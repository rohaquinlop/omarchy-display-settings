# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

An [Omarchy](https://omarchy.org) plugin (`rohaquinlop.display-settings`) that replaces the stock
`omarchy.monitor` bar widget. It manages Hyprland monitor settings (resolution, refresh rate,
scale, arrangement, primary display, and the rest of `HL.MonitorSpec`) and persists them as
readable `hl.monitor()` rules in the user's own `~/.config/hypr/monitors.lua` — not in a sidecar
config file. See README.md for the full feature list and rationale.

## Architecture

Two layers, split deliberately so the risky logic is testable without a compositor:

- **`bin/display_settings.py`** — the engine. stdlib-only (no packages installed). Owns *all*
  mode/scale parsing, PPI/density advice, Lua rendering, validation, `monitors.lua` read/write
  (atomic, diff-stable, symlink-safe, imports hand-written rules), and the apply/verify/revert
  state machine (a 15-second revert armed via a transient `systemd --user` timer, not a QML
  timer, so it survives the shell dying). Invoked as a CLI via `bin/omarchy-display-settings`
  (a thin shell shim so the documented path stays stable) with subcommands `read`, `advise`,
  `apply <layout>`, `persist <layout>`, `confirm`, `revert [--pending PATH]`. Each subcommand
  prints one JSON object to stdout (`{"ok": false, "error": ...}` on failure, exit 1).
- **QML (`Panel.qml`, `Advanced.qml`, `Arrange.qml`, `Confirm.qml`)** — presentation only. Talks
  to the engine exclusively through `Quickshell.Io.Process` (payloads go on argv, never stdin —
  stdin blocks the engine). `Model.js` (`.pragma library`) holds *pure* helpers only, for live UI
  feedback while dragging/stepping through options (mode string parsing, logical-pixel sizing for
  the arrangement canvas, scale formatting) — it deliberately duplicates nothing the engine
  already validates; the engine is the single source of truth for anything that touches
  `monitors.lua` or `hyprctl`.
- **`manifest.json`** — the Omarchy plugin manifest. `entryPoints.barWidget` is `Panel.qml`;
  `omarchy.clonedFrom: omarchy.monitor` is what lets this plugin take over the stock widget's bar
  slot and its `SUPER + CTRL + D` keybinding.

### QML component resolution — a real Quickshell footgun

QML files in this plugin's own directory (`Panel.qml`, `Advanced.qml`, `Arrange.qml`,
`Confirm.qml`, `FixedDropdown.qml`, ...) are available as bare types to each other automatically
(standard QML same-directory resolution) — this is how `Panel.qml` uses `Advanced { ... }`,
`Confirm { ... }`, etc. with no import.

**But this does *not* apply when the filename collides with a name already brought in by
`import qs.Ui`.** Omarchy plugins are sandboxed against silently shadowing a shared `qs.Ui`
primitive by filename: a local `Dropdown.qml` sitting next to `Panel.qml` is **never parsed** —
`Dropdown { ... }` still resolves to the shell's own `/usr/share/omarchy/shell/Ui/Dropdown.qml`,
with no error, warning, or log line to say so. If you need to vendor a locally-patched copy of a
`qs.Ui` component, give it a **non-colliding filename** (see `FixedDropdown.qml`) and update every
call site to reference that name explicitly. To verify a local override is actually being loaded
(rather than assuming standard QML shadowing rules apply), deliberately break its syntax, restart
the shell, and confirm a load error actually appears in the journal (see Debugging below) — a
silent "still works" is proof it was never parsed at all.

### Key handling inside a panel

A panel's own Escape-to-close handler must be an **ancestor** of everything that can take keyboard
focus inside it (dropdowns, text fields, ...), not a sibling — otherwise an unhandled key from a
focused descendant bubbles up *that descendant's own* ancestor chain and never reaches a sibling
handler. `Panel.qml`'s `PanelKeyCatcher` wraps its `ScrollView` for exactly this reason;
`Advanced.qml`'s own Escape handler must do the same (wrap the `ScrollView`, not sit beside it).

### Two separate popup/panel surfaces

`Panel.qml` (the bar widget) uses the shared `KeyboardPanel` + `PanelKeyCatcher` + `focusTarget`
pattern. `Advanced.qml` is a standalone `PanelWindow` (its own Wayland layer-shell surface,
`WlrKeyboardFocus.Exclusive` while open) with its own hand-rolled Escape handling — it does not
go through `KeyboardPanel`. Don't assume a fix in one automatically applies to the other.

## Commands

```bash
python3 -m unittest discover tests -v   # engine tests (119+), no compositor needed
node tests/model.test.js                # Model.js geometry/formatting checks
./tests/qmllint.sh                      # QML lint against the accepted warning baseline
omarchy plugin validate .               # manifest schema/entry-point/symlink checks
```

Run a single Python test: `python3 -m unittest tests.test_display_settings.ClassName.test_name -v`

`tests/qmllint.sh` needs the Qt6 `qmllint` (Arch ships Qt5's under `/usr/bin/qmllint`, which exits
255 on Qt6 QML — the real one is `/usr/lib/qt6/bin/qmllint`) and builds a `qs -> $OMARCHY_SHELL_DIR`
symlink shim so `qs.Ui`/`qs.Commons` imports resolve; override the shell location with
`OMARCHY_SHELL_DIR` if it's not at the default `/usr/share/omarchy/shell`. It only lints `*.qml`
files at the repo root (not the shell's own files), and fails only on warning categories outside
the accepted baseline (`missing-property`, `unqualified`, `uncreatable-type`,
`signal-handler-parameters` are expected noise from `qmllint`'s limited type info for this shell).

CI (`.github/workflows/ci.yml`) runs the Python tests, `model.test.js`, a manifest-schema check
(mirroring `omarchy plugin validate` since that tool isn't available in CI), and a QML
syntax-only check (full lint needs the shell, which CI doesn't have).

## Local development / manual verification

QML changes cannot be verified by any of the above alone — they need the real Omarchy shell
running. This plugin, once installed, lives at
`~/.config/omarchy/plugins/rohaquinlop.display-settings/`, a **separate copy** from a git
checkout elsewhere — changes made in a repo checkout must be copied there before they take effect.

**A code change is not proven working until the shell has been restarted with
`omarchy-restart-shell`.** Quickshell's own hot-reload (`Local plugin changed, reloading: <id>` in
the log) recompiles the component but does not reliably replace a bar widget instance already
sitting in the bar — it can keep running the QML it loaded at construction time, silently, with no
indication anything is stale. Trust a fix only after a real restart.

**Debugging what actually loaded:** the shell logs to the journal under the `omarchy-shell` tag —
`journalctl -t omarchy-shell --since "-5 min"`. Look for `WARN`/`Error` lines naming this plugin's
files, or the absence of an expected error when testing whether a file is even being parsed (see
the QML component resolution footgun above).

## Design constraints (from README, load-bearing)

- **Never trade resolution for size.** Resolution is the sharpness ceiling; scale is apparent
  size. The advisor recommends a scale, never a lower resolution, and only warns (never blocks) on
  a non-native mode.
- **`monitors.lua` writes are diff-stable and non-destructive**: fixed field order, outputs sorted
  by name, no timestamps, atomic write with a one-time backup, symlink target rewritten (link left
  alone), and hand-written `hl.monitor` rules are imported into the managed block rather than
  overwritten (originals commented out with a pointer).
- **Rules are always written complete** — Hyprland's `CMonitorRuleManager::add()` replaces the
  whole rule per output rather than merging, so a partial rule would silently fall back to
  Hyprland's defaults for the omitted fields.
- **A stale/disconnected primary must never block unrelated changes** — only explicitly *choosing*
  a disconnected display as primary is rejected; everything else applies normally regardless of
  whether the stored primary is still connected.
- **Verification, not blind trust**: applies go through `hyprctl eval` (Hyprland's Lua monitor
  API) and are verified against live state before being written — the legacy
  `hyprctl keyword monitor` path can report success without actually changing anything.
