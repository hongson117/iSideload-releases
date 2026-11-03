"""Publish audited unsigned iContainer code; never accepts user signing data."""
import base64,hashlib,json,os,pathlib,subprocess,sys,urllib.request,zipfile,plistlib
repo=os.environ['GITHUB_REPOSITORY']
assert repo=='hongson117/iSideload-releases'
root=pathlib.Path(sys.argv[1]);ipa=root/'iContainer.ipa'
def command(*args):
    result=subprocess.run(args,capture_output=True,text=True)
    if result.returncode:raise RuntimeError(result.stderr)
    return result.stdout.strip()
meta=json.loads((root/'BUILD-SOURCE.json').read_text())
audit=json.loads((root/'recipient-audit.json').read_text());assert audit['passed'] and not audit['failures']
sha=hashlib.sha256(ipa.read_bytes()).hexdigest();assert sha in (root/'SHA256SUMS.txt').read_text()
with zipfile.ZipFile(ipa) as z:
    info=plistlib.loads(z.read(next(n for n in z.namelist() if n.count('/')==2 and n.endswith('.app/Info.plist'))))
assert info['CFBundleIdentifier']=='com.hongson117.icontainer'
assert info['CFBundleShortVersionString']==meta['version'] and str(info['CFBundleVersion'])==meta['build']
assert info['ISLGitSHA']==meta['source_commit'][:7]
tag=f"icontainer-v{meta['version']}-b{meta['build']}"
notes=root/'release-notes.md'
notes.write_text(f"""iContainer {meta['version']} · build {meta['build']}

- Sửa duplicate LC_RPATH khi mở app trong Container; bản chạy cũ cần Chuẩn bị lại, giữ app gốc và dữ liệu.
- Kiểm tra/tải/ký và cập nhật phiên bản trong app, giữ đúng App ID/Team của bản Cá nhân.
- Có quản lý chứng chỉ theo tài khoản; tác vụ trong app vẫn cho chọn chứng chỉ sau khi quay về từ VPN.

IPA chưa ký. Mã nguồn được giữ private. Bản thử: sửa lỗi nạp không bảo đảm mọi IPA đều chạy được trong cùng tiến trình. Chỉ dùng IPA tin cậy.
""",encoding='utf-8')
assets=[ipa,root/'SHA256SUMS.txt',root/'ThirdPartyNotices.txt',root/'BUILD-SOURCE.json']
exists=subprocess.run(['gh','release','view',tag,'--repo',repo],capture_output=True).returncode==0
if not exists:
    command('gh','release','create',tag,*map(str,assets),'--repo',repo,'--prerelease','--title',f"iContainer {meta['version']} build {meta['build']}",'--notes-file',str(notes))
url=f'https://github.com/{repo}/releases/download/{tag}/iContainer.ipa'
with urllib.request.urlopen(url,timeout=120) as response:assert hashlib.file_digest(response,'sha256').hexdigest()==sha
# A lower build from a rerun must not replace a newer published update.
def order(entry):return tuple(int(n) for n in entry['version'].split('.'))+(int(entry['build']),)
for attempt in range(3):
    current=json.loads(command('gh','api',f'repos/{repo}/contents/app-updates.json'))
    manifest=json.loads(base64.b64decode(current['content']))
    entry={'version':meta['version'],'build':meta['build'],'url':url,'sha256':sha,'bytes':ipa.stat().st_size}
    old=manifest['apps'].get('icontainer')
    if old and order(old)>order(entry):break
    if old==entry:break
    manifest['apps']['icontainer']=entry
    content=(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n').encode()
    request=root/'feed-request.json';request.write_text(json.dumps({'message':f"Publish iContainer {meta['version']} build {meta['build']} update",'sha':current['sha'],'content':base64.b64encode(content).decode()}))
    result=subprocess.run(['gh','api','--method','PUT',f'repos/{repo}/contents/app-updates.json','--input',str(request)],capture_output=True,text=True)
    if result.returncode==0:break
else:raise RuntimeError('Release uploaded but update feed requires retry')
print(json.dumps({'published':True,'ipa':url,'sha256':sha}))
