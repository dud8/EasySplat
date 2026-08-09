#!/usr/bin/env python3
"""Hostile lifecycle tests for native toolchain install promotion."""

from __future__ import annotations

import importlib.util
import fcntl
import hashlib
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[3]
PROMOTER = ROOT / "scripts/toolchain/atomic_swap_install.py"
BUILDERS = {
    "colmap": (
        ROOT / "scripts/toolchain/build_colmap_impl.sh",
        "INSTALL",
        "LIVE_INSTALL",
    ),
    "ceres": (
        ROOT / "scripts/toolchain/build_ceres_impl.sh",
        "STAGE",
        "INSTALL",
    ),
    "colmap-support": (
        ROOT / "scripts/toolchain/build_colmap_support_impl.sh",
        "STAGE",
        "INSTALL",
    ),
    "openimageio": (
        ROOT / "scripts/toolchain/build_openimageio_impl.sh",
        "STAGE",
        "INSTALL",
    ),
    "msplat": (
        ROOT / "scripts/toolchain/build_msplat.sh",
        "STAGE_DIR",
        "INSTALL_DIR",
    ),
}


def load_promoter():
    spec = importlib.util.spec_from_file_location(
        "atomic_swap_install_lifecycle", PROMOTER
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {PROMOTER}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def write_tree(path: Path, value: str) -> None:
    path.mkdir()
    (path / "sentinel").write_text(value, encoding="utf-8")


def extended_attribute_names(path: Path) -> tuple[str, ...]:
    result = subprocess.run(
        ["/usr/bin/xattr", str(path)],
        check=True,
        capture_output=True,
        text=True,
    )
    return tuple(sorted(line for line in result.stdout.splitlines() if line))


def extended_attribute_snapshot(path: Path) -> tuple[tuple[str, bytes], ...]:
    snapshot = []
    for name in extended_attribute_names(path):
        result = subprocess.run(
            ["/usr/bin/xattr", "-px", name, str(path)],
            check=True,
            capture_output=True,
            text=True,
        )
        snapshot.append((name, bytes.fromhex(result.stdout)))
    return tuple(snapshot)


@contextmanager
def clean_system_temporary_directory():
    path = Path(
        subprocess.run(
            ["/usr/bin/mktemp", "-d", "/tmp/easysplat-metadata.XXXXXXXX"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
    )
    try:
        attributes = extended_attribute_names(path)
        if any(name != "com.apple.provenance" for name in attributes):
            raise RuntimeError(
                "system temporary directory inherited extended attributes; "
                "run this host-metadata suite with /usr/bin/python3 -I"
            )
        yield path
    finally:
        shutil.rmtree(path)


class TransactionLifecycleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.promoter = load_promoter()

    def fixture(self, root: Path, *, existing: bool = True) -> tuple[Path, Path]:
        stage = root / "install.stage.123"
        install = root / "install"
        write_tree(stage, "new")
        if existing:
            write_tree(install, "old")
        return stage, install

    def begin(self, stage: Path, install: Path) -> Path:
        receipt = self.promoter.tree_receipt(stage)
        return self.promoter.begin_transaction(stage, install, receipt)

    def test_transaction_payload_rejects_reserved_namespace_collisions(
        self,
    ) -> None:
        for collision in (
            "stage",
            "canonical-journal",
            "finalization-journal",
            "retirement",
        ):
            with (
                self.subTest(collision=collision),
                tempfile.TemporaryDirectory() as temporary,
            ):
                root = Path(temporary)
                stage = root / "install.stage.123"
                write_tree(stage, "new")
                collision_paths = {
                    "stage": stage,
                    "canonical-journal": self.promoter.transaction_state_path(stage),
                    "finalization-journal": (
                        self.promoter.transaction_finalization_path(stage)
                    ),
                    "retirement": self.promoter.retirement_state_path(stage),
                }
                install = collision_paths[collision]
                if install != stage:
                    write_tree(install, "old")
                fake_receipt = f"{self.promoter.TREE_RECEIPT_PREFIX}{'0' * 64}"

                with mock.patch.object(
                    self.promoter,
                    "_verify_tree_receipt",
                    side_effect=AssertionError(
                        "reserved collision reached receipt verification"
                    ),
                ) as verify:
                    with self.assertRaisesRegex(ValueError, "distinct"):
                        self.promoter._transaction_payload(
                            stage,
                            install,
                            fake_receipt,
                        )

                verify.assert_not_called()

    def test_pre_swap_failure_is_recoverable_without_touching_old_install(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage, install = self.fixture(root)
            with mock.patch.object(
                self.promoter, "sync_tree", side_effect=OSError("pre-swap failure")
            ):
                with self.assertRaisesRegex(OSError, "pre-swap failure"):
                    self.begin(stage, install)

            journal = self.promoter.transaction_state_path(stage)
            self.assertTrue(journal.is_file())
            self.assertEqual((install / "sentinel").read_text(), "old")
            self.assertEqual((stage / "sentinel").read_text(), "new")

            self.promoter.recover_transaction(journal)
            self.assertEqual((install / "sentinel").read_text(), "old")
            self.assertFalse(stage.exists())
            self.assertFalse(journal.exists())

    def test_owned_tree_creation_binds_the_inode_it_created(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage = root / "install.stage.123"

            identity = self.promoter.create_owned_tree(stage)

            metadata = stage.lstat()
            self.assertEqual(
                identity, {"device": metadata.st_dev, "inode": metadata.st_ino}
            )
            self.assertEqual(metadata.st_mode & 0o777, 0o700)

    def test_owned_tree_creation_never_binds_a_publish_race_replacement(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage = root / "install.stage.123"
            moved = root / "created-but-moved"
            observed: dict[str, int] = {}

            def replace_after_publish(parent: int, name: str) -> None:
                created = os.stat(name, dir_fd=parent, follow_symlinks=False)
                observed["created_inode"] = created.st_ino
                os.rename(
                    name,
                    moved.name,
                    src_dir_fd=parent,
                    dst_dir_fd=parent,
                )
                os.mkdir(name, mode=0o700, dir_fd=parent)

            with mock.patch.object(
                self.promoter,
                "_after_owned_tree_publish",
                side_effect=replace_after_publish,
            ):
                with self.assertRaisesRegex(Exception, "changed after creation"):
                    self.promoter.create_owned_tree(stage)

            replacement = stage.lstat()
            created = moved.lstat()
            self.assertEqual(created.st_ino, observed["created_inode"])
            self.assertNotEqual(replacement.st_ino, created.st_ino)
            self.assertTrue(stage.is_dir())
            self.assertTrue(moved.is_dir())

    def test_owned_tree_creation_preserves_an_existing_destination(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage = root / "install.stage.123"
            write_tree(stage, "replacement")

            with self.assertRaises(OSError):
                self.promoter.create_owned_tree(stage)

            self.assertEqual((stage / "sentinel").read_text(), "replacement")
            self.assertEqual(
                list(root.glob(".easysplat-create.*")),
                [],
            )

    def test_owned_tree_creation_rolls_back_a_post_publish_fsync_failure(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage = root / "install.stage.123"
            real_fsync = os.fsync
            calls = 0

            def fail_first_parent_sync(descriptor: int) -> None:
                nonlocal calls
                calls += 1
                if calls == 2:
                    raise OSError("forced post-publish parent fsync failure")
                real_fsync(descriptor)

            with mock.patch.object(
                self.promoter.os,
                "fsync",
                side_effect=fail_first_parent_sync,
            ):
                with self.assertRaisesRegex(
                    OSError,
                    "forced post-publish parent fsync failure",
                ):
                    self.promoter.create_owned_tree(stage)

            self.assertFalse(stage.exists())
            self.assertEqual(list(root.glob(".easysplat-create.*")), [])
            self.assertEqual(list(root.glob(".easysplat-remove.*")), [])

    def test_existing_install_success_commits_only_after_explicit_finalize(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage, install = self.fixture(root)
            journal = self.begin(stage, install)

            self.assertEqual((install / "sentinel").read_text(), "new")
            self.assertEqual((stage / "sentinel").read_text(), "old")
            self.assertTrue(journal.is_file())

            self.promoter.commit_transaction(journal)
            self.assertEqual((install / "sentinel").read_text(), "new")
            self.assertFalse(stage.exists())
            self.assertFalse(journal.exists())

    def test_current_journal_finalizes_after_crash_retiring_prior_install(
        self,
    ) -> None:
        for finalizer_name in ("commit_transaction", "recover_transaction"):
            with (
                self.subTest(finalizer=finalizer_name),
                tempfile.TemporaryDirectory() as temporary,
            ):
                root = Path(temporary)
                stage, install = self.fixture(root)
                journal = self.begin(stage, install)

                with mock.patch.object(
                    self.promoter,
                    "_unlink_transaction",
                    side_effect=OSError("crash after prior install retirement"),
                ):
                    with self.assertRaisesRegex(
                        OSError,
                        "crash after prior install retirement",
                    ):
                        self.promoter.commit_transaction(journal)

                self.assertFalse(stage.exists())
                self.assertEqual((install / "sentinel").read_text(), "new")
                self.assertTrue(journal.is_file())

                finalizer = getattr(self.promoter, finalizer_name)
                finalizer(journal)

                self.assertFalse(stage.exists())
                self.assertEqual((install / "sentinel").read_text(), "new")
                self.assertFalse(journal.exists())

    def test_current_journal_resumes_deterministic_prior_tree_retirement(
        self,
    ) -> None:
        for finalizer_name in ("commit_transaction", "recover_transaction"):
            with (
                self.subTest(finalizer=finalizer_name),
                tempfile.TemporaryDirectory() as temporary,
            ):
                root = Path(temporary)
                stage, install = self.fixture(root)
                journal = self.begin(stage, install)
                retirement = self.promoter.retirement_state_path(stage)

                with mock.patch.object(
                    self.promoter,
                    "_remove_retirement_tree",
                    side_effect=OSError("crash after retirement claim"),
                ):
                    with self.assertRaisesRegex(
                        OSError,
                        "crash after retirement claim",
                    ):
                        self.promoter.commit_transaction(journal)

                self.assertFalse(stage.exists())
                self.assertEqual((retirement / "sentinel").read_text(), "old")
                self.assertEqual((install / "sentinel").read_text(), "new")
                self.assertTrue(journal.is_file())

                finalizer = getattr(self.promoter, finalizer_name)
                finalizer(journal)

                self.assertFalse(stage.exists())
                self.assertFalse(retirement.exists())
                self.assertEqual((install / "sentinel").read_text(), "new")
                self.assertFalse(journal.exists())

    def test_current_journal_resumes_partially_deleted_retirement_tree(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage, install = self.fixture(root)
            journal = self.begin(stage, install)
            retirement = self.promoter.retirement_state_path(stage)

            def delete_one_entry_then_crash(
                descriptor: int,
                *,
                allow_symlinks: bool,
            ) -> None:
                self.assertFalse(allow_symlinks)
                os.unlink("sentinel", dir_fd=descriptor)
                os.fsync(descriptor)
                raise OSError("crash during retirement deletion")

            with mock.patch.object(
                self.promoter,
                "_remove_directory_contents",
                side_effect=delete_one_entry_then_crash,
            ):
                with self.assertRaisesRegex(
                    OSError,
                    "crash during retirement deletion",
                ):
                    self.promoter.commit_transaction(journal)

            self.assertFalse(stage.exists())
            self.assertTrue(retirement.is_dir())
            self.assertEqual(list(retirement.iterdir()), [])
            self.assertEqual((install / "sentinel").read_text(), "new")
            self.assertTrue(journal.is_file())

            self.promoter.recover_transaction(journal)

            self.assertFalse(retirement.exists())
            self.assertEqual((install / "sentinel").read_text(), "new")
            self.assertFalse(journal.exists())

    def test_finalization_journal_survives_hard_exit_during_validation(
        self,
    ) -> None:
        for existing in (False, True):
            with (
                self.subTest(existing=existing),
                tempfile.TemporaryDirectory() as temporary,
            ):
                root = Path(temporary)
                stage, install = self.fixture(root, existing=existing)
                journal = self.begin(stage, install)
                finalization = self.promoter.transaction_finalization_path(stage)

                child = os.fork()
                if child == 0:
                    self.promoter._verify_terminal_namespace = (  # type: ignore[method-assign]
                        lambda *_args, **_kwargs: os._exit(99)
                    )
                    self.promoter.commit_transaction(journal)
                    os._exit(98)

                _, status = os.waitpid(child, 0)
                self.assertEqual(os.waitstatus_to_exitcode(status), 99)
                self.assertFalse(journal.exists())
                self.assertTrue(finalization.is_file())
                self.assertFalse(stage.exists())
                self.assertEqual((install / "sentinel").read_text(), "new")

                self.promoter.recover_transaction(finalization)

                self.assertFalse(finalization.exists())
                self.assertFalse(stage.exists())
                self.assertEqual((install / "sentinel").read_text(), "new")

    def test_finalization_preserves_foreign_canonical_journal(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage, install = self.fixture(root)
            journal = self.begin(stage, install)
            finalization = self.promoter.transaction_finalization_path(stage)

            child = os.fork()
            if child == 0:
                self.promoter._verify_terminal_namespace = (  # type: ignore[method-assign]
                    lambda *_args, **_kwargs: os._exit(99)
                )
                self.promoter.commit_transaction(journal)
                os._exit(98)

            _, status = os.waitpid(child, 0)
            self.assertEqual(os.waitstatus_to_exitcode(status), 99)
            self.assertFalse(journal.exists())
            self.assertTrue(finalization.is_file())
            journal.write_text("foreign", encoding="utf-8")

            with self.assertRaisesRegex(Exception, "canonical.*reappeared"):
                self.promoter.recover_transaction(finalization)

            self.assertEqual(journal.read_text(encoding="utf-8"), "foreign")
            self.assertTrue(finalization.is_file())
            self.assertFalse(stage.exists())
            self.assertEqual((install / "sentinel").read_text(), "new")

    def test_recovery_finalization_journal_survives_hard_exit(self) -> None:
        for existing in (False, True):
            with (
                self.subTest(existing=existing),
                tempfile.TemporaryDirectory() as temporary,
            ):
                root = Path(temporary)
                stage, install = self.fixture(root, existing=existing)
                journal = self.begin(stage, install)
                finalization = self.promoter.transaction_finalization_path(stage)

                child = os.fork()
                if child == 0:
                    self.promoter._verify_terminal_namespace = (  # type: ignore[method-assign]
                        lambda *_args, **_kwargs: os._exit(99)
                    )
                    self.promoter.recover_transaction(journal)
                    os._exit(98)

                _, status = os.waitpid(child, 0)
                self.assertEqual(os.waitstatus_to_exitcode(status), 99)
                self.assertFalse(journal.exists())
                self.assertTrue(finalization.is_file())
                self.assertFalse(stage.exists())
                self.assertEqual(install.exists(), existing)
                if existing:
                    self.assertEqual((install / "sentinel").read_text(), "old")

                self.promoter.recover_transaction(finalization)

                self.assertFalse(finalization.exists())
                self.assertFalse(stage.exists())
                self.assertEqual(install.exists(), existing)
                if existing:
                    self.assertEqual((install / "sentinel").read_text(), "old")

    def test_foreign_retirement_name_is_never_adopted_or_deleted(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage, install = self.fixture(root)
            retirement = self.promoter.retirement_state_path(stage)
            write_tree(retirement, "foreign")

            with self.assertRaisesRegex(Exception, "retirement path already exists"):
                self.begin(stage, install)

            self.assertEqual((stage / "sentinel").read_text(), "new")
            self.assertEqual((install / "sentinel").read_text(), "old")
            self.assertEqual((retirement / "sentinel").read_text(), "foreign")
            self.assertFalse(self.promoter.transaction_state_path(stage).exists())

    def test_first_install_success_commits_without_inventing_a_backup(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage, install = self.fixture(root, existing=False)
            journal = self.begin(stage, install)

            self.assertFalse(stage.exists())
            self.assertEqual((install / "sentinel").read_text(), "new")
            self.promoter.commit_transaction(journal)
            self.assertEqual((install / "sentinel").read_text(), "new")
            self.assertFalse(journal.exists())

    def test_first_install_commit_rejects_parent_replacement_before_unlink(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            work = root / "work"
            work.mkdir()
            stage, install = self.fixture(work, existing=False)
            journal = self.begin(stage, install)
            moved = root / "moved-work"
            original_verify = self.promoter._verify_layout_receipts
            injected = False

            def replace_parent_after_verification(
                payload: dict[str, object],
                staged: Path,
                installed: Path,
                layout: str,
            ) -> None:
                nonlocal injected
                original_verify(payload, staged, installed, layout)
                if not injected:
                    injected = True
                    work.rename(moved)
                    work.mkdir()
                    (moved / install.name).rename(work / install.name)
                    (moved / journal.name).rename(work / journal.name)

            with mock.patch.object(
                self.promoter,
                "_verify_layout_receipts",
                side_effect=replace_parent_after_verification,
            ):
                with self.assertRaisesRegex(Exception, "parent changed"):
                    self.promoter.commit_transaction(journal)

            self.assertTrue(injected)
            self.assertEqual((install / "sentinel").read_text(), "new")
            self.assertTrue(journal.is_file())
            self.assertFalse((moved / journal.name).exists())

    def test_terminal_validation_rejects_live_replacement_at_journal_claim(
        self,
    ) -> None:
        for existing in (False, True):
            with (
                self.subTest(existing=existing),
                tempfile.TemporaryDirectory() as temporary,
            ):
                root = Path(temporary)
                stage, install = self.fixture(root, existing=existing)
                journal = self.begin(stage, install)
                saved_new = root / "saved-new"
                original_verify = self.promoter._verify_terminal_namespace
                injected = False

                def replace_live_during_terminal_validation(
                    parent: int,
                    parent_path: Path,
                    payload: dict[str, object],
                    outcome: str,
                ) -> None:
                    nonlocal injected
                    if not injected:
                        injected = True
                        install.rename(saved_new)
                        write_tree(install, "new")
                    original_verify(parent, parent_path, payload, outcome)

                with mock.patch.object(
                    self.promoter,
                    "_verify_terminal_namespace",
                    side_effect=replace_live_during_terminal_validation,
                ):
                    with self.assertRaisesRegex(Exception, "committed install changed"):
                        self.promoter.commit_transaction(journal)

                self.assertTrue(injected)
                self.assertFalse(stage.exists())
                self.assertEqual((install / "sentinel").read_text(), "new")
                self.assertEqual((saved_new / "sentinel").read_text(), "new")
                self.assertNotEqual(install.stat().st_ino, saved_new.stat().st_ino)
                self.assertTrue(journal.is_file())

    def test_first_install_never_replaces_a_destination_created_before_rename(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage, install = self.fixture(root, existing=False)
            receipt = self.promoter.tree_receipt(stage)
            original_sync = self.promoter.sync_tree
            foreign_identity: tuple[int, int] | None = None

            def create_destination_after_sync(path: Path) -> None:
                nonlocal foreign_identity
                original_sync(path)
                install.mkdir()
                metadata = install.lstat()
                foreign_identity = (metadata.st_dev, metadata.st_ino)

            with mock.patch.object(
                self.promoter,
                "sync_tree",
                side_effect=create_destination_after_sync,
            ):
                with self.assertRaises(Exception):
                    self.promoter.begin_transaction(stage, install, receipt)

            self.assertEqual((stage / "sentinel").read_text(), "new")
            metadata = install.lstat()
            self.assertEqual((metadata.st_dev, metadata.st_ino), foreign_identity)
            self.assertTrue(self.promoter.transaction_state_path(stage).is_file())

    def test_post_swap_nonzero_state_is_preserved_then_recovered(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage, install = self.fixture(root)
            journal = self.begin(stage, install)

            # This is the state left when a caller observes a signal-like nonzero
            # status after the swap but before it can validate or commit.
            self.assertEqual((install / "sentinel").read_text(), "new")
            self.assertEqual((stage / "sentinel").read_text(), "old")
            self.promoter.recover_transaction(journal)

            self.assertEqual((install / "sentinel").read_text(), "old")
            self.assertFalse(stage.exists())
            self.assertFalse(journal.exists())

    def test_recovery_rejects_old_stage_replacement_before_reverse_swap(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage, install = self.fixture(root)
            journal = self.begin(stage, install)
            saved_old = root / "saved-old"
            original_sync = self.promoter.sync_tree
            injected = False

            def replace_after_sync(path: Path) -> None:
                nonlocal injected
                original_sync(path)
                if path == stage and not injected:
                    injected = True
                    stage.rename(saved_old)
                    write_tree(stage, "replacement")

            with mock.patch.object(
                self.promoter,
                "sync_tree",
                side_effect=replace_after_sync,
            ):
                with self.assertRaisesRegex(
                    Exception,
                    "staged install identity changed before swap",
                ):
                    self.promoter.recover_transaction(journal)

            self.assertTrue(injected)
            self.assertEqual((install / "sentinel").read_text(), "new")
            self.assertEqual((stage / "sentinel").read_text(), "replacement")
            self.assertEqual((saved_old / "sentinel").read_text(), "old")
            self.assertTrue(journal.is_file())

    def test_failed_post_reverse_verification_restores_promoted_layout(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage, install = self.fixture(root)
            journal = self.begin(stage, install)
            original_verify = self.promoter._verify_layout_receipts

            def fail_prepared_layout(
                payload: dict[str, object],
                staged: Path,
                installed: Path,
                layout: str,
            ) -> None:
                original_verify(payload, staged, installed, layout)
                if layout == "prepared":
                    raise OSError("forced post-reverse verification failure")

            with mock.patch.object(
                self.promoter,
                "_verify_layout_receipts",
                side_effect=fail_prepared_layout,
            ):
                with self.assertRaisesRegex(
                    OSError,
                    "forced post-reverse verification failure",
                ):
                    self.promoter.recover_transaction(journal)

            self.assertEqual((install / "sentinel").read_text(), "new")
            self.assertEqual((stage / "sentinel").read_text(), "old")
            self.assertTrue(journal.is_file())

    def test_validation_failure_can_restore_existing_install(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage, install = self.fixture(root)
            journal = self.begin(stage, install)

            self.promoter.recover_transaction(journal)

            self.assertEqual((install / "sentinel").read_text(), "old")
            self.assertFalse(stage.exists())
            self.assertFalse(journal.exists())

    def test_validation_failure_can_remove_an_invalid_first_install(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage, install = self.fixture(root, existing=False)
            journal = self.begin(stage, install)

            self.promoter.recover_transaction(journal)

            self.assertFalse(install.exists())
            self.assertFalse(stage.exists())
            self.assertFalse(journal.exists())

    def test_recovery_resumes_rejected_tree_retirement_after_claim_or_delete(
        self,
    ) -> None:
        for existing in (False, True):
            for failure_point in ("claim", "delete"):
                with (
                    self.subTest(existing=existing, failure_point=failure_point),
                    tempfile.TemporaryDirectory() as temporary,
                ):
                    root = Path(temporary)
                    stage, install = self.fixture(root, existing=existing)
                    journal = self.begin(stage, install)
                    retirement = self.promoter.retirement_state_path(stage)
                    patched = (
                        "_remove_retirement_tree"
                        if failure_point == "claim"
                        else "_unlink_transaction"
                    )
                    with mock.patch.object(
                        self.promoter,
                        patched,
                        side_effect=OSError(f"crash after recovery {failure_point}"),
                    ):
                        with self.assertRaisesRegex(
                            OSError,
                            f"crash after recovery {failure_point}",
                        ):
                            self.promoter.recover_transaction(journal)

                    self.assertFalse(stage.exists())
                    self.assertEqual(install.exists(), existing)
                    if existing:
                        self.assertEqual((install / "sentinel").read_text(), "old")
                    if failure_point == "claim":
                        self.assertEqual(
                            (retirement / "sentinel").read_text(),
                            "new",
                        )
                    else:
                        self.assertFalse(retirement.exists())
                    self.assertTrue(journal.is_file())

                    self.promoter.recover_transaction(journal)

                    self.assertFalse(stage.exists())
                    self.assertFalse(retirement.exists())
                    self.assertEqual(install.exists(), existing)
                    if existing:
                        self.assertEqual((install / "sentinel").read_text(), "old")
                    self.assertFalse(journal.exists())

    def test_first_install_recovery_rejects_live_name_replacement(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage, install = self.fixture(root, existing=False)
            journal = self.begin(stage, install)
            saved_new = root / "saved-new"
            original_sync = self.promoter.sync_tree
            injected = False

            def replace_after_sync(path: Path) -> None:
                nonlocal injected
                original_sync(path)
                if path == install and not injected:
                    injected = True
                    install.rename(saved_new)
                    write_tree(install, "replacement")

            with mock.patch.object(
                self.promoter,
                "sync_tree",
                side_effect=replace_after_sync,
            ):
                with self.assertRaisesRegex(
                    Exception,
                    "staged install identity changed before swap",
                ):
                    self.promoter.recover_transaction(journal)

            self.assertTrue(injected)
            self.assertFalse(stage.exists())
            self.assertEqual((install / "sentinel").read_text(), "replacement")
            self.assertEqual((saved_new / "sentinel").read_text(), "new")
            self.assertTrue(journal.is_file())

    def test_failed_recovery_preserves_both_names_and_the_journal(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage, install = self.fixture(root)
            journal = self.begin(stage, install)
            with mock.patch.object(
                self.promoter,
                "_reverse_existing_promotion",
                side_effect=OSError("rollback failure"),
            ):
                with self.assertRaisesRegex(Exception, "rollback failure"):
                    self.promoter.recover_transaction(journal)

            self.assertEqual((install / "sentinel").read_text(), "new")
            self.assertEqual((stage / "sentinel").read_text(), "old")
            self.assertTrue(journal.is_file())

    def test_replacement_at_stage_name_is_never_deleted_or_swapped(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage, install = self.fixture(root)
            journal = self.begin(stage, install)
            saved_old = root / "saved-old"
            stage.rename(saved_old)
            write_tree(stage, "replacement")

            for operation in (
                self.promoter.commit_transaction,
                self.promoter.recover_transaction,
            ):
                with self.subTest(operation=operation.__name__):
                    with self.assertRaises(Exception):
                        operation(journal)
                    self.assertEqual((stage / "sentinel").read_text(), "replacement")
                    self.assertEqual((saved_old / "sentinel").read_text(), "old")
                    self.assertEqual((install / "sentinel").read_text(), "new")
                    self.assertTrue(journal.is_file())

    def test_transaction_unlink_preserves_a_replacement_created_after_claim(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage, install = self.fixture(root, existing=False)
            journal = self.begin(stage, install)
            finalization = self.promoter.transaction_finalization_path(stage)
            payload, expected = self.promoter._read_transaction(journal)
            original_rename = self.promoter._rename_exclusive_at

            def replace_after_claim(
                parent: int,
                source: str,
                destination: str,
            ) -> None:
                original_rename(parent, source, destination)
                replacement = os.open(
                    source,
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                    0o600,
                    dir_fd=parent,
                )
                try:
                    os.write(replacement, b"replacement")
                finally:
                    os.close(replacement)

            with mock.patch.object(
                self.promoter,
                "_rename_exclusive_at",
                side_effect=replace_after_claim,
            ):
                with self.assertRaisesRegex(Exception, "canonical.*reappeared"):
                    self.promoter._unlink_transaction(
                        journal,
                        expected,
                        self.promoter.directory_identity(root, "test parent"),
                        payload,
                        "commit",
                    )

            self.assertEqual(journal.read_text(encoding="utf-8"), "replacement")
            self.assertTrue(finalization.is_file())
            self.assertEqual((install / "sentinel").read_text(), "new")

    def test_failed_rollback_directory_sync_is_reported_and_trees_survive(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage, install = self.fixture(root)
            original_sync = self.promoter._sync_bound_parent
            parent_sync_count = 0

            def failing_parent_sync(descriptor: int) -> None:
                nonlocal parent_sync_count
                parent_sync_count += 1
                if parent_sync_count > 1:
                    raise OSError(f"parent sync failure {parent_sync_count}")
                original_sync(descriptor)

            with mock.patch.object(
                self.promoter,
                "_sync_bound_parent",
                side_effect=failing_parent_sync,
            ):
                with self.assertRaisesRegex(Exception, "rollback.*durability"):
                    self.begin(stage, install)

            self.assertEqual(parent_sync_count, 3)
            self.assertEqual((install / "sentinel").read_text(), "old")
            self.assertEqual((stage / "sentinel").read_text(), "new")
            self.assertTrue(self.promoter.transaction_state_path(stage).is_file())

    def test_post_swap_rollback_never_swaps_a_stage_replacement_live(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage, install = self.fixture(root)
            receipt = self.promoter.tree_receipt(stage)
            payload = self.promoter._transaction_payload(stage, install, receipt)
            journal = self.promoter.transaction_state_path(stage)
            self.promoter._write_transaction(journal, payload)
            saved_old = root / "saved-old"
            original_sync = self.promoter._sync_bound_parent
            injected = False

            def fail_after_replacing_old_stage(descriptor: int) -> None:
                nonlocal injected
                if not injected:
                    injected = True
                    stage.rename(saved_old)
                    write_tree(stage, "replacement")
                    raise OSError("forced post-swap sync failure")
                original_sync(descriptor)

            with mock.patch.object(
                self.promoter,
                "_sync_bound_parent",
                side_effect=fail_after_replacing_old_stage,
            ):
                with self.assertRaisesRegex(
                    Exception,
                    "rollback.*paths changed",
                ):
                    self.promoter.promote(
                        stage,
                        install,
                        expected_parent_identity=payload["parent"],
                        expected_stage_identity=payload["staged"],
                        expected_install_identity=payload["installed"],
                    )

            self.assertTrue(injected)
            self.assertEqual((install / "sentinel").read_text(), "new")
            self.assertEqual((stage / "sentinel").read_text(), "replacement")
            self.assertEqual((saved_old / "sentinel").read_text(), "old")
            self.assertTrue(journal.is_file())

    def test_first_install_rollback_verifies_restored_name_and_parent(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage, install = self.fixture(root, existing=False)
            receipt = self.promoter.tree_receipt(stage)
            payload = self.promoter._transaction_payload(stage, install, receipt)
            journal = self.promoter.transaction_state_path(stage)
            self.promoter._write_transaction(journal, payload)
            saved_new = root / "saved-new"
            original_sync = self.promoter._sync_bound_parent
            sync_count = 0

            def fail_then_replace_restored_stage(descriptor: int) -> None:
                nonlocal sync_count
                sync_count += 1
                if sync_count == 1:
                    raise OSError("forced first-install promotion sync failure")
                original_sync(descriptor)
                stage.rename(saved_new)
                write_tree(stage, "replacement")

            with mock.patch.object(
                self.promoter,
                "_sync_bound_parent",
                side_effect=fail_then_replace_restored_stage,
            ):
                with self.assertRaisesRegex(
                    Exception,
                    "rollback.*identity verification",
                ):
                    self.promoter.promote(
                        stage,
                        install,
                        expected_parent_identity=payload["parent"],
                        expected_stage_identity=payload["staged"],
                        expected_install_identity=None,
                    )

            self.assertEqual(sync_count, 2)
            self.assertFalse(install.exists())
            self.assertEqual((stage / "sentinel").read_text(), "replacement")
            self.assertEqual((saved_new / "sentinel").read_text(), "new")
            self.assertTrue(journal.is_file())

    def test_same_size_restored_mtime_mutation_is_rejected_before_swap(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage, install = self.fixture(root)
            receipt = self.promoter.tree_receipt(stage)
            sentinel = stage / "sentinel"
            metadata = sentinel.stat()
            sentinel.write_text("bad", encoding="utf-8")
            os.utime(
                sentinel,
                ns=(metadata.st_atime_ns, metadata.st_mtime_ns),
            )

            with self.assertRaisesRegex(Exception, "tree receipt"):
                self.promoter.begin_transaction(stage, install, receipt)

            self.assertEqual((install / "sentinel").read_text(), "old")
            self.assertEqual((stage / "sentinel").read_text(), "bad")
            self.assertFalse(self.promoter.transaction_state_path(stage).exists())

    def test_late_extended_attribute_is_rejected_before_swap(self) -> None:
        with clean_system_temporary_directory() as root:
            stage, install = self.fixture(root)
            receipt = self.promoter.tree_receipt(stage)
            sentinel = stage / "sentinel"
            subprocess.run(
                [
                    "/usr/bin/xattr",
                    "-w",
                    "com.easysplat.test",
                    "late-metadata",
                    str(sentinel),
                ],
                check=True,
                capture_output=True,
                text=True,
            )

            with self.assertRaisesRegex(Exception, "tree receipt"):
                self.promoter.begin_transaction(stage, install, receipt)

            self.assertEqual((install / "sentinel").read_text(), "old")
            self.assertEqual((stage / "sentinel").read_text(), "new")
            self.assertFalse(self.promoter.transaction_state_path(stage).exists())

    def test_late_extended_acl_is_rejected_before_swap(self) -> None:
        with clean_system_temporary_directory() as root:
            stage, install = self.fixture(root)
            receipt = self.promoter.tree_receipt(stage)
            sentinel = stage / "sentinel"
            subprocess.run(
                ["/bin/chmod", "+a", "everyone allow read", str(sentinel)],
                check=True,
                capture_output=True,
                text=True,
            )
            try:
                with self.assertRaisesRegex(Exception, "tree receipt"):
                    self.promoter.begin_transaction(stage, install, receipt)

                self.assertEqual((install / "sentinel").read_text(), "old")
                self.assertEqual((stage / "sentinel").read_text(), "new")
                self.assertFalse(self.promoter.transaction_state_path(stage).exists())
            finally:
                subprocess.run(
                    ["/bin/chmod", "-N", str(sentinel)],
                    check=True,
                    capture_output=True,
                    text=True,
                )

    def test_late_file_flags_are_rejected_before_swap(self) -> None:
        with clean_system_temporary_directory() as root:
            stage, install = self.fixture(root)
            receipt = self.promoter.tree_receipt(stage)
            sentinel = stage / "sentinel"
            subprocess.run(
                ["/usr/bin/chflags", "hidden", str(sentinel)],
                check=True,
                capture_output=True,
                text=True,
            )
            try:
                with self.assertRaisesRegex(Exception, "tree receipt"):
                    self.promoter.begin_transaction(stage, install, receipt)

                self.assertEqual((install / "sentinel").read_text(), "old")
                self.assertEqual((stage / "sentinel").read_text(), "new")
                self.assertFalse(self.promoter.transaction_state_path(stage).exists())
            finally:
                subprocess.run(
                    ["/usr/bin/chflags", "nohidden", str(sentinel)],
                    check=True,
                    capture_output=True,
                    text=True,
                )

    def test_clean_receipt_rejects_preexisting_extended_metadata(self) -> None:
        with clean_system_temporary_directory() as root:
            stage = root / "install.stage.123"
            write_tree(stage, "new")
            sentinel = stage / "sentinel"
            subprocess.run(
                [
                    "/usr/bin/xattr",
                    "-w",
                    "com.easysplat.test",
                    "preexisting",
                    str(sentinel),
                ],
                check=True,
                capture_output=True,
                text=True,
            )

            with self.assertRaisesRegex(Exception, "rejects extended metadata"):
                self.promoter.tree_receipt(stage)

    def test_existing_install_extended_metadata_is_bound_for_rollback(self) -> None:
        with clean_system_temporary_directory() as root:
            stage, install = self.fixture(root)
            installed_sentinel = install / "sentinel"
            subprocess.run(
                [
                    "/usr/bin/xattr",
                    "-w",
                    "com.apple.provenance",
                    "legacy-install",
                    str(installed_sentinel),
                ],
                check=True,
                capture_output=True,
                text=True,
            )

            journal = self.begin(stage, install)

            self.assertEqual((install / "sentinel").read_text(), "new")
            self.assertEqual((stage / "sentinel").read_text(), "old")
            self.assertEqual(
                extended_attribute_names(stage / "sentinel"),
                ("com.apple.provenance",),
            )
            self.promoter.commit_transaction(journal)
            self.assertEqual((install / "sentinel").read_text(), "new")

    def test_legacy_receipt_cannot_authorize_a_new_promotion(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage, install = self.fixture(root)
            legacy_receipt = self.promoter.tree_receipt(
                stage,
                receipt_prefix=self.promoter.LEGACY_TREE_RECEIPT_PREFIX,
            )

            with self.assertRaisesRegex(Exception, "current staged tree receipt"):
                self.promoter.begin_transaction(stage, install, legacy_receipt)

            self.assertEqual((stage / "sentinel").read_text(), "new")
            self.assertEqual((install / "sentinel").read_text(), "old")
            self.assertFalse(self.promoter.transaction_state_path(stage).exists())

    def test_legacy_receipt_remains_valid_for_durable_journal_recovery(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage, install = self.fixture(root)
            current_receipt = self.promoter.tree_receipt(stage)
            payload = self.promoter._transaction_payload(
                stage,
                install,
                current_receipt,
            )
            payload["staged_tree_receipt"] = self.promoter.tree_receipt(
                stage,
                receipt_prefix=self.promoter.LEGACY_TREE_RECEIPT_PREFIX,
            )
            payload["installed_tree_receipt"] = self.promoter.tree_receipt(
                install,
                receipt_prefix=self.promoter.LEGACY_TREE_RECEIPT_PREFIX,
            )
            journal = self.promoter.transaction_state_path(stage)
            self.promoter._write_transaction(journal, payload)

            self.promoter.recover_transaction(journal)

            self.assertFalse(stage.exists())
            self.assertFalse(journal.exists())
            self.assertEqual((install / "sentinel").read_text(), "old")

    def test_legacy_receipt_journal_cannot_commit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage, install = self.fixture(root)
            current_receipt = self.promoter.tree_receipt(stage)
            payload = self.promoter._transaction_payload(
                stage,
                install,
                current_receipt,
            )
            payload["staged_tree_receipt"] = self.promoter.tree_receipt(
                stage,
                receipt_prefix=self.promoter.LEGACY_TREE_RECEIPT_PREFIX,
            )
            payload["installed_tree_receipt"] = self.promoter.tree_receipt(
                install,
                receipt_prefix=self.promoter.LEGACY_TREE_RECEIPT_PREFIX,
            )
            journal = self.promoter.transaction_state_path(stage)
            self.promoter._write_transaction(journal, payload)
            self.promoter.promote(stage, install)

            with self.assertRaisesRegex(Exception, "may only be rolled back"):
                self.promoter.commit_transaction(journal)

            self.assertTrue(journal.exists())
            self.assertEqual((install / "sentinel").read_text(), "new")
            self.assertEqual((stage / "sentinel").read_text(), "old")
            self.promoter.recover_transaction(journal)
            self.assertFalse(stage.exists())
            self.assertFalse(journal.exists())
            self.assertEqual((install / "sentinel").read_text(), "old")

    def test_legacy_retired_layout_is_never_finalized_as_current(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage, install = self.fixture(root)
            current_receipt = self.promoter.tree_receipt(stage)
            payload = self.promoter._transaction_payload(
                stage,
                install,
                current_receipt,
            )
            payload["staged_tree_receipt"] = self.promoter.tree_receipt(
                stage,
                receipt_prefix=self.promoter.LEGACY_TREE_RECEIPT_PREFIX,
            )
            payload["installed_tree_receipt"] = self.promoter.tree_receipt(
                install,
                receipt_prefix=self.promoter.LEGACY_TREE_RECEIPT_PREFIX,
            )
            journal = self.promoter.transaction_state_path(stage)
            self.promoter._write_transaction(journal, payload)
            self.promoter.promote(stage, install)
            installed_identity = payload["installed"]
            assert isinstance(installed_identity, dict)
            self.promoter._remove_expected_tree(stage, installed_identity)

            with self.assertRaisesRegex(Exception, "may only be rolled back"):
                self.promoter.commit_transaction(journal)
            with self.assertRaisesRegex(Exception, "ambiguous promotion state"):
                self.promoter.recover_transaction(journal)

            self.assertFalse(stage.exists())
            self.assertEqual((install / "sentinel").read_text(), "new")
            self.assertTrue(journal.is_file())

    def test_mixed_current_and_legacy_receipts_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage, install = self.fixture(root)
            payload = self.promoter._transaction_payload(
                stage,
                install,
                self.promoter.tree_receipt(stage),
            )
            payload["installed_tree_receipt"] = self.promoter.tree_receipt(
                install,
                receipt_prefix=self.promoter.LEGACY_TREE_RECEIPT_PREFIX,
            )
            journal = self.promoter.transaction_state_path(stage)
            self.promoter._write_transaction(journal, payload)
            self.promoter.promote(stage, install)

            for operation in (
                self.promoter.commit_transaction,
                self.promoter.recover_transaction,
            ):
                with self.subTest(operation=operation.__name__):
                    with self.assertRaisesRegex(Exception, "mixes receipt generations"):
                        operation(journal)
                    self.assertEqual((install / "sentinel").read_text(), "new")
                    self.assertEqual((stage / "sentinel").read_text(), "old")
                    self.assertTrue(journal.is_file())

    def test_tree_receipt_rejects_links_without_reading_their_targets(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            victim = root / "victim"
            victim.write_text("must-survive", encoding="utf-8")
            stage = root / "install.stage.123"
            stage.mkdir()
            link = stage / "link"
            link.symlink_to(victim)

            with self.assertRaisesRegex(Exception, "unsupported entry"):
                self.promoter.tree_receipt(stage)

            link.unlink()
            hardlink = stage / "hardlink"
            os.link(victim, hardlink)
            with self.assertRaisesRegex(Exception, "multiply linked"):
                self.promoter.tree_receipt(stage)
            self.assertEqual(victim.read_text(encoding="utf-8"), "must-survive")

    def test_tree_receipt_rejects_a_replacement_for_its_owned_root(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage = root / "install.stage.123"
            write_tree(stage, "owned")
            metadata = stage.lstat()
            moved = root / "moved-owned-stage"
            stage.rename(moved)
            write_tree(stage, "replacement")

            with self.assertRaisesRegex(Exception, "owned root identity"):
                self.promoter.tree_receipt(
                    stage,
                    {"device": metadata.st_dev, "inode": metadata.st_ino},
                )

            self.assertEqual((moved / "sentinel").read_text(), "owned")
            self.assertEqual((stage / "sentinel").read_text(), "replacement")

    def test_mutation_after_journal_write_is_rejected_before_swap(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage, install = self.fixture(root)
            receipt = self.promoter.tree_receipt(stage)
            sentinel = stage / "sentinel"
            metadata = sentinel.stat()
            original_write = self.promoter._write_transaction

            def mutate_after_write(path: Path, payload: dict[str, object]) -> None:
                original_write(path, payload)
                sentinel.write_text("bad", encoding="utf-8")
                os.utime(
                    sentinel,
                    ns=(metadata.st_atime_ns, metadata.st_mtime_ns),
                )

            with mock.patch.object(
                self.promoter,
                "_write_transaction",
                side_effect=mutate_after_write,
            ):
                with self.assertRaisesRegex(Exception, "tree receipt"):
                    self.promoter.begin_transaction(stage, install, receipt)

            self.assertEqual((install / "sentinel").read_text(), "old")
            self.assertEqual((stage / "sentinel").read_text(), "bad")
            self.assertTrue(self.promoter.transaction_state_path(stage).is_file())

    def test_parent_replacement_before_journal_write_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            work = root / "work"
            work.mkdir()
            stage, install = self.fixture(work)
            receipt = self.promoter.tree_receipt(stage)
            original_write = self.promoter._write_transaction
            moved = root / "moved-work"

            def replace_parent_then_write(
                path: Path,
                payload: dict[str, object],
            ) -> None:
                work.rename(moved)
                work.mkdir()
                (moved / stage.name).rename(work / stage.name)
                (moved / install.name).rename(work / install.name)
                original_write(path, payload)

            with mock.patch.object(
                self.promoter,
                "_write_transaction",
                side_effect=replace_parent_then_write,
            ):
                with self.assertRaisesRegex(Exception, "parent.*changed"):
                    self.promoter.begin_transaction(stage, install, receipt)

            self.assertEqual((install / "sentinel").read_text(), "old")
            self.assertEqual((stage / "sentinel").read_text(), "new")
            self.assertFalse(self.promoter.transaction_state_path(stage).exists())
            self.assertFalse(list(moved.glob("*.promotion-state")))

    def test_stage_replacement_at_promotion_entry_never_reaches_live_install(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage, install = self.fixture(root)
            receipt = self.promoter.tree_receipt(stage)
            original_promote = self.promoter.promote
            moved = root / "validated-stage"

            def replace_stage_then_promote(
                staged: Path,
                installed: Path,
                *args: object,
                **kwargs: object,
            ) -> None:
                staged.rename(moved)
                write_tree(staged, "replacement")
                original_promote(staged, installed, *args, **kwargs)

            with mock.patch.object(
                self.promoter,
                "promote",
                side_effect=replace_stage_then_promote,
            ):
                with self.assertRaisesRegex(Exception, "staged install.*changed"):
                    self.promoter.begin_transaction(stage, install, receipt)

            self.assertEqual((install / "sentinel").read_text(), "old")
            self.assertEqual((stage / "sentinel").read_text(), "replacement")
            self.assertEqual((moved / "sentinel").read_text(), "new")
            self.assertTrue(self.promoter.transaction_state_path(stage).exists())

    def test_mutation_after_swap_is_rejected_and_recovery_state_survives(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage, install = self.fixture(root)
            receipt = self.promoter.tree_receipt(stage)
            original_promote = self.promoter.promote

            def mutate_after_swap(
                staged: Path,
                installed: Path,
                **kwargs: object,
            ) -> None:
                original_promote(staged, installed, **kwargs)
                sentinel = installed / "sentinel"
                metadata = sentinel.stat()
                sentinel.write_text("bad", encoding="utf-8")
                os.utime(
                    sentinel,
                    ns=(metadata.st_atime_ns, metadata.st_mtime_ns),
                )

            with mock.patch.object(
                self.promoter,
                "promote",
                side_effect=mutate_after_swap,
            ):
                with self.assertRaisesRegex(Exception, "tree receipt"):
                    self.promoter.begin_transaction(stage, install, receipt)

            self.assertEqual((install / "sentinel").read_text(), "bad")
            self.assertEqual((stage / "sentinel").read_text(), "old")
            self.assertTrue(self.promoter.transaction_state_path(stage).is_file())

    def test_live_tree_mutation_blocks_commit_and_recovery(self) -> None:
        for operation_name in ("commit_transaction", "recover_transaction"):
            with (
                self.subTest(operation=operation_name),
                tempfile.TemporaryDirectory() as temporary,
            ):
                root = Path(temporary)
                stage, install = self.fixture(root)
                journal = self.begin(stage, install)
                sentinel = install / "sentinel"
                metadata = sentinel.stat()
                sentinel.write_text("bad", encoding="utf-8")
                os.utime(
                    sentinel,
                    ns=(metadata.st_atime_ns, metadata.st_mtime_ns),
                )

                operation = getattr(self.promoter, operation_name)
                with self.assertRaisesRegex(Exception, "tree receipt"):
                    operation(journal)

                self.assertEqual((install / "sentinel").read_text(), "bad")
                self.assertEqual((stage / "sentinel").read_text(), "old")
                self.assertTrue(journal.is_file())

    def test_replaced_old_tree_entry_is_preserved_instead_of_retired(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage, install = self.fixture(root)
            journal = self.begin(stage, install)
            old_entry = stage / "sentinel"
            metadata = old_entry.stat()
            saved_entry = root / "saved-old-entry"
            old_entry.rename(saved_entry)
            old_entry.write_text("old", encoding="utf-8")
            os.chmod(old_entry, metadata.st_mode & 0o777)
            os.utime(
                old_entry,
                ns=(metadata.st_atime_ns, metadata.st_mtime_ns),
            )

            with self.assertRaisesRegex(Exception, "tree receipt"):
                self.promoter.commit_transaction(journal)

            self.assertEqual(old_entry.read_text(), "old")
            self.assertEqual(saved_entry.read_text(), "old")
            self.assertEqual((install / "sentinel").read_text(), "new")
            self.assertTrue(journal.is_file())

    def test_owned_tree_removal_never_follows_links(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            victim = root / "victim"
            write_tree(victim, "must-survive")
            stage = root / "input.stage.123"
            stage.mkdir()
            (stage / "nested").mkdir()
            (stage / "nested" / "file").write_text("owned", encoding="utf-8")
            (stage / "link").symlink_to(victim, target_is_directory=True)
            metadata = stage.lstat()

            self.promoter.remove_owned_tree(
                stage,
                metadata.st_dev,
                metadata.st_ino,
                allow_symlinks=True,
            )

            self.assertFalse(stage.exists())
            self.assertEqual((victim / "sentinel").read_text(), "must-survive")

    def test_owned_tree_removal_preserves_replacement_at_bound_name(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage = root / "input.stage.123"
            write_tree(stage, "owned")
            metadata = stage.lstat()
            moved = root / "moved-owned"
            stage.rename(moved)
            write_tree(stage, "replacement")

            with self.assertRaisesRegex(Exception, "replacement"):
                self.promoter.remove_owned_tree(
                    stage,
                    metadata.st_dev,
                    metadata.st_ino,
                    allow_symlinks=True,
                )

            self.assertEqual((stage / "sentinel").read_text(), "replacement")
            self.assertEqual((moved / "sentinel").read_text(), "owned")


class BuilderOwnershipContractTests(unittest.TestCase):
    @staticmethod
    def function(source: str, name: str) -> str:
        match = re.search(
            rf"^{re.escape(name)}\(\) \{{\n.*?^\}}$",
            source,
            re.MULTILINE | re.DOTALL,
        )
        if match is None:
            raise AssertionError(f"missing shell function: {name}")
        return match.group(0)

    @staticmethod
    def heredoc_function(source: str, name: str) -> str:
        match = re.search(
            rf"^{re.escape(name)}\(\) \{{\n.*?^PY\n\}}$",
            source,
            re.MULTILINE | re.DOTALL,
        )
        if match is None:
            raise AssertionError(f"missing shell heredoc function: {name}")
        return match.group(0)

    @contextmanager
    def frozen_promoter_support(
        self,
        builder: str,
        source: str,
        root: Path,
        payload: bytes,
    ) -> Iterator[tuple[str, tuple[int, ...]]]:
        if builder == "msplat":
            runner = self.function(source, "run_promoter")
            yield (
                'PROMOTER_RUNTIME="$PROMOTER"\n'
                "PROMOTER_RUNTIME_READY=1\n"
                f"{runner}\n",
                (),
            )
            return

        source_path = root / "frozen-promoter-source.py"
        source_path.write_bytes(payload)
        source_path.chmod(0o400)
        source_descriptor = os.open(
            source_path,
            os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
        )
        try:
            frozen_descriptor = fcntl.fcntl(
                source_descriptor,
                fcntl.F_DUPFD_CLOEXEC,
                100,
            )
        finally:
            os.close(source_descriptor)
        source_path.unlink()

        digest = hashlib.sha256(payload).hexdigest()
        runner_name = "run_frozen_promoter" if builder == "colmap" else "run_promoter"
        runner = self.heredoc_function(source, runner_name)
        support = (
            f"FROZEN_PROMOTER_FD={frozen_descriptor}\nFROZEN_PROMOTER_SHA256={digest}\n"
        )
        if builder == "colmap":
            support += f"FROZEN_PROMOTER_SIZE={len(payload)}\n"
        support += f"{runner}\n"

        try:
            yield support, (frozen_descriptor,)
        finally:
            os.close(frozen_descriptor)

    def test_every_native_builder_preserves_stage_after_promotion_begins(self) -> None:
        for name, (path, stage_variable, install_variable) in BUILDERS.items():
            with self.subTest(builder=name):
                source = path.read_text(encoding="utf-8")
                self.assertIn("STAGE_CLEANUP_ALLOWED=1", source)
                cleanup = source.split("cleanup() {", 1)[1].split("\n}", 1)[0]
                self.assertIn('[ "$STAGE_CLEANUP_ALLOWED" = "1" ]', cleanup)
                promotion = source.split("promote_install() {", 1)[1].split("\n}", 1)[0]
                normalized_promotion = promotion.replace("\\\n", " ")
                self.assertRegex(
                    normalized_promotion,
                    rf'--tree-receipt\s+"\${stage_variable}"',
                )
                self.assertIn('"$INSTALL_STAGE_DEVICE"', promotion)
                self.assertIn('"$INSTALL_STAGE_INODE"', promotion)
                self.assertIn("STAGE_CLEANUP_ALLOWED=0", promotion)
                self.assertGreater(
                    promotion.index("STAGE_CLEANUP_ALLOWED=0"),
                    promotion.index("--tree-receipt"),
                )
                self.assertIn(
                    f'"${stage_variable}" "${install_variable}" "$tree_receipt"',
                    promotion,
                )
                self.assertIn("--commit", promotion)

    def test_native_install_stages_are_created_and_cleaned_by_bound_identity(
        self,
    ) -> None:
        first_stage_writes = {
            "colmap": 'mkdir -p "$INSTALL/bin"',
            "ceres": "build_ceres",
            "colmap-support": "build_boost",
            "openimageio": "build_imath",
            "msplat": "stage_install",
        }
        for name in BUILDERS:
            path, stage_variable, _ = BUILDERS[name]
            with self.subTest(builder=name):
                source = path.read_text(encoding="utf-8")
                creation = self.function(source, "create_owned_install_stage")
                cleanup = self.function(source, "cleanup")

                self.assertIn(
                    f'--create-owned-tree "${stage_variable}"',
                    creation,
                )
                self.assertLess(
                    creation.index("--create-owned-tree"),
                    creation.index("INSTALL_STAGE_OWNED=1"),
                )
                self.assertNotIn("/bin/mkdir", creation)
                self.assertIn("--remove-owned-tree", cleanup)
                self.assertIn(f'"${stage_variable}"', cleanup)
                self.assertIn('"$INSTALL_STAGE_DEVICE"', cleanup)
                self.assertIn('"$INSTALL_STAGE_INODE"', cleanup)
                self.assertIn("--allow-symlinks", cleanup)
                self.assertNotRegex(
                    source,
                    rf"rm -rf[^\n]*\"\${stage_variable}\"",
                )
                self.assertEqual(
                    len(
                        re.findall(
                            r"^[ \t]*create_owned_install_stage$",
                            source,
                            re.MULTILINE,
                        )
                    ),
                    1,
                )
                stage_call = next(
                    re.finditer(
                        r"^[ \t]*create_owned_install_stage$",
                        source,
                        re.MULTILINE,
                    )
                ).start()
                self.assertLess(
                    stage_call,
                    source.rfind(first_stage_writes[name]),
                )

    def test_msplat_normalizes_only_system_provenance_and_rejects_other_metadata(
        self,
    ) -> None:
        source = BUILDERS["msplat"][0].read_text(encoding="utf-8")
        self.assertIn('PYTHON_BIN="/usr/bin/python3"', source)
        self.assertNotIn('PYTHON_BIN="$(command -v python3)"', source)
        audit = self.function(source, "audit_stage_extended_metadata")
        normalization = self.function(source, "normalize_stage_system_metadata")
        validation = self.function(source, "validate_stage_extended_metadata")
        pipeline = source.rsplit("\npreflight\n", 1)[1]
        self.assertLess(
            pipeline.index("\nnormalize_stage_system_metadata\n"),
            pipeline.index("\nvalidate_stage\n"),
        )
        self.assertLess(
            pipeline.index("\nvalidate_stage\n"),
            pipeline.index("\nvalidate_stage_extended_metadata\n"),
        )
        promotion = self.function(source, "promote_install")
        self.assertEqual(promotion.count("validate_stage_extended_metadata"), 2)

        with clean_system_temporary_directory() as root:
            stage = root / "msplat.stage.123"
            stage.mkdir()
            payload = stage / "payload"
            payload.write_bytes(b"native-msplat")
            subprocess.run(
                [
                    "/usr/bin/xattr",
                    "-w",
                    "com.apple.provenance",
                    "system-provenance",
                    str(payload),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertIn(
                "com.apple.provenance", extended_attribute_names(payload)
            )
            harness = (
                "#!/bin/bash\n"
                "set -euo pipefail\n"
                f"STAGE_DIR={stage!s}\n"
                f"INSTALL_STAGE_DEVICE={stage.lstat().st_dev}\n"
                f"INSTALL_STAGE_INODE={stage.lstat().st_ino}\n"
                "PYTHON_BIN=/usr/bin/python3\n"
                f"{audit}\n"
                f"{normalization}\n"
                f"{validation}\n"
                "normalize_stage_system_metadata\n"
                "validate_stage_extended_metadata\n"
            )
            normalized = subprocess.run(
                ["/bin/bash", "--noprofile", "--norc", "-s"],
                check=False,
                capture_output=True,
                text=True,
                input=harness,
            )
            self.assertEqual(
                normalized.returncode,
                0,
                normalized.stdout + normalized.stderr,
            )
            self.assertFalse(
                set(extended_attribute_names(payload)) - {"com.apple.provenance"}
            )

            subprocess.run(
                [
                    "/usr/bin/xattr",
                    "-w",
                    "user.easysplat-unexpected",
                    "must-reject",
                    str(payload),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            rejected = subprocess.run(
                ["/bin/bash", "--noprofile", "--norc", "-s"],
                check=False,
                capture_output=True,
                text=True,
                input=harness,
            )
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("unexpected extended attribute", rejected.stderr)

    def test_native_install_cleanup_unlinks_links_without_following_them(self) -> None:
        for name in BUILDERS:
            path, stage_variable, _ = BUILDERS[name]
            with self.subTest(builder=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                victim = root / "victim"
                write_tree(victim, "must-survive")
                stage = root / "install.stage.123"
                stage.mkdir()
                (stage / "nested").mkdir()
                (stage / "nested" / "file").write_text("owned", encoding="utf-8")
                (stage / "victim-link").symlink_to(victim, target_is_directory=True)
                metadata = stage.lstat()
                source = path.read_text(encoding="utf-8")
                cleanup = self.function(source, "cleanup")
                with self.frozen_promoter_support(
                    name,
                    source,
                    root,
                    PROMOTER.read_bytes(),
                ) as (promoter_support, pass_fds):
                    harness = root / "cleanup.sh"
                    harness.write_text(
                        self._cleanup_harness(
                            cleanup,
                            stage,
                            stage_variable,
                            metadata,
                            promoter_support,
                        ),
                        encoding="utf-8",
                    )

                    result = subprocess.run(
                        ["/bin/bash", "--noprofile", "--norc", str(harness)],
                        check=False,
                        capture_output=True,
                        text=True,
                        pass_fds=pass_fds,
                    )

                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse(stage.exists())
                self.assertEqual((victim / "sentinel").read_text(), "must-survive")

    def test_native_install_cleanup_preserves_a_raced_root_replacement(self) -> None:
        for name in BUILDERS:
            path, stage_variable, _ = BUILDERS[name]
            with self.subTest(builder=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                stage = root / "install.stage.123"
                write_tree(stage, "owned")
                metadata = stage.lstat()
                moved = root / "moved-owned"
                stage.rename(moved)
                write_tree(stage, "replacement")
                source = path.read_text(encoding="utf-8")
                cleanup = self.function(source, "cleanup")
                with self.frozen_promoter_support(
                    name,
                    source,
                    root,
                    PROMOTER.read_bytes(),
                ) as (promoter_support, pass_fds):
                    harness = root / "cleanup.sh"
                    harness.write_text(
                        self._cleanup_harness(
                            cleanup,
                            stage,
                            stage_variable,
                            metadata,
                            promoter_support,
                        ),
                        encoding="utf-8",
                    )

                    result = subprocess.run(
                        ["/bin/bash", "--noprofile", "--norc", str(harness)],
                        check=False,
                        capture_output=True,
                        text=True,
                        pass_fds=pass_fds,
                    )

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("preserved an unverified staged install", result.stderr)
                self.assertEqual((stage / "sentinel").read_text(), "replacement")
                self.assertEqual((moved / "sentinel").read_text(), "owned")

    @staticmethod
    def _cleanup_harness(
        cleanup: str,
        stage: Path,
        stage_variable: str,
        metadata: os.stat_result,
        promoter_support: str,
    ) -> str:
        assignments = {
            "STAGE": stage,
            "INSTALL": stage,
            "STAGE_DIR": stage,
            "INSTALL_DIR": stage,
            "LIVE_INSTALL": stage.parent / "live-install",
        }
        assignments[stage_variable] = stage
        bound_paths = "".join(
            f"{key}={value!s}\n" for key, value in assignments.items()
        )
        return (
            "#!/bin/bash\n"
            "set -u\n"
            f"{bound_paths}"
            f"PROMOTER={PROMOTER!s}\n"
            "PYTHON_BIN=/usr/bin/python3\n"
            "SELECTED_PYTHON=/usr/bin/python3\n"
            "STAGE_CLEANUP_ALLOWED=1\n"
            "INSTALL_STAGE_OWNED=1\n"
            f"INSTALL_STAGE_DEVICE={metadata.st_dev}\n"
            f"INSTALL_STAGE_INODE={metadata.st_ino}\n"
            "BUILD_INPUT_SNAPSHOT_OWNED=0\n"
            "PROMOTER_RUNTIME_OWNED=0\n"
            "BUILD_LOCK_OWNED=0\n"
            "CLEANUP_DEFERRED_SIGNAL=0\n"
            "LOCK_OWNED=0\n"
            "GUARDED_RUN=0\n"
            "MODE=build\n"
            "SCRATCH=\n"
            f"INPUT_SNAPSHOT={stage.parent / 'unused-input-stage'!s}\n"
            f"{promoter_support}"
            f"{cleanup}\n"
            "trap cleanup EXIT\n"
            "exit 0\n"
        )

    def test_colmap_rejects_staged_extended_attributes_and_acls(self) -> None:
        source = BUILDERS["colmap"][0].read_text(encoding="utf-8")
        validation = self.function(source, "validate_stage_extended_metadata")
        for contract in (
            "libc.listxattr",
            "XATTR_NOFOLLOW",
            "acl_get_link_np",
            "ACL_TYPE_EXTENDED",
            "native COLMAP install has extended attributes",
            "native COLMAP install has an extended ACL",
        ):
            self.assertIn(contract, validation)
        pipeline = source.rsplit("\npreflight\n", 1)[1]
        self.assertLess(
            pipeline.index("\nvalidate_metadata\n"),
            pipeline.index("\nvalidate_stage_extended_metadata\n"),
        )
        self.assertLess(
            pipeline.index("\nvalidate_stage_extended_metadata\n"),
            pipeline.index("\nawait_promotion_approval\n"),
        )
        promotion = self.function(source, "promote_install")
        self.assertEqual(promotion.count("validate_stage_extended_metadata"), 2)
        first_validation = promotion.index("validate_stage_extended_metadata")
        receipt = promotion.index("--tree-receipt")
        second_validation = promotion.index(
            "validate_stage_extended_metadata",
            first_validation + 1,
        )
        cleanup_handoff = promotion.index("STAGE_CLEANUP_ALLOWED=0")
        transaction = promotion.index('"$INSTALL" "$LIVE_INSTALL" "$tree_receipt"')
        self.assertLess(first_validation, receipt)
        self.assertLess(receipt, second_validation)
        self.assertLess(second_validation, cleanup_handoff)
        self.assertLess(cleanup_handoff, transaction)
        self.assertLess(
            second_validation,
            transaction,
        )

    def test_colmap_extended_metadata_gate_executes_for_xattrs_and_acls(self) -> None:
        source = BUILDERS["colmap"][0].read_text(encoding="utf-8")
        validation = self.function(source, "validate_stage_extended_metadata")
        with clean_system_temporary_directory() as root:
            stage = root / "install.stage.123"
            payload = stage / "colmap"
            subprocess.run(
                [
                    "/usr/bin/python3",
                    "-c",
                    (
                        "from pathlib import Path; "
                        "stage = Path(__import__('sys').argv[1]); "
                        "stage.mkdir(); (stage / 'colmap').write_bytes(b'native-colmap')"
                    ),
                    str(stage),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            harness = root / "validate.sh"
            harness.write_text(
                "#!/bin/bash\n"
                "set -u\n"
                f"INSTALL={stage!s}\n"
                "SELECTED_PYTHON=/usr/bin/python3\n"
                f"{validation}\n"
                "validate_stage_extended_metadata\n",
                encoding="utf-8",
            )

            subprocess.run(
                [
                    "/usr/bin/xattr",
                    "-w",
                    "com.easysplat.test",
                    "provenance",
                    str(payload),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            xattr = subprocess.run(
                ["/bin/bash", "--noprofile", "--norc", str(harness)],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(xattr.returncode, 0)
            self.assertIn("has extended attributes", xattr.stderr)

            subprocess.run(
                ["/bin/chmod", "+a", "everyone allow read", str(payload)],
                check=True,
                capture_output=True,
                text=True,
            )
            try:
                acl = subprocess.run(
                    ["/bin/bash", "--noprofile", "--norc", str(harness)],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertNotEqual(acl.returncode, 0)
                self.assertIn("has an extended ACL", acl.stderr)
            finally:
                subprocess.run(
                    ["/bin/chmod", "-N", str(payload)],
                    check=True,
                    capture_output=True,
                    text=True,
                )

    def test_colmap_normalizes_only_system_provenance_before_validation(
        self,
    ) -> None:
        source = BUILDERS["colmap"][0].read_text(encoding="utf-8")
        normalization = self.function(source, "normalize_stage_system_metadata")
        validation = self.function(source, "validate_stage_extended_metadata")
        pipeline = source.rsplit("\npreflight\n", 1)[1]
        self.assertLess(
            pipeline.index("\nnormalize_stage_system_metadata\n"),
            pipeline.index("\nvalidate_stage_extended_metadata\n"),
        )

        with clean_system_temporary_directory() as root:
            stage = root / "install.stage.123"
            stage.mkdir()
            payload = stage / "colmap"
            payload.write_bytes(b"native-colmap")
            harness = (
                "#!/bin/bash\n"
                "set -euo pipefail\n"
                f"INSTALL={stage!s}\n"
                f"INSTALL_STAGE_DEVICE={stage.lstat().st_dev}\n"
                f"INSTALL_STAGE_INODE={stage.lstat().st_ino}\n"
                "SELECTED_PYTHON=/usr/bin/python3\n"
                f"{normalization}\n"
                f"{validation}\n"
                "normalize_stage_system_metadata\n"
                "validate_stage_extended_metadata\n"
            )

            for path in (stage, payload):
                subprocess.run(
                    [
                        "/usr/bin/xattr",
                        "-w",
                        "com.apple.provenance",
                        "system-managed",
                        str(path),
                    ],
                    check=True,
                    capture_output=True,
                    text=True,
                )
            accepted_before = {
                path: extended_attribute_snapshot(path) for path in (stage, payload)
            }
            self.assertTrue(
                all(
                    any(
                        name == "com.apple.provenance"
                        for name, _ in snapshot
                    )
                    for snapshot in accepted_before.values()
                )
            )
            accepted = subprocess.run(
                ["/bin/bash", "--noprofile", "--norc", "-s"],
                check=False,
                capture_output=True,
                text=True,
                input=harness,
            )
            self.assertEqual(
                accepted.returncode,
                0,
                accepted.stdout + accepted.stderr,
            )
            self.assertFalse(
                set(extended_attribute_names(stage)) - {"com.apple.provenance"}
            )
            self.assertFalse(
                set(extended_attribute_names(payload)) - {"com.apple.provenance"}
            )

            for path in (stage, payload):
                subprocess.run(
                    [
                        "/usr/bin/xattr",
                        "-w",
                        "com.apple.provenance",
                        "system-managed",
                        str(path),
                    ],
                    check=True,
                    capture_output=True,
                    text=True,
                )
            subprocess.run(
                [
                    "/usr/bin/xattr",
                    "-w",
                    "com.easysplat.test",
                    "untrusted",
                    str(payload),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            rejected_before = {
                path: extended_attribute_snapshot(path) for path in (stage, payload)
            }
            rejected = subprocess.run(
                ["/bin/bash", "--noprofile", "--norc", "-s"],
                check=False,
                capture_output=True,
                text=True,
                input=harness,
            )
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("unexpected extended attribute", rejected.stderr)
            self.assertEqual(
                {path: extended_attribute_snapshot(path) for path in (stage, payload)},
                rejected_before,
            )

    def test_colmap_normalizer_rejects_hardlinks_before_mutating_their_inode(
        self,
    ) -> None:
        source = BUILDERS["colmap"][0].read_text(encoding="utf-8")
        normalization = self.function(source, "normalize_stage_system_metadata")
        with clean_system_temporary_directory() as root:
            external = root / "outside-colmap"
            external.write_bytes(b"native-colmap")
            stage = root / "install.stage.123"
            stage.mkdir()
            payload = stage / "colmap"
            os.link(external, payload)
            subprocess.run(
                [
                    "/usr/bin/xattr",
                    "-w",
                    "com.apple.provenance",
                    "outside-must-not-change",
                    str(external),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            before = extended_attribute_snapshot(external)
            harness = (
                "#!/bin/bash\n"
                "set -euo pipefail\n"
                f"INSTALL={stage!s}\n"
                f"INSTALL_STAGE_DEVICE={stage.lstat().st_dev}\n"
                f"INSTALL_STAGE_INODE={stage.lstat().st_ino}\n"
                "SELECTED_PYTHON=/usr/bin/python3\n"
                f"{normalization}\n"
                "normalize_stage_system_metadata\n"
            )

            rejected = subprocess.run(
                ["/bin/bash", "--noprofile", "--norc", "-s"],
                check=False,
                capture_output=True,
                text=True,
                input=harness,
            )

            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("multiply linked", rejected.stderr)
            self.assertEqual(extended_attribute_snapshot(external), before)
            self.assertEqual(extended_attribute_snapshot(payload), before)

    def test_every_native_builder_recovers_journaled_stages_before_rebuild(
        self,
    ) -> None:
        for name, (path, _, _) in BUILDERS.items():
            with self.subTest(builder=name):
                source = path.read_text(encoding="utf-8")
                self.assertIn("recover_stale_promotions() {", source)
                recovery = source.split("recover_stale_promotions() {", 1)[1].split(
                    "\n}", 1
                )[0]
                if name == "colmap":
                    self.assertIn("run_frozen_promoter --recover", recovery)
                elif name == "msplat":
                    self.assertIn("run_promoter --recover", recovery)
                else:
                    self.assertIn("run_promoter --recover", recovery)
                self.assertIn("ambiguous staged install requires recovery", recovery)
                install_stage_loop = recovery.split(
                    "ambiguous staged install requires recovery", 1
                )[0]
                self.assertNotIn('rm -rf "$path"', install_stage_loop)

    def test_release_suite_runs_the_hostile_promotion_tests(self) -> None:
        release_tests = (ROOT / "scripts/ci/test_release_scripts.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            "/usr/bin/python3 -I "
            '"$ROOT/scripts/toolchain/tests/test_atomic_swap_install.py"',
            release_tests,
        )

    def test_colmap_supervisor_owns_bound_input_stage_cleanup(self) -> None:
        source = BUILDERS["colmap"][0].read_text(encoding="utf-8")
        cleanup = self.function(source, "cleanup")
        self.assertNotIn("INPUT_SNAPSHOT", cleanup)
        self.assertNotIn("GUARDED_STAGE_DEVICE", cleanup)
        self.assertNotIn("GUARDED_STAGE_INODE", cleanup)

        supervisor = (ROOT / "scripts/toolchain/secure_colmap_build.py").read_text(
            encoding="utf-8"
        )
        owned_cleanup = supervisor.split("def _remove_owned_run_stage(", 1)[1].split(
            "\n\ndef _overlay_digest", 1
        )[0]
        self.assertIn("_read_bound_source", owned_cleanup)
        self.assertIn("_anonymous_copy", owned_cleanup)
        self.assertIn('"--remove-owned-tree"', owned_cleanup)
        self.assertIn("expected_device", owned_cleanup)
        self.assertIn("expected_inode", owned_cleanup)

    def test_signal_like_promoter_failure_never_deletes_swapped_old_install(
        self,
    ) -> None:
        for name, (path, stage_variable, install_variable) in BUILDERS.items():
            with self.subTest(builder=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                stage = root / "stage"
                install = root / "install"
                write_tree(stage, "new")
                write_tree(install, "old")
                promoter = root / "fake-promoter.py"
                promoter.write_text(
                    "import sys\n"
                    "from pathlib import Path\n"
                    "arguments = sys.argv[1:]\n"
                    "if arguments[0] == '--tree-receipt':\n"
                    "    print('tree-v1:' + ('0' * 64))\n"
                    "    raise SystemExit(0)\n"
                    "stage, install = map(Path, arguments[:2])\n"
                    "temporary = stage.with_name('swap-temporary')\n"
                    "stage.rename(temporary)\n"
                    "install.rename(stage)\n"
                    "temporary.rename(install)\n"
                    "raise SystemExit(143)\n",
                    encoding="utf-8",
                )
                source = path.read_text(encoding="utf-8")
                cleanup = self.function(source, "cleanup")
                promotion = self.function(source, "promote_install")
                input_snapshot = root / "input-snapshot"
                write_tree(input_snapshot, "input")
                with self.frozen_promoter_support(
                    name,
                    source,
                    root,
                    promoter.read_bytes(),
                ) as (promoter_support, pass_fds):
                    harness = root / "harness.sh"
                    harness.write_text(
                        "#!/bin/bash\n"
                        "set -u\n"
                        f"STAGE={stage!s}\n"
                        f"INSTALL={install!s}\n"
                        f"STAGE_DIR={stage!s}\n"
                        f"INSTALL_DIR={install!s}\n"
                        f"LIVE_INSTALL={install!s}\n"
                        f"{stage_variable}={stage!s}\n"
                        f"{install_variable}={install!s}\n"
                        f"PROMOTER={promoter!s}\n"
                        "PYTHON_BIN=/usr/bin/python3\n"
                        "SELECTED_PYTHON=/usr/bin/python3\n"
                        "STAGE_CLEANUP_ALLOWED=1\n"
                        "INSTALL_STAGE_OWNED=0\n"
                        f"INSTALL_STAGE_DEVICE={stage.lstat().st_dev}\n"
                        f"INSTALL_STAGE_INODE={stage.lstat().st_ino}\n"
                        "BUILD_INPUT_SNAPSHOT_OWNED=0\n"
                        "PROMOTER_RUNTIME_OWNED=0\n"
                        "BUILD_LOCK_OWNED=0\n"
                        "CLEANUP_DEFERRED_SIGNAL=0\n"
                        "LOCK_OWNED=0\n"
                        "GUARDED_RUN=0\n"
                        "GUARDED_STAGE_DEVICE=\n"
                        "GUARDED_STAGE_INODE=\n"
                        "MODE=build\n"
                        "SCRATCH=\n"
                        f"INPUT_SNAPSHOT={input_snapshot!s}\n"
                        f"{promoter_support}"
                        "die() { printf 'error=%s\\n' \"$*\"; exit 1; }\n"
                        "validate_stage_extended_metadata() { return 0; }\n"
                        "validate_install_tree() { return 0; }\n"
                        "validate_receipt() { return 0; }\n"
                        "validate_relocated_consumer() { return 0; }\n"
                        "validate_install_prefix() { return 0; }\n"
                        f"{cleanup}\n"
                        f"{promotion}\n"
                        "trap cleanup EXIT\n"
                        "promote_install\n",
                        encoding="utf-8",
                    )
                    result = subprocess.run(
                        ["/bin/bash", "--noprofile", "--norc", str(harness)],
                        check=False,
                        capture_output=True,
                        text=True,
                        pass_fds=pass_fds,
                    )
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual((stage / "sentinel").read_text(), "old")
                self.assertEqual((install / "sentinel").read_text(), "new")


if __name__ == "__main__":
    unittest.main()
