#!/usr/bin/env bash
set -euo pipefail

wait_for_k3s() {
	timeout_seconds="${1}"
	deadline=$((SECONDS + timeout_seconds))

	while [ "${SECONDS}" -lt "${deadline}" ]; do
		if systemctl is-active --quiet k3s && kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml get --raw=/readyz >/dev/null 2>&1; then
			kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml wait --for=condition=Ready nodes --all --timeout=180s
			return 0
		fi
		sleep 5
	done

	systemctl status k3s --no-pager || true
	journalctl -u k3s --no-pager -n 100 || true
	echo "timed out waiting for k3s API readiness" >&2
	return 1
}

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

wait_for_k3s 600
