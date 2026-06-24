#!/usr/bin/env bash
set -euo pipefail

arch="${1:-amd64}"
accelerator="$(scripts/select-qemu-accelerator.sh)"
efi_firmware_code="${PACKER_EFI_FIRMWARE_CODE:-}"
efi_firmware_vars="${PACKER_EFI_FIRMWARE_VARS:-}"

case "${arch}" in
amd64 | arm64) ;;
*)
	echo "usage: $0 [amd64|arm64]" >&2
	exit 64
	;;
esac

find_qemu_share_dir() {
	qemu_binary="${1}"
	qemu_prefix="$(dirname "$(dirname "${qemu_binary}")")"
	searched_dirs=""

	for share_dir in \
		"${qemu_prefix}/share/qemu" \
		"/opt/homebrew/share/qemu" \
		"/usr/local/share/qemu" \
		"/usr/share/qemu"; do
		if [ -d "${share_dir}" ]; then
			printf '%s\n' "${share_dir}"
			return 0
		fi

		searched_dirs="${searched_dirs} ${share_dir}"
	done

	echo "could not find QEMU firmware directory for ${qemu_binary}" >&2
	echo "searched:${searched_dirs}" >&2
	return 1
}

resolve_arm64_efi_firmware() {
	if [ -n "${efi_firmware_code}" ] || [ -n "${efi_firmware_vars}" ]; then
		if [ -z "${efi_firmware_code}" ] || [ -z "${efi_firmware_vars}" ]; then
			echo "set both PACKER_EFI_FIRMWARE_CODE and PACKER_EFI_FIRMWARE_VARS, or neither" >&2
			exit 64
		fi

		return 0
	fi

	qemu_binary="$(command -v qemu-system-aarch64 || true)"
	if [ -z "${qemu_binary}" ]; then
		echo "missing qemu-system-aarch64; install QEMU before building arm64 images" >&2
		exit 69
	fi

	share_dir="$(find_qemu_share_dir "${qemu_binary}" || true)"
	if [ -z "${share_dir}" ]; then
		echo "set PACKER_EFI_FIRMWARE_CODE and PACKER_EFI_FIRMWARE_VARS explicitly" >&2
		exit 69
	fi

	for firmware_code in \
		"${share_dir}/edk2-aarch64-code.fd" \
		"${share_dir}/QEMU_EFI.fd" \
		"${share_dir}/AAVMF_CODE.fd" \
		"${share_dir}/edk2-arm-code.fd"; do
		if [ -r "${firmware_code}" ]; then
			efi_firmware_code="${firmware_code}"
			break
		fi
	done

	for firmware_vars in \
		"${share_dir}/edk2-arm-vars.fd" \
		"${share_dir}/AAVMF_VARS.fd" \
		"${share_dir}/edk2-aarch64-vars.fd"; do
		if [ -r "${firmware_vars}" ]; then
			efi_firmware_vars="${firmware_vars}"
			break
		fi
	done

	if [ -z "${efi_firmware_code}" ] || [ -z "${efi_firmware_vars}" ]; then
		echo "missing ARM64 UEFI firmware in ${share_dir}" >&2
		echo "install a QEMU build that includes edk2-aarch64-code.fd and edk2-arm-vars.fd" >&2
		echo "or set PACKER_EFI_FIRMWARE_CODE and PACKER_EFI_FIRMWARE_VARS explicitly" >&2
		exit 69
	fi
}

validate_file_readable() {
	file_path="${1}"
	description="${2}"

	if [ ! -r "${file_path}" ]; then
		echo "${description} is not readable: ${file_path}" >&2
		exit 66
	fi
}

validate_accelerator_available() {
	case "${accelerator}" in
	hvf)
		qemu-system-aarch64 -accel help | grep -Fxq hvf || {
			echo "qemu-system-aarch64 does not support HVF; install QEMU with HVF support" >&2
			exit 69
		}
		;;
	kvm)
		qemu-system-aarch64 -accel help | grep -Fxq kvm || {
			echo "qemu-system-aarch64 does not support KVM; install QEMU with KVM support" >&2
			exit 69
		}
		;;
	esac
}

validate_qemu_boot_path() {
	case "${arch}:${accelerator}" in
	arm64:hvf)
		case "$(uname -s):$(uname -m)" in
		Darwin:arm64) ;;
		*)
			echo "QEMU_ACCELERATOR=hvf for arm64 requires Apple Silicon macOS; got $(uname -s) $(uname -m)" >&2
			exit 69
			;;
		esac
		;;
	arm64:kvm)
		if [ "$(uname -s)" != "Linux" ]; then
			echo "QEMU_ACCELERATOR=kvm requires Linux" >&2
			exit 69
		fi
		if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
			echo "QEMU_ACCELERATOR=kvm requires readable and writable /dev/kvm" >&2
			exit 69
		fi
		;;
	esac

	if [ "${arch}" = "arm64" ]; then
		resolve_arm64_efi_firmware
		validate_file_readable "${efi_firmware_code}" "ARM64 UEFI firmware code"
		validate_file_readable "${efi_firmware_vars}" "ARM64 UEFI firmware vars"
		validate_accelerator_available
		case "${efi_firmware_code}" in
		*secure* | *Secure* | *SECURE*)
			echo "ARM64 UEFI firmware must not require Secure Boot: ${efi_firmware_code}" >&2
			exit 69
			;;
		esac
		qemu-system-aarch64 -machine help | grep -Eq '^virt[[:space:]-]' || {
			echo "qemu-system-aarch64 does not support the required virt machine" >&2
			exit 69
		}
		case "${accelerator}" in
		none)
			validation_accelerator="tcg"
			validation_cpu="max"
			;;
		*)
			validation_accelerator="${accelerator}"
			validation_cpu="host"
			;;
		esac
		probe_efi_vars="$(mktemp "${TMPDIR:-/tmp}/bundle-vm-base-efivars.XXXXXX")"
		cp "${efi_firmware_vars}" "${probe_efi_vars}"
		set +e
		qemu_boot_probe_output="$(timeout 10 qemu-system-aarch64 -machine "virt,accel=${validation_accelerator}" -cpu "${validation_cpu}" \
			-display none -nodefaults -S -serial none -monitor none -parallel none -no-reboot \
			-drive "if=pflash,format=raw,readonly=on,file=${efi_firmware_code}" \
			-drive "if=pflash,format=raw,file=${probe_efi_vars}" 2>&1)"
		validation_status="${?}"
		set -e
		rm -f "${probe_efi_vars}"
		if [ "${validation_status}" -ne 0 ] && [ "${validation_status}" -ne 124 ]; then
			echo "QEMU cannot start the arm64 UEFI ${accelerator} boot path" >&2
			echo "firmware code: ${efi_firmware_code}" >&2
			echo "firmware vars: ${efi_firmware_vars}" >&2
			echo "${qemu_boot_probe_output}" >&2
			exit 69
		fi
	fi
}

set -a
# shellcheck source=versions.env
source versions.env
set +a

validate_qemu_boot_path

echo "Using QEMU accelerator: ${accelerator}"
if [ "${arch}" = "arm64" ]; then
	echo "Using ARM64 UEFI firmware code: ${efi_firmware_code}"
	echo "Using ARM64 UEFI firmware vars: ${efi_firmware_vars}"
fi

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
		-var "efi_firmware_code=${efi_firmware_code}" \
		-var "efi_firmware_vars=${efi_firmware_vars}" \
		.
)
