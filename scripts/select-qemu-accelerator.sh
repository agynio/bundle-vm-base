#!/usr/bin/env bash
set -euo pipefail

case "${QEMU_ACCELERATOR:-auto}" in
auto | "") ;;
kvm | none)
	printf '%s\n' "${QEMU_ACCELERATOR}"
	exit 0
	;;
*)
	echo "QEMU_ACCELERATOR must be auto, kvm, or none" >&2
	exit 64
	;;
esac

if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
	printf '%s\n' kvm
else
	printf '%s\n' none
fi
