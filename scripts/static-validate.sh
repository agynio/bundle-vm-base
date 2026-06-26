#!/usr/bin/env bash
set -euo pipefail

arm64_qemuargs_has_device() {
	awk '
		/^[[:space:]]*arm64_qemuargs[[:space:]]*=/ {
			found_arm64_qemuargs = 1
			in_arm64_qemuargs = 1
		}
		in_arm64_qemuargs && /"-device"/ { found_device = 1 }
		in_arm64_qemuargs && /^[[:space:]]*[[:alnum:]_]+[[:space:]]*=/ && ! /^[[:space:]]*arm64_qemuargs[[:space:]]*=/ { in_arm64_qemuargs = 0 }
		END {
			if (!found_arm64_qemuargs) { exit 2 }
			exit found_device ? 0 : 1
		}
	' "${1}"
}

validate_arm64_scsi_qemuargs() {
	set +e
	arm64_qemuargs_has_device packer/bundle-vm-base.pkr.hcl
	guard_status="${?}"
	set -e

	if [ "${guard_status}" -eq 0 ]; then
		echo "ARM64 qemuargs must not include -device while cdrom_interface is virtio-scsi." >&2
		echo "Packer suppresses generated scsi devices when custom -device arguments are present." >&2
		exit 1
	fi

	if [ "${guard_status}" -eq 2 ]; then
		echo "could not find arm64_qemuargs in packer/bundle-vm-base.pkr.hcl" >&2
		exit 1
	fi
}

validate_arm64_scsi_qemuargs_negative_fixture() {
	fixture_path="$(mktemp "${TMPDIR:-/tmp}/bundle-vm-base-arm64-qemuargs.XXXXXX.pkr.hcl")"
	cp packer/bundle-vm-base.pkr.hcl "${fixture_path}"
	trap 'rm -f "${fixture_path}"' RETURN
	awk '
		inserted == 0 && /^[[:space:]]*arm64_qemuargs[[:space:]]*=/ {
			print
			print "    [\"-device\", \"virtio-rng-pci\"],"
			inserted = 1
			next
		}
		{ print }
	' "${fixture_path}" >"${fixture_path}.tmp"
	mv "${fixture_path}.tmp" "${fixture_path}"

	if ! arm64_qemuargs_has_device "${fixture_path}"; then
		echo "negative fixture did not detect ARM64 -device qemuarg" >&2
		exit 1
	fi

	rm -f "${fixture_path}"
	trap - RETURN
}

validate_arm64_scsi_qemuargs
validate_arm64_scsi_qemuargs_negative_fixture

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
