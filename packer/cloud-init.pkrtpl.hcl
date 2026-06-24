#cloud-config
ssh_pwauth: false
disable_root: false
users:
  - name: packer
    groups: [adm, sudo]
    lock_passwd: true
    shell: /bin/bash
    ssh_authorized_keys:
      - ${ssh_public_key}
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
package_update: true
package_upgrade: false
packages:
  - openssh-server
runcmd:
  - install -d -m 0755 /etc/ssh/sshd_config.d
  - printf '%s\n' 'PasswordAuthentication no' 'PubkeyAuthentication yes' >/etc/ssh/sshd_config.d/10-packer-build.conf
  - systemctl enable --now ssh
