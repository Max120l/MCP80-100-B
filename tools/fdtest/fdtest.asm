;=======================================================================
; FDTEST - 8" floppy test for the MCP 80/100 FDC (FD1793 at F8h-FBh)
; Self-contained (talks to the console 8251 itself), so it runs from any
; monitor: load fdtest.hex with H, run with G:0100 <CR>; Q returns to
; MCPMON (F803h). FDTEST.COM is the same program for CP/M: the exit jump
; at EXITJP is patched to 0000h (warm boot).
;
; Single density (IBM 3740: 77 tracks, 26 x 128-byte sectors). Polls the
; 1793 status register and never touches port FCh (the board's wait port),
; so a dead drive can't hang the CPU. At start it measures the CPU clock
; against the console UART (assumed 9600 baud), so the rpm readout doesn't
; depend on the clock; transfers need a clock of 4 MHz or more.
;
; Keys:  Z restore      I / O step in / out      S seek to a track
;        A read the next sector ID     R read one sector and dump it
;        V read all 26 sectors of this track (doesn't write)
;        T FORMAT this track, write a pattern, read it back (asks Y)
;        ? help         Q or ESC quit
;=======================================================================
CONST_P: equ 003h			; console status: bit 0 TxRDY, 1 RxRDY, 2 TxEMPTY
CON_D:	equ 002h			; console data
FDCMD:	equ 0f8h			; FD1793 command / status
FDTRK:	equ 0f9h			; track register
FDSEC:	equ 0fah			; sector register
FDDAT:	equ 0fbh			; data register

TRKBUF:	equ 2000h			; track image for Write Track
TRKLEN:	equ 6400			; covers a slow (300 rpm) track too
TRKCAP:	equ (TRKBUF+TRKLEN)/256		; transfer stops if HL reaches this page
SECBUF:	equ 4000h			; sector buffer, up to 1 KB
SECCAP:	equ (SECBUF+1024)/256
NSEC:	equ 26
MAXTRK:	equ 76

	org 0100h

START:	di
	call CALIB
	ld hl,MSG_HELP
	call PUTS
	call PCLK
	ld a,0d0h			; force interrupt: idle, Type I status
	call FCMD

; ---- main loop: status line, then ~0.4 s of key polling ----------------------
MAIN:	call SHOW
	ld de,08000h
ML:	in a,(CONST_P)
	and 002h
	jr nz,KEY
	dec de
	ld a,d
	or e
	jr nz,ML
	jr MAIN

KEY:	call CONIN
	cp 'a'
	jr c,K0
	cp 'z'+1
	jr nc,K0
	sub 020h
K0:	cp 'Q'
	jp z,QUIT
	cp 01bh
	jp z,QUIT
	cp 'Z'
	jp z,KREST
	cp 'I'
	jp z,KIN
	cp 'O'
	jp z,KOUT
	cp 'S'
	jp z,KSEEK
	cp 'A'
	jp z,KADDR
	cp 'R'
	jp z,KREAD
	cp 'V'
	jp z,KVERIFY
	cp 'T'
	jp z,KTEST
	cp 'W'
	jp z,KLOOP
	cp 'K'
	jp z,KTRACK
	cp 'C'
	jp z,KCLEAN
	cp '?'
	jp nz,MAIN
	ld hl,MSG_HELP
	call PUTS
	call PCLK
	jp MAIN

QUIT:	ld a,0d0h
	call FCMD
	ld hl,MSG_BYE
	call PUTS
EXITJP:	jp 0f803h			; MCPMON warm start (0000h in FDTEST.COM)

; ---- console (8251 at 02h/03h) --------------------------------------------------
CONIN:	in a,(CONST_P)
	and 002h
	jr z,CONIN
	in a,(CON_D)
	and 07fh
	ret
CONOUT:	push af
CO1:	in a,(CONST_P)
	and 001h
	jr z,CO1
	pop af
	out (CON_D),a
	ret
PUTS:	ld a,(hl)			; 0-terminated string at HL
	or a
	ret z
	call CONOUT
	inc hl
	jr PUTS
PUTHEX:	push af				; A as two hex digits
	rrca
	rrca
	rrca
	rrca
	call PNIB
	pop af
PNIB:	and 00fh
	add a,090h
	daa
	adc a,040h
	daa
	jp CONOUT

; ---- status line ---------------------------------------------------------------
SHOW:	ld a,0dh
	call CONOUT
	in a,(FDCMD)
	ld c,a
	ld hl,T_ST
	call PUTS
	ld a,c
	call PUTHEX
	ld hl,T_TRK
	call PUTS
	in a,(FDTRK)
	call PUTDEC
	ld hl,T_NRDY
	bit 7,c
	jr nz,SH1
	ld hl,T_RDY
SH1:	call PUTS
	ld hl,T_WP
	bit 6,c
	call nz,PUTS
	ld hl,T_HLD
	bit 5,c
	call nz,PUTS
	ld hl,T_TK0
	bit 2,c
	call nz,PUTS
	ld hl,T_SKE
	bit 4,c
	call nz,PUTS
	ld a,' '
	call CONOUT
	call IPER
	jr c,SH2
	call SCALE			; ticks -> 0.1 ms using the measured clock
	push hl
	call PUTMS
	pop hl
	call RPM
	call PUTDEC16
	ld hl,T_RPM
	jr SH3
SH2:	ld hl,T_NOIDX
	or a
	jr z,SH3
	ld hl,T_FAST
SH3:	call PUTS
	ld hl,T_PAD
	jp PUTS

; IPER: time one revolution between index leading edges.
; NC: HL = period in 400-T ticks (0.1 ms at 4 MHz; SCALE converts).
; CY: A = 0 no index, A = 1 pulses too fast.
IPER:	ld hl,0
IP1:	in a,(FDCMD)			; wait for index inactive
	and 002h
	jr z,IP2
	dec hl
	ld a,h
	or l
	jr nz,IP1
	scf
	ret
IP2:	in a,(FDCMD)			; wait for a leading edge (~0.8 s max)
	and 002h
	jr nz,IP3
	dec hl
	ld a,h
	or l
	jr nz,IP2
	scf
	ret
IP3:	ld hl,0				; count 400-T (100 us) ticks to the next edge
IPA:	in a,(FDCMD)			; 11  pulse still active
	and 002h			; 7
	jr z,IPB			; 7
	inc hl				; 6
	ld a,h				; 4
	cp 30				; 7   768 ms: give up
	jr nc,IPX			; 7
	ld b,25				; 7
IPAD:	djnz IPAD			; 320
	nop				; 4
	nop				; 4
	nop				; 4
	jr IPA				; 12 = 400
IPB:	in a,(FDCMD)			; 11  waiting for the next edge
	and 002h			; 7
	jr nz,IPY			; 7
	inc hl				; 6
	ld a,h				; 4
	cp 30				; 7
	jr nc,IPX			; 7
	ld b,25				; 7
IPBD:	djnz IPBD			; 320
	nop				; 4
	nop				; 4
	nop				; 4
	jr IPB				; 12 = 400
IPY:	ld a,h				; under 25.6 ms: not a plain index hole
	or a
	ret nz
	ld a,1
	scf
	ret
IPX:	xor a
	scf
	ret

; PUTMS: print HL (0.1 ms units) as "166.7 ms "
PUTMS:	ld de,-10
	ld bc,0
PM1:	add hl,de
	jr nc,PM2
	inc bc
	jr PM1
PM2:	ld de,10
	add hl,de			; L = tenths
	push hl
	ld h,b
	ld l,c
	call PUTDEC16
	ld a,'.'
	call CONOUT
	pop hl
	ld a,l
	add a,'0'
	call CONOUT
	ld hl,T_MS
	jp PUTS

; ---- CPU clock calibration against the console UART ---------------------------
; The COM5016 baud clock has its own crystal, so 192 characters at 9600 baud
; (8N1) take exactly 200.0 ms. NULs are sent; terminals ignore them.
; CALT = 400-T ticks in 200 ms (2000 at 4 MHz). K15 = 65536000 / CALT.
CALIB:	in a,(CONST_P)			; wait until the transmitter is idle
	and 004h
	jr z,CALIB
	xor a
	out (CON_D),a			; NUL into the shift register
CA1:	in a,(CONST_P)
	rrca
	jr nc,CA1
	xor a
	out (CON_D),a			; second NUL waits in the holding register
CA2:	in a,(CONST_P)			; start: first NUL finished
	rrca
	jr nc,CA2
	xor a
	out (CON_D),a
	ld hl,0
	ld e,192
CA3:	in a,(CONST_P)			; 11
	rrca				; 4   TxRDY
	jr c,CA5			; 7
	inc hl				; 6
	ld b,27				; 7
CA4:	djnz CA4			; 346
	or 0				; 7
	jr CA3				; 12 = 400
CA5:	xor a				; event: 58 T, not counted
	out (CON_D),a
	dec e
	jr nz,CA3
	ld de,28			; 191 events x 58 T + half a tick
	add hl,de
	ld (CALT),hl
	ld de,-1001			; below 2 MHz (or console not 9600): give up
	add hl,de
	jr c,CA6
	ld hl,2000			; assume 4 MHz
	ld (CALT),hl
CA6:	ld hl,(CALT)
	ld b,h
	ld c,l
	ld de,1000
	ld hl,0				; DE:HL = 65536000
	call DIVU
	ld (K15),hl
	ret

; PCLK: print the measured clock
PCLK:	ld hl,MSG_CLK
	call PUTS
	ld hl,(CALT)
	add hl,hl			; kHz = 2 x CALT
	call PUTDEC16
	ld hl,MSG_KHZ
	jp PUTS

; SCALE: HL = 400-T ticks -> HL = 0.1 ms units: (ticks x K15) >> 15
SCALE:	ex de,hl
	ld bc,(K15)
	call MUL16
	add hl,hl
	rl e
	rl d
	ex de,hl
	ret

; MUL16: DE x BC -> DE:HL
MUL16:	ld hl,0
	ld a,16
MU1:	add hl,hl
	rl e
	rl d
	jr nc,MU2
	add hl,bc
	jr nc,MU2
	inc de
MU2:	dec a
	jr nz,MU1
	ret

; DIVU: DE:HL / BC -> HL quotient, DE remainder (needs DE < BC)
DIVU:	ld a,16
DV1:	add hl,hl
	rl e
	rl d
	jr c,DV3
	ex de,hl
	or a
	sbc hl,bc
	jr nc,DV2
	add hl,bc
	ex de,hl
	jr DV4
DV3:	ex de,hl
	or a
	sbc hl,bc
DV2:	ex de,hl
	inc l
DV4:	dec a
	jr nz,DV1
	ret

; RPM: HL = period in 0.1 ms (>= 256) -> HL = 600000 / period, rounded
RPM:	ex de,hl
	ld h,d
	ld l,e
	srl h
	rr l				; period / 2, for rounding
	ld bc,027c0h
	add hl,bc
	ld c,009h			; C:HL = 600000 + period/2
	jr nc,RP0
	inc c
RP0:	ld ix,0
RP1:	or a
	sbc hl,de
	jr nc,RP2
	dec c
	jp m,RP3
RP2:	inc ix
	jr RP1
RP3:	push ix
	pop hl
	ret

; ---- Type I commands -------------------------------------------------------------
KREST:	ld a,00bh			; restore, head load, 15 ms steps
	call TYPE1
	jp MAIN
KIN:	in a,(FDTRK)
	cp MAXTRK
	jp nc,MAIN
	ld a,05bh			; step in, update track, head load
	call TYPE1
	jp MAIN
KOUT:	in a,(FDTRK)
	or a
	jp z,MAIN
	ld a,07bh			; step out, update track, head load
	call TYPE1
	jp MAIN
KSEEK:	ld hl,MSG_SEEK
	call PUTS
	call GETDEC2
	jr c,KBAD
	cp MAXTRK+1
	jr nc,KBAD
	out (FDDAT),a			; target track
	ld a,01bh			; seek, head load, 15 ms steps
	call TYPE1
	ld hl,T_CRLF
	call PUTS
	jp MAIN
KBAD:	ld hl,MSG_BAD
	call PUTS
	jp MAIN

; TYPE1: issue a Type I command and wait for it (timeout ~6 s: a restore
; that never finds track 0 takes 255 x 15 ms)
TYPE1:	call FCMD
	ld hl,0
	ld b,8
T1W:	in a,(FDCMD)
	rrca				; BUSY
	ret nc
	dec hl
	ld a,h
	or l
	jr nz,T1W
	djnz T1W
	ld a,0d0h
	call FCMD
	ld hl,T_CRLF
	call PUTS
	ld hl,MSG_TO
	jp PUTS

; FCMD: write a command and give the 1793 time before status is read
FCMD:	out (FDCMD),a
	ld b,40
FC1:	djnz FC1
	ret

; NEEDRDY: back to MAIN with a message unless the drive is ready
NEEDRDY:
	in a,(FDCMD)
	and 080h
	ret z
	pop hl
	ld hl,MSG_NRDY
	call PUTS
	jp MAIN

; ---- A: read the next sector ID --------------------------------------------------
KADDR:	call NEEDRDY
	ld hl,MSG_ADDR
	call PUTS
	ld hl,SECBUF
	ld e,SECCAP
	ld a,0c4h			; read address, 15 ms settle
	call XFERIN
	jr nz,KA2
	ld hl,SECBUF			; track side sector size crc crc
	ld b,6
KA1:	ld a,(hl)
	call PUTHEX
	ld a,' '
	call CONOUT
	inc hl
	djnz KA1
	ld hl,MSG_ADDROK
	call PUTS
	jp MAIN
KA2:	call PERR
	jp MAIN

; ---- R: read one sector and dump it ------------------------------------------------
KREAD:	call NEEDRDY
	ld hl,MSG_RSEC
	call PUTS
	call GETDEC2
	jp c,KBAD
	out (FDSEC),a
	ld hl,SECBUF
	ld e,SECCAP
	ld a,08ch			; read sector, 15 ms settle
	call XFERIN
	push af
	ld de,SECBUF
	or a
	sbc hl,de			; bytes received
	ld b,h
	ld c,l
	pop af
	push bc
	ld hl,MSG_OK2
	call z,PUTS
	call nz,PERR
	pop bc
	ld hl,SECBUF
	call DUMP
	ld hl,T_CRLF
	call PUTS
	jp MAIN

; DUMP: hex + ASCII dump of BC bytes at HL, 16 per line
DUMP:	ld de,0				; offset
DU0:	ld a,b
	or c
	ret z
	ld a,0dh
	call CONOUT
	ld a,0ah
	call CONOUT
	ld a,d
	call PUTHEX
	ld a,e
	call PUTHEX
	ld a,':'
	call CONOUT
	push hl
	push bc
	ld b,16
DU1:	ld a,' '
	call CONOUT
	ld a,(hl)
	call PUTHEX
	inc hl
	djnz DU1
	pop bc
	pop hl
	ld a,' '
	call CONOUT
	push bc
	ld b,16
DU2:	ld a,(hl)
	cp 020h
	jr c,DU3
	cp 07fh
	jr c,DU4
DU3:	ld a,'.'
DU4:	call CONOUT
	inc hl
	djnz DU2
	pop bc
	ld a,e
	add a,16
	ld e,a
	jr nc,DU5
	inc d
DU5:	ld a,c
	sub 16
	ld c,a
	ld a,b
	sbc a,0
	ld b,a
	ret c				; fewer than 16 were left
	jr DU0

; ---- V: read all sectors of this track -----------------------------------------
KVERIFY:
	call NEEDRDY
	ld hl,MSG_VER
	call PUTS
	call READALL
	jp MAIN

; READALL: read sectors 1-26: '.' good, 'R' not found, 'C' CRC error,
; 'L' lost data, 'T' timeout, '?' other, 'P' read OK but pattern wrong
; (only when PATCHK is set). Then the count and the last error. A key
; stops it early (a blank track takes ~22 s: 0.8 s per missing sector).
READALL:
	xor a
	ld (GOOD),a
	ld (LASTERR),a
	inc a
	ld (CURSEC),a
RA1:	ld a,(CURSEC)
	out (FDSEC),a
	ld hl,SECBUF
	ld e,SECCAP
	ld a,08ch			; read sector, 15 ms settle
	call XFERIN
	jr nz,RA3
	ld a,(PATCHK)
	or a
	jr z,RA2
	call CHKPAT
	ld a,'P'
	jr nz,RA4
RA2:	ld hl,GOOD
	inc (hl)
	ld a,'.'
	jr RA4
RA3:	ld (LASTERR),a
	ld b,a
	ld a,'T'
	inc b
	jr z,RA4			; FFh = timeout
	dec b
	ld a,'R'
	bit 4,b
	jr nz,RA4
	ld a,'C'
	bit 3,b
	jr nz,RA4
	ld a,'L'
	bit 2,b
	jr nz,RA4
	ld a,'?'
RA4:	call CONOUT
	in a,(CONST_P)			; any key stops the pass
	and 002h
	jr z,RA5
	call CONIN
	jr RA6
RA5:	ld hl,CURSEC
	inc (hl)
	ld a,(hl)
	cp NSEC+1
	jr c,RA1
RA6:
	ld hl,MSG_GOOD
	call PUTS
	ld a,(GOOD)
	call PUTDEC
	ld hl,MSG_OF26
	call PUTS
	ld a,(LASTERR)
	or a
	ret z
	ld hl,MSG_LAST
	call PUTS
	ld a,(LASTERR)
	jp PERR

; ---- T: format + write + verify this track ---------------------------------------
KTEST:	call NEEDRDY
	in a,(FDCMD)
	and 040h
	jr z,KT0
	ld hl,MSG_WP
	call PUTS
	jp MAIN
KT0:	ld hl,MSG_ASK
	call PUTS
	call CONIN
	and 05fh
	cp 'Y'
	jr z,KT1
	ld hl,MSG_CANCEL
	call PUTS
	jp MAIN
KT1:	ld hl,MSG_FMT
	call PUTS
	call BUILDTRK
	ld hl,TRKBUF
	ld e,TRKCAP
	ld a,0f4h			; write track, 15 ms settle
	call XFEROUT
	jr z,KT2
	call PERR
	jp MAIN
KT2:	ld hl,MSG_OK
	call PUTS
	ld hl,MSG_WR			; every sector gets its own pattern
	call PUTS
	xor a
	ld (LASTERR),a
	inc a
	ld (CURSEC),a
KT3:	call MKPAT
	ld a,(CURSEC)
	out (FDSEC),a
	ld hl,SECBUF
	ld e,SECCAP
	ld a,0ach			; write sector, 15 ms settle
	call XFEROUT
	jr z,KT3A
	ld (LASTERR),a
	ld a,'W'
	jr KT4
KT3A:	ld a,'.'
KT4:	call CONOUT
	ld hl,CURSEC
	inc (hl)
	ld a,(hl)
	cp NSEC+1
	jr c,KT3
	ld a,(LASTERR)
	or a
	jr z,KT5
	ld hl,T_CRLF
	call PUTS
	ld hl,MSG_LAST
	call PUTS
	ld a,(LASTERR)
	call PERR
KT5:	ld hl,MSG_VER
	call PUTS
	ld a,1
	ld (PATCHK),a
	call READALL
	xor a
	ld (PATCHK),a
	jp MAIN

; ---- K: Read Track - raw bytes from index to index, counts + first 256 -------
; Shows what is physically on the track even when no sector can be found:
; a good IBM track has runs of FF and 00 gaps, FE/FB marks and E5 fill;
; a track with no usable recording reads as noise.
KTRACK:	call NEEDRDY
	ld hl,MSG_RTRK
	call PUTS
	ld hl,TRKBUF
	ld e,TRKCAP
	ld a,0e4h			; read track, 15 ms settle
	call XFERIN
	push af
	ld de,TRKBUF
	or a
	sbc hl,de			; bytes received
	ld (KTLEN),hl
	call PUTDEC16
	ld hl,MSG_BYTES
	call PUTS
	pop af
	call nz,PERR
	ld hl,T_CRLF
	call PUTS
	ld a,0ffh			; how many FF, 00, E5
	call KCOUNT
	ld a,000h
	call KCOUNT
	ld a,0e5h
	call KCOUNT
	ld hl,(KTLEN)
	ld bc,256
	or a
	sbc hl,bc
	ld b,h
	ld c,l
	ld hl,(KTLEN)
	jr c,KT9			; fewer than 256 bytes
	ld bc,256
	jr KT8
KT9:	ld b,h
	ld c,l
KT8:	ld hl,TRKBUF
	call DUMP
	ld hl,T_CRLF
	call PUTS
	jp MAIN

; KCOUNT: print "xx:nnnn  " = how many bytes equal to A in the track buffer
KCOUNT:	ld (KVAL),a
	call PUTHEX
	ld a,':'
	call CONOUT
	ld hl,TRKBUF
	ld bc,(KTLEN)
	ld de,0
KC1:	ld a,b
	or c
	jr z,KC3
	ld a,(KVAL)
	cp (hl)
	jr nz,KC2
	inc de
KC2:	inc hl
	dec bc
	jr KC1
KC3:	ex de,hl
	call PUTDEC16
	ld hl,MSG_SP2
	jp PUTS

; ---- C: head cleaning sweep --------------------------------------------------
; With a cleaning disk in: heads loaded, zig-zag across tracks 0-76 and back
; (two steps in, one back), lingering ~0.1 s at each stop. Two passes,
; about 30 s; any key stops early. Reads and writes nothing.
KCLEAN:	call NEEDRDY
	ld hl,MSG_CLN
	call PUTS
	call CONIN
	and 05fh
	cp 'Y'
	jr z,KCL0
	ld hl,MSG_CANCEL
	call PUTS
	jp MAIN
KCL0:	ld hl,MSG_CLN2
	call PUTS
	ld a,00bh			; restore, head loaded
	call TYPE1
	ld a,2
	ld (CPASS),a
KCL1:	ld hl,ZIGTAB
KCL2:	ld a,(hl)
	cp 0ffh
	jr z,KCL4
	push hl
	out (FDDAT),a
	ld a,01bh			; seek, head loaded, 15 ms steps
	call TYPE1
	call LINGER
	pop hl
	jr nz,KCL8			; key pressed
	ld a,'.'
	call CONOUT
	inc hl
	jr KCL2
KCL4:	ld a,' '
	call CONOUT
	ld a,(CPASS)
	dec a
	ld (CPASS),a
	jr nz,KCL1
	jr KCL9
KCL8:	call CONIN			; swallow the key
KCL9:	ld a,00bh			; back to track 0
	call TYPE1
	ld hl,MSG_CLN3
	call PUTS
	jp MAIN

; LINGER: about 0.1 s (from the measured clock). NZ if a key was pressed.
LINGER:	ld hl,(CALT)			; 400-T ticks per 200 ms
	srl h
	rr l
LG1:	in a,(CONST_P)
	and 002h
	ret nz
	ld b,28
LG2:	djnz LG2
	dec hl
	ld a,h
	or l
	jr nz,LG1
	ret

ZIGTAB:
	defb 8,4,12,8,16,12,20,16,24,20,28,24,32,28,36,32
	defb 40,36,44,40,48,44,52,48,56,52,60,56,64,60,68,64
	defb 72,68,76,72,76,68,72,64,68,60,64,56,60,52,56,48
	defb 52,44,48,40,44,36,40,32,36,28,32,24,28,20,24,16
	defb 20,12,16,8,12,4,8,0,4,0
	defb 0ffh

; ---- W: format this track over and over, for a scope on the write lines -------
; One '.' per format ('E' on an error); any key stops.
KLOOP:	call NEEDRDY
	in a,(FDCMD)
	and 040h
	jr z,KL0
	ld hl,MSG_WP
	call PUTS
	jp MAIN
KL0:	ld hl,MSG_ASKL
	call PUTS
	call CONIN
	and 05fh
	cp 'Y'
	jr z,KL1
	ld hl,MSG_CANCEL
	call PUTS
	jp MAIN
KL1:	ld hl,MSG_LOOP
	call PUTS
	call BUILDTRK
KL2:	ld hl,TRKBUF
	ld e,TRKCAP
	ld a,0f4h
	call XFEROUT
	ld a,'.'
	jr z,KL3
	ld a,'E'
KL3:	call CONOUT
	in a,(CONST_P)
	and 002h
	jr z,KL2
	call CONIN
	ld hl,T_CRLF
	call PUTS
	jp MAIN

; ---- data transfers: status polling only, never the FCh wait port ---------------
; In:  A = command, HL = buffer, E = page where the transfer must stop.
; Out: Z = OK.  NZ: A = 1793 status, FFh timeout, FEh too much data.
; XFERIN leaves HL just past the last byte. Worst-case response to DRQ is
; about 95 T (24 us at 4 MHz); single density gives 32 us per byte.
XFERIN:	call XSETUP
XI1:	in a,(FDCMD)			; 11
	rrca				; 4   BUSY -> carry
	jr nc,XENDI			; 7
	rrca				; 4   DRQ -> carry
	jr c,XI2			; 7
	djnz XI1			; 13  = 46 T per poll
	dec d
	jp nz,XI1
	dec e
	jp nz,XI1
	jr XTO
XI2:	in a,(FDDAT)
	ld (hl),a
	inc hl
	ld a,(XLAST)
	cp h
	jp nc,XI1
	jr XOVF

; XFEROUT keeps the next byte ready in A' so it goes out 3 T sooner
XFEROUT:
	ex af,af'
	ld a,(hl)
	inc hl
	ex af,af'
	call XSETUP
XO1:	in a,(FDCMD)
	rrca
	jr nc,XENDO
	rrca
	jr c,XO2
	djnz XO1
	dec d
	jp nz,XO1
	dec e
	jp nz,XO1
	jr XTO
XO2:	ex af,af'
	out (FDDAT),a
	ld a,(hl)
	inc hl
	ex af,af'
	ld a,(XLAST)
	cp h
	jp nc,XO1
	jr XOVF

XSETUP:	push af
	ld a,e
	dec a
	ld (XLAST),a			; last page the buffer may use
	pop af
	call FCMD			; also leaves B = 0
	ld de,0005h			; 5 x 256 x 256 polls, ~4 s
	ret
XENDI:	in a,(FDCMD)			; read: NRDY RNF CRC LOST
	and 09ch
	jr XEND
XENDO:	in a,(FDCMD)			; write: NRDY WP WF RNF CRC LOST
	and 0fch
XEND:	push af
	ld a,0d0h			; status register back to Type I
	call FCMD
	pop af
	or a
	ret
XTO:	ld a,0d0h
	call FCMD
	ld a,0ffh
	or a
	ret
XOVF:	ld a,0d0h
	call FCMD
	ld a,0feh
	or a
	ret

; PERR: explain an XFERIN / XFEROUT result in A
PERR:	ld hl,MSG_TO
	cp 0ffh
	jp z,PUTS
	ld hl,MSG_OVF
	cp 0feh
	jp z,PUTS
	ld c,a
	ld hl,MSG_ERR
	call PUTS
	ld a,c
	call PUTHEX
	ld hl,T_NR2
	bit 7,c
	call nz,PUTS
	ld hl,T_WPE
	bit 6,c
	call nz,PUTS
	ld hl,T_WF
	bit 5,c
	call nz,PUTS
	ld hl,T_RNF
	bit 4,c
	call nz,PUTS
	ld hl,T_CRC
	bit 3,c
	call nz,PUTS
	ld hl,T_LOST
	bit 2,c
	call nz,PUTS
	ld hl,T_CRLF
	jp PUTS

; ---- IBM 3740 track image for the current track ------------------------------------
BUILDTRK:
	ld hl,TRKBUF
	ld bc,40*256+0ffh		; gap 4a
	call FILL
	ld bc,6*256+000h
	call FILL
	ld (hl),0fch			; index mark
	inc hl
	ld bc,26*256+0ffh		; gap 1
	call FILL
	ld e,1				; sector number
BT1:	ld bc,6*256+000h
	call FILL
	ld (hl),0feh			; ID address mark
	inc hl
	in a,(FDTRK)
	ld (hl),a			; track
	inc hl
	ld (hl),0			; side
	inc hl
	ld (hl),e			; sector
	inc hl
	ld (hl),0			; size 0 = 128 bytes
	inc hl
	ld (hl),0f7h			; write ID CRC
	inc hl
	ld bc,11*256+0ffh		; gap 2
	call FILL
	ld bc,6*256+000h
	call FILL
	ld (hl),0fbh			; data address mark
	inc hl
	ld bc,128*256+0e5h
	call FILL
	ld (hl),0f7h			; write data CRC
	inc hl
	ld bc,27*256+0ffh		; gap 3
	call FILL
	inc e
	ld a,e
	cp NSEC+1
	jr c,BT1
	ld bc,TRKBUF+TRKLEN		; gap 4b: FF to the end of the buffer;
BT2:	ld (hl),0ffh			; the 1793 stops at the index pulse
	inc hl
	ld a,l
	cp c
	jr nz,BT2
	ld a,h
	cp b
	jr nz,BT2
	ret
FILL:	ld (hl),c
	inc hl
	djnz FILL
	ret

; ---- test pattern: byte i of sector s on track t = t*7 + s*13 + i -------------------
MKPAT:	call PATSEED
	ld hl,SECBUF
	ld b,128
MP1:	ld (hl),a
	inc a
	inc hl
	djnz MP1
	ret
CHKPAT:	call PATSEED			; Z = matches
	ld hl,SECBUF
	ld b,128
CP1:	cp (hl)
	ret nz
	inc a
	inc hl
	djnz CP1
	xor a
	ret
PATSEED:
	in a,(FDTRK)
	ld b,a
	add a,a
	add a,a
	add a,a
	sub b				; t*7
	ld b,a
	ld a,(CURSEC)
	ld c,a
	add a,a
	add a,c
	add a,a
	add a,a
	add a,c				; s*13
	add a,b
	ret

; ---- number I/O -------------------------------------------------------------------------
; GETDEC2: two decimal digits (echoed) -> A. CY if anything else is typed.
GETDEC2:
	call GDIG
	ret c
	ld b,a
	add a,a
	add a,a
	add a,b
	add a,a				; x10
	ld b,a
	call GDIG
	ret c
	add a,b
	or a
	ret
GDIG:	call CONIN
	cp '0'
	jr c,GD9
	cp '9'+1
	jr nc,GD9
	call CONOUT
	sub '0'
	ret
GD9:	scf
	ret

; PUTDEC: print A (0-255) in decimal, at least two digits
PUTDEC:	push bc
	ld c,a
	cp 100
	jr c,PD1
	ld b,'0'-1
PD0:	inc b
	sub 100
	jr nc,PD0
	add a,100
	ld c,a
	ld a,b
	call CONOUT
	ld a,c
PD1:	ld b,'0'-1
PD2:	inc b
	sub 10
	jr nc,PD2
	add a,10+'0'
	ld c,a
	ld a,b
	call CONOUT
	ld a,c
	call CONOUT
	pop bc
	ret

; PUTDEC16: print HL in decimal, no leading zeros
PUTDEC16:
	push bc
	push de
	ld e,0
	ld bc,-10000
	call P16D
	ld bc,-1000
	call P16D
	ld bc,-100
	call P16D
	ld bc,-10
	call P16D
	ld a,l
	add a,'0'
	call CONOUT
	pop de
	pop bc
	ret
P16D:	ld a,'0'-1
P16A:	inc a
	add hl,bc
	jr c,P16A
	sbc hl,bc			; undo the last step (carry is clear)
	cp '0'
	jr nz,P16B
	bit 0,e
	ret z				; leading zero
P16B:	ld e,1
	jp CONOUT

; ---- text ------------------------------------------------------------------------------
MSG_HELP:
	defb 0dh,0ah,"FDTEST: 8in single density, FD1793 at F8h"
	defb 0dh,0ah,"Z restore  I/O step in/out  S seek  A read ID"
	defb 0dh,0ah,"R read+dump sector  V read track  K raw track dump"
	defb 0dh,0ah,"T FORMAT+write+verify this track  W format in a loop (scope)"
	defb 0dh,0ah,"C head cleaning sweep  ? help  Q quit",0dh,0ah,0
MSG_BYE:	defb 0dh,0ah,"FDTEST done",0
MSG_CLK:	defb "CPU clock ",0
MSG_KHZ:	defb " kHz (measured against the console at 9600 baud)",0dh,0ah,0
MSG_TO:		defb "timeout",0dh,0ah,0
MSG_OVF:	defb "too much data",0dh,0ah,0
MSG_NRDY:	defb 0dh,0ah,"Drive not ready (disk in, door shut, spinning?)",0dh,0ah,0
MSG_SEEK:	defb 0dh,0ah,"Seek to track (00-76): ",0
MSG_RSEC:	defb 0dh,0ah,"Read sector (01-26): ",0
MSG_BAD:	defb " ?",0dh,0ah,0
MSG_ADDR:	defb 0dh,0ah,"ID: ",0
MSG_ADDROK:	defb " (trk side sec size crc crc)",0dh,0ah,0
MSG_VER:	defb 0dh,0ah,"Read:   ",0
MSG_GOOD:	defb "  good: ",0
MSG_OF26:	defb "/26",0dh,0ah,0
MSG_LAST:	defb "Last",0
MSG_WP:		defb 0dh,0ah,"Disk is write protected",0dh,0ah,0
MSG_ASK:	defb 0dh,0ah,"FORMAT this track (erases it)? Y/N ",0
MSG_CANCEL:	defb "cancelled",0dh,0ah,0
MSG_CLN:	defb 0dh,0ah,"Head cleaning sweep: cleaning disk in? Y/N ",0
MSG_CLN2:	defb 0dh,0ah,"Sweeping, any key stops: ",0
MSG_CLN3:	defb 0dh,0ah,"Sweep done, back on track 0",0dh,0ah,0
MSG_RTRK:	defb 0dh,0ah,"Read track: ",0
MSG_BYTES:	defb " bytes",0
MSG_SP2:	defb "   ",0
MSG_ASKL:	defb 0dh,0ah,"FORMAT this track repeatedly (erases it)? Y/N ",0
MSG_LOOP:	defb 0dh,0ah,"Formatting, any key stops: ",0
MSG_FMT:	defb 0dh,0ah,"Format: ",0
MSG_OK:		defb "OK",0
MSG_OK2:	defb "  OK",0
MSG_WR:		defb 0dh,0ah,"Write:  ",0
MSG_ERR:	defb "  error, status ",0
T_NR2:		defb " not-ready",0
T_WPE:		defb " write-protected",0
T_WF:		defb " write-fault",0
T_RNF:		defb " not-found",0
T_CRC:		defb " CRC",0
T_LOST:		defb " lost-data",0
T_CRLF:		defb 0dh,0ah,0
T_ST:	defb "ST=",0
T_TRK:	defb " TRK=",0
T_RDY:	defb " READY",0
T_NRDY:	defb " not-ready",0
T_WP:	defb " WPROT",0
T_HLD:	defb " HEAD",0
T_TK0:	defb " TK0",0
T_SKE:	defb " SEEKERR",0
T_MS:	defb " ms ",0
T_RPM:	defb " rpm",0
T_NOIDX: defb "no index",0
T_FAST:	defb "index too fast (hard-sectored?)",0
T_PAD:	defb "      ",0

CURSEC:	defb 0
GOOD:	defb 0
PATCHK:	defb 0
LASTERR: defb 0
XLAST:	defb 0
KTLEN:	defw 0
CPASS:	defb 0
KVAL:	defb 0
CALT:	defw 2000
K15:	defw 32768
