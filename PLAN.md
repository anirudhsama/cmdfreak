# better-wa — v1 implementation plan

A native macOS WhatsApp client for personal use. The goals are a native Mac feel with liquid glass, fast performance, strong keyboard control, and a ⌘K command bar. This file is the brief for the implementing agent, so read it top to bottom before starting.

## Decisions (settled — do not revisit)

- **Platform:** macOS 26+ only. Use no `#available` gating and no pre-glass fallbacks. Swift 6 with strict concurrency, `@Observable`, and Swift Testing.
- **WhatsApp protocol:** [`whatsapp-rust`](https://github.com/oxidezap/whatsapp-rust), wrapped in our own Rust crate and exposed to Swift through UniFFI. Pin it as a git dependency at commit `f9811768bdc61340222268bce279c39e962a9638`. It builds on **stable** Rust 1.98 on aarch64-apple-darwin (release lib build takes about 2 minutes), so do not adopt its nightly `rust-toolchain.toml`.
- **App database:** GRDB over plain SQLite in WAL mode, with no SQLCipher; FileVault covers encryption at rest. whatsapp-rust's own key and session store is a separate SQLite file owned by the Rust side.
- **Tags (post-v1):** local-only, not synced with WhatsApp labels. v1 only needs the rail modelled as a list of filters (see UI).
- **Media in v1:** receive and view every media type: image, video, GIF, sticker, document, audio, and voice note (with playback). Send images, videos, GIFs and documents of any file type. Do **not** send voice notes.
- **Signing and sandbox:** the app is unsandboxed. It is signed locally for personal use with Hardened Runtime on and no App Sandbox, and needs no notarization. The Rust side writes to `~/Library/Application Support`, and Quick Look and Open With work on arbitrary paths.
- **Project:** XcodeGen (`project.yml`) with a thin app target. Nearly all code goes in local SwiftPM packages so `swift build` and `swift test` work without Xcode.

## Reference code

Both repos are cloned in `/tmp/wa-research/`. If they are missing, re-clone them:
`git clone --depth 1 https://github.com/inline-chat/inline /tmp/wa-research/inline && git clone https://github.com/oxidezap/whatsapp-rust /tmp/wa-research/whatsapp-rust && git -C /tmp/wa-research/whatsapp-rust checkout f9811768bdc61340222268bce279c39e962a9638`

**Inline (`inline/apple/`)** is our model for performance and UX patterns. Read `apple/AGENTS.md` first. Copy patterns, not code wholesale.

| Concern | Inline file |
|---|---|
| Message list (NSTableView, updates, scroll anchoring) | `InlineMac/Views/MessageList/MessageListAppKit.swift` |
| Height/layout plans + caches | `InlineMac/Views/MessageList/MessageSizeCalculator.swift` |
| Core Text measurement | `InlineMac/Utils/TextMeasurer.swift` |
| Row model + diff (`UpdateKind`) | `ChatRowListViewModel.swift` |
| Push-style message change feed | `InlineKit/.../ViewModels/FullChatProgressive.swift` (`MessagesPublisher`) |
| Preload before first frame | `InlineMac/Features/Chat/ChatOpenPreloader.swift` |
| Sidebar list (NSCollectionView + reused hosting views) | `InlineMac/Features/Sidebar/Collection/SidebarCollectionBody.swift`, `SidebarCollectionItem.swift` |
| Glass compose (AppKit) | `InlineMac/Views/Compose/GlassComposeAppKit.swift`, `ComposeTextEditor.swift` |
| Command bar panel + registry | `InlineMac/Features/CommandBar/CommandBarOverlay.swift`, `CommandBarRegistry.swift`, `QuickSearchUsageStore.swift` |
| Key handling | `InlineMac/App/KeyMonitor.swift`, `App/AppMenu.swift`, `App/GlobalHotkeys.swift` |
| Window hosting | `InlineMac/Features/MainWindow/MainWindowController.swift` |

**whatsapp-rust** is the API we wrap. Read `README.md`, `AGENTS.md`, `agent_docs/`, and `examples/demo.rs`.

| Concern | Location |
|---|---|
| Builder, QR/pair-code callbacks | `src/bot.rs` (`on_qr_code` ~1126, `with_pair_code` ~1400, `with_event_handler` ~1263) |
| Pair code at runtime | `src/pair_code.rs` (`pair_with_code`, `cancel_pair_code`) |
| Event enum + `EventHandler` trait | `wacore/src/types/events.rs` (~80 variants; `HistorySync` is `LazyHistorySync`, use `.stream()`) |
| History sync decoding | `wacore/src/history_sync.rs` |
| Send | `src/send/mod.rs` (`send_message(jid, wa::Message)`), `src/send/actions.rs` (revoke) |
| Upload | `src/upload.rs` (`upload`, `upload_stream` → `UploadResponse`) |
| Download | `src/download.rs` (`download_from_params_to_writer`, `DownloadParams`) |
| Receipts / presence / typing | `src/receipt.rs` (`mark_as_read`), `src/features/presence.rs`, `src/features/chatstate.rs` |
| Groups, contacts, profile pics | `src/features/groups.rs`, `contacts.rs` (profile pictures are here too) |
| Edit / poll-vote decryption | `src/features/message_edit.rs`, `src/features/polls.rs` |
| Event delivery modes, durability | `src/bot.rs` (`EventDelivery` ~277), `examples/durability_hook.rs` |
| LID↔PN lookup | `src/client/lid_pn.rs` (`get_lid_pn_entry`) |
| Chat actions | `src/features/chat_actions.rs` |
| Storage backend | `storages/sqlite-storage/` |
| Protobuf | `waproto/` (`whatsapp.proto`) |

## Pre-linked session and captured fixtures

The user's real account is already linked (2026-09-26) through `rust/wa-link`, a capture tool that never sends anything. Use this session and the captured data for all development and testing.

**Session:** `~/Library/Application Support/BetterWA/wa-session.sqlite`. It's a whatsapp-rust `SqliteStore` at the pinned commit.
- `wa-bridge` opens this same file and connects without pairing again.
- **Never re-pair, and never call `logout()`**, during development. Pairing again needs the user's phone, and the initial history sync is only sent once per link.
- Back up the file before any experiment that could corrupt it.

**Captured data:** `~/Library/Application Support/BetterWA/capture/`.
- **`events.jsonl`:** 1,224 serde-serialized `Event`s, one per line, captured from pairing until the sync completed. Mostly app-state: 641 `ContactUpdate`, 238 `ArchiveUpdate`, 130 `CallLogSync`, 48 `StarUpdate`, 46 `MuteUpdate`, 26 `PinUpdate`, 12 `MarkChatAsReadUpdate`, 10 `LockChatUpdate`, and 4 `LabelEditUpdate`. There are only 16 live `Messages` batches. Lines of the form `{"HistorySyncFile": "<name>"}` point to the files below.
- **`history/*.zlib`:** 13 raw `HistorySync` payloads (zlib-compressed protobuf, 12 MB compressed), named `<eventSeq>-type<syncType>-chunk<n>.zlib`:
  - type 5 (non-blocking data) × 1;
  - type 0 (`INITIAL_BOOTSTRAP`) × 1, 1.35 MB inflated;
  - type 1 (initial status) × 1;
  - type 4 (`PUSH_NAME`) × 1;
  - type 3 (`RECENT`) chunks 1–9, about 29 MB inflated, which is where most messages live.

  Decode them with `LazyHistorySync::new(…)` or by inflating and parsing `wa::HistorySync` from `waproto`. They are the primary fixtures for the M2 ingest tests and the bridge history-sync tests.
- **Warnings seen during the capture** (harmless, but expect them): `AppState: Collection regular_low ltHash diverged at v191 … applying it and skipping the aggregate comparison`, and `chat_actions: Skipping chat mutation 'pin_v1'`.

**Operational rules:**
- **One connection only:** only one process may connect with this device at a time. Make sure `wa-link` is not running (`pkill -INT wa-link`) before starting `wa-cli` or the app.
- **Capturing more live traffic:** run `rust/wa-link/target/release/wa-link`. It reuses the session, appends to `events.jsonl`, and keeps running until Ctrl+C.
- **Live tests that send:** send only to the user's own number (the "Message yourself" chat), never to other contacts.
- **Workspace:** in M0, move `rust/wa-link` into the `rust/` workspace as a member (and remove its standalone `[workspace]` table).
- **Treat the capture as private data.** It holds real messages: never commit it, and copy only trimmed and anonymised fixtures into the repo. Add `capture/` patterns to `.gitignore`.

## Repo layout

```
better-wa/
  PLAN.md
  project.yml                 # XcodeGen: BetterWA.app target, links packages + WACoreFFI.xcframework
  App/                        # thin app target: @main, AppDelegate, Info.plist, entitlements, assets
  rust/
    Cargo.toml                # workspace
    wa-bridge/                # our UniFFI crate (cdylib + staticlib)
    rust-toolchain.toml       # stable
  scripts/
    build-bridge.sh           # cargo build --release (aarch64-apple-darwin) → uniffi-bindgen swift → xcframework
  Packages/
    WACoreFFI/                # SwiftPM: binaryTarget(xcframework) + generated Swift bindings
    WAKit/                    # models, GRDB DB, ingest actor, sync/session services, media store
    WAMacUI/                  # all AppKit/SwiftUI UI
  Tools/wa-cli/               # SwiftPM executable for M1 smoke tests (link, print events, send)
```

Build only arm64. Universal binaries are not needed.

## Architecture

### Rust bridge (`rust/wa-bridge`)

- **Runtime and store:** owns a multi-threaded tokio runtime and one `whatsapp-rust` client. The sqlite-storage backend points at `~/Library/Application Support/BetterWA/wa-session.sqlite`.
- **Connection lifecycle:** the library already auto-reconnects with backoff (`src/client/lifecycle.rs:619`, `:913`), and `Bot::spawn` supervises the client (`src/bot.rs:567-600`). Bridge `connect()` calls `bot.spawn()` exactly once. Do **not** add a second backoff loop anywhere. On system wake, Swift calls `nudgeReconnect()`, which disconnects and relies on the library's own loop.
- **Event delivery:** build with `with_event_delivery(EventDelivery::Ordered { capacity: 8192 })`. The default `Concurrent` mode does not preserve ordering (`src/bot.rs:277-292`). `Ordered` drops events when its mailbox is full, so:
  - `handle_event` must only push onto an unbounded channel and return. A separate coalescer task drains that channel.
  - Register an inbound durability hook (`examples/durability_hook.rs`) so dropped events are redelivered.
  - `wa-cli` prints `stats().events_dropped`, which must stay 0.
- **Exports to Swift** (UniFFI proc-macros, async functions):
  - `WaBridge::new(dataDir)`, `connect()`, `disconnect()`, `logout()`.
  - `startPairingQr()`, `pairWithPhone(number)`, `cancelPairing()`.
  - `sendText(chat, text, replyTo?)`, `sendMedia(chat, kind, fileURL, caption?, replyTo?)`, `sendReaction`, `editMessage`, `revokeMessage`.
  - `markRead(chat, [(messageId, senderJid)])`. Rust groups the ids by sender, because for group chats `mark_as_read(chat, sender, ids)` needs the sender for the receipt's `participant` field (`src/receipt.rs:1054`, `:1100`).
  - `sendChatState(chat, composing|paused)`, `subscribePresence(jid)`, `nudgeReconnect()`.
  - `fetchGroupOverviews(jids)` uses the batched `Groups::fetch_overviews` (`groups.rs:2823`), which returns subject and participant count only. `fetchGroupMetadata(jid)` is a single-group call (`groups.rs:1486`) made lazily when a group is opened, for its participant list.
  - `profilePicture(jid)` uses `get_profile_picture(jid, preview)` (`src/features/contacts.rs:380`), not `profile.rs`, which only sets your own profile.
  - `downloadMedia(params, destPath, progress)` uses `download_from_params_to_writer` (`src/download.rs:708`) with a `ProgressFile` writer. On retry the library truncates the writer back to 0 (`src/download.rs:716-725`), so `ProgressFile::truncate` must reset the reported progress.
  - `remuxOggToCaf(src, dst)` (see voice notes).
  - `pinChat`, `archiveChat`, `muteChat`, `markChatRead`.
  - API notes: `send_message` is `pub fn … -> impl Future` returning `SendResult { message_id, … }` (`src/send/mod.rs:1417`, `:937`). `edit_message` is at `src/client/messaging.rs:170`. `revoke_message(to, id, RevokeType::{Sender, Admin{original_sender}})` is at `src/send/actions.rs:18`. `send_reaction(chat, wa::MessageKey, emoji)` is at `reaction.rs:35`; the message table stores the `participant` so the key can be rebuilt.
- **Events:** a UniFFI `callback interface EventSink { fn onEvents(events: Vec<BridgeEvent>) }`, fed by an `EventHandler` impl.
  - Coalesce events on the Rust side, flushing every ~16ms or 200 events, so Swift receives batches and not one hop per message.
  - Use the handler's `interest()` filter to drop event kinds we don't use.
- **No protobufs across the boundary.** Map everything to flat UniFFI records: `BridgeChat`, `BridgeMessage`, `BridgeContact`, `BridgeReceipt`, `BridgePresence`, `BridgeGroup`, `BridgeHistoryChunk`, `BridgePairing` (QR string, pair code, success, error, logged out), and `BridgeConnection` (connecting, connected, disconnected with a reason).
  - `BridgeMessage` fields: `id`, `chatJid`, `senderJid`, `fromMe`, `timestamp`, `kind` (text, image, video, gif, sticker, document, audio, voice, location, contact, poll, system, unsupported), `text`/`caption`, `quoted` (id plus a snippet), `media: BridgeMedia?`, `reactions`, `editOf?`, `revoked`.
  - `BridgeMedia` fields: `directPath`, `mediaKey`, `fileSha256`, `fileEncSha256`, `fileLength`, `mediaType`, `mimetype`, `fileName?`, `width/height?`, `durationSecs?`, `jpegThumbnail?`, `waveform?` (voice), `pageCount?`, `isAnimated?`.
  - This record set is exactly what `DownloadParams` needs, so the app stores it and downloads later with no protobuf.
  - Keep one `unsupported` kind carrying a type name so nothing is silently dropped.
- **Message mapping inside `Event::Messages`:** there are no separate edit, revoke, or reaction event variants; all three arrive inside `Event::Messages` (`MessageBatch`, `events.rs:1418`) and the bridge maps them.
  - **Encrypted edits:** these are not decrypted by the library (`src/features/message_edit.rs:11-25`). Detect `secret_encrypted_message.secret_enc_type == MessageEdit`, then `extract_envelope`. Get the parent's `messageSecret` from the library's own store: `client.persistence_manager().backend().get_msg_secret(…)` (`wacore/src/store/traits.rs:1324`). Then `decrypt(…)` (`message_edit.rs:73`), `rewrap_as_legacy_edit`, and emit a normal `BridgeMessage { editOf }`.
  - **Legacy edits and revokes:** `protocol_message.edited_message` and `REVOKE` protocol messages map to `editOf` / `revoked`.
  - **Poll votes:** decrypt them the same way with `Polls::decrypt_vote` (`src/features/polls.rs:211`) and emit them as vote updates.
  - **`UndecryptableMessage`** (`events.rs:2317`): emit an `undecryptable` placeholder message. The library sends retry receipts itself.
  - **Batching:** never split one `MessageBatch` across two bridge batches.
- **Canonical IDs (critical):** WhatsApp mixes LID (`@lid`) and phone-number (`@s.whatsapp.net`) addresses. Chats keyed by the wrong one split in two.
  - **Resolution order:** first the message's own `MessageSource.sender_alt` / `recipient_alt` (`wacore/src/types/message.rs:176-178`), then `Client::get_lid_pn_entry(&Jid)` (`src/client/lid_pn.rs:1147`). The internal cache is `pub(crate)`, so don't try to reach into it.
  - **Cache lookups in the bridge.** One async lookup per message during a 50k-message sync is too slow.
  - **`jidAliases` events:** there is no "mapping learned" event in the library. Emit `jidAliases` from the resolutions above, from `ContactNumberChanged` (`events.rs:2425`), and from the history-sync remainder's `phoneNumberToLidMappings`, so Swift can merge any duplicated chat.
- **History sync:** `LazyHistorySync` (`events.rs:107-113`) exposes `progress()`, `chunk_order()`, `sync_type()`, and `stream()`.
  - **Where it runs:** the stream is synchronous. Run it on a blocking thread (`spawn_blocking`), never inside `handle_event`.
  - **Loop:** call `next_conversation()` repeatedly (`wacore/src/history_sync.rs:620`), emitting a `BridgeHistoryChunk { conversations, messages, progress, syncType }` every ~50 conversations.
  - **Remainder:** only after the conversations are drained, call `remainder()` (`:667`; it errors with `UnreadConversations` if called early). Push names and LID mappings come from it, in a final chunk.
  - **Sync types:** handle `INITIAL_BOOTSTRAP`, `RECENT`, `FULL`, and `ON_DEMAND` explicitly.
  - **Memory:** never hold a full sync in memory.
  - **If volume causes drops:** raise the `Ordered` capacity; `set_skip_history_sync` (`accessors.rs:227`) is the last resort.
- **Sending media:** Swift supplies the metadata it can compute natively (thumbnail JPEG, dimensions, duration, mimetype, page count) as a record. Rust uploads the file and builds the correct `wa::Message` (`ImageMessage`, `VideoMessage` with `gifPlayback` for GIFs, `DocumentMessage`).
  - **Images, GIFs, small files:** `upload(data: Vec<u8>, MediaType, UploadOptions)` (`src/upload.rs:409`), which works in memory.
  - **Videos and documents:** encrypt to a temp file with `wacore::upload::encrypt_media_streaming` (`wacore/src/upload.rs:540`), then `upload_stream(source, info, MediaType)` (`src/upload.rs:463`).
  - **Upload progress:** comes from a counting `UploadSource` wrapper.
  - **Sidecar:** leave `UploadOptions.streaming_sidecar = None` (the library picks by media type) and copy `UploadResponse.streaming_sidecar` into `VideoMessage.streaming_sidecar`.
- **Errors:** one `BridgeError` enum. Never panic across FFI.
- **Logging:** the crate logs through both the `log` facade (e.g. `src/history_sync.rs:566`) and the optional `tracing` feature. Install a `log` logger and a `tracing` subscriber, and forward both to Swift's `os.Logger` through a callback, filtered at `info` in release builds.

`scripts/build-bridge.sh` runs these steps; the script must be idempotent:
1. `cargo build --release --target aarch64-apple-darwin -p wa-bridge`.
2. `cargo run -p uniffi-bindgen -- generate --library … --language swift`. This needs a small `rust/uniffi-bindgen/` bin crate in the workspace (the standard UniFFI pattern).
3. Assemble the XCFramework (static lib plus headers plus modulemap) into `Packages/WACoreFFI`.
4. Copy the generated `.swift` bindings into the package.

The XcodeGen project runs it as a pre-build script only when the Rust sources are newer than the XCFramework.

### Data layer (`WAKit`)

- **Database:** GRDB `DatabasePool` at `~/Library/Application Support/BetterWA/app.sqlite`. Append-only migrations in one file.
- **Tables:**
  - `chat`: jid PK, kind (dm, group, broadcast), name, `lastMessageId`, `lastActivityAt`, `unreadCount`, `markedUnread`, `pinnedAt`, `mutedUntil`, `archived`, `avatarPath`.
  - `contact`: jid PK, `pushName`, `fullName`, `phone`.
  - `group_participant`.
  - `message`: (chatJid, id) PK. Columns: sender, participant, fromMe, timestamp, kind, text, quoted, status (pending, sent, delivered, read, failed), `editedAt`, `revoked`, `sortKey`. Index on (chatJid, timestamp).
  - `media`: messageKey FK. Holds the download params, the metadata, `localPath`, and `downloadState`.
  - `reaction`.
  - `jid_alias`.
  - `pending_mutation`: edits, revokes, reactions, and receipts waiting for their target message.
  - `message_fts`: FTS5 over text and caption, populated now so search is cheap later.
  - `chat_tag`, `tag`: create them now but leave them unused in v1, so the tags feature needs no migration.
- **`sortKey`:** `(timestamp, ingestSeq)`, where `timestamp` is the message's WhatsApp timestamp (`messageTimestamp` for history rows) and `ingestSeq` is a monotonically increasing integer assigned by `IngestActor`, used as the tie-breaker. Store it as one sortable integer column.
- **Out-of-order tolerance:** edits, revokes, reactions, and receipts can arrive before the message they target, especially during history sync. Park them in a `pending_mutation` table keyed by the target message, and apply them when the target is inserted.
- **Receipt status:** `Sent` → sent, `Delivered` → delivered, `Read`/`ReadSelf`/played → read. Status only moves forward, never back. `Retry` doesn't change status.
- **Unread semantics:**
  - Incoming non-own messages increment `unreadCount` unless that chat is currently open and the window is key.
  - `ReadSelf` receipts and `MarkChatAsReadUpdate` from other devices zero it.
  - `markedUnread` survives new incoming messages and clears only when the chat is opened.
  - Opening a chat calls `markRead` for the unread incoming messages.
- **`IngestActor`:** the single writer.
  - Receives bridge event batches, writes each batch in one transaction, and updates chat aggregates (last message, unread count) in the same transaction.
  - After committing, publishes a `MessageChange` (add, update, delete, reload, with ids) on a per-chat change feed. Copy Inline's `MessagesPublisher` approach: the open chat view applies index-set changes and does **not** run a `ValueObservation` over its message window.
- **Chat list:** a GRDB `ValueObservation` over the chat query, scheduled `.immediate`, with no extra main-queue hop.
- **`ChatWindowLoader`:** pages messages by `sortKey`. It supplies the initial page, `older(before:)`, `newer(after:)`, and `around(messageId)`.
- **`MediaStore`:** content-addressed files under `~/Library/Caches/BetterWA/media/` (keyed by `fileSha256`), with de-duplicated in-flight downloads and progress reporting.
  - **Auto-download:** images, stickers, GIFs, and voice notes up to 16 MB.
  - **On demand:** videos and documents; show a thumbnail and size, and download on click.
  - Decode thumbnails off the main thread into a memory cache (`NSCache`) of `CGImage`s sized to the display size.
- **`SessionService`** (`@Observable`): tracks connection and pairing state for the UI (`unpaired`, `pairing(qr or code)`, `syncing(progress)`, `ready`, `loggedOut`), taken from bridge events. It does not implement reconnection itself; on `NSWorkspace.didWakeNotification` it calls `bridge.nudgeReconnect()`.

### UI (`WAMacUI` + `App/`)

- **Window:** an `NSWindowController` with `NSSplitViewController`.
  - **Sidebar item:** a horizontal pair — the rail (fixed ~56pt) and the chat list (min 260pt, ideal 320pt). It uses the standard sidebar behaviour so macOS 26 draws it as floating glass.
  - **Content item:** the chat view.
  - The toolbar uses `.unified`, with the title and subtitle set from the active chat.
- **Rail:** a vertical list of `RailItem`s. v1 has one item, `Chats` (all non-archived chats), plus an `Archived` item at the bottom.
  - `RailItem` is an enum or protocol that yields a chat-list filter. Tags become rail items later, and tagged chats can be excluded from `Chats`. Design the filter type for that now.
  - The selected item shows an accent pill. Shortcuts: ⌘⌥1…9.
- **Chat list:** `NSCollectionView` with a diffable data source. Each row keeps a long-lived `NSHostingView` holding a SwiftUI row that is fed through a small `@Observable` row state, so a reused row is never rebuilt.
  - **Row content:** avatar, name, last-message preview (a media glyph plus caption for media, "You: " prefix when you sent it), time, unread badge, muted and pinned icons, and a typing indicator.
  - **Context menu:** pin, mute, archive, mark read or unread.
  - **Order:** pinned chats first, then by `lastActivityAt`.
- **Message list:** AppKit `NSTableView` built exactly on Inline's pattern:
  - One column, a fixed row height per row taken from a precomputed `LayoutPlan`, and `usesAutomaticRowHeights = false`.
  - Height is measured with Core Text (`CTFramesetterSuggestFrameSizeWithConstraints`) through a shared `MessageTextConfiguration`, so measurement and rendering match exactly. Plans are cached in `NSCache`, keyed by `messageId + contentHash + width`.
  - Cells use manual `layout()` with no Auto Layout inside the bubble. Text renders in a read-only TextKit 2 `NSTextView` subclass that supports selection and link detection.
  - Rows are built from `[Row]` values (day separator, unread separator, message), with group sender names and grouping of consecutive messages.
  - Updates are applied with animations disabled (`CATransaction.setDisableActions`, `NSAnimationContext` duration 0), followed by `noteHeightOfRows` for edits.
  - Paging older messages keeps the distance from the bottom stable, and live resizing stays pinned to the bottom.
  - `ChatOpenPreloader` actor: when a chat is selected, it loads the first page and computes layout plans off the main thread, so the first frame renders synchronously.
  - A thumbnail warm-up runs for visible and nearby rows, cancelling any stale warm-up.
- **Message kinds:**
  - **Text:** Markdown-lite rendering (`*bold*`, `_italic_`, `~strike~`, and monospace), links, and phone numbers.
  - **Image:** a blurred `jpegThumbnail` placeholder that is replaced by the full image. Click opens Quick Look (`QLPreviewPanel`) with arrow keys stepping through the chat's media.
  - **Video:** thumbnail, duration, and a play overlay. Clicking downloads the video, then plays it in Quick Look or an `AVPlayerView` panel.
  - **GIF** (MP4 with `gifPlayback`): muted, looping `AVPlayerLayer` that plays only while visible.
  - **Sticker:** WebP through ImageIO, including animated WebP. Lottie stickers show their thumbnail.
  - **Document:** a file-type icon (`NSWorkspace.icon(for:)`), name, size, and page count. Click downloads, then opens Quick Look. Also provide "Open With…", "Show in Finder", and drag-out as a file promise.
  - **Audio and voice notes:** a play/pause button, a waveform drawn from the `waveform` bytes, the time played, and 1×/1.5×/2× speed. Only one plays at a time, and playback continues if you switch chats.
    - WhatsApp voice notes are Ogg/Opus, and AVFoundation has no Ogg demuxer, so remux them to CAF in Rust after downloading: `bridge.remuxOggToCaf(src, dst)`.
      - Use the pure-Rust `ogg` crate, which must be added to `wa-bridge`; it is not a whatsapp-rust dependency.
      - Write the `OpusHead` as the CAF `kuki` magic-cookie chunk, write a `pakt` packet table, and honour the pre-skip.
      - Core Audio decodes Opus-in-CAF natively, so `AVAudioPlayer` plays the result.
      - Cache the `.caf` next to the original.
    - Verify this in M1 with a real voice note.
  - **Location, contact card, poll:** a compact read-only card. The poll card shows vote counts from the decrypted votes.
  - **Undecryptable:** "Waiting for this message. This may take a while."
  - **System messages** (group changes and similar): a centered small label.
  - **Revoked:** "This message was deleted." **Edited:** an "edited" tag.
  - **Unsupported:** "Unsupported message (type) — open on phone."
  - **Replies:** a quoted block that jumps to the original on click, using `around(messageId)`.
  - **Reactions:** a chip row. Clicking a chip toggles your own reaction.
  - **Receipts on sent messages:** a clock (pending), one tick (sent), two ticks (delivered), and blue ticks (read).
- **Compose:** a TextKit 2 `NSTextView` inside an `NSGlassEffectContainerView` + `NSGlassEffectView` pill, with the list's bottom inset set so messages scroll under the glass.
  - **Keys:** Enter sends, ⇧Enter inserts a newline, and ↑ in an empty compose edits your last message.
  - **Attachments** arrive by attach button, paste, or drag and drop, and show as a staging tray of thumbnails with an optional caption.
  - **Before sending**, compute each attachment's metadata off the main thread:
    - Image thumbnail, dimensions, and mimetype: ImageIO.
    - Video duration, dimensions, and thumbnail: `AVAssetImageGenerator`.
    - Document mimetype and page count: `UTType` and PDFKit.
  - Show a reply bar when replying.
  - Send `composing` while typing, throttled, and `paused` 5s after the last keystroke.
  - **Optimistic send:** insert the message as `pending`, update it to `sent` or `failed` from the bridge result, and show a retry option on failures.
- **Onboarding:** a centered glass card showing the QR code (generated with `CIQRCodeGenerator`, refreshed when the bridge rotates it) and a "Link with phone number instead" option that shows the 8-character code. After pairing it shows sync progress ("Syncing chats… n conversations"), and the main window becomes usable as soon as the first chunk has landed.
- **Command bar (⌘K):** a non-activating `NSPanel` (`.borderless`, `.nonactivatingPanel`, `canBecomeKey = true`) positioned over the main window, hosting a SwiftUI view with `.glassEffect`.
  - **Search:** fuzzy search over chat names, contact names, push names, and phone numbers, from SQL plus in-memory scoring.
  - **Ranking:** a recency and usage store.
  - **Keys** (through a local `NSEvent` monitor active only while the panel is key): ↑/↓, ⌃J/⌃K, ⌃N/⌃P, Enter to open, and Esc to close.
  - A `CommandRegistry` of actions ("Archive chat", "Mute chat", "Mark unread", "Log out", …) is included now so actions can be added cheaply later.
- **Shortcuts:** all go through `NSMenu` items, so they appear in the menu bar and in Help search.

  | Shortcut | Action |
  |---|---|
  | ⌘K | Command bar |
  | ⌘N | New chat (opens the command bar scoped to contacts) |
  | ⌘1…9 | Pinned chat 1–9 |
  | ⌃Tab / ⌃⇧Tab, ⌘] / ⌘[ | Next / previous chat in the list |
  | ⌥↑ / ⌥↓ | Next / previous unread chat |
  | ⌘⇧U | Toggle unread |
  | ⌘⇧A | Archive |
  | ⌘⇧M | Mute |
  | ⌘⇧P | Pin |
  | Esc | Clear reply or edit state; a second press focuses the chat list |
  | ⌘F | Reserved for message search (post-v1); disabled for now |
  | ⌘⇧O | Attach file |
  | Space (list focused) | Quick Look on the selected media |

  Typing any printable character while the chat list is focused moves focus into compose.

## Milestones

Each milestone ends with its acceptance checks passing. Commit per milestone; start by running `git init` in `better-wa`.

**M0 — Scaffold.**
- Tasks: create `project.yml`, the three packages, the Rust workspace, and `build-bridge.sh`. Add a UniFFI "hello" function called from the app.
- Acceptance: `xcodegen && xcodebuild -scheme BetterWA build` succeeds, the app launches, and it logs the Rust hello string.

**M1 — Bridge.**
- Tasks: pairing (QR and code), `connect` through `bot.spawn`, ordered event delivery with batching, LID→PN canonicalisation, mapping edits and revokes (including decrypting encrypted edits), poll-vote decryption, `sendText`, `downloadMedia`, `markRead`, `remuxOggToCaf`.
- Acceptance:
  - `wa-cli` links a real account by QR in the terminal and streams events as JSON lines, with `events_dropped == 0`.
  - It sends a text.
  - An edit made on the phone shows up as `editOf`, and a delete-for-everyone shows up as `revoked`.
  - It downloads one image and one voice note, and the remuxed `.caf` plays with `afplay`.

**M2 — Data.**
- Tasks: schema and migrations, `IngestActor`, history sync into rows, contacts and push names, group metadata fetched in batches for group chats, avatars cached lazily.
- Acceptance: after linking, `app.sqlite` has chats with correct names and last messages, and message counts are plausible compared with the phone. No duplicate chat exists for the same person under an LID and a phone number. Ingesting a 50k-message history keeps memory under 300 MB. Swift Testing covers the ingest mapping, alias merging, receipt and unread rules, and out-of-order tolerance (a revoke or edit arriving before its original is applied when the original is inserted), using recorded bridge fixtures.

**M3 — Onboarding and shell.**
- Tasks: onboarding flow, window, rail, chat list with live updates, context menu actions, and logout.
- Acceptance: a first launch shows the QR code, and linking lands in a populated, live-updating chat list. Scrolling a list of 2k+ chats shows no hitches longer than one frame in Instruments' Animation Hitches template.

**M4 — Chat view.**
- Tasks: message list, every receive kind above, compose with text send, replies, reactions, receipts, typing, edit, and delete for everyone.
- Acceptance:
  - Opening any chat renders its first frame with content and without a visible layout jump.
  - Scrolling back through 5k messages has no hitches in Instruments.
  - Incoming messages appear within one frame of ingest.
  - Voice notes play.
  - Documents open in Quick Look.

**M5 — Sending media.**
- Tasks: attachment tray, paste and drag in, sending images, videos, GIFs and documents with captions, and upload progress.
- Acceptance: each type arrives correctly on the phone (thumbnail, dimensions, duration, filename, and playable or openable).

**M6 — Command bar and shortcuts.**
- Tasks: the ⌘K panel, the registry, and the full shortcut table.
- Acceptance: every shortcut in the table works and is listed in the menus, and ⌘K → type → Enter opens the chat.

## Performance rules

These rules apply everywhere, adapted from Inline's `AGENTS.md`:

- No database, network, file I/O, or attributed-string building inside `tableView(_:viewFor:row:)` or `heightOfRow`. Everything is precomputed in plans.
- Never re-query the open chat's message window on every write. Apply the change feed.
- No `.receive(on: .main)` hop after an observation whose first value is needed for the first render.
- Decode images off the main thread, at display size.
- Profile the open-chat, send, and scroll paths with `os_signpost` points of interest. Check them in Instruments whenever those paths change.

## Out of scope for v1

Sending voice notes, calls, status/stories, message search UI (FTS is populated, but there is no UI), tags UI, notifications beyond a basic `UNUserNotificationCenter` banner for non-muted chats (optional stretch goal in M4), multiple accounts, communities and newsletters, and polls beyond read-only display.

## Risks

- **Ban risk:** WhatsApp can ban accounts that use unofficial clients. Behave like a linked device: don't spam presence subscriptions, and throttle chat-state updates.
- **API churn:** whatsapp-rust is pre-1.0. Upgrade the pinned commit deliberately and keep all whatsapp-rust types inside `wa-bridge`.
- **History sync timing:** sync is best-effort and chunked over minutes, so the UI must tolerate a chat list that keeps filling in.
- **Voice-note remux:** the Ogg→CAF remux is custom code and is verified early in M1 with a real voice note.
