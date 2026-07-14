#!/usr/bin/env python3
"""Run one protected benchmark lane and seal its raw evidence."""

from __future__ import annotations

import argparse
import math
import os
import signal
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any, BinaryIO, Mapping, Sequence

try:
    from scripts.benchmark import easysplat_benchmark as benchmark
    from scripts.benchmark import evidence_protocol as evidence
except ModuleNotFoundError:
    import easysplat_benchmark as benchmark
    import evidence_protocol as evidence


_TIMEOUT_OVERRIDE_ENVIRONMENT_KEY = "EASYSPLAT_INTERNAL_BENCHMARK_TIMEOUT_SECONDS"
_MINIMUM_TIMEOUT_OVERRIDE_SECONDS = 0.1
_MAXIMUM_TIMEOUT_OVERRIDE_SECONDS = 7 * 24 * 60 * 60
_PROCESS_GROUP_TERMINATION_GRACE_SECONDS = 5.0


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


def _verify_baseline_checkout(path: Path, expected_commit: str) -> Path:
    if path.is_symlink() or not path.is_dir():
        raise benchmark.ConfigError("baseline checkout must be a real directory")
    resolved = path.resolve()

    def git(*arguments: str) -> str:
        completed = subprocess.run(
            ["/usr/bin/git", "-C", str(resolved), *arguments],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            text=True,
        )
        if completed.returncode != 0:
            raise benchmark.ConfigError("baseline checkout is not a readable Git worktree")
        return completed.stdout.strip()

    top_level = Path(git("rev-parse", "--show-toplevel")).resolve()
    if top_level != resolved:
        raise benchmark.ConfigError("baseline checkout must point to its worktree root")
    if git("rev-parse", "HEAD") != expected_commit:
        raise benchmark.ConfigError("baseline checkout is not the approved commit")
    if git("status", "--porcelain", "--untracked-files=normal"):
        raise benchmark.ConfigError("baseline checkout must be clean")
    return resolved


def _verify_baseline_toolchain(path: Path, expected_identity: str) -> tuple[Path, str]:
    if path.is_symlink() or not path.is_dir():
        raise benchmark.ConfigError("baseline toolchain must be a real directory")
    resolved = path.resolve()
    identity = benchmark.resolved_toolchain_identity(resolved, "release")
    if identity != expected_identity:
        raise benchmark.ConfigError("baseline toolchain does not match the approved closure")
    return resolved, identity


def _verify_candidate_checkout(expected_commit: str) -> None:
    state = benchmark.collect_git_state()
    if state["dirty"] or state["commit"] != expected_commit:
        raise benchmark.ConfigError("candidate checkout changed during lane measurement")


def _verify_file_digest(path: Path, expected_digest: str, label: str) -> None:
    if evidence.sha256_file(path) != expected_digest:
        raise benchmark.ConfigError(f"{label} changed during lane measurement")


def _prepare_artifact_root(output_root: Path, relative: Path, scale: int, lane: str) -> Path:
    if output_root.exists() and (output_root.is_symlink() or not output_root.is_dir()):
        raise benchmark.ConfigError("benchmark output root must be a real directory")
    output_root.mkdir(parents=True, exist_ok=True)
    canonical_output = output_root.resolve(strict=True)
    artifact_root = output_root / relative / str(scale) / lane
    cursor = output_root
    for part in artifact_root.relative_to(output_root).parts:
        cursor /= part
        if cursor.is_symlink():
            raise benchmark.ConfigError("benchmark artifact path contains a symlink")
    parent = artifact_root.parent
    parent.mkdir(parents=True, exist_ok=True)
    resolved_parent = parent.resolve(strict=True)
    if resolved_parent != canonical_output and canonical_output not in resolved_parent.parents:
        raise benchmark.ConfigError("benchmark artifact path escapes the output root")
    if artifact_root.exists():
        if artifact_root.is_symlink() or not artifact_root.is_dir():
            raise benchmark.ConfigError("benchmark artifact root must be a real directory")
        shutil.rmtree(artifact_root)
    artifact_root.mkdir()
    return artifact_root


def _measurement_environment(artifact_root: Path) -> dict[str, str]:
    home = artifact_root / "runner-home"
    temporary = artifact_root / "tmp"
    cache = artifact_root / "cache"
    for directory in (home, temporary, cache):
        directory.mkdir()
    return {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": str(home),
        "TMPDIR": str(temporary),
        "XDG_CACHE_HOME": str(cache),
        "LANG": "en_US.UTF-8",
        "LC_ALL": "en_US.UTF-8",
    }


def _measurement_timeout_seconds(scale: int, override: str | None = None) -> float:
    if type(scale) is not int or scale <= 0:
        raise benchmark.ConfigError("benchmark scale must be a positive integer")
    if override is not None:
        try:
            seconds = float(override)
        except (TypeError, ValueError) as error:
            raise benchmark.ConfigError(
                f"{_TIMEOUT_OVERRIDE_ENVIRONMENT_KEY} must be a finite number of seconds"
            ) from error
        if (
            not math.isfinite(seconds)
            or seconds < _MINIMUM_TIMEOUT_OVERRIDE_SECONDS
            or seconds > _MAXIMUM_TIMEOUT_OVERRIDE_SECONDS
        ):
            raise benchmark.ConfigError(
                f"{_TIMEOUT_OVERRIDE_ENVIRONMENT_KEY} must be between "
                f"{_MINIMUM_TIMEOUT_OVERRIDE_SECONDS:g} and "
                f"{_MAXIMUM_TIMEOUT_OVERRIDE_SECONDS:g} seconds"
            )
        return seconds

    # A protected lane can include warm-ups, alternating baseline/candidate runs,
    # accurate references, and artifact validation. Keep the ceiling generous
    # enough for those real workloads while still bounding a wedged runner.
    return min(24 * 60 * 60.0, max(2 * 60 * 60.0, scale * 90.0))


def _signal_process_group(process: subprocess.Popen[bytes], signal_number: int) -> None:
    try:
        os.killpg(process.pid, signal_number)
    except ProcessLookupError:
        return
    except OSError as error:
        raise benchmark.ConfigError("could not terminate the measurement process group") from error


def _terminate_process_group(
    process: subprocess.Popen[bytes],
    grace_seconds: float | None = None,
) -> int:
    if grace_seconds is None:
        grace_seconds = _PROCESS_GROUP_TERMINATION_GRACE_SECONDS
    _signal_process_group(process, signal.SIGTERM)
    # Do not reap the session leader before the final group signal. Keeping it
    # unreaped prevents its process-group ID from being reused for unrelated work.
    time.sleep(grace_seconds)
    _signal_process_group(process, signal.SIGKILL)
    try:
        return process.wait(timeout=grace_seconds)
    except subprocess.TimeoutExpired as error:
        raise benchmark.ConfigError(
            "measurement runner did not exit after process-group termination"
        ) from error


def _run_measurement_process(
    command: Sequence[str],
    stdout_handle: BinaryIO,
    stderr_handle: BinaryIO,
    environment: Mapping[str, str],
    timeout_seconds: float,
) -> tuple[subprocess.CompletedProcess[bytes], bool]:
    process = subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=stdout_handle,
        stderr=stderr_handle,
        env=environment,
        start_new_session=True,
    )
    try:
        return_code = process.wait(timeout=timeout_seconds)
        return subprocess.CompletedProcess(command, return_code), False
    except subprocess.TimeoutExpired:
        return_code = _terminate_process_group(process)
        return subprocess.CompletedProcess(command, return_code), True
    except BaseException:
        try:
            _terminate_process_group(process)
        except Exception:
            pass
        raise


def run_lane(
    index_path: Path,
    requests_root: Path,
    corpus_path: Path,
    reference_config_path: Path,
    toolchain_root: Path,
    baseline_checkout_root: Path,
    baseline_toolchain_root: Path,
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
            "baseline_git_commit",
            "baseline_toolchain_identity",
            "baseline_configuration_digest",
            "baseline_run_configuration",
            "runner_identities",
            "requests",
        },
        "request index",
    )
    corpus = _load(corpus_path, "corpus")
    config = _load(reference_config_path, "reference config")
    protected_file_digests = {
        "request index": evidence.sha256_file(index_path),
        "corpus": evidence.sha256_file(corpus_path),
        "reference config": evidence.sha256_file(reference_config_path),
    }
    benchmark.validate_corpus(corpus, expected_profile="release")
    benchmark.validate_reference_config(config)
    if benchmark.sha256_json(corpus) != index["corpus_digest"]:
        raise benchmark.ConfigError("lane corpus does not match the prepared request index")
    if benchmark.sha256_json(config) != index["thresholds_digest"]:
        raise benchmark.ConfigError("lane thresholds do not match the prepared request index")
    _verify_candidate_checkout(index["git_commit"])
    git = benchmark.collect_git_state()
    toolchain_identity = benchmark.resolved_toolchain_identity(toolchain_root, "release")
    if toolchain_identity != index["toolchain_identity"]:
        raise benchmark.ConfigError("lane toolchain does not match the prepared request index")
    baseline_checkout = _verify_baseline_checkout(
        baseline_checkout_root,
        index["baseline_git_commit"],
    )
    baseline_toolchain, baseline_toolchain_identity = _verify_baseline_toolchain(
        baseline_toolchain_root,
        index["baseline_toolchain_identity"],
    )
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

    results = []
    for raw_entry in selected:
        _verify_candidate_checkout(index["git_commit"])
        for label, digest in protected_file_digests.items():
            _verify_file_digest(
                {"request index": index_path, "corpus": corpus_path, "reference config": reference_config_path}[label],
                digest,
                label,
            )
        _verify_runner_digest(runner, approved_runner, "before subprocess launch")
        entry = benchmark._require_mapping(raw_entry, "request index entry")
        request_path = requests_root / _relative(entry.get("request"), "request path")
        request = _load(request_path, "evidence request")
        evidence.validate_request(request)
        scene_id = benchmark._require_safe_token(entry.get("scene_id"), "request scene_id")
        scale = entry.get("scale")
        if (
            type(scale) is not int
            or request["binding"]["scene_id"] != scene_id
            or request["binding"]["scale"] != scale
            or request["binding"]["lane"] != lane
        ):
            raise benchmark.ConfigError("request index entry does not match its request")
        scene = next((item for item in corpus["scenes"] if item["id"] == scene_id), None)
        if scene is None:
            raise benchmark.ConfigError("request scene is absent from the corpus")
        expected_request = benchmark._evidence_request(
            scene,
            scale,
            lane,
            identity,
            request["binding"]["input_digest"],
        )
        if request != expected_request:
            raise benchmark.ConfigError("request policy does not match the prepared corpus and lane")
        request_digest = evidence.sha256_file(request_path)
        for field in (
            "corpus_digest",
            "thresholds_digest",
            "git_commit",
            "app_version",
            "toolchain_identity",
            "baseline_git_commit",
            "baseline_toolchain_identity",
            "baseline_configuration_digest",
        ):
            if request["binding"][field] != index[field]:
                raise benchmark.ConfigError(f"request {field} does not match its approved index")
        if request["baseline_run_configuration"] != index["baseline_run_configuration"]:
            raise benchmark.ConfigError("request baseline run configuration does not match its approved index")
        media_relative = _relative(entry.get("media_path"), "request media path")
        media = corpus_path.parent / media_relative
        expected_input_digest = request["binding"]["input_digest"]
        if benchmark.digest_input(media) != expected_input_digest:
            raise benchmark.ConfigError(f"{scene_id} input does not match the prepared request")

        evidence_relative = _relative(entry.get("evidence_path"), "request evidence path")
        artifact_root = _prepare_artifact_root(output_root, evidence_relative, scale, lane)
        command_log = artifact_root / "command.jsonl"
        supervisor_log = artifact_root / "supervisor-command.jsonl"
        stdout_log = artifact_root / "stdout.log"
        stderr_log = artifact_root / "stderr.log"
        timeout_seconds = _measurement_timeout_seconds(
            scale,
            os.environ.get(_TIMEOUT_OVERRIDE_ENVIRONMENT_KEY),
        )
        redacted_command = [
            "protected-measurement-runner",
            f"scene://{scene_id}",
            f"scale://{scale}",
            f"lane://{lane}",
            f"input://{expected_input_digest}",
            f"candidate://{index['git_commit']}",
            f"baseline://{index['baseline_git_commit']}",
            f"toolchain://{index['toolchain_identity']}",
            f"runner://{approved_runner['sha256']}",
            "--request",
            f"requests://{entry['request']}",
            "--input",
            f"corpus://{entry['media_path']}",
            "--toolchain-root",
            "toolchain://resolved",
            "--candidate-checkout-root",
            f"candidate://{index['git_commit']}",
            "--baseline-checkout-root",
            f"baseline://{index['baseline_git_commit']}",
            "--baseline-toolchain-root",
            "baseline-toolchain://resolved",
            "--reference-config",
            "config://reference",
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
            "--candidate-checkout-root",
            str(benchmark.ROOT),
            "--baseline-checkout-root",
            str(baseline_checkout),
            "--baseline-toolchain-root",
            str(baseline_toolchain),
            "--reference-config",
            str(reference_config_path),
            "--artifact-root",
            str(artifact_root),
            "--lane",
            lane,
        ]
        started = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        supervisor_log.write_bytes(
            evidence.canonical_json_bytes({"event": "started", "at": started, "argv": redacted_command})
            + b"\n"
        )
        _verify_runner_digest(runner, approved_runner, "immediately before subprocess launch")
        completed: subprocess.CompletedProcess[bytes] | None = None
        launch_error: OSError | None = None
        timed_out = False
        started_monotonic = time.monotonic()
        try:
            with stdout_log.open("wb") as stdout_handle, stderr_log.open("wb") as stderr_handle:
                completed, timed_out = _run_measurement_process(
                    command,
                    stdout_handle,
                    stderr_handle,
                    _measurement_environment(artifact_root),
                    timeout_seconds,
                )
        except OSError as error:
            launch_error = error
        finally:
            ended_monotonic = time.monotonic()
            _verify_runner_digest(runner, approved_runner, "after subprocess completion")
            _verify_candidate_checkout(index["git_commit"])
            for label, digest in protected_file_digests.items():
                _verify_file_digest(
                    {"request index": index_path, "corpus": corpus_path, "reference config": reference_config_path}[label],
                    digest,
                    label,
                )
            _verify_file_digest(request_path, request_digest, "evidence request")
        if completed is None:
            detail = launch_error.strerror if launch_error is not None else "unknown launch failure"
            raise benchmark.ConfigError(
                f"{lane} measurement runner could not start for {scene_id}@{scale}: {detail}"
            )
        ended = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        with supervisor_log.open("ab") as handle:
            handle.write(
                evidence.canonical_json_bytes(
                    {"event": "finished", "at": ended, "exit_code": completed.returncode}
                )
                + b"\n"
            )
        if timed_out:
            raise benchmark.ConfigError(
                f"{lane} measurement runner timed out for {scene_id}@{scale} "
                f"after {timeout_seconds:g} seconds"
            )
        if completed.returncode != 0:
            raise benchmark.ConfigError(
                f"{lane} measurement runner failed for {scene_id}@{scale} with exit {completed.returncode}"
            )

        observations_path = artifact_root / "observations.json"
        observations = _load(observations_path, "raw observations")
        if not isinstance(observations, Mapping):
            raise benchmark.ConfigError("measurement runner observations must be an object")
        raw_receipts = observations.get("commands") if isinstance(observations, Mapping) else None
        if not isinstance(raw_receipts, list):
            raise benchmark.ConfigError("measurement runner did not emit execution receipts")
        command_log.write_bytes(
            b"".join(evidence.canonical_json_bytes(receipt) + b"\n" for receipt in raw_receipts)
        )
        raw_artifacts = observations.get("artifacts")
        if not isinstance(raw_artifacts, dict):
            raise benchmark.ConfigError("measurement runner artifacts must be an object")
        raw_artifacts["supervisor_run"] = "supervisor-run.json"
        supervisor_run = {
            "schema_version": 1,
            "scene_id": scene_id,
            "scale": scale,
            "lane": lane,
            "input_digest": expected_input_digest,
            "candidate_git_commit": index["git_commit"],
            "baseline_git_commit": index["baseline_git_commit"],
            "toolchain_identity": index["toolchain_identity"],
            "baseline_toolchain_identity": index["baseline_toolchain_identity"],
            "runner_sha256": approved_runner["sha256"],
            "argv": redacted_command,
            "started_monotonic_seconds": started_monotonic,
            "ended_monotonic_seconds": ended_monotonic,
            "exit_code": completed.returncode,
        }
        (artifact_root / "supervisor-run.json").write_bytes(
            evidence.canonical_json_bytes(supervisor_run) + b"\n"
        )
        observations_path.write_bytes(evidence.canonical_json_bytes(observations) + b"\n")
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
    _verify_candidate_checkout(index["git_commit"])
    for label, digest in protected_file_digests.items():
        _verify_file_digest(
            {"request index": index_path, "corpus": corpus_path, "reference config": reference_config_path}[label],
            digest,
            label,
        )
    if benchmark.resolved_toolchain_identity(toolchain_root, "release") != toolchain_identity:
        raise benchmark.ConfigError("toolchain changed during lane measurement")
    _verify_baseline_checkout(baseline_checkout, index["baseline_git_commit"])
    _, final_baseline_toolchain_identity = _verify_baseline_toolchain(
        baseline_toolchain,
        baseline_toolchain_identity,
    )
    if final_baseline_toolchain_identity != baseline_toolchain_identity:
        raise benchmark.ConfigError("baseline toolchain changed during lane measurement")
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
    parser.add_argument("--baseline-checkout-root", type=Path, required=True)
    parser.add_argument("--baseline-toolchain-root", type=Path, required=True)
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
            args.baseline_checkout_root,
            args.baseline_toolchain_root,
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
