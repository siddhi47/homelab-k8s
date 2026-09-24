#!/usr/bin/env bash
# Deploy the homelab stack. Idempotent - safe to re-run.
#   ./deploy.sh              full deploy (cpu + gpu)
#   ./deploy.sh cpu          cpu workloads only
#   ./deploy.sh gpu          gpu workloads only
#   ./deploy.sh --dry-run    render + validate without applying
source "$(dirname "$0")/scripts/lib.sh"; load_config

TARGET="${1:-all}"; DRY=""
[ "${1:-}" = "--dry-run" ] && { TARGET=all; DRY="--dry-run=server"; }
[ "${2:-}" = "--dry-run" ] && DRY="--dry-run=server"

apply_dir() { # <dir>
  local dir="$1"
  [ -d "$dir" ] || return 0
  for f in $(ls "$dir"/*.yaml 2>/dev/null | sort); do
    if render "$f" | kubectl apply $DRY -f - >/dev/null 2>&1; then
      c_ok "$(basename "$f")"
    else
      c_err "$(basename "$f") failed:"
      render "$f" | kubectl apply $DRY -f - 2>&1 | sed 's/^/      /' || true
    fi
  done
}

"$ROOT/scripts/preflight.sh"
[ -n "$DRY" ] || "$ROOT/scripts/label-nodes.sh"

if [ "$TARGET" = "all" ] || [ "$TARGET" = "cpu" ]; then
  c_step "CPU workloads -> $CPU_NODE"
  apply_dir "$ROOT/manifests/cpu"
fi
if { [ "$TARGET" = "all" ] || [ "$TARGET" = "gpu" ]; } && [ -n "${GPU_NODE:-}" ]; then
  c_step "GPU workloads -> $GPU_NODE"
  apply_dir "$ROOT/manifests/gpu"
fi

[ -n "$DRY" ] && { c_step "dry-run complete - nothing applied"; exit 0; }

c_step "Waiting for rollouts"
for d in $(kubectl get deploy -o name 2>/dev/null); do
  name="${d#deployment.apps/}"
  if kubectl rollout status "$d" --timeout=180s >/dev/null 2>&1; then c_ok "$name"
  else c_warn "$name not ready yet - kubectl describe $d"; fi
done

c_step "Access"
kubectl get svc --no-headers 2>/dev/null | awk -v ip="${CLUSTER_IP:-<node-ip>}" '
  $5 ~ /:/ { split($5,p,":"); split(p[2],q,"/"); printf "  %-14s http://%s:%s\n", $1, ip, q[1] }'
echo
c_warn "GPU-node services may need tunnels instead of NodePort: sudo ./scripts/port-forwards.sh"
