;=======================================================================
; CP/M 2.2 BIOS for the MCP 80/100
;
; 60K system: CCP D400h, BDOS DC00h, BIOS EA00h. RAM above F000h belongs
; to the CPU card (monitor scratch RAM, then the ROM at F800h).
;
; Console   port A: 8251 at 02h (data) / 03h (status)
; PUN:/LST: port B: 8251 at 00h / 01h (gives up after ~1 s if not sending)
; RDR:      port B
; Drive A:  Shugart SA850 on MCP's FD1793 card (F8h-FBh), 8" single-sided
;           single density, IBM 3740: 77 tracks x 26 x 128 bytes, skew 6,
;           2 system tracks, 1K blocks, 243 blocks, 64 directory entries.
;
; Disk transfers poll the FD1793 status register (never the FCh wait port)
; with timeouts, as in FDTEST, so a missing disk can't hang the machine.
;
; Only code and initialised data are loaded from disk (EA00h-ED7Fh, the 7
; sectors left on the system tracks); buffers live at ED80h-EFFFh.
;=======================================================================
MSIZE:	equ 60
BIAS:	equ (MSIZE-20)*1024
CCP:	equ 3400h+BIAS			; D400h
BDOS:	equ CCP+0806h			; DC06h, BDOS entry
BIOS:	equ CCP+1600h			; EA00h
BIOSEND: equ BIOS+7*128			; ED80h: end of what the loader reads
NSECTS:	equ 44				; CCP + BDOS sectors, reloaded on warm boot

IOBYTE:	equ 0003h
CDISK:	equ 0004h

COND:	equ 002h			; console 8251
CONS:	equ 003h
AUXD:	equ 000h			; port B 8251
AUXS:	equ 001h

FDCMD:	equ 0f8h			; FD1793
FDTRK:	equ 0f9h
FDSEC:	equ 0fah
FDDAT:	equ 0fbh

RDCMD:	equ 08ch			; read sector, 15 ms head settle
RDFAST:	equ 088h			; read sector, no settle (sequential reads)
WRCMD:	equ 0ach			; write sector, 15 ms head settle
SKCMD:	equ 01bh			; seek, head load, 15 ms steps
RSCMD:	equ 00bh			; restore, head load, 15 ms steps

	org BIOS

	jp BOOT
WBOOTE:	jp WBOOT
	jp CONST
	jp CONIN
	jp CONOUT
	jp LIST
	jp PUNCH
	jp READER
	jp HOME
	jp SELDSK
	jp SETTRK
	jp SETSEC
	jp SETDMA
	jp READ
	jp WRITE
	jp LISTST
	jp SECTRAN

;-----------------------------------------------------------------------
; Cold and warm boot
;-----------------------------------------------------------------------
BOOT:	di
	ld sp,0080h
	ld hl,SIGNON
	call PRMSG
	xor a
	ld (IOBYTE),a
	ld (CDISK),a
	jr GOCPM

WBOOT:	di
	ld sp,0080h
	call RESTORE			; also puts the 1793's track register right
	ld hl,CCP
	ld (DMAADR),hl
	xor a
	ld (TRACK),a
	ld a,2				; CCP starts at track 0, sector 2
	ld (SECTOR),a
	ld a,NSECTS
	ld (WBCNT),a
	ld a,RDCMD			; first read lets the head settle
WB1:	call DSKIO
	or a
	jr nz,WBERR
	ld hl,(DMAADR)
	ld de,128
	add hl,de
	ld (DMAADR),hl
	ld hl,SECTOR
	inc (hl)
	ld a,(hl)
	cp 27
	jr c,WB2
	ld (hl),1
	ld hl,TRACK
	inc (hl)
WB2:	ld hl,WBCNT
	dec (hl)
	ld a,RDFAST			; the rest follow on directly
	jr nz,WB1

GOCPM:	ld a,0c3h			; page zero: JP WBOOT, JP BDOS
	ld (0000h),a
	ld hl,WBOOTE
	ld (0001h),hl
	ld (0005h),a
	ld hl,BDOS
	ld (0006h),hl
	ld bc,0080h
	call SETDMA
	ld a,(CDISK)
	and 00fh
	ld c,a
	jp CCP

WBERR:	ld hl,MSGWB
	call PRMSG
	call CONIN
	jr WBOOT

PRMSG:	ld a,(hl)
	or a
	ret z
	ld c,a
	call CONOUT
	inc hl
	jr PRMSG

;-----------------------------------------------------------------------
; Character I/O
;-----------------------------------------------------------------------
CONST:	in a,(CONS)
	and 002h
	ret z
	ld a,0ffh
	ret

CONIN:	in a,(CONS)
	and 002h
	jr z,CONIN
	in a,(COND)
	and 07fh
	ret

CONOUT:	in a,(CONS)
	and 001h
	jr z,CONOUT
	ld a,c
	out (COND),a
	ret

LIST:
PUNCH:	ld de,0				; port B; the 8251 only sends with CTS,
PU1:	in a,(AUXS)			; so give up after about a second
	and 001h
	jr nz,PU2
	dec de
	ld a,d
	or e
	jr nz,PU1
	ret
PU2:	ld a,c
	out (AUXD),a
	ret

LISTST:	in a,(AUXS)
	and 001h
	ret z
	ld a,0ffh
	ret

READER:	in a,(AUXS)
	and 002h
	jr z,READER
	in a,(AUXD)
	ret

;-----------------------------------------------------------------------
; Disk
;-----------------------------------------------------------------------
HOME:	xor a
	ld (TRACK),a
	jp RESTORE

SELDSK:	ld hl,0
	ld a,c
	or a
	ret nz				; only A:
	ld hl,DPH0
	ret

SETTRK:	ld a,c
	ld (TRACK),a
	ret

SETSEC:	ld a,c
	ld (SECTOR),a
	ret

SETDMA:	ld (DMAADR),bc
	ret

SECTRAN: ld a,d
	or e
	jr nz,ST1
	ld h,b				; no table: sector + 1
	ld l,c
	inc hl
	ret
ST1:	ex de,hl
	add hl,bc
	ld l,(hl)
	ld h,0
	ret

READ:	ld a,RDCMD
	jr DSKIO
WRITE:	ld a,WRCMD

; DSKIO: command in A (read or write sector), TRACK / SECTOR / DMAADR set.
; Returns A = 0 OK, 1 error. Ten tries; restores the head after four.
DSKIO:	ld (DCMD),a
	ld a,10
	ld (RETRY),a
DS1:	call SEEK
	ld a,(SECTOR)
	out (FDSEC),a
	ld hl,(DMAADR)
	ld a,(DCMD)
	bit 5,a				; write commands have bit 5 set
	jr nz,DS2
	call XIN
	jr DS3
DS2:	call XOUT
DS3:	or a
	ret z
	bit 6,a				; write protected: no point retrying
	jr nz,DSERR
	ld hl,RETRY
	dec (hl)
	jr z,DSERR
	ld a,(hl)
	cp 6
	call z,RESTORE
	ld a,(DCMD)			; retries settle the head again
	or 004h
	ld (DCMD),a
	jr DS1
DSERR:	ld a,1
	ret

SEEK:	in a,(FDTRK)
	ld b,a
	ld a,(TRACK)
	cp b
	ret z
	out (FDDAT),a
	ld a,SKCMD
	jr TYPE1

RESTORE: ld a,RSCMD
; TYPE1: issue a Type I command, wait until done (~4 s timeout)
TYPE1:	call FCMD
	ld hl,0
	ld b,12
T1W:	in a,(FDCMD)
	rrca
	ret nc
	dec hl
	ld a,h
	or l
	jr nz,T1W
	djnz T1W
	ld a,0d0h			; timeout: force interrupt
FCMD:	out (FDCMD),a			; command, then give the 1793 time
	ld a,40				; before its status is read
FC1:	dec a
	jr nz,FC1
	ret

; XIN / XOUT: command in A, 128 bytes at HL. A = 0 OK, else 1793 status
; (or FFh timeout). Polled: worst response to a data request is well under
; the 32 us per byte of single density, even at 4 MHz.
XIN:	call XSET
XI1:	in a,(FDCMD)
	rrca				; BUSY -> carry
	jr nc,XIEND
	rrca				; DRQ -> carry
	jr c,XI2
	djnz XI1
	dec d
	jp nz,XI1
	dec e
	jp nz,XI1
	jr XTO
XI2:	in a,(FDDAT)
	ld (hl),a
	inc hl
	dec c
	jp nz,XI1
XI3:	in a,(FDCMD)			; all 128 in: wait for the CRC check
	rrca
	jr nc,XIEND
	rrca
	jr c,XLONG			; more data: not a 128-byte sector
	djnz XI3
	dec d
	jr nz,XI3
	jr XTO
XIEND:	in a,(FDCMD)
	and 09ch			; not ready, not found, CRC, lost data
	jr XEND

XOUT:	call XSET
XO1:	in a,(FDCMD)
	rrca
	jr nc,XOEND
	rrca
	jr c,XO2
	djnz XO1
	dec d
	jp nz,XO1
	dec e
	jp nz,XO1
	jr XTO
XO2:	ld a,(hl)
	out (FDDAT),a
	inc hl
	dec c
	jp nz,XO1
XO3:	in a,(FDCMD)			; all 128 sent: wait for the end
	rrca
	jr nc,XOEND
	djnz XO3
	dec d
	jr nz,XO3
	jr XTO
XOEND:	in a,(FDCMD)
	and 0fch			; also write protect, write fault
XEND:	push af
	ld a,0d0h			; back to Type I status
	call FCMD
	pop af
	ret
XLONG:
XTO:	ld a,0d0h
	call FCMD
	ld a,0ffh
	ret

XSET:	ld a,(DCMD)			; issue the command (HL is kept)
	call FCMD
	ld bc,128			; B = 0 (inner timeout), C = byte count
	ld de,0005h			; D = 0 (256), E = 5: about 2.5 s at 6 MHz
	ret

;-----------------------------------------------------------------------
; Tables and text
;-----------------------------------------------------------------------
DPH0:	defw XLT, 0, 0, 0, DIRBUF, DPB, CSV, ALV

DPB:	defw 26				; sectors per track
	defb 3, 7, 0			; BSH, BLM, EXM (1K blocks)
	defw 242			; DSM: 243 blocks
	defw 63				; DRM: 64 directory entries
	defb 0c0h, 000h			; AL0, AL1: 2 directory blocks
	defw 16				; CKS
	defw 2				; OFF: system tracks

XLT:	defb 1,7,13,19,25,5,11,17,23,3,9,15,21
	defb 2,8,14,20,26,6,12,18,24,4,10,16,22

SIGNON:	defb 0dh,0ah,"MCP 80/100  60K CP/M 2.2  (BIOS 1.0)",0dh,0ah,0
MSGWB:	defb 0dh,0ah,"Warm boot: disk error. Press a key to retry",0dh,0ah,0

BIOSTOP:
;-----------------------------------------------------------------------
; Not loaded from disk: variables and buffers (ED80h-EFFFh)
;-----------------------------------------------------------------------
TRACK:	equ BIOSEND
SECTOR:	equ BIOSEND+1
DMAADR:	equ BIOSEND+2
DCMD:	equ BIOSEND+4
RETRY:	equ BIOSEND+5
WBCNT:	equ BIOSEND+6
DIRBUF:	equ BIOSEND+16			; 128
CSV:	equ DIRBUF+128			; 16
ALV:	equ CSV+16			; 31 (243 blocks)
BUFEND:	equ ALV+31
