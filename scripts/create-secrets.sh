#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; load_config
c_step "Creating secrets"
SRC="$ROOT/secrets.env"
[ -f "$SRC" ] || { c_err "secrets.env not found. Run: cp secrets.env.example secrets.env"; exit 1; }
set -a; source "$SRC"; set +a

mk() { # mk <name> <KEY=VALUE>...
  local name="$1"; shift
  local args=()
  for kv in "$@"; do args+=(--from-literal="$kv"); done
  kubectl create secret generic "$name" "${args[@]}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  c_ok "$name ($# keys)"
}

mk my-secrets \
  "OPENAI_API_KEY=${OPENAI_API_KEY:-}" \
  "LANGSMITH_API_KEY=${LANGSMITH_API_KEY:-}" \
  "LANGSMITH_PROJECT=${LANGSMITH_PROJECT:-}" \
  "LANGSMITH_TRACING=${LANGSMITH_TRACING:-false}" \
  "LANGSMITH_ENDPOINT=${LANGSMITH_ENDPOINT:-}"

mk resume-ai-secrets \
  "OPENAI_API_KEY=${OPENAI_API_KEY:-}" \
  "SECRET_KEY=${SECRET_KEY:-}" \
  "GITHUB_PERSONAL_ACCESS_TOKEN=${GITHUB_PERSONAL_ACCESS_TOKEN:-}" \
  "GITHUB_MCP_MODE=${GITHUB_MCP_MODE:-hosted}" \
  "GITHUB_USERNAME=${GITHUB_USERNAME:-}" \
  "LANGSMITH_API_KEY=${LANGSMITH_API_KEY:-}" \
  "LANGSMITH_PROJECT=${LANGSMITH_PROJECT:-}" \
  "LANGSMITH_TRACING=${LANGSMITH_TRACING:-false}" \
  "LANGSMITH_ENDPOINT=${LANGSMITH_ENDPOINT:-}"

if [ -n "${GPU_NODE:-}" ]; then
  mk jupyter-token "token=${JUPYTER_TOKEN:-}"
fi
c_warn "values were never printed; inspect with: kubectl describe secret <name>"
