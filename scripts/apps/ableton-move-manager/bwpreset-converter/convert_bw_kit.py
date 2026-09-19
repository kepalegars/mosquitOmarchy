#!/usr/bin/env python3
"""
convert_bw_kit.py — from one Bitwig Drum Machine .bwpreset, produce BOTH:
  - an Ableton Live Drum Rack .adg (via the same default-template logic as
    bwpreset_to_adg.py)
  - an Ableton Move preset bundle (the file L2Move itself produces — its
    real extension is .ablpresetbundle, not .ablbundle; Move's own JSON
    preset format, reverse-engineered directly from L2Move's source:
    MovePresetManager.cs / MovePreset.cs)

and organizes the results at the input file's location as:

    <folder containing your .bwpreset>/
        bwpreset/     <- a copy of the source .bwpreset
        adg/          <- name.adg + name_samples/*.wav
        ablpresetbundle/  <- name.ablpresetbundle  (already self-contained, samples included)

NOTE ON NOTES: Move's own drum rack format ignores the Bitwig pad note
entirely — Move always expects 16 pads mapped to a fixed range starting at
MIDI 36 (C1), in pad order. So for the .ablpresetbundle, pads are sorted by
Bitwig note (128 - PADn) descending and assigned notes 36..51 in that
order — exactly what L2Move does when it converts a normal Ableton rack.
The .adg still keeps the richer/more flexible per-pad note assignment from
its 16-slot reference template, unrelated to the fixed Move range.

USAGE
-----
    python3 convert_bw_kit.py mon_kit.bwpreset
    python3 convert_bw_kit.py --working-dir ~/Music/Ableton\\ Move\\ Projects \
        -o ~/Music/Ableton\\ Move\\ Projects/Presets mon_kit.bwpreset

The manager calls it as:

    convert_bw_kit.py --working-dir "$MOVE_DIR" -o "$MOVE_DIR/Presets" kit.bwpreset

All generated working folders/files live under the output root (defaults to
<working-dir>/Presets, created if missing):
    <out>/bwpreset/         copy of the source .bwpreset
    <out>/adg/              name.adg + name_samples/*.wav
    <out>/ablpresetbundle/  name.ablpresetbundle (self-contained)
"""
import struct
import re
import sys
import os
import zipfile
import io
import gzip
import zlib
import pickle
import json
import shutil
import argparse
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
TEMPLATE_PATH = os.path.join(HERE, "template_blocks.pkl")
# Subfolders created under the output root (<working-dir>/Presets by default).
BWPRESET_SUBDIR = "bwpreset"
ADG_SUBDIR = "adg"
BUNDLE_SUBDIR = "ablpresetbundle"

MOVE_SCHEMA = "http://tech.ableton.com/schema/song/1.4.4/devicePreset.json"


# ---------------------------------------------------------------------------
# Shared: parsing the .bwpreset
# ---------------------------------------------------------------------------

def find_zip_start(data):
    return data.find(b"PK\x03\x04")


def find_pads(data, end):
    """Return list of (pad_number:int, sample_display_name:str) sorted by
    note descending (pad_number ascending, since note = 128 - pad_number)."""
    pads = []
    for m in re.finditer(rb"PAD(\d+)", data[:end]):
        pos = m.start()
        padnum = int(m.group(1))
        window = data[pos : pos + 400]
        sample_name = None
        i = 0
        while i < len(window) - 5:
            if window[i] == 0x08:
                vlen = struct.unpack_from(">I", window, i + 1)[0]
                if 1 <= vlen <= 120 and i + 5 + vlen <= len(window):
                    candidate = window[i + 5 : i + 5 + vlen]
                    if all(32 <= b < 127 for b in candidate) and len(candidate) > 2:
                        sample_name = candidate.decode(errors="replace")
                        break
            i += 1
        if sample_name:
            pads.append((padnum, sample_name))
    pads.sort(key=lambda p: p[0])  # ascending pad number = descending note
    return pads


def extract_samples(data, zip_start, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    written = {}
    with zipfile.ZipFile(io.BytesIO(data[zip_start:])) as zf:
        for name in zf.namelist():
            if not name.lower().endswith((".wav", ".aif", ".aiff")):
                continue
            base = os.path.basename(name)
            content = zf.read(name)
            out_path = os.path.join(out_dir, base)
            with open(out_path, "wb") as f:
                f.write(content)
            display_name = os.path.splitext(base)[0]
            written[display_name] = (out_path, len(content), zlib.crc32(content))
    return written


def load_bwpreset(bw_path):
    data = open(bw_path, "rb").read()
    if not data.startswith(b"BtWg"):
        raise ValueError("not a valid Bitwig .bwpreset (missing 'BtWg' magic).")
    zip_start = find_zip_start(data)
    if zip_start == -1:
        raise ValueError("no embedded zip found (does this preset contain samples?).")
    pads = find_pads(data, zip_start)
    if not pads:
        raise ValueError("no PADn pad found in this preset.")
    return data, zip_start, pads


# ---------------------------------------------------------------------------
# .adg generation (Ableton Live Drum Rack, default-template based)
# ---------------------------------------------------------------------------

def patch_block(block_xml, sample_display_name, sample_path_abs, sample_path_rel, size, crc):
    block_xml = re.sub(
        r'(<Name Value=")[^"]*(" />\s*\n\s*<SourceContext)',
        lambda m: m.group(1) + sample_display_name.replace("&", "&amp;").replace('"', "&quot;") + m.group(2),
        block_xml,
        count=1,
    )
    if sample_display_name not in block_xml:
        block_xml = re.sub(
            r'<Name Value="[^"]+" />',
            f'<Name Value="{sample_display_name}" />',
            block_xml,
            count=1,
        )

    def esc(s):
        return s.replace("&", "&amp;").replace('"', "&quot;")

    rel = esc(sample_path_rel)
    absp = esc(sample_path_abs)

    block_xml = re.sub(r'<RelativePath Value="(?!")[^"]*\.(?:wav|aif|aiff)" />',
                        f'<RelativePath Value="{rel}" />', block_xml, flags=re.I)
    block_xml = re.sub(r'<Path Value="[^"]*\.(?:wav|aif|aiff)" />',
                        f'<Path Value="{absp}" />', block_xml, flags=re.I)
    block_xml = re.sub(r'<OriginalFileSize Value="\d+" />',
                        f'<OriginalFileSize Value="{size}" />', block_xml)
    block_xml = re.sub(r'<OriginalCrc Value="\d+" />',
                        f'<OriginalCrc Value="{crc}" />', block_xml)
    return block_xml


def load_template(template_path):
    """Load template_blocks.pkl, failing with a clear, actionable message.

    The pickle is Python-3 protocol 4 in the shipped copy. An older/Python-2
    pickle raises UnicodeDecodeError/ValueError; a missing file raises
    FileNotFoundError. Both are reported precisely rather than silently
    leaving the converter half-broken.
    """
    if not os.path.isfile(template_path):
        raise FileNotFoundError(
            f"template not found: {template_path}\n"
            f"Pass --template /path/to/template_blocks.pkl (it ships next to "
            f"this script in bwpreset-converter/)."
        )
    try:
        with open(template_path, "rb") as f:
            tpl = pickle.load(f)
    except (UnicodeDecodeError, ValueError, pickle.UnpicklingError, EOFError) as e:
        raise ValueError(
            f"could not read the template pickle {template_path}: {e}\n"
            f"It looks like an old/Python-2 pickle. Regenerate it on Python 3 "
            f"with: python3 -c \"import pickle; pickle.dump({{'full_xml': ..., "
            f"'blocks': [...]}}, open('template_blocks.pkl','wb'), protocol=4)\""
        ) from e
    if not isinstance(tpl, dict) or "full_xml" not in tpl or "blocks" not in tpl:
        raise ValueError(
            f"unexpected template structure in {template_path}: expected a dict "
            f"with 'full_xml' and 'blocks' keys."
        )
    return tpl


def build_adg(pads, extracted, out_adg_path, samples_out_dir, template_path=TEMPLATE_PATH):
    tpl = load_template(template_path)
    full_xml = tpl["full_xml"]

    def block_note(b):
        m = re.search(r'<ReceivingNote Value="(-?\d+)" />', b)
        return int(m.group(1)) if m else -9999

    template_blocks = sorted(tpl["blocks"], key=block_note, reverse=True)

    used_pads = pads[:16]
    if len(pads) > 16:
        print(f"[!] {len(pads)} pads found; only the 16 highest notes are used in the .adg.")

    samples_folder_name = os.path.basename(samples_out_dir.rstrip("/"))
    new_blocks = []
    for i, template_block in enumerate(template_blocks):
        if i < len(used_pads):
            padnum, sname = used_pads[i]
            if sname not in extracted:
                new_blocks.append(template_block)
                continue
            out_path, size, crc = extracted[sname]
            base = os.path.basename(out_path)
            rel_path = f"{samples_folder_name}/{base}"
            new_blocks.append(patch_block(template_block, sname, out_path, rel_path, size, crc))
        else:
            new_blocks.append(template_block)

    new_xml = full_xml
    for old, new in zip(template_blocks, new_blocks):
        new_xml = new_xml.replace(old, new, 1)

    with open(out_adg_path, "wb") as f:
        f.write(gzip.compress(new_xml.encode("utf-8")))


# ---------------------------------------------------------------------------
# .ablpresetbundle generation (Ableton Move), mirrors L2Move's
# MovePresetManager.cs / MovePreset.cs exactly
# ---------------------------------------------------------------------------

def _params_default():
    return {
        "Enabled": True,
        "Macro0": 0.0, "Macro1": 0.0, "Macro2": 0.0, "Macro3": 0.0,
        "Macro4": 0.0, "Macro5": 0.0, "Macro6": 0.0, "Macro7": 0.0,
    }


def _mixer_default(is_enabled=True):
    return {
        "pan": 0.0,
        "solo-cue": False,
        "speakerOn": True,
        "volume": 0.0,
        "sends": [{"isEnabled": is_enabled, "amount": -70.0}],
    }


def _drum_cell(sample_uri):
    return {
        "presetUri": None,
        "kind": "drumCell",
        "name": "",
        "parameters": {"Voice_Envelope_Hold": 60.0},
        "deviceData": {"sampleUri": sample_uri},
    }


def _reverb_return_chain():
    return {
        "name": "",
        "color": 0,
        "devices": [{
            "presetUri": None,
            "kind": "reverb",
            "name": "Reverb",
            "parameters": {},
            "deviceData": {},
        }],
        "mixer": _mixer_default(is_enabled=False),
    }


def build_move_preset_json(preset_name, ordered_sample_filenames):
    """ordered_sample_filenames: list of filenames (str), pad 0 = lowest
    Move note (36), in the order they should be laid out (i.e. same order
    L2Move uses: input order == pad order, note = 36 + index)."""
    drum_chains = []
    for i, fname in enumerate(ordered_sample_filenames):
        encoded = urllib.parse.quote(fname, safe="")
        sample_uri = f"Samples/{encoded}"
        drum_chains.append({
            "name": "",
            "color": 0,
            "devices": [_drum_cell(sample_uri)],
            "mixer": _mixer_default(is_enabled=True),
            "drumZoneSettings": {
                "receivingNote": 36 + i,
                "sendingNote": 60,
                "chokeGroup": None,
            },
        })

    drum_rack_device = {
        "presetUri": None,
        "kind": "drumRack",
        "name": "",
        "parameters": _params_default(),
        "chains": drum_chains,
        "returnChains": [_reverb_return_chain()],
    }

    saturator_device = {
        "presetUri": None,
        "kind": "saturator",
        "name": "Saturator",
        "parameters": {},
        "deviceData": {},
    }

    return {
        "$schema": MOVE_SCHEMA,
        "kind": "instrumentRack",
        "name": preset_name,
        "parameters": _params_default(),
        "chains": [{
            "name": "",
            "color": 0,
            "devices": [drum_rack_device, saturator_device],
            "mixer": {"pan": 0.0, "solo-cue": False, "speakerOn": True, "volume": 0.0, "sends": []},
        }],
    }


def build_move_bundle(pads, extracted, preset_name, out_bundle_path):
    used_pads = pads[:16]
    if len(pads) > 16:
        print(f"[!] {len(pads)} pads found; only the 16 highest notes are used in the .ablpresetbundle (Move has 16 fixed pads).")

    filenames = []
    sample_bytes = {}
    for padnum, sname in used_pads:
        if sname not in extracted:
            print(f"  [!] Sample '{sname}' not found in the embedded zip; pad skipped for the Move bundle.")
            continue
        out_path, size, crc = extracted[sname]
        base = os.path.basename(out_path)
        filenames.append(base)
        sample_bytes[base] = out_path

    preset = build_move_preset_json(preset_name, filenames)

    with zipfile.ZipFile(out_bundle_path, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("Preset.ablpreset", json.dumps(preset, indent=2))
        for base, path in sample_bytes.items():
            with open(path, "rb") as f:
                zf.writestr(f"Samples/{base}", f.read())


# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

def convert_one(bw_path, out_root, template_path, produce_adg=True, produce_bundle=True):
    """Convert a single .bwpreset, writing under out_root. Returns a result
    dict with the produced paths (adg / bundle, either may be "")."""
    base = os.path.splitext(os.path.basename(bw_path))[0]

    out_root = os.path.abspath(os.path.expanduser(out_root))
    bwpreset_dir = os.path.join(out_root, BWPRESET_SUBDIR)
    adg_dir = os.path.join(out_root, ADG_SUBDIR)
    ablbundle_dir = os.path.join(out_root, BUNDLE_SUBDIR)
    for d in (bwpreset_dir, adg_dir, ablbundle_dir):
        os.makedirs(d, exist_ok=True)

    print(f"Reading {bw_path} …")
    data, zip_start, pads = load_bwpreset(bw_path)
    print(f"{len(pads)} pads found:")
    for padnum, sname in pads:
        print(f"  PAD{padnum:<4} note={128 - padnum:<4} sample={sname}")

    # 1) copy the source .bwpreset
    shutil.copy2(bw_path, os.path.join(bwpreset_dir, os.path.basename(bw_path)))

    # 2) extract samples once (shared source for both outputs)
    tmp_samples_dir = os.path.join(adg_dir, f"{base}_samples")
    extracted = extract_samples(data, zip_start, tmp_samples_dir)
    print(f"{len(extracted)} samples extracted.")

    result = {"preset": base, "adg": "", "bundle": "", "bundle_error": ""}

    # 3) .adg
    if produce_adg:
        out_adg = os.path.join(adg_dir, f"{base}.adg")
        build_adg(pads, extracted, out_adg, tmp_samples_dir, template_path)
        result["adg"] = out_adg
        print(f"   .adg             -> {out_adg}")

    # 4) .ablpresetbundle (Move) — self-contained, own copy of samples inside the zip
    if produce_bundle:
        out_bundle = os.path.join(ablbundle_dir, f"{base}.ablpresetbundle")
        build_move_bundle(pads, extracted, base, out_bundle)
        result["bundle"] = out_bundle
        print(f"   .ablpresetbundle -> {out_bundle}")

    print(
        "\nGenerated tree:\n"
        f"  {bwpreset_dir}/{os.path.basename(bw_path)}\n"
        f"  {adg_dir}/{base}.adg (+ {base}_samples/)\n"
        f"  {ablbundle_dir}/{base}.ablpresetbundle  (samples already inside; nothing else to copy)\n"
    )
    return result


def build_parser():
    p = argparse.ArgumentParser(
        description=(
            "Convert Bitwig Drum Machine .bwpreset files into an Ableton Live "
            ".adg drum rack and an Ableton Move .ablpresetbundle preset."
        )
    )
    p.add_argument("files", nargs="+", help="source .bwpreset file(s)")
    p.add_argument(
        "--working-dir",
        default="",
        help="manager working directory; the default output root is "
             "<working-dir>/Presets (default: the current directory)",
    )
    p.add_argument(
        "-o", "--out",
        default="",
        help="output root directory (default: <working-dir>/Presets)",
    )
    p.add_argument(
        "--template",
        default=TEMPLATE_PATH,
        help="path to template_blocks.pkl (default: next to this script)",
    )
    p.add_argument("--no-adg", action="store_true", help="skip the .adg export")
    p.add_argument("--no-bundle", action="store_true", help="skip the .ablpresetbundle export")
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)

    working_dir = (
        os.path.abspath(os.path.expanduser(args.working_dir))
        if args.working_dir else os.getcwd()
    )
    out_root = (
        os.path.abspath(os.path.expanduser(args.out))
        if args.out else os.path.join(working_dir, "Presets")
    )
    template_path = os.path.abspath(os.path.expanduser(args.template))

    # Validate the template up front so a bad pickle is reported once, clearly,
    # before any per-file work begins.
    try:
        load_template(template_path)
    except (FileNotFoundError, ValueError) as e:
        print(f"ERR template: {e}", file=sys.stderr)
        return 1

    os.makedirs(out_root, exist_ok=True)
    print(f"Working dir: {working_dir}")
    print(f"Output root: {out_root}")

    errors = 0
    for bw_path in args.files:
        bw_path = os.path.abspath(os.path.expanduser(bw_path))
        if not os.path.isfile(bw_path):
            print(f"ERR {bw_path} — file not found", file=sys.stderr)
            errors += 1
            continue
        try:
            convert_one(
                bw_path, out_root, template_path,
                produce_adg=not args.no_adg,
                produce_bundle=not args.no_bundle,
            )
        except ValueError as e:
            print(f"ERR {os.path.basename(bw_path)} — {e}", file=sys.stderr)
            errors += 1
        except Exception as e:  # noqa: BLE001 — report and continue the batch
            print(f"ERR {os.path.basename(bw_path)} — unexpected: {e}", file=sys.stderr)
            errors += 1

    return 2 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
