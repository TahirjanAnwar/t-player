// T-Player window: the video fills the window, the controls fade in when the mouse moves.
import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Window
import QtMultimedia

ApplicationWindow {
    id: win
    width: 1280
    height: 720
    minimumWidth: 560
    minimumHeight: 340
    visible: false                      // tplayer.py shows it once its size and taskbar identity are set
    color: "#000000"
    title: backend.currentName !== "" ? backend.currentName + "  -  T-Player" : "T-Player"
    flags: backend.onTop ? (Qt.Window | Qt.WindowStaysOnTopHint) : Qt.Window
    font.family: backend.fontFamily
    font.pixelSize: Math.round(14 * backend.fontScale)

    palette.window: "#1b1c22"
    palette.windowText: "#f4f4f7"
    palette.base: "#141519"
    palette.text: "#f4f4f7"
    palette.button: "#24252d"
    palette.buttonText: "#f4f4f7"
    palette.highlight: "#0099ff"
    palette.highlightedText: "#ffffff"
    palette.light: "#3a3b45"
    palette.midlight: "#30313a"
    palette.mid: "#2a2b33"
    palette.dark: "#101114"
    palette.shadow: "#000000"
    palette.toolTipBase: "#24252d"
    palette.toolTipText: "#f4f4f7"

    // ------------------------------------------------------------ look
    readonly property color accent: "#0099ff"
    readonly property color ink: "#f4f4f7"
    readonly property color dim: "#a9acb9"
    readonly property string icons: "Segoe MDL2 Assets"
    readonly property real fs: backend.fontScale
    readonly property var s: backend.strings

    // ------------------------------------------------------------ state
    readonly property bool hasMedia: backend.currentPath !== ""
    readonly property bool playing: player.playbackState === MediaPlayer.PlayingState
    readonly property bool fullscreen: win.visibility === Window.FullScreen
    readonly property bool controlsShown: !playing || mouseActive || barHover.hovered || moreMenu.opened
    readonly property var speeds: [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    property bool wasMaximized: false
    property bool mouseActive: true
    property bool infoOpen: false
    property bool keysOpen: false
    property bool updatesOpen: false
    readonly property bool updateBusy: ["checking", "installing", "restarting"].indexOf(backend.updateState) >= 0
    property bool showRemaining: false
    property string errorText: ""
    property real pendingResume: 0
    property real seekPending: -1
    property var infoRows: []
    property var audioNames: []
    property var subtitleNames: []

    // ------------------------------------------------------------ helpers
    function tr(key, args) {
        var text = s[key] !== undefined ? s[key] : key
        if (args)
            for (var k in args)
                text = text.split("{" + k + "}").join(args[k])
        return text
    }
    function pad2(n) { return (n < 10 ? "0" : "") + n }
    function fmtTime(ms) {
        var t = Math.max(0, Math.floor((ms || 0) / 1000))
        var h = Math.floor(t / 3600), m = Math.floor(t / 60) % 60, sec = t % 60
        return h > 0 ? h + ":" + pad2(m) + ":" + pad2(sec) : m + ":" + pad2(sec)
    }
    function fmtPrecise(ms) {
        var t = Math.max(0, Math.round(ms || 0)), part = t % 1000
        return fmtTime(t) + "." + (part < 100 ? (part < 10 ? "00" : "0") : "") + part
    }
    function osd(text) { osdText.text = text; osdBox.opacity = 1; osdTimer.restart() }
    function poke() { mouseActive = true; idleTimer.restart() }
    function focusKeys() { keyScope.forceActiveFocus() }

    // ------------------------------------------------------------ actions
    function openUrl(target) {
        rememberPosition()
        if (!backend.openFile(String(target))) { osd(tr("file_missing")); return }
        startCurrent()
    }
    function startCurrent() {
        errorText = ""
        infoRows = []
        pendingResume = backend.resumePosition(backend.currentPath)
        player.source = backend.currentUrl
        player.play()
        poke()
        focusKeys()
    }
    function rememberPosition() {
        if (hasMedia && player.duration > 0)
            backend.savePosition(backend.currentPath, player.position, player.duration)
    }
    function stepVideo(delta) {
        if (!hasMedia) return
        rememberPosition()
        if (backend.stepFile(delta)) startCurrent()
        else osd(tr(delta < 0 ? "first_video" : "last_video"))
    }
    function frameMs() {
        var fps = backend.frameRate(player)
        return 1000 / (fps > 0 ? fps : 30)
    }
    function atEnd() {
        return player.mediaStatus === MediaPlayer.EndOfMedia
               || (player.duration > 0 && player.position >= player.duration - 2 * frameMs())
    }
    function togglePlay() {
        if (!hasMedia) { openDialog.open(); return }
        if (playing) {
            player.pause()
            flash.show(false)
        } else {
            if (atEnd()) player.setPosition(0)
            player.play()
            flash.show(true)
        }
    }
    // At the end of a video keep its last frame on screen (paused) instead of a black window.
    function holdLastFrame() {
        if (player.mediaStatus !== MediaPlayer.EndOfMedia || backend.repeat || !player.hasVideo) return
        player.pause()
        player.setPosition(Math.max(0, player.duration - frameMs() / 2))
    }
    function seekBy(ms) {
        if (!hasMedia || !player.seekable) return
        var target = Math.max(0, Math.min(player.duration, player.position + ms))
        player.setPosition(target)
        osd(fmtTime(target) + " / " + fmtTime(player.duration))
        poke()
    }
    function scrubTo(fraction, final) {
        if (!hasMedia || player.duration <= 0) return
        var ms = fraction * player.duration
        if (final) { seekThrottle.stop(); seekPending = -1; player.setPosition(ms); return }
        if (seekThrottle.running) seekPending = ms
        else { player.setPosition(ms); seekThrottle.start() }
    }
    function setVolume(v) {
        v = Math.max(0, Math.min(1, Math.round(v * 100) / 100))
        backend.volume = v
        if (backend.muted && v > 0) backend.muted = false
        osd(tr("volume_osd", { v: Math.round(v * 100) }))
    }
    function changeVolume(delta) { setVolume(backend.volume + delta) }
    function toggleMute() {
        backend.muted = !backend.muted
        osd(backend.muted ? tr("muted_osd") : tr("volume_osd", { v: Math.round(backend.volume * 100) }))
    }
    function speedName(rate) { return Math.abs(rate - 1) < 0.001 ? tr("speed_normal") : rate + "×" }
    function setSpeed(rate) { player.playbackRate = rate; osd(tr("speed_osd", { v: speedName(rate) })) }
    function changeSpeed(dir) {
        var i = speeds.indexOf(player.playbackRate)
        if (i < 0) i = 3
        setSpeed(speeds[Math.max(0, Math.min(speeds.length - 1, i + dir))])
    }
    function frameStep(dir) {
        if (!hasMedia || !player.hasVideo) return
        if (playing) player.pause()
        var step = frameMs()
        // Start from the exact time of the frame on screen; player.position is rounded down to whole ms.
        var shown = backend.frameStartMs(videoOut.videoSink)
        if (shown < 0) shown = Math.floor(player.position / step + 0.05) * step
        var target = Math.max(0, Math.min(player.duration, shown + (dir + 0.5) * step))
        player.setPosition(Math.round(target))
        osd(fmtPrecise(target))
    }
    function toggleFullscreen() {
        if (fullscreen) {
            if (wasMaximized) win.showMaximized()
            else win.showNormal()
        } else {
            wasMaximized = win.visibility === Window.Maximized
            win.showFullScreen()
        }
    }
    function saveFrame() {
        if (hasMedia && player.hasVideo)
            backend.saveFrame(videoOut.videoSink, player.position)
    }
    function refreshInfo() { infoRows = hasMedia ? backend.mediaInfo(player, videoOut.videoSink) : [] }
    function refreshTracks() {
        audioNames = backend.trackNames(player, 0)
        subtitleNames = backend.trackNames(player, 1)
    }
    function openUpdates() {
        updatesOpen = true
        if (["available", "installing", "restarting", "checking"].indexOf(backend.updateState) < 0)
            backend.checkForUpdates(false)
    }
    function handleKey(e) {
        var ctrl = (e.modifiers & Qt.ControlModifier) !== 0
        if (keysOpen && e.key === Qt.Key_Escape) { keysOpen = false; e.accepted = true; return }
        if (updatesOpen && e.key === Qt.Key_Escape) { if (!updateBusy) updatesOpen = false; e.accepted = true; return }
        switch (e.key) {
        case Qt.Key_Space: case Qt.Key_K: case Qt.Key_MediaPlay: case Qt.Key_MediaPause:
        case Qt.Key_MediaTogglePlayPause: togglePlay(); break
        case Qt.Key_Left: seekBy(ctrl ? -60000 : -5000); break
        case Qt.Key_Right: seekBy(ctrl ? 60000 : 5000); break
        case Qt.Key_J: seekBy(-10000); break
        case Qt.Key_L: seekBy(10000); break
        case Qt.Key_Up: changeVolume(0.05); break
        case Qt.Key_Down: changeVolume(-0.05); break
        case Qt.Key_M: toggleMute(); break
        case Qt.Key_F: case Qt.Key_F11: case Qt.Key_Return: case Qt.Key_Enter: toggleFullscreen(); break
        case Qt.Key_Escape:
            if (fullscreen) toggleFullscreen()
            else infoOpen = false
            break
        case Qt.Key_Comma: frameStep(-1); break
        case Qt.Key_Period: frameStep(1); break
        case Qt.Key_BracketLeft: changeSpeed(-1); break
        case Qt.Key_BracketRight: changeSpeed(1); break
        case Qt.Key_Backspace: setSpeed(1); break
        case Qt.Key_PageUp: case Qt.Key_MediaPrevious: stepVideo(-1); break
        case Qt.Key_PageDown: case Qt.Key_MediaNext: stepVideo(1); break
        case Qt.Key_Home: if (hasMedia) { player.setPosition(0); poke() } break
        case Qt.Key_S: if (!ctrl) saveFrame(); break
        case Qt.Key_I: if (hasMedia) infoOpen = !infoOpen; break
        case Qt.Key_O: if (ctrl) openDialog.open(); break
        default:
            if (e.key >= Qt.Key_0 && e.key <= Qt.Key_9 && !ctrl) {
                if (hasMedia && player.duration > 0) { player.setPosition(player.duration * (e.key - Qt.Key_0) / 10); poke() }
                break
            }
            return
        }
        e.accepted = true
    }

    onClosing: rememberPosition()
    Component.onCompleted: { poke(); focusKeys() }

    Connections {
        target: backend
        function onOpenRequested(target) { win.openUrl(target) }
        function onFrameSaved(path) { win.osd(win.tr("frame_saved")) }
        function onFrameSaveFailed() { win.osd(win.tr("frame_failed")) }
        function onUpdateInstalled() { win.rememberPosition(); backend.restartApp(backend.currentPath) }
    }

    Timer { id: idleTimer; interval: 2500; onTriggered: win.mouseActive = false }
    Timer { interval: 4000; running: true; onTriggered: backend.checkForUpdates(true) }   // a quiet look at GitHub
    Timer { id: osdTimer; interval: 1500; onTriggered: osdBox.opacity = 0 }
    Timer { id: clickTimer; interval: 240; onTriggered: win.togglePlay() }
    Timer { id: infoTimer; interval: 1000; repeat: true; triggeredOnStart: true; running: win.infoOpen && win.hasMedia; onTriggered: win.refreshInfo() }
    Timer {
        id: seekThrottle
        interval: 90
        onTriggered: if (win.seekPending >= 0) { player.setPosition(win.seekPending); win.seekPending = -1 }
    }

    // ------------------------------------------------------------ playback
    MediaPlayer {
        id: player
        objectName: "player"
        videoOutput: videoOut
        audioOutput: AudioOutput {
            volume: Math.pow(backend.volume, 3)     // a curve that sounds even across the slider
            muted: backend.muted
        }
        loops: backend.repeat ? MediaPlayer.Infinite : 1
        onSourceChanged: { win.audioNames = []; win.subtitleNames = [] }
        onTracksChanged: win.refreshTracks()
        onMediaStatusChanged: {
            // Continue where you stopped; the seek has to wait until playback is really running.
            if (mediaStatus === MediaPlayer.BufferedMedia && win.pendingResume > 0) {
                var ms = win.pendingResume
                win.pendingResume = 0
                Qt.callLater(function() { player.setPosition(ms) })
                win.osd(win.tr("resumed", { time: win.fmtTime(ms) }))
            }
            if (mediaStatus === MediaPlayer.EndOfMedia)
                Qt.callLater(win.holdLastFrame)
            if (mediaStatus === MediaPlayer.InvalidMedia && win.errorText === "")
                win.errorText = errorString !== "" ? errorString : win.tr("cant_play")
        }
        onErrorOccurred: (error, message) => { win.errorText = message !== "" ? message : win.tr("cant_play") }
    }

    Item {
        id: keyScope
        anchors.fill: parent
        focus: true
        Keys.onPressed: (event) => win.handleKey(event)
    }

    VideoOutput {
        id: videoOut
        objectName: "videoOut"
        anchors.fill: parent
        fillMode: VideoOutput.PreserveAspectFit
        visible: win.hasMedia
    }

    // Audio files: a note instead of a black screen
    Column {
        anchors.centerIn: parent
        spacing: 14
        visible: win.hasMedia && !player.hasVideo && win.errorText === ""
                 && (player.mediaStatus === MediaPlayer.BufferedMedia || player.mediaStatus === MediaPlayer.EndOfMedia)
        Text { anchors.horizontalCenter: parent.horizontalCenter; text: ""; font.family: win.icons; font.pixelSize: 72; color: "#55ffffff" }
        Text { anchors.horizontalCenter: parent.horizontalCenter; text: backend.currentName; color: win.ink; font.pixelSize: 18; font.family: "Segoe UI" }
    }

    MouseArea {
        id: videoMouse
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: (win.controlsShown || !win.hasMedia) ? Qt.ArrowCursor : Qt.BlankCursor
        onPositionChanged: win.poke()
        onClicked: (mouse) => {
            win.focusKeys()
            if (mouse.button === Qt.RightButton) moreMenu.popup()
            else if (win.hasMedia) clickTimer.restart()
        }
        onDoubleClicked: (mouse) => {
            if (mouse.button !== Qt.LeftButton) return
            clickTimer.stop()
            if (win.hasMedia) win.toggleFullscreen()
        }
        onWheel: (wheel) => { if (win.hasMedia) win.changeVolume(wheel.angleDelta.y > 0 ? 0.05 : -0.05) }
    }

    // ------------------------------------------------------------ start screen
    Rectangle {
        id: home
        anchors.fill: parent
        visible: !win.hasMedia
        gradient: Gradient {
            GradientStop { position: 0; color: "#191a21" }
            GradientStop { position: 1; color: "#0b0b0e" }
        }

        Column {
            anchors.centerIn: parent
            width: Math.min(parent.width - 48, 500)
            LayoutMirroring.enabled: backend.rtl
            LayoutMirroring.childrenInherit: true

            Image {
                anchors.horizontalCenter: parent.horizontalCenter
                source: Qt.resolvedUrl("../assets/t-player.png")
                width: 88; height: 88
                sourceSize: Qt.size(176, 176)
                smooth: true; mipmap: true
            }
            Item { width: 1; height: 12 }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "T-Player"
                color: win.ink
                font.pixelSize: 30; font.weight: Font.DemiBold; font.family: "Segoe UI"
            }
            Item { width: 1; height: 26 }
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: openRow.implicitWidth + 48; height: 50; radius: 25
                color: openArea.pressed ? Qt.darker(win.accent, 1.15) : openArea.containsMouse ? Qt.lighter(win.accent, 1.08) : win.accent
                Row {
                    id: openRow
                    anchors.centerIn: parent
                    spacing: 10
                    Text { anchors.verticalCenter: parent.verticalCenter; text: ""; font.family: win.icons; font.pixelSize: 17; color: "white" }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: win.tr("open_video")
                        color: "white"; font.pixelSize: Math.round(16 * win.fs); font.weight: Font.DemiBold; font.family: backend.fontFamily
                    }
                }
                MouseArea { id: openArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: openDialog.open() }
            }
            Item { width: 1; height: 12 }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: win.tr("drop_hint")
                color: win.dim; font.pixelSize: Math.round(13 * win.fs); font.family: backend.fontFamily
            }
            Item { width: 1; height: 36; visible: backend.recent.length > 0 }
            Item {
                width: parent.width; height: 28
                visible: backend.recent.length > 0
                Text {
                    anchors.left: parent.left; anchors.leftMargin: 12; anchors.verticalCenter: parent.verticalCenter
                    text: win.tr("recent")
                    color: win.dim; font.pixelSize: Math.round(13 * win.fs); font.weight: Font.DemiBold; font.family: backend.fontFamily
                }
                Text {
                    anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter
                    text: win.tr("clear_recent")
                    color: clearArea.containsMouse ? win.ink : win.dim; font.pixelSize: Math.round(12 * win.fs); font.family: backend.fontFamily
                    MouseArea { id: clearArea; anchors.fill: parent; anchors.margins: -6; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: backend.clearRecent() }
                }
            }
            Repeater {
                model: backend.recent
                delegate: Rectangle {
                    required property var modelData
                    width: parent ? parent.width : 0
                    height: 48; radius: 10
                    color: recentArea.containsMouse ? "#1affffff" : "transparent"
                    Text {
                        id: recentIcon
                        anchors.left: parent.left; anchors.leftMargin: 14; anchors.verticalCenter: parent.verticalCenter
                        text: ""; font.family: win.icons; font.pixelSize: 16; color: win.dim
                    }
                    Column {
                        anchors.left: recentIcon.right; anchors.leftMargin: 14
                        anchors.right: parent.right; anchors.rightMargin: 14
                        anchors.verticalCenter: parent.verticalCenter
                        Text { width: parent.width; horizontalAlignment: Text.AlignLeft; text: modelData.name; color: win.ink; font.pixelSize: 14; font.family: "Segoe UI"; elide: Text.ElideMiddle }
                        Text { width: parent.width; horizontalAlignment: Text.AlignLeft; text: modelData.folder; color: win.dim; font.pixelSize: 11; font.family: "Segoe UI"; elide: Text.ElideMiddle }
                    }
                    MouseArea { id: recentArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: win.openUrl(modelData.path) }
                }
            }
        }

        // Version, and "Check for updates" (a blue "Update available" button when GitHub has one)
        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 18
            spacing: 14
            LayoutMirroring.enabled: backend.rtl
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "T-Player " + backend.version
                color: "#6d707b"; font.pixelSize: 12; font.family: "Segoe UI"
            }
            Rectangle {
                readonly property bool available: backend.updateState === "available"
                anchors.verticalCenter: parent.verticalCenter
                width: updateLink.implicitWidth + (available ? 28 : 0)
                height: 28; radius: 14
                color: !available ? "transparent" : updateArea.containsMouse ? Qt.lighter(win.accent, 1.12) : win.accent
                Text {
                    id: updateLink
                    anchors.centerIn: parent
                    text: parent.available ? win.tr("update_available") : win.tr("check_updates")
                    color: parent.available ? "white" : updateArea.containsMouse ? win.ink : win.dim
                    font.pixelSize: Math.round(12 * win.fs); font.family: backend.fontFamily
                    font.weight: parent.available ? Font.DemiBold : Font.Normal
                    font.underline: !parent.available && updateArea.containsMouse
                }
                MouseArea { id: updateArea; anchors.fill: parent; anchors.margins: -4; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: win.openUpdates() }
            }
        }
    }

    // ------------------------------------------------------------ top: file name
    Item {
        anchors { left: parent.left; right: parent.right; top: parent.top }
        height: 70
        opacity: win.hasMedia && win.controlsShown ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 180 } }
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0; color: "#b3000000" }
                GradientStop { position: 1; color: "#00000000" }
            }
        }
        Text {
            anchors { left: parent.left; right: countText.left; top: parent.top; leftMargin: 18; rightMargin: 14; topMargin: 14 }
            text: backend.currentName
            color: win.ink; font.pixelSize: 15; font.family: "Segoe UI"; elide: Text.ElideMiddle
            horizontalAlignment: Text.AlignLeft
        }
        Text {
            id: countText
            anchors { right: parent.right; top: parent.top; rightMargin: 18; topMargin: 15 }
            text: backend.playlistText
            color: win.dim; font.pixelSize: 13; font.family: "Segoe UI"
        }
    }

    // ------------------------------------------------------------ bottom: the control bar
    Item {
        id: bottomBar
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: 112
        opacity: win.hasMedia && win.controlsShown ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 180 } }
        HoverHandler { id: barHover }
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0; color: "#00000000" }
                GradientStop { position: 1; color: "#d0000000" }
            }
        }

        SeekBar {
            id: seek
            anchors { left: parent.left; right: parent.right; bottom: buttons.top; leftMargin: 18; rightMargin: 18; bottomMargin: 4 }
            value: player.duration > 0 ? player.position / player.duration : 0
            duration: player.duration
            onScrub: (fraction, final) => win.scrubTo(fraction, final)
        }

        Item {
            id: buttons
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom; leftMargin: 10; rightMargin: 10; bottomMargin: 10 }
            height: 48

            Row {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2
                IconButton {
                    anchors.verticalCenter: parent.verticalCenter
                    glyph: ""; flip: true; tip: win.tr("previous")
                    visible: backend.playlistCount > 1
                    onClicked: win.stepVideo(-1)
                }
                Item {
                    id: playButton
                    anchors.verticalCenter: parent.verticalCenter
                    width: 48; height: 48
                    Rectangle { anchors.fill: parent; radius: 24; color: playArea.pressed ? "#40ffffff" : playArea.containsMouse ? "#2effffff" : "transparent" }
                    Text {
                        visible: !win.playing
                        anchors.centerIn: parent; anchors.horizontalCenterOffset: 2
                        text: ""; font.family: win.icons; font.pixelSize: 22; color: win.ink
                    }
                    Row {
                        visible: win.playing
                        anchors.centerIn: parent
                        spacing: 6
                        Rectangle { width: 5; height: 20; radius: 1.5; color: win.ink }
                        Rectangle { width: 5; height: 20; radius: 1.5; color: win.ink }
                    }
                    MouseArea { id: playArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: win.togglePlay() }
                    ToolTip.visible: playArea.containsMouse
                    ToolTip.delay: 700
                    ToolTip.text: win.playing ? win.tr("pause") : win.tr("play")
                }
                IconButton {
                    anchors.verticalCenter: parent.verticalCenter
                    glyph: ""; tip: win.tr("next")
                    visible: backend.playlistCount > 1
                    onClicked: win.stepVideo(1)
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    leftPadding: 10
                    color: win.ink; font.pixelSize: 14; font.family: "Segoe UI"
                    font.features: { "tnum": 1 }
                    text: {
                        var pos = seek.pressed ? seek.dragValue * player.duration : player.position
                        return (win.showRemaining ? "-" + win.fmtTime(player.duration - pos) : win.fmtTime(pos))
                               + "  /  " + win.fmtTime(player.duration)
                    }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: win.showRemaining = !win.showRemaining }
                }
            }

            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2
                IconButton {
                    anchors.verticalCenter: parent.verticalCenter
                    glyph: backend.muted || backend.volume === 0 ? "" : backend.volume < 0.34 ? "" : backend.volume < 0.67 ? "" : ""
                    tip: backend.muted ? win.tr("unmute") : win.tr("mute")
                    onClicked: win.toggleMute()
                }
                VolumeSlider {
                    anchors.verticalCenter: parent.verticalCenter
                    value: backend.volume
                    muted: backend.muted
                    onMoved: (v) => win.setVolume(v)
                }
                Item { width: 8; height: 1 }
                IconButton {
                    id: moreButton
                    anchors.verticalCenter: parent.verticalCenter
                    glyph: ""; tip: win.tr("more")
                    onClicked: moreMenu.popup(moreButton, moreButton.width - moreMenu.implicitWidth, -moreMenu.implicitHeight - 6)
                    Rectangle {      // a blue dot when an update is waiting
                        visible: backend.updateState === "available"
                        width: 10; height: 10; radius: 5
                        color: win.accent
                        border.color: "#000000"; border.width: 1.5
                        anchors { right: parent.right; top: parent.top; rightMargin: 6; topMargin: 6 }
                    }
                }
                IconButton {
                    anchors.verticalCenter: parent.verticalCenter
                    glyph: win.fullscreen ? "" : ""
                    tip: win.fullscreen ? win.tr("exit_fullscreen") : win.tr("fullscreen")
                    onClicked: win.toggleFullscreen()
                }
            }
        }
    }

    // ------------------------------------------------------------ play / pause flash in the middle
    Rectangle {
        id: flash
        anchors.centerIn: parent
        width: 84; height: 84; radius: 42
        color: "#8c000000"
        opacity: 0
        property bool playIcon: true
        function show(isPlay) { playIcon = isPlay; flashAnim.restart() }
        Text {
            visible: flash.playIcon
            anchors.centerIn: parent; anchors.horizontalCenterOffset: 3
            text: ""; font.family: win.icons; font.pixelSize: 32; color: "white"
        }
        Row {
            visible: !flash.playIcon
            anchors.centerIn: parent
            spacing: 8
            Rectangle { width: 7; height: 28; radius: 2; color: "white" }
            Rectangle { width: 7; height: 28; radius: 2; color: "white" }
        }
        ParallelAnimation {
            id: flashAnim
            NumberAnimation { target: flash; property: "opacity"; from: 0.9; to: 0; duration: 650; easing.type: Easing.InQuad }
            NumberAnimation { target: flash; property: "scale"; from: 0.85; to: 1.25; duration: 650; easing.type: Easing.OutQuad }
        }
    }

    // ------------------------------------------------------------ short messages (volume, speed, ...)
    Rectangle {
        id: osdBox
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: 62
        width: osdText.implicitWidth + 30
        height: osdText.implicitHeight + 16
        radius: 10
        color: "#d9111217"
        opacity: 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 160 } }
        Text {
            id: osdText
            objectName: "osdText"
            anchors.centerIn: parent
            color: win.ink
            font.pixelSize: Math.round(16 * win.fs); font.family: backend.fontFamily
        }
    }

    // ------------------------------------------------------------ "can't play" card
    Rectangle {
        visible: win.hasMedia && win.errorText !== ""
        anchors.centerIn: parent
        width: Math.min(parent.width - 60, 520)
        height: errorColumn.implicitHeight + 40
        radius: 14
        color: "#f214151b"
        border.color: "#550099ff"
        Column {
            id: errorColumn
            anchors.centerIn: parent
            width: parent.width - 40
            spacing: 8
            Text { width: parent.width; horizontalAlignment: Text.AlignHCenter; text: win.tr("cant_play"); color: win.ink; font.pixelSize: Math.round(18 * win.fs); font.weight: Font.DemiBold; font.family: backend.fontFamily }
            Text { width: parent.width; horizontalAlignment: Text.AlignHCenter; text: backend.currentName; color: win.dim; font.pixelSize: 13; font.family: "Segoe UI"; elide: Text.ElideMiddle }
            Text { width: parent.width; horizontalAlignment: Text.AlignHCenter; text: win.errorText; color: win.dim; font.pixelSize: 12; font.family: "Segoe UI"; wrapMode: Text.Wrap }
        }
    }

    // ------------------------------------------------------------ video info panel
    Rectangle {
        id: infoPanel
        visible: win.infoOpen && win.hasMedia
        anchors { top: parent.top; right: parent.right; topMargin: 62; rightMargin: 18 }
        width: 380
        height: infoColumn.implicitHeight + 28
        radius: 12
        color: "#eb14151b"
        border.color: "#22ffffff"
        LayoutMirroring.enabled: backend.rtl
        LayoutMirroring.childrenInherit: true
        MouseArea { anchors.fill: parent }     // clicks on the panel don't pause the video
        Column {
            id: infoColumn
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 14 }
            spacing: 7
            Item {
                width: parent.width; height: 28
                Text {
                    anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                    text: win.tr("media_info"); color: win.ink
                    font.pixelSize: Math.round(15 * win.fs); font.weight: Font.DemiBold; font.family: backend.fontFamily
                }
                IconButton {
                    anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    width: 30; height: 30; glyph: ""; glyphSize: 11; tip: win.tr("close")
                    onClicked: win.infoOpen = false
                }
            }
            Repeater {
                model: win.infoRows
                delegate: Item {
                    required property var modelData
                    width: infoColumn.width
                    height: Math.max(infoLabel.implicitHeight, infoValue.implicitHeight)
                    Text {
                        id: infoLabel
                        anchors.left: parent.left
                        width: 128
                        horizontalAlignment: Text.AlignLeft      // explicit, so right-to-left mirrors it too
                        text: modelData.label; color: win.dim; elide: Text.ElideRight
                        font.pixelSize: Math.round(13 * win.fs); font.family: backend.fontFamily
                    }
                    Text {
                        id: infoValue
                        anchors.left: infoLabel.right; anchors.right: parent.right; anchors.leftMargin: 8
                        horizontalAlignment: Text.AlignLeft
                        text: modelData.value; color: win.ink; wrapMode: Text.WrapAnywhere
                        font.pixelSize: modelData.value === win.tr("decoder_gpu") || modelData.value === win.tr("decoder_cpu") ? Math.round(13 * win.fs) : 13
                        font.family: modelData.value === win.tr("decoder_gpu") || modelData.value === win.tr("decoder_cpu") ? backend.fontFamily : "Segoe UI"
                    }
                }
            }
        }
    }

    // ------------------------------------------------------------ keyboard shortcuts panel
    Rectangle {
        anchors.fill: parent
        visible: win.keysOpen
        color: "#99000000"
        MouseArea { anchors.fill: parent; onClicked: win.keysOpen = false }
        Rectangle {
            anchors.centerIn: parent
            width: Math.min(parent.width - 40, 560)
            height: Math.min(parent.height - 40, keysColumn.implicitHeight + 32)
            radius: 14
            color: "#f514151b"
            border.color: "#22ffffff"
            clip: true
            LayoutMirroring.enabled: backend.rtl
            LayoutMirroring.childrenInherit: true
            MouseArea { anchors.fill: parent }
            Column {
                id: keysColumn
                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 18 }
                spacing: 4
                Item {
                    width: parent.width; height: 34
                    Text {
                        anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                        text: win.tr("shortcuts"); color: win.ink
                        font.pixelSize: Math.round(16 * win.fs); font.weight: Font.DemiBold; font.family: backend.fontFamily
                    }
                    IconButton {
                        anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                        width: 30; height: 30; glyph: ""; glyphSize: 11; tip: win.tr("close")
                        onClicked: win.keysOpen = false
                    }
                }
                Repeater {
                    model: [["Space", "key_play"], ["←  →", "key_seek"], ["Ctrl + ←  →", "key_seek_long"],
                            ["↑  ↓", "key_volume"], ["M", "key_mute"], ["F  /  Enter", "key_fullscreen"],
                            ["Esc", "key_exit"], [",  .", "key_frame"], ["[  ]  Backspace", "key_speed"],
                            ["Page Up  /  Page Down", "key_video"], ["0 … 9", "key_jump"], ["S", "key_picture"],
                            ["I", "key_info"], ["Ctrl + O", "key_open"]]
                    delegate: Item {
                        required property var modelData
                        width: keysColumn.width
                        height: Math.max(28, keyDesc.implicitHeight + 6)
                        Text {
                            id: keyName
                            anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                            width: 180
                            horizontalAlignment: Text.AlignLeft
                            text: "‎" + modelData[0]      // key names always read left to right
                            color: win.accent
                            font.pixelSize: 13; font.weight: Font.DemiBold; font.family: "Segoe UI"
                        }
                        Text {
                            id: keyDesc
                            anchors.left: keyName.right; anchors.right: parent.right; anchors.leftMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            horizontalAlignment: Text.AlignLeft
                            text: win.tr(modelData[1]); color: win.ink; wrapMode: Text.Wrap
                            font.pixelSize: Math.round(13 * win.fs); font.family: backend.fontFamily
                        }
                    }
                }
            }
        }
    }

    // ------------------------------------------------------------ updates panel
    Rectangle {
        anchors.fill: parent
        visible: win.updatesOpen
        color: "#99000000"
        MouseArea { anchors.fill: parent; onClicked: if (!win.updateBusy) win.updatesOpen = false }
        Rectangle {
            anchors.centerIn: parent
            width: Math.min(parent.width - 40, 520)
            height: updateColumn.implicitHeight + 40
            radius: 14
            color: "#f514151b"
            border.color: "#22ffffff"
            LayoutMirroring.enabled: backend.rtl
            LayoutMirroring.childrenInherit: true
            MouseArea { anchors.fill: parent }
            Column {
                id: updateColumn
                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 20 }
                spacing: 14
                Item {
                    width: parent.width; height: 32
                    Text {
                        anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                        text: win.tr("updates"); color: win.ink
                        font.pixelSize: Math.round(17 * win.fs); font.weight: Font.DemiBold; font.family: backend.fontFamily
                    }
                    IconButton {
                        anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                        width: 30; height: 30; glyph: ""; glyphSize: 11; tip: win.tr("close")
                        visible: !win.updateBusy
                        onClicked: win.updatesOpen = false
                    }
                }
                Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignLeft
                    // the version is wrapped as left-to-right text, so Uyghur and Arabic don't reorder its date
                    text: win.tr("upd_version", { version: "‪" + backend.versionText + "‬" })
                    color: win.dim; font.pixelSize: Math.round(13 * win.fs); font.family: backend.fontFamily
                }
                Item {
                    width: parent.width
                    height: Math.max(updateMessage.implicitHeight, busy.visible ? 28 : 0)
                    BusyIndicator {
                        id: busy
                        anchors.left: parent.left; anchors.top: parent.top
                        width: 28; height: 28
                        visible: win.updateBusy
                        running: visible
                    }
                    Text {
                        id: updateMessage
                        anchors.left: busy.visible ? busy.right : parent.left
                        anchors.leftMargin: busy.visible ? 10 : 0
                        anchors.right: parent.right
                        anchors.verticalCenter: busy.visible ? busy.verticalCenter : undefined
                        horizontalAlignment: Text.AlignLeft
                        text: backend.updateText
                        color: backend.updateState === "error" ? "#ff8a80" : win.ink
                        wrapMode: Text.Wrap
                        lineHeight: 1.15
                        font.pixelSize: Math.round(14 * win.fs); font.family: backend.fontFamily
                    }
                }
                Row {
                    spacing: 10
                    visible: !win.updateBusy
                    PillButton {
                        label: win.tr("install_update")
                        primary: true
                        visible: backend.updateState === "available"
                        onClicked: backend.installUpdate()
                    }
                    PillButton {
                        label: win.tr("check_again")
                        onClicked: backend.checkForUpdates(false)
                    }
                }
            }
        }
    }

    // ------------------------------------------------------------ drag and drop
    DropArea {
        id: drop
        anchors.fill: parent
        onEntered: (drag) => { if (drag.hasUrls) drag.accept(Qt.CopyAction) }
        onDropped: (dropEvent) => {
            if (dropEvent.hasUrls && dropEvent.urls.length > 0) {
                dropEvent.accept(Qt.CopyAction)
                win.openUrl(dropEvent.urls[0])
            }
        }
    }
    Rectangle {
        anchors.fill: parent
        anchors.margins: 10
        visible: drop.containsDrag
        color: "#1a0099ff"
        radius: 16
        border.color: win.accent
        border.width: 3
    }

    // ------------------------------------------------------------ the "..." / right-click menu
    Menu {
        id: moreMenu
        objectName: "moreMenu"
        delegate: MItem {}     // the rows that open the sub-menus
        onClosed: win.focusKeys()

        Menu {
            id: speedMenu
            title: win.tr("speed")
            enabled: win.hasMedia
            Instantiator {
                model: win.speeds
                delegate: MItem {
                    required property var modelData
                    text: win.speedName(modelData)
                    checkable: true
                    checked: Math.abs(player.playbackRate - modelData) < 0.001
                    onTriggered: {
                        win.setSpeed(modelData)
                        checked = Qt.binding(function() { return Math.abs(player.playbackRate - modelData) < 0.001 })
                    }
                }
                onObjectAdded: (index, object) => speedMenu.insertItem(index, object)
                onObjectRemoved: (index, object) => speedMenu.removeItem(object)
            }
        }
        Menu {
            id: audioMenu
            title: win.tr("audio_track")
            enabled: win.audioNames.length > 1
            Instantiator {
                model: win.audioNames
                delegate: MItem {
                    required property int index
                    required property var modelData
                    text: modelData
                    checkable: true
                    checked: player.activeAudioTrack === index
                    onTriggered: {
                        player.activeAudioTrack = index
                        checked = Qt.binding(function() { return player.activeAudioTrack === index })
                    }
                }
                onObjectAdded: (index, object) => audioMenu.insertItem(index, object)
                onObjectRemoved: (index, object) => audioMenu.removeItem(object)
            }
        }
        Menu {
            id: subtitleMenu
            title: win.tr("subtitles")
            enabled: win.subtitleNames.length > 0
            MItem {
                id: subtitlesOff
                text: win.tr("off")
                checkable: true
                checked: player.activeSubtitleTrack < 0
                onTriggered: {
                    player.activeSubtitleTrack = -1
                    checked = Qt.binding(function() { return player.activeSubtitleTrack < 0 })
                }
            }
            Instantiator {
                model: win.subtitleNames
                delegate: MItem {
                    required property int index
                    required property var modelData
                    text: modelData
                    checkable: true
                    checked: player.activeSubtitleTrack === index
                    onTriggered: {
                        player.activeSubtitleTrack = index
                        checked = Qt.binding(function() { return player.activeSubtitleTrack === index })
                    }
                }
                onObjectAdded: (index, object) => subtitleMenu.insertItem(index + 1, object)
                onObjectRemoved: (index, object) => subtitleMenu.removeItem(object)
            }
        }
        MenuSeparator {}
        MItem { text: win.tr("save_frame"); enabled: win.hasMedia && player.hasVideo; onTriggered: win.saveFrame() }
        MItem { text: win.tr("media_info"); enabled: win.hasMedia; onTriggered: win.infoOpen = !win.infoOpen }
        MItem { text: win.tr("show_in_folder"); enabled: win.hasMedia; onTriggered: backend.showInFolder(backend.currentPath) }
        MenuSeparator {}
        MItem { text: win.tr("repeat"); checkable: true; checked: backend.repeat; onToggled: backend.repeat = checked }
        MItem { text: win.tr("always_on_top"); checkable: true; checked: backend.onTop; onToggled: backend.onTop = checked }
        Menu {
            id: languageMenu
            title: win.tr("language")
            Instantiator {
                model: backend.languages
                delegate: MItem {
                    required property var modelData
                    text: modelData.name
                    checkable: true
                    checked: backend.language === modelData.code
                    onTriggered: {
                        backend.language = modelData.code
                        checked = Qt.binding(function() { return backend.language === modelData.code })
                    }
                }
                onObjectAdded: (index, object) => languageMenu.insertItem(index, object)
                onObjectRemoved: (index, object) => languageMenu.removeItem(object)
            }
        }
        MItem { text: win.tr("shortcuts"); onTriggered: win.keysOpen = true }
        MItem {
            text: backend.updateState === "available" ? win.tr("update_available") : win.tr("check_updates")
            onTriggered: win.openUpdates()
        }
        MenuSeparator {}
        MItem { text: win.tr("open_video"); onTriggered: openDialog.open() }
    }

    FileDialog {
        id: openDialog
        title: win.tr("open_video")
        nameFilters: [win.tr("filter_videos") + " (" + backend.mediaPatterns + ")", win.tr("filter_all") + " (*)"]
        currentFolder: backend.lastFolderUrl
        onAccepted: win.openUrl(selectedFile)
        onRejected: win.focusKeys()
    }

    // ============================================================ small building blocks

    // Menu rows that turn right-to-left for Uyghur and Arabic (Qt 6 no longer does that from the locale).
    component MItem: MenuItem {
        LayoutMirroring.enabled: backend.rtl
        LayoutMirroring.childrenInherit: true
    }

    component IconButton: Item {
        id: button
        property string glyph: ""
        property string tip: ""
        property int glyphSize: 16
        property bool flip: false
        signal clicked()
        width: 42; height: 42
        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: area.pressed ? "#40ffffff" : area.containsMouse ? "#26ffffff" : "transparent"
        }
        Text {
            id: glyphText
            anchors.centerIn: parent
            text: button.glyph
            font.family: "Segoe MDL2 Assets"
            font.pixelSize: button.glyphSize
            color: "#f4f4f7"
            transform: Scale { origin.x: glyphText.width / 2; xScale: button.flip ? -1 : 1 }
        }
        MouseArea { id: area; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: button.clicked() }
        ToolTip.visible: area.containsMouse && button.tip !== ""
        ToolTip.delay: 700
        ToolTip.text: button.tip
    }

    component PillButton: Rectangle {
        id: pill
        property string label: ""
        property bool primary: false
        signal clicked()
        width: pillText.implicitWidth + 40
        height: 40
        radius: 20
        color: primary ? (pillArea.pressed ? "#0080d6" : pillArea.containsMouse ? "#24a8ff" : "#0099ff")
                       : (pillArea.pressed ? "#40ffffff" : pillArea.containsMouse ? "#2effffff" : "#1fffffff")
        Text {
            id: pillText
            anchors.centerIn: parent
            text: pill.label
            color: "#ffffff"
            font.pixelSize: Math.round(14 * backend.fontScale); font.weight: Font.DemiBold; font.family: backend.fontFamily
        }
        MouseArea { id: pillArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: pill.clicked() }
    }

    component SeekBar: Item {
        id: bar
        property real value: 0              // played part, 0..1
        property real duration: 0           // ms, for the time bubble
        property real dragValue: 0
        property real hoverValue: 0
        readonly property bool pressed: area.pressed
        readonly property bool hot: area.containsMouse || area.pressed
        readonly property real shown: (area.pressed || hold.running) ? dragValue : value
        signal scrub(real fraction, bool final)
        height: 24

        function frac(x) { return Math.max(0, Math.min(1, x / width)) }
        function clock(ms) {
            var t = Math.max(0, Math.floor(ms / 1000)), h = Math.floor(t / 3600), m = Math.floor(t / 60) % 60, s = t % 60
            var two = function(n) { return (n < 10 ? "0" : "") + n }
            return h > 0 ? h + ":" + two(m) + ":" + two(s) : m + ":" + two(s)
        }

        Timer { id: hold; interval: 450 }     // keeps the knob still while the seek finishes
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: bar.hot ? 6 : 4
            radius: height / 2
            color: "#4dffffff"
            Behavior on height { NumberAnimation { duration: 90 } }
            Rectangle {
                visible: bar.hot
                width: parent.width * bar.hoverValue
                height: parent.height; radius: parent.radius
                color: "#33ffffff"
            }
            Rectangle {
                width: Math.max(parent.height, parent.width * bar.shown)
                height: parent.height; radius: parent.radius
                color: "#0099ff"
            }
        }
        Rectangle {
            width: 14; height: 14; radius: 7
            color: "#0099ff"
            anchors.verticalCenter: parent.verticalCenter
            x: bar.width * bar.shown - width / 2
            visible: bar.hot
        }
        Rectangle {
            visible: bar.hot && bar.duration > 0
            width: bubble.implicitWidth + 16; height: 26; radius: 7
            color: "#eb111217"
            y: -height - 8
            x: Math.max(0, Math.min(bar.width - width, bar.width * (bar.pressed ? bar.dragValue : bar.hoverValue) - width / 2))
            Text {
                id: bubble
                anchors.centerIn: parent
                color: "#f4f4f7"; font.pixelSize: 12; font.family: "Segoe UI"
                text: bar.clock(bar.duration * (bar.pressed ? bar.dragValue : bar.hoverValue))
            }
        }
        MouseArea {
            id: area
            anchors.fill: parent
            anchors.topMargin: -6
            anchors.bottomMargin: -6
            hoverEnabled: true
            preventStealing: true
            cursorShape: Qt.PointingHandCursor
            onPositionChanged: (mouse) => {
                bar.hoverValue = bar.frac(mouse.x)
                if (pressed) { bar.dragValue = bar.hoverValue; bar.scrub(bar.dragValue, false) }
            }
            onPressed: (mouse) => { bar.dragValue = bar.frac(mouse.x); bar.hoverValue = bar.dragValue; bar.scrub(bar.dragValue, false) }
            onReleased: (mouse) => { bar.dragValue = bar.frac(mouse.x); hold.restart(); bar.scrub(bar.dragValue, true) }
        }
    }

    component VolumeSlider: Item {
        id: slider
        property real value: 0
        property bool muted: false
        signal moved(real v)
        width: 92; height: 30
        readonly property real level: muted ? 0 : value
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width; height: 4; radius: 2
            color: "#4dffffff"
            Rectangle { width: parent.width * slider.level; height: parent.height; radius: 2; color: "#f4f4f7" }
        }
        Rectangle {
            width: 12; height: 12; radius: 6
            color: "#f4f4f7"
            anchors.verticalCenter: parent.verticalCenter
            x: slider.width * slider.level - width / 2
            visible: volumeArea.containsMouse || volumeArea.pressed
        }
        MouseArea {
            id: volumeArea
            anchors.fill: parent
            hoverEnabled: true
            preventStealing: true
            cursorShape: Qt.PointingHandCursor
            function at(x) { return Math.max(0, Math.min(1, x / width)) }
            onPressed: (mouse) => slider.moved(at(mouse.x))
            onPositionChanged: (mouse) => { if (pressed) slider.moved(at(mouse.x)) }
            onWheel: (wheel) => slider.moved(Math.max(0, Math.min(1, slider.value + (wheel.angleDelta.y > 0 ? 0.05 : -0.05))))
        }
    }
}
