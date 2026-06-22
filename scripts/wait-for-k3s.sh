#!/usr/bin/env bash
set -euo pipefail

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

timeout_seconds="${1:-300}"
deadline=$((SECONDS + timeout_seconds))

while [ "${SECONDS}" -lt "${deadline}" ]; do
	if systemctl is-active --quiet k3s && kubectl get --raw=/readyz >/dev/null 2>&1; then
		kubectl wait --for=condition=Ready nodes --all --timeout=180s
		exit 0
	fi
	sleep 5
done

systemctl status k3s --no-pager || true
journalctl -u k3s --no-pager -n 100 || true
echo "timed out waiting for k3s API readiness" >&2
exit 1
