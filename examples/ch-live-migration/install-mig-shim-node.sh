#!/bin/bash
# Copyright Contributors to Agones a Series of LF Projects, LLC.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Node-side half of install-mig-shim.sh, run as root on a node: installs the shim (and CH, if
# copied) from /home/docker and, the first time, the kata-clh-mig config and containerd runtime.
set -e
DEF=/opt/kata/share/defaults/kata-containers/runtimes
install -m 0755 /home/docker/containerd-shim-kata-mig-v2 /opt/kata/bin/containerd-shim-kata-mig-v2
if [ ! -d $DEF/clh-mig ]; then
  cp -a $DEF/clh $DEF/clh-mig
  mv $DEF/clh-mig/configuration-clh.toml $DEF/clh-mig/configuration-clh-mig.toml
  mkdir -p $DEF/clh-mig/config.d
  printf '[agent.kata]\ndebug_console_enabled = true\n' >$DEF/clh-mig/config.d/90-debug-console.toml
fi
if [ -f /home/docker/cloud-hypervisor-mig ]; then
  # Copy then rename: running VMs keep the old binary's inode.
  install -m 0755 /home/docker/cloud-hypervisor-mig /opt/kata/bin/.cloud-hypervisor-mig.new
  mv /opt/kata/bin/.cloud-hypervisor-mig.new /opt/kata/bin/cloud-hypervisor-mig
  cat >$DEF/clh-mig/config.d/80-cloud-hypervisor.toml <<'TOML'
[hypervisor.clh]
path = "/opt/kata/bin/cloud-hypervisor-mig"
valid_hypervisor_paths = ["/opt/kata/bin/cloud-hypervisor", "/opt/kata/bin/cloud-hypervisor-mig"]
TOML
  /opt/kata/bin/cloud-hypervisor-mig --version
fi
# Gratuitous ARP when the agent re-targets and brings up a migrated NIC, so the new node learns
# the pod's MAC right away instead of on the next ARP retry (~1s). Lives in guest memory, so it
# migrates with the VM. kernel_params replaces the base value, so repeat it.
cat >$DEF/clh-mig/config.d/85-arp-notify.toml <<'TOML'
[hypervisor.clh]
kernel_params = "cgroup_no_v1=all systemd.unified_cgroup_hierarchy=1 sysctl.net.ipv4.conf.all.arp_notify=1 sysctl.net.ipv4.conf.default.arp_notify=1"
TOML
mkdir -p /etc/containerd/conf.d
# pod_annotations: Kata's own, plus the live-migration receive-mode annotations.
cat >/tmp/kata-clh-mig.toml <<TOML
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata-clh-mig]
runtime_type = "io.containerd.kata-clh-mig.v2"
runtime_path = "/opt/kata/bin/containerd-shim-kata-mig-v2"
privileged_without_host_devices = true
pod_annotations = ["io.katacontainers.*", "migrate.agones.dev/*"]
container_annotations = ["io.kubernetes.container.terminationMessage*"]

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata-clh-mig.options]
ConfigPath = "$DEF/clh-mig/configuration-clh-mig.toml"
TOML
RESTART=
if ! cmp -s /tmp/kata-clh-mig.toml /etc/containerd/conf.d/kata-clh-mig.toml; then
  mv /tmp/kata-clh-mig.toml /etc/containerd/conf.d/kata-clh-mig.toml
  RESTART=1
fi
# minikube's config.toml has an explicit imports list (kata-deploy adds to it), so the conf.d
# glob containerd shows in `config dump` isn't in effect: add our drop-in explicitly.
# minikube may rewrite config.toml on `minikube start`; re-run this script afterwards.
if ! grep -q 'conf.d/kata-clh-mig.toml' /etc/containerd/config.toml; then
  sed -i 's|^imports = \[\(.*\)\]$|imports = [\1, "/etc/containerd/conf.d/kata-clh-mig.toml"]|' \
    /etc/containerd/config.toml
  RESTART=1
fi
# systemd disables cpuset on pod slices when no unit asks for it; kubelet (systemd cgroup driver)
# then sees the pod cgroup as missing and kills Burstable Kata pods' containers on its next sync
# (kubernetes/kubernetes#131567), about once a minute, and kills a migration placeholder outright.
# Asking for all CPUs on every kubepods-* slice keeps cpuset enabled without restricting anything.
D=/etc/systemd/system/kubepods-.slice.d
CPUSET="[Slice]
AllowedCPUs=0-$(($(nproc) - 1))"
if [ "$(cat $D/50-cpuset.conf 2>/dev/null)" != "$CPUSET" ]; then
  mkdir -p $D && echo "$CPUSET" >$D/50-cpuset.conf && systemctl daemon-reload
  echo "kubepods cpuset drop-in installed"
fi
if [ -n "$RESTART" ]; then
  systemctl restart containerd
  echo "containerd restarted"
fi
containerd config dump 2>/dev/null | grep -q 'runtimes.kata-clh-mig\]' ||
  { echo "kata-clh-mig not loaded by containerd"; exit 1; }
/opt/kata/bin/containerd-shim-kata-mig-v2 --version | head -1
