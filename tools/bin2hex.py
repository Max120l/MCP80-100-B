#!/usr/bin/env python3
"""bin2hex.py file.bin load_addr [file.hex] [--seg OFFSET:ADDR ...]
Intel HEX for MCPMON's H command. 16 data bytes per record, CR LF line
ends, end record :00000001FF. --seg: the bytes from file offset OFFSET
(decimal) on load at ADDR (hex) instead: a second org in a z80asm binary,
which has no padding between the sections."""
import sys


def ihex(data, addr, segs=()):
    out = []
    cuts = [(0, addr)] + sorted(segs)
    for n, (off, a0) in enumerate(cuts):
        end = cuts[n + 1][0] if n + 1 < len(cuts) else len(data)
        for i in range(off, end, 16):
            chunk = data[i:min(i + 16, end)]
            a = a0 + i - off
            rec = bytes([len(chunk), a >> 8, a & 0xFF, 0]) + chunk
            cs = (-sum(rec)) & 0xFF
            out.append(":" + (rec + bytes([cs])).hex().upper())
    out.append(":00000001FF")
    return "\r\n".join(out) + "\r\n"


if __name__ == "__main__":
    args = sys.argv[1:]
    segs = []
    while "--seg" in args:
        i = args.index("--seg")
        off, a = args[i + 1].split(":")
        segs.append((int(off), int(a, 16)))
        del args[i:i + 2]
    data = open(args[0], "rb").read()
    addr = int(args[1], 16)
    text = ihex(data, addr, segs)
    dst = args[2] if len(args) > 2 else args[0].rsplit(".", 1)[0] + ".hex"
    open(dst, "w", newline="").write(text)
    cuts = [(0, addr)] + sorted(segs)
    spans = []
    for n, (off, a0) in enumerate(cuts):
        end = cuts[n + 1][0] if n + 1 < len(cuts) else len(data)
        spans.append("%04X-%04X" % (a0, a0 + end - off - 1))
    print("%s: %d bytes, %s" % (dst, len(data), " + ".join(spans)))
