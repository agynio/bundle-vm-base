# Manual Lima usage

The published GHCR artifact contains four files:

- `bundle-vm-base-<arch>.qcow2.xz`
- `metadata.json`
- `checksums.sha256`
- `lima.yaml`

The disk includes Ubuntu, k3s, cert-manager, Argo CD, Helm, kubectl, and
common diagnostic tooling. It does not contain Agyn production, staging, or
external service credentials.

## Prerequisites

- Lima 1.0 or newer.
- ORAS 1.2 or newer.
- `xz`, `sha256sum`, and `jq`.
- A host architecture matching the image architecture whenever possible.

## Pull from GHCR

Choose the architecture that matches your host:

```sh
ARCH=amd64
VERSION=latest
IMAGE=ghcr.io/agynio/bundle-vm-base
mkdir -p agyn-base-${ARCH}
oras pull "${IMAGE}:${VERSION}-${ARCH}" -o "agyn-base-${ARCH}"
```

For Apple Silicon or Linux ARM64 hosts, use `ARCH=arm64`.

## Verify and decompress

```sh
cd "agyn-base-${ARCH}"
sha256sum -c checksums.sha256
xz -dk bundle-vm-base-${ARCH}.qcow2.xz
jq . metadata.json
```

The generated `lima.yaml` references the decompressed QCOW2 in the same
directory and maps OCI architecture names to Lima/QEMU architecture names
(`amd64` to `x86_64`, `arm64` to `aarch64`).

## Start the VM

```sh
limactl start --name agyn-base lima.yaml
```

## Check k3s

```sh
limactl shell agyn-base -- sudo systemctl status k3s --no-pager
limactl shell agyn-base -- sudo kubectl get nodes -o wide
limactl shell agyn-base -- sudo kubectl get pods -A
```

## Check cert-manager

```sh
limactl shell agyn-base -- sudo kubectl -n cert-manager get deploy,pods
limactl shell agyn-base -- sudo kubectl -n cert-manager wait --for=condition=Available deploy --all --timeout=180s
```

## Check Argo CD

```sh
limactl shell agyn-base -- sudo kubectl -n argocd get deploy,pods
limactl shell agyn-base -- sudo kubectl -n argocd wait --for=condition=Available deploy --all --timeout=180s
```

## Stop and remove

```sh
limactl stop agyn-base
limactl delete agyn-base
```

## Notes

- The image is intended as the reusable VM base layer. Agyn service bundle
  versions are intentionally not baked into it.
- The default kubeconfig inside the VM is `/etc/rancher/k3s/k3s.yaml`.
- Lima will create runtime state outside the QCOW2. Keep the pulled directory if
  you want to reuse the base disk.
