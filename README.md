# MirrorPod

MirrorPod lets Spotify (or any other Mac audio) keep playing normally to a HomePod while it mirrors the same system audio to the MacBook's built-in speakers.

The menu-bar app uses the native macOS 26 Liquid Glass interface and requires macOS 26 or later.

It avoids macOS's unreliable AirPlay Multi-Output Device behavior:

1. macOS sends the original audio to the selected HomePod.
2. ScreenCaptureKit captures the system mix.
3. MirrorPod excludes its own playback to prevent feedback.
4. AVAudioEngine sends the captured copy directly to the built-in speakers.

## Recommended: menu-bar app

1. Clone or download this repository on a Mac running macOS 26 or later.
2. Double-click **Build Menu App.command** to create **MirrorPod.app** locally.
3. Double-click **MirrorPod.app**, then click its speaker icon in the menu bar.
4. If requested, allow **MirrorPod** under **System Settings → Privacy & Security → Screen & System Audio Recording**, then quit and reopen the app.
5. Keep the HomePod selected as the normal Mac output. MirrorPod starts automatically and mirrors the audio to the MacBook speakers.

The menu includes:

- Start and Stop Mirroring
- A separate volume slider for the HomePod/AirPlay output
- A separate volume slider for the MacBook speakers
- An adjustable Mac-speaker delay for synchronization
- Direct links to Sound and Privacy settings

After the menu app works, you can remove or disable the old **Terminal** and command-line **mirrorpod** recording permissions. Keep the new **MirrorPod** permission enabled.

## Terminal version

1. Choose the HomePod in **System Settings → Sound → Output**.
2. Double-click **Start MirrorPod.command**.
3. On the first run, approve **Screen & System Audio Recording** access for Terminal, then run **Start MirrorPod.command** again.
4. Keep the Terminal window open. Press **Control-C** there to stop.

The launcher automatically builds the utility the first time.

## Build manually

```sh
cd /path/to/MirrorPod
swift build -c release
```

## Run

First choose the HomePod in **System Settings → Sound → Output**. Then run:

```sh
.build/release/mirrorpod
```

The first run asks for **Screen & System Audio Recording** permission. Approve it, quit MirrorPod, and launch it again.

The MacBook copy is delayed by 2000 ms by default to approximately match HomePod's AirPlay delay. Tune it if necessary:

```sh
.build/release/mirrorpod --delay-ms 1800
```

Press **Control-C** to stop.

## Notes

- MirrorPod mirrors all system audio, not only Spotify.
- The normal macOS output must remain set to the HomePod.
- Exact synchronization depends on Wi-Fi and HomePod buffering; adjust `--delay-ms` by ear.
- No audio is transmitted anywhere except the outputs already selected on the Mac.
