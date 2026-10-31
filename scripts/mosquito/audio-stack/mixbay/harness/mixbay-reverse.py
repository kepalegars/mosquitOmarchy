#!/usr/bin/env python3
"""mixbay-reverse — guided USB reverse-engineering harness for audio interfaces.

What it really does
-------------------
1. Lists USB devices and resolves the card by name/VID:PID.
2. Captures the *text* usbmon stream (``/sys/kernel/debug/usb/usbmon/<bus>u``)
   and keeps only the selected device's URBs.
3. Captures a quiet baseline, then the action the user performs once.
4. Diffs the two captures: new transfers, and same-request/different-payload
   transfers (a knob or a switch changing value).
5. Saves the labelled session under
   ``~/.config/mosquitomixbay/reverse/<card>/<timestamp>/``.
6. Replays *only captured bytes*, in the captured order, after an explicit
   confirmation. It never invents a frame.

The capture half needs root (usbmon). The script re-execs itself through
``sudo -E`` while preserving the invoking user's HOME through
``MIXBAY_REVERSE_HOME``. Replay uses pyusb (``python-usb``) and does not need
root when the card's udev rule grants access.

Examples
--------
    mixbay-reverse list
    mixbay-reverse capture --name "PreSonus Quantum ES 4" --match "Quantum ES"
    mixbay-reverse capture --vid 0x194f --pid 0x010d --label gain:input1
    mixbay-reverse sessions
    mixbay-reverse show gain:input1
    mixbay-reverse replay --label gain:input1 --dry-run
    mixbay-reverse replay --label gain:input1 --yes

Safety: replaying a captured write can change hardware state. Lower monitor
volume first. The harness only replays observed traffic, but the observed
traffic may still be a dangerous sequence if it was captured while the vendor
app was doing something else.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import pwd
import queue
import re
import shutil
import subprocess
import sys
import threading
import time
from collections import defaultdict
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Iterable, Sequence

DEBUGFS = Path("/sys/kernel/debug/usb/usbmon")
STATE_DIR = Path(".config/mosquitomixbay/reverse")
ADDR_RE = re.compile(r"^(?P<kind>[A-Za-z])(?P<dir>[io]):(?P<bus>\d+):(?P<dev>\d+):(?P<ep>\d+)$")
HEX_RE = re.compile(r"^[0-9a-fA-F]+$")

XFer = str  # control / bulk / interrupt / iso
KIND = {"C": "control", "B": "bulk", "I": "interrupt", "Z": "iso"}
DIRECTION = {"i": "in", "o": "out"}


# ---------------------------------------------------------------------------
# output / errors
# ---------------------------------------------------------------------------

def say(msg: str = "") -> None:
    try:
        print(msg, flush=True)
    except BrokenPipeError:
        # `mixbay-reverse list | head` is normal; exit quietly.
        raise SystemExit(0)


def warn(msg: str) -> None:
    print(f"! {msg}", file=sys.stderr, flush=True)


def die(msg: str, code: int = 2) -> "None":
    warn(msg)
    raise SystemExit(code)


def ask(msg: str, default: str = "") -> str:
    try:
        got = input(msg).strip()
    except EOFError:
        return default
    return got or default


def confirm(question: str, expected: str = "yes") -> bool:
    got = ask(f"{question} Type {expected!r} to continue: ")
    return got == expected


# ---------------------------------------------------------------------------
# privilege / paths
# ---------------------------------------------------------------------------

def invoking_home() -> Path:
    """The user's home even after sudo/pkexec reset HOME."""
    forced = os.environ.get("MIXBAY_REVERSE_HOME")
    if forced:
        return Path(forced).expanduser()
    sudo_user = os.environ.get("SUDO_USER")
    if os.geteuid() == 0 and sudo_user:
        try:
            return Path(pwd.getpwnam(sudo_user).pw_dir)
        except KeyError:
            pass
    return Path.home()


def state_root() -> Path:
    return invoking_home() / STATE_DIR


def ensure_root(argv: Sequence[str]) -> None:
    """Re-exec through sudo -E for the commands that touch usbmon."""
    if os.geteuid() == 0:
        return
    env = os.environ.copy()
    env["MIXBAY_REVERSE_HOME"] = str(invoking_home())
    sudo = shutil.which("sudo")
    if not sudo:
        die("usbmon capture needs root and sudo is not installed")
    os.execvpe(sudo, [sudo, "-E", sys.executable, str(Path(__file__).resolve()), *argv], env)


# ---------------------------------------------------------------------------
# usbmon
# ---------------------------------------------------------------------------

@dataclass
class UsbDevice:
    bus: int
    dev: int
    vid: int
    pid: int
    manufacturer: str = ""
    product: str = ""
    serial: str = ""
    sysfs: str = ""

    @property
    def label(self) -> str:
        name = self.product or self.manufacturer or "USB device"
        return f"{name} [{self.vid:04x}:{self.pid:04x}] bus {self.bus} dev {self.dev}"


def _read(path: Path, default: str = "") -> str:
    try:
        return path.read_text(errors="replace").strip()
    except OSError:
        return default


def list_usb_devices() -> list[UsbDevice]:
    out: list[UsbDevice] = []
    for entry in sorted(glob.glob("/sys/bus/usb/devices/*")):
        p = Path(entry)
        vid_s = _read(p / "idVendor")
        pid_s = _read(p / "idProduct")
        if not vid_s or not pid_s:
            continue
        try:
            bus = int(_read(p / "busnum"))
            dev = int(_read(p / "devnum"))
            vid = int(vid_s, 16)
            pid = int(pid_s, 16)
        except ValueError:
            continue
        out.append(UsbDevice(
            bus=bus, dev=dev, vid=vid, pid=pid,
            manufacturer=_read(p / "manufacturer"),
            product=_read(p / "product"),
            serial=_read(p / "serial"),
            sysfs=str(p),
        ))
    out.sort(key=lambda d: (d.bus, d.dev))
    return out


def find_device(args: argparse.Namespace, prompt: bool = True) -> UsbDevice:
    devs = list_usb_devices()
    if args.vid is not None or args.pid is not None:
        want_vid = args.vid
        want_pid = args.pid
        devs = [d for d in devs
                if (want_vid is None or d.vid == want_vid)
                and (want_pid is None or d.pid == want_pid)]
    if args.bus is not None:
        devs = [d for d in devs if d.bus == args.bus]
    if args.dev is not None:
        devs = [d for d in devs if d.dev == args.dev]
    needles = [n for n in (args.name, args.match) if n]
    if needles:
        def hit(d: UsbDevice, all_needles: bool) -> bool:
            hay = " ".join((d.product, d.manufacturer, d.serial)).lower()
            checks = [n.lower() in hay for n in needles]
            return all(checks) if all_needles else any(checks)
        strict = [d for d in devs if hit(d, True)]
        devs = strict or [d for d in devs if hit(d, False)]
    if not devs:
        die("no matching USB device (check lsusb / the card name)")
    if len(devs) == 1:
        return devs[0]
    say("Several USB devices match:")
    for i, d in enumerate(devs, 1):
        say(f"  {i:2d}. {d.label}")
    if not prompt or not sys.stdin.isatty():
        die("ambiguous device; pass --bus and --dev")
    choice = ask(f"Select 1-{len(devs)} [1]: ", "1")
    try:
        return devs[int(choice) - 1]
    except (ValueError, IndexError):
        die("invalid choice")


def ensure_usbmon() -> None:
    if DEBUGFS.is_dir():
        return
    subprocess.run(["modprobe", "usbmon"], check=False,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if DEBUGFS.is_dir():
        return
    # Debugfs is not always mounted; usbmon's text API lives there.
    subprocess.run(["mount", "-t", "debugfs", "none", "/sys/kernel/debug"],
                   check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if not DEBUGFS.is_dir():
        die("usbmon is unavailable (load the usbmon module and mount debugfs)")


@dataclass
class Event:
    urb: str
    ts: float
    event: str
    xfer: XFer
    direction: str
    bus: int
    dev: int
    ep: int
    status: int | None
    setup: list[int] | None
    data: bytes


@dataclass
class Transfer:
    """One completed URB, merged from its submission and callback."""
    ts: float
    xfer: XFer
    direction: str
    bus: int
    dev: int
    ep: int
    setup: list[int] | None
    data: bytes
    status: int | None

    def prefix(self) -> tuple:
        return (self.xfer, self.direction, self.ep, tuple(self.setup or ()))

    def signature(self) -> tuple:
        return self.prefix() + (self.data,)

    def summary(self) -> str:
        setup = ""
        if self.setup:
            bm, req, val, idx, ln = self.setup
            setup = f" setup={bm:02x}/{req:02x} val={val:04x} idx={idx:04x} len={ln}"
        payload = self.data.hex() if self.data else ""
        if len(payload) > 96:
            payload = payload[:96] + "…"
        return (f"{self.xfer:9s} {self.direction:3s} ep=0x{self.ep:02x}"
                f"{setup} data={payload or '-'}")


def parse_event(line: str) -> Event | None:
    parts = line.split()
    if len(parts) < 6:
        return None
    urb, ts_s, event, addr = parts[0], parts[1], parts[2], parts[3]
    m = ADDR_RE.match(addr)
    if not m or event not in ("S", "C", "E"):
        return None
    kind = m.group("kind").upper()
    if kind not in KIND:
        return None
    try:
        ts = float(ts_s) / 1_000_000.0
        bus, dev, ep = int(m.group("bus")), int(m.group("dev")), int(m.group("ep"))
    except ValueError:
        return None
    xfer = KIND[kind]
    direction = DIRECTION[m.group("dir")]
    idx = 4
    status_word = parts[idx]
    idx += 1
    setup = None
    # A control submission carries the five setup words before the length.
    if event == "S" and xfer == "control" and not re.fullmatch(r"-?\d+", status_word):
        if len(parts) < idx + 6:
            return None
        words = parts[idx:idx + 5]
        if status_word == "s":
            try:
                setup = [int(w, 16) for w in words]
            except ValueError:
                return None
        idx += 5
    try:
        length = int(parts[idx])
    except (IndexError, ValueError):
        length = 0
    idx += 1
    data = b""
    if idx < len(parts) and parts[idx] == "=":
        words = []
        for w in parts[idx + 1:]:
            if not HEX_RE.fullmatch(w):
                break
            words.append(w)
        if words:
            data = bytes.fromhex("".join(words))
    status = None
    if re.fullmatch(r"-?\d+", status_word):
        status = int(status_word)
    return Event(urb=urb, ts=ts, event=event, xfer=xfer, direction=direction,
                 bus=bus, dev=dev, ep=ep, status=status, setup=setup, data=data)


def merge_events(events: Iterable[Event]) -> list[Transfer]:
    """Merge S/C events by URB id. Missing callbacks are dropped."""
    pending: dict[str, Event] = {}
    out: list[Transfer] = []
    for ev in events:
        if ev.event == "S":
            pending[ev.urb] = ev
            continue
        if ev.event != "C":
            continue
        sub = pending.pop(ev.urb, None)
        if sub is None:
            continue
        # Isochronous audio streaming would flood a control-plane capture;
        # keep control/bulk/interrupt only.
        if sub.xfer == "iso":
            continue
        # IN data arrives on the callback, OUT data on the submission.
        data = sub.data if sub.direction == "out" else ev.data
        setup = sub.setup if sub.xfer == "control" else None
        out.append(Transfer(ts=sub.ts, xfer=sub.xfer, direction=sub.direction,
                            bus=sub.bus, dev=sub.dev, ep=sub.ep,
                            setup=setup, data=data, status=ev.status))
    return out


def capture(dev: UsbDevice, seconds: float) -> list[Transfer]:
    ensure_usbmon()
    path = DEBUGFS / f"{dev.bus}u"
    if not path.exists():
        die(f"usbmon bus file missing: {path}")
    proc = subprocess.Popen(["cat", str(path)], stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, text=True, bufsize=1)
    lines: queue.Queue[str] = queue.Queue()

    def reader() -> None:
        assert proc.stdout is not None
        for line in proc.stdout:
            lines.put(line)

    threading.Thread(target=reader, daemon=True).start()
    events: list[Event] = []
    deadline = time.monotonic() + max(0.1, seconds)
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            try:
                line = lines.get(timeout=remaining)
            except queue.Empty:
                break
            ev = parse_event(line)
            if ev and ev.bus == dev.bus and ev.dev == dev.dev:
                events.append(ev)
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()
    return merge_events(events)


def diff_candidates(baseline: Sequence[Transfer],
                    action: Sequence[Transfer]) -> list[Transfer]:
    """New signatures, plus same request with a different payload.

    Periodic polling (same request, same payload) is discarded. Same request
    with a different payload is exactly what a knob or a switch looks like.
    """
    base_sigs = {t.signature() for t in baseline}
    base_prefix_data: dict[tuple, set[bytes]] = defaultdict(set)
    for t in baseline:
        base_prefix_data[t.prefix()].add(t.data)
    out: list[Transfer] = []
    for t in action:
        if t.signature() in base_sigs:
            continue
        known = base_prefix_data.get(t.prefix())
        if known is not None and t.data in known:
            continue
        out.append(t)
    return out


# ---------------------------------------------------------------------------
# storage
# ---------------------------------------------------------------------------

def slug(text: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return s or "card"


def card_dir(dev: UsbDevice) -> Path:
    return state_root() / slug(f"{dev.product or dev.manufacturer}-{dev.vid:04x}-{dev.pid:04x}")


def _write_json(path: Path, obj: object) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(obj, indent=2, sort_keys=True) + "\n")
    os.replace(tmp, path)


def _write_jsonl(path: Path, rows: Iterable[dict]) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w") as fh:
        for row in rows:
            fh.write(json.dumps(row, sort_keys=True) + "\n")
    os.replace(tmp, path)


def transfer_row(t: Transfer) -> dict:
    return asdict(t) | {"data": t.data.hex(), "setup": t.setup}


def row_transfer(row: dict) -> Transfer:
    return Transfer(ts=float(row["ts"]), xfer=row["xfer"],
                    direction=row["direction"], bus=int(row["bus"]),
                    dev=int(row["dev"]), ep=int(row["ep"]),
                    setup=row.get("setup"), data=bytes.fromhex(row.get("data", "")),
                    status=row.get("status"))


def save_session(dev: UsbDevice, label: str, baseline: Sequence[Transfer],
                 action: Sequence[Transfer], candidates: Sequence[Transfer],
                 rng: dict, notes: str) -> Path:
    root = card_dir(dev)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    out = root / stamp
    out.mkdir(parents=True, exist_ok=False)
    meta = {
        "device": asdict(dev),
        "label": label,
        "range": rng,
        "notes": notes,
        "created": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "baseline_count": len(baseline),
        "action_count": len(action),
        "candidate_count": len(candidates),
        "tool": "mixbay-reverse",
    }
    _write_json(out / "meta.json", meta)
    _write_jsonl(out / "baseline.jsonl", (transfer_row(t) for t in baseline))
    _write_jsonl(out / "action.jsonl", (transfer_row(t) for t in action))
    _write_jsonl(out / "candidates.jsonl", (transfer_row(t) for t in candidates))
    # Human-readable capture, useful in a bug report or a protocol document.
    with (out / "capture.txt").open("w") as fh:
        fh.write(f"# {dev.label}\n# label: {label}\n\n[baseline]\n")
        for t in baseline:
            fh.write(t.summary() + "\n")
        fh.write("\n[action]\n")
        for t in action:
            fh.write(t.summary() + "\n")
        fh.write("\n[candidates]\n")
        for t in candidates:
            fh.write(t.summary() + "\n")
    # Map label -> latest session for replay/show.
    map_path = root / "map.json"
    try:
        state = json.loads(map_path.read_text())
    except (OSError, json.JSONDecodeError):
        state = {}
    state.setdefault("device", asdict(dev))
    state.setdefault("labels", {})[label] = {
        "session": str(out),
        "range": rng,
        "updated": meta["created"],
    }
    _write_json(map_path, state)
    return out


def load_session(path: Path) -> tuple[dict, list[Transfer], list[Transfer], list[Transfer]]:
    try:
        meta = json.loads((path / "meta.json").read_text())
    except (OSError, json.JSONDecodeError) as exc:
        die(f"not a session: {path}: {exc}")
    def rows(name: str) -> list[Transfer]:
        p = path / name
        if not p.exists():
            return []
        return [row_transfer(json.loads(line)) for line in p.read_text().splitlines() if line.strip()]
    return meta, rows("baseline.jsonl"), rows("action.jsonl"), rows("candidates.jsonl")


def resolve_label(label: str) -> tuple[Path, dict]:
    root = state_root()
    for map_path in root.glob("*/map.json"):
        try:
            state = json.loads(map_path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        entry = (state.get("labels") or {}).get(label)
        if entry:
            return Path(entry["session"]), entry
    die(f"no captured label {label!r}; run `mixbay-reverse sessions`")


def sessions() -> list[dict]:
    out: list[dict] = []
    for map_path in sorted(state_root().glob("*/map.json")):
        try:
            state = json.loads(map_path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        for label, entry in sorted((state.get("labels") or {}).items()):
            out.append({"label": label, "session": entry.get("session", ""),
                        "device": state.get("device", {}), "range": entry.get("range", {})})
    return out


# ---------------------------------------------------------------------------
# replay
# ---------------------------------------------------------------------------

def replay_window(action: Sequence[Transfer], candidates: Sequence[Transfer]) -> list[Transfer]:
    if not action:
        return []
    if not candidates:
        return list(action)
    # Candidates may come from a separate JSONL read, so match by signature
    # rather than object identity.
    wanted = {c.signature() for c in candidates}
    indexes = [i for i, t in enumerate(action) if t.signature() in wanted]
    if not indexes:
        return list(action)
    first, last = indexes[0], indexes[-1]
    # Keep the captured order between the first and last candidate, including
    # the GETs/acks in between (read-modify-write sequences).
    return list(action[first:last + 1])


def _usb():
    try:
        import usb.core  # type: ignore
        import usb.util  # type: ignore
    except Exception as exc:  # noqa: BLE001
        die(f"pyusb is required for replay ({exc}); install python-pyusb")
    return usb.core, usb.util


def _open_usb(dev: UsbDevice, interface: int, detach: bool):
    usb_core, usb_util = _usb()
    kwargs = {"idVendor": dev.vid, "idProduct": dev.pid,
              "bus": dev.bus, "address": dev.dev}
    handle = usb_core.find(**kwargs)
    if handle is None:
        # Bus/devnum changes after a re-enumeration; fall back to the stable
        # VID:PID (and serial when present).
        kwargs.pop("bus", None)
        kwargs.pop("address", None)
        if dev.serial:
            kwargs["serial_number"] = dev.serial
        handle = usb_core.find(**kwargs)
    if handle is None:
        die("device not found by pyusb (unplugged, re-enumerated, or vendor class hidden)")
    try:
        handle.set_configuration()
    except Exception:
        pass
    if detach:
        try:
            if handle.is_kernel_driver_active(interface):
                handle.detach_kernel_driver(interface)
        except Exception as exc:  # noqa: BLE001
            warn(f"could not detach kernel driver {interface}: {exc}")
    return handle, usb_util


def replay(dev: UsbDevice, transfers: Sequence[Transfer], *, dry_run: bool,
           yes: bool, verify: bool, interface: int, detach: bool) -> int:
    if not transfers:
        die("nothing to replay")
    say(f"Replay window: {len(transfers)} captured transfer(s) on {dev.label}")
    for i, t in enumerate(transfers, 1):
        say(f"  {i:3d}. {t.summary()}")
    if dry_run:
        say("\nDry run only; nothing was sent.")
        return 0
    if not yes and not confirm(
            "Replay ONLY these captured bytes? Lower monitors first.", "REPLAY"):
        say("Cancelled.")
        return 1
    handle, _ = _open_usb(dev, interface, detach)
    previous_ts = transfers[0].ts
    failures = 0
    for t in transfers:
        # Preserve the captured rhythm, but never stall on a long idle gap.
        time.sleep(max(0.0, min(t.ts - previous_ts, 0.05)))
        previous_ts = t.ts
        try:
            if t.xfer == "control":
                if not t.setup:
                    warn("control transfer without setup; skipped")
                    continue
                bm, req, val, idx, length = t.setup
                if t.direction == "out":
                    got = handle.ctrl_transfer(bm, req, val, idx, t.data, timeout=2000)
                else:
                    got = bytes(handle.ctrl_transfer(bm, req, val, idx, length, timeout=2000))
                    if verify and t.data and got != t.data:
                        warn(f"readback mismatch: got {got.hex()} want {t.data.hex()}")
                        failures += 1
            elif t.direction == "out":
                handle.write(t.ep, t.data, timeout=2000)
            else:
                got = bytes(handle.read(t.ep, max(1, len(t.data)), timeout=2000))
                if verify and t.data and got != t.data:
                    warn(f"readback mismatch: got {got.hex()} want {t.data.hex()}")
                    failures += 1
        except Exception as exc:  # noqa: BLE001
            warn(f"transfer failed ({t.summary()}): {exc}")
            failures += 1
    say(f"\nReplay finished: {len(transfers) - failures}/{len(transfers)} ok"
        f"{f', {failures} failure(s)' if failures else ''}.")
    return 0 if failures == 0 else 1


# ---------------------------------------------------------------------------
# commands
# ---------------------------------------------------------------------------

def cmd_list(args: argparse.Namespace) -> int:
    for d in list_usb_devices():
        say(f"{d.bus:03d}:{d.dev:03d}  {d.vid:04x}:{d.pid:04x}  {d.label}")
    return 0


def cmd_sessions(args: argparse.Namespace) -> int:
    rows = sessions()
    if args.json:
        say(json.dumps(rows, indent=2))
        return 0
    if not rows:
        say("No captured sessions yet.")
        return 0
    for r in rows:
        product = r["device"].get("product") or r["device"].get("manufacturer") or "?"
        say(f"{r['label']:24s}  {product}  {r['session']}")
    return 0


def cmd_show(args: argparse.Namespace) -> int:
    path, entry = resolve_label(args.label)
    meta, baseline, action, candidates = load_session(path)
    say(f"label   : {args.label}")
    say(f"device  : {meta.get('device', {}).get('label') or meta.get('device')}")
    say(f"session : {path}")
    say(f"range   : {entry.get('range')}")
    say(f"counts  : baseline={len(baseline)} action={len(action)} candidates={len(candidates)}")
    say("\nCandidates:")
    for i, t in enumerate(candidates, 1):
        say(f"  {i:3d}. {t.summary()}")
    return 0


def cmd_capture(args: argparse.Namespace) -> int:
    ensure_root(sys.argv[1:])
    dev = find_device(args)
    say(f"Device : {dev.label}")
    say(f"Bus    : {dev.bus}  devnum {dev.dev}")
    say(f"Config : baseline {args.baseline:.1f}s, action {args.action:.1f}s")
    say("\nBaseline: leave the card alone (do not touch the vendor app).")
    say("Capturing baseline…")
    baseline = capture(dev, args.baseline)
    say(f"  {len(baseline)} transfer(s).")
    say("\nAction: perform ONE control change now (one knob, one switch, one")
    say("button). If you need the vendor app, run it in the Windows VM with USB")
    say("passthrough; the host sees the traffic through usbmon.")
    ask("Press Enter when you are ready to start the action capture…")
    say("Capturing action…")
    action = capture(dev, args.action)
    say(f"  {len(action)} transfer(s).")
    candidates = diff_candidates(baseline, action)
    if not candidates:
        warn("no new/changed transfer found. Nothing was saved.")
        warn("Try a longer --action window, or check that the vendor app is talking to this card.")
        return 1
    say(f"\n{len(candidates)} candidate transfer(s):")
    for i, t in enumerate(candidates, 1):
        say(f"  {i:3d}. {t.summary()}")
    label = args.label or ask("\nLabel (e.g. gain:input1, volume:output1, phantom:input1): ")
    if not label:
        die("a label is required to save the session")
    rng = {
        "min": args.min if args.min is not None else ask("Min value [0]: ", "0"),
        "max": args.max if args.max is not None else ask("Max value [255]: ", "255"),
        "unit": args.unit or ask("Unit (dB, %, bool, raw) [raw]: ", "raw"),
    }
    notes = args.notes or ask("Notes (optional): ")
    path = save_session(dev, label, baseline, action, candidates, rng, notes)
    say(f"\nSaved: {path}")
    say(f"Label: {label}")
    say("Review capture.txt, then replay with:")
    say(f"  mixbay-reverse replay --label {label} --dry-run")
    return 0


def cmd_replay(args: argparse.Namespace) -> int:
    if args.session:
        path = Path(args.session).expanduser()
        meta, _, action, candidates = load_session(path)
        dev = UsbDevice(**meta["device"])
    else:
        if not args.label:
            die("pass --label or --session")
        path, _ = resolve_label(args.label)
        meta, _, action, candidates = load_session(path)
        dev = UsbDevice(**meta["device"])
    window = replay_window(action, candidates)
    return replay(dev, window, dry_run=args.dry_run, yes=args.yes,
                   verify=args.verify, interface=args.interface, detach=args.detach)


def cmd_delete(args: argparse.Namespace) -> int:
    path, _ = resolve_label(args.label)
    if not args.yes and not confirm(f"Delete captured session {path}?", "DELETE"):
        say("Cancelled.")
        return 1
    shutil.rmtree(path, ignore_errors=True)
    # Remove the label from the map; keep the map for the other labels.
    map_path = path.parent / "map.json"
    if map_path.exists():
        try:
            state = json.loads(map_path.read_text())
            state.get("labels", {}).pop(args.label, None)
            _write_json(map_path, state)
        except (OSError, json.JSONDecodeError):
            pass
    say("Deleted.")
    return 0


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="mixbay-reverse",
        description="Guided usbmon capture / replay harness for audio interfaces.",
        epilog="Replay only re-sends bytes observed in a capture. Never invent frames.",
    )
    sub = p.add_subparsers(dest="cmd", required=True)

    lst = sub.add_parser("list", help="list USB devices")
    lst.set_defaults(func=cmd_list)

    cap = sub.add_parser("capture", help="capture baseline + one action")
    cap.add_argument("--name", default="", help="substring of product/manufacturer")
    cap.add_argument("--match", default="", help="ALSA/card name substring")
    cap.add_argument("--vid", type=lambda s: int(s, 0), default=None)
    cap.add_argument("--pid", type=lambda s: int(s, 0), default=None)
    cap.add_argument("--bus", type=int, default=None)
    cap.add_argument("--dev", type=int, default=None)
    cap.add_argument("--baseline", type=float, default=3.0)
    cap.add_argument("--action", type=float, default=6.0)
    cap.add_argument("--label", default="")
    cap.add_argument("--min", default=None)
    cap.add_argument("--max", default=None)
    cap.add_argument("--unit", default=None)
    cap.add_argument("--notes", default="")
    cap.set_defaults(func=cmd_capture)

    ses = sub.add_parser("sessions", help="list captured labels")
    ses.add_argument("--json", action="store_true")
    ses.set_defaults(func=cmd_sessions)

    show = sub.add_parser("show", help="show one captured label")
    show.add_argument("label")
    show.set_defaults(func=cmd_show)

    rep = sub.add_parser("replay", help="replay one captured window")
    rep.add_argument("--label", default="")
    rep.add_argument("--session", default="")
    rep.add_argument("--dry-run", action="store_true")
    rep.add_argument("--yes", action="store_true")
    rep.add_argument("--verify", action="store_true", help="compare IN readbacks")
    rep.add_argument("--interface", type=int, default=0)
    rep.add_argument("--detach", action="store_true", help="detach the kernel driver")
    rep.set_defaults(func=cmd_replay)

    dele = sub.add_parser("delete", help="delete one captured label")
    dele.add_argument("label")
    dele.add_argument("--yes", action="store_true")
    dele.set_defaults(func=cmd_delete)
    return p


def main(argv: Sequence[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    args = build_parser().parse_args(argv)
    try:
        return int(args.func(args))
    except KeyboardInterrupt:
        warn("interrupted")
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
