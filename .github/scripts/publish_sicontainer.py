"""Publish audited unsigned SIContainer + SIContainerRunner1 code; never accepts user signing data."""
import base64, hashlib, json, os, pathlib, subprocess, sys, urllib.request, zipfile, plistlib

repo = os.environ["GITHUB_REPOSITORY"]
assert repo == "hongson117/iSideload-releases"
root = pathlib.Path(sys.argv[1])
ipa = root / "SIContainer.ipa"
r1_ipa = root / "SIContainerRunner1.ipa"


def command(*args):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stderr)
    return result.stdout.strip()


meta = json.loads((root / "BUILD-SOURCE.json").read_text())
audit = json.loads((root / "recipient-audit.json").read_text())
assert audit["passed"] and not audit["failures"]
r1_audit = json.loads((root / "runner1-audit.json").read_text())
assert r1_audit["passed"] and not r1_audit["failures"]

sha = hashlib.sha256(ipa.read_bytes()).hexdigest()
r1_sha = hashlib.sha256(r1_ipa.read_bytes()).hexdigest()
sums = (root / "SHA256SUMS.txt").read_text()
assert sha in sums and r1_sha in sums

with zipfile.ZipFile(ipa) as z:
    info = plistlib.loads(z.read(next(n for n in z.namelist() if n.count("/") == 2 and n.endswith(".app/Info.plist"))))
assert info["CFBundleIdentifier"] == "com.hongson117.sicontainer"
assert info["CFBundleShortVersionString"] == meta["version"] and str(info["CFBundleVersion"]) == meta["build"]
assert info["ISLGitSHA"] == meta["source_commit"][:7]

with zipfile.ZipFile(r1_ipa) as z:
    r1_info = plistlib.loads(z.read(next(n for n in z.namelist() if n.count("/") == 2 and n.endswith(".app/Info.plist"))))
assert r1_info["CFBundleIdentifier"] == "com.hongson117.sicontainer.runner1"
assert r1_info["CFBundleShortVersionString"] == meta["version"] and str(r1_info["CFBundleVersion"]) == meta["build"]
assert r1_info["ISLGitSHA"] == meta["source_commit"][:7]

tag = f"sicontainer-v{meta['version']}-b{meta['build']}"
notes = root / "release-notes.md"
notes.write_text(
    f"""SIContainer {meta['version']} · build {meta['build']} (Bước 1: 1 Chính + 1 Phụ)

- Kiến trúc tách biệt Con Chính (`SIContainer`) chuyên quản lý/ký/điều phối URL và Con Phụ 1 (`SIContainer Phụ 1`) chạy ứng dụng khách độc lập.
- Dữ liệu người dùng dùng chung qua App Group (`group.com.hongson117.sicontainer.<TEAM_ID>`), trong khi mỗi Slot có bản `Prepared/<slot_bundle_id>/Prepared.app` ký DER/XML riêng cho đúng Bundle ID của Slot đó.
- Cấp phát Slot theo giao dịch kèm khóa hạt nhân `flock()` (`runner1.alive.lock`, `.writer.lock`) và thu hồi lịch sự qua Darwin Notification.
- Tích hợp tạo Shortcut Màn hình chính iOS (WebClip `.mobileconfig` không viền và Safari Standalone).

IPA chưa ký (`SIContainer.ipa` đã kèm sẵn `SIContainerRunner1.ipa` bên trong để cài nhanh trên máy, đồng thời phát hành rời `SIContainerRunner1.ipa`).
""",
    encoding="utf-8",
)
assets = [
    ipa,
    r1_ipa,
    root / "SHA256SUMS.txt",
    root / "ThirdPartyNotices.txt",
    root / "BUILD-SOURCE.json",
    root / "recipient-audit.json",
    root / "runner1-audit.json",
]
exists = subprocess.run(["gh", "release", "view", tag, "--repo", repo], capture_output=True).returncode == 0
if not exists:
    command(
        "gh",
        "release",
        "create",
        tag,
        *map(str, assets),
        "--repo",
        repo,
        "--prerelease",
        "--title",
        f"SIContainer {meta['version']} build {meta['build']}",
        "--notes-file",
        str(notes),
    )
url = f"https://github.com/{repo}/releases/download/{tag}/SIContainer.ipa"
r1_url = f"https://github.com/{repo}/releases/download/{tag}/SIContainerRunner1.ipa"
with urllib.request.urlopen(url, timeout=120) as response:
    assert hashlib.file_digest(response, "sha256").hexdigest() == sha
with urllib.request.urlopen(r1_url, timeout=120) as response:
    assert hashlib.file_digest(response, "sha256").hexdigest() == r1_sha


def order(entry):
    return tuple(int(n) for n in entry["version"].split(".")) + (int(entry["build"]),)


for attempt in range(3):
    current = json.loads(command("gh", "api", f"repos/{repo}/contents/app-updates.json"))
    manifest = json.loads(base64.b64decode(current["content"]))
    entry = {"version": meta["version"], "build": meta["build"], "url": url, "sha256": sha, "bytes": ipa.stat().st_size}
    old = manifest["apps"].get("sicontainer")
    if old and order(old) > order(entry):
        break
    if old == entry:
        break
    manifest["apps"]["sicontainer"] = entry
    content = (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode()
    request = root / "feed-request.json"
    request.write_text(
        json.dumps(
            {
                "message": f"Publish SIContainer {meta['version']} build {meta['build']} update",
                "sha": current["sha"],
                "content": base64.b64encode(content).decode(),
            }
        )
    )
    result = subprocess.run(
        ["gh", "api", "--method", "PUT", f"repos/{repo}/contents/app-updates.json", "--input", str(request)],
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        break
else:
    raise RuntimeError("Release uploaded but update feed requires retry")

print(json.dumps({"published": True, "ipa": url, "sha256": sha, "runner1_ipa": r1_url, "runner1_sha256": r1_sha}))
