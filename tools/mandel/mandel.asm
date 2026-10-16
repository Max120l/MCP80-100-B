;=======================================================================
; MANDEL - ASCII Mandelbrot set for the MCP 80/100 (needs MCPMON 2.0)
;
; Load with MCPMON:  H  (send mandel.hex),  then  G:0100 <CR>
; 72 x 24 characters, 8.8 fixed-point maths. Any key stops it.
;=======================================================================
WARM:	equ 0f803h
CONST:	equ 0f806h
CONIN:	equ 0f809h
CONOUT:	equ 0f80ch
PUTS:	equ 0f818h

COLS:	equ 72
ROWS:	equ 24
XSTART:	equ -544			; -2.125 in 8.8
XSTEP:	equ 10				;  0.039
YSTART:	equ -288			; -1.125
YSTEP:	equ 25				;  0.098
MAXIT:	equ 15

	org 0100h

START:	ld hl,MSG
	call PUTS
	ld hl,YSTART
	ld (CY),hl
	ld b,ROWS
ROW:	push bc
	ld hl,XSTART
	ld (CX),hl
	ld b,COLS
COL:	push bc
	call PIXEL			; A = iterations before escape
	ld e,a
	ld d,0
	ld hl,CHARS
	add hl,de
	ld a,(hl)
	call CONOUT
	ld hl,(CX)
	ld de,XSTEP
	add hl,de
	ld (CX),hl
	call CONST			; any key stops
	jr nz,ABORT
	pop bc
	djnz COL
	ld a,0dh
	call CONOUT
	ld a,0ah
	call CONOUT
	ld hl,(CY)
	ld de,YSTEP
	add hl,de
	ld (CY),hl
	pop bc
	djnz ROW
	jp WARM
ABORT:	call CONIN
	jp WARM				; MCPMON resets the stack

; PIXEL: iterate z = z^2 + c from 0; A = iteration count (MAXIT = inside)
PIXEL:	ld hl,0
	ld (ZX),hl
	ld (ZY),hl
	xor a
	ld (IT),a
PX1:	ld hl,(ZX)
	ld d,h
	ld e,l
	call MUL88
	ld (X2),hl
	ld hl,(ZY)
	ld d,h
	ld e,l
	call MUL88
	ld (Y2),hl
	ld de,(X2)
	add hl,de			; |z|^2
	ld de,0400h			; 4.0
	or a
	sbc hl,de
	jr nc,PX2			; escaped
	ld hl,(ZX)			; zy = 2 zx zy + cy
	ld de,(ZY)
	call MUL88
	add hl,hl
	ld de,(CY)
	add hl,de
	ld (ZY),hl
	ld hl,(X2)			; zx = zx^2 - zy^2 + cx
	ld de,(Y2)
	or a
	sbc hl,de
	ld de,(CX)
	add hl,de
	ld (ZX),hl
	ld a,(IT)
	inc a
	ld (IT),a
	cp MAXIT
	jr c,PX1
	ret
PX2:	ld a,(IT)
	ret

; MUL88: HL = HL * DE, signed 8.8 fixed point
MUL88:	ld a,h
	xor d
	push af				; sign of the result in bit 7
	bit 7,h
	call nz,NEGHL
	ex de,hl
	bit 7,h
	call nz,NEGHL
	ld b,h				; BC = |b|, DE = |a|
	ld c,l
	ld hl,0				; DE:HL = BC * DE
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
	ld l,h				; middle 16 bits = product >> 8
	ld h,e
	pop af
	bit 7,a
	ret z
NEGHL:	ld a,l
	cpl
	ld l,a
	ld a,h
	cpl
	ld h,a
	inc hl
	ret

MSG:	defb 0dh,0ah,"MCP 80/100 says hello. Mandelbrot, any key stops:",0dh,0ah,0
CHARS:	defb " .,:;-~=+*ox%#&@"

CX:	defw 0
CY:	defw 0
ZX:	defw 0
ZY:	defw 0
X2:	defw 0
Y2:	defw 0
IT:	defb 0
