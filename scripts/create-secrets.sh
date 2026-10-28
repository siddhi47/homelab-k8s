#!/usr/bin/env bash
#   ./scripts/create-secrets.sh            all secrets
#   ./scripts/create-secrets.sh airflow    only airflow-secrets
#   ./scripts/create-secrets.sh grafana    only grafana-admin
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; load_config
ONLY="${1:-}"
c_step "Creating secrets"
SRC="$ROOT/secrets.env"
[ -f "$SRC" ] || { c_err "secrets.env not found. Run: cp secrets.env.example secrets.env"; exit 1; }
set -a; source "$SRC"; set +a

mk() { # mk <name>[@namespace] <KEY=VALUE>...
  local name="${1%@*}" ns=""; [[ "$1" == *@* ]] && ns="${1#*@}"; shift
  local args=()
  for kv in "$@"; do args+=(--from-literal="$kv"); done
  kubectl create secret generic "$name" ${ns:+-n "$ns"} "${args[@]}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  c_ok "$name${ns:+ in $ns} ($# keys)"
}

# Value from secrets.env, else the one already in the cluster, else generated.
# Keeps generated keys stable across re-runs.
keep_or_gen() { # keep_or_gen <secret>[@namespace] <key> <given> <generator...>
  local secret="${1%@*}" ns="" key="$2" given="$3"; [[ "$1" == *@* ]] && ns="${1#*@}"; shift 3
  if [ -n "$given" ]; then printf '%s' "$given"; return; fi
  local cur
  cur=$(kubectl get secret "$secret" ${ns:+-n "$ns"} -o "jsonpath={.data.$key}" 2>/dev/null | base64 -d 2>/dev/null || true)
  if [ -n "$cur" ]; then printf '%s' "$cur"; else "$@"; fi
}

mk_airflow() {
  if [ -z "${AIRFLOW_GIT_TOKEN:-}" ] || [ -z "${AIRFLOW_ADMIN_PASSWORD:-}" ]; then
    c_warn "airflow-secrets skipped: set AIRFLOW_GIT_TOKEN and AIRFLOW_ADMIN_PASSWORD in secrets.env"
    return
  fi
  mk airflow-secrets \
    "git-username=${AIRFLOW_GIT_USERNAME:-git}" \
    "git-token=${AIRFLOW_GIT_TOKEN}" \
    "admin-password=${AIRFLOW_ADMIN_PASSWORD}" \
    "postgres-password=$(keep_or_gen airflow-secrets postgres-password "${AIRFLOW_POSTGRES_PASSWORD:-}" openssl rand -hex 24)" \
    "fernet-key=$(keep_or_gen airflow-secrets fernet-key "${AIRFLOW_FERNET_KEY:-}" \
        python3 -c 'import base64,os;print(base64.urlsafe_b64encode(os.urandom(32)).decode(),end="")')" \
    "api-secret-key=$(keep_or_gen airflow-secrets api-secret-key "${AIRFLOW_API_SECRET_KEY:-}" openssl rand -hex 32)" \
    "jwt-secret=$(keep_or_gen airflow-secrets jwt-secret "${AIRFLOW_JWT_SECRET:-}" openssl rand -hex 32)"
  # Task pods run in airflow-tasks and can't read Secrets in default, so they
  # get their own copy of just the git credentials.
  kubectl create namespace airflow-tasks --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  mk airflow-git@airflow-tasks \
    "username=${AIRFLOW_GIT_USERNAME:-git}" \
    "token=${AIRFLOW_GIT_TOKEN}"
}

mk_grafana() {
  kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  mk grafana-admin@monitoring \
    "password=$(keep_or_gen grafana-admin@monitoring password "${GRAFANA_ADMIN_PASSWORD:-}" openssl rand -hex 16)"
}

if [ "$ONLY" = "grafana" ]; then
  mk_grafana
  c_warn "read it with: kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.password}' | base64 -d"
  exit 0
fi

if [ "$ONLY" = "airflow" ]; then
  mk_airflow
  c_warn "values were never printed; inspect with: kubectl describe secret airflow-secrets; kubectl -n airflow-tasks describe secret airflow-git"
  exit 0
fi

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
mk_airflow
mk_grafana
c_warn "values were never printed; inspect with: kubectl describe secret <name>"
