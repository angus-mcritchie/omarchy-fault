import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "angus.fault"
  ipcTarget: "angus.fault"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgentColor: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color dimmer: Qt.darker(foreground, 2.1)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string monoFamily: "monospace"

  // Held open on a healthy machine so the panel can still be summoned. Without
  // it the icon is both the alert and the only way in, and a machine with
  // nothing wrong has no way to show what this plugin does.
  property bool forceShown: false

  property double nowMs: Date.now()
  property string previewKey: ""

  readonly property bool alerting: !!fault && fault.alerting

  // Bar.qml collapses a slot whose item is invisible, so a healthy machine
  // draws nothing at all rather than a widget reading zero.
  visible: alerting || forceShown
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (opened) {
      nowMs = Date.now()
      previewKey = ""
      if (fault) fault.loadDetails()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    } else if (!alerting) {
      forceShown = false
    }
  }

  function summon() {
    forceShown = true
    Qt.callLater(function() { root.open() })
  }

  function refreshNow() {
    if (!fault) return
    fault.refresh()
    if (opened) fault.loadDetails()
  }

  function ago(stamp) {
    if (!stamp) return ""
    var secs = Math.max(0, Math.floor(nowMs / 1000 - stamp))
    if (secs < 60) return secs + "s ago"
    if (secs < 3600) return Math.floor(secs / 60) + "m ago"
    if (secs < 86400) return Math.floor(secs / 3600) + "h ago"
    return Math.floor(secs / 86400) + "d ago"
  }

  function headline() {
    if (!fault) return "Starting"
    var bits = []
    if (fault.failedCount > 0) bits.push(fault.failedCount + (fault.failedCount === 1 ? " unit failed" : " units failed"))
    if (fault.restartingCount > 0) bits.push(fault.restartingCount + " restarting")
    if (bits.length > 0) return bits.join(", ")
    if (fault.anyUnknown) return "A manager could not be read"
    if (fault.anyDegraded) return "Degraded"
    return "All units healthy"
  }

  function subhead() {
    if (!fault) return ""
    var parts = []
    if (fault.watchSystem) parts.push("system: " + fault.stateLabel(fault.systemState))
    if (fault.watchUser) parts.push("user: " + fault.stateLabel(fault.userState))
    return parts.join("   ")
  }

  function diagnosticsFor(u) {
    if (!fault) return ""
    var d = fault.details[fault.unitKey(u)]
    var out = []
    out.push("unit:     " + u.unit)
    out.push("manager:  " + u.manager)
    if (u.description) out.push("descr:    " + u.description)
    out.push("state:    " + u.active + " (" + u.sub + ")")
    if (d) {
      var r = fault.reported(d)
      if (r) out.push("reported: " + r)
      if (d.restarts) out.push("restarts: " + d.restarts)
      if (d.since) out.push("since:    " + ago(d.since))
      if (d.journal && d.journal.length) {
        out.push("")
        out.push("journal (last " + d.journal.length + "):")
        for (var i = 0; i < d.journal.length; i++) out.push("  " + d.journal[i])
      }
    }
    return out.join("\n")
  }

  function copyText(text) {
    copyProc.stdinEnabled = true
    copyProc.running = false
    copyProc.running = true
    copyProc.write(text)
    copyProc.stdinEnabled = false
  }

  function openLog(u) {
    if (!root.bar) return
    var flag = u.manager === "user" ? "--user -u" : "-u"
    root.bar.run("omarchy-launch-floating-terminal-with-presentation journalctl " + flag + " " + u.unit + " -e")
    root.close()
  }

  // One shared poller, instantiated once by the shell. The bar builds a widget
  // per screen; without this each screen polled systemd independently.
  readonly property var service: bar && bar.shell ? bar.shell.serviceFor("angus.fault") : null
  readonly property var fault: service ? service.model : null

  onServiceChanged: if (service) service.applySettings({
    intervalSec: root.setting("intervalSec", 10),
    journalLines: root.setting("journalLines", 20),
    watchSystem: root.setting("watchSystem", true),
    watchUser: root.setting("watchUser", true)
  })

  Timer {
    interval: 15000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  Process {
    id: copyProc
    command: ["wl-copy"]
    running: false
  }

  // Deliberately no open/close/toggle here. A per-target IPC handler only ever
  // reaches whichever per-monitor instance claimed the target, so on a
  // multi-monitor machine it opened the panel on the wrong screen. The shell's
  // own router picks the focused output:
  //
  //   omarchy-shell shell toggle angus.fault
  //
  IpcHandler {
    target: root.ipcTarget
    function refresh(): string { root.refreshNow(); return "ok" }
    function status(): string {
      if (!fault) return "starting"
      return fault.failedCount + " failed, " + fault.restartingCount + " restarting; " +
             "system=" + fault.systemState + " user=" + fault.userState
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰀦"
    active: !!fault && fault.urgent
    opacity: fault.urgent ? 1.0 : 0.55
    onPressed: function(code) {
      if (code === Qt.MiddleButton) root.refreshNow()
      else root.toggle()
    }

    SequentialAnimation on opacity {
      running: !!fault && fault.restartingCount > 0
      loops: Animation.Infinite
      alwaysRunToEnd: true
      NumberAnimation { to: 0.35; duration: 620; easing.type: Easing.InOutQuad }
      NumberAnimation { to: 1.0; duration: 620; easing.type: Easing.InOutQuad }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(430))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dy !== 0)
          flick.contentY = Math.max(0, Math.min(flick.contentY + dy * Style.space(56),
                                    Math.max(0, flick.contentHeight - flick.height)))
      }
      onActivateRequested: root.refreshNow()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { if (t === "r" || t === "R") root.refreshNow() }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: flick.width
          spacing: Style.space(10)

          PanelHero {
            width: column.width
            foreground: root.foreground
            fontFamily: root.fontFamily
            title: root.headline()
            meta: root.subhead()
            detail: fault && fault.detailsLoading ? "reading units..." : ""
          }

          // ---------------------------------------------------- all clear
          Column {
            width: column.width
            spacing: Style.space(6)
            visible: !fault || fault.units.length === 0

            PanelSeparator { width: column.width; foreground: root.foreground }

            Text {
              width: column.width
              wrapMode: Text.WordWrap
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              color: root.dim
              text: fault.anyUnknown
                ? "One of the managers did not answer. That is not the same as healthy, which is why this still draws an icon."
                : fault.anyDegraded
                  ? "A manager reports degraded with no unit currently failed. Something failed earlier and was cleared without being fixed."
                  : "Both managers answered and nothing is failed or restarting."
            }

            Text {
              width: column.width
              wrapMode: Text.WordWrap
              font.family: root.monoFamily
              font.pixelSize: Style.font.caption
              color: root.dimmer
              text: "watching " + ((fault.watchSystem ? 1 : 0) + (fault.watchUser ? 1 : 0)) +
                    " manager(s) every " + fault.intervalSec + "s"
            }
          }

          // -------------------------------------------------------- units
          Repeater {
            model: fault ? fault.units : []

            delegate: Column {
              id: card
              required property var modelData
              readonly property var detail: fault.details ? fault.details[fault.unitKey(modelData)] : null
              readonly property bool isPreviewing: root.previewKey === fault.unitKey(modelData)

              width: column.width
              spacing: Style.space(4)

              PanelSeparator { width: column.width; foreground: root.foreground }

              Row {
                width: column.width
                spacing: Style.space(6)

                Rectangle {
                  width: Style.space(3)
                  height: unitName.implicitHeight
                  radius: 1
                  color: card.modelData.kind === "failed" ? root.urgentColor : root.foreground
                  opacity: card.modelData.kind === "failed" ? 1.0 : 0.5
                }

                Text {
                  id: unitName
                  width: Math.max(0, column.width - Style.space(14) - managerTag.implicitWidth)
                  elide: Text.ElideRight
                  font.family: root.monoFamily
                  font.pixelSize: Style.font.body
                  color: root.foreground
                  text: card.modelData.unit
                }

                Text {
                  id: managerTag
                  anchors.baseline: unitName.baseline
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: root.dimmer
                  text: card.modelData.manager
                }
              }

              Text {
                width: column.width
                visible: text !== ""
                wrapMode: Text.WordWrap
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.dim
                text: card.modelData.description
              }

              // What systemd reported. Not a cause.
              Text {
                width: column.width
                visible: text !== ""
                wrapMode: Text.WordWrap
                font.family: root.monoFamily
                font.pixelSize: Style.font.caption
                color: card.modelData.kind === "failed" ? root.urgentColor : root.dim
                text: {
                  var bits = []
                  if (card.modelData.kind === "restarting") bits.push("restarting")
                  var r = fault.reported(card.detail)
                  if (r) bits.push(r)
                  if (card.detail && card.detail.restarts > 0) bits.push(card.detail.restarts + " restarts")
                  if (card.detail && card.detail.since) bits.push(root.ago(card.detail.since))
                  return bits.join("  ·  ")
                }
              }

              Text {
                width: column.width
                visible: text !== ""
                wrapMode: Text.WordWrap
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.dimmer
                text: fault.convention(card.detail)
              }

              // The journal is the evidence; the number above is only a label.
              Rectangle {
                width: column.width
                visible: !!card.detail && card.detail.journal.length > 0
                height: journalText.implicitHeight + Style.space(10)
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
                radius: Style.space(2)

                Text {
                  id: journalText
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(6)
                  anchors.rightMargin: Style.space(6)
                  wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                  font.family: root.monoFamily
                  font.pixelSize: Style.font.caption
                  color: root.dim
                  text: card.detail ? card.detail.journal.slice(-6).join("\n") : ""
                }
              }

              Text {
                width: column.width
                visible: !!card.detail && !card.detail.readable
                wrapMode: Text.WordWrap
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.dimmer
                text: "No journal returned. Reading the system journal needs membership of the wheel or systemd-journal group."
              }

              Row {
                spacing: Style.space(10)
                topPadding: Style.space(2)

                Text {
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: card.isPreviewing ? root.foreground : root.dim
                  text: card.isPreviewing ? "Hide diagnostics" : "Copy diagnostics"
                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.previewKey = card.isPreviewing ? "" : fault.unitKey(card.modelData)
                  }
                }

                Text {
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: root.dim
                  text: "Full log"
                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.openLog(card.modelData)
                  }
                }
              }

              // Review before copying. Service logs routinely carry tokens,
              // URLs, customer identifiers and request data, and a payload
              // pre-formatted for an issue tracker is what invites someone to
              // paste one into a public one.
              Column {
                width: column.width
                visible: card.isPreviewing
                spacing: Style.space(4)
                topPadding: Style.space(4)

                Text {
                  width: column.width
                  wrapMode: Text.WordWrap
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: root.urgentColor
                  text: "Read this before copying. Service logs routinely contain tokens, URLs, customer identifiers and request data."
                }

                Rectangle {
                  width: column.width
                  height: Math.min(previewText.implicitHeight + Style.space(10), Style.space(180))
                  color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.07)
                  radius: Style.space(2)
                  clip: true

                  Flickable {
                    anchors.fill: parent
                    anchors.margins: Style.space(5)
                    contentWidth: width
                    contentHeight: previewText.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    Text {
                      id: previewText
                      width: parent.width
                      wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                      font.family: root.monoFamily
                      font.pixelSize: Style.font.caption
                      color: root.dim
                      text: root.diagnosticsFor(card.modelData)
                    }
                  }
                }

                Text {
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: root.foreground
                  text: "Copy to clipboard"
                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      root.copyText(root.diagnosticsFor(card.modelData))
                      root.previewKey = ""
                    }
                  }
                }
              }
            }
          }

          Item { width: 1; height: Style.space(4) }
        }
      }
    }
  }
}
