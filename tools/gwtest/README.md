# GWTEST

Bench test files for writing the 8" drive (Shugart SA850) with a
Greaseweazle, independent of the MCP's own floppy controller.

| File | |
|---|---|
| `make_images.py` | Makes the two test images below |
| `rx01_test.img` | 77 × 26 × 128 bytes, side 0: IBM 3740 single density (built-in format `dec.rx01`) |
| `rx01ds_test.img` | Same on both sides (needs `sa850test.cfg`) |
| `sa850test.cfg` | Greaseweazle disk definition `rx01ds`: `dec.rx01` with two heads |

Every sector starts with its own address in text (`MCP SA850 C40 H1 S07`),
followed by runs of 00, FF, 55 and AA and a counter, so any sector read back
shows where it came from.

## Steps

Use a scratch disk for writing. Keep disks you care about out of the drive
while writing.

1. **Read check** (any disk with a single-density track 0, e.g. a TRS-80
   Model II/12/16 disk), with the diagnostic in Adrian Black's fork:

   ```
   gw-diag --rate 250 --encoding fm --secs 26 --cyls 77 --heads 1
   ```

   Press `0` for track 0: expect `S26/26` and about 360 rpm. Only track 0
   of a TRS-80 disk is single density.

2. **Write side 0** (verify is on by default; each track is read back):

   ```
   gw write --format=dec.rx01 --tracks=c=0-2,38-40,74-76 rx01_test.img
   ```

3. **Write side 1:**

   ```
   gw write --diskdefs=sa850test.cfg --format=rx01ds --tracks=c=0-2,38-40,74-76:h=1 rx01ds_test.img
   ```

4. **Look:** `gw-diag` as in step 1 (with `--heads 2`), jump to the written
   tracks and toggle the side with `h`. Written tracks show `S26/26`.

## Notes

- The SA850's write current switch is **pin 10** (jumper IW). Check what the
  50-pin adapter does with pin 10: grounded means low write current on every
  track. `--gen-tg43` drives pin 2, which the SA850 doesn't use for this.
- For scoping the drive's write trigger and drivers, write one track over
  and over: `gw write --format=dec.rx01 --tracks=c=40 rx01_test.img`.
