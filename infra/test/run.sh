#!/usr/bin/env bash
# Tests the server setup in a throwaway Ubuntu 24.04 container.
#
#   bash infra/test/run.sh               full run: bootstrap twice, verify, idempotence, extras
#   bash infra/test/run.sh verify-only   verify.sh on a bare system: every check must FAIL
#   bash infra/test/run.sh shellcheck    shellcheck on every script, in the container
#
# Needs Docker. The first full run takes several minutes (it installs the real packages);
# nothing is installed on your machine.
set -euo pipefail

# Git Bash on Windows would rewrite /opt/... arguments for docker.exe.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
infra=$(cd -- "$here/.." && pwd)
mode=${1:-full}
image=oc-infra-test:local

case $mode in
  full | verify-only | shellcheck) ;;
  *)
    printf 'usage: bash infra/test/run.sh [full|verify-only|shellcheck]\n' >&2
    exit 2
    ;;
esac

command -v docker >/dev/null 2>&1 || {
  printf 'docker is required\n' >&2
  exit 1
}
docker info >/dev/null 2>&1 || {
  printf 'the Docker daemon is not running\n' >&2
  exit 1
}

cd "$infra"
printf '==> building %s\n' "$image"
docker build --quiet --tag "$image" --file test/Dockerfile . >/dev/null

printf '==> running: %s\n' "$mode"
# --init reaps the helper processes the test starts (MariaDB, sshd, Nginx).
exec docker run --rm --init "$image" bash /opt/oc-infra/test/container-run.sh "$mode"
