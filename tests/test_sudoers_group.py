"""Safe transformation of the %sudo rule in the primary sudoers file."""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "lib" / "sudoers_group.py"


def run_editor(source: str):
    with tempfile.TemporaryDirectory() as directory:
        original = Path(directory) / "sudoers"
        modified = Path(directory) / "candidate"
        original.write_text(source, encoding="utf-8")
        result = subprocess.run(
            [sys.executable, str(SCRIPT), str(original), str(modified)],
            capture_output=True,
            text=True,
            check=False,
        )
        return result, modified.read_text(encoding="utf-8") if modified.exists() else None


class GroupSudoersTests(unittest.TestCase):
    def test_exact_sudo_rule_replaced_only_for_group(self):
        start = "# sudoers\nroot ALL=(ALL:ALL) ALL\n%sudo ALL=(ALL:ALL) ALL\n@includedir /etc/sudoers.d\n"
        result, candidate = run_editor(start)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            candidate,
            "# sudoers\nroot ALL=(ALL:ALL) ALL\n%sudo ALL=(ALL:ALL) NOPASSWD: ALL\n@includedir /etc/sudoers.d\n",
        )

    def test_accepts_legacy_sudo_group_rule(self):
        result, candidate = run_editor("%sudo ALL=(ALL) ALL\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(candidate, "%sudo ALL=(ALL) NOPASSWD: ALL\n")

    def test_preserves_indentation_comments_and_other_rules(self):
        source = "# %sudo ALL=(ALL:ALL) ALL\n  %sudo  ALL=(ALL:ALL)  ALL  # normal sudo\nother ALL=(ALL) ALL\n"
        result, candidate = run_editor(source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            candidate,
            "# %sudo ALL=(ALL:ALL) ALL\n  %sudo  ALL=(ALL:ALL)  NOPASSWD: ALL  # normal sudo\nother ALL=(ALL) ALL\n",
        )

    def test_already_enabled_is_idempotent(self):
        source = "%sudo ALL=(ALL:ALL) NOPASSWD: ALL\n"
        result, candidate = run_editor(source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(candidate, source)

    def test_missing_sudo_group_rule_fails_closed(self):
        result, candidate = run_editor("root ALL=(ALL:ALL) ALL\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(candidate)

    def test_multiple_sudo_group_rules_fail_closed(self):
        result, candidate = run_editor("%sudo ALL=(ALL:ALL) ALL\n%sudo ALL=(ALL:ALL) ALL\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(candidate)

    def test_unsupported_sudo_group_rule_fails_closed(self):
        result, candidate = run_editor("%sudo ALL=(ALL:ALL) /usr/bin/ls\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(candidate)

    def test_preserves_last_line_without_newline(self):
        result, candidate = run_editor("%sudo ALL=(ALL:ALL) ALL")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(candidate, "%sudo ALL=(ALL:ALL) NOPASSWD: ALL")


if __name__ == "__main__":
    unittest.main()
