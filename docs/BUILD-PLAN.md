# Zompado — build plan

**Pronunciation:** zomp-ah-doh

**Status:** Android prototype available. The first release below is the target scope.
**First platform:** Android. Windows, macOS, and Linux follow using the same game packages.  
**Product goal:** Play, share and chat with friends. Discover fun and unique games, or make your own. Install a game once and play solo offline where supported, or invite someone from an existing conversation.

## Current Android builds

| Build | Scope |
|---|---|
| [Public APK 0.5.9](https://github.com/JustTrySomthing/zompado/releases/tag/v0.5.9) | Built-in LÖVE player, official `.zomp` downloads, manual `.love` imports, encrypted friend chats, voice calls, online turns, and scheduled alerts. |
| Chatmail developer preview | Display-name setup, SecureJoin QR and shareable copy-and-paste invites, encrypted one-to-one message threads, unread badges, and queued or failed send feedback. The chat core owns the profile and messages in private Android storage. Installed Drop Four can be shared by link or sent as a game card in friend chats. Receivers verify the exact catalog version before installing. Online Drop Four adds match invites, alternating turns, and match recovery from the conversation history. |
| [Preview 0.5.5](https://github.com/JustTrySomthing/zompado/actions/runs/44631165902#artifacts) | Camera QR scanning through Google Play services with a paste fallback. Online Drop Four has a conversation dock and a Your turn shortcut in My Games. Friend activity can trigger private Android alerts while the app stays running in the background. The Games file picker checks and stores manually selected `.love` files. The first [Lua SDK](../sdk/README.md) includes saves, music and effects controls, and a sample game. |
| [Preview 0.5.6](https://github.com/JustTrySomthing/zompado/actions/runs/44635690236#artifacts) | One-to-one voice calls from a friend chat, an app-wide call bar, and scheduled friend activity notifications after Android closes Zompado’s process. |
| [Preview 0.5.7](https://github.com/JustTrySomthing/zompado/actions/runs/44641489452#artifacts) | Built-in LÖVE playback of downloaded official `.zomp` games and manual `.love` imports. New libraries start empty. Games install and remove individually. Drop Four 1.2.1 provides solo, pass and play, and online mode. |
| [Preview 0.5.8](https://github.com/JustTrySomthing/zompado/actions/runs/44646518299#artifacts) | Persistent game volume, Music, and Sound effects controls from Settings and the player. Games on the SDK use separate buses, and other imports have master volume. |
| Android 0.5.9 | Mute and automatic game-volume lowering during calls. Scheduled Chatmail fetch can surface a live call and recover it when the alert is opened. Alerts open the matching conversation or Drop Four match. A match opened from its alert or Your turn starts the board when the exact game version is installed. |

Chatmail Core 2.69.0 supplies the messaging protocol and relay transport. Preview 0.5.5 compiles the ARM64 JSON-RPC executable with NDK r28. All native code in the APK passed the 16 KB ELF alignment check. See the published [source and license](https://github.com/chatmail/core/tree/v2.69.0). The account is separate from saved games and old local preview messages.

The [live relay test](https://github.com/JustTrySomthing/zompado/actions/runs/44613099059) configured two fresh Chatmail Core profiles, established their encrypted conversations through SecureJoin, and verified messages in both directions. The test used the Linux build of the same Core release. Android installation and delivery still need device verification.

The [0.5.6 live relay test](https://github.com/JustTrySomthing/zompado/actions/runs/44634766582) verified encrypted call offers, answers and hangup. A separate Core process detected fresh encrypted activity after restarting the receiving profile. Android audio and notification delivery still require device tests.

The [Android emulator run](https://github.com/JustTrySomthing/zompado/actions/runs/44646518195) verified first-run setup, an empty library, catalog download, LÖVE touch input, save restoration after restarting, and game removal. The [live relay run](https://github.com/JustTrySomthing/zompado/actions/runs/44646518262) verified that two profiles recovered each other’s moves for Drop Four build 5. The x86_64 emulator workflow exercises the library and player. The relay workflow exercises the messaging backend.

The [scheduled call recovery test](https://github.com/JustTrySomthing/zompado/actions/runs/44650633673) delivered an encrypted text and voice offer while the recipient's Chatmail process was stopped. A background Core fetched both and a new foreground Core answered and ended the call. A desktop Chromium check used the embedded LÖVE runtime to load a manual `.love` game with an imported Lua module, PNG, font, Ogg audio, touch input, and an IndexedDB save that survived reload. A source-only replay check recovered the same complete Drop Four match and winner from both players' histories with out-of-order and duplicate records. Android end-to-end calls, notification behavior, and match navigation still need device verification.

A source-level alert check resolved an exact Drop Four move, reopened an alert for an already-read message, and rejected mismatched messages, unencrypted chats, and contact requests. Two desktop WebRTC peers passed a loopback Opus audio check for two-way playback, mute, and restore. Android microphone and speaker routing, TURN across separate networks, and tapping notifications on-device still need verification.

### Verify the Chatmail preview

Install the signed preview on two ARM64 Android phones. Use a 16 KB Android phone or emulator for the new alignment check. Open **Chats** and create a profile on each phone. On the first phone, tap **Invite friend**, then copy or share its link. On the second phone, use **Accept invite**, scan the QR code or paste an invite link, and wait for the connection to finish. Exchange messages both ways, check unread badges when the conversation is closed, then restart both apps and verify that the chats and Drop Four saves persist. Keep both apps open for initial validation.

Repeat on Wi-Fi and mobile data. Confirm that the sending state clears when the server accepts a message, that status changes do not duplicate messages, and that the profile remains usable offline and after reconnecting.

- In an online Drop Four match, send a message from the chat dock, close it, and play a turn. On the other device, open **Games → My Games → Your turn** and confirm that it opens the same board.
- Tap notifications from two different conversations and check that each opens its own chat. Tap a turn alert while another game is open, then use Back to return to it. With the recipient's process stopped, repeat from a scheduled alert. Check that a match opens its installed board and offers installation for a missing version.
- Allow notifications and microphone access in **Settings → Setup**. Place, answer, decline, and end calls from two phones. Verify two-way audio, mute, speaker, and that calls stay active while returning to a game or locking the phone. Try with each phone on a different network.
- Background the receiving phone and send an encrypted message. Repeat after Android has stopped the receiving process. Use `adb shell am kill io.tablecircle.prototype` on a backgrounded preview for process-death testing. Inspect the Android job with `adb shell dumpsys jobscheduler`. The periodic check has a 15-minute nominal interval, requires a network, and may be deferred. A manual **Force stop** pauses delivery until the app is reopened.
- Open **Games → Import a .love game** with a valid archive and a damaged archive. The valid file should appear once, run in the player, and be removable. The damaged archive should show an error.
- On a 16 KB test device, check that `adb shell getconf PAGE_SIZE` returns `16384` before testing Chatmail startup, an invite, and two-way messaging. The build-time ELF check verifies alignment. The phone test verifies execution.

### Android implementation notes

**Calls.** Chatmail Core carries offer and answer SDP for encrypted one-to-one calls. Android WebRTC `150.7871.01` carries audio. The call’s microphone foreground service is active while connecting and talking. Use the relay’s advertised ICE servers. Android delivery tests still need to cover relay candidate availability and real audio routing. [Pinned RPC implementation](https://github.com/chatmail/core/blob/v2.69.0/deltachat-jsonrpc/src/api.rs).

**Process-death alerts.** Android runs the persisted `ChatSyncJob` on a network at a 15-minute nominal interval. It opens the existing Chatmail profile only while the app does not own it. The job uses Chatmail's bounded `background_fetch` before checking `get_fresh_msgs`. Private alerts respect muted chats and exclude contact requests. A still-ringing voice call can post a dedicated alert with its remaining ringing window. Tapping it reopens the profile and checks the original offer before presenting Answer and Decline. Android can defer the job, so a call may already be missed when the check runs. Reopening the app resumes checks after a manual force stop. The pinned Core's built-in push requires a platform push token and the JSON-RPC interface used by Zompado does not register one. Real-time wakeups after process death remain a transport decision.

**LÖVE.** Android embeds pinned LÖVE 11.5 compatibility binaries from love.js. Android verifies the selected archive and serves it with the player assets to a private synthetic HTTPS origin in a sandboxed WebView renderer. The game has no JavaScript-to-native bridge. External requests, file access, and WebView permission requests are blocked. The renderer must be separate from the app process before the game archive is released. The host sends the online board state and reads the selected column, then checks turn and move legality before using Chatmail. WebView IndexedDB stores game saves by game origin. [Runtime source](https://github.com/Davidobot/love.js) · [Android WebView renderer](https://developer.android.com/develop/ui/views/layout/webapps/manage-webview-memory).

## First release

| Area | What players can do |
|---|---|
| **Chats** | Send one-to-one Chatmail texts, start a voice call, and see clear indicators for new texts, missed calls, invites, and turns. Game transfers and matches appear as cards in the conversation. |
| **Friends** | Use the familiar Relay Lab Invite and Accept flow with QR and shareable links or codes. Show clear success and failure states. A friend invite establishes a contact. A match invite starts a particular game. Verify compatibility before reusing Relay Lab code. |
| **My Games** | See installed games in a two-column library. Play or resume, see supported modes, and use a Your turn shortcut to resume a match. Solo saves are separate from friend matches. |
| **Get Games** | Browse the official GitHub catalog from inside the app. See cover art, size, supported modes, and Install or Update. |
| **Shared and imported games** | Send an eligible installed game in chat or import a downloaded file using the Games header icon and Android file picker. The same preview shows title, size, source, and compatibility across all install paths. Download & install and Install & join lead into the library or match. |
| **While playing** | In a friend match, a chat button with an unread dot opens the existing conversation in a bottom dock. The keyboard appears only when the field is tapped. Close the dock to dismiss the keyboard and return to the same board and unsubmitted move. A small call bar keeps Mic mute, Audio output, and End call available. |
| **Later releases** | Desktop chat can dock beside a game and remember whether it was open. The optional Game Builder is a separate download described below. |

The six-screen mockup is the visual reference. Use Chats and Games as the two bottom destinations, with My Games and Get Games inside Games. Follow the [approved Zompado brand kit](brand/README.md). Pair activity dots with readable text or accessible labels. Let people try solo play without setting up Chatmail. Ask for permissions when the corresponding feature is used and explain how to recover from a denial.

## Optional Game Builder

Stabilize and test gameplay, the game library, and the game SDK before starting the Game Builder. Distribute it as a separate, optional download. People will be able to chat with AI to create a game from a Zompado template, play a preview, ask for revisions, and save a shareable `.zomp` package to My Games. Use the same framework, SDK, and package format as the rest of Zompado. Decide model hosting and costs during Game Builder development.

## Settings and defaults

First-run Setup explains internet access and offers optional Android permissions for update alerts and in-app installation. Settings keeps Setup and searchable Help available after onboarding. Add future permissions alongside the features that use them.

- **Voice:** Mute mic, earpiece/speaker/headset routing, and hang up during calls. Support Android call volume buttons. Add a separate voice playback slider if it works reliably across the supported audio routes.
- **Game audio:** Music and Sound effects sliders, Mute game audio, and Lower game audio during calls enabled by default. Restore the previous game level when the call ends. Expose the controls from the pause menu. Official games and templates use a shared audio API. Compatibility imports may support overall volume only.
- **Appearance:** System, Light, or Dark, accent color, text size with preview, and reduced motion.
- **Profile and setup:** Display name, photo, invite QR and sharing, connection status, permissions help, backup or transfer. Explain what the backup includes and how game saves are handled.
- **Notifications and privacy:** Individual controls for texts, calls, invitations, and Your turn. Quiet hours, preview privacy, blocked contacts, and control over who can call or invite. In-app indicators remain visible during quiet hours.
- **Games and storage:** Installed sizes, downloads, uninstall, and a separate Delete saves choice. Keep saves by default and explain what uninstall means for ongoing matches.
- **Updates and help:** Automatic checks, Check for updates, installed version, release notes, and help for invites, background delivery, calls, and game installs.

## Architecture

| Layer | Decision |
|---|---|
| App | Flutter and Dart for shared UI, catalog, installation, and match state. SQLite and private files for library data, saves, and matches. Chatmail Core owns its own message store. |
| Player | Bundle LÖVE inside Zompado. The Android preview uses the LÖVE 11.5 WebAssembly compatibility runtime in a sandboxed WebView renderer. Test rendering, docked chat, and keyboard together. |
| Package | One portable `.zomp` ZIP archive per official game version, with a root `zompado.json` manifest for game ID, version, runtime, entry point, and supported modes. Compatible plain `.love` files are a separate manual solo import. Friend matches require the turn API. |
| Communication | Bundle Chatmail Core, using JSON-RPC where supported. Reuse the Relay Lab approach for verified contacts and encrypted chat. Call setup uses Chatmail and audio uses native WebRTC. Confirm the selected Core exposes the needed call operations and verify TURN fallback on the intended relay. |
| Isolation | Require a separate sandboxed Android renderer before serving a game. Give it only the selected archive, input, rendering, and narrowly scoped saves and moves. Keep chats, contacts, microphone, and networking with the host. Validate archive paths, expanded size, and compatibility before install. |
| Turns | Send small moves over Chatmail. Include match ID, move ID, sequence number, and an exact game version and hash. Validate sender, order, and move legality. Persist pending sends, apply each move once, and handle missing predecessors before replaying. |

## Independent GitHub release paths

**App.** Ship signed APKs from the app’s GitHub Releases. Automatic checks are on by default, on launch when due and roughly daily in the background as Android permits. **Settings → Check for updates** runs immediately and distinguishes up to date, update available, and check failed. Verify release metadata, APK identity, and signing certificate, then use Android’s installer and handle its confirmation. Establish a stable application ID and protect the signing key before distributing the first APK.

**Games.** Use a separate official games repository with a signed catalog index and versioned Release assets. Verify hashes, stage installs before replacing the active version, and keep saves. A game release needs no new APK. Active matches stay pinned to their exact version. Retain old packages so participants can still install a version needed for an open match. Test interrupted downloads and insufficient storage.

## Build order and release criteria

| Phase | Evidence needed |
|---|---|
| **1. Prove the player and communication** | On real Android hardware, render a LÖVE game in isolation. Open and close the dock and keyboard without losing the board. Exchange Chatmail texts and establish voice on two phones. Check incoming texts, turns, and calls with phones open, backgrounded, and locked. |
| **2. Build one full match** | Install Drop Four from the catalog. Play solo offline. Add a friend, invite them, take turns, and resume directly from a notification where supported. Reconnect after an interrupted send and confirm the move applies once. A call stays connected while entering and leaving the game. |
| **3. Finish installs and settings** | Install the same package from GitHub, chat, and the Android picker. Confirm audio routing, independent game volume controls, quiet hours, and saved settings. Reject incompatible or damaged packages cleanly. |
| **4. Verify release and recovery** | Upgrade one signed APK to the next and preserve profile, chats, saves, and matches. Verify manual and automatic checks. Release a game update independently, resume an old match, and start a new one with the newer package. Document reproducible build and signing-key recovery steps with the new project without committing secrets. |

**Unresolved before promising a release:** Background delivery without Firebase or a permanent notification can vary by Android device. Measure it across Wi-Fi and mobile data and distinguish delayed text/turn notifications from missed incoming ringing. If an optional wakeup method is needed, decide on it after seeing the results. Downloaded games require a working isolated player. Measure actual APK size and launch time from the prototype before establishing a size target.

## References

- [Flutter Android platform views](https://docs.flutter.dev/platform-integration/android/platform-views)
- [LÖVE Android source and loader](https://github.com/love2d/love-android)
- [Chatmail Core](https://github.com/chatmail/core)
- [Delta Chat notifications and calls](https://delta.chat/en/help)
- [Android isolated services](https://developer.android.com/guide/topics/manifest/service-element)
- [GitHub release assets](https://docs.github.com/en/rest/releases/assets)
