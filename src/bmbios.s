; ===================================================================
; bmbios.s -- BM_* backup-memory BIOS (ws005 p006), clean room.
;
; Implements BM_FORMAT ($18), BM_FREE ($19), BM_READ ($1A),
; BM_WRITE ($1B), BM_DELETE ($1C), BM_FILES ($1D) against the
; core's 8 KB backup RAM (bank $F7), following the public format
; (Hu7 manual): "HUBM" header, directory entries of
; length word + checksum + 12-byte FCB (user ID + 10-byte name)
; + data, chained from $0010.
;
; All semantics were measured black-box against the genuine card
; (test_p006.js, 67 cases, full-BRAM byte comparisons):
;   checksum = -(sum of the 12 FCB bytes + data bytes) mod 2^16
;   BM_FREE  = (header end word - unused ptr) - 18, clamped at 0;
;              carry set iff the raw gap is >= 18
;   BM_FORMAT compares exactly 11 password bytes, zeroes the
;              whole area, writes end=$A000, unused=$8010
;   BM_WRITE on a missing file always plants the 16-byte stub
;              (len=16, ck=0, FCB) and advances the unused ptr
;              before the data-fit test; growth of an existing
;              file that does not fit fails cleanly ($01, no
;              change); DX past the end zero-fills the gap
;   BM_READ  delivers data even on checksum error (A=$02)
;   missing "HUBM" -> A=$FF for every function but FORMAT;
;              carry then comes from the header's last byte
;              comparison (measured on zeroed / $FF-filled RAM)
;   carry: FORMAT ok=1 ng=0; READ=1; WRITE=0; DELETE=1;
;              FILES found=1, not found = (directory empty)
;   argument shadows are preserved except: FREE writes _CX,
;              READ writes _CX when the file is found, FILES
;              writes _AL when not found.
;   BM_WRITE with _CX=0 never returns on the genuine card in
;              this core (same hang class as p003/p004), so
;              COMPAT3 answers A=$22 at once (policy case).
;
; The code lives in bank 2, linked at $C000 and entered through
; the bank-0 MPR6 glue (bm_format etc. in bank0.s). Because the
; glue restores MPR6 with PLA, the result A and carry are handed
; back through bm_res / bm_carryf (ZP $3F / $3E at exit time).
; BRAM is reached through MPR4 (window $8000, bank $F7),
; unlocked on entry ($1807 bit 7) and locked on exit ($1803
; read) -- the core drops $F7 writes while locked.
;
; Deliberate divergence: after writes past a completely full
; BRAM the genuine card's directory walk reads beyond the 8 KB
; window (its own work RAM); COMPAT3 stops the walk at $A000.
; That regime is reachable only by writing to an already-full
; BRAM and is not differentially gated.
; ===================================================================

        .setcpu "huc6280"
        .include "hw.inc"

        .export bmb_format, bmb_free, bmb_read
        .export bmb_write, bmb_delete, bmb_files

; --- BM work cells (C-D4: nothing standing in ZP $80-$D7) -----
; (Was $30-$3F until item 3.5: that block sits inside
; the $2000-$203F page a caller buffer can alias onto
; the zero page, and every state write during a call
; then lands in the caller's source data -- the
; genuine's BM state lives in its $226A+ work area and
; its transfers are exact there.  The block then sat at
; $80-$8D, free in every BIOS module's map and clear of
; the test programs' areas ($8E+) -- but layer 10 round 2
; (Dracula X, C-D4) measured the genuine preserving ZP
; $80-$D7 across ALL calls, BM calls included, while
; BM_READ left this whole block standing.  The plain
; counters now live in WRAM (BM_LEN / BM_N / BM_CK /
; BM_CNT, hw.inc).  The three (zp),y pointers are
; borrows above the preservation range, saved by
; bmb_enter and restored by bmb_ret (save area BM_SAV):
; bm_ep has a dedicated borrow cell (BM_EP, $E0);
; bm_dp aliases zp_dataptr ($DC) and bm_tp aliases
; zp_dst ($DE) for the duration of a BM body -- both
; cells are dead inside BM calls, which never nest
; inside a stream, a SCSI data-in, or each other.)
bm_ep           = BM_EP         ; entry / walk pointer (2)
bm_dp           = zp_dataptr    ; caller pointer: FCB or data (2)
bm_tp           = zp_dst        ; transfer pointer (2)
bm_len          = BM_LEN        ; current entry length (2)
bm_n            = BM_N          ; 16-bit work count (2)
bm_ck           = BM_CK         ; checksum accumulator (2)
bm_cnt          = BM_CNT        ; FILES counter / scratch (2)
bm_mpr4         = $3E           ; (unused since BM_SMPR4)
bm_res          = $22AA         ; exit: result A (= BM_RES)
bm_carryf       = $22AB         ; exit: result carry
                                ; (= BM_CARRYF)
BM_TII          = $22A0         ; TII stub (8 bytes, work RAM):
                                ; $73, src(2), dst(2), len(2), $60
BM_SRES         = $22A8         ; BM_READ: result A stashed
                                ; across the data copy
BM_SMPR4        = $22A9         ; saved caller MPR4 (was ZP
                                ; $3E: an aliased READ/FILES
                                ; copy overwrites it with
                                ; file data before bmb_ret
                                ; restores it -- measured
                                ; crash, item 3.5)
bm_bad          = BM_LEN        ; BM_READ: checksum-bad flag
                                ; (reuses bm_len low: dead there
                                ; once the data length is derived)

BRAM            = $8000         ; BRAM window base (MPR4 = $F7)

        .segment "BMCODE"

; -------------------------------------------------------------------
; Common entry: save caller's MPR4 (in bm_mpr4 -- NOT on the
; stack; an early draft pushed it and the function's own RTS
; then popped it as half of the return address), map BRAM at
; $8000, unlock it.
; -------------------------------------------------------------------
bmb_enter:
        ; C-D4: save the borrowed pointer cells
        ; (zp_dataptr / zp_dst / BM_EP) before any BM body
        ; writes them; bmb_ret restores them.  (A is free
        ; here: the current body already clobbers it with
        ; the tma below before any caller value is read.)
        lda     zp_dataptr
        sta     BM_SAV
        lda     zp_dataptr+1
        sta     BM_SAV+1
        lda     zp_dst
        sta     BM_SAV+2
        lda     zp_dst+1
        sta     BM_SAV+3
        lda     BM_EP
        sta     BM_SAV+4
        lda     BM_EP+1
        sta     BM_SAV+5
        tma     #$10
        sta     BM_SMPR4
        lda     #$F7
        tam     #$10
        lda     #$80
        sta     CD_PORT+7       ; unlock backup RAM
        rts

; -------------------------------------------------------------------
; Common exit: A = result, carry = result carry on entry.
; Stashes both, locks BRAM, restores MPR4, returns to the glue,
; which rebuilds A and carry from bm_res / bm_carryf.
; -------------------------------------------------------------------
bmb_ret:
        sta     bm_res
        lda     BM_SMPR4
        tam     #$10            ; restore caller's MPR4
        lda     #$00
        rol     a
        sta     bm_carryf
        ; C-D4: restore the borrowed pointer cells saved
        ; by bmb_enter (result A / carry already stashed
        ; in bm_res / bm_carryf, so A is free here).
        lda     BM_SAV
        sta     zp_dataptr
        lda     BM_SAV+1
        sta     zp_dataptr+1
        lda     BM_SAV+2
        sta     zp_dst
        lda     BM_SAV+3
        sta     zp_dst+1
        lda     BM_SAV+4
        sta     BM_EP
        lda     BM_SAV+5
        sta     BM_EP+1
        lda     CD_PORT+3       ; lock backup RAM
        rts

; -------------------------------------------------------------------
; "HUBM" check: all four compares always run (so the flags of the
; last one survive in bm_cnt+1 bit 0 for the $FF exit's carry).
; Out: X = 0 if the header matches, 1 otherwise.
; -------------------------------------------------------------------
bmb_hubm:
        stz     bm_ck+1
        ldx     #$00
        lda     BRAM+0
        cmp     #'H'
        beq     hh1
        ldx     #$01
hh1:    lda     BRAM+1
        cmp     #'U'
        beq     hh2
        ldx     #$01
hh2:    lda     BRAM+2
        cmp     #'B'
        beq     hh3
        ldx     #$01
hh3:    lda     BRAM+3
        cmp     #'M'
        beq     hh4
        ldx     #$01
hh4:    rol     bm_ck+1         ; bit0 = carry of the 'M' compare
        rts

; No-"HUBM" exit: A = $FF, carry from the 'M' byte comparison.
bmb_nohubm:
        lsr     bm_ck+1         ; carry = saved bit0
        lda     #$FF
        jmp     bmb_ret

; -------------------------------------------------------------------
; Directory walk primitives. bm_ep walks entries from $8010 while
; bm_ep < header unused ptr, bm_ep < $A000, length word nonzero;
; bm_len holds the current entry's length.
; -------------------------------------------------------------------
bmb_walk_init:
        lda     #$10
        sta     bm_ep
        lda     #$80
        sta     bm_ep+1
bmb_walk_test:
        lda     bm_ep+1
        cmp     #$A0
        bcs     bw_none
        lda     bm_ep
        cmp     BRAM+6
        lda     bm_ep+1
        sbc     BRAM+7
        bcs     bw_none
        ldy     #$00
        lda     (bm_ep),y
        sta     bm_len
        iny
        lda     (bm_ep),y
        sta     bm_len+1
        ora     bm_len
        beq     bw_none
        sec
        rts
bw_none:
        clc
        rts

bmb_walk_next:
        lda     bm_ep
        clc
        adc     bm_len
        sta     bm_ep
        lda     bm_ep+1
        adc     bm_len+1
        sta     bm_ep+1
        jmp     bmb_walk_test

; -------------------------------------------------------------------
; FCB compare: the 12 bytes at bm_ep+4 against (bm_dp).
; Out: carry set on match. Clobbers bm_tp, Y.
; -------------------------------------------------------------------
bmb_fcb_cmp:
        lda     bm_ep
        clc
        adc     #$04
        sta     bm_tp
        lda     bm_ep+1
        adc     #$00
        sta     bm_tp+1
        ldy     #$0B
fc1:    lda     (bm_tp),y
        cmp     (bm_dp),y
        bne     fc_no
        dey
        bpl     fc1
        sec
        rts
fc_no:  clc
        rts

; -------------------------------------------------------------------
; Search the directory for the FCB at (bm_dp).
; Out: carry set + bm_ep/bm_len valid when found.
; -------------------------------------------------------------------
bmb_search:
        jsr     bmb_walk_init
        bcc     bs_no
bs1:    jsr     bmb_fcb_cmp
        bcs     bs_yes
        jsr     bmb_walk_next
        bcs     bs1
bs_no:  clc
        rts
bs_yes: sec
        rts

; -------------------------------------------------------------------
; Checksum: bm_ck = byte sum of the current entry's bytes
; [4, bm_len) (FCB + data). Clobbers bm_tp, bm_n, Y.
; -------------------------------------------------------------------
bmb_cksum:
        stz     bm_ck
        stz     bm_ck+1
        lda     bm_ep
        clc
        adc     #$04
        sta     bm_tp
        lda     bm_ep+1
        adc     #$00
        sta     bm_tp+1
        lda     bm_len
        sec
        sbc     #$04
        sta     bm_n
        lda     bm_len+1
        sbc     #$00
        sta     bm_n+1
ck1:    lda     bm_n
        ora     bm_n+1
        beq     ck9
        ldy     #$00
        lda     (bm_tp),y
        clc
        adc     bm_ck
        sta     bm_ck
        bcc     ck2
        inc     bm_ck+1
ck2:    inc     bm_tp
        bne     ck3
        inc     bm_tp+1
ck3:    lda     bm_n
        bne     ck4
        dec     bm_n+1
ck4:    dec     bm_n
        jmp     ck1
ck9:    rts

; Maintain the directory terminator: the genuine card leaves a
; $0000 length word at the unused pointer after every operation
; that moves it (measured: BM_WRITE new/grow and BM_DELETE leave
; 00 00 at the new directory end even over stale data).
bmb_term:
        lda     BRAM+6
        sta     bm_tp
        lda     BRAM+7
        sta     bm_tp+1
        cmp     #$A0
        bcs     bt_r            ; unused >= $A000: out of window
        ldy     #$00
        lda     #$00
        sta     (bm_tp),y
        lda     bm_tp
        cmp     #$FF
        beq     bt_r            ; second byte would leave the window
        iny
        lda     #$00
        sta     (bm_tp),y
bt_r:   rts

; Store the negated checksum at bm_ep+2.
bmb_ck_store:
        jsr     bmb_cksum
        lda     #$00
        sec
        sbc     bm_ck
        ldy     #$02
        sta     (bm_ep),y
        lda     #$00
        sbc     bm_ck+1
        iny
        sta     (bm_ep),y
        rts

; -------------------------------------------------------------------
; Byte movers. Count in bm_n (16 bit), both pointers advance.
;   bmb_copy_out: (bm_tp) -> (bm_dp)     BRAM -> caller
;   bmb_copy_in:  (bm_dp) -> (bm_tp)     caller -> BRAM
;   bmb_zero:     fill (bm_tp) with $00
; -------------------------------------------------------------------
; The movers run a TII whose operands are built into a
; stub in work RAM (BM_TII).  The genuine transfers data
; exactly even when the caller buffer aliases the zero
; page (measured, item 3.5); a ZP-pointer loop cannot:
; its pointer/count cells sit at $2030-$203D, inside
; the aliased page, so the transfer reads and writes
; its own state as data.  The stub's operands live in
; the instruction stream and are set before the copy
; starts, so nothing the copy does can disturb them.
bmb_copy_out:                   ; (bm_tp) -> (bm_dp)
        lda     bm_n            ; a zero length must NOT
        ora     bm_n+1          ; reach the TII: on the
        beq     bc_ret          ; HuC6280 a length of 0
                                ; transfers 65536 bytes
                                ; (found item 3.5: a
                                ; beyond-EOF BM_READ, whose
                                ; CX-out is 0, blasted the
                                ; whole address space)
        lda     #$73            ; TII opcode
        sta     BM_TII
        lda     bm_tp
        sta     BM_TII+1
        lda     bm_tp+1
        sta     BM_TII+2
        lda     bm_dp
        sta     BM_TII+3
        lda     bm_dp+1
        sta     BM_TII+4
        lda     bm_n
        sta     BM_TII+5
        lda     bm_n+1
        sta     BM_TII+6
        lda     #$60            ; RTS
        sta     BM_TII+7
        jmp     BM_TII

bmb_copy_in:                    ; (bm_dp) -> (bm_tp)
        lda     bm_n            ; zero length: no TII
        ora     bm_n+1          ; (see bmb_copy_out)
        beq     bc_ret
        lda     #$73            ; TII opcode
        sta     BM_TII
        lda     bm_dp
        sta     BM_TII+1
        lda     bm_dp+1
        sta     BM_TII+2
        lda     bm_tp
        sta     BM_TII+3
        lda     bm_tp+1
        sta     BM_TII+4
        lda     bm_n
        sta     BM_TII+5
        lda     bm_n+1
        sta     BM_TII+6
        lda     #$60            ; RTS
        sta     BM_TII+7
        jmp     BM_TII
bc_ret: rts

bmb_zero:
        lda     bm_n
        ora     bm_n+1
        beq     cz9
        ldy     #$00
        lda     #$00
        sta     (bm_tp),y
        inc     bm_tp
        bne     cz1
        inc     bm_tp+1
cz1:    lda     bm_n
        bne     cz2
        dec     bm_n+1
cz2:    dec     bm_n
        jmp     bmb_zero
cz9:    rts

; ===================================================================
; BM_FORMAT ($18): _AX = password address. The password is the
; 11-byte string "!BM FORMAT!"; anything else -> A=$01, no change.
; On success the whole area is zeroed and the header rewritten
; (end $A000, unused $8010). No "HUBM" check. Shadows preserved.
; ===================================================================
bmb_format:
        jsr     bmb_enter
        lda     ARG_AL
        sta     bm_dp
        lda     ARG_AH
        sta     bm_dp+1
        ldy     #$0A
pf1:    lda     (bm_dp),y
        cmp     bm_pw,y
        bne     pf_ng
        dey
        bpl     pf1
        ; clear $8010-$9FFF
        lda     #$10
        sta     bm_tp
        lda     #$80
        sta     bm_tp+1
        lda     #$F0
        sta     bm_n
        lda     #$1F
        sta     bm_n+1
        jsr     bmb_zero
        ; header: "HUBM", end=$A000, unused=$8010, rest zero
        ldy     #$0F
pf2:    lda     bm_hdr,y
        sta     BRAM,y
        dey
        bpl     pf2
        lda     #$00
        sec
        jmp     bmb_ret
pf_ng:  lda     #$01
        clc
        jmp     bmb_ret

bm_pw:  .byte   "!BM FORMAT!"
bm_hdr: .byte   "HUBM", $00, $A0, $10, $80
        .byte   $00, $00, $00, $00, $00, $00, $00, $00

; ===================================================================
; BM_FREE ($19): _CX = (end - unused) - 18 clamped at 0;
; carry set iff the raw gap is >= 18. A=$00. Only _CX is written.
; ===================================================================
bmb_free:
        jsr     bmb_enter
        jsr     bmb_hubm
        txa
        beq     hub_ok_1
        jmp     bmb_nohubm
hub_ok_1:
        ; gap = end word - unused ptr (borrow -> zero result)
        lda     BRAM+4
        sec
        sbc     BRAM+6
        sta     bm_n
        lda     BRAM+5
        sbc     BRAM+7
        sta     bm_n+1
        bcc     fr_zero
        ; gap < 18 -> CX = 0, carry clear
        lda     bm_n+1
        bne     fr_big
        lda     bm_n
        cmp     #$12
        bcc     fr_zero
fr_big: lda     bm_n
        sec
        sbc     #$12
        sta     ARG_CL
        lda     bm_n+1
        sbc     #$00
        sta     ARG_CH
        lda     #$00
        sec
        jmp     bmb_ret
fr_zero:
        stz     ARG_CL
        stz     ARG_CH
        lda     #$00
        clc
        jmp     bmb_ret

; ===================================================================
; BM_READ ($1A): _AX = FCB, _BX = destination, _CX = count,
; _DX = offset in file. Found: data copied from the offset,
; _CX = bytes actually read, A = $00, or $02 when the stored
; checksum does not match (data is still delivered in full).
; Not found: A = $01, _CX untouched. Carry set on every return
; past the header check. Shadows otherwise preserved.
; ===================================================================
bmb_read:
        jsr     bmb_enter
        jsr     bmb_hubm
        txa
        beq     hub_ok_2
        jmp     bmb_nohubm
hub_ok_2:
        lda     ARG_AL
        sta     bm_dp
        lda     ARG_AH
        sta     bm_dp+1
        jsr     bmb_search
        bcs     rd_found
        lda     #$01
        sec
        jmp     bmb_ret
rd_found:
        ; data length = bm_len - 16 -> bm_cnt
        lda     bm_len
        sec
        sbc     #$10
        sta     bm_cnt
        lda     bm_len+1
        sbc     #$00
        sta     bm_cnt+1
        ; verify checksum: sum + stored == 0 ? -> bm_bad (0/1)
        jsr     bmb_cksum
        ldy     #$02
        lda     (bm_ep),y
        clc
        adc     bm_ck
        sta     bm_tp
        iny
        lda     (bm_ep),y
        adc     bm_ck+1
        ora     bm_tp
        beq     rd_ckok
        lda     #$01
        sta     bm_bad
        jmp     rd_amt
rd_ckok:
        stz     bm_bad
rd_amt:
        ; actual = 0 when _DX >= datalen
        lda     ARG_DL
        cmp     bm_cnt
        lda     ARG_DH
        sbc     bm_cnt+1
        bcs     rd_zero
        ; remaining = datalen - _DX
        lda     bm_cnt
        sec
        sbc     ARG_DL
        sta     bm_n
        lda     bm_cnt+1
        sbc     ARG_DH
        sta     bm_n+1
        ; actual = min(_CX, remaining)
        lda     bm_n+1
        cmp     ARG_CH
        bne     rd_cmp1
        lda     bm_n
        cmp     ARG_CL
rd_cmp1:
        bcc     rd_have
        lda     ARG_CL
        sta     bm_n
        lda     ARG_CH
        sta     bm_n+1
rd_have:
        jmp     rd_copy
rd_zero:
        stz     bm_n
        stz     bm_n+1
rd_copy:
        lda     bm_n
        sta     ARG_CL
        lda     bm_n+1
        sta     ARG_CH
        ; source = bm_ep + 16 + _DX ; dest = _BX
        lda     bm_ep
        clc
        adc     #$10
        sta     bm_tp
        lda     bm_ep+1
        adc     #$00
        sta     bm_tp+1
        lda     bm_tp
        clc
        adc     ARG_DL
        sta     bm_tp
        lda     bm_tp+1
        adc     ARG_DH
        sta     bm_tp+1
        lda     ARG_BL
        sta     bm_dp
        lda     ARG_BH
        sta     bm_dp+1
        ; Decide the result BEFORE the copy: a destination
        ; that aliases the zero page overwrites bm_bad
        ; (ZP $36) with file data during the transfer.
        lda     bm_bad
        beq     rd_s00
        lda     #$02
        bra     rd_sres
rd_s00: lda     #$00
rd_sres:
        sta     BM_SRES
        jsr     bmb_copy_out
        ; Exit carry on the READ transfer paths is bit 12
        ; of the destination _BX (measured on the genuine
        ; at 11 destination addresses, item 3.5).
        lda     ARG_BH
        and     #$10
        beq     rd_clc
        lda     BM_SRES
        sec
        jmp     bmb_ret
rd_clc: lda     BM_SRES
        clc
        jmp     bmb_ret

; ===================================================================
; BM_WRITE ($1B): _AX = FCB, _BX = source, _CX = count,
; _DX = offset in file. Existing file: overwrite / append / grow
; in place (tail shifts up); growth that does not fit fails with
; A=$01 and no change. New file: the 16-byte stub (len=16, ck=0,
; FCB) is planted and the unused pointer advanced first; when
; the data then does not fit, A=$01 with the stub left behind.
; DX past the current end zero-fills the gap. _CX=0 is the
; policy case (A=$22, nothing touched). Carry clear on every
; return past the header check. Shadows preserved.
; ===================================================================
bmb_write:
        jsr     bmb_enter
        jsr     bmb_hubm
        txa
        beq     hub_ok_3
        jmp     bmb_nohubm
hub_ok_3:
        lda     ARG_CL
        ora     ARG_CH
        bne     wr_go
        lda     #$22            ; policy: genuine never returns
        clc
        jmp     bmb_ret
wr_go:  lda     ARG_AL
        sta     bm_dp
        lda     ARG_AH
        sta     bm_dp+1
        jsr     bmb_search
        bcc     wr_new
        jmp     wr_exist

; --- new file -----------------------------------------------------
wr_new:
        ; bm_ep = old unused pointer (the stub position)
        lda     BRAM+6
        sta     bm_ep
        lda     BRAM+7
        sta     bm_ep+1
        ; plant the stub header bytes, clipped at $A000:
        ; +0 = $10, +1..+3 = $00 (writes at/past the end are
        ; dropped, matching the observable genuine state)
        lda     bm_ep+1
        cmp     #$A0
        bcs     wn_s1
        ldy     #$00
        lda     #$10
        sta     (bm_ep),y
wn_s1:  lda     bm_ep
        clc
        adc     #$01
        sta     bm_tp
        lda     bm_ep+1
        adc     #$00
        sta     bm_tp+1
        cmp     #$A0
        bcs     wn_s2
        ldy     #$00
        lda     #$00
        sta     (bm_tp),y
wn_s2:  lda     bm_ep
        clc
        adc     #$02
        sta     bm_tp
        lda     bm_ep+1
        adc     #$00
        sta     bm_tp+1
        cmp     #$A0
        bcs     wn_s3
        ldy     #$00
        lda     #$00
        sta     (bm_tp),y
wn_s3:  lda     bm_ep
        clc
        adc     #$03
        sta     bm_tp
        lda     bm_ep+1
        adc     #$00
        sta     bm_tp+1
        cmp     #$A0
        bcs     wn_s4
        ldy     #$00
        lda     #$00
        sta     (bm_tp),y
wn_s4:  ; FCB: copy min(12, $A000 - (bm_ep+4)) bytes from (bm_dp)
        lda     bm_ep
        clc
        adc     #$04
        sta     bm_tp
        lda     bm_ep+1
        adc     #$00
        sta     bm_tp+1
        cmp     #$A0
        bcs     wn_s5
        ; room = $A000 - bm_tp (at most 12 matters)
        lda     #$00
        sec
        sbc     bm_tp
        sta     bm_n
        lda     #$A0
        sbc     bm_tp+1
        sta     bm_n+1
        bne     wn_c12
        lda     bm_n
        cmp     #$0C
        bcc     wn_cpy
wn_c12: lda     #$0C
        sta     bm_n
        stz     bm_n+1
wn_cpy: jsr     bmb_copy_in
wn_s5:  ; unused += 16 (header word)
        lda     BRAM+6
        clc
        adc     #$10
        sta     BRAM+6
        lda     BRAM+7
        adc     #$00
        sta     BRAM+7
        ; new data length = _DX + _CX (overflow -> cannot fit)
        lda     ARG_DL
        clc
        adc     ARG_CL
        sta     bm_cnt
        lda     ARG_DH
        adc     ARG_CH
        sta     bm_cnt+1
        bcs     wn_full_j
        bra     wn_fit0
wn_full_j:
        jmp     wr_full
wn_fit0:
        ; fits iff newD <= end - new unused (borrow -> no fit)
        lda     BRAM+4
        sec
        sbc     BRAM+6
        sta     bm_n
        lda     BRAM+5
        sbc     BRAM+7
        sta     bm_n+1
        bcc     wr_full
        lda     bm_n+1
        cmp     bm_cnt+1
        bne     wn_fit1
        lda     bm_n
        cmp     bm_cnt
wn_fit1:
        bcc     wr_full
        ; zero the gap [0, _DX), then copy data at +_DX
        lda     bm_ep
        clc
        adc     #$10
        sta     bm_tp
        lda     bm_ep+1
        adc     #$00
        sta     bm_tp+1
        lda     ARG_DL
        sta     bm_n
        lda     ARG_DH
        sta     bm_n+1
        jsr     bmb_zero        ; advances bm_tp by _DX
        lda     ARG_BL
        sta     bm_dp
        lda     ARG_BH
        sta     bm_dp+1
        lda     ARG_CL
        sta     bm_n
        lda     ARG_CH
        sta     bm_n+1
        jsr     bmb_copy_in
        ; length word = 16 + newD
        lda     bm_cnt
        clc
        adc     #$10
        sta     bm_len
        ldy     #$00
        sta     (bm_ep),y
        lda     bm_cnt+1
        adc     #$00
        sta     bm_len+1
        iny
        sta     (bm_ep),y
        ; unused += newD (the header advance above covered
        ; only the 16-byte stub)
        lda     BRAM+6
        clc
        adc     bm_cnt
        sta     BRAM+6
        lda     BRAM+7
        adc     bm_cnt+1
        sta     BRAM+7
        jsr     bmb_term
        jsr     bmb_ck_store
        lda     #$00
        clc
        jmp     bmb_ret
wr_full:
        lda     #$01
        clc
        jmp     bmb_ret

; --- existing file --------------------------------------------------
wr_exist:
        ; data length D = bm_len - 16 -> bm_cnt
        lda     bm_len
        sec
        sbc     #$10
        sta     bm_cnt
        lda     bm_len+1
        sbc     #$00
        sta     bm_cnt+1
        ; endpos = _DX + _CX -> bm_tp (overflow -> cannot fit)
        lda     ARG_DL
        clc
        adc     ARG_CL
        sta     bm_tp
        lda     ARG_DH
        adc     ARG_CH
        sta     bm_tp+1
        bcs     we_xfull_j
        ; grow iff endpos > D
        lda     bm_tp+1
        cmp     bm_cnt+1
        bne     we_cmp1
        lda     bm_tp
        cmp     bm_cnt
we_cmp1:
        bcc     we_write_j
        beq     we_write_j
        bra     we_grow
we_write_j:
        jmp     we_write
we_grow:
        lda     bm_tp
        sec
        sbc     bm_cnt
        sta     bm_n
        lda     bm_tp+1
        sbc     bm_cnt+1
        sta     bm_n+1
        ; fits iff delta <= end - unused (borrow -> no fit)
        lda     BRAM+4
        sec
        sbc     BRAM+6
        sta     bm_tp
        lda     BRAM+5
        sbc     BRAM+7
        sta     bm_tp+1
        bcc     we_xfull_j
        lda     bm_tp+1
        cmp     bm_n+1
        bne     we_fit1
        lda     bm_tp
        cmp     bm_n
we_fit1:
        bcc     we_xfull_j
        bra     we_shift
we_xfull_j:
        jmp     wr_xfull
we_shift:
        ; shift the tail [bm_ep+bm_len, unused) up by delta:
        ; backward copy; count -> bm_ck (scratch), src end in
        ; bm_tp, dst end in bm_dp
        lda     BRAM+6
        sec
        sbc     #$01
        sta     bm_tp
        lda     BRAM+7
        sbc     #$00
        sta     bm_tp+1         ; src = unused - 1
        lda     bm_tp
        clc
        adc     bm_n
        sta     bm_dp
        lda     bm_tp+1
        adc     bm_n+1
        sta     bm_dp+1         ; dst = src + delta
        lda     bm_ep
        clc
        adc     bm_len
        sta     bm_ck
        lda     bm_ep+1
        adc     bm_len+1
        sta     bm_ck+1
        lda     BRAM+6
        sec
        sbc     bm_ck
        sta     bm_ck
        lda     BRAM+7
        sbc     bm_ck+1
        sta     bm_ck+1         ; count = unused - tail start
we_sh1: lda     bm_ck
        ora     bm_ck+1
        beq     we_sh9
        ldy     #$00
        lda     (bm_tp),y
        sta     (bm_dp),y
        lda     bm_tp
        bne     we_sh2
        dec     bm_tp+1
we_sh2: dec     bm_tp
        lda     bm_dp
        bne     we_sh3
        dec     bm_dp+1
we_sh3: dec     bm_dp
        lda     bm_ck
        bne     we_sh4
        dec     bm_ck+1
we_sh4: dec     bm_ck
        jmp     we_sh1
we_sh9: ; unused += delta ; entry length += delta
        lda     BRAM+6
        clc
        adc     bm_n
        sta     BRAM+6
        lda     BRAM+7
        adc     bm_n+1
        sta     BRAM+7
        jsr     bmb_term
        lda     bm_len
        clc
        adc     bm_n
        sta     bm_len
        ldy     #$00
        sta     (bm_ep),y
        lda     bm_len+1
        adc     bm_n+1
        sta     bm_len+1
        iny
        sta     (bm_ep),y
we_write:
        ; gap zero when _DX > D: at bm_ep+16+D, count _DX-D
        lda     ARG_DL
        cmp     bm_cnt
        bne     we_gz1
        lda     ARG_DH
        cmp     bm_cnt+1
        beq     we_data
we_gz1: lda     ARG_DL
        cmp     bm_cnt
        lda     ARG_DH
        sbc     bm_cnt+1
        bcc     we_data
        lda     bm_ep
        clc
        adc     #$10
        sta     bm_tp
        lda     bm_ep+1
        adc     #$00
        sta     bm_tp+1
        lda     bm_tp
        clc
        adc     bm_cnt
        sta     bm_tp
        lda     bm_tp+1
        adc     bm_cnt+1
        sta     bm_tp+1
        lda     ARG_DL
        sec
        sbc     bm_cnt
        sta     bm_n
        lda     ARG_DH
        sbc     bm_cnt+1
        sta     bm_n+1
        jsr     bmb_zero
we_data:
        ; copy _CX bytes from _BX to bm_ep+16+_DX
        lda     bm_ep
        clc
        adc     #$10
        sta     bm_tp
        lda     bm_ep+1
        adc     #$00
        sta     bm_tp+1
        lda     bm_tp
        clc
        adc     ARG_DL
        sta     bm_tp
        lda     bm_tp+1
        adc     ARG_DH
        sta     bm_tp+1
        lda     ARG_BL
        sta     bm_dp
        lda     ARG_BH
        sta     bm_dp+1
        lda     ARG_CL
        sta     bm_n
        lda     ARG_CH
        sta     bm_n+1
        jsr     bmb_copy_in
        jsr     bmb_ck_store
        lda     #$00
        clc
        jmp     bmb_ret
wr_xfull:
        lda     #$01
        clc
        jmp     bmb_ret

; ===================================================================
; BM_DELETE ($1C): _AX = FCB. Found: the tail shifts down over
; the entry and the unused pointer retreats; the freed bytes are
; not wiped. Not found: A=$01. Carry set on every return past
; the header check. Shadows preserved.
; ===================================================================
bmb_delete:
        jsr     bmb_enter
        jsr     bmb_hubm
        txa
        beq     hub_ok_4
        jmp     bmb_nohubm
hub_ok_4:
        lda     ARG_AL
        sta     bm_dp
        lda     ARG_AH
        sta     bm_dp+1
        jsr     bmb_search
        bcs     dl_found
        lda     #$01
        sec
        jmp     bmb_ret
dl_found:
        ; shift down: dst = bm_ep, src = bm_ep + bm_len,
        ; count = unused - src (forward copy is safe: dst < src)
        lda     bm_ep
        clc
        adc     bm_len
        sta     bm_tp
        lda     bm_ep+1
        adc     bm_len+1
        sta     bm_tp+1
        lda     BRAM+6
        sec
        sbc     bm_tp
        sta     bm_n
        lda     BRAM+7
        sbc     bm_tp+1
        sta     bm_n+1
        lda     bm_ep
        sta     bm_dp
        lda     bm_ep+1
        sta     bm_dp+1
        jsr     bmb_copy_out
        ; unused -= bm_len
        lda     BRAM+6
        sec
        sbc     bm_len
        sta     BRAM+6
        lda     BRAM+7
        sbc     bm_len+1
        sta     BRAM+7
        jsr     bmb_term
        lda     #$00
        sec
        jmp     bmb_ret

; ===================================================================
; BM_FILES ($1D): _BX = FCB destination, _AL = file number
; (top = 1). Found: the 12-byte FCB is copied out, A=$00, carry
; set. Not found: A=$01, _AL = largest file number (low byte),
; destination untouched, carry set iff the directory is empty.
; ===================================================================
bmb_files:
        jsr     bmb_enter
        jsr     bmb_hubm
        txa
        beq     hub_ok_5
        jmp     bmb_nohubm
hub_ok_5:
        stz     bm_cnt
        stz     bm_cnt+1
        jsr     bmb_walk_init
        bcc     fl_none
fl_loop:
        inc     bm_cnt
        bne     fl_c1
        inc     bm_cnt+1
fl_c1:  lda     bm_cnt+1
        bne     fl_next
        lda     bm_cnt
        cmp     ARG_AL
        bne     fl_next
        ; found: copy the FCB to _BX
        lda     bm_ep
        clc
        adc     #$04
        sta     bm_tp
        lda     bm_ep+1
        adc     #$00
        sta     bm_tp+1
        lda     ARG_BL
        sta     bm_dp
        lda     ARG_BH
        sta     bm_dp+1
        lda     #$0C
        sta     bm_n
        stz     bm_n+1
        jsr     bmb_copy_out
        lda     #$00
        sec
        jmp     bmb_ret
fl_next:
        jsr     bmb_walk_next
        bcs     fl_loop
fl_none:
        lda     bm_cnt
        sta     ARG_AL
        lda     bm_cnt
        ora     bm_cnt+1
        beq     fl_empty
        lda     #$01
        clc
        jmp     bmb_ret
fl_empty:
        lda     #$01
        sec
        jmp     bmb_ret
