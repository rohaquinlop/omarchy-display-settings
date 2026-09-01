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

// Snap a dragged tile so its edges sit flush against a neighbour. Hyprland
// tolerates gaps and overlaps; people almost never want either.
function snap(tile, others, threshold) {
  var x = tile.x
  var y = tile.y
  for (var i = 0; i < others.length; i++) {
    var other = others[i]
    if (other.name === tile.name) continue
    var candidatesX = [other.x + other.width, other.x - tile.width, other.x]
    var candidatesY = [other.y + other.height, other.y - tile.height, other.y]
    for (var a = 0; a < candidatesX.length; a++)
      if (Math.abs(x - candidatesX[a]) <= threshold) { x = candidatesX[a]; break }
    for (var b = 0; b < candidatesY.length; b++)
      if (Math.abs(y - candidatesY[b]) <= threshold) { y = candidatesY[b]; break }
  }
  return { x: Math.round(x), y: Math.round(y) }
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
