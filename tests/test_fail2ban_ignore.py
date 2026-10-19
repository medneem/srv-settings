#!/usr/bin/env python3
"""Unit tests for the persistent SSH Fail2ban IP/CIDR allowlist."""
import importlib.util
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("fail2ban_ignore", ROOT / "lib/fail2ban_ignore.py")
mod = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mod)


class IgnoreIpTests(unittest.TestCase):
    def test_valid_ipv4_ipv6_and_networks(self):
        self.assertEqual(mod.parse_csv("192.0.2.8, 10.1.2.7/24, 2001:db8::1, 2001:db8:1::9/48"),
                         ["192.0.2.8", "10.1.2.0/24", "2001:db8::1", "2001:db8:1::/48"])

    def test_duplicate_addresses_are_ignored(self):
        self.assertEqual(mod.parse_csv("192.0.2.2,192.0.2.2, 192.0.2.2"), ["192.0.2.2"])

    def test_invalid_values_are_rejected_atomically(self):
        bad = ["", ",", "192.0.2.2,", ",192.0.2.2", "192.0.2.2,,::1",
               "unknown.example.org", "192.0.2.999", "192.0.2.1; touch /tmp/a",
               "192.0.2.2 192.0.2.3", "0.0.0.0/0", "::/0"]
        for value in bad:
            with self.subTest(value=value), self.assertRaises(ValueError):
                mod.parse_csv(value)

    def test_add_remove_and_idempotence(self):
        original = ["192.0.2.1"]
        added = mod.apply_edit(original, "add", "192.0.2.1, 2001:db8::9, 10.0.0.4/24")
        self.assertEqual(added, ["192.0.2.1", "2001:db8::9", "10.0.0.0/24"])
        self.assertEqual(mod.apply_edit(added, "add", "10.0.0.0/24"), added)
        self.assertEqual(mod.apply_edit(added, "remove", "2001:db8::9"),
                         ["192.0.2.1", "10.0.0.0/24"])

    def test_localhost_cannot_be_removed(self):
        self.assertEqual(mod.apply_edit([], "remove", "127.0.0.1/8, ::1"), [])
        self.assertEqual(mod.apply_edit([], "add", "127.0.0.1/8, ::1"), [])

    def test_render_preserves_localhost_and_only_ssh_jail(self):
        text = mod.render(["192.0.2.1", "2001:db8::/32"])
        self.assertTrue(text.startswith(mod.HEADER))
        self.assertIn("[sshd]\nignoreip = 127.0.0.0/8 ::1 192.0.2.1 2001:db8::/32", text)
        self.assertNotIn("[DEFAULT]", text)

    def test_remove_last_user_ip_removes_override(self):
        self.assertEqual(mod.render([]), "")

    def test_round_trip(self):
        with tempfile.TemporaryDirectory() as folder:
            path = pathlib.Path(folder) / "95-srv-settings-ignore.local"
            self.assertEqual(mod.load_managed(path), [])
            entries = mod.apply_edit([], "add", "198.51.100.4, 2001:db8::5")
            path.write_text(mod.render(entries), encoding="utf-8")
            self.assertEqual(mod.load_managed(path), entries)
            self.assertEqual(mod.apply_edit(mod.load_managed(path), "remove", "198.51.100.4"),
                             ["2001:db8::5"])

    def test_refuses_to_overwrite_unmanaged_file(self):
        with tempfile.TemporaryDirectory() as folder:
            path = pathlib.Path(folder) / "existing.local"
            path.write_text("[sshd]\nignoreip = 192.0.2.5\n", encoding="utf-8")
            with self.assertRaises(ValueError):
                mod.load_managed(path)

    def test_refuses_corrupted_managed_file(self):
        with tempfile.TemporaryDirectory() as folder:
            path = pathlib.Path(folder) / "managed.local"
            path.write_text(mod.HEADER + "[sshd]\nignoreip = 192.0.2.5\n", encoding="utf-8")
            with self.assertRaises(ValueError):
                mod.load_managed(path)

    def test_show_does_not_modify_file(self):
        with tempfile.TemporaryDirectory() as folder:
            path = pathlib.Path(folder) / "managed.local"
            path.write_text(mod.render(["203.0.113.9"]), encoding="utf-8")
            self.assertEqual(mod.main(["show", str(path)]), 0)
            self.assertEqual(mod.load_managed(path), ["203.0.113.9"])


if __name__ == "__main__":
    unittest.main()
