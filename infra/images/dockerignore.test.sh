#!/usr/bin/env bash
# Tests the root .dockerignore: plants files that must never reach an image (an .env, keys,
# a database, uploads, a git folder, tests) inside the folders the Dockerfiles build from,
# builds a throwaway image that copies the whole build context and lists it, and checks that
# none of them got in while the sources the builds need did. The planted files are removed
# again, also when the test is interrupted. Needs Docker.
#
#   bash infra/images/dockerignore.test.sh
set -euo pipefail

export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(cd -- "$here/../.." && pwd)
cd "$root"

# Windows Git Bash gives docker.exe a Windows path; elsewhere the path is already right.
host_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

# Every planted path starts with "dockerignore-probe" so it cannot be mistaken for real work.
planted=(
  apps/web/.env.dockerignore-probe
  apps/cms/.env.dockerignore-probe
  apps/cms/dockerignore-probe.pem
  apps/cms/dockerignore-probe.key
  apps/cms/dockerignore-probe.sqlite
  apps/cms/dockerignore-probe.sql
  apps/cms/public/uploads/dockerignore-probe.txt
  apps/cms/.tmp/dockerignore-probe.db
  apps/cms/dist/dockerignore-probe.js
  apps/web/dockerignore-probe.test.ts
  apps/web/tests/dockerignore-probe.spec.ts
  packages/shared/node_modules/dockerignore-probe.js
  dockerignore-probe.env.txt
)
cleanup() {
  local p
  for p in "${planted[@]}"; do rm -f "$root/$p"; done
  # Folders the test made (they are empty again by now); never touches a folder with other content.
  rmdir "$root/apps/cms/.tmp" 2>/dev/null || true
  rm -f "$root/.dockerignore-probe.Dockerfile"
}
trap cleanup EXIT

created=()
for p in "${planted[@]}"; do
  mkdir -p "$root/$(dirname "$p")"
  printf 'dockerignore probe\n' >"$root/$p"
  created+=("$p")
done

# A Dockerfile of its own, so the real ones are not touched. BuildKit reads the root
# .dockerignore for it, as it does for apps/*/Dockerfile.
cat >"$root/.dockerignore-probe.Dockerfile" <<'EOF'
FROM scratch AS probe
COPY . /ctx
FROM scratch
COPY --from=probe /ctx /ctx
EOF

out=$(mktemp -d)
trap 'cleanup; rm -rf "$out"' EXIT
docker build --quiet --file "$(host_path "$root/.dockerignore-probe.Dockerfile")" \
  --output "type=local,dest=$(host_path "$out")" "$(host_path "$root")" >/dev/null

failed=0
ok() { printf 'ok     - %s\n' "$*"; }
notok() {
  printf 'NOT OK - %s\n' "$*"
  failed=$((failed + 1))
}

for p in "${created[@]}"; do
  if [[ -e "$out/ctx/$p" ]]; then notok "$p reached the build context"; else ok "$p is kept out"; fi
done

# And nothing that looks like a secret or local data, planted or not (apps/cms/.env is the
# developer's real file on this machine; it must not be in the context either).
leaks=$(cd "$out/ctx" && find . \( -name '.env*' -o -name '*.pem' -o -name '*.key' -o -name '*.sqlite*' -o -name '*.db' -o -name '*.sql' -o -name '.git' -o -name '.superpowers' -o -name node_modules \) -print)
if [[ -z $leaks ]]; then ok 'no .env, key, database, .git or node_modules anywhere in the context'; else notok "found in the context: $leaks"; fi
if [[ -e "$out/ctx/docs" || -e "$out/ctx/design" || -e "$out/ctx/infra" || -e "$out/ctx/.github" ]]; then
  notok 'docs, design, infra or .github reached the build context'
else
  ok 'docs, design, infra and .github are not in the context'
fi

# The sources the builds need are there.
for need in package.json pnpm-lock.yaml pnpm-workspace.yaml tsconfig.base.json apps/web/package.json \
  apps/web/astro.config.mjs apps/web/healthcheck.mjs apps/cms/package.json apps/cms/tsconfig.json \
  apps/cms/healthcheck.mjs apps/cms/public/robots.txt packages/shared/package.json packages/shared/src/index.ts; do
  if [[ -f "$out/ctx/$need" ]]; then ok "$need is in the context"; else notok "$need is missing from the context"; fi
done

if ((failed)); then
  printf '\n%s check(s) of .dockerignore failed\n' "$failed"
  exit 1
fi
printf '\n.dockerignore behaves as expected\n'
