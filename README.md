# homelab-k8s

Deployable bundle for the homelab stack: LLM serving, image generation, notebooks,
two Flask apps and a self-hosted search engine, across a CPU node and an optional
GPU node.

```
./deploy.sh                 # deploy everything
./deploy.sh cpu             # CPU workloads only
./deploy.sh gpu             # GPU workloads only
./deploy.sh --dry-run       # validate server-side, apply nothing
```

## Quick start on a fresh cluster

```bash
git clone <this repo> && cd homelab-k8s

cp config.env.example config.env    && $EDITOR config.env     # node names, paths
cp secrets.env.example secrets.env  && $EDITOR secrets.env    # API keys

./deploy.sh --dry-run               # sanity check first
./scripts/create-secrets.sh
./scripts/build-images.sh           # only if you want my-infer/resume-ai/sd-webui
./deploy.sh
```

`config.env` and `secrets.env` are gitignored. Nothing in `manifests/` contains a
credential or a machine-specific hostname.

## What gets deployed

| Workload | Node | Port | What it is |
|---|---|---|---|
| `my-infer` | cpu | 32050 | RAG chatbot (Flask + LangChain + Chroma) |
| `resume-ai` | cpu | 30505 | Resume/cover-letter generator (Flask + tectonic) |
| `open-webui` | cpu | 30880 | Chat UI in front of Ollama |
| `searxng` | cpu | 30081 | Self-hosted metasearch, backs Open WebUI's web search |
| `ollama` | gpu | 30434 | LLM serving |
| `comfyui` | gpu | 30188 | Image generation (node-graph; handles SDXL/Flux/Z-Image) |
| `sd-webui` | gpu | 30860 | AUTOMATIC1111 (optional; ComfyUI is the better backend) |
| `jupyter-gpu` | gpu | 30888 | Notebooks with CUDA |

## How portability works

The manifests are generic. Two things make them so:

**Node selection by label, not hostname.** Manifests select
`homelab.local/cpu=true` / `homelab.local/gpu=true`. `deploy.sh` applies those
labels to whichever nodes you named in `config.env`, so the YAML never mentions a
machine. Set `GPU_NODE=""` to skip GPU workloads entirely on a CPU-only cluster.

**Storage via `${DATA_ROOT}`.** hostPath volumes are rendered at apply time with
`envsubst`, restricted to that single variable — several manifests embed shell
scripts full of `$(...)` and `\$VAR` that must survive untouched.

## Prerequisites

- A working `kubectl` context (`kubectl cluster-info`)
- `envsubst` (coreutils/gettext)
- For GPU workloads: NVIDIA drivers **and** the NVIDIA container toolkit wired into
  the node's containerd, so that `RuntimeClass: nvidia` resolves. `preflight.sh`
  warns if the RuntimeClass is missing but cannot verify the toolkit itself.
- For `build-images.sh`: `podman` (or set `BUILDER=docker`) and the app sources.

## Storage

hostPath, not PVCs — deliberately. These workloads hold tens of GB of models and
are pinned to specific nodes anyway, so a local path is simpler and faster than a
provisioner. The consequence: **data lives on the node, and moving a pod to a
different node does not move its data.**

Directories created under `$DATA_ROOT`:

```
ollama-data/      pulled LLM weights (tens of GB)
comfyui-data/     ComfyUI venv (run/) + models, outputs, custom nodes (basedir/)
sd-webui-data/    A1111 checkpoints, VAEs, extensions, config
jupyter-data/     notebooks and the persistent kernel venv
open-webui-data/  webui.db - accounts, chat history, settings
resume-ai-data/   agent checkpoint sqlite + generated PDFs
```

ComfyUI additionally mounts `sd-webui-data/models` **read-only**, so both image
backends share one copy of every checkpoint instead of duplicating them.

To migrate a node, `rsync` the relevant directory and re-label.

## Locally-built images

Three images aren't on any registry. They're built from source and imported
straight into the node's containerd, and their manifests use
`imagePullPolicy: Never`:

| Image | Source (`config.env`) |
|---|---|
| `my-infer:local` | `MY_INFER_SRC` |
| `resume-ai:local` | `RESUME_AI_SRC` |
| `sd-webui:local` | `SD_WEBUI_SRC` |

`build-images.sh` builds, `podman save`s, and imports them — over SSH if the
target is a remote node. Skip it if you only want the registry-backed workloads
(ollama, comfyui, open-webui, searxng, jupyter).

## Networking note (read this if services are unreachable)

On a normal cluster, NodePort works and you can ignore `port-forwards.sh`.

This stack was built against a GPU node running **WSL2 in mirrored networking
mode**, where NodePort, ClusterIP and pod IPs are all unreachable from other
machines. Cause: kube-proxy implements NodePorts as iptables DNAT rules with no
listening socket, and WSL's mirrored mode only forwards ports it can see an actual
socket for. Kubelet's 10250 works precisely because it *is* a real socket.

The workaround is `scripts/port-forwards.sh`, which installs systemd units running
`kubectl port-forward` — that tunnels via the API server and sidesteps the problem.
Those units **go stale when their target pod is replaced**; if a port stops
responding while the pod is healthy, restart the unit:

```bash
sudo systemctl restart comfyui-portforward.service
```

Alternatives if you hit this: run the pod with `hostNetwork: true` (gives it a real
socket), or use a cluster whose nodes aren't behind WSL.

## Secrets

`create-secrets.sh` reads `secrets.env` and creates three secrets, never echoing
values:

- `my-secrets` - OpenAI + LangSmith, for `my-infer`
- `resume-ai-secrets` - OpenAI, Flask `SECRET_KEY`, GitHub PAT, LangSmith
- `jupyter-token` - the Jupyter login token

Re-running is safe; it applies over the existing secrets. Verify with
`kubectl describe secret <name>` (shows key names and sizes, not values).

## Teardown

```bash
./scripts/teardown.sh
```

Deletes deployments and services after confirmation. Deliberately leaves secrets
and hostPath data alone — remove those by hand if you really mean it.

## Open WebUI: configuration lives in two places

The manifest is only half of it. Open WebUI keeps nearly all settings — model
endpoints, tool servers, image generation, task models, web search — in a `config`
table inside `webui.db` on its data volume, not in environment variables.
Environment variables are *PersistentConfig*: they seed the database on first boot
and are ignored from then on, because the stored value wins.

So `kubectl apply -f manifests/cpu/open-webui.yaml` on a fresh cluster produces a
working but unconfigured install. Restore the other half with:

```sh
./scripts/open-webui-config.sh restore open-webui-config.json
kubectl rollout restart deploy/open-webui
```

`open-webui-config.json` in this repo is redacted — keys that look like credentials
are replaced with `__REDACTED__` and skipped on restore. Re-enter those afterwards
(the ComfyUI API token is the one that matters here). To take a full backup for
yourself:

```sh
./scripts/open-webui-config.sh export --with-secrets   # gitignored
```
