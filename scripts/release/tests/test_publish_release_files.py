from __future__ import annotations

import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "publish_release_files.py"
SPEC = importlib.util.spec_from_file_location("publish_release_files", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PublishReleaseFilesTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory(
            prefix="easysplat-publication-test."
        )
        self.root = Path(self.temporary_directory.name).resolve()
        self.output = self.root / "release"
        self.output.mkdir(mode=0o700)
        self.stage = self.output / ".EasySplat-0.2.0.release.fixture"
        self.stage.mkdir(mode=0o700)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def _write_stage(self, name: str, payload: bytes) -> None:
        (self.stage / name).write_bytes(payload)

    def test_publishes_the_complete_validated_set_and_replaces_old_outputs(self) -> None:
        names = ("EasySplat.dmg", "EasySplat.dmg.sha256", "receipt.json")
        for index, name in enumerate(names):
            self._write_stage(name, f"new-{index}".encode())
        (self.output / names[0]).write_bytes(b"old-dmg")
        (self.output / names[1]).write_bytes(b"old-checksum")

        MODULE.publish_release_files(self.stage, self.output, list(names))

        self.assertEqual(
            [(self.output / name).read_bytes() for name in names],
            [b"new-0", b"new-1", b"new-2"],
        )
        self.assertEqual(list(self.stage.iterdir()), [])
        self.assertFalse((self.output / MODULE.LOCK_NAME).exists())

    def test_move_failure_rolls_back_every_old_and_new_output(self) -> None:
        names = ("one.dmg", "two.json", "three.txt")
        for index, name in enumerate(names):
            self._write_stage(name, f"new-{index}".encode())
        (self.output / names[0]).write_bytes(b"old-one")
        (self.output / names[1]).write_bytes(b"old-two")
        failure_injected = False

        def replace(source: str | os.PathLike[str], destination: str | os.PathLike[str]) -> None:
            nonlocal failure_injected
            source_path = Path(source)
            if (
                not failure_injected
                and source_path.parent == self.stage
                and source_path.name == names[2]
            ):
                failure_injected = True
                raise OSError("injected publication failure")
            os.replace(source, destination)

        with self.assertRaisesRegex(MODULE.PublicationError, "rolled back"):
            MODULE.publish_release_files(
                self.stage,
                self.output,
                list(names),
                replace=replace,
            )

        self.assertTrue(failure_injected)
        self.assertEqual((self.output / names[0]).read_bytes(), b"old-one")
        self.assertEqual((self.output / names[1]).read_bytes(), b"old-two")
        self.assertFalse((self.output / names[2]).exists())
        self.assertEqual(
            [(self.stage / name).read_bytes() for name in names],
            [b"new-0", b"new-1", b"new-2"],
        )
        self.assertFalse((self.output / MODULE.LOCK_NAME).exists())
        self.assertFalse((self.stage / MODULE.BACKUP_NAME).exists())

    def test_interruption_rolls_back_before_propagating(self) -> None:
        names = ("one.dmg", "two.json")
        for index, name in enumerate(names):
            self._write_stage(name, f"new-{index}".encode())
            (self.output / name).write_bytes(f"old-{index}".encode())

        def replace(source: str | os.PathLike[str], destination: str | os.PathLike[str]) -> None:
            source_path = Path(source)
            if source_path.parent == self.stage and source_path.name == names[1]:
                raise KeyboardInterrupt()
            os.replace(source, destination)

        with self.assertRaises(KeyboardInterrupt):
            MODULE.publish_release_files(
                self.stage,
                self.output,
                list(names),
                replace=replace,
            )

        self.assertEqual(
            [(self.output / name).read_bytes() for name in names],
            [b"old-0", b"old-1"],
        )
        self.assertEqual(
            [(self.stage / name).read_bytes() for name in names],
            [b"new-0", b"new-1"],
        )
        self.assertFalse((self.output / MODULE.LOCK_NAME).exists())
        self.assertFalse((self.stage / MODULE.BACKUP_NAME).exists())

    def test_backup_validation_failure_still_restores_the_old_output(self) -> None:
        name = "EasySplat.dmg"
        self._write_stage(name, b"new release")
        destination = self.output / name
        destination.write_bytes(b"old release")
        destination.chmod(0o644)
        changed_backup_mode = False

        def replace(source: str | os.PathLike[str], target: str | os.PathLike[str]) -> None:
            nonlocal changed_backup_mode
            os.replace(source, target)
            target_path = Path(target)
            if target_path.parent.name == MODULE.BACKUP_NAME:
                target_path.chmod(0o666)
                changed_backup_mode = True

        with self.assertRaisesRegex(MODULE.PublicationError, "rolled back"):
            MODULE.publish_release_files(
                self.stage,
                self.output,
                [name],
                replace=replace,
            )

        self.assertTrue(changed_backup_mode)
        self.assertEqual(destination.read_bytes(), b"old release")
        self.assertEqual(destination.stat().st_mode & 0o777, 0o644)
        self.assertEqual((self.stage / name).read_bytes(), b"new release")
        self.assertFalse((self.output / MODULE.LOCK_NAME).exists())
        self.assertFalse((self.stage / MODULE.BACKUP_NAME).exists())

    def test_rejects_unsafe_inputs_before_replacing_any_output(self) -> None:
        safe = self.stage / "safe.dmg"
        safe.write_bytes(b"new")
        alias = self.stage / "alias.json"
        alias.symlink_to(safe)
        existing = self.output / "safe.dmg"
        existing.write_bytes(b"old")

        with self.assertRaisesRegex(MODULE.PublicationError, "ordinary regular file"):
            MODULE.publish_release_files(
                self.stage, self.output, ["safe.dmg", "alias.json"]
            )

        self.assertEqual(existing.read_bytes(), b"old")
        self.assertEqual(safe.read_bytes(), b"new")
        self.assertFalse((self.output / MODULE.LOCK_NAME).exists())

    def test_refuses_a_concurrent_publication_lock(self) -> None:
        self._write_stage("EasySplat.dmg", b"new")
        (self.output / MODULE.LOCK_NAME).mkdir(mode=0o700)

        with self.assertRaisesRegex(MODULE.PublicationError, "already in progress"):
            MODULE.publish_release_files(
                self.stage, self.output, ["EasySplat.dmg"]
            )

        self.assertFalse((self.output / "EasySplat.dmg").exists())

    def test_expected_digest_rejects_post_notarization_mutation_before_moves(self) -> None:
        name = "EasySplat.dmg"
        self._write_stage(name, b"mutated after notarization")
        (self.output / name).write_bytes(b"previous release")

        with self.assertRaisesRegex(MODULE.PublicationError, "expected digest"):
            MODULE.publish_release_files(
                self.stage,
                self.output,
                [name],
                expected_sha256={name: "0" * 64},
            )

        self.assertEqual((self.output / name).read_bytes(), b"previous release")
        self.assertEqual((self.stage / name).read_bytes(), b"mutated after notarization")

    def test_first_output_move_occurs_only_after_prepared_journal_is_durable(self) -> None:
        name = "EasySplat.dmg"
        self._write_stage(name, b"new release")
        observed_states: list[str] = []

        def replace(source: str | os.PathLike[str], target: str | os.PathLike[str]) -> None:
            source_path = Path(source)
            if source_path == self.stage / name:
                journal = self.output / MODULE.LOCK_NAME / MODULE.JOURNAL_NAME
                observed_states.append(json.loads(journal.read_text())["state"])
            os.replace(source, target)

        MODULE.publish_release_files(
            self.stage,
            self.output,
            [name],
            replace=replace,
        )

        self.assertEqual(observed_states, ["prepared"])

    def test_recovers_a_dead_prepared_transaction_to_the_previous_release(self) -> None:
        names = ("EasySplat.dmg", "receipt.json")
        for index, name in enumerate(names):
            self._write_stage(name, f"new-{index}".encode())
        old_path = self.output / names[0]
        old_path.write_bytes(b"old release")

        new_bindings = {
            name: MODULE._file_binding(self.stage / name) for name in names
        }
        old_bindings = {names[0]: MODULE._file_binding(old_path)}
        lock = self.output / MODULE.LOCK_NAME
        lock.mkdir(mode=0o700)
        backup = self.stage / MODULE.BACKUP_NAME
        backup.mkdir(mode=0o700)
        os.replace(old_path, backup / names[0])
        os.replace(self.stage / names[0], self.output / names[0])
        MODULE._write_journal(
            lock,
            MODULE._journal_payload(
                state="prepared",
                process_id=999_999_999,
                stage=self.stage,
                output=self.output,
                names=list(names),
                source_bindings=new_bindings,
                old_bindings=old_bindings,
            ),
        )

        MODULE.recover_interrupted_publication(self.output)

        self.assertEqual(old_path.read_bytes(), b"old release")
        self.assertEqual(
            [(self.stage / name).read_bytes() for name in names],
            [b"new-0", b"new-1"],
        )
        self.assertFalse((self.output / names[1]).exists())
        self.assertFalse(lock.exists())
        self.assertFalse(backup.exists())

    def test_recovers_a_dead_committed_transaction_without_reverting_it(self) -> None:
        names = ("EasySplat.dmg", "receipt.json")
        for index, name in enumerate(names):
            self._write_stage(name, f"new-{index}".encode())
        old_path = self.output / names[0]
        old_path.write_bytes(b"old release")
        new_bindings = {
            name: MODULE._file_binding(self.stage / name) for name in names
        }
        old_bindings = {names[0]: MODULE._file_binding(old_path)}
        lock = self.output / MODULE.LOCK_NAME
        lock.mkdir(mode=0o700)
        backup = self.stage / MODULE.BACKUP_NAME
        backup.mkdir(mode=0o700)
        os.replace(old_path, backup / names[0])
        for name in names:
            os.replace(self.stage / name, self.output / name)
        MODULE._write_journal(
            lock,
            MODULE._journal_payload(
                state="committed",
                process_id=999_999_999,
                stage=self.stage,
                output=self.output,
                names=list(names),
                source_bindings=new_bindings,
                old_bindings=old_bindings,
            ),
        )

        MODULE.recover_interrupted_publication(self.output)

        self.assertEqual(
            [(self.output / name).read_bytes() for name in names],
            [b"new-0", b"new-1"],
        )
        self.assertFalse(lock.exists())
        self.assertFalse(backup.exists())

    def test_live_journal_is_never_recovered(self) -> None:
        name = "EasySplat.dmg"
        self._write_stage(name, b"new release")
        source_bindings = {name: MODULE._file_binding(self.stage / name)}
        lock = self.output / MODULE.LOCK_NAME
        lock.mkdir(mode=0o700)
        MODULE._write_journal(
            lock,
            MODULE._journal_payload(
                state="prepared",
                process_id=os.getpid(),
                stage=self.stage,
                output=self.output,
                names=[name],
                source_bindings=source_bindings,
                old_bindings={},
            ),
        )

        with self.assertRaisesRegex(MODULE.PublicationError, "still running"):
            MODULE.recover_interrupted_publication(self.output)

        self.assertTrue(lock.exists())
        self.assertEqual((self.stage / name).read_bytes(), b"new release")


if __name__ == "__main__":
    unittest.main()
