#!/usr/bin/env bash
set -euo pipefail

K3S_KUBECONFIG=/etc/rancher/k3s/k3s.yaml

log_k3s_readiness() {
	printf '[k3s readiness] %s\n' "$*"
}

dump_k3s_diagnostics() {
	systemctl status k3s --no-pager || true
	journalctl -u k3s --no-pager -n 100 || true
}

wait_for_k3s() {
	timeout_seconds="${1}"
	deadline=$((SECONDS + timeout_seconds))

	log_k3s_readiness "waiting for k3s service and API /readyz"
	while [ "${SECONDS}" -lt "${deadline}" ]; do
		if systemctl is-active --quiet k3s && kubectl --kubeconfig="${K3S_KUBECONFIG}" get --raw=/readyz >/dev/null 2>&1; then
			log_k3s_readiness "k3s API /readyz is available"
			break
		fi
		sleep 5
	done

	if [ "${SECONDS}" -ge "${deadline}" ]; then
		dump_k3s_diagnostics
		echo "timed out waiting for k3s service and API /readyz" >&2
		return 1
	fi

	log_k3s_readiness "waiting for node registration"
	while [ "${SECONDS}" -lt "${deadline}" ]; do
		node_names="$(kubectl --kubeconfig="${K3S_KUBECONFIG}" get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
		if [ -n "${node_names}" ]; then
			log_k3s_readiness "registered nodes: ${node_names}"
			break
		fi
		sleep 5
	done

	if [ "${SECONDS}" -ge "${deadline}" ]; then
		dump_k3s_diagnostics
		echo "timed out waiting for k3s node registration" >&2
		return 1
	fi

	log_k3s_readiness "waiting for registered nodes to become Ready"
	while [ "${SECONDS}" -lt "${deadline}" ]; do
		if kubectl --kubeconfig="${K3S_KUBECONFIG}" wait --for=condition=Ready nodes --all --timeout=30s; then
			log_k3s_readiness "all registered nodes are Ready"
			return 0
		fi
		sleep 5
	done

	dump_k3s_diagnostics
	echo "timed out waiting for k3s nodes to become Ready" >&2
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
