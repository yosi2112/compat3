; COMPAT3 CD BIOS functions (ws005 p003): CD_BOOT ($00),
; CD_RESET ($01), CD_BASE ($02), CD_READ ($03), CD_SEEK ($04),
; CD_EXEC ($05), CD_STAT ($09), CD_SUBQ ($0A), CD_DINFO ($0B),
; CD_CONTNTS ($0C), CD_FADE ($0F).
;
; Written from the public specifications only: the Hu7 CD System
; BIOS Manual (function IN/OUT tables, SUB ERROR CODE list p.40,
; BIOS work equ list p.41-42) and the zeograd System Card BIOS
; document, on top of the CSCP core's SCSI CD model (the core
; source is a spec source per the ws005 plan). Where the two
; documents disagree (e.g. CD_BASE's set-mode bits), the
; differential suite against the reference card arbitrates and
; the outcome is recorded in pce-web/PROGRESS.md.
;
; Calling convention (public): arguments in the zero-page
; shadows $20F8-$20FF (al, ah, bl, bh, cl, ch, dl, dh); CD_STAT
; and CD_FADE take the real A register instead. Results in the
; real A register (0 = OK, else a SUB ERROR CODE) plus the
; documented buffer / work-variable outputs. The BIOS work
; variables live at their public addresses ($226A-$227E) and
; recbase is stored big-endian (H, M, L) at $2274-$2279.
;
; Drive primitives used (NEC vendor commands, via scsi.s):
;   $DE Get Dir Info (subs 0/1/2) -- TOC data
;   $DD Read Sub Channel Q        -- CD_SUBQ's 10-byte reply
;   $D8 Set Audio Playback Start Position, mode 0 (pause at
;       position)                 -- CD_SEEK's head move; in
;       this core it latches cdda_start_frame, which $DD then
;       reports as the current position
;   READ(6) via cd_stream         -- data transfer
;   TEST UNIT READY via scsi_cmd6 -- readiness checks
        .segment "CODE"

; -------------------------------------------------------------------
; scsi_cmd6: like scsi_cmd (scsi.s) but sends a 6-byte CDB.
; Needed for the standard 6-byte commands (TEST UNIT READY).
; Data-in phase supported via zp_dataptr / zp_datalen as usual.
; -------------------------------------------------------------------
scsi_cmd6:
        stz     zp_err
        lda     #$01
        sta     $1801
        stz     $1800
        lda     #$80
        sta     zp_waitmask
        sta     zp_waitexpect
        jsr     wait1800
        bcc     s6_cdb
        lda     #$01
        sta     zp_err
        jmp     scsi_fail
s6_cdb:
        ldx     #$00
s6_cdb_loop:
        lda     #$78
        sta     zp_waitmask
        lda     #$50
        sta     zp_waitexpect
        jsr     wait1800
        bcc     s6_cdb_send
        lda     #$02
        sta     zp_err
        jmp     scsi_fail
s6_cdb_send:
        lda     zp_cdb,x
        sta     $1801
        jsr     ack_pulse
        bcc     s6_cdb_next
        lda     #$03
        sta     zp_err
        jmp     scsi_fail
s6_cdb_next:
        inx
        cpx     #$06
        bne     s6_cdb_loop
        lda     zp_datalen
        beq     s6_status
        ldy     #$00
s6_data_loop:
        lda     #$78
        sta     zp_waitmask
        lda     #$48
        sta     zp_waitexpect
        jsr     wait1800
        bcc     s6_data_get
        lda     #$04
        sta     zp_err
        jmp     scsi_fail
s6_data_get:
        lda     $1801
        sta     (zp_dataptr),y
        jsr     ack_pulse
        bcc     s6_data_next
        lda     #$03
        sta     zp_err
        jmp     scsi_fail
s6_data_next:
        iny
        cpy     zp_datalen
        bne     s6_data_loop
s6_status:
        lda     #$78
        sta     zp_waitmask
        lda     #$58
        sta     zp_waitexpect
        jsr     wait1800
        bcc     s6_status_get
        lda     #$05
        sta     zp_err
        jmp     scsi_fail
s6_status_get:
        lda     $1801
        sta     zp_scsi_stat
        jsr     ack_pulse
        bcc     s6_msg
        lda     #$03
        sta     zp_err
        jmp     scsi_fail
s6_msg:
        lda     #$78
        sta     zp_waitmask
        sta     zp_waitexpect
        jsr     wait1800
        bcc     s6_msg_get
        lda     #$06
        sta     zp_err
        jmp     scsi_fail
s6_msg_get:
        lda     $1801
        sta     zp_scsi_msg
        jsr     ack_pulse
        bcc     s6_done
        lda     #$03
        sta     zp_err
        jmp     scsi_fail
s6_done:
        clc
        rts

; tur_cmd / sense_cmd moved to segment FIXUP2 (bank 3) in
; the C-D4 fix-up: their only caller is cd_stat_b2 (already
; bank 3), their tail jmp scsi_cmd6 reaches bank 0 through
; the resident $E000 window, and bank 0 needed the room for
; the C-D4 fix-up's stub wraps. See below, before cd_stat_b2.

; note_status: record the last SCSI status byte in the public
; work variable (called after every drive command).
note_status:
        lda     zp_scsi_stat
        sta     WV_SCSISTS
        rts

; fail_with: A = SUB ERROR CODE. Stores it in WV_SUBERRC and
; returns with it in A (the common BIOS error exit).
fail_with:
        sta     WV_SUBERRC
        rts

; ok_ret: the common success exit: WV_SUBERRC = 0, A = 0.
ok_ret:
        lda     #$00
        bra     fail_with       ; shares the store (bank-0
                                ; space reclaim, 2026-11-23)

; ok_ret_sec: same, but returns with carry SET. Measured on
; the genuine BIOS (2026-11-20 differential): CD_READ,
; CD_SEEK and CD_CONTNTS return from successful calls with
; carry set, while CD_STAT's ready check returns carry clear
; (it uses ok_ret). The genuine carry is evidently leftover
; state from its internal paths; matched per function.
ok_ret_sec:
        lda     #$00
        sec
        bra     fail_with       ; shares the store (bank-0
                                ; space reclaim, 2026-11-23)

; -------------------------------------------------------------------
; shadow_offset: zp_off (3 bytes, little-endian) = the record
; offset formed by cl (high), ch (mid), dl (low).
; abs_from_base0: zp_alba = recbase0 + zp_off.
; -------------------------------------------------------------------
shadow_offset:
        lda     ARG_DL
        sta     zp_off
        lda     ARG_CH
        sta     zp_off+1
        lda     ARG_CL
        sta     zp_off+2
        rts

abs_from_base0:
        lda     WV_RECBASE0+2   ; L
        clc
        adc     zp_off
        sta     zp_alba
        lda     WV_RECBASE0+1   ; M
        adc     zp_off+1
        sta     zp_alba+1
        lda     WV_RECBASE0     ; H
        adc     zp_off+2
        sta     zp_alba+2
        rts

; -------------------------------------------------------------------
; cd_stream: READ(6) zp_bytes bytes starting at zp_alba into a
; destination selected by zp_dstmode:
;   0 = linear: (zp_dst) advancing through the caller's map
;   1 = MPR wrap: (zp_dst) wraps inside its 8 KB window; on each
;       wrap the window's bank (zp_bank, MPR mask in zp_waiterr)
;       is incremented and re-loaded -- the CD_READ MPR form
;   2 = VRAM: bytes alternate VDC_DLO / VDC_DHI writes (MAWR
;       preset by the caller, VWR selected); zp_tmp2 = phase
; Same READ(6) handshake as read6_stream in ipl.s (6-byte CDB,
; poll for the data-in phase once, then read $1808 with no
; per-byte ACK -- the core auto-ACKs and BUSREQ-stalls).
; Carry set + zp_err on failure; zp_scsi_stat holds the status.
; -------------------------------------------------------------------
cd_stream:
        lda     #$00
        sta     zp_err
        lda     #$08
        sta     zp_cdb
        lda     zp_alba+2
        sta     zp_cdb+1
        lda     zp_alba+1
        sta     zp_cdb+2
        lda     zp_alba
        sta     zp_cdb+3
        ; record count = bytes / 2048 (callers pass whole records,
        ; except VRAM byte mode which rounds up before calling)
        lda     zp_bytes+1
        lsr     a
        lsr     a
        lsr     a
        sta     zp_cdb+4        ; low 5 bits of count come from
        lda     zp_bytes+2      ; bits 11-15; count high bits from
        asl     a               ; bytes+2 << 5
        asl     a
        asl     a
        asl     a
        asl     a
        ora     zp_cdb+4
        sta     zp_cdb+4
        lda     #$00
        sta     zp_cdb+5
        sta     zp_cdb+6
        sta     zp_cdb+7
        sta     zp_cdb+8
        sta     zp_cdb+9
        ; select
        lda     #$01
        sta     $1801
        lda     #$00
        sta     $1800
        lda     #$80
        sta     zp_waitmask
        sta     zp_waitexpect
        jsr     wait1800
        bcc     cs_cdb
        lda     #$01
        sta     zp_err
        jmp     cs_fail
cs_cdb:
        ldx     #$00
cs_cdb_loop:
        lda     #$78
        sta     zp_waitmask
        lda     #$50
        sta     zp_waitexpect
        jsr     wait1800
        bcc     cs_cdb_send
        lda     #$02
        sta     zp_err
        jmp     cs_fail
cs_cdb_send:
        lda     zp_cdb,x
        sta     $1801
        jsr     ack_pulse
        bcc     cs_cdb_next
        lda     #$03
        sta     zp_err
        jmp     cs_fail
cs_cdb_next:
        inx
        cpx     #$06
        bne     cs_cdb_loop
        ; wait for the data-in phase to be presented
        lda     #$78
        sta     zp_waitmask
        lda     #$48
        sta     zp_waitexpect
        jsr     wait1800
        bcc     cs_data_loop
        lda     #$04
        sta     zp_err
        jmp     cs_fail
cs_data_loop:
        ldx     zp_dstmode
        beq     @m0j
        dex
        beq     @m1j
        dex
        beq     @m2j
        jmp     cs_m3           ; mode 3 (and any higher
                                ; value, as in the old
                                ; dispatch's fall-through)
@m0j:   jmp     cs_m0
@m1j:   jmp     cs_m1
@m2j:   jmp     cs_m2

; cs_chunk_calc: zp_str_chunk = min(256, zp_bytes), as a
; 16-bit count (lo + hi in {0,1}); Z set on return iff
; zp_bytes == 0 (the callers' zero-count guard). Clobbers A.
cs_chunk_calc:
        stz     zp_str_chunk
        stz     zp_str_chunk+1
        lda     zp_bytes+1
        ora     zp_bytes+2
        bne     @full
        lda     zp_bytes
        sta     zp_str_chunk    ; 1..255
        ora     zp_bytes+1      ; (byte +2 is 0 on this path)
        rts                     ; Z set iff zp_bytes == 0
@full:  inc     zp_str_chunk+1  ; 256 (lo 0, hi 1); the inc
        rts                     ; leaves Z clear, as required

; cs_chunk_sub: zp_bytes -= zp_str_chunk; Z set iff
; zp_bytes is now zero. Clobbers A.
cs_chunk_sub:
        lda     zp_bytes
        sec
        sbc     zp_str_chunk
        sta     zp_bytes
        lda     zp_bytes+1
        sbc     zp_str_chunk+1
        sta     zp_bytes+1
        bcs     @t
        dec     zp_bytes+2
@t:     lda     zp_bytes
        ora     zp_bytes+1
        ora     zp_bytes+2
        rts

; cs_store_n: stream zp_str_chunk bytes (1..256) from
; $1808 to (zp_dst), advancing zp_dst by the same count.
; The base is pre-offset by (256 - count), so the Y loop
; covers exactly the chunk and one high-byte increment
; lands zp_dst on (start + count). Clobbers A, Y.
cs_store_n:
        lda     zp_str_chunk
        eor     #$FF
        clc
        adc     #$01
        sta     zp_str_pre      ; pre = (-count) mod 256
        lda     zp_dst
        sec
        sbc     zp_str_pre
        sta     zp_dst
        bcs     @loop
        dec     zp_dst+1
@loop:  ldy     zp_str_pre
@byte:  lda     $1808           ; CD data port (auto-ACK + stall)
        sta     (zp_dst),y
        iny
        bne     @byte
        inc     zp_dst+1
        rts

; cs_discard_n: consume zp_str_chunk bytes (1..256) from
; $1808, storing nothing. Clobbers A, Y.
cs_discard_n:
        lda     zp_str_chunk
        eor     #$FF
        clc
        adc     #$01
        tay
@byte:  lda     $1808
        iny
        bne     @byte
        rts

; mode 0: linear store through the caller's map.
cs_m0:
        jsr     cs_chunk_calc
        beq     @done           ; zp_bytes == 0: status phase
        jsr     cs_store_n
        jsr     cs_chunk_sub
        beq     @done
        jmp     cs_m0
@done:  jmp     cs_status

; mode 1: MPR window store. Chunks are clamped to the
; rest of the 8 KB window; the wrap fold + bank advance
; (the old per-byte cs_wrap tail) runs once per wrap.
cs_m1:
        jsr     cs_chunk_calc
        beq     @done           ; zp_bytes == 0: status phase
        lda     zp_dst+1
        and     #$1F
        cmp     #$1F
        bne     @go             ; not the window's last page
        lda     zp_dst
        beq     @go             ; a full page remains
        eor     #$FF
        clc
        adc     #$01
        sta     zp_str_rem      ; remainder, 1..255
        lda     zp_str_chunk+1
        bne     @clamp          ; a 256 chunk always clamps
        lda     zp_str_rem
        cmp     zp_str_chunk
        bcs     @go             ; remainder >= chunk
@clamp: lda     zp_str_rem
        sta     zp_str_chunk
        stz     zp_str_chunk+1
@go:    jsr     cs_store_n
        lda     zp_dst
        bne     @sub
        lda     zp_dst+1
        and     #$1F
        bne     @sub
        ; zp_dst sits exactly on the next window's base:
        ; fold it back and advance the bank.
        lda     zp_dst+1
        sec
        sbc     #$20
        sta     zp_dst+1
        inc     zp_bank
        lda     zp_bank
        ldx     zp_waiterr      ; saved TAM mask for the window
        cpx     #$04
        beq     @tam2
        cpx     #$08
        beq     @tam3
        cpx     #$10
        beq     @tam4
        cpx     #$20
        beq     @tam5
        tam     #$40            ; MPR6
        bra     @sub
@tam2:  tam     #$04
        bra     @sub
@tam3:  tam     #$08
        bra     @sub
@tam4:  tam     #$10
        bra     @sub
@tam5:  tam     #$20
@sub:   jsr     cs_chunk_sub
        beq     @done
        jmp     cs_m1
@done:  jmp     cs_status

; mode 2: VRAM. Bytes alternate VDC_DLO / VDC_DHI writes
; (MAWR preset by the caller, VWR selected); zp_tmp2 is
; the phase (0 = low byte next). The chunk runs as a
; paired loop (~12.5 clocks/byte) after a possible
; phase-completing first byte; a trailing odd byte
; leaves the phase at 1, exactly as the old loop.
cs_m2:
        jsr     cs_chunk_calc
        bne     @go             ; zp_bytes == 0: status phase
        jmp     cs_status
@go:
        lda     zp_str_chunk
        sta     zp_str_aux
        lda     zp_str_chunk+1
        sta     zp_str_aux+1    ; aux = bytes this chunk
        lda     zp_tmp2
        beq     @pairs
        lda     $1808           ; phase byte completes a word
        sta     a:VDC_DHI
        stz     zp_tmp2
        lda     zp_str_aux
        bne     @ad0
        dec     zp_str_aux+1
@ad0:   dec     zp_str_aux
        lda     zp_str_aux
        ora     zp_str_aux+1
        beq     @sub            ; the phase byte was the chunk
@pairs: lda     zp_str_aux
        and     #$01
        sta     zp_str_pre      ; tail flag (aux bit 0)
        lsr     zp_str_aux+1    ; aux (16-bit) >>= 1: the
        ror     zp_str_aux      ; pair count, 0..128
        lda     zp_str_aux
        beq     @tail
        eor     #$FF
        clc
        adc     #$01
        tay                     ; Y = (-pairs) mod 256
@pair:  lda     $1808
        sta     a:VDC_DLO
        lda     $1808
        sta     a:VDC_DHI
        iny
        bne     @pair
@tail:  lda     zp_str_pre
        beq     @sub
        lda     $1808
        sta     a:VDC_DLO
        lda     #$01
        sta     zp_tmp2         ; phase: high byte next
@sub:   jsr     cs_chunk_sub
        beq     @done
        jmp     cs_m2
@done:  jmp     cs_status

; mode 3: store the first ARG_AL bytes of the stream at
; (zp_dst) (zp_tmp2 counts them, as before); the rest is
; consumed and discarded. Per chunk, the store part is
; min(chunk, ARG_AL - zp_tmp2) and the rest is discarded.
cs_m3:
        jsr     cs_chunk_calc
        beq     @done           ; zp_bytes == 0: status phase
        lda     ARG_AL
        sec
        sbc     zp_tmp2
        bcs     @q
        lda     #$00
@q:     sta     zp_str_rem      ; quota left, 0..255
        beq     @disc           ; quota spent: discard all
        lda     zp_str_chunk+1
        bne     @split          ; a 256 chunk always splits
        lda     zp_str_rem
        cmp     zp_str_chunk
        bcs     @whole          ; the chunk fits the quota
@split: lda     zp_str_chunk
        sec
        sbc     zp_str_rem
        sta     zp_str_aux
        lda     zp_str_chunk+1
        sbc     #$00
        sta     zp_str_aux+1    ; discard count (16-bit)
        lda     zp_str_rem
        sta     zp_str_chunk
        stz     zp_str_chunk+1
        jsr     cs_store_n
        lda     ARG_AL          ; the quota is now met
        sta     zp_tmp2         ; exactly
        lda     zp_str_aux
        sta     zp_str_chunk
        lda     zp_str_aux+1
        sta     zp_str_chunk+1
        jsr     cs_discard_n
        bra     @sub
@whole: jsr     cs_store_n
        lda     zp_str_chunk    ; chunk hi is 0 on this path
        clc
        adc     zp_tmp2
        sta     zp_tmp2
        bra     @sub
@disc:  jsr     cs_discard_n
@sub:   jsr     cs_chunk_sub
        beq     @done
        jmp     cs_m3
@done:  jmp     cs_status
cs_status:
        lda     #$78
        sta     zp_waitmask
        lda     #$58
        sta     zp_waitexpect
        jsr     wait1800
        bcc     cs_status_get
        lda     #$05
        sta     zp_err
        jmp     cs_fail
cs_status_get:
        lda     $1801
        sta     zp_scsi_stat
        jsr     ack_pulse
        bcc     cs_msg
        lda     #$03
        sta     zp_err
        jmp     cs_fail
cs_msg:
        lda     #$78
        sta     zp_waitmask
        sta     zp_waitexpect
        jsr     wait1800
        bcc     cs_msg_get
        lda     #$06
        sta     zp_err
        jmp     cs_fail
cs_msg_get:
        lda     $1801
        sta     zp_scsi_msg
        jsr     ack_pulse
        bcc     cs_done
        lda     #$03
        sta     zp_err
        jmp     cs_fail
cs_done:
        ; wait for the bus to go free (BSY drop) before
        ; returning: same BUSREQ-latch handoff hazard as in
        ; ipl.s read6_stream (the CD_EXEC jump target's first
        ; instructions must not meet a latched BUSREQ). Bounded
        ; by wait1800's timeout; result ignored.
        lda     #$80
        sta     zp_waitmask
        lda     #$00
        sta     zp_waitexpect
        jsr     wait1800
        jsr     note_status
        lda     zp_scsi_stat
        beq     cs_ok
        lda     #$F0
        sta     zp_err
        jmp     cs_fail
cs_ok:
        clc
        rts
cs_fail:
        jsr     note_status
        jsr     scsi_bus_reset
        sec
        rts

; set_bytes_records: zp_bytes = A (record count) * 2048.
set_bytes_records:
        sta     zp_rcount
        lda     #$00
        sta     zp_bytes
        lda     zp_rcount
        asl     a
        asl     a
        asl     a
        sta     zp_bytes+1
        lda     zp_rcount
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        sta     zp_bytes+2
        rts

; -------------------------------------------------------------------
; CD_BOOT ($00): shift to the CD-ROM BIOS boot status (title
; screen, wait for RUN). Never returns to the caller.
; -------------------------------------------------------------------
cd_boot:
        sei
        ldx     #$FF
        txs
        jsr     show_title
        jmp     main_loop

; -------------------------------------------------------------------
; CD_RESET ($01): bring the CD drive to its reset state. The
; next command re-checks the disc and reads the TOC.
; OUT: A = 0 (OK) or a SUB ERROR CODE.
; -------------------------------------------------------------------
cd_reset:
        jsr     scsi_bus_reset
        lda     #$00
        sta     WV_SCSISTS
        jmp     ok_ret

; -------------------------------------------------------------------
; CD_BASE ($02): set the base record number(s) used by CD_READ /
; CD_SEEK / CD_EXEC offsets.
;   BH type: $00- = logical block (AL=H, AH=M, BL=L),
;            $40- = MSF (AL/AH/BL = BCD M/S/F),
;            $80- = track number (AL = BCD TNO)
;   CL set mode bits: bit 0 set = skip pair 0, bit 1 set = skip
;            pair 1 (zeograd's reading; the Hu7 table disagrees
;            and the differential arbitrates)
;   OUT: AL/AH/BL = recbase0 (H/M/L) after the call.
; -------------------------------------------------------------------
cd_base:
        ; The genuine CD_BASE's exit carry is form-
        ; dependent (2026-11-23): the LOGICAL form
        ; PRESERVES the entry carry (layer3c sec/clc pair),
        ; the MSF and TNO forms FORCE it set on success
        ; (layer3d: clear-entry probes returned set on
        ; those forms, preserved-clear on logical; this
        ; also explains cdtest's all-set BASE rows without
        ; entry-state assumptions). Save the entry status
        ; byte first (A is scratch here; inputs are the
        ; shadows); the MSF/TNO success paths overwrite
        ; the save with $FF before cb_ret.
        php
        pla
        sta     WV_PRIV_BASEC
        lda     ARG_BH
        and     #$C0
        beq     cb_logical
        cmp     #$40
        beq     cb_msf
        cmp     #$80
        beq     cb_track
        jmp     cb_out          ; unknown type: change nothing
cb_logical:
        lda     ARG_AL
        sta     zp_alba+2
        lda     ARG_AH
        sta     zp_alba+1
        lda     ARG_BL
        sta     zp_alba
        bra     cb_store
cb_msf:
        lda     ARG_AL
        jsr     from_bcd
        sta     zp_msf
        lda     ARG_AH
        jsr     from_bcd
        sta     zp_msf+1
        lda     ARG_BL
        jsr     from_bcd
        sta     zp_msf+2
        jsr     msf_to_lba
        lda     zp_acc
        sta     zp_alba
        lda     zp_acc+1
        sta     zp_alba+1
        lda     zp_acc+2
        sta     zp_alba+2
        ; MSF form: the exit carry is forced SET (the
        ; logical form preserves the entry carry instead;
        ; layer3c logical pair + layer3d forms, 2026-11-23).
        lda     #$FF
        sta     WV_PRIV_BASEC
        bra     cb_store
cb_track:
        ; No range validation (measured 2026-11-20 via the
        ; exec9 sweep): the genuine BIOS passes any track
        ; number to $DE sub 2 and converts whatever reply
        ; comes back -- track TNOMAX+1 yields the lead-out
        ; position, far out-of-range numbers yield 0 (the
        ; core's table read past the end returns zeroes in
        ; practice). Passing through identically reproduces
        ; those outcomes exactly, since both BIOSes then see
        ; the same reply bytes.
        ldx     ARG_AL          ; BCD track number
        lda     #$02
        jsr     de_cmd
        bcs     cb_out          ; cannot resolve: change nothing
        lda     zp_dirbuf
        jsr     from_bcd
        sta     zp_msf
        lda     zp_dirbuf+1
        jsr     from_bcd
        sta     zp_msf+1
        lda     zp_dirbuf+2
        jsr     from_bcd
        sta     zp_msf+2
        jsr     msf_to_lba
        lda     zp_acc
        sta     zp_alba
        lda     zp_acc+1
        sta     zp_alba+1
        lda     zp_acc+2
        sta     zp_alba+2
        ; The $DE track reply is an MSF *time* (lead-in
        ; included); msf_to_lba's -150 yields exactly the
        ; base the genuine BIOS stores (measured 2026-11-20:
        ; track 2 -> 210, track 1 -> 0, via the exec8 probe).
        ; An earlier +150 "quirk" add here double-counted the
        ; lead-in and was removed.
        ; TNO form success (layer3d + Dracula X's own BASE
        ; calls, 2026-11-23): the exit carry is forced SET
        ; (logical preserves entry instead) and _BH is left
        ; at $22 -- a constant on both the 3-track probe
        ; disc and the 22-track game disc, so it is not
        ; TNOMAX; its meaning inside the genuine is not
        ; observable from here, but games read it back.
        lda     #$FF
        sta     WV_PRIV_BASEC
        lda     #$22
        sta     ARG_BH
cb_store:
        ; Set mode (CL low 2 bits) is a SELECTOR, measured on
        ; the genuine BIOS 2026-11-20: 0 = set both pairs,
        ; 1 = set pair 0 only, 2 = set pair 1 only, 3 = set
        ; neither. (Zeograd's "bit set means skip" reading and
        ; the register being CH are both wrong; CH is ignored.)
        lda     ARG_CL
        and     #$03
        cmp     #$02
        beq     cb_skip0        ; mode 2: pair 1 only
        cmp     #$03
        beq     cb_out          ; mode 3: neither
        lda     zp_alba+2
        sta     WV_RECBASE0
        lda     zp_alba+1
        sta     WV_RECBASE0+1
        lda     zp_alba
        sta     WV_RECBASE0+2
cb_skip0:
        lda     ARG_CL
        and     #$03
        cmp     #$01
        beq     cb_out          ; mode 1: pair 0 only
        lda     zp_alba+2
        sta     WV_RECBASE1
        lda     zp_alba+1
        sta     WV_RECBASE1+1
        lda     zp_alba
        sta     WV_RECBASE1+2
cb_out:
        ; OUT shadows + A, measured on the genuine BIOS
        ; 2026-11-20: the OUT pair is the one the set-mode
        ; selected (mode 2 -> pair 1, modes 0/1 -> pair 0);
        ; A = that pair's low byte. Mode 3 leaves the shadows
        ; untouched and returns A = 0. A TNO resolution failure
        ; also lands here (pairs untouched, OUT = current pair).
        lda     ARG_CL
        and     #$03
        cmp     #$03
        beq     cb_out3
        cmp     #$02
        beq     cb_out1
        lda     WV_RECBASE0
        sta     ARG_AL
        lda     WV_RECBASE0+1
        sta     ARG_AH
        lda     WV_RECBASE0+2
        sta     ARG_BL
        lda     WV_RECBASE0+2
        bra     cb_ret
cb_out1:
        lda     WV_RECBASE1
        sta     ARG_AL
        lda     WV_RECBASE1+1
        sta     ARG_AH
        lda     WV_RECBASE1+2
        sta     ARG_BL
        lda     WV_RECBASE1+2
        bra     cb_ret
cb_out3:
        lda     #$00
cb_ret:
        pha
        lda     #$00
        sta     WV_SUBERRC
        lda     WV_PRIV_BASEC
        lsr     a               ; carry := saved entry carry
        pla                     ; (pla does not touch carry)
        rts

; -------------------------------------------------------------------
; cd_read_core: the shared CD_READ / CD_EXEC transfer.
; On entry the shadows hold the call arguments. Performs the
; transfer and returns carry clear on success; on failure carry
; is set and zp_errcode holds the SUB ERROR CODE for A.
; Destination forms (DH): $01 local (BX address, AL records),
; $02-$06 MPR window (BL bank, AL records), $FE VRAM byte mode
; (BX VRAM address, AX byte length), $FF VRAM block mode
; (BX VRAM address, AL records).
; -------------------------------------------------------------------
cd_read_core:
        ; Preserve the program's zp_bytes and zp_dst
        ; across the transfer: the genuine
        ; keeps its stream state in private WRAM and
        ; returns the program's ZP untouched (measured
        ; layer-5 with Gate of Thunder's exact 128-record
        ; MPR read: genuine changed 0 bytes of $BB-$D7,
        ; COMPAT3 zeroed $BB-$BD and left zp_dst at the
        ; stream end). The save must happen here, before
        ; set_bytes_records / the form handlers write the
        ; cells; the restore preserves A and carry.
        ldx     #$02
@sv1:   lda     zp_bytes,x
        sta     zp_str_sav,x
        dex
        bpl     @sv1
        ldx     #$01
@sv2:   lda     zp_dst,x
        sta     zp_str_sav+3,x
        dex
        bpl     @sv2
        jsr     cd_read_core_inner
        pha
        phx
        ldx     #$02
@rs1:   lda     zp_str_sav,x
        sta     zp_bytes,x
        dex
        bpl     @rs1
        ldx     #$01
@rs2:   lda     zp_str_sav+3,x
        sta     zp_dst,x
        dex
        bpl     @rs2
        plx
        pla
        rts
cd_read_core_inner:
        jsr     shadow_offset
        jsr     abs_from_base0
        lda     ARG_DH
        cmp     #$01
        beq     crc_local_j
        cmp     #$FE
        beq     crc_vram_byte_j
        cmp     #$FF
        beq     crc_vram_block_j
        cmp     #$00
        beq     crc_sink_j
        cmp     #$02
        bcc     crc_badtype_j
        cmp     #$07
        bcs     crc_badtype_j
        bra     crc_mpr
crc_badtype_j:
        jmp     crc_badtype
crc_sink_j:
        jmp     crc_sink
crc_local_j:
        jmp     crc_local
crc_vram_byte_j:
        jmp     crc_vram_byte
crc_vram_block_j:
        jmp     crc_vram_block
crc_mpr:
        ; ---- MPR window form --------------------------------
        sta     zp_tmp0         ; MPR number 2-6
        lda     ARG_AL
        jsr     set_bytes_records
        ; window base page and TAM mask from the MPR number
        lda     zp_tmp0
        sec
        sbc     #$02
        asl     a
        asl     a
        asl     a
        asl     a
        asl     a               ; (n-2)*32
        clc
        adc     #$40            ; window base high byte
        sta     zp_dst+1
        lda     #$00
        sta     zp_dst
        lda     zp_tmp0
        sec
        sbc     #$02
        tax
        lda     #$04
crc_mask:
        dex
        bmi     crc_mask_done
        asl     a
        bra     crc_mask
crc_mask_done:
        sta     zp_waiterr      ; TAM mask for this window
        ; save the caller's MPR for this window (TMA dispatch)
        lda     zp_waiterr
        cmp     #$04
        beq     crc_tma2
        cmp     #$08
        beq     crc_tma3
        cmp     #$10
        beq     crc_tma4
        cmp     #$20
        beq     crc_tma5
        tma     #$40
        bra     crc_tma_done
crc_tma2:
        tma     #$04
        bra     crc_tma_done
crc_tma3:
        tma     #$08
        bra     crc_tma_done
crc_tma4:
        tma     #$10
        bra     crc_tma_done
crc_tma5:
        tma     #$20
crc_tma_done:
        sta     zp_saved_mpr    ; caller's bank (overwrites mask
                                ; copy; zp_waiterr keeps the mask)
        lda     ARG_BL
        sta     zp_bank
        ldx     zp_waiterr
        cpx     #$04
        beq     crc_set2
        cpx     #$08
        beq     crc_set3
        cpx     #$10
        beq     crc_set4
        cpx     #$20
        beq     crc_set5
        tam     #$40
        bra     crc_go_mpr
crc_set2:
        tam     #$04
        bra     crc_go_mpr
crc_set3:
        tam     #$08
        bra     crc_go_mpr
crc_set4:
        tam     #$10
        bra     crc_go_mpr
crc_set5:
        tam     #$20
crc_go_mpr:
        lda     #$01
        sta     zp_dstmode
        jsr     cd_stream
        bcs     crc_mpr_fail
        ; restore the caller's MPR
        lda     zp_saved_mpr
        ldx     zp_waiterr
        cpx     #$04
        beq     crc_res2
        cpx     #$08
        beq     crc_res3
        cpx     #$10
        beq     crc_res4
        cpx     #$20
        beq     crc_res5
        tam     #$40
        clc
        rts
crc_res2:
        tam     #$04
        clc
        rts
crc_res3:
        tam     #$08
        clc
        rts
crc_res4:
        tam     #$10
        clc
        rts
crc_res5:
        tam     #$20
        clc
        rts
crc_mpr_fail:
        lda     zp_saved_mpr
        ldx     zp_waiterr
        cpx     #$04
        beq     crc_rf2
        cpx     #$08
        beq     crc_rf3
        cpx     #$10
        beq     crc_rf4
        cpx     #$20
        beq     crc_rf5
        tam     #$40
        jmp     crc_fail
crc_rf2:
        tam     #$04
        jmp     crc_fail
crc_rf3:
        tam     #$08
        jmp     crc_fail
crc_rf4:
        tam     #$10
        jmp     crc_fail
crc_rf5:
        tam     #$20
        jmp     crc_fail
crc_local:
        lda     ARG_AL
        jsr     set_bytes_records
        lda     ARG_BL
        sta     zp_dst
        lda     ARG_BH
        sta     zp_dst+1
        lda     #$00
        sta     zp_dstmode
        jsr     cd_stream
        bcc     crc_local_ok
        jmp     crc_fail
crc_local_ok:
        clc
        rts
crc_sink:
        ; DH = $00 (undocumented; zeograd lists "?"). The
        ; genuine lands exactly ARG_AL BYTES from the
        ; record start at BX and returns A = 0 with _AL
        ; zeroed (measured item 3.6 over counts 1-4 and
        ; three offsets, inside the cdtest phase-1
        ; environment; the p003 count-1 observation is
        ; the ARG_AL = 1 special case). The stream still
        ; runs for ARG_AL records through the sink
        ; destination mode; only the first ARG_AL bytes
        ; are stored.
        lda     ARG_AL
        jsr     set_bytes_records
        lda     ARG_BL
        sta     zp_dst
        lda     ARG_BH
        sta     zp_dst+1
        lda     #$03
        sta     zp_dstmode
        stz     zp_tmp2
        jsr     cd_stream
        bcs     crc_fail
        stz     ARG_AL          ; measured: _AL out = 0
        clc
        rts
crc_vram_block:
        lda     ARG_AL
        jsr     set_bytes_records
        bra     crc_vram_common
crc_vram_byte:
        ; byte length in AX (al = low, ah = high); the drive
        ; still transfers whole records (rounded up)
        lda     ARG_AL
        sta     zp_bytes
        lda     ARG_AH
        sta     zp_bytes+1
        lda     #$00
        sta     zp_bytes+2
        ; round up to a whole record: add 2047, clear low 11
        ; bits. The surplus stream bytes are written to VRAM
        ; as well; the reference card's exact byte-count
        ; behaviour is differential-arbitrated.
        lda     zp_bytes
        clc
        adc     #$FF
        sta     zp_bytes
        lda     zp_bytes+1
        adc     #$07
        sta     zp_bytes+1
        lda     zp_bytes+1
        and     #$F8
        sta     zp_bytes+1
        lda     #$00
        sta     zp_bytes
crc_vram_common:
        lda     #$01
        sta     WV_VDTIN_FLG    ; VRAM transfer in progress
        ; MAWR = BX, select VWR
        lda     ARG_BL
        sta     zp_vdcval
        lda     ARG_BH
        sta     zp_vdcval+1
        jsr     vdc_set_mawr
        ldy     #VDC_VWR
        sty     a:VDC_SEL
        lda     #$00
        sta     zp_tmp2         ; byte phase: 0 = low next
        lda     #$02
        sta     zp_dstmode
        jsr     cd_stream
        bcs     crc_fail
        lda     #$00            ; genuine BIOS returns with
        sta     WV_VDTIN_FLG    ; VDTIN_FLG cleared (measured)
        clc
        rts
crc_badtype:
        lda     #ERR_BAD_PARAM
        sta     zp_errcode
        sec
        rts
crc_fail:
        lda     #$00
        sta     WV_VDTIN_FLG
        lda     #ERR_NOT_READY
        sta     zp_errcode
        sec
        rts

; -------------------------------------------------------------------
; CD_READ ($03): read data from CD. OUT: A = 0 or SUB ERROR CODE.
; -------------------------------------------------------------------
cd_read:
        ; Zero-length transfers are rejected up front with
        ; $22 and carry CLEAR (measured on the genuine BIOS
        ; 2026-11-20: count 0 -> A = $22, scratch untouched).
        ; An invalid DH still reports $22 via cd_read_core,
        ; but with carry SET (also measured), so it is not
        ; intercepted here.
        lda     ARG_DH
        cmp     #$01
        beq     crd_chk_al
        cmp     #$FF
        beq     crd_chk_al
        cmp     #$FE
        beq     crd_chk_ax
        cmp     #$02
        bcc     crd_chk_al      ; DH = $00 (sink form)
        cmp     #$07
        bcc     crd_chk_al      ; DH = $02-$06 (MPR forms)
        bra     crd_go          ; invalid DH
crd_chk_ax:
        lda     ARG_AL
        ora     ARG_AH
        bne     crd_go          ; (fallthrough into crd_bad
                                ; when zero)
crd_bad:
        lda     #ERR_BAD_PARAM
        clc
        jmp     fail_with
crd_chk_al:
        lda     ARG_AL
        beq     crd_bad         ; (fallthrough into crd_go
                                ; when nonzero -- the two
                                ; fallthroughs save 4 bytes,
                                ; 2026-11-23)
crd_go:
        jsr     cd_read_core
        bcs     cr_err
        ; A successful data read stops any flagged CD-DA
        ; play (the drive serves data instead): the play
        ; flag clears, so a following CD_STAT reads $00
        ; (layer3 replica phase B, 2026-11-23). Slot exit
        ; only -- CD_EXEC / AD_CPLAY share cd_read_core
        ; and keep their own $227A handling.
        stz     WV_REC1X
        ; The genuine's CD_READ consumes the argument
        ; shadows as its working registers (LOCAL form,
        ; count > 0 only -- count 0 leaves everything,
        ; p003 case 10). Full exit contract, measured on
        ; the genuine via the replica (layer3/layer3b) and
        ; confirmed on Dracula X's own reads via return-
        ; address breakpoints (2026-11-23):
        ;   _AL <- 0, _AH <- 0 (both counted down)
        ;   _BH <- _BH + 8*count - 1 (byte arithmetic)
        ;   (CL,CH,DL) <- recbase0 + entry (CL,CH,DL),
        ;     the absolute start LBA, full 24-bit add
        ;   _BL, _DH unchanged
        ; (An earlier revision added only the low byte
        ; into _DL and left _AH/_CH/_CL alone: the replica
        ; could not tell the difference -- its recbase
        ; was $00000A and its entries had _AH = 0 -- but
        ; Dracula X's loader, whose recbase is $000E51,
        ; reads the absolute triple back and derailed.)
        ; Both fixups live in bank 3 (FIXUP2; bank 2 until
        ; C-D4 round 2) behind the crd_fixup relay -- bank 0
        ; is byte-full (layer-5).
        jsr     crd_fixup
crd_res:
        ; Success exit with the genuine's measured register
        ; residues (irq2min mode 11, 2026-11-23): X = $01,
        ; Y = $FF for any entry X/Y -- COMPAT3's copy loop
        ; used to leave X = $00 and Y preserved. Dracula X's
        ; loader sees these residues after every read.
        ldx     #$01
        ldy     #$FF
        jmp     ok_ret_sec      ; A = 0, carry set, store
cr_err:
        lda     zp_errcode
        jmp     fail_with

; -------------------------------------------------------------------
; CD_EXEC ($05): CD_READ, then load S with $FF and jump to the
; address in BX. On transfer error it returns the SUB ERROR
; CODE in A (the Hu7 note "it will be reset if an error occurs"
; is differential-arbitrated).
; -------------------------------------------------------------------
cd_exec:
        lda     ARG_BL
        sta     zp_execjmp
        lda     ARG_BH
        sta     zp_execjmp+1
        jsr     cd_read_core
        bcs     cr_err          ; shared with cd_read
        ; re-read the jump target from the argument shadows
        ; (they are verified to survive the transfer; the MPR
        ; tail below overwrites zp_execjmp for the window form
        ; anyway). The jump itself uses push/RTS -- see ce_jump
        ; for why jmp (zp) cannot be used in this core.
        lda     ARG_BL
        sta     zp_execjmp
        lda     ARG_BH
        sta     zp_execjmp+1
        ; MPR form (DH 2-6): the jump goes to the WINDOW BASE
        ; with the loaded bank mapped in (observed on the
        ; genuine BIOS 2026-11-20 via the exec2 probe: BX=$8123
        ; still entered payload2 at $8000). cd_read_core
        ; restored the caller's MPR after the load, so map the
        ; loaded bank back in first. LOCAL/VRAM forms jump to
        ; BX with the caller's mapping, as observed.
        lda     ARG_DH
        cmp     #$02
        bcc     ce_jump
        cmp     #$07
        bcs     ce_jump
        sta     zp_tmp0
        sec
        sbc     #$02
        asl     a
        asl     a
        asl     a
        asl     a
        asl     a               ; (n-2)*32
        clc
        adc     #$40            ; window base high byte
        sta     zp_execjmp+1
        lda     #$00
        sta     zp_execjmp
        lda     ARG_BL
        ldx     zp_tmp0
        cpx     #$02
        beq     ce_m2
        cpx     #$03
        beq     ce_m3
        cpx     #$04
        beq     ce_m4
        cpx     #$05
        beq     ce_m5
        tam     #$40
        bra     ce_jump
ce_m2:  tam     #$04
        bra     ce_jump
ce_m3:  tam     #$08
        bra     ce_jump
ce_m4:  tam     #$10
        bra     ce_jump
ce_m5:  tam     #$20
ce_jump:
        ldx     #$FF
        txs
        ; jump via push/RTS, NOT jmp (zp_execjmp): in this
        ; core an absolute-indirect pointer fetch from a
        ; zero-page address reads the I/O page (MPR0 = $FF,
        ; open bus), not the ZP space the stores wrote -- the
        ; p003 traces showed the pointer present at $71/$72
        ; two instructions before a jmp (zp) that nevertheless
        ; landed at $0000. The IPL's RTS jump (ipl.s) is the
        ; proven mechanism in this environment.
        lda     zp_execjmp
        bne     ce_jl
        dec     zp_execjmp+1
ce_jl:  dec     zp_execjmp
        lda     zp_execjmp+1
        pha
        lda     zp_execjmp
        pha
        rts

; -------------------------------------------------------------------
; CD_SEEK ($04): move the head to the record at recbase0 +
; offset (cl/ch/dl). The genuine BIOS implements the seek as
; a 1-record READ(6) at the target address, the data
; discarded (execution-traced 2026-11-20: for LBA 20 its CDB
; stream is 08 00 00 14 01 00). That is why CD_SUBQ after a
; seek reports the drive stopped: no $D8 play state is ever
; entered. (An earlier $D8/pause implementation left the
; drive in this core's PAUSED state and CD_SUBQ disagreed.)
; Mirrored here with the sink destination mode.
; -------------------------------------------------------------------
cd_seek:
        lda     zp_dst          ; C-D4 fix-up: preserve the
        sta     DST_SAV         ; program's zp_dst across the
        lda     zp_dst+1        ; seek stream (zp_dst is a
        sta     DST_SAV+1       ; borrow-zone cell since the
                                ; fix-up); restored at both exits
        jsr     shadow_offset
        jsr     abs_from_base0
        lda     #$01
        jsr     set_bytes_records       ; zp_bytes = 2048
        lda     #<zp_subqbuf
        sta     zp_dst
        lda     #>zp_subqbuf
        sta     zp_dst+1
        lda     #$03
        sta     zp_dstmode
        stz     zp_tmp2
        jsr     cd_stream
        bcs     csk_fail
        lda     DST_SAV
        sta     zp_dst
        lda     DST_SAV+1
        sta     zp_dst+1
        jmp     ok_ret_sec
csk_fail:
        lda     DST_SAV
        sta     zp_dst
        lda     DST_SAV+1
        sta     zp_dst+1
        lda     #ERR_NOT_READY
        jmp     fail_with

; -------------------------------------------------------------------
; CD_STAT ($09): IN A: $00 = drive busy check (OUT A: $00 = not
; busy, else busy); else = drive ready check (OUT A: $00 =
; ready, else SUB ERROR CODE).
; -------------------------------------------------------------------
cd_stat:
        sta     zp_relay_a      ; entry A (the body's argument)
        jsr     dp_save         ; C-D4 fix-up: preserve the
                                ; program's zp_dataptr (the
                                ; sense path in cd_stat_b2
                                ; leaves it at zp_subqbuf);
                                ; restored just before the exit
        tma     #$40
        pha
        lda     #$03
        tam     #$40
        lda     zp_relay_a
        jsr     cd_stat_b2
        sta     zp_relay_a      ; exit A; every body exit path
        pla                     ; leaves N/Z as a load of that
        tam     #$40            ; same A, and carry passes
        lda     DP_SAV          ; through the stub untouched,
        sta     zp_dataptr      ; so exit flags are exact (the
        lda     DP_SAV+1        ; dataptr restore sits before
        sta     zp_dataptr+1    ; the final A load on purpose)
        lda     zp_relay_a
        rts

; -------------------------------------------------------------------
; CD_SUBQ ($0A): read play status + subcode Q into the 10-byte
; buffer at BX. OUT: A = 0 or SUB ERROR CODE. Uses the NEC $DD
; command, whose reply is exactly the documented buffer.
; -------------------------------------------------------------------
; dp_save: C-D4 fix-up helper -- save the program's
; zp_dataptr into DP_SAV (clobbers A; every caller is a
; stub that reloads or discards A before the body runs).
dp_save:
        lda     zp_dataptr
        sta     DP_SAV
        lda     zp_dataptr+1
        sta     DP_SAV+1
        rts

; The five bank-3 relay stubs below also preserve the
; program's zp_dataptr (C-D4 fix-up): the _b2 bodies leave
; it standing at their reply buffer (zp_subqbuf / the TOC
; buffer). Saved into DP_SAV at stub entry, restored in
; relay_restore inside its pha/pla bracket, so exit A,
; flags and carry are untouched.
cd_subq:
        jsr     dp_save
        tma     #$40
        sta     zp_relay_mpr
        lda     #$03
        tam     #$40
        jsr     cd_subq_b2
        jmp     relay_restore

frames_to_bcdmsf:
        jsr     dp_save
        tma     #$40
        sta     zp_relay_mpr
        lda     #$03
        tam     #$40
        jsr     frames_to_bcdmsf_b2
        jmp     relay_restore

cd_dinfo:
        jsr     dp_save
        tma     #$40
        sta     zp_relay_mpr
        lda     #$03
        tam     #$40
        jsr     cd_dinfo_b2
        jmp     relay_restore

toc_refresh:
        jsr     dp_save
        tma     #$40
        sta     zp_relay_mpr
        lda     #$03
        tam     #$40
        jsr     toc_refresh_b2
        jmp     relay_restore

cd_contnts:
        jsr     dp_save
        tma     #$40
        sta     zp_relay_mpr
        lda     #$03
        tam     #$40
        jsr     cd_contnts_b2
        jmp     relay_restore

relay_restore:
        pha
        lda     DP_SAV
        sta     zp_dataptr
        lda     DP_SAV+1
        sta     zp_dataptr+1
        lda     zp_relay_mpr
        tam     #$40
        pla
        rts

; -------------------------------------------------------------------
; CD_FADE ($0F): IN A: $00 cancel, $08 PCM fade out (6.0 s),
; $0A ADPCM fade out (6.0 s), $0C PCM fade out (2.5 s), $0E
; ADPCM fade out (2.5 s). The value is written to the CD
; interface's fade timer port $180F, whose switch in this core
; is keyed on exactly these values. OUT: none.
; -------------------------------------------------------------------
cd_fade:
        sta     $180F
        rts

; -------------------------------------------------------------------
; crd_fixup relay (bank 0) + body (bank 3, segment FIXUP2;
; bank 3 since C-D4 round 2 -- bank 2 filled up with the
; BMCODE WRAM-addressing growth; the body is self-contained
; and the relay's bank byte is the only change):
; CD_READ's success exit-shadow fixups. Bank 0 is byte-full,
; so the bodies live in bank 2 behind this MPR6 relay (the
; video_init pattern). The body touches only WRAM shadows
; and zp_tmp0, so it is mapping-independent apart from its
; own code fetch. MPR6 is saved/restored around the call.
; -------------------------------------------------------------------
crd_fixup:
        tma     #$40
        pha
        lda     #$03
        tam     #$40
        jsr     crd_fixup_b2
        pla
        tam     #$40
        rts

        .segment "FIXUP2"
crd_fixup_b2:
        lda     ARG_DH
        cmp     #$01
        beq     @local
        cmp     #$02
        bcc     @out
        cmp     #$07
        bcs     @out
        ; MPR forms (DH $02-$06): the genuine's exit
        ; shadows are its reader cursor residues, measured
        ; on SYSCARD3 with a replica probe over 7 cases
        ; (counts 1,2,5,6,8,16,128; banks $68/$70/$80;
        ; layer-5, 2026-11-24):
        ;   _AL <- 0, _AH <- 0, _BL <- 0
        ;   _BH <- $47 + 8 * ((count-1) mod 4)
        ;   _DL <- start bank + ceil(count/4) - 1
        ;          (the last bank written)
        ;   _CL, _CH <- high bytes of the absolute start
        ;          LBA (recbase0 + entry triple, the same
        ;          24-bit add as the LOCAL form; the reader
        ;          computes it, then overwrites _DL with
        ;          its bank cursor -- on Gate's real read
        ;          this leaves _CH = $0E, which a probe with
        ;          recbase 131 could not distinguish).
        ;   _DH unchanged.
        clc
        lda     ARG_DL
        adc     WV_RECBASE0+2
        lda     ARG_CH
        adc     WV_RECBASE0+1
        sta     ARG_CH
        lda     ARG_CL
        adc     WV_RECBASE0
        sta     ARG_CL
        lda     ARG_AL
        sec
        sbc     #$01            ; count-1
        pha
        and     #$03
        asl     a
        asl     a
        asl     a
        clc
        adc     #$47
        sta     ARG_BH
        pla
        lsr     a
        lsr     a               ; ceil(count/4)-1
        clc
        adc     ARG_BL
        sta     ARG_DL
        stz     ARG_AL
        stz     ARG_AH
        stz     ARG_BL
        clv                     ; genuine exits with V clear
        rts
@out:
        rts
@local:
        ; LOCAL form, count > 0 only (count 0 leaves
        ; everything -- p003 case 10). Contract comment at
        ; the call site in cd_read.
        lda     ARG_AL
        beq     @done
        clc
        lda     ARG_DL
        adc     WV_RECBASE0+2
        sta     ARG_DL
        lda     ARG_CH
        adc     WV_RECBASE0+1
        sta     ARG_CH
        lda     ARG_CL
        adc     WV_RECBASE0
        sta     ARG_CL
        lda     ARG_AL
        asl     a
        asl     a
        asl     a               ; 8*count (mod 256)
        sec
        sbc     #$01
        sta     zp_tmp0
        clc
        lda     ARG_BH
        adc     zp_tmp0
        sta     ARG_BH
        lda     #$00
        sta     ARG_AL
        sta     ARG_AH
@done:
        rts

; irq1_compose_b2: the IRQ1 handler's joy-byte
; composition, relocated verbatim from bank 0 (layer 10
; round 3; bank 0 needed the room for the RCR dispatch
; and the C-L3 register saves). Called from irq1_vd
; through the MPR6 relay with bank 3 mapped (bank 2
; until C-D4 round 2), in the crd_fixup pattern above. Inputs: zp_pad_dir (Up,
; Right, Down, Left in bits 0-3) and zp_pad_cur;
; output: EX_PADTMP = the composed byte (bits 0-3 =
; I/II/Select/Run, bits 4-7 = Up/Down/Left/Right).
; A clobbered; X/Y untouched.
irq1_compose_b2:
        lda     zp_pad_dir
        asl     a
        asl     a
        asl     a
        sta     EX_PADTMP       ; dir << 3: Down->5, Left->6
        and     #$60
        sta     EX_PADTMP2
        lda     EX_PADTMP
        asl     a               ; dir << 4
        and     #$10            ; Up->4
        ora     EX_PADTMP2
        sta     EX_PADTMP2
        lda     zp_pad_dir
        asl     a
        asl     a
        asl     a
        asl     a
        asl     a
        asl     a               ; dir << 6
        and     #$80            ; Right->7
        ora     EX_PADTMP2
        ora     zp_pad_cur
        sta     EX_PADTMP       ; the composed byte (bits 0-3
                                ; of zp_pad_cur are I/II/S/R;
                                ; its high bits are III-VI,
                                ; masked out below)
        and     #$0F
        sta     EX_PADTMP2
        lda     EX_PADTMP
        and     #$F0
        ora     EX_PADTMP2
        sta     EX_PADTMP
        rts

; tur_cmd: TEST UNIT READY. Carry clear + zp_scsi_stat = 0 when
; the drive is ready; carry set on transport error, or carry
; clear with zp_scsi_stat != 0 (CHECK CONDITION) when not.
; (In segment FIXUP2 since the C-D4 fix-up; see the note at
; its old bank-0 site.)
tur_cmd:
        lda     #$00
        ldx     #$0A
tc_clear:
        sta     zp_cdb,x
        dex
        bpl     tc_clear
        sta     zp_datalen
        jmp     scsi_cmd6

; sense_cmd: REQUEST SENSE, 10 bytes into zp_subqbuf (reused
; as the sense buffer). The byte that matters is +2: in this
; core it is $06 whenever the device is not ready, $00 when
; ready (the core derives it from readiness at sense time).
; Carry set on transport error.
sense_cmd:
        lda     #$00
        ldx     #$0A
sns_clear:
        sta     zp_cdb,x
        dex
        bpl     sns_clear
        lda     #$03
        sta     zp_cdb
        lda     #$0A
        sta     zp_cdb+4
        sta     zp_datalen
        lda     #<zp_subqbuf
        sta     zp_dataptr
        lda     #>zp_subqbuf
        sta     zp_dataptr+1
        jmp     scsi_cmd6

; cd_stat_b2: the CD_STAT body, relocated to bank 2
; (layer 10 round 4, same room-making as above; bank 3
; since C-D4 round 2, with the rest of segment FIXUP2;
; reached through the A-preserving bank-0 cd_stat relay
; stub, which now maps bank 3).
cd_stat_b2:
        cmp     #$00
        beq     cst_busy
        jsr     tur_cmd
        bcs     cst_sense
        jsr     note_status
        lda     zp_scsi_stat
        bne     cst_sense
        jmp     ok_ret
cst_sense:
        ; CHECK CONDITION (or transport failure): fetch the
        ; sense data, publish byte +2 at $227D, and treat the
        ; unit-attention key $06 as READY. Measured on the
        ; genuine BIOS (2026-11-20 differential, case 51: no
        ; disc after an eject): its CD_STAT returns A = 0 with
        ; carry SET and $227D = $06, and $227D then stays $06
        ; (sticky) for the rest of the session.
        jsr     sense_cmd
        bcs     cst_notready
        jsr     note_status
        lda     zp_scsi_stat
        bne     cst_notready
        lda     zp_subqbuf+2
        sta     WV_SENSE
        cmp     #$06
        beq     cst_ua
        bra     cst_notready
cst_ua:
        jmp     ok_ret_sec
cst_notready:
        lda     #ERR_NOT_READY
        jmp     fail_with
cst_busy:
        lda     $1800
        and     #$80            ; BSY: a command is in flight
        beq     cst_idle
        lda     #$01            ; busy (not an error return)
        rts
cst_idle:
        ; A = $80 while a flagged CD play (CD_PLAY modes
        ; 1/2, $227A set) is in effect, else $00 (layer3
        ; replica + layer3c, 2026-11-23). The $80 is BIOS
        ; play state, not live drive state: a raw $D8 play
        ; that bypasses CD_PLAY (p003) still reads $00,
        ; and a mode-0 CD_PLAY (flag $00) reads $00 while
        ; its audio plays. X = $00 in the $80 case
        ; (measured); the idle case preserves X.
        lda     WV_REC1X
        beq     cst_idle0
        lda     #$00
        sta     WV_SUBERRC
        ldx     #$00
        lda     #$80
        sec
        rts
cst_idle0:
        jmp     ok_ret



; cd_subq_b2 / frames_to_bcdmsf_b2 / cd_dinfo_b2 /
; toc_refresh_b2 / cd_contnts_b2: the SUBQ / DINFO /
; CONTNTS cluster, relocated to bank 2 (layer 10 round 4,
; same room-making as cd_stat_b2; bank 3 since C-D4
; round 2, segment FIXUP2). None of these bodies
; waits on the device directly -- every device wait runs
; inside scsi_cmd / de_cmd in bank 0 -- so, like
; cd_stat_b2, they are safe behind MPR6 relay stubs.
; (The cd_stream prologue and status tail were tried in
; bank 2 first and came back: their direct wait1800 /
; ack_pulse calls break the phase waits from the window.)
cd_subq_b2:
        lda     #$DD
        sta     zp_cdb
        lda     #$00
        ldx     #$09
csq_clear:
        sta     zp_cdb+1,x
        dex
        bpl     csq_clear
        lda     #<zp_subqbuf
        sta     zp_dataptr
        lda     #>zp_subqbuf
        sta     zp_dataptr+1
        lda     #$0A
        sta     zp_datalen
        jsr     scsi_cmd
        jsr     note_status
        bcs     csq_fail
        lda     zp_scsi_stat
        bne     csq_fail
        ; The $DD reply's MSF fields are passed through in
        ; every state: when stopped, the core reports the
        ; segment start frame, and the genuine returns
        ; exactly that (p005 differential, 2026-11-20: after
        ; CD_PAUSE its SUBQ shows the paused segment's start
        ; MSF, not zeroes; the zero buffers seen in p003 all
        ; had a $DD frame of 0 underneath). One adjustment:
        ; the track and index bytes are floored at 1 -- when
        ; the position sits in track 1's pregap the core's
        ; $DD reports 0/0, but the genuine reports 1/1
        ; (p003 spot checks, re-measured 2026-11-20).
        ; A successful SUBQ also clears the $227A play-mode
        ; flag (set by CD_PLAY / CD_SEARCH; measured in p005).
        lda     #$00
        sta     WV_REC1X
        lda     zp_subqbuf+2
        bne     csq_trk_ok
        lda     #$01
        sta     zp_subqbuf+2
csq_trk_ok:
        lda     zp_subqbuf+3
        bne     csq_idx_ok
        lda     #$01
        sta     zp_subqbuf+3
csq_idx_ok:
csq_copy0:
        ; copy the 10 reply bytes to the caller's buffer (BX).
        ; C-D4 fix-up: zp_dst is a borrow-zone cell now, so
        ; preserve the program's value across the copy
        ; (DST_SAV; restored at csq_bxdone, before the exit
        ; tail sets A / carry itself).
        lda     zp_dst
        sta     DST_SAV
        lda     zp_dst+1
        sta     DST_SAV+1
        lda     ARG_BL
        sta     zp_dst
        lda     ARG_BH
        sta     zp_dst+1
        ldy     #$00
        ldx     #$00
csq_copy:
        lda     zp_subqbuf,x    ; zp,X form (see cdi_copy note)
        sta     (zp_dst),y
        inx
        iny
        cpy     #$0A
        bne     csq_copy
        ; The genuine leaves BX advanced past the 10-byte
        ; reply (p003 differential: its _BL is COMPAT3's
        ; + $0A in every SUBQ case; 16-bit add assumed).
        clc
        lda     ARG_BL
        adc     #$0A
        sta     ARG_BL
        bcc     csq_bxdone
        inc     ARG_BH
csq_bxdone:
        lda     DST_SAV         ; C-D4 fix-up: restore zp_dst
        sta     zp_dst
        lda     DST_SAV+1
        sta     zp_dst+1
        sec                     ; success carry is forced set
        jmp     ok_ret          ; (ok_ret/fail_with keep it)
csq_fail:
        lda     #ERR_NOT_READY
        jmp     fail_with

; -------------------------------------------------------------------
; frames_to_bcdmsf: zp_acc (24-bit absolute frame count) ->
; zp_dirbuf[0..2] = BCD minutes / seconds / frames.
; (Uses scsi.s's to_bcd.)
; -------------------------------------------------------------------
frames_to_bcdmsf_b2:
        ldx     #$00            ; minutes
ftbm_m:
        lda     zp_acc+2
        bne     ftbm_msub
        lda     zp_acc+1
        cmp     #$11
        bcc     ftbm_mdone
        bne     ftbm_msub
        lda     zp_acc
        cmp     #$94
        bcc     ftbm_mdone
ftbm_msub:
        sec
        lda     zp_acc
        sbc     #$94            ; 4500 = $1194
        sta     zp_acc
        lda     zp_acc+1
        sbc     #$11
        sta     zp_acc+1
        lda     zp_acc+2
        sbc     #$00
        sta     zp_acc+2
        inx
        bra     ftbm_m
ftbm_mdone:
        txa
        jsr     to_bcd
        sta     zp_dirbuf
        ldx     #$00            ; seconds (zp_acc < 4500 now)
ftbm_s:
        lda     zp_acc+1
        bne     ftbm_ssub
        lda     zp_acc
        cmp     #$4B            ; 75
        bcc     ftbm_sdone
ftbm_ssub:
        sec
        lda     zp_acc
        sbc     #$4B
        sta     zp_acc
        lda     zp_acc+1
        sbc     #$00
        sta     zp_acc+1
        inx
        bra     ftbm_s
ftbm_sdone:
        txa
        jsr     to_bcd
        sta     zp_dirbuf+1
        lda     zp_acc          ; remainder = frames (< 75)
        jsr     to_bcd
        sta     zp_dirbuf+2
        rts

; -------------------------------------------------------------------
; CD_DINFO ($0B): read TOC data into the 4-byte buffer at BX.
;   AL = 0: [min TNO, max TNO, 0, 0]            ($DE sub 0)
;   AL = 1: lead-out [M, S, F, 0] (BCD)         ($DE sub 1)
;   AL = 2: track AH [M, S, F, control] (BCD)   ($DE sub 2)
;   AL = 3: track AH [rec H, rec M, rec L, control]
;           (synthesized from sub 2: the core's $DE has no
;           sub 3; MSF -> LBA is exact)
; OUT: A = 0 or SUB ERROR CODE.
; -------------------------------------------------------------------
cd_dinfo_b2:
        lda     ARG_AL
        cmp     #$00
        beq     cdi_sub0
        cmp     #$01
        beq     cdi_sub1
        cmp     #$02
        beq     cdi_s2_t
        cmp     #$03
        beq     cdi_s3_t
        lda     #ERR_BAD_PARAM
        jmp     fail_with
cdi_s2_t:
        jmp     cdi_sub2
cdi_s3_t:
        jmp     cdi_sub3
cdi_sub0:
        lda     #$00
        ldx     #$00
        jsr     de_cmd
        bcs     cdi_fail_t
        jmp     cdi_copy
cdi_sub1:
        lda     #$01
        ldx     #$00
        jsr     de_cmd
        bcs     cdi_fail_t
        jmp     cdi_copy
cdi_copy:
        ; C-D4 fix-up: preserve the program's zp_dst across
        ; the copy (DST_SAV; restored after the loop).
        lda     zp_dst
        sta     DST_SAV
        lda     zp_dst+1
        sta     DST_SAV+1
        lda     ARG_BL
        sta     zp_dst
        lda     ARG_BH
        sta     zp_dst+1
        ldy     #$00
        ldx     #$00
cdi_copy_loop:
        ; NOTE: the source index must be X, not Y. The HuC6280
        ; has no zero-page,Y load/store for these mnemonics,
        ; so `lda zp_dirbuf,y` assembles as ABSOLUTE,Y -- and
        ; in this core an absolute $00xx access goes through
        ; MPR0 ($FF = the I/O page), not the ZP cell. (Found
        ; 2026-11-20: DINFO/SUBQ returned garbage buffers.)
        lda     zp_dirbuf,x
        sta     (zp_dst),y
        inx
        iny
        cpy     #$04
        bne     cdi_copy_loop
        lda     DST_SAV         ; C-D4 fix-up: restore zp_dst
        sta     zp_dst
        lda     DST_SAV+1
        sta     zp_dst+1
        jmp     ok_ret
cdi_fail_t:
        jmp     cdi_fail
cdi_fail:
        lda     #ERR_NOT_READY
        jmp     fail_with

cdi_sub2:
        lda     #$02
        ldx     ARG_AH
        jsr     de_cmd
        bcs     cdi_fail_t
        ; The $DE sub-2 reply IS the value the genuine BIOS
        ; returns for type 2 (measured 2026-11-20 via exec8:
        ; the reply is an MSF time with the lead-in included,
        ; e.g. track 2 -> [00 04 60], which is what the
        ; genuine DINFO type 2 reports). An earlier conversion
        ; here added a further +300 frames on a mistaken
        ; "quirk" theory and double-counted; removed.
        jmp     cdi_copy
cdi_sub3:
        lda     #$02
        ldx     ARG_AH
        jsr     de_cmd
        bcs     cdi_fail_t
        lda     zp_dirbuf
        jsr     from_bcd
        sta     zp_msf
        lda     zp_dirbuf+1
        jsr     from_bcd
        sta     zp_msf+1
        lda     zp_dirbuf+2
        jsr     from_bcd
        sta     zp_msf+2
        jsr     msf_to_lba
        ; Record-number form: the record base is the same
        ; value CD_BASE's track form stores (the $DE reply is
        ; an MSF time; msf_to_lba converts it, e.g. track 2
        ; -> 210, track 1 -> 0). The genuine type 3 hangs in
        ; this core, so this remains model-based, not
        ; differential-verified.
cdi_s3_store:
        lda     zp_acc+2
        sta     zp_dirbuf
        lda     zp_acc+1
        sta     zp_dirbuf+1
        lda     zp_acc
        sta     zp_dirbuf+2
        ; zp_dirbuf+3 (control) already in place from sub 2
        jmp     cdi_copy        ; (was missing: the store fell
                                ; through into toc_refresh, so
                                ; type 3 never copied the buffer
                                ; and returned the lead-out frame
                                ; byte in A -- found 2026-11-20
                                ; once the t3 cases ran for real)
; -------------------------------------------------------------------
; toc_refresh: read the TOC summary into the public work
; variables (tnomin/tnomax from $DE sub 0, lead-out MSF from
; $DE sub 1). Carry set on failure (variables untouched).
; Shared by CD_CONTNTS and the boot disc_check.
; -------------------------------------------------------------------
toc_refresh_b2:
        lda     #$00
        ldx     #$00
        jsr     de_cmd
        bcs     tr_ret
        lda     zp_dirbuf
        sta     WV_TNOMIN
        lda     zp_dirbuf+1
        sta     WV_TNOMAX
        lda     #$01
        ldx     #$00
        jsr     de_cmd
        bcs     tr_ret
        lda     zp_dirbuf
        sta     WV_OUTMIN
        lda     zp_dirbuf+1
        sta     WV_OUTSEC
        lda     zp_dirbuf+2
        sta     WV_OUTFRM
        clc
tr_ret:
        rts

; -------------------------------------------------------------------
; CD_CONTNTS ($0C): (re-)initialize the system work from the
; current disc's TOC: TNOMIN/TNOMAX/OUTMIN/OUTSEC/OUTFRM.
; OUT: A = 0 or SUB ERROR CODE.
; -------------------------------------------------------------------
cd_contnts_b2:
        jsr     toc_refresh_b2
        bcs     cct_fail
        ; The genuine also returns TNOMIN in _AL (layer3
        ; replica, 2026-11-23: _AL = $01 out for input
        ; _AL = $00, both AL forms; AL itself is ignored
        ; and there is no buffer form -- the AL=1 buffer
        ; bytes seen in probing were CD_DINFO residue).
        lda     WV_TNOMIN
        sta     ARG_AL
        jmp     ok_ret_sec
cct_fail:
        lda     #ERR_NOT_READY
        jmp     fail_with


        .segment "CODE"
