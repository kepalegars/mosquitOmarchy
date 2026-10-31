#!/usr/bin/env python3
"""Tests for the mixbay-reverse harness — no USB hardware required."""

from __future__ import annotations

import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "mixbay-reverse.py"
spec = importlib.util.spec_from_file_location("mixbay_reverse", SCRIPT)
assert spec and spec.loader
mr = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = mr
spec.loader.exec_module(mr)


class ParseTests(unittest.TestCase):
    def test_control_in(self):
        lines = [
            "d5ea89a0 3575914555 S Ci:1:001:0 s a3 00 0000 0003 0004 4 <",
            "d5ea89a0 3575914560 C Ci:1:001:0 0 4 = 01050000",
        ]
        events = [mr.parse_event(line) for line in lines]
        self.assertTrue(all(events))
        tx = mr.merge_events(events)
        self.assertEqual(len(tx), 1)
        t = tx[0]
        self.assertEqual((t.xfer, t.direction, t.bus, t.dev, t.ep),
                         ("control", "in", 1, 1, 0))
        self.assertEqual(t.setup, [0xA3, 0x00, 0x0000, 0x0003, 0x0004])
        self.assertEqual(t.data, bytes.fromhex("01050000"))
        self.assertEqual(t.status, 0)

    def test_control_out(self):
        lines = [
            "aa 42 S Co:1:002:0 s 40 01 0000 0000 0002 2 = 0102",
            "aa 45 C Co:1:002:0 0 2 >",
        ]
        t = mr.merge_events([mr.parse_event(line) for line in lines])[0]
        self.assertEqual((t.xfer, t.direction), ("control", "out"))
        self.assertEqual(t.setup, [0x40, 0x01, 0x0000, 0x0000, 0x0002])
        self.assertEqual(t.data, bytes.fromhex("0102"))

    def test_bulk_out(self):
        lines = [
            "bb 100 S Bo:1:003:2 -115 4 = deadbeef",
            "bb 110 C Bo:1:003:2 0 4 >",
        ]
        t = mr.merge_events([mr.parse_event(line) for line in lines])[0]
        self.assertEqual((t.xfer, t.direction, t.ep), ("bulk", "out", 2))
        self.assertEqual(t.data, bytes.fromhex("deadbeef"))

    def test_interrupt_in(self):
        lines = [
            "cc 200 S Ii:1:004:1 0 8 <",
            "cc 210 C Ii:1:004:1 0 8 = 0102030405060708",
        ]
        t = mr.merge_events([mr.parse_event(line) for line in lines])[0]
        self.assertEqual((t.xfer, t.direction), ("interrupt", "in"))
        self.assertEqual(t.data, bytes.fromhex("0102030405060708"))

    def test_missing_callback_is_dropped(self):
        ev = mr.parse_event("dd 1 S Ci:1:005:0 s 80 06 0100 0000 0012 18 <")
        self.assertEqual(mr.merge_events([ev]), [])


class DiffTests(unittest.TestCase):
    def t(self, setup, data, direction="in"):
        return mr.Transfer(ts=0, xfer="control", direction=direction,
                           bus=1, dev=1, ep=0, setup=list(setup),
                           data=bytes(data), status=0)

    def test_same_request_new_payload_is_candidate(self):
        get = [0xA1, 1, 0x0200, 0, 2]
        base = [self.t(get, b"\x00\x00")]
        action = [self.t(get, b"\x10\x00")]
        cand = mr.diff_candidates(base, action)
        self.assertEqual(len(cand), 1)
        self.assertEqual(cand[0].data, b"\x10\x00")

    def test_identical_periodic_poll_is_ignored(self):
        get = [0xA1, 1, 0x0200, 0, 2]
        base = [self.t(get, b"\x00\x00")]
        action = [self.t(get, b"\x00\x00")]
        self.assertEqual(mr.diff_candidates(base, action), [])

    def test_new_write_is_candidate(self):
        setvol = [0x40, 2, 0x0300, 1, 2]
        base = []
        action = [self.t(setvol, b"\x20\x00", direction="out")]
        self.assertEqual(len(mr.diff_candidates(base, action)), 1)


class DiscoveryTests(unittest.TestCase):
    def test_channels_and_guided_steps(self):
        cards = [{
            "name": "alsa_card.usb-PreSonus_Quantum_ES_4-00",
            "active_profile": "output:analog-stereo+input:analog-stereo",
            "properties": {"alsa.card_name": "Quantum ES 4",
                           "device.description": "PreSonus Quantum ES 4"},
        }]
        sinks = [{
            "name": "alsa_output.usb-PreSonus",
            "description": "Quantum ES 4 Analog Stereo",
            "sample_specification": "s32le 2ch 48000Hz",
            "properties": {"alsa.card_name": "Quantum ES 4"},
        }]
        sources = [{
            "name": "alsa_input.usb-PreSonus",
            "description": "Quantum ES 4 Analog Stereo",
            "sample_specification": "s32le 4ch 48000Hz",
            "properties": {"alsa.card_name": "Quantum ES 4"},
        }]

        def fake(*args):
            return {"cards": cards, "sinks": sinks, "sources": sources}.get(args[-1], [])

        old = mr.pactl_json
        mr.pactl_json = fake
        try:
            dev = mr.UsbDevice(bus=1, dev=7, vid=0x194F, pid=0x010D,
                               manufacturer="PreSonus", product="Quantum ES 4")
            ch = mr.discover_channels(dev)
            self.assertEqual(ch["playback"], 2)
            self.assertEqual(ch["capture"], 4)
            self.assertIn("Quantum ES 4", ch["card"])
            steps = mr.guided_steps(ch)
            self.assertIn("gain:input4", steps)
            self.assertIn("volume:output2", steps)
            self.assertNotIn("volume:output3", steps)
        finally:
            mr.pactl_json = old


class ReplayWindowTests(unittest.TestCase):
    def test_keeps_the_get_between_candidates(self):
        rows = [
            mr.Transfer(0, "control", "in", 1, 1, 0, [0x80, 6, 0, 0, 1], b"a", 0),
            mr.Transfer(1, "control", "in", 1, 1, 0, [0xA1, 1, 0, 0, 1], b"b", 0),
            mr.Transfer(2, "control", "in", 1, 1, 0, [0xA1, 1, 0, 0, 1], b"c", 0),
            mr.Transfer(3, "control", "out", 1, 1, 0, [0x40, 2, 0, 0, 1], b"d", 0),
            mr.Transfer(4, "control", "in", 1, 1, 0, [0xA1, 1, 0, 0, 1], b"e", 0),
        ]
        # Candidates loaded from disk are distinct objects: match by signature.
        candidates = [rows[2], rows[3]]
        window = mr.replay_window(rows, candidates)
        self.assertEqual(window, rows[2:4])


class StorageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["MIXBAY_REVERSE_HOME"] = self.tmp.name

    def tearDown(self):
        os.environ.pop("MIXBAY_REVERSE_HOME", None)
        self.tmp.cleanup()

    def test_save_load_and_map(self):
        dev = mr.UsbDevice(bus=1, dev=7, vid=0x194F, pid=0x010D,
                           manufacturer="PreSonus", product="Quantum ES 4")
        base = [mr.Transfer(0, "control", "in", 1, 7, 0,
                            [0xA1, 1, 0, 0, 1], b"\x00", 0)]
        action = [mr.Transfer(1, "control", "out", 1, 7, 0,
                              [0x40, 2, 0, 0, 1], b"\x10", 0)]
        cand = [action[0]]
        path = mr.save_session(dev, "gain:input1", base, action, cand,
                               {"min": 0, "max": 60, "unit": "dB"}, "test")
        self.assertTrue((path / "candidates.jsonl").exists())
        meta, b, a, c = mr.load_session(path)
        self.assertEqual(meta["label"], "gain:input1")
        self.assertEqual(len(b), 1)
        self.assertEqual(len(a), 1)
        self.assertEqual(c[0].data, b"\x10")
        rows = mr.sessions()
        self.assertEqual(rows[0]["label"], "gain:input1")
        got_path, entry = mr.resolve_label("gain:input1")
        self.assertEqual(got_path, path)
        self.assertEqual(entry["range"]["max"], 60)
        state = json.loads((path.parent / "map.json").read_text())
        self.assertEqual(state["labels"]["gain:input1"]["session"], str(path))


if __name__ == "__main__":
    unittest.main()
