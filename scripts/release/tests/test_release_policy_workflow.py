#!/usr/bin/env python3

import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[3]
WORKFLOW = ROOT / ".github" / "workflows" / "release-app.yml"
START = "          # BEGIN TRUSTED RELEASE POLICY CHECKER\n"
END = "          # END TRUSTED RELEASE POLICY CHECKER\n"
WORKFLOW_PARSER_START = "          # BEGIN TRUSTED WORKFLOW YAML POLICY PARSER\n"
WORKFLOW_PARSER_END = "          # END TRUSTED WORKFLOW YAML POLICY PARSER\n"
TAG = "v0.2.0"
AUTHORITY = "dud8"
GITHUB_ACTIONS_APP_ID = 15368
REQUIRED_CHECKS = {
    "Swift · macOS 15 arm64 · Xcode 16.4",
    "Real 8 GB-class policy lane",
    "Native Metal trainer",
    "Repository contracts",
    "DA3 bridge · Python 3.12",
    "Actions and shell lint",
    "Python dependency audit",
    "Full-history secret scan",
    "Pull request dependency review",
    "Analyze swift",
    "Analyze python",
    "Analyze c-cpp",
    "Analyze actions",
}


def valid_snapshot():
    environment = {
        "name": "placeholder",
        "can_admins_bypass": False,
        "deployment_branch_policy": {
            "protected_branches": True,
            "custom_branch_policies": False,
        },
        "protection_rules": [
            {
                "type": "required_reviewers",
                "prevent_self_review": True,
                "reviewers": [
                    {
                        "type": "User",
                        "reviewer": {"login": "independent-reviewer"},
                    }
                ],
            }
        ],
    }
    return {
        "repository": {
            "full_name": "dud8/EasySplat",
            "default_branch": "main",
            "private": False,
            "visibility": "public",
            "owner": {"login": AUTHORITY, "type": "User"},
            "allow_squash_merge": True,
            "allow_merge_commit": False,
            "allow_rebase_merge": False,
            "delete_branch_on_merge": True,
        },
        "branch": {
            "required_pull_request_reviews": {
                "required_approving_review_count": 1,
                "dismiss_stale_reviews": True,
                "require_last_push_approval": True,
                "bypass_pull_request_allowances": {
                    "users": [],
                    "teams": [],
                    "apps": [],
                },
            },
            "enforce_admins": {"enabled": True},
            "required_status_checks": {
                "strict": True,
                "contexts": sorted(REQUIRED_CHECKS),
                "checks": [
                    {"context": context, "app_id": GITHUB_ACTIONS_APP_ID}
                    for context in sorted(REQUIRED_CHECKS)
                ],
            },
            "required_linear_history": {"enabled": True},
            "required_conversation_resolution": {"enabled": True},
            "allow_force_pushes": {"enabled": False},
            "allow_deletions": {"enabled": False},
        },
        "verification_environment": {
            **copy.deepcopy(environment),
            "name": "release-verification",
        },
        "signing_environment": {
            **copy.deepcopy(environment),
            "name": "release-signing",
        },
        "release_environment": {
            **copy.deepcopy(environment),
            "name": "release-publication",
        },
        "authority": {"login": AUTHORITY, "type": "User"},
        "collaborators": [
            {
                "login": AUTHORITY,
                "permissions": {
                    "admin": True,
                    "maintain": True,
                    "push": True,
                    "triage": True,
                    "pull": True,
                },
            },
            {
                "login": "independent-reviewer",
                "permissions": {
                    "admin": False,
                    "maintain": False,
                    "push": False,
                    "triage": True,
                    "pull": True,
                },
            },
        ],
        "keys": [{"id": 1, "read_only": True}],
        "actions": {
            "default_workflow_permissions": "read",
            "can_approve_pull_request_reviews": False,
        },
        "versions": ["2026-03-10", "2022-11-28"],
        "workflows": {
            ".github/workflows/ci.yml": "permissions:\n  contents: read\n",
            ".github/workflows/release-app.yml": "permissions:\n  contents: read\n",
        },
        "rulesets": [
            {
                "id": 42,
                "name": "Lock EasySplat release tag",
                "target": "tag",
                "enforcement": "active",
                "bypass_actors": [],
                "conditions": {
                    "ref_name": {
                        "include": [f"refs/tags/{TAG}"],
                        "exclude": [],
                    }
                },
                "rules": [{"type": "update"}, {"type": "deletion"}],
            }
        ],
    }


class ReleasePolicyWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        parser_heredoc = workflow.split(
            '          cat >"$WORKFLOW_PARSER" <<\'RUBY\'\n', 1
        )[1]
        if not parser_heredoc.startswith(
            "          #!/usr/bin/env ruby\n" + WORKFLOW_PARSER_START
        ):
            raise AssertionError("trusted workflow parser is not directly executable")
        if WORKFLOW_PARSER_START not in workflow or WORKFLOW_PARSER_END not in workflow:
            raise AssertionError("release workflow has no embedded trusted YAML parser")
        parser_source = parser_heredoc.split("          RUBY\n", 1)[0]
        cls.workflow_parser = textwrap.dedent(parser_source)

        heredoc = workflow.split('          cat >"$CHECKER" <<\'PY\'\n', 1)[1]
        if not heredoc.startswith(
            "          #!/usr/bin/env python3\n" + START
        ):
            raise AssertionError("trusted policy checker is not directly executable")
        if START not in workflow or END not in workflow:
            raise AssertionError("release workflow has no embedded trusted policy checker")
        body = workflow.split(START, 1)[1].split(END, 1)[0]
        cls.checker = textwrap.dedent(body)

    def run_snapshot(self, snapshot, expect_success, parser_hash=None):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            checker = root / "checker.py"
            checker.write_text(self.checker, encoding="utf-8")
            workflow_parser = root / "workflow-policy.rb"
            workflow_parser.write_text(self.workflow_parser, encoding="utf-8")
            workflow_parser.chmod(0o500)
            for name, value in snapshot.items():
                (root / f"{name}.json").write_text(
                    json.dumps(value, sort_keys=True), encoding="utf-8"
                )
            environment = os.environ.copy()
            environment["WORKFLOW_POLICY_PARSER"] = os.fspath(workflow_parser)
            environment["WORKFLOW_POLICY_PARSER_SHA256"] = parser_hash or hashlib.sha256(
                self.workflow_parser.encode("utf-8")
            ).hexdigest()
            result = subprocess.run(
                [
                    sys.executable,
                    os.fspath(checker),
                    "verify-snapshot",
                    "--snapshot-dir",
                    os.fspath(root),
                    "--repository",
                    "dud8/EasySplat",
                    "--tag",
                    TAG,
                ],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )
            if expect_success and result.returncode != 0:
                self.fail(result.stderr)
            if not expect_success and result.returncode == 0:
                self.fail("invalid live release policy was accepted")

    def test_valid_policy_passes(self):
        self.run_snapshot(valid_snapshot(), True)

    def test_tracked_workflow_closure_passes(self):
        snapshot = valid_snapshot()
        snapshot["workflows"] = {
            workflow.relative_to(ROOT).as_posix(): workflow.read_text(encoding="utf-8")
            for workflow in sorted((ROOT / ".github" / "workflows").glob("*.y*ml"))
        }
        self.run_snapshot(snapshot, True)

    def test_signing_job_never_executes_prepared_artifact_code(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        prepare = workflow.split("  prepare-release:\n", 1)[1].split(
            "  sign-and-notarize:\n", 1
        )[0]
        signing = workflow.split("  sign-and-notarize:\n", 1)[1].split(
            "  quarantined-install:\n", 1
        )[0]
        credentialed = signing.split(
            "      - name: Sign, notarize, and staple official artifacts\n", 1
        )[1].split("      - name: Create exact signed build closure\n", 1)[0]

        self.assertIn("runs-on: macos-26", prepare)
        self.assertIn("RUNNER_ENVIRONMENT: ${{ runner.environment }}", prepare)
        self.assertIn('test "$RUNNER_ENVIRONMENT" = "github-hosted"', prepare)
        self.assertIn("actions/checkout@", signing)
        self.assertIn(
            "ref: ${{ needs.live-policy-preflight.outputs.source_commit }}", signing
        )
        self.assertIn(
            '"$GITHUB_WORKSPACE/scripts/release/build_dmg.sh"', credentialed
        )
        self.assertIn("--manifest-tool-bin", credentialed)
        self.assertIn("PREPARED_MANIFEST_SHA256", signing)
        self.assertIn(
            '--prepared-manifest-sha256 "$PREPARED_MANIFEST_SHA256"',
            credentialed,
        )
        self.assertNotIn("$PREPARED_ROOT/source/", signing)
        self.assertNotIn("$PREPARED_ROOT/product/ManifestTool", credentialed)
        self.assertIn('test ! -e "$PREPARED_ROOT/product/ManifestTool"', signing)
        self.assertNotIn("$SOURCE_ROOT/scripts/", credentialed)

    def test_stale_review_policy_fails(self):
        snapshot = valid_snapshot()
        snapshot["branch"]["required_pull_request_reviews"]["dismiss_stale_reviews"] = False
        self.run_snapshot(snapshot, False)

    def test_wrong_status_app_fails(self):
        snapshot = valid_snapshot()
        snapshot["branch"]["required_status_checks"]["checks"][0]["app_id"] = None
        self.run_snapshot(snapshot, False)

    def test_writer_collaborator_fails(self):
        snapshot = valid_snapshot()
        snapshot["collaborators"][1]["permissions"]["push"] = True
        self.run_snapshot(snapshot, False)

    def test_authority_without_admin_permission_fails(self):
        snapshot = valid_snapshot()
        snapshot["collaborators"][0]["permissions"]["admin"] = False
        snapshot["collaborators"][0]["permissions"]["maintain"] = False
        self.run_snapshot(snapshot, False)

    def test_writable_deploy_key_fails(self):
        snapshot = valid_snapshot()
        snapshot["keys"][0]["read_only"] = False
        self.run_snapshot(snapshot, False)

    def test_workflow_contents_writer_fails(self):
        snapshot = valid_snapshot()
        snapshot["workflows"][".github/workflows/ci.yml"] = (
            "jobs:\n  mutate:\n    permissions:\n      contents: write\n"
        )
        self.run_snapshot(snapshot, False)

    def test_quoted_workflow_write_all_fails(self):
        snapshot = valid_snapshot()
        snapshot["workflows"][".github/workflows/ci.yml"] = (
            '"permissions": "write-all"\n'
        )
        self.run_snapshot(snapshot, False)

    def test_nested_case_variant_contents_writer_fails(self):
        snapshot = valid_snapshot()
        snapshot["workflows"][".github/workflows/ci.yml"] = (
            "jobs:\n"
            "  mutate:\n"
            "    Permissions:\n"
            "      ConTenTs: WrItE\n"
        )
        self.run_snapshot(snapshot, False)

    def test_inline_quoted_workflow_contents_writer_fails(self):
        snapshot = valid_snapshot()
        snapshot["workflows"][".github/workflows/ci.yml"] = (
            'jobs:\n  mutate:\n    permissions: {contents: "write", issues: read}\n'
        )
        self.run_snapshot(snapshot, False)

    def test_workflow_write_all_fails(self):
        snapshot = valid_snapshot()
        snapshot["workflows"][".github/workflows/ci.yml"] = (
            "permissions: write-all\n"
        )
        self.run_snapshot(snapshot, False)

    def test_release_admin_secret_in_another_workflow_fails(self):
        snapshot = valid_snapshot()
        snapshot["workflows"][".github/workflows/ci.yml"] = (
            "env:\n  GH_TOKEN: ${{ secrets.EASYSPLAT_RELEASE_ADMIN_TOKEN }}\n"
        )
        self.run_snapshot(snapshot, False)

    def test_case_variant_release_admin_secret_in_another_workflow_fails(self):
        snapshot = valid_snapshot()
        snapshot["workflows"][".github/workflows/ci.yml"] = (
            "env:\n  GH_TOKEN: ${{ secrets.easysplat_release_admin_token }}\n"
        )
        self.run_snapshot(snapshot, False)

    def test_signing_secret_in_another_workflow_fails(self):
        snapshot = valid_snapshot()
        snapshot["workflows"][".github/workflows/ci.yml"] = (
            "env:\n"
            "  IDENTITY: ${{ secrets.EASYSPLAT_DEVELOPER_ID_APPLICATION_SHA1 }}\n"
        )
        self.run_snapshot(snapshot, False)

    def test_case_variant_signing_secret_in_another_workflow_fails(self):
        snapshot = valid_snapshot()
        snapshot["workflows"][".github/workflows/ci.yml"] = (
            "env:\n"
            "  IDENTITY: ${{ secrets.easysplat_developer_id_application_sha1 }}\n"
        )
        self.run_snapshot(snapshot, False)

    def test_signing_environment_in_another_workflow_fails(self):
        snapshot = valid_snapshot()
        snapshot["workflows"][".github/workflows/ci.yml"] = (
            "jobs:\n"
            "  sign:\n"
            "    runs-on: macos-26\n"
            "    environment: release-signing\n"
            "    steps:\n"
            "      - run: true\n"
        )
        self.run_snapshot(snapshot, False)

    def test_release_admin_secret_bracket_expression_fails(self):
        snapshot = valid_snapshot()
        snapshot["workflows"][".github/workflows/ci.yml"] = (
            "env:\n"
            "  GH_TOKEN: ${{ secrets['EASYSPLAT_RELEASE_ADMIN_TOKEN'] }}\n"
        )
        self.run_snapshot(snapshot, False)

    def test_computed_release_admin_secret_fails(self):
        snapshot = valid_snapshot()
        snapshot["workflows"][".github/workflows/ci.yml"] = (
            "env:\n"
            "  GH_TOKEN: ${{ secrets[format('EASYSPLAT_{0}_ADMIN_TOKEN', 'RELEASE')] }}\n"
        )
        self.run_snapshot(snapshot, False)

    def test_release_environment_expression_fails(self):
        snapshot = valid_snapshot()
        snapshot["workflows"][".github/workflows/ci.yml"] = (
            'environment: "${{ \'release-publication\' }}"\n'
        )
        self.run_snapshot(snapshot, False)

    def test_computed_environment_selector_fails(self):
        snapshot = valid_snapshot()
        snapshot["workflows"][".github/workflows/ci.yml"] = (
            "jobs:\n"
            "  publish:\n"
            "    runs-on: macos-15\n"
            "    environment: ${{ format('{0}-{1}', 'release', 'release') }}\n"
            "    steps:\n"
            "      - run: true\n"
        )
        self.run_snapshot(snapshot, False)

    def test_workflow_parser_hash_mismatch_fails(self):
        self.run_snapshot(valid_snapshot(), False, parser_hash="0" * 64)

    def test_duplicate_workflow_keys_fail(self):
        snapshot = valid_snapshot()
        snapshot["workflows"][".github/workflows/ci.yml"] = (
            "permissions: read-all\n"
            "permissions:\n"
            "  contents: read\n"
        )
        self.run_snapshot(snapshot, False)

    def test_workflow_aliases_fail(self):
        snapshot = valid_snapshot()
        snapshot["workflows"][".github/workflows/ci.yml"] = (
            "defaults: &defaults\n"
            "  contents: read\n"
            "permissions: *defaults\n"
        )
        self.run_snapshot(snapshot, False)

    def test_workflow_explicit_tags_fail(self):
        snapshot = valid_snapshot()
        snapshot["workflows"][".github/workflows/ci.yml"] = (
            "permissions: !authority read-all\n"
        )
        self.run_snapshot(snapshot, False)

    def test_on_key_is_not_coerced_by_yaml_1_1(self):
        snapshot = valid_snapshot()
        snapshot["workflows"][".github/workflows/ci.yml"] = (
            "name: CI\n"
            "on:\n"
            "  pull_request:\n"
            "permissions:\n"
            "  contents: read\n"
            "jobs:\n"
            "  test:\n"
            "    runs-on: macos-15\n"
            "    steps:\n"
            "      - run: true\n"
        )
        self.run_snapshot(snapshot, True)

    def test_unsupported_api_version_fails(self):
        snapshot = valid_snapshot()
        snapshot["versions"] = ["2022-11-28"]
        self.run_snapshot(snapshot, False)

    def test_tag_ruleset_bypass_fails(self):
        snapshot = valid_snapshot()
        snapshot["rulesets"][0]["bypass_actors"] = [
            {"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always"}
        ]
        self.run_snapshot(snapshot, False)

    def test_tag_ruleset_without_update_lock_fails(self):
        snapshot = valid_snapshot()
        snapshot["rulesets"][0]["rules"] = [{"type": "deletion"}]
        self.run_snapshot(snapshot, False)

    def test_release_authority_cannot_review_its_own_environment(self):
        snapshot = valid_snapshot()
        snapshot["release_environment"]["protection_rules"][0]["reviewers"][0]["reviewer"]["login"] = AUTHORITY
        self.run_snapshot(snapshot, False)

    def test_signing_authority_cannot_review_its_own_environment(self):
        snapshot = valid_snapshot()
        snapshot["signing_environment"]["protection_rules"][0]["reviewers"][0]["reviewer"]["login"] = AUTHORITY
        self.run_snapshot(snapshot, False)

if __name__ == "__main__":
    unittest.main()
