#!/usr/bin/env bash
# Structural checks on the two GitHub workflows (.github/workflows/ci.yml and deploy.yml), the ones
# actionlint cannot make:
#
#   1. every `uses:` names a full commit SHA (40 hex characters) with the version as a trailing
#      comment, never a tag: a tag can be moved to other code, a commit cannot;
#   2. every job that names an `environment:` (the deploy jobs, which are the ones that hold a key)
#      has a step with `if: always()` that removes the key file, in addition to the EXIT trap of the
#      step that writes it.
#
#   bash infra/deploy/workflow.test.sh                 the workflows of this repository
#   WORKFLOW_DIR=/some/folder bash ...                 another copy of them
#
# It needs only bash, awk, grep and sed. Inside the test container (which holds only infra/) there is
# no .github folder, and it says so and passes: infra/test/run.sh runs it on the host before the
# container starts. Each check is also tried on a deliberately broken copy, so it is known to be able
# to fail.
set -uo pipefail
export LC_ALL=C

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
DIR=${WORKFLOW_DIR:-$HERE/../../.github/workflows}
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

if [[ ! -f $DIR/ci.yml || ! -f $DIR/deploy.yml ]]; then
  printf 'skipped: there are no workflows in %s (this copy of the repository holds only infra/)\n' "$DIR"
  exit 0
fi

# pins_problems DIR: one line per `uses:` that is not a full SHA with a version comment
pins_problems() {
  local f
  for f in "$1"/ci.yml "$1"/deploy.yml; do
    grep -nE '^[[:space:]]*-?[[:space:]]*uses:' "$f" |
      grep -vE 'uses:[[:space:]]+[A-Za-z0-9._/-]+@[0-9a-f]{40}[[:space:]]+#[[:space:]]+v[0-9]' |
      sed "s|^|$(basename "$f"):|" || true
  done
}

# cleanup_problems DIR: one line per job with an environment that lacks the always() cleanup step
cleanup_problems() {
  awk '
    function finish() {
      if (job != "" && env && !cleanup) print fname ": the job " job " names an environment but has no `if: always()` step that removes the key file"
    }
    FNR == 1 { finish(); fname = FILENAME; job = ""; env = 0; cleanup = 0; injobs = 0 }
    /^jobs:/ { injobs = 1; next }
    injobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { finish(); job = $1; sub(/:$/, "", job); env = 0; cleanup = 0; next }
    job != "" && /^    environment:/ { env = 1 }
    job != "" && /^        if: always\(\)[[:space:]]*$/ { want = 1; next }
    want && /^        run: .*rm -rf.*deploy-ssh\./ { cleanup = 1 }
    { want = 0 }
    END { finish() }
  ' "$1"/deploy.yml "$1"/ci.yml
}

none() { # DESCRIPTION OUTPUT: ok when OUTPUT is empty
  if [[ -z $2 ]]; then ok "$1"; else
    notok "$1"
    printf '%s\n' "$2" | sed 's/^/         | /' | head -n 10
  fi
}
some() { # DESCRIPTION OUTPUT TEXT: ok when OUTPUT contains TEXT (the check can fail, and for the stated reason)
  if [[ $2 == *"$3"* ]]; then ok "$1 (found: $3)"; else
    notok "$1 (wanted '$3' in: ${2:0:200})"
  fi
}

none "every action in ci.yml and deploy.yml is pinned to a full commit SHA with a version comment" "$(pins_problems "$DIR")"
none "every job with an environment has an if: always() step that removes the key file" "$(cleanup_problems "$DIR")"

# the same checks on broken copies: each must be noticed
T=$(mktemp -d -t oc-workflow-test.XXXXXX)
trap 'rm -rf -- "$T"' EXIT
cp "$DIR/ci.yml" "$DIR/deploy.yml" "$T/"
sed -i '0,/uses: actions\/checkout@[0-9a-f]\{40\} # v7.0.1/s||uses: actions/checkout@v7|' "$T/ci.yml"
some "a tag instead of a SHA (actions/checkout@v7) is noticed" "$(pins_problems "$T")" "ci.yml:"
cp "$DIR/ci.yml" "$T/ci.yml"
sed -i '0,/uses: pnpm\/action-setup@[0-9a-f]\{40\} # v6.1.1/s||uses: pnpm/action-setup@73e46992e05b19abd31f2f3c20e0e7370d762115|' "$T/deploy.yml"
some "a SHA with no version comment is noticed" "$(pins_problems "$T")" "deploy.yml:"
cp "$DIR/deploy.yml" "$T/deploy.yml"
sed -i '0,/^        if: always()$/s//        if: success()/' "$T/deploy.yml"
some "a deploy job whose cleanup step is not always() is noticed" "$(cleanup_problems "$T")" "has no \`if: always()\` step that removes the key file"
cp "$DIR/deploy.yml" "$T/deploy.yml"
# shellcheck disable=SC2016  # a sed expression: the $ signs are sed's, not the shell's
sed -i 's|^        run: rm -rf -- "\$RUNNER_TEMP"/deploy-ssh\.\*$|        run: echo done|' "$T/deploy.yml"
some "an always() step that does not remove the key file is noticed" "$(cleanup_problems "$T")" "names an environment but has no"
cp "$DIR/deploy.yml" "$T/deploy.yml"
none "(control) the unbroken copies are accepted again" "$(pins_problems "$T")$(cleanup_problems "$T")"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
