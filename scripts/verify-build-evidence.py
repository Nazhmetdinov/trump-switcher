#!/usr/bin/env python3
"""File-only build/report attribution. No app, subprocess, UI or network calls.

snapshot emits a post-build filesystem checkpoint to stdout. It does NOT prove
which sources a compiler used. Capture inputs before a future build and require
the same inputs afterwards to make that stronger claim.

verify checks the complete checkpoint and admits a report only when its
buildIdentity exactly matches. Legacy/unbound reports are excluded, not inferred
from their filenames. A matching identity does not turn a failed test or sender
event count into editor-correctness evidence. The producing test runner must
capture this identity at execution time; do not retrofit old reports.
"""

import argparse
import datetime
import hashlib
import json
import pathlib
import plistlib
import sys


SCHEMA = "trumpswitcher.build-evidence.v1"
SOURCE_ROOTS = ("Sources", "Assets", "scripts", "Package.swift", "THIRD_PARTY.md")


def digest(path):
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def relative_file(root, name):
    relative = pathlib.PurePosixPath(name)
    if relative.is_absolute() or ".." in relative.parts or not relative.parts:
        raise ValueError("Unsafe relative path: " + name)
    path = root.joinpath(*relative.parts)
    for candidate in (path, *path.parents):
        if candidate == root:
            break
        if candidate.is_symlink():
            raise ValueError("Symlink is not accepted: " + name)
    if not path.is_file():
        raise ValueError("Missing regular file: " + name)
    return path


def inventory(root, names=None):
    if root.is_symlink() or not root.is_dir():
        raise ValueError("Expected a real directory: " + str(root))
    files = {}
    for name in names if names is not None else (".",):
        start = root / name
        if not start.exists():
            raise ValueError("Missing inventory root: " + name)
        paths = [start, *sorted(start.rglob("*"))] if start.is_dir() else [start]
        for path in paths:
            if path.is_symlink():
                raise ValueError("Symlink is not accepted: " + str(path.relative_to(root)))
            if path.is_dir():
                continue
            if not path.is_file():
                raise ValueError("Non-regular file is not accepted")
            files[path.relative_to(root).as_posix()] = digest(path)
    return dict(sorted(files.items()))


def tree_digest(files):
    data = json.dumps(files, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(data).hexdigest()


def bundle_identity(bundle):
    info = plistlib.loads(relative_file(bundle, "Contents/Info.plist").read_bytes())
    executable = info["CFBundleExecutable"]
    if not isinstance(executable, str) or "/" in executable or executable in (".", ".."):
        raise ValueError("Invalid CFBundleExecutable")
    return {
        "version": str(info["CFBundleShortVersionString"]),
        "build": str(info["CFBundleVersion"]),
        "executableSHA256": digest(relative_file(bundle, "Contents/MacOS/" + executable)),
    }


def snapshot(repo, bundle, manifest_path):
    manifest_hash = digest(manifest_path)
    manifest = read_json(manifest_path)
    identity = bundle_identity(bundle)
    expected = {"version": str(manifest["version"]), "build": str(manifest["build"]),
                "executableSHA256": manifest["packagedSHA256"]}
    if identity != expected:
        raise ValueError("Bundle build/version/executable differs from release manifest")
    for name, expected_hash in manifest["sourceSHA256"].items():
        if digest(relative_file(repo, name)) != expected_hash:
            raise ValueError("Release source mismatch: " + name)
    checks = manifest["checks"]
    if digest(relative_file(repo, checks["buildLog"])) != checks["buildLogSHA256"]:
        raise ValueError("Build log differs from release manifest")
    bundle_files = inventory(bundle)
    source_files = inventory(repo, SOURCE_ROOTS)
    # Another task may be building in the shared workspace. Do not combine an
    # earlier manifest identity with files which changed during this snapshot.
    if digest(manifest_path) != manifest_hash or bundle_identity(bundle) != expected:
        raise ValueError("Manifest or binary changed during snapshot")
    for name, expected_hash in manifest["sourceSHA256"].items():
        if digest(relative_file(repo, name)) != expected_hash or (
                name in source_files and source_files[name] != expected_hash):
            raise ValueError("Release source changed during snapshot: " + name)
    if digest(relative_file(repo, checks["buildLog"])) != checks["buildLogSHA256"]:
        raise ValueError("Build log changed during snapshot")
    executable = plistlib.loads(relative_file(bundle, "Contents/Info.plist").read_bytes())["CFBundleExecutable"]
    if bundle_files["Contents/MacOS/" + executable] != expected["executableSHA256"]:
        raise ValueError("Binary changed during bundle inventory")
    identity.update(bundleTreeSHA256=tree_digest(bundle_files), sourceTreeSHA256=tree_digest(source_files))
    return {
        "schema": SCHEMA,
        "recordedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "scope": "Post-build filesystem checkpoint; not compiler attestation or runtime validation.",
        "releaseManifestSHA256": manifest_hash,
        "identity": identity,
        "bundleFiles": bundle_files,
        "sourceFiles": source_files,
    }


def differences(expected, actual):
    return {
        "missing": sorted(expected.keys() - actual.keys()),
        "added": sorted(actual.keys() - expected.keys()),
        "changed": sorted(k for k in expected.keys() & actual.keys() if expected[k] != actual[k]),
    }


def verify(checkpoint, repo, bundle, reports=()):
    if checkpoint.get("schema") != SCHEMA:
        raise ValueError("Unsupported checkpoint schema")
    identity = checkpoint["identity"]
    for kind in ("bundle", "source"):
        if tree_digest(checkpoint[kind + "Files"]) != identity[kind + "TreeSHA256"]:
            raise ValueError("Checkpoint inventory digest mismatch: " + kind)
    bundle_files = inventory(bundle)
    source_files = inventory(repo, SOURCE_ROOTS)
    current = bundle_identity(bundle)
    current.update(bundleTreeSHA256=tree_digest(bundle_files), sourceTreeSHA256=tree_digest(source_files))
    attributed, excluded = [], []
    for path in reports:
        entry = {"path": str(path), "sha256": digest(path)}
        try:
            report = read_json(path)
        except (ValueError, UnicodeError):
            excluded.append({**entry, "reason": "invalid_json"})
            continue
        if not isinstance(report, dict) or not isinstance(report.get("buildIdentity"), dict):
            excluded.append({**entry, "reason": "missing_execution_build_identity"})
        elif report["buildIdentity"] != identity:
            excluded.append({**entry, "reason": "different_execution_build_identity"})
        else:
            attributed.append({**entry, "summary": {key: report.get(key) for key in
                               ("status", "planned", "completed", "passed", "failed")}})
    return {
        "scope": "File integrity and report attribution only; no runtime-success claim.",
        "identity": identity,
        "filesVerified": current == identity,
        "bundleDifferences": differences(checkpoint["bundleFiles"], bundle_files),
        "sourceDifferences": differences(checkpoint["sourceFiles"], source_files),
        "attributedReports": attributed,
        "excludedReports": excluded,
        "runtimeSuccessClaimed": False,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("snapshot", "verify"))
    parser.add_argument("--repo", type=pathlib.Path, required=True)
    parser.add_argument("--bundle", type=pathlib.Path, required=True)
    parser.add_argument("--manifest", type=pathlib.Path, help="Release manifest for snapshot")
    parser.add_argument("--checkpoint", type=pathlib.Path, help="Immutable snapshot JSON for verify")
    parser.add_argument("--report", type=pathlib.Path, action="append", default=[])
    args = parser.parse_args()
    try:
        if args.mode == "snapshot":
            if args.manifest is None or args.checkpoint is not None or args.report:
                parser.error("snapshot requires --manifest only")
            result = snapshot(args.repo, args.bundle, args.manifest)
            okay = True
        else:
            if args.checkpoint is None or args.manifest is not None:
                parser.error("verify requires --checkpoint, optionally --report")
            result = verify(read_json(args.checkpoint), args.repo, args.bundle, args.report)
            okay = result["filesVerified"] and not result["excludedReports"]
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0 if okay else 1
    except (OSError, ValueError, KeyError, TypeError, plistlib.InvalidFileException) as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False))
        return 2


if __name__ == "__main__":
    sys.exit(main())
