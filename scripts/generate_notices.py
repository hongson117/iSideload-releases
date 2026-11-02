"""Bundle dependency license/notice documents from Cargo's resolved metadata."""
import json
from pathlib import Path
import subprocess

metadata = json.loads(subprocess.check_output([
    "cargo", "metadata", "--locked", "--format-version", "1",
    "--manifest-path", "core/Cargo.toml", "--filter-platform", "aarch64-apple-ios",
], text=True))
parts = ["iSideload - Third-party software notices\n\n"
         "The following open-source components retain their respective copyrights and licenses.\n"
         "This file contains attribution and license texts, not application source code.\n"]
for package in sorted(metadata["packages"], key=lambda item: (item["name"], item["version"])):
    root = Path(package["manifest_path"]).parent
    documents = []
    for path in root.iterdir():
        if path.is_file() and path.name.upper().startswith(("LICENSE", "LICENCE", "COPYING", "NOTICE")):
            documents.append(path)
    if package.get("license_file"):
        specified = Path(package["license_file"])
        if not specified.is_absolute():
            specified = root / specified
        if specified.is_file() and specified not in documents:
            documents.append(specified)
    parts.append("\n" + "=" * 72 + "\n" + package["name"] + " " + package["version"] + "\n"
                 + "License: " + (package.get("license") or "See upstream license") + "\n"
                 + "Project: " + (package.get("repository") or package.get("homepage") or "") + "\n")
    for document in sorted(documents):
        if document.stat().st_size <= 2_000_000:
            parts.append("\n" + document.name + "\n" + document.read_text(encoding="utf-8", errors="replace") + "\n")
output = Path("ios/iSideload/Resources/ThirdPartyNotices.txt")
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text("".join(parts), encoding="utf-8")
print(f"Bundled notices for {len(metadata['packages'])} resolved packages ({output.stat().st_size} bytes)")
