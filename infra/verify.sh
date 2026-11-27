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
#   VERIFY_ONLY="ID ..."  run only the checks with these ids (for example: VERIFY_ONLY="NET-03 NGX-01").
#                         For the test container only, like VERIFY_CONTAINER=1: on a real host setting
#                         it is refused (FAIL CFG-02), because a verification that quietly covers
#                         fewer checks than it claims is worse than none. An id that is not a check
#                         fails (FAIL CFG-03, naming it), so does a selection that names none, and a
#                         subset run says so: "NOTE only ran: ..." and "only=..." on the SUMMARY line.
#                         A real verification runs them all.
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
# shellcheck source=lib/ssh.sh
source "$OC_INFRA_DIR/lib/ssh.sh"

VERIFY_CONTAINER=${VERIFY_CONTAINER:-0}
# The awk the Nginx tokenizer and the Quadlet normaliser run under. The tests run both parsers
# under gawk and mawk and compare; a server uses Ubuntu's default (mawk).
AWK=${OC_AWK:-awk}
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
# What sshd would do for each user who may sign in: `sshd -T -C user=<u>,host=x,addr=203.0.113.1`.
# A Match block can change a value for one user only, so the plain `sshd -T` is not enough.
declare -A SSHD_T_USER=()
NGINX_T=""
NGINX_SERVERS=""

load_facts() {
  local u
  local -a users=()
  if oc_have sshd; then
    SSHD_T=$(sshd -T 2>/dev/null) || SSHD_T=""
    read -r -a users <<<"$(ssh_allowed_users)"
    for u in "${users[@]}"; do
      SSHD_T_USER[$u]=$(sshd -T -C "user=$u,host=x,addr=203.0.113.1" 2>/dev/null) || SSHD_T_USER[$u]=""
    done
  fi
  if oc_have nginx; then
    NGINX_T=$(nginx -T 2>/dev/null) || NGINX_T=""
  fi
  if [[ -n $NGINX_T ]]; then
    NGINX_SERVERS=$(nginx_servers <<<"$NGINX_T")
  fi
}

sshd_val() { awk -v k="$1" '$1 == k {$1 = ""; sub(/^ /, ""); v = (v == "" ? $0 : v " " $0)} END {print v}' <<<"$SSHD_T"; }
# sshd_val_user USER KEY: the value of KEY for that user (a Match block may differ from the global one).
sshd_val_user() { awk -v k="$2" '$1 == k {$1 = ""; sub(/^ /, ""); v = (v == "" ? $0 : v " " $0)} END {print v}' <<<"${SSHD_T_USER[$1]:-}"; }

# nginx_servers: reads `nginx -T` and prints, in this order, a D line for every use of a few
# directives (anywhere: http, server, location, if), then one S line per server block, then one
# summary line:
#   D|directive|arguments                      (server_tokens, client_max_body_size, client_body_timeout, client_header_timeout)
#   S|names|ssl|default|reject|verify_client|client_certificate|ssl_protocols|tls_ports|own_ssl
#   T|ssl_listens_in_servers|listens_outside_servers|ssl_listens_outside_servers|unreadable|ssl_directives
# ssl is 1 when the server is served over TLS: its own listen has ssl or quic, or it says
# "ssl on", OR another server listens on the same port with ssl. Nginx turns TLS on for every
# server of a listening socket when one of them says ssl, so a server that does not say it
# can still be one; the check treats every server on such a port (whatever the address) as TLS.
# own_ssl is 1 when the server says ssl itself. tls_ports are the ports (or unix: sockets) of
# the server's listens that are TLS, space separated. ssl_directives counts every "ssl"
# directive anywhere, whatever its value: that is the old way to switch TLS on (for one server,
# or for all of them from the http level), and NET-03 refuses it.
# It is a port of Nginx's own tokenizer (ngx_conf_read_token), because a reader that differs
# from Nginx in one rule can be made to skip a server. The rules that matter:
#   - a quote or # is special only at the START of a word ("a'b" is one word; so is a#b);
#   - } closes a block only at the start of a word (in "a}" the } is part of the word);
#   - after $ a { is just part of the word (${a is a word that ends at the next space or ;);
#   - \ keeps the next character in the word, and "\"", "\'", "\\", \t, \r, \n are unescaped;
#   - a quoted word must be followed by a space, ; or { (anything else is an error), except
#     that a ) after it is the first character of the next word;
#   - a word ends at a space, ; or {.
# Only directives written directly in the server block count for that server, not those in
# locations. Values of on/off directives are compared without regard to case (Nginx does the
# same). A listen whose address this parser cannot place on a port makes the text "unreadable",
# as does any text that is not something Nginx itself would accept (unbalanced braces, an open
# quote, a ; with no directive, ...), and NET-03 then fails.
NGINX_AWK=""
read -r -d '' NGINX_AWK <<'AWK' || true
function isws(c) { return c == " " || c == "\t" || c == "\r" || c == "\n" }
function unescape(s,   out, i, n, c, d) {
  out = ""; n = length(s); i = 1
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == "\\" && i < n) {
      d = substr(s, i + 1, 1)
      if (d == "\"" || d == "'" || d == "\\") { out = out d; i += 2; continue }
      if (d == "t") { out = out "\t"; i += 2; continue }
      if (d == "r") { out = out "\r"; i += 2; continue }
      if (d == "n") { out = out "\n"; i += 2; continue }
    }
    out = out c
    i++
  }
  return out
}
function word_end() { w[nw++] = unescape(raw); raw = "" }
function join(from,   i, r) {
  r = ""
  for (i = from; i < nw; i++) r = (r == "" ? w[i] : r " " w[i])
  return r
}
function reset_state() { lastspace = 1; need_space = 0; variable = 0; dq = 0; sq = 0; quoted = 0; raw = "" }
# listen_key(arg): the port a listen address is on (what Nginx shares between servers), as a
# number, or the whole "unix:..." address, or "" when the address is not one this parser places.
# Only a port counts: 127.0.0.1:443, *:443, [::]:443 and 443 are all port 443; an address with no
# port is port 80.
function listen_key(a,   n) {
  if (a ~ /^unix:/) return a
  if (a ~ /^[0-9]+-[0-9]+$/) return ""
  if (a ~ /^[0-9]+$/) { n = a + 0; return n "" }
  if (a ~ /^\[[0-9A-Fa-f:.]+\]:[0-9]+$/) { sub(/^.*\]:/, "", a); n = a + 0; return n "" }
  if (a ~ /^\[[0-9A-Fa-f:.]+\]$/) return "80"
  if (a ~ /^[^:\[\]]*:[0-9]+$/) { sub(/^.*:/, "", a); n = a + 0; return n "" }
  if (a ~ /^[^:\[\]]+$/) return "80"
  return ""
}
function add_port(k) { if (index(" " s_ports " ", " " k " ") == 0) s_ports = (s_ports == "" ? k : s_ports " " k) }
function directive(   name, lname, i, has_ssl, has_def, k) {
  name = w[0]
  lname = tolower(name)
  if (lname == "ssl") ssl_directives++
  if (name == "server_tokens" || name == "client_max_body_size" || name == "client_body_timeout" || name == "client_header_timeout") {
    print "D|" name "|" join(1)
  }
  if (name == "listen") {
    has_ssl = 0; has_def = 0
    for (i = 1; i < nw; i++) {
      if (w[i] == "ssl" || w[i] == "quic") has_ssl = 1
      if (w[i] == "default_server") has_def = 1
    }
    if (srv > 0) {
      k = listen_key(w[1])
      if (k == "") bad = 1
      else {
        add_port(k)
        if (has_ssl) port_ssl[k] = 1
      }
      if (has_ssl) { s_ssl = 1; srv_ssl_listens++ }
      if (has_def) s_def = 1
    } else {
      orphan++
      if (has_ssl) orphan_ssl++
    }
    return
  }
  if (srv > 0 && depth == srv) {
    if (name == "server_name") s_names = (s_names == "" ? join(1) : s_names " " join(1))
    else if (name == "ssl_reject_handshake") { if (tolower(w[1]) == "on") s_rej = 1 }
    else if (name == "ssl_verify_client") s_ver = w[1]
    else if (name == "ssl_client_certificate") s_cc = w[1]
    else if (name == "ssl_protocols") s_proto = join(1)
    else if (lname == "ssl") { if (tolower(w[1]) == "on") s_ssl = 1 }
  }
}
function open_block() {
  depth++
  if (srv == 0 && nw == 1 && w[0] == "server") {
    srv = depth
    s_names = ""; s_ssl = 0; s_def = 0; s_rej = 0; s_ver = ""; s_cc = ""; s_proto = ""; s_ports = ""
  }
}
# A server is kept until the end of the text: whether it is TLS depends on the other servers.
function close_block() {
  if (depth <= 0) { bad = 1; return }
  if (srv > 0 && depth == srv) {
    nsrv++
    k_names[nsrv] = s_names; k_ssl[nsrv] = s_ssl; k_def[nsrv] = s_def; k_rej[nsrv] = s_rej
    k_ver[nsrv] = s_ver; k_cc[nsrv] = s_cc; k_proto[nsrv] = s_proto
    # a server with no listen at all listens on port 80
    k_ports[nsrv] = (s_ports == "" ? "80" : s_ports)
    srv = 0
  }
  depth--
}
function print_servers(   i, j, n, pk, eff, tlsp) {
  for (i = 1; i <= nsrv; i++) {
    n = split(k_ports[i], pk, " ")
    eff = k_ssl[i]; tlsp = ""
    for (j = 1; j <= n; j++) {
      if (port_ssl[pk[j]]) { eff = 1; tlsp = (tlsp == "" ? pk[j] : tlsp " " pk[j]) }
    }
    print "S|" k_names[i] "|" eff "|" k_def[i] "|" k_rej[i] "|" k_ver[i] "|" k_cc[i] "|" k_proto[i] "|" tlsp "|" k_ssl[i]
  }
}
# A statement ends at ; or { . With no words in it, Nginx refuses the file.
function stmt(kind) {
  if (nw == 0) bad = 1
  else if (kind == ";") directive()
  else open_block()
  nw = 0
}
function feed(c) {
  if (c == "\n" && sharp) sharp = 0
  if (sharp) return
  if (quoted) { quoted = 0; raw = raw c; return }
  if (need_space) {
    if (isws(c)) { lastspace = 1; need_space = 0; return }
    if (c == ";" || c == "{") { stmt(c); reset_state(); return }
    # Nginx treats a ) here as the end of the quoted word AND the first character of the next
    # word (it falls through to the start-of-word code below); anything else is an error.
    if (c == ")") { lastspace = 1; need_space = 0 } else { bad = 1; return }
  }
  if (lastspace) {
    if (isws(c)) return
    if (c == ";" || c == "{") { stmt(c); reset_state(); return }
    if (c == "}") { if (nw != 0) bad = 1; nw = 0; close_block(); reset_state(); return }
    if (c == "#") { sharp = 1; return }
    lastspace = 0; raw = ""
    if (c == "\\") { quoted = 1; raw = "\\"; return }
    if (c == "\"") { dq = 1; return }
    if (c == "'") { sq = 1; return }
    if (c == "$") { variable = 1; raw = "$"; return }
    raw = c
    return
  }
  if (c == "{" && variable) { raw = raw c; return }
  variable = 0
  if (c == "\\") { quoted = 1; raw = raw c; return }
  if (c == "$") { variable = 1; raw = raw c; return }
  if (dq) { if (c == "\"") { dq = 0; need_space = 1; word_end() } else raw = raw c; return }
  if (sq) { if (c == "'") { sq = 0; need_space = 1; word_end() } else raw = raw c; return }
  if (isws(c) || c == ";" || c == "{") {
    lastspace = 1; word_end()
    if (c == ";" || c == "{") { stmt(c); reset_state() }
    return
  }
  raw = raw c
}
BEGIN { reset_state() }
{
  n = length($0)
  for (i = 1; i <= n; i++) feed(substr($0, i, 1))
  feed("\n")
}
END {
  if (depth != 0 || nw != 0 || dq || sq || quoted || !lastspace) bad = 1
  print_servers()
  print "T|" (srv_ssl_listens + 0) "|" (orphan + 0) "|" (orphan_ssl + 0) "|" (bad + 0) "|" (ssl_directives + 0)
}
AWK
nginx_servers() { "$AWK" "$NGINX_AWK"; }

# The same facts a second way, by plain text search: every "listen ... ;" statement, how many
# of them have ssl or quic (quoted or not), and how many contain a quote at all. NET-03 needs
# the parser and this count to agree, and refuses a configuration with a quote in a listen.
nginx_listen_stmts() {
  printf '%s\n' "$1" | sed 's/[[:space:]]*#.*$//' | grep -oE '(^|[;{}[:space:]])listen[[:space:]][^;]*;' || true
}
nginx_tls_listen_count() {
  nginx_listen_stmts "$1" | grep -cE "[[:space:]][\"']?(ssl|quic)[\"']?([[:space:];]|\$)" || true
}
nginx_quoted_listen_count() {
  nginx_listen_stmts "$1" | grep -c "[\"']" || true
}
# A third count, again by plain text: the statements that start with the word ssl (the old
# "ssl on;"), quoted or not. The parser's count of "ssl" directives must agree with it.
nginx_ssl_directive_count() {
  printf '%s\n' "$1" | sed 's/[[:space:]]*#.*$//' | grep -oE "(^|[;{}])[[:space:]]*[\"']?ssl[\"']?[[:space:]]" | wc -l | tr -d '[:space:]'
}

# --- SSH ---------------------------------------------------------------------------
need_sshd() {
  if [[ -z $SSHD_T ]]; then
    fail "cannot read the effective sshd configuration (is openssh-server installed? does sshd -T work?)"
    return 1
  fi
}

# need_sshd_users: sshd must have answered for every user who may sign in, and the
# configuration must hold no Match or Include line of anyone else's (it could switch a rule
# back on for some connections only, in a way the sample users below would never show).
need_sshd_users() {
  local u foreign
  local -a users=()
  need_sshd || return 1
  read -r -a users <<<"$(ssh_allowed_users)"
  for u in "${users[@]}"; do
    if [[ -z ${SSHD_T_USER[$u]:-} ]]; then
      fail "cannot read the effective sshd configuration for the user $u (sshd -T -C user=$u,host=x,addr=203.0.113.1 gave nothing)"
      return 1
    fi
  done
  foreign=$(ssh_foreign_match)
  if [[ -n $foreign ]]; then
    fail "the sshd configuration has a Match or Include line this setup did not write, which could change these rules for some connections: $(printf '%s' "$foreign" | head -n 2 | tr '\n' ' ')"
    return 1
  fi
}

check_ssh_01() {
  local u pw kbd am bad=""
  local -a users=()
  need_sshd_users || return 0
  read -r -a users <<<"$(ssh_allowed_users)"
  for u in "${users[@]}"; do
    pw=$(sshd_val_user "$u" passwordauthentication)
    kbd=$(sshd_val_user "$u" kbdinteractiveauthentication)
    am=$(sshd_val_user "$u" authenticationmethods)
    [[ $pw == no && $kbd == no && $am == publickey ]] || bad+=" $u(passwordauthentication=$pw, kbdinteractiveauthentication=$kbd, authenticationmethods=$am)"
  done
  if [[ -z $bad ]]; then
    pass "password login is off; only public keys are accepted (asked for each user who may sign in: ${users[*]})"
  else
    fail "password login is not fully off for:$bad"
  fi
}

check_ssh_02() {
  local u v bad=""
  local -a users=()
  need_sshd_users || return 0
  read -r -a users <<<"$(ssh_allowed_users)"
  for u in "${users[@]}"; do
    v=$(sshd_val_user "$u" permitrootlogin)
    [[ $v == no ]] || bad+=" $u(permitrootlogin=$v)"
  done
  if [[ -z $bad ]]; then pass "root login is off"; else fail "permitrootlogin is not 'no' for:$bad"; fi
}

check_ssh_03() {
  local got want name home bad=""
  need_sshd || return 0
  got=$(sorted_words "$(sshd_val allowusers)")
  want=$(sorted_words "$(ssh_allowed_users)")
  if [[ $got != "$want" ]]; then
    fail "AllowUsers is '$got', the admins in server.env (and the deploy account, if on) are '$want'"
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
    pass "only the named admins (and the deploy account, if on) may sign in: $got"
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

# --- the deploy account ------------------------------------------------------------
# dep_root_only PATH: PATH and every folder above it belong to root and cannot be written by a
# group or by others, so the deploy account cannot replace what it is made to run.
dep_root_only() {
  local p a g
  p=$(readlink -f -- "$1" 2>/dev/null) || return 1
  [[ -n $p && -e $p ]] || return 1
  while :; do
    [[ $(stat -c %u -- "$p") == 0 ]] || return 1
    a=$(stat -c %A -- "$p")
    g=$(stat -c %G -- "$p")
    # Anyone may not write. The group may not either, unless it is a group the deploy user is not in
    # (its only group is its own: DEP-01 checks that too; a system folder may belong to "staff").
    [[ ${a:8:1} != w ]] || return 1
    [[ ${a:5:1} != w || $g != "$OC_DEPLOY_USER" ]] || return 1
    [[ $p == / ]] && return 0
    p=$(dirname -- "$p")
  done
}

# dep_expected_sudo_command: the one command line sudo should show for the deploy account,
# taken from the same function that writes the rule.
dep_expected_sudo_command() {
  users_deploy_sudoers | awk -v u="$OC_DEPLOY_USER" 'index($0, u " ALL=(root) NOPASSWD: ") == 1 {print substr($0, length(u " ALL=(root) NOPASSWD: ") + 1)}'
}

check_dep_01() {
  local bad="" f st n line key rest a out entries cmds expect_cmd got kf nenv bound e o mixed want seen_blobs
  if [[ $OC_DEPLOY_ENABLED != yes ]]; then
    for f in "$OC_DEPLOY_SUDOERS" "$OC_DEPLOY_KEYS" "$OC_DEPLOY_FORCED" "$OC_DEPLOY_APPLY"; do
      if [[ -e $f || -L $f ]]; then bad+=" [$f is still there]"; fi
    done
    if getent passwd "$OC_DEPLOY_USER" >/dev/null; then bad+=" [the user $OC_DEPLOY_USER still exists]"; fi
    if [[ -z $bad ]]; then
      pass "the deploy account is switched off (OC_DEPLOY_ENABLED=no) and nothing of it is left"
    else
      fail "the deploy account is switched off but is not gone:$bad"
    fi
    return 0
  fi

  # 1. the account: a system user, no password, no group but its own, a home it cannot write
  if ! getent passwd "$OC_DEPLOY_USER" >/dev/null; then
    fail "the deploy user $OC_DEPLOY_USER does not exist"
    return 0
  fi
  n=$(id -u -- "$OC_DEPLOY_USER")
  [[ $n -ge 1 && $n -lt 1000 ]] || bad+=" [$OC_DEPLOY_USER is not a system account (id $n)]"
  [[ $(getent passwd "$OC_DEPLOY_USER" | cut -d: -f7) == /bin/sh ]] || bad+=" [its shell is not /bin/sh]"
  [[ $(getent passwd "$OC_DEPLOY_USER" | cut -d: -f6) == "$OC_DEPLOY_HOME" ]] || bad+=" [its home is not $OC_DEPLOY_HOME]"
  st=$(getent shadow "$OC_DEPLOY_USER" | cut -d: -f2)
  [[ $st == '!'* || $st == '*'* ]] || bad+=" [it has a password (the account must be locked)]"
  [[ $(id -nG -- "$OC_DEPLOY_USER") == "$OC_DEPLOY_USER" ]] || bad+=" [it is in groups beyond its own: $(id -nG -- "$OC_DEPLOY_USER")]"
  [[ $(stat -c '%U:%G %a' -- "$OC_DEPLOY_HOME" 2>/dev/null) == "root:root 755" ]] || bad+=" [$OC_DEPLOY_HOME is not root:root 755]"
  [[ $(stat -c '%U:%G %a' -- "$OC_DEPLOY_SPOOL" 2>/dev/null) == "root:$OC_DEPLOY_USER 770" ]] || bad+=" [$OC_DEPLOY_SPOOL is not root:$OC_DEPLOY_USER 770]"

  # 2. what it runs is root's and cannot be replaced by it
  for f in "$OC_DEPLOY_FORCED" "$OC_DEPLOY_APPLY"; do
    if [[ ! -f $f || -L $f ]]; then
      bad+=" [$f is missing or not a plain file]"
      continue
    fi
    [[ $(stat -c '%U:%G %a' -- "$f") == "root:root 755" ]] || bad+=" [$f is not root:root 755]"
    dep_root_only "$f" || bad+=" [$f, or a folder above it, can be changed by someone other than root]"
  done
  cmp -s -- "$OC_INFRA_DIR/deploy/deploy-release.sh" "$OC_DEPLOY_FORCED" 2>/dev/null || bad+=" [$OC_DEPLOY_FORCED is not the same as infra/deploy/deploy-release.sh; rerun the bootstrap]"
  cmp -s -- "$OC_INFRA_DIR/deploy/apply-release.sh" "$OC_DEPLOY_APPLY" 2>/dev/null || bad+=" [$OC_DEPLOY_APPLY is not the same as infra/deploy/apply-release.sh; rerun the bootstrap]"
  grep -qx "MAX_TARBALL_BYTES=$OC_DEPLOY_MAX_BYTES" -- "$OC_DEPLOY_LIMITS" 2>/dev/null || bad+=" [$OC_DEPLOY_LIMITS does not say MAX_TARBALL_BYTES=$OC_DEPLOY_MAX_BYTES]"
  dep_root_only "$OC_DEPLOY_LIMITS" || bad+=" [$OC_DEPLOY_LIMITS is missing, or it or a folder above it can be changed by someone other than root]"

  # 3. its key file: root's, exactly one line per environment on this server. Each line is that
  # environment's forced command (which names the environment, so the key fixes it) and `restrict`,
  # then that environment's own key, and nothing else. No line without an environment, none with
  # any other option, no two with the same key, none with an environment this server does not run,
  # and each key is the one configured for its environment (OC_DEPLOY_PUBKEY_<ENV>), not another's.
  nenv=${#OC_ENV_LIST[@]}
  declare -A key_count=() key_blob=()
  seen_blobs=" "
  if [[ ! -f $OC_DEPLOY_KEYS || -L $OC_DEPLOY_KEYS ]]; then
    bad+=" [$OC_DEPLOY_KEYS is missing or not a plain file]"
  else
    [[ $(stat -c '%U:%G' -- "$OC_DEPLOY_KEYS") == root:root ]] || bad+=" [$OC_DEPLOY_KEYS is not owned by root]"
    dep_root_only "$OC_DEPLOY_KEYS" || bad+=" [$OC_DEPLOY_KEYS, or a folder above it, can be changed by someone other than root]"
    n=$(grep -c -v -E '^[[:space:]]*$' -- "$OC_DEPLOY_KEYS" || true)
    [[ $n -eq $nenv ]] || bad+=" [$OC_DEPLOY_KEYS has $n lines, not exactly one per environment ($nenv: ${OC_ENV_LIST[*]})]"
    while IFS= read -r line || [[ -n $line ]]; do
      [[ $line =~ ^[[:space:]]*$ ]] && continue
      bound=""
      for e in $OC_KNOWN_ENVS; do
        if [[ $line == "$(users_deploy_prefix "$e") "* ]]; then
          bound=$e
          rest=${line#"$(users_deploy_prefix "$e") "}
          break
        fi
      done
      if [[ -z $bound ]]; then
        if [[ $line == "command=\"$OC_DEPLOY_FORCED\",restrict "* ]]; then
          bad+=" [a key line does not bind an environment: its forced command is '$OC_DEPLOY_FORCED' alone, so that key could deploy any environment]"
        elif [[ $line =~ ^command=\"$OC_DEPLOY_FORCED\ (prod|staging)\"(,[^\ ]+)\  ]]; then
          # (an option list that is not exactly ",restrict": a line with no options at all, restrict
          # missing, falls through to the general message below)
          bad+=" [a key line carries options besides command= and restrict: '${BASH_REMATCH[2]#,}']"
        else
          bad+=" [a key line must start with exactly 'command=\"$OC_DEPLOY_FORCED <environment>\",restrict ' (the forced command with its environment and restrict, no other option, no pty); this one starts with '${line:0:100}']"
        fi
        continue
      fi
      if [[ " ${OC_ENV_LIST[*]} " != *" $bound "* ]]; then
        bad+=" [a key line binds the environment $bound, which this server does not run]"
      fi
      key_count[$bound]=$((${key_count[$bound]:-0} + 1))
      if [[ ! $rest =~ ^(ssh-ed25519|sk-ssh-ed25519@openssh\.com|ecdsa-sha2-nistp(256|384|521)|ssh-rsa)\ [A-Za-z0-9+/=]+\ oc-deploy-$bound$ ]]; then
        bad+=" [after its options the $bound key line is not '<key type> <key> oc-deploy-$bound' as the bootstrap writes it]"
        continue
      fi
      # ssh-keygen wants a real file, not a pipe
      kf=$(mktemp) || kf=""
      if [[ -z $kf ]]; then
        bad+=" [cannot make a temporary file to parse the key]"
      else
        printf '%s\n' "$rest" >"$kf"
        ssh-keygen -l -f "$kf" >/dev/null 2>&1 || bad+=" [the key of the $bound line does not parse]"
        rm -f -- "$kf"
      fi
      key=$(awk '{print $1 " " $2}' <<<"$rest")
      key_blob[$bound]=$key
      if [[ $seen_blobs == *"|$key|"* ]]; then
        bad+=" [two key lines carry the same key (the one of the $bound line): one shared key would be one door into both environments]"
      fi
      seen_blobs+="|$key|"
      # the CI key must not also be an admin's key
      for a in "${OC_ADMIN_NAMES[@]}"; do
        f=$(getent passwd "$a" | cut -d: -f6)/.ssh/authorized_keys
        [[ -f $f ]] || continue
        if awk '{print $1 " " $2}' "$f" | grep -qxF -- "$key"; then
          bad+=" [the key of the $bound line is also the key of the admin $a]"
        fi
      done
    done <"$OC_DEPLOY_KEYS"
    for e in "${OC_ENV_LIST[@]}"; do
      if [[ ${key_count[$e]:-0} -eq 0 ]]; then
        bad+=" [no key line for the environment $e]"
        continue
      elif [[ ${key_count[$e]} -gt 1 ]]; then
        bad+=" [${key_count[$e]} key lines for the environment $e, not exactly one]"
      fi
      [[ -n ${key_blob[$e]:-} ]] || continue
      kf=$(oc_deploy_keyfile "$e")
      if [[ ! -r $kf ]]; then
        bad+=" [cannot compare the $e key line with the key configured for $e: $kf is not readable]"
        continue
      fi
      want=$(users_pubkey_blob "$kf")
      if [[ ${key_blob[$e]} != "$want" ]]; then
        mixed=""
        for o in "${OC_ENV_LIST[@]}"; do
          [[ $o != "$e" && ${key_blob[$e]} == "$(users_pubkey_blob "$(oc_deploy_keyfile "$o")" 2>/dev/null)" ]] && mixed=$o
        done
        if [[ -n $mixed ]]; then
          bad+=" [the key configured for $mixed is bound to $e in $OC_DEPLOY_KEYS (a $mixed key must only deploy $mixed)]"
        else
          bad+=" [the key line for $e carries a key that is not the one configured for $e (OC_DEPLOY_PUBKEY_${e^^})]"
        fi
      fi
    done
  fi

  # 4. sudo: exactly one rule, for exactly one command and argument shape, nothing else
  if ! oc_have sudo; then
    bad+=" [sudo is missing, so the deploy account's rights cannot be read]"
  else
    out=$(sudo -ll -U "$OC_DEPLOY_USER" 2>&1) || out=""
    entries=$(grep -c '^Sudoers entry:' <<<"$out" || true)
    cmds=$(awk '/^[[:space:]]+Commands:/ {c = 1; next} /^[^[:space:]]/ {c = 0} /^[[:space:]]+[A-Za-z]+:/ {c = 0} c {sub(/^[ \t]+/, ""); if ($0 != "") print}' <<<"$out")
    expect_cmd=$(dep_expected_sudo_command)
    if [[ $entries -ne 1 ]]; then
      bad+=" [sudo shows $entries rules for $OC_DEPLOY_USER, not exactly one]"
    elif [[ $cmds != "$expect_cmd" ]]; then
      bad+=" [the one sudo rule is for '${cmds:0:200}', not '$expect_cmd']"
    fi
    [[ $(awk '/^[[:space:]]+RunAsUsers:/ {sub(/^[ \t]+RunAsUsers:[ \t]*/, ""); print}' <<<"$out") == root ]] || bad+=" [the sudo rule does not run as root only]"
    ! grep -q '^[[:space:]]*RunAsGroups:' <<<"$out" || bad+=" [the sudo rule names run-as groups]"
    [[ $(awk '/^[[:space:]]+Options:/ {sub(/^[ \t]+Options:[ \t]*/, ""); print}' <<<"$out") == '!authenticate' ]] || bad+=" [the sudo rule has options other than !authenticate]"
    line=$(grep -A1 '^Matching Defaults entries' <<<"$out" | tail -n 1)
    [[ $line == *env_reset* && $line != *'!env_reset'* && $line != *env_keep* && $line != *env_check* ]] || bad+=" [sudo does not reset the environment for the deploy account]"
    ! grep -Eq '(^|[[:space:],])setenv([[:space:],]|$)' <<<"$line" || bad+=" [sudo lets the deploy account set environment variables]"
    # the file itself is exactly what the bootstrap writes
    if [[ ! -f $OC_DEPLOY_SUDOERS ]] || ! users_deploy_sudoers | cmp -s - "$OC_DEPLOY_SUDOERS"; then
      bad+=" [$OC_DEPLOY_SUDOERS is not exactly what the bootstrap writes]"
    fi
    [[ $(stat -c '%U:%G %a' -- "$OC_DEPLOY_SUDOERS" 2>/dev/null) == "root:root 440" ]] || bad+=" [$OC_DEPLOY_SUDOERS is not root:root 440]"
  fi

  # 5. sshd, asked for this user: no ForceCommand of its own (it would override the key lines'
  # command=, which fixes each key's environment), no terminal, no forwarding of any kind
  if [[ -z ${SSHD_T_USER[$OC_DEPLOY_USER]:-} ]]; then
    bad+=" [sshd gave no answer for the user $OC_DEPLOY_USER]"
  else
    declare -A want_ssh=(
      [authorizedkeysfile]=$OC_DEPLOY_KEYS [forcecommand]=none [permittty]=no [disableforwarding]=yes
      [allowtcpforwarding]=no [allowstreamlocalforwarding]=no [x11forwarding]=no [allowagentforwarding]=no
      [permittunnel]=no [gatewayports]=no [permituserrc]=no [permituserenvironment]=no
      [passwordauthentication]=no [authenticationmethods]=publickey [maxsessions]=1
      # no other way in than the key lines (their command= is all that forces the command now): no
      # program that prints keys, no certificate authority, no principals file
      [authorizedkeyscommand]=none [authorizedkeyscommanduser]=none [trustedusercakeys]=none [authorizedprincipalsfile]=none
    )
    for key in "${!want_ssh[@]}"; do
      got=$(sshd_val_user "$OC_DEPLOY_USER" "$key")
      [[ $got == "${want_ssh[$key]}" ]] || bad+=" [sshd: $key is '$got' for $OC_DEPLOY_USER, want '${want_ssh[$key]}']"
    done
  fi

  if [[ -n $bad ]]; then
    fail "the deploy account is not restricted as it should be:$bad"
  else
    pass "the deploy account ($OC_DEPLOY_USER): no password, no group but its own; one key line per environment (${OC_ENV_LIST[*]}), each command=\"$OC_DEPLOY_FORCED <env>\",restrict with its own key; sshd gives it no terminal, forwarding or agent; sudo lets it run one script with one argument shape; what it runs is root's"
  fi
}

# check_dep_02: try, as the deploy user itself, to read what it must not read and write what it
# must not write. Two controls come first: if the account cannot be run as at all, or cannot do
# what it is meant to do, every "cannot" below would pass for the wrong reason, so the check fails.
check_dep_02() {
  local bad="" env d f readable u rc out
  local -a lookat=()
  if [[ $OC_DEPLOY_ENABLED != yes ]]; then
    if getent passwd "$OC_DEPLOY_USER" >/dev/null; then
      fail "the deploy account is switched off but the user $OC_DEPLOY_USER still exists"
    else
      pass "the deploy account is switched off; there is nobody to check"
    fi
    return 0
  fi
  if ! oc_have runuser; then
    fail "runuser is missing, so what the deploy user can read cannot be tried"
    return 0
  fi
  if ! getent passwd "$OC_DEPLOY_USER" >/dev/null; then
    fail "the deploy user $OC_DEPLOY_USER does not exist"
    return 0
  fi
  as_deploy() { runuser -u "$OC_DEPLOY_USER" -- "$@"; }
  if ! as_deploy test -r /etc/os-release; then
    fail "cannot run a command as $OC_DEPLOY_USER (runuser failed), so what it can read cannot be tried"
    return 0
  fi
  as_deploy test -w "$OC_DEPLOY_SPOOL" || bad+=" [control: $OC_DEPLOY_USER cannot write its own spool folder $OC_DEPLOY_SPOOL]"

  # not readable: the secrets folder (and every file in it) and every environment's data. A folder that
  # is not there cannot be tried: that is a failure, not a pass (a missing /etc/oc would otherwise
  # look like a folder nobody can read).
  if [[ ! -d $OC_SECRET_DIR ]]; then
    bad+=" [$OC_SECRET_DIR does not exist, so it cannot be checked]"
  else
    if as_deploy ls -- "$OC_SECRET_DIR" >/dev/null 2>&1; then bad+=" [can list $OC_SECRET_DIR]"; fi
    for f in "$OC_SECRET_DIR"/*; do
      [[ -e $f ]] || continue
      if as_deploy test -r "$f"; then bad+=" [can read $f]"; fi
    done
  fi
  for env in "${OC_ENV_LIST[@]}"; do
    lookat=("$OC_DATA_ROOT/$env" "$OC_DATA_ROOT/$env/media" "$OC_DATA_ROOT/$env/private" "$OC_DATA_ROOT/$env/tmp" "$(oc_env_home "$env")" "$(oc_env_quadlet_dir "$env")")
    for d in "${lookat[@]}"; do
      if [[ ! -d $d ]]; then
        bad+=" [$d does not exist, so it cannot be checked]"
        continue
      fi
      if as_deploy test -r "$d"; then bad+=" [can read $d]"; fi
      if as_deploy test -x "$d"; then bad+=" [can enter $d]"; fi
    done
  done
  # MariaDB: its files hold every database (password hashes included), and its socket is open to every
  # local user, so the only thing between the deploy account and the data is that it has no login.
  if [[ ! -d $OC_MARIADB_DATADIR ]]; then
    bad+=" [$OC_MARIADB_DATADIR does not exist, so it cannot be checked]"
  else
    # (what the server itself owns: the data, logs and system tables. The package leaves a few
    # root-owned notes there, such as mariadb_upgrade_info, which anyone may read.)
    getent passwd mysql >/dev/null || bad+=" [the user mysql does not exist, so the MariaDB data folder cannot be checked]"
    # shellcheck disable=SC2016  # the sh -c program is single-quoted on purpose
    readable=$(find "$OC_MARIADB_DATADIR" -maxdepth 2 -mindepth 1 -user mysql -print0 2>/dev/null |
      xargs -0 -r runuser -u "$OC_DEPLOY_USER" -- sh -c 'for p; do if test -r "$p"; then echo "$p"; fi; done' sh 2>/dev/null | head -n 3 | tr '\n' ' ')
    [[ -z $readable ]] || bad+=" [can read in the MariaDB data folder: $readable]"
  fi
  if ! oc_have mariadb; then
    bad+=" [the mariadb client is missing, so a sign-in to MariaDB through its socket cannot be tried]"
  elif [[ ! -S $OC_MARIADB_SOCKET ]]; then
    bad+=" [the MariaDB socket $OC_MARIADB_SOCKET does not exist (is MariaDB running?), so a sign-in cannot be tried]"
  else
    for u in root "$OC_DEPLOY_USER" "${OC_ENV_LIST[@]/#/oc_}"; do
      rc=0
      out=$(timeout 15 runuser -u "$OC_DEPLOY_USER" -- mariadb --no-defaults --protocol=socket --socket="$OC_MARIADB_SOCKET" -u "$u" -e 'SELECT 1' 2>&1) || rc=$?
      if [[ $rc -eq 0 ]]; then
        bad+=" [$OC_DEPLOY_USER can sign in to MariaDB through its socket as '$u']"
      elif [[ $out != *"Access denied"* ]]; then
        # refused for some other reason (no server answering, a broken client): that proves nothing
        bad+=" [could not tell whether $OC_DEPLOY_USER can sign in to MariaDB as '$u': ${out:0:80}]"
      fi
    done
  fi
  # /var/log: it may not write there (it could plant or replace a log), and may not read the logs of
  # who signed in and what sudo ran
  if [[ ! -d /var/log ]]; then
    bad+=" [/var/log does not exist, so it cannot be checked]"
  else
    if as_deploy test -w /var/log; then bad+=" [can write /var/log]"; fi
    for f in /var/log/auth.log /var/log/syslog /var/log/sudo.log /var/log/audit; do
      [[ -e $f ]] || continue
      if as_deploy test -r "$f"; then bad+=" [can read $f]"; fi
    done
  fi
  # not writable: its own home, the configuration, what it runs, the sudo and sshd files
  for f in "$OC_DEPLOY_HOME" "$OC_SECRET_DIR" "$OC_DATA_ROOT" /etc /etc/sudoers.d /etc/ssh /etc/ssh/sshd_config.d "$OC_DEPLOY_DIR" "$OC_DEPLOY_FORCED" \
    "$OC_DEPLOY_APPLY" "$OC_DEPLOY_LIMITS" "$OC_DEPLOY_KEYS" "$OC_DEPLOY_SUDOERS" /usr/local/sbin /usr/local/bin; do
    [[ -e $f ]] || continue
    if as_deploy test -w "$f"; then bad+=" [can write $f]"; fi
  done
  # and it cannot become anyone else: sudo allows nothing but the one script
  if as_deploy sudo -n true >/dev/null 2>&1; then bad+=" [sudo -n true works for $OC_DEPLOY_USER]"; fi
  if as_deploy sudo -n -i true >/dev/null 2>&1; then bad+=" [a root shell through sudo works for $OC_DEPLOY_USER]"; fi

  if [[ -n $bad ]]; then
    fail "the deploy user reaches what it must not:$bad"
  else
    pass "the deploy user cannot read $OC_SECRET_DIR, any environment's data folder or home, MariaDB's data folder or the logs of sign-ins and sudo; cannot sign in to MariaDB; cannot write anywhere but its spool folder; and cannot run any other command through sudo"
  fi
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
  # With IPV6=no ufw leaves IPv6 alone: the IPv6 rules (the Cloudflare IPv6 ranges, SSH) would not
  # be loaded and the default policy would not apply to IPv6 traffic.
  if ! grep -q '^IPV6=yes$' /etc/default/ufw 2>/dev/null; then
    fail "/etc/default/ufw does not say IPV6=yes, so ufw would not filter IPv6 traffic at all (set IPV6=yes, then run: ufw reload)"
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

# nginx_parse_summary: the counts from the T| line of nginx_servers (used by NET-03).
nginx_parse_summary() {
  # Sets: NS_UNBALANCED NS_ORPHAN_SSL NS_PARSED_SSL NS_SSL_DIRECTIVES, from the T| line.
  local t
  t=$(grep '^T|' <<<"$NGINX_SERVERS" | head -n 1)
  IFS='|' read -r _ NS_PARSED_SSL _ NS_ORPHAN_SSL NS_UNBALANCED NS_SSL_DIRECTIVES <<<"$t"
}

check_net_03() {
  local line type names ssl rej ver cc proto ports own n=0 bad="" name tested=0 code indep quoted sslcount p url skipped="" why
  local NS_PARSED_SSL=0 NS_ORPHAN_SSL=0 NS_UNBALANCED=0 NS_SSL_DIRECTIVES=0
  if [[ -z $NGINX_SERVERS ]]; then
    fail "cannot read the Nginx configuration (is nginx installed and does nginx -T pass?)"
    return 0
  fi
  nginx_parse_summary
  if [[ ${NS_UNBALANCED:-1} != 0 ]]; then
    fail "the Nginx configuration could not be read reliably (unbalanced braces or quotes, or a listen address this check cannot place on a port), so TLS cannot be vouched for"
    return 0
  fi
  [[ ${NS_ORPHAN_SSL:-0} == 0 ]] || bad+=" [${NS_ORPHAN_SSL} TLS listen directive(s) outside any server block]"
  # A second, independent count of the "listen ... ssl" statements in the text. The parser
  # and this count must agree, so a layout the parser does not understand cannot hide a site.
  indep=$(nginx_tls_listen_count "$NGINX_T")
  quoted=$(nginx_quoted_listen_count "$NGINX_T")
  [[ $quoted -eq 0 ]] || bad+=" [$quoted listen statement(s) contain a quote character, which this check does not interpret]"
  if [[ $indep -ne $((NS_PARSED_SSL + NS_ORPHAN_SSL)) ]]; then
    bad+=" [the configuration has $indep TLS listen statements but the parser accounted for $((NS_PARSED_SSL + NS_ORPHAN_SSL))]"
  fi
  # The old "ssl on;" switches TLS on for a server whose listen says nothing about it, or for all
  # of them from the http level, and Nginx reads its value without regard to case ("ssl ON;"). It
  # is refused at every level and with every value; TLS is switched on with "listen ... ssl".
  [[ ${NS_SSL_DIRECTIVES:-0} == 0 ]] || bad+=" [${NS_SSL_DIRECTIVES} 'ssl' directive(s): the old way to switch TLS on, which can make a server TLS that no listen says is, so it is not accepted; write 'listen ... ssl' instead]"
  sslcount=$(nginx_ssl_directive_count "$NGINX_T")
  if [[ $sslcount -ne ${NS_SSL_DIRECTIVES:-0} ]]; then
    bad+=" [the configuration has $sslcount statements that start with 'ssl' but the parser accounted for ${NS_SSL_DIRECTIVES:-0} ssl directives]"
  fi
  while IFS='|' read -r type names ssl _ rej ver cc proto ports own; do
    [[ $type == S && $ssl == 1 && $rej == 0 ]] || continue
    n=$((n + 1))
    why=""
    [[ $own == 1 ]] || why=" (TLS only because another server listens with ssl on the same port: ${ports:-80}; Nginx serves every server of that port over TLS)"
    if [[ ${ver,,} != on ]]; then
      bad+=" [${names:-unnamed server}: ssl_verify_client '$ver'$why]"
    elif [[ -z $cc || ! -f $cc ]]; then
      bad+=" [${names:-unnamed server}: client certificate file missing$why]"
    elif ! cmp -s -- "$cc" "$OC_INFRA_DIR/nginx/cloudflare-origin-pull-ca.pem"; then
      bad+=" [${names:-unnamed server}: client CA differs from infra/nginx/cloudflare-origin-pull-ca.pem$why]"
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
  if ! systemctl is-active --quiet nginx; then
    fail "nginx is not running"
    return 0
  fi
  # Live: every host name of every TLS site, on every TLS port it listens on (not only 443), must
  # refuse a request without the certificate. A name that cannot be requested by name (a wildcard,
  # "_", a regular expression) is not tested here: it is listed in the result, so the check never
  # silently covers less than it says.
  while IFS='|' read -r type names ssl _ rej _ _ _ ports _; do
    [[ $type == S && $ssl == 1 && $rej == 0 ]] || continue
    if [[ -z $names ]]; then
      skipped+=" [an unnamed server (ports ${ports:-?}): it has no host name to request]"
      continue
    fi
    for p in $ports; do
      if [[ $p == unix:* ]]; then
        skipped+=" [$names on $p: a unix socket is not requested over TCP]"
        continue
      fi
      for name in $names; do
        if [[ ! $name =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
          skipped+=" [$name on port $p: a wildcard, '_' or regular-expression name cannot be requested by name]"
          continue
        fi
        tested=$((tested + 1))
        url="https://$name/"
        [[ $p == 443 ]] || url="https://$name:$p/"
        code=$(curl -sk --max-time 10 -o /dev/null -w '%{http_code}' --resolve "$name:$p:127.0.0.1" "$url" 2>/dev/null)
        [[ $code == 400 ]] || bad+=" [$name on port $p answered $code to a request without a client certificate]"
      done
    done
  done <<<"$NGINX_SERVERS"
  if ((tested == 0)); then
    fail "no TLS host name could be tested live${skipped:+; skipped:$skipped}"
  elif [[ -n $bad ]]; then
    fail "a request without Cloudflare's client certificate was not refused:$bad"
  else
    pass "all $n TLS sites require Cloudflare's client certificate; a request without one is refused on all $tested host name and port pairs${skipped:+. NOT TESTED LIVE (covered by the configuration check only):$skipped}"
  fi
}

check_ngx_01() {
  local type names ssl rej ver cc proto p bad="" name val off=0 sizes=0 body=0 header=0
  if [[ -z $NGINX_SERVERS ]]; then
    fail "cannot read the Nginx configuration"
    return 0
  fi
  while IFS='|' read -r type names ssl _ rej ver cc proto _; do
    [[ $type == S && $ssl == 1 ]] || continue
    [[ -n $proto ]] || bad+=" [${names:-unnamed server}: no ssl_protocols]"
    for p in $proto; do
      [[ $p == TLSv1.2 || $p == TLSv1.3 ]] || bad+=" [${names:-unnamed server}: allows $p]"
    done
  done <<<"$NGINX_SERVERS"
  # The tokenizer reports every use of these directives, wherever it stands in the text (a
  # one-line server, after a ; or a {, in a location): a search for them at the start of a line
  # would miss one that is not. Values are compared without regard to case, as Nginx reads them.
  while IFS='|' read -r type name val; do
    [[ $type == D ]] || continue
    case $name in
      server_tokens)
        if [[ ${val,,} == off ]]; then off=$((off + 1)); else bad+=" [server_tokens is '$val' somewhere: it must be off everywhere]"; fi
        ;;
      client_max_body_size)
        sizes=$((sizes + 1))
        [[ ${val,,} == 30m ]] || bad+=" [client_max_body_size is '$val' somewhere: the limit is 30m everywhere]"
        ;;
      client_body_timeout) body=1 ;;
      client_header_timeout) header=1 ;;
      *) ;;
    esac
  done <<<"$NGINX_SERVERS"
  ((off > 0)) || bad+=" [server_tokens is not off]"
  ((sizes > 0)) || bad+=" [client_max_body_size 30m missing]"
  ((body > 0)) || bad+=" [client_body_timeout missing]"
  ((header > 0)) || bad+=" [client_header_timeout missing]"
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
# These Quadlet files belong to the same user the containers run as, so they are exactly what
# a compromised app would try to change. Everything below is therefore an ALLOW-list: a
# section, key, mount, flag or environment name that is not named here fails the check.
# When a template legitimately gains a line, this is the one place to add it.

# qnorm FILE: a Quadlet (systemd-style) file as "section US key US value" records (US is the
# character 0x1f). It reads the syntax the way systemd does, so tampering cannot hide in a
# spelling the checks do not expect: spaces or tabs around the key and the =, comment lines
# (# and ;) skipped. A comment line is recognised BEFORE anything else, and a backslash at its
# end does not continue it; only a Key=value line can be continued by a trailing backslash
# (the lines are joined with a space). Where parsers differ in the rest (a comment line that
# ends in a backslash, a comment inside a continued line, a continuation on a line that is not
# Key=value), the line is not guessed at: it becomes a record with an empty key, which the
# checks reject. The file then fails instead of being read one way here and another way by
# Podman. Every other line is read the same by both.
qnorm() {
  # shellcheck disable=SC2016  # an awk program: the $ signs are awk's, not the shell's
  "$AWK" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function odd(msg) { print section "\037\037" msg }
    function emit(line,   t, eq) {
      t = trim(line)
      if (t == "") return
      if (t ~ /^\[.*\]$/) { section = substr(t, 2, length(t) - 2); return }
      eq = index(t, "=")
      if (eq == 0) { odd(t); return }
      print section "\037" trim(substr(t, 1, eq - 1)) "\037" trim(substr(t, eq + 1))
    }
    {
      line = $0; sub(/\r$/, "", line)
      t = trim(line)
      if (t ~ /^[#;]/) {
        if (t ~ /\\$/) odd("a comment line ends with a backslash")
        if (pending != "") odd("a comment line inside a continued line")
        next
      }
      if (pending != "") { line = pending " " line; pending = ""; t = trim(line) }
      if (line ~ /\\$/) {
        if (t ~ /^\[/ || index(t, "=") == 0) { odd("a line that is not Key=value ends with a backslash"); next }
        sub(/\\$/, "", line); pending = line; next
      }
      emit(line)
    }
    END { if (pending != "") emit(pending) }
  ' "$1"
}

Q_US=$'\037'

# q_allowed_keys SECTION: the keys a file may use in that section (fails for an unknown section).
q_allowed_keys() {
  case $1 in
    Unit) echo "Description" ;;
    Container) echo "ContainerName Image Pull UserNS User Group ReadOnly DropCapability NoNewPrivileges Tmpfs PidsLimit PodmanArgs Environment EnvironmentFile Network PublishPort Volume HealthCmd HealthInterval HealthTimeout HealthRetries HealthStartPeriod" ;;
    Service) echo "Restart RestartSec TimeoutStartSec TimeoutStopSec" ;;
    Install) echo "WantedBy" ;;
    *) return 1 ;;
  esac
}

# q_env_problem ROLE NAME VALUE: why an environment variable may not be set by a Quadlet file.
q_env_problem() {
  local role=$1 name=$2 value=$3 allowed
  if [[ $role == cms ]]; then
    allowed="NODE_OPTIONS HOST PORT DATABASE_SOCKET_PATH OC_CLAMD_SOCKET"
  else
    allowed="NODE_OPTIONS HOST PORT OC_CMS_URL"
  fi
  word_in "$allowed" "$name" || {
    echo "environment variable $name is not allowed"
    return 0
  }
  if [[ $name == NODE_OPTIONS && ! $value =~ ^--max-old-space-size=[0-9]+$ ]]; then
    echo "NODE_OPTIONS may only set --max-old-space-size"
  fi
}

# q_expected_volumes ENV ROLE: the mounts a container may have, one per line (src:dst[:ro]).
q_expected_volumes() {
  local env=$1 role=$2
  if [[ $role == cms ]]; then
    printf '%s\n' "$OC_DATA_ROOT/$env:$OC_DATA_ROOT/$env" \
      "$OC_MARIADB_RUN_DIR:$OC_MARIADB_RUN_DIR:ro" "$OC_CLAMD_RUN_DIR:$OC_CLAMD_RUN_DIR:ro"
  else
    printf '%s\n' "$OC_DATA_ROOT/$env/media:$OC_DATA_ROOT/$env/media:ro"
  fi
}

# q_env_file ENV ROLE: the one environment file a container may use.
q_env_file() {
  if [[ $2 == web ]]; then
    printf '%s/%s.web.env' "$OC_SECRET_DIR" "$1"
  else
    printf '%s/%s.env' "$OC_SECRET_DIR" "$1"
  fi
}

# q_tmpfs_problem VALUE: why a tmpfs mount may not be used (nothing when it is fine). It is for /tmp
# only, and its options may not turn on what Podman leaves off by default for a tmpfs (exec, suid,
# dev): "exec" after "noexec" wins, so a plain search for noexec would not be enough.
q_tmpfs_problem() {
  local val=$1 o
  local -a opts=()
  if [[ $val != /tmp && $val != /tmp:* ]]; then
    echo "is not for /tmp"
    return 0
  fi
  [[ $val == *:* ]] || return 0
  IFS=, read -r -a opts <<<"${val#*:}"
  for o in "${opts[@]}"; do
    case $o in
      exec | suid | dev)
        echo "has the option '$o' (the tmpfs must stay noexec, nosuid and nodev)"
        return 0
        ;;
      *) ;;
    esac
  done
}

# q_check_container FILE ENV ROLE: one problem per line for a Quadlet container file.
q_check_container() {
  local f=$1 env=$2 role=$3 qn uid gid sec key val allowed n v arg expected host_port internal got
  qn=$(qnorm "$f")
  uid=$(oc_env_uid "$env")
  gid=$(oc_env_gid "$env")
  [[ -n $uid && -n $gid ]] || {
    echo "user oc-$env does not exist"
    return 0
  }
  if [[ $role == cms ]]; then
    host_port=$(oc_cms_port "$env")
    internal=$OC_CMS_INTERNAL_PORT
  else
    host_port=$(oc_web_port "$env")
    internal=$OC_WEB_INTERNAL_PORT
  fi
  qget() { awk -F"$Q_US" -v s="$1" -v k="$2" '$1 == s && $2 == k {print $3}' <<<"$qn"; }
  qcount() { awk -F"$Q_US" -v s="$1" -v k="$2" '$1 == s && $2 == k {n++} END {print n + 0}' <<<"$qn"; }

  # 1. Only known sections and keys.
  while IFS="$Q_US" read -r sec key val; do
    [[ -n $sec$key$val ]] || continue
    if [[ -z $key ]]; then
      echo "a line that is not Key=value: '${val:0:50}'"
      continue
    fi
    if ! allowed=$(q_allowed_keys "$sec"); then
      echo "section [$sec] is not allowed"
      continue
    fi
    word_in "$allowed" "$key" || echo "key $key in [$sec] is not allowed"
  done <<<"$qn"

  # 2. Keys that must appear exactly once, with exactly the right value.
  for key in ContainerName Image Pull UserNS User Group ReadOnly DropCapability NoNewPrivileges PidsLimit EnvironmentFile Network Tmpfs HealthCmd PublishPort; do
    n=$(qcount Container "$key")
    [[ $n -eq 1 ]] || echo "$key appears $n times (exactly one is needed)"
  done
  [[ $(qget Container ContainerName) == "oc-$role-$env" ]] || echo "ContainerName is not oc-$role-$env"
  [[ $(qget Container Pull) == never ]] || echo "Pull is not never (a missing image must never be fetched from a registry)"
  [[ $(qget Container UserNS) == keep-id ]] || echo "UserNS is not keep-id"
  v=$(qget Container User)
  [[ $v == "$uid" && $uid -ne 0 ]] || echo "User is not the environment user's id ($uid), or is root"
  v=$(qget Container Group)
  [[ $v == "$gid" && $gid -ne 0 ]] || echo "Group is not the environment user's group ($gid), or is root"
  [[ $(qget Container ReadOnly) == true ]] || echo "ReadOnly is not true"
  [[ $(qget Container DropCapability) == ALL ]] || echo "DropCapability is not ALL"
  [[ $(qget Container NoNewPrivileges) == true ]] || echo "NoNewPrivileges is not true"
  [[ $(qget Container PidsLimit) =~ ^[1-9][0-9]*$ ]] || echo "no PidsLimit (a positive number)"
  v=$(q_tmpfs_problem "$(qget Container Tmpfs)")
  [[ -z $v ]] || echo "Tmpfs $v"
  expected=$(q_env_file "$env" "$role")
  [[ $(qget Container EnvironmentFile) == "$expected" ]] || echo "EnvironmentFile is not $expected"
  [[ $(qget Container Network) == "oc-$env.network" ]] || echo "Network is not oc-$env.network (the private network)"
  [[ $(qget Container PublishPort) == "127.0.0.1:$host_port:$internal" ]] || echo "PublishPort is not exactly 127.0.0.1:$host_port:$internal"
  [[ $(qget Container Image) =~ ^localhost/oc-(cms|web)(:[A-Za-z0-9._-]+|@sha256:[0-9a-f]{64})$ ]] || echo "Image is not a local oc-cms or oc-web image"
  [[ $(qget Container HealthCmd) == '["/nodejs/bin/node","/app/healthcheck.mjs"]' ]] || echo "HealthCmd is not the /app/healthcheck.mjs check"

  # 3. Mounts: exactly the expected ones.
  expected=$(q_expected_volumes "$env" "$role")
  got=$(qget Container Volume)
  while IFS= read -r v; do
    [[ -n $v ]] || continue
    [[ $'\n'$expected$'\n' == *$'\n'"$v"$'\n'* ]] || echo "Volume '$v' is not allowed"
  done <<<"$got"
  while IFS= read -r v; do
    [[ -n $v ]] || continue
    [[ $'\n'$got$'\n' == *$'\n'"$v"$'\n'* ]] || echo "the expected Volume '$v' is missing"
  done <<<"$expected"

  # 4. Environment variables, and extra podman arguments: names and flags on an allow-list.
  while IFS= read -r v; do
    [[ -n $v ]] || continue
    if [[ $v != *=* ]]; then
      echo "Environment '$v' is not NAME=value"
      continue
    fi
    q_env_problem "$role" "${v%%=*}" "${v#*=}"
  done < <(qget Container Environment)
  n=0
  while IFS= read -r v; do
    [[ -n $v ]] || continue
    for arg in $v; do
      case $arg in
        --memory=[1-9]*) n=$((n + 1)) ;;
        --memory-swap=[1-9]*) ;;
        --group-add=keep-groups) [[ $role == cms ]] || echo "the website must not keep the host's groups" ;;
        *) echo "PodmanArgs has '$arg', which is not on the allow-list" ;;
      esac
    done
  done < <(qget Container PodmanArgs)
  [[ $n -eq 1 ]] || echo "no memory limit (PodmanArgs=--memory=...)"

  # 5. The other sections.
  [[ $(qget Install WantedBy) == default.target ]] || echo "WantedBy is not default.target"
  while IFS="$Q_US" read -r sec key val; do
    [[ $sec == Service ]] || continue
    case $key in
      Restart) [[ $val == on-failure ]] || echo "Restart is not on-failure" ;;
      *) [[ $val =~ ^[0-9]+$ ]] || echo "$key is not a number of seconds" ;;
    esac
  done <<<"$qn"
}

# q_check_generated ENV ROLE LINE: one problem per line for the ExecStart= line of the podman
# run command that Podman's Quadlet generator produced. This is what would really run, so it
# is checked flag by flag: only the flags the templates produce are allowed, each with only
# its expected values. --privileged, --cap-add, --network=host, unconfined profiles, extra
# mounts, devices and namespaces all fall outside that.
q_check_generated() {
  local env=$1 role=$2 line=$3 uid gid i t flag val hasval seen_image=0 hp ip v name
  local -a tok=() missing=()
  local -A seen=() vols=()
  uid=$(oc_env_uid "$env")
  gid=$(oc_env_gid "$env")
  if [[ $role == cms ]]; then
    hp=$(oc_cms_port "$env")
    ip=$OC_CMS_INTERNAL_PORT
  else
    hp=$(oc_web_port "$env")
    ip=$OC_WEB_INTERNAL_PORT
  fi
  read -r -a tok <<<"${line#ExecStart=}"
  if [[ ${tok[0]:-} != /usr/bin/podman || ${tok[1]:-} != run ]]; then
    echo "the generated command is not /usr/bin/podman run"
    return 0
  fi
  i=2
  while ((i < ${#tok[@]})); do
    t=${tok[$i]}
    i=$((i + 1))
    if [[ $t != -* ]]; then
      if ((seen_image)); then
        echo "an extra argument after the image: '${t:0:40}'"
      else
        seen_image=1
        [[ $t =~ ^localhost/oc-(cms|web)(:[A-Za-z0-9._-]+|@sha256:[0-9a-f]{64})$ ]] || echo "the image '${t:0:60}' is not a local oc-cms or oc-web image"
      fi
      continue
    fi
    flag=$t
    val=""
    hasval=0
    if [[ $t == --*=* || $t == -d=* ]]; then
      flag=${t%%=*}
      val=${t#*=}
      hasval=1
    fi
    case $flag in
      --replace | --rm | -d | --read-only)
        # A switch: bare (on), or =true. "--read-only=false" and "--rm=false" are the same flags
        # with the opposite meaning, so a value is checked, not skipped.
        if ((hasval)) && [[ $val != true ]]; then
          echo "$flag is '$val': this switch must be bare (or =true), a value switches it off"
        else
          seen[$flag]=1
        fi
        continue
        ;;
      --name | --cidfile | --cgroups | --network | --sdnotify | --security-opt | --pids-limit | --cap-drop | --user | --userns | --tmpfs | -v | --publish | --env | --env-file | --health-cmd | --health-interval | --health-retries | --health-start-period | --health-timeout | --group-add | --memory | --memory-swap | --pull)
        if ((!hasval)); then
          val=${tok[$i]:-}
          i=$((i + 1))
        fi
        ;;
      *)
        echo "the generated command has the flag '$flag', which is not allowed"
        continue
        ;;
    esac
    seen[$flag]=1
    case $flag in
      --name) [[ $val == "oc-$role-$env" ]] || echo "--name is not oc-$role-$env" ;;
      --network) [[ $val == "oc-$env" ]] || echo "--network is '$val', not the private network oc-$env" ;;
      --security-opt) [[ $val == no-new-privileges ]] || echo "--security-opt '$val' is not allowed (only no-new-privileges)" ;;
      --cap-drop) [[ $val == all ]] || echo "--cap-drop is '$val', not all" ;;
      --userns) [[ $val == keep-id ]] || echo "--userns is '$val', not keep-id" ;;
      --user) [[ $val == "$uid:$gid" ]] || echo "--user is '$val', not $uid:$gid" ;;
      --pids-limit) [[ $val =~ ^[1-9][0-9]*$ ]] || echo "--pids-limit '$val' is not a positive number" ;;
      --memory | --memory-swap) [[ $val =~ ^[1-9][0-9]*[kKmMgG]?$ ]] || echo "$flag '$val' is not a size" ;;
      --pull) [[ $val == never ]] || echo "--pull is '$val', not never" ;;
      --tmpfs)
        v=$(q_tmpfs_problem "$val")
        [[ -z $v ]] || echo "--tmpfs '$val' $v"
        ;;
      --publish) [[ $val == "127.0.0.1:$hp:$ip" ]] || echo "--publish '$val' is not exactly 127.0.0.1:$hp:$ip" ;;
      --env-file) [[ $val == "$(q_env_file "$env" "$role")" ]] || echo "--env-file is '$val', not $(q_env_file "$env" "$role")" ;;
      --group-add) [[ $val == keep-groups && $role == cms ]] || echo "--group-add '$val' is not allowed here" ;;
      --health-cmd)
        v=${val//[\\\"]/}
        [[ $v == '[/nodejs/bin/node,/app/healthcheck.mjs]' ]] || echo "--health-cmd is not the /app/healthcheck.mjs check"
        ;;
      --env)
        name=${val%%=*}
        q_env_problem "$role" "$name" "${val#*=}"
        ;;
      -v)
        vols[$val]=1
        [[ $'\n'$(q_expected_volumes "$env" "$role")$'\n' == *$'\n'"$val"$'\n'* ]] || echo "the mount '$val' is not allowed"
        ;;
      *) ;;
    esac
  done
  ((seen_image)) || echo "the generated command has no image"
  for flag in --read-only --cap-drop --security-opt --userns --user --pids-limit --memory --publish --network --env-file --tmpfs --health-cmd --pull; do
    [[ -n ${seen[$flag]:-} ]] || missing+=("$flag")
  done
  [[ ${#missing[@]} -eq 0 ]] || echo "the generated command lacks: ${missing[*]}"
  while IFS= read -r v; do
    [[ -n $v ]] || continue
    [[ -n ${vols[$v]:-} ]] || echo "the generated command lacks the mount '$v'"
  done < <(q_expected_volumes "$env" "$role")
}

# q_check_dir ENV: the Quadlet folder holds exactly the three files, as plain files. A drop-in
# folder (oc-web-prod.container.d/), a second container file or anything else is a way to
# change what runs, so it fails. In a running system the user's runtime Quadlet folder must
# be empty too.
q_check_dir() {
  local env=$1 qdir name uid rdir sec key val
  local -a want=()
  qdir=$(oc_env_quadlet_dir "$env")
  want=("oc-$env.network" "oc-cms-$env.container" "oc-web-$env.container")
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    word_in "${want[*]}" "$name" || echo "unexpected entry '$name' in $qdir"
  done < <(find "$qdir" -mindepth 1 -printf '%P\n' 2>/dev/null)
  find "$qdir" -mindepth 1 ! -type f -printf '%P is not a plain file\n' 2>/dev/null
  # The network file: only its name.
  while IFS="$Q_US" read -r sec key val; do
    [[ -n $sec$key$val ]] || continue
    [[ $sec == Network && $key == NetworkName && $val == "oc-$env" ]] || echo "oc-$env.network has '${sec}/${key}', which is not allowed"
  done < <(qnorm "$qdir/oc-$env.network" 2>/dev/null)
  if ! in_container; then
    uid=$(oc_env_uid "$env")
    rdir=/run/user/$uid/containers/systemd
    if [[ -d $rdir && -n $(find "$rdir" -mindepth 1 -print -quit 2>/dev/null) ]]; then
      echo "the runtime Quadlet folder $rdir is not empty"
    fi
  fi
}

# q_check_units ENV GEN: one problem per line about the units Podman's Quadlet generator
# produced (GEN is its dry-run output). Exactly three units may come out of the three files:
# the network, and one service per container. In each container service the ONLY Exec lines
# are one ExecStart (the podman run command, checked flag by flag) and the generator's own
# ExecStop and ExecStopPost "podman rm" forms, exactly. Any other Exec key (ExecStartPre,
# ExecStartPost, ExecReload, ExecCondition, Exec=, a second ExecStart, ...), and any "podman
# run" or "podman create" anywhere but the one ExecStart, is refused: those would run a second
# container that the flag check never sees.
q_check_units() {
  local env=$1 gen=$2 kind a b c block role key val expected n
  local -A seen=() starts=()
  expected="oc-cms-$env.service oc-web-$env.service oc-$env-network.service"
  # shellcheck disable=SC2016  # the awk program at the end of this loop: its $ signs are awk's, not the shell's
  while IFS="$Q_US" read -r kind a b c; do
    case $kind in
      B)
        word_in "$expected" "$a" || echo "the generator produced an unexpected unit '$a'"
        seen[$a]=1
        ;;
      E)
        block=$a key=$b val=$c
        case $block in
          "oc-$env-network.service")
            if [[ $key != ExecStart || $val != "/usr/bin/podman network create --ignore oc-$env" ]]; then
              echo "$block: $key=${val:0:60} is not the generator's own network command"
            fi
            starts[$block]=$((${starts[$block]:-0} + 1))
            ;;
          "oc-cms-$env.service" | "oc-web-$env.service")
            role=${block#oc-}
            role=${role%%-*}
            case $key in
              ExecStart)
                starts[$block]=$((${starts[$block]:-0} + 1))
                while IFS= read -r n; do
                  [[ -n $n ]] && echo "$block: $n"
                done < <(q_check_generated "$env" "$role" "ExecStart=$val")
                ;;
              ExecStop) [[ $val == "/usr/bin/podman rm -v -f -i --cidfile=%t/%N.cid" ]] || echo "$block: ExecStop=${val:0:60} is not the generator's own podman rm" ;;
              ExecStopPost) [[ $val == "-/usr/bin/podman rm -v -f -i --cidfile=%t/%N.cid" ]] || echo "$block: ExecStopPost=${val:0:60} is not the generator's own podman rm" ;;
              *) echo "$block: the generated unit has $key=, which is not allowed" ;;
            esac
            ;;
          *) echo "$block: an Exec line ($key) in a unit that should not have one" ;;
        esac
        ;;
      R) echo "$a: 'podman run' or 'podman create' outside ExecStart: ${b:0:60}" ;;
      *) ;;
    esac
  done < <(printf '%s\n' "$gen" | "$AWK" '
    /^---.*---$/ { block = substr($0, 4, length($0) - 6); print "B\037" block; next }
    /^[ \t]*Exec[A-Za-z]*[ \t]*=/ {
      s = $0; sub(/^[ \t]+/, "", s); i = index(s, "=")
      k = substr(s, 1, i - 1); sub(/[ \t]+$/, "", k)
      v = substr(s, i + 1); sub(/^[ \t]+/, "", v)
      print "E\037" block "\037" k "\037" v; next
    }
    /^[ \t]*[#;]/ { next }
    /podman.*[ \t](run|create)([ \t]|$)/ { print "R\037" block "\037" $0 }
  ')
  for block in $expected; do
    [[ -n ${seen[$block]:-} ]] || echo "the generator produced no $block"
    [[ ${starts[$block]:-0} -eq 1 ]] || echo "$block has ${starts[$block]:-0} ExecStart lines (exactly one is needed)"
  done
}

check_ctr_01() {
  local env role f qdir p bad="" n=0 gen rc problems
  for env in "${OC_ENV_LIST[@]}"; do
    qdir=$(oc_env_quadlet_dir "$env")
    if [[ ! -d $qdir ]]; then
      bad+=" [$qdir missing]"
      continue
    fi
    while IFS= read -r p; do
      [[ -n $p ]] && bad+=" [oc-$env: $p]"
    done < <(q_check_dir "$env")
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
    # Podman's own Quadlet generator must accept the files, and what it generates is checked
    # flag by flag (a second look, at what would really run).
    if [[ -x /usr/libexec/podman/quadlet ]]; then
      rc=0
      gen=$(QUADLET_UNIT_DIRS="$qdir" /usr/libexec/podman/quadlet -dryrun -user 2>&1) || rc=$?
      problems=$(grep '^quadlet-generator' <<<"$gen" | grep -v 'Loading source unit file' || true)
      if [[ $rc -ne 0 || -n $problems ]]; then
        bad+=" [oc-$env: the Quadlet generator rejects the files: ${problems:0:120}]"
      else
        while IFS= read -r p; do
          [[ -n $p ]] && bad+=" [oc-$env generated: $p]"
        done < <(q_check_units "$env" "$gen")
      fi
    else
      bad+=" [the Podman Quadlet generator (/usr/libexec/podman/quadlet) is missing]"
    fi
  done
  if [[ -n $bad ]]; then
    fail "container definitions are not safe:$bad"
  else
    pass "$n Quadlet files hold only allowed settings: non-root user mapping, read-only root, no capabilities, no-new-privileges, memory and pids limits, ports on 127.0.0.1 only, own data folder only, no container socket, each its own environment file; Podman's generator accepts them and its command has no other flags"
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

# --- CTR-04: nothing in the environment user's own configuration changes what runs --------------
# The environment user owns its home. A unit file or drop-in in ~/.config/systemd/user, or a
# containers.conf, would change how its containers start without touching the Quadlet files that
# CTR-01 reads. So the home must hold none of them, and (on a running server) what systemd and Podman
# really have must match the hardening the templates ask for.

# ctr04_user ENV CMD...: a command as the environment user, with its runtime directory and its own
# systemd manager's bus (the same way the bootstrap talks to it).
ctr04_user() {
  local env=$1 uid
  shift
  uid=$(oc_env_uid "$env")
  runuser -u "oc-$env" -- env "HOME=$(oc_env_home "$env")" "XDG_RUNTIME_DIR=/run/user/$uid" \
    "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus" "$@"
}

# ctr04_unit_text ENV UNIT: `systemctl --user cat UNIT` (the unit as systemd really has it: the file
# and every drop-in, each introduced by a "# /path" line).
ctr04_unit_text() { ctr04_user "$1" systemctl --user cat "$2"; }

# ctr04_inspect_facts ENV ROLE: the facts about the running container, one per line (see q_check_inspect).
# `podman container exists` tells "no such container" (status 1) from "podman does not work" (125).
# shellcheck disable=SC2016  # a Go template: the $ signs are its own
CTR04_FORMAT='running={{.State.Running}}
privileged={{.HostConfig.Privileged}}
readonly={{.HostConfig.ReadonlyRootfs}}
user={{.Config.User}}
pids={{.HostConfig.PidsLimit}}
memory={{.HostConfig.Memory}}
effectivecaps={{len .EffectiveCaps}}
capadd={{len .HostConfig.CapAdd}}
securityopt={{range .HostConfig.SecurityOpt}}{{.}},{{end}}
networks={{range $k, $v := .NetworkSettings.Networks}}{{$k}},{{end}}
imagename={{.ImageName}}
imageid={{.ImageID}}
{{range .Mounts}}mount|{{.Type}}|{{.Source}}|{{.Destination}}|{{.RW}}
{{end}}{{range $d, $o := .HostConfig.Tmpfs}}tmpfs|{{$d}}|{{$o}}
{{end}}{{range $p, $b := .HostConfig.PortBindings}}{{range $b}}port|{{.HostIP}}|{{.HostPort}}|{{$p}}
{{end}}{{end}}'
ctr04_inspect_facts() {
  local env=$1 role=$2 rc=0
  ctr04_user "$env" podman container exists "oc-$role-$env" >/dev/null 2>&1 || rc=$?
  if [[ $rc -eq 1 ]]; then
    echo "absent"
    return 0
  fi
  [[ $rc -eq 0 ]] || return 1
  ctr04_user "$env" podman container inspect --format "$CTR04_FORMAT" "oc-$role-$env"
}

# q_check_inspect ENV ROLE FACTS: one problem per line about what a running container really is.
q_check_inspect() {
  local env=$1 role=$2 facts=$3 uid gid hp ip line key val kind a b c d own
  local -a mounts=() ports=() want=() topts=()
  local tmpfs_n=0 tmpfs_o
  uid=$(oc_env_uid "$env")
  gid=$(oc_env_gid "$env")
  if [[ $role == cms ]]; then
    hp=$(oc_cms_port "$env")
    ip=$OC_CMS_INTERNAL_PORT
  else
    hp=$(oc_web_port "$env")
    ip=$OC_WEB_INTERNAL_PORT
  fi
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    if [[ $line == mount\|* || $line == port\|* || $line == tmpfs\|* ]]; then
      IFS='|' read -r kind a b c d <<<"$line"
      if [[ $kind == mount ]]; then
        case $a in
          bind) mounts+=("$b:$c$([[ $d == true ]] || echo ':ro')") ;;
          *) echo "the container has a mount of type '$a' ($b to $c), which is not allowed" ;;
        esac
      elif [[ $kind == tmpfs ]]; then
        # (podman lists a tmpfs under HostConfig.Tmpfs: destination, then options such as rw,noexec,nosuid,size=64m,...)
        tmpfs_n=$((tmpfs_n + 1))
        if [[ $a != /tmp ]]; then
          echo "the container has a tmpfs at $a (only /tmp may be one)"
        else
          IFS=, read -r -a topts <<<"$b"
          word_in "${topts[*]//,/ }" noexec || echo "the tmpfs at /tmp is not noexec ('$b')"
          for tmpfs_o in "${topts[@]}"; do
            case $tmpfs_o in exec | suid | dev) echo "the tmpfs at /tmp has the option '$tmpfs_o' ('$b')" ;; *) ;; esac
          done
        fi
      else
        ports+=("$a:$b->$c")
      fi
      continue
    fi
    key=${line%%=*}
    val=${line#*=}
    case $key in
      running) [[ $val == true ]] || echo "the container is not running" ;;
      privileged) [[ $val == false ]] || echo "the container is privileged ('$val')" ;;
      readonly) [[ $val == true ]] || echo "the container's root file system is not read-only ('$val')" ;;
      user) [[ $val == "$uid:$gid" ]] || echo "the container runs as '$val', not $uid:$gid" ;;
      pids) [[ $val =~ ^[1-9][0-9]*$ ]] || echo "the container has no pids limit ('$val')" ;;
      memory) [[ $val =~ ^[1-9][0-9]*$ ]] || echo "the container has no memory limit ('$val')" ;;
      effectivecaps) [[ $val == 0 ]] || echo "the container has $val capabilities (all must be dropped)" ;;
      capadd) [[ $val == 0 ]] || echo "the container was given $val added capabilities" ;;
      securityopt)
        [[ ,$val == *,no-new-privileges,* ]] || echo "no-new-privileges is not set on the container ('$val')"
        [[ $val != *unconfined* ]] || echo "the container runs with an unconfined security option ('$val')"
        ;;
      networks) [[ $val == "oc-$env," ]] || echo "the container is on the networks '$val', not only oc-$env" ;;
      imagename) [[ $val =~ ^localhost/oc-$role(:[A-Za-z0-9._-]+|@sha256:[0-9a-f]{64})$ ]] || echo "the container runs the image '$val', which is not a local oc-$role image" ;;
      *) ;;
    esac
  done <<<"$facts"
  mapfile -t want < <(q_expected_volumes "$env" "$role")
  for own in "${want[@]}"; do
    word_in "${mounts[*]}" "$own" || echo "the container lacks the mount '$own'"
  done
  for own in "${mounts[@]}"; do
    word_in "${want[*]}" "$own" || echo "the container has the mount '$own', which is not allowed"
  done
  [[ $tmpfs_n -eq 1 ]] || echo "the container has $tmpfs_n tmpfs mounts, not exactly one (/tmp)"
  [[ ${#ports[@]} -eq 1 && ${ports[0]} == "127.0.0.1:$hp->$ip/tcp" ]] || echo "the container's published ports are '${ports[*]}', not exactly 127.0.0.1:$hp->$ip/tcp"
}

check_ctr_04() {
  local env home d p uid unit gen text bad="" notrun="" n=0 role facts f paths extra
  for env in "${OC_ENV_LIST[@]}"; do
    home=$(oc_env_home "$env")
    n=$((n + 1))
    # a check that cannot look fails: nothing can be said about a user, or a home, that is not there
    if [[ -z $(oc_env_uid "$env") || ! -d $home ]]; then
      bad+=" [oc-$env: the user, or its home $home, does not exist, so its configuration cannot be checked]"
      continue
    fi
    # 1. no unit of ours, and no drop-in, in the user's own systemd folders
    for d in "$home/.config/systemd/user" "$home/.local/share/systemd/user"; do
      [[ -e $d || -L $d ]] || continue
      if [[ -L $d ]]; then
        bad+=" [oc-$env: $d is a symbolic link]"
        continue
      fi
      while IFS= read -r p; do
        [[ -n $p ]] && bad+=" [oc-$env: $p is a user-level systemd unit or drop-in of ours, which would override what the Quadlet files generate]"
      done < <(find "$d" -mindepth 1 \( -name 'oc-*' -o -name 'oc-*.d' \) -print 2>/dev/null)
    done
    # 2. no containers.conf (it changes defaults: capabilities, runtime, hooks, ...)
    for p in "$home/.config/containers/containers.conf" "$home/.config/containers/containers.conf.d"; do
      if [[ -e $p || -L $p ]]; then
        bad+=" [oc-$env: $p exists; a containers.conf changes how Podman starts containers]"
      fi
    done
  done
  if in_container; then
    if [[ -n $bad ]]; then
      fail "the environment users' own configuration changes what runs:$bad"
    else
      pass "$n environment user(s): no user-level systemd unit or drop-in of ours, and no containers.conf (configuration; the live units and containers are compared on a real server)"
    fi
    return 0
  fi
  if ! oc_have runuser || ! oc_have podman; then
    fail "runuser or podman is missing, so what systemd and Podman really have cannot be compared"
    return 0
  fi
  # 3. live: the units systemd really has (each must come from the generator alone, with no
  # drop-in, and pass the same flag-by-flag check as the dry run), and the running containers
  for env in "${OC_ENV_LIST[@]}"; do
    uid=$(oc_env_uid "$env")
    [[ -n $uid ]] || continue # (already reported above)
    gen=""
    for unit in "oc-cms-$env.service" "oc-web-$env.service" "oc-$env-network.service"; do
      if ! text=$(ctr04_unit_text "$env" "$unit" 2>&1); then
        bad+=" [oc-$env: systemctl --user cat $unit failed: ${text:0:100}]"
        continue
      fi
      paths=$(grep '^# /' <<<"$text" | sed 's/^# //' || true)
      extra=$(grep -v "^/run/user/$uid/systemd/generator/$unit\$" <<<"$paths" | tr '\n' ' ' || true)
      [[ -z ${extra// /} ]] || bad+=" [oc-$env: $unit is not only what the generator wrote; systemd also reads: $extra]"
      gen+="---$unit---"$'\n'"$(grep -v '^# /' <<<"$text")"$'\n'
    done
    while IFS= read -r p; do
      [[ -n $p ]] && bad+=" [oc-$env live: $p]"
    done < <(q_check_units "$env" "$gen")
    for role in cms web; do
      if ! facts=$(ctr04_inspect_facts "$env" "$role" 2>&1); then
        bad+=" [oc-$env: podman could not be asked about oc-$role-$env: ${facts:0:100}]"
        continue
      fi
      if [[ $facts == absent ]]; then
        notrun+=" oc-$role-$env"
        continue
      fi
      while IFS= read -r p; do
        [[ -n $p ]] && bad+=" [oc-$role-$env: $p]"
      done < <(q_check_inspect "$env" "$role" "$facts")
    done
  done
  if [[ -n $bad ]]; then
    fail "what systemd and Podman really have is not the hardened set-up:$bad"
  elif [[ -n $notrun ]]; then
    warn "no unit or configuration problem, but these containers do not exist yet, so they were not compared with the hardening (nothing has been deployed?):$notrun"
  else
    pass "$n environment user(s): no user-level unit, drop-in or containers.conf; the units systemd has pass the flag-by-flag check; the running containers are read-only, unprivileged, capability-free, limited, on their own network, with only their own mounts and a loopback port"
  fi
}

check_svc_02() {
  local env cms web key bad="" missing n=0 stray extra a b f line
  for env in "${OC_ENV_LIST[@]}"; do
    cms="$OC_SECRET_DIR/$env.env"
    web="$OC_SECRET_DIR/$env.web.env"
    for f in "$cms" "$web"; do
      if [[ ! -f $f ]]; then
        bad+=" [$f missing]"
        continue
      fi
      n=$((n + 1))
      [[ $(stat -c '%a %U %G' -- "$f") == "640 root oc-$env" ]] || bad+=" [$f is $(stat -c '%a %U:%G' -- "$f"), want 640 root:oc-$env]"
    done
    # Only key NAMES are ever looked at or printed, never values.
    if [[ -f $cms ]]; then
      missing=""
      for key in "${USERS_CMS_KEYS[@]}"; do
        grep -q "^$key=" -- "$cms" || {
          missing+=" $key"
          continue
        }
        [[ -n $(users_file_value "$cms" "$key") ]] || missing+=" $key(empty)"
      done
      [[ -z $missing ]] || bad+=" [$cms lacks:$missing]"
    fi
    if [[ -f $web ]]; then
      missing=""
      for key in "${USERS_WEB_KEYS[@]}"; do
        grep -q "^$key=" -- "$web" || {
          missing+=" $key"
          continue
        }
        if [[ -z $(users_file_value "$web" "$key") ]] && ! word_in "${USERS_WEB_MAY_BE_EMPTY[*]}" "$key"; then
          missing+=" $key(empty)"
        fi
      done
      [[ -z $missing ]] || bad+=" [$web lacks:$missing]"
      # The website's file holds ONLY the website's keys. Anything else (a database setting,
      # a JWT secret, the file master key, ...) is a secret the website must not have. Podman reads
      # an environment file the way its own parser does: leading whitespace is dropped, and only a
      # line that starts with # is a comment. A line that starts with ; is NOT a comment there: it
      # is a variable whose name starts with ;, so it is looked at like any other line.
      extra=""
      while IFS= read -r line; do
        line=${line#"${line%%[![:space:]]*}"}
        [[ -z $line || $line == \#* ]] && continue
        if [[ $line =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]]; then
          key=${BASH_REMATCH[1]}
          word_in "${USERS_WEB_KEYS[*]}" "$key" || extra+=" $key"
        else
          extra+=" (a line that is not NAME=value)"
        fi
      done <"$web"
      [[ -z $extra ]] || bad+=" [$web holds keys the website must not have:$extra]"
    fi
    # The one shared secret must be the same in both files.
    if [[ -f $cms && -f $web ]]; then
      a=$(users_file_value "$cms" OC_INTERNAL_SECRET)
      b=$(users_file_value "$web" OC_INTERNAL_SECRET)
      if [[ -z $a || $a != "$b" ]]; then
        bad+=" [OC_INTERNAL_SECRET differs between $cms and $web, or is empty]"
      fi
    fi
  done
  stray=$(find "$OC_SECRET_DIR" -type f -perm /o+rwx 2>/dev/null | head -n 3 | tr '\n' ' ')
  [[ -z $stray ]] || bad+=" [world-accessible files in $OC_SECRET_DIR: $stray]"
  if [[ -n $bad ]]; then
    fail "secret files are wrong:$bad"
  else
    pass "$n secret file(s) are 0640 root:oc-<env>; the website's file holds only its own keys; OC_INTERNAL_SECRET matches in both files of each environment"
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
  # No account but the environment's own may hold ANY privilege on its database, whatever the
  # account is called (a backup user, a monitoring user, a leftover): the grants are read from the
  # server, at every level a privilege can be given: the database (the name may be a pattern, such as
  # oc%), a table, a column, and globally (ON *.*). The only global accounts are the ones the server
  # itself makes: root (unix socket), mariadb.sys and mysql.
  for env in "${OC_ENV_LIST[@]}"; do
    db="oc_$env"
    other=$(mariadb -N -B 2>/dev/null <<SQL
SELECT DISTINCT CONCAT(GRANTEE, ' (', LEVEL, ')') FROM (
  SELECT GRANTEE, 'on the database' AS LEVEL FROM information_schema.SCHEMA_PRIVILEGES WHERE '$db' LIKE TABLE_SCHEMA
  UNION ALL SELECT GRANTEE, 'on a table' FROM information_schema.TABLE_PRIVILEGES WHERE TABLE_SCHEMA = '$db'
  UNION ALL SELECT GRANTEE, 'on a column' FROM information_schema.COLUMN_PRIVILEGES WHERE TABLE_SCHEMA = '$db'
  UNION ALL SELECT GRANTEE, 'global' FROM information_schema.USER_PRIVILEGES WHERE PRIVILEGE_TYPE <> 'USAGE'
) AS g
WHERE GRANTEE <> '''oc_$env''@''localhost'''
  AND GRANTEE NOT IN ('''root''@''localhost''', '''mariadb.sys''@''localhost''', '''mysql''@''localhost''')
ORDER BY 1;
SQL
    ) || other="(the grants could not be read)"
    [[ -z $other ]] || bad+=" [$db can also be reached by: $(printf '%s' "$other" | tr '\n' ',' | sed 's/,$//')]"
  done
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
# tls_origin_ca_name FILE: does the certificate's issuer carry exactly the name of Cloudflare's Origin CA?
# Prints "ok|<the OU>" or "no|<why>". The issuer is read in openssl's multi-line form, one attribute per
# line, so a value cannot be mistaken for the separator of another. The rules, with no substring and no
# case-folding anywhere: exactly one O, exactly "CloudFlare, Inc."; exactly one OU, exactly one of the
# two names of Cloudflare's Origin CA; and no attribute besides those and C, ST and L (a CN, a DC or an
# extra OU is somewhere the text could be smuggled in).
tls_origin_ca_name() {
  local line type val o="" ou="" n_o=0 n_ou=0 any=0 why=""
  local want_o="CloudFlare, Inc." ou_rsa="CloudFlare Origin SSL Certificate Authority" ou_ecc="CloudFlare Origin SSL ECC Certificate Authority"
  while IFS= read -r line; do
    [[ $line =~ ^[[:space:]]+([A-Za-z0-9.]+)[[:space:]]+=[[:space:]](.*)$ ]] || continue
    any=1
    type=${BASH_REMATCH[1]}
    val=${BASH_REMATCH[2]}
    case $type in
      O)
        n_o=$((n_o + 1))
        o=$val
        ;;
      OU)
        n_ou=$((n_ou + 1))
        ou=$val
        ;;
      C | ST | L) ;;
      *) why+="the issuer has a $type attribute, which Cloudflare's Origin CA does not have; " ;;
    esac
  done < <(openssl x509 -in "$1" -noout -issuer -nameopt multiline,sname 2>/dev/null)
  if ((!any)); then
    echo "no|the issuer could not be read"
    return 0
  fi
  if ((n_o != 1)); then
    why+="the issuer has $n_o O attributes, not exactly one; "
  elif [[ $o != "$want_o" ]]; then
    why+="O is '$o', not exactly '$want_o'; "
  fi
  if ((n_ou == 0)); then
    why+="the issuer has no OU attribute; "
  elif ((n_ou != 1)); then
    why+="the issuer has $n_ou OU attributes, not exactly one; "
  elif [[ $ou != "$ou_rsa" && $ou != "$ou_ecc" ]]; then
    why+="OU is '$ou', not exactly '$ou_rsa' or '$ou_ecc'; "
  fi
  if [[ -z $why ]]; then
    echo "ok|$ou"
  else
    echo "no|${why%; }"
  fi
}

check_tls_01() {
  local subject issuer a b verdict
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
    return 0
  fi
  # Cloudflare in Full (strict) mode accepts an origin certificate only if Cloudflare's own Origin CA
  # issued it or a public CA did; anything else (a private CA, a staging CA) is answered with error 526.
  # Cloudflare's Origin CA is recognised by the NAME in the certificate's issuer, matched exactly, field
  # by field (tls_origin_ca_name). That is all it is: a name the certificate chose itself. A copy of
  # Cloudflare's Origin CA root is not kept in this repository, so the chain below it is NOT verified
  # (Task 4c: verify it against Cloudflare's published roots), and the result line says so. A public CA
  # is recognised by really verifying the chain against the system's CA bundle.
  verdict=$(tls_origin_ca_name "$OC_TLS_CERT")
  if [[ $verdict == ok\|* ]]; then
    pass "a real origin certificate is installed; its issuer is named as Cloudflare's Origin CA ('${verdict#ok|}', O 'CloudFlare, Inc.'). Only that NAME was checked: the chain was NOT verified (no copy of Cloudflare's Origin CA root is kept here), so a private CA that copies the name would pass; verify the chain against Cloudflare's published Origin CA roots ($(openssl x509 -in "$OC_TLS_CERT" -noout -enddate | sed 's/^notAfter=/expires /'))"
    return 0
  fi
  if openssl verify -purpose sslserver -CAfile /etc/ssl/certs/ca-certificates.crt -no-CApath -no-CAstore \
    -untrusted "$OC_TLS_CERT" "$OC_TLS_CERT" >/dev/null 2>&1; then
    pass "a real origin certificate is installed, issued by a publicly trusted CA ($(openssl x509 -in "$OC_TLS_CERT" -noout -enddate | sed 's/^notAfter=/expires /'))"
  else
    fail "the origin certificate's issuer (${issuer#issuer=}) is neither named exactly as Cloudflare's Origin CA (${verdict#no|}) nor a publicly trusted CA (its chain does not verify against /etc/ssl/certs/ca-certificates.crt): Cloudflare in Full (strict) mode would refuse it with error 526"
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
  "DEP-01 check_dep_01" "DEP-02 check_dep_02"
  "NET-01 check_net_01" "NET-02 check_net_02" "NET-03 check_net_03" "NET-04 check_net_04" "NET-05 check_net_05" "NET-06 check_net_06"
  "NGX-01 check_ngx_01"
  "OS-01 check_os_01" "OS-02 check_os_02" "OS-03 check_os_03" "OS-04 check_os_04" "OS-05 check_os_05"
  "OS-06 check_os_06" "OS-07 check_os_07" "OS-08 check_os_08"
  "CTR-01 check_ctr_01" "CTR-02 check_ctr_02" "CTR-03 check_ctr_03" "CTR-04 check_ctr_04"
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
  local config=${OC_CONFIG:-$OC_INFRA_DIR/server.env} cfg_err entry id known only="" ran=0
  local -a only_ids=() only_run=()
  oc_require_root
  # VERIFY_CONTAINER=1 reads written configuration instead of live state. On a real host that
  # would quietly stop checking the firewall, the services and Podman, so it is refused there,
  # the same way the bootstrap refuses OC_CONTAINER=1 on a host that is running systemd.
  if in_container && [[ -d /run/systemd/system ]]; then
    printf 'FAIL CFG-01 VERIFY_CONTAINER=1 is set but systemd is running on this machine. That setting is for the test container only; on a real server it would skip the live checks. Unset it and run verify.sh again.
'
    printf 'SUMMARY pass=0 fail=1 warn=0 skip=0
'
    exit 1
  fi
  # VERIFY_ONLY is honoured only where VERIFY_CONTAINER=1 is: a real host is verified in full, and a
  # variable left exported in a shell must not make it pass with fewer checks than it claims.
  if [[ -n ${VERIFY_ONLY+x} ]]; then
    if ! in_container; then
      printf 'FAIL CFG-02 VERIFY_ONLY is set but this is not the test container (VERIFY_CONTAINER is not 1). It would run fewer checks than the verifier has, so on a real server it is refused. Unset it and run verify.sh again.\n'
      printf 'SUMMARY pass=0 fail=1 warn=0 skip=0\n'
      exit 1
    fi
    read -r -a only_ids <<<"$VERIFY_ONLY"
    if [[ ${#only_ids[@]} -eq 0 ]]; then
      printf 'FAIL CFG-03 VERIFY_ONLY names no check (it is set, but empty): a selection of nothing would pass without checking anything. Unset it to run every check.\n'
      printf 'SUMMARY pass=0 fail=1 warn=0 skip=0\n'
      exit 1
    fi
    for id in "${only_ids[@]}"; do
      known=0
      for entry in "${CHECKS[@]}"; do
        [[ ${entry%% *} == "$id" ]] && known=1
      done
      if ((!known)); then
        printf 'FAIL CFG-03 VERIFY_ONLY names a check that does not exist: %s (a mistyped id would run nothing and pass)\n' "$id"
        printf 'SUMMARY pass=0 fail=1 warn=0 skip=0\n'
        exit 1
      fi
    done
    # the checks that will run, in the verifier's own order
    for entry in "${CHECKS[@]}"; do
      word_in "${only_ids[*]}" "${entry%% *}" && only_run+=("${entry%% *}")
    done
    only=$(IFS=,; printf '%s' "${only_run[*]}")
  fi
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
  if [[ -n $only ]]; then
    printf 'NOTE only ran: %s (VERIFY_ONLY is set: this is NOT a full verification)\n' "$only"
  fi
  load_facts
  for entry in "${CHECKS[@]}"; do
    if [[ -n $only ]] && ! word_in "${only_ids[*]}" "${entry%% *}"; then
      continue
    fi
    ran=$((ran + 1))
    run_check "${entry%% *}" "${entry#* }"
  done
  # a verification that ran nothing has verified nothing
  if ((ran == 0)); then
    N_FAIL=$((N_FAIL + 1))
    printf 'FAIL CFG-03 no check ran; a verification that checks nothing is a failure\n'
  fi
  printf 'SUMMARY pass=%d fail=%d warn=%d skip=%d%s\n' "$N_PASS" "$N_FAIL" "$N_WARN" "$N_SKIP" "${only:+ only=$only}"
  [[ $N_FAIL -eq 0 ]]
}

# Run unless this file is being sourced (the tests source it to exercise single functions).
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
