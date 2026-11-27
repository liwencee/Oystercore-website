#!/usr/bin/env bash
# Proves that an app image is minimal and non-root, by test and not by promise (spec 10.9).
#
#   bash infra/images/verify-image.sh <image> [web|cms]
#
# The app is taken from the image name (oc-web, oc-cms) when the second argument is left out.
# Every check runs even when an earlier one fails, so one run shows everything. Output is one
# line per check, "PASS <id> <detail>" or "FAIL <id> <detail>".
#
#   non-root      the image's user is a numeric uid AND an explicit numeric gid (USER 65532:65532),
#                 and neither is 0. A uid with no gid runs with gid 0 whenever the image's
#                 /etc/passwd has no entry for it, so a lone uid is refused.
#   no-shell      no shell binary is in the filesystem and /bin/sh cannot be started
#   node-version  `<image> --version` prints Node 22.23.4 or newer
#   forbidden     no .env*, .git, *.test.*, *.spec.* or .cache entry, and no __tests__, test or
#                 tests folder, anywhere in the filesystem
#   esbuild       no ELF binary under a path with an esbuild folder or file name (esbuild is a
#                 build tool; its Go binary is scanned, and needs updating, like the app)
#   size          the filesystem is under the limit below (1.5 times the measured size)
#   healthcheck   the health-check script exits 1 when nothing is listening (a control, so a
#                 script that always exits 0 cannot pass)
#   read-only     the image starts under the Quadlet sandbox (read-only root, no capabilities,
#                 no new privileges, a small /tmp) and /app/healthcheck.mjs passes. In the
#                 running container the process is not root, /proc/mounts shows the root
#                 filesystem read-only, /app cannot be written and /tmp can. (Capabilities and
#                 no-new-privileges are asked for, not read back.)
#   keep-id       the same, as a host user's uid that has no entry in the image (what
#                 `--userns=keep-id` does on the server)
#
# Exit status: 0 every check passed, 1 a check failed, 2 the verifier could not run.
#
# Needs Docker. The cms needs the compose database (docker compose -f docker-compose.dev.yml
# up -d), which is reached through host.docker.internal. For the run the verifier creates a
# throwaway database and database user, generates throwaway Strapi secrets and drops the
# database again at the end. Nothing is read from apps/cms/.env, and no secret is ever on a
# command line or in an image. Settings (all optional):
#
#   OC_VERIFY_DB_HOST / _PORT       where the database is (host.docker.internal / 3307)
#   OC_VERIFY_DB_USER / _PASSWORD   an account that may create databases and users; the
#                                   defaults are the dev credentials in docker-compose.dev.yml
#   OC_VERIFY_START_TIMEOUT         seconds to wait for the health check (web 60, cms 150)
#   OC_VERIFY_MAX_BYTES             overrides the size limit
set -euo pipefail

# Git Bash on Windows would rewrite /nodejs/... and /tmp arguments for docker.exe.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'
export LC_ALL=C

# The oldest Node the images may report (spec 10.9: Astro 7 and the Node security releases).
readonly MIN_NODE='22.23.4'
# The check script and the node binary sit at fixed places; the Quadlet files run them from here.
readonly NODE_BIN='/nodejs/bin/node'
readonly HEALTHCHECK_JS='/app/healthcheck.mjs'
# A host user's uid, for the keep-id run. Any uid that has no passwd entry in the image will do.
readonly KEEP_ID_USER='20000:20000'

# Size limits: 1.5 times the size measured when the images were first built, in bytes of the
# exported filesystem (`docker export`), which does not depend on the image store in use.
readonly MAX_BYTES_WEB=417051648  # measured 278034432 (265 MiB) x 1.5
readonly MAX_BYTES_CMS=1129378560 # measured 752919040 (718 MiB) x 1.5

die() {
  printf 'verify-image: %s\n' "$*" >&2
  exit 2
}

usage() {
  printf 'usage: bash infra/images/verify-image.sh <image> [web|cms]\n' >&2
  exit 2
}

[[ $# -ge 1 && $# -le 2 ]] || usage
image=$1
app=${2:-}
if [[ -z $app ]]; then
  case $image in
    *oc-web*) app=web ;;
    *oc-cms*) app=cms ;;
    *) die "cannot tell which app $image is: pass web or cms as the second argument" ;;
  esac
fi

# The values below mirror infra/quadlet/oc-<app>.container.template: ports, memory, process
# limit and the Node heap, so a limit that is too small shows up here and not on the server.
case $app in
  web)
    port=4321
    memory=512m
    pids=256
    heap=384
    start_timeout=60
    max_bytes=$MAX_BYTES_WEB
    ;;
  cms)
    port=1337
    memory=1536m
    pids=512
    heap=1024
    start_timeout=150
    max_bytes=$MAX_BYTES_CMS
    ;;
  *) usage ;;
esac
start_timeout=${OC_VERIFY_START_TIMEOUT:-$start_timeout}
max_bytes=${OC_VERIFY_MAX_BYTES:-$max_bytes}

command -v docker >/dev/null 2>&1 || die 'docker is required'
docker info >/dev/null 2>&1 || die 'the Docker daemon is not running'
docker image inspect "$image" >/dev/null 2>&1 || die "no such image: $image (build it first)"

work=$(mktemp -d)
containers=()
db_name=''
db_user=''
db_password=''

db_host=${OC_VERIFY_DB_HOST:-host.docker.internal}
db_port=${OC_VERIFY_DB_PORT:-3307}
db_admin_user=${OC_VERIFY_DB_USER:-root}
# The dev root password from docker-compose.dev.yml (a throwaway local database, not a secret).
db_admin_password=${OC_VERIFY_DB_PASSWORD:-oc_dev_root}
# Pinned by digest (the multi-arch index of mariadb:11.4), the same as the MariaDB service in
# .github/workflows/ci.yml; Renovate bumps both (renovate.json).
readonly db_client_image='mariadb:11.4@sha256:a8992b5e5404d11e03c54a31d0c1bdea3fd116d283aa6d1a627551f29045309b'

# Windows Git Bash gives docker.exe a Windows path for files; elsewhere the path is already right.
host_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

# random N: N bytes of randomness as letters and digits (no characters a database or an
# environment file would treat specially).
random() {
  head -c "$(($1 * 2))" /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c "1-$1"
}

# db_sql: runs the SQL on stdin as the database admin, in a throwaway client container, with
# the password in the environment and not on a command line.
db_sql() {
  MYSQL_PWD=$db_admin_password docker run --rm -i -e MYSQL_PWD \
    --add-host host.docker.internal:host-gateway "$db_client_image" \
    mariadb --protocol=tcp -h "$db_host" -P "$db_port" -u "$db_admin_user"
}

# The throwaway database and its own account, for the cms; and the SQL that removes them.
# Backticks and quotes are part of the SQL, so the text is built in a here-document.
sql_create() {
  cat <<SQL
CREATE DATABASE \`$db_name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER '$db_user'@'%' IDENTIFIED BY '$db_password';
GRANT ALL PRIVILEGES ON \`$db_name\`.* TO '$db_user'@'%';
SQL
}
sql_drop() {
  cat <<SQL
DROP DATABASE IF EXISTS \`$db_name\`;
DROP USER IF EXISTS '$db_user'@'%';
SQL
}

cleanup() {
  local status=$?
  local c
  if ((${#containers[@]})); then
    for c in "${containers[@]}"; do docker rm -f "$c" >/dev/null 2>&1 || true; done
  fi
  if [[ -n $db_name ]]; then
    sql_drop | db_sql >/dev/null 2>&1 || printf 'verify-image: could not drop database %s\n' "$db_name" >&2
  fi
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT

failures=0
pass() { printf 'PASS %-13s %s\n' "$1" "$2"; }
fail() {
  printf 'FAIL %-13s %s\n' "$1" "$2"
  failures=$((failures + 1))
}
# indent: shows a block of output under its check, indented.
indent() { sed 's/^/       | /'; }

version_ge() { # version_ge A B: true when A >= B, both X.Y.Z
  local -a a b
  local i
  IFS=. read -ra a <<<"$1"
  IFS=. read -ra b <<<"$2"
  for i in 0 1 2; do
    if ((10#${a[i]} > 10#${b[i]})); then return 0; fi
    if ((10#${a[i]} < 10#${b[i]})); then return 1; fi
  done
  return 0
}

printf 'verifying %s as the %s app\n' "$image" "$app"

# ---- non-root -------------------------------------------------------------------------
check_non_root() {
  local user uid gid=''
  user=$(docker image inspect --format '{{.Config.User}}' "$image")
  if [[ $user =~ ^([0-9]+)(:([0-9]+))?$ ]]; then
    uid=${BASH_REMATCH[1]}
    gid=${BASH_REMATCH[3]:-}
    if ((10#$uid == 0)); then
      fail non-root "the image runs as uid 0 (User=$user)"
    elif [[ -z $gid ]]; then
      fail non-root "User=$user names no group, and a uid that has no entry in the image's /etc/passwd runs with gid 0 (write USER $uid:<gid>)"
    elif ((10#$gid == 0)); then
      fail non-root "the image runs with gid 0 (User=$user)"
    else
      pass non-root "User=$user"
    fi
  elif [[ -z $user ]]; then
    fail non-root 'the image sets no User, so it runs as root'
  else
    fail non-root "User=$user is a name, not a numeric uid"
  fi
}
check_non_root

# ---- the filesystem, exported once for the shell, forbidden-files and size checks ----------
fs_ok=0
cid=$(docker create "$image" 2>"$work/create.err") || cid=''
if [[ -n $cid ]]; then
  containers+=("$cid")
  if docker export "$cid" >"$work/fs.tar" 2>"$work/export.err" &&
    tar -tf "$work/fs.tar" >"$work/list.txt" 2>"$work/tar.err" &&
    [[ $(wc -l <"$work/list.txt") -ge 50 ]]; then
    fs_ok=1
  fi
fi
if ((!fs_ok)); then
  printf 'could not read the image filesystem:\n' >&2
  cat "$work/create.err" "$work/export.err" "$work/tar.err" 2>/dev/null | indent >&2
fi

# ---- no-shell -------------------------------------------------------------------------
check_no_shell() {
  local found out rc=0 status_ok=1
  if ((fs_ok)); then
    # Entries that are not directories (a directory's entry ends in "/") named like a shell.
    found=$(grep -E '(^|/)(sh|bash|dash|ash|zsh|ksh|csh|tcsh|fish|busybox)$' "$work/list.txt" || true)
    if [[ -n $found ]]; then
      fail no-shell "a shell is in the filesystem: $(printf '%s' "$found" | head -n 5 | tr '\n' ' ')"
      status_ok=0
    fi
  else
    fail no-shell 'the filesystem could not be listed'
    status_ok=0
  fi
  out=$(docker run --rm --entrypoint /bin/sh "$image" -c 'echo a-shell-ran' 2>&1) || rc=$?
  if ((rc == 0)); then
    fail no-shell "/bin/sh started and ran a command: $out"
  elif ((rc == 126 || rc == 127)) && grep -qiE 'no such file|not found' <<<"$out"; then
    ((status_ok)) && pass no-shell '/bin/sh cannot be started and no shell is in the filesystem'
  else
    fail no-shell "/bin/sh failed in an unexpected way (exit $rc): $out"
  fi
}
check_no_shell

# ---- node-version ---------------------------------------------------------------------
check_node_version() {
  local out v
  out=$(docker run --rm "$image" --version 2>&1) || {
    fail node-version "\`--version\` did not run: $out"
    return
  }
  v=${out##*$'\n'}
  if [[ $v =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
    if version_ge "${BASH_REMATCH[1]}" "$MIN_NODE"; then
      pass node-version "$v (at least $MIN_NODE)"
    else
      fail node-version "$v is older than $MIN_NODE"
    fi
  else
    fail node-version "\`--version\` printed '$out', not a Node version"
  fi
}
check_node_version

# ---- forbidden files ------------------------------------------------------------------
check_forbidden() {
  local found
  if ((!fs_ok)); then
    fail forbidden 'the filesystem could not be listed'
    return
  fi
  # Any path component: .git, .cache, .env*, *.test.*, *.spec.*; and a folder (an entry that ends
  # in "/") called __tests__, test or tests. A file called "test" is not a test folder.
  found=$(grep -E '(^|/)((\.git|\.cache|\.env[^/]*|[^/]*\.test\.[^/]*|[^/]*\.spec\.[^/]*)(/|$)|(__tests__|tests?)/)' \
    "$work/list.txt" || true)
  if [[ -z $found ]]; then
    pass forbidden "none of .env*, .git, *.test.*, *.spec.*, .cache, __tests__, test, tests in $(wc -l <"$work/list.txt" | tr -d ' ') entries"
  else
    fail forbidden "$(printf '%s\n' "$found" | wc -l | tr -d ' ') forbidden entries, for example:"
    printf '%s\n' "$found" | head -n 10 | indent
  fi
}
check_forbidden

# ---- esbuild ------------------------------------------------------------------------------
# esbuild is a build tool that Strapi's admin build and Vite pull in. Its native binary is a Go
# program, so it brings the Go standard library's advisories into the image, and the app never
# starts it. The Dockerfiles delete it; this proves it. Every file (not folder, not link) whose
# path has an esbuild component is read, because a binary can be renamed or moved inside the
# package; the file counts when it starts with the ELF magic bytes. A JavaScript wrapper called
# esbuild is not an ELF and does not count.
check_esbuild() {
  local f magic found='' n=0
  if ((!fs_ok)); then
    fail esbuild 'the filesystem could not be listed'
    return
  fi
  grep -E '(^|/)[^/]*esbuild[^/]*(/|$)' "$work/list.txt" | grep -v '/$' >"$work/esbuild.list" || true
  if [[ -s $work/esbuild.list ]]; then
    mkdir "$work/esbuild"
    # A link that cannot be made here is not a file to read; whatever tar says goes to a file.
    tar -xf "$work/fs.tar" -C "$work/esbuild" --no-same-owner -T "$work/esbuild.list" 2>"$work/esbuild.err" || true
    while IFS= read -r f; do
      [[ -f $work/esbuild/$f && ! -L $work/esbuild/$f ]] || continue
      n=$((n + 1))
      magic=$(head -c 4 "$work/esbuild/$f" | od -An -tx1 | tr -d ' \n')
      if [[ $magic == 7f454c46 ]]; then found+="$f"$'\n'; fi
    done <"$work/esbuild.list"
  fi
  if [[ -z $found ]]; then
    pass esbuild "no ELF binary among the $n files under an esbuild path"
  else
    fail esbuild "$(printf '%s' "$found" | wc -l | tr -d ' ') ELF binary(ies) under an esbuild path, for example:"
    printf '%s' "$found" | head -n 10 | indent
  fi
}
check_esbuild

# ---- size -----------------------------------------------------------------------------
check_size() {
  local bytes reported
  if ((!fs_ok)); then
    fail size 'the filesystem could not be measured'
    return
  fi
  bytes=$(wc -c <"$work/fs.tar" | tr -d ' ')
  reported=$(docker image inspect --format '{{.Size}}' "$image")
  if ((bytes < max_bytes)); then
    pass size "$((bytes / 1048576)) MiB of filesystem, limit $((max_bytes / 1048576)) MiB (image store reports $((reported / 1048576)) MiB)"
  else
    fail size "$((bytes / 1048576)) MiB of filesystem is not under the limit of $((max_bytes / 1048576)) MiB"
  fi
}
check_size

# ---- the sandbox the Quadlet files apply ------------------------------------------------
sandbox=(
  --read-only
  --cap-drop ALL
  --security-opt no-new-privileges
  --tmpfs "/tmp:rw,noexec,nosuid,size=64m"
  --memory "$memory" --memory-swap "$memory"
  --pids-limit "$pids"
)
app_env=(-e HOST=0.0.0.0 -e "PORT=$port" -e "NODE_OPTIONS=--max-old-space-size=$heap")

# ---- the CMS needs its database and secrets ---------------------------------------------
cms_ready=1
if [[ $app == cms ]]; then
  db_name="oc_verify_$(random 10)"
  db_user="ocv_$(random 10)"
  db_password=$(random 24)
  # A subshell, so the strict umask covers this one file and cannot outlive it: the caller's own
  # umask is what applies to everything else the verifier makes.
  (
    umask 077
    {
      printf 'APP_KEYS=%s,%s,%s,%s\n' "$(random 22)" "$(random 22)" "$(random 22)" "$(random 22)"
      printf 'API_TOKEN_SALT=%s\n' "$(random 22)"
      printf 'ADMIN_JWT_SECRET=%s\n' "$(random 22)"
      printf 'JWT_SECRET=%s\n' "$(random 22)"
      printf 'TRANSFER_TOKEN_SALT=%s\n' "$(random 22)"
      printf 'ENCRYPTION_KEY=%s\n' "$(random 22)"
      printf 'DATABASE_CLIENT=mysql\nDATABASE_HOST=%s\nDATABASE_PORT=%s\n' "$db_host" "$db_port"
      printf 'DATABASE_NAME=%s\nDATABASE_USERNAME=%s\nDATABASE_PASSWORD=%s\nDATABASE_SSL=false\n' \
        "$db_name" "$db_user" "$db_password"
    } >"$work/cms.env"
  )
  app_env+=(--env-file "$(host_path "$work/cms.env")" --add-host host.docker.internal:host-gateway)
  # The app's own account sees only its own throwaway database, as in production.
  if ! sql_out=$(sql_create | db_sql 2>&1); then
    cms_ready=0
    db_name=''
    printf 'cannot reach the database at %s:%s as %s:\n' "$db_host" "$db_port" "$db_admin_user" >&2
    printf '%s\n' "$sql_out" | indent >&2
    printf '  start it with: docker compose -f docker-compose.dev.yml up -d\n' >&2
  fi
fi

# ---- healthcheck control ----------------------------------------------------------------
check_healthcheck_control() {
  local out rc=0
  out=$(docker run --rm "${sandbox[@]}" -e "PORT=$port" --entrypoint "$NODE_BIN" "$image" "$HEALTHCHECK_JS" 2>&1) || rc=$?
  if ((rc == 1)) && ! grep -qiE 'cannot find module|MODULE_NOT_FOUND' <<<"$out"; then
    pass healthcheck "exits 1 when nothing listens on port $port"
  else
    fail healthcheck "expected exit 1 with nothing listening, got exit $rc: $out"
  fi
}
check_healthcheck_control

# ---- run it under the sandbox -----------------------------------------------------------
# run_sandboxed ID [docker run options]: starts the app and waits for its health check.
run_sandboxed() {
  local id=$1
  shift
  local name="oc-verify-$app-$$-$id" state deadline probe out
  if ((!cms_ready)); then
    fail "$id" 'the database is not reachable, so the CMS could not be started'
    return
  fi
  containers+=("$name")
  if ! docker run -d --name "$name" "${sandbox[@]}" "${app_env[@]}" "$@" "$image" >"$work/$id.out" 2>&1; then
    fail "$id" 'docker could not start the container'
    indent <"$work/$id.out"
    return
  fi
  deadline=$((SECONDS + start_timeout))
  while ((SECONDS < deadline)); do
    state=$(docker inspect --format '{{.State.Status}}' "$name")
    if [[ $state != running ]]; then
      fail "$id" "the container stopped ($state, exit $(docker inspect --format '{{.State.ExitCode}}' "$name")); its log ends:"
      docker logs --tail 20 "$name" 2>&1 | indent
      return
    fi
    if docker exec "$name" "$NODE_BIN" "$HEALTHCHECK_JS" >/dev/null 2>&1; then
      # What the running process sees. That the root is read-only is read from /proc/mounts (the
      # mount's own options): a refused write to /app proves less, because /app belongs to root
      # and a process that is not root cannot write there on a writable root either. The write to
      # /app stays as the check that the code folder is not the process's to change.
      # Capabilities and no-new-privileges are asked for in $sandbox but are not read back here.
      probe='const fs=require("fs");
        if (process.getuid()===0) { console.log("running as root"); process.exit(1); }
        const root=fs.readFileSync("/proc/mounts","utf8").split("\n").map((l)=>l.split(" ")).filter((m)=>m[1]==="/").pop();
        if (!root) { console.log("/proc/mounts has no entry for the root filesystem"); process.exit(1); }
        if (!root[3].split(",").includes("ro")) { console.log("the root filesystem is mounted read-write (/proc/mounts: "+root[3]+")"); process.exit(1); }
        try { fs.writeFileSync("/app/.write-probe","x"); console.log("/app is writable"); process.exit(1); } catch {}
        try { fs.writeFileSync("/tmp/.write-probe","x"); } catch { console.log("/tmp is not writable"); process.exit(1); }'
      if out=$(docker exec "$name" "$NODE_BIN" -e "$probe" 2>&1); then
        pass "$id" "healthy within $((SECONDS - deadline + start_timeout)) s; not root, root filesystem read-only (/proc/mounts), /app not writable, /tmp writable"
      else
        fail "$id" "healthy, but the sandbox is not what it should be: $out"
      fi
      docker rm -f "$name" >/dev/null 2>&1 || true
      return
    fi
    sleep 1
  done
  fail "$id" "no healthy answer within $start_timeout s; the log ends:"
  docker logs --tail 20 "$name" 2>&1 | indent
}

run_sandboxed read-only
run_sandboxed keep-id --user "$KEEP_ID_USER"

if ((failures)); then
  printf 'RESULT: %s check(s) failed for %s\n' "$failures" "$image"
  exit 1
fi
printf 'RESULT: every check passed for %s\n' "$image"
