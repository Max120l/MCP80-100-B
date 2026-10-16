"""8251 USART on a timed serial line, for the MCP simulator (port B).

Attach to an MCP as .aux; ports 00h (data) and 01h (status/command) then
come here instead of the simulator's untimed port B.

The far end of the line is a Python object (the "peer", for example an
XMODEM sender playing the PC) with:
    peer.attach(uart)        called once
    peer.receive(t, byte)    a byte from the MCP has fully arrived at time t
    peer.next_timer()        time of the peer's next timeout, or None
    peer.timer(t)            that timeout has come (must clear or move it)
The peer sends with uart.pc_send(data, t): the bytes leave the PC one after
another from time t, one character time each.

Times are CPU T-states (MCP.now()). The model is lazy: it catches up on
every port access, handling arrivals, transmissions and peer timeouts in
time order (sync() catches up without one). Like the real chip it holds one received byte; a byte that
completes before the CPU read the previous one replaces it and sets OE.
"""
import collections


class Uart8251:
    def __init__(self, now, char_t, peer=None):
        self.now = now
        self.char_t = char_t          # T-states per character on the line
        self.rx = collections.deque() # (time complete, byte) heading for the MCP
        self.line_free = 0            # when the PC's transmitter is free again
        self.rbuf = None              # received byte the CPU hasn't read
        self.err = 0                  # 08h PE, 10h OE, 20h FE
        self.overruns = 0
        self.tx_shift = None          # (time complete, byte) being sent
        self.tx_hold = None           # byte waiting in the holding register
        self.tx_lost = 0              # writes while the holding register was full
        self.expect_mode = False
        self.mode = None
        self.cmd = None
        self.ctl = []                 # every control write, in order
        self.peer = None
        if peer is not None:
            self.attach(peer)

    def attach(self, peer):
        self.peer = peer
        peer.attach(self)

    def pc_send(self, data, t):
        start = max(t, self.line_free)
        for b in data:
            start += self.char_t
            self.rx.append((start, b))
        self.line_free = start

    def sync(self):
        """Catch up to now (the CPU may have stopped touching the port)."""
        self._advance(self.now())

    def _advance(self, t):
        while True:
            ev = []
            if self.rx:
                ev.append((self.rx[0][0], 0))
            if self.tx_shift is not None:
                ev.append((self.tx_shift[0], 1))
            pt = self.peer.next_timer() if self.peer else None
            if pt is not None:
                ev.append((pt, 2))
            if not ev:
                return
            tm, kind = min(ev)
            if tm > t:
                return
            if kind == 0:
                _, b = self.rx.popleft()
                if self.rbuf is not None:
                    self.err |= 0x10
                    self.overruns += 1
                self.rbuf = b
            elif kind == 1:
                end, b = self.tx_shift
                if self.tx_hold is not None:
                    self.tx_shift = (end + self.char_t, self.tx_hold)
                    self.tx_hold = None
                else:
                    self.tx_shift = None
                if self.peer:
                    self.peer.receive(end, b)
            else:
                self.peer.timer(tm)

    def inp(self, port):
        self._advance(self.now())
        if port == 0x00:
            b = self.rbuf if self.rbuf is not None else 0
            self.rbuf = None
            return b
        v = 0x80                                  # DSR
        if self.tx_hold is None:
            v |= 0x01                             # TxRDY
        if self.rbuf is not None:
            v |= 0x02                             # RxRDY
        if self.tx_hold is None and self.tx_shift is None:
            v |= 0x04                             # TxEMPTY
        return v | self.err

    def out(self, port, val):
        t = self.now()
        self._advance(t)
        if port == 0x00:
            if self.tx_shift is None:
                self.tx_shift = (t + self.char_t, val)
            elif self.tx_hold is None:
                self.tx_hold = val
            else:
                self.tx_lost += 1
                self.tx_hold = val
            return
        self.ctl.append(val)
        if self.expect_mode:
            self.mode = val
            self.expect_mode = False
        elif val & 0x40:                          # internal reset
            self.expect_mode = True
            self.rbuf = None
            self.err = 0
        else:
            self.cmd = val
            if val & 0x10:                        # error reset
                self.err = 0
