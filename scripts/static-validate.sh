#!/usr/bin/env bash
set -euo pipefail

validate_arm64_scsi_qemuargs() {
	if awk '
		/^[[:space:]]*qemuargs[[:space:]]*=/ { in_qemuargs = 1 }
		in_qemuargs && /"-device"/ { found_device = 1 }
		in_qemuargs && index($0, "] : [") { in_qemuargs = 0 }
		END { exit found_device ? 0 : 1 }
	' packer/bundle-vm-base.pkr.hcl; then
		echo "ARM64 qemuargs must not include -device while cdrom_interface is virtio-scsi." >&2
		echo "Packer suppresses generated scsi devices when custom -device arguments are present." >&2
		exit 1
	fi
}

validate_arm64_scsi_qemuargs

if command -v packer >/dev/null 2>&1; then
	ssh_key_dir="$(mktemp -d "${TMPDIR:-/tmp}/bundle-vm-base-static-ssh.XXXXXX")"
	ssh_private_key_file="${ssh_key_dir}/packer_ed25519"
	ssh-keygen -q -t ed25519 -N '' -C bundle-vm-base-packer -f "${ssh_private_key_file}"
	ssh_public_key="$(cat "${ssh_private_key_file}.pub")"
	trap 'rm -rf "${ssh_key_dir}"' EXIT

	packer init packer
	packer fmt -check packer
	(
		cd packer
		packer validate \
			-var arch=amd64 \
			-var ssh_private_key_file="${ssh_private_key_file}" \
			-var ssh_public_key="${ssh_public_key}" \
			-var k3s_version=v0.0.0 \
			-var cert_manager_version=v0.0.0 \
			-var argocd_version=v0.0.0 \
			-var helm_version=v0.0.0 \
			-var kubectl_version=v0.0.0 \
			.
		packer validate \
			-var arch=arm64 \
			-var ssh_private_key_file="${ssh_private_key_file}" \
			-var ssh_public_key="${ssh_public_key}" \
			-var k3s_version=v0.0.0 \
			-var cert_manager_version=v0.0.0 \
			-var argocd_version=v0.0.0 \
			-var helm_version=v0.0.0 \
			-var kubectl_version=v0.0.0 \
			.
		packer validate \
			-var arch=arm64 \
			-var qemu_accelerator=hvf \
			-var efi_firmware_code=/tmp/edk2-aarch64-code.fd \
			-var efi_firmware_vars=/tmp/edk2-arm-vars.fd \
			-var ssh_private_key_file="${ssh_private_key_file}" \
			-var ssh_public_key="${ssh_public_key}" \
			-var k3s_version=v0.0.0 \
			-var cert_manager_version=v0.0.0 \
			-var argocd_version=v0.0.0 \
			-var helm_version=v0.0.0 \
			-var kubectl_version=v0.0.0 \
			.
	)
fi

if command -v shellcheck >/dev/null 2>&1; then
	shellcheck -x scripts/*.sh
fi

if command -v yamllint >/dev/null 2>&1; then
	yamllint .github/workflows examples docs
fi

if command -v jq >/dev/null 2>&1 && [ -d artifacts ]; then
	find artifacts -name metadata.json -print0 | xargs -0 -r -n1 jq empty
fi
