import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Infinitus fleet widget for the Omarchy (Quickshell) bar — the same
// infinitus-tray binary the Waybar module uses, one JSON status line
// per refresh. The engine stays behind `cswap … --json`; the widget
// never reads engine internals.
BarWidget {
  id: root
  moduleName: "infinitus.fleet"

  property string statusText: ""
  property string statusTooltip: ""
  property string stateClass: ""

  readonly property string themeId: String(setting("theme", "rpg"))
  readonly property int refreshMs: Math.max(15, Number(setting("refreshIntervalSec", 60))) * 1000
  readonly property string trayBin: Quickshell.env("HOME") + "/.local/bin/infinitus-tray"

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  // The tray pango-escapes for Waybar; undo it for plain Text.
  function unpango(s) {
    return String(s || "")
      .replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&")
  }

  function apply(out) {
    try {
      var d = JSON.parse(out)
      statusText = unpango(d.text)
      statusTooltip = unpango(d.tooltip)
      stateClass = String(d["class"] || "")
    } catch (e) {
      statusText = "⇄ engine error"
      statusTooltip = String(out).slice(0, 400)
      stateClass = "error"
    }
  }

  Process {
    id: statusProc
    command: [root.trayBin, "status", "--theme", root.themeId]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.apply(text)
    }
  }

  Process {
    id: rotateProc
    command: [root.trayBin, "rotate"]
    onExited: root.refresh()
  }

  // Right-click cycles the theme through the real settings mechanism —
  // `omarchy bar set` writes shell.json, the shell hot-applies it, and
  // themeId's change triggers the re-render. Quattro 4.0.1 has no
  // widget-settings GUI; the CLI is the supported editor.
  property var themeIds: []

  Process {
    id: themesProc
    command: [root.trayBin, "themes"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var ids = []
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
          var id = lines[i].split("\t")[0].trim()
          if (id) ids.push(id)
        }
        root.themeIds = ids
      }
    }
  }

  Process {
    id: themeSetProc
    property string nextTheme: ""
    command: ["omarchy", "bar", "set", "infinitus.fleet", "theme", nextTheme]
  }

  function cycleTheme() {
    if (themeIds.length === 0 || themeSetProc.running) return
    var i = themeIds.indexOf(themeId)
    themeSetProc.nextTheme = themeIds[(i + 1) % themeIds.length]
    themeSetProc.running = true
  }

  onThemeIdChanged: refresh()

  Component.onCompleted: themesProc.running = true

  Timer {
    interval: root.refreshMs
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  visible: statusText !== ""
  implicitWidth: visible ? label.implicitWidth + Style.spacing.controlPaddingX * 2 : 0
  implicitHeight: barSize

  Text {
    id: label
    anchors.centerIn: parent
    text: root.statusText
    color: root.stateClass === "dead" || root.stateClass === "error"
             ? (root.bar ? root.bar.urgent : Color.urgent)
             : (root.bar ? root.bar.barForeground : Color.foreground)
    opacity: root.stateClass === "warning" ? 0.7 : 1
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: Style.font.body
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
    onClicked: function(mouse) {
      if (mouse.button === Qt.RightButton) root.cycleTheme()
      else if (mouse.button === Qt.MiddleButton) root.refresh()
      else if (!rotateProc.running) rotateProc.running = true
    }
    onEntered: if (root.bar) root.bar.showTooltip(root, root.statusTooltip)
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }
}
