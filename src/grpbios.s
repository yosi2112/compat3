; ===================================================================
; grpbios.s -- $49 GRP_BIOS (ws005 item 4, IMPLEMENTATION side
; of the two-side clean room).
;
; Written ONLY from item4_spec.md and public documentation
; (Hu7 CD System BIOS Manual). Lives in bank 3 (segment
; GRPCODE), swapped into MPR6 by the bank-2 stub exb_grp;
; grp_entry restores MPR6 = bank 2 before returning.
;
; The bitmap layout, coordinate conventions, per-function
; inputs/outputs and state cells are the spec's (sections 4
; and 2.1): word address = GINIT base + (y>>3)*$200 +
; (y&7) + (x>>3)*$10; the word at addr holds planes 0/1, the
; word at addr+8 planes 2/3; pixel i (0 = leftmost) is bit
; (7-i) of each plane byte. Exit A is not a result (spec 4);
; results return in X and the shadow block.
;
; Unpinned-by-spec behaviours are implemented per the public
; manual, as the spec directs: PUTFONT/SYMBOL glyph rendering
; (4.10 -- glyphs come from COMPAT3's own KH-dot font data
; through the same MPR5 layout fnbios.s uses; nothing is
; copied from the genuine card), POINT returns the colour
; in A (4, manual). FLOOD/PAINT/GWINDOW follow the
; measured semantics pinned in spec 4.2 as revised at R4,
; and POINT's exit carry follows the vi_padrs model pinned
; at R6 (SB-20; the R5 one-shot rule is withdrawn) with the
; full transition table measured at R7 (SB-21; see
; g_point). (The documented interior fill was never
; observed on the genuine card in this environment.)
; DH >= 16 is a no-op here; on the genuine it is undefined
; (spec 4).
; ===================================================================
        .setcpu "HuC6280"
        .include "hw.inc"

        .import vdc_write
        .export grp_entry

; shadow result words (same addresses as hw.inc's ARG block;
; bmbios.s keeps the same local names)
BM_AX           = $20F8
BM_BX           = $20FA
BM_BH           = $20FB

; GRP work-RAM layout (spec 4: work area $2616-$2648)
GW_ADDR         = $2642         ; current word address (2)
GP0             = $2644         ; plane bytes for RMW
GP1             = $2645
GP2             = $2646
GP3             = $2647
; COMPAT3-private GRP state (outside the observed area)
GRP_PRIV        = $28D0
PX              = GRP_PRIV + 0  ; pixel-op x
PY              = GRP_PRIV + 1  ; pixel-op y
PCOL            = GRP_PRIV + 2  ; pixel-op colour
F_BORDL         = GRP_PRIV + 7  ; PAINT border mask (copy)
F_BORDH         = GRP_PRIV + 8
GL_IDX          = GRP_PRIV + 9  ; glyph index (2)
GL_W            = GRP_PRIV + 11 ; glyph width (8/12/16)
GL_H            = GRP_PRIV + 12 ; glyph height
GL_MX           = GRP_PRIV + 13 ; magnification x
GL_MY           = GRP_PRIV + 14 ; magnification y
GL_ROW          = GRP_PRIV + 15 ; render row
GL_COL          = GRP_PRIV + 16 ; render column
GL_BITS         = GRP_PRIV + 17 ; current glyph row (2)
GL_BASEX        = GRP_PRIV + 19 ; render base pixel x (2)
GL_BASEY        = GRP_PRIV + 21 ; render base pixel y (2)
PMASK           = GRP_PRIV + 23 ; pixel-op bit mask
PINV            = GRP_PRIV + 24 ; inverse mask
PACC            = GRP_PRIV + 25 ; colour accumulator
GL_DX           = GRP_PRIV + 26 ; magnification counters
GL_DY           = GRP_PRIV + 27
GL_T            = GRP_PRIV + 28 ; render temp
SH_N            = GRP_PRIV + 29 ; glyph bit shift count
SH_LO           = GRP_PRIV + 30 ; glyph bit shift value (2)
SH_HI           = GRP_PRIV + 31
FILL_STACK      = $2A00         ; 768 (x,y) seed pairs

; mainline scratch (shared bank convention; was ZP $30-$3B
; until the C-D1 relocation, layer 10 / spec_drac.md -- the
; scalar cells now sit in WRAM at the same offsets in the
; shared block $24D0-$24DB)
L_X             = $24D0
L_Y             = $24D1
L_X1            = $24D2
L_Y1            = $24D3
L_SX            = $24D4
L_SY            = $24D5
L_DX            = $24D6         ; (2)
L_DY            = $24D8         ; (2, negative)
L_ERR           = $24DA         ; (2, signed)
; pointer cells (mainline): fill-stack pointer, glyph ptr.
; GP_PTR stays a zero-page cell because the glyph render
; dereferences it with (zp),y, which cannot encode a WRAM
; operand: it is the borrowed ZP_PTR_GP ($C4), saved and
; restored around grp_entry (see hw.inc).
FP              = $24D2         ; (overlaps L_X1: fill and
                                ;  line never run together)
GP_PTR          = ZP_PTR_GP     ; (was ZP $34, aliasing L_SX)

        .segment "GRPCODE"

; ===================================================================
; Entry from the bank-2 stub: dispatch, then restore MPR6.
; ===================================================================
grp_entry:
        lda     ZP_PTR_GP       ; save the borrowed pointer
        sta     GP_PTR_SAV      ; cell's caller bytes (restored
        lda     ZP_PTR_GP+1     ; below; net effect zero). A is
        sta     GP_PTR_SAV+1    ; dead here (the relay set it
                                ; to the bank number $03)
        jsr     grp_dispatch
        lda     GP_PTR_SAV      ; restore the borrowed pointer
        sta     ZP_PTR_GP
        lda     GP_PTR_SAV+1
        sta     ZP_PTR_GP+1
        ; Plain RTS, deliberately WITHOUT an MPR6 restore
        ; here: this code executes inside the MPR6 window, so
        ; a TAM back to bank 2 would make the RTS itself be
        ; fetched from bank 2 at this address (the same trap
        ; as the forward switch; see exbios.s). The return
        ; lands in ex_tramp_inline (fixed bank 0), which
        ; restores the caller's MPR6 from the stack.
        rts

; Bank-switch relay, second half (see exbios.s / cfg):
; exb_grp (bank 2, $DFF0) executes lda #$03 / tam #$40; the
; next fetch comes from THIS bank at $DFF4.
        .segment "GRPRELAY"
grp_relay:
        jmp     grp_entry
        .segment "GRPCODE"

grp_dispatch:
        lda     ARG_DH
        cmp     #$10
        bcs     gd_noop         ; DH >= 16: undefined on the
                                ; genuine; a no-op is the
                                ; spec-sanctioned reading
        asl     a
        tax
        lda     gd_tab+1,x
        pha
        lda     gd_tab,x
        pha
        rts
gd_noop:
        rts

gd_tab:
        .word   g_init-1        ; 0  GRP_GINIT
        .word   g_cashclr-1     ; 1  GRP_CASHCLR
        .word   g_strtadr-1     ; 2  GRP_STRTADR
        .word   g_getadrs-1     ; 3  GRP_GETADRS
        .word   g_cls-1         ; 4  GRP_CLS
        .word   g_pset-1        ; 5  GRP_PSET
        .word   g_point-1       ; 6  GRP_POINT
        .word   g_line-1        ; 7  GRP_LINE
        .word   g_box-1         ; 8  GRP_BOX
        .word   g_boxf-1        ; 9  GRP_BOXF
        .word   g_flood-1       ; 10 GRP_FLOOD
        .word   g_paint-1       ; 11 GRP_PAINT
        .word   g_window-1      ; 12 GRP_GWINDOW
        .word   g_font-1        ; 13 GRP_GFONT
        .word   g_putfont-1     ; 14 GRP_PUTFONT
        .word   g_symbol-1      ; 15 GRP_SYMBOL

; ===================================================================
; VDC helpers (the core's established access patterns: MAWR /
; MARR through vdc_write, VRR/VWR streamed on VDCDAT, with
; the priming dummy read pair extest6 established).
; ===================================================================

; The word helpers move data through WT0/WT1, reserved for
; them alone.
WT0             = GRP_PRIV + 32
WT1             = GRP_PRIV + 33
; R2 fill/window private cells
GW_B4           = GRP_PRIV + 34 ; GWINDOW: GINIT base >> 4 (2)
GW_STEP         = GRP_PRIV + 36 ; GWINDOW: row step 32-w (2)
GW_SUM          = GRP_PRIV + 38 ; GWINDOW: p + (base>>4) (2)
GW_ROW          = GRP_PRIV + 40 ; GWINDOW write row
GW_COL          = GRP_PRIV + 41 ; GWINDOW write column
GW_POS          = GRP_PRIV + 42 ; GWINDOW grid position (2)
GW_W            = GRP_PRIV + 44 ; GWINDOW width (exact _CH)
GW_H            = GRP_PRIV + 45 ; GWINDOW height
; (R6, SB-20; R7, SB-21) vi_padrs model. The POINT carry
; factor lives in GRP_PADRS itself ($20DE, the genuine's
; own cell -- BIOS ZP, boot-cleared to $0000, outside the
; $2800 IPL load area, so no private mirror is needed;
; the R5 one-shot cell at $20E3 is retired). Measured
; transitions implemented here (spec 4.2 DH 6, R7 table):
; boot $0000; GINIT -> $FFFF; CASHCLR -> $FFFF; POINT ->
; (y << 8) | (x & $F8) of its own point, unconditionally;
; PSET -> the same function of its point; LINE -> the
; same function of its END point; BOX -> a geometry-
; dependent residue (unmeasured function; the last word
; address touched is kept as the reading); FLOOD/PAINT ->
; a scan-traversal residue (the GINIT paint-stack _BX
; class values are the zeroed-screen reference case; see
; gf_padrs). BOXF, GETADRS, GFONT, PUTFONT, SYMBOL,
; GWINDOW, CLS and STRTADR do not write the word.
G_RAWSTK        = GRP_PRIV + 46 ; raw GINIT paint-stack _BX (2)
G_INITED        = GRP_PRIV + 48 ; nonzero once GINIT has run
                                ;   (GRP_PRIV sits inside the
                                ;   $2800 IPL load area, so
                                ;   these cells are only read
                                ;   after GINIT has written
                                ;   them -- the fill path
                                ;   checks G_INITED first and
                                ;   GINIT always writes all
                                ;   three bytes).

; g_wr_word: write WT0 (lo) / WT1 (hi) at GW_ADDR.
g_wr_word:
        ldy     #VDC_MAWR
        ldx     GW_ADDR
        lda     GW_ADDR+1
        jsr     vdc_write
        lda     #VDC_VWR
        sta     a:VDC_SEL
        lda     WT0
        sta     a:VDC_DLO
        lda     WT1
        sta     a:VDC_DHI
        rts

; g_rd_word: read the word at GW_ADDR into WT0 (lo) / WT1 (hi).
g_rd_word:
        ldy     #VDC_MARR
        ldx     GW_ADDR
        lda     GW_ADDR+1
        jsr     vdc_write
        lda     #VDC_VRR
        sta     a:VDC_SEL
        lda     a:VDC_DLO       ; priming pair (discarded)
        lda     a:VDC_DHI
        lda     a:VDC_DLO
        sta     WT0
        lda     a:VDC_DHI
        sta     WT1
        rts

; g_rd_planes / g_wr_planes: all four plane bytes at GW_ADDR
; (the word at GW_ADDR is planes 0/1, at GW_ADDR+8 planes 2/3).
g_rd_planes:
        jsr     g_rd_word
        lda     WT0
        sta     GP0
        lda     WT1
        sta     GP1
        lda     GW_ADDR
        clc
        adc     #$08
        sta     GW_ADDR
        bcc     grp_rd2
        inc     GW_ADDR+1
grp_rd2:
        jsr     g_rd_word
        lda     WT0
        sta     GP2
        lda     WT1
        sta     GP3
        lda     GW_ADDR
        sec
        sbc     #$08
        sta     GW_ADDR
        bcs     grp_rd3
        dec     GW_ADDR+1
grp_rd3:
        rts

g_wr_planes:
        lda     GP0
        sta     WT0
        lda     GP1
        sta     WT1
        jsr     g_wr_word       ; planes 0/1
        lda     GW_ADDR
        clc
        adc     #$08
        sta     GW_ADDR
        bcc     grp_wr2
        inc     GW_ADDR+1
grp_wr2:
        lda     GP2
        sta     WT0
        lda     GP3
        sta     WT1
        jsr     g_wr_word       ; planes 2/3
        lda     GW_ADDR
        sec
        sbc     #$08
        sta     GW_ADDR
        bcs     grp_wr3
        dec     GW_ADDR+1
grp_wr3:
        rts

; g_addr: GW_ADDR = word address of pixel (PX, PY);
; A = bit mask for the pixel ($80 >> (PX & 7)).
g_addr:
        lda     GRP_BASE        ; start from the GINIT base
        sta     GW_ADDR
        lda     GRP_BASE+1
        sta     GW_ADDR+1
        lda     PY              ; (y>>3) * $200: hi += (y>>3)*2
        lsr     a
        lsr     a
        lsr     a
        asl     a
        clc
        adc     GW_ADDR+1
        sta     GW_ADDR+1
        lda     PY              ; + (y & 7)
        and     #$07
        clc
        adc     GW_ADDR
        sta     GW_ADDR
        bcc     ga_x
        inc     GW_ADDR+1
ga_x:
        lda     PX              ; + (x>>3) * $10 (9-bit term:
        and     #$F8            ; the asl carry is the high
        asl     a               ; bit for x >= 128 -- the
        sta     GW_ADDR+2       ; original code dropped it,
        lda     #$00            ; so pixel ops at x >= 128
        rol     a               ; landed $100 words low)
        sta     GW_ADDR+3
        lda     GW_ADDR
        clc
        adc     GW_ADDR+2
        sta     GW_ADDR
        lda     GW_ADDR+1
        adc     GW_ADDR+3
        sta     GW_ADDR+1
ga_m:
        lda     PX              ; mask = $80 >> (x & 7)
        and     #$07
        tax
        lda     #$80
        cpx     #$00
        beq     ga_done
ga_ml:
        lsr     a
        dex
        bne     ga_ml
ga_done:
        rts

; g_pset_core: set pixel (PX, PY) to colour PCOL.
g_pset_core:
        jsr     g_addr
        sta     PMASK
        jsr     g_rd_planes
        lda     PMASK
        eor     #$FF
        sta     PINV
        lda     PCOL
        lsr     a
        bcc     gps_p0c
        lda     GP0
        ora     PMASK
        sta     GP0
        bra     gps_p1
gps_p0c:
        lda     GP0
        and     PINV
        sta     GP0
gps_p1:
        lda     PCOL
        lsr     a
        lsr     a
        bcc     gps_p1c
        lda     GP1
        ora     PMASK
        sta     GP1
        bra     gps_p2
gps_p1c:
        lda     GP1
        and     PINV
        sta     GP1
gps_p2:
        lda     PCOL
        lsr     a
        lsr     a
        lsr     a
        bcc     gps_p2c
        lda     GP2
        ora     PMASK
        sta     GP2
        bra     gps_p3
gps_p2c:
        lda     GP2
        and     PINV
        sta     GP2
gps_p3:
        lda     PCOL
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        bcc     gps_p3c
        lda     GP3
        ora     PMASK
        sta     GP3
        bra     gps_w
gps_p3c:
        lda     GP3
        and     PINV
        sta     GP3
gps_w:
        jsr     g_wr_planes
        rts

; g_point_core: A = colour of pixel (PX, PY).
g_point_core:
        jsr     g_addr
        sta     PMASK
        jsr     g_rd_planes
        lda     #$00
        sta     PACC            ; colour accumulator
        lda     GP0
        and     PMASK
        beq     gpt_1
        lda     #$01
        sta     PACC
gpt_1:
        lda     GP1
        and     PMASK
        beq     gpt_2
        lda     PACC
        ora     #$02
        sta     PACC
gpt_2:
        lda     GP2
        and     PMASK
        beq     gpt_3
        lda     PACC
        ora     #$04
        sta     PACC
gpt_3:
        lda     GP3
        and     PMASK
        beq     gpt_d
        lda     PACC
        ora     #$08
        sta     PACC
gpt_d:
        lda     PACC
        rts

; ===================================================================
; DH 0: GRP_GINIT. _AX = graphic base, _BX = paint stack
; area (0 = the driver's default). Mirrors the spec's ZP
; state cells.
; ===================================================================
g_init:
        lda     ARG_AL
        sta     GRP_BASE
        lda     ARG_AH
        sta     GRP_BASE+1
        lda     #$FF            ; (R6) GINIT leaves vi_padrs
        sta     GRP_PADRS       ; $FFFF, any base, any stack
        sta     GRP_PADRS+1
        lda     ARG_BL          ; record the RAW paint-stack
        sta     G_RAWSTK        ; _BX as passed: the FLOOD /
        lda     ARG_BH          ; PAINT vi_padrs rule keys on
        sta     G_RAWSTK+1      ; it (see gf_padrs), not on
        lda     #$01            ; the resolved default below
        sta     G_INITED
        lda     ARG_BL
        ora     ARG_BH
        beq     gi_def
        lda     ARG_BL
        sta     GRP_STACKBASE
        lda     ARG_BH
        sta     GRP_STACKBASE+1
        bra     gi_set
gi_def:
        lda     #<GRP_STKDEF
        sta     GRP_STACKBASE
        lda     #>GRP_STKDEF
        sta     GRP_STACKBASE+1
gi_set:
        lda     GRP_STACKBASE
        sta     GRP_STACKP
        sta     GRP_STACKZP
        lda     GRP_STACKBASE+1
        sta     GRP_STACKP+1
        sta     GRP_STACKZP+1
        stz     GRP_BITPAT
        rts

; DH 1: GRP_CASHCLR. Clears the pointer cache; no work-RAM
; change. (R7, SB-21) Stores $FFFF to vi_padrs -- the same
; cache-invalid value GINIT leaves. (R1, SB-10) Exit:
; X=$02, Y=0, carry clear.
g_cashclr:
        lda     #$FF
        sta     GRP_PADRS
        sta     GRP_PADRS+1
        lda     #$02
        sta     EX_XRES
        stz     EX_YRES
        rts

; DH 2: GRP_STRTADR. (R1, SB-2) OUT _AX = the GINIT
; graphic start address with the low 5 bits cleared;
; _BX is NOT a result (the first edition's paint-stack
; values were argument-area residues; in controlled
; sequences the _BX shadow reads $0000 and a staged _BX
; input does not survive) -- COMPAT3 writes $0000.
; Exit: X=$04, Y preserved, carry clear.
g_strtadr:
        lda     GRP_BASE
        and     #$E0
        sta     BM_AX
        lda     GRP_BASE+1
        sta     BM_AX+1
        stz     BM_BX
        stz     BM_BX+1
        lda     #$04
        sta     EX_XRES
        rts

; DH 3: GRP_GETADRS. IN _AH = x, _AL = y (char units).
; OUT _AX = word address, _BH = x & 7 (spec 4).
g_getadrs:
        ; The spec's worked example pins the convention:
        ; GINIT base $0800, GETADRS(8,8) -> $0A10, which is
        ; the bitmap formula applied to the char-unit inputs
        ; as given (not scaled by 8).
        lda     ARG_AH
        and     #$07
        sta     BM_BH           ; BH = x & 7 FIRST: the _AX
                                ; result store below overwrites
                                ; ARG_AH (same shadow block)
        lda     ARG_AH
        sta     PX
        lda     ARG_AL
        sta     PY
        jsr     g_addr
        lda     GW_ADDR         ; (R6) GETADRS does not touch
        sta     BM_AX           ; vi_padrs; (R7) confirmed by
        lda     GW_ADDR+1       ; direct readout at (0,0),
        sta     BM_AX+1         ; (16,16) and (255,255). The
                                ; R0-era store of the result
                                ; address into GRP_PADRS
                                ; stays removed
        lda     BM_BH           ; (R1, SB-10) X = x&7 too
        sta     EX_XRES
        stz     EX_YRES         ; Y = 0, carry clear
        rts

; DH 4: GRP_CLS. Clears the driver's screen area (base ..
; base + $3FFF words) to zero, regardless of the window
; (spec 4). The genuine leaves a small non-zero residue in
; $2000-$21FF; COMPAT3 clears exactly its screen area.
g_cls:
        ldy     #VDC_MAWR       ; MAWR = base
        ldx     GRP_BASE
        lda     GRP_BASE+1
        jsr     vdc_write
        lda     #VDC_VWR
        sta     a:VDC_SEL
        ldx     #$00            ; 16384 words = $4000 pairs
        ldy     #$40
gcls_l:
        stz     a:VDC_DLO
        stz     a:VDC_DHI
        inx
        bne     gcls_l
        dey
        bne     gcls_l
        stz     EX_XRES         ; (R1, SB-10) X=0, Y=0,
        stz     EX_YRES         ; carry clear
        rts

; DH 5: GRP_PSET. _AH = x, _AL = y (pixels), _DL = colour.
; (R7, SB-21) Stores (y << 8) | (x & $F8) of its own point
; to vi_padrs, the same transition as POINT (the store is
; made here in the dispatch wrapper, NOT in g_pset_core:
; the internal pixel writes of LINE/BOX/BOXF/fills are not
; PSET calls and make no such transition of their own).
; (R1, SB-10) Exit: Y=$02; X is an algorithm residue on
; the genuine -- unspecified, left as the caller's.
g_pset:
        lda     ARG_AH
        and     #$F8
        sta     GRP_PADRS
        lda     ARG_AL
        sta     GRP_PADRS+1
        lda     ARG_AH
        sta     PX
        lda     ARG_AL
        sta     PY
        lda     ARG_DL
        sta     PCOL
        jsr     g_pset_core
        lda     #$02
        sta     EX_YRES
        rts

; DH 6: GRP_POINT. Returns the colour in A (manual; not
; observable through the genuine's dispatch, spec 4).
; (R4, SB-16) Exit X = x & 7; exit Y is PRESERVED (the
; dispatcher keeps the caller's latched Y unless a
; function overwrites it -- POINT does not).
; (R6, SB-20; supersedes the R5 one-shot rule, which was
; an analysis-probe artifact and is withdrawn) Carry is
; SET iff BOTH hold: (a) the point lies in the bitmap's
; first word: its 4.1 offset (y>>3)*$200 + (y&7) +
; (x>>3)*$10 is 0, i.e. y = 0 and x < 8 -- independent of
; the GINIT base and of the pixel's colour; and (b) the
; driver ZP word vi_padrs (GRP_PADRS, $20DE) reads $0000
; when the call executes. There is no one-shot: with
; vi_padrs at $0000, repeated word-0 POINTs all return
; carry set.
; (R7, SB-21) vi_padrs is the driver's cached current-
; point word, and POINT itself stores to it:
; (y << 8) | (x & $F8) -- the point's y in the high byte,
; its x rounded down to the 8-pixel word in the low byte
; -- unconditionally (any pre-state, base, colour, pre-
; or post-GINIT). The R6 "(0,0) leaves $0000" anchor is
; this function at the origin. The carry above is
; evaluated from the value the word holds when the call
; executes, i.e. BEFORE this store lands: a word-0 POINT
; arriving with vi_padrs non-zero returns carry clear and
; only then leaves $0000 behind. The store therefore sits
; at the common exit below, after the carry decision.
; The transitions other calls make are implemented at
; those calls: GINIT -> $FFFF (g_init), CASHCLR -> $FFFF
; (g_cashclr), PSET -> the same function of its point
; (g_pset), LINE -> the same function of its end point
; (g_line), FLOOD/PAINT -> scan residue (gf_padrs),
; BOX -> geometry residue (g_box). BOXF, GETADRS, GFONT,
; PUTFONT, SYMBOL, GWINDOW, CLS and STRTADR do not write
; the word.
g_point:
        lda     ARG_AH
        sta     PX
        lda     ARG_AL
        sta     PY
        jsr     g_point_core
        sta     BM_RES
        lda     ARG_AH
        and     #$07
        sta     EX_XRES
        lda     ARG_AL
        bne     gp_carry_done   ; y != 0: outside word 0
        lda     ARG_AH
        cmp     #$08
        bcs     gp_carry_done   ; x >= 8: outside word 0
        lda     GRP_PADRS
        ora     GRP_PADRS+1
        bne     gp_carry_done   ; vi_padrs != $0000 (the
                                ; pre-store value decides)
        lda     #$01
        sta     BM_CARRYF
gp_carry_done:
        lda     ARG_AH          ; (R7) POINT stores
        and     #$F8            ; (y << 8) | (x & $F8) to
        sta     GRP_PADRS       ; vi_padrs, unconditionally
        lda     ARG_AL
        sta     GRP_PADRS+1
        rts

; DH 7: GRP_LINE. (_AH,_AL) -> (_BH,_BL), colour _DL.
; Integer Bresenham. (R7, SB-21) Stores
; (y << 8) | (x & $F8) of its END point (_BH,_BL) to
; vi_padrs -- made here at entry, in the dispatch
; wrapper: the loop's internal g_pset_core calls are not
; PSET calls and make no transition of their own.
g_line:
        lda     ARG_BH
        and     #$F8
        sta     GRP_PADRS
        lda     ARG_BL
        sta     GRP_PADRS+1
        lda     ARG_AH
        sta     L_X
        lda     ARG_AL
        sta     L_Y
        lda     ARG_BH
        sta     L_X1
        lda     ARG_BL
        sta     L_Y1
        lda     ARG_DL
        sta     PCOL
        ; dx = |x1 - x0|, sx = sign
        lda     #$01
        sta     L_SX
        lda     L_X1
        sec
        sbc     L_X
        bcs     gl_dx
        lda     #$FF
        sta     L_SX
        lda     L_X
        sec
        sbc     L_X1
gl_dx:
        sta     L_DX
        stz     L_DX+1
        ; dy = -|y1 - y0|, sy = sign
        lda     #$01
        sta     L_SY
        lda     L_Y1
        sec
        sbc     L_Y
        bcs     gl_dy
        lda     #$FF
        sta     L_SY
        lda     L_Y
        sec
        sbc     L_Y1
gl_dy:
        eor     #$FF            ; negate (16-bit)
        sta     L_DY
        lda     #$FF
        sta     L_DY+1
        inc     L_DY
        bne     gl_err
        inc     L_DY+1
gl_err:
        lda     L_DX            ; err = dx + dy
        clc
        adc     L_DY
        sta     L_ERR
        lda     L_DX+1
        adc     L_DY+1
        sta     L_ERR+1
gl_loop:
        lda     L_X
        sta     PX
        lda     L_Y
        sta     PY
        jsr     g_pset_core
        lda     L_X
        cmp     L_X1
        bne     gl_step
        lda     L_Y
        cmp     L_Y1
        beq     gl_done
gl_step:
        lda     L_ERR           ; e2 = 2 * err
        asl     a
        sta     GW_ADDR+2
        lda     L_ERR+1
        rol     a
        sta     GW_ADDR+3
        ; if e2 >= dy: err += dy, x += sx
        lda     GW_ADDR+2
        cmp     L_DY
        lda     GW_ADDR+3
        sbc     L_DY+1
        bvc     gl_s1
        eor     #$80
gl_s1:
        bmi     gl_s2
        lda     L_ERR
        clc
        adc     L_DY
        sta     L_ERR
        lda     L_ERR+1
        adc     L_DY+1
        sta     L_ERR+1
        lda     L_X
        clc
        adc     L_SX
        sta     L_X
gl_s2:
        ; if e2 <= dx: err += dx, y += sy
        lda     L_DX
        cmp     GW_ADDR+2
        lda     L_DX+1
        sbc     GW_ADDR+3
        bvc     gl_s3
        eor     #$80
gl_s3:
        bmi     gl_loop
        lda     L_ERR
        clc
        adc     L_DX
        sta     L_ERR
        lda     L_ERR+1
        adc     L_DX+1
        sta     L_ERR+1
        lda     L_Y
        clc
        adc     L_SY
        sta     L_Y
        jmp     gl_loop         ; (was bra: out of range since
                                ;   the C-D1 relocation made the
                                ;   loop body's cell accesses
                                ;   absolute-encoded)
gl_done:
        lda     #$02            ; (R1, SB-10) Y=$02; X and
        sta     EX_YRES         ; carry are residues --
        rts                     ; unspecified

; DH 8: GRP_BOX. Rectangle outline (_AH,_AL)-(_BH,_BL).
g_box:
        lda     ARG_DL
        sta     PCOL
        lda     ARG_AL          ; top edge
        sta     PY
        lda     ARG_AH
        sta     PX
gb_t:
        jsr     g_pset_core
        inc     PX
        lda     PX
        cmp     ARG_BH
        bne     gb_t
        jsr     g_pset_core     ; corner
        lda     ARG_BL          ; bottom edge
        sta     PY
        lda     ARG_AH
        sta     PX
gb_b:
        jsr     g_pset_core
        inc     PX
        lda     PX
        cmp     ARG_BH
        bne     gb_b
        jsr     g_pset_core
        lda     ARG_AH          ; left edge
        sta     PX
        lda     ARG_AL
        sta     PY
gb_l:
        jsr     g_pset_core
        inc     PY
        lda     PY
        cmp     ARG_BL
        bne     gb_l
        lda     ARG_BH          ; right edge
        sta     PX
        lda     ARG_AL
        sta     PY
gb_r:
        jsr     g_pset_core
        inc     PY
        lda     PY
        cmp     ARG_BL
        bne     gb_r
        lda     GW_ADDR         ; (R6) BOX leaves vi_padrs
        sta     GRP_PADRS       ; non-zero: the residue kept
        lda     GW_ADDR+1       ; here is the last word
        sta     GRP_PADRS+1     ; address the box loop
                                ; touched (the genuine's one
                                ; measured value, $0908 after
                                ; BOX (5,3)-(15,10) at base
                                ; $0800, is a residue of the
                                ; same kind; exact values are
                                ; unspecified by the spec)
        lda     #$02            ; (R1, SB-10) Y=$02, carry
        sta     EX_YRES         ; set; X is a residue
        lda     #$01
        sta     BM_CARRYF
        rts

; DH 9: GRP_BOXF. Filled rectangle.
g_boxf:
        lda     ARG_DL
        sta     PCOL
        lda     ARG_AL
        sta     PY
gbf_y:
        lda     ARG_AH
        sta     PX
gbf_x:
        jsr     g_pset_core
        lda     PX
        cmp     ARG_BH
        beq     gbf_rowdone
        inc     PX
        bra     gbf_x
gbf_rowdone:
        lda     PY
        cmp     ARG_BL
        beq     gbf_done
        inc     PY
        bra     gbf_y
gbf_done:
        ; (R7, SB-21) BOXF does NOT write vi_padrs (a $1234
        ; pre-state survives it on the genuine), unlike
        ; BOX. The R6 reading kept here until R7 -- BOXF
        ; storing the last word address touched, as the
        ; filled variant of BOX -- is superseded and the
        ; store is removed.
        lda     #$02            ; (R1, SB-10) Y=$02, carry
        sta     EX_YRES         ; set; X is a residue
        lda     #$01
        sta     BM_CARRYF
        rts

; ===================================================================
; DH 10/11: GRP_FLOOD / GRP_PAINT. The documented
; connected-region / border-bounded interior fill was
; never observed on the genuine card in this environment;
; the contracts below are the measured semantics, pinned
; by the FLOOD/PAINT retest round and send-back round 2
; (spec 4.2 DH 10/11 as revised at R4; 6 items 1-2, 10).
; Both calls act on row y=0 only, at the graphic base.
; Exit X/Y/_AX are residues on the genuine -- unspecified,
; left as the caller's; carry is clear unless stated.
; (R6, SB-20) Both calls also rewrite vi_padrs in every
; form -- filling, no-op, masked and seed==fill alike:
; the value is decided by the GINIT paint-stack _BX (see
; gf_padrs). This replaces the withdrawn R5 one-shot
; reading; see g_point for the carry contract.
; (R7, SB-21) The fills' residue is a scan-traversal
; residue: the stack-class values are the measured
; behaviour on a zeroed screen; over arbitrary screen
; content the residue varies with the traversal and is
; unspecified, so the stack-class behaviour is kept as
; the reference-case reading.
;
; FLOOD (R4): if the seed point's colour is non-zero the
; call is a complete no-op. If it is 0, the fill colour is
; written across row y=0, SKIPPING pixels whose colour is
; not 0 -- the write does not stop at them (contrast
; PAINT's stop rule). The seed's coordinates are otherwise
; ignored, and the effect is idempotent. (With
; GWINDOW-written character codes in the bitmap area the
; genuine FLOOD's behaviour is erratic -- partial fills,
; erasure, non-returns; spec 4.2 DH 10 lists the outcomes
; as environment behaviour implementations are NOT
; required to match, so no such behaviour is implemented
; here. GWINDOW below does write the codes, and CLS
; clears them.)
;
; PAINT (R4, SB-14): the gate is the SEED COLOUR's own
; bit in the border mask _BX (bit c of _BX tests colour
; c). Every call first writes the work table at
; $2619-$2628: entry[c] = the mask bit of colour c (0/1),
; except the fill colour's entry = its mask bit + 1 (1 or
; 2); and exit _BH = 0. Then: seed colour == fill colour
; -> no fill, carry SET (the only carry-set PAINT). Seed
; colour's mask bit set -> nothing at all (carry clear).
; Otherwise the call scans row y=0 from x=0, overwriting
; every pixel whose colour's mask bit is clear, and
; STOPS at the first pixel whose colour's mask bit is
; set. (The table and _BH are written on every path --
; the spec states both unconditionally.)
; ===================================================================
g_flood:
        jsr     gf_padrs        ; (R6) any FLOOD rewrites
                                ; vi_padrs, even a no-op one
        jsr     gf_seedcolour   ; A = colour of the seed
        bne     gf_ret          ; non-zero: complete no-op
        lda     ARG_DL          ; seed colour 0: fill row 0,
        sta     PCOL            ; skipping non-zero pixels
        stz     PY
        stz     PX
gf_loop:
        jsr     g_point_core    ; A = colour at (PX, 0)
        bne     gf_skip         ; non-zero: skip, keep going
        jsr     g_pset_core
gf_skip:
        inc     PX
        bne     gf_loop
gf_ret:
        rts

g_paint:
        jsr     gf_padrs        ; (R6) any PAINT rewrites
                                ; vi_padrs, on every path
        lda     ARG_BL
        sta     F_BORDL
        lda     ARG_BH
        sta     F_BORDH
        stz     BM_BH           ; exit _BH = 0, always
        ldx     #$00            ; work table $2619-$2628:
gpt_loop:                       ; entry[c] = mask bit c,
        txa                     ; fill colour's = bit + 1
        jsr     gp_maskbit
        cpx     ARG_DL
        bne     gpt_st
        inc     a
gpt_st:
        sta     GRP_GLYPHREC,x
        inx
        cpx     #$10
        bne     gpt_loop
        jsr     gf_seedcolour   ; A = seed colour
        cmp     ARG_DL
        beq     gp_same         ; seed == fill: carry set
        jsr     gp_maskbit      ; seed colour's mask bit
        bne     gf_ret          ; set: nothing at all
        lda     ARG_DL          ; scan row 0 from x=0
        sta     PCOL
        stz     PY
        stz     PX
gp_loop:
        jsr     g_point_core    ; A = colour at (PX, 0)
        jsr     gp_maskbit
        bne     gf_ret          ; masked pixel: STOP
        jsr     g_pset_core
        inc     PX
        bne     gp_loop
        rts
gp_same:
        lda     #$01
        sta     BM_CARRYF
        rts

; gp_maskbit: A = colour (0-15) -> A = its bit in the
; border mask copy (F_BORDL/F_BORDH): 0 or 1.
; Clobbers A only (X is preserved for the table loop).
gp_maskbit:
        phx
        cmp     #$08
        bcs     gpm_hi
        tax
        lda     F_BORDL
        bra     gpm_sh
gpm_hi:
        sec
        sbc     #$08
        tax
        lda     F_BORDH
gpm_sh:
        cpx     #$00
        beq     gpm_bit
gpm_l:
        lsr     a
        dex
        bne     gpm_l
gpm_bit:
        plx                     ; restore X first: PLX sets
        and     #$01            ; the flags, so this AND must
        rts                     ; be last (Z reflects the bit)

; gf_padrs: the FLOOD/PAINT vi_padrs transition (R6,
; SB-20; spec 4.2 DH 6). Measured anchors: with the GINIT
; paint-stack _BX in {$0000, $2616} the fills leave
; vi_padrs $0000; with _BX in {$2000, $3000} they leave it
; non-zero ($FEF8 measured for FLOOD, seed (0,0) colour 7,
; at both) -- seed, mask, fill colour and base do not
; decide it, and even a no-op FLOOD rewrites the word.
; (R7, SB-21) Those anchors are the zeroed-screen case,
; re-measured directly at R7; over arbitrary content the
; residue is traversal-dependent and unspecified. The
; stack-class behaviour below is kept as the reference
; reading.
; Reading for unmeasured _BX values: the two measured
; zero anchors are the special cases; every other stack
; address falls in the non-zero class and leaves the one
; measured non-zero value, $FEF8 (PAINT's exact non-zero
; value is unmeasured; the same value is used). Before
; any GINIT the word is left unchanged (unmeasured; at
; boot it already reads $0000).
gf_padrs:
        lda     G_INITED
        beq     gfp_ret         ; no GINIT yet: unchanged
        lda     G_RAWSTK
        ora     G_RAWSTK+1
        beq     gfp_zero        ; _BX = $0000
        lda     G_RAWSTK
        cmp     #$16
        bne     gfp_nz
        lda     G_RAWSTK+1
        cmp     #$26
        beq     gfp_zero        ; _BX = $2616
gfp_nz:
        lda     #$F8
        sta     GRP_PADRS
        lda     #$FE
        sta     GRP_PADRS+1
        rts
gfp_zero:
        stz     GRP_PADRS
        stz     GRP_PADRS+1
gfp_ret:
        rts

; gf_seedcolour: A = colour of the seed pixel (ARG_AH,
; ARG_AL). Clobbers PX/PY and the plane scratch.
gf_seedcolour:
        lda     ARG_AH
        sta     PX
        lda     ARG_AL
        sta     PY
        jmp     g_point_core

; DH 12: GRP_GWINDOW. _AH/_AL = window start (chars),
; _CH = width (chars), _CL = height (chars), _DL = colour
; bank. (R4, SB-12/13; spec 4.2 DH 12) A character-window
; initializer, not a clip window: the call writes exactly
; _CH x _CL character codes starting at VRAM word $0000
; -- NOT at the graphic base -- in a 32-cell-wide grid:
; the word at VRAM $0000 + p, p = row*32 + col (row-major,
; stride 32), holds code = (_DL << 12) | (p + (GINIT
; _AX >> 4)). The _AH/_AL origin never offsets the
; writing; the value's low part tracks the absolute grid
; position plus the graphic base's high bits. Exit X =
; _CH exactly, Y = 0, carry clear; the shadow inputs are
; preserved. The window does not limit CLS (spec 4.2
; DH 4). (The GRP_WIN/GRP_PORG state stores predate the
; R4 pin and are kept; they are not part of the measured
; contract either way.)
g_window:
        lda     ARG_CH          ; exit X = _CH, set first:
        sta     EX_XRES         ; it holds even on the
        stz     EX_YRES         ; zero-extent paths
        lda     ARG_AH
        sta     GRP_WIN
        sta     GRP_PORG
        lda     ARG_AL
        sta     GRP_WIN+1
        lda     ARG_CH
        sta     GRP_WIN+2
        sta     GW_W
        lda     ARG_CL
        sta     GRP_WIN+3
        sta     GW_H
        lda     ARG_DL
        sta     GRP_WIN+4
        lda     GW_W
        bne     gw_wok1
        jmp     gw_done         ; zero width: no extent
gw_wok1:
        lda     GW_H
        bne     gw_wok2
        jmp     gw_done         ; zero height: no extent
gw_wok2:
        lda     GRP_BASE+1      ; GW_B4 = GRP_BASE >> 4:
        lsr     a               ; high byte = base_hi >> 4
        lsr     a
        lsr     a
        lsr     a
        sta     GW_B4+1
        lda     GRP_BASE+1      ; low byte = (base_lo >> 4)
        asl     a               ; | (base_hi << 4)
        asl     a
        asl     a
        asl     a
        sta     GW_SUM          ; (scratch; GW_SUM is
        lda     GRP_BASE        ; rewritten per cell)
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        ora     GW_SUM
        sta     GW_B4
        lda     #$20            ; GW_STEP = 32 - width
        sec                     ; (16-bit, signed: a width
        sbc     GW_W            ; above 32 steps backwards)
        sta     GW_STEP
        lda     #$00
        sbc     #$00
        sta     GW_STEP+1
        stz     GW_ROW
        stz     GW_POS
        stz     GW_POS+1
gw_row:
        stz     GW_COL
gw_cell:
        lda     GW_POS          ; word at VRAM $0000 + p
        sta     GW_ADDR
        lda     GW_POS+1
        sta     GW_ADDR+1
        lda     GW_POS          ; value = (DL<<12) |
        clc                     ; (p + (base >> 4)), the
        adc     GW_B4           ; whole sum as one 16-bit
        sta     GW_SUM          ; OR (DL's own bits wrap
        lda     GW_POS+1        ; out above bit 15)
        adc     GW_B4+1
        sta     GW_SUM+1
        lda     ARG_DL
        asl     a
        asl     a
        asl     a
        asl     a
        ora     GW_SUM+1
        sta     WT1
        lda     GW_SUM
        sta     WT0
        jsr     g_wr_word
        inc     GW_POS
        bne     gw_n1
        inc     GW_POS+1
gw_n1:
        inc     GW_COL
        lda     GW_COL
        cmp     GW_W
        bne     gw_cell
        lda     GW_POS          ; next grid row:
        clc                     ; pos += 32 - width
        adc     GW_STEP
        sta     GW_POS
        lda     GW_POS+1
        adc     GW_STEP+1
        sta     GW_POS+1
        inc     GW_ROW
        lda     GW_ROW
        cmp     GW_H
        bne     gw_row
gw_done:
        rts

; DH 13: GRP_GFONT. _AL = font size (0 = 16-dot, 1 = 12,
; 2 = 8, 4 = user; 3 also accepted). X = $1A, carry clear.
g_font:
        lda     ARG_AL
        sta     GRP_FONTSEL
        lda     #$1A
        sta     EX_XRES
        rts

; ===================================================================
; DH 14/15: GRP_PUTFONT / GRP_SYMBOL. _AH/_AL = position in
; char units, _BX = font number (a JIS code: BH = ku,
; BL = ten), _CL bits 0-3 = back colour, bit 6 = back
; transparent, bit 7 = fore transparent, _DL = fore colour.
; SYMBOL adds _CL bits 4-5 = font select and _CH =
; magnification (low nibble X, high nibble Y). Returns
; _BX = $2619 (the glyph record area), X = $01, carry set
; (spec 4). Glyphs come from COMPAT3's own KH font data.
; ===================================================================
g_putfont:
        lda     #$01            ; magnification 1 x 1
        sta     GL_MX
        sta     GL_MY
        lda     GRP_FONTSEL     ; size from GFONT selection
        jsr     g_fontsize
        bra     g_render
g_symbol:
        lda     ARG_CH
        and     #$0F
        bne     gs_mx
        lda     #$01
gs_mx:
        sta     GL_MX
        lda     ARG_CH
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        bne     gs_my
        lda     #$01
gs_my:
        sta     GL_MY
        lda     ARG_CL          ; font select in bits 4-5
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        and     #$03
        jsr     g_fontsize
        bra     g_render

; g_fontsize: A = select (0 = 16-dot, 1 = 12-dot, 2 = 8-dot,
; 3/4 = user). Sets GL_W / GL_H; user font sets GL_W = 0
; (no glyph source: nothing renders).
g_fontsize:
        cmp     #$00
        beq     gfs_16
        cmp     #$01
        beq     gfs_12
        cmp     #$02
        beq     gfs_8
        bra     gfs_user
gfs_16:
        lda     #$10            ; 0 -> 16-dot
        sta     GL_W
        sta     GL_H
        rts
gfs_12:
        lda     #$0C
        sta     GL_W
        sta     GL_H
        rts
gfs_8:
        lda     #$08
        sta     GL_W
        sta     GL_H
        rts
gfs_user:
        stz     GL_W
        stz     GL_H
        rts

gr_setbx:
        lda     #$19
        sta     BM_BX
        lda     #$26
        sta     BM_BX+1
        rts

g_render:
        ; returns: _BX = $2619, X = $01, carry set. The _BX
        ; store is deferred until after g_glyph_index: _BX
        ; shares the shadow block with the font-number
        ; input (ARG_BL/ARG_BH), which the index computation
        ; still has to read.
        lda     #$01
        sta     EX_XRES
        sta     BM_CARRYF
        lda     GL_W
        bne     gr_idx
        jsr     gr_setbx
        rts                     ; user font: nothing renders
gr_idx:
        jsr     g_glyph_index   ; JIS ku/ten -> GL_IDX
        jsr     gr_setbx
        bcs     gr_blank        ; unassigned code: blank
        jsr     g_glyph_fetch   ; -> glyph record at $2619
        bra     gr_draw
gr_blank:
        ldx     #$1F            ; zero the record (blank)
        lda     #$00
gr_bl:
        sta     GRP_GLYPHREC,x
        dex
        bpl     gr_bl
gr_draw:
        ; base pixel = char position * 8
        lda     ARG_AH
        asl     a
        asl     a
        asl     a
        sta     GL_BASEX
        stz     GL_BASEX+1
        lda     ARG_AL
        asl     a
        asl     a
        asl     a
        sta     GL_BASEY
        stz     GL_BASEY+1
        stz     GL_ROW
gr_row:
        lda     GL_ROW
        cmp     GL_H
        bcs     gr_r
        jsr     g_rowbits       ; GL_BITS = glyph row bits
        stz     GL_COL
gr_col:
        lda     GL_COL
        cmp     GL_W
        bcs     gr_rownext
        ; bit (GL_W-1-GL_COL) of GL_BITS: shift a copy
        ; right by (GL_W-1-GL_COL) and test bit 0
        lda     GL_W
        sec
        sbc     GL_COL
        sta     SH_N            ; shifts + 1
        lda     GL_BITS
        sta     SH_LO
        lda     GL_BITS+1
        sta     SH_HI
gr_sh:
        dec     SH_N
        beq     gr_bit
        lsr     SH_HI
        ror     SH_LO
        bra     gr_sh
gr_bit:
        lda     SH_LO
        lsr     a               ; bit -> carry
        bcs     gr_fore
        ; background pixel
        lda     ARG_CL
        and     #$40
        bne     gr_colnext      ; back transparent
        lda     ARG_CL
        and     #$0F
        sta     PCOL
        bra     gr_plot
gr_fore:
        lda     ARG_CL
        and     #$80
        bne     gr_colnext      ; fore transparent
        lda     ARG_DL
        sta     PCOL
gr_plot:
        jsr     g_plot_mag
gr_colnext:
        inc     GL_COL
        bra     gr_col
gr_rownext:
        inc     GL_ROW
        bra     gr_row
gr_r:
        rts

; g_plot_mag: plot PCOL at the magnified cell for
; (GL_COL, GL_ROW). PX = basex + col*mx + dx, PY = basey +
; row*my + dy (byte arithmetic; char positions are small).
g_plot_mag:
        stz     GL_DY
gpm_y:
        stz     GL_DX
gpm_x:
        ldx     GL_MX           ; A = col * mx
        lda     #$00
gpm_mx:
        clc
        adc     GL_COL
        dex
        bne     gpm_mx
        clc
        adc     GL_BASEX
        adc     GL_DX
        sta     PX
        ldx     GL_MY           ; A = row * my
        lda     #$00
gpm_my:
        clc
        adc     GL_ROW
        dex
        bne     gpm_my
        clc
        adc     GL_BASEY
        adc     GL_DY
        sta     PY
        jsr     g_pset_core
        inc     GL_DX
        lda     GL_DX
        cmp     GL_MX
        bne     gpm_x
        inc     GL_DY
        lda     GL_DY
        cmp     GL_MY
        bne     gpm_y
        rts

; g_glyph_index: font number _BX as a JIS code (BH = ku,
; BL = ten) -> linear glyph index in GL_IDX; carry set if
; the code is outside the level-1 ranges COMPAT3 serves
; (ku 1-7 and 16-47 -- the same coverage as EX_GETFNT).
g_glyph_index:
        lda     ARG_BH          ; ku
        cmp     #$01
        bcc     ggi_bad
        cmp     #$08
        bcc     ggi_low
        cmp     #$10
        bcc     ggi_bad
        cmp     #$30
        bcs     ggi_bad
        ; ku 16-47: idx = 658 + (ku-16)*94 + (ten-1)
        sec
        sbc     #$10
        jsr     ggi_mul94
        lda     GL_IDX
        clc
        adc     #<658
        sta     GL_IDX
        lda     GL_IDX+1
        adc     #>658
        sta     GL_IDX+1
        bra     ggi_ten
ggi_low:                        ; ku 1-7: idx = (ku-1)*94 +
        sec                     ; (ten-1)
        sbc     #$01
        jsr     ggi_mul94
ggi_ten:
        lda     ARG_BL          ; ten
        beq     ggi_bad
        cmp     #$5F
        bcs     ggi_bad
        sec
        sbc     #$01
        clc
        adc     GL_IDX
        sta     GL_IDX
        bcc     ggi_ok
        inc     GL_IDX+1
ggi_ok:
        clc
        rts
ggi_bad:
        sec
        rts

; ggi_mul94: A (0-31) -> GL_IDX = A * 94.
ggi_mul94:
        sta     GW_ADDR+2
        stz     GL_IDX
        stz     GL_IDX+1
        tax
        beq     ggm_r
ggm_l:
        lda     GL_IDX
        clc
        adc     #94
        sta     GL_IDX
        bcc     ggm_n
        inc     GL_IDX+1
ggm_n:
        dex
        bne     ggm_l
ggm_r:
        rts

; g_glyph_fetch: copy the glyph for GL_IDX from COMPAT3's
; packed KH font (through MPR5, the fnbios layout) into
; the glyph record at GRP_GLYPHREC. 16/8-dot: bank
; 4 + idx/256, offset (idx & $FF) * 32, 32 bytes. 12-dot:
; bank 19 + idx/341, offset (idx mod 341) * 24, 24 bytes.
g_glyph_fetch:
        tma     #$20
        pha                     ; save caller MPR5
        lda     GL_W
        cmp     #$0C
        beq     ggf_12
        ; 16-dot layout (also the 8-dot source)
        lda     GL_IDX+1
        clc
        adc     #$04
        tam     #$20
        lda     GL_IDX          ; offset = low byte * 32
        stz     GP_PTR+1
        asl     a
        rol     GP_PTR+1
        asl     a
        rol     GP_PTR+1
        asl     a
        rol     GP_PTR+1
        asl     a
        rol     GP_PTR+1
        asl     a
        rol     GP_PTR+1
        sta     GP_PTR
        lda     GP_PTR+1
        clc
        adc     #$A0
        sta     GP_PTR+1
        ldy     #$00
ggf_16:
        lda     (GP_PTR),y
        sta     GRP_GLYPHREC,y
        iny
        cpy     #$20
        bne     ggf_16
        bra     ggf_done
ggf_12:
        ; idx / 341 by repeated subtraction; remainder
        ; stays in GW_ADDR, quotient in X
        lda     GL_IDX
        sta     GW_ADDR
        lda     GL_IDX+1
        sta     GW_ADDR+1
        ldx     #$00
ggf12_l:
        lda     GW_ADDR
        sec
        sbc     #<341
        tay
        lda     GW_ADDR+1
        sbc     #>341
        bcc     ggf12_d
        sta     GW_ADDR+1
        tya
        sta     GW_ADDR
        inx
        bra     ggf12_l
ggf12_d:
        txa
        clc
        adc     #19
        tam     #$20
        ; offset = remainder * 24 (24 additions)
        lda     GW_ADDR
        sta     SH_LO           ; remainder (2)
        lda     GW_ADDR+1
        sta     SH_HI
        stz     GP_PTR
        stz     GP_PTR+1
        ldx     #24
ggf12_m:
        clc
        lda     GP_PTR
        adc     SH_LO
        sta     GP_PTR
        lda     GP_PTR+1
        adc     SH_HI
        sta     GP_PTR+1
        dex
        bne     ggf12_m
        lda     GP_PTR+1
        clc
        adc     #$A0
        sta     GP_PTR+1
        ldy     #$00
ggf12_c:
        lda     (GP_PTR),y
        sta     GRP_GLYPHREC,y
        iny
        cpy     #$18
        bne     ggf12_c
        lda     #$00            ; zero the record's tail
ggf12_z:
        sta     GRP_GLYPHREC,y
        iny
        cpy     #$20
        bne     ggf12_z
ggf_done:
        pla
        tam     #$20            ; restore caller MPR5
        rts

; g_rowbits: GL_BITS = the GL_ROW-th glyph row as a value
; whose bit (GL_W-1) is the leftmost pixel. The record
; stores rows big-endian (first byte = leftmost 8 pixels,
; MSB first).
g_rowbits:
        lda     GL_ROW
        asl     a
        tax                     ; record offset = row * 2
        lda     GL_W
        cmp     #$08
        beq     grb_8
        cmp     #$0C
        beq     grb_12
        lda     GRP_GLYPHREC,x  ; 16-dot: value = rec word
        sta     GL_BITS+1
        lda     GRP_GLYPHREC+1,x
        sta     GL_BITS
        rts
grb_12:                         ; 12-dot: value = word >> 4
        lda     GRP_GLYPHREC,x
        sta     GL_BITS+1
        lda     GRP_GLYPHREC+1,x
        sta     GL_BITS
        ldx     #$04
grb_12s:
        lsr     GL_BITS+1
        ror     GL_BITS
        dex
        bne     grb_12s
        rts
grb_8:                          ; 8-dot: left byte only
        lda     GRP_GLYPHREC,x
        sta     GL_BITS
        stz     GL_BITS+1
        rts
