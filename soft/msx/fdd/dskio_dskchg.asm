; errorcodes used by DSKIO, DSKCHG and GETDPB
;
; 0	write protect error
; 2	not ready error
; 4	data (crc) error
; 6	seek error
; 8	record not found error
; 10	write fault error
; 12	other error


; -----------------------------------------------------------------------------
; DSKIO
; -----------------------------------------------------------------------------
; Input: 	A	Drivenumber
;		F	Cx reset for read
;			Cx set for write
; 		B	number of sectors
; 		C	Media descriptor
;		DE	logical sectornumber
; 		HL	transferaddress
; Output:	F	Cx set for error
;			Cx reset for ok
;		A	if error, errorcode
;		B	total count of sectors read
; Changed:	AF,BC,DE,HL,IX,IY may be affected
; -----------------------------------------------------------------------------

DSKIO_STACK_SPACE: equ 32

DSKIO_IMPL:
    push af
    or a
    jr z,_DSKIO_OK_UNIT

    bit 7,b ;Sanity check: transfer of 64K or more requested?
    jr z,_DSKIO_OK_UNIT

    pop af
    ld a,12
    scf
    ret

_DSKIO_OK_UNIT:
    ld a,b
    pop bc
    rrc c   ;Now C:7 = 0 to read, 1 to write
    ld b,a

    ;ld a,b
    or a
    ret z   ;Nothing to read

    push hl
    push de
    push bc
    call USB_CHECK_DEV_CHANGE
    pop bc
    pop de
    pop hl
    ld a,12
    ret c   ;No device is connected

    ld ix,-DSKIO_STACK_SPACE
    add ix,sp
    ld sp,ix

    push hl
    push de
    push bc

    push ix
    pop de
    ld hl,_UFI_READ_SECTOR_CMD
    ld bc,12
    ldir
    
    pop bc
    bit 7,c
    jr z,_DSKIO_OK_CMD
    ld a,2Ah    ;Convert "Read sector" command into "Write sector" command
    ld (ix),a
_DSKIO_OK_CMD:    
    pop de
    ld (ix+4),d   ;First sector number
    ld (ix+5),e
    pop de      ;DE = Transfer address

    ;* Sector transfer loop. 
    ;  We read/write sectors one by one always, because some FDD units
    ;  choke when requested too many sectors at the same time
    ;  and become unresponsive until they are reset.
    ;
    ;  At this point:
    ;  IX = Read or write sector command, with the proper sector number
    ;  DE = Transfer address
    ;  B  = Sector count

    ld a,c
    and 80h
    ld c,a  ;Count of sectors transferred so far (bit 7 is still 0 to read or 1 to write)
_DSKIO_TX_LOOP:
    push bc
    push de

    ld a,d
    cp 3Eh
    jr c,_DSKIO_TX_DIRECT
    and 80h
    jr nz,_DSKIO_TX_DIRECT

    ;* Transfer using SECBUF and XFER (transfer address is between 4000h and 7FFFh)

    bit 7,c
    jr nz,_DSKIO_WRITE_XFER

_DSKIO_READ_XFER:
    ld de,(SECBUF)
    call _DSKIO_TX_ONE
    jr c,_DSKIO_TX_END_POP

    pop de
    push de
    ld hl,(SECBUF)
    ld bc,512
    call XFER

    jr _DSKIO_TX_STEP_OK

_DSKIO_WRITE_XFER:
    pop hl
    push hl
    ld de,(SECBUF)
    ld bc,512
    call XFER

    ld de,(SECBUF)
    call _DSKIO_TX_ONE
    jr c,_DSKIO_TX_END_POP

    jr _DSKIO_TX_STEP_OK

    ;* Direct transfer

_DSKIO_TX_DIRECT:
    call _DSKIO_TX_ONE
    jr c,_DSKIO_TX_END_POP

    ;* One sector was transferred ok

_DSKIO_TX_STEP_OK:
    pop de
    inc d
    inc d   ;Update transfer address (+512 bytes)

    pop bc
    inc c   ;Update total sectors already transferred count

    ld h,(ix+4)
    ld l,(ix+5)
    inc hl      ;Update sector number
    ld (ix+4),h
    ld (ix+5),l

    djnz _DSKIO_TX_LOOP 
    jr _DSKIO_TX_END

_DSKIO_TX_END_POP:
    pop hl
    pop bc
_DSKIO_TX_END:    
    ld b,c
    res 7,b ;Clear read/write flag
    push af
    pop hl
    ld ix,DSKIO_STACK_SPACE
    add ix,sp
    ld sp,ix
    push hl
    pop af
    ret

    ;--- Routine for transferring one sector
    ;    Input:  IX = Command address (with proper sector number and sector count set)
    ;            DE = Transfer address
    ;    Output: On success: Cy = 0
    ;            On error:   Cy = 1, A = DSKIO error code
    ;    Preserves IX
_DSKIO_TX_ONE:
    push ix
    pop hl
    ld a,(ix)   ;Command is 28h to read or 2Ah to write
    rra
    rra
    ld a,1  ;Retry "media changed"
    ld bc,512   ;Bytes to transfer

    push ix
    call USB_EXECUTE_CBI_WITH_RETRY
    pop ix

    or a
    ld a,12
    scf
    ret nz   ;Return "other error" on USB error

    ld a,(ix)
    cp 2Ah
    jr z,_DSKIO_TX_ONE_2
    ld a,b
    cp 2
    ld a,12
    scf
    ret nz  ;Return "other error" if no whole sector was read

_DSKIO_TX_ONE_2:
    ld a,d
    or a
    ret z   ;Success if ASC = 0

    call ASC_TO_ERR
    scf
    ret

_UFI_READ_SECTOR_CMD:
    db 28h, 0, 0, 0, 255, 255, 0, 0, 1, 0, 0, 0   ;bytes 4 and 5 = sector number, byte 8 = transfer length

;_UFI_WRITE_SECTOR_CMD:
;    db 2Ah, 0, 0, 0, 255, 255, 0, 0, 1, 0, 0, 0   ;bytes 4 and 5 = sector number, byte 8 = transfer length


; -----------------------------------------------------------------------------
; ASC_TO_ERR: Convert ASC to DSKIO error
; -----------------------------------------------------------------------------
; Input:  A = ASC
; Output: A = Error

ASC_TO_ERR:
    call _ASC_TO_ERR
    ld a,h
    ret

_ASC_TO_ERR:
    cp 27h      ;Write protected
    ld h,0
    ret z
    cp 3Ah      ;Not ready
    ld h,2
    ret z
    cp 10h      ;CRC error
    ld h,4
    ret z
    cp 21h      ;Invalid logical block
    ld h,6
    ret z
    cp 02h      ;Seek error
    ret z
    cp 03h
    ld h,10
    ret z
    ld h,12     ;Other error
    ret


; -----------------------------------------------------------------------------
; DSKCHG
; -----------------------------------------------------------------------------
; Input: 	A	Drivenumber
; 		B	0
; 		C	Media descriptor
; 		HL	pointer to DPB
; Output:	F	Cx set for error
;			Cx reset for ok
;		A	if error, errorcode
;		B	if no error, disk change status
;			01 disk unchanged
;			00 unknown
;			FF disk changed
; Changed:	AF,BC,DE,HL,IX,IY may be affected
; Remark:	DOS1 kernel expects the DPB updated when disk change status is
;               unknown or changed DOS2 kernel does not care if the DPB is
;               updated or not		
; -----------------------------------------------------------------------------

DSKCHG_IMPL:
    or a
    ld a,12
    scf
    ret nz

    push hl
    call USB_CHECK_DEV_CHANGE
    pop hl
    ld a,12
    ret c   ;No device is connected

    push hl
    ld hl,READ_0_SECTORS_CMD
    ld de,0  ;"Discard data" just in case, we won't actually retrieve any data
    ld bc,0
    xor a   ;Don't retry "media changed" + Cy=0 (read data)
    call USB_EXECUTE_CBI_WITH_RETRY

    pop hl
    or a
    ld a,12
    scf
    ret nz  ;Return "other error" on USB error

    ld a,d
    or a
    ld b,1
    ret z   ;If no error, media hasn't changed

    cp 28h  ;ASC for "media changed"
    jr z,_DSKCHG_BUILD_DPB

    call ASC_TO_ERR
    scf
    ret

_DSKCHG_BUILD_DPB:
    xor a
    call GETDPB_IMPL
    ld b,0FFh
    ret

READ_0_SECTORS_CMD:
    db 28h, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0


; -----------------------------------------------------------------------------
; GETDPB
; -----------------------------------------------------------------------------
; Input: 	A	Drivenumber
; 		B	first byte of FAT
; 		C	Media descriptor
; 		HL	pointer to DPB
; Output:	[HL+1]
;		..
;		[HL+18]	updated
; Changed:	AF,BC,DE,HL,IX,IY may be affected
; -----------------------------------------------------------------------------

GETDPBERR:
	pop  bc
	pop  af
	ld   a,12
	scf
	ret
GETDPB_IMPL:
	push af 
	push bc 
	push hl 
	ld   hl,(SECBUF)
	push hl
	ld   b,1
	ld   de,0 
	or   a 
	ld   c,0FFh 
	call DSKIO_IMPL
	pop  iy 
	pop  hl 
	jr   c,GETDPBERR
	inc  hl
	push hl
	ex   de,hl
	ld   hl,DEFDPB_1+1
	ld   bc,18
	ldir
	pop  hl
	ld   a,(iy+21)
	cp   0F9h
	jr   z,GETDPBEND 
	ld   (hl),a
	inc  hl
	ld   a,(iy+11)
	ld   (hl),a
	inc  hl
	ld   a,(iy+12)
	ld   (hl),a
	inc  hl
	ld   (hl),0Fh
	inc  hl
	ld   (hl),04h
	inc  hl
	ld   a,(iy+0Dh)
	dec  a
	ld   (hl),a
	inc  hl
	add  a,1
	ld   b,0
GETDPB0: 
	inc  b
	rra 
	jr   nc,GETDPB0
	ld   (hl),b
	inc  hl
	push bc
	ld   a,(iy+0Eh)
	ld   (hl),a
	inc  hl
	ld   d,(iy+0Fh)
	ld   (hl),d
	inc  hl
	ld   b,(iy+010h)
	ld   (hl),b
	inc  hl
GETDPB1: 
	add  a,(iy+016h)
	jr   nc,GETDPB2
	inc  d
GETDPB2: 
	djnz GETDPB1
	ld   c,a
	ld   b,d
	ld   e,(iy+011h)
	ld   d,(iy+012h)
	ld   a,d
	or   a
	ld   a,0FEh
	jr   nz,GETDPB3
	ld   a,e
GETDPB3: 
	ld   (hl),a
	inc  hl
	dec  de
	ld   a,4
GETDPB4: 
	srl  d
	rr   e
	dec  a
	jr   nz,GETDPB4
	inc  de
	ex   de,hl
	add  hl,bc
	ex   de,hl
	ld   (hl),e
	inc  hl
	ld   (hl),d
	inc  hl
	ld   a,(iy+013h)
	sub  e
	ld   e,a
	ld   a,(iy+014h)
	sbc  a,d
	ld   d,a
	pop  af
GETDPB5: 
	dec  a
	jr   z,GETDPB6
	srl  d
	rr   e
	jr   GETDPB5
GETDPB6:
	inc  de
	ld   (hl),e
	inc  hl
	ld   (hl),d
	inc  hl
	ld   a,(iy+016h)
	ld   (hl),a
	inc  hl
	ld   (hl),c
	inc  hl
	ld   (hl),b
GETDPBEND: 
	pop  bc
	pop  af 
	xor  a
	ret
