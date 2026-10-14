#!/usr/bin/env python3
"""Offline regression tests for the source-built inventory cache boundary."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("inventory_tools", Path(__file__).with_name("ci-inventory-tools.py"))
tools = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tools)


class CacheTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "bin").mkdir()
        suffix = ".exe" if os.name == "nt" else ""
        self.names = [name + suffix for name in tools.TOOLS]
        for name in self.names:
            (self.root / "bin" / name).write_bytes(name.encode())
        self.manifest = {"versions": tools.TOOLS, "sha256": {name: tools.digest(self.root / "bin" / name) for name in self.names}}
        self.save_manifest()

    def save_manifest(self):
        (self.root / "manifest.json").write_text(json.dumps(self.manifest), encoding="utf-8")

    @patch.object(tools.subprocess, "check_output", side_effect=["cargo-audit 0.22.2", "cargo-cyclonedx 0.5.9"])
    def test_valid_cache_checks_versions_after_hashes(self, run):
        tools.verify(self.root)
        self.assertEqual(run.call_count, 2)
        self.assertEqual(run.call_args_list[0].args[0], ["cargo", "audit", "--version"])
        self.assertEqual(run.call_args_list[1].args[0], ["cargo", "cyclonedx", "--version"])

    @patch.object(tools.subprocess, "check_output")
    def test_modified_binary_never_executes(self, run):
        (self.root / "bin" / self.names[0]).write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "checksum"):
            tools.verify(self.root)
        run.assert_not_called()

    @patch.object(tools.subprocess, "check_output")
    def test_missing_binary_never_executes(self, run):
        (self.root / "bin" / self.names[0]).unlink()
        with self.assertRaises(FileNotFoundError):
            tools.verify(self.root)
        run.assert_not_called()

    @patch.object(tools.subprocess, "check_output")
    def test_wrong_tool_set_never_executes(self, run):
        self.manifest["versions"] = {"cargo-audit": "0.22.1"}
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, "versions"):
            tools.verify(self.root)
        run.assert_not_called()

    @patch.object(tools.subprocess, "check_output", return_value="cargo-audit 0.22.20")
    def test_version_match_is_exact(self, run):
        with self.assertRaisesRegex(ValueError, "version"):
            tools.verify(self.root)

    @patch.object(tools.subprocess, "check_output")
    def test_unexpected_manifest_binary_never_executes(self, run):
        self.manifest["sha256"]["extra"] = "0" * 64
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, "unexpected"):
            tools.verify(self.root)
        run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
