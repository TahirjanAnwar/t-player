"""T-Player - a simple video player that plays HEVC / H.265 (and almost anything else).

Windows' own apps need Microsoft's paid "HEVC Video Extensions" for H.265. T-Player doesn't: Qt Multimedia
brings its own FFmpeg. 4:2:0 HEVC and H.264 are decoded on the graphics card (D3D11VA), other formats on the CPU.

Start it with T-Player.exe, or:  .venv\\Scripts\\pythonw.exe tplayer.py [video]
"""
from __future__ import annotations

import ctypes
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import traceback
from pathlib import Path

APP_NAME = "T-Player"
APP_ID = "TProduction.TPlayer"
VERSION = "1.0.0"
APP_DIR = Path(__file__).resolve().parent
SETTINGS_PATH = APP_DIR / "settings.json"
LOG_PATH = APP_DIR / "t-player.log"
ICON_PATH = APP_DIR / "assets" / "t-player.ico"

# Qt's own FFmpeg engine, not Windows Media Foundation (which is the one that wants the paid codec).
os.environ.setdefault("QT_MEDIA_BACKEND", "ffmpeg")

from PySide6.QtCore import (Property, QLocale, QObject, QRect, QStandardPaths, QTimer, QUrl, Signal, Slot,
                            qInstallMessageHandler)
from PySide6.QtGui import QColor, QFont, QFontDatabase, QGuiApplication, QIcon, QImage, QPalette, QWindow
from PySide6.QtMultimedia import QMediaMetaData, QMediaPlayer, QVideoFrame, QVideoFrameFormat, QVideoSink
from PySide6.QtQml import QQmlApplicationEngine
from PySide6.QtQuickControls2 import QQuickStyle

VIDEO_EXTS = {".mp4", ".m4v", ".mov", ".mkv", ".webm", ".avi", ".wmv", ".asf", ".mts", ".m2ts", ".ts", ".mxf",
              ".3gp", ".3g2", ".mpg", ".mpeg", ".m2v", ".vob", ".flv", ".ogv", ".hevc", ".h265", ".265",
              ".h264", ".264", ".lrv", ".dv"}
AUDIO_EXTS = {".mp3", ".m4a", ".aac", ".wav", ".flac", ".ogg", ".opus", ".wma", ".aif", ".aiff"}
LANGUAGE_ORDER = ["en", "ug", "tr", "ar", "nl"]
RTL_LANGUAGES = {"ug", "ar"}
UYGHUR_FONTS = ["UKIJ Tuz Tom", "ALKATIP Basma Tom", "Microsoft Uighur"]
MAX_RECENT = 6
CODEC_NAMES = {"H265": "HEVC (H.265)", "H264": "H.264 (AVC)", "MPEG4": "MPEG-4", "MPEG2": "MPEG-2",
               "MPEG1": "MPEG-1", "MotionJPEG": "Motion JPEG", "Wave": "PCM"}
DEFAULTS = {"language": "", "volume": 0.8, "muted": False, "repeat": False, "on_top": False,
            "recent": [], "resume": {}, "last_folder": "", "window": None}


# ---------------------------------------------------------------- logging

def log(text: str) -> None:
    try:
        with LOG_PATH.open("a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')}  {text}\n")
    except OSError:
        pass
    if sys.stderr:
        print(text, file=sys.stderr)


def start_log() -> None:
    try:
        if LOG_PATH.exists() and LOG_PATH.stat().st_size > 512_000:
            LOG_PATH.unlink()
    except OSError:
        pass
    log(f"{APP_NAME} {VERSION} starting")
    qInstallMessageHandler(lambda mode, context, message: log(f"Qt: {message}"))
    sys.excepthook = lambda kind, value, tb: log("".join(traceback.format_exception(kind, value, tb)))


# ---------------------------------------------------------------- settings

class Settings:
    """settings.json next to the app. Writes are bundled, so dragging the volume doesn't hammer the disk."""

    def __init__(self, path: Path):
        self.path = path
        self.data = dict(DEFAULTS)
        try:
            loaded = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(loaded, dict):
                self.data.update(loaded)
        except (OSError, ValueError):
            pass
        self._timer = QTimer()
        self._timer.setSingleShot(True)
        self._timer.setInterval(400)
        self._timer.timeout.connect(self.save_now)

    def get(self, key):
        return self.data.get(key, DEFAULTS.get(key))

    def set(self, key, value) -> None:
        self.data[key] = value
        self._timer.start()

    def save_now(self) -> None:
        self._timer.stop()
        tmp = self.path.with_suffix(".tmp")
        try:
            tmp.write_text(json.dumps(self.data, ensure_ascii=False, indent=1), encoding="utf-8")
            os.replace(tmp, self.path)
        except OSError as error:
            log(f"settings not saved: {error}")


# ---------------------------------------------------------------- helpers

def natural_key(name: str):
    return [int(part) if part.isdigit() else part.lower() for part in re.split(r"(\d+)", name)]


def media_kind(path: str) -> str:
    ext = os.path.splitext(path)[1].lower()
    return "audio" if ext in AUDIO_EXTS else "video"


def same_file(a: str, b: str) -> bool:
    return os.path.normcase(os.path.abspath(a)) == os.path.normcase(os.path.abspath(b))


def human_size(size: int) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if size < 1024 or unit == "GB":
            return f"{size:.0f} {unit}" if unit == "B" else f"{size:.1f} {unit}"
        size /= 1024
    return ""


def human_bitrate(bits) -> str:
    try:
        bits = float(bits)
    except (TypeError, ValueError):
        return ""
    if bits <= 0:
        return ""
    return f"{bits / 1e6:.1f} Mb/s" if bits >= 1e6 else f"{bits / 1e3:.0f} kb/s"


def human_duration(ms: int) -> str:
    t = max(0, int(ms) // 1000)
    h, m, s = t // 3600, t // 60 % 60, t % 60
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m}:{s:02d}"


def load_locales() -> dict[str, dict]:
    locales = {}
    for file in sorted((APP_DIR / "locales").glob("*.json")):
        try:
            locales[file.stem] = json.loads(file.read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            log(f"locale {file.name} not loaded: {error}")
    locales.setdefault("en", {"_language_name": "English"})
    return locales


def pick_language(saved: str, available) -> str:
    if saved in available:
        return saved
    for tag in QLocale.system().uiLanguages():
        code = tag.replace("_", "-").split("-")[0].lower()
        if code in available:
            return code
    return "en"


# ---------------------------------------------------------------- the bridge between Python and the QML window

class Backend(QObject):
    languageChanged = Signal()
    optionsChanged = Signal()
    recentChanged = Signal()
    currentChanged = Signal()
    openRequested = Signal(str)
    frameSaved = Signal(str)
    frameSaveFailed = Signal()

    def __init__(self, settings: Settings):
        super().__init__()
        self._settings = settings
        self._locales = load_locales()
        self._lang = pick_language(settings.get("language"), self._locales)
        self._strings = self._merged_strings()
        families = set(QFontDatabase.families())
        self._uyghur_font = next((f for f in UYGHUR_FONTS if f in families), "")
        self._current = ""
        self._playlist: list[str] = []

    # ---- language
    def _merged_strings(self) -> dict:
        return {**self._locales.get("en", {}), **self._locales.get(self._lang, {})}

    @Property("QVariantMap", notify=languageChanged)
    def strings(self):
        return self._strings

    @Property(str, notify=languageChanged)
    def language(self):
        return self._lang

    @language.setter
    def language(self, code):
        if code in self._locales and code != self._lang:
            self._lang = code
            self._strings = self._merged_strings()
            self._settings.set("language", code)
            self.languageChanged.emit()

    @Property("QVariantList", constant=True)
    def languages(self):
        codes = [c for c in LANGUAGE_ORDER if c in self._locales]
        codes += [c for c in self._locales if c not in codes]
        return [{"code": c, "name": self._locales[c].get("_language_name", c)} for c in codes]

    @Property(bool, notify=languageChanged)
    def rtl(self):
        return self._lang in RTL_LANGUAGES

    @Property(str, notify=languageChanged)
    def fontFamily(self):
        return self._uyghur_font if self._lang == "ug" and self._uyghur_font else "Segoe UI"

    @Property(float, notify=languageChanged)
    def fontScale(self):
        # Microsoft Uighur draws its letters small; the Voice Clone app enlarges it the same way.
        return 1.45 if self.fontFamily == "Microsoft Uighur" else 1.0

    # ---- options
    def _option(self, key, value):
        if self._settings.get(key) != value:
            self._settings.set(key, value)
            self.optionsChanged.emit()

    @Property(float, notify=optionsChanged)
    def volume(self):
        return float(self._settings.get("volume"))

    @volume.setter
    def volume(self, value):
        self._option("volume", round(max(0.0, min(1.0, float(value))), 2))

    @Property(bool, notify=optionsChanged)
    def muted(self):
        return bool(self._settings.get("muted"))

    @muted.setter
    def muted(self, value):
        self._option("muted", bool(value))

    @Property(bool, notify=optionsChanged)
    def repeat(self):
        return bool(self._settings.get("repeat"))

    @repeat.setter
    def repeat(self, value):
        self._option("repeat", bool(value))

    @Property(bool, notify=optionsChanged)
    def onTop(self):
        return bool(self._settings.get("on_top"))

    @onTop.setter
    def onTop(self, value):
        self._option("on_top", bool(value))

    @Property(str, constant=True)
    def version(self):
        return VERSION

    @Property(str, constant=True)
    def mediaPatterns(self):
        return " ".join("*" + ext for ext in sorted(VIDEO_EXTS | AUDIO_EXTS))

    @Property(QUrl, notify=currentChanged)
    def lastFolderUrl(self):
        folder = self._settings.get("last_folder") or ""
        return QUrl.fromLocalFile(folder) if folder and os.path.isdir(folder) else QUrl()

    # ---- the open file and the other videos in its folder
    @Property(str, notify=currentChanged)
    def currentPath(self):
        return self._current

    @Property(QUrl, notify=currentChanged)
    def currentUrl(self):
        return QUrl.fromLocalFile(self._current) if self._current else QUrl()

    @Property(str, notify=currentChanged)
    def currentName(self):
        return os.path.basename(self._current)

    @Property(int, notify=currentChanged)
    def playlistCount(self):
        return len(self._playlist)

    @Property(str, notify=currentChanged)
    def playlistText(self):
        index = self._index_of(self._current)
        return f"{index + 1} / {len(self._playlist)}" if len(self._playlist) > 1 and index >= 0 else ""

    def _index_of(self, path: str) -> int:
        return next((i for i, p in enumerate(self._playlist) if same_file(p, path)), -1)

    def _scan_folder(self, path: str) -> list[str]:
        folder, kind = os.path.dirname(path), media_kind(path)
        exts = AUDIO_EXTS if kind == "audio" else VIDEO_EXTS
        try:
            names = [n for n in os.listdir(folder)
                     if os.path.splitext(n)[1].lower() in exts and os.path.isfile(os.path.join(folder, n))]
        except OSError:
            names = []
        files = [os.path.join(folder, n) for n in sorted(names, key=natural_key)]
        if not any(same_file(f, path) for f in files):
            files.append(path)
            files.sort(key=lambda p: natural_key(os.path.basename(p)))
        return files

    @Slot(str, result=bool)
    def openFile(self, target: str) -> bool:
        path = QUrl(target).toLocalFile() if target.lower().startswith("file:") else target
        path = os.path.realpath(path.strip().strip('"')) if path else ""   # also turns short 8.3 names into long ones
        if not path or not os.path.isfile(path):
            log(f"not found: {target}")
            return False
        self._current = path
        self._playlist = self._scan_folder(path)
        recent = [p for p in self._settings.get("recent") or [] if not same_file(p, path)]
        self._settings.set("recent", [path] + recent[:MAX_RECENT * 2])
        self._settings.set("last_folder", os.path.dirname(path))
        self.currentChanged.emit()
        self.recentChanged.emit()
        return True

    @Slot(int, result=bool)
    def stepFile(self, delta: int) -> bool:
        if not self._current:
            return False
        self._playlist = self._scan_folder(self._current)   # picks up files added since
        index = self._index_of(self._current) + delta
        return 0 <= index < len(self._playlist) and self.openFile(self._playlist[index])

    @Property("QVariantList", notify=recentChanged)
    def recent(self):
        items = []
        for path in self._settings.get("recent") or []:
            if os.path.isfile(path):
                items.append({"path": path, "name": os.path.basename(path), "folder": os.path.dirname(path)})
            if len(items) == MAX_RECENT:
                break
        return items

    @Slot()
    def clearRecent(self):
        self._settings.set("recent", [])
        self.recentChanged.emit()

    # ---- continue long videos where you stopped
    @Slot(str, float, float)
    def savePosition(self, path: str, position_ms: float, duration_ms: float):
        if not path:
            return
        key = os.path.normcase(path)
        resume = dict(self._settings.get("resume") or {})
        resume.pop(key, None)
        if duration_ms >= 120_000 and 15_000 <= position_ms <= duration_ms - 20_000:
            resume[key] = int(position_ms)
        while len(resume) > 300:
            resume.pop(next(iter(resume)))
        self._settings.set("resume", resume)

    @Slot(str, result=float)
    def resumePosition(self, path: str) -> float:
        return float((self._settings.get("resume") or {}).get(os.path.normcase(path), 0))

    # ---- extras
    @Slot(str)
    def showInFolder(self, path: str):
        if path and os.path.exists(path):
            subprocess.Popen(f'explorer /select,"{os.path.normpath(path)}"')

    @Slot(QObject, float)
    def saveFrame(self, sink, position_ms: float):
        """Saves the frame on screen as a PNG in Pictures\\T-Player (in the background: 4K PNGs take a moment)."""
        image = None
        try:
            frame = sink.videoFrame() if isinstance(sink, QVideoSink) else QVideoFrame()
            image = frame.toImage() if frame.isValid() else None
        except Exception as error:  # noqa: BLE001 - any failure just means "couldn't save"
            log(f"frame grab failed: {error}")
        if image is None or image.isNull():
            self.frameSaveFailed.emit()
            return
        image = image.convertToFormat(QImage.Format.Format_RGB888)   # no see-through layer: smaller files
        pictures =QStandardPaths.writableLocation(QStandardPaths.StandardLocation.PicturesLocation)
        folder = Path(pictures) / APP_NAME
        stem = Path(self._current).stem if self._current else "frame"
        t = int(position_ms)
        stamp = f"{t // 3600000:02d}-{t // 60000 % 60:02d}-{t // 1000 % 60:02d}.{t % 1000:03d}"

        def work():
            try:
                folder.mkdir(parents=True, exist_ok=True)
                target, n = folder / f"{stem} {stamp}.png", 2
                while target.exists():
                    target, n = folder / f"{stem} {stamp} ({n}).png", n + 1
                ok = image.save(str(target), "PNG")
            except OSError as error:
                log(f"frame not saved: {error}")
                ok = False
            if ok:
                self.frameSaved.emit(str(target))
            else:
                self.frameSaveFailed.emit()

        threading.Thread(target=work, daemon=True).start()

    @staticmethod
    def _metadata(player):
        try:
            return player.metaData() if isinstance(player, QMediaPlayer) else None
        except RuntimeError:
            return None

    @Slot(QObject, result=float)
    def frameStartMs(self, sink) -> float:
        """Exact time (ms) of the frame on screen, or -1."""
        frame = sink.videoFrame() if isinstance(sink, QVideoSink) else QVideoFrame()
        return frame.startTime() / 1000.0 if frame.isValid() and frame.startTime() >= 0 else -1.0

    @Slot(QObject, result=float)
    def frameRate(self, player) -> float:
        md = self._metadata(player)
        try:
            return float(md.value(QMediaMetaData.Key.VideoFrameRate) or 0) if md is not None else 0.0
        except (TypeError, ValueError):
            return 0.0

    @Slot(QObject, int, result="QVariantList")
    def trackNames(self, player, kind: int):
        """Readable names for the audio (kind 0) or subtitle (kind 1) tracks."""
        if not isinstance(player, QMediaPlayer):
            return []
        tracks = player.audioTracks() if kind == 0 else player.subtitleTracks()
        names = []
        for number, md in enumerate(tracks, 1):
            title = (md.stringValue(QMediaMetaData.Key.Title) or "").strip()
            language = md.value(QMediaMetaData.Key.Language)
            lang = ""
            if isinstance(language, QLocale.Language) and language not in (QLocale.Language.AnyLanguage,
                                                                         QLocale.Language.C):
                lang = QLocale.languageToString(language)
            if title and lang and lang.lower() not in title.lower():
                names.append(f"{title} ({lang})")
            else:
                names.append(title or lang or self._strings.get("track", "Track {n}").replace("{n}", str(number)))
        return names

    @Slot(QObject, QObject, result="QVariantList")
    def mediaInfo(self, player, sink):
        """Rows for the Video info panel."""
        t = self._strings
        rows = []

        def add(key, value):
            if value:
                rows.append({"label": t.get(key, key), "value": str(value)})

        if self._current:
            add("info_file", os.path.basename(self._current))
            try:
                add("info_size", human_size(os.path.getsize(self._current)))
            except OSError:
                pass
        md = self._metadata(player)
        if md is None:
            return rows
        key = QMediaMetaData.Key
        add("info_container", md.stringValue(key.FileFormat))
        frame = sink.videoFrame() if isinstance(sink, QVideoSink) else QVideoFrame()
        if player.hasVideo():
            codec = md.stringValue(key.VideoCodec)
            add("info_video", CODEC_NAMES.get(codec, codec))
            if frame.isValid():
                add("info_resolution", f"{frame.width()} × {frame.height()}")
            else:
                add("info_resolution", md.stringValue(key.Resolution))
            fps = self.frameRate(player)
            if fps > 0:
                add("info_frame_rate", f"{fps:.3f}".rstrip("0").rstrip(".") + " fps")
            if frame.isValid():
                fmt = QVideoFrameFormat.PixelFormat
                ten_bit = {getattr(fmt, n) for n in ("Format_P010", "Format_P016", "Format_YUV420P10") if hasattr(fmt, n)}
                add("info_bit_depth", "10-bit" if frame.pixelFormat() in ten_bit else "8-bit")
            add("info_bitrate", human_bitrate(md.value(key.VideoBitRate)))
        if player.hasAudio():
            codec = md.stringValue(key.AudioCodec)
            audio = [CODEC_NAMES.get(codec, codec), human_bitrate(md.value(key.AudioBitRate))]
            add("info_audio", " · ".join(a for a in audio if a))
        if player.duration() > 0:
            add("info_duration", human_duration(player.duration()))
        if player.hasVideo() and frame.isValid():
            on_gpu = frame.handleType() == QVideoFrame.HandleType.RhiTextureHandle
            add("info_decoding", t.get("decoder_gpu") if on_gpu else t.get("decoder_cpu"))
        return rows


# ---------------------------------------------------------------- Windows touches: dark title bar, taskbar identity

class _GUID(ctypes.Structure):
    _fields_ = [("Data1", ctypes.c_ulong), ("Data2", ctypes.c_ushort), ("Data3", ctypes.c_ushort),
                ("Data4", ctypes.c_ubyte * 8)]

    def __init__(self, text: str):
        super().__init__()
        ctypes.oledll.ole32.CLSIDFromString(ctypes.c_wchar_p("{" + text + "}"), ctypes.byref(self))


class _PROPERTYKEY(ctypes.Structure):
    _fields_ = [("fmtid", _GUID), ("pid", ctypes.c_ulong)]


class _PROPVARIANT(ctypes.Structure):
    _fields_ = [("vt", ctypes.c_ushort), ("r1", ctypes.c_ushort), ("r2", ctypes.c_ushort), ("r3", ctypes.c_ushort),
                ("value", ctypes.c_wchar_p), ("pad", ctypes.c_void_p)]


def set_dark_title_bar(hwnd: int) -> None:
    on = ctypes.c_int(1)
    for attribute in (20, 19):  # DWMWA_USE_IMMERSIVE_DARK_MODE (19 on older Windows 10 builds)
        if ctypes.windll.dwmapi.DwmSetWindowAttribute(ctypes.c_void_p(hwnd), attribute, ctypes.byref(on),
                                                      ctypes.sizeof(on)) == 0:
            return


def set_taskbar_identity(hwnd: int) -> None:
    """Groups the window as T-Player on the taskbar (not as Python), so pinning it pins T-Player.exe."""
    exe = APP_DIR / "T-Player.exe"
    if exe.exists():
        command = f'"{exe}"'
    else:
        command = f'"{Path(sys.executable).with_name("pythonw.exe")}" "{APP_DIR / "tplayer.py"}"'
    values = ((5, APP_ID), (2, command), (4, APP_NAME), (3, f"{ICON_PATH},0"))  # ID, RelaunchCommand, name, icon
    shell32 = ctypes.windll.shell32
    shell32.SHGetPropertyStoreForWindow.argtypes = [ctypes.c_void_p, ctypes.POINTER(_GUID),
                                                    ctypes.POINTER(ctypes.c_void_p)]
    store = ctypes.c_void_p()
    if shell32.SHGetPropertyStoreForWindow(hwnd, _GUID("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"),
                                           ctypes.byref(store)) != 0 or not store:
        return
    vtable = ctypes.cast(store, ctypes.POINTER(ctypes.POINTER(ctypes.c_void_p))).contents
    set_value = ctypes.WINFUNCTYPE(ctypes.c_long, ctypes.c_void_p, ctypes.POINTER(_PROPERTYKEY),
                                   ctypes.POINTER(_PROPVARIANT))(vtable[6])
    commit = ctypes.WINFUNCTYPE(ctypes.c_long, ctypes.c_void_p)(vtable[7])
    release = ctypes.WINFUNCTYPE(ctypes.c_ulong, ctypes.c_void_p)(vtable[2])
    fmtid = _GUID("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3")  # System.AppUserModel.*
    try:
        for pid, text in values:
            variant = _PROPVARIANT()
            variant.vt = 31  # VT_LPWSTR
            variant.value = text
            set_value(store, ctypes.byref(_PROPERTYKEY(fmtid, pid)), ctypes.byref(variant))
        commit(store)
    finally:
        release(store)


# ---------------------------------------------------------------- window and app

def apply_palette(app: QGuiApplication) -> None:
    """Dark colours for menus, tooltips and the file dialog's Qt parts."""
    role, group = QPalette.ColorRole, QPalette.ColorGroup
    colours = {role.Window: "#1b1c22", role.WindowText: "#f4f4f7", role.Base: "#141519",
               role.AlternateBase: "#22232a", role.ToolTipBase: "#24252d", role.ToolTipText: "#f4f4f7",
               role.Text: "#f4f4f7", role.Button: "#24252d", role.ButtonText: "#f4f4f7", role.BrightText: "#ffffff",
               role.Highlight: "#ff4f5e", role.HighlightedText: "#ffffff", role.Light: "#3a3b45",
               role.Midlight: "#30313a", role.Mid: "#2a2b33", role.Dark: "#101114", role.Shadow: "#000000",
               role.PlaceholderText: "#8a8d99", role.Link: "#ff7a85"}
    palette = QPalette()
    for r, colour in colours.items():
        palette.setColor(r, QColor(colour))
    for r in (role.WindowText, role.Text, role.ButtonText):
        palette.setColor(group.Disabled, r, QColor("#6d707b"))
    app.setPalette(palette)


def show_window(win: QWindow, settings: Settings) -> None:
    if sys.platform == "win32":
        hwnd = int(win.winId())
        for step in (set_dark_title_bar, set_taskbar_identity):
            try:
                step(hwnd)
            except Exception as error:  # noqa: BLE001 - cosmetic only
                log(f"{step.__name__} failed: {error}")

    saved = settings.get("window") or {}
    rect = None
    try:
        rect = QRect(int(saved["x"]), int(saved["y"]), int(saved["w"]), int(saved["h"]))
    except (KeyError, TypeError, ValueError):
        pass
    if not (rect and rect.width() >= 400 and rect.height() >= 250
            and any(s.availableGeometry().intersects(rect) for s in QGuiApplication.screens())):
        area = QGuiApplication.primaryScreen().availableGeometry()
        w, h = min(1280, int(area.width() * 0.8)), min(720, int(area.height() * 0.8))
        rect = QRect(area.center().x() - w // 2, area.center().y() - h // 2, w, h)
    win.setGeometry(rect)
    normal = {"x": rect.x(), "y": rect.y(), "w": rect.width(), "h": rect.height()}

    def remember(*_):
        if win.visibility() == QWindow.Visibility.Windowed:
            g = win.geometry()
            normal.update(x=g.x(), y=g.y(), w=g.width(), h=g.height())

    for signal in (win.xChanged, win.yChanged, win.widthChanged, win.heightChanged, win.visibilityChanged):
        signal.connect(remember)

    def save_on_quit():
        visibility = win.visibility()
        maximized = visibility == QWindow.Visibility.Maximized or (
            visibility == QWindow.Visibility.FullScreen and bool(win.property("wasMaximized")))
        settings.set("window", {**normal, "max": maximized})
        settings.save_now()

    QGuiApplication.instance().aboutToQuit.connect(save_on_quit)
    if saved.get("max"):
        win.showMaximized()
    else:
        win.show()


def build(argv: list[str]):
    """Creates the app and its window. Returns (app, engine, window, backend); keep them alive."""
    start_log()
    QGuiApplication.setApplicationName(APP_NAME)
    QGuiApplication.setOrganizationName("T-production")
    QGuiApplication.setApplicationVersion(VERSION)
    QQuickStyle.setStyle("Fusion")
    app = QGuiApplication(argv)
    app.setWindowIcon(QIcon(str(ICON_PATH)))
    app.setFont(QFont("Segoe UI", 10))
    apply_palette(app)

    settings = Settings(SETTINGS_PATH)
    backend = Backend(settings)
    engine = QQmlApplicationEngine()
    backend.setParent(engine)   # the window is torn down before the backend it reads from
    engine.rootContext().setContextProperty("backend", backend)
    engine.load(QUrl.fromLocalFile(str(APP_DIR / "qml" / "Main.qml")))
    if not engine.rootObjects():
        log("The window couldn't be loaded (see the Qt messages above).")
        raise SystemExit(1)
    win = engine.rootObjects()[0]
    show_window(win, settings)
    app.aboutToQuit.connect(lambda: log("closed"))
    return app, engine, win, backend


# ---------------------------------------------------------------- "Open with" and Default apps (current user only)

PROG_ID = "TPlayer.Video"
CAPABILITIES = r"Software\Clients\Media\T-Player\Capabilities"
THUMBNAIL_DLL = APP_DIR / "TPlayerThumbnails.dll"
THUMBNAIL_CLSID = "{5F2722BF-DA9D-4983-AF1D-B5C441DBF04E}"      # TPlayer.ThumbnailProvider in TPlayerThumbnails.cs
THUMBNAIL_HANDLER = "{e357fccd-a995-4576-b01f-234630154e96}"    # Windows' "thumbnail provider" slot
APPROVED = r"Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Approved"
ASSOCIATE_EXTS = [".mp4", ".m4v", ".mov", ".mkv", ".webm", ".avi", ".wmv", ".mts", ".m2ts", ".ts", ".mxf", ".3gp",
                  ".mpg", ".mpeg", ".flv", ".hevc", ".h265"]


def registry_entries() -> list[tuple[str, str, str]]:
    """(key, value name, data) under HKEY_CURRENT_USER. "" as name means the key's default value."""
    exe, icon = APP_DIR / "T-Player.exe", f'"{ICON_PATH}"'
    command = f'"{exe}" "%1"'
    entries = [
        (rf"Software\Classes\{PROG_ID}", "", "Video (T-Player)"),
        (rf"Software\Classes\{PROG_ID}\DefaultIcon", "", icon),
        (rf"Software\Classes\{PROG_ID}\shell\open", "FriendlyAppName", APP_NAME),
        (rf"Software\Classes\{PROG_ID}\shell\open\command", "", command),
        (r"Software\Classes\Applications\T-Player.exe", "FriendlyAppName", APP_NAME),
        (r"Software\Classes\Applications\T-Player.exe\shell\open\command", "", command),
        (CAPABILITIES, "ApplicationName", APP_NAME),
        (CAPABILITIES, "ApplicationDescription", "Plays HEVC / H.265 and other videos"),
        (CAPABILITIES, "ApplicationIcon", f"{ICON_PATH},0"),
        (r"Software\RegisteredApplications", APP_NAME, CAPABILITIES),
    ]
    for ext in ASSOCIATE_EXTS:
        entries += [(CAPABILITIES + r"\FileAssociations", ext, PROG_ID),
                    (rf"Software\Classes\{ext}\OpenWithProgids", PROG_ID, ""),
                    (r"Software\Classes\Applications\T-Player.exe\SupportedTypes", ext, "")]
    return entries


def thumbnail_entries(ffmpeg: str) -> list[tuple[str, str, str]]:
    """Explorer thumbnails for videos that open with T-Player: TPlayerThumbnails.dll, a .NET COM class that
    Windows runs in its separate thumbnail process."""
    clsid = rf"Software\Classes\CLSID\{THUMBNAIL_CLSID}"
    server = {"Class": "TPlayer.ThumbnailProvider",
              "Assembly": "TPlayerThumbnails, Version=1.0.0.0, Culture=neutral, PublicKeyToken=null",
              "RuntimeVersion": "v4.0.30319",
              "CodeBase": "file:///" + str(THUMBNAIL_DLL).replace("\\", "/")}
    entries = [(clsid, "", "T-Player thumbnails"),
               (clsid + r"\InprocServer32", "", "mscoree.dll"),
               (clsid + r"\InprocServer32", "ThreadingModel", "Both")]
    entries += [(clsid + r"\InprocServer32", name, value) for name, value in server.items()]
    entries += [(clsid + r"\InprocServer32\1.0.0.0", name, value) for name, value in server.items()]
    entries += [(clsid + r"\Implemented Categories\{62C8FE65-4EBB-45e7-B440-6E39B2CDBF29}", "", ""),
                (rf"Software\Classes\{PROG_ID}\ShellEx\{THUMBNAIL_HANDLER}", "", THUMBNAIL_CLSID),
                (APPROVED, THUMBNAIL_CLSID, "T-Player thumbnails"),
                (r"Software\T-Player", "FFmpeg", ffmpeg)]
    return entries


def register_with_windows(remove: bool = False) -> None:
    """Lists T-Player under "Open with" and Settings > Apps > Default apps > Video player.
    Windows doesn't let an app make itself the default: you pick T-Player there once."""
    import winreg
    hkcu = winreg.HKEY_CURRENT_USER

    def delete_tree(path):
        try:
            with winreg.OpenKey(hkcu, path, 0, winreg.KEY_ALL_ACCESS) as key:
                while True:
                    try:
                        child = winreg.EnumKey(key, 0)
                    except OSError:
                        break
                    delete_tree(path + "\\" + child)
            winreg.DeleteKey(hkcu, path)
        except FileNotFoundError:
            pass

    def delete_value(path, name):
        try:
            with winreg.OpenKey(hkcu, path, 0, winreg.KEY_SET_VALUE) as key:
                winreg.DeleteValue(key, name)
        except FileNotFoundError:
            pass

    if remove:
        for path in (rf"Software\Classes\{PROG_ID}", r"Software\Classes\Applications\T-Player.exe",
                     r"Software\Clients\Media\T-Player", rf"Software\Classes\CLSID\{THUMBNAIL_CLSID}",
                     r"Software\T-Player"):
            delete_tree(path)
        delete_value(r"Software\RegisteredApplications", APP_NAME)
        delete_value(APPROVED, THUMBNAIL_CLSID)
        for ext in ASSOCIATE_EXTS:
            delete_value(rf"Software\Classes\{ext}\OpenWithProgids", PROG_ID)
        notes = ["T-Player removed from Windows' app lists and thumbnails."]
    else:
        if not (APP_DIR / "T-Player.exe").exists():
            raise SystemExit("T-Player.exe is missing - run setup.cmd first.")
        entries = registry_entries()
        notes = ["T-Player is now listed under Open with and Settings > Apps > Default apps > Video player."]
        ffmpeg = shutil.which("ffmpeg")
        if not THUMBNAIL_DLL.exists():
            notes.append("No thumbnails: TPlayerThumbnails.dll is missing - run setup.cmd first.")
        elif not ffmpeg:
            notes.append("No thumbnails: FFmpeg isn't installed (winget install Gyan.FFmpeg), then register again.")
        else:
            entries += thumbnail_entries(ffmpeg)
            notes.append("Videos that open with T-Player now show a frame as their thumbnail in File Explorer.")
        for path, name, data in entries:
            with winreg.CreateKeyEx(hkcu, path, 0, winreg.KEY_SET_VALUE) as key:
                winreg.SetValueEx(key, name, 0, winreg.REG_SZ, data)
    ctypes.windll.shell32.SHChangeNotify(0x08000000, 0, None, None)   # SHCNE_ASSOCCHANGED: Explorer re-reads
    print("\n".join(notes))


def main() -> int:
    if "--register" in sys.argv or "--unregister" in sys.argv:
        register_with_windows(remove="--unregister" in sys.argv)
        return 0
    if sys.platform == "win32":
        try:
            ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID(APP_ID)
        except Exception:  # noqa: BLE001
            pass
    app, engine, win, backend = build(sys.argv)
    files = [a for a in sys.argv[1:] if not a.startswith("--")]
    if files:
        QTimer.singleShot(0, lambda: backend.openRequested.emit(files[0]))
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
