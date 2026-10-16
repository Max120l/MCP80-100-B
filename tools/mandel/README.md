# MANDEL

The machine's first program in decades: an ASCII Mandelbrot set, 72 × 24
characters, in 8.8 fixed-point maths. 321 bytes at 0100h. Needs MCPMON 2.0.

**Run:** `H`, send `mandel.hex`, wait for `OK`, then `G:0100` and Enter. Any
key stops it.

Takes roughly 11 s at 4 MHz (about 7 s at 6 MHz, 23 s at 2 MHz) without wait
states. A stopwatch is only a rough check of the clock; FDTEST measures it
properly.
