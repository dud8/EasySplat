from __future__ import annotations

import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock


VALIDATOR = Path(__file__).resolve().parents[1] / "validate_da3_payload.py"
MODEL_REVISIONS = {
    "DA3-BASE": (
        "depth-anything/DA3-BASE",
        "f4a6c9b3c95e41c82048423d3493a81ec3fa810e",
    ),
    "DA3-SMALL": (
        "depth-anything/DA3-SMALL",
        "e08cab65ca0ec38e7826075418411ab90cab4da3",
    ),
}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class Da3PayloadTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if not VALIDATOR.is_file():
            raise AssertionError(f"DA3 payload validator is missing: {VALIDATOR}")
        spec = importlib.util.spec_from_file_location("validate_da3_payload", VALIDATOR)
        assert spec and spec.loader
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    def make_payload(self, root: Path) -> None:
        for directory in (
            "app/easysplat_da3_sfm",
            "bin",
            "licenses/python-build-standalone/licenses",
            "models/DA3-BASE",
            "models/DA3-SMALL",
            "python/bin",
            "python/lib/python3.13/site-packages",
            "vendor/depth-anything-3/src/depth_anything_3",
        ):
            (root / directory).mkdir(parents=True, exist_ok=True)

        runner = root / "bin/easysplat_da3_sfm"
        runner.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        runner.chmod(0o755)
        python = root / "python/bin/python3"
        python.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        python.chmod(0o755)
        for name in ("__init__.py", "alignment.py", "run.py"):
            (root / "app/easysplat_da3_sfm" / name).write_text(
                f"# {name}\n", encoding="utf-8"
            )
        for model, (repo_id, revision) in MODEL_REVISIONS.items():
            model_root = root / "models" / model
            (model_root / "LICENSE").write_text("Apache-2.0\n", encoding="utf-8")
            (model_root / "config.json").write_text(
                json.dumps({"model": model}) + "\n", encoding="utf-8"
            )
            (model_root / "model.safetensors").write_bytes(
                f"{model}:weights\n".encode()
            )
            artifacts = {
                name: {
                    "sha256": sha256(model_root / name),
                    "size_bytes": (model_root / name).stat().st_size,
                }
                for name in ("config.json", "model.safetensors")
            }
            (model_root / "easysplat_model_info.json").write_text(
                json.dumps(
                    {
                        "repo_id": repo_id,
                        "requested_revision": revision,
                        "resolved_sha": revision,
                        "license": "apache-2.0",
                        "artifacts": artifacts,
                    },
                    sort_keys=True,
                )
                + "\n",
                encoding="utf-8",
            )
        (root / "vendor/depth-anything-3/LICENSE").write_text(
            "Apache-2.0\n", encoding="utf-8"
        )
        (root / "vendor/depth-anything-3/src/depth_anything_3/api.py").write_text(
            "# api.py\n", encoding="utf-8"
        )

        requirements = root / "licenses/python-packages-requirements.txt"
        requirements.write_text("numpy==2.3.5\n", encoding="utf-8")
        supplemental = root / "licenses/python-package-upstream-notices.json"
        supplemental.write_text(
            json.dumps({"schemaVersion": 1, "notices": []}) + "\n",
            encoding="utf-8",
        )
        (root / "licenses/python-packages-install-report.json").write_text(
            json.dumps({"install": []}) + "\n", encoding="utf-8"
        )
        (root / "licenses/python-build-standalone/PYTHON.json").write_text(
            "{}\n", encoding="utf-8"
        )

        receipt = {
            "toolchain_name": "da3_mps",
            "source_repo": "https://github.com/ByteDance-Seed/Depth-Anything-3.git",
            "source_ref": "a" * 40,
            "source_commit": "a" * 40,
            "source_path": "git:https://example.com/da3.git@" + "a" * 40,
            "source_provenance": "pinned-git",
            "expected_upstream_repo": "https://github.com/ByteDance-Seed/Depth-Anything-3.git",
            "expected_upstream_ref": "a" * 40,
            "base_checkpoint_repo": "depth-anything/DA3-BASE",
            "base_checkpoint_revision": MODEL_REVISIONS["DA3-BASE"][1],
            "base_checkpoint_commit": MODEL_REVISIONS["DA3-BASE"][1],
            "small_checkpoint_repo": "depth-anything/DA3-SMALL",
            "small_checkpoint_revision": MODEL_REVISIONS["DA3-SMALL"][1],
            "small_checkpoint_commit": MODEL_REVISIONS["DA3-SMALL"][1],
            "model_lock": "scripts/toolchain/da3-model-lock.json",
            "model_lock_sha256": "0" * 64,
            "python_version": "3.13.11",
            "python_standalone_url": "https://example.com/python.tar.gz",
            "python_standalone_sha256": "d" * 64,
            "python_standalone_license_archive_url": "https://example.com/python.tar.zst",
            "python_standalone_license_archive_sha256": "e" * 64,
            "requirements_lock": "Tools/Da3Sfm/requirements.txt",
            "requirements_lock_sha256": sha256(requirements),
            "runtime_patch": "Tools/Da3Sfm/patches/da3-api-lazy-export.patch",
            "runtime_patch_sha256": "f" * 64,
            "supplemental_license_manifest": "licenses/python-package-upstream-notices.json",
            "supplemental_license_manifest_sha256": sha256(supplemental),
            "pip_install_report": "licenses/python-packages-install-report.json",
            "torch_version": "2.12.1",
            "torchvision_version": "0.27.1",
            "huggingface_hub_version": "1.14.0",
        }
        (root / "build_info.json").write_text(
            json.dumps(receipt, sort_keys=True) + "\n", encoding="utf-8"
        )

    def fixture_model_lock(self) -> dict:
        models = {}
        for model, (repo_id, revision) in MODEL_REVISIONS.items():
            config = (json.dumps({"model": model}) + "\n").encode()
            weights = f"{model}:weights\n".encode()
            models[model] = {
                "repo_id": repo_id,
                "requested_revision": revision,
                "resolved_sha": revision,
                "license": "apache-2.0",
                "artifacts": {
                    "config.json": {
                        "sha256": hashlib.sha256(config).hexdigest(),
                        "size_bytes": len(config),
                    },
                    "model.safetensors": {
                        "sha256": hashlib.sha256(weights).hexdigest(),
                        "size_bytes": len(weights),
                    },
                },
            }
        return {"schema_version": 1, "models": models}

    def validate(self, root: Path) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            lock = Path(temporary) / "fixture-model-lock.json"
            lock.write_text(
                json.dumps(self.fixture_model_lock(), sort_keys=True) + "\n",
                encoding="utf-8",
            )
            receipt_path = root / "build_info.json"
            receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
            receipt["model_lock_sha256"] = sha256(lock)
            receipt_path.write_text(
                json.dumps(receipt, sort_keys=True) + "\n", encoding="utf-8"
            )
            with mock.patch.object(self.module, "DA3_MODEL_LOCK", lock):
                self.module.validate(root)

    def test_accepts_exact_optional_da3_runtime(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_payload(root)
            self.validate(root)

    def test_production_lock_pins_reviewed_model_bytes(self) -> None:
        lock = json.loads(
            (VALIDATOR.parent / "da3-model-lock.json").read_text(encoding="utf-8")
        )
        expected = {
            "DA3-BASE": {
                "config.json": (
                    1205,
                    "5e34115ebc17bd2d8d43033c5f72e9446ac8833fd61d3fa160b7e67e0bb5b7b5",
                ),
                "model.safetensors": (
                    541518028,
                    "e01067dc1659613083d9145a9a2547ccdbe6ccbbf83c4fe7b3e8a4e2bdae78b5",
                ),
            },
            "DA3-SMALL": {
                "config.json": (
                    1202,
                    "a486e29e82b7ab4a7d4cefc1ea4526cfe2ae438a572c8ca98917cfbcde7447d2",
                ),
                "model.safetensors": (
                    137248940,
                    "364492e38a3a06d221ac75da7f6621ada3f2361cd24fde11ba79091e9f40efcf",
                ),
            },
        }
        self.assertEqual(lock["schema_version"], 1)
        self.assertEqual(set(lock["models"]), set(expected))
        for model, artifacts in expected.items():
            repo_id, revision = MODEL_REVISIONS[model]
            self.assertEqual(
                {
                    field: lock["models"][model][field]
                    for field in (
                        "repo_id",
                        "requested_revision",
                        "resolved_sha",
                        "license",
                    )
                },
                {
                    "repo_id": repo_id,
                    "requested_revision": revision,
                    "resolved_sha": revision,
                    "license": "apache-2.0",
                },
            )
            for name, (size, digest) in artifacts.items():
                self.assertEqual(
                    lock["models"][model]["artifacts"][name],
                    {"size_bytes": size, "sha256": digest},
                )

    def test_rejects_retired_bridge_files(self) -> None:
        for relative in (
            "bin/easysplat_colmap",
            "app/easysplat_da3_sfm/colmap_cli.py",
        ):
            with (
                self.subTest(relative=relative),
                tempfile.TemporaryDirectory() as temporary,
            ):
                root = Path(temporary)
                self.make_payload(root)
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("retired\n", encoding="utf-8")
                with self.assertRaisesRegex(SystemExit, "exact"):
                    self.validate(root)

    def test_rejects_same_size_model_artifact_tampering(self) -> None:
        for model in MODEL_REVISIONS:
            for artifact in ("config.json", "model.safetensors"):
                with (
                    self.subTest(model=model, artifact=artifact),
                    tempfile.TemporaryDirectory() as temporary,
                ):
                    root = Path(temporary)
                    self.make_payload(root)
                    path = root / "models" / model / artifact
                    original = path.read_bytes()
                    path.write_bytes(bytes([original[0] ^ 1]) + original[1:])
                    self.assertEqual(path.stat().st_size, len(original))
                    with self.assertRaisesRegex(SystemExit, "artifact SHA-256"):
                        self.validate(root)

    def test_rejects_unreviewed_model_identity_and_metadata_fields(self) -> None:
        mutations = {
            "repo_id": "attacker/unreviewed-model",
            "requested_revision": "0" * 40,
            "resolved_sha": "0" * 40,
            "license": "mit",
            "unexpected": "not-reviewed",
        }
        for field, value in mutations.items():
            with (
                self.subTest(field=field),
                tempfile.TemporaryDirectory() as temporary,
            ):
                root = Path(temporary)
                self.make_payload(root)
                info_path = root / "models/DA3-BASE/easysplat_model_info.json"
                info = json.loads(info_path.read_text(encoding="utf-8"))
                info[field] = value
                info_path.write_text(
                    json.dumps(info, sort_keys=True) + "\n", encoding="utf-8"
                )
                with self.assertRaisesRegex(SystemExit, "model metadata"):
                    self.validate(root)

    def test_rejects_self_check_runtime_token(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_payload(root)
            runner = root / "bin/easysplat_da3_sfm"
            runner.write_text("#!/bin/sh\n# --self-check\n", encoding="utf-8")
            with self.assertRaisesRegex(SystemExit, "forbidden runtime token"):
                self.validate(root)

    def test_rejects_retired_receipt_fields(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_payload(root)
            receipt_path = root / "build_info.json"
            receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
            receipt["colmap_launcher_sha256"] = "a" * 64
            receipt_path.write_text(json.dumps(receipt) + "\n", encoding="utf-8")
            with self.assertRaisesRegex(SystemExit, "receipt fields"):
                self.validate(root)

    def test_rejects_retired_python_distribution(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_payload(root)
            (
                root / "python/lib/python3.13/site-packages/pycolmap-4.1.0.dist-info"
            ).mkdir()
            with self.assertRaisesRegex(SystemExit, "retired Python COLMAP"):
                self.validate(root)

    def test_rejects_every_symlink_in_the_payload(self) -> None:
        for relative in (
            "python/bin/python3",
            "vendor/depth-anything-3/src/linked.py",
            "licenses/linked-notice",
        ):
            with (
                self.subTest(relative=relative),
                tempfile.TemporaryDirectory() as temporary,
            ):
                root = Path(temporary)
                self.make_payload(root)
                target = root / "python/lib/python3.13/site-packages/target.txt"
                target.write_text("target\n", encoding="utf-8")
                link = root / relative
                link.parent.mkdir(parents=True, exist_ok=True)
                if link.exists():
                    link.unlink()
                link.symlink_to(target)
                with self.assertRaisesRegex(SystemExit, "symlink"):
                    self.validate(root)

    def test_rejects_directory_and_dangling_symlinks(self) -> None:
        for relative, target_relative in (
            ("python/linked-directory", "python/lib"),
            ("python/dangling", "missing-target"),
        ):
            with (
                self.subTest(relative=relative),
                tempfile.TemporaryDirectory() as temporary,
            ):
                root = Path(temporary)
                self.make_payload(root)
                (root / relative).symlink_to(root / target_relative)
                with self.assertRaisesRegex(SystemExit, "symlink"):
                    self.validate(root)


if __name__ == "__main__":
    unittest.main()
