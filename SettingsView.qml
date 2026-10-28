import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Blip's settings and the plugin's own, in the same style as the rest of the
// window. Blip's are applied through its core, the plugin's are saved to
// shell.json; Blip's own window stays one button away for anything else.
Item {
  id: view

  required property var blip
  property bool wide: false

  property color foreground: Commons.Color.foreground
  property color urgent: Commons.Color.urgent
  property color accent: Commons.Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  property string fontFamily: Style.font.family

  readonly property var account: blip.account || ({})
  property bool confirmLogout: false

  signal backRequested()
  signal closeRequested()

  Keys.onEscapePressed: view.backRequested()

  Timer {
    id: logoutTimer
    interval: 4000
    onTriggered: view.confirmLogout = false
  }

  Flickable {
    id: flick
    anchors.fill: parent
    contentWidth: width
    contentHeight: page.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    Column {
      id: page
      width: flick.width
      spacing: Style.space(16)

      PanelHero {
        id: hero
        width: parent.width
        title: "Settings"
        meta: view.account.email ? view.account.email : "Not signed in to Blip"
        foreground: view.foreground
        fontFamily: view.fontFamily
        iconComponent: Component {
          BlipIcon {
            iconSize: Style.font.display
            color: view.foreground
          }
        }
        trailingControl: Component {
          PanelActionButton {
            iconText: "󰁍"
            tooltipText: "Back (Esc)"
            foreground: hero.foreground
            fontFamily: hero.fontFamily
            onClicked: view.backRequested()
          }
        }
      }

      GridLayout {
        width: parent.width
        columns: view.wide ? 2 : 1
        columnSpacing: Style.space(28)
        rowSpacing: Style.space(16)

        // Blip itself: account, this device, receiving, speed.
        Column {
          Layout.fillWidth: true
          Layout.alignment: Qt.AlignTop
          Layout.preferredWidth: 1
          spacing: Style.space(10)

          PanelSectionHeader { text: "ACCOUNT"; foreground: view.foreground; fontFamily: view.fontFamily }

          SettingField {
            label: "Your name"
            value: view.account.name || ""
            placeholder: "Shown to people you send to"
            onCommitted: function(text) { if (text !== "") blip.setBlip("name", text) }
          }

          Toggle {
            width: parent.width
            label: "Findable by email"
            description: "Let people who know your email send you files."
            checked: !!view.account.searchable
            foreground: view.foreground
            accent: view.accent
            fontFamily: view.fontFamily
            onClicked: blip.setBlip("searchable", !view.account.searchable)
          }

          PanelSectionHeader { text: "THIS DEVICE"; foreground: view.foreground; fontFamily: view.fontFamily }

          SettingField {
            label: "Device name"
            value: view.account.deviceName || ""
            placeholder: "How your other devices see this one"
            onCommitted: function(text) { if (text !== "") blip.setBlip("deviceName", text) }
          }

          Repeater {
            model: (view.account.devices || []).filter(function(d) { return !d.current })
            delegate: RowLayout {
              required property var modelData
              width: parent.width
              spacing: Style.space(8)
              Text {
                text: Model.deviceGlyph(modelData)
                color: view.dim
                font.family: view.fontFamily
                font.pixelSize: Style.font.icon
                Layout.preferredWidth: Style.font.icon * 1.4
                horizontalAlignment: Text.AlignHCenter
              }
              Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                text: modelData.name + "  ·  " + Model.deviceMeta(modelData)
                color: view.dim
                font.family: view.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }
            }
          }

          PanelSectionHeader { text: "RECEIVING"; foreground: view.foreground; fontFamily: view.fontFamily }

          Toggle {
            width: parent.width
            label: "Accept from my devices automatically"
            description: "Files from your own devices arrive without asking."
            checked: view.account.autoAccept !== false
            foreground: view.foreground
            accent: view.accent
            fontFamily: view.fontFamily
            onClicked: blip.setBlip("autoAccept", view.account.autoAccept === false)
          }

          SettingField {
            label: "Save received files to"
            value: view.account.savePath || ""
            buttonIcon: "󰉋"
            buttonTip: "Choose a folder"
            onButtonClicked: blip.pickSaveFolder()
            onCommitted: function(text) { if (text !== "") blip.setBlip("savePath", text) }
          }

          PanelSectionHeader { text: "SPEED"; foreground: view.foreground; fontFamily: view.fontFamily }

          NumberField {
            label: "Upload limit, Mbps (0 = no limit)"
            value: Number(view.account.uploadLimit || 0)
            from: 0
            to: 10000
            stepSize: 5
            foreground: view.foreground
            accent: view.accent
            fontFamily: view.fontFamily
            onModified: function(value) { blip.setBlip("uploadLimit", value) }
          }

          NumberField {
            label: "Download limit, Mbps (0 = no limit)"
            value: Number(view.account.downloadLimit || 0)
            from: 0
            to: 10000
            stepSize: 5
            foreground: view.foreground
            accent: view.accent
            fontFamily: view.fontFamily
            onModified: function(value) { blip.setBlip("downloadLimit", value) }
          }

          Toggle {
            width: parent.width
            label: "Share connection diagnostics"
            description: "Help Blip fix slow or failed connections."
            checked: !!view.account.diagnostics
            foreground: view.foreground
            accent: view.accent
            fontFamily: view.fontFamily
            onClicked: blip.setBlip("diagnostics", !view.account.diagnostics)
          }
        }

        // The plugin: how it behaves in the bar.
        Column {
          Layout.fillWidth: true
          Layout.alignment: Qt.AlignTop
          Layout.preferredWidth: 1
          spacing: Style.space(10)

          PanelSectionHeader { text: "PLUGIN"; foreground: view.foreground; fontFamily: view.fontFamily }

          Toggle {
            width: parent.width
            label: "Hide Blip's own windows"
            description: "Transfers, prompts and the app open here instead."
            checked: blip.hideWindows
            foreground: view.foreground
            accent: view.accent
            fontFamily: view.fontFamily
            onClicked: blip.setPlugin("hideBlipWindows", !blip.hideWindows)
          }

          NumberField {
            label: "Recent people in the To list"
            value: blip.recentPeople
            from: 0
            to: 20
            stepSize: 1
            foreground: view.foreground
            accent: view.accent
            fontFamily: view.fontFamily
            onModified: function(value) { blip.setPlugin("recentPeople", value) }
          }

          NumberField {
            label: "Received files to list"
            value: blip.historyLimit
            from: 5
            to: 200
            stepSize: 5
            foreground: view.foreground
            accent: view.accent
            fontFamily: view.fontFamily
            onModified: function(value) { blip.setPlugin("historyLimit", value) }
          }

          NumberField {
            label: "Check Blip every (seconds, when it is not running)"
            value: blip.refreshIntervalSec
            from: 2
            to: 600
            stepSize: 1
            foreground: view.foreground
            accent: view.accent
            fontFamily: view.fontFamily
            onModified: function(value) { blip.setPlugin("refreshIntervalSec", value) }
          }

          PanelSeparator { width: parent.width }

          Row {
            spacing: Style.space(8)

            Button {
              text: "Open Blip's window"
              iconText: "󰖲"
              bordered: true
              foreground: view.foreground
              accent: view.accent
              fontFamily: view.fontFamily
              tooltipText: "Blip's own app, for anything not here"
              onClicked: blip.showRealApp()
            }

            Button {
              text: view.confirmLogout ? "Click again to log out" : "Log out"
              iconText: "󰍃"
              bordered: true
              foreground: view.urgent
              accent: view.urgent
              fontFamily: view.fontFamily
              visible: !!view.account.email
              onClicked: {
                if (!view.confirmLogout) {
                  view.confirmLogout = true
                  logoutTimer.restart()
                  return
                }
                view.confirmLogout = false
                blip.setBlip("logout", "")
              }
            }
          }
        }
      }
    }
  }

  // A labelled text setting, applied on Enter or when focus leaves it.
  component SettingField: Column {
    id: settingField
    property string label: ""
    property string value: ""
    property string placeholder: ""
    property string buttonIcon: ""
    property string buttonTip: ""
    signal committed(string text)
    signal buttonClicked()

    width: parent ? parent.width : 0
    spacing: Style.space(4)

    Text {
      textFormat: Text.PlainText
      text: settingField.label
      color: Qt.darker(view.foreground, 1.4)
      font.family: view.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    RowLayout {
      width: parent.width
      spacing: Style.space(6)

      TextField {
        id: input
        Layout.fillWidth: true
        text: settingField.value
        placeholderText: settingField.placeholder
        font.family: view.fontFamily
        font.pixelSize: Style.font.body
        foreground: view.foreground
        accent: view.accent
        onEditingFinished: if (text.trim() !== settingField.value) settingField.committed(text.trim())
        Keys.onEscapePressed: { text = settingField.value; view.forceActiveFocus() }
      }

      PanelActionButton {
        visible: settingField.buttonIcon !== ""
        iconText: settingField.buttonIcon
        tooltipText: settingField.buttonTip
        foreground: view.foreground
        fontFamily: view.fontFamily
        onClicked: settingField.buttonClicked()
      }
    }
  }
}
