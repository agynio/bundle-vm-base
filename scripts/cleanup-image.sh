#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

cloud-init clean --logs --seed

if getent passwd packer >/dev/null; then
	sed -i "/^packer:/d" /etc/passwd /etc/shadow /etc/group /etc/gshadow
	rm -rf /home/packer
fi

passwd -l root

install -d -m 0755 /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/99-agyn-base.conf <<'EOF'
PasswordAuthentication no
PermitRootLogin prohibit-password
EOF

rm -rf /tmp/* /var/tmp/*
apt-get clean
rm -rf /var/lib/apt/lists/*

truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id
