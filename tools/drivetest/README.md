# DRIVETEST

Interactive exerciser for the MiniScribe on the XCOMP controller. Shows the
drive status live, selects the drive, picks a head and steps the heads.
It only uses the drive ports 60h–63h and never starts the controller's
microcode, so **it cannot write to the disk**.

**Run:** at the MCPMON prompt type `H`, send `drivetest.hex`, wait for `OK`,
then `G:0100` and Enter. Loads at 0100h–0596h.

The status line redraws in place about once a second:

```
ST=8D SEL RDY TK0 SKE --- ---  IDX=004E CYL=0000 HD=0 [sel on]
```

| Field | Meaning |
|---|---|
| `ST=` | Raw drive status (port 60h) |
| `SEL` | Drive answered the select (DRIVE SELECTED/ low) |
| `RDY` | READY |
| `TK0` | Heads at track 0 |
| `SKE` | SEEK END |
| `SKG` | Seeking (SEEKING/ low) |
| `FLT` | WRITE FAULT |
| `IDX=` | Index pulses counted since the last update. Non-zero = disk turning and drive selected. At 3600 rpm it's about 60 per second of window, so it also hints at the CPU clock |
| `CYL=` | Head position as tracked by the program (`????` until a restore) |
| `HD=` | Selected head |
| `[sel on]` | Whether the program is asserting drive select |

| Key | Action |
|---|---|
| `S` | Drive select on/off (port 61h bit 0); watch the drive LED |
| `0`–`3` | Select head |
| `Z` | Restore to track 0 (same sequence as the boot ROM) |
| `I` / `O` | Step one cylinder in / out (stays within 0–479) |
| `W` | Sweep between cylinders 0 and 200 until a key is pressed: audible |
| `?` | Help |
| `Q`, ESC, ^C | Deselect and return to MCPMON |

Stepping keys refuse to run unless the drive reports SEL, and `I`/`O`/`W`
need a restore first so the position is known.

`test_drivetest.py` runs it in the simulator against a working drive and a
drive that never selects.
