# ComfyUI assets

## workflows/mage-flow-edit.api.json

The Mage-Flow-Edit blueprint, flattened into ComfyUI **API format** so Open WebUI
can drive it as its image-edit workflow (`images.edit.comfyui.workflow`).

ComfyUI ships this as a *subgraph* blueprint — one node at the top level wrapping
15 inner nodes. Subgraph form cannot be submitted to `/prompt`, and Open WebUI needs
a flat graph whose node ids it can address. This file is the flattened equivalent:
the three `ComfySwitchNode`s are driven by constant `PrimitiveBoolean` inputs, so
they resolve statically to "use the scaled image" and "take width/height from the
image", collapsing 15 nodes to 10.

Two things that are easy to get wrong here:

- **The autogrow image input must use dot notation.** Write
  `"images.image_1": ["2", 0]`, not `"images": {"image_1": ["2", 0]}`. ComfyUI
  accepts the nested form, validates it, and runs to `success` — but the node never
  receives the image, so output is generated from the prompt alone with no source
  conditioning. It fails silently and looks like a bad model rather than a bad graph.
- **Width and height are intentionally unmapped** in Open WebUI's node mapping. The
  graph derives them from `GetImageSize` on the scaled input, which preserves the
  source aspect ratio. Mapping them forces Open WebUI's defaults onto every edit.

Required models (not committed - tens of gigabytes, fetch from HuggingFace
`Comfy-Org/Mage-Flow`):

| Path under `models/` | File | Size |
|---|---|---|
| `diffusion_models/` | `mage_flow_edit_int8_convrot.safetensors` | 4.16 GB |
| `text_encoders/` | `qwen3vl_4b_bf16.safetensors` | 8.88 GB |
| `vae/` | `mage_flow_vae_bf16.safetensors` | 0.35 GB |

Runs on a 6GB RTX 3060 Laptop at roughly two minutes per 1MP edit.

Prompts should be short imperatives — "shorter hair", "dark clothes". Long prompts
with preservation clauses ("keep the face unchanged") work against the model: naming
a feature pulls it into the conditioning and invites regeneration.
