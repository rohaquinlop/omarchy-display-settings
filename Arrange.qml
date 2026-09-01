import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Ui
import qs.Commons
import "Model.js" as Model

// Fullscreen arrangement canvas. Owned by Panel.qml rather than declared as an
// `overlay` plugin kind: a plugin that is both bar-widget and overlay gives the
// summoned surface to the overlay (shell.qml:426), which would make
// SUPER + CTRL + D open this canvas instead of the Display panel.
//
// Everything here works in logical pixels. Hyprland positions monitors in
// scale-adjusted space, so a 2560x1440 panel at scale 1.25 occupies 2048x1152.
// Drawing in physical pixels would place every multi-monitor layout wrongly.
Item {
  id: root

  property QtObject bar: null
  property bool opened: false
  property bool previewing: false
  property int secondsRemaining: 0

  // Working copy: {name, x, y, width, height, disabled, mode, scale, transform, mirror}
  property var tiles: []
  property string selectedName: ""
  property int snapThreshold: 40

  signal applyRequested(var layout)
  signal keepRequested()
  signal revertRequested()

  readonly property color foreground: Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  function show(outputs) {
    var next = []
    for (var i = 0; i < outputs.length; i++) {
      var display = outputs[i]
      var size = Model.logicalSize(display.mode, display.scale, display.transform)
      next.push({
        name: display.name,
        x: display.x,
        y: display.y,
        width: size.width,
        height: size.height,
        disabled: display.disabled,
        mode: display.mode,
        scale: display.scale,
        transform: display.transform,
        mirror: display.mirror
      })
    }
    root.tiles = next
    root.selectedName = next.length ? next[0].name : ""
    root.opened = true
  }

  function hide() { root.opened = false }

  function box() {
    var live = root.tiles.filter(function(t) { return !t.disabled })
    return Model.boundingBox(live.length ? live : root.tiles)
  }

  // One factor maps logical pixels onto the canvas, so relative sizes stay true.
  function factor() {
    var b = root.box()
    if (b.width <= 0 || b.height <= 0) return 0.1
    return Math.min(canvas.width * 0.8 / b.width, canvas.height * 0.8 / b.height)
  }

  // Called once when a drag ends: snap against the other tiles, then publish
  // the new model. Snapping mid-drag would fight the pointer.
  function commitTile(name, logicalX, logicalY) {
    moveTile(name, logicalX, logicalY)
  }

  function moveTile(name, logicalX, logicalY) {
    var next = []
    var moving = null
    for (var i = 0; i < root.tiles.length; i++) {
      var copy = JSON.parse(JSON.stringify(root.tiles[i]))
      if (copy.name === name) { copy.x = logicalX; copy.y = logicalY; moving = copy }
      next.push(copy)
    }
    if (moving) {
      var snapped = Model.snap(moving, next, root.snapThreshold / root.factor())
      moving.x = snapped.x
      moving.y = snapped.y
    }
    root.tiles = next
  }

  function problems() {
    var found = []
    var live = root.tiles.filter(function(t) { return !t.disabled && !t.mirror })
    if (!root.tiles.filter(function(t) { return !t.disabled }).length)
      found.push("At least one display must stay on.")
    if (Model.anyOverlap(live)) found.push("Displays overlap. Drag them apart.")
    return found
  }

  function apply() {
    if (root.problems().length) return
    var b = root.box()
    var layout = []
    for (var i = 0; i < root.tiles.length; i++) {
      var tile = root.tiles[i]
      var rule = {
        output: tile.name,
        mode: tile.mode || "preferred",
        position: Math.round(tile.x - b.x) + "x" + Math.round(tile.y - b.y),
        scale: tile.scale,
        transform: tile.transform
      }
      if (tile.mirror) rule.mirror = tile.mirror
      if (tile.disabled) rule.disabled = true
      layout.push(rule)
    }
    root.applyRequested(layout)
  }

  PanelWindow {
    id: window
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-display-settings-arrange"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: Color.background
      opacity: 0.92
    }

    // Keyboard focus is a layer-shell property; the key handler itself lives on
    // a child item, as the stock image-picker overlay does.
    Item {
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) { root.hide(); event.accepted = true }
      }
    }

    Column {
      anchors.centerIn: parent
      width: Math.min(parent.width - Style.space(80), Style.space(1000))
      spacing: Style.space(16)

      Text {
        textFormat: Text.PlainText
        text: "Arrange displays"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.display
        anchors.horizontalCenter: parent.horizontalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: "Drag a display to move it. Edges snap."
        color: root.foreground
        opacity: 0.6
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.horizontalCenter: parent.horizontalCenter
      }

      // ---------- canvas ----------
      Rectangle {
        id: canvas
        width: parent.width
        height: Style.space(420)
        color: "transparent"
        border.width: 1
        border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)
        radius: Style.cornerRadius

        readonly property real factor: root.factor()
        readonly property var origin: root.box()
        readonly property real offsetX: (width - origin.width * factor) / 2
        readonly property real offsetY: (height - origin.height * factor) / 2

        Repeater {
          model: root.tiles

          delegate: Rectangle {
            id: tile
            required property var modelData

            // Position is set imperatively rather than bound to the model:
            // `drag.target` writes x/y directly, and a binding would fight it.
            // Delegates are recreated whenever the model changes, so
            // Component.onCompleted re-syncs them after every commit.
            function syncFromModel() {
              x = canvas.offsetX + (modelData.x - canvas.origin.x) * canvas.factor
              y = canvas.offsetY + (modelData.y - canvas.origin.y) * canvas.factor
            }
            Component.onCompleted: syncFromModel()
            onWidthChanged: if (!dragArea.drag.active) syncFromModel()
            width: Math.max(24, modelData.width * canvas.factor)
            height: Math.max(18, modelData.height * canvas.factor)

            color: modelData.disabled
              ? "transparent"
              : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.10)
            border.width: root.selectedName === modelData.name ? 2 : 1
            border.color: root.selectedName === modelData.name
              ? Color.accent
              : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.45)
            radius: Style.cornerRadius
            opacity: modelData.disabled ? 0.4 : 1.0

            Column {
              anchors.centerIn: parent
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                text: tile.modelData.name
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                anchors.horizontalCenter: parent.horizontalCenter
              }

              Text {
                textFormat: Text.PlainText
                text: tile.modelData.disabled
                  ? "off"
                  : tile.modelData.width + "×" + tile.modelData.height
                color: root.foreground
                opacity: 0.6
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.horizontalCenter: parent.horizontalCenter
              }
            }

            // drag.target moves the item itself, so the pointer keeps its
            // grab for the whole gesture. Rewriting the model on every mouse
            // move instead made the Repeater rebuild this delegate mid-drag,
            // destroying the MouseArea holding the grab — the tile jumped once
            // and then needed a fresh click.
            MouseArea {
              id: dragArea
              anchors.fill: parent
              cursorShape: Qt.SizeAllCursor
              drag.target: tile
              drag.threshold: 0
              drag.smoothed: false

              onPressed: root.selectedName = tile.modelData.name

              onReleased: {
                root.commitTile(
                  tile.modelData.name,
                  Math.round((tile.x - canvas.offsetX) / canvas.factor + canvas.origin.x),
                  Math.round((tile.y - canvas.offsetY) / canvas.factor + canvas.origin.y))
              }
            }
          }
        }
      }

      // ---------- problems ----------
      Column {
        width: parent.width
        spacing: Style.space(4)
        visible: root.problems().length > 0

        Repeater {
          model: root.problems()
          delegate: Text {
            required property string modelData
            textFormat: Text.PlainText
            text: "⚠ " + modelData
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      // ---------- countdown ----------
      Column {
        width: parent.width
        spacing: Style.space(6)
        visible: root.previewing

        Text {
          textFormat: Text.PlainText
          text: "Keep these settings? Reverting in " + root.secondsRemaining + "s"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          anchors.horizontalCenter: parent.horizontalCenter
        }

        Row {
          spacing: Style.space(10)
          anchors.horizontalCenter: parent.horizontalCenter
          Button { text: "Keep"; bordered: true; onClicked: root.keepRequested() }
          Button { text: "Revert"; bordered: true; onClicked: root.revertRequested() }
        }
      }

      // ---------- actions ----------
      Row {
        spacing: Style.space(10)
        anchors.horizontalCenter: parent.horizontalCenter
        visible: !root.previewing

        Button { text: "Close"; bordered: true; onClicked: root.hide() }
        Button {
          text: "Apply"
          bordered: true
          enabled: root.problems().length === 0
          onClicked: root.apply()
        }
      }
    }
  }
}
