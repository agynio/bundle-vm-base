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

- Packer 1.10 or newer.
- QEMU system packages.
- OpenSSH client tools, including `ssh-keygen`.
- `xz`, `jq`, and `sha256sum`.
- Network access to Ubuntu cloud images, k3s, Kubernetes, Helm, cert-manager,
  and Argo CD release assets.

Use a native host for the target architecture. Linux builds use KVM when
`/dev/kvm` is readable and writable. Apple Silicon builds use QEMU HVF and
must run on macOS ARM64.

### Apple Silicon macOS prerequisites

Install the local build tools with Homebrew:

```sh
brew install packer qemu xorriso xz jq openssh
```

The arm64 Ubuntu cloud image boots through UEFI. On Apple Silicon, the build
script resolves QEMU's ARM64 edk2 firmware from the QEMU installation and passes
it to Packer explicitly. The expected Homebrew firmware files are usually:

- `/opt/homebrew/share/qemu/edk2-aarch64-code.fd`
- `/opt/homebrew/share/qemu/edk2-arm-vars.fd`

If QEMU is installed somewhere else, set both firmware paths explicitly:

```sh
PACKER_EFI_FIRMWARE_CODE=/path/to/edk2-aarch64-code.fd \
PACKER_EFI_FIRMWARE_VARS=/path/to/edk2-arm-vars.fd \
QEMU_ACCELERATOR=hvf scripts/build.sh arm64
```

The script fails before starting Packer when `qemu-system-aarch64` is missing,
the firmware files are unreadable, the QEMU binary lacks HVF support, or the
host is not Apple Silicon macOS while `QEMU_ACCELERATOR=hvf` is forced. These
checks are intended to surface local setup problems before Packer reaches its
long SSH timeout.

The ARM64 Packer source attaches the generated NoCloud `cidata` seed CD-ROM as
`virtio-scsi` and does not pass custom `-device` qemuargs. That allows Packer to
keep managing the generated `virtio-scsi-pci` and `scsi-cd` devices required for
the seed to be guest-visible on Apple Silicon HVF and Linux ARM64 KVM. The
temporary `packer` user receives the generated SSH public key from cloud-init
before Packer starts provisioning.

### SSH-timeout diagnostics

`scripts/build.sh` enables Packer debug logging for every build. When an Apple
Silicon HVF build runs, it also writes the guest serial console to a separate
log. The default paths are timestamped files under `${TMPDIR:-/tmp}`:

- `bundle-vm-base-packer-arm64-YYYYmmddHHMMSS.log`
- `bundle-vm-base-serial-arm64-YYYYmmddHHMMSS.log`

Set `PACKER_LOG_PATH` or `PACKER_SERIAL_LOG_PATH` to choose explicit paths. On
failure, the script prints both paths, extracts the communicator host port and
QEMU `hostfwd` entry from the Packer log when present, runs a best-effort TCP
probe against `127.0.0.1:<port>`, and tails both logs.

Search the serial log for these cloud-init markers:

- `AGYN-DIAG cloud-init runcmd start`
- `AGYN-DIAG block devices:`
- `AGYN-DIAG cidata devices:`
- `AGYN-DIAG cidata mounts:`
- `AGYN-DIAG packer user present`
- `AGYN-DIAG packer authorized_keys present`
- `AGYN-DIAG ssh service active`
- `AGYN-DIAG listening sockets:`
- `AGYN-DIAG cloud-init runcmd complete`

Use the emitted evidence to narrow SSH timeouts:

| Evidence | Likely cause |
| --- | --- |
| No serial log or no kernel/cloud-init output | Guest did not boot far enough, or serial capture failed. Check ARM64 firmware and QEMU startup lines in the Packer log. |
| No `cidata` device or mount marker | NoCloud seed was not guest-visible. Check `cdrom_interface`, Packer-managed SCSI devices, and QEMU device arguments. |
| `cidata` is visible but no cloud-init completion marker | cloud-init failed or stalled before finishing user setup. Inspect surrounding serial output. |
| Missing packer user or authorized key markers | cloud-init did not apply the user data that Packer generated. Check seed contents and cloud-init errors. |
| `ssh service active` missing or no port 22 listener in socket output | sshd did not start inside the guest. Inspect `systemctl status ssh` in the serial log. |
| Guest sshd is active but host TCP probe fails | QEMU user networking or `hostfwd` did not expose the communicator port. Inspect the Packer log `hostfwd` line. |
| Host TCP probe succeeds but Packer still cannot connect | The path is reachable; inspect SSH auth, username, and key fingerprint details. |

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
QEMU_ACCELERATOR=hvf scripts/build.sh arm64
scripts/package.sh arm64 dev
```

`QEMU_ACCELERATOR=hvf` is optional on macOS because `auto` selects HVF, but it
is useful when validating Apple Silicon-specific setup. Linux ARM64 KVM hosts
keep the same build path and do not require manual firmware variables:

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
`scripts/build.sh` creates a temporary Ed25519 SSH keypair for each Packer run,
injects only that public key into the NoCloud seed data for the temporary
`packer` build user, and passes the private key path to Packer. Password SSH
authentication is disabled during the build and in the final disk. The temporary
private key remains on the host only, is removed when the build script exits,
and the temporary Packer build user is removed during image finalization.
When a build fails, the script prints the key fingerprint, ARM64 firmware, seed
attachment mode, Packer-managed device policy, Packer debug log path, ARM64 HVF
serial console log path, communicator host port, QEMU `hostfwd` entry, and a
best-effort host TCP probe. The serial log includes `AGYN-DIAG` markers for
block devices, `cidata`, cloud-init completion, `packer` user setup, sshd
startup, and listening sockets.
