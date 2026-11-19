# Zompado

## Product focus

Play and chat with friends.<br>
Discover fun and unique games,<br>
and easily make and share your own.

Prioritize work that helps people play or chat with friends, discover games, or make and share games. Keep those flows easy to find and use. Leave unrelated features outside the project unless the user explicitly expands its scope. Describe available features on the public README and download page, and document proposed work in the build plan.

The Game Builder is an optional download for Zompado. Begin work on it after gameplay, the game library, and the shared game SDK are stable and tested. Build it on the same framework and shareable game package format used by Zompado.

## Working on the project

Start with [docs/RECOVERY.md](docs/RECOVERY.md) when resuming on a new machine or in a new chat. GitHub is the source of truth for the Android app, official games, and shipped versions. Check both repositories and their release feeds before changing versions or distribution.

Preserve the Android package ID and the existing signing certificate for in-place upgrades. Store signing credentials in protected settings. Follow [the release steps](docs/RELEASE.md) and update this handoff when the toolchain, distribution, or credential custody changes.
