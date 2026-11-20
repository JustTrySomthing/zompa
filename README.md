# Zompado for Android

Play, share and chat with friends.<br>
Discover fun and unique games,<br>
or make your own.

[Download for Android (ARM64)](https://github.com/JustTrySomthing/zompado/releases/latest) · [Browse the game catalog](https://github.com/JustTrySomthing/zompado-games)

## What you can do today

- **Play Drop Four.** Download it from the game catalog. In the preview, the built-in LÖVE player runs its `.zomp` package for solo, same-phone, and online matches.
- **Discover and install games.** Open **Games → Get Games** to browse the official catalog and install games in the app.
- **Invite and message friends in the Android preview.** Create a Chatmail profile, share an invite link or QR code, and exchange encrypted one-to-one text messages. [Get the signed preview](https://github.com/JustTrySomthing/zompado/actions/runs/44646518299/artifacts/14589332914).

The public APK includes a local chat preview. For online messaging, download the `zompado-signed-android` ZIP from the preview build and extract the APK. Preview 0.5.8 passed the APK’s 16 KB native alignment check. On-device verification is pending.

In the preview, scan a friend’s invite QR code or paste their invite link. Take turns in online Drop Four, chat from the board, and resume from **Your turn** in My Games. Share Drop Four from your library or a conversation. Call friends from a conversation and use the call bar to mute, switch to speaker, or hang up. With alerts enabled, Android can check for friend activity after closing the app process. Its schedule can delay those alerts. Reopen Setup and searchable Help from **Settings**.

The preview starts with an empty game library on a fresh install. Add titles in **Games → Get Games** and remove a title from its menu in **My Games**. Use the import button to play compatible `.love` files from your device. Downloaded games require Android 10 or later with a sandboxed WebView renderer.

Open **Settings → Game audio** or tap the speaker icon while playing to adjust game volume, music, and effects. Separate music and effects work with games that use the SDK. Game volume also controls audio in compatible imports.

## Game Builder coming soon

Chat with AI to turn your idea into a Zompado game you can play and share. The Game Builder will be available as an optional download.

## Project docs

[Build and recovery](docs/RECOVERY.md) · [Releases](docs/RELEASE.md) · [Brand assets](docs/brand/README.md) · [Build plan](docs/BUILD-PLAN.md)
