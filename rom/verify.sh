#!/bin/sh
# Reassemble the annotated listing and check it matches the dumped ROM.
# Needs z80asm (Debian/Ubuntu: apt install z80asm).
set -e
cd "$(dirname "$0")"
z80asm -i mcp_boot.asm -o rebuilt.bin
if cmp -s rebuilt.bin mcp_boot_f800.bin; then
    echo "OK: mcp_boot.asm reassembles byte-for-byte to mcp_boot_f800.bin"
    rm -f rebuilt.bin
else
    echo "MISMATCH: rebuilt.bin differs from mcp_boot_f800.bin"
    cmp -l rebuilt.bin mcp_boot_f800.bin | head
    exit 1
fi
