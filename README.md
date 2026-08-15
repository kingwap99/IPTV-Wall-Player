# IPTV Wall Player

IPTV Wall Player is a multi-channel video wall player for Apple platforms. It
lets users import their own M3U playlists, monitor several streams at once, and
promote one stream to a larger player without rebuilding the playback session.

This repository contains the shared SwiftUI source used by the macOS, iOS, and
tvOS targets. The downloadable binary published here is the macOS edition.

## Features

- 4x4, 5x5, and 6x6 wall layouts on macOS
- M3U playlist import and local playlist management
- Large-player and full-screen viewing modes
- Audio fade transitions when switching the featured channel
- Optional iCloud synchronization for user-owned settings and playlists
- Traditional Chinese and English localization

## Requirements

- Apple silicon Mac
- macOS 14 or later
- Xcode 26.6 or later

## Build The macOS App

1. Open `GlobalNewsWallTV.xcodeproj` in Xcode.
2. Select the `IPTVWallMac` scheme.
3. Choose your own Development Team when signing is required.
4. Build and run the project.

An unsigned local build can also be created from Terminal:

```bash
xcodebuild \
  -project GlobalNewsWallTV.xcodeproj \
  -scheme IPTVWallMac \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## macOS Download

The GitHub Release contains an arm64 build for Apple silicon. It is not
notarized by Apple. On first launch, use Finder's **Open** command from the
context menu and confirm that you want to open the app.

If macOS still blocks the app after it has been moved to Applications, remove
the download quarantine attribute and open it again:

```bash
xattr -dr com.apple.quarantine "/Applications/IPTV Wall Player.app"
```

The prebuilt GitHub binary intentionally omits restricted iCloud entitlements
so it can run without an Apple distribution certificate. To use CloudKit,
build the source with your own Apple Development Team in Xcode.

## Content And Privacy

IPTV Wall Player is a playback tool. Users are responsible for ensuring they
have permission to access every stream or playlist they add. The app does not
claim ownership of third-party media, channel names, logos, or stream URLs.

Playlist data and preferences are stored on the user's device and may be synced
through the user's private iCloud account when that feature is enabled.

## License

Source code is available for inspection, learning, contribution, and free
personal non-commercial use. Organizational or commercial use requires a
separate commercial license. See [LICENSE.md](LICENSE.md) or contact
`kingwap.tw@gmail.com`.
