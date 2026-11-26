#!/usr/bin/env bash
# Tests for deploy-release.sh and apply-release.sh with fakes on a throwaway directory tree.
#
#   bash infra/deploy/deploy-release.test.sh
#
# No Podman, systemd, sudo or network is needed: apply-release.sh is pointed at a fake root
# (OC_ROOT) and fake podman, systemctl, curl and runuser programs (OC_PODMAN, OC_SYSTEMCTL,
# OC_CURL, OC_RUNUSER). The fakes keep their state in plain files, so each test can look at
# exactly what the script did. Needs Linux tools: flock, gzip, GNU stat/sed/awk.
# good_tarball and run_good take optional arguments; most calls use the defaults.
# shellcheck disable=SC2119,SC2120
set -uo pipefail
export LC_ALL=C

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
DEPLOY=$HERE/deploy-release.sh
APPLY=$HERE/apply-release.sh
TEMPLATES=$(cd -- "$HERE/../quadlet" && pwd -P)
COMMON=$(cd -- "$HERE/../lib" && pwd -P)/common.sh

PASS=0
FAIL=0
ok() {
  PASS=$((PASS + 1))
  printf 'ok     - %s\n' "$*"
}
notok() {
  FAIL=$((FAIL + 1))
  printf 'NOT OK - %s\n' "$*"
}
# check DESCRIPTION CMD...: ok when the command succeeds.
check() {
  local desc=$1
  shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else notok "$desc"; fi
}
section() { printf '\n## %s\n' "$*"; }

# hold_lock FILE: another process takes the exclusive flock on FILE and keeps it until
# release_lock. (The lock holder is the sleep itself, so killing it frees the lock.)
HOLDER=""
hold_lock() {
  (
    exec 8>>"$1"
    flock 8
    exec sleep 30
  ) &
  HOLDER=$!
  local _
  for _ in $(seq 1 100); do
    flock -n "$1" true 2>/dev/null || break
    sleep 0.05
  done
}
release_lock() {
  kill "$HOLDER" 2>/dev/null
  wait "$HOLDER" 2>/dev/null
  return 0
}

W=$(mktemp -d -t oc-deploy-test.XXXXXX)
trap 'rm -rf -- "$W"' EXIT
OWNER=$(id -un)

# --- ids ------------------------------------------------------------------------------
SHA_NEW=1111111111111111111111111111111111111111
SHA_OLD=2222222222222222222222222222222222222222
hex64() { printf '%064x' "$1"; }
id_of() { printf 'sha256:%s' "$(hex64 "$1")"; }
CMS_ID=$(id_of 101)
WEB_ID=$(id_of 102)

# --- the fakes --------------------------------------------------------------------------
make_fakes() { # DIR
  local d=$1
  mkdir -p "$d"
  cat >"$d/podman" <<'EOF'
#!/usr/bin/env bash
# Fake podman. State: ../state/images/<name with / and : as _> holding "name id created".
# (The fakes find their state from their own location: apply-release.sh starts them with
# an empty environment, like the real one does for Podman.)
set -u
S=$(cd -- "$(dirname -- "$0")/../state" && pwd -P)
printf 'podman %s\n' "$*" >>"$S/calls.log"
key() { local k=${1//\//_}; printf '%s' "${k//:/_}"; }
case ${1:-} in
  load)
    content=$(cat)
    case $content in *CORRUPT*) echo "Error: payload does not match any of the supported image formats" >&2; exit 125 ;; esac
    while read -r kw name id created; do
      [[ $kw == image ]] || continue
      [[ $name == */* ]] || name="localhost/$name"
      # A name that moves to another image leaves the old image behind, untagged, as podman does.
      if [[ -f $S/images/$(key "$name") ]]; then
        read -r _ oldid _ <"$S/images/$(key "$name")"
        mkdir -p "$S/orphans"
        cp -- "$S/images/$(key "$name")" "$S/orphans/$oldid"
      fi
      printf '%s %s %s\n' "$name" "$id" "$created" >"$S/images/$(key "$name")"
      printf 'Loaded image: %s\n' "$name"
    done <<<"$content"
    ;;
  image)
    case ${2:-} in
      ls)
        [[ ${3:-} == --format && ${4:-} == '{{.Id}}|{{.CreatedAt}}|{{.Repository}}:{{.Tag}}' ]] || { echo "fake podman: unexpected image ls arguments: $*" >&2; exit 99; }
        for f in "$S"/images/*; do
          [[ -f $f ]] || continue
          read -r name id created <"$f"
          [[ -f $S/bare-ids ]] && id=${id#sha256:}
          # Real podman 4.9.3 prints {{.CreatedAt}} like "2026-03-23 21:33:59 +0000 UTC" and
          # {{.Created}} like "8 months ago"; the fakes are seeded with unix seconds.
          printf '%s|%s|%s\n' "$id" "$(date -u -d "@$created" '+%Y-%m-%d %H:%M:%S +0000 UTC')" "$name"
        done
        ;;
      inspect)
        [[ ${3:-} == --format && ${4:-} == '{{.Id}}' ]] || { echo "fake podman: unexpected image inspect arguments: $*" >&2; exit 99; }
        f=$S/images/$(key "${5:-}")
        [[ -f $f ]] || { echo "Error: ${5:-}: image not known" >&2; exit 125; }
        read -r _ id _ <"$f"
        [[ -f $S/bare-ids ]] && id=${id#sha256:}
        printf '%s\n' "$id"
        ;;
      exists)
        [[ -f $S/images/$(key "${3:-}") ]]
        ;;
      *) echo "fake podman: unexpected: $*" >&2; exit 99 ;;
    esac
    ;;
  rmi)
    [[ ${2:-} == -- ]] || { echo "fake podman: rmi without --: $*" >&2; exit 99; }
    f=$S/images/$(key "${3:-}")
    [[ -f $f ]] || { echo "Error: ${3:-}: image not known" >&2; exit 1; }
    rm -f -- "$f"
    ;;
  tag)
    # podman tag SOURCE-ID DEST: give DEST the image with that id.
    [[ ${2:-} == -- ]] || { echo "fake podman: tag without --: $*" >&2; exit 99; }
    found=""
    foundid=""
    for f in "$S"/images/* "$S"/orphans/*; do
      [[ -f $f ]] || continue
      read -r name id created <"$f"
      if [[ ${id#sha256:} == "${3#sha256:}" ]]; then
        found="$created"
        foundid="$id"
      fi
    done
    # (An image whose only name was taken away is kept by id, like podman keeps it untagged.)
    [[ -n $found ]] || exit 1
    printf '%s %s %s\n' "${4:-}" "$foundid" "$found" >"$S/images/$(key "${4:-}")"
    ;;
  *) echo "fake podman: unexpected: $*" >&2; exit 99 ;;
esac
EOF
  cat >"$d/systemctl" <<'EOF'
#!/usr/bin/env bash
# Fake systemctl. Logs every call; "restart" records which Image= lines the files had then.
set -u
S=$(cd -- "$(dirname -- "$0")/../state" && pwd -P)
R=$(cd -- "$(dirname -- "$0")/../root" && pwd -P)
printf 'systemctl %s\n' "$*" >>"$S/calls.log"
printf '%s\n' "$*" >>"$S/systemctl.log"
[[ ${1:-} == --user ]] || { echo "fake systemctl: expected --user first: $*" >&2; exit 99; }
shift
case ${1:-} in
  restart)
    cms=$(sed -n 's/^Image=//p' "$R/home/oc-$(cat "$S/env-name")/.config/containers/systemd/oc-cms-$(cat "$S/env-name").container")
    web=$(sed -n 's/^Image=//p' "$R/home/oc-$(cat "$S/env-name")/.config/containers/systemd/oc-web-$(cat "$S/env-name").container")
    printf 'restart cms=%s web=%s\n' "$cms" "$web" >>"$S/restarts.log"
    if [[ -f $S/restart-fails-for ]] && [[ $cms == *"$(cat "$S/restart-fails-for")" ]]; then
      echo "Job for oc-cms.service failed" >&2
      exit 1
    fi
    ;;
  daemon-reload | stop | is-active) ;;
  *) echo "fake systemctl: unexpected: $*" >&2; exit 99 ;;
esac
EOF
  cat >"$d/curl" <<'EOF'
#!/usr/bin/env bash
# Fake curl: a service is healthy when its Quadlet file does not point at the bad tag.
set -u
S=$(cd -- "$(dirname -- "$0")/../state" && pwd -P)
R=$(cd -- "$(dirname -- "$0")/../root" && pwd -P)
url=${*: -1}
printf 'curl %s\n' "$url" >>"$S/curl.log"
env=$(cat "$S/env-name")
case $url in
  http://127.0.0.1:1337/_health | http://127.0.0.1:1338/_health) app=cms ;;
  http://127.0.0.1:4321/healthz | http://127.0.0.1:4322/healthz) app=web ;;
  *) echo "fake curl: unexpected URL $url" >&2; exit 99 ;;
esac
tag=$(sed -n 's/^Image=[^:]*://p' "$R/home/oc-$env/.config/containers/systemd/oc-$app-$env.container")
[[ $tag == bootstrap ]] && exit 22
[[ -f $S/bad-tag && $tag == "$(cat "$S/bad-tag")" ]] && exit 22
exit 0
EOF
  cat >"$d/runuser" <<'EOF'
#!/usr/bin/env bash
# Fake runuser: runuser -u USER -- COMMAND... runs the command as the current user.
set -u
S=$(cd -- "$(dirname -- "$0")/../state" && pwd -P)
[[ ${1:-} == -u && ${3:-} == -- ]] || { echo "fake runuser: unexpected: $*" >&2; exit 99; }
printf '%s\n' "$2" >>"$S/runuser.log"
user=$2
shift 3
if [[ -f $S/fail-sed-web && " $* " == *" sed "* && $* == *oc-web-* ]]; then exit 1; fi
if [[ $1 == env ]]; then
  # The real call is: env HOME=... XDG_RUNTIME_DIR=... [DBUS_SESSION_BUS_ADDRESS=...] PROGRAM args
  printf 'env-call %s %s\n' "$user" "$*" >>"$S/runuser-env.log"
fi
exec "$@"
EOF
  cat >"$d/sudo" <<'EOF'
#!/usr/bin/env bash
# Fake sudo for deploy-release: sudo -n -- PROGRAM args
[[ ${1:-} == -n && ${2:-} == -- ]] || { echo "fake sudo: unexpected: $*" >&2; exit 99; }
shift 2
exec "$@"
EOF
  cat >"$d/apply" <<'EOF'
#!/usr/bin/env bash
# Fake apply-release.sh for deploy-release: records its arguments and the spooled file.
S=$(cd -- "$(dirname -- "$0")/../state" && pwd -P)
R=$(cd -- "$(dirname -- "$0")/../root" && pwd -P)
printf '%s\n' "$*" >>"$S/apply.args"
spool=$R/var/lib/oc-deploy/spool/incoming.tar.gz
if [[ -f $spool ]]; then cp -- "$spool" "$S/apply.saw-spool"; fi
exit "$(cat "$S/apply-rc" 2>/dev/null || echo 0)"
EOF
  chmod +x "$d"/*
}

# --- a fresh fake server for each test --------------------------------------------------
# new_case NAME [ENV]: R (the fake root), S (the fakes' state), F (the fakes), Q (Quadlet folder).
new_case() {
  CASE=$W/$1
  local env=${2:-prod}
  ENV_NAME=$env
  R=$CASE/root
  S=$CASE/state
  F=$CASE/fakes
  Q=$R/home/oc-$env/.config/containers/systemd
  SPOOL_DIR=$R/var/lib/oc-deploy/spool
  rm -rf "$CASE"
  mkdir -p "$Q" "$S/images" "$SPOOL_DIR" "$R/var/lib/oc-deploy"
  : >"$S/calls.log"
  printf '%s\n' "$env" >"$S/env-name"
  make_fakes "$F"
  local app
  for app in cms web; do
    sed -e "s/@@ENV@@/$env/g" -e 's/@@[A-Z_]*@@/1234/g' "$TEMPLATES/oc-$app.container.template" >"$Q/oc-$app-$env.container"
    sed -i "s|^Image=.*|Image=localhost/oc-$app:$SHA_OLD|" "$Q/oc-$app-$env.container"
  done
  cp -p "$Q/oc-cms-$env.container" "$CASE/cms.orig"
  cp -p "$Q/oc-web-$env.container" "$CASE/web.orig"
  OUT=$CASE/out.txt
  # By default the old release is loaded in the fake store, and both services are healthy.
  seed_image "localhost/oc-cms:$SHA_OLD" "$(id_of 201)" 1000
  seed_image "localhost/oc-web:$SHA_OLD" "$(id_of 202)" 1000
  APPLY_ENV=(
    "OC_ROOT=$R" "OC_PODMAN=$F/podman" "OC_SYSTEMCTL=$F/systemctl" "OC_CURL=$F/curl" "OC_RUNUSER=$F/runuser"
    "OC_DEPLOY_USER=$OWNER" "OC_ENV_UID=1234" "OC_HEALTH_TIMEOUT=2" "OC_HEALTH_INTERVAL=0.2"
  )
}

seed_image() { # NAME ID CREATED
  local k=${1//\//_}
  k=${k//:/_}
  printf '%s %s %s\n' "$1" "$2" "$3" >"$S/images/$k"
}
has_image() { # NAME
  local k=${1//\//_}
  k=${k//:/_}
  [[ -f $S/images/$k ]]
}
image_id() { # NAME
  local k=${1//\//_}
  k=${k//:/_}
  awk '{print $2}' "$S/images/$k"
}

# make_tarball LINES...: the spool file, a gzip of "image NAME ID CREATED" lines.
make_tarball() {
  printf '%s\n' "$@" | gzip -c >"$SPOOL_DIR/incoming.tar.gz"
  chmod 0600 "$SPOOL_DIR/incoming.tar.gz"
}
good_tarball() { # [SHA]
  local sha=${1:-$SHA_NEW}
  make_tarball "image oc-cms:$sha $CMS_ID 2000" "image oc-web:$sha $WEB_ID 2000"
}

# run_apply ARGS...: runs apply-release.sh with the fakes; RC and the output in $OUT.
run_apply() {
  RC=0
  env "${APPLY_ENV[@]}" bash "$APPLY" "$@" >"$OUT" 2>&1 || RC=$?
}
deploy_args() { printf '%s\n' "$ENV_NAME" "${1:-$SHA_NEW}" "${2:-$CMS_ID}" "${3:-$WEB_ID}"; }
run_good() {
  local -a a
  mapfile -t a < <(deploy_args "$@")
  run_apply "${a[@]}"
}

qimage() { sed -n 's/^Image=//p' "$Q/oc-$1-$ENV_NAME.container"; }
files_unchanged() { cmp -s "$Q/oc-cms-$ENV_NAME.container" "$CASE/cms.orig" && cmp -s "$Q/oc-web-$ENV_NAME.container" "$CASE/web.orig"; }
no_service_calls() { ! grep -q '^systemctl ' "$S/calls.log"; }
restart_count() { grep -c '^restart ' "$S/restarts.log" 2>/dev/null || true; }
show_out() { sed 's/^/         | /' "$OUT" | head -n 25; }

# ======================================================================================
section "success"
new_case success
good_tarball
run_good
if [[ $RC -eq 0 ]]; then ok "success: exits 0"; else notok "success: exits $RC (wanted 0)"; show_out; fi
check "success: loads the images (one podman load)" test "$(grep -c '^podman load' "$S/calls.log")" -eq 1
check "success: the CMS file points at the new tag" test "$(qimage cms)" = "localhost/oc-cms:$SHA_NEW"
check "success: the web file points at the new tag" test "$(qimage web)" = "localhost/oc-web:$SHA_NEW"
check "success: Quadlet is told to regenerate (daemon-reload) before the restart" bash -c "grep -n 'daemon-reload\|restart' '$S/systemctl.log' | head -n 1 | grep -q daemon-reload"
check "success: both services are restarted, together" grep -qx -- '--user restart oc-cms-prod.service oc-web-prod.service' "$S/systemctl.log"
check "success: the restart saw both files already on the new tag" grep -qx "restart cms=localhost/oc-cms:$SHA_NEW web=localhost/oc-web:$SHA_NEW" "$S/restarts.log"
check "success: it waited for the CMS /_health on 1337" grep -qx 'curl http://127.0.0.1:1337/_health' "$S/curl.log"
check "success: it waited for the web /healthz on 4321" grep -qx 'curl http://127.0.0.1:4321/healthz' "$S/curl.log"
check "success: Podman, systemctl and the file edit all ran as oc-prod" bash -c "sort -u '$S/runuser.log' | grep -qx oc-prod && [[ \$(sort -u '$S/runuser.log' | wc -l) -eq 1 ]]"
check "success: Podman runs with a clean environment that is the environment user's (HOME and XDG_RUNTIME_DIR)" bash -c "grep -q 'env-call oc-prod env -i PATH=[^ ]* LC_ALL=C HOME=$R/home/oc-prod XDG_RUNTIME_DIR=/run/user/1234 $F/podman load' '$S/runuser-env.log'"
check "success: systemctl --user gets the user's bus address" bash -c "grep -q 'XDG_RUNTIME_DIR=/run/user/1234 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1234/bus $F/systemctl --user restart' '$S/runuser-env.log'"
check "success: the spool file is deleted afterwards" test ! -e "$SPOOL_DIR/incoming.tar.gz"
check "success: staging is not touched" test "$(grep -c staging "$S/systemctl.log" || true)" -eq 0

section "podman prints image ids without the sha256: prefix, Docker with it"
new_case bare
touch "$S/bare-ids"
good_tarball
run_good
if [[ $RC -eq 0 ]]; then ok "ids that podman prints as bare hex still match the sha256:<hex> that CI sends: exits 0"; else notok "bare ids: exits $RC"; show_out; fi
new_case bare-bad
touch "$S/bare-ids"
make_tarball "image oc-cms:$SHA_NEW $(id_of 999) 2000" "image oc-web:$SHA_NEW $WEB_ID 2000"
run_good
if [[ $RC -eq 3 ]]; then ok "bare hex ids that differ still exit 3"; else notok "bare ids mismatch: exits $RC"; fi

section "staging uses its own user, ports and services"
new_case staging staging
good_tarball
run_good
if [[ $RC -eq 0 ]]; then ok "staging: exits 0"; else notok "staging: exits $RC"; show_out; fi
check "staging: restarts oc-cms-staging and oc-web-staging" grep -qx -- '--user restart oc-cms-staging.service oc-web-staging.service' "$S/systemctl.log"
check "staging: checks 1338 and 4322" bash -c "grep -qx 'curl http://127.0.0.1:1338/_health' '$S/curl.log' && grep -qx 'curl http://127.0.0.1:4322/healthz' '$S/curl.log'"
check "staging: acts as oc-staging" bash -c "sort -u '$S/runuser.log' | grep -qx oc-staging"

# ======================================================================================
section "a failed health check rolls back"
new_case health
good_tarball
echo "$SHA_NEW" >"$S/bad-tag"
run_good
if [[ $RC -eq 1 ]]; then ok "health failure: exits 1"; else notok "health failure: exits $RC (wanted 1)"; show_out; fi
check "health failure: both files are byte for byte what they were" files_unchanged
check "health failure: the new tags were tried, then the old ones restarted" bash -c "[[ \$(grep -c '^restart ' '$S/restarts.log') -eq 2 ]] && sed -n 1p '$S/restarts.log' | grep -q $SHA_NEW && sed -n 2p '$S/restarts.log' | grep -q 'cms=localhost/oc-cms:$SHA_OLD web=localhost/oc-web:$SHA_OLD'"
check "health failure: the output says it went back" grep -qi 'rolled back' "$OUT"
check "health failure: nothing was stopped (the old release runs)" bash -c "! grep -q -- '--user stop' '$S/systemctl.log'"
check "health failure: the spool file is deleted" test ! -e "$SPOOL_DIR/incoming.tar.gz"

new_case health-web
good_tarball
# only the web app is unhealthy on the new tag: fake curl checks both files, so make just the web tag bad
cat >"$F/curl" <<'EOF'
#!/usr/bin/env bash
S=$(cd -- "$(dirname -- "$0")/../state" && pwd -P); R=$(cd -- "$(dirname -- "$0")/../root" && pwd -P)
url=${*: -1}
printf 'curl %s\n' "$url" >>"$S/curl.log"
case $url in
  *4321/healthz) tag=$(sed -n 's/^Image=[^:]*://p' "$R/home/oc-prod/.config/containers/systemd/oc-web-prod.container"); [[ $tag == "$(cat "$S/bad-tag")" ]] && exit 22 ;;
esac
exit 0
EOF
echo "$SHA_NEW" >"$S/bad-tag"
run_good
if [[ $RC -eq 1 ]]; then ok "an unhealthy web app alone also rolls back: exits 1"; else notok "an unhealthy web app alone: exits $RC"; show_out; fi
check "an unhealthy web app alone: both files are back on the old pair (no mixed pair)" files_unchanged

new_case restart-fails
good_tarball
echo "$SHA_NEW" >"$S/restart-fails-for"
run_good
if [[ $RC -eq 1 ]]; then ok "a restart that fails also rolls back: exits 1"; else notok "a failed restart: exits $RC"; show_out; fi
check "a restart that fails: both files are back on the old pair" files_unchanged
check "a restart that fails: the old pair was restarted" bash -c "tail -n 1 '$S/restarts.log' | grep -q 'cms=localhost/oc-cms:$SHA_OLD web=localhost/oc-web:$SHA_OLD'"

new_case rewrite-half
good_tarball
touch "$S/fail-sed-web"
run_good
if [[ $RC -eq 1 ]]; then ok "an edit that fails halfway (CMS done, web not): exits 1"; else notok "a half edit: exits $RC"; show_out; fi
check "a half edit: the CMS file is put back too (never a mixed pair)" files_unchanged
check "a half edit: the services were not left stopped" bash -c "! grep -q -- '--user stop' '$S/systemctl.log'"

section "no previous release: a failed deploy leaves the services stopped"
new_case first
rm -f "$S"/images/*
sed -i "s|^Image=.*|Image=localhost/oc-cms:bootstrap|" "$Q/oc-cms-prod.container"
sed -i "s|^Image=.*|Image=localhost/oc-web:bootstrap|" "$Q/oc-web-prod.container"
cp -p "$Q/oc-cms-prod.container" "$CASE/cms.orig"
cp -p "$Q/oc-web-prod.container" "$CASE/web.orig"
good_tarball
echo "$SHA_NEW" >"$S/bad-tag"
run_good
if [[ $RC -eq 1 ]]; then ok "no previous release: exits 1"; else notok "no previous release: exits $RC"; show_out; fi
check "no previous release: the files are back as the bootstrap wrote them" files_unchanged
check "no previous release: only the one (failed) restart happened" test "$(restart_count)" -eq 1
check "no previous release: both services were stopped, last" bash -c "tail -n 1 '$S/systemctl.log' | grep -qx -- '--user stop oc-cms-prod.service oc-web-prod.service'"
check "no previous release: the output says so" grep -qi 'left stopped' "$OUT"

section "a good first deploy works too"
new_case first-ok
rm -f "$S"/images/*
sed -i "s|^Image=.*|Image=localhost/oc-cms:bootstrap|" "$Q/oc-cms-prod.container"
sed -i "s|^Image=.*|Image=localhost/oc-web:bootstrap|" "$Q/oc-web-prod.container"
good_tarball
run_good
if [[ $RC -eq 0 ]]; then ok "first deploy over the bootstrap placeholder: exits 0"; else notok "first deploy: exits $RC"; show_out; fi
check "first deploy: both files on the new tag" bash -c "[[ \$(sed -n 's/^Image=//p' '$Q/oc-cms-prod.container') == localhost/oc-cms:$SHA_NEW ]]"

# ======================================================================================
section "arguments are validated, with no side effects"
bad_args() { # DESCRIPTION ARGS...
  local desc=$1
  shift
  new_case bad
  good_tarball
  run_apply "$@"
  if [[ $RC -eq 2 ]]; then ok "$desc exits 2"; else notok "$desc exits $RC (wanted 2)"; show_out; fi
  if no_service_calls && [[ ! -s $S/calls.log ]] && files_unchanged && [[ -f $SPOOL_DIR/incoming.tar.gz ]]; then
    ok "$desc: nothing was touched (no podman, no systemctl, files and spool as they were)"
  else
    notok "$desc: something was touched"
  fi
}
G_CMS=$CMS_ID
G_WEB=$WEB_ID
bad_args "bad env 'dev'" dev "$SHA_NEW" "$G_CMS" "$G_WEB"
bad_args "bad env 'production'" production "$SHA_NEW" "$G_CMS" "$G_WEB"
bad_args "bad env 'Prod'" Prod "$SHA_NEW" "$G_CMS" "$G_WEB"
bad_args "bad env '../x'" ../x "$SHA_NEW" "$G_CMS" "$G_WEB"
bad_args "bad env 'prod ' (trailing space)" "prod " "$SHA_NEW" "$G_CMS" "$G_WEB"
bad_args "bad env with a newline" $'prod\n' "$SHA_NEW" "$G_CMS" "$G_WEB"
bad_args "an empty env" "" "$SHA_NEW" "$G_CMS" "$G_WEB"
bad_args "bad sha '../x'" prod ../x "$G_CMS" "$G_WEB"
bad_args "a 39-character sha" prod "${SHA_NEW:0:39}" "$G_CMS" "$G_WEB"
bad_args "a 41-character sha" prod "${SHA_NEW}a" "$G_CMS" "$G_WEB"
bad_args "an upper-case sha" prod "${SHA_NEW//1/A}" "$G_CMS" "$G_WEB"
bad_args "a sha with a non-hex letter" prod "${SHA_NEW:0:39}g" "$G_CMS" "$G_WEB"
bad_args "a sha with a trailing newline" prod "$SHA_NEW"$'\n' "$G_CMS" "$G_WEB"
bad_args "a sha that is a tag name" prod latest "$G_CMS" "$G_WEB"
bad_args "a CMS image id with 63 hex characters" prod "$SHA_NEW" "sha256:${G_CMS:7:63}" "$G_WEB"
bad_args "a CMS image id with 65 hex characters" prod "$SHA_NEW" "${G_CMS}a" "$G_WEB"
bad_args "a web image id in upper case" prod "$SHA_NEW" "$G_CMS" "sha256:${G_WEB:7}A"
bad_args "a web image id without the sha256: prefix" prod "$SHA_NEW" "$G_CMS" "${G_WEB:7}"
bad_args "a web image id with sha512:" prod "$SHA_NEW" "$G_CMS" "sha512:${G_WEB:7}"
bad_args "an image id that starts with an option" prod "$SHA_NEW" "--all" "$G_WEB"
bad_args "an image id with a trailing newline" prod "$SHA_NEW" "$G_CMS" "$G_WEB"$'\n'
bad_args "no arguments"
bad_args "three arguments" prod "$SHA_NEW" "$G_CMS"
bad_args "five arguments" prod "$SHA_NEW" "$G_CMS" "$G_WEB" extra
bad_args "one argument holding all four values" "prod $SHA_NEW $G_CMS $G_WEB"

# ======================================================================================
section "the image ids sent by CI must match what was loaded"
new_case mismatch
make_tarball "image oc-cms:$SHA_NEW $(id_of 999) 2000" "image oc-web:$SHA_NEW $WEB_ID 2000"
run_good
if [[ $RC -eq 3 ]]; then ok "an image id that does not match what was loaded exits 3"; else notok "id mismatch: exits $RC (wanted 3)"; show_out; fi
check "mismatch: the Quadlet files are byte for byte unchanged" files_unchanged
check "mismatch: no systemctl call at all (nothing was restarted or reloaded)" no_service_calls
check "mismatch: the images that were loaded are removed again" bash -c "[[ ! -f '$S/images/localhost_oc-cms_$SHA_NEW' && ! -f '$S/images/localhost_oc-web_$SHA_NEW' ]]"
check "mismatch: the old release is still in the store" bash -c "[[ -f '$S/images/localhost_oc-cms_$SHA_OLD' ]]"
check "mismatch: the output names the mismatch" grep -qi 'does not match' "$OUT"

new_case mismatch-web
make_tarball "image oc-cms:$SHA_NEW $CMS_ID 2000" "image oc-web:$SHA_NEW $(id_of 998) 2000"
run_good
if [[ $RC -eq 3 ]]; then ok "a web image id that does not match also exits 3"; else notok "web id mismatch: exits $RC"; show_out; fi
check "web mismatch: Quadlet files unchanged" files_unchanged
check "web mismatch: no systemctl call" no_service_calls
check "web mismatch: neither new tag is left in the store" bash -c "[[ ! -f '$S/images/localhost_oc-cms_$SHA_NEW' && ! -f '$S/images/localhost_oc-web_$SHA_NEW' ]]"

section "a tarball with other images in it"
new_case extra-image
make_tarball "image oc-cms:$SHA_NEW $CMS_ID 2000" "image oc-web:$SHA_NEW $WEB_ID 2000" "image evil/shell:1 $(id_of 777) 2000"
run_good
if [[ $RC -eq 3 ]]; then ok "an unexpected third image exits 3"; else notok "third image: exits $RC"; show_out; fi
check "third image: Quadlet files unchanged" files_unchanged
check "third image: no systemctl call" no_service_calls
check "third image: it is removed again" bash -c "[[ ! -f '$S/images/localhost_evil_shell_1' ]]"

new_case extra-retag
# the tarball re-points the previous release's tag at different content
make_tarball "image oc-cms:$SHA_NEW $CMS_ID 2000" "image oc-web:$SHA_NEW $WEB_ID 2000" "image oc-cms:$SHA_OLD $(id_of 666) 2000"
run_good
if [[ $RC -eq 3 ]]; then ok "a tarball that re-points an existing release tag exits 3"; else notok "re-pointed tag: exits $RC"; show_out; fi
check "re-pointed tag: the old release tag is back on the old image" bash -c "[[ \$(awk '{print \$2}' '$S/images/localhost_oc-cms_$SHA_OLD') == '$(id_of 201)' ]]"
check "re-pointed tag: files unchanged" files_unchanged

section "a tag that already exists with another id"
new_case tag-collision
seed_image "localhost/oc-cms:$SHA_NEW" "$(id_of 555)" 1500
good_tarball
run_good
if [[ $RC -eq 3 ]]; then ok "a release tag that already holds a different image exits 3"; else notok "tag collision: exits $RC"; show_out; fi
check "tag collision: nothing was loaded" bash -c "! grep -q '^podman load' '$S/calls.log'"
check "tag collision: files unchanged and no systemctl call" files_unchanged
check "tag collision: the existing image is untouched" bash -c "[[ \$(awk '{print \$2}' '$S/images/localhost_oc-cms_$SHA_NEW') == '$(id_of 555)' ]]"

new_case redeploy
seed_image "localhost/oc-cms:$SHA_NEW" "$CMS_ID" 1500
seed_image "localhost/oc-web:$SHA_NEW" "$WEB_ID" 1500
sed -i "s|^Image=.*|Image=localhost/oc-cms:$SHA_NEW|" "$Q/oc-cms-prod.container"
sed -i "s|^Image=.*|Image=localhost/oc-web:$SHA_NEW|" "$Q/oc-web-prod.container"
good_tarball
run_good
if [[ $RC -eq 0 ]]; then ok "deploying the release that is already running (same ids) exits 0"; else notok "redeploy: exits $RC"; show_out; fi

section "a tarball that cannot be loaded"
new_case corrupt
make_tarball "CORRUPT"
run_good
if [[ $RC -eq 6 ]]; then ok "a tarball podman cannot load exits 6"; else notok "corrupt tarball: exits $RC (wanted 6)"; show_out; fi
check "corrupt tarball: files unchanged and no systemctl call" files_unchanged
check "corrupt tarball: no systemctl call" no_service_calls

new_case notgzip
printf 'this is not gzip' >"$SPOOL_DIR/incoming.tar.gz"
run_good
if [[ $RC -eq 6 ]]; then ok "a spool file that is not gzip exits 6"; else notok "not gzip: exits $RC"; show_out; fi
check "not gzip: files unchanged" files_unchanged

# ======================================================================================
section "keeps only the 3 newest tags per image"
new_case prune
rm -f "$S"/images/*
for i in 1 2 3 4 5; do
  sha=$(printf '%040x' "$((0xaaaa + i))")
  seed_image "localhost/oc-cms:$sha" "$(id_of $((300 + i)))" "$((1000 + i))"
  seed_image "localhost/oc-web:$sha" "$(id_of $((400 + i)))" "$((1000 + i))"
done
CUR=$(printf '%040x' "$((0xaaaa + 5))")
sed -i "s|^Image=.*|Image=localhost/oc-cms:$CUR|" "$Q/oc-cms-prod.container"
sed -i "s|^Image=.*|Image=localhost/oc-web:$CUR|" "$Q/oc-web-prod.container"
seed_image "localhost/oc-cms:latest" "$(id_of 901)" 1
seed_image "localhost/oc-cms:bootstrap" "$(id_of 902)" 1
seed_image "localhost/other:$SHA_OLD" "$(id_of 903)" 1
good_tarball
run_good
if [[ $RC -eq 0 ]]; then ok "prune: the deploy succeeds"; else notok "prune: exits $RC"; show_out; fi
for app in cms web; do
  left=$(awk -v a="oc-$app" '$1 ~ ("^localhost/" a ":[0-9a-f]{40}$") {n++} END {print n + 0}' "$S"/images/*)
  check "prune: exactly 3 oc-$app release tags are left" test "$left" -eq 3
  check "prune: the new oc-$app tag is kept" has_image "localhost/oc-$app:$SHA_NEW"
  check "prune: the current oc-$app tag is kept" has_image "localhost/oc-$app:$CUR"
  check "prune: the oldest oc-$app tags are gone" bash -c "! [[ -f '$S/images/localhost_oc-${app}_$(printf '%040x' $((0xaaaa + 1)))' ]] && ! [[ -f '$S/images/localhost_oc-${app}_$(printf '%040x' $((0xaaaa + 2)))' ]]"
done
check "prune: the 4th newest cms tag is kept" has_image "localhost/oc-cms:$(printf '%040x' $((0xaaaa + 4)))"
check "prune: a tag that is not a 40-hex release (latest) is left alone" has_image "localhost/oc-cms:latest"
check "prune: the bootstrap tag is left alone" has_image "localhost/oc-cms:bootstrap"
check "prune: another repository is left alone" has_image "localhost/other:$SHA_OLD"

new_case prune-failed
rm -f "$S"/images/*
for i in 1 2 3 4 5; do
  sha=$(printf '%040x' "$((0xaaaa + i))")
  seed_image "localhost/oc-cms:$sha" "$(id_of $((300 + i)))" "$((1000 + i))"
  seed_image "localhost/oc-web:$sha" "$(id_of $((400 + i)))" "$((1000 + i))"
done
CUR=$(printf '%040x' "$((0xaaaa + 5))")
sed -i "s|^Image=.*|Image=localhost/oc-cms:$CUR|" "$Q/oc-cms-prod.container"
sed -i "s|^Image=.*|Image=localhost/oc-web:$CUR|" "$Q/oc-web-prod.container"
cp -p "$Q/oc-cms-prod.container" "$CASE/cms.orig"
cp -p "$Q/oc-web-prod.container" "$CASE/web.orig"
good_tarball
echo "$SHA_NEW" >"$S/bad-tag"
run_good
check "a failed deploy prunes nothing" bash -c "[[ \$(ls '$S/images' | wc -l) -eq 12 ]]"

# ======================================================================================
section "only the Image= line of the Quadlet files changes"
new_case oneline
good_tarball
run_good
for app in cms web; do
  f=$Q/oc-$app-prod.container
  o=$CASE/$app.orig
  changed=$(diff "$o" "$f" | grep -c '^[<>]' || true)
  check "oneline: oc-$app changes exactly one line (diff shows $changed changed lines, wanted 2: one out, one in)" test "$changed" -eq 2
  sed "s|^Image=.*|Image=localhost/oc-$app:$SHA_OLD|" "$f" >"$CASE/$app.reverted"
  check "oneline: oc-$app is byte for byte the original once the Image= line is put back" cmp -s "$CASE/$app.reverted" "$o"
  check "oneline: oc-$app keeps its mode" test "$(stat -c %a "$f")" = "$(stat -c %a "$o")"
done
# A file with no newline at the end, and one with CRLF line ends, keep those exactly.
new_case oneline-odd
good_tarball
printf '[Container]\nImage=localhost/oc-cms:%s\nUserNS=keep-id' "$SHA_OLD" >"$Q/oc-cms-prod.container"
cp -p "$Q/oc-cms-prod.container" "$CASE/cms.orig"
run_good
check "a file with no final newline keeps having none" bash -c "[[ \$(tail -c 1 '$Q/oc-cms-prod.container' | od -An -tx1 | tr -d ' ') == 64 ]]"
check "the other lines of such a file are unchanged" bash -c "[[ \$(sed -n '3p' '$Q/oc-cms-prod.container') == 'UserNS=keep-id' ]]"

section "a Quadlet file that is not what the bootstrap wrote is refused"
new_case two-images
printf 'Image=localhost/oc-cms:%s\n' "$SHA_OLD" >>"$Q/oc-cms-prod.container"
cp -p "$Q/oc-cms-prod.container" "$CASE/cms.orig"
good_tarball
run_good
if [[ $RC -eq 7 ]]; then ok "two Image= lines: exits 7"; else notok "two Image= lines: exits $RC (wanted 7)"; show_out; fi
check "two Image= lines: nothing changed, nothing loaded" bash -c "! grep -q '^podman load' '$S/calls.log'"
check "two Image= lines: no systemctl call" no_service_calls

new_case no-image
sed -i '/^Image=/d' "$Q/oc-web-prod.container"
cp -p "$Q/oc-web-prod.container" "$CASE/web.orig"
good_tarball
run_good
if [[ $RC -eq 7 ]]; then ok "no Image= line: exits 7"; else notok "no Image= line: exits $RC"; show_out; fi

new_case spaced-image
sed -i 's|^Image=|Image = |' "$Q/oc-web-prod.container"
cp -p "$Q/oc-web-prod.container" "$CASE/web.orig"
good_tarball
run_good
if [[ $RC -eq 7 ]]; then ok "an 'Image = x' spelling the edit would miss: exits 7"; else notok "spaced Image: exits $RC"; show_out; fi

new_case foreign-image
sed -i 's|^Image=.*|Image=docker.io/library/node:22|' "$Q/oc-web-prod.container"
cp -p "$Q/oc-web-prod.container" "$CASE/web.orig"
good_tarball
run_good
if [[ $RC -eq 7 ]]; then ok "an Image= that is not a local oc image: exits 7"; else notok "foreign Image: exits $RC"; show_out; fi

new_case no-quadlet
rm -f "$Q/oc-cms-prod.container"
good_tarball
run_good
if [[ $RC -eq 7 ]]; then ok "a missing Quadlet file: exits 7"; else notok "missing Quadlet file: exits $RC"; show_out; fi

# ======================================================================================
section "two deploys at the same time"
new_case lock
good_tarball
hold_lock "$R/var/lib/oc-deploy/apply.lock"
run_good
release_lock
if [[ $RC -eq 4 ]]; then ok "a second deploy at the same time is refused (exit 4)"; else notok "concurrent deploy: exits $RC (wanted 4)"; show_out; fi
check "concurrent: nothing was touched" bash -c "[[ ! -s '$S/calls.log' ]]"
check "concurrent: the first deploy's spool file is not deleted by the refused one" test -f "$SPOOL_DIR/incoming.tar.gz"
check "concurrent: the output says another deploy is running" grep -qi 'already running' "$OUT"
run_good
if [[ $RC -eq 0 ]]; then ok "once the lock is free the same deploy works"; else notok "after the lock was released: exits $RC"; fi

# ======================================================================================
section "the spool file is never trusted"
spool_case() { # NAME DESCRIPTION EXPECTED-OUTPUT-TEXT
  if [[ $RC -eq 5 ]]; then ok "$2: exits 5"; else notok "$2: exits $RC (wanted 5)"; show_out; fi
  check "$2: nothing was loaded, nothing restarted" bash -c "! grep -q '^podman load' '$S/calls.log'"
  check "$2: files unchanged" files_unchanged
  check "$2: the refusal says why ($3)" grep -qi -- "$3" "$OUT"
}
new_case symlink
good_tarball
mv "$SPOOL_DIR/incoming.tar.gz" "$CASE/elsewhere.tar.gz"
ln -s "$CASE/elsewhere.tar.gz" "$SPOOL_DIR/incoming.tar.gz"
run_good
spool_case symlink "a symlink as the spool file" "symbolic link"
check "a symlink: the file it pointed to is not deleted" test -f "$CASE/elsewhere.tar.gz"

new_case spool-dir-symlink
good_tarball
mv "$SPOOL_DIR" "$CASE/realspool"
ln -s "$CASE/realspool" "$SPOOL_DIR"
run_good
spool_case dirlink "a symlink as the spool directory" "directory"

new_case missing
rm -f "$SPOOL_DIR/incoming.tar.gz"
run_good
spool_case missing "no spool file" "regular file"

new_case isdir
mkdir "$SPOOL_DIR/incoming.tar.gz"
run_good
spool_case isdir "a directory as the spool file" "regular file"

new_case fifo
mkfifo "$SPOOL_DIR/incoming.tar.gz"
run_good
spool_case fifo "a named pipe as the spool file" "regular file"

new_case empty
: >"$SPOOL_DIR/incoming.tar.gz"
run_good
spool_case empty "an empty spool file" "empty"

new_case wrong-owner
good_tarball
APPLY_ENV=("${APPLY_ENV[@]/OC_DEPLOY_USER=$OWNER/OC_DEPLOY_USER=nobody}")
if [[ $OWNER != nobody ]]; then
  run_good
  spool_case owner "a spool file that the deploy user does not own" "owned by"
else
  ok "wrong owner: skipped (running as nobody)"
fi

new_case hardlink
good_tarball
ln "$SPOOL_DIR/incoming.tar.gz" "$CASE/second-name"
run_good
spool_case hardlink "a spool file with a second hard link" "link"

new_case toobig
good_tarball
size=$(stat -c %s "$SPOOL_DIR/incoming.tar.gz")
APPLY_ENV+=("OC_MAX_TARBALL_BYTES=$((size - 1))")
run_good
spool_case toobig "a spool file over the size limit" "too large"
new_case justfits
good_tarball
size=$(stat -c %s "$SPOOL_DIR/incoming.tar.gz")
APPLY_ENV+=("OC_MAX_TARBALL_BYTES=$size")
run_good
if [[ $RC -eq 0 ]]; then ok "a spool file exactly at the limit is accepted"; else notok "at the limit: exits $RC"; show_out; fi

new_case limits-conf
good_tarball
mkdir -p "$CASE/bin"
cp "$APPLY" "$CASE/bin/apply-release.sh"
printf 'MAX_TARBALL_BYTES=1\n' >"$CASE/bin/limits.conf"
RC=0
(cd "$CASE" && env "${APPLY_ENV[@]}" bash bin/apply-release.sh prod "$SHA_NEW" "$CMS_ID" "$WEB_ID") >"$OUT" 2>&1 || RC=$?
if [[ $RC -eq 5 ]]; then ok "limits.conf next to the script sets the size limit (and the script works when started by a relative path)"; else notok "limits.conf: exits $RC (wanted 5)"; show_out; fi
check "limits.conf: the refusal is for size" grep -qi 'too large' "$OUT"
printf 'MAX_TARBALL_BYTES=notanumber\nsomething else\n' >"$CASE/bin/limits.conf"
good_tarball
RC=0
(cd "$CASE" && env "${APPLY_ENV[@]}" bash bin/apply-release.sh prod "$SHA_NEW" "$CMS_ID" "$WEB_ID") >"$OUT" 2>&1 || RC=$?
if [[ $RC -eq 0 ]]; then ok "a limits.conf line that is not a number is ignored (default limit)"; else notok "bad limits.conf: exits $RC"; show_out; fi

new_case spool-removed-on-refusal
good_tarball
APPLY_ENV+=("OC_MAX_TARBALL_BYTES=1")
run_good
check "a refused spool file (too large) is deleted, so it cannot be used by a later run" test ! -e "$SPOOL_DIR/incoming.tar.gz"

# ======================================================================================
section "the root script ignores its caller's environment when it runs under sudo"
new_case sudo-env
good_tarball
cat >"$F/evil" <<EOF
#!/usr/bin/env bash
touch "$CASE/EVIL-RAN"
exit 0
EOF
chmod +x "$F/evil"
RC=0
env SUDO_USER=attacker OC_ROOT="$R" OC_PODMAN="$F/evil" OC_SYSTEMCTL="$F/evil" OC_CURL="$F/evil" OC_RUNUSER="$F/evil" \
  OC_DEPLOY_USER="$OWNER" OC_MAX_TARBALL_BYTES=99999999999 \
  bash "$APPLY" prod "$SHA_NEW" "$CMS_ID" "$WEB_ID" >"$OUT" 2>&1 || RC=$?
check "under sudo, OC_PODMAN and the other overrides are not run" test ! -e "$CASE/EVIL-RAN"
check "under sudo, OC_ROOT is ignored (the fake tree is not used)" bash -c "! grep -q '^podman' '$S/calls.log' && [[ -f '$SPOOL_DIR/incoming.tar.gz' ]]"
check "under sudo the script fails (there is no real spool on this machine) instead of deploying" test "$RC" -ne 0

section "the ports in apply-release.sh are the ones in infra/lib/common.sh"
# shellcheck source=../lib/common.sh
source "$COMMON"
# shellcheck source=apply-release.sh
source "$APPLY"
for e in prod staging; do
  check "ports of $e: CMS" test "$(release_port cms "$e")" = "$(oc_cms_port "$e")"
  check "ports of $e: web" test "$(release_port web "$e")" = "$(oc_web_port "$e")"
done

# ======================================================================================
# deploy-release.sh: the forced command run as the restricted deploy user
section "deploy-release: the forced command"
new_deploy() { # NAME
  new_case "$1"
  DEPLOY_ENV=(
    "OC_ROOT=$R" "OC_SUDO=$F/sudo" "OC_APPLY_RELEASE=$F/apply" "OC_MAX_TARBALL_BYTES=${MAXB:-1048576}"
  )
  rm -f "$SPOOL_DIR"/*
}
# run_deploy STDIN-TEXT ARGS...: the forced command, with the given stdin
run_deploy() {
  local input=$1
  shift
  RC=0
  printf '%s' "$input" | env "${DEPLOY_ENV[@]}" bash "$DEPLOY" "$@" >"$OUT" 2>&1 || RC=$?
}
new_deploy d-ok
run_deploy "TARBALL-BYTES" prod "$SHA_NEW" "$CMS_ID" "$WEB_ID"
if [[ $RC -eq 0 ]]; then ok "deploy-release: good arguments and a tarball on stdin exit 0"; else notok "deploy-release: exits $RC"; show_out; fi
check "deploy-release: apply-release gets exactly the four arguments" grep -qx "prod $SHA_NEW $CMS_ID $WEB_ID" "$S/apply.args"
check "deploy-release: apply-release saw the tarball as the spool file" bash -c "[[ \$(cat '$S/apply.saw-spool') == TARBALL-BYTES ]]"
check "deploy-release: the spool file is gone afterwards" test ! -e "$SPOOL_DIR/incoming.tar.gz"
check "deploy-release: no part file is left" bash -c "[[ -z \$(ls -A '$SPOOL_DIR' | grep -v '^.lock\$') ]]"

new_deploy d-ssh
RC=0
printf 'TB' | env "${DEPLOY_ENV[@]}" SSH_ORIGINAL_COMMAND="prod $SHA_NEW $CMS_ID $WEB_ID" bash "$DEPLOY" >"$OUT" 2>&1 || RC=$?
if [[ $RC -eq 0 ]]; then ok "deploy-release: the arguments can come from SSH_ORIGINAL_COMMAND (the forced-command way)"; else notok "SSH_ORIGINAL_COMMAND: exits $RC"; show_out; fi
check "deploy-release: ... and reach apply-release unchanged" grep -qx "prod $SHA_NEW $CMS_ID $WEB_ID" "$S/apply.args"

ssh_bad() { # DESCRIPTION COMMAND-STRING
  new_deploy d-ssh-bad
  RC=0
  printf 'TB' | env "${DEPLOY_ENV[@]}" SSH_ORIGINAL_COMMAND="$2" bash "$DEPLOY" >"$OUT" 2>&1 || RC=$?
  if [[ $RC -eq 2 ]]; then ok "deploy-release: $1 exits 2"; else notok "deploy-release: $1 exits $RC (wanted 2)"; show_out; fi
  check "deploy-release: $1: apply-release was not called and nothing was spooled" bash -c "[[ ! -e '$S/apply.args' && -z \$(ls -A '$SPOOL_DIR' | grep -v '^.lock\$') ]]"
}
ssh_bad "a shell command" "id"
ssh_bad "a command after the arguments" "prod $SHA_NEW $CMS_ID $WEB_ID; cat /etc/shadow"
ssh_bad "a command in front of the arguments" "cat /etc/shadow; prod $SHA_NEW $CMS_ID $WEB_ID"
ssh_bad "command substitution in the sha" "prod \$(id)$SHA_NEW $CMS_ID $WEB_ID"
ssh_bad "an extra word" "prod $SHA_NEW $CMS_ID $WEB_ID --force"
ssh_bad "a missing word" "prod $SHA_NEW $CMS_ID"
ssh_bad "two spaces between words" "prod  $SHA_NEW $CMS_ID $WEB_ID"
ssh_bad "a newline in the command" "prod $SHA_NEW $CMS_ID $WEB_ID"$'\n'"id"
ssh_bad "a bad environment" "dev $SHA_NEW $CMS_ID $WEB_ID"
ssh_bad "an empty command" ""
ssh_bad "an scp or sftp request" "scp -t /tmp"
ssh_bad "a path in place of the environment" "../../prod $SHA_NEW $CMS_ID $WEB_ID"

new_deploy d-both
RC=0
printf 'TB' | env "${DEPLOY_ENV[@]}" SSH_ORIGINAL_COMMAND="prod $SHA_NEW $CMS_ID $WEB_ID" bash "$DEPLOY" prod "$SHA_NEW" "$CMS_ID" "$WEB_ID" >"$OUT" 2>&1 || RC=$?
if [[ $RC -eq 2 ]]; then ok "deploy-release: arguments and SSH_ORIGINAL_COMMAND together are refused (exit 2)"; else notok "both sources: exits $RC"; fi

new_deploy d-none
run_deploy "TB"
if [[ $RC -eq 2 ]]; then ok "deploy-release: no arguments and no SSH_ORIGINAL_COMMAND (an interactive login) exits 2"; else notok "no command: exits $RC"; fi

new_deploy d-badargs
run_deploy "TB" dev "$SHA_NEW" "$CMS_ID" "$WEB_ID"
if [[ $RC -eq 2 ]]; then ok "deploy-release: bad env exits 2"; else notok "d bad env: $RC"; fi
run_deploy "TB" prod "${SHA_NEW:0:39}" "$CMS_ID" "$WEB_ID"
if [[ $RC -eq 2 ]]; then ok "deploy-release: a 39-character sha exits 2"; else notok "d 39-char sha: $RC"; fi
run_deploy "TB" prod ../x "$CMS_ID" "$WEB_ID"
if [[ $RC -eq 2 ]]; then ok "deploy-release: ../x as the sha exits 2"; else notok "d ../x: $RC"; fi
run_deploy "TB" prod "$SHA_NEW" "$CMS_ID" "sha256:short"
if [[ $RC -eq 2 ]]; then ok "deploy-release: a short image id exits 2"; else notok "d short id: $RC"; fi
check "deploy-release: none of those reached apply-release" test ! -e "$S/apply.args"

new_deploy d-rc
echo 3 >"$S/apply-rc"
run_deploy "TB" prod "$SHA_NEW" "$CMS_ID" "$WEB_ID"
if [[ $RC -eq 3 ]]; then ok "deploy-release: passes apply-release's exit status through (3)"; else notok "rc passthrough: $RC"; fi
echo 1 >"$S/apply-rc"
run_deploy "TB" prod "$SHA_NEW" "$CMS_ID" "$WEB_ID"
if [[ $RC -eq 1 ]]; then ok "deploy-release: passes apply-release's exit status through (1)"; else notok "rc passthrough 1: $RC"; fi
check "deploy-release: the spool file is deleted after a failed apply too" test ! -e "$SPOOL_DIR/incoming.tar.gz"

new_deploy d-big
MAXB=10
DEPLOY_ENV=("${DEPLOY_ENV[@]/OC_MAX_TARBALL_BYTES=*/OC_MAX_TARBALL_BYTES=10}")
run_deploy "0123456789ABC" prod "$SHA_NEW" "$CMS_ID" "$WEB_ID"
if [[ $RC -eq 5 ]]; then ok "deploy-release: a tarball over the limit exits 5"; else notok "too big: exits $RC (wanted 5)"; show_out; fi
check "deploy-release: ... apply-release was not called" test ! -e "$S/apply.args"
check "deploy-release: ... and nothing is left in the spool" bash -c "[[ -z \$(ls -A '$SPOOL_DIR' | grep -v '^.lock\$') ]]"
run_deploy "0123456789" prod "$SHA_NEW" "$CMS_ID" "$WEB_ID"
if [[ $RC -eq 0 ]]; then ok "deploy-release: a tarball exactly at the limit is accepted"; else notok "at the limit: exits $RC"; show_out; fi
MAXB=

new_deploy d-empty
run_deploy "" prod "$SHA_NEW" "$CMS_ID" "$WEB_ID"
if [[ $RC -eq 5 ]]; then ok "deploy-release: an empty stdin exits 5"; else notok "empty stdin: exits $RC"; fi

new_deploy d-stale
printf 'OLD' >"$SPOOL_DIR/incoming.tar.gz"
run_deploy "NEW-TARBALL" prod "$SHA_NEW" "$CMS_ID" "$WEB_ID"
check "deploy-release: a stale spool file is replaced, never mixed in" bash -c "[[ \$(cat '$S/apply.saw-spool') == NEW-TARBALL ]]"

new_deploy d-lock
hold_lock "$SPOOL_DIR/.lock"
run_deploy "TB" prod "$SHA_NEW" "$CMS_ID" "$WEB_ID"
release_lock
if [[ $RC -eq 4 ]]; then ok "deploy-release: a second deploy at the same time is refused (exit 4)"; else notok "d concurrent: exits $RC (wanted 4)"; show_out; fi
check "deploy-release: ... without calling apply-release" test ! -e "$S/apply.args"

# ======================================================================================
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
