#!/usr/bin/env python3
"""Filesystem-only failure checks; no installed app, launch, TCC or UI changes."""
import importlib.util
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("replacement", Path(__file__).with_name("replace-app-bundle.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class InstallerChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="trump-installer-check-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source, self.dest = self.root / "Source.app", self.root / "Installed.app"
        self.source.mkdir(); self.dest.mkdir()
        (self.source / "new").write_bytes(b"new bundle")
        (self.dest / "old").write_bytes(b"old bundle")

    def replace(self, verify=lambda p: None, copy=shutil.copytree, before=lambda: None):
        module.replace_bundle(self.source, self.dest, copy, verify, before)

    def assertOldIntact(self):
        self.assertEqual((self.dest / "old").read_bytes(), b"old bundle")
        self.assertFalse((self.dest / "new").exists())
        self.assertEqual(list(self.root.glob(".TrumpSwitcher-update-*")), [])

    def test_complete_replacement_removes_old_resources(self):
        self.replace()
        self.assertEqual((self.dest / "new").read_bytes(), b"new bundle")
        self.assertFalse((self.dest / "old").exists())
        self.assertEqual(list(self.root.glob(".TrumpSwitcher-update-*")), [])

    def test_copy_failure_keeps_old(self):
        def broken(source, dest):
            dest.mkdir(); (dest / "partial").touch(); raise OSError("copy failure")
        with self.assertRaises(OSError): self.replace(copy=broken)
        self.assertOldIntact()

    def test_invalid_staged_signature_keeps_old(self):
        def invalid(path): raise ValueError("signature rejected")
        with self.assertRaises(ValueError): self.replace(verify=invalid)
        self.assertOldIntact()

    def test_invalid_installed_signature_restores_old(self):
        def verify(path):
            if path == self.dest: raise ValueError("final verification failure")
        with self.assertRaises(ValueError): self.replace(verify=verify)
        self.assertOldIntact()

    def test_application_reopened_before_commit_keeps_old(self):
        def running(): raise RuntimeError("app reopened")
        with self.assertRaises(RuntimeError): self.replace(before=running)
        self.assertOldIntact()

    def test_failed_first_install_removes_partial_application(self):
        shutil.rmtree(self.dest)
        def verify(path):
            if path == self.dest: raise ValueError("final verification failure")
        with self.assertRaises(ValueError): self.replace(verify=verify)
        self.assertFalse(self.dest.exists())
        self.assertEqual(list(self.root.glob(".TrumpSwitcher-update-*")), [])

    def test_symlink_destination_is_not_followed(self):
        shutil.rmtree(self.dest); self.dest.symlink_to(self.source, target_is_directory=True)
        with self.assertRaises(ValueError): self.replace()
        self.assertEqual((self.source / "new").read_bytes(), b"new bundle")

    def test_failed_rollback_preserves_recovery_copy(self):
        rename = module.os.rename
        def broken(source, dest):
            if Path(source).name == "Previous.app": raise OSError("restore refused")
            return rename(source, dest)
        def verify(path):
            if path == self.dest: raise ValueError("final verification failure")
        with patch.object(module.os, "rename", side_effect=broken):
            with self.assertRaises(OSError): self.replace(verify=verify)
        saved = list(self.root.glob(".TrumpSwitcher-update-*/Previous.app/old"))
        self.assertEqual(len(saved), 1)
        self.assertEqual(saved[0].read_bytes(), b"old bundle")


if __name__ == "__main__": unittest.main()
