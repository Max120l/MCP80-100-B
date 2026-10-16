#!/usr/bin/env python3
"""Where are the bad sectors in an HDIMAGE image?

    python3 hdmap.py mcp-hd-000-479.img [first_cylinder]

Finds every "** BAD SECTOR" filler and prints them by track (cylinder,
head, the sector numbers), then a count per head and per 20-cylinder
band, so a pattern (one head, one band, whole tracks, scattered) shows.
The image is 32 sectors x 256 bytes per track, 4 heads per cylinder.
"""
import sys
from collections import defaultdict

FILLER = b"** BAD SECTOR"


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    img = open(argv[1], "rb").read()
    first = int(argv[2]) if len(argv) > 2 else 0
    bad = defaultdict(list)
    for i in range(0, len(img) - 255, 256):
        if img[i:i + len(FILLER)] == FILLER:
            n = i // 256
            c, h, s = first + n // 128, (n // 32) % 4, n % 32
            bad[(c, h)].append(s)
    total = sum(len(v) for v in bad.values())
    print("%d bad sector(s) in %d track(s), image of %d cylinder(s)\n" % (
        total, len(bad), len(img) // 32768))
    for (c, h), secs in sorted(bad.items()):
        print("C%03d H%d  %2d: %s" % (c, h, len(secs),
                                      "whole track" if len(secs) == 32 else " ".join("%d" % s for s in secs)))
    byhead = defaultdict(int)
    byband = defaultdict(int)
    for (c, h), secs in bad.items():
        byhead[h] += len(secs)
        byband[c // 20 * 20] += len(secs)
    print("\nper head: " + "  ".join("H%d %d" % (h, byhead[h]) for h in range(4)))
    print("per band: " + "  ".join("C%03d-%03d %d" % (b, b + 19, byband[b]) for b in sorted(byband)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
