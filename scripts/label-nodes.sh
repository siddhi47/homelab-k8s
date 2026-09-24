#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; load_config
c_step "Labelling nodes"
# Manifests select on these labels instead of hostnames, so the same YAML
# works on any cluster.
kubectl label node "$CPU_NODE" homelab.local/cpu=true --overwrite >/dev/null
c_ok "$CPU_NODE  homelab.local/cpu=true"
if [ -n "${GPU_NODE:-}" ]; then
  kubectl label node "$GPU_NODE" homelab.local/gpu=true --overwrite >/dev/null
  c_ok "$GPU_NODE  homelab.local/gpu=true"
fi
