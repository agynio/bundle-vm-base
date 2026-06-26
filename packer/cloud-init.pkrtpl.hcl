#cloud-config
ssh_pwauth: false
disable_root: false
%{ if enable_cloud_init_diagnostics ~}
output:
  all: "| tee -a /var/log/cloud-init-output.log /dev/console"
%{ endif ~}
users:
  - name: packer
    groups: [adm, sudo]
    lock_passwd: true
    shell: /bin/bash
    ssh_authorized_keys:
      - ${ssh_public_key}
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
%{ if enable_cloud_init_diagnostics ~}
bootcmd:
  - |
    printf '%s\n' 'AGYN-DIAG bootcmd start'
  - |
    printf '%s' 'AGYN-DIAG bootcmd block devices: '
    lsblk -o NAME,TYPE,FSTYPE,LABEL,MOUNTPOINTS || true
  - |
    printf '%s' 'AGYN-DIAG bootcmd cidata devices: '
    blkid -L cidata || true
  - |
    printf '%s' 'AGYN-DIAG bootcmd cidata mounts: '
    findmnt -rno SOURCE,TARGET,LABEL | awk '$3 == "cidata" { print }' || true
  - |
    printf '%s\n' 'AGYN-DIAG bootcmd complete'
%{ endif ~}
runcmd:
%{ if enable_cloud_init_diagnostics ~}
  - |
    printf '%s\n' 'AGYN-DIAG cloud-init runcmd start'
  - |
    printf '%s' 'AGYN-DIAG block devices: '
    lsblk -o NAME,TYPE,FSTYPE,LABEL,MOUNTPOINTS || true
  - |
    printf '%s' 'AGYN-DIAG cidata devices: '
    blkid -L cidata || true
  - |
    printf '%s' 'AGYN-DIAG cidata mounts: '
    findmnt -rno SOURCE,TARGET,LABEL | awk '$3 == "cidata" { print }' || true
  - |
    if id packer >/dev/null 2>&1; then
      printf '%s\n' 'AGYN-DIAG packer user present'
    else
      printf '%s\n' 'AGYN-DIAG packer user missing'
    fi
  - |
    if test -s /home/packer/.ssh/authorized_keys; then
      printf '%s\n' 'AGYN-DIAG packer authorized_keys present'
    else
      printf '%s\n' 'AGYN-DIAG packer authorized_keys missing'
    fi
%{ endif ~}
  - install -d -m 0755 /etc/ssh/sshd_config.d
  - |
    printf '%s\n' 'PasswordAuthentication no' 'PubkeyAuthentication yes' >/etc/ssh/sshd_config.d/10-packer-build.conf
  - systemctl enable --now ssh
%{ if enable_cloud_init_diagnostics ~}
  - systemctl --no-pager --full status ssh || true
  - |
    if systemctl is-active --quiet ssh; then
      printf '%s\n' 'AGYN-DIAG ssh service active'
    else
      printf '%s\n' 'AGYN-DIAG ssh service inactive'
    fi
  - |
    if command -v sshd >/dev/null 2>&1; then
      sshd -t && printf '%s\n' 'AGYN-DIAG sshd config valid'
    elif [ -x /usr/sbin/sshd ]; then
      /usr/sbin/sshd -t && printf '%s\n' 'AGYN-DIAG sshd config valid'
    else
      printf '%s\n' 'AGYN-DIAG sshd binary missing'
    fi
  - |
    printf '%s' 'AGYN-DIAG ssh host keys: '
    find /etc/ssh -maxdepth 1 -name 'ssh_host_*_key.pub' -type f -print | sort || true
  - |
    printf '%s' 'AGYN-DIAG listening sockets: '
    ss -ltnp || true
  - |
    printf '%s' 'AGYN-DIAG port 22 listeners: '
    ss -ltnp '( sport = :22 )' || true
  - |
    printf '%s\n' 'AGYN-DIAG ssh journal tail start'
    journalctl -u ssh --no-pager -n 80 || true
    printf '%s\n' 'AGYN-DIAG ssh journal tail complete'
  - |
    printf '%s\n' 'AGYN-DIAG cloud-init runcmd complete'
%{ endif ~}
