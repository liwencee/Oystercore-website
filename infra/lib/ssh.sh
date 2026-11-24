#!/usr/bin/env bash
# SSH hardening: keys only, no root, named admins only, non-default port.
# Sourced by bootstrap.sh. Needs lib/common.sh and lib/users.sh (admins exist first).
#
# Lock-out safety, in order:
#  1. every admin key is validated and installed before the new rules are applied;
#  2. the new rules are checked with `sshd -t`, first on their own and then in place;
#  3. the effective rules (`sshd -T`) must match what was asked for;
#  4. after the switch, sshd must be listening on the new port, or the old rules come back;
#  5. a running session is never cut: restarting sshd leaves open sessions alone.
# shellcheck shell=bash

# The one place that decides who may sign in. Task 4 adds the restricted deploy user here.
ssh_allowed_users() { printf '%s' "${OC_ADMIN_NAMES[*]}"; }

ssh_render_dropin() {
  cat <<EOF
# Managed by infra/bootstrap.sh (lib/ssh.sh). Change infra/server.env and rerun the bootstrap.
# The 00- prefix matters: sshd keeps the FIRST value it reads, and cloud images ship
# drop-ins (for example 50-cloud-init.conf) that switch passwords back on.
Port $OC_SSH_PORT
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PubkeyAuthentication yes
AuthenticationMethods publickey
AllowUsers $(ssh_allowed_users)
MaxAuthTries 3
LoginGraceTime 30
MaxStartups 10:30:60
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
AllowStreamLocalForwarding no
PermitTunnel no
GatewayPorts no
PermitUserEnvironment no
HostbasedAuthentication no
IgnoreRhosts yes
UseDNS no
LogLevel VERBOSE
ClientAliveInterval 300
ClientAliveCountMax 2
# Ciphers, key exchange and MACs stay at the OpenSSH 9.6 defaults: they are already
# modern, and a hand-edited list ages worse than the vendor's.
EOF
}

# ssh_port_listening PORT: is anything listening on that TCP port?
ssh_port_listening() {
  ss -H -ltn 2>/dev/null | awk -v p=":$1" '$4 ~ (p "$") {found = 1} END {exit !found}'
}

# ssh_effective KEY: the value of KEY in the effective configuration. sshd -T prints a
# key that takes several values (AllowUsers) once per value, so the values are joined.
ssh_effective() {
  sshd -T 2>/dev/null | awk -v k="$1" '$1 == k {$1 = ""; sub(/^ /, ""); v = (v == "" ? $0 : v " " $0)} END {print v}'
}

ssh_require_admin_ready() {
  local name home status
  for name in "${OC_ADMIN_NAMES[@]}"; do
    home=$(getent passwd "$name" | cut -d: -f6)
    [[ -s $home/.ssh/authorized_keys ]] || oc_die "$name has no authorized key; refusing to change SSH (it would lock the admin out)"
    ssh-keygen -l -f "$home/.ssh/authorized_keys" >/dev/null 2>&1 || oc_die "the authorized key of $name does not parse; refusing to change SSH"
    [[ $(stat -c %U -- "$home/.ssh/authorized_keys") == "$name" ]] || oc_die "authorized_keys of $name has the wrong owner"
    if [[ $OC_SUDO_PASSWORDLESS == no ]]; then
      status=$(passwd -S "$name" 2>/dev/null | awk '{print $2}')
      [[ $status == P ]] || oc_die "OC_SUDO_PASSWORDLESS=no but $name has no password, so sudo would be impossible. Run 'passwd $name' as root first."
    fi
  done
  visudo -c >/dev/null 2>&1 || oc_die "the sudoers files do not validate; refusing to change SSH"
}

# ssh_assert_effective: the live rules say what we asked for. Catches a drop-in that is
# not included, or an earlier file that overrides ours.
ssh_assert_effective() {
  local got want key
  declare -A expect=(
    [port]=$OC_SSH_PORT
    [permitrootlogin]=no
    [passwordauthentication]=no
    [kbdinteractiveauthentication]=no
    [pubkeyauthentication]=yes
    [maxauthtries]=3
    [x11forwarding]=no
    [allowagentforwarding]=no
  )
  for key in "${!expect[@]}"; do
    got=$(ssh_effective "$key")
    want=${expect[$key]}
    [[ $got == "$want" ]] || oc_die "sshd would use '$key $got' instead of '$key $want'. Another file in /etc/ssh overrides $OC_SSHD_DROPIN; nothing was reloaded."
  done
  got=$(ssh_effective allowusers | tr ' ' '\n' | sort | tr '\n' ' ')
  want=$(printf '%s\n' "${OC_ADMIN_NAMES[@]}" | sort | tr '\n' ' ')
  [[ $got == "$want" ]] || oc_die "sshd would allow '$got' instead of '$want'; nothing was reloaded."
}

ssh_restore() {
  local backup=$1 had=$2
  if [[ $had == yes ]]; then
    cp -p -- "$backup" "$OC_SSHD_DROPIN"
  else
    rm -f -- "$OC_SSHD_DROPIN"
  fi
}

# ssh_activate: make the running sshd use the new port. Ubuntu 24.04 starts sshd from
# ssh.socket, which listens on port 22 whatever sshd_config says, so the socket is
# switched off (and masked, so a package upgrade cannot bring it back) and ssh.service
# listens by itself.
ssh_activate() {
  if systemctl cat ssh.socket >/dev/null 2>&1; then
    systemctl disable ssh.socket >/dev/null 2>&1 || true
    systemctl enable ssh.service >/dev/null 2>&1
    systemctl daemon-reload
    systemctl stop ssh.socket || true
    systemctl mask ssh.socket >/dev/null 2>&1
  else
    systemctl enable ssh.service >/dev/null 2>&1
  fi
  systemctl restart ssh.service
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if ssh_port_listening "$OC_SSH_PORT"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

ssh_apply() {
  local cand backup had=no before=$OC_CHANGES
  [[ -x /usr/sbin/sshd ]] || oc_die "openssh-server is not installed"
  grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config ||
    oc_die "/etc/ssh/sshd_config does not include sshd_config.d; refusing to continue (the hardening file would be ignored)"
  ssh-keygen -A >/dev/null
  if oc_container_mode; then
    install -d -m 0755 /run/sshd
  fi
  ssh_require_admin_ready

  # 1. the candidate must be valid on its own
  oc_mktemp_into cand
  ssh_render_dropin >"$cand"
  sshd -t -f "$cand" || oc_die "the new SSH rules are not valid; nothing was changed"

  # 2. put it in place, check the whole configuration, and undo on any problem
  oc_mktemp_into backup
  if [[ -f $OC_SSHD_DROPIN ]]; then
    cp -p -- "$OC_SSHD_DROPIN" "$backup"
    had=yes
  fi
  oc_install_stdin "$OC_SSHD_DROPIN" 0644 root root <"$cand"
  if ! sshd -t; then
    ssh_restore "$backup" "$had"
    oc_die "the SSH configuration does not validate with the new rules; the old rules were restored"
  fi
  if ! (ssh_assert_effective); then
    ssh_restore "$backup" "$had"
    oc_die "the effective SSH rules are not what was asked for; the old rules were restored"
  fi

  if oc_container_mode; then
    oc_log "container: SSH rules written and validated; sshd not restarted"
    return 0
  fi

  # 3. activate, unless nothing changed and sshd already behaves as configured
  if [[ $OC_CHANGES -eq $before ]] && ssh_port_listening "$OC_SSH_PORT" &&
    { [[ $OC_SSH_PORT -eq 22 ]] || ! ssh_port_listening 22; }; then
    oc_log "SSH already running as configured on port $OC_SSH_PORT"
    return 0
  fi
  if ssh_port_listening "$OC_SSH_PORT" && ! systemctl is-active --quiet ssh.service; then
    ssh_restore "$backup" "$had"
    oc_die "port $OC_SSH_PORT is already used by something other than sshd; the old rules were restored"
  fi
  if ! ssh_activate; then
    ssh_restore "$backup" "$had"
    systemctl restart ssh.service || true
    oc_die "sshd did not start listening on port $OC_SSH_PORT. The old rules were restored. Check 'journalctl -u ssh' BEFORE you close this session."
  fi
  oc_log "sshd listens on port $OC_SSH_PORT"
}
