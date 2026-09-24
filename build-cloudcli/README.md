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
