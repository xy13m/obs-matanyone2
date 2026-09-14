#!/usr/bin/env bash
# Exports the six MatAnyone 2 Core ML models at a landscape working resolution
# and compiles them for the plugin bundle.
#
# Inputs (environment):
#   MA2_WORKING_WIDTH, MA2_WORKING_HEIGHT  working resolution, multiples of 16
#                                          (default 512x288)
#   MA2_FORCE_EXPORT=1                     discard a previous export first
#
# Output: .build/models/<W>x<H>/MatAnyone/ with manifest.json, six .mlmodelc
# directories and the upstream LICENSE.txt.
#
# The upstream MatAnyone2 commit and the Python package versions are pinned
# (below and in tools/export/uv.lock) so the export is reproducible. The weights
# come from the upstream Hugging Face release and are never committed.
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
width="${MA2_WORKING_WIDTH:-512}"
height="${MA2_WORKING_HEIGHT:-288}"
upstream_rev="0079197acd6d16a741f71558809c06c586c579e0"
upstream_dir="$root_dir/.build/MatAnyone2"
kit_scripts="$root_dir/.build/checkouts/MatAnyone2Kit/scripts"
export_project="$root_dir/tools/export"
export_dir="$root_dir/.build/export-${width}x${height}"
models_dir="$root_dir/.build/models/${width}x${height}/MatAnyone"

if ((width % 16 != 0 || height % 16 != 0 || width <= 0 || height <= 0)); then
    echo "Working resolution ${width}x${height} must be a positive multiple of 16." >&2
    exit 1
fi
if [[ ! -f "$kit_scripts/export.py" ]]; then
    echo "MatAnyone2Kit checkout is missing. Run 'swift package resolve' first." >&2
    exit 1
fi
if ! command -v uv >/dev/null 2>&1; then
    echo "uv is required: brew install uv" >&2
    exit 1
fi

if [[ "${MA2_FORCE_EXPORT:-0}" == "1" ]]; then
    rm -rf "$export_dir" "$models_dir"
fi
if [[ -f "$models_dir/manifest.json" ]]; then
    printf 'Models for %sx%s already exported at %s\n' "$width" "$height" "$models_dir"
    exit 0
fi

# Upstream MatAnyone2 source at the pinned commit.
if [[ ! -d "$upstream_dir/.git" ]]; then
    git clone --filter=blob:none https://github.com/pq-yang/MatAnyone2.git "$upstream_dir"
fi
if [[ "$(git -C "$upstream_dir" rev-parse HEAD)" != "$upstream_rev" ]]; then
    git -C "$upstream_dir" fetch origin "$upstream_rev"
    git -C "$upstream_dir" checkout --detach "$upstream_rev"
fi

# Pinned Python environment.
uv sync --project "$export_project" --frozen

# Core ML Tools 9.0 crashes on one-element numpy arrays reaching aten::Int.
# The upstream fix is not in the pinned release, so patch the installed copy.
coreml_ops="$(find "$export_project/.venv/lib" \
    -path '*/coremltools/converters/mil/frontend/torch/ops.py' -print -quit)"
COREML_OPS="$coreml_ops" "$export_project/.venv/bin/python" - <<'PY'
import os
from pathlib import Path

path = Path(os.environ["COREML_OPS"])
source = path.read_text()
old = """        if not isinstance(x.val, dtype):
            res = mb.const(val=dtype(x.val), name=node.name)
        else:
            res = x"""
new = """        if not isinstance(x.val, dtype):
            raw_value = x.val
            if hasattr(raw_value, "size") and raw_value.size == 1:
                raw_value = raw_value.item()
            res = mb.const(val=dtype(raw_value), name=node.name)
        else:
            res = x"""
if old in source:
    path.write_text(source.replace(old, new, 1))
elif new not in source:
    raise SystemExit("coremltools scalar fix does not apply; check the pinned version")
PY

# Working copy of the kit's export script, rewritten for a landscape working
# resolution. The kit exports portrait 288x512 with the stride-16 feature grid
# hard-coded; both come from the resolution here.
mkdir -p "$export_dir"
cp "$kit_scripts/export.py" "$kit_scripts/coreml_prod_op.py" "$export_dir/"
chmod u+w "$export_dir"/*.py
EXPORT_FILE="$export_dir/export.py" UPSTREAM_DIR="$upstream_dir" \
    MA2_W="$width" MA2_H="$height" "$export_project/.venv/bin/python" - <<'PY'
import os
from pathlib import Path

path = Path(os.environ["EXPORT_FILE"])
w, h = int(os.environ["MA2_W"]), int(os.environ["MA2_H"])
cfg = Path(os.environ["UPSTREAM_DIR"]) / "matanyone2/config/eval_matanyone_config.yaml"
source = path.read_text()

def replace(old, new):
    global source
    if old not in source:
        raise SystemExit(f"export.py changed upstream; could not find: {old!r}")
    source = source.replace(old, new, 1)

replace('EVAL_CFG = "/tmp/matanyone2/matanyone2/config/eval_matanyone_config.yaml"',
        f"EVAL_CFG = {str(cfg)!r}")
replace("H, W = 512, 288", f"H, W = {h}, {w}")
# pixel_fusion upsamples to sensory.shape[-2:], a two-element tensor that
# Core ML Tools 9 cannot lower through aten::Int. Fix the stride-16 grid size.
replace("patch_ane_hostile_ops()\npatch_eca_rank4()",
        "patch_ane_hostile_ops()\npatch_eca_rank4()\n\n"
        "from matanyone2.model.matanyone2 import MatAnyone2 as _MatAnyone2\n"
        "_rebind(_MatAnyone2, \"pixel_fusion\", [\n"
        f"    (\"size=sensory.shape[-2:]\", \"size=({h // 16}, {w // 16})\"),\n"
        "])")
# Skip models that are already converted so an interrupted run can resume.
replace("def convert_save(name, wrapper, in_names, tensors, out_names):\n"
        "    wrapper = wrapper.eval()",
        "def convert_save(name, wrapper, in_names, tensors, out_names):\n"
        "    path = os.path.join(OUT_DIR, f\"{name}.mlpackage\")\n"
        "    if os.path.exists(path):\n"
        "        print(f\"  reusing {name}.mlpackage\")\n"
        "        return {\n"
        "            \"name\": name,\n"
        "            \"path\": f\"models/{name}.mlpackage\",\n"
        "            \"inputs\": [{\"name\": n, \"shape\": list(t.shape)} for n, t in zip(in_names, tensors)],\n"
        "            \"outputs\": out_names,\n"
        "            \"median_ms_mac_ane\": 0.0,\n"
        "        }\n"
        "    wrapper = wrapper.eval()")
path.write_text(source)
PY

(
    cd "$export_dir"
    PYTHONPATH="$upstream_dir:$export_dir" "$export_project/.venv/bin/python" export.py
)

rm -rf "$models_dir"
mkdir -p "$models_dir"
cp "$export_dir/models/manifest.json" "$models_dir/"
cp "$upstream_dir/LICENSE.txt" "$models_dir/LICENSE.txt"
for model in encoder uncert readout decoder maskencoder objsummary; do
    xcrun coremlcompiler compile "$export_dir/models/$model.mlpackage" "$models_dir/"
done

printf 'Core ML models (%sx%s) ready at %s\n' "$width" "$height" "$models_dir"
