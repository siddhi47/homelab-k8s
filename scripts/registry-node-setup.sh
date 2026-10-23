#!/usr/bin/env bash
# Point a node's containerd at the in-cluster registry (manifests/cpu/registry.yaml).
# Run ON EACH NODE, as root. Standalone - doesn't need the repo or config.env,
# so it can be copied to the GPU node:
#
#   sudo ./scripts/registry-node-setup.sh 10.0.0.132:30500
#   ssh gpu-node 'sudo bash -s 10.0.0.132:30500' < scripts/registry-node-setup.sh
#
# Writes /etc/rancher/k3s/registries.yaml marking the registry as plain HTTP,
# then restarts k3s (server) or k3s-agent. Running pods are not affected by
# the restart; the node shows NotReady for a few seconds.
set -euo pipefail
REG="${1:?usage: $0 <host:port>   e.g. 10.0.0.132:30500}"
FILE=/etc/rancher/k3s/registries.yaml
[ "$(id -u)" = 0 ] || { echo "run as root (sudo)" >&2; exit 1; }

WANT="# Managed by homelab-k8s scripts/registry-node-setup.sh
mirrors:
  \"$REG\":
    endpoint:
      - \"http://$REG\"
"

mkdir -p "$(dirname "$FILE")"
if [ -f "$FILE" ]; then
  if [ "$(cat "$FILE")" = "$(printf '%s' "$WANT")" ]; then
    echo "  $FILE already configured for $REG"
  elif grep -q "Managed by homelab-k8s" "$FILE"; then
    printf '%s' "$WANT" > "$FILE"; echo "  updated $FILE"
  else
    # Someone else's config - don't clobber it.
    echo "  $FILE exists and wasn't written by this script. Add this under mirrors: by hand:" >&2
    printf '%s' "$WANT" | sed -n '/^  "/,$p' >&2
    exit 1
  fi
else
  printf '%s' "$WANT" > "$FILE"; echo "  wrote $FILE"
fi

if systemctl list-unit-files k3s.service >/dev/null 2>&1 && systemctl is-enabled -q k3s 2>/dev/null; then
  svc=k3s
else
  svc=k3s-agent
fi
echo "  restarting $svc"
systemctl restart "$svc"
echo "  done - containerd will now pull from http://$REG"
