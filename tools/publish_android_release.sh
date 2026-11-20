#!/usr/bin/env bash
set -euo pipefail

repo=JustTrySomthing/zompado
[[ "$GITHUB_REPOSITORY" == "$repo" && "$GITHUB_REF" == refs/heads/main && "$GITHUB_EVENT_NAME" == push ]]
request=.github/release-request.json
version=$(jq -er '.version | select(type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))' "$request")
build=$(jq -er '.build | select(type == "number" and . >= 1 and floor == .)' "$request")
tag="v$version"
name=Zompado-ARM64.apk
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
python3 - "$manifest" "$scratch/published.json" <<'PY'
import json
import sys
from pathlib import Path

def version(value):
    return tuple(int(part) for part in value.split("."))

candidate, published = (json.loads(Path(path).read_text()) for path in sys.argv[1:])
if candidate != published and (candidate["build"] <= published["build"] or version(candidate["version"]) <= version(published["version"])):
    raise SystemExit("The requested release must increase both the published version and build.")
PY

if ! gh release view "$tag" -R "$repo" --json isDraft,targetCommitish,assets > "$scratch/release.json"; then
  gh release create "$tag" -R "$repo" --target "$GITHUB_SHA" --draft \
    --title "Zompado $version for Android" --notes-file "$scratch/notes.md"
  gh release view "$tag" -R "$repo" --json isDraft,targetCommitish,assets > "$scratch/release.json"
fi

if [[ $(jq -r '.isDraft' "$scratch/release.json") == true ]]; then
  jq -e --arg head "$GITHUB_SHA" '.targetCommitish == $head' "$scratch/release.json" > /dev/null
  mkdir -p "$scratch/existing"
  for asset in "$apk" "$manifest"; do
    filename=${asset##*/}
    if jq -e --arg name "$filename" '.assets | any(.name == $name)' "$scratch/release.json" > /dev/null; then
      gh release download "$tag" -R "$repo" --pattern "$filename" --dir "$scratch/existing"
      cmp "$asset" "$scratch/existing/$filename"
    else
      gh release upload "$tag" "$asset" -R "$repo"
    fi
  done
  gh release edit "$tag" -R "$repo" --draft=false --latest
fi

# The latest release is selected only after both assets exist. Verify the
# public links before updating the compatibility feed for older clients.
verify_download() {
  local url=$1 expected=$2
  local state
  for state in 1 2 3 4 5 6; do
    if curl --fail --silent --show-error --location --max-time 60 \
        "$url?verify=$GITHUB_RUN_ID-$state" -o "$scratch/public" &&
        cmp -s "$expected" "$scratch/public"; then
      return 0
    fi
    sleep 5
  done
  echo "Public download does not match $expected" >&2
  return 1
}
base="https://github.com/$repo/releases/latest/download"
verify_download "$(jq -er '.url' "$manifest")" "$apk"
verify_download "$base/$name" "$apk"
verify_download "$base/update.json" "$manifest"

if cmp -s "$manifest" "$scratch/published.json"; then
  echo "$tag is already published and listed in the update feed."
  exit 0
fi

jq -n --arg message "Publish $version (build $build) to the Android update feed" \
  --arg sha "$(jq -r '.sha' "$scratch/feed.json")" \
  --arg content "$(base64 -w 0 "$manifest")" \
  '{message: $message, sha: $sha, content: $content, branch: "main"}' |
  gh api --method PUT "$feed_endpoint" --input - --jq '.commit.sha'
