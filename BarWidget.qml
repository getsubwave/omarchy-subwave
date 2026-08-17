import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "StationModel.js" as StationModel

BarWidget {
  id: root
  moduleName: "getsubwave.radio"

  property bool playerRunning: false
  property bool playerPaused: false
  property int playerVolume: 70
  property string stationName: "SUB/WAVE"
  property string stationUrl: ""
  property string trackTitle: ""
  property string trackArtist: ""
  property bool stationOnline: true
  readonly property string playerPath: Qt.resolvedUrl("subwave-player").toString().replace(/^file:\/\//, "")
  readonly property string fetchPath: Qt.resolvedUrl("subwave-fetch").toString().replace(/^file:\/\//, "")
  readonly property string statusPath: Quickshell.env("XDG_RUNTIME_DIR") + "/omarchy-subwave/status.json"
  readonly property string label: trackTitle
    ? trackTitle + (trackArtist ? " · " + trackArtist : "")
    : stationName

  function applyStatus(raw) {
    try {
      if (typeof raw !== "string" || raw.length > 65536) return
      var state = JSON.parse(raw || "{}")
      playerRunning = state.running === true
      playerPaused = state.paused === true
      playerVolume = Math.max(0, Math.min(100, Math.round(Number(state.volume || 70))))
      stationName = StationModel.singleLine(state.station && state.station.name || "SUB/WAVE", 160)
      stationUrl = StationModel.normalizeOrigin(state.station && state.station.url || "")
      if (!playerRunning) {
        trackTitle = ""
        trackArtist = ""
      }
      nowTimer.running = playerRunning && stationUrl !== ""
      if (nowTimer.running) refreshNowPlaying()
    } catch (error) {}
  }

  function applyNowPlaying(raw) {
    try {
      if (typeof raw !== "string" || raw.length > 65536) return
      var state = JSON.parse(raw || "{}")
      stationOnline = state.online !== false
      if (state.station) stationName = StationModel.singleLine(state.station, 160)
      if (!state.error) {
        trackTitle = StationModel.singleLine(state.title, 512)
        trackArtist = StationModel.singleLine(state.artist, 512)
      }
    } catch (error) { stationOnline = false }
  }

  function runAction(action, value) {
    if (actionProcess.running) return
    actionProcess.command = value === undefined
      ? [playerPath, action]
      : [playerPath, action, String(value)]
    actionProcess.running = true
  }

  function changeVolume(delta) {
    runAction("volume", Math.max(0, Math.min(100, playerVolume + (delta > 0 ? 5 : -5))))
  }

  function toggleOverlay() {
    var configured = StationModel.normalizeOrigin(setting("stationUrl", ""))
    var payload = JSON.stringify({ stationUrl: configured })
    Quickshell.execDetached(["omarchy-shell", "shell", "toggle", "getsubwave.radio", payload])
  }

  function refreshNowPlaying() {
    if (nowProcess.running || !stationUrl) return
    nowProcess.command = [fetchPath, "now-playing", stationUrl]
    nowProcess.running = true
  }

  implicitWidth: row.implicitWidth + Style.space(14)
  implicitHeight: barSize

  FileView {
    path: root.statusPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.applyStatus(text())
    onFileChanged: reload()
  }

  Process {
    id: statusProcess
    command: [root.playerPath, "status"]
    running: true
    stdout: StdioCollector { id: statusOutput; waitForEnd: true }
    onExited: root.applyStatus(statusOutput.text)
  }

  Process {
    id: actionProcess
    command: []
    stdout: StdioCollector { id: actionOutput; waitForEnd: true }
    onExited: root.applyStatus(actionOutput.text)
  }

  Process {
    id: nowProcess
    command: []
    stdout: StdioCollector { id: nowOutput; waitForEnd: true }
    onExited: root.applyNowPlaying(nowOutput.text)
  }

  Timer {
    id: nowTimer
    interval: 5000
    repeat: true
    running: false
    onTriggered: root.refreshNowPlaying()
  }

  Row {
    id: row
    anchors.centerIn: parent
    spacing: Style.space(6)

    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: "󰝚"
      color: root.playerRunning && !root.playerPaused && root.stationOnline
        ? Color.accent : root.bar.barForeground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.body
    }

    Text {
      visible: !root.vertical
      width: Math.min(implicitWidth, Style.space(180))
      anchors.verticalCenter: parent.verticalCenter
      text: root.label
      color: root.bar.barForeground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
    cursorShape: Qt.PointingHandCursor
    onClicked: function(mouse) {
      if (mouse.button === Qt.MiddleButton) root.runAction("toggle")
      else if (mouse.button === Qt.RightButton) root.runAction("stop")
      else root.toggleOverlay()
    }
    onWheel: function(wheel) { root.changeVolume(wheel.angleDelta.y) }
    onEntered: if (root.bar) root.bar.showTooltip(root,
      (root.playerRunning ? (root.playerPaused ? "Paused · " : "Playing · ") : "Open · ")
      + root.stationName + (root.trackTitle ? "\n" + root.label : "")
      + " · " + root.playerVolume + "%")
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }
}
