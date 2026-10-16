#!/usr/bin/env python3
"""Print the two hard disk controller tables from the MCP 80/100 boot ROM.

Usage: decode_hd_tables.py [rom image]   (default: ../rom/mcp_boot_f800.bin)

Table format (as consumed by HDLOADTAB at FD02h):
  byte 0      -> port 64h (area select)
  byte 1      -> port 65h (start pointer)
  then records, all data written to port 66h:
    01h-7Fh   n literal bytes follow
    80h+n     the next byte, repeated n times
    00h       end of table
"""
import os
import sys

BASE = 0xF800
TABLES = [("A", 0xFD47), ("B", 0xFD2C)]   # loaded in this order by HDBOOT


def decode(rom, addr):
    at = lambda a: rom[a - BASE]
    mode, ptr = at(addr), at(addr + 1)
    a = addr + 2
    records, expanded = [], []
    while True:
        n = at(a)
        if n == 0:
            break
        if n & 0x80:
            count, val = n & 0x7F, at(a + 1)
            records.append("%dx%02X" % (count, val))
            expanded += [val] * count
            a += 2
        else:
            vals = [at(x) for x in range(a + 1, a + 1 + n)]
            records.append(" ".join("%02X" % v for v in vals))
            expanded += vals
            a += 1 + n
    return mode, ptr, records, expanded


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "..", "rom", "mcp_boot_f800.bin")
    rom = open(path, "rb").read()
    if len(rom) != 2048:
        sys.exit("expected a 2048-byte image, got %d bytes" % len(rom))
    for name, addr in TABLES:
        mode, ptr, records, expanded = decode(rom, addr)
        print("Table %s at %04Xh: 64h <- %02Xh, 65h <- %02Xh, %d bytes to 66h"
              % (name, addr, mode, ptr, len(expanded)))
        print("  records:  " + " | ".join(records))
        for i in range(0, len(expanded), 16):
            print("  %3d: %s" % (i, " ".join("%02X" % v for v in expanded[i:i + 16])))
        print()


if __name__ == "__main__":
    main()
