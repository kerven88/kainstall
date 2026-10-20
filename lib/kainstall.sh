#!/usr/bin/env bash
# Shared, sourceable implementation. Sourcing this file never changes the host.

fail() { printf 'ERROR: %s\n' "$*" >&2; return 1; }
log() { printf '[kainstall] %s\n' "$*" >&2; }

defaults() {
  KUBE_VERSION=${KUBE_VERSION:-latest}
  MASTER_NODES=${MASTER_NODES:-}
  WORKER_NODES=${WORKER_NODES:-}
  MGMT_NODE=${MGMT_NODE:-127.0.0.1}
  KUBE_APISERVER=${KUBE_APISERVER:-}
  KUBE_POD_SUBNET=${KUBE_POD_SUBNET:-10.244.0.0/16}
  KUBE_SERVICE_SUBNET=${KUBE_SERVICE_SUBNET:-10.96.0.0/12}
  KUBE_DNSDOMAIN=${KUBE_DNSDOMAIN:-cluster.local}
  KUBE_IMAGE_REPO=${KUBE_IMAGE_REPO:-registry.k8s.io}
  KUBE_CRI=${KUBE_CRI:-containerd}
  KUBE_NETWORK=${KUBE_NETWORK:-flannel}
  CONTAINERD_VERSION=${CONTAINERD_VERSION:-2.2.7}
  RUNC_VERSION=${RUNC_VERSION:-1.4.0}
  CNI_VERSION=${CNI_VERSION:-1.9.0}
  FLANNEL_VERSION=${FLANNEL_VERSION:-0.28.6}
  KUBE_PACKAGE_BASE=${KUBE_PACKAGE_BASE:-https://pkgs.k8s.io}
  KUBE_DOWNLOAD_BASE=${KUBE_DOWNLOAD_BASE:-https://dl.k8s.io}
  GITHUB_DOWNLOAD_BASE=${GITHUB_DOWNLOAD_BASE:-https://github.com}
  SSH_USER=${SSH_USER:-root}
  SSH_PORT=${SSH_PORT:-22}
  SSH_PRIVATE_KEY=${SSH_PRIVATE_KEY:-}
  SSH_PASSWORD=${SSH_PASSWORD:-}
  CERT_YEARS=${CERT_YEARS:-1}
  BACKUP_DIR=${BACKUP_DIR:-/var/backups/etcd}
}

platform_family() {
  case "$1:$2" in
    ubuntu:22.04|ubuntu:24.04|debian:12|debian:13) printf 'apt\n' ;;
    centos:9|centos:10)
      [[ "$3" == *Stream* ]] || { fail "Unsupported OS: $1 $2 $3 (use CentOS Stream)"; return 1; }
      printf 'dnf\n' ;;
    rocky:9|rocky:9.*|rocky:10|rocky:10.*|amzn:2023) printf 'dnf\n' ;;
    *) fail "Unsupported OS: $1 $2 $3" ;;
  esac
}

platform_arch() {
  case "$1" in
    x86_64) printf 'amd64\n' ;;
    aarch64) printf 'arm64\n' ;;
    *) fail "Unsupported architecture: $1" ;;
  esac
}

version_validate() {
  local version=${1#v}
  [[ "$version" =~ ^1\.(35|36|37)\.(0|[1-9][0-9]*)$ ]] || {
    fail "Unsupported Kubernetes version: $1; expected 1.35.x, 1.36.x or 1.37.x"; return 1;
  }
  printf '%s\n' "$version"
}

version_resolve() {
  local version=$1
  if [[ "$version" == latest ]]; then
    version=$(curl -fsSL --retry 3 "${KUBE_DOWNLOAD_BASE}/release/stable.txt") || return 1
  elif [[ "$version" =~ ^v?1\.(35|36|37)$ ]]; then
    version=$(curl -fsSL --retry 3 "${KUBE_DOWNLOAD_BASE}/release/stable-${version#v}.txt") || return 1
  fi
  version_validate "$version"
}

select_package_version() {
  local version=$1 found
  found=$(awk -v prefix="$version-" 'index($1,prefix)==1 { print $1 }' | sort -V | tail -n 1)
  [[ -n "$found" ]] || { fail "Kubernetes package version $version is unavailable in the configured repository"; return 1; }
  printf '%s\n' "$found"
}

upgrade_validate() {
  local current target cm cp tm tp
  current=$(version_validate "$1") || return 1
  target=$(version_validate "$2") || return 1
  cm=${current%.*}; cm=${cm#1.}; cp=${current##*.}
  tm=${target%.*}; tm=${tm#1.}; tp=${target##*.}
  if (( tm < cm || tm > cm + 1 || (tm == cm && tp <= cp) )); then
    fail "Invalid upgrade $current -> $target: no downgrades, no skipped minors, target must be newer"; return 1
  fi
}

validate_host() {
  [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || { fail "Invalid host: $1 (IPv4 or DNS name required)"; return 1; }
}

validate_inputs() {
  local host all seen=' ' value
  [[ "$KUBE_CRI" == containerd ]] || { fail 'Only containerd is supported for modern Kubernetes'; return 1; }
  [[ "$KUBE_NETWORK" == flannel ]] || { fail 'Only flannel is currently supported; install other CNIs separately'; return 1; }
  [[ "$SSH_USER" =~ ^[a-z_][a-zA-Z0-9_-]*$ ]] || { fail 'Invalid SSH user'; return 1; }
  if [[ ! "$SSH_PORT" =~ ^[1-9][0-9]{0,4}$ ]] || (( SSH_PORT > 65535 )); then
    fail 'Invalid SSH port'; return 1
  fi
  [[ "$CERT_YEARS" == 1 || "$CERT_YEARS" == 10 ]] || { fail 'CERT_YEARS must be 1 or 10'; return 1; }
  for value in "$CONTAINERD_VERSION" "$RUNC_VERSION" "$CNI_VERSION" "$FLANNEL_VERSION"; do
    [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { fail "Invalid component version: $value"; return 1; }
  done
  [[ "$CONTAINERD_VERSION" == 2.2.* ]] || { fail 'This installer requires containerd 2.2.x'; return 1; }
  for value in "$KUBE_IMAGE_REPO" "$KUBE_DNSDOMAIN"; do
    [[ "$value" =~ ^[a-zA-Z0-9][a-zA-Z0-9./:-]*$ ]] || { fail "Invalid cluster value: $value"; return 1; }
  done
  for value in "$KUBE_POD_SUBNET" "$KUBE_SERVICE_SUBNET"; do
    [[ "$value" =~ ^[0-9.]+/[0-9]+$ ]] || { fail "Invalid IPv4 CIDR: $value"; return 1; }
  done
  for value in "$KUBE_PACKAGE_BASE" "$KUBE_DOWNLOAD_BASE" "$GITHUB_DOWNLOAD_BASE"; do
    [[ "$value" =~ ^https://[a-zA-Z0-9][a-zA-Z0-9./:_-]*$ ]] || { fail "Invalid HTTPS download base: $value"; return 1; }
  done
  if [[ -n "$KUBE_APISERVER" ]]; then
    [[ "$KUBE_APISERVER" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*:[0-9]+$ ]] || {
      fail 'API endpoint must be IPv4-or-DNS:port'; return 1;
    }
  fi
  validate_host "$MGMT_NODE" || return 1
  # Normalize separators once; do not use unquoted user input as shell commands.
  MASTER_NODES=$(printf '%s\n' "${MASTER_NODES//,/ }" | awk '{$1=$1; print}')
  WORKER_NODES=$(printf '%s\n' "${WORKER_NODES//,/ }" | awk '{$1=$1; print}')
  all="$MASTER_NODES $WORKER_NODES"
  for host in $all; do
    validate_host "$host" || return 1
    [[ "$seen" != *" $host "* ]] || { fail "Duplicate node: $host"; return 1; }
    seen="$seen$host "
  done
  command -v python3 >/dev/null || { fail 'Python 3 is required on the management host'; return 1; }
  # Host lists have been validated to contain no glob characters; split into argv.
  # shellcheck disable=SC2086
  python3 - "$KUBE_POD_SUBNET" "$KUBE_SERVICE_SUBNET" "$KUBE_APISERVER" $all <<'PY'
import ipaddress, re, sys
try:
    pod, service = (ipaddress.IPv4Network(s) for s in sys.argv[1:3])
    if pod.overlaps(service):
        raise ValueError('Pod and Service CIDRs must not overlap')
    if sys.argv[3]:
        host, port = sys.argv[3].rsplit(':', 1)
        if not 1 <= int(port) <= 65535:
            raise ValueError('API endpoint port is out of range')
    else:
        host = ''
    for name in [host] + sys.argv[4:]:
        if not name:
            continue
        if re.fullmatch(r'[0-9.]+', name):
            ipaddress.IPv4Address(name)
        elif len(name) > 253 or any(not re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?', label) for label in name.split('.')):
            raise ValueError('Invalid DNS host: ' + name)
except ValueError as error:
    raise SystemExit('ERROR: ' + str(error))
PY
  if [[ "$KUBE_VERSION" != latest && ! "$KUBE_VERSION" =~ ^v?1\.(35|36|37)$ ]]; then
    version_validate "$KUBE_VERSION" >/dev/null || return 1
  fi
}

render_init() {
  local name=$1 ip=$2
  cat <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "$ip"
nodeRegistration:
  name: "$name"
  criSocket: unix:///run/containerd/containerd.sock
  kubeletExtraArgs:
  - name: node-ip
    value: "$ip"
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v$KUBE_VERSION
controlPlaneEndpoint: "$KUBE_APISERVER"
imageRepository: "$KUBE_IMAGE_REPO"
networking:
  dnsDomain: "$KUBE_DNSDOMAIN"
  podSubnet: "$KUBE_POD_SUBNET"
  serviceSubnet: "$KUBE_SERVICE_SUBNET"
certificateValidityPeriod: $((CERT_YEARS * 8760))h
caCertificateValidityPeriod: 87600h
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
failSwapOn: true
rotateCertificates: true
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: iptables
EOF
}

render_join() {
  local role=$1 name=$2 ip=$3 token=$4 hash=$5 key=${6:-}
  cat <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: JoinConfiguration
nodeRegistration:
  name: "$name"
  criSocket: unix:///run/containerd/containerd.sock
  kubeletExtraArgs:
  - name: node-ip
    value: "$ip"
discovery:
  bootstrapToken:
    apiServerEndpoint: "$KUBE_APISERVER"
    token: "$token"
    caCertHashes:
    - sha256:$hash
timeouts:
  discovery: 5m0s
EOF
  if [[ "$role" == master ]]; then
    cat <<EOF
controlPlane:
  localAPIEndpoint:
    advertiseAddress: "$ip"
  certificateKey: "$key"
EOF
  fi
}

# Functions below are serialized to nodes via stdin. No repository checkout is
# needed on remote nodes. Both argv and configuration use Bash %q quoting.
run() {
  local host=$1; shift
  local payload key remote_command
  payload=$(
    printf 'set -Eeuo pipefail\nexport PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n'
    declare -f
    for key in KUBE_VERSION KUBE_APISERVER KUBE_POD_SUBNET KUBE_SERVICE_SUBNET KUBE_DNSDOMAIN KUBE_IMAGE_REPO \
      CONTAINERD_VERSION RUNC_VERSION CNI_VERSION FLANNEL_VERSION KUBE_PACKAGE_BASE KUBE_DOWNLOAD_BASE GITHUB_DOWNLOAD_BASE CERT_YEARS BACKUP_DIR; do
      printf '%s=%q\n' "$key" "${!key}"
    done
    printf '%q ' "$@"; printf '\n'
  )
  if [[ "$host" == 127.0.0.1 || "$host" == localhost ]]; then
    if (( EUID == 0 )); then bash -se <<< "$payload"; else sudo -n bash -se <<< "$payload"; fi
  else
    local ssh_args=(-T -p "$SSH_PORT" -o ConnectTimeout=15 -o StrictHostKeyChecking=yes)
    [[ -z "$SSH_PRIVATE_KEY" ]] || ssh_args+=(-i "$SSH_PRIVATE_KEY")
    remote_command='sudo -n bash -se'
    [[ "$SSH_USER" != root ]] || remote_command='bash -se'
    if [[ -n "$SSH_PASSWORD" ]]; then
      command -v sshpass >/dev/null || { fail 'Install sshpass on the management host for --password'; return 1; }
      SSHPASS=$SSH_PASSWORD sshpass -e ssh "${ssh_args[@]}" -o BatchMode=no "$SSH_USER@$host" "$remote_command" <<< "$payload"
    else
      ssh "${ssh_args[@]}" -o BatchMode=yes "$SSH_USER@$host" "$remote_command" <<< "$payload"
    fi
  fi
}

node_platform() {
  [[ $(uname -s) == Linux ]] || { fail 'Target must run Linux'; return 1; }
  # shellcheck disable=SC1091
  source /etc/os-release
  # NAME is supplied by os-release, rather than the local variable name.
  # shellcheck disable=SC2153
  platform_family "$ID" "$VERSION_ID" "$NAME"
}

node_preflight() {
  local mode=$1
  (( EUID == 0 )) || { fail 'Root or passwordless sudo is required on every node'; return 1; }
  node_platform >/dev/null
  platform_arch "$(uname -m)" >/dev/null
  [[ -d /run/systemd/system && -f /sys/fs/cgroup/cgroup.controllers ]] || {
    fail 'systemd and cgroup v2 are required'; return 1;
  }
  if command -v getenforce >/dev/null && [[ $(getenforce) == Enforcing ]]; then
    fail 'SELinux must be permissive/disabled before installing upstream containerd binaries'; return 1
  fi
  if [[ "$mode" == fresh ]]; then
    [[ ! -f /etc/kubernetes/kubelet.conf && ! -f /etc/kubernetes/admin.conf ]] || {
      fail 'Node already belongs to a cluster; refusing to overwrite it'; return 1;
    }
    if command -v containerd >/dev/null || command -v dockerd >/dev/null; then
      fail 'Fresh nodes must not have a pre-existing container runtime'; return 1
    fi
  elif [[ "$mode" == upgrade ]]; then
    [[ -f /etc/kubernetes/kubelet.conf ]] || { fail 'Node is not a cluster member'; return 1; }
    local runtime_version
    runtime_version=$(containerd --version)
    [[ "$runtime_version" =~ [[:space:]]v?2\.2\. ]] || { fail 'Upgrade requires an existing containerd 2.2.x runtime'; return 1; }
  fi
}

node_identity() {
  local name ip
  name=$(hostname -s | tr '[:upper:]' '[:lower:]')
  ip=$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
  [[ "$name" =~ ^[a-z0-9][a-z0-9.-]*$ && "$ip" =~ ^[0-9.]+$ ]] || { fail 'Cannot determine node hostname/IPv4 address'; return 1; }
  printf '%s %s\n' "$name" "$ip"
}

node_dependencies() {
  local family
  family=$(node_platform)
  if [[ "$family" == apt ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update </dev/null
    apt-get install -y ca-certificates curl gpg tar gzip conntrack iptables iproute2 socat ethtool openssl python3 chrony </dev/null
    systemctl enable --now chrony
  else
    command -v curl >/dev/null || dnf install -y curl </dev/null
    dnf install -y ca-certificates tar gzip conntrack-tools iptables iproute socat ethtool openssl python3 chrony </dev/null
    systemctl enable --now chronyd
  fi
}

node_prepare() {
  node_dependencies
  swapoff -a
  # Keep the original fstab and disable only active swap entries.
  [[ -f /etc/fstab.kainstall.bak ]] || cp -p /etc/fstab /etc/fstab.kainstall.bak
  sed -i '/^[^#].*[[:space:]]swap[[:space:]]/s/^/# kainstall: /' /etc/fstab
  # systemd-generated zram swap needs explicit removal by the operator.
  if systemctl list-unit-files 'systemd-zram-setup@*' --no-legend | grep -q enabled; then
    fail 'Disable the systemd zram generator before installing Kubernetes'; return 1
  fi
  mkdir -p /etc/modules-load.d /etc/sysctl.d /opt/cni/bin /etc/cni/net.d
  printf 'overlay\nbr_netfilter\n' > /etc/modules-load.d/kainstall.conf
  modprobe overlay
  modprobe br_netfilter
  cat > /etc/sysctl.d/99-kainstall.conf <<'EOF'
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
  sysctl -p /etc/sysctl.d/99-kainstall.conf
}

fetch() { curl --fail --location --silent --show-error --retry 3 --connect-timeout 20 --max-time 600 "$1" -o "$2"; }

verify_checksum() {
  local file=$1 checksum=$2 expected
  expected=$(awk 'NR==1 { print $1 }' "$checksum")
  [[ "$expected" =~ ^[a-fA-F0-9]{64}$ ]] || { fail "Invalid SHA256 for $file"; return 1; }
  printf '%s  %s\n' "$expected" "$file" | sha256sum -c -
}

render_runtime() {
  cat <<EOF
# Managed by kainstall. containerd 2.2 config format.
version = 3
[plugins.'io.containerd.cri.v1.images'.pinned_images]
  sandbox = '$1'
[plugins.'io.containerd.cri.v1.runtime'.containerd]
  default_runtime_name = 'runc'
[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc]
  runtime_type = 'io.containerd.runc.v2'
[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]
  SystemdCgroup = true
EOF
}

update_pause_config() {
  python3 - "$1" "$2" <<'PY'
import os, pathlib, re, stat, sys, tempfile
path = pathlib.Path(sys.argv[1])
text = path.read_text()
section = r"(\[plugins\.'io\.containerd\.cri\.v1\.images'\.pinned_images\]\s*\n)([^\[]*)"
count = 0
def update(match):
    global count
    body, count = re.subn(r"(?m)^\s*sandbox\s*=.*$", "  sandbox = '" + sys.argv[2] + "'", match[2])
    return match[1] + body
changed, sections = re.subn(section, update, text)
if sections != 1 or count != 1:
    raise SystemExit('Unsupported containerd config layout; refusing to overwrite it')
with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, delete=False) as tmp:
    tmp.write(changed)
    temporary = tmp.name
try:
    os.chmod(temporary, stat.S_IMODE(path.stat().st_mode))
    os.replace(temporary, path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
}

node_pause_image() {
  local pause
  pause=$(kubeadm config images list --kubernetes-version "v$KUBE_VERSION" --image-repository "$KUBE_IMAGE_REPO" | awk '/\/pause:/ {print; exit}')
  [[ -n "$pause" ]] || { fail 'Cannot resolve Kubernetes pause image'; return 1; }
  printf '%s\n' "$pause"
}

node_wait_cri() {
  local attempt
  for ((attempt=0; attempt<60; attempt++)); do
    if crictl info >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  fail 'containerd CRI did not become ready within the startup timeout'
}

node_install_runtime() (
  local arch tmp asset base pause
  arch=$(platform_arch "$(uname -m)")
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  # Static builds also support RHEL-family glibc 2.34.
  asset="containerd-static-${CONTAINERD_VERSION}-linux-${arch}.tar.gz"
  base="${GITHUB_DOWNLOAD_BASE}/containerd/containerd/releases/download/v${CONTAINERD_VERSION}"
  fetch "$base/$asset" "$tmp/$asset"
  fetch "$base/$asset.sha256sum" "$tmp/containerd.sha256"
  verify_checksum "$tmp/$asset" "$tmp/containerd.sha256"
  tar -xzf "$tmp/$asset" -C /usr/local

  base="${GITHUB_DOWNLOAD_BASE}/opencontainers/runc/releases/download/v${RUNC_VERSION}"
  fetch "$base/runc.$arch" "$tmp/runc.$arch"
  fetch "$base/runc.sha256sum" "$tmp/runc.sha256sum"
  awk -v name="runc.$arch" '{f=$2; sub(/^\*/,"",f); if(f==name) print $1}' "$tmp/runc.sha256sum" > "$tmp/runc.sha256"
  verify_checksum "$tmp/runc.$arch" "$tmp/runc.sha256"
  install -m 0755 "$tmp/runc.$arch" /usr/local/sbin/runc

  asset="cni-plugins-linux-${arch}-v${CNI_VERSION}.tgz"
  base="${GITHUB_DOWNLOAD_BASE}/containernetworking/plugins/releases/download/v${CNI_VERSION}"
  fetch "$base/$asset" "$tmp/$asset"
  fetch "$base/$asset.sha256" "$tmp/cni.sha256"
  verify_checksum "$tmp/$asset" "$tmp/cni.sha256"
  tar -xzf "$tmp/$asset" -C /opt/cni/bin

  # Use the pause version selected by this exact kubeadm release.
  pause=$(node_pause_image)
  mkdir -p /etc/containerd
  render_runtime "$pause" > /etc/containerd/config.toml
  cat > /etc/systemd/system/containerd.service <<'EOF'
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target local-fs.target
[Service]
Type=notify
TimeoutStartSec=120
ExecStart=/usr/local/bin/containerd
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Delegate=yes
KillMode=process
Restart=always
RestartSec=5
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
OOMScoreAdjust=-999
[Install]
WantedBy=multi-user.target
EOF
  cat > /etc/crictl.yaml <<'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
EOF
  systemctl daemon-reload
  systemctl enable --now containerd
  node_wait_cri
)

node_repo() {
  local family minor tmp
  family=$(node_platform)
  minor=${KUBE_VERSION%.*}
  if [[ "$family" == apt ]]; then
    mkdir -p /etc/apt/keyrings
    tmp=$(mktemp)
    fetch "${KUBE_PACKAGE_BASE}/core:/stable:/v${minor}/deb/Release.key" "$tmp"
    gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg "$tmp"
    rm -f "$tmp"
    chmod 0644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    printf 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] %s/core:/stable:/v%s/deb/ /\n' \
      "$KUBE_PACKAGE_BASE" "$minor" > /etc/apt/sources.list.d/kubernetes.list
    apt-get update </dev/null
  else
    cat > /etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes v$minor
baseurl=${KUBE_PACKAGE_BASE}/core:/stable:/v${minor}/rpm/
enabled=1
gpgcheck=1
gpgkey=${KUBE_PACKAGE_BASE}/core:/stable:/v${minor}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
    dnf --disablerepo='*' --enablerepo=kubernetes makecache </dev/null
  fi
}

node_packages() {
  local family package revision
  family=$(node_platform)
  for package in "$@"; do
    if [[ "$family" == apt ]]; then
      revision=$(apt-cache madison "$package" | awk '{print $3}' | select_package_version "$KUBE_VERSION")
      apt-get install -y --allow-change-held-packages "$package=$revision" </dev/null
      apt-mark hold "$package"
    else
      revision=$(dnf -q --disableexcludes=kubernetes --showduplicates list "$package" | awk '$1 ~ /^'"$package"'\./ {sub(/^[0-9]+:/,"",$2); print $2}' | select_package_version "$KUBE_VERSION")
      dnf install -y --disableexcludes=kubernetes "$package-$revision" </dev/null
    fi
  done
}

node_install() {
  node_prepare
  node_repo
  node_packages kubeadm kubelet kubectl
  node_install_runtime
  systemctl enable kubelet
}

node_kube() { KUBECONFIG=/etc/kubernetes/admin.conf kubectl "$@"; }

node_write_config() {
  mkdir -p /etc/kubernetes
  umask 077
  printf '%s\n' "$1" > /etc/kubernetes/kainstall.yaml
  kubeadm config validate --config /etc/kubernetes/kainstall.yaml
}

node_init() {
  node_write_config "$1"
  kubeadm init --config /etc/kubernetes/kainstall.yaml --upload-certs
  node_flannel
}

node_join() (
  trap 'rm -f /etc/kubernetes/kainstall.yaml' EXIT
  node_write_config "$1"
  kubeadm join --config /etc/kubernetes/kainstall.yaml
)

node_flannel() (
  local tmp
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  fetch "${GITHUB_DOWNLOAD_BASE}/flannel-io/flannel/releases/download/v${FLANNEL_VERSION}/kube-flannel.yml" "$tmp/flannel.yaml"
  # Change only the network in the ConfigMap; do not replace image tags or URLs.
  python3 - "$tmp/flannel.yaml" "$KUBE_POD_SUBNET" <<'PY'
import ipaddress, pathlib, re, sys
path = pathlib.Path(sys.argv[1])
network = str(ipaddress.IPv4Network(sys.argv[2]))
text, count = re.subn(r'("Network"\s*:\s*")[^"]+("[ ,]*)',
                      lambda m: m[1] + network + m[2], path.read_text())
if count != 1:
    raise SystemExit('Expected exactly one Flannel network setting')
path.write_text(text)
PY
  node_kube apply -f "$tmp/flannel.yaml"
)

node_credentials() {
  local token hash key=''
  token=$(kubeadm token create --ttl 30m)
  hash=$(openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl pkey -pubin -outform DER | openssl dgst -sha256 -hex | awk '{print $NF}')
  if [[ "$1" == master ]]; then
    key=$(kubeadm init phase upload-certs --upload-certs | tail -n 1)
    [[ "$key" =~ ^[a-f0-9]{64}$ ]] || { fail 'Invalid certificate upload key'; return 1; }
  fi
  [[ "$token" =~ ^[a-z0-9]{6}\.[a-z0-9]{16}$ && "$hash" =~ ^[a-f0-9]{64}$ ]] || { fail 'Invalid bootstrap credentials'; return 1; }
  printf '%s %s %s\n' "$token" "$hash" "$key"
}

node_context() {
  local config
  node_kube get --raw=/version | python3 -c 'import json,sys; print(json.load(sys.stdin)["gitVersion"])'
  config=$(node_kube -n kube-system get cm kubeadm-config -o 'jsonpath={.data.ClusterConfiguration}')
  awk '/^controlPlaneEndpoint:/ {gsub(/"/,"",$2); print $2}' <<< "$config"
  awk '/^imageRepository:/ {gsub(/"/,"",$2); print $2}' <<< "$config"
}

node_inventory() {
  node_kube get nodes -o json | python3 -c '
import json,sys
for node in json.load(sys.stdin)["items"]:
    labels=node["metadata"]["labels"]
    role="master" if "node-role.kubernetes.io/control-plane" in labels else "worker"
    ips=[a["address"] for a in node["status"]["addresses"] if a["type"]=="InternalIP"]
    print(node["metadata"]["name"],role,ips[0],node["status"]["nodeInfo"]["kubeletVersion"])
'
}

node_upgrade() {
  local role=$1
  node_repo
  node_packages kubeadm
  # New Kubernetes minors can change the sandbox image. Keep runtime and
  # kubeadm in sync without replacing other runtime settings or binaries.
  update_pause_config /etc/containerd/config.toml "$(node_pause_image)"
  systemctl restart containerd
  node_wait_cri
  if [[ "$role" == first ]]; then
    kubeadm upgrade apply "v$KUBE_VERSION" -y
  else
    kubeadm upgrade node
  fi
  node_packages kubelet kubectl
  systemctl daemon-reload
  systemctl restart kubelet
}

node_reset() {
  kubeadm reset -f --cri-socket unix:///run/containerd/containerd.sock
  # kubeadm reset leaves network configuration behind; remove managed Flannel state.
  rm -f /etc/cni/net.d/10-flannel.conflist /etc/kubernetes/kainstall.yaml
  ip link show cni0 >/dev/null 2>&1 && ip link delete cni0 || true
  ip link show flannel.1 >/dev/null 2>&1 && ip link delete flannel.1 || true
}

node_renew() (
  local name config
  config=$(mktemp)
  trap 'rm -f "$config"' EXIT
  chmod 0600 "$config"
  node_kube -n kube-system get cm kubeadm-config -o 'jsonpath={.data.ClusterConfiguration}' > "$config"
  kubeadm certs renew all --config "$config"
  # Stop each static pod sandbox separately; kubelet recreates it with renewed certs.
  for name in etcd kube-apiserver kube-controller-manager kube-scheduler; do
    local ids id
    ids=$(crictl pods --name "$name" -q)
    while IFS= read -r id; do
      [[ -z "$id" ]] || crictl stopp "$id"
    done <<< "$ids"
  done
  kubeadm certs check-expiration
)

node_wait_api() {
  local attempt
  for ((attempt=0; attempt<60; attempt++)); do
    if node_kube --request-timeout=5s get --raw=/readyz >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  fail 'API server did not become ready after restarting static pods'
}

node_wait_version() {
  local name=$1 attempt version
  for ((attempt=0; attempt<60; attempt++)); do
    version=$(node_kube --request-timeout=5s get node "$name" -o 'jsonpath={.status.nodeInfo.kubeletVersion}') || version=''
    if [[ "$version" == "v$KUBE_VERSION" ]]; then return 0; fi
    sleep 2
  done
  fail "Node $name did not report kubelet v$KUBE_VERSION"
}

node_backup() {
  local pod path
  mkdir -p "$BACKUP_DIR"
  chmod 0700 "$BACKUP_DIR"
  pod=$(node_kube -n kube-system get pods -l component=etcd --field-selector "spec.nodeName=$(hostname -s | tr '[:upper:]' '[:lower:]')" -o 'jsonpath={.items[0].metadata.name}')
  [[ -n "$pod" ]] || { fail 'No local etcd pod found'; return 1; }
  path="/var/lib/etcd/kainstall-snapshot-$(date -u +%Y%m%dT%H%M%SZ).db"
  node_kube -n kube-system exec "$pod" -- etcdctl --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
    --key=/etc/kubernetes/pki/etcd/healthcheck-client.key snapshot save "$path"
  # The pod's /var/lib/etcd is a hostPath; avoid requiring tar inside the etcd image.
  install -m 0600 "$path" "$BACKUP_DIR/${path##*/}"
  rm -f "$path"
  printf 'Snapshot saved: %s/%s\n' "$BACKUP_DIR" "${path##*/}"
}
