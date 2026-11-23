# Zompa game SDK

The Zompa Lua SDK targets LÖVE 11.5. Put [zompa.lua](zompa.lua) in the game root and load it with `require("zompa")`. Start with [Cats vs Dogs](https://github.com/JustTrySomthing/zompa-games/tree/main/drop-four/1.3.13), the reference game for all three official modes. [Tap Counter](template) is a small desktop example for learning the Lua helpers. Set a unique identity in `conf.lua` when developing locally with LÖVE.

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
| `zompa.clear(slot)` | Remove a durable save slot. A missing slot counts as success. |
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
- The session API returns no local round and rejects writes during online matches. Older imports can keep using their own save files. Their resume and reset behavior depends on the game.

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


## Three play modes

Every official Zompa game is expected to offer **Single Player** (`solo`), **Pass & Play** (`local`), and **Online 2 Player** (`online`). Declare all three in `zompa.json` once they work in the Android player. Use the same game rules for each mode. Single Player takes the second turn from the computer opponent. Pass & Play takes both players’ turns on one device.

In Online 2 Player, both Zompa apps handle the invitation, participants, turn order, exact game build, and synchronization. Zompa exchanges moves and match events through hidden encrypted Chatmail messages. Game code receives and sends moves through the host. Keep networking and Chatmail out of the game package.

The current Android online move format serves Cats vs Dogs. Its SDK handoff is `zompa.onlineState()` to read the latest board snapshot and `zompa.submitOnlineMove(column)` to submit a zero-based column (0 to 6). The reference game waits for the host's updated snapshot before applying an online turn. Keep the transport details inside the SDK. Other games need Android support for their own moves before they can offer Online 2 Player.

## Publishing check

For the reference game, the games repository builds the candidate `.zomp` once. The publishing check uses that exact package in the Zompa Android player. It plays a human and computer turn in Single Player, plays both sides and checks resume in Pass & Play, and uses two Android installs to accept an invitation and exchange moves through Chatmail in Online 2 Player. A failed check blocks publishing the package and updating Get Games.
