# The website (Astro, server-rendered) as a minimal, non-root image: oc-web.
#
# Build from the repository root (the build needs the whole pnpm workspace):
#   docker build -f apps/web/Dockerfile -t oc-web:dev .
# Check it with: bash infra/images/verify-image.sh oc-web:dev
#
# Two stages. The build stage has a shell and package tools and is thrown away. The final stage
# is Google's distroless Node 22: no shell, no package manager, no root user. Only the built
# app and its production dependencies are copied across.
#
# Both base images are pinned by digest. The tag is only a label for people; the digest decides.
# CI rebuilds weekly and Renovate proposes new digests, so security fixes arrive.
#   build stage: node:22-bookworm-slim, Node 22.23.5.
#   final stage: distroless nodejs22 on Debian 13, Node 22.23.5. The Debian 12 variant
#   (nodejs22-debian12) is still on Node 22.22.0, older than the 22.23.4 the spec requires.

# ---- build stage -----------------------------------------------------------------------
FROM node:22-bookworm-slim@sha256:be979e5523c76fa4d5ca4ebd3099078f220aa47ec39c48ad5b5df9314debd6eb AS build

# Nothing in this stage needs root, so the first instruction makes it non-root. Corepack puts
# pnpm (the version in the root package.json, "packageManager") into the node user's own folder.
USER node
ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
    ASTRO_TELEMETRY_DISABLED=1 \
    PATH="/home/node/bin:${PATH}"
RUN mkdir /home/node/bin /home/node/build \
    && corepack enable --install-directory /home/node/bin
WORKDIR /home/node/build

# Dependencies first, from the manifests and the lockfile only, so this layer is reused until
# one of them changes. --frozen-lockfile fails the build if the lockfile is out of date.
# Only the website, the shared package and what they need are installed, not the whole workspace.
# apps/cms/package.json is here only because the workspace lists that project.
COPY --chown=node:node package.json pnpm-lock.yaml pnpm-workspace.yaml tsconfig.base.json ./
COPY --chown=node:node apps/web/package.json apps/web/
COPY --chown=node:node apps/cms/package.json apps/cms/
COPY --chown=node:node packages/shared/package.json packages/shared/
RUN pnpm install --frozen-lockfile --filter @oc/web... --filter @oc/shared

# The sources, then @oc/shared first (the apps resolve it from its dist folder), then the app.
COPY --chown=node:node packages/shared packages/shared
COPY --chown=node:node apps/web apps/web
RUN pnpm --filter @oc/shared build \
    && pnpm --filter @oc/web build

# The production dependencies as a self-contained folder. `pnpm deploy` (pnpm 12) builds it from
# the workspace lockfile, so the versions are exactly the locked ones, and it copies workspace
# packages such as @oc/shared into node_modules instead of linking to the workspace. It needs no
# --legacy and no injected-packages setting. Only node_modules is taken from the result.
#
# Then what the image must not contain is removed (spec 10.9):
#  - the files a dependency ships that are tests (zod and others ship theirs), and any .git,
#    .cache or .env* entry;
#  - esbuild's native binary. esbuild is a build tool that Vite pulls in; the server never
#    starts it at run time, and a Go program in the image would be scanned and updated with
#    the Go standard library it was built with (the CMS image's older esbuild carries 26 HIGH
#    and CRITICAL advisories that way).
# infra/images/verify-image.sh and the Trivy scan check the result.
RUN pnpm --filter @oc/web deploy --prod /home/node/app \
    && find /home/node/app/node_modules \
        \( -name .git -o -name .cache -o -name '.env*' -o -name '*.test.*' -o -name '*.spec.*' \) \
        -prune -exec rm -rf '{}' + \
    && find /home/node/app/node_modules -path '*/node_modules/@esbuild/*/bin/esbuild' -type f -delete

# ---- final stage -----------------------------------------------------------------------
FROM gcr.io/distroless/nodejs22-debian13:nonroot@sha256:f991e86a080567b6ab7c3392e36f7a0a4f9300639e526b48ee81b92d523af62e AS final

USER 65532
ENV NODE_ENV=production
WORKDIR /app

# Only the built app (not the sources), the production dependencies and the health check.
# Owned by root and not writable: the process cannot change its own code, whatever user the
# container runs as (the server runs it as the environment's own user, --userns=keep-id).
COPY --from=build --chown=0:0 /home/node/app/package.json ./package.json
COPY --from=build --chown=0:0 /home/node/app/node_modules ./node_modules
COPY --from=build --chown=0:0 /home/node/build/apps/web/dist ./dist
COPY --chown=0:0 apps/web/healthcheck.mjs ./healthcheck.mjs

# Docker's own health status. The Quadlet file runs the same script with HealthCmd.
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD ["/nodejs/bin/node", "/app/healthcheck.mjs"]

# The base image's entrypoint is /nodejs/bin/node, so this runs: node /app/dist/server/entry.mjs
CMD ["/app/dist/server/entry.mjs"]
