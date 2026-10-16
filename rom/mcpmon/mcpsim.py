#!/usr/bin/env python3
"""Minimal MCP 80/100 simulator for testing ROM code.

Z80 core: the `z80` Python package (kosarev). Models:
  - ROM at F800h-FFFFh (read-only), RAM elsewhere
  - console 8251 at 02h/03h, transfer 8251 at 00h/01h (untimed, or a timed
    line with a scripted far end: uart8251.py attached as .aux)
  - hard disk controller at 60h-66h, behaving as the boot ROM expects (or
    a timed XCOMP ST/S + MiniScribe model: xcomp.py attached as .hdc_model)
  - floppy controller ports that always report an error, unless an FD1793
    model (fd1793.py) is attached as .fdc
The disk model is only good enough to exercise the ROM's code paths; the
real controller's behaviour is still partly unknown.
"""
import collections
import z80


class HDC:
    """Model of the MCP hard disk controller as inferred from the ROM."""

    def __init__(self):
        self.mode = 0
        self.ptr = 0
        self.areas = collections.defaultdict(lambda: bytearray(256))
        self.latch = 0
        self.done = False
        self.errors = 0
        self.track0 = True
        self.ready = True
        self.write_fault = False
        self.sel = 0
        self.drv = 0
        self.steps = 0
        self.sectors = {}      # bytes(id) -> 256 bytes
        self.reads = []        # ids read, in order
        self.log = []

    def out(self, port, val):
        self.log.append(("out", port, val))
        if port == 0x60:
            self.drv = val
            if val & 1 and not self.track0:   # stepping out to track 0
                self.track0 = True
        elif port == 0x61:
            self.sel = val
            if val == 0:
                self.write_fault = False
        elif port == 0x64:
            if val & 0x08:                    # GO
                ident = bytes(self.areas[4][0xEA:0xEE])
                self.reads.append(ident)
                data = self.sectors.get(ident)
                if data is None:
                    self.errors = 0x02            # not found
                    data = bytes(256)
                else:
                    self.errors = 0
                self.areas[2][:] = data
                self.done = True
            else:
                self.mode = val
                if val == 0:
                    self.done = self.done   # idle keeps status
        elif port == 0x65:
            self.ptr = val
        elif port == 0x66:
            self.areas[self.mode][self.ptr & 0xFF] = val
            self.ptr = (self.ptr + 1) & 0xFF
        # 62h/63h: step counter, ignored

    def inp(self, port):
        if port == 0x60:
            v = 0
            if self.ready:
                v |= 0x01
            if self.write_fault:
                v |= 0x02
            if self.track0:
                v |= 0x04
            v |= 0x80                       # seek complete
            return v
        if port == 0x64:
            return (0x01 if self.done else 0) | self.errors
        if port == 0x66:
            v = self.latch
            self.latch = self.areas[self.mode][self.ptr & 0xFF]
            self.ptr = (self.ptr + 1) & 0xFF
            return v
        return 0xFF


class MCP:
    def __init__(self, rom, fault=None):
        self.m = z80.Z80Machine()
        self.mem = bytearray(0x10000)
        self.mem[0xF800:0x10000] = rom.ljust(2048, b"\xff")
        self.m.set_memory_block(0, bytes(self.mem))
        self.fault = fault          # (addr, mask): RAM bit stuck at 0
        self.con_in = collections.deque()
        self.con_out = bytearray()
        self.aux_in = collections.deque()
        self.aux_out = bytearray()
        self.hdc = HDC()
        self.idle = 0
        self.port_log = []
        self.fdc = None             # optional fd1793.FD1793(self.now, ...)
        self.aux = None             # optional uart8251.Uart8251 for port B
        self.hdc_model = None       # optional xcomp.XComp (timed controller + drive)
        self.tx_char_t = None       # console TX timing: T-states per character
        self._tx_shift_end = 0      # (None = always ready, the default)
        self._tx_hold = False
        self._t0 = 0                # T-state clock, see now()
        self._chunk = 0
        self.t = 0
        self.m.set_input_callback(self.inp)
        self.m.set_output_callback(self.out)
        self.m.set_write_callback(self.write)
        # the callback only sees write-marked addresses: ROM + faulty cell
        self.m.mark_addrs(0xF800, 0x800, self.m.WRITE_MARK)
        if fault:
            self.m.mark_addrs(fault[0], 1, self.m.WRITE_MARK)
        self.m.pc = 0xF800

    # memory ------------------------------------------------------------
    def write(self, addr, val):
        if addr >= 0xF800:
            return                      # ROM
        if self.fault and addr == self.fault[0]:
            val &= ~self.fault[1] & 0xFF
        self.m.memory[addr] = val

    def peek(self, addr, n=1):
        return bytes(self.m.memory[addr:addr + n])

    def poke(self, addr, data):
        self.m.memory[addr:addr + len(data)] = data

    # I/O ---------------------------------------------------------------
    def inp(self, port):
        port &= 0xFF
        if port == 0x03:
            if not self.con_in:
                self.idle += 1
            return self._tx_status() | (0x02 if self.con_in else 0)
        if port == 0x02:
            return self.con_in.popleft() if self.con_in else 0
        if self.aux is not None and port in (0x00, 0x01):
            return self.aux.inp(port)
        if port == 0x01:
            return 0x05 | (0x02 if self.aux_in else 0)
        if port == 0x00:
            return self.aux_in.popleft() if self.aux_in else 0
        if 0x60 <= port <= 0x66:
            if self.hdc_model is not None:
                return self.hdc_model.inp(port)
            return self.hdc.inp(port)
        if self.fdc is not None and 0xF8 <= port <= 0xFC:
            return self.fdc.inp(port)
        if port in (0xF8, 0x78):        # floppy status: record not found
            return 0x10
        if port in (0xFC, 0x7C):        # wait port: command finished
            return 0x00
        return 0xFF

    def out(self, port, val):
        port &= 0xFF
        self.port_log.append((port, val))
        if port == 0x02:
            self.con_out.append(val)
            self.idle = 0           # only polls with no output count as idle
            self._tx_write()
        elif self.aux is not None and port in (0x00, 0x01):
            self.aux.out(port, val)
        elif port == 0x00:
            self.aux_out.append(val)
        elif 0x60 <= port <= 0x66:
            if self.hdc_model is not None:
                self.hdc_model.out(port, val)
            else:
                self.hdc.out(port, val)
        elif self.fdc is not None and 0xF8 <= port <= 0xFB:
            self.fdc.out(port, val)

    # console transmitter timing (8251: holding register + shift register)
    def _tx_update(self):
        t = self.now()
        if self._tx_hold and t >= self._tx_shift_end:
            self._tx_shift_end += self.tx_char_t
            self._tx_hold = False

    def _tx_status(self):
        if self.tx_char_t is None:
            return 0x05
        self._tx_update()
        v = 0 if self._tx_hold else 0x01
        if not self._tx_hold and self.now() >= self._tx_shift_end:
            v |= 0x04
        return v

    def _tx_write(self):
        if self.tx_char_t is None:
            return
        self._tx_update()
        t = self.now()
        if t >= self._tx_shift_end and not self._tx_hold:
            self._tx_shift_end = t + self.tx_char_t
        else:
            self._tx_hold = True        # (a write while full would overrun)

    # running -----------------------------------------------------------
    def type(self, s):
        self.con_in.extend(s.encode() if isinstance(s, str) else s)

    def now(self):
        """CPU clock in T-states, valid inside I/O callbacks too."""
        return self._t0 + self._chunk - self.m.ticks_to_stop

    def _chunk_run(self, n):
        self._t0 = self.now()
        self._chunk = n
        self.m.ticks_to_stop = n
        self.m.run()
        self.t = self.now()

    def ticks(self, n):
        """Run for n T-states regardless of what the CPU is doing."""
        end = self.now() + n
        while self.now() < end:
            self._chunk_run(min(20000, end - self.now()))

    def run(self, max_ticks=50_000_000):
        """Run until the CPU waits for console input with nothing queued."""
        self.idle = 0
        spent = 0
        while spent < max_ticks:
            self._chunk_run(20000)
            spent += 20000
            if self.idle > 200 and not self.con_in:
                return
        raise RuntimeError("timeout, PC=%04X" % self.m.pc)

    def output(self, clear=True):
        s = self.con_out.decode("latin-1")
        if clear:
            self.con_out.clear()
        return s
