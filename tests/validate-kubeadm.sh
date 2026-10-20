#!/usr/bin/env bash
# Run on Linux with an actual kubeadm binary, without a cluster or host changes.
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/kainstall.sh
source "$SCRIPT_DIR/../lib/kainstall.sh"
defaults
KUBE_VERSION=$(version_validate "${1:-1.35.1}")
KUBE_APISERVER=api.example.com:6443
KUBEADM_BIN=${KUBEADM_BIN:-kubeadm}
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT
render_init cp1 10.0.0.11 > "$TEST_TMP/init.yaml"
render_join worker worker1 10.0.0.21 abcdef.0123456789abcdef \
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa > "$TEST_TMP/worker.yaml"
render_join master cp2 10.0.0.12 abcdef.0123456789abcdef \
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb > "$TEST_TMP/master.yaml"
for config in "$TEST_TMP"/*.yaml; do
  "$KUBEADM_BIN" config validate --config "$config"
done
printf 'kubeadm v%s validated init, worker join and control-plane join\n' "$KUBE_VERSION"
