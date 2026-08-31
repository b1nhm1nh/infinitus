import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The Infinitus fleet popup — the Omarchy counterpart of the macOS
// menu-bar app's popup. Per-account rows with usage gauges, themed by
// the same RowTheme vocabulary; click a row to switch to that account,
// rotate and theme cycling live in the footer.
//
// Data comes from `infinitus-tray panel --theme <id>` (structured JSON,
// themed strings rendered Swift-side); the engine stays behind
// `cswap … --json` subprocesses. BarWidget.qml owns the bar label and
// hands this panel the widget to anchor against.
Panel {
  id: root
  moduleName: "infinitus.fleet"
  ipcTarget: "infinitus.fleet"
  manageIpc: false

  property var anchorItem: null

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not
  // this nested panel (popout coordinator + open-panel dot identity).
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property string themeId: String(setting("theme", "rpg"))
  readonly property string trayBin: Quickshell.env("HOME") + "/.local/bin/infinitus-tray"

  property var fleet: null
  readonly property var accounts: fleet && fleet.accounts ? fleet.accounts : []
  readonly property var themeList: fleet && fleet.themes ? fleet.themes : []
  readonly property string themeName: {
    for (var i = 0; i < themeList.length; i++)
      if (themeList[i].id === themeId) return themeList[i].name.split(" — ")[0]
    return themeId
  }

  // Guarded so the widget renders before the bar is injected.
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color mutedForeground: Qt.darker(contentForeground, 1.5)

  function gaugeColor(pct) {
    return pct >= 85 ? Color.urgent
                     : Style.selectedStateColor(contentForeground, Color.accent)
  }

  function open() {
    refresh()
    root.controller.show()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function refresh() {
    if (!panelProc.running) panelProc.running = true
  }

  // Bar label + panel together, after a switch/rotate.
  function refreshAll() {
    refresh()
    if (root.hostWidget && typeof root.hostWidget.refresh === "function")
      root.hostWidget.refresh()
  }

  function rotate() {
    if (!rotateProc.running) rotateProc.running = true
  }

  function switchTo(number) {
    if (switchProc.running) return
    switchProc.accountNumber = number
    switchProc.running = true
  }

  // The theme is a stored setting, same mechanism as the clock's format:
  // applied locally first so the panel redraws on the click itself, then
  // written back through shell.json.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]

    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function cycleTheme(delta) {
    if (themeList.length === 0) return
    var i = 0
    for (var k = 0; k < themeList.length; k++)
      if (themeList[k].id === themeId) { i = k; break }
    var next = themeList[(i + delta + themeList.length) % themeList.length].id
    persistSettings({ theme: next })
  }

  onThemeIdChanged: if (opened) refresh()

  Process {
    id: panelProc
    command: [root.trayBin, "panel", "--theme", root.themeId]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.fleet = JSON.parse(text) } catch (e) {
          console.log("infinitus panel: bad payload (" + e + "): " + String(text).slice(0, 120))
          root.fleet = null
        }
      }
    }
  }

  Process {
    id: rotateProc
    command: [root.trayBin, "rotate"]
    onExited: root.refreshAll()
  }

  Process {
    id: switchProc
    property int accountNumber: 0
    command: [root.trayBin, "switch", String(accountNumber)]
    onExited: root.refreshAll()
  }

  // Usage moves while the panel sits open.
  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(fleetColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onActivateRequested: root.rotate()
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.rotate()
        else if (t === "[") root.cycleTheme(-1)
        else if (t === "]") root.cycleTheme(1)
        else if (t >= "1" && t <= "9") root.switchTo(Number(t))
      }

      Flickable {
        id: fleetScroll
        anchors.fill: parent
        contentWidth: fleetColumn.width
        contentHeight: fleetColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: fleetColumn
          width: fleetScroll.width
          spacing: Style.space(8)

          // ---- Hero: the active account's bar line, sessions under it.
          Column {
            width: parent.width
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: root.fleet ? String(root.fleet.title || "") : "…"
              elide: Text.ElideRight
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.pixelSize ? Style.font.pixelSize : 24
              font.bold: true
            }

            Text {
              textFormat: Text.PlainText
              visible: text !== ""
              width: parent.width
              text: root.fleet && root.fleet.sessionsLine ? root.fleet.sessionsLine : ""
              elide: Text.ElideRight
              color: root.mutedForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.contentForeground
          }

          // ---- Fleet rows. Click a non-active, non-disabled row to
          //      switch to that account (the macOS popup's row action).
          Repeater {
            model: root.accounts

            Rectangle {
              id: row
              required property var modelData
              readonly property bool clickable: !modelData.active && !modelData.disabled && !modelData.note

              width: fleetColumn.width
              height: rowContent.implicitHeight + Style.space(10)
              radius: Style.cornerRadius
              color: modelData.active
                ? Style.hoverFillFor(root.contentForeground, Color.accent)
                : (rowMouse.containsMouse && clickable
                   ? Style.hoverFillFor(root.contentForeground, Color.accent)
                   : "transparent")
              opacity: modelData.disabled ? 0.45 : 1

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                enabled: row.clickable
                cursorShape: row.clickable ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: root.switchTo(row.modelData.number)

                PanelToolTip {
                  visible: rowMouse.containsMouse && row.clickable
                  text: "Switch to " + row.modelData.name
                  fontFamily: root.contentFontFamily
                }
              }

              Column {
                id: rowContent
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(8)
                spacing: Style.space(3)

                // Header: marker, slot, name, plan.
                Item {
                  width: parent.width
                  height: nameText.implicitHeight

                  Text {
                    id: markerText
                    textFormat: Text.PlainText
                    anchors.left: parent.left
                    text: row.modelData.marker
                    color: row.modelData.active ? Color.accent : root.mutedForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                  }

                  Text {
                    id: nameText
                    textFormat: Text.PlainText
                    anchors.left: markerText.right
                    anchors.leftMargin: Style.space(8)
                    text: row.modelData.number + " " + row.modelData.name
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                    font.bold: row.modelData.active
                  }

                  Text {
                    textFormat: Text.PlainText
                    anchors.left: nameText.right
                    anchors.leftMargin: Style.space(10)
                    anchors.baseline: nameText.baseline
                    text: row.modelData.plan || ""
                    color: root.mutedForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    textFormat: Text.PlainText
                    anchors.right: parent.right
                    anchors.baseline: nameText.baseline
                    text: row.modelData.disabled ? "disabled"
                        : row.modelData.active ? "active"
                        : rowMouse.containsMouse && row.clickable ? "switch" : ""
                    color: rowMouse.containsMouse && row.clickable
                      ? Style.hoverStateColor(root.contentForeground, Color.accent)
                      : root.mutedForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                // Sentinel note (re-login etc.) or the themed death line.
                Text {
                  textFormat: Text.PlainText
                  visible: text !== ""
                  width: parent.width
                  text: row.modelData.note || row.modelData.deadLine || ""
                  elide: Text.ElideRight
                  color: row.modelData.deadLine ? Color.urgent : root.mutedForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                // Usage gauges, one per window: label · track · pct · reset.
                Repeater {
                  model: row.modelData.windows

                  Item {
                    id: windowRow
                    required property var modelData
                    width: rowContent.width
                    height: Style.space(16)
                    opacity: row.modelData.deadLine ? 0.55 : 1

                    Text {
                      id: windowLabel
                      textFormat: Text.PlainText
                      anchors.left: parent.left
                      anchors.verticalCenter: parent.verticalCenter
                      width: Style.space(92)
                      elide: Text.ElideRight
                      text: windowRow.modelData.label
                      color: root.mutedForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                    }

                    Text {
                      id: windowReset
                      textFormat: Text.PlainText
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      width: Style.space(96)
                      horizontalAlignment: Text.AlignRight
                      elide: Text.ElideRight
                      text: windowRow.modelData.reset || ""
                      color: root.mutedForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                    }

                    Text {
                      id: windowPct
                      textFormat: Text.PlainText
                      anchors.right: windowReset.left
                      anchors.rightMargin: Style.space(8)
                      anchors.verticalCenter: parent.verticalCenter
                      width: Style.space(42)
                      horizontalAlignment: Text.AlignRight
                      text: windowRow.modelData.pct + "%"
                      color: root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                    }

                    Rectangle {
                      anchors.left: windowLabel.right
                      anchors.right: windowPct.left
                      anchors.leftMargin: Style.space(10)
                      anchors.rightMargin: Style.space(10)
                      anchors.verticalCenter: parent.verticalCenter
                      height: Style.space(6)
                      radius: Style.cornerRadius > 0 ? height / 2 : 0
                      color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)

                      Rectangle {
                        width: Math.round(parent.width * Math.min(100, windowRow.modelData.pct) / 100)
                        height: parent.height
                        radius: parent.radius
                        color: root.gaugeColor(windowRow.modelData.pct)

                        Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                      }
                    }
                  }
                }
              }
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.contentForeground
          }

          // ---- Footer: rotate on the left, theme stepper on the right.
          Item {
            width: parent.width
            height: Math.max(rotateButton.height, themeNav.height)

            PanelActionButton {
              id: rotateButton
              anchors.left: parent.left
              anchors.leftMargin: -Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰑖"
              tooltipText: "Rotate to the next account"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              onClicked: root.rotate()
            }

            Row {
              id: themeNav
              anchors.right: parent.right
              anchors.rightMargin: -Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              PanelActionButton {
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰅁"
                tooltipText: "Previous theme"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.cycleTheme(-1)
              }

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(110)
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                text: root.themeName.toUpperCase()
                color: root.mutedForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }

              PanelActionButton {
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰅂"
                tooltipText: "Next theme"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.cycleTheme(1)
              }
            }
          }
        }
      }
    }
  }
}
