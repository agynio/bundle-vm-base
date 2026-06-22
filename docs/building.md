# Building and publishing

This repository builds one QCOW2 base disk per architecture and publishes each
architecture as a separate OCI artifact in GHCR:

- `ghcr.io/agynio/bundle-vm-base:<version>-amd64`
- `ghcr.io/agynio/bundle-vm-base:<version>-arm64`
- `ghcr.io/agynio/bundle-vm-base:latest-amd64` from `main`
- `ghcr.io/agynio/bundle-vm-base:latest-arm64` from `main`

## CI runner policy

The default GitHub Actions workflow uses GitHub-hosted Linux runners. It does
not require self-hosted runners.

Static validation runs on `ubuntu-latest`. VM disk builds also run on
GitHub-hosted Linux runners and explicitly enable KVM access before invoking
Packer. The workflow uses the udev rule recommended by GitHub's Linux hosted
runner hardware-acceleration documentation:

```sh
echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' | sudo tee /etc/udev/rules.d/99-kvm4all.rules
sudo udevadm control --reload-rules
sudo udevadm trigger --name-match=kvm
```

After that step, each build job probes `/dev/kvm` via
`scripts/select-qemu-accelerator.sh` and proceeds only when the selected
accelerator is `kvm`:

- `build-amd64`: `ubuntu-latest`, requires `uname -m == x86_64` and usable
  `/dev/kvm`.
- `build-arm64`: `ubuntu-24.04-arm`, requires `uname -m == aarch64` and usable
  `/dev/kvm`.

Hosted/non-KVM software emulation is unsupported for publish builds. TCG QEMU
runs were observed to fail or time out during k3s, cert-manager, and Argo CD
provisioning. If `/dev/kvm` is unavailable on a runner, the job fails fast with
a clear message instead of falling back to `QEMU_ACCELERATOR=none`.

If GitHub-hosted ARM64 runners do not expose usable `/dev/kvm`, hosted arm64 KVM
availability is the remaining blocker for arm64 publish builds. The next
acceptable alternative is an ephemeral cloud-builder workflow that creates
temporary amd64 and arm64 cloud VMs with KVM, runs the build and publish commands
on them, and destroys the VMs afterward. That requires cloud credentials or OIDC
role setup and is not implemented in this PR.

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
