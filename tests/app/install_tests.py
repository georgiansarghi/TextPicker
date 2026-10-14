"""Exercise installation transactions in an isolated HOME; never launch/quit the real app."""

import os
import subprocess
import tempfile
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / ".build/apps/TextPicker.app"

with tempfile.TemporaryDirectory(prefix="textpicker-install-tests-") as temporary:
    temporary = Path(temporary)
    commands = temporary / "commands"
    commands.mkdir()
    scripts = {
        "pgrep": "exit 1\n",
        "open": '[ "$TEST_FAILURE" != launch ]\n',
        "cp": '[ "$TEST_FAILURE" != copy ] || exit 1\nexec /bin/cp "$@"\n',
        "codesign": """LAST="${!#}"
if [ "$TEST_FAILURE" = staged ] && [[ "$LAST" = "$HOME/Applications/.textpicker-install."*"/TextPicker.app" ]]; then exit 1; fi
if [ "$TEST_FAILURE" = postverify ] && [ "$LAST" = "$HOME/Applications/TextPicker.app" ]; then exit 1; fi
exec /usr/bin/codesign "$@"
""",
    }
    for name, script in scripts.items():
        path = commands / name
        path.write_text("#!/bin/bash\nset -eu\n" + script)
        path.chmod(0o700)
    for failure in ["copy", "staged", "postverify", "launch", "success", "legacy"]:
        home = temporary / (failure + " home")
        target = home / "Applications/TextPicker.app"
        (target / "Contents").mkdir(parents=True)
        info = (SOURCE / "Contents/Info.plist").read_bytes()
        if failure == "legacy":  # Upgrading a 0.11 install with the old identifier.
            info = info.replace(b"io.github.georgiansarghi.TextPicker", b"local.textpicker")
        (target / "Contents/Info.plist").write_bytes(info)
        (target / "checkpoint-marker").write_text("old installation")
        environment = dict(
            os.environ,
            HOME=str(home),
            TEST_FAILURE=failure,
            PATH=str(commands) + ":" + os.environ["PATH"],
        )
        result = subprocess.run(
            ["bash", ROOT / "scripts/install.sh", SOURCE],
            env=environment,
            capture_output=True,
            text=True,
            timeout=60,
        )
        succeeds = failure in ("success", "legacy")
        assert (result.returncode == 0) == succeeds, (
            failure,
            result.stdout,
            result.stderr,
        )
        assert not list((home / "Applications").glob("TextPicker.previous-*.app"))
        rollback = home / "Library/Application Support/TextPicker/Rollback/TextPicker.app"
        backups = [rollback] if rollback.exists() else []
        if succeeds:
            assert len(backups) == 1 and (backups[0] / "checkpoint-marker").exists()
            assert (target / "Contents/MacOS/TextPicker").is_file()
            assert (target / "Contents/MacOS/TextPickerNative").is_file()
        else:
            assert (target / "checkpoint-marker").read_text() == "old installation"
            assert not backups
        assert not list((home / "Applications").glob(".textpicker-install.*"))
        # Release APFS clones promptly rather than retaining five bundles.
        import shutil

        shutil.rmtree(home)
print(
    "PASS: 6 isolated install transactions (copy, staged/post-swap verification, launch failure, success, legacy upgrade)"
)
