#!/bin/sh
# Build fdtest.hex (MCPMON, load with H) and FDTEST.COM (CP/M).
set -e
cd "$(dirname "$0")"
z80asm -i fdtest.asm -o fdtest.bin --label=fdtest.lbl
python3 ../bin2hex.py fdtest.bin 0100 fdtest.hex
python3 - <<'PY'
import re
lbl = open("fdtest.lbl").read()
exitjp = int(re.search(r"^EXITJP:\s+equ \$([0-9a-fA-F]+)", lbl, re.M).group(1), 16)
b = bytearray(open("fdtest.bin", "rb").read())
off = exitjp - 0x100
assert b[off] == 0xC3 and b[off + 1:off + 3] == b"\x03\xf8", "EXITJP not found"
b[off + 1:off + 3] = b"\x00\x00"           # CP/M: JP 0000h (warm boot)
b += b"\x1a" * (-len(b) % 128)             # whole records, padded with ^Z
open("FDTEST.COM", "wb").write(b)
print("FDTEST.COM: %d bytes" % len(b))
PY
rm -f fdtest.bin fdtest.lbl
