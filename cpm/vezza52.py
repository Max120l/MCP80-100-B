#!/usr/bin/env python3
"""Make a Vezza build for a real DEC VT52 from Vezza's Sinclair QL build.

    python3 vezza52.py vezza-QL.com VEZZA52.COM

Vezza (https://gitlab.com/sijnstra1/vezza, Shawn Sijnstra) runs Infocom and
Inform story files on CP/M. Its VT52 builds use the extended VT52 found on
later machines (Atari ST, Amstrad, Heath H19): ESC E clear screen, ESC p/q
reverse video, ESC M delete line. A real VT52 has none of those, and it
ignores an ESC Y whose row is off the screen. The QL build is the closest:
CP/M 2.2, small TPA, and it scrolls with CR LF at the bottom instead of
deleting lines. What it lacks for a VT52:

  - 25 lines: the bottom row would be off a VT52's screen, so every height
    constant drops by one (compared against the 24-line H19 build, which
    differs from the QL build in exactly these places)
  - ESC E to clear the screen: ESC H ESC J instead
  - ESC p / ESC q reverse video and the QL's ^R / ^S highlighting: removed
    (the <-More-> prompt gets spaces instead)

The result only sends ESC H, ESC J, ESC K, ESC Y (rows 0-23), CR, LF, BS
and TAB. The status line is drawn on the top row before each input; text
scrolls the whole screen, so the status line scrolls away with it and is
drawn again at the next prompt. 79 columns, so nothing is written in the
VT52's last column (where the cursor sticks).

Vezza isn't stored in this repository; this script patches a downloaded
vezza-QL.com (Release Serial 250209) and checks every byte it changes.
"""
import hashlib
import sys

QL_SHA256 = "d54f79b73f3481800ff3bc06b7373d2f1d6affd81bcfd07e4af15b1f3fa0c8db"
ORG = 0x100

# operand of each instruction that holds a screen height (QL: 25 lines)
HEIGHT = [0x05f5, 0x0612, 0x06de, 0x07b6, 0x080c, 0x0828, 0x0835, 0x0839,
          0x089d, 0x09a1, 0x09ed, 0x0f53, 0x12f6]

# terminal strings ($-terminated, printed with BDOS 9): address, old, new
STRINGS = [
    (0x0559, b"\x1bH\x1bE$", b"\x1bH\x1bJ$"),             # clear screen
    (0x0561, b"\x1bM", b"$M"),                             # delete line (unused)
    (0x056e, b"\x1bp <-More-> \x1bq$", b"   <-More->   $"),
    (0x0585, b"\x1bp$", b"$$$"),                           # reverse on
    (0x0588, b"\x12$", b"$$"),                             # QL highlight
    (0x058a, b"\x13\x1bq$", b"$$$$"),                      # normal
]

BANNER_OLD = b"for CP/M 2.2 for 79x25 QL"
BANNER_NEW = b"for CP/M 2.2 / VT52 79x24"


def patch(data):
    if hashlib.sha256(data).hexdigest() != QL_SHA256:
        sys.exit("not the expected vezza-QL.com (Release Serial 250209)")
    b = bytearray(data)
    for a in HEIGHT:
        o = a - ORG + 1                       # the immediate after the opcode
        if b[o] not in (0x17, 0x18, 0x19):
            sys.exit("unexpected height constant at %04X" % a)
        b[o] -= 1
    for a, old, new in STRINGS:
        o = a - ORG
        if bytes(b[o:o + len(old)]) != old or len(old) != len(new):
            sys.exit("unexpected string at %04X" % a)
        b[o:o + len(new)] = new
    o = b.find(BANNER_OLD)
    b[o:o + len(BANNER_NEW)] = BANNER_NEW
    return bytes(b)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__.split("\n\n")[1])
    out = patch(open(sys.argv[1], "rb").read())
    open(sys.argv[2], "wb").write(out)
    print("%s: %d bytes, for a real VT52 (79x24)" % (sys.argv[2], len(out)))
