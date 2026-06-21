#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
	apt-transport-https \
	bash-completion \
	ca-certificates \
	cloud-init \
	conntrack \
	curl \
	dnsutils \
	git \
	gnupg \
	htop \
	iproute2 \
	iptables \
	jq \
	less \
	netcat-openbsd \
	nfs-common \
	open-iscsi \
	openssh-server \
	qemu-guest-agent \
	rsync \
	socat \
	tar \
	tcpdump \
	traceroute \
	unzip \
	vim \
	wget \
	xz-utils

systemctl enable qemu-guest-agent
systemctl enable iscsid

install -d -m 0755 /usr/local/bin /etc/agyn /etc/rancher/k3s

curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" -o /tmp/helm.tar.gz
tar -C /tmp -xzf /tmp/helm.tar.gz
install -m 0755 "/tmp/linux-${ARCH}/helm" /usr/local/bin/helm

curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" -o /usr/local/bin/kubectl
chmod 0755 /usr/local/bin/kubectl

cat >/etc/agyn/base-image.env <<EOF
ARCH=${ARCH}
K3S_VERSION=${K3S_VERSION}
CERT_MANAGER_VERSION=${CERT_MANAGER_VERSION}
ARGOCD_VERSION=${ARGOCD_VERSION}
HELM_VERSION=${HELM_VERSION}
KUBECTL_VERSION=${KUBECTL_VERSION}
EOF
