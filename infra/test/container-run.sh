#!/usr/bin/env bash
# Runs inside the test container (started by infra/test/run.sh). Not for use on a server.
#
#   container-run.sh shellcheck     shellcheck on every script
#   container-run.sh verify-only    verify.sh on a bare system: every check must fail
#   container-run.sh full           the whole proof (see the sections below)
set -euo pipefail
export LC_ALL=C

mode=${1:-full}
infra=/opt/oc-infra
work=/tmp/oc-test
FAILED=0

section() { printf '\n########## %s ##########\n' "$*"; }
ok() { printf 'ok     - %s\n' "$*"; }
notok() {
  printf 'NOT OK - %s\n' "$*"
  FAILED=$((FAILED + 1))
}

# expect DESCRIPTION CMD...: runs the command, reports ok or NOT OK.
expect() {
  local desc=$1
  shift
  if "$@" >"$work/expect.out" 2>&1; then
    ok "$desc"
  else
    notok "$desc"
    sed 's/^/         | /' "$work/expect.out" | head -n 20
  fi
}

# expect_fail DESCRIPTION CMD...: the command must fail.
expect_fail() {
  local desc=$1
  shift
  if "$@" >"$work/expect.out" 2>&1; then
    notok "$desc (it succeeded, it should have failed)"
    sed 's/^/         | /' "$work/expect.out" | head -n 20
  else
    ok "$desc"
  fi
}

# yes_if DESCRIPTION CMD...: ok when the command succeeds, NOT OK when it fails (no output shown).
yes_if() {
  local desc=$1
  shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else notok "$desc"; fi
}

scripts() {
  find "$infra" -type f \( -name '*.sh' -o -path "$infra/bin/*" \) -print0 | sort -z
}

run_shellcheck() {
  section "shellcheck"
  scripts | xargs -0 shellcheck -x --shell=bash -P "$infra:$infra/lib"
  printf 'shellcheck: clean (%s files)\n' "$(scripts | tr -cd '\0' | wc -c)"
}

make_settings() {
  mkdir -p "$work/keys"
  local u
  for u in alice bob; do
    [[ -f $work/keys/$u ]] || ssh-keygen -q -t ed25519 -N '' -C "$u@test" -f "$work/keys/$u"
  done
  cat >"$work/server.env" <<EOF
OC_DOMAIN=example.test
OC_ADMINS=alice:$work/keys/alice.pub,bob:$work/keys/bob.pub
OC_SSH_PORT=2222
OC_TIMEZONE=Africa/Lagos
OC_ENVS=prod staging
OC_SWAP_SIZE=2G
EOF
}

mkdir -p "$work"
export OC_CONFIG="$work/server.env"
export OC_CONTAINER=1 VERIFY_CONTAINER=1
export OC_CF_IPS_DIR="$infra/test/fixtures"
export OC_SKIP_LYNIS=1

if [[ $mode == shellcheck ]]; then
  run_shellcheck
  exit 0
fi

make_settings

# --------------------------------------------------------------------------------------
if [[ $mode == verify-only ]]; then
  section "RED: verify.sh on a system nothing has been set up on"
  rc=0
  bash "$infra/verify.sh" >"$work/verify-red.txt" 2>&1 || rc=$?
  cat "$work/verify-red.txt"
  passes=$(grep -c '^PASS ' "$work/verify-red.txt" || true)
  fails=$(grep -c '^FAIL ' "$work/verify-red.txt" || true)
  skips=$(grep -c '^SKIP ' "$work/verify-red.txt" || true)
  printf '\nRED result: %s FAIL, %s PASS, %s SKIP, verify.sh exit status %s\n' "$fails" "$passes" "$skips" "$rc"
  if ((passes > 0)); then
    printf 'A check passed on a bare system, so it checks nothing.\n' >&2
    exit 2
  fi
  [[ $rc -ne 0 ]] || exit 2
  exit 1
fi

# ======================================================================================
section "refusals before anything is installed"
bad_env() { printf '%s\n' "$1" >"$work/bad.env"; }
base="OC_DOMAIN=example.test
OC_ADMINS=alice:$work/keys/alice.pub
OC_SSH_PORT=2222"
bad_env "$base
OC_SSH_PORT=22"
expect_fail "SSH port 22 is refused" bash "$infra/bootstrap.sh" --config "$work/bad.env"
bad_env "$base
OC_SURPRISE=1"
expect_fail "an unknown setting is refused" bash "$infra/bootstrap.sh" --config "$work/bad.env"
bad_env "$base
OC_ADMINS=alice:$work/keys/alice"
expect_fail "a private key in place of the public key is refused" bash "$infra/bootstrap.sh" --config "$work/bad.env"
bad_env "OC_DOMAIN=example.test
OC_SSH_PORT=2222"
expect_fail "no admins is refused" bash "$infra/bootstrap.sh" --config "$work/bad.env"
bad_env "$base
OC_ADMINS=root:$work/keys/alice.pub"
expect_fail "an admin named root is refused" bash "$infra/bootstrap.sh" --config "$work/bad.env"
expect_fail "a non-root user is refused" runuser -u nobody -- bash "$infra/bootstrap.sh" --config "$work/server.env"
expect_fail "a missing settings file is refused" bash "$infra/bootstrap.sh" --config "$work/nope.env"

# --------------------------------------------------------------------------------------
snapshot() {
  # Content, mode, owner and modification time of every file in the places the setup writes.
  local out=$1 d
  : >"$out"
  for d in /etc/oc /etc/nginx /etc/ssh/sshd_config.d /etc/ufw /etc/default/ufw /etc/ssl/oc /etc/systemd/system \
    /etc/sudoers.d /etc/fail2ban /etc/audit/rules.d /etc/sysctl.d /etc/mysql /etc/clamav /etc/apt/apt.conf.d \
    /etc/apt/sources.list.d /etc/apt/preferences.d /etc/apt/keyrings /etc/logrotate.d /usr/local/lib/oc \
    /usr/local/sbin/oc-cloudflare-ips /home/alice/.ssh /home/bob/.ssh /etc/subuid /etc/subgid /var/lib/systemd/linger \
    /home/oc-prod/.config /home/oc-staging/.config; do
    [[ -e $d ]] || continue
    find "$d" -type f -print0 | sort -z | xargs -0 -r sha256sum >>"$out"
    find "$d" \( -type f -o -type l \) -printf '%p mode=%m owner=%u:%g mtime=%T@ link=%l\n' | sort >>"$out"
  done
}

# run_logged LOGFILE CMD...: show the output as it comes, keep a copy, return CMD's status.
run_logged() {
  local log=$1 rc
  shift
  set +e
  "$@" 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  set -e
  return "$rc"
}

section "bootstrap, first run"
rc=0
run_logged "$work/bootstrap1.log" bash "$infra/bootstrap.sh" || rc=$?
if [[ $rc -eq 0 ]]; then
  ok "first bootstrap run exits 0"
else
  notok "first bootstrap run exits $rc"
  exit 1
fi
yes_if "first run reports its changes" grep -q 'DONE changes=' "$work/bootstrap1.log"

section "verify after the first run"
rc=0
run_logged "$work/verify1.txt" bash "$infra/verify.sh" || rc=$?
yes_if "verify.sh exits 0" test "$rc" -eq 0
expect "no FAIL line" bash -c "! grep -q '^FAIL ' '$work/verify1.txt'"
for id in NET-02 NET-06 OS-02 OS-03 OS-05 OS-08 CTR-03; do
  expect "$id is SKIPped in container mode" grep -q "^SKIP $id " "$work/verify1.txt"
done
expect "TLS-01 warns about the placeholder certificate" grep -q '^WARN TLS-01 .*PLACEHOLDER' "$work/verify1.txt"
for id in SSH-01 SSH-02 SSH-03 SSH-04 NET-01 NET-03 NET-04 NET-05 OS-01 CTR-01 CTR-02 SVC-02 SVC-03 FS-01 FS-02 DB-01 PKG-01 PKG-02; do
  expect "$id passes" grep -q "^PASS $id " "$work/verify1.txt"
done

section "idempotence: second run in the same container"
snapshot "$work/snap1.txt"
secrets_before=$(sha256sum /etc/oc/*.env | sha256sum)
# The website gets its own, smaller secrets file (fix round 1). Before the second run: what
# each file holds, and that the one shared secret is the same in both files.
secret_of() { awk -F= '$1 == "OC_INTERNAL_SECRET" {sub(/^[^=]*=/, ""); v = $0} END {print v}' "$1"; }
# shellcheck disable=SC2317  # called through yes_if
shared_match() { # true if, in every environment, both files hold the same non-empty secret
  local e a b
  for e in prod staging; do
    a=$(secret_of "/etc/oc/$e.env")
    b=$(secret_of "/etc/oc/$e.web.env")
    [[ -n $a && $a == "$b" ]] || return 1
  done
}
shared_hash() { for e in prod staging; do secret_of "/etc/oc/$e.env"; secret_of "/etc/oc/$e.web.env"; done | sha256sum; }
web_key_names() { sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$1" | sort | tr '\n' ' '; }
yes_if "each environment has a CMS file and a website file, 0640 root:oc-<env>" bash -c "
  for e in prod staging; do
    for f in /etc/oc/\$e.env /etc/oc/\$e.web.env; do
      [[ \$(stat -c '%a %U %G' \$f) == '640 root oc-'\$e ]] || exit 1
    done
  done"
yes_if "the website file holds exactly its nine keys and no others" test "$(web_key_names /etc/oc/prod.web.env)" = "CSP_MODE HOST NODE_ENV OC_CMS_API_TOKEN OC_CMS_URL OC_DATA_DIR OC_INTERNAL_SECRET PORT PUBLIC_SITE_URL "
yes_if "the website file has none of the CMS-only keys" bash -c "! grep -qE '^(DATABASE_|APP_KEYS|API_TOKEN_SALT|ADMIN_JWT_SECRET|TRANSFER_TOKEN_SALT|JWT_SECRET|ENCRYPTION_KEY|OC_FILE_MASTER_KEY)' /etc/oc/prod.web.env /etc/oc/staging.web.env"
yes_if "the CMS file does not carry the API token placeholder (the token is the website's)" bash -c "! grep -q '^OC_CMS_API_TOKEN' /etc/oc/prod.env /etc/oc/staging.env"
yes_if "OC_INTERNAL_SECRET is the same in both files of each environment (first run)" shared_match
yes_if "the two environments do not share a secret" test "$(secret_of /etc/oc/prod.env)" != "$(secret_of /etc/oc/staging.env)"
shared_before=$(shared_hash)
rc=0
run_logged "$work/bootstrap2.log" bash "$infra/bootstrap.sh" || rc=$?
yes_if "second bootstrap run exits 0" test "$rc" -eq 0
snapshot "$work/snap2.txt"
if diff -u "$work/snap1.txt" "$work/snap2.txt" >"$work/snap.diff"; then
  ok "no file under /etc/oc, /etc/nginx, /etc/ssh/sshd_config.d, /etc/ufw (and 20 more places) changed: content, mode, owner and mtime ($(grep -c . "$work/snap1.txt") lines compared)"
else
  notok "the second run changed files"
  head -n 40 "$work/snap.diff"
fi
yes_if "OC_INTERNAL_SECRET is still the same in both files of each environment (second run)" shared_match
yes_if "neither OC_INTERNAL_SECRET value changed on the second run" test "$(shared_hash)" = "$shared_before"
secrets_after=$(sha256sum /etc/oc/*.env | sha256sum)
yes_if "no secret was regenerated" test "$secrets_after" = "$secrets_before"
if grep -q 'DONE changes=0$' "$work/bootstrap2.log"; then
  ok "the second run reports changes=0"
else
  notok "the second run reports changes"
  grep 'changed:' "$work/bootstrap2.log" | head -n 20
fi
yes_if "the first run prints a NEXT STEPS notice about the placeholder certificate" grep -q 'REPLACE THE PLACEHOLDER TLS CERTIFICATE' "$work/bootstrap1.log"
yes_if "the second run still reminds about the placeholder certificate" grep -q 'REPLACE THE PLACEHOLDER TLS CERTIFICATE' "$work/bootstrap2.log"
rc=0
bash "$infra/verify.sh" >"$work/verify2.txt" 2>&1 || rc=$?
yes_if "verify.sh still exits 0 after the second run" test "$rc" -eq 0

section "no secret reached the logs"
leak=0
while IFS= read -r line; do
  val=${line#*=}
  [[ ${#val} -ge 16 ]] || continue
  if grep -qF -- "$val" "$work"/bootstrap1.log "$work"/bootstrap2.log "$work"/verify1.txt "$work"/verify2.txt; then
    leak=1
  fi
done < <(grep -hE '^(DATABASE_PASSWORD|APP_KEYS|API_TOKEN_SALT|ADMIN_JWT_SECRET|TRANSFER_TOKEN_SALT|JWT_SECRET|ENCRYPTION_KEY|OC_INTERNAL_SECRET|OC_FILE_MASTER_KEY)=' /etc/oc/*.env)
yes_if "no generated secret value appears in the bootstrap or verify output" test "$leak" -eq 0
# The grep itself carries the password in its own arguments, hence "at most 1".
# shellcheck disable=SC2009
ps_leak=$(ps -eo args | grep -c -F "$(sed -n 's/^DATABASE_PASSWORD=//p' /etc/oc/prod.env)" || true)
yes_if "the database password is not in any process argument list" test "$ps_leak" -le 1

# --------------------------------------------------------------------------------------
section "artefacts"
expect "nginx -t passes on the rendered configuration" nginx -t
expect "the rendered configuration has no unreplaced markers" bash -c "! grep -q '@@' /etc/nginx/conf.d/oc.conf"
expect "fail2ban accepts its configuration" fail2ban-client -t
expect "sshd accepts its configuration" sshd -t
expect "the sudoers files validate" visudo -c
expect "the audit rules compile" augenrules --check
expect "systemd-analyze verify the Cloudflare refresh service and timer" systemd-analyze verify /etc/systemd/system/oc-cloudflare-ips.service /etc/systemd/system/oc-cloudflare-ips.timer

section "Podman's Quadlet generator (dry run) accepts the generated files"
quadlet=/usr/libexec/podman/quadlet
expect "the generator is installed with the podman package" test -x "$quadlet"
for e in prod staging; do
  qdir=/home/oc-$e/.config/containers/systemd
  uid=$(id -u "oc-$e")
  gid=$(id -g "oc-$e")
  qrc=0
  QUADLET_UNIT_DIRS="$qdir" "$quadlet" -dryrun -user >"$work/quadlet-$e.txt" 2>&1 || qrc=$?
  yes_if "the dry run exits 0 for $e" test "$qrc" -eq 0
  yes_if "$e: no generator error" bash -c "! grep '^quadlet-generator' '$work/quadlet-$e.txt' | grep -v 'Loading source unit file'"
  for u in oc-cms-$e oc-web-$e oc-$e-network; do
    yes_if "$e: the generator produces $u.service" grep -q -- "^---$u.service---\$" "$work/quadlet-$e.txt"
  done
  for flag in '--read-only' '--cap-drop=all' '--security-opt=no-new-privileges' "--user=$uid:$gid" '--userns keep-id' '--pids-limit' '--memory=' '--network=oc-'"$e" '--publish 127.0.0.1:'; do
    yes_if "$e: the generated podman command has $flag" grep -q -- "^ExecStart=/usr/bin/podman run .*$flag" "$work/quadlet-$e.txt"
  done
  yes_if "$e: the generated command ends with exactly the placeholder image" grep -qE "^ExecStart=/usr/bin/podman run .* localhost/oc-(cms|web):bootstrap\$" "$work/quadlet-$e.txt"
done
# The dry run is a real validator: a file with a bad key is rejected, not waved through.
mkdir -p "$work/badquadlet"
printf '[Container]\nImage=localhost/x:y\nNotARealKey=1\n' >"$work/badquadlet/bad.container"
bad_out=$(QUADLET_UNIT_DIRS="$work/badquadlet" "$quadlet" -dryrun -user 2>&1 || true)
if [[ $bad_out == *"unsupported key"* ]]; then
  ok "the generator rejects an unknown key (so its silence above means something)"
else
  notok "the generator did not reject an unknown key"
fi

section "a prod-only setup (OC_ENVS=prod) renders and passes nginx -t"
(
  # shellcheck source=../lib/common.sh
  source "$infra/lib/common.sh"
  # shellcheck source=../lib/firewall.sh
  source "$infra/lib/firewall.sh"
  # shellcheck source=../lib/nginx.sh
  source "$infra/lib/nginx.sh"
  OC_DOMAIN=example.test
  OC_ENV_LIST=(prod)
  nginx_render "$infra/nginx/oc.conf.template" >"$work/prod-only.conf"
)
printf 'pid %s/wrap.pid;
events {}
http {
  include %s/prod-only.conf;
}
' "$work" "$work" >"$work/wrap.conf"
expect "a prod-only configuration passes nginx -t" nginx -t -c "$work/wrap.conf"
expect "a prod-only configuration has no staging host" bash -c "! grep -q staging '$work/prod-only.conf'"

section "firewall rules (written, not activated: a container has no kernel firewall)"
ufw show added >"$work/ufw-added.txt" 2>/dev/null
expect "one SSH rule on 2222 and nothing else for SSH" bash -c "[[ \$(grep -c '^ufw allow 2222/tcp' '$work/ufw-added.txt') -eq 1 ]]"
expect "22 Cloudflare rules (15 IPv4 + 7 IPv6) for ports 80,443" bash -c "[[ \$(grep -c \"^ufw allow from .* to any port 80,443 proto tcp comment 'oc-cloudflare'\" '$work/ufw-added.txt') -eq 22 ]]"
expect "no rule opens 80, 443 or anything else to everyone" bash -c "! grep -E '^ufw allow (80|443|22)(/| |$)' '$work/ufw-added.txt' && [[ \$(grep -c '^ufw ' '$work/ufw-added.txt') -eq 23 ]]"
expect "default policy is deny incoming, allow outgoing" bash -c "grep -q '^DEFAULT_INPUT_POLICY=\"DROP\"' /etc/default/ufw && grep -q '^DEFAULT_OUTPUT_POLICY=\"ACCEPT\"' /etc/default/ufw"
expect "Nginx trusts the same 22 ranges" bash -c "[[ \$(grep -c '^set_real_ip_from ' /etc/nginx/conf.d/00-oc-cloudflare-realip.conf) -eq 22 ]]"

section "the weekly Cloudflare refresh (oc-cloudflare-ips), offline"
expect "a refresh with the same ranges changes nothing" bash -c "/usr/local/sbin/oc-cloudflare-ips | tee '$work/refresh0.log' | grep -q ' 0 change(s)'"
mkdir -p "$work/cf-new" "$work/cf-bad"
# New list: drop one IPv4 range, add another. Old rule must go, new rule must arrive.
grep -v '^131.0.72.0/22$' "$infra/test/fixtures/ips-v4" >"$work/cf-new/ips-v4"
printf '%s\n' '203.0.113.0/24' >>"$work/cf-new/ips-v4"
cp "$infra/test/fixtures/ips-v6" "$work/cf-new/ips-v6"
expect "a changed list updates the firewall and Nginx" env OC_CF_IPS_DIR="$work/cf-new" /usr/local/sbin/oc-cloudflare-ips
expect "the new range is allowed and the old one is gone" bash -c "ufw show added | grep -q 'from 203.0.113.0/24 ' && ! ufw show added | grep -q 'from 131.0.72.0/22 '"
expect "Nginx trusts the new range" bash -c "grep -q '^set_real_ip_from 203.0.113.0/24;' /etc/nginx/conf.d/00-oc-cloudflare-realip.conf && nginx -t"
snapshot "$work/snap-refresh.txt"
# Bad lists: a catch-all range, too few ranges, garbage. Each must be refused with nothing changed.
printf '%s\n' '0.0.0.0/0' >"$work/cf-bad/ips-v4"
cp "$infra/test/fixtures/ips-v6" "$work/cf-bad/ips-v6"
expect_fail "a list containing 0.0.0.0/0 is refused" env OC_CF_IPS_DIR="$work/cf-bad" /usr/local/sbin/oc-cloudflare-ips
printf '%s\n' '10.0.0.0/16' '10.1.0.0/16' >"$work/cf-bad/ips-v4"
expect_fail "a list with too few ranges is refused" env OC_CF_IPS_DIR="$work/cf-bad" /usr/local/sbin/oc-cloudflare-ips
printf '%s\n' '<html>error</html>' >"$work/cf-bad/ips-v4"
expect_fail "a list that is not addresses is refused" env OC_CF_IPS_DIR="$work/cf-bad" /usr/local/sbin/oc-cloudflare-ips
snapshot "$work/snap-refresh2.txt"
expect "refused lists changed nothing" diff -q "$work/snap-refresh.txt" "$work/snap-refresh2.txt"
# Put the real list back so the next steps see the standard state.
expect "restoring the standard list works" /usr/local/sbin/oc-cloudflare-ips
expect "verify.sh is clean again" bash -c "bash '$infra/verify.sh' | grep -q '^SUMMARY pass=.* fail=0 '"

# --------------------------------------------------------------------------------------
section "the verifier notices breakage (each change is made, checked, and undone)"
# mutation ID DESCRIPTION APPLY REVERT: verify.sh must print FAIL <ID> while the change is in place.
mutation() { # ID DESCRIPTION APPLY REVERT [TEXT THAT MUST BE IN THE FAIL LINE [A SECOND TEXT THAT MUST ALSO BE IN IT]]
  local id=$1 desc=$2 apply=$3 revert=$4 expect=${5:-} expect2=${6:-} out line
  bash -c "$apply"
  out=$(bash "$infra/verify.sh" 2>&1 || true)
  bash -c "$revert"
  line=$(grep "^FAIL $id " <<<"$out" | head -n 1 || true)
  if [[ -z $line ]]; then
    notok "$id still does not fail when $desc"
  elif [[ -n $expect && $line != *"$expect"* ]]; then
    notok "$id fails when $desc, but not for the expected reason (wanted '$expect')"
    printf '         | %s\n' "${line:0:400}"
  elif [[ -n $expect2 && $line != *"$expect2"* ]]; then
    notok "$id fails when $desc, but not also for the second expected reason (wanted '$expect2')"
    printf '         | %s\n' "${line:0:400}"
  else
    ok "$id fails when $desc${expect:+ (because: $expect${expect2:+; and: $expect2})}"
  fi
}
mutation SVC-02 "a secret file is world-readable" "chmod 0644 /etc/oc/prod.env" "chmod 0640 /etc/oc/prod.env"
mutation FS-01 "a private data folder is group-readable by everyone" "chmod 0755 /var/lib/oc/prod/private" "chmod 0750 /var/lib/oc/prod/private"
mutation SSH-01 "an earlier SSH drop-in turns passwords back on" \
  "printf 'PasswordAuthentication yes\n' >/etc/ssh/sshd_config.d/00-aaa.conf" "rm -f /etc/ssh/sshd_config.d/00-aaa.conf"
mutation SSH-02 "an earlier SSH drop-in allows root" \
  "printf 'PermitRootLogin yes\n' >/etc/ssh/sshd_config.d/00-aaa.conf" "rm -f /etc/ssh/sshd_config.d/00-aaa.conf"
mutation SSH-03 "another user is allowed to sign in" \
  "sed -i 's/^AllowUsers .*/AllowUsers alice bob mallory/' /etc/ssh/sshd_config.d/00-oc-hardening.conf" \
  "sed -i 's/^AllowUsers .*/AllowUsers alice bob/' /etc/ssh/sshd_config.d/00-oc-hardening.conf"
mutation SSH-04 "sshd also listens on port 22" \
  "printf 'Port 22\n' >/etc/ssh/sshd_config.d/00-aaa.conf" "rm -f /etc/ssh/sshd_config.d/00-aaa.conf"
mutation NET-01 "ufw would allow incoming by default" \
  "sed -i 's/^DEFAULT_INPUT_POLICY=.*/DEFAULT_INPUT_POLICY=\"ACCEPT\"/' /etc/default/ufw" \
  "sed -i 's/^DEFAULT_INPUT_POLICY=.*/DEFAULT_INPUT_POLICY=\"DROP\"/' /etc/default/ufw"
mutation NET-03 "Nginx stops requiring the client certificate" \
  "sed -i 's/ssl_verify_client\\([[:space:]]*\\)on;/ssl_verify_client\\1off;/' /etc/nginx/conf.d/oc.conf" \
  "sed -i 's/ssl_verify_client\\([[:space:]]*\\)off;/ssl_verify_client\\1on;/' /etc/nginx/conf.d/oc.conf"
mutation NGX-01 "Nginx allows TLS 1.0" \
  "sed -i '0,/ssl_protocols\\([[:space:]]*\\)TLSv1.2 TLSv1.3;/s//ssl_protocols\\1TLSv1 TLSv1.2 TLSv1.3;/' /etc/nginx/conf.d/oc.conf" \
  "sed -i 's/ssl_protocols\\([[:space:]]*\\)TLSv1 TLSv1.2 TLSv1.3;/ssl_protocols\\1TLSv1.2 TLSv1.3;/' /etc/nginx/conf.d/oc.conf"
mutation FS-02 "Nginx is given /var/lib/oc as a web root" \
  "printf 'server { listen 8081; root /var/lib/oc/prod/media; }\n' >/etc/nginx/conf.d/zz-test.conf" "rm -f /etc/nginx/conf.d/zz-test.conf"
mutation NET-04 "MariaDB is told to listen on every interface" \
  "printf '[mariadbd]\nbind-address = 0.0.0.0\n' >/etc/mysql/mariadb.conf.d/99-zz.cnf" "rm -f /etc/mysql/mariadb.conf.d/99-zz.cnf"
mutation NET-05 "clamd is given a TCP port" \
  "printf 'TCPSocket 3310\n' >>/etc/clamav/clamd.conf" "sed -i '/^TCPSocket 3310\$/d' /etc/clamav/clamd.conf"
mutation OS-01 "automatic updates are switched off" \
  "sed -i 's/Unattended-Upgrade \"1\"/Unattended-Upgrade \"0\"/' /etc/apt/apt.conf.d/20auto-upgrades" \
  "sed -i 's/Unattended-Upgrade \"0\"/Unattended-Upgrade \"1\"/' /etc/apt/apt.conf.d/20auto-upgrades"
qweb=/home/oc-prod/.config/containers/systemd/oc-web-prod.container
qcms=/home/oc-prod/.config/containers/systemd/oc-cms-prod.container
# Backups of the files being changed live OUTSIDE the Quadlet folder: an extra file in that
# folder is itself a CTR-01 failure, which would make every test below pass for the wrong
# reason. Each test also states WHY CTR-01 must fail, and that text must be in the FAIL line.
qbak=$work/qbak
mkdir -p "$qbak"
yes_if "before the Quadlet changes: CTR-01, SVC-02 and NET-03 pass on the untouched files (so a FAIL below is caused by the change)" \
  bash -c "bash '$infra/verify.sh' 2>&1 | grep -cE '^PASS (CTR-01|SVC-02|NET-03) ' | grep -qx 3"
# A Quadlet change: save the file, change it, check, put it back byte for byte.
qmutation() { # DESCRIPTION FILE SED-EXPRESSION EXPECTED-TEXT-IN-THE-FAIL-LINE
  mutation CTR-01 "$1" "cp -p $2 $qbak/$(basename "$2") && sed -i '$3' $2" "mv -f $qbak/$(basename "$2") $2" "$4"
}
qmutation "the web container loses ReadOnly=true" "$qweb" '/^ReadOnly=true$/d' "ReadOnly is not true"
qmutation "the web container is allowed all capabilities" "$qweb" '/^DropCapability=ALL$/d' "DropCapability is not ALL"
qmutation "the web container may gain privileges" "$qweb" 's/^NoNewPrivileges=true/NoNewPrivileges=false/' "NoNewPrivileges is not true"
qmutation "the CMS container runs as root" "$qcms" 's/^User=[0-9]*$/User=0/' "User is not the environment user's id"
qmutation "the CMS container loses its user mapping" "$qcms" '/^UserNS=keep-id$/d' "UserNS"
qmutation "the CMS container loses its memory limit" "$qcms" 's/^PodmanArgs=--memory=.*$/PodmanArgs=--memory-swap=1536m/' "no memory limit"
qmutation "the CMS container loses its pids limit" "$qcms" '/^PidsLimit=/d' "PidsLimit"
qmutation "the CMS container loses its tmpfs" "$qcms" '/^Tmpfs=/d' "Tmpfs"
qmutation "the CMS container publishes on every interface" "$qcms" 's/^PublishPort=127.0.0.1:/PublishPort=0.0.0.0:/' "PublishPort is not exactly 127.0.0.1"
qmutation "the CMS container mounts the host's Podman socket" "$qcms" 's|^Volume=/run/clamav:/run/clamav:ro|Volume=/run/podman:/run/podman|' "Volume '/run/podman:/run/podman' is not allowed"
qmutation "the CMS container mounts all of /var/lib/oc" "$qcms" 's|^Volume=/var/lib/oc/prod:/var/lib/oc/prod|Volume=/var/lib/oc:/var/lib/oc|' "Volume '/var/lib/oc:/var/lib/oc' is not allowed"
qmutation "the CMS container mounts ClamAV read-write" "$qcms" 's|^Volume=/run/clamav:/run/clamav:ro|Volume=/run/clamav:/run/clamav|' "Volume '/run/clamav:/run/clamav' is not allowed"
qmutation "the web container mounts the whole data folder" "$qweb" 's|^Volume=/var/lib/oc/prod/media:/var/lib/oc/prod/media:ro|Volume=/var/lib/oc/prod:/var/lib/oc/prod|' "Volume '/var/lib/oc/prod:/var/lib/oc/prod' is not allowed"
qmutation "the web container gets a second image line" "$qweb" 's|^Image=.*|&\nImage=localhost/oc-web:other|' "Image appears 2 times"
qmutation "the web container is made privileged" "$qweb" 's|^PidsLimit=256|&\nPodmanArgs=--privileged|' "PodmanArgs has '--privileged'"
qmutation "the web container loses its health check" "$qweb" '/^HealthCmd=/d' "HealthCmd"
qmutation "the web container uses a different environment file" "$qweb" 's|^EnvironmentFile=.*|EnvironmentFile=/etc/oc/staging.env|' "EnvironmentFile is not /etc/oc/prod.web.env"
qmutation "the web container uses host networking" "$qweb" 's|^Network=.*|Network=host|' "Network is not oc-prod.network"
qmutation "the web container gets an unknown key" "$qweb" 's|^ReadOnly=true|&\nNotARealKey=1|' "key NotARealKey in [Container] is not allowed"
mutation CTR-02 "an environment user loses its subuid range" "cp -p /etc/subuid /tmp/subuid.orig && sed -i '/^oc-prod:/d' /etc/subuid" "mv -f /tmp/subuid.orig /etc/subuid"
mutation CTR-02 "an environment user loses its subgid range" "cp -p /etc/subgid /tmp/subgid.orig && sed -i '/^oc-staging:/d' /etc/subgid" "mv -f /tmp/subgid.orig /etc/subgid"
mutation CTR-02 "two environment users share a subuid range" \
  "cp -p /etc/subuid /tmp/subuid.orig && printf 'mallory:%s:65536\n' \"\$(awk -F: '\$1==\"oc-prod\"{print \$2}' /etc/subuid)\" >>/etc/subuid" "mv -f /tmp/subuid.orig /etc/subuid"
mutation CTR-02 "lingering is off for an environment user" "mv /var/lib/systemd/linger/oc-staging /tmp/linger.orig" "mv /tmp/linger.orig /var/lib/systemd/linger/oc-staging"
mutation PKG-01 "a Docker daemon is present" \
  "printf '#!/bin/sh\nexit 0\n' >/usr/local/bin/dockerd && chmod +x /usr/local/bin/dockerd" "rm -f /usr/local/bin/dockerd"
mutation SVC-03 "the weekly Cloudflare refresh script is missing" "mv /usr/local/sbin/oc-cloudflare-ips /tmp/ocips.orig" "mv /tmp/ocips.orig /usr/local/sbin/oc-cloudflare-ips"
mutation DB-01 "one environment's database user may read the other environment's database" \
  "mariadb -e 'GRANT SELECT ON \`oc_staging\`.* TO \`oc_prod\`@\`localhost\`'" \
  "mariadb -e 'REVOKE SELECT ON \`oc_staging\`.* FROM \`oc_prod\`@\`localhost\`'"
mutation DB-01 "an extra database account exists" \
  "mariadb -e \"CREATE USER 'oc_extra'@'%' IDENTIFIED BY 'x'\"" "mariadb -e \"DROP USER 'oc_extra'@'%'\""
mutation TLS-01 "the origin key does not match the origin certificate" \
  "cp -p /etc/ssl/oc/origin.key /tmp/origin.key.bak && openssl ecparam -name prime256v1 -genkey -noout -out /etc/ssl/oc/origin.key" \
  "cp -p /tmp/origin.key.bak /etc/ssl/oc/origin.key && rm -f /tmp/origin.key.bak"
mutation SSH-03 "an admin loses the authorized key (lock-out risk)" \
  "mv /home/bob/.ssh/authorized_keys /tmp/bob.keys" "mv /tmp/bob.keys /home/bob/.ssh/authorized_keys"
# --- fix round 1: the spelling tricks and gaps the reviewer found; each must fail, and fail for
# the stated reason ---
# Quadlet and systemd accept "Key = value" and continued lines; a check that reads only
# "Key=value" at the start of a line would never see these.
webuid=$(id -u oc-prod)
qmutation "the web container gets PodmanArgs = --privileged (spaces around =)" "$qweb" '/^\[Container\]$/a PodmanArgs = --privileged' "PodmanArgs has '--privileged'"
qmutation "the web container gets AddCapability = ALL (spaces around =)" "$qweb" '/^\[Container\]$/a AddCapability = ALL' "key AddCapability in [Container] is not allowed"
qmutation "the web container mounts a podman.sock with Volume = (spaces around =)" "$qweb" "/^\\[Container\\]\$/a Volume = /run/user/$webuid/podman/podman.sock:/s" "Volume '/run/user/$webuid/podman/podman.sock:/s' is not allowed"
qmutation "the web container mounts docker.sock after leading spaces" "$qweb" '/^\[Container\]$/a    Volume=/var/run/docker.sock:/var/run/docker.sock' "Volume '/var/run/docker.sock:/var/run/docker.sock' is not allowed"
qmutation "the web container gets a key with a tab before the =" "$qweb" "/^\\[Container\\]\$/a AddCapability\t= ALL" "key AddCapability in [Container] is not allowed"
mutation CTR-01 "a PodmanArgs line is continued with a backslash and hides --privileged" \
  "cp -p $qweb $qbak/web.orig && awk '{print} /^\\[Container\\]\$/ {print \"PodmanArgs=--memory=512m \\134\"; print \"--privileged\"}' $qbak/web.orig >$qbak/web.tmp && cat $qbak/web.tmp >$qweb" \
  "mv -f $qbak/web.orig $qweb" "PodmanArgs has '--privileged'"
for k in Unmask SeccompProfile SecurityLabelNested UIDMap GIDMap SubUIDMap ExposeHostPort GlobalArgs Annotation SecurityLabelDisable AddDevice Mount Pod Ulimit Sysctl Notify; do
  qmutation "the web container gets $k=" "$qweb" "/^\\[Container\\]\$/a $k=x" "key $k in [Container] is not allowed"
done
qmutation "the web container gets a [Service] ExecStartPre" "$qweb" '/^\[Service\]$/a ExecStartPre=/usr/bin/podman run --privileged x' "key ExecStartPre in [Service] is not allowed"
qmutation "the web container gets a second environment file" "$qweb" 's|^EnvironmentFile=.*|&\nEnvironmentFile=/etc/oc/prod.env|' "EnvironmentFile appears 2 times"
qmutation "the web container is pointed at the CMS's secrets file" "$qweb" 's|^EnvironmentFile=.*|EnvironmentFile=/etc/oc/prod.env|' "EnvironmentFile is not /etc/oc/prod.web.env"
qmutation "the CMS container is pointed at the website's file" "$qcms" 's|^EnvironmentFile=.*|EnvironmentFile=/etc/oc/prod.web.env|' "EnvironmentFile is not /etc/oc/prod.env"
qmutation "the web container sets a secret in Environment=" "$qweb" '/^\[Container\]$/a Environment=OC_FILE_MASTER_KEY=x' "environment variable OC_FILE_MASTER_KEY is not allowed"
qmutation "the web container sets NODE_OPTIONS to load a file" "$qweb" 's|^Environment=NODE_OPTIONS=.*|Environment=NODE_OPTIONS=--require /var/lib/oc/prod/evil.js|' "NODE_OPTIONS may only set"
qmutation "the web container's image line carries an extra flag" "$qweb" 's|^Image=.*|Image=localhost/oc-web:x --privileged|' "Image is not a local oc-cms or oc-web image"
qmutation "the web container uses an image from a registry" "$qweb" 's|^Image=.*|Image=docker.io/library/node:22|' "Image is not a local oc-cms or oc-web image"
qmutation "the web container gets a [Pod] section" "$qweb" 's|^\[Install\]$|[Pod]\nPodName=x\n&|' "section [Pod] is not allowed"
mutation CTR-01 "a drop-in folder next to the web Quadlet file adds --privileged" \
  "mkdir -p $qweb.d && printf '[Container]\nPodmanArgs=--privileged\n' >$qweb.d/zz.conf" "rm -rf $qweb.d" "unexpected entry 'oc-web-prod.container.d"
mutation CTR-01 "an extra container file appears in the Quadlet folder" \
  "printf '[Container]\nImage=localhost/oc-web:x\n' >$(dirname "$qweb")/evil.container" "rm -f $(dirname "$qweb")/evil.container" "unexpected entry 'evil.container'"
qnet=$(dirname "$qweb")/oc-prod.network
mutation CTR-01 "the private network file gets another setting" \
  "cp -p $qnet $qbak/net.orig && printf 'Internal=false\n' >>$qnet" "mv -f $qbak/net.orig $qnet" "oc-prod.network has"

# --- the website's secrets file: only the website's keys ---
wfile=/etc/oc/prod.web.env
# wmutation DESCRIPTION APPLY-ON-COPY EXPECTED: change the website's file, check, put it back
wmutation() {
  mutation SVC-02 "$1" "cp -p $wfile $qbak/web.env.orig && $2" "mv -f $qbak/web.env.orig $wfile" "$3"
}
for k in DATABASE_PASSWORD DATABASE_HOST DATABASE_NAME APP_KEYS API_TOKEN_SALT ADMIN_JWT_SECRET TRANSFER_TOKEN_SALT JWT_SECRET ENCRYPTION_KEY OC_FILE_MASTER_KEY; do
  wmutation "the website's file holds the CMS-only key $k" "printf '%s=x\n' $k >>$wfile" "must not have: $k"
done
wmutation "the website's file holds an unknown key" "printf 'SOMETHING_ELSE=x\n' >>$wfile" "must not have: SOMETHING_ELSE"
wmutation "the website's file has a line that is not NAME=value" "printf 'export FOO=1\n' >>$wfile" "not NAME=value"
wmutation "the two files of an environment hold different OC_INTERNAL_SECRET values" \
  "sed 's|^OC_INTERNAL_SECRET=.*|OC_INTERNAL_SECRET=a-different-value-0123456789|' $qbak/web.env.orig >$qbak/web.env.tmp && cat $qbak/web.env.tmp >$wfile" "OC_INTERNAL_SECRET differs"
wmutation "the website's file is world-readable" "chmod 0644 $wfile" "is 644 root:oc-prod, want 640 root:oc-prod"
wmutation "the website's file belongs to the wrong group" "chgrp oc-staging $wfile" "want 640 root:oc-prod"
wmutation "the website's file loses a required key" "sed '/^CSP_MODE=/d' $qbak/web.env.orig >$qbak/web.env.tmp && cat $qbak/web.env.tmp >$wfile" "lacks: CSP_MODE"
mutation SVC-02 "the website's file is missing" "mv $wfile $qbak/web.env.gone" "mv $qbak/web.env.gone $wfile" "prod.web.env missing"

# --- Nginx layouts the parser must understand: a TLS site without the client certificate
# must fail NET-03 however it is written ---
ngxdir=/etc/nginx/conf.d
tls="ssl_certificate /etc/ssl/oc/origin.pem; ssl_certificate_key /etc/ssl/oc/origin.key;"
mutation NET-03 "a one-line TLS server without the client certificate is added" \
  "printf 'server { listen 8443 ssl; server_name oneline.example.test; $tls }\n' >$ngxdir/zz-test.conf" "rm -f $ngxdir/zz-test.conf" "oneline.example.test: ssl_verify_client ''"
mutation NET-03 "a TLS server with 'server' and '{' on separate lines is added without the client certificate" \
  "printf 'server\n{\n  listen 8444 ssl;\n  server_name twoline.example.test;\n  $tls\n}\n' >$ngxdir/zz-test.conf" "rm -f $ngxdir/zz-test.conf" "twoline.example.test: ssl_verify_client ''"
mutation NET-03 "a server turns TLS on with 'ssl on;' and has no client certificate" \
  "printf 'server { listen 8445; ssl on; server_name sslon.example.test; $tls }\n' >$ngxdir/zz-test.conf" "rm -f $ngxdir/zz-test.conf" "sslon.example.test: ssl_verify_client ''"
mutation NET-03 "a TLS server asks for the client certificate only optionally" \
  "printf 'server { listen 8446 ssl; server_name optional.example.test; $tls ssl_client_certificate /etc/nginx/oc/cloudflare-origin-pull-ca.pem; ssl_verify_client optional; }\n' >$ngxdir/zz-test.conf" "rm -f $ngxdir/zz-test.conf" "optional.example.test: ssl_verify_client 'optional'"
mutation NET-03 "a TLS server switches verification off with a quoted value" \
  "printf 'server { listen 8447 ssl; server_name quoted.example.test; $tls ssl_verify_client \"off\"; }\n' >$ngxdir/zz-test.conf" "rm -f $ngxdir/zz-test.conf" "quoted.example.test: ssl_verify_client 'off'"
mutation NET-03 "a TLS server trusts a different CA" \
  "printf 'server { listen 8448 ssl; server_name otherca.example.test; $tls ssl_client_certificate /etc/ssl/oc/origin.pem; ssl_verify_client on; }\n' >$ngxdir/zz-test.conf" "rm -f $ngxdir/zz-test.conf" "otherca.example.test: client CA differs"
mutation NET-03 "two servers share one line and the second is TLS without the client certificate" \
  "printf 'server { listen 8449; return 404; } server { listen 8450 ssl; server_name second.example.test; $tls }\n' >$ngxdir/zz-test.conf" "rm -f $ngxdir/zz-test.conf" "second.example.test: ssl_verify_client ''"
# The parser is not just refusing everything: a correct one-line TLS server passes.
printf 'server { listen 8451 ssl; server_name ok.example.test; %s ssl_client_certificate /etc/nginx/oc/cloudflare-origin-pull-ca.pem; ssl_verify_client on; ssl_protocols TLSv1.2 TLSv1.3; return 404; }\n' "$tls" >"$ngxdir/zz-test.conf"
bash "$infra/verify.sh" >"$work/verify-ngx-ok.txt" 2>&1 || true
rm -f "$ngxdir/zz-test.conf"
yes_if "a correct one-line TLS server is seen and accepted (NET-03 counts 5 TLS sites)" grep -q '^PASS NET-03 all 5 TLS sites' "$work/verify-ngx-ok.txt"

# --- fix round 2 ---------------------------------------------------------------------------
# The two parsers had rules different from the real ones. Nginx's tokenizer and Podman's file
# parser are now followed exactly; each trick that got past them must fail for its reason.

# Nginx: TLS servers without the client certificate, hidden by the rules the tokenizer used to get wrong.
ngxsrv="$ngxdir/zz-test.conf"
mutation NET-03 "a TLS server using a quoted \"ssl\" sits between servers whose add_header values hold a quote mid-word (a'b ... c'd)" \
  "printf \"server { listen 8460; add_header X a'b; server_name a.example.test; }\nserver { listen 8443 \\\"ssl\\\"; server_name q.example.test; $tls }\nserver { listen 8461; add_header Y c'd; server_name c.example.test; }\n\" >$ngxsrv" \
  "rm -f $ngxsrv" "q.example.test: ssl_verify_client ''" "contain a quote character"
mutation NET-03 "a TLS server using a quoted \"ssl\" follows 'default_type \${a;' (a \${ in a value) and a '}' ends a word in the next server" \
  "printf 'server { default_type \${a; listen 8444 \"ssl\"; server_name b.example.test; $tls }\nserver { listen 8462; return 200 a}; server_name n.example.test; }\n' >$ngxsrv" \
  "rm -f $ngxsrv" "b.example.test: ssl_verify_client ''" "contain a quote character"
mutation NET-03 "a plain TLS server sits between servers whose add_header values hold a quote mid-word" \
  "printf \"server { listen 8463; add_header X a'b; server_name p.example.test; }\nserver { listen 8445 ssl; server_name m.example.test; $tls }\nserver { listen 8464; add_header Y c'd; server_name r.example.test; }\n\" >$ngxsrv" \
  "rm -f $ngxsrv" "m.example.test: ssl_verify_client ''"
mutation NET-03 "a TLS server follows a '\${' in a value (default_type \${a;)" \
  "printf 'server { default_type \${a; listen 8446 ssl; server_name v.example.test; $tls }\n' >$ngxsrv" \
  "rm -f $ngxsrv" "v.example.test: ssl_verify_client ''"
mutation NET-03 "a TLS server follows a '}' inside a word (add_header X a}b;)" \
  "printf 'server { add_header X a}b; listen 8447 ssl; server_name w.example.test; $tls }\n' >$ngxsrv" \
  "rm -f $ngxsrv" "w.example.test: ssl_verify_client ''"
mutation NET-03 "a TLS server has a double-quoted \"ssl\" in its listen and no client certificate" \
  "printf 'server { listen 8448 \"ssl\"; server_name x.example.test; $tls }\n' >$ngxsrv" \
  "rm -f $ngxsrv" "x.example.test: ssl_verify_client ''" "contain a quote character"
mutation NET-03 "a TLS server has a '#' in the middle of a word before its listen (add_header X a#b;)" \
  "printf 'server { add_header X a#b; listen 8449 ssl; server_name y.example.test; $tls }\n' >$ngxsrv" \
  "rm -f $ngxsrv" "y.example.test: ssl_verify_client ''"

# Quadlet: a comment line that ends in a backslash must not swallow the line after it.
# qinsert DESCRIPTION FILE SECTION EXPECTED-REASON LINE...: put the lines right after the
# section header, and say why CTR-01 must fail. (@BS@ in a line stands for a backslash.)
qinsert() {
  local desc=$1 file=$2 sec=$3 why=$4 base line
  shift 4
  base=$(basename "$file")
  : >"$qbak/insert.txt"
  for line in "$@"; do
    printf '%s\n' "${line//@BS@/\\}" >>"$qbak/insert.txt"
  done
  mutation CTR-01 "$desc" \
    "cp -p $file $qbak/$base && awk -v sec='[$sec]' 'FNR == NR {ins[++n] = \$0; next} {print} \$0 == sec {for (i = 1; i <= n; i++) print ins[i]}' $qbak/insert.txt $qbak/$base >$qbak/insert.new && cat $qbak/insert.new >$file" \
    "mv -f $qbak/$base $file" "$why" "a comment line ends with a backslash"
}
qinsert "a '; ... \\' comment line comes before PodmanArgs=--privileged" "$qweb" Container "PodmanArgs has '--privileged'" \
  '; note @BS@' 'PodmanArgs=--privileged'
qinsert "a '# ... \\' comment line comes before PodmanArgs=--privileged" "$qweb" Container "PodmanArgs has '--privileged'" \
  '# note @BS@' 'PodmanArgs=--privileged'
qinsert "a comment line ending in a backslash comes before [Service] ExecStartPre=/usr/bin/podman run --privileged -v /:/host" "$qweb" Service "key ExecStartPre in [Service] is not allowed" \
  '; note @BS@' 'ExecStartPre=/usr/bin/podman run -d --privileged -v /:/host x'
qinsert "a comment line ending in a backslash comes before PodmanArgs=--read-only=false" "$qweb" Container "PodmanArgs has '--read-only=false'" \
  '; note @BS@' 'PodmanArgs=--read-only=false'
qinsert "a comment line ending in a backslash comes before PodmanArgs=--privileged in the CMS file" "$qcms" Container "PodmanArgs has '--privileged'" \
  '# note @BS@' 'PodmanArgs=--privileged'


# --- VERIFY_CONTAINER=1 on a real host must not quietly skip the live checks ---
realhost_made=0
if [[ ! -d /run/systemd/system ]]; then
  mkdir -p /run/systemd/system
  realhost_made=1
fi
rc=0
bash "$infra/verify.sh" >"$work/verify-realhost.txt" 2>&1 || rc=$?
if [[ $realhost_made -eq 1 ]]; then
  rmdir /run/systemd/system
  rmdir /run/systemd 2>/dev/null || true
fi
yes_if "verify.sh refuses VERIFY_CONTAINER=1 when systemd is running (FAIL CFG-01)" grep -q '^FAIL CFG-01 ' "$work/verify-realhost.txt"
yes_if "and exits non-zero" test "$rc" -ne 0
yes_if "and prints no PASS or SKIP line at all" bash -c "! grep -qE '^(PASS|SKIP) ' '$work/verify-realhost.txt'"

# --- the generated podman command, checked flag by flag (unit tests on crafted commands) ---
gen_line() { # ROLE: the real generated ExecStart= line for prod
  QUADLET_UNIT_DIRS=/home/oc-prod/.config/containers/systemd "$quadlet" -dryrun -user 2>/dev/null |
    awk -v s="---oc-$1-prod.service---" '$0 == s {f = 1; next} /^---.*---$/ {f = 0} f && /^ExecStart=/ && !done {print; done = 1}'
}
gen_problems() { # ROLE LINE: what q_check_generated says about LINE
  OC_TEST_LINE=$2 bash -c 'source "$1/verify.sh"; q_check_generated prod "$2" "$OC_TEST_LINE"' _ "$infra" "$1"
}
web_line=$(gen_line web)
cms_line=$(gen_line cms)
yes_if "the real generated web command has no problem (positive control)" test -z "$(gen_problems web "$web_line")"
yes_if "the real generated CMS command has no problem (positive control)" test -z "$(gen_problems cms "$cms_line")"
gen_case() { # DESCRIPTION ROLE FROM TO EXPECTED: replace FROM by TO in the real command; it must be flagged, for the stated reason
  local line problems
  if [[ $2 == web ]]; then line=$web_line; else line=$cms_line; fi
  if [[ $line != *"$3"* ]]; then
    notok "$1 (test bug: '$3' is not in the generated command)"
    return
  fi
  line=${line/"$3"/"$4"}
  problems=$(gen_problems "$2" "$line")
  if [[ -z $problems ]]; then
    notok "the generated-command check misses: $1"
  elif [[ $problems != *"$5"* ]]; then
    notok "the generated-command check flags '$1' but not for the expected reason (wanted '$5')"
    printf '         | %s\n' "${problems:0:300}"
  else
    ok "the generated-command check flags: $1"
  fi
}
img=' localhost/oc-web:bootstrap'
gen_case "--privileged" web "$img" " --privileged$img" "flag '--privileged'"
gen_case "--cap-add=ALL" web "--cap-drop=all" "--cap-drop=all --cap-add=ALL" "flag '--cap-add'"
gen_case "--cap-drop dropped" web "--cap-drop=all" "--cap-drop=net_raw" "--cap-drop is 'net_raw'"
gen_case "--network=host" web "--network=oc-prod" "--network=host" "--network is 'host'"
gen_case "--net host" web "--network=oc-prod" "--net host" "flag '--net'"
gen_case "seccomp=unconfined" web "--security-opt=no-new-privileges" "--security-opt=no-new-privileges --security-opt=seccomp=unconfined" "--security-opt 'seccomp=unconfined'"
gen_case "label=disable" web "--security-opt=no-new-privileges" "--security-opt=no-new-privileges --security-opt label=disable" "--security-opt 'label=disable'"
gen_case "apparmor=unconfined" web "--security-opt=no-new-privileges" "--security-opt=no-new-privileges --security-opt apparmor=unconfined" "--security-opt 'apparmor=unconfined'"
gen_case "no-new-privileges replaced" web "--security-opt=no-new-privileges" "--security-opt=label=type:x" "--security-opt 'label=type:x'"
gen_case "a podman socket mount" web "$img" " -v /run/user/$webuid/podman/podman.sock:/s$img" "the mount '/run/user/$webuid/podman/podman.sock:/s'"
gen_case "a docker socket mount" web "$img" " -v /var/run/docker.sock:/var/run/docker.sock$img" "the mount '/var/run/docker.sock:/var/run/docker.sock'"
gen_case "a mount of /" web "$img" " -v /:/host$img" "the mount '/:/host'"
gen_case "--mount" web "$img" " --mount type=bind,src=/,dst=/h$img" "flag '--mount'"
gen_case "--volume" web "$img" " --volume /etc:/etc$img" "flag '--volume'"
gen_case "--pid=host" web "$img" " --pid=host$img" "flag '--pid'"
gen_case "--ipc=host" web "$img" " --ipc=host$img" "flag '--ipc'"
gen_case "--uts=host" web "$img" " --uts=host$img" "flag '--uts'"
gen_case "--userns=host" web "--userns keep-id" "--userns host" "--userns is 'host'"
gen_case "--device" web "$img" " --device /dev/fuse$img" "flag '--device'"
gen_case "--security-opt systempaths=unconfined" web "$img" " --security-opt systempaths=unconfined$img" "--security-opt 'systempaths=unconfined'"
gen_case "a root user" web "--user=$webuid:" "--user=0:" "--user is '0:"
gen_case "publish on 0.0.0.0" web "--publish 127.0.0.1:4321:4321" "--publish 0.0.0.0:4321:4321" "--publish '0.0.0.0:4321:4321'"
gen_case "publish on every interface (no address)" web "--publish 127.0.0.1:4321:4321" "--publish 4321:4321" "--publish '4321:4321'"
gen_case "a second publish" web "$img" " --publish 127.0.0.1:2222:22$img" "--publish '127.0.0.1:2222:22'"
gen_case "the CMS's env file for the website" web "--env-file /etc/oc/prod.web.env" "--env-file /etc/oc/prod.env" "--env-file is '/etc/oc/prod.env'"
gen_case "the website's env file for the CMS" cms "--env-file /etc/oc/prod.env" "--env-file /etc/oc/prod.web.env" "--env-file is '/etc/oc/prod.web.env'"
gen_case "an extra env file" web "$img" " --env-file /etc/oc/prod.env$img" "--env-file is '/etc/oc/prod.env'"
gen_case "a command after the image" web "$img" "$img /bin/sh" "an extra argument after the image"
gen_case "an image from a registry" web "$img" " docker.io/library/node:22" "the image 'docker.io/library/node:22'"
gen_case "--read-only removed" web " --read-only" "" "lacks: --read-only"
gen_case "the memory limit removed" web " --memory=512m" "" "lacks: --memory"
gen_case "the pids limit removed" web "--pids-limit 256" "" "lacks: --pids-limit"
gen_case "the tmpfs removed" web " --tmpfs /tmp:rw,noexec,nosuid,size=64m" "" "lacks: --tmpfs"
gen_case "--entrypoint" web "$img" " --entrypoint /bin/sh$img" "flag '--entrypoint'"
gen_case "--group-add keep-groups for the website" web "$img" " --group-add=keep-groups$img" "--group-add 'keep-groups' is not allowed here"
gen_case "--add-host" web "$img" " --add-host x:127.0.0.1$img" "flag '--add-host'"
gen_case "--env LD_PRELOAD" web "$img" " --env LD_PRELOAD=/x.so$img" "environment variable LD_PRELOAD is not allowed"
gen_case "the CMS mounts the podman socket" cms " --publish 127.0.0.1:1337:1337" " -v /run/podman/podman.sock:/s --publish 127.0.0.1:1337:1337" "the mount '/run/podman/podman.sock:/s'"
gen_case "the CMS mounts ClamAV read-write" cms "-v /run/clamav:/run/clamav:ro" "-v /run/clamav:/run/clamav" "the mount '/run/clamav:/run/clamav'"

# The generated units: only the one ExecStart (checked flag by flag) and the generator's own
# podman rm in ExecStop and ExecStopPost may run anything. Crafted copies of the real output.
gen_prod=$(QUADLET_UNIT_DIRS=/home/oc-prod/.config/containers/systemd "$quadlet" -dryrun -user 2>&1)
units_problems() { # GENERATED-OUTPUT: what q_check_units says about it
  OC_TEST_GEN=$1 bash -c 'source "$1/verify.sh"; q_check_units prod "$OC_TEST_GEN"' _ "$infra"
}
# after_line BLOCK PATTERN EXTRA: the real output with EXTRA added after the first line of BLOCK matching PATTERN
after_line() { printf '%s\n' "$gen_prod" | awk -v b="---$1---" -v p="$2" -v x="$3" '$0 == b {f = 1} f && !d && $0 ~ p {print; print x; d = 1; next} {print}'; }
# replace_line BLOCK PATTERN NEW: the real output with that line replaced (NEW empty: removed)
replace_line() { printf '%s\n' "$gen_prod" | awk -v b="---$1---" -v p="$2" -v x="$3" '$0 == b {f = 1} f && !d && $0 ~ p {if (x != "") print x; d = 1; next} {print}'; }
unit_case() { # DESCRIPTION EDITED-OUTPUT EXPECTED-REASON
  local problems
  problems=$(units_problems "$2")
  if [[ -z $problems ]]; then
    notok "the generated-unit check misses: $1"
  elif [[ $problems != *"$3"* ]]; then
    notok "the generated-unit check flags '$1' but not for the expected reason (wanted '$3')"
    printf '         | %s\n' "${problems:0:300}"
  else
    ok "the generated-unit check flags: $1"
  fi
}
yes_if "the real generated units have no problem (positive control)" test -z "$(units_problems "$gen_prod")"
prun='/usr/bin/podman run -d --privileged -v /:/host localhost/oc-web:x'
unit_case "an ExecStartPre that runs podman run --privileged" "$(after_line oc-web-prod.service '^ExecStop=' "ExecStartPre=$prun")" "has ExecStartPre=, which is not allowed"
unit_case "an ExecStartPost that runs podman run" "$(after_line oc-web-prod.service '^ExecStop=' "ExecStartPost=$prun")" "has ExecStartPost=, which is not allowed"
unit_case "an ExecReload that runs podman create" "$(after_line oc-web-prod.service '^ExecStop=' 'ExecReload=/usr/bin/podman create -v /:/host x')" "has ExecReload=, which is not allowed"
unit_case "an ExecCondition" "$(after_line oc-web-prod.service '^ExecStop=' 'ExecCondition=/bin/true')" "has ExecCondition=, which is not allowed"
unit_case "an Exec= key" "$(after_line oc-web-prod.service '^ExecStop=' 'Exec=/bin/sh')" "has Exec=, which is not allowed"
unit_case "a second ExecStart" "$(after_line oc-web-prod.service '^ExecStop=' "ExecStart=$prun")" "has 2 ExecStart lines"
unit_case "ExecStop replaced by a podman run" "$(replace_line oc-web-prod.service '^ExecStop=' "ExecStop=$prun")" "ExecStop=/usr/bin/podman run"
unit_case "ExecStop with extra podman rm arguments" "$(replace_line oc-web-prod.service '^ExecStop=' 'ExecStop=/usr/bin/podman rm -v -f -i --cidfile=%t/%N.cid -v /:/host')" "is not the generator's own podman rm"
unit_case "ExecStopPost with a second command after a ;" "$(replace_line oc-web-prod.service '^ExecStopPost=' "ExecStopPost=-/usr/bin/podman rm -v -f -i --cidfile=%t/%N.cid ; $prun")" "ExecStopPost=-/usr/bin/podman rm"
unit_case "ExecStopPost replaced by podman create" "$(replace_line oc-web-prod.service '^ExecStopPost=' 'ExecStopPost=/usr/bin/podman create -v /:/host x')" "is not the generator's own podman rm"
unit_case "podman run in a [Service] Environment line" "$(after_line oc-web-prod.service '^ExecStop=' "Environment=X=$prun")" "outside ExecStart"
unit_case "podman create in an Environment= line" "$(after_line oc-web-prod.service '^ExecStop=' 'Environment=X=/usr/bin/podman create -v /:/host x')" "outside ExecStart"
unit_case "a made-up Exec key (ExecStopPostX=)" "$(after_line oc-web-prod.service '^ExecStop=' 'ExecStopPostX=/usr/bin/podman create -v /:/host x')" "has ExecStopPostX=, which is not allowed"
unit_case "an Exec line with spaces around the = (ExecStartPre = podman run)" "$(after_line oc-web-prod.service '^ExecStop=' "  ExecStartPre = $prun")" "has ExecStartPre=, which is not allowed"
unit_case "podman run with a global option before it (podman --log-level=debug run)" "$(after_line oc-web-prod.service '^ExecStop=' "Environment=X=/usr/bin/podman --log-level=debug run -d x")" "outside ExecStart"
unit_case "no ExecStart at all in a container unit" "$(replace_line oc-web-prod.service '^ExecStart=' '')" "has 0 ExecStart lines"
unit_case "an ExecStart that is not podman run" "$(replace_line oc-cms-prod.service '^ExecStart=' 'ExecStart=/bin/sh -c x')" "the generated command is not /usr/bin/podman run"
unit_case "a podman create in place of the podman run" "$(replace_line oc-cms-prod.service '^ExecStart=' 'ExecStart=/usr/bin/podman create --name=x localhost/oc-cms:x')" "the generated command is not /usr/bin/podman run"
unit_case "the network unit runs something else" "$(replace_line oc-prod-network.service '^ExecStart=' 'ExecStart=/usr/bin/podman run -d --privileged x')" "is not the generator's own network command"
unit_case "the network unit gets an ExecStartPre" "$(after_line oc-prod-network.service '^ExecStart=' 'ExecStartPre=/usr/bin/podman run -d --privileged x')" "is not the generator's own network command"
unit_case "an extra unit appears" "$(printf '%s\n---evil.service---\n[Service]\nExecStart=%s\n' "$gen_prod" "$prun")" "unexpected unit 'evil.service'"
unit_case "an extra unit appears with an Exec line" "$(printf '%s\n---evil.service---\n[Service]\nExecStart=%s\n' "$gen_prod" "$prun")" "in a unit that should not have one"


rc=0
bash "$infra/verify.sh" >"$work/verify-after-mutations.txt" 2>&1 || rc=$?
yes_if "after the changes are undone verify.sh is clean again" test "$rc" -eq 0

# --------------------------------------------------------------------------------------
section "the two hand-written parsers, under gawk and under the default awk (mawk), on the same cases"
parser_mawk="$work/parser-mawk.txt"
parser_gawk="$work/parser-gawk.txt"
rc=0
bash "$infra/test/parser-cases.sh" mawk nginx >"$parser_mawk" 2>"$work/parser-mawk.err" || rc=$?
yes_if "every case is answered correctly under mawk, and Nginx itself accepts every case that is meant to be valid" test "$rc" -eq 0
rc=0
bash "$infra/test/parser-cases.sh" gawk nginx >"$parser_gawk" 2>"$work/parser-gawk.err" || rc=$?
yes_if "every case is answered correctly under gawk, and Nginx itself accepts every case that is meant to be valid" test "$rc" -eq 0
yes_if "gawk and mawk print byte-for-byte identical output on every case" cmp -s "$parser_mawk" "$parser_gawk"
yes_if "the default awk of this image is mawk" bash -c "[[ \$(readlink -f \"\$(command -v awk)\") == */mawk ]]"
cat "$parser_mawk"
printf '(%s nginx cases, %s count cases, %s qnorm cases; the same lines under gawk)\n' \
  "$(grep -c '^== nginx' "$parser_mawk")" "$(grep -c '^== counts' "$parser_mawk")" "$(grep -c '^== qnorm' "$parser_mawk")"


# --------------------------------------------------------------------------------------
section "a missing website file is recreated with the CMS's secret, and the CMS file is left alone"
cp -p /etc/oc/staging.web.env "$work/staging.web.env.orig"
cms_hash_before=$(sha256sum /etc/oc/staging.env)
rm -f /etc/oc/staging.web.env
rc=0
run_logged "$work/bootstrap-recreate.log" bash "$infra/bootstrap.sh" >/dev/null || rc=$?
yes_if "bootstrap exits 0 with the website file missing" test "$rc" -eq 0
yes_if "the website file is back, 0640 root:oc-staging" bash -c "[[ \$(stat -c '%a %U %G' /etc/oc/staging.web.env) == '640 root oc-staging' ]]"
yes_if "it holds the same secret as the CMS file" shared_match
yes_if "the CMS file was not touched" test "$(sha256sum /etc/oc/staging.env)" = "$cms_hash_before"
yes_if "the recreated file has the same content as the original" cmp -s "$work/staging.web.env.orig" /etc/oc/staging.web.env
yes_if "the run reported what it changed (and nothing about secret values)" bash -c "grep -q 'changed: created /etc/oc/staging.web.env (values not shown)' '$work/bootstrap-recreate.log'"
mv -f "$work/staging.web.env.orig" /etc/oc/staging.web.env

# --------------------------------------------------------------------------------------
section "a certificate installed by the owner is kept, accepted, and ends the warning"
own="$work/owncert"
mkdir -p "$own"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 -subj "/CN=Test Origin CA" \
  -keyout "$own/ca.key" -out "$own/ca.pem" >/dev/null 2>&1
openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj "/CN=example.test" \
  -keyout "$own/leaf.key" -out "$own/leaf.csr" >/dev/null 2>&1
openssl x509 -req -in "$own/leaf.csr" -CA "$own/ca.pem" -CAkey "$own/ca.key" -CAcreateserial -days 30 \
  -out "$own/leaf.crt" >/dev/null 2>&1
cp -p /etc/ssl/oc/origin.pem "$own/placeholder.pem"
cp -p /etc/ssl/oc/origin.key "$own/placeholder.key"
install -m 0644 -o root -g root "$own/leaf.crt" /etc/ssl/oc/origin.pem
install -m 0600 -o root -g root "$own/leaf.key" /etc/ssl/oc/origin.key
# Task 4's deploy script changes the Image= line; a rerun of the bootstrap must keep that.
# (cat >, not sed -i: the file must keep its owner, like the deploy script's edit would)
sed 's|^Image=.*|Image=localhost/oc-web:abc123|' "$qweb" >"$work/q.tmp" && cat "$work/q.tmp" >"$qweb"
rc=0
run_logged "$work/bootstrap3.log" bash "$infra/bootstrap.sh" >/dev/null || rc=$?
yes_if "bootstrap still exits 0 with the owner's certificate in place" test "$rc" -eq 0
yes_if "bootstrap left the owner's certificate alone" cmp -s "$own/leaf.crt" /etc/ssl/oc/origin.pem
yes_if "bootstrap left the owner's key alone" cmp -s "$own/leaf.key" /etc/ssl/oc/origin.key
yes_if "no placeholder reminder is printed any more" bash -c "! grep -q 'REPLACE THE PLACEHOLDER' '$work/bootstrap3.log'"
yes_if "the run changed nothing" grep -q 'DONE changes=0$' "$work/bootstrap3.log"
yes_if "the bootstrap kept the Image= line the deploy script set" grep -q '^Image=localhost/oc-web:abc123$' "$qweb"
sed 's|^Image=.*|Image=localhost/oc-web:bootstrap|' "$qweb" >"$work/q.tmp" && cat "$work/q.tmp" >"$qweb"
bash "$infra/verify.sh" >"$work/verify-owncert.txt" 2>&1 || true
yes_if "TLS-01 passes (no warning) with a real certificate" grep -q '^PASS TLS-01 ' "$work/verify-owncert.txt"
expect "nginx -t passes with the owner's certificate" nginx -t
cp -p "$own/placeholder.pem" /etc/ssl/oc/origin.pem
cp -p "$own/placeholder.key" /etc/ssl/oc/origin.key

# --------------------------------------------------------------------------------------
section "SSH really behaves as configured (sshd started by hand on port 2222)"
mkdir -p /run/sshd
# A container cannot write /proc/self/loginuid; this is a test-only change to PAM.
sed -i 's/^session[[:space:]]\+required[[:space:]]\+pam_loginuid.so/session optional pam_loginuid.so/' /etc/pam.d/sshd
id mallory >/dev/null 2>&1 || useradd -m -s /bin/bash mallory
install -d -m 0700 -o mallory -g mallory /home/mallory/.ssh
install -m 0600 -o mallory -g mallory "$work/keys/alice.pub" /home/mallory/.ssh/authorized_keys
install -d -m 0700 /root/.ssh
install -m 0600 "$work/keys/alice.pub" /root/.ssh/authorized_keys
/usr/sbin/sshd -D -e -f /etc/ssh/sshd_config >"$work/sshd.log" 2>&1 &
# shellcheck disable=SC2031  # $! here belongs to this shell; the earlier subshell is unrelated
sshd_pid=$!
for _ in $(seq 1 20); do
  ss -H -ltn | awk '$4 ~ /:2222$/ {f=1} END {exit !f}' && break
  sleep 0.5
done
expect "sshd listens on 2222" bash -c "ss -H -ltn | awk '\$4 ~ /:2222\$/ {f=1} END {exit !f}'"
expect "sshd does not listen on 22" bash -c "! ss -H -ltn | awk '\$4 ~ /:22\$/ {f=1} END {exit !f}'"
sshc=(ssh -p 2222 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)
expect "alice signs in with her key" bash -c "[[ \$(${sshc[*]} -i $work/keys/alice alice@127.0.0.1 'id -un') == alice ]]"
expect "bob signs in with his key" bash -c "[[ \$(${sshc[*]} -i $work/keys/bob bob@127.0.0.1 'id -un') == bob ]]"
expect "an admin has sudo without a password (OC_SUDO_PASSWORDLESS=yes)" bash -c "[[ \$(${sshc[*]} -i $work/keys/alice alice@127.0.0.1 'sudo -n id -u') == 0 ]]"
expect_fail "bob cannot sign in with alice's key" "${sshc[@]}" -i "$work/keys/alice" -o IdentitiesOnly=yes bob@127.0.0.1 true
expect_fail "root cannot sign in, even with a valid authorized key" "${sshc[@]}" -i "$work/keys/alice" root@127.0.0.1 true
expect_fail "a user that is not an admin cannot sign in, even with a valid key" "${sshc[@]}" -i "$work/keys/alice" mallory@127.0.0.1 true
expect_fail "the environment user cannot sign in" "${sshc[@]}" -i "$work/keys/alice" oc-prod@127.0.0.1 true
expect_fail "a password is not even offered" "${sshc[@]}" -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no alice@127.0.0.1 true
ssh_out=$("${sshc[@]}" -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no alice@127.0.0.1 true 2>&1 || true)
if [[ $ssh_out == *"Permission denied (publickey)"* ]]; then
  ok "the server answers 'Permission denied (publickey)': only keys are accepted"
else
  notok "unexpected authentication methods offered"
fi
expect_fail "TCP forwarding is refused (ssh -R)" "${sshc[@]}" -i "$work/keys/alice" -o ExitOnForwardFailure=yes -R 15432:127.0.0.1:3306 alice@127.0.0.1 true
kill "$sshd_pid" 2>/dev/null || true
rm -f /root/.ssh/authorized_keys

# --------------------------------------------------------------------------------------
section "Nginx really behaves as configured"
bash "$infra/test/nginx-behaviour.sh" "$work" || FAILED=$((FAILED + 1))

# --------------------------------------------------------------------------------------
section "shellcheck"
if scripts | xargs -0 shellcheck -x --shell=bash -P "$infra:$infra/lib" >"$work/shellcheck.out" 2>&1; then
  ok "shellcheck is clean on every script"
else
  notok "shellcheck found problems"
  head -n 60 "$work/shellcheck.out"
fi

section "final verify.sh, after every test above has run"
rc=0
bash "$infra/verify.sh" >"$work/verify3.txt" 2>&1 || rc=$?
yes_if "verify.sh exits 0 after all the tests (they left the configuration as it was)" test "$rc" -eq 0

section "result"
if [[ $FAILED -eq 0 ]]; then
  printf 'ALL GOOD: every check above passed.\n'
  printf '\nFinal verify.sh listing:\n'
  cat "$work/verify3.txt"
  exit 0
fi
printf '%s check(s) failed.\n' "$FAILED" >&2
exit 1
