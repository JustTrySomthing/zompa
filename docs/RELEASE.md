# Android releases

[Download the latest Android APK](https://github.com/JustTrySomthing/zompa/releases/latest/download/Zompa-ARM64.apk)

To publish an update, increase the version and build in `pubspec.yaml` and `lib/app_updates.dart` and update [.github/release-request.json](../.github/release-request.json) on `main`. The Android release workflow builds and signs the APK, then uploads `Zompa-ARM64.apk` and its generated `update.json` to the same GitHub release before marking it latest. After verifying the public download and metadata, the workflow copies the metadata to the repository root for older installed apps. Both feeds are generated from the signed APK.

If a publish job fails, rerun the failed jobs to reuse the signed artifact. See [the recovery guide](RECOVERY.md) for the signing identity and build environment. Use the [games repository](https://github.com/JustTrySomthing/zompa-games) to publish game packages.

The app checks the APK size and SHA-256 before installation. Android verifies the package and signing identity when installing the update.
