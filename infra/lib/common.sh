#!/usr/bin/env bash
# Shared helpers for bootstrap.sh, verify.sh and the runtime script oc-cloudflare-ips.
# This file is sourced, never executed. It sets no shell options and installs no traps:
# the entry scripts do that.
# shellcheck shell=bash
# shellcheck disable=SC2034  # the constants below are used by the scripts that source this file

# --- constants ---------------------------------------------------------------------
# Every path the setup touches is spelled out here, so the verifier and the bootstrap
# cannot drift apart.
OC_DATA_ROOT=/var/lib/oc
OC_SECRET_DIR=/etc/oc
OC_NGINX_DIR=/etc/nginx/oc
OC_NGINX_CONF=/etc/nginx/conf.d/oc.conf
OC_NGINX_REALIP=/etc/nginx/conf.d/00-oc-cloudflare-realip.conf
OC_NGINX_CA="$OC_NGINX_DIR/cloudflare-origin-pull-ca.pem"
OC_TLS_DIR=/etc/ssl/oc
OC_TLS_CERT="$OC_TLS_DIR/origin.pem"
OC_TLS_KEY="$OC_TLS_DIR/origin.key"
OC_SSHD_DROPIN=/etc/ssh/sshd_config.d/00-oc-hardening.conf
OC_UNIT_DIR=/etc/systemd/system
OC_RUNTIME_LIB_DIR=/usr/local/lib/oc
OC_RUNTIME_BIN=/usr/local/sbin/oc-cloudflare-ips
OC_CLAMD_GROUP=oc-clamd
OC_ADMIN_GROUP=oc-admins
OC_CLAMD_SOCKET=/run/clamav/clamd.ctl
OC_MIN_PODMAN=4.4
# Rootless Podman: each environment user's home holds its image store and its Quadlet files.
# The home is NOT the data folder, so the apps (which can write the data folder) cannot
# change their own container definition.
OC_ENV_HOME_ROOT=/home
OC_QUADLET_SUBDIR=.config/containers/systemd
OC_MARIADB_RUN_DIR=/run/mysqld
OC_MARIADB_SOCKET=/run/mysqld/mysqld.sock
OC_MARIADB_DATADIR=/var/lib/mysql
OC_CLAMD_RUN_DIR=/run/clamav
OC_LINGER_DIR=/var/lib/systemd/linger
OC_SUBID_MIN=100000
OC_SUBID_COUNT=65536
# The ports the apps listen on INSIDE their containers. On the host they are published on
# 127.0.0.1 as oc_cms_port and oc_web_port.
OC_CMS_INTERNAL_PORT=1337
OC_WEB_INTERNAL_PORT=4321
OC_KNOWN_ENVS="prod staging"
# The deploy account (spec 5 and 10.9): CI's one door into the server. Everything it can run is
# root-owned: the forced command, and the script that one sudoers rule allows. Its home holds
# nothing and it cannot write there; the spool folder is the only place it can write.
OC_DEPLOY_USER=oc-deploy
OC_DEPLOY_HOME=/var/lib/oc-deploy
OC_DEPLOY_SPOOL=/var/lib/oc-deploy/spool
OC_DEPLOY_DIR=/usr/local/lib/oc/deploy
OC_DEPLOY_FORCED=/usr/local/lib/oc/deploy/deploy-release
OC_DEPLOY_APPLY=/usr/local/lib/oc/deploy/apply-release.sh
OC_DEPLOY_LIMITS=/usr/local/lib/oc/deploy/limits.conf
# The deploy key lives in a root-owned file (sshd's Match block points AuthorizedKeysFile at
# it), so the deploy account cannot add a key or change the forced command.
OC_DEPLOY_KEYS=/etc/ssh/oc-deploy.authorized_keys
OC_DEPLOY_SUDOERS=/etc/sudoers.d/92-oc-deploy
# Services a web server has no use for. The bootstrap masks any that exist; verify.sh checks.
OC_UNUSED_UNITS=(
  snapd.service snapd.socket snapd.seeded.service multipathd.service multipathd.socket
  ModemManager.service udisks2.service avahi-daemon.service avahi-daemon.socket
  cups.service cups.socket cups-browsed.service bluetooth.service rpcbind.service rpcbind.socket
  apport.service
)

# Ports on localhost (spec section 5). Index by environment name.
oc_cms_port() { case $1 in prod) echo 1337 ;; staging) echo 1338 ;; *) oc_die "unknown environment: $1" ;; esac; }
oc_web_port() { case $1 in prod) echo 4321 ;; staging) echo 4322 ;; *) oc_die "unknown environment: $1" ;; esac; }
# Public host names, built from OC_DOMAIN.
oc_web_host() { case $1 in prod) echo "www.$OC_DOMAIN" ;; staging) echo "staging.$OC_DOMAIN" ;; *) oc_die "unknown environment: $1" ;; esac; }
oc_cms_host() { case $1 in prod) echo "cms.$OC_DOMAIN" ;; staging) echo "cms-staging.$OC_DOMAIN" ;; *) oc_die "unknown environment: $1" ;; esac; }

# The environment user's home and Quadlet folder, and its numeric ids (empty if no such user).
oc_env_home() { printf '%s/oc-%s' "$OC_ENV_HOME_ROOT" "$1"; }
oc_env_quadlet_dir() { printf '%s/%s' "$(oc_env_home "$1")" "$OC_QUADLET_SUBDIR"; }
oc_env_uid() { id -u -- "oc-$1" 2>/dev/null || true; }
oc_env_gid() { id -g -- "oc-$1" 2>/dev/null || true; }

# --- logging -----------------------------------------------------------------------
oc_log() { printf '[oc] %s\n' "$*"; }
oc_warn() { printf '[oc] WARN: %s\n' "$*" >&2; }
oc_die() {
  printf '[oc] ERROR: %s\n' "$*" >&2
  exit 1
}

# Every change the script makes goes through oc_changed, so a second run can prove it
# changed nothing (OC_CHANGES stays 0).
OC_CHANGES=0
oc_changed() {
  OC_CHANGES=$((OC_CHANGES + 1))
  oc_log "changed: $*"
}

# --- modes -------------------------------------------------------------------------
# OC_CONTAINER=1 is set only by infra/test/run.sh. It makes the bootstrap write every
# configuration file but skip what needs a kernel or systemd (firewall activation,
# service start, sysctl, swap). It is refused on a host that is really running systemd.
oc_container_mode() { [[ ${OC_CONTAINER:-0} == 1 ]]; }

oc_require_root() {
  [[ $EUID -eq 0 ]] || oc_die "run this as root (for example: sudo bash $0)"
}

oc_check_mode() {
  if oc_container_mode; then
    if [[ -d /run/systemd/system ]]; then
      oc_die "OC_CONTAINER=1 is set but systemd is running here. That setting is for the test container only."
    fi
  else
    [[ -d /run/systemd/system ]] || oc_die "systemd is not running. This script sets up a real server. (The test container sets OC_CONTAINER=1.)"
  fi
}

# systemctl, skipped in container mode.
oc_systemctl() {
  if oc_container_mode; then
    oc_log "container: skipped systemctl $*"
    return 0
  fi
  systemctl "$@"
}

# --- temporary files ---------------------------------------------------------------
# Temp files come from mktemp and are removed by the entry script's EXIT trap.
OC_TMP_PATHS=()

# oc_mktemp_into VARNAME [DIR] [-d]
# Creates a private (0600/0700) temp file or directory and stores its path in VARNAME.
# A function that returned the path on stdout would run in a subshell and lose the
# bookkeeping needed for cleanup.
oc_mktemp_into() {
  local __var=$1 __dir=${2:-} __flag=${3:-} __path
  local -a args=()
  [[ $__flag == -d ]] && args+=(-d)
  if [[ -n $__dir ]]; then
    __path=$(mktemp "${args[@]}" -p "$__dir" ".oc-tmp.XXXXXX") || oc_die "mktemp failed in $__dir"
  else
    __path=$(mktemp "${args[@]}" -t "oc.XXXXXX") || oc_die "mktemp failed"
  fi
  OC_TMP_PATHS+=("$__path")
  printf -v "$__var" '%s' "$__path"
}

oc_cleanup() {
  local p
  for p in "${OC_TMP_PATHS[@]}"; do
    rm -rf -- "$p"
  done
}

# --- small string helpers ----------------------------------------------------------
oc_trim() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

# oc_version_ge A B: true when version A >= version B.
oc_version_ge() {
  [[ $(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n 1) == "$2" ]]
}

oc_have() { command -v "$1" >/dev/null 2>&1; }

# oc_in_group USER GROUP (a string match, not a grep pipe: see fw_has_rule).
oc_in_group() {
  local g
  g=$(id -nG -- "$1" 2>/dev/null) || return 1
  [[ " $g " == *" $2 "* ]]
}

# Run a command and show its output only if it fails. Used for chatty tools (ufw).
oc_quiet() {
  local out rc=0
  out=$("$@" 2>&1) || rc=$?
  if [[ $rc -ne 0 ]]; then
    printf '%s\n' "$out" >&2
    return "$rc"
  fi
}

# --- file helpers ------------------------------------------------------------------
oc_norm_mode() { printf '%o' "$((8#$1))"; }

# oc_fix_perms PATH MODE OWNER GROUP: make an existing path match, counting a change.
oc_fix_perms() {
  local path=$1 mode owner=$3 group=$4 have
  mode=$(oc_norm_mode "$2")
  have=$(stat -c '%a %U %G' -- "$path")
  if [[ $have != "$mode $owner $group" ]]; then
    chown "$owner:$group" -- "$path"
    chmod "$mode" -- "$path"
    oc_changed "permissions of $path ($have -> $mode $owner $group)"
  fi
}

# oc_ensure_dir DIR MODE OWNER GROUP: create or correct one directory (not its parents).
oc_ensure_dir() {
  local dir=$1 mode=$2 owner=$3 group=$4
  if [[ -L $dir ]]; then
    oc_die "$dir is a symbolic link; refusing to use it"
  fi
  if [[ ! -d $dir ]]; then
    install -d -m "$mode" -o "$owner" -g "$group" -- "$dir"
    oc_changed "created directory $dir"
    return 0
  fi
  oc_fix_perms "$dir" "$mode" "$owner" "$group"
}

# oc_install_tmp TMP DEST MODE OWNER GROUP: move a finished temp file into place unless
# DEST already has the same content, mode and owner. The mode and owner are set on the
# temp file first, so DEST never exists with wider permissions than intended.
oc_install_tmp() {
  local tmp=$1 dest=$2 mode=$3 owner=$4 group=$5
  if [[ -f $dest && ! -L $dest ]] && cmp -s -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    oc_fix_perms "$dest" "$mode" "$owner" "$group"
    return 0
  fi
  chown "$owner:$group" -- "$tmp"
  chmod "$mode" -- "$tmp"
  mv -f -- "$tmp" "$dest"
  oc_changed "wrote $dest"
}

# oc_install_stdin DEST MODE OWNER GROUP [CHECK_CMD [ARGS...]]
# Reads the new content from stdin. When CHECK_CMD is given it is run as
# CHECK_CMD ARGS... TEMPFILE before anything is moved into place; a failure aborts.
oc_install_stdin() {
  local dest=$1 mode=$2 owner=$3 group=$4
  shift 4
  local dir tmp
  dir=$(dirname -- "$dest")
  [[ -d $dir ]] || oc_die "directory $dir does not exist (needed for $dest)"
  oc_mktemp_into tmp "$dir"
  cat >"$tmp"
  if [[ $# -gt 0 ]]; then
    oc_quiet "$@" "$tmp" || oc_die "validation failed for the new $dest (nothing was changed)"
  fi
  oc_install_tmp "$tmp" "$dest" "$mode" "$owner" "$group"
}

# oc_install_file SRC DEST MODE OWNER GROUP
oc_install_file() {
  [[ -f $1 ]] || oc_die "missing source file $1"
  oc_install_stdin "$2" "$3" "$4" "$5" <"$1"
}

# --- configuration (server.env) ----------------------------------------------------
# Defaults. The file may override them.
OC_DOMAIN=""
OC_ADMINS=""
OC_SSH_PORT=""
OC_TIMEZONE="Africa/Lagos"
OC_ENVS="prod staging"
OC_SUDO_PASSWORDLESS="yes"
OC_SWAP_SIZE="2G"
OC_DEPLOY_ENABLED="yes"
OC_DEPLOY_PUBKEY_PROD=""
OC_DEPLOY_PUBKEY_STAGING=""
OC_DEPLOY_MAX_BYTES="2147483648"
OC_DEPLOY_KEYFILE_PROD=""
OC_DEPLOY_KEYFILE_STAGING=""
OC_CONFIG_DIR=""
OC_ENV_LIST=()
OC_ADMIN_NAMES=()
OC_ADMIN_KEYS=()

# oc_load_config FILE
# The file is parsed, never sourced: only KEY=value lines for known keys are accepted,
# so a typo or a stray command cannot run as root.
oc_load_config() {
  local file=$1 line key val n=0
  local dq='^"(.*)"$' sq="^'(.*)'\$"
  [[ -f $file && -r $file ]] || oc_die "configuration file not found or unreadable: $file (copy infra/server.env.example to infra/server.env and edit it)"
  OC_CONFIG_DIR=$(cd -- "$(dirname -- "$file")" && pwd -P)
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    line=${line%$'\r'}
    if [[ $line =~ ^[[:space:]]*(#.*)?$ ]]; then
      continue
    fi
    if [[ $line =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
      key=${BASH_REMATCH[1]}
      val=${BASH_REMATCH[2]}
      if [[ $val =~ $dq ]] || [[ $val =~ $sq ]]; then
        val=${BASH_REMATCH[1]}
      fi
      case $key in
        OC_DOMAIN | OC_ADMINS | OC_SSH_PORT | OC_TIMEZONE | OC_ENVS | OC_SUDO_PASSWORDLESS | OC_SWAP_SIZE | OC_DEPLOY_ENABLED | OC_DEPLOY_PUBKEY_PROD | OC_DEPLOY_PUBKEY_STAGING | OC_DEPLOY_MAX_BYTES)
          printf -v "$key" '%s' "$val"
          ;;
        OC_DEPLOY_PUBKEY) oc_die "$file line $n: OC_DEPLOY_PUBKEY is gone: every environment has its own deploy key now. Use OC_DEPLOY_PUBKEY_PROD and OC_DEPLOY_PUBKEY_STAGING (one .pub file each, for each environment in OC_ENVS)" ;;
        *) oc_die "$file line $n: unknown setting $key" ;;
      esac
    else
      oc_die "$file line $n: expected KEY=value (no spaces around =, no trailing comments)"
    fi
  done <"$file"
}

# oc_deploy_keyfile ENV: the path of the public key file of that environment's deploy key (empty
# when the deploy account is off or the environment is not on this server).
oc_deploy_keyfile() {
  local v=OC_DEPLOY_KEYFILE_${1^^}
  printf '%s' "${!v:-}"
}

# Names an admin may not take: they belong to the system or to this setup.
oc_reserved_user() {
  case $1 in
    root | daemon | bin | sys | sync | games | man | lp | mail | news | uucp | proxy | www-data | backup | list | irc | _apt | nobody | sshd | mysql | clamav | nginx | systemd-* | oc-* | deploy | ubuntu) return 0 ;;
    *) return 1 ;;
  esac
}

oc_validate_config() {
  local port env seen=" " pair name path
  local -a pairs=()

  [[ $OC_DOMAIN =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] ||
    oc_die "OC_DOMAIN must be a lowercase domain such as example.com (no scheme, no www.)"

  [[ $OC_SSH_PORT =~ ^[0-9]{1,5}$ ]] || oc_die "OC_SSH_PORT must be a number"
  port=$((10#$OC_SSH_PORT))
  ((port >= 1 && port <= 65535)) || oc_die "OC_SSH_PORT must be between 1 and 65535"
  ((port != 22)) || oc_die "OC_SSH_PORT must not be 22 (the spec requires a non-default port)"
  case $port in
    80 | 443 | 3306 | 1337 | 1338 | 4321 | 4322) oc_die "OC_SSH_PORT $port is used by another service" ;;
    *) ;;
  esac
  OC_SSH_PORT=$port

  [[ $OC_TIMEZONE =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]] || oc_die "OC_TIMEZONE is not a valid zone name"
  [[ $OC_SUDO_PASSWORDLESS == yes || $OC_SUDO_PASSWORDLESS == no ]] || oc_die "OC_SUDO_PASSWORDLESS must be yes or no"
  [[ $OC_SWAP_SIZE =~ ^[1-9][0-9]*[MG]$ ]] || oc_die "OC_SWAP_SIZE must look like 2G or 1024M"
  [[ $OC_DEPLOY_ENABLED == yes || $OC_DEPLOY_ENABLED == no ]] || oc_die "OC_DEPLOY_ENABLED must be yes or no"
  # The largest image tarball the deploy account may upload: at least 1 MiB, at most 64 GiB.
  [[ $OC_DEPLOY_MAX_BYTES =~ ^[1-9][0-9]{6,10}$ ]] ||
    oc_die "OC_DEPLOY_MAX_BYTES must be a number of bytes between 1048576 (1 MiB) and 68719476736 (64 GiB)"
  ((OC_DEPLOY_MAX_BYTES >= 1048576 && OC_DEPLOY_MAX_BYTES <= 68719476736)) ||
    oc_die "OC_DEPLOY_MAX_BYTES must be a number of bytes between 1048576 (1 MiB) and 68719476736 (64 GiB)"
  read -r -a OC_ENV_LIST <<<"${OC_ENVS//,/ }"
  [[ ${#OC_ENV_LIST[@]} -gt 0 ]] || oc_die "OC_ENVS is empty"
  for env in "${OC_ENV_LIST[@]}"; do
    [[ " $OC_KNOWN_ENVS " == *" $env "* ]] || oc_die "OC_ENVS: unknown environment '$env' (known: $OC_KNOWN_ENVS)"
    [[ $seen != *" $env "* ]] || oc_die "OC_ENVS: '$env' is listed twice"
    seen+="$env "
  done

  # One deploy key PER ENVIRONMENT, for each environment this server runs (OC_ENVS). The key's line
  # in the account's authorized_keys fixes its environment, so a staging key can never deploy
  # production. A key setting for an environment that is not on this server is a mistake.
  OC_DEPLOY_KEYFILE_PROD=""
  OC_DEPLOY_KEYFILE_STAGING=""
  if [[ $OC_DEPLOY_ENABLED == yes ]]; then
    local pubvar filevar ghenv
    for env in $OC_KNOWN_ENVS; do
      pubvar=OC_DEPLOY_PUBKEY_${env^^}
      filevar=OC_DEPLOY_KEYFILE_${env^^}
      # the GitHub environment that holds the private half: `production` for the server's prod
      ghenv=$env
      [[ $env != prod ]] || ghenv=production
      if [[ " ${OC_ENV_LIST[*]} " == *" $env "* ]]; then
        [[ -n ${!pubvar} ]] ||
          oc_die "OC_DEPLOY_ENABLED=yes needs $pubvar=<path to the PUBLIC key (.pub) of the $env deploy key>, because $env is in OC_ENVS. Every environment has its own key pair for CI (ssh-keygen -t ed25519): keep the private half in the GitHub environment '$ghenv' as the secret DEPLOY_SSH_KEY and give the .pub file here. Or set OC_DEPLOY_ENABLED=no."
        if [[ ${!pubvar} == /* ]]; then
          printf -v "$filevar" '%s' "${!pubvar}"
        else
          printf -v "$filevar" '%s' "$OC_CONFIG_DIR/${!pubvar}"
        fi
      elif [[ -n ${!pubvar} ]]; then
        oc_die "$pubvar is set, but $env is not in OC_ENVS (this server does not run it). Remove the setting."
      fi
    done
  fi

  OC_ADMIN_NAMES=()
  OC_ADMIN_KEYS=()
  IFS=',' read -r -a pairs <<<"$OC_ADMINS"
  seen=" "
  for pair in "${pairs[@]}"; do
    pair=$(oc_trim "$pair")
    [[ -n $pair ]] || continue
    [[ $pair == *:* ]] || oc_die "OC_ADMINS entry '$pair' must look like name:path-to-public-key"
    name=$(oc_trim "${pair%%:*}")
    path=$(oc_trim "${pair#*:}")
    [[ $name =~ ^[a-z][a-z0-9_-]{1,30}$ ]] || oc_die "OC_ADMINS: '$name' is not a valid user name (lowercase letters, digits, - and _)"
    if oc_reserved_user "$name"; then
      oc_die "OC_ADMINS: '$name' is a reserved name"
    fi
    [[ $seen != *" $name "* ]] || oc_die "OC_ADMINS: '$name' is listed twice"
    seen+="$name "
    [[ -n $path ]] || oc_die "OC_ADMINS: no key file for '$name'"
    if [[ $path != /* ]]; then
      path="$OC_CONFIG_DIR/$path"
    fi
    OC_ADMIN_NAMES+=("$name")
    OC_ADMIN_KEYS+=("$path")
  done
  [[ ${#OC_ADMIN_NAMES[@]} -gt 0 ]] || oc_die "OC_ADMINS needs at least one name:path-to-public-key entry"
}

# oc_validate_pubkey FILE: exactly one plain public key, never a private key.
oc_validate_pubkey() {
  local file=$1 lines type bits
  [[ -f $file && -r $file ]] || oc_die "public key file not found: $file"
  [[ $(stat -c %s -- "$file") -le 4096 ]] || oc_die "$file is too large to be a public key"
  if grep -q 'PRIVATE KEY' -- "$file"; then
    oc_die "$file contains a PRIVATE key. Give the path of the .pub file instead, and keep private keys off the server."
  fi
  lines=$(grep -c -v -E '^[[:space:]]*(#.*)?$' -- "$file" || true)
  [[ $lines -eq 1 ]] || oc_die "$file must hold exactly one public key line (found $lines)"
  grep -q -E '^(ssh-ed25519|sk-ssh-ed25519@openssh\.com|ecdsa-sha2-nistp(256|384|521)|ssh-rsa) [A-Za-z0-9+/=]+( [^[:cntrl:]]*)?$' -- "$file" ||
    oc_die "$file is not a plain public key line (key options and unknown key types are refused)"
  ssh-keygen -l -f "$file" >/dev/null 2>&1 || oc_die "$file could not be parsed by ssh-keygen"
  type=$(awk '{print $1; exit}' "$file")
  if [[ $type == ssh-rsa ]]; then
    bits=$(ssh-keygen -l -f "$file" | awk '{print $1; exit}')
    ((bits >= 3072)) || oc_die "$file is an RSA key of $bits bits; use ed25519 or RSA of at least 3072 bits"
  fi
}

# oc_pubkey_line FILE: the key line without leading or trailing space.
oc_pubkey_line() {
  awk '!/^[[:space:]]*(#|$)/ {sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print; exit}' "$1"
}
