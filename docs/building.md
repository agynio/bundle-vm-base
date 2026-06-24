# Building and publishing

This repository builds one QCOW2 base disk per architecture and publishes each
architecture as a separate OCI artifact in GHCR:

- `ghcr.io/agynio/bundle-vm-base:<version>-amd64`
- `ghcr.io/agynio/bundle-vm-base:<version>-arm64`
- `ghcr.io/agynio/bundle-vm-base:latest-amd64` from `main`
- `ghcr.io/agynio/bundle-vm-base:latest-arm64` from `main`

## CI runner policy

The default pull request workflow runs static validation and the amd64 VM build
on GitHub-hosted Linux runners. The arm64 VM build is skipped on pull requests
unless repository variable `RUN_ARM64_PR_BUILD=true` is set, because the default
hosted ARM64 Linux runner currently exposes no usable hardware acceleration for
this image and times out before SSH under `QEMU_ACCELERATOR=none`.

Static validation runs on `ubuntu-latest`. The amd64 build runs on
`ubuntu-latest` and explicitly enables KVM access before invoking Packer. The
workflow uses the udev rule recommended by GitHub's Linux hosted runner
hardware-acceleration documentation:

```sh
echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' | sudo tee /etc/udev/rules.d/99-kvm4all.rules
sudo udevadm control --reload-rules
sudo udevadm trigger --name-match=kvm
```

On hosted Linux runners where triggering the `kvm` device rule itself reports
that the device is unavailable, the workflow continues to the explicit
accelerator probe so the job fails with the repository's publish-build message
instead of a raw udev error.

After that step, each build job probes `/dev/kvm` via
`scripts/select-qemu-accelerator.sh`:

- `build-amd64`: `ubuntu-latest`, requires `uname -m == x86_64` and usable
  `/dev/kvm`. This path has completed successfully in PR CI with KVM.
- `build-arm64`: requires a native ARM64 runner and a supported accelerator. Set
  repository variable `ARM64_BUILD_RUNNER` to an ARM64 Linux runner with KVM or
  an Apple Silicon macOS runner with HVF. The legacy `ARM64_KVM_RUNNER` variable
  is still honored for Linux KVM runner labels. The default fallback label is
  `ubuntu-24.04-arm`, but that runner currently reaches `QEMU_ACCELERATOR=none`
  and fails fast with a clear message instead of attempting a known-unreliable
  publish build.

Native-architecture runners are always used. Cross-architecture emulation is not
the default path. Mac local builds and Apple Silicon macOS runners use HVF via
`scripts/select-qemu-accelerator.sh`; Linux runners use KVM when `/dev/kvm` is
readable and writable.

## Publishing policy

Pull requests build amd64 and upload workflow artifacts but do not publish to
GHCR. Pull request arm64 builds are opt-in with `RUN_ARM64_PR_BUILD=true` and an
accelerated ARM64 runner. Pushes to `main` and `v*` tags publish both
architecture artifacts to GHCR, and the arm64 publish job must run on the
accelerated ARM64 runner selected by `ARM64_BUILD_RUNNER` or `ARM64_KVM_RUNNER`.
Manual `workflow_dispatch` runs publish by default and can opt out with the
`publish` input.

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

`scripts/build.sh` defaults to `QEMU_ACCELERATOR=auto`, which selects `hvf` on
macOS, `kvm` on Linux when `/dev/kvm` is readable and writable, and otherwise
`none`. Set `QEMU_ACCELERATOR=hvf` or `QEMU_ACCELERATOR=kvm` to force hardware
acceleration. Software acceleration is only for local experimentation; publish
builds must use HVF or KVM.

For arm64, run the same commands on an ARM64 host. Apple Silicon Macs use HVF by
default:

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
The temporary Packer build user is removed during image finalization, and
password SSH authentication is disabled in the final disk.
