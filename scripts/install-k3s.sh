#!/usr/bin/env bash
set -euo pipefail

curl -sfL https://get.k3s.io |
	INSTALL_K3S_VERSION="${K3S_VERSION}" \
		INSTALL_K3S_EXEC="server --disable traefik --disable servicelb --write-kubeconfig-mode 0644 --node-name bundle-vm-base" \
		sh -

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

install -d -m 0755 /root/.kube
cp /etc/rancher/k3s/k3s.yaml /root/.kube/config

if id ubuntu >/dev/null 2>&1; then
	install -d -m 0755 -o ubuntu -g ubuntu /home/ubuntu/.kube
	cp /etc/rancher/k3s/k3s.yaml /home/ubuntu/.kube/config
	chown ubuntu:ubuntu /home/ubuntu/.kube/config
fi

cat >/etc/profile.d/agyn-kubeconfig.sh <<'EOF'
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
EOF

scripts/wait-for-k3s.sh 600
