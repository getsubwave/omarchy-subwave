import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "StationModel.js" as StationModel

Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null
  property bool opened: false
  property string configuredUrl: ""
  property string configuredInput: ""
  property bool editingConfigured: false
  property bool savingConfigured: false
  property string configuredError: ""
  property var allStations: []
  property string filterText: ""
  property int selectedIndex: 0
  property var liveByUrl: ({})
  property int liveRevision: 0
  property var probeQueue: []
  property string probingUrl: ""
  property string errorText: ""
  property string playingUrl: ""
  readonly property string fetchPath: Qt.resolvedUrl("subwave-fetch").toString().replace(/^file:\/\//, "")
  readonly property string playerPath: Qt.resolvedUrl("subwave-player").toString().replace(/^file:\/\//, "")
  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color border: Color.menu.border
  readonly property color scrim: Color.menu.scrim
  readonly property color accent: Color.accent
  readonly property int cardWidth: Math.min(Style.space(680), panel.width - Style.gapsOut * 2)
  readonly property int cardHeight: Math.min(Style.space(650), panel.height - Style.gapsOut * 2)

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (error) {}
    configuredUrl = StationModel.normalizeOrigin(payload.stationUrl || "")
    configuredInput = configuredUrl
    editingConfigured = false
    savingConfigured = false
    configuredError = ""
    opened = true
    errorText = ""
    filterText = ""
    selectedIndex = 0
    loadCache()
    Qt.callLater(function() { searchField.forceActiveFocus() })
  }

  function close() {
    opened = false
    probeTimer.stop()
    probeQueue = []
  }

  function dismiss() {
    close()
    if (shell && typeof shell.hide === "function") shell.hide((manifest && manifest.id) || "getsubwave.radio")
  }

  function loadCache() {
    if (cacheProcess.running) return
    cacheProcess.command = [fetchPath, "cache"]
    cacheProcess.running = true
  }

  function refreshCatalog() {
    if (catalogProcess.running) return
    catalogProcess.command = [fetchPath, "catalog"]
    catalogProcess.running = true
  }

  function applyCatalog(raw) {
    try {
      if (typeof raw !== "string" || raw.length > 1048576) throw new Error("Directory response is too large")
      var parsed = JSON.parse(raw || "[]")
      allStations = StationModel.mergeConfigured(parsed, configuredUrl)
      rebuildVisible()
      queueVisibleProbes()
    } catch (error) {
      errorText = "Station directory unavailable"
    }
  }

  function rebuildVisible() {
    var rows = StationModel.searchStations(allStations, filterText)
    visibleStations.clear()
    for (var i = 0; i < rows.length; i++) visibleStations.append(rows[i])
    selectedIndex = Math.max(0, Math.min(selectedIndex, visibleStations.count - 1))
    stationList.currentIndex = selectedIndex
  }

  function setFilter(value) {
    filterText = StationModel.singleLine(value, 160)
    rebuildVisible()
    queueVisibleProbes()
  }

  function beginConfiguredEdit() {
    configuredInput = configuredUrl
    configuredError = ""
    editingConfigured = true
    Qt.callLater(function() { configuredField.forceActiveFocus() })
  }

  function cancelConfiguredEdit() {
    configuredInput = configuredUrl
    configuredError = ""
    editingConfigured = false
    Qt.callLater(function() { searchField.forceActiveFocus() })
  }

  function saveConfigured(value) {
    if (settingProcess.running) return
    var update = StationModel.configuredStationUpdate(value)
    if (!update.ok) {
      configuredError = update.error
      return
    }
    configuredError = ""
    savingConfigured = true
    settingProcess.pendingUrl = update.url
    settingProcess.command = update.command
    settingProcess.running = true
  }

  function applyConfigured(url) {
    configuredUrl = url
    configuredInput = url
    allStations = StationModel.mergeConfigured(allStations, configuredUrl)
    rebuildVisible()
    queueVisibleProbes()
    editingConfigured = false
    Qt.callLater(function() { searchField.forceActiveFocus() })
  }

  function moveSelection(delta) {
    if (!visibleStations.count) return
    selectedIndex = (selectedIndex + delta + visibleStations.count) % visibleStations.count
    stationList.currentIndex = selectedIndex
    stationList.positionViewAtIndex(selectedIndex, ListView.Contain)
  }

  function playSelected() {
    if (!visibleStations.count || playProcess.running) return
    var station = visibleStations.get(selectedIndex)
    if (playingUrl === station.url) {
      dismiss()
      return
    }
    errorText = ""
    playProcess.stationUrl = station.url
    playProcess.command = [playerPath, "play", station.url, station.name]
    playProcess.running = true
  }

  function openWebPlayer(url) {
    var command = StationModel.webPlayerCommand(url)
    if (command.length) Quickshell.execDetached(command)
  }

  function queueVisibleProbes() {
    var next = []
    var limit = Math.min(24, visibleStations.count)
    for (var i = 0; i < limit; i++) {
      var url = visibleStations.get(i).url
      if (url !== probingUrl) next.push(url)
    }
    probeQueue = next
    startNextProbe()
  }

  function startNextProbe() {
    if (probeProcess.running || !opened || probeQueue.length === 0) return
    var next = probeQueue.slice()
    probingUrl = next.shift()
    probeQueue = next
    probeProcess.command = [fetchPath, "now-playing", probingUrl]
    probeProcess.running = true
  }

  function applyProbe(url, raw) {
    var state = ({ online: false, error: "Station unavailable" })
    try {
      if (typeof raw === "string" && raw.length <= 65536) state = JSON.parse(raw || "{}")
    } catch (error) {}
    var copy = ({})
    for (var key in liveByUrl) copy[key] = liveByUrl[key]
    copy[url] = state
    liveByUrl = copy
    liveRevision++
  }

  function liveFor(url) {
    var revision = liveRevision
    return liveByUrl[url] || null
  }

  ListModel { id: visibleStations }

  Process {
    id: cacheProcess
    command: []
    stdout: StdioCollector { id: cacheOutput; waitForEnd: true }
    onExited: {
      root.applyCatalog(cacheOutput.text)
      root.refreshCatalog()
    }
  }

  Process {
    id: catalogProcess
    command: []
    stdout: StdioCollector { id: catalogOutput; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) root.applyCatalog(catalogOutput.text)
      else if (root.allStations.length === 0) root.errorText = "Could not refresh the station directory"
    }
  }

  Process {
    id: probeProcess
    command: []
    stdout: StdioCollector { id: probeOutput; waitForEnd: true }
    onExited: {
      root.applyProbe(root.probingUrl, probeOutput.text)
      root.probingUrl = ""
      root.startNextProbe()
    }
  }

  Process {
    id: playProcess
    property string stationUrl: ""
    command: []
    stdout: StdioCollector { id: playOutput; waitForEnd: true }
    stderr: StdioCollector { id: playError; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.playingUrl = stationUrl
        root.queueVisibleProbes()
      } else root.errorText = StationModel.singleLine(playError.text, 200) || "Could not start this station"
    }
  }

  Process {
    id: settingProcess
    property string pendingUrl: ""
    command: []
    stdout: StdioCollector { id: settingOutput; waitForEnd: true }
    stderr: StdioCollector { id: settingError; waitForEnd: true }
    onExited: function(exitCode) {
      root.savingConfigured = false
      if (exitCode === 0) root.applyConfigured(pendingUrl)
      else root.configuredError = StationModel.singleLine(settingError.text, 200) || "Could not save station setting"
    }
  }

  Timer {
    id: probeTimer
    interval: 30000
    repeat: true
    running: root.opened
    onTriggered: root.queueVisibleProbes()
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-subwave"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; color: root.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      anchors.centerIn: parent
      radius: Style.cornerRadius
      color: root.background
      borderSpec: Border.surfaceSpec("menu", "border", root.border, Math.max(1, Style.space(2)))

      MouseArea { anchors.fill: parent; onClicked: {} }

      Column {
        anchors.fill: parent
        anchors.margins: Style.spacing.panelPadding
        spacing: Style.spacing.md

        Row {
          width: parent.width
          spacing: Style.spacing.md

          Text {
            text: "SUB/WAVE"
            color: root.foreground
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Text {
            width: parent.width - x
            text: visibleStations.count + " stations"
            color: root.foreground
            opacity: 0.58
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignRight
          }
        }
        Row {
          width: parent.width
          spacing: Style.spacing.sm

          TextField {
            id: searchField
            width: parent.width - configuredButton.width - parent.spacing
            placeholderText: "Search stations, places, genres…"
            foreground: root.foreground
            accent: root.accent
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.body
            onTextChanged: root.setFilter(text)
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Down) { root.moveSelection(1); event.accepted = true }
              else if (event.key === Qt.Key_Up) { root.moveSelection(-1); event.accepted = true }
              else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.playSelected(); event.accepted = true }
              else if (event.key === Qt.Key_Escape) {
                if (text) text = ""
                else root.dismiss()
                event.accepted = true
              }
            }
          }

          Button {
            id: configuredButton
            text: root.configuredUrl ? "EDIT" : "+ SELF-HOSTED"
            active: root.configuredUrl !== ""
            focusable: true
            bordered: true
            foreground: root.foreground
            accent: root.accent
            fontFamily: Style.font.menuFamily
            fontSize: Style.font.caption
            onClicked: root.editingConfigured ? root.cancelConfiguredEdit() : root.beginConfiguredEdit()
          }
        }

        BorderSurface {
          visible: root.editingConfigured
          width: parent.width
          implicitHeight: configuredEditor.implicitHeight + Style.spacing.md * 2
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.035)
          radius: Style.cornerRadius
          borderSpec: Border.flat(Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.10), 1)

          Column {
            id: configuredEditor
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.spacing.md
            anchors.rightMargin: Style.spacing.md
            spacing: Style.spacing.sm

            Text {
              width: parent.width
              text: "SELF-HOSTED STATION"
              color: root.foreground
              opacity: 0.62
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Row {
              width: parent.width
              spacing: Style.spacing.sm

              TextField {
                id: configuredField
                width: parent.width - saveConfiguredButton.width - cancelConfiguredButton.width
                  - (removeConfiguredButton.visible ? removeConfiguredButton.width + parent.spacing : 0)
                  - parent.spacing * 2
                enabled: !root.savingConfigured
                text: root.configuredInput
                placeholderText: "https://radio.example.com"
                foreground: root.foreground
                accent: root.accent
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.body
                onTextChanged: root.configuredInput = text
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    root.saveConfigured(text)
                    event.accepted = true
                  } else if (event.key === Qt.Key_Escape) {
                    root.cancelConfiguredEdit()
                    event.accepted = true
                  }
                }
              }

              Button {
                id: saveConfiguredButton
                text: root.savingConfigured ? "SAVING" : "SAVE"
                enabled: !root.savingConfigured
                focusable: true
                bordered: true
                foreground: root.foreground
                accent: root.accent
                fontFamily: Style.font.menuFamily
                fontSize: Style.font.caption
                onClicked: root.saveConfigured(configuredField.text)
              }

              Button {
                id: removeConfiguredButton
                visible: root.configuredUrl !== ""
                text: "REMOVE"
                enabled: !root.savingConfigured
                focusable: true
                foreground: Color.urgent
                accent: Color.urgent
                fontFamily: Style.font.menuFamily
                fontSize: Style.font.caption
                onClicked: root.saveConfigured("")
              }

              Button {
                id: cancelConfiguredButton
                text: "CANCEL"
                enabled: !root.savingConfigured
                focusable: true
                foreground: root.foreground
                accent: root.accent
                fontFamily: Style.font.menuFamily
                fontSize: Style.font.caption
                onClicked: root.cancelConfiguredEdit()
              }
            }

            Text {
              visible: root.configuredError !== ""
              width: parent.width
              text: root.configuredError
              color: Color.urgent
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
            }
          }
        }

        Text {
          visible: root.errorText !== ""
          width: parent.width
          text: root.errorText
          color: Color.urgent
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }

        ListView {
          id: stationList
          width: parent.width
          height: parent.height - y
          clip: true
          spacing: Style.spacing.xs
          model: visibleStations
          currentIndex: root.selectedIndex

          delegate: BorderSurface {
            required property int index
            required property string name
            required property string url
            required property string location
            required property string country
            required property string genre
            required property bool featured
            required property bool isConfigured
            readonly property var live: root.liveFor(url)
            width: ListView.view.width
            height: Style.space(68)
            radius: Style.spacing.labelGap
            color: index === root.selectedIndex
              ? Color.menu.selectedBackground
              : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.025)
            borderSpec: index === root.selectedIndex
              ? Border.surfaceSpec("menu", "selected-border", Color.menu.selectedBorder, 1)
              : Border.flat(Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08), 1)

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: root.selectedIndex = index
              onClicked: { root.selectedIndex = index; root.playSelected() }
            }

            Column {
              anchors.left: parent.left
              anchors.right: status.left
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(14)
              anchors.rightMargin: Style.space(12)
              spacing: Style.space(4)

              Text {
                width: parent.width
                text: name + (isConfigured ? "  ·  MY STATION" : (featured ? "  ·  FEATURED" : ""))
                color: root.foreground
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.body
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                text: live && live.title
                  ? live.title + (live.artist ? " · " + live.artist : "")
                  : [location || country, genre].filter(function(value) { return value }).join(" · ")
                color: root.foreground
                opacity: 0.62
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            Text {
              id: status
              anchors.right: webPlayerButton.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              text: root.playingUrl === url ? "PLAYING" : (!live ? "CHECKING" : (live.online ? "ON AIR" : "OFFLINE"))
              color: live && live.online ? root.accent : root.foreground
              opacity: live && live.online ? 1 : 0.5
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Button {
              id: webPlayerButton
              z: 1
              anchors.right: parent.right
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: "↗"
              tooltipText: "Open web player"
              focusable: true
              foreground: root.foreground
              accent: root.accent
              fontFamily: Style.font.menuFamily
              fontSize: Style.font.body
              horizontalPadding: Style.spacing.controlGap
              verticalPadding: Style.spacing.labelGap
              onClicked: root.openWebPlayer(url)
            }
          }

          Text {
            anchors.centerIn: parent
            visible: visibleStations.count === 0
            text: root.filterText ? "No matching stations" : "No stations available"
            color: root.foreground
            opacity: 0.58
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.body
          }
        }
      }
    }
  }
}
