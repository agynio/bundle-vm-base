#!/usr/bin/env bash
set -euo pipefail

curl -sfL https://get.k3s.io |
	INSTALL_K3S_VERSION="${K3S_VERSION}" \
		INSTALL_K3S_EXEC="server --disable traefik --disable servicelb --write-kubeconfig-mode 0644 --node-name bundle-vm-base" \
		sh -

install -d -m 0755 /home/ubuntu/.kube /root/.kube
cp /etc/rancher/k3s/k3s.yaml /home/ubuntu/.kube/config
cp /etc/rancher/k3s/k3s.yaml /root/.kube/config
chown -R ubuntu:ubuntu /home/ubuntu/.kube

cat >/etc/profile.d/agyn-kubeconfig.sh <<'EOF'
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
EOF

kubectl wait --for=condition=Ready nodes --all --timeout=180s
