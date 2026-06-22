#!/usr/bin/env bash
set -euo pipefail

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
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

wait_for_k3s 600

kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
kubectl -n cert-manager rollout status deploy/cert-manager --timeout=300s
kubectl -n cert-manager rollout status deploy/cert-manager-cainjector --timeout=300s
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=300s

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
kubectl -n argocd rollout status deploy/argocd-applicationset-controller --timeout=300s
kubectl -n argocd rollout status deploy/argocd-dex-server --timeout=300s
kubectl -n argocd rollout status deploy/argocd-notifications-controller --timeout=300s
kubectl -n argocd rollout status deploy/argocd-redis --timeout=300s
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=300s
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s

cat >/etc/agyn/components.json <<EOF
{
  "k3s": "${K3S_VERSION}",
  "certManager": "${CERT_MANAGER_VERSION}",
  "argoCd": "${ARGOCD_VERSION}",
  "helm": "${HELM_VERSION}",
  "kubectl": "${KUBECTL_VERSION}"
}
EOF
