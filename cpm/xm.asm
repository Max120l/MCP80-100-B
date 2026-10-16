;=======================================================================
; XM 1.0 - XMODEM file transfer on serial port B, for CP/M 2.2 on the
; MCP 80/100
;
;   XM R FILE.EXT     receive FILE.EXT from the PC (the PC sends)
;   XM S FILE.EXT     send FILE.EXT to the PC (the PC receives)
;
; Port B is the second 8251 (00h data, 01h status/command); its baud rate
; comes from DIP switches 1-4. XM resets the 8251 to 8N1 with the x16
; clock, as MCPMON does, so it works whichever ROM booted CP/M. The
; console stays on port A.
;
; Receive: asks for CRC ('C' every 3 s for 30 s), then for checksum (NAK
; every 3 s for 60 s more). Takes 128- and 1024-byte blocks (SOH/STX).
; Blocks collect in memory and go to disk 4K at a time, before the block
; that filled the buffer is acknowledged (one record at a time would wait
; most of a disk turn per record). The data goes to FILE.$$$, which
; replaces FILE.EXT only once the transfer is complete. Records of pure ^Z
; padding at the end of the last block are dropped, so 1K blocks don't
; add up to 7 records of padding.
;
; Send: 128-byte blocks, CRC or checksum as the receiver asks ('C' or NAK).
; Reads the file 4K at a time.
;
; ^C, ^X or ESC on the console cancels whenever XM is waiting. Console I/O
; goes straight to the BIOS. Timeouts assume the 6 MHz CPU.
;=======================================================================
BDOS:	equ 0005h
WBOOTV:	equ 0001h			; address of the BIOS warm boot entry
FCB1:	equ 005ch			; first argument (R or S), parsed by the CCP
FCB2:	equ 006ch			; second argument (the file name)

AUXD:	equ 000h			; port B 8251
AUXS:	equ 001h			; status: 0 TxRDY, 1 RxRDY, 3 PE, 4 OE, 5 FE

SOH:	equ 001h
STX:	equ 002h
EOT:	equ 004h
ACK:	equ 006h
NAK:	equ 015h
CAN:	equ 018h
CTRLZ:	equ 01ah

T100:	equ 11765			; RXTO: 51-T loop, 0.1 s at 6 MHz

STACK:	equ 0d00h			; the program must end below 0C00h
CRCPG:	equ 00eh			; CRC table: high bytes 0E00h, low 0F00h
BUF:	equ 1000h			; 4K of data plus a block: 1000h-23FFh

	org 0100h

START:	ld (OLDSP),sp
	ld sp,STACK
	ld hl,(WBOOTV)			; BIOS CONST, CONIN, CONOUT follow the
	ld de,3				; warm boot entry
	add hl,de
	ld (VCONST+1),hl
	add hl,de
	ld (VCONIN+1),hl
	add hl,de
	ld (VCONOUT+1),hl
	call CRCINIT
	xor a
	ld (OPEN),a
	ld hl,0
	ld (BLKS),hl
	ld (RECS),hl
	ld (RETRY),hl

	ld a,(FCB1+2)			; R or S, one letter
	cp ' '
	jr nz,USAGE
	ld a,(FCB1+1)
	ld (MODE),a
	cp 'R'
	jr z,ARG2
	cp 'S'
	jr nz,USAGE
ARG2:	ld a,(FCB2+1)			; a file name
	cp ' '
	jr z,USAGE
	ld hl,FCB2			; drive, name, type
	ld de,FCB
	ld bc,12
	ldir
	xor a				; extent and record counts: zero
	ld b,24
ZF:	ld (de),a
	inc de
	djnz ZF
	ld hl,FCB+1			; no wildcards
	ld b,11
WC:	ld a,(hl)
	cp '?'
	jr z,USAGE
	inc hl
	djnz WC
	call AUXINIT
	ld a,(MODE)
	cp 'S'
	jp z,SEND
	jp RECV

USAGE:	ld hl,MUSAGE
	call PRINT
	jp EXIT

AUXINIT: xor a				; 8251 reset: 00 00 00 40, mode, command
	call AUXW			; (the same as MCPMON's SIOINIT)
	call AUXW
	call AUXW
	ld a,040h
	call AUXW
	ld a,04eh			; async, x16 clock, 8 bits, no parity, 1 stop
	call AUXW
	ld a,037h			; RTS, DTR, RxE, TxEN, clear errors
AUXW:	out (AUXS),a
	ld b,20
AW1:	djnz AW1
	ret

;-----------------------------------------------------------------------
; Receive
;-----------------------------------------------------------------------
RECV:	ld hl,FCB			; the data goes to FILE.$$$ first
	ld de,TFCB
	ld bc,36
	ldir
	ld hl,TFCB+9
	ld (hl),'$'
	inc hl
	ld (hl),'$'
	inc hl
	ld (hl),'$'
	ld de,TFCB			; remove any leftover, then create it
	ld c,19
	call BDOS
	ld de,TFCB
	ld c,22
	call BDOS
	inc a
	ld hl,MDIRF
	jp z,FAILNC
	ld a,1
	ld (OPEN),a			; from here FAIL removes FILE.$$$
	ld hl,MRECV
	call PRINT
	call PNAME
	ld hl,MRECV2
	call PRINT
	ld a,1
	ld (BLKNUM),a
	ld (CRCM),a
	ld hl,BUF
	ld (FILL),hl
	ld hl,0
	ld (LASTLEN),hl
	xor a
	ld (ERRS),a
	ld a,30				; ask 10 times with 'C' (CRC), then 20
	ld (TRIES),a			; times with NAK (checksum), 3 s apart
RH1:	ld a,(TRIES)
	cp 21
	ld a,'C'
	jr nc,RH2
	xor a
	ld (CRCM),a
	ld a,NAK
RH2:	call TXBX
	ld b,30
	call RXTO
	jr nc,RBYTE
	ld hl,TRIES
	dec (hl)
	jr nz,RH1
	ld hl,MNOSND
	jp FAIL

RNEXT:	ld b,100			; 10 s for the next block
	call RXTO
	jr c,RTIME
RBYTE:	ld de,128
	cp SOH
	jr z,RBLK
	ld de,1024
	cp STX
	jr z,RBLK
	cp EOT
	jp z,REOT
	cp CAN
	jr z,RCAN
	call CONCHK			; noise: wait for a block
	jr RNEXT
RCAN:	ld b,10				; two CANs: the PC cancelled
	call RXTO
	jr c,RNEXT
	cp CAN
	jr nz,RNEXT
	ld hl,MPCCAN
	jp FAIL
RTIME:	call RERR
	jr RNEXT

RBLK:	ld (BLEN),de
	ld b,10				; 1 s per byte
	call RXTO
	jp c,RBAD
	ld (RBN),a
	ld b,10
	call RXTO
	jp c,RBAD
	ld (RBNC),a
	ld hl,(FILL)			; the block goes after the data so far
RB1:	ld b,10
	call RXTO
	jp c,RBAD
	ld (hl),a
	inc hl
	dec de
	ld a,d
	or e
	jr nz,RB1
	ld b,10
	call RXTO
	jp c,RBAD
	ld (RCK1),a
	ld a,(CRCM)
	or a
	jr z,RB2
	ld b,10
	call RXTO
	jp c,RBAD
	ld (RCK2),a
RB2:	in a,(AUXS)			; overrun or framing error: bad block
	and 038h
	jp nz,RBAD
	ld a,(RBNC)			; block number and its complement
	cpl
	ld b,a
	ld a,(RBN)
	cp b
	jp nz,RBAD
	ld de,(FILL)
	ld bc,(BLEN)
	ld a,(CRCM)
	or a
	jr z,RB3
	call CRC16
	ld a,(RCK1)
	cp h
	jp nz,RBAD
	ld a,(RCK2)
	cp l
	jp nz,RBAD
	jr RB4
RB3:	call CKSUM
	ld b,a
	ld a,(RCK1)
	cp b
	jp nz,RBAD
RB4:	ld a,(BLKNUM)
	ld b,a
	ld a,(RBN)
	cp b
	jr z,RGOOD
	inc a
	cp b
	jr nz,RSYNC
	ld a,ACK			; the previous block again: our ACK was
	call TXBX			; lost, so acknowledge it again
	jp RNEXT
RSYNC:	ld hl,MSYNC
	jp FAIL
RBAD:	call PURGE
	call RERR
	jp RNEXT

RGOOD:	xor a
	ld (ERRS),a
	ld hl,(FILL)			; keep the block
	ld de,(BLEN)
	add hl,de
	ld (FILL),hl
	ld (LASTLEN),de
	ld de,0-(BUF+4097)		; more than 4K waiting: to disk
	add hl,de
	call c,FLUSH
	ld hl,BLKNUM
	inc (hl)
	call PROG
	ld a,ACK
	call TXBX
	jp RNEXT

; End of file: drop the last block's trailing ^Z records, write the rest,
; close FILE.$$$ and rename it to FILE.EXT.
REOT:	ld hl,(LASTLEN)
	ld a,h
	or l
	jr z,RE6			; nothing received
	add hl,hl
	ld c,h				; records in the last block: 1 or 8
	ld hl,(FILL)
RE3:	push hl				; HL = end of a record: all ^Z?
	ld de,-128
	add hl,de
	ld b,128
RE4:	ld a,(hl)
	cp CTRLZ
	jr nz,RE5
	inc hl
	djnz RE4
	pop hl				; padding: drop it
	ld de,-128
	add hl,de
	dec c
	jr nz,RE3
	push hl
RE5:	pop hl				; the end of what to keep
	ld (FILL),hl
RE6:	call WALL
	ld de,TFCB			; close FILE.$$$
	ld c,16
	call BDOS
	inc a
	ld hl,MCLOSE
	jp z,FAIL
	ld de,FCB			; remove the old FILE.EXT
	ld c,19
	call BDOS
	ld hl,TFCB			; rename: old name, then new name
	ld de,RFCB
	ld bc,16
	ldir
	ld hl,FCB
	ld bc,16
	ldir
	ld de,RFCB
	ld c,23
	call BDOS
	xor a
	ld (OPEN),a
	ld a,ACK
	call TXBX
	ld hl,MSUMR
	jp DONE

; Write everything but the last block, then move the last block down to
; the start of the buffer.
FLUSH:	ld hl,(FILL)
	ld de,(LASTLEN)
	or a
	sbc hl,de			; HL = start of the last block
	push hl
	call WTO
	pop hl
	ld de,BUF
	ld bc,(LASTLEN)
	ldir
	ld (FILL),de
	ret

; Write all the data in the buffer.
WALL:	ld hl,(FILL)
; Write the records from BUF up to HL.
WTO:	ld de,BUF
	or a
	sbc hl,de
	add hl,hl
	ld b,h				; records
	ld hl,BUF
; Write B records from HL to FILE.$$$.
WREC:	ld a,b
	or a
	ret z
WR1:	push bc
	push hl
	ex de,hl
	ld c,26				; DMA address
	call BDOS
	ld de,TFCB
	ld c,21				; write sequential
	call BDOS
	pop hl
	pop bc
	or a
	jr nz,WFULL
	push hl
	ld hl,(RECS)
	inc hl
	ld (RECS),hl
	pop hl
	ld de,128
	add hl,de
	djnz WR1
	ret
WFULL:	ld hl,MFULL
	jp FAIL

; Count an error; NAK, or 'C' while still waiting for the first block
; in CRC mode. Ten in a row cancel.
RERR:	ld hl,ERRS
	inc (hl)
	ld a,(hl)
	cp 10
	ld hl,MERRS
	jp nc,FAIL
	ld hl,(RETRY)
	inc hl
	ld (RETRY),hl
	ld a,(CRCM)
	or a
	ld a,NAK
	jr z,RR1
	ld hl,(BLKS)
	ld a,h
	or l
	ld a,NAK
	jr nz,RR1
	ld a,'C'
RR1:	jp TXBX

; Wait until port B has been quiet for 1 s (at most 3000 bytes), then
; clear the 8251's error flags.
PURGE:	ld de,3000
PG1:	ld b,10
	call RXTO
	jr c,PG2
	dec de
	ld a,d
	or e
	jr nz,PG1
PG2:	ld a,037h
	out (AUXS),a
	ret

;-----------------------------------------------------------------------
; Send
;-----------------------------------------------------------------------
SEND:	ld de,FCB
	ld c,15				; open
	call BDOS
	inc a
	ld hl,MNOFILE
	jp z,FAILNC
	ld hl,MSEND
	call PRINT
	call PNAME
	ld hl,MSEND2
	call PRINT
	ld a,30				; 90 s for the PC to start
	ld (TRIES),a
SH1:	ld b,30
	call RXTO
	jr c,SH2
	cp 'C'
	ld c,1
	jr z,SH3
	cp NAK
	ld c,0
	jr z,SH3
	cp CAN
	jr nz,SH1
	ld b,10
	call RXTO
	jr c,SH1
	cp CAN
	jr nz,SH1
	ld hl,MPCCAN
	jp FAIL
SH2:	ld hl,TRIES
	dec (hl)
	jr nz,SH1
	ld hl,MNORCV
	jp FAIL
SH3:	ld a,c
	ld (CRCM),a
	ld a,1
	ld (BLKNUM),a
	xor a
	ld (SCNT),a
	ld (SEOF),a

SNEXT:	ld a,(SCNT)			; records left in the buffer
	or a
	jr nz,SN0
	call SFILL
	ld a,(SCNT)
	or a
	jp z,SEOT
SN0:	ld de,(SPTR)
	ld bc,128
	ld a,(CRCM)
	or a
	jr z,SN1
	call CRC16
	ld (SCHK),hl
	jr SN2
SN1:	call CKSUM
	ld (SCHK),a
SN2:	xor a
	ld (ERRS),a
SBLK:	ld a,SOH
	call TXBX
	ld a,(BLKNUM)
	call TXBX
	ld a,(BLKNUM)
	cpl
	call TXBX
	ld hl,(SPTR)
	ld b,128
SB1:	ld a,(hl)
	call TXBX
	inc hl
	djnz SB1
	ld a,(CRCM)
	or a
	jr z,SB2
	ld a,(SCHK+1)			; CRC: high byte first
	call TXBX
SB2:	ld a,(SCHK)
	call TXBX
SW1:	ld b,100			; 10 s for the answer
	call RXTO
	jr c,SRETRY
	cp ACK
	jr z,SACK
	cp NAK
	jr z,SRETRY
	cp CAN
	jr nz,SW1			; 'C' or noise: keep waiting
	ld b,10
	call RXTO
	jr c,SW1
	cp CAN
	jr nz,SW1
	ld hl,MPCCAN
	jp FAIL
SRETRY:	call SERR
	jr SBLK
SACK:	ld hl,(RECS)
	inc hl
	ld (RECS),hl
	ld hl,(SPTR)
	ld de,128
	add hl,de
	ld (SPTR),hl
	ld hl,SCNT
	dec (hl)
	ld hl,BLKNUM
	inc (hl)
	call PROG
	jp SNEXT

; Read up to 32 records (4K) into the buffer: SCNT records at SPTR.
SFILL:	ld hl,BUF
	ld (SPTR),hl
	ld a,(SEOF)
	or a
	ret nz
	ld b,32
SF1:	push bc
	push hl
	ex de,hl
	ld c,26				; DMA address
	call BDOS
	ld de,FCB
	ld c,20				; read sequential: 0 OK, 1 end of file
	call BDOS
	pop hl
	pop bc
	or a
	jr nz,SF2
	ld a,(SCNT)
	inc a
	ld (SCNT),a
	ld de,128
	add hl,de
	djnz SF1
	ret
SF2:	ld a,1
	ld (SEOF),a
	ret

SEOT:	xor a
	ld (ERRS),a
SE1:	ld a,EOT
	call TXBX
SE2:	ld b,100
	call RXTO
	jr c,SE3
	cp ACK
	jr z,SE4
	cp NAK
	jr nz,SE2
SE3:	call SERR
	jr SE1
SE4:	ld hl,MSUMS
	jp DONE

SERR:	ld hl,ERRS			; count a retry, ten in a row cancel
	inc (hl)
	ld a,(hl)
	cp 10
	ld hl,MERRS
	jp nc,FAIL
	ld hl,(RETRY)
	inc hl
	ld (RETRY),hl
	ret

;-----------------------------------------------------------------------
; Endings
;-----------------------------------------------------------------------
; Success. HL = " received: " or " sent: "
DONE:	push hl
	ld hl,MCRLF
	call PRINT
	call PNAME
	pop hl
	call PRINT
	ld hl,(RECS)
	call PDEC
	ld hl,MSUM2
	call PRINT
	ld hl,(RECS)			; K = (records + 7) / 8
	ld de,7
	add hl,de
	srl h
	rr l
	srl h
	rr l
	srl h
	rr l
	call PDEC
	ld hl,MSUM3
	call PRINT
	ld hl,(RETRY)
	ld a,h
	or l
	jr z,DN1
	ld hl,MSUM4
	call PRINT
	ld hl,(RETRY)
	call PDEC
DN1:	ld hl,MCRLF
	call PRINT
	jp EXIT

; Failure. HL = message. FAIL also sends CANs to stop the PC's side.
FAIL:	ld sp,STACK
	push hl
	ld b,5
FA1:	ld a,CAN
	call TXB
	djnz FA1
	pop hl
FAILNC:	ld sp,STACK
	push hl
	ld hl,MCRLF
	call PRINT
	pop hl
	call PRINT
	ld a,(OPEN)			; receiving: remove FILE.$$$
	or a
	jr z,FA2
	ld de,TFCB
	ld c,16
	call BDOS
	ld de,TFCB
	ld c,19
	call BDOS
	ld hl,MNOSAV
	call PRINT
FA2:	ld hl,MCRLF
	call PRINT
EXIT:	ld de,0080h			; the CCP's DMA address
	ld c,26
	call BDOS
	ld sp,(OLDSP)
	ret

;-----------------------------------------------------------------------
; Port B
;-----------------------------------------------------------------------
; Byte from port B -> A, carry clear. Carry set on timeout after B tenths
; of a second. Keeps C, DE, HL. Checks the console during silences.
RXTO:	push de
RT1:	ld de,T100
RT2:	in a,(AUXS)			; 11
	and 002h			; 7
	jr nz,RTGOT			; 7
	dec de				; 6
	ld a,d				; 4
	or e				; 4
	jr nz,RT2			; 12 = 51 T
	call CONCHK
	djnz RT1
	pop de
	scf
	ret
RTGOT:	in a,(AUXD)
	pop de
	or a
	ret

; A -> port B. Carry set if the 8251 stays busy for 0.5 s (the 8251 only
; sends while CTS is asserted). Keeps A, BC, DE, HL.
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
	scf
	ret
TX2:	pop af
	out (AUXD),a
	pop de
	or a
	ret
TXBX:	call TXB			; the same, giving up if port B is stuck
	ret nc
	ld hl,MNOCTS
	jp FAILNC

;-----------------------------------------------------------------------
; Checks
;-----------------------------------------------------------------------
; CRC-16/XMODEM (polynomial 1021h) of BC bytes at DE -> HL, with the
; table: crc = (crc << 8) xor T[(crc >> 8) xor byte]
CRC16:	ld hl,0
CR1:	ld a,(de)
	inc de
	xor h
	push de
	ld e,a
	ld d,CRCPG
	ld a,(de)			; high byte of T[i]
	xor l
	ld h,a
	inc d
	ld a,(de)			; low byte of T[i]
	ld l,a
	pop de
	dec bc
	ld a,b
	or c
	jr nz,CR1
	ret

; Build the table: T[i] = i << 8 shifted through the polynomial 8 times
CRCINIT: ld c,0
CI1:	ld h,c
	ld l,0
	ld b,8
CI2:	add hl,hl
	jr nc,CI3
	ld a,h
	xor 010h
	ld h,a
	ld a,l
	xor 021h
	ld l,a
CI3:	djnz CI2
	ld d,CRCPG
	ld e,c
	ld a,h
	ld (de),a
	inc d
	ld a,l
	ld (de),a
	inc c
	jr nz,CI1
	ret

; Sum of BC bytes at DE -> A
CKSUM:	ld h,0
CK1:	ld a,(de)
	add a,h
	ld h,a
	inc de
	dec bc
	ld a,b
	or c
	jr nz,CK1
	ld a,h
	ret

;-----------------------------------------------------------------------
; Console (BIOS)
;-----------------------------------------------------------------------
; ^C, ^X or ESC typed: cancel. Keeps all registers otherwise.
CONCHK:	push bc
	push de
	push hl
	call VCONST
	or a
	jr z,CC1
	call VCONIN
	cp 003h
	jr z,CCX
	cp 018h
	jr z,CCX
	cp 01bh
	jr z,CCX
CC1:	pop hl
	pop de
	pop bc
	ret
CCX:	ld hl,MUSER
	jp FAIL

; Count a block and show the count
PROG:	ld hl,(BLKS)
	inc hl
	ld (BLKS),hl
	push hl
	ld hl,MBLOCK
	call PRINT
	pop hl
	jp PDEC

; HL in decimal
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
	call PUTC
	pop hl
	pop de
	pop bc
	ret
PD1:	ld a,'0'-1
PD2:	inc a
	add hl,de
	jr c,PD2
	sbc hl,de			; carry is clear here: undo the last add
	cp '0'
	jr nz,PD3
	inc b				; leading zero?
	dec b
	ret z
PD3:	ld b,1
	jp PUTC

; The file name, as NAME.EXT
PNAME:	ld hl,FCB+1
	ld b,8
PN1:	ld a,(hl)
	and 07fh
	cp ' '
	call nz,PUTC
	inc hl
	djnz PN1
	ld a,(hl)
	cp ' '
	ret z
	ld a,'.'
	call PUTC
	ld b,3
PN2:	ld a,(hl)
	and 07fh
	cp ' '
	call nz,PUTC
	inc hl
	djnz PN2
	ret

; 0-terminated string at HL
PRINT:	ld a,(hl)
	or a
	ret z
	call PUTC
	inc hl
	jr PRINT

; A to the console. Keeps all registers.
PUTC:	push af
	push bc
	push de
	push hl
	ld c,a
	call VCONOUT
	pop hl
	pop de
	pop bc
	pop af
	ret

VCONST:	jp 0				; patched with the BIOS entries
VCONIN:	jp 0
VCONOUT: jp 0

;-----------------------------------------------------------------------
MUSAGE:	defb "XM 1.0  XMODEM on serial port B",0dh,0ah
	defb "  XM R FILE.EXT   receive a file from the PC",0dh,0ah
	defb "  XM S FILE.EXT   send a file to the PC",0dh,0ah,0
MRECV:	defb "Receiving ",0
MRECV2:	defb " on port B: start the XMODEM send on the PC (^C cancels)",0dh,0ah,0
MSEND:	defb "Sending ",0
MSEND2:	defb " on port B: start the XMODEM receive on the PC (^C cancels)",0dh,0ah,0
MBLOCK:	defb 0dh,"Block ",0
MSUMR:	defb " received: ",0
MSUMS:	defb " sent: ",0
MSUM2:	defb " records (",0
MSUM3:	defb "K)",0
MSUM4:	defb ", retries: ",0
MCRLF:	defb 0dh,0ah,0
MNOFILE: defb "File not found",0
MDIRF:	defb "Directory full",0
MFULL:	defb "Disk full",0
MCLOSE:	defb "Can't close the file",0
MNOSND:	defb "Nothing from the PC: no XMODEM send started",0
MNORCV:	defb "Nothing from the PC: no XMODEM receive started",0
MPCCAN:	defb "Cancelled by the PC",0
MUSER:	defb "Cancelled",0
MERRS:	defb "Too many errors",0
MSYNC:	defb "Blocks out of sequence",0
MNOCTS:	defb "Port B isn't sending (no CTS from the PC?)",0
MNOSAV:	defb ", nothing saved",0

;-----------------------------------------------------------------------
OLDSP:	defw 0
MODE:	defb 0
OPEN:	defb 0				; 1 while FILE.$$$ exists
CRCM:	defb 0				; 1 = CRC, 0 = checksum
TRIES:	defb 0
ERRS:	defb 0				; errors in a row
BLKNUM:	defb 0				; block number expected / being sent
RBN:	defb 0
RBNC:	defb 0
RCK1:	defb 0
RCK2:	defb 0
BLEN:	defw 0				; length of the block being received
FILL:	defw 0				; end of the data waiting in BUF
LASTLEN: defw 0				; length of the last good block (0 = none)
SPTR:	defw 0				; send: next record in BUF
SCNT:	defb 0				; send: records left in BUF
SEOF:	defb 0				; send: end of file reached
BLKS:	defw 0				; blocks transferred
RECS:	defw 0				; records written or sent
RETRY:	defw 0				; retries, total
SCHK:	defw 0				; check value of the block being sent
FCB:	defs 36				; FILE.EXT
TFCB:	defs 36				; FILE.$$$
RFCB:	defs 36				; rename
CODEEND:
