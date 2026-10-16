# PORTB

Test and bridge for serial port B (second 8251, ports 00h/01h). Needs
MCPMON 2.0, which sets port B to 8N1.

**Load and run** (MCPMON's `H` reads from the console, port A):

1. With the PC on port A, `H` and send `portb.hex`, wait for `OK`.
2. Without powering off, move the PC's adapter to port B and plug the
   terminal (VT52) into port A. The program stays in RAM.
3. On the terminal: `G:0100` and Enter.

What it does:

- Sends `MCP port B says hello #nn` on port B every couple of seconds.
- Shows anything received on port B on the console.
- Sends anything typed on the console to port B. ESC quits.
- Reports port B status changes on the console: `DSR on` means the other
  end's DTR is reaching the MCP; `FRAMING ERROR` usually means the baud rate
  doesn't match.

Never blocks: the 8251 only transmits while its CTS input is asserted, so if
nothing arrives on the PC, the other end isn't driving CTS. Enable RTS/CTS
(or DTR) in the PC terminal, try a null modem, or loop pins 4–5 on the MCP
side.

`test_portb.py` runs it in the simulator.
