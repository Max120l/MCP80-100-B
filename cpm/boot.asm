;=======================================================================
; CP/M boot sector for the MCP 80/100 (track 0, sector 1)
;
; The monitor's B command (original ROM and MCPMON alike) reads this
; sector to 0000h and enters it at 007Dh. It loads the rest of the system
; tracks to D400h: track 0 sectors 2-26 and track 1 sectors 1-26, which
; hold the CCP, BDOS and BIOS. Then it starts the BIOS cold boot.
;
; Polls the FD1793 status register; eight tries per sector.
;=======================================================================
CCP:	equ 0d400h
BIOS:	equ 0ea00h
CONS:	equ 003h
COND:	equ 002h
FDCMD:	equ 0f8h
FDSEC:	equ 0fah
FDDAT:	equ 0fbh

	org 0

LOADER:	di
	ld sp,0100h
	ld hl,CCP
	ld de,0002h			; D = track 0, E = sector 2
	ld b,51				; sectors to load
LS:	ld c,8				; tries
LR:	push hl
	ld a,e
	out (FDSEC),a
RDOP:	ld a,088h			; read sector (8Ch after a step or error)
	call LCMD
LW:	in a,(FDCMD)
	rrca				; BUSY
	jr nc,LD
	rrca				; DRQ
	jr nc,LW
	in a,(FDDAT)
	ld (hl),a
	inc hl
	jr LW
LD:	in a,(FDCMD)
	and 09ch			; not ready, not found, CRC, lost data
	ld a,08ch
	ld (RDOP+1),a			; next read: let the head settle
	jr z,LOK
	pop hl				; back to the start of this sector
	dec c
	jr nz,LR
	jr LERR
LOK:	pop af				; drop the saved address
	ld a,088h
	ld (RDOP+1),a
	inc e
	ld a,e
	cp 27
	jr c,LN
	ld e,1				; on to track 1
	ld a,05bh			; step in, update track register
	call LCMD
LSW:	in a,(FDCMD)
	rrca
	jr c,LSW
	ld a,08ch
	ld (RDOP+1),a
LN:	djnz LS
	jp BIOS

LCMD:	out (FDCMD),a			; command, then a short wait before
	ld a,40				; the status is valid
LC1:	dec a
	jr nz,LC1
	ret

LERR:	ld hl,LMSG
LE1:	in a,(CONS)
	and 001h
	jr z,LE1
	ld a,(hl)
	or a
LE2:	jr z,LE2			; stop here; reset to get back
	out (COND),a
	inc hl
	jr LE1
LMSG:	defb 0dh,0ah,"BOOT ERR",0

	defs 07dh-$			; the monitor enters at 007Dh
	jp LOADER
