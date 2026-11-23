#!/usr/bin/env python3
"""Build, validate, and stage a Zompa game package. Requires Python 3.11+."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile
from zipfile import ZIP_DEFLATED, BadZipFile, ZipFile, ZipInfo

OWNER = "JustTrySomthing"
GAMES_REPO = f"{OWNER}/zompa-games"
APP_ID = "io.tablecircle.prototype"
MAX_PACKAGE = 64 * 1024 * 1024
MAX_CONTENT = 192 * 1024 * 1024
MAX_ENTRIES = 4096
MODES = ("solo", "local", "online")


def checked_text(archive, name, limit):
    try:
        entry = archive.getinfo(name)
    except KeyError as error:
        raise ValueError(f"Missing root {name}.") from error
    if not 0 < entry.file_size <= limit:
        raise ValueError(f"{name} must be between 1 and {limit} bytes.")
    try:
        value = archive.read(entry).decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValueError(f"{name} must be UTF-8.") from error
    if not value.strip():
        raise ValueError(f"{name} must contain text.")
    return value


def validate(package, *, require_three_modes=False):
    if not re.fullmatch(r"[A-Za-z0-9._-]+\.zomp", package.name):
        raise ValueError("Use a .zomp filename with ASCII letters, digits, dots, underscores or hyphens.")
    if not 0 < package.stat().st_size <= MAX_PACKAGE:
        raise ValueError("The archive must fit in 64 MiB.")
    with ZipFile(package) as archive:
        entries = archive.infolist()
        if len(entries) > MAX_ENTRIES:
            raise ValueError(f"The archive may contain at most {MAX_ENTRIES} entries.")
        if sum(entry.file_size for entry in entries if not entry.is_dir()) > MAX_CONTENT:
            raise ValueError("Game files may use at most 192 MiB when expanded.")
        names = set()
        files = set()
        directories = set()
        for entry in entries:
            path = entry.orig_filename.removesuffix("/") if entry.is_dir() else entry.orig_filename
            if (len(path.encode("utf-16-le")) > 1024 or "\\" in path or ":" in path
                    or any(ord(c) < 32 or 127 <= ord(c) <= 159 for c in path)
                    or any(part in {"", ".", ".."} for part in path.split("/"))):
                raise ValueError(f"Invalid archive path: {path!r}.")
            normalized = path.lower()
            parents = set()
            for parent in Path(normalized).parents:
                if parent != Path("."):
                    parents.add(parent.as_posix())
            if (normalized in names or parents & files
                    or (not entry.is_dir() and normalized in directories)):
                raise ValueError(f"Conflicting archive path: {path!r}.")
            names.add(normalized)
            directories.update(parents)
            if entry.is_dir():
                directories.add(normalized)
            else:
                files.add(normalized)
        if "main.lua" not in archive.namelist() or archive.getinfo("main.lua").file_size == 0:
            raise ValueError("The archive needs a nonempty root main.lua.")
        manifest_text = checked_text(archive, "zompa.json", 4096)
        manifest = json.loads(manifest_text)
        if "zompado.json" in archive.namelist():
            legacy_manifest = checked_text(archive, "zompado.json", 4096)
            if json.loads(legacy_manifest) != manifest:
                raise ValueError("zompado.json must match zompa.json.")
        checked_text(archive, "how-to-play.txt", 16 * 1024)
        if bad := archive.testzip():
            raise ValueError(f"ZIP integrity check failed for {bad}.")
    if not isinstance(manifest, dict):
        raise ValueError("zompa.json must contain a JSON object.")
    game_id, title, version, build, modes = (
        manifest.get(field) for field in ("id", "title", "version", "build", "modes")
    )
    if not isinstance(game_id, str) or len(game_id) > 64 or not re.fullmatch(
        r"[a-z0-9]+(?:-[a-z0-9]+)*", game_id
    ):
        raise ValueError("id must be a lowercase, hyphen-separated name up to 64 characters.")
    if not isinstance(title, str) or not title.strip() or len(title.encode("utf-16-le")) > 180:
        raise ValueError("title must be nonblank and at most 90 UTF-16 units.")
    if not isinstance(version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("version must use the numeric x.y.z format.")
    if type(build) is not int or not 1 <= build <= 2147483647:
        raise ValueError("build must be a positive 32-bit integer.")
    if (type(manifest.get("schema")) is not int or manifest["schema"] != 1
            or manifest.get("runtime") != "love-11.5" or manifest.get("entry") != "main.lua"):
        raise ValueError("Use schema 1, runtime love-11.5 and entry main.lua.")
    if (not isinstance(modes, list) or any(mode not in MODES for mode in modes)
            or len(set(modes)) != len(modes) or "solo" not in modes):
        raise ValueError("modes must list solo and may also list local and online once each.")
    if require_three_modes and set(modes) != set(MODES):
        raise ValueError("Official games must declare solo, local and online.")
    if "localSaves" in manifest and type(manifest["localSaves"]) is not bool:
        raise ValueError("localSaves must be a boolean.")
    if "minZompaBuild" in manifest and (
        type(manifest["minZompaBuild"]) is not int
        or not 1 <= manifest["minZompaBuild"] <= 2147483647
    ):
        raise ValueError("minZompaBuild must be a positive 32-bit integer.")
    if "onlineProtocol" in manifest and (
        manifest["onlineProtocol"] != "turns-v1" or "online" not in modes
        or manifest.get("minZompaBuild", 1) < 55
    ):
        raise ValueError("onlineProtocol must be turns-v1 and requires the online mode and minZompaBuild 55 or higher.")
    return manifest


def catalog_entry(package, manifest, repo=GAMES_REPO):
    game = {key: manifest[key] for key in ("id", "title", "version", "build", "modes")}
    for key in ("localSaves", "minZompaBuild", "onlineProtocol"):
        if key in manifest:
            game[key] = manifest[key]
    tag = f"{game['id']}-v{game['version']}"
    with package.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    game.update(format="zomp", size=package.stat().st_size, sha256=digest,
                url=f"https://github.com/{repo}/releases/download/{tag}/{package.name}")
    return game


def build(source, output, *, require_three_modes=False):
    source, output = source.resolve(), output.resolve()
    if not source.is_dir():
        raise ValueError("The game source directory does not exist.")
    if output.is_relative_to(source):
        raise ValueError("Put the output .zomp outside the source directory.")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent) as directory:
        staged = Path(directory) / output.name
        with ZipFile(staged, "w", ZIP_DEFLATED) as archive:
            files = sorted(source.rglob("*"))
            total = 0
            count = 0
            for file in files:
                relative = file.relative_to(source)
                if any(part.startswith(".") or part == "__pycache__" for part in relative.parts):
                    continue
                if file.is_symlink():
                    raise ValueError(f"Game source must contain ordinary files: {relative}.")
                if not file.is_file():
                    continue
                total += file.stat().st_size
                count += 1
                if total > MAX_CONTENT or count > MAX_ENTRIES:
                    raise ValueError("Source exceeds the player’s expanded package limits.")
                archive.writestr(ZipInfo(relative.as_posix()), file.read_bytes(), ZIP_DEFLATED)
        manifest = validate(staged, require_three_modes=require_three_modes)
        staged.replace(output)
    return manifest


def stage(package, manifest, adb, serials):
    game = catalog_entry(package, manifest)
    feed = json.dumps({"schema": 2, "games": [game], "archive": []}).encode()
    for serial in serials:
        subprocess.run([adb, "-s", serial, "shell", "am", "force-stop", APP_ID], check=True)
        shell = [adb, "-s", serial, "shell", "-T"]
        def send(command, data=None):
            subprocess.run([*shell, command], input=data, check=True)
        folder = f"files/games/{game['id']}"
        send(f"run-as {APP_ID} mkdir -p {folder}")
        send(f"run-as {APP_ID} tee {folder}/{game['build']}.zomp >/dev/null",
             package.read_bytes())
        send(f"run-as {APP_ID} tee files/game-release-check.json.part >/dev/null", feed)
        send(f"run-as {APP_ID} mv files/game-release-check.json.part files/game-release-check.json")
        print(f"{serial}: staged {game['title']} ({game['sha256']}).")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ("build", "check", "preview"):
        sub = commands.add_parser(command)
        if command == "build":
            sub.add_argument("source", type=Path)
        sub.add_argument("package", type=Path)
        sub.add_argument("--require-three-modes", action="store_true")
        if command == "preview":
            sub.add_argument("--adb", default="adb")
            sub.add_argument("--device", action="append", required=True)
    args = parser.parse_args()
    try:
        manifest = (
            build(args.source, args.package, require_three_modes=args.require_three_modes)
            if args.command == "build" else
            validate(args.package, require_three_modes=args.require_three_modes)
        )
        if args.command == "preview":
            stage(args.package, manifest, args.adb, args.device)
        else:
            print(json.dumps(catalog_entry(args.package, manifest), indent=2))
    except (ValueError, BadZipFile, OSError, RuntimeError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
