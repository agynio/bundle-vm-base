#!/usr/bin/env bash
set -euo pipefail

# Builds, packages and publishes one architecture of the base image.
#
# The base image is a build input, not a consumer download: the platform build
# pulls it from GHCR by version (see bundle-vm's versions.env). So this
# publishes to GHCR only — there is no CDN copy to keep in step.
#
# Same shape as bundle-vm's scripts/release.sh on purpose. amd64 runs in GitHub
# Actions; arm64 runs on a maintainer's machine until an arm64 runner with KVM
# exists, and both run this one command.
#
#   scripts/release.sh arm64 0.1.1
#   scripts/release.sh amd64 0.1.1 --no-publish

usage() {
	cat >&2 <<'EOF'
usage: scripts/release.sh ARCH VERSION [--no-publish] [--skip-build]

  ARCH          amd64 | arm64
  VERSION       release version (e.g. 0.1.1), or "dev" for a local build
  --no-publish  build and package only; do not upload
  --skip-build  reuse packer/output (for re-publishing an existing build)
EOF
	exit 64
}

arch="${1:-}"
version="${2:-}"
[ -n "${arch}" ] && [ -n "${version}" ] || usage
shift 2

publish=true
skip_build=false
for arg in "$@"; do
	case "${arg}" in
	--no-publish) publish=false ;;
	--skip-build) skip_build=true ;;
	*) usage ;;
	esac
done

case "${arch}" in
amd64 | arm64) ;;
*) usage ;;
esac

version="$(scripts/validate-version.sh "${version}")"

log() { printf '\n[release] %s\n' "$*"; }
fail() {
	printf '[release] %s\n' "$*" >&2
	exit 1
}

log "preflight for ${arch} ${version}"

for tool in packer qemu-img xz; do
	command -v "${tool}" >/dev/null 2>&1 || fail "missing ${tool}"
done
if [ "${publish}" = true ]; then
	command -v oras >/dev/null 2>&1 || fail "missing oras (needed to publish; pass --no-publish to skip)"
fi

# Without hardware acceleration QEMU emulates the guest and this build takes
# hours rather than minutes — long enough to look like a hang.
accelerator="$(scripts/select-qemu-accelerator.sh)"
if [ "${accelerator}" = "none" ] && [ "${AGYN_ALLOW_SLOW_BUILD:-}" != "1" ]; then
	fail "no hardware acceleration (no /dev/kvm, not macOS): the build would take hours.
Set AGYN_ALLOW_SLOW_BUILD=1 to proceed anyway."
fi
echo "  accelerator: ${accelerator}"

case "$(uname -s)" in
Darwin) free_gb="$(df -g . | awk 'NR==2 {print $4}')" ;;
*) free_gb="$(df -BG --output=avail . | awk 'NR==2 {gsub("G",""); print $1}')" ;;
esac
echo "  free disk: ${free_gb}G"
if [ "${free_gb}" -lt 20 ]; then
	fail "need at least 20G free, have ${free_gb}G"
fi

log "static validation"
scripts/static-validate.sh

if [ "${skip_build}" = true ]; then
	log "skipping build (--skip-build)"
else
	log "building ${arch}"
	rm -rf "packer/output/${arch}"
	scripts/build.sh "${arch}"
fi

log "packaging ${arch} ${version}"
scripts/package.sh "${arch}" "${version}"

if [ "${publish}" = false ]; then
	log "built and packaged; not publishing (--no-publish)"
	ls -lh "artifacts/${arch}"
	exit 0
fi

log "publishing to GHCR"
scripts/publish.sh "${arch}" "${version}" "${BASE_IMAGE:-ghcr.io/agynio/bundle-vm-base}"

log "released ${arch} ${version}"
printf '\nPin it in bundle-vm/versions.env:\n  BASE_IMAGE_VERSION=%s\n' "${version}"
