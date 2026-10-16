#!/usr/bin/env python3
"""Boot the CP/M image in the MCP simulator: MCPMON's B command, 6 MHz CPU,
9600-baud console, FD1793 + SA850 model with real timing (out/mcpcpm22.img,
built by build.py)."""
import os, re, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "rom", "mcpmon"))
from mcpsim import MCP
import fd1793
from fd1793 import FD1793, Disk

ROM = open(os.path.join(HERE, "..", "rom", "mcpmon", "mcpmon_2716.bin"), "rb").read()
IMG = open(os.path.join(HERE, "out", "mcpcpm22.img"), "rb").read()
MHZ = 6.0
MS = int(1000 * MHZ)
fd1793.MS = MS                       # the drive's real-time constants, in
fd1793.T_BYTE = int(32 * MHZ)        # T-states of a 6 MHz CPU
fd1793.REV = int(166_666.7 * MHZ)
fd1793.IDX_W = int(1800 * MHZ)
fd1793.SETTLE = 15 * MS

fails = 0
def check(name, cond, detail=""):
    global fails
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else "  " + detail))
    fails += 0 if cond else 1


def until(s, text, seconds=20):
    """Run until `text` shows up in the console output (simulated seconds)."""
    out = ""
    for _ in range(int(seconds * 10)):
        s.ticks(MS * 100)
        out += s.output()
        if text in out:
            return out
    return out


def cmd(s, line, wait="A>", seconds=20):
    s.type(line + "\r")
    return until(s, wait, seconds)


def cpmls(img_bytes):
    with tempfile.NamedTemporaryFile(suffix=".img", delete=False) as f:
        f.write(img_bytes)
    try:
        return subprocess.run(["cpmls", "-f", "ibm-3740", f.name],
                              capture_output=True, text=True).stdout
    finally:
        os.unlink(f.name)


s = MCP(ROM)
s.tx_char_t = MHZ * 1e6 * 10 / 9600
disk = Disk.from_img(IMG)
s.fdc = FD1793(s.now, disk)
s.fdc.head = 20                       # wherever the head was left
s.run(); s.output()

s.type("B")
out = until(s, "A>", 10)
check("B boots CP/M: sign-on and A> prompt",
      "MCP 80/100  60K CP/M 2.2" in out and out.rstrip().endswith("A>"), repr(out[-200:]))

out = cmd(s, "DIR")
check("DIR lists the disk", all(n in out for n in ("PIP", "STAT", "FDTEST", "SYSGEN")), repr(out))

out = cmd(s, "STAT")
check("STAT: A: R/W with 194k free", re.search(r"A: R/W, Space: +194k", out) is not None, repr(out))

out = cmd(s, "STAT DSK:")
check("STAT DSK: shows the 8-inch parameters",
      "243: 128 Byte Record Capacity" in out or "1944: 128 Byte Record Capacity" in out, repr(out))

out = cmd(s, "SAVE 4 TEST.COM")
out = cmd(s, "DIR TEST.COM")
check("SAVE writes a file", re.search(r"TEST +COM", out) is not None, repr(out))
ls = cpmls(disk.to_img())
check("the file is on the disk image (cpmtools sees it)", "test.com" in ls, ls)

out = cmd(s, "ERA TEST.COM")
out = cmd(s, "DIR TEST.COM")
check("ERA deletes it", "NO FILE" in out, repr(out))

s.type("\x03")
out = until(s, "A>", 10)
check("^C warm boot reloads CP/M", out.rstrip().endswith("A>"), repr(out))

out = cmd(s, "FDTEST", wait=" rpm", seconds=10)
m = re.search(r"CPU clock (\d+) kHz", out)
check("FDTEST.COM runs under CP/M (clock ~6000 kHz, 360 rpm)",
      m and abs(int(m.group(1)) - 6000) <= 12 and re.search(r"READY.*36[01] rpm", out) is not None,
      repr(out[-300:]))
s.type("Q")
out = until(s, "A>", 10)
check("FDTEST's Q returns to CP/M (warm boot)", "FDTEST done" in out and out.rstrip().endswith("A>"),
      repr(out[-200:]))

out = cmd(s, "DIR")
check("disk still readable after FDTEST moved the head", "PIP" in out, repr(out))

out = cmd(s, "PIP COPY.COM=PIP.COM[V]", seconds=60)
with tempfile.TemporaryDirectory() as d:
    img = os.path.join(d, "x.img")
    open(img, "wb").write(disk.to_img())
    subprocess.run(["cpmcp", "-f", "ibm-3740", img, "0:copy.com", "0:pip.com", d], check=True)
    same = open(os.path.join(d, "copy.com"), "rb").read() == open(os.path.join(d, "pip.com"), "rb").read()
check("PIP copies PIP.COM with verify, and the copy matches byte for byte", same and "A>" in out, repr(out[-200:]))

s.aux_in.extend(b"HELLO FROM PORT B\r\n\x1a")
out = cmd(s, "PIP HELLO.TXT=RDR:", seconds=20)
out = cmd(s, "TYPE HELLO.TXT")
check("PIP from RDR: (port B) makes a file", "HELLO FROM PORT B" in out, repr(out))

# the same disk boots from the original MCP ROM's B command too
rom0 = open(os.path.join(HERE, "..", "rom", "mcp_boot_f800.bin"), "rb").read()
s2 = MCP(rom0)
s2.tx_char_t = MHZ * 1e6 * 10 / 9600
s2.fdc = FD1793(s2.now, Disk.from_img(IMG))
s2.run(); s2.output()
t0 = s2.now()
s2.type("B")
out = until(s2, "A>", 10)
secs = (s2.now() - t0) / (MHZ * 1e6)
check("original ROM's B boots it too", "60K CP/M 2.2" in out and out.rstrip().endswith("A>"), repr(out[-200:]))
print("     boot to A> took %.2f s (simulated, 6 MHz)" % secs)

print("\n%d failure(s)" % fails)
sys.exit(1 if fails else 0)
