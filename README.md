# CmdFreak

A native macOS WhatsApp client built for the keyboard, backed by
[whatsapp-rust](https://github.com/oxidezap/whatsapp-rust).

> **Status:** early and unofficial. Not affiliated with WhatsApp or Meta. See the [disclaimer](#disclaimer).

## Features

- Links to your account as a companion device, by QR code or phone-number pairing code
- Syncs chat history, groups, contacts and avatars
- Shows every kind of media: images, videos, GIFs, stickers, documents, audio and voice notes (with playback)
- Sends text, replies, images, videos, GIFs and documents
- Mail-style three-column window: filter sidebar, chat list, conversation
- ⌘K command bar for chats and actions
- Notifications for incoming messages, unread count on the Dock icon
- Updates itself through [Sparkle](https://sparkle-project.org)

### Keyboard

| Shortcut | Action |
| --- | --- |
| ⌘K | Command bar |
| ⌘N | New chat |
| ⌘F | Search chats |
| ⌘] / ⌘[ | Next / previous chat |
| ⌥↓ / ⌥↑ | Next / previous unread chat |
| ⌘1 … ⌘9 | Open pinned chat |
| ⌥⌘1 … ⌥⌘4 | Chats, Unread, Groups, Archived |
| ⌥⌘↓ / ⌥⌘↑ | Next / previous sidebar item |
| ⇧⌘O | Attach a file |
| Space | Quick Look the selected attachment |
| ⇧⌘U / ⇧⌘P / ⇧⌘M / ⇧⌘A | Mark unread / pin / mute / archive |
| ⌃⌘S | Toggle the sidebar |

Every shortcut is also in the menu bar.

## Install

Requires macOS 26 on Apple silicon.

1. Download `CmdFreak-<version>.dmg` from [Releases](https://github.com/anirudhsama/cmdfreak/releases/latest)
   and drag CmdFreak into Applications.
2. The app is self-signed rather than notarized, so macOS blocks the first launch. Open it once,
   then go to **System Settings → Privacy & Security** and click **Open Anyway**. Or run:

   ```sh
   xattr -dr com.apple.quarantine /Applications/CmdFreak.app
   ```

3. Link your account from WhatsApp on your phone: **Settings → Linked Devices → Link a Device**.

Later versions arrive through **CmdFreak → Check for Updates…** and install without the Gatekeeper step.

## Privacy

Everything stays on your Mac. The session keys and the message database live in
`~/Library/Application Support/CmdFreak`, and downloaded media and avatars in `~/Library/Caches/CmdFreak`.
Neither is encrypted by the app; turn on FileVault to encrypt them at rest. The app talks only to
WhatsApp's servers and, for update checks, to GitHub.

## Building from source

Requirements:

- Xcode 26 or later
- Rust via [rustup](https://rustup.rs); `rust/rust-toolchain.toml` selects the stable toolchain
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

```sh
scripts/build-bridge.sh   # Rust bridge → Packages/WACoreFFI (first build takes a few minutes)
xcodegen generate         # CmdFreak.xcodeproj from project.yml
open CmdFreak.xcodeproj
```

The Xcode build rebuilds the bridge when Rust sources change. Debug builds are ad-hoc signed and
never check for updates. `swift build` and `swift test` work inside each package under `Packages/`.

### Layout

```
CmdFreak/        app target: entry point, menus, Info.plist, entitlements, icon
Packages/
  WAKit/         data layer: GRDB database, ingest, sync, media store
  WAMacUI/       AppKit and SwiftUI interface
  WACoreFFI/     Swift package around the generated bridge (built by scripts/build-bridge.sh)
rust/
  wa-bridge/     UniFFI bridge over whatsapp-rust
  wa-link/       CLI that links an account and records events for fixtures
Tools/wa-cli/    CLI for smoke-testing the bridge
scripts/         bridge build and release setup
```

### Releasing

Releases are built by the **Release** workflow (Actions → Release → version `X.Y.Z`). It signs the
app, publishes a DMG, a zip and a Sparkle appcast to GitHub Releases, and installed copies pick it
up from there. `scripts/setup-release-signing.sh` creates the signing identity and update key once.

## Disclaimer

CmdFreak is an unofficial client and is not affiliated with, endorsed by or sponsored by WhatsApp
or Meta. WhatsApp is a trademark of WhatsApp LLC. Using an unofficial client may be against
WhatsApp's Terms of Service and could get your account suspended or banned. Use it at your own
risk.

## License

[MIT](LICENSE). whatsapp-rust is also MIT licensed. The chat bubble in the app icon is
from [Lucide](https://lucide.dev) ([ISC](https://github.com/lucide-icons/lucide/blob/main/LICENSE)).
