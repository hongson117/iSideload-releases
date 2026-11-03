"""Generate isolated SIContainer + SIContainerRunner1 targets (Step 1: 1 Main + 1 Helper)."""
from pathlib import Path
import copy
import json
import plistlib
import re
import yaml

root = Path(__file__).resolve().parents[1]
base = yaml.safe_load((root / "project.yml").read_text(encoding="utf-8"))
spec_path = root / "project-sicontainer.yml"
if spec_path.exists():
    variant = yaml.safe_load(spec_path.read_text(encoding="utf-8"))
    version = str(
        variant.get("targets", {})
        .get("SIContainer", {})
        .get("settings", {})
        .get("base", {})
        .get("MARKETING_VERSION", "0.1.0")
    )
else:
    version = "0.1.0"

if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
    raise ValueError("Invalid SIContainer marketing version")

GUEST_PRIVACY_DESCRIPTIONS = {
    "NSLocalNetworkUsageDescription": "SIContainer dùng mạng cục bộ để kết nối, ghép nối thiết bị và hỗ trợ ứng dụng bên trong.",
    "NSPhotoLibraryUsageDescription": "Cho phép ứng dụng bên trong SIContainer truy cập Thư viện ảnh khi bạn sử dụng.",
    "NSPhotoLibraryAddUsageDescription": "Cho phép ứng dụng bên trong SIContainer lưu ảnh vào Thư viện ảnh.",
    "NSCameraUsageDescription": "Cho phép ứng dụng bên trong SIContainer sử dụng Camera khi bạn yêu cầu.",
    "NSMicrophoneUsageDescription": "Cho phép ứng dụng bên trong SIContainer sử dụng Micro khi bạn yêu cầu.",
    "NSCalendarsUsageDescription": "Cho phép ứng dụng bên trong SIContainer truy cập Lịch.",
    "NSRemindersUsageDescription": "Cho phép ứng dụng bên trong SIContainer truy cập Lời nhắc.",
    "NSContactsUsageDescription": "Cho phép ứng dụng bên trong SIContainer truy cập Danh bạ.",
    "NSLocationWhenInUseUsageDescription": "Cho phép ứng dụng bên trong SIContainer truy cập Vị trí khi đang dùng ứng dụng.",
    "NSFaceIDUsageDescription": "Cho phép ứng dụng bên trong SIContainer xác thực bằng Face ID.",
    "NSBluetoothAlwaysUsageDescription": "Cho phép ứng dụng bên trong SIContainer kết nối Bluetooth.",
}

main_target = copy.deepcopy(base["targets"]["iSideload"])
main_target["sources"].append({
    "path": "ios/iContainer",
    "excludes": ["*.plist"],
})
main_target["settings"]["base"].update({
    "PRODUCT_BUNDLE_IDENTIFIER": "com.hongson117.sicontainer",
    "PRODUCT_NAME": "SIContainer",
    "INFOPLIST_FILE": "ios/iContainer/Info.plist",
    "SWIFT_OBJC_BRIDGING_HEADER": "ios/iContainer/BridgingHeader.h",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "$(inherited) ICONTAINER SICONTAINER",
    "MARKETING_VERSION": version,
    "CLANG_ENABLE_OBJC_ARC": "YES",
})

runner1_target = copy.deepcopy(base["targets"]["iSideload"])
runner1_target["sources"] = [
    {"path": "ios/iSideload/Resources"},
    {"path": "ios/iContainer", "excludes": ["*.plist"]},
]
runner1_target["settings"]["base"].update({
    "PRODUCT_BUNDLE_IDENTIFIER": "com.hongson117.sicontainer.runner1",
    "PRODUCT_NAME": "SIContainerRunner1",
    "INFOPLIST_FILE": "ios/iContainer/Runner1-Info.plist",
    "SWIFT_OBJC_BRIDGING_HEADER": "ios/iContainer/BridgingHeader.h",
    "HEADER_SEARCH_PATHS": "$(SRCROOT)/core/include",
    "LIBRARY_SEARCH_PATHS": "",
    "OTHER_LDFLAGS": "-framework Security -framework SystemConfiguration -framework CoreFoundation -framework UIKit -framework Foundation",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "$(inherited) ICONTAINER SICONTAINER SICONTAINER_RUNNER",
    "MARKETING_VERSION": version,
    "CLANG_ENABLE_OBJC_ARC": "YES",
})

project = {
    "name": "SIContainer",
    "options": base["options"],
    "settings": base["settings"],
    "targets": {
        "SIContainer": main_target,
        "SIContainerRunner1": runner1_target,
    },
}
spec_path.write_text(yaml.safe_dump(project, sort_keys=False), encoding="utf-8")

# Also keep project-icontainer.yml synchronized so legacy scripts or CI steps work seamlessly
(root / "project-icontainer.yml").write_text(yaml.safe_dump(project, sort_keys=False), encoding="utf-8")

info = plistlib.loads((root / "ios/Info.plist").read_bytes())
info["CFBundleDisplayName"] = "SIContainer"
info["CFBundleURLTypes"] = [{"CFBundleURLSchemes": ["sicontainer", "icontainer"]}]
info["LSApplicationQueriesSchemes"] = [
    "sicontainer-runner1",
    "sicontainer-runner2",
    "localdevvpn",
    "livecontainer",
]
info["BGTaskSchedulerPermittedIdentifiers"] = [
    "com.hongson117.sicontainer.refresh",
    "com.hongson117.sicontainer.resign",
]
info.update(GUEST_PRIVACY_DESCRIPTIONS)
(root / "ios/iContainer/Info.plist").write_bytes(plistlib.dumps(info))

runner1_info = plistlib.loads((root / "ios/Info.plist").read_bytes())
runner1_info["CFBundleDisplayName"] = "SIContainer Phụ 1"
runner1_info["CFBundleURLTypes"] = [{"CFBundleURLSchemes": ["sicontainer-runner1"]}]
runner1_info["LSApplicationQueriesSchemes"] = ["sicontainer", "icontainer"]
for unused_key in (
    "BGTaskSchedulerPermittedIdentifiers",
    "UIBackgroundModes",
    "CFBundleDocumentTypes",
    "UTImportedTypeDeclarations",
    "NSBonjourServices",
):
    runner1_info.pop(unused_key, None)
runner1_info["UIFileSharingEnabled"] = False
runner1_info.update(GUEST_PRIVACY_DESCRIPTIONS)
(root / "ios/iContainer/Runner1-Info.plist").write_bytes(plistlib.dumps(runner1_info))

(root / "ios/iContainer/BridgingHeader.h").write_text(
    '#import "isideload.h"\n#import "ICRuntime.h"\n',
    encoding="utf-8",
)
print(
    json.dumps({
        "targets": {
            "SIContainer": "com.hongson117.sicontainer",
            "SIContainerRunner1": "com.hongson117.sicontainer.runner1",
        },
        "version": version,
        "source": "project-sicontainer.yml",
    })
)
