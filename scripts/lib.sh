#!/usr/bin/env bash
# Shared helpers. Sourced by the other scripts.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
c_ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
c_warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
c_err()  { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; }
c_step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

load_config() {
  [ -f "$ROOT/config.env" ] || { c_err "config.env not found. Run: cp config.env.example config.env"; exit 1; }
  # shellcheck disable=SC1090
  set -a; source "$ROOT/config.env"; set +a
  : "${DATA_ROOT:?}" "${CPU_NODE:?}"
  export DATA_ROOT CPU_NODE GPU_NODE CLUSTER_IP
}

need() { command -v "$1" >/dev/null 2>&1 || { c_err "required command not found: $1"; exit 1; }; }

# Render a manifest, substituting ONLY our own variables. Restricting the list
# matters: some manifests embed shell scripts full of $(...) and \$VAR that
# must be left untouched.
render() { envsubst '${DATA_ROOT} ${CLUSTER_IP}' < "$1"; }
