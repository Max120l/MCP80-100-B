"""XCOMP ST/S hard disk controller (ports 60h-66h) with a MiniScribe 4020
attached, for the MCP simulator. Attach as MCP.hdc_model.

Timed against the CPU clock (now(), T-states):
  - drive: 480 cylinders x 4 heads x 32 sectors of 256 bytes, 3600 rpm,
    buffered seeks (15 ms + 0.5 ms per cylinder), index once per turn,
    status bits as in the ST/S manual (port 60h)
  - controller: microcode RAM banks, data buffer, compare buffer, the
    dummy first read after setting the pointer, status port 64h
  - the read microcode isn't emulated instruction by instruction: a START
    of bank 0 at D7h (where the ROM's table A starts, checked against the
    table actually loaded) searches the track under the selected head for a
    header equal to the 4 compare-buffer bytes at EAh-EDh, and completes
    when that sector has passed under the head (or after two turns with
    DONE + BUSY: not found, error 02 as the real controller reports it)
  - a START of bank 1 (the write microcode) is never carried out; it is
    counted in write_starts so tests can insist on zero

The sector header layout is a function header(c, h, s) -> 4 bytes, so
tests can try layouts the imager doesn't know in advance.

Flaky cabling, as seen on the real drive: during a dropout (dropouts: list
of (t0, t1)) the drive reads as not selected and not ready, and a read that
is running when one starts completes with DONE and no error bits but zero
data, as if the controller lost the drive halfway. drop_reads holds indexes
(into reads) of reads that end that way with no visible dropout at all,
the worst case: nothing but a second read can tell. drop_at_read maps a
read index to the length of a dropout that begins during that read.

drift is a time before each dropout during which every read fails with a
CRC error: the spindle speed drifting before the firmware drops READY.

speed is a list of (t0, t1, factor): the spindle period is rev x factor in
that time, the index comes accordingly, and since the controller times
sectors from the index, sectors whose slot x |factor - 1| exceeds a
quarter of a slot are not found (the last sectors of a track go first).

spare=True gives every track a 33rd sector with sector number 32 and E5
fill, as the real drive seems to have (every track answers to it).

Damaged ID fields, as found on the real drive's directory tracks: id_errors
gives, per sector, the 4 header bytes that are actually there; the sector
then answers only to those. bad = 'missing' is an ID that answers to
nothing; 'crc' is a sector whose data comes back with a bit wrong and the
CRC bit set.
"""

ROM_TABLE_A = bytes([0x40, 0x41] + [0x40] * 3 + [0x6D] * 12 + [0x63] + [0x65] * 4 +
                    [0x67] * 2 + [0x49] + [0x40] * 2 + [0x6D] * 12 + [0x63, 0xE7, 0x67] +
                    [0x0F] * 7 + [0x40, 0x41] + [0x40] * 3 + [0x6D] * 12 + [0x63] +
                    [0x65] * 2 + [0x60] * 2 + [0x67] * 2 + [0x0F])


def layout_cchs(c, h, s):
    """cylinder low, cylinder high, head, sector"""
    return bytes([c & 0xFF, c >> 8, h, s])


def default_data(c, h, s):
    seed = (c * 4 + h) * 32 + s
    head = b"C%03dH%dS%02d" % (c, h, s)
    body = bytes((seed * 7 + i * 13) & 0xFF for i in range(256 - len(head)))
    return head + body


class XComp:
    def __init__(self, now, mhz=6.0, cyls=480, heads=4, nsec=32, header=layout_cchs,
                 data=default_data, interleave=1, start_cyl=137, ready=True, spare=False):
        self.now = now
        self.t_ms = int(mhz * 1000)
        self.rev = int(16.6667 * self.t_ms)
        self.slot = self.rev // nsec
        self.cyls, self.heads, self.nsec = cyls, heads, nsec
        self.header, self.data = header, data
        self.ready = ready
        self.spare = spare                # a 33rd sector per track, "sector 32", E5 fill
        # physical slot of each logical sector
        self.phys = {}
        p = 0
        used = set()
        for s in range(nsec):
            while p in used:
                p = (p + 1) % nsec
            self.phys[s] = p
            used.add(p)
            p = (p + interleave) % nsec
        self.bad = {}                     # (c,h,s) -> 'crc' | 'missing'
        self.id_errors = {}               # (c,h,s) -> the 4 ID bytes actually on the disk
        self.seek_errors = {}             # seek index -> cylinders the drive lands off by
        self.unformatted = set()          # (c,h) with no sectors at all
        self.dropouts = []                # (t0, t1): the drive is gone
        self.drift = 0                    # T-states before a dropout in which reads fail (CRC)
        self.speed = []                   # (t0, t1, factor): the spindle period x factor
        self.drop_reads = set()           # reads that silently return zeros
        self.drop_at_read = {}            # read index -> a dropout of that length starts in it
        # drive
        self.dext = 0
        self.dcmd = 0
        self.count = 0
        self.cyl = start_cyl
        self.seek_from = start_cyl
        self.seek_to = start_cyl
        self.seek_t0 = 0
        self.seek_end = 0
        self.idx_clear = 0
        # controller
        self.mode = 0
        self.ptr = 0
        self.mem = {0: bytearray(256), 1: bytearray(256), 2: bytearray(256), 4: bytearray(256)}
        self.latch = 0
        self.op = None                    # (end time, status bits, start time)
        self.status = 0
        self.flag_clear = 0
        # what happened
        self.write_starts = 0
        self.reads = []                   # (c, h, id bytes, found)
        self.seeks = 0
        self.max_cyl_seen = 0

    # ---- drive ---------------------------------------------------------------
    def _pos(self):
        t = self.now()
        if t >= self.seek_end:
            self.cyl = self.seek_to
        else:
            frac = (t - self.seek_t0) / max(1, self.seek_end - self.seek_t0)
            self.cyl = round(self.seek_from + (self.seek_to - self.seek_from) * frac)
        return self.cyl

    def _seeking(self):
        return self.now() < self.seek_end

    def factor(self, t):
        for a, b, f in self.speed:
            if a <= t < b:
                return f
        return 1.0

    def gone(self, t0, t1=None):
        """Is the drive in a dropout at t0 (or anywhere in t0..t1)?"""
        t1 = t0 if t1 is None else t1
        return any(a <= t1 and t0 < b for a, b in self.dropouts)

    def selected(self):
        return bool(self.dext & 1) and not self.gone(self.now())

    def head(self):
        return (self.dext >> 2) & 7

    def _start_seek(self, n):
        cur = self._pos()
        tgt = cur + n if self.dext & 2 else cur - n
        tgt += self.seek_errors.get(self.seeks, 0)
        tgt = max(0, min(525, tgt))       # the drive's own limit (shipping zone)
        self.seek_from, self.seek_to = cur, tgt
        self.seek_t0 = self.now()
        self.seek_end = self.seek_t0 + 15 * self.t_ms + abs(tgt - cur) * self.t_ms // 2
        self.seeks += 1
        self.max_cyl_seen = max(self.max_cyl_seen, tgt)

    def _stop_seek(self):
        cur = self._pos()
        self.seek_from = self.seek_to = cur
        self.seek_end = min(self.seek_end, self.now() + 15 * self.t_ms)

    # ---- controller ----------------------------------------------------------
    def _target(self):
        if self.mode & 4:
            return self.mem[4]
        if self.mode & 2:
            return self.mem[2]
        return self.mem[self.mode & 1]

    def _start(self):
        t = self.now()
        self.status = 0
        if self.mode & 1:                 # bank 1: write microcode
            self.write_starts += 1
            self.op = None
            return
        tab = bytes(self.mem[0][0xD7:]) + bytes(self.mem[0][:0x21])
        if self.ptr != 0xD7 or tab != ROM_TABLE_A or not self.dext & 1 or not self.ready:
            self.op = (t + 10 ** 12, 0, t)   # never completes
            return
        want = bytes(self.mem[4][0xEA:0xEE])
        c, h = self._pos(), self.head()
        n = len(self.reads)
        if n in self.drop_at_read:            # the drive goes away during this read
            self.dropouts.append((t + 1, t + self.drop_at_read[n]))
        if self.gone(t) or n in self.drop_reads:
            self.reads.append((c, h, want, "dropout"))
            self._spurious(t + self.t_ms)
            return
        if self.drift and any(a - self.drift <= t < a for a, b in self.dropouts):
            self.reads.append((c, h, want, "drift"))   # speed off: nothing reads
            self.op = (t + 2 * self.rev, 0x01 | 0x08, t)
            return
        found = None
        if not self._seeking() and h < self.heads and c < self.cyls and (c, h) not in self.unformatted:
            for s in range(self.nsec):
                hdr = self.id_errors.get((c, h, s)) or self.header(c, h, s)
                if hdr == want and self.bad.get((c, h, s)) != "missing":
                    found = s
                    break
        if found is None and self.spare and not self._seeking() and h < self.heads \
                and c < self.cyls and self.header(c, h, 32) == want:
            found = 32
        # the controller times sectors from the index: off speed, the error
        # builds up around the track and the last sectors miss their windows
        if found is not None and abs(self.factor(t) - 1) * self.phys.get(found, 32) > 0.25:
            self.reads.append((c, h, want, "speed"))
            found = None
        self.reads.append((c, h, want, found))
        if found is None:
            nxt = (t // self.rev + 1) * self.rev
            self.op = (nxt + self.rev, 0x03, t)   # DONE + BUSY: not found (02, as the real one)
            return
        start = (t // self.rev) * self.rev + self.phys.get(found, 31) * self.slot
        while start < t + self.t_ms // 20:            # header must still be ahead
            start += self.rev
        end = start + self.slot * 9 // 10
        st = 0x01
        self.mem[2][:] = self.data(c, h, found) if found < 32 else b"\xe5" * 256
        if self.bad.get((c, h, found)) == "crc":
            st |= 0x08
            self.mem[2][100] ^= 0x40          # the data as read, one bit wrong
        self.op = (end, st, t)

    def _spurious(self, end):
        """the drive went away during the read: DONE, no errors, zeros"""
        self.mem[2][:] = bytes(256)
        self.op = (end, 0x01, self.now())

    def _cstatus(self):
        t = self.now()
        v = self.status
        if self.op:
            end, st, t0 = self.op
            if t >= end:
                if st and self.gone(t0, end):
                    self._spurious(end)
                    st = 0x01
                    self.reads[-1] = self.reads[-1][:3] + ("dropout",)
                v = self.status = st
                self.op = None
            else:
                v = 0x02
        if (t // self.rev) > (self.flag_clear // self.rev):
            v |= 0x10                     # delayed index
        if t - self.flag_clear > self.slot:
            v |= 0x20                     # sector pulse
        if not self._seeking():
            v |= 0x40
        return v

    def _dstatus(self):
        if not self.selected():
            return 0x10
        t = self.now()
        v = 0x01 if self.ready else 0
        if self._pos() == 0:
            v |= 0x04
        if not self._seeking():
            v |= 0x08 | 0x80
        rev = int(self.rev * self.factor(t))
        if (t // rev) > (self.idx_clear // rev):
            v |= 0x20
        return v

    # ---- ports -----------------------------------------------------------------
    def out(self, port, val):
        if port == 0x60:
            if val & 1 and not self.dcmd & 1 and self.count:
                self._start_seek(self.count)
            self.dcmd = val
        elif port == 0x61:
            self.dext = val
        elif port == 0x62:
            self.count = (self.count & 0x100) | val
            if self.count == 0 and self._seeking():
                self._stop_seek()
        elif port == 0x63:
            self.count = (self.count & 0xFF) | ((val & 1) << 8)
            if self.count == 0 and self._seeking():
                self._stop_seek()
        elif port == 0x64:
            self.flag_clear = self.now()
            if not val & 8 and self.op:
                self.op = None            # stopped
            self.mode = val
            if val & 8:
                self._start()
        elif port == 0x65:
            self.ptr = val
        elif port == 0x66:
            self._target()[self.ptr] = val
            self.ptr = (self.ptr + 1) & 0xFF

    def inp(self, port):
        if port == 0x60:
            return self._dstatus()
        if port == 0x61:
            self.idx_clear = self.now()
            return 0xFF
        if port == 0x64:
            return self._cstatus()
        if port == 0x66:
            v = self.latch
            self.latch = self._target()[self.ptr]
            self.ptr = (self.ptr + 1) & 0xFF
            return v
        return 0xFF
