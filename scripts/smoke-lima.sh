#!/usr/bin/env bash
set -euo pipefail

name="${1:-agyn-base-smoke}"
config="${2:-artifacts/amd64/lima.yaml}"

limactl start --name "${name}" "${config}"
limactl shell "${name}" -- sudo kubectl wait --for=condition=Ready nodes --all --timeout=180s
limactl shell "${name}" -- sudo kubectl -n cert-manager wait --for=condition=Available deploy --all --timeout=180s
limactl shell "${name}" -- sudo kubectl -n argocd wait --for=condition=Available deploy --all --timeout=180s
