import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons

// Blip as an Omarchy app: the same view as the bar panel, laid out wide in a
// themed window. It stands in for Blip's own window when Blip is opened from
// the app search or the bar; Blip's window stays one button away for its
// settings and account, though the plugin's own settings page covers them.
Scope {
  id: root

  required property var blip
  property bool shown: false
  property bool settingsShown: false

  function show() {
    root.shown = true
    blip.refresh()
    blip.markSeen()
    if (blip.needsSetup) setup.focusInitial()
    else view.focusInitial()
  }

  function showSettings() {
    root.settingsShown = true
    root.show()
    settings.forceActiveFocus()
  }

  function hide() {
    root.shown = false
    root.settingsShown = false
    view.reset()
  }

  function toggle() {
    if (root.shown) root.hide()
    else root.show()
  }

  function takeDrop(paths) {
    root.settingsShown = false
    root.show()
    view.takeDrop(paths)
  }

  FloatingWindow {
    id: window
    title: "Blip"
    visible: root.shown
    color: Commons.Color.background
    implicitWidth: 960
    implicitHeight: 640
    minimumSize: Qt.size(640, 440)

    // Closed from the title bar or by the compositor.
    onVisibleChanged: if (!visible && root.shown) root.hide()

    SetupView {
      id: setup
      visible: root.blip.needsSetup
      anchors.fill: parent
      anchors.margins: Style.space(20)
      blip: root.blip
      onCloseRequested: root.hide()
    }

    BlipView {
      id: view
      visible: !root.settingsShown && !root.blip.needsSetup
      anchors.fill: parent
      anchors.margins: Style.space(20)
      blip: root.blip
      wide: window.width >= 760
      closeAfterSend: false
      heroActionIcon: "󰒓"
      heroActionTip: "Settings (w)"
      onHeroActionClicked: root.showSettings()
      onCloseRequested: root.hide()
    }

    SettingsView {
      id: settings
      visible: root.settingsShown && !root.blip.needsSetup
      anchors.fill: parent
      anchors.margins: Style.space(20)
      blip: root.blip
      wide: window.width >= 760
      onBackRequested: {
        root.settingsShown = false
        view.focusInitial()
      }
      onCloseRequested: root.hide()
    }
  }
}
