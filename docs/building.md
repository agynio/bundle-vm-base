# Building and publishing

This repository builds one QCOW2 base disk per architecture and publishes each
architecture as a separate OCI artifact in GHCR:

- `ghcr.io/agynio/bundle-vm-base:<version>-amd64`
- `ghcr.io/agynio/bundle-vm-base:<version>-arm64`
- `ghcr.io/agynio/bundle-vm-base:latest-amd64` from `main`
- `ghcr.io/agynio/bundle-vm-base:latest-arm64` from `main`

## Current CI status

The default GitHub Actions workflow currently performs static validation on
GitHub-hosted `ubuntu-latest` runners. It does **not** require or target
self-hosted runners.

Actual publish-capable VM disk builds require usable KVM. Standard
GitHub-hosted runners did not provide a reliable KVM path for this Packer/QEMU
build, and hosted non-KVM software emulation is unsupported for publish builds:
observed TCG/software QEMU runs failed or timed out during k3s, cert-manager,
and Argo CD provisioning.

Until the repository has either a GitHub-hosted/larger runner SKU with usable
`/dev/kvm` for both amd64 and arm64, or credentials for an ephemeral cloud
builder implementation, normal `main`/tag CI is intentionally limited to static
validation and does not claim to publish complete VM disk artifacts.

## Hosted KVM build scaffold

The `build` workflow includes a manual `workflow_dispatch` input named
`run_vm_builds`. When set to `true`, the workflow attempts amd64 and arm64 VM
builds on GitHub-hosted runner labels and probes `/dev/kvm` before invoking
Packer:

- `build-amd64`: `ubuntu-latest`, requires `uname -m == x86_64` and readable /
  writable `/dev/kvm`.
- `build-arm64`: `ubuntu-24.04-arm`, requires `uname -m == aarch64` and readable
  / writable `/dev/kvm`.

If KVM is unavailable, the job fails before the expensive build with a clear
message. The workflow does not fall back to non-KVM QEMU for publish builds.

## TODO for publish-capable CI

Choose one of these before enabling automatic publish builds on `main` and tags:

1. Use GitHub-hosted or larger runner labels that provide usable `/dev/kvm` for
   both amd64 and arm64, then enable the build jobs for push/tag events.
2. Add an ephemeral cloud-builder workflow: GitHub Actions creates temporary
   amd64 and arm64 cloud VMs with KVM, runs the build and publish commands on
   them, and destroys the VMs afterward. This requires cloud credentials or OIDC
   role setup that is not present in this PR.

Persistent self-hosted runners are not a required or documented primary path.

## Local build prerequisites

- Linux host with KVM enabled.
- Packer 1.10 or newer.
- QEMU system packages.
- `xz`, `jq`, and `sha256sum`.
- Network access to Ubuntu cloud images, k3s, Kubernetes, Helm, cert-manager,
  and Argo CD release assets.

## Local static validation

```sh
scripts/static-validate.sh
```

The script runs the available validators installed on the host:

- Packer init, fmt check, and validate when `packer` exists.
- ShellCheck when `shellcheck` exists.
- yamllint when `yamllint` exists.
- JSON validation for generated artifact metadata when `jq` exists.

## Local build

```sh
scripts/build.sh amd64
scripts/package.sh amd64 dev
```

`scripts/build.sh` defaults to `QEMU_ACCELERATOR=auto`, which selects `kvm` only
when `/dev/kvm` is readable and writable, and otherwise selects `none`. Set
`QEMU_ACCELERATOR=kvm` to force hardware acceleration. Software acceleration is
only for local experimentation and is not a supported publish path.

For arm64, run the same commands on an ARM64 host with KVM:

```sh
scripts/build.sh arm64
scripts/package.sh arm64 dev
```

## Smoke test with Lima

After packaging an artifact locally, run:

```sh
scripts/smoke-lima.sh agyn-base-smoke artifacts/amd64/lima.yaml
```

The smoke test starts the Lima VM and waits for the k3s node, cert-manager
deployments, and Argo CD deployments to become available.

## Publish manually

Login to GHCR first:

```sh
oras login ghcr.io
scripts/publish.sh amd64 dev ghcr.io/agynio/bundle-vm-base latest
```

The publisher pushes the compressed QCOW2 disk, metadata, checksums, and Lima
example as one OCI artifact with an Agyn-specific artifact media type.

Artifact versions are validated before packaging and publishing. They must be
valid OCI tag components: 128 characters or fewer, start with an ASCII letter,
digit, or underscore, and contain only ASCII letters, digits, underscores,
periods, and hyphens.

## Credentials

The base image must not include Agyn production, staging, external service, or
developer credentials. Local-only credentials created by Lima or cloud-init are
for VM access only and must not grant access to non-local Agyn infrastructure.
The temporary Packer build user is removed during image cleanup, and password
SSH authentication is disabled in the final disk.
