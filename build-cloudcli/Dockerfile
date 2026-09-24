# syntax=docker/dockerfile:1
#
# Builds siteboon/claudecodeui from a tagged GitHub source release.
#
# Stages:
#   build    - downloads the source tarball, builds with VITE_IS_PLATFORM=true,
#              and `npm pack`s the result into /out/*.tgz
#   artifact - scratch stage holding only that .tgz, for extracting to the host
#   runtime  - default final image: installs the .tgz globally (`cloudcli` on PATH)
#
# To pick up a new release, bump CLAUDECODEUI_VERSION (build arg) - no other
# changes needed as long as the upstream build process stays the same:
#   docker compose build --build-arg CLAUDECODEUI_VERSION=<new-version>

FROM node:22-bookworm-slim AS build

ARG CLAUDECODEUI_VERSION=1.37.3

# VITE_IS_PLATFORM is read by Vite at build time and inlined into the
# client bundle - it MUST be set before `npm run build`, not at container
# runtime (a runtime env var would have no effect on the already-built assets).
#
# NOTE: do NOT set NODE_ENV=production here - it changes npm's optional-
# dependency resolution and drops the platform's native rollup binary
# (@rollup/rollup-linux-*), breaking `vite build`.
ENV VITE_IS_PLATFORM=true

# build-essential/python3 are required to compile native addons
# (node-pty, better-sqlite3, bcrypt) used by the server.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
        git \
        build-essential \
        python3 \
        python3-setuptools \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/claudecodeui

# Download and extract the tagged source release from GitHub.
RUN curl -fsSL \
        "https://github.com/siteboon/claudecodeui/archive/refs/tags/v${CLAUDECODEUI_VERSION}.tar.gz" \
        -o /tmp/claudecodeui.tar.gz \
    && tar -xzf /tmp/claudecodeui.tar.gz --strip-components=1 -C /usr/src/claudecodeui \
    && rm /tmp/claudecodeui.tar.gz

# Drop the "prepare" hook (runs husky git-hook setup) - irrelevant here
# since this is a source tarball, not a git checkout.
RUN npm pkg delete scripts.prepare

# Drop the committed lockfile: it may have been resolved on a different
# CPU arch, which trips npm's optional-dependency bug (npm/cli#4828) and
# leaves platform-specific packages (e.g. @rollup/rollup-linux-*) missing.
RUN rm -f package-lock.json

# Install full dependencies (incl. devDependencies) - needed for the
# vite/tsc build step below.
RUN npm install

# Builds the client (vite, picks up VITE_IS_PLATFORM=true above) and the
# server (tsc + tsc-alias).
RUN npm run build

# Pack the built package into a tarball. Packing (rather than
# `npm install -g .`) avoids npm's local-path install symlinking back to
# this source checkout, and gives us a single portable artifact.
RUN mkdir -p /out && npm pack --pack-destination /out


# Minimal stage holding only the packed tarball - lets you extract it to
# the host without pulling in the rest of the build stage's filesystem.
# See the docker commands below (or in the README) to grab it.
FROM scratch AS artifact
COPY --from=build /out/*.tgz /


FROM node:22-bookworm-slim AS runtime

# build-essential/python3 are required again here: `npm install -g` still
# needs to compile the same native addons for the runtime image.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        python3 \
        python3-setuptools \
        sqlite3 \
        jq \
        ripgrep \
        unzip \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /out/*.tgz /tmp/
RUN npm install -g /tmp/*.tgz \
    && cloudcli --version \
    && rm -rf /tmp/*.tgz /root/.npm

ENV NODE_ENV=production \
    SERVER_PORT=3001 \
    HOST=0.0.0.0

EXPOSE 3001

# Persistent app data (auth.db, app config) lives under ~/.cloudcli by
# default - see docker-compose.yml for the matching volume mount.
VOLUME ["/root/.cloudcli"]

ENTRYPOINT ["cloudcli"]
CMD ["start"]
