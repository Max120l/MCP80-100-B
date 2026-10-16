# MFM (ST-506) target for the EBAZ4205 ESDI emulator

Notes for adding an ST-506/MFM target to the FPGA ESDI emulator (EBAZ4205
boards), with the MCP 80/100 as its test bench. Written 2026-10-12.

## Why
The MCP 80/100's hard disk is a MiniScribe 4020 (ST-506/MFM, 1983) on an
XCOMP ST/S controller. It has been fully imaged (read twice; 377 + 211
files extracted, all complete), and goes on the shelf. An MFM target for
the emulator would let the MCP run its 1982 installation from the image,
and the same board in reader mode is the flux-level reader needed for the
sectors the controller can't find (damaged ID fields, mostly on A:'s
directory tracks).
Firmware-only is the goal. Controller and drive notes: [README.md](README.md);
the imager and test programs: [../tools/hdimage/](../tools/hdimage/README.md).

## The drive the controller expects
- 480 cylinders × 4 heads × 32 sectors × 256 bytes (8K per track, 15,360K).
- Buffered seeks: STEP pulses with DIRECTION, the drive steps and raises
  SEEK COMPLETE; the controller sends a 9-bit step count. Position limit
  525 (the firmware's shipping zone; beyond it the real drive recalibrates).
- Status lines the controller reads (port 60h): READY, WRITE FAULT,
  TRACK 00, SEEKING/, DRIVE SELECTED/ (low = selected), INDEX (latched),
  SEEK END. The real drive only asserts READY after spin-up + recalibrate;
  its LED is lit when selected. Radial/daisy-chain jumpering: with the
  jumper open, status lines are only driven while selected.
- 3600 rpm: index every 16.667 ms. The XCOMP finds sectors by timing from
  the index (its status has DELAYED INDEX and SECTOR bits), so index
  placement and sector spacing matter, not only the bits.
- Sector ID as the controller matches it: 4 bytes = cylinder low,
  cylinder high (bit 0), head, sector (0–31). Cyl 0 head 0 sector 0 is
  the boot sector, ID 00 00 00 00. Every track on the real drive also
  answers to an ID with sector number 32 (20h): the spare that slips a
  defect (the two factory defects, C342 H0 at 2536 bytes from index and
  C345 H0 at 6941, are on tracks that read 32 good sectors). A raw track
  read will show where it sits.
- Not yet known (needs one raw track from the real drive, or MSFMT.ASM /
  DFORMAT.ASM from the extracted files, which are the formatter sources):
  sync bytes, address marks, ID/data CRC polynomials, gap lengths,
  interleave, and how the spare is placed.

## Cabling: the pinout is on our side
- 20-pin data cable: ST-506 pins 13/14 = MFM WRITE DATA (controller →
  drive), 17/18 = MFM READ DATA (drive → controller), 1 = DRIVE SELECTED.
  ESDI uses the same pairs for NRZ write data (13/14) and NRZ read data
  (17/18): the board's existing receiver and driver are on the right lines.
- The ESDI outputs on pins 2, 3 (sector/AM found, command complete) and
  the clock pairs 7/8 and 10/11 land on ST-506 GROUND pins. In MFM mode
  those drivers must be tri-stated. If their enables are under PL control
  it is firmware-only; if they are hardwired enabled, one enable pin lifted
  or an adapter cable. That is the only hardware question.
- 34-pin control cable: lines up well between ESDI and ST-506 (select,
  step, direction, head select, write gate; READY, TRACK 0, INDEX, SEEK
  COMPLETE, WRITE FAULT back). The MFM target is a dumb-drive state
  machine on the same pins, no serial command channel.
- MFM at 5 Mbit/s: 10 MHz cell clock; a sampling PLL at 40–50 MHz in the
  PL is comfortable. Read path: MFM encoder from the image. Write path
  (needed for the formatter and for writes): MFM decoder with its own PLL.

## Test bench already written ([tools/hdimage](../tools/hdimage/README.md), on the MCP, over serial)
- `P`: ID layout check (two reads that set every address bit).
- `T 1`: index period per revolution, 20 µs resolution, READY drops.
- `T 2`–`T 5`: one-cylinder walk, full stroke, random, butterfly; every
  seek timed to SEEK END and verified by reading a header at the target.
- `I`: image a cylinder range to the PC by XMODEM; compare with the real
  image (`hdmerge.py` reports sectors that differ).
- [`rom/mcpmon/xcomp.py`](../rom/mcpmon/xcomp.py): a timed software model of the controller + drive
  used by the simulator tests — a second reference for what the controller
  expects (seek timing, index latch, status bits, dummy first read, etc.).
- Finish line: the MCP boots the 1982 system ("62K MSIOS (16 Meg) / CP/M
  Vers 2.2 / 28-Oct-82") from the emulator with MCPMON's `L`.

## Order of work
1. Schematic check: driver enables on 20-pin pins 2, 3, 7/8, 10/11.
2. Reader mode first: capture raw tracks from the real drive (cold) →
   the exact bit-level format, the sector-32 question, and the 44 sectors.
3. Emulator mode: play the image back in that format; run P, T, I against
   it; then boot the MCP from it.
