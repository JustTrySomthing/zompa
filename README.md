# Zompado for Android

Play Drop Four against the computer or take turns on the same phone. Install official games from **Games → Get Games**.

- [Download the Android ARM64 APK](https://github.com/JustTrySomthing/zompado/releases/latest)
- [Official games and standalone cartridges](https://github.com/JustTrySomthing/zompado-games)
- [Build plan](docs/BUILD-PLAN.md)
- [Brand kit and production assets](docs/brand/README.md)
- [Resume this project from GitHub](docs/RECOVERY.md)

## Updates

Zompado checks GitHub automatically on launch when due and about daily in the background when Android permits. You can also use **Settings → Check for updates**. The app verifies the downloaded APK and opens Android’s installer for confirmation. If you have a build from before Zompado 0.3.0, install the APK from Releases over your existing app to move to the new update and game feeds.

The game catalog comes from the separate games repository. The app downloads and verifies the versioned Drop Four package before adding it to My Games. The current Android prototype uses its built-in Drop Four player. The isolated LÖVE player, Chatmail, and online friend matches are future milestones.

## Build

Use Flutter 3.50.0, JDK 21, and Android SDK 36.

```sh
flutter pub get
flutter build apk --release --target-platform android-arm64
```

For an updateable release, set `ZOMPADO_KEYSTORE`, `ZOMPADO_KEYSTORE_PASSWORD`, `ZOMPADO_KEY_ALIAS`, and `ZOMPADO_KEY_PASSWORD` to the existing signing identity. Never commit keystores or credentials. Debug-signed builds cannot update the distributed APK. Keep the application ID and signer stable and increment the Android version code.

See [recovery and signing setup](docs/RECOVERY.md) and [release instructions](docs/RELEASE.md).
