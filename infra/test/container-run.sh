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
mutation() {
  local id=$1 desc=$2 apply=$3 revert=$4 out
  bash -c "$apply"
  out=$(bash "$infra/verify.sh" 2>&1 || true)
  bash -c "$revert"
  if grep -q "^FAIL $id " <<<"$out"; then
    ok "$id fails when $desc"
  else
    notok "$id still does not fail when $desc"
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
# A Quadlet change: save the file, change it, check, put it back byte for byte.
qmutation() { # DESCRIPTION FILE SED-EXPRESSION
  mutation CTR-01 "$1" "cp -p $2 $2.orig && sed -i '$3' $2" "mv -f $2.orig $2"
}
qmutation "the web container loses ReadOnly=true" "$qweb" '/^ReadOnly=true$/d'
qmutation "the web container is allowed all capabilities" "$qweb" '/^DropCapability=ALL$/d'
qmutation "the web container may gain privileges" "$qweb" 's/^NoNewPrivileges=true/NoNewPrivileges=false/'
qmutation "the CMS container runs as root" "$qcms" 's/^User=[0-9]*$/User=0/'
qmutation "the CMS container loses its user mapping" "$qcms" '/^UserNS=keep-id$/d'
qmutation "the CMS container loses its memory limit" "$qcms" 's/^PodmanArgs=--memory=.*$/PodmanArgs=--memory-swap=1536m/'
qmutation "the CMS container loses its pids limit" "$qcms" '/^PidsLimit=/d'
qmutation "the CMS container loses its tmpfs" "$qcms" '/^Tmpfs=/d'
qmutation "the CMS container publishes on every interface" "$qcms" 's/^PublishPort=127.0.0.1:/PublishPort=0.0.0.0:/'
qmutation "the CMS container mounts the host's Podman socket" "$qcms" 's|^Volume=/run/clamav:/run/clamav:ro|Volume=/run/podman:/run/podman|'
qmutation "the CMS container mounts all of /var/lib/oc" "$qcms" 's|^Volume=/var/lib/oc/prod:/var/lib/oc/prod|Volume=/var/lib/oc:/var/lib/oc|'
qmutation "the CMS container mounts ClamAV read-write" "$qcms" 's|^Volume=/run/clamav:/run/clamav:ro|Volume=/run/clamav:/run/clamav|'
qmutation "the web container mounts the whole data folder" "$qweb" 's|^Volume=/var/lib/oc/prod/media:/var/lib/oc/prod/media:ro|Volume=/var/lib/oc/prod:/var/lib/oc/prod|'
qmutation "the web container gets a second image line" "$qweb" 's|^Image=.*|&\nImage=localhost/oc-web:other|'
qmutation "the web container is made privileged" "$qweb" 's|^PidsLimit=256|&\nPodmanArgs=--privileged|'
qmutation "the web container loses its health check" "$qweb" '/^HealthCmd=/d'
qmutation "the web container uses a different environment file" "$qweb" 's|^EnvironmentFile=.*|EnvironmentFile=/etc/oc/staging.env|'
qmutation "the web container uses host networking" "$qweb" 's|^Network=.*|Network=host|'
qmutation "the web container gets an unknown key" "$qweb" 's|^ReadOnly=true|&\nNotARealKey=1|'
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
rc=0
bash "$infra/verify.sh" >"$work/verify-after-mutations.txt" 2>&1 || rc=$?
yes_if "after the changes are undone verify.sh is clean again" test "$rc" -eq 0

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
