# Building and publishing

This repository builds one QCOW2 base disk per architecture and publishes each
architecture as a separate OCI artifact in GHCR:

- `ghcr.io/agynio/bundle-vm-base:<version>-amd64`
- `ghcr.io/agynio/bundle-vm-base:<version>-arm64`
- `ghcr.io/agynio/bundle-vm-base:latest-amd64` from `main`
- `ghcr.io/agynio/bundle-vm-base:latest-arm64` from `main`

## Architecture policy

Builds are configured for native runners:

- `amd64`: self-hosted Linux AMD64 runner with labels `self-hosted`, `linux`,
  `amd64`, and `kvm`
- `arm64`: self-hosted Linux ARM64 runner with labels `self-hosted`, `linux`,
  `arm64`, and `kvm`

Static validation stays on GitHub-hosted `ubuntu-latest`, but disk builds run
only on KVM-capable self-hosted runners. GitHub-hosted Linux runners do not
provide usable nested KVM for this repository, and TCG/software QEMU has proven
too slow for reliable k3s, cert-manager, and Argo CD provisioning. The build
jobs verify the native machine architecture and read/write access to `/dev/kvm`
before invoking Packer with `QEMU_ACCELERATOR=kvm`.

Register appropriate self-hosted runners, or update the workflow `runs-on`
labels to match the organization's equivalent KVM-capable runner labels:

```yaml
runs-on:
  - self-hosted
  - linux
  - amd64 # or arm64
  - kvm
```

Native builds are preferred because k3s and cluster component provisioning makes
cross-architecture QEMU emulation slow and less reliable.

Pull request workflows do not start the arm64 build, so a missing self-hosted
runner does not keep the PR workflow queued and block access to amd64 failure
logs. Run the `build-arm64` workflow manually when the required self-hosted
runner is available. The amd64 build remains in the main workflow but requires
the KVM-capable self-hosted AMD64 runner described above.

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
`QEMU_ACCELERATOR=kvm` to force hardware acceleration. CI forces
`QEMU_ACCELERATOR=kvm` for image builds; software acceleration is only for local
experimentation and is not a supported publish path.

For arm64, run the same commands on an ARM64 host:

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
