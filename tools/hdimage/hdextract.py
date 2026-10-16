#!/usr/bin/env python3
"""Extract the files of one CP/M logical drive from an HDIMAGE image.

    python3 hdextract.py mcp-hd-000-479.img DRIVE OUTDIR [--user N] [--list]

DRIVE is the logical drive's number as hdlayout.py prints it (0 = A:,
1 = B:). Files go to OUTDIR/<user>/<NAME.EXT> (user areas other than 0 in
their own folders). For each file it prints the size and how many of its
256-byte sectors are "** BAD SECTOR" fillers in the image, so it is clear
which files are complete and which are not (a filler is left in the file
where the sector was), and whether a directory entry of the file is
missing (lost with a bad directory sector: the file then lacks a 32K
piece, and files whose every entry was in a bad sector don't appear at
all). --list only prints. Nothing on the disk is
interpreted beyond the directory; CP/M's date stamps, if any, are ignored.

Directory layout as on the MCP's MiniScribe: 32-byte entries, 16-bit
block numbers (8 per entry), block size and extent mask worked out from
the entries as hdlayout.py does. Entries with block numbers past the end
of the disk are reported and skipped.
"""
import math, os, re, sys
from collections import defaultdict

FILLER = b"** BAD SECTOR"
SEC, TRK, HEADS = 256, 32 * 256, 4
DISK_TRACKS = 480 * HEADS


def sector_kind(s):
    if s[:len(FILLER)] == FILLER:
        return "bad"
    if s == b"\xe5" * SEC:
        return "e5"
    good = 0
    for e in range(0, SEC, 32):
        ent = s[e:e + 32]
        if ent[0] == 0xE5:
            good += 1
        elif ent[0] < 32 and all(32 <= (b & 0x7F) < 127 for b in ent[1:12]) and ent[12] < 32:
            good += 1
    return "dir" if good >= 6 else "data"


def find_drives(img):
    """[(first directory track, end of directory, entries)] as hdlayout does"""
    ntracks = len(img) // TRK
    kinds = []
    for t in range(ntracks):
        ks = defaultdict(int)
        for s in range(32):
            ks[sector_kind(img[t * TRK + s * SEC:t * TRK + (s + 1) * SEC])] += 1
        kinds.append("D" if ks["dir"] else ("E" if ks["dir"] + ks["e5"] + ks["bad"] >= 28 and ks["e5"] else "."))
    runs, t = [], 0
    while t < ntracks:
        if kinds[t] == "D":
            t0 = t
            while t < ntracks and kinds[t] in "DE":
                t += 1
            runs.append((t0, t))
        else:
            t += 1
    drives = []
    for a, b in runs:
        ents = []
        for i in range(a * TRK, b * TRK, 32):
            ent = img[i:i + 32]
            if ent[:len(FILLER)] == FILLER or ent[0] == 0xE5 or ent[0] > 31:
                continue
            ents.append(ent)
        if not ents:
            continue
        bls, exm = block_size(ents)
        spt = TRK // bls
        blocks = [ent[16 + 2 * i] | (ent[17 + 2 * i] << 8) for ent in ents for i in range(8)]
        blocks = [blk for blk in blocks if blk]
        if blocks and sum(1 for blk in blocks if a + blk // spt < DISK_TRACKS) < 0.9 * len(blocks):
            continue                                  # a leftover, not a drive
        drives.append((a, b, ents, bls, exm))
    return drives


def block_size(entries):
    best = None
    for bls, exm in ((1024, 0), (2048, 0), (4096, 1), (8192, 3), (16384, 7)):
        ok = 0
        for ent in entries:
            nb = sum(1 for i in range(8) if ent[16 + 2 * i] | (ent[17 + 2 * i] << 8))
            nbytes = ((ent[12] & exm) * 128 + ent[15]) * 128
            ok += math.ceil(nbytes / bls) == nb
        if best is None or ok > best[0]:
            best = (ok, bls, exm)
    return best[1], best[2]


def safe_name(ent):
    name = bytes(b & 0x7F for b in ent[1:9]).decode("ascii", "replace").rstrip()
    ext = bytes(b & 0x7F for b in ent[9:12]).decode("ascii", "replace").rstrip()
    full = name + ("." + ext if ext else "")
    full = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", full) or "_"
    return full


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    opts = [a for a in argv[1:] if a.startswith("--")]
    if len(args) < 2 or (len(args) < 3 and "--list" not in opts):
        print(__doc__)
        return 2
    img = open(args[0], "rb").read()
    which = int(args[1])
    outdir = args[2] if len(args) > 2 else None
    only_user = None
    for o in opts:
        if o.startswith("--user"):
            only_user = int(o.split("=")[1]) if "=" in o else int(args.pop(3))
    drives = find_drives(img)
    if which >= len(drives):
        print("drive %d: only %d logical drive(s) found" % (which, len(drives)))
        return 1
    a, b, ents, bls, exm = drives[which]
    spt = TRK // bls
    print("drive %d: directory at track %d (C%d H%d), %d entries, %dK blocks, extent mask %d"
          % (which, a, a // HEADS, a % HEADS, len(ents), bls // 1024, exm))
    files = defaultdict(list)
    for ent in ents:
        key = (ent[0], bytes(x & 0x7F for x in ent[1:12]))
        files[key].append(ent)
    total = complete = 0
    for (user, _), fents in sorted(files.items(), key=lambda kv: (kv[0][0], kv[0][1])):
        if only_user is not None and user != only_user:
            continue
        name = safe_name(fents[0])
        fents.sort(key=lambda e: (e[14] << 5) | (e[12] & ~exm & 0x1F))
        data = bytearray()
        bad = 0
        broken = False
        # a file's entries must follow on: one missing (a bad directory
        # sector) shows as a gap in the extent numbers, or a full entry
        # after the last one
        gaps = 0
        want = 0
        for ent in fents:
            n = ((ent[14] << 5) | (ent[12] & ~exm & 0x1F)) // (exm + 1)
            if n != want:
                gaps += 1
            want = n + 1
        for ent in fents:
            nbytes = ((ent[12] & exm) * 128 + ent[15]) * 128
            chunk = bytearray()
            for i in range(8):
                blk = ent[16 + 2 * i] | (ent[17 + 2 * i] << 8)
                if not blk:
                    break
                t, within = a + blk // spt, (blk % spt) * bls
                off = t * TRK + within
                if off + bls > len(img):
                    broken = True
                    break
                chunk += img[off:off + bls]
            chunk = chunk[:nbytes]
            bad += sum(1 for i in range(0, len(chunk), SEC) if chunk[i:i + len(FILLER)] == FILLER)
            data += chunk
        total += 1
        complete += not bad and not broken
        note = ""
        if broken:
            note = "  BLOCKS PAST THE DISK: entry skipped"
        elif bad:
            note = "  %d bad sector(s) in it" % bad
        if gaps:
            note += "  %d DIRECTORY ENTRY(IES) MISSING: part of the file is not here" % gaps
            complete -= not bad and not broken
        print("  %2d: %-12s %7d bytes%s" % (user, name, len(data), note))
        if outdir is not None and not broken:
            d = os.path.join(outdir, "%d" % user) if user else outdir
            os.makedirs(d, exist_ok=True)
            open(os.path.join(d, name), "wb").write(data)
    print("%d file(s), %d complete" % (total, complete))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
