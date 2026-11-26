; COMPAT3 bank 0 -- jump table, reset/boot shell, BIOS entries.
; Clean-room implementation written from public documentation
; (zeograd BIOS document; Hudson Hu7 CD System BIOS Manual) and
; black-box observation. No NEC/Hudson code or data.
;
; Bank 0 is mapped at logical $E000-$FFFF (MPR7 = $00) and holds:
;   $E000  jump table, 81 slots x 3 bytes (jmp instruction each)
;   ...    boot code and BIOS function implementations
;   $FFF6  interrupt / reset vectors
        .setcpu "HuC6280"
        .include "hw.inc"

; The player UI (player.s) is a separate object in bank 1;
; it calls these bank-0 helpers, and bank 0 calls its two
; entry points through the MPR6-window glue below.
        .import player_enter, player_tick, gfx_drain_some
        .import bmb_format, bmb_free, bmb_read
        .import exb_dispatch, exb_colorc_go
        .import bmb_write, bmb_delete, bmb_files
        .import fnb_getfnt
        .import psgb_irq_tick
        .export vdc_write, vdc_set_mawr, bat_clear, set_cursor
        .export putch, print_str, print_dec
        .export disc_check, show_title, scsi_cmd
        .export to_bcd, from_bcd
        .export usrvec_default

; ===================================================================
; Jump table at $E000. Slot n is called as JSR $E000 + 3*n with
; MPR7 = $00, MPR0 = $FF (I/O), MPR1 = $F8 (work RAM); arguments in
; the zero-page shadows $20F8-$20FF (al..dh). As of item 4 all
; 81 slots are implemented. Implemented in p001:
;   $1E EX_GETVER   $22 EX_JOYREP (documented no-op)
; ===================================================================
        .segment "JUMPTAB"
        .repeat 81, slot
        .if slot = $00
        jmp     cd_boot
        .elseif slot = $01
        jmp     cd_reset
        .elseif slot = $02
        jmp     cd_base
        .elseif slot = $03
        jmp     cd_read
        .elseif slot = $04
        jmp     cd_seek
        .elseif slot = $05
        jmp     cd_exec
        .elseif slot = $06
        jmp     cd_play
        .elseif slot = $07
        jmp     cd_search
        .elseif slot = $08
        jmp     cd_pause
        .elseif slot = $09
        jmp     cd_stat
        .elseif slot = $0A
        jmp     cd_subq
        .elseif slot = $0B
        jmp     cd_dinfo
        .elseif slot = $0C
        jmp     cd_contnts
        .elseif slot = $0D
        jmp     cd_subrq
        .elseif slot = $0E
        jmp     cd_pcmrd
        .elseif slot = $0F
        jmp     cd_fade
        .elseif slot = $10
        jmp     ad_reset
        .elseif slot = $11
        jmp     ad_trans
        .elseif slot = $12
        jmp     ad_read
        .elseif slot = $13
        jmp     ad_write
        .elseif slot = $14
        jmp     ad_play
        .elseif slot = $15
        jmp     ad_cplay
        .elseif slot = $16
        jmp     ad_stop
        .elseif slot = $17
        jmp     ad_stat
        .elseif slot = $18
        jmp     bm_format
        .elseif slot = $19
        jmp     bm_free
        .elseif slot = $1A
        jmp     bm_read
        .elseif slot = $1B
        jmp     bm_write
        .elseif slot = $1C
        jmp     bm_delete
        .elseif slot = $1D
        jmp     bm_files
        .elseif slot = $1E
        jmp     ex_getver
        .elseif slot = $20
        jmp     ex_getfnt
        .elseif slot = $22
        jmp     ex_joyrep
        .elseif slot = $1F
        jmp     exs_setvec
        .elseif slot = $21
        jmp     exs_joysns
        .elseif slot = $23
        jmp     exs_scrsiz
        .elseif slot = $24
        jmp     exs_dotmod
        .elseif slot = $25
        jmp     exs_scrmod
        .elseif slot = $26
        jmp     exs_imode
        .elseif slot = $27
        jmp     exs_vmode
        .elseif slot = $28
        jmp     exs_hmode
        .elseif slot = $29
        jmp     exs_vsync
        .elseif slot = $2A
        jmp     exs_rcron
        .elseif slot = $2B
        jmp     exs_rcroff
        .elseif slot = $2C
        jmp     exs_irqon
        .elseif slot = $2D
        jmp     exs_irqoff
        .elseif slot = $2E
        jmp     exs_bgon
        .elseif slot = $2F
        jmp     exs_bgoff
        .elseif slot = $30
        jmp     exs_spron
        .elseif slot = $31
        jmp     exs_sproff
        .elseif slot = $32
        jmp     exs_dspon
        .elseif slot = $33
        jmp     exs_dspoff
        .elseif slot = $34
        jmp     exs_dmamod
        .elseif slot = $35
        jmp     exs_sprdma
        .elseif slot = $36
        jmp     exs_satclr
        .elseif slot = $37
        jmp     exs_sprput
        .elseif slot = $38
        jmp     exs_setrcr
        .elseif slot = $39
        jmp     exs_setred
        .elseif slot = $3A
        jmp     exs_setwrt
        .elseif slot = $3B
        jmp     exs_setdma
        .elseif slot = $3C
        jmp     exs_binbcd
        .elseif slot = $3D
        jmp     exs_bcdbin
        .elseif slot = $3E
        jmp     exs_rnd
        .elseif slot = $3F
        jmp     exs_mul8u
        .elseif slot = $40
        jmp     exs_mul8s
        .elseif slot = $41
        jmp     exs_mul16u
        .elseif slot = $42
        jmp     exs_div16s
        .elseif slot = $43
        jmp     exs_div16u
        .elseif slot = $44
        jmp     exs_sqrt
        .elseif slot = $45
        jmp     exs_sin
        .elseif slot = $46
        jmp     exs_cos
        .elseif slot = $47
        jmp     exs_atni
        .elseif slot = $48
        jmp     exs_psgbios
        .elseif slot = $49
        jmp     exs_grpbios
        .elseif slot = $4A
        jmp     exs_keybios
        .elseif slot = $4B
        jmp     exs_psgdrive
        .elseif slot = $4C
        jmp     exs_colorc
        .elseif slot = $4D
        jmp     exs_stream_start
        .elseif slot = $4E
        jmp     exs_stream_poll
        .elseif slot = $4F
        jmp     exs_mul16s
        .elseif slot = $50
        jmp     exs_cbasis
        .else
        jmp     ex_joyrep       ; defensive default: as of item 4
        .endif                  ; all 81 slots are routed above,
        .endrepeat              ; so this is never emitted

        .segment "CODE"

; ===================================================================
; EX_GETVER ($1E): report the BIOS version in X (major) and
; Y (minor). COMPAT3 implements the System Card 3.0 interface,
; so it reports 3.0 -- the semantics a 3.0 card exposes, per the
; public manual.
; ===================================================================
ex_getver:
        ldx     #$03
        ldy     #$00
        clc
        rts

; ===================================================================
; EX_JOYREP ($22): documented as an immediate return (the joypad
; auto-repeat control is a no-op stub in the public interface).
; ===================================================================
ex_joyrep:
        rts

; ===================================================================
; Reset / boot:
;   - CPU + MPR setup (I/O page, work RAM, this bank at $E000)
;   - mask all IRQs
;   - clear work RAM (the core does not clear RAM for us)
;   - clear the whole CD RAM window $68-$87 (the core never clears
;     cdrom_ram on reset; COMPAT3 initializes it so later phases
;     start from a known state)
;   - capture the core-synthesized CD ID bytes ($18C1/$18C2/$18C7)
;     into the diagnostic mailbox: they only read as AA 55 .. 03
;     when the core has recognized this image as a System Card
;     (support_cdrom), which is the p000 recognition evidence
;   - boot self-test: call EX_GETVER through the jump table and
;     publish X/Y to the mailbox
;   - bring up video and the title screen, then run the shell loop
; ===================================================================
reset:
        sei
        cld
        csh                     ; high-speed mode
        lda     #$FF
        tam     #$01            ; MPR0 = $FF (I/O page)
        lda     #$F8
        tam     #$02            ; MPR1 = $F8 (work RAM)
        lda     #$00
        tam     #$80            ; MPR7 = $00 (this bank)
        ldx     #$FF
        txs
        lda     #$06            ; IRQ1 + timer masked, IRQ2
        sta     IRQ_MASK        ; live: the BIOS IRQ2 handler
        sta     IRQ_ACK         ; (ADPCM half/full, CD) must be
                                ; able to run in the IPL-booted
                                ; program's environment, as on
                                ; the genuine card
        ; clear work RAM $2000-$3FFF (zero first byte, then let a
        ; forward TII propagate it)
        stz     $2000
        tii     $2000, $2001, 8191
        ; clear CD RAM banks $68-$87 through the MPR2 window
        lda     #BANK_CD_RAM_LO
        sta     zp_bank
cdram_loop:
        lda     zp_bank
        tam     #$04            ; MPR2 = current CD RAM bank
        stz     $4000
        tii     $4000, $4001, 8191
        inc     zp_bank
        lda     zp_bank
        cmp     #BANK_CD_RAM_HI + 1
        bne     cdram_loop
        ; EX BIOS work state: the genuine's boot values,
        ; measured black-box (p009). The rest of the EX work
        ; area is zero from the RAM clear above, as observed.
        lda     #$88
        sta     EX_CRLM
        lda     #$02
        sta     EX_REGBOX
        lda     #$1F
        sta     EX_JOYENA
        lda     #$B8
        sta     EX_RNDSEED
        ; usrvec boot defaults (vectest snapshot on the
        ; genuine, 2026-11-22): slots 0-5 point at an RTI
        ; stub (genuine: $E8E2), slots 6-8 stay $0000 from
        ; the RAM clear above.
        ldx     #$0A
usrvec_init:
        lda     #<usrvec_default
        sta     EX_USRVEC,x
        lda     #>usrvec_default
        sta     EX_USRVEC+1,x
        dex
        dex
        bpl     usrvec_init
        ; usrvec boot defaults (vectest snapshot on the
        ; genuine, 2026-11-22): slots 0-5 point at an RTI
        ; stub (genuine: $E8E2), slots 6-8 stay $0000 from
        ; the RAM clear above.
        ; capture the CD ID bytes (support_cdrom evidence)
        lda     CD_ID1
        sta     MB_ID0
        lda     CD_ID2
        sta     MB_ID1
        lda     CD_IDVER
        sta     MB_ID2
        ; publish boot magic / state
        lda     #$A5
        sta     MB_MAGIC
        lda     #STATE_BOOT
        sta     MB_STATE
        ; boot self-test: EX_GETVER via the jump table
        jsr     BIOS_GETVER
        stx     MB_GETVER_X
        sty     MB_GETVER_Y
        ; video + title screen
        jsr     video_init
        jsr     show_title
        stz     zp_pad_prev
        stz     zp_pad_cur
        jmp     main_loop

; ===================================================================
; Shell main loop: once per vblank, read the pad; a RUN press
; (edge) toggles between the title screen and the player screen.
; ===================================================================
main_loop:
        ; In GRAPHICS (CD+G) mode the subcode FIFO must be
        ; drained near-continuously: it holds 16 bytes
        ; while playback produces ~122 per frame, so the
        ; vblank spin below would silently drop most of
        ; the stream (measured: sync spacing 62/88
        ; instead of 98, ~1/3 of all bytes lost).  Drain
        ; a chunk per spin iteration instead.
        lda     MB_STATE
        cmp     #STATE_PLAYER_NODISC
        bcc     ml_spin
        cmp     #STATE_BOOT_ERROR
        bcs     ml_spin
        lda     PL_GFX
        beq     ml_spin
        jsr     gfx_drain_glue
ml_spin:
        lda     a:VDC_SEL       ; poll VDC status for vblank
        and     #VDC_STATUS_VD
        beq     main_loop
        jsr     read_pad
        lda     zp_pad_prev
        eor     #$FF
        and     zp_pad_cur      ; A = newly pressed buttons
        sta     zp_tmp0
        lda     zp_pad_cur
        sta     zp_pad_prev
        ; player states: hand the frame to the player tick
        ; (it handles RUN-to-title itself)
        lda     MB_STATE
        cmp     #STATE_PLAYER_NODISC
        bcc     ml_notplayer
        cmp     #STATE_BOOT_ERROR
        bcs     ml_notplayer
        jsr     player_tick_glue
        bra     main_loop
ml_notplayer:
        lda     zp_tmp0
        and     #$08            ; RUN button bit
        beq     main_loop
        lda     MB_STATE
        cmp     #STATE_TITLE
        beq     ml_player
        cmp     #STATE_PLAYER_NODISC
        bcc     main_loop
        cmp     #STATE_BOOT_ERROR + 1
        bcs     main_loop
        jsr     show_title
        bra     main_loop
ml_player:
        ; RUN at the title: a data disc takes the IPL boot path
        ; (which jumps away on success and returns only with the
        ; boot-error screen drawn); anything else opens the
        ; player screen.
        lda     zp_disc
        cmp     #DISC_DATA
        bne     ml_player_screen
        jsr     ipl_boot
        bra     main_loop
ml_player_screen:
        jsr     show_player
        bra     main_loop

; ===================================================================
; Title screen (COMPAT3's own layout and wording).
; ===================================================================
show_title:
        lda     #STATE_CHECK
        sta     MB_STATE
        jsr     disc_check
        jsr     bat_clear
        ; "COMPAT3" -- row 4, col 12, palette 1
        lda     #$04
        ldx     #$0C
        jsr     set_cursor
        lda     #$01
        sta     zp_pal
        lda     #<str_title
        sta     zp_ptr
        lda     #>str_title
        sta     zp_ptr+1
        jsr     print_str
        ; "CLEAN-ROOM CD-ROM SYSTEM" -- row 6, col 4, palette 0
        lda     #$06
        ldx     #$04
        jsr     set_cursor
        stz     zp_pal
        lda     #<str_subtitle
        sta     zp_ptr
        lda     #>str_subtitle
        sta     zp_ptr+1
        jsr     print_str
        ; "BIOS VER x.y" from the GETVER self-test -- row 8
        lda     #$08
        ldx     #$0A
        jsr     set_cursor
        lda     #<str_ver
        sta     zp_ptr
        lda     #>str_ver
        sta     zp_ptr+1
        jsr     print_str
        lda     MB_GETVER_X
        ora     #$30
        jsr     putch
        lda     #$2E            ; '.'
        jsr     putch
        lda     MB_GETVER_Y
        ora     #$30
        jsr     putch
        ; "PRESS RUN BUTTON" -- row 12, col 8, palette 2
        lda     #$0C
        ldx     #$08
        jsr     set_cursor
        lda     #$02
        sta     zp_pal
        lda     #<str_pressrun
        sta     zp_ptr
        lda     #>str_pressrun
        sta     zp_ptr+1
        jsr     print_str
        ; disc status line -- row 16, col 2, palette 0
        lda     #$10
        ldx     #$02
        jsr     set_cursor
        stz     zp_pal
        lda     #<str_disc
        sta     zp_ptr
        lda     #>str_disc
        sta     zp_ptr+1
        jsr     print_str
        lda     zp_disc
        beq     st_none
        cmp     #DISC_AUDIO
        beq     st_audio
        lda     #<str_data
        sta     zp_ptr
        lda     #>str_data
        sta     zp_ptr+1
        jsr     print_str
        bra     st_tracks
st_audio:
        lda     #<str_audio
        sta     zp_ptr
        lda     #>str_audio
        sta     zp_ptr+1
        jsr     print_str
        bra     st_tracks
st_none:
        lda     #<str_none
        sta     zp_ptr
        lda     #>str_none
        sta     zp_ptr+1
        jsr     print_str
        bra     st_state
st_tracks:
        lda     #<str_dash
        sta     zp_ptr
        lda     #>str_dash
        sta     zp_ptr+1
        jsr     print_str
        lda     zp_tracks
        jsr     print_dec
        lda     #<str_tracks
        sta     zp_ptr
        lda     #>str_tracks
        sta     zp_ptr+1
        jsr     print_str
st_state:
        ; footer -- row 20, col 3
        lda     #$14
        ldx     #$03
        jsr     set_cursor
        lda     #<str_footer
        sta     zp_ptr
        lda     #>str_footer
        sta     zp_ptr+1
        jsr     print_str
        lda     #STATE_TITLE
        sta     MB_STATE
        rts

; ===================================================================
; Player screen (p005): the implementation lives in bank 1
; (player.s, segment PLAYER) and runs through the MPR6
; window at $C000 -- bank 0 is full. The B-class BIOS calls
; the player makes all preserve MPR6 (proven by the p003 /
; p005 differentials, which gate caller MPRs), so the code
; can live in the window safely. These two glue stubs save
; and restore the caller's MPR6 around the window call.
; ===================================================================
show_player:
        tma     #$40
        pha
        lda     #$01
        tam     #$40
        jsr     player_enter
        pla
        tam     #$40
        rts

player_tick_glue:
        tma     #$40
        pha
        lda     #$01
        tam     #$40
        jsr     player_tick
        pla
        tam     #$40
        rts

gfx_drain_glue:
        tma     #$40
        pha
        lda     #$01
        tam     #$40
        jsr     gfx_drain_some
        pla
        tam     #$40
        rts

; ===================================================================
; BM BIOS (p006): the implementation lives in bank 2 (bmbios.s,
; segment BMCODE), linked at $C000 and run through the MPR6
; window like the player. The result A and carry come back
; through BM_RES / BM_CARRYF because PLA would destroy A.
; ===================================================================
; bm_tail: shared BM trampoline exit (result A in
; BM_RES, carry bit0 in BM_CARRYF -- work RAM since
; item 3.5; the lsr moves the carry bit into C).
bm_tail:
        lda     BM_CARRYF
        lsr     a
        lda     BM_RES
        rts

bm_format:
        tma     #$40
        pha
        lda     #$02
        tam     #$40
        jsr     bmb_format
        pla
        tam     #$40
        jmp     bm_tail

bm_free:
        tma     #$40
        pha
        lda     #$02
        tam     #$40
        jsr     bmb_free
        pla
        tam     #$40
        jmp     bm_tail

bm_read:
        tma     #$40
        pha
        lda     #$02
        tam     #$40
        jsr     bmb_read
        pla
        tam     #$40
        jmp     bm_tail

bm_write:
        tma     #$40
        pha
        lda     #$02
        tam     #$40
        jsr     bmb_write
        pla
        tam     #$40
        jmp     bm_tail

bm_delete:
        tma     #$40
        pha
        lda     #$02
        tam     #$40
        jsr     bmb_delete
        pla
        tam     #$40
        jmp     bm_tail

bm_files:
        tma     #$40
        pha
        lda     #$02
        tam     #$40
        jsr     bmb_files
        pla
        tam     #$40
        jmp     bm_tail

; ===================================================================
; EX_GETFNT (p007): the implementation lives in bank 2 (fnbios.s,
; segment FNCODE) and stages the 32-byte glyph cell into
; FN_STAGE. The copy to the caller's destination happens here,
; after the caller's MPR6 has been restored, so destinations in
; any window -- including $C000 itself -- land through the
; caller's own mapping. Carry is always set (measured on the
; genuine card, success and error alike); A = BM_RES.
; ===================================================================
ex_getfnt:
        tma     #$40
        pha
        lda     #$02
        tam     #$40
        jsr     fnb_getfnt
        pla
        tam     #$40
        ; C-D4: the copy pointer below is zp_dataptr,
        ; borrowed for this call and saved/restored via
        ; GF_PTR_SAV (restored at gf_done). It used to be
        ; zp_ptr ($D0/$D1) until C-D5 round 3: $D0 is
        ; inside the C-D4 census range ($80-$D7) and the
        ; per-byte reloads below showed as transient
        ; writes there once a title lived long enough to
        ; call GETFNT in its title era (the genuine's
        ; census is zero even transiently). zp_dataptr
        ; ($DC) is above the range, dead inside GETFNT
        ; (no SCSI work there), and already a wrapped
        ; borrow everywhere else (DP_SAV / BM_SAV);
        ; fnb_getfnt does not touch it (it borrows
        ; BM_EP, $E0, as ZP_PTR_FN).
        lda     zp_dataptr
        sta     GF_PTR_SAV
        lda     zp_dataptr+1
        sta     GF_PTR_SAV+1
        lda     BM_RES
        bne     gf_done         ; error: A = $01, nothing written
        ; The destination pointer is reloaded from the argument
        ; shadows on every byte: a destination in the $6000
        ; window mapped to work RAM aliases the zero page
        ; itself (logical $2000-$20FF), so the stores can
        ; overwrite zp_dataptr mid-copy -- reloading makes the
        ; transfer land exactly like the genuine card's does
        ; (measured: fntest case 27 / c27test).
        ldy     #$1F
gf_copy:
        lda     ARG_BL
        sta     zp_dataptr
        lda     ARG_BH
        sta     zp_dataptr+1
        lda     FN_STAGE,y
        sta     (zp_dataptr),y
        dey
        bpl     gf_copy
        lda     #$00
gf_done:
        ; C-D4: restore the caller's zp_dataptr saved
        ; above. pha/pla preserves the result A; its
        ; flags are exactly what pla + sec rebuild
        ; (success A=$00: Z=1; error A=$01: Z=0; carry
        ; set by sec), so the exit contract is
        ; byte-identical.
        pha
        lda     GF_PTR_SAV
        sta     zp_dataptr
        lda     GF_PTR_SAV+1
        sta     zp_dataptr+1
        pla
        sec
        rts


; ===================================================================
; EX/MA BIOS (p009): the implementation lives in bank 2
; (exbios.s, segment EXCODE) behind one shared trampoline.
; Each stub passes its slot number as an inline byte after the
; JSR; the trampoline latches A into zp_ex_a itself. It
; pops the inline-byte address, reads the slot, swaps MPR6 to
; bank 2, dispatches, and materializes A / carry / X / Y from
; BM_RES / BM_CARRYF / EX_XRES / EX_YRES (the BM precedent).
; ===================================================================
exs_setvec:
        jsr     ex_tramp_inline
        .byte   $1F
exs_joysns:
        jsr     ex_tramp_inline
        .byte   $21
exs_scrsiz:
        jsr     ex_tramp_inline
        .byte   $23
exs_dotmod:
        jsr     ex_tramp_inline
        .byte   $24
exs_scrmod:
        jsr     ex_tramp_inline
        .byte   $25
exs_imode:
        jsr     ex_tramp_inline
        .byte   $26
exs_vmode:
        jsr     ex_tramp_inline
        .byte   $27
exs_hmode:
        jsr     ex_tramp_inline
        .byte   $28
exs_vsync:
        jsr     ex_tramp_inline
        .byte   $29
exs_rcron:
        jsr     ex_tramp_inline
        .byte   $2A
exs_rcroff:
        jsr     ex_tramp_inline
        .byte   $2B
exs_irqon:
        jsr     ex_tramp_inline
        .byte   $2C
exs_irqoff:
        jsr     ex_tramp_inline
        .byte   $2D
exs_bgon:
        jsr     ex_tramp_inline
        .byte   $2E
exs_bgoff:
        jsr     ex_tramp_inline
        .byte   $2F
exs_spron:
        jsr     ex_tramp_inline
        .byte   $30
exs_sproff:
        jsr     ex_tramp_inline
        .byte   $31
exs_dspon:
        jsr     ex_tramp_inline
        .byte   $32
exs_dspoff:
        jsr     ex_tramp_inline
        .byte   $33
exs_dmamod:
        jsr     ex_tramp_inline
        .byte   $34
exs_sprdma:
        jsr     ex_tramp_inline
        .byte   $35
exs_satclr:
        jsr     ex_tramp_inline
        .byte   $36
exs_sprput:
        jsr     ex_tramp_inline
        .byte   $37
exs_setrcr:
        jsr     ex_tramp_inline
        .byte   $38
exs_setred:
        jsr     ex_tramp_inline
        .byte   $39
exs_setwrt:
        jsr     ex_tramp_inline
        .byte   $3A
exs_setdma:
        jsr     ex_tramp_inline
        .byte   $3B
exs_binbcd:
        jsr     ex_tramp_inline
        .byte   $3C
exs_bcdbin:
        jsr     ex_tramp_inline
        .byte   $3D
exs_rnd:
        jsr     ex_tramp_inline
        .byte   $3E
exs_mul8u:
        jsr     ex_tramp_inline
        .byte   $3F
exs_mul8s:
        jsr     ex_tramp_inline
        .byte   $40
exs_mul16u:
        jsr     ex_tramp_inline
        .byte   $41
exs_div16s:
        jsr     ex_tramp_inline
        .byte   $42
exs_div16u:
        jsr     ex_tramp_inline
        .byte   $43
exs_sqrt:
        jsr     ex_tramp_inline
        .byte   $44
exs_sin:
        jsr     ex_tramp_inline
        .byte   $45
exs_cos:
        jsr     ex_tramp_inline
        .byte   $46
exs_atni:
        jsr     ex_tramp_inline
        .byte   $47
exs_colorc:
        jsr     ex_tramp_inline
        .byte   $4C
exs_stream_start:
        jsr     ex_tramp_inline
        .byte   $4D
exs_stream_poll:
        jsr     ex_tramp_inline
        .byte   $4E
exs_mul16s:
        jsr     ex_tramp_inline
        .byte   $4F
exs_cbasis:
        jsr     ex_tramp_inline
        .byte   $50
exs_psgbios:
        jsr     ex_tramp_inline
        .byte   $48
exs_grpbios:
        jsr     ex_tramp_inline
        .byte   $49
exs_keybios:
        jsr     ex_tramp_inline
        .byte   $4A
exs_psgdrive:
        jsr     ex_tramp_inline
        .byte   $4B

ex_tramp_inline:
        sta     zp_ex_a         ; latch A for every EX-family call
                                ; (item 4): the A-input stubs used
                                ; to save it themselves; latching
                                ; here is identical for them (the
                                ; zp_ex_a readers are exactly the
                                ; A-input functions) and frees the
                                ; per-stub saves bank 0 needed.
        stx     zp_ex_x         ; latch the caller's X/Y FIRST:
        sty     zp_ex_y         ; the ldy #$01 below clobbers Y
                                ; (it returned $01 as the "input
                                ; Y" to every EX/MA call until
                                ; ws005 item 1, 2026-11-21)
        lda     zp_ex_ret       ; stash the caller's $DA/$DB:
        sta     zp_ex_sav       ; zp_ex_ret borrows them for the
        lda     zp_ex_ret+1     ; dispatch below, and programs
        sta     zp_ex_sav+1     ; keep live state there across
                                ; EX/MA calls (extest6's p_slot
                                ; is $D3; clobbering it sent the
                                ; next call to a garbage target --
                                ; the test_p009 desync, layer 5)
        pla
        sta     zp_ex_ret
        pla
        sta     zp_ex_ret+1
        ldy     #$01            ; the JSR pushed (inline byte
                                ; address - 1): the slot byte is
                                ; one past the pushed address
        lda     (zp_ex_ret),y
        sta     zp_ex_idx
        ; NOTE (layer 7, 2026-11-24): a p009-era inference
        ; had this trampoline write $60 to $2000 on every
        ; EX/MA call ("dispatcher marker"). z00probe proves
        ; the genuine PRESERVES program ZP $00-$02 across
        ; GETVER/SETVEC/JOYSNS/VSYNC/SETDMA/PSG_BIOS (and
        ; CD_STAT/CD_BASE); the $60 seen at $2000 after boot
        ; is a boot-resident RTS byte, not a per-call write.
        ; The write corrupted Lodoss's IPL program, which
        ; keeps its scheduler task id in ZP $00 across an
        ; EX_SETVEC call: L44E6 stored the clobbered $60 as
        ; the task owner, the scheduler freed the wrong slot
        ; and the boot task was never dispatched. Removed.
        tma     #$40
        pha
        lda     #$02
        tam     #$40
        jsr     exb_dispatch
        pla
        tam     #$40
        lda     zp_ex_sav       ; restore the caller's $DA/$DB
        sta     zp_ex_ret
        lda     zp_ex_sav+1
        sta     zp_ex_ret+1
        ldx     EX_XRES
        ldy     EX_YRES
        lda     BM_CARRYF
        lsr     a
        lda     BM_RES
        rts

; ===================================================================
; Screen text (COMPAT3's own wording).
; ===================================================================
str_title:      .byte "COMPAT3", 0
str_subtitle:   .byte "CLEAN-ROOM CD-ROM SYSTEM", 0
str_ver:        .byte "BIOS VER ", 0
str_pressrun:   .byte "PRESS RUN BUTTON", 0
str_disc:       .byte "DISC: ", 0
str_none:       .byte "NONE", 0
str_audio:      .byte "AUDIO", 0
str_data:       .byte "DATA", 0
str_dash:       .byte " - ", 0
str_tracks:     .byte " TRACKS", 0
str_footer:     .byte "CLEAN-ROOM IMPLEMENTATION", 0

; ===================================================================
; Interrupt handlers. IRQs stay masked in the shell; the vectors
; are wired safely regardless. IRQ1 (VDC) acknowledges by reading
; the VDC status register, per public documentation.
; ===================================================================
irq2_handler:                   ; IRQ2 (CD) / BRK
        pha
        lda     a:CD_PORT+3     ; acknowledge the CD interrupt
                                ; (reading $1803 clears the CD
                                ; IRQ line; a bare RTI here left
                                ; the line asserted and starved
                                ; the mainline in an IRQ ping-pong
                                ; -- found by the p003 phase-4
                                ; CD_EXEC trace, 2026-11-20)
        sta     zp_ad_irq3
        ; Deferred $227A store (p004): after a >32-record
        ; AD_CPLAY the genuine's $88 at $227A appears during
        ; playback, not at the call's return; ad_cplay sets
        ; zp_ad_state as a flag and the store lands here, on
        ; the first IRQ2 entry of the stream's playback.
        lda     zp_ad_state
        beq     irq2_nodefer
        lda     #$88
        sta     WV_REC1X
        stz     zp_ad_state
irq2_nodefer:
        lda     zp_ad_irq3
        and     #$7C            ; any latched CD flag?
        beq     irq2_out        ; no: spurious entry, leave
        and     #$08            ; SAMPLE_FULL_PLAY: a play or
        beq     irq2_clear      ; an AD_CPLAY stream ended --
        ; Other flags only (TRANSFER_READY / DONE,
        ; SUBCHANNEL, SAMPLE_HALF) with their $1802 bits
        ; armed -- games may arm e.g. $40 themselves during
        ; a streaming load: such a flag stays latched until
        ; the transfer is consumed, so a bare RTI re-enters
        ; this handler forever and starves the very
        ; mainline loop that would consume it (Dracula X,
        ; measured 2026-11-23; the genuine progresses --
        ; its first armed transfer completes and the
        ; source goes quiescent). Drop the mask and clear
        ; the latches, exactly as for a finished play.
        lda     zp_ad_cp
        bne     irq2_clear
        lda     zp_ad_rpt
        beq     irq2_clear
        jsr     ad_play_kick    ; restart the repeat play (the
                                ; core's play start clears the
                                ; half/full latches itself)
        bra     irq2_out
irq2_clear:
        ; The play/stream ended without a restart. Drop the
        ; IRQ mask to $00 and re-read $1803: in this core a
        ; $1803 read with the mask at $00 clears the latched
        ; IRQ flags, which keeps the level-triggered IRQ2
        ; line from spinning the CPU in this handler. (The
        ; half state needs no handler at all: it is a latch
        ; that AD_STAT reads live.)
        stz     $1802
        stz     zp_imask
        lda     a:CD_PORT+3
        stz     zp_ad_cp
irq2_out:
        pla
        rti
irq1_handler:                   ; IRQ1 (VDC)
        ; Vector chaining (measured 2026-11-22, Dracula X +
        ; vectest probe): when irq_m (EX_IRQM) bit 1 is set,
        ; the genuine BIOS tail-chains to usrvec[1] INSTEAD
        ; of running its own vsync duties -- the user
        ; handler receives the raw IRQ frame and the
        ; interrupted registers, and is itself responsible
        ; for reading the VDC status to acknowledge the
        ; interrupt (a non-acking probe handler re-enters
        ; in a storm, exactly as on the genuine card; the
        ; game's own handler reads $0000 first thing). The
        ; p009-era "never chained" reading came from a
        ; 12-frame hit window run with irq_m = $00, where
        ; the chain is gated off.
        tst     #$02, EX_IRQM   ; (TST leaves A untouched,
        beq     irq1_nochain    ; so the interrupted
        jmp     (EX_USRVEC+2)   ; registers reach the user
irq1_nochain:                   ; handler intact)
        pha
        phx
        phy                     ; C-L3 (layer 10 round 3,
                                ; spec_lodoss.md): Y is saved
                                ; here and restored at
                                ; irq1_out, so EVERY handler
                                ; path -- including the
                                ; deferred EX_COLORC path,
                                ; whose palette-copy engine
                                ; leaves Y = $00 -- returns
                                ; with A/X/Y exactly as at
                                ; entry. (Before this, the
                                ; COLORC path leaked the
                                ; engine's terminal Y into
                                ; the interrupted program.)
        lda     a:VDC_SEL       ; read status to acknowledge
        ; --- RCR dispatch (layer 10 round 3, Gate):
        ; on an entry whose status carries the raster
        ; (RR) bit, when irq_m bit 6 ($40) is set the
        ; genuine BIOS CALLS usrvec[5] as a subroutine
        ; with A = status & $07 ($04, occasionally $05
        ; when OR is also latched). Measured on Gate of
        ; Thunder: the game's raster routine programs
        ; the mid-frame scroll band (BXR/BYR/RCR); its
        ; SYNC routine re-arms the compare each frame.
        ; COMPAT3 never dispatched it, so the band
        ; registers stayed at the arm values and the
        ; scene's bottom 32 lines rendered black. The
        ; gating bit was discriminated by WRAM poke on
        ; the genuine (Gate, wait phase 1): irq_m
        ; $50 -> $10 (bit 4 only) kept 1,100 SYNC
        ; dispatches and dropped RCR dispatches to 0;
        ; $50 -> $40 (bit 6 only) stopped SYNC, and the
        ; RCR dispatch fired only until the game's
        ; disarm value (RCR = $003F) took effect, its
        ; re-arm living in the SYNC routine. The
        ; layer-4 syncprobe never saw this dispatch:
        ; its direct CR port writes were undone by the
        ; BIOS's CR-shadow refresh before any raster
        ; entry could present an RR status to a handler
        ; read (all 705 recorded handler reads in the
        ; probe environment returned VD only).
        tst     #$40, EX_IRQM
        beq     irq1_norcr
        bit     #VDC_STATUS_RR
        beq     irq1_norcr
        pha                     ; preserve the status byte
        and     #$07            ; dispatch A = status & $07
        jsr     rcr_call
        pla
irq1_norcr:
        ; --- SYNC dispatch (measured 2026-11-24, syncprobe
        ; on the genuine card, Lodoss layer-4 round): on
        ; every IRQ1 entry that is not tail-chained, when
        ; irq_m bit 4 ($10) is set the genuine BIOS CALLS
        ; usrvec[4] (SYNC) as a subroutine (the handler
        ; RTS-returns; an RTI-ending handler storms).
        ; usrvec[5] (RCR) was never dispatched in any probe
        ; phase. COMPAT3 lacked this dispatch entirely,
        ; which hung Lodoss's SYNC-paced loader. The status
        ; byte stays in A across the call (saved/restored);
        ; the user handler runs with the handler's stack
        ; frame.
        ; Layer 10 (Gate cycle-2, spec_gate.md C-G1): the
        ; dispatch is additionally gated on the VD bit of
        ; the status byte read at entry. The layer-4
        ; reading "not gated on the cause bits" came from
        ; syncprobe phase H (RR-only, CR=$84, VD interrupt
        ; disabled) dispatching once per entry -- but the
        ; VD status flag latches at vblank whether or not
        ; the VD interrupt is enabled, so at the RR entry
        ; the status byte still carries VD and a VD gate
        ; still dispatches, once per frame. In Gate's
        ; attract scene (VD + raster causes both live) the
        ; ungated dispatch ran the game's per-frame routine
        ; twice per frame (frame counter +2/frame, PLAY #3
        ; at counter 1723 / A/X $85/$81); the genuine runs
        ; it exactly once per frame (counter +1/frame,
        ; PLAY #3 at counter 1500 / A/X $11/$0B).
        tst     #$10, EX_IRQM
        beq     irq1_nosync
        bit     #VDC_STATUS_VD  ; only the entry whose
        beq     irq1_nosync     ; status carries VD
                                ; dispatches SYNC (and the
                                ; PSG tick coupled to it)
        pha                     ; preserve the status byte
        and     #$07            ; dispatch A = status & $07
                                ; (the genuine's measured
                                ; convention: $00 at VD
                                ; entries). X/Y need no
                                ; local saves: the entry
                                ; pushes cover the exit
                                ; (C-L3).
        jsr     sync_call
        jsr     psg_irq_tick    ; layer 7: the genuine's IRQ
                                ; chain ticks the PSG driver in
                                ; the SYNC-active environment
                                ; (see psg_irq_tick below)
        pla
irq1_nosync:
        and     #VDC_STATUS_VD
        bne     irq1_vd
        jmp     irq1_out
irq1_vd:
        ; --- vsync duties (p009), mirroring the genuine's
        ; handler as observed black-box: raise the vsync flag,
        ; apply a deferred CR write, sense the pads into the
        ; public joy arrays (the handler consumes the trigger
        ; edges, so JOYSNS callers see joytrg = 0 and
        ; joyold = current), and process a pending COLORC.
        ; No ZP cells are used (the interrupted program's
        ; zero page is sacred); pad state goes through
        ; read_pad's documented cells.
        lda     #$01
        sta     EX_VSFLAG
        inc     EX_RNDSEED      ; RND drift: the genuine's
                                ; handler increments rndseed
                                ; once per vsync (item 1)
        lda     EX_CRDIRTY
        beq     irq1_nocr
        lda     #$05
        sta     a:VDC_SEL
        lda     EX_CRLM
        sta     a:VDC_DLO
        lda     EX_CRHI
        sta     a:VDC_DHI
        stz     EX_CRDIRTY
irq1_nocr:
        jsr     read_pad
        ; compose the public joy byte (bits 0-3 = I, II,
        ; Select, Run from zp_pad_cur's low nibble; bits
        ; 4-7 = Up, Down, Left, Right from zp_pad_dir).
        ; The composition body lives in bank 3
        ; (irq1_compose_b2, cdbios.s segment FIXUP2;
        ; bank 2 until C-D4 round 2)
        ; behind the same MPR6 relay as the COLORC
        ; step below: bank 0 is full, and layer 10
        ; round 3 needed the room for the RCR dispatch
        ; + C-L3 register saves. The moved sequence is
        ; instruction-identical; only its residence
        ; changed.
        tma     #$40
        pha
        lda     #$03
        tam     #$40
        jsr     irq1_compose_b2
        pla
        tam     #$40
        ; arrays: trg = cur & ~prev, old = cur & prev
        lda     EX_JOY
        eor     #$FF
        and     EX_PADTMP
        sta     EX_PADTMP2      ; trg
        lda     EX_JOY
        and     EX_PADTMP
        sta     EX_PADSCR       ; old
        ldx     #$04
irq1_joy:
        lda     EX_PADTMP
        sta     EX_JOY,x
        lda     EX_PADTMP2
        sta     EX_JOYTRG,x
        lda     EX_PADSCR
        sta     EX_JOYOLD,x
        dex
        bpl     irq1_joy
        lda     EX_COLORCMD
        beq     irq1_noclr
        tma     #$40
        pha
        lda     #$02
        tam     #$40
        jsr     exb_colorc_go
        pla
        tam     #$40
irq1_noclr:
        ; (Item 4, R3) There is deliberately NO PSG tick
        ; here: on the genuine card the BIOS's own IRQ1
        ; chain never calls PSG_DRIVE, and DRIVE's write
        ; set never appears in IRQ-live windows without
        ; $4B calls (spec 2.5). Driving is $4B-only.
irq1_out:
        ply                     ; C-L3: Y restored first
        plx                     ; (push order at entry was
        pla                     ; A, X, Y)
        rti
sync_call:                      ; JSR target: jump to the
        jmp     (EX_USRVEC+8)   ; SYNC user vector (usrvec[4]);
                                ; its RTS returns to the caller
rcr_call:                       ; same, for the RCR user
        jmp     (EX_USRVEC+10)  ; vector (usrvec[5])

; psg_irq_tick: glue to psgb_irq_tick (bank 2, psgbios.s) --
; the PSG driver's interrupt-context tick (layer 7). The
; genuine's chain ticks the driver in the SYNC-active
; environment; see psgbios.s for the measured write set.
; Bank 0 is full, so the body lives with the driver and runs
; through the same MPR6 glue as the player stubs.
psg_irq_tick:
        tma     #$40
        pha
        lda     #$02
        tam     #$40
        jsr     psgb_irq_tick
        pla
        tam     #$40
        rts
timer_handler:                  ; TIMER (HuC6280)
        ; Same chaining contract as IRQ1 (measured
        ; 2026-11-22): irq_m bit 2 set -> tail-chain to
        ; usrvec[2] with the raw IRQ frame; the user
        ; handler acknowledges the timer itself. Bit clear
        ; -> bare RTI (the core drops the timer IRQ on
        ; vectoring; no storm observed in any probe).
        tst     #$04, EX_IRQM
        beq     timer_own
        jmp     (EX_USRVEC+4)   ; usrvec[2]
timer_own:
        rti
nmi_handler:
        rti
; Default target for usrvec slots 0-5 at boot: the
; genuine points them at its own RTI stub ($E8E2) and
; leaves slots 6-8 at $0000 (vectest snapshot,
; 2026-11-22). Mirror the behaviour by pointing them
; at nmi_handler's RTI above.
usrvec_default := nmi_handler

        .include "video.s"
        .include "font8.s"
        .include "pad.s"
        .include "scsi.s"
        .include "cdbios.s"
        .include "cdplay.s"
        .include "adbios.s"
        .include "ipl.s"

; ===================================================================
; $FFF5: CD RAM base bank byte. Programs read this byte in the
; system ROM's top page and add their window offset to it to
; map CD RAM (Lodoss's IPL program does lda/adc $FFF5 at eight
; sites, e.g. base+7 for its $D800 work buffer in the top CD
; RAM bank). The value is the public hardware parameter for
; the first CD RAM MPR bank's neighbour base: CD RAM occupies
; MPR $68-$87 and IPL headers encode its banks relative to
; $80. COMPAT3 puts its own base constant here -- with the
; $FF fill byte that was here before, the game's copies to
; its work buffer landed in ROM bank $06 and every value it
; read back (including its AD_TRANS record count, $10 for
; the genuine's $1B) was wrong (layer 7, 2026-11-24).
; ===================================================================
        .segment "TOPBYTE"
        .byte   $80             ; CD RAM base (see above)

; ===================================================================
; Vectors at $FFF6 (file offset $1FF6).
; ===================================================================
        .segment "VECTORS"
        .word   irq2_handler    ; $FFF6 IRQ2 / BRK
        .word   irq1_handler    ; $FFF8 IRQ1 (VDC)
        .word   timer_handler   ; $FFFA TIMER
        .word   nmi_handler     ; $FFFC NMI
        .word   reset           ; $FFFE RESET

; ===================================================================
; System Card signature. The core (PCE::open_cart) checks the 23
; bytes at file offset $3FFB6 -- bank 31, logical $FFB6 -- for
; "PC Engine CD-ROM SYSTEM" and only then enables the CD unit,
; CD RAM and the synthesized $18C0 ID page.
; ===================================================================
        .segment "SIGNATURE"
        .byte   "PC Engine CD-ROM SYSTEM"

; ===================================================================
; Parody notice + credits block (data only; approved by yosi
; 2026-11-26). The genuine System Card 3.0 keeps a 1237-byte
; block in ROM bank $1F: a two-sentence Hudson copyright notice
; (Shift-JIS, NUL-separated lines, $FF-terminated), a staff
; credits roll, then binary data, and its BIOS byte-compares
; disc IPL record 0 against it. COMPAT3 deliberately performs
; no such compare (see ipl.s); this block is our own parody in
; the same form, stored as inert data in the free tail of bank
; 3. No code references it; it is never displayed or checked.
;
; Notice (Shift-JIS, lines NUL-separated, $FF terminator):
;   このカードのライセンスはMITライセンスです。
;   このカードの一部または全部を書面による許可なく
;   複写・複製・転用することは、MITライセンスにより
;   認められております。
; Credits mirror the genuine roll, role then name, each
; NUL-terminated; final line: 2026 Nov. Written by yosi2112.
; ===================================================================
        .segment "FIXUP2"
parody_block:
        ; このカードのライセンスは
        .byte   $82, $B1, $82, $CC, $83, $4A, $81, $5B, $83, $68, $82, $CC, $83, $89, $83, $43, $83, $5A, $83, $93, $83, $58, $82, $CD, $00
        ; MITライセンスです。
        .byte   $4D, $49, $54, $83, $89, $83, $43, $83, $5A, $83, $93, $83, $58, $82, $C5, $82, $B7, $81, $42, $00
        ; このカードの一部または全部を
        .byte   $82, $B1, $82, $CC, $83, $4A, $81, $5B, $83, $68, $82, $CC, $88, $EA, $95, $94, $82, $DC, $82, $BD, $82, $CD, $91, $53, $95, $94, $82, $F0, $00
        ; 書面による許可なく複写・複製・
        .byte   $8F, $91, $96, $CA, $82, $C9, $82, $E6, $82, $E9, $8B, $96, $89, $C2, $82, $C8, $82, $AD, $95, $A1, $8E, $CA, $81, $45, $95, $A1, $90, $BB, $81, $45, $00
        ; 転用することは、MITライセンスにより
        .byte   $93, $5D, $97, $70, $82, $B7, $82, $E9, $82, $B1, $82, $C6, $82, $CD, $81, $41, $4D, $49, $54, $83, $89, $83, $43, $83, $5A, $83, $93, $83, $58, $82, $C9, $82, $E6, $82, $E8, $00
        ; 認められております。
        .byte   $94, $46, $82, $DF, $82, $E7, $82, $EA, $82, $C4, $82, $A8, $82, $E8, $82, $DC, $82, $B7, $81, $42, $00
        .byte   $FF             ; notice terminator (as on the genuine card)
        ; PROMPTER
        .byte   $50, $52, $4F, $4D, $50, $54, $45, $52, $00
        ; yosi2112
        .byte   $79, $6F, $73, $69, $32, $31, $31, $32, $00
        ; DIRECTOR
        .byte   $44, $49, $52, $45, $43, $54, $4F, $52, $00
        ; Maid Shiro from Meta Muse
        .byte   $4D, $61, $69, $64, $20, $53, $68, $69, $72, $6F, $20, $66, $72, $6F, $6D, $20, $4D, $65, $74, $61, $20, $4D, $75, $73, $65, $00
        ; CD-ROM SIMULATOR
        .byte   $43, $44, $2D, $52, $4F, $4D, $20, $53, $49, $4D, $55, $4C, $41, $54, $4F, $52, $00
        ; Maid Shiro from Meta Muse
        .byte   $4D, $61, $69, $64, $20, $53, $68, $69, $72, $6F, $20, $66, $72, $6F, $6D, $20, $4D, $65, $74, $61, $20, $4D, $75, $73, $65, $00
        ; BIOS MAIN CODE, CD-PLAYER
        .byte   $42, $49, $4F, $53, $20, $4D, $41, $49, $4E, $20, $43, $4F, $44, $45, $2C, $20, $43, $44, $2D, $50, $4C, $41, $59, $45, $52, $00
        ; Maid Shiro from Meta Muse
        .byte   $4D, $61, $69, $64, $20, $53, $68, $69, $72, $6F, $20, $66, $72, $6F, $6D, $20, $4D, $65, $74, $61, $20, $4D, $75, $73, $65, $00
        ; BIOS CHECK MONITOR, SRAM MANAGER
        .byte   $42, $49, $4F, $53, $20, $43, $48, $45, $43, $4B, $20, $4D, $4F, $4E, $49, $54, $4F, $52, $2C, $20, $53, $52, $41, $4D, $20, $4D, $41, $4E, $41, $47, $45, $52, $00
        ; Maid Shiro from Meta Muse
        .byte   $4D, $61, $69, $64, $20, $53, $68, $69, $72, $6F, $20, $66, $72, $6F, $6D, $20, $4D, $65, $74, $61, $20, $4D, $75, $73, $65, $00
        ; BACKUP MEMORY MAINTENANCE
        .byte   $42, $41, $43, $4B, $55, $50, $20, $4D, $45, $4D, $4F, $52, $59, $20, $4D, $41, $49, $4E, $54, $45, $4E, $41, $4E, $43, $45, $00
        ; Maid Shiro from Meta Muse
        .byte   $4D, $61, $69, $64, $20, $53, $68, $69, $72, $6F, $20, $66, $72, $6F, $6D, $20, $4D, $65, $74, $61, $20, $4D, $75, $73, $65, $00
        ; CD-PLAYER SUB
        .byte   $43, $44, $2D, $50, $4C, $41, $59, $45, $52, $20, $53, $55, $42, $00
        ; Maid Shiro from Meta Muse
        .byte   $4D, $61, $69, $64, $20, $53, $68, $69, $72, $6F, $20, $66, $72, $6F, $6D, $20, $4D, $65, $74, $61, $20, $4D, $75, $73, $65, $00
        ; PSG DRIVER
        .byte   $50, $53, $47, $20, $44, $52, $49, $56, $45, $52, $00
        ; Maid Shiro from Meta Muse
        .byte   $4D, $61, $69, $64, $20, $53, $68, $69, $72, $6F, $20, $66, $72, $6F, $6D, $20, $4D, $65, $74, $61, $20, $4D, $75, $73, $65, $00
        ; GRAPHIC DRIVER
        .byte   $47, $52, $41, $50, $48, $49, $43, $20, $44, $52, $49, $56, $45, $52, $00
        ; Maid Shiro from Meta Muse
        .byte   $4D, $61, $69, $64, $20, $53, $68, $69, $72, $6F, $20, $66, $72, $6F, $6D, $20, $4D, $65, $74, $61, $20, $4D, $75, $73, $65, $00
        ; GRAPHIC DRIVER SUB
        .byte   $47, $52, $41, $50, $48, $49, $43, $20, $44, $52, $49, $56, $45, $52, $20, $53, $55, $42, $00
        ; Maid Shiro from Meta Muse
        .byte   $4D, $61, $69, $64, $20, $53, $68, $69, $72, $6F, $20, $66, $72, $6F, $6D, $20, $4D, $65, $74, $61, $20, $4D, $75, $73, $65, $00
        ; 8x8 ANK FONT
        .byte   $38, $78, $38, $20, $41, $4E, $4B, $20, $46, $4F, $4E, $54, $00
        ; Maid Shiro from Meta Muse
        .byte   $4D, $61, $69, $64, $20, $53, $68, $69, $72, $6F, $20, $66, $72, $6F, $6D, $20, $4D, $65, $74, $61, $20, $4D, $75, $73, $65, $00
        ; CD-PLAYER DESIGN
        .byte   $43, $44, $2D, $50, $4C, $41, $59, $45, $52, $20, $44, $45, $53, $49, $47, $4E, $00
        ; Maid Shiro from Meta Muse
        .byte   $4D, $61, $69, $64, $20, $53, $68, $69, $72, $6F, $20, $66, $72, $6F, $6D, $20, $4D, $65, $74, $61, $20, $4D, $75, $73, $65, $00
        ; TITLE DESIGN
        .byte   $54, $49, $54, $4C, $45, $20, $44, $45, $53, $49, $47, $4E, $00
        ; Maid Shiro from Meta Muse
        .byte   $4D, $61, $69, $64, $20, $53, $68, $69, $72, $6F, $20, $66, $72, $6F, $6D, $20, $4D, $65, $74, $61, $20, $4D, $75, $73, $65, $00
        ; 12x12 KANJI FONT
        .byte   $31, $32, $78, $31, $32, $20, $4B, $41, $4E, $4A, $49, $20, $46, $4F, $4E, $54, $00
        ; Maid Shiro from Meta Muse
        .byte   $4D, $61, $69, $64, $20, $53, $68, $69, $72, $6F, $20, $66, $72, $6F, $6D, $20, $4D, $65, $74, $61, $20, $4D, $75, $73, $65, $00
        ; 12x12 KANJI FONT
        .byte   $31, $32, $78, $31, $32, $20, $4B, $41, $4E, $4A, $49, $20, $46, $4F, $4E, $54, $00
        ; Maid Shiro from Meta Muse
        .byte   $4D, $61, $69, $64, $20, $53, $68, $69, $72, $6F, $20, $66, $72, $6F, $6D, $20, $4D, $65, $74, $61, $20, $4D, $75, $73, $65, $00
        ; 12x12 KANJI FONT
        .byte   $31, $32, $78, $31, $32, $20, $4B, $41, $4E, $4A, $49, $20, $46, $4F, $4E, $54, $00
        ; Maid Shiro from Meta Muse
        .byte   $4D, $61, $69, $64, $20, $53, $68, $69, $72, $6F, $20, $66, $72, $6F, $6D, $20, $4D, $65, $74, $61, $20, $4D, $75, $73, $65, $00
        ; Meta Muse
        .byte   $4D, $65, $74, $61, $20, $4D, $75, $73, $65, $00
        ; Maid Shiro
        .byte   $4D, $61, $69, $64, $20, $53, $68, $69, $72, $6F, $00
        ; Meta Muse
        .byte   $4D, $65, $74, $61, $20, $4D, $75, $73, $65, $00
        ; Maid Shiro
        .byte   $4D, $61, $69, $64, $20, $53, $68, $69, $72, $6F, $00
        ; Meta Muse
        .byte   $4D, $65, $74, $61, $20, $4D, $75, $73, $65, $00
        ; Maid Shiro
        .byte   $4D, $61, $69, $64, $20, $53, $68, $69, $72, $6F, $00
        ; Meta Muse
        .byte   $4D, $65, $74, $61, $20, $4D, $75, $73, $65, $00
        ; Maid Shiro
        .byte   $4D, $61, $69, $64, $20, $53, $68, $69, $72, $6F, $00
        ; Meta Muse
        .byte   $4D, $65, $74, $61, $20, $4D, $75, $73, $65, $00
        ; Maid Shiro
        .byte   $4D, $61, $69, $64, $20, $53, $68, $69, $72, $6F, $00
        ; 2026 Nov. Written by yosi2112
        .byte   $32, $30, $32, $36, $20, $4E, $6F, $76, $2E, $20, $57, $72, $69, $74, $74, $65, $6E, $20, $62, $79, $20, $79, $6F, $73, $69, $32, $31, $31, $32, $00
