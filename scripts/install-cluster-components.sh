#!/usr/bin/env bash
set -euo pipefail

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
K3S_KUBECONFIG=/etc/rancher/k3s/k3s.yaml
COMPONENT_ROLLOUT_TIMEOUT=900s
IMAGE_PULL_TIMEOUT=1800
COMPONENT_IMAGES=(
	"quay.io/jetstack/cert-manager-controller:${CERT_MANAGER_VERSION}"
	"quay.io/jetstack/cert-manager-cainjector:${CERT_MANAGER_VERSION}"
	"quay.io/jetstack/cert-manager-webhook:${CERT_MANAGER_VERSION}"
	"quay.io/argoproj/argocd:${ARGOCD_VERSION}"
	"ghcr.io/dexidp/dex:v2.41.1"
	"redis:7.2.7-alpine"
)

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

pull_component_image() {
	image="${1}"
	deadline=$((SECONDS + IMAGE_PULL_TIMEOUT))

	echo "[component images] pulling ${image}"
	while [ "${SECONDS}" -lt "${deadline}" ]; do
		if k3s crictl pull "${image}"; then
			echo "[component images] pulled ${image}"
			return 0
		fi

		echo "[component images] retrying ${image} after failed pull" >&2
		sleep 15
	done

	echo "timed out pulling component image ${image}" >&2
	return 1
}

pre_pull_component_images() {
	for image in "${COMPONENT_IMAGES[@]}"; do
		pull_component_image "${image}"
	done

	echo "[component images] images available in k3s containerd"
	k3s crictl images | grep -E 'cert-manager|argocd|dex|redis' || true
}

pre_pull_component_images

dump_namespace_diagnostics() {
	namespace="${1}"

	echo "[component diagnostics] namespace=${namespace}: pods"
	kubectl -n "${namespace}" get pods -o wide || true
	echo "[component diagnostics] namespace=${namespace}: deployments"
	kubectl -n "${namespace}" get deployments -o wide || true
	echo "[component diagnostics] namespace=${namespace}: deployment descriptions"
	kubectl -n "${namespace}" describe deployments || true
	echo "[component diagnostics] namespace=${namespace}: pod descriptions"
	kubectl -n "${namespace}" describe pods || true
	echo "[component diagnostics] namespace=${namespace}: recent events"
	kubectl -n "${namespace}" get events --sort-by=.lastTimestamp || true
}

wait_for_deployment_rollout() {
	namespace="${1}"
	deployment="${2}"
	timeout="${3}"

	echo "[component readiness] waiting for deployment ${namespace}/${deployment} rollout (${timeout})"
	if kubectl -n "${namespace}" rollout status "deploy/${deployment}" --timeout="${timeout}"; then
		echo "[component readiness] deployment ${namespace}/${deployment} is available"
		return 0
	fi

	dump_namespace_diagnostics "${namespace}"
	echo "timed out waiting for deployment ${namespace}/${deployment}" >&2
	return 1
}

kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
wait_for_deployment_rollout cert-manager cert-manager "${COMPONENT_ROLLOUT_TIMEOUT}"
wait_for_deployment_rollout cert-manager cert-manager-cainjector "${COMPONENT_ROLLOUT_TIMEOUT}"
wait_for_deployment_rollout cert-manager cert-manager-webhook "${COMPONENT_ROLLOUT_TIMEOUT}"

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
wait_for_deployment_rollout argocd argocd-applicationset-controller "${COMPONENT_ROLLOUT_TIMEOUT}"
wait_for_deployment_rollout argocd argocd-dex-server "${COMPONENT_ROLLOUT_TIMEOUT}"
wait_for_deployment_rollout argocd argocd-notifications-controller "${COMPONENT_ROLLOUT_TIMEOUT}"
wait_for_deployment_rollout argocd argocd-redis "${COMPONENT_ROLLOUT_TIMEOUT}"
wait_for_deployment_rollout argocd argocd-repo-server "${COMPONENT_ROLLOUT_TIMEOUT}"
wait_for_deployment_rollout argocd argocd-server "${COMPONENT_ROLLOUT_TIMEOUT}"

cat >/etc/agyn/components.json <<EOF
{
  "k3s": "${K3S_VERSION}",
  "certManager": "${CERT_MANAGER_VERSION}",
  "argoCd": "${ARGOCD_VERSION}",
  "helm": "${HELM_VERSION}",
  "kubectl": "${KUBECTL_VERSION}"
}
EOF
