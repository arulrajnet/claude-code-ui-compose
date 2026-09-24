#!/usr/bin/env bash
# Builds the "artifact" stage from the Dockerfile and exports the packed
# cloudcli .tgz into ./dist on the host.
#
# Usage:
#   ./export-tgz.sh [CLAUDECODEUI_VERSION] [OUTPUT_DIR]
#
# Examples:
#   ./export-tgz.sh                  # build v1.37.3 (Dockerfile default) into ./dist
#   ./export-tgz.sh 1.38.0            # build a different release
#   ./export-tgz.sh 1.38.0 ./out      # ...into a different output dir

set -euo pipefail

VERSION="${1:-}"
OUTPUT_DIR="${2:-./dist}"

BUILD_ARGS=()
if [[ -n "$VERSION" ]]; then
  BUILD_ARGS+=(--build-arg "CLAUDECODEUI_VERSION=$VERSION")
fi

docker build --target artifact "${BUILD_ARGS[@]}" --output "type=local,dest=${OUTPUT_DIR}" .

echo "Exported:"
ls -la "$OUTPUT_DIR"

echo "Install the exported .tgz with:"
echo "  npm install -g ${OUTPUT_DIR}/*.tgz"
echo "  cloudcli --version"
