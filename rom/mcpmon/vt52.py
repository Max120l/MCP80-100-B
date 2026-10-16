"""A real DEC VT52 screen for the simulator, per the DECscope Users' Manual
(EK-VT5X-OP-001): 80 x 24, only the VT52's own escape codes (ESC A B C D H
I J K Y Z [ \\ = > F G), no wrap at column 80 (the cursor stays in column
80), ESC Y with an off-screen row moves only the column. Anything a VT52
wouldn't do (VT100 codes, ESC [ = hold screen, graphics mode, other control
characters) is collected in .bad, so a test can insist on none.

    vt = VT52(); vt.feed(sim.output()); print(vt.show()); assert not vt.bad

Used to check VEZZA52.COM (cpm/vezza52.py) before it ran on the real VT52.
"""


class VT52:
    VALID = set("ABCDHIJKYZ[\\=>FG")
    def __init__(s):
        s.scr=[[' ']*80 for _ in range(24)]; s.r=s.c=0; s.st=0; s.bad=[]; s.yrow=None
        s.hold=False; s.graphics=False
    def feed(s, data):
        for ch in data:
            o=ord(ch)
            if s.st==1:
                s.st=0
                if ch not in s.VALID: s.bad.append("ESC "+repr(ch)); continue
                if ch=='A': s.r=max(0,s.r-1)
                elif ch=='B': s.r=min(23,s.r+1)
                elif ch=='C': s.c=min(79,s.c+1)
                elif ch=='D': s.c=max(0,s.c-1)
                elif ch=='H': s.r=s.c=0
                elif ch=='I':
                    if s.r==0: s.scr=[[' ']*80]+s.scr[:-1]
                    else: s.r-=1
                elif ch=='J':
                    s.scr[s.r][s.c:]=[' ']*(80-s.c)
                    for i in range(s.r+1,24): s.scr[i]=[' ']*80
                elif ch=='K': s.scr[s.r][s.c:]=[' ']*(80-s.c)
                elif ch=='Y': s.st=2
                elif ch=='[': s.hold=True; s.bad.append("hold screen")
                elif ch=='F': s.graphics=True; s.bad.append("graphics")
                elif ch=='G': s.graphics=False
                else: s.bad.append("ESC "+ch)
                continue
            if s.st==2: s.yrow=o-32; s.st=3; continue
            if s.st==3:
                s.st=0
                if 0<=s.yrow<=23: s.r=s.yrow
                else: s.bad.append("ESC Y row %d off screen" % s.yrow)
                s.c=min(79,max(0,o-32)); continue
            if o==27: s.st=1
            elif o==13: s.c=0
            elif o==10:
                if s.r==23: s.scr=s.scr[1:]+[[' ']*80]
                else: s.r+=1
            elif o==8: s.c=max(0,s.c-1)
            elif o==9: s.c=min(79,(s.c//8+1)*8)
            elif o in (0,7,127): pass
            elif o<32: s.bad.append("ctrl %02X" % o)
            else:
                s.scr[s.r][s.c]=ch
                if s.c<79: s.c+=1
    def show(s):
        return "\n".join("|"+"".join(l)+"|" for l in s.scr)
