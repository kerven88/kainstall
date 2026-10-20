#!/usr/bin/env bash
# CLI assignments are consumed by lib/kainstall.sh in the same shell.
# shellcheck disable=SC2034

usage() {
  cat <<'EOF'
kainstall: kubeadm Kubernetes 1.35–1.37 installer

OS: Ubuntu 22.04/24.04; Debian 12/13; CentOS Stream 9/10;
    Rocky Linux 9/10; Amazon Linux 2023 (amd64/arm64, systemd, cgroup v2).

Usage: bash kainstall.sh COMMAND [OPTIONS]
Commands:
  init           Install a new cluster on fresh nodes
  add            Add fresh nodes to an existing cluster
  del            Drain, reset and delete one node
  reset          Run kubeadm reset on explicitly listed nodes
  upgrade        Upgrade a complete node inventory, one minor at a time
  renew-cert     Renew certificates on listed control-plane nodes
  backup-etcd    Save local etcd snapshot on --mgmt-node
  check          Read-only OS/runtime prerequisite checks on listed nodes
  render-config  Print init YAML without changing nodes (exact --version)

Options:
  -m, --master IP[,IP...]     Control-plane nodes (init defaults to localhost)
  -w, --worker IP[,IP...]     Worker nodes
      --mgmt-node HOST       Existing control-plane SSH host (add/del/backup)
      --apiserver HOST:PORT  Stable API endpoint; required for multiple masters
  -v, --version VERSION      Exact version, minor (1.35), or latest
  -u, --user USER            SSH user (default root); non-root uses sudo -n
  -p, --password PASSWORD    SSH password (requires local sshpass; prefer keys)
  -P, --port PORT            SSH port (default 22)
      --private-key PATH    SSH private key; known_hosts must trust every node
      --cri containerd      Only supported runtime
  -n, --network flannel      Only bundled CNI
      --10years             Official kubeadm 10-year non-CA certificate duration
      --sudo                Use passwordless sudo (automatic for non-root SSH)
  -h, --help                Show help

Multi-control-plane clusters require a preconfigured TCP load balancer.
Legacy offline archives and bundled ingress/UI/storage/monitoring are unsupported.
Clone the entire repository: OS entry points load the shared lib/ directory.
EOF
}

parse_args() {
  COMMAND=${1:---help}
  [[ $# == 0 ]] || shift
  case "$COMMAND" in
    -h|--help|help) usage; return 2 ;;
    init|add|del|reset|upgrade|renew-cert|backup-etcd|check|render-config) ;;
    *) fail "Unknown command: $COMMAND"; return 1 ;;
  esac
  while (( $# )); do
    case "$1" in
      -h|--help) usage; return 2 ;;
      --10years) CERT_YEARS=10; shift; continue ;;
      --sudo) shift; continue ;;
      -m|--master|-w|--worker|--mgmt-node|--apiserver|-v|--version|-u|--user|-p|--password|-P|--port|--private-key|--cri|-n|--network)
        (( $# >= 2 )) && [[ -n "$2" && "$2" != --* ]] || { fail "Missing value for $1"; return 1; }
        case "$1" in
          -m|--master) MASTER_NODES=$2 ;;
          -w|--worker) WORKER_NODES=$2 ;;
          --mgmt-node) MGMT_NODE=$2 ;;
          --apiserver) KUBE_APISERVER=$2 ;;
          -v|--version) KUBE_VERSION=$2 ;;
          -u|--user) SSH_USER=$2 ;;
          -p|--password) SSH_PASSWORD=$2 ;;
          -P|--port) SSH_PORT=$2 ;;
          --private-key) SSH_PRIVATE_KEY=$2 ;;
          --cri) KUBE_CRI=$2 ;;
          -n|--network) KUBE_NETWORK=$2 ;;
        esac
        shift 2 ;;
      *) fail "Unsupported option: $1; see --help. Legacy addons/offline packages require separate migration."; return 1 ;;
    esac
  done
}

# Arrays are populated in the controller only; remote functions use explicit args.
collect_nodes() {
  local mode=$1 host role identity name ip names=' '
  NODE_HOSTS=(); NODE_ROLES=(); NODE_NAMES=(); NODE_IPS=()
  for role in master worker; do
    local hosts=$MASTER_NODES
    [[ "$role" != worker ]] || hosts=$WORKER_NODES
    for host in $hosts; do
      log "Checking $host ($role)"
      run "$host" node_preflight "$mode"
      identity=$(run "$host" node_identity)
      read -r name ip <<< "$identity"
      [[ "$name" =~ ^[a-z0-9][a-z0-9.-]*$ && "$ip" =~ ^[0-9.]+$ ]] || { fail "Invalid node identity: $host"; return 1; }
      [[ "$names" != *" $name "* ]] || { fail "Duplicate node hostname: $name"; return 1; }
      names="$names$name "
      NODE_HOSTS+=("$host"); NODE_ROLES+=("$role"); NODE_NAMES+=("$name"); NODE_IPS+=("$ip")
    done
  done
}

read_context() {
  local context
  context=$(run "$MGMT_NODE" node_context)
  CLUSTER_VERSION=$(version_validate "${context%%$'\n'*}")
  local endpoint=${context#*$'\n'} repository
  endpoint=${endpoint%%$'\n'*}
  [[ "$endpoint" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*:[0-9]+$ ]] || { fail 'Cluster has no valid stable controlPlaneEndpoint'; return 1; }
  if [[ -n "$KUBE_APISERVER" && "$KUBE_APISERVER" != "$endpoint" ]]; then
    fail "Specified endpoint differs from cluster endpoint $endpoint"; return 1
  fi
  KUBE_APISERVER=$endpoint
  repository=$(printf '%s\n' "$context" | sed -n '3p')
  if [[ -n "$repository" ]]; then
    [[ "$repository" =~ ^[a-zA-Z0-9][a-zA-Z0-9./:-]*$ ]] || { fail 'Invalid cluster imageRepository'; return 1; }
    KUBE_IMAGE_REPO=$repository
  fi
}

join_node() {
  local index=$1 credentials token hash key config
  credentials=$(run "$MGMT_NODE" node_credentials "${NODE_ROLES[$index]}")
  read -r token hash key <<< "$credentials"
  config=$(render_join "${NODE_ROLES[$index]}" "${NODE_NAMES[$index]}" "${NODE_IPS[$index]}" "$token" "$hash" "${key:-}")
  run "${NODE_HOSTS[$index]}" node_join "$config"
}

init_cluster() {
  local i config
  MGMT_NODE=${MASTER_NODES%% *}
  KUBE_VERSION=$(version_resolve "$KUBE_VERSION")
  collect_nodes fresh
  if [[ -z "$KUBE_APISERVER" ]]; then KUBE_APISERVER="${NODE_IPS[0]}:6443"; fi
  for ((i=0; i<${#NODE_HOSTS[@]}; i++)); do run "${NODE_HOSTS[$i]}" node_install; done
  config=$(render_init "${NODE_NAMES[0]}" "${NODE_IPS[0]}")
  run "$MGMT_NODE" node_init "$config"
  for ((i=1; i<${#NODE_HOSTS[@]}; i++)); do join_node "$i"; done
  wait_nodes
}

add_nodes() {
  local requested=$KUBE_VERSION i
  read_context
  if [[ "$requested" != latest ]]; then
    requested=$(version_resolve "$requested")
    [[ "$requested" == "$CLUSTER_VERSION" ]] || { fail 'New nodes must match the control-plane version'; return 1; }
  fi
  KUBE_VERSION=$CLUSTER_VERSION
  collect_nodes fresh
  for ((i=0; i<${#NODE_HOSTS[@]}; i++)); do
    run "${NODE_HOSTS[$i]}" node_install
    join_node "$i"
  done
  wait_nodes
}

wait_nodes() {
  local name
  for name in "${NODE_NAMES[@]}"; do
    run "$MGMT_NODE" node_kube wait --for=condition=Ready "node/$name" --timeout=300s
  done
  run "$MGMT_NODE" node_kube -n kube-system rollout status deployment/coredns --timeout=300s
  run "$MGMT_NODE" node_kube get nodes -o wide
}

inventory_entry() {
  local name=$1
  awk -v name="$name" '$1==name {print; found=1} END {if(!found) exit 1}' <<< "$INVENTORY"
}

validate_inventory() {
  local complete=$1 i entry name role ip version count=0
  for ((i=0; i<${#NODE_HOSTS[@]}; i++)); do
    entry=$(inventory_entry "${NODE_NAMES[$i]}") || { fail "Node ${NODE_NAMES[$i]} not found in cluster inventory"; return 1; }
    read -r name role ip version <<< "$entry"
    [[ "$role" == "${NODE_ROLES[$i]}" && "$ip" == "${NODE_IPS[$i]}" ]] || {
      fail "Node role/IP mismatch for $name; use the node's InternalIP interface"; return 1;
    }
  done
  if [[ "$complete" == yes ]]; then
    while read -r name role ip version; do [[ -z "$name" ]] || count=$((count + 1)); done <<< "$INVENTORY"
    (( count == ${#NODE_HOSTS[@]} )) || { fail 'Upgrade requires all existing control-plane and worker nodes'; return 1; }
  fi
}

upgrade_cluster() {
  local i entry name role ip version server_version pending=0 first=yes
  read_context
  server_version=$CLUSTER_VERSION
  KUBE_VERSION=$(version_resolve "$KUBE_VERSION")
  INVENTORY=$(run "$MGMT_NODE" node_inventory)
  collect_nodes upgrade
  validate_inventory yes
  if [[ "$server_version" != "$KUBE_VERSION" ]]; then upgrade_validate "$server_version" "$KUBE_VERSION"; fi
  # Validate every node before draining any node; also allow resuming after a
  # successful API server upgrade interrupted before all kubelets were upgraded.
  while read -r name role ip version; do
    version=${version#v}
    if [[ "$version" != "$KUBE_VERSION" ]]; then
      upgrade_validate "$version" "$KUBE_VERSION"
      pending=$((pending + 1))
    fi
  done <<< "$INVENTORY"
  (( pending > 0 )) || { fail 'All nodes already run the requested version'; return 1; }
  for ((i=0; i<${#NODE_HOSTS[@]}; i++)); do
    entry=$(inventory_entry "${NODE_NAMES[$i]}")
    read -r name role ip version <<< "$entry"
    if [[ "${version#v}" == "$KUBE_VERSION" ]]; then continue; fi
    run "$MGMT_NODE" node_kube drain "$name" --ignore-daemonsets --timeout=300s
    if [[ "$role" == master && "$first" == yes ]]; then
      run "${NODE_HOSTS[$i]}" node_upgrade first
      first=no
    else
      run "${NODE_HOSTS[$i]}" node_upgrade node
    fi
    run "$MGMT_NODE" node_wait_version "$name"
    run "$MGMT_NODE" node_kube wait --for=condition=Ready "node/$name" --timeout=300s
    run "$MGMT_NODE" node_kube uncordon "$name"
  done
  wait_nodes
}

delete_node() {
  local entry name role ip version masters
  read_context
  INVENTORY=$(run "$MGMT_NODE" node_inventory)
  collect_nodes member
  validate_inventory no
  entry=$(inventory_entry "${NODE_NAMES[0]}")
  read -r name role ip version <<< "$entry"
  if [[ "$role" == master ]]; then
    masters=$(awk '$2=="master" {n++} END {print n+0}' <<< "$INVENTORY")
    (( masters > 1 )) || { fail 'Cannot delete the last control-plane node'; return 1; }
    local mgmt_identity
    mgmt_identity=$(run "$MGMT_NODE" node_identity)
    [[ "${mgmt_identity%% *}" != "$name" ]] || { fail 'Use another --mgmt-node to delete this control plane'; return 1; }
  fi
  run "$MGMT_NODE" node_kube drain "$name" --ignore-daemonsets --timeout=300s
  run "${NODE_HOSTS[0]}" node_reset
  run "$MGMT_NODE" node_kube delete node "$name"
}

main() {
  defaults
  local parsed=0 host count=0
  parse_args "$@" || parsed=$?
  [[ "$parsed" != 2 ]] || return 0
  [[ "$parsed" == 0 ]] || return "$parsed"
  validate_inputs
  if [[ "$COMMAND" == init || "$COMMAND" == render-config ]]; then
    MASTER_NODES=${MASTER_NODES:-127.0.0.1}
    for host in $MASTER_NODES; do count=$((count + 1)); done
    if (( count > 1 )) && [[ -z "$KUBE_APISERVER" ]]; then
      fail 'Multiple control-plane nodes require --apiserver HOST:PORT and a preconfigured TCP load balancer'; return 1
    fi
  elif [[ "$COMMAND" != backup-etcd ]]; then
    [[ -n "$MASTER_NODES$WORKER_NODES" ]] || { fail 'Specify --master and/or --worker nodes'; return 1; }
  fi
  if [[ "$COMMAND" == renew-cert || "$COMMAND" == upgrade ]]; then
    [[ -n "$MASTER_NODES" ]] || { fail 'Specify control-plane nodes using --master'; return 1; }
    [[ -z "$WORKER_NODES" || "$COMMAND" != renew-cert ]] || { fail 'renew-cert accepts control-plane nodes only'; return 1; }
    # Unless explicitly set, use the first listed control plane as management host.
    [[ "$MGMT_NODE" != 127.0.0.1 ]] || MGMT_NODE=${MASTER_NODES%% *}
  fi
  if [[ "$COMMAND" == del ]]; then
    count=0
    for host in $MASTER_NODES $WORKER_NODES; do count=$((count + 1)); done
    (( count == 1 )) || { fail 'Delete exactly one node at a time'; return 1; }
  fi
  case "$COMMAND" in
    render-config)
      [[ "$KUBE_VERSION" =~ ^v?1\.(35|36|37)\.[0-9]+$ ]] || { fail 'render-config requires an exact --version'; return 1; }
      KUBE_VERSION=$(version_validate "$KUBE_VERSION")
      host=${MASTER_NODES%% *}
      [[ "$host" =~ ^[0-9.]+$ ]] || { fail 'render-config requires an IPv4 --master'; return 1; }
      KUBE_APISERVER=${KUBE_APISERVER:-$host:6443}
      render_init control-plane "$host" ;;
    init) init_cluster ;;
    add) add_nodes ;;
    del) delete_node ;;
    upgrade) upgrade_cluster ;;
    reset)
      collect_nodes member
      for host in "${NODE_HOSTS[@]}"; do run "$host" node_reset; done ;;
    renew-cert)
      collect_nodes member
      for host in "${NODE_HOSTS[@]}"; do
        run "$host" node_renew
        run "$host" node_wait_api
      done ;;
    backup-etcd) run "$MGMT_NODE" node_backup ;;
    check) collect_nodes fresh ;;
  esac
  [[ "$COMMAND" == render-config ]] || log "$COMMAND completed"
}
