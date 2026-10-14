#!/usr/bin/env python3
"""Small synthetic filesystem regressions; never runs an app or accesses UI."""

import importlib.util
import json
import pathlib
import plistlib
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("evidence", pathlib.Path(__file__).with_name("verify-build-evidence.py"))
evidence = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evidence)


class BuildEvidenceChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="build-evidence-check-")
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.bundle = self.root / "Test.app"
        for name in ("Sources", "Assets", "scripts", "Test.app/Contents/MacOS", "Test.app/Contents/Resources"):
            (self.root / name).mkdir(parents=True)
        for name in ("Package.swift", "THIRD_PARTY.md", "Sources/main.swift", "build.log"):
            (self.root / name).write_text("fixed test input\n")
        (self.bundle / "Contents/MacOS/Test").write_bytes(b"not an executable; never run")
        self.resource = self.bundle / "Contents/Resources/dictionary.txt"
        self.resource.write_text("fixed dictionary\n")
        (self.bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "Test", "CFBundleVersion": "58", "CFBundleShortVersionString": "0.6.30"}))
        manifest = {"version": "0.6.30", "build": "58", "packagedSHA256": evidence.digest(self.bundle / "Contents/MacOS/Test"),
                    "sourceSHA256": {"Sources/main.swift": evidence.digest(self.root / "Sources/main.swift")},
                    "checks": {"buildLog": "build.log", "buildLogSHA256": evidence.digest(self.root / "build.log")}}
        self.manifest = self.root / "release.json"
        self.manifest.write_text(json.dumps(manifest))
        self.checkpoint = evidence.snapshot(self.root, self.bundle, self.manifest)

    def check(self, reports=()):
        return evidence.verify(self.checkpoint, self.root, self.bundle, reports)

    def test_unchanged_files(self):
        result = self.check()
        self.assertTrue(result["filesVerified"])
        self.assertFalse(result["runtimeSuccessClaimed"])

    def test_tampered_resource(self):
        self.resource.write_text("modified dictionary\n")
        result = self.check()
        self.assertFalse(result["filesVerified"])
        self.assertEqual(result["bundleDifferences"]["changed"], ["Contents/Resources/dictionary.txt"])

    def test_unexpected_packaged_file(self):
        (self.bundle / "Contents/Resources/unexpected.txt").write_text("extra")
        self.assertFalse(self.check()["filesVerified"])

    def test_changed_source(self):
        (self.root / "Sources/main.swift").write_text("changed")
        self.assertFalse(self.check()["filesVerified"])
        with self.assertRaisesRegex(ValueError, "source mismatch"):
            evidence.snapshot(self.root, self.bundle, self.manifest)

    def test_wrong_binary_manifest(self):
        (self.bundle / "Contents/MacOS/Test").write_bytes(b"different binary")
        with self.assertRaisesRegex(ValueError, "Bundle build/version/executable"):
            evidence.snapshot(self.root, self.bundle, self.manifest)

    def test_report_from_other_build_excluded(self):
        report = self.root / "other-build.json"
        identity = dict(self.checkpoint["identity"], build="57")
        report.write_text(json.dumps({"buildIdentity": identity, "status": "completed", "passed": 999}))
        result = self.check([report])
        self.assertEqual(result["attributedReports"], [])
        self.assertEqual(result["excludedReports"][0]["reason"], "different_execution_build_identity")

    def test_unbound_legacy_report_excluded(self):
        report = self.root / "ellipsis-pipeline-58.json"
        report.write_text(json.dumps({"status": "completed", "passed": 21}))
        self.assertEqual(self.check([report])["excludedReports"][0]["reason"], "missing_execution_build_identity")

    def test_identity_match_does_not_hide_failure(self):
        report = self.root / "failed.json"
        report.write_text(json.dumps({"buildIdentity": self.checkpoint["identity"], "status": "completed", "passed": 20, "failed": 1}))
        result = self.check([report])
        self.assertEqual(result["attributedReports"][0]["summary"]["failed"], 1)
        self.assertFalse(result["runtimeSuccessClaimed"])

    def test_inventory_digest_tamper_rejected(self):
        self.checkpoint["bundleFiles"]["Contents/Resources/dictionary.txt"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "Checkpoint inventory digest"):
            self.check()

    def test_symlink_rejected(self):
        (self.bundle / "Contents/Resources/link").symlink_to(self.resource)
        with self.assertRaisesRegex(ValueError, "Symlink"):
            self.check()


if __name__ == "__main__":
    unittest.main()
