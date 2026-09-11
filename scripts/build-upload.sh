#!/bin/bash
# IPTV Wall build + sign + package (+upload) one-shot.
# Usage: APP_PASSWORD=<app-specific-password> scripts/build-upload.sh <ios|tvos|mac> <build> [--upload]
set -euo pipefail

PLATFORM="${1:?platform: ios|tvos|mac}"
BUILD="${2:?build number, e.g. 98}"
UPLOAD=0
[[ "${3:-}" == "--upload" ]] && UPLOAD=1

LOCAL_REPO="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE_HOST="$(printenv REMOTE_HOST || true)"
REMOTE_USER="$(printenv REMOTE_USER || true)"
SSH_PASS="$(printenv BUILD_SSH_PASSWORD || true)"
KEYCHAIN_PASSWORD="$(printenv BUILD_KEYCHAIN_PASSWORD || true)"
ASC_USERNAME="$(printenv ASC_USERNAME || true)"
APP_PASSWORD="$(printenv APP_PASSWORD || true)"
REMOTE_ROOT="/Users/$REMOTE_USER/IPTVWall"
REMOTE_BASE="$REMOTE_ROOT/tvOS"
[ -n "$REMOTE_HOST" ] || { echo "需要環境變數 REMOTE_HOST（build 機位址）" >&2; exit 1; }
[ -n "$REMOTE_USER" ] || { echo "需要環境變數 REMOTE_USER（build 機帳號）" >&2; exit 1; }
[ -n "$SSH_PASS" ] || { echo "需要環境變數 BUILD_SSH_PASSWORD" >&2; exit 1; }
[ -n "$KEYCHAIN_PASSWORD" ] || KEYCHAIN_PASSWORD="$SSH_PASS"
SSHOPTS="-o StrictHostKeyChecking=no -o IdentitiesOnly=yes -o PreferredAuthentications=password -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1"

case "$PLATFORM" in
  ios)   SCHEME="IPTVWallPad";       DEST="generic/platform=iOS";    PROV="38b16cce-32c7-4786-b026-970aa35197ce.mobileprovision"; ALT="-t ios";;
  tvos)  SCHEME="GlobalNewsWallTV";  DEST="generic/platform=tvOS";   PROV="104d6729-085e-4b85-9ba4-4037e63fff3c.mobileprovision"; ALT="-t appletvos";;
  mac)   SCHEME="IPTVWallMac";      DEST="platform=macOS";          PROV=""; ALT="";;
  *) echo "unknown platform $PLATFORM"; exit 1;;
esac

echo "==> 同步程式碼到 ${REMOTE_HOST}"
sshpass -p "$SSH_PASS" scp $SSHOPTS -r "$LOCAL_REPO/GlobalNewsWallTV" "$LOCAL_REPO/GlobalNewsWallTV.xcodeproj" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_BASE/"

DD="DerivedData-${PLATFORM}-${BUILD}"
REMOTE_CMD="export SCHEME='$SCHEME' DEST='$DEST' BUILD='$BUILD' DD='$DD' PROV='$PROV' PLATFORM='$PLATFORM' REMOTE_BASE='$REMOTE_BASE' REMOTE_ROOT='$REMOTE_ROOT' REMOTE_USER='$REMOTE_USER' KEYCHAIN_PASSWORD='$KEYCHAIN_PASSWORD' ASC_USERNAME='$ASC_USERNAME'; "
REMOTE_CMD+=$(cat <<'RHEOF'
set -euo pipefail
cd "$REMOTE_BASE"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" ~/Library/Keychains/login.keychain-db 2>/dev/null || true
echo "==> build ${SCHEME} ${BUILD} (unsigned)"
rm -rf "$REMOTE_ROOT/${DD}"
xcodebuild -scheme "$SCHEME" -destination "$DEST" -configuration Release \
  -derivedDataPath "$REMOTE_ROOT/${DD}" \
  CURRENT_PROJECT_VERSION="$BUILD" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build \
  | grep -E "BUILD (SUCCEEDED|FAILED)" | head -1
if [ "$PLATFORM" != "mac" ]; then
  APP=$(find "$REMOTE_ROOT/${DD}/Build/Products" -maxdepth 2 -name "*.app" -type d | head -1)
  echo "==> app: ${APP}"
  /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" -c "Print :CFBundleVersion" "${APP}/Info.plist"
  echo "==> 簽證 (Apple Distribution)"
  PROF="/Users/$REMOTE_USER/Library/MobileDevice/Provisioning Profiles/${PROV}"
  security cms -D -i "$PROF" > /tmp/entprof.plist 2>/dev/null
  plutil -extract Entitlements xml1 /tmp/entprof.plist -o /tmp/ent-raw.plist
python3 - <<"PYEOF"
import os, plistlib
p = plistlib.load(open("/tmp/ent-raw.plist","rb"))
platform = os.environ.get("PLATFORM", "")
# tvOS/iOS CloudKit rejects the array form ("malformed entitlements"); it wants a
# plain string "Production". Verified on-device: array crashes, string works.
p["com.apple.developer.icloud-container-environment"] = "Production"
p.pop("com.apple.developer.icloud-container-development-container-identifiers", None)
p["com.apple.developer.ubiquity-kvstore-identifier"] = "NZBLXS857E.com.neo99.IPTVWall"
if platform == "ios":
    p["com.apple.developer.icloud-services"] = ["CloudKit"]
if platform == "tvos":
    p.pop("com.apple.developer.user-management", None)
plistlib.dump(p, open("/tmp/ent-fixed.plist","wb"))
print("entitlements fixed for", platform)
PYEOF
  cp "$PROF" "${APP}/embedded.mobileprovision"
  codesign --force --sign "Apple Distribution: Ching-yuan yang (NZBLXS857E)" --entitlements /tmp/ent-fixed.plist "$APP"
  echo "==> 打包 ipa"
  rm -rf /tmp/pkg; mkdir -p /tmp/pkg/Payload
  cp -R "$APP" /tmp/pkg/Payload/
  cd /tmp/pkg
  IPA="$REMOTE_ROOT/IPTVWall-${PLATFORM}-1.3-${BUILD}.ipa"
  zip -qry "$IPA" Payload
  ls -la "$IPA"
else
  APP="$REMOTE_ROOT/${DD}/Build/Products/Release/IPTV Wall Player.app"
  /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" -c "Print :CFBundleVersion" "${APP}/Contents/Info.plist"
  codesign --force --deep --sign - "$APP" 2>&1 || true
  ditto -c -k --keepParent "$APP" "$REMOTE_ROOT/IPTVWall-mac-1.3-${BUILD}.zip"
  ls -la "$REMOTE_ROOT/IPTVWall-mac-1.3-${BUILD}.zip"
fi
RHEOF)
sshpass -p "$SSH_PASS" ssh $SSHOPTS "$REMOTE_USER@$REMOTE_HOST" "$REMOTE_CMD"

if [ "$PLATFORM" == "mac" ]; then
  echo "==> 抓回本機"
  sshpass -p "$SSH_PASS" scp $SSHOPTS "$REMOTE_USER@$REMOTE_HOST:$REMOTE_ROOT/IPTVWall-mac-1.3-${BUILD}.zip" .
fi

if [ "$UPLOAD" == "1" ]; then
  if [ -z "$APP_PASSWORD" ]; then echo "缺少 APP_PASSWORD 環境變數"; exit 1; fi
  IPA="$REMOTE_ROOT/IPTVWall-${PLATFORM}-1.3-${BUILD}.ipa"
  echo "==> 上傳 TestFlight ($PLATFORM build $BUILD)"
  sshpass -p "$SSH_PASS" ssh $SSHOPTS "$REMOTE_USER@$REMOTE_HOST" "sh -c 'cd $REMOTE_ROOT && nohup xcrun altool --upload-app -f $IPA $ALT -u $ASC_USERNAME -p $APP_PASSWORD > /tmp/up-${PLATFORM}-${BUILD}.log 2>&1 &'"
  sleep 25
  for i in $(seq 1 20); do
    STATE=$(sshpass -p "$SSH_PASS" ssh $SSHOPTS "$REMOTE_USER@$REMOTE_HOST" "pgrep -f 'altool --upload-app' >/dev/null && echo RUNNING || echo DONE")
    echo "waiting... $STATE"
    [ "$STATE" == "DONE" ] && break
    sleep 15
  done
  echo "==> 上傳結果:"
  sshpass -p "$SSH_PASS" ssh $SSHOPTS "$REMOTE_USER@$REMOTE_HOST" "tail -8 /tmp/up-${PLATFORM}-${BUILD}.log; echo ---; grep -E 'Delivery UUID|UPLOAD SUCCEEDED|ERROR' /tmp/up-${PLATFORM}-${BUILD}.log | head -3 || true"
fi
echo "==> done"
