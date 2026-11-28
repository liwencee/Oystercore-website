#!/usr/bin/env bash
# Tests verify-image.sh itself: it must pass a good image, and fail an image that is wrong in
# each way it exists to catch, and say which check failed. (A verifier that has never been seen
# to fail proves nothing.) Needs Docker. It builds a few tiny throwaway images (a small HTTP
# server on the distroless base the real images use), and removes them again.
#
#   bash infra/images/verify-image.test.sh
set -euo pipefail

export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
verifier="$here/verify-image.sh"
work=$(mktemp -d)
built=()

# The bases of the test images. Pinned like the real ones, so the test does not change by itself.
# distroless12 is the Debian 12 variant, whose Node (22.22.0) is too old: a control for the version check.
readonly distroless13='gcr.io/distroless/nodejs22-debian13:nonroot@sha256:c73ddeb03e1dc2d579aa111c83d6699c6b8b487e35c0c631d4a3a20229fc25ee'
readonly distroless12='gcr.io/distroless/nodejs22-debian12:nonroot@sha256:13593b7570658e8477de39e2f4a1dd25db2f836d68a0ba771251572d23bb4f8e'
readonly node_slim='node:22-bookworm-slim@sha256:be979e5523c76fa4d5ca4ebd3099078f220aa47ec39c48ad5b5df9314debd6eb'

cleanup() {
  local i
  if ((${#built[@]})); then
    for i in "${built[@]}"; do docker rmi -f "$i" >/dev/null 2>&1 || true; done
  fi
  rm -rf "$work"
}
trap cleanup EXIT

# Windows Git Bash gives docker.exe a Windows path; elsewhere the path is already right.
host_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

failed=0
ok() { printf 'ok     - %s\n' "$*"; }
notok() {
  printf 'NOT OK - %s\n' "$*"
  failed=$((failed + 1))
}

# An image the test hands to the verifier by its registry name (not one the test built itself)
# has to be fetched by the test: the verifier refuses an image that is not in the local store
# (exit 2), and a runner starts with an empty store. A `FROM` line pulls by itself; `docker run`
# and the verifier do not. So the test pulls such an image first (quietly, and stops at once if
# the pull fails), and run_verifier refuses to run one the test never pulled, which is what made
# this test pass on a machine with a warm cache and fail on a clean runner.
pulled=(none)
pull_image() {
  if ! docker pull --quiet "$1" >/dev/null; then
    printf 'NOT OK - could not pull %s (the test needs it)\n' "$1" >&2
    exit 1
  fi
  pulled+=("$1")
}

# run_verifier ARGS...: runs the verifier, keeps its output in $out and its exit status in $rc.
# A short start timeout keeps the cases that are meant to fail from waiting a minute each.
run_verifier() {
  local p seen=0
  if [[ ${1:-} == *@sha256:* ]]; then
    for p in "${pulled[@]}"; do [[ $p == "$1" ]] && seen=1; done
    ((seen)) || notok "run_verifier was given $1, which this test never pulled: it would pass only where that image is already cached"
  fi
  rc=0
  out=$(OC_VERIFY_START_TIMEOUT=20 OC_VERIFY_MIN_PACKAGES="${OC_VERIFY_MIN_PACKAGES-0}" bash "$verifier" "$@" 2>&1) || rc=$?
}

# expect_line TEXT: the verifier's output must contain a line that starts with TEXT.
expect_line() {
  if grep -q "^$1" <<<"$out"; then ok "output has: $1"; else
    notok "output lacks a line starting '$1'"
    printf '%s\n' "$out" | sed 's/^/         | /' | head -n 40
  fi
}

# expect_exit N: the verifier must have exited with N.
expect_exit() {
  if ((rc == $1)); then ok "exit $1"; else
    notok "exit $rc, expected $1"
    printf '%s\n' "$out" | sed 's/^/         | /' | head -n 40
  fi
}

# expect_text TEXT: the verifier's output must contain TEXT (anywhere), to show that a check
# failed for its stated reason and not for another.
expect_text() {
  if grep -qF -- "$1" <<<"$out"; then ok "output says: $1"; else
    notok "output does not say '$1'"
    printf '%s\n' "$out" | sed 's/^/         | /' | head -n 40
  fi
}

# A stand-in for `docker`, put in front of the real one on PATH for the runs that need to see or
# change what the verifier asks Docker to do. It passes everything on to the real docker, except:
#   SHIM_FAKE_DB=1     the database client container (the `mariadb --protocol=tcp -h HOST` run)
#                      is not started: the SQL is read and dropped, and the host is logged, so a
#                      CMS run needs no database;
#   SHIM_ROOT_RW=1     `--read-only` is taken out of every `docker run`, which is the one fault a
#                      read-only check must catch and an image cannot cause by itself.
# For each detached run (the app) it logs the umask the verifier had and the mode of the --env-file,
# and keeps a copy of that file (throwaway values; the verifier deletes the original at its end).
real_docker=$(command -v docker)
mkdir "$work/shim"
shimlog="$work/shim.log"
shimenv="$work/shim.env"
cat >"$work/shim/docker" <<'SHIM'
#!/usr/bin/env bash
set -u
args=("$@")
if [[ ${1:-} == run ]]; then
  detached=0 db=0 host='' envfile=''
  for ((i = 0; i < ${#args[@]}; i++)); do
    case ${args[i]} in
      -d) detached=1 ;;
      --protocol=tcp) db=1 ;;
      -h) host=${args[i + 1]:-} ;;
      --env-file) envfile=${args[i + 1]:-} ;;
    esac
  done
  if ((db && ${SHIM_FAKE_DB:-0})); then
    printf 'db-client host=%s\n' "$host" >>"$SHIM_LOG"
    cat >/dev/null
    exit 0
  fi
  if ((detached)); then
    printf 'app-run umask=%s\n' "$(umask)" >>"$SHIM_LOG"
    if [[ -n $envfile ]]; then
      if command -v cygpath >/dev/null 2>&1; then envfile=$(cygpath -u "$envfile"); fi
      printf 'env-file mode=%s\n' "$(stat -c %a "$envfile")" >>"$SHIM_LOG"
      cp "$envfile" "$SHIM_ENV_COPY"
    fi
    if [[ ${SHIM_ROOT_RW:-0} == 1 ]]; then
      keep=()
      for a in "${args[@]}"; do [[ $a == --read-only ]] || keep+=("$a"); done
      args=("${keep[@]}")
    fi
  fi
fi
exec "$SHIM_REAL_DOCKER" "${args[@]}"
SHIM
chmod +x "$work/shim/docker"

# A stand-in for `tar`, next to the one for docker, for the esbuild check (it extracts a few files
# from the exported filesystem and reads them). It passes everything on to the real tar, except
# the extraction (`tar -xf`), which SHIM_TAR_MODE spoils the two ways it can go wrong:
#   fail    tar says "Cannot hard link", extracts nothing and exits 2;
#   short   tar extracts everything and exits 0, but one extracted file is gone afterwards (as if
#           it had never landed on disk).
# An image cannot cause either; a verifier that treats "could not read" as "nothing found" would
# pass an image that has an esbuild binary in it.
real_tar=$(command -v tar)
cat >"$work/shim/tar" <<'SHIM'
#!/usr/bin/env bash
set -u
extract=0 dir=''
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case ${args[i]} in
    -xf) extract=1 ;;
    -C) dir=${args[i + 1]:-} ;;
  esac
done
if ((extract)); then
  case ${SHIM_TAR_MODE:-pass} in
    fail)
      printf "tar: esbuild/bin/esbuild: Cannot hard link to 'app/other/esbuild': No such file or directory\n" >&2
      exit 2
      ;;
    short)
      "$SHIM_REAL_TAR" "$@"
      rc=$?
      first=$(find "$dir" -type f | sed -n '1p')
      [[ -z $first ]] || rm -f "$first"
      exit "$rc"
      ;;
  esac
fi
exec "$SHIM_REAL_TAR" "$@"
SHIM
chmod +x "$work/shim/tar"

# run_verifier_shim ARGS...: run_verifier, with the stand-ins in front. SHIM_* and OC_VERIFY_*
# settings put before the call reach it.
run_verifier_shim() {
  rc=0
  : >"$shimlog"
  rm -f "$shimenv"
  out=$(PATH="$work/shim:$PATH" SHIM_REAL_DOCKER=$real_docker SHIM_REAL_TAR=$real_tar SHIM_LOG=$shimlog SHIM_ENV_COPY=$shimenv \
    OC_VERIFY_START_TIMEOUT=20 OC_VERIFY_MIN_PACKAGES="${OC_VERIFY_MIN_PACKAGES-0}" bash "$verifier" "$@" 2>&1) || rc=$?
}

# shim_lines PREFIX / shim_env_database: what the shim saw, on one line, for a failure message.
shim_lines() { grep "^$1" "$shimlog" 2>/dev/null | tr '\n' ' '; }
shim_env_database() { grep -E '^DATABASE_(HOST|PORT)=' "$shimenv" 2>&1 | tr '\n' ' '; }

# expect_log TEXT: the shim's log must have a line that starts with TEXT (and the log must exist,
# which shows the shim was in front of the verifier's docker at all).
expect_log() {
  if grep -q "^$1" "$shimlog" 2>/dev/null; then ok "shim log has: $1"; else
    notok "shim log lacks a line starting '$1'; it holds: $(tr '\n' '|' <"$shimlog" 2>/dev/null)"
  fi
}

# ---- the verifier is strict about how it is called --------------------------------------
run_verifier
expect_exit 2
run_verifier oc-no-such-image:never web
expect_exit 2
if grep -q 'no such image' <<<"$out"; then ok 'a missing image is reported'; else notok "a missing image: $out"; fi

# ---- RED: the plain Node image is root, has a shell and has no health check --------------
# node:22-bookworm-slim is a normal Node image. The verifier must fail it on the non-root,
# no-shell and read-only checks, and pass what is true of it (its Node is new enough).
pull_image "$node_slim"
run_verifier "$node_slim" web
expect_exit 1
expect_line 'FAIL non-root'
expect_line 'FAIL no-shell'
expect_line 'FAIL read-only'
expect_line 'PASS node-version'

# ---- test images --------------------------------------------------------------------------
mkdir -p "$work/ctx"
cp "$here/../../apps/web/healthcheck.mjs" "$work/ctx/healthcheck.mjs"
# A server that answers /healthz with $STATUS.
cat >"$work/ctx/server.mjs" <<'EOF'
import { createServer } from 'node:http';
const status = Number(process.env.STATUS ?? 200);
createServer((req, res) => {
  res.statusCode = req.url === '/healthz' ? status : 404;
  res.end('ok');
}).listen(Number(process.env.PORT), process.env.HOST);
EOF
# A health check that always says yes, however broken the app.
printf 'process.exit(0);\n' >"$work/ctx/always-ok.mjs"

# build NAME [docker build options]: builds the test image from the Dockerfile on stdin.
build() {
  local name=$1
  shift
  docker build -q -t "oc-verify-test-$name:test" "$@" -f - "$(host_path "$work/ctx")" >/dev/null
  built+=("oc-verify-test-$name:test")
}

# The base of every test image: what the real images are, in miniature.
good_dockerfile() {
  cat <<EOF
FROM ${1:-$distroless13}
COPY server.mjs healthcheck.mjs /app/
WORKDIR /app
USER ${2:-65532:65532}
ARG STATUS=200
ENV STATUS=\$STATUS NODE_ENV=production
CMD ["/app/server.mjs"]
EOF
}

# ---- GREEN: a good image passes every check ------------------------------------------------
good_dockerfile | build good
run_verifier oc-verify-test-good:test web
expect_exit 0
for id in non-root no-shell node-version forbidden esbuild size healthcheck read-only keep-id; do expect_line "PASS $id"; done

# ---- each fault is caught, by the check that is meant to catch it ----------------------------
good_dockerfile "$distroless13" 0 | build root
run_verifier oc-verify-test-root:test web
expect_exit 1
expect_line 'FAIL non-root'

good_dockerfile "$distroless13" nonroot | build named-user
run_verifier oc-verify-test-named-user:test web
expect_exit 1
expect_line 'FAIL non-root'

# An /app made by WORKDIR belongs to the user in force at that moment (the base image's 65532,
# whatever order USER and WORKDIR come in), so the process could replace the files in it:
# root-owned files do not help, the folder's owner may rename and delete them. Every other test
# image here makes /app with a root-owned COPY first, as the real images now do. The keep-id run
# has another uid and still passes, which shows the check is about the owner.
{
  printf 'FROM %s\nUSER 65532:65532\nWORKDIR /app\nCOPY server.mjs healthcheck.mjs ./\nCMD ["/app/server.mjs"]\n' "$distroless13"
} | build app-owned
run_verifier oc-verify-test-app-owned:test web
expect_exit 1
expect_line 'FAIL read-only'
expect_text 'belongs to the user the process runs as'
expect_line 'PASS keep-id'

# A uid with no group named. The distroless base has a passwd entry for 65532, so that process
# really gets gid 65532, but the verifier does not rely on the base's /etc/passwd: it wants the
# gid written down.
good_dockerfile "$distroless13" 65532 | build no-gid
run_verifier oc-verify-test-no-gid:test web
expect_exit 1
expect_line 'FAIL non-root'
expect_text 'names no group'

# The reason for that rule, shown and not only claimed: a uid that has no passwd entry and no
# group named runs with gid 0 (and group 0 among its groups).
good_dockerfile "$distroless13" 65533 | build no-entry
gid_seen=$(docker run --rm --entrypoint /nodejs/bin/node oc-verify-test-no-entry:test -e 'process.stdout.write(process.getgid() + ":" + process.getgroups())')
if [[ $gid_seen == '0:0' ]]; then ok 'a uid with no passwd entry and no gid runs with gid 0'; else notok "uid 65533 with no gid ran with gid:groups $gid_seen, expected 0:0"; fi
run_verifier oc-verify-test-no-entry:test web
expect_exit 1
expect_line 'FAIL non-root'
expect_text 'names no group'

# A named gid that is root's.
good_dockerfile "$distroless13" 65532:0 | build gid-zero
run_verifier oc-verify-test-gid-zero:test web
expect_exit 1
expect_line 'FAIL non-root'
expect_text 'gid 0'

# An older Node: the check on the Node version.
good_dockerfile "$distroless12" | build old-node
run_verifier oc-verify-test-old-node:test web
expect_exit 1
expect_line 'FAIL node-version'
expect_line 'PASS non-root'

# An unhealthy app: the server answers /healthz with 500.
good_dockerfile | build unhealthy --build-arg STATUS=500
run_verifier oc-verify-test-unhealthy:test web
expect_exit 1
expect_line 'FAIL read-only'
expect_line 'FAIL keep-id'

# A health check that always says yes is not a health check.
{
  good_dockerfile
  printf 'COPY always-ok.mjs /app/healthcheck.mjs\n'
} | build always-ok
run_verifier oc-verify-test-always-ok:test web
expect_exit 1
expect_line 'FAIL healthcheck'

# A shell in the image.
{
  printf 'FROM %s AS donor\nFROM %s\n' "$node_slim" "$distroless13"
  printf 'COPY --from=donor /bin/dash /bin/sh\n'
  printf 'COPY server.mjs healthcheck.mjs /app/\nWORKDIR /app\nUSER 65532:65532\nCMD ["/app/server.mjs"]\n'
} | build shell
run_verifier oc-verify-test-shell:test web
expect_exit 1
expect_line 'FAIL no-shell'

# Files that must never be in an image: an .env, a .git folder, tests, a .cache folder.
{
  printf 'FROM %s AS plant\nUSER node\n' "$node_slim"
  printf 'RUN mkdir -p /home/node/p/.git /home/node/p/.cache /home/node/p/lib \\\n'
  printf ' && touch /home/node/p/.env /home/node/p/.env.production /home/node/p/.git/HEAD /home/node/p/.cache/x \\\n'
  printf ' /home/node/p/lib/a.test.js /home/node/p/lib/b.spec.ts\n'
  printf 'FROM %s\nCOPY server.mjs healthcheck.mjs /app/\nWORKDIR /app\nUSER 65532:65532\n' "$distroless13"
  printf 'COPY --from=plant /home/node/p /app/p\nCMD ["/app/server.mjs"]\n'
} | build forbidden
run_verifier oc-verify-test-forbidden:test web
expect_exit 1
expect_line 'FAIL forbidden'
for name in '\.env$' '\.env\.production' '\.git/HEAD' '\.cache/x' 'a\.test\.js' 'b\.spec\.ts'; do
  if grep -qE "^ +\| .*$name" <<<"$out"; then ok "forbidden lists $name"; else notok "forbidden does not list $name"; fi
done

# Test folders, which dependencies ship (a lone `test` or `tests` or `__tests__` folder, in any
# package), are forbidden too.
{
  printf 'FROM %s AS plant\nUSER node\n' "$node_slim"
  printf 'RUN mkdir -p /home/node/p/a/test /home/node/p/b/__tests__ /home/node/p/c/tests \\\n'
  printf ' && touch /home/node/p/a/test/x.js /home/node/p/b/__tests__/y.js /home/node/p/c/tests/z.js\n'
  printf 'FROM %s\nCOPY server.mjs healthcheck.mjs /app/\nWORKDIR /app\nUSER 65532:65532\n' "$distroless13"
  printf 'COPY --from=plant /home/node/p /app/p\nCMD ["/app/server.mjs"]\n'
} | build testdirs
run_verifier oc-verify-test-testdirs:test web
expect_exit 1
expect_line 'FAIL forbidden'
for name in 'a/test/' 'b/__tests__/' 'c/tests/'; do
  if grep -qF "$name" <<<"$out"; then ok "forbidden lists $name"; else notok "forbidden does not list $name"; fi
done

# A list of forbidden files too long for a pipe (1500 entries of about 100 bytes, over the 64 KiB
# a pipe holds) must be reported like a short one. The verifier shows only the first ten; with
# `head` the writer died of SIGPIPE, and under pipefail and errexit the verifier ended with exit
# 141 before it ran its other checks (found by running it on the real, unpruned CMS image).
{
  printf 'FROM %s AS plant\nUSER node\n' "$node_slim"
  printf 'RUN mkdir -p /home/node/p/a-folder-with-a-name-long-enough-to-fill-a-pipe-buffer-quickly \\\n'
  printf ' && cd /home/node/p/a-folder-with-a-name-long-enough-to-fill-a-pipe-buffer-quickly \\\n'
  # shellcheck disable=SC2016  # the $ signs are the Dockerfile shell's, not this one's
  printf ' && for i in $(seq 1 1500); do : > "a-file-with-a-long-name-for-the-sake-of-the-test-$i.test.js"; done\n'
  printf 'FROM %s\nCOPY server.mjs healthcheck.mjs /app/\nWORKDIR /app\nUSER 65532:65532\n' "$distroless13"
  printf 'COPY --from=plant /home/node/p /app/p\nCMD ["/app/server.mjs"]\n'
} | build manyfiles
run_verifier oc-verify-test-manyfiles:test web
expect_exit 1
expect_line 'FAIL forbidden'
expect_text '1500 forbidden entries'
expect_line 'RESULT: 1 check(s) failed'
expect_line 'PASS keep-id'

# (control) Names that only look like test folders are fine: folders called contest, latest and
# testing, a file called test, and a file called tests.js. The same image carries the esbuild
# look-alikes (below), so one run shows that neither check is too broad.
printf '#!/usr/bin/env node\nrequire("./main");\n' >"$work/ctx/esbuild-wrapper.js"
# Packages for the entrypoints check. The look-alikes (which must pass): one that says "test" only to
# exclude it ("!test" in files), and the one package and path on the known list ("ai", "./dist/test/").
printf '{"name":"fine","version":"1.0.0","main":"./lib/index.js","exports":{".":"./lib/index.js","./package.json":"./package.json"},"files":["lib","!test"]}\n' >"$work/ctx/fine-package.json"
printf '{"name":"ai","version":"6.0.0","exports":{"./test":{"import":"./dist/test/index.mjs","require":"./dist/test/index.js"}}}\n' >"$work/ctx/ai-package.json"
# The broken ones: every field the check reads, a scoped package, a path with no leading "./", and
# a package that is not on the known list but has a known path.
printf '{"name":"broken","version":"1.0.0","main":"./test/index.js","bin":{"x":"./tests/cli.js"},"exports":{"./util":{"import":"./__tests__/util.mjs"}},"files":["src","test"]}\n' >"$work/ctx/broken-package.json"
printf '{"name":"@scope/scoped","version":"2.0.0","module":"dist/__tests__/m.js"}\n' >"$work/ctx/scoped-package.json"
printf '{"name":"other","exports":{"./test":"./dist/test/index.js"}}\n' >"$work/ctx/other-package.json"
{
  printf 'FROM %s AS plant\nUSER node\n' "$node_slim"
  printf 'RUN mkdir -p /home/node/p/contest /home/node/p/latest /home/node/p/testing /home/node/p/bin \\\n'
  printf ' && touch /home/node/p/contest/a.js /home/node/p/latest/b.js /home/node/p/testing/c.js /home/node/p/bin/test /home/node/p/tests.js\n'
  printf 'FROM %s\nCOPY server.mjs healthcheck.mjs /app/\nWORKDIR /app\nUSER 65532:65532\n' "$distroless13"
  printf 'COPY --from=plant /home/node/p /app/p\n'
  # An ELF outside esbuild's folders, and a JavaScript file called esbuild inside them.
  printf 'COPY --from=plant /bin/true /app/p/bin/true\n'
  printf 'COPY esbuild-wrapper.js /app/node_modules/esbuild/bin/esbuild\n'
  printf 'COPY fine-package.json /app/node_modules/fine/package.json\n'
  printf 'COPY ai-package.json /app/node_modules/ai/package.json\nCMD ["/app/server.mjs"]\n'
} | build lookalikes
run_verifier oc-verify-test-lookalikes:test web
expect_exit 0
expect_line 'PASS forbidden'
expect_line 'PASS esbuild'
expect_line 'PASS entrypoints'
expect_text 'read 2 package.json files; 0 reference(s) into a test folder, 2 known test helper export(s) not counted'

# Entry points into a test folder, which the Dockerfiles remove: every field the check reads, a
# scoped package and a path without "./". The image has no test folder (it is as the prune leaves
# it), so only the package.json files say that something is gone. The known list is exact (package,
# field and path): a package that is not on it but uses a known path ("other"), and the known
# package with another path or in another field ("ai": ./dist/test/other.js, and bin ->
# ./dist/test/index.js) must fail too.
printf '{"name":"ai","version":"6.0.1","exports":{"./test":"./dist/test/other.js"},"bin":"./dist/test/index.js"}\n' >"$work/ctx/ai-wrong-package.json"
{
  printf 'FROM %s\nCOPY server.mjs healthcheck.mjs /app/\nWORKDIR /app\nUSER 65532:65532\n' "$distroless13"
  printf 'COPY broken-package.json /app/node_modules/broken/package.json\n'
  printf 'COPY scoped-package.json /app/node_modules/@scope/scoped/package.json\n'
  printf 'COPY ai-wrong-package.json /app/node_modules/ai/package.json\n'
  printf 'COPY other-package.json /app/node_modules/other/package.json\nCMD ["/app/server.mjs"]\n'
} | build entrypoints
run_verifier oc-verify-test-entrypoints:test web
expect_exit 1
expect_line 'FAIL entrypoints'
expect_text '(read 4 package.json files; 8 reference(s) into a test folder, 0 known test helper export(s) not counted)'
for name in 'broken@1.0.0: main -> ./test/index.js' 'broken@1.0.0: bin -> ./tests/cli.js' 'broken@1.0.0: exports -> ./__tests__/util.mjs' 'broken@1.0.0: files -> test' '@scope/scoped@2.0.0: module -> dist/__tests__/m.js' 'other@?: exports -> ./dist/test/index.js' 'ai@6.0.1: exports -> ./dist/test/other.js' 'ai@6.0.1: bin -> ./dist/test/index.js'; do
  if grep -qF "$name" <<<"$out"; then ok "entrypoints lists $name"; else notok "entrypoints does not list $name"; fi
done
expect_line 'PASS forbidden'

# A scan that cannot read does not pass; each of these must fail `entrypoints`, with the reason in
# the text, not only the exit status (the check used to say "read 0 package.json files" and pass).
# The floor is 0 in these runs unless the case sets it (the helpers above), because most test
# images have no dependencies; the cases that test the floor itself leave it empty, which means the
# verifier's own default (100 for the website, 400 for the CMS).
#  (1) no /app/node_modules at all, the floor at its default: the good image has none.
OC_VERIFY_MIN_PACKAGES='' run_verifier oc-verify-test-good:test web
expect_exit 1
expect_line 'FAIL entrypoints'
expect_text 'cannot read the folder /app/node_modules: ENOENT'
#  (2) one malformed (truncated) package.json among good ones.
printf '{"name":"x","main":"./test/a.js",' >"$work/ctx/trunc-package.json"
{
  printf 'FROM %s\nCOPY server.mjs healthcheck.mjs /app/\nWORKDIR /app\nUSER 65532:65532\n' "$distroless13"
  printf 'COPY fine-package.json /app/node_modules/fine/package.json\n'
  printf 'COPY trunc-package.json /app/node_modules/trunc/package.json\nCMD ["/app/server.mjs"]\n'
} | build ep-badjson
run_verifier oc-verify-test-ep-badjson:test web
expect_exit 1
expect_line 'FAIL entrypoints'
expect_text 'the scan could not run (exit 2)'
expect_text 'could not read or parse /app/node_modules/trunc/package.json'
#  (3) a folder the process cannot list (mode 000, owned by another user; the image runs as 65532).
{
  printf 'FROM %s AS plant\nUSER node\nRUN mkdir -p /home/node/p/locked && chmod 000 /home/node/p/locked\n' "$node_slim"
  printf 'FROM %s\nCOPY server.mjs healthcheck.mjs /app/\nWORKDIR /app\nUSER 65532:65532\n' "$distroless13"
  printf 'COPY fine-package.json /app/node_modules/fine/package.json\n'
  printf 'COPY --from=plant /home/node/p /app/node_modules\nCMD ["/app/server.mjs"]\n'
} | build ep-locked
run_verifier oc-verify-test-ep-locked:test web
expect_exit 1
expect_line 'FAIL entrypoints'
expect_text 'cannot read the folder /app/node_modules/locked: EACCES'
#  (4) fewer package.json files than the floor (the look-alike image has two): at the default floor
#      it fails and says why; at a floor of exactly two it passes (the control, and the boundary).
OC_VERIFY_MIN_PACKAGES='' run_verifier oc-verify-test-lookalikes:test web
expect_exit 1
expect_line 'FAIL entrypoints'
expect_text 'only 2 package.json files under /app/node_modules, fewer than the floor of 100 for this kind of image'
OC_VERIFY_MIN_PACKAGES=2 run_verifier oc-verify-test-lookalikes:test web
expect_exit 0
expect_line 'PASS entrypoints'

# An esbuild binary: the ELF that esbuild's install script leaves at node_modules/esbuild/bin/esbuild
# and the platform package's own, and one that was moved and renamed inside the package.
{
  printf 'FROM %s AS donor\nFROM %s\nCOPY server.mjs healthcheck.mjs /app/\nWORKDIR /app\nUSER 65532:65532\n' "$node_slim" "$distroless13"
  printf 'COPY --from=donor /bin/true /app/node_modules/@esbuild/linux-x64/bin/esbuild\n'
  printf 'COPY --from=donor /bin/true /app/node_modules/esbuild/lib/helper.bin\n'
  printf 'CMD ["/app/server.mjs"]\n'
} | build esbuild-elf
run_verifier oc-verify-test-esbuild-elf:test web
expect_exit 1
expect_line 'FAIL esbuild'
expect_text '2 ELF binary(ies) under an esbuild path'
for name in '@esbuild/linux-x64/bin/esbuild' 'esbuild/lib/helper.bin'; do
  if grep -qE "^ +\| .*$name" <<<"$out"; then ok "esbuild lists $name"; else notok "esbuild does not list $name"; fi
done

# A check that cannot read the files it must read does not pass. With the extraction spoiled
# (the stand-in for tar, above), the same image, which really has two esbuild binaries, must
# fail `esbuild` and say it could not read them, and show tar's own message; an extraction that
# exits 0 but lost a file (the count from the archive's listing is what notices) must fail too.
# The control is the look-alike image (one JavaScript file under an esbuild path) through the same
# stand-ins, with the extraction left alone: it still passes.
SHIM_TAR_MODE=fail run_verifier_shim oc-verify-test-esbuild-elf:test web
expect_exit 1
expect_line 'FAIL esbuild'
expect_text 'could not read the esbuild files: 0 of 2 files extracted and read (tar exit 0 when listing, 2 when extracting)'
expect_text 'Cannot hard link'
SHIM_TAR_MODE=short run_verifier_shim oc-verify-test-esbuild-elf:test web
expect_exit 1
expect_line 'FAIL esbuild'
expect_text 'could not read the esbuild files: 1 of 2 files extracted and read (tar exit 0 when listing, 0 when extracting)'
SHIM_TAR_MODE=pass run_verifier_shim oc-verify-test-lookalikes:test web
expect_exit 0
expect_line 'PASS esbuild  *no ELF binary among the 1 files under an esbuild path'

# The size limit: the same good image, under a limit that is too small.
OC_VERIFY_MAX_BYTES=1000000 run_verifier oc-verify-test-good:test web
expect_exit 1
expect_line 'FAIL size'

# ---- what the verifier asks Docker to do, seen through the stand-in for docker ------------------
# The root filesystem is proved read-only from inside the running container (/proc/mounts), not
# taken from the flag: with `--read-only` taken out, a good image must fail both runs. (Writing to
# /app is refused on a writable root too, because /app belongs to root: that is what the old
# check relied on.) The controls are the two CMS runs below, which have the stand-in in front too
# and must pass `read-only` and `keep-id`.
SHIM_ROOT_RW=1 run_verifier_shim oc-verify-test-good:test web
expect_exit 1
expect_line 'FAIL read-only'
expect_line 'FAIL keep-id'
expect_text 'mounted read-write'

# The strict umask the verifier uses for its secrets file ends with that file: the umask the
# caller had (0027 here, which is neither of the verifier's own two) is the one in force when
# the app is started, and (where the filesystem keeps modes) the secrets file is still private,
# mode 600. The same run is the control for the database host (the default,
# host.docker.internal) and shows that the stand-in alone does not make a good image fail.
# No database is needed: the stand-in drops the SQL.
old_umask=$(umask)
umask 0027
SHIM_FAKE_DB=1 run_verifier_shim oc-verify-test-good:test cms
umask "$old_umask"
expect_exit 0
expect_line 'PASS read-only'
expect_line 'PASS keep-id'
expect_log 'app-run umask=0027'
other_umasks=$(grep '^app-run' "$shimlog" | grep -vc 'umask=0027' || true)
if [[ $other_umasks == 0 ]]; then ok "every app run had the caller's umask"; else notok "$other_umasks app run(s) had another umask: $(shim_lines app-run)"; fi
# A filesystem that works a file's mode out from the umask of whoever asks (Git Bash on Windows)
# cannot show that the secrets file was made private, so the mode is checked only where it is kept.
( umask 077; : >"$work/mode-probe" )
if [[ $( (umask 0022; stat -c %a "$work/mode-probe") ) == 600 ]]; then
  expect_log 'env-file mode=600'
else
  printf 'skip   - the secrets file is mode 600: this filesystem does not keep file modes (CI, on Linux, checks it)\n'
fi
expect_log 'db-client host=host.docker.internal'
if grep -qx 'DATABASE_HOST=host.docker.internal' "$shimenv" 2>/dev/null; then ok '(control) the CMS gets DATABASE_HOST=host.docker.internal by default'; else notok "(control) no DATABASE_HOST=host.docker.internal in the env file: $(shim_env_database)"; fi

# The CMS gets the database host and port it was told, in the env file the verifier writes.
SHIM_FAKE_DB=1 OC_VERIFY_DB_HOST=db.example.test OC_VERIFY_DB_PORT=3999 run_verifier_shim oc-verify-test-good:test cms
expect_exit 0
expect_log 'db-client host=db.example.test'
if grep -qx 'DATABASE_HOST=db.example.test' "$shimenv" 2>/dev/null; then ok 'the CMS gets DATABASE_HOST from OC_VERIFY_DB_HOST'; else notok "the env file does not say DATABASE_HOST=db.example.test: $(shim_env_database)"; fi
if grep -qx 'DATABASE_PORT=3999' "$shimenv" 2>/dev/null; then ok 'the CMS gets DATABASE_PORT from OC_VERIFY_DB_PORT'; else notok 'the env file does not say DATABASE_PORT=3999'; fi

if ((failed)); then
  printf '\n%s check(s) of the verifier failed\n' "$failed"
  exit 1
fi
printf '\nverify-image.sh behaves as expected\n'
