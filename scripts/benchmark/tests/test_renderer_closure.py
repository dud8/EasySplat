from __future__ import annotations

import os
import shutil
import tempfile
import unittest
from pathlib import Path

from scripts.benchmark import renderer_closure


class RendererClosureTests(unittest.TestCase):
    def _source(self, root: Path) -> tuple[Path, Path]:
        executable = root / "EasySplatBenchmarkDriver"
        executable.write_bytes(b"release-renderer")
        executable.chmod(0o755)
        bundle = root / "MetalSplatter_MetalSplatter.bundle"
        bundle.mkdir()
        (bundle / "Shaders.metal").write_bytes(b"kernel void draw() {}\n")
        return executable, bundle

    def test_build_and_verify_bind_every_runtime_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable, bundle = self._source(root)
            closure = root / "closure"
            identity_path = root / "identity.json"

            identity = renderer_closure.build_closure(
                executable,
                bundle,
                closure,
                identity_path,
            )
            verified = renderer_closure.verify_closure(closure, identity)

            self.assertEqual(verified.executable, (closure / "EasySplatBenchmarkDriver").resolve())
            self.assertEqual(
                verified.resource_bundle,
                (closure / "MetalSplatter_MetalSplatter.bundle").resolve(),
            )
            self.assertEqual(identity["executable_sha256"], renderer_closure.sha256_file(executable))
            self.assertEqual(identity, renderer_closure.load_identity(identity_path))
            self.assertTrue(os.access(verified.executable, os.X_OK))

    def test_missing_bundle_and_tampered_shader_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable, bundle = self._source(root)
            closure = root / "closure"
            identity = renderer_closure.build_closure(
                executable,
                bundle,
                closure,
                root / "identity.json",
            )

            shader = closure / "MetalSplatter_MetalSplatter.bundle" / "Shaders.metal"
            shader.unlink()
            with self.assertRaisesRegex(renderer_closure.ClosureError, "missing"):
                renderer_closure.verify_closure(closure, identity)

            shader.write_bytes(b"kernel void changed() {}\n")
            with self.assertRaisesRegex(renderer_closure.ClosureError, "size|digest"):
                renderer_closure.verify_closure(closure, identity)

    def test_substituted_executable_and_unlisted_file_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable, bundle = self._source(root)
            closure = root / "closure"
            identity = renderer_closure.build_closure(
                executable,
                bundle,
                closure,
                root / "identity.json",
            )

            (closure / "EasySplatBenchmarkDriver").write_bytes(b"substituted")
            with self.assertRaisesRegex(renderer_closure.ClosureError, "size|digest"):
                renderer_closure.verify_closure(closure, identity)

            (closure / "EasySplatBenchmarkDriver").write_bytes(b"release-renderer")
            (closure / "unexpected.dylib").write_bytes(b"unbound")
            with self.assertRaisesRegex(renderer_closure.ClosureError, "closure file set"):
                renderer_closure.verify_closure(closure, identity)

    def test_nested_directory_symlink_is_rejected_before_shader_is_read(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable, bundle = self._source(root)
            closure = root / "closure"
            identity = renderer_closure.build_closure(
                executable,
                bundle,
                closure,
                root / "identity.json",
            )
            outside = root / "outside"
            outside.mkdir()
            (outside / "Shaders.metal").write_bytes(b"kernel void draw() {}\n")
            copied_bundle = closure / "MetalSplatter_MetalSplatter.bundle"
            shutil.rmtree(copied_bundle)
            copied_bundle.symlink_to(outside, target_is_directory=True)

            with self.assertRaisesRegex(renderer_closure.ClosureError, "unsafe ancestor"):
                renderer_closure.verify_closure(closure, identity)


if __name__ == "__main__":
    unittest.main()
