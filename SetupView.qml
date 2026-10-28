import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// First run: install Blip, start it, and sign in with an emailed code, all in
// the plugin's own style so Blip's onboarding window never has to show.
Item {
  id: view

  required property var blip

  property color foreground: Commons.Color.foreground
  property color urgent: Commons.Color.urgent
  property color accent: Commons.Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  property string fontFamily: Style.font.family

  readonly property var registration: blip.registration || ({})
  // Back to the email form after a code was sent, to use another address.
  property bool changingEmail: false
  readonly property string step: {
    if (!blip.installed) return "install"
    if (!blip.running) return "start"
    if (blip.signedIn && registration.needsProfile) return "profile"
    if (blip.signedIn) return "done"
    if (!view.changingEmail && (registration.status === "codeSent" || registration.status === "registering")) return "code"
    return "email"
  }
  readonly property real contentImplicitHeight: page.implicitHeight
  readonly property string error: blip.loginError !== "" ? blip.loginError : (registration.error || "")

  signal closeRequested()

  function focusInitial() {
    if (view.step === "start") blip.startBlip()
    Qt.callLater(function() {
      if (view.step === "email") emailField.forceActiveFocus()
      else if (view.step === "code") codeField.forceActiveFocus()
      else if (view.step === "profile") nameField.forceActiveFocus()
      else view.forceActiveFocus()
    })
  }

  onStepChanged: {
    if (step !== "email") changingEmail = false
    if (view.visible) focusInitial()
  }

  Keys.onEscapePressed: view.closeRequested()

  function sendCode() {
    var email = emailField.text.trim()
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || view.blip.loginBusy) return
    view.changingEmail = false
    blip.sendLoginCode(email, deviceField.text.trim() || registration.suggestedDeviceName || "Linux PC")
  }

  function submitCode() {
    var code = codeField.text.replace(/\s+/g, "")
    if (code === "" || view.blip.loginBusy) return
    blip.signIn(code, deviceField.text.trim() || registration.suggestedDeviceName || "Linux PC")
    codeField.text = ""
  }

  Flickable {
    anchors.fill: parent
    contentWidth: width
    contentHeight: page.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Column {
      id: page
      width: parent.width
      spacing: Style.space(14)

      PanelHero {
        width: parent.width
        title: view.step === "install" ? "Get Blip"
             : view.step === "start" ? "Starting Blip"
             : view.step === "code" ? "Check your email"
             : view.step === "profile" ? "One last thing"
             : "Sign in to Blip"
        meta: view.step === "install" ? "Blip isn't installed yet"
            : view.step === "start" ? "Waiting for Blip to start…"
            : view.step === "code" ? "We sent a code to " + (view.registration.email || "your email")
            : view.step === "profile" ? "How should people see you?"
            : "Send files to your devices and to anyone"
        foreground: view.foreground
        fontFamily: view.fontFamily
        iconComponent: Component {
          BlipIcon {
            iconSize: Style.font.display
            color: view.foreground
          }
        }
      }

      Text {
        visible: view.error !== ""
        width: parent.width
        textFormat: Text.PlainText
        text: view.error
        color: view.urgent
        font.family: view.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }

      // Not installed: Blip's Linux app is the AUR package blipnet.
      Column {
        visible: view.step === "install"
        width: parent.width
        spacing: Style.space(10)

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: "This plugin works with the Blip app. Installing opens a terminal that builds the "
                + "AUR package blipnet and asks for your password."
          color: view.dim
          font.family: view.fontFamily
          font.pixelSize: Style.font.body
          wrapMode: Text.WordWrap
        }

        Button {
          text: "Install Blip"
          iconText: "󰏔"
          bordered: true
          foreground: view.foreground
          accent: view.accent
          fontFamily: view.fontFamily
          onClicked: view.blip.installBlip()
        }
      }

      Button {
        visible: view.step === "start"
        text: "Start Blip"
        iconText: "󰐊"
        bordered: true
        foreground: view.foreground
        accent: view.accent
        fontFamily: view.fontFamily
        onClicked: view.blip.startBlip()
      }

      // Email (and this device's name) first; Blip emails a one-time code.
      Column {
        visible: view.step === "email"
        width: parent.width
        spacing: Style.space(8)

        FieldLabel { text: "Email" }
        TextField {
          id: emailField
          width: parent.width
          placeholderText: "you@example.com"
          inputMethodHints: Qt.ImhEmailCharactersOnly | Qt.ImhNoAutoUppercase
          font.family: view.fontFamily
          font.pixelSize: Style.font.body
          foreground: view.foreground
          accent: view.accent
          text: view.registration.email || ""
          onAccepted: view.sendCode()
        }

        FieldLabel { text: "This device's name" }
        TextField {
          id: deviceField
          width: parent.width
          placeholderText: view.registration.suggestedDeviceName || "Linux PC"
          font.family: view.fontFamily
          font.pixelSize: Style.font.body
          foreground: view.foreground
          accent: view.accent
          onAccepted: view.sendCode()
        }

        Button {
          text: view.registration.status === "sending" || view.blip.loginBusy ? "Sending…" : "Email me a code"
          iconText: "󰇮"
          bordered: true
          foreground: view.foreground
          accent: view.accent
          fontFamily: view.fontFamily
          onClicked: view.sendCode()
        }
      }

      Column {
        visible: view.step === "code"
        width: parent.width
        spacing: Style.space(8)

        FieldLabel { text: "Code" }
        TextField {
          id: codeField
          width: parent.width
          placeholderText: "Code from the email"
          inputMethodHints: Qt.ImhNoPredictiveText | Qt.ImhSensitiveData
          font.family: view.fontFamily
          font.pixelSize: Style.font.body
          foreground: view.foreground
          accent: view.accent
          onAccepted: view.submitCode()
        }

        Row {
          spacing: Style.space(8)

          Button {
            text: view.registration.status === "registering" || view.blip.loginBusy ? "Signing in…" : "Sign in"
            iconText: "󰍂"
            bordered: true
            foreground: view.foreground
            accent: view.accent
            fontFamily: view.fontFamily
            onClicked: view.submitCode()
          }

          Button {
            text: "Use another email"
            foreground: view.foreground
            accent: view.accent
            fontFamily: view.fontFamily
            onClicked: {
              view.changingEmail = true
              view.focusInitial()
            }
          }
        }
      }

      Column {
        visible: view.step === "profile"
        width: parent.width
        spacing: Style.space(8)

        FieldLabel { text: "Your name" }
        TextField {
          id: nameField
          width: parent.width
          placeholderText: "Shown to people you send to"
          font.family: view.fontFamily
          font.pixelSize: Style.font.body
          foreground: view.foreground
          accent: view.accent
          onAccepted: if (text.trim() !== "") view.blip.finishProfile(text)
        }

        Button {
          text: "Done"
          iconText: "󰄬"
          bordered: true
          foreground: view.foreground
          accent: view.accent
          fontFamily: view.fontFamily
          onClicked: if (nameField.text.trim() !== "") view.blip.finishProfile(nameField.text)
        }
      }
    }
  }

  component FieldLabel: Text {
    textFormat: Text.PlainText
    color: Qt.darker(view.foreground, 1.4)
    font.family: view.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
}
