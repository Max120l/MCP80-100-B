# Roadmap

## Plan

- [x] Reform the PSU filter caps
- [x] Check unloaded rail voltages
- [x] Dump the boot ROM (4 reads, identical) and disassemble it
- [x] Load-test the PSU (+8 V and ±16 V passed)
- [ ] Measure capacitance and ESR of the reformed caps
- [ ] Reinstall the 12,000 µF cap and check the floppy supply
- [ ] Check the outputs of the TO-3 regulator board next to the floppy
- [x] First power-up: drives unplugged, CPU + memory card only, monitor
      prompt at 9600 baud
- [x] Quick RAM check with `F` and `D` (0000–EFFF, patterns 55/AA/00, spot
      checks clean)
- [x] Stage 1: MCPMON 2.0 replacement monitor (port I/O, RAM test, Intel
      HEX load/dump, hard disk sector read), emulator-tested
- [x] Run MCPMON on the machine (2732 with doubled image; original 2716 kept)
- [x] Intermittent address faults found and fixed: socket contacts (DeoxIT,
      chips reseated). ADDRTEST loop rock solid
- [ ] Confirm with `T:0000:EFFF` and a long ADDRTEST loop run
- [x] Hard disk controller: sockets cleaned, installed, bench-checked with no
      drive (buffer, sequencer RAM, status port all OK)
- [ ] Same socket treatment for the remaining cards before installing them
- [x] MiniScribe firmware image: found on bitsavers (40216-12, board
      3000708-01, same as ours), checked
- [x] Burned to a new chip for U20: the drive recalibrates and answers
      select (LED on) on the bench
- [x] First boot of the original system from the MiniScribe (MCPMON `L`)
- [x] Read-only image of the MiniScribe before anything writes to it
- [x] Read cylinder 0 with `R` (OK, and `L` boots the original CP/M)
- [x] Find the compare-buffer byte order: cylinder low, cylinder high,
      head, sector (HDIMAGE's probe on the real drive, 2026-10-12)
- [ ] Document the original BIOS from its own source (MSIOS1.ASM, in
      disk/original-system/). The formatter (MSFMT.ASM) is done: track
      format, sparing and interleave in disk/README.md
- [x] Stage 2: hard disk imager loaded over serial: tools/hdimage (reads
      every sector through the original controller with retries, sends the
      image by XMODEM-1K on port B to Tera Term; no PC-side script needed).
      Simulator-tested against a timed controller + drive model
- [x] Full HDIMAGE runs (2026-10-12): the whole drive read twice, `F` over
      the bad list, merged. 377 files on A: and 211 on B:, all complete; the
      unreadable rest is A:'s damaged directory sectors and free space
- [ ] Optional: the drive on a bench supply with a scope on INDEX and
      +12 V while reading, to pin down the READY dropouts (LED 0111). Not
      through the XCOMP as it stands (write-gate blips)
- [x] MFM (ST-506) target for the EBAZ4205 ESDI emulator: the track format
      from the controller's own writes, then the whole disk synthesised
      from the image. **The MCP boots and runs the 1982 system from it**
      (2026-10-16) ([disk/emulator-target.md](disk/emulator-target.md))
- [ ] Raw read of the MiniScribe's damaged directory sectors: the
      emulator's next board revision in host mode, no XCOMP
- [x] XCOMP gray-mark timer G4 drifted (~560 ns): re-centred to 500 ns,
      read errors and misplaced writes gone (2026-10-16)
- [ ] XCOMP data board: find and fix the 1.6 µs write-gate blips at the
      start of operations (scope WG, P2-13), or block WRITE GATE for
      read-only work. **No real drive on the XCOMP until then**
- [ ] XCOMP data board: the lost last check bit (5–8 % of data writes, a
      race between two clocks)
- [ ] Watch for the write clock at 3/4 rate (seen once): scope 2XCLK/XCLK
      if it recurs
- [x] Serial port B working: null modem to the PC, now 19200 baud. VT52 is
      the console on port A
- [ ] MCPMON 2.1: Intel HEX load from port B, so programs can be sent from
      the PC while the VT52 is the console
- [ ] Stage 3: CP/M 2.2 with a BIOS that uses disk images on the PC over the
      second serial port; later the original BIOS / drives
- [x] Extract the files: `tools/hdimage/hdextract.py` (cpmtools can't
      describe the two logical drives' layout directly)
- [x] The extracted system files (MS*, MCPBOOT/MCPBIOS, DFORMAT, FORMAT,
      the DOCs) into this repository: disk/original-system/. (CRCKLIST.CRC
      only lists data files, none of these)
- [x] Floppy controller: FD1793 registers echo, commands accepted
- [x] 8" drive: selects (no select port needed), steps, finds track 0 after
      cleaning the ribbon connector
- [x] FDTEST written and simulator-tested (live status + rpm, read, format)
- [x] 8" drive identified (Shugart SA850); seized spindle-clamp bearing freed
- [x] Disk speed: spindle 360 rpm (video); FDTEST now calibrates its timing
- [x] Drive READY at 361 rpm, CPU clock measured at 6000 kHz
- [x] Read path works: TRS-80 Model 12 disk, track 0 (FM) read 26/26
- [x] Bench test with a Greaseweazle: the SA850 writes and reads back
      byte-for-byte on outer, middle and inner tracks
- [x] MCP writing works (FDTEST `T` on a clean single-density track). Old
      double-density data underneath defeats the overwrite: erase old disks
      first
- [ ] Optional: does isolating pin 10 (full write current) let the MCP
      overwrite old double-density tracks without erasing?
- [x] CP/M 2.2 on 8" single-sided single density: BIOS (cpm/bios.asm), boot
      sector for the ROM's `B` command, image built with cpmtools, boots in
      the simulator from MCPMON and the original ROM
- [x] First real CP/M boot from the SA850 (MCPMON `B`, 2026-10-11)
- [x] CP/M on the real machine: DIR, STAT, SAVE (writing), PIP with verify,
      FDTEST.COM and its return to CP/M all work
- [x] XM: XMODEM file transfer on port B (cpm/xm.asm), console stays on
      port A; tested in the simulator against a timed 8251 and a scripted
      Tera Term-like PC end
- [x] XM: MCP to PC works on the real machine
- [x] XM: PC to MCP on the real machine (Vezza and a 108K story file)
- [x] Planetfall with Vezza from the 8" disk, on the VT52 (VEZZA52.COM)
- [ ] Side 1 of the SA850: test with a double-sided disk (side select works;
      a single-sided disk shows nothing on side 1)
- [ ] Pin 10 (SA850 write current switch) is held low by the card: isolate it
      (tape over the finger or pull jumper IW) so outer tracks get full current
- [ ] Image any 8" disks

## Open questions

- The CPU runs at 6 MHz (measured). What is the 4.000 MHz crystal for?

- What exactly does reading port 0Ah do? (Probably turns off the ROM copy at
  0000h.)
- Which cards are in the cage? The floppy controller is at F8h; is there a
  second one at 78h, or does the ROM just support both addresses?
- How does the floppy card select drives and density? The ROM never writes
  a select port and drive 1 answers anyway; probably a latch that resets to
  drive 1, or a hard-wired select.
- Is the scratch RAM below F400h really the 2114s on the CPU card? If so, the
  monitor should run with only the CPU card installed.
- Does the memory card have bank-select logic (the chips and header at the
  top)? Was the "128K" in the CP/M list a two-card configuration?
- Microcode word format of the XCOMP controller (not in the schematic,
  which draws the data board as a black box). Table A is 74 bytes but
  starts at D7h, so the buffer address must wrap or the control store is
  larger than 256 bytes.
- Why the MiniScribe image had few data check errors when the controller
  loses a last bit in 5–8 % of writes on the emulator: did the race appear
  recently, or did the real drive's timing avoid it?
- What triggers the MiniScribe's READY dropouts while reading, when the
  spindle is steady at idle and the seek tests run clean?
- What is the board with three TO-3 transistors next to the floppy?
