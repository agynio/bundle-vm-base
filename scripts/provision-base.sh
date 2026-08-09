#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

print_cloud_init_debug() {
	if ! command -v cloud-init >/dev/null 2>&1; then
		return 0
	fi

	{
		echo "[provision-base] cloud-init status --long:"
		cloud-init status --long || true
		if [ -f /var/log/cloud-init-output.log ]; then
			echo "[provision-base] tail /var/log/cloud-init-output.log:"
			tail -n 120 /var/log/cloud-init-output.log || true
		fi
		if [ -f /var/log/cloud-init.log ]; then
			echo "[provision-base] tail /var/log/cloud-init.log:"
			tail -n 120 /var/log/cloud-init.log || true
		fi
	} >&2
}

print_failure_debug() {
	status="${1}"
	line="${2}"
	command="${3}"

	{
		echo "[provision-base] failed with status ${status} at line ${line}: ${command}"
		echo "[provision-base] architecture: ${ARCH:-unset}"
		echo "[provision-base] versions: k3s=${K3S_VERSION:-unset} cert-manager=${CERT_MANAGER_VERSION:-unset} helm=${HELM_VERSION:-unset} kubectl=${KUBECTL_VERSION:-unset}"
	} >&2

	print_cloud_init_debug
}

trap 'status="${?}"; line="${LINENO}"; command="${BASH_COMMAND}"; trap - ERR; print_failure_debug "${status}" "${line}" "${command}"' ERR

wait_for_cloud_init() {
	if command -v cloud-init >/dev/null 2>&1; then
		set +e
		cloud_init_status_output="$(cloud-init status --wait 2>&1)"
		cloud_init_status="${?}"
		set -e

		printf '%s\n' "${cloud_init_status_output}"

		if [ "${cloud_init_status}" -eq 0 ]; then
			return 0
		fi

		set +e
		cloud_init_long_output="$(cloud-init status --long 2>&1)"
		set -e
		printf '%s\n' "${cloud_init_long_output}" >&2

		if printf '%s\n%s\n' "${cloud_init_status_output}" "${cloud_init_long_output}" | grep -Fxq 'status: done'; then
			echo "[provision-base] cloud-init reported status: done with exit status ${cloud_init_status}; continuing after printing diagnostics" >&2
			print_cloud_init_debug
			return 0
		fi

		echo "[provision-base] cloud-init did not complete successfully; exit status ${cloud_init_status}" >&2
		return "${cloud_init_status}"
	fi
}

wait_for_apt() {
	while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1; do
		echo "waiting for apt/dpkg locks to be released"
		sleep 5
	done
}

wait_for_cloud_init
wait_for_apt
apt-get update
wait_for_apt
# Runtime + bake essentials only. Debug tooling (git, vim, htop, tcpdump,
# traceroute, rsync, wget, unzip, bash-completion) is intentionally omitted —
# nothing in the runtime uses it and it is one `apt install` away when needed.
apt-get install -y --no-install-recommends \
	apt-transport-https \
	ca-certificates \
	cloud-init \
	conntrack \
	curl \
	dnsutils \
	iproute2 \
	iptables \
	jq \
	less \
	netcat-openbsd \
	nfs-common \
	open-iscsi \
	openssh-server \
	qemu-guest-agent \
	socat \
	tar \
	xz-utils

systemctl enable qemu-guest-agent
systemctl enable iscsid

install -d -m 0755 /usr/local/bin /etc/agyn /etc/rancher/k3s

# Every devspace container watches its synced tree as uid 1000, so they share
# one 128-instance budget and the sync dies once enough services run.
cat >/etc/sysctl.d/99-inotify.conf <<'EOF'
fs.inotify.max_user_instances=1024
EOF

curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" -o /tmp/helm.tar.gz
tar -C /tmp -xzf /tmp/helm.tar.gz
install -m 0755 "/tmp/linux-${ARCH}/helm" /usr/local/bin/helm

curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" -o /usr/local/bin/kubectl
chmod 0755 /usr/local/bin/kubectl

cat >/etc/agyn/base-image.env <<EOF
ARCH=${ARCH}
K3S_VERSION=${K3S_VERSION}
CERT_MANAGER_VERSION=${CERT_MANAGER_VERSION}
HELM_VERSION=${HELM_VERSION}
KUBECTL_VERSION=${KUBECTL_VERSION}
EOF
