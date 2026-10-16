# The original system software

The MCP's own system files, extracted from the MiniScribe's image
(2026-10-12, `tools/hdimage/hdextract.py`, logical drive A:). They are
the byte-exact CP/M files: CRLF text in 128-byte records, padded with ^Z
(1Ah) after the end of the text. Published here for preservation; the
image and everything else on the drive stay private ([../README.md](../README.md)).

They name the company: the floppy BIOS is headed **"MCP COMPUTER
PRODUCTS"**, the hard disk BIOS **"MCP COMPUTER PRODUCTS CONFIGURATION
12-01-82"**, and the floppy formatters were modified by **J. (Jim) Yates of
MCP Computer Products** (December 1980).

## XCOMP's MiniScribe software (hard disk)

XCOMP shipped CP/M support software with the ST/S controller. The docs
below describe the version for Rotating Memory Systems drives (RMS*.ASM);
these MS*.ASM files are the MiniScribe versions of the same programs
(`DRSIZE EQU 4` = MS-4020, two logical 7.8 MB drives), most set up for the
MCP (`CBASE EQU 60H`; XCOMP's standard is 70h). All for Digital Research's
MAC assembler.

| File | Date | What it is |
|---|---|---|
| `MSIOS1.ASM`, `.HEX` | 12-01-82 | The BIOS: hard disk A: and B:, floppies C: and D: on the MCP floppy card. Sign-on "62K MSIOS (16 Meg)" |
| `MSBED.ASM`, `.HEX` | 10-28-82 | Back end driver: adds the hard disk to an existing floppy CBIOS (see BED.DOC) |
| `MSMDC.ASM` | 10-28-82 | Moves MSBED's code to its target address |
| `MSBOOT.ASM`, `.HEX` | 08-02-82 | Bootstrap loader for the hard disk, started by a ROM boot such as MCPMON's `L` |
| `MSGET.ASM` | 10-28-82 | Boots CP/M from the hard disk as a COM file (`CBASE 70H`, not adapted) |
| `MSPUT.ASM` | 10-28-82 | Writes the system onto the hard disk (`CBASE 70H`) |
| `MSFMT.ASM`, `.HEX` | 10-27-82 | Formatter: gray marks, 33 headers, surface test with the worst-case pattern, sector sparing, interleave 10 (16 on a 2 MHz CPU) |
| `MSVER.ASM` | 10-27-82 | Reads (verifies) the whole disk |
| `MSRDT.ASM` | 10-27-82 | Random read/write test (`CBASE 70H`: assemble with 60H on the MCP). **Destroys data** |
| `MSATS.ASM` | 12-02-81 | Alternate track seek test (controller and drive step logic) |
| `MSBT.ASM` | 07-28-82 | Controller buffer test |
| `MSOFF.ASM` | 10-27-82 | Parks the heads on the landing zone |
| `DISK.DOC` | | The program list (RMS names) |
| `BRINGUP.DOC` | | Installation and test order: buffer test, seek test, format, random test |
| `SYSBLD.DOC` | | Building a CP/M system with the hard disk BIOS |
| `BED.DOC` | | The back end driver |

What the formatter and the BIOS say about the track format, the sparing
and the logical drives is in [../README.md](../README.md) and
[../xcomp_troubleshooting.md](../xcomp_troubleshooting.md). Several
programs here write to the disk (MSFMT, MSRDT, MSPUT): on this machine,
only against the emulator, never the MiniScribe.

One damaged spot: `MSVER.ASM` has 256 bytes of the formatter's fill
pattern (6D B3 ...) instead of text at offset 4A00h (line 990, inside the
sector-table setup). That sector is that way on the disk: the image read
it without error.

## MCP's floppy software

| File | Date | What it is |
|---|---|---|
| `MCPBIOS.ASM`, `.HEX` | | CP/M 2.2 BIOS for the MCP floppy card (FD1793): auto density select, single or double sided; track 0 single density 26 × 128, double density 51 × 128 on tracks 1-76; console on ports 02h/03h. Sign-on "\*\*MCP\*\* 62K CP/M" |
| `MCPBOOT.ASM`, `.HEX` | | Its cold start loader |
| `DFORMAT.ASM` | 12-21-81 | Floppy formatter for the WD1793 (interleaved sectors, 52 sectors per track, double sided); Tarbell lineage (G. W. Mulchin), modified by J. Yates of MCP |
| `DFORMAT.Z80` | 7/16/81 | The same program in Z80 mnemonics, "DFORMAT PROGRAM OF 7/16/81 MCP CONTROLLER" |
| `FORMAT.ASM` | 6-4-80 | Older formatter: written by Dick Culbertson (1977), modified by Don Tarbell, Marc Farjeon, Jerry Mulchin, then Jim Yates (December 1980) "for use with new controller board" |
## Left out

Digital Research's sample BIOS sources (`BIOS.ASM`, `CBIOS.ASM`) and
library files, dBASE II's notes and files, `CRCKLIST.CRC` (a checksum list
of the previous owners' data files; it covers none of the files above),
and everything that isn't system software.
