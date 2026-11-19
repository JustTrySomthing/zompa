#!/usr/bin/env bash
set -euo pipefail

target=${1:?Supply the Android native executable output path}
version=2.69.0
sha=101c7c59675f295efa601eba0e4bcf01fa2456e44b8aa9ed2fa999c6fb995257
check() { printf '%s  %s\n' "$sha" "$1" | sha256sum --check --status; }

if [[ -f "$target" ]] && check "$target"; then
    exit
fi
mkdir -p "$(dirname "$target")"
partial=$(mktemp "$target.XXXXXX")
trap 'rm -f "$partial"' EXIT
curl -fsSL --retry 3 --retry-all-errors --max-time 120 \
    "https://github.com/chatmail/core/releases/download/v$version/deltachat-rpc-server-arm64-v8a-android" \
    -o "$partial"
check "$partial"
chmod 755 "$partial"
mv "$partial" "$target"
