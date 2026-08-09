#!/usr/bin/env python3
"""Run one App Store command while monitoring the exact package vnode."""

from __future__ import annotations

import argparse
import importlib.util
import sys
from pathlib import Path


EVIDENCE_HELPER = Path(__file__).with_name("mas_release_evidence.py")


def _load_evidence_helper():
    spec = importlib.util.spec_from_file_location(
        "easysplat_mas_release_evidence", EVIDENCE_HELPER
    )
    if spec is None or spec.loader is None:
        raise RuntimeError("MAS release evidence helper is unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot", required=True, type=Path)
    parser.add_argument("--descriptor", required=True, type=int)
    parser.add_argument("--token", required=True)
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    return parser


def main(arguments: list[str] | None = None) -> int:
    options = _parser().parse_args(arguments)
    command = options.arguments
    if command[:1] == ["--"]:
        command = command[1:]
    try:
        helper = _load_evidence_helper()
        return helper.run_bound_package_command(
            snapshot=options.snapshot,
            descriptor=options.descriptor,
            token=options.token,
            arguments=command,
        )
    except (OSError, RuntimeError) as error:
        print(f"Bound package command failed: {error}", file=sys.stderr)
        return 1
    except Exception as error:
        if error.__class__.__name__ != "ReleaseEvidenceError":
            raise
        print(f"Bound package command rejected: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
