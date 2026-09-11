# IPTV Wall 三端 Build + TestFlight 上傳流程（2026-08-31 驗證）

本文件是已驗證可用的完整流程。以後 build、上傳一律照這個跑，不要重新探索。
快速路徑：scripts/build-upload.sh（見文末）。

## 0. 環境（不變的事實）

- 遠端 build 機：位址與帳號不寫在 repo，改用環境變數（見下方「必要環境變數」）
  - 連線範例：sshpass -p "$BUILD_SSH_PASSWORD" ssh -o StrictHostKeyChecking=no -o IdentitiesOnly=yes -o PreferredAuthentications=password -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 "$REMOTE_USER@$REMOTE_HOST" '指令'
- 遠端 Xcode：26.6（17F113）。App Store 上傳唯一合法版本；RC 未出以前都用 26.6
- 遠端專案路徑：/Users/$REMOTE_USER/IPTVWall/tvOS/（曾被外部刪過，已從本機 repo 重建）
- 本機 repo 是唯一來源（原始碼 push 到 GitHub 後，build 機再從本機同步）
- Apple ID：由 ASC_USERNAME 提供；上傳用 App 專用密碼（一般密碼會回 -22910）
- 簽證：Apple Distribution: Ching-yuan yang (NZBLXS857E)；Team = NZBLXS857E
- provisioning profile（在 build 機）：
  - tvOS：104d6729-085e-4b85-9ba4-4037e63fff3c.mobileprovision
  - iOS：38b16cce-32c7-4786-b026-970aa35197ce.mobileprovision
  - macOS：目前沒有 macOS App Store profile，macOS 無法上 TestFlight，只能本地 zip 交付
  - tvOS 開發/Ad Hoc（本機 ~/Downloads）：IPTV_Wall_tvOS_Dev.mobileprovision、
    IPTV_Wall_tvOS_AdHoc.mobileprovision（2026-09-11 建，含兩台 ATV UDID）
- 版號狀態：tvOS 101、iOS 100、macOS 114；MARKETING_VERSION = 1.3
- iCloud 快照 schemaVersion = 3，已包含 go2rtc 頻道（go2rtc 增刪改會觸發同步）
- iOS/tvOS 發行版（TestFlight/App Store）不會保留可讀的 embedded.mobileprovision，
  hasRequiredEntitlement 在真機上改為「無 profile 即信任簽章發行版」，
  否則 iOS/tvOS 會被靜默停用 CloudKit 同步（2026-09-11 已修）
- tvOS/iOS 的 CloudKit entitlements：
  - com.apple.developer.icloud-container-environment 必須是「字串 "Production"」，
    陣列 ["Production"] 在 tvOS 會拋 CKException 崩潰（實測驗證），上傳腳本已改
- macOS 開發版走 production；tvOS/iOS 開發簽章走 development（與 Mac 資料隔離），
  要同步真資料必須裝 TestFlight/App Store 簽章的 build
- 實機直裝（devicectl）請用 tvOS Ad Hoc profile + Apple Distribution 簽章
  （get-task-allow=false → production env）：
    codesign --sign 'Apple Distribution: Ching-yuan yang (NZBLXS857E)'
      --entitlements <env=字串Production> app
  2026-09-11 已在工作室 ATV 驗證：Ad Hoc 101 同步到 production，11 支 go2rtc 全部下載
  - 每平台獨立計數；上傳前確認目標 build 大於該平台 ASC 現有最高 build，否則 -19232 拒絕

## 1. 修改程式碼後

只改本機 repo，再同步到 .22（可只傳改過的檔，或整個目錄）：

scp -r GlobalNewsWallTV GlobalNewsWallTV.xcodeproj "$REMOTE_USER@$REMOTE_HOST:/Users/$REMOTE_USER/IPTVWall/tvOS/"

## 2. Build（unsigned Release）

cd /Users/$REMOTE_USER/IPTVWall/tvOS
xcodebuild -scheme <SCHEME> -destination <DEST> -configuration Release
  -derivedDataPath /Users/$REMOTE_USER/IPTVWall/DerivedData-<tag>
  CURRENT_PROJECT_VERSION=<N> CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build

- tvOS：scheme GlobalNewsWallTV，destination generic/platform=tvOS
- iOS：scheme IPTVWallPad，destination generic/platform=iOS
- macOS：scheme IPTVWallMac，destination platform=macOS
- 驗證：/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" -c "Print :CFBundleVersion" "<app>/Info.plist" 要 1.3 / N

## 3. 手動簽證

不要用 Xcode 自動簽證（build 機沒有 Apple ID 帳號；手動流程已被 Apple 接受）。

1. 解鎖 keychain：security unlock-keychain -p "$KEYCHAIN_PASSWORD" ~/Library/Keychains/login.keychain-db
2. 從 profile 抽 Entitlements 並修正：
   - com.apple.developer.icloud-container-environment = "Production"
     （必須是字串。用陣列 ["Production"] 在 tvOS 會讓 CloudKit 丟 CKException 直接崩潰）
   - 刪掉 com.apple.developer.icloud-container-development-container-identifiers
   - com.apple.developer.ubiquity-kvstore-identifier = "NZBLXS857E.com.neo99.IPTVWall"（不能用萬用字元）
   - iOS 才做：com.apple.developer.icloud-services = ["CloudKit"]（"*" 不被接受）
   - tvOS 必做：刪掉 com.apple.developer.user-management（ITMS-90780 就是它的坑）
3. 嵌 profile 並簽：
   - cp <profile> "<app>/embedded.mobileprovision"
   - codesign --force --sign "Apple Distribution: Ching-yuan yang (NZBLXS857E)" --entitlements <fixed.plist> "<app>"

## 4. 打包 .ipa

rm -rf /tmp/xipa; mkdir -p /tmp/xipa/Payload
cp -R "<app>" /tmp/xipa/Payload/
cd /tmp/xipa && zip -qry /Users/$REMOTE_USER/IPTVWall/IPTVWall-<platform>-1.3-<N>.ipa Payload

## 5. 上傳（altool + App 專用密碼）

xcrun altool --upload-app -f <ipa> -t appletvos|ios -u "$ASC_USERNAME" -p <APP_SPECIFIC_PASSWORD>

- 成功會印 UPLOAD SUCCEEDED 與 Delivery UUID；記下 UUID 回報
- 收到 UUID 不等於出現在 TestFlight：還要等 Apple 處理 10-60 分鐘
- 常見錯誤：
  - -22910：缺少 App 專用密碼
  - -19232：build 太低，往上加
  - 90186 train closed：1.2 已關要升 1.3；之後 1.3 關就升 1.4
  - 90046 / 90211：entitlements 問題，對照第 3 步
  - ITMS-90780：tvOS 帶了 user-management，移除重簽
  - ITMS-90471 缺 Top Shelf：目前只是 warning，不是拒絕原因

## 6. 已知坑（避免重踩）

- exec 有 30 秒上限：把 yield_time_ms 拉大；上傳用遠端 nohup + log 後輪詢（pgrep -f "altool --upload-app"）
- SSH 限流：連續連線會 Too many authentication failures；間隔 20-30 秒，能塞同一條 SSH 就塞
- MTU：build 機連 Apple S3 出現 TLS / checksum not match 時先 sudo ifconfig en5 mtu 1400（重開機還原）
- grep -c 是 0 時回傳碼為 1，set -e 腳本要用 grep -c ... || true
- build-upload.sh 的 python heredoc 是 quoted 形式，裡面不能用 $PLATFORM；
  2026-09-11 已改為 os.environ.get("PLATFORM")，否則 ios 的
  icloud-services=["CloudKit"]（90046）與 tvos 的 user-management（90780）修正都不會生效
- build 機的 /Users/$REMOTE_USER/IPTVWall 曾被外部刪掉：build 前先 ls 確認
- 版號要與 ASC 對齊，上傳前確認

## 7. 必要環境變數（不進版控）

| 變數 | 用途 |
| --- | --- |
| REMOTE_HOST | build 機位址 |
| REMOTE_USER | build 機帳號 |
| BUILD_SSH_PASSWORD | build 機 SSH 密碼（sshpass 用） |
| BUILD_KEYCHAIN_PASSWORD | build 機 login keychain 密碼（未設時沿用 BUILD_SSH_PASSWORD） |
| ASC_USERNAME | 上傳 TestFlight 的 Apple ID |
| APP_PASSWORD | App 專用密碼，只有加 --upload 時才需要 |

範例：

REMOTE_HOST=... REMOTE_USER=... BUILD_SSH_PASSWORD=... ASC_USERNAME=... APP_PASSWORD=... scripts/build-upload.sh ios 101 --upload

## 8. 一鍵腳本

scripts/build-upload.sh <ios|tvos|mac> <build> [--upload]（本機執行）
- 需先設好第 7 節的環境變數，沒設會直接中止並提示缺哪一個
- 加 --upload 會上傳 TestFlight（ios/tvos）
- macOS 用 scripts/build-upload.sh mac <build>：只 build + zip 抓回本機（無 profile 無法上傳）
