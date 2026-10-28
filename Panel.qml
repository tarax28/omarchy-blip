import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Blip in the bar: drop files on the mark (or on a device row in the panel)
// to send them, follow transfers, and see what has come in. Right-click opens
// the same view as a full Omarchy window in place of Blip's own.
Panel {
  id: root
  moduleName: "tarax.blip"
  ipcTarget: "tarax.blip"
  manageIpc: false

  property bool dragOver: false

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color accent: Commons.Color.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color barIconColor: dragOver
    ? accent
    : (service.running ? barForeground : Qt.darker(barForeground, 1.55))
  // Progress across every transfer that is moving bytes, for the bar mark.
  readonly property real overallFraction: {
    var done = 0, total = 0
    for (var i = 0; i < service.transfers.length; i++) {
      var t = service.transfers[i]
      if (t.status !== "Active" || !(t.total > 0)) continue
      done += Number(t.done || 0)
      total += Number(t.total)
    }
    return total > 0 ? done / total : -1
  }

  function tooltip() {
    var lines = ["Blip"]
    for (var i = 0; i < service.transfers.length; i++) {
      var t = service.transfers[i]
      var pct = t.total > 0 && t.status === "Active" ? " · " + Math.round(Model.transferFraction(t) * 100) + "%" : ""
      lines.push((t.outgoing ? "↑ " : "↓ ") + Model.transferTitle(t) + pct)
    }
    if (service.unseenCount > 0) lines.push(service.unseenCount + (service.unseenCount === 1 ? " new file" : " new files"))
    lines.push("Drop files here to send")
    lines.push("Left: open · Right: Blip window · Middle: downloads")
    return lines.join("\n")
  }

  function takeDrop(paths) {
    if (!paths || paths.length === 0) return
    // A drop on the mark goes to the window when it is already open.
    if (appWindow.shown) {
      appWindow.takeDrop(paths)
      return
    }
    if (!root.opened) root.open()
    view.takeDrop(paths)
  }

  function openApp() {
    root.close()
    appWindow.show()
  }

  function deviceNamed(name) {
    var wanted = String(name || "").toLowerCase()
    for (var i = 0; i < service.devices.length; i++) {
      if (String(service.devices[i].name).toLowerCase() === wanted) return service.devices[i]
    }
    return null
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (opened) {
      service.refresh()
      service.markSeen()
      if (service.needsSetup) setup.focusInitial()
      else view.focusInitial()
    } else {
      root.dragOver = false
      view.reset()
    }
  }

  Service {
    id: service
    settings: root.settings
    bar: root.bar
    onAppRequested: appWindow.show()
  }

  BlipWindow {
    id: appWindow
    blip: service
  }

  // omarchy-shell tarax.blip send Phone /path/a.pdf  ·  omarchy-shell tarax.blip drop /path/a.pdf
  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function app(): void { root.openApp() }
    function window(): void { root.close(); appWindow.toggle() }
    function settings(): void { root.close(); appWindow.showSettings() }
    function blip(): void { service.showRealApp() }
    function refresh(): string { service.refresh(); return "ok" }
    function drop(paths: string): void { root.takeDrop(paths.split("\n").filter(function(p) { return p !== "" })) }
    function send(device: string, paths: string): string {
      var target = root.deviceNamed(device)
      if (!target) return "unknown device: " + device
      service.send(target, paths.split("\n").filter(function(p) { return p !== "" }))
      return "ok"
    }
    function search(text: string): void {
      if (!root.opened) root.open()
      view.query = text
      view.setCursor("devices", 0)
    }
    function devices(): string { return service.devices.map(function(d) { return d.name }).join("\n") }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    active: root.opened || appWindow.shown
    tooltipText: root.tooltip()
    iconComponent: Component {
      Item {
        BlipIcon {
          anchors.centerIn: parent
          iconSize: Style.space(12)
          color: root.barIconColor
          Behavior on color { ColorAnimation { duration: 120 } }
        }
        Rectangle {
          visible: service.unseenCount > 0
          width: Style.space(5)
          height: width
          radius: width / 2
          color: root.accent
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.rightMargin: Style.space(1)
          anchors.topMargin: Style.space(1)
        }
        // A thin progress line under the mark while something is transferring.
        Rectangle {
          visible: root.overallFraction >= 0
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.bottom: parent.bottom
          width: Style.space(14)
          height: Math.max(2, Style.space(2))
          radius: height / 2
          color: Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, 0.25)
          Rectangle {
            width: parent.width * Math.max(0, root.overallFraction)
            height: parent.height
            radius: parent.radius
            color: root.accent
            Behavior on width { NumberAnimation { duration: 250 } }
          }
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) { root.close(); appWindow.toggle() }
      else if (buttonCode === Qt.MiddleButton) service.openDownloads()
      else root.toggle()
    }

    DropArea {
      anchors.fill: parent
      keys: ["text/uri-list"]
      onEntered: root.dragOver = true
      onExited: root.dragOver = false
      onDropped: function(event) {
        root.dragOver = false
        var paths = Model.pathsFromUris(event.getDataAsString("text/uri-list"))
        if (paths.length === 0) return
        // Copy, never move: Blip reads the files where they are.
        event.accept(Qt.CopyAction)
        root.takeDrop(paths)
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: service.needsSetup ? setup : view.keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(service.needsSetup ? setup.contentImplicitHeight : view.contentImplicitHeight,
                                             Style.space(560))

    SetupView {
      id: setup
      visible: service.needsSetup
      anchors.fill: parent
      blip: service
      foreground: root.foreground
      urgent: root.urgent
      fontFamily: root.fontFamily
      onCloseRequested: root.close()
    }

    BlipView {
      id: view
      visible: !service.needsSetup
      anchors.fill: parent
      blip: service
      foreground: root.foreground
      urgent: root.urgent
      fontFamily: root.fontFamily
      heroActionIcon: "󰖲"
      heroActionTip: "Open the Blip window (w)"
      onHeroActionClicked: root.openApp()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
    }
  }
}
