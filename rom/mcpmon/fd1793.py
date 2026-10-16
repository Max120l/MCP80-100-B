#!/usr/bin/env python3
"""FD1793 + 8" single-density drive model for mcpsim.

Timing is in Z80 T-states at 4 MHz (1 T = 0.25 us). The model is lazy: the
controller's state is worked out from the clock whenever the CPU touches a
port, which is enough to catch a program that polls too slowly (lost data)
or never finishes a transfer.

Covers what FDTEST and a simple BIOS need: restore / seek / step, read
sector, read address, write sector, write track (IBM 3740 FM stream parsed
into sectors), read track, force interrupt. Ports: F8 cmd/status, F9 track,
FA sector, FB data, FC the board's wait port (reading it stalls until DRQ or
the end of the command: modelled by moving the disk's clock forward).
Disk.from_img() / to_img() convert to and from a 77 x 26 x 128 image in
physical sector order (Greaseweazle dec.rx01, cpmtools ibm-3740).
"""

T_BYTE = 128            # FM at 250 kbit/s: 32 us per byte
REV = 666_667           # 360 rpm: 166.7 ms per revolution
IDX_W = 8_000           # index pulse width, 2 ms
STEP_MS = (3, 6, 10, 15)
MS = 4_000              # T-states per ms
SETTLE = 15 * MS        # E flag delay
NTRK = 77


def ibm_stream(track, fill=0xE5, nsec=26, data=None):
    """The byte stream a program writes with Write Track for IBM 3740.
    data(sec) may supply each sector's 128 bytes."""
    s = bytearray([0xFF] * 40 + [0] * 6 + [0xFC] + [0xFF] * 26)
    for sec in range(1, nsec + 1):
        body = data(sec) if data else bytes([fill]) * 128
        s += bytes(6) + bytes([0xFE, track, 0, sec, 0, 0xF7]) + b"\xff" * 11
        s += bytes(6) + bytes([0xFB]) + bytes(body) + b"\xf7" + b"\xff" * 27
    s += b"\xff" * 247
    return s


def parse_stream(stream):
    """FM Write Track stream -> list of sectors with on-disk byte offsets.
    F7 writes two CRC bytes, so it takes two byte cells on the disk."""
    secs = []
    d = 0                       # on-disk byte offset from index
    i = 0
    cur = None
    while i < len(stream):
        b = stream[i]
        if b == 0xFE and i + 5 < len(stream):
            cur = {"id": tuple(stream[i + 1:i + 5]), "id_off": d,
                   "id_crc": stream[i + 5] == 0xF7, "data": None,
                   "data_off": None, "crc_bad": False}
            secs.append(cur)
            d += 5              # FE + 4 ID bytes
            i += 5
            continue
        if b in (0xFB, 0xF8) and cur is not None and cur["data"] is None:
            n = 128 << (cur["id"][3] & 3)
            data = stream[i + 1:i + 1 + n]
            cur["data_off"] = d + 1
            cur["data"] = bytearray(data.ljust(n, b"\x00"))
            cur["crc_bad"] = not (i + 1 + n < len(stream) and stream[i + 1 + n] == 0xF7)
            d += 1 + n
            i += 1 + n
            continue
        d += 2 if b == 0xF7 else 1
        i += 1
    return [s for s in secs if s["id_crc"]]


class Disk:
    def __init__(self, formatted=True, wp=False):
        self.wp = wp
        self.tracks = {}
        self.raw = {}           # Write Track streams, for Read Track
        if formatted:
            for t in range(NTRK):
                self.raw[t] = ibm_stream(t)
                self.tracks[t] = parse_stream(self.raw[t])

    def sectors(self, cyl):
        return self.tracks.get(cyl, [])

    @classmethod
    def from_img(cls, img, wp=False, nsec=26):
        d = cls(formatted=False, wp=wp)
        ntrk = len(img) // (nsec * 128)
        for t in range(ntrk):
            def data(sec, t=t):
                o = (t * nsec + sec - 1) * 128
                return img[o:o + 128]
            d.raw[t] = ibm_stream(t, nsec=nsec, data=data)
            d.tracks[t] = parse_stream(d.raw[t])
        return d

    def to_img(self, ntrk=NTRK, nsec=26):
        out = bytearray()
        for t in range(ntrk):
            secs = {s["id"][2]: s for s in self.sectors(t) if s["id"][0] == t}
            for sec in range(1, nsec + 1):
                s = secs.get(sec)
                out += bytes(s["data"][:128]) if s and s["data"] else b"\xe5" * 128
        return bytes(out)


class FD1793:
    def __init__(self, now, disk=None, spinning=True):
        self._cpu_now = now
        self.skew = 0           # disk clock ahead of the CPU (FC wait port stalls)
        self.disk = disk
        self.spinning = spinning
        self.idx_t0 = 1234
        self.head = 5           # physical cylinder at power-up
        self.tr = 0
        self.sr = 1
        self.dr = 0
        self.hld = False
        self.type1 = True
        self.busy_until = 0
        self.seek_err = False
        self.final = 0          # Type II/III status bits after the command
        self.op = None          # active transfer
        self.log = []           # (t, "cmd", value)
        self.max_lat = {}       # op kind -> worst DRQ-to-service time, T-states

    def now(self):
        return self._cpu_now() + self.skew

    # board wait port (FCh): stall until DRQ or the end of the command --------
    def wait_port(self):
        t = self.now()
        if t >= self.busy_until:
            self._update(t)
            return 0x00
        self._update(t)
        op = self.op
        if op and op.get("drq"):
            return 0x80
        te = self.busy_until
        if op and op["kind"] in ("rs", "ra") and op["got"] < op["n"]:
            te = min(te, max(t, op["t0"] + op["got"] * T_BYTE))
        elif op and op["kind"] in ("ws", "wt") and op["put"] < op["n"]:
            nxt = op["t_drq"] if op["put"] == 0 else op["t0"] + (op["put"] - 1) * T_BYTE
            te = min(te, max(t, nxt))
        self.skew += max(0, te - t) + 1
        t = self.now()
        self._update(t)
        if t < self.busy_until and self.op and self.op.get("drq"):
            return 0x80
        return 0x00

    # drive ------------------------------------------------------------------
    def ready(self):
        return self.disk is not None and self.spinning

    def index_active(self, t):
        return self.ready() and (t - self.idx_t0) % REV < IDX_W

    def next_index(self, t):
        k = -(-(t - self.idx_t0) // REV)
        return self.idx_t0 + k * REV

    def next_pos(self, t, off):
        """First time >= t that disk byte offset `off` passes the head."""
        base = self.next_index(t) - REV
        x = base + off * T_BYTE
        while x < t:
            x += REV
        return x

    # status -----------------------------------------------------------------
    def status(self, t):
        busy = t < self.busy_until
        if self.type1:
            v = 0
            if not self.ready():
                v |= 0x80
            if self.disk is not None and self.disk.wp:
                v |= 0x40
            if self.hld:
                v |= 0x20
            if self.seek_err:
                v |= 0x10
            if self.head == 0:
                v |= 0x04
            if self.index_active(t):
                v |= 0x02
            return v | (1 if busy else 0)
        self._update(t)
        v = self.final
        if not self.ready():
            v |= 0x80
        if busy:
            v |= 1
            if self.op and self.op.get("drq"):
                v |= 2
        return v

    def _update(self, t):
        op = self.op
        if op is None or op["kind"] in ("done", "none"):
            return
        tt = min(t, self.busy_until - 1)
        if op["kind"] in ("rs", "ra"):
            if tt < op["t0"]:
                op["drq"] = False
            else:
                a = min(op["n"], (tt - op["t0"]) // T_BYTE + 1)   # bytes assembled
                if a - op["got"] >= 2:
                    self.final |= 0x04                           # lost data
                    op["got"] = a - 1
                op["drq"] = a - op["got"] == 1
        else:                                                    # ws / wt
            if tt < op["t_drq"]:
                op["drq"] = False
            elif op["put"] == 0 and (
                    (op["kind"] == "wt" and tt >= op["t0"]) or
                    (op["kind"] == "ws" and tt >= op["t_drq"] + 11 * T_BYTE)):
                self.final |= 0x04                               # first byte late: abort
                self.busy_until = tt
                op["kind"] = "done"
                op["drq"] = False
                return
            else:
                m = 0 if tt < op["t0"] else min(op["n"], (tt - op["t0"]) // T_BYTE + 1)
                if m > op["put"]:
                    self.final |= 0x04                           # DR not reloaded in time
                    op["buf"] += bytes(m - op["put"])
                    op["put"] = m
                op["drq"] = op["put"] == m and op["put"] < op["n"]
        if t >= self.busy_until:
            if op["kind"] in ("ws", "wt"):
                self._commit(op)
            op["kind"] = "done"
            op["drq"] = False

    def _commit(self, op):
        if op.get("committed"):
            return
        op["committed"] = True
        if op["kind"] == "ws":
            data = bytes(op["buf"][:op["n"]]).ljust(op["n"], b"\x00")
            op["sector"]["data"][:] = data
            op["sector"]["crc_bad"] = False
        else:
            self.disk.raw[self.head] = bytes(op["buf"])
            self.disk.tracks[self.head] = parse_stream(bytes(op["buf"]))
            self.log.append((self.now(), "track", self.head, len(op["buf"])))

    # ports --------------------------------------------------------------------
    def inp(self, port):
        t = self.now()
        if port == 0xF8:
            return self.status(t)
        if port == 0xF9:
            return self.tr
        if port == 0xFA:
            return self.sr
        if port == 0xFC:
            return self.wait_port()
        if port == 0xFB:
            self._update(t)
            op = self.op
            if op and op["kind"] in ("rs", "ra") and op.get("drq"):
                v = op["bytes"][op["got"]]
                self._lat(op["kind"], t - (op["t0"] + op["got"] * T_BYTE))
                op["got"] += 1
                op["drq"] = False
                self.dr = v
            return self.dr
        return 0xFF

    def out(self, port, val):
        t = self.now()
        if port == 0xF8:
            self.command(val, t)
        elif port == 0xF9:
            self.tr = val
        elif port == 0xFA:
            self.sr = val
        elif port == 0xFB:
            self.dr = val
            self._update(t)
            op = self.op
            if op and op["kind"] in ("ws", "wt") and op.get("drq"):
                if op["put"] > 0:
                    rise = max(op["t_drq"], op["t0"] + (op["put"] - 1) * T_BYTE)
                    self._lat(op["kind"], t - rise)
                op["buf"].append(val)
                op["put"] += 1
                op["drq"] = False

    def _lat(self, kind, dt):
        if dt > self.max_lat.get(kind, -1):
            self.max_lat[kind] = dt

    # commands -----------------------------------------------------------------
    def command(self, c, t):
        self.log.append((t, "cmd", c))
        if (c & 0xF0) == 0xD0:
            if self.op and self.op["kind"] in ("ws", "wt") and t < self.busy_until:
                self.busy_until = t
                self._commit(self.op)
            self.op = None
            self.busy_until = min(self.busy_until, t)
            self.type1 = True
            return
        if t < self.busy_until:
            return                                   # ignored while busy
        if c & 0x80 == 0:
            self._type1(c, t)
        else:
            self._type23(c, t)

    def _type1(self, c, t):
        self.type1 = True
        self.op = None
        self.seek_err = False
        self.hld = bool(c & 0x08)
        rate = STEP_MS[c & 3] * MS
        kind = c >> 4
        steps = 0
        if kind == 0:                                # restore
            steps = min(self.head, 255)
            self.head -= steps
            if self.head == 0:
                self.tr = 0
            else:
                self.seek_err = True
        elif kind == 1:                              # seek to DR
            delta = self.dr - self.tr
            steps = abs(delta)
            self.head = max(0, min(NTRK + 2, self.head + delta))
            self.tr = self.dr
        else:
            if kind in (4, 5):
                self.dir = 1
            elif kind in (6, 7):
                self.dir = -1
            d = getattr(self, "dir", 1)
            self.head = max(0, min(NTRK + 2, self.head + d))
            if c & 0x10:
                self.tr = (self.tr + d) & 0xFF
            steps = 1
        self.busy_until = t + 200 + steps * rate + (SETTLE if c & 4 else 0)

    def _find(self, ts, match):
        """Next ID field after ts that satisfies match(); None if 5 index
        pulses pass first. Returns (sector, time of the ID mark)."""
        limit = self.next_index(ts) + 4 * REV
        best = None
        for s in self.disk.sectors(self.head):
            if not match(s):
                continue
            x = self.next_pos(ts, s["id_off"])
            if x <= limit and (best is None or x < best[1]):
                best = (s, x)
        return best, limit

    def _type23(self, c, t):
        self.type1 = False
        self.final = 0
        self.hld = True
        if not self.ready():
            self.final = 0x80
            self.busy_until = t
            self.op = None
            return
        ts = t + 200 + (SETTLE if c & 4 else 0)
        top = c >> 4
        write = top in (0xA, 0xB, 0xF)
        if write and self.disk.wp:
            self.final = 0x40
            self.busy_until = t
            self.op = None
            return
        if top in (0x8, 0x9, 0xA, 0xB):              # read / write sector
            hit, limit = self._find(ts, lambda s: s["id"][0] == self.tr and s["id"][2] == self.sr
                                    and s["data"] is not None)
            if hit is None:
                self.final = 0x10
                self.busy_until = limit
                self.op = {"kind": "none", "drq": False}
                return
            s, x = hit
            n = len(s["data"])
            t_data = self.next_index(x) - REV + s["data_off"] * T_BYTE
            while t_data < x:
                t_data += REV
            if top in (0x8, 0x9):
                if s["crc_bad"]:
                    self.final |= 0x08
                self.op = {"kind": "rs", "t0": t_data + T_BYTE, "n": n, "got": 0,
                           "bytes": bytes(s["data"]), "drq": False}
                self.busy_until = t_data + (n + 3) * T_BYTE
            else:
                t_drq = x + 7 * T_BYTE
                self.op = {"kind": "ws", "t_drq": t_drq, "t0": t_data, "n": n, "put": 0,
                           "buf": bytearray(), "sector": s, "drq": False}
                self.busy_until = t_data + (n + 3) * T_BYTE
        elif top == 0xC:                             # read address
            hit, limit = self._find(ts, lambda s: True)
            if hit is None:
                self.final = 0x10
                self.busy_until = limit
                self.op = {"kind": "none", "drq": False}
                return
            s, x = hit
            idb = bytes(s["id"]) + b"\x12\x34"
            self.sr = s["id"][0]
            self.op = {"kind": "ra", "t0": x + 2 * T_BYTE, "n": 6, "got": 0,
                       "bytes": idb, "drq": False}
            self.busy_until = x + 9 * T_BYTE
        elif top == 0xF:                             # write track
            t_idx = self.next_index(ts)
            n = REV // T_BYTE
            self.op = {"kind": "wt", "t_drq": ts, "t0": t_idx, "n": n, "put": 0,
                       "buf": bytearray(), "drq": False}
            self.busy_until = t_idx + REV
        elif top == 0xE:                             # read track: raw bytes, index to index
            t_idx = self.next_index(ts)
            n = REV // T_BYTE
            raw = self.disk.raw.get(self.head)
            if raw is None:                          # erased / unformatted: noise
                x = 0x1234 + self.head
                out = bytearray()
                for _ in range(n):
                    x = (x * 1103515245 + 12345) & 0x7FFFFFFF
                    out.append((x >> 16) & 0xFF)
            else:
                out = bytearray()
                for b in raw:
                    out += b"\x12\x34" if b == 0xF7 else bytes([b])
                out = out[:n].ljust(n, b"\xff")
            self.op = {"kind": "rs", "t0": t_idx + T_BYTE, "n": n, "got": 0,
                       "bytes": bytes(out), "drq": False}
            self.busy_until = t_idx + REV
        else:                                        # anything else: not modelled
            self.final = 0x10
            self.busy_until = t
            self.op = None
