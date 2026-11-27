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

## Install

1. Python 3.12 has to be installed (<https://www.python.org/downloads/>).
2. Double-click **`setup.cmd`**. It does four things:
   - installs Qt for Python into `.venv` (about 350 MB)
   - builds `T-Player.exe`
   - puts T-Player on the desktop and in the Start menu
   - asks whether videos should open in T-Player with a double-click

## Make T-Player your video player

Windows doesn't let an app make itself the default, so you choose it once:

1. Run `.venv\Scripts\python.exe tplayer.py --register`. `setup.cmd` does this when you answer **Y**.
   It only adds T-Player to *your* user's app lists.
2. In **Settings › Apps › Default apps › Video player**, choose **T-Player**.

Another way: right-click a video › *Open with* › *Choose another app* › T-Player › *Always use this app*.
To undo the registration: `.venv\Scripts\python.exe tplayer.py --unregister`.

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
| `assets/` | The icon. `tools/make_icon.py` draws it (needs Pillow) |
| `tools/check_playback.py` | A test run with real videos: GPU or CPU, frame rate, frame stepping, screenshots |

The video engine is Qt Multimedia with its built-in FFmpeg (LGPL), from
[Qt for Python](https://doc.qt.io/qtforpython-6/) (PySide6).
