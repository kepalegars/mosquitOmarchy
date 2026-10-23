#!/usr/bin/python3
"""Unit tests for colors-unifier's contrast and managed-block logic.

Run: python3 scripts/tweaks/colors-unifier_test.py
"""
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("colors_unifier", HERE / "colors-unifier.py")
cu = importlib.util.module_from_spec(spec)
sys.modules["colors_unifier"] = cu
spec.loader.exec_module(cu)


def theme(mode="dark", bg="#101010", fg="#e0e0e0", accent="#4a90d9"):
    return {
        "mode": mode,
        "background": bg,
        "foreground": fg,
        "accent": accent,
        "dark_background": bg,
        "darker_background": bg,
        "lighter_background": bg,
        "muted": fg,
        "selection": accent,
        "red": "#cc3333",
        "green": "#33aa55",
        "yellow": "#ddaa22",
        "magenta": "#aa55cc",
        "blue": accent,
        "cyan": "#33aaaa",
    }


class ContrastTests(unittest.TestCase):
    def test_black_white_is_21(self):
        self.assertAlmostEqual(cu.contrast_ratio("#000000", "#ffffff"), 21.0, places=2)

    def test_white_on_white_is_unreadable(self):
        self.assertEqual(cu.readable_on("#ffffff", ["#ffffff"]), "#000000")

    def test_black_on_black_is_unreadable(self):
        self.assertEqual(cu.readable_on("#000000", ["#000000"]), "#ffffff")

    def test_good_theme_foreground_is_kept(self):
        self.assertEqual(cu.readable_on("#101010", ["#e0e0e0"]), "#e0e0e0")

    def test_ensure_contrast_fixes_muted_on_white(self):
        fixed = cu.ensure_contrast("#dddddd", ["#ffffff"], 3.0)
        self.assertGreaterEqual(cu.contrast_ratio(fixed, "#ffffff"), 3.0)

    def test_badge_text_meets_45(self):
        p = cu.build_palette(theme())
        for bg, fg in (
            (p["accent"], p["on_accent"]),
            (p["red"], p["on_red"]),
            (p["green"], p["on_green"]),
            (p["yellow"], p["on_yellow"]),
        ):
            self.assertGreaterEqual(cu.contrast_ratio(fg, bg), 4.5, (bg, fg))

    def test_light_theme_with_light_foreground_never_light_on_light(self):
        p = cu.build_palette(theme(mode="light", bg="#fefefe", fg="#f0f0f0"))
        for bg, fg in (
            (p["window_bg"], p["fg_window"]),
            (p["view_bg"], p["fg_view"]),
            (p["headerbar_bg"], p["fg_headerbar"]),
            (p["sidebar_bg"], p["fg_sidebar"]),
            (p["surface_bg"], p["fg_surface"]),
        ):
            self.assertGreaterEqual(cu.contrast_ratio(fg, bg), 4.5, (bg, fg))

    def test_status_text_is_readable_on_surfaces(self):
        p = cu.build_palette(theme())
        for key in ("accent_text", "success_text", "warning_text",
                    "error_text", "link_text"):
            for bg in (p["window_bg"], p["view_bg"], p["surface_bg"]):
                self.assertGreaterEqual(cu.contrast_ratio(p[key], bg), 4.5, (key, bg))


class ExplorerTests(unittest.TestCase):
    def test_flea_desktop_is_detected(self):
        self.assertTrue(cu.is_flea_desktop("com.thisisgm.flea.desktop\n"))
        self.assertTrue(cu.is_flea_desktop("flea.desktop"))

    def test_nautilus_is_not_flea(self):
        self.assertFalse(cu.is_flea_desktop("org.gnome.Nautilus.desktop\n"))
        self.assertFalse(cu.is_flea_desktop(""))

    def test_flea_default_skips_nautilus_prompt(self):
        seen = []
        def running(name):
            seen.append(name)
            return [123] if name == "nautilus" else []
        with patch.object(cu, "default_explorer_is_flea", return_value=True), \
             patch.object(cu, "windowed_pids", return_value={123}), \
             patch.object(cu, "running_pids", side_effect=running), \
             patch.object(cu, "spawn_nautilus_prompt") as prompt:
            restarted, pending, prompted = cu.refresh_apps()
        self.assertNotIn("nautilus", seen)
        self.assertFalse(prompted)
        prompt.assert_not_called()
        self.assertNotIn("nautilus", restarted + pending)


class ManagedBlockTests(unittest.TestCase):
    def test_managed_block_roundtrip(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "gtk.css"
            path.write_text("/* user css */\n")
            block = cu.render_block({"window_bg_color": "#101010"})
            self.assertEqual(cu.write_managed(path, block), "merged")
            self.assertIn(cu.BEGIN, path.read_text())
            self.assertIn("/* user css */", path.read_text())
            self.assertEqual(cu.revert_file(path), "restored-backup")
            self.assertEqual(path.read_text(), "/* user css */\n")

    def test_accord_block_is_stripped_on_apply(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "gtk.css"
            path.write_text(
                cu.ACCORD_BEGIN + "\n@define-color window_bg_color #000;\n" + cu.ACCORD_END + "\n"
                "/* user css */\n")
            cu.write_managed(path, cu.render_block({"window_bg_color": "#111111"}))
            text = path.read_text()
            self.assertNotIn(cu.ACCORD_BEGIN, text)
            self.assertIn(cu.BEGIN, text)
            self.assertIn("/* user css */", text)

    def test_truncated_managed_block_is_replaced(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "gtk.css"
            path.write_text(cu.BEGIN + "\n@define-color old #000;\n")
            cu.write_managed(path, cu.render_block({"window_bg_color": "#222222"}))
            text = path.read_text()
            self.assertNotIn("@define-color old", text)
            self.assertEqual(text.count(cu.BEGIN), 1)


if __name__ == "__main__":
    unittest.main()
