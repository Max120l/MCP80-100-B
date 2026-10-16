;=======================================================================
; MCP 80/100 boot ROM (2716, 2 KB, runs at F800h-FFFFh)
; Annotated disassembly. Reassembles byte-for-byte with:
;     z80asm -i mcp_boot.asm -o rebuilt.bin  (see verify.sh)
;
; Source image: 4 independent reads, all identical
;     MD5    896f955e6635ab978e36aabd114d29bf
;     SHA256 704b26c60d5a499fbcd4ae6a159208d9f3fcfc1c8853001c0f900e046404edbc
;
; Comments marked "tentative" are inferences that still need checking
; on real hardware.
;
; Monitor commands (addresses are exactly 4 hex digits, bytes 2,
; no Enter; DEL returns to the prompt from anywhere):
;   G:aaaa<CR>        go
;   D:ssss:eeee       hex dump
;   S:aaaa            substitute (space = next, hh = store)
;   F:ssss:eeee hh    fill
;   M:ssss:eeee:dddd  move
;   B                 boot floppy (ctrl at F8h, then 78h)
;   A                 boot floppy (ctrl at 78h)
;   L                 boot hard disk (ctrl at 60h-66h)
;=======================================================================

; I/O ports
SIO2_DATA:  equ 000h  ; second 8251 data
SIO2_CTRL:  equ 001h  ; second 8251 mode/command/status
CON_DATA:   equ 002h  ; console 8251 data
CON_CTRL:   equ 003h  ; console 8251 mode/command/status
PPI_CTRL:   equ 007h  ; 8255 control (ports A/B/C at 04h-06h)
SHADOW_OFF: equ 00ah  ; read: probably disables the ROM copy at 0000h (tentative)
HD_DRV:     equ 060h  ; XCOMP BASE+0: drive commands (out) / drive status (in)
HD_SEL:     equ 061h  ; XCOMP BASE+1: extended drive commands (out) / clear index (in)
HD_STEPLO:  equ 062h  ; XCOMP BASE+2: seek count LSB
HD_STEPHI:  equ 063h  ; XCOMP BASE+3: seek count MSB
HD_MODE:    equ 064h  ; XCOMP BASE+4: controller commands (out) / status (in)
HD_PTR:     equ 065h  ; XCOMP BASE+5: buffer address
HD_DATA:    equ 066h  ; XCOMP BASE+6: data in/out (auto-increment)
FDC2_CMD:   equ 078h  ; floppy ctrl #2, WD179x-type command/status
FDC2_SEC:   equ 07ah  ; floppy ctrl #2 sector register
FDC2_DATA:  equ 07bh  ; floppy ctrl #2 data register
FDC2_WAIT:  equ 07ch  ; floppy ctrl #2 board wait/status port (bit 7 = DRQ?)
FDC1_CMD:   equ 0f8h  ; floppy ctrl #1, WD179x-type command/status
FDC1_SEC:   equ 0fah  ; floppy ctrl #1 sector register
FDC1_DATA:  equ 0fbh  ; floppy ctrl #1 data register
FDC1_WAIT:  equ 0fch  ; floppy ctrl #1 board wait/status port (bit 7 = DRQ?)

	org 0f800h

;-----------------------------------------------------------------------
; Reset / cold start
;-----------------------------------------------------------------------
RESET:
	jp COLD                                ; F800  at reset the ROM also answers at 0000h: jump up to F803h
COLD:
	in a,(SHADOW_OFF)                      ; F803  probably turns off the ROM copy at 0000h (tentative)
	ld sp,0f3ffh                           ; F805  stack just below F400h (scratch RAM, probably CPU-card 2114s)
	jp INIT                                ; F808  hardware init, then fall into the monitor

;-----------------------------------------------------------------------
; Monitor main loop: print prompt, read one letter, look it up in CMDTAB
; and jump to the handler with PROMPT as the return address.
;-----------------------------------------------------------------------
MONITOR:
	ld sp,0f3ffh                           ; F80B  monitor warm entry: reset stack
PROMPT:
	ld hl,MSG_PROMPT                       ; F80E  print CR LF '>'
	call PUTS                              ; F811
	call GETCH                             ; F814  read command letter (echoed)
	ld b,a                                 ; F817
	ld hl,CRLF_STR                         ; F818  HL = CMDTAB-3, so the first INC x3 lands on entry 0
DISPATCH:
	inc hl                                 ; F81B
	inc hl                                 ; F81C
	inc hl                                 ; F81D
	ld a,(hl)                              ; F81E
	cp 0ffh                                ; F81F  FFh = end of table
	jp z,BADCMD                            ; F821
	cp b                                   ; F824  letter matches?
	jp nz,DISPATCH                         ; F825
	inc hl                                 ; F828
	ld e,(hl)                              ; F829  DE = handler address
	inc hl                                 ; F82A
	ld d,(hl)                              ; F82B
	ld hl,PROMPT                           ; F82C  return address for the handler = PROMPT
	push hl                                ; F82F
	push de                                ; F830
	ret                                    ; F831  'call' the handler
BADCMD:
	ld hl,MSG_ERR                          ; F832  unknown command: print ' ?' CR LF
	call PUTS                              ; F835
	jp PROMPT                              ; F838

;-----------------------------------------------------------------------
; Strings and command table. CRLF_STR doubles as CMDTAB-3.
;-----------------------------------------------------------------------
MSG_PROMPT:
	defb 00dh,00ah,">",000h                ; F83B
MSG_ERR:
	defb " ?"                              ; F83F
CRLF_STR:
	defb 00dh,00ah,000h                    ; F841
CMDTAB:
	defb 'G'                               ; F844
	defw CMD_G                             ; F845
	defb 'D'                               ; F847
	defw CMD_D                             ; F848
	defb 'L'                               ; F84A
	defw CMD_L                             ; F84B
	defb 'S'                               ; F84D
	defw CMD_S                             ; F84E
	defb 'B'                               ; F850
	defw CMD_B                             ; F851
	defb 'M'                               ; F853
	defw CMD_M                             ; F854
	defb 'A'                               ; F856
	defw CMD_A                             ; F857
	defb 'F'                               ; F859
	defw CMD_F                             ; F85A
	defb 0ffh                              ; F85C  end of table
	defb 0ffh,0ffh,0ffh,0ffh,0ffh,0ffh,0ffh,0ffh,0ffh; F85D  unused (blank)

;-----------------------------------------------------------------------
; Console I/O (8251 at 02h/03h)
;-----------------------------------------------------------------------
CONIN:
	in a,(CON_CTRL)                        ; F866  wait for RxRDY (8251 status bit 1)
	and 002h                               ; F868
	jp z,CONIN                             ; F86A
	in a,(CON_DATA)                        ; F86D
	and 07fh                               ; F86F  strip parity bit
	ret                                    ; F871
GETCH:
	call CONIN                             ; F872
	call CONOUT                            ; F875  echo it
	cp 07fh                                ; F878  DEL aborts any command back to the monitor
	jp z,MONITOR                           ; F87A
	ret                                    ; F87D
PUTS:
	ld a,(hl)                              ; F87E
	or a                                   ; F87F
	ret z                                  ; F880
	call CONOUT                            ; F881
	inc hl                                 ; F884
	jp PUTS                                ; F885
CONOUT:
	push af                                ; F888
LF889:
	in a,(CON_CTRL)                        ; F889  wait for TxRDY (8251 status bit 0)
	and 001h                               ; F88B
	jp z,LF889                             ; F88D
	pop af                                 ; F890
	out (CON_DATA),a                       ; F891
	ret                                    ; F893

;-----------------------------------------------------------------------
; B: boot from floppy. Tries the WD179x-type controller at F8h-FCh; on
; error falls through into A, which tries the one at 78h-7Ch. Reads
; track 0 sector 1 to 0000h and enters it at 007Dh. If both fail, the
; status byte is printed in hex.
;-----------------------------------------------------------------------
CMD_B:
	ld a,06bh                              ; F894  WD179x: STEP-OUT, head load, slowest step rate
	out (FDC1_CMD),a                       ; F896
	in a,(FDC1_WAIT)                       ; F898  wait for the controller
	in a,(FDC1_CMD)                        ; F89A  status: bit 2 = TRACK 00
	and 004h                               ; F89C
	jp nz,LF8A9                            ; F89E  already on track 0
	ld a,00bh                              ; F8A1  WD179x: RESTORE, head load, slowest step rate
	out (FDC1_CMD),a                       ; F8A3
	in a,(FDC1_WAIT)                       ; F8A5
	in a,(FDC1_CMD)                        ; F8A7
LF8A9:
	ld hl,00000h                           ; F8A9  load address 0000h
	ld a,001h                              ; F8AC  sector 1
	out (FDC1_SEC),a                       ; F8AE
	ld a,088h                              ; F8B0  WD179x: READ SECTOR
	out (FDC1_CMD),a                       ; F8B2
LF8B4:
	in a,(FDC1_WAIT)                       ; F8B4  bit 7 set = data byte ready (tentative)
	or a                                   ; F8B6
	jp p,LF8C1                             ; F8B7  bit 7 clear: command finished
	in a,(FDC1_DATA)                       ; F8BA
	ld (hl),a                              ; F8BC
	inc hl                                 ; F8BD
	jp LF8B4                               ; F8BE
LF8C1:
	in a,(FDC1_CMD)                        ; F8C1  final status
	or a                                   ; F8C3
	jp z,0007dh                            ; F8C4  status 0 = OK: enter boot sector at 007Dh
CMD_A:
	ld a,06bh                              ; F8C7  controller #1 failed (or 'A' typed): same again at 78h
	out (FDC2_CMD),a                       ; F8C9
	in a,(FDC2_WAIT)                       ; F8CB
	in a,(FDC2_CMD)                        ; F8CD
	and 004h                               ; F8CF
	jp nz,LF8DC                            ; F8D1
	ld a,00bh                              ; F8D4
	out (FDC2_CMD),a                       ; F8D6
	in a,(FDC2_WAIT)                       ; F8D8
	in a,(FDC2_CMD)                        ; F8DA
LF8DC:
	ld hl,00000h                           ; F8DC
	ld a,001h                              ; F8DF
	out (FDC2_SEC),a                       ; F8E1
	ld a,088h                              ; F8E3
	out (FDC2_CMD),a                       ; F8E5
LF8E7:
	in a,(FDC2_WAIT)                       ; F8E7
	or a                                   ; F8E9
	jp p,LF8F4                             ; F8EA
	in a,(FDC2_DATA)                       ; F8ED
	ld (hl),a                              ; F8EF
	inc hl                                 ; F8F0
	jp LF8E7                               ; F8F1
LF8F4:
	in a,(FDC2_CMD)                        ; F8F4
	or a                                   ; F8F6
	jp z,0007dh                            ; F8F7  OK: enter boot sector at 007Dh; else fall into PUTHEX (prints status)

;-----------------------------------------------------------------------
; Hex output / input helpers
;-----------------------------------------------------------------------
PUTHEX:
	push bc                                ; F8FA  print A as two hex digits
	ld b,a                                 ; F8FB
	call HEXNIB                            ; F8FC
	ld c,a                                 ; F8FF
	ld a,b                                 ; F900
	rrca                                   ; F901
	rrca                                   ; F902
	rrca                                   ; F903
	rrca                                   ; F904
	call HEXNIB                            ; F905
	call CONOUT                            ; F908
	ld a,c                                 ; F90B
	pop bc                                 ; F90C
	jp CONOUT                              ; F90D
HEXNIB:
	and 00fh                               ; F910  low nibble -> ASCII hex (DAA trick)
	add a,090h                             ; F912
	daa                                    ; F914
	adc a,040h                             ; F915
	daa                                    ; F917
	ret                                    ; F918
PUTADDR:
	ld a,h                                 ; F919  print HL as four hex digits and a space
	call PUTHEX                            ; F91A
	ld a,l                                 ; F91D
	call PUTHEX                            ; F91E
	ld a,020h                              ; F921
	jp CONOUT                              ; F923
CMD_G:
	call GETADDR                           ; F926  G: ':' + 4 hex digits
	call GETCH                             ; F929
	cp 00dh                                ; F92C  needs CR to confirm, anything else cancels
	ret nz                                 ; F92E
	jp (hl)                                ; F92F  go
GETBYTE:
	push bc                                ; F930  read two hex digits -> A (entry for S: GETBYTE2, first char in A)
	call GETCH                             ; F931
GETBYTE2:
	call HEXVAL                            ; F934
	ld c,a                                 ; F937
	call GETCH                             ; F938
	call HEXVAL                            ; F93B
	ld b,a                                 ; F93E
	ld a,c                                 ; F93F
	rlca                                   ; F940
	rlca                                   ; F941
	rlca                                   ; F942
	rlca                                   ; F943
	or b                                   ; F944
	pop bc                                 ; F945
	ret                                    ; F946
HEXVAL:
	cp 030h                                ; F947  ASCII hex digit -> value; anything else -> HEXBAD
	jp c,HEXBAD                            ; F949
	cp 047h                                ; F94C
	jp nc,HEXBAD                           ; F94E
	cp 03ah                                ; F951
	jp nc,LF959                            ; F953
	and 00fh                               ; F956
	ret                                    ; F958
LF959:
	cp 041h                                ; F959
	jp c,HEXBAD                            ; F95B
	and 00fh                               ; F95E
	add a,009h                             ; F960
	ret                                    ; F962
HEXBAD:
	ld a,03fh                              ; F963  bad digit: print '?' and restart input
	call CONOUT                            ; F965
	jp GETBYTE                             ; F968  NOTE: re-enters without unwinding the stack - after a '?' press DEL
GETADDR:
	ld a,03ah                              ; F96B  print ':' then read a 4-digit hex address into HL
	call CONOUT                            ; F96D
	call GETBYTE                           ; F970
	ld h,a                                 ; F973
	call GETBYTE                           ; F974
	ld l,a                                 ; F977
	ld a,020h                              ; F978
	call CONOUT                            ; F97A
	ret                                    ; F97D

;-----------------------------------------------------------------------
; Baudot (ITA2 / US TTY) translation table, 32 letters + 32 figures.
; Only used by UNUSED_BAUDOT, which nothing calls: a leftover from a
; version that drove a 5-level teleprinter.
;-----------------------------------------------------------------------
BAUDOT_TAB:
	defb 000h,'E',00ah,'A',' ','S','I','U' ; F97E  letters, codes 00h-07h
	defb 00dh,'D','R','J','N','F','C','K'  ; F986  letters, codes 08h-0Fh
	defb 'T','Z','L','W','H','Y','P','Q'   ; F98E  letters, codes 10h-17h
	defb 'O','B','G',000h,'M','X','V',000h ; F996  letters, codes 18h-1Fh
	defb 000h,'3',00ah,'-',' ',' ','8','7' ; F99E  figures, codes 00h-07h
	defb 00dh,'$','4',027h,',','!',':','(' ; F9A6  figures, codes 08h-0Fh
	defb '5','"',')','2',01bh,'6','0','1'  ; F9AE  figures, codes 10h-17h
	defb '9','?','&',000h,'.','/',';',000h ; F9B6  figures, codes 18h-1Fh

;-----------------------------------------------------------------------
; D: hex dump  D:ssss:eeee
;-----------------------------------------------------------------------
CMD_D:
	call GETADDR                           ; F9BE  D: start address
	ex de,hl                               ; F9C1
	call GETADDR                           ; F9C2  end address
	push hl                                ; F9C5
	ex de,hl                               ; F9C6
	pop bc                                 ; F9C7
	inc bc                                 ; F9C8  BC = end+1
LF9C9:
	push hl                                ; F9C9
	ld hl,CRLF_STR                         ; F9CA
	call PUTS                              ; F9CD
	pop hl                                 ; F9D0
	call PUTADDR                           ; F9D1
LF9D4:
	ld a,020h                              ; F9D4
	call CONOUT                            ; F9D6
	ld a,(hl)                              ; F9D9
	call PUTHEX                            ; F9DA
	inc hl                                 ; F9DD
	call CMPHLBC                           ; F9DE
	ret nc                                 ; F9E1
	ld a,l                                 ; F9E2
	and 00fh                               ; F9E3
	jp nz,LF9D4                            ; F9E5
	jp LF9C9                               ; F9E8
CMPHLBC:
	ld a,h                                 ; F9EB  carry if HL < BC (only correct while H <= B)
	cp b                                   ; F9EC
	ret c                                  ; F9ED
	ld a,l                                 ; F9EE
	cp c                                   ; F9EF
	ret                                    ; F9F0
CMD_L:
	jp HDBOOT                              ; F9F1  L: boot from hard disk

;-----------------------------------------------------------------------
; Unreachable code (no table entry or call points here)
;-----------------------------------------------------------------------
UNUSED_ENTER:
	push hl                                ; F9F4  UNREACHABLE: nothing jumps here except its own loop
	ld hl,CRLF_STR                         ; F9F5
	call PUTS                              ; F9F8
	pop hl                                 ; F9FB
	call PUTADDR                           ; F9FC
	ld a,020h                              ; F9FF
	call CONOUT                            ; FA01
LFA04:
	call CONOUT                            ; FA04
	call GETBYTE                           ; FA07
	ld (hl),a                              ; FA0A
	inc hl                                 ; FA0B
	ld a,l                                 ; FA0C
	and 00fh                               ; FA0D
	ld a,020h                              ; FA0F
	jp nz,LFA04                            ; FA11
	jp UNUSED_ENTER                        ; FA14
UNUSED_BAUDOT:
	push hl                                ; FA17  UNREACHABLE: ASCII -> Baudot lookup in BAUDOT_TAB
	ld hl,BAUDOT_TAB                       ; FA18
	push bc                                ; FA1B
	ld b,a                                 ; FA1C
LFA1D:
	cp (hl)                                ; FA1D
	ld a,l                                 ; FA1E
	jp z,LFA2B                             ; FA1F
	inc l                                  ; FA22
	cp 03fh                                ; FA23
	ld a,b                                 ; FA25
	jp nz,LFA1D                            ; FA26
	ld a,004h                              ; FA29
LFA2B:
	pop bc                                 ; FA2B  returns low byte of the table address, not a clean 5-bit code
	pop hl                                 ; FA2C
	ret                                    ; FA2D

;-----------------------------------------------------------------------
; S: substitute memory  S:aaaa  then per byte: space = next, hh = store
;-----------------------------------------------------------------------
CMD_S:
	call GETADDR                           ; FA2E  S: start address
LFA31:
	ld a,l                                 ; FA31
	and 007h                               ; FA32
	jp nz,LFA42                            ; FA34
	push hl                                ; FA37
	ld hl,CRLF_STR                         ; FA38
	call PUTS                              ; FA3B
	pop hl                                 ; FA3E
	call PUTADDR                           ; FA3F
LFA42:
	ld a,(hl)                              ; FA42
	call PUTHEX                            ; FA43
	ld a,02dh                              ; FA46
	call CONOUT                            ; FA48
	call GETCH                             ; FA4B  space = keep and move on, hex digits = replace
	cp 020h                                ; FA4E
	jp nz,LFA57                            ; FA50
	inc hl                                 ; FA53
	jp LFA31                               ; FA54
LFA57:
	push hl                                ; FA57
	ld hl,LFA60                            ; FA58
	push hl                                ; FA5B
	push bc                                ; FA5C
	jp GETBYTE2                            ; FA5D
LFA60:
	pop hl                                 ; FA60
	ld (hl),a                              ; FA61
	ld a,020h                              ; FA62
	call CONOUT                            ; FA64
	inc hl                                 ; FA67
	jp LFA31                               ; FA68

;-----------------------------------------------------------------------
; M: move  M:ssss:eeee:dddd      F: fill  F:ssss:eeee hh
;-----------------------------------------------------------------------
CMD_M:
	call GETADDR                           ; FA6B  M: source start
	ex de,hl                               ; FA6E
	call GETADDR                           ; FA6F  source end
	push hl                                ; FA72
	call GETADDR                           ; FA73  destination
	ex de,hl                               ; FA76
	pop bc                                 ; FA77
	inc bc                                 ; FA78
LFA79:
	call CMPHLBC                           ; FA79
	ret nc                                 ; FA7C
	ld a,(hl)                              ; FA7D
	ld (de),a                              ; FA7E
	inc hl                                 ; FA7F
	inc de                                 ; FA80
	jp LFA79                               ; FA81
CMD_F:
	call GETADDR                           ; FA84  F: start address
	ex de,hl                               ; FA87
	call GETADDR                           ; FA88  end address
	push hl                                ; FA8B
	ex de,hl                               ; FA8C
	pop bc                                 ; FA8D
	inc bc                                 ; FA8E
	call GETBYTE                           ; FA8F  fill byte (2 hex digits, no ':' prompt)
	ld d,a                                 ; FA92
LFA93:
	call CMPHLBC                           ; FA93
	ret nc                                 ; FA96
	ld (hl),d                              ; FA97
	inc hl                                 ; FA98
	jp LFA93                               ; FA99

;-----------------------------------------------------------------------
; Hardware init: both 8251s, clear the terminal screen, 8255 setup.
; No autoboot: goes straight to the monitor prompt.
;-----------------------------------------------------------------------
INIT:
	ld a,0ceh                              ; FA9C  8251 mode: 2 stop bits, no parity, 8 data bits, x16 clock
	out (SIO2_CTRL),a                      ; FA9E
	out (CON_CTRL),a                       ; FAA0
	ld a,027h                              ; FAA2  8251 command: RTS, RxE, DTR, TxEN
	out (SIO2_CTRL),a                      ; FAA4
	out (CON_CTRL),a                       ; FAA6
	ld a,01bh                              ; FAA8  ESC ...
	call CONOUT                            ; FAAA
	ld a,02ah                              ; FAAD  ... '*' = clear screen on TeleVideo-style terminals
	call CONOUT                            ; FAAF
	in a,(CON_DATA)                        ; FAB2  discard any pending input
	ld a,0a2h                              ; FAB4  8255: port A mode 1 output, port B input, port C outputs
	out (PPI_CTRL),a                       ; FAB6
	ld a,00bh                              ; FAB8  8255 bit set: PC5 = 1
	out (PPI_CTRL),a                       ; FABA
	jp MONITOR                             ; FABC

;-----------------------------------------------------------------------
; Unused space. Not FFh: mostly 00/FF alternating with stray bits, i.e.
; leftover contents of the EPROM programmer's buffer. Identical in all
; four reads, so this is not bit rot.
;-----------------------------------------------------------------------
	defb 0dfh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h; FABF
	defb 0ffh,000h,0b5h,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h; FACF
	defb 0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h; FADF
	defb 0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0f7h,000h,0ffh,000h,0ffh,095h; FAEF
	defb 0aah,0aah,080h,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h; FAFF
	defb 0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h; FB0F
	defb 0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h; FB1F
	defb 0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h; FB2F
	defb 0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h; FB3F
	defb 0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h; FB4F
	defb 0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h; FB5F
	defb 0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h; FB6F
	defb 0ffh,004h,06dh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h; FB7F
	defb 0ffh,000h,0f7h,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h; FB8F
	defb 0ffh,000h,0feh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h; FB9F
	defb 0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h; FBAF
	defb 0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h; FBBF
	defb 0ffh,000h,0dfh,000h,0ffh,000h,0ffh,000h,0bfh,000h,0ffh,000h,0ffh,000h,0ffh,000h; FBCF
	defb 0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h; FBDF
	defb 0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,062h; FBEF
	defb 0dfh                              ; FBFF

;=======================================================================
; L: boot from the hard disk (XCOMP ST/S controller at 60h-67h)
;
; Register names follow the XCOMP ST/S Users Manual (see ../disk/README.md).
; 60h in = drive status: bit0 READY, bit1 WRITE FAULT, bit2 TRACK 00,
; bit3 SEEKING/, bit4 DRIVE SELECTED/, bit5 INDEX, bit7 SEEK END. 61h out
; = drive select, direction, head select, precomp, write current. 62h/63h
; = seek count. 64h out = BANK1, DATA BUFFER ENABLE, COMPARE BUFFER
; ENABLE, START; 65h = buffer address; 66h = data.
;
; Flow: load the read microcode (BANK0) and write microcode (BANK1),
; restore to track 0, set the header compare buffer to 00 00 00 00, run
; the read microcode, copy the 256-byte data buffer to 0000h, jump there.
; This section has its own copies of the console routines, so it was
; probably written as a separate module.
;=======================================================================
HDBOOT:
	ld sp,00100h                           ; FC00  stack at 0100h (the boot sector later overwrites it)
	xor a                                  ; FC03
	out (HD_MODE),a                        ; FC04  HDC idle
	out (HD_DRV),a                         ; FC06  drive control off
	out (HD_SEL),a                         ; FC08  drive deselected
	ld hl,HDTAB_A                          ; FC0A  load read microcode into BANK0
	call HDLOADTAB                         ; FC0D
	ld hl,HDTAB_B                          ; FC10  load write microcode into BANK1
	call HDLOADTAB                         ; FC13
	ld a,041h                              ; FC16  DRIVE SELECT + INHIBIT PRE-COMPENSATION
	out (HD_SEL),a                         ; FC18
	ld a,002h                              ; FC1A  ENABLE INTERFACE
	out (HD_DRV),a                         ; FC1C
	call HDRESTORE                         ; FC1E  step out to track 0 if needed
	jp nz,HDFAIL                           ; FC21
HDREAD0:
	call HDREADSEC                         ; FC24  read cylinder 0 / head 0 / sector 0 into the HDC buffer
	jp nz,HDFAIL                           ; FC27
	ld a,002h                              ; FC2A  DATA BUFFER ENABLE
	out (HD_MODE),a                        ; FC2C
	xor a                                  ; FC2E  pointer = 0
	out (HD_PTR),a                         ; FC2F
	ld b,a                                 ; FC31  B = 0 -> 256 bytes
	ld hl,00000h                           ; FC32
	in a,(HD_DATA)                         ; FC35  dummy read primes the buffer pipeline
	nop                                    ; FC37
LFC38:
	in a,(HD_DATA)                         ; FC38
	ld (hl),a                              ; FC3A
	inc hl                                 ; FC3B
	dec b                                  ; FC3C
	jp nz,LFC38                            ; FC3D
	jp 00000h                              ; FC40  run the boot sector
HDREADSEC:
	ld d,00ah                              ; FC43  up to 10 tries
	ld a,004h                              ; FC45  COMPARE BUFFER ENABLE (header compare)
	out (HD_MODE),a                        ; FC47
	ld a,0eah                              ; FC49  pointer = EAh
	out (HD_PTR),a                         ; FC4B
	ld b,004h                              ; FC4D  4-byte compare value = 00 00 00 00
	xor a                                  ; FC4F
LFC50:
	out (HD_DATA),a                        ; FC50
	dec b                                  ; FC52
	jp nz,LFC50                            ; FC53
LFC56:
	call HDCHKRDY                          ; FC56
	ret nz                                 ; FC59
	xor a                                  ; FC5A
	out (HD_MODE),a                        ; FC5B
	ld a,0d7h                              ; FC5D  microcode start address D7h (= start of table A)
	out (HD_PTR),a                         ; FC5F
	ld a,008h                              ; FC61  START, BANK0 = read microcode
	out (HD_MODE),a                        ; FC63
	ld hl,00000h                           ; FC65  timeout counter
LFC68:
	in a,(HD_MODE)                         ; FC68  bit 0 = DONE
	rrca                                   ; FC6A
	jp c,LFC79                             ; FC6B
	dec hl                                 ; FC6E
	ld a,h                                 ; FC6F
	or l                                   ; FC70
	jp nz,LFC68                            ; FC71
	out (HD_MODE),a                        ; FC74  timeout: stop the HDC (A = 0)
	jp LFC8E                               ; FC76
LFC79:
	in a,(HD_MODE)                         ; FC79
	and 00eh                               ; FC7B  bits 1-3 = BUSY, COMPARE ERROR, CRC ERROR
	ld b,a                                 ; FC7D
	xor a                                  ; FC7E
	out (HD_MODE),a                        ; FC7F  HDC idle
	in a,(HD_DRV)                          ; FC81  WRITE FAULT?
	and 002h                               ; FC83
	call nz,HDCLRFLT                       ; FC85  ...clear it by deselecting/reselecting
	or b                                   ; FC88
	ret z                                  ; FC89  no errors: done (Z)
	dec d                                  ; FC8A
	jp nz,LFC56                            ; FC8B
LFC8E:
	ld hl,MSG_READFAIL                     ; FC8E  NZ + HL = message: read failed
	or 001h                                ; FC91
	ret                                    ; FC93
HDRESTORE:
	in a,(HD_DRV)                          ; FC94  ST-506 TRACK 0 already?
	and 004h                               ; FC96
	xor 004h                               ; FC98
	ret z                                  ; FC9A
	call HDCHKRDY                          ; FC9B
	ret nz                                 ; FC9E
	ld a,0ffh                              ; FC9F  seek count = 01FFh (511 steps max)
	out (HD_STEPLO),a                      ; FCA1
	ld a,001h                              ; FCA3
	out (HD_STEPHI),a                      ; FCA5
	ld a,001h                              ; FCA7  DRIVE SELECT, direction out
	out (HD_SEL),a                         ; FCA9
	ld a,003h                              ; FCAB  SEEK + ENABLE INTERFACE
	out (HD_DRV),a                         ; FCAD
	ld hl,00000h                           ; FCAF
	ld b,00ah                              ; FCB2
LFCB4:
	in a,(HD_DRV)                          ; FCB4  wait for TRACK 0
	and 004h                               ; FCB6
	jp nz,LFCCF                            ; FCB8
	dec hl                                 ; FCBB
	ld a,h                                 ; FCBC
	or l                                   ; FCBD
	jp nz,LFCB4                            ; FCBE
	dec b                                  ; FCC1
	jp nz,LFCB4                            ; FCC2
	out (HD_STEPHI),a                      ; FCC5  timeout: clear seek count
	out (HD_STEPLO),a                      ; FCC7
	ld hl,MSG_RESTFAIL                     ; FCC9  NZ + HL = message: restore failed
	or 001h                                ; FCCC
	ret                                    ; FCCE
LFCCF:
	xor a                                  ; FCCF  track 0 reached: clear seek count
	out (HD_STEPHI),a                      ; FCD0
	out (HD_STEPLO),a                      ; FCD2
	call HDWAITSC                          ; FCD4  let the drive settle
	xor a                                  ; FCD7
	ret                                    ; FCD8
HDWAITSC:
	ld hl,00000h                           ; FCD9  wait for ST-506 SEEK COMPLETE (bit 7), with timeout
	ld d,003h                              ; FCDC
LFCDE:
	in a,(HD_DRV)                          ; FCDE
	rla                                    ; FCE0
	ret c                                  ; FCE1
	dec hl                                 ; FCE2
	ld a,h                                 ; FCE3
	or l                                   ; FCE4
	jp nz,LFCDE                            ; FCE5
	dec d                                  ; FCE8
	jp nz,LFCDE                            ; FCE9
	ret                                    ; FCEC
HDCHKRDY:
	in a,(HD_DRV)                          ; FCED  ST-506 READY (bit 0)?
	and 001h                               ; FCEF
	xor 001h                               ; FCF1
	ret z                                  ; FCF3
	ld hl,MSG_NOTRDY                       ; FCF4  NZ + HL = message: drive not ready
	or 001h                                ; FCF7
	ret                                    ; FCF9
HDCLRFLT:
	xor a                                  ; FCFA  deselect then reselect: clears an ST-506 write fault
	out (HD_SEL),a                         ; FCFB
	ld a,041h                              ; FCFD
	out (HD_SEL),a                         ; FCFF
	ret                                    ; FD01
HDLOADTAB:
	ld a,(hl)                              ; FD02  table: [mode][pointer] then records, all data -> HD_DATA
	out (HD_MODE),a                        ; FD03
	inc hl                                 ; FD05
	ld a,(hl)                              ; FD06
	out (HD_PTR),a                         ; FD07
	inc hl                                 ; FD09
LFD0A:
	ld a,(hl)                              ; FD0A
	or a                                   ; FD0B
	ret z                                  ; FD0C
	inc hl                                 ; FD0D
	ld b,a                                 ; FD0E
	rla                                    ; FD0F  bit 7 set = run-length record
	jp c,LFD1E                             ; FD10
LFD13:
	ld a,(hl)                              ; FD13  literal record: n bytes follow
	out (HD_DATA),a                        ; FD14
	inc hl                                 ; FD16
	dec b                                  ; FD17
	jp nz,LFD13                            ; FD18
	jp LFD0A                               ; FD1B
LFD1E:
	or a                                   ; FD1E  run record: (n & 7Fh) copies of the next byte
	rra                                    ; FD1F
	ld b,a                                 ; FD20
	ld a,(hl)                              ; FD21
	inc hl                                 ; FD22
LFD23:
	out (HD_DATA),a                        ; FD23
	dec b                                  ; FD25
	jp nz,LFD23                            ; FD26
	jp LFD0A                               ; FD29

;-----------------------------------------------------------------------
; XCOMP controller microcode, loaded by HDLOADTAB: table A into BANK0
; (read microcode, started at D7h), table B into BANK1 (write microcode,
; never run by this ROM). Each starts with the HD_MODE value and the
; HD_PTR start address; then records: n (1-7Fh) = n literal bytes follow,
; 80h+n = next byte repeated n times, 00h = end.
;
; The microcode word format isn't in the manual (the schematic should
; show it). The shapes fit a sector: 12-byte runs for sync fields, 4 for
; the header compare, 2 for check bytes.
;-----------------------------------------------------------------------
HDTAB_B:
	defb 001h,0d3h                         ; FD2C  -> HD_MODE 01h, HD_PTR D3h
	defb 002h,040h,041h                    ; FD2E  literal: 40 41
	defb 083h,040h                         ; FD31  3 x 40h
	defb 08ch,06dh                         ; FD33  12 x 6Dh
	defb 001h,063h                         ; FD35  literal: 63
	defb 084h,065h                         ; FD37  4 x 65h
	defb 082h,067h                         ; FD39  2 x 67h
	defb 002h,049h,040h                    ; FD3B  literal: 49 40
	defb 091h,050h                         ; FD3E  17 x 50h
	defb 005h,05bh,0ddh,05dh,050h,00fh     ; FD40  literal: 5B DD 5D 50 0F
	defb 000h                              ; FD46  end

HDTAB_A:
	defb 000h,0d7h                         ; FD47  -> HD_MODE 00h, HD_PTR D7h
	defb 002h,040h,041h                    ; FD49  literal: 40 41
	defb 083h,040h                         ; FD4C  3 x 40h
	defb 08ch,06dh                         ; FD4E  12 x 6Dh
	defb 001h,063h                         ; FD50  literal: 63
	defb 084h,065h                         ; FD52  4 x 65h
	defb 082h,067h                         ; FD54  2 x 67h
	defb 001h,049h                         ; FD56  literal: 49
	defb 082h,040h                         ; FD58  2 x 40h
	defb 08ch,06dh                         ; FD5A  12 x 6Dh
	defb 003h,063h,0e7h,067h               ; FD5C  literal: 63 E7 67
	defb 087h,00fh                         ; FD60  7 x 0Fh
	defb 002h,040h,041h                    ; FD62  literal: 40 41
	defb 083h,040h                         ; FD65  3 x 40h
	defb 08ch,06dh                         ; FD67  12 x 6Dh
	defb 001h,063h                         ; FD69  literal: 63
	defb 082h,065h                         ; FD6B  2 x 65h
	defb 082h,060h                         ; FD6D  2 x 60h
	defb 082h,067h                         ; FD6F  2 x 67h
	defb 001h,00fh                         ; FD71  literal: 0F
	defb 000h                              ; FD73  end

;-----------------------------------------------------------------------
; Hard disk error path and the module's own console routines
;-----------------------------------------------------------------------
HDFAIL:
	call HDPUTS                            ; FD74  print the error message
	call HDCONIN                           ; FD77  wait for any key
	ld hl,MSG_CRLF2                        ; FD7A
	call HDPUTS                            ; FD7D
	jp HDREAD0                             ; FD80  retry the read (not the restore)
HDPUTS:
	ld a,(hl)                              ; FD83
	inc hl                                 ; FD84
	or a                                   ; FD85
	ret z                                  ; FD86
	ld c,a                                 ; FD87
	call HDCONOUT                          ; FD88
	jp HDPUTS                              ; FD8B
HDCONIN:
	in a,(CON_CTRL)                        ; FD8E
	and 002h                               ; FD90
	jp z,HDCONIN                           ; FD92
	in a,(CON_DATA)                        ; FD95
	and 07fh                               ; FD97
	ret                                    ; FD99
HDCONOUT:
	in a,(CON_CTRL)                        ; FD9A
	and 001h                               ; FD9C
	jp z,HDCONOUT                          ; FD9E
	ld a,c                                 ; FDA1
	out (CON_DATA),a                       ; FDA2
	ret                                    ; FDA4

;-----------------------------------------------------------------------
; Hard disk messages
;-----------------------------------------------------------------------
MSG_NOTRDY:
	defb 007h,00dh,00ah,"* Drive not Ready ",000h; FDA5
MSG_RESTFAIL:
	defb 007h,00dh,00ah,"* Restore Failed ",000h; FDBB
MSG_READFAIL:
	defb 007h,00dh,00ah,"* Read Failed ",000h; FDD0
MSG_CRLF2:
	defb 00dh,00ah,000h                    ; FDE2

;-----------------------------------------------------------------------
; Unused space (programmer buffer leftovers, see FABFh)
;-----------------------------------------------------------------------
	defb 0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h; FDE5
	defb 0ffh,000h,0ffh,010h,0ffh,000h,0ffh,000h,0ffh,003h,03fh,017h,0a9h,000h,0ffh,000h; FDF5
	defb 0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h; FE05
	defb 0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h; FE15
	defb 0ffh,040h,0ffh,000h,0bfh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h; FE25
	defb 0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,001h,0ffh,000h,0ffh,000h; FE35
	defb 0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h; FE45
	defb 0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h; FE55
	defb 0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h; FE65
	defb 0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,05ah,0d4h,000h,0ffh,000h; FE75
	defb 0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,004h,0d7h,000h,0ffh,000h; FE85
	defb 0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h; FE95
	defb 0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,020h; FEA5
	defb 0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h; FEB5
	defb 0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,002h,08fh,000h,0ffh,000h; FEC5
	defb 0ffh,000h,0efh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h; FED5
	defb 0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h; FEE5
	defb 0ffh,000h,0ffh,012h,0ffh,000h,0ffh,000h,0ffh,031h,093h,036h,00ah,000h,0ffh,000h; FEF5
	defb 0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0bfh,000h,0fbh,000h,077h,000h,0ffh,000h; FF05
	defb 0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0fbh,000h,0eeh,000h,0ffh,000h; FF15
	defb 0ffh,000h,0ffh,000h,0efh,000h,0ffh,000h,07fh,000h,0ffh,000h,0ffh,000h,0ffh,000h; FF25
	defb 0ffh,000h,0ffh,000h,0bfh,000h,0ffh,000h,0ffh,000h,0b7h,000h,0ffh,000h,0ffh,000h; FF35
	defb 0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,077h,000h,0edh,000h,0ffh,000h; FF45
	defb 0ffh,000h,0beh,080h,0fbh,000h,0ffh,000h,0ffh,000h,0ebh,000h,0ddh,000h,0feh,000h; FF55
	defb 0ffh,000h,0dah,000h,0ffh,000h,0ffh,000h,0ffh,000h,0dbh,000h,0fbh,000h,0ffh,000h; FF65
	defb 0ffh,000h,06fh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0feh,000h,087h,000h,0ffh,000h; FF75
	defb 0ffh,000h,0ffh,000h,0f7h,000h,0ffh,000h,0ffh,000h,0dbh,040h,072h,000h,0ffh,000h; FF85
	defb 0ffh,000h,0ffh,000h,0afh,000h,0ffh,000h,0ffh,000h,0edh,000h,0fbh,000h,0ffh,000h; FF95
	defb 0ffh,000h,0ffh,000h,0ffh,000h,0fbh,000h,0ffh,000h,0feh,000h,0feh,000h,0dfh,000h; FFA5
	defb 0ffh,000h,0fbh,002h,0ffh,000h,0ffh,000h,0ffh,000h,0ceh,000h,0ffh,000h,0ffh,000h; FFB5
	defb 0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0efh,080h,008h,000h,0ffh,000h; FFC5
	defb 0ffh,000h,0ebh,000h,0f3h,000h,0ffh,000h,0ffh,000h,0dfh,000h,0ffh,000h,0ffh,000h; FFD5
	defb 0ffh,000h,0afh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0ffh,000h,0feh,000h,0ffh,000h; FFE5
	defb 0ffh,000h,0ffh,000h,019h,000h,0ffh,000h,0ffh,052h,000h; FFF5
