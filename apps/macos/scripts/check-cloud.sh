#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
WORK="${SAYDROP_VALIDATION_DIR:-$ROOT/.work/client-validation}"
CACHE="${SAYDROP_BUILD_CACHE:-$ROOT/.work/build-cache}"
BUILD=0
for option in "$@"; do
  case "$option" in
    --build) BUILD=1 ;;
    --snapshots) export SAYDROP_PREVIEW_DIR="$WORK/previews" ;;
    *) echo 'Usage: bash apps/macos/scripts/check-cloud.sh [--snapshots] [--build]' >&2; exit 2 ;;
  esac
done
mkdir -p "$WORK" "$CACHE"/{tmp,module-cache,spm-cache,spm-config,spm-security}
export TMPDIR="$CACHE/tmp"
export CLANG_MODULE_CACHE_PATH="$CACHE/module-cache"
COMMON=(--disable-sandbox --cache-path "$CACHE/spm-cache" --config-path "$CACHE/spm-config" --security-path "$CACHE/spm-security")
for item in core realtime ui; do
  case "$item" in
    core) PACKAGE="$ROOT/apps/macos/packages/SaydropCore" ;;
    realtime) PACKAGE="$ROOT/apps/macos/packages/SaydropRealtime" ;;
    ui) PACKAGE="$ROOT/apps/macos" ;;
  esac
  swift test "${COMMON[@]}" --package-path "$PACKAGE" --scratch-path "$CACHE/$item-build" > "$WORK/$item-test.log" 2>&1 || { tail -100 "$WORK/$item-test.log"; exit 1; }
  tail -8 "$WORK/$item-test.log"
done
if [[ "$BUILD" == 1 ]]; then
  xcodebuild -project "$ROOT/apps/macos/Saydrop.xcodeproj" -scheme Saydrop -configuration Debug \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$CACHE/xcode-build" \
    -clonedSourcePackagesDirPath "$CACHE/xcode-packages" -disablePackageRepositoryCache -skipPackageUpdates \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build > "$WORK/xcode-build.log" 2>&1 || { tail -100 "$WORK/xcode-build.log"; exit 1; }
  tail -5 "$WORK/xcode-build.log"
  lipo -archs "$CACHE/xcode-build/Build/Products/Debug/Saydrop.app/Contents/MacOS/Saydrop"
fi
printf '\nValidation logs: %s\n' "$WORK"
