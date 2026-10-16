#!/usr/bin/env python3
"""Fill an image's bad-sector fillers from a second image of the same
cylinders (a re-read of a range, or another full image).

    python3 hdmerge.py main.img part.img [first_cylinder_of_part]

For every sector that is a "** BAD SECTOR" filler in main.img and real
data in part.img, the data is copied into main.img. Sectors that are good
in both are compared and any difference is reported (and left as in
main.img). Nothing else is touched.
"""
import sys

FILLER = b"** BAD SECTOR"
SEC = 256


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    main_path, part_path = argv[1], argv[2]
    first = int(argv[3]) if len(argv) > 3 else 0
    img = bytearray(open(main_path, "rb").read())
    part = open(part_path, "rb").read()
    base = first * 4 * 32 * SEC
    if base + len(part) > len(img):
        print("part.img runs past the end of main.img (first cylinder %d?)" % first)
        return 1
    filled = still = differ = 0
    for i in range(0, len(part) - SEC + 1, SEC):
        a, b = img[base + i:base + i + SEC], part[i:i + SEC]
        a_bad, b_bad = a[:len(FILLER)] == FILLER, b[:len(FILLER)] == FILLER
        if a_bad and not b_bad:
            img[base + i:base + i + SEC] = b
            filled += 1
        elif a_bad and b_bad:
            still += 1
        elif not a_bad and not b_bad and a != b:
            n = (base + i) // SEC
            print("C%d H%d S%d reads differently in the two images, main.img kept"
                  % (n // 128, (n // 32) % 4, n % 32))
            differ += 1
    if filled:
        open(main_path, "wb").write(img)
    left = sum(1 for i in range(0, len(img), SEC) if img[i:i + len(FILLER)] == FILLER)
    print("%d sector(s) filled in, %d still bad in both, %d read differently; %d filler(s) left in %s"
          % (filled, still, differ, left, main_path))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
