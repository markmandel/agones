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

# Cloud Hypervisor live-migration test harness, run as root on a minikube node.
# Usage: mig.sh setup <bridge-ip> <peer-node-ip> | src | dst <listen-port> |
#        send <dst-ip> <port> | probe | probe-stop | stop | status
set -u
K=/opt/kata/share/kata-containers/vmlinux-6.18.56-208
CH=/opt/kata/bin/cloud-hypervisor
VFSD=/opt/kata/libexec/virtiofsd
W=/tmp/mig
GUEST_IP=192.168.100.2

wait_sock() { for _ in $(seq 50); do [ -S "$1" ] && return 0; sleep 0.1; done; echo "timeout waiting for $1"; return 1; }

start_vfsd() { # $1 = log name
  # Unlink (not just replace) the pid file: a running virtiofsd holds a lock on it.
  rm -f $W/vfs.sock $W/vfs.sock.pid
  setsid nohup $VFSD --socket-path=$W/vfs.sock --shared-dir=$W/share --cache=auto \
    --migration-mode=find-paths --log-level=info >$W/vfsd-$1.log 2>&1 </dev/null &
  wait_sock $W/vfs.sock
}

case "${1:-}" in
setup)
  # setup <bridge-ip> <peer-node-ip>: one 192.168.100.0/24 L2 segment across nodes,
  # via a brmig bridge on each node joined by a vxmig VXLAN tunnel over eth0.
  BR_IP=${2:?usage: setup <bridge-ip e.g. 192.168.100.1> <peer-node-ip>}
  PEER=${3:?usage: setup <bridge-ip> <peer-node-ip>}
  LOCAL=$(ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1)
  mkdir -p $W/share
  echo "hello from the shared dir" >$W/share/hello.txt
  ip link show brmig >/dev/null 2>&1 || ip link add brmig type bridge
  ip link show vxmig >/dev/null 2>&1 ||
    ip link add vxmig type vxlan id 100 dstport 4789 local "$LOCAL" remote "$PEER" dev eth0
  ip link set vxmig master brmig up
  ip link show tapmig >/dev/null 2>&1 || ip tuntap add dev tapmig mode tap multi_queue
  ip addr flush dev tapmig
  ip link set tapmig master brmig up
  ip addr replace "$BR_IP"/24 dev brmig
  ip link set brmig up
  [ -x $W/ch-remote ] || curl -sSLf -o $W/ch-remote \
    https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/v54.0/ch-remote-static
  chmod +x $W/ch-remote
  cp /home/docker/initramfs.cpio.gz $W/
  $W/ch-remote --version
  ;;
src)
  start_vfsd src || exit 1
  rm -f $W/src-api.sock $W/vsock.sock $W/src-events.json
  setsid nohup $CH --api-socket $W/src-api.sock --event-monitor path=$W/src-events.json -v \
    --kernel $K --initramfs $W/initramfs.cpio.gz \
    --cmdline "console=ttyS0 ip=$GUEST_IP::192.168.100.1:255.255.255.0::eth0:off" \
    --cpus boot=2 --memory size=512M,shared=on \
    --net tap=tapmig,mac=52:54:00:00:00:02,num_queues=4 \
    --fs tag=share,socket=$W/vfs.sock \
    --vsock cid=3,socket=$W/vsock.sock \
    --serial file=$W/serial.log --console off >$W/ch-src.log 2>&1 </dev/null &
  wait_sock $W/src-api.sock
  ;;
dst)
  # The destination reuses the source's config, so the same paths must be free.
  start_vfsd dst || exit 1
  rm -f $W/dst-api.sock $W/vsock.sock $W/dst-events.json
  setsid nohup $CH --api-socket $W/dst-api.sock --event-monitor path=$W/dst-events.json -v \
    >$W/ch-dst.log 2>&1 </dev/null &
  wait_sock $W/dst-api.sock || exit 1
  setsid nohup $W/ch-remote --api-socket $W/dst-api.sock receive-migration \
    receiver_url=tcp:0.0.0.0:${2:-6000} >$W/recv.log 2>&1 </dev/null &
  sleep 1
  grep -o 'migration-receive-ready' $W/dst-events.json
  ;;
send)
  $W/ch-remote --api-socket $W/src-api.sock send-migration \
    destination_url=tcp:$2:${3:-6000}
  ;;
probe)
  # One request every 100ms, logged with timestamps, until `probe-stop`.
  echo $$ >$W/probe.pid
  while true; do
    printf '%s %s\n' "$(date +%T.%3N)" \
      "$(echo ping | timeout 0.3 socat -T0.25 - UDP:$GUEST_IP:7777 2>/dev/null || true)"
    sleep 0.1
  done >$W/probe.log 2>&1
  ;;
probe-stop)
  [ -f $W/probe.pid ] && kill "$(cat $W/probe.pid)" 2>/dev/null; rm -f $W/probe.pid
  ;;
stop)
  bash "$0" probe-stop
  pkill -9 -x cloud-hyperviso ; pkill -x virtiofsd
  ;;
status)
  ps -eo pid,args | grep -E "[c]loud-hypervisor|[v]irtiofsd --socket-path=$W" | cut -c1-120
  for e in src dst; do [ -f $W/$e-events.json ] && echo "$e: $(grep -o '"event": "[a-z-]*"' $W/$e-events.json | cut -d'"' -f4 | tr '\n' ' ')"; done
  ;;
*) echo "usage: $0 setup <bridge-ip> <peer-ip>|src|dst [port]|send <ip> [port]|probe|stop|status"; exit 2 ;;
esac
