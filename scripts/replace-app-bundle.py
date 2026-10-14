#!/usr/bin/env python3
"""Stage a complete signed app, replace it without old files, restore on failure."""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile


def replace_bundle(source, destination, copy, verify, before_commit=lambda: None):
    source, destination = Path(source), Path(destination)
    if destination.is_symlink():
        raise ValueError("Refusing to replace an application symlink")
    stage = Path(tempfile.mkdtemp(prefix=".TrumpSwitcher-update-", dir=destination.parent))
    new, previous = stage / "Trump Switcher.app", stage / "Previous.app"
    new_installed = False
    committed = False
    try:
        copy(source, new)
        verify(new)
        before_commit()
        if destination.exists():
            os.rename(destination, previous)
        os.rename(new, destination)
        new_installed = True
        verify(destination)
        committed = True
    except BaseException:
        # Preserve the full previous inode tree, including its signature.
        if previous.exists():
            if destination.exists():
                os.rename(destination, stage / "Rejected.app")
            os.rename(previous, destination)
        elif new_installed:
            os.rename(destination, stage / "Rejected.app")
        raise
    finally:
        if previous.exists() and not committed:
            # A rollback itself failed. Never delete the recoverable old app.
            print("Previous app preserved for recovery: " + str(previous), file=sys.stderr)
        else:
            shutil.rmtree(stage)


def main():
    if len(sys.argv) != 3:
        raise SystemExit("Usage: replace-app-bundle.py SOURCE DESTINATION")
    def copy(source, dest):
        subprocess.run(["/usr/bin/ditto", str(source), str(dest)], check=True)
    def verify(path):
        subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(path)], check=True)
    def stopped():
        if subprocess.run(["/usr/bin/pgrep", "-x", "TrumpSwitcher"], stdout=subprocess.DEVNULL).returncode == 0:
            raise RuntimeError("Quit Trump Switcher before installing an update")
    replace_bundle(sys.argv[1], sys.argv[2], copy, verify, stopped)


if __name__ == "__main__":
    main()
