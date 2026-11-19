# Releases

1. Increment the version and Android version code in pubspec.yaml and keep the update controller’s installed version/build in sync.
2. Compile an ARM64 APK with the existing signing identity. Check its package name, version code, ABI, and signing certificate against the previous release.
3. Publish the APK to a GitHub Release under the matching `vX.Y.Z` tag.
4. After the asset is publicly downloadable, run `python3 tools/release_manifest.py APK --version X.Y.Z --build BUILD` and commit the output as `update.json` on main. Updating the feed last keeps users from seeing unavailable downloads.
5. For game releases, follow the instructions in [the separate games repository](https://github.com/JustTrySomthing/table-circle-games).

The app compares numeric build codes. Downloads are checked against their declared byte count and SHA-256. Android also checks app identity and the signer. Android may ask the player to allow updates from Table Circle before opening the installer. Game packages are downloaded independently and never alter the APK.
