#!/usr/bin/env bash
# Install a persistent autossh tunnel from a Mac to the homelab NUC.
#
# Run this ON THE MAC (i8firmware), not on the NUC:
#
#     ./install-tunnel-macos.sh
#
# Why a tunnel at all, when the NUC is right there on the LAN: processes spawned
# by VS Code inherit VS Code's "responsible process" attribution on macOS, and the
# per-app Network Extension policy blocks them from the local subnet. A plain
# Terminal can reach 10.0.0.132 while Cline cannot. SSH out (which is permitted)
# and every forwarded port becomes a 127.0.0.1 port that VS Code may use.
#
# autossh, not plain ssh: it detects a dead session and rebuilds it. launchd's
# KeepAlive alone restarts the *process*, but a half-open TCP session can survive
# a laptop sleep/wake looking alive while forwarding nothing.

set -euo pipefail

NUC_USER="${NUC_USER:-i8labs}"
NUC_HOST="${NUC_HOST:-10.0.0.132}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
LABEL="com.homelab.tunnel"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"

# local:remote_host:remote_port — remote_host is resolved *on the NUC*
FORWARDS=(
  "6443:127.0.0.1:6443"     # k3s API server
  "30880:127.0.0.1:30880"   # Open WebUI      (NodePort)
  "30081:127.0.0.1:30081"   # SearXNG         (NodePort)
  "30505:127.0.0.1:30505"   # resume-ai       (NodePort)
  "8188:127.0.0.1:8188"     # ComfyUI         (via NUC kubectl port-forward)
  "11435:127.0.0.1:11435"   # Ollama on GPU   (via NUC kubectl port-forward)
  # Ollama on the Mac inference server is intentionally NOT here — you already
  # have a tunnel binding 11434. To consolidate into this one unit, stop that
  # tunnel and uncomment:
  # "11434:10.0.0.35:11434"
)

AUTOSSH="$(command -v autossh || true)"
if [ -z "$AUTOSSH" ]; then
  echo "autossh not found. Install it with:  brew install autossh" >&2
  exit 1
fi
[ -f "$SSH_KEY" ] || { echo "ssh key not found: $SSH_KEY" >&2; exit 1; }

echo "Testing SSH to ${NUC_USER}@${NUC_HOST} ..."
if ! ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=accept-new \
        "${NUC_USER}@${NUC_HOST}" true 2>/dev/null; then
  echo "error: key-based SSH to ${NUC_USER}@${NUC_HOST} failed." >&2
  echo "       Add $(basename "$SSH_KEY").pub to the NUC's ~/.ssh/authorized_keys first." >&2
  exit 1
fi
echo "  ok"

args=()
for f in "${FORWARDS[@]}"; do args+=("      <string>-L</string>" "      <string>${f}</string>"); done

mkdir -p "$HOME/Library/LaunchAgents"
{
  cat <<'HEAD'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
HEAD
  echo "    <key>Label</key><string>${LABEL}</string>"
  echo "    <key>ProgramArguments</key>"
  echo "    <array>"
  echo "      <string>${AUTOSSH}</string>"
  # -M 0 disables autossh's own echo port; ServerAlive* is the modern way.
  echo "      <string>-M</string><string>0</string>"
  echo "      <string>-N</string>"
  echo "      <string>-i</string><string>${SSH_KEY}</string>"
  echo "      <string>-o</string><string>ServerAliveInterval=15</string>"
  echo "      <string>-o</string><string>ServerAliveCountMax=3</string>"
  echo "      <string>-o</string><string>ExitOnForwardFailure=yes</string>"
  echo "      <string>-o</string><string>StrictHostKeyChecking=accept-new</string>"
  echo "      <string>-o</string><string>BatchMode=yes</string>"
  printf '%s\n' "${args[@]}"
  echo "      <string>${NUC_USER}@${NUC_HOST}</string>"
  echo "    </array>"
  cat <<TAIL
    <key>EnvironmentVariables</key>
    <dict>
      <!-- 0 = never give up, even if the very first connection fails (boot/wake
           ordering means the network may not be up yet). -->
      <key>AUTOSSH_GATETIME</key><string>0</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>${HOME}/Library/Logs/homelab-tunnel.log</string>
    <key>StandardErrorPath</key><string>${HOME}/Library/Logs/homelab-tunnel.err</string>
</dict>
</plist>
TAIL
} > "$PLIST"

launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "gui/$(id -u)/${LABEL}"

echo "installed: $PLIST"
sleep 4
echo
echo "Listening locally:"
for f in "${FORWARDS[@]}"; do
  p="${f%%:*}"
  if nc -z 127.0.0.1 "$p" 2>/dev/null; then echo "  127.0.0.1:$p  up"; else echo "  127.0.0.1:$p  DOWN"; fi
done
echo
echo "Logs: ~/Library/Logs/homelab-tunnel.err"
echo "Note: this is a LaunchAgent — it starts at login, not at boot."
