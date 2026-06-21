#!/usr/bin/env bash
set -euo pipefail

arch="${1:-amd64}"
version="${2:-dev}"

case "${arch}" in
amd64 | arm64) ;;
*)
	echo "usage: $0 [amd64|arm64] [version]" >&2
	exit 64
	;;
esac

set -a
# shellcheck source=versions.env
source versions.env
set +a

disk="packer/output/${arch}/bundle-vm-base-${arch}.qcow2"
artifact_dir="artifacts/${arch}"

if [ ! -f "${disk}" ]; then
	echo "missing disk: ${disk}" >&2
	exit 66
fi

rm -rf "${artifact_dir}"
install -d -m 0755 "${artifact_dir}"

cp "${disk}" "${artifact_dir}/bundle-vm-base-${arch}.qcow2"
xz -T0 -9 --keep --force "${artifact_dir}/bundle-vm-base-${arch}.qcow2"

cat >"${artifact_dir}/metadata.json" <<EOF
{
  "name": "bundle-vm-base",
  "version": "${version}",
  "architecture": "${arch}",
  "os": {
    "name": "ubuntu",
    "series": "${UBUNTU_SERIES}",
    "version": "${UBUNTU_VERSION}"
  },
  "disk": {
    "format": "qcow2",
    "compression": "xz",
    "size": "${DISK_SIZE}",
    "file": "bundle-vm-base-${arch}.qcow2.xz"
  },
  "components": {
    "k3s": "${K3S_VERSION}",
    "certManager": "${CERT_MANAGER_VERSION}",
    "argoCd": "${ARGOCD_VERSION}",
    "helm": "${HELM_VERSION}",
    "kubectl": "${KUBECTL_VERSION}"
  }
}
EOF

sed \
	-e "s/{{ARCH}}/${arch}/g" \
	-e "s/{{VERSION}}/${version}/g" \
	examples/lima.yaml.tpl >"${artifact_dir}/lima.yaml"

(
	cd "${artifact_dir}"
	sha256sum "bundle-vm-base-${arch}.qcow2.xz" metadata.json lima.yaml >checksums.sha256
)
