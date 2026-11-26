; ===================================================================
; psgbios.s -- $48 PSG_BIOS, $4B PSG_DRIVE, $4A KEY_BIOS
; (ws005 item 4, IMPLEMENTATION side of the two-side clean room).
;
; Written ONLY from item4_spec.md (the analysis side's spec) and
; public documentation (Hu7 CD System BIOS Manual, zeograd's
; BIOS document, David Shadoff's public "CDROM Music Bytecode"
; note for the song format). No genuine-card code or data.
;
; Lives in bank 2, segment EXCODE, behind the shared EX
; trampoline; results return via BM_RES / BM_CARRYF / EX_XRES /
; EX_YRES like every EX-family function. X/Y are preserved on
; $48 (spec 2.1); $4B forces X=$FF, Y=$00 (spec 3); $4A returns
; A=$68, X=$03, carry clear, Y preserved, no side effects
; (spec 5: a fixed vestige -- matching it IS the contract).
;
; Observable driver state lives at the spec's addresses in
; $22C0-$2307, and no $48/$4B call writes anything else in
; that area: PSG_ON, PSG_PLAY, PSG_FDOUT, PSG_CONT and the
; stop family are each pinned to exactly their own stores
; (spec 2.2/2.3, R3). All COMPAT3-private bookkeeping lives
; in the PSG_SEQ block ($27E7), outside the documented area.
;
; (R3) There is NO sequencer here. The song round pinned the
; submission contract (PSG_PLAY stores _AX at $22E1; bit 7
; of the stored low byte is the started flag), the DRIVE
; tick classification, PSG_CONT's single effect and the
; MSTAT/SSTAT mode table -- and established that in this
; environment the stored pointer is never consumed or
; advanced, no playing state ever appears, and the audio
; output stays silent (spec 2.5, 6 items 3-4). The previous
; rounds' fetch/advance model moved state the pins forbid
; (it rewrote $22E1 on settle/halt, reported a modelled
; MSTAT $40, wrote PSG chip registers), so it was removed;
; what remains is exactly the pinned bookkeeping. The
; bank-0 IRQ1 handler ticks the driver in the SYNC-active
; environment (a user SYNC vector installed): the spec's
; no-user-vector windows never showed the write set, but
; Lodoss's live environment settles without any $4B call
; (layer 7; see psg_irq_tick in bank0.s).
; ===================================================================
        .setcpu "HuC6280"
        .include "hw.inc"

        .export psgb_bios, psgb_drive, psgb_key, psgb_irq_tick
        .import usrvec_default

; mainline scratch (shared bank-2 convention; was ZP
; $30-$34 until the C-D1 relocation, layer 10 /
; spec_drac.md -- now in WRAM in the shared block; only
; the $48 control functions use these)
ps_a            = $24D0         ; 16-bit dividend (2)
ps_b            = $24D2         ; divisor
ps_r            = $24D3         ; division remainder (2)

; COMPAT3-private bookkeeping in the PSG_SEQ block ($27E7),
; zeroed by PSG_INIT. None of these are observable state.
PP_INIFLG       = PSG_SEQ + 0   ; $A5 after PSG_INIT
PP_ONAL         = PSG_SEQ + 1   ; PSG_ON AL copy (private;
                                ;   ON has no observable
                                ;   state effect, spec 2.3)
PP_PTRSET       = PSG_SEQ + 2   ; $A5 once PSG_PLAY has
                                ;   stored a song pointer
PP_CONT         = PSG_SEQ + 3   ; 1 after PSG_CONT until the
                                ;   next PSG_DRIVE (spec 3c)

        .segment "EXCODE"

; ===================================================================
; $4A KEY_BIOS -- fixed vestige (spec 5): A=$68, X=$03, carry
; clear, Y preserved, all inputs ignored, no side effects.
; ===================================================================
psgb_key:
        lda     #$68
        sta     BM_RES
        lda     #$03
        sta     EX_XRES
        rts                     ; BM_CARRYF = 0 from dispatch

; ===================================================================
; $48 PSG_BIOS -- dispatch on shadow DH, parameter in AL.
; DH > 20: A = DH echoed, carry set (spec 2).
; ===================================================================
psgb_bios:
        lda     ARG_DH
        cmp     #21
        bcs     pb_range
        asl     a
        tax
        lda     pb_tab+1,x
        pha
        lda     pb_tab,x
        pha
        rts
pb_range:
        lda     ARG_DH
        sta     BM_RES
        lda     #$01
        sta     BM_CARRYF
        rts

pb_tab:
        .word   pb_on-1         ; 0  PSG_ON
        .word   pb_off-1        ; 1  PSG_OFF
        .word   pb_init-1       ; 2  PSG_INIT
        .word   pb_bank-1       ; 3  PSG_BANK
        .word   pb_track-1      ; 4  PSG_TRACK
        .word   pb_wave-1       ; 5  PSG_WAVE
        .word   pb_env-1        ; 6  PSG_ENV
        .word   pb_fm-1         ; 7  PSG_FM
        .word   pb_pe-1         ; 8  PSG_PE
        .word   pb_pc-1         ; 9  PSG_PC
        .word   pb_tempo-1      ; 10 PSG_TEMPO
        .word   pb_play-1       ; 11 PSG_PLAY
        .word   pb_mstat-1      ; 12 PSG_MSTAT
        .word   pb_sstat-1      ; 13 PSG_SSTAT
        .word   pb_mstop-1      ; 14 PSG_MSTOP
        .word   pb_sstop-1      ; 15 PSG_SSTOP
        .word   pb_astop-1      ; 16 PSG_ASTOP
        .word   pb_mvoff-1      ; 17 PSG_MVOFF
        .word   pb_cont-1       ; 18 PSG_CONT
        .word   pb_fdout-1      ; 19 PSG_FDOUT
        .word   pb_dcnt-1       ; 20 PSG_DCNT

; --- DH 0: PSG_ON. A=1, carry clear. AL has no observable
; --- state effect (spec 2.3); it is kept privately (the
; --- public drive-source/track-enable selection).
pb_on:
        lda     ARG_AL
        sta     PP_ONAL
        lda     #$01
        sta     BM_RES
        rts

; --- DH 1: PSG_OFF. A=0, carry clear. (R1/R3) OFF has NO
; --- work-RAM effect in any state, including with a song
; --- pointer stored in either flag state. Nothing to do.
pb_off:
        rts                     ; BM_RES = 0, carry clear

; --- DH 2: PSG_INIT. A=2, carry SET. Writes the spec 2.1
; --- initial state; $22DF takes the AL mode byte (spec 2.3:
; --- AL 0->$00, 1->$01, $FF->$02; other values follow the
; --- same small-mode reading). $22C0-$22C2 are left alone:
; --- $22C1/$22C2 belong to the $4D/$4E stream state. The
; --- private block is reset with the driver (a stored
; --- song pointer does not survive INIT).
pb_init:
        ldx     #$44            ; zero $22C3-$2307 (69 bytes)
        lda     #$00
pb_init_z:
        sta     $22C3,x
        dex
        bpl     pb_init_z
        ldx     #$0F            ; zero the private block
                                ;   (16 bytes at PSG_SEQ; was
                                ;   128 bytes at the old $2850
                                ;   placement, which zeroed
                                ;   Lodoss's scheduler tables --
                                ;   layer 7)
pb_init_z2:
        sta     PSG_SEQ,x
        dex
        bpl     pb_init_z2
        lda     #$73
        sta     PSG_TEMPOB
        lda     #$C0
        sta     PSG_DESTAT
        lda     #$80
        sta     PSG_SONGPTR
        lda     #$D3
        sta     $22E3
        lda     #$06
        sta     $22E6
        lda     #$08
        sta     $22E7
        lda     #$20
        sta     $22E8
        lda     #$60
        sta     $22EA
        lda     ARG_AL
        beq     pb_init_m
        cmp     #$01
        beq     pb_init_m
        lda     #$02
pb_init_m:
        sta     PSG_INITMODE
        lda     #$A5
        sta     PP_INIFLG
        lda     #$02
        sta     BM_RES
        lda     #$01
        sta     BM_CARRYF
        rts

; --- DH 3: PSG_BANK. AL stored verbatim at $22EB.
pb_bank:
        lda     ARG_AL
        sta     PSG_BANKB
        rts

; --- DH 4: PSG_TRACK. AL stored at $22D0.
pb_track:
        lda     ARG_AL
        sta     PSG_TRACKB
        rts

; --- DH 5-9: WAVE/ENV/FM/PE/PC. A=0, carry clear. (R1,
; --- SB-9) Each stores AL verbatim at its genuine work
; --- address (spec 2.2); playback-time effects of the
; --- stored values are unpinned (spec 6 item 3).
pb_wave:
        lda     ARG_AL
        sta     PSG_WAVEA
        rts
pb_env:
        lda     ARG_AL
        sta     PSG_ENVBA
        rts
pb_fm:
        lda     ARG_AL
        sta     PSG_FMBA
        rts
pb_pe:
        lda     ARG_AL
        sta     PSG_PEBA
        rts
pb_pc:
        lda     ARG_AL
        sta     PSG_PCBA
        rts

; --- DH 10: PSG_TEMPO. A=2. (R1, SB-1: full-range sweep,
; --- deterministic) $22D4 = min(round(4370/AL), $7D),
; --- computed as (4370 + AL/2) / AL, except AL=43 -> 101,
; --- AL=94 -> 47, AL=131 -> 34. Carry is set iff the
; --- unclamped value <= $7D (equivalently AL >= 35);
; --- clamped results and AL=0 give carry clear.
pb_tempo:
        lda     ARG_AL
        beq     pb_tempo_clamp  ; AL=0: $7D, carry clear
        cmp     #43
        beq     pb_tempo_e43
        cmp     #94
        beq     pb_tempo_e94
        cmp     #131
        beq     pb_tempo_e131
        sta     ps_b
        lsr     a               ; AL/2
        clc
        adc     #<4370
        sta     ps_a
        lda     #>4370
        adc     #$00
        sta     ps_a+1
        jsr     pb_div          ; ps_a = quotient
        lda     ps_a+1
        bne     pb_tempo_clamp
        lda     ps_a
        cmp     #$7E
        bcs     pb_tempo_clamp
        sta     PSG_TEMPOB      ; unclamped: carry set
        lda     #$01
        sta     BM_CARRYF
        bra     pb_tempo_done
pb_tempo_e43:
        lda     #101
        bra     pb_tempo_exc
pb_tempo_e94:
        lda     #47
        bra     pb_tempo_exc
pb_tempo_e131:
        lda     #34
pb_tempo_exc:                   ; exceptions are unclamped
        sta     PSG_TEMPOB      ; values: carry set
        lda     #$01
        sta     BM_CARRYF
pb_tempo_done:
        lda     #$02
        sta     BM_RES
        rts
pb_tempo_clamp:
        lda     #$7D
        sta     PSG_TEMPOB
        lda     #$02
        sta     BM_RES
        rts                     ; carry clear (dispatch)

; ps_a (16-bit) / ps_b (8-bit) -> ps_a = quotient.
; The remainder is 16-bit: with divisors above 127 the
; partial remainder exceeds one byte (an 8-bit remainder
; silently broke TEMPO for AL >= 128).
pb_div:
        stz     ps_r
        stz     ps_r+1
        ldx     #16
pb_div_l:
        asl     ps_a
        rol     ps_a+1
        rol     ps_r
        rol     ps_r+1
        lda     ps_r
        sec
        sbc     ps_b
        tay
        lda     ps_r+1
        sbc     #$00
        bcc     pb_div_n
        sta     ps_r+1
        sty     ps_r
        inc     ps_a
pb_div_n:
        dex
        bne     pb_div_l
        rts

; --- DH 11: PSG_PLAY. A=0, carry clear. (R3) Stores _AX
; --- verbatim at $22E1 (the song header pointer) and
; --- changes nothing else in the work area. Bit 7 of the
; --- stored low byte is the driver's started flag
; --- (spec 2.5); BANK/TRACK do not select a different
; --- pointer. Whether playback follows is the drive
; --- path's business -- in this environment it never
; --- does (spec 2.5, 6 item 3).
pb_play:
        lda     ARG_AL
        sta     PSG_SONGPTR
        lda     ARG_AH
        sta     PSG_SONGPTR+1
        lda     #$A5
        sta     PP_PTRSET
        rts

; --- DH 12: PSG_MSTAT. (R3) The stopped-state value is
; --- driven by the INIT mode byte at $22DF, not by any
; --- song state: mode 0 -> $00, mode 1 -> $80, mode 2 ->
; --- $00. No other value was ever observed (spec 6.4).
pb_mstat:
        lda     PSG_INITMODE
        cmp     #$01
        bne     pb_mstat_r
        lda     #$80
        sta     BM_RES
pb_mstat_r:
        rts

; --- DH 13: PSG_SSTAT. (R3) By INIT mode: mode 0 -> $80,
; --- mode 1 -> $00, mode 2 -> $00.
pb_sstat:
        lda     PSG_INITMODE
        bne     pb_sstat_r
        lda     #$80
        sta     BM_RES
pb_sstat_r:
        rts

; --- DH 14: PSG_MSTOP. A=0, carry SET. (R3) No work-RAM
; --- effect, even with a song pointer stored in either
; --- flag state; the pointer is not cleared.
pb_mstop:
        lda     #$01
        sta     BM_CARRYF
        rts

; --- DH 15: PSG_SSTOP. A=0, carry clear. (R3) No
; --- work-RAM effect; the pointer is not cleared.
pb_sstop:
        rts

; --- DH 16: PSG_ASTOP. A=$C0, carry clear. (R3) No
; --- work-RAM effect even with a song pointer stored;
; --- the pointer is not cleared.
pb_astop:
        lda     #$C0
        sta     BM_RES
        rts

; --- DH 17: PSG_MVOFF. A=0, carry SET. No state effect
; --- is pinned beyond the return (spec 2.2).
pb_mvoff:
        lda     #$01
        sta     BM_CARRYF
        rts

; --- DH 18: PSG_CONT. A=0, carry clear. (R3) Exactly one
; --- synchronous work-RAM effect, measured IRQ-masked:
; --- $22DE $C0 -> $40 -- i.e. bit 7 of $22DE clears (the
; --- only pinned transition; COMPAT3 applies it as a
; --- bit clear). The next PSG_DRIVE tick performs the
; --- stopped write set again, restoring $22DE = $C0
; --- (spec 3c) -- PP_CONT records that obligation.
pb_cont:
        lda     PSG_DESTAT
        and     #$7F
        sta     PSG_DESTAT
        lda     #$01
        sta     PP_CONT
        rts

; --- DH 19: PSG_FDOUT. (R1, SB-11) v = |AL| with AL read
; --- as a signed byte (AL $81-$FF -> 256-AL, $80 -> 128).
; --- Returns A = v. If 1 <= v <= 127: stores v at $2488
; --- and returns carry set; v = 0 or 128: no store, carry
; --- clear. No other work-RAM effect in the stopped
; --- state; playback-time fade behaviour is unpinned
; --- (spec 6 item 3) and is not modelled.
pb_fdout:
        lda     ARG_AL
        bpl     pb_fd_v         ; $00-$7F: v = AL
        eor     #$FF            ; $80-$FF: v = ~AL + 1
        inc     a               ; (= 256 - AL; $80 -> 128)
pb_fd_v:
        sta     BM_RES          ; A = v
        beq     pb_fd_r         ; v = 0: no store
        cmp     #$80
        beq     pb_fd_r         ; v = 128: no store
        sta     PSG_FDOUTA
        lda     #$01
        sta     BM_CARRYF
pb_fd_r:
        rts

; --- DH 20: PSG_DCNT. (R1, SB-11) Stores AL & 7 at $22DD
; --- (always, including 0) and returns A = AL & 7, carry
; --- clear. Playback-time use of the count is unpinned
; --- (spec 6 item 3).
pb_dcnt:
        lda     ARG_AL
        and     #$07
        sta     PSG_DCNTA
        sta     BM_RES
        rts

; ===================================================================
; $4B PSG_DRIVE -- no arguments (DH and all shadows ignored).
; Returns A=$00, X=$FF, Y=$00, carry set, always (spec 3).
;
; (R3) The write set is state-dependent once a song pointer
; is stored (spec 3, correcting the R1 reading):
;   - pointer stored, started flag SET: the tick's only
;     change is $22D4 bit 7 (further ticks change nothing
;     at all); $22E0 is NOT written.
;   - pointer stored, flag CLEAR: the first tick performs
;     the full stopped write set, which sets the flag
;     ($22E1 |= $80); later ticks are as above.
;   - after PSG_CONT: the first tick performs the stopped
;     write set again (restoring $22DE=$C0, $22E0=$FF).
;   - no pointer stored (pristine, after INIT, after
;     ON/OFF): the stopped write set, as in R1.
; The stopped write set is: $22D4 |= $80, $22DE |= $80,
; $22E0 = $FF, $22E1 |= $80 (from pristine $22E1 = $00 this
; reads as the spec's literal "$22E1 = $80"). In no state
; does a tick advance or consume the pointer, change
; MSTAT/SSTAT, or produce audio in this environment.
; ===================================================================
psgb_drive:
        lda     #$FF
        sta     EX_XRES
        stz     EX_YRES
        lda     #$01
        sta     BM_CARRYF       ; BM_RES = 0 from dispatch
        lda     PP_CONT
        bne     pd_stopped      ; CONT pending: stopped set
        lda     PP_PTRSET
        beq     pd_stopped      ; no pointer: stopped set
        lda     PSG_SONGPTR
        bpl     pd_stopped      ; flag clear: stopped set
        lda     PSG_TEMPOB      ; flag set: $22D4 bit 7 only
        ora     #$80
        sta     PSG_TEMPOB
        rts
pd_stopped:
        stz     PP_CONT
        lda     PSG_TEMPOB
        ora     #$80
        sta     PSG_TEMPOB
        lda     PSG_DESTAT
        ora     #$80
        sta     PSG_DESTAT
        lda     #$FF
        sta     PSG_ENDF
        lda     PSG_SONGPTR
        ora     #$80
        sta     PSG_SONGPTR
        rts

; ===================================================================
; psgb_irq_tick: the driver's interrupt-context tick (layer 7),
; called from bank 0's IRQ1 handler right after the SYNC dispatch
; (irq_m bit 4 set). The spec (2.5) recorded that in IRQ-live
; windows with NO user vector, DRIVE's write set never appeared;
; the same spec (SB-5) recorded $22DE $C0->$40 as "an interrupt-
; handler side effect of the live measurement". Lodoss (user
; SYNC vector installed, song started with the flag bit clear)
; settles its driver state within ~90 frames with NO $4B call
; anywhere in the program -- $22D4 $73->$F3, $22E0 $00->$FF,
; $22E1 $01->$81, $22DE $C0->$40 -- and its mainline polls
; MSTAT/SSTAT for exactly that settle. So in the SYNC-active
; environment the genuine's chain does tick the driver. This
; routine reproduces the observed IRQ-context write set; the
; user-vector gate preserves the no-user-vector observation.
;   - usrvec[4] == the default stub, or no pointer: no writes.
;   - CONT obligation pending: the $4B stopped set (spec 3c;
;     $22DE |= $80 restores $C0 from the playing $40).
;   - pointer stored, started flag clear: the song-start set:
;     $22D4 |= $80, $22E0 = $FF, $22E1 |= $80, $22DE = $40 (the
;     playing status; the $4B mainline tick's stopped set
;     writes $22DE |= $80 instead -- the two contexts differ
;     on this one cell, each as measured).
;   - pointer stored, flag set: $22D4 |= $80 only (spec 3a).
; Uses A only.
; ===================================================================
psgb_irq_tick:
        lda     EX_USRVEC+8
        cmp     #<usrvec_default
        bne     pit_live
        lda     EX_USRVEC+9
        cmp     #>usrvec_default
        beq     pit_out
pit_live:
        lda     PP_PTRSET
        beq     pit_out
        lda     PP_CONT
        bne     pit_stopped
        lda     PSG_SONGPTR
        bpl     pit_start
        lda     PSG_TEMPOB      ; flag set: $22D4 bit 7 only
        ora     #$80
        sta     PSG_TEMPOB
        rts
pit_start:
        lda     #$40            ; playing status
        sta     PSG_DESTAT
        bra     pit_set
pit_stopped:
        stz     PP_CONT
        lda     PSG_DESTAT
        ora     #$80
        sta     PSG_DESTAT
pit_set:
        lda     PSG_TEMPOB
        ora     #$80
        sta     PSG_TEMPOB
        lda     #$FF
        sta     PSG_ENDF
        lda     PSG_SONGPTR
        ora     #$80
        sta     PSG_SONGPTR
pit_out:
        rts
