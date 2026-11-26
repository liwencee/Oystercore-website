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
  # 0711: a user can reach a file in it by name (each environment's user reads its own env
  # files) but cannot list it. Every file in it is 0640 root:oc-<env>.
  oc_ensure_dir "$OC_SECRET_DIR" 0711 root root
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

# --- the deploy account ------------------------------------------------------------------
# CI's one door into the server. It has no password, no shell of its own that anyone can reach
# (sshd runs only the forced command), one sudoers rule, and nothing it can read or write but
# its spool folder. See infra/deploy/ for what it runs.

# users_pubkey_blob FILE: "type base64" of the first key line in FILE, without any comment.
users_pubkey_blob() { awk '!/^[[:space:]]*(#|$)/ {print $1 " " $2; exit}' "$1"; }

# users_validate_deploy_key: a plain public key (never private), and not an admin's key. If
# the CI key were also an admin's key, whoever holds CI's secret could sign in as that admin.
users_validate_deploy_key() {
  local blob adm i
  [[ $OC_DEPLOY_ENABLED == yes ]] || return 0
  oc_validate_pubkey "$OC_DEPLOY_KEYFILE"
  blob=$(users_pubkey_blob "$OC_DEPLOY_KEYFILE")
  for i in "${!OC_ADMIN_KEYS[@]}"; do
    adm=$(users_pubkey_blob "${OC_ADMIN_KEYS[$i]}")
    [[ $blob != "$adm" ]] || oc_die "OC_DEPLOY_PUBKEY is the same key as the admin '${OC_ADMIN_NAMES[$i]}'. The deploy key must be its own key pair, kept only in GitHub's secrets."
  done
}

# users_deploy_key_line: the one line of the deploy account's authorized_keys file. The forced
# command and `restrict` (no pty, no forwarding, no agent, no X11, no user rc) come first;
# the key is the configured one, with a fixed comment instead of whatever the file had.
users_deploy_key_line() {
  printf 'command="%s",restrict %s oc-deploy-ci' "$OC_DEPLOY_FORCED" "$(users_pubkey_blob "$OC_DEPLOY_KEYFILE")"
}

# The one sudoers rule. The arguments are a regular expression (sudo 1.9.10 and later: the
# argument text starts with ^ and ends with $), so sudo itself refuses anything but the exact
# shape deploy-release sends, and apply-release.sh checks the same patterns again. ':' is
# escaped because sudoers uses it as a separator. No wildcard anywhere. env_reset and !setenv
# mean the deploy account cannot pass environment variables through sudo.
users_deploy_sudoers() {
  cat <<EOF
# Managed by infra/bootstrap.sh. The deploy account may run ONE script as root, with arguments
# of exactly one shape (prod or staging, a 40-character commit, two sha256 image ids).
Defaults:$OC_DEPLOY_USER env_reset, !setenv
$OC_DEPLOY_USER ALL=(root) NOPASSWD: $OC_DEPLOY_APPLY ^(prod|staging) [0-9a-f]{40} sha256\:[0-9a-f]{64} sha256\:[0-9a-f]{64}\$
EOF
}

users_ensure_deploy() {
  local shell home status groups
  if [[ $OC_DEPLOY_ENABLED != yes ]]; then
    users_remove_deploy
    return 0
  fi
  users_ensure_system_group "$OC_DEPLOY_USER"
  if ! getent passwd "$OC_DEPLOY_USER" >/dev/null; then
    useradd --system --gid "$OC_DEPLOY_USER" --home-dir "$OC_DEPLOY_HOME" --no-create-home \
      --shell /bin/sh --comment "OysterCore deploy (forced command only)" -- "$OC_DEPLOY_USER"
    oc_changed "created user $OC_DEPLOY_USER"
  fi
  [[ $(id -u -- "$OC_DEPLOY_USER") -lt 1000 && $(id -u -- "$OC_DEPLOY_USER") -ne 0 ]] || oc_die "$OC_DEPLOY_USER is not a system account"
  home=$(getent passwd "$OC_DEPLOY_USER" | cut -d: -f6)
  if [[ $home != "$OC_DEPLOY_HOME" ]]; then
    usermod --home "$OC_DEPLOY_HOME" -- "$OC_DEPLOY_USER"
    oc_changed "set the home of $OC_DEPLOY_USER to $OC_DEPLOY_HOME"
  fi
  # sshd runs a forced command through the account's shell (sh -c), so it needs one that can.
  shell=$(getent passwd "$OC_DEPLOY_USER" | cut -d: -f7)
  if [[ $shell != /bin/sh ]]; then
    usermod --shell /bin/sh -- "$OC_DEPLOY_USER"
    oc_changed "set the shell of $OC_DEPLOY_USER to /bin/sh"
  fi
  # No password (locked), and in no group but its own: no group may give it more.
  status=$(getent shadow "$OC_DEPLOY_USER" | cut -d: -f2)
  if [[ $status != '!'* && $status != '*'* ]]; then
    passwd -l -- "$OC_DEPLOY_USER" >/dev/null
    oc_changed "locked the password of $OC_DEPLOY_USER"
  fi
  groups=$(id -nG -- "$OC_DEPLOY_USER")
  if [[ $groups != "$OC_DEPLOY_USER" ]]; then
    usermod --groups "" -- "$OC_DEPLOY_USER"
    oc_changed "removed $OC_DEPLOY_USER from every group but its own (was: $groups)"
  fi

  # Folders: the home is root's and cannot be written by the deploy account; the spool is the
  # one place it can write (group oc-deploy), and only root can replace the folder itself.
  oc_ensure_dir "$OC_DEPLOY_HOME" 0755 root root
  oc_ensure_dir "$OC_DEPLOY_SPOOL" 0770 root "$OC_DEPLOY_USER"
  oc_ensure_dir "$OC_RUNTIME_LIB_DIR" 0755 root root
  oc_ensure_dir "$OC_DEPLOY_DIR" 0755 root root
  # The scripts and the size limit, root-owned and not writable by anyone else.
  oc_install_file "$OC_INFRA_DIR/deploy/deploy-release.sh" "$OC_DEPLOY_FORCED" 0755 root root
  oc_install_file "$OC_INFRA_DIR/deploy/apply-release.sh" "$OC_DEPLOY_APPLY" 0755 root root
  oc_install_stdin "$OC_DEPLOY_LIMITS" 0644 root root <<EOF
# Managed by infra/bootstrap.sh (OC_DEPLOY_MAX_BYTES in server.env). Read by both deploy scripts.
MAX_TARBALL_BYTES=$OC_DEPLOY_MAX_BYTES
EOF
  # The deploy key, in a root-owned file that only sshd's Match block for this user reads.
  oc_install_stdin "$OC_DEPLOY_KEYS" 0644 root root <<<"$(users_deploy_key_line)"
  # The one sudoers rule, checked by visudo before it is put in place.
  users_deploy_sudoers | oc_install_stdin "$OC_DEPLOY_SUDOERS" 0440 root root visudo -c -f
}

# Deploy account switched off (OC_DEPLOY_ENABLED=no): nothing of it is left. Idempotent.
users_remove_deploy() {
  local f
  for f in "$OC_DEPLOY_SUDOERS" "$OC_DEPLOY_KEYS" "$OC_DEPLOY_FORCED" "$OC_DEPLOY_APPLY" "$OC_DEPLOY_LIMITS"; do
    if [[ -e $f || -L $f ]]; then
      rm -f -- "$f"
      oc_changed "removed $f"
    fi
  done
  if [[ -d $OC_DEPLOY_DIR && ! -L $OC_DEPLOY_DIR ]] && rmdir -- "$OC_DEPLOY_DIR" 2>/dev/null; then
    oc_changed "removed $OC_DEPLOY_DIR"
  fi
  if getent passwd "$OC_DEPLOY_USER" >/dev/null; then
    userdel -- "$OC_DEPLOY_USER" >/dev/null 2>&1 || oc_die "could not remove the user $OC_DEPLOY_USER"
    oc_changed "removed the user $OC_DEPLOY_USER"
  fi
  if getent group "$OC_DEPLOY_USER" >/dev/null; then
    groupdel -- "$OC_DEPLOY_USER" >/dev/null 2>&1 || oc_die "could not remove the group $OC_DEPLOY_USER"
    oc_changed "removed the group $OC_DEPLOY_USER"
  fi
  if [[ -d $OC_DEPLOY_HOME && ! -L $OC_DEPLOY_HOME ]]; then
    rm -rf --one-file-system -- "$OC_DEPLOY_HOME"
    oc_changed "removed $OC_DEPLOY_HOME"
  fi
}
