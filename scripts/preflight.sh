#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; load_config
c_step "Preflight"
need kubectl; need envsubst
kubectl cluster-info >/dev/null 2>&1 || { c_err "cannot reach a cluster (check KUBECONFIG)"; exit 1; }
c_ok "kubectl can reach $(kubectl config current-context)"

kubectl get node "$CPU_NODE" >/dev/null 2>&1 || { c_err "CPU_NODE '$CPU_NODE' not found"; kubectl get nodes; exit 1; }
c_ok "CPU node present: $CPU_NODE"

if [ -n "${GPU_NODE:-}" ]; then
  if kubectl get node "$GPU_NODE" >/dev/null 2>&1; then
    c_ok "GPU node present: $GPU_NODE"
    kubectl get runtimeclass nvidia >/dev/null 2>&1 \
      && c_ok "RuntimeClass 'nvidia' exists" \
      || c_warn "RuntimeClass 'nvidia' missing - GPU pods will fail. Applied by deploy.sh, but the node also needs the NVIDIA container toolkit configured in containerd."
  else
    c_err "GPU_NODE '$GPU_NODE' not found. Set GPU_NODE=\"\" to skip GPU workloads."; exit 1
  fi
else
  c_warn "GPU_NODE empty - GPU workloads will be skipped"
fi
c_ok "preflight passed"
