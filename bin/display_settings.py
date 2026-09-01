#!/usr/bin/env python3
"""Engine for rohaquinlop.display-settings.

Reads monitor state from Hyprland, advises on scale from real EDID density,
applies layouts through the Lua monitor API, and persists them as a managed
block of hl.monitor() rules inside the user's own ~/.config/hypr/monitors.lua.

Stdlib only. bin/omarchy-display-settings is a launcher for this module; tests
import it directly.

Commands:
  read                     normalized monitor state as JSON
  advise                   recommended scale per output as JSON
  apply <layout.json>      arm revert, apply live, verify
  confirm                  cancel revert, write the managed block
  revert                   restore the previous layout
  persist <layout.json>    write the managed block only
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Any

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

BLOCK_BEGIN = "-- >>> omarchy-display-settings (generated) — do not edit inside this block >>>"
BLOCK_END = "-- <<< omarchy-display-settings <<<"

BACKUP_SUFFIX = ".omarchy-display-settings.bak"

# Hyprland accepts scales in 1/120 units that divide the mode into whole
# logical pixels. Same presets as Omarchy's own scale row, so this plugin and
# SUPER + / offer the same values.
SCALE_PRESETS = ("1", "1.25", "1.6", "2", "3", "4")

# Effective-PPI comfort bands. Internal panels are viewed closer, so the same
# perceived sharpness needs a higher density. Taste, not physics — overridable.
BAND_INTERNAL = (120.0, 140.0)
BAND_EXTERNAL = (95.0, 115.0)

# Connectors that are built into the machine. Same test omarchy-monitor-state
# uses to tell an internal panel from an external one.
INTERNAL_PREFIXES = ("eDP", "LVDS", "DSI")

# A density outside this range means the EDID is lying, not that the panel is
# exotic. Below ~30 is a projector or a TV reporting nonsense; above ~700 is
# beyond any shipping panel.
PPI_MIN, PPI_MAX = 30.0, 700.0

# Horizontal and vertical density should agree on any real panel. A larger gap
# means the reported physical size does not describe the reported mode.
PPI_AXIS_TOLERANCE = 0.05

# hyprctl reports refresh as a float that drifts from the advertised string
# (60.00300 vs "60.00Hz"). Anything closer than this is the same mode.
REFRESH_TOLERANCE = 0.5

REVERT_UNIT = "omarchy-display-settings-revert"
REVERT_SECONDS = 15

OUTPUT_NAME_RE = re.compile(r"^[A-Za-z0-9._-]+$")
MODE_RE = re.compile(r"^\d+x\d+@\d+(\.\d+)?$")
POSITION_RE = re.compile(r"^-?\d+x-?\d+$")

# Order fields are written in. Fixed so a no-op rewrite produces no git diff.
FIELD_ORDER = (
    "output",
    "mode",
    "position",
    "scale",
    "transform",
    "mirror",
    "vrr",
    "bitdepth",
    "cm",
    "icc",
    "supports_hdr",
    "supports_wide_color",
    "sdrbrightness",
    "sdrsaturation",
    "sdr_eotf",
    "min_luminance",
    "max_luminance",
    "max_avg_luminance",
    "sdr_min_luminance",
    "sdr_max_luminance",
    "disabled",
)

# Every field HL.MonitorSpec documents (/usr/share/hypr/stubs/hl.meta.lua).
# The raw escape hatch accepts these names and nothing else.
KNOWN_FIELDS = frozenset(FIELD_ORDER) | {"reserved", "reserved_area"}

CM_VALUES = frozenset({"auto", "srgb", "wide", "edid", "hdr", "hdredid"})
SDR_EOTF_VALUES = frozenset({"gamma2.2", "sRGB"})


class ValidationError(ValueError):
    """A value that must never reach hyprctl eval or monitors.lua."""


# ---------------------------------------------------------------------------
# Modes and scales
# ---------------------------------------------------------------------------


def parse_mode(mode: str) -> tuple[int, int, float] | None:
    """Split "2560x1440@59.95Hz" into (2560, 1440, 59.95). None if unparseable."""
    match = re.match(r"^(\d+)x(\d+)@(\d+(?:\.\d+)?)", str(mode or ""))
    if not match:
        return None
    return int(match.group(1)), int(match.group(2)), float(match.group(3))


def canonical_mode(mode: str) -> str:
    """Normalize any mode spelling to WxH@R.RR, the form written into Lua."""
    parts = parse_mode(mode)
    if not parts:
        return ""
    width, height, refresh = parts
    return f"{width}x{height}@{refresh:.2f}"


def mode_resolution(mode: str) -> str:
    parts = parse_mode(mode)
    return f"{parts[0]}x{parts[1]}" if parts else ""


def mode_refresh(mode: str) -> float | None:
    parts = parse_mode(mode)
    return parts[2] if parts else None


def modes_match(a: str, b: str) -> bool:
    """True when two mode strings name the same mode, tolerating float drift."""
    pa, pb = parse_mode(a), parse_mode(b)
    if not pa or not pb:
        return False
    return pa[0] == pb[0] and pa[1] == pb[1] and abs(pa[2] - pb[2]) <= REFRESH_TOLERANCE


def group_modes(modes: list[str]) -> tuple[list[str], dict[str, list[str]]]:
    """Return (resolutions in advertised order, {resolution: [refresh strings]})."""
    resolutions: list[str] = []
    by_resolution: dict[str, list[str]] = {}
    for mode in modes:
        parts = parse_mode(mode)
        if not parts:
            continue
        resolution = f"{parts[0]}x{parts[1]}"
        refresh = f"{parts[2]:.2f}"
        if resolution not in by_resolution:
            by_resolution[resolution] = []
            resolutions.append(resolution)
        if refresh not in by_resolution[resolution]:
            by_resolution[resolution].append(refresh)
    return resolutions, by_resolution


def clean_scale(scale: float, width: int, height: int) -> float | None:
    """Round a scale up to the nearest value Hyprland will accept for this mode.

    Hyprland works in 1/120 units and requires whole logical pixels, so a legal
    scale is one whose 1/120 numerator divides gcd(width*120, height*120). This
    is the same rule omarchy-hyprland-monitor-scaling uses, so the two agree.
    """
    if scale <= 0 or width <= 0 or height <= 0:
        return None
    divisor = math.gcd(width * 120, height * 120)
    units = round(scale * 120)
    if units < 1:
        units = 1
    if units > divisor:
        units = divisor
    while divisor % units != 0:
        units += 1
    return units / 120


def legal_scales(width: int, height: int, extra: float | None = None) -> list[str]:
    """Preset scales cleaned to legal values for this mode, deduplicated.

    Several presets can collapse onto the same legal value; keep the first, so
    stepping through the row always changes the effective scale.
    """
    seen: dict[str, None] = {}
    candidates = [float(p) for p in SCALE_PRESETS]
    if extra is not None:
        candidates.append(extra)
    for candidate in candidates:
        cleaned = clean_scale(candidate, width, height)
        if cleaned is None:
            continue
        seen.setdefault(format_number(cleaned), None)
    return sorted(seen, key=float)


def format_number(value: float) -> str:
    """Render a float without trailing zeros, so 1.25 stays "1.25" and 2.0 is "2"."""
    text = f"{value:.6f}".rstrip("0").rstrip(".")
    return text or "0"


def logical_size(width: int, height: int, scale: float, transform: int) -> tuple[int, int]:
    """Size the output occupies in Hyprland's coordinate space.

    Positions are logical pixels, not physical ones: a 2560x1440 panel at scale
    1.25 occupies 2048x1152. An odd transform rotates it a quarter turn.
    """
    if scale <= 0:
        scale = 1.0
    if transform % 2 == 1:
        width, height = height, width
    return round(width / scale), round(height / scale)


# ---------------------------------------------------------------------------
# Density
# ---------------------------------------------------------------------------


def compute_ppi(
    width: int, height: int, mm_width: float, mm_height: float
) -> tuple[float | None, str | None]:
    """Physical pixels per inch, or (None, reason) when the EDID is unusable.

    Density is taken from the diagonal — the standard definition, and robust to
    EDID rounding either axis (a 1920x1200 panel reported as 300x190 mm gives
    162.6 across and 160.4 down; the diagonal splits the difference at 161.9).

    Both axis pairings are tried and the closer-agreeing one is kept, which
    absorbs outputs whose reported mode is already rotated relative to the
    panel's manufactured dimensions. The remaining disagreement doubles as a
    lie detector: if even the better pairing disagrees, the reported physical
    size does not describe this mode and no density is reported at all.
    """
    if width <= 0 or height <= 0:
        return None, "unknown mode"
    if mm_width <= 0 or mm_height <= 0:
        return None, "display reports no physical size"

    spread = min(
        abs(pixel_w * 25.4 / mm_width - pixel_h * 25.4 / mm_height)
        / max(pixel_w * 25.4 / mm_width, pixel_h * 25.4 / mm_height)
        for pixel_w, pixel_h in ((width, height), (height, width))
    )
    if spread > PPI_AXIS_TOLERANCE:
        return None, "display reports an inconsistent physical size"

    ppi = math.hypot(width, height) / (math.hypot(mm_width, mm_height) / 25.4)
    if not (PPI_MIN <= ppi <= PPI_MAX):
        return None, "display reports an implausible physical size"
    return round(ppi, 1), None


def diagonal_inches(mm_width: float, mm_height: float) -> float | None:
    if mm_width <= 0 or mm_height <= 0:
        return None
    return round(math.hypot(mm_width, mm_height) / 25.4, 1)


def is_internal(name: str) -> bool:
    return str(name or "").startswith(INTERNAL_PREFIXES)


def band_for(name: str) -> tuple[float, float]:
    return BAND_INTERNAL if is_internal(name) else BAND_EXTERNAL


def recommend_scale(ppi: float | None, scales: list[str], band: tuple[float, float]) -> str | None:
    """The legal scale whose effective PPI sits nearest the band centre.

    An integer scale inside the band wins over a fractional one at the same
    distance: fractional scales make XWayland clients render soft.
    """
    if ppi is None or not scales:
        return None
    centre = (band[0] + band[1]) / 2
    best: tuple[float, int, str] | None = None
    for scale_text in scales:
        scale = float(scale_text)
        effective = ppi / scale
        distance = abs(effective - centre)
        # Sort key: distance first, then integer scales ahead of fractional.
        fractional = 0 if float(scale).is_integer() else 1
        candidate = (round(distance, 6), fractional, scale_text)
        if best is None or candidate < best:
            best = candidate
    return best[2] if best else None


# ---------------------------------------------------------------------------
# Lua value validation and rule rendering
# ---------------------------------------------------------------------------


def _reject_lua_metacharacters(field: str, value: str) -> None:
    """Refuse anything that could break out of a Lua string literal.

    Values reach both `hyprctl eval`, which executes Lua, and monitors.lua,
    which is Lua. Escaping is not attempted: a value that needs escaping is a
    value we do not understand, so it is refused.
    """
    for bad in ('"', "'", "\\", "\n", "\r", "--", "[[", "]]"):
        if bad in value:
            raise ValidationError(f"{field}: value may not contain {bad!r}")


def validate_field(field: str, value: Any) -> Any:
    """Normalize and bound-check one HL.MonitorSpec field. Raises on anything else."""
    if field not in KNOWN_FIELDS:
        raise ValidationError(
            f"unknown field {field!r}; accepted fields: {', '.join(sorted(KNOWN_FIELDS))}"
        )

    if field == "output":
        text = str(value)
        _reject_lua_metacharacters(field, text)
        if not OUTPUT_NAME_RE.match(text):
            raise ValidationError(f"output: {text!r} is not a connector name")
        return text

    if field == "mode":
        text = canonical_mode(str(value)) if str(value) != "preferred" else "preferred"
        if text == "preferred":
            return text
        if not MODE_RE.match(text):
            raise ValidationError(f"mode: {value!r} is not WxH@R")
        return text

    if field == "position":
        text = str(value)
        if text == "auto":
            return text
        if not POSITION_RE.match(text):
            raise ValidationError(f"position: {value!r} is not NxM")
        return text

    if field == "scale":
        if str(value) == "auto":
            return "auto"
        number = float(value)
        if not 0.1 <= number <= 8:
            raise ValidationError(f"scale: {value!r} out of range 0.1-8")
        return number

    if field == "transform":
        number = int(value)
        if not 0 <= number <= 7:
            raise ValidationError(f"transform: {value!r} out of range 0-7")
        return number

    if field == "mirror":
        text = str(value)
        _reject_lua_metacharacters(field, text)
        if not OUTPUT_NAME_RE.match(text):
            raise ValidationError(f"mirror: {text!r} is not a connector name")
        return text

    if field == "vrr":
        number = int(value)
        if number not in (0, 1, 2, 3):
            raise ValidationError(f"vrr: {value!r} must be 0-3")
        return number

    if field == "bitdepth":
        number = int(value)
        if number not in (8, 10):
            raise ValidationError(f"bitdepth: {value!r} must be 8 or 10")
        return number

    if field == "cm":
        text = str(value)
        if text not in CM_VALUES:
            raise ValidationError(f"cm: {value!r} must be one of {sorted(CM_VALUES)}")
        return text

    if field == "sdr_eotf":
        text = str(value)
        if text not in SDR_EOTF_VALUES:
            raise ValidationError(f"sdr_eotf: {value!r} must be one of {sorted(SDR_EOTF_VALUES)}")
        return text

    if field == "icc":
        text = str(value)
        _reject_lua_metacharacters(field, text)
        path = os.path.expanduser(text)
        if not os.path.isfile(path) or not os.access(path, os.R_OK):
            raise ValidationError(f"icc: {text!r} is not a readable file")
        return path

    if field in ("supports_hdr", "supports_wide_color", "disabled"):
        if isinstance(value, bool):
            return value
        number = int(value)
        if number not in (0, 1):
            raise ValidationError(f"{field}: {value!r} must be 0/1 or a boolean")
        return bool(number)

    if field in ("sdrbrightness", "sdrsaturation"):
        number = float(value)
        if not 0 <= number <= 10:
            raise ValidationError(f"{field}: {value!r} out of range 0-10")
        return number

    if field in (
        "min_luminance",
        "max_luminance",
        "max_avg_luminance",
        "sdr_min_luminance",
        "sdr_max_luminance",
    ):
        number = float(value)
        if not 0 <= number <= 10000:
            raise ValidationError(f"{field}: {value!r} out of range 0-10000")
        return number

    if field in ("reserved", "reserved_area"):
        number = int(value)
        if not 0 <= number <= 1000:
            raise ValidationError(f"{field}: {value!r} out of range 0-1000")
        return number

    raise ValidationError(f"unhandled field {field!r}")


def render_lua_value(value: Any) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int,)) and not isinstance(value, bool):
        return str(value)
    if isinstance(value, float):
        return format_number(value)
    return f'"{value}"'


def render_rule(rule: dict[str, Any]) -> str:
    """One validated hl.monitor() call.

    Rules are complete, never partial. Hyprland's CMonitorRuleManager::add()
    erases the prior rule with the same name before appending, so a field left
    out here resolves to Hyprland's own default rather than to whatever the
    user wrote earlier in the file.
    """
    validated = {field: validate_field(field, rule[field]) for field in rule}
    if "output" not in validated:
        raise ValidationError("rule has no output")
    parts = [
        f"{field} = {render_lua_value(validated[field])}"
        for field in FIELD_ORDER
        if field in validated
    ]
    for field in sorted(set(validated) - set(FIELD_ORDER)):
        parts.append(f"{field} = {render_lua_value(validated[field])}")
    return "hl.monitor({ " + ", ".join(parts) + " })"


def render_comment(rule: dict[str, Any], density: dict[str, Any] | None) -> str | None:
    """The reasoning line above a rule — the comment a careful user would write."""
    if not density or density.get("ppi") is None:
        return None
    bits = [str(rule.get("output", "")), str(rule.get("mode", ""))]
    if density.get("diagonalIn"):
        bits.append(f"{density['diagonalIn']}\"")
    bits.append(f"{density['ppi']} PPI")
    scale = rule.get("scale")
    if isinstance(scale, (int, float)) and density.get("effectivePpi") is not None:
        bits.append(f"scale {format_number(float(scale))} → {density['effectivePpi']} effective PPI")
    return "-- " + " · ".join(b for b in bits if b)


def render_block(rules: list[dict[str, Any]], densities: dict[str, dict[str, Any]]) -> str:
    """The full managed block.

    Outputs are sorted by name and fields follow FIELD_ORDER, so re-running
    with unchanged input produces a byte-identical file and an empty git diff.
    """
    lines = [BLOCK_BEGIN]
    for rule in sorted(rules, key=lambda r: str(r.get("output", ""))):
        comment = render_comment(rule, densities.get(str(rule.get("output", ""))))
        if comment:
            lines.append(comment)
        lines.append(render_rule(rule))
    lines.append(BLOCK_END)
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# monitors.lua parsing and writing
# ---------------------------------------------------------------------------

# Deliberately conservative: only a single-line call whose values are all
# literals. Anything dynamic (a variable, a loop, a conditional — Omarchy's own
# default uses `local omarchy_monitor_scale`) is left alone and reported.
RULE_LINE_RE = re.compile(r"^\s*hl\.monitor\(\{(?P<body>[^}]*)\}\)\s*$")
PAIR_RE = re.compile(
    r'(?P<key>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?P<value>"[^"]*"|true|false|-?\d+(?:\.\d+)?)'
)


def parse_rule_line(line: str) -> dict[str, Any] | None:
    """Parse one literal hl.monitor line, or None if it is not one."""
    match = RULE_LINE_RE.match(line)
    if not match:
        return None
    body = match.group("body")
    pairs = list(PAIR_RE.finditer(body))
    if not pairs:
        return None

    # Blank out every literal key = value pair. Anything left over is a
    # non-literal value such as `scale = omarchy_monitor_scale`, which makes
    # the whole line dynamic. Refuse it: importing a partial reading would
    # drop the field we could not evaluate and silently change behavior.
    remainder = list(body)
    for pair in pairs:
        for index in range(pair.start(), pair.end()):
            remainder[index] = " "
    if re.sub(r"[\s,]", "", "".join(remainder)):
        return None

    rule: dict[str, Any] = {}
    for pair in pairs:
        key = pair.group("key")
        raw = pair.group("value")
        if raw.startswith('"'):
            rule[key] = raw[1:-1]
        elif raw in ("true", "false"):
            rule[key] = raw == "true"
        elif "." in raw:
            rule[key] = float(raw)
        else:
            rule[key] = int(raw)
    if "output" not in rule:
        return None
    return rule


def is_dynamic_rule_line(line: str) -> bool:
    """A hl.monitor call this parser will not touch."""
    stripped = line.strip()
    if not stripped.startswith("hl.monitor("):
        return False
    return parse_rule_line(line) is None


def config_path() -> str:
    config_home = os.environ.get("XDG_CONFIG_HOME") or os.path.join(
        os.path.expanduser("~"), ".config"
    )
    return os.path.join(config_home, "hypr", "monitors.lua")


def split_block(text: str) -> tuple[str, str | None, str]:
    """Split file text into (before, block or None, after)."""
    begin = text.find(BLOCK_BEGIN)
    if begin == -1:
        return text, None, ""
    end = text.find(BLOCK_END, begin)
    if end == -1:
        return text, None, ""
    end += len(BLOCK_END)
    return text[:begin], text[begin:end], text[end:]


def scan_config(text: str) -> dict[str, Any]:
    """Describe what a monitors.lua already contains, ignoring the managed block."""
    before, block, after = split_block(text)
    outside = before + after
    literal: list[dict[str, Any]] = []
    dynamic: list[str] = []
    desc: list[str] = []
    for line in outside.splitlines():
        if line.strip().startswith("--"):
            continue
        rule = parse_rule_line(line)
        if rule is not None:
            output = str(rule.get("output", ""))
            # An empty output is Omarchy's catch-all; it applies only when no
            # named rule matched, so it is never something we take over.
            if output == "":
                continue
            if output.startswith("desc:"):
                desc.append(output)
                continue
            literal.append(rule)
        elif is_dynamic_rule_line(line):
            dynamic.append(line.strip())
    block_outputs: list[str] = []
    if block:
        for line in block.splitlines():
            rule = parse_rule_line(line)
            if rule:
                block_outputs.append(str(rule.get("output", "")))
    return {
        "hasBlock": block is not None,
        "blockOutputs": block_outputs,
        "literalRules": literal,
        "dynamicRules": dynamic,
        "descRules": desc,
    }


def atomic_write(path: str, text: str) -> str:
    """Write text to path, following symlinks and replacing atomically.

    The config is often a symlink into a dotfiles repo. Writing the resolved
    target keeps the link intact; replacing the link with a regular file would
    silently detach the user from their dotfiles.
    """
    target = os.path.realpath(path)
    directory = os.path.dirname(target) or "."
    os.makedirs(directory, exist_ok=True)
    handle = tempfile.NamedTemporaryFile(
        "w", dir=directory, prefix=".omarchy-display-settings.", delete=False
    )
    try:
        with handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        if os.path.exists(target):
            shutil.copymode(target, handle.name)
        os.replace(handle.name, target)
    except BaseException:
        if os.path.exists(handle.name):
            os.unlink(handle.name)
        raise
    return target


def ensure_backup(path: str) -> str | None:
    """Copy the config aside once, before the first write ever changes it."""
    target = os.path.realpath(path)
    backup = target + BACKUP_SUFFIX
    if os.path.exists(target) and not os.path.exists(backup):
        shutil.copy2(target, backup)
        return backup
    return None


def import_existing(text: str, outputs: set[str]) -> tuple[str, list[dict[str, Any]]]:
    """Comment out literal rules for outputs we are taking over, and return them.

    Values are carried into the block verbatim, so importing alone changes no
    effective behavior. Dynamic rules are left untouched.
    """
    before, block, after = split_block(text)
    imported: list[dict[str, Any]] = []
    seen: set[str] = set()

    def rewrite(section: str) -> str:
        lines = section.splitlines(keepends=True)
        result: list[str] = []
        for line in lines:
            rule = parse_rule_line(line)
            output = str(rule.get("output", "")) if rule else ""
            if rule and output in outputs and output != "" and output not in seen:
                seen.add(output)
                imported.append(rule)
                newline = "\n" if line.endswith("\n") else ""
                stripped = line.rstrip("\n")
                result.append(f"-- {stripped}{newline}")
                result.append(
                    "-- ^ imported into the omarchy-display-settings block below"
                    f"{newline or os.linesep}"
                )
            else:
                result.append(line)
        return "".join(result)

    new_text = rewrite(before) + (block or "") + rewrite(after)
    return new_text, imported


def write_config(
    path: str,
    rules: list[dict[str, Any]],
    densities: dict[str, dict[str, Any]],
    do_import: bool = True,
) -> dict[str, Any]:
    """Write the managed block, importing any hand-written rules it supersedes."""
    target = os.path.realpath(path)
    text = ""
    if os.path.exists(target):
        with open(target, encoding="utf-8") as handle:
            text = handle.read()

    backup = ensure_backup(path) if text else None

    imported: list[dict[str, Any]] = []
    if do_import and text:
        outputs = {str(r.get("output", "")) for r in rules}
        text, imported = import_existing(text, outputs)

    before, _, after = split_block(text)
    block = render_block(rules, densities)

    body = (before.rstrip("\n") + "\n\n") if before.strip() else ""
    tail = after.strip("\n")
    new_text = body + block + "\n"
    if tail:
        new_text += "\n" + tail + "\n"

    written = atomic_write(path, new_text)
    return {
        "path": path,
        "written": written,
        "backup": backup,
        "imported": [r.get("output") for r in imported],
        "isSymlink": os.path.islink(path),
    }


# ---------------------------------------------------------------------------
# Hyprland I/O
# ---------------------------------------------------------------------------


def run(command: list[str]) -> tuple[int, str, str]:
    try:
        proc = subprocess.run(command, capture_output=True, text=True, check=False)
    except FileNotFoundError as exc:
        return 127, "", str(exc)
    return proc.returncode, proc.stdout, proc.stderr


def hypr_monitors() -> list[dict[str, Any]]:
    code, out, err = run(["hyprctl", "monitors", "all", "-j"])
    if code != 0:
        raise RuntimeError(f"hyprctl failed: {err.strip() or code}")
    try:
        data = json.loads(out)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"hyprctl returned invalid JSON: {exc}") from exc
    return data if isinstance(data, list) else []


def apply_rule(rule: dict[str, Any]) -> tuple[bool, str]:
    """Apply one rule live through the Lua API.

    hyprctl keyword monitor is deliberately not used: it can report success
    without changing state. omarchy-hyprland-monitor-scaling uses eval too.
    """
    lua = render_rule(rule)
    code, out, err = run(["hyprctl", "eval", lua])
    ok = code == 0 and "error" not in (out or "").lower()
    return ok, (err or out or "").strip()


# ---------------------------------------------------------------------------
# State model
# ---------------------------------------------------------------------------


def describe(monitor: dict[str, Any], config: dict[str, Any]) -> dict[str, Any]:
    """Turn one hyprctl monitor record into everything the UI needs."""
    name = str(monitor.get("name", ""))
    modes = [canonical_mode(m) for m in monitor.get("availableModes") or []]
    modes = [m for m in modes if m]
    resolutions, refresh_for = group_modes(modes)

    width = int(monitor.get("width") or 0)
    height = int(monitor.get("height") or 0)
    scale = float(monitor.get("scale") or 1.0)
    transform = int(monitor.get("transform") or 0)
    current_mode = canonical_mode(f"{width}x{height}@{float(monitor.get('refreshRate') or 0)}")

    mm_width = float(monitor.get("physicalWidth") or 0)
    mm_height = float(monitor.get("physicalHeight") or 0)
    ppi, ppi_note = compute_ppi(width, height, mm_width, mm_height)

    scales = legal_scales(width, height, extra=scale)
    band = band_for(name)
    recommended = recommend_scale(ppi, scales, band)
    effective = round(ppi / scale, 1) if ppi else None
    logical_w, logical_h = logical_size(width, height, scale, transform)

    managed = name in config.get("blockOutputs", [])
    managed_elsewhere = any(name in line for line in config.get("dynamicRules", []))
    desc_conflict = [d for d in config.get("descRules", []) if str(monitor.get("description", "")) in d]

    return {
        "name": name,
        "description": str(monitor.get("description", "")),
        "internal": is_internal(name),
        "disabled": bool(monitor.get("disabled")),
        "focused": bool(monitor.get("focused")),
        "mode": current_mode,
        "modes": modes,
        "resolutions": resolutions,
        "refreshFor": refresh_for,
        "nativeResolution": resolutions[0] if resolutions else "",
        "x": int(monitor.get("x") or 0),
        "y": int(monitor.get("y") or 0),
        "position": f"{int(monitor.get('x') or 0)}x{int(monitor.get('y') or 0)}",
        "scale": scale,
        "legalScales": scales,
        "recommendedScale": recommended,
        "transform": transform,
        "vrr": bool(monitor.get("vrr")),
        "mirror": None if monitor.get("mirrorOf") in (None, "none", "") else monitor.get("mirrorOf"),
        "logicalWidth": logical_w,
        "logicalHeight": logical_h,
        "physicalWidthMm": mm_width,
        "physicalHeightMm": mm_height,
        "diagonalIn": diagonal_inches(mm_width, mm_height),
        "ppi": ppi,
        "ppiNote": ppi_note,
        "effectivePpi": effective,
        "band": list(band),
        "inBand": (effective is not None and band[0] <= effective <= band[1]),
        "managed": managed,
        "managedElsewhere": managed_elsewhere,
        "descConflicts": desc_conflict,
    }


def read_state() -> dict[str, Any]:
    path = config_path()
    text = ""
    real = os.path.realpath(path)
    if os.path.exists(real):
        with open(real, encoding="utf-8") as handle:
            text = handle.read()
    config = scan_config(text)
    monitors = hypr_monitors()
    return {
        "outputs": [describe(m, config) for m in monitors],
        "config": {
            "path": path,
            "realPath": real,
            "isSymlink": os.path.islink(path),
            "exists": os.path.exists(real),
            **config,
        },
        "pending": read_pending(),
    }


# ---------------------------------------------------------------------------
# Layout validation
# ---------------------------------------------------------------------------


def validate_layout(layout: list[dict[str, Any]]) -> list[str]:
    """Reasons this layout must not be applied. Empty means it is fine."""
    problems: list[str] = []
    enabled = [r for r in layout if not r.get("disabled")]
    if not enabled:
        problems.append("at least one display must stay enabled")

    names = {str(r.get("output", "")) for r in layout}
    for rule in layout:
        mirror = rule.get("mirror")
        if mirror and str(mirror) not in names:
            problems.append(f"{rule.get('output')} mirrors {mirror}, which is not connected")

    boxes = []
    for rule in enabled:
        if rule.get("mirror"):
            continue
        parts = parse_mode(str(rule.get("mode", "")))
        if not parts:
            continue
        position = str(rule.get("position", "0x0"))
        if not POSITION_RE.match(position):
            continue
        x_text, y_text = position.split("x", 1) if position.count("x") == 1 else (position[: position.rindex("x")], position[position.rindex("x") + 1 :])
        try:
            x, y = int(x_text), int(y_text)
        except ValueError:
            continue
        width, height = logical_size(
            parts[0], parts[1], float(rule.get("scale", 1) or 1), int(rule.get("transform", 0) or 0)
        )
        boxes.append((str(rule.get("output", "")), x, y, width, height))

    for i in range(len(boxes)):
        for j in range(i + 1, len(boxes)):
            a, b = boxes[i], boxes[j]
            if a[1] < b[1] + b[3] and a[1] + a[3] > b[1] and a[2] < b[2] + b[4] and a[2] + a[4] > b[2]:
                problems.append(f"{a[0]} and {b[0]} overlap")
    return problems


def normalize_positions(layout: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Translate the layout so the enabled bounding box starts at 0x0."""
    points = []
    for rule in layout:
        if rule.get("disabled") or rule.get("mirror"):
            continue
        position = str(rule.get("position", "0x0"))
        if not POSITION_RE.match(position):
            continue
        index = position.rindex("x")
        points.append((int(position[:index]), int(position[index + 1 :])))
    if not points:
        return layout
    min_x = min(p[0] for p in points)
    min_y = min(p[1] for p in points)
    if min_x == 0 and min_y == 0:
        return layout
    result = []
    for rule in layout:
        copy = dict(rule)
        position = str(rule.get("position", ""))
        if POSITION_RE.match(position) and not rule.get("disabled") and not rule.get("mirror"):
            index = position.rindex("x")
            copy["position"] = f"{int(position[:index]) - min_x}x{int(position[index + 1 :]) - min_y}"
        result.append(copy)
    return result


# ---------------------------------------------------------------------------
# Apply, verify, revert
# ---------------------------------------------------------------------------


def state_dir() -> str:
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(
        os.path.expanduser("~"), ".local", "state"
    )
    return os.path.join(base, "omarchy-display-settings")


def pending_path() -> str:
    return os.path.join(state_dir(), "pending.json")


def read_pending(path: str | None = None) -> dict[str, Any] | None:
    try:
        with open(path or pending_path(), encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError):
        return None


def write_pending(data: dict[str, Any]) -> None:
    os.makedirs(state_dir(), exist_ok=True)
    with open(pending_path(), "w", encoding="utf-8") as handle:
        json.dump(data, handle)


def clear_pending(path: str | None = None) -> None:
    try:
        os.unlink(path or pending_path())
    except OSError:
        pass


def shim_path() -> str:
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "omarchy-display-settings")


def running_inside_revert_unit() -> bool:
    """True when this process is the transient revert service's own payload.

    systemd exports INVOCATION_ID to a unit's processes and nothing else does.
    """
    return bool(os.environ.get("INVOCATION_ID"))


def stop_revert_unit(include_service: bool = True) -> None:
    """Cancel a scheduled revert.

    The service must not be stopped from inside itself: `systemctl stop` on our
    own unit terminates this process mid-restore, which is exactly what the
    revert exists to prevent. Stopping the timer from inside is fine — it is a
    separate unit.
    """
    run(["systemctl", "--user", "stop", f"{REVERT_UNIT}.timer"])
    if include_service and not running_inside_revert_unit():
        run(["systemctl", "--user", "stop", f"{REVERT_UNIT}.service"])


def arm_revert() -> bool:
    """Schedule the revert outside this process.

    An in-shell timer dies with omarchy-shell, which is exactly the moment it
    is needed: a broken display and a dead shell leave no way to click Revert.

    The pending path is passed as an argument rather than left to the
    environment. `systemd-run --user` hands the job to the user manager, which
    does not inherit our environment, so a caller with a different
    XDG_STATE_HOME than the manager would arm a revert that silently finds no
    pending state and restores nothing — a silent failure of the one safety net.
    """
    stop_revert_unit()
    code, _, _ = run(
        [
            "systemd-run",
            "--user",
            f"--on-active={REVERT_SECONDS}",
            f"--unit={REVERT_UNIT}",
            shim_path(),
            "revert",
            "--pending",
            pending_path(),
        ]
    )
    return code == 0


def current_layout() -> list[dict[str, Any]]:
    """The live layout, in the same rule shape apply() takes."""
    layout = []
    for monitor in hypr_monitors():
        name = str(monitor.get("name", ""))
        if not name:
            continue
        rule: dict[str, Any] = {
            "output": name,
            "mode": canonical_mode(
                f"{monitor.get('width')}x{monitor.get('height')}@{monitor.get('refreshRate')}"
            )
            or "preferred",
            "position": f"{int(monitor.get('x') or 0)}x{int(monitor.get('y') or 0)}",
            "scale": float(monitor.get("scale") or 1.0),
            "transform": int(monitor.get("transform") or 0),
        }
        if monitor.get("disabled"):
            rule["disabled"] = True
        mirror = monitor.get("mirrorOf")
        if mirror not in (None, "none", ""):
            rule["mirror"] = mirror
        layout.append(rule)
    return layout


def verify(layout: list[dict[str, Any]]) -> list[str]:
    """Compare live state to what was asked for. Empty means it took effect."""
    live = {str(m.get("name", "")): m for m in hypr_monitors()}
    problems: list[str] = []
    for rule in layout:
        name = str(rule.get("output", ""))
        monitor = live.get(name)
        if monitor is None:
            problems.append(f"{name} is not present")
            continue
        if rule.get("disabled"):
            if not monitor.get("disabled"):
                problems.append(f"{name} did not turn off")
            continue
        if monitor.get("disabled"):
            problems.append(f"{name} did not turn on")
            continue
        wanted_mode = str(rule.get("mode", ""))
        if wanted_mode and wanted_mode != "preferred":
            got = f"{monitor.get('width')}x{monitor.get('height')}@{monitor.get('refreshRate')}"
            if not modes_match(wanted_mode, got):
                problems.append(f"{name} kept {canonical_mode(got)}, not {wanted_mode}")
        if "scale" in rule and rule["scale"] != "auto":
            if abs(float(monitor.get("scale") or 0) - float(rule["scale"])) > 0.01:
                problems.append(f"{name} kept scale {monitor.get('scale')}, not {rule['scale']}")
        position = str(rule.get("position", ""))
        if POSITION_RE.match(position):
            index = position.rindex("x")
            want = (int(position[:index]), int(position[index + 1 :]))
            got_pos = (int(monitor.get("x") or 0), int(monitor.get("y") or 0))
            if want != got_pos:
                problems.append(f"{name} sits at {got_pos[0]}x{got_pos[1]}, not {position}")
        if "transform" in rule and int(monitor.get("transform") or 0) != int(rule["transform"]):
            problems.append(f"{name} kept transform {monitor.get('transform')}")
    return problems


def apply_layout(layout: list[dict[str, Any]]) -> dict[str, Any]:
    problems = validate_layout(layout)
    if problems:
        return {"ok": False, "stage": "validate", "problems": problems}

    layout = normalize_positions(layout)
    previous = current_layout()
    write_pending({"layout": previous})
    armed = arm_revert()

    def abandon(stage: str, problems: list[str]) -> dict[str, Any]:
        # We restored here and now, so the armed revert has nothing left to do.
        # Leaving it running would fire a redundant restore later and leave a
        # stale pending file behind to confuse the next apply.
        restore(previous)
        stop_revert_unit()
        clear_pending()
        return {"ok": False, "stage": stage, "problems": problems, "reverted": True}

    failures = []
    for rule in layout:
        ok, message = apply_rule(rule)
        if not ok:
            failures.append(f"{rule.get('output')}: {message}")
    if failures:
        return abandon("apply", failures)

    problems = verify(layout)
    if problems:
        return abandon("verify", problems)

    return {
        "ok": True,
        "stage": "preview",
        "armed": armed,
        "secondsRemaining": REVERT_SECONDS,
        "layout": layout,
    }


def restore(layout: list[dict[str, Any]]) -> None:
    for rule in layout:
        apply_rule(rule)


def cmd_revert(path: str | None = None) -> dict[str, Any]:
    # Restore first, cancel second. If anything here terminates this process
    # early, the display must already be back rather than left broken.
    pending = read_pending(path)
    restored = False
    if pending:
        restore(pending.get("layout", []))
        clear_pending(path)
        restored = True
    stop_revert_unit()
    return {"ok": True, "restored": restored}


def densities_for(outputs: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    return {
        o["name"]: {
            "ppi": o.get("ppi"),
            "effectivePpi": o.get("effectivePpi"),
            "diagonalIn": o.get("diagonalIn"),
        }
        for o in outputs
    }


def cmd_confirm() -> dict[str, Any]:
    stop_revert_unit()
    state = read_state()
    layout = current_layout()
    result = write_config(config_path(), layout, densities_for(state["outputs"]))
    clear_pending()
    return {"ok": True, **result}


def cmd_persist(layout: list[dict[str, Any]]) -> dict[str, Any]:
    problems = validate_layout(layout)
    if problems:
        return {"ok": False, "problems": problems}
    state = read_state()
    result = write_config(
        config_path(), normalize_positions(layout), densities_for(state["outputs"])
    )
    return {"ok": True, **result}


def cmd_advise() -> dict[str, Any]:
    state = read_state()
    return {
        "outputs": [
            {
                "name": o["name"],
                "ppi": o["ppi"],
                "ppiNote": o["ppiNote"],
                "effectivePpi": o["effectivePpi"],
                "band": o["band"],
                "inBand": o["inBand"],
                "recommendedScale": o["recommendedScale"],
                "currentScale": o["scale"],
            }
            for o in state["outputs"]
        ]
    }


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def load_layout(source: str) -> list[dict[str, Any]]:
    """Read a layout from inline JSON, a file path, or stdin ("-").

    Inline JSON is what the QML side uses. Passing it through stdin instead
    means the caller must close the pipe for json.load to return, and a caller
    that forgets leaves this process blocked forever holding the UI's busy
    flag — so argv is the safer contract for a payload this small.
    """
    text = source.strip()
    if text.startswith(("{", "[")):
        data = json.loads(text)
    elif source == "-":
        data = json.load(sys.stdin)
    else:
        with open(source, encoding="utf-8") as handle:
            data = json.load(handle)
    if isinstance(data, dict):
        data = data.get("layout", [])
    if not isinstance(data, list):
        raise ValueError("layout must be a JSON array of rules")
    return data


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="omarchy-display-settings", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("read")
    sub.add_parser("advise")
    sub.add_parser("confirm")
    revert_parser = sub.add_parser("revert")
    revert_parser.add_argument(
        "--pending",
        default=None,
        help="path to the pending-layout file; defaults to the XDG state location",
    )
    apply_parser = sub.add_parser("apply")
    apply_parser.add_argument("layout", help='inline layout JSON, a path to a layout JSON file, or "-" for stdin')
    persist_parser = sub.add_parser("persist")
    persist_parser.add_argument("layout", help='inline layout JSON, a path to a layout JSON file, or "-" for stdin')

    args = parser.parse_args(argv)
    try:
        if args.command == "read":
            result: Any = read_state()
        elif args.command == "advise":
            result = cmd_advise()
        elif args.command == "apply":
            result = apply_layout(load_layout(args.layout))
        elif args.command == "persist":
            result = cmd_persist(load_layout(args.layout))
        elif args.command == "confirm":
            result = cmd_confirm()
        elif args.command == "revert":
            result = cmd_revert(args.pending)
        else:
            parser.error(f"unknown command {args.command}")
            return 2
    except (RuntimeError, ValidationError, OSError, ValueError) as exc:
        json.dump({"ok": False, "error": str(exc)}, sys.stdout)
        sys.stdout.write("\n")
        return 1

    json.dump(result, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
