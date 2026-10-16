#!/usr/bin/env python3
"""Tests for MCPMON 2.0 in the MCP simulator. Run: python3 test_mcpmon.py"""
import sys
from mcpsim import MCP

ROM = open(sys.argv[1] if len(sys.argv) > 1 else "mcpmon_2716.bin", "rb").read()
fails = 0


def check(name, cond, detail=""):
    global fails
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else "  " + detail))
    if not cond:
        fails += 1


def fresh(**kw):
    s = MCP(ROM, **kw)
    s.run()
    s.output()
    return s


def cmd(s, text):
    s.type(text)
    s.run()
    return s.output()


def ihex(addr, data, rectype=0):
    rec = bytes([len(data), addr >> 8, addr & 0xFF, rectype]) + data
    cs = (-sum(rec)) & 0xFF
    return ":" + (rec + bytes([cs])).hex().upper() + "\r\n"


# ---- boot ---------------------------------------------------------------
s = MCP(ROM)
s.run()
out = s.output()
check("banner and prompt", "MCPMON 2.0" in out and out.endswith(">"), repr(out))
inits = [(p, v) for p, v in s.port_log if p in (1, 3)]
check("8251 reset sequence on both ports",
      inits[:6] == [(1, 0), (1, 0), (1, 0), (1, 0x40), (1, 0x4E), (1, 0x37)]
      and inits[6:12] == [(3, 0), (3, 0), (3, 0), (3, 0x40), (3, 0x4E), (3, 0x37)], str(inits))
check("8255 init like original", (7, 0xA2) in s.port_log and (7, 0x0B) in s.port_log)
check("port 0Ah read at reset: not checked by sim (input)", True)

# ---- help, bad command ---------------------------------------------------
out = cmd(s, "?")
check("help text", "R:iiiiiiii" in out and "hex load" in out, repr(out))
out = cmd(s, "Z")
check("unknown command -> ?", out.startswith("Z?"), repr(out))
out = cmd(s, "\r")
check("empty line -> new prompt", out.endswith(">"), repr(out))

# ---- D ---------------------------------------------------------------------
out = cmd(s, "DF800F81F")
lines = [l for l in out.split("\r\n") if l.startswith("F8")]
check("dump: two lines", len(lines) == 2, repr(out))
check("dump: first bytes are JP COLD", lines and lines[0].startswith("F800 C3"), repr(lines[:1]))
out = cmd(s, "d:f800:f80f")
check("lowercase and typed colons accepted", "F800 C3" in out, repr(out))
out = cmd(s, "DF810F800")
check("dump with end < start -> ?", "?" in out, repr(out))

# ---- S -----------------------------------------------------------------
out = cmd(s, "S1000" + "3E" + "41" + " " + "99" + "\r")
check("substitute stores bytes, space skips",
      s.peek(0x1000, 4) == bytes([0x3E, 0x41, 0x00, 0x99]), s.peek(0x1000, 4).hex())
out = cmd(s, "SF900" + "12" + "\r")
check("substitute into ROM shows '!'", "!" in out, repr(out))
out = cmd(s, "S1000" + "G")
check("bad hex digit in S -> ? and prompt", out.endswith("?\r\n>"), repr(out))

# ---- F / M -------------------------------------------------------------
cmd(s, "F100010FFAA")
check("fill", s.peek(0x1000, 256) == b"\xAA" * 256 and s.peek(0x1100) == b"\x00")
s.poke(0x3000, bytes(range(32)))
cmd(s, "M3000301F4000")
check("move forward", s.peek(0x4000, 32) == bytes(range(32)))
cmd(s, "M3000301F3001")
check("move overlapping upward", s.peek(0x3001, 32) == bytes(range(32)), s.peek(0x3000, 34).hex())
s.poke(0x5000, bytes(range(32)))
cmd(s, "M5001501F5000")
check("move overlapping downward", s.peek(0x5000, 31) == bytes(range(1, 32)))

# ---- I / O -------------------------------------------------------------
out = cmd(s, "I60")
check("I reads port", "=85" in out, repr(out))   # ready + track0 + seek complete
cmd(s, "O6512")
check("O writes port", (0x65, 0x12) in s.port_log[-10:], str(s.port_log[-10:]))

# ---- T -----------------------------------------------------------------
out = cmd(s, "T00003FFF")
check("RAM test passes on good RAM", out.endswith(" OK\r\n>"), repr(out[-40:]))
out = cmd(s, "TF000F3FF")
check("RAM test refuses monitor RAM", out.endswith("?\r\n>"), repr(out))
out = cmd(s, "TF2F0F300")
check("RAM test refuses range ending in monitor RAM", out.endswith("?\r\n>"), repr(out))
sf = fresh(fault=(0x2345, 0x10))
out = cmd(sf, "T20002FFF")
check("RAM test finds stuck bit", "2345" in out and "FAIL" in out, repr(out[-80:]))

# ---- H -----------------------------------------------------------------
prog = bytes(range(0x30, 0x30 + 40))
hexfile = ihex(0x6000, prog[:16]) + ihex(0x6010, prog[16:32]) + ihex(0x6020, prog[32:]) \
    + ":00000001FF\r\n"
out = cmd(s, "H" + hexfile)
check("HEX load", s.peek(0x6000, 40) == prog and "... OK" in out, repr(out))
bad = ihex(0x6100, b"\x01\x02\x03")
bad = bad[:-4] + "00" + "\r\n"            # wrong checksum
out = cmd(s, "H" + bad + ":00000001FF\r\n")
check("HEX load reports bad checksum", "E" in out and "FAIL" in out, repr(out))
lower = ihex(0x6200, b"\xab\xcd").lower()
out = cmd(s, "H" + lower + ":00000001ff\r\n")
check("HEX load accepts lowercase", s.peek(0x6200, 2) == b"\xab\xcd", repr(out))

# ---- X -----------------------------------------------------------------
s.poke(0x7000, bytes(range(40)))
out = cmd(s, "X70007027")
recs = [l for l in out.split("\r\n") if l.startswith(":")]
ok = True
data = bytearray()
for r in recs:
    b = bytes.fromhex(r[1:])
    ok &= (sum(b) & 0xFF) == 0
    if b[3] == 0:
        data += b[4:4 + b[0]]
check("hex dump records valid", ok and recs[-1] == ":00000001FF", repr(recs))
check("hex dump data matches", bytes(data) == bytes(range(40)), data.hex())
out = cmd(s, "XFFF0FFFF")
check("hex dump at top of memory ends cleanly",
      [l for l in out.split("\r\n") if l.startswith(":")] == [":10FFF000" + "FF" * 16 + "11", ":00000001FF"], repr(out))

# ---- R -----------------------------------------------------------------
sector = bytes((i * 7 + 3) & 0xFF for i in range(256))
s.hdc.sectors[bytes([0, 0, 0, 5])] = sector
out = cmd(s, "R00000005")
check("R reads sector into 8000h", s.peek(0x8000, 256) == sector and "OK -> 8000" in out, repr(out))
check("R used ID 00000005", s.hdc.reads[-1] == bytes([0, 0, 0, 5]))
check("R loaded table A into area 0 at D7h",
      bytes(s.hdc.areas[0][0xD7:0xDD]) == bytes([0x40, 0x41, 0x40, 0x40, 0x40, 0x6D]),
      bytes(s.hdc.areas[0][0xD7:0xDD]).hex())
out = cmd(s, "R00000099")
check("R on missing sector -> Read Failed with status", "Read Failed" in out and " 02" in out, repr(out))
s.hdc.ready = False
out = cmd(s, "R00000005")
check("R with drive not ready", "Drive not Ready" in out, repr(out))
s.hdc.ready = True

# ---- L -----------------------------------------------------------------
# boot sector: print 'BOOT' via the ROM's CONOUT vector, then return to the monitor
boot = bytes([0x21, 0x10, 0x00,        # ld hl,0010h
              0x7E,                    # loop: ld a,(hl)
              0xB7,                    # or a
              0xCA, 0x03, 0xF8,        # jp z,F803h (WARM)
              0xCD, 0x0C, 0xF8,        # call F80Ch (CONOUT)
              0x23,                    # inc hl
              0xC3, 0x03, 0x00,        # jp loop
              0x00]) + b"BOOT\0"
s.hdc.sectors[bytes(4)] = boot.ljust(256, b"\0")
s.hdc.track0 = False
out = cmd(s, "L")
check("L restores, reads sector 0, runs it", "BOOT" in out, repr(out))
check("L stepped out (HD_DRV=03h during restore)", (0x60, 0x03) in s.port_log)

# ---- B / A -------------------------------------------------------------
out = cmd(s, "B")
check("B tries both floppy controllers and reports status",
      "FD status 10" in out and (0xF8, 0x6B) in s.port_log and (0x78, 0x88) in s.port_log, repr(out))

# ---- G and the jump table ------------------------------------------------
prog = bytes([0x3E, 0x41, 0xCD, 0x0C, 0xF8,      # ld a,'A' / call CONOUT
              0x3E, 0x5A, 0xCD, 0x15, 0xF8,      # ld a,'Z' / call AUXOUT
              0xC3, 0x03, 0xF8])                 # jp WARM
s.poke(0x2000, prog)
out = cmd(s, "G2000\r")
check("G runs code; vectors CONOUT/AUXOUT/WARM work", "A" in out and s.aux_out.endswith(b"Z"), repr(out))
out = cmd(s, "G2000X")
check("G without CR cancels", "A" not in out.split("X", 1)[-1], repr(out))

# ---- aborts ------------------------------------------------------------
out = cmd(s, "D\x03")
check("^C aborts parameter entry", out.endswith(">"), repr(out))
s.poke(0x0000, bytes(0x100))
s.type("D00000FFF")
s.type("x")          # key press during dump
s.run()
out = s.output()
check("key press stops a long dump", "^C" in out and out.count("\r\n") < 200, str(out.count("\r\n")))

print("\n%d failure(s)" % fails)
sys.exit(1 if fails else 0)
