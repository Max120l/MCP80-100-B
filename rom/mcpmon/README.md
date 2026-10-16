# MCPMON 2.0

Replacement 2 KB monitor ROM for the MCP 80/100. It keeps the original
monitor's commands and adds the tools needed to explore the machine and
read the hard disk over serial. It is stage 1 of the plan in
[../../ROADMAP.md](../../ROADMAP.md).

**Status: running on the real machine** (2732, doubled image). 41/41 emulator
tests pass.

| File | |
|---|---|
| `mcpmon.asm` | Source (z80asm syntax) |
| `mcpmon_2716.bin` | ROM image, padded to 2048 bytes for a 2716 / One ROM |
| `mcpmon_2732.bin` | Same image twice (4096 bytes), for a 2732 in the 2716 socket |
| `mcpsim.py` | Simulator: Z80 + 8251s + hard disk controller model, T-state clock (`now()`, `ticks()`) |
| `fd1793.py` | FD1793 + 8" single-density drive model with real timing (index, steps, DRQ, lost data); attach as `sim.fdc` |
| `uart8251.py` | Port B 8251 on a timed serial line (overruns, transmit timing) with a scripted far end, such as an XMODEM sender playing the PC; attach as `sim.aux` |
| `xmodem_peer.py` | Tera Term-like XMODEM sender and receiver for that far end (the receiver NAKs after 10 s of silence and cancels after 10 in a row) |
| `xcomp.py` | XCOMP ST/S + MiniScribe 4020 with timing (seeks, rotation, header compare against any header layout, bad sectors, dropouts of READY/SELECT and reads that silently return zeros); counts any start of the write microcode; attach as `sim.hdc_model` |
| `vt52.py` | A real DEC VT52 screen (only its own escape codes, no wrap); collects anything a VT52 wouldn't do |
| `test_mcpmon.py` | Test suite (`python3 test_mcpmon.py`, needs `pip install z80`) |

```
mcpmon_2716.bin
MD5     a78471eccabd79ef309a1abaa21dfe16
SHA256  b6d5dd66f9204e4a2e459232376887e5bd7379de4e85156a1189d4014a327555
```

Build: `z80asm -o mcpmon.bin mcpmon.asm`, then pad to 2048 bytes with FFh.

## Installing with One ROM

- Put the **original ROM in one slot** and MCPMON in another, so you can always
  go back.
- Check the 2716 is in your board's supported chip list.
- One ROM needs a moment after power-up before it serves data. If the machine
  doesn't reach the prompt, press reset once it's powered.
- Try the original ROM first, to confirm the machine, the terminal and the
  baud rate work, before switching to MCPMON.

## Using a 2732 instead

A 2732 fits the 2716 socket. The only pin that differs is 21: VPP on the
2716 (held at +5 V for reading), A11 on the 2732. With pin 21 high, the 2732
serves its upper 2 KB. `mcpmon_2732.bin` holds the image in both halves, so
it works whatever pin 21 is tied to. Check pin 21 isn't floating (it should
read about 5 V at the socket with the machine on), and use a part at least
as fast as the original 2716.

## Serial settings

Console on the same 8251 as the original (ports 02h/03h). MCPMON sets both
8251s to **8 data bits, no parity, 1 stop bit** (the original used 2 stop
bits). The baud rate is set in hardware, probably by the CPU card's DIP
switch, so it doesn't change. The second 8251 (00h/01h) is set up the same
way for transfers.

## Commands

Parameters are hex: addresses 4 digits, bytes 2 digits, no Enter. The
monitor prints the `:` separators itself; typing them is harmless.
Lowercase is fine. **^C, ESC or DEL** abort back to the prompt from
anywhere.

| Command | Does |
|---|---|
| `G:aaaa` CR | Go. Anything but CR cancels |
| `D:ssss:eeee` | Dump, 16 bytes + ASCII per line. Any key stops |
| `S:aaaa` | Substitute. Shows each byte: type 2 digits to store, space to skip, CR to finish. `!` = didn't read back |
| `F:ssss:eeee:hh` | Fill |
| `M:ssss:eeee:dddd` | Move (copes with overlap) |
| `I:pp` | Read a port, shows `=vv` |
| `O:pp:vv` | Write a port |
| `T:ssss:eeee` | RAM test (00, FF, 55, AA, address pattern). Lists up to 8 bad addresses as `addr wrote/read`. Refuses F300h–F3FFh |
| `H` | Intel HEX load: send a .hex file from the terminal. `.` per good record, `E` per bad one, ends with OK / FAIL |
| `X:ssss:eeee` | Intel HEX dump, for capturing with the terminal's log |
| `R:iiiiiiii` | Read one hard disk sector by its 4-byte ID into 8000h–80FFh |
| `L` | Hard disk boot, same as the original |
| `B` / `A` | Floppy boot, same as the original (B tries F8h then 78h, A only 78h) |
| `?` | Help |

`R` and `L` drive the controller exactly the way the original ROM does:
same tables, same register sequence, same timing loops. They only ever
start the read sequence (D7h).

## Memory

- Monitor RAM: F300h–F3FFh (stack at F400h downward, like the original's).
- `R` uses 8000h–80FFh. `L` loads to 0000h–00FFh and jumps there with
  SP = 0100h, like the original.
- Don't HEX-load or fill over F300h–F3FFh.

## Entry points for loaded programs

Fixed addresses, so programs loaded with `H` can use them:

| Address | Routine |
|---|---|
| F800h | Cold start |
| F803h | Back to the monitor prompt |
| F806h | Console status: NZ = character waiting |
| F809h | Console input → A (7 bits) |
| F80Ch | Console output ← A |
| F80Fh | Transfer port status: NZ = character waiting |
| F812h | Transfer port input → A (8 bits) |
| F815h | Transfer port output ← A |
| F818h | Print 0-terminated string at HL |
| F81Bh | Print A as two hex digits |
| F81Eh | HDINIT: load controller tables, select drive, restore. Z = OK, else NZ and HL = message |
| F821h | HDREAD: read the sector whose 4-byte ID is at HL into the controller buffer. Z = OK, else NZ, HL = message, B = error bits |
| F824h | HDGETBUF: copy the 256-byte controller buffer to HL |

## First run on the machine

1. Original ROM: reach the `>` prompt, note the baud rate.
2. MCPMON: the banner `MCPMON 2.0  ? = help` should appear.
3. `D:F800:F83F` should show the ROM.
4. `T:0000:EFFF`, then `T:F000:F2FF` and `T:F400:F7FF`, which also shows
   where RAM really is.
5. `I:60` reads the hard disk status port. With no drive connected this
   shows what "no drive" looks like, a useful reference for later.

## Reading cylinder 0 (when the MiniScribe is connected)

`R:00000000` reads the same sector `L` boots from, without running it. Look
at it with `D:8000:80FF` and save it with `X:8000:80FF`.

The order of the 4 ID bytes isn't known yet. To find the sector number, try
changing one byte at a time (`R:00000001`, `R:00000100`, ...). The byte
whose increments give new, valid sectors is the sector number. A read of a
sector that doesn't exist reports `Read Failed` and the controller's error
bits. It retries 10 times first, so that can take several seconds.

Cylinder 0 should contain the boot code and probably the original BIOS,
which will show the full geometry and how the controller seeks.
