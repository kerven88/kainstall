"""Behavioral tests: no SSH, package installs or host configuration changes."""
import pathlib
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
LIB = ROOT / 'lib/kainstall.sh'


def shell(code, stdin=None):
    return subprocess.run(['bash', '-c', 'set -Eeuo pipefail; source "$1"; ' + code,
                           'test', str(LIB)], input=stdin, text=True, capture_output=True)


class PlatformTests(unittest.TestCase):
    def test_supported_distribution_matrix(self):
        for distro, version, name, family in [
            ('ubuntu', '22.04', 'Ubuntu', 'apt'), ('ubuntu', '24.04', 'Ubuntu', 'apt'),
            ('debian', '12', 'Debian', 'apt'), ('debian', '13', 'Debian', 'apt'),
            ('centos', '9', 'CentOS Stream', 'dnf'), ('centos', '10', 'CentOS Stream', 'dnf'),
            ('rocky', '9.6', 'Rocky Linux', 'dnf'), ('rocky', '10.0', 'Rocky Linux', 'dnf'),
            ('amzn', '2023', 'Amazon Linux', 'dnf')]:
            with self.subTest(distro=distro, version=version):
                r = shell(f'platform_family "{distro}" "{version}" "{name}"')
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(r.stdout.strip(), family)

    def test_old_or_unrecognized_distributions_rejected(self):
        for args in ['centos 8 "CentOS Linux"', 'centos 9 "CentOS Linux"',
                     'amzn 2 "Amazon Linux"', 'ubuntu 20.04 Ubuntu',
                     'debian 11 Debian', 'rocky 8.10 Rocky', 'almalinux 9 Alma']:
            with self.subTest(args=args):
                r = shell('platform_family ' + args)
                self.assertNotEqual(r.returncode, 0)
                self.assertIn('Unsupported OS', r.stderr)

    def test_architecture_mapping(self):
        for arch, expected in [('x86_64', 'amd64'), ('aarch64', 'arm64')]:
            r = shell(f'platform_arch {arch}')
            self.assertEqual(r.stdout.strip(), expected)
        self.assertNotEqual(shell('platform_arch i686').returncode, 0)


class VersionTests(unittest.TestCase):
    def test_version_normalization_and_range(self):
        for version in ['1.35.1', 'v1.36.5', '1.37.1']:
            r = shell(f'version_validate {version}')
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(r.stdout.strip(), version.lstrip('v'))
        for version in ['1.27.1', '1.34.9', '1.38.0', '1.37.0-rc.1', 'garbage']:
            self.assertNotEqual(shell(f'version_validate {version}').returncode, 0)

    def test_exact_package_version_uses_repository_revision(self):
        r = shell('select_package_version 1.35.1',
                  '1.35.10-1.1\n1.35.1-2.1\n1.35.1-1.1\n1.36.1-1.1\n')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), '1.35.1-2.1')
        self.assertNotEqual(shell('select_package_version 1.35.1', '1.35.10-1.1\n').returncode, 0)

    def test_upgrade_rejects_downgrade_skipped_minor_and_noop(self):
        for current, target in [('1.35.2', '1.35.1'), ('1.35.1', '1.37.1'),
                                ('1.36.1', '1.35.1'), ('1.35.1', '1.35.1')]:
            self.assertNotEqual(shell(f'upgrade_validate {current} {target}').returncode, 0)
        for current, target in [('1.35.1', '1.35.2'), ('1.35.9', '1.36.1'),
                                ('1.36.5', '1.37.1')]:
            r = shell(f'upgrade_validate {current} {target}')
            self.assertEqual(r.returncode, 0, r.stderr)


class ConfigTests(unittest.TestCase):
    def test_init_config_has_modern_api_systemd_cgroups_and_endpoint(self):
        r = shell('defaults; KUBE_VERSION=1.35.1; KUBE_APISERVER=lb.example:6443; '
                  'render_init cp1 10.0.0.11')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('apiVersion: kubeadm.k8s.io/v1beta4', r.stdout)
        self.assertIn('kubernetesVersion: v1.35.1', r.stdout)
        self.assertIn('controlPlaneEndpoint: "lb.example:6443"', r.stdout)
        self.assertIn('cgroupDriver: systemd', r.stdout)
        self.assertIn('advertiseAddress: "10.0.0.11"', r.stdout)
        self.assertNotIn('dockershim', r.stdout)
        self.assertNotIn('pod-infra-container-image', r.stdout)
        self.assertNotIn('runtime-cgroups', r.stdout)

    def test_join_worker_and_control_plane_discovery(self):
        for role in ['worker', 'master']:
            r = shell('defaults; KUBE_APISERVER=lb.example:6443; '
                      f'render_join {role} node2 10.0.0.12 abcdef.0123456789abcdef '
                      + 'a' * 64 + ' ' + 'b' * 64)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn('sha256:' + 'a' * 64, r.stdout)
            self.assertIn('discovery: 5m0s', r.stdout)
            self.assertNotIn('unsafeSkipCAVerification', r.stdout)
            self.assertEqual('certificateKey:' in r.stdout, role == 'master')
            self.assertEqual('advertiseAddress:' in r.stdout, role == 'master')

    def test_ten_year_certificates_use_official_kubeadm_fields(self):
        r = shell('defaults; KUBE_VERSION=1.35.1; KUBE_APISERVER=10.0.0.11:6443; '
                  'CERT_YEARS=10; render_init cp1 10.0.0.11')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('certificateValidityPeriod: 87600h', r.stdout)


class CliTests(unittest.TestCase):
    def cli(self, *args):
        return subprocess.run(['bash', str(ROOT / 'kainstall.sh'), *args],
                              capture_output=True, text=True)

    def test_help_works_without_root_or_network(self):
        r = self.cli('--help')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('Amazon Linux 2023', r.stdout)

    def test_unsafe_or_unsupported_inputs_fail_before_connection(self):
        for args in [('init', '--version', '1.27.1'),
                     ('init', '--master', '10.0.0.1;touch /tmp/unwanted'),
                     ('init', '--cri', 'docker'), ('init', '--network', 'calico'),
                     ('init', '--offline-file', 'old.tgz'),
                     ('init', '--master', '10.0.0.1,10.0.0.2'),
                     ('init', '--version'), ('init', '--ingress', 'nginx')]:
            with self.subTest(args=args):
                r = self.cli(*args)
                self.assertNotEqual(r.returncode, 0)
                self.assertNotIn('Connecting', r.stderr)
                self.assertNotIn('Permission denied', r.stderr)

    def test_render_config_is_readonly(self):
        r = self.cli('render-config', '--master', '10.0.0.11', '--version', '1.35.1')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('controlPlaneEndpoint: "10.0.0.11:6443"', r.stdout)


class WorkflowTests(unittest.TestCase):
    def workflow(self, code):
        return shell('source "' + str(ROOT / 'lib/cli.sh') + '"; defaults; ' + code)

    def test_failed_install_stops_before_init_and_never_reports_success(self):
        r = self.workflow('''
version_resolve() { echo 1.35.1; }
run() {
  local host=$1 action=$2
  case "$action" in
    node_preflight) return 0 ;;
    node_identity) echo "cp1 10.0.0.11" ;;
    node_install) echo PACKAGE_FAILURE >&2; return 42 ;;
    *) echo "UNEXPECTED_MUTATION $action" ;;
  esac
}
main init --master 10.0.0.11 --version 1.35.1
''')
        self.assertEqual(r.returncode, 42, r.stderr)
        self.assertIn('PACKAGE_FAILURE', r.stderr)
        self.assertNotIn('UNEXPECTED_MUTATION', r.stdout)
        self.assertNotIn('completed', r.stderr)

    def test_missing_upgrade_node_fails_before_drain(self):
        r = self.workflow('''
version_resolve() { echo 1.36.1; }
run() {
  case "$2" in
    node_context) printf 'v1.35.1\\nlb.example:6443\\n' ;;
    node_inventory) printf 'cp1 master 10.0.0.11 v1.35.1\\nworker1 worker 10.0.0.12 v1.35.1\\n' ;;
    node_preflight) return 0 ;;
    node_identity) echo 'cp1 10.0.0.11' ;;
    *) echo "UNEXPECTED_MUTATION $2" ;;
  esac
}
main upgrade --master 10.0.0.11 --version 1.36.1
''')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('all existing', r.stderr)
        self.assertNotIn('UNEXPECTED_MUTATION', r.stdout)

    def test_upgrade_uses_exact_target_and_drains_before_changing_node(self):
        r = self.workflow('''
version_resolve() { echo 1.36.1; }
run() {
  local host=$1 action=$2; shift 2
  case "$action" in
    node_context) printf 'v1.35.1\\nlb.example:6443\\n' ;;
    node_inventory) echo 'cp1 master 10.0.0.11 v1.35.1' ;;
    node_preflight) return 0 ;;
    node_identity) echo 'cp1 10.0.0.11' ;;
    *) printf '%s %s %s\\n' "$action" "$*" "$KUBE_VERSION" ;;
  esac
}
main upgrade --master 10.0.0.11 --version 1.36.1
''')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertLess(r.stdout.index('drain cp1'), r.stdout.index('node_upgrade first 1.36.1'))
        self.assertLess(r.stdout.index('node_upgrade first 1.36.1'), r.stdout.index('uncordon cp1'))

    def test_failed_upgrade_keeps_node_cordoned(self):
        r = self.workflow('''
version_resolve() { echo 1.36.1; }
run() {
  local host=$1 action=$2; shift 2
  case "$action" in
    node_context) printf 'v1.35.1\\nlb.example:6443\\n' ;;
    node_inventory) echo 'cp1 master 10.0.0.11 v1.35.1' ;;
    node_preflight) return 0 ;;
    node_identity) echo 'cp1 10.0.0.11' ;;
    node_upgrade) return 43 ;;
    *) echo "$action $*" ;;
  esac
}
main upgrade --master 10.0.0.11 --version 1.36.1
''')
        self.assertEqual(r.returncode, 43, r.stderr)
        self.assertNotIn('uncordon', r.stdout)
        self.assertNotIn('completed', r.stderr)

    def test_join_inherits_cluster_version_instead_of_latest(self):
        r = self.workflow('''
run() {
  local host=$1 action=$2
  case "$action" in
    node_context) printf 'v1.35.1\\nlb.example:6443\\n' ;;
    node_preflight) return 0 ;;
    node_identity) echo 'worker1 10.0.0.12' ;;
    node_credentials) echo 'abcdef.0123456789abcdef aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ;;
    node_install) echo "installed=$KUBE_VERSION" ;;
    node_join) printf '%s\\n' "$3" ;;
  esac
}
main add --worker 10.0.0.12 --mgmt-node 10.0.0.11
''')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('installed=1.35.1', r.stdout)
        self.assertIn('apiServerEndpoint: "lb.example:6443"', r.stdout)

    def test_network_overlap_rejected_before_ssh(self):
        for pod, service in [('10.96.0.0/16', '10.96.0.0/12'), ('10.999.0.0/16', '10.96.0.0/12')]:
            r = self.workflow(f'''
KUBE_POD_SUBNET={pod}; KUBE_SERVICE_SUBNET={service}
run() {{ echo UNEXPECTED_CONNECTION; }}
version_resolve() {{ echo 1.35.1; }}
main init --master 10.0.0.11 --version 1.35.1
''')
            self.assertNotEqual(r.returncode, 0)
            self.assertNotIn('UNEXPECTED_CONNECTION', r.stdout)

    def test_local_transport_quotes_configuration_and_propagates_failure(self):
        # Real run() serialization into a fresh Bash process; replace only sudo,
        # because tests must not elevate or depend on the developer being root.
        r = self.workflow('''
sudo() { [[ "$1" != -n ]] || shift; "$@"; }
KUBE_DNSDOMAIN='literal$(exit 99)'
probe() { printf '%s|%s\\n' "$KUBE_DNSDOMAIN" "$1"; return 44; }
run localhost probe 'argument with spaces; $(exit 98)'
''')
        self.assertEqual(r.returncode, 44, r.stderr)
        self.assertEqual(r.stdout.strip(), 'literal$(exit 99)|argument with spaces; $(exit 98)')


class PackageTests(unittest.TestCase):
    def test_apt_and_rpm_pin_exact_repository_versions(self):
        for family, listing, expected in [
            ('apt', 'kubelet | 1.35.1-1.1 | https://repo/\nkubelet | 1.35.10-1.1 | https://repo/', 'kubelet=1.35.1-1.1'),
            ('dnf', 'Available Packages\nkubelet.x86_64 1.35.1-150500.1.1 kubernetes\nkubelet.x86_64 1.35.10-150500.1.1 kubernetes', 'kubelet-1.35.1-150500.1.1')]:
            code = '''
defaults; KUBE_VERSION=1.35.1
node_platform() { echo FAMILY; }
apt-cache() { printf '%s\\n' 'LISTING'; }
apt-get() { printf '%s\\n' "$*"; }
apt-mark() { :; }
dnf() {
  if [[ "$*" == *--showduplicates* ]]; then printf '%s\\n' 'LISTING'; else printf '%s\\n' "$*"; fi
}
node_packages kubelet
'''.replace('FAMILY', family).replace('LISTING', listing)
            r = shell(code)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn(expected, r.stdout)
            self.assertNotIn('kubelet=1.35.10', r.stdout)

    def test_bad_checksum_is_rejected_before_extraction(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            asset = pathlib.Path(tmp) / 'asset'
            checksum = pathlib.Path(tmp) / 'checksum'
            asset.write_text('tampered payload')
            checksum.write_text('0' * 64)
            r = shell(f'verify_checksum "{asset}" "{checksum}"')
            self.assertNotEqual(r.returncode, 0)


class RuntimeConfigTests(unittest.TestCase):
    def test_containerd_v3_config_uses_systemd_and_selected_pause(self):
        import tomllib
        r = shell('render_runtime registry.k8s.io/pause:3.10.1')
        self.assertEqual(r.returncode, 0, r.stderr)
        config = tomllib.loads(r.stdout)
        self.assertEqual(config['version'], 3)
        self.assertEqual(config['plugins']['io.containerd.cri.v1.images']['pinned_images']['sandbox'],
                         'registry.k8s.io/pause:3.10.1')
        runtime = config['plugins']['io.containerd.cri.v1.runtime']['containerd']['runtimes']['runc']
        self.assertEqual(runtime['runtime_type'], 'io.containerd.runc.v2')
        self.assertTrue(runtime['options']['SystemdCgroup'])

    def test_pause_update_preserves_other_runtime_options(self):
        import tempfile
        import tomllib
        with tempfile.TemporaryDirectory() as tmp:
            config = pathlib.Path(tmp) / 'config.toml'
            config.write_text("""version = 3
[plugins.'io.containerd.cri.v1.images'.pinned_images]
  sandbox = 'registry.k8s.io/pause:3.9'
[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]
  SystemdCgroup = true
""")
            r = shell(f'update_pause_config "{config}" registry.k8s.io/pause:3.10.1')
            self.assertEqual(r.returncode, 0, r.stderr)
            result = tomllib.loads(config.read_text())
            self.assertEqual(result['plugins']['io.containerd.cri.v1.images']['pinned_images']['sandbox'],
                             'registry.k8s.io/pause:3.10.1')
            self.assertTrue(result['plugins']['io.containerd.cri.v1.runtime']['containerd']['runtimes']['runc']['options']['SystemdCgroup'])

    def test_unknown_runtime_layout_is_not_overwritten(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            config = pathlib.Path(tmp) / 'config.toml'
            original = "version = 2\n[other]\nsandbox = 'old'\n"
            config.write_text(original)
            r = shell(f'update_pause_config "{config}" registry.k8s.io/pause:3.10.1')
            self.assertNotEqual(r.returncode, 0)
            self.assertEqual(config.read_text(), original)


class ReadinessTests(unittest.TestCase):
    def test_cri_readiness_tolerates_startup_delay(self):
        r = shell("""
cri_calls=0
crictl() { cri_calls=$((cri_calls + 1)); (( cri_calls >= 3 )); }
sleep() { :; }
node_wait_cri
printf 'attempts=%s\\n' "$cri_calls"
""")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), 'attempts=3')

    def test_cri_timeout_propagates_failure(self):
        r = shell("""
crictl() { return 1; }
sleep() { :; }
node_wait_cri
""")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('CRI', r.stderr)


class ClusterContextTests(unittest.TestCase):
    def test_private_image_repository_is_inherited(self):
        r = shell('source "' + str(ROOT / 'lib/cli.sh') + '"; defaults; ' + """
run() { printf 'v1.35.1\\nlb.example:6443\\nregistry.example.com/kubernetes\\n'; }
read_context
printf '%s|%s|%s\\n' "$CLUSTER_VERSION" "$KUBE_APISERVER" "$KUBE_IMAGE_REPO"
""")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), '1.35.1|lb.example:6443|registry.example.com/kubernetes')


if __name__ == '__main__':
    unittest.main()
