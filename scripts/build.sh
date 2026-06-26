#!/usr/bin/env bash
set -euo pipefail

arch="${1:-amd64}"
accelerator="$(scripts/select-qemu-accelerator.sh)"
efi_firmware_code="${PACKER_EFI_FIRMWARE_CODE:-}"
efi_firmware_vars="${PACKER_EFI_FIRMWARE_VARS:-}"
ssh_key_dir=""
packer_log_path=""
serial_log_path=""
debug_dir="/tmp/bundle-vm-base-debug"
tcp_probe_result="unavailable"

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

cleanup_build_ssh_key() {
	if [ -n "${ssh_key_dir}" ]; then
		rm -rf "${ssh_key_dir}"
	fi
}

create_build_ssh_key() {
	ssh_key_dir="$(mktemp -d "${TMPDIR:-/tmp}/bundle-vm-base-ssh.XXXXXX")"
	trap cleanup_build_ssh_key EXIT
	ssh_private_key_file="${ssh_key_dir}/packer_ed25519"
	ssh_public_key_file="${ssh_private_key_file}.pub"

	ssh-keygen -q -t ed25519 -N '' -C bundle-vm-base-packer -f "${ssh_private_key_file}"
	ssh_public_key="$(cat "${ssh_public_key_file}")"
}

ensure_parent_dir() {
	file_path="${1}"
	parent_dir="$(dirname "${file_path}")"

	mkdir -p "${parent_dir}"
}

create_packer_log_path() {
	if [ -n "${PACKER_LOG_PATH:-}" ]; then
		packer_log_path="${PACKER_LOG_PATH}"
		ensure_parent_dir "${packer_log_path}"
		export PACKER_LOG=1
		return 0
	fi

	if [ "${arch}:${accelerator}" = "arm64:hvf" ]; then
		mkdir -p "${debug_dir}"
		packer_log_path="${debug_dir}/packer-arm64-hvf.log"
	else
		packer_log_path="${TMPDIR:-/tmp}/bundle-vm-base-packer-${arch}-$(date +%Y%m%d%H%M%S).log"
	fi
	export PACKER_LOG=1
	export PACKER_LOG_PATH="${packer_log_path}"
}

create_serial_log_path() {
	if [ "${arch}:${accelerator}" != "arm64:hvf" ]; then
		return 0
	fi

	if [ -n "${PACKER_SERIAL_LOG_PATH:-}" ]; then
		serial_log_path="${PACKER_SERIAL_LOG_PATH}"
		ensure_parent_dir "${serial_log_path}"
		: >"${serial_log_path}"
		return 0
	fi

	mkdir -p "${debug_dir}"
	serial_log_path="${debug_dir}/serial-arm64-hvf.log"
	: >"${serial_log_path}"
}

print_arm64_hvf_banner() {
	if [ "${arch}:${accelerator}" != "arm64:hvf" ]; then
		return 0
	fi

	{
		echo "ARM64 HVF diagnostics:"
		echo "  Packer log: ${packer_log_path}"
		echo "  Serial console log: ${serial_log_path}"
		echo "If SSH times out, collect diagnostics with:"
		echo "  grep -n 'AGYN-DIAG' '${serial_log_path}'"
		echo "  tail -n 240 '${serial_log_path}'"
		echo "  grep -nE 'hostfwd|127\\.0\\.0\\.1|handshake|connection reset|Timeout waiting for SSH|Connected to SSH' '${packer_log_path}' | tail -n 160"
		echo "  tail -n 160 '${packer_log_path}'"
	} >&2
}

print_log_tail() {
	log_label="${1}"
	log_path="${2}"
	line_count="${3}"

	if [ -z "${log_path}" ]; then
		echo "${log_label}: unavailable" >&2
		return 0
	fi

	if [ ! -f "${log_path}" ]; then
		echo "${log_label}: missing at ${log_path}" >&2
		return 0
	fi

	{
		echo "${log_label}: ${log_path}"
		tail -n "${line_count}" "${log_path}"
	} >&2
}

extract_packer_log_value() {
	pattern="${1}"

	if [ -z "${packer_log_path}" ] || [ ! -f "${packer_log_path}" ]; then
		return 1
	fi

	sed -nE "s/.*${pattern}.*/\\1/p" "${packer_log_path}" | tail -n 1
}

extract_communicator_port() {
	if [ -z "${packer_log_path}" ] || [ ! -f "${packer_log_path}" ]; then
		return 0
	fi

	{
		sed -nE 's/.*127\.0\.0\.1:([0-9]+).*/\1/p' "${packer_log_path}"
		sed -nE 's/.*host:[[:space:]]*127\.0\.0\.1,[[:space:]]*port:[[:space:]]*([0-9]+).*/\1/p' "${packer_log_path}"
	} | tail -n 1
}

extract_hostfwd() {
	extract_packer_log_value '(hostfwd=[^[:space:],]+)' || true
}

packer_log_has() {
	pattern="${1}"

	[ -n "${packer_log_path}" ] && [ -f "${packer_log_path}" ] && grep -Eqi "${pattern}" "${packer_log_path}"
}

serial_log_has() {
	pattern="${1}"

	[ -n "${serial_log_path}" ] && [ -f "${serial_log_path}" ] && grep -Fq "${pattern}" "${serial_log_path}"
}

probe_communicator_port() {
	communicator_port="${1}"

	if [ -z "${communicator_port}" ]; then
		echo "  TCP probe: skipped; communicator host port unavailable" >&2
		tcp_probe_result="unavailable"
		return 0
	fi

	set +e
	( exec 3<>"/dev/tcp/127.0.0.1/${communicator_port}" ) >/dev/null 2>&1
	probe_status="${?}"
	set -e

	case "${probe_status}" in
	0)
		echo "  TCP probe: 127.0.0.1:${communicator_port} accepted a connection" >&2
		tcp_probe_result="accepted"
		;;
	*)
		echo "  TCP probe: 127.0.0.1:${communicator_port} did not accept a connection" >&2
		tcp_probe_result="rejected"
		;;
	esac
}

print_ssh_timeout_diagnostics() {
	communicator_port="$(extract_communicator_port)"
	hostfwd="$(extract_hostfwd)"

	{
		echo "SSH-timeout diagnostics:"
		if [ -n "${hostfwd}" ]; then
			echo "  QEMU hostfwd: ${hostfwd}"
		else
			echo "  QEMU hostfwd: unavailable in Packer log"
		fi
		if [ -n "${communicator_port}" ]; then
			echo "  communicator host port: 127.0.0.1:${communicator_port}"
		else
			echo "  communicator host port: unavailable in Packer log"
		fi
	} >&2

	probe_communicator_port "${communicator_port}"
}

print_recent_packer_ssh_errors() {
	if [ -z "${packer_log_path}" ] || [ ! -f "${packer_log_path}" ]; then
		echo "Recent Packer SSH communicator errors: unavailable; Packer log missing" >&2
		return 0
	fi

	{
		echo "Recent Packer SSH communicator errors:"
		grep -Ei 'ssh|handshake|connection reset|connection refused|timeout waiting for ssh|unable to authenticate|permission denied|hostfwd|127\.0\.0\.1' "${packer_log_path}" | tail -n 80 || true
	} >&2
}

print_failure_classification() {
	communicator_port="$(extract_communicator_port)"
	hostfwd="$(extract_hostfwd)"

	{
		echo "Failure classification:"
		if [ "${arch}:${accelerator}" != "arm64:hvf" ]; then
			echo "  ARM64 HVF serial classification: not applicable for ${arch}:${accelerator}."
			return 0
		fi

		if [ -z "${serial_log_path}" ] || [ ! -s "${serial_log_path}" ]; then
			echo "  boot/serial: serial log is missing or empty; QEMU may not have booted far enough or serial capture failed."
		elif ! serial_log_has "AGYN-DIAG bootcmd start"; then
			echo "  boot/cloud-init: serial log exists, but cloud-init bootcmd markers are missing."
		elif ! serial_log_has "AGYN-DIAG bootcmd cidata devices:" && ! serial_log_has "AGYN-DIAG cidata devices:"; then
			echo "  seed/cloud-init: NoCloud cidata visibility markers are missing."
		elif ! serial_log_has "AGYN-DIAG cloud-init runcmd start"; then
			echo "  cloud-init: bootcmd ran, but runcmd did not start."
		elif ! serial_log_has "AGYN-DIAG sshd config valid"; then
			echo "  sshd: sshd configuration validation did not report success."
		elif ! serial_log_has "AGYN-DIAG ssh service active"; then
			echo "  sshd: ssh service did not report active."
		elif ! serial_log_has "AGYN-DIAG port 22 listeners:"; then
			echo "  sshd: port 22 listener marker is missing."
		elif [ -z "${hostfwd}" ] || [ -z "${communicator_port}" ]; then
			echo "  hostfwd: Packer log did not expose QEMU hostfwd or communicator port."
		elif [ "${tcp_probe_result}" = "rejected" ]; then
			echo "  hostfwd/tcp: QEMU hostfwd was logged, but the host TCP probe could not connect to 127.0.0.1:${communicator_port}."
		elif packer_log_has 'connection reset by peer'; then
			echo "  auth/handshake: hostfwd and guest sshd evidence exist, but Packer saw connection reset by peer during SSH handshake."
		elif [ "${tcp_probe_result}" = "accepted" ]; then
			echo "  auth/handshake: host TCP probe reached 127.0.0.1:${communicator_port}; inspect SSH auth, username, key, and sshd journal evidence."
		else
			echo "  unresolved: review Packer SSH errors and serial AGYN-DIAG markers above."
		fi
	} >&2
}

print_diagnostic_collection_commands() {
	{
		echo "Diagnostic collection commands:"
		if [ -n "${serial_log_path}" ]; then
			echo "  grep -n 'AGYN-DIAG' '${serial_log_path}'"
			echo "  tail -n 240 '${serial_log_path}'"
		fi
		if [ -n "${packer_log_path}" ]; then
			echo "  grep -nE 'hostfwd|127\\.0\\.0\\.1|handshake|connection reset|Timeout waiting for SSH|Connected to SSH|permission denied|unable to authenticate' '${packer_log_path}' | tail -n 160"
			echo "  tail -n 160 '${packer_log_path}'"
		fi
	} >&2
}

print_failure_debug() {
	status="${1}"

	if [ "${status}" -eq 0 ]; then
		return 0
	fi

	{
		echo "Packer build failed with exit status ${status}."
		echo "Build debug context:"
		echo "  architecture: ${arch}"
		echo "  accelerator: ${accelerator}"
		echo "  ssh private key: ${ssh_private_key_file}"
		echo "  ssh public key fingerprint: $(ssh-keygen -lf "${ssh_public_key_file}")"
		if [ "${arch}" = "arm64" ]; then
			echo "  ARM64 UEFI firmware code: ${efi_firmware_code}"
			echo "  ARM64 UEFI firmware vars: ${efi_firmware_vars}"
			echo "  ARM64 cidata CD-ROM interface: virtio-scsi"
			echo "  ARM64 qemuargs device policy: Packer-managed devices"
		fi
		if [ -n "${packer_log_path}" ]; then
			echo "  Packer debug log: ${packer_log_path}"
		fi
		if [ -n "${serial_log_path}" ]; then
			echo "  ARM64 HVF serial console log: ${serial_log_path}"
		fi
		echo "Inspect AGYN-DIAG markers below for NoCloud seed visibility, cloud-init completion, packer user setup, sshd startup, listening sockets, and hostfwd reachability."
	} >&2

	print_ssh_timeout_diagnostics
	print_recent_packer_ssh_errors
	print_failure_classification
	print_diagnostic_collection_commands
	print_log_tail "Last Packer log lines" "${packer_log_path}" 120
	print_log_tail "Last ARM64 HVF serial console lines" "${serial_log_path}" 160
}

run_packer_build() {
	set +e
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
		-var "ssh_private_key_file=${ssh_private_key_file}" \
		-var "ssh_public_key=${ssh_public_key}" \
		-var "serial_log_path=${serial_log_path}" \
		.
	build_status="${?}"
	set -e
	print_failure_debug "${build_status}"
	return "${build_status}"
}

set -a
# shellcheck source=versions.env
source versions.env
set +a

validate_qemu_boot_path
create_build_ssh_key
create_packer_log_path
create_serial_log_path

echo "Using QEMU accelerator: ${accelerator}"
if [ "${arch}" = "arm64" ]; then
	echo "Using ARM64 UEFI firmware code: ${efi_firmware_code}"
	echo "Using ARM64 UEFI firmware vars: ${efi_firmware_vars}"
fi
if [ -n "${serial_log_path}" ]; then
	echo "Writing ARM64 HVF serial console log: ${serial_log_path}"
fi
print_arm64_hvf_banner

packer init packer
(
	cd packer
	run_packer_build
)
