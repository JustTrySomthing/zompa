# Zompado game SDK

This first SDK slice targets LÖVE 11.5. Put [zompado.lua](zompado.lua) in the game root and load it with `require("zompado")`. [Tap Counter](template) is a small example with a save slot and touch or keyboard input. Set a unique identity in `conf.lua` when developing locally with LÖVE.

Run the sample during development with LÖVE 11.5.

```sh
sample=$(mktemp -d)
cp sdk/template/* sdk/zompado.lua "$sample/"
love "$sample"
```

Official packages use a ZIP archive with a root `zompado.json` and `main.lua`. Use the example manifest as a starting point. Keep the ID stable, increase `build` for a new version, and use an immutable SHA-256 when publishing to the [official games catalog](https://github.com/JustTrySomthing/zompado-games).

| API | Behavior |
|---|---|
| `zompado.save(slot, bytes)` | Write an opaque string of up to 256 KiB. Returns success and, on failure, an error. |
| `zompado.load(slot)` | Read the save string from the game's LÖVE save directory. Keep formats versioned and tolerate a missing save. |
| `zompado.audio()` | Create a mixer for one game. Register sources on the `music` or `effects` bus, then call `setGain` or `setMuted` to control registered sources. |

The built-in isolated player will own the storage and permissions boundary. The sample runs in an installed desktop LÖVE runtime for development. Android can validate and save manually selected `.love` archives while built-in playback is being implemented. Host-controlled audio, scoped saves, and a general turn API still require player integration.
