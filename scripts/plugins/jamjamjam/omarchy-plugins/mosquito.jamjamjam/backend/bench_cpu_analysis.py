
#!/usr/bin/env python3
"""jamjamjam CPU/memory bench — 10 s of the REAL analysis pipeline.

Benchmarks AudioAnalyzer.analyze() (the exact code path while the panel is
open, once per second) built on real signals; include the tuner pass and the
metronome synth garbage collection. Useful to embed the worst-case overhead
into the plugin README.
"""
from __future__ import annotations

import argparse, importlib.util, time, tracemalloc
import numpy as np
import os

BACKEND = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       'jamjamjam_backend.py')
spec = importlib.util.spec_from_file_location('__bench__', BACKEND)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)


def fake_stream(seconds, fs, freqs=(440, 660, 880)):
    n = int(seconds * fs)
    ts = np.linspace(0, seconds, n, endpoint=False)
    wave = sum(np.sin(2 * np.pi * f * ts) for f in freqs) * 0.05
    wave = wave + np.sin(2 * np.pi * 88 * ts) * 0.08
    return (wave * 32768.0).astype('<i2')


def main():
    import argparse as _ap
    ap = _ap.ArgumentParser()
    ap.add_argument('--seconds', type=float, default=10.0)
    args = ap.parse_args()
    fs = m.SAMPLE_RATE

    pcm = fake_stream(args.seconds, fs)
    a = m.AudioAnalyzer()
    a.feed(pcm[:m.ANALYSIS_CHUNK].tobytes())  # warm up: fill a full chunk
    times = []
    idx = m.ANALYSIS_CHUNK
    hop = m.HOP_SIZE * 8  # ~0.17 s per feed, like the real recorder chunking
    while idx < len(pcm):
        chunk = pcm[idx:idx + hop].tobytes()
        a.feed(chunk); idx += hop
        t0 = time.perf_counter()
        a.analyze(record_progression=False)
        times.append((time.perf_counter() - t0) * 1000.0)
    per = np.array(times)

    tracemalloc.start()
    a2 = m.AudioAnalyzer()
    a2.feed(pcm[:m.ANALYSIS_CHUNK].tobytes())
    idx2 = m.ANALYSIS_CHUNK
    t0 = time.perf_counter()
    for i in range(24):
        if idx2 + hop > len(pcm):
            break
        a2.feed(pcm[idx2:idx2+hop].tobytes())
        idx2 += hop
        a2.analyze(record_progression=False)
    cur, peak = tracemalloc.get_traced_memory()

    # Tuner single pass over 4s:
    s = m.Tuner(); tt0 = time.perf_counter()
    s.feed(bytes(pcm[-4*fs:])); s.analyze()
    tuner = (time.perf_counter() - tt0) * 1000
    print(f'== bench_cpu_analysis (audio {args.seconds}s, {len(times)} passes) ==')
    print(f'analysis pass latency: mean {per.mean() if hasattr(per,"mean") else per:.1f} ms (p95 {np.percentile(per,95):.1f} ms, max {np.max(per):.1f} ms)')
    # Analysis pass cadence = 1 s (the backend loops `run_analysis_pass` at
    # 1 Hz). Meaning: a ~12 ms pass ONCE per second is ~1.2 % of one core.
    print(f'approx CPU: {(per.mean() / 1000) * 100:.1f}% of one CPU core '
          f'({per.mean():.1f} ms per pass over a 1 s cadence = one pass/sec)')
    print(f'memory (peak/cur): {peak/1024:.0f}/{cur/1024:.0f} KiB')
    print(f'tuner pass (4 s of audio): {tuner:.1f} ms')
    print(f'README line: "analysis ≈ {per.mean():.0f} ms once per second '
          f'({(per.mean() / 10):.1f}% of one core); peak memory {peak/1024:.0f} KiB"')

if __name__ == '__main__':
    main()
