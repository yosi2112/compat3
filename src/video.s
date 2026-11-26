; COMPAT3 video: VDC/VCE bring-up and BAT text output.
; Display format follows the verified values used by the ws001
; test ROMs in this repository (32x32 BAT, 256x240 visible).
; Text patterns live at VRAM word $2000: character code in the BAT
; is $200 + (ASCII - $20), one 8x8 glyph per code.
        .segment "CODE"

; vdc_write: Y = register, X = value low, A = value high.
; The VDC ports are < $0100, so the a: prefix is mandatory (else
; ca65 emits zero-page addressing into work RAM).
vdc_write:
        sty     a:VDC_SEL
        stx     a:VDC_DLO
        sta     a:VDC_DHI
        rts

; vdc_write_addr: set MAWR from zp_vdcval (16-bit).
vdc_set_mawr:
        ldy     #VDC_MAWR
        ldx     zp_vdcval
        lda     zp_vdcval+1
        jmp     vdc_write

; video_init: palette, VDC registers, VRAM clear, font upload,
; background display on (CR written last).
video_init:
        ; Layer-5: the body lives in bank 2 (segment VIDEO2);
        ; bank 0 needed the bytes for the WRAM work-area move.
        ; This relay maps bank 2 into MPR6, calls the body and
        ; restores the caller's MPR6. video_init runs once, at
        ; reset, before any program exists.
        tma     #$40
        pha
        lda     #$02
        tam     #$40
        jsr     video_init_b2
        pla
        tam     #$40
        rts

        .segment "VIDEO2"
video_init_b2:
        ; --- VCE: backdrop everywhere, then 3 text colors -------
        stz     VCE_CTL
        stz     VCE_PAL_LO
        stz     VCE_PAL_HI
        ldx     #$00
vi_pal_loop:                    ; 256 entries of backdrop $005
        lda     #$05
        sta     VCE_PAL_DLO
        stz     VCE_PAL_DHI
        inx
        bne     vi_pal_loop
        ; entry 1 (pal 0 color 1) = white $1FF
        lda     #$01
        sta     VCE_PAL_LO
        stz     VCE_PAL_HI
        lda     #$FF
        sta     VCE_PAL_DLO
        lda     #$01
        sta     VCE_PAL_DHI
        ; entry 17 (pal 1 color 1) = yellow $1F8
        lda     #$11
        sta     VCE_PAL_LO
        lda     #$F8
        sta     VCE_PAL_DLO
        lda     #$01
        sta     VCE_PAL_DHI
        ; entry 33 (pal 2 color 1) = cyan $1C7
        lda     #$21
        sta     VCE_PAL_LO
        lda     #$C7
        sta     VCE_PAL_DLO
        lda     #$01
        sta     VCE_PAL_DHI
        ; --- VDC registers ----------------------------------------
        ldy     #VDC_MWR
        ldx     #$00
        lda     #$00
        jsr     vdc_write
        ldy     #VDC_HSR
        ldx     #$02
        lda     #$02
        jsr     vdc_write
        ldy     #VDC_HDR
        ldx     #$1F
        lda     #$04
        jsr     vdc_write
        ldy     #VDC_VPR
        ldx     #$02
        lda     #$0F
        jsr     vdc_write
        ldy     #VDC_VDW
        ldx     #$EF
        lda     #$00
        jsr     vdc_write
        ldy     #VDC_VCR
        ldx     #$F6            ; power-on set VCR = $00F6
        lda     #$00            ; (layer 10 round 6, C-G5:
        jsr     vdc_write       ; was $0002 pre-round-6)
        ldy     #VDC_DCR
        ldx     #$00
        lda     #$00
        jsr     vdc_write
        ldy     #VDC_BXR
        ldx     #$00
        lda     #$00
        jsr     vdc_write
        ldy     #VDC_BYR
        ldx     #$00
        lda     #$00
        jsr     vdc_write
        ; --- clear VRAM (32768 words) ------------------------------
        lda     #$00
        sta     zp_vdcval
        sta     zp_vdcval+1
        jsr     vdc_set_mawr
        ldy     #VDC_VWR
        sty     a:VDC_SEL
        ldy     #$80            ; 128 x 256 = 32768 words
vi_clr_y:
        ldx     #$00
vi_clr_x:
        lda     #$00
        sta     a:VDC_DLO
        sta     a:VDC_DHI
        inx
        bne     vi_clr_x
        dey
        bne     vi_clr_y
        ; --- upload font to VRAM word $2000 ------------------------
        lda     #$00
        sta     zp_vdcval
        lda     #$20
        sta     zp_vdcval+1
        jsr     vdc_set_mawr
        ldy     #VDC_VWR
        sty     a:VDC_SEL
        lda     #<font8_data
        sta     zp_ptr
        lda     #>font8_data
        sta     zp_ptr+1
        ; font8_data lives in bank 2 (FONT8B2, $D850
        ; since C-D4 round 2):
        ; map it into the MPR6 window for the upload and
        ; restore the caller's MPR6 afterwards.
        tma     #$40
        pha
        lda     #$02
        tam     #$40
        ldx     #95             ; glyphs $20-$7E
vi_glyph:
        ldy     #$00
vi_row:                         ; 8 pattern words: row byte, 0
        lda     (zp_ptr),y
        sta     a:VDC_DLO
        lda     #$00
        sta     a:VDC_DHI
        iny
        cpy     #$08
        bne     vi_row
        ldy     #$08            ; 8 empty words (planes 2/3 + pad)
vi_zero:
        lda     #$00
        sta     a:VDC_DLO
        sta     a:VDC_DHI
        dey
        bne     vi_zero
        clc
        lda     zp_ptr
        adc     #$08
        sta     zp_ptr
        bcc     vi_gnext
        inc     zp_ptr+1
vi_gnext:
        dex
        bne     vi_glyph
        pla
        tam     #$40            ; restore caller's MPR6
        ; --- display on: CR = $0088 (BG enable + vblank IRQ enable)
        ; The vblank interrupt enable is required on this core:
        ; its VDC only sets the VD status bit when CR bit 3 is set
        ; (pce.cpp: status |= VDC_VD is inside if (CR & CR_VR)).
        ; The IRQ itself stays masked at $1402 and by the CPU
        ; I flag, so no handler runs; we poll the status bit.
        ldy     #VDC_CR
        ldx     #$88
        lda     #$00
        jsr     vdc_write
        rts

; ipl_vdc_game_b2 (the round-3 C-G3 handover timing write)
; is RETIRED by layer 10 round 6 (contract C-G5): the
; genuine writes nothing at IPL handover; per-title timing
; sets arrive via the game's own EX_SCMOD call under the
; C-L6 apply in exbios.s (segment VIDEO2, below video_init
; in the link layout only -- it is exbios.o's contribution
; to this segment).

        .segment "CODE"
; bat_clear: fill the 32x32 BAT with the space glyph (palette 0).
bat_clear:
        lda     #$00
        sta     zp_vdcval
        sta     zp_vdcval+1
        jsr     vdc_set_mawr
        ldy     #VDC_VWR
        sty     a:VDC_SEL
        ldy     #$04            ; 4 x 256 = 1024 words
bc_y:
        ldx     #$00
bc_x:
        lda     #$00            ; low byte of code $200
        sta     a:VDC_DLO
        lda     #$02            ; high byte: code $200, palette 0
        sta     a:VDC_DHI
        inx
        bne     bc_x
        dey
        bne     bc_y
        rts

; set_cursor: A = row (0-27), X = column (0-31). Sets MAWR.
set_cursor:
        stx     zp_tmp0
        sta     zp_tmp1
        lda     #$00
        sta     zp_vdcval
        sta     zp_vdcval+1
sc_add:
        lda     zp_tmp1
        beq     sc_set
        clc
        lda     zp_vdcval
        adc     #$20
        sta     zp_vdcval
        bcc     sc_nc
        inc     zp_vdcval+1
sc_nc:
        dec     zp_tmp1
        bra     sc_add
sc_set:
        clc
        lda     zp_vdcval
        adc     zp_tmp0
        sta     zp_vdcval
        bcc     sc_go
        inc     zp_vdcval+1
sc_go:
        jmp     vdc_set_mawr

; putch: A = ASCII character. Writes one BAT entry at the cursor
; (MAWR auto-increments). Characters outside $20-$7E become space.
; Uses the palette in zp_pal.
putch:
        cmp     #$20
        bcc     pc_space
        cmp     #$7F
        bcc     pc_ok
pc_space:
        lda     #$20
pc_ok:
        sec
        sbc     #$20            ; glyph index = code low byte
        pha
        lda     #VDC_VWR        ; select via A: putch must preserve
        sta     a:VDC_SEL       ; Y, which print_str uses as index
        pla
        sta     a:VDC_DLO
        lda     zp_pal
        asl     a
        asl     a
        asl     a
        asl     a
        ora     #$02            ; character code high byte ($2xx)
        sta     a:VDC_DHI
        rts

; print_str: NUL-terminated string at zp_ptr.
print_str:
        ldy     #$00
ps_loop:
        lda     (zp_ptr),y
        beq     ps_done
        jsr     putch
        iny
        bne     ps_loop
ps_done:
        rts

; print_dec: A = value 0-99, printed without leading zero.
print_dec:
        ldx     #$00
        sta     zp_tmp0
pd_tens:
        lda     zp_tmp0
        cmp     #$0A
        bcc     pd_units
        sec
        sbc     #$0A
        sta     zp_tmp0
        inx
        bra     pd_tens
pd_units:
        txa
        beq     pd_one
        ora     #$30
        jsr     putch
pd_one:
        lda     zp_tmp0
        ora     #$30
        jmp     putch
