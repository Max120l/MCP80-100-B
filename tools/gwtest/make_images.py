#!/usr/bin/env python3
"""Test images for writing an 8" drive with a Greaseweazle.

rx01_test.img    77 cyl x 1 head  x 26 x 128 (IBM 3740 FM)  --format=dec.rx01
rx01ds_test.img  77 cyl x 2 heads x 26 x 128 (same, both sides)
                 --diskdefs=sa850test.cfg --format=rx01ds

Each sector starts with readable text naming its own cylinder, head and
sector, then 96 bytes of a mixed bit pattern (00, FF, 55, AA runs and a
counter), so a dump of any sector read back shows where it came from.
"""
import sys

def sector(c, h, s):
    text = ("MCP SA850 C%02d H%d S%02d " % (c, h, s)).encode().ljust(32, b".")
    pat = bytes([0x00] * 8 + [0xFF] * 8 + [0x55] * 8 + [0xAA] * 8)
    cnt = bytes(((i * 7 + c * 13 + s) & 0xFF) for i in range(64))
    return text + pat + cnt

def image(heads):
    out = bytearray()
    for c in range(77):
        for h in range(heads):
            for s in range(1, 27):
                out += sector(c, h, s)
    return bytes(out)

if __name__ == "__main__":
    for name, heads in (("rx01_test.img", 1), ("rx01ds_test.img", 2)):
        data = image(heads)
        open(name, "wb").write(data)
        print(name, len(data), "bytes")
