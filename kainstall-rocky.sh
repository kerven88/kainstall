#!/usr/bin/env bash
# Compatibility entry point; all distributions use the same checked OS routing.
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec bash "$SCRIPT_DIR/kainstall.sh" "$@"
