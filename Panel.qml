import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

// Bar widget for rohaquinlop.display-settings. Replaces Omarchy's stock
// omarchy.monitor widget (see omarchy.clonedFrom in manifest.json), so it
// carries the stock brightness, text-size, and scale rows and adds resolution,
// refresh rate, density, arrangement, and the advanced monitor surface.
//
// The stock rows call the same Omarchy commands the built-in panel calls
// rather than reimplementing them; everything else goes through
// bin/omarchy-display-settings, which owns all parsing, validation, and writing.
Panel {
  id: root
  moduleName: "rohaquinlop.display-settings"
  ipcTarget: "rohaquinlop.display-settings"

  readonly property string engine: Quickshell.env("HOME")
    + "/.config/omarchy/plugins/rohaquinlop.display-settings/bin/omarchy-display-settings"

  // Ui/Panel is a bare Item with no implicit size, so a bar widget must take
  // its dimensions from its own button. Without these the widget loads without
  // error and renders 0x0 — it simply vanishes from the bar.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  property var outputs: []
  property var configInfo: ({})
  property string selectedName: ""
  property bool busy: false
  property string lastError: ""

  // Preview lifecycle. The countdown is only a display of what the backend has
  // already armed with systemd — the timer that actually reverts lives outside
  // this process, so it still fires if the shell dies.
  property bool previewing: false
  property int secondsRemaining: 0

  property int brightnessPercent: 0
  property bool brightnessAvailable: false
  property int textSizePx: 12

  readonly property var selected: {
    for (var i = 0; i < outputs.length; i++)
      if (outputs[i].name === selectedName) return outputs[i]
    return outputs.length > 0 ? outputs[0] : null
  }

  readonly property int enabledCount: {
    var count = 0
    for (var i = 0; i < outputs.length; i++) if (!outputs[i].disabled) count++
    return count
  }

  function refresh() {
    if (readProc.running) return
    readProc.running = true
  }

  function selectedResolution() {
    return root.selected ? Model.resolutionOf(root.selected.mode) : ""
  }

  function refreshOptions() {
    if (!root.selected) return []
    var rates = root.selected.refreshFor[root.selectedResolution()] || []
    return rates.map(function(rate) { return { value: rate, label: rate + " Hz" } })
  }

  function resolutionOptions() {
    if (!root.selected) return []
    var native = root.selected.nativeResolution
    return root.selected.resolutions.map(function(value) {
      return { value: value, label: value === native ? value + "  (native)" : value }
    })
  }

  function isNonNative() {
    return root.selected && root.selected.nativeResolution
      && root.selectedResolution() !== root.selected.nativeResolution
  }

  // Build the full layout from live state, overriding one output's fields.
  // Rules must be complete: Hyprland replaces a same-named rule rather than
  // merging with it, so a field left out would fall back to its default.
  function layoutWith(name, changes) {
    var layout = []
    for (var i = 0; i < root.outputs.length; i++) {
      var display = root.outputs[i]
      var rule = {
        output: display.name,
        mode: display.mode || "preferred",
        position: display.position,
        scale: display.scale,
        transform: display.transform
      }
      if (display.mirror) rule.mirror = display.mirror
      if (display.disabled) rule.disabled = true
      if (display.name === name)
        for (var key in changes) rule[key] = changes[key]
      layout.push(rule)
    }
    return layout
  }

  function preview(layout) {
    if (root.busy) return
    root.busy = true
    root.lastError = ""
    applyProc.payload = JSON.stringify({ layout: layout })
    applyProc.running = true
  }

  function setResolution(value) {
    var rates = root.selected.refreshFor[value] || []
    if (!rates.length) return
    root.preview(root.layoutWith(root.selectedName, { mode: Model.modeFor(value, rates[0]) }))
  }

  function setRefresh(value) {
    root.preview(root.layoutWith(root.selectedName,
      { mode: Model.modeFor(root.selectedResolution(), value) }))
  }

  function setScale(value) {
    root.preview(root.layoutWith(root.selectedName, { scale: Number(value) }))
  }

  function toggleDisplay(display) {
    // Refuse to turn off the last display rather than let the backend reject it.
    if (!display.disabled && root.enabledCount <= 1) return
    root.preview(root.layoutWith(display.name, { disabled: !display.disabled }))
  }

  function keepChanges() {
    countdown.stop()
    root.previewing = false
    confirmProc.running = true
  }

  function revertChanges() {
    countdown.stop()
    root.previewing = false
    revertProc.running = true
  }

  Component.onCompleted: root.refresh()
  onOpenedChanged: if (root.opened) root.refresh()

  // ---- backend calls -------------------------------------------------------

  Process {
    id: readProc
    command: [root.engine, "read"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(String(text || "{}"))
          root.outputs = parsed.outputs || []
          root.configInfo = parsed.config || ({})
          if (!root.selectedName && root.outputs.length > 0) {
            for (var i = 0; i < root.outputs.length; i++)
              if (root.outputs[i].focused) root.selectedName = root.outputs[i].name
            if (!root.selectedName) root.selectedName = root.outputs[0].name
          }
        } catch (error) {
          root.lastError = "could not read display state"
        }
      }
    }
  }

  Process {
    id: applyProc
    property string payload: ""
    command: [root.engine, "apply", "-"]
    stdinEnabled: true
    onRunningChanged: {
      if (running && payload !== "") {
        write(payload)
        stdinEnabled = false
      }
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.busy = false
        var result = ({})
        try { result = JSON.parse(String(text || "{}")) } catch (error) { result = ({}) }
        if (result.ok) {
          root.previewing = true
          root.secondsRemaining = result.secondsRemaining || 15
          countdown.restart()
        } else {
          root.previewing = false
          var problems = result.problems || []
          root.lastError = problems.length ? String(problems[0]) : "could not apply that change"
        }
        root.refresh()
      }
    }
  }

  Process {
    id: confirmProc
    command: [root.engine, "confirm"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.refresh() }
  }

  Process {
    id: revertProc
    command: [root.engine, "revert"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.refresh() }
  }

  Process {
    id: actionProc
    command: []
  }

  // ---- stock rows: same commands the built-in Display panel calls ----------

  Process {
    id: stateProc
    command: ["omarchy-monitor-state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").split("\n")
        var brightness = String(lines[0] || "").trim()
        root.brightnessAvailable = brightness !== "unavailable" && brightness !== ""
        root.brightnessPercent = root.brightnessAvailable
          ? Math.max(0, Math.min(100, parseInt(brightness, 10))) : 0
      }
    }
  }

  function setBrightness(percent) {
    var value = Math.max(1, Math.min(100, Math.round(percent)))
    root.brightnessPercent = value
    actionProc.command = ["omarchy-brightness-display", "--no-osd", value + "%"]
    if (!actionProc.running) actionProc.running = true
  }

  function setTextSize(px) {
    root.textSizePx = px
    actionProc.command = ["omarchy-display-text-size", String(px)]
    if (!actionProc.running) actionProc.running = true
  }

  Timer {
    id: countdown
    interval: 1000
    repeat: true
    onTriggered: {
      root.secondsRemaining -= 1
      if (root.secondsRemaining <= 0) {
        stop()
        root.previewing = false
        root.refresh()
      }
    }
  }

  Timer {
    // The panel is the only consumer, so poll only while it is open.
    interval: 5000
    repeat: true
    running: root.opened
    onTriggered: stateProc.running = true
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Quickshell.screens.length > 1 ? "󰍺" : "󰍹"
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: column.implicitHeight > height
          ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

        Column {
          id: column
          width: scrollArea.availableWidth
          spacing: Style.space(12)

          // ---------- hero ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroText.implicitHeight)

            Text {
              id: heroIcon
              textFormat: Text.PlainText
              text: root.outputs.length > 1 ? "󰍺" : "󰍹"
              color: root.bar ? root.bar.foreground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              id: heroText
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                text: "Display"
                color: root.bar ? root.bar.foreground : Color.foreground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.subtitle
              }

              // Density line: physical PPI, panel size, connector class. The
              // facts behind the recommendation, kept quiet.
              Text {
                textFormat: Text.PlainText
                text: {
                  if (!root.selected) return ""
                  if (root.selected.ppi === null) return root.selected.ppiNote || ""
                  var bits = [root.selected.ppi + " PPI"]
                  if (root.selected.diagonalIn) bits.push(root.selected.diagonalIn + "\"")
                  bits.push(root.selected.internal ? "laptop" : "desktop")
                  return bits.join(" · ")
                }
                color: root.bar ? root.bar.foreground : Color.foreground
                opacity: 0.6
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }

          // ---------- preview countdown ----------
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.previewing

            PanelSectionHeader { text: "KEEP THESE SETTINGS?" }

            Text {
              textFormat: Text.PlainText
              text: "Reverting in " + root.secondsRemaining + "s"
              color: root.bar ? root.bar.foreground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
            }

            Row {
              spacing: Style.space(8)
              Button { text: "Keep"; bordered: true; onClicked: root.keepChanges() }
              Button { text: "Revert"; bordered: true; onClicked: root.revertChanges() }
            }
          }

          // ---------- error ----------
          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            visible: root.lastError !== ""
            text: "⚠ " + root.lastError
            color: root.bar ? root.bar.foreground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }

          // ---------- brightness (stock) ----------
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.brightnessAvailable

            PanelSectionHeader { text: "BRIGHTNESS" }

            PanelSlider {
              width: parent.width
              bar: root.bar
              minimum: 1
              maximum: 100
              integer: true
              value: root.brightnessPercent
              onReleased: function(value) { root.setBrightness(value) }
            }
          }

          // ---------- text size (stock) ----------
          Column {
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader { text: "TEXT SIZE" }

            PanelSlider {
              width: parent.width
              bar: root.bar
              minimum: 9
              maximum: 20
              step: 1
              integer: true
              tickCount: 12
              value: root.textSizePx
              onReleased: function(value) { root.setTextSize(Math.round(value)) }
            }
          }

          PanelSeparator { width: parent.width }

          // ---------- display picker ----------
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.outputs.length > 1

            PanelSectionHeader { text: "DISPLAY" }

            Dropdown {
              width: parent.width
              showLabel: false
              value: root.selectedName
              options: root.outputs.map(function(display) {
                return { value: display.name, label: display.name
                  + (display.focused ? "  · focused" : "") }
              })
              onChanged: function(value) { root.selectedName = value }
            }
          }

          // ---------- resolution ----------
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.selected !== null && root.selected.resolutions.length > 0

            PanelSectionHeader { text: "RESOLUTION" }

            // A single advertised resolution is a fact, not a choice.
            Text {
              width: parent.width
              textFormat: Text.PlainText
              visible: root.selected !== null && root.selected.resolutions.length === 1
              text: root.selectedResolution() + "  (native)"
              color: root.bar ? root.bar.foreground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
            }

            Dropdown {
              width: parent.width
              showLabel: false
              visible: root.selected !== null && root.selected.resolutions.length > 1
              value: root.selectedResolution()
              options: root.resolutionOptions()
              onChanged: function(value) { root.setResolution(value) }
            }

            // Resolution sets the sharpness ceiling; scale sets apparent size.
            // They are independent, so there is never a reason to trade one for
            // the other — but the choice stays the user's.
            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              visible: root.isNonNative()
              text: "⚠ Non-native — the panel will interpolate and look soft. "
                + "For a larger interface, keep " + (root.selected ? root.selected.nativeResolution : "")
                + " and raise the scale instead."
              color: root.bar ? root.bar.foreground : Color.foreground
              opacity: 0.75
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          // ---------- refresh rate ----------
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.refreshOptions().length > 1

            PanelSectionHeader { text: "REFRESH RATE" }

            Dropdown {
              width: parent.width
              showLabel: false
              value: root.selected ? Model.refreshOf(root.selected.mode) : ""
              options: root.refreshOptions()
              onChanged: function(value) { root.setRefresh(value) }
            }
          }

          // ---------- scale ----------
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.selected !== null

            PanelSectionHeader { text: "SCALE" }

            Flow {
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.selected ? root.selected.legalScales : []
                delegate: Button {
                  required property string modelData
                  text: modelData + "x"
                    + (root.selected && root.selected.recommendedScale === modelData ? " ★" : "")
                  bordered: true
                  selected: root.selected
                    && Model.formatScale(root.selected.scale) === Model.formatScale(modelData)
                  onClicked: root.setScale(modelData)
                }
              }
            }

            // The number the user is actually changing.
            Text {
              width: parent.width
              textFormat: Text.PlainText
              visible: root.selected !== null && root.selected.effectivePpi !== null
              text: {
                if (!root.selected || root.selected.effectivePpi === null) return ""
                var note = Model.densityNote(root.selected.effectivePpi, root.selected.band)
                return "→ " + root.selected.effectivePpi + " effective PPI"
                  + (note ? "  ·  " + note : "")
              }
              color: root.bar ? root.bar.foreground : Color.foreground
              opacity: root.selected && root.selected.inBand ? 0.6 : 0.9
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          PanelSeparator { width: parent.width }

          // ---------- displays ----------
          Column {
            width: parent.width
            spacing: Style.space(4)

            PanelSectionHeader { text: "DISPLAYS" }

            Repeater {
              model: root.outputs
              delegate: Item {
                required property var modelData
                width: column.width
                implicitHeight: Style.space(26)

                Text {
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: "󰍹  " + modelData.name
                    + (modelData.managedElsewhere ? "  · managed elsewhere" : "")
                  color: root.bar ? root.bar.foreground : Color.foreground
                  opacity: modelData.disabled ? 0.45 : 1.0
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.body
                }

                Text {
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: modelData.disabled ? "" : "󰄬"
                  color: root.bar ? root.bar.foreground : Color.foreground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.body
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.toggleDisplay(modelData)
                }
              }
            }
          }

          PanelSeparator { width: parent.width }

          // ---------- actions ----------
          Column {
            width: parent.width
            spacing: Style.space(6)

            // The canvas is a window this plugin owns, not a declared overlay
            // kind: a plugin that is both bar-widget and overlay hands the
            // summoned surface to the overlay (shell.qml:426), which would make
            // SUPER + CTRL + D open the canvas instead of this panel.
            Button {
              width: parent.width
              leftAlign: true
              bordered: true
              text: "Arrange displays…"
              enabled: root.outputs.length > 1
              onClicked: {
                root.close()
                arrangeCanvas.show(root.outputs)
              }
            }

            Button {
              width: parent.width
              leftAlign: true
              bordered: true
              text: "Advanced…"
              onClicked: advancedSheet.open()
            }

            // Where the settings actually live. The whole point of the plugin,
            // so it is stated rather than hidden.
            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: "Saved to " + (root.configInfo.path || "monitors.lua")
              color: root.bar ? root.bar.foreground : Color.foreground
              opacity: 0.5
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }
  }

  Advanced {
    id: advancedSheet
    bar: root.bar
    display: root.selected
    onApplyRequested: function(changes) {
      root.preview(root.layoutWith(root.selectedName, changes))
    }
  }

  Arrange {
    id: arrangeCanvas
    bar: root.bar
    onApplyRequested: function(layout) { root.preview(layout) }
    onKeepRequested: root.keepChanges()
    onRevertRequested: root.revertChanges()
    previewing: root.previewing
    secondsRemaining: root.secondsRemaining
  }
}
