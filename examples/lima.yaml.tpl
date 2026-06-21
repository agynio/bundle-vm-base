vmType: qemu
arch: "{{LIMA_ARCH}}"
cpus: 4
memory: 6GiB
disk: 16GiB

images:
  - location: ./bundle-vm-base-{{ARCH}}.qcow2
    arch: "{{LIMA_ARCH}}"

mounts: []

ssh:
  localPort: 0
  loadDotSSHPubKeys: true

containerd:
  system: false
  user: false

provision:
  - mode: system
    script: |
      #!/usr/bin/env bash
      set -euo pipefail
      systemctl enable --now k3s

probes:
  - mode: readiness
    script: |
      #!/usr/bin/env bash
      set -euo pipefail
      sudo kubectl wait --for=condition=Ready nodes --all --timeout=180s
