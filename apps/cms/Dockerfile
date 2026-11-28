# The CMS (Strapi 5) as a minimal, non-root image: oc-cms.
#
# Build from the repository root (the build needs the whole pnpm workspace):
#   docker build -f apps/cms/Dockerfile -t oc-cms:dev .
# Check it with: bash infra/images/verify-image.sh oc-cms:dev
#
# Two stages. The build stage has a shell and package tools and is thrown away. The final stage
# is Google's distroless Node 22: no shell, no package manager, no root user. Only the built
# app and its production dependencies are copied across.
#
# Both base images are pinned by digest. The tag is only a label for people; the digest decides,
# so a build never changes by itself. How a security fix reaches the base: the weekly CI run
# scans the final image with Trivy (the distroless base and the app layers on top of it, not the
# build stage, which is thrown away) and fails when a HIGH or CRITICAL vulnerability that has a
# fix is in it. Once the Renovate GitHub app is installed on the repository, Renovate
# (renovate.json) opens the pull request that bumps the digest; until then a person bumps it by
# hand. Either way the base changes only when a person merges that change.
#   build stage: node:22-bookworm-slim, Node 22.23.5.
#   final stage: distroless nodejs22 on Debian 13, Node 22.23.5. The Debian 12 variant
#   (nodejs22-debian12) is still on Node 22.22.0, older than the 22.23.4 the spec requires.
#   Strapi loads @oc/shared (an ES module) with require(), which needs Node 22.12 or newer.

# ---- build stage -----------------------------------------------------------------------
FROM node:22-bookworm-slim@sha256:be979e5523c76fa4d5ca4ebd3099078f220aa47ec39c48ad5b5df9314debd6eb AS build

# Nothing in this stage needs root, so the first instruction makes it non-root. Corepack puts
# pnpm (the version in the root package.json, "packageManager") into the node user's own folder.
USER node
ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
    STRAPI_TELEMETRY_DISABLED=true \
    PATH="/home/node/bin:${PATH}"
RUN mkdir /home/node/bin /home/node/build \
    && corepack enable --install-directory /home/node/bin
WORKDIR /home/node/build

# Dependencies first, from the manifests and the lockfile only, so this layer is reused until
# one of them changes. --frozen-lockfile fails the build if the lockfile is out of date.
# Only the CMS, the shared package and what they need are installed, not the whole workspace.
# apps/web/package.json is here only because the workspace lists that project.
COPY --chown=node:node package.json pnpm-lock.yaml pnpm-workspace.yaml tsconfig.base.json ./
COPY --chown=node:node apps/cms/package.json apps/cms/
COPY --chown=node:node apps/web/package.json apps/web/
COPY --chown=node:node packages/shared/package.json packages/shared/
RUN pnpm install --frozen-lockfile --filter @oc/cms... --filter @oc/shared

# The sources, then @oc/shared first (the apps resolve it from its dist folder), then the app.
# Strapi compiles its TypeScript into dist/ and builds the admin panel into dist/build/.
# The admin build is memory-hungry, so it gets a bigger Node heap than the default.
# public/uploads is made empty here: the build context never holds local uploads (.dockerignore),
# but Strapi's local upload provider refuses to start if the folder is missing, and on a
# read-only root it cannot create it. It stays empty and read-only in the image.
COPY --chown=node:node packages/shared packages/shared
COPY --chown=node:node apps/cms apps/cms
RUN mkdir -p apps/cms/public/uploads \
    && pnpm --filter @oc/shared build \
    && NODE_OPTIONS=--max-old-space-size=3072 pnpm --filter @oc/cms build

# The production dependencies as a self-contained folder. `pnpm deploy` (pnpm 12) builds it from
# the workspace lockfile, so the versions are exactly the locked ones, and it copies workspace
# packages such as @oc/shared into node_modules instead of linking to the workspace. It needs no
# --legacy and no injected-packages setting. Only node_modules and package.json are taken from
# the result.
#
# Then what the image must not contain is removed (spec 10.9):
#  - the files and folders a dependency ships that are tests (*.test.*, *.spec.*, and folders
#    called __tests__, test or tests), and any .git, .cache or .env* entry;
#  - esbuild's native binary, which is in two places (the platform package, and a copy that
#    esbuild's install script puts over its own bin/esbuild). esbuild is a build tool that
#    Strapi's admin build pulls in; the app never starts it at run time. The Go standard
#    library inside the old 0.25.12 binary carries 26 HIGH and CRITICAL advisories (Trivy), so
#    the binary is left out instead of ignored.
# infra/images/verify-image.sh and the Trivy scan check the result.
RUN pnpm --filter @oc/cms deploy --prod /home/node/app \
    && find /home/node/app/node_modules \
        \( -name .git -o -name .cache -o -name '.env*' -o -name '*.test.*' -o -name '*.spec.*' \
           -o \( -type d \( -name __tests__ -o -name test -o -name tests \) \) \) \
        -prune -exec rm -rf '{}' + \
    && find /home/node/app/node_modules \
        \( -path '*/node_modules/@esbuild/*/bin/esbuild' -o -path '*/node_modules/esbuild/bin/esbuild' \) \
        -type f -delete

# ---- final stage -----------------------------------------------------------------------
FROM gcr.io/distroless/nodejs22-debian13:nonroot@sha256:c73ddeb03e1dc2d579aa111c83d6699c6b8b487e35c0c631d4a3a20229fc25ee AS final

# The first COPY creates /app, owned by root, and WORKDIR then finds it there. WORKDIR on its
# own would create the folder for the user in force at that moment, which is the base image's
# 65532 whatever this file says (and a folder made after USER 65532 is 65532's too), and the
# process could then replace what is in it, files owned by root or not. verify-image.sh checks
# the owner of /app.
COPY --from=build --chown=0:0 /home/node/app/package.json /app/package.json
# Strapi starts from the current folder, so the app lives in /app and that is the WORKDIR.
WORKDIR /app
# The group is written down as well as the user: a uid with no group runs with gid 0 when the
# image's /etc/passwd has no entry for it, and infra/images/verify-image.sh refuses that.
USER 65532:65532
# Telemetry is already off in package.json; the variable makes sure of it. HOME is /tmp because
# the container may run as a user with no home folder, and Strapi's command loader wants to
# create ~/.config; /tmp is the one writable tmpfs.
ENV NODE_ENV=production \
    STRAPI_TELEMETRY_DISABLED=true \
    HOME=/tmp

# Only what `strapi start` reads: package.json, tsconfig.json (it names the dist folder), the
# compiled app and admin panel in dist/, the public folder and favicon, the folder for user
# migrations (Strapi creates it at start if it is missing, which a read-only root forbids), the
# production dependencies, and the health check. Owned by root and not writable: the process
# cannot change its own code, whatever user the container runs as (the server runs it as the
# environment's own user, --userns=keep-id). The sources in src/ and config/ are not copied;
# dist/ holds them compiled.
COPY --from=build --chown=0:0 /home/node/app/node_modules ./node_modules
COPY --from=build --chown=0:0 /home/node/build/apps/cms/tsconfig.json ./tsconfig.json
COPY --from=build --chown=0:0 /home/node/build/apps/cms/dist ./dist
COPY --from=build --chown=0:0 /home/node/build/apps/cms/public ./public
COPY --from=build --chown=0:0 /home/node/build/apps/cms/favicon.png ./favicon.png
COPY --from=build --chown=0:0 /home/node/build/apps/cms/database ./database
COPY --chown=0:0 apps/cms/healthcheck.mjs ./healthcheck.mjs

# Docker's own health status. The Quadlet file runs the same script with HealthCmd.
HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 \
    CMD ["/nodejs/bin/node", "/app/healthcheck.mjs"]

# The base image's entrypoint is /nodejs/bin/node, so this runs: node .../strapi.js start
CMD ["/app/node_modules/@strapi/strapi/bin/strapi.js", "start"]
