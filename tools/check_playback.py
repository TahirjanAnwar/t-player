"""Development check: plays videos in the real T-Player window and reports what happened.

    .venv\\Scripts\\python.exe tools\\check_playback.py OUT_DIR [--long LONG_VIDEO] video1 [video2 ...]

Per video: frames shown per second, CPU use, GPU or CPU decoding, the info panel rows, track names,
frame stepping, a saved picture and window screenshots. With --long (a video of 2+ minutes) it also checks
"continue where you stopped" and the keyboard. Writes OUT_DIR\\report.json.
"""
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import tplayer  # noqa: E402
from PySide6.QtCore import Q_ARG, QMetaObject, QObject, QTimer  # noqa: E402
from PySide6.QtMultimedia import QMediaPlayer  # noqa: E402
from PySide6.QtQuick import QQuickItem  # noqa: E402

args = sys.argv[1:]
out_dir = Path(args.pop(0))
long_clip = None
if "--long" in args:
    i = args.index("--long")
    long_clip = str(Path(args[i + 1]).resolve())
    del args[i:i + 2]
clips = [str(Path(p).resolve()) for p in args]
out_dir.mkdir(parents=True, exist_ok=True)

app, engine, win, backend = tplayer.build([sys.argv[0]])
player = win.findChild(QMediaPlayer, "player")
sink = win.findChild(QQuickItem, "videoOut").property("videoSink")
menu = win.findChild(QObject, "moreMenu")
report = {"clips": []}
frames = {"n": 0}
saved = []
sink.videoFrameChanged.connect(lambda f: frames.__setitem__("n", frames["n"] + 1))
backend.frameSaved.connect(saved.append)

steps = []          # (delay_ms, action) run one after another


def at(delay, action):
    steps.append((delay, action))


def run_next():
    if not steps:
        (out_dir / "report.json").write_text(json.dumps(report, indent=1, ensure_ascii=False), encoding="utf-8")
        print(json.dumps(report, indent=1, ensure_ascii=False))
        app.quit()
        return
    delay, action = steps.pop(0)

    def go():
        try:
            action()
        except Exception as error:  # noqa: BLE001
            report.setdefault("errors", []).append(f"{getattr(action, '__name__', action)}: {error!r}")
        run_next()
    QTimer.singleShot(delay, go)


def shot(name):
    def take():
        win.grabWindow().save(str(out_dir / f"{name}.png"))
    take.__name__ = f"shot {name}"
    return take


def call(method, *args):
    QMetaObject.invokeMethod(win, method, *[Q_ARG("QVariant", a) for a in args])


def frame_time():
    frame = sink.videoFrame()
    return frame.startTime() if frame.isValid() else None


# start screen, also in Uyghur with the menu open
at(800, shot("01_start_en"))
at(0, lambda: setattr(backend, "language", "ug"))
at(300, shot("02_start_ug"))
at(0, lambda: (menu.setProperty("x", 300), menu.setProperty("y", 120), QMetaObject.invokeMethod(menu, "open")))
at(400, shot("03_menu_ug"))
at(0, lambda: QMetaObject.invokeMethod(menu, "close"))
at(0, lambda: setattr(backend, "language", "en"))

for index, clip in enumerate(clips, 1):
    entry = {"clip": os.path.basename(clip)}
    report["clips"].append(entry)
    state = {}

    def open_clip(clip=clip):
        backend.openRequested.emit(clip)

    def start_measure(state=state):
        state.update(f0=frames["n"], t0=time.perf_counter(), c0=time.process_time())

    def stop_measure(entry=entry, state=state):
        wall = time.perf_counter() - state["t0"]
        entry["fps_shown"] = round((frames["n"] - state["f0"]) / wall, 1)
        entry["cpu_pct_of_pc"] = round(100 * (time.process_time() - state["c0"]) / wall / os.cpu_count(), 1)
        frame = sink.videoFrame()
        entry["frame"] = f"{frame.width()}x{frame.height()} {frame.pixelFormat().name} {frame.handleType().name}"
        entry["info"] = {r["label"]: r["value"] for r in backend.mediaInfo(player, sink)}
        entry["audio_tracks"] = backend.trackNames(player, 0)
        entry["subtitle_tracks"] = backend.trackNames(player, 1)
        entry["error"] = win.property("errorText")
        entry["status"] = player.mediaStatus().name

    def show_controls():
        win.setProperty("mouseActive", True)

    def pause_and_mark(entry=entry, state=state):
        player.pause()
        state["pos0"] = player.position()

    def step_forward(entry=entry, state=state):
        state["t_before"] = frame_time()
        call("frameStep", 1)

    def after_step(entry=entry, state=state):
        entry["frame_step_forward"] = {"pos_before": state["pos0"], "pos_after": player.position(),
                                       "frame_us_before": state["t_before"], "frame_us_after": frame_time()}
        state["t_before2"] = frame_time()
        call("frameStep", -1)

    def after_step_back(entry=entry, state=state):
        entry["frame_step_back"] = {"pos_after": player.position(), "frame_us_before": state["t_before2"],
                                    "frame_us_after": frame_time()}

    def save_picture(entry=entry):
        call("saveFrame")

    def picture_done(entry=entry):
        entry["picture_saved"] = saved[-1] if saved else None

    def after_end(entry=entry):
        if player.duration() < 6000:   # short clips have ended by now: the last frame should still be there
            frame = sink.videoFrame()
            entry["after_end"] = {"state": player.playbackState().name, "position": player.position(),
                                  "duration": player.duration(), "frame_valid": frame.isValid(),
                                  "frame_us": frame.startTime() if frame.isValid() else None}

    at(300, open_clip)
    at(1200, start_measure)
    at(3000, stop_measure)
    at(1500, after_end)
    at(0, show_controls)
    at(350, shot(f"{index + 3:02d}_{Path(clip).stem}_controls"))
    at(0, lambda: win.setProperty("infoOpen", True))
    at(1300, shot(f"{index + 3:02d}_{Path(clip).stem}_info"))
    at(0, lambda: win.setProperty("infoOpen", False))
    at(0, pause_and_mark)
    at(500, step_forward)
    at(700, after_step)
    at(700, after_step_back)
    at(100, save_picture)
    at(2500, picture_done)

if long_clip:
    from PySide6.QtCore import Qt
    from PySide6.QtTest import QTest
    checks = report["long"] = {}

    def key(k):
        QTest.keyClick(win, k)

    at(300, lambda: backend.openRequested.emit(long_clip))
    at(1500, lambda: player.setPosition(60_000))
    at(800, lambda: checks.update(before_switch=player.position()))
    at(0, lambda: backend.openRequested.emit(clips[0]))          # switching saves the position
    at(1500, lambda: backend.openRequested.emit(long_clip))      # ... and reopening continues there
    at(1500, lambda: checks.update(resumed_at=player.position(), osd=win.findChild(QObject, "osdText").property("text")))
    at(0, lambda: checks.update(volume_before=backend.volume))
    at(0, lambda: key(Qt.Key.Key_Up))
    at(200, lambda: checks.update(volume_after_up=backend.volume))
    at(0, lambda: key(Qt.Key.Key_Space))
    at(400, lambda: checks.update(after_space=player.playbackState().name, pos_paused=player.position()))
    at(0, lambda: key(Qt.Key.Key_Right))
    at(600, lambda: checks.update(after_right=player.position()))
    at(0, lambda: key(Qt.Key.Key_5))
    at(600, lambda: checks.update(after_5=player.position(), duration=player.duration()))
    at(0, lambda: key(Qt.Key.Key_BracketRight))
    at(200, lambda: checks.update(speed_after_bracket=player.playbackRate()))
    at(0, lambda: key(Qt.Key.Key_Backspace))
    at(0, lambda: key(Qt.Key.Key_Down))
    at(0, lambda: key(Qt.Key.Key_F))
    at(900, lambda: checks.update(fullscreen=win.visibility().name))
    at(0, shot("20_fullscreen"))
    at(0, lambda: key(Qt.Key.Key_Escape))
    at(900, lambda: checks.update(after_escape=win.visibility().name))

# the menu in Uyghur once more, now that menus get the right-to-left setting
at(0, lambda: setattr(backend, "language", "ug"))
at(0, lambda: win.setProperty("mouseActive", True))
at(0, lambda: (menu.setProperty("x", 700), menu.setProperty("y", 140), QMetaObject.invokeMethod(menu, "open")))
at(500, shot("21_menu_ug_playing"))
at(0, lambda: QMetaObject.invokeMethod(menu, "close"))
at(0, lambda: win.setProperty("keysOpen", True))
at(400, shot("22_shortcuts_ug"))
at(0, lambda: win.setProperty("keysOpen", False))
at(0, lambda: win.setProperty("infoOpen", True))
at(1300, shot("23_info_ug"))
at(0, lambda: win.setProperty("infoOpen", False))
at(0, lambda: setattr(backend, "language", "en"))

run_next()
sys.exit(app.exec())
