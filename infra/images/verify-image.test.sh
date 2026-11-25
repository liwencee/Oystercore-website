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
readonly distroless13='gcr.io/distroless/nodejs22-debian13:nonroot@sha256:f991e86a080567b6ab7c3392e36f7a0a4f9300639e526b48ee81b92d523af62e'
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

# run_verifier ARGS...: runs the verifier, keeps its output in $out and its exit status in $rc.
# A short start timeout keeps the cases that are meant to fail from waiting a minute each.
run_verifier() {
  rc=0
  out=$(OC_VERIFY_START_TIMEOUT=20 bash "$verifier" "$@" 2>&1) || rc=$?
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

# ---- the verifier is strict about how it is called --------------------------------------
run_verifier
expect_exit 2
run_verifier oc-no-such-image:never web
expect_exit 2
if grep -q 'no such image' <<<"$out"; then ok 'a missing image is reported'; else notok "a missing image: $out"; fi

# ---- RED: the plain Node image is root, has a shell and has no health check --------------
# node:22-bookworm-slim is a normal Node image. The verifier must fail it on the non-root,
# no-shell and read-only checks, and pass what is true of it (its Node is new enough).
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
USER ${2:-65532}
WORKDIR /app
COPY server.mjs healthcheck.mjs ./
ARG STATUS=200
ENV STATUS=\$STATUS NODE_ENV=production
CMD ["/app/server.mjs"]
EOF
}

# ---- GREEN: a good image passes every check ------------------------------------------------
good_dockerfile | build good
run_verifier oc-verify-test-good:test web
expect_exit 0
for id in non-root no-shell node-version forbidden size healthcheck read-only keep-id; do expect_line "PASS $id"; done

# ---- each fault is caught, by the check that is meant to catch it ----------------------------
good_dockerfile "$distroless13" 0 | build root
run_verifier oc-verify-test-root:test web
expect_exit 1
expect_line 'FAIL non-root'

good_dockerfile "$distroless13" nonroot | build named-user
run_verifier oc-verify-test-named-user:test web
expect_exit 1
expect_line 'FAIL non-root'

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
  printf 'USER 65532\nWORKDIR /app\nCOPY server.mjs healthcheck.mjs ./\nCMD ["/app/server.mjs"]\n'
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
  printf 'FROM %s\nUSER 65532\nWORKDIR /app\nCOPY server.mjs healthcheck.mjs ./\n' "$distroless13"
  printf 'COPY --from=plant /home/node/p /app/p\nCMD ["/app/server.mjs"]\n'
} | build forbidden
run_verifier oc-verify-test-forbidden:test web
expect_exit 1
expect_line 'FAIL forbidden'
for name in '\.env$' '\.env\.production' '\.git/HEAD' '\.cache/x' 'a\.test\.js' 'b\.spec\.ts'; do
  if grep -qE "^ +\| .*$name" <<<"$out"; then ok "forbidden lists $name"; else notok "forbidden does not list $name"; fi
done

# The size limit: the same good image, under a limit that is too small.
OC_VERIFY_MAX_BYTES=1000000 run_verifier oc-verify-test-good:test web
expect_exit 1
expect_line 'FAIL size'

if ((failed)); then
  printf '\n%s check(s) of the verifier failed\n' "$failed"
  exit 1
fi
printf '\nverify-image.sh behaves as expected\n'
