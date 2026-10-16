#!/usr/bin/env python3
"""Run PORTB in the MCP simulator."""
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "rom", "mcpmon"))
from mcpsim import MCP

ROM = open(os.path.join(HERE, "..", "..", "rom", "mcpmon", "mcpmon_2716.bin"), "rb").read()
HEX = open(os.path.join(HERE, "portb.hex")).read()

def ticks(s, n):
    done = 0
    while done < n:
        s.m.ticks_to_stop = 20000
        s.m.run()
        done += 20000

fails = 0
def check(name, cond, detail=""):
    global fails
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else "  " + detail))
    fails += 0 if cond else 1

s = MCP(ROM)
s.run(); s.output()
s.type("H" + HEX); s.run(); assert "OK" in s.output()
status = {"dsr": False, "fe": False}
orig = s.inp
def inp(port):
    port &= 0xFF
    if port == 0x01:
        v = 0x05 | (0x02 if s.aux_in else 0)
        if status["dsr"]: v |= 0x80
        if status["fe"]: v |= 0x20
        return v
    return orig(port)
s.m.set_input_callback(inp)

s.type("G0100\r"); ticks(s, 3_000_000)
out = s.output()
check("banner and first status report", "PORTB:" in out and "DSR off" in out, repr(out))
check("beacon sent on port B", b"MCP port B says hello #00" in bytes(s.aux_out), repr(bytes(s.aux_out)))
s.aux_in.extend(b"hi from PC"); ticks(s, 2_000_000)
check("port B -> console", "hi from PC" in s.output(), "")
s.type("abc"); ticks(s, 2_000_000)
check("console -> port B", bytes(s.aux_out).endswith(b"abc") or b"abc" in bytes(s.aux_out), repr(bytes(s.aux_out)[-40:]))
status["dsr"] = True; ticks(s, 2_000_000)
check("DSR change reported", "DSR on" in s.output(), "")
status["fe"] = True; ticks(s, 1_000_000); status["fe"] = False; ticks(s, 1_000_000)
out = s.output()
check("framing error reported", "FRAMING ERROR" in out, repr(out))
check("errors cleared with 37h", (0x01, 0x37) in s.port_log[-50:], "")
ticks(s, 20_000_000)
check("beacon repeats with counter", b"#01" in bytes(s.aux_out), repr(bytes(s.aux_out)[-60:]))
s.type("\x1b"); s.run()
out = s.output()
check("ESC returns to MCPMON", "PORTB done" in out and out.rstrip().endswith(">"), repr(out))
print("\n%d failure(s)" % fails)
sys.exit(1 if fails else 0)
