#cloud-config
ssh_pwauth: true
disable_root: false
users:
  - name: packer
    groups: [adm, sudo]
    lock_passwd: false
    passwd: "$6$packer$boWUDPn2ItbIVp75vZkcB9enktYcH/yND03ZqeO.xN1ydPY2A8ZRsbTDbbiRlToGQ97O4.AM3Tdw9FQoPk41k."
    shell: /bin/bash
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
package_update: true
package_upgrade: false
packages:
  - openssh-server
runcmd:
  - sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - systemctl enable --now ssh
