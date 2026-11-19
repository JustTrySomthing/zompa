"""Verify APK ARM64 executables and libraries can be mapped with 16 KiB pages."""

import struct
import sys
import zipfile

PAGE = 16384


def check(data: bytes, path: str) -> None:
    if data[:6] != b"\x7fELF\x02\x01":
        raise ValueError(f"{path}: expected 64-bit little-endian ELF")
    phoff, entsize, count = (
        struct.unpack_from("<Q", data, 32)[0],
        *struct.unpack_from("<HH", data, 54),
    )
    if not count or entsize < 56:
        raise ValueError(f"{path}: ELF has no valid program headers")
    loaded = 0
    for index in range(count):
        offset = phoff + index * entsize
        kind, _, file_offset, virtual_address, _, _, _, alignment = (
            struct.unpack_from("<IIQQQQQQ", data, offset)
        )
        if kind == 1:  # PT_LOAD
            loaded += 1
            if alignment < PAGE or (virtual_address - file_offset) % PAGE:
                raise ValueError(f"{path}: LOAD segment {index} is unaligned for 16 KiB")
    if not loaded:
        raise ValueError(f"{path}: ELF has no LOAD segments")


def main() -> None:
    with zipfile.ZipFile(sys.argv[1]) as apk:
        libs = [p for p in apk.namelist() if p.startswith("lib/arm64-v8a/") and p.endswith(".so")]
        if not {"lib/arm64-v8a/" + p for p in ("libapp.so", "libflutter.so", "libchatmail_rpc.so")}.issubset(libs):
            raise SystemExit("APK is missing required ARM64 libraries")
        for path in libs:
            check(apk.read(path), path)
            print(f"{path} has 16 KiB ELF alignment")


if __name__ == "__main__":
    main()
