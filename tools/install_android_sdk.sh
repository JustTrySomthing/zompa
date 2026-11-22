#!/usr/bin/env bash
set -euo pipefail

runner_temp=${RUNNER_TEMP:?Set RUNNER_TEMP}
sdk="$runner_temp/zompa-android-sdk"
archive=$(mktemp -d "$runner_temp/zompa-sdk-tools.XXXXXX")
trap 'rm -rf "$archive"' EXIT

url=https://dl.google.com/android/repository/commandlinetools-linux-15859902_latest.zip
sha256=4e4c464f145a7512b57d088ac6c278c03c9eea610886b35a5e0804e74eedf583
curl --fail --silent --show-error --location --retry 3 "$url" -o "$archive/tools.zip"
printf '%s  %s\n' "$sha256" "$archive/tools.zip" | sha256sum --check --status
unzip -q "$archive/tools.zip" -d "$archive"
mkdir -p "$sdk/cmdline-tools"
mv "$archive/cmdline-tools" "$sdk/cmdline-tools/latest"
export ANDROID_HOME="$sdk"
export ANDROID_SDK_ROOT="$sdk"
sdkmanager="$sdk/cmdline-tools/latest/bin/sdkmanager"
"$sdkmanager" --licenses < <(yes) >/dev/null
"$sdkmanager" --install "$@"
printf 'ANDROID_HOME=%s\nANDROID_SDK_ROOT=%s\n' "$sdk" "$sdk" >> "${GITHUB_ENV:?Set GITHUB_ENV}"
