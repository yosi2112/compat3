; ===================================================================
; fnbios.s -- EX_GETFNT ($20) implementation (ws005 p007), clean
; room. Lives in bank 2 next to the BM BIOS and is entered through
; the bank-0 MPR6 glue (ex_getfnt in bank0.s), which also performs
; the final copy from FN_STAGE to the caller's destination AFTER
; restoring the caller's MPR6 -- so every destination page,
; including the $C000 window itself, lands through the caller's
; own mapping exactly as on the genuine card.
;
; The observable contract was measured black-box against the
; genuine card (fntest.s sweeps of all 11,280 Shift-JIS double-
; byte codes in both modes, single-byte forms, and 30 register /
; memory shape cases; glyph bytes themselves were never read
; out beyond a 4-code layout probe and are NOT reproduced --
; COMPAT3's glyphs come from the KH-Dot-Dougenzaka font, SIL
; OFL 1.1, packed by tools/pack_font.py):
;
;   IN   _AH = Shift-JIS lead byte, _AL = trail byte
;        _BX = destination address, _DH = mode (bit 0 only:
;              0 = 16x16 cell, 1 = 12x12 cell)
;   OUT  A = $00 ok / $01 kanji code error; carry ALWAYS set
;   - accepted set: exactly the codes whose JIS X 0208 ku is
;     1-7 or 16-47 (level-1 kanji), every ten 1-94 in those ku,
;     including slots JIS leaves unassigned (blank glyphs)
;   - single-byte forms (either byte $00) are all errors
;   - transfer is 32 bytes in BOTH modes; the 12x12 cell keeps
;     its 12 pixels in bits 15-4 of each of the first 12 rows
;     (2 bytes/row) and bytes 24-31 are zero
;   - all caller MPRs are preserved; on error nothing is
;     written to the destination
;
; Packed font layout (glyph index = ku order over the accepted
; set, 3666 glyphs): 16x16 at 32 B/glyph in ROM banks 4-18
; (256 glyphs/bank); 12x12 at 24 B/glyph in banks 19-29
; (341 glyphs/bank, 8184 B used). The font is read through
; MPR5 (window $A000), saved and restored around the call.
; ===================================================================

        .setcpu "huc6280"
        .include "hw.inc"

        .export fnb_getfnt

; --- Work block, shared with the EX/MA scratch block (calls
; never nest). Was ZP $30-$3D until the C-D1 relocation
; (layer 10 / spec_drac.md): the scalar cells now sit in WRAM
; at the same offsets in the shared block ($24D0-$24DB) and
; fn_mpr5 at $24DD. fn_ptr stays a zero-page cell because the
; copy loops dereference it with (zp),y, which cannot encode
; a WRAM operand: it is the borrowed ZP_PTR_FN ($E0,
; BM_EP's cell; was $C2 until C-D5 round 3), saved
; and restored around fnb_getfnt (see hw.inc). ---
fn_lead         = $24D0         ; SJIS lead byte
fn_trail        = $24D1         ; SJIS trail byte
fn_ku           = $24D2         ; JIS ku (1-94)
fn_ten          = $24D3         ; JIS ten (1-94)
fn_idx          = $24D4         ; glyph index (2)
fn_ptr          = ZP_PTR_FN     ; font source pointer (2)
fn_tmp          = $24D8         ; 16-bit scratch (2)
fn_bank         = $24DA         ; font ROM bank
fn_mode         = $24DB         ; 0 = 16x16, 1 = 12x12
fn_mpr5         = $24DD         ; saved caller MPR5

        .segment "FNCODE"

; -------------------------------------------------------------------
; fnb_getfnt: validate + convert the code, stage the 32-byte
; cell into FN_STAGE, leave the result code in BM_RES.
; -------------------------------------------------------------------
fnb_getfnt:
        lda     ZP_PTR_FN       ; save the borrowed pointer
        sta     FN_PTR_SAV      ; cell's caller bytes (restored
        lda     ZP_PTR_FN+1     ; at fn_done; net effect zero)
        sta     FN_PTR_SAV+1
        lda     #$01
        sta     BM_RES          ; default: kanji code error
        tma     #$20            ; save caller's MPR5 (font window)
        sta     fn_mpr5
        lda     ARG_DH
        and     #$01
        sta     fn_mode
        lda     ARG_AH
        sta     fn_lead
        lda     ARG_AL
        sta     fn_trail
        ; --- lead byte range: $81-$9F or $E0-$FC -----------------
        lda     fn_lead
        cmp     #$81
        bcc     fn_reject1
        cmp     #$A0
        bcc     fn_lead_ok
        cmp     #$E0
        bcc     fn_reject1
        cmp     #$FD
        bcs     fn_reject1
fn_lead_ok:
        ; --- trail byte range: $40-$7E or $80-$FC ----------------
        lda     fn_trail
        cmp     #$40
        bcc     fn_reject1
        cmp     #$7F
        beq     fn_reject1
        cmp     #$FD
        bcs     fn_reject1
        bra     fn_conv
fn_reject1:
        jmp     fn_done
fn_conv:
        ; --- SJIS -> JIS: adjusted lead --------------------------
        lda     fn_lead
        cmp     #$E0
        bcc     fn_adj
        sbc     #$40            ; carry set (>= $E0): lead - $40
fn_adj:                         ; A = $81-$9F
        sec
        sbc     #$81            ; 0-$1E
        asl     a               ; *2 (<= $3C, no overflow)
        inc     a               ; ku_base = (adj-$81)*2 + 1
        sta     fn_ku
        ; --- trail half ------------------------------------------
        lda     fn_trail
        cmp     #$9F
        bcs     fn_high
        cmp     #$7F            ; $40-$7E -> ten = trail-$3F
        bcc     fn_ten_lo
        sbc     #$40            ; $80-$9E -> ten = trail-$40
        sta     fn_ten          ; (carry set: >= $80)
        bra     fn_range
fn_ten_lo:
        sec
        sbc     #$3F            ; ten = trail - $3F (1-63)
        sta     fn_ten
        bra     fn_range
fn_high:                        ; trail $9F-$FC: ku+1, ten = trail-$9E
        inc     fn_ku
        sbc     #$9E            ; carry set (>= $9F)
        sta     fn_ten
fn_range:
        ; --- acceptance: ku 1-7 or 16-47 -------------------------
        lda     fn_ku
        cmp     #$08
        bcc     fn_idx_a        ; ku 1-7
        cmp     #$10
        bcc     fn_reject       ; ku 8-15 rejected
        cmp     #$30
        bcs     fn_reject       ; ku 48+ rejected
        ; region B: idx = 658 + (ku-16)*94 + (ten-1)
        lda     #<658
        sta     fn_idx
        lda     #>658
        sta     fn_idx+1
        lda     fn_ku
        sec
        sbc     #$10            ; ku-16 (0-31)
        jsr     fn_add94
        bra     fn_idx_done
fn_reject:
        jmp     fn_done
fn_idx_a:                       ; region A: idx = (ku-1)*94 + (ten-1)
        stz     fn_idx
        stz     fn_idx+1
        lda     fn_ku
        dec     a               ; ku-1 (0-6)
        jsr     fn_add94
fn_idx_done:
        lda     fn_ten
        dec     a               ; ten-1 (0-93)
        clc
        adc     fn_idx
        sta     fn_idx
        bcc     fn_mode_sel
        inc     fn_idx+1
fn_mode_sel:
        lda     fn_mode
        bne     fn_do12
        jmp     fn_do16
fn_done:
        lda     fn_mpr5
        tam     #$20            ; restore caller's MPR5
        lda     FN_PTR_SAV      ; restore the borrowed pointer
        sta     ZP_PTR_FN
        lda     FN_PTR_SAV+1
        sta     ZP_PTR_FN+1
        rts

; fn_add94: fn_idx += A * 94  (A = 0-31)
fn_add94:
        tax
        beq     fa_rts
fa_loop:
        clc
        lda     fn_idx
        adc     #94
        sta     fn_idx
        bcc     fa_next
        inc     fn_idx+1
fa_next:
        dex
        bne     fa_loop
fa_rts:
        rts

; -------------------------------------------------------------------
; 16x16: bank = 4 + (idx >> 8); offset = (idx & $FF) * 32.
; -------------------------------------------------------------------
fn_do16:
        lda     fn_idx+1
        clc
        adc     #$04
        sta     fn_bank
        lda     fn_idx          ; offset = idx_lo * 32 (16-bit)
        sta     fn_ptr
        stz     fn_ptr+1
        ldx     #$05
fd16_sh:
        asl     fn_ptr
        rol     fn_ptr+1
        dex
        bne     fd16_sh
        lda     fn_ptr+1
        ora     #$A0            ; font window at $A000 (MPR5)
        sta     fn_ptr+1
        lda     fn_bank
        tam     #$20
        ldy     #$1F            ; copy 32 bytes to FN_STAGE
fd16_cp:
        lda     (fn_ptr),y
        sta     FN_STAGE,y
        dey
        bpl     fd16_cp
        stz     BM_RES          ; success
        bra     fn_done

; -------------------------------------------------------------------
; 12x12: bank = 19 + idx/341; offset = (idx mod 341) * 24.
; Copy 24 bytes, zero the last 8 of the 32-byte cell.
; -------------------------------------------------------------------
fn_do12:
        lda     fn_idx
        sta     fn_tmp
        lda     fn_idx+1
        sta     fn_tmp+1
        ldx     #$00            ; X = quotient
fd12_div:
        lda     fn_tmp+1
        cmp     #>341
        bcc     fd12_divdone
        bne     fd12_sub
        lda     fn_tmp
        cmp     #<341
        bcc     fd12_divdone
fd12_sub:
        sec
        lda     fn_tmp
        sbc     #<341
        sta     fn_tmp
        lda     fn_tmp+1
        sbc     #>341
        sta     fn_tmp+1
        inx
        bra     fd12_div
fd12_divdone:
        txa
        clc
        adc     #19
        sta     fn_bank
        ; offset = rem * 24 = rem*16 + rem*8
        lda     fn_tmp          ; fn_ptr = rem << 3
        sta     fn_ptr
        lda     fn_tmp+1
        sta     fn_ptr+1
        ldx     #$03
fd12_s1:
        asl     fn_ptr
        rol     fn_ptr+1
        dex
        bne     fd12_s1
        lda     fn_ptr          ; fn_tmp = fn_ptr (rem*8)
        sta     fn_tmp
        lda     fn_ptr+1
        sta     fn_tmp+1
        ldx     #$01            ; fn_ptr = rem*16
fd12_s2:
        asl     fn_ptr
        rol     fn_ptr+1
        dex
        bne     fd12_s2
        clc                     ; fn_ptr += rem*8 -> rem*24
        lda     fn_ptr
        adc     fn_tmp
        sta     fn_ptr
        lda     fn_ptr+1
        adc     fn_tmp+1
        ora     #$A0            ; font window at $A000 (MPR5)
        sta     fn_ptr+1
        lda     fn_bank
        tam     #$20
        ldy     #$17            ; copy 24 bytes
fd12_cp:
        lda     (fn_ptr),y
        sta     FN_STAGE,y
        dey
        bpl     fd12_cp
        lda     #$00            ; bytes 24-31 are zero
        ldy     #$18
fd12_z:
        sta     FN_STAGE,y
        iny
        cpy     #$20
        bne     fd12_z
        stz     BM_RES          ; success
        jmp     fn_done
