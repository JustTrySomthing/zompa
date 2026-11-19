#!/usr/bin/env bash
set -euo pipefail

apk=${1:?Usage: verify_release_apk.sh APK VERSION BUILD}
version=${2:?Supply the expected version name}
build=${3:?Supply the expected Android build number}
sdk=${ANDROID_SDK_ROOT:-${ANDROID_HOME:?Set ANDROID_SDK_ROOT or ANDROID_HOME}}
build_tools="$sdk/build-tools/36.0.0"
fingerprint=d55fa5cc439bc4abfbf914e32675728de84c3267d2a86ec59c91781ff1bb39b8

certificates=$("$build_tools/apksigner" verify --print-certs "$apk")
signers=$(sed -nE 's/^Signer #[0-9]+ certificate SHA-256 digest: (.*)$/\1/p' <<<"$certificates")
if [[ "$signers" != "$fingerprint" ]]; then
  echo 'APK signing certificate does not match the published Zompado certificate.' >&2
  exit 1
fi

badging=$("$build_tools/aapt" dump badging "$apk")
if ! grep -Fq "package: name='io.tablecircle.prototype' versionCode='$build' versionName='$version'" <<<"$badging" ||
   ! grep -Eq "^native-code: 'arm64-v8a'[[:space:]]*$" <<<"$badging"; then
  echo 'APK package, version, build, or ABI does not match the release.' >&2
  exit 1
fi

printf 'Verified Zompado %s (build %s), ARM64, signer SHA-256 %s\n' "$version" "$build" "$fingerprint"
