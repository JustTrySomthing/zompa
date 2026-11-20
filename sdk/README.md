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
| `zompado.audio()` | Create a mixer for one game. Register sources on the `music` or `effects` bus, then call `mixer:update(dt)` from `love.update(dt)` to apply Zompado settings. `setGain` and `setMuted` apply game-level controls on top of the host settings. |

Zompado provides Pause, Resume, and Quit in the game toolbar. Omit these controls from official game screens. Save progress through the SDK where the game supports continuing later. In an online game, the host also provides messaging and voice calls.

Host music and effect gains multiply each source’s volume and any game-level adjustments. The host master volume applies to game audio after mixing, including games with no SDK integration. The game can run with desktop LÖVE and defaults to its own mix there.

```lua
local mixer = require("zompado").audio()

function love.load()
    theme = mixer:register(love.audio.newSource("music.ogg", "stream"), "music")
    drop = mixer:register(love.audio.newSource("drop.wav", "static"), "effects")
end

function love.update(dt)
    mixer:update(dt)
end
```
