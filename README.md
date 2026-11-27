# T-Player

A simple video player for Windows that plays **HEVC / H.265** videos from phones, drones and cameras
without Microsoft's paid "HEVC Video Extensions". It plays almost every other format too.

- **Uses the graphics card.** On a GTX 1070, 4K 50 fps HEVC 10-bit plays at about 0.4 % CPU.
- **Simple screen.** The video fills the window, and the controls show when you move the mouse.
  Right-click (or `⋯`) for everything else.
- **Opening videos.** Use *Open video*, drag a video in, or double-click videos once T-Player is your video player.
- **Next and previous.** Page Up / Page Down go to the next or previous video in the same folder.
- **Remembers settings.** It keeps the volume, window size and language, and where you stopped in videos
  longer than 2 minutes.
- **Extras:** frame-by-frame stepping, speed 0.25× to 2×, audio track and subtitle choice, video info,
  and saving the frame on screen as a PNG.
- **Five languages:** English, Uyghur, Turkish, Arabic and Dutch.
- **Thumbnails.** HEVC videos show a frame as their thumbnail in File Explorer.
- **Updates.** A *Check for updates* button installs new versions from GitHub.

The icon is the sky blue of the Kök Bayraq, the flag of East Turkistan (#0099FF), with a white play symbol.

## Install

You need Windows 10 or 11, [Python 3.12](https://www.python.org/downloads/) and
[Git](https://git-scm.com/download/win).

1. Get T-Player with Git, so the update button can update it later:

   ```
   git clone https://github.com/TahirjanAnwar/t-player.git T-Player
   ```

   A ZIP download from GitHub works too, but then T-Player can't update itself.
2. Double-click **`setup.cmd`** in the `T-Player` folder. It does four things:
   - installs Qt for Python into `.venv` (about 350 MB)
   - builds `T-Player.exe` and the thumbnail add-on
   - puts T-Player on the desktop and in the Start menu
   - asks whether videos should open in T-Player with a double-click

## Updates

T-Player looks for a new version on GitHub a few seconds after it starts. When there is one, the start screen
shows a blue **Update available** button, and a blue dot appears on `⋯`. You can also check yourself with
**Check for updates**: at the bottom of the start screen, or in the `⋯` / right-click menu.

**Install update** gets the new version with `git pull`, installs new packages if the update needs them, and
rebuilds `T-Player.exe` or the thumbnail add-on if they changed. Then T-Player restarts with the same video.

## Make T-Player your video player

Windows doesn't let an app make itself the default, so you choose it once:

1. Run `.venv\Scripts\python.exe tplayer.py --register`. `setup.cmd` does this when you answer **Y**.
   It only adds T-Player to *your* user's app lists.
2. In **Settings › Apps › Default apps › Video player**, choose **T-Player**.

Another way: right-click a video › *Open with* › *Choose another app* › T-Player › *Always use this app*.
To undo the registration: `.venv\Scripts\python.exe tplayer.py --unregister`.

## Thumbnails in File Explorer

Without Microsoft's HEVC codec, Windows can't show a picture for HEVC videos, so they just show the app's icon.
`--register` also switches on T-Player's own thumbnails:

- **What you see.** Videos that open with T-Player show a frame from about 1 second in as their thumbnail.
- **How it works.** `TPlayerThumbnails.dll` asks FFmpeg for that frame. It needs FFmpeg
  (`winget install Gyan.FFmpeg`).
- **Safety.** Windows runs it in its separate thumbnail process, not inside Explorer, and it only reads the videos.
- **Speed.** A 4K HEVC clip takes about half a second the first time, then Windows keeps the thumbnail.
- **Turning it off.** `--unregister` removes it together with the rest.

## Keyboard

| Key | Does |
|---|---|
| Space, or click the video | Play / pause |
| ← → | Back / forward 5 seconds (Ctrl: 1 minute) |
| ↑ ↓, or the mouse wheel | Volume |
| M | Mute |
| F, Enter, or double-click | Full screen (Esc leaves it) |
| `,` `.` | Previous / next frame |
| `[` `]` Backspace | Slower / faster / normal speed |
| Page Up / Page Down | Previous / next video in the folder |
| 0 … 9 | Jump to 0 % … 90 % |
| Home | Back to the start |
| S | Save the frame as a picture (Pictures\T-Player) |
| I | Video info |
| Ctrl+O | Open video |

## Good to know

- **Who decodes what.** HEVC and H.264 in 4:2:0 are decoded by the graphics card. That covers phones,
  drones and most camera settings.
- **4:2:2 10-bit footage** comes from modes like Sony XAVC HS 4:2:2 and some Canon and Panasonic settings.
  A GTX 1070 can't decode it, so the processor does. In 4K this plays at about 21 frames per second,
  which looks a little choppy. *Video info* (I) shows whether the GPU or the CPU is in use.
- **Pinning.** T-Player shows on the taskbar under its own name, so you can pin it.
- **Problems.** If something goes wrong, look in `t-player.log` next to the app.

## Files

| File | What it is |
|---|---|
| `tplayer.py` | The app: files and folders, settings, languages, Windows integration |
| `qml/Main.qml` | The window and its controls |
| `locales/*.json` | The texts in each language |
| `launcher/TPlayerLauncher.cs` | Source of `T-Player.exe`, built by `setup.cmd` with Windows' own C# compiler |
| `launcher/TPlayerThumbnails.cs` | Source of `TPlayerThumbnails.dll`, the File Explorer thumbnails |
| `assets/` | The icon. `tools/make_icon.py` draws it (needs Pillow) |
| `tools/check_playback.py` | A test run with real videos: GPU or CPU, frame rate, frame stepping, screenshots |
| `tools/thumbtest.cs` | A test for the thumbnails: directly, or through Windows once registered |

The video engine is Qt Multimedia with its built-in FFmpeg (LGPL), from
[Qt for Python](https://doc.qt.io/qtforpython-6/) (PySide6).
