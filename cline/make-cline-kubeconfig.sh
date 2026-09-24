#!/usr/bin/env bash
# Build a kubeconfig for the `cline` ServiceAccount, pointed at the local end of
# the SSH tunnel (127.0.0.1:6443) rather than at the NUC's LAN address.
#
# Run this ON THE NUC, after `kubectl apply -f cline-rbac.yaml`:
#
#     ./make-cline-kubeconfig.sh                 # -> ./kubeconfig-cline.yaml
#     ./make-cline-kubeconfig.sh /tmp/kc.yaml    # -> custom path
#
# Then copy it to the Mac:
#
#     scp kubeconfig-cline.yaml <you>@10.0.0.206:~/.kube/config-homelab
#
# Why 127.0.0.1 and not 10.0.0.132: the k3s API certificate lists both
#   IP Address:127.0.0.1, IP Address:10.0.0.132, DNS:localhost
# so a tunnelled localhost connection validates TLS normally. No
# insecure-skip-tls-verify, no cert warnings.

set -euo pipefail

NS=default
SECRET=cline-token
OUT="${1:-$(pwd)/kubeconfig-cline.yaml}"
SERVER="${SERVER:-https://127.0.0.1:6443}"

if ! kubectl -n "$NS" get secret "$SECRET" >/dev/null 2>&1; then
  echo "error: secret $NS/$SECRET not found — run 'kubectl apply -f cline-rbac.yaml' first" >&2
  exit 1
fi

# The token Secret is populated asynchronously by the token controller.
for _ in $(seq 1 20); do
  TOKEN_B64="$(kubectl -n "$NS" get secret "$SECRET" -o jsonpath='{.data.token}' 2>/dev/null || true)"
  [ -n "$TOKEN_B64" ] && break
  sleep 1
done
if [ -z "${TOKEN_B64:-}" ]; then
  echo "error: token never populated in $NS/$SECRET" >&2
  exit 1
fi

CA_B64="$(kubectl -n "$NS" get secret "$SECRET" -o jsonpath='{.data.ca\.crt}')"

umask 077
cat > "$OUT" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: homelab
    cluster:
      server: ${SERVER}
      certificate-authority-data: ${CA_B64}
users:
  - name: cline
    user:
      token: $(printf '%s' "$TOKEN_B64" | base64 -d)
contexts:
  - name: homelab
    context:
      cluster: homelab
      user: cline
      namespace: default
current-context: homelab
EOF
chmod 600 "$OUT"

echo "wrote $OUT (mode 600)"
echo
echo "This file contains a bearer token. It is read-only (ClusterRole 'view'),"
echo "but still treat it as a credential: do not commit it."
echo
echo "Verify from the Mac, with the tunnel up:"
echo "  KUBECONFIG=~/.kube/config-homelab kubectl get pods -A"
