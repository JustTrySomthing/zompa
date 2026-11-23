# Zompa game SDK

The Zompa Lua SDK targets LÖVE 11.5. Put [zompa.lua](zompa.lua) in the game root and load it with `require("zompa")`. [Tap Counter](template) is a small example with a save slot and touch or keyboard input. Set a unique identity in `conf.lua` when developing locally with LÖVE.

Run the sample during development with LÖVE 11.5.

```sh
sample=$(mktemp -d)
cp sdk/template/* sdk/zompa.lua "$sample/"
love "$sample"
```

Official packages use a ZIP archive with a root `zompa.json` and `main.lua`. Use the example manifest as a starting point. When targeting older app versions, include the same manifest as `zompado.json` as well. Keep the ID stable, increase `build` for a new version, and use an immutable SHA-256 when publishing to the [official games catalog](https://github.com/JustTrySomthing/zompa-games).

| API | Behavior |
|---|---|
| `zompa.save(slot, bytes)` | Write an opaque string of up to 256 KiB. Returns success and, on failure, an error. |
| `zompa.load(slot)` | Read the save string from the game's LÖVE save directory. Keep formats versioned and tolerate a missing save. |
| `zompa.mode()` | Return the current game mode (`solo`, `local`, or `online`) and whether Zompa is hosting the game. Desktop LÖVE defaults to `solo`. |
| `zompa.saveSession(bytes)` | Save the unfinished round for the current mode. Store between 1 byte and 256 KiB. Returns success and, on failure, an error. |
| `zompa.loadSession()` | Read the current mode’s unfinished round, or return `nil` to start with an empty board. |
| `zompa.clearSession()` | Remove the unfinished round when the game finishes. |
| `zompa.audio()` | Create a mixer for one game. Register sources on the `music` or `effects` bus, then call `mixer:update(dt)` from `love.update(dt)` to apply Zompa settings. `setGain` and `setMuted` apply game-level controls on top of the host settings. |

## What Zompa provides during play

- The game toolbar has a **Back** arrow and the game title on the left, plus **How to play**, **Game audio** and **Pause/Resume** on the right. **Quit game** appears in the pause panel. Online games also get chat and call controls. Zompa reserves the standard 56 logical-pixel toolbar and Android’s system insets. Put game-specific controls inside the play area and size them to the canvas LÖVE receives.
- The Game audio sheet has a circled speaker button that mutes all game sound. The crossed-out speaker shows when mute is on. Zompa remembers master volume, music and effects settings, and whether to lower game audio during a call.

## Starting, resuming, and ending games

- **Play → Single Player** and **Play → Pass & Play** start a fresh round and replace the previous unfinished round for that mode. **New Online Match** and a new invitation from chat create a separate online match with an empty board. Existing online matches keep their own match IDs.
- **Back** leaves an unfinished round available under **My Games → Active Games**. Selecting a game there loads the saved round. **Pause** keeps the current round open. **Quit game** clears that local round or ends the online match for both players.
- For official games with resumable local rounds, declare `"localSaves": true` in the catalog entry and use the session API for round progress. One round can be saved per local mode. Save after state changes so Back, app suspension, or process death can recover the latest saved board. Use ordinary `save` and `load` slots for durable preferences, achievements, and unlocks. Keep the round format versioned and handle an unrecognized save by starting clean.
- The current online protocol supports Cats vs Dogs. Other game types need host integration before they can offer online play. In online mode the host supplies the match state. The session API returns no local round and rejects writes in this mode. Older imports can keep using their own save files. Their resume and reset behavior depends on the game.

Host music and effect gains multiply each source’s volume and any game-level adjustments. The host master volume applies to game audio after mixing, including games with no SDK integration. The game can run with desktop LÖVE and defaults to its own mix there.

```lua
local mixer = require("zompa").audio()

function love.load()
    theme = mixer:register(love.audio.newSource("music.ogg", "stream"), "music")
    drop = mixer:register(love.audio.newSource("drop.wav", "static"), "effects")
end

function love.update(dt)
    mixer:update(dt)
end
```

## Standard game toolbar

Zompa owns the Back button, game title and three right-side actions: How to play, Audio and Pause/Resume. Online communication actions appear before them when available. Leave those controls outside the LÖVE canvas. Include a UTF-8 plain-text file named `how-to-play.txt` at the root of each package (up to 16 KiB). Describe the goal, a typical turn, and how to win. The host reads the instructions from the installed package for official and imported games. Local play suspends while instructions are open. Online help opens for the reader only.
