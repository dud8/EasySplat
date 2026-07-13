#!/usr/bin/env python3
"""Run one protected benchmark lane and seal its raw evidence."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any, Mapping

try:
    from scripts.benchmark import easysplat_benchmark as benchmark
    from scripts.benchmark import evidence_protocol as evidence
except ModuleNotFoundError:
    import easysplat_benchmark as benchmark
    import evidence_protocol as evidence


def _load(path: Path, label: str) -> Any:
    return benchmark._load_json(path, label)


def _relative(value: Any, label: str) -> Path:
    raw = benchmark._safe_relative_path(value, label)
    return Path(*PurePosixPath(raw).parts)


def _require_runner(path: Path) -> Path:
    if path.is_symlink() or not path.is_file() or not os.access(path, os.X_OK):
        raise benchmark.ConfigError("measurement runner must be a regular executable")
    return path.resolve()


def _verify_runner_digest(path: Path, expected: Mapping[str, str], phase: str) -> None:
    actual = evidence.sha256_file(path)
    if actual != expected["sha256"]:
        raise benchmark.ConfigError(
            f"{expected['label']} digest mismatch {phase}; refusing protected measurement"
        )


def run_lane(
    index_path: Path,
    requests_root: Path,
    corpus_path: Path,
    reference_config_path: Path,
    toolchain_root: Path,
    output_root: Path,
    lane: str,
    runner_path: Path,
    evidence_key_path: Path,
) -> dict[str, Any]:
    if lane not in evidence.RELEASE_LANES:
        raise benchmark.ConfigError("unsupported benchmark lane")
    runner = _require_runner(runner_path)
    index = benchmark._require_mapping(_load(index_path, "request index"), "request index")
    benchmark._require_exact_keys(
        index,
        {
            "schema_version",
            "producer_protocol",
            "producer_version",
            "producer_digest",
            "corpus_digest",
            "thresholds_digest",
            "git_commit",
            "app_version",
            "toolchain_identity",
            "runner_identities",
            "requests",
        },
        "request index",
    )
    corpus = _load(corpus_path, "corpus")
    config = _load(reference_config_path, "reference config")
    benchmark.validate_corpus(corpus, expected_profile="release")
    benchmark.validate_reference_config(config)
    if benchmark.sha256_json(corpus) != index["corpus_digest"]:
        raise benchmark.ConfigError("lane corpus does not match the prepared request index")
    if benchmark.sha256_json(config) != index["thresholds_digest"]:
        raise benchmark.ConfigError("lane thresholds do not match the prepared request index")
    git = benchmark.collect_git_state()
    if git["dirty"] or git["commit"] != index["git_commit"]:
        raise benchmark.ConfigError("lane checkout is not the exact clean prepared commit")
    toolchain_identity = benchmark.resolved_toolchain_identity(toolchain_root, "release")
    if toolchain_identity != index["toolchain_identity"]:
        raise benchmark.ConfigError("lane toolchain does not match the prepared request index")
    identity = benchmark.RunIdentity(
        profile="release",
        corpus_digest=benchmark.sha256_json(corpus),
        thresholds_digest=benchmark.sha256_json(config),
        git_commit=git["commit"],
        app_version=benchmark.APP_VERSION,
        toolchain_identity=toolchain_identity,
    )
    index = benchmark.validate_request_index(index, identity, corpus)
    approved_runner = index["runner_identities"][lane]
    _verify_runner_digest(runner, approved_runner, "before the first scene")

    machine = evidence.collect_machine_metadata()
    evidence.validate_machine_lane(machine, lane)
    key = evidence.load_key(evidence_key_path)
    requests = index["requests"]
    if not isinstance(requests, list):
        raise benchmark.ConfigError("request index requests must be an array")
    selected = [entry for entry in requests if isinstance(entry, Mapping) and entry.get("lane") == lane]
    if not selected:
        raise benchmark.ConfigError(f"request index contains no {lane} work")

    output_root.mkdir(parents=True, exist_ok=True)
    results = []
    for raw_entry in selected:
        _verify_runner_digest(runner, approved_runner, "before subprocess launch")
        entry = benchmark._require_mapping(raw_entry, "request index entry")
        request_path = requests_root / _relative(entry.get("request"), "request path")
        request = _load(request_path, "evidence request")
        evidence.validate_request(request)
        scene_id = benchmark._require_safe_token(entry.get("scene_id"), "request scene_id")
        scale = entry.get("scale")
        if type(scale) is not int or request["binding"]["scene_id"] != scene_id or request["binding"]["scale"] != scale:
            raise benchmark.ConfigError("request index entry does not match its request")
        media_relative = _relative(entry.get("media_path"), "request media path")
        media = corpus_path.parent / media_relative
        expected_input_digest = request["binding"]["input_digest"]
        if benchmark.digest_input(media) != expected_input_digest:
            raise benchmark.ConfigError(f"{scene_id} input does not match the prepared request")

        evidence_relative = _relative(entry.get("evidence_path"), "request evidence path")
        artifact_root = output_root / evidence_relative / str(scale) / lane
        if artifact_root.exists():
            shutil.rmtree(artifact_root)
        artifact_root.mkdir(parents=True)
        command_log = artifact_root / "command.jsonl"
        stdout_log = artifact_root / "stdout.log"
        stderr_log = artifact_root / "stderr.log"
        redacted_command = [
            "protected-measurement-runner",
            "--request",
            f"requests://{entry['request']}",
            "--input",
            f"corpus://{entry['media_path']}",
            "--toolchain-root",
            "toolchain://resolved",
            "--artifact-root",
            "evidence://run",
            "--lane",
            lane,
        ]
        command = [
            str(runner),
            "--request",
            str(request_path),
            "--input",
            str(media),
            "--toolchain-root",
            str(toolchain_root),
            "--artifact-root",
            str(artifact_root),
            "--lane",
            lane,
        ]
        started = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        command_log.write_bytes(
            evidence.canonical_json_bytes({"event": "started", "at": started, "argv": redacted_command})
            + b"\n"
        )
        _verify_runner_digest(runner, approved_runner, "immediately before subprocess launch")
        try:
            with stdout_log.open("wb") as stdout_handle, stderr_log.open("wb") as stderr_handle:
                completed = subprocess.run(
                    command,
                    stdin=subprocess.DEVNULL,
                    stdout=stdout_handle,
                    stderr=stderr_handle,
                    check=False,
                )
        finally:
            _verify_runner_digest(runner, approved_runner, "after subprocess completion")
        ended = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        with command_log.open("ab") as handle:
            handle.write(
                evidence.canonical_json_bytes(
                    {"event": "finished", "at": ended, "exit_code": completed.returncode}
                )
                + b"\n"
            )
        if completed.returncode != 0:
            raise benchmark.ConfigError(
                f"{lane} measurement runner failed for {scene_id}@{scale} with exit {completed.returncode}"
            )

        observations_path = artifact_root / "observations.json"
        observations = _load(observations_path, "raw observations")
        attestation = evidence.produce_attestation(
            request,
            observations,
            artifact_root,
            artifact_root / "attestation.json",
            key,
            lane,
            approved_runner,
            machine=machine,
        )
        attestation_path = artifact_root / "attestation.json"
        benchmark.atomic_write_json(attestation_path, attestation)
        if benchmark.digest_input(media) != expected_input_digest:
            raise benchmark.ConfigError(f"{scene_id} input changed during measurement")
        results.append(
            {
                "scene_id": scene_id,
                "scale": scale,
                "lane": lane,
                "attestation": (evidence_relative / str(scale) / lane / "attestation.json").as_posix(),
                "sha256": evidence.sha256_file(attestation_path),
            }
        )

    _verify_runner_digest(runner, approved_runner, "at lane completion")
    if benchmark.resolved_toolchain_identity(toolchain_root, "release") != toolchain_identity:
        raise benchmark.ConfigError("toolchain changed during lane measurement")
    lane_result = {
        "schema_version": 1,
        "lane": lane,
        "machine": machine,
        "git_commit": index["git_commit"],
        "corpus_digest": index["corpus_digest"],
        "thresholds_digest": index["thresholds_digest"],
        "toolchain_identity": index["toolchain_identity"],
        "producer_digest": index["producer_digest"],
        "runner_identity": approved_runner,
        "attestations": results,
    }
    benchmark.atomic_write_json(output_root / f"lane-{lane}.json", lane_result)
    return lane_result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--index", type=Path, required=True)
    parser.add_argument("--requests-root", type=Path, required=True)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--reference-config", type=Path, required=True)
    parser.add_argument("--toolchain-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--lane", choices=sorted(evidence.RELEASE_LANES), required=True)
    parser.add_argument("--runner", type=Path, required=True)
    parser.add_argument("--evidence-key-file", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        result = run_lane(
            args.index,
            args.requests_root,
            args.corpus,
            args.reference_config,
            args.toolchain_root,
            args.output,
            args.lane,
            args.runner,
            args.evidence_key_file,
        )
        print(evidence.canonical_json_bytes({"status": "attested", "count": len(result["attestations"])}).decode())
        return 0
    except (benchmark.ConfigError, evidence.EvidenceError) as error:
        print(f"benchmark lane error: {error}", file=sys.stderr)
        return 64


if __name__ == "__main__":
    raise SystemExit(main())
