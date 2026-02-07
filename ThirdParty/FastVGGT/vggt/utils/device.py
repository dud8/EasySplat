from __future__ import annotations

from contextlib import nullcontext
import os
from typing import ContextManager

import torch


def resolve_device(device_arg: str | None) -> torch.device:
    if device_arg is None:
        device_arg = "auto"

    device_arg = device_arg.lower()
    if device_arg == "auto":
        if torch.cuda.is_available():
            return torch.device("cuda")
        if hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
            return torch.device("mps")
        return torch.device("cpu")

    if device_arg.startswith("cuda"):
        if not torch.cuda.is_available():
            raise RuntimeError("CUDA requested but not available")
        return torch.device(device_arg)

    if device_arg == "mps":
        if not (hasattr(torch.backends, "mps") and torch.backends.mps.is_available()):
            raise RuntimeError("MPS requested but not available")
        return torch.device("mps")

    if device_arg == "cpu":
        return torch.device("cpu")

    raise ValueError(f"Unknown device: {device_arg}")


def resolve_dtype(device: torch.device, dtype_arg: str | None) -> torch.dtype:
    if dtype_arg is None or dtype_arg == "auto":
        if device.type == "cuda":
            capability = torch.cuda.get_device_capability(device)
            if capability[0] >= 8:
                return torch.bfloat16
            return torch.float16
        return torch.float32

    dtype_arg = dtype_arg.lower()
    mapping = {
        "float32": torch.float32,
        "float16": torch.float16,
        "bfloat16": torch.bfloat16,
    }
    if dtype_arg not in mapping:
        raise ValueError(f"Unknown dtype: {dtype_arg}")

    chosen = mapping[dtype_arg]
    if device.type == "cpu" and chosen != torch.float32:
        print("⚠️  CPU does not reliably support float16/bfloat16; using float32")
        return torch.float32
    if device.type == "mps" and chosen == torch.bfloat16:
        print("⚠️  MPS does not support bfloat16 reliably; using float32")
        return torch.float32

    return chosen


def maybe_autocast(device: torch.device, dtype: torch.dtype) -> ContextManager:
    if device.type == "cuda":
        return torch.autocast(device_type="cuda", dtype=dtype)
    return nullcontext()


def sync_device(device: torch.device) -> None:
    if device.type == "cuda":
        torch.cuda.synchronize()
    elif device.type == "mps":
        if hasattr(torch, "mps") and hasattr(torch.mps, "synchronize"):
            torch.mps.synchronize()


def empty_cache(device: torch.device) -> None:
    if device.type == "cuda":
        torch.cuda.empty_cache()


def warn_if_mps_fallback_disabled(device: torch.device) -> None:
    if device.type != "mps":
        return
    env_value = os.environ.get("PYTORCH_ENABLE_MPS_FALLBACK")
    if env_value is None or env_value == "0":
        print(
            "⚠️  MPS fallback is disabled. If you hit unsupported ops, set "
            "PYTORCH_ENABLE_MPS_FALLBACK=1 to allow CPU fallback."
        )
