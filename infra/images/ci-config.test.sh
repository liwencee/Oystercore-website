#!/usr/bin/env bash
# Structural checks on the settings around the images that no other tool makes: the workflow
# .github/workflows/ci.yml (checkout credentials, the Trivy options, the MariaDB images), the Trivy
# exceptions in .trivyignore.yaml, renovate.json, the packageManager line of the root package.json,
# and the wording of the comments that say how a security fix reaches an image.
#
#   bash infra/images/ci-config.test.sh                  this repository
#   CONFIG_ROOT=/some/folder bash ...                    another copy of it
#
# It needs bash, awk, grep, sed, date and node (node only reads renovate.json). It does not need
# Docker or the network. Each check is also tried on a deliberately broken copy, so it is known
# to be able to fail, and to fail for the stated reason.
set -uo pipefail
export LC_ALL=C

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=${CONFIG_ROOT:-$(cd -- "$HERE/../.." && pwd -P)}
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
none() { # DESCRIPTION OUTPUT: ok when OUTPUT is empty
  if [[ -z $2 ]]; then ok "$1"; else
    notok "$1"
    printf '%s\n' "$2" | sed 's/^/         | /' | head -n 10
  fi
}
some() { # DESCRIPTION OUTPUT TEXT: ok when OUTPUT contains TEXT (the check can fail, and for the stated reason)
  if [[ $2 == *"$3"* ]]; then ok "$1 (found: $3)"; else
    notok "$1 (wanted '$3' in: ${2:0:300})"
  fi
}

# ---- 1. every checkout drops the git credentials ---------------------------------------------------
# A job that checks out code and then runs other people's code (package install scripts, a build)
# must not leave the repository token in .git/config for them to read.
checkout_problems() { # ROOT: one line per actions/checkout step without persist-credentials: false
  local f
  for f in "$1"/.github/workflows/ci.yml "$1"/.github/workflows/deploy.yml; do
    awk -v name="$(basename "$f")" '
      function indent(s) { match(s, /^ */); return RLENGTH }
      function finish() { if (inco && !pc) print name ":" sline ": this actions/checkout step does not set persist-credentials: false" }
      /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
      { if (inco && indent($0) <= sind) { finish(); inco = 0 } }
      /^[[:space:]]*- uses:[[:space:]]+actions\/checkout@/ { inco = 1; pc = 0; sind = indent($0); sline = FNR; next }
      inco && /persist-credentials:[[:space:]]+false[[:space:]]*$/ { pc = 1 }
      END { finish() }
    ' "$f"
  done
}

# ---- 2. Trivy: a timeout, one cache for both scans, the YAML exceptions file ----------------------
trivy_problems() { # ROOT
  local ci=$1/.github/workflows/ci.yml cache ignore
  grep -qE -- '--timeout 15m([[:space:]]|$)' "$ci" || echo 'ci.yml: the Trivy scan has no --timeout 15m (the default is 5 minutes, short for the first download of the database and the larger image)'
  cache=$(sed -nE 's/^[[:space:]]*--cache-dir[[:space:]]+([^[:space:]]+).*/\1/p' "$ci" | head -n 1)
  if [[ -z $cache ]]; then
    echo 'ci.yml: the Trivy scan has no --cache-dir, so each of the two scans downloads the vulnerability database again'
  elif ! grep -qE -- "--volume \"[^\"]*:${cache}\" *\\\\?\$" "$ci"; then
    echo "ci.yml: --cache-dir $cache is not a folder shared with the runner (no --volume \"...:$cache\"), so it is not shared between the two scans"
  fi
  ignore=$(sed -nE 's/^[[:space:]]*--ignorefile[[:space:]]+([^[:space:]]+).*/\1/p' "$ci" | head -n 1)
  case $ignore in
    *.trivyignore.yaml) grep -qE -- "--volume \"[^\"]*\\.trivyignore\\.yaml:${ignore}:ro\"" "$ci" || echo "ci.yml: --ignorefile $ignore is not mounted (read-only) from .trivyignore.yaml" ;;
    *) echo "ci.yml: --ignorefile is '$ignore', not the .trivyignore.yaml that carries the expiry dates" ;;
  esac
}

# ---- 3. the Trivy exceptions expire ------------------------------------------------------------------
# Each exception names an exact advisory id, says why, and has an expired_at date. After the date
# Trivy stops ignoring it and the scan fails again, so a "temporary" exception cannot stay for good.
trivyignore_problems() { # ROOT
  local f=$1/.trivyignore.yaml
  [[ ! -e $1/.trivyignore ]] || echo '.trivyignore still exists next to .trivyignore.yaml (Trivy reads only the file named by --ignorefile)'
  if [[ ! -f $f ]]; then
    echo '.trivyignore.yaml does not exist'
    return
  fi
  awk '
    function finish() {
      if (id == "") return
      if (id !~ /^(CVE-[0-9]{4}-[0-9]+|GHSA-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4})$/) print ".trivyignore.yaml: \"" id "\" is not an exact CVE or GHSA id"
      if (!stmt) print ".trivyignore.yaml: " id " has no statement (the reason)"
      if (until == "") print ".trivyignore.yaml: " id " has no expired_at date"
      else {
        cmd = "date -d \"" until "\" +%F 2>/dev/null"
        cmd | getline back
        close(cmd)
        if (back != until) print ".trivyignore.yaml: " id " has expired_at \"" until "\", which is not a date (YYYY-MM-DD)"
      }
      n++
    }
    /^  - id:[[:space:]]/ { finish(); id = $3; stmt = 0; until = ""; back = ""; next }
    /^    statement:/ { stmt = 1 }
    /^    expired_at:/ { until = $2 }
    END { finish(); if (n == 0) print ".trivyignore.yaml: no entry at all (delete the file and the --ignorefile option instead)" }
  ' "$f"
}

# ---- 4. the MariaDB images are pinned by digest, one digest everywhere --------------------------------
mariadb_problems() { # ROOT
  local ci=$1/.github/workflows/ci.yml vi=$1/infra/images/verify-image.sh digests n
  grep -nE '^[[:space:]]+image:[[:space:]]' "$ci" | grep -vE '@sha256:[0-9a-f]{64}' | sed 's/^/ci.yml: a service image is not pinned by digest: /' || true
  grep -nE '^[^#]*mariadb:[0-9]' "$ci" | grep -vE '@sha256:[0-9a-f]{64}' | sed 's/^/ci.yml: a mariadb tag with no digest: /' || true
  grep -nE -- 'ancestor=' "$ci" | sed 's/^/ci.yml: a container is found by its image name, which a digest pin changes: /' || true
  grep -q 'job\.services\.mariadb\.id' "$ci" || echo 'ci.yml: the ci job does not find the MariaDB container through job.services.mariadb.id'
  grep -qE "db_client_image='[^']+@sha256:[0-9a-f]{64}'" "$vi" || echo 'verify-image.sh: db_client_image is not pinned by digest'
  digests=$(grep -ohE 'mariadb:[0-9][0-9.]*@sha256:[0-9a-f]{64}' "$ci" "$vi" | sort -u)
  n=$(printf '%s' "$digests" | grep -c . || true)
  [[ $n -le 1 ]] || printf 'the MariaDB pins differ between ci.yml and verify-image.sh: %s\n' "$(printf '%s' "$digests" | tr '\n' ' ')"
  [[ $n -ge 1 ]] || echo 'no mariadb:<tag>@sha256:<digest> pin found in ci.yml and verify-image.sh'
}

# ---- 5. the pnpm version carries its hash ----------------------------------------------------------------
packagemanager_problems() { # ROOT
  grep -qE '"packageManager":[[:space:]]*"pnpm@[0-9]+\.[0-9]+\.[0-9]+\+sha512\.[0-9a-f]{128}"' "$1/package.json" ||
    echo 'package.json: packageManager is not pnpm@<version>+sha512.<128 hex digits> (without the hash, Corepack takes whatever the registry serves)'
}

# ---- 6. Renovate: majors apart, a release age, the verifier's client image --------------------------------
renovate_problems() { # ROOT: one line per problem, from node reading renovate.json
  node - "$1" <<'JS'
const fs = require('fs');
const path = require('path');
const root = process.argv[2];
const problems = [];
const cfg = JSON.parse(fs.readFileSync(path.join(root, 'renovate.json'), 'utf8'));

// The weekly group takes minor, patch, digest and pin updates only; a major is its own pull request.
const weekly = (cfg.packageRules || []).filter((r) => r.groupName === 'weekly updates');
if (weekly.length !== 1) problems.push(`renovate.json: expected one rule with groupName "weekly updates", found ${weekly.length}`);
for (const r of weekly) {
  const t = r.matchUpdateTypes;
  const allowed = ['minor', 'patch', 'digest', 'pin', 'pinDigest'];
  if (!Array.isArray(t) || t.length === 0) problems.push('renovate.json: the weekly group has no matchUpdateTypes, so major updates are in it too');
  else {
    if (t.includes('major')) problems.push('renovate.json: the weekly group includes major updates');
    for (const u of t) if (!allowed.includes(u)) problems.push(`renovate.json: the weekly group includes the update type "${u}"`);
    for (const u of ['minor', 'patch', 'digest']) if (!t.includes(u)) problems.push(`renovate.json: the weekly group does not include "${u}" updates`);
  }
}

// A few days between a release and its pull request; a security update is never held back.
const age = cfg.minimumReleaseAge;
const m = typeof age === 'string' ? /^(\d+)\s*(day|days|week|weeks|hour|hours)$/.exec(age) : null;
const days = m ? Number(m[1]) * ({ day: 1, days: 1, week: 7, weeks: 7, hour: 1 / 24, hours: 1 / 24 })[m[2]] : 0;
if (days < 3) problems.push(`renovate.json: minimumReleaseAge is ${JSON.stringify(age)}; it must be at least 3 days`);
const va = cfg.vulnerabilityAlerts || {};
if (!('minimumReleaseAge' in va) || va.minimumReleaseAge !== null) problems.push('renovate.json: vulnerabilityAlerts must set minimumReleaseAge to null, so a security update is not delayed');

// Every custom manager must find what it is meant to find, in the file it names.
const managers = cfg.customManagers || [];
let coversVerifier = false;
for (const cm of managers) {
  const files = ['.github/workflows/ci.yml', 'infra/images/verify-image.sh'].filter((f) =>
    (cm.managerFilePatterns || []).some((p) => new RegExp(p.replace(/^\/(.*)\/$/, '$1')).test(f)));
  for (const f of files) {
    const text = fs.readFileSync(path.join(root, f), 'utf8');
    for (const s of cm.matchStrings || []) {
      const found = [...text.matchAll(new RegExp(s, 'g'))];
      if (found.length === 0) problems.push(`renovate.json: a custom manager for ${f} matches nothing in it`);
      for (const x of found) {
        const g = x.groups || {};
        if (!g.depName || !g.currentValue || !g.currentDigest) problems.push(`renovate.json: a custom manager for ${f} matched "${x[0].slice(0, 60)}" without depName, currentValue and currentDigest`);
      }
      if (f === 'infra/images/verify-image.sh' && found.some((x) => x.groups && x.groups.depName === 'mariadb')) coversVerifier = true;
    }
  }
}
if (!coversVerifier) problems.push("renovate.json: no custom manager reads the mariadb image that verify-image.sh runs as its database client, so its digest would never be bumped");
for (const p of problems) console.log(p);
JS
}

# ---- 7. the comments say how a security fix really reaches an image ------------------------------------
# The weekly run scans the FINAL image (the distroless base and the app layers, not the build stage)
# and fails on a HIGH or CRITICAL vulnerability that has a fix; Renovate opens the bump pull request
# once its GitHub app is installed on the repository.
wording_problems() { # ROOT
  local f text want
  for f in apps/cms/Dockerfile apps/web/Dockerfile .github/workflows/ci.yml; do
    text=$(sed -E 's/^[[:space:]]*#[[:space:]]?//' "$1/$f" | tr '\n' ' ' | tr -s ' ')
    for want in 'not the build stage' 'HIGH or CRITICAL' 'Renovate GitHub app'; do
      [[ $text == *"$want"* ]] || printf '%s: the comment about how a security fix arrives does not say "%s"\n' "$f" "$want"
    done
    for want in 'is in one of them' 'is in a pinned base image' 'then opens a pull request that bumps'; do
      [[ $text != *"$want"* ]] || printf '%s: still says "%s", which overclaims\n' "$f" "$want"
    done
  done
}

all_problems() { # ROOT
  checkout_problems "$1"
  trivy_problems "$1"
  trivyignore_problems "$1"
  mariadb_problems "$1"
  packagemanager_problems "$1"
  renovate_problems "$1"
  wording_problems "$1"
}

none "ci.yml and deploy.yml: every checkout sets persist-credentials: false" "$(checkout_problems "$ROOT")"
none "ci.yml: Trivy has a 15 minute timeout, one shared cache folder and the YAML exceptions file" "$(trivy_problems "$ROOT")"
none ".trivyignore.yaml: every exception has an exact id, a reason and an expiry date" "$(trivyignore_problems "$ROOT")"
none "the MariaDB service and client images are pinned by one digest" "$(mariadb_problems "$ROOT")"
none "package.json: packageManager carries the sha512 of the pnpm release" "$(packagemanager_problems "$ROOT")"
none "renovate.json: majors apart, a release age, and every custom manager finds its image" "$(renovate_problems "$ROOT")"
none "the Dockerfiles and ci.yml say how a security fix really arrives" "$(wording_problems "$ROOT")"

# ---- the same checks on broken copies: each must be noticed, for its own reason ---------------------------
T=$(mktemp -d -t oc-ci-config-test.XXXXXX)
trap 'rm -rf -- "$T"' EXIT
fresh() { # a clean copy of everything the checks read
  rm -rf "$T/c"
  mkdir -p "$T/c/.github/workflows" "$T/c/apps/cms" "$T/c/apps/web" "$T/c/infra/images"
  cp "$ROOT/.github/workflows/ci.yml" "$ROOT/.github/workflows/deploy.yml" "$T/c/.github/workflows/"
  cp "$ROOT/.trivyignore.yaml" "$ROOT/renovate.json" "$ROOT/package.json" "$T/c/"
  cp "$ROOT/apps/cms/Dockerfile" "$T/c/apps/cms/"
  cp "$ROOT/apps/web/Dockerfile" "$T/c/apps/web/"
  cp "$ROOT/infra/images/verify-image.sh" "$T/c/infra/images/"
}
C=$T/c
edit_json() { # FILE JS: runs JS (a statement on c, the parsed file) and writes the file back
  node -e 'const fs = require("fs"); const p = process.argv[1]; const c = JSON.parse(fs.readFileSync(p, "utf8")); eval(process.argv[2]); fs.writeFileSync(p, JSON.stringify(c, null, 2));' "$1" "$2"
}
fresh
none "(control) the clean copy is accepted" "$(all_problems "$C")"

# 1. checkout
fresh
sed -i '0,/^          persist-credentials: false$/s///' "$C/.github/workflows/deploy.yml"
some "a checkout without persist-credentials is noticed (deploy.yml)" "$(checkout_problems "$C")" "deploy.yml:"
fresh
sed -i '0,/persist-credentials: false/s//persist-credentials: true/' "$C/.github/workflows/ci.yml"
some "persist-credentials: true is noticed (ci.yml)" "$(checkout_problems "$C")" "ci.yml:"

# 2. Trivy
fresh
sed -i '/--timeout 15m/d' "$C/.github/workflows/ci.yml"
some "a Trivy scan without --timeout 15m is noticed" "$(trivy_problems "$C")" "no --timeout 15m"
fresh
sed -i '/--cache-dir/d' "$C/.github/workflows/ci.yml"
some "a Trivy scan without --cache-dir is noticed" "$(trivy_problems "$C")" "no --cache-dir"
fresh
# shellcheck disable=SC2016  # a sed expression: the $ signs are sed's, not the shell's
sed -i '/--volume "\$PWD\/trivy-cache:/d' "$C/.github/workflows/ci.yml"
some "a --cache-dir that is not a shared folder is noticed" "$(trivy_problems "$C")" "is not a folder shared with the runner"
fresh
sed -i 's|--ignorefile /.trivyignore.yaml|--ignorefile /.trivyignore|' "$C/.github/workflows/ci.yml"
some "an --ignorefile that is not the YAML file is noticed" "$(trivy_problems "$C")" "not the .trivyignore.yaml"

# 3. .trivyignore.yaml
fresh
sed -i '0,/^    expired_at:.*$/s///' "$C/.trivyignore.yaml"
some "an exception with no expired_at is noticed" "$(trivyignore_problems "$C")" "has no expired_at date"
fresh
sed -i '0,/^    expired_at:.*$/s//    expired_at: 2027-02-31/' "$C/.trivyignore.yaml"
some "an expired_at that is not a date is noticed" "$(trivyignore_problems "$C")" "is not a date"
fresh
sed -i '0,/^  - id: .*$/s//  - id: CVE-*/' "$C/.trivyignore.yaml"
some "a wildcard id is noticed" "$(trivyignore_problems "$C")" "is not an exact CVE or GHSA id"
fresh
sed -i '0,/^    statement:.*$/s//    reason: x/' "$C/.trivyignore.yaml"
some "an exception with no statement is noticed" "$(trivyignore_problems "$C")" "has no statement"
fresh
printf 'GHSA-26w7-cxv4-gfx2\n' >"$C/.trivyignore"
some "a leftover .trivyignore is noticed" "$(trivyignore_problems "$C")" ".trivyignore still exists"

# 4. MariaDB
fresh
sed -i '0,/image: mariadb:11.4@sha256:[0-9a-f]*/s//image: mariadb:11.4/' "$C/.github/workflows/ci.yml"
some "a service image with no digest is noticed" "$(mariadb_problems "$C")" "a service image is not pinned by digest"
fresh
sed -i "s|^readonly db_client_image=.*|readonly db_client_image='mariadb:11.4'|" "$C/infra/images/verify-image.sh"
some "a client image with no digest is noticed" "$(mariadb_problems "$C")" "db_client_image is not pinned by digest"
fresh
sed -i "0,/mariadb:11.4@sha256:[0-9a-f]\{64\}/s//mariadb:11.4@sha256:$(printf '0%.0s' {1..64})/" "$C/infra/images/verify-image.sh"
some "two different digests are noticed" "$(mariadb_problems "$C")" "pins differ between ci.yml and verify-image.sh"
fresh
# shellcheck disable=SC2016  # a sed expression: the $ signs are sed's, not the shell's
sed -i 's|"\$MARIADB_CONTAINER"|"$(docker ps -q --filter ancestor=mariadb:11.4)"|' "$C/.github/workflows/ci.yml"
some "finding the container by its image name is noticed" "$(mariadb_problems "$C")" "found by its image name"

# 5. packageManager
fresh
sed -i 's/\(pnpm@[0-9.]*\)+sha512\.[0-9a-f]*/\1/' "$C/package.json"
some "a packageManager with no hash is noticed" "$(packagemanager_problems "$C")" "packageManager is not pnpm@<version>+sha512"
fresh
sed -i 's/+sha512\.\([0-9a-f]\{20\}\)[0-9a-f]*/+sha512.\1/' "$C/package.json"
some "a packageManager with a short hash is noticed" "$(packagemanager_problems "$C")" "packageManager is not pnpm@<version>+sha512"

# 6. Renovate
fresh
edit_json "$C/renovate.json" 'delete c.packageRules[0].matchUpdateTypes'
some "a weekly group that takes major updates is noticed" "$(renovate_problems "$C")" "major updates are in it too"
fresh
edit_json "$C/renovate.json" 'c.packageRules[0].matchUpdateTypes.push("major")'
some "a weekly group that lists major is noticed" "$(renovate_problems "$C")" "includes major updates"
fresh
edit_json "$C/renovate.json" 'delete c.minimumReleaseAge'
some "no minimumReleaseAge is noticed" "$(renovate_problems "$C")" "minimumReleaseAge is undefined"
fresh
edit_json "$C/renovate.json" 'c.minimumReleaseAge = "1 day"'
some "a release age under three days is noticed" "$(renovate_problems "$C")" "at least 3 days"
fresh
edit_json "$C/renovate.json" 'delete c.vulnerabilityAlerts.minimumReleaseAge'
some "security updates that wait for the release age are noticed" "$(renovate_problems "$C")" "vulnerabilityAlerts must set minimumReleaseAge to null"
fresh
edit_json "$C/renovate.json" 'c.customManagers = c.customManagers.filter((m) => !m.managerFilePatterns.some((f) => f.includes("verify-image")))'
some "no manager for the verifier's database client image is noticed" "$(renovate_problems "$C")" "no custom manager reads the mariadb image"
fresh
sed -i "s|^readonly db_client_image=.*|readonly db_client_image=\"mariadb\"|" "$C/infra/images/verify-image.sh"
some "a manager that matches nothing in its file is noticed" "$(renovate_problems "$C")" "matches nothing in it"

# 7. wording
fresh
sed -i 's/Renovate GitHub app/Renovate/' "$C/apps/cms/Dockerfile"
some "a Dockerfile that does not mention the GitHub app is noticed" "$(wording_problems "$C")" 'apps/cms/Dockerfile: the comment about how a security fix arrives does not say "Renovate GitHub app"'
fresh
sed -i 's/build stage, which is thrown away/final stage/' "$C/apps/web/Dockerfile"
some "a Dockerfile that does not say the final image is scanned is noticed" "$(wording_problems "$C")" 'does not say "not the build stage"'
fresh
sed -i 's/HIGH or CRITICAL/serious/' "$C/.github/workflows/ci.yml"
some "ci.yml without the severities is noticed" "$(wording_problems "$C")" 'ci.yml: the comment about how a security fix arrives does not say "HIGH or CRITICAL"'
fresh
sed -i '0,/^# Both base images are pinned by digest/s//# Re-scans these pinned digests and fails when a vulnerability that has a fix is in one of them. Both base images are pinned by digest/' "$C/apps/cms/Dockerfile"
some "the old overclaiming sentence is noticed" "$(wording_problems "$C")" 'still says "is in one of them"'
fresh
none "(control) the clean copy is accepted again" "$(all_problems "$C")"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
