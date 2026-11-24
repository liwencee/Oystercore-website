#!/usr/bin/env bash
# Checks this server against spec section 10.9 and fails loudly. Run as root, after the
# bootstrap, after every change to infra/, and monthly:
#
#     sudo bash infra/verify.sh
#
# Output: one line per check, "PASS <ID> <text>", "FAIL <ID> <text>", "WARN <ID> <text>"
# or "SKIP <ID> <text>", then a SUMMARY line. The exit code is 1 if any check failed.
# Secrets are never printed. A check that cannot run FAILs: it never passes by default.
#
# Environment:
#   OC_CONFIG=<file>      settings (default: infra/server.env)
#   VERIFY_CONTAINER=1    the test container has no kernel or systemd to ask, so checks
#                         read the written configuration instead of live state, and the
#                         checks marked (kernel) print SKIP.
#   VERIFY_DEBUG=1        show the error output of the commands the checks run.
set -uo pipefail
export LC_ALL=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

OC_INFRA_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib/common.sh
source "$OC_INFRA_DIR/lib/common.sh"
# shellcheck source=lib/users.sh
source "$OC_INFRA_DIR/lib/users.sh"
# shellcheck source=lib/packages.sh
source "$OC_INFRA_DIR/lib/packages.sh"

VERIFY_CONTAINER=${VERIFY_CONTAINER:-0}
CUR=""

pass() { printf 'PASS %s %s\n' "$CUR" "$*"; }
fail() { printf 'FAIL %s %s\n' "$CUR" "$*"; }
warn() { printf 'WARN %s %s\n' "$CUR" "$*"; }
skip() { printf 'SKIP %s %s\n' "$CUR" "$*"; }

in_container() { [[ $VERIFY_CONTAINER == 1 ]]; }

# kernel_skip: for checks that need a kernel or systemd. Returns 0 (and prints SKIP) in
# container mode, so the caller can return at once.
kernel_skip() {
  if in_container; then
    skip "(kernel) not checked in container mode"
    return 0
  fi
  return 1
}

# word_in LIST WORD: is WORD one of the space-separated words of LIST?
word_in() { [[ " $1 " == *" $2 "* ]]; }

# sorted_words "a b c": the words sorted and joined by single spaces.
sorted_words() {
  local -a w=()
  read -r -a w <<<"$1"
  [[ ${#w[@]} -gt 0 ]] || return 0
  printf '%s\n' "${w[@]}" | sort | tr '\n' ' ' | sed 's/ $//'
}

# --- facts read once (the checks run in subshells and inherit these) ---------------
SSHD_T=""
NGINX_T=""
NGINX_SERVERS=""

load_facts() {
  if oc_have sshd; then
    SSHD_T=$(sshd -T 2>/dev/null) || SSHD_T=""
  fi
  if oc_have nginx; then
    NGINX_T=$(nginx -T 2>/dev/null) || NGINX_T=""
  fi
  if [[ -n $NGINX_T ]]; then
    NGINX_SERVERS=$(nginx_servers <<<"$NGINX_T")
  fi
}

sshd_val() { awk -v k="$1" '$1 == k {$1 = ""; sub(/^ /, ""); v = (v == "" ? $0 : v " " $0)} END {print v}' <<<"$SSHD_T"; }

# nginx_servers: one line per server block of `nginx -T`:
#   names|ssl|default|reject|verify_client|client_certificate|ssl_protocols
# Only directives written directly in the server block count, not those in locations.
nginx_servers() {
  awk '
    {
      line = $0
      sub(/[ \t]*#.*$/, "", line)
      if (!in_server && line ~ /^[ \t]*server[ \t]*\{[ \t]*$/) {
        in_server = 1; sdepth = depth + 1; depth++
        names = ""; ssl = 0; def = 0; rej = 0; ver = ""; cc = ""; proto = ""
        next
      }
      o = gsub(/\{/, "{", line); c = gsub(/\}/, "}", line)
      if (in_server && depth == sdepth) {
        if (line ~ /^[ \t]*listen[ \t]/) {
          if (line ~ /[ \t]ssl([ \t;]|$)/) ssl = 1
          if (line ~ /default_server/) def = 1
        } else if (line ~ /^[ \t]*server_name[ \t]/) {
          t = line; sub(/^[ \t]*server_name[ \t]+/, "", t); sub(/[ \t]*;.*$/, "", t); names = t
        } else if (line ~ /^[ \t]*ssl_reject_handshake[ \t]+on[ \t]*;/) {
          rej = 1
        } else if (line ~ /^[ \t]*ssl_verify_client[ \t]/) {
          t = line; sub(/^[ \t]*ssl_verify_client[ \t]+/, "", t); sub(/[ \t]*;.*$/, "", t); ver = t
        } else if (line ~ /^[ \t]*ssl_client_certificate[ \t]/) {
          t = line; sub(/^[ \t]*ssl_client_certificate[ \t]+/, "", t); sub(/[ \t]*;.*$/, "", t); cc = t
        } else if (line ~ /^[ \t]*ssl_protocols[ \t]/) {
          t = line; sub(/^[ \t]*ssl_protocols[ \t]+/, "", t); sub(/[ \t]*;.*$/, "", t); proto = t
        }
      }
      depth += o - c
      if (in_server && depth < sdepth) {
        print names "|" ssl "|" def "|" rej "|" ver "|" cc "|" proto
        in_server = 0
      }
    }
  '
}

# --- SSH ---------------------------------------------------------------------------
need_sshd() {
  if [[ -z $SSHD_T ]]; then
    fail "cannot read the effective sshd configuration (is openssh-server installed? does sshd -T work?)"
    return 1
  fi
}

check_ssh_01() {
  local pw kbd am
  need_sshd || return 0
  pw=$(sshd_val passwordauthentication)
  kbd=$(sshd_val kbdinteractiveauthentication)
  am=$(sshd_val authenticationmethods)
  if [[ $pw == no && $kbd == no && $am == publickey ]]; then
    pass "password login is off; only public keys are accepted"
  else
    fail "password login is not fully off (passwordauthentication=$pw, kbdinteractiveauthentication=$kbd, authenticationmethods=$am)"
  fi
}

check_ssh_02() {
  local v
  need_sshd || return 0
  v=$(sshd_val permitrootlogin)
  if [[ $v == no ]]; then pass "root login is off"; else fail "permitrootlogin is '$v', not 'no'"; fi
}

check_ssh_03() {
  local got want name home bad=""
  need_sshd || return 0
  got=$(sorted_words "$(sshd_val allowusers)")
  want=$(sorted_words "${OC_ADMIN_NAMES[*]}")
  if [[ $got != "$want" ]]; then
    fail "AllowUsers is '$got', the admins in server.env are '$want'"
    return 0
  fi
  for name in "${OC_ADMIN_NAMES[@]}"; do
    home=$(getent passwd "$name" | cut -d: -f6)
    if [[ -z $home || ! -s $home/.ssh/authorized_keys ]]; then
      bad+=" $name"
    fi
  done
  if [[ -n $bad ]]; then
    fail "admin(s) without a user or an authorized key:$bad"
  else
    pass "only the named admins may sign in: $got"
  fi
}

check_ssh_04() {
  local ports
  need_sshd || return 0
  ports=$(awk '$1 == "port" {print $2}' <<<"$SSHD_T" | tr '\n' ' ' | sed 's/ $//')
  if [[ $ports != "$OC_SSH_PORT" ]]; then
    fail "sshd ports are '$ports', expected only $OC_SSH_PORT"
    return 0
  fi
  if [[ $ports == 22 ]]; then
    fail "sshd uses the default port 22"
    return 0
  fi
  if in_container; then
    pass "sshd is set to port $ports, not 22 (configuration)"
    return 0
  fi
  if ! oc_have ss; then
    fail "ss is missing, so the live listener cannot be checked"
    return 0
  fi
  if ! ss -H -ltn | awk -v p=":$ports" '$4 ~ (p "$") {f = 1} END {exit !f}'; then
    fail "nothing is listening on port $ports"
  elif ss -H -ltn | awk '$4 ~ /:22$/ {f = 1} END {exit !f}'; then
    fail "something still listens on port 22"
  else
    pass "sshd listens on port $ports and nothing listens on 22"
  fi
}

check_ssh_05() {
  local key want got bad=""
  need_sshd || return 0
  declare -A expect=(
    [maxauthtries]=3 [x11forwarding]=no [allowagentforwarding]=no [allowtcpforwarding]=no
    [permitemptypasswords]=no [hostbasedauthentication]=no [pubkeyauthentication]=yes
  )
  for key in "${!expect[@]}"; do
    want=${expect[$key]}
    got=$(sshd_val "$key")
    [[ $got == "$want" ]] || bad+=" $key=$got(want $want)"
  done
  if [[ -n $bad ]]; then fail "SSH settings differ:$bad"; else pass "MaxAuthTries 3, no X11, agent or TCP forwarding, no empty passwords"; fi
}

# --- network -----------------------------------------------------------------------
check_net_01() {
  local v
  if ! oc_have ufw; then
    fail "ufw is not installed"
    return 0
  fi
  if ! grep -q '^DEFAULT_INPUT_POLICY="DROP"' /etc/default/ufw 2>/dev/null ||
    ! grep -q '^DEFAULT_OUTPUT_POLICY="ACCEPT"' /etc/default/ufw 2>/dev/null; then
    fail "/etc/default/ufw does not deny incoming and allow outgoing by default"
    return 0
  fi
  if in_container; then
    pass "ufw is set to deny incoming and allow outgoing (configuration)"
    return 0
  fi
  v=$(ufw status verbose 2>/dev/null)
  if [[ $v != *"Status: active"* ]]; then
    fail "ufw is not active"
  elif [[ $v != *"Default: deny (incoming), allow (outgoing)"* ]]; then
    fail "ufw's live default policy is not deny incoming, allow outgoing"
  else
    pass "ufw is active and denies inbound traffic by default"
  fi
}

# cf_ranges: the Cloudflare ranges Nginx trusts, one per line (the refresh keeps this file
# and the firewall in step).
cf_ranges() {
  sed -n 's/^set_real_ip_from \(.*\);$/\1/p' "$OC_NGINX_REALIP" 2>/dev/null | sort -u
}

check_net_02() {
  local line key cidr bad="" n=0 want have status
  local -A fw=()
  kernel_skip && return 0
  want=$(cf_ranges)
  if [[ -z $want ]]; then
    fail "no Cloudflare ranges in $OC_NGINX_REALIP"
    return 0
  fi
  status=$(ufw status 2>/dev/null || true)
  if [[ $status != "Status: active"* ]]; then
    fail "ufw is not active"
    return 0
  fi
  while IFS= read -r line; do
    [[ $line == "ufw "* ]] || continue
    key=${line% comment *}
    if [[ $key == "ufw allow $OC_SSH_PORT/tcp" ]]; then
      continue
    elif [[ $key =~ ^ufw\ allow\ from\ ([^ ]+)\ to\ any\ port\ 80,443\ proto\ tcp$ ]]; then
      cidr=${BASH_REMATCH[1]}
      fw[$cidr]=1
      n=$((n + 1))
    else
      bad+=" [$key]"
    fi
  done < <(ufw show added 2>/dev/null)
  if [[ -n $bad ]]; then
    fail "firewall rules other than SSH and Cloudflare ports 80/443:$bad"
    return 0
  fi
  have=$(printf '%s\n' "${!fw[@]}" | sort -u)
  if [[ $have != "$want" ]]; then
    fail "the firewall's Cloudflare ranges differ from the list Nginx trusts (run oc-cloudflare-ips)"
    return 0
  fi
  pass "ports 80 and 443 are open only to the $n Cloudflare ranges; SSH is the only other open port"
}

check_net_03() {
  local line names ssl rej ver cc proto n=0 bad=""
  if [[ -z $NGINX_SERVERS ]]; then
    fail "cannot read the Nginx configuration (is nginx installed and does nginx -T pass?)"
    return 0
  fi
  while IFS='|' read -r names ssl _ rej ver cc proto; do
    [[ $ssl == 1 && $rej == 0 ]] || continue
    n=$((n + 1))
    if [[ $ver != on ]]; then
      bad+=" [$names: ssl_verify_client '$ver']"
    elif [[ -z $cc || ! -f $cc ]]; then
      bad+=" [$names: client certificate file missing]"
    elif ! cmp -s -- "$cc" "$OC_INFRA_DIR/nginx/cloudflare-origin-pull-ca.pem"; then
      bad+=" [$names: client CA differs from infra/nginx/cloudflare-origin-pull-ca.pem]"
    fi
  done <<<"$NGINX_SERVERS"
  if ((n == 0)); then
    fail "no TLS site is configured in Nginx"
    return 0
  fi
  if [[ -n $bad ]]; then
    fail "Nginx does not require Cloudflare's client certificate:$bad"
    return 0
  fi
  if in_container; then
    pass "all $n TLS sites require Cloudflare's client certificate (configuration)"
    return 0
  fi
  line=$(echo "$NGINX_SERVERS" | awk -F'|' '$2 == 1 && $4 == 0 {split($1, a, " "); print a[1]; exit}')
  if ! systemctl is-active --quiet nginx; then
    fail "nginx is not running"
    return 0
  fi
  if [[ $(curl -sk --max-time 10 -o /dev/null -w '%{http_code}' --resolve "$line:443:127.0.0.1" "https://$line/" 2>/dev/null) != 400 ]]; then
    fail "a request without a client certificate to $line was not refused"
    return 0
  fi
  pass "all $n TLS sites require Cloudflare's client certificate; a request without one is refused"
}

check_ngx_01() {
  local names ssl rej ver cc proto p bad=""
  if [[ -z $NGINX_SERVERS ]]; then
    fail "cannot read the Nginx configuration"
    return 0
  fi
  while IFS='|' read -r names ssl _ rej ver cc proto; do
    [[ $ssl == 1 ]] || continue
    [[ -n $proto ]] || bad+=" [$names: no ssl_protocols]"
    for p in $proto; do
      [[ $p == TLSv1.2 || $p == TLSv1.3 ]] || bad+=" [$names: allows $p]"
    done
  done <<<"$NGINX_SERVERS"
  grep -Eq '^[[:space:]]*server_tokens[[:space:]]+off;' <<<"$NGINX_T" || bad+=" [server_tokens is not off]"
  grep -Eq '^[[:space:]]*server_tokens[[:space:]]+(on|build);' <<<"$NGINX_T" && bad+=" [server_tokens is switched on somewhere]"
  grep -Eq '^[[:space:]]*client_max_body_size[[:space:]]+30m;' <<<"$NGINX_T" || bad+=" [client_max_body_size 30m missing]"
  grep -Eq '^[[:space:]]*client_body_timeout[[:space:]]' <<<"$NGINX_T" || bad+=" [client_body_timeout missing]"
  grep -Eq '^[[:space:]]*client_header_timeout[[:space:]]' <<<"$NGINX_T" || bad+=" [client_header_timeout missing]"
  if [[ -n $bad ]]; then
    fail "Nginx limits or TLS settings are wrong:$bad"
  else
    pass "TLS 1.2 or newer only, no version banner, 30 MB request limit, body and header timeouts set"
  fi
}

check_net_04() {
  local pd bind listeners bad=""
  if ! oc_have mariadbd; then
    fail "mariadbd is not installed"
    return 0
  fi
  pd=$(mariadbd --print-defaults 2>/dev/null)
  bind=$(grep -o -- '--bind[-_]address=[^ ]*' <<<"$pd" | tail -n 1 | cut -d= -f2)
  if [[ $bind != 127.0.0.1 && $bind != ::1 && $bind != localhost ]]; then
    fail "MariaDB bind-address is '${bind:-unset}', not localhost"
    return 0
  fi
  if ! oc_have ss; then
    fail "ss is missing, so the live listener cannot be checked"
    return 0
  fi
  listeners=$(ss -H -ltn | awk '$4 ~ /:3306$/ {print $4}')
  if [[ -z $listeners ]]; then
    fail "MariaDB is not listening on 3306 (is it running?)"
    return 0
  fi
  while IFS= read -r l; do
    [[ $l == 127.0.0.1:3306 || $l == '[::1]:3306' ]] || bad+=" $l"
  done <<<"$listeners"
  if [[ -n $bad ]]; then
    fail "MariaDB listens on more than localhost:$bad"
  else
    pass "MariaDB is bound to $bind only"
  fi
}

check_net_05() {
  local conf=/etc/clamav/clamd.conf sock grp mode u bad="" dropin
  if [[ ! -f $conf ]]; then
    fail "$conf is missing (is clamav-daemon installed?)"
    return 0
  fi
  sock=$(awk '$1 == "LocalSocket" {v = $2} END {print v}' "$conf")
  grp=$(awk '$1 == "LocalSocketGroup" {v = $2} END {print v}' "$conf")
  mode=$(awk '$1 == "LocalSocketMode" {v = $2} END {print v}' "$conf")
  [[ $sock == "$OC_CLAMD_SOCKET" ]] || bad+=" [LocalSocket '${sock:-unset}']"
  if grep -Eq '^[[:space:]]*(TCPSocket|TCPAddr)[[:space:]]' "$conf"; then bad+=" [TCPSocket or TCPAddr is set]"; fi
  [[ $grp == "$OC_CLAMD_GROUP" ]] || bad+=" [LocalSocketGroup '${grp:-unset}']"
  if [[ ! $mode =~ ^[0-7]{3}$ ]] || ((8#$mode & 8#007)); then bad+=" [LocalSocketMode '${mode:-unset}' is not closed to others]"; fi
  dropin=/etc/systemd/system/clamav-daemon.socket.d/oc.conf
  if ! grep -q "^SocketGroup=$OC_CLAMD_GROUP\$" "$dropin" 2>/dev/null || ! grep -q '^SocketMode=0660$' "$dropin" 2>/dev/null; then
    bad+=" [$dropin does not set the socket group and mode]"
  fi
  # No systemd socket unit may listen on a TCP port.
  if grep -hE '^ListenStream=[^/]' /usr/lib/systemd/system/clamav-daemon.socket /lib/systemd/system/clamav-daemon.socket \
    /etc/systemd/system/clamav-daemon.socket.d/*.conf /run/systemd/generator/clamav-daemon.socket.d/*.conf 2>/dev/null | grep -q .; then
    bad+=" [a socket unit listens on a TCP port]"
  fi
  for u in "${OC_ENV_LIST[@]}"; do
    oc_in_group "oc-$u" "$OC_CLAMD_GROUP" || bad+=" [oc-$u cannot reach the socket]"
  done
  if ! in_container; then
    if ss -H -ltn | awk '$4 ~ /:3310$/ {f = 1} END {exit !f}'; then bad+=" [something listens on TCP 3310]"; fi
    if [[ -S $sock ]]; then
      [[ $(stat -c '%G %a' -- "$sock") == "$OC_CLAMD_GROUP 660" ]] || bad+=" [the live socket is not $OC_CLAMD_GROUP 660]"
    else
      bad+=" [the socket $sock does not exist; is clamd running?]"
    fi
  fi
  if [[ -n $bad ]]; then
    fail "clamd is not limited to a local socket:$bad"
  elif in_container; then
    pass "clamd listens on the unix socket $sock only (group $grp, mode $mode); no TCP (configuration)"
  else
    pass "clamd listens on the unix socket $sock only (group $grp, mode $mode); no TCP"
  fi
}

check_net_06() {
  local addr host port bad=""
  kernel_skip && return 0
  if ! oc_have ss; then
    fail "ss is missing, so the listening ports cannot be checked"
    return 0
  fi
  while IFS= read -r addr; do
    [[ -n $addr ]] || continue
    host=${addr%:*}
    port=${addr##*:}
    case $host in 127.* | "[::1]") continue ;; *) ;; esac
    case $port in "$OC_SSH_PORT" | 80 | 443) continue ;; *) ;; esac
    bad+=" $addr"
  done < <(ss -H -ltn | awk '{print $4}')
  if [[ -n $bad ]]; then
    fail "unexpected network listeners (only SSH $OC_SSH_PORT, 80 and 443 may listen beyond localhost):$bad"
  else
    pass "the only listeners beyond localhost are SSH ($OC_SSH_PORT), 80 and 443"
  fi
}

# --- operating system --------------------------------------------------------------
check_os_01() {
  local cfg
  if ! dpkg -s unattended-upgrades >/dev/null 2>&1; then
    fail "unattended-upgrades is not installed"
    return 0
  fi
  cfg=$(apt-config dump 2>/dev/null)
  if ! grep -q 'APT::Periodic::Unattended-Upgrade "1";' <<<"$cfg" || ! grep -q 'APT::Periodic::Update-Package-Lists "1";' <<<"$cfg"; then
    fail "automatic security updates are not switched on in the apt configuration"
    return 0
  fi
  if ! in_container; then
    if ! systemctl is-enabled --quiet apt-daily-upgrade.timer 2>/dev/null || ! systemctl is-active --quiet apt-daily-upgrade.timer 2>/dev/null; then
      fail "apt-daily-upgrade.timer is not enabled and active"
      return 0
    fi
  fi
  pass "unattended-upgrades is on (security updates, no automatic reboot)"
}

check_os_02() {
  kernel_skip && return 0
  if ! oc_have fail2ban-client; then
    fail "fail2ban is not installed"
  elif fail2ban-client status sshd >/dev/null 2>&1; then
    pass "the fail2ban sshd jail is active"
  else
    fail "the fail2ban sshd jail is not active"
  fi
}

check_os_03() {
  kernel_skip && return 0
  if [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null) == yes ]]; then
    pass "time sync is on and the clock is synchronised"
  else
    fail "the clock is not synchronised (timedatectl NTPSynchronized is not yes)"
  fi
}

check_os_04() {
  local k v want got bad="" n=0
  if [[ ! -f /etc/sysctl.d/99-oc-hardening.conf ]]; then
    fail "/etc/sysctl.d/99-oc-hardening.conf is missing"
    return 0
  fi
  while IFS='=' read -r k v; do
    k=$(oc_trim "$k")
    v=$(oc_trim "$v")
    [[ -n $k && $k != \#* ]] || continue
    n=$((n + 1))
    if ! in_container; then
      got=$(sysctl -n "$k" 2>/dev/null) || continue
      want=$v
      [[ $got == "$want" ]] || bad+=" $k=$got(want $want)"
    fi
  done </etc/sysctl.d/99-oc-hardening.conf
  grep -q '^kernel.randomize_va_space = 2$' /etc/sysctl.d/99-oc-hardening.conf || bad+=" [ASLR setting missing]"
  if [[ -n $bad ]]; then
    fail "kernel and network hardening is not in effect:$bad"
  elif in_container; then
    pass "sysctl hardening file is in place with $n settings (configuration)"
  else
    pass "sysctl hardening is in effect ($n settings)"
  fi
}

check_os_05() {
  kernel_skip && return 0
  if [[ -z $(swapon --show --noheadings 2>/dev/null) ]]; then
    fail "no swap is active"
  elif ! grep -qE '^[^#].*[[:space:]]swap[[:space:]]' /etc/fstab; then
    fail "swap is active but /etc/fstab has no swap entry, so it will not survive a reboot"
  else
    pass "swap is active ($(swapon --show=SIZE --noheadings | head -n 1 | tr -d ' '))"
  fi
}

check_os_06() {
  local f=/etc/audit/rules.d/oc.rules bad="" w loaded
  if [[ ! -f $f ]]; then
    fail "$f is missing (is auditd installed?)"
    return 0
  fi
  for w in '-w /etc/oc -p wa' '-w /etc/sudoers.d -p wa' '-w /var/log/lastlog -p wa' '-w /var/log/wtmp -p wa' '-w /etc/ssh/sshd_config.d -p wa'; do
    grep -q -- "^$w" "$f" || bad+=" [no rule: $w]"
  done
  if ! in_container; then
    systemctl is-active --quiet auditd || bad+=" [auditd is not running]"
    loaded=$(auditctl -l 2>/dev/null || true)
    [[ $loaded == *"/etc/oc"* ]] || bad+=" [the /etc/oc watch is not loaded]"
  fi
  if [[ -n $bad ]]; then
    fail "auditd does not watch logins, sudo and /etc/oc:$bad"
  elif in_container; then
    pass "auditd rules cover logins, sudo and /etc/oc (configuration)"
  else
    pass "auditd is running and watches logins, sudo and /etc/oc"
  fi
}

check_os_07() {
  local bad=""
  grep -q '^Storage=persistent$' /etc/systemd/journald.conf.d/oc.conf 2>/dev/null || bad+=" [journald is not persistent]"
  grep -q '^SystemMaxUse=' /etc/systemd/journald.conf.d/oc.conf 2>/dev/null || bad+=" [journald has no size limit]"
  grep -q '^MaxRetentionSec=' /etc/systemd/journald.conf.d/oc.conf 2>/dev/null || bad+=" [journald has no retention]"
  grep -rq 'logfile="/var/log/sudo.log"' /etc/sudoers.d 2>/dev/null || bad+=" [sudo does not log to /var/log/sudo.log]"
  [[ -f /etc/logrotate.d/oc-sudo ]] || bad+=" [no logrotate rule for the sudo log]"
  if [[ -f /var/log/sudo.log && $(stat -c '%a' /var/log/sudo.log) != 600 ]]; then bad+=" [sudo.log is not 0600]"; fi
  if [[ -n $bad ]]; then
    fail "logging is not set up:$bad"
  else
    pass "journald keeps persistent, rotated logs and the sudo log is kept and rotated"
  fi
}

check_os_08() {
  local u state bad=""
  kernel_skip && return 0
  for u in "${OC_UNUSED_UNITS[@]}"; do
    state=$(systemctl is-enabled "$u" 2>/dev/null || true)
    case $state in
      enabled | enabled-runtime | linked | linked-runtime | alias | generated | transient) bad+=" $u($state)" ;;
      *) ;;
    esac
    if systemctl is-active --quiet "$u" 2>/dev/null; then bad+=" $u(active)"; fi
  done
  if [[ -n $bad ]]; then
    fail "unused services are on:$bad"
  else
    pass "none of the ${#OC_UNUSED_UNITS[@]} unused services (snapd, cups, avahi, ...) is enabled or running"
  fi
}

# --- services and files ------------------------------------------------------------
# --- containers (rootless Podman, Quadlet) -----------------------------------------
# qvals FILE KEY: every value of KEY= in a Quadlet file (comment lines are not read).
qvals() { awk -v k="$2" 'index($0, k "=") == 1 {print substr($0, length(k) + 2)}' "$1"; }

# q_check_container FILE ENV ROLE: print one problem per line for a Quadlet container file.
q_check_container() {
  local f=$1 env=$2 role=$3 uid gid v n src dst opt arg bad
  uid=$(oc_env_uid "$env")
  gid=$(oc_env_gid "$env")
  [[ -n $uid && -n $gid ]] || {
    echo "user oc-$env does not exist"
    return 0
  }
  [[ $(qvals "$f" UserNS) == keep-id ]] || echo "UserNS is not keep-id"
  [[ $(qvals "$f" User) == "$uid" && $uid -ne 0 ]] || echo "User is not the environment user's id ($uid), or is root"
  [[ $(qvals "$f" Group) == "$gid" && $gid -ne 0 ]] || echo "Group is not the environment user's group ($gid), or is root"
  [[ $(qvals "$f" ReadOnly) == true ]] || echo "ReadOnly is not true"
  [[ $(qvals "$f" DropCapability) == ALL ]] || echo "DropCapability is not ALL"
  [[ $(qvals "$f" NoNewPrivileges) == true ]] || echo "NoNewPrivileges is not true"
  [[ $(qvals "$f" Tmpfs | head -n 1) == /tmp* ]] || echo "no Tmpfs for /tmp"
  v=$(qvals "$f" PidsLimit)
  [[ $v =~ ^[1-9][0-9]*$ ]] || echo "no PidsLimit (a positive number)"
  if ! qvals "$f" PodmanArgs | grep -Eq -- '(^|[[:space:]])--memory=[1-9][0-9]*[kmgKMG]?([[:space:]]|$)' &&
    ! qvals "$f" Memory | grep -Eq '^[1-9][0-9]*[kmgKMG]?$'; then
    echo "no memory limit"
  fi
  [[ $(qvals "$f" EnvironmentFile) == "$OC_SECRET_DIR/$env.env" ]] || echo "EnvironmentFile is not $OC_SECRET_DIR/$env.env"
  n=$(qvals "$f" Image | grep -c . || true)
  [[ $n -eq 1 ]] || echo "$n Image= lines (exactly one is needed)"
  qvals "$f" HealthCmd | grep -q '/app/healthcheck.mjs' || echo "no health check using /app/healthcheck.mjs"
  [[ $(qvals "$f" Network) == "oc-$env.network" ]] || echo "Network is not oc-$env.network (the private network)"
  n=0
  while IFS= read -r v; do
    [[ -n $v ]] || continue
    n=$((n + 1))
    [[ $v == 127.0.0.1:* ]] || echo "PublishPort '$v' is not on 127.0.0.1 only"
  done < <(qvals "$f" PublishPort)
  [[ $n -ge 1 ]] || echo "no PublishPort (the app would not be reachable by Nginx)"
  # Mounts: the environment's own data folder, and (CMS only) the MariaDB and ClamAV socket
  # folders read-only. Nothing else, and never a container socket.
  while IFS= read -r v; do
    [[ -n $v ]] || continue
    IFS=: read -r src dst opt <<<"$v"
    case $src in
      "$OC_DATA_ROOT/$env" | "$OC_DATA_ROOT/$env"/media | "$OC_DATA_ROOT/$env"/media/) ;;
      "$OC_MARIADB_RUN_DIR" | "$OC_CLAMD_RUN_DIR")
        [[ $role == cms ]] || echo "the website must not mount $src"
        [[ $opt == ro ]] || echo "$src must be mounted read-only"
        ;;
      *) echo "Volume source '$src' is not allowed" ;;
    esac
    [[ $dst == "$src" ]] || echo "Volume $src is mounted at a different path ($dst)"
  done < <(qvals "$f" Volume)
  if [[ $role == web ]]; then
    qvals "$f" Volume | grep -q "^$OC_DATA_ROOT/$env:" && echo "the website mounts the whole data folder; it needs only media, read-only"
  fi
  # No other way to widen the sandbox.
  for arg in AddCapability AddDevice Mount SecurityLabelDisable SecurityLabelType Rootfs Pod; do
    [[ -z $(qvals "$f" "$arg") ]] || echo "$arg is set"
  done
  while IFS= read -r v; do
    for arg in $v; do
      case $arg in
        --memory=* | --memory-swap=*) ;;
        --group-add=keep-groups) [[ $role == cms ]] || echo "the website must not keep the host's groups" ;;
        *) echo "PodmanArgs has '$arg', which is not on the allow-list" ;;
      esac
    done
  done < <(qvals "$f" PodmanArgs)
  bad=$(qvals "$f" Network | grep -c -- 'host' || true)
  [[ $bad -eq 0 ]] || echo "host networking"
}

check_ctr_01() {
  local env role f qdir p bad="" n=0 gen flags problems
  for env in "${OC_ENV_LIST[@]}"; do
    qdir=$(oc_env_quadlet_dir "$env")
    [[ -f $qdir/oc-$env.network ]] || bad+=" [$qdir/oc-$env.network missing]"
    for role in cms web; do
      f="$qdir/oc-$role-$env.container"
      if [[ ! -f $f ]]; then
        bad+=" [$f missing]"
        continue
      fi
      n=$((n + 1))
      while IFS= read -r p; do
        [[ -n $p ]] && bad+=" [oc-$role-$env: $p]"
      done < <(q_check_container "$f" "$env" "$role")
    done
    # Podman's own Quadlet generator must accept the files, and what it generates must carry
    # the flags (a second look, at what would really run).
    if [[ -x /usr/libexec/podman/quadlet ]]; then
      if ! gen=$(QUADLET_UNIT_DIRS="$qdir" /usr/libexec/podman/quadlet -dryrun -user 2>&1); then
        bad+=" [oc-$env: the Quadlet generator rejects the files]"
      elif problems=$(grep '^quadlet-generator' <<<"$gen" | grep -v 'Loading source unit file' || true) && [[ -n $problems ]]; then
        bad+=" [oc-$env: the Quadlet generator reports a problem: ${problems:0:120}]"
      else
        for role in cms web; do
          flags=$(grep -m1 "^ExecStart=/usr/bin/podman run .*--name=oc-$role-$env " <<<"$gen" || true)
          for p in '--read-only' '--cap-drop=all' '--security-opt=no-new-privileges' '--userns keep-id' '--pids-limit' '--memory=' '--publish 127.0.0.1:'; do
            [[ $flags == *"$p"* ]] || bad+=" [oc-$role-$env: generated command lacks $p]"
          done
        done
      fi
    else
      bad+=" [the Podman Quadlet generator (/usr/libexec/podman/quadlet) is missing]"
    fi
  done
  if [[ -n $bad ]]; then
    fail "container definitions are not safe:$bad"
  else
    pass "$n Quadlet files: non-root user mapping, read-only root, no capabilities, no-new-privileges, memory and pids limits, ports on 127.0.0.1 only, own data folder only, no container socket; Podman's generator accepts them"
  fi
}

check_ctr_02() {
  local env user file bad="" start count end
  for env in "${OC_ENV_LIST[@]}"; do
    user="oc-$env"
    for file in /etc/subuid /etc/subgid; do
      if ! awk -F: -v u="$user" -v c="$OC_SUBID_COUNT" '$1 == u && $3 >= c {f = 1} END {exit !f}' "$file" 2>/dev/null; then
        bad+=" [$user has no $file range of at least $OC_SUBID_COUNT]"
        continue
      fi
      # No other range may overlap this one, or two users would share ids.
      start=$(awk -F: -v u="$user" '$1 == u {print $2; exit}' "$file")
      count=$(awk -F: -v u="$user" '$1 == u {print $3; exit}' "$file")
      end=$((start + count))
      if awk -F: -v u="$user" -v s="$start" -v e="$end" '$1 != u && $2 < e && ($2 + $3) > s {f = 1} END {exit !f}' "$file"; then
        bad+=" [$user's range in $file overlaps another user's]"
      fi
    done
    [[ -e $OC_LINGER_DIR/$user ]] || bad+=" [lingering is not enabled for $user]"
    if ! in_container; then
      [[ $(loginctl show-user "$user" -p Linger --value 2>/dev/null) == yes ]] || bad+=" [logind does not report lingering for $user]"
    fi
  done
  if [[ -n $bad ]]; then
    fail "rootless Podman is not prepared:$bad"
  else
    pass "each environment user has its own subuid and subgid range (no overlap) and lingering is enabled"
  fi
}

check_ctr_03() {
  local env uid home out bad="" n=0
  kernel_skip && return 0
  if ! oc_have podman; then
    fail "podman is not installed"
    return 0
  fi
  for env in "${OC_ENV_LIST[@]}"; do
    uid=$(oc_env_uid "$env")
    home=$(oc_env_home "$env")
    n=$((n + 1))
    out=$(runuser -u "oc-$env" -- env "HOME=$home" "XDG_RUNTIME_DIR=/run/user/$uid" \
      podman info --format '{{.Host.Security.Rootless}}' 2>&1) || out="error"
    [[ $out == true ]] || bad+=" [podman info as oc-$env: ${out:0:80}]"
  done
  if [[ -n $bad ]]; then
    fail "rootless Podman does not work:$bad"
  else
    pass "podman info works rootless as each of the $n environment users"
  fi
}

check_svc_02() {
  local env f key line bad="" missing n=0 stray
  for env in "${OC_ENV_LIST[@]}"; do
    f="$OC_SECRET_DIR/$env.env"
    if [[ ! -f $f ]]; then
      bad+=" [$f missing]"
      continue
    fi
    n=$((n + 1))
    [[ $(stat -c '%a %U %G' -- "$f") == "640 root oc-$env" ]] || bad+=" [$f is $(stat -c '%a %U:%G' -- "$f"), want 640 root:oc-$env]"
    missing=""
    for key in "${USERS_ENV_KEYS[@]}"; do
      line=$(grep -m1 "^$key=" -- "$f" || true)
      [[ -n $line ]] || {
        missing+=" $key"
        continue
      }
      # Only names are reported, never values. OC_CMS_API_TOKEN may stay empty until Strapi has one.
      if [[ $key != OC_CMS_API_TOKEN && ${line#*=} == "" ]]; then missing+=" $key(empty)"; fi
    done
    [[ -z $missing ]] || bad+=" [$f lacks:$missing]"
  done
  stray=$(find "$OC_SECRET_DIR" -type f -perm /o+rwx 2>/dev/null | head -n 3 | tr '\n' ' ')
  [[ -z $stray ]] || bad+=" [world-accessible files in $OC_SECRET_DIR: $stray]"
  if [[ -n $bad ]]; then
    fail "secret files are wrong:$bad"
  else
    pass "$n secret file(s) are 0640 root:oc-<env> and hold every required key"
  fi
}

check_fs_01() {
  local env d bad="" n=0
  for env in "${OC_ENV_LIST[@]}"; do
    for d in "$OC_DATA_ROOT/$env" "$OC_DATA_ROOT/$env/media" "$OC_DATA_ROOT/$env/private" "$OC_DATA_ROOT/$env/tmp"; do
      if [[ ! -d $d ]]; then
        bad+=" [$d missing]"
        continue
      fi
      n=$((n + 1))
      [[ $(stat -c '%a %U %G' -- "$d") == "750 oc-$env oc-$env" ]] || bad+=" [$d is $(stat -c '%a %U:%G' -- "$d"), want 750 oc-$env:oc-$env]"
    done
  done
  [[ $(stat -c '%a' -- "$OC_DATA_ROOT" 2>/dev/null) =~ ^7[0-5][0-5]$ ]] || bad+=" [$OC_DATA_ROOT is writable by others or missing]"
  if [[ -n $bad ]]; then
    fail "data folders are wrong:$bad"
  else
    pass "$n data folders are owned by their environment user with mode 0750"
  fi
}

check_fs_02() {
  local p bad="" n=0
  if [[ -z $NGINX_T ]]; then
    fail "cannot read the Nginx configuration, so the web roots cannot be checked"
    return 0
  fi
  while IFS= read -r p; do
    [[ -n $p ]] || continue
    n=$((n + 1))
    # A root at /var/lib/oc, below it, or above it (/, /var, /var/lib) would expose the data.
    if [[ $p == /var/lib/oc || $p == /var/lib/oc/* || $p == / || $p == /var || $p == /var/ || $p == /var/lib || $p == /var/lib/ ]]; then
      bad+=" [$p]"
    fi
  done < <(printf '%s\n' "$NGINX_T" | sed 's/[[:space:]]*#.*$//' |
    grep -oE '(^|[{;[:space:]])(root|alias)[[:space:]]+[^;[:space:]]+;' |
    sed -E 's/^[{;[:space:]]*(root|alias)[[:space:]]+//; s/;$//')
  if [[ -n $bad ]]; then
    fail "Nginx serves a folder at or above $OC_DATA_ROOT:$bad"
  else
    pass "$OC_DATA_ROOT is not under any Nginx root ($n root/alias directives checked)"
  fi
}

# --- database ----------------------------------------------------------------------
check_db_01() {
  local env user hosts grants line bad="" defaults pass db other n=0 extra
  if ! oc_have mariadb || ! mariadb -N -B -e 'SELECT 1' >/dev/null 2>&1; then
    fail "cannot query MariaDB as root over the socket (is it installed and running?)"
    return 0
  fi
  for env in "${OC_ENV_LIST[@]}"; do
    user="oc_$env"
    db="oc_$env"
    n=$((n + 1))
    hosts=$(mariadb -N -B -e "SELECT Host FROM mysql.global_priv WHERE User = '$user'" 2>/dev/null)
    if [[ $hosts != localhost ]]; then
      bad+=" [$user has hosts '$(echo "$hosts" | tr '\n' ',')', want exactly localhost (the unix socket)]"
      continue
    fi
    grants=$(mariadb -N -B -e "SHOW GRANTS FOR '$user'@'localhost'" 2>/dev/null)
    local found_db=0
    while IFS= read -r line; do
      [[ -n $line ]] || continue
      if [[ $line == "GRANT USAGE ON *.* TO "* ]]; then
        continue
      elif [[ $line =~ ^GRANT\ [A-Z\ ,]+\ ON\ \`$db\`\.\*\ TO\  && $line != *"WITH GRANT OPTION"* ]]; then
        found_db=1
      else
        bad+=" [$user has a grant beyond its own database]"
      fi
    done <<<"$grants"
    ((found_db)) || bad+=" [$user has no grant on $db]"
    # The password in the secret file must work, for its own database only.
    # The file holds a password for a moment: 0600 from mktemp, and removed even if this
    # check dies (it runs in its own subshell, so this EXIT trap ends with it).
    defaults=$(mktemp -t "oc.XXXXXX")
    trap 'rm -f -- "$defaults"' EXIT
    pass=$(users_env_value "$env" DATABASE_PASSWORD)
    {
      printf '[client]\nuser=%s\nprotocol=socket\nsocket=%s\n' "$user" "$OC_MARIADB_SOCKET"
      printf 'password=%s\n' "$pass"
    } >"$defaults"
    if ! mariadb --defaults-extra-file="$defaults" -N -B -e 'SELECT 1' "$db" >/dev/null 2>&1; then
      bad+=" [$user cannot sign in to $db with the password in $env.env]"
    fi
    if mariadb --defaults-extra-file="$defaults" -N -B -e 'SELECT COUNT(*) FROM mysql.global_priv' >/dev/null 2>&1; then
      bad+=" [$user can read the mysql system database]"
    fi
    for other in "${OC_ENV_LIST[@]}"; do
      [[ $other != "$env" ]] || continue
      if mariadb --defaults-extra-file="$defaults" -N -B -e "USE oc_$other" >/dev/null 2>&1; then
        bad+=" [$user can open oc_$other]"
      fi
    done
    rm -f -- "$defaults"
  done
  extra=$(mariadb -N -B -e "SELECT CONCAT(User, '@', Host) FROM mysql.global_priv WHERE (User LIKE 'oc\_%' OR User = '') ORDER BY User" 2>/dev/null)
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    word_in " $(printf 'oc_%s@localhost ' "${OC_ENV_LIST[@]}")" "$line" || bad+=" [unexpected account $line]"
  done <<<"$extra"
  if [[ -n $bad ]]; then
    fail "database accounts are wrong:$bad"
  else
    pass "$n database user(s), one per environment, each limited to its own database"
  fi
}

# --- packages ----------------------------------------------------------------------
check_pkg_01() {
  local v found
  if ! oc_have podman; then
    fail "podman is not installed"
    return 0
  fi
  v=$(podman --version 2>/dev/null | awk '{print $3}')
  if ! oc_version_ge "$v" "$OC_MIN_PODMAN"; then
    fail "Podman '${v:-unknown}' is older than $OC_MIN_PODMAN (Quadlet needs 4.4 or newer)"
    return 0
  fi
  # No Docker, and no other container daemon: they run as root.
  if ! declare -F pkg_docker_found >/dev/null; then
    fail "internal error: the Docker detection is not loaded, so the check cannot run"
    return 0
  fi
  found=$(pkg_docker_found | tr '\n' ',' | sed 's/,$//')
  if [[ -n $found ]]; then
    fail "Podman $v is installed, but so is Docker or another container daemon ($found)"
    return 0
  fi
  pass "Podman $v (Quadlet needs $OC_MIN_PODMAN or newer) and no Docker daemon"
}

check_pkg_02() {
  local v
  if ! oc_have mariadbd; then
    fail "mariadbd is not installed"
    return 0
  fi
  v=$(mariadbd --version 2>/dev/null | sed -n 's/.*Ver \([0-9]*\.[0-9]*\.[0-9]*\).*/\1/p')
  if [[ $v == 11.4.* ]]; then
    pass "MariaDB $v"
  else
    fail "MariaDB is '${v:-unknown}', not the 11.4 series"
  fi
}

# --- TLS certificate ---------------------------------------------------------------
check_tls_01() {
  local subject issuer a b
  if [[ ! -s $OC_TLS_CERT || ! -s $OC_TLS_KEY ]]; then
    fail "the origin certificate or key is missing ($OC_TLS_CERT, $OC_TLS_KEY)"
    return 0
  fi
  if ! openssl x509 -in "$OC_TLS_CERT" -noout -checkend 0 >/dev/null 2>&1; then
    fail "the origin certificate has expired (or is unreadable)"
    return 0
  fi
  a=$(openssl x509 -in "$OC_TLS_CERT" -noout -pubkey 2>/dev/null | sha256sum | cut -d' ' -f1)
  b=$(openssl pkey -in "$OC_TLS_KEY" -pubout 2>/dev/null | sha256sum | cut -d' ' -f1)
  if [[ $a != "$b" ]]; then
    fail "the origin key does not match the origin certificate"
    return 0
  fi
  if [[ $(stat -c '%a %U' -- "$OC_TLS_KEY") != "600 root" ]]; then
    fail "the origin key is not 0600 root"
    return 0
  fi
  subject=$(openssl x509 -in "$OC_TLS_CERT" -noout -subject 2>/dev/null)
  issuer=$(openssl x509 -in "$OC_TLS_CERT" -noout -issuer 2>/dev/null)
  if [[ $subject == *oc-placeholder* || ${subject#subject=} == "${issuer#issuer=}" ]]; then
    warn "the PLACEHOLDER self-signed origin certificate is still in use: install a Cloudflare origin certificate at $OC_TLS_CERT (Full (strict) mode refuses this one)"
  else
    pass "a real origin certificate is installed ($(openssl x509 -in "$OC_TLS_CERT" -noout -enddate | sed 's/^notAfter=/expires /'))"
  fi
}

# --- units and the Cloudflare refresh ----------------------------------------------
check_svc_03() {
  local u bad=""
  for u in oc-cloudflare-ips.service oc-cloudflare-ips.timer; do
    [[ -f $OC_UNIT_DIR/$u ]] || bad+=" [$u not installed]"
  done
  [[ -x $OC_RUNTIME_BIN ]] || bad+=" [$OC_RUNTIME_BIN missing]"
  [[ -f $OC_RUNTIME_LIB_DIR/common.sh && -f $OC_RUNTIME_LIB_DIR/firewall.sh && -f $OC_RUNTIME_LIB_DIR/nginx.sh ]] ||
    bad+=" [the refresh's libraries are missing from $OC_RUNTIME_LIB_DIR]"
  if ! in_container; then
    systemctl is-enabled --quiet oc-cloudflare-ips.timer 2>/dev/null || bad+=" [oc-cloudflare-ips.timer is not enabled]"
    systemctl is-active --quiet oc-cloudflare-ips.timer 2>/dev/null || bad+=" [oc-cloudflare-ips.timer is not active]"
  fi
  if [[ -n $bad ]]; then
    fail "the Cloudflare refresh is not set up:$bad"
  elif in_container; then
    pass "the weekly Cloudflare refresh (service, timer and script) is installed (configuration)"
  else
    pass "the weekly Cloudflare refresh timer is enabled and active"
  fi
}

# --- runner ------------------------------------------------------------------------
CHECKS=(
  "SSH-01 check_ssh_01" "SSH-02 check_ssh_02" "SSH-03 check_ssh_03" "SSH-04 check_ssh_04" "SSH-05 check_ssh_05"
  "NET-01 check_net_01" "NET-02 check_net_02" "NET-03 check_net_03" "NET-04 check_net_04" "NET-05 check_net_05" "NET-06 check_net_06"
  "NGX-01 check_ngx_01"
  "OS-01 check_os_01" "OS-02 check_os_02" "OS-03 check_os_03" "OS-04 check_os_04" "OS-05 check_os_05"
  "OS-06 check_os_06" "OS-07 check_os_07" "OS-08 check_os_08"
  "CTR-01 check_ctr_01" "CTR-02 check_ctr_02" "CTR-03 check_ctr_03"
  "SVC-02 check_svc_02" "SVC-03 check_svc_03"
  "FS-01 check_fs_01" "FS-02 check_fs_02"
  "DB-01 check_db_01"
  "PKG-01 check_pkg_01" "PKG-02 check_pkg_02"
  "TLS-01 check_tls_01"
)

N_PASS=0
N_FAIL=0
N_WARN=0
N_SKIP=0

run_check() {
  local id=$1 fn=$2 out rc=0 status rest got=0
  CUR=$id
  if [[ ${VERIFY_DEBUG:-0} == 1 ]]; then
    out=$( ("$fn") 2>&1) || rc=$?
  else
    out=$( ("$fn") 2>/dev/null) || rc=$?
  fi
  while IFS=' ' read -r status rest; do
    case $status in
      PASS) N_PASS=$((N_PASS + 1)) ;;
      FAIL) N_FAIL=$((N_FAIL + 1)) ;;
      WARN) N_WARN=$((N_WARN + 1)) ;;
      SKIP) N_SKIP=$((N_SKIP + 1)) ;;
      *) continue ;;
    esac
    [[ ${rest%% *} == "$id" ]] && got=1
    printf '%s %s\n' "$status" "$rest"
  done <<<"$out"
  if ((got == 0)); then
    N_FAIL=$((N_FAIL + 1))
    printf 'FAIL %s the check produced no result (exit status %s); a check that cannot run is a failure\n' "$id" "$rc"
  fi
}

main() {
  local config=${OC_CONFIG:-$OC_INFRA_DIR/server.env} cfg_err entry
  oc_require_root
  if ! cfg_err=$( (
    oc_load_config "$config"
    oc_validate_config
  ) 2>&1); then
    printf 'FAIL CFG-00 settings: %s\n' "${cfg_err#\[oc\] ERROR: }"
    printf 'SUMMARY pass=0 fail=1 warn=0 skip=0\n'
    exit 1
  fi
  oc_load_config "$config"
  oc_validate_config
  if in_container; then
    printf 'NOTE container mode: checks read the written configuration; (kernel) checks are skipped\n'
  fi
  load_facts
  for entry in "${CHECKS[@]}"; do
    run_check "${entry%% *}" "${entry#* }"
  done
  printf 'SUMMARY pass=%d fail=%d warn=%d skip=%d\n' "$N_PASS" "$N_FAIL" "$N_WARN" "$N_SKIP"
  [[ $N_FAIL -eq 0 ]]
}

main "$@"
