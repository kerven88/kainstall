# Modern Kubernetes Implementation Plan

> Execute sequentially in the requested checkout. User authorized repair of this repository.

**Goal:** Modern kubeadm installation and lifecycle commands across five OS families.
**Architecture:** Shared sourceable Bash core, one CLI, thin legacy/OS entry points.
**Tech Stack:** Bash, apt/dnf, official Kubernetes repositories, containerd, Python unittest.
**Spec:** docs/superpowers/specs/2026-10-20-modern-kubernetes-design.md

## Global Constraints
- Kubernetes 1.35–1.37; reject unsupported versions before host changes.
- Ubuntu 22.04/24.04, Debian 12/13, CentOS Stream 9/10, Rocky 9/10, Amazon Linux 2023.
- Preserve failures and secrets, use verified downloads, keep firewall configuration intact.

## Review Focus
- Unsupported distro/old Kubernetes must fail before package installation.
- Minor-specific repositories and exact apt/rpm versions must resolve without old -00 assumptions.
- Join config must include discovery trust and control-plane certificate key only when needed.
- Incomplete upgrade inventory, downgrades and skipped minors must fail before drain.
- SSH/sudo and package failures must stop orchestration; no success output on failure.

### Task 1: Core contracts and platform routing
- [x] Write failing unittest tests for distro matrix, versions, package resolution, CLI validation.
- [x] Implement sourceable lib/kainstall.sh and kainstall.sh entry, run tests.

### Task 2: Node preparation and kubeadm lifecycle
- [x] Write failing tests for kubeadm v1beta4 renderers and lifecycle ordering/failures.
- [x] Implement preparation, checksum downloads, containerd and native packages.
- [x] Implement init/add/del/reset/upgrade/renew-cert/backup-etcd orchestration.
- [x] Run all behavioral tests and shell syntax checks.

### Task 3: Entrypoints, documentation and CI
- [x] Replace duplicated OS scripts with shared-core launchers; add Rocky/Amazon Linux.
- [x] Document exact support targets, migration, HA/network prerequisites and VM smoke test.
- [x] Add CI for tests and shell lint; review diff and record validation limits.

## Execution record
- Existing checkout was clean, no existing test suite beyond lint CI.
- Local Docker daemon is unavailable; Linux VM smoke tests cannot run locally.
- Proceed in place without commits/pushes; the reviewable deliverable is the working-tree diff.

## Verification outcome
- `python3 -m unittest discover -s tests -v`: 27 tests passed.
- `bash -n` for every entry point, library and shell test: passed.
- ShellCheck 0.11.0 for every Bash file: passed.
- Workflow YAML parsed successfully; `git diff --check`: passed.
- Independent code review found a containerd startup race; corrected with notify
  service type and bounded CRI readiness polling, with delay/timeout regression tests.
- kubeadm 1.35/1.36/1.37 schema jobs are configured but not executed locally.
- No real Linux install, HA, reboot, network or upgrade smoke tests were performed.
  The OS matrix remains an implementation target pending disposable VM validation.
