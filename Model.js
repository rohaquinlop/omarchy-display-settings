.pragma library

// Pure helpers the UI needs for live feedback while the user drags or steps
// through options. Everything else — mode parsing, scale legality, density,
// validation, Lua — lives in bin/display_settings.py, which is the single
// implementation and the one under test. Nothing here writes anything.

function parseMode(mode) {
  var match = String(mode || "").match(/^(\d+)x(\d+)@(\d+(?:\.\d+)?)/)
  if (!match) return null
  return { width: Number(match[1]), height: Number(match[2]), refresh: Number(match[3]) }
}

function resolutionOf(mode) {
  var parts = parseMode(mode)
  return parts ? parts.width + "x" + parts.height : ""
}

function refreshOf(mode) {
  var parts = parseMode(mode)
  return parts ? parts.refresh.toFixed(2) : ""
}

function modeFor(resolution, refresh) {
  return resolution + "@" + refresh
}

// Hyprland positions monitors in logical pixels: a 2560x1440 panel at scale
// 1.25 occupies 2048x1152. An odd transform turns it a quarter turn. The
// arrangement canvas draws in this space, not in physical pixels.
function logicalSize(mode, scale, transform) {
  var parts = parseMode(mode)
  if (!parts) return { width: 0, height: 0 }
  var factor = Number(scale) > 0 ? Number(scale) : 1
  var width = parts.width
  var height = parts.height
  if (Number(transform) % 2 === 1) {
    var swap = width
    width = height
    height = swap
  }
  return { width: Math.round(width / factor), height: Math.round(height / factor) }
}

function effectivePpi(ppi, scale) {
  if (ppi === null || ppi === undefined) return null
  var factor = Number(scale) > 0 ? Number(scale) : 1
  return Math.round((Number(ppi) / factor) * 10) / 10
}

function inBand(effective, band) {
  if (effective === null || effective === undefined || !band) return false
  return effective >= band[0] && effective <= band[1]
}

// Wording for the readout under the scale row. Says what is true, and in which
// direction it is off — never scolds, never changes anything.
function densityNote(effective, band) {
  if (effective === null || effective === undefined) return ""
  if (!band) return ""
  if (effective < band[0]) return "larger than typical"
  if (effective > band[1]) return "smaller than typical"
  return "comfortable"
}

function formatScale(value) {
  var number = Number(value)
  if (!isFinite(number)) return String(value)
  return String(Math.round(number * 100) / 100)
}

function boundingBox(tiles) {
  if (!tiles || !tiles.length) return { x: 0, y: 0, width: 0, height: 0 }
  var minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity
  for (var i = 0; i < tiles.length; i++) {
    var t = tiles[i]
    minX = Math.min(minX, t.x)
    minY = Math.min(minY, t.y)
    maxX = Math.max(maxX, t.x + t.width)
    maxY = Math.max(maxY, t.y + t.height)
  }
  return { x: minX, y: minY, width: maxX - minX, height: maxY - minY }
}

// Displays must stay touching. A gap is dead space the pointer cannot cross,
// and Hyprland will persist one without complaint, so threshold-based snapping
// is the wrong model: drop a display far enough from its neighbour and the gap
// simply survives. Instead the dragged display is always attached flush to an
// edge of its nearest neighbour, at whichever placement is closest to where it
// was actually dropped. Gaps and overlaps both become unrepresentable.

// Minimum shared edge, as a fraction of the smaller side. Below this two
// displays touch only at a corner, which is contact in name only.
var MIN_SHARE = 0.2

function clamp(value, low, high) {
  return Math.max(low, Math.min(high, value))
}

// Slide `value` along the shared edge, keeping a usable overlap, then prefer a
// clean alignment when the drop was already close to one.
function alongEdge(value, size, otherStart, otherSize, alignThreshold) {
  var share = Math.min(size, otherSize) * MIN_SHARE
  var placed = clamp(value, otherStart - size + share, otherStart + otherSize - share)
  var alignments = [
    otherStart,                                  // leading edges flush
    otherStart + otherSize - size,               // trailing edges flush
    otherStart + (otherSize - size) / 2          // centred
  ]
  for (var i = 0; i < alignments.length; i++) {
    if (Math.abs(placed - alignments[i]) <= alignThreshold) return alignments[i]
  }
  return placed
}

function attach(tile, others, alignThreshold) {
  var neighbours = []
  for (var n = 0; n < others.length; n++) {
    var candidate = others[n]
    if (candidate.name === tile.name || candidate.disabled || candidate.mirror) continue
    neighbours.push(candidate)
  }
  if (!neighbours.length) return { x: Math.round(tile.x), y: Math.round(tile.y) }

  var places = []
  for (var i = 0; i < neighbours.length; i++) {
    var other = neighbours[i]
    var y = alongEdge(tile.y, tile.height, other.y, other.height, alignThreshold)
    var x = alongEdge(tile.x, tile.width, other.x, other.width, alignThreshold)
    places.push({ x: other.x + other.width, y: y })   // to its right
    places.push({ x: other.x - tile.width, y: y })    // to its left
    places.push({ x: x, y: other.y + other.height })  // below it
    places.push({ x: x, y: other.y - tile.height })   // above it
  }

  var best = null
  for (var p = 0; p < places.length; p++) {
    var probe = {
      name: tile.name, x: places[p].x, y: places[p].y,
      width: tile.width, height: tile.height
    }
    var clashes = false
    for (var q = 0; q < neighbours.length; q++) {
      if (overlaps(probe, neighbours[q])) { clashes = true; break }
    }
    if (clashes) continue
    var dx = places[p].x - tile.x
    var dy = places[p].y - tile.y
    var distance = dx * dx + dy * dy
    if (!best || distance < best.distance) best = { x: places[p].x, y: places[p].y, distance: distance }
  }

  // Every attachment overlapped something; leave the drop where it landed and
  // let validation report it rather than silently placing it somewhere else.
  if (!best) return { x: Math.round(tile.x), y: Math.round(tile.y) }
  return { x: Math.round(best.x), y: Math.round(best.y) }
}

// Changing one display's mode/scale changes its logical footprint, and
// nothing else in the layout knows to move. A display that was sitting flush
// against its right edge is now either overlapped (footprint grew) or
// separated by a gap (footprint shrank). Reflow shifts every other enabled,
// non-mirrored tile that was positioned at or beyond the resized tile's old
// edge, by the same delta, along each axis independently -- so a row (or
// column) of displays keeps its flush arrangement across a scale or
// resolution change instead of the user hitting an "overlap" rejection for a
// change they didn't make.
function reflowAfterResize(tiles, name, oldWidth, oldHeight, newWidth, newHeight) {
  var anchor = null
  for (var i = 0; i < tiles.length; i++) {
    if (tiles[i].name === name) { anchor = tiles[i]; break }
  }
  if (!anchor) return tiles.slice()

  var deltaW = newWidth - oldWidth
  var deltaH = newHeight - oldHeight
  if (deltaW === 0 && deltaH === 0) return tiles.slice()

  var oldRight = anchor.x + oldWidth
  var oldBottom = anchor.y + oldHeight

  return tiles.map(function(tile) {
    if (tile.name === name || tile.disabled || tile.mirror) return tile
    var copy = Object.assign({}, tile)
    if (deltaW !== 0 && tile.x >= oldRight) copy.x = tile.x + deltaW
    if (deltaH !== 0 && tile.y >= oldBottom) copy.y = tile.y + deltaH
    return copy
  })
}

function overlaps(a, b) {
  return a.x < b.x + b.width && a.x + a.width > b.x
      && a.y < b.y + b.height && a.y + a.height > b.y
}

function anyOverlap(tiles) {
  for (var i = 0; i < tiles.length; i++)
    for (var j = i + 1; j < tiles.length; j++)
      if (!tiles[i].disabled && !tiles[j].disabled && overlaps(tiles[i], tiles[j])) return true
  return false
}

// What an apply payload contains. `primary` is included only when the caller
// is actually asking to set one -- never a fallback to "whatever the current
// primary is". Hyprland never clears cursor:default_monitor when a display
// disconnects, so a payload that resent that stale name on every unrelated
// change (a scale tweak, a toggle, ...) got the whole apply rejected once the
// primary display was gone.
function buildApplyPayload(layout, primary) {
  return { layout: layout, primary: primary || "" }
}

// How the engine's JSON result (or lack of one) maps to UI state, shared by
// every Process that calls the engine (apply, confirm, revert) instead of
// three slightly different inline handlers. `resultJson` is the parsed
// result, or null/undefined when the process produced no parseable output at
// all -- the caller decides what to do with that case, since only it knows
// whether a more specific error (e.g. a nonzero exit code) is already shown.
function describeEngineResult(resultJson) {
  var result = resultJson || {}
  if (result.ok) return { ok: true, error: "" }
  var problems = result.problems || []
  if (problems.length) return { ok: false, error: String(problems[0]) }
  if (result.error) return { ok: false, error: String(result.error) }
  return { ok: false, error: "could not apply that change" }
}
