#!/usr/bin/env bash
set -euo pipefail

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

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
