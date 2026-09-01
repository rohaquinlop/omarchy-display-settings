# omarchy-display-settings

Display settings for [Omarchy](https://omarchy.org) that live in **your own
Hyprland config**, not in a sidecar file.

Resolution, refresh rate, monitor arrangement, scale with a real density
advisor, and the rest of Hyprland's monitor surface — written as readable
`hl.monitor()` rules inside `~/.config/hypr/monitors.lua`, where you can read
them, edit them, and commit them.

## Install

```bash
omarchy plugin add https://github.com/rohaquinlop/omarchy-display-settings.git --enable
```

It replaces Omarchy's built-in **Display** widget in the same bar slot, so you
still get one display icon and `SUPER + CTRL + D` still opens it. Removing the
plugin puts the stock widget back exactly where it was.

```bash
omarchy plugin remove rohaquinlop.display-settings
```

## What it does

- **Resolution and refresh rate** per monitor, from the modes Hyprland
  advertises. The native mode is marked.
- **Scale**, restricted to values Hyprland accepts for the chosen mode — the
  same `gcd`-in-1/120 rule `SUPER + /` uses, so the two never disagree.
- **A density advisor.** Real PPI from the panel's EDID, a recommended scale,
  and a live effective-PPI readout. It marks a recommendation and never
  changes anything on its own.
- **Arrangement**, on a drag canvas that works in logical pixels — a 2560×1440
  panel at scale 1.25 occupies 2048×1152, and placing it as if it were 2560
  wide is the single most common way to get a two-monitor layout wrong.
- **Advanced**: `transform`, `vrr`, `mirror`, `bitdepth`, `cm`, `icc`,
  `supports_hdr`, the `sdr*` fields, plus a raw key/value escape hatch for any
  documented `HL.MonitorSpec` field this build has no control for.
- **A 15-second revert.** Every change previews first and rolls back unless you
  confirm.

## Why the config file matters

Your settings end up here, and nowhere else:

```lua
-- >>> omarchy-display-settings (generated) — do not edit inside this block >>>
-- eDP-1 · 1920x1200@60.00 · 14.0" · 162.0 PPI · scale 1.25 → 129.6 effective PPI
hl.monitor({ output = "eDP-1", mode = "1920x1200@60.00", position = "0x0", scale = 1.25 })
-- <<< omarchy-display-settings <<<
```

That block is plain Lua in your own `monitors.lua`. It survives removing the
plugin, it goes into your dotfiles repo with everything else, and it carries a
comment explaining the reasoning — the comment you would have written yourself.

The writer is careful about the things that make config files annoying:

- **Diff-stable.** Fixed field order, outputs sorted by name, no timestamps.
  Re-running with no changes produces an empty `git diff`.
- **Symlink-safe.** If `monitors.lua` is a symlink into your dotfiles, the
  target is rewritten and the link is left alone.
- **Atomic**, with a one-time backup to `monitors.lua.omarchy-display-settings.bak`.
- **It imports what you already wrote.** Hand-written `hl.monitor` rules are
  carried into the block verbatim and the originals are commented out with a
  pointer, so nothing is lost and nothing is silently overridden. Rules that
  use variables or conditionals are left completely alone, and the affected
  display is reported as managed elsewhere.

Rules are always written complete. Hyprland's `CMonitorRuleManager::add()`
erases the previous rule for an output rather than merging with it, so a field
left out would fall back to Hyprland's default rather than your earlier value.

## Never lower resolution to make things bigger

Resolution sets the sharpness ceiling. Scale sets apparent size. They are
independent, so there is no reason to trade one for the other — a lower
resolution costs you real sharpness to buy something scale gives you free. The
plugin runs native and adjusts scale, and warns (without blocking) if you pick
a non-native mode.

The advisor splits its comfort bands by connector — roughly 120–140 effective
PPI for `eDP`/`LVDS`/`DSI` panels and 95–115 for external ones. The reason is
viewing distance: a 162 PPI laptop panel and a 109 PPI 27" monitor land within
a few pixels-per-degree of each other at the distances they are actually used
at, so the same effective PPI would be wrong for both.

## How it compares to omarchy-display-manager

[omarchy-display-manager](https://github.com/Bmontythe3rd/omarchy-display-manager)
covers similar ground and is worth your attention. The difference in one line:

> **Display Manager keeps your settings in a sidecar profile. This keeps them
> in your Hyprland config.**

It also has features this plugin deliberately does not: **hotplug/dock profiles**
that auto-apply on topology change, and a numbered **identify-displays** overlay.
If you want those, use it — it does them well. `hl.monitor` rules already
survive hotplug, because Hyprland re-applies a matching rule when an output
comes back, but per-dock profiles are a real feature and this plugin has none.

What this plugin has that it does not: `monitors.lua` persistence, the full
`HL.MonitorSpec` surface with a raw escape hatch, EDID-derived density advice,
and a single Display icon instead of a second one beside the stock widget.

## Requirements

Omarchy 4 (Quattro), Hyprland 0.55+, and `hyprctl`, `jq`, `python3`, and
`systemd --user` — all already present on Omarchy. No packages are installed
and nothing runs as root.

## Development

```bash
python3 -m unittest discover tests   # 99 tests, no compositor needed
./tests/qmllint.sh                   # QML lint against the accepted baseline
omarchy plugin validate .
```

Two notes that cost real time to discover:

- `/usr/bin/qmllint` on Arch is the **Qt5** binary and exits 255 without a word
  on Qt6 QML. The Qt6 one is at `/usr/lib/qt6/bin/qmllint`.
- `qs.Ui` resolves to `<importPath>/qs/Ui`, but the shell ships that module at
  `<shell>/Ui`. Pointing `-I` at the shell root leaves every `qs.*` type
  unresolved and the lint silently checks almost nothing. `tests/qmllint.sh`
  builds the `qs` shim for you.

If you install by hand rather than with `omarchy plugin add`, note that
`omarchy-shell shell rescanPlugins` is asynchronous — wait a couple of seconds
and confirm with `omarchy-shell shell listPlugins` before enabling, or the
registry will act on a stale manifest.

The engine (`bin/display_settings.py`) is stdlib-only and holds all the
parsing, validation, and writing; the QML is presentation. Everything risky —
the Lua writer, the density advisor, the apply/verify/revert state machine — is
covered by tests that run without a compositor.

## Safety

Display settings apply through `hyprctl eval` with Hyprland's Lua monitor API
and are verified against live state before anything is written; the legacy
`hyprctl keyword monitor` path can report success without changing state. The
15-second revert is armed as a transient `systemd --user` timer rather than a
timer inside the shell, so it still fires if `omarchy-shell` dies — which is
exactly when a broken display leaves you no way to click Revert.

Every value is checked against a per-field whitelist before it is formatted
into Lua, because it reaches both `hyprctl eval` (which executes Lua) and your
config file (which is Lua). Values needing escaping are refused, not escaped.

As with any Omarchy plugin, this runs unsandboxed as your user inside
`omarchy-shell`. Read the source before you install it.

## Credits

Brightness, text-size, and scale behavior follow Omarchy's built-in Display
widget and call the same `omarchy-*` commands. Omarchy is MIT licensed.

## License

[MIT](LICENSE)
