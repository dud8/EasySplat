#!/usr/bin/env python3
"""Verify EasySplat's source-built Homebrew dependency closure."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import Any


class LockError(ValueError):
    """The reviewed Homebrew closure no longer matches the build."""


BREW_COMMIT = "34c40c18ffa2029b611b61c73273e32c003d0842"
CORE_COMMIT = "a0399ab620e48f72567cfab1ad941b3525051690"
EXPECTED_FORMULAE = {
    "boost",
    "cmake",
    "gflags",
    "giflib",
    "glog",
    "icu4c@78",
    "imath",
    "jpeg-turbo",
    "libdeflate",
    "libomp",
    "libpng",
    "libtiff",
    "lz4",
    "metis",
    "ninja",
    "openexr",
    "openjph",
    "pkgconf",
    "webp",
    "xz",
    "zstd",
}
EXPECTED_REQUESTED = [
    "cmake",
    "ninja",
    "boost",
    "glog",
    "imath",
    "jpeg-turbo",
    "libdeflate",
    "libomp",
    "libpng",
    "libtiff",
    "metis",
    "openexr",
    "openjph",
    "xz",
    "zstd",
]
HEX_SHA256 = re.compile(r"[0-9a-f]{64}")


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise LockError(message)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def json_digest(value: Any) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def load_json(path: Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise LockError(f"cannot read {path}: {exc}") from exc
    _require(isinstance(payload, dict), f"{path} must contain a JSON object")
    return payload


def load_lock(path: Path) -> dict[str, Any]:
    lock = load_json(path)
    validate_lock(lock)
    return lock


def _exact_keys(value: dict[str, Any], expected: set[str], label: str) -> None:
    actual = set(value)
    _require(
        actual == expected,
        f"{label} keys mismatch: expected {sorted(expected)}, got {sorted(actual)}",
    )


def validate_lock(lock: dict[str, Any]) -> None:
    _exact_keys(
        lock, {"schemaVersion", "homebrew", "core", "install", "formulae"}, "lock"
    )
    _require(lock["schemaVersion"] == 1, "unsupported lock schema")
    for label, commit, repository in (
        ("homebrew", BREW_COMMIT, "https://github.com/Homebrew/brew.git"),
        ("core", CORE_COMMIT, "https://github.com/Homebrew/homebrew-core.git"),
    ):
        entry = lock[label]
        _require(isinstance(entry, dict), f"{label} lock must be an object")
        _exact_keys(entry, {"repository", "commit"}, label)
        _require(entry["commit"] == commit, f"{label} commit is not the reviewed pin")
        _require(
            entry["repository"] == repository,
            f"{label} repository is not the reviewed origin",
        )

    install = lock["install"]
    _require(isinstance(install, dict), "install lock must be an object")
    _exact_keys(install, {"mode", "requestedFormulae"}, "install")
    _require(
        install["mode"] == "build-from-source",
        "Homebrew install mode must be build-from-source",
    )
    _require(
        install["requestedFormulae"] == EXPECTED_REQUESTED,
        "requested formula set or order changed",
    )

    formulae = lock["formulae"]
    _require(isinstance(formulae, dict), "formulae lock must be an object")
    actual_formulae = set(formulae)
    _require(
        actual_formulae == EXPECTED_FORMULAE,
        f"formula set mismatch: expected {sorted(EXPECTED_FORMULAE)}, got {sorted(actual_formulae)}",
    )
    formula_paths: set[str] = set()
    for name, entry in formulae.items():
        _require(isinstance(entry, dict), f"{name} lock entry must be an object")
        _exact_keys(
            entry,
            {
                "version",
                "revision",
                "versionScheme",
                "installedVersion",
                "source",
                "license",
                "formulaPath",
                "formulaSha256",
                "dependencies",
            },
            name,
        )
        version = entry["version"]
        revision = entry["revision"]
        _require(
            isinstance(version, str) and bool(version), f"{name} has no stable version"
        )
        _require(
            isinstance(revision, int) and revision >= 0,
            f"{name} has an invalid revision",
        )
        _require(
            isinstance(entry["versionScheme"], int) and entry["versionScheme"] >= 0,
            f"{name} has an invalid version scheme",
        )
        installed = version + (f"_{revision}" if revision else "")
        _require(
            entry["installedVersion"] == installed,
            f"{name} installed version is inconsistent",
        )
        _require(
            isinstance(entry["license"], (str, dict)),
            f"{name} has no SPDX license expression",
        )

        source = entry["source"]
        _require(isinstance(source, dict), f"{name} source must be an object")
        _exact_keys(source, {"url", "sha256"}, f"{name} source")
        _require(
            str(source["url"]).startswith("https://"), f"{name} source is not HTTPS"
        )
        _require(
            bool(HEX_SHA256.fullmatch(str(source["sha256"]))),
            f"{name} source SHA-256 is invalid",
        )

        formula_path = entry["formulaPath"]
        _require(isinstance(formula_path, str), f"{name} formula path is invalid")
        parts = Path(formula_path).parts
        _require(
            len(parts) >= 3
            and parts[0] == "Formula"
            and ".." not in parts
            and not Path(formula_path).is_absolute(),
            f"{name} formula path is unsafe",
        )
        _require(
            formula_path not in formula_paths, f"duplicate formula path: {formula_path}"
        )
        formula_paths.add(formula_path)
        _require(
            bool(HEX_SHA256.fullmatch(str(entry["formulaSha256"]))),
            f"{name} formula SHA-256 is invalid",
        )

        dependencies = entry["dependencies"]
        _require(
            isinstance(dependencies, dict), f"{name} dependencies must be an object"
        )
        _exact_keys(dependencies, {"runtime", "build"}, f"{name} dependencies")
        for kind in ("runtime", "build"):
            values = dependencies[kind]
            _require(
                isinstance(values, list) and values == sorted(set(values)),
                f"{name} {kind} dependencies must be sorted and unique",
            )
            _require(
                set(values) <= actual_formulae,
                f"{name} has an unlocked {kind} dependency",
            )

    closure: set[str] = set()
    pending = list(EXPECTED_REQUESTED)
    while pending:
        name = pending.pop()
        if name in closure:
            continue
        closure.add(name)
        dependencies = formulae[name]["dependencies"]
        pending.extend(dependencies["runtime"])
        pending.extend(dependencies["build"])
    _require(
        closure == EXPECTED_FORMULAE,
        "locked formulae are not the exact requested dependency closure",
    )


def verify_formula_file(core_repository: Path, formula: dict[str, Any]) -> None:
    root = core_repository.resolve()
    candidate = root / formula["formulaPath"]
    try:
        resolved = candidate.resolve(strict=True)
        resolved.relative_to(root)
    except (OSError, ValueError) as exc:
        raise LockError(
            f"formula path escapes the pinned core checkout: {candidate}"
        ) from exc
    _require(
        resolved.is_file() and not candidate.is_symlink(),
        f"formula is not a regular file: {candidate}",
    )
    actual = sha256_file(resolved)
    _require(
        actual == formula["formulaSha256"],
        f"formula SHA-256 mismatch for {formula['formulaPath']}: expected {formula['formulaSha256']}, got {actual}",
    )


def _git_head(repository: Path) -> str:
    try:
        return subprocess.run(
            ["git", "-C", str(repository), "rev-parse", "HEAD"],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError) as exc:
        raise LockError(f"cannot inspect Git checkout {repository}: {exc}") from exc


def _run(command: list[str]) -> str:
    environment = os.environ.copy()
    environment.update(
        {
            "HOMEBREW_NO_AUTO_UPDATE": "1",
            "HOMEBREW_NO_INSTALL_FROM_API": "1",
            "HOMEBREW_NO_ANALYTICS": "1",
        }
    )
    try:
        return subprocess.run(
            command,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
        ).stdout
    except (OSError, subprocess.CalledProcessError) as exc:
        stderr = getattr(exc, "stderr", "")
        raise LockError(
            f"{' '.join(command)} failed: {str(stderr).strip() or exc}"
        ) from exc


def validate_formula_metadata(lock: dict[str, Any], metadata: dict[str, Any]) -> None:
    entries = metadata.get("formulae")
    _require(isinstance(entries, list), "brew info did not return formula metadata")
    by_name = {
        str(entry.get("name")): entry for entry in entries if isinstance(entry, dict)
    }
    _require(
        set(by_name) == EXPECTED_FORMULAE,
        "brew info returned an unexpected formula set",
    )
    for name, expected in lock["formulae"].items():
        actual = by_name[name]
        stable = actual.get("urls", {}).get("stable", {})
        comparisons = (
            (actual.get("versions", {}).get("stable"), expected["version"], "version"),
            (actual.get("revision"), expected["revision"], "revision"),
            (actual.get("version_scheme"), expected["versionScheme"], "version scheme"),
            (stable.get("url"), expected["source"]["url"], "source URL"),
            (stable.get("checksum"), expected["source"]["sha256"], "source SHA-256"),
            (actual.get("license"), expected["license"], "license"),
            (
                sorted(actual.get("dependencies") or []),
                expected["dependencies"]["runtime"],
                "runtime dependencies",
            ),
            (
                sorted(actual.get("build_dependencies") or []),
                expected["dependencies"]["build"],
                "build dependencies",
            ),
        )
        for value, locked, label in comparisons:
            _require(value == locked, f"{name} {label} drifted from homebrew-lock.json")
        _require(
            not actual.get("recommended_dependencies"),
            f"{name} gained a recommended dependency",
        )
        _require(
            not actual.get("optional_dependencies"),
            f"{name} gained an optional dependency",
        )


def verify_source(
    lock: dict[str, Any], brew_repository: Path, core_repository: Path
) -> None:
    _require(
        _git_head(brew_repository) == BREW_COMMIT,
        "Homebrew checkout is not at the reviewed commit",
    )
    _require(
        _git_head(core_repository) == CORE_COMMIT,
        "homebrew-core checkout is not at the reviewed commit",
    )
    for entry in lock["formulae"].values():
        verify_formula_file(core_repository, entry)
    metadata = json.loads(
        _run(["brew", "info", "--json=v2", *sorted(EXPECTED_FORMULAE)])
    )
    _require(isinstance(metadata, dict), "brew info returned invalid metadata")
    validate_formula_metadata(lock, metadata)


def formula_install_order(lock: dict[str, Any]) -> list[str]:
    order: list[str] = []
    visited: set[str] = set()

    def visit(name: str) -> None:
        if name in visited:
            return
        visited.add(name)
        dependencies = lock["formulae"][name]["dependencies"]
        for dependency in dependencies["build"] + dependencies["runtime"]:
            visit(dependency)
        order.append(name)

    for formula in EXPECTED_REQUESTED:
        visit(formula)
    for formula in sorted(EXPECTED_FORMULAE):
        visit(formula)
    return order


def validate_receipts(lock: dict[str, Any], receipts: dict[str, Any]) -> None:
    _exact_keys(
        receipts,
        {
            "schemaVersion",
            "lockFileSha256",
            "homebrewCommit",
            "coreCommit",
            "buildMode",
            "brewConfig",
            "formulae",
        },
        "Homebrew provenance",
    )
    _require(receipts["schemaVersion"] == 1, "unsupported Homebrew provenance schema")
    _require(
        bool(HEX_SHA256.fullmatch(str(receipts["lockFileSha256"]))),
        "lock file digest is invalid",
    )
    _require(
        receipts["homebrewCommit"] == BREW_COMMIT, "receipt Homebrew commit mismatch"
    )
    _require(
        receipts["coreCommit"] == CORE_COMMIT, "receipt homebrew-core commit mismatch"
    )
    _require(
        receipts["buildMode"] == "build-from-source", "receipt build mode is not source"
    )
    _require(
        f"HEAD: {BREW_COMMIT}" in receipts["brewConfig"],
        "brew config does not identify the reviewed Homebrew commit",
    )
    formulae = receipts["formulae"]
    _require(isinstance(formulae, dict), "receipt formulae must be an object")
    _require(set(formulae) == EXPECTED_FORMULAE, "install receipt formula set mismatch")
    for name, locked in lock["formulae"].items():
        item = formulae[name]
        _require(isinstance(item, dict), f"{name} receipt entry must be an object")
        _exact_keys(
            item,
            {"installedVersion", "receiptSha256", "receipt"},
            f"{name} receipt entry",
        )
        _require(
            item["installedVersion"] == locked["installedVersion"],
            f"{name} installed version mismatch",
        )
        receipt = item["receipt"]
        _require(isinstance(receipt, dict), f"{name} install receipt must be an object")
        _require(
            receipt.get("poured_from_bottle") is False,
            f"{name} was poured from a bottle",
        )
        _require(
            receipt.get("built_as_bottle") is False, f"{name} was built as a bottle"
        )
        _require(
            receipt.get("loaded_from_api") is not True,
            f"{name} was loaded from the formula API",
        )
        _require(
            receipt.get("loaded_from_internal_api") is not True,
            f"{name} was loaded from the internal API",
        )
        _require(receipt.get("arch") == "arm64", f"{name} was not built for arm64")
        source = receipt.get("source")
        _require(isinstance(source, dict), f"{name} receipt has no formula source")
        _require(
            source.get("spec") == "stable",
            f"{name} was not built from the stable source",
        )
        _require(
            source.get("tap") == "homebrew/core",
            f"{name} was not built from homebrew/core",
        )
        _require(
            source.get("tap_git_head") == CORE_COMMIT,
            f"{name} receipt core commit mismatch",
        )
        versions = source.get("versions") or {}
        _require(
            versions.get("stable") == locked["version"],
            f"{name} receipt version mismatch",
        )
        _require(
            versions.get("version_scheme") == locked["versionScheme"],
            f"{name} version scheme mismatch",
        )
        _require(
            item["receiptSha256"] == json_digest(receipt),
            f"{name} receipt SHA-256 mismatch",
        )


def collect_receipts(
    lock: dict[str, Any], lock_path: Path, core_repository: Path
) -> dict[str, Any]:
    cellar = Path(_run(["brew", "--cellar"]).strip())
    formulae: dict[str, Any] = {}
    for name, entry in lock["formulae"].items():
        receipt_path = (
            cellar / name / entry["installedVersion"] / "INSTALL_RECEIPT.json"
        )
        receipt = load_json(receipt_path)
        source_path = Path(str((receipt.get("source") or {}).get("path") or ""))
        _require(
            source_path.is_absolute(),
            f"{name} receipt has no absolute formula source path",
        )
        try:
            source_path.resolve(strict=True).relative_to(core_repository.resolve())
        except (OSError, ValueError) as exc:
            raise LockError(
                f"{name} receipt formula path is outside the pinned core checkout"
            ) from exc
        _require(
            source_path.resolve(strict=True)
            == (core_repository / entry["formulaPath"]).resolve(strict=True),
            f"{name} receipt formula path does not match the lock",
        )
        formulae[name] = {
            "installedVersion": entry["installedVersion"],
            "receiptSha256": json_digest(receipt),
            "receipt": receipt,
        }
    provenance = {
        "schemaVersion": 1,
        "lockFileSha256": sha256_file(lock_path),
        "homebrewCommit": BREW_COMMIT,
        "coreCommit": CORE_COMMIT,
        "buildMode": "build-from-source",
        "brewConfig": _run(["brew", "config"]),
        "formulae": formulae,
    }
    validate_receipts(lock, provenance)
    return provenance


def load_homebrew_provenance(
    lock_path: Path, provenance_path: Path
) -> tuple[dict[str, Any], dict[str, Any]]:
    lock = load_lock(lock_path)
    provenance = load_json(provenance_path)
    validate_receipts(lock, provenance)
    _require(
        provenance["lockFileSha256"] == sha256_file(lock_path),
        "Homebrew lock file digest mismatch",
    )
    return lock, provenance


class HomebrewLockSelfTests(unittest.TestCase):
    def setUp(self) -> None:
        self.lock = json.loads(
            (Path(__file__).with_name("homebrew-lock.json")).read_text(encoding="utf-8")
        )

    def test_tampered_formula_file_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            formula = copy.deepcopy(self.lock["formulae"]["cmake"])
            path = root / formula["formulaPath"]
            path.parent.mkdir(parents=True)
            path.write_text("class Cmake < Formula; end\n", encoding="utf-8")
            with self.assertRaisesRegex(LockError, "formula SHA-256 mismatch"):
                verify_formula_file(root, formula)

    def test_unexpected_formula_is_rejected(self) -> None:
        tampered = copy.deepcopy(self.lock)
        tampered["formulae"]["surprise"] = copy.deepcopy(tampered["formulae"]["cmake"])
        with self.assertRaisesRegex(LockError, "formula set mismatch"):
            validate_lock(tampered)

    def test_bottle_receipt_is_rejected(self) -> None:
        formulae = self.lock["formulae"]
        receipt_entries: dict[str, Any] = {}
        for name, entry in formulae.items():
            receipt = {
                "homebrew_version": "test",
                "poured_from_bottle": name == "cmake",
                "built_as_bottle": name == "cmake",
                "loaded_from_api": False,
                "loaded_from_internal_api": False,
                "arch": "arm64",
                "source": {
                    "spec": "stable",
                    "versions": {
                        "stable": entry["version"],
                        "version_scheme": entry["versionScheme"],
                    },
                    "tap": "homebrew/core",
                    "tap_git_head": self.lock["core"]["commit"],
                },
            }
            receipt_entries[name] = {
                "installedVersion": entry["installedVersion"],
                "receiptSha256": json_digest(receipt),
                "receipt": receipt,
            }
        receipts = {
            "schemaVersion": 1,
            "lockFileSha256": "0" * 64,
            "homebrewCommit": self.lock["homebrew"]["commit"],
            "coreCommit": self.lock["core"]["commit"],
            "buildMode": self.lock["install"]["mode"],
            "brewConfig": "HEAD: " + self.lock["homebrew"]["commit"],
            "formulae": receipt_entries,
        }
        with self.assertRaisesRegex(LockError, "was poured from a bottle"):
            validate_receipts(self.lock, receipts)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "command", choices=("source", "installed", "formulae", "self-test")
    )
    parser.add_argument(
        "--lock",
        type=Path,
        default=Path(__file__).with_name("homebrew-lock.json"),
    )
    parser.add_argument("--brew-repository", type=Path)
    parser.add_argument("--core-repository", type=Path)
    parser.add_argument("--provenance-out", type=Path)
    args = parser.parse_args()
    if args.command == "self-test":
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(HomebrewLockSelfTests)
        return (
            0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1
        )
    try:
        lock = load_lock(args.lock)
        if args.command == "formulae":
            print("\n".join(formula_install_order(lock)))
            return 0
        _require(args.brew_repository is not None, "--brew-repository is required")
        _require(args.core_repository is not None, "--core-repository is required")
        verify_source(lock, args.brew_repository, args.core_repository)
        if args.command == "source":
            print(f"Verified {len(lock['formulae'])} locked Homebrew formulae.")
            return 0
        _require(args.provenance_out is not None, "--provenance-out is required")
        provenance = collect_receipts(lock, args.lock, args.core_repository)
        args.provenance_out.parent.mkdir(parents=True, exist_ok=True)
        args.provenance_out.write_text(
            json.dumps(provenance, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        print(f"Recorded {len(provenance['formulae'])} source-build receipts.")
        return 0
    except (LockError, json.JSONDecodeError) as exc:
        print(f"Homebrew lock verification failed: {exc}", file=os.sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
