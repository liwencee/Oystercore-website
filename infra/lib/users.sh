#!/usr/bin/env bash
# Users, groups, folders, secret files and the named admin accounts.
# Sourced by bootstrap.sh. Needs lib/common.sh and a loaded configuration.
# shellcheck shell=bash
# shellcheck disable=SC2034  # the USERS_* key lists are read by verify.sh

# Environment users are system accounts with no login shell and a group of their own. Each
# runs its own rootless Podman, so its home (not the data folder) holds the image store and
# the Quadlet files (see lib/containers.sh).
users_ensure_system_group() {
  local name=$1
  if ! getent group "$name" >/dev/null; then
    groupadd --system -- "$name"
    oc_changed "created group $name"
  fi
}

users_ensure_env_user() {
  local env=$1 name="oc-$1" shell home want
  want=$(oc_env_home "$env")
  users_ensure_system_group "$name"
  if ! getent passwd "$name" >/dev/null; then
    useradd --system --gid "$name" --home-dir "$want" --no-create-home \
      --shell /usr/sbin/nologin --comment "OysterCore $env services" -- "$name"
    oc_changed "created user $name"
  fi
  home=$(getent passwd "$name" | cut -d: -f6)
  if [[ $home != "$want" ]]; then
    usermod --home "$want" -- "$name"
    oc_changed "set the home of $name to $want"
  fi
  shell=$(getent passwd "$name" | cut -d: -f7)
  if [[ $shell != /usr/sbin/nologin ]]; then
    usermod --shell /usr/sbin/nologin -- "$name"
    oc_changed "set the shell of $name to nologin"
  fi
  # The scan socket is group-accessible to the environment users (and only them).
  if ! oc_in_group "$name" "$OC_CLAMD_GROUP"; then
    usermod --append --groups "$OC_CLAMD_GROUP" -- "$name"
    oc_changed "added $name to $OC_CLAMD_GROUP"
  fi
}

users_ensure_dirs() {
  local env
  oc_ensure_dir "$OC_DATA_ROOT" 0755 root root
  oc_ensure_dir "$OC_SECRET_DIR" 0755 root root
  for env in "${OC_ENV_LIST[@]}"; do
    oc_ensure_dir "$OC_DATA_ROOT/$env" 0750 "oc-$env" "oc-$env"
    oc_ensure_dir "$OC_DATA_ROOT/$env/media" 0750 "oc-$env" "oc-$env"
    oc_ensure_dir "$OC_DATA_ROOT/$env/private" 0750 "oc-$env" "oc-$env"
    oc_ensure_dir "$OC_DATA_ROOT/$env/tmp" 0750 "oc-$env" "oc-$env"
  done
}

# --- secret files ------------------------------------------------------------------
users_rand_b64() { openssl rand -base64 "$1" | tr -d '\n'; }
users_rand_hex() { openssl rand -hex "$1" | tr -d '\n'; }

# The names each environment file must define. verify.sh reads these lists too.
#
# Two files per environment, because the website must not hold what only the CMS needs
# (spec 10.4): /etc/oc/<env>.env is the CMS's, /etc/oc/<env>.web.env is the website's.
# The only secret they share is OC_INTERNAL_SECRET, the value the website sends to Strapi in
# the x-oc-secret header; it is generated once and written to both.
USERS_CMS_KEYS=(
  NODE_ENV HOST DATABASE_CLIENT DATABASE_HOST DATABASE_PORT DATABASE_NAME DATABASE_USERNAME
  DATABASE_PASSWORD APP_KEYS API_TOKEN_SALT ADMIN_JWT_SECRET TRANSFER_TOKEN_SALT JWT_SECRET
  ENCRYPTION_KEY OC_INTERNAL_SECRET OC_FILE_MASTER_KEY OC_DATA_DIR OC_CMS_URL PUBLIC_SITE_URL
  CSP_MODE
)
# The website's whole list. A key in the web file that is not here is an error.
USERS_WEB_KEYS=(
  NODE_ENV HOST PORT OC_CMS_URL OC_CMS_API_TOKEN OC_INTERNAL_SECRET OC_DATA_DIR PUBLIC_SITE_URL
  CSP_MODE
)
# Of those, the one that may stay empty until the token exists in the Strapi admin.
USERS_WEB_MAY_BE_EMPTY=(OC_CMS_API_TOKEN)

# users_file_value FILE KEY: the value of KEY in an environment file (the last one wins, as
# in systemd). The caller keeps it in a variable and never prints it.
users_file_value() {
  awk -F= -v k="$2" '$1 == k {sub(/^[^=]*=/, ""); v = $0; f = 1} END {if (f) print v}' "$1"
}

# users_env_value ENV KEY: one value from the CMS's environment file.
users_env_value() { users_file_value "$OC_SECRET_DIR/$1.env" "$2"; }

# users_write_env_file FILE ENV OWNERGROUP: read the new content from stdin into a private
# temp file, hand it to its group, and move it into place. The file is created 0600 and only
# then given to its group, so it is never readable by anyone it should not be.
users_write_env_file() {
  local file=$1 env=$2 tmp
  (
    umask 077
    tmp=$(mktemp -p "$OC_SECRET_DIR" ".oc-tmp.XXXXXX")
    trap 'rm -f -- "$tmp"' EXIT
    cat >"$tmp"
    chown "root:oc-$env" -- "$tmp"
    chmod 0640 -- "$tmp"
    mv -n -- "$tmp" "$file"
  )
  [[ -f $file ]] || oc_die "could not create $file"
  oc_changed "created $file (values not shown)"
}

# users_ensure_env_files ENV
# Generates /etc/oc/<env>.env (the CMS's) and /etc/oc/<env>.web.env (the website's) once.
# An existing file is never rewritten: rerunning the bootstrap must not rotate a secret out
# from under a running application. Values are written from shell variables through a
# heredoc, so none appears in a process argument list or in the log.
#
# OC_INTERNAL_SECRET must be the same in both files. If either file exists already its value
# is reused for the other, so a half-finished earlier run still ends with two matching files.
users_ensure_env_files() {
  local env=$1 cms="$OC_SECRET_DIR/$1.env" web="$OC_SECRET_DIR/$1.web.env" internal=""
  local db_pass app_keys api_salt admin_jwt transfer_salt jwt enc master
  if [[ -f $cms ]]; then
    internal=$(users_file_value "$cms" OC_INTERNAL_SECRET)
  elif [[ -f $web ]]; then
    internal=$(users_file_value "$web" OC_INTERNAL_SECRET)
  fi
  if [[ -f $cms && -f $web ]]; then
    oc_fix_perms "$cms" 0640 root "oc-$env"
    oc_fix_perms "$web" 0640 root "oc-$env"
    return 0
  fi
  if [[ -z $internal ]]; then
    # Only a brand-new environment gets a new secret. An existing file without one is a
    # broken file, and writing a different value into the other file would make them differ.
    if [[ -f $cms || -f $web ]]; then
      oc_die "an existing $env environment file has no OC_INTERNAL_SECRET; fix it by hand (both files must hold the same value)"
    fi
    internal=$(users_rand_b64 32)
  fi
  [[ $internal =~ ^[A-Za-z0-9+/=]{20,}$ ]] || oc_die "OC_INTERNAL_SECRET in an existing $env environment file is missing or has unexpected characters"

  if [[ -f $cms ]]; then
    oc_fix_perms "$cms" 0640 root "oc-$env"
  else
    oc_log "generating the CMS secrets for $env (once; never regenerated)"
    db_pass=$(users_rand_hex 24)
    app_keys="$(users_rand_b64 18),$(users_rand_b64 18),$(users_rand_b64 18),$(users_rand_b64 18)"
    api_salt=$(users_rand_b64 24)
    admin_jwt=$(users_rand_b64 32)
    transfer_salt=$(users_rand_b64 24)
    jwt=$(users_rand_b64 32)
    enc=$(users_rand_b64 32)
    master=$(users_rand_b64 32)
    users_write_env_file "$cms" "$env" <<EOF
# Managed by infra/bootstrap.sh. Generated once; the bootstrap never rewrites this file.
# The CMS container's secrets (oc-cms-$env). The website has its own, smaller file,
# /etc/oc/$env.web.env, which shares only OC_INTERNAL_SECRET with this one. Never commit it.
# The Quadlet file overrides what differs inside the container: HOST (0.0.0.0, inside the
# private network), PORT, and the MariaDB and ClamAV socket paths (DATABASE_SOCKET_PATH,
# OC_CLAMD_SOCKET). The host-side values below (127.0.0.1, 3306) are for running the app
# outside a container, for example in development.
NODE_ENV=production
HOST=127.0.0.1
DATABASE_CLIENT=mysql
DATABASE_HOST=127.0.0.1
DATABASE_PORT=3306
DATABASE_NAME=oc_$env
DATABASE_USERNAME=oc_$env
DATABASE_PASSWORD=$db_pass
APP_KEYS=$app_keys
API_TOKEN_SALT=$api_salt
ADMIN_JWT_SECRET=$admin_jwt
TRANSFER_TOKEN_SALT=$transfer_salt
JWT_SECRET=$jwt
ENCRYPTION_KEY=$enc
OC_INTERNAL_SECRET=$internal
OC_FILE_MASTER_KEY=$master
OC_DATA_DIR=$OC_DATA_ROOT/$env
OC_CMS_URL=http://127.0.0.1:$(oc_cms_port "$env")
PUBLIC_SITE_URL=https://$(oc_web_host "$env")
CSP_MODE=report-only
EOF
  fi

  if [[ -f $web ]]; then
    oc_fix_perms "$web" 0640 root "oc-$env"
  else
    oc_log "generating the website's environment file for $env (once; never regenerated)"
    users_write_env_file "$web" "$env" <<EOF
# Managed by infra/bootstrap.sh. Generated once; the bootstrap never rewrites this file.
# The website container's environment (oc-web-$env), and ONLY that: no database password, no
# JWT or admin secrets, no encryption keys, no file master key. Those are the CMS's, in
# /etc/oc/$env.env. The website is the most exposed process on the server, so it holds the
# least. Never commit this file.
# The one shared secret: OC_INTERNAL_SECRET, which the website sends to Strapi as the
# x-oc-secret header. It has the same value as in the CMS file.
# The Quadlet file sets HOST, PORT and OC_CMS_URL again with the same values.
NODE_ENV=production
HOST=0.0.0.0
PORT=$OC_WEB_INTERNAL_PORT
OC_CMS_URL=http://oc-cms-$env:$OC_CMS_INTERNAL_PORT
# Create the read-only API token in the Strapi admin (Settings, API Tokens), paste it here
# and restart oc-web-$env. It is empty until then.
OC_CMS_API_TOKEN=
OC_INTERNAL_SECRET=$internal
OC_DATA_DIR=$OC_DATA_ROOT/$env
PUBLIC_SITE_URL=https://$(oc_web_host "$env")
CSP_MODE=report-only
EOF
  fi
}

# --- admins ------------------------------------------------------------------------
users_ensure_admin() {
  local name=$1 keyfile=$2 home line cur
  oc_validate_pubkey "$keyfile"
  line=$(oc_pubkey_line "$keyfile")
  if ! getent passwd "$name" >/dev/null; then
    useradd --create-home --shell /bin/bash --comment "OysterCore administrator" -- "$name"
    oc_changed "created admin user $name"
  fi
  [[ $(id -u -- "$name") -ge 1000 ]] || oc_die "$name is a system account; an admin must be a normal user"
  home=$(getent passwd "$name" | cut -d: -f6)
  [[ -d $home ]] || oc_die "home folder of $name ($home) does not exist"
  for cur in sudo "$OC_ADMIN_GROUP"; do
    if ! oc_in_group "$name" "$cur"; then
      usermod --append --groups "$cur" -- "$name"
      oc_changed "added $name to $cur"
    fi
  done
  oc_ensure_dir "$home/.ssh" 0700 "$name" "$name"
  # One named key per person: the file holds exactly the key given in server.env.
  oc_install_stdin "$home/.ssh/authorized_keys" 0600 "$name" "$name" <<<"$line"
}

users_ensure_admins() {
  local i
  users_ensure_system_group "$OC_ADMIN_GROUP"
  for i in "${!OC_ADMIN_NAMES[@]}"; do
    users_ensure_admin "${OC_ADMIN_NAMES[$i]}" "${OC_ADMIN_KEYS[$i]}"
  done
}

# sudo for admins: named accounts, a sudo log that is kept, and (by default) no password
# prompt, because admins have no password to type: they sign in by key only.
users_ensure_sudo() {
  oc_install_stdin /etc/sudoers.d/91-oc-logging 0440 root root visudo -c -f <<'EOF'
# Managed by infra/bootstrap.sh
Defaults logfile="/var/log/sudo.log"
Defaults log_year
Defaults use_pty
Defaults !visiblepw
EOF
  if [[ $OC_SUDO_PASSWORDLESS == yes ]]; then
    oc_install_stdin /etc/sudoers.d/90-oc-admins 0440 root root visudo -c -f <<EOF
# Managed by infra/bootstrap.sh. Admins sign in by SSH key only and have no password.
%$OC_ADMIN_GROUP ALL=(ALL:ALL) NOPASSWD: ALL
EOF
  elif [[ -e /etc/sudoers.d/90-oc-admins ]]; then
    rm -f -- /etc/sudoers.d/90-oc-admins
    oc_changed "removed /etc/sudoers.d/90-oc-admins (OC_SUDO_PASSWORDLESS=no)"
  fi
  oc_install_stdin /etc/logrotate.d/oc-sudo 0644 root root <<'EOF'
# Managed by infra/bootstrap.sh
/var/log/sudo.log {
    weekly
    rotate 52
    compress
    delaycompress
    missingok
    notifempty
    create 0600 root root
}
EOF
  if [[ ! -e /var/log/sudo.log ]]; then
    install -m 0600 -o root -g root /dev/null /var/log/sudo.log
    oc_changed "created /var/log/sudo.log"
  fi
}
