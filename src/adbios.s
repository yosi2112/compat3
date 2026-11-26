; COMPAT3 ADPCM BIOS (ws005 p004) -- the AD_* jump-table group
; (slots $10-$17) plus the IPL OPENMODE ADP opening.
; Clean-room: behaviour from the public Hu7 manual / zeograd
; parameter lists and from black-box differential probing of
; the genuine card in this core (pce-web/PROGRESS.md, p004
; section). No NEC/Hudson code or data.
;
; Hardware model (CSCP core, src/vm/pcengine/pce.cpp): the
; ADPCM unit is register-driven through $1808-$180E, and its
; playback termination is stateful, so the port protocol below
; mirrors the one the genuine BIOS's observable effects imply:
;   - $180D bit1 sets the write address; bit0 of the same
;     write is the core's swallow flag (with $03 the first
;     $180A write is dropped). AD_WRITE uses $03, so its
;     stored stream is src[1..AX-1] (measured byte-for-byte);
;     the DMA paths and DH=0 TRANS use $02 (nothing dropped).
;   - The core counts DMA-delivered bytes (adpcm_written);
;     a write-address set resets the count to 0, and a play
;     in DMA mode ends exactly when the count is consumed.
;     AD_TRANS therefore delivers through the core's DMA
;     path ($180B arming), never through CPU reads, so the
;     count and the DMA-armed flag at return match the
;     genuine's, including the knock-on effects on later
;     AD_PLAY termination (all measured).
;   - $180D bit3 sets the read address (two dummy $180A
;     reads prime the read buffer); bit4 sets the length;
;     bit6 rising edge starts playback; bit6=0 with bit5=0
;     stops; bit7 falling edge resets the unit (and clears
;     the DMA-armed flag).
; AD_STAT's X state (0 first half / 4 second half / 1 stopped)
; lives in zp_ad_state, maintained by ad_play / ad_stop /
; ad_reset and by the IRQ2 handler's half/full branches in
; bank0.s (a repeat play is restarted there on the full IRQ).
        .segment "CODE"

; -------------------------------------------------------------------
; AD_RESET (slot $10): reset the ADPCM unit. No documented
; inputs or outputs; measured on the genuine: carry clear,
; playback stopped, AD_STAT reports stopped afterwards.
; -------------------------------------------------------------------
ad_reset:
        lda     #$80
        sta     $180D
        lda     #$00
        sta     $180D           ; bit7 falling edge: core reset
        sta     zp_ad_rpt
        sta     zp_ad_cp
        sta     zp_ad_start
        sta     zp_ad_start+1
        sta     zp_ad_len
        sta     zp_ad_len+1
        sta     zp_ad_rate
        stz     zp_ad_state     ; clear deferred $227A flag
        clc
        rts

; -------------------------------------------------------------------
; AD_STOP (slot $16): stop playback now. Measured: the
; genuine leaves A = $60 deterministically in this
; environment, carry clear, AD_STAT stopped immediately.
; -------------------------------------------------------------------
ad_stop:
        lda     #$00
        sta     $180D           ; bit6=0, bit5=0: core stop
        sta     zp_ad_rpt
        sta     zp_ad_cp
        stz     zp_ad_state     ; clear deferred $227A flag
        lda     #$60
        ; carry PRESERVED from entry (measured layer3c,
        ; 2026-11-23: sec->set, clc->clear on the genuine;
        ; no instruction here touches carry once the
        ; old clc is gone). p004 enters carry-clear in
        ; every gated case, so this changes nothing there.
        rts

; -------------------------------------------------------------------
; AD_STAT (slot $17): A = $08 while playing, else $00;
; X = $00 (first half), $04 (second half), $01 (stopped);
; carry PRESERVED from entry (layer3c, 2026-11-23:
; sec->set / clc->clear in both states, any shadows --
; the p003/p004 contexts all enter carry-clear, which
; is why "carry clear" measured there; Dracula X's
; attract poll enters with carry set from its own code
; and the genuine hands it back untouched). No
; instruction in either path touches carry now.
; "Playing" is the core's PLAY flag, $180C bit 3 -- the
; same bit whose value the genuine returns in A. The
; half state is the core's HALF latch in $1803 bit 2,
; read live: the latch is set when the play pointer
; crosses the half address and cleared by the core
; when it crosses the end address, so X = $04 is
; transient exactly as measured on the genuine (a poll
; that catches the half window sees $04; a later poll
; of the same play sees $00 again).
; -------------------------------------------------------------------
ad_stat:
        lda     $180C
        and     #$08
        beq     as_stopped
        lda     $1803
        and     #$04
        tax                     ; X = $04 in the half window,
        lda     #$08            ; else $00
        rts
as_stopped:
        stz     zp_ad_cp
        ldx     #$01
        lda     #$00
        rts

; -------------------------------------------------------------------
; AD_PLAY (slot $14): start playback.
;   mode 0 (DL bit0 = 0): BX = start, AX = length, DH =
;     rate; the parameters are saved for counter mode.
;   counter mode (DL bit0 = 1): reuse the saved parameters
;     (this call's BX/AX/DH are ignored -- measured).
;   DL bit7 = repeat (restarted by the IRQ2 full handler).
; While a play is already active the call is refused with
; A = $08 and nothing changes (measured). Success: A = 0,
; carry clear.
; -------------------------------------------------------------------
ad_play:
        lda     $180C
        and     #$08
        beq     ap_idle
        lda     #$08            ; busy: A = $08, carry clear,
        clc                     ; SUBERRC untouched (measured)
        rts
ap_idle:
        lda     ARG_DL
        and     #$01
        bne     ap_go           ; counter mode: keep saved
        lda     ARG_BL
        sta     zp_ad_start
        lda     ARG_BH
        sta     zp_ad_start+1
        lda     ARG_AL
        sta     zp_ad_len
        lda     ARG_AH
        sta     zp_ad_len+1
        lda     ARG_DH
        sta     zp_ad_rate
ap_go:
        lda     ARG_DL
        and     #$80
        beq     ap_norpt
        lda     #$01
        sta     zp_ad_rpt
        bra     ap_state
ap_norpt:
        stz     zp_ad_rpt
ap_state:
        stz     zp_ad_state
        stz     zp_ad_cp
        lda     zp_ad_rate
        sta     $180E
        jsr     ad_play_kick
        lda     #$08            ; unmask the ADPCM full-play
        sta     $1802           ; IRQ (the core gates the CPU
        sta     zp_imask        ; IRQ2 line on this register;
                                ; the zp_imask shadow makes the
                                ; SCSI ACK pulse preserve it --
                                ; a raw $00 there would mute
                                ; repeat restarts.
                                ; The half IRQ stays masked: the
                                ; half state is a latch AD_STAT
                                ; reads, and an enabled level
                                ; line on it would spin the CPU
                                ; in the handler -- see bank0.s)
        clc
        jmp     ok_ret          ; A = 0, SUBERRC = 0

; ad_play_kick: (re)start playback with the saved parameters
; (zp_ad_start / zp_ad_len; rate already written). Also used
; by the IRQ2 handler for repeat plays. Uses only A.
ad_play_kick:
        lda     zp_ad_start
        sta     $1808
        lda     zp_ad_start+1
        sta     $1809
        lda     #$08
        sta     $180D           ; set read address
        lda     zp_ad_len
        sta     $1808
        lda     zp_ad_len+1
        sta     $1809
        lda     #$10
        sta     $180D           ; set length
        lda     zp_ad_rpt
        beq     apk_single
        lda     #$60            ; play + repeat gate bit
        bra     apk_go
apk_single:
        lda     #$40            ; play
apk_go:
        sta     $180D
        rts

; -------------------------------------------------------------------
; ad_dec_cnt: decrement the 16-bit stream counter zp_ad_cnt.
; Carry set when it reached zero, clear otherwise.
; -------------------------------------------------------------------
ad_dec_cnt:
        lda     zp_ad_cnt
        bne     adc_d0
        dec     zp_ad_cnt+1
adc_d0:
        dec     zp_ad_cnt
        lda     zp_ad_cnt
        ora     zp_ad_cnt+1
        beq     adc_zero
        clc
        rts
adc_zero:
        sec
        rts

; -------------------------------------------------------------------
; MPR window helpers for the AD_READ / AD_WRITE MPR forms.
; ad_win_calc: ARG_DH = MPR number (2-6); computes the window
; base into zp_ad_ptr and the TAM mask into zp_ad_mask (the
; same derivation as cd_read's MPR form). ad_tam loads the
; bank in zp_bank into the zp_ad_mask window; ad_tma reads
; the window's current bank into zp_ad_saved.
; -------------------------------------------------------------------
ad_win_calc:
        lda     ARG_DH
        sec
        sbc     #$02
        asl     a
        asl     a
        asl     a
        asl     a
        asl     a               ; (n-2)*32
        clc
        adc     #$40            ; window base high byte
        sta     zp_ad_ptr+1
        lda     #$00
        sta     zp_ad_ptr
        lda     ARG_DH
        sec
        sbc     #$02
        tax
        lda     #$04
awc_mask:
        dex
        bmi     awc_done
        asl     a
        bra     awc_mask
awc_done:
        sta     zp_ad_mask
        rts

ad_tam:
        lda     zp_bank
        ldx     zp_ad_mask
        cpx     #$04
        beq     atam_2
        cpx     #$08
        beq     atam_3
        cpx     #$10
        beq     atam_4
        cpx     #$20
        beq     atam_5
        tam     #$40
        rts
atam_2:
        tam     #$04
        rts
atam_3:
        tam     #$08
        rts
atam_4:
        tam     #$10
        rts
atam_5:
        tam     #$20
        rts

ad_tma:
        lda     zp_ad_mask
        cmp     #$04
        beq     atma_2
        cmp     #$08
        beq     atma_3
        cmp     #$10
        beq     atma_4
        cmp     #$20
        beq     atma_5
        tma     #$40
        bra     atma_done
atma_2:
        tma     #$04
        bra     atma_done
atma_3:
        tma     #$08
        bra     atma_done
atma_4:
        tma     #$10
        bra     atma_done
atma_5:
        tma     #$20
atma_done:
        sta     zp_ad_saved
        rts

; ad_ptr_wrap: advance zp_ad_ptr by one byte; on an 8 KB
; window wrap, advance the window bank (zp_bank) and reload
; it (the CD_READ MPR form's wrap discipline).
ad_ptr_wrap:
        inc     zp_ad_ptr
        bne     apw_done
        inc     zp_ad_ptr+1
        lda     zp_ad_ptr+1
        and     #$1F
        bne     apw_done
        lda     zp_ad_ptr+1
        sec
        sbc     #$20
        sta     zp_ad_ptr+1
        inc     zp_bank
        jsr     ad_tam
apw_done:
        rts

; -------------------------------------------------------------------
; AD_WRITE (slot $13): copy AX bytes into ADPCM RAM at CX.
;   DH = $00 local: source = (BX), caller's map, linear
;   DH = $02-$06 MPR form: BL = bank; source = the MPR[DH]
;        window base, wrapping with bank increment; the
;        window's MPR is LEFT set to the bank used (measured:
;        the genuine does not restore it after a write)
;   DH = $FF VRAM: source = VRAM word address BX; VDTIN_FLG
;        raised during the transfer; returns carry SET
;        (the other forms return carry clear)
; The write address is set with $180D = $03, so the core
; drops the first byte written: the stored stream is
; src[1..AX-1] (measured byte-for-byte via a dump program).
; AX = 0 still performs the address set (which resets the
; core's DMA byte count) but moves no data (measured).
; -------------------------------------------------------------------
ad_write:
        lda     ARG_CL
        sta     $1808
        lda     ARG_CH
        sta     $1809
        lda     #$03
        sta     $180D           ; set write addr, swallow 1st
        lda     ARG_AL
        sta     zp_ad_cnt
        lda     ARG_AH
        sta     zp_ad_cnt+1
        ora     zp_ad_cnt
        beq     aw_done_clc
        lda     ARG_DH
        beq     aw_local
        cmp     #$FF
        beq     aw_vram
        cmp     #$02
        bcc     aw_badtype
        cmp     #$07
        bcs     aw_badtype
        bra     aw_mpr
aw_badtype:
        lda     #ERR_BAD_PARAM
        jsr     fail_with
        sec
        rts
aw_done_clc:
        clc
        jmp     ok_ret
aw_done_sec:
        sec
        jmp     ok_ret
aw_local:
        lda     ARG_BL
        sta     zp_ad_ptr
        lda     ARG_BH
        sta     zp_ad_ptr+1
aw_local_loop:
        lda     (zp_ad_ptr)
        sta     $180A
        inc     zp_ad_ptr
        bne     aw_local_dec
        inc     zp_ad_ptr+1
aw_local_dec:
        jsr     ad_dec_cnt
        bcc     aw_local_loop
        bra     aw_done_clc
aw_mpr:
        jsr     ad_win_calc
        lda     ARG_BL
        sta     zp_bank
        jsr     ad_tam          ; map the bank; left in place
aw_mpr_loop:
        lda     (zp_ad_ptr)
        sta     $180A
        jsr     ad_ptr_wrap
        jsr     ad_dec_cnt
        bcc     aw_mpr_loop
        bra     aw_done_clc
aw_vram:
        lda     #$01
        sta     WV_VDTIN_FLG
        lda     #VDC_MARR
        sta     a:VDC_SEL
        lda     ARG_BL
        sta     a:VDC_DLO
        lda     ARG_BH
        sta     a:VDC_DHI
        lda     #VDC_VWR        ; select the data port, as in
        sta     a:VDC_SEL       ; the vram_read_b sequence that
                                ; measurably advances through
                                ; VRAM in this core (selecting
                                ; VRR left the read buffer stuck
                                ; on the first word)
        ; No priming reads: the read buffer serves the first
        ; word immediately after MARR, and the transfer's
        ; first byte is the one the $180D=$03 swallow drops
        ; anyway -- the genuine's stored stream starts at
        ; source byte 1 (measured with a dump probe,
        ; 2026-11-20; a dummy pair here shifted the stream
        ; by one word). The core's VDC read buffer advances
        ; on back-to-back data-port pairs (the vram_read_b
        ; pattern): read the low and high bytes of each word
        ; together, then write both to the ADPCM port.
        ; Reading the pair in separate loop iterations
        ; returned the same stale word forever (also measured).
aw_vram_loop:
        lda     a:VDC_DLO
        sta     zp_ad_phase     ; low byte held across the
        lda     a:VDC_DHI       ; high read
        sta     zp_tmp0
        lda     zp_ad_phase
        sta     $180A
        jsr     ad_dec_cnt
        bcs     aw_vram_done    ; count hit zero on the low
        lda     zp_tmp0         ; byte: the high byte is not
        sta     $180A           ; written (AX was odd)
        jsr     ad_dec_cnt
        bcc     aw_vram_loop
aw_vram_done:
        lda     #$00
        sta     WV_VDTIN_FLG
        jmp     aw_done_sec

; -------------------------------------------------------------------
; AD_READ (slot $12): copy AX bytes from ADPCM RAM at CX to
; host memory / VRAM. The DH forms mirror AD_WRITE's, with
; two measured differences: the MPR form RESTORES the
; caller's window MPR afterwards, and AX = 0 never returns
; on the genuine in this core (runaway; see the policy note
; at ar_policy).
; -------------------------------------------------------------------
ad_read:
        lda     ARG_AL
        ora     ARG_AH
        beq     ar_policy
        lda     ARG_AL
        sta     zp_ad_cnt
        lda     ARG_AH
        sta     zp_ad_cnt+1
        lda     ARG_CL
        sta     $1808
        lda     ARG_CH
        sta     $1809
        lda     #$08
        sta     $180D           ; set read address
        lda     $180A           ; two dummy reads prime the
        lda     $180A           ; core's read buffer
        lda     ARG_DH
        beq     ar_local
        cmp     #$FF
        beq     ar_vram
        cmp     #$02
        bcc     ar_badtype
        cmp     #$07
        bcs     ar_badtype
        bra     ar_mpr
ar_policy:
        ; AX = 0: the genuine call never returns in this
        ; core (measured runaway inside the BIOS; the
        ; caller's RAM ends up rearranged -- an artifact of
        ; the runaway, not a function). COMPAT3 policy:
        ; return ERR_BAD_PARAM without transferring, the
        ; same policy shape as p003's unobservable cases.
        lda     #ERR_BAD_PARAM
        jsr     fail_with
        sec
        rts
ar_badtype:
        lda     #ERR_BAD_PARAM
        jsr     fail_with
        sec
        rts
ar_done_clc:
        clc
        jmp     ok_ret
ar_done_sec:
        sec
        jmp     ok_ret
ar_local:
        lda     ARG_BL
        sta     zp_ad_ptr
        lda     ARG_BH
        sta     zp_ad_ptr+1
ar_local_loop:
        lda     $180A
        sta     (zp_ad_ptr)
        inc     zp_ad_ptr
        bne     ar_local_dec
        inc     zp_ad_ptr+1
ar_local_dec:
        jsr     ad_dec_cnt
        bcc     ar_local_loop
        bra     ar_done_clc
ar_mpr:
        jsr     ad_win_calc
        jsr     ad_tma          ; save the caller's bank
        lda     ARG_BL
        sta     zp_bank
        jsr     ad_tam
ar_mpr_loop:
        lda     $180A
        sta     (zp_ad_ptr)
        jsr     ad_ptr_wrap
        jsr     ad_dec_cnt
        bcc     ar_mpr_loop
        lda     zp_ad_saved     ; restore the caller's bank
        sta     zp_bank
        jsr     ad_tam
        bra     ar_done_clc
ar_vram:
        lda     #$01
        sta     WV_VDTIN_FLG
        lda     #VDC_MAWR
        sta     a:VDC_SEL
        lda     ARG_BL
        sta     a:VDC_DLO
        lda     ARG_BH
        sta     a:VDC_DHI
        lda     #VDC_VWR
        sta     a:VDC_SEL
        stz     zp_ad_phase
ar_vram_loop:
        lda     $180A
        ldx     zp_ad_phase
        bne     ar_vram_hi
        sta     a:VDC_DLO
        inc     zp_ad_phase
        bra     ar_vram_dec
ar_vram_hi:
        sta     a:VDC_DHI
        stz     zp_ad_phase
ar_vram_dec:
        jsr     ad_dec_cnt
        bcs     ar_vram_fin
        jmp     ar_vram_loop    ; (trampoline: out of range
                                ; since the ZP work area move)
ar_vram_fin:
        lda     #$00
        sta     WV_VDTIN_FLG
        jmp     ar_done_sec

; -------------------------------------------------------------------
; ad_dma_start: issue READ(6) for zp_bytes bytes at zp_alba
; and arm the core's CD->ADPCM DMA ($180B). Returns with the
; data phase streaming; the status/message phases are left
; for ad_dma_finish (AD_TRANS) or for later BIOS activity
; (AD_CPLAY). Carry set + zp_err on failure (bus reset has
; been issued). The CDB encoding matches cd_stream's.
; -------------------------------------------------------------------
ad_dma_start:
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
        lda     zp_bytes+1
        lsr     a
        lsr     a
        lsr     a
        sta     zp_cdb+4
        lda     zp_bytes+2
        asl     a
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
        lda     #$01
        sta     $1801
        lda     #$00
        sta     $1800
        lda     #$80
        sta     zp_waitmask
        sta     zp_waitexpect
        jsr     wait1800
        bcc     ads_cdb
        lda     #$01
        sta     zp_err
        jmp     ads_fail
ads_cdb:
        ldx     #$00
ads_cdb_loop:
        lda     #$78
        sta     zp_waitmask
        lda     #$50
        sta     zp_waitexpect
        jsr     wait1800
        bcc     ads_cdb_send
        lda     #$02
        sta     zp_err
        jmp     ads_fail
ads_cdb_send:
        lda     zp_cdb,x
        sta     $1801
        jsr     ack_pulse
        bcc     ads_cdb_next
        lda     #$03
        sta     zp_err
        jmp     ads_fail
ads_cdb_next:
        inx
        cpx     #$06
        bne     ads_cdb_loop
        ; wait for the data-in phase to be presented, then
        ; arm the DMA: the core's DRQ/VCLK machinery delivers
        ; the bytes from here (pacing itself against any
        ; active playback) and counts them in adpcm_written.
        lda     #$78
        sta     zp_waitmask
        lda     #$48
        sta     zp_waitexpect
        jsr     wait1800
        bcc     ads_arm
        lda     #$04
        sta     zp_err
        jmp     ads_fail
ads_arm:
        lda     #$03
        sta     $180B
        clc
        rts
ads_fail:
        jsr     scsi_bus_reset
        sec
        rts

; -------------------------------------------------------------------
; ad_dma_finish: consume the status/message phases of a DMA
; stream started by ad_dma_start. The status wait is LONG
; (up to 256 wait1800 rounds): while a play is active the
; core paces DMA delivery against the play pointer, so a
; transfer can legitimately take seconds of emulated time.
; Carry set + zp_err on failure.
; -------------------------------------------------------------------
ad_dma_finish:
        ldx     #$00
adf_wait:
        lda     #$78
        sta     zp_waitmask
        lda     #$58
        sta     zp_waitexpect
        jsr     wait1800
        bcc     adf_status
        inx
        bne     adf_wait
        lda     #$05
        sta     zp_err
        bra     adf_fail
adf_status:
        lda     $1801
        sta     zp_scsi_stat
        jsr     ack_pulse
        bcc     adf_msgw
        lda     #$03
        sta     zp_err
        bra     adf_fail
adf_msgw:
        lda     #$78
        sta     zp_waitmask
        sta     zp_waitexpect
        jsr     wait1800
        bcc     adf_msg
        lda     #$06
        sta     zp_err
        bra     adf_fail
adf_msg:
        lda     $1801
        sta     zp_scsi_msg
        jsr     ack_pulse
        bcc     adf_free
        lda     #$03
        sta     zp_err
        bra     adf_fail
adf_free:
        lda     #$80            ; bus-free wait (bounded,
        sta     zp_waitmask     ; result ignored, as in
        lda     #$00            ; cd_stream)
        sta     zp_waitexpect
        jsr     wait1800
        jsr     note_status
        lda     zp_scsi_stat
        beq     adf_ok
        lda     #$F0
        sta     zp_err
        bra     adf_fail
adf_ok:
        clc
        rts
adf_fail:
        jsr     note_status
        jsr     scsi_bus_reset
        sec
        rts

; ad_dma_stream: a complete DMA transfer (AD_TRANS, IPL).
ad_dma_stream:
        jsr     ad_dma_start
        bcs     adms_done
        jmp     ad_dma_finish
adms_done:
        rts

; -------------------------------------------------------------------
; AD_TRANS (slot $11): stream AL records from the CD (record
; offset CL/CH/DL relative to recbase0) into ADPCM RAM.
;   DH = $00: the destination is BX (write address set,
;     no byte swallowed)
;   DH != $00: the destination is the current write point
;     (BX ignored; the write address is NOT set, so the
;     core's DMA byte count keeps accumulating -- measured)
; Success: A = 0, carry SET (measured). The data moves
; through the core's DMA path (ad_dma_stream), so at return
; the DMA-armed flag and the delivered-byte count match the
; genuine's -- later AD_PLAY termination depends on both.
; -------------------------------------------------------------------
ad_trans:
        lda     ARG_AL
        beq     at_policy
        jsr     shadow_offset
        jsr     abs_from_base0
        lda     ARG_AL
        jsr     set_bytes_records
        lda     ARG_DH
        bne     at_stream       ; DH != 0: keep write point
        lda     ARG_BL
        sta     $1808
        lda     ARG_BH
        sta     $1809
        lda     #$02
        sta     $180D           ; set write addr, no swallow
at_stream:
        jsr     ad_dma_stream
        bcs     at_fail
        ; The genuine rewrites (CL,CH,DL) to the absolute
        ; start LBA (recbase0 + entry offset), the same
        ; contract as CD_READ's LOCAL form -- measured
        ; layer-5 on Gate of Thunder's real call (entry
        ; $000104 -> exit $000F0A with recbase0 = 3590);
        ; a recbase-0 probe disc masks it (exit = entry).
        ; zp_alba is little-endian L,M,H and survives the
        ; stream (ad_dma_start only reads it). The shadows
        ; take CL = H, CH = M, DL = L (the entry convention
        ; of shadow_offset). Layer-6 (2026-11-24): an
        ; earlier revision stored CL/DL swapped under a
        ; "big-endian" misreading of zp_alba; the adprobe
        ; replica proves the genuine's order (entry
        ; $000104 -> exit shadows CL=$00, CH=$01, DL=$04;
        ; the swapped build returned CL=$04, DL=$00).
        lda     zp_alba+2
        sta     ARG_CL
        lda     zp_alba+1
        sta     ARG_CH
        lda     zp_alba
        sta     ARG_DL
        ldx     #$0E            ; genuine's AD_TRANS exit
        ldy     #$01            ; residues X = $0E, Y = $01
        jmp     ok_ret_sec      ; A = 0, carry set (measured
                                ; layer-5 replica, all forms)
at_policy:
        ; AL = 0: the genuine hangs in this core (measured).
        ; COMPAT3 policy: ERR_BAD_PARAM, no transfer.
        lda     #ERR_BAD_PARAM
        jsr     fail_with
        sec
        rts
at_fail:
        ; No disc / transport failure. The genuine hangs on
        ; the no-disc call in this core (measured); COMPAT3
        ; policy: ERR_NOT_READY.
        lda     #ERR_NOT_READY
        jsr     fail_with
        sec
        rts

; -------------------------------------------------------------------
; AD_CPLAY (slot $15): streaming playback from CD. Record
; offset CL/CH/DL relative to recbase0; record count is
; 24-bit (AL = low, AH = mid, BL = high); DH = rate. The
; stream is delivered into ADPCM RAM from $0000 through
; the DMA path (status/message consumed), and playback
; then runs from $0000, ending when the delivered-byte
; count is consumed: the genuine's measured end timings
; (364 frames for 32 records at rate 14, 455 for the
; buffer-wrapping 40) match this model exactly. A = 0.
; Carry: SET iff count >= 32 records (measured at 16/32/40
; records) -- exactly the overflow of the 16-bit byte count
; (count * 2048) that the play length is latched from.
; -------------------------------------------------------------------
ad_cplay:
        ; return carry from the unshifted count: set iff
        ; BL != 0 or AH != 0 or AL >= 32
        lda     ARG_BL
        ora     ARG_AH
        bne     acp_carry
        lda     ARG_AL
        cmp     #$20
        bcs     acp_carry
        stz     zp_ad_phase
        bra     acp_count
acp_carry:
        lda     #$01
        sta     zp_ad_phase
acp_count:
        ; zp_bytes = count24 * 2048 (count24 in zp_bytes
        ; first, then shifted left 11)
        lda     ARG_AL
        sta     zp_bytes
        lda     ARG_AH
        sta     zp_bytes+1
        lda     ARG_BL
        sta     zp_bytes+2
        ldx     #$0B
acp_shift:
        asl     zp_bytes
        rol     zp_bytes+1
        rol     zp_bytes+2
        dex
        bne     acp_shift
        jsr     shadow_offset
        jsr     abs_from_base0
        lda     ARG_DH
        sta     $180E
        ; Deliver the stream into ADPCM RAM in chunks of at
        ; most 32 records, each chunk with its own READ(6)
        ; and its own write-address set at the chunk's
        ; buffer offset, THEN start playback: with the
        ; delivered-byte count fully loaded, playback runs
        ; the stream's exact duration and ends as the count
        ; drains -- the genuine's measured end timings (364
        ; frames for 32 records, 455 for the buffer-wrapping
        ; 40) match this model. The chunk split mirrors the
        ; genuine's traces: after a >32-record CPLAY it
        ; leaves $88 at $227A (recbase1+3) and $00 after a
        ; <=32-record one (measured at counts 32, 33, 40 and
        ; 48, 2026-11-20), and its wrapped-region content
        ; differs from a single-stream delivery in the way
        ; a fresh second delivery explains.
        ; The genuine's $88 at $227A is NOT yet present when
        ; AD_CPLAY returns (its case-90 log shows $00) but IS
        ; present once playback has run (case 91): the store
        ; happens during playback. COMPAT3 defers it: set a
        ; flag here; the IRQ2 handler performs the store on
        ; its first entry during the stream's playback.
        lda     ARG_BL
        ora     ARG_AH
        bne     acp_wv88
        lda     ARG_AL
        cmp     #$21
        bcs     acp_wv88
        stz     zp_ad_state
        lda     #$00
        sta     WV_REC1X
        bra     acp_init
acp_wv88:
        lda     #$01
        sta     zp_ad_state
acp_init:
        ; zp_ad_rem = count24 (records)
        lda     ARG_AL
        sta     zp_ad_rem
        lda     ARG_AH
        sta     zp_ad_rem+1
        lda     ARG_BL
        sta     zp_ad_rem+2
        ; ONE write-address set for the whole stream: the
        ; core's write pointer wraps at 64 KB on its own,
        ; and re-setting the address mid-stream would reset
        ; the core's delivered-byte counter, ending playback
        ; after the last chunk alone (measured: 92 frames
        ; instead of 455 for the 40-record stream).
        lda     #$00
        sta     $1808
        sta     $1809
        lda     #$02
        sta     $180D
acp_chunk:
        ; chunkrec (zp_tmp1) = min(remaining, 32)
        lda     zp_ad_rem+2
        bne     acp_c32
        lda     zp_ad_rem+1
        bne     acp_c32
        lda     zp_ad_rem
        cmp     #$21
        bcc     acp_csmall
acp_c32:
        lda     #$20
        sta     zp_tmp1
        bra     acp_cbytes
acp_csmall:
        lda     zp_ad_rem
        sta     zp_tmp1
acp_cbytes:
        ; zp_bytes = chunkrec * 2048
        lda     zp_tmp1
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        sta     zp_bytes+2      ; chunkrec >> 5 (0 or 1)
        lda     zp_tmp1
        asl     a
        asl     a
        asl     a
        sta     zp_bytes+1      ; (chunkrec & 31) << 3
        stz     zp_bytes
        jsr     ad_dma_stream
        bcc     acp_ok1
        jmp     acp_fail
acp_ok1:
        ; LBA += chunkrec (zp_alba is little-endian
        ; L, M, H: add to +0, carry into +1, then +2.
        ; Layer-6 (2026-11-24): an earlier revision added
        ; to +2 under a "big-endian" misreading, so each
        ; chunk advanced the wire LBA by chunkrec*65536
        ; -- proven by the SCSI log: chunk LBAs went
        ; $000000, $200000, $400000, ... for 32-record
        ; chunks instead of +$20.)
        lda     zp_alba
        clc
        adc     zp_tmp1
        sta     zp_alba
        bcc     acp_adv
        inc     zp_alba+1
        bne     acp_adv
        inc     zp_alba+2
acp_adv:
        ; (No write-offset bookkeeping: the whole stream
        ; uses the single address set above; the core's
        ; write pointer wraps at 64 KB on its own.)
        ; remaining -= chunkrec (24-bit)
        sec
        lda     zp_ad_rem
        sbc     zp_tmp1
        sta     zp_ad_rem
        bcs     acp_remok
        lda     zp_ad_rem+1
        bne     acp_rem1
        dec     zp_ad_rem+2
acp_rem1:
        dec     zp_ad_rem+1
acp_remok:
        lda     zp_ad_rem
        ora     zp_ad_rem+1
        ora     zp_ad_rem+2
        beq     acp_chunks_done
        jmp     acp_chunk
acp_chunks_done:
        ; zp_bytes = total byte count again for the
        ; playback length latch below
        lda     ARG_AL
        sta     zp_bytes
        lda     ARG_AH
        sta     zp_bytes+1
        lda     ARG_BL
        sta     zp_bytes+2
        ldx     #$0B
acp_reshift:
        asl     zp_bytes
        rol     zp_bytes+1
        rol     zp_bytes+2
        dex
        bne     acp_reshift
        ; start playback from $0000, length = bytes16
        lda     #$00
        sta     zp_ad_start
        sta     zp_ad_start+1
        sta     $1808
        sta     $1809
        lda     #$08
        sta     $180D           ; set read address
        lda     zp_bytes
        sta     zp_ad_len
        sta     $1808
        lda     zp_bytes+1
        sta     zp_ad_len+1
        sta     $1809
        lda     #$10
        sta     $180D           ; set length
        stz     zp_ad_rpt
        lda     #$01
        sta     zp_ad_cp
        lda     #$40
        sta     $180D           ; play
        lda     #$08            ; unmask the full-play IRQ
        sta     $1802           ; (see ad_play)
        sta     zp_imask
        sta     zp_imask
        lda     zp_ad_phase
        beq     acp_clc
        sec
        jmp     ok_ret
acp_clc:
        clc
        jmp     ok_ret
acp_fail:
        ; No disc / transport failure: the genuine hangs on
        ; the no-disc call in this core (measured); COMPAT3
        ; policy: ERR_NOT_READY.
        lda     #ERR_NOT_READY
        jsr     fail_with
        clc
        rts

; -------------------------------------------------------------------
; ipl_adp_opening: the IPL OPENMODE ADP opening (Hu7 IPL
; description; bit semantics measured on the genuine in
; this core, 2026-11-20): if OPENMODE bit1 ($02) is set and
; ADPBLN > 0, stream ADPBLN records from (data track start
; + ADPBLK) into ADPCM RAM at $0000; then, unless bit6
; ($40, load-only) is set, start playback at ADPRATE with
; bit7 ($80) as the repeat flag. Called from ipl.s after
; the recbase work variables are set, before the program
; load (the manual's opening order). A failed stream just
; skips the opening; the boot continues.
; Header fields (work RAM $3000): OPENMODE $300D, GRP*
; $300E-$3013 (graphics opening: p005), ADPBLK $3014-$3016
; (big-endian), ADPBLN $3017, ADPRATE $3018.
; -------------------------------------------------------------------
ipl_adp_opening:
        lda     $300D
        and     #$02
        beq     iao_done
        lda     $3017
        beq     iao_done
        lda     zp_data_lba
        clc
        adc     $3016
        sta     zp_alba
        lda     zp_data_lba+1
        adc     $3015
        sta     zp_alba+1
        lda     zp_data_lba+2
        adc     $3014
        sta     zp_alba+2
        lda     $3017
        jsr     set_bytes_records
        lda     #$00
        sta     $1808
        sta     $1809
        lda     #$02
        sta     $180D           ; write address 0, no swallow
        jsr     ad_dma_stream
        bcs     iao_done
        lda     $300D
        and     #$40
        bne     iao_done        ; load-only
        lda     $3018           ; ADPRATE
        sta     zp_ad_rate
        sta     $180E
        lda     #$00
        sta     zp_ad_start
        sta     zp_ad_start+1
        ; length = ADPBLN * 2048 (16-bit, as latched)
        lda     $3017
        asl     a
        asl     a
        asl     a
        sta     zp_ad_len+1
        lda     #$00
        sta     zp_ad_len
        stz     zp_ad_state
        stz     zp_ad_cp
        lda     $300D
        and     #$80
        beq     iao_norpt
        lda     #$01
        sta     zp_ad_rpt
        bra     iao_kick
iao_norpt:
        stz     zp_ad_rpt
iao_kick:
        jsr     ad_play_kick
        lda     #$08            ; unmask the full-play IRQ
        sta     $1802           ; (see ad_play)
        sta     zp_imask
        sta     zp_imask
iao_done:
        rts
