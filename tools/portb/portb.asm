;=======================================================================
; PORTB - serial port B test / bridge for the MCP 80/100 (needs MCPMON 2.0)
;
; Console (port A) <-> port B bridge plus a beacon:
;   - every couple of seconds sends "MCP port B says hello #nn" on port B
;   - anything received on port B is shown on the console
;   - anything typed on the console is sent to port B (ESC quits)
;   - changes in port B's 8251 status are reported: DSR (the other end's
;     DTR), framing / overrun / parity errors (FE usually = wrong baud)
; Transmits never block: if port B can't send (no CTS), it just waits.
;
; Load with MCPMON:  H (send portb.hex),  then  G:0100 <CR>
;=======================================================================
WARM:	equ 0f803h
CONST:	equ 0f806h
CONIN:	equ 0f809h
CONOUT:	equ 0f80ch
PUTS:	equ 0f818h
PUTHEX:	equ 0f81bh

B_DATA:	equ 000h
B_CTRL:	equ 001h			; status: 0 TxRDY, 1 RxRDY, 2 TxEMPTY,
					; 3 PE, 4 OE, 5 FE, 7 DSR

	org 0100h

START:	ld hl,MSG
	call PUTS
	ld a,037h			; RTS, DTR, RxE, TxEN, clear errors
	out (B_CTRL),a
	ld a,0ffh
	ld (LASTST),a			; force a first status report
	ld hl,BEACON
	ld (BPTR),hl			; send a beacon straight away
	ld hl,0
	ld (TICK),hl

LOOP:	in a,(B_CTRL)
	ld b,a
	and 0b8h			; DSR + error bits
	ld c,a
	ld a,(LASTST)
	cp c
	call nz,SHOWST
	ld a,b
	and 002h			; port B -> console
	jr z,L1
	in a,(B_DATA)
	call CONOUT
L1:	call CONST			; console -> port B
	jr z,L2
	call CONIN
	cp 01bh
	jr z,QUIT
	ld c,a
	call TXWAIT
	jr nz,L2			; couldn't send: drop it
	ld a,c
	out (B_DATA),a
L2:	ld hl,(TICK)			; beacon timer
	dec hl
	ld (TICK),hl
	ld a,h
	or l
	jr nz,L3
	call NEWBEACON
L3:	ld hl,(BPTR)			; send the next beacon character
	ld a,(hl)
	or a
	jr z,LOOP
	in a,(B_CTRL)
	and 001h
	jr z,LOOP
	ld a,(hl)
	out (B_DATA),a
	inc hl
	ld (BPTR),hl
	jr LOOP

QUIT:	ld hl,MSG_BYE
	call PUTS
	jp WARM

; TXWAIT: wait (briefly) for TxRDY. Z = ready, NZ = timeout
TXWAIT:	ld hl,8000
TW1:	in a,(B_CTRL)
	and 001h
	jr nz,TW2
	dec hl
	ld a,h
	or l
	jr nz,TW1
	or 1
	ret
TW2:	xor a
	ret

; NEWBEACON: bump the counter in the text and restart the beacon
NEWBEACON:
	ld a,(COUNT)
	inc a
	ld (COUNT),a
	ld b,a
	rrca
	rrca
	rrca
	rrca
	call HEXCH
	ld (BNUM),a
	ld a,b
	call HEXCH
	ld (BNUM+1),a
	ld hl,BEACON
	ld (BPTR),hl
	ret
HEXCH:	and 00fh
	add a,090h
	daa
	adc a,040h
	daa
	ret

; SHOWST: report port B status (C = masked status), then clear errors
SHOWST:	ld a,c
	ld (LASTST),a
	ld hl,T_ST
	call PUTS
	ld a,b
	call PUTHEX
	ld a,c
	and 080h
	ld hl,T_DSR1
	jr nz,SS1
	ld hl,T_DSR0
SS1:	call PUTS
	ld a,c
	and 020h
	ld hl,T_FE
	call nz,PUTS
	ld a,c
	and 010h
	ld hl,T_OE
	call nz,PUTS
	ld a,c
	and 008h
	ld hl,T_PE
	call nz,PUTS
	ld hl,T_END
	call PUTS
	ld a,c
	and 038h			; errors: clear them in the 8251
	ret z
	ld a,037h
	out (B_CTRL),a
	ld a,c
	and 080h			; remember only DSR, so errors report again
	ld (LASTST),a
	ret

MSG:	defb 0dh,0ah,"PORTB: console <-> port B bridge, beacon on port B. ESC quits",0dh,0ah,0
MSG_BYE:	defb 0dh,0ah,"PORTB done",0
T_ST:	defb 0dh,0ah,"[port B status ",0
T_DSR1:	defb ": DSR on (other end's DTR seen)",0
T_DSR0:	defb ": DSR off",0
T_FE:	defb ", FRAMING ERROR (baud?)",0
T_OE:	defb ", overrun",0
T_PE:	defb ", parity error",0
T_END:	defb "]",0dh,0ah,0
BEACON:	defb "MCP port B says hello #"
BNUM:	defb "00",0dh,0ah,0

LASTST:	defb 0
COUNT:	defb 0
BPTR:	defw 0
TICK:	defw 0
