#!/usr/bin/env python3
"""HDIMAGE in the MCP simulator: MCPMON at 6 MHz, the console at 9600
baud, the XCOMP ST/S + MiniScribe model (rom/mcpmon/xcomp.py) and port B
as a timed 19200-baud line with a Tera Term-like XMODEM receiver.

The header layout is varied: the known one (cylinder low, cylinder high,
head, sector) must pass the check reads straight away, any other must be
found by the search. The flaky cabling seen on the real drive is modelled
too: dropouts the imager must ride out, and reads that silently return
zeros, which the probe must not believe.
"""
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "rom", "mcpmon"))
from mcpsim import MCP
from xcomp import XComp, default_data
from uart8251 import Uart8251
import xmodem_peer
from xmodem_peer import Receiver, Silent

ROM = open(os.path.join(HERE, "..", "..", "rom", "mcpmon", "mcpmon_2716.bin"), "rb").read()
HEX = open(os.path.join(HERE, "hdimage.hex")).read()
MHZ = 6.0
MS = int(1000 * MHZ)
SEC = 1000 * MS
CHAR_T = int(MHZ * 1e6 * 10 / 19200)

fails = 0
def check(name, cond, detail=""):
    global fails
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else "  " + detail))
    fails += 0 if cond else 1


# header layouts the probe has to work out
def lay_cchs(c, h, s):   return bytes([c & 0xFF, c >> 8, h, s])
def lay_shcc(c, h, s):   return bytes([s, h, c & 0xFF, c >> 8])
def lay_be(c, h, s):     return bytes([c >> 8, c & 0xFF, h, s])
def lay_packed(c, h, s): return bytes([c & 0xFF, ((c >> 8) << 6) | h, s, 0])
def lay_nohead(c, h, s): return bytes([c & 0xFF, c >> 8, s, 0])


class Rig:
    def __init__(self, header=lay_cchs, interleave=1, ready=True, spare=False):
        self.s = MCP(ROM)
        self.s.tx_char_t = MHZ * 1e6 * 10 / 9600
        self.x = XComp(self.s.now, header=header, interleave=interleave, ready=ready, spare=spare)
        self.s.hdc_model = self.x
        self.u = Uart8251(self.s.now, CHAR_T, Silent())
        self.s.aux = self.u
        self.s.run(); self.s.output()
        self.s.type("H" + HEX); self.s.run()
        assert "OK" in self.s.output()
        self.out = ""

    def until(self, text, secs):
        for _ in range(int(secs * 20)):
            self.s.ticks(MS * 50)
            self.out += self.s.output()
            if text in self.out:
                break
        o, self.out = self.out, ""
        return o

    def key(self, keys, wait, secs=60):
        self.s.type(keys)
        return self.until(wait, secs)


def expected(cyls, bad=(), filler=None):
    out = bytearray()
    for c in cyls:
        for h in range(4):
            for s in range(32):
                if (c, h, s) in bad:
                    line = b"** BAD SECTOR C%03d H%d S%02d **  \r\n" % (c, h, s)
                    out += line * 8
                else:
                    out += default_data(c, h, s)
    return bytes(out)


# --- start-up and probe, standard layout -------------------------------------
r = Rig()
o = r.key("G0100\r", "HDIMAGE> ", 20)
check("start: HDINIT restores and reports the drive ready",
      "Drive ready" in o and "selected ready track-0" in o and r.x._pos() == 0, repr(o[-300:]))
t0 = r.s.now()
o = r.key("P", "HDIMAGE> ", 120)
secs = (r.s.now() - t0) / SEC
print("     probe took %.1f s" % secs)
check("probe: the known layout passes both check reads, no search",
      "sector 1-16: 3.0 3.1 3.2 3.3 3.4" in o and "head 1-2: 2.0 2.1" in o
      and "cylinder 1-256: 0.0 0.1 0.2 0.3 0.4 0.5 0.6 0.7 1.0" in o and "Layout OK" in o
      and "Searching" not in o and secs < 3,
      repr(o))
check("the check reads set every address bit between them",
      {(c, h, want) for c, h, want, f in r.x.reads if f is not None}
      == {(300, 3, bytes([300 & 0xFF, 1, 3, 21])), (243, 0, bytes([243, 0, 0, 10]))},
      repr(r.x.reads))
check("never starts the write microcode", r.x.write_starts == 0)

o = r.key("R5\r2\r7\r", "HDIMAGE> ", 30)
check("R reads C5 H2 S7 and dumps it", "C005H2S07" in o and "00: 43 30 30 35" in o, repr(o[-400:]))

# --- imaging 3 cylinders with bad sectors -----------------------------------------
bad = {(1, 2, 5): "crc", (2, 0, 31): "missing"}
r.x.bad.update(bad)
r.x.unformatted.add((2, 3))
badset = set(bad) | {(2, 3, s) for s in range(32)}
o = r.key("I0\r2\r", "Start the XMODEM receive", 10)
check("I asks for the range and announces the size", "3 cylinders, 96K" in o, repr(o))
peer = Receiver(start=r.s.now() + 2 * SEC)
r.u.attach(peer)
t0 = r.s.now()
o = r.until("HDIMAGE> ", 300)
r.u.sync()
secs = (r.s.now() - t0) / SEC
img = bytes(peer.data)
want = expected(range(3), badset)
check("image of cylinders 0-2 arrives intact, bad sectors as text fillers",
      peer.state == "done" and img == want, "state=%s len=%d/%d first diff %s" % (
          peer.state, len(img), len(want),
          next((i for i in range(min(len(img), len(want))) if img[i] != want[i]), None)))
check("bad sector list: 34 (1 CRC, 1 missing, a whole unformatted track)",
      "Bad sectors: 34" in o and "C1 H2 S5 err 08" in o and "C2 H0 S31 err 02" in o, repr(o[-700:]))
check("still no write microcode, no overruns", r.x.write_starts == 0 and r.u.overruns == 0,
      "%d %d" % (r.x.write_starts, r.u.overruns))
print("     3 cylinders (one bad track) in %.1f s" % secs)

# --- clean imaging speed, interleave 1 and 4 ------------------------------------
for il in (1, 4):
    r = Rig(interleave=il)
    r.key("G0100\r", "HDIMAGE> ", 20)
    r.key("P", "HDIMAGE> ", 120)
    r.key("I100\r101\r", "Start the XMODEM receive", 10)
    peer = Receiver(start=r.s.now())
    r.u.attach(peer)
    t0 = r.s.now()
    o = r.until("HDIMAGE> ", 200)
    r.u.sync()
    secs = (r.s.now() - t0) / SEC
    ok = peer.state == "done" and bytes(peer.data) == expected(range(100, 102))
    check("interleave %d: cylinders 100-101 intact, no bad sectors" % il,
          ok and "Bad sectors: 0" in o, repr(o[-200:]))
    print("     %.1f s per cylinder: whole drive about %.1f hours" % (secs / 2, secs / 2 * 480 / 3600))

# --- other header layouts --------------------------------------------------------
for name, lay, want_s, want_h, want_c in (
        ("sector, head, cyl lo, cyl hi", lay_shcc, "0.0 0.1 0.2 0.3 0.4", "1.0 1.1",
         "2.0 2.1 2.2 2.3 2.4 2.5 2.6 2.7 3.0"),
        ("big-endian cylinder", lay_be, "3.0 3.1 3.2 3.3 3.4", "2.0 2.1",
         "1.0 1.1 1.2 1.3 1.4 1.5 1.6 1.7 0.0"),
        ("cylinder bit 8 packed with the head", lay_packed, "2.0 2.1 2.2 2.3 2.4", "1.0 1.1",
         "0.0 0.1 0.2 0.3 0.4 0.5 0.6 0.7 1.6"),
        ("no head in the header", lay_nohead, "2.0 2.1 2.2 2.3 2.4", "--- ---",
         "0.0 0.1 0.2 0.3 0.4 0.5 0.6 0.7 1.0")):
    r = Rig(header=lay, interleave=3)
    r.key("G0100\r", "HDIMAGE> ", 20)
    t0 = r.s.now()
    o = r.key("P", "HDIMAGE> ", 200)
    check("probe, %s: the known layout fails the check, the search finds it" % name,
          "Searching" in o and ("sector 1-16: " + want_s) in o and ("head 1-2: " + want_h) in o
          and ("cylinder 1-256: " + want_c) in o and "Layout OK" in o, repr(o))
    print("     search took %.1f s" % ((r.s.now() - t0) / SEC))
    if lay is lay_packed:
        o = r.key("R300\r3\r21\r", "HDIMAGE> ", 30)
        check("  and R reads C300 H3 S21 with it", "C300H3S21" in o, repr(o[-300:]))

# --- a flaky drive: reads that silently return zeros -----------------------------
# Every 5th read completes with no error bits and no data (the drive flickered
# and the controller didn't notice). The search must not take any of them for
# a found header: each candidate has to read twice.
r = Rig(header=lay_shcc, interleave=3)
r.key("G0100\r", "HDIMAGE> ", 20)
r.x.drop_reads = {i for i in range(100000) if i % 5 == 2}
o = r.key("P", "HDIMAGE> ", 300)
check("search with every 5th read a silent dud: still the right layout",
      "sector 1-16: 0.0 0.1 0.2 0.3 0.4" in o and "head 1-2: 1.0 1.1" in o
      and "cylinder 1-256: 2.0 2.1 2.2 2.3 2.4 2.5 2.6 2.7 3.0" in o and "Layout OK" in o,
      repr(o))
r.x.drop_reads = set()

# --- a flaky drive: dropouts while imaging -----------------------------------------
# The drive goes away for 4 s three times during cylinders 0-2, twice in
# the middle of a read (which then looks complete, with zeros) and once
# between reads, that one preceded by a second in which the spindle speed
# is off and nothing reads (as on the real drive: the bad count went up
# just before each "waiting"). The status check after the read says the
# drive is gone; HDIMAGE waits, restores, and reads the sector again; the
# sector that failed during the drift gets 2 s to show READY dropping.
r = Rig()
r.key("G0100\r", "HDIMAGE> ", 20)
r.key("P", "HDIMAGE> ", 120)
r.key("I0\r2\r", "Start the XMODEM receive", 10)
peer = Receiver(start=r.s.now())
r.u.attach(peer)
t = r.s.now()
n0 = len(r.x.reads)
r.x.drop_at_read = {n0 + 40: 4 * SEC, n0 + 300: 4 * SEC}
r.x.dropouts = [(t + 30 * SEC, t + 34 * SEC)]
r.x.drift = SEC
o = r.until("HDIMAGE> ", 400)
r.u.sync()
img = bytes(peer.data)
want = expected(range(3))
check("three 4 s dropouts: waited for the drive each time, image of cylinders 0-2 intact, no bad sectors",
      peer.state == "done" and img == want and o.count("waiting up to 60 s") == 3
      and o.count("back.") == 3 and "Bad sectors: 0" in o,
      "state=%s len=%d/%d waits=%d first diff %s %r" % (
          peer.state, len(img), len(want), o.count("waiting"),
          next((i for i in range(min(len(img), len(want))) if img[i] != want[i]), None),
          o[-400:]))
check("the reads the drive dropped out of were not taken as data",
      sum(1 for c, h, w, f in r.x.reads if f == "dropout") >= 2
      and not any(img[i:i + 256] == bytes(256) for i in range(0, len(img), 256)),
      repr([x for x in r.x.reads if x[3] == "dropout"]))
check("the sector that failed while the speed drifted was read again after the dropout, not marked bad",
      sum(1 for c, h, w, f in r.x.reads if f == "drift") >= 10,
      "%d drift reads" % sum(1 for c, h, w, f in r.x.reads if f == "drift"))
r.x.drop_at_read = {}
r.x.drift = 0

# --- a flaky drive: it doesn't come back ------------------------------------------
r.key("I5\r6\r", "Start the XMODEM receive", 10)
peer = Receiver(start=r.s.now())
r.u.attach(peer)
t = r.s.now()
r.x.dropouts = [(t + 25 * SEC, t + 300 * SEC)]
t0 = r.s.now()
o = r.until("HDIMAGE> ", 400)
r.u.sync()
secs = (r.s.now() - t0) / SEC
check("a dropout of minutes: 60 s wait, then the image is stopped at that cylinder with the whole-cylinder size",
      "didn't come back: image stopped at cylinder 6" in o and "Whole cylinders sent: 32K" in o
      and "restart the image from that cylinder" in o and peer.state != "done" and 80 < secs < 110,
      "%.0f s %r" % (secs, o[-500:]))
check("  the PC's file holds exactly the cylinders before it, plus what was sent of that one",
      bytes(peer.data)[:32768] == expected([5]) and 32768 < len(peer.data) < 65536,
      "len=%d" % len(peer.data))
r.x.dropouts = []
o = r.key("S", "HDIMAGE> ", 10)
check("  afterwards: status shows the drive back", "selected ready" in o, repr(o))

# --- a flaky drive: the spindle off speed ------------------------------------------
# As in the band at cylinders 411-473 of the first full image: with the
# spindle 1 % off for a while (not enough for the firmware to drop READY),
# the last sectors of every track read then are "not found", since the
# controller times them from the index. The speed gate before each track
# and before a sector's last tries waits for the speed to come back.
r = Rig()
r.key("G0100\r", "HDIMAGE> ", 20)
r.key("P", "HDIMAGE> ", 120)
r.key("I0\r1\r", "Start the XMODEM receive", 10)
peer = Receiver(start=r.s.now())
r.u.attach(peer)
t = r.s.now()
r.x.speed = [(t + 6 * SEC, t + 14 * SEC, 1.01)]
o = r.until("HDIMAGE> ", 300)
r.u.sync()
img = bytes(peer.data)
check("spindle 1 % off for 8 s during a 2-cylinder image: the gate waits it out, image intact, no bad sectors",
      peer.state == "done" and img == expected(range(2)) and "Bad sectors: 0" in o
      and "Spindle off speed: 16.8" in o and "on speed." in o,
      "state=%s len=%d %r" % (peer.state, len(img), o[-500:]))
check("  the model did refuse the late sectors while off speed",
      sum(1 for c, h, w, f in r.x.reads if f == "speed") > 0)
# a part image to merge: the same cylinders read again, into a main image with fillers
import subprocess, tempfile
main_img = bytearray(expected(range(2), {(0, 2, 5), (1, 3, 31), (1, 0, 0)}))
with tempfile.TemporaryDirectory() as d:
    open(d + "/main", "wb").write(main_img)
    open(d + "/part", "wb").write(img[32768:])       # cylinder 1 only
    p = subprocess.run([sys.executable, os.path.join(HERE, "hdmerge.py"), d + "/main", d + "/part", "1"],
                       capture_output=True, text=True)
    merged = open(d + "/main", "rb").read()
want = expected(range(2), {(0, 2, 5)})
check("hdmerge.py fills cylinder 1's fillers from a re-read of cylinder 1 and leaves cylinder 0's",
      p.returncode == 0 and merged == want and "2 sector(s) filled in, 0 still bad in both, 0 read differently; 1 filler(s) left" in p.stdout,
      p.stdout + p.stderr)
r.x.speed = []

# --- a flaky drive: a recalibrate that lands off-track ----------------------------
# In the first full image the drive landed off-track after the restore +
# seek back that followed a real bad sector, and every later sector of the
# track failed. Now the recalibrate is a short move away and back, checked
# by reading a neighbour; a bad landing is retried with restores.
r = Rig()
r.key("G0100\r", "HDIMAGE> ", 20)
r.key("P", "HDIMAGE> ", 120)
r.x.bad = {(300, 1, 5): "missing"}
r.key("I300\r300\r", "Start the XMODEM receive", 10)
peer = Receiver(start=r.s.now())
r.u.attach(peer)
r.until("Cylinder 300 head 0", 60)
n0 = r.x.seeks                       # next seeks: the recalibrate's move away (+1) and back (+2)
r.x.seek_errors = {n0 + 2: 1}        # the move back lands one cylinder in
o = r.until("HDIMAGE> ", 200)
r.u.sync()
check("recalibrate lands off-track: the landing check catches it, the rest of the track is intact",
      peer.state == "done" and bytes(peer.data) == expected([300], {(300, 1, 5)}) and "Bad sectors: 1" in o,
      "%r %r" % (o[-300:], [x for x in r.x.reads if x[0] != 300][:3]))
r.x.seek_errors = {}
r.x.bad = {}

# --- F: sectors behind damaged IDs ---------------------------------------------
# As on the real drive's directory tracks: sectors whose ID field no longer
# reads as it should. Three answer to a one-bit/one-byte variant of their
# ID (one of them with a CRC error in the data), one ID is gone altogether.
import subprocess, tempfile
r = Rig(spare=True)                                      # every track answers to "sector 32"
r.key("G0100\r", "HDIMAGE> ", 20)
r.key("P", "HDIMAGE> ", 120)
r.x.id_errors = {(0, 2, 3): bytes([0, 0, 2, 0x83]),      # sector byte bit 7
                 (0, 2, 5): bytes([0x40, 0, 2, 5]),      # cylinder byte bit 6
                 (1, 0, 12): bytes([1, 0, 2, 12]),       # head byte says 2
                 (0, 2, 8): bytes([0, 0, 2, 0x88])}      # bit 7 again, and a CRC error
r.x.bad = {(0, 2, 8): "crc", (0, 3, 4): "missing"}
r.key("I0\r1\r", "Start the XMODEM receive", 10)
peer = Receiver(start=r.s.now())
r.u.attach(peer)
o = r.until("HDIMAGE> ", 300)
r.u.sync()
img = bytearray(peer.data)
hidden = {(0, 2, 3), (0, 2, 5), (1, 0, 12), (0, 2, 8), (0, 3, 4)}
check("image with 5 damaged IDs: 5 fillers, all err 02",
      peer.state == "done" and img == expected(range(2), hidden) and "Bad sectors: 5" in o
      and o.count("err 02") == 5, repr(o[-400:]))
t0 = r.s.now()
o = r.key("FY", "Start the XMODEM receive", 600)
secs = (r.s.now() - t0) / SEC
print("     hunt for 5 sectors (one of them not there) took %.0f s" % secs)
check("F hunts the list: 4 found with the ID they answer to, 1 not found (never 'found' as the spare)",
      "C0 H2 S3:" in o and "found as 00 00 02 83" in o and "found as 40 00 02 05" in o
      and "found as 01 00 02 0C" in o and "found as 00 00 02 88 (CRC error in the data)" in o
      and "C0 H3 S4:" in o and o.count("not found") == 1 and "Recovered 4 sector(s)" in o
      and "20" not in [x.split()[-1] for x in o.split("found as")[1:]],
      repr(o))
check("  the hunt never read with another sector number of the track",
      not any(f == 32 for c, h, w, f in r.x.reads), repr([x for x in r.x.reads if x[3] == 32][:3]))
check("  no read with an ID that belongs to another sector of the track",
      not any(f not in (None, "dropout") and want != r.x.header(c, h, f)
              and (c, h, f) not in r.x.id_errors for c, h, want, f in r.x.reads),
      repr([x for x in r.x.reads if x[3] is not None and x[2] != r.x.header(x[0], x[1], x[3])][:5]))
peer = Receiver(start=r.s.now())
r.u.attach(peer)
o = r.until("HDIMAGE> ", 120)
r.u.sync()
fix = bytes(peer.data)
check("  the fix file: 4 records of 384 bytes, sent and acknowledged",
      peer.state == "done" and len(fix) == 4 * 384 and fix[:7] == b"HDFIX C"
      and "Fix file sent" in o, "%d %r" % (len(fix), fix[:40]))
with tempfile.TemporaryDirectory() as d:
    open(d + "/img", "wb").write(img)
    open(d + "/fix", "wb").write(fix)
    p = subprocess.run([sys.executable, os.path.join(HERE, "hdfix.py"), d + "/img", d + "/fix"],
                       capture_output=True, text=True)
    fixed = open(d + "/img", "rb").read()
want = bytearray(expected(range(2), {(0, 3, 4)}))
want[((0 * 4 + 2) * 32 + 8) * 256 + 100] ^= 0x40          # the CRC-error sector, as read
check("  hdfix.py puts the 4 back, leaving the filler for the 5th",
      p.returncode == 0 and fixed == bytes(want) and "4 sector(s) put back, 0 skipped; 1 filler(s) left" in p.stdout,
      p.stdout + p.stderr)
o = r.key("FN", "Cylinder: ", 10)
o2 = r.key("\x1b", "HDIMAGE> ", 10)      # typed-in sector: ESC backs out
check("  F with a list asks Y/N; N asks for one sector", "(Y/N)?" in o and "Cylinder:" in o
      and o2.endswith("HDIMAGE> "), repr(o + o2))
# the list survives a reload of HDIMAGE (it sits above the program): F can
# take it over by count, after checking the entries
r.key("Q", ">", 10)
r.s.type("H" + HEX); r.s.run(); r.s.output()
r.key("G0100\r", "HDIMAGE> ", 20)
r.key("P", "HDIMAGE> ", 120)
o = r.key("F5\r", "Start the XMODEM receive", 600)
check("  after a reload, F takes the 5 entries the previous run left and finds the same 4",
      "Entries of a previous run's list" in o and "Recovered 4 sector(s)" in o
      and "found as 00 00 02 83" in o, repr(o[-600:]))
peer = Receiver(start=r.s.now())
r.u.attach(peer)
r.until("HDIMAGE> ", 120)
r.u.sync()
check("  and sends the same fix file", bytes(peer.data) == fix)
o = r.key("F\r", "Cylinder: ", 10)
r.key("\x1b", "HDIMAGE> ", 10)
check("  Enter at that prompt asks for one sector instead", "Cylinder:" in o, repr(o))
r.x.id_errors = {}
r.x.bad = {}

# --- T: drive tests ----------------------------------------------------------------
r = Rig()
r.key("G0100\r", "HDIMAGE> ", 20)
r.key("P", "HDIMAGE> ", 120)
r.key("T1", "Seconds [60]: ", 10)
o = r.key("2\r", "HDIMAGE> ", 30)
check("T1: index period per 60 revolutions, 16.66-16.67 ms, 3600 rpm, no READY drops",
      o.count(" rpm ") == 2 and all(x in o for x in ("16.6", "360", "READY drops 0"))
      and "drops 1" not in o, repr(o[-300:]))
r.key("T1", "Seconds [60]: ", 10)
t = r.s.now()
r.x.dropouts = [(t + SEC, t + 3 * SEC)]
o = r.key("4\r", "HDIMAGE> ", 60)
check("  with a 2 s dropout: waits for the drive, counts one READY drop",
      "waiting up to 60 s" in o and "back." in o and "READY drops 1" in o, repr(o[-400:]))
r.x.dropouts = []
r.key("T1", "Seconds [60]: ", 10)
t = r.s.now()
r.x.speed = [(t + SEC, t + 2 * SEC, 1.006)]
o = r.key("3\r", "HDIMAGE> ", 60)
check("  with the spindle 0.6 % slow for a second: that line's max shows 16.7x ms",
      "max 16.7" in o and o.count(" rpm ") == 3, repr(o[-400:]))
r.x.speed = []
r.x.seek_errors = {r.x.seeks + 8: -1, r.x.seeks + 13: 2}
o = r.key("T3", "HDIMAGE> ", 120)
check("T3: full-stroke seeks timed (about 250 ms), two that land wrong are reported and resynced",
      "Seeks: 99" in o and "off by -1 at C479" in o and "off by 2 at C0" in o
      and "Arrived: 97  off by 1-3: 2  lost: 0  timeouts: 0  READY drops: 0" in o
      and "time min/avg/max ms: 24" in o, repr(o[-500:]))
r.x.seek_errors = {}
o = r.key("T2", "HDIMAGE> ", 200)
check("T2: 958 one-cylinder seeks, all verified, about 15.5 ms each",
      "Seeks: 958" in o and "Arrived: 958" in o and "ms: 15." in o, repr(o[-300:]))
o = r.key("T4", "HDIMAGE> ", 300)
check("T4: 300 random seeks, all verified", "Seeks: 300" in o and "Arrived: 300" in o, repr(o[-300:]))
o = r.key("T5", "HDIMAGE> ", 400)
check("T5: butterfly, 479 seeks (the first, to 0, is no move), all verified, max about 250 ms",
      "Seeks: 479" in o and "Arrived: 479" in o and "/24" in o, repr(o[-300:]))
check("  still no write microcode after the tests", r.x.write_starts == 0)
o = r.key("K", "HDIMAGE> ", 20)
check("K parks the heads at cylinder 525", "parked in the shipping zone" in o and r.x._pos() == 525,
      "%r pos=%d" % (o[-200:], r.x._pos()))
o = r.key("Z", "HDIMAGE> ", 20)
check("  Z afterwards restores to 0", r.x._pos() == 0 and "track-0" in o, repr(o[-200:]))

# --- checksum receiver: 128-byte blocks ------------------------------------------
r = Rig()
r.key("G0100\r", "HDIMAGE> ", 20)
r.key("P", "HDIMAGE> ", 120)
r.key("I7\r7\r", "Start the XMODEM receive", 10)
peer = Receiver(start=r.s.now(), crc=False)
r.u.attach(peer)
o = r.until("HDIMAGE> ", 200)
r.u.sync()
check("checksum receiver: cylinder 7 in 128-byte blocks, intact",
      peer.state == "done" and bytes(peer.data) == expected([7]), repr(o[-200:]))

# --- ^C stops a transfer -----------------------------------------------------------
r.key("I0\r479\r", "Start the XMODEM receive", 10)
peer = Receiver(start=r.s.now())
r.u.attach(peer)
r.until("Cylinder 0 head 1", 60)
r.s.type("\x03")
o = r.until("HDIMAGE> ", 30)
r.u.sync()
check("^C stops the image, the PC's side is cancelled", "Stopped" in o and peer.state != "done",
      repr(o[-200:]))

# --- drive not ready -----------------------------------------------------------------
r = Rig(ready=False)
o = r.key("G0100\r", "HDIMAGE> ", 30)
check("drive not ready: MCPMON's message, no crash", "Drive not Ready" in o, repr(o[-300:]))
o = r.key("P", "HDIMAGE> ", 30)
check("probe on a drive that isn't ready says so", "Drive not Ready" in o, repr(o[-300:]))
o = r.key("Q", ">", 10)
check("Q deselects and returns to MCPMON", r.x.dext == 0 and o.rstrip().endswith(">"), repr(o))

print("\n%d failure(s)" % fails)
sys.exit(1 if fails else 0)
