# Modern Kubernetes support

User requirement: repair this repository for recent Kubernetes on mainstream Ubuntu,
Debian, CentOS, Rocky and Amazon Linux.

Implementation decisions: one shared Bash core with compatible OS entry points;
Ubuntu 22.04/24.04, Debian 12/13, CentOS Stream 9/10, Rocky 9/10, Amazon Linux 2023;
x86_64 and aarch64. Kubernetes 1.35–1.37 only, resolved once to an exact patch.
Use official minor-specific package repositories, containerd 2.x with systemd
cgroups, upstream runc/CNI binaries with checksum verification and Flannel.
Keep init, add, del, reset, upgrade and renew-cert commands. Multiple control planes
require an explicit preconfigured TCP load balancer. Preserve SSH authentication
and passwordless sudo, fail before mutation for unsupported legacy options.

Do not silently install old optional plugins or consume the old Docker-only offline
archives. Explain this migration in README. Do not disable host firewalls or erase
iptables. Require SELinux permissive/disabled for this upstream binary runtime
installation and explain the prerequisite instead of silently changing policy.
Fresh nodes only for init/add. Upgrade one minor at a time, refuse downgrades,
verify complete node inventory before upgrade, drain and uncordon in sequence.
Renew on each control plane and restart static pods. Keep etcd backup as an explicit
command using the running etcd pod and certificate paths, not old CronJob manifests.

Verification: behavioral unit tests of distro routing, version/package selection,
rendered YAML, command ordering, argument validation and failure propagation.
Optional real kubeadm schema validation and disposable Linux VM smoke instructions.
Local tests are not proof of a working multi-OS cluster; report VM limitations.
