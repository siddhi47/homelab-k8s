#!/usr/bin/env bash
# Remove the workloads. Does NOT touch hostPath data or secrets by default.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; load_config
c_step "Teardown"
read -rp "  Delete all homelab deployments/services? [y/N] " a
[ "$a" = "y" ] || { echo "  aborted"; exit 0; }
for f in "$ROOT"/manifests/*/*.yaml; do
  render "$f" | kubectl delete --ignore-not-found -f - >/dev/null 2>&1 && c_ok "$(basename "$f")"
done
c_warn "secrets kept (delete: kubectl delete secret my-secrets resume-ai-secrets jupyter-token)"
c_warn "hostPath data under \$DATA_ROOT on each node kept - remove manually if wanted"
