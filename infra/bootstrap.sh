#!/usr/bin/env bash
# OysterCore server bootstrap: sets up and hardens a fresh Ubuntu 24.04 VPS (spec sections
# 5 and 10.9). Run as root, from a checkout of this repository:
#
#     cp infra/server.env.example infra/server.env     # then edit it
#     sudo bash infra/bootstrap.sh
#     sudo bash infra/verify.sh
#
# It is idempotent: a second run changes nothing (the last line says "changes=0"), and it
# never regenerates a secret. It never prints a secret.
#
# Usage: bootstrap.sh [--config FILE]     (default: infra/server.env, or $OC_CONFIG)
#
# Environment (for tests only): OC_CONTAINER=1 writes every file but skips what needs a
# kernel or systemd; OC_CF_IPS_DIR=<dir> reads Cloudflare's ips-v4 and ips-v6 from a
# folder instead of the network; OC_SKIP_LYNIS=1 skips the final Lynis run.
set -Eeuo pipefail
export LC_ALL=C
umask 022

OC_INFRA_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

# shellcheck source=lib/common.sh
source "$OC_INFRA_DIR/lib/common.sh"
# shellcheck source=lib/packages.sh
source "$OC_INFRA_DIR/lib/packages.sh"
# shellcheck source=lib/users.sh
source "$OC_INFRA_DIR/lib/users.sh"
# shellcheck source=lib/firewall.sh
source "$OC_INFRA_DIR/lib/firewall.sh"
# shellcheck source=lib/nginx.sh
source "$OC_INFRA_DIR/lib/nginx.sh"
# shellcheck source=lib/ssh.sh
source "$OC_INFRA_DIR/lib/ssh.sh"
# shellcheck source=lib/containers.sh
source "$OC_INFRA_DIR/lib/containers.sh"
# shellcheck source=lib/services.sh
source "$OC_INFRA_DIR/lib/services.sh"

trap oc_cleanup EXIT
trap 'printf "[oc] ERROR: the bootstrap stopped at %s line %s. Nothing already done is rolled back; fix the cause and rerun it (it is safe to rerun).\n" "${BASH_SOURCE[0]##*/}" "$LINENO" >&2' ERR

usage() {
  sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

oc_step() { printf '\n[oc] == %s ==\n' "$*"; }

check_os() {
  local id version codename
  id=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')
  version=$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"')
  codename=$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release | tr -d '"')
  [[ $id == ubuntu && $version == 24.04 && $codename == noble ]] ||
    oc_die "this setup is written for Ubuntu 24.04 LTS (found $id $version)"
}

print_next_steps() {
  local step
  printf '\n[oc] =============================== NEXT STEPS ===============================\n'
  printf '[oc] 1. Do NOT close this session yet. Open a SECOND terminal and sign in:\n'
  printf '[oc]      ssh -p %s %s@<server address>\n' "$OC_SSH_PORT" "${OC_ADMIN_NAMES[0]}"
  printf '[oc]    Root login and passwords are now off. If Hostinger'"'"'s own firewall (hPanel) is\n'
  printf '[oc]    switched on, allow TCP port %s there as well, or you cannot get in.\n' "$OC_SSH_PORT"
  printf '[oc] 2. Then run: sudo bash infra/verify.sh\n'
  if [[ $OC_SUDO_PASSWORDLESS == no ]]; then
    printf '[oc] 3. sudo asks for a password (OC_SUDO_PASSWORDLESS=no); each admin set one before this run.\n'
  fi
  printf '[oc] -  The app containers (oc-cms-<env>, oc-web-<env>) are defined but NOT started: there\n'
  printf '[oc]    is no image yet. The first deploy loads the images and starts them; after that they\n'
  printf '[oc]    start at boot. Their Quadlet files are in /home/oc-<env>/.config/containers/systemd/.\n'
  for step in "${OC_NEXT_STEPS[@]}"; do
    printf '[oc] -  %s\n' "$step"
  done
  if [[ -f /var/run/reboot-required ]]; then
    printf '[oc] -  A reboot is pending (kernel or library updates). Reboot in a quiet moment, after step 1.\n'
  fi
  printf '[oc] ============================================================================\n'
}

main() {
  local config=${OC_CONFIG:-$OC_INFRA_DIR/server.env} i
  while [[ $# -gt 0 ]]; do
    case $1 in
      --config)
        [[ $# -ge 2 ]] || oc_die "--config needs a file"
        config=$2
        shift 2
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) oc_die "unknown argument: $1 (try --help)" ;;
    esac
  done

  oc_step "checking this machine and the settings"
  oc_require_root
  oc_check_mode
  check_os
  oc_load_config "$config"
  oc_validate_config
  if ! oc_have ssh-keygen; then
    DEBIAN_FRONTEND=noninteractive apt-get -y -qq install --no-install-recommends openssh-client >/dev/null
  fi
  for i in "${!OC_ADMIN_NAMES[@]}"; do
    oc_validate_pubkey "${OC_ADMIN_KEYS[$i]}"
  done
  oc_log "domain $OC_DOMAIN, environments: ${OC_ENV_LIST[*]}, admins: ${OC_ADMIN_NAMES[*]}, SSH port $OC_SSH_PORT"
  if oc_container_mode; then
    oc_log "TEST CONTAINER MODE: files are written, kernel and systemd steps are skipped"
  fi

  oc_step "packages"
  pkg_install_all

  oc_step "users, folders and secrets"
  users_ensure_system_group "$OC_CLAMD_GROUP"
  for i in "${OC_ENV_LIST[@]}"; do
    users_ensure_env_user "$i"
  done
  users_ensure_dirs
  for i in "${OC_ENV_LIST[@]}"; do
    users_ensure_env_files "$i"
  done

  oc_step "rootless Podman for each environment"
  # Before the admins exist: the environment users take the first subuid and subgid blocks.
  for i in "${OC_ENV_LIST[@]}"; do
    ctr_setup_env "$i"
  done

  oc_step "admins and sudo"
  users_ensure_admins
  users_ensure_sudo

  oc_step "MariaDB"
  svc_mariadb
  svc_databases

  oc_step "ClamAV"
  svc_clamav

  oc_step "Nginx, Cloudflare ranges and certificates"
  fw_load_cloudflare_ips
  nginx_ensure_ca
  nginx_ensure_origin_cert
  nginx_update_realip
  nginx_install_site

  oc_step "the weekly Cloudflare refresh"
  svc_install_units

  oc_step "firewall rules (not yet active)"
  fw_baseline
  fw_add_ssh_rule
  fw_sync_cloudflare

  oc_step "SSH"
  ssh_apply

  oc_step "firewall activation"
  fw_prune_unmanaged
  fw_enable

  oc_step "operating system hardening"
  svc_fail2ban
  svc_unattended_upgrades
  svc_auditd
  svc_sysctl
  svc_journald
  svc_swap
  svc_time
  svc_disable_unused

  oc_step "Lynis"
  svc_lynis

  print_next_steps
  oc_log "DONE changes=$OC_CHANGES"
}

main "$@"
