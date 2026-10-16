# Log

## 2026-10-06

- Reformed the PSU filter caps one at a time on a current-limited bench
  supply. First 64,000 µF: about 12.5 V after 15 min in current limit,
  reached 15 V, 6 mA five minutes later, then below the supply's display
  resolution. Second 64,000 µF behaved the same. Both 11,000 µF reformed
  at 25 V. 12,000 µF (floppy supply) reformed off-board.
- First unloaded power-up of the bare supply (everything disconnected,
  12,000 µF out): +11.9 V, +20 V, −20 V.

## 2026-10-07

- Photographed the machine and the CPU and memory cards.
- Found a CP/M machine list entry: "MCP (128K, Z80, S-100 bus)". This unit
  has one 64K card.
- Dumped the boot EPROM four times: all identical. Disassembled it;
  annotated listing reassembles byte-for-byte.
- Decided: MiniScribe and floppy stay unplugged. Hard disk format to be
  captured with the ESDI emulator board first; imaging once the FPGA reader
  exists.
- Plan changed: image the hard disk through the machine's own controller over
  serial (decoded sectors), starting with cylinder 0. Raw flux capture stays
  optional. Both serial ports (A and B) are on the back panel: console on
  one, transfers on the other.
- Wrote MCPMON 2.0, a replacement monitor for One ROM. 41/41 tests pass in
  an emulator; not yet run on the machine.
- PSU load test passed: +8 V at 9.5 V under a 100 W bulb, ±16 V at about
  ±20 V with 0.22 A, ripple within spec.

## 2026-10-08

- First power-up with cards (CPU + memory card only, drives unplugged): the
  original monitor came up. Console runs at 9600 baud. Card 5 V measured
  5.125 V.
- Dump of F800h over the bus matches the ROM image.
- RAM fill test 0000–EFFF with 55, AA and 00: spot checks all clean.
- Rear serial port A is the console and needs a null modem cable. Port B
  not tried yet.
- MCPMON 2.0 burned to a 2732 (image in both halves) and running in the
  2716 socket.
- MCPMON `T:0000:EFFF`: patterns 00/FF/55/AA pass, address pattern fails
  (0000 read 80, 0001 read 81...). Writes to 8000h+ land on 0000h+: the
  memory card isn't seeing A15. Reproduced exactly in the simulator with an
  A15 alias. Side finding: the scratch RAM at F000–F3FF is separate from the
  memory card (the test overwrote 7300–73FF without disturbing the monitor).
- Follow-up: after `F:0000:EFFF:00` and writing AAh at 8000h, 0000–000F read
  back power-up junk (CF 00 00 FF 00 FF 40 FF...), neither the fill value
  nor the AAh alias. The fault doesn't behave like a cleanly stuck line;
  looks intermittent. Wrote ADDRTEST (tools/addrtest) to pin it down.
- ADDRTEST loop mode: clean until the card was touched, then A7 failed on
  every pass. The fault is mechanical: different address lines (A15, A12–A15,
  A7) failed at different times.
- Fix: DeoxIT and pressing the socketed chips back into their sockets. ADDRTEST
  loop now rock solid.
- Hard disk controller installed (sockets cleaned and reseated first), no
  drive connected: status port reads 30h, data buffer and sequencer RAM read
  back correctly, `R` stops at "Drive not Ready". Controller looks healthy.
- Identified the hard disk controller as an XCOMP ST/S (XS data board
  001785-1 + STS interface board 001790-04). Found its users manual and
  schematic on s100computers.com: full register map now known. The ROM's two
  tables are the controller's read (BANK0) and write (BANK1) microcode; the
  4-byte target ID is the header compare buffer. Format: 32 × 256-byte
  sectors per track.
- Drive is a MiniScribe IV 4020: 480 cylinders, 4 heads, 15.7 MB in this
  format. Needs up to 4.5 A on 12 V at spin-up.
- Front square button is the power lamp.
- MiniScribe connected (spins, cables believed good): `R` gives "Drive not
  Ready". With `O:60:02 O:61:41`, `I:60` = 10h: DRIVE SELECTED/ stays high,
  so the drive never selects. Drive-select lines (pins 26/28/30/32) all read
  low whether selected or not; drive has 5 V. Suspects: missing terminator
  pack and/or missing DS jumper on the drive. Next: inspect the drive's logic
  board around the 34-pin connector.
- Wrote DRIVETEST (tools/drivetest): live drive status, select, head
  select, restore, step and sweep. Never starts the controller microcode.
- Ran MANDEL (tools/mandel), the first demo program: full picture in about
  11 s, which confirms the CPU runs at 4 MHz.

## 2026-10-09

- MiniScribe on the bench. Logic board P/N 3000708: MC6803 + OKI MSM2716AS
  EPROM (U20, window uncovered). Terminator RP1 present; select shunt at E1.
- EPROM reads all 00h every time; the programmer reads the MCP boot ROM
  correctly, so the EPROM itself isn't responding. At power-up the spindle
  starts but the heads never recalibrate. Conclusion: drive firmware lost;
  need a 4020 firmware image from another drive.

## 2026-10-10

- Port B works (PORTB tool, VT52 as console on port A, PC on port B). Port B
  runs at 1200 baud.
- DIP switch decoded: COM5016 rate selects, OFF = 1, board switches 5–8 =
  port A, 1–4 = port B (confirmed by flipping switch 5, which changed the
  console rate).
- Port B set to 19200 (switches 1–4 OFF); `O:00:41` arrives on the PC.
- Floppy controller identified: MCP's own card, FD1793B-02, WD2143-03 clock
  generator, 7438 drivers, 50-pin Shugart connector. Registers at F8h–FBh
  echo (55/AA). Drive power supply checked good.
- First 8" drive tests: status A0 (not ready, head loaded) and no movement.
  After cleaning the ribbon connector the head steps; seek (`O:FB:0A`
  `O:F8:1B`) and restore work, status A4 = track 0 found. Still not ready:
  the motor runs but the spindle doesn't turn, so the belt is broken or
  slipping.
- Wrote FDTEST (tools/fdtest): live status with index period and rpm,
  restore / step / seek, read ID, read + dump sector, read track, and a
  format + pattern write + verify on one track. Polls the status register,
  never the FCh wait port. Added an FD1793 + drive model to the simulator
  (rom/mcpmon/fd1793.py); worst DRQ response in the model is 96 T (24 us)
  against 32 us per byte.
- The disk wasn't turning because the spindle clamp's bearing was seized,
  not the belt. Freed by the owner. Drive identified: Shugart SA850
  (double-sided 8"), 115 V 60 Hz, serial 041504, logic board 25140-0.
- FDTEST on the machine: index pulses arrive, but the disk turns at 221 rpm
  (271 ms per turn) instead of 360, so the drive holds READY off. After
  cleaning the belt and pulleys: 241 rpm. Extra drag on the disk makes the
  belt come off, so it's slipping: belt slack or pulleys out of line. The
  motor is capacitor-run (oval run/start cap), so its speed isn't locked to
  the line. The SA800 belt is a flat rubberized-fabric belt, 22.8" inside
  circumference x 0.193" wide (FRF22.8, per retrotechnology.com); the SA850
  probably takes the same.
- Slow-motion video (240 fps) of the spindle pulley: 9° per frame, one turn
  per 40 frames = 360 rpm. FDTEST's 241 rpm was 1.5x low: the CPU card's
  tall crystal is 6 MHz, and FDTEST had assumed a 4 MHz CPU. FDTEST now
  measures the CPU clock against the console UART (COM5016 crystal) and
  scales the index timing with it. The disk is probably at the right speed,
  so NOT READY has another cause (next: pin 22 READY and pin 14 side select
  at the drive).
- New FDTEST on the machine: `CPU clock 6000 kHz`, status `ST=04 READY TK0
  166.0 ms 361 rpm`. The CPU runs at 6 MHz with no wait states in these
  loops, and the drive now reports READY. The fix was probably DeoxIT on the
  drive's microswitches and connectors while working on it, not the speed
  (the disk was likely near 360 rpm all along).
- Console: a PC terminal (Tera Term) on port A works as well as the VT52 and
  makes loading HEX files simpler.
- **First data read from the 8" drive.** A TRS-80 Model 12 disk (TRSDOS 4.2,
  1983): track 0 is single density, IBM 3740. `A` gave ID `00 00 04 00`,
  `V` read 26/26 sectors, `R01` showed the TRSDOS boot sector text
  ("TRSDOS disk operating system version 4.2. Jan 1, 1983. Copyright 1983
  by Tandy Corporation"). The read path works: drive, cable, data
  separator, FD1793 and FDTEST's polled transfers at 6 MHz.
- First write test: `T` reports `Format: OK`, but afterwards every sector
  write and read on that track gives record-not-found. The format ran on
  track 0 of the TRSDOS disk, which had read 26/26 before; now nothing on it
  reads. Track 0 of a second, untouched TRSDOS disk still reads fine. So the
  drive does switch on write current (the old data is wiped; a
  write-protected disk would have been left alone), but the written data
  isn't readable: suspect the write data path (pin 38, FD1793 WD pin 31,
  the card's precompensation logic, 7438 driver). Added `W` to FDTEST:
  formats repeatedly so the write lines can be watched on a scope.
- Read Track (`K`) on the good disk's track 0 shows the TRSDOS layout with
  varying bit errors and too many bytes per turn; sector reads of the same
  track pass, so Read Track is only a rough view on this card. Heads cleaned.
- SA850 manual: pin 10 is the write current switch (active low = lower
  current for tracks 43–76, jumper IW). If held low on all tracks, writes on
  the outer tracks would be weak: check on the bench. Front LED follows drive
  select, so it's lit all the time on this card.
- Added `C` to FDTEST: head cleaning sweep (zig-zag 0–76, heads loaded).
- Pin 10 on the card connector measures low all the time. On the SA850
  (jumper IW plugged, factory default) pin 10 low selects the lower write
  current, meant for tracks 43–76, so every track gets the low current.
  Strong suspect for the weak writes. Next: isolate pin 10 at the drive
  (tape over the edge-connector finger, or pull the IW plug) and repeat `T`
  on tracks 0 and 76; check whether the card's track-43 signal is on pin 2
  instead (SA800-style cabling).
- Pin 2 is always high and pin 10 always low, even during reads on tracks 0
  and 76: the card has no track-43 output, and pin 10 just holds the drive in
  low write current. But writing also fails on track 76, where low current is
  the right setting, so pin 10 isn't the main fault. Next, on the bench:
  write test with the Greaseweazle on both sides (drive vs MCP card); if the
  drive fails there too, scope the write trigger flip-flop and the two write
  driver transistors; if it passes, compare pin 38 pulse width and level
  between the Greaseweazle and the MCP card.

## 2026-10-11

- SA850 on the bench with a Greaseweazle (Adrian Black's fork with
  `gw-diag`, read-side diagnostics). Wrote tools/gwtest: test images for
  IBM 3740 single density on side 0 and both sides, a two-head disk
  definition, and the write/verify steps.
- Bench, Greaseweazle: `gw-diag` reads the TRSDOS disk's track 0 at
  360.5–360.9 rpm, 26/26 sectors, track 0 sensor OK, disk reads unprotected.
- `gw write --format=dec.rx01` on the scratch disk: track 0 writes and
  verifies even without pre-erase; track 1 fails (old double-density data
  underneath). With `--pre-erase`, tracks 0–2 and 38–40 write and verify;
  track 74 still fails. So the drive's write electronics work; the old
  recordings need a strong overwrite, and the inner tracks are marginal.
  The MCP's failure on track 0 points at the MCP side (pin 10 low = low
  write current). A bulk-erased disk would take old data out of the picture.
- Read-back check (`gw read --format=dec.rx01`, tracks 0–2, 38–40, 74)
  compared byte for byte with the test image: every sector on all seven
  tracks matches, inner track 74 included. The SA850 writes and reads
  correctly on the bench. The MCP write failure is on the MCP side: pin 10
  held low (reduced write current) plus old double-density data underneath.
- Side 1 (Greaseweazle, single-sided scratch disk): erase + write + read on
  h=1 finds nothing, but side 0 is untouched afterwards, so side select
  reaches the drive and it switches heads. Can't tell apart "drive refuses
  side 1 with single-sided media", "unusable side 1 surface" and "head 1
  fault" without a double-sided disk. Parked: CP/M 8" SSSD only needs side 0.
- On the bench with the Greaseweazle, pin 2 is also always high and pin 10
  always low, the same as in the MCP, yet the bench writes were perfect. So
  reduced write current (pin 10) is not the MCP's problem. Same drive, same
  pin states: the difference is the MCP card's write signal. Next: capture
  pin 38 (and 40) on the scope with the Greaseweazle writing as a reference,
  then the same in the MCP during FDTEST `W`.
- Reference capture, Greaseweazle writing, pin 38 at the drive (TDS420A,
  hardware/captures/gw-pin38-write-data.wfm, decoded with tools/tekwfm.py):
  high 5.1 V, low 0.4 V, about -0.2 V undershoot on the falling edge;
  pulses 400 ns wide, 2.0 µs apart (4.0 µs for a 0 bit). Textbook single
  density. Pin 40 (write gate): low one revolution per track, about 3 Hz at
  50% during a whole-side write. Next: the same capture from the MCP card.
- Drive back in the MCP: FDTEST reads the Greaseweazle-written tracks
  correctly, sector labels (`MCP SA850 Cnn H0 Snn`) matching their track and
  sector. Data written by another controller reads fine on the MCP.
- **The MCP writes.** FDTEST `T` on track 1 (Greaseweazle-written, clean
  single density underneath): format, 26 sector writes and the pattern
  read-back all pass. The earlier failures were overwriting old
  double-density TRS-80 data, which this drive's write current (pin 10 held
  low by both controllers) doesn't fully cover. Practical rule: bulk-erase
  (or `gw erase --hfreq`) old disks before formatting them on the MCP.
- MCP write data on pin 38 during FDTEST `W`
  (hardware/captures/mcp-pin38-write-data.wfm): high 5.0 V, low 0.36 V, no
  undershoot, pulses 520 ns wide (the FD1793's single-density write pulse),
  2.0/4.0 µs spacing, edges inside one 40 ns sample. Same as the Greaseweazle
  reference apart from the slightly wider pulses: the card's write signal is
  healthy.
- CP/M 2.2 (cpm/): 60K system (CCP D400h, BDOS DC00h, BIOS EA00h). CCP+BDOS
  relocated from MOVCPM's zero-based image using the relocation map from
  z80pack's 64K build (1072 address bytes, all differing by E4h). Own BIOS:
  console port A, PUN:/LST:/RDR: on port B, drive A: 8" SSSD IBM 3740 on
  the FD1793 with polled transfers and retries. Boot sector fits the
  monitor's B convention (load to 0000h, enter at 007Dh). Disk image with
  the CP/M utilities and FDTEST.COM (FDTEST is now self-contained: same
  program for MCPMON and CP/M). The FDC model now has the FCh wait port
  and image import/export; the simulator boots the image from MCPMON and
  from the original ROM (1.3 s to A>), and DIR, STAT, SAVE/ERA, ^C,
  FDTEST, PIP with verify and PIP from RDR: all work.
- First real CP/M boot: disk written on the bench with the Greaseweazle
  (erase, then `gw write --format=dec.rx01`), drive back in the MCP, `B` at
  the MCPMON prompt: sign-on "MCP 80/100  60K CP/M 2.2  (BIOS 1.0)" and A>.
- On the real machine: DIR (11 files), STAT (197k free), SAVE 1 X.COM,
  PIP C.COM=PIP.COM[V], FDTEST.COM (6000 kHz, 361 rpm) and Q back to A>.
  No errors or retries visible. The MCP writes and verifies files on the
  Greaseweazle-written disk.
- XM (cpm/xm.asm): XMODEM over port B for CP/M, `XM R FILE` / `XM S FILE`.
  Receive: CRC first, checksum fallback, 128 and 1K blocks, data held in
  memory and written 4K at a time (one record per block waited most of a
  disk turn each: 400 B/s; now about 1 KB/s at 19200 baud), FILE.$$$
  renamed only on success, trailing ^Z records of the last block dropped.
  Send: 128-byte blocks, reads 4K ahead. Table-driven CRC. Resets the port
  B 8251 itself. New simulator model rom/mcpmon/uart8251.py: 8251 on a
  timed line with overruns and a scripted far end; test_xm.py runs Tera
  Term-like senders and receivers with corrupted, short and repeated
  blocks. Disk image now has XM.COM (194K free). For the existing disk:
  MCPMON `H` xm.hex, `B`, `SAVE 10 XM.COM`.
- First real XM transfer: MCP to PC works.
- Vezza (Z-machine interpreter for CP/M, vezza-RW build: CP/M 2.2, VT100,
  small TPA) runs in the simulator on this BIOS: Cloak of Darkness compiled
  for z3 with PunyInform loads in 17 s and plays through. XM simulated with
  110K files (Planetfall size): 128-byte blocks (block numbers wrapping)
  864 B/s, 1K blocks 1089 B/s, no overruns; a disk-full during the second
  one was handled (PC cancelled, partial file removed).
- The console is the real VT52, so the VT100 build of Vezza won't do (its
  `ESC [` is Hold Screen on a VT52). Vezza's VT52 builds need CP/M 3 or a
  bigger TPA, and use ESC E / ESC p,q / ESC M, which a real VT52 lacks; it
  also ignores ESC Y with an off-screen row (DECscope Users' Manual). The
  Sinclair QL build (CP/M 2.2, scrolls with CR LF) patched by cpm/vezza52.py:
  25 -> 24 lines (13 constants, found by diffing against the 24-line H19
  build), ESC H ESC J to clear, reverse video and QL highlighting removed.
  Played Cloak of Darkness through a model of a real VT52: correct screen,
  save/restore work.
- On the real machine: XM received VEZZA52.COM and the Planetfall story file
  from the PC, and Planetfall plays on the VT52 with VEZZA52.COM.
- MiniScribe 4020 firmware found on bitsavers: 40216-12_2516.BIN, from a
  drive with logic board P/N 3000708-01 (same as ours). 2048 bytes, RESET
  vector 1800h (EPROM at 1800h-1FFFh in the 6803 map), valid 6803 start-up
  code, part number 40216-12 inside the image, 8-bit checksum 00h.
- Firmware burned and fitted: the drive spins up and the stepper moves (it
  never did before), then keeps stepping. Disassembled the 40216-12 image
  (f9dasm, 6803 mode): I/O map, power-up and recalibrate sequence, the
  exerciser jumper on P16 (pin 19), track 0 sensor on input 0046h bit 6,
  and the front LED's error codes. Written up in disk/README.md.
- The front LED never lights. The firmware lights it for every error code
  and in exerciser mode, so (if the LED works) the drive is stuck in the one
  unbounded loop: recalibrate step 3, creeping outward looking for the track
  0 sensor a second time. Next: measure the track 0 signal at the input port.
- Correction: the drive wasn't stuck. Scoping the input port's enable
  (74LS244 pin 1) showed only a few reads at start-up, which means the
  firmware finished recalibrating and sat in its idle loop (which doesn't
  read the port). The single step seen, the track 0 input high (heads at
  track 0), the dark LED (not selected) and the index output all fit. The
  "stepping" was the stepper humming while powered to hold position.
  Selected on the bench (J1 pin 26 to ground): the LED lights. The
  MiniScribe works again.
- MiniScribe in the MCP: first `R` gave "Drive not Ready" with I:60 = 90h
  (DRIVE SELECTED/ inactive, so READY and TRACK 00 gated off by the drive's
  daisy-chain jumpering). Wiggling the cable fixed it: a flaky contact in
  the drive cabling, to be cleaned or replaced before imaging.
- `L` from MCPMON booted the original system from the MiniScribe: the first
  boot of the machine's own hard disk installation since it was found.
- The original system: "62K MSIOS (16 Meg) / CP/M Vers 2.2 / 28-Oct-82".
  DIR shows the system's own sources (MSBOOT, MSIOS, MSGET/MSPUT/MSRDT,
  MSATS, DFORMAT.ASM, MCPBIOS.HEX, DEBLOCK.ASM, DISKDEF.LIB), CP/M tools,
  WordStar with MailMerge, dBASE-looking files. One directory sector gives
  "Bdos Err On A: Bad Sector" (also at the first prompt); DIR then repeats
  the previous 7 entries. Listing in disk/README.md. Powered down to image
  with retries first.
- HDIMAGE (tools/hdimage): hard disk imager for MCPMON. Init through
  MCPMON's HDINIT, then a probe that finds which header bit carries each
  sector/head/cylinder bit (C0 H0 S0 is 00 00 00 00), reads with retries
  and one recalibrate per track, bad sectors as text fillers plus a list,
  and the image to Tera Term by XMODEM-1K on port B (checksum receivers get
  128-byte blocks). Never starts the write microcode. New simulator model
  rom/mcpmon/xcomp.py (timed controller + drive, any header layout, bad
  sectors), XMODEM peers moved to rom/mcpmon/xmodem_peer.py. Tests pass on
  five header layouts; about 21 s per cylinder, 2.8 h for the drive.
- Full DIR: several hundred files (system tools, dBASE II, MBASIC programs,
  and the previous owners' personal and business files, kept out of the
  public repo). About ten "Bad Sector" errors along the directory, some
  consecutive: looks systematic. HDIMAGE now retries 5 + 10 times (with
  the recalibrate before the 10 on a track's first failure); its bad list
  will show the pattern.

## 2026-10-12

- First HDIMAGE run on the machine. The seeks and the search
  work: two probes gave the layout **cylinder low, cylinder high (bit 0),
  head, sector**, and the check read of C300 H3 S21 passed. But the first
  probe was wrong (`sector 1-16: 1.0 3.0 ...`, a `---` for cylinder 8,
  check failed) and later `R` gave error 80, then "Drive not Ready": the
  drive drops READY/DRIVE SELECTED now and then (the cable again), and a
  read caught by a dropout can come back with no error bits, which the
  search took for a found header. HDIMAGE reworked: the drive status is
  checked after every read as well as before, the probe believes a read
  only when a second one agrees, the known layout is tried first with two
  check reads that between them set all 16 address bits (C300 H3 S21 and
  C243 H0 S10), the search is the fallback, and during imaging a dropout
  means wait up to 60 s, restore and read the sector again; if the drive
  stays away the image is stopped with the cylinder and the whole-cylinder
  size to cut the PC's file at. The model (xcomp.py) got dropouts and
  silent dud reads; yesterday's HDIMAGE fails that test the way the real
  drive fooled it, the new one passes. The 34-pin and 20-pin cables and
  connectors need cleaning or replacing before the 2.8 h run.
- New cables (the old edge sockets were loose): `P` with the reworked
  HDIMAGE gives `Layout OK` in a second. Cylinders 0-1 imaged (64K): 13
  bad sectors, all `02` (ID not found), all on the directory tracks (C0 H2
  worst, 10 of 32), none on the system track or the first data track; the
  same errors the original system hit in `DIR`, so the media, not the
  cable. Format seen in the image: one 8K track per head, two reserved
  tracks (C0 H0 system, C0 H1 empty), a 4-track directory (1024 entries)
  from C0 H2, data from C1 H2. The full image (480 cylinders) started.
- During the full run the drive drops READY now and then, at cylinder and
  head changes, "not super often"; HDIMAGE waits and goes on ("back."),
  nothing lost. The LED blinks 1 fast 3 slow = firmware code 0111, spindle
  speed lock lost and regained: the drive itself, not the cable. Suspects:
  +12 V sagging under the stepper's seek current, the spindle motor/driver,
  index sensor. Test after the run: the drive on the bench supply.
- HDIMAGE `F`: hunts the bad sectors behind damaged IDs (every single-bit
  and single-byte variant of the ID, skipping other sectors' IDs; a hit is
  confirmed by a second read; CRC-error data kept, marked), records to the
  PC by XMODEM, `hdfix.py` puts them into the image. The bad list stays at
  1E00h so a reloaded HDIMAGE can take over the running build's list by
  count. Model: damaged IDs (id_errors), CRC data as read, not-found = 02
  like the real controller. 36 checks pass.
- Full run in progress: READY dropouts every 3-10 cylinders, and the bad
  count climbing by one or two right before each "waiting": the spindle
  drifts for a moment before the firmware drops READY, and the sector
  being read then fails all 15 tries for nothing. HDIMAGE now gives a
  sector that failed all its tries 2 s and a status check: READY gone
  means wait, restore and read it again. For this run, `F`'s first step
  (the expected ID, 3 tries) brings those sectors back as "reads normally
  now". Model: a drift period before a dropout in which reads fail.
- During the run the drive once spun down and back up on its own (the
  firmware's restart after losing speed, or a supply dip resetting its
  MCU); HDIMAGE's 60 s wait covered it and the image went on. 3 MB by
  cylinder 100.
- HDIMAGE `T`: drive tests for after the imaging, all read-only. Spindle:
  the index period per revolution (20 us resolution), a line per 60
  revolutions with average, rpm, min, max and READY drops. Seeks:
  one-cylinder walk, full stroke, random, butterfly, every seek timed to
  SEEK END and verified by reading a header at the target; lands-wrong
  and lost seeks reported and resynced. The program is now two sections
  (the tests at 2900h, bin2hex handles a second org) so the bad list at
  1E00h stays where a reloaded HDIMAGE can take it over. 43 checks pass.
- The bad count climbed to 108 between cylinders 362 and 442 with few
  dropouts there: a band of real read failures. From A:'s directory
  (cylinders 0-1): 4K blocks, 1024 entries, 452 used, 3344K allocated,
  highest block at cylinder 133 — with STAT's ~3000K free, A: is about
  6 MB, so the rest of the disk is a second logical drive (CP/M 2.2's
  8 MB limit); hdlayout.py finds the directories in the full image and
  says which bad sectors are in files, directories or free space;
  hdmap.py lists them by track. `K` parks the heads at cylinder 525 (the
  firmware's shipping position) for power-down; SEEKTO now splits moves
  over 511 cylinders. The full image finished at 13:53 (about 3 h).
- The full image's 202 bad sectors, by hdmap/hdlayout: A:'s directory 14,
  6 singles in A:'s files and 5 in B:'s (one per track, the speed events),
  B:'s directory clean, and a band at cylinders 411-473 (all in B:'s free
  space) where tracks lost their *last* sectors (20-31, 18-31, 29-31) on
  three heads: the controller times sectors from the index, so a spindle
  a few tenths of a percent off loses the end of the track first. Two
  1-track "directories" at C421 H2 and C456 H3 are leftovers of an
  earlier partitioning (block numbers past the disk); hdlayout now says
  so. All errors on the screen 02 (one 04). HDIMAGE now measures the
  index period before every track and before a failing sector's last
  tries and waits for the speed to come back (model: speed excursions
  make the late sectors unreadable); hdmerge.py fills a re-read range
  into the main image. 50 checks pass. Plan: F over the first 128 of the
  list, re-image 400-479, merge; T1 while warm; K; bench supply later.
- T1 for 3 minutes warm: 3601 rpm, no variation, no drops — the spindle
  is fine at idle, so the band wasn't speed. T2-T5: 0 off-by, 0 lost,
  0 drops: the mechanics are fine too. First F run (128 entries): 83
  genuine (the band's sectors read normally on the retry), but 44
  "found as ... 20": every track answers to sector number 32 (a spare,
  or a masked bit) and the hunt took it for the missing sector — the 14
  directory sectors and ~30 scattered singles are real, their IDs answer
  to no single-bit/byte variant. hdfix.py now refuses records whose data
  is another sector's of the track or whose sector number isn't the
  expected one; F keeps the sector field in its candidates and checks a
  hit against the track's other sectors and against the same change on a
  good sector's ID. The band explained in the simulator: a dropout during
  a recalibrate's seek moves the heads with no SEEK END, and the track's
  remaining sectors are "not found" until the next recalibrate. Fixed:
  position unknown after a timeout or dropout (restore before the next
  seek), recalibrate by a short move-and-back with a landing check, full
  restores only if that fails. 52 checks pass. Second full image started
  warm with this build, to merge into the first.
- Second full image started warm: 25 bad sectors on the directory alone
  (14 cold), 50 by cylinder 90 (about 15 cold), dropouts every cylinder
  or two: hot, the drive reads much worse. Stopped at cylinder 90, parked
  with K, powered down; the second pass is for a cold morning.
  hdextract.py: pulls the files of a logical drive out of an image
  (tested against cpmtools-made images with 4K blocks, user areas, a
  filler inside a file). The image and the extracted personal files stay
  off the public repo; only the system files get documented.
- Factory defect list from the drive's label: C345 H0 at 2536 bytes from
  index, C342 H0 at 6941. Both tracks read clean in both images: the
  spare 33rd sector per track ("sector 32") is the formatter's defect
  slip. Second (cold) full image done tonight; directory tracks worse
  than in the morning (24 bad vs 14), the rest to be merged tomorrow;
  drive parked and off, for the shelf.
- Second (cold) full image the same evening; T1 after it: 3601 rpm,
  16.66-16.68 ms, no drops. The factory defect list from the drive's
  label (C345 H0 at 2536 bytes from index, C342 H0 at 6941) is on tracks
  that read 32 good sectors: the "sector 32" every track answers to is the
  defect slip. Drive parked (`K`) and retired to the shelf.

## 2026-10-13

Emulator work (EBAZ4205 board as the drive, MiniScribe on the shelf). The
day-by-day notes are in the emulator project; the controller's side is in
[disk/xcomp_troubleshooting.md](disk/xcomp_troubleshooting.md).

- The XCOMP against the board as a capture drive: MCPMON sees READY,
  TRACK 00, SEEK END, the seek count steps the board's cylinder. MSFMT on
  C0 H0 wrote a clean track and then the **gray marks**: 8 intervals of
  600 ns (illegal in MFM), first about 437 µs after index, one every 504.1 µs,
  33 per revolution. So the XCOMP hard-sectors its own disks.
- Record and replay (one revolution in block RAM): **MSFMT formatted and
  verified C0 H0 on the emulator**. Learned on the way: the controller
  always writes with 20 ns precompensation (the inhibit bit changes
  nothing), bytes go out LSB first, and the gate rises 550–750 ns before
  the first transition.
- **Write-gate blips:** at the start of operations the XCOMP raises WRITE
  GATE for 1.6 µs with a couple of transitions, and one landed on a header
  and destroyed it. On the MiniScribe that's the most likely cause of the
  directory headers no ID variant could find. The emulator now undoes any
  burst under 6.4 µs.
- Once, after a blip, the controller wrote at 3/4 rate (3.75 Mbit/s)
  until the MCP was power-cycled. Not seen again.
- MSRDT (XCOMP's random read/write test, from the MCP's disk, with the
  controller base changed to 60h) runs on the emulator: 4310 passes, 4 %
  of first reads failing, 7 % failing all retries. Photos of its error lines showed the same few
  sectors over and over: two emulator bugs (the last bit of a field lost
  at gate-off, the 4 half-cells after the index never played) and, as it
  turned out, a controller fault.

## 2026-10-14

- MCP console logged to a PC over serial, so MSRDT's lines arrive as text.
- Chasing a "late bit" in a few data fields: the board's pin samples and
  an independent capture agree cycle for cycle. **The controller itself
  writes the last bit of a data field (bit 7 of the second check byte) as
  0** in 5–8 % of data writes, in every capture of every day.

## 2026-10-15

- MSRDT2 (MSRDT with a zero fill): the fill pattern isn't the trigger.
  The lost bit depends on the delay from WRITE GATE to the first bit
  (0.04 % at 540–545 ns, 2–7 % above): a race between two clocks on the
  data board.
- **The check bytes are a 16-bit XOR**, not a CRC: byte 0 = XOR of the
  even bytes, byte 1 = F0h XOR the odd ones (data and headers). Checked on
  19,582 fields. With that, tracks can be built from the disk image.
- Emulator firmware repairs the lost last bit when the XOR says it's the
  only difference; the index-straddling slot (sector 13h) fixed in the
  recorder.
- First reads failing about 4 % in the morning, 7–10 % in the afternoon,
  an A/B test cleared the newest emulator build, which left the
  controller's temperature. Cleaning the trimmers (returned to their
  marks) changed nothing.

## 2026-10-16

- The project moved to its own GitHub repository. Added: notes
  for an MFM target for the EBAZ4205 emulator (disk/emulator-target.md),
  the f9dasm info file for the MiniScribe firmware, the VT52 screen model
  used to check VEZZA52 (rom/mcpmon/vt52.py). The hard disk image and the
  previous owners' files stay out.
- **XCOMP gray-mark timer:** G4 (74LS123 on the interface board) measured
  on the scope against the emulator's marks: ~560 ns instead of the
  design's 500, leaving ~40 ns before marks are missed. Re-centred. MSRDT2:
  soft reads 9.5 % → 0.2 %, misplaced writes 2.6 % → 0. Probably also why
  the MiniScribe read worse warm. With all emulator fixes, 4878 passes:
  0.7 % soft reads, 1 hard read.
- **The whole disk on the emulator:** all 1920 tracks synthesised from the
  image (the controller's own track geometry, the image's IDs and data,
  XOR check bytes), a cylinder at a time in block RAM. **MCPMON `L` booted
  the 1982 CP/M from it**; `DIR` lists A:'s directory. During that boot
  and DIR, no writes at all, the XCOMP blipped WRITE GATE 5 times on the
  directory tracks: the blips come with reads too. Rule: the MiniScribe
  doesn't go back on this XCOMP until the blip is fixed or blocked.
- PIP with verify onto the emulated disk, emulator power-cycled, the file
  still there: writes persist on its SD card. dBASE II runs.
- Added to the repository: the XCOMP troubleshooting summary with its
  photos, scope capture, plots and schematic excerpts
  (disk/xcomp_troubleshooting.md), the track format and the faults in
  disk/README.md, the emulator's status, and the system's own sources from
  the disk (disk/original-system/). They name the maker: MCP Computer
  Products.
