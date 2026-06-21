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

version="$(scripts/validate-version.sh "${version}")"

case "${arch}" in
amd64) lima_arch="x86_64" ;;
arm64) lima_arch="aarch64" ;;
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

jq -n \
	--arg version "${version}" \
	--arg architecture "${arch}" \
	--arg lima_arch "${lima_arch}" \
	--arg ubuntu_series "${UBUNTU_SERIES}" \
	--arg ubuntu_version "${UBUNTU_VERSION}" \
	--arg disk_size "${DISK_SIZE}" \
	--arg disk_file "bundle-vm-base-${arch}.qcow2.xz" \
	--arg k3s_version "${K3S_VERSION}" \
	--arg cert_manager_version "${CERT_MANAGER_VERSION}" \
	--arg argocd_version "${ARGOCD_VERSION}" \
	--arg helm_version "${HELM_VERSION}" \
	--arg kubectl_version "${KUBECTL_VERSION}" \
	'{
    name: "bundle-vm-base",
    version: $version,
    architecture: $architecture,
    limaArchitecture: $lima_arch,
    os: {
      name: "ubuntu",
      series: $ubuntu_series,
      version: $ubuntu_version
    },
    disk: {
      format: "qcow2",
      compression: "xz",
      size: $disk_size,
      file: $disk_file
    },
    components: {
      k3s: $k3s_version,
      certManager: $cert_manager_version,
      argoCd: $argocd_version,
      helm: $helm_version,
      kubectl: $kubectl_version
    }
  }' >"${artifact_dir}/metadata.json"

sed \
	-e "s/{{ARCH}}/${arch}/g" \
	-e "s/{{LIMA_ARCH}}/${lima_arch}/g" \
	-e "s/{{VERSION}}/${version}/g" \
	examples/lima.yaml.tpl >"${artifact_dir}/lima.yaml"

(
	cd "${artifact_dir}"
	sha256sum "bundle-vm-base-${arch}.qcow2.xz" metadata.json lima.yaml >checksums.sha256
)
