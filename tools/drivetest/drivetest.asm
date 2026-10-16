;=======================================================================
; DRIVETEST - MiniScribe / XCOMP ST/S exerciser for MCPMON 2.0
;
; Shows the drive status live and lets you select the drive, pick a head
; and step the heads. Uses only the drive ports 60h-63h: it never starts
; the controller's microcode, so it cannot write to the disk.
;
; Load with MCPMON:  H  (send drivetest.hex),  then  G:0100 <CR>
;
; Keys: S select on/off   0-3 head   Z restore to track 0
;       I / O step in / out one cylinder   W sweep 0 <-> 200 (any key stops)
;       ? help   Q (or ESC, ^C) quit to the monitor
;=======================================================================
WARM:	equ 0f803h
CONIN:	equ 0f809h
CONOUT:	equ 0f80ch
PUTS:	equ 0f818h
PUTHEX:	equ 0f81bh

CONST_P: equ 003h			; console 8251 status (bit 1 = key waiting)
DSTAT:	equ 060h			; in: drive status   out: drive commands
DEXT:	equ 061h			; out: extended drive commands  in: clear index
SCLO:	equ 062h			; seek count LSB
SCHI:	equ 063h			; seek count MSB
CCMD:	equ 064h			; controller commands (only ever 00h here)

MAXCYL:	equ 479				; MiniScribe 4020: cylinders 0-479
SWEEP:	equ 200

	org 0100h

START:	xor a
	out (CCMD),a			; controller idle; START is never used
	ld a,002h
	out (DSTAT),a			; ENABLE INTERFACE
	ld a,041h			; DRIVE SELECT + inhibit precomp (as the ROM)
	ld (DEXTV),a
	out (DEXT),a
	ld hl,0ffffh
	ld (CYL),hl			; position unknown until a restore
	in a,(DEXT)			; clear the index latch
	ld hl,MSG_HELP
	call PUTS

; ---- main loop: poll for about a second, counting index pulses ----------
MAIN:	ld hl,0
	ld (IDXN),hl
	ld de,0				; 65536 polls
WIN:	in a,(DSTAT)
	and 020h			; INDEX latched?
	jr z,W1
	in a,(DEXT)			; clear it and count
	ld hl,(IDXN)
	inc hl
	ld (IDXN),hl
W1:	in a,(CONST_P)
	and 002h
	jp nz,KEY
	dec de
	ld a,d
	or e
	jr nz,WIN
	call SHOW
	jr MAIN

; ---- status line, redrawn in place --------------------------------------
SHOW:	ld a,0dh
	call CONOUT
	in a,(DSTAT)
	ld c,a
	ld hl,T_ST
	call PUTS
	ld a,c
	call PUTHEX
	ld a,c
	and 010h			; DRIVE SELECTED/ (low = selected)
	ld hl,T_SEL
	call FLAGLO
	ld a,c
	and 001h			; READY
	ld hl,T_RDY
	call FLAGHI
	ld a,c
	and 004h			; TRACK 00
	ld hl,T_TK0
	call FLAGHI
	ld a,c
	and 080h			; SEEK END
	ld hl,T_SKE
	call FLAGHI
	ld a,c
	and 008h			; SEEKING/ (low = seeking)
	ld hl,T_SKG
	call FLAGLO
	ld a,c
	and 002h			; WRITE FAULT
	ld hl,T_FLT
	call FLAGHI
	ld hl,T_IDX
	call PUTS
	ld hl,(IDXN)
	call PUTHL
	ld hl,T_CYL
	call PUTS
	ld hl,(CYL)
	ld a,h
	and l
	inc a
	jr nz,SH1
	ld hl,T_UNK			; FFFF = unknown
	call PUTS
	jr SH2
SH1:	call PUTHL
SH2:	ld hl,T_HD
	call PUTS
	ld a,(DEXTV)
	rrca
	rrca
	and 007h
	add a,'0'
	call CONOUT
	ld a,(DEXTV)
	and 001h
	ld hl,T_SELON
	jr nz,SH3
	ld hl,T_SELOFF
SH3:	jp PUTS

FLAGLO:	jr z,FPUT			; active when the bit is clear
FOFF:	ld hl,T_OFF
FPUT:	jp PUTS
FLAGHI:	jr nz,FPUT			; active when the bit is set
	jr FOFF

PUTHL:	ld a,h
	call PUTHEX
	ld a,l
	jp PUTHEX

CRLF:	ld a,0dh
	call CONOUT
	ld a,0ah
	jp CONOUT

; ---- keys ----------------------------------------------------------------
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
	cp 003h
	jp z,QUIT
	cp 'S'
	jr z,KSEL
	cp 'Z'
	jp z,KZERO
	cp 'I'
	jp z,KIN
	cp 'O'
	jp z,KOUT
	cp 'W'
	jp z,KSWEEP
	cp '?'
	jr z,KHELP
	cp '0'
	jp c,MAIN
	cp '4'
	jp nc,MAIN
	sub '0'				; head 0-3 -> bits 2-4
	rlca
	rlca
	ld b,a
	ld a,(DEXTV)
	and 0e3h
	or b
	ld (DEXTV),a
	out (DEXT),a
	jp MAIN

KHELP:	ld hl,MSG_HELP
	call PUTS
	jp MAIN

KSEL:	ld a,(DEXTV)
	xor 001h
	ld (DEXTV),a
	out (DEXT),a
	jp MAIN

QUIT:	xor a
	out (DEXT),a			; deselect
	out (DSTAT),a
	call CRLF
	jp WARM

; NEEDSEL: back to MAIN with a message unless the drive is selected
NEEDSEL:
	in a,(DSTAT)
	and 010h
	ret z
	pop hl
	ld hl,MSG_NOSEL
	call PUTS
	jp MAIN

; NEEDCYL: back to MAIN with a message unless the position is known
NEEDCYL:
	ld hl,(CYL)
	ld a,h
	and l
	inc a
	ret nz
	pop hl
	ld hl,MSG_NOCYL
	call PUTS
	jp MAIN

; ---- Z: restore to track 0 (same sequence as the boot ROM) --------------
KZERO:	call NEEDSEL
	ld hl,MSG_REST
	call PUTS
	ld a,002h
	out (DSTAT),a			; SEEK off
	ld a,(DEXTV)
	and 0fdh			; direction out
	ld (DEXTV),a
	out (DEXT),a
	ld a,0ffh			; seek count 01FFh
	out (SCLO),a
	ld a,001h
	out (SCHI),a
	ld a,003h			; SEEK + ENABLE INTERFACE
	out (DSTAT),a
	ld hl,0
	ld d,10
KZ1:	in a,(DSTAT)
	and 004h			; TRACK 00?
	jr nz,KZ2
	dec hl
	ld a,h
	or l
	jr nz,KZ1
	dec d
	jr nz,KZ1
	xor a				; timeout: clear the count
	out (SCHI),a
	out (SCLO),a
	ld a,002h
	out (DSTAT),a
	ld hl,MSG_FAIL
	call PUTS
	jp MAIN
KZ2:	xor a				; at track 0: clear the count
	out (SCHI),a
	out (SCLO),a
	call WAITSKE
	ld a,002h
	out (DSTAT),a
	ld hl,0
	ld (CYL),hl
	ld hl,MSG_OK
	call PUTS
	jp MAIN

; ---- I / O: one cylinder in / out ----------------------------------------
KIN:	call NEEDSEL
	call NEEDCYL
	ld hl,(CYL)
	ld de,MAXCYL
	or a
	sbc hl,de
	jp nc,MAIN			; already at the last cylinder
	ld hl,1
	ld b,002h
	call SEEKN
	jr nz,KTO
	ld hl,(CYL)
	inc hl
	ld (CYL),hl
	jp MAIN
KOUT:	call NEEDSEL
	call NEEDCYL
	ld hl,(CYL)
	ld a,h
	or l
	jp z,MAIN			; already at cylinder 0
	ld hl,1
	ld b,000h
	call SEEKN
	jr nz,KTO
	ld hl,(CYL)
	dec hl
	ld (CYL),hl
	jp MAIN
KTO:	ld hl,MSG_STO
	call PUTS
	jp MAIN

; ---- W: sweep between 0 and 200 until a key is pressed -------------------
KSWEEP:	call NEEDSEL
	call NEEDCYL
	ld hl,MSG_SWEEP
	call PUTS
SW1:	ld hl,(CYL)
	ld a,h
	or l
	jr nz,SW2
	ld hl,SWEEP			; at 0: go in to 200
	ld b,002h
	call SEEKN
	jr nz,SWTO
	ld hl,SWEEP
	ld (CYL),hl
	jr SW3
SW2:	ld b,000h			; elsewhere: go out to 0
	call SEEKN
	jr nz,SWTO
	ld hl,0
	ld (CYL),hl
SW3:	ld a,'.'
	call CONOUT
	in a,(CONST_P)
	and 002h
	jr z,SW1
	call CONIN
	call CRLF
	jp MAIN
SWTO:	ld hl,0ffffh			; position no longer trusted
	ld (CYL),hl
	jr KTO

; SEEKN: step HL cylinders, B = 02h in / 00h out. Z = done, NZ = timeout
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
	ld hl,4096			; let SEEK END drop (short timeout)
SK1:	in a,(DSTAT)
	rla
	jr nc,SK2
	dec hl
	ld a,h
	or l
	jr nz,SK1
SK2:	call WAITSKE
	push af
	ld a,002h
	out (DSTAT),a			; SEEK off
	pop af
	ret

; WAITSKE: wait for SEEK END. Z = seen, NZ = timeout
WAITSKE:
	ld hl,0
	ld d,10
WS1:	in a,(DSTAT)
	rla
	jr c,WS2
	dec hl
	ld a,h
	or l
	jr nz,WS1
	dec d
	jr nz,WS1
	or 1
	ret
WS2:	xor a
	ret

; ---- text ------------------------------------------------------------------
MSG_HELP:
	defb 0dh,0ah,"DRIVETEST: steps and selects only, never writes"
	defb 0dh,0ah,"S select on/off  0-3 head  Z restore to track 0"
	defb 0dh,0ah,"I/O step in/out  W sweep 0<->200 (any key stops)  Q quit"
	defb 0dh,0ah,"IDX = index pulses since the last update (disk turning)"
	defb 0dh,0ah,0
MSG_NOSEL:	defb 0dh,0ah,"Drive not selected",0dh,0ah,0
MSG_NOCYL:	defb 0dh,0ah,"Position unknown: restore first (Z)",0dh,0ah,0
MSG_REST:	defb 0dh,0ah,"Restore...",0
MSG_OK:		defb " OK",0dh,0ah,0
MSG_FAIL:	defb " FAILED (no track 0)",0dh,0ah,0
MSG_STO:	defb 0dh,0ah,"Seek timeout",0dh,0ah,0
MSG_SWEEP:	defb 0dh,0ah,"Sweeping, any key stops ",0
T_ST:	defb "ST=",0
T_SEL:	defb " SEL",0
T_RDY:	defb " RDY",0
T_TK0:	defb " TK0",0
T_SKE:	defb " SKE",0
T_SKG:	defb " SKG",0
T_FLT:	defb " FLT",0
T_OFF:	defb " ---",0
T_IDX:	defb "  IDX=",0
T_CYL:	defb " CYL=",0
T_UNK:	defb "????",0
T_HD:	defb " HD=",0
T_SELON:	defb " [sel on] ",0
T_SELOFF:	defb " [sel off]",0

DEXTV:	defb 0
CYL:	defw 0
IDXN:	defw 0
