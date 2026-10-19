#!/usr/bin/env python3
"""Unit tests for Docker mirror merging. Never touches /etc/docker."""
import json
import os
import pathlib
import sys
import tempfile
import unittest

PROJECT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT / "lib"))
from docker_mirrors import MIRRORS, merged_config, render


class DockerMirrorTests(unittest.TestCase):
    def test_adds_default_mirrors(self):
        result = merged_config({})
        self.assertEqual(result["registry-mirrors"], list(MIRRORS))

    def test_preserves_other_daemon_settings(self):
        data = {"dns": ["172.22.0.50"], "log-driver": "json-file"}
        result = merged_config(data)
        self.assertEqual(result["dns"], data["dns"])
        self.assertEqual(result["log-driver"], data["log-driver"])
        self.assertNotIn("registry-mirrors", data)

    def test_keeps_user_mirrors_first(self):
        existing = {"registry-mirrors": ["https://private.example.net", MIRRORS[0]]}
        result = merged_config(existing)
        self.assertEqual(result["registry-mirrors"][0], "https://private.example.net")
        self.assertEqual(result["registry-mirrors"].count(MIRRORS[0]), 1)

    def test_idempotent(self):
        first = merged_config({"debug": True})
        self.assertEqual(merged_config(first), first)

    def test_rejects_non_object_json(self):
        for item in ([], None, "hello", 42):
            with self.subTest(item=item):
                with self.assertRaises(ValueError):
                    merged_config(item)

    def test_rejects_invalid_registry_mirrors_type(self):
        for bad in ("text", {"url": "x"}, [1, 2], None):
            with self.subTest(bad=bad):
                with self.assertRaises(ValueError):
                    merged_config({"registry-mirrors": bad})

    def test_renders_into_staging_path(self):
        with tempfile.TemporaryDirectory() as folder:
            source = os.path.join(folder, "daemon.json")
            staged = os.path.join(folder, ".daemon.test")
            with open(source, "w", encoding="utf-8") as f:
                json.dump({"dns": ["1.1.1.1"]}, f)
            render(source, staged)
            with open(source, encoding="utf-8") as f:
                self.assertEqual(json.load(f), {"dns": ["1.1.1.1"]})
            with open(staged, encoding="utf-8") as f:
                self.assertIn(MIRRORS[0], json.load(f)["registry-mirrors"])
            self.assertEqual(os.stat(staged).st_mode & 0o777, 0o644)

    def test_bad_json_does_not_overwrite_existing_target(self):
        with tempfile.TemporaryDirectory() as folder:
            source = os.path.join(folder, "daemon.json")
            staged = os.path.join(folder, ".daemon.test")
            pathlib.Path(source).write_text("{invalid", encoding="utf-8")
            pathlib.Path(staged).write_text("previous", encoding="utf-8")
            with self.assertRaises(json.JSONDecodeError):
                render(source, staged)
            self.assertEqual(pathlib.Path(staged).read_text(), "previous")


if __name__ == "__main__":
    unittest.main()
