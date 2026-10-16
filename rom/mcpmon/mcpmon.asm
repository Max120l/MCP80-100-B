;=======================================================================
; MCPMON 2.0 - replacement monitor for the MCP 80/100 (2 KB, F800h)
;
; Keeps the original monitor's commands (G D S F M B A L) and adds:
;   I  read a port          O  write a port        T  RAM test
;   H  Intel HEX load       X  Intel HEX dump      R  read a disk sector
;   ?  help
; Lowercase is accepted. ^C, ESC or DEL abort back to the prompt.
;
; Hard disk and floppy code follows the original ROM instruction for
; instruction where timing could matter (see ../mcp_boot.asm).
;
; Assemble: z80asm -i mcpmon.asm -o mcpmon.bin   (must be <= 2048 bytes)
;=======================================================================

; ---- I/O ports -------------------------------------------------------
SIO2_DATA:  equ 000h        ; second 8251 (transfer port)
SIO2_CTRL:  equ 001h
CON_DATA:   equ 002h        ; console 8251
CON_CTRL:   equ 003h
PPI_CTRL:   equ 007h        ; 8255 control
SHADOW_OFF: equ 00ah        ; read at reset (as in the original ROM)
HD_DRV:     equ 060h        ; HDC drive control / ST-506 status
HD_SEL:     equ 061h        ; HDC drive select
HD_STEPLO:  equ 062h        ; HDC step counter
HD_STEPHI:  equ 063h
HD_MODE:    equ 064h        ; HDC area select / GO / done+errors
HD_PTR:     equ 065h        ; HDC pointer
HD_DATA:    equ 066h        ; HDC data

; ---- RAM -------------------------------------------------------------
; The original ROM keeps its stack just below F400h, so that RAM is
; known to exist. The monitor uses F300h-F3FFh only.
STACK:      equ 0f400h
TSTART:     equ 0f300h      ; RAM test start (2)
TEND:       equ 0f302h      ; RAM test end (2)
TPAT:       equ 0f304h      ; RAM test pattern number
TERRS:      equ 0f305h      ; RAM test error count
IDBUF:      equ 0f306h      ; 4-byte sector ID for R
HXERR:      equ 0f30ah      ; HEX load error count
MONRAM:     equ 0f3h        ; high byte of the monitor's RAM page
HDBUFDST:   equ 08000h      ; where R puts the sector

	org 0f800h

;=======================================================================
; Entry points. Loaded programs should call these, not internal labels.
;=======================================================================
RESET:	jp COLD                 ; F800  also runs at 0000h after reset
	jp WARM                 ; F803  back to the monitor prompt
	jp CONST                ; F806  console status: NZ = char ready
	jp CONIN                ; F809  console in (7 bits) -> A
	jp CONOUT               ; F80C  console out <- A
	jp AUXST                ; F80F  transfer port status: NZ = ready
	jp AUXIN                ; F812  transfer port in (8 bits) -> A
	jp AUXOUT               ; F815  transfer port out <- A
	jp PUTS                 ; F818  print 0-terminated string at HL
	jp PUTHEX               ; F81B  print A as 2 hex digits
	jp HDINIT               ; F81E  load HDC tables, select, restore
	jp HDREAD               ; F821  read sector, ID at HL (4 bytes)
	jp HDGETBUF             ; F824  copy 256-byte HDC buffer to HL

;=======================================================================
; Cold start
;=======================================================================
COLD:	in a,(SHADOW_OFF)      ; same as the original ROM
	ld sp,STACK
	ld c,SIO2_CTRL
	call SIOINIT
	ld c,CON_CTRL
	call SIOINIT
	in a,(CON_DATA)         ; discard junk
	in a,(SIO2_DATA)
	ld a,0a2h               ; 8255 setup, same as the original ROM
	out (PPI_CTRL),a
	ld a,00bh
	out (PPI_CTRL),a
	ld hl,MSG_BANNER
	call PUTS

;=======================================================================
; Command loop
;=======================================================================
WARM:	ld sp,STACK
	ld hl,MSG_PROMPT
	call PUTS
	call GETCH
	cp 00dh                 ; empty line
	jr z,WARM
	ld b,a
	ld hl,CMDTAB
W1:	ld a,(hl)
	or a
	jr z,WBAD
	inc hl
	cp b
	jr z,W2
	inc hl
	inc hl
	jr W1
W2:	ld e,(hl)
	inc hl
	ld d,(hl)
	ld hl,WARM              ; handlers return to the prompt
	push hl
	ex de,hl
	jp (hl)
WBAD:	ld a,'?'
	call CONOUT
	jr WARM

CMDTAB:	defb 'G'
	defw CMD_G
	defb 'D'
	defw CMD_D
	defb 'S'
	defw CMD_S
	defb 'F'
	defw CMD_F
	defb 'M'
	defw CMD_M
	defb 'I'
	defw CMD_I
	defb 'O'
	defw CMD_O
	defb 'T'
	defw CMD_T
	defb 'H'
	defw CMD_H
	defb 'X'
	defw CMD_X
	defb 'R'
	defw CMD_R
	defb 'L'
	defw CMD_L
	defb 'B'
	defw CMD_B
	defb 'A'
	defw CMD_A
	defb '?'
	defw CMD_HELP
	defb 0

;=======================================================================
; 8251 setup: C = control port. Forces a clean reset (00 00 00 40h),
; then 8 data bits, no parity, 1 stop bit, x16 clock; RTS, DTR, RxE,
; TxEN, error reset.
;=======================================================================
SIOINIT:
	xor a
	call SIOW
	call SIOW
	call SIOW
	ld a,040h               ; internal reset
	call SIOW
	ld a,04eh               ; mode
	call SIOW
	ld a,037h               ; command
SIOW:	out (c),a               ; write, then give the 8251 recovery time
	push bc
	ld b,20
SIOW1:	djnz SIOW1
	pop bc
	ret

;=======================================================================
; Console and transfer port I/O
;=======================================================================
CONST:	in a,(CON_CTRL)
	and 002h
	ret
CONIN:	in a,(CON_CTRL)
	and 002h
	jr z,CONIN
	in a,(CON_DATA)
	and 07fh
	ret
CONOUT:	push af
CO1:	in a,(CON_CTRL)
	and 001h
	jr z,CO1
	pop af
	out (CON_DATA),a
	ret
AUXST:	in a,(SIO2_CTRL)
	and 002h
	ret
AUXIN:	in a,(SIO2_CTRL)
	and 002h
	jr z,AUXIN
	in a,(SIO2_DATA)
	ret
AUXOUT:	push af
AO1:	in a,(SIO2_CTRL)
	and 001h
	jr z,AO1
	pop af
	out (SIO2_DATA),a
	ret

; GETCH: read a key, abort on ^C / ESC / DEL, uppercase, echo.
GETCH:	call GETKEY
	jp CONOUT
GETKEY:	call CONIN
	cp 003h
	jp z,WARM
	cp 01bh
	jp z,WARM
	cp 07fh
	jp z,WARM
	cp 'a'
	jr c,GC1
	cp 'z'+1
	jr nc,GC1
	sub 020h
GC1:	ret

; BRKCHK: any key pressed aborts to the prompt
BRKCHK:	call CONST
	ret z
	call CONIN
	ld hl,MSG_BRK
	call PUTS
	jp WARM

;=======================================================================
; Output helpers (preserve everything except A, except PUTS: HL)
;=======================================================================
PUTS:	ld a,(hl)
	or a
	ret z
	call CONOUT
	inc hl
	jr PUTS
PUTHL:	ld a,h
	call PUTHEX
	ld a,l
PUTHEX:	push af
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
CRLF:	ld a,00dh
	call CONOUT
	ld a,00ah
	jp CONOUT
SPACE:	ld a,' '
	jp CONOUT

;=======================================================================
; Input helpers. A bad hex digit prints '?' and returns to the prompt.
;=======================================================================
HEXV:	cp 'a'                  ; A = ASCII hex digit -> 0-15
	jr c,HV1
	sub 020h                ; lowercase -> uppercase
HV1:	sub '0'
	jr c,BADIN
	cp 10
	ret c
	sub 7
	cp 10
	jr c,BADIN
	cp 16
	ret c
BADIN:	ld a,'?'
	call CONOUT
	jp WARM

GETNIB:	call GETKEY             ; ':' typed out of habit is ignored
	cp ':'
	jr z,GETNIB
	call CONOUT
	jr HEXV

GETB2:	push bc                 ; two hex digits -> A
	call GETNIB
	rlca
	rlca
	rlca
	rlca
	ld c,a
	call GETNIB
	or c
	pop bc
	ret

PARB:	ld a,':'                ; ':' + 2 hex digits -> A
	call CONOUT
	jr GETB2

PARW:	ld a,':'                ; ':' + 4 hex digits -> HL
	call CONOUT
	call GETB2
	ld h,a
	call GETB2
	ld l,a
	ret

PAR2W:	call PARW               ; two addresses: HL = first, DE = second
	push hl
	call PARW
	ex de,hl
	pop hl
RANGE:	push hl                 ; require HL <= DE
	or a
	sbc hl,de
	pop hl
	ret c
	ret z
	jr BADIN

CPHLDE:	ld a,h                  ; Z if HL = DE
	cp d
	ret nz
	ld a,l
	cp e
	ret

;=======================================================================
; G:aaaa<CR>  go
;=======================================================================
CMD_G:	call PARW
	call GETCH
	cp 00dh
	ret nz
	jp (hl)

;=======================================================================
; D:ssss:eeee  dump, 16 bytes + ASCII per line, any key stops
;=======================================================================
CMD_D:	call PAR2W
DL1:	call CRLF
	call PUTHL
	push hl
	ld b,16
DL2:	call SPACE
	ld a,(hl)
	call PUTHEX
	inc hl
	djnz DL2
	call SPACE
	call SPACE
	pop hl
	ld b,16
DL3:	ld a,(hl)
	cp 020h
	jr c,DL4
	cp 07fh
	jr c,DL5
DL4:	ld a,'.'
DL5:	call CONOUT
	inc hl
	djnz DL3
	ld a,h                  ; wrapped past FFFFh
	or l
	ret z
	call BRKCHK
	push hl
	or a
	sbc hl,de
	pop hl
	jr c,DL1
	jr z,DL1
	ret

;=======================================================================
; S:aaaa  substitute: shows bytes; hh = store, space = skip, CR = done.
; Prints '!' if the byte doesn't read back (ROM or bad RAM).
;=======================================================================
CMD_S:	call PARW
SB1:	ld a,l
	and 007h
	jr nz,SB2
	call CRLF
	call PUTHL
SB2:	call SPACE
	ld a,(hl)
	call PUTHEX
	ld a,'-'
	call CONOUT
	call GETCH
	cp ' '
	jr z,SB3
	cp 00dh
	ret z
	call HEXV
	rlca
	rlca
	rlca
	rlca
	ld c,a
	call GETNIB
	or c
	ld (hl),a
	cp (hl)
	jr z,SB3
	ld a,'!'
	call CONOUT
SB3:	inc hl
	jr SB1

;=======================================================================
; F:ssss:eeee:hh  fill
;=======================================================================
CMD_F:	call PAR2W
	call PARB
	ld c,a
FL1:	ld (hl),c
	call CPHLDE
	ret z
	inc hl
	jr FL1

;=======================================================================
; M:ssss:eeee:dddd  move (overlap-safe)
;=======================================================================
CMD_M:	call PAR2W              ; HL = src, DE = end
	push hl
	ex de,hl
	pop de                  ; HL = end, DE = src
	or a
	sbc hl,de
	inc hl                  ; HL = count
	push hl
	push de
	call PARW               ; HL = dst
	ex de,hl                ; DE = dst
	pop hl                  ; HL = src
	pop bc                  ; BC = count
	push hl
	or a
	sbc hl,de               ; carry if src < dst
	pop hl
	jr nc,MV1
	add hl,bc               ; copy backwards
	dec hl
	ex de,hl
	add hl,bc
	dec hl
	ex de,hl
	lddr
	ret
MV1:	ldir
	ret

;=======================================================================
; I:pp  read port      O:pp:vv  write port
;=======================================================================
CMD_I:	call PARB
	ld c,a
	in a,(c)
	push af
	ld a,'='
	call CONOUT
	pop af
	jp PUTHEX
CMD_O:	call PARB
	ld b,a
	call PARB
	ld c,b
	out (c),a
	ret

;=======================================================================
; T:ssss:eeee  RAM test: 00, FF, 55, AA, then address pattern.
; Refuses ranges touching F300h-F3FFh (monitor RAM). Any key stops.
;=======================================================================
CMD_T:	call PAR2W
	ld a,d                  ; end below F300h is fine
	cp MONRAM
	jr c,TS0
	ld a,h                  ; else start must be above F3FFh
	cp MONRAM+1
	jp c,BADIN
TS0:	ld (TSTART),hl
	ld (TEND),de
	xor a
	ld (TERRS),a
	ld (TPAT),a
TS1:	ld hl,(TSTART)          ; fill
	ld de,(TEND)
TS2:	call TVAL
	ld (hl),a
	call CPHLDE
	jr z,TS3
	inc hl
	jr TS2
TS3:	ld hl,(TSTART)          ; verify
TS4:	call TVAL
	cp (hl)
	call nz,TERR
	call CPHLDE
	jr z,TS5
	inc hl
	jr TS4
TS5:	ld a,'.'
	call CONOUT
	call BRKCHK
	ld a,(TPAT)
	inc a
	ld (TPAT),a
	cp 5
	jr c,TS1
	ld a,(TERRS)
	or a
	ld hl,MSG_OK
	jr z,TS6
	ld hl,MSG_FAIL
TS6:	jp PUTS

TVAL:	ld a,(TPAT)             ; expected byte for address HL
	cp 4
	jr nc,TV1
	push hl
	push de
	ld e,a
	ld d,0
	ld hl,TPATS
	add hl,de
	ld a,(hl)
	pop de
	pop hl
	ret
TV1:	ld a,l
	xor h
	ret
TPATS:	defb 000h,0ffh,055h,0aah

TERR:	push af                 ; A = expected, (HL) = what was read
	call CRLF
	call PUTHL
	call SPACE
	pop af
	call PUTHEX
	ld a,'/'
	call CONOUT
	ld a,(hl)
	call PUTHEX
	ld a,(TERRS)
	inc a
	ld (TERRS),a
	cp 8
	ret c
	ld hl,MSG_FAIL
	call PUTS
	jp WARM

;=======================================================================
; H  Intel HEX load from the console. Send the file from the terminal.
; Prints '.' per good record, 'E' per bad one. Ends at the EOF record.
; Don't load over F300h-F3FFh (monitor RAM).
;=======================================================================
CMD_H:	call CRLF
	xor a
	ld (HXERR),a
HX0:	call CONIN
	cp 003h                 ; ^C
	jp z,WARM
	cp 01bh                 ; ESC
	jp z,WARM
	cp ':'
	jr nz,HX0
	ld e,0                  ; checksum
	call HXB
	ld b,a                  ; count
	call HXB
	ld h,a
	call HXB
	ld l,a                  ; address
	call HXB
	ld c,a                  ; record type
	ld a,b
	or a
	jr z,HX3
HX1:	call HXB
	inc c                   ; type 00 = data, others ignored
	dec c
	jr nz,HX2
	ld (hl),a
	inc hl
HX2:	djnz HX1
HX3:	call HXB                ; checksum byte
	ld a,e
	or a
	ld a,'.'
	jr z,HX4
	ld a,(HXERR)
	inc a
	ld (HXERR),a
	ld a,'E'
HX4:	call CONOUT
	ld a,c
	cp 1                    ; EOF record
	jr nz,HX0
	ld a,(HXERR)
	or a
	ld hl,MSG_OK
	jr z,HX5
	ld hl,MSG_FAIL
HX5:	jp PUTS

HXB:	call CONIN              ; two hex chars -> A, added to E
	call HEXV
	rlca
	rlca
	rlca
	rlca
	ld d,a
	call CONIN
	call HEXV
	or d
	ld d,a
	add a,e
	ld e,a
	ld a,d
	ret

;=======================================================================
; X:ssss:eeee  Intel HEX dump to the console, 16 bytes per record
;=======================================================================
CMD_X:	call PAR2W
	call CRLF
XD1:	ld a,e                  ; BC = end - current
	sub l
	ld c,a
	ld a,d
	sbc a,h
	ld b,a
	or a
	jr nz,XD2
	ld a,c
	cp 15
	jr nc,XD2
	inc a
	jr XD3
XD2:	ld a,16
XD3:	ld b,a                  ; B = bytes in this record
	ld a,':'
	call CONOUT
	ld c,0                  ; checksum
	ld a,b
	call XHEX
	ld a,h
	call XHEX
	ld a,l
	call XHEX
	xor a
	call XHEX
XD4:	ld a,(hl)
	call XHEX
	inc hl
	djnz XD4
	ld a,c
	neg
	call PUTHEX
	call CRLF
	dec hl                  ; done when the last byte was the end
	call CPHLDE
	inc hl
	jr z,XD5
	call BRKCHK
	jr XD1
XD5:	ld hl,MSG_HEXEOF
	jp PUTS
XHEX:	push af
	add a,c
	ld c,a
	pop af
	jp PUTHEX

;=======================================================================
; R:iiiiiiii  read one hard disk sector by its 4-byte ID into 8000h.
; Uses only the read sequence the original boot ROM uses.
;=======================================================================
CMD_R:	ld a,':'
	call CONOUT
	ld hl,IDBUF
	ld b,4
RD1:	call GETB2
	ld (hl),a
	inc hl
	djnz RD1
	call HDINIT
	jr nz,RD3
	ld hl,IDBUF
	call HDREAD
	jr nz,RD2
	ld hl,HDBUFDST
	call HDGETBUF
	ld hl,MSG_RDOK
	jp PUTS
RD2:	push hl                 ; read failed: show error bits too
	ld a,' '
	call CONOUT
	ld a,b
	call PUTHEX
	pop hl
RD3:	jp PUTS

;=======================================================================
; L  boot from the hard disk (same behaviour as the original, but a
; key press after an error can also abort with ^C / ESC / DEL)
;=======================================================================
CMD_L:	call HDINIT
	jr nz,LB2
LB1:	ld hl,ZEROID
	call HDREAD
	jr nz,LB2
	ld hl,00000h
	call HDGETBUF
	ld sp,00100h            ; as the original ROM left it
	jp 00000h
LB2:	call PUTS
	call GETCH
	call CRLF
	jr LB1
ZEROID:	defb 0,0,0,0

;=======================================================================
; B / A  boot from floppy (controller at F8h, then 78h / only 78h).
; Reads track 0 sector 1 to 0000h and enters it at 007Dh.
;=======================================================================
CMD_B:	ld c,0f8h
	call FDBOOT
CMD_A:	ld c,078h
	call FDBOOT
	push af
	ld hl,MSG_FDERR
	call PUTS
	pop af
	jp PUTHEX

FDBOOT:	ld a,06bh               ; C = command/status port
	out (c),a               ; step out
	call FDWAIT
	in a,(c)
	and 004h                ; track 0?
	jr nz,FB1
	ld a,00bh               ; restore
	out (c),a
	call FDWAIT
	in a,(c)
FB1:	ld hl,00000h
	inc c                   ; sector register = base+2
	inc c
	ld a,001h
	out (c),a
	dec c
	dec c
	ld a,088h               ; read sector
	out (c),a
	inc c                   ; C = wait/status port (base+4)
	inc c
	inc c
	inc c
FB2:	in a,(c)
	or a
	jp p,FB3
	dec c                   ; data port (base+3)
	in a,(c)
	inc c
	ld (hl),a
	inc hl
	jp FB2
FB3:	dec c
	dec c
	dec c
	dec c
	in a,(c)                ; final status
	or a
	jp z,0007dh
	ret                     ; NZ, A = status

FDWAIT:	push bc                 ; read the board's wait port (base+4)
	ld a,c
	add a,4
	ld c,a
	in a,(c)
	pop bc
	ret

;=======================================================================
; Hard disk controller routines, ported from the original ROM.
; All return Z = OK, or NZ with HL = error message.
;=======================================================================
HDINIT:	xor a
	out (HD_MODE),a
	out (HD_DRV),a
	out (HD_SEL),a
	ld hl,HDTAB_A
	call HDLOADTAB
	ld hl,HDTAB_B
	call HDLOADTAB
	ld a,041h
	out (HD_SEL),a
	ld a,002h
	out (HD_DRV),a
	; fall into HDRESTORE

HDRESTORE:
	in a,(HD_DRV)
	and 004h
	xor 004h
	ret z                   ; already on track 0
	call HDCHKRDY
	ret nz
	ld a,0ffh
	out (HD_STEPLO),a
	ld a,001h
	out (HD_STEPHI),a
	ld a,001h
	out (HD_SEL),a
	ld a,003h
	out (HD_DRV),a
	ld hl,00000h
	ld b,00ah
HRS1:	in a,(HD_DRV)
	and 004h
	jp nz,HRS2
	dec hl
	ld a,h
	or l
	jp nz,HRS1
	dec b
	jp nz,HRS1
	out (HD_STEPHI),a
	out (HD_STEPLO),a
	ld hl,MSG_RESTFAIL
	or 001h
	ret
HRS2:	xor a
	out (HD_STEPHI),a
	out (HD_STEPLO),a
	call HDWAITSC
	xor a
	ret

; HDREAD: HL -> 4-byte target ID. On error B = error bits.
HDREAD:	ld d,00ah               ; tries
	ld a,004h               ; ID area, pointer EAh
	out (HD_MODE),a
	ld a,0eah
	out (HD_PTR),a
	ld b,004h
HR1:	ld a,(hl)
	out (HD_DATA),a
	inc hl
	dec b
	jp nz,HR1
HR2:	call HDCHKRDY
	ret nz
	xor a                   ; start the read sequence at D7h
	out (HD_MODE),a
	ld a,0d7h
	out (HD_PTR),a
	ld a,008h
	out (HD_MODE),a
	ld hl,00000h
HR3:	in a,(HD_MODE)
	rrca
	jp c,HR4
	dec hl
	ld a,h
	or l
	jp nz,HR3
	out (HD_MODE),a         ; timeout: stop
	jp HR6
HR4:	in a,(HD_MODE)
	and 00eh
	ld b,a
	xor a
	out (HD_MODE),a
	in a,(HD_DRV)
	and 002h
	call nz,HDCLRFLT        ; write fault: clear it, and retry
	or b
	ret z
	dec d
	jp nz,HR2
HR6:	ld hl,MSG_READFAIL
	or 001h
	ret

; HDGETBUF: copy the 256-byte buffer to HL (same loop as the original)
HDGETBUF:
	ld a,002h
	out (HD_MODE),a
	xor a
	out (HD_PTR),a
	ld b,a
	in a,(HD_DATA)          ; dummy read
	nop
HG1:	in a,(HD_DATA)
	ld (hl),a
	inc hl
	dec b
	jp nz,HG1
	ret

HDWAITSC:
	ld hl,00000h
	ld d,003h
HW1:	in a,(HD_DRV)
	rla
	ret c
	dec hl
	ld a,h
	or l
	jp nz,HW1
	dec d
	jp nz,HW1
	ret

HDCHKRDY:
	in a,(HD_DRV)
	and 001h
	xor 001h
	ret z
	ld hl,MSG_NOTRDY
	or 001h
	ret

HDCLRFLT:
	xor a
	out (HD_SEL),a
	ld a,041h
	out (HD_SEL),a
	ret

HDLOADTAB:
	ld a,(hl)
	out (HD_MODE),a
	inc hl
	ld a,(hl)
	out (HD_PTR),a
	inc hl
HL1:	ld a,(hl)
	or a
	ret z
	inc hl
	ld b,a
	rla
	jp c,HL3
HL2:	ld a,(hl)
	out (HD_DATA),a
	inc hl
	dec b
	jp nz,HL2
	jp HL1
HL3:	or a
	rra
	ld b,a
	ld a,(hl)
	inc hl
HL4:	out (HD_DATA),a
	dec b
	jp nz,HL4
	jp HL1

; Sequencer tables, copied unchanged from the original ROM
HDTAB_B:
	defb 001h,0d3h
	defb 002h,040h,041h, 083h,040h, 08ch,06dh, 001h,063h, 084h,065h
	defb 082h,067h, 002h,049h,040h, 091h,050h
	defb 005h,05bh,0ddh,05dh,050h,00fh, 000h
HDTAB_A:
	defb 000h,0d7h
	defb 002h,040h,041h, 083h,040h, 08ch,06dh, 001h,063h, 084h,065h
	defb 082h,067h, 001h,049h, 082h,040h, 08ch,06dh
	defb 003h,063h,0e7h,067h, 087h,00fh, 002h,040h,041h, 083h,040h
	defb 08ch,06dh, 001h,063h, 082h,065h, 082h,060h, 082h,067h
	defb 001h,00fh, 000h

;=======================================================================
; Help and messages
;=======================================================================
CMD_HELP:
	ld hl,MSG_HELP
	jp PUTS

MSG_BANNER:	defb 0dh,0ah,"MCPMON 2.0  ? = help",0
MSG_PROMPT:	defb 0dh,0ah,'>',0
MSG_BRK:	defb " ^C",0
MSG_OK:		defb " OK",0
MSG_FAIL:	defb " FAIL",0
MSG_RDOK:	defb " OK -> 8000",0
MSG_FDERR:	defb " FD status ",0
MSG_HEXEOF:	defb ":00000001FF",0dh,0ah,0
MSG_NOTRDY:	defb 07h,0dh,0ah,"* Drive not Ready ",0
MSG_RESTFAIL:	defb 07h,0dh,0ah,"* Restore Failed ",0
MSG_READFAIL:	defb 07h,0dh,0ah,"* Read Failed ",0
MSG_HELP:
	defb 0dh,0ah,"G:aaaa go       D:ss:ee dump    S:aaaa set"
	defb 0dh,0ah,"F:ss:ee:hh fill M:ss:ee:dd move I:pp in  O:pp:vv out"
	defb 0dh,0ah,"T:ss:ee test    H hex load      X:ss:ee hex dump"
	defb 0dh,0ah,"R:iiiiiiii read HD sector->8000 L HD boot  B/A FD boot"
	defb 0dh,0ah,"^C/ESC/DEL abort",0

ROMEND:
