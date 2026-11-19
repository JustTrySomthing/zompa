# Releases

1. Increase the version and Android build code in `pubspec.yaml`. Set `installedVersion` and `installedBuild` to the same values in `lib/app_updates.dart`.
2. Build a signed ARM64 APK using [the GitHub Actions workflow or the original local keystore](RECOVERY.md). Run `bash tools/verify_release_apk.sh APK X.Y.Z BUILD` against the candidate. The script checks the published certificate fingerprint, package, version, build, and ABI. Install the APK over the previous public build on a test device and check that saved data survives.
3. Publish the APK to GitHub Releases under the matching `vX.Y.Z` tag at the commit used to build it. Use the filename `Zompado-X.Y.Z-ARM64.apk`.
4. Generate the feed with `python3 tools/release_manifest.py APK --version X.Y.Z --build BUILD`. Confirm the public release asset can be downloaded and its SHA-256 and byte count match the generated feed. Commit that feed as `update.json` on `main` after the asset is live. Confirm it serves from [the public updater URL](https://raw.githubusercontent.com/JustTrySomthing/zompado/main/update.json).
5. Follow [the games repository instructions](https://github.com/JustTrySomthing/zompado-games) for game releases and the separate game catalog.

The app compares numeric build codes and checks APK downloads against their declared byte count and SHA-256. Android verifies the package and signing identity before upgrading. Game packages are downloaded independently.
