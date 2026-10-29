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
| `registry` | cpu | 30500 | Container registry; nodes pull images pushed here |
| `airflow-api-server` | cpu | 30808 | Airflow 3 UI/API (+ `airflow-scheduler`, `airflow-postgres`) |
| `grafana` | cpu | 30300 | Dashboards (namespace `monitoring`) |
| `prometheus` | cpu | 30909 | Metrics, 15 days (+ `node-exporter` on every node, `kube-state-metrics`) |
| `loki` | cpu | - | Container logs, 15 days (+ `alloy` on every node); query in Grafana |
| `gpu-exporter` | gpu | - | GPU utilization/memory/temperature for Prometheus |
| `ollama` | gpu | 30434 | LLM serving |
| `comfyui` | gpu | 30188 | Image generation (node-graph; handles SDXL/Flux/Z-Image) |
| `sd-webui` | gpu | 30860 | AUTOMATIC1111 (optional; ComfyUI is the better backend) |
| `jupyter-gpu` | gpu | 30888 | Notebooks with CUDA |

## How portability works

The manifests are generic. Two things make them so:

**Node selection by label, not hostname.** Manifests select
`homelab.local/cpu=true` / `homelab.local/gpu=true` (and `homelab.local/pi=true`
for the optional Raspberry Pi). `deploy.sh` applies those
labels to whichever nodes you named in `config.env`, so the YAML never mentions a
machine. Set `GPU_NODE=""` to skip GPU workloads entirely on a CPU-only cluster.

**Storage via `${DATA_ROOT}`.** hostPath volumes are rendered at apply time with
`envsubst`, restricted to that single variable — several manifests embed shell
scripts full of `$(...)` and `\$VAR` that must survive untouched.

## Adding a node (Raspberry Pi example)

Nodes join over Tailscale: flannel runs on `tailscale0` and every node's
`node-ip` is its Tailscale address, so the same steps work whether the node is
on the LAN or not. This is how `rpik8` (Pi 4, 8 GB, arm64) was added.

1. **Flash Raspberry Pi OS Lite (64-bit).** Pi OS configures itself on first
   boot from cloud-init files on the boot partition. If Imager's settings
   weren't applied, `user-data` and `network-config` are only comments and the
   Pi boots with no Wi-Fi and no SSH. Fill them in by hand: a user with your
   SSH key, `enable_ssh: true`, and a netplan `wifis:` entry with
   `regulatory-domain`.
2. **Memory cgroups:** append `cgroup_memory=1 cgroup_enable=memory` to the
   single line in `/boot/firmware/cmdline.txt`, or the k3s agent won't start.
3. **Tailscale**, from its apt repo (pkgs.tailscale.com/stable/debian), then
   `sudo tailscale up --hostname=<name>` and approve the login link.
4. **k3s agent, same version as the server.** Put the node settings in
   `/etc/rancher/k3s/config.yaml` only, not also as installer flags:
   ```
   node-ip: <tailscale ip>
   flannel-iface: tailscale0
   ```
   then install with `INSTALL_K3S_VERSION=<server version>`,
   `K3S_URL=https://<server tailscale ip>:6443` and the token from
   `/var/lib/rancher/k3s/server/node-token` on the server.
5. **Registry:** `ssh <node> 'sudo bash -s <registry>' < scripts/registry-node-setup.sh`.
6. **Label:** set `PI_NODE` in `config.env` and run `./scripts/label-nodes.sh`.
7. **Optional, keep k3s writes off the SD card.** On `rpik8`, a USB stick
   (ext4, label `k3sdata`) is mounted at `/mnt/k3sdata`, with
   `/var/lib/rancher` and `/var/lib/kubelet` bind-mounted from it via
   `/etc/fstab` (all `nofail`). A `k3s-agent.service.d` drop-in with
   `RequiresMountsFor=/var/lib/rancher /var/lib/kubelet` keeps k3s from
   starting on the empty SD-card directories if the stick is missing.

Only workloads that select `homelab.local/pi=true` are placed on the Pi, apart
from DaemonSets (node-exporter, the k3s load balancer) and unpinned system
pods, all of which have arm64 images. Images built on the NUC are amd64-only
and can't run there.

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
airflow-data/     postgres/ (metadata DB) and logs/ (task logs)
registry-data/    pushed container images
prometheus-data/  metrics (15 days, capped at 10 GB)
grafana-data/     grafana.db - users, saved dashboards; dashboards/ (downloaded)
loki-data/        logs (15 days, no size cap)
alloy-data/       Alloy's read positions in /var/log/pods (every node)
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

## Container registry

`manifests/cpu/registry.yaml` runs a plain registry (CNCF Distribution) on
port 30500. Build and push from your machine, then reference the image from any
manifest or DAG:

```bash
./scripts/build-images.sh push training:3f2a1c9 ~/git/training
#   -> 10.0.0.132:30500/training:3f2a1c9
```

**One-time setup on every node**, or pulls fail with *"server gave HTTP
response to HTTPS client"*. Image pulls are done by each node's containerd,
which expects HTTPS; this marks the registry as plain HTTP and restarts k3s:

```bash
sudo ./scripts/registry-node-setup.sh 10.0.0.132:30500                          # CPU node
ssh <gpu-node> 'sudo bash -s 10.0.0.132:30500' < scripts/registry-node-setup.sh  # GPU node
```

No auth and no TLS, so treat it as LAN-only. Deleting a tag doesn't free disk
space; see the garbage-collect command in the manifest.

The three images built by `build-images.sh` (no arguments) still go through
`podman save` and an import into containerd, and their manifests keep
`imagePullPolicy: Never`. Moving them to the registry is a separate change.

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
- `grafana-admin` (namespace `monitoring`) - Grafana's `admin` password,
  generated unless `GRAFANA_ADMIN_PASSWORD` is set. Read it with
  `kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.password}' | base64 -d`
- `airflow-secrets` - git-sync credentials, the `admin` UI password, and the
  Postgres password / Fernet key / API + JWT secrets. The last four are generated
  on first run and kept on re-runs; `./scripts/create-secrets.sh airflow` touches
  only this secret.

Re-running is safe; it applies over the existing secrets. Verify with
`kubectl describe secret <name>` (shows key names and sizes, not values).

## Teardown

```bash
./scripts/teardown.sh
```

Deletes deployments and services after confirmation. Deliberately leaves secrets
and hostPath data alone — remove those by hand if you really mean it.

## Airflow

Airflow 3.3 with KubernetesExecutor — `manifests/cpu/airflow.yaml` explains the
layout. The scheduler, dag-processor and triggerer run in `default`; **every task
runs in its own pod in the `airflow-tasks` namespace** (`hello-say-xxxx`), which
is deleted on success and kept on failure for `kubectl -n airflow-tasks logs`.

DAGs come from git: set `AIRFLOW_DAGS_REPO` / `_BRANCH` / `_SUBDIR` in
`config.env`, and `AIRFLOW_GIT_TOKEN` (a read-only PAT) in `secrets.env`. A push
shows up in the UI within about two minutes. Task pods clone the repo at start,
so they always run the latest commit. The branch needs at least one commit or
the scheduler pod stays in `Init`.

Log in at `http://<node>:30808` as `admin`.

Task pods default to the CPU node, `apache/airflow:3.3.2`, 1 GiB memory. Override
per task — a different image (for extra Python packages), more memory, or the GPU:

```python
from kubernetes.client import models as k8s

@task(executor_config={"pod_override": k8s.V1Pod(spec=k8s.V1PodSpec(
    runtime_class_name="nvidia",
    node_selector={"homelab.local/gpu": "true"},
    containers=[k8s.V1Container(
        name="base",                      # must be "base"
        image="my-airflow-gpu:latest",    # FROM apache/airflow:3.3.2 + your deps
        resources=k8s.V1ResourceRequirements(limits={"memory": "8Gi"}),
    )],
))})
def train(): ...
```

A task placed on the GPU node writes its log to that node's disk: the UI shows
it while the task runs, not after.

## Monitoring

Prometheus and Grafana as plain manifests, no operator. See the header of
`manifests/cpu/monitoring.yaml`. Grafana is at `http://<node>:30300`, user
`admin`. The **Homelab** folder holds these dashboards, downloaded from
grafana.com on each Grafana start:

| Dashboard | Shows |
|---|---|
| Node Exporter Full | one node in depth: CPU, memory, disks, network |
| Kubernetes / Views / Global, Nodes, Namespaces, Pods | cluster down to a single pod's CPU/memory |
| Nvidia GPU Metrics | the GPU node's card: utilization, VRAM, temperature, power |

To have Prometheus scrape your own app, add `prometheus.io/scrape: "true"` and
`prometheus.io/port` annotations to its pod template.

Logs from every container go to Loki (`manifests/cpu/loki.yaml`) via Alloy;
nothing to add per app. In Grafana use Explore -> Loki, e.g.
`{namespace="airflow-tasks"} |= "error"`, or Drilldown -> Logs to browse.

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
