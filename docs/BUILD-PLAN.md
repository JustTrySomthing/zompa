# Android game and chat app — build plan

**Status:** Proposed for review before implementation  
**First platform:** Android. Windows, macOS, and Linux follow using the same game packages.  
**Product goal:** Open one app to talk with friends, find a game, and play together. Install a game once and play solo offline where supported, or invite someone from an existing conversation.

## First release

| Area | What players can do |
|---|---|
| **Chats** | Send one-to-one Chatmail texts, start a voice call, and see clear indicators for new texts, missed calls, invites, and turns. Game transfers and matches appear as cards in the conversation. |
| **Friends** | Use the familiar Relay Lab Invite and Accept flow with QR and shareable links or codes. Show clear success and failure states. A friend invite establishes a contact. A match invite starts a particular game. Verify compatibility before reusing Relay Lab code. |
| **My Games** | See installed games in a two-column library. Play or resume, see supported modes, and use a Your turn shortcut to resume a match. Solo saves are separate from friend matches. |
| **Get Games** | Browse the official GitHub catalog from inside the app. See cover art, size, supported modes, and Install or Update. |
| **Shared and imported games** | Send an eligible installed game in chat or import a downloaded file using the Games header icon and Android file picker. The same preview shows title, size, source, and compatibility across all install paths. Download & install and Install & join lead into the library or match. |
| **While playing** | In a friend match, a chat button with an unread dot opens the existing conversation in a bottom dock. The keyboard appears only when the field is tapped. Close the dock to dismiss the keyboard and return to the same board and unsubmitted move. A small call bar keeps Mic mute, Audio output, and End call available. |
| **Later releases** | Desktop chat can dock beside a game and remember whether it was open. The conversational AI creator generates a game from a template, previews it, accepts revisions, and saves the same shareable package to My Games. Model hosting and costs are a separate decision. |

The six-screen mockup is the visual reference. Use Chats and Games as the two bottom destinations, with My Games and Get Games inside Games. Retain the slate, warm yellow, and lavender direction. Pair activity dots with readable text or accessible labels. Let people try solo play without setting up Chatmail. Ask for permissions when the corresponding feature is used and explain how to recover from a denial.

## Settings and defaults

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
| Package | One portable .love file per game version. A platform manifest defines stable game ID, version, compatible API/runtime, and supported modes. Compatible plain .love files can be solo imports. Friend matches require the turn API. |
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
