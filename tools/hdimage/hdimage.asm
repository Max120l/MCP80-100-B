;=======================================================================
; HDIMAGE 1.0 - image the MiniScribe 4020 through the XCOMP ST/S and send
; it to the PC by XMODEM on port B. For MCPMON 2.0 (uses its console and
; hard disk entry points).
;
; Load with MCPMON:  H  (send hdimage.hex),  then  G:0100 <CR>
;
; READS ONLY. The controller is set up by MCPMON's HDINIT (the original
; ROM's tables and restore) and only the read microcode (bank 0 at D7h) is
; ever started. Bank 1, the write microcode, is never touched.
;
;   P  probe: find the sector header layout. The 4 header bytes hold the
;      cylinder, head and sector; the MiniScribe in the MCP has cylinder
;      low, cylinder high, head, sector, so that is tried first, with two
;      check reads that between them set every address bit. If it doesn't
;      read, the search: C0 H0 S0 is known to be 00 00 00 00 (the boot
;      sector), and for each address bit (sector 1, 2, 4.., head 1, 2,
;      cylinder 1, 2, 4 .. 256) the probe reads with one header bit set at
;      a time until the sector is found.
;   R  read one sector (cylinder, head, sector) and dump it
;   I  image a range of cylinders: 4 sectors at a time into a 1K block,
;      sent as one XMODEM-1K block (or 8 x 128 if the PC asks for
;      checksum), cylinder by cylinder, head 0-3, sector 0-31
;   F  hunt for the sectors in the bad list behind damaged IDs (every
;      single-bit and single-byte variant of the ID), and send what it
;      finds to the PC as a fix file for hdfix.py
;   T  drive tests, all read-only: the index period revolution by
;      revolution (spindle speed and its wobble, READY drops), and seek
;      patterns (one-cylinder walk, full-stroke, random, butterfly) with
;      every seek timed and verified by reading a header at the target
;   S  drive status   Z  restore   Q  quit
;   K  park: seek to the shipping zone, cylinder 525, the position the
;      drive's own firmware uses (its exerciser ships the heads there and
;      it refuses anything beyond); then power the drive down
;
; Bad sectors: 5 reads, then 10 more; before those, on the first failure
; in a track, one recalibrate. A sector that still fails goes into the image as a text
; filler ("** BAD SECTOR C123 H1 S07 **") and into a list shown at the end.
;
; The drive drops READY now and then (its firmware losing spindle speed
; lock for a moment; before that it was flaky cabling), and a read caught
; by that can complete with no error bits and no data. So: the drive
; status is checked after every read as well as before, the probe believes
; a read only when a second one agrees, and when the drive goes away the
; imager waits up to 60 s for it, restores, and goes on from the same
; sector; if it stays away the image is stopped so it can be restarted
; from that cylinder. A sector that fails all its tries is given 2 s to see
; whether READY drops (the speed drifting before the firmware notices).
;
; Timeouts assume the 6 MHz CPU.
;=======================================================================
WARM:	equ 0f803h			; MCPMON entry points
CONIN:	equ 0f809h
CONOUT:	equ 0f80ch
PUTS:	equ 0f818h
PUTHEX:	equ 0f81bh
HDINIT:	equ 0f81eh			; tables, select, restore: Z = OK
HDGETBUF: equ 0f824h			; copy the 256-byte buffer to HL

CONS_P:	equ 003h			; console 8251
COND:	equ 002h
AUXD:	equ 000h			; port B 8251
AUXS:	equ 001h

DSTAT:	equ 060h			; in: drive status   out: drive commands
DEXT:	equ 061h			; out: select, direction, head
SCLO:	equ 062h			; seek count
SCHI:	equ 063h
CCMD:	equ 064h			; controller commands / status
CPTR:	equ 065h			; buffer address
CDATA:	equ 066h			; data

SOH:	equ 001h
STX:	equ 002h
EOT:	equ 004h
ACK:	equ 006h
NAK:	equ 015h
CAN:	equ 018h

MAXCYL:	equ 479
PARKCYL: equ 525			; shipping zone (firmware: 1050 half-steps)
T100:	equ 11765			; RXTO: 51-T loop, 0.1 s at 6 MHz

STACK:	equ 1e00h			; the program must end below 1D00h
BADL:	equ 1e00h			; bad sector list: 5 bytes each, to 207Fh.
BADMAX:	equ 128				; Keep it here: F can use the list a
					; previous build left after a reload
CRCPG:	equ 021h			; CRC table: high bytes 2100h, low 2200h
BLK:	equ 2300h			; 1K block being sent
TESTS:	equ 2900h			; the T tests (second section), to 31FFh
FIXBUF:	equ 3200h			; F's records, 384 bytes each, up to F1FFh

	org 0100h

START:	ld sp,STACK
	call CRCINIT
	ld hl,MSG_HELP
	call PUTS
	call HDSETUP

MENU:	ld sp,STACK
	ld hl,MSG_PROMPT
	call PUTS
	call CONIN
	cp 'a'
	jr c,MN1
	sub 020h
MN1:	cp 020h
	jr c,MN2
	call CONOUT
MN2:	cp 'P'
	jp z,CMD_PROBE
	cp 'R'
	jp z,CMD_READ
	cp 'F'
	jp z,CMD_HUNT
	cp 'I'
	jp z,CMD_IMAGE
	cp 'S'
	jp z,CMD_STATUS
	cp 'T'
	jp z,CMD_TEST
	cp 'K'
	jp z,CMD_PARK
	cp 'Z'
	jp z,CMD_RESTORE
	cp '?'
	jp z,CMD_HELP
	cp 'Q'
	jr z,QUIT
	cp 01bh
	jr z,QUIT
	cp 003h
	jr z,QUIT
	jr MENU

QUIT:	xor a
	out (CCMD),a
	out (DEXT),a			; deselect
	out (DSTAT),a
	ld hl,MSG_CRLF
	call PUTS
	jp WARM

CMD_HELP:
	ld hl,MSG_HELP
	call PUTS
	jr MENU

CMD_STATUS:
	call CRLF
	call SHOWST
	jr MENU

CMD_RESTORE:
	call CRLF
	ld hl,(CURCYL)			; parked? the ROM's restore steps 511 at
	ld de,MAXCYL+1			; most: come back to the data area first
	or a
	sbc hl,de
	jr c,CRS1
	ld hl,MAXCYL
	call SEEKTO
CRS1:	call HDSETUP
	jp MENU

; K: park. Two seeks (the count is 9 bits): to 479, then to 525. The
; firmware recalibrates instead if it doesn't like the position, so
; TRACK 00 afterwards means it refused.
CMD_PARK:
	call CRLF
	ld hl,MAXCYL
	call SEEKTO
	jr nz,PK9
	ld hl,PARKCYL
	call SEEKTO
	jr nz,PK9
	in a,(DSTAT)
	and 004h
	jr nz,PK8
	ld hl,MSG_PARKED
	call PUTS
	jp MENU
PK8:	ld hl,MSG_PARK0
	call PUTS
	jp MENU
PK9:	ld hl,MSG_SEEKF
	call PUTS
	jp MENU

;-----------------------------------------------------------------------
; Drive set-up and positioning
;-----------------------------------------------------------------------
; HDSETUP: HDINIT, then say how it went
HDSETUP: call HDINIT2
	jr z,HS1
	call PUTS			; MCPMON's message
	call CRLF
	jp SHOWST
HS1:	ld hl,MSG_READY
	call PUTS
	jp SHOWST

; HDINIT2: MCPMON's HDINIT (load the tables, select, restore), then select
; head 0 the way this program keeps it. Z = OK, NZ with HL = message.
HDINIT2: call HDINIT
	push af
	push hl
	ld hl,0
	jr z,HI1
	ld hl,0ffffh			; no restore: position unknown
HI1:	ld (CURCYL),hl
	ld a,041h			; select + inhibit precomp, head 0
	ld (DEXTV),a
	out (DEXT),a
	ld a,002h			; ENABLE INTERFACE, SEEK off
	out (DSTAT),a
	pop hl
	pop af
	ret

; SHOWST: drive status port in words
SHOWST:	ld hl,MSG_ST
	call PUTS
	in a,(DSTAT)
	ld c,a
	call PUTHEX
	ld a,c
	and 010h
	ld hl,MSG_SEL
	call z,PUTS
	ld a,c
	and 001h
	ld hl,MSG_RDY
	call nz,PUTS
	ld a,c
	and 004h
	ld hl,MSG_TK0
	call nz,PUTS
	ld a,c
	and 002h
	ld hl,MSG_FLT
	call nz,PUTS
	jp CRLF

; SELHEAD: select head A (0-3)
SELHEAD: rlca
	rlca
	and 01ch
	ld b,a
	ld a,(DEXTV)
	and 0e3h
	or b
	ld (DEXTV),a
	out (DEXT),a
	ret

; SEEKTO: move to cylinder HL. Z = done, NZ = timeout. The seek count is
; 9 bits: a longer move (from the park position) is done in two. After a
; timeout the position is unknown (CURCYL = FFFFh): the drive may have
; moved without SEEK END being seen, as when it drops out during a seek.
; The next SEEKTO then restores first. (In the first full image a dropout
; during a recalibrate's seek left the heads somewhere else, and every
; sector to the end of the track was "not found".)
SEEKTO:	ld (TGTCYL),hl
	ld de,(CURCYL)
	ld a,d
	and e
	inc a
	jr nz,ST1			; position known
	call HDINIT2			; unknown: restore first
	jr nz,STFAIL
	ld hl,(TGTCYL)
	ld de,0
ST1:	or a
	sbc hl,de
	ret z
	ld b,002h			; in
	jr nc,SK0
	ld a,h				; out: count = -difference
	cpl
	ld h,a
	ld a,l
	cpl
	ld l,a
	inc hl
	ld b,000h
SK0:	ld de,512
	push hl
	or a
	sbc hl,de
	pop hl
	jr c,SK1
	ld hl,511			; too far for one seek: 511 now, the rest after
	push bc
	call SEEKN
	pop bc
	jr nz,STFAIL
	ld hl,(CURCYL)
	ld de,511
	bit 1,b
	jr nz,SK2
	or a
	sbc hl,de
	jr SK3
SK2:	add hl,de
SK3:	ld (CURCYL),hl
	ld hl,(TGTCYL)
	jr SEEKTO
SK1:	call SEEKN
	jr nz,STFAIL
	ld hl,(TGTCYL)
	ld (CURCYL),hl
	xor a
	ret
STFAIL:	ld hl,0ffffh			; where are the heads now? unknown
	ld (CURCYL),hl
	or 1
	ret

; SEEKN: step HL cylinders, B = 02h in / 00h out (as DRIVETEST)
SEEKN:	ld a,002h
	out (DSTAT),a			; SEEK off
	ld a,(DEXTV)
	and 0fdh
	or b
	ld (DEXTV),a
	out (DEXT),a			; direction
	ld a,l
	out (SCLO),a
	ld a,h
	out (SCHI),a
	ld a,003h
	out (DSTAT),a			; SEEK + ENABLE INTERFACE
	ld hl,4096			; let SEEK END drop
SN1:	in a,(DSTAT)
	rla
	jr nc,SN2
	dec hl
	ld a,h
	or l
	jr nz,SN1
SN2:	ld hl,0				; wait for SEEK END, about 4 s
	ld d,10
SN3:	in a,(DSTAT)
	rla
	jr c,SN4
	dec hl
	ld a,h
	or l
	jr nz,SN3
	dec d
	jr nz,SN3
	ld a,002h
	out (DSTAT),a
	or 1
	ret
SN4:	ld a,002h
	out (DSTAT),a			; SEEK off
	xor a
	ret

; RECAL: get the heads properly onto RCYL / RHEAD again. First a short
; move away and back (two cylinders), then up to three restores with the
; seek back; after each, the landing is checked by reading a neighbour
; of RSEC (any of the next three sectors). The drive has been seen to
; land off-track after a long seek: without the check, every sector of
; the track after a recalibrate failed. Z = a neighbour reads.
RECAL:	ld hl,(RCYL)
	ld de,2
	or a
	sbc hl,de
	jr nc,RC1
	ld hl,(RCYL)
	add hl,de
RC1:	call SEEKTO
	ld hl,(RCYL)
	call SEEKTO
	ld a,(RHEAD)
	call SELHEAD
	call LANDED
	ret z
	ld b,3
RC2:	push bc
	call HDINIT2
	ld hl,(RCYL)
	call SEEKTO
	ld a,(RHEAD)
	call SELHEAD
	call LANDED
	pop bc
	ret z
	djnz RC2
	or 1
	ret

; LANDED: Z = one of the three sectors after RSEC reads (one try each),
; so the heads are on the track. RSEC and IDBUF are left as they were.
LANDED:	ld a,(RSEC)
	ld (SAVSEC),a
	ld b,3
LD1:	ld a,(RSEC)
	inc a
	and 01fh
	ld (RSEC),a
	push bc
	call MKID
	call TRYID
	pop bc
	jr z,LD2
	djnz LD1
	or 1
LD2:	push af
	ld a,(SAVSEC)
	ld (RSEC),a
	call MKID
	pop af
	ret

;-----------------------------------------------------------------------
; Reading
;-----------------------------------------------------------------------
; TRYID: one read of the sector whose header matches IDBUF. A = error bits
; (00 OK, 02 not found, 04 compare, 08 CRC, 40 write fault, 80 not ready
; or not selected, FF no answer), Z = OK. The data is then in the
; controller's buffer. The drive must be selected and ready before and
; after: a read that the drive dropped out of can look fine otherwise.
TRYID:	ld a,004h			; compare buffer, at EAh
	out (CCMD),a
	ld a,0eah
	out (CPTR),a
	ld hl,IDBUF
	ld b,4
TI1:	ld a,(hl)
	out (CDATA),a
	inc hl
	djnz TI1
	call DRVOK
	jr z,TI2
	ld a,080h			; not ready / not selected
	or a
	ret
TI2:	xor a				; read microcode at D7h
	out (CCMD),a
	ld a,0d7h
	out (CPTR),a
	ld a,008h			; START, bank 0
	out (CCMD),a
	ld de,18750			; 150 ms
TI3:	in a,(CCMD)
	rrca
	jr c,TI4
	dec de
	ld a,d
	or e
	jr nz,TI3
	xor a				; no answer: stop
	out (CCMD),a
	ld a,0ffh
	or a
	ret
TI4:	in a,(CCMD)
	and 00eh			; busy (not found), compare, CRC
	ld b,a
	xor a
	out (CCMD),a
	call DRVOK			; still there?
	jr z,TI6
	ld a,080h
	or a
	ret
TI6:	ld a,c
	and 002h			; write fault: clear it, as the ROM does
	jr z,TI5
	xor a
	out (DEXT),a
	ld a,(DEXTV)
	out (DEXT),a
	ld a,b
	or 040h
	ld b,a
TI5:	ld a,b
	or a
	ret

; DRVOK: Z = drive selected and ready (C = the status byte)
DRVOK:	in a,(DSTAT)
	ld c,a
	and 011h
	cp 001h
	ret

; TRYN: TRYID up to A times. Z = OK, else NZ with A = last error
TRYN:	ld (TRIES),a
TN1:	call TRYID
	ret z
	ld (LASTERR),a
	ld hl,TRIES
	dec (hl)
	jr nz,TN1
	ld a,(LASTERR)
	or a
	ret

; TRY2: TRYID until two reads have succeeded, giving up after A failures.
; Z = confirmed. One read that only looks successful can't get through.
TRY2:	ld (TRIES),a
	xor a
	ld (GOOD),a
T21:	call TRYID
	jr nz,T22
	ld hl,GOOD
	inc (hl)
	ld a,(hl)
	cp 2
	jr c,T21
	xor a
	ret
T22:	ld (LASTERR),a
	ld hl,TRIES
	dec (hl)
	jr nz,T21
	ld a,(LASTERR)
	or a
	ret

; READSEC: read RCYL/RHEAD/RSEC (positioned there) into (DEST). Z = OK,
; NZ = failed, A = error bits. 5 tries, then 10 more, with a recalibrate
; before them the first time in a track (RECALD). If the drive goes away
; (80): wait for it, restore, and start the tries again, up to 3 times.
; A sector that fails all 15 gets 2 s and a status check first: on this
; drive the spindle drifts for a moment before the firmware drops READY,
; and sectors read then fail for nothing; then a speed check (the
; controller finds sectors by timing from the index, so a few tenths of a
; percent off speed lose the last sectors of a track) with a wait for the
; speed to come back.
READSEC: ld a,3
	ld (GONES),a
RS9:	call MKID
	ld a,5
	call TRYN
	jr z,RS2
	cp 080h
	jr z,RSG
	ld a,(RECALD)			; first failure in this track: recalibrate
	or a
	jr nz,RS0
	inc a
	ld (RECALD),a
	call RECAL
	call MKID
RS0:	ld a,10				; marginal sectors often read on a later try
	call TRYN
	jr z,RS2
	cp 080h
	jr z,RSG
	ld b,20				; or the spindle is drifting and READY is
RSW:	call DLY100			; about to drop: give it 2 s and look
	djnz RSW
	call DRVOK
	jr nz,RSG
	call SPDGATE			; off speed? say so, wait for it
	call MKID			; still here: a last 5 tries
	ld a,5
	call TRYN
	jr z,RS2
	cp 080h
	jr z,RSG
RS1:	ld a,(LASTERR)
	or a
	ret
RSG:	ld hl,GONES			; not ready or not selected any more
	dec (hl)
	jr z,RS1
	call WAITRDY
	jr nz,RS1
	call RECAL
	jr RS9
RS2:	ld hl,(DEST)
	call HDGETBUF
	xor a
	ret

; WAITRDY: the drive dropped READY or its select. Wait up to 60 s for it
; to be back, and stay back for a second. Z = back.
WAITRDY: ld hl,MSG_WAIT
	call PUTS
	ld bc,600			; tenths of a second
WR1:	ld de,10345			; 58 T per turn: 0.1 s
WR2:	in a,(DSTAT)			; 11
	and 011h			; 7
	cp 001h				; 7
	jr z,WR4			; 7
	dec de				; 6
	ld a,d				; 4
	or e				; 4
	jr nz,WR2			; 12
	call CONCHK
	dec bc
	ld a,b
	or c
	jr nz,WR1
	ld hl,MSG_WAITF
	call PUTS
	or 1
	ret
WR4:	push bc				; back: give it a second, then look again
	ld b,10
WR5:	call DLY100
	djnz WR5
	pop bc
	call DRVOK
	jr nz,WR1
	ld hl,MSG_WAITOK
	call PUTS
	ld hl,0ffffh			; the drive may have recalibrated itself
	ld (CURCYL),hl
	xor a
	ret

; DLY100: 0.1 s
DLY100:	push de
	ld de,23077			; 26 T per turn
DL1:	dec de
	ld a,d
	or e
	jr nz,DL1
	pop de
	ret

; MKID: header bytes for RCYL/RHEAD/RSEC from MAP
MKID:	call ZEROID
	ld ix,MAP
	ld a,(RSEC)
	ld c,a
	ld b,5
	call MKBITS
	ld a,(RHEAD)
	ld c,a
	ld b,2
	call MKBITS
	ld a,(RCYL)
	ld c,a
	ld b,8
	call MKBITS
	ld a,(RCYL+1)
	ld c,a
	ld b,1
MKBITS:	srl c
	call c,APPLY
	inc ix
	inc ix
	djnz MKBITS
	ret
APPLY:	ld a,(ix+0)			; entry: byte, mask (FFh = not in header)
	cp 4
	ret nc
	ld e,a
	ld d,0
	ld hl,IDBUF
	add hl,de
	ld a,(ix+1)
	or (hl)
	ld (hl),a
	ret

ZEROID:	ld hl,IDBUF
	xor a
	ld (hl),a
	inc hl
	ld (hl),a
	inc hl
	ld (hl),a
	inc hl
	ld (hl),a
	ret

;-----------------------------------------------------------------------
; P: probe the header layout
;-----------------------------------------------------------------------
CMD_PROBE:
	call CRLF
	call PROBE
	jp MENU

; NEEDPROBE: probe first if that hasn't been done
NEEDPROBE:
	ld a,(PROBED)
	or a
	ret nz
	call CRLF
	call PROBE
	ret z
	jp MENU

; PROBE: Z = layout found and checked
PROBE:	xor a
	ld (PROBED),a
	ld hl,MSG_PROBE
	call PUTS
	call HDINIT2
	jr z,PB0
	call PUTS
	jp NZRET
PB0:	ld hl,KNOWN			; the layout this drive was found to use
	ld de,MAP
	ld bc,32
	ldir
	ld hl,MSG_KNOWN
	call PUTS
	call CHECK
	jp z,PB9
	ld hl,MSG_KNOWNF
	call PUTS
PB1:	ld hl,MAP			; nothing known yet
	ld b,32
PB2:	ld (hl),0ffh
	inc hl
	djnz PB2
	ld hl,USED
	ld b,4
PB3:	ld (hl),0
	inc hl
	djnz PB3
	ld hl,0
	call SEEKTO
	xor a
	call SELHEAD
	call ZEROID			; C0 H0 S0 = 00 00 00 00
	ld a,4
	call TRY2
	jr z,PB4
	push af
	ld hl,MSG_NOS0
	call PUTS
	pop af
	call PUTHEX
	call CRLF
	jp NZRET
PB4:	ld hl,MSG_S0OK
	call PUTS
	ld ix,MAP			; sector bits, at C0 H0
	xor a
	ld (ALLOWNONE),a
	ld b,5
	ld c,0
PB5:	push bc
	ld a,c
	ld (BITK),a
	call FINDBIT
	pop bc
	inc ix
	inc ix
	inc c
	djnz PB5
	ld a,1				; head bits, at C0 S0
	ld (ALLOWNONE),a
	ld a,1
	call SELHEAD
	xor a
	ld (BITK),a
	call FINDBIT
	inc ix
	inc ix
	ld a,2
	call SELHEAD
	ld a,1
	ld (BITK),a
	call FINDBIT
	inc ix
	inc ix
	xor a
	call SELHEAD
	ld b,9				; cylinder bits, at H0 S0
	ld c,0
	ld hl,1
PB6:	push bc
	push hl
	ld a,c
	ld (BITK),a
	call SEEKTO
	jr z,PB7
	ld hl,MSG_SEEKF
	call PUTS
	pop hl
	pop bc
	jp NZRET
PB7:	call FINDBIT
	pop hl
	pop bc
	add hl,hl
	inc ix
	inc ix
	inc c
	djnz PB6
	call CHECK
	push af
	call PMAP
	pop af
	jr z,PB8
	ld hl,MSG_CHKF
	call PUTS
	jp NZRET
PB9:	call PMAP
PB8:	ld hl,MSG_CHKOK
	call PUTS
	ld a,1
	ld (PROBED),a
	xor a
	ret
NZRET:	or 1
	ret

; CHECK: read C300 H3 S21 and C243 H0 S10 with the layout in MAP; between
; them every address bit is set once, so a layout with any bit wrong
; fails one of them. Z = both read (twice each). Ends at C0 H0.
CHECK:	ld hl,300
	ld a,3
	ld c,21
	call CHK1
	jr nz,CHK9
	ld hl,243
	xor a
	ld c,10
	call CHK1
CHK9:	push af
	ld hl,0
	call SEEKTO
	xor a
	call SELHEAD
	pop af
	ret
CHK1:	ld (RCYL),hl
	ld (RHEAD),a
	ld a,c
	ld (RSEC),a
	call SEEKTO
	ret nz
	ld a,(RHEAD)
	call SELHEAD
	call MKID
	ld a,4
	jp TRY2

; FINDBIT: find the header bit for MAP entry IX (address bit BITK of its
; field) at the current position. ALLOWNONE: the bit may be absent from
; the header (heads, cylinders), tested with an all-zero header first.
FINDBIT: ld a,(ALLOWNONE)
	or a
	jr z,FB1
	call ZEROID
	ld a,2
	call TRY2
	jr nz,FB1
	ld (ix+0),0ffh			; not in the header
	ld (ix+1),000h
	ret
FB1:	ld a,(BITK)			; the bit after the field's previous one
	or a
	jr z,FB3
	ld a,(ix-2)
	cp 4
	jr nc,FB3
	ld e,a
	ld a,(ix-1)
	rlca
	ld d,a
	cp 001h
	jr z,FB2
	call TRYCAND
	ret z
	jr FB3
FB2:	inc e				; carried into the next byte, either way
	call TRYCAND
	ret z
	dec e
	dec e
	call TRYCAND
	ret z
FB3:	ld d,001h			; then everything: bit 0 of each byte first
FB4:	ld e,0
FB5:	call TRYCAND
	ret z
	inc e
	ld a,e
	cp 4
	jr c,FB5
	sla d
	jr nc,FB4
	ld (ix+0),0ffh			; not found
	ld (ix+1),0feh
	ret

; TRYCAND: try header byte E, mask D. Z = found (MAP entry and USED set)
TRYCAND: ld a,e
	cp 4
	jr nc,TC9
	ld hl,USED
	ld b,0
	ld c,e
	add hl,bc
	ld a,(hl)
	and d
	jr nz,TC9
	push de
	call ZEROID
	pop de
	ld hl,IDBUF
	ld b,0
	ld c,e
	add hl,bc
	ld (hl),d
	push de
	ld a,2
	call TRY2
	pop de
	ret nz
	ld (ix+0),e
	ld (ix+1),d
	ld hl,USED
	ld b,0
	ld c,e
	add hl,bc
	ld a,(hl)
	or d
	ld (hl),a
	xor a
	ret
TC9:	or 1
	ret

; PMAP: print the layout, byte.bit per address bit
PMAP:	ld hl,MSG_MAP
	call PUTS
	ld ix,MAP
	ld hl,MSG_MS
	call PUTS
	ld b,5
	call PMAPN
	ld hl,MSG_MH
	call PUTS
	ld b,2
	call PMAPN
	ld hl,MSG_MC
	call PUTS
	ld b,9
	call PMAPN
	jp CRLF
PMAPN:	push bc
	ld a,' '
	call CONOUT
	ld a,(ix+0)
	cp 4
	jr c,PM2
	ld a,(ix+1)
	cp 0feh
	ld a,'?'
	jr z,PM1
	ld a,'-'
PM1:	call CONOUT
	call CONOUT
	call CONOUT
	jr PM4
PM2:	add a,'0'
	call CONOUT
	ld a,'.'
	call CONOUT
	ld a,(ix+1)
	ld c,'0'-1
PM3:	inc c
	rrca
	jr nc,PM3
	ld a,c
	call CONOUT
PM4:	inc ix
	inc ix
	pop bc
	djnz PMAPN
	ret

;-----------------------------------------------------------------------
; R: read one sector and dump it
;-----------------------------------------------------------------------
CMD_READ:
	call NEEDPROBE
	call ASKCHS
	call CRLF
	ld hl,(RCYL)
	call SEEKTO
	jr z,CR1
	ld hl,MSG_SEEKF
	call PUTS
	jp MENU
CR1:	ld a,(RHEAD)
	call SELHEAD
	xor a
	ld (RECALD),a
	ld hl,BLK
	ld (DEST),hl
	call READSEC
	jr z,CR2
	push af
	ld hl,MSG_RDF
	call PUTS
	pop af
	call PUTHEX
	call CRLF
	jp MENU
CR2:	ld hl,BLK			; 16 lines: offset, 16 bytes, text
	ld c,0
CR3:	ld a,c
	call PUTHEX
	ld a,':'
	call CONOUT
	push hl
	ld b,16
CR4:	ld a,' '
	call CONOUT
	ld a,(hl)
	call PUTHEX
	inc hl
	djnz CR4
	pop hl
	ld a,' '
	call CONOUT
	call CONOUT
	ld b,16
CR5:	ld a,(hl)
	and 07fh
	cp 020h
	jr c,CR6
	cp 07fh
	jr c,CR7
CR6:	ld a,'.'
CR7:	call CONOUT
	inc hl
	djnz CR5
	call CRLF
	ld a,c
	add a,010h
	ld c,a
	jr nz,CR3
	jp MENU

; ASKCHS: cylinder, head and sector from the console into RCYL/RHEAD/RSEC
ASKCHS:	ld hl,MSG_ASKC
	call PUTS
	call GETNUM
	ld de,MAXCYL+1
	call CHKMAX
	ld (RCYL),hl
	ld hl,MSG_ASKH
	call PUTS
	call GETNUM
	ld de,4
	call CHKMAX
	ld a,l
	ld (RHEAD),a
	ld hl,MSG_ASKS
	call PUTS
	call GETNUM
	ld de,32
	call CHKMAX
	ld a,l
	ld (RSEC),a
	ret

; CHKMAX: HL must be below DE, else back to the menu
CHKMAX:	push hl
	or a
	sbc hl,de
	pop hl
	ret c
	ld hl,MSG_RANGE
	call PUTS
	jp MENU

;-----------------------------------------------------------------------
; F: hunt for sectors behind damaged IDs
;-----------------------------------------------------------------------
; A sector that fails with "not found" has an ID field the controller no
; longer matches. Its data field may be fine. For each sector in the bad
; list of the last image (or one typed in), the hunt reads with the
; expected ID, then with every single bit of it flipped, then with every
; value of each byte: one read per candidate, skipping IDs that belong to
; other sectors of the same track. A sector that answers is read again to
; be sure and kept as a 384-byte record (128 bytes of text with C/H/S, the
; ID it answered to and OK or CRC, then the 256 data bytes). The records
; go to the PC by XMODEM at the end, for hdfix.py to put into the image.
CMD_HUNT:
	call NEEDPROBE
	ld hl,(BADCNT)
	ld a,h
	or l
	jr nz,HU1
	ld hl,MSG_HU0			; no list from this run: one left at BADL
	call PUTS			; by the build that ran before a reload?
	call GETNUM
	jr z,HU0
	ld de,BADMAX+1
	call CHKMAX
	ld a,l
	ld (HUNTN),a
	ld ix,BADL			; check those entries before trusting them
	ld b,l
HUC:	ld e,(ix+0)
	ld d,(ix+1)
	ld hl,MAXCYL
	or a
	sbc hl,de
	jr c,HUCBAD
	ld a,(ix+2)
	cp 4
	jr nc,HUCBAD
	ld a,(ix+3)
	cp 32
	jr nc,HUCBAD
	ld de,5
	add ix,de
	djnz HUC
	ld ix,BADL
	jp HU3
HUCBAD:	ld hl,MSG_HUCB
	call PUTS
	jp MENU
HU1:	ld hl,MSG_HU1
	call PUTS
	ld hl,(BADCNT)
	call PDEC
	ld hl,MSG_HU2
	call PUTS
	call CONIN
	and 0dfh
	cp 'Y'
	jr z,HU2
HU0:	call ASKCHS			; one sector, typed in
	ld ix,TMPENT
	ld hl,(RCYL)
	ld (ix+0),l
	ld (ix+1),h
	ld a,(RHEAD)
	ld (ix+2),a
	ld a,(RSEC)
	ld (ix+3),a
	ld a,1
	ld (HUNTN),a
	jr HU3
HU2:	ld ix,BADL			; the list (at most BADMAX entries)
	ld hl,(BADCNT)
	ld de,BADMAX+1
	or a
	sbc hl,de
	ld hl,(BADCNT)
	jr c,HU2A
	ld hl,BADMAX
HU2A:	ld a,l
	ld (HUNTN),a
HU3:	ld hl,FIXBUF
	ld (FIXPTR),hl
	xor a
	ld (FIXCNT),a
HU4:	ld l,(ix+0)			; each listed sector
	ld h,(ix+1)
	ld (RCYL),hl
	ld a,(ix+2)
	ld (RHEAD),a
	ld a,(ix+3)
	ld (RSEC),a
	push ix
	call HUNT1
	pop ix
	ld de,5
	add ix,de
	ld hl,HUNTN
	dec (hl)
	jr nz,HU4
	ld hl,MSG_HUR1			; summary
	call PUTS
	ld a,(FIXCNT)
	ld l,a
	ld h,0
	call PDEC
	ld hl,MSG_HUR2
	call PUTS
	ld a,(FIXCNT)
	or a
	jp z,MENU
	ld hl,MSG_HUR3
	call PUTS
	call AUXRST
	ld a,1
	ld (XFER),a
	ld (BLKNUM),a
	call XSTART
	jp nz,XFAIL
	ld hl,FIXBUF
	ld a,(FIXCNT)
	ld b,a
HU5:	push bc				; each record: 3 blocks of 128
	ld b,3
HU6:	push bc
	push hl
	ld bc,128
	ld a,SOH
	call SENDPKT
	pop hl
	pop bc
	jp nz,XFAIL
	ld de,128
	add hl,de
	djnz HU6
	pop bc
	djnz HU5
	call XEOT
	jp nz,XFAIL
	xor a
	ld (XFER),a
	ld hl,MSG_HUSENT
	call PUTS
	jp MENU

; HUNT1: hunt for RCYL/RHEAD/RSEC. Z = found and stored.
HUNT1:	ld hl,MSG_HC
	call PUTS
	ld hl,(RCYL)
	call PDEC
	ld hl,MSG_BLH
	call PUTS
	ld a,(RHEAD)
	add a,'0'
	call CONOUT
	ld hl,MSG_BLS
	call PUTS
	ld a,(RSEC)
	ld l,a
	ld h,0
	call PDEC
	ld hl,MSG_HCOL
	call PUTS
	ld hl,(RCYL)
	call SEEKTO
	jr z,HN1
	call HDINIT2
	ld hl,(RCYL)
	call SEEKTO
	jr z,HN1
	ld hl,MSG_SEEKF
	call PUTS
	or 1
	ret
HN1:	ld a,(RHEAD)
	call SELHEAD
	call MKID
	ld hl,IDBUF
	ld de,EXPID
	ld bc,4
	ldir
	xor a
	ld (HNCNT),a
	ld a,3
	call TRYN
	jr nz,HN2
	ld hl,MSG_HNOW
	call PUTS
	ld hl,BLK
	call HDGETBUF
	xor a
	jp STOREFIX
HN2:	ld b,32				; every single bit flipped
	ld c,0
HN3:	push bc
	call EXP2ID
	pop bc
	push bc
	ld a,c
	srl a
	srl a
	srl a
	ld e,a				; byte 0-3
	ld d,0
	ld hl,IDBUF
	add hl,de
	ld a,c
	and 7
	inc a
	ld b,a
	xor a
	scf
HN3A:	rla				; 1 << bit
	djnz HN3A
	xor (hl)
	ld (hl),a
	call SECSAME			; not a sector-field bit
	jr nz,HN3B
	call HTRY
	pop bc
	ret z
	jr HN3C
HN3B:	pop bc
HN3C:	inc c
	djnz HN3
	ld c,3				; every value of each byte, byte 3 first
HN4:	ld e,0
HN5:	push bc
	push de
	call EXP2ID
	pop de
	pop bc
	ld hl,IDBUF
	push de
	ld e,c
	ld d,0
	add hl,de
	pop de
	ld a,(hl)
	cp e
	jr z,HN6			; the expected value: tried already
	ld (hl),e
	push bc
	push de
	ld e,c
	call SECSAME			; the sector field must stay as it is
	jr nz,HN5B
	call HTRY
HN5B:	pop de
	pop bc
	ret z
HN6:	inc e
	jr nz,HN5
	dec c
	jp p,HN4
	ld hl,MSG_HNONE
	call PUTS
	or 1
	ret

EXP2ID:	ld hl,EXPID
	ld de,IDBUF
	ld bc,4
	ldir
	ret

; HTRY: one read with the candidate ID in IDBUF, unless it is another
; sector's on this track. Z = it answered (and the record is stored).
HTRY:	ld hl,IDBUF
	ld de,CAND
	ld bc,4
	ldir
	ld a,(RSEC)
	ld (SAVSEC),a
	ld b,32
	ld c,0
HT1:	push bc
	ld a,c
	ld (RSEC),a
	call MKID
	ld hl,IDBUF
	ld de,CAND
	ld b,4
HT2:	ld a,(de)
	cp (hl)
	jr nz,HT3
	inc hl
	inc de
	djnz HT2
	pop bc				; equal: a real sector of this track
	call HTREST
	or 1
	ret
HT3:	pop bc
	inc c
	djnz HT1
	call HTREST
	ld hl,HNCNT			; a dot every 32 candidates
	inc (hl)
	ld a,(hl)
	and 01fh
	jr nz,HT4
	ld a,'.'
	call CONOUT
HT4:	call CONCHK
	call TRYID
	jr z,HT5
	cp 008h
	jr z,HT6
	or 1
	ret
HT5:	call TRYID			; once more, to be sure
	ret nz
	ld hl,BLK
	call HDGETBUF
	call NOTOURS			; another sector's data, or a format
	ret nz				; feature? then not ours
	xor a
	jp STOREFIX
HT6:	ld hl,BLK			; CRC error: keep this data, try for a clean read
	call HDGETBUF
	ld a,10
	call TRYN
	jr nz,HT7
	ld hl,BLK
	call HDGETBUF
	call NOTOURS
	ret nz
	xor a
	jp STOREFIX
HT7:	call NOTOURS
	ret nz
	ld a,1
	jp STOREFIX

; SECSAME: Z = header byte E of IDBUF has the same sector-field bits as
; EXPID (MAP entries 0-4 give the sector bits: byte, mask)
SECSAME: ld ix,MAP
	ld b,5
SS1:	ld a,(ix+0)
	cp e
	jr nz,SS2
	ld d,0
	ld hl,IDBUF
	add hl,de
	ld a,(hl)
	ld hl,EXPID
	add hl,de
	xor (hl)
	and (ix+1)
	jr nz,SS9			; this sector bit differs
SS2:	inc ix
	inc ix
	djnz SS1
	xor a
	ret
SS9:	or 1
	ret

; NOTOURS: the candidate in IDBUF answered with the data now in BLK.
; NZ = it isn't our sector: the data is identical to another sector of
; the track (read now, into BLK+256), or the same change applied to a
; good sector's ID answers too (a masked bit or a spare, not damage).
; Leaves IDBUF = the candidate, RSEC as it was. Prints why.
NOTOURS: ld hl,IDBUF
	ld de,CAND
	ld bc,4
	ldir
	ld a,(RSEC)
	ld (SAVSEC),a
	ld a,0ffh
	ld (GOODSEC),a
	ld c,0
NO1:	ld a,(SAVSEC)
	cp c
	jr z,NO4
	ld a,c
	ld (RSEC),a
	push bc
	call MKID
	call TRYID
	jr nz,NO3
	ld a,(GOODSEC)			; remember one that reads
	inc a
	jr nz,NO2
	ld a,c
	ld (GOODSEC),a
NO2:	ld hl,BLK+256
	call HDGETBUF
	ld hl,BLK
	ld de,BLK+256
	ld bc,256
NO2A:	ld a,(de)
	cp (hl)
	jr nz,NO3
	inc hl
	inc de
	dec bc
	ld a,b
	or c
	jr nz,NO2A
	pop bc				; identical: sector C's data
	ld hl,MSG_HTWIN
	call PUTS
	ld a,c
	ld l,a
	ld h,0
	call PDEC
	ld a,')'
	call CONOUT
	jr NO8
NO3:	pop bc
NO4:	inc c
	ld a,c
	cp 32
	jr c,NO1
	ld a,(GOODSEC)			; the same change on a good sector's ID
	cp 0ffh
	jr z,NO7
	ld (RSEC),a
	call MKID
	ld hl,IDBUF			; IDBUF(good) ^= CAND ^ EXPID, byte by byte
	ld de,CAND
	push hl
	ld hl,EXPID
	ld (XTMP),hl
	pop hl
	ld b,4
NO6:	ld a,(de)
	push hl
	ld hl,(XTMP)
	xor (hl)
	inc hl
	ld (XTMP),hl
	pop hl
	xor (hl)
	ld (hl),a
	inc hl
	inc de
	djnz NO6
	call TRYID
	jr nz,NO7
	ld hl,MSG_HFEAT
	call PUTS
	jr NO8
NO7:	call HTREST			; ours, as far as can be told
	xor a
	ret
NO8:	call HTREST
	or 1
	ret

HTREST:	ld a,(SAVSEC)			; RSEC and IDBUF back to the candidate
	ld (RSEC),a
	ld hl,CAND
	ld de,IDBUF
	ld bc,4
	ldir
	ret

; STOREFIX: keep the sector that answered to IDBUF, its data in BLK: A = 0
; (good read) or 1 (read with a CRC error). Z on return.
STOREFIX: ld (FIXFLG),a
	ld hl,(FIXPTR)
	push hl
	ld (hl),0			; 128 bytes of text, zero filled
	ld d,h
	ld e,l
	inc de
	ld bc,127
	ldir
	pop de
	push de
	ld hl,FIXTXT
	ld bc,FIXTXTL
	ldir
	pop de
	push de
	push de
	ld hl,7				; "HDFIX C000 H0 S00 ID 00 00 00 00 OK "
	add hl,de
	ex de,hl
	ld hl,(RCYL)
	call DEC3			; cylinder at 7
	pop de
	ld hl,12
	add hl,de
	ld a,(RHEAD)
	add a,'0'
	ld (hl),a			; head at 12
	inc hl
	inc hl
	push hl
	ex de,hl
	ld a,(RSEC)
	ld l,a
	ld h,0
	call DEC3			; sector: 3 digits from 14, then the S back
	pop hl
	ld (hl),'S'
	ld de,7
	add hl,de			; the ID at 21
	ex de,hl
	ld hl,IDBUF
	ld b,4
SF1:	ld a,(hl)
	call HEXDE
	inc de
	inc hl
	djnz SF1
	ld a,(FIXFLG)
	or a
	jr z,SF2
	ld hl,MSG_CRC3			; "CRC" over the "OK "
	ld bc,3
	ldir
SF2:	pop de
	ld hl,128
	add hl,de
	ex de,hl
	ld hl,BLK			; the data
	ld bc,256
	ldir
	ld hl,(FIXPTR)
	ld de,384
	add hl,de
	ld (FIXPTR),hl
	ld hl,FIXCNT
	inc (hl)
	ld hl,MSG_HFOUND		; say so
	call PUTS
	ld hl,IDBUF
	ld b,4
SF5:	ld a,(hl)
	call PUTHEX
	ld a,' '
	call CONOUT
	inc hl
	djnz SF5
	ld a,(FIXFLG)
	or a
	jr z,SF6
	ld hl,MSG_HCRC
	call PUTS
SF6:	xor a
	ret

; HEXDE: A as two hex digits at DE (DE advanced past them)
HEXDE:	push af
	rrca
	rrca
	rrca
	rrca
	call HEX1
	pop af
HEX1:	and 00fh
	add a,090h
	daa
	adc a,040h
	daa
	ld (de),a
	inc de
	ret

;-----------------------------------------------------------------------
; I: image cylinders to the PC
;-----------------------------------------------------------------------
CMD_IMAGE:
	call NEEDPROBE
	ld hl,MSG_ASKF
	call PUTS
	call GETNUM
	ld de,MAXCYL+1
	call CHKMAX
	ld (FIRST),hl
	ld hl,MSG_ASKL
	call PUTS
	call GETNUM
	jr nz,CI1
	ld hl,MAXCYL			; default: to the end
CI1:	ld de,MAXCYL+1
	call CHKMAX
	ld (LAST),hl
	ld de,(FIRST)
	or a
	sbc hl,de
	jr nc,CI2
	ld hl,MSG_RANGE
	call PUTS
	jp MENU
CI2:	inc hl				; cylinders x 32K
	ld (NCYLS),hl
	ld hl,MSG_IM1
	call PUTS
	ld hl,(NCYLS)
	call PDEC
	ld hl,MSG_IM2
	call PUTS
	ld hl,(NCYLS)
	add hl,hl
	add hl,hl
	add hl,hl
	add hl,hl
	add hl,hl
	call PDEC
	ld hl,MSG_IM3
	call PUTS
	call AUXRST
	ld a,1
	ld (XFER),a			; ^C now cancels the PC's side too
	call XSTART			; wait for the PC: 'C' or NAK
	jp nz,XFAIL
	ld a,1
	ld (BLKNUM),a
	ld hl,0
	ld (BADCNT),hl
	ld hl,BADL
	ld (BADPTR),hl
	ld hl,(FIRST)
	ld (RCYL),hl
IM1:	ld hl,(RCYL)			; each cylinder
	call SEEKTO
	jr z,IM2
	call HDINIT2			; seek failed: restore and try again
	ld hl,(RCYL)
	call SEEKTO
IM2:	xor a
	ld (RHEAD),a
IM3:	ld a,(RHEAD)			; each head
	call SELHEAD
	call SPDGATE			; not while the spindle is off speed
	xor a
	ld (RECALD),a
	ld (RSEC),a
IM4:	ld hl,BLK			; each 1K block: 4 sectors
	ld (DEST),hl
	ld b,4
IM5:	push bc
	call READSEC
	jr z,IM6
	cp 080h				; the drive stayed away: stop here
	jp z,IMGONE
	call BADSEC
IM6:	ld hl,(DEST)
	ld de,256
	add hl,de
	ld (DEST),hl
	ld hl,RSEC
	inc (hl)
	pop bc
	djnz IM5
	ld hl,BLK
	call XSEND1K
	jp nz,XFAIL
	call CONCHK
	ld a,(RSEC)
	cp 32
	jr c,IM4
	call PROGRESS
	ld hl,RHEAD
	inc (hl)
	ld a,(hl)
	cp 4
	jr c,IM3
	ld hl,(RCYL)
	inc hl
	ld (RCYL),hl
	ld de,(LAST)
	ex de,hl
	or a
	sbc hl,de			; LAST - next: carry when past the end
	jr nc,IM1
	call XEOT
	jp nz,XFAIL
	xor a
	ld (XFER),a
	ld hl,MSG_DONE
	call PUTS
	call BADLIST
	jp MENU

; IMGONE: the drive didn't come back. Say where the image stops and how
; much of the PC's file is whole cylinders, then cancel the transfer.
IMGONE:	ld hl,MSG_GONE1
	call PUTS
	ld hl,(RCYL)
	call PDEC
	ld hl,MSG_GONE2
	call PUTS
	ld hl,(RCYL)			; (cylinders done) x 32K
	ld de,(FIRST)
	or a
	sbc hl,de
	add hl,hl
	add hl,hl
	add hl,hl
	add hl,hl
	add hl,hl
	call PDEC
	ld a,'K'
	call CONOUT
	ld hl,MSG_GONE3
	ld (FAILMSG),hl
	jp XFAIL

; PROGRESS: \rCyl ccc head h  bad n
PROGRESS:
	ld hl,MSG_PCYL
	call PUTS
	ld hl,(RCYL)
	call PDEC
	ld hl,MSG_PHD
	call PUTS
	ld a,(RHEAD)
	add a,'0'
	call CONOUT
	ld hl,MSG_PBAD
	call PUTS
	ld hl,(BADCNT)
	call PDEC
	ld a,' '
	call CONOUT
	jp CONOUT

; BADSEC: A = error bits. Count it, list it, fill the sector with text.
BADSEC:	ld (LASTERR),a
	ld hl,(BADCNT)
	inc hl
	ld (BADCNT),hl
	ld de,BADMAX+1
	or a
	sbc hl,de
	jr nc,BS1			; list full: just count
	ld hl,(BADPTR)
	ld de,(RCYL)
	ld (hl),e
	inc hl
	ld (hl),d
	inc hl
	ld a,(RHEAD)
	ld (hl),a
	inc hl
	ld a,(RSEC)
	ld (hl),a
	inc hl
	ld a,(LASTERR)
	ld (hl),a
	inc hl
	ld (BADPTR),hl
BS1:	ld hl,BADTXT			; 32-byte line with C/H/S filled in
	ld de,LINE
	ld bc,32
	ldir
	ld hl,(RCYL)
	ld de,LINE+15
	call DEC3
	ld a,(RHEAD)
	add a,'0'
	ld (LINE+20),a
	ld a,(RSEC)
	ld l,a
	ld h,0
	ld de,LINE+22
	call DEC3			; 3 digits from 22: overwrite the 'S'
	ld a,'S'
	ld (LINE+22),a
	ld de,(DEST)			; 8 copies
	ld b,8
BS2:	push bc
	ld hl,LINE
	ld bc,32
	ldir
	pop bc
	djnz BS2
	ret

; BADLIST: count and list of bad sectors
BADLIST: ld hl,MSG_BAD1
	call PUTS
	ld hl,(BADCNT)
	call PDEC
	call CRLF
	ld hl,(BADCNT)
	ld a,h
	or l
	ret z
	ld de,BADMAX+1			; entries listed: min(count, BADMAX)
	or a
	sbc hl,de
	ld hl,(BADCNT)
	jr c,BL1
	ld hl,BADMAX
BL1:	ld b,l
	ld ix,BADL
	ld c,0
BL2:	push bc
	ld a,'C'
	call CONOUT
	ld l,(ix+0)
	ld h,(ix+1)
	call PDEC
	ld hl,MSG_BLH
	call PUTS
	ld a,(ix+2)
	add a,'0'
	call CONOUT
	ld hl,MSG_BLS
	call PUTS
	ld l,(ix+3)
	ld h,0
	call PDEC
	ld hl,MSG_BLE
	call PUTS
	ld a,(ix+4)
	call PUTHEX
	ld de,5
	add ix,de
	pop bc
	inc c
	ld a,c
	and 003h
	jr nz,BL3
	call CRLF
	jr BL4
BL3:	ld a,' '
	call CONOUT
	call CONOUT
BL4:	djnz BL2
	call CRLF
	ld hl,MSG_ERRS
	jp PUTS

;-----------------------------------------------------------------------
; XMODEM sender on port B
;-----------------------------------------------------------------------
AUXRST:	xor a				; 8251 reset, 8N1 x16, RTS DTR RxE TxEN
	call AUXW
	call AUXW
	call AUXW
	ld a,040h
	call AUXW
	ld a,04eh
	call AUXW
	ld a,037h
AUXW:	out (AUXS),a
	ld b,20
AW1:	djnz AW1
	ret

; XSTART: wait up to 90 s for 'C' (CRC, 1K blocks) or NAK (checksum,
; 128-byte blocks). Z = go.
XSTART:	ld a,30
	ld (TRIES),a
XS1:	ld b,30
	call RXTO
	jr c,XS3
	cp 'C'
	ld c,1
	jr z,XS2
	cp NAK
	ld c,0
	jr z,XS2
	cp CAN
	jr nz,XS1
	ld b,10
	call RXTO
	jr c,XS1
	cp CAN
	jr nz,XS1
	ld hl,MSG_PCCAN
	jr XS4
XS2:	ld a,c
	ld (CRCM),a
	xor a
	ret
XS3:	ld hl,TRIES
	dec (hl)
	jr nz,XS1
	ld hl,MSG_NORCV
XS4:	ld (FAILMSG),hl
	or 1
	ret

; XSEND1K: the 1K block at HL, as one STX block (CRC) or 8 SOH blocks
XSEND1K: ld a,(CRCM)
	or a
	jr z,XK1
	ld bc,1024
	ld a,STX
	jp SENDPKT
XK1:	ld b,8
XK2:	push bc
	push hl
	ld bc,128
	ld a,SOH
	call SENDPKT
	pop hl
	pop bc
	ret nz
	ld de,128
	add hl,de
	djnz XK2
	xor a
	ret

; SENDPKT: block of BC bytes at HL, type A. Z = acknowledged.
SENDPKT: ld (PKTPTR),hl
	ld (PKTLEN),bc
	ld (PKTTYPE),a
	ld a,10
	ld (ERRS),a
SP1:	call FLUSHRX			; stray NAKs from waiting while reading
	ld a,(PKTTYPE)
	call TXB
	ld a,(BLKNUM)
	call TXB
	cpl
	call TXB
	ld hl,(PKTPTR)
	ld bc,(PKTLEN)
	ld de,0				; CRC (D high, E low) or checksum (E)
SP2:	ld a,(hl)
	call TXB
	push hl
	ld l,a
	ld a,(CRCM)
	or a
	jr z,SP3
	ld a,l				; crc = (crc << 8) ^ T[(crc >> 8) ^ byte]
	xor d
	ld l,a
	ld h,CRCPG
	ld a,(hl)
	xor e
	ld d,a
	inc h
	ld e,(hl)
	jr SP4
SP3:	ld a,l
	add a,e
	ld e,a
SP4:	pop hl
	inc hl
	dec bc
	ld a,b
	or c
	jr nz,SP2
	ld a,(CRCM)
	or a
	jr z,SP5
	ld a,d
	call TXB
SP5:	ld a,e
	call TXB
SP6:	ld b,100			; 10 s for the answer
	call RXTO
	jr c,SP8
	cp ACK
	jr z,SP9
	cp NAK
	jr z,SP8
	cp CAN
	jr nz,SP6			; 'C' or noise: keep waiting
	ld b,10
	call RXTO
	jr c,SP6
	cp CAN
	jr nz,SP6
	ld hl,MSG_PCCAN
	ld (FAILMSG),hl
	or 1
	ret
SP8:	ld hl,ERRS			; NAK or no answer: send it again
	dec (hl)
	jr nz,SP1
	ld hl,MSG_XERR
	ld (FAILMSG),hl
	or 1
	ret
SP9:	ld hl,BLKNUM
	inc (hl)
	xor a
	ret

; XEOT: end of transfer. Z = acknowledged.
XEOT:	ld a,10
	ld (ERRS),a
XE1:	call FLUSHRX
	ld a,EOT
	call TXB
XE2:	ld b,100
	call RXTO
	jr c,XE3
	cp ACK
	ret z
	cp NAK
	jr nz,XE2
XE3:	ld hl,ERRS
	dec (hl)
	jr nz,XE1
	ld hl,MSG_XERR
	ld (FAILMSG),hl
	or 1
	ret

; XFAIL: transfer stopped (FAILMSG says why). Cancel the PC's side.
XFAIL:	ld sp,STACK
	xor a
	ld (XFER),a
	ld b,5
XF1:	ld a,CAN
	call TXB
	djnz XF1
	call CRLF
	ld hl,(FAILMSG)
	call PUTS
	call CRLF
	call BADLIST
	jp MENU

; CONCHK: ^C or ESC on the console stops the transfer (or, outside one,
; whatever is waiting on the drive)
CONCHK:	in a,(CONS_P)
	and 002h
	ret z
	in a,(COND)
	and 07fh
	cp 003h
	jr z,CC1
	cp 01bh
	ret nz
CC1:	ld a,(XFER)
	or a
	jr z,CC2
	ld hl,MSG_USER
	ld (FAILMSG),hl
	jp XFAIL
CC2:	ld sp,STACK
	call CRLF
	ld hl,MSG_USER
	call PUTS
	jp MENU

; FLUSHRX: drop whatever port B has received, clear its error flags
FLUSHRX: in a,(AUXS)
	and 002h
	jr z,FR1
	in a,(AUXD)
	jr FLUSHRX
FR1:	ld a,037h
	out (AUXS),a
	ret

; RXTO: byte from port B -> A, carry clear; carry set after B tenths of a
; second. Keeps C, DE, HL. Checks the console during silences.
RXTO:	push de
RT1:	ld de,T100
RT2:	in a,(AUXS)			; 11
	and 002h			; 7
	jr nz,RT3			; 7
	dec de				; 6
	ld a,d				; 4
	or e				; 4
	jr nz,RT2			; 12 = 51 T
	call CONCHK
	djnz RT1
	pop de
	scf
	ret
RT3:	in a,(AUXD)
	pop de
	or a
	ret

; TXB: A -> port B (keeps all registers). Gives up after about 0.5 s
; (the 8251 only sends while CTS is asserted).
TXB:	push de
	push af
	ld de,0
TX1:	in a,(AUXS)
	rrca
	jr c,TX2
	dec de
	ld a,d
	or e
	jr nz,TX1
	pop af
	pop de
	ld hl,MSG_NOCTS
	ld (FAILMSG),hl
	ld sp,STACK			; can't even send CANs: straight out
	call CRLF
	ld hl,MSG_NOCTS
	call PUTS
	jp MENU
TX2:	pop af
	out (AUXD),a
	pop de
	ret

; CRC-16/XMODEM table: T[i] = i << 8 shifted through 1021h 8 times
CRCINIT: ld c,0
CI3:	ld h,c
	ld l,0
	ld b,8
CI4:	add hl,hl
	jr nc,CI5
	ld a,h
	xor 010h
	ld h,a
	ld a,l
	xor 021h
	ld l,a
CI5:	djnz CI4
	ld d,CRCPG
	ld e,c
	ld a,h
	ld (de),a
	inc d
	ld a,l
	ld (de),a
	inc c
	jr nz,CI3
	ret

;-----------------------------------------------------------------------
; Console helpers
;-----------------------------------------------------------------------
CRLF:	ld hl,MSG_CRLF
	jp PUTS

; GETNUM: decimal number from the console -> HL. Z = nothing typed (HL 0).
; ESC or ^C: back to the menu.
GETNUM:	ld c,0
GN1:	call CONIN
	cp 00dh
	jr z,GN4
	cp 01bh
	jp z,MENU
	cp 003h
	jp z,MENU
	cp 008h
	jr z,GN3
	cp 07fh
	jr z,GN3
	cp '0'
	jr c,GN1
	cp '9'+1
	jr nc,GN1
	ld b,a
	ld a,c
	cp 4
	jr nc,GN1
	ld a,b
	call CONOUT
	ld hl,NUMBUF
	ld e,c
	ld d,0
	add hl,de
	sub '0'
	ld (hl),a
	inc c
	jr GN1
GN3:	ld a,c				; backspace
	or a
	jr z,GN1
	dec c
	ld a,008h
	call CONOUT
	ld a,' '
	call CONOUT
	ld a,008h
	call CONOUT
	jr GN1
GN4:	ld hl,0
	ld a,c
	or a
	ret z
	ld b,c
	ld de,NUMBUF
GN5:	push bc
	ld b,h				; HL = HL * 10 + digit
	ld c,l
	add hl,hl
	add hl,hl
	add hl,bc
	add hl,hl
	ld a,(de)
	ld c,a
	ld b,0
	add hl,bc
	inc de
	pop bc
	djnz GN5
	or 1				; NZ: something typed (A is a digit)
	ld a,1
	or a
	ret

; PDEC: HL in decimal
PDEC:	push bc
	push de
	push hl
	ld b,0
	ld de,-10000
	call PD1
	ld de,-1000
	call PD1
	ld de,-100
	call PD1
	ld de,-10
	call PD1
	ld a,l
	add a,'0'
	call CONOUT
	pop hl
	pop de
	pop bc
	ret
PD1:	ld a,'0'-1
PD2:	inc a
	add hl,de
	jr c,PD2
	sbc hl,de
	cp '0'
	jr nz,PD3
	inc b
	dec b
	ret z
PD3:	ld b,1
	jp CONOUT

; DEC3: HL (0-999) as 3 digits at DE
DEC3:	push de
	ld de,-100
	call DC1
	pop de
	ld (de),a
	inc de
	push de
	ld de,-10
	call DC1
	pop de
	ld (de),a
	inc de
	ld a,l
	add a,'0'
	ld (de),a
	ret
DC1:	ld a,'0'-1
DC2:	inc a
	add hl,de
	jr c,DC2
	sbc hl,de
	ret

;-----------------------------------------------------------------------
MSG_HELP:
	defb 0dh,0ah,"HDIMAGE 1.0  MiniScribe -> PC through the XCOMP ST/S. Reads only."
	defb 0dh,0ah," P  find the sector header layout (also a quick read test)"
	defb 0dh,0ah," R  read one sector and show it"
	defb 0dh,0ah," I  image cylinders to the PC: XMODEM on port B"
	defb 0dh,0ah," F  hunt the bad sectors behind damaged IDs; fix file to the PC"
	defb 0dh,0ah," T  drive tests: spindle speed, seeks with verification"
	defb 0dh,0ah," S  drive status   Z  restore   K  park the heads   Q  quit to MCPMON"
	defb 0dh,0ah,0
MSG_PROMPT:	defb 0dh,0ah,"HDIMAGE> ",0
MSG_CRLF:	defb 0dh,0ah,0
MSG_READY:	defb "Drive ready, heads at cylinder 0",0dh,0ah,0
MSG_ST:		defb "Drive status ",0
MSG_SEL:	defb " selected",0
MSG_RDY:	defb " ready",0
MSG_TK0:	defb " track-0",0
MSG_FLT:	defb " WRITE-FAULT",0
MSG_PROBE:	defb "Probing the sector header layout...",0dh,0ah,0
MSG_KNOWN:	defb "Trying the known layout (cyl lo, cyl hi, head, sector)...",0dh,0ah,0
MSG_KNOWNF:	defb "It doesn't read here. Searching...",0dh,0ah,0
MSG_NOS0:	defb "Can't read cylinder 0 head 0 sector 0, error ",0
MSG_S0OK:	defb "C0 H0 S0 reads (header 00 00 00 00)",0dh,0ah,0
MSG_SEEKF:	defb "Seek failed",0dh,0ah,0
MSG_MAP:	defb "Header byte.bit for each address bit (-- not in the header, ?? not found):",0dh,0ah,0
MSG_MS:		defb " sector 1-16:",0
MSG_MH:		defb 0dh,0ah," head 1-2:",0
MSG_MC:		defb 0dh,0ah," cylinder 1-256:",0
MSG_CHKOK:	defb "Check: C300 H3 S21 and C243 H0 S10 read. Layout OK.",0dh,0ah,0
MSG_CHKF:	defb "Check reads of C300 H3 S21 / C243 H0 S10 FAILED: layout not trusted.",0dh,0ah,0
MSG_WAIT:	defb 0dh,0ah,"Drive not ready or not selected: waiting up to 60 s for it (^C stops)... ",0
MSG_WAITOK:	defb "back.",0dh,0ah,0
MSG_WAITF:	defb "no.",0dh,0ah,0
MSG_GONE1:	defb 0dh,0ah,"The drive didn't come back: image stopped at cylinder ",0
MSG_GONE2:	defb ". Whole cylinders sent: ",0
MSG_GONE3:	defb "Cut the PC's file to that size and restart the image from that cylinder.",0
MSG_HU0:	defb 0dh,0ah,"No bad list from this run. Entries of a previous run's list to use [none]: ",0
MSG_HUCB:	defb 0dh,0ah,"That list isn't there any more (an entry is out of range).",0dh,0ah,0
MSG_HU1:	defb 0dh,0ah,"Hunt the ",0
MSG_HU2:	defb " bad sectors of the last image (Y/N)? ",0
MSG_HC:		defb 0dh,0ah,"C",0
MSG_HCOL:	defb ": ",0
MSG_HNOW:	defb "reads normally now",0
MSG_HFOUND:	defb " found as ",0
MSG_HCRC:	defb "(CRC error in the data)",0
MSG_HNONE:	defb " not found",0
MSG_HTWIN:	defb " (that was sector ",0
MSG_HFEAT:	defb " (a good sector answers to that change too: not damage)",0
MSG_HUR1:	defb 0dh,0ah,"Recovered ",0
MSG_HUR2:	defb " sector(s).",0dh,0ah,0
MSG_HUR3:	defb "Start the XMODEM receive on the PC (port B) for the fix file; hdfix.py puts it into the image.",0dh,0ah,0
MSG_HUSENT:	defb 0dh,0ah,"Fix file sent.",0dh,0ah,0
MSG_CRC3:	defb "CRC"
FIXTXT:		defb "HDFIX C000 H0 S00 ID 00 00 00 00 OK ",0dh,0ah
FIXTXTL:	equ $-FIXTXT
MSG_ASKC:	defb 0dh,0ah,"Cylinder: ",0
MSG_ASKH:	defb "  Head: ",0
MSG_ASKS:	defb "  Sector: ",0
MSG_RDF:	defb "Read failed, error ",0
MSG_RANGE:	defb 0dh,0ah,"Out of range",0dh,0ah,0
MSG_PARKED:	defb "Heads parked in the shipping zone (cylinder 525). Power the drive down.",0dh,0ah,0
MSG_PARK0:	defb "The drive went to track 0 instead: it refused the shipping-zone seek.",0dh,0ah,0
MSG_ASKF:	defb 0dh,0ah,"First cylinder [0]: ",0
MSG_ASKL:	defb "  Last cylinder [479]: ",0
MSG_IM1:	defb 0dh,0ah,0
MSG_IM2:	defb " cylinders, ",0
MSG_IM3:	defb "K. Start the XMODEM receive on the PC (port B). ^C stops.",0dh,0ah,0
MSG_PCYL:	defb 0dh,"Cylinder ",0
MSG_PHD:	defb " head ",0
MSG_PBAD:	defb "  bad sectors ",0
MSG_DONE:	defb 0dh,0ah,"Image complete.",0dh,0ah,0
MSG_BAD1:	defb "Bad sectors: ",0
MSG_BLH:	defb " H",0
MSG_BLS:	defb " S",0
MSG_BLE:	defb " err ",0
MSG_ERRS:	defb "err: 02 not found, 04 compare, 08 CRC, 40 write fault, 80 not ready, FF no answer",0dh,0ah,0
MSG_PCCAN:	defb "Cancelled by the PC",0
MSG_NORCV:	defb "Nothing from the PC: no XMODEM receive started",0
MSG_XERR:	defb "Too many XMODEM errors",0
MSG_USER:	defb "Stopped",0
MSG_NOCTS:	defb "Port B isn't sending (no CTS from the PC?)",0dh,0ah,0
BADTXT:		defb "** BAD SECTOR C000 H0 S00 **  ",0dh,0ah
; the layout found on the MCP's MiniScribe: byte 0 cylinder 0-7, byte 1
; bit 0 cylinder 8, byte 2 head, byte 3 sector (MAP order: S0-4 H0-1 C0-8)
KNOWN:		defb 3,001h, 3,002h, 3,004h, 3,008h, 3,010h
		defb 2,001h, 2,002h
		defb 0,001h, 0,002h, 0,004h, 0,008h, 0,010h, 0,020h, 0,040h, 0,080h
		defb 1,001h

;-----------------------------------------------------------------------
DEXTV:	defb 0				; what port 61h was last set to
CURCYL:	defw 0
TGTCYL:	defw 0
RCYL:	defw 0				; sector being read
RHEAD:	defb 0
RSEC:	defb 0
DEST:	defw 0
RECALD:	defb 0				; recalibrated in this track already
TRIES:	defb 0
GOOD:	defb 0
GONES:	defb 0				; drive dropouts allowed for this sector
XFER:	defb 0				; an XMODEM transfer is running
LASTERR: defb 0
IDBUF:	defs 4
PROBED:	defb 0
ALLOWNONE: defb 0
BITK:	defb 0
USED:	defs 4
MAP:	defs 32				; S0-S4, H0-H1, C0-C8: byte, mask
FIRST:	defw 0
LAST:	defw 0
NCYLS:	defw 0
BADCNT:	defw 0
BADPTR:	defw 0
CRCM:	defb 0
BLKNUM:	defb 0
ERRS:	defb 0
PKTPTR:	defw 0
PKTLEN:	defw 0
PKTTYPE: defb 0
FAILMSG: defw 0
NUMBUF:	defs 4
LINE:	defs 32
PMIN:	defw 0				; T: spindle
PMAX:	defw 0
PSUM:	defw 0
PDROPS:	defw 0
TSECS:	defb 0
NSEEK:	defw 0				; T: seeks
NTMO:	defw 0
NOFF:	defw 0
NLOST:	defw 0
NDROP:	defw 0
TMIN:	defw 0
TMAX:	defw 0
TSUM:	defs 3
LFSR:	defw 0
DIVS:	defw 0
DIVR:	defw 0
DIVN:	defb 0
SPDLAST: defw 0
EXPID:	defs 4				; F: the ID a sector should have
CAND:	defs 4				; the one being tried
SAVSEC:	defb 0
HNCNT:	defb 0
HUNTN:	defb 0
TMPENT:	defs 5
FIXPTR:	defw 0
FIXCNT:	defb 0
FIXFLG:	defb 0
GOODSEC: defb 0
XTMP:	defw 0
CODEEND:

;=======================================================================
; Second section: the T tests, above the bad list and the buffers (the
; main program has to stay below 1E00h). bin2hex places it at TESTS.
;=======================================================================
	org TESTS
;-----------------------------------------------------------------------
; T: drive tests, read-only
;-----------------------------------------------------------------------
CMD_TEST:
	call NEEDPROBE
	ld hl,MSG_TMENU
	call PUTS
	call CONIN
	cp '1'
	jp z,T_SPIN
	cp '2'
	jp z,T_WALK
	cp '3'
	jp z,T_LONG
	cp '4'
	jp z,T_RAND
	cp '5'
	jp z,T_FLY
	jp MENU

; --- 1: the index period, revolution by revolution ---------------------
T_SPIN:	ld hl,MSG_TSECS
	call PUTS
	call GETNUM
	jr nz,TSP0
	ld hl,60
TSP0:	ld a,l
	ld (TSECS),a
	ld hl,MSG_TSPIN
	call PUTS
	ld hl,0ffffh
	ld (PMIN),hl
	ld hl,0
	ld (PMAX),hl
	ld (PDROPS),hl
TSP1:	ld b,60				; 60 revolutions per line
	ld hl,0
	ld (PSUM),hl
TSP2:	push bc
	call CONCHK
	call INDEXP
	pop bc
	jr c,TSP8
	ld hl,(PSUM)
	add hl,de
	ld (PSUM),hl
	ld hl,(PMIN)
	or a
	sbc hl,de
	jr c,TSP3
	ld (PMIN),de
TSP3:	ld hl,(PMAX)
	or a
	sbc hl,de
	jr nc,TSP4
	ld (PMAX),de
TSP4:	djnz TSP2
	ld hl,(PSUM)			; the line: average, rpm, min, max, drops
	ld de,60
	xor a
	call DIV24
	push hl
	call PMS
	ld hl,MSG_TMS
	call PUTS
	pop de
	ld a,02dh			; 3,000,000 / period = rpm
	ld hl,0c6c0h
	call DIV24
	call PDEC
	ld hl,MSG_TRPM
	call PUTS
	ld hl,(PMIN)
	call PMS
	ld hl,MSG_TMAX
	call PUTS
	ld hl,(PMAX)
	call PMS
	ld hl,MSG_TDR
	call PUTS
	ld hl,(PDROPS)
	call PDEC
	call CRLF
	ld hl,TSECS
	dec (hl)
	jr nz,TSP1
	jp MENU
TSP8:	or a				; no period: READY gone, or no index
	jr z,TSP9
	ld hl,MSG_TNOIDX
	call PUTS
	jp TSP1
TSP9:	ld hl,(PDROPS)
	inc hl
	ld (PDROPS),hl
	call WAITRDY
	jp TSP1

; INDEXP: one index period -> DE in 20 us units (833 = 3600 rpm). Carry:
; no period, A = 0 drive not ready, 1 no index pulse within 40 ms.
INDEXP:	call IXEDGE
	ret c
	call IXEDGE
	ret

IXEDGE:	in a,(DEXT)			; clear the latched INDEX
	ld de,0
IX1:	in a,(DSTAT)			; 11
	rrca				; 4   READY -> carry
	jr nc,IX8			; 7
	bit 4,a				; 8   INDEX (was bit 5)
	jr nz,IX9			; 7
	ld b,4				; 7
IX2:	djnz IX2			; 47
	inc de				; 6
	ld a,d				; 4
	cp 8				; 7   2048 x 20 us = 41 ms
	jr c,IX1			; 12  = 120 T = 20 us
	ld a,1
	scf
	ret
IX8:	xor a
	scf
	ret
IX9:	inc de				; the clear-to-loop overhead, about a count
	or a
	ret

; SPDOK: Z = the index period is within 0.5 % of 16.67 ms (829-837
; counts); DE = the period. NZ with carry: no period at all.
SPDOK:	call INDEXP
	jr c,SPD9
	ld (SPDLAST),de
	ld hl,837
	or a
	sbc hl,de
	jr c,SPD8
	ld hl,828
	or a
	sbc hl,de
	jr nc,SPD8
	xor a
	ret
SPD8:	or 1
	ret
SPD9:	or 1
	scf
	ret

; SPDGATE: if the spindle is off speed, say so and wait up to about 15 s
; for it to be back. Z = on speed.
SPDGATE: call SPDOK
	ret z
	ret c				; not ready or no index: READSEC's business
	ld hl,MSG_SPD1
	call PUTS
	ld hl,(SPDLAST)
	call PMS
	ld hl,MSG_SPD2
	call PUTS
	ld b,100
SPG1:	push bc
	call CONCHK
	call DLY100
	call SPDOK
	pop bc
	jr z,SPG2
	djnz SPG1
	ld hl,MSG_SPD4
	call PUTS
	or 1
	ret
SPG2:	ld hl,MSG_SPD3
	call PUTS
	xor a
	ret

; PMS: HL in 20 us units as ms with two decimals, e.g. 16.67
PMS:	ld de,50
	xor a
	call DIV24			; HL = ms, (PSUM-style remainder lost: redo)
	push hl
	ld d,h
	ld e,l
	ld hl,(DIVR)			; remainder = units mod 50
	add hl,hl			; x2 = hundredths
	ex (sp),hl
	call PDEC
	ld a,'.'
	call CONOUT
	pop hl
	ld a,l
	ld de,-10
	ld b,'0'-1
PMSL:	inc b
	add hl,de
	jr c,PMSL
	sbc hl,de
	ld a,b
	call CONOUT
	ld a,l
	add a,'0'
	jp CONOUT

; DIV24: A:HL / DE -> A:HL, remainder in (DIVR)
DIV24:	ld (DIVS),de
	push af
	ld a,24
	ld (DIVN),a
	pop af
	ld bc,0
DV1:	add hl,hl
	rla
	rl c
	rl b
	jr c,DV2			; remainder bit 16: certainly >= divisor
	push hl
	ld h,b
	ld l,c
	ld de,(DIVS)
	or a
	sbc hl,de
	jr c,DV3
DV2A:	ld b,h
	ld c,l
	pop hl
	inc l				; quotient bit (L bit 0 is 0 after the shift)
	jr DV4
DV2:	push hl
	ld h,b
	ld l,c
	ld de,(DIVS)
	or a
	sbc hl,de
	jr DV2A
DV3:	pop hl
DV4:	push af
	ld a,(DIVN)
	dec a
	ld (DIVN),a
	jr z,DV9
	pop af
	jr DV1
DV9:	pop af
	ld (DIVR),bc
	ret

; --- 2-5: seek patterns --------------------------------------------------
T_WALK:	ld hl,MSG_TWALK
	call TSTART
	ld hl,1
TW1:	push hl
	call TSTEP
	pop hl
	inc hl
	ld a,h
	cp 1				; past 479?
	jr nz,TW1
	ld a,l
	cp 224
	jr nz,TW1
	ld hl,478
TW2:	push hl
	call TSTEP
	pop hl
	ld a,h
	or l
	jr z,TW3
	dec hl
	jr TW2
TW3:	jp TSUMM

T_LONG:	ld hl,MSG_TLONG
	call TSTART
	ld b,50
TL1:	push bc
	ld hl,MAXCYL
	call TSTEP
	ld hl,0
	call TSTEP
	pop bc
	djnz TL1
	jp TSUMM

T_RAND:	ld hl,MSG_TRAND
	call TSTART
	ld hl,0ace1h
	ld (LFSR),hl
	ld bc,300
TR1:	push bc
	ld hl,(LFSR)			; 16-bit LFSR, taps 16 14 13 11
	ld a,l
	srl h
	rr l
	jr nc,TR2
	ld a,h
	xor 0b4h
	ld h,a
TR2:	ld (LFSR),hl
	ld a,h
	and 1
	ld h,a				; 0..511
	ld de,480
	or a
	sbc hl,de
	jr nc,TR3
	add hl,de
TR3:	call TSTEP
	pop bc
	dec bc
	ld a,b
	or c
	jr nz,TR1
	jp TSUMM

T_FLY:	ld hl,MSG_TFLY
	call TSTART
	ld hl,0
	ld (LAST),hl			; low end (the image's range variables
	ld hl,MAXCYL			; are free here)
	ld (FIRST),hl			; high end
TF1:	ld hl,(LAST)
	call TSTEP
	ld hl,(FIRST)
	call TSTEP
	ld hl,(LAST)
	inc hl
	ld (LAST),hl
	ld de,(FIRST)
	dec de
	ld (FIRST),de
	or a
	sbc hl,de
	jr c,TF1
	jp TSUMM

; TSTART: title, zero the counters, restore
TSTART:	call PUTS
	ld hl,0
	ld (NSEEK),hl
	ld (NTMO),hl
	ld (NOFF),hl
	ld (NLOST),hl
	ld (NDROP),hl
	ld (TMAX),hl
	ld (TSUM),hl
	ld (TSUM+1),hl
	dec hl
	ld (TMIN),hl
	jp HDINIT2

; TSTEP: one timed seek to cylinder HL, verified by reading a header there
; (a seek to where the heads already are isn't counted)
TSTEP:	push hl
	call CONCHK
	call DRVOK
	jr z,TST1
	call TDROP
TST1:	pop hl
	push hl
	ld de,(CURCYL)
	or a
	sbc hl,de
	pop hl
	ret z
	push hl
	call TSEEK
	pop hl
	jr z,TST2
	push hl
	ld hl,(NTMO)
	inc hl
	ld (NTMO),hl
	ld hl,MSG_TTMO
	call PUTS
	pop hl
	call PDEC
	call CRLF
	jp HDINIT2
TST2:	ld hl,(NSEEK)
	inc hl
	ld (NSEEK),hl
	ld hl,(TSUM)			; 24-bit sum of the times
	add hl,de
	ld (TSUM),hl
	jr nc,TST3
	ld hl,TSUM+2
	inc (hl)
TST3:	ld hl,(TMIN)
	or a
	sbc hl,de
	jr c,TST4
	ld (TMIN),de
TST4:	ld hl,(TMAX)
	or a
	sbc hl,de
	jr nc,TST5
	ld (TMAX),de
TST5:	call VERIFY
	jr z,TST9
	ld c,a
	ld a,(LASTERR)			; READY went while verifying?
	cp 080h
	jr nz,TST6
	call TDROP
	ret
TST6:	ld a,c
	cp 080h
	jr z,TST7
	ld hl,(NOFF)
	inc hl
	ld (NOFF),hl
	ld hl,MSG_TOFF
	call PUTS
	ld a,c
	or a
	jp p,TST6A
	neg
	ld c,a
	ld a,'-'
	call CONOUT
	ld a,c
TST6A:	add a,'0'
	call CONOUT
	ld hl,MSG_TAT
	jr TST8
TST7:	ld hl,(NLOST)
	inc hl
	ld (NLOST),hl
	ld hl,MSG_TLOST
TST8:	call PUTS
	ld hl,(CURCYL)
	call PDEC
	call CRLF
	jp HDINIT2			; back in step with the drive
TST9:	ld a,(NSEEK)
	and 00fh
	ret nz
	ld a,'.'
	jp CONOUT

; TDROP: READY gone during a test: count, wait, restore
TDROP:	ld hl,(NDROP)
	inc hl
	ld (NDROP),hl
	call WAITRDY
	jp HDINIT2

; TSEEK: timed seek to cylinder HL. DE = time in 0.1 ms from the command
; to SEEK END, Z = done (CURCYL updated), NZ = no SEEK END within 4 s.
TSEEK:	ld (TGTCYL),hl
	ld de,0
	push de
	ld de,(CURCYL)
	or a
	sbc hl,de
	pop de
	ret z
	ld b,002h
	jr nc,TSK1
	ld a,h
	cpl
	ld h,a
	ld a,l
	cpl
	ld l,a
	inc hl
	ld b,000h
TSK1:	ld a,002h
	out (DSTAT),a
	ld a,(DEXTV)
	and 0fdh
	or b
	ld (DEXTV),a
	out (DEXT),a
	ld a,l
	out (SCLO),a
	ld a,h
	out (SCHI),a
	ld a,003h
	out (DSTAT),a
TSK2:	in a,(DSTAT)			; SEEK END drops (within 22 ms)
	rla
	jr nc,TSK3
	call T100US
	ld a,d
	or a
	jr nz,TSK3
	ld a,e
	cp 220
	jr c,TSK2
TSK3:	in a,(DSTAT)			; and comes back
	rla
	jr c,TSK4
	call T100US
	ld a,d
	cp 09ch				; about 4 s
	jr c,TSK3
	ld a,002h
	out (DSTAT),a
	or 1
	ret
TSK4:	ld a,002h
	out (DSTAT),a
	ld hl,(TGTCYL)
	ld (CURCYL),hl
	xor a
	ret

T100US:	ld b,41				; with the caller's loop: 0.1 ms, DE++
TU1:	djnz TU1
	inc de
	ret

; VERIFY: a header of CURCYL (head 0, sector 0 or 1) reads. Z = yes; else
; A = where one did: +-1..3 cylinders away, or 80h nowhere near.
VERIFY:	xor a
	ld (RHEAD),a
	call SELHEAD
	xor a
	call VFTRY
	ret z
	ld b,1
VF1:	push bc
	ld a,b
	call VFTRY
	pop bc
	jr nz,VF2
	ld a,b
	or a
	ret
VF2:	push bc
	ld a,b
	neg
	call VFTRY
	pop bc
	jr nz,VF3
	ld a,b
	neg
	or a
	ret
VF3:	inc b
	ld a,b
	cp 4
	jr c,VF1
	ld a,080h
	or a
	ret

; VFTRY: does a header of cylinder CURCYL + A (signed) read? Z = yes
VFTRY:	ld e,a
	ld d,0
	or a
	jp p,VFT1
	ld d,0ffh
VFT1:	ld hl,(CURCYL)
	add hl,de
	bit 7,h
	jr nz,VFT9
	ld de,MAXCYL+1
	push hl
	or a
	sbc hl,de
	pop hl
	jr nc,VFT9
	ld (RCYL),hl
	xor a
	ld (RSEC),a
	call MKID
	ld a,2
	call TRYN
	ret z
	ld a,1				; or sector 1, in case sector 0 is bad
	ld (RSEC),a
	call MKID
	ld a,2
	jp TRYN
VFT9:	or 1
	ret

; TSUMM: the pattern's results
TSUMM:	ld hl,MSG_TS1
	call PUTS
	ld hl,(NSEEK)
	call PDEC
	ld hl,MSG_TS2
	call PUTS
	ld hl,(TMIN)
	call PMS1
	ld a,'/'
	call CONOUT
	ld a,(TSUM+2)
	ld hl,(TSUM)
	ld de,(NSEEK)
	call DIV24
	call PMS1
	ld a,'/'
	call CONOUT
	ld hl,(TMAX)
	call PMS1
	ld hl,MSG_TS3
	call PUTS
	ld hl,(NSEEK)
	ld de,(NOFF)
	or a
	sbc hl,de
	ld de,(NLOST)
	or a
	sbc hl,de
	call PDEC
	ld hl,MSG_TS4
	call PUTS
	ld hl,(NOFF)
	call PDEC
	ld hl,MSG_TS5
	call PUTS
	ld hl,(NLOST)
	call PDEC
	ld hl,MSG_TS6
	call PUTS
	ld hl,(NTMO)
	call PDEC
	ld hl,MSG_TS7
	call PUTS
	ld hl,(NDROP)
	call PDEC
	call CRLF
	jp MENU

; PMS1: HL in 0.1 ms units as ms with one decimal
PMS1:	ld de,10
	xor a
	call DIV24
	call PDEC
	ld a,'.'
	call CONOUT
	ld a,(DIVR)
	add a,'0'
	jp CONOUT

MSG_TMENU:	defb 0dh,0ah,"Tests (all read-only):",0dh,0ah
		defb " 1  spindle: index period, 60 revolutions per line",0dh,0ah
		defb " 2  seeks: one-cylinder walk 0 -> 479 -> 0",0dh,0ah
		defb " 3  seeks: full stroke 0 <-> 479, 50 times",0dh,0ah
		defb " 4  seeks: 300 random cylinders",0dh,0ah
		defb " 5  seeks: butterfly 0, 479, 1, 478 ...",0dh,0ah
		defb "Test (ESC): ",0
MSG_TSECS:	defb 0dh,0ah,"Seconds [60]: ",0
MSG_TSPIN:	defb 0dh,0ah,"Index period, ms (nominal 16.67 = 3600 rpm). ^C stops.",0dh,0ah,0
MSG_TMS:	defb " ms ",0
MSG_SPD1:	defb 0dh,0ah,"Spindle off speed: ",0
MSG_SPD2:	defb " ms, waiting for it... ",0
MSG_SPD3:	defb "on speed.",0dh,0ah,0
MSG_SPD4:	defb "still off, going on.",0dh,0ah,0
MSG_TRPM:	defb " rpm  min ",0
MSG_TMAX:	defb " max ",0
MSG_TDR:	defb "  READY drops ",0
MSG_TNOIDX:	defb " no index pulse for 40 ms",0dh,0ah,0
MSG_TWALK:	defb 0dh,0ah,"One-cylinder walk 0 -> 479 -> 0 (. = 16 seeks, ^C stops)",0dh,0ah,0
MSG_TLONG:	defb 0dh,0ah,"Full stroke 0 <-> 479, 50 times",0dh,0ah,0
MSG_TRAND:	defb 0dh,0ah,"300 random seeks",0dh,0ah,0
MSG_TFLY:	defb 0dh,0ah,"Butterfly 0, 479, 1, 478 ...",0dh,0ah,0
MSG_TTMO:	defb " seek timeout at C",0
MSG_TOFF:	defb " off by ",0
MSG_TAT:	defb " at C",0
MSG_TLOST:	defb " lost at C",0
MSG_TS1:	defb 0dh,0ah,"Seeks: ",0
MSG_TS2:	defb "  time min/avg/max ms: ",0
MSG_TS3:	defb 0dh,0ah,"Arrived: ",0
MSG_TS4:	defb "  off by 1-3: ",0
MSG_TS5:	defb "  lost: ",0
MSG_TS6:	defb "  timeouts: ",0
MSG_TS7:	defb "  READY drops: ",0
TESTEND:
