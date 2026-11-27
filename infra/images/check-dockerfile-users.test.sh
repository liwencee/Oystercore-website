#!/usr/bin/env bash
# Tests check-dockerfile-users.sh on small Dockerfiles that are right and wrong in the ways it
# exists to catch. No Docker needed.
#
#   bash infra/images/check-dockerfile-users.test.sh
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
checker="$here/check-dockerfile-users.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failed=0
ok() { printf 'ok     - %s\n' "$*"; }
notok() {
  printf 'NOT OK - %s\n' "$*"
  failed=$((failed + 1))
}

# expect_pass NAME: the Dockerfile on stdin must pass.
expect_pass() {
  local name=$1 out
  cat >"$work/Dockerfile"
  if out=$(bash "$checker" "$work/Dockerfile" 2>&1); then ok "$name"; else
    notok "$name (it was rejected)"
    printf '%s\n' "$out" | sed 's/^/         | /'
  fi
}

# expect_fail NAME TEXT: the Dockerfile on stdin must be rejected, with TEXT in the message.
expect_fail() {
  local name=$1 text=$2 out rc=0
  cat >"$work/Dockerfile"
  out=$(bash "$checker" "$work/Dockerfile" 2>&1) || rc=$?
  if ((rc == 1)) && grep -qF -- "$text" <<<"$out"; then ok "$name"; else
    notok "$name (exit $rc, expected 1 with '$text')"
    printf '%s\n' "$out" | sed 's/^/         | /'
  fi
}

expect_pass 'two stages, USER first in each' <<'EOF'
FROM node:22 AS build
USER node
RUN echo build
FROM gcr.io/distroless/nodejs22-debian13:nonroot
USER 65532
COPY --from=build /x /x
EOF

expect_pass 'a stage built from a non-root stage inherits its user' <<'EOF'
FROM node:22 AS build
USER node
FROM build AS test
RUN echo test
FROM scratch
USER 65532
EOF

expect_pass 'comments, line continuations and mixed case' <<'EOF'
# syntax=docker/dockerfile:1
from node:22 as build
# a comment
user node:node
run echo one \
    && echo two
FROM scratch
USER 1000:1000
EOF

expect_fail 'RUN before USER' 'RUN before a non-root USER' <<'EOF'
FROM node:22
RUN echo as root
USER node
EOF

expect_fail 'a second stage that forgets USER' 'stage 2' <<'EOF'
FROM node:22 AS build
USER node
RUN echo ok
FROM node:22
RUN echo as root
EOF

expect_fail 'a final stage with no USER at all' 'never sets a non-root USER' <<'EOF'
FROM node:22 AS build
USER node
FROM gcr.io/distroless/nodejs22-debian13:nonroot
COPY --from=build /x /x
EOF

expect_fail 'USER root after a non-root USER' 'USER root is root' <<'EOF'
FROM node:22
USER node
USER root
RUN echo as root
EOF

expect_fail 'USER 0' 'USER 0 is root' <<'EOF'
FROM node:22
USER 0
EOF

expect_fail 'USER 0:0' 'USER 0:0 is root' <<'EOF'
FROM node:22
USER 0:0
EOF

expect_fail 'USER with a variable' 'uses a variable' <<'EOF'
FROM node:22
ARG WHO=root
USER ${WHO}
EOF

expect_fail 'a stage built from a root stage stays root' 'RUN before a non-root USER' <<'EOF'
FROM node:22 AS base
FROM base AS build
RUN echo as root
USER node
EOF

expect_fail 'an empty file' 'no FROM instruction' <<'EOF'
EOF

if out=$(bash "$checker" "$work/does-not-exist" 2>&1); then notok 'a missing file passed'; else
  if grep -q 'no such file' <<<"$out"; then ok 'a missing file is reported'; else notok "a missing file: $out"; fi
fi

# The real Dockerfiles must pass.
if out=$(bash "$checker" "$here"/../../apps/web/Dockerfile "$here"/../../apps/cms/Dockerfile 2>&1); then
  ok 'apps/web/Dockerfile and apps/cms/Dockerfile pass'
else
  notok 'the real Dockerfiles failed'
  printf '%s\n' "$out" | sed 's/^/         | /'
fi

if ((failed)); then
  printf '\n%s check(s) failed\n' "$failed"
  exit 1
fi
printf '\ncheck-dockerfile-users.sh behaves as expected\n'
