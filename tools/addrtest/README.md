# ADDRTEST

Address-line test for the memory card. Runs from the CPU card's scratch RAM
at F000h, so faults on the memory card can't overwrite it. Needs MCPMON 2.0.

**Load:** at the MCPMON prompt type `H`, send `addrtest.hex` from the
terminal, wait for `OK`.

- `G:F000` + Enter: one run of 256 passes, full table. Takes under a second.
- `G:F003` + Enter: loop until a key is pressed, for tap testing. Prints `.`
  for each clean block of 256 passes (about 3 per second); a failing block
  prints a line like `A15/0=0053 A15/6=004B` (line / base, 0 = 0000h,
  6 = 6A55h, failures out of 0100 in hex).

The program occupies F000h–F2A7h; its counters live at F30Ch–F375h, between
MCPMON's variables and its stack.

For each address line A0–A15, at two base addresses (0000h and 6A55h), 256
times:

- **self:** write 55h then AAh to the base address and read each back.
- **A*n*:** write 55h to the base, AAh to base XOR that line, read the base.
  If the base now reads AAh, the card can't tell the two addresses apart.

Output is the failure count in hex out of 0100, and the last bad byte read:

| Count | Meaning |
|---|---|
| 0000 | OK |
| 0100 on one line | That address line is stuck or not reaching the chips |
| 0001–00FF | Intermittent: marginal contact, floating line, failing buffer |
| 0100 on every line at one base, incl. self | That cell doesn't store at all |

`test_addrtest.py` runs it in the simulator against those fault models.
