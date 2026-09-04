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
  // Hyprland has no primary flag; the engine composes it from
  // cursor:default_monitor plus the home of workspace 1.
  property string primaryName: ""
  // False when primaryName names a display that is no longer connected --
  // Hyprland never clears cursor:default_monitor on disconnect, so this is
  // the only way to tell "no primary" apart from "a stale one".
  property bool primaryConnected: false
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
    root.readStockRows()
    if (readProc.running) return
    readProc.running = true
  }

  // Brightness and text size come from Omarchy's own commands. They used to be
  // fetched only by a repeating timer, which does not fire until its first
  // interval has elapsed — so the brightness row stayed hidden and the text
  // size slider sat on its default for five seconds after every open.
  function readStockRows() {
    if (!stateProc.running) stateProc.running = true
    if (!textSizeProc.running) textSizeProc.running = true
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
    // A resolution or scale change on `name` can change its logical
    // footprint. Left alone, a neighbor that was sitting flush against it
    // either now overlaps it (footprint grew) or is left with a gap
    // (footprint shrank) -- and the apply gets rejected as an overlap for an
    // edit the user never touched. Reflow the current positions first, in
    // logical space, using the edited display's old and new footprint; every
    // other field on every other display is left exactly as it is.
    var edited = null
    for (var i = 0; i < root.outputs.length; i++)
      if (root.outputs[i].name === name) { edited = root.outputs[i]; break }

    var tiles = root.outputs.map(function(display) {
      var size = Model.logicalSize(display.mode, display.scale, display.transform)
      return {
        name: display.name, x: display.x, y: display.y,
        width: size.width, height: size.height,
        disabled: display.disabled, mirror: display.mirror
      }
    })

    var positions = tiles
    if (edited) {
      var oldSize = Model.logicalSize(edited.mode, edited.scale, edited.transform)
      var newMode = changes.mode !== undefined ? changes.mode : edited.mode
      var newScale = changes.scale !== undefined ? changes.scale : edited.scale
      var newTransform = changes.transform !== undefined ? changes.transform : edited.transform
      var newSize = Model.logicalSize(newMode, newScale, newTransform)
      positions = Model.reflowAfterResize(
        tiles, name, oldSize.width, oldSize.height, newSize.width, newSize.height)
    }

    var layout = []
    for (var j = 0; j < root.outputs.length; j++) {
      var display2 = root.outputs[j]
      var position = positions.filter(function(t) { return t.name === display2.name })[0]
      var rule = {
        output: display2.name,
        mode: display2.mode || "preferred",
        position: Math.round(position.x) + "x" + Math.round(position.y),
        scale: display2.scale,
        transform: display2.transform
      }
      if (display2.mirror) rule.mirror = display2.mirror
      if (display2.disabled) rule.disabled = true
      if (display2.name === name)
        for (var key in changes) rule[key] = changes[key]
      layout.push(rule)
    }
    return layout
  }

  function preview(layout, primary) {
    if (root.busy || applyProc.running) return
    root.busy = true
    root.lastError = ""
    // The payload rides on argv, not stdin. Over stdin the engine blocks in
    // json.load until the pipe closes, and a missed close would leave `busy`
    // latched true — silently swallowing every later click.
    applyProc.command = [root.engine, "apply",
      JSON.stringify(Model.buildApplyPayload(layout, primary))]
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

    var changes = { disabled: !display.disabled }
    if (display.disabled) {
      // Turning one back on. A disabled output reports 0x0 and no modes, so
      // reusing its reported position drops it on top of whatever is already
      // there and validation rejects the whole apply — the display simply
      // refuses to come back with no explanation. Let Hyprland place it, and
      // the next read reports the concrete position it chose.
      changes.position = "auto"
      changes.mode = "preferred"
    }
    root.preview(root.layoutWith(display.name, changes))
  }

  function setPrimary(name) {
    if (name === root.primaryName) return
    root.preview(root.layoutWith("", {}), name)
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
          root.primaryName = String(parsed.primary || "")
          root.primaryConnected = Boolean(parsed.primaryConnected)
          // A revert armed by an earlier preview keeps running whether or not
          // this panel is open. Pick the countdown back up rather than let the
          // display change back with no explanation on screen.
          var remaining = Number(parsed.pendingSeconds || 0)
          if (remaining > 0) {
            root.previewing = true
            root.secondsRemaining = remaining
            if (!countdown.running) countdown.restart()
          } else if (!applyProc.running) {
            root.previewing = false
            countdown.stop()
          }
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
    command: []

    // Always clear `busy`, whatever happened. If the engine dies without
    // producing parseable output, the panel must still accept the next click.
    onExited: function(exitCode) {
      root.busy = false
      if (exitCode !== 0 && root.lastError === "")
        root.lastError = "the display engine exited with code " + exitCode
    }

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.busy = false
        // Distinguish "no parseable output at all" (the process likely died
        // before printing anything) from "parsed fine, and it says ok:false".
        // Only the latter should produce a generic fallback message -- the
        // former already has a more specific one from onExited, and letting
        // this handler stomp it with "could not apply that change" was the
        // bug: whichever handler happened to run last silently won.
        var result = null
        try { result = JSON.parse(String(text || "")) } catch (error) { result = null }
        if (result && result.ok) {
          root.previewing = true
          root.secondsRemaining = result.secondsRemaining || 15
          countdown.restart()
        } else {
          root.previewing = false
          if (result !== null) root.lastError = Model.describeEngineResult(result).error
        }
        root.refresh()
      }
    }
  }

  Process {
    id: confirmProc
    command: [root.engine, "confirm"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // A failed write (permission denied, disk full, a broken symlink
        // target) used to be silently swallowed here: the revert safety net
        // is already cancelled by the time confirm attempts the write, so a
        // failure with no visible error left the user believing nothing was
        // wrong while nothing had actually been saved.
        var result = null
        try { result = JSON.parse(String(text || "")) } catch (error) { result = null }
        var described = Model.describeEngineResult(result)
        root.lastError = described.ok ? "" : described.error
        root.refresh()
      }
    }
  }

  Process {
    id: revertProc
    command: [root.engine, "revert"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var result = null
        try { result = JSON.parse(String(text || "")) } catch (error) { result = null }
        var described = Model.describeEngineResult(result)
        root.lastError = described.ok ? "" : described.error
        root.refresh()
      }
    }
  }

  Process {
    id: actionProc
    command: []
  }

  Process {
    id: textSizeProc
    command: ["omarchy-display-text-size"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // "text size: 12 px", or "text size: 12 (default) px" when unset.
        var match = String(text || "").match(/text size:\s*(\d+)/)
        if (match) root.textSizePx = parseInt(match[1], 10)
      }
    }
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
    triggeredOnStart: true
    onTriggered: root.readStockRows()
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
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(820))

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

          // ---------- preview status ----------
          //
          // The Keep/Revert decision itself lives in the floating Confirm
          // dialog (see the Loader near the end of this file), which shows up
          // on its own the moment a preview is armed -- the 15-second window
          // is easy to miss if the only way to see or act on it were to have
          // this popup open. This is a status line only, for someone who
          // happens to have it open at the time.
          Row {
            width: parent.width
            spacing: Style.space(6)
            visible: root.previewing

            Text {
              textFormat: Text.PlainText
              text: "Previewing — reverting in " + root.secondsRemaining + "s unless kept"
              color: root.bar ? root.bar.foreground : Color.foreground
              opacity: 0.75
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
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

            FixedDropdown {
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

            FixedDropdown {
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

            FixedDropdown {
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

          // ---------- primary display ----------
          //
          // Normally moot with one display -- there's nothing to choose
          // between -- so the section stays hidden then. But a primary
          // display can disconnect and leave exactly one output behind with
          // a primary that no longer matches anything: Hyprland never clears
          // cursor:default_monitor on disconnect. The section reappears in
          // exactly that case so there is still a way to fix it.
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.outputs.length > 1
              || (root.primaryName !== "" && !root.primaryConnected)

            PanelSectionHeader { text: "PRIMARY DISPLAY" }

            FixedDropdown {
              width: parent.width
              showLabel: false
              value: root.primaryName
              options: root.outputs.map(function(display) {
                return { value: display.name, label: display.name }
              })
              onChanged: function(value) { root.setPrimary(value) }
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              visible: root.primaryName !== "" && !root.primaryConnected
              text: "⚠ " + root.primaryName + " is disconnected — pick a new primary."
              color: root.bar ? root.bar.foreground : Color.foreground
              opacity: 0.75
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              visible: !(root.primaryName !== "" && !root.primaryConnected)
              text: "The pointer starts here, and workspace 1 lives here."
              color: root.bar ? root.bar.foreground : Color.foreground
              opacity: 0.55
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          // ---------- displays ----------
          //
          // The row selects; only the power icon turns a display off. Making the
          // whole row a toggle meant a misclick while picking which display to
          // configure blanked a screen instead — destructive, and on the exact
          // target you reach for most often.
          Column {
            width: parent.width
            spacing: Style.space(4)

            PanelSectionHeader { text: "DISPLAYS" }

            Repeater {
              model: root.outputs
              delegate: Rectangle {
                id: displayRow
                required property var modelData
                width: column.width
                implicitHeight: Style.space(28)
                radius: Style.cornerRadius
                color: root.selectedName === modelData.name
                  ? Qt.rgba(root.bar ? root.bar.foreground.r : 1,
                            root.bar ? root.bar.foreground.g : 1,
                            root.bar ? root.bar.foreground.b : 1, 0.07)
                  : "transparent"

                MouseArea {
                  anchors.left: parent.left
                  anchors.top: parent.top
                  anchors.bottom: parent.bottom
                  anchors.right: rowActions.left
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.selectedName = displayRow.modelData.name
                }

                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: "󰍹  " + displayRow.modelData.name
                    + (displayRow.modelData.managedElsewhere ? "  · managed elsewhere" : "")
                    + (displayRow.modelData.disabled ? "  · off" : "")
                  color: root.bar ? root.bar.foreground : Color.foreground
                  opacity: displayRow.modelData.disabled ? 0.45 : 1.0
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.body
                }

                Row {
                  id: rowActions
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(12)

                  // Set primary. Visible under the same condition as the
                  // PRIMARY DISPLAY section above: normally only with more
                  // than one display, but also for the one remaining display
                  // when the stored primary is stale (see that section).
                  Text {
                    textFormat: Text.PlainText
                    visible: (root.outputs.length > 1
                        || (root.primaryName !== "" && !root.primaryConnected))
                      && !displayRow.modelData.disabled
                    text: root.primaryName === displayRow.modelData.name ? "★" : "☆"
                    color: root.bar ? root.bar.foreground : Color.foreground
                    opacity: root.primaryName === displayRow.modelData.name ? 1.0 : 0.35
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.body
                    anchors.verticalCenter: parent.verticalCenter

                    MouseArea {
                      anchors.fill: parent
                      anchors.margins: -Style.space(5)
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.setPrimary(displayRow.modelData.name)
                    }
                  }

                  // Turn the display on or off. Deliberately its own small
                  // target, and inert for the last display left on.
                  Text {
                    textFormat: Text.PlainText
                    text: "⏻"
                    color: root.bar ? root.bar.foreground : Color.foreground
                    opacity: {
                      if (!displayRow.modelData.disabled && root.enabledCount <= 1) return 0.2
                      return displayRow.modelData.disabled ? 0.35 : 0.9
                    }
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.body
                    anchors.verticalCenter: parent.verticalCenter

                    MouseArea {
                      anchors.fill: parent
                      anchors.margins: -Style.space(5)
                      enabled: displayRow.modelData.disabled || root.enabledCount > 1
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.toggleDisplay(displayRow.modelData)
                    }
                  }
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
                { arrangeLoader.active = true; arrangeLoader.item.show(root.outputs) }
              }
            }

            Button {
              width: parent.width
              leftAlign: true
              bordered: true
              text: "Advanced…"
              onClicked: { advancedLoader.active = true; advancedLoader.item.open() }
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

  // A bar widget is instantiated once per monitor, and a PanelWindow declared
  // directly inside one stops the widget rendering at all — no error in any
  // log, just an empty bar slot. No first-party bar widget declares one; the
  // fullscreen overlays all live in separate panel-kind plugins. Both surfaces
  // are therefore built on first use.
  Loader {
    id: advancedLoader
    active: false
    sourceComponent: Advanced {
      bar: root.bar
      display: root.selected
      // Discard the instance on close so the next open builds it fresh from
      // whatever is on disk. Keeping it alive made plugin reloads invisible.
      onClosed: Qt.callLater(function() { advancedLoader.active = false })
      onApplyRequested: function(changes) {
        root.preview(root.layoutWith(root.selectedName, changes))
      }
    }
  }

  Loader {
    id: arrangeLoader
    active: false
    sourceComponent: Arrange {
      bar: root.bar
      primaryName: root.primaryName
      onClosed: Qt.callLater(function() { arrangeLoader.active = false })
      previewing: root.previewing
      secondsRemaining: root.secondsRemaining
      onApplyRequested: function(layout) { root.preview(layout) }
      onKeepRequested: root.keepChanges()
      onRevertRequested: root.revertChanges()
    }
  }

  // The floating "keep these settings?" dialog, active only while a preview
  // is pending. Bound to `previewing` rather than opened by a click, so it
  // appears on its own the moment a change is applied -- whether or not this
  // panel is open -- and disappears the moment it is confirmed, reverted, or
  // times out. This is the one place the decision actually needs to be
  // visible: 15 seconds is short, and requiring the bar popup to be open to
  // see or act on it is the gap this exists to close.
  Loader {
    id: confirmLoader
    active: root.previewing
    sourceComponent: Confirm {
      bar: root.bar
      previewing: root.previewing
      secondsRemaining: root.secondsRemaining
      onKeepRequested: root.keepChanges()
      onRevertRequested: root.revertChanges()
    }
  }
}
