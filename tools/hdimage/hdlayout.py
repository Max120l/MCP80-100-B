#!/usr/bin/env python3
"""The CP/M layout of an HDIMAGE image: where the logical drives, their
directories and their data are, and which bad sectors matter.

    python3 hdlayout.py mcp-hd-000-479.img

CP/M 2.2 can't address more than 8 MB per drive, so a 16 MB MiniScribe is
split into logical drives, each with its own directory at its start. This
finds the directories (runs of tracks holding directory entries or E5h
fill), and for each works out the block size from the entries, the
allocated blocks, the highest cylinder with data, and how many of the
image's "** BAD SECTOR" fillers fall in allocated blocks, in the
directory, or in free space. File names are not printed.
"""
import math, sys
from collections import Counter, defaultdict

FILLER = b"** BAD SECTOR"
SEC, TRK = 256, 32 * 256
HEADS = 4
DISK_TRACKS = 480 * HEADS                 # the MiniScribe 4020 (an image may be a part of it)


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


def entries_of(tracks_data):
    out = []
    for i in range(0, len(tracks_data), 32):
        ent = tracks_data[i:i + 32]
        if ent[:len(FILLER)] == FILLER or ent[0] == 0xE5 or ent[0] > 31:
            continue
        out.append(ent)
    return out


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
    return best


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    img = open(argv[1], "rb").read()
    ntracks = len(img) // TRK
    kinds = []
    for t in range(ntracks):
        ks = Counter(sector_kind(img[t * TRK + s * SEC:t * TRK + (s + 1) * SEC]) for s in range(32))
        if ks["dir"] + ks["e5"] + ks["bad"] >= 28 and ks["dir"] + ks["e5"] > 0:
            kinds.append("D" if ks["dir"] else "E")      # directory-looking track
        else:
            kinds.append(".")
    # a directory = a run of D/E tracks that starts with a D track
    runs, t = [], 0
    while t < ntracks:
        if kinds[t] == "D":
            t0 = t
            while t < ntracks and kinds[t] in "DE":
                t += 1
            runs.append((t0, t))
        else:
            t += 1
    bad = set()
    for i in range(0, len(img) - SEC + 1, SEC):
        if img[i:i + len(FILLER)] == FILLER:
            bad.add(i // SEC)
    print("%d tracks, %d bad sectors; directory-looking track runs: %s\n" % (
        ntracks, len(bad), ", ".join("tracks %d-%d (C%d H%d ..)" % (a, b - 1, a // HEADS, a % HEADS) for a, b in runs)))
    # a run is a real directory only if its entries' blocks fit before the
    # next directory (or the end): leftovers of an earlier partitioning in
    # free space point anywhere
    drives = []
    for n, (a, b) in enumerate(runs):
        ents = entries_of(img[a * TRK:b * TRK])
        if not ents:
            continue
        ok, bls, exm = block_size(ents)
        spt = TRK // bls
        end_track = (runs[n + 1][0] if n + 1 < len(runs) else ntracks)
        blocks = [ent[16 + 2 * i] | (ent[17 + 2 * i] << 8) for ent in ents for i in range(8)]
        blocks = [blk for blk in blocks if blk]
        fit = sum(1 for blk in blocks if a + blk // spt < DISK_TRACKS)
        if blocks and fit < 0.9 * len(blocks):
            print("tracks %d-%d (C%d H%d): directory-shaped but %d of %d block numbers point past the disk: "
                  "a leftover of an earlier partitioning, not a drive\n"
                  % (a, b - 1, a // HEADS, a % HEADS, len(blocks) - fit, len(blocks)))
            continue
        drives.append((a, b, ents, ok, bls, exm))
    for n, (a, b, ents, ok, bls, exm) in enumerate(drives):
        spt = TRK // bls                      # blocks per track
        alloc = set()
        for ent in ents:
            for i in range(8):
                blk = ent[16 + 2 * i] | (ent[17 + 2 * i] << 8)
                if blk:
                    alloc.add(blk)
        # block 0 is the first directory track (the reserved tracks are before it)
        def block_track(blk):
            return a + blk // spt
        maxblk = max(alloc) if alloc else 0
        end_track = (drives[n + 1][0] if n + 1 < len(drives) else ntracks)
        print("Logical drive %d: directory at tracks %d-%d (C%d H%d - C%d H%d), %d entries, %d used"
              % (n, a, b - 1, a // HEADS, a % HEADS, (b - 1) // HEADS, (b - 1) % HEADS, (b - a) * 256, len(ents)))
        print("  block size %dK (EXM %d, %d of %d entries agree), %d blocks allocated = %dK"
              % (bls // 1024, exm, ok, len(ents), len(alloc), len(alloc) * bls // 1024))
        print("  highest allocated block %d -> track %d (C%d H%d); next directory at track %d"
              % (maxblk, block_track(maxblk), block_track(maxblk) // HEADS, block_track(maxblk) % HEADS, end_track))
        in_dir = in_alloc = in_free = 0
        for s in bad:
            t = s // 32
            if t < a or t >= end_track:
                continue
            if t < b:
                in_dir += 1
            elif (t - a) * spt + (s % 32) * SEC // bls in alloc:
                in_alloc += 1
            else:
                in_free += 1
        print("  bad sectors here: %d in the directory, %d in allocated blocks, %d in free space\n"
              % (in_dir, in_alloc, in_free))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
