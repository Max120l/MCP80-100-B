#!/usr/bin/env python3
"""Run DRIVETEST in the MCP simulator against a simple ST-506 drive model."""
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "rom", "mcpmon"))
from mcpsim import MCP

ROM = open(os.path.join(HERE, "..", "..", "rom", "mcpmon", "mcpmon_2716.bin"), "rb").read()
HEX = open(os.path.join(HERE, "drivetest.hex")).read()


class Drive:
    """XCOMP drive ports 60h-63h plus a MiniScribe-like drive."""
    def __init__(self, responds=True):
        self.responds = responds      # False = drive never selects (DS jumper wrong)
        self.dext = 0
        self.cmd = 0
        self.count = 0
        self.cyl = 137                # wherever the heads were left
        self.stepping = 0
        self.idx = False
        self.reads = 0
        self.ccmd_writes = []

    def selected(self):
        return self.responds and (self.dext & 1)

    def out(self, port, val):
        if port == 0x60:
            if val & 1 and not self.cmd & 1:
                self.stepping = self.count        # rising SEEK: issue the pulses
            self.cmd = val
        elif port == 0x61:
            self.dext = val
        elif port == 0x62:
            self.count = (self.count & 0x100) | val
            if self.count == 0: self.stepping = 0
        elif port == 0x63:
            self.count = (self.count & 0xFF) | ((val & 1) << 8)
            if self.count == 0: self.stepping = 0
        elif port == 0x64:
            self.ccmd_writes.append(val)

    def inp(self, port):
        if port == 0x61:
            self.idx = False
            return 0xFF
        if port != 0x60:
            return 0xFF
        self.reads += 1
        if not self.selected():
            return 0x10 | (0x20 if self.idx else 0)
        if self.reads % 500 == 0:
            self.idx = True
        if self.stepping and self.cmd & 1 and self.reads % 3 == 0:
            if self.dext & 2:
                self.cyl = min(self.cyl + 1, 479)
            else:
                self.cyl = max(self.cyl - 1, 0)
            self.stepping -= 1
        seeking = self.stepping > 0 and self.cmd & 1
        v = 0x01
        if self.cyl == 0: v |= 0x04
        if not seeking: v |= 0x08 | 0x80
        if self.idx: v |= 0x20
        return v


def machine(responds=True):
    s = MCP(ROM)
    d = Drive(responds)
    s.inp_orig, s.out_orig = s.inp, s.out
    def inp(port):
        port &= 0xFF
        return d.inp(port) if 0x60 <= port <= 0x63 or port == 0x64 else s.inp_orig(port)
    def out(port, val):
        port &= 0xFF
        if 0x60 <= port <= 0x64:
            d.out(port, val)
        s.out_orig(port, val)
    s.m.set_input_callback(inp)
    s.m.set_output_callback(out)
    s.run(); s.output()
    s.type("H" + HEX); s.run()
    assert "OK" in s.output()
    return s, d


def ticks(s, n):
    done = 0
    while done < n:
        s.m.ticks_to_stop = 20000
        s.m.run()
        done += 20000


def key(s, k, n=8_000_000):
    s.type(k)
    ticks(s, n)


fails = 0
def check(name, cond, detail=""):
    global fails
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else "  " + detail))
    fails += 0 if cond else 1


# drive that never selects (today's situation)
s, d = machine(responds=False)
s.type("G0100\r"); ticks(s, 12_000_000)
out = s.output()
check("banner + status line", "DRIVETEST" in out and "ST=10" in out and "[sel on]" in out, repr(out[-160:]))
key(s, "Z"); out = s.output()
check("Z refuses when not selected", "Drive not selected" in out, repr(out[-120:]))

# working drive
s, d = machine()
s.type("G0100\r"); ticks(s, 12_000_000)
out = s.output()
check("status shows SEL RDY", " SEL RDY" in out, repr(out[-160:]))
check("index pulses counted", "IDX=0000" not in out.split("\r")[-1], repr(out.split("\r")[-1]))
key(s, "I"); out = s.output()
check("I refuses before restore", "restore first" in out, repr(out[-120:]))
key(s, "Z", 20_000_000); out = s.output()
check("Z restores to track 0", "Restore... OK" in out and d.cyl == 0, repr(out[-160:]) + " cyl=%d" % d.cyl)
key(s, "I"); key(s, "I"); key(s, "I"); key(s, "O")
check("I/O step the heads", d.cyl == 2, "cyl=%d" % d.cyl)
ticks(s, 12_000_000); out = s.output()
check("status shows CYL=0002", "CYL=0002" in out, repr(out[-120:]))
key(s, "2"); ticks(s, 12_000_000); out = s.output()
check("head select 2 -> port 61 bits 2-4", (d.dext >> 2) & 7 == 2 and "HD=2" in out, hex(d.dext))
key(s, "W", 30_000_000); key(s, "x", 6_000_000); out = s.output()
check("sweep runs and stops on a key", out.count(".") >= 2 and d.cyl in (0, 200), repr(out[-120:]) + " cyl=%d" % d.cyl)
key(s, "S"); ticks(s, 12_000_000); out = s.output()
check("S deselects", (d.dext & 1) == 0 and "[sel off]" in out, hex(d.dext))
key(s, "Q", 2_000_000); out = s.output()
check("Q deselects and returns to MCPMON", d.dext == 0 and out.rstrip().endswith(">"), repr(out[-60:]))
check("never starts the controller (port 64 bit 3)", all(not (v & 8) for v in d.ccmd_writes), str(d.ccmd_writes))

print("\n%d failure(s)" % fails)
sys.exit(1 if fails else 0)
