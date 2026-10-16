#!/usr/bin/env python3
"""Run ADDRTEST in the MCP simulator against several memory faults."""
import os, random, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "rom", "mcpmon"))
from mcpsim import MCP

ROM = open(os.path.join(HERE, "..", "..", "rom", "mcpmon", "mcpmon_2716.bin"), "rb").read()
HEX = open(os.path.join(HERE, "addrtest.hex")).read()


def card(s, mapper):
    """Route memory-card writes (0000-EFFF) through mapper(addr) -> list of cells."""
    def w(addr, val):
        if addr >= 0xF000:
            if addr < 0xF800:
                s.m.memory[addr] = val
            return
        for a in mapper(addr):
            s.m.memory[a] = val
    s.m.set_write_callback(w)
    s.m.mark_addrs(0, 0xF000, s.m.WRITE_MARK)


def load(setup=None):
    s = MCP(ROM)
    s.run()
    s.output()
    if setup:
        setup(s)
    s.type("H" + HEX)
    s.run()
    assert "OK" in s.output()
    return s


def run_loop(name, setup=None, ticks=20_000_000):
    s = load(setup)
    s.type("GF003\r")
    try:
        s.run(max_ticks=ticks)
    except RuntimeError:
        pass                      # still looping, as expected
    s.type("x")                   # key press stops it
    s.run()
    print("=== loop: " + name)
    print(s.output())
    return s


def run(name, setup=None):
    s = MCP(ROM)
    s.run()
    s.output()
    if setup:
        setup(s)
    s.type("H" + HEX)
    s.run()
    assert "OK" in s.output()
    s.type("GF000\r")
    s.run(max_ticks=300_000_000)
    print("=== " + name)
    print(s.output())
    return s


def a15_stuck(s):
    card(s, lambda a: [x for x in (a & 0x7FFF, (a & 0x7FFF) | 0x8000) if x < 0xF000])


def a13_stuck(s):
    card(s, lambda a: [a & ~0x2000, a | 0x2000])


def a15_flaky(s):
    rnd = random.Random(1)
    card(s, lambda a: [a & 0x7FFF] if (a & 0x8000 and rnd.random() < 0.3) else [a])


def low_dead(s):
    s.poke(0, bytes([0xCF, 0, 0, 0xFF, 0, 0xFF, 0x40, 0xFF]) * 32)
    s.m.set_write_callback(lambda a, v: None)
    s.m.mark_addrs(0, 0x100, s.m.WRITE_MARK)


if __name__ == "__main__":
    run("good RAM")
    run("A15 ignored", a15_stuck)
    run("A13 ignored", a13_stuck)
    run("A15 flaky (30% of writes)", a15_flaky)
    run("0000-00FF not storing", low_dead)
    run_loop("good RAM")
    run_loop("A15 flaky (30% of writes)", a15_flaky)
