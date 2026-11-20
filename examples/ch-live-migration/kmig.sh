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

# Experimental live migration of a Kata (kata-clh) pod's VM, run as root on a node.
# Needs `mig.sh setup` first (brmig bridge, /tmp/mig/ch-remote) and the Kata agent
# debug console enabled. Steps:
#   src: kmig.sh unplug <id>       remove the Kata NIC (fd-backed, can't migrate)
#   src: kmig.sh freeze <id>       SIGSTOP the Kata shim so it can't tear down the sandbox
#   dst: kmig.sh tree-recv <id> [port]       cross-node only: start first, receives shared/
#   src: kmig.sh tree-send <id> <dst-ip> [port]   cross-node only: copy the shim's shared/ tree
#   dst: kmig.sh dst <id> [port]   destination virtiofsd + CH, waiting on TCP port
#   src: kmig.sh send <id> <dst-ip> [port]   via a socat bridge out of the pod netns
#   dst: kmig.sh revsock <id>      same-node only: move the vsock to a path the source didn't unlink
#   dst: kmig.sh plug <id> <guest-ip>   hot-add a named tap on brmig, set the guest IP
#   any: kmig.sh console <id> '<cmd>'   run a command in the guest via the debug console
#   any: kmig.sh info <id>
#   any: kmig.sh cleanup <id>      undo this script's state on this node and thaw the shim
#   dst: kmig.sh bridge-in - [port] [unix-path]   pod 1 -> pod 2 (receive-mode shim): TCP -> CH
#   dst: kmig.sh diff-recv <placeholder-id> [port]   pod 1 -> pod 2: start once it's waiting
#   src: kmig.sh diff-send <id> <dst-ip> [port]      pod 1 -> pod 2: container writable layers
set -u
CH=/opt/kata/bin/cloud-hypervisor
VFSD=/opt/kata/libexec/virtiofsd
CHR=/tmp/mig/ch-remote
W=/tmp/mig
cmd=${1:-}; ID=${2:-}
VMDIR=/run/vc/vm/$ID
SHARED=/run/kata-containers/shared/sandboxes/$ID/shared

wait_sock() { for _ in $(seq 50); do [ -S "$1" ] && return 0; sleep 0.1; done; echo "timeout waiting for $1"; return 1; }
src_api() { echo "$VMDIR/clh-api.sock"; }

case "$cmd" in
unplug)
  $CHR --api-socket "$(src_api)" remove-device _net1 && echo "removed _net1"
  ;;
freeze)
  pid=$(pgrep -f "^/opt/kata/bin/containerd-shim-kata(-mig)?-v2 .*-id $ID") || { echo "no shim for $ID"; exit 1; }
  kill -STOP $pid && echo "shim $pid stopped"
  ;;
thaw)
  pid=$(pgrep -f "^/opt/kata/bin/containerd-shim-kata(-mig)?-v2 .*-id $ID") && kill -CONT $pid && echo "shim $pid continued"
  ;;
cleanup)
  # Undo this script's state for <id> on this node: destination CH/virtiofsd, copied tree,
  # tap, and thaw the shim (so Kubernetes can delete the pod normally).
  bash "$0" thaw "$ID" 2>/dev/null
  for p in $(pgrep -x cloud-hyperviso) $(pgrep -x virtiofsd); do
    tr '\0' ' ' </proc/$p/cmdline 2>/dev/null | grep -qE "kdst-api.sock|socket-path=$VMDIR" && kill -9 $p
  done
  if [ -f $W/kmig-mounts ]; then
    tac $W/kmig-mounts | while read -r p; do umount "$p" 2>/dev/null; done
    rm -rf "/run/kata-containers/shared/sandboxes/$ID" "$VMDIR" $W/kmig-mounts
  fi
  ip link del tapk 2>/dev/null
  rm -f $W/kdst-api.sock $W/kvsock.sock $W/kout.sock $W/.kmig-mounts
  pkill -x socat 2>/dev/null
  echo "cleaned $ID"
  ;;
tree-recv)
  # Cross-node: receive the shim's shared/ tree at the same path, then re-create each
  # submount (container rootfs, volume files) as a bind mount onto itself.
  mkdir -p "$SHARED"
  socat -u TCP-LISTEN:${3:-6100},reuseaddr - | tar -x -C "$SHARED" --numeric-owner
  mv "$SHARED/.kmig-mounts" $W/kmig-mounts
  while read -r p; do mount --bind "$p" "$p" || echo "bind failed: $p"; done <$W/kmig-mounts
  echo "received $(du -sh "$SHARED" | cut -f1), $(wc -l <$W/kmig-mounts) submounts"
  ;;
tree-send)
  # tree-send <id> <dst-ip> [port]: tar the shared/ tree from inside the shim's mount namespace.
  pid=$(pgrep -f "^/opt/kata/bin/containerd-shim-kata(-mig)?-v2 .*-id $ID") || { echo "no shim for $ID"; exit 1; }
  awk '{print $5}' /proc/$pid/mountinfo | grep "^$SHARED/" >$W/.kmig-mounts
  nsenter -t "$pid" -m tar -cf - --numeric-owner -C "$SHARED" . -C $W .kmig-mounts |
    socat -u - TCP:$3:${4:-6100}
  ;;
diff-send)
  # diff-send <id> <dst-ip> [port]: pod 1 -> pod 2. Send each container's rootfs writable layer
  # (overlay upperdir: files the container or agent created, e.g. mount points) as a tar
  # stream per container, with paths prefixed by the source container ID.
  pid=$(pgrep -f "^/opt/kata/bin/containerd-shim-kata(-mig)?-v2 .*-id $ID") || { echo "no shim for $ID"; exit 1; }
  grep -E " ${SHARED%/shared}/mounts/[^ ]+/rootfs " /proc/$pid/mountinfo |
    while read -r line; do
      cid=$(echo "$line" | awk '{print $5}' | sed -E 's|.*/mounts/([^/]+)/rootfs$|\1|')
      upper=$(echo "$line" | grep -o 'upperdir=[^,]*' | cut -d= -f2)
      tar -cf - --numeric-owner -C "$upper" --transform "s,^\.,$cid/rootfs," . && echo "$cid $upper" >&2
    done | socat -u - TCP:$3:${4:-6101}
  ;;
diff-recv)
  # diff-recv <placeholder-sandbox-id> [port]: unpack diff-send's stream into the placeholder's
  # rootfs mounts (named by source container ID) inside its shim's mount namespace.
  pid=$(pgrep -f "^/opt/kata/bin/containerd-shim-kata(-mig)?-v2 .*-id $ID") || { echo "no shim for $ID"; exit 1; }
  socat -u TCP-LISTEN:${3:-6101},reuseaddr - |
    nsenter -t "$pid" -m tar -xi --numeric-owner -C "${SHARED%/shared}/mounts"
  echo "diff received into ${SHARED%/shared}/mounts"
  ;;
probe)
  # probe <name> <ip>: UDP request about every 0.1s (0.2s when unanswered), timestamped, to
  # $W/kprobe-<name>.log until probe-stop <name>. Several can run at once.
  echo $$ >$W/kprobe-$ID.pid
  while true; do
    printf '%s %s\n' "$(date +%T.%3N)" \
      "$(echo ping | timeout 0.2 socat -T0.15 - UDP:$3:7777 2>/dev/null || true)"
    sleep 0.05
  done >$W/kprobe-$ID.log 2>&1
  ;;
pod-ip)
  # pod-ip <placeholder-id>: the pod IP of a waiting placeholder. kubelet doesn't publish it
  # while CreateContainer blocks, and crictl's status call goes through the busy shim, so read
  # eth0 in the pod netns, where the placeholder's CH runs.
  ch=$(pgrep -f "^/opt/kata/bin/cloud-hypervisor --api-socket $VMDIR/") || { echo "no CH for $ID" >&2; exit 1; }
  nsenter -t "$ch" -n ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1
  ;;
outage)
  # outage - <unplug-time>: from the src/dst probe logs, the gap between the last reply from the
  # source pod IP and the first reply from the destination pod IP.
  awk -v t0="$3" '
    function sec(t,  a) { split(t, a, ":"); return a[1] * 3600 + a[2] * 60 + a[3] }
    FILENAME ~ /src/ && /boot=/ { last = $1 }
    FILENAME ~ /dst/ && /boot=/ && !first { first = $1; line = $0 }
    END {
      printf "unplug %s, last pod 1 reply %s, first pod 2 reply %s\n", t0, last, first
      printf "outage: %.2fs (last pod 1 reply -> first pod 2 reply), %.2fs from unplug\n", sec(first) - sec(last), sec(first) - sec(t0)
      print "first pod 2 reply: " line
    }' $W/kprobe-src.log $W/kprobe-dst.log
  ;;
probe-stop)
  [ -f $W/kprobe-$ID.pid ] && kill "$(cat $W/kprobe-$ID.pid)" 2>/dev/null; rm -f $W/kprobe-$ID.pid
  ;;
dst)
  mkdir -p "$VMDIR" "$SHARED"
  # The destination reuses the source's config, so its socket paths must be free.
  rm -f "$VMDIR/virtiofsd.sock" "$VMDIR/virtiofsd.sock.pid" "$VMDIR/clh.sock" $W/kdst-api.sock $W/kdst-events.json
  # The Kata shim has its own mount namespace, where shared/ is a read-only bind of mounts/
  # with the container rootfs and volumes under it. On the source node, run virtiofsd there.
  NS=()
  shim=$(pgrep -f "^/opt/kata/bin/containerd-shim-kata(-mig)?-v2 .*-id $ID") && NS=(nsenter -t "$shim" -m --)
  setsid nohup "${NS[@]}" $VFSD --socket-path="$VMDIR/virtiofsd.sock" --shared-dir="$SHARED" --cache=auto \
    --thread-pool-size=1 --announce-submounts --migration-mode=find-paths --log-level=info \
    >$W/kvfsd-dst.log 2>&1 </dev/null &
  wait_sock "$VMDIR/virtiofsd.sock" || exit 1
  setsid nohup $CH --api-socket $W/kdst-api.sock --event-monitor path=$W/kdst-events.json -v \
    >$W/kch-dst.log 2>&1 </dev/null &
  wait_sock $W/kdst-api.sock || exit 1
  setsid nohup $CHR --api-socket $W/kdst-api.sock receive-migration \
    receiver_url=tcp:0.0.0.0:${3:-6000} >$W/krecv.log 2>&1 </dev/null &
  sleep 1
  grep -o 'migration-receive-ready' $W/kdst-events.json
  ;;
send)
  # Kata's CH lives in the pod netns, which has no usable network: bridge via a UNIX socket.
  rm -f $W/kout.sock
  setsid nohup socat UNIX-LISTEN:$W/kout.sock,fork TCP:$3:${4:-6000} >$W/ksocat.log 2>&1 </dev/null &
  wait_sock $W/kout.sock || exit 1
  $CHR --api-socket "$(src_api)" send-migration destination_url=unix:$W/kout.sock
  ;;
bridge-in)
  # bridge-in - [port] [unix-path]: for a receive-mode placeholder pod (kata-clh-mig shim). Its
  # CH listens on a UNIX socket (the pod netns can't take connections), so accept TCP here.
  # The <id> argument is unused; pass '-'.
  setsid nohup socat TCP-LISTEN:${3:-6000},reuseaddr,fork UNIX-CONNECT:${4:-/run/vc/migrate-in.sock} \
    >$W/kbridge-in.log 2>&1 </dev/null &
  sleep 0.5
  ss -tln | grep -q ":${3:-6000} " && echo "bridging tcp:${3:-6000} -> ${4:-/run/vc/migrate-in.sock}"
  ;;
revsock)
  # Same-node only: when the source CH exits it unlinks its vsock path, which is also the
  # destination's. Swap the destination's vsock device to a new path; the agent's debug
  # console listens on a vsock port, so it comes back on the new device.
  $CHR --api-socket $W/kdst-api.sock remove-device "${3:-_vsock3}" && sleep 1
  rm -f $W/kvsock.sock
  $CHR --api-socket $W/kdst-api.sock add-vsock cid=3,socket=$W/kvsock.sock
  ;;
plug)
  ip link show tapk >/dev/null 2>&1 || ip tuntap add dev tapk mode tap
  ip link set tapk master brmig up
  $CHR --api-socket $W/kdst-api.sock add-net tap=tapk,mac=52:54:00:00:00:20
  sleep 2
  bash "$0" console "$ID" "I=\$(ls /sys/class/net | grep -v '^lo\$' | head -1); ip link set \$I up; ip addr add $3/24 dev \$I; ip -br addr"
  ;;
console)
  VS="$VMDIR/clh.sock"; [ -S $W/kvsock.sock ] && VS=$W/kvsock.sock
  { echo "CONNECT 1026"; sleep 1; echo "$3"; sleep 2; } |
    timeout 6 socat - UNIX-CONNECT:"$VS" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | tail -n +2
  ;;
info)
  for s in "$(src_api)" $W/kdst-api.sock; do
    [ -S "$s" ] && echo "$s: $($CHR --api-socket "$s" info 2>/dev/null | grep -o '"state": *"[A-Za-z]*"')"
  done
  [ -f $W/kdst-events.json ] && echo "dst: $(grep -o '"event": "[a-z-]*"' $W/kdst-events.json | cut -d'"' -f4 | tr '\n' ' ')"
  ;;
*) sed -n '16,30p' "$0"; exit 2 ;;
esac
