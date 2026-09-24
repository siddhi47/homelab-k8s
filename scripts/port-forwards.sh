#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; load_config
c_step "Installing port-forward tunnels (systemd)"
# Only needed when the cluster network can't reach a node directly - e.g. a
# WSL2 node, where NodePort/ClusterIP are unreachable because kube-proxy uses
# iptables DNAT with no listening socket for WSL's mirrored networking to see.
# On a normal cluster you can skip this entirely and use NodePorts.
[ "$(id -u)" -eq 0 ] || { c_err "run with sudo"; exit 1; }
KCFG="${KUBECONFIG:-$HOME/.kube/config}"
RUN_AS="${SUDO_USER:-$USER}"
install_unit() { # <name> <deploy> <localport:targetport>
  local name="$1" dep="$2" ports="$3"
  cat > "/etc/systemd/system/${name}-portforward.service" <<UNIT
[Unit]
Description=kubectl port-forward for ${dep}
After=network.target

[Service]
Type=simple
User=${RUN_AS}
Environment=KUBECONFIG=${KCFG}
ExecStart=$(command -v kubectl) port-forward --address 0.0.0.0 deploy/${dep} ${ports}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
  systemctl enable --now "${name}-portforward.service" >/dev/null 2>&1
  c_ok "${name}-portforward.service -> ${ports}"
}
if [ -n "${GPU_NODE:-}" ]; then
  install_unit comfyui comfyui     8188:8188
  install_unit ollama  ollama      11435:11434
  install_unit jupyter jupyter-gpu 8899:8888
fi
systemctl daemon-reload
c_warn "these bind 0.0.0.0 with no auth - they go stale when a pod is replaced; restart the unit if a port stops responding"
