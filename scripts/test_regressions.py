#!/usr/bin/env python3
"""Regression checks for MDM retries and staged script generation."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
GENERATED = tuple(f"mdm/{mdm}-macos.sh" for mdm in ("kandji", "jamf", "fleet", "intune"))

INSTALL_FIXTURE = r'''
set -e
set -o pipefail
log_info() { printf 'INFO: %s\n' "$1"; }
log_warn() { printf 'WARN: %s\n' "$1"; }
log_error() { printf 'ERROR: %s\n' "$1" >&2; }
log_success() { printf 'SUCCESS: %s\n' "$1"; }
redact() { printf '%s' "$1"; }
is_safe_value() { [ -n "$1" ]; }
get_editor_cli_path() { printf '%s/editor\n' "$REVIEW_CASE"; }
get_editor_cli_path_alternative() { get_editor_cli_path; }
get_editor_ext_dir() { printf '.fixture/extensions\n'; }
run_extension_install() {
    printf '%s\n' "$editor" >> "$REVIEW_CASE/attempts"
    EXTENSION_OUTPUT_FILE=$(mktemp "$REVIEW_CASE/output.XXXXXX")
    INSTALL_TIMEOUT_USED=60
    if [ "$REVIEW_SCENARIO" = timeout ] && [ "$editor" = Cursor ]; then
        return 124
    fi
    if [ "$REVIEW_SCENARIO" = budget ]; then
        EXTENSION_PHASE_START=$((SECONDS - EXTENSION_PHASE_TIMEOUT))
    fi
    printf 'successfully installed\n' > "$EXTENSION_OUTPUT_FILE"
}
sudo() {
    [ "$1" = -u ] || return 99
    shift 2
    "$@"
}
curl() {
    cat > /dev/null
    printf '{"apiToken":"cor_review_fixture","apiTokenId":"review-fixture"}\n200\n'
}
CURRENT_USER=review-fixture
USER_HOME="$REVIEW_CASE/home"
CORRIDOR_CONFIG_DIR="$USER_HOME/.corridor"
INSTALLED_EDITORS='Cursor VSCode'
EDITOR_PATHS='Cursor:standard VSCode:standard'
EXTENSION_PHASE_TIMEOUT=150
PROVISION_PLATFORMS='cursor vscode'
CLI_INSTALLED=false
CORRIDOR_TEAM_TOKEN=cor-team_review_fixture
CORRIDOR_API_URL=https://invalid.example.test/api
DEVICE_SERIAL=REVIEW01
USER_EMAIL=review@example.test
'''


class ExtensionRetryTests(unittest.TestCase):
    def test_install_outcomes_preserve_token_provisioning(self):
        common = (ROOT / "src/macos/legacy-provision.sh").read_text()
        section = common[common.index("skip_remaining_editors() {"):]
        cases = (
            ("success", 0, ["Cursor", "VSCode"]),
            ("timeout", 1, ["Cursor", "VSCode"]),
            ("budget", 1, ["Cursor"]),
        )
        for scenario, expected_status, expected_attempts in cases:
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as temp:
                case = Path(temp)
                (case / "editor").touch()
                env = dict(os.environ, REVIEW_CASE=temp, REVIEW_SCENARIO=scenario)
                result = subprocess.run(
                    ["bash", "-c", INSTALL_FIXTURE + section],
                    cwd=case, env=env, text=True, capture_output=True,
                )
                self.assertEqual(result.returncode, expected_status, result.stdout + result.stderr)
                self.assertEqual((case / "attempts").read_text().splitlines(), expected_attempts)
                for platform in ("cursor", "vscode"):
                    pending = case / "home/.corridor" / platform / "pending-token"
                    self.assertEqual(json.loads(pending.read_text())["apiToken"], "cor_review_fixture")


class PreCommitTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / "repo"
        shutil.copytree(ROOT, self.repo, ignore=shutil.ignore_patterns(".git", "__pycache__"))
        self.git("init", "-q")
        self.git("add", ".")
        self.commit()

    def git(self, *args):
        return subprocess.run(
            ["git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", *args],
            cwd=self.repo, text=True, capture_output=True, check=True,
        )

    def commit(self):
        self.git("-c", "user.name=Regression Test", "-c", "user.email=test@example.test",
                 "commit", "-qm", "fixture")

    def hook(self):
        return subprocess.run(
            ["bash", ".githooks/pre-commit"], cwd=self.repo, text=True, capture_output=True,
        )

    def change_timeout(self, path, before, after):
        file = self.repo / path
        file.write_text(file.read_text().replace(
            f"EXTENSION_INSTALL_TIMEOUT={before}", f"EXTENSION_INSTALL_TIMEOUT={after}",
        ))

    def build(self):
        subprocess.run(["bash", "scripts/build.sh"], cwd=self.repo, check=True)

    def assert_index_builds(self):
        exported = Path(self.temp.name) / "index"
        exported.mkdir()
        self.git("checkout-index", "--all", f"--prefix={exported}/")
        result = subprocess.run(
            ["bash", "scripts/build.sh", "--check"],
            cwd=exported, text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_rebuilds_fully_staged_source(self):
        self.change_timeout("src/macos/legacy-provision.sh", 60, 61)
        self.git("add", "src/macos/legacy-provision.sh")
        result = self.hook()
        self.assertEqual(result.returncode, 0, result.stderr)
        for path in GENERATED:
            self.assertIn("EXTENSION_INSTALL_TIMEOUT=61", self.git("show", f":{path}").stdout)
        self.assert_index_builds()

    def test_rejects_partially_staged_source_without_rebuilding(self):
        self.change_timeout("src/macos/legacy-provision.sh", 60, 61)
        self.git("add", "src/macos/legacy-provision.sh")
        self.change_timeout("src/macos/legacy-provision.sh", 61, 62)
        outputs = {path: (self.repo / path).read_text() for path in GENERATED}
        result = self.hook()
        self.assertNotEqual(result.returncode, 0)
        for path, original in outputs.items():
            self.assertEqual((self.repo / path).read_text(), original)
            self.assertEqual(self.git("show", f":{path}").stdout, original)

    def test_rejects_untracked_include(self):
        source = self.repo / "src/macos/kandji.sh"
        source.write_text(source.read_text().replace(
            "# @include prelude.sh", "# @include prelude.sh\n# @include fixture-extra.sh",
        ))
        (self.repo / "src/macos/fixture-extra.sh").write_text("FIXTURE_FLAG=1\n")
        self.git("add", "src/macos/kandji.sh")
        self.assertNotEqual(self.hook().returncode, 0)

    def test_rejects_staged_generated_edit_hidden_in_working_tree(self):
        generated = self.repo / "mdm/jamf-macos.sh"
        original = generated.read_text()
        self.change_timeout("mdm/jamf-macos.sh", 60, 62)
        self.git("add", "mdm/jamf-macos.sh")
        staged = self.git("show", ":mdm/jamf-macos.sh").stdout
        generated.write_text(original)
        self.assertNotEqual(self.hook().returncode, 0)
        self.assertEqual(self.git("show", ":mdm/jamf-macos.sh").stdout, staged)
        self.assertEqual(generated.read_text(), original)

    def test_rejects_generated_hand_edit(self):
        self.change_timeout("mdm/jamf-macos.sh", 60, 62)
        self.git("add", "mdm/jamf-macos.sh")
        self.assertNotEqual(self.hook().returncode, 0)

    def test_accepts_current_generated_only_changes(self):
        self.change_timeout("src/macos/legacy-provision.sh", 60, 61)
        self.git("add", "src/macos/legacy-provision.sh")
        self.commit()
        self.build()
        self.git("add", *GENERATED)
        result = self.hook()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_index_builds()


if __name__ == "__main__":
    unittest.main(verbosity=2)
