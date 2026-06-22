# Ephemeral cloud-builder plan

The default workflow uses GitHub-hosted runners and requires KVM for publish
builds. GitHub-hosted `ubuntu-latest` currently provides usable KVM for amd64
in this repository. GitHub-hosted `ubuntu-24.04-arm` starts on an
ARM64 machine, but `/dev/kvm` was unavailable in PR validation even after
applying GitHub's documented KVM udev rule.

If GitHub does not provide a KVM-capable hosted ARM64 runner SKU for this
repository, the remaining non-self-hosted implementation path is an ephemeral
cloud builder launched by GitHub Actions:

1. Configure cloud OIDC trust for this repository and store only non-secret
   configuration as repository variables, for example image IDs, subnet IDs,
   and instance types. Do not store long-lived cloud keys.
2. Add a publish-only workflow job that starts a temporary ARM64 VM type with
   hardware virtualization/KVM.
3. Pass the GitHub run ID, target version, architecture, and a short-lived GHCR
   token to the VM over cloud-init or an instance user-data secret channel.
4. On the VM, checkout the repository at `GITHUB_SHA`, install Packer/QEMU/ORAS,
   run `scripts/build.sh arm64`, `scripts/package.sh arm64 <version>`, and
   `scripts/publish.sh arm64 <version> ghcr.io/agynio/bundle-vm-base`.
5. Stream build logs back to the workflow, upload the packaged artifact, and
   always terminate the instance in an `if: always()` cleanup step.
6. Keep the hosted-runner KVM probe in place as the preferred no-cloud path; use
   the cloud builder only when GitHub-hosted ARM64 KVM is not available.

This PR intentionally does not implement a provider-specific launcher because
no cloud provider, image, network, OIDC role, region, or instance type has been
specified for this repository. Adding one without those inputs would create
untestable CI scaffolding or require credentials not allowed by the issue.
