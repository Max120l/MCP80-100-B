# Scope captures

TDS420A `.WFM` files (saved to the scope's floppy). Decode with
`python3 ../../tools/tekwfm.py FILE [out.csv]`.

| File | Signal | Result |
|---|---|---|
| `gw-pin38-write-data.wfm` | Pin 38 (write data) at the SA850, Greaseweazle writing single density. 2 V/div, 2 µs/div | High 5.1 V, low 0.4 V, about −0.2 V undershoot, 400 ns pulses, 2.0/4.0 µs spacing |
| `mcp-pin38-write-data.wfm` | Pin 38 at the SA850, MCP FD1793 card writing (FDTEST `W`). Same settings | High 5.0 V, low 0.36 V, no undershoot, 520 ns pulses, 2.0/4.0 µs spacing |
