# bundle-vm-base

Build and publish Agyn base VM disks for the local bundle runtime.

This repository owns the reusable VM base layer for the future Agyn local bundle
runtime. It builds native `linux/amd64` and `linux/arm64` Ubuntu QCOW2 disks
with:

- single-node k3s
- cert-manager
- Argo CD
- Helm, kubectl, and common CLI/debug tooling

It intentionally does not bake Agyn service bundle versions or any production,
staging, external service, or developer credentials into the image.

## Artifacts

CI publishes OCI artifacts to GHCR with architecture-specific tags:

- `ghcr.io/agynio/bundle-vm-base:<version>-amd64`
- `ghcr.io/agynio/bundle-vm-base:<version>-arm64`
- `ghcr.io/agynio/bundle-vm-base:latest-amd64`
- `ghcr.io/agynio/bundle-vm-base:latest-arm64`

Each artifact contains:

- compressed QCOW2 disk (`bundle-vm-base-<arch>.qcow2.xz`)
- `checksums.sha256`
- `metadata.json` with OS, architecture, disk, k3s, and component versions
- generated `lima.yaml` for manual testing

## Documentation

- [Building and publishing](docs/building.md)
- [Manual Lima usage](docs/lima.md)

## Quick local validation

```sh
scripts/static-validate.sh
```

## Quick local build

Run on a Linux host with KVM and Packer installed:

```sh
scripts/build.sh amd64
scripts/package.sh amd64 dev
```

Use `arm64` on a native ARM64 host. Native builds are preferred; see
[building docs](docs/building.md) for the self-hosted ARM64 runner option.
