#!/usr/bin/env bash
set -euo pipefail

if command -v packer >/dev/null 2>&1; then
	packer init packer
	packer fmt -check packer
	(
		cd packer
		packer validate \
			-var arch=amd64 \
			-var k3s_version=v0.0.0 \
			-var cert_manager_version=v0.0.0 \
			-var argocd_version=v0.0.0 \
			-var helm_version=v0.0.0 \
			-var kubectl_version=v0.0.0 \
			.
		packer validate \
			-var arch=arm64 \
			-var k3s_version=v0.0.0 \
			-var cert_manager_version=v0.0.0 \
			-var argocd_version=v0.0.0 \
			-var helm_version=v0.0.0 \
			-var kubectl_version=v0.0.0 \
			.
	)
fi

if command -v shellcheck >/dev/null 2>&1; then
	shellcheck -x scripts/*.sh
fi

if command -v yamllint >/dev/null 2>&1; then
	yamllint .github/workflows examples docs
fi

if command -v jq >/dev/null 2>&1 && [ -d artifacts ]; then
	find artifacts -name metadata.json -print0 | xargs -0 -r -n1 jq empty
fi
