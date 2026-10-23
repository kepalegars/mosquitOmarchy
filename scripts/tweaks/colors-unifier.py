#!/usr/bin/python3
"""colors-unifier — make GTK4, GTK3, and (via qgtk3) Qt apps follow the
Omarchy theme, with contrast-safe text and a Nautilus that can be refreshed
immediately.

Derived from Accord (https://github.com/vonsensey/accord), MIT License,
Copyright (c) vonsensey. Kept here as a fork because two hardenings matter:

  * every foreground is checked against the surface it is actually drawn on
    (WCAG contrast ratio), not just derived once from the theme's foreground,
    so a theme can never produce light-on-light or dark-on-dark text;
  * Nautilus is never closed behind the user's back. A visible window gets a
    centred prompt that says what closing costs (in-progress copies/moves are
    cancelled); Esc/No leaves it running and the new CSS applies on its next
    start. When Flea is the default explorer, Nautilus is left entirely alone
    and that prompt is skipped.

Writes exactly: a marked block in ~/.config/gtk-4.0/gtk.css and
~/.config/gtk-3.0/gtk.css, two gsettings keys, and state.json. It also removes
Accord's own managed block so the two palettes cannot fight.

Exit codes: 0 = applied/reverted; 3 = nothing applied (missing or broken theme
input; the reason lands in state.json and on stderr).
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import tomllib
from pathlib import Path

HOME = Path.home()


def _env_path(name: str, default: Path) -> Path:
    v = os.environ.get(name)
    return Path(v) if v else default


def _state_default() -> Path:
    base = os.environ.get("XDG_STATE_HOME")
    return (Path(base) if base else HOME / ".local/state") / "mosquitomarchy/colors-unifier"


THEME_DIR = _env_path("COLORS_UNIFIER_THEME_DIR", HOME / ".local/state/omarchy/current/theme")
GTK4_CSS = _env_path("COLORS_UNIFIER_GTK4_CSS", HOME / ".config/gtk-4.0/gtk.css")
GTK3_CSS = _env_path("COLORS_UNIFIER_GTK3_CSS", HOME / ".config/gtk-3.0/gtk.css")
STATE_DIR = _env_path("COLORS_UNIFIER_STATE_DIR", _state_default())
STATE_FILE = STATE_DIR / "state.json"
PROMPT_PID_FILE = STATE_DIR / "nautilus-prompt.pid"
NO_GSETTINGS = os.environ.get("COLORS_UNIFIER_NO_GSETTINGS") == "1"
NO_PROMPT = os.environ.get("COLORS_UNIFIER_NO_PROMPT") == "1"

BEGIN = ("/* >>> colors-unifier:managed >>> generated from the active Omarchy "
         "theme; edits inside this block are overwritten */")
END = "/* <<< colors-unifier:managed <<< */"

# Accord's block, removed on every apply. Its service writes it whenever the
# theme changes, so leaving it in place means duplicate @define-color names and
# a last-wins race we cannot control.
ACCORD_BEGIN = "/* >>> accord:managed >>>"
ACCORD_END = "/* <<< accord:managed <<< */"

# Windowless GTK daemons that can be restarted without anything visible
# disappearing. Nautilus is handled separately: a visible window is the user's
# work, so it only closes after the prompt says yes.
RESTART_ALLOWLIST = ["geary", "gnome-calendar", "gnome-text-editor",
                     "loupe", "evince", "snapshot"]

HEX_RE = re.compile(r"^#[0-9a-fA-F]{6}$")
ENC = {"encoding": "utf-8", "errors": "surrogateescape"}


# ---------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------
def read_file(path: Path) -> str:
    return path.read_text(**ENC)


def atomic_write(path: Path, text: str, enc=None):
    kw = ENC if enc is None else enc
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent),
                               prefix=f".{path.name}.", suffix=".colors-unifier-tmp")
    try:
        os.fchmod(fd, 0o644)
        with os.fdopen(fd, "w", **kw) as f:
            f.write(text)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def find_block_span(text: str, begin: str, end: str):
    b = text.find(begin)
    if b < 0:
        return None
    e = text.find(end, b)
    if e < 0:
        return b, len(text)
    e += len(end)
    if e < len(text) and text[e] == "\n":
        e += 1
    return b, e


def strip_between(text: str, begin: str, end: str) -> str:
    span = find_block_span(text, begin, end)
    if span is None:
        return text
    remainder = text[:span[0]] + text[span[1]:]
    if remainder.startswith("\n"):
        remainder = remainder[1:]
    return remainder


def write_managed(path: Path, block: str, backup_suffix=".colors-unifier-backup") -> str:
    """Install `block` as our managed region. Returns created/updated/unchanged/merged."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path = path.resolve() if path.exists() else path.parent.resolve() / path.name

    if not path.exists():
        atomic_write(path, block)
        return "created"

    text = read_file(path)
    cleaned = strip_between(text, ACCORD_BEGIN, ACCORD_END)
    if cleaned != text:
        atomic_write(path, cleaned)
        text = cleaned

    span = find_block_span(text, BEGIN, END)
    if span is not None:
        new = text[:span[0]] + block + text[span[1]:]
        if new == text:
            return "unchanged"
        atomic_write(path, new)
        return "updated"

    backup = path.with_name(path.name + backup_suffix)
    if not backup.exists():
        shutil.copy2(path, backup)
    atomic_write(path, block + "\n" + text)
    return "merged"


def revert_file(path: Path, backup_suffix=".colors-unifier-backup") -> str:
    if path.exists():
        path = path.resolve()
    backup = path.with_name(path.name + backup_suffix)

    if backup.exists():
        backup_text = read_file(backup)
        if path.exists():
            remainder = strip_between(read_file(path), BEGIN, END)
            if remainder != backup_text:
                atomic_write(path, remainder)
                return "stripped-kept-backup"
        atomic_write(path, backup_text)
        backup.unlink()
        return "restored-backup"

    if not path.exists():
        return "absent"
    text = read_file(path)
    if BEGIN not in text:
        return "untouched"
    remainder = strip_between(text, BEGIN, END)
    if remainder.strip() == "":
        path.unlink()
        return "removed"
    atomic_write(path, remainder)
    return "stripped"


# ---------------------------------------------------------------------------
# Colour maths (WCAG 2.x)
# ---------------------------------------------------------------------------
def parse_hex(value):
    if isinstance(value, str) and HEX_RE.match(value.strip()):
        return value.strip().lower()
    return None


def _channels(hex_color: str) -> tuple[int, int, int]:
    return (int(hex_color[1:3], 16), int(hex_color[3:5], 16), int(hex_color[5:7], 16))


def _linear(component: int) -> float:
    c = component / 255.0
    return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4


def luminance(hex_color: str) -> float:
    r, g, b = _channels(hex_color)
    return 0.2126 * _linear(r) + 0.7152 * _linear(g) + 0.0722 * _linear(b)


def contrast_ratio(a: str, b: str) -> float:
    la, lb = luminance(a), luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def mix(a: str, b: str, t: float) -> str:
    ca, cb = _channels(a), _channels(b)
    return "#" + "".join(f"{round(x + (y - x) * t):02x}" for x, y in zip(ca, cb))


def min_ratio(fg: str, backgrounds: list[str]) -> float:
    return min(contrast_ratio(fg, bg) for bg in backgrounds)


def readable_on(bg: str, candidates: list[str], minimum: float = 4.5) -> str:
    """A foreground for `bg`: the first candidate that passes, else black or
    white (whichever wins). Never returns an unreadable candidate just because
    it is the theme's."""
    for c in candidates:
        if contrast_ratio(c, bg) >= minimum:
            return c
    return max(["#000000", "#ffffff"], key=lambda c: contrast_ratio(c, bg))


def ensure_contrast(color: str, backgrounds: list[str], minimum: float = 4.5) -> str:
    """Return `color` if it passes on every background, otherwise the closest
    blend toward black or white that passes. If neither direction can reach
    the threshold, return whichever has the best worst-case ratio."""
    if min_ratio(color, backgrounds) >= minimum:
        return color
    best, best_ratio = color, min_ratio(color, backgrounds)
    for step in range(1, 26):
        t = step / 25.0
        for target in ("#000000", "#ffffff"):
            candidate = mix(color, target, t)
            ratio = min_ratio(candidate, backgrounds)
            if ratio > best_ratio:
                best, best_ratio = candidate, ratio
            if ratio >= minimum:
                return candidate
    return best


def on_color(base: str, candidates: list[str], minimum: float = 4.5) -> str:
    best = max(candidates, key=lambda c: contrast_ratio(c, base))
    if contrast_ratio(best, base) >= minimum:
        return best
    return ensure_contrast(best, [base], minimum)


# ---------------------------------------------------------------------------
# Theme
# ---------------------------------------------------------------------------
def load_theme(theme_dir: Path):
    toml_path = theme_dir / "colors.toml"
    try:
        with open(toml_path, "rb") as f:
            data = tomllib.load(f)
    except (OSError, tomllib.TOMLDecodeError) as e:
        return None, f"cannot read {toml_path}: {e}"

    def col(*keys):
        for k in keys:
            v = parse_hex(data.get(k))
            if v:
                return v
        return None

    background = col("background")
    foreground = col("foreground")
    accent = col("accent", "blue")
    if not (background and foreground and accent):
        return None, f"{toml_path} lacks background/foreground/accent"

    return {
        "mode": "light" if data.get("mode") == "light" else "dark",
        "background": background,
        "foreground": foreground,
        "accent": accent,
        "dark_background": col("dark_background", "background"),
        "darker_background": col("darker_background", "dark_background", "background"),
        "lighter_background": col("lighter_background", "background"),
        "muted": col("muted", "dark_foreground", "foreground"),
        "selection": col("selection", "lighter_background", "background"),
        "red": col("red", "bright_red") or accent,
        "green": col("green", "bright_green") or accent,
        "yellow": col("yellow", "bright_yellow") or accent,
        "magenta": col("magenta", "bright_magenta") or accent,
        "blue": col("blue", "bright_blue") or accent,
        "cyan": col("cyan", "bright_cyan") or accent,
    }, None


def build_palette(t):
    dark = t["mode"] == "dark"
    if dark:
        window_bg = t["background"]
        view_bg = t["dark_background"]
        headerbar_bg = t["darker_background"]
        surface_bg = t["lighter_background"]
        sidebar_bg = t["dark_background"]
    else:
        window_bg = t["dark_background"]
        view_bg = t["background"]
        headerbar_bg = t["darker_background"]
        surface_bg = t["background"]
        sidebar_bg = t["dark_background"]

    fg = t["foreground"]
    surfaces = [window_bg, view_bg, headerbar_bg, surface_bg, sidebar_bg]
    safe = [window_bg, view_bg, surface_bg]
    shade = "rgba(0, 0, 0, 0.36)" if dark else "rgba(0, 0, 6, 0.07)"

    return {
        "mode": t["mode"],
        "window_bg": window_bg, "view_bg": view_bg, "headerbar_bg": headerbar_bg,
        "surface_bg": surface_bg, "sidebar_bg": sidebar_bg,
        "accent": t["accent"], "selection": t["selection"], "shade": shade,
        "red": t["red"], "green": t["green"], "yellow": t["yellow"],
        "magenta": t["magenta"], "blue": t["blue"], "cyan": t["cyan"],
        "fg": fg,
        # One foreground per surface: what makes light-on-light impossible.
        "fg_window": readable_on(window_bg, [fg]),
        "fg_view": readable_on(view_bg, [fg]),
        "fg_headerbar": readable_on(headerbar_bg, [fg]),
        "fg_sidebar": readable_on(sidebar_bg, [fg]),
        "fg_surface": readable_on(surface_bg, [fg]),
        # Insensitive/secondary text only has to be legible, not primary.
        "muted_safe": ensure_contrast(t["muted"], surfaces, 3.0),
        "accent_text": ensure_contrast(t["accent"], safe, 4.5),
        "on_accent": on_color(t["accent"], [t["background"], t["foreground"]]),
        "on_red": on_color(t["red"], [t["background"], t["foreground"]]),
        "on_green": on_color(t["green"], [t["background"], t["foreground"]]),
        "on_yellow": on_color(t["yellow"], [t["background"], t["foreground"]]),
        "success_text": ensure_contrast(t["green"], safe, 4.5),
        "warning_text": ensure_contrast(t["yellow"], safe, 4.5),
        "error_text": ensure_contrast(t["red"], safe, 4.5),
        "link_text": ensure_contrast(t["accent"], safe, 4.5),
        "visited_text": ensure_contrast(t["magenta"], safe, 4.5),
    }


def gtk4_defines(p):
    return {
        "accent_bg_color": p["accent"], "accent_fg_color": p["on_accent"],
        "accent_color": p["accent_text"],
        "destructive_bg_color": p["red"], "destructive_fg_color": p["on_red"],
        "destructive_color": p["error_text"],
        "success_bg_color": p["green"], "success_fg_color": p["on_green"],
        "success_color": p["success_text"],
        "warning_bg_color": p["yellow"], "warning_fg_color": p["on_yellow"],
        "warning_color": p["warning_text"],
        "error_bg_color": p["red"], "error_fg_color": p["on_red"],
        "error_color": p["error_text"],
        "window_bg_color": p["window_bg"], "window_fg_color": p["fg_window"],
        "view_bg_color": p["view_bg"], "view_fg_color": p["fg_view"],
        "headerbar_bg_color": p["headerbar_bg"], "headerbar_fg_color": p["fg_headerbar"],
        "headerbar_border_color": p["fg_headerbar"],
        "headerbar_backdrop_color": p["window_bg"],
        "headerbar_shade_color": p["shade"],
        "headerbar_darker_shade_color": p["shade"],
        "sidebar_bg_color": p["sidebar_bg"], "sidebar_fg_color": p["fg_sidebar"],
        "sidebar_backdrop_color": p["window_bg"],
        "sidebar_shade_color": p["shade"],
        "sidebar_border_color": p["shade"],
        "secondary_sidebar_bg_color": p["sidebar_bg"],
        "secondary_sidebar_fg_color": p["fg_sidebar"],
        "secondary_sidebar_backdrop_color": p["window_bg"],
        "secondary_sidebar_shade_color": p["shade"],
        "secondary_sidebar_border_color": p["shade"],
        "card_bg_color": p["surface_bg"], "card_fg_color": p["fg_surface"],
        "card_shade_color": p["shade"],
        "dialog_bg_color": p["surface_bg"], "dialog_fg_color": p["fg_surface"],
        "popover_bg_color": p["surface_bg"], "popover_fg_color": p["fg_surface"],
        "popover_shade_color": p["shade"],
        "thumbnail_bg_color": p["surface_bg"], "thumbnail_fg_color": p["fg_surface"],
        "shade_color": p["shade"],
        "scrollbar_outline_color": p["shade"],
    }


def gtk3_defines(p):
    return {
        "theme_bg_color": p["window_bg"], "theme_fg_color": p["fg_window"],
        "theme_base_color": p["view_bg"], "theme_text_color": p["fg_view"],
        "theme_selected_bg_color": p["accent"], "theme_selected_fg_color": p["on_accent"],
        "theme_unfocused_bg_color": p["window_bg"], "theme_unfocused_fg_color": p["fg_window"],
        "theme_unfocused_base_color": p["view_bg"], "theme_unfocused_text_color": p["fg_view"],
        "theme_unfocused_selected_bg_color": p["accent"],
        "theme_unfocused_selected_fg_color": p["on_accent"],
        "insensitive_bg_color": p["window_bg"], "insensitive_fg_color": p["muted_safe"],
        "insensitive_base_color": p["view_bg"],
        "borders": p["selection"], "unfocused_borders": p["selection"],
        "link_color": p["link_text"], "link_visited_color": p["visited_text"],
        "success_color": p["success_text"], "warning_color": p["warning_text"],
        "error_color": p["error_text"],
    }


def render_block(defines: dict) -> str:
    lines = [BEGIN]
    lines += [f"@define-color {name} {value};" for name, value in defines.items()]
    lines.append(END)
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# gsettings + state
# ---------------------------------------------------------------------------
def gsettings_get(key: str):
    try:
        out = subprocess.run(
            ["gsettings", "get", "org.gnome.desktop.interface", key],
            capture_output=True, text=True, timeout=10)
        return out.stdout.strip().strip("'") if out.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def gsettings_set(key: str, value: str) -> bool:
    try:
        return subprocess.run(
            ["gsettings", "set", "org.gnome.desktop.interface", key, value],
            capture_output=True, timeout=10).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def display_name(theme_dir: Path) -> str:
    try:
        name = (theme_dir.parent / "theme.name").read_text(encoding="utf-8").strip()
    except OSError:
        name = ""
    if not name:
        name = theme_dir.resolve().name
    return re.sub(r"[^A-Za-z0-9 _.-]", "-", name)[:64]


def load_state():
    try:
        with open(STATE_FILE, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}


def save_state(state: dict):
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        atomic_write(STATE_FILE, json.dumps(state, indent=1) + "\n",
                     enc={"encoding": "utf-8"})
        return True
    except OSError as e:
        print(f"colors-unifier: cannot write {STATE_FILE}: {e}", file=sys.stderr)
        return False


def usable_saved(saved) -> bool:
    return isinstance(saved, dict) and any(saved.values())


# ---------------------------------------------------------------------------
# Nautilus
# ---------------------------------------------------------------------------
def running_pids(name: str) -> list[int]:
    try:
        out = subprocess.run(["pgrep", "-x", "-U", str(os.getuid()), name],
                             capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return []
    if out.returncode != 0:
        return []
    return [int(p) for p in out.stdout.split() if p.isdigit()]


def windowed_pids():
    try:
        out = subprocess.run(["hyprctl", "clients", "-j"],
                             capture_output=True, text=True, timeout=10)
        if out.returncode != 0:
            return None
        return {c["pid"] for c in json.loads(out.stdout)
                if isinstance(c, dict) and c.get("pid")}
    except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError,
            TypeError, AttributeError, KeyError):
        return None


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def prompt_already_running() -> bool:
    try:
        pid = int(PROMPT_PID_FILE.read_text().strip())
    except (OSError, ValueError):
        return False
    if pid_alive(pid):
        return True
    PROMPT_PID_FILE.unlink(missing_ok=True)
    return False


def spawn_nautilus_prompt() -> bool:
    if NO_PROMPT or not (os.environ.get("WAYLAND_DISPLAY") or os.environ.get("DISPLAY")):
        return False
    if not shutil.which("zenity"):
        print("colors-unifier: zenity not found; Nautilus left running", file=sys.stderr)
        return False
    if prompt_already_running():
        return True
    try:
        proc = subprocess.Popen(
            [sys.executable, str(Path(__file__).resolve()), "--nautilus-prompt"],
            start_new_session=True, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL)
    except OSError as e:
        print(f"colors-unifier: cannot start the Nautilus prompt: {e}", file=sys.stderr)
        return False
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        PROMPT_PID_FILE.write_text(str(proc.pid) + "\n")
    except OSError:
        pass
    return True


def nautilus_prompt() -> int:
    """The detached child: ask, then quit/reopen Nautilus only on Yes. Zenity
    returns 1 for No, Esc and the window's close button, which is exactly the
    'leave it running' answer."""
    text = (
        "The Omarchy theme changed.\n\n"
        "Nautilus must be closed to repaint itself with the new theme now.\n"
        "Closing it cancels any copy or move that is still in progress.\n\n"
        "Close Nautilus and reopen a window?\n"
        "No leaves it running; it will use the new theme next time it starts."
    )
    try:
        code = subprocess.run(
            ["zenity", "--question", "--title=colors-unifier",
             "--text=" + text, "--ok-label=Close and reopen",
             "--cancel-label=Not now", "--default-cancel"],
            timeout=180).returncode
    except (OSError, subprocess.TimeoutExpired):
        code = 1
    finally:
        PROMPT_PID_FILE.unlink(missing_ok=True)
    if code != 0:
        return 0
    try:
        subprocess.run(["nautilus", "-q"], timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        pass
    time.sleep(0.3)
    if not running_pids("nautilus"):
        try:
            subprocess.Popen(["setsid", "-f", "nautilus"], start_new_session=True,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             stdin=subprocess.DEVNULL)
        except OSError:
            pass
    return 0


def is_flea_desktop(desktop: str) -> bool:
    return "flea" in desktop.strip().lower()


def default_explorer_is_flea() -> bool:
    try:
        out = subprocess.run(
            ["xdg-mime", "query", "default", "inode/directory"],
            capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return out.returncode == 0 and is_flea_desktop(out.stdout)


def refresh_apps():
    """Restart windowless GTK daemons; for Nautilus, prompt instead of closing
    a visible window. Flea being the default explorer means Nautilus is not
    the user's file manager: leave it alone, with no prompt."""
    visible = windowed_pids()
    nautilus = [] if default_explorer_is_flea() else running_pids("nautilus")
    restarted, pending, prompted = [], [], False

    if nautilus:
        if visible is None:
            pending.append("nautilus")
        elif any(p in visible for p in nautilus):
            prompted = spawn_nautilus_prompt()
            if not prompted:
                pending.append("nautilus")
        else:
            for p in nautilus:
                try:
                    os.kill(p, 15)
                except OSError:
                    pass
            restarted.append("nautilus")

    candidates = {name: pids for name in RESTART_ALLOWLIST
                  if (pids := running_pids(name))}
    for name, pids in candidates.items():
        if visible is None:
            pending.append(name)
            continue
        if any(p in visible for p in pids):
            pending.append(name)
            continue
        for p in pids:
            try:
                os.kill(p, 15)
            except OSError:
                pass
        restarted.append(name)

    return restarted, pending, prompted


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
def do_revert() -> int:
    state = load_state()
    r4 = revert_file(GTK4_CSS)
    r3 = revert_file(GTK3_CSS)
    saved = state.get("gsettings", {}).get("saved") or {}
    restored, failed = [], []
    if not NO_GSETTINGS:
        if usable_saved(saved):
            for key, value in saved.items():
                if not value:
                    continue
                (restored if gsettings_set(key, value) else failed).append(key)
        else:
            if shutil.which("omarchy-theme-set-gnome"):
                try:
                    if subprocess.run(["omarchy-theme-set-gnome"],
                                      capture_output=True, timeout=15).returncode == 0:
                        restored = ["via omarchy-theme-set-gnome"]
                except (OSError, subprocess.TimeoutExpired):
                    pass
    STATE_FILE.unlink(missing_ok=True)
    PROMPT_PID_FILE.unlink(missing_ok=True)
    if failed:
        print(f"colors-unifier: reverted css (gtk4: {r4}, gtk3: {r3}) but could "
              f"not restore gsettings: {', '.join(failed)}", file=sys.stderr)
        return 1
    gs = ", ".join(restored) if restored else "nothing to restore"
    print(f"colors-unifier: reverted (gtk4: {r4}, gtk3: {r3}, gsettings: {gs})")
    return 0


def do_status() -> int:
    state = load_state()
    block4 = GTK4_CSS.exists() and BEGIN in read_file(GTK4_CSS)
    block3 = GTK3_CSS.exists() and BEGIN in read_file(GTK3_CSS)
    nautilus = running_pids("nautilus")
    visible = windowed_pids()
    nautilus_open = bool(nautilus) and visible is not None and any(p in visible for p in nautilus)
    print(f"theme: {state.get('theme', '?')} ({state.get('mode', '?')})")
    print(f"gtk4: {'managed' if block4 else 'absent'} ({GTK4_CSS})")
    print(f"gtk3: {'managed' if block3 else 'absent'} ({GTK3_CSS})")
    print(f"nautilus: {'open window' if nautilus_open else 'running' if nautilus else 'not running'}")
    if state.get("lastError"):
        print(f"last error: {state['lastError']}")
    return 0


def apply(no_restart: bool, quiet: bool) -> int:
    theme, err = load_theme(THEME_DIR)
    if theme is None:
        print(f"colors-unifier: {err}; nothing applied", file=sys.stderr)
        prev = load_state() or {"schemaVersion": 1}
        prev["lastError"] = err
        prev["lastErrorAt"] = int(time.time())
        save_state(prev)
        return 3

    p = build_palette(theme)
    theme_name = display_name(THEME_DIR)

    prev = load_state()
    gsettings = {"applied": False,
                 "saved": prev.get("gsettings", {}).get("saved")}
    if not NO_GSETTINGS and not usable_saved(gsettings["saved"]):
        captured = {"color-scheme": gsettings_get("color-scheme"),
                    "gtk-theme": gsettings_get("gtk-theme")}
        gsettings["saved"] = captured if usable_saved(captured) else None
        if gsettings["saved"]:
            early = dict(prev) if prev else {"schemaVersion": 1}
            early["gsettings"] = {"applied": False, "saved": gsettings["saved"]}
            save_state(early)

    s4 = write_managed(GTK4_CSS, render_block(gtk4_defines(p)))
    s3 = write_managed(GTK3_CSS, render_block(gtk3_defines(p)))

    if not NO_GSETTINGS:
        scheme = "prefer-light" if p["mode"] == "light" else "prefer-dark"
        gtk_theme = "Adwaita" if p["mode"] == "light" else "Adwaita-dark"
        ok1 = gsettings_set("color-scheme", scheme)
        ok2 = gsettings_set("gtk-theme", gtk_theme)
        gsettings.update({"applied": ok1 and ok2,
                          "color_scheme": scheme, "gtk_theme": gtk_theme})

    changed = s4 in ("created", "updated", "merged") or s3 in ("created", "updated", "merged")
    restarted, pending, prompted = ([], [], False)
    if not no_restart and changed:
        restarted, pending, prompted = refresh_apps()

    state = {
        "schemaVersion": 1,
        "generatedAt": int(time.time()),
        "generatedAtIso": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "theme": theme_name,
        "mode": p["mode"],
        "palette": {
            k: p[k] for k in (
                "window_bg", "view_bg", "headerbar_bg", "surface_bg",
                "sidebar_bg", "fg", "fg_window", "fg_view", "fg_headerbar",
                "fg_sidebar", "fg_surface", "muted_safe", "accent",
                "accent_text", "on_accent", "red", "green", "yellow",
                "success_text", "warning_text", "error_text", "link_text")
        },
        "files": {
            "gtk4": {"path": str(GTK4_CSS), "status": s4},
            "gtk3": {"path": str(GTK3_CSS), "status": s3},
        },
        "gsettings": gsettings,
        "restarts": {"restarted": restarted, "pending": pending,
                     "nautilus_prompt": prompted},
    }
    save_state(state)

    if not quiet:
        extra = ""
        if restarted:
            extra += f", restarted {','.join(restarted)}"
        if prompted:
            extra += ", Nautilus prompt shown"
        if pending:
            extra += f", pending {','.join(sorted(set(pending)))}"
        print(f"colors-unifier: {theme_name} ({p['mode']}) → gtk4 {s4}, gtk3 {s3}{extra}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--no-restart", action="store_true",
                    help="do not restart daemons or prompt for Nautilus")
    ap.add_argument("--no-prompt", action="store_true",
                    help="never show the Nautilus prompt")
    ap.add_argument("--revert", action="store_true",
                    help="remove everything this tool wrote and restore saved settings")
    ap.add_argument("--status", action="store_true",
                    help="read-only report")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--nautilus-prompt", action="store_true",
                    help=argparse.SUPPRESS)
    args = ap.parse_args()

    global NO_PROMPT
    if args.no_prompt:
        NO_PROMPT = True
    if args.nautilus_prompt:
        return nautilus_prompt()
    if args.status:
        return do_status()
    if args.revert:
        return do_revert()
    return apply(args.no_restart, args.quiet)


if __name__ == "__main__":
    sys.exit(main())
