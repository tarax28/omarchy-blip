import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Everything Blip shows: the "To" picker with devices and people, transfers
// in flight, and received files. The bar panel shows it as one column; the
// app window lays it out wide, in two.
Item {
  id: view

  required property var blip
  property bool wide: false
  // The panel closes once a send is on its way; the window stays put.
  property bool closeAfterSend: true
  property string heroActionIcon: "󰖲"
  property string heroActionTip: ""

  property color foreground: Commons.Color.foreground
  property color urgent: Commons.Color.urgent
  property color accent: Commons.Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  property string fontFamily: Style.font.family

  signal closeRequested()
  signal heroActionClicked()
  signal tabRequested(int direction)

  // Files dropped on the view (or the bar mark) waiting for a destination.
  property var pendingPaths: []
  // What is typed in the "To" field: a device, a name or an email.
  property string query: ""
  readonly property var targets: Model.targets(blip.devices, blip.people, query, blip.search)
  onQueryChanged: blip.lookup(query)
  readonly property bool hasPending: pendingPaths.length > 0
  property string focusSection: "devices"
  property int cursorIndex: 0
  property bool cursorActive: false

  readonly property alias searchField: searchField
  readonly property alias keyCatcher: keyCatcher

  function heroMeta() {
    if (!blip.installed) return "Blip is not installed"
    if (!blip.signedIn) return "Sign in to Blip to send files"
    if (view.hasPending) return "Choose where to send " + Model.pendingTitle(view.pendingPaths)
    if (!blip.running) return "Not running · will start on first send"
    var n = blip.devices.length
    return n === 0 ? "No other devices yet" : (n === 1 ? "1 device" : n + " devices")
  }

  function takeDrop(paths) {
    if (!paths || paths.length === 0) return
    view.addPaths(paths)
    view.setCursor("devices", 0)
    Qt.callLater(function() { searchField.forceActiveFocus() })
  }

  // Every drop adds to what is already waiting; the same file twice is kept once.
  function addPaths(paths) {
    var merged = view.pendingPaths.slice()
    for (var i = 0; i < paths.length; i++) {
      if (merged.indexOf(paths[i]) < 0) merged.push(paths[i])
    }
    view.pendingPaths = merged
  }

  function removePath(path) {
    view.pendingPaths = view.pendingPaths.filter(function(p) { return p !== path })
  }

  // Closing keeps queued files: picking the next file in a file manager
  // closes the panel, and that drop should add to the queue, not replace it.
  function reset() {
    view.query = ""
    view.cursorActive = false
    flick.contentY = 0
  }

  // With files waiting, focus lands on the "To" field, like Blip's picker.
  function focusInitial() {
    if (!view.hasPending) view.cursorActive = false
    Qt.callLater(function() { (view.hasPending ? searchField : keyCatcher).forceActiveFocus() })
  }

  function sendTo(entry) {
    if (!entry || entry.type === "status") return
    if (entry.type === "focus") {
      searchField.forceActiveFocus()
      return
    }
    var paths = view.pendingPaths
    view.pendingPaths = []
    view.query = ""
    if (view.closeAfterSend) view.closeRequested()
    if (entry.type === "handoff") {
      if (paths.length > 0) blip.handoff(paths, entry.query)
      else blip.pickAndHandoff(entry.query)
    } else if (paths.length > 0) {
      blip.send(entry.target, paths)
    } else {
      blip.pickAndSend(entry.target)
    }
  }

  function sectionLength(section) {
    return section === "devices" ? view.targets.length : blip.received.length
  }

  function moveCursor(dy) {
    if (dy === 0) return
    if (!view.cursorActive) {
      view.cursorActive = true
      return
    }
    var next = view.cursorIndex + dy
    if (view.focusSection === "devices" && next >= view.targets.length && blip.received.length > 0) {
      view.focusSection = "files"
      next = 0
    } else if (view.focusSection === "files" && next < 0 && view.targets.length > 0) {
      view.focusSection = "devices"
      next = view.targets.length - 1
    }
    view.cursorIndex = Math.max(0, Math.min(view.sectionLength(view.focusSection) - 1, next))
    scrollCursorIntoView()
  }

  function activateCursor() {
    if (!view.cursorActive) return
    if (view.focusSection === "devices") view.sendTo(view.targets[view.cursorIndex])
    else blip.openFile(blip.received[view.cursorIndex])
  }

  function setCursor(section, index) {
    view.cursorActive = true
    view.focusSection = section
    view.cursorIndex = index
  }

  function scrollCursorIntoView() {
    var column = view.focusSection === "devices" ? deviceColumn : fileColumn
    var scroller = view.wide && view.focusSection === "files" ? sideFlick : flick
    if (!column || view.cursorIndex < 0 || view.cursorIndex >= column.children.length) return
    var item = column.children[view.cursorIndex]
    Qt.callLater(function() {
      if (!item) return
      var margin = Style.space(6)
      var top = item.mapToItem(scroller.contentItem, 0, 0).y
      var bottom = top + item.height
      var maxY = Math.max(0, scroller.contentHeight - scroller.height)
      if (top < scroller.contentY + margin) scroller.contentY = Math.max(0, top - margin)
      else if (bottom > scroller.contentY + scroller.height - margin) scroller.contentY = Math.min(maxY, bottom + margin - scroller.height)
    })
  }

  // Natural height of the single-column layout, for the bar panel to size to.
  readonly property real contentImplicitHeight: mainColumn.implicitHeight

  PanelKeyCatcher {
    id: keyCatcher
    anchors.fill: parent
    blocked: searchField.activeFocus
    onMoveRequested: function(dx, dy) { view.moveCursor(dy) }
    onActivateRequested: view.activateCursor()
    onCloseRequested: {
      if (view.hasPending) view.pendingPaths = []
      else view.closeRequested()
    }
    onTabRequested: function(direction) { view.tabRequested(direction) }
    onTextKey: function(t) {
      if (t === "/") searchField.forceActiveFocus()
      else if (t === "r" || t === "R") blip.refresh()
      else if (t === "w" || t === "W") view.heroActionClicked()
      else if (t === "o" || t === "O") blip.openDownloads()
      else if ((t === "f" || t === "F") && view.cursorActive && view.focusSection === "files") blip.revealFile(blip.received[view.cursorIndex])
    }

    // Dropping anywhere on the view queues the files, same as the bar mark.
    DropArea {
      anchors.fill: parent
      keys: ["text/uri-list"]
      onDropped: function(event) {
        var paths = Model.pathsFromUris(event.getDataAsString("text/uri-list"))
        if (paths.length === 0) return
        event.accept(Qt.CopyAction)
        view.takeDrop(paths)
      }
    }

    RowLayout {
      anchors.fill: parent
      spacing: Style.space(24)

      Flickable {
        id: flick
        Layout.fillHeight: true
        Layout.fillWidth: !view.wide
        Layout.preferredWidth: view.wide ? Math.round(view.width * 0.42) : -1
        contentWidth: width
        contentHeight: mainColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: mainColumn
          width: flick.width
          spacing: Style.space(12)

          PanelHero {
            id: hero
            width: parent.width
            title: "Blip"
            meta: view.heroMeta()
            foreground: view.foreground
            fontFamily: view.fontFamily
            iconOpacity: blip.running ? 1.0 : 0.5
            iconComponent: Component {
              BlipIcon {
                iconSize: Style.font.display
                color: view.foreground
              }
            }
            trailingControl: Component {
              PanelActionButton {
                iconText: view.heroActionIcon
                tooltipText: view.heroActionTip
                foreground: hero.foreground
                fontFamily: hero.fontFamily
                onClicked: view.heroActionClicked()
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: blip.actionStatus !== "" || blip.lastError !== ""
            width: parent.width
            text: blip.actionStatus !== "" ? blip.actionStatus : blip.lastError
            color: blip.actionStatus === "" ? view.urgent : view.dim
            font.family: view.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          PendingCard {
            visible: view.hasPending
            width: parent.width
          }

          Loader {
            width: parent.width
            active: !view.wide
            visible: active && blip.transfers.length > 0
            sourceComponent: transfersSection
          }

          Column {
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "SEND TO"
              foreground: view.foreground
              fontFamily: view.fontFamily
            }

            TextField {
              id: searchField
              width: parent.width
              placeholderText: "To: name or email"
              font.family: view.fontFamily
              font.pixelSize: Style.font.body
              foreground: view.foreground
              horizontalPadding: Style.spacing.controlGap
              verticalPadding: Style.spacing.controlPaddingY
              text: view.query
              onTextChanged: {
                if (text === view.query) return
                view.query = text
                view.setCursor("devices", 0)
              }
              onAccepted: {
                if (!view.cursorActive) view.setCursor("devices", 0)
                view.activateCursor()
              }
              Keys.onUpPressed: view.moveCursor(-1)
              Keys.onDownPressed: view.moveCursor(1)
              Keys.onTabPressed: keyCatcher.forceActiveFocus()
              Keys.onEscapePressed: {
                if (text !== "") view.query = ""
                else if (view.hasPending) view.pendingPaths = []
                else view.closeRequested()
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: view.wide && !view.hasPending
              width: parent.width
              text: "Drop files here, or pick someone to choose files."
              color: view.dim
              font.family: view.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Column {
              id: deviceColumn
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: view.targets
                TargetRow {
                  required property var modelData
                  required property int index
                  width: deviceColumn.width
                  entry: modelData
                  rowIndex: index
                }
              }
            }
          }

          PanelSeparator {
            visible: !view.wide
            foreground: view.foreground
          }

          Loader {
            width: parent.width
            active: !view.wide
            visible: active
            sourceComponent: receivedSection
          }
        }
      }

      // Wide layout only: transfers and received files get their own column.
      Rectangle {
        visible: view.wide
        Layout.fillHeight: true
        Layout.preferredWidth: 1
        color: Qt.rgba(view.foreground.r, view.foreground.g, view.foreground.b, 0.12)
      }

      Flickable {
        id: sideFlick
        visible: view.wide
        Layout.fillHeight: true
        Layout.fillWidth: true
        contentWidth: width
        contentHeight: sideColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: sideColumn
          width: sideFlick.width
          spacing: Style.space(16)

          Loader {
            width: parent.width
            active: view.wide
            visible: active && blip.transfers.length > 0
            sourceComponent: transfersSection
          }

          Loader {
            width: parent.width
            active: view.wide
            visible: active
            sourceComponent: receivedSection
          }
        }
      }
    }
  }

  Component {
    id: transfersSection

    Column {
      visible: blip.transfers.length > 0
      spacing: Style.space(10)

      PanelSectionHeader {
        text: "TRANSFERS"
        foreground: view.foreground
        fontFamily: view.fontFamily
      }

      Column {
        width: parent.width
        spacing: Style.space(6)

        Repeater {
          model: blip.transfers
          TransferRow {
            required property var modelData
            width: parent.width
            transfer: modelData
          }
        }
      }
    }
  }

  // The received list is the cursor's "files" section, so the column it
  // lives in is published for scrollCursorIntoView.
  property Item fileColumn: null

  Component {
    id: receivedSection

    Column {
      spacing: Style.space(10)

      PanelSectionHeader {
        text: "RECEIVED"
        foreground: view.foreground
        fontFamily: view.fontFamily
      }

      Text {
        visible: blip.received.length === 0
        width: parent.width
        text: "Nothing received yet."
        color: view.dim
        font.family: view.fontFamily
        font.pixelSize: Style.font.body
        horizontalAlignment: Text.AlignHCenter
      }

      Column {
        id: files
        visible: blip.received.length > 0
        width: parent.width
        spacing: Style.space(6)
        Component.onCompleted: view.fileColumn = files
        Component.onDestruction: if (view.fileColumn === files) view.fileColumn = null

        Repeater {
          model: blip.received
          FileRow {
            required property var modelData
            required property int index
            width: parent.width
            file: modelData
            rowIndex: index
          }
        }
      }
    }
  }

  component PendingCard: CursorSurface {
    foreground: view.foreground
    current: true
    implicitHeight: pendingColumn.implicitHeight + Style.spacing.rowPaddingX

    Column {
      id: pendingColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(4)

    RowLayout {
      width: parent.width
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: view.pendingPaths.length === 1 ? Model.fileGlyph(view.pendingPaths[0]) : "󰉖"
        color: view.accent
        font.family: view.fontFamily
        font.pixelSize: Style.font.icon
        horizontalAlignment: Text.AlignHCenter
        Layout.preferredWidth: Style.font.icon * 1.4
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: Model.pendingTitle(view.pendingPaths)
          color: view.foreground
          font.family: view.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideMiddle
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: (view.pendingPaths.length > 1 ? "Drop more to add · " : "Ready to send · ") + "pick a device or type a name or email"
          color: view.dim
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        iconText: "󰅖"
        tooltipText: view.pendingPaths.length > 1 ? "Remove all (esc)" : "Cancel (esc)"
        foreground: view.foreground
        fontFamily: view.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: view.pendingPaths = []
      }
    }

    // With several files, each one is listed and can be taken out alone.
    Repeater {
      model: view.pendingPaths.length > 1 ? view.pendingPaths : []

      RowLayout {
        required property var modelData
        width: pendingColumn.width
        spacing: Style.space(8)

        Text {
          textFormat: Text.PlainText
          text: Model.fileGlyph(modelData)
          color: view.dim
          font.family: view.fontFamily
          font.pixelSize: Style.font.bodySmall
          horizontalAlignment: Text.AlignHCenter
          Layout.preferredWidth: Style.font.icon * 1.4
          Layout.alignment: Qt.AlignVCenter
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: Model.baseName(modelData)
          color: view.foreground
          font.family: view.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideMiddle
        }

        PanelActionButton {
          iconText: "󰅖"
          tooltipText: "Remove"
          foreground: view.dim
          fontFamily: view.fontFamily
          Layout.alignment: Qt.AlignVCenter
          onClicked: view.removePath(modelData)
        }
      }
    }
    }
  }

  component TransferRow: CursorSurface {
    id: transferRow
    property var transfer: null
    readonly property bool active: transfer && transfer.status === "Active"
    readonly property real fraction: Model.transferFraction(transfer)

    foreground: view.foreground
    implicitHeight: transferContent.implicitHeight + Style.spacing.rowPaddingX

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: transferRow.transfer && transferRow.transfer.outgoing ? "󰕒" : "󰇚"
        color: transferRow.active ? view.accent : view.foreground
        font.family: view.fontFamily
        font.pixelSize: Style.font.icon
        horizontalAlignment: Text.AlignHCenter
        Layout.preferredWidth: Style.font.icon * 1.4
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: transferContent
        Layout.fillWidth: true
        spacing: Style.space(3)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: Model.transferTitle(transferRow.transfer)
            color: view.foreground
            font.family: view.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideMiddle
          }

          Text {
            textFormat: Text.PlainText
            visible: transferRow.active && transferRow.transfer.total > 0
            text: Math.floor(transferRow.fraction * 100) + "%"
            color: view.foreground
            font.family: view.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Rectangle {
          Layout.fillWidth: true
          Layout.preferredHeight: Math.max(3, Style.space(3))
          radius: height / 2
          color: Qt.rgba(view.foreground.r, view.foreground.g, view.foreground.b, 0.15)

          Rectangle {
            width: parent.width * transferRow.fraction
            height: parent.height
            radius: parent.radius
            color: transferRow.transfer && transferRow.transfer.paused ? view.dim : view.accent
            Behavior on width { NumberAnimation { duration: 250 } }
          }
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: Model.transferMeta(transferRow.transfer)
          color: view.dim
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      // Someone is offering files: answer here, since Blip's own prompt is hidden.
      PanelActionButton {
        visible: !!(transferRow.transfer && transferRow.transfer.asking)
        iconText: "󰄬"
        tooltipText: "Accept"
        foreground: view.accent
        fontFamily: view.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: blip.answer(transferRow.transfer, true)
      }

      PanelActionButton {
        visible: !!(transferRow.transfer && transferRow.transfer.asking)
        iconText: "󰅖"
        tooltipText: "Decline"
        foreground: view.urgent
        fontFamily: view.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: blip.answer(transferRow.transfer, false)
      }

      PanelActionButton {
        visible: !(transferRow.transfer && transferRow.transfer.asking)
        iconText: "󰓛"
        tooltipText: "Stop transfer"
        foreground: view.urgent
        fontFamily: view.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: blip.stop(transferRow.transfer)
      }
    }
  }

  component TargetRow: CursorSurface {
    id: deviceRow
    property var entry: null
    property int rowIndex: 0
    property bool dropping: false

    hasCursor: dropping || (view.cursorActive && view.focusSection === "devices" && view.cursorIndex === rowIndex)
    foreground: view.foreground
    implicitHeight: deviceContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: view.setCursor("devices", deviceRow.rowIndex)
      onClicked: view.sendTo(deviceRow.entry)
    }

    // A file dropped straight on a device skips the queue and goes now.
    DropArea {
      anchors.fill: parent
      keys: ["text/uri-list"]
      onEntered: deviceRow.dropping = true
      onExited: deviceRow.dropping = false
      onDropped: function(event) {
        deviceRow.dropping = false
        var paths = Model.pathsFromUris(event.getDataAsString("text/uri-list"))
        if (paths.length === 0) return
        event.accept(Qt.CopyAction)
        view.addPaths(paths)
        view.sendTo(deviceRow.entry)
      }
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      // A person's own devices sit indented under them.
      anchors.leftMargin: Style.space(deviceRow.entry && deviceRow.entry.nested ? 34 : 10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: deviceRow.entry ? deviceRow.entry.glyph : ""
        color: view.foreground
        font.family: view.fontFamily
        font.pixelSize: Style.font.icon
        horizontalAlignment: Text.AlignHCenter
        Layout.preferredWidth: Style.font.icon * 1.4
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: deviceContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: deviceRow.entry ? deviceRow.entry.name : ""
          color: view.foreground
          font.family: view.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: deviceRow.entry ? deviceRow.entry.meta : ""
          color: view.dim
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Text {
        textFormat: Text.PlainText
        text: "󰒊"
        visible: deviceRow.hasCursor && deviceRow.entry && deviceRow.entry.type !== "status"
        color: view.hasPending || deviceRow.dropping ? view.accent : view.dim
        font.family: view.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }
    }
  }

  component FileRow: CursorSurface {
    id: fileRow
    property var file: null
    property int rowIndex: 0
    readonly property string fileName: file ? String(file.name || "Untitled") : "Untitled"
    readonly property bool isNew: file && blip.seenTime >= 0 && Number(file.time || 0) > blip.seenTime

    hasCursor: view.cursorActive && view.focusSection === "files" && view.cursorIndex === rowIndex
    foreground: view.foreground
    opacity: file && file.exists === false ? 0.55 : 1.0
    implicitHeight: fileContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: view.setCursor("files", fileRow.rowIndex)
      onClicked: blip.openFile(fileRow.file)
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: Model.fileGlyph(fileRow.fileName)
        color: fileRow.isNew ? view.accent : view.foreground
        font.family: view.fontFamily
        font.pixelSize: Style.font.icon
        horizontalAlignment: Text.AlignHCenter
        Layout.preferredWidth: Style.font.icon * 1.4
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: fileContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: fileRow.fileName
          color: view.foreground
          font.family: view.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideMiddle
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: Model.fileMeta(fileRow.file)
          color: view.dim
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        visible: fileRow.hasCursor && fileRow.file && fileRow.file.exists !== false
        iconText: "󰝰"
        tooltipText: "Show in folder (f)"
        foreground: view.foreground
        fontFamily: view.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: blip.revealFile(fileRow.file)
      }
    }
  }
}
