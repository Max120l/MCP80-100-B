#!/usr/bin/env python3
"""Build a bootable CP/M 2.2 disk image for the MCP 80/100.

    python3 build.py [--z80pack DIR] [--out DIR]

Output (default out/):
  mcpcpm22.img   8" SSSD image, 77 x 26 x 128 bytes in physical sector order.
                 Write it with a Greaseweazle: gw write --format=dec.rx01 FILE
  systrk.bin     the two system tracks (boot sector, CCP, BDOS, BIOS)
  ccpbdos.bin    CCP + BDOS relocated to D400h (60K)
  XM.COM         XMODEM on port B (also on the disk)
and, next to this script:
  xm.hex         XM for MCPMON's H command (loads at 0100h; then boot CP/M
                 and SAVE 10 XM.COM: the way onto an existing disk)

CP/M itself comes from Digital Research's distribution as packaged in
z80pack (https://github.com/udo-munk/z80pack), fetched here on first use:
  - MOVCPM.COM holds a CCP + BDOS image assembled for address 0000h.
  - z80pack's cpm.bin holds the same CCP + BDOS relocated for 64K (E400h).
  Every byte that differs between the two is the high byte of an address,
  differing by exactly E4h. That gives the relocation map, so the zero-based
  image is moved to D400h by adding D4h at those bytes.
The standard utilities come from z80pack's CP/M 2.2 distribution disk.

Needs: z80asm, cpmtools (mkfs.cpm, cpmcp, cpmls), git (first run only).
"""
import argparse, os, subprocess, sys, tempfile
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools"))
from bin2hex import ihex

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

CCP_BASE = 0xD400               # 60K system
CCPBDOS_LEN = 44 * 128          # 5632 bytes
UTILS = ["pip.com", "stat.com", "ed.com", "asm.com", "load.com", "ddt.com",
         "dump.com", "submit.com", "xsub.com", "sysgen.com"]
DISKDEF = "ibm-3740"
IMG_LEN = 77 * 26 * 128


def run(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode:
        sys.exit("%s failed:\n%s%s" % (" ".join(cmd), r.stdout, r.stderr))
    return r.stdout


def fetch_z80pack(dest):
    need = ["cpmsim/srccpm2/cpm.bin", "cpmsim/disks/library/cpm22-1.dsk"]
    if all(os.path.exists(os.path.join(dest, p)) for p in need):
        return
    print("fetching z80pack (CP/M 2.2 distribution files) ...")
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    if not os.path.isdir(os.path.join(dest, ".git")):
        run(["git", "clone", "--depth", "1", "--filter=blob:none", "--no-checkout",
             "https://github.com/udo-munk/z80pack", dest])
    run(["git", "-C", dest, "sparse-checkout", "init", "--no-cone"])
    with open(os.path.join(dest, ".git", "info", "sparse-checkout"), "w") as f:
        f.write("\n".join(need) + "\n")
    run(["git", "-C", dest, "checkout"])


def relocated_ccpbdos(movcpm, cpm64, base=CCP_BASE):
    zero = movcpm[0x900:0x900 + CCPBDOS_LEN]          # assembled for 0000h
    e400 = cpm64[0x880:0x880 + CCPBDOS_LEN]           # same, for E400h
    if zero[:3] != b"\xc3\x5c\x03":
        sys.exit("MOVCPM.COM: CCP image not where expected")
    out = bytearray(zero)
    nrel = 0
    for i in range(CCPBDOS_LEN):
        if zero[i] != e400[i]:
            if (e400[i] - zero[i]) & 0xFF != 0xE4:
                sys.exit("unexpected difference at %04X: not a relocation" % i)
            out[i] = (zero[i] + (base >> 8)) & 0xFF
            nrel += 1
    return bytes(out), nrel


def assemble(src, tmp):
    binf = os.path.join(tmp, os.path.basename(src) + ".bin")
    lbl = os.path.join(tmp, os.path.basename(src) + ".lbl")
    run(["z80asm", "-i", src, "-o", binf, "--label=" + lbl], cwd=HERE)
    labels = {}
    for line in open(lbl):
        name, _, val = line.partition(":")
        if "equ $" in val:
            labels[name.strip()] = int(val.split("$")[1], 16)
    return open(binf, "rb").read(), labels


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--z80pack", default=os.path.join(HERE, ".cache", "z80pack"))
    ap.add_argument("--out", default=os.path.join(HERE, "out"))
    a = ap.parse_args()
    fetch_z80pack(a.z80pack)
    os.makedirs(a.out, exist_ok=True)
    dist = os.path.join(a.z80pack, "cpmsim", "disks", "library", "cpm22-1.dsk")

    with tempfile.TemporaryDirectory() as tmp:
        run(["cpmcp", "-f", DISKDEF, dist, "0:movcpm.com"] + ["0:" + u for u in UTILS]
            + [tmp])
        movcpm = open(os.path.join(tmp, "movcpm.com"), "rb").read()
        cpm64 = open(os.path.join(a.z80pack, "cpmsim", "srccpm2", "cpm.bin"), "rb").read()
        ccpbdos, nrel = relocated_ccpbdos(movcpm, cpm64)
        print("CCP+BDOS relocated to %04Xh (%d address bytes)" % (CCP_BASE, nrel))

        boot, _ = assemble("boot.asm", tmp)
        bios, lb = assemble("bios.asm", tmp)
        if len(boot) != 128:
            sys.exit("boot sector is %d bytes, must be 128" % len(boot))
        if len(bios) > 7 * 128:
            sys.exit("BIOS is %d bytes: only 896 fit on the system tracks" % len(bios))
        print("boot sector 128 bytes, BIOS %d of 896 bytes, buffers end %04Xh"
              % (len(bios), lb["BUFEND"]))
        if lb["BUFEND"] > 0xF000:
            sys.exit("BIOS buffers run into F000h")

        xm, lx = assemble("xm.asm", tmp)
        if lx["CODEEND"] > 0xC00:
            sys.exit("XM runs into its stack at 0C00h")
        open(os.path.join(HERE, "xm.hex"), "w", newline="").write(ihex(xm, 0x100))
        xmcom = os.path.join(a.out, "XM.COM")
        open(xmcom, "wb").write(xm + b"\x1a" * (-len(xm) % 128))
        print("XM.COM %d bytes (0100h-%04Xh), SAVE %d" % (len(xm), 0xFF + len(xm),
                                                       (len(xm) + 255) // 256))

        systrk = boot + ccpbdos + bios.ljust(7 * 128, b"\x00")
        assert len(systrk) == 52 * 128
        open(os.path.join(a.out, "systrk.bin"), "wb").write(systrk)
        open(os.path.join(a.out, "ccpbdos.bin"), "wb").write(ccpbdos)

        img = os.path.join(a.out, "mcpcpm22.img")
        open(img, "wb").write(b"\xe5" * IMG_LEN)
        run(["mkfs.cpm", "-f", DISKDEF, img])
        with open(img, "r+b") as f:                       # system tracks, raw
            f.write(systrk)
        fdtest = os.path.join(REPO, "tools", "fdtest", "FDTEST.COM")
        files = [os.path.join(tmp, u) for u in UTILS] + [fdtest, xmcom]
        run(["cpmcp", "-f", DISKDEF, img] + files + ["0:"])
        print(run(["cpmls", "-f", DISKDEF, "-D", img]))
        size = os.path.getsize(img)
        if size != IMG_LEN:
            sys.exit("image is %d bytes, expected %d" % (size, IMG_LEN))
        print("%s: %d bytes" % (img, size))


if __name__ == "__main__":
    main()
