# Zompado — build plan

**Pronunciation:** zomp-ah-doh

**Status:** Android prototype available. The first release below is the target scope.
**First platform:** Android. Windows, macOS, and Linux follow using the same game packages.  
**Product goal:** Open one app to talk with friends, find a game, and play together. Install a game once and play solo offline where supported, or invite someone from an existing conversation.

## Current Android builds

| Build | Scope |
|---|---|
| Public APK | Official `.zomp` downloads, offline Drop Four, and the local chat preview. |
| Chatmail developer preview | Display-name setup, SecureJoin QR and shareable copy-and-paste invites, encrypted one-to-one message threads, unread badges, and queued or failed send feedback. The chat core owns the profile and messages in private Android storage. |
| Still open | Two-Android-device validation, QR camera scanning, 16 KB Android compatibility for the bundled core, background alerts, calls, remote matches, isolated LÖVE, and manual `.love` import. |

Chatmail Core 2.69.0 supplies the messaging protocol and relay transport. Zompado uses the verified official ARM64 JSON-RPC executable and its published [source and license](https://github.com/chatmail/core/tree/v2.69.0). The account is separate from saved games and old local preview messages.

The [live relay test](https://github.com/JustTrySomthing/zompado/actions/runs/44613099059) configured two fresh Chatmail Core profiles, established their encrypted conversations through SecureJoin, and verified messages in both directions. The test used the Linux build of the same Core release. Android installation and delivery still need device verification.

### Verify the Chatmail preview

Install the signed preview on two ARM64 Android phones with 4 KB memory pages. Open **Chats** and create a profile on each phone. On the first phone, tap **Invite friend**, then copy or share its link. On the second phone, use **Accept invite** and wait for the connection to finish. Exchange messages both ways, check unread badges when the conversation is closed, then restart both apps and verify that the chats and Drop Four saves persist. Keep both apps open for initial validation.

Repeat on Wi-Fi and mobile data. Confirm that the sending state clears when the server accepts a message, that status changes do not duplicate messages, and that the profile remains usable offline and after reconnecting. Verify voice calls and online turns separately after this baseline is proven.

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
| Player | Bundle a pinned native LÖVE runtime once per platform. Adapt the Android Java/SDL loader with Kotlin where needed. Test native rendering, docked chat, and keyboard together. |
| Package | One portable `.zomp` ZIP archive per official game version, with a root `zompado.json` manifest for game ID, version, runtime, entry point, and supported modes. Compatible plain `.love` files are a separate manual solo import. Friend matches require the turn API. |
| Communication | Bundle Chatmail Core, using JSON-RPC where supported. Reuse the Relay Lab approach for verified contacts and encrypted chat. Call setup uses Chatmail and audio uses native WebRTC. Confirm the selected Core exposes the needed call operations and verify TURN fallback on the intended relay. |
| Isolation | Prototype a permissionless Android isolated player. Give it access to the selected game, input, rendering, and narrowly scoped saves and moves. Keep chats, contacts, microphone, and networking with the host. Validate archive paths, expanded size, and compatibility before install. LÖVE plus an ordinary Android activity is insufficient for isolating downloaded Lua. |
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
