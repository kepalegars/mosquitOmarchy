#!/usr/bin/env python3
"""Batch driver for jamjamjam-bpm: analyse one or more audio files.

lib_bpm_core.py is importable on its own and has a single-file __main__; this
wrapper exists for the cases that need more than one file: a folder of samples,
or a loop over a setlist where each result has to be greppable on its own line.
Exit status is 1 if any file produced no tempo, so a script can tell the
difference between "analysed, found nothing" and "analysed, found something".
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import lib_bpm_core as C  # noqa: E402

AUDIO_SUFFIXES = {".wav", ".flac", ".ogg", ".oga", ".opus", ".mp3", ".m4a", ".aac", ".aiff", ".aif", ".wma"}


def expand(paths):
    out = []
    for path in paths:
        if os.path.isdir(path):
            for name in sorted(os.listdir(path)):
                if os.path.splitext(name)[1].lower() in AUDIO_SUFFIXES:
                    out.append(os.path.join(path, name))
        else:
            out.append(path)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(prog="jamjamjam-bpm analyse")
    ap.add_argument("files", nargs="+", help="audio files, or directories to scan")
    ap.add_argument("--naming", default="flats", choices=("flats", "sharps"))
    ap.add_argument("--isrc", default="", help="ISRC for the remote cross-check (single file only)")
    ap.add_argument("--json", action="store_true", help="emit one JSON document")
    ap.add_argument("--no-remote", action="store_true", help="skip the network entirely")
    args = ap.parse_args()

    targets = expand(args.files)
    if not targets:
        print("jamjamjam-bpm: nothing to analyse", file=sys.stderr)
        return 1

    results = []
    missing = 0
    for path in targets:
        try:
            res = C.analyse_file(path, naming=args.naming)
        except FileNotFoundError:
            print(f"{path}: no such file", file=sys.stderr)
            missing += 1
            continue
        except Exception as exc:  # a single bad file must not kill the batch
            print(f"{path}: {type(exc).__name__}: {exc}", file=sys.stderr)
            missing += 1
            continue
        if args.isrc and not args.no_remote and len(targets) == 1:
            res = C.annotate_remote(res, args.isrc)
        elif not args.no_remote and not args.isrc:
            res.warnings.append("no ISRC: remote cross-check skipped")
        if res.bpm.bpm <= 0:
            missing += 1
        results.append((path, res))

    if args.json:
        payload = {}
        for path, res in results:
            payload[path] = res.as_dict()
        print(json.dumps(payload, indent=2))
    else:
        width = min(max((len(os.path.basename(p)) for p, _ in results), default=10), 48)
        for path, res in results:
            name = os.path.basename(path)
            print(f"── {name:<{width}}  {os.path.dirname(path) or '.'}")
            for line in C.render_text(res).splitlines():
                print(f"   {line}")
            print()

    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
