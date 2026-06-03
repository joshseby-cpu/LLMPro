"""model_memory.py — per-model memory breakdown, read from safetensors HEADERS.

No weights are loaded. The safetensors format starts with an 8-byte little-endian
header length, then a JSON header mapping tensor-name -> {dtype, shape,
data_offsets}. We sum each tensor's byte size from its dtype + shape, and
classify tensors as "expert" (MoE FFN experts) vs "everything else".

For an MoE this answers the key memory question: the experts dominate RAM, but
only top-k of them are active per token — so "active per token" memory is far
smaller than the resident footprint. Pruning cold experts (see profile_experts.py)
reclaims resident RAM directly.

Invoked as:  python model_memory.py <model_dir>
Emits a single JSON line:
    {"event":"done","total":<bytes>,"expert":<bytes>,"nonexpert":<bytes>,
     "num_experts":N,"top_k":K,"per_expert":<bytes>,"active_estimate":<bytes>,
     "shards":M,"tensors":T,"dtypes":{"BF16":...}}
"""

from __future__ import annotations

import json
import re
import struct
import sys
from pathlib import Path

# safetensors dtype -> bytes per element
DTYPE_SIZES = {
    "F64": 8, "F32": 4, "F16": 2, "BF16": 2,
    "I64": 8, "I32": 4, "I16": 2, "I8": 1, "U8": 1, "U64": 8, "U32": 4, "U16": 2,
    "BOOL": 1, "F8_E4M3": 1, "F8_E5M2": 1,
}

_EXPERT_RE = re.compile(r"experts\.\d+\.")


def _is_expert(name: str) -> bool:
    return ("experts.switch_glu" in name) or ("block_sparse_moe.experts" in name) \
        or bool(_EXPERT_RE.search(name))


def _header_tensors(path: Path):
    """Yield (name, dtype, nbytes) for each tensor in a safetensors file,
    reading only the JSON header."""
    with open(path, "rb") as f:
        raw_len = f.read(8)
        if len(raw_len) < 8:
            return
        n = struct.unpack("<Q", raw_len)[0]
        hdr = json.loads(f.read(n))
    for name, meta in hdr.items():
        if name == "__metadata__" or not isinstance(meta, dict):
            continue
        dt = meta.get("dtype", "F16")
        shape = meta.get("shape", []) or []
        nb = DTYPE_SIZES.get(dt, 2)
        for s in shape:
            nb *= int(s)
        yield name, dt, nb


def _find_int(cfg: dict, *keys):
    for d in (cfg, cfg.get("text_config", {}) or {}, cfg.get("ffn_config", {}) or {}):
        if isinstance(d, dict):
            for k in keys:
                v = d.get(k)
                if isinstance(v, int):
                    return v
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        sys.stdout.write(json.dumps({"event": "error", "message": "Usage: model_memory.py <model_dir>"}) + "\n")
        return 2
    src = Path(sys.argv[1])
    cfg_path = src / "config.json"
    if not cfg_path.exists():
        sys.stdout.write(json.dumps({"event": "error", "message": f"No config.json in {src}"}) + "\n")
        return 3
    cfg = json.loads(cfg_path.read_text())

    num_experts = _find_int(cfg, "num_local_experts", "num_experts", "moe_num_experts")
    top_k = _find_int(cfg, "num_experts_per_tok", "top_k_experts", "moe_top_k", "num_experts_per_token")

    shards = sorted(src.glob("*.safetensors"))
    if not shards:
        sys.stdout.write(json.dumps({"event": "error", "message": "No safetensors files found"}) + "\n")
        return 4

    total = 0
    expert = 0
    tensors = 0
    dtypes: dict[str, int] = {}
    for sh in shards:
        try:
            for name, dt, nb in _header_tensors(sh):
                total += nb
                tensors += 1
                dtypes[dt] = dtypes.get(dt, 0) + nb
                if _is_expert(name):
                    expert += nb
        except Exception as exc:  # noqa: BLE001
            sys.stdout.write(json.dumps({"event": "error", "message": f"Failed reading {sh.name}: {exc}"}) + "\n")
            return 5

    nonexpert = total - expert
    per_expert = (expert // num_experts) if num_experts > 1 else 0
    if num_experts > 1 and top_k > 0:
        active = nonexpert + per_expert * top_k
    else:
        active = total

    sys.stdout.write(json.dumps({
        "event": "done",
        "total": total,
        "expert": expert,
        "nonexpert": nonexpert,
        "num_experts": num_experts,
        "top_k": top_k,
        "per_expert": per_expert,
        "active_estimate": active,
        "shards": len(shards),
        "tensors": tensors,
        "dtypes": dtypes,
    }) + "\n")
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
