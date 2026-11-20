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

# Build the Kata shim from a kata-containers checkout and install it on every node of the
# `migration` minikube profile as a separate `kata-clh-mig` runtime class, leaving the stock
# `kata-clh` class untouched as a control. Run from the host. Re-run after shim changes
# (only new pods pick up a new shim binary).
# Usage: install-mig-shim.sh [path-to-kata-containers]   (default ~/workspace/kata-containers)
set -euo pipefail
KATA=${1:-$HOME/workspace/kata-containers}
P=migration

make -C "$KATA/src/runtime" containerd-shim-v2 >/dev/null
"$KATA/src/runtime/containerd-shim-kata-v2" --version

for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
  echo "== $node"
  minikube -p $P cp "$KATA/src/runtime/containerd-shim-kata-v2" "$node:/home/docker/containerd-shim-kata-mig-v2"
  minikube -p $P cp "$(dirname "$0")/install-mig-shim-node.sh" "$node:/home/docker/install-mig-shim-node.sh"
  # Run a copied script: `minikube ssh` never closes stdin, so `bash -s` with a heredoc hangs.
  minikube -p $P ssh -n "$node" -- "sudo bash /home/docker/install-mig-shim-node.sh"
done

kubectl get runtimeclass kata-clh-mig >/dev/null 2>&1 || kubectl get runtimeclass kata-clh -o json |
  jq '.metadata = {name: "kata-clh-mig"} | .handler = "kata-clh-mig"' | kubectl apply -f -
kubectl get runtimeclass kata-clh-mig
