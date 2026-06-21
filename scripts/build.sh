#!/usr/bin/env bash
set -euo pipefail

arch="${1:-amd64}"
accelerator="${QEMU_ACCELERATOR:-kvm}"

case "${arch}" in
amd64 | arm64) ;;
*)
	echo "usage: $0 [amd64|arm64]" >&2
	exit 64
	;;
esac

set -a
# shellcheck source=versions.env
source versions.env
set +a

packer init packer
(
	cd packer
	packer build \
		-var "arch=${arch}" \
		-var "ubuntu_series=${UBUNTU_SERIES}" \
		-var "ubuntu_version=${UBUNTU_VERSION}" \
		-var "disk_size=${DISK_SIZE}" \
		-var "k3s_version=${K3S_VERSION}" \
		-var "cert_manager_version=${CERT_MANAGER_VERSION}" \
		-var "argocd_version=${ARGOCD_VERSION}" \
		-var "helm_version=${HELM_VERSION}" \
		-var "kubectl_version=${KUBECTL_VERSION}" \
		-var "qemu_accelerator=${accelerator}" \
		.
)
