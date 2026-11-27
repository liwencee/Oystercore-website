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

# expect_fail_because DESCRIPTION TEXT CMD...: the command must fail, and its output must contain
# TEXT (so it fails for the stated reason and not for some other one).
expect_fail_because() {
  local desc=$1 text=$2
  shift 2
  if "$@" >"$work/expect.out" 2>&1; then
    notok "$desc (it succeeded, it should have failed)"
    sed 's/^/         | /' "$work/expect.out" | head -n 20
  elif grep -qF -- "$text" "$work/expect.out"; then
    ok "$desc (because: $text)"
  else
    notok "$desc, but not for the stated reason (wanted '$text')"
    sed 's/^/         | /' "$work/expect.out" | head -n 20
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
  for u in alice bob deploy-prod deploy-staging; do
    [[ -f $work/keys/$u ]] || ssh-keygen -q -t ed25519 -N '' -C "$u@test" -f "$work/keys/$u"
  done
  cat >"$work/server.env" <<EOF
OC_DOMAIN=example.test
OC_ADMINS=alice:$work/keys/alice.pub,bob:$work/keys/bob.pub
OC_DEPLOY_PUBKEY_PROD=$work/keys/deploy-prod.pub
OC_DEPLOY_PUBKEY_STAGING=$work/keys/deploy-staging.pub
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
OC_DEPLOY_PUBKEY_PROD=$work/keys/deploy-prod.pub
OC_DEPLOY_PUBKEY_STAGING=$work/keys/deploy-staging.pub
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

# The deploy account's settings: one key per environment. Each refusal must be for its own reason:
# the base settings above are valid, so only the lines changed can be the cause.
bad_env "$base
OC_DEPLOY_PUBKEY_PROD="
expect_fail_because "the deploy account switched on with an empty key setting for prod is refused" "needs OC_DEPLOY_PUBKEY_PROD" bash "$infra/bootstrap.sh" --config "$work/bad.env"
expect_fail_because "the missing prod key's message names the GitHub environment 'production' (the server's prod is GitHub's production)" "GitHub environment 'production'" bash "$infra/bootstrap.sh" --config "$work/bad.env"
bad_env "OC_DOMAIN=example.test
OC_ADMINS=alice:$work/keys/alice.pub
OC_DEPLOY_PUBKEY_PROD=$work/keys/deploy-prod.pub
OC_SSH_PORT=2222"
expect_fail_because "a missing key for an enabled environment (staging) is refused" "needs OC_DEPLOY_PUBKEY_STAGING" bash "$infra/bootstrap.sh" --config "$work/bad.env"
expect_fail_because "the missing staging key's message names the GitHub environment 'staging'" "GitHub environment 'staging'" bash "$infra/bootstrap.sh" --config "$work/bad.env"
bad_env "OC_DOMAIN=example.test
OC_ADMINS=alice:$work/keys/alice.pub
OC_DEPLOY_PUBKEY_STAGING=$work/keys/deploy-staging.pub
OC_SSH_PORT=2222"
expect_fail_because "a missing key for an enabled environment (prod) is refused" "needs OC_DEPLOY_PUBKEY_PROD" bash "$infra/bootstrap.sh" --config "$work/bad.env"
bad_env "OC_DOMAIN=example.test
OC_ADMINS=alice:$work/keys/alice.pub
OC_SSH_PORT=2222"
expect_fail_because "no deploy keys at all, with OC_DEPLOY_ENABLED left at its default (yes)" "needs OC_DEPLOY_PUBKEY_PROD" bash "$infra/bootstrap.sh" --config "$work/bad.env"
bad_env "$base
OC_DEPLOY_PUBKEY=$work/keys/deploy-prod.pub"
expect_fail_because "the old single-key setting OC_DEPLOY_PUBKEY is refused, and says what replaces it" "OC_DEPLOY_PUBKEY is gone" bash "$infra/bootstrap.sh" --config "$work/bad.env"
bad_env "$base
OC_DEPLOY_PUBKEY_STAGING=$work/keys/deploy-prod.pub"
expect_fail_because "the same key for both environments is refused" "is the same key as OC_DEPLOY_PUBKEY_STAGING" bash "$infra/bootstrap.sh" --config "$work/bad.env"
cp "$work/keys/deploy-prod.pub" "$work/keys/deploy-prod-renamed.pub"
sed -i 's/ [^ ]*$/ another-comment@elsewhere/' "$work/keys/deploy-prod-renamed.pub"
bad_env "$base
OC_DEPLOY_PUBKEY_STAGING=$work/keys/deploy-prod-renamed.pub"
expect_fail_because "the same key with another comment is still the same key (the blob is compared, not the comment)" "is the same key as OC_DEPLOY_PUBKEY_STAGING" bash "$infra/bootstrap.sh" --config "$work/bad.env"
bad_env "OC_DOMAIN=example.test
OC_ADMINS=alice:$work/keys/alice.pub
OC_ENVS=prod
OC_DEPLOY_PUBKEY_PROD=$work/keys/deploy-prod.pub
OC_DEPLOY_PUBKEY_STAGING=$work/keys/deploy-staging.pub
OC_SSH_PORT=2222"
expect_fail_because "a key for an environment this server does not run (staging, with OC_ENVS=prod) is refused" "OC_DEPLOY_PUBKEY_STAGING is set, but staging is not in OC_ENVS" bash "$infra/bootstrap.sh" --config "$work/bad.env"
bad_env "$base
OC_DEPLOY_PUBKEY_PROD=$work/keys/deploy-prod"
expect_fail_because "a PRIVATE key as the prod deploy key is refused" "contains a PRIVATE key" bash "$infra/bootstrap.sh" --config "$work/bad.env"
bad_env "$base
OC_DEPLOY_PUBKEY_STAGING=$work/keys/deploy-staging"
expect_fail_because "a PRIVATE key as the staging deploy key is refused" "contains a PRIVATE key" bash "$infra/bootstrap.sh" --config "$work/bad.env"
bad_env "$base
OC_DEPLOY_PUBKEY_STAGING=$work/keys/alice.pub"
expect_fail_because "an admin's key as the staging deploy key is refused" "is the same key as the admin 'alice'" bash "$infra/bootstrap.sh" --config "$work/bad.env"
bad_env "$base
OC_DEPLOY_PUBKEY_PROD=$work/keys/alice.pub"
expect_fail_because "an admin's key as the prod deploy key is refused" "is the same key as the admin 'alice'" bash "$infra/bootstrap.sh" --config "$work/bad.env"
bad_env "$base
OC_DEPLOY_PUBKEY_STAGING=$work/keys/nope.pub"
expect_fail_because "a deploy key file that does not exist is refused" "public key file not found" bash "$infra/bootstrap.sh" --config "$work/bad.env"
printf 'command="/bin/sh",pty %s\n' "$(cut -d' ' -f1,2 "$work/keys/deploy-staging.pub")" >"$work/keys/deploy-with-options.pub"
bad_env "$base
OC_DEPLOY_PUBKEY_STAGING=$work/keys/deploy-with-options.pub"
expect_fail_because "a deploy key that carries options of its own is refused" "is not a plain public key line" bash "$infra/bootstrap.sh" --config "$work/bad.env"
bad_env "$base
OC_DEPLOY_ENABLED=maybe"
expect_fail_because "OC_DEPLOY_ENABLED=maybe is refused" "OC_DEPLOY_ENABLED must be yes or no" bash "$infra/bootstrap.sh" --config "$work/bad.env"
bad_env "$base
OC_DEPLOY_MAX_BYTES=10"
expect_fail_because "a size limit of 10 bytes is refused" "OC_DEPLOY_MAX_BYTES must be" bash "$infra/bootstrap.sh" --config "$work/bad.env"
bad_env "$base
OC_DEPLOY_MAX_BYTES=999999999999999"
expect_fail_because "a size limit of 900 TB is refused" "OC_DEPLOY_MAX_BYTES must be" bash "$infra/bootstrap.sh" --config "$work/bad.env"
# Positive controls: the settings the refusals above would be accepted with.
# shellcheck disable=SC2317  # called through expect
validates() { # FILE: the settings parse and validate (nothing is installed)
  bash -c 'source "$1/lib/common.sh"; oc_load_config "$2"; oc_validate_config' _ "$infra" "$1"
}
bad_env "OC_DOMAIN=example.test
OC_ADMINS=alice:$work/keys/alice.pub
OC_SSH_PORT=2222
OC_DEPLOY_ENABLED=no"
expect "OC_DEPLOY_ENABLED=no needs no deploy key (positive control)" validates "$work/bad.env"
bad_env "OC_DOMAIN=example.test
OC_ADMINS=alice:$work/keys/alice.pub
OC_ENVS=prod
OC_DEPLOY_PUBKEY_PROD=$work/keys/deploy-prod.pub
OC_SSH_PORT=2222"
expect "a server that runs only prod needs only the prod key (positive control)" validates "$work/bad.env"
expect "the real settings (both keys) validate (positive control)" validates "$work/server.env"

# --------------------------------------------------------------------------------------
snapshot() {
  # Content, mode, owner and modification time of every file in the places the setup writes.
  local out=$1 d
  : >"$out"
  for d in /etc/oc /etc/nginx /etc/ssh/sshd_config.d /etc/ufw /etc/default/ufw /etc/ssl/oc /etc/systemd/system \
    /etc/sudoers.d /etc/fail2ban /etc/audit/rules.d /etc/sysctl.d /etc/mysql /etc/clamav /etc/apt/apt.conf.d \
    /etc/apt/sources.list.d /etc/apt/preferences.d /etc/apt/keyrings /etc/logrotate.d /usr/local/lib/oc \
    /usr/local/sbin/oc-cloudflare-ips /home/alice/.ssh /home/bob/.ssh /etc/subuid /etc/subgid /var/lib/systemd/linger \
    /home/oc-prod/.config /home/oc-staging/.config /var/lib/oc-deploy /etc/ssh/oc-deploy.authorized_keys /etc/passwd /etc/group /etc/shadow; do
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
for id in SSH-01 SSH-02 SSH-03 SSH-04 DEP-01 DEP-02 NET-01 NET-03 NET-04 NET-05 OS-01 CTR-01 CTR-02 CTR-04 SVC-02 SVC-03 FS-01 FS-02 DB-01 PKG-01 PKG-02; do
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
# The deploy instructions at the end of the first run say where the secrets go (the review finding:
# "GitHub (Settings, Secrets)" reads as repository secrets, which every branch's workflows can read).
for text in 'ONE DEPLOY KEY PER ENVIRONMENT' 'a staging key can never' 'ENVIRONMENT secrets, never as repository secrets'   'environment "production": DEPLOY_SSH_KEY' 'environment "staging": DEPLOY_SSH_KEY' "$work/keys/deploy-prod.pub" "$work/keys/deploy-staging.pub"   'DEPLOY_KNOWN_HOSTS' 'DEPLOY_HOST' 'DEPLOY_SSH_PORT' '"Deployment branches": production only the main branch'   'staging only the staging branch' '"Required reviewers" (the manual approval) to production' 'protect the staging branch as strictly as main'; do
  yes_if "the first run's NEXT STEPS say: $text" grep -qF -- "$text" "$work/bootstrap1.log"
done
yes_if "the NEXT STEPS no longer say 'Settings, Secrets' (repository secrets)" bash -c "! grep -qF 'Settings, Secrets' '$work/bootstrap1.log'"
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
# Only the check <ID> is run (VERIFY_ONLY), which keeps the two hundred changes below to a few seconds each;
# the whole verifier is run in full before and after them (and "after the changes are undone verify.sh is
# clean again" below runs it in full).
mutation() { # ID DESCRIPTION APPLY REVERT [TEXT THAT MUST BE IN THE FAIL LINE [A SECOND TEXT THAT MUST ALSO BE IN IT]]
  local id=$1 desc=$2 apply=$3 revert=$4 expect=${5:-} expect2=${6:-} out line
  bash -c "$apply"
  out=$(VERIFY_ONLY=$id bash "$infra/verify.sh" 2>&1 || true)
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
  "sed -i 's/^AllowUsers .*/AllowUsers alice bob oc-deploy mallory/' /etc/ssh/sshd_config.d/00-oc-hardening.conf" \
  "sed -i 's/^AllowUsers .*/AllowUsers alice bob oc-deploy/' /etc/ssh/sshd_config.d/00-oc-hardening.conf" "AllowUsers is 'alice bob mallory oc-deploy'"
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


# --- Task 4: Pull=never, the deploy account, and sshd's per-user rules ------------------------
# Every change below is made, checked, and undone; each must fail for the stated reason.
for f in "$infra/quadlet/oc-cms.container.template" "$infra/quadlet/oc-web.container.template" "$qweb" "$qcms" \
  /home/oc-staging/.config/containers/systemd/oc-web-staging.container /home/oc-staging/.config/containers/systemd/oc-cms-staging.container; do
  yes_if "Pull=never is in $(basename "$f")" grep -qx 'Pull=never' "$f"
done
qmutation "the web container loses Pull=never (a missing image could then be fetched from a registry)" "$qweb" '/^Pull=never$/d' "Pull is not never"
qmutation "the web container's Pull=never becomes Pull=always" "$qweb" 's/^Pull=never$/Pull=always/' "Pull is not never"
qmutation "the CMS container gets Pull=missing" "$qcms" 's/^Pull=never$/Pull=missing/' "Pull is not never"
qmutation "the CMS container gets a second Pull line" "$qcms" 's|^Pull=never$|&\nPull=always|' "Pull appears 2 times"
qmutation "the web container gets Pull = always (spaces around =)" "$qweb" 's|^Pull=never$|Pull = always|' "Pull is not never"
qmutation "the web container's Tmpfs gets the exec option" "$qweb" 's|^Tmpfs=.*|Tmpfs=/tmp:rw,exec,nosuid,size=64m|' "Tmpfs has the option 'exec'"
qmutation "the CMS container's Tmpfs is not for /tmp" "$qcms" 's|^Tmpfs=.*|Tmpfs=/var/lib/oc:rw,noexec|' "Tmpfs is not for /tmp"

section "the deploy account: every way of widening it must be noticed"
yes_if "before the changes: DEP-01, DEP-02, SSH-01, SSH-02 and SSH-03 pass on the untouched system (so a FAIL below is caused by the change)" \
  bash -c "bash '$infra/verify.sh' 2>&1 | grep -cE '^PASS (DEP-01|DEP-02|SSH-01|SSH-02|SSH-03) ' | grep -qx 5"
dkeys=/etc/ssh/oc-deploy.authorized_keys
dapply=/usr/local/lib/oc/deploy/apply-release.sh
dforced=/usr/local/lib/oc/deploy/deploy-release
dsudo=/etc/sudoers.d/92-oc-deploy
dlimits=/usr/local/lib/oc/deploy/limits.conf
ddrop=/etc/ssh/sshd_config.d/00-oc-hardening.conf
dbak=$work/dbak
mkdir -p "$dbak"
# fmutation ID DESCRIPTION FILE SED-EXPRESSION EXPECTED...: save FILE, edit it with sed, check, put it back (same owner and mode).
fmutation() {
  local id=$1 desc=$2 file=$3 expr=$4
  shift 4
  mutation "$id" "$desc" "cp -p $file $dbak/$(basename "$file") && sed -E -i '$expr' $file" "cp -p $dbak/$(basename "$file") $file && rm -f $dbak/$(basename "$file")" "$@"
}

# --- DEP-01: the key lines (one per environment, each binding its environment and its own key)
# The file holds two lines, prod's first. pkey and skey are the key types and keys of the two deploy
# keys; kfile_set writes a whole file from two (command, key, comment) triples.
pkey=$(awk '{print $1 " " $2}' "$work/keys/deploy-prod.pub")
skey=$(awk '{print $1 " " $2}' "$work/keys/deploy-staging.pub")
akey=$(awk '{print $1 " " $2}' "$work/keys/alice.pub")
# kfile_mutation DESCRIPTION SHELL-COMMANDS-THAT-REWRITE-THE-KEY-FILE EXPECTED-TEXT...
kfile_mutation() {
  local desc=$1 apply=$2
  shift 2
  mutation DEP-01 "$desc" "cp -p $dkeys $dbak/keys && $apply" "cp -p $dbak/keys $dkeys" "$@"
}
yes_if "the key file has one line per environment, each binding its own environment (positive control)" bash -c "
  [[ \$(wc -l <$dkeys) -eq 2 ]] &&
  sed -n 1p $dkeys | grep -q '^command=\"$dforced prod\",restrict ssh-ed25519 ' &&
  sed -n 2p $dkeys | grep -q '^command=\"$dforced staging\",restrict ssh-ed25519 ' &&
  sed -n 1p $dkeys | grep -q ' oc-deploy-prod\$' && sed -n 2p $dkeys | grep -q ' oc-deploy-staging\$'"
yes_if "the two lines carry different keys, and they are the configured ones (positive control)" bash -c "
  [[ \$(sed -n 1p $dkeys | awk '{print \$3 \" \" \$4}') == '$pkey' && \$(sed -n 2p $dkeys | awk '{print \$3 \" \" \$4}') == '$skey' && '$pkey' != '$skey' ]]"
kfile_mutation "an extra third key line (an admin's key, without options)" "cat $work/keys/alice.pub >>$dkeys" "has 3 lines, not exactly one per environment"
kfile_mutation "an extra third key line (a copy of the prod line)" "sed -n 1p $dbak/keys >>$dkeys" "has 3 lines, not exactly one per environment"
kfile_mutation "a missing key for an enabled environment (the staging line is gone)" "sed -i '/ oc-deploy-staging\$/d' $dkeys" "no key line for the environment staging"
kfile_mutation "a missing key for an enabled environment (the prod line is gone)" "sed -i '/ oc-deploy-prod\$/d' $dkeys" "no key line for the environment prod"
kfile_mutation "the same key for both environments (the staging line carries prod's key)" \
  "printf 'command=\"$dforced prod\",restrict %s oc-deploy-prod\ncommand=\"$dforced staging\",restrict %s oc-deploy-staging\n' '$pkey' '$pkey' >$dkeys" "two key lines carry the same key"
kfile_mutation "a key line with no environment in its command (prod's command is the bare forced command)" \
  "sed -i 's|^command=\"$dforced prod\"|command=\"$dforced\"|' $dkeys" "does not bind an environment"
kfile_mutation "a key line with no environment in its command (both lines)" \
  "sed -i 's|^command=\"$dforced [a-z]*\"|command=\"$dforced\"|' $dkeys" "does not bind an environment"
kfile_mutation "a line whose command names the wrong environment for its key (each key bound to the other environment)" \
  "printf 'command=\"$dforced prod\",restrict %s oc-deploy-prod\ncommand=\"$dforced staging\",restrict %s oc-deploy-staging\n' '$skey' '$pkey' >$dkeys" "is bound to"
kfile_mutation "a line whose command names an environment the comment and key do not match (only the command word is swapped)" \
  "sed -i -e 's|deploy-release prod\"|deploy-release TMP\"|' -e 's|deploy-release staging\"|deploy-release prod\"|' -e 's|deploy-release TMP\"|deploy-release staging\"|' $dkeys" "key line is not '<key type> <key> oc-deploy-"
kfile_mutation "a key line carrying the pty option beside command= and restrict" "sed -i 's/,restrict /,restrict,pty /' $dkeys" "carries options besides command= and restrict"
kfile_mutation "a key line carrying no-agent-forwarding beside command= and restrict" "sed -i 's/,restrict /,restrict,no-agent-forwarding /' $dkeys" "carries options besides command= and restrict"
kfile_mutation "a key line carrying from= beside command= and restrict" "sed -i 's/,restrict /,restrict,from=\"203.0.113.5\" /' $dkeys" "carries options besides command= and restrict"
kfile_mutation "a key line carrying an option in front of command=" "sed -i 's/^command=/no-pty,command=/' $dkeys" "must start with exactly"
kfile_mutation "the key line loses 'restrict'" "sed -i 's/,restrict//' $dkeys" "must start with exactly"
kfile_mutation "the key line has no-pty instead of restrict" "sed -i 's/,restrict /,no-pty /' $dkeys" "carries options besides command= and restrict"
kfile_mutation "the key line's forced command is /bin/sh" "sed -i 's|^command=\"[^\"]*\"|command=\"/bin/sh prod\"|' $dkeys" "must start with exactly"
kfile_mutation "the key line has no command= at all" "sed -i 's/^command=\"[^\"]*\",restrict //' $dkeys" "must start with exactly"
kfile_mutation "a key line's comment names another environment" "sed -i 's/ oc-deploy-prod\$/ oc-deploy-staging/' $dkeys" "key line is not '<key type> <key> oc-deploy-"
kfile_mutation "the staging line carries an admin's key (alice)" \
  "printf 'command=\"$dforced prod\",restrict %s oc-deploy-prod\ncommand=\"$dforced staging\",restrict %s oc-deploy-staging\n' '$pkey' '$akey' >$dkeys" "is also the key of the admin alice"
mutation DEP-01 "the settings swap the two key files (each key is now configured for the other environment)" \
  "cp -p $work/server.env $dbak/server.env && printf 'OC_DEPLOY_PUBKEY_PROD=$work/keys/deploy-staging.pub\nOC_DEPLOY_PUBKEY_STAGING=$work/keys/deploy-prod.pub\n' >>$work/server.env" \
  "cp -p $dbak/server.env $work/server.env" "is bound to"
mutation DEP-01 "a configured key file cannot be read (so the key line cannot be compared: a check that cannot run fails)" \
  "mv $work/keys/deploy-staging.pub $dbak/deploy-staging.pub" "mv $dbak/deploy-staging.pub $work/keys/deploy-staging.pub" "is not readable"
mutation DEP-01 "the key file is owned by the deploy user (it could rewrite its own forced command)" \
  "chown oc-deploy $dkeys" "chown root $dkeys" "is not owned by root"
mutation DEP-01 "the key file is writable by everyone" "chmod 0666 $dkeys" "chmod 0644 $dkeys" "can be changed by someone other than root"
mutation DEP-01 "the key file is a symbolic link" \
  "mv $dkeys $dbak/keys.real && ln -s $dbak/keys.real $dkeys" "rm -f $dkeys && mv $dbak/keys.real $dkeys" "is missing or not a plain file"
# --- DEP-01: sudo
mutation DEP-01 "the deploy user gets a second sudo rule (all commands)" \
  "printf 'oc-deploy ALL=(ALL) NOPASSWD: ALL\n' >/etc/sudoers.d/93-extra && chmod 0440 /etc/sudoers.d/93-extra" "rm -f /etc/sudoers.d/93-extra" "sudo shows 2 rules"
fmutation DEP-01 "the one sudo rule's arguments become a bare wildcard" "$dsudo" 's|^(oc-deploy ALL=.*apply-release\.sh) .*$|\1 *|' "the one sudo rule is for"
fmutation DEP-01 "the one sudo rule may run as any user" "$dsudo" 's/ALL=\(root\)/ALL=(ALL)/' "does not run as root only"
fmutation DEP-01 "sudo is told to let the deploy user set environment variables" "$dsudo" 's/^Defaults:oc-deploy .*/Defaults:oc-deploy env_reset, setenv/' "lets the deploy account set environment variables"
fmutation DEP-01 "sudo is told to keep environment variables for the deploy user" "$dsudo" 's/^Defaults:oc-deploy .*/Defaults:oc-deploy env_keep+="OC_ROOT OC_PODMAN"/' "is not exactly what the bootstrap writes"
fmutation DEP-01 "the sudo rule asks for a password (it would never work)" "$dsudo" 's/NOPASSWD: //' "has options other than !authenticate"
mutation DEP-01 "the deploy user is in the sudo group" "usermod -aG sudo oc-deploy" "gpasswd -d oc-deploy sudo" "groups beyond its own"
mutation DEP-01 "the deploy user is in the admins' group" "usermod -aG oc-admins oc-deploy" "gpasswd -d oc-deploy oc-admins" "groups beyond its own"
mutation DEP-01 "the deploy user has a password" "usermod -p '\$6\$abc\$def' oc-deploy" "usermod -p '!' oc-deploy" "it has a password"
mutation DEP-01 "the deploy user's shell is bash" "usermod -s /bin/bash oc-deploy" "usermod -s /bin/sh oc-deploy" "its shell is not /bin/sh"
mutation DEP-01 "the deploy user does not exist (renamed away)" "usermod -l oc-deploy-gone oc-deploy" "usermod -l oc-deploy oc-deploy-gone" "the deploy user oc-deploy does not exist"
# --- DEP-01: what it runs
mutation DEP-01 "apply-release.sh is writable by the group" "chmod 0775 $dapply" "chmod 0755 $dapply" "is not root:root 755"
mutation DEP-01 "apply-release.sh is owned by the deploy user" "chown oc-deploy:oc-deploy $dapply" "chown root:root $dapply" "is not root:root 755"
mutation DEP-01 "deploy-release is owned by the deploy user" "chown oc-deploy:oc-deploy $dforced" "chown root:root $dforced" "is not root:root 755"
mutation DEP-01 "apply-release.sh has one line added" "cp -p $dapply $dbak/apply && echo '# changed' >>$dapply" "cp -p $dbak/apply $dapply" "is not the same as infra/deploy/apply-release.sh"
mutation DEP-01 "deploy-release has one line added" "cp -p $dforced $dbak/forced && echo '# changed' >>$dforced" "cp -p $dbak/forced $dforced" "is not the same as infra/deploy/deploy-release.sh"
mutation DEP-01 "the deploy folder is writable by everyone (a script could be replaced)" "chmod 0777 /usr/local/lib/oc/deploy" "chmod 0755 /usr/local/lib/oc/deploy" "can be changed by someone other than root"
mutation DEP-01 "the size limit file says another number" "cp -p $dlimits $dbak/limits && sed -i 's/=.*/=9999999999999/' $dlimits" "cp -p $dbak/limits $dlimits" "does not say MAX_TARBALL_BYTES"
mutation DEP-01 "the deploy user's home is writable by everyone" "chmod 0777 /var/lib/oc-deploy" "chmod 0755 /var/lib/oc-deploy" "is not root:root 755"
mutation DEP-01 "the spool folder is open to everyone" "chmod 0777 /var/lib/oc-deploy/spool" "chmod 0770 /var/lib/oc-deploy/spool" "is not root:oc-deploy 770"
# --- DEP-01: sshd's rules for this user
fmutation DEP-01 "sshd's Match block for the deploy user allows a terminal" "$ddrop" 's/^    PermitTTY no$/    PermitTTY yes/' "permittty is 'yes'"
fmutation DEP-01 "sshd's Match block allows TCP forwarding" "$ddrop" 's/^    AllowTcpForwarding no$/    AllowTcpForwarding yes/' "allowtcpforwarding is 'yes'"
fmutation DEP-01 "sshd's Match block allows agent forwarding" "$ddrop" 's/^    AllowAgentForwarding no$/    AllowAgentForwarding yes/' "allowagentforwarding is 'yes'"
fmutation DEP-01 "sshd's Match block allows X11 forwarding" "$ddrop" 's/^    X11Forwarding no$/    X11Forwarding yes/' "x11forwarding is 'yes'"
fmutation DEP-01 "sshd's Match block allows tunnels" "$ddrop" 's/^    PermitTunnel no$/    PermitTunnel yes/' "permittunnel is 'yes'"
fmutation DEP-01 "sshd's Match block runs ~/.ssh/rc" "$ddrop" 's/^    PermitUserRC no$/    PermitUserRC yes/' "permituserrc is 'yes'"
mutation DEP-01 "sshd's Match block gets a ForceCommand of its own (it would override the key lines' command=, and with it the environment each key fixes)"   "cp -p $ddrop $dbak/drop && sed -i '/^Match User oc-deploy\$/a ForceCommand $dforced' $ddrop" "cp -p $dbak/drop $ddrop" "forcecommand is '$dforced'"
mutation DEP-01 "sshd's Match block forces another command (/bin/sh)"   "cp -p $ddrop $dbak/drop && sed -i '/^Match User oc-deploy\$/a ForceCommand /bin/sh' $ddrop" "cp -p $dbak/drop $ddrop" "forcecommand is '/bin/sh'"
fmutation DEP-01 "sshd's Match block reads the key from the user's own home again" "$ddrop" '/^    AuthorizedKeysFile /d' "authorizedkeysfile is '.ssh/authorized_keys"
mutation DEP-01 "sshd's Match block for the deploy user is gone" "cp -p $ddrop $dbak/drop && sed -i '/^Match User oc-deploy\$/,\$d' $ddrop" "cp -p $dbak/drop $ddrop" "permittty is 'yes'"
# --- SSH-01, SSH-02, SSH-03: asked for each user who may sign in
fmutation SSH-01 "the deploy user's Match block switches passwords on (only the per-user answer shows it)" "$ddrop" 's/^    AuthenticationMethods publickey$/    PasswordAuthentication yes/' "oc-deploy(passwordauthentication=yes"
fmutation SSH-02 "the deploy user's Match block allows root login (only the per-user answer shows it)" "$ddrop" 's/^    MaxSessions 1$/    PermitRootLogin yes/' "oc-deploy(permitrootlogin=yes)"
mutation SSH-01 "a Match block for another address (not the one asked about) switches passwords on" \
  "printf 'Match Address 198.51.100.0/24\n    PasswordAuthentication yes\n' >/etc/ssh/sshd_config.d/10-zz.conf" "rm -f /etc/ssh/sshd_config.d/10-zz.conf" "a Match or Include line this setup did not write"
mutation SSH-02 "a Match block for another address allows root login" \
  "printf 'Match Address 198.51.100.0/24\n    PermitRootLogin yes\n' >/etc/ssh/sshd_config.d/10-zz.conf" "rm -f /etc/ssh/sshd_config.d/10-zz.conf" "a Match or Include line this setup did not write"
mutation SSH-01 "a Match block for the admin bob is added to the main sshd_config" \
  "cp -p /etc/ssh/sshd_config $dbak/sshd_config && printf 'Match User bob\n    PasswordAuthentication yes\n' >>/etc/ssh/sshd_config" "cp -p $dbak/sshd_config /etc/ssh/sshd_config" "a Match or Include line this setup did not write"
mutation SSH-01 "an Include of a file outside sshd_config.d is added" \
  "cp -p /etc/ssh/sshd_config $dbak/sshd_config && printf 'Include /tmp/oc-extra.conf\n' >>/etc/ssh/sshd_config" "cp -p $dbak/sshd_config /etc/ssh/sshd_config" "a Match or Include line this setup did not write"
mutation SSH-01 "our own Match line is spelled with another user name (so it is not ours any more)" \
  "cp -p $ddrop $dbak/drop && sed -i 's/^Match User oc-deploy\$/Match User oc-deploy,bob/' $ddrop" "cp -p $dbak/drop $ddrop" "a Match or Include line this setup did not write"
mutation SSH-03 "the deploy user is no longer in AllowUsers" "cp -p $ddrop $dbak/drop && sed -i 's/^AllowUsers .*/AllowUsers alice bob/' $ddrop" "cp -p $dbak/drop $ddrop" "AllowUsers is 'alice bob'"
mutation SSH-03 "the deploy account is switched off in server.env while its account still exists" \
  "cp -p $work/server.env $dbak/server.env && printf 'OC_DEPLOY_ENABLED=no\n' >>$work/server.env" "cp -p $dbak/server.env $work/server.env" "AllowUsers is 'alice bob oc-deploy'"
mutation DEP-01 "the deploy account is switched off in server.env while its account still exists" \
  "cp -p $work/server.env $dbak/server.env && printf 'OC_DEPLOY_ENABLED=no\n' >>$work/server.env" "cp -p $dbak/server.env $work/server.env" "the deploy account is switched off but is not gone"

# --- DEP-01: with no ForceCommand in the Match block only the key lines' command= forces the command, so
# every other way to sign in as the deploy user must be off, whichever file turns it on
mutation DEP-01 "an earlier sshd drop-in sets a global AuthorizedKeysCommand (a program that prints keys, with no command=)" \
  "printf 'AuthorizedKeysCommand /usr/local/bin/oc-keys\nAuthorizedKeysCommandUser root\n' >/etc/ssh/sshd_config.d/00-aaa.conf" "rm -f /etc/ssh/sshd_config.d/00-aaa.conf" "authorizedkeyscommand is '/usr/local/bin/oc-keys'"
mutation DEP-01 "an earlier sshd drop-in sets a global AuthorizedKeysCommand, and so also a user to run it" \
  "printf 'AuthorizedKeysCommand /usr/local/bin/oc-keys\nAuthorizedKeysCommandUser root\n' >/etc/ssh/sshd_config.d/00-aaa.conf" "rm -f /etc/ssh/sshd_config.d/00-aaa.conf" "authorizedkeyscommanduser is 'root'"
mutation DEP-01 "an earlier sshd drop-in sets only AuthorizedKeysCommandUser" \
  "printf 'AuthorizedKeysCommandUser nobody\n' >/etc/ssh/sshd_config.d/00-aaa.conf" "rm -f /etc/ssh/sshd_config.d/00-aaa.conf" "authorizedkeyscommanduser is 'nobody'"
mutation DEP-01 "an earlier sshd drop-in trusts a certificate authority (TrustedUserCAKeys: a certificate carries its own options, not the key lines')" \
  "cp $work/keys/alice.pub /etc/ssh/oc-test-ca.pub && printf 'TrustedUserCAKeys /etc/ssh/oc-test-ca.pub\n' >/etc/ssh/sshd_config.d/00-aaa.conf" \
  "rm -f /etc/ssh/sshd_config.d/00-aaa.conf /etc/ssh/oc-test-ca.pub" "trustedusercakeys is '/etc/ssh/oc-test-ca.pub'"
mutation DEP-01 "an earlier sshd drop-in sets an AuthorizedPrincipalsFile" \
  "printf 'AuthorizedPrincipalsFile .ssh/authorized_principals\n' >/etc/ssh/sshd_config.d/00-aaa.conf" "rm -f /etc/ssh/sshd_config.d/00-aaa.conf" "authorizedprincipalsfile is '.ssh/authorized_principals'"
mutation DEP-01 "the deploy user's own Match block sets an AuthorizedKeysCommand" \
  "cp -p $ddrop $dbak/drop && sed -i '/^Match User oc-deploy\$/a AuthorizedKeysCommand /usr/local/bin/oc-keys' $ddrop" "cp -p $dbak/drop $ddrop" "authorizedkeyscommand is '/usr/local/bin/oc-keys'"
# the four settings are "none" on the real system (positive control for the four above: they are looked at)
yes_if "sshd answers none for all four settings for the deploy user (positive control)" bash -c "
  out=\$(sshd -T -C user=oc-deploy,host=x,addr=203.0.113.1)
  grep -qx 'authorizedkeyscommand none' <<<\"\$out\" && grep -qx 'authorizedkeyscommanduser none' <<<\"\$out\" && grep -qx 'trustedusercakeys none' <<<\"\$out\" && grep -qx 'authorizedprincipalsfile none' <<<\"\$out\""


# --- DEP-02: what the deploy user can reach, tried as that user
mutation DEP-02 "a secret file is readable by everyone" "chmod 0644 /etc/oc/prod.env" "chmod 0640 /etc/oc/prod.env" "can read /etc/oc/prod.env"
mutation DEP-02 "the deploy user is in the group of an environment (it can read the env files)" "usermod -aG oc-prod oc-deploy" "gpasswd -d oc-deploy oc-prod" "can read /etc/oc/prod.env"
mutation DEP-02 "/etc/oc can be listed by everyone" "chmod 0755 /etc/oc" "chmod 0711 /etc/oc" "can list /etc/oc"
mutation DEP-02 "an environment's data folder is open to everyone" "chmod 0755 /var/lib/oc/prod" "chmod 0750 /var/lib/oc/prod" "can read /var/lib/oc/prod"
mutation DEP-02 "an environment user's home is open to everyone" "chmod 0755 /home/oc-prod" "chmod 0700 /home/oc-prod" "can read /home/oc-prod"
mutation DEP-02 "the deploy user cannot write its spool (the control: otherwise every 'cannot' above proves nothing)" \
  "chmod 0750 /var/lib/oc-deploy/spool" "chmod 0770 /var/lib/oc-deploy/spool" "control: oc-deploy cannot write its own spool folder"
mutation DEP-02 "commands cannot be run as the deploy user at all (a failing runuser)" \
  "printf '#!/bin/sh\nexit 1\n' >/usr/local/sbin/runuser && chmod 0755 /usr/local/sbin/runuser" "rm -f /usr/local/sbin/runuser" "cannot run a command as oc-deploy"
mutation DEP-02 "the deploy user may get a root shell through sudo" \
  "printf 'oc-deploy ALL=(ALL) NOPASSWD: ALL\n' >/etc/sudoers.d/93-extra && chmod 0440 /etc/sudoers.d/93-extra" "rm -f /etc/sudoers.d/93-extra" "a root shell through sudo works"
mutation DEP-02 "the deploy user may run sudo true" \
  "printf 'oc-deploy ALL=(root) NOPASSWD: /usr/bin/true\n' >/etc/sudoers.d/93-extra && chmod 0440 /etc/sudoers.d/93-extra" "rm -f /etc/sudoers.d/93-extra" "sudo -n true works"
mutation DEP-02 "the deploy user owns what it runs (it could replace apply-release.sh)" "chown oc-deploy $dapply" "chown root $dapply" "can write $dapply"
mutation DEP-02 "/usr/local/sbin is writable by everyone" "chmod 0777 /usr/local/sbin" "chmod 0755 /usr/local/sbin" "can write /usr/local/sbin"
mutation DEP-02 "the deploy user's home is writable by everyone" "chmod 0777 /var/lib/oc-deploy" "chmod 0755 /var/lib/oc-deploy" "can write /var/lib/oc-deploy"
mutation DEP-02 "an environment's data folder is missing (so it cannot be checked, which is a failure)" \
  "mv /var/lib/oc/prod/tmp $dbak/prodtmp" "mv $dbak/prodtmp /var/lib/oc/prod/tmp" "/var/lib/oc/prod/tmp does not exist, so it cannot be checked"

# --- DEP-02, Task 4b: MariaDB's data folder and socket, /var/log, a missing /etc/oc
# --- DEP-02 ------------------------------------------------------------------------------------
mutation DEP-02 "/etc/oc is missing (a folder that is not there cannot be tried, so it is a failure, not a pass)" \
  "mv /etc/oc /etc/oc.gone" "mv /etc/oc.gone /etc/oc" "/etc/oc does not exist, so it cannot be checked"
mutation DEP-02 "a MariaDB data file is readable by everyone" \
  "chmod 0644 /var/lib/mysql/ibdata1" "chmod 0660 /var/lib/mysql/ibdata1" "can read in the MariaDB data folder: /var/lib/mysql/ibdata1"
mutation DEP-02 "the MariaDB data folder is missing (it cannot be checked)" \
  "mv /var/lib/mysql /var/lib/mysql.gone" "mv /var/lib/mysql.gone /var/lib/mysql" "/var/lib/mysql does not exist, so it cannot be checked"
mutation DEP-02 "the deploy user can sign in to MariaDB through its socket (a unix_socket account of its own name)" \
  "mariadb -e \"CREATE USER 'oc-deploy'@'localhost' IDENTIFIED VIA unix_socket\"" "mariadb -e \"DROP USER 'oc-deploy'@'localhost'\"" "oc-deploy can sign in to MariaDB through its socket as 'oc-deploy'"
mutation DEP-02 "the MariaDB socket is not where the verifier looks (so no sign-in could be tried: that is a failure)" \
  "mv /run/mysqld/mysqld.sock /run/mysqld/mysqld.sock.moved" "mv /run/mysqld/mysqld.sock.moved /run/mysqld/mysqld.sock" "the MariaDB socket /run/mysqld/mysqld.sock does not exist"
mutation DEP-02 "/var/log can be written by everyone" "chmod 0777 /var/log" "chmod 0755 /var/log" "can write /var/log"
mutation DEP-02 "the sudo log is readable by everyone" "chmod 0644 /var/log/sudo.log" "chmod 0600 /var/log/sudo.log" "can read /var/log/sudo.log"
mutation DEP-02 "the audit log folder is readable by everyone" "chmod 0755 /var/log/audit" "chmod 0750 /var/log/audit" "can read /var/log/audit"

# --- Task 4b, step 1: NET-03 false passes ------------------------------------------------------------
cacert=/etc/nginx/oc/cloudflare-origin-pull-ca.pem

# (i) the old "ssl" directive, at any level and in any case
mutation NET-03 "a server turns TLS on with 'ssl ON;' (upper case) and has no client certificate" \
  "printf 'server { listen 8452; ssl ON; server_name sslonu.example.test; $tls }\n' >$ngxsrv" "rm -f $ngxsrv" "'ssl' directive" "sslonu.example.test: ssl_verify_client ''"
mutation NET-03 "'ssl on;' is written at the http level (it makes every server TLS, the certificate-less ones too)" \
  "printf 'ssl on;\nssl_certificate /etc/ssl/oc/origin.pem;\nssl_certificate_key /etc/ssl/oc/origin.key;\n' >$ngxsrv" "rm -f $ngxsrv" "'ssl' directive"
mutation NET-03 "'ssl off;' is written (every ssl directive is refused, whatever its value)" \
  "printf 'server { listen 8453; ssl off; server_name ssloff.example.test; }\n' >$ngxsrv" "rm -f $ngxsrv" "'ssl' directive"

# (ii) TLS belongs to the port: a server whose listen says nothing about ssl is TLS when another listens on its port with ssl
mutation NET-03 "a server with a plain 'listen 443;' shares the TLS port 443 and has no client certificate" \
  "printf 'server { listen 443; server_name plain443.example.test; $tls }\n' >$ngxsrv" "rm -f $ngxsrv" "plain443.example.test: ssl_verify_client ''" "another server listens with ssl on the same port"
mutation NET-03 "a server with 'listen 127.0.0.1:443;' (another address, the same port) has no client certificate" \
  "printf 'server { listen 127.0.0.1:443; server_name plainaddr.example.test; $tls }\n' >$ngxsrv" "rm -f $ngxsrv" "plainaddr.example.test: ssl_verify_client ''" "another server listens with ssl on the same port"
mutation NET-03 "a server with 'listen [::]:443;' has no client certificate" \
  "printf 'server { listen [::]:443; server_name plainv6.example.test; $tls }\n' >$ngxsrv" "rm -f $ngxsrv" "plainv6.example.test: ssl_verify_client ''" "another server listens with ssl on the same port"
mutation NET-03 "the second server of a pair on port 8454 says 'listen 8454;' (the first says ssl and has the certificate check)" \
  "printf 'server { listen 8454 ssl; server_name pairA.example.test; $tls ssl_client_certificate $cacert; ssl_verify_client on; ssl_protocols TLSv1.2 TLSv1.3; }\nserver { listen 8454; server_name pairB.example.test; $tls }\n' >$ngxsrv" "rm -f $ngxsrv" "pairB.example.test: ssl_verify_client ''"
mutation NET-03 "a port range with ssl (listen 8460-8470 ssl) is a layout this check cannot place on ports" \
  "printf 'server { listen 8460-8470 ssl; server_name range.example.test; $tls ssl_client_certificate $cacert; ssl_verify_client on; ssl_protocols TLSv1.2 TLSv1.3; }\n' >$ngxsrv" "rm -f $ngxsrv" "could not be read reliably"

# positive controls: the same parser accepts a plain server on a port of its own, and values in other cases
printf 'server { listen 8455; server_name plain8455.example.test; return 404; }\n' >"$ngxsrv"
bash "$infra/verify.sh" >"$work/verify-ngx-plain.txt" 2>&1 || true
rm -f "$ngxsrv"
yes_if "a plain HTTP server on a port of its own is still accepted (NET-03 counts the same 4 TLS sites)" grep -q '^PASS NET-03 all 4 TLS sites' "$work/verify-ngx-plain.txt"

# (iii) the value of ssl_verify_client and ssl_reject_handshake is read without regard to case, as Nginx reads it
printf 'server { listen 8456 ssl; server_name upper.example.test; %s ssl_client_certificate %s; ssl_verify_client ON; ssl_protocols TLSv1.2 TLSv1.3; return 404; }\n' "$tls" "$cacert" >"$ngxsrv"
bash "$infra/verify.sh" >"$work/verify-ngx-upper.txt" 2>&1 || true
rm -f "$ngxsrv"
yes_if "'ssl_verify_client ON;' (upper case) is accepted as on (NET-03 counts 5 TLS sites)" grep -q '^PASS NET-03 all 5 TLS sites' "$work/verify-ngx-upper.txt"
printf 'server { listen 8457 ssl; server_name rej.example.test; ssl_reject_handshake On; ssl_protocols TLSv1.2 TLSv1.3; }\n' >"$ngxsrv"
bash "$infra/verify.sh" >"$work/verify-ngx-rej.txt" 2>&1 || true
rm -f "$ngxsrv"
yes_if "'ssl_reject_handshake On;' (mixed case) makes a server exempt like 'on' (NET-03 still counts 4 TLS sites)" grep -q '^PASS NET-03 all 4 TLS sites' "$work/verify-ngx-rej.txt"
mutation NET-03 "a TLS server asks for the client certificate with 'ssl_verify_client OFF;' (upper case)" \
  "printf 'server { listen 8458 ssl; server_name offupper.example.test; $tls ssl_client_certificate $cacert; ssl_verify_client OFF; }\n' >$ngxsrv" "rm -f $ngxsrv" "offupper.example.test: ssl_verify_client 'OFF'"

# the live branch (unit tests: a function stands in for systemctl and curl, the configuration is text)
live_net03() { # CONFIG-TEXT ANSWER-OF-CURL: the verdict of NET-03 as it would be on a real server, then the curl calls
  rm -f "$work/curl.log"
  OC_T=$1 OC_CURL_ANSWER=${2:-400} OC_CURL_LOG=$work/curl.log bash -c '
    source "$1/verify.sh"
    VERIFY_CONTAINER=0
    systemctl() { return 0; }
    curl() { printf "%s\n" "$*" >>"$OC_CURL_LOG"; printf "%s" "$OC_CURL_ANSWER"; }
    NGINX_T=$OC_T
    NGINX_SERVERS=$(nginx_servers <<<"$NGINX_T")
    CUR=NET-03
    check_net_03' _ "$infra"
  [[ -f $work/curl.log ]] && sed 's/^/curl: /' "$work/curl.log"
  return 0
}
caok=$infra/nginx/cloudflare-origin-pull-ca.pem
live_cfg="server { listen 443 ssl; listen 8443 ssl; server_name a.example.test *.wild.example.test ~^re\\.example\\.test\$ _; ssl_verify_client on; ssl_client_certificate $caok; ssl_protocols TLSv1.2 TLSv1.3; }
server { listen 9443 ssl; server_name only-wild.example.test; ssl_verify_client on; ssl_client_certificate $caok; }"
live_out=$(live_net03 "$live_cfg" 400)
# shellcheck disable=SC2317  # called through yes_if
live_has() { [[ $live_out == *"$1"* ]]; }
yes_if "live NET-03: a TLS listen that is not 443 is requested too (https://a.example.test:8443/ with --resolve for that port)" live_has 'curl: -sk --max-time 10 -o /dev/null -w %{http_code} --resolve a.example.test:8443:127.0.0.1 https://a.example.test:8443/'
yes_if "live NET-03: port 443 is still requested as before" live_has 'curl: -sk --max-time 10 -o /dev/null -w %{http_code} --resolve a.example.test:443:127.0.0.1 https://a.example.test/'
yes_if "live NET-03: the name on the third TLS port (9443) is requested" live_has '--resolve only-wild.example.test:9443:127.0.0.1 https://only-wild.example.test:9443/'
yes_if "live NET-03: it says it did not test the wildcard name" live_has '*.wild.example.test on port 443'
yes_if "live NET-03: it says it did not test the regular-expression name" live_has '~^re\.example\.test$ on port 443'
yes_if "live NET-03: it says it did not test '_'" live_has '_ on port 8443'
yes_if "live NET-03: and the line is still a PASS that says what was NOT TESTED LIVE" live_has 'PASS NET-03 all 2 TLS sites require Cloudflare'"'"'s client certificate; a request without one is refused on all 3 host name and port pairs. NOT TESTED LIVE'
live_out=$(live_net03 "$live_cfg" 200)
yes_if "live NET-03 fails when a non-443 TLS listen does not refuse a request without the certificate (answers 200)" live_has 'FAIL NET-03 a request without Cloudflare'"'"'s client certificate was not refused: [a.example.test on port 443 answered 200 to a request without a client certificate] [a.example.test on port 8443 answered 200'
live_cfg2="server { listen 443 ssl; server_name a.example.test; ssl_verify_client on; ssl_client_certificate $caok; ssl_protocols TLSv1.2 TLSv1.3; }"
live_out=$(live_net03 "$live_cfg2" 400)
yes_if "live NET-03: a configuration with only plain names says nothing is skipped (positive control: no NOT TESTED text)" bash -c "[[ \$1 == *'PASS NET-03 all 1 TLS sites'* && \$1 != *'NOT TESTED'* ]]" _ "$live_out"
live_cfg3="server { listen 8443 ssl; server_name *.wild.example.test; ssl_verify_client on; ssl_client_certificate $caok; }"
live_out=$(live_net03 "$live_cfg3" 400)
yes_if "live NET-03: when no name at all can be requested it FAILs and names what it skipped" live_has 'FAIL NET-03 no TLS host name could be tested live; skipped: [*.wild.example.test on port 8443'

# --- Task 4b, step 2: CTR-04 (the environment users' own configuration) ------------------------------
yes_if "before the CTR-04 changes: CTR-04 passes on the untouched system (so a FAIL below is caused by the change)" \
  bash -c "VERIFY_ONLY=CTR-04 bash '$infra/verify.sh' 2>&1 | grep -q '^PASS CTR-04 '"
mutation CTR-04 "a user-level systemd unit of the same name overrides oc-web-prod.service" \
  "mkdir -p /home/oc-prod/.config/systemd/user && printf '[Service]\nExecStart=/bin/sh\n' >/home/oc-prod/.config/systemd/user/oc-web-prod.service" \
  "rm -rf /home/oc-prod/.config/systemd" "oc-web-prod.service is a user-level systemd unit or drop-in of ours"
mutation CTR-04 "a drop-in folder next to oc-cms-prod.service in the user's own systemd folder adds a command" \
  "mkdir -p /home/oc-prod/.config/systemd/user/oc-cms-prod.service.d && printf '[Service]\nExecStartPre=/bin/sh\n' >/home/oc-prod/.config/systemd/user/oc-cms-prod.service.d/10-x.conf" \
  "rm -rf /home/oc-prod/.config/systemd" "oc-cms-prod.service.d is a user-level systemd unit or drop-in of ours"
mutation CTR-04 "staging gets a user-level unit for its own web service too" \
  "mkdir -p /home/oc-staging/.config/systemd/user && printf '[Service]\n' >/home/oc-staging/.config/systemd/user/oc-web-staging.service" \
  "rm -rf /home/oc-staging/.config/systemd" "oc-staging: /home/oc-staging/.config/systemd/user/oc-web-staging.service"
mutation CTR-04 "a unit of ours sits in ~/.local/share/systemd/user (the other user-writable unit folder)" \
  "mkdir -p /home/oc-prod/.local/share/systemd/user && printf '[Service]\n' >/home/oc-prod/.local/share/systemd/user/oc-prod-network.service" \
  "rm -rf /home/oc-prod/.local" "/home/oc-prod/.local/share/systemd/user/oc-prod-network.service is a user-level systemd unit"
mutation CTR-04 "the user's .config/systemd/user is a symbolic link" \
  "mkdir -p /home/oc-prod/.config/systemd /tmp/elsewhere && ln -s /tmp/elsewhere /home/oc-prod/.config/systemd/user" \
  "rm -rf /home/oc-prod/.config/systemd /tmp/elsewhere" "/home/oc-prod/.config/systemd/user is a symbolic link"
mutation CTR-04 "the user has a containers.conf" \
  "printf '[containers]\ndefault_capabilities=[\"ALL\"]\n' >/home/oc-prod/.config/containers/containers.conf" \
  "rm -f /home/oc-prod/.config/containers/containers.conf" "/home/oc-prod/.config/containers/containers.conf exists"
mutation CTR-04 "the user has a containers.conf.d folder" \
  "mkdir -p /home/oc-staging/.config/containers/containers.conf.d" \
  "rm -rf /home/oc-staging/.config/containers/containers.conf.d" "/home/oc-staging/.config/containers/containers.conf.d exists"
mutation CTR-04 "an environment user does not exist (so nothing can be said about its configuration: a check that cannot look fails)" \
  "usermod -l oc-prod-gone oc-prod" "usermod -l oc-prod oc-prod-gone" "the user, or its home /home/oc-prod, does not exist"
# a harmless file of another name does not fail (so the check is not failing on anything it finds there)
mkdir -p /home/oc-prod/.config/systemd/user
printf '[Service]\n' >/home/oc-prod/.config/systemd/user/some-other.service
VERIFY_ONLY=CTR-04 bash "$infra/verify.sh" >"$work/verify-ctr04-other.txt" 2>&1 || true
rm -rf /home/oc-prod/.config/systemd
yes_if "a user-level unit that is not ours (some-other.service) is left alone (positive control)" grep -q '^PASS CTR-04 ' "$work/verify-ctr04-other.txt"

# CTR-04, the live half. A function stands in for `systemctl --user cat` and for `podman container
# inspect`, so the comparison itself is tested here; what the real commands print is for a real server.
c4=$work/c4
cat >"$work/ctr04-live.sh" <<'EOS'
source "$1/verify.sh"
VERIFY_CONTAINER=0
oc_load_config "$OC_CONFIG"; oc_validate_config
ctr04_unit_text() { cat "$OC_UNITS_DIR/$2"; }
ctr04_inspect_facts() {
  local f=$OC_FACTS_DIR/$2-$1
  if [[ $(cat "$f") == ERROR ]]; then echo "Error: podman is broken"; return 1; fi
  cat "$f"
}
CUR=CTR-04
check_ctr_04
EOS
c4_reset() { # good units (from Podman's own dry run, with the header systemctl cat prints) and good facts
  local env role uid gid hp ip
  rm -rf "$c4" && mkdir -p "$c4/units" "$c4/facts"
  for env in prod staging; do
    uid=$(id -u "oc-$env") && gid=$(id -g "oc-$env")
    QUADLET_UNIT_DIRS=/home/oc-$env/.config/containers/systemd "$quadlet" -dryrun -user 2>/dev/null |
      awk -v d="$c4/units" -v u="$uid" '/^---.*---$/ {name = substr($0, 4, length($0) - 6); f = d "/" name; print "# /run/user/" u "/systemd/generator/" name > f; next} name != "" {print >> f}'
    for role in cms web; do
      if [[ $role == cms ]]; then
        hp=$([[ $env == prod ]] && echo 1337 || echo 1338)
        ip=1337
      else
        hp=$([[ $env == prod ]] && echo 4321 || echo 4322)
        ip=4321
      fi
      {
        printf 'running=true\nprivileged=false\nreadonly=true\nuser=%s:%s\npids=256\nmemory=536870912\neffectivecaps=0\ncapadd=0\n' "$uid" "$gid"
        printf 'securityopt=no-new-privileges,\nnetworks=oc-%s,\nimagename=localhost/oc-%s:bootstrap\nimageid=%064d\n' "$env" "$role" 7
        if [[ $role == cms ]]; then
          printf 'mount|bind|/var/lib/oc/%s|/var/lib/oc/%s|true\nmount|bind|/run/mysqld|/run/mysqld|false\nmount|bind|/run/clamav|/run/clamav|false\n' "$env" "$env"
        else
          printf 'mount|bind|/var/lib/oc/%s/media|/var/lib/oc/%s/media|false\n' "$env" "$env"
        fi
        printf 'tmpfs|/tmp|rw,noexec,nosuid,size=64m,rprivate,nodev,tmpcopyup\nport|127.0.0.1|%s|%s/tcp\n' "$hp" "$ip"
      } >"$c4/facts/$role-$env"
    done
  done
}
c4_run() { OC_UNITS_DIR=$c4/units OC_FACTS_DIR=$c4/facts bash "$work/ctr04-live.sh" "$infra" 2>&1 || true; }
c4_edit() { # FILE SED-EXPRESSION
  sed -i -E "$2" "$1"
}
c4_expect() { # DESCRIPTION FILE SED-EXPRESSION TEXT-IN-THE-OUTPUT
  local out
  c4_reset
  c4_edit "$2" "$3"
  out=$(c4_run)
  if [[ $out == FAIL\ CTR-04\ * && $out == *"$4"* ]]; then
    ok "CTR-04 (live) fails when $1 (because: $4)"
  else
    notok "CTR-04 (live) should fail when $1 (because: $4); it said: ${out:0:300}"
  fi
}
c4_reset
out=$(c4_run)
if [[ $out == "PASS CTR-04 2 environment user(s): no user-level unit"* ]]; then ok "CTR-04 (live) passes on the real generated units and good container facts (positive control)"; else notok "CTR-04 (live) positive control: $out"; fi
ucat=$c4/units
c4_expect "a drop-in is listed after the generated unit (systemctl cat shows another file)" "$ucat/oc-web-prod.service" '1a # /home/oc-prod/.config/systemd/user/oc-web-prod.service.d/x.conf' "oc-web-prod.service is not only what the generator wrote"
c4_expect "the unit comes from the user's own file, not the generator" "$ucat/oc-cms-prod.service" '1s|.*|# /home/oc-prod/.config/systemd/user/oc-cms-prod.service|' "oc-cms-prod.service is not only what the generator wrote"
c4_expect "the unit systemd has runs podman with --privileged (the same check as the dry run)" "$ucat/oc-web-staging.service" 's|^(ExecStart=/usr/bin/podman run )|\1--privileged |' "oc-staging live: oc-web-staging.service: the generated command has the flag '--privileged'"
c4_expect "the unit systemd has gains an ExecStartPre" "$ucat/oc-web-prod.service" 's|^(ExecStart=)|ExecStartPre=/usr/bin/podman run --privileged x\n\1|' "oc-prod live: oc-web-prod.service: the generated unit has ExecStartPre="
# shellcheck disable=SC2016  # sed expressions below: the $ signs are sed's, not the shell's
c4_expect "the unit cannot be read at all" "$ucat/oc-prod-network.service" '1,$d' "has 0 ExecStart lines"
f=$c4/facts
c4_expect "a container is privileged" "$f/web-prod" 's/^privileged=false/privileged=true/' "oc-web-prod: the container is privileged"
c4_expect "a container's root file system is writable" "$f/cms-staging" 's/^readonly=true/readonly=false/' "oc-cms-staging: the container's root file system is not read-only"
c4_expect "a container runs as root" "$f/web-prod" 's/^user=.*/user=0:0/' "oc-web-prod: the container runs as '0:0'"
c4_expect "a container has no memory limit" "$f/web-prod" 's/^memory=.*/memory=0/' "the container has no memory limit"
c4_expect "a container has no pids limit" "$f/cms-prod" 's/^pids=.*/pids=0/' "the container has no pids limit"
c4_expect "a container keeps capabilities" "$f/web-prod" 's/^effectivecaps=.*/effectivecaps=14/' "the container has 14 capabilities"
c4_expect "a container was given an added capability" "$f/web-prod" 's/^capadd=.*/capadd=1/' "was given 1 added capabilities"
c4_expect "a container lacks no-new-privileges" "$f/web-prod" 's/^securityopt=.*/securityopt=/' "no-new-privileges is not set"
c4_expect "a container runs unconfined" "$f/web-prod" 's/^securityopt=.*/securityopt=no-new-privileges,seccomp=unconfined,/' "unconfined security option"
c4_expect "a container is on the host network" "$f/web-prod" 's/^networks=.*/networks=host,/' "the container is on the networks 'host,'"
c4_expect "a container runs an image from a registry" "$f/web-prod" 's|^imagename=.*|imagename=docker.io/library/node:22|' "which is not a local oc-web image"
# shellcheck disable=SC2016
c4_expect "a container has an extra mount of /" "$f/web-prod" '$a mount|bind|/|/host|true' "the container has the mount '/:/host', which is not allowed"
c4_expect "a container mounts ClamAV read-write" "$f/cms-prod" 's|^(mount.bind./run/clamav./run/clamav.)false|\1true|' "the container has the mount '/run/clamav:/run/clamav', which is not allowed"
c4_expect "a container lacks one of its mounts" "$f/cms-prod" '/mount.bind.\/run\/mysqld/d' "the container lacks the mount '/run/mysqld:/run/mysqld:ro'"
# shellcheck disable=SC2016
c4_expect "a container has a volume of another type" "$f/web-prod" '$a mount|volume|/var/lib/x|/data|true' "has a mount of type 'volume'"
c4_expect "a container publishes on every interface" "$f/web-prod" 's/^port\|127.0.0.1/port|0.0.0.0/' "published ports are '0.0.0.0:4321->4321/tcp'"
# shellcheck disable=SC2016
c4_expect "a container publishes a second port" "$f/web-prod" '$a port|127.0.0.1|22|22/tcp' "published ports are"
c4_expect "a container's tmpfs allows exec" "$f/web-prod" 's/^tmpfs\|\/tmp\|rw,noexec,/tmpfs|\/tmp|rw,exec,/' "the tmpfs at /tmp is not noexec"
c4_expect "a container's tmpfs has the suid option" "$f/web-prod" 's/,nodev,/,suid,/' "the tmpfs at /tmp has the option 'suid'"
c4_expect "a container has a tmpfs somewhere else" "$f/web-prod" 's/^tmpfs\|\/tmp\|/tmpfs|\/var\/lib\/oc|/' "the container has a tmpfs at /var/lib/oc"
c4_expect "a container has no tmpfs at all" "$f/web-prod" '/^tmpfs\|/d' "the container has 0 tmpfs mounts, not exactly one"
# shellcheck disable=SC2016
c4_expect "podman cannot be asked about a container" "$f/web-prod" '1s/.*/ERROR/;2,$d' "podman could not be asked about oc-web-prod"
# a container that does not exist yet is a warning (a first deploy has not happened), not a failure; the rest is still compared
c4_reset
printf 'absent\n' >"$f/web-prod"
out=$(c4_run)
if [[ $out == WARN\ CTR-04\ * && $out == *"do not exist yet"*"oc-web-prod"* ]]; then ok "CTR-04 (live): a container that does not exist yet is a WARN, not a FAIL (nothing deployed yet)"; else notok "absent container: ${out:0:300}"; fi
sed -i 's/^privileged=false/privileged=true/' "$f/cms-prod"
out=$(c4_run)
if [[ $out == FAIL\ CTR-04\ * && $out == *"oc-cms-prod: the container is privileged"* ]]; then ok "CTR-04 (live): with one container absent the others are still compared"; else notok "absent plus bad: ${out:0:300}"; fi
rm -rf "$c4"


# --- Task 4b, step 3: the verifier says only what it checked ---------------------------------------------
# NET-01: ufw's IPv6 setting
mutation NET-01 "ufw is told to leave IPv6 alone (IPV6=no)" \
  "sed -i 's/^IPV6=.*/IPV6=no/' /etc/default/ufw" "sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw" "IPV6=yes"
# SVC-02: a line that starts with ; is a variable name to Podman, not a comment
wmutation "the website's file has a line that starts with ; (Podman reads only # as a comment, so this is a variable)" "printf ';DATABASE_PASSWORD=x\n' >>$wfile" "a line that is not NAME=value"
wmutation "the website's file has an indented ; line" "printf '   ;SECRET=x\n' >>$wfile" "a line that is not NAME=value"
cp -p "$wfile" "$qbak/web.env.orig"
printf '# a real comment\n   # an indented comment\n\n' >>"$wfile"
VERIFY_ONLY=SVC-02 bash "$infra/verify.sh" >"$work/verify-svc02-comment.txt" 2>&1 || true
mv -f "$qbak/web.env.orig" "$wfile"
yes_if "comment lines that start with # (also indented) and empty lines are fine in the website's file (positive control)" grep -q '^PASS SVC-02 ' "$work/verify-svc02-comment.txt"

# NGX-01: server_tokens and client_max_body_size wherever they stand, and in any case
mutation NGX-01 "server_tokens is switched on in a one-line server" \
  "printf 'server { listen 8461; server_tokens on; server_name tok.example.test; }\n' >$ngxsrv" "rm -f $ngxsrv" "server_tokens is 'on' somewhere"
mutation NGX-01 "server_tokens is switched on after a # in the middle of a word on the same line" \
  "printf 'server { listen 8462; add_header X a#b; server_tokens build; server_name tok2.example.test; }\n' >$ngxsrv" "rm -f $ngxsrv" "server_tokens is 'build' somewhere"
mutation NGX-01 "server_tokens is written in upper case (ON)" \
  "printf 'server { listen 8463; server_tokens ON; server_name tok3.example.test; }\n' >$ngxsrv" "rm -f $ngxsrv" "server_tokens is 'ON' somewhere"
mutation NGX-01 "a one-line server lifts the request size limit (client_max_body_size 0)" \
  "printf 'server { listen 8464; client_max_body_size 0; server_name big.example.test; }\n' >$ngxsrv" "rm -f $ngxsrv" "client_max_body_size is '0' somewhere"
mutation NGX-01 "a one-line server raises the request size limit (client_max_body_size 2g)" \
  "printf 'server { listen 8465; client_max_body_size 2g; server_name big2.example.test; }\n' >$ngxsrv" "rm -f $ngxsrv" "client_max_body_size is '2g' somewhere"
printf 'server { listen 8466; client_max_body_size 30M; server_tokens OFF; server_name ok.example.test; return 404; }\n' >"$ngxsrv"
VERIFY_ONLY=NGX-01 bash "$infra/verify.sh" >"$work/verify-ngx01-ok.txt" 2>&1 || true
rm -f "$ngxsrv"
yes_if "'client_max_body_size 30M;' and 'server_tokens OFF;' in a one-line server are accepted (positive control)" grep -q '^PASS NGX-01 ' "$work/verify-ngx01-ok.txt"

# DB-01: no account but the environment's own may hold any privilege on its database
mutation DB-01 "an account with another name (backup) has SELECT on the prod database" \
  "mariadb -e \"CREATE USER 'backup'@'localhost' IDENTIFIED BY 'x'; GRANT SELECT ON \\\`oc_prod\\\`.* TO 'backup'@'localhost'\"" \
  "mariadb -e \"DROP USER 'backup'@'localhost'\"" "oc_prod can also be reached by: 'backup'@'localhost' (on the database)"
mutation DB-01 "an account is granted a database PATTERN that matches the prod database (oc%)" \
  "mariadb -e \"CREATE USER 'ops'@'localhost'; GRANT SELECT ON \\\`oc%\\\`.* TO 'ops'@'localhost'\"" \
  "mariadb -e \"DROP USER 'ops'@'localhost'\"" "oc_prod can also be reached by: 'ops'@'localhost' (on the database)"
mutation DB-01 "an account may read one table of the prod database" \
  "mariadb -e \"CREATE TABLE oc_prod.t1 (a INT); CREATE USER 'rpt'@'localhost'; GRANT SELECT ON oc_prod.t1 TO 'rpt'@'localhost'\"" \
  "mariadb -e \"DROP USER 'rpt'@'localhost'; DROP TABLE oc_prod.t1\"" "'rpt'@'localhost' (on a table)"
mutation DB-01 "an account may read one column of a table of the staging database" \
  "mariadb -e \"CREATE TABLE oc_staging.t1 (a INT); CREATE USER 'rpt'@'localhost'; GRANT SELECT (a) ON oc_staging.t1 TO 'rpt'@'localhost'\"" \
  "mariadb -e \"DROP USER 'rpt'@'localhost'; DROP TABLE oc_staging.t1\"" "oc_staging can also be reached by: 'rpt'@'localhost' (on a column)"
mutation DB-01 "an account has a global privilege (SELECT ON *.*)" \
  "mariadb -e \"CREATE USER 'dba'@'localhost'; GRANT SELECT ON *.* TO 'dba'@'localhost'\"" \
  "mariadb -e \"DROP USER 'dba'@'localhost'\"" "'dba'@'localhost' (global)"
mutation DB-01 "an account that may be used from any host has ALL on the staging database" \
  "mariadb -e \"CREATE USER 'remote'@'%'; GRANT ALL ON \\\`oc_staging\\\`.* TO 'remote'@'%'\"" \
  "mariadb -e \"DROP USER 'remote'@'%'\"" "oc_staging can also be reached by: 'remote'@'%'"
mutation DB-01 "the other environment's account may read this environment's database" \
  "mariadb -e \"GRANT SELECT ON \\\`oc_staging\\\`.* TO 'oc_prod'@'localhost'\"" \
  "mariadb -e \"REVOKE SELECT ON \\\`oc_staging\\\`.* FROM 'oc_prod'@'localhost'\"" "oc_staging can also be reached by: 'oc_prod'@'localhost' (on the database)"
mariadb -e "CREATE USER 'idle'@'localhost'"
VERIFY_ONLY=DB-01 bash "$infra/verify.sh" >"$work/verify-db-idle.txt" 2>&1 || true
mariadb -e "DROP USER 'idle'@'localhost'"
yes_if "an account with no privileges at all is left alone (positive control: DB-01 does not fail on every extra account)" grep -q '^PASS DB-01 ' "$work/verify-db-idle.txt"

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

# --- VERIFY_ONLY is for the test container only, and a subset run can never look like a full one -------------
# vo_run ENV-ASSIGNMENT...: run verify.sh with those variables; the output is in $work/vo.txt, the status in $VO_RC
vo_run() {
  VO_RC=0
  env "$@" bash "$infra/verify.sh" >"$work/vo.txt" 2>&1 || VO_RC=$?
}
# shellcheck disable=SC2317  # called through yes_if
vo_has() { grep -qE -- "$1" "$work/vo.txt"; }
# shellcheck disable=SC2317
vo_no_check_ran() { [[ $(grep -cE '^(PASS|FAIL|WARN|SKIP) ' "$work/vo.txt") -eq 1 && $(grep -c '^FAIL CFG-0' "$work/vo.txt") -eq 1 ]]; }
# shellcheck disable=SC2317
vo_refused() { [[ $VO_RC -ne 0 ]] && grep -q '^FAIL CFG-0' "$work/vo.txt"; }
# (a) a real host: the container's VERIFY_CONTAINER=1 is what allows it
vo_run VERIFY_CONTAINER=0 VERIFY_ONLY=NET-03
yes_if "VERIFY_ONLY on a real host (VERIFY_CONTAINER is 0) is refused: FAIL CFG-02" vo_has '^FAIL CFG-02 VERIFY_ONLY is set'
yes_if "VERIFY_ONLY on a real host is a non-zero exit with a CFG failure" vo_refused
yes_if "VERIFY_ONLY on a real host runs no check at all (one FAIL line, no PASS, SKIP or WARN)" vo_no_check_ran
yes_if "VERIFY_ONLY on a real host says what to do (unset it) and ends with a SUMMARY of one failure" bash -c "grep -q 'Unset it' '$work/vo.txt' && grep -qx 'SUMMARY pass=0 fail=1 warn=0 skip=0' '$work/vo.txt'"
VO_RC=0
env -u VERIFY_CONTAINER VERIFY_ONLY=NET-03 bash "$infra/verify.sh" >"$work/vo.txt" 2>&1 || VO_RC=$?
yes_if "VERIFY_ONLY with VERIFY_CONTAINER not set at all is refused too" vo_has '^FAIL CFG-02 '
# (b) every named check must exist
vo_run VERIFY_ONLY=NET03
yes_if "a mistyped check id (NET03) fails: FAIL CFG-03, naming it" vo_has "^FAIL CFG-03 .*NET03"
yes_if "a mistyped check id is a non-zero exit with a CFG failure" vo_refused
yes_if "a mistyped check id runs nothing (no PASS, SKIP or WARN, one FAIL)" vo_no_check_ran
vo_run "VERIFY_ONLY=NET-03 NOPE-01"
yes_if "one unknown id among good ones fails, naming the unknown one" vo_has "^FAIL CFG-03 .*NOPE-01"
yes_if "... and the good one does not run either (a typo cannot be hidden by the others)" vo_no_check_ran
# (c) a selection that selects nothing
vo_run "VERIFY_ONLY= "
yes_if "a selection with no id at all (spaces only) fails: FAIL CFG-03, names no check" vo_has '^FAIL CFG-03 VERIFY_ONLY names no check'
yes_if "... and is a non-zero exit with a CFG failure" vo_refused
vo_run "VERIFY_ONLY="
yes_if "an empty VERIFY_ONLY (set, but empty) is also a selection of nothing, and fails" vo_has '^FAIL CFG-03 VERIFY_ONLY names no check'
# (d) a subset says so
vo_run "VERIFY_ONLY=NGX-01 NET-03"
yes_if "a subset run prints a NOTE that only those checks ran (in the verifier's own order)" vo_has '^NOTE only ran: NET-03,NGX-01 '
yes_if "a subset run puts only=<ids> on the SUMMARY line" vo_has '^SUMMARY pass=[0-9]+ fail=[0-9]+ warn=[0-9]+ skip=[0-9]+ only=NET-03,NGX-01$'
yes_if "a subset run really ran just the two checks (two result lines)" bash -c "[[ \$(grep -cE '^(PASS|FAIL|WARN|SKIP) ' '$work/vo.txt') -eq 2 ]]"
vo_run VERIFY_ONLY=CTR-04
yes_if "one id works too: only=CTR-04" vo_has '^SUMMARY .* only=CTR-04$'
# a normal run is a full one: no NOTE, no only=
vo_run VERIFY_CONTAINER=1
yes_if "a normal (full) run has no 'only=' on its SUMMARY line (and so cannot be mistaken for a subset)" bash -c "grep -q '^SUMMARY ' '$work/vo.txt' && ! grep -q 'only=' '$work/vo.txt' && ! grep -q 'NOTE only ran' '$work/vo.txt'"
yes_if "a normal (full) run runs every check (34 checks, one result line each or more)" bash -c "[[ \$(grep -cE '^(PASS|FAIL|WARN|SKIP) ' '$work/vo.txt') -ge 34 ]]"

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
gen_case "--pull never replaced by --pull always" web "--pull never" "--pull always" "--pull is 'always'"
gen_case "--pull never replaced by --pull=missing" web "--pull never" "--pull=missing" "--pull is 'missing'"
gen_case "--pull never removed" web " --pull never" "" "lacks: --pull"

# Task 4b: a switch with a value, and the tmpfs options
yes_if "the real generated web command has no problem (positive control)" test -z "$(gen_problems web "$web_line")"
gen_case "--read-only=false" web " --read-only" " --read-only=false" "--read-only is 'false'"
gen_case "--read-only=0" web " --read-only" " --read-only=0" "--read-only is '0'"
gen_case "--rm=false" web " --rm" " --rm=false" "--rm is 'false'"
gen_case "--replace=false" web " --replace" " --replace=false" "--replace is 'false'"
gen_case "-d=false" web " -d" " -d=false" "-d is 'false'"
yes_if "--read-only=true is accepted (positive control: the switch value is read, not refused)" test -z "$(gen_problems web "${web_line/ --read-only/ --read-only=true}")"
gen_case "a tmpfs with exec" web "noexec,nosuid" "noexec,exec,nosuid" "has the option 'exec'"
gen_case "a tmpfs that is only exec (--tmpfs /tmp:rw,exec)" web "/tmp:rw,noexec,nosuid,size=64m" "/tmp:rw,exec,size=64m" "has the option 'exec'"
gen_case "a tmpfs with suid" web "noexec,nosuid" "noexec,suid" "has the option 'suid'"
gen_case "a tmpfs with dev" web "noexec,nosuid" "noexec,nosuid,dev" "has the option 'dev'"
gen_case "a tmpfs that is not /tmp" web "--tmpfs /tmp:" "--tmpfs /var/lib/oc:" "is not for /tmp"

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
# Cloudflare's Origin CA calls itself "CloudFlare Origin SSL Certificate Authority"; a copy of its root is not
# kept in this repository, so TLS-01 recognises the Origin CA by that name and the test CA takes it.
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 \
  -subj "/C=US/O=CloudFlare, Inc./OU=CloudFlare Origin SSL Certificate Authority/L=San Francisco/ST=California" \
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
yes_if "TLS-01 says its issuer is named as Cloudflare's Origin CA, and that only the name was checked" grep -q "^PASS TLS-01 .*issuer is named as Cloudflare's Origin CA.*the chain was NOT verified" "$work/verify-owncert.txt"
# A certificate from a CA that is neither Cloudflare's nor trusted would be answered with error 526 by Cloudflare.
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 -subj "/CN=Test Origin CA" \
  -keyout "$own/other-ca.key" -out "$own/other-ca.pem" >/dev/null 2>&1
openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj "/CN=example.test" \
  -keyout "$own/other.key" -out "$own/other.csr" >/dev/null 2>&1
openssl x509 -req -in "$own/other.csr" -CA "$own/other-ca.pem" -CAkey "$own/other-ca.key" -CAcreateserial -days 30 \
  -out "$own/other.crt" >/dev/null 2>&1
install -m 0644 -o root -g root "$own/other.crt" /etc/ssl/oc/origin.pem
install -m 0600 -o root -g root "$own/other.key" /etc/ssl/oc/origin.key
VERIFY_ONLY=TLS-01 bash "$infra/verify.sh" >"$work/verify-othercert.txt" 2>&1 || true
yes_if "TLS-01 FAILs for a certificate from a private CA (neither Cloudflare's Origin CA nor publicly trusted)" grep -q "^FAIL TLS-01 the origin certificate's issuer (CN = Test Origin CA) is neither named exactly as Cloudflare's Origin CA" "$work/verify-othercert.txt"
# the same certificate once the system trusts its CA: the chain verifies, so it is publicly trusted as far as this machine can tell
cp "$own/other-ca.pem" /usr/local/share/ca-certificates/oc-test-ca.crt
update-ca-certificates >/dev/null 2>&1
VERIFY_ONLY=TLS-01 bash "$infra/verify.sh" >"$work/verify-trustedcert.txt" 2>&1 || true
rm -f /usr/local/share/ca-certificates/oc-test-ca.crt
update-ca-certificates --fresh >/dev/null 2>&1
yes_if "TLS-01 passes when the CA is in the system's trust store (positive control: the chain is really verified)" grep -q '^PASS TLS-01 .*issued by a publicly trusted CA' "$work/verify-trustedcert.txt"
VERIFY_ONLY=TLS-01 bash "$infra/verify.sh" >"$work/verify-othercert2.txt" 2>&1 || true
yes_if "and it FAILs again once that CA is out of the trust store" grep -q '^FAIL TLS-01 .*neither named exactly as Cloudflare' "$work/verify-othercert2.txt"
# Cloudflare's Origin CA is recognised by its name, matched exactly field by field: a lookalike must fail and say why
# --- TLS-01: the issuer must be named EXACTLY as Cloudflare's Origin CA (or the chain must be public) ---------
own=${own:-$work/owncert}
mkdir -p "$own/issuer"
ou_rsa="CloudFlare Origin SSL Certificate Authority"
ou_ecc="CloudFlare Origin SSL ECC Certificate Authority"
# tls_issuer_case SUBJECT: a CA with that subject signs a leaf, the leaf is installed, TLS-01 runs; prints its line
tls_issuer_case() {
  local d=$own/issuer
  rm -f "$d"/*
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 -subj "$1" -keyout "$d/ca.key" -out "$d/ca.pem" >/dev/null 2>&1 || { echo "TEST BUG: no CA for $1"; return 0; }
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj "/CN=example.test" -keyout "$d/leaf.key" -out "$d/leaf.csr" >/dev/null 2>&1
  openssl x509 -req -in "$d/leaf.csr" -CA "$d/ca.pem" -CAkey "$d/ca.key" -CAcreateserial -days 30 -out "$d/leaf.crt" >/dev/null 2>&1
  install -m 0644 -o root -g root "$d/leaf.crt" /etc/ssl/oc/origin.pem
  install -m 0600 -o root -g root "$d/leaf.key" /etc/ssl/oc/origin.key
  VERIFY_ONLY=TLS-01 bash "$infra/verify.sh" 2>&1 | grep '^[A-Z]* TLS-01 ' || true
}
tls_must_fail() { # DESCRIPTION SUBJECT REASON-TEXT
  local out
  out=$(tls_issuer_case "$2")
  if [[ $out == "FAIL TLS-01 "* && $out == *"is neither named exactly as Cloudflare's Origin CA"* && $out == *"$3"* ]]; then
    ok "TLS-01 FAILs for $1 (because: $3)"
  else
    notok "TLS-01 should fail for $1 (because: $3); it said: ${out:0:350}"
  fi
}
tls_must_pass() { # DESCRIPTION SUBJECT OU
  local out
  out=$(tls_issuer_case "$2")
  if [[ $out == "PASS TLS-01 "* && $out == *"issuer is named as Cloudflare's Origin CA ('$3'"* && $out == *"the chain was NOT verified"* && $out != *"publicly trusted"* ]]; then
    ok "TLS-01 passes for $1, and says that only the name was checked and the chain was NOT verified"
  else
    notok "TLS-01 should pass for $1 as a name match only; it said: ${out:0:350}"
  fi
}
# positive controls: both exact names, with and without the other attributes Cloudflare's certificate carries
tls_must_pass "the RSA Origin CA's name (O, OU, C, L, ST)" "/C=US/O=CloudFlare, Inc./OU=$ou_rsa/L=San Francisco/ST=California" "$ou_rsa"
tls_must_pass "the ECC Origin CA's name (O, OU, C, L, ST)" "/C=US/O=CloudFlare, Inc./OU=$ou_ecc/L=San Francisco/ST=California" "$ou_ecc"
tls_must_pass "the RSA name with only O and OU" "/O=CloudFlare, Inc./OU=$ou_rsa" "$ou_rsa"
tls_must_pass "the ECC name with only O and OU" "/O=CloudFlare, Inc./OU=$ou_ecc" "$ou_ecc"
# a lookalike must fail, and say why
tls_must_fail "an O that merely contains the text (O=not cloudflare origin)" "/O=not cloudflare origin" "O is 'not cloudflare origin'"
tls_must_fail "an O that contains the text with an OU that is not Cloudflare's" "/O=not cloudflare origin/OU=x" "O is 'not cloudflare origin'"
tls_must_fail "the right OU under the wrong O" "/O=Evil Inc./OU=$ou_rsa" "O is 'Evil Inc.'"
tls_must_fail "the right O with the wrong OU" "/O=CloudFlare, Inc./OU=Something Else" "OU is 'Something Else'"
tls_must_fail "the right O with no OU at all" "/O=CloudFlare, Inc." "no OU"
tls_must_fail "an RSA OU with a suffix" "/O=CloudFlare, Inc./OU=$ou_rsa X" "OU is '$ou_rsa X'"
tls_must_fail "an RSA OU with a prefix" "/O=CloudFlare, Inc./OU=X $ou_rsa" "OU is 'X $ou_rsa'"
tls_must_fail "an ECC OU with a suffix" "/O=CloudFlare, Inc./OU=$ou_ecc X" "OU is '$ou_ecc X'"
tls_must_fail "an ECC OU with a prefix" "/O=CloudFlare, Inc./OU=X $ou_ecc" "OU is 'X $ou_ecc'"
tls_must_fail "an OU with a trailing space" "/O=CloudFlare, Inc./OU=$ou_rsa " "OU is '$ou_rsa '"
tls_must_fail "the OU in upper case" "/O=CloudFlare, Inc./OU=${ou_rsa^^}" "OU is '${ou_rsa^^}'"
tls_must_fail "the OU in lower case" "/O=CloudFlare, Inc./OU=${ou_ecc,,}" "OU is '${ou_ecc,,}'"
tls_must_fail "the O in lower case" "/O=cloudflare, inc./OU=$ou_rsa" "O is 'cloudflare, inc.'"
tls_must_fail "the O in upper case" "/O=CLOUDFLARE, INC./OU=$ou_ecc" "O is 'CLOUDFLARE, INC.'"
tls_must_fail "the right O and OU plus a CN (an extra attribute could carry the text)" "/O=CloudFlare, Inc./OU=$ou_rsa/CN=x" "has a CN attribute"
tls_must_fail "the name smuggled into a CN only" "/O=Evil/OU=Evil/CN=$ou_rsa" "has a CN attribute"
tls_must_fail "a second OU" "/O=CloudFlare, Inc./OU=$ou_rsa/OU=extra" "2 OU attributes"
tls_must_fail "a second O" "/O=CloudFlare, Inc./O=Evil/OU=$ou_rsa" "2 O attributes"
tls_must_fail "the name only in the subject of the leaf's CA as a domain component" "/DC=cloudflare/O=CloudFlare, Inc./OU=$ou_rsa" "has a DC attribute"
install -m 0644 -o root -g root "$own/leaf.crt" /etc/ssl/oc/origin.pem
install -m 0600 -o root -g root "$own/leaf.key" /etc/ssl/oc/origin.key
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

# --- the deploy account over a real SSH connection: one key per environment ---------------------
dkeyp=$work/keys/deploy-prod
dkeyst=$work/keys/deploy-staging
dsha=1111111111111111111111111111111111111111
did=sha256:$(printf 'a%.0s' $(seq 64))
dgood="$dsha $did $did" # what CI sends: no environment in it (the key fixes that)
dsshp=("${sshc[@]}" -o IdentitiesOnly=yes -i "$dkeyp")
dsshs=("${sshc[@]}" -o IdentitiesOnly=yes -i "$dkeyst")
# dssh_prod ARGS... and dssh_staging ARGS...: ssh as the deploy account with that environment's key, no
# input (a test that sends a file redirects it itself)
# shellcheck disable=SC2317  # both are called through refused_over_ssh, by name
dssh_prod() { "${dsshp[@]}" oc-deploy@127.0.0.1 "$@" </dev/null; }
# shellcheck disable=SC2317
dssh_staging() { "${dsshs[@]}" oc-deploy@127.0.0.1 "$@" </dev/null; }
# refused_over_ssh DESCRIPTION KEY-ENV COMMAND: the forced command refuses (exit 2, "the command must be
# exactly") and the root script is never reached (no "deploying" in the output)
refused_over_ssh() {
  local desc=$1 keyenv=$2 cmd=$3 rc=0 out
  out=$("dssh_$keyenv" "$cmd" 2>&1) || rc=$?
  if [[ $rc -eq 2 && $out == *"the command must be exactly"* && $out != *"deploying"* && $out != *"uid="* ]]; then
    ok "$desc (exit 2, refused by the forced command, the root script never ran)"
  else
    notok "$desc: exit $rc: ${out:0:250}"
  fi
}
refused_over_ssh "the prod key signs in, and asking for 'id' runs the forced command instead" prod "id"
refused_over_ssh "the staging key signs in, and asking for 'id' runs the forced command instead" staging "id"
refused_over_ssh "a 39-character commit over the prod key is refused" prod "${dsha:0:39} $did $did"
# The review finding: one key must never reach both environments.
refused_over_ssh "THE STAGING KEY CANNOT DEPLOY PRODUCTION: asking for 'prod <values>' with the staging key is refused" staging "prod $dgood"
refused_over_ssh "the prod key cannot deploy staging: asking for 'staging <values>' with the prod key is refused" prod "staging $dgood"
refused_over_ssh "a client that names its own environment is refused even when it is the key's (prod key, 'prod <values>')" prod "prod $dgood"
refused_over_ssh "a client that names its own environment is refused even when it is the key's (staging key, 'staging <values>')" staging "staging $dgood"
refused_over_ssh "two words instead of three are refused" prod "$dsha $did"
refused_over_ssh "four words after the three are refused" prod "$dgood extra"
rc=0
out=$("${dsshp[@]}" -T oc-deploy@127.0.0.1 </dev/null 2>&1) || rc=$?
if [[ $rc -eq 2 && $out == *"no command given"* ]]; then ok "signing in with no command (a login shell) runs the forced command, which refuses (exit 2)"; else notok "no command: exit $rc: ${out:0:200}"; fi
rc=0
out=$("${dsshp[@]}" -tt oc-deploy@127.0.0.1 id </dev/null 2>&1) || rc=$?
if [[ $out == *"PTY allocation request failed"* && $out != *"uid="* ]]; then ok "a terminal (ssh -tt) is refused for the prod key"; else notok "ssh -tt for the prod key: exit $rc: ${out:0:200}"; fi
rc=0
out=$("${dsshs[@]}" -tt oc-deploy@127.0.0.1 id </dev/null 2>&1) || rc=$?
if [[ $out == *"PTY allocation request failed"* && $out != *"uid="* ]]; then ok "a terminal (ssh -tt) is refused for the staging key"; else notok "ssh -tt for the staging key: exit $rc: ${out:0:200}"; fi
expect_fail "TCP forwarding is refused for the prod key (ssh -L)" "${dsshp[@]}" -o ExitOnForwardFailure=yes -L 15433:127.0.0.1:3306 oc-deploy@127.0.0.1 id
expect_fail "TCP forwarding is refused for the staging key (ssh -L)" "${dsshs[@]}" -o ExitOnForwardFailure=yes -L 15434:127.0.0.1:3306 oc-deploy@127.0.0.1 id
expect_fail "scp to the deploy account is refused (the forced command is not scp)" scp -P 2222 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o IdentitiesOnly=yes -i "$dkeyp" /etc/hostname oc-deploy@127.0.0.1:/tmp/hostname-x
expect_fail "sftp to the deploy account is refused (a subsystem is forced too)" bash -c "printf 'ls\n' | sftp -P 2222 -b - -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o IdentitiesOnly=yes -i '$dkeyp' oc-deploy@127.0.0.1"
expect_fail "an admin's key cannot sign in as the deploy account" "${sshc[@]}" -o IdentitiesOnly=yes -i "$work/keys/alice" oc-deploy@127.0.0.1 id
expect_fail "the prod deploy key cannot sign in as an admin" "${sshc[@]}" -o IdentitiesOnly=yes -i "$dkeyp" alice@127.0.0.1 id
expect_fail "the staging deploy key cannot sign in as an admin" "${sshc[@]}" -o IdentitiesOnly=yes -i "$dkeyst" alice@127.0.0.1 id
expect_fail "the prod deploy key cannot sign in as root" "${sshc[@]}" -o IdentitiesOnly=yes -i "$dkeyp" root@127.0.0.1 id
expect_fail "the staging deploy key cannot sign in as root" "${sshc[@]}" -o IdentitiesOnly=yes -i "$dkeyst" root@127.0.0.1 id
rc=0
out=$("${sshc[@]}" -i "$work/keys/alice" -tt alice@127.0.0.1 tty </dev/null 2>&1) || rc=$?
if [[ $out == *"/dev/pts/"* ]]; then ok "an admin still gets a terminal (the deploy account's Match block did not leak to admins)"; else notok "admin terminal: exit $rc: ${out:0:200}"; fi

# The whole chain, once per key: SSH, forced command (which fixes the environment), spool, sudo, root
# script, Podman as the environment's user. Podman cannot run inside this container, so the root script
# stops at its first Podman call; what is proved is everything before it, with the real sudo, runuser and
# file permissions, and WHICH environment each key reaches.
qstg_web=/home/oc-staging/.config/containers/systemd/oc-web-staging.container
qstg_cms=/home/oc-staging/.config/containers/systemd/oc-cms-staging.container
qsum_before=$(sha256sum "$qweb" "$qcms" "$qstg_web" "$qstg_cms" | sha256sum)
printf 'not an image' | gzip -c >"$work/e2e.tgz"
rc=0
out=$("${dsshp[@]}" oc-deploy@127.0.0.1 "$dgood" <"$work/e2e.tgz" 2>&1) || rc=$?
if [[ $out == *"received"* && $out == *"deploying $dsha to prod"* && $out != *"to staging"* ]]; then
  ok "end to end, the prod key: the forced command spooled the tarball and the root script ran through sudo FOR PROD (output: ${out//$'\n'/ | })"
else
  notok "end to end, the prod key: the chain did not reach the root script for prod (exit $rc): ${out:0:300}"
fi
yes_if "end to end, the prod key: it stopped after the checks, before changing anything (exit 1 or 6, not 2 or 5)" test "$rc" -eq 1 -o "$rc" -eq 6
rc=0
out=$("${dsshs[@]}" oc-deploy@127.0.0.1 "$dgood" <"$work/e2e.tgz" 2>&1) || rc=$?
if [[ $out == *"received"* && $out == *"deploying $dsha to staging"* && $out != *"to prod"* ]]; then
  ok "end to end, the staging key: the same command reaches the root script FOR STAGING, never prod (output: ${out//$'\n'/ | })"
else
  notok "end to end, the staging key: the chain did not reach the root script for staging (exit $rc): ${out:0:300}"
fi
yes_if "end to end, the staging key: it stopped after the checks, before changing anything (exit 1 or 6, not 2 or 5)" test "$rc" -eq 1 -o "$rc" -eq 6
yes_if "end to end: every environment's Quadlet files are unchanged" test "$(sha256sum "$qweb" "$qcms" "$qstg_web" "$qstg_cms" | sha256sum)" = "$qsum_before"
yes_if "end to end: the spool folder is empty again afterwards" bash -c "[[ -z \$(find /var/lib/oc-deploy/spool -mindepth 1 ! -name .lock) ]]"
yes_if "end to end: sudo's own log records the prod command and the staging command, each run as root by the deploy user" bash -c "tr '\n' ' ' </var/log/sudo.log | tr -s ' ' | grep -q 'oc-deploy : .*USER=root ; COMMAND=/usr/local/lib/oc/deploy/apply-release.sh prod $dsha ' && tr '\n' ' ' </var/log/sudo.log | tr -s ' ' | grep -q 'oc-deploy : .*USER=root ; COMMAND=/usr/local/lib/oc/deploy/apply-release.sh staging $dsha '"
# sudo itself, called by the deploy user directly
expect_fail_because "sudo refuses anything but the one script: a root shell" "a password is required" runuser -u oc-deploy -- sudo -n -i true
expect_fail_because "sudo refuses the script with arguments of another shape (bad environment)" "a password is required" runuser -u oc-deploy -- sudo -n /usr/local/lib/oc/deploy/apply-release.sh dev "$dsha" "$did" "$did"
expect_fail_because "sudo refuses the script with arguments of another shape (a fifth argument)" "a password is required" runuser -u oc-deploy -- sudo -n /usr/local/lib/oc/deploy/apply-release.sh prod "$dsha" "$did" "$did" --force
expect_fail_because "sudo refuses the script with arguments of another shape (a short commit)" "a password is required" runuser -u oc-deploy -- sudo -n /usr/local/lib/oc/deploy/apply-release.sh prod "${dsha:0:39}" "$did" "$did"
expect_fail_because "sudo refuses the script with a wildcard-style argument" "a password is required" runuser -u oc-deploy -- sudo -n /usr/local/lib/oc/deploy/apply-release.sh '*'
expect_fail_because "sudo refuses another program, even with a good argument list" "a password is required" runuser -u oc-deploy -- sudo -n /usr/bin/id prod "$dsha" "$did" "$did"
expect_fail_because "sudo refuses to pass environment variables on the command line" "not allowed to set the following environment variables" runuser -u oc-deploy -- sudo -n OC_ROOT=/tmp/evil /usr/local/lib/oc/deploy/apply-release.sh prod "$dsha" "$did" "$did"
expect_fail_because "the exact shape gets through sudo; the root script then refuses for want of a spool file (exit 5)" "the spool file is missing" runuser -u oc-deploy -- sudo -n /usr/local/lib/oc/deploy/apply-release.sh prod "$dsha" "$did" "$did"
printf '#!/bin/sh\ntouch /tmp/EVIL-RAN\n' >/tmp/evil-podman && chmod 0755 /tmp/evil-podman
rm -f /tmp/EVIL-RAN
expect_fail_because "test overrides in the caller's environment do not reach the root script (env_reset), which still looks for its real spool" "the spool file is missing" \
  runuser -u oc-deploy -- env OC_ROOT=/tmp/evil OC_PODMAN=/tmp/evil-podman OC_RUNUSER=/tmp/evil-podman SUDO_USER= sudo -n /usr/local/lib/oc/deploy/apply-release.sh prod "$dsha" "$did" "$did"
yes_if "and the program named in OC_PODMAN was never run" test ! -e /tmp/EVIL-RAN
rm -f /tmp/evil-podman
kill "$sshd_pid" 2>/dev/null || true
rm -f /root/.ssh/authorized_keys

# --------------------------------------------------------------------------------------
section "Nginx really behaves as configured"
bash "$infra/test/nginx-behaviour.sh" "$work" || FAILED=$((FAILED + 1))

# --------------------------------------------------------------------------------------
section "the deploy scripts' unit tests (fakes for podman, systemctl, curl and runuser)"
rc=0
bash "$infra/deploy/deploy-release.test.sh" >"$work/deploy-unit.txt" 2>&1 || rc=$?
tail -n 3 "$work/deploy-unit.txt"
yes_if "deploy-release.test.sh passes inside the test container" test "$rc" -eq 0
yes_if "and it ran a few hundred checks" bash -c "[[ \$(grep -c '^ok ' '$work/deploy-unit.txt') -gt 200 ]]"

# --------------------------------------------------------------------------------------
section "ssh_assert_effective asks for every user, and refuses a Match block that is not ours (bootstrap level)"
# The bootstrap checks the live rules before it reloads sshd. A change it does not expect must stop it, with
# the drop-in left exactly as it was.
cp -p "$ddrop" "$work/dropin.before"
printf 'PasswordAuthentication yes\n' >/etc/ssh/sshd_config.d/00-aaa.conf
expect_fail_because "bootstrap stops when an earlier drop-in turns passwords back on" "sshd would use 'passwordauthentication yes' instead of 'passwordauthentication no'" bash "$infra/bootstrap.sh"
rm -f /etc/ssh/sshd_config.d/00-aaa.conf
yes_if "that refusal left the drop-in as it was" cmp -s "$ddrop" "$work/dropin.before"
printf 'Match Address 198.51.100.0/24\n    PasswordAuthentication yes\n' >/etc/ssh/sshd_config.d/10-zz.conf
expect_fail_because "bootstrap stops when another Match block (for an address nobody asked about) exists" "has a Match or Include line that this setup did not write" bash "$infra/bootstrap.sh"
rm -f /etc/ssh/sshd_config.d/10-zz.conf
yes_if "that refusal left the drop-in as it was" cmp -s "$ddrop" "$work/dropin.before"
# The per-user questions, tried with a sshd whose answer differs for the deploy user only: a shell
# function stands in for sshd, so the bootstrap's own function is the thing under test.
# shellcheck disable=SC2317,SC2016  # called through expect; the bash -c program is single-quoted on purpose
assert_with_fake_sshd() { # SED-EXPRESSION applied to the deploy user's answer
  bash -c '
    source "$1/lib/common.sh"; source "$1/lib/ssh.sh"
    oc_load_config "$OC_CONFIG"; oc_validate_config
    expr=$2
    sshd() { # the real sshd, except that the answer for the deploy account is edited
      if [[ $* == *"user=oc-deploy"* ]]; then /usr/sbin/sshd "$@" | sed -E "$expr"; else /usr/sbin/sshd "$@"; fi
    }
    ssh_assert_effective
  ' _ "$infra" "$1"
}
expect "the bootstrap's own check passes on the real answers (positive control)" assert_with_fake_sshd 's/^$//'
expect_fail_because "ssh_assert_effective notices that passwords are on for the deploy user only" "for oc-deploy" assert_with_fake_sshd 's/^passwordauthentication no$/passwordauthentication yes/'
expect_fail_because "ssh_assert_effective notices root login for the deploy user only" "for oc-deploy" assert_with_fake_sshd 's/^permitrootlogin no$/permitrootlogin yes/'
expect_fail_because "ssh_assert_effective notices a terminal for the deploy user (its Match block did not apply)" "the Match block did not take effect" assert_with_fake_sshd 's/^permittty no$/permittty yes/'
expect_fail_because "ssh_assert_effective notices another forced command for the deploy user" "the Match block did not take effect" assert_with_fake_sshd 's|^forcecommand .*|forcecommand /bin/sh|'
expect_fail_because "ssh_assert_effective notices an AuthorizedKeysCommand for the deploy user" "another way to sign in as oc-deploy" assert_with_fake_sshd 's|^authorizedkeyscommand none$|authorizedkeyscommand /usr/local/bin/oc-keys|'
expect_fail_because "ssh_assert_effective notices an AuthorizedKeysCommandUser for the deploy user" "authorizedkeyscommanduser root" assert_with_fake_sshd 's|^authorizedkeyscommanduser none$|authorizedkeyscommanduser root|'
expect_fail_because "ssh_assert_effective notices a TrustedUserCAKeys for the deploy user" "trustedusercakeys /etc/ssh/ca.pub" assert_with_fake_sshd 's|^trustedusercakeys none$|trustedusercakeys /etc/ssh/ca.pub|'
expect_fail_because "ssh_assert_effective notices an AuthorizedPrincipalsFile for the deploy user" "authorizedprincipalsfile .ssh/principals" assert_with_fake_sshd 's|^authorizedprincipalsfile none$|authorizedprincipalsfile .ssh/principals|'
printf 'AuthorizedKeysCommand /usr/local/bin/oc-keys\nAuthorizedKeysCommandUser root\n' >/etc/ssh/sshd_config.d/00-aaa.conf
expect_fail_because "the bootstrap stops when an earlier drop-in gives the deploy user an AuthorizedKeysCommand (with the real sshd)" "another way to sign in as oc-deploy" bash "$infra/bootstrap.sh"
rm -f /etc/ssh/sshd_config.d/00-aaa.conf
# shellcheck disable=SC2016  # the bash -c program is single-quoted on purpose
expect_fail_because "ssh_assert_effective notices a deploy user who is not in AllowUsers" "sshd would allow" bash -c '
  source "$1/lib/common.sh"; source "$1/lib/ssh.sh"
  oc_load_config "$OC_CONFIG"; oc_validate_config
  sshd() { # the real sshd, except that the global answer lists no oc-deploy in AllowUsers
    if [[ $* == *"-C"* ]]; then /usr/sbin/sshd "$@"; else /usr/sbin/sshd "$@" | sed -E "s/^allowusers oc-deploy$//"; fi
  }
  ssh_assert_effective' _ "$infra"

# --------------------------------------------------------------------------------------
section "the deploy account switched off and on again: nothing is left behind, and nothing is lost"
cp -p "$work/server.env" "$work/server-off.env"
printf 'OC_DEPLOY_ENABLED=no\n' >>"$work/server-off.env"
rc=0
run_logged "$work/bootstrap-off.log" bash "$infra/bootstrap.sh" --config "$work/server-off.env" >/dev/null || rc=$?
yes_if "bootstrap with OC_DEPLOY_ENABLED=no exits 0" test "$rc" -eq 0
yes_if "the deploy user is gone" bash -c "! getent passwd oc-deploy && ! getent group oc-deploy"
yes_if "its key file, sudoers file, scripts and folders are gone" bash -c "[[ ! -e /etc/ssh/oc-deploy.authorized_keys && ! -e /etc/sudoers.d/92-oc-deploy && ! -e /usr/local/lib/oc/deploy && ! -e /var/lib/oc-deploy ]]"
yes_if "sshd no longer allows it and has no Match block" bash -c "! grep -q 'oc-deploy' /etc/ssh/sshd_config.d/00-oc-hardening.conf && ! grep -q '^Match' /etc/ssh/sshd_config.d/00-oc-hardening.conf"
yes_if "the admins are still allowed" grep -qx 'AllowUsers alice bob' /etc/ssh/sshd_config.d/00-oc-hardening.conf
yes_if "sudo still works for the admins' file and the sudo log rules" bash -c "visudo -c >/dev/null && [[ -f /etc/sudoers.d/90-oc-admins ]]"
rc=0
OC_CONFIG="$work/server-off.env" bash "$infra/verify.sh" >"$work/verify-off.txt" 2>&1 || rc=$?
yes_if "verify.sh exits 0 with the deploy account off" test "$rc" -eq 0
yes_if "DEP-01 and DEP-02 say it is switched off (and pass)" bash -c "grep -q '^PASS DEP-01 the deploy account is switched off' '$work/verify-off.txt' && grep -q '^PASS DEP-02 the deploy account is switched off' '$work/verify-off.txt'"
rc=0
run_logged "$work/bootstrap-off2.log" bash "$infra/bootstrap.sh" --config "$work/server-off.env" >/dev/null || rc=$?
yes_if "a second run with it off exits 0" test "$rc" -eq 0
yes_if "and changes nothing (changes=0)" grep -q 'DONE changes=0$' "$work/bootstrap-off2.log"
rc=0
run_logged "$work/bootstrap-on.log" bash "$infra/bootstrap.sh" >/dev/null || rc=$?
yes_if "bootstrap with the account on again exits 0" test "$rc" -eq 0
yes_if "the account is back with its key line and sudo rule" bash -c "getent passwd oc-deploy >/dev/null && [[ -f /etc/ssh/oc-deploy.authorized_keys && -f /etc/sudoers.d/92-oc-deploy ]]"
rc=0
bash "$infra/verify.sh" >"$work/verify-on.txt" 2>&1 || rc=$?
yes_if "verify.sh exits 0 again, with DEP-01 and DEP-02 passing" bash -c "[[ $rc -eq 0 ]] && grep -q '^PASS DEP-01 ' '$work/verify-on.txt' && grep -q '^PASS DEP-02 ' '$work/verify-on.txt'"
rc=0
run_logged "$work/bootstrap-on2.log" bash "$infra/bootstrap.sh" >/dev/null || rc=$?
yes_if "and another run changes nothing (changes=0)" bash -c "[[ $rc -eq 0 ]] && grep -q 'DONE changes=0\$' '$work/bootstrap-on2.log'"

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
