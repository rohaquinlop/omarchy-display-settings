"""Tests for bin/display_settings.py (stdlib unittest).

Run: python3 -m unittest discover tests

Nothing here touches a live compositor or the user's real config: hyprctl
output comes from recorded fixtures and every write goes to a temp directory.
"""

import json
import os
import sys
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES = os.path.join(REPO, "tests", "fixtures")
sys.path.insert(0, os.path.join(REPO, "bin"))

import display_settings as ds  # engine lives in bin/display_settings.py


def fixture(name):
    with open(os.path.join(FIXTURES, name), encoding="utf-8") as handle:
        return handle.read()


def monitors(name):
    return json.loads(fixture(name))


class ModeTests(unittest.TestCase):
    def test_parses_advertised_form(self):
        self.assertEqual(ds.parse_mode("2560x1440@59.95Hz"), (2560, 1440, 59.95))

    def test_canonical_drops_hz_and_fixes_precision(self):
        self.assertEqual(ds.canonical_mode("2560x1440@59.95Hz"), "2560x1440@59.95")
        self.assertEqual(ds.canonical_mode("1920x1200@60"), "1920x1200@60.00")

    def test_rejects_garbage(self):
        self.assertIsNone(ds.parse_mode("preferred"))
        self.assertEqual(ds.canonical_mode("nonsense"), "")

    def test_live_float_matches_advertised_string(self):
        # hyprctl reports 60.00300 for an advertised 60.00Hz mode.
        self.assertTrue(ds.modes_match("1920x1200@60.00", "1920x1200@60.00300"))

    def test_different_refresh_does_not_match(self):
        self.assertFalse(ds.modes_match("2560x1440@60.00", "2560x1440@143.86"))

    def test_groups_refresh_rates_under_resolutions(self):
        resolutions, by_resolution = ds.group_modes(
            ["2560x1440@143.86", "2560x1440@59.95", "1920x1080@60.00"]
        )
        self.assertEqual(resolutions, ["2560x1440", "1920x1080"])
        self.assertEqual(by_resolution["2560x1440"], ["143.86", "59.95"])


class ScaleTests(unittest.TestCase):
    def test_clean_scale_matches_omarchy_rule(self):
        # 1920x1200 divides evenly at 1.25 -> 1536x960.
        self.assertEqual(ds.clean_scale(1.25, 1920, 1200), 1.25)

    def test_illegal_scale_rounds_up_to_legal(self):
        # 2560/3 is not whole, so 3 is not offered; 3.2 gives 800x450.
        self.assertEqual(ds.legal_scales(2560, 1440), ["1", "1.25", "1.6", "2", "3.2", "4"])

    def test_presets_are_deduplicated(self):
        scales = ds.legal_scales(1920, 1200)
        self.assertEqual(len(scales), len(set(scales)))

    def test_logical_size_divides_by_scale(self):
        self.assertEqual(ds.logical_size(2560, 1440, 1.25, 0), (2048, 1152))

    def test_odd_transform_swaps_axes(self):
        self.assertEqual(ds.logical_size(2560, 1440, 1.0, 1), (1440, 2560))


class DensityTests(unittest.TestCase):
    def test_reproduces_hand_computed_laptop_ppi(self):
        # The user's own monitors.lua comment records 162 DPI for this panel.
        ppi, note = ds.compute_ppi(1920, 1200, 300, 190)
        self.assertIsNone(note)
        self.assertAlmostEqual(ppi, 162.0, delta=0.5)

    def test_reproduces_hand_computed_external_ppi(self):
        # The same comment records 109 DPI for a 27" 1440p panel.
        ppi, note = ds.compute_ppi(2560, 1440, 597, 336)
        self.assertIsNone(note)
        self.assertAlmostEqual(ppi, 109.0, delta=0.5)

    def test_missing_physical_size_is_unknown(self):
        ppi, note = ds.compute_ppi(1920, 1080, 0, 0)
        self.assertIsNone(ppi)
        self.assertIn("no physical size", note)

    def test_implausible_density_is_unknown(self):
        # A TV reporting 16x9 mm would compute to thousands of PPI.
        ppi, note = ds.compute_ppi(1920, 1080, 16, 9)
        self.assertIsNone(ppi)
        self.assertIn("implausible", note)

    def test_axis_disagreement_is_unknown(self):
        ppi, note = ds.compute_ppi(1920, 1200, 300, 100)
        self.assertIsNone(ppi)
        self.assertIn("inconsistent", note)

    def test_rotated_pairing_is_absorbed(self):
        # Mode reported in the rotated orientation against unrotated mm.
        ppi, note = ds.compute_ppi(1200, 1920, 300, 190)
        self.assertIsNone(note)
        self.assertIsNotNone(ppi)

    def test_internal_connectors_detected(self):
        self.assertTrue(ds.is_internal("eDP-1"))
        self.assertTrue(ds.is_internal("LVDS-1"))
        self.assertFalse(ds.is_internal("HDMI-A-1"))

    def test_bands_differ_by_connector_class(self):
        self.assertEqual(ds.band_for("eDP-1"), ds.BAND_INTERNAL)
        self.assertEqual(ds.band_for("DP-2"), ds.BAND_EXTERNAL)


class AdvisorTests(unittest.TestCase):
    def test_recommends_the_scale_the_user_chose_by_hand(self):
        scales = ds.legal_scales(1920, 1200)
        self.assertEqual(ds.recommend_scale(162.0, scales, ds.BAND_INTERNAL), "1.25")

    def test_recommends_native_scale_for_27_inch_1440p(self):
        scales = ds.legal_scales(2560, 1440)
        self.assertEqual(ds.recommend_scale(109.0, scales, ds.BAND_EXTERNAL), "1")

    def test_prefers_integer_scale_on_a_tie(self):
        # 200 PPI: scale 2 gives 100, dead centre of the external band.
        scales = ds.legal_scales(3840, 2160)
        self.assertEqual(ds.recommend_scale(200.0, scales, ds.BAND_EXTERNAL), "2")

    def test_no_recommendation_without_density(self):
        self.assertIsNone(ds.recommend_scale(None, ["1", "2"], ds.BAND_EXTERNAL))

    def test_advisor_never_mutates_input(self):
        scales = ds.legal_scales(1920, 1200)
        before = list(scales)
        ds.recommend_scale(162.0, scales, ds.BAND_INTERNAL)
        self.assertEqual(scales, before)


class ValidationTests(unittest.TestCase):
    def test_accepts_a_connector_name(self):
        self.assertEqual(ds.validate_field("output", "HDMI-A-1"), "HDMI-A-1")

    def test_rejects_a_lua_injection_in_output(self):
        with self.assertRaises(ds.ValidationError):
            ds.validate_field("output", 'x"}) os.execute("rm -rf /") --')

    def test_rejects_quote_in_a_string_field(self):
        with self.assertRaises(ds.ValidationError):
            ds.validate_field("mirror", 'eDP-1"')

    def test_rejects_newline_in_a_string_field(self):
        with self.assertRaises(ds.ValidationError):
            ds.validate_field("output", "eDP-1\nhl.monitor({})")

    def test_rejects_comment_marker(self):
        with self.assertRaises(ds.ValidationError):
            ds.validate_field("mirror", "eDP--1x")

    def test_rejects_malformed_mode(self):
        with self.assertRaises(ds.ValidationError):
            ds.validate_field("mode", "1920by1200")

    def test_rejects_malformed_position(self):
        with self.assertRaises(ds.ValidationError):
            ds.validate_field("position", "0,0")

    def test_accepts_negative_position(self):
        self.assertEqual(ds.validate_field("position", "-1920x0"), "-1920x0")

    def test_bounds_transform(self):
        self.assertEqual(ds.validate_field("transform", 3), 3)
        with self.assertRaises(ds.ValidationError):
            ds.validate_field("transform", 9)

    def test_bounds_scale(self):
        with self.assertRaises(ds.ValidationError):
            ds.validate_field("scale", 99)

    def test_enumerates_cm(self):
        self.assertEqual(ds.validate_field("cm", "srgb"), "srgb")
        with self.assertRaises(ds.ValidationError):
            ds.validate_field("cm", "definitely-not-a-preset")

    def test_bitdepth_is_8_or_10(self):
        with self.assertRaises(ds.ValidationError):
            ds.validate_field("bitdepth", 12)

    def test_rejects_unknown_field(self):
        with self.assertRaises(ds.ValidationError):
            ds.validate_field("rm_rf_slash", 1)

    def test_icc_must_exist(self):
        with self.assertRaises(ds.ValidationError):
            ds.validate_field("icc", "/nonexistent/profile.icc")

    def test_icc_accepts_a_readable_file(self):
        with tempfile.NamedTemporaryFile(suffix=".icc") as handle:
            self.assertEqual(ds.validate_field("icc", handle.name), handle.name)


class RenderTests(unittest.TestCase):
    def test_renders_a_complete_rule(self):
        rule = {"output": "eDP-1", "mode": "1920x1200@60", "position": "0x0", "scale": 1.25}
        self.assertEqual(
            ds.render_rule(rule),
            'hl.monitor({ output = "eDP-1", mode = "1920x1200@60.00", position = "0x0", scale = 1.25 })',
        )

    def test_field_order_is_fixed_regardless_of_input_order(self):
        a = ds.render_rule({"scale": 1, "output": "eDP-1", "mode": "1920x1200@60"})
        b = ds.render_rule({"mode": "1920x1200@60", "output": "eDP-1", "scale": 1})
        self.assertEqual(a, b)

    def test_booleans_render_unquoted(self):
        rule = {"output": "eDP-1", "mode": "1920x1200@60", "disabled": True}
        self.assertIn("disabled = true", ds.render_rule(rule))

    def test_block_sorts_outputs_by_name(self):
        rules = [
            {"output": "HDMI-A-1", "mode": "2560x1440@60", "position": "1920x0", "scale": 1},
            {"output": "eDP-1", "mode": "1920x1200@60", "position": "0x0", "scale": 1.25},
        ]
        block = ds.render_block(rules, {})
        self.assertLess(block.index("HDMI-A-1"), block.index("eDP-1"))

    def test_block_carries_a_reasoning_comment(self):
        rules = [{"output": "eDP-1", "mode": "1920x1200@60", "position": "0x0", "scale": 1.25}]
        densities = {"eDP-1": {"ppi": 162.0, "effectivePpi": 129.6, "diagonalIn": 14.0}}
        block = ds.render_block(rules, densities)
        self.assertIn("162.0 PPI", block)
        self.assertIn("129.6 effective PPI", block)

    def test_no_timestamp_in_the_block(self):
        rules = [{"output": "eDP-1", "mode": "1920x1200@60", "position": "0x0", "scale": 1}]
        first = ds.render_block(rules, {})
        second = ds.render_block(rules, {})
        self.assertEqual(first, second)


class ParseConfigTests(unittest.TestCase):
    def test_parses_a_literal_rule(self):
        rule = ds.parse_rule_line(
            'hl.monitor({ output = "eDP-1", mode = "1920x1200@60", position = "0x0", scale = 1.25 })'
        )
        self.assertEqual(rule["output"], "eDP-1")
        self.assertEqual(rule["scale"], 1.25)

    def test_refuses_a_dynamic_rule(self):
        line = 'hl.monitor({ output = "", mode = "preferred", position = "auto", scale = omarchy_monitor_scale })'
        self.assertIsNone(ds.parse_rule_line(line))
        self.assertTrue(ds.is_dynamic_rule_line(line))

    def test_scan_ignores_the_catch_all(self):
        scanned = ds.scan_config(fixture("lua_stock.lua"))
        self.assertEqual(scanned["literalRules"], [])
        self.assertFalse(scanned["hasBlock"])

    def test_scan_finds_hand_written_rules(self):
        scanned = ds.scan_config(fixture("lua_handwritten.lua"))
        names = sorted(r["output"] for r in scanned["literalRules"])
        self.assertEqual(names, ["HDMI-A-1", "eDP-1"])

    def test_scan_ignores_commented_rules(self):
        scanned = ds.scan_config(
            '-- hl.monitor({ output = "DP-2", mode = "2560x1440@144", position = "0x0", scale = 1 })'
        )
        self.assertEqual(scanned["literalRules"], [])

    def test_scan_reports_desc_rules_separately(self):
        scanned = ds.scan_config(fixture("lua_desc.lua"))
        self.assertEqual(scanned["descRules"], ["desc:BOE 0x094C"])
        self.assertEqual(scanned["literalRules"], [])

    def test_scan_finds_an_existing_block(self):
        scanned = ds.scan_config(fixture("lua_hasblock.lua"))
        self.assertTrue(scanned["hasBlock"])
        self.assertEqual(scanned["blockOutputs"], ["eDP-1"])

    def test_scan_of_an_existing_block_does_not_report_it_as_user_rules(self):
        scanned = ds.scan_config(fixture("lua_hasblock.lua"))
        self.assertEqual(scanned["literalRules"], [])


class WriteConfigTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = os.path.join(self.tmp.name, "monitors.lua")
        self.rules = [
            {"output": "eDP-1", "mode": "1920x1200@60", "position": "0x0", "scale": 1.25}
        ]

    def write(self, content):
        with open(self.path, "w", encoding="utf-8") as handle:
            handle.write(content)

    def read(self):
        with open(self.path, encoding="utf-8") as handle:
            return handle.read()

    def test_creates_a_missing_file_with_only_the_block(self):
        ds.write_config(self.path, self.rules, {})
        text = self.read()
        self.assertTrue(text.startswith(ds.BLOCK_BEGIN))
        self.assertIn(ds.BLOCK_END, text)

    def test_appends_the_block_after_existing_content(self):
        self.write(fixture("lua_stock.lua"))
        ds.write_config(self.path, self.rules, {})
        text = self.read()
        self.assertLess(text.index("omarchy_gdk_scale"), text.index(ds.BLOCK_BEGIN))

    def test_rewriting_with_identical_input_produces_no_change(self):
        self.write(fixture("lua_stock.lua"))
        ds.write_config(self.path, self.rules, {})
        first = self.read()
        ds.write_config(self.path, self.rules, {})
        self.assertEqual(first, self.read())

    def test_replaces_an_existing_block_rather_than_stacking(self):
        self.write(fixture("lua_hasblock.lua"))
        ds.write_config(self.path, self.rules, {})
        self.assertEqual(self.read().count(ds.BLOCK_BEGIN), 1)

    def test_backs_up_once(self):
        self.write(fixture("lua_stock.lua"))
        ds.write_config(self.path, self.rules, {})
        backup = self.path + ds.BACKUP_SUFFIX
        self.assertTrue(os.path.exists(backup))
        with open(backup, encoding="utf-8") as handle:
            self.assertIn("omarchy_gdk_scale", handle.read())

    def test_backup_is_not_overwritten_by_a_later_write(self):
        self.write(fixture("lua_stock.lua"))
        ds.write_config(self.path, self.rules, {})
        ds.write_config(self.path, self.rules, {})
        with open(self.path + ds.BACKUP_SUFFIX, encoding="utf-8") as handle:
            self.assertNotIn(ds.BLOCK_BEGIN, handle.read())

    def test_imports_hand_written_rules_and_comments_them_out(self):
        self.write(fixture("lua_handwritten.lua"))
        rules = [
            {"output": "eDP-1", "mode": "1920x1200@60", "position": "0x0", "scale": 1.25},
            {"output": "HDMI-A-1", "mode": "2560x1440@59.95", "position": "1920x0", "scale": 1.25},
        ]
        result = ds.write_config(self.path, rules, {})
        text = self.read()
        self.assertEqual(sorted(result["imported"]), ["HDMI-A-1", "eDP-1"])
        # The originals survive as comments, so nothing is lost.
        self.assertIn('-- hl.monitor({ output = "eDP-1"', text)
        self.assertIn("imported into the omarchy-display-settings block", text)
        # And exactly one live rule per output remains, inside the block.
        live = [
            line
            for line in text.splitlines()
            if line.strip().startswith("hl.monitor(")
        ]
        self.assertEqual(len(live), 2)

    def test_import_preserves_the_users_comments(self):
        self.write(fixture("lua_handwritten.lua"))
        ds.write_config(self.path, self.rules, {})
        self.assertIn("162 DPI", self.read())

    def test_does_not_comment_out_dynamic_rules(self):
        self.write(fixture("lua_stock.lua"))
        ds.write_config(self.path, self.rules, {})
        text = self.read()
        self.assertIn(
            'hl.monitor({ output = "", mode = "preferred", position = "auto", scale = omarchy_monitor_scale })',
            text,
        )

    def test_writes_through_a_symlink_and_keeps_it(self):
        target = os.path.join(self.tmp.name, "dotfiles", "monitors.lua")
        os.makedirs(os.path.dirname(target))
        with open(target, "w", encoding="utf-8") as handle:
            handle.write(fixture("lua_stock.lua"))
        link = os.path.join(self.tmp.name, "linked.lua")
        os.symlink(target, link)

        ds.write_config(link, self.rules, {})

        self.assertTrue(os.path.islink(link))
        self.assertEqual(os.path.realpath(link), target)
        with open(target, encoding="utf-8") as handle:
            self.assertIn(ds.BLOCK_BEGIN, handle.read())

    def test_block_is_last_so_it_wins_reverse_iteration(self):
        self.write(fixture("lua_handwritten.lua"))
        ds.write_config(self.path, self.rules, {})
        text = self.read().rstrip("\n")
        self.assertTrue(text.endswith(ds.BLOCK_END))


class LayoutTests(unittest.TestCase):
    def rule(self, name, position, mode="1920x1200@60.00", scale=1.0, **extra):
        return {"output": name, "mode": mode, "position": position, "scale": scale, **extra}

    def test_accepts_a_side_by_side_layout(self):
        layout = [
            self.rule("eDP-1", "0x0"),
            self.rule("HDMI-A-1", "1920x0", mode="2560x1440@60.00"),
        ]
        self.assertEqual(ds.validate_layout(layout), [])

    def test_rejects_overlap(self):
        layout = [
            self.rule("eDP-1", "0x0"),
            self.rule("HDMI-A-1", "100x0", mode="2560x1440@60.00"),
        ]
        self.assertTrue(any("overlap" in p for p in ds.validate_layout(layout)))

    def test_overlap_is_measured_in_logical_pixels(self):
        # 2560 wide at scale 1.25 occupies 2048 logical px, so 2048x0 is flush
        # and 2000x0 overlaps. A physical-pixel check would miss both.
        flush = [
            self.rule("HDMI-A-1", "0x0", mode="2560x1440@60.00", scale=1.25),
            self.rule("eDP-1", "2048x0"),
        ]
        self.assertEqual(ds.validate_layout(flush), [])
        overlapping = [
            self.rule("HDMI-A-1", "0x0", mode="2560x1440@60.00", scale=1.25),
            self.rule("eDP-1", "2000x0"),
        ]
        self.assertTrue(any("overlap" in p for p in ds.validate_layout(overlapping)))

    def test_rejects_all_disabled(self):
        layout = [self.rule("eDP-1", "0x0", disabled=True)]
        self.assertTrue(any("enabled" in p for p in ds.validate_layout(layout)))

    def test_rejects_an_absent_mirror_target(self):
        layout = [self.rule("eDP-1", "0x0", mirror="DP-9")]
        self.assertTrue(any("not connected" in p for p in ds.validate_layout(layout)))

    def test_disabled_outputs_do_not_count_as_overlapping(self):
        layout = [
            self.rule("eDP-1", "0x0"),
            self.rule("HDMI-A-1", "0x0", disabled=True),
        ]
        self.assertEqual(ds.validate_layout(layout), [])

    def test_normalizes_to_origin(self):
        layout = [self.rule("eDP-1", "-1920x-100"), self.rule("HDMI-A-1", "0x0")]
        normalized = ds.normalize_positions(layout)
        positions = {r["output"]: r["position"] for r in normalized}
        self.assertEqual(positions["eDP-1"], "0x0")
        self.assertEqual(positions["HDMI-A-1"], "1920x100")

    def test_normalize_is_a_no_op_when_already_at_origin(self):
        layout = [self.rule("eDP-1", "0x0")]
        self.assertEqual(ds.normalize_positions(layout), layout)


class DescribeTests(unittest.TestCase):
    def describe_all(self, name):
        config = ds.scan_config("")
        return [ds.describe(m, config) for m in monitors(name)]

    def test_laptop_reports_density_and_recommendation(self):
        output = self.describe_all("monitors_laptop.json")[0]
        self.assertEqual(output["name"], "eDP-1")
        self.assertTrue(output["internal"])
        self.assertAlmostEqual(output["ppi"], 162.0, delta=0.5)
        self.assertEqual(output["recommendedScale"], "1.25")
        self.assertTrue(output["inBand"])

    def test_external_monitor_lists_every_advertised_resolution(self):
        outputs = {o["name"]: o for o in self.describe_all("monitors_dual.json")}
        external = outputs["HDMI-A-1"]
        self.assertEqual(external["resolutions"], ["2560x1440", "1920x1080", "1280x720"])
        self.assertEqual(external["refreshFor"]["2560x1440"], ["143.86", "59.95"])
        self.assertEqual(external["nativeResolution"], "2560x1440")
        self.assertFalse(external["internal"])

    def test_out_of_band_scale_is_flagged(self):
        # A 109 PPI panel at scale 1.25 gives 87 effective PPI: too large.
        config = ds.scan_config("")
        record = monitors("monitors_dual.json")[1]
        record["scale"] = 1.25
        output = ds.describe(record, config)
        self.assertAlmostEqual(output["effectivePpi"], 87.1, delta=0.5)
        self.assertFalse(output["inBand"])

    def test_rotated_output_swaps_logical_axes(self):
        output = self.describe_all("monitors_rotated.json")[0]
        self.assertEqual((output["logicalWidth"], output["logicalHeight"]), (1440, 2560))

    def test_unreliable_edid_yields_no_recommendation(self):
        outputs = {o["name"]: o for o in self.describe_all("monitors_badedid.json")}
        for name in ("HDMI-A-2", "HDMI-A-3", "DP-5"):
            self.assertIsNone(outputs[name]["ppi"], name)
            self.assertIsNone(outputs[name]["recommendedScale"], name)
            self.assertIsNotNone(outputs[name]["ppiNote"], name)

    def test_disabled_output_is_reported_without_crashing(self):
        outputs = {o["name"]: o for o in self.describe_all("monitors_disabled.json")}
        self.assertTrue(outputs["HDMI-A-1"]["disabled"])
        self.assertEqual(outputs["HDMI-A-1"]["modes"], [])

    def test_managed_flag_follows_the_block(self):
        config = ds.scan_config(fixture("lua_hasblock.lua"))
        output = ds.describe(monitors("monitors_laptop.json")[0], config)
        self.assertTrue(output["managed"])


class VerifyTests(unittest.TestCase):
    """The apply/verify contract, with hyprctl replaced by fixtures."""

    def setUp(self):
        self.original = ds.hypr_monitors

        def restore():
            ds.hypr_monitors = self.original

        self.addCleanup(restore)

    def use(self, records):
        ds.hypr_monitors = lambda: records

    def use_sequence(self, sequence):
        """Return each snapshot in turn, then repeat the last one."""
        state = {"i": 0}

        def next_read():
            index = min(state["i"], len(sequence) - 1)
            state["i"] += 1
            return sequence[index]

        ds.hypr_monitors = next_read

    def test_verify_waits_for_the_compositor_to_settle(self):
        # Hyprland schedules a rule rather than applying it inline, so the first
        # read back still shows the old values. Verifying instantly reported a
        # false rejection and auto-reverted a change that had actually worked.
        stale = monitors("monitors_laptop.json")
        settled = json.loads(json.dumps(stale))
        settled[0]["scale"] = 1.6
        reads = [stale, stale, settled]
        self.use_sequence(reads)
        layout = [{"output": "eDP-1", "mode": "1920x1200@60.00", "scale": 1.6}]
        self.assertEqual(ds.verify(layout, timeout=2), [])

    def test_verify_gives_up_after_the_timeout(self):
        self.use(monitors("monitors_laptop.json"))
        layout = [{"output": "eDP-1", "mode": "1920x1200@60.00", "scale": 1.6}]
        self.assertTrue(ds.verify(layout, timeout=0))

    def test_matching_state_verifies_clean(self):
        self.use(monitors("monitors_laptop.json"))
        layout = [
            {"output": "eDP-1", "mode": "1920x1200@60.00", "position": "0x0", "scale": 1.25}
        ]
        self.assertEqual(ds.verify(layout), [])

    def test_refresh_drift_is_tolerated(self):
        # Fixture reports 60.00300 against a requested 60.00.
        self.use(monitors("monitors_laptop.json"))
        layout = [{"output": "eDP-1", "mode": "1920x1200@60.00", "position": "0x0"}]
        self.assertEqual(ds.verify(layout), [])

    def test_detects_a_mode_the_hardware_refused(self):
        self.use(monitors("monitors_laptop.json"))
        layout = [{"output": "eDP-1", "mode": "3840x2160@60.00", "position": "0x0"}]
        self.assertTrue(any("not 3840x2160" in p for p in ds.verify(layout, timeout=0)))

    def test_detects_a_scale_that_did_not_take(self):
        self.use(monitors("monitors_laptop.json"))
        layout = [{"output": "eDP-1", "mode": "1920x1200@60.00", "scale": 2}]
        self.assertTrue(any("scale" in p for p in ds.verify(layout, timeout=0)))

    def test_detects_a_position_that_did_not_take(self):
        self.use(monitors("monitors_laptop.json"))
        layout = [{"output": "eDP-1", "mode": "1920x1200@60.00", "position": "1920x0"}]
        self.assertTrue(any("sits at" in p for p in ds.verify(layout, timeout=0)))

    def test_detects_a_missing_output(self):
        self.use(monitors("monitors_laptop.json"))
        layout = [{"output": "DP-9", "mode": "1920x1080@60.00"}]
        self.assertTrue(any("not present" in p for p in ds.verify(layout, timeout=0)))

    def test_current_layout_round_trips_into_rules(self):
        self.use(monitors("monitors_dual.json"))
        layout = ds.current_layout()
        self.assertEqual(len(layout), 2)
        self.assertEqual(ds.verify(layout), [])
        # Every rule it produces must survive validation and rendering.
        for rule in layout:
            ds.render_rule(rule)


class ApplyStateMachineTests(unittest.TestCase):
    """apply -> verify -> revert, with hyprctl and systemd fully stubbed."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        os.environ["XDG_STATE_HOME"] = self.tmp.name

        # The settle wait is real time; the state machine does not need it.
        self.settle = ds.SETTLE_TIMEOUT
        ds.SETTLE_TIMEOUT = 0
        self.addCleanup(lambda: setattr(ds, "SETTLE_TIMEOUT", self.settle))

        self.originals = {
            "hypr_monitors": ds.hypr_monitors,
            "apply_rule": ds.apply_rule,
            "arm_revert": ds.arm_revert,
            "stop_revert_unit": ds.stop_revert_unit,
        }

        def restore():
            for name, value in self.originals.items():
                setattr(ds, name, value)
            os.environ.pop("XDG_STATE_HOME", None)

        self.addCleanup(restore)

        self.applied = []
        self.armed = []
        self.stopped = []
        self.live = monitors("monitors_laptop.json")

        ds.hypr_monitors = lambda: self.live
        ds.apply_rule = self._record_apply
        ds.arm_revert = lambda: (self.armed.append(True), True)[1]
        ds.stop_revert_unit = lambda: self.stopped.append(True)

    def _record_apply(self, rule):
        self.applied.append(rule)
        return True, ""

    def good_layout(self):
        return [
            {"output": "eDP-1", "mode": "1920x1200@60.00", "position": "0x0", "scale": 1.25}
        ]

    def test_successful_apply_arms_revert_and_does_not_persist(self):
        result = ds.apply_layout(self.good_layout())
        self.assertTrue(result["ok"])
        self.assertEqual(result["stage"], "preview")
        self.assertEqual(len(self.armed), 1)
        # Nothing is written until confirm.
        self.assertIsNotNone(ds.read_pending())

    def test_revert_is_armed_before_anything_changes(self):
        order = []
        ds.arm_revert = lambda: (order.append("arm"), True)[1]

        def track(rule):
            order.append("apply")
            return True, ""

        ds.apply_rule = track
        ds.apply_layout(self.good_layout())
        self.assertEqual(order[0], "arm")

    def test_invalid_layout_never_touches_the_compositor(self):
        result = ds.apply_layout([{"output": "eDP-1", "mode": "1920x1200@60.00", "disabled": True}])
        self.assertFalse(result["ok"])
        self.assertEqual(result["stage"], "validate")
        self.assertEqual(self.applied, [])
        self.assertEqual(self.armed, [])

    def test_failed_apply_restores_the_previous_layout(self):
        ds.apply_rule = lambda rule: (False, "hardware said no")
        result = ds.apply_layout(self.good_layout())
        self.assertFalse(result["ok"])
        self.assertEqual(result["stage"], "apply")
        self.assertTrue(result["reverted"])

    def test_verification_failure_reverts_and_reports(self):
        # Compositor accepts the call but keeps the old mode.
        layout = [{"output": "eDP-1", "mode": "3840x2160@60.00", "position": "0x0"}]
        result = ds.apply_layout(layout)
        self.assertFalse(result["ok"])
        self.assertEqual(result["stage"], "verify")
        self.assertTrue(result["reverted"])

    def test_revert_restores_and_clears_pending(self):
        ds.apply_layout(self.good_layout())
        self.assertIsNotNone(ds.read_pending())
        result = ds.cmd_revert()
        self.assertTrue(result["restored"])
        self.assertIsNone(ds.read_pending())
        self.assertTrue(self.stopped)

    def test_revert_without_pending_state_is_harmless(self):
        result = ds.cmd_revert()
        self.assertTrue(result["ok"])
        self.assertFalse(result["restored"])

    def test_failed_apply_cancels_the_armed_revert(self):
        # A failed apply restores immediately, so the armed revert has nothing
        # left to do. Leaving it running fired a redundant restore later and
        # left a stale pending file to confuse the next apply.
        ds.apply_rule = lambda rule: (False, "hardware said no")
        result = ds.apply_layout(self.good_layout())
        self.assertFalse(result["ok"])
        self.assertTrue(result["reverted"])
        self.assertIsNone(ds.read_pending())
        self.assertTrue(self.stopped, "the transient unit must be stopped")

    def test_verification_failure_also_cancels(self):
        result = ds.apply_layout(
            [{"output": "eDP-1", "mode": "3840x2160@60.00", "position": "0x0"}]
        )
        self.assertEqual(result["stage"], "verify")
        self.assertIsNone(ds.read_pending())

    def test_revert_restores_before_it_cancels_anything(self):
        # Regression: cmd_revert used to run `systemctl stop <unit>.service`
        # first, which terminated the revert service from inside itself before
        # the restore could run. Order matters more than the call does.
        order = []
        ds.apply_layout(self.good_layout())
        ds.apply_rule = lambda rule: (order.append("restore"), (True, ""))[1]
        ds.stop_revert_unit = lambda *a, **k: order.append("stop")
        ds.cmd_revert()
        self.assertEqual(order[0], "restore")
        self.assertEqual(order[-1], "stop")

    def test_service_does_not_stop_itself(self):
        calls = []
        original_run = ds.run
        ds.run = lambda command: (calls.append(command), (0, "", ""))[1]
        self.addCleanup(lambda: setattr(ds, "run", original_run))
        os.environ["INVOCATION_ID"] = "pretend-we-are-the-unit"
        self.addCleanup(lambda: os.environ.pop("INVOCATION_ID", None))

        self.originals["stop_revert_unit"](True)

        stopped = [" ".join(c) for c in calls]
        self.assertTrue(any(".timer" in s for s in stopped), "timer should still be cancelled")
        self.assertFalse(any(".service" in s for s in stopped), "must not stop its own service")

    def test_service_stops_itself_when_run_from_outside(self):
        calls = []
        original_run = ds.run
        ds.run = lambda command: (calls.append(command), (0, "", ""))[1]
        self.addCleanup(lambda: setattr(ds, "run", original_run))
        os.environ.pop("INVOCATION_ID", None)

        self.originals["stop_revert_unit"](True)

        stopped = [" ".join(c) for c in calls]
        self.assertTrue(any(".service" in s for s in stopped))

    def test_arm_passes_the_pending_path_explicitly(self):
        # Regression: `systemd-run --user` hands the job to the user manager,
        # which does not inherit our environment. Relying on XDG_STATE_HOME
        # meant the fired revert looked in a different directory, found no
        # pending state, and restored nothing — silently.
        calls = []
        original_run = ds.run
        ds.run = lambda command: (calls.append(command), (0, "", ""))[1]
        self.addCleanup(lambda: setattr(ds, "run", original_run))

        self.originals["arm_revert"]()

        armed = [c for c in calls if c and c[0] == "systemd-run"]
        self.assertEqual(len(armed), 1)
        self.assertIn("--pending", armed[0])
        self.assertIn(ds.pending_path(), armed[0])

    def test_revert_reads_the_path_it_was_given(self):
        other = os.path.join(self.tmp.name, "elsewhere.json")
        with open(other, "w", encoding="utf-8") as handle:
            json.dump({"layout": [{"output": "eDP-1", "mode": "1920x1200@60.00"}]}, handle)
        result = ds.cmd_revert(other)
        self.assertTrue(result["restored"])
        self.assertFalse(os.path.exists(other))

    def test_stale_unit_is_stopped_before_arming_a_new_one(self):
        ds.arm_revert = self.originals["arm_revert"]
        ds.stop_revert_unit = lambda: self.stopped.append(True)
        original_run = ds.run
        ds.run = lambda command: (0, "", "")
        self.addCleanup(lambda: setattr(ds, "run", original_run))
        ds.arm_revert()
        self.assertTrue(self.stopped)


if __name__ == "__main__":
    unittest.main()
