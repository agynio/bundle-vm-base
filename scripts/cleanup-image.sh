#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

rm -rf /tmp/* /var/tmp/*
apt-get clean
rm -rf /var/lib/apt/lists/*

truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id

cloud-init clean --logs --seed
