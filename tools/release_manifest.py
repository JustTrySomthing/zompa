#!/usr/bin/env python3
"""Write the updater feed for an already signed Zompado ARM64 APK."""
import argparse
import hashlib
import json
import re
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("apk", type=Path)
parser.add_argument("--version", required=True)
parser.add_argument("--build", type=int, required=True)
args = parser.parse_args()
if not re.fullmatch(r"\d+\.\d+\.\d+", args.version) or args.build < 1:
    parser.error("use a numeric x.y.z version and positive Android build number")
if not re.fullmatch(r"[A-Za-z0-9._-]+\.apk", args.apk.name):
    parser.error("use a GitHub-safe APK filename")
with args.apk.open("rb") as stream:
    sha256 = hashlib.file_digest(stream, "sha256").hexdigest()
print(json.dumps({
    "schema": 1,
    "version": args.version,
    "build": args.build,
    "abi": "arm64-v8a",
    "url": f"https://github.com/JustTrySomthing/zompado/releases/download/v{args.version}/{args.apk.name}",
    "sha256": sha256,
    "size": args.apk.stat().st_size,
}, indent=2))
