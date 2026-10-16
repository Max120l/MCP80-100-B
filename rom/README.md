# Boot ROM

| File | |
|---|---|
| `mcp_boot_f800.bin` | 2716 image (2048 bytes) from U16 on the CPU card |
| `mcp_boot.asm` | Annotated disassembly, reassembles byte-for-byte |
| `verify.sh` | Rebuilds the listing with `z80asm` and compares |
| `mcpmon/` | MCPMON 2.0, the replacement monitor (see its README) |

The image was read four times and all four reads are identical:

```
MD5     896f955e6635ab978e36aabd114d29bf
SHA256  704b26c60d5a499fbcd4ae6a159208d9f3fcfc1c8853001c0f900e046404edbc
```

## Memory map

| Address | Use |
|---|---|
| 0000h | ROM also visible here at reset. First instruction jumps to F803h, which reads port 0Ah (probably turns this copy off) |
| below F400h | Monitor stack (SP = F3FFh), probably the 2114 RAM on the CPU card |
| F800h–FFFFh | ROM |

## I/O used by the ROM

| Port | Use |
|---|---|
| 00h / 01h | Second 8251 (data / control) |
| 02h / 03h | Console 8251 (data / control). Status bit 0 = TxRDY, bit 1 = RxRDY |
| 04h–07h | 8255. Init: port A mode 1 output, port B input, port C outputs, then PC5 set |
| 0Ah | Read at reset (probably ROM shadow off) |
| 60h–66h | XCOMP ST/S hard disk controller, see [../disk/](../disk/README.md) |
| 78h–7Ch | Floppy controller #2: 78h cmd/status, 7Ah sector, 7Bh data, 7Ch wait/status |
| F8h–FCh | Floppy controller #1: F8h cmd/status, FAh sector, FBh data, FCh wait/status |

## Startup

1. Both 8251s: mode CEh (8 data bits, no parity, 2 stop bits, ×16 clock),
   command 27h (RTS, RxE, DTR, TxEN).
2. Sends `ESC *` (clear screen on TeleVideo-style terminals).
3. Flushes console input, sets up the 8255.
4. Prints `>` and waits. **No autoboot.**

## Monitor commands

Addresses are exactly 4 hex digits and bytes exactly 2. There's no Enter
after them. The monitor prints `:` before each address. **DEL** returns to
the prompt from anywhere. An unknown letter prints ` ?`.

| Command | Does |
|---|---|
| `G:aaaa` + CR | Jump to aaaa. Anything other than CR cancels |
| `D:ssss:eeee` | Hex dump, 16 bytes per line |
| `S:aaaa` | Edit memory. Shows `hh-`; **space** keeps it and moves on, two hex digits store a new value |
| `F:ssss:eeee hh` | Fill ssss–eeee with hh |
| `M:ssss:eeee:dddd` | Copy ssss–eeee to dddd |
| `B` | Floppy boot from controller at F8h; on error tries 78h |
| `A` | Floppy boot from controller at 78h |
| `L` | Hard disk boot |

Floppy boot: step out / restore to track 0, read sector 1 to 0000h, jump to
**007Dh**. If both controllers fail, the WD status byte is printed in hex.

Hard disk boot: load the XCOMP controller's read and write microcode,
restore to track 0, read cylinder 0 / head 0 / sector 0 (256 bytes) to
0000h, jump to 0000h. Errors print `* Drive not Ready`, `* Restore Failed` or
`* Read Failed`, wait for a key, and retry the read.

## Quirks

- **After a `?` from a bad hex digit, press DEL and start over.** The retry
  path jumps back into the input routine without unwinding the stack, so the
  next digits get misread.
- The range compare used by D, M and F is only correct while the high byte
  of the current address is ≤ the end address's high byte. Normal use is
  fine.
- There are no port input/output commands.

## Poking I/O ports from the monitor

Enter a few bytes with `S`, then run them with `G`. Each snippet ends with
`JP F80Bh`, which returns to the monitor. These examples use 0100h, so the
memory card has to be installed.

In `S`, type the hex pairs back to back. A space means "skip this byte", so
don't type spaces between pairs. Press DEL when done.

Write `xx` to port 64h:

```
S:0100   then type  3Exx D364 C30BF8   (LD A,xx / OUT (64h),A / JP F80Bh), DEL
G:0100   then CR
```

Read port 60h into 0200h, then look at it:

```
S:0100   then type  DB60 320002 C30BF8   (IN A,(60h) / LD (0200h),A / JP F80Bh), DEL
G:0100   then CR
D:0200:0200
```

(The groupings above are only for readability; type the digits without the
spaces.)

## Leftovers

- A Baudot (ITA2 / US TTY, 5-bit teleprinter code) translation table at
  F97Eh plus a lookup routine at FA17h. Nothing calls either, so this is
  probably left over from a version that drove a teleprinter.
- An unreachable "enter bytes" routine at F9F4h.
- Unused areas (FABFh–FBFFh, FDE5h–FFFFh) contain the EPROM programmer's
  buffer contents rather than FFh. They are identical in all four reads, so
  this is not bit rot.
- The hard disk code has its own copies of the console routines, so it was
  probably written as a separate module and added later.
