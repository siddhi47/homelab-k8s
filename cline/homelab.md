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

Mac inference server (10.0.0.35, reachable on localhost:11434 through the tunnel).
`OLLAMA_MAX_LOADED_MODELS=2` and `OLLAMA_KEEP_ALIVE=-1`, so two models stay resident
indefinitely:

| Model | Resident | Vision | Tools |
|---|---|---|---|
| `qwen3:32b` | 31.4 GB @ 40k ctx | no | yes |
| `qwen3.5:4b` | 5.9 GB @ 64k ctx | **yes** | yes |
| `qwen3-coder:30b` | 25 GB (not resident) | no | yes |

That is 37.2 GB of a 38.3 GB Metal working-set budget, so roughly 1 GB spare. A
request for `qwen3-coder:30b` must evict something and costs a full reload (~72s).
If tool calls or chat suddenly feel slow, check `/api/ps` before suspecting anything
else.

Measured on this hardware:

| | prompt eval | generation |
|---|---|---|
| `qwen3:32b` (dense) | 163 tok/s | 22 tok/s |
| `qwen3-coder:30b` (MoE, ~3B active) | 841 tok/s | 75 tok/s |

The MoE model reads five times faster. That matters most for tool-heavy chat, where
tool schemas dominate the prompt: five attached tool servers are about 16k tokens of
schema on *every* message, which is ~98s of prompt eval on the dense model versus
~19s on the MoE. Attach only the tools a conversation needs.

Only `qwen3.5:4b` and `medgemma1.5` accept images. `qwen3:32b` rejects any request
carrying image data outright ("model does not support multimodal requests"), so
image editing in Open WebUI must use the 4B even though ComfyUI does the actual
work — Open WebUI attaches the image to the chat request, not only to the tool.

The GPU node has 6 GB of VRAM and runs small models plus image generation only.
