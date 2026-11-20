#!/usr/bin/env bash
set -euo pipefail

target=${1:?Supply the Android native executable output path}
sdk=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}
ndk="$sdk/ndk/28.2.13676358"
ndk_bin="$ndk/toolchains/llvm/prebuilt/linux-x86_64/bin"
revision=189c007b9a343eb4639892fc3defafbf9f367da3
rust=1.95.0
case $(basename "$(dirname "$target")") in
    arm64-v8a) triple=aarch64-linux-android ;;
    x86_64) triple=x86_64-linux-android ;;
    *) echo 'Unsupported Chatmail build ABI.' >&2; exit 1 ;;
esac
linker="$ndk_bin/${triple}21-clang"

if [[ ! -x "$linker" ]]; then
    echo "Install Android NDK 28.2.13676358 and set ANDROID_SDK_ROOT." >&2
    exit 1
fi
if ! command -v rustup >/dev/null; then
    echo "Install rustup to build the pinned Chatmail Core source." >&2
    exit 1
fi

mkdir -p "$(dirname "$target")"
target="$(cd "$(dirname "$target")" && pwd)/$(basename "$target")"
source_dir="$(dirname "$target")/../../chatmail-source"
mkdir -p "$source_dir"
if [[ ! -d "$source_dir/.git" ]]; then
    git -C "$source_dir" init --quiet
fi
if [[ $(git -C "$source_dir" rev-parse --verify HEAD 2>/dev/null || true) != "$revision" ]]; then
    git -C "$source_dir" fetch --quiet --depth=1 https://github.com/chatmail/core.git "$revision"
    git -C "$source_dir" checkout --quiet --detach FETCH_HEAD
fi

rustup toolchain install "$rust" --profile minimal --target "$triple"
variable_triple=${triple//-/_}
export "CC_$variable_triple=$linker"
export "AR_$variable_triple=$ndk_bin/llvm-ar"
export "RANLIB_$variable_triple=$ndk_bin/llvm-ranlib"
export "CARGO_TARGET_${variable_triple^^}_LINKER=$linker"
export "CARGO_TARGET_${variable_triple^^}_RUSTFLAGS=-C link-arg=-Wl,-z,max-page-size=16384"
(
    cd "$source_dir"
    cargo +"$rust" build --locked --release --target "$triple" --package deltachat-rpc-server
)
partial=$(mktemp "$target.XXXXXX")
trap 'rm -f "$partial"' EXIT
"$ndk_bin/llvm-strip" -o "$partial" "$source_dir/target/$triple/release/deltachat-rpc-server"
chmod 755 "$partial"
mv "$partial" "$target"
