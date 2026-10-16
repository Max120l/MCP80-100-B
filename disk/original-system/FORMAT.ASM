; DISK FORMATTING PROGRAM
; WRITTEN BY DICK CULBERTSON IN AUG, 1977
; MODIFIED BY DON TARBELL IN SEP, 1977
; MODIFIED BY MARC FARJEON - MAY 24, 1979.
; MODIFIED BY JERRY MULCHIN - JUNE 27, 1979
; MODIFIED BY JIM YATES - DEC, 1980
;   FOR USE WITH NEW CONTROLLER BOARD
; Modified 5-12-80 for multi-drive select
; and double sided select, and read test
; of the formatted track. (G.W.Mulchin.)
;Modified 6-4-80 for double sided code byte insert
;during formatting. Code = E7h, doub sided.
;
; This program will format either a single
; sided or a double sided disk and check
; each track for CRC or RNF errors. If any
; errors of this type are found, the program
; will reformat that track again, recheck it
; again, for 5 retrys. If the retry count
; exceeds 5, then that disk is declared fatal
; and should be replaced.
;
true	equ	-1
false	equ	not true
;
SCC     EQU     TRUE            ;TRUE EQU 6MHZ MCP/SCC-6
intrp	equ	false		;true if using interrupts
DCOM	EQU	0F8H		;DISK COMMAND PORT
DSTAT	EQU	0F8H		;DISK STATUS PORT
TRACK	EQU	0F9H		;DISK TRACK COMMAND
SECTP	EQU	0FAH		;DISK SECTOR PORT
DDATA	EQU	0FBH		;DISK DATA PORT
WAIT	EQU	0FCH		;DISK WAIT CONTROL PORT
ENTRY	EQU	5		;ENTRY PT TO FDOS
bell	equ	'G'-40h		;cntl-G = bell
readc	equ	80h		;read command
rstor	equ	0		;restore command
step	equ	01010000b	;step in command
hlab	equ	8		;0=no head load, 8=head load
stprat	equ	1		;0=3ms,1=6ms,2=10ms
;
;
	ORG	0100H		;LOAD & EX HERE
;
;STARTING MESSAGE
;	
	if	intrp
begin:	di
	endif

	lxi	h,0		;clear h,l
	dad	sp		;get cpm stack pointer
	shld	oldstk		;save it for later
bgin:	lxi	sp,stack	;set up local stack
	mvi	a,0e5h
	sta	spbyte+1
	MVI	C,9		;GET CODE FOR PRINT.
	LXI	D,MSG		;GET ADR OF MESSAGE.
	CALL	ENTRY		;PRINT OPENING.
	lxi	d,drive		;get drive to format
	mvi	c,9
	call	entry		;print message
	mvi	c,1		;now get the drive
	call	entry
	call	conv		;check cases
	cpi	'Q'		;quit?
	jz	exit		;yes
	ani	7		;strip ascii bits
	dcr	a		;make cpm drive
	add	a
	add	a
	add	a
	add	a		;shift 4 places
	sta	sdrive		;save drive code
	out	wait		;select the drive
	lxi	d,dubmsg
	mvi	c,9
	call	entry		;ask about double sided drives
	mvi	c,1
	call	entry
	call	conv		;check cases
	cpi	'N'		;not using dub sided disks
	mvi	a,0
	sta	dubsid
	jz	bgin1		;doing single sided
	cma
	sta	dubsid		;doing doub. sided
	mvi	a,0e7h		;double sided code byte
	sta	spbyte+1	;modify byte in spfill routine.
bgin1:	lxi	d,crlf
	mvi	c,9
	call	entry
	MVI	C,9
	LXI	D,RDY		;PRINT READY MESSAGE.
	CALL	ENTRY
	MVI	C,1		;READ A CHAR FROM KB.
	CALL	ENTRY
	call	conv		;convert lower to upper case
	CPI	'Y'		;IF IT'S A 'Y',
	jz	START		;GO AHEAD AND DO IT.
exit:	lhld	oldstk		;recover cpm stack
	sphl			;restore it

	if	intrp
	ei
	endif

	ret			;go back to operating system
;
;conv - Convert letters from lower case
;	to upper case.
;entry:	accum = char to convert
;exit:	accum = converted char if lower case
;
conv:	cpi	'a'		;check case
	rc			;upper case already.
	cpi	'z'+1
	rnc
	ani	5fh		;if lower case, change it
	ret
;
; RESTORE DRIVE TO TRACK 00
;
START:	lxi	d,crlf		;print cr,lf on console
	mvi	c,9
	call	entry
	MVI	A,rstor+stprat	;restore head to trk 0
	OUT	DCOM		;ISSUE HOME CMD
	IN	WAIT		;WAIT FOR HOME
	MVI	C,0		;SET TRACK NUMBER TO 0
	MVI	H,77		;SET TOTAL TRACKS TO 77
format:
	call	side0
	mvi	a,5		;retrys
	sta	errcnt		;save it
rformat:push	b		;save b,c
	push	d
	push	h
	lxi	d,fmsg0		;format msg
	mvi	c,9
	call	entry
	pop	h
	pop	d
	pop	b
	call	nxttrk		;format the disk
	push	b
	push	d
	push	h
	lxi	d,rmsg0		;read msg
	mvi	c,9
	call	entry
	pop	h
	pop	d
	pop	b
	call	read		;test formatted track
	ora	a		;read ok?
	jz	side		;yes,	check for side 1
	lda	errcnt		;error, decrease count
	dcr	a
	sta	errcnt
	jnz	rformat		;reformat and check again
	lxi	d,disker	;point to error message
	mvi	c,9
	call	entry
	jmp	bgin		;exit and return to start.
side:
	lda	dubsid		;check if doing double sided
	ora	a		;zero = single sided only
	jz	newtrk		;do other side if <> 0
	call	side1		;now do side 1
	mvi	a,5
	sta	errcnt
rfmat:	push	b
	push	d
	push	h
	lxi	d,fmsg1		;format side 1 msg
	mvi	c,9
	call	entry
	pop	h
	pop	d
	pop	b
	call	nxttrk
	push	b
	push	d
	push	h
	lxi	d,rmsg1
	mvi	c,9
	call	entry
	pop	h
	pop	d
	pop	b
	call	read		;check for disk errors
	ora	a		;errors?
	jz	newtrk		;no
	lda	errcnt		;error, decrease count
	dcr	a
	sta	errcnt
	jnz	rfmat		;reformat and check again
	lxi	d,disker	;point to error message
	mvi	c,9
	call	entry
	jmp	bgin		;exit to start
newtrk:	inr  c			;BUMP TRACK #
	dcr  h			;TRK COUNT =COUNT -1
	jnz  bmptrk 		;IF NOT 0 THEN DO MORE
	jmp  bgin		;GO BACK TO DO ROUTINE AGAIN
;
side0:	lda	sdrive
	ani	10110000b	;select side 0
	out	wait
	ret
;
side1:	lda	sdrive
	ori	01000000b	;select side 1
	out	wait
	ret
;
BMPTRK:	MVI  A,step+hlab+stprat	;LOAD STEP IN
	OUT  DCOM   		;STEP IN
	in	wait
	ora	a
	IN  WAIT		;WAIT TIL DONE
	IN   DSTAT  		;CHECK STATUS
	JMP  format
;
NXTTRK:	MVI	D,1		;SECTOR CNT TO 0
	MVI	E,26		;SET MAX # SECTORS -1 
	MVI	B,40		;GAP 4 PREINDEX 40 BYTES OF FF
	MVI	A,0F4H		;LOAD TRACK WRITE COMMAND
	OUT	DCOM		;ISSUE TRACK WRITE
;
; WRITE PREINDEX FILL
;
PREIND:	IN	WAIT		;WAIT FOR DRQ
	ORA	A		;SET FLAGS
	JP	ERRMSG		;JMP OUT IF ERROR
	MVI	A,0FFH		;LOAD PREINDEX FILL
	OUT	DDATA		;WRITE IT ON DISK
	DCR	B		;COUNT = COUNT - 1
	JNZ	PREIND		;GO BACK TILL B =0
	MVI	B,6
PREIN1:	IN	WAIT
	ORA	A
	JP	ERRMSG
	XRA	A
	OUT	DDATA
	DCR	B
	JNZ	PREIN1
;
; WRITE ADDRESS MARK ON TRACK
;
	IN	WAIT		;WAIT FOR DRQ
	ORA	A		;SET FLAGS
	JP	ERRMSG		;JMP OUT IF ERROR
	MVI	A,0FCH		;LOAD ADDRESS MARK
	OUT	DDATA		;WRITE IT ON DISK
;
; POST INDEX GAP
;
	MVI	B,26		;SET # OF BYTES
POSTID:	IN	WAIT		;WAIT FOR DRQ
	ORA	A		;SET FLAGS
	JP	ERRMSG		;JMP OUT IF ERROR
	MVI	A,0FFH		;LOAD FILL DATA
	OUT	DDATA		;WRITE IT ON DISK
	DCR	B		;COUNT = COUNT - 1
	JNZ	POSTID		;IF NOT 0 GO BACK
;
; PRE ID SECTION
;
ASECT:	MVI	B,6		;GET # OF BYTES
SECTOR:	IN	WAIT		;WAIT FOR DRQ
	ORA	A		;SET FLAGS
	JP	ERRMSG		;JMP OUT IF ERROR
	XRA  A			;MAKE A = 0
	OUT  DDATA  		;WRITE IT ON TRACK
	DCR  B			;COUNT = COUNT=1
	JNZ  SECTOR 		;JMP BACK IF NOT DONE
;
; WRITE ID ADDRESS MARK
;
	IN   WAIT   		;WAIT FOR DRQ
	ORA  A			;SET FLAGS
	JP   ERRMSG 		;IF ERROR JMP OUT
	MVI  A,0FEH 		;GET ADDRESS MARK
	OUT  DDATA  		;WRITE IT ON DISK
;
; WRITE TRACK NUMBER ON DISK
;
	IN   WAIT   		;WAIT FOR DRQ
	ORA  A			;SET FLAGS
	JP   ERRMSG 		;JMP OUT IF ERROR
	MOV  A,C		;GET TRACK NUMBER
	OUT  DDATA  		;WRITE IT ON DISK
;
; WRITE ONE BYTE OF 00
;
	IN   WAIT   		;WAIT FOR DRQ
	ORA  A			;SET FLAGS
	JP   ERRMSG 		;JMP OUT IF ERROR
	XRA  A			;SET A TO 0
	OUT DDATA   		;WRITE IT ON DISK
;
; WRITE SECTOR # ON DISK
;
	IN   WAIT   		;WAIT FOR DRQ
	ORA  A			;SET FLAGS
	JP   ERRMSG 		;JMP OUT IF ERROR
	MOV  A,D		;GET SECTOR #
	OUT DDATA   		;WRITE IT ON DISK
;
; ONE MORE BYTE 0
;
	IN   WAIT   		;WAIT FOR DRQ
	ORA  A			;SET FLAGS
	JP   ERRMSG 		;JMP OUT IF ERROR
	XRA  A			;SET A TO 00
	OUT  DDATA  		;WRITE IT ON DISK
	INR  D			;BUMP SECT. #
;
; WRITE 2 CRC'S ON THIS SECTOR
;
	IN   WAIT   		;WAIT FOR DRQ
	ORA  A			;SET FLAGS
	JP   ERRMSG 		;JMP OUT IF ERROR
	MVI  A,0F7H 		;GET CRC PATTERN
	OUT DDATA   		;WRITE IT ON DISK
;
; PRE DATA 17 BYTES FF's
;
	MVI  B,11   		;SET COUNT
PREDAT:	IN   WAIT   		;WAIT FOR DRQ
	ORA  A			;SET FLAGS
	JP   ERRMSG 		;JMP OUT IF ERROR
	MVI  A,0FFH		;SET A TO FF
	OUT  DDATA  		;WRITE IT ON DISK
	DCR  B			;REDUCE COUNT BY 1
	JNZ  PREDAT 		;GO BACK IF NOT DONE
	MVI  B,6
PREDA1:	IN   WAIT
	ORA  A
	JP   ERRMSG
	XRA  A
	OUT  DDATA
	DCR  B
	JNZ  PREDA1

;
; DATA ADDRESS MARK
;
	IN   WAIT   		;WAIT FOR DRQ
	ORA  A			;SET FLAGS
	JP   ERRMSG 		;JMP OUT IF ERROR
	MVI  A,0FBH 		;GET DATA ADDRESS MARK
	OUT  DDATA  		;WRITE IT ON DISK
;
; FILL DATA FIELD WITH E5
;
	mvi  b,126		;126 E5's
DFILL:	IN   WAIT   		;WAIT FOR DRQ
	ORA  A			;YOU KNOW WHAT
	JP   errmsg 		;HAPPENS HERE BY NOW
	mvi  a,0e5h
	OUT  DDATA  		;WRITE IT ON DISK
	dcr  b			;bump 1 to count
	jnz  DFILL  		;DO TILL done
	mvi  b,2
spfill:	in   wait
	ora  a
	jp   errmsg
spbyte:	mvi  a,0e7h		;doub sided byte
	out  ddata
	dcr  b
	jnz  spfill
;
; WRITE CRC'S
;
	IN   WAIT   		;WAIT TILL DRQ
	ORA  A			;SET FLAGS
	JP   ERRMSG 		;JMP OUT IF ERROR
	MVI  A,0F7H 		;GET CRC BYTE
	OUT  DDATA  		;WRITE IT ON DISK
;
; END OF SECTOR FILL
;
	DCR  E			;REDUCE SECTOR COUNT
	JZ  ENDTRK		;IF 0 DO END OF TRACK RTN
DATGAP:	IN WAIT			;WAIT FOR DRQ
	ORA  A			;SET FLAGS   
	JP   ERRMSG 		;JMP OUT IF ERROR
	MVI  A,0FFH		;GET FILL CHARACTER
	OUT  DDATA  		;WRITE IT ON DISK
	JMP  POSTID-2 		;GO BACK FOR MORE
;
; DO TRACK & SECTOR HOUSE KEEPING
;
ENDTRK:
	mvi  a,0e5h
	sta  spbyte+1
	IN   WAIT   		;WAIT FOR DRQ OR INTRQ
	ORA  A			;SET FLAGS
	JP   DONE   		;JMP OUT IF ERROR
	MVI  A,0FFH		;LOAD A WITH FFH
	OUT  DDATA  		;WRITE IT ON DISK
	JMP  ENDTRK 		;DO UNTIL INTRQ
;
done:	in	dstat		;check status
	ani	0ffh
	jnz	errmsg
	ret			;return to caller
;
;Disk read test routine.
;checks disk for errors
;after track is formatted.
;
;entry:	none
;exit:	accum = 0 if formatted ok
;	accum = ff if more than 5 retrys
;
read:	push	b		;save formatting registers
	push	d		; on stack
	push	h
read1:	mvi	c,1		;start reading at sector 1
	mvi	b,26		;read 26 sectors total
readl:	call	dskset		;set up disk command
	ora	d		;or in read command
	out	dcom
rloop:	in	wait		;wait for intrq
	ora	a		;set flags
	jp	rdone		;read finished when positive
	in	ddata		;read a byte
	jmp	rloop		;accum = infinate bit bucket
rdone:	in	dstat		;check status
	ani	0ch		;check crc and rnf bits only
	jz	rnxt		;if = 0, read next sector
	jmp	rexit		;return to format program
rnxt:	inr	c		;bump sector number
	dcr	b		;decrease total sectors
	jnz	readl		;more to read.
rexit:	pop	h
	pop	d
	pop	b		;registers restored.
	ret			;return with error code.
;
dskset:	mvi	a,0d0h		;force intrp command
	out	dcom

        IF      SCC             ;IF 6MHZ SCC GIVE SOME DELAY
        xthl
        xthl
        ENDIF

	mvi	d,readc		;get read command
	mov	a,c		;get sector number
	out	sectp
	in	dstat		;check head load bit
	ani	20h
	mvi	a,0
	rz
	mvi	a,4		;set head load bit
	ret
;
;ERROR ROUTINE
;
ERRMSG:	lxi	d,error
	mvi	c,9
	call	entry
	lxi	sp,stack	;reset local stack
	jmp	bgin		;restart program
;
error:	db	bell,0dh
	db	'*********************************************',0dh,0ah
	db	'*					    *',0dh,0ah
	db	'*       E R R O R  in formatting disk       *',0dh,0ah
	db	'*					    *',0dh,0ah
	db	'*********************************************',0dh,0ah
	db	bell,'$'
disker:	db	bell,0dh
	db	'*********************************************',0dh,0ah
	db	'*					    *',0dh,0ah
	db	'*    Fatal disk errors, try another disk    *',0dh,0ah
	db	'*					    *',0dh,0ah
	db	'*********************************************',0dh,0ah
	db	bell,'$'
MSG:    db      'Single density,double sided format program',0dh,0ah
	db	'Version 1.1  dated 6-4-80',0dh,0ah
	db	0dh,0ah,'Formats 76 tracks',0dh,0ah
	db	'26 sectors/track with 128 bytes/sector',0dh,0ah,0dh,0ah,'$'
RDY:	DB	'Blank disk ready to FORMAT? (Y or N) $'
drive:	db	0DH,0AH,'ENTER (A) FOR FLOPPY DISK 1, (B) FOR FLOPPY DISK 2'
        DB      0DH,0AH,'      (C) FOR FLOPPY DISK 3, (D) FOR FLOPPY DISK 4'
        DB      0DH,0AH,'      (Q) FOR QUIT AND EXIT PROGRAM'
        db      0DH,0AH,'$'
dubmsg:	db	0dh,0ah,'Format a Double Sided Disk (Y or N)? $'
fmsg0:	db	0dh,'Formatting Side 0 $'
rmsg0:	db	0dh,'Reading    Side 0 $'
fmsg1:	db	0dh,'Formatting Side 1 $'
rmsg1:	db	0dh,'Reading    Side 1 $'
crlf:	db	0dh,0ah,'$'
;
	ds	128			;stack area
stack:	ds	1			;internal stack
oldstk:	ds	2			;cpm stack saved here
sdrive:	ds	1			;drive select code
dubsid:	ds	1			;0=single sided format
errcnt:	ds	1			;disk retrys
	end	begin
