from __future__ import annotations

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[3]
ENTRYPOINT = ROOT / "scripts" / "ci" / "test_release_scripts.sh"
HOSTILE_SUPERVISION = ROOT / "scripts" / "ci" / "test_hostile_process_supervision.sh"
PACKAGE = ROOT / "Package.swift"
MANIFEST_TOOL_ROOT = ROOT / "Tools" / "ManifestTool"
MANIFEST_TOOL_PACKAGE = MANIFEST_TOOL_ROOT / "Package.swift"
VERIFY_RELEASE = ROOT / "scripts" / "release" / "verify_release.sh"
RELEASE_WORKFLOW = ROOT / ".github" / "workflows" / "release-app.yml"
WORKFLOW_ROOT = ROOT / ".github" / "workflows"
UI_VERIFIER_ROOT = ROOT / "Tools" / "UIVerifier"
VERIFY_UI = ROOT / "scripts" / "release" / "verify_ui.sh"
DOCUMENTS = (
    ROOT / "README.md",
    ROOT / "CONTRIBUTING.md",
    ROOT / "ONBOARDING.md",
    ROOT / ".github" / "pull_request_template.md",
)
DOCUMENTED_LOCAL_CHECKS = (
    ROOT / "scripts" / "test.sh",
    ROOT / "scripts" / "test_python_tools.sh",
    ROOT / "scripts" / "ci" / "check_repo_health.sh",
    ROOT / "scripts" / "ci" / "check_workflows.sh",
    ROOT / "scripts" / "ci" / "test_release_scripts.sh",
    ROOT / "scripts" / "benchmark" / "run_suite.sh",
    ROOT / "scripts" / "ci" / "test_msplat_native_build.sh",
)
SOURCED_RELEASE_HELPERS = (
    ROOT / "scripts" / "release" / "lib" / "token_process_cleanup.sh",
    ROOT / "scripts" / "release" / "lib" / "strict_semver.sh",
    ROOT / "scripts" / "release" / "lib" / "e2e_verifier.sh",
    ROOT / "scripts" / "release" / "lib" / "packaged_app_bootstrap_smoke.sh",
)


def swift_code_without_literals(source: str) -> str:
    source = re.sub(r'""".*?"""', '""', source, flags=re.DOTALL)
    source = re.sub(r'"(?:\\.|[^"\\])*"', '""', source)
    source = re.sub(r'/\*.*?\*/', '', source, flags=re.DOTALL)
    return re.sub(r'//.*$', '', source, flags=re.MULTILINE)


def package_test_target_paths(package: str) -> set[Path]:
    paths: set[Path] = set()
    cursor = 0
    marker = ".testTarget("
    while True:
        start = package.find(marker, cursor)
        if start < 0:
            break
        index = start + len(marker)
        depth = 1
        in_string = False
        escaped = False
        while index < len(package) and depth:
            character = package[index]
            if in_string:
                if escaped:
                    escaped = False
                elif character == "\\":
                    escaped = True
                elif character == '"':
                    in_string = False
            elif character == '"':
                in_string = True
            elif character == "(":
                depth += 1
            elif character == ")":
                depth -= 1
            index += 1
        if depth:
            raise AssertionError("unterminated testTarget declaration in Package.swift")
        block = package[start:index]
        match = re.search(r'\bpath:\s*"([^"]+)"', block)
        if match is None:
            raise AssertionError("every test target must declare an auditable path")
        paths.add(Path(match.group(1)))
        cursor = index
    return paths


def workflow_jobs(source: str) -> dict[str, str]:
    jobs = source.split("\njobs:\n", 1)[1]
    matches = list(re.finditer(r"^  ([a-z0-9][a-z0-9_-]*):\s*$", jobs, re.MULTILINE))
    return {
        match.group(1): jobs[
            match.start() : matches[index + 1].start() if index + 1 < len(matches) else len(jobs)
        ]
        for index, match in enumerate(matches)
    }


class ReleaseEntrypointHeadlessContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.entrypoint = ENTRYPOINT.read_text(encoding="utf-8")
        self.hostile_supervision = HOSTILE_SUPERVISION.read_text(encoding="utf-8")
        self.package = PACKAGE.read_text(encoding="utf-8")
        self.manifest_tool_package = MANIFEST_TOOL_PACKAGE.read_text(encoding="utf-8")
        self.verify_release = VERIFY_RELEASE.read_text(encoding="utf-8")
        self.release_workflow = RELEASE_WORKFLOW.read_text(encoding="utf-8")

    def test_static_headless_contract_runs_before_the_release_suite(self) -> None:
        contract = (
            '/usr/bin/python3 -I \\\n  "$ROOT/scripts/release/tests/'
            'test_release_entrypoint_headless.py"'
        )
        self.assertIn(contract, self.entrypoint)
        self.assertLess(
            self.entrypoint.index(contract),
            self.entrypoint.index(
                'source "$ROOT/scripts/release/lib/token_process_cleanup.sh"'
            ),
        )

    def test_complete_suite_runs_in_a_sacrificial_process_session(self) -> None:
        boundary = 'EASYSPLAT_RELEASE_TEST_SACRIFICIAL_CHILD'
        source = 'source "$ROOT/scripts/release/lib/token_process_cleanup.sh"'
        self.assertIn('start_new_session=True', self.entrypoint)
        self.assertIn('/usr/bin/python3 -I - "$$"', self.entrypoint)
        self.assertIn('expected_session_leader = int(sys.argv[1])', self.entrypoint)
        self.assertIn('os.getppid() != expected_session_leader', self.entrypoint)
        self.assertIn('os.getsid(0) != expected_session_leader', self.entrypoint)
        self.assertIn('os.getpgrp() != expected_session_leader', self.entrypoint)
        self.assertNotIn('os.getsid(0) != os.getpid()', self.entrypoint)
        self.assertGreaterEqual(self.entrypoint.count(boundary), 2)
        self.assertLess(self.entrypoint.index(boundary), self.entrypoint.index(source))

    def test_entrypoint_does_not_execute_foreground_ui_automation(self) -> None:
        forbidden = (
            r"^\s*(?:/usr/bin/)?open\s",
            r"^\s*osascript\s",
            r'^\s*"?\$ROOT/scripts/release/verify_ui\.sh"?(?:\s|\\|$)',
            r"^\s*(?:/usr/bin/)?swift\s+run[^\n]*\bUIVerifier\b",
            r"CGEvent\([^\n]*\)\.post\(",
            r"AXUIElementCreateApplication\(",
            r"activateIgnoringOtherApps",
            r"makeKeyAndOrderFront",
        )
        for pattern in forbidden:
            with self.subTest(pattern=pattern):
                self.assertIsNone(
                    re.search(pattern, self.entrypoint, flags=re.MULTILINE),
                    f"release-test entrypoint contains foreground UI behavior: {pattern}",
                )

    def test_package_test_targets_contain_no_live_ui_or_input_code(self) -> None:
        test_paths = package_test_target_paths(self.package)
        self.assertNotIn(Path("Tools/UIVerifier/Tests"), test_paths)
        self.assertIn(Path("EasySplatAppTests"), test_paths)
        self.assertGreaterEqual(len(test_paths), 5)
        manifest_test_paths = package_test_target_paths(self.manifest_tool_package)
        self.assertEqual(manifest_test_paths, {Path("Tests/ManifestToolCoreTests")})

        forbidden = (
            r"\bNSWorkspace\.shared\.openApplication\s*\(",
            r"\bAXUIElementCreateApplication\s*\(",
            r"\bAXUIElementCreateSystemWide\s*\(",
            r"\bAXIsProcessTrusted\s*\(",
            r"\bCGPreflightScreenCaptureAccess\s*\(",
            r"\.postToPid\s*\(",
            r"\.post\s*\(\s*tap\s*:",
            r"\bmakeKeyAndOrderFront\s*\(",
        )
        source_roots = [(ROOT, relative) for relative in test_paths]
        source_roots.extend(
            (MANIFEST_TOOL_ROOT, relative) for relative in manifest_test_paths
        )
        for package_root, relative in sorted(source_roots):
            root = package_root / relative
            swift_files = sorted(root.rglob("*.swift"))
            self.assertTrue(swift_files, f"test target has no Swift sources: {relative}")
            for path in swift_files:
                code = swift_code_without_literals(path.read_text(encoding="utf-8"))
                for pattern in forbidden:
                    with self.subTest(path=path.relative_to(ROOT), pattern=pattern):
                        self.assertIsNone(re.search(pattern, code))

    def test_documented_local_checks_have_no_foreground_ui_entrypoint(self) -> None:
        documentation = "\n".join(path.read_text(encoding="utf-8") for path in DOCUMENTS)
        for command in (
            "./scripts/test.sh",
            "swift test --package-path Tools/ManifestTool",
            "./scripts/test_python_tools.sh",
            "./scripts/ci/check_repo_health.sh",
            "./scripts/ci/check_workflows.sh",
            "./scripts/ci/test_release_scripts.sh",
        ):
            self.assertIn(command, documentation)

        direct_execution = (
            r"^\s*(?:/usr/bin/)?open(?:\s|$)",
            r"^\s*(?:/usr/bin/)?osascript(?:\s|$)",
            r"^\s*.*EasySplatUIVerifier(?:\s|\\).*\brun\b",
            r"^\s*(?:\S+/)?verify_ui\.sh(?:\s|\\|$)",
        )
        for path in DOCUMENTED_LOCAL_CHECKS:
            source = path.read_text(encoding="utf-8")
            if path == ENTRYPOINT:
                continue
            for pattern in direct_execution:
                with self.subTest(path=path.relative_to(ROOT), pattern=pattern):
                    self.assertIsNone(re.search(pattern, source, re.MULTILINE))

        python_entrypoint = (ROOT / "scripts" / "test_python_tools.sh").read_text(
            encoding="utf-8"
        )
        python_tests = re.findall(
            r'^run_suite\s+"[^"]+"\s+"([^"]+)"\s*$',
            python_entrypoint,
            re.MULTILINE,
        )
        self.assertTrue(python_tests)
        for relative in python_tests:
            test_source = (ROOT / relative).read_text(encoding="utf-8")
            for token in (
                "NSWorkspace",
                "CGEvent",
                "AXUIElement",
                "makeKeyAndOrderFront",
                "/usr/bin/open",
                "osascript",
            ):
                with self.subTest(path=relative, token=token):
                    self.assertNotIn(token, test_source)

    def test_sourced_release_helpers_are_audited_and_launch_only_inert_fixtures(self) -> None:
        for helper in SOURCED_RELEASE_HELPERS:
            self.assertTrue(helper.is_file())
            self.assertIn(helper.name, self.verify_release)

        for helper in (
            SOURCED_RELEASE_HELPERS[0],
            SOURCED_RELEASE_HELPERS[2],
            SOURCED_RELEASE_HELPERS[3],
        ):
            self.assertIn(helper.name, self.entrypoint)

        for helper in SOURCED_RELEASE_HELPERS[:3]:
            source = helper.read_text(encoding="utf-8")
            for token in ("NSWorkspace", "CGEvent", "AXUIElement", "makeKeyAndOrderFront"):
                self.assertNotIn(token, source, f"live UI token in {helper.relative_to(ROOT)}")

        packaged = SOURCED_RELEASE_HELPERS[3].read_text(encoding="utf-8")
        self.assertIn("--easysplat-release-verify-bundled-pipeline", packaged)
        self.assertIn('< /dev/null >"$APP_WIRING_LOG" 2>&1 &', packaged)
        for token in ("NSWorkspace", "CGEvent", "AXUIElement", "/usr/bin/open"):
            self.assertNotIn(token, packaged)

        broker_start = self.entrypoint.index('broker_open_invoker="$broker_probe_root/invoke-open.py"')
        broker_end = self.entrypoint.index('if [ "$broker_probe_failures" -ne 0 ]', broker_start)
        broker_fixture = self.entrypoint[broker_start:broker_end]
        remainder = self.entrypoint[:broker_start] + self.entrypoint[broker_end:]
        self.assertIn('"/usr/bin/open"', broker_fixture)
        self.assertIn("configuration.activates = NO", broker_fixture)
        self.assertNotIn('"/usr/bin/open"', remainder)
        self.assertNotIn("openApplicationAtURL", remainder)

        regular_fixture = self.entrypoint.index("NSApplicationActivationPolicyRegular")
        inert_replacement = self.entrypoint.index(
            'cat >"$INSTALLED_EXECUTABLE" <<\'PY\'', regular_fixture
        )
        first_packaged_smoke = self.entrypoint.index(
            'run_packaged_app_bootstrap_smoke "$packaged_hook_fixture"',
            inert_replacement,
        )
        self.assertLess(regular_fixture, inert_replacement)
        self.assertLess(inert_replacement, first_packaged_smoke)

    def test_packaged_app_smoke_is_positive_opt_in_and_required_by_strict_release(self) -> None:
        self.assertIn("RUN_PACKAGED_APP_SMOKE=0", self.verify_release)
        self.assertIn("--packaged-app-smoke) RUN_PACKAGED_APP_SMOKE=1", self.verify_release)
        self.assertIn(
            'Release verification requires explicit --packaged-app-smoke.',
            self.verify_release,
        )
        self.assertNotIn("SKIP_PACKAGED_APP_SMOKE=0", self.verify_release)
        smoke_gate = self.verify_release.index('if [ "$RUN_PACKAGED_APP_SMOKE" -eq 1 ]; then')
        launch = self.verify_release.index(
            'run_packaged_app_bootstrap_smoke "$E2E_FIXTURE_MEDIA"'
        )
        self.assertLess(smoke_gate, launch)

    def test_workflow_omits_live_ui_and_limits_packaged_launch_to_release_jobs(self) -> None:
        jobs = workflow_jobs(self.release_workflow)
        self.assertNotIn("shipping-ui-verification", jobs)

        verify_release_jobs: set[str] = set()
        for name, body in jobs.items():
            self.assertNotIn("scripts/release/verify_ui.sh", body)
            if "scripts/release/verify_release.sh" in body:
                verify_release_jobs.add(name)
                self.assertIn("--packaged-app-smoke", body)
            if "/usr/bin/open -n" in body:
                self.assertEqual(name, "quarantined-install")
            for token in ("CGEvent", "AXUIElement", "makeKeyAndOrderFront"):
                self.assertNotIn(token, body)

        self.assertEqual(
            verify_release_jobs,
            {"quarantined-install", "macos15-signed-compatibility"},
        )
        for name, runner in (
            ("quarantined-install", "runs-on: macos-26"),
            ("macos15-signed-compatibility", "runs-on: macos-15"),
        ):
            body = jobs[name]
            self.assertIn("needs: [prepare-release, sign-and-notarize]", body)
            self.assertIn(
                "if: github.ref == 'refs/heads/main' && github.event.repository.default_branch == 'main'",
                body,
            )
            self.assertIn(runner, body)

        for workflow in sorted(WORKFLOW_ROOT.glob("*.y*ml")):
            if workflow == RELEASE_WORKFLOW:
                continue
            source = workflow.read_text(encoding="utf-8")
            for token in (
                "scripts/release/verify_ui.sh",
                "scripts/release/verify_release.sh",
                "/usr/bin/open -n",
                "CGEvent",
                "AXUIElement",
                "makeKeyAndOrderFront",
            ):
                with self.subTest(workflow=workflow.name, token=token):
                    self.assertNotIn(token, source)

    def test_ui_verifier_release_surface_is_physically_absent(self) -> None:
        self.assertFalse(UI_VERIFIER_ROOT.exists())
        self.assertFalse(VERIFY_UI.exists())
        self.assertNotIn("EasySplatUIVerifier", self.package)
        for token in (
            "shipping-ui-verification",
            "scripts/release/verify_ui.sh",
            "EasySplatUIVerifier",
            "release-ui-verification",
            "easysplat-ui-verifier",
            "ui_verification",
        ):
            self.assertNotIn(token, self.release_workflow)

    def test_parent_kill_fixtures_exist_only_behind_a_new_session(self) -> None:
        for forbidden in (
            r"os\.kill\(os\.getppid\(\),\s*signal\.SIGKILL\)",
            r"\bkill\s+(?:-[A-Z]+\s+)?[\"']?\$\$",
            r"\bkill\s+(?:-[A-Z]+\s+)?[\"']?\$PPID",
        ):
            self.assertIsNone(re.search(forbidden, self.entrypoint))

        self.assertIn(
            "os.kill(os.getppid(), signal.SIGKILL)",
            self.hostile_supervision,
        )
        parent_probe = self.hostile_supervision.index(
            "run_sacrificial_fixture parent-kill-probe -9"
        )
        session_boundary = self.hostile_supervision.index("start_new_session=True")
        self.assertLess(session_boundary, parent_probe)
        self.assertGreaterEqual(
            self.hostile_supervision.count("require_outer_identity()"),
            3,
        )


if __name__ == "__main__":
    unittest.main()
