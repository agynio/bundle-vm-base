#!/usr/bin/env bash
set -euo pipefail

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

scripts/wait-for-k3s.sh 600

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
