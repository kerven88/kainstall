#!/usr/bin/env bash
set -Eeuo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/kainstall.sh
source "$SCRIPT_DIR/lib/kainstall.sh"
# shellcheck source=lib/cli.sh
source "$SCRIPT_DIR/lib/cli.sh"
main "$@"
