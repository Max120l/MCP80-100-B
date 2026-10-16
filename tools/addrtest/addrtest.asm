;=======================================================================
; ADDRTEST - address line test for the MCP 80/100 memory card
; Runs from the CPU card's scratch RAM at F000h (not on the memory card),
; so memory card faults can't overwrite it. Needs MCPMON 2.0.
;
; Load with MCPMON:  H  (send addrtest.hex), then
;   G:F000 <CR>   one run of 256 passes, full table
;   G:F003 <CR>   loop until a key is pressed: '.' per clean block of 256
;                 passes, or a line listing what failed (for tap testing)
;
; For each address line A0-A15 and two base addresses (0000h, 6A55h):
;   self test : write 55h/AAh to base, read back
;   alias test: write 55h to base, AAh to base XOR line, read base
; 256 passes. Prints failure counts (hex, out of 0100) and the last bad
; byte read. A count between 0001 and 00FF means an intermittent fault.
;=======================================================================
WARM:	equ 0f803h
CONST:	equ 0f806h
CONIN:	equ 0f809h
CONOUT:	equ 0f80ch
PUTS:	equ 0f818h
PUTHEX:	equ 0f81bh

; Work area: in the CPU card RAM page MCPMON uses (F300h-F3FFh), above its
; variables (F300h-F30Ah) and well below its stack (top F3FFh). Not loaded
; from the HEX file; cleared at run time.
PASS:	equ 0f30ch
DOTS:	equ 0f30dh
CNT:	equ 0f310h			; 2 bases x 17 cells x 3 bytes
TBLEND:	equ CNT+102

	org 0f000h

	jp START			; F000  single run
	jp LOOP				; F003  loop mode

START:	ld hl,MSG_RUN
	call PUTS
	call RUN256
	jp REPORT

; ---- loop mode -----------------------------------------------------------
LOOP:	ld hl,MSG_LOOP
	call PUTS
	xor a
	ld (DOTS),a
LP1:	call RUN256
	call SUMMARY
	call CONST
	jr z,LP1
	call CONIN
	call CRLF
	jp WARM

; SUMMARY: '.' if the block was clean, else a line naming each failure
SUMMARY:
	ld ix,CNT
	ld b,34				; 2 bases x 17 cells
	xor a
SM1:	or (ix+0)
	or (ix+1)
	inc ix
	inc ix
	inc ix
	djnz SM1
	or a
	jr nz,SM3
	ld a,'.'			; clean block
	call CONOUT
	ld a,(DOTS)
	inc a
	ld (DOTS),a
	cp 64
	ret c
	xor a
	ld (DOTS),a
	jp CRLF
SM3:	xor a
	ld (DOTS),a
	call CRLF
	ld ix,CNT
	ld d,'0'			; base tag: 0 = 0000, 6 = 6A55
	call SMBASE
	ld ix,CNT+51
	ld d,'6'
	jp SMBASE
SMBASE:	ld c,0ffh			; cell index: FF = self, 0..15 = A0..A15
SB1:	ld a,(ix+0)
	or (ix+1)
	jr z,SB2
	ld a,c				; name
	inc a
	jr nz,SBA
	ld a,'S'
	call CONOUT
	jr SBT
SBA:	call LNAME
SBT:	ld a,'/'
	call CONOUT
	ld a,d
	call CONOUT
	ld a,'='
	call CONOUT
	ld a,(ix+1)
	call PUTHEX
	ld a,(ix+0)
	call PUTHEX
	ld a,' '
	call CONOUT
SB2:	inc ix
	inc ix
	inc ix
	inc c
	ld a,c
	cp 16
	jr nz,SB1
	ret

; LNAME: print "A" and line number C (0-15) in decimal
LNAME:	ld a,'A'
	call CONOUT
	ld a,c
	cp 10
	jr c,LN1
	ld a,'1'
	call CONOUT
	ld a,c
	sub 10
LN1:	add a,'0'
	jp CONOUT

; ---- 256 passes over both bases -------------------------------------------
RUN256:	ld hl,CNT			; clear counters and last-bad bytes
	ld bc,TBLEND-CNT
CLR:	ld (hl),0
	inc hl
	dec bc
	ld a,b
	or c
	jr nz,CLR
	xor a
	ld (PASS),a
PASSLP:	ld hl,00000h
	ld ix,CNT
	call ONEBASE
	ld hl,06a55h
	ld ix,CNT+51
	call ONEBASE
	ld a,(PASS)
	inc a
	ld (PASS),a
	jr nz,PASSLP
	ret

; ---- report ------------------------------------------------------------
REPORT:	ld hl,MSG_HDR
	call PUTS
	ld ix,CNT
	ld iy,CNT+51
	ld hl,MSG_SELF			; first row: self test
	call PUTS
	call ROW
	ld c,0				; then A0..A15
RPT:	call CRLF
	call LNAME
	ld a,c
	cp 10
	ld a,' '
	call c,CONOUT
	ld a,' '
	call CONOUT
	call CONOUT
	call ROW
	inc c
	ld a,c
	cp 16
	jr nz,RPT
	call CRLF
	jp WARM

; ROW: print counter at IX and IY (3 bytes each: count lo, hi, last bad),
; then advance both by 3
ROW:	call CELL
	inc ix
	inc ix
	inc ix
	push ix
	push iy
	pop ix
	call CELL
	inc ix
	inc ix
	inc ix
	push ix
	pop iy
	pop ix
	ret
CELL:	ld a,' '
	call CONOUT
	call CONOUT
	ld a,(ix+1)
	call PUTHEX
	ld a,(ix+0)
	call PUTHEX
	ld a,' '
	call CONOUT
	ld a,(ix+0)
	or (ix+1)
	jr z,CELL1
	ld a,(ix+2)
	jp PUTHEX
CELL1:	ld a,'-'
	call CONOUT
	jp CONOUT

CRLF:	ld a,0dh
	call CONOUT
	ld a,0ah
	jp CONOUT

; ---- one base: HL = base, IX -> 17 x 3-byte cells (self, A0..A15) ------
ONEBASE:
	ld (hl),055h			; self test
	ld a,(hl)
	cp 055h
	jr nz,OBSF
	ld (hl),0aah
	ld a,(hl)
	cp 0aah
	jr z,OBS2
OBSF:	call BUMP
OBS2:	inc ix
	inc ix
	inc ix
	ld de,00001h			; line mask
	ld b,16
OB1:	push bc
	ld a,h				; BC = partner = base XOR mask
	xor d
	ld b,a
	ld a,l
	xor e
	ld c,a
	ld (hl),055h
	ld a,0aah
	ld (bc),a
	ld a,(hl)
	cp 055h
	call nz,BUMP
	pop bc
	inc ix
	inc ix
	inc ix
	sla e
	rl d
	djnz OB1
	ret

BUMP:	ld (ix+2),a			; A = bad byte read
	inc (ix+0)
	ret nz
	inc (ix+1)
	ret

MSG_RUN:	defb 0dh,0ah,"ADDRTEST: 256 passes...",0
MSG_HDR:	defb 0dh,0ah,"fails/0100, last bad byte"
		defb 0dh,0ah,"      base 0000  base 6A55",0
MSG_SELF:	defb 0dh,0ah,"self ",0
MSG_LOOP:	defb 0dh,0ah,"ADDRTEST loop, any key stops. '.' = 256 clean passes"
		defb 0dh,0ah,"failures: line/base=count  (base 0 = 0000, 6 = 6A55)",0dh,0ah,0

CODEEND:
