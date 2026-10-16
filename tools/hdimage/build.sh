#!/bin/sh
# Build hdimage.hex (MCPMON, load with H, run with G:0100). Two sections:
# the program at 0100h (must end below 1D00h: the stack and the bad list
# are at 1E00h) and the T tests at 2900h (must end below 3200h).
set -e
cd "$(dirname "$0")"
z80asm -i hdimage.asm -o hdimage.bin --label=hdimage.lbl
lbl() { sed -n "s/^$1:[[:space:]]*equ \$\([0-9a-fA-F]*\)/\1/p" hdimage.lbl; }
END=$(lbl CODEEND); TEND=$(lbl TESTEND)
if [ $((0x$END)) -gt $((0x1D00)) ]; then echo "HDIMAGE ends at $END: runs into its stack"; exit 1; fi
if [ $((0x$TEND)) -gt $((0x3200)) ]; then echo "the tests end at $TEND: run into F's buffer"; exit 1; fi
python3 ../bin2hex.py hdimage.bin 0100 hdimage.hex --seg $((0x$END - 0x100)):2900
rm -f hdimage.bin hdimage.lbl
