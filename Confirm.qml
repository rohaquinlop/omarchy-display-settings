import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Ui
import qs.Commons

// Floating "keep these display settings?" card — the same pattern macOS and
// Windows use after a display change. It appears the moment a preview is
// armed and stays up regardless of whether the bar popup is open, because
// the 15-second window is short and easy to miss if the only way to see or
// act on it is to have already reopened the panel.
//
// Owned by Panel.qml behind a Loader bound to `previewing` rather than a
// manual open()/close(): a PanelWindow instantiated directly inside a bar
// widget stops the widget rendering at all (see Panel.qml/Arrange.qml), and
// here the dialog's whole point is to appear on its own, not on a click.
Item {
  id: root

  property QtObject bar: null
  property bool previewing: false
  property int secondsRemaining: 0

  signal keepRequested()
  signal revertRequested()

  readonly property color foreground: Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  PanelWindow {
    visible: root.previewing
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-display-settings-confirm"
    WlrLayershell.layer: WlrLayer.Overlay
    // Deliberately WlrKeyboardFocus.None, unlike Arrange/Advanced: this
    // dialog must not swallow the whole screen's input. The user should be
    // able to keep working while deciding, exactly as the OS-level version
    // behaves -- it never grabs focus either.
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      id: card
      anchors.horizontalCenter: parent.horizontalCenter
      y: parent.height * 0.14
      width: Math.min(parent.width - Style.space(80), Style.space(420))
      implicitHeight: content.implicitHeight + Style.space(28)
      radius: Style.cornerRadius
      color: Color.popups.background
      border.width: 1
      border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)

      // A soft shadow-like backing so the card reads as floating above the
      // desktop rather than pasted flat onto it.
      Rectangle {
        anchors.fill: parent
        anchors.margins: -2
        radius: parent.radius + 2
        color: "transparent"
        border.width: 1
        border.color: Qt.rgba(0, 0, 0, 0.25)
        z: -1
      }

      Column {
        id: content
        anchors.centerIn: parent
        width: parent.width - Style.space(28)
        spacing: Style.space(10)

        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          horizontalAlignment: Text.AlignHCenter
          textFormat: Text.PlainText
          text: "Keep these display settings?"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          textFormat: Text.PlainText
          text: "Reverting automatically in " + root.secondsRemaining + "s"
          color: root.foreground
          opacity: 0.6
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(10)

          Button {
            text: "Revert"
            bordered: true
            onClicked: root.revertRequested()
          }

          // The default, expected action gets the accent treatment, matching
          // the primary/secondary button convention this pattern is known for.
          Button {
            text: "Keep"
            bordered: true
            foreground: Color.accent
            onClicked: root.keepRequested()
          }
        }
      }
    }
  }
}
