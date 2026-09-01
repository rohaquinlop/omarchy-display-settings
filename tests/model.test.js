// Tests for Model.js, the UI-side geometry helpers.
// Run: node tests/model.test.js
//
// Model.js is a QML .js library, so it is loaded here by eval after stripping
// the .pragma line. These assert invariants rather than exact coordinates: the
// point of attach() is that gaps and overlaps cannot be represented, not that a
// particular drop lands on a particular pixel.

const fs = require("fs")
const path = require("path")

const source = fs
  .readFileSync(path.join(__dirname, "..", "Model.js"), "utf8")
  .replace(".pragma library", "")
eval(source)

let failures = 0
let checks = 0

function check(condition, description) {
  checks += 1
  if (!condition) {
    failures += 1
    console.error("FAIL: " + description)
  }
}

function equal(actual, expected, description) {
  check(
    JSON.stringify(actual) === JSON.stringify(expected),
    description + " (got " + JSON.stringify(actual) + ", wanted " + JSON.stringify(expected) + ")"
  )
}

// --- geometry basics -------------------------------------------------------

equal(parseMode("2560x1440@59.95Hz"), { width: 2560, height: 1440, refresh: 59.95 }, "parseMode")
equal(resolutionOf("2560x1440@59.95"), "2560x1440", "resolutionOf")
equal(refreshOf("2560x1440@59.95"), "59.95", "refreshOf")

// A 2560x1440 panel at scale 1.25 occupies 2048x1152 logical pixels. Placing
// it as if it were 2560 wide is the classic multi-monitor mistake.
equal(logicalSize("2560x1440@60", 1.25, 0), { width: 2048, height: 1152 }, "logical size divides by scale")
equal(logicalSize("2560x1440@60", 1, 1), { width: 1440, height: 2560 }, "odd transform swaps axes")

equal(effectivePpi(162, 1.25), 129.6, "effective PPI")
check(inBand(130, [120, 140]), "130 is inside the laptop band")
check(!inBand(87, [95, 115]), "87 is below the desktop band")
equal(densityNote(87, [95, 115]), "larger than typical", "below-band wording")
equal(densityNote(130, [120, 140]), "comfortable", "in-band wording")

// --- attach(): the no-gap guarantee ---------------------------------------

const ALIGN = 60

function touches(a, b) {
  const sharesVertical =
    (a.x + a.width === b.x || b.x + b.width === a.x) &&
    Math.min(a.y + a.height, b.y + b.height) - Math.max(a.y, b.y) > 0
  const sharesHorizontal =
    (a.y + a.height === b.y || b.y + b.height === a.y) &&
    Math.min(a.x + a.width, b.x + b.width) - Math.max(a.x, b.x) > 0
  return sharesVertical || sharesHorizontal
}

const anchor = { name: "eDP-1", x: 0, y: 0, width: 1536, height: 960 }

// Drop the second display all over the plane, including far away, on top of
// the anchor, and at every diagonal. None of these may produce a gap.
const drops = [
  [2400, 0], [1600, 30], [-1200, 10], [100, 1100], [80, -700], [700, 300],
  [5000, 5000], [-5000, -5000], [0, 0], [1536, 0], [3000, -2000], [-3000, 2000],
  [768, 480], [1535, 959], [10, -1], [1537, 961],
]

for (const [x, y] of drops) {
  const dragged = { name: "HEADLESS-1", x, y, width: 960, height: 540 }
  const placed = attach(dragged, [anchor, dragged], ALIGN)
  const result = { name: "HEADLESS-1", x: placed.x, y: placed.y, width: 960, height: 540 }

  check(!overlaps(result, anchor), "drop " + [x, y] + " must not overlap")
  check(touches(result, anchor), "drop " + [x, y] + " must stay touching (no gap)")
  check(
    Number.isInteger(placed.x) && Number.isInteger(placed.y),
    "drop " + [x, y] + " must land on whole pixels"
  )
}

// Dropping near a clean alignment prefers that alignment.
{
  const dragged = { name: "HEADLESS-1", x: 1600, y: 25, width: 960, height: 540 }
  const placed = attach(dragged, [anchor, dragged], ALIGN)
  equal(placed, { x: 1536, y: 0 }, "a near-aligned drop lands top-aligned and flush")
}

// Far along the shared edge, it stays flush but keeps the user's offset rather
// than yanking it back to an alignment.
{
  const dragged = { name: "HEADLESS-1", x: 1700, y: 400, width: 960, height: 540 }
  const placed = attach(dragged, [anchor, dragged], ALIGN)
  equal(placed.x, 1536, "still flush against the right edge")
  check(placed.y > 100, "keeps the user's offset along the edge")
}

// A single display has nothing to attach to and must be left alone.
{
  const only = { name: "eDP-1", x: 37, y: 11, width: 1536, height: 960 }
  equal(attach(only, [only], ALIGN), { x: 37, y: 11 }, "a lone display is not moved")
}

// Disabled and mirrored displays are not attachment targets.
{
  const off = { name: "HDMI-A-1", x: 0, y: 0, width: 1920, height: 1080, disabled: true }
  const dragged = { name: "HEADLESS-1", x: 4000, y: 4000, width: 960, height: 540 }
  equal(attach(dragged, [off, dragged], ALIGN), { x: 4000, y: 4000 }, "disabled displays are ignored")
}

// --- overlap detection -----------------------------------------------------

check(anyOverlap([anchor, { name: "b", x: 100, y: 100, width: 500, height: 500 }]), "overlap detected")
check(
  !anyOverlap([anchor, { name: "b", x: 1536, y: 0, width: 960, height: 540 }]),
  "flush neighbours do not count as overlapping"
)

equal(boundingBox([anchor, { name: "b", x: 1536, y: 0, width: 960, height: 540 }]),
  { x: 0, y: 0, width: 2496, height: 960 }, "bounding box spans both displays")

console.log(checks - failures + "/" + checks + " checks passed")
process.exit(failures ? 1 : 0)
