packer {
  required_version = ">= 1.10.0"

  required_plugins {
    qemu = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

variable "arch" {
  type = string
  validation {
    condition     = contains(["amd64", "arm64"], var.arch)
    error_message = "Architecture must be amd64 or arm64."
  }
}

variable "ubuntu_series" {
  type    = string
  default = "noble"
}

variable "ubuntu_version" {
  type    = string
  default = "24.04"
}

variable "disk_size" {
  type    = string
  default = "16G"
}

variable "k3s_version" {
  type = string
}

variable "cert_manager_version" {
  type = string
}

variable "argocd_version" {
  type = string
}

variable "helm_version" {
  type = string
}

variable "kubectl_version" {
  type = string
}

variable "qemu_accelerator" {
  type    = string
  default = "kvm"
  validation {
    condition     = contains(["kvm", "none"], var.qemu_accelerator)
    error_message = "QEMU accelerator must be kvm or none."
  }
}

locals {
  ubuntu_arch = var.arch == "amd64" ? "amd64" : "arm64"
  qemu_arch   = var.arch == "amd64" ? "x86_64" : "aarch64"
  machine     = var.arch == "amd64" ? "pc" : "virt"
  cpu         = var.qemu_accelerator == "kvm" ? "host" : "max"
  iso_url     = "https://cloud-images.ubuntu.com/${var.ubuntu_series}/current/${var.ubuntu_series}-server-cloudimg-${local.ubuntu_arch}.img"
  sha_url     = "https://cloud-images.ubuntu.com/${var.ubuntu_series}/current/SHA256SUMS"
}

source "qemu" "ubuntu_cloud" {
  accelerator = var.qemu_accelerator
  boot_wait   = "2s"
  cd_content = {
    "meta-data" = "instance-id: bundle-vm-base-${var.arch}\nlocal-hostname: bundle-vm-base\n"
    "user-data" = templatefile("cloud-init.pkrtpl.hcl", {})
  }
  cd_label         = "cidata"
  cpus             = 2
  disk_compression = false
  disk_image       = true
  disk_size        = var.disk_size
  format           = "qcow2"
  headless         = true
  iso_checksum     = "file:${local.sha_url}"
  iso_url          = local.iso_url
  machine_type     = local.machine
  memory           = 4096
  net_device       = "virtio-net"
  output_directory = "output/${var.arch}"
  qemu_binary      = "qemu-system-${local.qemu_arch}"
  qemuargs = var.arch == "arm64" ? [
    ["-cpu", local.cpu],
    ["-device", "virtio-gpu-pci"],
    ["-device", "qemu-xhci"],
    ] : [
    ["-cpu", local.cpu],
  ]
  shutdown_command       = "sudo cloud-init clean --logs && sudo shutdown -P now"
  ssh_handshake_attempts = 120
  ssh_password           = "packer"
  ssh_timeout            = "30m"
  ssh_username           = "packer"
  vm_name                = "bundle-vm-base-${var.arch}.qcow2"
}

build {
  name    = "bundle-vm-base"
  sources = ["source.qemu.ubuntu_cloud"]

  provisioner "shell" {
    environment_vars = [
      "ARCH=${var.arch}",
      "K3S_VERSION=${var.k3s_version}",
      "CERT_MANAGER_VERSION=${var.cert_manager_version}",
      "ARGOCD_VERSION=${var.argocd_version}",
      "HELM_VERSION=${var.helm_version}",
      "KUBECTL_VERSION=${var.kubectl_version}",
    ]
    execute_command = "sudo -E bash '{{ .Path }}'"
    scripts = [
      "${path.root}/../scripts/provision-base.sh",
      "${path.root}/../scripts/install-k3s.sh",
      "${path.root}/../scripts/install-cluster-components.sh",
      "${path.root}/../scripts/cleanup-image.sh",
    ]
  }
}
