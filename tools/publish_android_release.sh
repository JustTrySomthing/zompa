#!/usr/bin/env bash
set -euo pipefail

repo=JustTrySomthing/zompado
[[ "$GITHUB_REPOSITORY" == "$repo" && "$GITHUB_REF" == refs/heads/main && "$GITHUB_EVENT_NAME" == push ]]
request=.github/release-request.json
version=$(jq -er '.version | select(type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))' "$request")
build=$(jq -er '.build | select(type == "number" and . >= 1 and floor == .)' "$request")
tag="v$version"
name="Zompado-$version-ARM64.apk"
apk="release/$name"
manifest=release/update.json
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

grep -Fxq "version: $version+$build" pubspec.yaml
jq -er '.notes | select(type == "string" and length > 0)' "$request" > "$scratch/notes.md"
python3 tools/release_manifest.py "$apk" --version "$version" --build "$build" > "$scratch/manifest.json"
cmp "$manifest" "$scratch/manifest.json"

feed_endpoint="repos/$repo/contents/update.json"
gh api "$feed_endpoint?ref=main" > "$scratch/feed.json"
jq -r '.content' "$scratch/feed.json" | base64 --decode > "$scratch/published.json"
if cmp -s "$manifest" "$scratch/published.json"; then
  echo "$tag is already published and listed in the update feed."
  exit 0
fi
python3 - "$manifest" "$scratch/published.json" <<'PY'
import json
import sys
from pathlib import Path

def version(value):
    return tuple(int(part) for part in value.split("."))

candidate, published = (json.loads(Path(path).read_text()) for path in sys.argv[1:])
if candidate["build"] <= published["build"] or version(candidate["version"]) <= version(published["version"]):
    raise SystemExit("The requested release must increase both the published version and build.")
PY

if ! gh release view "$tag" -R "$repo" --json isDraft,targetCommitish,assets > "$scratch/release.json"; then
  gh release create "$tag" -R "$repo" --target "$GITHUB_SHA" --draft \
    --title "Zompado $version for Android" --notes-file "$scratch/notes.md"
  gh release view "$tag" -R "$repo" --json isDraft,targetCommitish,assets > "$scratch/release.json"
fi

if [[ $(jq -r '.isDraft' "$scratch/release.json") == true ]]; then
  jq -e --arg head "$GITHUB_SHA" '.targetCommitish == $head' "$scratch/release.json" > /dev/null
  if jq -e --arg name "$name" '.assets | any(.name == $name)' "$scratch/release.json" > /dev/null; then
    gh release download "$tag" -R "$repo" --pattern "$name" --dir "$scratch"
    cmp "$apk" "$scratch/$name"
  else
    gh release upload "$tag" "$apk" -R "$repo"
  fi
  gh release edit "$tag" -R "$repo" --draft=false --latest
fi

# Expose the update only after a public download matches the signed artifact.
url=$(jq -er '.url' "$manifest")
curl --fail --silent --show-error --location --retry 6 --retry-all-errors \
  "$url" -o "$scratch/public.apk"
cmp "$apk" "$scratch/public.apk"

jq -n --arg message "Publish $version (build $build) to the Android update feed" \
  --arg sha "$(jq -r '.sha' "$scratch/feed.json")" \
  --arg content "$(base64 -w 0 "$manifest")" \
  '{message: $message, sha: $sha, content: $content, branch: "main"}' |
  gh api --method PUT "$feed_endpoint" --input - --jq '.commit.sha'
