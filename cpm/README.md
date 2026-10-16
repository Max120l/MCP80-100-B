# CP/M 2.2 for the MCP 80/100

A bootable 8" CP/M 2.2 disk for the MCP's own floppy controller and the
Shugart SA850, booted with the monitor's `B` command (MCPMON or the original
ROM).

| File | |
|---|---|
| `bios.asm` | The BIOS (z80asm) |
| `boot.asm` | Boot sector (track 0, sector 1) |
| `build.py` | Builds the system tracks and the disk image |
| `xm.asm` | XM, XMODEM file transfer on port B |
| `vezza52.py` | Patches Vezza's QL build into one for a real DEC VT52 (see below) |
| `test_cpm.py` | Boots the image in the simulator and runs CP/M commands |
| `test_xm.py` | XM transfers in the simulator against a scripted PC end |
| `out/mcpcpm22.img` | The disk image (built, not in git) |
| `xm.hex` | XM as Intel HEX for MCPMON's `H` (built by `build.py`, kept in git) |
| `out/XM.COM` | XM (built) |

## The system

| | |
|---|---|
| Memory | 60K: CCP D400h, BDOS DC00h, BIOS EA00h, buffers to EE3Fh. F000h and up belongs to the CPU card (scratch RAM, ROM) |
| Console | Port A, 8251 at 02h/03h, as set up by the monitor |
| `PUN:`, `LST:` | Port B (00h/01h). Gives up after about a second if port B isn't sending (the 8251 needs CTS) |
| `RDR:` | Port B. `PIP FILE.TXT=RDR:` takes text from the PC until a ^Z |
| Drive | A: only. 8" single-sided single density, IBM 3740: 77 tracks × 26 × 128 bytes, skew 6, 2 system tracks, 1K blocks, 243 KB, 64 directory entries |
| Disk I/O | Polls the FD1793 status register with timeouts and 10 retries (head restored after four). Never uses the FCh wait port |

**Boot:** the monitor's `B` reads track 0 sector 1 to 0000h and enters it at
007Dh. The boot sector reads the other 51 system sectors (CCP, BDOS, BIOS)
to D400h and starts the BIOS. Warm boot reloads the CCP and BDOS (44
sectors) after a restore, so programs that move the head (FDTEST) are fine.

## Disk contents

The CP/M 2.2 utilities `PIP`, `STAT`, `ED`, `ASM`, `LOAD`, `DDT`, `DUMP`,
`SUBMIT`, `XSUB`, `SYSGEN`, plus `FDTEST.COM` (the floppy test, exits back
to CP/M) and `XM.COM` (XMODEM on port B). 194K free.

`SYSGEN` works through the BIOS, so it can copy the system tracks to another
disk with the one drive (it prompts for the disk swap).

## XM: files to and from the PC

XMODEM over serial port B, so the console stays on port A. Port B runs at
the rate set by DIP switches 1-4 (19200 here). On the PC, a second Tera Term
window on port B's COM port, 8N1, does the other end.

| | On the MCP | In the port B Tera Term window |
|---|---|---|
| PC to MCP | `XM R NAME.EXT` | File > Transfer > XMODEM > Send, pick the file |
| MCP to PC | `XM S NAME.EXT` | File > Transfer > XMODEM > Receive, Binary |

- Either side can start first: XM waits 90 s for the PC and ^C, ^X or ESC
  cancels.
- Receiving, XM asks for CRC and falls back to checksum after 30 s. It
  takes 128- and 1K blocks. The file arrives as NAME.$$$ and replaces
  NAME.EXT only when the transfer completes; a failed transfer leaves the
  old file alone.
- XMODEM pads files to whole 128-byte records with ^Z, both ways. That's
  how CP/M stores files anyway.
- About 1 KB/s: blocks collect in memory and go to disk 4K at a time
  (the MCP can't take serial data while the disk is busy, and XMODEM's
  stop-and-wait keeps the PC waiting meanwhile).
- XM resets the port B 8251 to 8N1 itself, so it works after either ROM's
  boot.

**Onto a disk that doesn't have it yet**, without the Greaseweazle: at the
MCPMON prompt, `H` and send `cpm/xm.hex` from Tera Term on port A (as with
FDTEST), wait for `OK`, then `B` to boot CP/M and `SAVE 10 XM.COM`. The
boot doesn't touch memory at 0100h, so SAVE writes out what `H` loaded.

## Infocom games (Vezza)

[Vezza](https://gitlab.com/sijnstra1/vezza) by Shawn Sijnstra runs Z-machine
story files (Infocom's, and Inform games) on CP/M. Two builds fit this
machine, depending on the console:

| Console | Build |
|---|---|
| Tera Term (VT100) | `vezza-RW.com` as is: CP/M 2.2, VT100 codes, small TPA, made with Tera Term in mind |
| Real DEC VT52 | `VEZZA52.COM`, made from `vezza-QL.com` with `python3 vezza52.py vezza-QL.com VEZZA52.COM` |

Vezza's own VT52 builds use the extended VT52 of later machines (ESC E, ESC
p/q reverse video, ESC M delete line), which a real VT52 doesn't have, and
the VT100 build's `ESC [` turns on a VT52's Hold Screen. `vezza52.py`
patches the Sinclair QL build, which already scrolls with CR LF instead of
deleting lines: 24 lines instead of 25 (every height constant, found by
comparing with the 24-line H19 build), ESC H ESC J to clear, no reverse
video or QL highlighting. It then only sends ESC H/J/K/Y, CR, LF, BS and
TAB, in 79 columns. The status line is drawn on the top row at each prompt;
a long reply scrolls it away until the next prompt (a VT52 has no scroll
region). Vezza itself isn't stored here; download it from the Vezza page.

1. `XM R VEZZA.COM` (or `VEZZA52.COM`) and send it from the PC.
2. `XM R GAME.Z3` and send the story file (any platform's Infocom data
   file is the same Z-machine program; `.DAT` or `.Z3`, rename freely).
3. `VEZZA GAME.Z3`. Loading takes 15-20 s. `SAVE`/`RESTORE` ask for a file
   name and use drive A:.

Checked in the simulator with Cloak of Darkness (PunyInform, z3): both
builds load in about 17 s and play through, save and restore work, and the
VT52 build's output was played into a model of a real VT52
([`rom/mcpmon/vt52.py`](../rom/mcpmon/vt52.py), escape codes and cursor
addressing per the DECscope Users' Manual): the only codes it
doesn't take are two off-screen cursor moves while the first status line is
drawn, which a VT52 ignores and which are followed by a correct one. Story
files up to about 110K transfer fine with XM (simulated, 128-byte and 1K
blocks; 864 and 1089 bytes/s). Type after the prompt appears: a key pressed
while text is still printing can get lost.

## Making the disk (Greaseweazle)

Old disks first need erasing: this drive writes with reduced current (pin 10
is held low), which doesn't overwrite old double-density recordings cleanly.

```
gw erase --hfreq --tracks=c=0-76:h=0
gw write --format=dec.rx01 mcpcpm22.img
```

`gw write` reads every track back. Then in the MCP: disk in, door shut,
`B` at the monitor prompt.

## Building

```
python3 build.py
```

Needs z80asm, cpmtools and git. On first run it fetches CP/M from z80pack
(https://github.com/udo-munk/z80pack), which packages Digital Research's
distribution:

- `MOVCPM.COM` holds a CCP + BDOS image assembled for address 0000h; z80pack's
  `cpm.bin` holds the same image relocated for 64K (E400h). The 1072 bytes
  that differ are exactly the address high bytes (all differ by E4h), which
  gives the relocation map. `build.py` adds D4h to them for 60K.
- The utilities come from z80pack's CP/M 2.2 distribution disk.

CP/M 2.2 is distributed under the 2022 grant from DRDOS, Inc. (owner of
Digital Research's assets), which allows using, modifying and distributing
CP/M and its derivatives. The built image and the fetched files are not
stored in this repository.

## Testing

```
python3 test_cpm.py
python3 test_xm.py
```

The simulator boots the image through MCPMON's `B` at 6 MHz with the
FD1793/drive model (real disk timing, including the FCh wait port the
monitor's boot uses), then runs `DIR`, `STAT`, `SAVE`/`ERA` (checked with
cpmtools on the resulting image), ^C, `FDTEST`, `PIP` with verify (copy
compared byte for byte), `PIP` from `RDR:`, and a boot from the original
ROM. Boot to `A>` takes about 1.3 s.

`test_xm.py` puts a timed 8251 on port B (19200 baud, overruns modelled)
with a Python XMODEM sender or receiver at the far end, behaving like Tera
Term's, and checks receiving (CRC, checksum, 128 and 1K blocks, 20K across
an extent, corrupted/short/repeated blocks, a PC cancel, ^C), sending (CRC
and checksum receivers, NAKs, no receiver) and getting XM onto a disk with
`H`, `B` and `SAVE`.
