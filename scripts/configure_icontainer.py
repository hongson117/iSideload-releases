"""Generate an isolated iContainer target; never changes the stable checkout."""
from pathlib import Path
import copy
import json
import plistlib
import yaml

root=Path(__file__).resolve().parents[1]
base=yaml.safe_load((root/'project.yml').read_text(encoding='utf-8'))
target=copy.deepcopy(base['targets']['iSideload'])
target['sources'].append({'path':'ios/iContainer'})
target['settings']['base'].update({
    'PRODUCT_BUNDLE_IDENTIFIER':'com.hongson117.icontainer',
    'PRODUCT_NAME':'iContainer',
    'INFOPLIST_FILE':'ios/iContainer/Info.plist',
    'SWIFT_OBJC_BRIDGING_HEADER':'ios/iContainer/BridgingHeader.h',
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS':'$(inherited) ICONTAINER',
    'MARKETING_VERSION':'0.1.1',
    'CLANG_ENABLE_OBJC_ARC':'YES',
})
project={'name':'iContainer','options':base['options'],'settings':base['settings'],'targets':{'iContainer':target}}
(root/'project-icontainer.yml').write_text(yaml.safe_dump(project,sort_keys=False),encoding='utf-8')
info=plistlib.loads((root/'ios/Info.plist').read_bytes())
info['CFBundleDisplayName']='iContainer'
info['CFBundleURLTypes']=[{'CFBundleURLSchemes':['icontainer']}]
info['NSLocalNetworkUsageDescription']='iContainer dùng mạng cục bộ để kết nối và ghép nối thiết bị.'
info['BGTaskSchedulerPermittedIdentifiers']=['com.hongson117.icontainer.refresh','com.hongson117.icontainer.resign']
(root/'ios/iContainer/Info.plist').write_bytes(plistlib.dumps(info))
(root/'ios/iContainer/BridgingHeader.h').write_text('#import "isideload.h"\n#import "ICRuntime.h"\n',encoding='utf-8')
print(json.dumps({'target':'iContainer','bundle_id':'com.hongson117.icontainer','version':'0.1.1','source':'project-icontainer.yml'}))
