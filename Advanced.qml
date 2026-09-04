import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Wayland
import qs.Ui
import qs.Commons

// The rest of Hyprland's HL.MonitorSpec surface, plus a raw escape hatch so no
// documented field is out of reach.
//
// Nothing is validated here beyond keeping the controls typed. The backend owns
// validation, because every value reaches both `hyprctl eval` (which executes
// Lua) and monitors.lua (which is Lua) — one whitelist, in one place, under
// test. This sheet only reports what the backend refuses.
Item {
  id: root

  property QtObject bar: null
  property var display: null
  property bool opened: false

  // Only fields the user actually set are emitted. An unset field must stay
  // out of the rule so Hyprland applies its own default rather than ours.
  property var pending: ({})
  property string rawKey: ""
  property string rawValue: ""
  property string errorText: ""

  signal closed()
  signal applyRequested(var changes)

  // A labelled single-line input. Ui/TextField inherits Qt Quick Controls
  // TextField, whose API has no label, so the name sits above the field.
  component LabeledField: Column {
    id: field
    property string label: ""
    property string placeholder: ""
    property string text: ""
    signal edited(string value)

    spacing: Style.space(3)

    Text {
      textFormat: Text.PlainText
      text: field.label
      color: root.foreground
      opacity: 0.7
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    TextField {
      width: field.width
      placeholderText: field.placeholder
      text: field.text
      onEditingFinished: field.edited(text)
    }
  }

  readonly property color foreground: Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var transformOptions: [
    { value: "0", label: "Normal" },
    { value: "1", label: "90°" },
    { value: "2", label: "180°" },
    { value: "3", label: "270°" },
    { value: "4", label: "Flipped" },
    { value: "5", label: "Flipped 90°" },
    { value: "6", label: "Flipped 180°" },
    { value: "7", label: "Flipped 270°" }
  ]

  readonly property var vrrOptions: [
    { value: "0", label: "Off" },
    { value: "1", label: "On" },
    { value: "2", label: "Fullscreen only" },
    { value: "3", label: "Fullscreen games and video" }
  ]

  readonly property var bitdepthOptions: [
    { value: "8", label: "8-bit" },
    { value: "10", label: "10-bit" }
  ]

  readonly property var cmOptions: [
    { value: "auto", label: "auto" },
    { value: "srgb", label: "sRGB" },
    { value: "wide", label: "Wide gamut" },
    { value: "edid", label: "From EDID" },
    { value: "hdr", label: "HDR" },
    { value: "hdredid", label: "HDR from EDID" }
  ]

  function open() {
    root.pending = ({})
    root.errorText = ""
    root.rawKey = ""
    root.rawValue = ""
    root.opened = true
  }

  function close() { root.opened = false; root.closed() }

  function set(field, value) {
    var next = ({})
    for (var key in root.pending) next[key] = root.pending[key]
    next[field] = value
    root.pending = next
  }

  function clear(field) {
    var next = ({})
    for (var key in root.pending) if (key !== field) next[key] = root.pending[key]
    root.pending = next
  }

  function currentOf(field, fallback) {
    if (root.pending[field] !== undefined) return String(root.pending[field])
    if (root.display && root.display[field] !== undefined && root.display[field] !== null)
      return String(root.display[field])
    return fallback
  }

  function addRaw() {
    if (root.rawKey === "") return
    var value = root.rawValue
    // Numbers stay numbers so they render unquoted in Lua; the backend still
    // has the final say on whether the field accepts them.
    if (value !== "" && !isNaN(Number(value))) value = Number(value)
    root.set(root.rawKey, value)
    root.rawKey = ""
    root.rawValue = ""
  }

  function apply() {
    if (Object.keys(root.pending).length === 0) { root.close(); return }
    root.applyRequested(root.pending)
    root.close()
  }

  PanelWindow {
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-display-settings-advanced"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: Color.background
      opacity: 0.92
    }

    // Keyboard focus is a layer-shell property; the key handler itself lives on
    // a child item, as the stock image-picker overlay does. It wraps the
    // ScrollView (rather than sitting beside it) so an unhandled Escape from
    // a focused descendant -- e.g. a dropdown's trigger, after its own list
    // closes -- bubbles up through this item and still closes the sheet,
    // instead of bubbling up a sibling branch that never reaches it.
    Item {
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) { root.close(); event.accepted = true }
      }

      ScrollView {
        id: scroller
        anchors.centerIn: parent
        width: Math.min(parent.width - Style.space(80), Style.space(560))
        height: Math.min(parent.height - Style.space(80), sheet.implicitHeight)
        clip: true
  
        Column {
          id: sheet
          width: scroller.availableWidth
          spacing: Style.space(12)
  
          Text {
            textFormat: Text.PlainText
            text: "Advanced"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
          }
  
          Text {
            textFormat: Text.PlainText
            text: root.display ? root.display.name : ""
            color: root.foreground
            opacity: 0.6
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
  
          PanelSeparator { width: parent.width }
  
          FixedDropdown {
            width: parent.width
            label: "Orientation"
            value: root.currentOf("transform", "0")
            options: root.transformOptions
            onChanged: function(value) { root.set("transform", parseInt(value, 10)) }
          }
  
          FixedDropdown {
            width: parent.width
            label: "Variable refresh rate"
            value: root.pending["vrr"] !== undefined
              ? String(root.pending["vrr"])
              : (root.display && root.display.vrr ? "1" : "0")
            options: root.vrrOptions
            onChanged: function(value) { root.set("vrr", parseInt(value, 10)) }
          }
  
          FixedDropdown {
            width: parent.width
            label: "Colour depth"
            value: root.currentOf("bitdepth", "8")
            options: root.bitdepthOptions
            onChanged: function(value) { root.set("bitdepth", parseInt(value, 10)) }
          }
  
          FixedDropdown {
            width: parent.width
            label: "Colour management"
            value: root.currentOf("cm", "auto")
            options: root.cmOptions
            onChanged: function(value) { root.set("cm", value) }
          }
  
          // Ui/TextField inherits Qt Quick Controls TextField, which carries no
          // label of its own, so each field states its own name above the input.
          LabeledField {
            width: parent.width
            label: "Mirror of"
            placeholder: "connector name, e.g. eDP-1"
            text: root.currentOf("mirror", "")
            onEdited: function(value) {
              value === "" ? root.clear("mirror") : root.set("mirror", value)
            }
          }
  
          LabeledField {
            width: parent.width
            label: "ICC profile"
            placeholder: "path to a .icc file"
            text: root.currentOf("icc", "")
            onEdited: function(value) {
              value === "" ? root.clear("icc") : root.set("icc", value)
            }
          }
  
          // Ui/NumberField is integer-only; these two are fractional, so they
          // take a numeric text field instead. The backend bounds them either way.
          LabeledField {
            width: parent.width
            label: "SDR brightness"
            placeholder: "1.0"
            text: root.currentOf("sdrbrightness", "")
            onEdited: function(value) {
              value === "" ? root.clear("sdrbrightness") : root.set("sdrbrightness", Number(value))
            }
          }
  
          LabeledField {
            width: parent.width
            label: "SDR saturation"
            placeholder: "1.0"
            text: root.currentOf("sdrsaturation", "")
            onEdited: function(value) {
              value === "" ? root.clear("sdrsaturation") : root.set("sdrsaturation", Number(value))
            }
          }
  
          PanelSeparator { width: parent.width }
  
          PanelSectionHeader { text: "OTHER FIELDS" }
  
          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: "Any documented HL.MonitorSpec field, for hardware this build "
              + "has no control for. Rejected keys are reported below."
            color: root.foreground
            opacity: 0.6
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
  
          Row {
            width: parent.width
            spacing: Style.space(6)
  
            TextField {
              width: (parent.width - Style.space(6) * 2 - Style.space(70)) / 2
              placeholderText: "field"
              text: root.rawKey
              onTextChanged: root.rawKey = text
            }
  
            TextField {
              width: (parent.width - Style.space(6) * 2 - Style.space(70)) / 2
              placeholderText: "value"
              text: root.rawValue
              onTextChanged: root.rawValue = text
            }
  
            Button {
              width: Style.space(70)
              text: "Add"
              bordered: true
              onClicked: root.addRaw()
            }
          }
  
          // What will actually be written, so nothing is a surprise.
          Column {
            width: parent.width
            spacing: Style.space(2)
            visible: Object.keys(root.pending).length > 0
  
            PanelSectionHeader { text: "PENDING CHANGES" }
  
            Repeater {
              model: Object.keys(root.pending)
              delegate: Text {
                required property string modelData
                textFormat: Text.PlainText
                text: modelData + " = " + root.pending[modelData]
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
  
          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            visible: root.errorText !== ""
            text: "⚠ " + root.errorText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
  
          Row {
            spacing: Style.space(10)
            Button { text: "Cancel"; bordered: true; onClicked: root.close() }
            Button {
              text: "Apply"
              bordered: true
              enabled: Object.keys(root.pending).length > 0
              onClicked: root.apply()
            }
          }
        }
      }
    }
  }
}
