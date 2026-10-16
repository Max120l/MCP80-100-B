# FDTEST

Interactive test for the 8" floppy on MCP's floppy controller (FD1793 at
F8h–FBh). It shows the drive status live, including disk speed, and covers
restore, step, seek, reading sector IDs and sectors, and a format/write/read
test on a single track.

Single density only (IBM 3740: 77 tracks, 26 × 128-byte sectors, FM).

FDTEST never reads port FCh, the board's wait port. That port stalls the CPU
until the controller answers, so a dead drive could hang the machine.
FDTEST polls the 1793's status register instead and times out after about
4 s.

FDTEST talks to the console itself, so it doesn't depend on the monitor
ROM. `build.sh` makes both `fdtest.hex` (load with `H`, `Q` returns to
MCPMON) and `FDTEST.COM` for CP/M (`Q` warm-boots CP/M); the CP/M disk in
[../../cpm/](../../cpm/README.md) includes it.

**Load and run** (MCPMON's `H` reads from the console, port A):

1. Plug the PC into port A, type `H`, send `fdtest.hex` and wait for `OK`.
2. Without powering off, move the VT52 back to port A. The program stays
   in RAM.
3. On the VT52, type `G:0100` and press Enter.

It loads at 0100h–0DEFh and uses 2000h–38FFh (track image) and 4000h–43FFh
(sector buffer). Needs the memory card.

## CPU clock

At start (and with `?`) FDTEST prints the CPU clock it measured:

```
CPU clock 6000 kHz (measured against the console at 9600 baud)
```

It sends 195 NUL characters to the console (terminals ignore them) and
counts its own loops while the UART shifts them out. The UART's baud clock
comes from the COM5016's separate 5.0688 MHz crystal, so this is an
independent reference. The rpm readout uses this measurement, so it's right
whatever the clock. The number is the *effective* clock: wait states would
make it read lower than the crystal. If the console isn't at 9600 baud the
number is off by the same ratio (19200 shows half).

The first version assumed 4 MHz. On this machine it showed 241 rpm while a
slow-motion video of the spindle pulley showed 360, exactly the 1.5 ratio of
a 6 MHz CPU.

## Status line

The status line redraws in place about once a second:

```
ST=24 TRK=00 READY HEAD TK0 166.7 ms 360 rpm
```

| Field | Meaning |
|---|---|
| `ST=` | Raw 1793 status (Type I) |
| `TRK=` | The 1793's track register: where it thinks the head is |
| `READY` / `not-ready` | The drive's READY line. On 8" drives this needs a disk in, the door shut and the disk spinning |
| `WPROT` | Disk is write protected. On 8" disks that usually means the notch is **open** |
| `HEAD` | Head loaded. The 1793 unloads it after 15 idle revolutions |
| `TK0` | Track 0 sensor |
| `SEEKERR` | Last restore never found track 0 |
| `166.7 ms 360 rpm` | Time between index pulses, measured to 0.1 ms. 360 rpm is right for 8". 300 rpm means a 60 Hz pulley running on 50 Hz. Uses the measured CPU clock |
| `no index` | No index pulses: no disk, the disk isn't turning, or the drive isn't selected |
| `index too fast` | Pulses closer than 25 ms apart: probably a hard-sectored disk |

## Keys

| Key | Does |
|---|---|
| `Z` | Restore (seek to track 0) |
| `I` / `O` | Step in / out one track |
| `S` | Seek: type two digits, 00–76 |
| `A` | Read the next sector ID: track, side, sector, size code (0 = 128 bytes), CRC |
| `R` | Read one sector (type two digits) and hex-dump it. Any sector size up to 1 KB |
| `V` | Read sectors 1–26 of this track. Doesn't write. Any key stops it |
| `K` | Read Track: the raw bytes from index to index (about 5200), with counts of FF, 00 and E5 and a dump of the first 256. Shows what is physically on a track even when no sector can be found: a good IBM track shows FF and 00 gap runs, FC/FE/FB marks and E5 fill; an unrecorded track reads as noise |
| `T` | **Format** this track, write a pattern to every sector, read it back. Asks for `Y` first; refuses on a write-protected disk |
| `W` | **Format** this track over and over until a key is pressed (one `.` per format). For a scope on write gate (pin 40) and write data (pin 38). Asks for `Y` first |
| `C` | Head cleaning sweep: with a cleaning disk in, the heads stay loaded and zig-zag across tracks 0–76 and back (two steps in, one back), pausing about 0.1 s at each stop. Two passes, about 30 s; any key stops it; ends on track 0. Reads and writes nothing. Asks for `Y` first |
| `?` | Help |
| `Q` / `ESC` | Back to MCPMON |

`V` and `T` print one character per sector:

| Char | Meaning |
|---|---|
| `.` | Good |
| `R` | Record not found: no sector with this track/sector number. On a blank or differently formatted disk, every sector shows `R`, at about 0.8 s each |
| `C` | CRC error |
| `L` | Lost data: the program didn't keep up with the controller |
| `T` | Timeout: the controller never finished |
| `P` | Read fine but the pattern didn't match (only after `T`) |
| `W` | Write failed (during `T`) |

After the list comes the count and the last error status, decoded.

## Suggested order

1. With a disk in and the door shut, watch the status line. You want `READY`
   and about `360 rpm`.
2. `Z`: `TK0` should appear.
3. `A` on a pre-formatted disk: an ID like `00 00 01 00 xx xx` means the
   controller is reading data.
4. `V`: on a standard IBM-formatted disk, 26 dots.
5. Only on a disk you don't care about: `S` to a middle track (e.g. 40),
   then `T`. A full row of dots on both write and read means the write side
   works too.

## Notes

- The ROM never writes a drive-select port, and the drive answers without
  one, so the card's default selection works (the drive is jumpered DS1).
- Side 0 only. The drive is a double-sided Shugart SA850; with a
  single-sided disk it only reports READY while side 0 is selected.
- Transfers poll the status register. In the simulator the worst response
  to a data request is about 96 T-states: 24 µs at 4 MHz, 16 µs at 6 MHz.
  Single density gives 32 µs per byte. `L` errors would point at heavy wait
  states.
- `test_fdtest.py` runs FDTEST in the simulator against an FD1793 and drive
  model (`rom/mcpmon/fd1793.py`) and a console UART timing model: spindle not
  turning, formatted disk, blank disk, write-protect, 300 rpm, a 6 MHz CPU,
  and the DRQ timing check.
