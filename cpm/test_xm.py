#!/usr/bin/env python3
"""XM (XMODEM on port B) in the MCP simulator.

CP/M boots from out/mcpcpm22.img (build.py) at 6 MHz. Port B is a timed
8251 on a 19200-baud line (rom/mcpmon/uart8251.py) whose far end is a
Python XMODEM sender or receiver behaving like Tera Term's, with errors
injected: corrupted, short and repeated blocks, NAKs, cancels.
"""
import os, random, re, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "rom", "mcpmon"))
from mcpsim import MCP
import fd1793
from fd1793 import FD1793, Disk
from uart8251 import Uart8251
from xmodem_peer import Sender, Receiver, Silent, crc16

ROM = open(os.path.join(HERE, "..", "rom", "mcpmon", "mcpmon_2716.bin"), "rb").read()
IMG = open(os.path.join(HERE, "out", "mcpcpm22.img"), "rb").read()
MHZ = 6.0
MS = int(1000 * MHZ)
SEC = 1000 * MS
fd1793.MS = MS
fd1793.T_BYTE = int(32 * MHZ)
fd1793.REV = int(166_666.7 * MHZ)
fd1793.IDX_W = int(1800 * MHZ)
fd1793.SETTLE = 15 * MS
CHAR_T = int(MHZ * 1e6 * 10 / 19200)      # port B: 19200 baud, 10 bits


fails = 0
def check(name, cond, detail=""):
    global fails
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else "  " + detail))
    fails += 0 if cond else 1


def until(s, text, seconds):
    out = ""
    for _ in range(int(seconds * 10)):
        s.ticks(MS * 100)
        out += s.output()
        if out.rstrip().endswith(text):
            return out
    return out


def cmd(s, line, seconds=20):
    s.type(line + "\r")
    out = until(s, "A>", seconds)
    if s.aux is not None:
        s.aux.sync()            # deliver XM's last bytes to the PC end
    return out


def disk_file(disk, name):
    with tempfile.TemporaryDirectory() as d:
        img = os.path.join(d, "x.img")
        open(img, "wb").write(disk.to_img())
        r = subprocess.run(["cpmcp", "-f", "ibm-3740", img, "0:" + name, d],
                           capture_output=True)
        p = os.path.join(d, name)
        return open(p, "rb").read() if r.returncode == 0 and os.path.exists(p) else None


def disk_ls(disk):
    with tempfile.NamedTemporaryFile(suffix=".img", delete=False) as f:
        f.write(disk.to_img())
    try:
        return subprocess.run(["cpmls", "-f", "ibm-3740", f.name],
                              capture_output=True, text=True).stdout.split()
    finally:
        os.unlink(f.name)


def padded(data, records=None):
    n = records if records is not None else (len(data) + 127) // 128
    return data.ljust(n * 128, b"\x1a")


s = MCP(ROM)
s.tx_char_t = MHZ * 1e6 * 10 / 9600
disk = Disk.from_img(IMG)
s.fdc = FD1793(s.now, disk)
uart = Uart8251(s.now, CHAR_T, Silent())
s.aux = uart
s.run(); s.output()
s.type("B")
out = until(s, "A>", 10)
assert "60K CP/M 2.2" in out, out
rnd = random.Random(1980)


def receive(name, peer, seconds=60):
    uart.attach(peer)
    uart.overruns = 0
    t0 = s.now()
    out = cmd(s, "XM R " + name, seconds)
    return out, (s.now() - t0) / SEC


out = cmd(s, "XM")
check("XM alone prints the usage", "XM R FILE.EXT" in out and "XM S FILE.EXT" in out, repr(out))

# --- PC -> MCP --------------------------------------------------------------
data1 = bytes(rnd.randrange(256) for _ in range(5000))
peer = Sender(data1)
out, secs = receive("TEST.COM", peer)
f = disk_file(disk, "test.com")
check("receive, CRC, 128-byte blocks: file arrives intact (40 records)",
      peer.state == "done" and f == padded(data1) and "TEST.COM received: 40 records (5K)" in out,
      repr(out[-200:]))
check("port B reset to 8N1 x16 (40h, 4Eh, 37h) and no overruns",
      uart.ctl[-3:] == [0x40, 0x4E, 0x37] and uart.overruns == 0 and uart.mode == 0x4E,
      "%r %d" % (uart.ctl[-6:], uart.overruns))
print("     5000 bytes in %.1f s" % secs)

data2 = bytes(rnd.randrange(256) for _ in range(2200))
peer = Sender(data2, one_k="all")
out, secs = receive("TEST.COM", peer)
f = disk_file(disk, "test.com")
ls = disk_ls(disk)
check("receive, CRC, 1K blocks: replaces TEST.COM, padding records dropped (18 records)",
      peer.state == "done" and f == padded(data2) and len(f) == 18 * 128
      and ls.count("test.com") == 1 and "test.$$$" not in ls, "%r %r" % (out[-200:], ls))

data3 = bytes(rnd.randrange(256) for _ in range(20000))
peer = Sender(data3, one_k="mixed", corrupt={2}, short={4}, dup={6})
out, secs = receive("BIG.DAT", peer, seconds=120)
f = disk_file(disk, "big.dat")
check("receive 20000 bytes (past a 16K extent) with a corrupted, a short and a repeated block",
      peer.state == "done" and f == padded(data3) and peer.naks == 2 and uart.overruns == 0
      and "retries: 2" in out, "naks=%d %r" % (peer.naks, out[-200:]))
print("     20000 bytes, 1K blocks, in %.1f s (%.0f bytes/s)" % (secs, 20000 / secs))

data4 = b"Plain text from the PC.\r\n" * 20
peer = Sender(data4, crc_ok=False)
out, secs = receive("OLD.TXT", peer, seconds=60)
f = disk_file(disk, "old.txt")
check("receive from a checksum-only sender: XM falls back to NAK after 30 s",
      peer.state == "done" and f == padded(data4) and not peer.crc and 29 < secs < 40,
      "%r %.1f" % (out[-200:], secs))

peer = Sender(data1, cancel_after=2)
out, secs = receive("GONE.COM", peer)
ls = disk_ls(disk)
check("PC cancels mid-transfer: XM stops, nothing saved",
      "Cancelled by the PC, nothing saved" in out and "gone.com" not in ls and "gone.$$$" not in ls,
      "%r %r" % (out[-200:], ls))

uart.attach(Silent())
s.type("XM R NOPE.COM\r")
out = until(s, "(^C cancels)\r\n", 5)
s.ticks(2 * SEC)
s.type("\x03")
out += until(s, "A>", 5)
ls = disk_ls(disk)
check("^C while waiting cancels, no file left",
      "Cancelled, nothing saved" in out and "nope.com" not in ls and "nope.$$$" not in ls,
      "%r %r" % (out[-200:], ls))

# --- MCP -> PC --------------------------------------------------------------
stat = disk_file(disk, "stat.com")
peer = Receiver(start=s.now() + 2 * SEC, nak={3})
uart.attach(peer)
t0 = s.now()
out = cmd(s, "XM S STAT.COM", 60)
secs = (s.now() - t0) / SEC
check("send, CRC receiver started 2 s later, block 3 NAKed once: data intact",
      peer.state == "done" and bytes(peer.data) == stat and "STAT.COM sent: 40 records (5K), retries: 1" in out,
      "%r len=%d/%d" % (out[-200:], len(peer.data), len(stat)))
print("     %d bytes in %.1f s" % (len(stat), secs))

peer = Receiver(start=s.now(), crc=False)          # started before XM
uart.attach(peer)
out = cmd(s, "XM S BIG.DAT", 90)
check("send, checksum receiver started first: data intact",
      peer.state == "done" and bytes(peer.data) == padded(data3), repr(out[-200:]))

out = cmd(s, "XM S NOFILE.COM")
check("send a missing file: 'File not found'", "File not found" in out, repr(out))

uart.attach(Silent())
t0 = s.now()
out = cmd(s, "XM S STAT.COM", 100)
check("send with no receiver gives up after 90 s",
      "no XMODEM receive started" in out and 89 < (s.now() - t0) / SEC < 95, repr(out[-200:]))

out = cmd(s, "DIR")
check("DIR afterwards", all(n in out for n in ("XM", "TEST", "BIG", "OLD")), repr(out))

# --- Getting XM onto an existing disk: MCPMON H, boot, SAVE ---------------
hexf = open(os.path.join(HERE, "xm.hex")).read()
xmcom = open(os.path.join(HERE, "out", "XM.COM"), "rb").read()
s2 = MCP(ROM)
s2.tx_char_t = MHZ * 1e6 * 10 / 9600
d2 = Disk.from_img(IMG)
s2.fdc = FD1793(s2.now, d2)
s2.run(); s2.output()
s2.type("H" + hexf); s2.run()
ok = "OK" in s2.output()
s2.type("B")
out = until(s2, "A>", 10)
pages = (len(xmcom.rstrip(b"\x1a")) + 255) // 256
out = cmd(s2, "SAVE %d XM2.COM" % pages)
out = cmd(s2, "XM2")
saved = disk_file(d2, "xm2.com")
n = len(xmcom.rstrip(b"\x1a"))
check("H xm.hex, B, SAVE %d XM2.COM gives a working XM" % pages,
      ok and saved is not None and saved[:n] == xmcom[:n] and "XM R FILE.EXT" in out, repr(out))

print("\n%d failure(s)" % fails)
sys.exit(1 if fails else 0)
