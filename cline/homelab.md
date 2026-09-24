# Homelab infrastructure

Install this as a **global** Cline rule (it applies to every repo, not one project):

    ~/Documents/Cline/Rules/homelab.md

---

Everything in this homelab runs on a **k3s cluster**, not on the local machine and
not in plain Docker. If you are debugging why a service behaves a certain way, the
answer is usually in the cluster, not in the working copy on disk.

## Nodes

| Node | Address | Role |
|---|---|---|
| `i8labs-nuc11pahi7` | 10.0.0.132 | k3s control-plane. Runs the CPU workloads. |
| `win-nuc-gpu` | 10.0.0.24 | WSL2 on a Windows laptop, RTX 3060 6GB. Runs the GPU workloads. |
| Mac inference server | 10.0.0.35 | **Not in the cluster.** Plain Ollama on an M4 Max 48GB. |

## Reaching the cluster from this machine

This Mac talks to the cluster over an SSH tunnel (launchd job `com.homelab.tunnel`),
because processes spawned by VS Code are blocked from the local subnet by the macOS
per-app Network Extension policy. **Always use `127.0.0.1` and the ports below. Never
use 10.0.0.x directly — it will hang or return "No route to host", and that failure is
the network policy, not the service being down.**

| Local port | Service |
|---|---|
| 6443 | k3s API server |
| 30880 | Open WebUI |
| 30081 | SearXNG |
| 30505 | resume-ai (the resume bot) |
| 8188 | ComfyUI |
| 11435 | Ollama on the GPU node |
| 11434 | Ollama on the Mac inference server (`qwen3-coder:30b`) |

If a port is refusing connections, check the tunnel before suspecting the service:

    launchctl print gui/$(id -u)/com.homelab.tunnel | head -20
    tail -20 ~/Library/Logs/homelab-tunnel.err

## kubectl

    export KUBECONFIG=~/.kube/config-homelab      # context: homelab

This kubeconfig is a **read-only** ServiceAccount (ClusterRole `view`). You can
`get`, `list`, `describe`, and read `logs`. You **cannot** read secrets, `exec` into
pods, `port-forward`, or change anything. Do not attempt writes and do not suggest
working around this — if a change to the cluster is needed, describe the exact
command and let the human run it.

## Cluster facts that are not obvious from the code

- **The pod overlay between the two nodes is broken** (flannel/WireGuard, stale
  peers, zero handshakes). Consequences: NodePorts for GPU-node services do not
  answer on the NUC, and cross-node pod-to-pod traffic does not work. The workaround
  is `kubectl port-forward` systemd units on the NUC (that is why ComfyUI is on 8188
  and GPU Ollama on 11435 rather than their NodePorts). Do not "fix" a service by
  pointing it at a cross-node ClusterIP or NodePort; route it through a forward, or
  through a node's LAN address.
- **Application code is baked into images.** hostPath mounts carry *data* only. Editing
  a source file in a working copy changes nothing in the cluster until the image is
  rebuilt and the deployment rolled out. If behaviour does not match the source, check
  the running image first.
- **Never mount a hostPath over `/app`** in these manifests — it shadows the code in
  the image.
- **Probe timeouts must exceed the slowest real request.** LLM generation can take
  minutes; a short `timeoutSeconds` kills the pod mid-request and presents as a crash
  loop rather than a timeout.

## Models

- Mac (10.0.0.35, via localhost:11434): `qwen3-coder:30b` and `qwen3:32b`, but
  `OLLAMA_MAX_LOADED_MODELS=1` and they are ~20GB each, so **only one is resident at a
  time**. Requesting the other evicts the first and costs a ~9s reload. `qwen3-coder`
  is pinned resident with `OLLAMA_KEEP_ALIVE=-1` at a 64k context.
- Measured throughput on the Mac: ~840 tok/s prompt processing, ~75 tok/s generation.
  A 13k-token request takes ~20s, nearly all of it prompt processing. Keep context
  tight; it is the dominant cost.
- The GPU node has 6GB of VRAM. It runs small models and image generation only.
