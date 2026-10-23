"""No-host-mutation tests for SSH AllowUsers configuration editing."""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "lib" / "ssh_allowusers.py"


def render(contents: str, name: str) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory() as directory:
        source = Path(directory) / "sshd_config"
        destination = Path(directory) / "candidate"
        source.write_text(contents, encoding="utf-8")
        result = subprocess.run(
            [sys.executable, str(SCRIPT), str(source), str(destination), name],
            capture_output=True,
            text=True,
            check=False,
        )
        if destination.exists():
            result.candidate = destination.read_text(encoding="utf-8")
        else:
            result.candidate = None
        return result


class TestAllowUsersEdit(unittest.TestCase):
    def test_appends_at_end_when_there_are_no_match_blocks(self):
        original = "Include /etc/ssh/sshd_config.d/*.conf\nPasswordAuthentication yes\n"
        result = render(original, "admins")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.candidate, original + "AllowUsers admins\n"
        )

    def test_places_global_setting_before_first_match(self):
        original = "# example\nPort 22\nMatch User backup\n    ForceCommand internal-sftp\n"
        result = render(original, "admins")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.candidate,
            "# example\nPort 22\nAllowUsers admins\nMatch User backup\n"
            "    ForceCommand internal-sftp\n",
        )

    def test_preserves_other_allowed_users(self):
        original = "AllowUsers deploy backup@192.0.2.*\nPort 22\n"
        result = render(original, "admins")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("AllowUsers deploy backup@192.0.2.*", result.candidate)
        self.assertIn("AllowUsers admins\n", result.candidate)

    def test_does_not_duplicate_same_allowed_user(self):
        original = "AllowUsers deploy admins\nPort 22\n"
        result = render(original, "admins")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.candidate, original)

    def test_repeated_run_is_idempotent(self):
        first = render("Port 22\n", "admins")
        self.assertEqual(first.returncode, 0, first.stderr)
        second = render(first.candidate, "admins")
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(second.candidate, first.candidate)

    def test_unterminated_last_line_is_preserved(self):
        result = render("Port 22", "admins")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.candidate, "Port 22\nAllowUsers admins\n")

    def test_rejects_root_and_command_injection_names(self):
        for name in ("root", "admins;exit", "admins foo", "-oProxyCommand=x"):
            with self.subTest(name=name):
                result = render("Port 22\n", name)
                self.assertNotEqual(result.returncode, 0)
                self.assertIsNone(result.candidate)


if __name__ == "__main__":
    unittest.main()
