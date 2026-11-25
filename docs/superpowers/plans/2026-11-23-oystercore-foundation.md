# OysterCore Platform: Foundation Implementation Plan (Plan 1 of 4)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Set up and harden the Hostinger VPS (Phase 0), then ship the foundation to staging: monorepo, CMS content model for companies, home and site settings, design system, header and footer, the home hero slider, Our Group, company pages, audit log, admin roles and CI.

**Architecture:** One pnpm monorepo with four parts. `@oc/cms` is Strapi 5 on MariaDB 11.4. `@oc/web` is Astro rendered on the server, which is the only caller of Strapi's content API. `@oc/shared` holds pure TypeScript both apps use. `infra/` sets up and checks the server. Everything runs on one Hostinger VPS behind Cloudflare Free, in two environments (production and staging). The two apps run as distroless, non-root container images under rootless Podman. Uploaded media lives on disk outside the images.

**Tech Stack:** Node 22 LTS, pnpm workspaces, TypeScript (strict), Strapi 5 (`mysql2`), MariaDB 11.4, Astro with the Node adapter, Ubuntu 24.04, Nginx, Podman and Quadlet, Docker (to build images), distroless Node base images, Trivy, ClamAV, vitest, Playwright, axe, Lighthouse CI, shellcheck, GitHub Actions, Cloudflare Free.

**Spec:** `docs/superpowers/specs/2026-11-23-oystercore-platform-design.md` (approved 23 November 2026). Client PRD: `Desktop\Claude\OYSTERCORE_PRD.pdf` (signed). Prototype markup: `design/prototype/`.

**This is plan 1 of 4.** Later plans are written after Phase 0 reports, because its results can change them.
- Plan 2: content sections, forms and the email send test, Zoho CRM, search, consent and analytics (spec Phase 2).
- Plan 3: the file pipeline (ClamAV scan, the throttled 25 MB chunked upload test) and the procurement, careers and investor portals (Phase 3).
- Plan 4: marketing pages, chat, newsletter, the nightly backup job and its restore test, image signing, hardening and launch readiness (Phases 4 and 5).

## Global Constraints

Every task's requirements include this section.

- Node 22 LTS, 22.23.4 or newer (`.nvmrc` = `22`). pnpm workspaces. TypeScript `strict: true`. Strapi 5.x with `mysql2`; MariaDB 11.4 (the version on the server, in CI and locally).
- **No hard-coded content (HOM-02).** Names, colours, headlines, figures, photos and links come from Strapi. Navigation structure and UI labels may live in code.
- Palette: deep navy `#0B1F3A`, group navy `#14305C`, gold `#C9A24B`, dark gold `#8A6A1C` (gold text on white), light grey `#F2F4F8`, slate `#4B5668`.
- Type: Manrope 800 for headings, Inter 400 for body at 17px on desktop. Fonts are self-hosted; **no requests to Google Fonts**. Form fields are 48px tall.
- Accessibility: WCAG 2.2 AA. Text contrast at least 4.5:1. Every interactive part works by keyboard and screen reader. Reduced motion is honoured.
- Budgets: mobile LCP 2.5 s, CLS 0.1, at most 70 KB of compressed JavaScript per template.
- **No monthly cost to the client.** The VPS is paid by Slatech; everything else is a free tier or an existing subscription. No AWS, no paid Strapi edition, no paid scanner (ClamAV is free).
- Hostinger VPS (KVM 2 minimum, Ubuntu 24.04 LTS): the server is set up and checked by the scripts in `infra/`; nothing is configured by hand without a matching change there. Persistent files live in `/var/lib/oc/<env>` (env var `OC_DATA_DIR`), outside the release folders. Apps are built in CI, never on the server.
- **Images (decided by Slatech):** minimal distroless base (`gcr.io/distroless/nodejs22-debian12:nonroot` or its newest successor) pinned by digest; non-root; no shell; Node 22.23.4 or newer inside; run rootless under Podman with a read-only filesystem, all capabilities dropped and `no-new-privileges`. Only `/var/lib/oc/<env>` is writable. No secret, `.env`, `.git` folder or test file ends up in an image.
- Strapi's public content API is off. Astro calls it with a read-only API token plus header `x-oc-secret`. Draft content is never rendered on a public page.
- Moments are stored in UTC and displayed in Africa/Lagos. The hero has 11 slides at launch: the group slide, then one per active company in `sortOrder`. It advances every 6 s.
- Environment variables (Hostinger and `.env.example`): `DATABASE_CLIENT`, `DATABASE_HOST`, `DATABASE_PORT`, `DATABASE_NAME`, `DATABASE_USERNAME`, `DATABASE_PASSWORD`, `APP_KEYS`, `API_TOKEN_SALT`, `ADMIN_JWT_SECRET`, `TRANSFER_TOKEN_SALT`, `JWT_SECRET`, `ENCRYPTION_KEY`, `OC_INTERNAL_SECRET`, `OC_CMS_URL`, `OC_CMS_API_TOKEN`, `OC_DATA_DIR`, `CSP_MODE` (`report-only` or `enforce`), `PUBLIC_SITE_URL`.

## Prerequisites (from Slatech)

Task 3 and the repository parts of Task 4 need only this machine (with Docker). The server steps of Task 4 need: a Hostinger VPS (KVM 2 or larger, Ubuntu 24.04 LTS, 24-month term) and an SSH key for each person who will administer it; a test domain on a Cloudflare account; a GitHub repository with the deploy secrets set (`DEPLOY_SSH_KEY`, `DEPLOY_HOST`, `DEPLOY_KNOWN_HOSTS`); and a data-centre choice (spec open item O4; Slatech's pick until the DPO answers). Locally: pnpm, Docker, and Node 22.23.4 or newer.

## Review Focus

Failure modes the spec implies that are most likely to bite. Each is pinned by a test in the task shown.

1. **Draft or unpublished content reaching a public page.** A draft company must never appear on the home, group or company pages, and its URL must 404. (Tasks 8, 14, 15)
2. **A company saved with no logo, hero image, tagline, leaders or figures.** Pages and slider cards render fallbacks, never a broken image or the word "undefined". (Tasks 13, 14, 15)
3. **Extreme brand colours.** `#FFFF00`, `#FFFFFF`, `#000000` and mid-tones like `#808080` still give readable text. `#fff`, `red` and `#GGGGGG` are refused with a clear message. (Tasks 5, 7, 15)
4. **Strapi slow or down while Astro renders.** The visitor sees a calm 503 page with no stack trace or secrets. `/healthz` stays 200 and reports `cms: false`. (Task 8)
5. **Hero with 0, 1 or 12 companies, and with reduced motion.** No crash; a twelfth company needs no code change; the slider starts paused when motion is reduced. (Task 13)

## File Structure

```
package.json  pnpm-workspace.yaml  tsconfig.base.json  .nvmrc  .gitignore
docker-compose.dev.yml  playwright.config.ts  lighthouserc.json
.github/workflows/ci.yml
docs/phase0/report.md  docs/deploy.md
infra/  (bootstrap.sh verify.sh lib/ quadlet/ systemd/ nginx/ images/ deploy/ test/)
apps/cms/Dockerfile  apps/web/Dockerfile  .dockerignore  .trivyignore
packages/shared/src/  colour.ts tokens.ts initials.ts slides.ts content-types.ts index.ts (+ *.test.ts)
apps/cms/             Strapi 5 app
  src/api/{company,home,site-setting,audit-event,staff-company-assignment}/
  src/components/{shared,company}/   src/middlewares/internal-secret.ts
  src/bootstrap/roles.ts   src/audit/   providers/upload-oc-disk/   scripts/seed.ts   tests/
apps/web/             Astro app
  src/lib/{strapi,csp,navigation,site}.ts   src/middleware.ts
  src/layouts/Base.astro  src/components/{Header,Footer,HeroSlider,CompanyCard}.astro
  src/islands/{hero-slider,mega-menu}.ts   src/styles/{tokens,global}.css
  src/pages/{index.astro,group.astro,healthz.ts,media/[...path].ts,companies/[slug].astro,503.astro}
  tests/e2e/
```

---

## Phase 0: workspace and server baseline

### Task 1: Workspace, tooling and CI

**Files:**
- Create: `package.json`, `pnpm-workspace.yaml`, `tsconfig.base.json`, `.nvmrc`, `.gitignore`, `docker-compose.dev.yml`, `.github/workflows/ci.yml`, `packages/shared/{package.json,tsconfig.json,vitest.config.ts,src/index.ts}`

**Interfaces:**
- Produces: workspace packages `@oc/shared`, `@oc/cms`, `@oc/web`. Root scripts `pnpm typecheck`, `pnpm test`, `pnpm build` (each runs `pnpm -r`). `docker-compose.dev.yml` runs `mariadb:11.4` on host port **3307** (avoids the local MariaDB on 3306) with databases `oc_dev` and `oc_test`.

- [ ] **Step 1:** In the repo root run `git init -b main`, then `corepack enable && corepack prepare pnpm@latest --activate`. Create the files above. `ci.yml` runs on push and PR: Node 22, pnpm install with cache, a `mariadb:11.4` service container, then `pnpm typecheck`, `pnpm test`, `pnpm build`, `pnpm audit --audit-level=high`, and gitleaks.
- [ ] **Step 2:** Run `pnpm install && pnpm typecheck`. Expected: exit 0 on the empty workspace.
- [ ] **Step 3:** Create the GitHub repo, set `main` and `staging` as protected branches (CI must pass, one review), and push. Expected: the CI run is green.
- [ ] **Step 4:** Commit: `git add -A && git commit -m "chore: workspace, tooling and CI"`.

### Task 2: Walking skeleton and the end-to-end harness

**Files:**
- Create: `apps/cms/` (Strapi scaffold), `apps/web/` (Astro scaffold), `apps/web/src/pages/healthz.ts`, `playwright.config.ts`, `apps/web/tests/e2e/healthz.spec.ts`, `.env.example` in each app

**Interfaces:**
- Produces: `GET /healthz` on web, returning status `200` with a JSON body whose `ok` is `true` (Task 8 adds a `cms` field). `playwright.config.ts` starts Strapi (`pnpm --filter @oc/cms start`) and Astro (`pnpm --filter @oc/web preview`) via `webServer`, with `baseURL` from `BASE_URL` (default `http://localhost:4321`).

- [ ] **Step 1:** Scaffold Strapi with `npx create-strapi@latest apps/cms` (TypeScript, `mysql` client, no example data, skip cloud; check flags with `--help`). Scaffold Astro with the Node adapter in `standalone` mode into `apps/web`. Set package names to `@oc/cms` and `@oc/web`. Run `docker compose -f docker-compose.dev.yml up -d`.
- [ ] **Step 2:** Write the failing test `healthz returns ok` in `healthz.spec.ts`: `GET /healthz` has status 200 and a JSON body whose `ok` is `true`. Run `pnpm exec playwright test`. Expected: FAIL (404).
- [ ] **Step 3:** Implement `GET` in `healthz.ts` returning `{ ok: true }`. Run the test. Expected: PASS. Also run `pnpm --filter @oc/cms develop` and confirm the admin loads at `localhost:1337/admin`.
- [ ] **Step 4:** Commit: `feat: walking skeleton with Strapi, Astro and Playwright`.

### Task 3: Server setup scripts and the verifier

**Files:**
- Create: `infra/bootstrap.sh`, `infra/verify.sh`, `infra/server.env.example`, `infra/lib/{packages,users,ssh,firewall,containers,nginx}.sh`, `infra/quadlet/{oc-web.container.template,oc-cms.container.template}`, `infra/systemd/{oc-cloudflare-ips.service,oc-cloudflare-ips.timer}`, `infra/nginx/oc.conf.template`, `infra/test/{Dockerfile,run.sh}`
- Modify: `.github/workflows/ci.yml` (a new `infra` job)

**Interfaces:**
- Consumes: spec §5 (layout and containers) and §10.9 (every hardening item). Layout: system users `oc-prod` and `oc-staging`, each with a subuid and subgid range and lingering enabled so their rootless services start at boot; `/var/lib/oc/<env>/{media,private,tmp}`; `/etc/oc/<env>.env`; Quadlet files generated per environment into that user's `~/.config/containers/systemd/` from the templates, producing services `oc-cms-<env>` and `oc-web-<env>`. The host does not get Node, Docker or a container daemon.
- Produces: `infra/bootstrap.sh` (idempotent: running it twice changes nothing the second time). It reads `infra/server.env`, made from `infra/server.env.example`, which defines `OC_DOMAIN`, `OC_ADMINS` (comma-separated `user:path-to-public-key`), `OC_SSH_PORT`, `OC_TIMEZONE` (default `Africa/Lagos`) and `OC_ENVS` (default `prod staging`). `infra/verify.sh` prints `PASS <ID> <text>` or `FAIL <ID> <text>` per check, prints `SKIP <ID>` for checks marked (kernel) when `VERIFY_CONTAINER=1`, and exits non-zero if any check fails. Check IDs: SSH-01 password login off; SSH-02 root login off; SSH-03 only the named admins allowed; SSH-04 non-default port; NET-01 ufw denies inbound by default; NET-02 ports 80 and 443 open only to Cloudflare's ranges (kernel); NET-03 Nginx requires Cloudflare's client certificate; NET-04 MariaDB bound to localhost; NET-05 clamd on a local socket only; OS-01 unattended-upgrades enabled; OS-02 fail2ban sshd jail active (kernel); OS-03 time sync on (kernel); CTR-01 each generated Quadlet file sets a non-root user mapping, `ReadOnly=true`, `DropCapability=ALL`, `NoNewPrivileges=true`, a memory limit and a pids limit, publishes ports on `127.0.0.1` only, mounts nothing except its own data folder (and the MariaDB and ClamAV sockets if used), and never mounts a container socket; CTR-02 each environment user has subuid and subgid ranges and lingering enabled; CTR-03 rootless `podman info` works as each environment user (kernel); SVC-02 secret files are `0640` and owned `root:oc-<env>`; FS-01 data folders are owned by the environment user with mode `0750`; FS-02 `/var/lib/oc` is not under any Nginx root; DB-01 one database user per environment, limited to its own database; PKG-01 Podman is 4.4 or newer (Quadlet) and no Docker daemon is installed; PKG-02 MariaDB is 11.4.x.

- [ ] **Step 1: Write the failing verifier.** Write `infra/verify.sh` with every check above, and `infra/test/{Dockerfile,run.sh}`: an Ubuntu 24.04 image without systemd that runs `bootstrap.sh` then `verify.sh` with `VERIFY_CONTAINER=1`, and a `verify-only` mode that skips the bootstrap. Run `bash infra/test/run.sh verify-only`. Expected: FAIL on every non-skipped check.
- [ ] **Step 2: Implement the bootstrap** (libs, Quadlet templates, Nginx template) until every check that can run in a container passes. Validate the generated Quadlet files with Podman's Quadlet generator in dry-run mode in the container. Run `bash infra/test/run.sh`. Expected: PASS for all non-kernel checks, SKIP for the kernel ones, exit 0. Run it twice in the same container; the second run changes nothing (file hashes under `/etc` and the generated Quadlet files unchanged, no secret regenerated).
- [ ] **Step 3: Validate the artefacts.** `shellcheck` is clean on every script. `nginx -t` passes on the rendered template inside the container. `systemd-analyze verify` passes on the timer and service if available in the image; if not, say so in the report.
- [ ] **Step 4: CI.** Add an `infra` job that builds the test image, runs `infra/test/run.sh` and `shellcheck`. Commit: `feat(infra): server bootstrap, hardening and verifier`.

### Task 3b: App container images (distroless, non-root)

**Files:**
- Create: `apps/cms/Dockerfile`, `apps/web/Dockerfile`, `apps/cms/healthcheck.mjs`, `apps/web/healthcheck.mjs`, `.dockerignore`, `.trivyignore`, `infra/images/verify-image.sh`, `infra/images/verify-image.test.sh`
- Modify: `.github/workflows/ci.yml` (a new `images` job)

**Interfaces:**
- Consumes: the pnpm workspace; Task 3's runtime conventions (container user is the host environment user via `--userns=keep-id`; writable path only `/var/lib/oc/<env>`; read-only root filesystem).
- Produces: images `oc-cms` and `oc-web`. Each Dockerfile is multi-stage: a build stage on `node:22-bookworm-slim` pinned by digest, running as the non-root `node` user (any root-only setup, such as enabling pnpm, happens before `USER node` and nothing after it needs root), runs `pnpm install --frozen-lockfile`, builds `@oc/shared` and the app, and creates a production-only, self-contained app directory with `pnpm deploy`; the final stage is `gcr.io/distroless/nodejs22-debian12:nonroot` (or its newest successor) pinned by digest, copies only that directory, sets `USER 65532`, `NODE_ENV=production`, and a `CMD` that starts the app (web: `dist/server/entry.mjs`; cms: Strapi's `start`). `healthcheck.mjs` exits 0 if the app's own health endpoint (web `/healthz`, cms `/_health`) answers 2xx on its localhost port within 2 s, otherwise 1. `infra/images/verify-image.sh <image>` exits 0 only if: the image's user is a non-root numeric UID; `/bin/sh` cannot be started in it; running it with `--version` prints Node 22.23.4 or newer; its filesystem contains no `.env*`, `.git`, `*.test.*`, `*.spec.*` or `.cache` entries; its size is under a limit set at 1.5 times the measured size; and it starts with `--read-only --cap-drop ALL --security-opt no-new-privileges --tmpfs /tmp` and its `healthcheck.mjs` passes (web needs no database; cms runs against the compose database through `host.docker.internal:3307`).

- [ ] **Step 1: Write the failing verifier and its test.** Write `verify-image.sh` and `verify-image.test.sh`: the test runs the verifier against `node:22-bookworm-slim` and expects it to fail on the non-root, no-shell and read-only checks. Run it. Expected: the verifier exits non-zero on that image and the test passes (RED evidence for the verifier itself); there are no app images yet.
- [ ] **Step 2: Write the Dockerfiles, the health-check scripts and `.dockerignore`.** Build both images: `docker build -f apps/web/Dockerfile -t oc-web:dev .` and the same for the cms. Run `bash infra/images/verify-image.sh oc-web:dev` and `oc-cms:dev`. Expected: exit 0 for both. Fix what the read-only root filesystem exposes (extra tmpfs mounts, writable paths) and record each one in the report so Task 3's Quadlet files can match.
- [ ] **Step 3: Scan.** Run Trivy (from its container image) on both images for HIGH and CRITICAL findings that have a fix. Record the output. Any finding that comes from the temporary Astro-7 audit exceptions or the zod 3 exception goes into `.trivyignore` by its exact advisory id, each with a `# TEMPORARY until the Astro 7 upgrade (ledger R18)` or `# TEMPORARY until Strapi moves koa-session off zod 3` comment. Nothing else is ignored.
- [ ] **Step 4: CI.** Add an `images` job: run hadolint on both Dockerfiles (rule DL3002, plus a script check that every stage sets a non-root `USER` before its first build command), build both images with Buildx, run `verify-image.sh` on each, run Trivy with `--exit-code 1 --severity HIGH,CRITICAL --ignore-unfixed` and `.trivyignore`. Add a weekly `schedule` trigger so base-image fixes arrive even when the code doesn't change. Expected: green. Commit: `feat: distroless non-root app images with CI checks`.

### Task 4: Deploy pipeline

**Files:**
- Create: `infra/deploy/deploy-release.sh`, `infra/deploy/apply-release.sh`, `infra/deploy/deploy-release.test.sh`, `.github/workflows/deploy.yml`, `docs/deploy.md`
- Modify: `.github/workflows/ci.yml` (add `actionlint`), `infra/bootstrap.sh`, `infra/lib/users.sh` (create the deploy user, its restricted `authorized_keys` line, and the sudoers entry), `infra/lib/ssh.sh`, `infra/verify.sh` (checks DEP-01 and DEP-02, and the SSH single-source change below), `infra/quadlet/oc-web.container.template`, `infra/quadlet/oc-cms.container.template` (`Pull=never`), `infra/test/container-run.sh` (breakage tests for the new checks)

**Interfaces:**
- Consumes: Task 3's layout, users and Quadlet files; Task 3b's images (`oc-cms` and `oc-web`, tagged with the commit sha).
- Produces: `deploy-release <env> <sha> <cms-image-id> <web-image-id>`, the SSH forced command run as the restricted deploy user. It reads one tarball (made with `podman save` or `docker save` from `oc-cms:<sha>` and `oc-web:<sha>`) on stdin into a spool file. `env` must be `prod` or `staging`, `sha` exactly 40 hex characters, each image id `sha256:` plus 64 hex characters; anything else exits 2 with no side effects. It then calls `apply-release.sh`, a root-owned script that the deploy user may run only through one sudoers entry (exact path, no wildcards beyond the validated arguments). `apply-release.sh` loads the images as the environment's user, checks that the loaded image ids equal the ones passed in (exit 3 if not), rewrites only the `Image=` line of the environment's Quadlet files to the new tag, restarts `oc-cms-<env>` and `oc-web-<env>`, waits up to 60 s for the CMS `/_health` and the web `/healthz` on localhost, and on any failure points the `Image=` lines back at the previous tag, restarts, and exits 1. It keeps the 3 newest tags per image and removes older ones. Tests override `OC_ROOT`, `OC_PODMAN`, `OC_SYSTEMCTL` and `OC_CURL` with fakes. `deploy.yml`: a push to `staging` deploys to staging; a push to `main` runs in the GitHub environment `production`, which needs a manual approval. Both build and test in CI, build the two images, run the Task 3b checks, `docker save` them to one tarball, and run `ssh -o StrictHostKeyChecking=yes` with `DEPLOY_SSH_KEY` and `DEPLOY_KNOWN_HOSTS`. Verifier checks added: DEP-01 the deploy user has no shell access (its `authorized_keys` line has `command=`, `restrict` and no pty) and no sudo rights beyond the one entry; DEP-02 the deploy user cannot read `/etc/oc`.

- [ ] **Step 1: Write the failing tests** in `deploy-release.test.sh` (plain bash with fakes on `PATH`): `success loads, repoints and restarts both services`; `a failed health check restores the previous tags and exits 1`; `bad env exits 2`; `bad sha exits 2` (including `../x`, a 39-character hex and a 41-character hex); `bad image id exits 2`; `an image id that does not match what was loaded exits 3 and changes nothing`; `keeps only the 3 newest tags`; `a second deploy at the same time is refused` (use `flock`); `a failing health check with no previous release exits 1 and leaves the services stopped`; `only the Image= line of the Quadlet files changes`. Run it. Expected: FAIL (scripts missing).
- [ ] **Step 2: Implement** both scripts. Run the tests. Expected: all PASS; `shellcheck` clean.
- [ ] **Step 3: The SSH and Quadlet items tied to the deploy user** (each gets a breakage test that fails for its stated reason, as in Task 3): make `ssh_allowed_users()` the single source for `AllowUsers` in `ssh_assert_effective` (`infra/lib/ssh.sh`) and in SSH-03 (`infra/verify.sh`), and add the deploy user there; add a `Match User deploy` block (no forwarding, no tty, no agent, no X11), and evaluate `sshd -T -C user=<u>,host=x,addr=203.0.113.1` for each allowed user in SSH-01, SSH-02 and `ssh_assert_effective`, or fail on any other `Match` block; add `Pull=never` to both Quadlet templates, and document that the units fail at boot until the first deploy because the bootstrap image tag does not exist.
- [ ] **Step 4: Write `deploy.yml`** and add `actionlint` to CI. Expected: CI green. Do not run the workflow yet.
- [ ] **Step 5: Run everything and commit.** `bash infra/test/run.sh` (full, with the idempotence proof), `shellcheck`, `pnpm typecheck && pnpm test && pnpm build`. Commit: `feat(infra): deploy pipeline`.

### Task 4b: Verifier and image follow-ups

These are the findings from the Task 3 and Task 3b reviews that were deferred as out of scope, each now owned. Every fix gets a breakage test that fails for its stated reason, as in Task 3.

**Files:**
- Modify: `infra/verify.sh`, `infra/lib/*.sh` and `infra/test/container-run.sh` and `infra/test/parser-cases.sh` as needed, `.dockerignore`, `infra/images/verify-image.sh`, `infra/images/verify-image.test.sh`, `infra/images/dockerignore.test.sh`, `apps/cms/Dockerfile`, `apps/web/Dockerfile`, `.github/workflows/ci.yml`, `renovate.json`, `package.json` (the pnpm integrity hash)

**Interfaces:**
- Produces: verifier checks NET-03 (hardened), CTR-04 (new), plus the tightened checks listed; no change to the interfaces other tasks consume.

- [ ] **Step 1: NET-03 false passes.** (i) Refuse any `ssl` directive, in any case and at any level (`ssl on;`, `ssl ON;`, http-level). (ii) Treat every server on an address and port as TLS when any `listen` there has `ssl` (or refuse ports that mix ssl and non-ssl). (iii) Compare `ssl_verify_client` without regard to case.
- [ ] **Step 2: CTR-04.** The environment users have no user-level systemd overrides (`~/.config/systemd/user/oc-*-<env>.service` or `.service.d/`) and no `~/.config/containers/containers.conf` or `containers.conf.d/`. In live mode also compare `systemctl --user cat oc-*-<env>` and `podman inspect` of the running containers with the expected hardening.
- [ ] **Step 3: Verifier honesty.** `q_check_generated` must check the values of `--read-only=`, `--rm=`, `--replace=` and `-d`, and `--tmpfs` must refuse `exec`; SVC-02 must treat `;` lines in the web env file as variable names (Podman reads only `#` as a comment); TLS-01 must require the certificate's issuer to be Cloudflare's Origin CA or publicly trusted; DB-01 must catch any account other than the environment's own with privileges on its database, whatever it is named; NGX-01 must not anchor `server_tokens` and `client_max_body_size` to the line start; NET-01 must check `IPV6=yes` in `/etc/default/ufw`; the live NET-03 branch must say when it skips wildcard, `_` or regex server names and must also curl any non-443 TLS listen.
- [ ] **Step 4: Image checks.** `.dockerignore`: add `**/.npmrc`, `**/.yarnrc*`, `**/*.pfx`, `**/*.crt`, `**/id_*`, `**/secrets`, `**/*.gpg`, `**/*.age`, `**/*.zip`, `**/*.tar*`, `**/*.dump`, `**/*.bak` and extend `dockerignore.test.sh` to plant each. `verify-image.sh`: require an explicit non-zero gid (or check `/proc/1/status`); prove the read-only root from `/proc/mounts` and soften the overclaiming comment; use `$db_host` for `DATABASE_HOST`; restore the original umask; fail if any `esbuild` ELF remains in an image; prune `__tests__` and `test` directories in the cms image and widen the forbidden-file pattern to match. CI: `persist-credentials: false` on checkout, Trivy `--timeout 15m` and a shared cache directory, consider a `.trivyignore.yaml` with `expired_at` for the two temporary exceptions. Pin the `packageManager` field in the root `package.json` with `+sha512`, and pin the `mariadb` CI service and client images by digest.
- [ ] **Step 5: Renovate and wording.** In `renovate.json`: set `pinDigests: false` for `mariadb` (or change the CI filter so a digest-pinned image still matches), keep major updates in their own pull request (`matchUpdateTypes` limited to minor, patch, digest and pin in the weekly group), and add a `minimumReleaseAge` of a few days for non-security updates. Correct the three comment wording gaps in the Dockerfiles and `ci.yml`: the weekly scan fails on a HIGH or CRITICAL fixable vulnerability in the final image (the distroless base and the app layers, not the build stage), and Renovate opens the bump pull request once its GitHub app is installed on the repository.
- [ ] **Step 6: Run everything and commit.** Full `bash infra/test/run.sh`, `bash infra/images/verify-image.test.sh`, `dockerignore.test.sh`, `check-dockerfile-users.test.sh`, hadolint, `shellcheck`, and `pnpm typecheck && pnpm test && pnpm build`. Rebuild both images and run `verify-image.sh` on each. Commit: `fix(infra): close the verifier and image findings from review`.

### Task 4c: The baseline run on the VPS

This task is run by the owner, with the controller's help. It needs the VPS, so it can happen any time after Task 4b and does not block the application tasks.

- [ ] **Step 1: Local RBAC check (spec Phase 0 item 8).** In a local Strapi, register a custom condition in `register()` via `strapi.service('admin::permission').conditionProvider.register({ name, displayName, handler })` that returns `{ name: { $eq: 'Company 01' } }`. Give a role "update Company" with that condition. Through the admin REST API a user with that role gets 200 updating Company 01 and 403 on Company 02. Record PASS or FAIL and the mechanism in `docs/phase0/report.md`. If it fails, record that the per-company-roles fallback applies. Revert the spike code; commit only the report.
- [ ] **Step 2: The server run.** For each of spec Phase 0 items 1 to 7, do the step, record the result and any value in `docs/phase0/report.md`, with these pass criteria. (1) The VPS exists (KVM 2, Ubuntu 24.04, 24-month term) and the owner can SSH in with a key. (2) `bash infra/bootstrap.sh` then `bash infra/verify.sh` shows no FAIL; record the Lynis hardening index. (3) Record the versions of Podman, MariaDB, ClamAV and Nginx, and the Node version each image reports. (4) Push the skeletons to the `staging` branch: the workflow deploys, `curl https://staging.<domain>/healthz` and the CMS `/_health` answer, then push a release whose health check is made to fail and confirm the previous tags are serving again. (5) As the `oc-staging` user write `/var/lib/oc/staging/media/probe.txt`, deploy again, and the file is still there and readable inside the web container; `curl https://staging.<domain>/probe.txt` and `/media/../probe.txt` are 404; `clamdscan` on a file containing the EICAR test string reports `FOUND`; `podman exec` into a container fails because there is no shell. (6) Cloudflare proxies the hostnames; `curl -k --resolve staging.<domain>:443:<server-ip> https://staging.<domain>/` straight to the IP is refused; a signed-out request to the staging host redirects to Cloudflare Access. (7) `npx autocannon -c 50 -d 60 https://staging.<domain>/healthz`: no errors, then record `free -m`, CPU and `df -h`; if free memory is under 1 GB, record that O2 needs a larger plan. Also at this step, with the owner: compare the committed Cloudflare origin-pull CA's SHA-256 (`c14fed0ce5210db0719fea11d1f10b33750dc17d609aeaf47c75e9eff0d7b843`) with Cloudflare's documentation, decide between Cloudflare's shared origin-pull certificate and a zone-level one, and install the Renovate GitHub app.
- [ ] **Step 3: Close out.** Fill `docs/deploy.md` (the exact commands, environment variables, secrets list, and how to roll back by hand) and add a **GO** or **NO-GO** line to the report. Items 2 and 4 failing is NO-GO: stop and take it to Slatech. Get Slatech's sign-off on the line. Commit: `docs: Phase 0 report and deploy notes`.

---

## Phase 1: Foundation

### Task 5: Brand-colour accessibility (`deriveAccent`)

**Files:**
- Create: `packages/shared/src/colour.ts`, `packages/shared/src/colour.test.ts`
- Modify: `packages/shared/src/index.ts`

**Interfaces:**
- Produces: `class InvalidColourError extends Error`; `contrast(a: string, b: string): number` (WCAG ratio, both `#RRGGBB`); `type DerivedAccent = { brand: string; onAccent: '#FFFFFF' | '#0B1F3A' | '#000000'; accentOnWhite: string }`; `deriveAccent(hex: string): DerivedAccent`. `brand` is uppercased. `onAccent` is the first of white, deep navy, black reaching 4.5:1 on the brand. `accentOnWhite` is the brand darkened (same hue, lower lightness) until it reaches 4.5:1 on `#FFFFFF`, or the brand itself if it already does.

- [ ] **Step 1: Write the failing tests** in `colour.test.ts`:
  - `contrast('#FFFFFF','#000000')` is `21` (`toBeCloseTo(21, 1)`).
  - `deriveAccent('#ffff00').brand === '#FFFF00'`, `.onAccent === '#0B1F3A'`, and `contrast(.accentOnWhite, '#FFFFFF') >= 4.5`.
  - `deriveAccent('#808080').onAccent === '#000000'` (neither white nor navy reaches 4.5:1).
  - For each prototype sample colour `#1D4ED8 #0F766E #B45309 #7C3AED #BE123C #15803D #0369A1 #A16207 #C2410C #475569`: `contrast(onAccent, brand) >= 4.5` and `contrast(accentOnWhite, '#FFFFFF') >= 4.5`.
  - `#FFFFFF` and `#000000` both produce `contrast(onAccent, brand) >= 4.5` and `contrast(accentOnWhite,'#FFFFFF') >= 4.5`.
  - `'#fff'`, `'red'`, `'#GGGGGG'`, `''` each throw `InvalidColourError`.
  Run `pnpm --filter @oc/shared test`. Expected: FAIL (module missing).
- [ ] **Step 2: Implement** `colour.ts` to the signatures above. Use the WCAG relative-luminance formula. Darken by reducing HSL lightness in 1% steps.
- [ ] **Step 3:** Run the tests. Expected: PASS. Commit: `feat(shared): derive accessible text colours from brand colours`.

### Task 6: Design tokens and self-hosted fonts

**Files:**
- Create: `packages/shared/src/tokens.ts`, `packages/shared/src/tokens.test.ts`, `apps/web/src/styles/tokens.css`, `apps/web/src/styles/global.css`, `apps/web/tests/e2e/fonts.spec.ts`
- Modify: `apps/web/package.json` (add `@fontsource-variable/manrope`, `@fontsource-variable/inter`)

**Interfaces:**
- Produces: `palette` (keys `deepNavy groupNavy gold darkGold lightGrey slate`) and `fontStack` in `tokens.ts`. CSS custom properties in `tokens.css`: `--navy`, `--navy-2`, `--gold`, `--gold-text`, `--grey`, `--slate`, `--font-heading`, `--font-body`, plus `--company-accent`, `--company-on-accent`, `--company-accent-text` (defaults to navy tokens).

- [ ] **Step 1: Write the failing tests.** `tokens.test.ts`: each of the six palette values equals the hex in Global Constraints. `fonts.spec.ts`: load `/`, record every request, assert none goes to a host containing `googleapis` or `gstatic`, at least one `.woff2` request is same-origin, and `getComputedStyle(document.body).fontFamily` starts with `Inter`. Run both. Expected: FAIL.
- [ ] **Step 2: Implement** `tokens.ts`, `tokens.css` and `global.css` (body 17px Inter, headings Manrope 800, 48px form fields, a visible `:focus-visible` ring, `prefers-reduced-motion` disables transitions). Import the fontsource packages in the base layout.
- [ ] **Step 3:** Run the tests. Expected: PASS. Commit: `feat(web): design tokens and self-hosted fonts`.

### Task 7: CMS content model and the colour hook

**Files:**
- Create: `apps/cms/src/components/shared/{seo,figure,social-link}.json`, `apps/cms/src/components/company/leader.json`, `apps/cms/src/api/company/content-types/company/{schema.json,lifecycles.ts}`, `apps/cms/src/api/home/content-types/home/schema.json`, `apps/cms/src/api/site-setting/content-types/site-setting/schema.json`, `apps/cms/tests/helpers/strapi.ts`, `apps/cms/tests/company.test.ts`
- Modify: `apps/cms/config/plugins.ts` (i18n on, locale `en` only)

**Interfaces:**
- Produces: Company (`api::company.company`, collection, draft and publish on): `name` (required), `slug` (uid from name), `legalName`, `rcNumber`, `founded` (integer), `headOffice`, `contactEmail`, `contactPhone`, `brandColour` (required string), `onAccent`, `accentOnWhite`, `logo` (media), `tagline`, `overview` (blocks), `leaders` (repeatable `company.leader`: `name`, `title`, `bio`, `portrait`), `figures` (repeatable `shared.figure`: `value`, `label`), `heroHeadline`, `heroSubtext`, `heroImage` (media), `sortOrder` (integer, default 0), `active` (boolean, default true), `seo` (`shared.seo`). Home (`api::home.home`, single): `groupHeadline`, `groupSubtext`, `groupVideo`, `groupPoster`, `figures`, `seo`. Site settings (`api::site-setting.site-setting`, single): `emergencyLine`, `whatsappNumbers` (json), `socialLinks` (repeatable `shared.social-link`), `footerText`, `companyNumber`, `chatHours`. Test helper: `startStrapi(): Promise<Strapi>`, `stopStrapi(): Promise<void>`, `readOnlyToken(): Promise<string>`, `http(): supertest.Agent`; it runs against DB `oc_test` and empties content tables between tests. Lifecycle `beforeCreate` and `beforeUpdate` call `deriveAccent` and fill `onAccent` and `accentOnWhite`; on `InvalidColourError` they throw Strapi's `ValidationError` with the message `Brand colour must be a 6-digit hex like #1D4ED8`.

- [ ] **Step 1: Write the failing tests** in `company.test.ts`, using `strapi.documents('api::company.company')`:
  - `stores derived colours`: create with `brandColour: '#FFFF00'`; `onAccent === '#0B1F3A'` and `accentOnWhite` reaches 4.5:1 on white.
  - `mid-tone brand gets black text`: `'#808080'` gives `onAccent === '#000000'`. (Review Focus 3)
  - `recomputes on update`: change to `'#1D4ED8'`; `onAccent === '#FFFFFF'`.
  - `rejects bad colours`: `'#fff'`, `'red'`, `'#GGGGGG'` each reject with the message above. (Review Focus 3)
  - `company saves with only name and colour`: no logo, hero or leaders; it saves. (Review Focus 2)
  - `slug is unique`: two companies named "Alpha" get different slugs.
  Run `pnpm --filter @oc/cms test`. Expected: FAIL.
- [ ] **Step 2: Implement** the schemas, components, lifecycles and test helper to the interfaces above. Add `apps/cms` test script (vitest, node environment, single worker).
- [ ] **Step 3:** Run the tests. Expected: PASS. Run `pnpm --filter @oc/cms develop` and add a company by hand to confirm the admin shows all fields. Commit: `feat(cms): company, home and site settings content types`.

### Task 8: Locked-down API and the typed client

**Files:**
- Create: `apps/cms/src/middlewares/internal-secret.ts`, `apps/cms/tests/api-lockdown.test.ts`, `packages/shared/src/content-types.ts`, `apps/web/src/lib/strapi.ts`, `apps/web/src/lib/strapi.test.ts`, `apps/web/src/pages/503.astro`, `apps/web/tests/e2e/cms-down.spec.ts`
- Modify: `apps/cms/config/middlewares.ts`

**Interfaces:**
- Produces in `content-types.ts`: `MediaRef = { url: string; alt: string | null; width: number | null; height: number | null }`; `Leader`, `Figure`, `Seo`; `Company` (every field listed in Task 7 with `logo`/`heroImage` as `MediaRef | null` and `leaders`/`figures` as arrays); `Home`; `SiteSettings`. In `strapi.ts`: `class CmsUnavailableError extends Error`; `cms.get<T>(path: string, init?: { timeoutMs?: number }): Promise<T>` (default timeout 5000 ms, one retry, sends `Authorization: Bearer ${OC_CMS_API_TOKEN}` and `x-oc-secret`); `getCompanies(): Promise<Company[]>` (active only, ordered by `sortOrder` then `name`); `getCompany(slug: string): Promise<Company | null>`; `getHome(): Promise<Home | null>`; `getSiteSettings(): Promise<SiteSettings | null>`. Middleware `global::internal-secret` rejects any `/api/*` request lacking a matching `x-oc-secret` (timing-safe compare) with 403.

- [ ] **Step 1: Write the failing tests.**
  - `api-lockdown.test.ts`: `GET /api/companies` with no secret is 403; with the secret and no token is 401 or 403; with secret and read-only token is 200; **a draft-only company is absent from the list and `GET /api/companies?filters[slug]=<draft>` returns an empty `data`** (Review Focus 1); a published company appears.
  - `strapi.test.ts` (vitest with a mocked `fetch`): `cms.get` retries once on a network error; throws `CmsUnavailableError` after the timeout; `getCompany('missing')` returns `null` on an empty `data`; `getCompanies` drops `active: false`.
  - `cms-down.spec.ts`: with `OC_CMS_URL` pointing at a closed port, `GET /group` returns status 503, shows the text "temporarily unavailable", and the body contains neither `at ` stack lines, `OC_CMS_API_TOKEN` nor `x-oc-secret`; `GET /healthz` is 200 with `{ ok: true, cms: false }`. (Review Focus 4)
  Run them. Expected: FAIL.
- [ ] **Step 2: Implement.** Register the middleware at the front of `config/middlewares.ts`. In Strapi, switch off every permission of the Public role (seed it in bootstrap) and create a read-only API token in `.env.example` instructions. Implement the client and render `503.astro` when a page catches `CmsUnavailableError`. Extend `healthz.ts` to probe `${OC_CMS_URL}/_health` with a 2 s timeout and return `{ ok: true, cms: boolean }`, always status 200.
- [ ] **Step 3:** Run all of them. Expected: PASS. Commit: `feat: lock the CMS API and add the typed client`.

### Task 9: Media on disk, outside the deploy folders

**Files:**
- Create: `apps/cms/providers/upload-oc-disk/{index.ts,index.test.ts}`, `apps/web/src/pages/media/[...path].ts`, `apps/web/tests/e2e/media.spec.ts`
- Modify: `apps/cms/config/plugins.ts` (upload provider), `apps/cms/config/middlewares.ts` (`strapi::security` `img-src` allows the site's `/media`)

**Interfaces:**
- Produces: a Strapi upload provider (`init(config) => { upload(file), uploadStream(file), delete(file), isPrivate(): false }`) that writes `${OC_DATA_DIR}/media/<sha256-prefix>.<ext>` and sets `file.url = '/media/<name>'`. Astro route `GET /media/*` streams that file with `Cache-Control: public, max-age=31536000, immutable`. Only `.png .jpg .jpeg .webp .avif .svg .pdf .mp4` are served.

- [ ] **Step 1: Write the failing tests.** `index.test.ts`: `upload` writes the file under a hashed name and sets `url`; the same bytes uploaded twice give one file; `delete` removes it; a file name with `../` cannot escape `media/`. `media.spec.ts`: a file placed in the media folder is served 200 with the immutable header and the right content type; `GET /media/..%2f..%2fetc%2fpasswd` and `GET /media/%2e%2e/secret.txt` return 404; `GET /media/x.exe` returns 404; an `.svg` response carries `Content-Security-Policy: sandbox`. Run them. Expected: FAIL.
- [ ] **Step 2: Implement** the provider and route. Resolve the path with `path.resolve` and refuse anything whose result doesn't start with the media root. Read the media folder from `OC_DATA_DIR` in both apps.
- [ ] **Step 3:** Run the tests. Expected: PASS. Upload an image through the admin and confirm it appears at `/media/<name>` on the web app. Commit: `feat: store uploaded media on disk outside the deploy folders`.

### Task 10: Seed script and end-to-end data

**Files:**
- Create: `apps/cms/scripts/seed.ts`, `apps/cms/tests/seed.test.ts`, `apps/web/tests/e2e/global-setup.ts`
- Modify: `apps/cms/package.json` (script `seed`), `playwright.config.ts` (`globalSetup`)

**Interfaces:**
- Produces: `seed(strapi: Strapi, opts?: { companies?: number; reset?: boolean }): Promise<void>`. It creates, **published**, the Home, Site settings and N companies (default 10) named `[Company 01]` and so on, with the ten prototype sample colours cycling and sort order 1 to N. Every text value is a visibly bracketed placeholder. `pnpm --filter @oc/cms seed -- --companies 3 --reset` runs it. The Playwright global setup runs a reset seed of 10.

- [ ] **Step 1: Write the failing test** in `seed.test.ts`: `seed` with `companies: 3` creates 3 published companies; running it twice (no reset) still leaves 3 (idempotent); `reset: true` with `companies: 2` leaves exactly 2; the site settings and home entries are published.
- [ ] **Step 2:** Run it. Expected: FAIL. Implement `seed` with the Document Service (`strapi.documents(uid).create({ data, status: 'published' })`) and match on `slug` for idempotency.
- [ ] **Step 3:** Run it. Expected: PASS. Commit: `feat(cms): seed script for development and end-to-end tests`.

### Task 11: Security headers, caching and `/healthz`

**Files:**
- Create: `apps/web/src/lib/csp.ts`, `apps/web/src/lib/csp.test.ts`, `apps/web/src/middleware.ts`, `apps/web/tests/e2e/headers.spec.ts`

**Interfaces:**
- Produces: `buildCsp(opts: { mode: 'report-only' | 'enforce'; scriptNonce?: string }): { name: 'Content-Security-Policy' | 'Content-Security-Policy-Report-Only'; value: string }`. Middleware sets on every response: the CSP (mode from `CSP_MODE`), `Strict-Transport-Security: max-age=31536000; includeSubDomains` (no `preload`), `X-Content-Type-Options: nosniff`, `Referrer-Policy: strict-origin-when-cross-origin`, `Permissions-Policy: camera=(), microphone=(), geolocation=()`. HTML responses without a session cookie also get `Cache-Control: public, max-age=0, s-maxage=60, stale-while-revalidate=300`, and `/healthz` gets `Cache-Control: no-store`.

- [ ] **Step 1: Write the failing tests.** `csp.test.ts`: the value contains `default-src 'self'`, `frame-ancestors 'none'`, `base-uri 'none'`, `form-action 'self'`; with a nonce it contains `'nonce-<value>'` in `script-src` and never `'unsafe-inline'` in `script-src`; mode `report-only` gives the `-Report-Only` header name. `headers.spec.ts`: `GET /` has all five headers above, and the HTML cache header; `GET /healthz` has `no-store`.
- [ ] **Step 2:** Run them. Expected: FAIL. Implement. If the installed Astro has built-in CSP support, use it for script hashes; otherwise use a per-request nonce. The tests pin the header values either way.
- [ ] **Step 3:** Run them. Expected: PASS. Commit: `feat(web): security headers and caching`.

### Task 12: Base layout, header and footer

**Files:**
- Create: `packages/shared/src/initials.ts`, `packages/shared/src/initials.test.ts`, `apps/web/src/lib/navigation.ts`, `apps/web/src/layouts/Base.astro`, `apps/web/src/components/{Header,Footer}.astro`, `apps/web/src/islands/mega-menu.ts`, `apps/web/tests/e2e/chrome.spec.ts`

**Interfaces:**
- Consumes: `getSiteSettings()`, `getCompanies()`.
- Produces: `initials(name: string): string`: strips a leading bracket, takes the first letters of up to two words, uppercased (`'[Company 03]'` gives `'C0'`; `'Alpha Beta Gamma'` gives `'AB'`; `''` gives `'?'`). `Base.astro` with props `{ title: string; description?: string; noindex?: boolean }`. Header (prototype board 09): top bar with emergency line from site settings and links to Procurement, Careers, Investors and "EN"; logo; nav About us, Our companies (mega-menu), Services, Industries, Projects, News, Contact; search link; "Request a quote" button. Footer (board 10): columns The group, What we do, Portals, Contact; legal row with the current year and `companyNumber`.

- [ ] **Step 1: Write the failing tests.** `initials.test.ts` as above. `chrome.spec.ts`: the header shows the seeded emergency line; the first Tab stop is a "Skip to content" link that moves focus to `main`; with Enter on "Our companies" the mega-menu opens with `aria-expanded="true"` and lists every active seeded company (10), and Escape closes it and returns focus to the trigger; the footer shows the `companyNumber` and the current year; run `@axe-core/playwright` on `/` and expect no violations. Run them. Expected: FAIL.
- [ ] **Step 2: Implement** the layout, components and island from the prototype markup in `design/prototype/09-site-header.html` and `10-site-footer.html`, replacing the inline styles with the token classes. Company chips show `logo` or `initials` on the company's brand colour.
- [ ] **Step 3:** Run them. Expected: PASS. Commit: `feat(web): layout, header and footer`.

### Task 13: Hero slider and the home page top

**Files:**
- Create: `packages/shared/src/slides.ts`, `packages/shared/src/slides.test.ts`, `apps/web/src/components/HeroSlider.astro`, `apps/web/src/islands/hero-slider.ts`, `apps/web/src/pages/index.astro`, `apps/web/tests/e2e/hero.spec.ts`

**Interfaces:**
- Consumes: `getHome()`, `getCompanies()`, `Company`, `Home`.
- Produces: `type Slide = { kind: 'group' | 'company'; id: string; eyebrow: string; headline: string; subtext: string; image: MediaRef | null; brand: string; onAccent: string; href: string; cta: { label: string; href: string }[] }`; `buildSlides(home: Home | null, companies: Company[]): Slide[]`. The group slide is always first. Company slides follow in `sortOrder`, active only. A missing `heroHeadline` falls back to the company `name`; a missing image gives `image: null`.

- [ ] **Step 1: Write the failing tests.** `slides.test.ts`: group slide first; inactive companies excluded; sorted by `sortOrder`; **0 companies gives only the group slide; 12 give 13 slides** (Review Focus 5); a company with no hero fields gets `headline === name` and `image === null`, and no field is the string `'undefined'` (Review Focus 2). `hero.spec.ts` (Playwright, `page.clock`): 11 slides; the counter reads `01 / 11`; after `clock.fastForward(6000)` it reads `02 / 11`; the pause button is labelled "Pause the slideshow" and after click "Play the slideshow" and the slider stops advancing; next from the last slide wraps to the first; a chip has `aria-current="true"` for the current slide; with `reducedMotion: 'reduce'` the slider starts paused and the group slide renders no `<video>`; the desktop card stack shows a link per company with `href="/companies/<slug>"` (client note, 9 November); with only the group seeded (`companies: 0`) the page renders one slide with no errors and no prev/next. Run them. Expected: FAIL.
- [ ] **Step 2: Implement** `buildSlides`, then the component and island from `design/prototype/01-home-desktop.html`. Group slide: muted `playsinline` video with `preload="none"` and the poster as the first paint; the video starts after the `load` event. Labels from the prototype: "Explore our group", "Request a quote", "Work with us"; company slides "Explore <name>", "Request a quote", "All companies".
- [ ] **Step 3:** Run them. Expected: PASS. Commit: `feat(web): home hero slider driven by the CMS`.

### Task 14: Home snapshot and the Our Group page

**Files:**
- Create: `apps/web/src/components/CompanyCard.astro`, `apps/web/src/pages/group.astro`, `apps/web/tests/e2e/group.spec.ts`
- Modify: `apps/web/src/pages/index.astro` (headline figures and "Our group" section)

**Interfaces:**
- Consumes: `getHome()`, `getCompanies()`.
- Produces: `CompanyCard.astro` with props `{ company: Company }`, a card in the company's colours showing logo or initials chip, name, tagline and a "Visit company page" link to `/companies/<slug>`.

- [ ] **Step 1: Write the failing tests** in `group.spec.ts` (seeded with 3 companies): `/group` lists 3 cards, each linking to its `/companies/<slug>`; after seeding 11 it lists 11 with no code change; a company published then unpublished in the CMS disappears from `/group` and `/` within 60 s, **and a draft-only company never appears** (Review Focus 1); a company with no logo shows its initials chip and no `<img>` with an empty `src` (Review Focus 2); the holding-company box and structure chart render; `/` shows the headline figures from the Home entry and omits the figures block when there are none; axe finds no violations on `/group`. Run them. Expected: FAIL.
- [ ] **Step 2: Implement** from `design/prototype/03-our-group.html` and the Our group and figures sections of board 01.
- [ ] **Step 3:** Run them. Expected: PASS. Commit: `feat(web): our group page and home snapshot`.

### Task 15: Company page template

**Files:**
- Create: `apps/web/src/pages/companies/[slug].astro`, `apps/web/tests/e2e/company.spec.ts`

**Interfaces:**
- Consumes: `getCompany(slug)`, `Company`.
- Produces: page `/companies/<slug>`. It sets `--company-accent`, `--company-on-accent` and `--company-accent-text` on the page root from `brandColour`, `onAccent` and `accentOnWhite`. Sections, each omitted when empty: hero, overview, company facts (registered name, RC number, founded, head office, contact), leadership, figures, "Talk to this company" call to action linking to `/contact?company=<slug>`. An unknown or unpublished slug returns 404.

- [ ] **Step 1: Write the failing tests** in `company.spec.ts`: a seeded company renders its name, facts and CTA; `/companies/does-not-exist` is 404; a **draft-only** company's slug is 404 (Review Focus 1); a company with no logo, leaders, figures or overview renders no empty headings, no `<img src="">` and no text `undefined` (Review Focus 2); with brand colour `#FFFF00` and `#808080` axe reports no `color-contrast` violations on the page (Review Focus 3); the page sets `--company-accent` equal to the brand colour. Run them. Expected: FAIL.
- [ ] **Step 2: Implement** from `design/prototype/04-company-template.html`. Render the `overview` blocks through a structured renderer; never raw HTML.
- [ ] **Step 3:** Run them. Expected: PASS. Commit: `feat(web): company page template`.

### Task 16: Audit log

**Files:**
- Create: `apps/cms/src/api/audit-event/content-types/audit-event/{schema.json,lifecycles.ts}`, `apps/cms/src/audit/{service.ts,subscribers.ts}`, `apps/cms/tests/audit.test.ts`
- Modify: `apps/cms/src/index.ts` (register subscribers in `bootstrap`)

**Interfaces:**
- Produces: `type AuditInput = { action: string; actorType: 'admin' | 'portal' | 'system' | 'anonymous'; actorId: string | null; subjectType: string | null; subjectId: string | null; before?: unknown; after?: unknown; ipHash?: string | null }`; `audit.record(input: AuditInput): Promise<void>` (exposed as `strapi.service('api::audit-event.audit-event').record`); `class AuditAppendOnlyError extends Error`. The content type has no draft and publish, and **no public routes**. Events written: `admin.login.success`, `admin.login.failed` (from the event hub's admin auth events; confirm the exact event names in the installed Strapi), `content.publish` and `content.unpublish` for companies, `role.updated` (from a database lifecycle on `admin::role`).

- [ ] **Step 1: Write the failing tests** in `audit.test.ts`: `record` stores a row with every field; updating a stored row through the Document Service or the database layer throws `AuditAppendOnlyError`, and so does deleting it; publishing a company writes `content.publish` with the company's `documentId` as `subjectId`; emitting the admin auth failure event writes `admin.login.failed`; `GET /api/audit-events` returns 404 even with secret and token. Run them. Expected: FAIL.
- [ ] **Step 2: Implement** the service, the lifecycle guard and the subscribers.
- [ ] **Step 3:** Run them. Expected: PASS. Commit: `feat(cms): append-only audit log`.

### Task 17: Admin roles and the company condition

**Files:**
- Create: `apps/cms/src/bootstrap/roles.ts`, `apps/cms/src/api/staff-company-assignment/content-types/staff-company-assignment/schema.json`, `apps/cms/src/services/assigned-companies.ts`, `apps/cms/src/conditions/own-company.ts`, `apps/cms/tests/roles.test.ts`
- Modify: `apps/cms/src/index.ts` (register conditions in `register`, call `ensureRoles` in `bootstrap`)

**Interfaces:**
- Produces: `ensureRoles(strapi: Strapi): Promise<void>` (idempotent). It creates the roles Group Administrator, Communications, Company Editor, Procurement Officer, Group HR, Company HR and Investor Relations Officer; permissions for the types that exist in Plan 1 (Company, Home, Site settings, media), and nothing on `audit-event` for anyone except Super Admin. Content type `staff-company-assignment` with `adminUserId` (integer) and `company` (many-to-one). `getCompanyDocumentIds(adminUserId: number): Promise<string[]>`. Condition `own-company-entry` (for Company itself) restricts to `documentId` in the user's assigned companies. Use the mechanism Phase 0 item 11 proved; if it recorded that conditions don't work in Community, build one role per company with the same restriction and note it in `docs/deploy.md`.

- [ ] **Step 1: Write the failing tests** in `roles.test.ts`, through the real admin REST API with JWTs from `POST /admin/login`: `company editor can update their own company` is 200; `company editor gets 403 on another company`; `group administrator can update any company`; `company editor cannot read audit events` is 403; `ensureRoles twice creates each role once`. Run them. Expected: FAIL.
- [ ] **Step 2: Implement** to the interfaces. Record each denied attempt as `admin.permission.denied` through `audit.record`.
- [ ] **Step 3:** Run them. Expected: PASS. Commit: `feat(cms): admin roles and per-company permissions`.

### Task 18: Quality gates and staging live

**Files:**
- Create: `lighthouserc.json`
- Modify: `.github/workflows/ci.yml`, `playwright.config.ts` (skip starting local servers when `BASE_URL` points elsewhere), `docs/deploy.md` (extend)

**Interfaces:**
- Produces: CI jobs `e2e` (seeded Strapi and Astro against the CI database, Playwright with axe) and `lighthouse` (Lighthouse CI on `/`, `/group`, `/companies/<seeded slug>` with mobile emulation). Assertions: LCP at most 2500 ms, CLS at most 0.1, total compressed JavaScript at most 70 KB. The Task 4 pipeline deploys staging from the `staging` branch. With `BASE_URL` set to a remote address, `pnpm e2e` runs against it and starts nothing locally.

- [ ] **Step 1:** Add the two CI jobs and `lighthouserc.json`. Push a branch. Expected: both run; fix any budget breach by trimming JavaScript, not by raising the budget.
- [ ] **Step 2:** Merge to `staging`. The Task 4 workflow deploys both apps. Confirm `CSP_MODE=report-only` in `/etc/oc/staging.env`. Add UptimeRobot checks for `staging.<domain>/healthz` and the CMS `/_health`.
- [ ] **Step 3:** Put placeholder data on staging: run `pnpm --filter @oc/cms seed` on the server as `oc-staging`, or add the companies by hand in the staging admin. Then run `BASE_URL=https://staging.<domain> pnpm exec playwright test`. Expected: PASS.
- [ ] **Step 4:** Record the staging URL, the CI links and any CSP reports in `docs/deploy.md`. Commit: `ci: quality gates and staging deployment`. Ask Slatech to review staging before Plan 2.

---

## Self-review notes

- **Spec coverage.** Phase 0 items 1 to 8 are Tasks 3 and 4 (items 7 and 8 of the old list, email and backup, move to Plans 2 and 4, and the throttled upload to Plan 3, because they need code that doesn't exist yet). Phase 1 (content model, roles and conditions, audit log, design system, header and footer, home, Our Group, company template, CI, staging) is Tasks 5 to 18. The spec's media store, locked API, headers and caching are Tasks 8, 9 and 11. Left to later plans: scheduled publishing and the job runner, forms, CRM, search, consent (Plan 2); the file pipeline and portals (Plan 3); the backup job and hardening (Plan 4). The project case-study prototype board is a design task for Slatech in week 1, not code.
- **Type consistency.** `deriveAccent`, `InvalidColourError`, `CmsUnavailableError`, `getCompanies`, `getCompany`, `getHome`, `getSiteSettings`, `buildSlides`, `initials`, `AuditInput`, `audit.record`, `ensureRoles` and the env var names are used identically wherever they appear.
- **Open dependency.** Q4 (developer count and launch date) isn't answered. It decides whether Tasks 12 to 15 run in parallel with Tasks 16 and 17 (they touch different apps and files, so they can).
