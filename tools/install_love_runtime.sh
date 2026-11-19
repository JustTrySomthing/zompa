#!/usr/bin/env bash
set -euo pipefail

output=${1:?Supply an Android generated asset directory}
revision=c4f04e185033a7c9fbefa9be3bec88c41a90421b
base="https://raw.githubusercontent.com/Davidobot/love.js/$revision/src/compat"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
for name in love.js love.wasm; do
    curl -fsSL --retry 3 --max-time 120 "$base/$name" -o "$scratch/$name"
done
(
    cd "$scratch"
    sha256sum --check <<'HASHES'
86a993add89e4b62af875995ad954f39a23725f3f48553a1618b520738b228a0  love.js
8e955d3ca1db20c2c3509313c0093cf81826fc391f509194f85562ac57c601fa  love.wasm
HASHES
)
python3 - "$scratch/love.js" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_bytes()
anchor = b'Module["FS_createPath"]=FS.createPath;'
if source.count(anchor) != 2:
    raise SystemExit("Unexpected LÖVE runtime exports")
source = source.replace(anchor, anchor + b'Module["ZompadoFS"]=FS;')
old_sync = b'if(err){Module["printErr"](err)}else{Module.removeRunDependency("IDBFS_sync")}'
if source.count(old_sync) != 1:
    raise SystemExit("Unexpected LÖVE save initialization")
source = source.replace(old_sync,
    b'if(err){Module["printErr"](err)}Module.removeRunDependency("IDBFS_sync")')
old_eval = b'function _emscripten_run_script(ptr){eval(UTF8ToString(ptr))}'
if source.count(old_eval) != 1:
    raise SystemExit("Unexpected LÖVE script callback")
path.write_bytes(source.replace(old_eval,
    b'function _emscripten_run_script(ptr){if(Module["onAbort"])Module["onAbort"]()}'))
PY
mkdir -p "$output/love"
cp "$scratch/love.js" "$scratch/love.wasm" "$output/love/"
