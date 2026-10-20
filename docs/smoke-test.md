# Disposable Linux VM smoke tests

These tests change the target machines. Use fresh disposable VMs, never production
nodes. The local macOS behavioral suite does not run these steps.

## Matrix and prerequisites

Run the following workflow separately for Ubuntu 22.04/24.04, Debian 12/13,
CentOS Stream 9/10, Rocky 9/10 and Amazon Linux 2023; repeat on amd64 and arm64
where images are available. Test Kubernetes 1.35, 1.36 and 1.37.

Provision a control plane (2 CPU, 4 GiB) and a worker (2 CPU, 4 GiB), systemd and
cgroup v2, unique hostnames and stable IPv4s, no preinstalled runtime. Configure SSH
trust and passwordless sudo. Configure SELinux prerequisites and network ports as
in README. Capture OS release, architecture, exact component versions and command
logs. For HA use three control planes and a separate TCP load balancer.

## Install and exercise the network

```bash
bash kainstall.sh check --master "$CP_IP" --worker "$WORKER_IP" --user "$SSH_USER"
bash kainstall.sh init --master "$CP_IP" --worker "$WORKER_IP" --user "$SSH_USER" --version 1.35
# The rest of the kubectl commands run on CP_IP as root with this environment:
export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl wait --for=condition=Ready nodes --all --timeout=300s
kubectl -n kube-flannel rollout status daemonset/kube-flannel-ds --timeout=300s
kubectl -n kube-system rollout status deployment/coredns --timeout=300s
kubectl create deployment web --image=nginx:stable-alpine --replicas=2
kubectl expose deployment web --port=80
kubectl rollout status deployment/web --timeout=180s
kubectl run network-test --image=busybox:1.37 --restart=Never --command -- \
  sh -ec 'nslookup kubernetes.default.svc.cluster.local; wget -qO- http://web.default.svc.cluster.local'
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/network-test --timeout=180s
kubectl logs network-test
```

Confirm both pod IP connectivity and Service/DNS connectivity. For a meaningful
cross-node check, add a second worker and pin the client and server to different
workers with nodeSelector; verify success in both directions. For a mixed-OS
cluster, repeat by adding a worker of each supported OS to the same cluster.

## Lifecycle and reboot

1. Add a fresh worker using `add --mgmt-node`, verify Ready and cross-node traffic.
2. Save etcd snapshot using `backup-etcd`; verify nonempty file and
   `etcdutl snapshot status` using the matching etcd release (install it separately).
3. Upgrade the complete node inventory 1.35 → 1.36 → 1.37. Recheck DNS, Service and
   pod connectivity after each step. Try an incomplete inventory and a skipped
   minor; confirm no node was drained or modified.
4. Exercise a PDB that blocks drain; confirm the upgrade stops without uncordoning
   the blocked node. Resolve the PDB and resume the same target version.
5. Renew all control-plane certificates, check expiry, API readiness and workloads.
6. Reboot each node, confirm swap remains off, chrony/containerd/kubelet start,
   all nodes recover Ready, and cross-node traffic works.
7. Delete the added worker using `del`, confirm it is absent from the cluster.
8. In HA tests, add/remove a control plane, update load-balancer backends, and test
   API access with one control plane stopped. Do not destroy etcd quorum.
9. Use `reset` only for teardown. Destroy the disposable VMs afterwards.

Record pass/fail per OS, architecture, Kubernetes patch version and scenario.
Do not report the entire support matrix as verified from only schema or unit tests.
