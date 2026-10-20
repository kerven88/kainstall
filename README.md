# kainstall — kubeadm install Kubernetes

基于 kubeadm 的 Kubernetes 安装和维护工具。新版使用共享 Bash 核心，支持不同
Linux 发行版混合组建集群，默认安装 containerd + Flannel。

## 适配范围

| 系统 | 目标版本 |
| --- | --- |
| Ubuntu | 22.04 LTS、24.04 LTS |
| Debian | 12、13 |
| CentOS | **Stream 9、Stream 10** |
| Rocky Linux | 9.x、10.x |
| Amazon Linux | **2023** |

- Kubernetes：**1.35.x、1.36.x、1.37.x**。不接受预发布版或其他次版本。
- 架构：`x86_64/amd64`、`aarch64/arm64`。
- 目标节点必须使用 systemd、cgroup v2。CentOS Linux 7/8、Rocky 8、Amazon Linux 2
  和其他旧系统不在支持范围。
- 此矩阵表示代码适配目标。仓库提供行为测试和 kubeadm 配置校验 CI，**不等于这些
  OS/架构组合均已完成真实虚拟机安装验证**；装机验证流程见
  [smoke-test.md](docs/smoke-test.md)。

核心变更：kubeadm `v1beta4` 配置、按 Kubernetes 次版本划分的软件源、动态解析包版本
后缀、containerd 2.x 配置及 systemd cgroups、官方证书有效期字段。

## 安装前准备

每个节点至少 2 CPU、4 GiB RAM，使用独立、唯一的主机名和静态 IPv4 地址。
安装或加节点必须使用没有已有集群、没有预装 Docker/containerd 的新节点。
脚本不接管已有容器运行时，升级命令用于本版工具安装的现代集群。

管理机需要 Bash、Python 3、curl、OpenSSH；本机操作需要 root 或 `sudo -n`。
远程操作可使用 root 或有免密 sudo 的账户，各节点应使用同一 SSH 用户和认证方式。
提前核验并加入 SSH `known_hosts`；脚本保持严格主机密钥验证。
`--password` 需要管理机安装 `sshpass`，建议使用密钥。

节点需能访问发行版软件源、`pkgs.k8s.io`、`dl.k8s.io`、GitHub、`registry.k8s.io`
和 Flannel 清单内的镜像仓库。脚本不替换发行版源，下载使用 HTTPS。
下载源和镜像仓库可通过下面的环境变量指定到可信镜像。

SELinux 系统需提前设为 permissive 或 disabled；本版的上游二进制运行时安装方案
不包含发行版 SELinux policy，遇到 enforcing 会在安装前停止。
脚本会禁用 swap、注释 fstab 中的 swap 条目（保留备份），开启转发和 bridge 内核参数，
安装并启用 chrony。使用 zram 的系统应先禁用相应 generator，避免重启后重新开启 swap。

**脚本不关闭防火墙、不清空 iptables，也不修改云安全组。** 请按拓扑提前放行：

| 用途 | 端口/协议 |
| --- | --- |
| SSH | TCP 22 或自定义 SSH 端口 |
| API Server / API 负载均衡 | TCP 6443 或自定义入口端口 |
| etcd，控制平面节点之间 | TCP 2379–2380 |
| kubelet，节点之间/控制平面访问 | TCP 10250 |
| Flannel VXLAN，节点之间 | UDP 8472 |
| NodePort，按应用需要 | TCP/UDP 30000–32767 |

多控制平面必须预先配置可从**所有节点**访问的 TCP 负载均衡，后端为各控制平面的
`IP:6443`，建议 3 个控制平面。脚本不自动创建 VIP、DNS 或负载均衡。
Pod、Service 和宿主机网段应互不重叠；默认 `10.244.0.0/16`、`10.96.0.0/12`。

## 获取代码和预检

必须克隆整个仓库；入口会读取 `lib/`，不再支持只下载一个 OS 脚本或 `curl | bash`。

```bash
git clone https://github.com/kerven88/kainstall.git
cd kainstall
bash kainstall.sh --help

# 只读预检，不安装软件或更改节点设置
bash kainstall.sh check \
  --master 10.0.0.11 --worker 10.0.0.21 \
  --user ubuntu --private-key ~/.ssh/id_ed25519
```

`kainstall-ubuntu.sh`、`kainstall-debian.sh`、`kainstall-centos.sh` 保留原入口名；新增
`kainstall-rocky.sh`、`kainstall-amazonlinux.sh`，均调用同一个核心，逐节点识别系统。

## 初始化集群

```bash
# 一个控制平面和一个 worker；1.35 自动解析为该分支最新稳定补丁版
bash kainstall.sh init \
  --master 10.0.0.11 --worker 10.0.0.21 \
  --user ubuntu --private-key ~/.ssh/id_ed25519 \
  --version 1.35

# 三个控制平面，入口由外部 TCP 负载均衡提供
bash kainstall.sh init \
  --master 10.0.0.11,10.0.0.12,10.0.0.13 \
  --worker 10.0.0.21,10.0.0.22 \
  --apiserver api.example.com:6443 \
  --user rocky --version 1.37
```

不传 `--version` 时从官方 `stable.txt` 解析一次，所有节点安装同一精确版本；若上游
已经发布了超出适配范围的新次版本，脚本会停止，此时请显式指定 `1.35`、`1.36`、`1.37`
或其中的精确补丁版本。生产环境建议显式固定补丁版本。

不传 `--master` 的 `init` 在本机安装。本机须为 Linux 目标系统。
初始化完成后，在控制平面执行：

```bash
sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes -o wide
```

复制 `admin.conf` 到个人 kubeconfig 时注意文件权限及现有 contexts；脚本不会覆盖个人配置。
控制平面保持默认不可调度污点；业务负载请运行在 worker 上。

## 加节点、删节点、重置

```bash
# --mgmt-node 必须指向已有控制平面；新节点默认继承当前集群精确版本
bash kainstall.sh add --mgmt-node 10.0.0.11 --worker 10.0.0.23 --user ubuntu
bash kainstall.sh add --mgmt-node 10.0.0.11 --master 10.0.0.14 --user ubuntu

# 一次删除一个节点；drain 遵守 PDB，不自动删除 emptyDir 数据
bash kainstall.sh del --mgmt-node 10.0.0.11 --worker 10.0.0.23 --user ubuntu

# 只重置明确列出的节点，不代表从仍在运行的集群中安全移除节点
bash kainstall.sh reset --worker 10.0.0.23 --user ubuntu
```

删除控制平面时不能删除最后一个控制平面，`--mgmt-node` 必须是另一个控制平面。
增删控制平面后，需要同步维护外部负载均衡后端及合理的 etcd 成员数量。
`reset` 使用 `kubeadm reset`，会销毁该节点的 Kubernetes/本地 etcd 状态；它不卸载软件、
恢复 swap、清空防火墙或删除个人 kubeconfig。移除在线集群成员请使用 `del`。

## 升级和证书

```bash
# 先备份 etcd；文件保存在该控制平面 /var/backups/etcd
bash kainstall.sh backup-etcd --mgmt-node 10.0.0.11 --user ubuntu

# 必须提供完整节点清单，先控制平面、再 worker，逐节点排空和升级
bash kainstall.sh upgrade \
  --master 10.0.0.11,10.0.0.12,10.0.0.13 \
  --worker 10.0.0.21,10.0.0.22 \
  --user ubuntu --version 1.36

bash kainstall.sh renew-cert --master 10.0.0.11,10.0.0.12,10.0.0.13 --user ubuntu
```

- 每次最多升级一个次版本，禁止降级；1.35 → 1.37 必须分两次执行。
- 升级前应检查目标版本发布说明、备份、应用/PDB 和第三方插件兼容性。
- 升级失败立即停止，当前节点保持 cordon。排除故障后可使用相同目标版本和完整清单
  重试；已升级 kubelet 的节点会跳过。必要时在检查节点后手动 `kubectl uncordon`。
- `renew-cert` 使用集群的证书配置，依次更新控制平面证书、重启静态 Pod 并等待 API
  就绪；单控制平面会有短暂 API 中断。个人复制的 kubeconfig 需自行同步。
- `init --10years` 使用官方 `certificateValidityPeriod`，不下载第三方修改版 kubeadm。
- 本版不负责从 2021 年的旧集群直接跨多个次版本迁移；旧集群应按官方步骤逐版迁移或重建。

## 默认组件及可配置项

| 组件 | 默认版本 |
| --- | --- |
| containerd（静态包） | 2.2.7 |
| runc | 1.4.0 |
| CNI plugins | 1.9.0 |
| Flannel | 0.28.6 |

containerd、runc、CNI binaries 下载后核验上游 SHA256；Flannel 使用固定 release 清单。
Kubernetes 软件包通过 apt/dnf 的签名验证安装；apt 自动 hold，RPM 仓库配置 exclude。
脚本从仓库查询精确包 revision，不假定旧 `-00` 后缀。升级只升级 Kubernetes 软件包，
不会自动升级 containerd/runc/CNI/Flannel；组件升级应单独安排验证。

可以设置：

```bash
export KUBE_POD_SUBNET=10.244.0.0/16
export KUBE_SERVICE_SUBNET=10.96.0.0/12
export KUBE_IMAGE_REPO=registry.k8s.io
export KUBE_PACKAGE_BASE=https://pkgs.k8s.io
export KUBE_DOWNLOAD_BASE=https://dl.k8s.io
export GITHUB_DOWNLOAD_BASE=https://github.com
# 同样支持 MASTER_NODES、WORKER_NODES、MGMT_NODE、KUBE_APISERVER、KUBE_VERSION、
# SSH_USER、SSH_PORT、SSH_PRIVATE_KEY、SSH_PASSWORD、BACKUP_DIR、CERT_YEARS。
# CONTAINERD_VERSION 限 2.2.x；RUNC_VERSION、CNI_VERSION、FLANNEL_VERSION 可覆盖。
```

原来内嵌的 ingress、dashboard、KubeSphere、监控、日志、存储及其他网络插件清单已停止
自动安装；相关旧参数会在连接节点前明确报错。请使用各项目当前支持目标 Kubernetes 的
Helm chart/安装方案。旧 Docker-only 离线包、自动内核升级及在线 `update` 命令也不再支持。

## 开发验证

```bash
python3 -m unittest discover -s tests -v
bash -n kainstall.sh lib/kainstall.sh lib/cli.sh

# 只输出配置，既不连接节点也不安装软件
bash kainstall.sh render-config --master 10.0.0.11 --version 1.35.1
```

CI 使用 Kubernetes 1.35、1.36、1.37 各自的 kubeadm 对生成的 init/join YAML 做真实 schema
校验，并执行行为测试和 ShellCheck。CI 配置校验不取代完整集群和发行版装机测试。

## License

MIT
