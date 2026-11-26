; COMPAT3 -- BIOS CD player function set (ws005 p005):
;   $06 CD_PLAY   $07 CD_SEARCH   $08 CD_PAUSE
;   $0D CD_SUBRQ  $0E CD_PCMRD
; Clean-room: semantics from the public Hu7 manual / zeograd
; document and from black-box differential observation of the
; genuine card in this core (2026-11-20, see PROGRESS.md ws005
; p005). No NEC/Hudson code or data.
;
; Drive model (measured): CD_PLAY issues NEC $D8 (Set Audio
; Playback Start Position) followed by $D9 (Set Audio Playback
; End Position), both with CDB byte 1 = the play mode (DH low
; bits). CD_SEARCH issues $D8 alone with byte 1 = mode & 2.
; CD_PAUSE issues $DA. The core's own mode arithmetic produces
; the observed state machine: modes 0 and 4 end CDDA_OFF via
; $D9, mode 1 repeats, mode 2 interrupts, mode 3 plays through.
;
; Start address forms (BH bits 7-6):
;   $00 LBA: the genuine's conversion is observable only as the
;     CDB value (0, REC-H, REC-M) -- REC-L is dropped, i.e. the
;     $D8 LBA value is REC >> 8. When that value is 0 the $D8
;     is not issued at all (playback continues from the current
;     position; an all-zero address would be the core's stop
;     pattern, which the genuine demonstrably does not send).
;   $40 MSF: CDB bytes 2-4 = (AL, AH, BL) BCD, byte 9 = $40.
;   $80 TNO: CDB byte 2 = AL (BCD track), byte 9 = $80.
;   $C0 CURRENT: no $D8 (playback position unchanged).
; End address forms (DH bits 7-6) go to the $D9 with the DH
; address shadows (CL, CH, DL) at CDB bytes 2-4 and byte 9 =
; the end type; the core reads LBA ends from bytes 3-5, which
; reproduces the genuine's effective end positions.
;
; On success these functions return A = 0 with carry SET
; (measured; ok_ret_sec). A successful CD_PLAY also records
; the play-end position in $226F-$2271 as the BCD MSF of
; (lead-out frame - 1) (measured in every observed case).
; Where the genuine card does not return in this core (no
; disc), COMPAT3 returns ERR_NOT_READY immediately -- the
; recorded p005 policy, following the p003/p004 precedent.

zp_pl_mode      = $24E0         ; saved play/search mode bits.
                                ; Were ZP $07-$09 until the C-D1
                                ; relocation (layer 10 /
                                ; spec_drac.md): call state left
                                ; standing in the caller's low
                                ; zero page at return. Now WRAM
                                ; beside the shared scratch block.
zp_pl_want      = $24E1         ; CD_PCMRD wanted channel mask
zp_pl_err       = $24E2         ; d8_start transport error flag

        .segment "CODE"

; -------------------------------------------------------------------
; d8_start: build and issue the $D8 for the start address in
; the argument shadows. zp_pl_mode = CDB byte 1. Forms that
; need no $D8 (CURRENT, LBA with a zero >>8 value) skip the
; command entirely. zp_pl_err is set on transport/status
; error; callers check it and bail to their fail path.
; -------------------------------------------------------------------
d8_start:
        lda     #$00
        sta     zp_pl_err
        lda     ARG_BH
        and     #$C0
        cmp     #$40
        beq     d8s_msf
        cmp     #$80
        beq     d8s_tno
        cmp     #$C0
        bne     d8s_lba
        jmp     d8s_skip        ; CURRENT: no $D8
d8s_lba:
        ; LBA form: value = REC >> 8 -> CDB (0, AL, AH);
        ; skip when zero (would be the stop pattern).
        lda     ARG_AL
        ora     ARG_AH
        bne     d8s_have
        jmp     d8s_skip        ; (trampoline: out of range
                                ; since the ZP work area move)
d8s_have:
        lda     #$D8
        sta     zp_cdb
        lda     zp_pl_mode
        sta     zp_cdb+1
        lda     #$00
        sta     zp_cdb+2
        lda     ARG_AL
        sta     zp_cdb+3
        lda     ARG_AH
        sta     zp_cdb+4
        lda     #$00
        sta     zp_cdb+9
        bra     d8s_issue
d8s_msf:
        lda     #$D8
        sta     zp_cdb
        lda     zp_pl_mode
        sta     zp_cdb+1
        lda     ARG_AL
        sta     zp_cdb+2
        lda     ARG_AH
        sta     zp_cdb+3
        lda     ARG_BL
        sta     zp_cdb+4
        lda     #$40
        sta     zp_cdb+9
        bra     d8s_issue
d8s_tno:
        lda     #$D8
        sta     zp_cdb
        lda     zp_pl_mode
        sta     zp_cdb+1
        lda     ARG_AL
        sta     zp_cdb+2
        lda     #$00
        sta     zp_cdb+3
        sta     zp_cdb+4
        lda     #$80
        sta     zp_cdb+9
d8s_issue:
        lda     #$00
        sta     zp_cdb+5
        sta     zp_cdb+6
        sta     zp_cdb+7
        sta     zp_cdb+8
        sta     zp_datalen
        jsr     scsi_cmd
        jsr     note_status
        bcs     d8s_err
        lda     zp_scsi_stat
        bne     d8s_err
        sec
        rts
d8s_err:
        lda     #$01
        sta     zp_pl_err
        clc
        rts
d8s_skip:
        clc
        rts

; -------------------------------------------------------------------
; CD_PLAY ($06).
; -------------------------------------------------------------------
cd_play:
        stx     WV_PRIV_SX      ; entry X/Y for the residue
        sty     WV_PRIV_SY      ; rules at the success exit
        lda     ARG_DH
        and     #$07
        sta     zp_pl_mode
        jsr     d8_start
        lda     zp_pl_err
        beq     cpl_d9
        jmp     cpl_fail
cpl_d9:
        ; $D9: end position + mode
        lda     #$D9
        sta     zp_cdb
        lda     zp_pl_mode
        sta     zp_cdb+1
        lda     ARG_CL
        sta     zp_cdb+2
        lda     ARG_CH
        sta     zp_cdb+3
        lda     ARG_DL
        sta     zp_cdb+4
        lda     #$00
        sta     zp_cdb+5
        sta     zp_cdb+6
        sta     zp_cdb+7
        sta     zp_cdb+8
        sta     zp_datalen
        lda     ARG_DH
        and     #$C0
        sta     zp_cdb+9
        jsr     scsi_cmd
        jsr     note_status
        bcs     cpl_fail
        lda     zp_scsi_stat
        bne     cpl_fail
        jsr     play_note_end
        ; $227A and the X/Y residues, re-measured in the
        ; layer-3 round (2026-11-23; layer3/3b/3c probes
        ; + the p005 player log):
        ;   modes 1/2: $227A = $98, plus $40 when the end
        ;     form (DH bits 7-6) is CURRENT ($C0) -> $D8;
        ;     X = $0A.
        ;   modes 0/3/4: $227A = $00 (a mode-0 play right
        ;     after a mode-1 play clears the $D8 -- it is
        ;     written, not left); X = entry X.
        ;   Y (all modes): start form CURRENT -> entry Y;
        ;     start form LBA, or an end address specified
        ;     (end form != CURRENT) -> $03; else $02.
        ; The flag otherwise stays until CD_SUBQ /
        ; CD_PAUSE / a successful CD_READ clears it.
        lda     zp_pl_mode
        cmp     #$01
        beq     cpl_m12
        cmp     #$02
        beq     cpl_m12
        lda     #$00
        sta     WV_REC1X
        ldx     WV_PRIV_SX
        bra     cpl_y
cpl_m12:
        lda     ARG_DH
        and     #$C0
        cmp     #$C0
        beq     cpl_fd8
        lda     #$98
        bra     cpl_fst
cpl_fd8:
        lda     #$D8
cpl_fst:
        sta     WV_REC1X
        ldx     #$0A
cpl_y:
        lda     ARG_BH
        and     #$C0
        cmp     #$C0
        beq     cpl_ycurr       ; CURRENT start: Y = entry
        cmp     #$00
        beq     cpl_y3          ; LBA start: Y = 3
        lda     ARG_DH
        and     #$C0
        cmp     #$C0
        bne     cpl_y3          ; end specified: Y = 3
        ldy     #$02
        bra     cpl_done
cpl_y3:
        ldy     #$03
        bra     cpl_done
cpl_ycurr:
        ldy     WV_PRIV_SY
cpl_done:
        jmp     ok_ret_sec
cpl_fail:
        lda     #ERR_NOT_READY
        jmp     fail_with

; play_note_end: $226F-$2271 <- BCD MSF of (lead-out frame - 1),
; from the WV_OUT* BCD triple. Skipped when the TOC lead-out
; was never loaded (all zero).
play_note_end:
        lda     WV_OUTMIN
        ora     WV_OUTSEC
        ora     WV_OUTFRM
        bne     pne_have
        jmp     pne_done        ; (trampoline: out of range
                                ; since the ZP work area move)
pne_have:
        lda     WV_OUTMIN
        jsr     from_bcd
        sta     zp_msf
        lda     WV_OUTSEC
        jsr     from_bcd
        sta     zp_msf+1
        lda     WV_OUTFRM
        jsr     from_bcd
        sta     zp_msf+2
        ; zp_acc = F + S*75 + M*4500 (24-bit), then -1
        lda     zp_msf+2
        sta     zp_acc
        lda     #$00
        sta     zp_acc+1
        sta     zp_acc+2
        ldx     zp_msf+1        ; seconds
        beq     pne_m
pne_s:  lda     zp_acc
        clc
        adc     #$4B            ; +75
        sta     zp_acc
        bcc     pne_s2
        inc     zp_acc+1
        bne     pne_s2
        inc     zp_acc+2
pne_s2: dex
        bne     pne_s
pne_m:  ldx     zp_msf          ; minutes
        beq     pne_sub
pne_ml: lda     zp_acc
        clc
        adc     #$94            ; +4500 = $1194
        sta     zp_acc
        lda     zp_acc+1
        adc     #$11
        sta     zp_acc+1
        bcc     pne_m2
        inc     zp_acc+2
pne_m2: dex
        bne     pne_ml
pne_sub:
        lda     zp_acc
        sec
        sbc     #$01
        sta     zp_acc
        bcs     pne_conv
        lda     zp_acc+1
        sec
        sbc     #$01
        sta     zp_acc+1
        bcs     pne_conv
        dec     zp_acc+2
pne_conv:
        jsr     frames_to_bcdmsf
        lda     zp_dirbuf
        sta     WV_PLAYEND_M
        lda     zp_dirbuf+1
        sta     WV_PLAYEND_S
        lda     zp_dirbuf+2
        sta     WV_PLAYEND_F
pne_done:
        rts

; -------------------------------------------------------------------
; CD_SEARCH ($07): $D8 only; CDB byte 1 = mode & 2 (bit 1 =
; play at target, bit 0 = the wait/async distinction, which
; has no separate CDB expression in this core).
; -------------------------------------------------------------------
cd_search:
        stx     WV_PRIV_SX      ; entry X/Y (residue rules,
        sty     WV_PRIV_SY      ; same as CD_PLAY: layer3)
        lda     ARG_BH
        and     #$02
        sta     zp_pl_mode
        jsr     d8_start
        lda     zp_pl_err
        bne     cse_fail
        ; odd search modes (BH bit 0) set the $227A flag to
        ; $98 and return X = $0A; even modes preserve the
        ; entry X (p005 player log, 2026-11-20; layer-3
        ; round confirmed the shape). The next CD_SUBQ
        ; clears the flag. Y follows the start-form rule:
        ; CURRENT -> entry Y, LBA -> $03, TNO/MSF -> $02.
        lda     ARG_BH
        and     #$01
        beq     cse_even
        lda     #$98
        sta     WV_REC1X
        ldx     #$0A
        bra     cse_y
cse_even:
        ldx     WV_PRIV_SX
cse_y:
        lda     ARG_BH
        and     #$C0
        cmp     #$C0
        beq     cse_ycurr
        cmp     #$00
        beq     cse_y3
        ldy     #$02
        bra     cse_done
cse_y3:
        ldy     #$03
        bra     cse_done
cse_ycurr:
        ldy     WV_PRIV_SY
cse_done:
        jmp     ok_ret_sec
cse_fail:
        lda     #ERR_NOT_READY
        jmp     fail_with

; -------------------------------------------------------------------
; CD_PAUSE ($08): NEC $DA.
; -------------------------------------------------------------------
cd_pause:
        lda     #$DA
        sta     zp_cdb
        lda     #$00
        ldx     #$09
cpa_clear:
        sta     zp_cdb+1,x
        dex
        bpl     cpa_clear
        sta     zp_datalen
        jsr     scsi_cmd
        jsr     note_status
        bcs     cpa_fail
        lda     zp_scsi_stat
        bne     cpa_fail
        stz     WV_REC1X        ; a successful pause ends
                                ; the flagged play (genuine:
                                ; $227A $D8 -> $00, layer3b)
        jmp     ok_ret_sec
cpa_fail:
        lda     #ERR_NOT_READY
        jmp     fail_with

; -------------------------------------------------------------------
; CD_SUBRQ ($0D): if the $1803 subchannel flag (bit 4) is set,
; return the next FIFO byte in A with carry CLEAR; otherwise
; return with carry SET and A preserved (both measured).
; -------------------------------------------------------------------
cd_subrq:
        pha
        lda     a:$1803
        and     #$10
        beq     csrq_empty
        pla
        lda     a:$1807
        sta     WV_SUBCODE      ; genuine stores the byte at
                                ; $227E (p005: after a burst,
                                ; $227E = the last byte read)
        clc
        rts
csrq_empty:
        pla
        sec
        rts

; -------------------------------------------------------------------
; CD_PCMRD ($0E): A-in selects the channel (0 = R, 1 = L);
; returns X = sample low byte, Y = sample high byte, A = 0,
; carry clear (measured). The $1803 read returns the channel
; selection as it was BEFORE the read in bit 1 and then flips
; the selection (core cdrom_read), so: read $1803, and if the
; now-selected channel is not the wanted one, read $1803 once
; more to flip back; then read $1805/$1806.
; -------------------------------------------------------------------
cd_pcmrd:
        ldx     #$00
        cmp     #$00
        beq     cpcm_r
        ldx     #$02
cpcm_r:
        stx     zp_pl_want
        lda     a:$1803
        and     #$02
        eor     #$02            ; now-selected channel mask
        cmp     zp_pl_want
        beq     cpcm_read
        lda     a:$1803         ; flip back to the wanted channel
cpcm_read:
        ldx     a:$1805
        ldy     a:$1806
        lda     #$00
        clc
        rts
