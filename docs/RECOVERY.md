# Resume Zompado from GitHub

Clone the Android app and, if the task touches games or the catalog, clone the games repository beside it.

```sh
git clone https://github.com/JustTrySomthing/zompado.git
git clone https://github.com/JustTrySomthing/zompado-games.git
cd zompado
```

Both repositories use `main`. Check the latest published APK and the current `update.json` before selecting a release version. The prototype was previously called Table Circle. Its Android package remains `io.tablecircle.prototype`.

| What you need | Where to look |
|---|---|
| Android source at the tag for a shipped version | [Android releases](https://github.com/JustTrySomthing/zompado/releases) |
| App updater feed, native Android bridge, and download validation | [update.json](../update.json), [Android sources](../android/app/src/main/java/io/tablecircle/prototype), [install controller](../lib/app_updates.dart), [GitHub distribution code](../lib/github_distribution.dart) |
| Official .zomp catalog, versioned LÖVE sources, and release assets | [zompado-games](https://github.com/JustTrySomthing/zompado-games) |
| Voice calls and scheduled Android chat alerts | [Call state and UI](../lib/voice_calls.dart), [Android WebRTC bridge](../android/app/src/main/java/io/tablecircle/prototype/VoicePeer.java), [Chat sync job](../android/app/src/main/java/io/tablecircle/prototype/ChatSyncJob.java), [relay verification workflow](../.github/workflows/verify-chatmail-relay.yml) |
| Manual `.zomp` and `.love` imports and Lua template | [Android archive validation](../android/app/src/main/java/io/tablecircle/prototype/LoveImport.java), [Lua SDK](../sdk/README.md) |
| Embedded LÖVE and online match validation | [Runtime pin and hashes](../tools/install_love_runtime.sh), [Android player](../android/app/src/main/java/io/tablecircle/prototype/LovePlayer.java), [Flutter view](../lib/love_player.dart), [match validation](../lib/online_match.dart) |
| Game audio and Android test workflow | [Flutter settings](../lib/game_audio.dart), [Lua mixer](../sdk/zompado.lua), [Android emulator workflow](../.github/workflows/android-game-smoke.yml) |
| Contacts, self profile, and chat composer | [Contact list](../lib/contacts_page.dart), [Chatmail profile editor](../lib/profile_page.dart), [composer and invites](../lib/friends.dart) |
| Two-device Android verification | [Emulator workflow](../.github/workflows/android-friends-smoke.yml), [verification script](../tools/check_android_friends.py) |
| Implemented features and next milestones | [README](../README.md), [build plan](BUILD-PLAN.md) |
| Public download page | [GitHub Pages source](index.html), published from `main:/docs` |
| Release preparation and feed update order | [RELEASE.md](RELEASE.md) |

The Android app ships the LÖVE 11.5 compatibility WebAssembly runtime inside the APK. Players install and remove their games separately. The catalog uses `games` for current entries and `archive` for exact older shared links. The player opens the selected package in a sandboxed Android WebView renderer with a private origin per game. Playback requires Android 10 or later and a multiprocess WebView provider. The Gradle build fetches two pinned runtime files, checks their hashes, and packages them with the player assets. The version 1 catalog is kept for older APKs. The new Drop Four starts its own Lua save when upgrading from the Dart game. Chatmail and the remaining user-facing milestones are described in the [build plan](BUILD-PLAN.md). The public APK and the developer preview can be on different versions.

Cats vs Dogs retains the `drop-four` game ID for saves and older match links. Starting with game build 8, the catalog title and .zomp filename use Cats vs Dogs. The catalog card uses the original OnKlav faceoff illustration bundled in `assets/games/cats-vs-dogs.webp`.

The match invitation opens a waiting screen for the sender. The recipient’s Accept action sends a preparation status, gets the required game from the catalog if needed, then signals readiness. Both players can select Play Now. Pause and resume are tracked per player. Quit ends the match for both. The online match list is available from My Games and the Play menu.

The [signed 0.5.17 preview, build 26](https://github.com/JustTrySomthing/zompado/actions/runs/44793737081/artifacts/14657163426) was built from `a01b68b`. **Settings → Appearance** includes a live preview for message text size. The call receiver can send an answer after a short relay-gathering grace period when the caller offers a UDP relay and the receiver has a local UDP candidate. **Settings → App Log** records the answer tap, Chatmail signaling, and WebRTC connection separately. See the [two-device Android check](https://github.com/JustTrySomthing/zompado/actions/runs/44793737065). The APK SHA-256 is `06dfe14be15954067f34f5ac1e3bcdfcb6af41feb0d66177f61aae817d2b4cc7`.

The [signed 0.5.16 preview, build 25](https://github.com/JustTrySomthing/zompado/actions/runs/44780613871/artifacts/14652623501) was built from `925766d`. The release APK now retains WebRTC’s Java bindings used by JNI. The [APK verifier](../tools/verify_webrtc_apk.py) rejected the previous signed preview’s DEX and passed on this signed APK. **Settings → App Log** captures call startup, Android and Flutter error types, and available historical native backtraces. Its Copy Log and Clear Log controls work on the app’s local log. See the [emulator App Log check](https://github.com/JustTrySomthing/zompado/actions/runs/44785312955) and [Delta Chat interoperability check](https://github.com/JustTrySomthing/zompado/actions/runs/44782843024). The APK SHA-256 is `baf60cd56b822ce946fe7ad89839c63f04e02653d665ae030126344b0b4bbd1f`.

The [signed 0.5.15 preview, build 24](https://github.com/JustTrySomthing/zompado/actions/runs/44774718338/artifacts/14649262708) was built from `4db3304`. It adds the global Saved collection, Chatmail reactions, chat list actions, contact pins, and per-category notifications. The paperclip uses Core image quality and Android AAC/H.264 preparation for audio and video. Attach Original File bypasses those media changes. Setup links to Android lock-screen notification controls. See [the Android friends check](https://github.com/JustTrySomthing/zompado/actions/runs/44777572888) and [the Delta Chat check](https://github.com/JustTrySomthing/zompado/actions/runs/44777300379). The preview APK’s SHA-256 is `fc47177b8d14c4bd35df5dd9a7543e2c048961b849d78d63b240d50d756476cf`.

The [signed 0.5.14 preview, build 23](https://github.com/JustTrySomthing/zompado/actions/runs/44756954682/artifacts/14639242713) adds Contacts, the Chatmail self-profile editor, attachments and emoji, and the match readiness and pause flow. The APK was built from commit `4ada3df`. Its SHA-256 is `e18090bf0d08e70d14725f4e0448d10966c1c8c465b91776154c3739410ae389`. The [Android game smoke test](https://github.com/JustTrySomthing/zompado/actions/runs/44756955086) passed on that build. The [two-device Android check](https://github.com/JustTrySomthing/zompado/actions/runs/44759755448) passed invitations, turn exchange, synchronized pause and resume, quitting, and reopening the board from a background alert. The [stock Delta Chat check](https://github.com/JustTrySomthing/zompado/actions/runs/44759483369) passed messages and calls in both directions, including Delta Chat video displayed by Zompado.

The [signed 0.5.13 calling preview, build 20](https://github.com/JustTrySomthing/zompado/actions/runs/44734662303/artifacts/14628706186) uses Chatmail Core signaling, Relay Lab’s UDP/TCP fallback for Chatmail TURN URLs, and the negotiated Delta Chat ICE and mute-state channels. See the [two-Zompado test](../.github/workflows/android-friends-smoke.yml) and [stock Delta Chat test](../.github/workflows/android-delta-chat-smoke.yml) for device coverage. The camera starts on user action and stops when the activity leaves the foreground. The [build 20 Android test](https://github.com/JustTrySomthing/zompado/actions/runs/44734662285) verified answering with the chat composer focused, video frames, controls, hangup, and the online game flow.

The Android friend invite scanner uses the bundled ZXing decoder and the Android Camera permission. Setup offers this permission, and the scanner also requests access when first used. Paste remains available on devices without a camera.

For instant Android wakeups, Zompado needs an authorized push registration for `io.tablecircle.prototype` and a compatible Chatmail notifier that can send to that registration. The pinned Core has a push token API in its native interface; Zompado's JSON-RPC bridge would need to expose it. Keep provider credentials with the notifier. Current builds use Android's scheduled fetch. [Chatmail push behavior](https://delta.chat/en/help#instant-message-delivery-and-push-notifications).

## Toolchain and fresh checkout

Use JDK 21, Android platform and Build Tools `36.0.0` (SDK platform `android-36`), NDK `28.2.13676358`, and Python 3.11 or newer for the feed generator. The ARM64 Chatmail executable is built on Linux from its pinned upstream source with Cargo 1.95.0 via rustup. Install rustup, a C build toolchain, and Perl for vendored OpenSSL. CI checks 16 KB ELF alignment for every packaged ARM64 library. The Gradle wrapper pins Gradle 9.5.0, and Android Gradle Plugin 9.3.1 is declared in `android/settings.gradle.kts`.

The 0.3.0 build used Flutter 3.50.0 candidate revision `ab2912035e160d9cad6306df307576da6128ebdb`, with engine `371f77202a73e8dff57a8b3bff75bca55c090aee` and Dart 3.14.0. Use the framework revision in [the workflow](../.github/workflows/android-release.yml) to reinstall it. With Flutter on PATH and SDK licenses accepted:

```sh
flutter pub get --enforce-lockfile
flutter analyze
flutter build apk --release --target-platform android-arm64 --no-pub
```

Flutter creates `android/local.properties` for the local SDK paths. Gradle needs access to the Gradle Plugin Portal, Google Maven, and Maven Central. The 0.3.0 APK was packaged on a constrained runner after Gradle dependency resolution failed there. Use a network-enabled build runner for the Gradle build and verify the result against the shipped APK's identity before release.

## Android signing and key custody

| Setting | Value |
|---|---|
| Package | `io.tablecircle.prototype` |
| Distribution ABI | `arm64-v8a` |
| Certificate subject | `CN=Table Circle Prototype` |
| Certificate SHA-256 | `d55fa5cc439bc4abfbf914e32675728de84c3267d2a86ec59c91781ff1bb39b8` |
| Public reference APK | [Zompado 0.5.14, build 23](https://github.com/JustTrySomthing/zompado/releases/tag/v0.5.14) |

The public APK contains the certificate. Signing future updates requires the original private key and its credentials. Never put the private material in commits, issues, logs, or release assets. The verified certificate also matches the Table Circle 0.2.0 APK.

The original signing key is stored in the `android-release` GitHub Actions environment with the other three signing secrets. The environment accepts deployments from the `main` branch only. The [signed Android build](../.github/workflows/android-release.yml) uses the key on GitHub and verifies its fingerprint before producing an APK. A fresh session can start this workflow from GitHub without recovering a local keystore. To publish through the connected GitHub account without a CLI sign-in, follow the explicit release request in [RELEASE.md](RELEASE.md). [Verified 0.5.12 release](https://github.com/JustTrySomthing/zompado/actions/runs/44725039586).

The environment uses these secrets. If a repository administrator has to restore it from a backup, configure the environment under **Settings → Environments** with a `main` branch restriction before loading the original signing credentials.

| GitHub Actions secret | Contents |
|---|---|
| `ZOMPADO_KEYSTORE_BASE64` | Base64 of the original signing keystore |
| `ZOMPADO_KEYSTORE_PASSWORD` | Keystore password |
| `ZOMPADO_KEY_ALIAS` | Original signing key alias |
| `ZOMPADO_KEY_PASSWORD` | Key password |

With authenticated GitHub CLI admin access, the binary secret can be loaded without putting its contents on screen, then the other three supplied at the hidden prompts.

```sh
base64 -w 0 /secure/path/zompado.keystore |
  gh secret set ZOMPADO_KEYSTORE_BASE64 -R JustTrySomthing/zompado -e android-release
for name in ZOMPADO_KEYSTORE_PASSWORD ZOMPADO_KEY_ALIAS ZOMPADO_KEY_PASSWORD; do
  gh secret set "$name" -R JustTrySomthing/zompado -e android-release
done
```

Run **Actions → Build signed Android APK → Run workflow** on `main`, or use the authenticated GitHub CLI. Download the `zompado-signed-android` artifact from a successful run. The workflow leaves Releases and the update feed untouched. Keep an owner-controlled encrypted backup of the same key and credentials to recover if the repository or Actions secrets are lost.

```sh
gh workflow run android-release.yml --ref main -R JustTrySomthing/zompado
```

For local signing, set the same three credentials and set `ZOMPADO_KEYSTORE` to the secure local keystore path before building. See [RELEASE.md](RELEASE.md) for verification. A fresh debug or release key changes the APK signature and breaks updates over the existing install.
