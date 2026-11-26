; COMPAT3 EX/MA BIOS -- bank 2, segment EXCODE (p009).
; Clean-room implementation from public documentation (zeograd
; BIOS document; Hudson Hu7 CD System BIOS Manual) and black-box
; differential observation of the genuine card through the public
; jump-table interface (probe discs extest..extest6, 2026-11-20).
; No NEC/Hudson code or data. The SIN/ATNI tables are computed
; from the mathematical definitions (round(sin(a deg)*256) and
; round(atan(x/64) in degrees)), which the black-box sweeps
; verified point-for-point over the documented domains.
;
; Calling convention (from bank0.s): the shared trampoline has
; saved the slot number in zp_ex_idx and the A input in zp_ex_a;
; X/Y arrive live and are latched into zp_ex_x / zp_ex_y here.
; Results return through BM_RES (A), BM_CARRYF (bit0 = carry),
; EX_XRES and EX_YRES -- the BM trampoline precedent.
; EX_XRES / EX_YRES default to the caller's X / Y (preserved);
; only functions whose genuine contract defines X/Y outputs
; overwrite them (see exb_dispatch).
        .setcpu "HuC6280"
        .include "hw.inc"

        .import vdc_write
        .import psgb_bios, psgb_drive, psgb_key
        .import grp_entry
        .export exb_dispatch, exb_colorc_go

; scratch (shared bank-2 convention; was ZP $30-$3B until the
; C-D1 relocation, layer 10 / spec_drac.md: ZP $00-$7F is the
; caller's and must survive every call byte-identical. The
; block now lives in WRAM at $24D0-$24DB, offsets and aliases
; unchanged; fnbios/grpbios/psgbios share it as before)
xs_a            = $24D0         ; operand A (2) / pointer
xs_b            = $24D2         ; operand B (2) / word count
xs_p            = $24D4         ; product / work (4)
xs_m            = $24D8         ; multiplicand (4)
xs_t            = $24D8         ; byte temp (aliases xs_m: the
xs_t2           = $24D9         ;   multiply paths do not overlap
xs_cnt          = $24DA         ;   the byte-temp paths)
xs_sign         = $24DB

        .segment "EXCODE"

; ===================================================================
; Dispatch: slot in zp_ex_idx ($1F-$50), table of (label-1) words.
; ===================================================================
exb_dispatch:
        ; zp_ex_x / zp_ex_y were latched by ex_tramp_inline
        ; (bank0.s) at stub entry -- latching here would read
        ; the trampoline's own clobbered Y ($01).
        lda     #$00
        sta     BM_RES
        sta     BM_CARRYF
        ; X/Y are PRESERVED by default: the genuine BIOS
        ; returns the caller's X/Y unchanged for every slot
        ; that does not define X/Y outputs (proven by the
        ; extest6 SQRT spot loop, which keeps its counter in
        ; X across MA_SQRT calls and only terminates because
        ; the genuine card hands X back). Functions with
        ; genuine X/Y outputs (SETVEC, SCRSIZ, DOTMOD,
        ; SCRMOD, SETRCR) overwrite EX_XRES / EX_YRES.
        ; Zeroing them here (the original p009 code) made
        ; every MA/EX call return X=0/Y=0 and wedged that
        ; loop on its second entry forever -- the "MA stall"
        ; diagnosed in ws005 item 1 (2026-11-21).
        lda     zp_ex_x
        sta     EX_XRES
        lda     zp_ex_y
        sta     EX_YRES
        lda     zp_ex_idx
        sec
        sbc     #$1F
        bcc     exb_fail
        cmp     #$32
        bcs     exb_fail
        asl     a
        tax
        lda     exb_tab+1,x
        pha
        lda     exb_tab,x
        pha
        rts
exb_fail:
        lda     #$FF
        sta     BM_RES
        lda     #$01
        sta     BM_CARRYF
        rts

exb_tab:
        .word   exb_setvec-1    ; $1F EX_SETVEC
        .word   exb_fail-1      ; $20 (EX_GETFNT lives elsewhere)
        .word   exb_joysns-1    ; $21 EX_JOYSNS
        .word   exb_fail-1      ; $22 (EX_JOYREP lives elsewhere)
        .word   exb_scrsiz-1    ; $23 EX_SCRSIZ
        .word   exb_dotmod-1    ; $24 EX_DOTMOD
        .word   exb_scrmod-1    ; $25 EX_SCRMOD
        .word   exb_imode-1     ; $26 EX_IMODE
        .word   exb_vmode-1     ; $27 EX_VMODE
        .word   exb_hmode-1     ; $28 EX_HMODE
        .word   exb_vsync-1     ; $29 EX_VSYNC
        .word   exb_rcron-1     ; $2A EX_RCRON
        .word   exb_rcroff-1    ; $2B EX_RCROFF
        .word   exb_irqon-1     ; $2C EX_IRQON
        .word   exb_irqoff-1    ; $2D EX_IRQOFF
        .word   exb_bgon-1      ; $2E EX_BGON
        .word   exb_bgoff-1     ; $2F EX_BGOFF
        .word   exb_spron-1     ; $30 EX_SPRON
        .word   exb_sproff-1    ; $31 EX_SPROFF
        .word   exb_dspon-1     ; $32 EX_DSPON
        .word   exb_dspoff-1    ; $33 EX_DSPOFF
        .word   exb_dmamod-1    ; $34 EX_DMAMOD
        .word   exb_sprdma-1    ; $35 EX_SPRDMA
        .word   exb_satclr-1    ; $36 EX_SATCLR
        .word   exb_sprput-1    ; $37 EX_SPRPUT
        .word   exb_setrcr-1    ; $38 EX_SETRCR
        .word   exb_setred-1    ; $39 EX_SETRED
        .word   exb_setwrt-1    ; $3A EX_SETWRT
        .word   exb_setdma-1    ; $3B EX_SETDMA
        .word   exb_binbcd-1    ; $3C EX_BINBCD
        .word   exb_bcdbin-1    ; $3D EX_BCDBIN
        .word   exb_rnd-1       ; $3E EX_RND
        .word   exb_mul8u-1     ; $3F MA_MUL8U
        .word   exb_mul8s-1     ; $40 MA_MUL8S
        .word   exb_mul16u-1    ; $41 MA_MUL16U
        .word   exb_div16s-1    ; $42 MA_DIV16S (signed; measured)
        .word   exb_div16u-1    ; $43 MA_DIV16U (unsigned; measured)
        .word   exb_sqrt-1      ; $44 MA_SQRT
        .word   exb_sin-1       ; $45 MA_SIN
        .word   exb_cos-1       ; $46 MA_COS
        .word   exb_atni-1      ; $47 MA_ATNI
        .word   psgb_bios-1     ; $48 PSG_BIOS (item 4, psgbios.s)
        .word   exb_grp-1       ; $49 GRP_BIOS (item 4, bank 3)
        .word   psgb_key-1      ; $4A KEY_BIOS (item 4, psgbios.s)
        .word   psgb_drive-1    ; $4B PSG_DRIVE (item 4, psgbios.s)
        .word   exb_colorc-1    ; $4C EX_COLORC
        .word   exb_stream_start-1 ; $4D AD_STREAM_START (item 2)
        .word   exb_stream_poll-1  ; $4E AD_STREAM_POLL (item 2)
        .word   exb_mul16s-1    ; $4F MA_MUL16S
        .word   exb_cbasis-1    ; $50 MA_CBASIS

; ===================================================================
; $49 GRP_BIOS lives in bank 3 (grpbios.s, segment GRPCODE).
; The bank switch CANNOT be done from inside the MPR6 window:
; a TAM that remaps MPR6 while executing in that window makes
; the very next instruction fetch come from the NEW bank at
; the same address (an earlier build did lda/tam/jmp here in
; bank 2 and the jmp was fetched from bank 3's fill bytes --
; the CPU slid into BRK loops and the shell; found by step
; trace, ws005 item 4). The switch therefore goes through the
; fixed-address relay at $DFF0/$DFF4 (cfg/compat3.cfg):
; exb_grp below (bank 2, $DFF0) runs lda #$03 / tam #$40 and
; the fetch after the TAM lands on bank 3's $DFF4, which
; holds jmp grp_entry. grp_entry returns with a plain RTS:
; MPR6 restoration is left to ex_tramp_inline, whose restore
; code lives in the fixed bank-0 window.
; ===================================================================
        .segment "EXRELAY"
exb_grp:
        lda     #$03
        tam     #$40
        ; fetch continues in bank 3 at $DFF4 (GRPRELAY):
        ; jmp grp_entry
        .segment "EXCODE"

; ===================================================================
; Shared helpers
; ===================================================================
; Apply the CR shadow ($20F3 + EX_CRHI) to VDC reg 5.
exb_apply_cr:
        ldy     #VDC_CR
        ldx     EX_CRLM
        lda     EX_CRHI
        jsr     vdc_write
        lda     #$05
        sta     EX_REGBOX
        rts

; Apply the MWR shadow (EX_MWR) to VDC reg 9.
exb_apply_mwr:
        ldy     #VDC_MWR
        ldx     EX_MWR
        lda     #$00
        jsr     vdc_write
        lda     #$09
        sta     EX_REGBOX
        rts

; Unsigned 16x16 -> 32 multiply: xs_a * xs_b -> xs_p.
mul16:
        lda     xs_a
        sta     xs_m
        lda     xs_a+1
        sta     xs_m+1
        stz     xs_m+2
        stz     xs_m+3
        stz     xs_p
        stz     xs_p+1
        stz     xs_p+2
        stz     xs_p+3
        ldx     #$10
mul16_l:
        lsr     xs_b+1
        ror     xs_b
        bcc     mul16_n
        clc
        lda     xs_p
        adc     xs_m
        sta     xs_p
        lda     xs_p+1
        adc     xs_m+1
        sta     xs_p+1
        lda     xs_p+2
        adc     xs_m+2
        sta     xs_p+2
        lda     xs_p+3
        adc     xs_m+3
        sta     xs_p+3
mul16_n:
        asl     xs_m
        rol     xs_m+1
        rol     xs_m+2
        rol     xs_m+3
        dex
        bne     mul16_l
        rts

; Unsigned 16/16 divide: xs_a / xs_b -> Q in xs_a, R in xs_p.
; Divisor zero -> Q = 0, R = 0 (measured steady state, p009).
div16u:
        lda     xs_b
        ora     xs_b+1
        beq     div16z
        stz     xs_p
        stz     xs_p+1
        ldx     #$10
div16_l:
        asl     xs_a
        rol     xs_a+1
        rol     xs_p
        rol     xs_p+1
        lda     xs_p
        sec
        sbc     xs_b
        tay
        lda     xs_p+1
        sbc     xs_b+1
        bcc     div16_n
        sta     xs_p+1
        sty     xs_p
        inc     xs_a
div16_n:
        dex
        bne     div16_l
        rts
div16z:
        stz     xs_a
        stz     xs_a+1
        stz     xs_p
        stz     xs_p+1
        rts

; |AX| as a 16-bit magnitude (negate if negative; $8000 stays
; $8000, i.e. magnitude 32768). Input in xs_a.
abs16:
        lda     xs_a+1
        bpl     abs16_d
        lda     #$00
        sec
        sbc     xs_a
        sta     xs_a
        lda     #$00
        sbc     xs_a+1
        sta     xs_a+1
abs16_d:
        rts

; ===================================================================
; MA group (arguments/results in the $20F8-$20FF shadows)
; ===================================================================
exb_mul8u:
        lda     ARG_AL
        sta     xs_a
        stz     xs_a+1
        lda     ARG_BL
        sta     xs_b
        stz     xs_b+1
        jsr     mul16
        lda     xs_p
        sta     ARG_CL
        lda     xs_p+1
        sta     ARG_CH
        ; CPU residues (maprobe, layer-4 2026-11-24, 5
        ; operand points on the genuine): A = product
        ; low, X = product high, Y = 0, carry = bit 7
        ; of the multiplier _BL (the residue of the
        ; genuine's shift loop). Dracula X's loader
        ; preamble reads X after this call.
        lda     xs_p
        sta     BM_RES
        lda     xs_p+1
        sta     EX_XRES
        stz     EX_YRES
        stz     BM_CARRYF
        lda     ARG_BL
        bpl     m8u_nc
        inc     BM_CARRYF
m8u_nc:
        rts

exb_mul8s:
        ; sign = sign(AL) XOR sign(BL); multiply magnitudes
        lda     ARG_AL
        eor     ARG_BL
        and     #$80
        sta     EX_SCRATCH      ; sign (mul16 owns the shared
                                ;   scratch block $24D8-$24DB)
        lda     ARG_AL
        bpl     m8s_a
        eor     #$FF
        clc
        adc     #$01
m8s_a:
        sta     xs_a
        stz     xs_a+1
        lda     ARG_BL
        bpl     m8s_b
        eor     #$FF
        clc
        adc     #$01
m8s_b:
        sta     xs_b
        stz     xs_b+1
        jsr     mul16
        lda     EX_SCRATCH
        beq     m8s_st
        lda     #$00
        sec
        sbc     xs_p
        sta     xs_p
        lda     #$00
        sbc     xs_p+1
        sta     xs_p+1
m8s_st:
        lda     xs_p
        sta     ARG_CL
        lda     xs_p+1
        sta     ARG_CH
        ; CPU residues (maprobe, layer-4 2026-11-24,
        ; 2 operand points): A = product high,
        ; X = 0, Y = 0, carry = 0.
        sta     BM_RES
        stz     EX_XRES
        stz     EX_YRES
        rts

exb_mul16u:
        lda     ARG_AL
        sta     xs_a
        lda     ARG_AH
        sta     xs_a+1
        lda     ARG_BL
        sta     xs_b
        lda     ARG_BH
        sta     xs_b+1
        jsr     mul16
        lda     xs_p
        sta     ARG_CL
        lda     xs_p+1
        sta     ARG_CH
        lda     xs_p+2
        sta     ARG_DL
        lda     xs_p+3
        sta     ARG_DH
        ; CPU residue (maprobe, layer-4 2026-11-24,
        ; 2 operand points): X = 0 (A = 0 and Y
        ; preserved already match the genuine).
        stz     EX_XRES
        rts

; Measured rule (p009): CX:DX = s16(abs16(AX)) * s16(BX), where
; abs16 is the 16-bit negate-if-negative (so $8000 maps to
; itself and reads as -32768). Equivalently: magnitudes
; multiply, and the sign is (AX == $8000) XOR (BX < 0).
exb_mul16s:
        lda     ARG_AH
        cmp     #$80
        bne     m16s_pn
        lda     ARG_AL
        bne     m16s_pn
        lda     #$80            ; AX == $8000 -> p negative
        sta     EX_SCRATCH
        bra     m16s_pm
m16s_pn:
        stz     EX_SCRATCH
m16s_pm:
        lda     ARG_BH
        and     #$80
        eor     EX_SCRATCH
        sta     EX_SCRATCH      ; total sign ($80 or $00)
        lda     ARG_AL
        sta     xs_a
        lda     ARG_AH
        sta     xs_a+1
        jsr     abs16
        lda     ARG_BL
        sta     xs_b
        lda     ARG_BH
        sta     xs_b+1
        ; abs16 of BX into xs_b (save/restore xs_a around it)
        lda     xs_a
        pha
        lda     xs_a+1
        pha
        lda     xs_b
        sta     xs_a
        lda     xs_b+1
        sta     xs_a+1
        jsr     abs16
        lda     xs_a
        sta     xs_b
        lda     xs_a+1
        sta     xs_b+1
        pla
        sta     xs_a+1
        pla
        sta     xs_a
        jsr     mul16
        lda     EX_SCRATCH
        beq     m16s_st
        ; negate the 32-bit product
        sec
        lda     #$00
        sbc     xs_p
        sta     xs_p
        lda     #$00
        sbc     xs_p+1
        sta     xs_p+1
        lda     #$00
        sbc     xs_p+2
        sta     xs_p+2
        lda     #$00
        sbc     xs_p+3
        sta     xs_p+3
m16s_st:
        lda     xs_p
        sta     ARG_CL
        lda     xs_p+1
        sta     ARG_CH
        lda     xs_p+2
        sta     ARG_DL
        lda     xs_p+3
        sta     ARG_DH
        rts

exb_div16u:
        lda     ARG_AL
        sta     xs_a
        lda     ARG_AH
        sta     xs_a+1
        lda     ARG_BL
        sta     xs_b
        lda     ARG_BH
        sta     xs_b+1
        jsr     div16u
        lda     xs_a
        sta     ARG_CL
        lda     xs_a+1
        sta     ARG_CH
        lda     xs_p
        sta     ARG_DL
        lda     xs_p+1
        sta     ARG_DH
        rts

; Signed divide: Q sign = sign(AX) XOR sign(BX), R sign =
; sign(AX); BX = 0 -> Q = 0, R = 0 (measured, p009).
exb_div16s:
        lda     ARG_BH
        eor     ARG_AH
        and     #$80
        sta     EX_SCRATCH      ; quotient sign
        lda     ARG_AH
        and     #$80
        sta     EX_SCRATCH+1    ; remainder sign
        lda     ARG_AL
        sta     xs_a
        lda     ARG_AH
        sta     xs_a+1
        jsr     abs16
        lda     ARG_BL
        sta     xs_b
        lda     ARG_BH
        sta     xs_b+1
        lda     xs_a
        pha
        lda     xs_a+1
        pha
        lda     xs_b
        sta     xs_a
        lda     xs_b+1
        sta     xs_a+1
        jsr     abs16
        lda     xs_a
        sta     xs_b
        lda     xs_a+1
        sta     xs_b+1
        pla
        sta     xs_a+1
        pla
        sta     xs_a
        jsr     div16u
        ; xs_a = |Q|, xs_p = |R|
        lda     EX_SCRATCH
        beq     dv16s_r
        lda     #$00
        sec
        sbc     xs_a
        sta     xs_a
        lda     #$00
        sbc     xs_a+1
        sta     xs_a+1
dv16s_r:
        lda     EX_SCRATCH+1
        beq     dv16s_st
        lda     #$00
        sec
        sbc     xs_p
        sta     xs_p
        lda     #$00
        sbc     xs_p+1
        sta     xs_p+1
dv16s_st:
        lda     xs_a
        sta     ARG_CL
        lda     xs_a+1
        sta     ARG_CH
        lda     xs_p
        sta     ARG_DL
        lda     xs_p+1
        sta     ARG_DH
        rts

; _CL = floor(sqrt(_AX)) for every 16-bit input (measured over
; the full 65536 sweep, p009).
exb_sqrt:
        ; loop state lives in EX_SCRATCH work RAM: mul16 owns
        ; the whole shared scratch block while it runs.
        stz     EX_SCRATCH      ; result
        lda     #$80
        sta     EX_SCRATCH+1    ; bit under test
sqrt_l:
        lda     EX_SCRATCH
        ora     EX_SCRATCH+1
        sta     EX_SCRATCH+2    ; trial
        sta     xs_a
        stz     xs_a+1
        sta     xs_b
        stz     xs_b+1
        jsr     mul16           ; xs_p = trial * trial
        ; accept if xs_p <= AX
        lda     xs_p+1
        cmp     ARG_AH
        bcc     sqrt_ok
        bne     sqrt_no
        lda     xs_p
        cmp     ARG_AL
        bcc     sqrt_ok
        beq     sqrt_ok
        bra     sqrt_no
sqrt_ok:
        lda     EX_SCRATCH+2
        sta     EX_SCRATCH
sqrt_no:
        lsr     EX_SCRATCH+1
        bne     sqrt_l
        lda     EX_SCRATCH
        sta     ARG_CL
        rts

; SIN(A): A in 0..86 -> 9-bit round(sin(A deg)*256) returned as
; A = low byte, carry = bit 8. A >= 87 -> A unchanged, carry 1
; (measured; the manual's domain is 0..90 but the observed
; table ends at 86).
exb_sin:
        lda     zp_ex_a
        cmp     #87
        bcs     sin_err
        asl     a
        tax
        lda     sin_tab,x
        sta     BM_RES
        lda     sin_tab+1,x
        sta     BM_CARRYF
        rts
sin_err:
        lda     zp_ex_a
        sta     BM_RES
        lda     #$01
        sta     BM_CARRYF
        rts

; COS(A) = SIN((90 - A) & $FF), error propagation included
; (measured point-for-point, p009).
exb_cos:
        lda     #90
        sec
        sbc     zp_ex_a
        sta     zp_ex_a
        bra     exb_sin

; ATNI: input is the X register. For X in 0..64 (the documented
; domain, y/x*64 with y <= x) A = round(atan(X/64) in degrees),
; carry 0 -- verified over the full sweep. Above 64 the genuine
; returns iterative-routine residue; COMPAT3 returns the same
; formula extended (46..76), a recorded divergence (p009).
exb_atni:
        ldx     zp_ex_x
        lda     atni_tab,x
        sta     BM_RES
        rts

exb_binbcd:
        lda     zp_ex_a
        cmp     #100
        bcs     binbcd_err
        ldx     #$00
binbcd_l:
        cmp     #10
        bcc     binbcd_d
        sec
        sbc     #10
        inx
        bra     binbcd_l
binbcd_d:
        sta     xs_t
        txa
        asl     a
        asl     a
        asl     a
        asl     a
        ora     xs_t
        sta     BM_RES
        rts
binbcd_err:
        lda     zp_ex_a
        sta     BM_RES
        lda     #$01
        sta     BM_CARRYF
        rts

; BCDBIN: valid BCD (both nibbles <= 9) -> A = hi*10 + lo,
; carry 0; either nibble > 9 -> A returned UNCHANGED, carry 1
; (pinned by the item-1 gate, correcting the p009 fit which
; had the value computed in the error case too).
exb_bcdbin:
        lda     zp_ex_a
        and     #$0F
        sta     xs_t            ; lo nibble
        lda     zp_ex_a
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        sta     xs_t2           ; hi nibble
        cmp     #10
        bcs     bcdbin_c
        lda     xs_t
        cmp     #10
        bcc     bcdbin_nc
bcdbin_c:
        lda     #$01
        sta     BM_CARRYF
        lda     zp_ex_a
        sta     BM_RES
        rts
bcdbin_nc:
        lda     xs_t2
        asl     a               ; hi*2
        sta     xs_p
        asl     a
        asl     a               ; hi*8
        clc
        adc     xs_p            ; hi*10
        clc
        adc     xs_t
        sta     BM_RES
        rts

; CBASIS: _CL = _AL div _BL, _DL = _AL mod _BL; _BL = 0 ->
; _CL = $FF, _DL = _AL (measured, p009).
exb_cbasis:
        lda     ARG_BL
        beq     cbasis_z
        sta     xs_b
        stz     xs_b+1
        lda     ARG_AL
        sta     xs_a
        stz     xs_a+1
        jsr     div16u
        lda     xs_a
        sta     ARG_CL
        lda     xs_p
        sta     ARG_DL
        rts
cbasis_z:
        lda     #$FF
        sta     ARG_CL
        lda     ARG_AL
        sta     ARG_DL
        rts

; RND: linear feedback over (rndseed, rndh) with rndm as a
; fixed mixing byte, solved exactly from 1,056 black-box
; samples by a GF(2) affine fit (p009):
;   seed' = ((seed ^ rndm) << 1) | ((seed & 1) ^ (rndh >> 6 & 1))
;   rndh' = ((seed ^ rndh) << 1) | ((seed >> 7) ^ (rndm >> 7))
;   A     = seed' ^ rndh'
; (0,0,0) is a fixed point. The genuine's IRQ1 handler also
; increments rndseed once per vsync (identified in item 1
; from the gate's R1 stream: the pure iteration plus four
; seed+1 events at call indices 156/603/1496/1943 reproduces
; all 2,048 outputs and the exact after-state); COMPAT3's
; handler does the same (bank0.s irq1_handler).
exb_rnd:
        lda     EX_RNDSEED
        sta     xs_t            ; s
        eor     EX_RNDM
        asl     a
        sta     xs_t2           ; (s^m)<<1
        lda     xs_t
        and     #$01
        sta     xs_p            ; s & 1
        lda     EX_RNDH
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        and     #$01
        eor     xs_p
        ora     xs_t2
        sta     xs_p+1          ; seed'
        lda     xs_t
        eor     EX_RNDH
        asl     a
        sta     xs_t2           ; (s^h)<<1
        lda     xs_t
        asl     a               ; carry = s bit7
        lda     #$00
        rol     a
        sta     xs_p            ; s >> 7
        lda     EX_RNDM
        asl     a               ; carry = m bit7
        lda     #$00
        rol     a
        eor     xs_p
        ora     xs_t2
        sta     xs_p+2          ; rndh'
        lda     xs_p+1
        sta     EX_RNDSEED
        lda     xs_p+2
        sta     EX_RNDH
        eor     xs_p+1
        sta     BM_RES
        rts

; ===================================================================
; AD stream group ($4D/$4E; System Card 2.0 additions, named
; ad_stream_start / ad_stream_poll in the one public source
; that lists them; contracts measured black-box in ws005
; item 2 -- see pce-web/item2_notes.md)
; ===================================================================
; AD_STREAM_START ($4D): store the AD_TRANS-family parameter
; block from the shadows (record CL:CH:DL -> $224D-$224F,
; count AL -> $2250, BX -> $22C3/$22C4), zero the poll
; counter ($22C1), set the stream state ($22C2) to 1.
; Returns A=01, carry clear, X preserved, Y=00. The arm's
; effect depends on the current state (all measured):
; state 0: arm, poison cleared. State 1: re-arm replaces
; the pending stream, poison flag unchanged (a poisoned
; stream stays poisoned). States 2/3: arm stores but
; poisons -- the new stream's polls return 01 indefinitely.
; State 4 (drain): the arm is IGNORED -- no store, no state
; change, returns A=00 with carry set.
exb_stream_start:
        lda     ST_STATE
        beq     ss_arm0
        cmp     #$04
        beq     ss_ignore
        cmp     #$01
        beq     ss_store        ; state 1: poison unchanged
        lda     #$01            ; states 2/3: poison
        sta     ST_POISON
        bra     ss_store
ss_arm0:
        stz     ST_POISON
ss_store:
        lda     ARG_CL
        sta     ST_REC
        lda     ARG_CH
        sta     ST_REC+1
        lda     ARG_DL
        sta     ST_REC+2
        lda     ARG_AL
        sta     ST_CNTB
        lda     ARG_BL
        sta     ST_BX
        lda     ARG_BH
        sta     ST_BX+1
        stz     ST_COUNT
        lda     #$01
        sta     ST_STATE
        sta     BM_RES          ; A = 01
        lda     #$00
        sta     EX_YRES         ; Y = 00 (measured)
        rts
ss_ignore:
        lda     #$01
        sta     BM_CARRYF       ; carry set; A=00 (BM_RES
                                ; default), nothing stored
        rts

; AD_STREAM_POLL ($4E): walk the stream state machine.
; State 0: A=00. State 1 fresh: first poll -> A=02, X=$FF,
; state=2. State 1 poisoned: A=01 indefinitely. State 2:
; six polls A=$80, X = counter 0..5 (counter increments per
; poll); the next poll leaves state 2 -- A=04/state=4 when
; the stored count is 0 (state 3 skipped), else A=03/
; state=3. State 3: one poll, A=04, state=4. State 4
; (drain): A=$88 until the drain elapses (time-based on
; the genuine; modelled here as 4 vsyncs after entry, or
; immediate when the count is 0), then A=00 with carry
; set and state=0. Like the genuine card on this core, no
; data is transferred (item 2 notes: the genuine's stream
; data path lands nowhere on this core).
exb_stream_poll:
        lda     ST_STATE
        beq     sp_idle
        cmp     #$01
        beq     sp_state1
        cmp     #$02
        beq     sp_state2
        cmp     #$03
        beq     sp_state3
        ; state 4: drain
        lda     ST_CNTB
        beq     sp_done
        lda     EX_RNDSEED      ; +1 per vsync (item 1)
        sec
        sbc     ST_FSTAMP
        cmp     #$04
        bcs     sp_done
        lda     #$88
        sta     BM_RES
        rts
sp_done:
        stz     ST_STATE
        lda     #$01
        sta     BM_CARRYF       ; carry set on completion
        rts                     ; BM_RES = 00 (dispatcher)
sp_idle:
        rts                     ; A=00, X/Y preserved
sp_state1:
        lda     ST_POISON
        bne     sp_busy
        lda     #$02
        sta     ST_STATE
        sta     BM_RES          ; A = 02
        lda     #$FF
        sta     EX_XRES         ; X = $FF
        rts
sp_busy:
        lda     #$01
        sta     BM_RES          ; A = 01, X/Y preserved
        rts
sp_state2:
        lda     ST_COUNT
        cmp     #$06
        bcs     sp_leave2
        sta     EX_XRES         ; X = counter
        inc     ST_COUNT
        lda     #$80
        sta     BM_RES          ; A = $80
        rts
sp_leave2:
        lda     ST_CNTB
        beq     sp_to4
        lda     #$03
        sta     BM_RES          ; A = 03
        lda     #$03
        sta     ST_STATE
        rts
sp_state3:
sp_to4:
        lda     #$04
        sta     BM_RES          ; A = 04
        sta     ST_STATE
        lda     EX_RNDSEED
        sta     ST_FSTAMP
        rts

; EX_SETVEC: store X:Y at usrvec[n] ($2200 + 2n) for n in
; 0..5, 7, 8; returns A = n, X = 2n+1, Y = addr hi. n = 6 (soft
; reset) is special on the genuine: the vector lands at
; $2284/$2285 (measured in virgin and repeated registrations,
; p009) and X returns the address low byte instead of 2n+1.
; n = $FF stores nothing and returns A = X = $FF, Y = addr hi.
exb_setvec:
        lda     zp_ex_a
        cmp     #$FF
        beq     setvec_ff
        cmp     #$06
        beq     setvec_6
        asl     a
        tax
        lda     zp_ex_x
        sta     EX_USRVEC,x
        lda     zp_ex_y
        sta     EX_USRVEC+1,x
        txa
        clc
        adc     #$01
        sta     EX_XRES
        lda     zp_ex_y
        sta     EX_YRES
        lda     zp_ex_a
        sta     BM_RES
        rts
setvec_6:
        lda     zp_ex_x
        sta     EX_SRESET
        lda     zp_ex_y
        sta     EX_SRESET+1
        lda     zp_ex_x
        sta     EX_XRES
        lda     zp_ex_y
        sta     EX_YRES
        lda     #$06
        sta     BM_RES
        rts
setvec_ff:
        lda     #$FF
        sta     BM_RES
        sta     EX_XRES
        lda     zp_ex_y
        sta     EX_YRES
        rts

; EX_JOYSNS: the pad arrays at $2228-$2236 are maintained by
; the IRQ1 handler at every vsync (measured: at any call point
; joytrg reads $00 and joyold = current, because the handler
; consumes the edges first, p009). The call itself returns
; A = 0, carry set, and leaves $20F7 = $05. The soft-reset
; vector is stored by SETVEC but never taken: in the genuine's
; IPL-program environment the reset did not fire under any
; tested condition (held RUN+SEL for 300 frames with the
; vector registered, handler-only and JOYSNS-called alike),
; so v1 does not implement the jump (recorded, p009).
exb_joysns:
        lda     #$05
        sta     EX_REGBOX
        lda     #$01
        sta     BM_CARRYF
        rts

; CR bit operations ($2A-$33): all update the $20F3 shadow.
; The RCR/IRQ family also writes CR through immediately
; (measured: the core's VD bit follows CR bit3 at once) and
; returns the new shadow in A; the BG/SPR/DSP family only
; marks the shadow dirty for the vsync handler to apply and
; returns A = $E0 (the value observed at every such call).
; $20F7 = $05 after every one of them (measured).
exb_rcron:
        lda     #$04
        ldx     #$03            ; set, CR now
        bra     exb_bitop
exb_rcroff:
        lda     #$04
        ldx     #$02            ; clear, CR now
        bra     exb_bitop
exb_irqon:
        lda     #$08
        ldx     #$03
        bra     exb_bitop
exb_irqoff:
        lda     #$08
        ldx     #$02
        bra     exb_bitop
exb_bgon:
        lda     #$80
        ldx     #$01            ; set, deferred
        bra     exb_bitop
exb_bgoff:
        lda     #$80
        ldx     #$00            ; clear, deferred
        bra     exb_bitop
exb_spron:
        lda     #$40
        ldx     #$01
        bra     exb_bitop
exb_sproff:
        lda     #$40
        ldx     #$00
        bra     exb_bitop
exb_dspon:
        lda     #$C0
        ldx     #$01
        bra     exb_bitop
exb_dspoff:
        lda     #$C0
        ldx     #$00
        bra     exb_bitop
; A = bit mask, X = mode (bit0 set/clear, bit1 CR-now/deferred)
exb_bitop:
        sta     xs_t
        txa
        and     #$01
        beq     bitop_clr
        lda     EX_CRLM
        ora     xs_t
        bra     bitop_st
bitop_clr:
        lda     xs_t
        eor     #$FF
        and     EX_CRLM
bitop_st:
        sta     EX_CRLM
        txa
        and     #$02
        beq     bitop_def
        jsr     exb_apply_cr
        lda     EX_CRLM
        sta     BM_RES
        rts
bitop_def:
        lda     #$01
        sta     EX_CRDIRTY
        lda     #$05
        sta     EX_REGBOX
        lda     #$E0
        sta     BM_RES
        rts

; EX_SCRSIZ / EX_DOTMOD share one MWR shadow byte (measured,
; p009): SCRSIZ writes bits 4-6 from (n & 7), DOTMOD writes
; bits 0-3 from (n & $0F); both program VDC reg 9 with the
; combined shadow and leave $20F7 = $09.
exb_scrsiz:
        lda     zp_ex_a
        and     #$07
        asl     a
        asl     a
        asl     a
        asl     a
        sta     xs_t
        sta     EX_YRES
        lda     EX_MWR
        and     #$0F
        ora     xs_t
        sta     EX_MWR
        sta     BM_RES
        jsr     exb_apply_mwr
        rts

exb_dotmod:
        lda     zp_ex_a
        sta     EX_YRES
        and     #$0F
        sta     xs_t
        lda     EX_MWR
        and     #$F0
        ora     xs_t
        sta     EX_MWR
        sta     BM_RES
        jsr     exb_apply_mwr
        rts

; EX_SCRMOD (A = clock, X = cols, Y = rows): validation measured
; over a full grid and confirmed by the Hu7 manual -- clock
; family 0/2 (5 MHz): cols 10..34; family 1/3 (7 MHz): cols
; 16..44; rows 10..30 (the 10/11 boundary rows were
; confirmed on the genuine in the item-3.7 sweep: both
; clocks accept them, and a fast-clock success returns
; Y = $0A like A; a slow success returns Y = 0).
; On success: A = (MWR shadow & $F0) | (odd clock ? $0A : $00),
; X = cols - 1, Y = (odd clock ? $0A : $00), carry 0, and the
; VCE dot clock follows the clock family. On error: A = 1,
; carry 1, X = $1F, Y = 0. $20F7 = $09 either way.
; Register apply (layer 10 round 6, contract C-L6): EVERY
; call, success or failure, writes the VDC timing set
; (VPR/VDW/VCR/HSR/HDR) once inside the call, plus MWR from
; the SCRSIZ shadow. Success writes formula(clock, cols,
; rows); failure writes the power-on set formula(0,32,30)
; regardless of any earlier geometry. The p009-era "shadow
; convention" (post-shadow-call failure state, unidentified
; recovery) is WITHDRAWN as a BIOS behaviour (spec_lodoss
; round 6 S9.1): the extest6 grid's case_open clobbers the
; probe's own table-offset cell, so all nine grid calls are
; invalid-argument calls on both cards; what the era read
; as a state machine is this failure-path refresh.
exb_scrmod:
        lda     #$09
        sta     EX_REGBOX
        lda     zp_ex_a
        and     #$01
        sta     xs_t            ; clock family (0 slow, 1 fast)
        lda     zp_ex_y
        cmp     #10
        bcc     scrmod_fail
        cmp     #31
        bcs     scrmod_fail
        lda     xs_t
        beq     scrmod_slow
        lda     zp_ex_x
        cmp     #16
        bcc     scrmod_fail
        cmp     #45
        bcs     scrmod_fail
        bra     scrmod_ok
scrmod_slow:
        lda     zp_ex_x
        cmp     #10
        bcc     scrmod_fail
        cmp     #35
        bcs     scrmod_fail
scrmod_ok:
        lda     EX_VCE
        and     #$FC
        ora     xs_t
        sta     EX_VCE
        sta     a:VCE_CTL
        lda     #$00            ; Y out: $0A on a fast-clock
        ldx     xs_t            ; success, $00 on a slow one
        beq     scrmod_y        ; (item-3.7 measurement;
                                ; the item-1 grid had no
                                ; fast-success sample)
        lda     #$0A
scrmod_y:
        sta     EX_YRES
        lda     EX_MWR
        and     #$F0
        sta     BM_RES
        lda     xs_t
        beq     scrmod_ev
        lda     BM_RES
        ora     #$0A
        sta     BM_RES
scrmod_ev:
        lda     zp_ex_x
        sec
        sbc     #$01
        sta     EX_XRES
        jsr     scrmod_apply    ; C-L6: formula set + MWR (last:
                                ; the apply's staging overwrites
                                ; xs_t, which the return-value
                                ; computation above still needs)
        rts
scrmod_fail:
        jsr     scrmod_apply_fail ; C-L6: power-on set + MWR
        lda     #$01
        sta     BM_RES
        sta     BM_CARRYF
        lda     #$1F
        sta     EX_XRES
        stz     EX_YRES
        rts

; ===================================================================
; EX_SCMOD register apply (layer 10 round 6, contract C-L6;
; spec_lodoss.md S9.2). Lives in segment VIDEO2: EXCODE has
; only ~36 bytes free before FONT8B2, while VIDEO2 (same
; bank 2, same MPR6 window -- a direct JSR from exb_scrmod)
; has room, the more so with ipl_vdc_game_b2 retired by
; C-G5. STATELESS by design: the success set is computed
; from the call arguments, the failure set is a constant
; table; no stored-geometry cell and no init stores are
; introduced (spec S9.2 item 6 -- the round-5 residue flip
; at the p009 cases 84-86 came with geometry-init stores).
;
; The five values are staged in xs_a..xs_a+9 as lo/hi pairs
; in the genuine's write order VPR, VDW, VCR, HSR, HDR;
; scrmod_write5 then writes each register once, followed
; by MWR with the byte staged at xs_a+10 (= xs_cnt, whose
; computation use is dead by then). The MWR byte differs
; by path (genuine geom-probe port logs): on SUCCESS it is
; the call's A-out byte, (EX_MWR & $F0) | (odd clock ?
; $0A : $00) -- already computed into BM_RES by the caller
; (slow geom1/geom4: $00/$50 = the shadow; fast geom6/7/
; 18/20: $0A with shadow $00). On FAILURE it is the plain
; SCRSIZ shadow EX_MWR (geom11). The shadow cell itself is
; NOT updated (no measurement shows persistence, and the
; p009 differential passes without it). The writer also
; leaves EX_REGBOX = $09, as exb_apply_mwr does.
; Formula (K = clock & 1, C = cols, R = rows; (T,Q,B) =
; (36,8,40) for K=0, (48,16,56) for K=1):
;   VPR = ((135-4R) << 8) | $02     VDW = 8R-1 (hi $00)
;   VCR = 126+4R (hi $00)
;   HSR = (HDS << 5) | (K+2), HDS = round_up(4(T-C), Q)
;   HDR = (HDE << 7) | (C-1),  HDE = (B-C) & ~1
; Success-envelope arithmetic stays in bytes: 4R <= 120,
; 8R <= 240, 4(T-C) <= 128. HSR/HDR are computed last:
; staging HDR's lo byte overwrites xs_t (the family copy)
; only after its final use.
; ===================================================================
        .segment "VIDEO2"
scrmod_apply:
        ; --- VPR (vector bytes 0,1) ---
        lda     zp_ex_y
        asl     a
        asl     a               ; 4R
        sta     xs_sign
        lda     #$02
        sta     xs_a            ; VPR lo
        lda     #135
        sec
        sbc     xs_sign
        sta     xs_a+1          ; VPR hi = 135-4R
        ; --- VDW (bytes 2,3) ---
        lda     zp_ex_y
        asl     a
        asl     a
        asl     a               ; 8R
        sec
        sbc     #$01
        sta     xs_a+2          ; VDW lo = 8R-1
        stz     xs_a+3
        ; --- VCR (bytes 4,5) ---
        lda     xs_sign         ; 4R
        clc
        adc     #126
        sta     xs_a+4          ; VCR lo = 126+4R
        stz     xs_a+5
        ; --- family constants: T -> xs_sign, Q-1 -> xs_cnt,
        ;     B -> xs_t2 (consumed by HDR below, before the
        ;     byte-9 store overwrites it) ---
        lda     xs_t
        beq     sa_slow
        lda     #48
        sta     xs_sign
        lda     #$0F
        sta     xs_cnt
        lda     #56
        bra     sa_h
sa_slow:
        lda     #36
        sta     xs_sign
        lda     #$07
        sta     xs_cnt
        lda     #40
sa_h:
        sta     xs_t2           ; B
        ; --- HDS = round_up(4(T-C), Q) = (4(T-C)+Q-1) & ~(Q-1)
        lda     xs_sign         ; T
        sec
        sbc     zp_ex_x
        asl     a
        asl     a               ; 4(T-C)
        clc
        adc     xs_cnt          ; + Q-1
        sta     xs_sign
        lda     xs_cnt
        eor     #$FF            ; ~(Q-1)
        and     xs_sign
        sta     xs_sign         ; HDS
        ; --- HSR (bytes 6,7) ---
        and     #$07
        asl     a
        asl     a
        asl     a
        asl     a
        asl     a               ; (HDS&7)<<5
        sta     xs_a+6
        lda     xs_t            ; K
        clc
        adc     #$02
        ora     xs_a+6
        sta     xs_a+6          ; HSR lo = (HDS&7)<<5 | (K+2)
        lda     xs_sign         ; HDS
        lsr     a
        lsr     a
        lsr     a
        sta     xs_a+7          ; HSR hi = HDS>>3
        ; --- HDR (bytes 8,9) ---
        lda     xs_t2           ; B
        sec
        sbc     zp_ex_x
        and     #$FE            ; HDE = (B-C) & ~1
        sta     xs_sign
        lda     zp_ex_x
        sec
        sbc     #$01
        sta     xs_a+8          ; HDR lo = C-1
        lda     xs_sign
        lsr     a
        sta     xs_a+9          ; HDR hi = HDE>>1
        lda     BM_RES          ; success MWR byte = A-out
        sta     xs_cnt          ; staged at xs_a+10
        bra     scrmod_write5

scrmod_apply_fail:
        ldx     #$09
saf_loop:
        lda     scrmod_powon,x
        sta     xs_a,x
        dex
        bpl     saf_loop
        lda     EX_MWR          ; failure MWR byte = the
        sta     xs_cnt          ; plain SCRSIZ shadow
        ; fall through to the writer

scrmod_write5:
        stz     xs_sign         ; step 0..4
sw5_loop:
        ldx     xs_sign
        lda     scrmod_regs,x
        tay                     ; Y = VDC register number
        txa
        asl     a               ; vector byte offset = step*2
        tax
        lda     xs_a+1,x
        pha                     ; value hi via the stack
        lda     xs_a,x
        tax                     ; X = value lo
        pla                     ; A = value hi
        jsr     vdc_write
        inc     xs_sign
        lda     xs_sign
        cmp     #$05
        bcc     sw5_loop
        ldy     #VDC_MWR
        ldx     xs_cnt          ; the staged MWR byte
        lda     #$00
        jsr     vdc_write
        lda     #$09
        sta     EX_REGBOX
        rts

scrmod_regs:
        .byte   VDC_VPR, VDC_VDW, VDC_VCR, VDC_HSR, VDC_HDR
scrmod_powon:                   ; power-on set, vector order:
        .byte   $02, $0F        ; VPR $0F02
        .byte   $EF, $00        ; VDW $00EF
        .byte   $F6, $00        ; VCR $00F6
        .byte   $02, $02        ; HSR $0202
        .byte   $1F, $04        ; HDR $041F

        .segment "EXCODE"

; EX_IMODE: CR bits 11-12 = A & 3; A out = (A & 3) << 3;
; carry set only for A = $FF (measured over 12 inputs, p009).
exb_imode:
        lda     zp_ex_a
        cmp     #$FF
        bne     imode_nc
        lda     #$01
        sta     BM_CARRYF
imode_nc:
        lda     zp_ex_a
        and     #$03
        asl     a
        asl     a
        asl     a
        sta     xs_t
        sta     BM_RES
        lda     EX_CRHI
        and     #$E7
        ora     xs_t
        sta     EX_CRHI
        jsr     exb_apply_cr
        rts

; EX_VMODE: increment follows the SCRSIZ width, capped at +64
; (measured: width codes 0/1/2 -> +32/+64/+64, p009).
exb_vmode:
        lda     EX_MWR
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        and     #$07
        beq     vmode_32
        lda     #$10            ; code 2 (+64) << 3
        bra     vmode_st
vmode_32:
        lda     #$08            ; code 1 (+32) << 3
vmode_st:
        sta     xs_t
        sta     BM_RES          ; A out = the increment code
                                ; << 3 (item-1 gate)
        lda     EX_CRHI
        and     #$E7
        ora     xs_t
        sta     EX_CRHI
        jsr     exb_apply_cr
        rts

; EX_HMODE: increment +1.
exb_hmode:
        lda     EX_CRHI
        and     #$E7
        sta     EX_CRHI
        jsr     exb_apply_cr
        rts

; EX_VSYNC: wait for the next vsync. If the vsync IRQ is
; off in the CR shadow it is switched on first (Hu7: "If
; VSYNC IRQ is OFF, it is set ON"). The wait itself polls
; the VDC status port's VD bit directly -- NOT the IRQ1
; handler's flag: the genuine's EX_VSYNC returns even with
; interrupts masked (layer-5 replica, SEI caller: genuine
; returns, a handler-flag wait never does; Gate of
; Thunder's frame loop calls EX_VSYNC with I set and spun
; in the flag wait forever, PC parked in the spin loop).
; Poll first until VD is clear (any current vblank has
; passed), then until it sets: that edge is the next
; vsync. Status reads ack the VD interrupt, as the
; handler's own read does.
exb_vsync:
        lda     EX_CRLM
        and     #$08
        sta     EX_SCRATCH      ; entry VD-enable state (exit
                                ; $20F7 residue, below)
        bne     vsync_apply
        lda     EX_CRLM
        ora     #$08
        sta     EX_CRLM
vsync_apply:
        ; Re-assert the CR shadow in hardware: a caller
        ; that wrote the VDC directly (Gate's loader turns
        ; the display fully off before this call) leaves no
        ; vblank to wait for; the genuine's EX_VSYNC
        ; returns in that state too (layer-5 replica with
        ; CR forced to $0000), so it must recreate the
        ; condition it waits for.
        jsr     exb_apply_cr
        ; Poll with interrupts masked: COMPAT3's IRQ1
        ; handler reads the status at entry and ack's VD
        ; before a mainline poll can observe it (measured:
        ; with the handler active the poll never sees the
        ; bit, while the handler's own flag sets every
        ; frame). Masking for the poll's duration makes
        ; the VD edge observable; the caller's I flag is
        ; restored on exit.
        php
        sei
vsync_poll:
        lda     a:VDC_SEL
        and     #VDC_STATUS_VD
        bne     vsync_poll
vsync_set:
        lda     a:VDC_SEL
        and     #VDC_STATUS_VD
        beq     vsync_set
        plp
        ; $20F7 residue (p009 VSYNC cases 87/88): when
        ; the VD interrupt was already enabled at entry,
        ; the genuine's per-vblank service (DMA restart,
        ; VDC reg $13) is the last $20F7 writer; when the
        ; call itself had to enable it (EX_IRQOFF state),
        ; the CR write's $05 stands.
        lda     EX_SCRATCH
        beq     vsync_done
        lda     #$13
        sta     EX_REGBOX
vsync_done:
        rts

; EX_DMAMOD: DCR (reg 15) work value $2243 = A & $1F, written
; through; A out = the same value; $20F7 = $0F (measured).
exb_dmamod:
        lda     zp_ex_a
        and     #$1F
        sta     EX_DCRW
        sta     BM_RES
        ldy     #VDC_DCR
        tax
        lda     #$00
        jsr     vdc_write
        lda     #$0F
        sta     EX_REGBOX
        rts

; EX_SPRDMA: point DVSSR (reg 19) at sat_adr and start the
; SATB DMA (DCR bit 0; the $2243 work value itself is not
; changed). $20F7 = $13 (measured).
exb_sprdma:
        ldy     #VDC_DVSSR
        ldx     EX_SATADR
        lda     EX_SATADR+1
        jsr     vdc_write
        ; start the SATB DMA: DCR bit 0 (the $2243 work value
        ; itself is not changed)
        ldy     #VDC_DCR
        lda     EX_DCRW
        ora     #$01
        tax
        lda     #$00
        jsr     vdc_write
        lda     #$13
        sta     EX_REGBOX
        rts

; EX_SATCLR: zero the 512-byte SATB region at sat_adr and
; reset sprptr to 0. $20F7 = $02 (measured).
exb_satclr:
        ldy     #VDC_MAWR
        ldx     EX_SATADR
        lda     EX_SATADR+1
        jsr     vdc_write
        lda     #VDC_VWR
        sta     a:VDC_SEL
        ldx     #$00
satclr_l:
        stz     a:VDC_DLO
        stz     a:VDC_DHI
        dex
        bne     satclr_l
        stz     EX_SPRPTR
        lda     #$02
        sta     BM_RES          ; A out = 2 (item-1 gate)
        sta     EX_REGBOX
        stz     EX_XRES         ; X out = 0 (item-1 gate)
        rts

; EX_SPRPUT: write the 4-word entry (spry/sprx/sprn/spra work
; bytes) at sat_adr + sprptr*4 words, then sprptr++. Carry
; reads set at every measured call. $20F7 = $02.
exb_sprput:
        lda     EX_SPRPTR
        sta     xs_t
        stz     xs_t2
        asl     xs_t
        rol     xs_t2
        asl     xs_t
        rol     xs_t2           ; xs_t/xs_t2 = sprptr * 4
        lda     EX_SATADR
        clc
        adc     xs_t
        sta     xs_p            ; address low
        lda     EX_SATADR+1
        adc     xs_t2
        sta     xs_p+1          ; address high
        ldy     #VDC_MAWR
        ldx     xs_p
        lda     xs_p+1
        jsr     vdc_write
        lda     #VDC_VWR
        sta     a:VDC_SEL
        ldy     #$00
sprput_l:
        lda     EX_SPRY,y
        sta     a:VDC_DLO
        iny
        lda     EX_SPRY,y
        sta     a:VDC_DHI
        iny
        cpy     #$08
        bne     sprput_l
        inc     EX_SPRPTR
        lda     #$01
        sta     BM_CARRYF
        lda     #$02
        sta     EX_REGBOX
        rts

; EX_SETRCR: VDC reg 6 = X:A (hi:lo). $20F7 = $06; A and X
; pass back out (measured).
exb_setrcr:
        lda     zp_ex_x
        sta     EX_XRES
        ldy     #VDC_RCR
        ldx     zp_ex_a
        lda     zp_ex_x
        jsr     vdc_write
        lda     zp_ex_a
        sta     BM_RES
        lda     #$06
        sta     EX_REGBOX
        rts

; EX_SETWRT: MAWR = X:A, then select VWR for the caller's
; data writes. $20F7 = $02 (measured).
exb_setwrt:
        ldy     #VDC_MAWR
        ldx     zp_ex_a
        lda     zp_ex_x
        jsr     vdc_write
        lda     #VDC_VWR
        sta     a:VDC_SEL
        lda     #$02            ; A out = 2 (item-1 gate)
        sta     BM_RES
        sta     EX_REGBOX
        rts

; EX_SETRED: MARR = X:A, then select VRR. $20F7 reads $02
; after this call on the genuine (measured) even though the
; physically selected register is VRR.
exb_setred:
        ldy     #VDC_MARR
        ldx     zp_ex_a
        lda     zp_ex_x
        jsr     vdc_write
        lda     #VDC_VRR
        sta     a:VDC_SEL
        lda     #$02            ; A out = 2 (item-1 gate)
        sta     BM_RES
        sta     EX_REGBOX
        rts

; EX_SETDMA: the shadows ARE the arguments (item-1 gate,
; correcting the p009 table reading): SOUR = _BX, DESR =
; _DX, LENR = _CX - 1 (the VDC's convention), then start
; the transfer via DCR bit 1. $20F7 is not touched
; (measured). A out on the genuine is VDC-status-class
; residue (pin samples vary by environment); COMPAT3
; leaves A = 0.
exb_setdma:
        ldy     #VDC_SOUR
        ldx     ARG_BL
        lda     ARG_BH
        jsr     vdc_write
        ldy     #VDC_DESR
        ldx     ARG_DL
        lda     ARG_DH
        jsr     vdc_write
        lda     ARG_CL
        sec
        sbc     #$01
        tax
        lda     ARG_CH
        sbc     #$00
        ldy     #VDC_LENR
        jsr     vdc_write
        ; start the VRAM-VRAM DMA: DCR bit 1 (register only;
        ; measured: the transfer runs even with the $2243 work
        ; value at 0, so SETDMA triggers it itself)
        ldy     #VDC_DCR
        lda     EX_DCRW
        ora     #$02
        tax
        lda     #$00
        jsr     vdc_write
        rts

; EX_COLORC: process the pending color_cmd ($221F) -- 2 =
; copy the BG/SPR palette buffers to the VCE, 1 = read the
; VCE palettes back into the buffers; the length bytes count
; 16-word palettes (BG from VCE address $000, SPR from $100).
; color_cmd is cleared on completion (measured). Processing
; happens on a direct call and from the IRQ1 handler (the
; deferred form), via exb_colorc_go with bank 2 mapped.
exb_colorc:
        lda     EX_COLORCMD
        beq     cc_noop
        jsr     exb_colorc_go
        lda     #$01            ; A out = 1 when a command was
        sta     BM_RES          ; processed (item-1 gate)
        rts
cc_noop:
        jsr     exb_colorc_go
        rts

exb_colorc_go:
        ; Borrow ZP_PTR_CC for the copy loops' (zp),y pointer:
        ; save the caller's bytes first and restore them at
        ; cc_ret, so the net effect is zero in BOTH entry
        ; contexts (mainline EX_COLORC call and the IRQ1
        ; handler's deferred form). A is dead at both call
        ; sites (the trampoline materializes A from BM_RES;
        ; the handler restores A from its entry stack frame).
        lda     ZP_PTR_CC
        sta     CC_PTR_SAV
        lda     ZP_PTR_CC+1
        sta     CC_PTR_SAV+1
        lda     EX_COLORCMD
        beq     cc_early
        cmp     #$02
        beq     cc_write
        cmp     #$01
        beq     cc_read
        bra     cc_clr
cc_early:
        jmp     cc_ret
cc_write:
        lda     EX_BGCPTR
        sta     xs_a
        lda     EX_BGCPTR+1
        sta     xs_a+1
        lda     EX_BGCLEN
        jsr     cc_setcnt
        stz     xs_p
        stz     xs_p+1
        jsr     cc_copy_w
        lda     EX_SPRCPTR
        sta     xs_a
        lda     EX_SPRCPTR+1
        sta     xs_a+1
        lda     EX_SPRCLEN
        jsr     cc_setcnt
        stz     xs_p
        lda     #$01
        sta     xs_p+1
        jsr     cc_copy_w
        bra     cc_clr
cc_read:
        lda     EX_BGCPTR
        sta     xs_a
        lda     EX_BGCPTR+1
        sta     xs_a+1
        lda     EX_BGCLEN
        jsr     cc_setcnt
        stz     xs_p
        stz     xs_p+1
        jsr     cc_copy_r
        lda     EX_SPRCPTR
        sta     xs_a
        lda     EX_SPRCPTR+1
        sta     xs_a+1
        lda     EX_SPRCLEN
        jsr     cc_setcnt
        stz     xs_p
        lda     #$01
        sta     xs_p+1
        jsr     cc_copy_r
cc_clr:
        lda     #$00
        sta     EX_COLORCMD
cc_ret:
        lda     CC_PTR_SAV      ; restore the borrowed pointer
        sta     ZP_PTR_CC
        lda     CC_PTR_SAV+1
        sta     ZP_PTR_CC+1
        rts

; A = palette count -> xs_b = count * 16 words.
cc_setcnt:
        sta     xs_t
        stz     xs_b+1
        asl     a
        rol     xs_b+1
        asl     a
        rol     xs_b+1
        asl     a
        rol     xs_b+1
        asl     a
        rol     xs_b+1
        sta     xs_b
        rts

; Copy xs_b words from (xs_a) to the VCE palette RAM starting
; at the 9-bit address in xs_p/xs_p+1. The dereference goes
; through the borrowed ZP pointer ZP_PTR_CC (xs_a itself is
; WRAM since the C-D1 relocation and cannot encode (zp),y).
cc_copy_w:
        lda     xs_a
        sta     ZP_PTR_CC
        lda     xs_a+1
        sta     ZP_PTR_CC+1
        lda     xs_p
        sta     VCE_PAL_LO
        lda     xs_p+1
        sta     VCE_PAL_HI
        ldy     #$00
ccw_l:
        lda     xs_b
        ora     xs_b+1
        beq     ccw_d
        lda     (ZP_PTR_CC),y
        sta     VCE_PAL_DLO
        iny
        lda     (ZP_PTR_CC),y
        sta     VCE_PAL_DHI
        iny
        bne     ccw_n
        inc     ZP_PTR_CC+1
ccw_n:
        lda     xs_b
        bne     ccw_nd
        dec     xs_b+1
ccw_nd:
        dec     xs_b
        bra     ccw_l
ccw_d:
        rts

; Copy xs_b words from the VCE palette RAM into (xs_a)
; (through the borrowed ZP pointer, as in cc_copy_w).
cc_copy_r:
        lda     xs_a
        sta     ZP_PTR_CC
        lda     xs_a+1
        sta     ZP_PTR_CC+1
        lda     xs_p
        sta     VCE_PAL_LO
        lda     xs_p+1
        sta     VCE_PAL_HI
        ldy     #$00
ccr_l:
        lda     xs_b
        ora     xs_b+1
        beq     ccr_d
        lda     VCE_PAL_DLO
        sta     (ZP_PTR_CC),y
        iny
        lda     VCE_PAL_DHI
        sta     (ZP_PTR_CC),y
        iny
        bne     ccr_n
        inc     ZP_PTR_CC+1
ccr_n:
        lda     xs_b
        bne     ccr_nd
        dec     xs_b+1
ccr_nd:
        dec     xs_b
        bra     ccr_l
ccr_d:
        rts

; ===================================================================
; Tables (computed data: see the header comment)
; ===================================================================
; round(sin(a deg) * 256) for a = 0..86, as 16-bit words.
sin_tab:
        .word   $0000, $0004, $0009, $000D, $0012, $0016, $001B, $001F
        .word   $0024, $0028, $002C, $0031, $0035, $003A, $003E, $0042
        .word   $0047, $004B, $004F, $0053, $0058, $005C, $0060, $0064
        .word   $0068, $006C, $0070, $0074, $0078, $007C, $0080, $0084
        .word   $0088, $008B, $008F, $0093, $0096, $009A, $009E, $00A1
        .word   $00A5, $00A8, $00AB, $00AF, $00B2, $00B5, $00B8, $00BB
        .word   $00BE, $00C1, $00C4, $00C7, $00CA, $00CC, $00CF, $00D2
        .word   $00D4, $00D7, $00D9, $00DB, $00DE, $00E0, $00E2, $00E4
        .word   $00E6, $00E8, $00EA, $00EC, $00ED, $00EF, $00F1, $00F2
        .word   $00F3, $00F5, $00F6, $00F7, $00F8, $00F9, $00FA, $00FB
        .word   $00FC, $00FD, $00FE, $00FE, $00FF, $00FF, $00FF

; round(atan(x/64) in degrees) for x = 0..255.
atni_tab:
        .byte   $00, $01, $02, $03, $04, $04, $05, $06, $07, $08, $09, $0A, $0B, $0B, $0C, $0D
        .byte   $0E, $0F, $10, $11, $11, $12, $13, $14, $15, $15, $16, $17, $18, $18, $19, $1A
        .byte   $1B, $1B, $1C, $1D, $1D, $1E, $1F, $1F, $20, $21, $21, $22, $23, $23, $24, $24
        .byte   $25, $25, $26, $27, $27, $28, $28, $29, $29, $2A, $2A, $2B, $2B, $2C, $2C, $2D
        .byte   $2D, $2D, $2E, $2E, $2F, $2F, $30, $30, $30, $31, $31, $32, $32, $32, $33, $33
        .byte   $33, $34, $34, $34, $35, $35, $35, $36, $36, $36, $37, $37, $37, $37, $38, $38
        .byte   $38, $39, $39, $39, $39, $3A, $3A, $3A, $3A, $3B, $3B, $3B, $3B, $3C, $3C, $3C
        .byte   $3C, $3C, $3D, $3D, $3D, $3D, $3E, $3E, $3E, $3E, $3E, $3F, $3F, $3F, $3F, $3F
        .byte   $3F, $40, $40, $40, $40, $40, $40, $41, $41, $41, $41, $41, $41, $42, $42, $42
        .byte   $42, $42, $42, $42, $43, $43, $43, $43, $43, $43, $43, $44, $44, $44, $44, $44
        .byte   $44, $44, $44, $45, $45, $45, $45, $45, $45, $45, $45, $45, $46, $46, $46, $46
        .byte   $46, $46, $46, $46, $46, $47, $47, $47, $47, $47, $47, $47, $47, $47, $47, $47
        .byte   $48, $48, $48, $48, $48, $48, $48, $48, $48, $48, $48, $49, $49, $49, $49, $49
        .byte   $49, $49, $49, $49, $49, $49, $49, $49, $49, $4A, $4A, $4A, $4A, $4A, $4A, $4A
        .byte   $4A, $4A, $4A, $4A, $4A, $4A, $4A, $4B, $4B, $4B, $4B, $4B, $4B, $4B, $4B, $4B
        .byte   $4B, $4B, $4B, $4B, $4B, $4B, $4B, $4B, $4C, $4C, $4C, $4C, $4C, $4C, $4C, $4C
