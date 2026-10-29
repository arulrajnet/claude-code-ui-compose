# claudecodeui Docker Build

Automated Docker build pipeline for [siteboon/claudecodeui](https://github.com/siteboon/claudecodeui) with platform mode enabled.

## Problem

When running claudecodeui behind an OAuth2 proxy, the application requests authentication even though the proxy has already verified the user. This creates an extra authentication layer that complicates deployment behind enterprise auth systems.

## Solution

Compile claudecodeui with the `VITE_IS_PLATFORM=true` environment variable set at build time. This inlines platform-mode configuration into the frontend bundle, which:

- Skips token-based authentication checks
- Assumes a platform-managed user context (bypassing the app's own auth flow)
- Disables redundant login prompts when behind an OAuth2 proxy

The Dockerfile automates this build process:
1. Downloads the tagged GitHub release
2. Builds with `VITE_IS_PLATFORM=true` inlined into the client bundle
3. Globally installs the built `cloudcli` package
4. Provides docker-compose for easy self-hosted deployment

## Description

- **Dockerfile** — multi-stage build (downloads source tarball, compiles with platform mode, creates portable npm package)
- **docker-compose.yml** — ready-to-deploy production configuration with persistent data volume
- **export-tgz.sh** — extracts the built `.tgz` for installation on your host machine

## Dependency pinning

The upstream `package-lock.json` is deleted before `npm install` (it can be
resolved on a different CPU arch, which drops rollup's native binary - see
npm/cli#4828). To keep the build reproducible anyway, the Dockerfile first
pins every direct dependency in `package.json` to its exact lockfile version.
Without that, `^` ranges float to the newest releases - e.g. a newer
`@anthropic-ai/claude-agent-sdk` broke `tsc` for v1.37.6. The build log lists
the installed `@anthropic-ai/claude-agent-sdk` and `typescript` versions.
