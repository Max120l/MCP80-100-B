"""XMODEM peers playing the PC's side (Tera Term-like) on a timed serial
line (uart8251.Uart8251): Sender (PC sends), Receiver (PC receives),
Silent. Times are CPU T-states; MS and SEC default to a 6 MHz CPU and can
be changed before creating peers.
"""
MS = 6000
SEC = 1000 * MS
SOH, STX, EOT, ACK, NAK, CAN = 0x01, 0x02, 0x04, 0x06, 0x15, 0x18


def crc16(data):
    crc = 0
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) if crc & 0x8000 else crc << 1
            crc &= 0xFFFF
    return crc


class Sender:
    """The PC sending (Tera Term's XMODEM send): waits for 'C' (CRC) or NAK
    (checksum), then sends blocks, resending on NAK or after 10 s.
    one_k: None (128-byte blocks), "all" (1K blocks, the last one padded)
    or "mixed" (1K blocks, then 128-byte ones for the tail).
    Faults, by block number: corrupt (a data byte flipped), short (a byte
    missing), dup (sent again after its ACK, as if the ACK was garbled),
    cancel_after (CAN CAN instead of the next block)."""

    def __init__(self, data, one_k=None, crc_ok=True, corrupt=(), short=(),
                 dup=(), cancel_after=None, delay=None):
        self.blocks = []
        i = 0
        while i < len(data):
            rest = len(data) - i
            size = 1024 if one_k == "all" or (one_k == "mixed" and rest >= 1024) else 128
            self.blocks.append(data[i:i + size].ljust(size, b"\x1a"))
            i += size
        self.crc_ok, self.delay = crc_ok, 5 * MS if delay is None else delay
        self.corrupt, self.short, self.dup = set(corrupt), set(short), set(dup)
        self.cancel_after = cancel_after
        self.state, self.deadline, self.i = "start", None, 0
        self.sent, self.duped = set(), set()
        self.naks = self.timeouts = 0
        self.got = bytearray()

    def attach(self, uart):
        self.uart = uart

    def next_timer(self):
        return self.deadline

    def timer(self, t):
        self.deadline = None
        self.timeouts += 1
        if self.state == "ack":
            self.send_block(t)
        elif self.state == "eot":
            self.send_eot(t)

    def send_block(self, t):
        n = self.i + 1
        data = self.blocks[self.i]
        pkt = bytes([STX if len(data) == 1024 else SOH, n & 0xFF, 255 - (n & 0xFF)])
        check = crc16(data).to_bytes(2, "big") if self.crc else bytes([sum(data) & 0xFF])
        if n not in self.sent and n in self.corrupt:
            data = bytes([data[0] ^ 0x55]) + data[1:]
        if n not in self.sent and n in self.short:
            data = data[:50] + data[51:]
        self.sent.add(n)
        self.uart.pc_send(pkt + data + check, t + self.delay)
        self.state = "ack"
        self.deadline = self.uart.line_free + 10 * SEC

    def send_eot(self, t):
        self.uart.pc_send(bytes([EOT]), t + self.delay)
        self.state = "eot"
        self.deadline = self.uart.line_free + 10 * SEC

    def receive(self, t, b):
        self.got.append(b)
        if self.state == "start":
            if b == ord("C") and self.crc_ok:
                self.crc = True
            elif b == NAK:
                self.crc = False
            else:
                return
            self.send_block(t)
        elif self.state == "ack":
            n = self.i + 1
            if b == ACK:
                if n in self.dup and n not in self.duped:
                    self.duped.add(n)
                    self.send_block(t)
                    return
                self.i += 1
                if self.cancel_after is not None and self.i == self.cancel_after:
                    self.uart.pc_send(bytes([CAN, CAN]), t + self.delay)
                    self.state, self.deadline = "cancelled", None
                elif self.i == len(self.blocks):
                    self.send_eot(t)
                else:
                    self.send_block(t)
            elif b == NAK:
                self.naks += 1
                self.send_block(t)
            elif b == CAN:
                self.state, self.deadline = "cancelled", None
        elif self.state == "eot":
            if b == ACK:
                self.state, self.deadline = "done", None
            elif b == NAK:
                self.send_eot(t)
        elif self.state in ("start", "done", "cancelled"):
            pass


class Receiver:
    """The PC receiving (Tera Term's XMODEM receive): 'C' (CRC) or NAK
    (checksum) every 3 s until a block starts, then ACK/NAK per block,
    NAK after 1 s of silence inside a block or 10 s between blocks, and
    CAN CAN after 10 NAKs in a row (give_up). nak: blocks to NAK the first
    time (as if they arrived damaged)."""

    def __init__(self, start, crc=True, nak=(), delay=None, give_up=10):
        self.crc, self.delay, self.nak = crc, 5 * MS if delay is None else delay, set(nak)
        self.state, self.deadline = "start", start
        self.buf, self.data, self.expect = bytearray(), bytearray(), 1
        self.naked, self.naks, self.requests = set(), 0, 0
        self.give_up, self.row = give_up, 0

    def attach(self, uart):
        self.uart = uart

    def next_timer(self):
        return self.deadline

    def say(self, t, b):
        self.uart.pc_send(bytes([b]), t + self.delay)

    def _nak(self, t):
        self.naks += 1
        self.row += 1
        if self.row > self.give_up:
            self.say(t, CAN)
            self.say(t, CAN)
            self.state, self.deadline = "cancelled", None
            return
        self.say(t, NAK)
        self.state, self.deadline = "idle", t + 10 * SEC

    def timer(self, t):
        if self.state == "start":
            self.requests += 1
            self.say(t, ord("C") if self.crc else NAK)
            self.deadline = t + 3 * SEC
        elif self.state in ("block", "idle"):
            self._nak(t)
        else:
            self.deadline = None

    def receive(self, t, b):
        if self.state in ("start", "idle"):
            if b in (SOH, STX):
                self.state = "block"
                self.buf = bytearray([b])
                self.need = (128 if b == SOH else 1024) + 3 + (2 if self.crc else 1)
                self.deadline = t + SEC
            elif b == EOT:
                self.say(t, ACK)
                self.state, self.deadline = "done", None
            return
        if self.state != "block":
            return
        self.buf.append(b)
        self.deadline = t + SEC
        if len(self.buf) < self.need:
            return
        self.state, self.deadline = "idle", t + 10 * SEC
        n, nc = self.buf[1], self.buf[2]
        size = 128 if self.buf[0] == SOH else 1024
        data = bytes(self.buf[3:3 + size])
        if self.crc:
            ok = crc16(data) == int.from_bytes(self.buf[3 + size:], "big")
        else:
            ok = sum(data) & 0xFF == self.buf[3 + size]
        ok = ok and n == 255 - nc
        if ok and n == self.expect & 0xFF and n in self.nak and n not in self.naked:
            self.naked.add(n)
            ok = False
        if not ok:
            self._nak(t)
        elif n == self.expect & 0xFF:
            self.data += data
            self.expect += 1
            self.row = 0
            self.say(t, ACK)
        elif n == (self.expect - 1) & 0xFF:
            self.row = 0
            self.say(t, ACK)
        else:
            self.say(t, CAN)
            self.say(t, CAN)
            self.state, self.deadline = "cancelled", None


class Silent:
    """Nothing at the PC end."""
    def attach(self, uart): pass
    def next_timer(self): return None
    def timer(self, t): pass
    def receive(self, t, b): pass
