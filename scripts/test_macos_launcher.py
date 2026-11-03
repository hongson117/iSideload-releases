"""Exercise launcher dispatch/cancellation/integrity without a phone or Apple account."""
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile

source = Path(__file__).resolve().parents[1] / "macos/Cai-iSideload.command"
with tempfile.TemporaryDirectory(prefix="iSideload Mac kiểm thử ") as temporary:
    root = Path(temporary)
    shutil.copy2(source, root / source.name)
    stub = root / "isl-mac"
    stub.write_text('#!/bin/bash\nprintf "CLI_CALL:%s\\n" "$*"\n', encoding="utf-8")
    stub.chmod(0o755)
    (root / "iSideload.ipa").write_bytes(b"launcher fixture only")
    rows = [hashlib.sha256((root / n).read_bytes()).hexdigest() + "  " + n
            for n in ["isl-mac", "iSideload.ipa", source.name]]
    (root / "SHA256SUMS.txt").write_text("\n".join(rows) + "\n", encoding="utf-8")

    def launch(input):
        return subprocess.run(["/bin/bash", str(root / source.name)], input=input,
                              capture_output=True, text=True, timeout=15)

    result = launch("1\n\n")
    assert result.returncode == 0 and "CLI_CALL:./iSideload.ipa" in result.stdout, result.stdout + result.stderr
    result = launch("2\n\n")
    assert result.returncode == 0 and "CLI_CALL:--pair-only" in result.stdout, result.stdout + result.stderr
    for input in ["0\n", "\n", ""]:
        result = launch(input)
        assert result.returncode == 1 and "CLI_CALL:" not in result.stdout, result.stdout + result.stderr
    (root / "iSideload.ipa").write_bytes(b"modified")
    result = launch("\n")
    assert result.returncode == 2 and "CLI_CALL:" not in result.stdout, result.stdout + result.stderr
print("Launcher checks passed: install/repair dispatch, invalid/empty/EOF cancellation, corrupted package blocked, Unicode/space paths")
