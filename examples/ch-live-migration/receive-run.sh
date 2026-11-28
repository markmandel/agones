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

# Pod 1 -> pod 2 live migration with the receive-mode shim (kata-clh-mig), run from the host.
# Starts a fresh mig-src on node 1, freezes it, creates the mig-dst placeholder on node 2, copies
# the writable layers while it waits, sends the VM, then checks the workload at pod 2's IP.
# Needs install-mig-shim.sh and the ch-mig-guest:0.1 image loaded (see the plan's rebuild steps).
# PODS=<file> picks the pod pair (default receive-pods.yaml); KIND=guest|xonotic the UDP probe,
# QKIND (default KIND) the one-off before/after query (xonotic-status shows the game state).
set -euo pipefail
cd "$(dirname "$0")"
P=migration N1=migration N2=migration-m02 N2IP=192.168.39.241
K=/home/docker/kmig.sh
PODS=${PODS:-receive-pods.yaml} KIND=${KIND:-guest}; QKIND=${QKIND:-$KIND}
on() { local n=$1; shift; minikube -p $P ssh -n "$n" -- "sudo $*"; }
pod() { python3 -I -c "print(open('$PODS').read().split('---')[$1])"; }

# Fresh nodes: the work dir and the node-side script.
for n in $N1 $N2; do
  on $n mkdir -p /tmp/mig
  minikube -p $P cp kmig.sh "$n:$K" >/dev/null
done

# Thaw shims frozen by a previous run, or deleting their pods hangs.
for old in $(on $N1 crictl pods --name mig-src -q --no-trunc 2>/dev/null | tr -d '\r'); do
  on $N1 bash $K thaw "$old" >/dev/null 2>&1 || true
done
kubectl delete pod mig-src mig-dst --ignore-not-found --wait=true --timeout=120s >/dev/null
pod 0 | kubectl apply -f - >/dev/null
kubectl wait pod/mig-src --for=condition=Ready --timeout=120s >/dev/null
SIP=$(kubectl get pod mig-src -o jsonpath='{.status.podIP}')
S=$(on $N1 crictl pods --name mig-src --state ready -q --no-trunc | tr -d '\r')
CN=$(kubectl get pod mig-src -o jsonpath='{.spec.containers[0].name}')
C=$(on $N1 crictl ps --pod "$S" --name "$CN" -q --no-trunc | tr -d '\r')
echo "source sandbox $S, container $CN $C, ip $SIP"
q() {   # retried: Xonotic rate-limits getstatus
  local r; for _ in 1 2 3; do r=$(on $N1 bash $K query - "$1" $QKIND | tr -d '\r'); [ -n "$r" ] && break; sleep 0.6; done
  echo "$r"
}
for _ in $(seq 120); do [ -n "$(q $SIP)" ] && break; sleep 1; done   # e.g. Xonotic loading a map
sleep ${SETTLE:-0}
echo "before: $(q $SIP)"
on $N1 bash $K guest-mem "$S"

on $N2 "bash -c 'ss -tln | grep -q \":6000 \" || bash $K bridge-in - 6000'"

on $N2 rm -f /run/vc/migrate-in.sock   # a stale socket would look like a waiting placeholder
pod 1 | sed -e "s/SOURCE_SANDBOX/$S/" -e "s/SOURCE_GUEST_ID/$C/" | kubectl apply -f - >/dev/null
D=
for _ in $(seq 60); do
  D=$(on $N2 crictl pods --name mig-dst --state ready -q --no-trunc 2>/dev/null | tr -d '\r')
  [ -n "$D" ] && on $N2 test -S /run/vc/migrate-in.sock 2>/dev/null && break
  sleep 1
done
[ -n "$D" ] || { echo "placeholder never started waiting"; exit 1; }
echo "placeholder sandbox $D is waiting to receive"

on $N2 "bash -c '(setsid nohup bash $K diff-recv $D 6101 >/tmp/mig/kdiff.log 2>&1 </dev/null &); sleep 1'"
on $N1 bash $K diff-send "$S" $N2IP 6101
sleep 1
on $N2 cat /tmp/mig/kdiff.log

# Network outage: probe the source pod IP and the placeholder's pod IP (assigned already, while it
# waits) from node 1, around the send.
DIP=$(on $N2 bash $K pod-ip "$D" | tr -d '\r')
[ -n "$DIP" ] || { echo "placeholder has no pod IP"; exit 1; }
echo "placeholder pod IP $DIP"
for p in src:$SIP dst:$DIP; do
  on $N1 "bash -c '(setsid nohup bash $K probe ${p%%:*} ${p#*:} $KIND >/dev/null 2>&1 </dev/null &)'"
done
sleep 2
T0=$(on $N1 date +%T.%3N | tr -d '\r')
# With CH's receive-migration net_fds support the NIC stays attached and the placeholder supplies
# its own tap. UNPLUG=1 uses the earlier workaround (unplug the source NIC first) for comparison.
if [ "${UNPLUG:-0}" = 1 ]; then on $N1 bash $K unplug "$S"; fi
on $N1 bash $K migrate-out "$S" $N2IP 6000
kubectl wait pod/mig-dst --for=condition=Ready --timeout=60s >/dev/null
sleep 3
on $N1 bash $K probe-stop src
on $N1 bash $K probe-stop dst
kubectl get pod mig-src mig-dst -o wide
echo "after, at pod 2 IP $DIP: $(q $DIP)"
echo "CH migration events (source):"
on $N1 bash $K mig-events "$S"
on $N1 bash $K outage - "$T0"

# Pod 1 after the migration: its shim keeps the containers "running" (so kubelet doesn't restart
# them there) until the pod is deleted, then tears down without an agent.
sleep 5
kubectl get pod mig-src -o jsonpath='{"pod 1 after migration: "}{.status.phase}{", restarts "}{.status.containerStatuses[0].restartCount}{"\n"}'
time kubectl delete pod mig-src --wait=true --timeout=60s
echo "pod 2 after deleting pod 1: $(q $DIP)"
