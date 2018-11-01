; MSX-DOS 1 kernel with USB FDD driver for Rookie Drive
; By Konamiman, 2018
;
; Kernel and base driver code taken from the dsk2rom project by joyrex2001:
; https://github.com/joyrex2001/dsk2rom
;
; Assemble with:
; sjasm rookiefdd.asm rookiefdd.rom

CALL_XFER_SIZE: equ 20  ;Size of CALL_XFER routine in callbnk.asm

CALL_IX:    equ 7FD0h
CALL_BANK: equ CALL_IX+2

    include "flags.asm"
    include "usb_errors.asm"

    ;--- Bank 0: MSX-DOS kernel, MSX-DOS driver functions entry points, CALL commands

    org 4000h

    include "kernel.asm"
    include "driver.asm"
    include "choice_strings.asm"
    include "oemstat.asm"
DEFDPB:
    include "defdpb.asm"    

HOSTILE_TAKEOVER:	db   0	  ; 0 = no, 1 = make this an exclusive diskrom

    ds CALL_IX-$,0FFh
    include "callbnk.asm"

    ds 7FFFh-$,0FFh
    db 0

    ;--- Bank 1: initialization routine, MSX-DOS driver functions implementation and all the USB related code

    ; Note: USB host controller hardware dependant code needs to be placed before usb.asm 
    ; because of the HW_IMPL_* constants.

    org 4000h

    include "ch376.asm" ;USB host hardware dependant code
    include "inihrd_inienv.asm"
    include "dskio_dskchg.asm"
    include "choice_dskfmt.asm"    
    include "work_area.asm"
    include "usb.asm"
    include "ufi.asm"
DEFDPB_1:
    include "defdpb.asm"

    ds CALL_IX-$,0FFh
    include "callbnk.asm"

    ds 7FFFh-$,0FFh
    db 1

