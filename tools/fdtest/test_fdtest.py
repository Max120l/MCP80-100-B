#!/usr/bin/env python3
"""Run FDTEST in the MCP simulator against the FD1793 + 8" drive model."""
import os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "rom", "mcpmon"))
from mcpsim import MCP
import fd1793
from fd1793 import FD1793, Disk

ROM = open(os.path.join(HERE, "..", "..", "rom", "mcpmon", "mcpmon_2716.bin"), "rb").read()
HEX = open(os.path.join(HERE, "fdtest.hex")).read()
MS = 4000
MHZ = 4.0


def set_clock(mhz):
    """Simulate a CPU clock: the model's real-time constants scale with it."""
    global MS, MHZ
    MHZ = mhz
    MS = int(1000 * mhz)
    fd1793.MS = MS
    fd1793.T_BYTE = int(32 * mhz)
    fd1793.REV = int(166_666.7 * mhz)
    fd1793.IDX_W = int(1800 * mhz)
    fd1793.SETTLE = 15 * MS

fails = 0
def check(name, cond, detail=""):
    global fails
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else "  " + detail))
    fails += 0 if cond else 1


def boot(disk=None, spinning=True):
    s = MCP(ROM)
    s.tx_char_t = MHZ * 1e6 * 10 / 9600     # console: 9600 baud 8N1
    s.fdc = FD1793(s.now, disk, spinning)
    s.run(); s.output()
    s.type("H" + HEX); s.run(); assert "OK" in s.output()
    s.type("G0100\r")
    s.ticks(2000 * MS)
    return s


def key(s, k, ms=1500):
    s.type(k)
    s.ticks(ms * MS)
    return s.output()


def status_lines(out):
    """Complete status lines only (they end with the padding)."""
    return [l for l in out.split("\r") if l.startswith("ST=") and l.endswith("      ")]


# ---- drive with no spinning spindle (motor runs, belt gone) ----------------
s = boot(Disk(), spinning=False)
out = s.output()
st = status_lines(out)
check("help printed", "FDTEST" in out and "Q quit" in out, repr(out[:200]))
m = re.search(r"CPU clock (\d+) kHz", out)
check("clock measured: 4000 kHz", m and abs(int(m.group(1)) - 4000) <= 8, repr(m and m.group(0)))
check("calibration sends only NULs (195 of them)", "\0" * 195 in out and out.count("\0") == 195, "count %d" % out.count("\0"))
check("no spin: not-ready, no index", st and "not-ready" in st[-1] and "no index" in st[-1], repr(st[-1:]))
r = key(s, "A")
check("A refuses when not ready", "Drive not ready" in r, repr(r))
r = key(s, "Z", 3000)
check("Z restore works without spin (Type I)", s.fdc.head == 0 and "TK0" in status_lines(r)[-1], repr(status_lines(r)[-1:]))

# ---- good drive, IBM-formatted disk -------------------------------------------
s = boot(Disk())
st = status_lines(s.output())
m = re.search(r"(\d+\.\d) ms (\d+) rpm", st[-1]) if st else None
check("status: READY + period/rpm", m and "READY" in st[-1], repr(st[-1:]))
if m:
    check("period ~166.7 ms, 360 rpm", abs(float(m.group(1)) - 166.7) <= 0.2 and int(m.group(2)) == 360, m.group(0))
st = status_lines(key(s, "Z"))
check("restore: TRK=00 TK0", s.fdc.head == 0 and "TRK=00" in st[-1] and "TK0" in st[-1], repr(st[-1:]))
for _ in range(3):
    key(s, "I", 600)
st = status_lines(key(s, "O", 600))
check("step in x3, out x1 -> track 2", s.fdc.head == 2 and s.fdc.tr == 2 and "TRK=02" in st[-1], "head %d tr %d" % (s.fdc.head, s.fdc.tr))
r = key(s, "S40", 2500)
check("S40 seeks to 40", s.fdc.head == 40 and s.fdc.tr == 40, "head %d" % s.fdc.head)
r = key(s, "A", 600)
check("A reads an ID on track 40", re.search(r"ID: 28 00 [0-9A-F]{2} 00 12 34", r) is not None, repr(r))
r = key(s, "V", 9000)
check("V: 26/26 on a formatted track", "." * 26 in r and "good: 26/26" in r, repr(r))
check("no lost data during V", "L" not in r.split("Read:")[1].split("good")[0], repr(r))
r = key(s, "K", 3500)
m = re.search(r"Read track: (\d+) bytes", r)
check("K: read track returns a full revolution", m and abs(int(m.group(1)) - 5208) <= 2, repr(r[:120]))
check("K: counts and dump of an IBM track", re.search(r"FF:\d+", r) and re.search(r"E5:3\d\d\d", r) and "0000:" in r and " FC" in r, repr(r[:400]))
r = key(s, "R05", 800)
check("R05 dumps 128 bytes of E5", "  OK" in r and r.count(" E5") == 128 and "0070:" in r, repr(r[:300]))

# ---- T on a blank disk ---------------------------------------------------------
disk = Disk(formatted=False)
s = s_t = boot(disk)
key(s, "Z"); key(s, "S12", 1500)
r = key(s, "V", 25000)
check("V on blank track: all R, not-found", "R" * 26 in r and "good: 00/26" in r and "not-found" in r, repr(r))
r = key(s, "A", 2000)
check("A on blank track: not-found", "not-found" in r, repr(r))
r = key(s, "K", 3500)
check("K on blank track: noise, few E5", re.search(r"E5:\d{1,2}\b", r) is not None and "lost" not in r, repr(r[:300]))
r = key(s, "TN", 300)
check("T then N cancels", "cancelled" in r and not disk.tracks, repr(r))
r = key(s, "TY", 16000)
check("T: format OK", "Format: OK" in r, repr(r))
secs = disk.sectors(12)
check("track parsed into 26 sectors with IDs 12/0/n/0",
      len(secs) == 26 and all(x["id"] == (12, 0, i + 1, 0) for i, x in enumerate(secs)), repr([x["id"] for x in secs][:5]))
check("T: 26 sectors written", "Write:  " + "." * 26 in r, repr(r))
check("T: pattern verified 26/26", r.count("good: 26/26") == 1 and "P" not in r.split("Read:")[-1], repr(r))
exp = bytes(((12 * 7 + 5 * 13 + i) & 0xFF) for i in range(128))
check("sector 5 holds the pattern", bytes(secs[4]["data"]) == exp, bytes(secs[4]["data"][:8]).hex())
check("other tracks untouched", list(disk.tracks.keys()) == [12], repr(list(disk.tracks.keys())))

r = key(s, "V", 1500)
r += key(s, "x", 1500)
check("a key stops V early", "good:" in r and r.count(".") < 26, repr(r))
n0 = sum(1 for e in s.fdc.log if e[1] == "track")
r = key(s, "WY", 2000)
r += key(s, "x", 1000)
n1 = sum(1 for e in s.fdc.log if e[1] == "track")
check("W formats repeatedly until a key", "Formatting" in r and r.count(".") >= 4 and n1 - n0 >= 4 and "E" not in r.split("stops:")[1].split("\r")[0], "%d formats, %r" % (n1 - n0, r[-80:]))
r = key(s, "V", 9000)
check("track still readable after W", "good: 26/26" in r, repr(r[-60:]))

# ---- C: cleaning sweep ------------------------------------------------------------
s = boot(Disk())
heads = []
orig_t1 = s.fdc._type1
def t1(c, t):
    orig_t1(c, t)
    heads.append(s.fdc.head)
s.fdc._type1 = t1
r = key(s, "CN", 300)
check("C then N cancels", "cancelled" in r and not heads, repr(r))
r = key(s, "CY", 8000)
check("C sweeps in to track 76 with the head loaded", max(heads) == 76 and s.fdc.hld and r.count(".") > 20, "max %d, %r" % (max(heads) if heads else -1, r[-60:]))
mid = len(heads)
r += key(s, "x", 3000)
check("a key stops the sweep and it restores to track 0", "Sweep done" in r and s.fdc.head == 0 and s.fdc.tr == 0, repr(r[-80:]))
heads.clear()
r = key(s, "CY", 32000)
check("full sweep: two passes, ends on track 0", "Sweep done" in r and s.fdc.head == 0 and r.split("stops: ")[1].split("Sweep done")[0].count(".") == 2 * 74,
      "%d stops, %r" % (r.count("."), r[-80:]))

# ---- write protect ---------------------------------------------------------------
s = boot(Disk(wp=True))
st = status_lines(s.output())
check("WPROT shown", "WPROT" in st[-1], repr(st[-1:]))
r = key(s, "T", 300)
check("T refuses on a protected disk", "write protected" in r, repr(r))

# ---- slow drive (300 rpm: 50 Hz pulley on 60 Hz, or the reverse) -----------------
fd1793.REV = 800_000
s = boot(Disk())
st = status_lines(s.output())
m = re.search(r"(\d+\.\d) ms (\d+) rpm", st[-1])
check("300 rpm drive: 200.0 ms (+-0.3), 300 rpm", m and abs(float(m.group(1)) - 200.0) <= 0.3 and int(m.group(2)) == 300, repr(st[-1:]))
fd1793.REV = 666_667

# ---- 6 MHz CPU: the readout must not change; transfers get more margin ------------
set_clock(6.0)
disk6 = Disk(formatted=False)
s = s6 = boot(disk6)
out = s.output()
m = re.search(r"CPU clock (\d+) kHz", out)
check("6 MHz: clock measured 6000 kHz", m and abs(int(m.group(1)) - 6000) <= 12, repr(m and m.group(0)))
st = status_lines(out)
m = st and re.search(r"(\d+\.\d) ms (\d+) rpm", st[-1])
check("6 MHz: still 166.7 ms (+-0.3), 360 rpm", m and abs(float(m.group(1)) - 166.7) <= 0.3 and int(m.group(2)) == 360, repr(st[-1:]))
key(s, "Z", 1000)
r = key(s, "TY", 16000)
check("6 MHz: T formats, writes and verifies 26/26", "Format: OK" in r and "good: 26/26" in r, repr(r[-200:]))
print("     6 MHz worst DRQ response: %s; one byte = %d T" % (s6.fdc.max_lat, fd1793.T_BYTE))
set_clock(4.0)

# ---- timing margin: worst time from DRQ to the CPU servicing it ----------------
lat = s_t.fdc.max_lat
worst = max(lat.values())
print("     worst DRQ response (T-states at 4 MHz): %s; one byte = %d T" % (lat, fd1793.T_BYTE))
check("all transfer kinds measured", set(lat) >= {"wt", "ws", "rs"}, repr(lat))
check("worst DRQ response under 100 T (25 us, byte time 32 us)", worst < 100, str(worst))

# ---- quit ------------------------------------------------------------------------
s = boot(Disk())
s.type("Q"); s.run()
out = s.output()
check("Q returns to MCPMON", "FDTEST done" in out and out.rstrip().endswith(">"), repr(out[-80:]))
check("never touched port FC", all(p != 0xFC for p, v in s.port_log), "")

print("\n%d failure(s)" % fails)
sys.exit(1 if fails else 0)
