#!/usr/bin/env bash
# Builds the "artifact" stage from the Dockerfile and exports the packed
# cloudcli .tgz into ./dist on the host.
#
# Usage:
#   ./export-tgz.sh [CLAUDECODEUI_VERSION] [OUTPUT_DIR]
#
# Examples:
#   ./export-tgz.sh                  # build v1.37.6 (Dockerfile default) into ./dist
#   ./export-tgz.sh 1.38.0            # build a different release
#   ./export-tgz.sh 1.38.0 ./out      # ...into a different output dir

set -euo pipefail

VERSION="${1:-}"
OUTPUT_DIR="${2:-./dist}"

BUILD_ARGS=()
if [[ -n "$VERSION" ]]; then
  BUILD_ARGS+=(--build-arg "CLAUDECODEUI_VERSION=$VERSION")
fi

# Start from an empty output dir so stale .tgz files from earlier builds don't
# get picked up by `npm install -g <dir>/*.tgz`. Refuse anything that is (or
# contains) the current dir, the home dir or /, since OUTPUT_DIR is user input.
OUTPUT_ABS="$(realpath -m "$OUTPUT_DIR")"
for protected in / "$HOME" "$PWD"; do
  case "$(realpath -m "$protected")/" in
    "${OUTPUT_ABS%/}/"*)
      echo "Refusing to remove output dir $OUTPUT_DIR ($OUTPUT_ABS): it contains $protected" >&2
      exit 1
      ;;
  esac
done
rm -rf "$OUTPUT_ABS"

docker build --target artifact "${BUILD_ARGS[@]}" --output "type=local,dest=${OUTPUT_DIR}" .

echo "Exported:"
ls -la "$OUTPUT_DIR"

echo "Install the exported .tgz with:"
echo "  npm install -g ${OUTPUT_DIR}/*.tgz"
echo "  cloudcli --version"
