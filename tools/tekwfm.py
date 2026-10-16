#!/usr/bin/env python3
"""tekwfm.py capture.wfm [out.csv] - decode a Tektronix TDS 400/500/600
".WFM" file saved to floppy (internal "LLWFM" format), print the scale and
a pulse summary, optionally write time,volts CSV.

Layout (big-endian), as used by WaveMetrics' TekWfmLoad.ipf and checked
against a TDS420A capture:
  0x44 FP64 seconds per point      0x4E FP64 vertical offset
  0x56 FP64 vertical position      0x5E FP64 volts per division
  0x66 I32  number of points       0x6A I16  trigger position (%)
  curve: I16 per point (8-bit sample << 8), 16 padding points first,
  real points from 0x90 + 32; 2-byte checksum at the end.
  volts = raw * vdiv / 25 / 256 + offset - position * vdiv
"""
import struct, sys


def load(path):
    d = open(path, "rb").read()
    if not d.startswith(b"LLWFM"):
        raise SystemExit("not an LLWFM file")
    dt = struct.unpack(">d", d[0x44:0x4C])[0]
    voff = struct.unpack(">d", d[0x4E:0x56])[0]
    vpos = struct.unpack(">d", d[0x56:0x5E])[0]
    vdiv = struct.unpack(">d", d[0x5E:0x66])[0]
    n = struct.unpack(">i", d[0x66:0x6A])[0]
    trig = struct.unpack(">h", d[0x6A:0x6C])[0]
    start = 0x90 + 32
    raw = struct.unpack(">%dh" % n, d[start:start + 2 * n])
    volts = [r * vdiv / 25 / 256 + voff - vpos * vdiv for r in raw]
    t0 = -n * trig / 100 * dt
    return dt, vdiv, trig, [t0 + i * dt for i in range(n)], volts


def pulses(volts, dt, threshold):
    out, i, n = [], 0, len(volts)
    while i < n:
        if volts[i] < threshold:
            j = i
            while j < n and volts[j] < threshold:
                j += 1
            out.append((i, j))
            i = j
        else:
            i += 1
    return out


if __name__ == "__main__":
    dt, vdiv, trig, t, v = load(sys.argv[1])
    print("%d points, %.3g s/point (%.3g s/div), %g V/div, trigger at %d%%"
          % (len(v), dt, dt * len(v) / 10, vdiv, trig))
    lo, hi = min(v), max(v)
    s = sorted(v)
    k = max(1, len(s) // 10)
    print("min %.2f V, max %.2f V, typical low %.2f V, high %.2f V"
          % (lo, hi, sum(s[:k]) / k, sum(s[-k:]) / k))
    th = (sum(s[:k]) / k + sum(s[-k:]) / k) / 2
    p = pulses(v, dt, th)
    whole = [x for x in p if x[0] > 0 and x[1] < len(v)]
    print("low pulses (threshold %.2f V): %d" % (th, len(p)))
    if whole:
        print("widths (ns):", [round((b - a) * dt * 1e9) for a, b in whole])
    falls = [a for a, b in p if a > 0]
    print("falling-edge spacing (us):",
          [round((falls[i + 1] - falls[i]) * dt * 1e6, 2) for i in range(len(falls) - 1)])
    if len(sys.argv) > 2:
        with open(sys.argv[2], "w") as f:
            f.write("time_s,volts\n")
            for a, b in zip(t, v):
                f.write("%.9g,%.4f\n" % (a, b))
