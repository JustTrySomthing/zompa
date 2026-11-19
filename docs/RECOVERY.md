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
| Voice calls and scheduled Android chat alerts | [Call state and UI](../lib/voice_calls.dart), [Android WebRTC bridge](../android/app/src/main/java/io/tablecircle/prototype/VoicePeer.java), [Chat sync job](../android/app/src/main/java/io/tablecircle/prototype/ChatSyncJob.java) |
| Manual `.love` staging and Lua template | [Android archive validation](../android/app/src/main/java/io/tablecircle/prototype/LoveImport.java), [Lua SDK](../sdk/README.md) |
| Board rules and UI | [board.dart](../lib/board.dart), [main.dart](../lib/main.dart) |
| Implemented features and next milestones | [README](../README.md), [build plan](BUILD-PLAN.md) |
| Public download page | [GitHub Pages source](index.html), published from `main:/docs` |
| Release preparation and feed update order | [RELEASE.md](RELEASE.md) |

The Android prototype uses a built-in Drop Four player and installs verified official `.zomp` packages from the version 2 game catalog. The version 1 catalog is kept for older APKs. The Chatmail developer preview and remaining user-facing milestones are described in the [build plan](BUILD-PLAN.md). The public APK and the developer preview can be on different versions.

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
| Public reference APK | [Zompado 0.3.0, build 3](https://github.com/JustTrySomthing/zompado/releases/tag/v0.3.0) |

The public APK contains the certificate. Signing future updates requires the original private key and its credentials. Never put the private material in commits, issues, logs, or release assets. The verified certificate also matches the Table Circle 0.2.0 APK.

The original signing key is stored in the `android-release` GitHub Actions environment with the other three signing secrets. The environment accepts deployments from the `main` branch only. The [signed Android build](../.github/workflows/android-release.yml) uses the key on GitHub and verifies its fingerprint before producing an APK. A fresh session can start this workflow from GitHub without recovering a local keystore. To publish through the connected GitHub account without a CLI sign-in, follow the explicit release request in [RELEASE.md](RELEASE.md). [Verified build](https://github.com/JustTrySomthing/zompado/actions/runs/44603090929).

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
