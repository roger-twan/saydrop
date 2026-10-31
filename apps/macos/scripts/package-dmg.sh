#!/bin/bash
# Local test packaging only. No installation, launch, signing or notarization.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
APP="${1:-$ROOT/.work/capture-hotkeys-20261026/xcode-build/Build/Products/Debug/Saydrop.app}"
OUT="${2:-$ROOT/outputs/macos-local-test}"
NOTES="${3:-$ROOT/outputs/macos-local-test/Local-installation-test-guide.md}"
WORK="$ROOT/.work/dmg-local-test-20261026"
[[ -d "$APP" && -f "$NOTES" ]] || { echo 'A complete Saydrop.app and local test guide are required.' >&2; exit 1; }
mkdir -p "$WORK" "$OUT"
STAGE="$(mktemp -d "$WORK/stage.XXXXXX")"
MOUNT="$(mktemp -d "$WORK/mount.XXXXXX")"
TEMP="$(mktemp -d "$WORK/image.XXXXXX")"
cleanup() { hdiutil detach "$MOUNT" >/dev/null 2>&1 || true; }
trap cleanup EXIT

python3 - "$APP" "$ROOT" "$WORK/source-manifest.json" <<'PY'
import hashlib, json, pathlib, plistlib, re, subprocess, sys
app, root, output = map(pathlib.Path, sys.argv[1:])
info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier'] == 'local.saydrop.dev', 'Only the confirmed development bundle is permitted.'
assert info['CFBundleName'] == 'Saydrop'
assert info['LSMinimumSystemVersion'] == '14.0'
assert info['SaydropBackendURL'] == 'http://127.0.0.1:8000'
assert info['LSUIElement'] is True
assert re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', info['CFBundleShortVersionString'])
keys = ['SaydropCloudDisclosureVersion','SaydropCloudReceiver','SaydropCloudPurpose','SaydropCloudRetention']
assert not all(str(info.get(k,'')).strip() for k in keys), 'This local test recipe expects cloud uploading to remain disabled.'
assert (app/'Contents/Resources/Saydrop.icns').is_file()
assert (app/'Contents/Resources/KeyboardShortcuts_KeyboardShortcuts.bundle/Contents/Info.plist').is_file()
exe = app/'Contents/MacOS/Saydrop'
code = list((root/'apps/macos/SaydropApp').rglob('*.swift'))
code += list((root/'apps/macos/packages/SaydropCore/Sources').rglob('*.swift'))
code += list((root/'apps/macos/packages/SaydropRealtime/Sources').rglob('*.[ch]'))
code += [root/'apps/macos/SaydropApp/Info-Debug.plist']
assert max(p.stat().st_mtime for p in code) <= exe.stat().st_mtime, 'Application is older than source; build before packaging.'
manifest = {'files': {}, 'symlinks': {}, 'mach_o': []}
for p in sorted(app.rglob('*')):
    relative = p.relative_to(app).as_posix()
    if p.is_symlink():
        manifest['symlinks'][relative] = str(p.readlink())
    elif p.is_file():
        data = p.read_bytes()
        manifest['files'][relative] = hashlib.sha256(data).hexdigest()
        if data[:4] in [b'\xcf\xfa\xed\xfe',b'\xfe\xed\xfa\xcf',b'\xca\xfe\xba\xbe',b'\xbe\xba\xfe\xca']:
            arch = subprocess.check_output(['/usr/bin/lipo','-archs',str(p)],text=True).strip()
            assert arch == 'arm64', (relative,arch)
            manifest['mach_o'].append(relative)
            deps = subprocess.check_output(['/usr/bin/otool','-L',str(p)],text=True)
            for line in deps.splitlines()[1:]:
                dep = line.strip().split(' (',1)[0]
                if dep.startswith('/'):
                    assert dep.startswith(('/usr/lib/','/System/Library/')), ('Non-system absolute dependency',dep)
                if dep.startswith('@rpath/Saydrop'):
                    assert (app/'Contents/MacOS'/dep.split('/')[-1]).is_file(), ('Missing bundled dylib',dep)
assert manifest['mach_o'], 'Missing executable'
output.write_text(json.dumps(manifest,ensure_ascii=False,indent=2))
print('Validated development metadata, source freshness, resources and all arm64 Mach-O files.')
PY

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
NAME="Saydrop-$VERSION-arm64.dmg"
ditto "$APP" "$STAGE/Saydrop.app"
ln -s /Applications "$STAGE/Applications"
cp "$NOTES" "$STAGE/Local-installation-test-guide.txt"
chmod 644 "$STAGE/Local-installation-test-guide.txt"

hdiutil create -srcfolder "$STAGE" -volname "Saydrop $VERSION Local Test" -fs HFS+ -format UDZO -ov "$TEMP/$NAME" > "$WORK/create.log" 2>&1
hdiutil verify "$TEMP/$NAME" > "$WORK/verify.log" 2>&1
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT" -plist "$TEMP/$NAME" > "$WORK/attach.plist" 2> "$WORK/attach.log"

python3 - "$MOUNT" "$WORK/source-manifest.json" "$NOTES" <<'PY'
import hashlib, json, pathlib, sys
mount, record, notes = map(pathlib.Path, sys.argv[1:])
app = mount/'Saydrop.app'
source = json.loads(record.read_text())
files, symlinks = {}, {}
for p in sorted(app.rglob('*')):
    relative = p.relative_to(app).as_posix()
    if p.is_symlink(): symlinks[relative] = str(p.readlink())
    elif p.is_file(): files[relative] = hashlib.sha256(p.read_bytes()).hexdigest()
assert files == source['files'], 'Mounted app differs from built app.'
assert symlinks == source['symlinks'], 'Mounted bundle symlinks differ.'
assert (mount/'Applications').is_symlink()
assert str((mount/'Applications').readlink()) == '/Applications'
assert (mount/'Local-installation-test-guide.txt').read_bytes() == notes.read_bytes()
print('Read-only mount verified:', len(files), 'app files; app hashes, Applications shortcut and notes match.')
PY
hdiutil detach "$MOUNT" > "$WORK/detach.log" 2>&1
trap - EXIT
mv -f "$TEMP/$NAME" "$OUT/$NAME"
(cd "$OUT" && shasum -a 256 "$NAME" > SHA256SUMS.txt && shasum -a 256 -c SHA256SUMS.txt)
printf '\nVerified local test DMG: %s\n' "$OUT/$NAME"
printf 'This command did not install, launch, codesign or notarize Saydrop.\n'
