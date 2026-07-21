from __future__ import annotations

import importlib.util
import json
import os
import tempfile
import unittest
from unittest import mock
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "verify_notarization_receipt.py"
SPEC = importlib.util.spec_from_file_location("verify_notarization_receipt", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
SUBMISSION_ID = "a2a4ed8f-4d52-47d5-bf09-0c682d8146c9"


class VerifyNotarizationReceiptTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory(
            prefix="easysplat-notary-receipt-test."
        )
        self.root = Path(self.temporary_directory.name).resolve()

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def _receipt(self, artifact_type: str, artifact: Path) -> Path:
        post_digest = MODULE.artifact_sha256(artifact)
        payload = {
            "schemaVersion": 1,
            "artifactType": artifact_type,
            "artifactDigestFormat": (
                "sha256-tree-v1" if artifact_type == "app" else "sha256-file-v1"
            ),
            "submissionID": SUBMISSION_ID,
            "status": "Accepted",
            "preStapleSHA256": "0" * 64,
            "postStapleSHA256": post_digest,
            "stapled": True,
            "verification": {
                "codesign": "passed",
                "systemPolicy": (
                    "passed" if artifact_type == "app" else "notApplicable"
                ),
                "stapler": "passed",
                "gatekeeper": "passed",
            },
            "downstreamChecksums": "generate-after-notarization",
        }
        receipt = self.root / f"{artifact_type}-receipt.json"
        receipt.write_text(json.dumps(payload), encoding="utf-8")
        return receipt

    def _signing_receipt(self, artifact_type: str, pre_staple_digest: str) -> Path:
        receipt = self.root / f"{artifact_type}-signing.json"
        receipt.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "rootKind": artifact_type,
                    "artifactDigest": {
                        "format": (
                            "sha256-tree-v1"
                            if artifact_type == "app"
                            else "sha256-file-v1"
                        ),
                        "postSignSHA256": pre_staple_digest,
                    },
                }
            ),
            encoding="utf-8",
        )
        return receipt

    def test_cross_binds_signing_postsign_to_notarization_prestaple(self) -> None:
        artifact = self.root / "EasySplat.dmg"
        artifact.write_bytes(b"signed and stapled disk image")
        notary_receipt = self._receipt("dmg", artifact)
        notary_payload = json.loads(notary_receipt.read_text(encoding="utf-8"))

        wrong = self._signing_receipt("dmg", "f" * 64)
        with self.assertRaisesRegex(MODULE.ReceiptError, "post-sign.*pre-staple"):
            MODULE.validate_notarization_receipt(
                notary_receipt,
                artifact,
                "dmg",
                signing_receipt=wrong,
            )

        notary_payload["preStapleSHA256"] = "e" * 64
        notary_receipt.write_text(json.dumps(notary_payload), encoding="utf-8")
        correct = self._signing_receipt("dmg", "e" * 64)
        payload = MODULE.validate_notarization_receipt(
            notary_receipt,
            artifact,
            "dmg",
            signing_receipt=correct,
        )
        self.assertEqual(payload["preStapleSHA256"], "e" * 64)

    def test_artifact_is_rebound_after_the_signing_receipt_is_read(self) -> None:
        artifact = self.root / "EasySplat.dmg"
        artifact.write_bytes(b"signed and stapled disk image")
        receipt = self._receipt("dmg", artifact)
        payload = json.loads(receipt.read_text(encoding="utf-8"))
        payload["preStapleSHA256"] = "e" * 64
        receipt.write_text(json.dumps(payload), encoding="utf-8")
        signing = self._signing_receipt("dmg", "e" * 64)
        real_read = MODULE._read_stable_json
        mutated = False

        def mutating_read(path: Path, **kwargs: object):
            nonlocal mutated
            result = real_read(path, **kwargs)
            if path == signing and not mutated:
                artifact.write_bytes(b"different bytes after receipt validation")
                mutated = True
            return result

        with mock.patch.object(MODULE, "_read_stable_json", side_effect=mutating_read):
            with self.assertRaisesRegex(MODULE.ReceiptError, "artifact.*changed|current artifact"):
                MODULE.validate_notarization_receipt(
                    receipt,
                    artifact,
                    "dmg",
                    signing_receipt=signing,
                )
        self.assertTrue(mutated)

    def test_notarization_receipt_path_is_rebound_before_success(self) -> None:
        artifact = self.root / "EasySplat.dmg"
        artifact.write_bytes(b"signed and stapled disk image")
        receipt = self._receipt("dmg", artifact)
        attacker = self.root / "attacker-notarization.json"
        attacker.write_text('{"status":"forged"}', encoding="utf-8")
        original = self.root / "original-notarization.json"
        real_read = MODULE._read_stable_json
        substituted = False

        def substituting_read(path: Path, **kwargs: object):
            nonlocal substituted
            result = real_read(path, **kwargs)
            if path == receipt and not substituted:
                receipt.rename(original)
                attacker.rename(receipt)
                substituted = True
            return result

        with mock.patch.object(MODULE, "_read_stable_json", side_effect=substituting_read):
            with self.assertRaisesRegex(
                MODULE.ReceiptError,
                "notarization receipt.*changed|notarization receipt.*identity",
            ):
                MODULE.validate_notarization_receipt(receipt, artifact, "dmg")
        self.assertTrue(substituted)

    def test_signing_receipt_path_is_rebound_before_success(self) -> None:
        artifact = self.root / "EasySplat.dmg"
        artifact.write_bytes(b"signed and stapled disk image")
        receipt = self._receipt("dmg", artifact)
        payload = json.loads(receipt.read_text(encoding="utf-8"))
        payload["preStapleSHA256"] = "e" * 64
        receipt.write_text(json.dumps(payload), encoding="utf-8")
        signing = self._signing_receipt("dmg", "e" * 64)
        attacker = self.root / "attacker-signing-after-read.json"
        attacker.write_text('{"status":"forged"}', encoding="utf-8")
        original = self.root / "original-signing-after-read.json"
        real_read = MODULE._read_stable_json
        substituted = False

        def substituting_read(path: Path, **kwargs: object):
            nonlocal substituted
            result = real_read(path, **kwargs)
            if path == signing and not substituted:
                signing.rename(original)
                attacker.rename(signing)
                substituted = True
            return result

        with mock.patch.object(MODULE, "_read_stable_json", side_effect=substituting_read):
            with self.assertRaisesRegex(
                MODULE.ReceiptError,
                "signing receipt.*changed|signing receipt.*identity",
            ):
                MODULE.validate_notarization_receipt(
                    receipt,
                    artifact,
                    "dmg",
                    signing_receipt=signing,
                )
        self.assertTrue(substituted)

    def test_empty_regular_app_resources_are_part_of_the_digest(self) -> None:
        app = self.root / "EasySplat.app"
        executable = app / "Contents/MacOS/EasySplatApp"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"signed app")
        empty = app / "Contents/Resources/empty.dat"
        empty.parent.mkdir(parents=True)
        empty.write_bytes(b"")

        self.assertRegex(MODULE.artifact_sha256(app), r"^[0-9a-f]{64}$")

    def test_validates_app_and_dmg_receipts_against_current_artifact_bytes(self) -> None:
        app = self.root / "EasySplat.app"
        executable = app / "Contents/MacOS/EasySplatApp"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"signed and stapled app")
        dmg = self.root / "EasySplat.dmg"
        dmg.write_bytes(b"signed and stapled disk image")

        app_payload = MODULE.validate_notarization_receipt(
            self._receipt("app", app), app, "app"
        )
        dmg_payload = MODULE.validate_notarization_receipt(
            self._receipt("dmg", dmg), dmg, "dmg"
        )

        self.assertEqual(
            app_payload["postStapleSHA256"], MODULE.artifact_sha256(app)
        )
        self.assertEqual(
            dmg_payload["postStapleSHA256"], MODULE.artifact_sha256(dmg)
        )

    def test_rejects_artifact_mutation_and_false_verification_claims(self) -> None:
        dmg = self.root / "EasySplat.dmg"
        dmg.write_bytes(b"signed and stapled disk image")
        receipt = self._receipt("dmg", dmg)
        dmg.write_bytes(b"mutated after receipt")

        with self.assertRaisesRegex(MODULE.ReceiptError, "current artifact bytes"):
            MODULE.validate_notarization_receipt(receipt, dmg, "dmg")

        dmg.write_bytes(b"signed and stapled disk image")
        payload = json.loads(receipt.read_text(encoding="utf-8"))
        payload["verification"]["codesign"] = "notApplicable"
        receipt.write_text(json.dumps(payload), encoding="utf-8")
        with self.assertRaisesRegex(MODULE.ReceiptError, "verification results"):
            MODULE.validate_notarization_receipt(receipt, dmg, "dmg")

    def test_stable_identity_uses_non_resettable_change_time(self) -> None:
        artifact = self.root / "EasySplat.dmg"
        artifact.write_bytes(b"signed and stapled disk image")
        before = artifact.stat()
        os.utime(
            artifact,
            ns=(before.st_atime_ns + 1_000_000_000, before.st_mtime_ns),
        )
        after = artifact.stat()

        self.assertNotEqual(before.st_atime_ns, after.st_atime_ns)
        self.assertNotEqual(
            MODULE._stable_file_identity(before),
            MODULE._stable_file_identity(after),
        )

    def test_same_inode_same_size_receipt_restore_is_rejected(self) -> None:
        artifact = self.root / "EasySplat.dmg"
        artifact.write_bytes(b"signed and stapled disk image")
        receipt = self._receipt("dmg", artifact)
        original = receipt.read_bytes()
        attacker = original.replace(b'"Accepted"', b'"Rejected"')
        self.assertEqual(len(attacker), len(original))
        original_mtime = receipt.stat().st_mtime_ns
        real_read = MODULE.os.read
        swapped = False

        def swapping_read(descriptor: int, count: int) -> bytes:
            nonlocal swapped
            if not swapped:
                swapped = True
                receipt.write_bytes(attacker)
                data = real_read(descriptor, count)
                receipt.write_bytes(original)
                os.utime(receipt, ns=(receipt.stat().st_atime_ns, original_mtime))
                return data
            return real_read(descriptor, count)

        with mock.patch.object(MODULE.os, "read", side_effect=swapping_read):
            with self.assertRaisesRegex(MODULE.ReceiptError, "changed"):
                MODULE.validate_notarization_receipt(receipt, artifact, "dmg")
        self.assertTrue(swapped)

    def test_artifact_file_swap_and_restore_is_rejected(self) -> None:
        artifact = self.root / "EasySplat.dmg"
        artifact.write_bytes(b"signed and stapled disk image")
        receipt = self._receipt("dmg", artifact)
        attacker = self.root / "attacker.dmg"
        attacker.write_bytes(artifact.read_bytes())
        original = self.root / "original.dmg"
        real_open = MODULE.os.open
        swapped = False

        def swapping_open(path: object, flags: int, *args: object, **kwargs: object) -> int:
            nonlocal swapped
            if not swapped and Path(path) == artifact:
                swapped = True
                artifact.rename(original)
                attacker.rename(artifact)
                descriptor = real_open(path, flags, *args, **kwargs)
                artifact.rename(attacker)
                original.rename(artifact)
                return descriptor
            return real_open(path, flags, *args, **kwargs)

        with mock.patch.object(MODULE.os, "open", side_effect=swapping_open):
            with self.assertRaisesRegex(MODULE.ReceiptError, "identity|changed"):
                MODULE.validate_notarization_receipt(receipt, artifact, "dmg")
        self.assertTrue(swapped)

    def test_app_tree_addition_during_hash_is_rejected(self) -> None:
        app = self.root / "EasySplat.app"
        executable = app / "Contents/MacOS/EasySplatApp"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"signed app")
        receipt = self._receipt("app", app)
        real_scandir = MODULE.os.scandir
        added = False

        def adding_scandir(path: object):
            nonlocal added
            entries = list(real_scandir(path))
            if not added and (isinstance(path, int) or Path(path) == app):
                added = True
                (app / "late-file").write_bytes(b"late")
            return entries

        with mock.patch.object(MODULE.os, "scandir", side_effect=adding_scandir):
            with self.assertRaisesRegex(MODULE.ReceiptError, "changed"):
                MODULE.validate_notarization_receipt(receipt, app, "app")
        self.assertTrue(added)

    def test_app_root_swap_across_both_tree_scans_is_rejected(self) -> None:
        app = self.root / "EasySplat.app"
        executable = app / "Contents/MacOS/EasySplatApp"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"current unnotarized app")
        attacker = self.root / "Notarized.app"
        attacker_executable = attacker / "Contents/MacOS/EasySplatApp"
        attacker_executable.parent.mkdir(parents=True)
        attacker_executable.write_bytes(b"different notarized app")
        receipt = self._receipt("app", attacker)
        original = self.root / "Original.app"
        real_snapshot = MODULE._tree_snapshot
        calls = 0

        def swapping_snapshot(root: Path):
            nonlocal calls
            if Path(root) != app:
                return real_snapshot(root)
            if calls == 0:
                app.rename(original)
                attacker.rename(app)
            snapshot = real_snapshot(root)
            calls += 1
            if calls == 2:
                app.rename(attacker)
                original.rename(app)
            return snapshot

        with mock.patch.object(MODULE, "_tree_snapshot", side_effect=swapping_snapshot):
            with self.assertRaisesRegex(MODULE.ReceiptError, "current artifact bytes"):
                MODULE.validate_notarization_receipt(receipt, app, "app")
        self.assertEqual(executable.read_bytes(), b"current unnotarized app")
        self.assertEqual(calls, 0)

    def test_receipt_swap_and_restore_is_rejected(self) -> None:
        artifact = self.root / "EasySplat.dmg"
        artifact.write_bytes(b"signed and stapled disk image")
        receipt = self._receipt("dmg", artifact)
        attacker = self.root / "attacker-receipt.json"
        attacker.write_bytes(receipt.read_bytes())
        original = self.root / "original-receipt.json"
        real_open = MODULE.os.open
        swapped = False

        def swapping_open(path: object, flags: int, *args: object, **kwargs: object) -> int:
            nonlocal swapped
            if not swapped and Path(path) == receipt:
                swapped = True
                receipt.rename(original)
                attacker.rename(receipt)
                descriptor = real_open(path, flags, *args, **kwargs)
                receipt.rename(attacker)
                original.rename(receipt)
                return descriptor
            return real_open(path, flags, *args, **kwargs)

        with mock.patch.object(MODULE.os, "open", side_effect=swapping_open):
            with self.assertRaisesRegex(MODULE.ReceiptError, "changed|identity"):
                MODULE.validate_notarization_receipt(receipt, artifact, "dmg")
        self.assertTrue(swapped)

    def test_signing_receipt_swap_and_restore_is_rejected(self) -> None:
        artifact = self.root / "EasySplat.dmg"
        artifact.write_bytes(b"signed and stapled disk image")
        receipt = self._receipt("dmg", artifact)
        payload = json.loads(receipt.read_text(encoding="utf-8"))
        payload["preStapleSHA256"] = "e" * 64
        receipt.write_text(json.dumps(payload), encoding="utf-8")
        signing = self._signing_receipt("dmg", "e" * 64)
        attacker = self.root / "attacker-signing.json"
        attacker.write_bytes(signing.read_bytes())
        original = self.root / "original-signing.json"
        real_open = MODULE.os.open
        swapped = False

        def swapping_open(path: object, flags: int, *args: object, **kwargs: object) -> int:
            nonlocal swapped
            if not swapped and Path(path) == signing:
                swapped = True
                signing.rename(original)
                attacker.rename(signing)
                descriptor = real_open(path, flags, *args, **kwargs)
                signing.rename(attacker)
                original.rename(signing)
                return descriptor
            return real_open(path, flags, *args, **kwargs)

        with mock.patch.object(MODULE.os, "open", side_effect=swapping_open):
            with self.assertRaisesRegex(MODULE.ReceiptError, "changed|identity"):
                MODULE.validate_notarization_receipt(
                    receipt,
                    artifact,
                    "dmg",
                    signing_receipt=signing,
                )
        self.assertTrue(swapped)

    def test_artifact_type_must_match_file_or_directory_contract(self) -> None:
        directory = self.root / "not-a-dmg"
        directory.mkdir()
        directory_receipt = self._receipt("dmg", directory)
        with self.assertRaisesRegex(MODULE.ReceiptError, "directory|regular file"):
            MODULE.validate_notarization_receipt(
                directory_receipt, directory, "dmg"
            )

        file = self.root / "not-an-app"
        file.write_bytes(b"file")
        file_receipt = self._receipt("app", file)
        with self.assertRaisesRegex(MODULE.ReceiptError, "directory"):
            MODULE.validate_notarization_receipt(file_receipt, file, "app")


if __name__ == "__main__":
    unittest.main()
