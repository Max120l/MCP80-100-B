#!/usr/bin/env python3
"""Put the sectors HDIMAGE's F command recovered into the image.

    python3 hdfix.py mcp-hd-000-479.img mcp-hd-fix.bin [first_cylinder]

The fix file is what F sent by XMODEM: 384-byte records, each 128 bytes of
text ("HDFIX C000 H2 S03 ID 00 00 02 83 OK") followed by the sector's 256
data bytes. Each record replaces the "** BAD SECTOR" filler at that
sector's place in the image (an image that starts at a cylinder other than
0 needs first_cylinder). A record whose place doesn't hold the filler is
skipped unless --force is given. Records marked CRC carry data the
controller read with a CRC error: better than the filler, but not certain.

Two checks guard against a hunt that found the wrong sector: a record is
not applied if its data is identical to another sector of the same track
in the image (the hunt found that sector, not ours), nor if the ID it
answered to has a sector number (the low 5 bits of the last ID byte: the
layout is cylinder low, cylinder high, head, sector) other than the
expected one: a sector that answers to "sector 32" is the track's spare
or a sector the controller matched with a bit masked, and can't be
attributed. A record that answered to its own sector number with other
bits changed is applied.
"""
import re, sys

FILLER = b"** BAD SECTOR"
REC = 384
HDR = re.compile(rb"HDFIX C(\d+) H(\d) S(\d+) ID (\w\w) (\w\w) (\w\w) (\w\w) (OK|CRC)")


def main(argv):
    force = "--force" in argv
    argv = [a for a in argv if a != "--force"]
    if len(argv) < 3:
        print(__doc__)
        return 2
    img_path, fix_path = argv[1], argv[2]
    first = int(argv[3]) if len(argv) > 3 else 0
    img = bytearray(open(img_path, "rb").read())
    fix = open(fix_path, "rb").read()
    done = skipped = 0
    for i in range(0, len(fix) - REC + 1, REC):
        rec = fix[i:i + REC]
        m = HDR.match(rec[:128])
        if not m:
            if rec.strip(b"\x1a\x00"):
                print("record at %d: not an HDFIX record, stopping" % i)
            break
        c, h, s = int(m.group(1)), int(m.group(2)), int(m.group(3))
        ident = " ".join(g.decode() for g in m.groups()[3:7])
        flag = m.group(8).decode()
        off = ((c - first) * 4 + h) * 32 * 256 + s * 256
        if off < 0 or off + 256 > len(img):
            print("C%d H%d S%d: outside this image" % (c, h, s))
            skipped += 1
            continue
        if not img[off:off + len(FILLER)] == FILLER and not force:
            print("C%d H%d S%d: the image has data there already, left alone (--force to replace)"
                  % (c, h, s))
            skipped += 1
            continue
        data = rec[128:384]
        track = off - s * 256
        twin = next((k for k in range(32) if k != s and img[track + k * 256:track + (k + 1) * 256] == data), None)
        if twin is not None:
            print("C%d H%d S%d: NOT applied, the data is sector %d's of the same track (answered to ID %s)"
                  % (c, h, s, twin, ident))
            skipped += 1
            continue
        if int(m.group(7), 16) & 0x1F != s:
            print("C%d H%d S%d: NOT applied, it answered to sector %d's ID (%s), which can't be attributed to it"
                  % (c, h, s, int(m.group(7), 16) & 0x1F, ident))
            skipped += 1
            continue
        img[off:off + 256] = data
        done += 1
        print("C%d H%d S%d: put back (answered to ID %s)%s"
              % (c, h, s, ident, "" if flag == "OK" else ", read with a CRC error"))
    if done:
        open(img_path, "wb").write(img)
    print("%d sector(s) put back, %d skipped; %d filler(s) left in the image"
          % (done, skipped, sum(1 for i in range(0, len(img), 256) if img[i:i + len(FILLER)] == FILLER)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
