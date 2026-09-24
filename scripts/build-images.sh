#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; load_config
c_step "Building local images"
BUILDER="${BUILDER:-podman}"; need "$BUILDER"

# Three images aren't on any registry - they're built from source and imported
# straight into the node's containerd. Manifests use imagePullPolicy: Never.
build_and_import() { # <tag> <context-dir> <target-node>
  local tag="$1" ctx="$2" node="$3"
  if [ ! -d "$ctx" ]; then c_warn "skip $tag - source not found at $ctx"; return; fi
  c_ok "building $tag from $ctx"
  "$BUILDER" build -t "$tag" "$ctx"
  local tar; tar="$(mktemp -d)/img.tar"
  "$BUILDER" save "localhost/$tag" -o "$tar"
  if [ "$node" = "$(hostname)" ] || [ "${node}" = "local" ]; then
    sudo k3s ctr -n k8s.io images import "$tar"
  else
    c_ok "copying to $node"
    scp -q "$tar" "${REMOTE_USER:-$USER}@${node}:/tmp/img.tar"
    ssh "${REMOTE_USER:-$USER}@${node}" "sudo k3s ctr -n k8s.io images import /tmp/img.tar && rm -f /tmp/img.tar"
  fi
  rm -f "$tar"
  c_ok "$tag imported on $node"
}

build_and_import my-infer:local  "$MY_INFER_SRC"  local
build_and_import resume-ai:local "$RESUME_AI_SRC" local
if [ -n "${GPU_NODE:-}" ]; then
  # sd-webui is optional; ComfyUI is the better-supported image backend.
  build_and_import sd-webui:local "$SD_WEBUI_SRC" "${GPU_NODE_SSH:-$GPU_NODE}"
fi
