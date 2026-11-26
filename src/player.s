; COMPAT3 CD player UI + CD+G display (ws005 p005).
; Clean-room: original functional-minimal UI written for
; COMPAT3; the CD+G decoder follows the public CD+G
; channel-coding specification (packet format and the
; Memory Preset / Border Preset / Tile Block / Scroll /
; Load Colour Table instructions). No NEC/Hudson code,
; data or UI assets.
;
; This file is a SEPARATE object (player.o) linked into
; ROM bank 1, which the linker maps at logical $C000:
; bank 0 is full, so the shell reaches this code through
; the MPR6 window (see the glue in bank0.s). Every BIOS
; call made from here preserves MPR6 (proven by the
; p003/p005 differentials, which gate caller MPRs), and
; the framebuffer helpers use MPR2/MPR3 for CD RAM.
        .setcpu "HuC6280"
        .include "hw.inc"

        .export player_enter, player_tick, gfx_drain_some
        .import vdc_write, vdc_set_mawr, bat_clear, set_cursor
        .import putch, print_str, print_dec
        .import disc_check, show_title, scsi_cmd
        .import to_bcd, from_bcd

        .segment "PLAYER"

; BIOS jump-table slots used by the player.
BIOS_PLAY       = $E012         ; slot $06
BIOS_PAUSE      = $E018         ; slot $08
BIOS_SUBQ       = $E01E         ; slot $0C
BIOS_SUBRQ      = $E027         ; slot $0D
BIOS_DINFO      = $E036         ; slot $12
BIOS_BMFMT      = $E048         ; slot $18 BM_FORMAT
BIOS_BMFREE     = $E04B         ; slot $19 BM_FREE
BIOS_BMDEL      = $E054         ; slot $1C BM_DELETE
BIOS_BMFILES    = $E057         ; slot $1D BM_FILES
BIOS_GETFNT     = $E060         ; slot $20 EX_GETFNT

; BRAM screen state (work RAM $2A00 page: outside the player's
; $2300-$28FF area and the $2F00 mailbox; shell-only).
PLB_STATE       = $2A00         ; 0 = off, 1 = list, 2 = format confirm
PLB_CUR         = $2A01         ; cursor (0-based file index)
PLB_WIN         = $2A02         ; first visible file index
PLB_CNT         = $2A03         ; file count (interface byte range)
PLB_ROW         = $2A04         ; draw loop row
PLB_NUM         = $2A05         ; decimal printer value (2 bytes)
PLB_LEAD        = $2A07         ; decimal printer: digit seen
PLB_PIDX        = $2A08         ; decimal printer: place index
PLB_PLACE       = $2A09         ; decimal printer: place (2 bytes)
PLB_DIG         = $2A0B         ; decimal printer: digit
PLB_FCB         = $2A10         ; 12-byte FCB scratch (FILES dest)
PLB_LIST        = $2A20         ; visible window FCBs: 16 x 12 bytes
PLB_PW          = $2AE0         ; "!BM FORMAT!" in work RAM (the
                                ; BM glue switches MPR6, so the
                                ; password must live in a window
                                ; the BIOS does not remap)

; Player-local scratch (work RAM, shell-only).
PL_E1           = $2764         ; direction edges this tick
PL_I            = $2765
PL_J            = $2766
PL_K            = $2767
PL_DIV          = $2768         ; 24-bit math (3 bytes)
PL_DIV2         = $276B         ; 24-bit math (3 bytes)
PL_FBX          = $276E         ; framebuffer x (2 bytes)
PL_FBY          = $2770         ; framebuffer y
PL_COLOR        = $2771
PL_TX           = $2772
PL_TY           = $2773
PL_CNT          = $2774         ; 2 bytes
PL_PX           = $2776         ; 8 pixel staging bytes

; CD+G geometry.
GFX_W           = 288
GFX_H           = 192
GFX_FB_BANK     = $69           ; framebuffer: banks $69-$6F
GFX_TILE0       = $400          ; first BG tile index (VRAM)

; ===================================================================
; player_enter: build the track table and draw the player
; screen. Called from bank 0 via the MPR6 glue (show_player).
; ===================================================================
player_enter:
        jsr     disc_check
        lda     #$00
        sta     PL_GFX
        sta     PL_PLAYTRK
        sta     PL_TICK
        sta     PL_DIRPREV
        sta     PL_WIN
        sta     PL_PAUSED
        sta     PLB_STATE
        lda     #$03
        sta     PL_STATUS
        lda     zp_disc
        bne     pe_build
        ; --- no disc: simple screen -------------------------
        jsr     bat_clear
        lda     #$01
        ldx     #$02
        jsr     set_cursor
        lda     #$01
        sta     zp_pal
        lda     #<str_player
        sta     zp_ptr
        lda     #>str_player
        sta     zp_ptr+1
        jsr     print_str
        lda     #$04
        ldx     #$02
        jsr     set_cursor
        lda     #$00
        sta     zp_pal
        lda     #<str_nodisc
        sta     zp_ptr
        lda     #>str_nodisc
        sta     zp_ptr+1
        jsr     print_str
        lda     #$06
        ldx     #$02
        jsr     set_cursor
        lda     #$02
        sta     zp_pal
        lda     #<str_runret
        sta     zp_ptr
        lda     #>str_runret
        sta     zp_ptr+1
        jsr     print_str
        jmp     pe_state
pe_build:
        lda     WV_TNOMIN
        jsr     from_bcd
        sta     PL_TMIN
        sta     PL_CURSOR
        lda     WV_TNOMAX
        jsr     from_bcd
        sta     PL_TMAX
        lda     zp_tracks
        sta     PL_NTRACKS
        ; per-track start MSF via CD_DINFO type 2
        lda     PL_TMIN
        sta     PL_I
pe_tloop:
        lda     PL_I
        jsr     to_bcd
        sta     ARG_AL
        lda     #$02
        sta     ARG_AH
        lda     #<PL_DBUF
        sta     ARG_BL
        lda     #>PL_DBUF
        sta     ARG_BH
        jsr     BIOS_DINFO
        ; PL_TSTART + (PL_I-1)*3 -> zp_ptr
        lda     PL_I
        dec     a
        sta     PL_J
        asl     a
        clc
        adc     #<PL_TSTART
        sta     zp_ptr
        lda     #>PL_TSTART
        adc     #$00
        sta     zp_ptr+1
        lda     zp_ptr
        clc
        adc     PL_J
        sta     zp_ptr
        bcc     pe_tcopy
        inc     zp_ptr+1
pe_tcopy:
        ldy     #$00
pe_tc1:
        lda     PL_DBUF,y
        sta     (zp_ptr),y
        iny
        cpy     #$03
        bne     pe_tc1
        inc     PL_I
        lda     PL_I
        cmp     PL_TMAX
        bcc     pe_tloop
        beq     pe_tloop
        ; lengths: frames(next start) - frames(this start),
        ; converted to BCD (min, sec) in PL_TLENBCD.
        lda     #$00
        sta     PL_I            ; 0-based index
pe_lloop:
        ; frames of start[PL_I] -> PL_DIV
        jsr     pe_start_ptr    ; zp_ptr = start[PL_I] (BCD)
        jsr     bcdmsf_frames   ; -> PL_DIV2 (saved below)
        lda     PL_DIV2
        pha
        lda     PL_DIV2+1
        pha
        lda     PL_DIV2+2
        pha
        ; frames of start[PL_I + 1] (or lead-out) -> PL_DIV2
        inc     PL_I
        jsr     pe_start_ptr
        jsr     bcdmsf_frames
        dec     PL_I
        ; PL_DIV = PL_DIV2 - saved
        pla
        sta     PL_DIV+2
        pla
        sta     PL_DIV+1
        pla
        sta     PL_DIV
        sec
        lda     PL_DIV2
        sbc     PL_DIV
        sta     PL_DIV
        lda     PL_DIV2+1
        sbc     PL_DIV+1
        sta     PL_DIV+1
        lda     PL_DIV2+2
        sbc     PL_DIV+2
        sta     PL_DIV+2
        ; total seconds = frames / 75 -> PL_DIV (24-bit div)
        jsr     div24_75
        ; minutes = totsec / 60, seconds = remainder
        lda     PL_DIV
        sta     PL_J            ; totsec low (<= 5940: use
        lda     PL_DIV+1        ; 16-bit value in PL_J/PL_K)
        sta     PL_K
        lda     #$00
        sta     PL_TLENBCD_TMP  ; minutes counter (local)
pe_minloop:
        lda     PL_K
        bne     pe_minsub
        lda     PL_J
        cmp     #60
        bcc     pe_mindone
pe_minsub:
        sec
        lda     PL_J
        sbc     #60
        sta     PL_J
        lda     PL_K
        sbc     #$00
        sta     PL_K
        inc     PL_TLENBCD_TMP
        bra     pe_minloop
pe_mindone:
        ; store BCD min/sec at PL_TLENBCD + PL_I*2
        lda     PL_I
        asl     a
        clc
        adc     #<PL_TLENBCD
        sta     zp_ptr
        lda     #>PL_TLENBCD
        adc     #$00
        sta     zp_ptr+1
        lda     PL_TLENBCD_TMP
        jsr     to_bcd
        ldy     #$00
        sta     (zp_ptr),y
        lda     PL_J            ; seconds (binary)
        jsr     to_bcd
        iny
        sta     (zp_ptr),y
        inc     PL_I
        lda     PL_I
        cmp     PL_NTRACKS
        bcs     pe_lskip
        jmp     pe_lloop
pe_lskip:
        jsr     pl_draw_all
pe_state:
        lda     zp_disc
        clc
        adc     #STATE_PLAYER_NODISC
        sta     MB_STATE
        rts

PL_TLENBCD_TMP  = $2775

; pe_start_ptr: zp_ptr -> BCD MSF triple of track index
; PL_I (0-based); index == PL_NTRACKS gives the lead-out
; (from WV_OUTMIN/SEC/FRM, staged through PL_DBUF).
pe_start_ptr:
        lda     PL_I
        cmp     PL_NTRACKS
        bne     psp_track
        lda     WV_OUTMIN
        sta     PL_DBUF
        lda     WV_OUTSEC
        sta     PL_DBUF+1
        lda     WV_OUTFRM
        sta     PL_DBUF+2
        lda     #<PL_DBUF
        sta     zp_ptr
        lda     #>PL_DBUF
        sta     zp_ptr+1
        rts
psp_track:
        lda     PL_I
        sta     PL_J
        asl     a
        clc
        adc     #<PL_TSTART
        sta     zp_ptr
        lda     #>PL_TSTART
        adc     #$00
        sta     zp_ptr+1
        lda     zp_ptr
        clc
        adc     PL_J
        sta     zp_ptr
        bcc     psp_done
        inc     zp_ptr+1
psp_done:
        rts

; bcdmsf_frames: BCD (M,S,F) at zp_ptr -> frames in
; PL_DIV2 (24-bit LE) = ((M*60)+S)*75+F.
bcdmsf_frames:
        ldy     #$00
        lda     (zp_ptr),y
        jsr     from_bcd
        sta     PL_DIV2
        lda     #$00
        sta     PL_DIV2+1
        sta     PL_DIV2+2
        ; *60 = *64 - *4
        jsr     shl24_2         ; *4 (on PL_DIV2)
        lda     PL_DIV2
        sta     PL_DIV
        lda     PL_DIV2+1
        sta     PL_DIV+1
        lda     PL_DIV2+2
        sta     PL_DIV+2
        jsr     shl24_2
        jsr     shl24_2
        jsr     shl24_2
        jsr     shl24_2         ; PL_DIV2 = M*64
        sec
        lda     PL_DIV2
        sbc     PL_DIV
        sta     PL_DIV2
        lda     PL_DIV2+1
        sbc     PL_DIV+1
        sta     PL_DIV2+1
        lda     PL_DIV2+2
        sbc     PL_DIV+2
        sta     PL_DIV2+2       ; PL_DIV2 = M*60
        ldy     #$01
        lda     (zp_ptr),y
        jsr     from_bcd
        clc
        adc     PL_DIV2
        sta     PL_DIV2
        bcc     bmf_75
        inc     PL_DIV2+1
bmf_75:
        ; *75 = *64 + *8 + *2 + *1: accumulate into PL_DIV
        lda     PL_DIV2
        sta     PL_DIV
        lda     PL_DIV2+1
        sta     PL_DIV+1
        lda     PL_DIV2+2
        sta     PL_DIV+2        ; PL_DIV = v
        jsr     shl24_1_v2      ; PL_DIV2 = v*2
        jsr     add24_v2        ; PL_DIV += v*2
        jsr     shl24_1_v2
        jsr     shl24_1_v2      ; PL_DIV2 = v*8
        jsr     add24_v2
        jsr     shl24_1_v2
        jsr     shl24_1_v2
        jsr     shl24_1_v2      ; PL_DIV2 = v*64
        jsr     add24_v2        ; PL_DIV = v*75
        ldy     #$02
        lda     (zp_ptr),y
        jsr     from_bcd
        clc
        adc     PL_DIV
        sta     PL_DIV2
        lda     PL_DIV+1
        adc     #$00
        sta     PL_DIV2+1
        lda     PL_DIV+2
        adc     #$00
        sta     PL_DIV2+2
        rts

shl24_2:                        ; PL_DIV2 *= 4
        jsr     shl24_1_v2
shl24_1_v2:                     ; PL_DIV2 *= 2
        asl     PL_DIV2
        rol     PL_DIV2+1
        rol     PL_DIV2+2
        rts

add24_v2:                       ; PL_DIV += PL_DIV2
        clc
        lda     PL_DIV
        adc     PL_DIV2
        sta     PL_DIV
        lda     PL_DIV+1
        adc     PL_DIV2+1
        sta     PL_DIV+1
        lda     PL_DIV+2
        adc     PL_DIV2+2
        sta     PL_DIV+2
        rts

; div24_75: PL_DIV (24-bit) /= 75 by repeated subtraction;
; quotient stays in PL_DIV, remainder discarded.
div24_75:
        lda     #$00
        sta     PL_DIV2
        sta     PL_DIV2+1
        sta     PL_DIV2+2
d75_loop:
        lda     PL_DIV+2
        bne     d75_sub
        lda     PL_DIV+1
        bne     d75_sub
        lda     PL_DIV
        cmp     #75
        bcc     d75_done
d75_sub:
        sec
        lda     PL_DIV
        sbc     #75
        sta     PL_DIV
        lda     PL_DIV+1
        sbc     #$00
        sta     PL_DIV+1
        lda     PL_DIV+2
        sbc     #$00
        sta     PL_DIV+2
        inc     PL_DIV2
        bne     d75_loop
        inc     PL_DIV2+1
        bne     d75_loop
        inc     PL_DIV2+2
        bra     d75_loop
d75_done:
        lda     PL_DIV2
        sta     PL_DIV
        lda     PL_DIV2+1
        sta     PL_DIV+1
        lda     PL_DIV2+2
        sta     PL_DIV+2
        rts

; ===================================================================
; Drawing (text mode, 32x32 BAT).
; ===================================================================
pl_draw_all:
        jsr     bat_clear
        lda     #$01
        ldx     #$02
        jsr     set_cursor
        lda     #$01
        sta     zp_pal
        lda     #<str_player
        sta     zp_ptr
        lda     #>str_player
        sta     zp_ptr+1
        jsr     print_str
        jsr     pl_draw_status
        jsr     pl_draw_list
        lda     #$16
        ldx     #$02
        jsr     set_cursor
        lda     #$02
        sta     zp_pal
        lda     #<str_help1
        sta     zp_ptr
        lda     #>str_help1
        sta     zp_ptr+1
        jsr     print_str
        lda     #$17
        ldx     #$02
        jsr     set_cursor
        lda     #<str_help2
        sta     zp_ptr
        lda     #>str_help2
        sta     zp_ptr+1
        jsr     print_str
        rts

; Status line (row 3): "STOP TRK 01 00:00 / 03:45".
pl_draw_status:
        lda     PL_GFX
        beq     pds_go
        rts
pds_go:
        lda     #$03
        ldx     #$02
        jsr     set_cursor
        lda     #$00
        sta     zp_pal
        ; blank the line (28 spaces via putch loop)
        ldx     #28
pds_blank:
        lda     #$20
        jsr     putch
        dex
        bne     pds_blank
        lda     #$03
        ldx     #$02
        jsr     set_cursor
        lda     PL_STATUS
        cmp     #$00
        beq     pds_play
        cmp     #$02
        beq     pds_paus
        lda     #<str_stop
        sta     zp_ptr
        lda     #>str_stop
        sta     zp_ptr+1
        bra     pds_word
pds_play:
        lda     #<str_play
        sta     zp_ptr
        lda     #>str_play
        sta     zp_ptr+1
        bra     pds_word
pds_paus:
        lda     #<str_paus
        sta     zp_ptr
        lda     #>str_paus
        sta     zp_ptr+1
pds_word:
        jsr     print_str
        lda     #<str_trk
        sta     zp_ptr
        lda     #>str_trk
        sta     zp_ptr+1
        jsr     print_str
        ; track number (BCD): SUBQ's when playing/paused,
        ; the cursor track when stopped
        lda     PL_STATUS
        cmp     #$03
        beq     pds_curtrk
        lda     PL_SUBQBUF+2
        bra     pds_trknum
pds_curtrk:
        lda     PL_CURSOR
        jsr     to_bcd
pds_trknum:
        sta     PL_J
        jsr     print_bcd2_j
        lda     #$20
        jsr     putch
        ; elapsed rel time MM:SS (BCD from SUBQ; 00:00 stop)
        lda     PL_STATUS
        cmp     #$03
        beq     pds_zero_time
        lda     PL_SUBQBUF+4
        sta     PL_J
        jsr     print_bcd2_j
        lda     #$3A
        jsr     putch
        lda     PL_SUBQBUF+5
        sta     PL_J
        jsr     print_bcd2_j
        bra     pds_len
pds_zero_time:
        lda     #$30
        jsr     putch
        lda     #$30
        jsr     putch
        lda     #$3A
        jsr     putch
        lda     #$30
        jsr     putch
        lda     #$30
        jsr     putch
pds_len:
        lda     #<str_slash
        sta     zp_ptr
        lda     #>str_slash
        sta     zp_ptr+1
        jsr     print_str
        ; length of the shown track from PL_TLENBCD
        lda     PL_STATUS
        cmp     #$03
        beq     pds_len_cur
        lda     PL_SUBQBUF+2
        jsr     from_bcd
        bra     pds_len_idx
pds_len_cur:
        lda     PL_CURSOR
pds_len_idx:
        dec     a
        asl     a
        clc
        adc     #<PL_TLENBCD
        sta     zp_ptr
        lda     #>PL_TLENBCD
        adc     #$00
        sta     zp_ptr+1
        ldy     #$00
        lda     (zp_ptr),y
        sta     PL_J
        jsr     print_bcd2_j
        lda     #$3A
        jsr     putch
        ldy     #$01
        lda     (zp_ptr),y
        sta     PL_J
        jsr     print_bcd2_j
pds_rts:
        rts

; print_bcd2_j: print PL_J as two BCD digits.
print_bcd2_j:
        lda     PL_J
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        ora     #$30
        jsr     putch
        lda     PL_J
        and     #$0F
        ora     #$30
        jsr     putch
        rts

; Track list: rows 5..20, 16 visible from PL_WIN.
pl_draw_list:
        lda     #$00
        sta     PL_I            ; visible row counter
pdl_loop:
        lda     PL_I
        clc
        adc     #$05
        ldx     #$01
        jsr     set_cursor
        lda     #$00
        sta     zp_pal
        ldx     #30
pdl_blank:
        lda     #$20
        jsr     putch
        dex
        bne     pdl_blank
        ; track index = PL_WIN + PL_I
        lda     PL_WIN
        clc
        adc     PL_I
        cmp     PL_NTRACKS
        bcs     pdl_next
        sta     PL_J            ; 0-based track index
        lda     PL_I
        clc
        adc     #$05
        ldx     #$02
        jsr     set_cursor
        ; cursor marker
        lda     PL_J
        inc     a
        cmp     PL_CURSOR
        beq     pdl_cur
        lda     #$20
        bra     pdl_mark
pdl_cur:
        lda     #$3E            ; '>'
pdl_mark:
        jsr     putch
        lda     #<str_trk2
        sta     zp_ptr
        lda     #>str_trk2
        sta     zp_ptr+1
        jsr     print_str
        lda     PL_J
        inc     a
        jsr     print_dec2
        ; length at col 14
        lda     PL_I
        clc
        adc     #$05
        ldx     #$0E
        jsr     set_cursor
        lda     PL_J
        asl     a
        clc
        adc     #<PL_TLENBCD
        sta     zp_ptr
        lda     #>PL_TLENBCD
        adc     #$00
        sta     zp_ptr+1
        ldy     #$00
        lda     (zp_ptr),y
        sta     PL_J
        jsr     print_bcd2_j
        lda     #$3A
        jsr     putch
        ; note: PL_J was overwritten with the minutes byte;
        ; the seconds index uses the track index kept in
        ; PL_K -- move it there before the call above would
        ; be needed; instead recompute from PL_I/PL_WIN:
        lda     PL_WIN
        clc
        adc     PL_I
        asl     a
        clc
        adc     #<PL_TLENBCD
        sta     zp_ptr
        lda     #>PL_TLENBCD
        adc     #$00
        sta     zp_ptr+1
        ldy     #$01
        lda     (zp_ptr),y
        sta     PL_J
        jsr     print_bcd2_j
pdl_next:
        inc     PL_I
        lda     PL_I
        cmp     #16
        bcs     pdl_done
        jmp     pdl_loop
pdl_done:
        rts

; print_dec2: A = binary 0..99 -> two digits (leading zero).
print_dec2:
        ldx     #$00
pd2_loop:
        cmp     #10
        bcc     pd2_units
        sec
        sbc     #10
        inx
        bra     pd2_loop
pd2_units:
        sta     PL_K
        txa
        ora     #$30
        jsr     putch
        lda     PL_K
        ora     #$30
        jsr     putch
        rts

; ===================================================================
; Transport helpers.
; ===================================================================

; pl_refresh: CD_SUBQ -> PL_SUBQBUF / PL_STATUS, redraw the
; status line (suppressed in GFX mode by pl_draw_status).
pl_refresh:
        lda     #<PL_SUBQBUF
        sta     ARG_BL
        lda     #>PL_SUBQBUF
        sta     ARG_BH
        jsr     BIOS_SUBQ
        cmp     #$00            ; CD_SUBQ signals success in
        bne     pr_fail         ; A (=0); its carry-out is
        ; leftover state from the copy loop (ok_ret does not
        ; clear it) -- do not test carry here.
        lda     PL_SUBQBUF
        cmp     #$03
        bne     pr_st
        lda     PL_PAUSED       ; status 3 + player-side
        beq     pr_stop3        ; pause flag = paused (2);
        lda     #$02            ; not paused = stopped (3).
        bra     pr_st           ; (A held PL_PAUSED -- the
pr_stop3:                       ; status must be reloaded)
        lda     #$03
pr_st:
        sta     PL_STATUS
        bra     pr_draw
pr_fail:
        lda     #$03
        sta     PL_STATUS
pr_draw:
        jsr     pl_draw_status
        rts

; pl_play_track: A = binary track number. Plays it with
; CD_PLAY (TNO start, READ OUT end, mode 3).
pl_play_track:
        ldx     #$00
        stx     PL_PAUSED
        sta     PL_PLAYTRK
        sta     PL_CURSOR
        jsr     pl_fix_window
        jsr     to_bcd
        sta     ARG_AL
        lda     #$80
        sta     ARG_BH
        lda     #$00
        sta     ARG_CL
        sta     ARG_CH
        sta     ARG_DL
        lda     #$C3
        sta     ARG_DH
        jsr     BIOS_PLAY
        jsr     pl_draw_list
        jsr     pl_refresh
        rts

; pl_pause_toggle: playing -> CD_PAUSE; paused -> CD_PLAY
; from the current position; stopped -> play the cursor
; track.
pl_pause_toggle:
        lda     PL_STATUS
        cmp     #$00
        beq     ppt_pause
        cmp     #$02
        beq     ppt_resume
        lda     PL_CURSOR
        jmp     pl_play_track
ppt_pause:
        jsr     BIOS_PAUSE
        lda     #$01
        sta     PL_PAUSED
        jsr     pl_refresh
        rts
ppt_resume:
        lda     #$00
        sta     PL_PAUSED
        lda     #$C0
        sta     ARG_BH
        lda     #$C3
        sta     ARG_DH
        lda     #$00
        sta     ARG_AL
        sta     ARG_CL
        sta     ARG_CH
        sta     ARG_DL
        jsr     BIOS_PLAY
        jsr     pl_refresh
        rts

; pl_stop: raw $D8 with an all-zero address (the core's
; CDDA stop), then refresh.
pl_stop:
        lda     #$D8
        sta     zp_cdb
        lda     #$00
        ldx     #$09
pst_clear:
        sta     zp_cdb+1,x
        dex
        bpl     pst_clear
        jsr     scsi_cmd
        lda     #$00
        sta     PL_PAUSED
        sta     PL_PLAYTRK
        jsr     pl_refresh
        rts

; pl_fix_window: keep PL_CURSOR inside the visible window.
pl_fix_window:
        lda     PL_CURSOR
        dec     a               ; 0-based index
        cmp     PL_WIN
        bcs     pfw_hi
        sta     PL_WIN
        rts
pfw_hi:
        sec
        sbc     PL_WIN
        cmp     #16
        bcc     pfw_ok
        lda     PL_CURSOR
        dec     a
        sec
        sbc     #15
        sta     PL_WIN
pfw_ok:
        rts

; ===================================================================
; player_tick: one vblank of player input + housekeeping.
; Button edges are in zp_tmp0 (computed by bank 0's main
; loop); direction edges are derived here from PL_DIRPREV.
; ===================================================================
player_tick:
        inc     PL_TICK
        lda     PLB_STATE
        beq     pt_gfxchk
        jmp     bram_tick
pt_gfxchk:
        lda     PL_GFX
        beq     pt_text
        jmp     gfx_tick
pt_text:
        lda     zp_pad_dir
        eor     PL_DIRPREV
        and     zp_pad_dir
        sta     PL_E1
        lda     zp_pad_dir
        sta     PL_DIRPREV
        ; RUN always returns to the title screen
        lda     zp_tmp0
        and     #$08
        beq     pt_disc
        jsr     show_title
        rts
pt_disc:
        lda     zp_disc
        bne     pt_disc2
        rts
pt_disc2:
        ; Up: cursor to previous track
        lda     PL_E1
        and     #$01
        beq     pt_down
        lda     PL_CURSOR
        cmp     PL_TMIN
        beq     pt_down
        dec     PL_CURSOR
        jsr     pl_fix_window
        jsr     pl_draw_list
pt_down:
        lda     PL_E1
        and     #$04
        beq     pt_right
        lda     PL_CURSOR
        cmp     PL_TMAX
        beq     pt_right
        inc     PL_CURSOR
        jsr     pl_fix_window
        jsr     pl_draw_list
pt_right:                       ; Right: play next track
        lda     PL_E1
        and     #$02
        beq     pt_left
        lda     PL_PLAYTRK
        beq     pt_right_cur
        cmp     PL_TMAX
        bcs     pt_left
        inc     a
        jsr     pl_play_track
        bra     pt_left
pt_right_cur:
        lda     PL_CURSOR
        jsr     pl_play_track
pt_left:                        ; Left: play previous track
        lda     PL_E1
        and     #$08
        beq     pt_buttons
        lda     PL_PLAYTRK
        beq     pt_buttons
        cmp     PL_TMIN
        beq     pt_buttons
        dec     a
        jsr     pl_play_track
pt_buttons:
        lda     zp_tmp0
        and     #$01            ; I: play cursor track
        beq     pt_b2
        lda     PL_CURSOR
        jsr     pl_play_track
pt_b2:
        lda     zp_tmp0
        and     #$02            ; II: pause / resume
        beq     pt_bsel
        jsr     pl_pause_toggle
pt_bsel:
        lda     zp_tmp0
        and     #$04            ; Select: stop
        beq     pt_b3
        jsr     pl_stop
pt_b3:
        lda     zp_tmp0
        and     #$10            ; III: CD+G graphics
        beq     pt_b4
        jsr     gfx_enter
        bra     pt_refresh
pt_b4:
        lda     zp_tmp0
        and     #$20            ; IV: BRAM screen
        beq     pt_refresh
        jsr     bram_enter
        rts
pt_refresh:
        lda     PL_TICK
        and     #$0F
        bne     pt_rts
        jsr     pl_refresh
pt_rts:
        rts

; ===================================================================
; BRAM management screen (ws005 p006). Entered from the player
; with the IV button. Lists the backup-RAM files through
; BM_FILES, deletes the selected file with BM_DELETE (I), and
; formats after a confirmation step (II, then I). RUN returns
; to the player; from the confirm step RUN cancels instead.
; Functional-minimal, per PLAN.md 2.5. The BM calls go through
; the bank-0 glue, which saves/restores MPR6, so calling them
; from this bank-1 window is safe.
; ===================================================================
bram_enter:
        lda     #$01
        sta     PLB_STATE
        stz     PLB_CUR
        stz     PLB_WIN
        ; stage the format password in work RAM: the BM glue
        ; remaps MPR6, so the password cannot live in this
        ; bank's window
        ldx     #$0A
be_pw:  lda     bram_pw_str,x
        sta     PLB_PW,x
        dex
        bpl     be_pw
        jsr     bram_enum
        jmp     bram_draw

; bram_enum: PLB_CNT = file count. BM_FILES numbering is a
; byte: probing #255 either finds it (count saturates at 255;
; higher files are unreachable through the interface anyway)
; or reports the largest file number in _AL.
bram_enum:
        lda     #$FF
        sta     ARG_AL
        lda     #<PLB_FCB
        sta     ARG_BL
        lda     #>PLB_FCB
        sta     ARG_BH
        jsr     BIOS_BMFILES
        cmp     #$01
        beq     be_cnt          ; not found: _AL = largest = count
        cmp     #$00
        beq     be_full         ; file #255 exists: count = 255
        lda     #$00            ; $FF: no valid BRAM image
        sta     PLB_CNT
        rts
be_full:
        lda     #$FF
        sta     PLB_CNT
        rts
be_cnt:
        lda     ARG_AL
        sta     PLB_CNT
        rts

; bram_rowptr: zp_ptr = PLB_LIST + PLB_ROW * 12.
bram_rowptr:
        lda     #<PLB_LIST
        sta     zp_ptr
        lda     #>PLB_LIST
        sta     zp_ptr+1
        ldx     PLB_ROW
        beq     brp_rts
brp_add:
        lda     zp_ptr
        clc
        adc     #$0C
        sta     zp_ptr
        bcc     brp_1
        inc     zp_ptr+1
brp_1:  dex
        bne     brp_add
brp_rts:
        rts

bram_draw:
        ; enumerate the visible window into PLB_LIST
        stz     PLB_ROW
bd_enum:
        lda     PLB_WIN
        clc
        adc     PLB_ROW
        cmp     PLB_CNT
        bcs     bd_draw
        inc     a               ; BM_FILES is 1-based
        sta     ARG_AL
        jsr     bram_rowptr
        lda     zp_ptr
        sta     ARG_BL
        lda     zp_ptr+1
        sta     ARG_BH
        jsr     BIOS_BMFILES
        inc     PLB_ROW
        lda     PLB_ROW
        cmp     #$08
        bne     bd_enum
bd_draw:
        jsr     bat_clear
        lda     #$01
        ldx     #$02
        jsr     set_cursor
        lda     #$01
        sta     zp_pal
        lda     #<str_bram
        sta     zp_ptr
        lda     #>str_bram
        sta     zp_ptr+1
        jsr     print_str
        ; row 2: "FREE <bytes>" (0 when the image is invalid)
        lda     #$02
        ldx     #$02
        jsr     set_cursor
        lda     #$00
        sta     zp_pal
        lda     #<str_free
        sta     zp_ptr
        lda     #>str_free
        sta     zp_ptr+1
        jsr     print_str
        jsr     BIOS_BMFREE
        cmp     #$00
        beq     bd_free_ok
        lda     #$00
        sta     ARG_CL
        sta     ARG_CH
bd_free_ok:
        lda     ARG_CL
        sta     PLB_NUM
        lda     ARG_CH
        sta     PLB_NUM+1
        jsr     bram_dec16
        ; file rows: 8 files, BAT rows 5,7,...,19 (two BAT
        ; rows per file: the 16x16 name glyphs are 2 tiles
        ; tall -- see bram_name_draw)
        stz     PLB_ROW
bd_row:
        lda     PLB_ROW
        asl     a
        clc
        adc     #$05
        ldx     #$01
        jsr     set_cursor
        lda     #$00
        sta     zp_pal
        ldx     #30
bd_blank:
        lda     #$20
        jsr     putch
        dex
        bne     bd_blank
        lda     PLB_WIN
        clc
        adc     PLB_ROW
        cmp     PLB_CNT
        bcs     bd_next
        lda     PLB_ROW
        asl     a
        clc
        adc     #$05
        ldx     #$02
        jsr     set_cursor
        lda     PLB_WIN
        clc
        adc     PLB_ROW
        cmp     PLB_CUR
        beq     bd_cur
        lda     #$20
        bra     bd_mark
bd_cur:
        lda     #$3E            ; '>'
bd_mark:
        jsr     putch
        lda     #$20
        jsr     putch
        lda     PLB_WIN
        clc
        adc     PLB_ROW
        inc     a
        sta     PLB_NUM
        stz     PLB_NUM+1
        jsr     bram_dec16
        lda     #$20
        jsr     putch
        jsr     bram_rowptr
        jsr     bram_name_draw
bd_next:
        inc     PLB_ROW
        lda     PLB_ROW
        cmp     #$08
        beq     bd_help
        jmp     bd_row
bd_help:
        lda     #$16
        ldx     #$02
        jsr     set_cursor
        lda     #$02
        sta     zp_pal
        lda     #<str_bhelp
        sta     zp_ptr
        lda     #>str_bhelp
        sta     zp_ptr+1
        jsr     print_str
        rts

; ===================================================================
; BRAM file-name rendering with the KH 16x16 font (ws005 p007).
; FCB names are 10 bytes and may hold Shift-JIS text. The name
; is parsed as: SJIS double-byte characters (their own
; glyphs), ASCII bytes (their fullwidth forms, zenkaku_tab),
; anything else (a fullwidth '?'). Glyphs are fetched through
; EX_GETFNT itself into FN_STAGE, uploaded to VRAM tiles
; PLK_TILE0 + (row*10 + pos)*4, and written as four BAT
; entries at column 8 + pos*2 of the file row (BAT row
; 5 + PLB_ROW*2) and the row below it. File rows are two BAT
; rows tall, so the list window is 8 files.
; ===================================================================
PLK_TILE0       = $260          ; first kanji tile (VRAM): the
                                ; free gap between font8
                                ; ($200-$25E) and CD+G ($400+)
PLB_NIDX        = $2A0C         ; name byte index (0-9)
PLB_NPOS        = $2A0D         ; glyph position in the row
PLB_NLEAD       = $2A0E         ; current SJIS lead byte
PLB_NTRAIL      = $2A0F         ; current SJIS trail byte
PLB_NTILE       = $2A10         ; tile base (2 B; reuses the
                                ; PLB_FCB scratch -- bram_enum
                                ; has finished by draw time)

bram_name_draw:
        lda     zp_ptr
        sta     PLB_PLACE       ; FCB pointer save (the decimal
        lda     zp_ptr+1        ; scratch is dead during name
        sta     PLB_PLACE+1     ; draw; EX_GETFNT uses zp_ptr)
        stz     PLB_NIDX
        stz     PLB_NPOS
bnd_loop:
        lda     PLB_NIDX
        cmp     #$0A
        bne     bnd_body
        rts
bnd_body:
        lda     PLB_PLACE
        sta     zp_ptr
        lda     PLB_PLACE+1
        sta     zp_ptr+1
        ldy     PLB_NIDX
        iny
        iny                     ; Y = name offset 2..11
        lda     (zp_ptr),y
        cmp     #$81            ; SJIS lead byte?
        bcc     bnd_single
        cmp     #$A0
        bcc     bnd_lead
        cmp     #$E0
        bcc     bnd_single
        cmp     #$FD
        bcs     bnd_single
bnd_lead:
        sta     PLB_NLEAD
        lda     PLB_NIDX
        cmp     #$09
        bcs     bnd_q           ; no room for a trail byte
        ldy     PLB_NIDX
        iny
        iny
        iny                     ; Y = trail offset
        lda     (zp_ptr),y
        cmp     #$40
        bcc     bnd_q
        cmp     #$7F
        beq     bnd_q
        cmp     #$FD
        bcs     bnd_q
        sta     PLB_NTRAIL
        lda     PLB_NIDX        ; consume 2 bytes
        clc
        adc     #$02
        sta     PLB_NIDX
        bra     bnd_fetch
bnd_single:                     ; A = the byte itself
        cmp     #$20
        bcc     bnd_q
        cmp     #$7F
        bcs     bnd_q
        sec
        sbc     #$20
        asl     a
        tax
        lda     zenkaku_tab,x
        sta     PLB_NLEAD
        lda     zenkaku_tab+1,x
        sta     PLB_NTRAIL
        bra     bnd_step1
bnd_q:                          ; fullwidth '?'
        lda     #$81
        sta     PLB_NLEAD
        lda     #$48
        sta     PLB_NTRAIL
bnd_step1:
        inc     PLB_NIDX
bnd_fetch:
        lda     PLB_NLEAD
        sta     ARG_AH
        lda     PLB_NTRAIL
        sta     ARG_AL
        lda     #<FN_STAGE
        sta     ARG_BL
        lda     #>FN_STAGE
        sta     ARG_BH
        stz     ARG_DH          ; mode 0: 16x16
        jsr     BIOS_GETFNT
        cmp     #$00
        beq     bnd_have
        ldy     #$1F            ; rejected code: blank glyph
        lda     #$00
bnd_z:  sta     FN_STAGE,y
        dey
        bpl     bnd_z
bnd_have:
        jsr     plk_upload
        jsr     plk_bat
        inc     PLB_NPOS
        jmp     bnd_loop
bnd_rts:
        rts

; plk_upload: FN_STAGE (32 B, 16 rows x 2 B) -> 4 VRAM tiles
; at PLK_TILE0 + (PLB_ROW*10 + PLB_NPOS)*4. Sub-tile order
; TL, TR, BL, BR; each is 8 rows of (row byte, $00) + 8 zero
; words (plane 0 only, the font8 format).
plk_upload:
        lda     PLB_ROW
        asl     a
        asl     a
        asl     a               ; ROW*8
        sta     PLB_NTILE
        lda     PLB_ROW
        asl     a               ; ROW*2
        clc
        adc     PLB_NTILE
        adc     PLB_NPOS        ; slot = ROW*10 + NPOS (<= 79)
        sta     PLB_NTILE
        stz     PLB_NTILE+1
        asl     PLB_NTILE       ; slot * 4
        rol     PLB_NTILE+1
        asl     PLB_NTILE
        rol     PLB_NTILE+1
        clc
        lda     PLB_NTILE
        adc     #<PLK_TILE0
        sta     PLB_NTILE
        lda     PLB_NTILE+1
        adc     #>PLK_TILE0
        sta     PLB_NTILE+1
        stz     zp_tmp0         ; sub-tile counter 0..3
plu_sub:
        lda     PLB_NTILE       ; MAWR = (NTILE + sub) * 16
        clc
        adc     zp_tmp0
        sta     zp_vdcval
        lda     PLB_NTILE+1
        adc     #$00
        sta     zp_vdcval+1
        ldx     #$04
plu_sh: asl     zp_vdcval
        rol     zp_vdcval+1
        dex
        bne     plu_sh
        jsr     vdc_set_mawr
        ldy     #VDC_VWR
        sty     a:VDC_SEL
        lda     zp_tmp0         ; src offset = (sub>>1)*16
        lsr     a               ;   + (sub&1), row step 2
        asl     a
        asl     a
        asl     a
        asl     a
        sta     zp_tmp1
        lda     zp_tmp0
        and     #$01
        clc
        adc     zp_tmp1
        sta     zp_tmp1
        ldx     #$08            ; 8 pattern rows
plu_row:
        ldy     zp_tmp1
        lda     FN_STAGE,y
        sta     a:VDC_DLO
        lda     #$00
        sta     a:VDC_DHI
        lda     zp_tmp1
        clc
        adc     #$02
        sta     zp_tmp1
        dex
        bne     plu_row
        ldx     #$08            ; 8 zero words
plu_zero:
        lda     #$00
        sta     a:VDC_DLO
        sta     a:VDC_DHI
        dex
        bne     plu_zero
        inc     zp_tmp0
        lda     zp_tmp0
        cmp     #$04
        bne     plu_sub
        rts

; plk_bat: write the glyph's 4 BAT entries at (batrow, col)
; and (batrow+1, col); batrow = 5 + PLB_ROW*2, col =
; 8 + PLB_NPOS*2. Palette 0, so the entry is the tile index.
; MAWR auto-increment covers TL->TR and BL->BR.
plk_bat:
        lda     PLB_ROW
        asl     a
        clc
        adc     #$05
        sta     zp_tmp2         ; batrow
        lda     PLB_NPOS
        asl     a
        clc
        adc     #$08
        tax                     ; X = col
        lda     zp_tmp2
        jsr     set_cursor
        ldy     #VDC_VWR
        sty     a:VDC_SEL
        lda     PLB_NTILE
        sta     a:VDC_DLO
        lda     PLB_NTILE+1
        sta     a:VDC_DHI
        lda     PLB_NTILE
        clc
        adc     #$01
        sta     a:VDC_DLO
        lda     PLB_NTILE+1
        adc     #$00
        sta     a:VDC_DHI
        lda     PLB_NPOS
        asl     a
        clc
        adc     #$08
        tax
        lda     zp_tmp2
        inc     a               ; batrow + 1
        jsr     set_cursor
        ldy     #VDC_VWR
        sty     a:VDC_SEL
        lda     PLB_NTILE
        clc
        adc     #$02
        sta     a:VDC_DLO
        lda     PLB_NTILE+1
        adc     #$00
        sta     a:VDC_DHI
        lda     PLB_NTILE
        clc
        adc     #$03
        sta     a:VDC_DLO
        lda     PLB_NTILE+1
        adc     #$00
        sta     a:VDC_DHI
        rts

; ASCII $20-$7E -> Shift-JIS fullwidth forms (JIS X 0208
; ku 1-3), for bram_name_draw. '"' and '\'' have no JIS
; fullwidth forms; the JIS left/right quotes are used.
zenkaku_tab:
        .byte $81,$40,$81,$49,$81,$67,$81,$94,$81,$90  ; _!"#$
        .byte $81,$93,$81,$95,$81,$66,$81,$69,$81,$6A  ; %&'()
        .byte $81,$96,$81,$7B,$81,$43,$81,$5C,$81,$44  ; *+,-.
        .byte $81,$5E,$82,$4F,$82,$50,$82,$51,$82,$52  ; /0123
        .byte $82,$53,$82,$54,$82,$55,$82,$56,$82,$57  ; 45678
        .byte $82,$58,$81,$46,$81,$47,$81,$83,$81,$81  ; 9:;<=
        .byte $81,$84,$81,$48,$81,$97,$82,$60,$82,$61  ; >?@AB
        .byte $82,$62,$82,$63,$82,$64,$82,$65,$82,$66  ; CDEFG
        .byte $82,$67,$82,$68,$82,$69,$82,$6A,$82,$6B  ; HIJKL
        .byte $82,$6C,$82,$6D,$82,$6E,$82,$6F,$82,$70  ; MNOPQ
        .byte $82,$71,$82,$72,$82,$73,$82,$74,$82,$75  ; RSTUV
        .byte $82,$76,$82,$77,$82,$78,$82,$79,$81,$6D  ; WXYZ[
        .byte $81,$5F,$81,$6E,$81,$4F,$81,$51,$81,$4D  ; \]^_`
        .byte $82,$81,$82,$82,$82,$83,$82,$84,$82,$85  ; abcde
        .byte $82,$86,$82,$87,$82,$88,$82,$89,$82,$8A  ; fghij
        .byte $82,$8B,$82,$8C,$82,$8D,$82,$8E,$82,$8F  ; klmno
        .byte $82,$90,$82,$91,$82,$92,$82,$93,$82,$94  ; pqrst
        .byte $82,$95,$82,$96,$82,$97,$82,$98,$82,$99  ; uvwxy
        .byte $82,$9A,$81,$6F,$81,$62,$81,$70,$81,$60  ; z{|}~

bram_draw_confirm:
        jsr     bat_clear
        lda     #$05
        ldx     #$02
        jsr     set_cursor
        lda     #$01
        sta     zp_pal
        lda     #<str_bask
        sta     zp_ptr
        lda     #>str_bask
        sta     zp_ptr+1
        jsr     print_str
        lda     #$07
        ldx     #$02
        jsr     set_cursor
        lda     #$00
        sta     zp_pal
        lda     #<str_byes
        sta     zp_ptr
        lda     #>str_byes
        sta     zp_ptr+1
        jsr     print_str
        rts

; bram_dec16: print PLB_NUM (16-bit) in decimal, no leading
; zeros. Working state in PLB_LEAD/PLB_PIDX/PLB_PLACE/PLB_DIG.
bram_dec16:
        stz     PLB_LEAD
        stz     PLB_PIDX
bd16_place:
        lda     PLB_PIDX
        asl     a
        tax
        lda     bd16_tab,x
        sta     PLB_PLACE
        lda     bd16_tab+1,x
        sta     PLB_PLACE+1
        lda     #$00
        sta     PLB_DIG
bd16_sub:
        lda     PLB_NUM
        cmp     PLB_PLACE
        lda     PLB_NUM+1
        sbc     PLB_PLACE+1
        bcc     bd16_out
        lda     PLB_NUM
        sec
        sbc     PLB_PLACE
        sta     PLB_NUM
        lda     PLB_NUM+1
        sbc     PLB_PLACE+1
        sta     PLB_NUM+1
        inc     PLB_DIG
        bra     bd16_sub
bd16_out:
        lda     PLB_DIG
        bne     bd16_pr
        lda     PLB_LEAD
        bne     bd16_pr
        lda     PLB_PIDX
        cmp     #$04            ; the units place always prints
        bne     bd16_next
bd16_pr:
        lda     #$01
        sta     PLB_LEAD
        lda     PLB_DIG
        ora     #$30
        jsr     putch
bd16_next:
        inc     PLB_PIDX
        lda     PLB_PIDX
        cmp     #$05
        bne     bd16_place
        rts
bd16_tab:
        .word   10000, 1000, 100, 10, 1

bram_fixwin:
        lda     PLB_CUR
        cmp     PLB_WIN
        bcs     bf_hi
        sta     PLB_WIN
        rts
bf_hi:  sec
        sbc     PLB_WIN         ; A = CUR - WIN
        cmp     #$08
        bcc     bf_ok
        lda     PLB_CUR
        sec
        sbc     #$07
        sta     PLB_WIN
bf_ok:  rts

bram_tick:
        ; direction edges, same scheme as pt_text
        lda     zp_pad_dir
        eor     PL_DIRPREV
        and     zp_pad_dir
        sta     PL_E1
        lda     zp_pad_dir
        sta     PL_DIRPREV
        ; RUN: cancel the confirm step, else exit to the player
        lda     zp_tmp0
        and     #$08
        beq     bt_state
        lda     PLB_STATE
        cmp     #$02
        beq     bt_cancel
        stz     PLB_STATE
        jsr     pl_draw_all
        rts
bt_cancel:
        lda     #$01
        sta     PLB_STATE
        jsr     bram_draw
        rts
bt_state:
        lda     PLB_STATE
        cmp     #$02
        bne     bt_list
        jmp     bt_confirm
bt_list:
        ; --- list state -------------------------------------
        lda     PL_E1
        and     #$01            ; Up
        beq     bt_down
        lda     PLB_CUR
        beq     bt_down
        dec     PLB_CUR
        jsr     bram_fixwin
        jsr     bram_draw
        rts
bt_down:
        lda     PL_E1
        and     #$04            ; Down
        beq     bt_i
        lda     PLB_CUR
        inc     a
        cmp     PLB_CNT
        bcs     bt_i
        sta     PLB_CUR
        jsr     bram_fixwin
        jsr     bram_draw
        rts
bt_i:   ; I: delete the selected file
        lda     zp_tmp0
        and     #$01
        beq     bt_ii
        lda     PLB_CNT
        beq     bt_rts
        lda     PLB_CUR
        sec
        sbc     PLB_WIN
        sta     PLB_ROW
        jsr     bram_rowptr
        lda     zp_ptr
        sta     ARG_AL
        lda     zp_ptr+1
        sta     ARG_AH
        jsr     BIOS_BMDEL
        jsr     bram_enum
        lda     PLB_CNT
        beq     bt_cl0
        cmp     PLB_CUR
        bcs     bt_keep         ; CNT > CUR: cursor still valid
        lda     PLB_CNT
        sec
        sbc     #$01
        sta     PLB_CUR
        bra     bt_keep
bt_cl0: stz     PLB_CUR
bt_keep:
        jsr     bram_fixwin
        jsr     bram_draw
        rts
bt_ii:  ; II: ask for format confirmation
        lda     zp_tmp0
        and     #$02
        beq     bt_rts
        lda     #$02
        sta     PLB_STATE
        jsr     bram_draw_confirm
bt_rts: rts
bt_confirm:
        lda     zp_tmp0
        and     #$01            ; I: yes, format
        beq     bt_rts
        lda     #<PLB_PW
        sta     ARG_AL
        lda     #>PLB_PW
        sta     ARG_AH
        jsr     BIOS_BMFMT
        lda     #$01
        sta     PLB_STATE
        stz     PLB_CUR
        stz     PLB_WIN
        jsr     bram_enum
        jsr     bram_draw
        rts

; ===================================================================
; Strings (COMPAT3's own wording).
; ===================================================================
str_player:     .byte "CD PLAYER", 0
str_nodisc:     .byte "NO DISC", 0
str_runret:     .byte "PRESS RUN TO RETURN", 0
str_stop:       .byte "STOP", 0
str_play:       .byte "PLAY", 0
str_paus:       .byte "PAUS", 0
str_trk:        .byte " TRK ", 0
str_trk2:       .byte " TRK ", 0
str_slash:      .byte " / ", 0
str_help1:      .byte "I:PLAY II:PAUSE SEL:STOP", 0
str_help2:      .byte "LR:NEXT III:GFX RUN:EXIT", 0
str_bram:       .byte "BRAM FILES", 0
str_free:       .byte "FREE ", 0
str_bhelp:      .byte "I:DELETE II:FORMAT RUN:BACK", 0
str_bask:       .byte "FORMAT BRAM?", 0
str_byes:       .byte "I:YES RUN:NO", 0
bram_pw_str:    .byte "!BM FORMAT!"

; ===================================================================
; CD+G graphics mode. The 288x192 framebuffer (one byte per
; pixel, palette index) lives in CD RAM banks $69-$6F and
; is shown through a 64-wide BAT: tile (tx,ty) of the 36x24
; grid is BG tile GFX_TILE0 + ty*36 + tx, palette 0 (the
; CD+G colour table is loaded into VCE palette 0).
;
; Framebuffer addressing: offset = y*288 + x (16-bit);
; bank = GFX_FB_BANK + (offset >> 13); window address =
; $4000 + (offset & $1FFF) via MPR2. Spans that would cross
; a bank boundary are split or written per pixel.
; ===================================================================

gfx_enter:
ge_vdc:
        ; VDC: BAT 64 wide (MWR $10), display 36 tiles wide
        ldy     #VDC_MWR
        ldx     #$10
        lda     #$00
        jsr     vdc_write
        ldy     #VDC_HDR
        ldx     #$23
        lda     #$04
        jsr     vdc_write
        ; BAT fill: 64x32 entries
        lda     #$00
        sta     zp_vdcval
        sta     zp_vdcval+1
        jsr     vdc_set_mawr
        ldy     #VDC_VWR
        sty     a:VDC_SEL
        lda     #$00
        sta     PL_TY
ge_baty:
        lda     #$00
        sta     PL_TX
ge_batx:
        jsr     ge_tile_index   ; PL_DIV = tile index
        lda     PL_DIV
        sta     a:VDC_DLO
        lda     PL_DIV+1
        sta     a:VDC_DHI
        inc     PL_TX
        lda     PL_TX
        cmp     #64
        bne     ge_batx
        inc     PL_TY
        lda     PL_TY
        cmp     #32
        bne     ge_baty
        ; framebuffer clear (colour 0)
        lda     #$00
        sta     PL_COLOR
        jsr     gfx_fb_fill
        jsr     gfx_dirty_all
        ; CLUT shadow + VCE palette 0 cleared to black
        ldx     #31
        lda     #$00
ge_clut:
        sta     PL_CLUT,x
        dex
        bpl     ge_clut
        lda     #$00
        sta     VCE_PAL_LO
        sta     VCE_PAL_HI
        ldx     #16
ge_vce:
        lda     #$00
        sta     VCE_PAL_DLO
        sta     VCE_PAL_DHI
        dex
        bne     ge_vce
        lda     #$00
        sta     PL_DBBUSY
        sta     PL_HDEPTH
        sta     PL_GOTBYTE
        sta     PL_UPCNT
        sta     PL_PKTN
        sta     PL_QHEAD
        sta     PL_QHEAD+1
        sta     PL_QTAIL
        sta     PL_QTAIL+1
        lda     #$FE
        sta     PL_PHASE        ; decoder: entry hunt
        lda     #$FF
        sta     PL_PREV         ; no previous byte yet
        lda     #$00
        sta     PL_GOFFX
        sta     PL_GOFFY
        sta     PL_UPIDX
        sta     PL_UPIDX+1
        sta     PL_HSKIP
        lda     #<864
        sta     PL_CHKCAP
        lda     #>864
        sta     PL_CHKCAP+1
        lda     #96
        sta     PL_UPCAP
        lda     #$FF
        sta     PL_LASTRPT
        ; Start the cursor track only now, with all
        ; setup done.  The play is (re)issued even if
        ; the same track is already playing: setup
        ; takes long enough that a decoder locking
        ; onto the live stream mid-track misses the
        ; opening scene (CD+G is stateful -- the
        ; colour bars are built by the track's first
        ; packs and never repeated).  Restarting the
        ; track puts the stream start after setup, so
        ; the decoder sees the scene from pack 0.
        ; (An earlier build avoided the re-issue
        ; because the stream "crawled and died"; that
        ; was the gfx_dirty_tileblock low-byte bug
        ; starving the feed, not a core quirk.)
ge_start:
        lda     #$00
        sta     PL_PAUSED
        lda     PL_CURSOR
        sta     PL_PLAYTRK
        jsr     to_bcd
        sta     ARG_AL
        lda     #$80
        sta     ARG_BH
        lda     #$00
        sta     ARG_CL
        sta     ARG_CH
        sta     ARG_DL
        lda     #$C3
        sta     ARG_DH
        jsr     BIOS_PLAY
        lda     #$00
        sta     PL_STATUS
        lda     #$01
        sta     PL_GFX
        rts

; ge_tile_index: PL_DIV (16-bit) = BG tile index for BAT
; position (PL_TX, PL_TY): inside the 36x24 image ->
; GFX_TILE0 + PL_TY*36 + PL_TX; outside -> the blank tile
; GFX_TILE0 + 864 (kept zeroed).
ge_tile_index:
        lda     PL_TY
        cmp     #24
        bcs     ge_blank
        lda     PL_TX
        cmp     #36
        bcs     ge_blank
        lda     PL_TY
        asl     a
        asl     a
        sta     PL_K            ; TY*4 (TY <= 23 -> <= 92)
        lda     PL_TY
        asl     a
        asl     a
        asl     a
        asl     a
        asl     a               ; TY*32, low byte
        sta     PL_DIV
        lda     PL_TY
        lsr     a
        lsr     a
        lsr     a               ; (TY*32) >> 8 = TY >> 3
        sta     PL_DIV+1
        lda     PL_DIV
        clc
        adc     PL_K
        sta     PL_DIV
        bcc     ge_ti_tx
        inc     PL_DIV+1
ge_ti_tx:
        lda     PL_DIV
        clc
        adc     PL_TX
        sta     PL_DIV
        lda     PL_DIV+1
        adc     #>GFX_TILE0     ; GFX_TILE0 = $400: low byte
        sta     PL_DIV+1        ; $00 adds nothing to PL_DIV
        rts
ge_blank:
        lda     #<(GFX_TILE0 + 864)
        sta     PL_DIV
        lda     #>(GFX_TILE0 + 864)
        sta     PL_DIV+1
        rts

gfx_exit:
        ldy     #VDC_MWR
        ldx     #$00
        lda     #$00
        jsr     vdc_write
        ldy     #VDC_HDR
        ldx     #$1F
        lda     #$04
        jsr     vdc_write
        ; restore VCE entries 0..15 (text palette 0):
        ; entry 0 = backdrop $005, entry 1 = white $1FF,
        ; entries 2..15 = $005
        lda     #$00
        sta     VCE_PAL_LO
        sta     VCE_PAL_HI
        lda     #$05
        sta     VCE_PAL_DLO
        lda     #$00
        sta     VCE_PAL_DHI
        lda     #$FF
        sta     VCE_PAL_DLO
        lda     #$01
        sta     VCE_PAL_DHI
        ldx     #14
gx_vce:
        lda     #$05
        sta     VCE_PAL_DLO
        lda     #$00
        sta     VCE_PAL_DHI
        dex
        bne     gx_vce
        lda     #$00
        sta     PL_GFX
        jsr     pl_draw_all
        jsr     pl_refresh
        rts

; gfx_drain_some: drain up to 1024 CD_SUBRQ attempts,
; feeding the decoder.  Called from bank 0's vblank spin
; (via the MPR6 glue) so the FIFO never sits undrained
; while the shell waits for the next frame.  No uploads
; or input here -- just the stream.
gfx_drain_some:
        lda     #$00
        sta     PL_GDS_C
        lda     #$04            ; 4 x 256 = 1024 attempts
        sta     PL_GDS_C+1
        lda     #192            ; fed-byte budget (see
        sta     PL_FEDBUD       ; gfx_tick's note)
gds_loop:
        jsr     gfx_poll_feed
        bcs     gds_next
        dec     PL_FEDBUD       ; a byte was fed: count it
        beq     gds_done        ; (the spin re-calls us)
gds_next:
        inc     PL_GDS_C
        bne     gds_loop
        inc     PL_GDS_C+1
        lda     PL_GDS_C+1
        cmp     #$08
        bcc     gds_loop
gds_done:
        rts

; gfx_tick: one GRAPHICS-mode tick.
gfx_tick:
        ; GRAPHICS tick. The subcode FIFO is only 16 bytes
        ; deep while CDDA playback produces ~122 subcode
        ; bytes per frame, so the drain must run near-
        ; continuously: poll CD_SUBRQ in chunks, and between
        ; chunks upload a few dirty tiles (a whole-frame
        ; upload batch would overflow the FIFO and break
        ; the sync lock). Pad input is handled once per
        ; tick by the caller-visible state as before.
        lda     #8              ; 8 chunks x 256 attempts
        sta     PL_TBUD         ; = ~2000 CD_SUBRQ polls.
        lda     #192            ; fed-byte budget: with the
        sta     PL_FEDBUD       ; 1 KB raw queue a tick can
                                ; otherwise chew through the
                                ; whole backlog (dozens of
                                ; frames) and starve read_pad
                                ; sampling -- the gate's II
                                ; tap was lost exactly that
                                ; way.  192 B > the 122.5
                                ; B/frame production rate, so
                                ; the stream still keeps up.
                                ; The vblank spin's
                                ; gfx_drain_some does most of
                                ; the feeding; this loop only
                                ; has to keep up with uploads
                                ; and input.  A long tick
                                ; (48 chunks could span ~20
                                ; frames in dense content)
                                ; starves read_pad sampling:
                                ; a short pad tap can start
                                ; and end between two samples
                                ; and its edge is lost
                                ; (measured: the gate's II
                                ; pause tap was missed).
gt_loop:
        lda     #0
        sta     PL_K2           ; drain chunk: 256 attempts
gt_dchunk:
        jsr     gfx_poll_feed
        bcs     gt_dnext
        lda     #$01
        sta     PL_GOTBYTE
        dec     PL_FEDBUD
        beq     gt_buttons      ; fed-byte budget spent:
                                ; go sample the pad
gt_dnext:
        inc     PL_K2
        bne     gt_dchunk
        ; Upload dirty tiles when the stream is
        ; momentarily idle (the last chunk received no
        ; byte), or every 4th chunk at the latest.
        ; (Item 3.1 measurement: a CD+G stream is never
        ; byte-idle during playback -- zero packs flow
        ; constantly -- so the original every-16th-chunk
        ; rule repainted a full picture only after
        ; ~7 s, where the genuine card needs ~1 s.
        ; The per-row drains inside gfx_upload_one
        ; service the FIFO during uploads, and the
        ; decoder's bounded recovery contains the
        ; occasional byte lost to a long upload.)
        inc     PL_UPCNT
        lda     PL_GOTBYTE
        beq     gt_doup
        lda     #$00
        sta     PL_GOTBYTE
        lda     PL_UPCNT
        cmp     #4
        bcc     gt_noup
gt_doup:
        lda     #$00
        sta     PL_UPCNT
        lda     #16
        sta     PL_CHKCAP
        lda     #$00
        sta     PL_CHKCAP+1
        lda     #8              ; per-chunk upload cap
        sta     PL_UPCAP        ; while playing (the
                                ; per-row drains inside
                                ; gfx_upload_one keep the
                                ; FIFO serviced)
        lda     PL_STATUS       ; while paused or stopped
        beq     gt_up2          ; there is no live stream
        lda     #128            ; to protect: upload the
        sta     PL_CHKCAP       ; pending picture at full
        lda     #32             ; speed so the paused
        sta     PL_UPCAP        ; frame settles at once
gt_up2:
        jsr     gfx_upload
gt_noup:
        dec     PL_TBUD
        bne     gt_loop
gt_buttons:
        lda     zp_pad_dir
        sta     PL_DIRPREV
        ; RUN or III exits graphics mode
        lda     zp_tmp0
        and     #$18
        beq     gt_b2
        jsr     gfx_exit
        rts
gt_b2:
        lda     zp_tmp0
        and     #$02            ; II: pause / resume
        beq     gt_b1
        jsr     pl_refresh      ; on-demand status (see below)
        jsr     pl_pause_toggle
gt_b1:
        lda     zp_tmp0
        and     #$01            ; I: play if stopped/paused
        beq     gt_rts
        jsr     pl_refresh
        lda     PL_STATUS
        beq     gt_rts
        jsr     pl_pause_toggle
gt_rts:
        rts
        ; NOTE: no periodic pl_refresh in GRAPHICS mode.
        ; A $DD command occupies the SCSI bus (and this
        ; loop) long enough for the 16-byte subcode FIFO
        ; to overflow, punching a hole in the stream and
        ; costing the sync lock -- the status is refreshed
        ; on demand when a transport key is pressed.

; gfx_feed: A = one subcode byte from the $1807 FIFO.
; The FIFO carries the on-disc subcode symbol stream:
; 98 symbols per sector, positions 0/1 being the sync
; symbols ($00, $80 -- the $80 is unique because data
; symbols are 7-bit) and positions 2..97 the 96 data
; symbols.  CD+G packs are interleaved across the data
; symbols (the CD subcode delay-line interleave,
; measured against the .sub ground truth in the p005
; differential).
; -------------------------------------------------------------------
; CD+G stream decoder (third generation, item 3.1).
;
; The core stuffs one subcode byte every 6 stereo
; samples during CD-DA playback: per sector exactly
; [$00, $80, 96 data symbols].  PL_PHASE counts EVERY
; byte mod 98 (0 = first marker due, 1 = second,
; 2..97 = data symbols, which are stored).  Because
; the markers are counted too, the framing cannot
; drift: any loss is detected at the next pair check,
; at most one sector later.
;
; Failure handling (the FIFO is 16 bytes deep, so a
; byte can be lost while the CPU is busy elsewhere):
;  - data symbol dropped: the sector's $00 marker is
;    stored as its 96th symbol (the placeholder) and
;    the $80 arrives at phase 0, where the early-pair
;    rule consumes it as the pair's second half.
;    Exact count, one symbol wrong, next sector clean.
;  - marker dropped: the byte at the pair check is a
;    data byte -> recovery hunt.
;  - recovery hunt: discard bytes until the [$00,
;    $80] pair (in this core's stream $80 only ever
;    appears as a marker, so the first pair found is
;    a true sector boundary, and the discarded span
;    is provably a suffix of one sector's data).
;    Exactly the discarded data symbols are then
;    zero-filled into the ring, so the absolute
;    symbol alignment the deinterleave relies on is
;    preserved; damage is bounded to the affected
;    sector(s).  PL_PHASE $FE = entry hunt (no fill:
;    alignment starts at the lock), $FF = recovery.
gfx_feed:
        pha
        lda     PL_SAVEB
        sta     PL_PREV         ; previous fed byte
        pla
        sta     PL_SAVEB
        lda     PL_PHASE
        cmp     #$FE
        bne     gf3_nfe
        jmp     gf3_hunt0
gf3_nfe:
        cmp     #$FF
        bne     gf3_nff
        jmp     gf3_hunt1
gf3_nff:
        cmp     #2
        bcs     gf3_data
        cmp     #1
        beq     gf3_p1
        ; phase 0: the first marker byte is due
        lda     PL_SAVEB
        cmp     #$00
        bne     gf3_p0x
        lda     #1
        sta     PL_PHASE
        rts
gf3_p0x:
        cmp     #$80
        beq     gf3_early_pair
        jmp     gf3_to_hunt     ; a data byte: resync
gf3_early_pair:
        ; $80 at phase 0: the pair arrived one byte
        ; early (a data symbol was dropped last
        ; sector; its $00 half was stored as the 96th
        ; symbol and stands as the placeholder) or
        ; the $00 half was dropped (this $80 is the
        ; pair's second half).  Either way the pair
        ; is consumed and the symbol count is exact.
        lda     #2
        sta     PL_PHASE
        lda     #$00
        sta     PL_GRPCNT       ; re-anchor the group
        sta     PL_HSKIP        ; grid (96 = 4 groups)
        lda     PL_RINGW
        sta     PL_RINGW_SYNC
        rts
gf3_p1:
        ; phase 1: the second marker byte is due
        lda     PL_SAVEB
        cmp     #$80
        bne     gf3_to_hunt     ; dropped: resync
        lda     #2
        sta     PL_PHASE
        lda     #$00
        sta     PL_GRPCNT       ; re-anchor the group
        sta     PL_HSKIP        ; grid (96 = 4 groups)
        lda     PL_RINGW
        sta     PL_RINGW_SYNC
        rts
gf3_data:
        ; phases 2..97: a data symbol
        lda     PL_SAVEB
        jsr     gf_symbol
        inc     PL_PHASE
        lda     PL_PHASE
        cmp     #98
        bne     gf3_rts
        lda     #$00
        sta     PL_PHASE
gf3_rts:
        rts

; a pair check failed: enter the recovery hunt.
; The failing byte is a data byte of the stream and
; is processed by the hunt below as its first byte;
; PL_HSKIP suppresses the previous-byte count for
; it (the byte before it is a stored symbol or the
; phase-0 marker, never a discarded data byte).
gf3_to_hunt:
        lda     #$00
        sta     PL_HCNT
        lda     #$FF
        sta     PL_PHASE
        lda     #$01
        sta     PL_HSKIP
        ; fall through to the hunt with PL_SAVEB set
gf3_hunt1:
        lda     PL_SAVEB
        cmp     #$80
        bne     gh1_not80
        lda     PL_PREV
        cmp     #$00
        bne     gh1_cnt80
        ; the pair: lock.  Zero-fill exactly the
        ; discarded data symbols, then resume at
        ; phase 2 (this sector's data follows).
        lda     PL_HCNT
        beq     gh1_locked
gh1_fill:
        lda     #$00
        jsr     gf_symbol
        dec     PL_HCNT
        bne     gh1_fill
gh1_locked:
        lda     #2
        sta     PL_PHASE
        rts
gh1_cnt80:
        inc     PL_HCNT         ; $80 not after $00:
        jmp     gh1_prev        ; a data byte here
gh1_not80:
        cmp     #$00
        beq     gh1_zero
        inc     PL_HCNT         ; an ordinary data byte
        jmp     gh1_prev
gh1_zero:
        ; a $00: not counted yet -- it is data only
        ; if the next byte is not $80 (counted then,
        ; via gh1_prev of that byte)
        nop
gh1_prev:
        ; the previous byte, if it was an uncounted
        ; $00, is now known to be data: count it.
        ; (Skipped for the hunt's first byte.)
        lda     PL_HSKIP
        bne     gh1_skip1
        lda     PL_PREV
        cmp     #$00
        bne     gh1_skip1
        inc     PL_HCNT
gh1_skip1:
        lda     #$00
        sta     PL_HSKIP
        rts

; entry hunt: scan for the pair; at the lock, zero
; the ring (absolute alignment starts here).
gf3_hunt0:
        lda     PL_SAVEB
        cmp     #$80
        bne     gf3_rts
        lda     PL_PREV
        cmp     #$00
        bne     gf3_rts
        ldx     #$00
        lda     #$00
gf3_z0:
        sta     PL_SYMRING,x
        inx
        bne     gf3_z0
        sta     PL_RINGW
        sta     PL_RINGW_SYNC
        sta     PL_GRPCNT
        lda     #2
        sta     PL_PHASE
        rts

gf_symbol:                      ; A = data symbol
        and     #$3F            ; only the R-W channel bits
        ; form the CD+G symbol (the P/Q bits are stripped;
        ; measured in the p005 ground-truth comparison)
        ldx     PL_RINGW
        sta     PL_SYMRING,x
        inc     PL_RINGW
        inc     PL_GRPCNT
        lda     PL_GRPCNT
        cmp     #24
        bcs     gf_grp
        rts
gf_grp:
        lda     #$00
        sta     PL_GRPCNT
        ; one 24-symbol group completed: emit the next pack
gf_emit:
        ldx     #$00
gf_emit_loop:
        lda     deint_tab,x
        clc
        adc     PL_RINGW
        tay
        lda     PL_SYMRING,y
        sta     PL_PKT,x
        inx
        cpx     #24
        bne     gf_emit_loop
        lda     PL_PKT
        and     #$3F
        cmp     #$09
        beq     gf_call_pkt
        rts
gf_call_pkt:
        jsr     gfx_packet
        rts

; deint_tab[k] = (src_k - d_k * 24) mod 256, from the
; measured deinterleave (p005): (d, src) pairs are
; (8,0) (6,18) (3,5) (1,23) (4,4) (6,2) (2,6) (1,7)
; (8,8) (7,9) (6,10) (5,11) (4,12) (3,13) (2,14) (1,15)
; (8,16) (7,17) (7,1) (5,19) (4,20) (3,21) (2,22) (5,3).
deint_tab:
        .byte   64, 130, 189, 255, 164, 114, 214, 239
        .byte   72, 97, 122, 147, 172, 197, 222, 247
        .byte   80, 105, 89, 155, 180, 205, 230, 139

; gfx_packet: execute one CD+G packet (PL_PKT, 24 bytes;
; data[i] = PL_PKT+4+i, used masked with $3F).
gfx_packet:
        inc     PL_HDEPTH
        jsr     gfx_packet_body
        dec     PL_HDEPTH
        rts
gfx_packet_body:
        lda     PL_PKT+1
        and     #$3F
        cmp     #1
        beq     gp_preset
        cmp     #2
        bne     gp_d0
        jmp     gp_border
gp_d0:
        cmp     #6              ; Tile Block (normal)
        bne     gp_d1
        jmp     gp_tile
gp_d1:
        cmp     #20
        bne     gp_d2
        jmp     gp_scroll_pre
gp_d2:
        cmp     #24
        bne     gp_d3
        jmp     gp_scroll_cpy
gp_d3:
        cmp     #30
        bne     gp_d4
        jmp     gp_clut_lo
gp_d4:
        cmp     #31
        bne     gp_d5
        jmp     gp_clut_hi
gp_d5:
        cmp     #38             ; Tile Block (XOR)
        bne     gp_d6
        jmp     gp_tile_xor
gp_d6:
        rts

; --- Memory Preset -----------------------------------------
; gfx_pause_da / gfx_resume_da: halt CD-DA production
; around a long graphics handler (preset fill, border,
; scroll) so the 16-byte FIFO + 1 KB raw queue cannot
; overflow while it runs; the resume continues at the
; paused position.  PL_SCPAUSED records whether this
; handler paused (never nested: packet handlers run
; sequentially and handler-time drains do not feed).
gfx_pause_da:
        lda     #$00
        sta     PL_SCPAUSED
        lda     PL_STATUS
        bne     gpd_rts         ; not playing: no production
        lda     PL_PAUSED
        bne     gpd_rts         ; user pause: already halted
        jsr     BIOS_PAUSE
        bcc     gpd_rts         ; pause failed: proceed live
        lda     #$01
        sta     PL_SCPAUSED
gpd_rts:
        rts

gfx_resume_da:
        lda     PL_SCPAUSED
        beq     grd_rts
        lda     #$00
        sta     PL_SCPAUSED
        lda     #$C0            ; resume-from-pause argument
        sta     ARG_BH          ; pattern (same as
        lda     #$C3            ; pl_pause_toggle's resume)
        sta     ARG_DH
        lda     #$00
        sta     ARG_AL
        sta     ARG_CL
        sta     ARG_CH
        sta     ARG_DL
        jsr     BIOS_PLAY
grd_rts:
        rts

gp_preset:
        lda     PL_PKT+5        ; data[1] = repeat count
        and     #$0F
        cmp     PL_LASTRPT
        beq     gp_rts          ; repeated broadcast: skip
        sta     PL_LASTRPT
        lda     PL_PKT+4        ; data[0] = colour
        and     #$0F
        sta     PL_COLOR
        jsr     gfx_pause_da
        jsr     gfx_fb_fill
        jsr     gfx_dirty_all
        jsr     gfx_resume_da
gp_rts:
        rts

; --- Border Preset ------------------------------------------
gp_border:
        lda     PL_PKT+4
        and     #$0F
        sta     PL_COLOR
        jsr     gfx_pause_da
        lda     #$00
        sta     PL_FBY
        lda     #6
        sta     PL_GFR_I
        jsr     gfx_fill_rows   ; rows 0..5
        lda     #186
        sta     PL_FBY
        lda     #6
        sta     PL_GFR_I
        jsr     gfx_fill_rows   ; rows 186..191
        ; side columns, rows 6..185: 6-byte spans whose
        ; window offsets provably stay inside the bank
        ; (row starts are multiples of 32 <= 8160; the
        ; x=282 span peaks at offset 8186, +6 = 8192).
        lda     #6
        sta     PL_FBY
gb_side:
        lda     PL_FBY
        jsr     gfx_row_ptr
        ldy     #$00
        lda     PL_COLOR
gb_s1:
        sta     (zp_ptr),y
        iny
        cpy     #6
        bne     gb_s1
        lda     #<282
        sta     PL_FBX
        lda     #>282
        sta     PL_FBX+1
        jsr     gfx_xy_ptr      ; (PL_FBX, PL_FBY) -- PL_FBY
                                ; still holds the row
        ldy     #$00
        lda     PL_COLOR
gb_s2:
        sta     (zp_ptr),y
        iny
        cpy     #6
        bne     gb_s2
        inc     PL_FBY
        jsr     drain_burst     ; keep the FIFO drained per
                                ; row (this loop previously
                                ; ran ~170K cycles undrained
                                ; and dropped stream bytes --
                                ; item 3.1 measurement)
        lda     PL_FBY
        cmp     #186
        bne     gb_side
        jsr     gfx_dirty_edges
        jsr     gfx_resume_da
        rts

; gfx_fill_rows: fill PL_I full-width (288 px) rows
; starting at row PL_FBY with PL_COLOR; PL_FBY advances.
; Rows are written in bank-safe segments.
gfx_fill_rows:
gfr_loop:
        lda     #$00
        sta     PL_FBX
        sta     PL_FBX+1
        lda     #<288
        sta     PL_GFR_C
        lda     #>288
        sta     PL_GFR_C+1
gfr_seg:
        jsr     gfx_xy_ptr      ; (PL_FBX, PL_FBY) -> zp_ptr
        jsr     seg_len         ; PL_K2 = segment length
        ldy     #$00
        lda     PL_COLOR
gfr_w:
        sta     (zp_ptr),y
        iny
        cpy     PL_K2
        bne     gfr_w
        jsr     seg_advance     ; PL_FBX += K2, PL_CNT -= K2
        lda     PL_GFR_C
        ora     PL_GFR_C+1
        bne     gfr_seg
        inc     PL_FBY
        jsr     drain_burst     ; keep the FIFO drained per row
        dec     PL_GFR_I
        bne     gfr_loop
        rts

; --- Tile Block (normal / XOR) ------------------------------
gp_tile:
        lda     #$00
        sta     PL_K            ; 0 = normal
        bra     gt_common
gp_tile_xor:
        lda     #$01
        sta     PL_K            ; 1 = XOR
gt_common:
        lda     PL_PKT+6        ; data[2] = tile row 0..15
        and     #$1F
        cmp     #16
        bcc     gt_ok1
        rts
gt_ok1:
        sta     PL_TY
        lda     PL_PKT+7        ; data[3] = tile col 0..47
        and     #$3F
        cmp     #48
        bcc     gt_ok2
        rts
gt_ok2:
        sta     PL_TX
        lda     #$00
        sta     PL_I            ; r = 0..11
gt_row:
        ; y = PL_TY*12 + r
        lda     PL_TY
        asl     a
        asl     a
        sta     PL_J            ; *4
        asl     a               ; *8
        clc
        adc     PL_J            ; *12
        adc     PL_I
        sta     PL_FBY
        ; x0 = PL_TX*6 = PL_TX*4 + PL_TX*2
        lda     PL_TX
        asl     a
        sta     PL_FBX          ; *2
        lda     #$00
        sta     PL_FBX+1
        asl     PL_FBX
        rol     PL_FBX+1        ; *4
        lda     PL_TX
        asl     a
        clc
        adc     PL_FBX
        sta     PL_FBX
        bcc     gt_ptr
        inc     PL_FBX+1
gt_ptr:
        jsr     gfx_xy_ptr      ; zp_ptr -> (x0, y), MPR2 set
        ; fast span iff the 6 bytes stay in this bank:
        ; window offset = zp_ptr - $4000 <= $1FF9
        lda     zp_ptr+1
        cmp     #$5F
        bcc     gt_fast
        bne     gt_slow
        lda     zp_ptr
        cmp     #$FA
        bcs     gt_slow
gt_fast:
        ldx     PL_I
        lda     PL_PKT+8,x      ; bitmap byte for row r
        and     #$3F
        sta     PL_J
        asl     PL_J            ; discard bits 7,6: pixel 0
        asl     PL_J            ; uses bit 5 first
        ldy     #$00
gt_pix:
        asl     PL_J
        bcs     gt_p1
        lda     PL_PKT+4        ; colour 0
        bra     gt_pw
gt_p1:
        lda     PL_PKT+5        ; colour 1
gt_pw:
        and     #$0F
        sta     PL_COLOR
        lda     PL_K
        beq     gt_write
        lda     (zp_ptr),y
        eor     PL_COLOR
        sta     PL_COLOR
gt_write:
        lda     PL_COLOR
        sta     (zp_ptr),y
        iny
        cpy     #6
        bne     gt_pix
        jmp     gt_next
gt_slow:                        ; per-pixel fallback
        ldx     PL_I
        lda     PL_PKT+8,x
        and     #$3F
        sta     PL_J
        asl     PL_J
        asl     PL_J
        lda     #$00
        sta     PL_K2           ; c = 0..5
gt_spix:
        ; recompute the pixel pointer (PL_FBX + c, PL_FBY)
        lda     PL_FBX
        clc
        adc     PL_K2
        sta     PL_DIV
        lda     PL_FBX+1
        adc     #$00
        sta     PL_DIV+1
        lda     PL_DIV
        sta     PL_FBX_S
        lda     PL_DIV+1
        sta     PL_FBX_S+1
        ; push current PL_FBX, use the pixel x
        lda     PL_FBX
        pha
        lda     PL_FBX+1
        pha
        lda     PL_FBX_S
        sta     PL_FBX
        lda     PL_FBX_S+1
        sta     PL_FBX+1
        jsr     gfx_xy_ptr
        pla
        sta     PL_FBX+1
        pla
        sta     PL_FBX
        asl     PL_J
        bcs     gt_sp1
        lda     PL_PKT+4
        bra     gt_spw
gt_sp1:
        lda     PL_PKT+5
gt_spw:
        and     #$0F
        sta     PL_COLOR
        lda     PL_K
        beq     gt_swrite
        ldy     #$00
        lda     (zp_ptr),y
        eor     PL_COLOR
        sta     PL_COLOR
gt_swrite:
        ldy     #$00
        lda     PL_COLOR
        sta     (zp_ptr),y
        inc     PL_K2
        lda     PL_K2
        cmp     #6
        bne     gt_spix
gt_next:
        inc     PL_I
        lda     PL_I
        cmp     #12
        beq     gt_rows_done
        jmp     gt_row
gt_rows_done:
        jsr     gfx_dirty_tileblock
gp_rts2:
        rts

PL_K2           = $2787         ; (was $277A: inside
        ; PL_PX's 8-byte staging range -- the pixel store
        ; overwrote the loop counter, hanging the upload)
PL_FBX_S        = $277D         ; 2 bytes

; --- Scroll (preset 20 / copy 24) ---------------------------
; Model: the packet's offset fields give the image's new
; sub-tile offset; the framebuffer is shifted by the
; signed delta against the stored offset (mod 6 / mod 12),
; which reproduces the usual one-pixel-per-packet creep.
; Preset fills the exposed band with the colour; copy
; wraps the image.
gp_scroll_pre:
        lda     #$00
        sta     PL_GK            ; 0 = preset
        bra     gs_common
gp_scroll_cpy:
        lda     #$01
        sta     PL_GK            ; 1 = copy
gs_common:
        lda     #$00
        sta     PL_GDX          ; dx
        sta     PL_GDY         ; dy
        ; horizontal: hcmd = (data[1] >> 4) & 3
        lda     PL_PKT+5
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        and     #$03
        beq     gs_vert
        lda     PL_PKT+6        ; data[2]: hoff = bits 0-2
        and     #$07
        cmp     #6
        bcs     gs_vert         ; invalid offset: ignore H
        sta     PL_J            ; new hoff
        sec
        sbc     PL_GOFFX
        sta     PL_GDX          ; delta -5..5
        cmp     #4
        bcc     gs_dxok
        cmp     #$80
        bcs     gs_dxn
        sec
        sbc     #6
        sta     PL_GDX
        bra     gs_dxok
gs_dxn:
        clc
        adc     #6
        sta     PL_GDX
gs_dxok:
        lda     PL_J
        sta     PL_GOFFX
gs_vert:
        lda     PL_PKT+5        ; vcmd = data[1] & 3
        and     #$03
        beq     gs_apply
        lda     PL_PKT+6
        lsr     a
        lsr     a
        lsr     a
        and     #$1F            ; voff = bits 3-7
        cmp     #12
        bcs     gs_apply
        sta     PL_J            ; new voff
        sec
        sbc     PL_GOFFY
        sta     PL_GDY         ; delta -11..11
        cmp     #6
        bcc     gs_dyok
        cmp     #$80
        bcs     gs_dyn
        sec
        sbc     #12
        sta     PL_GDY
        bra     gs_dyok
gs_dyn:
        clc
        adc     #12
        sta     PL_GDY
gs_dyok:
        lda     PL_J
        sta     PL_GOFFY
gs_apply:
        lda     PL_GDX
        ora     PL_GDY
        beq     gs_rts
        lda     PL_PKT+4
        and     #$0F
        sta     PL_COLOR
        ; Pause CD-DA while the scroll runs.  A full
        ; framebuffer scroll takes far longer than the
        ; ~8 frames of stream the 16-byte hardware FIFO
        ; plus the 1024-byte raw queue can absorb, so an
        ; unpaused scroll drops stream bytes wholesale
        ; and the packets that follow it are lost (their
        ; symbols fall in the dropped span).  Pausing
        ; halts production at the source; the resume
        ; continues at the paused position, so the stream
        ; resumes exactly where it stopped.
        lda     #$00
        sta     PL_SCPAUSED
        lda     PL_STATUS
        bne     gs_nopause      ; not playing: no production
        lda     PL_PAUSED
        bne     gs_nopause      ; user pause: already halted
        jsr     BIOS_PAUSE
        bcc     gs_nopause      ; pause failed: proceed live
        lda     #$01
        sta     PL_SCPAUSED
gs_nopause:
        lda     PL_GDY
        beq     gs_h
        jsr     gfx_scroll_v
gs_h:
        lda     PL_GDX
        beq     gs_done
        jsr     gfx_scroll_h
gs_done:
        lda     PL_SCPAUSED
        beq     gs_dirty
        lda     #$C0            ; resume-from-pause argument
        sta     ARG_BH          ; pattern (same as
        lda     #$C3            ; pl_pause_toggle's resume)
        sta     ARG_DH
        lda     #$00
        sta     ARG_AL
        sta     ARG_CL
        sta     ARG_CH
        sta     ARG_DL
        jsr     BIOS_PLAY
gs_dirty:
        jsr     gfx_dirty_all
gs_rts:
        rts

; Row transfer through the bank $68 buffer at $6000
; (MPR3 window). gfx_row_read copies framebuffer row
; PL_FBY into the buffer; gfx_row_write copies it back.
; Both are bank-safe (segmented at <= 255 bytes). The
; buffer pointer rides in zp_dataptr (BIOS data-pointer
; scratch; no BIOS call is in flight during a transfer).
gfx_row_read:
        lda     #$00
        sta     PL_BBASE
        sta     PL_BBASE+1
grr_body:                       ; read row PL_FBY into the
                                ; buffer at PL_BBASE
        lda     #$68
        tam     #$08            ; MPR3 = buffer bank
        lda     #$00
        sta     PL_FBX
        sta     PL_FBX+1
        lda     #<288
        sta     PL_GFR_C
        lda     #>288
        sta     PL_GFR_C+1
grr_loop:
        jsr     gfx_xy_ptr      ; zp_ptr -> fb (PL_FBX, PL_FBY)
        jsr     seg_setup       ; zp_dataptr = $6000 + PL_FBX
        jsr     seg_len         ; PL_K2 = segment length
        ldy     #$00
grr_cp:
        lda     (zp_ptr),y
        sta     (zp_dataptr),y
        iny
        cpy     PL_K2
        bne     grr_cp
        jsr     seg_advance
        lda     PL_GFR_C
        ora     PL_GFR_C+1
        bne     grr_loop
        rts

gfx_row_write:
        lda     #$00
        sta     PL_BBASE
        sta     PL_BBASE+1
grw_body:                       ; write row PL_FBY from the
                                ; buffer at PL_BBASE
        lda     #$68
        tam     #$08            ; MPR3 = buffer bank
        lda     #$00
        sta     PL_FBX
        sta     PL_FBX+1
        lda     #<288
        sta     PL_GFR_C
        lda     #>288
        sta     PL_GFR_C+1
grw_loop:
        jsr     gfx_xy_ptr      ; zp_ptr -> fb (PL_FBX, PL_FBY)
        jsr     seg_setup
        jsr     seg_len
        ldy     #$00
grw_cp:
        lda     (zp_dataptr),y
        sta     (zp_ptr),y
        iny
        cpy     PL_K2
        bne     grw_cp
        jsr     seg_advance
        lda     PL_GFR_C
        ora     PL_GFR_C+1
        bne     grw_loop
        rts

seg_setup:                      ; zp_dataptr = $6000 +
                                ; PL_BBASE + PL_FBX
        lda     PL_FBX
        clc
        adc     PL_BBASE
        sta     zp_dataptr
        lda     PL_FBX+1
        adc     PL_BBASE+1
        ora     #$60
        sta     zp_dataptr+1
        rts

; seg_len: PL_K2 = min(255, bytes to bank end, PL_CNT).
seg_len:
        sec
        lda     #$00
        sbc     zp_ptr          ; $6000 - zp_ptr (16-bit)
        sta     PL_J
        lda     #$60
        sbc     zp_ptr+1
        sta     PL_K            ; remaining (16-bit) K:J
        ; candidate = remaining if < PL_GFR_C else PL_GFR_C
        lda     PL_K
        cmp     PL_GFR_C+1
        bcc     sl_rem
        bne     sl_cnt
        lda     PL_J
        cmp     PL_GFR_C
        bcc     sl_rem
sl_cnt:
        lda     PL_GFR_C
        sta     PL_J
        lda     PL_GFR_C+1
        sta     PL_K
sl_rem:
        lda     PL_K
        bne     sl_cap          ; > 255 -> cap
        lda     PL_J
        cmp     #255
        bcc     sl_set
sl_cap:
        lda     #255
        sta     PL_K2
        rts
sl_set:
        lda     PL_J
        sta     PL_K2
        rts

seg_advance:                    ; PL_FBX += PL_K2; PL_GFR_C -= PL_K2
        lda     PL_FBX
        clc
        adc     PL_K2
        sta     PL_FBX
        bcc     sa_1
        inc     PL_FBX+1
sa_1:
        sec
        lda     PL_GFR_C
        sbc     PL_K2
        sta     PL_GFR_C
        lda     PL_GFR_C+1
        sbc     #$00
        sta     PL_GFR_C+1
        rts

; gfx_scroll_h: shift every row horizontally by PL_GDX
; (signed, -5..5). Source row comes from the buffer.
gfx_scroll_h:
        lda     #$00
        sta     PL_FBY
gsh_loop:
        jsr     gfx_row_read    ; row -> buffer
        ; write back: for dest x in 0..287 (two spans)
        lda     #$00
        sta     PL_FBX
        sta     PL_FBX+1
        lda     #<288
        sta     PL_GFR_C
        lda     #>288
        sta     PL_GFR_C+1
gsh_seg:
        jsr     gfx_xy_ptr      ; dest (PL_FBX, PL_FBY)
        jsr     seg_len
        ldy     #$00
gsh_w:
        ; source x = PL_FBX + y - dx -> PL_TMPX (signed)
        tya
        clc
        adc     PL_FBX
        sta     PL_TMPX
        lda     PL_FBX+1
        adc     #$00
        sta     PL_TMPX+1
        jsr     gsh_srcx        ; A = source byte
        sta     (zp_ptr),y
        iny
        cpy     PL_K2
        bne     gsh_w
        jsr     seg_advance
        lda     PL_GFR_C
        ora     PL_GFR_C+1
        bne     gsh_seg
        inc     PL_FBY
        jsr     drain_burst     ; keep the FIFO drained per row
        lda     PL_FBY
        cmp     #GFX_H
        bne     gsh_loop
        rts

PL_TMPX         = $2781         ; 2 bytes

; gsh_srcx: A = buffer byte for source x = PL_TMPX - dx
; (dx = PL_GDX, signed). Out of range: wrap (PL_K = 1)
; or PL_COLOR (PL_K = 0).
gsh_srcx:
        lda     PL_GDX
        bpl     gsh_pos
        ; dx < 0: src = x + |dx|
        lda     #$00
        sec
        sbc     PL_GDX
        sta     PL_J            ; |dx|
        lda     PL_TMPX
        clc
        adc     PL_J
        sta     PL_TMPX
        bcc     gsh_range
        inc     PL_TMPX+1
        bra     gsh_range
gsh_pos:
        lda     PL_TMPX
        sec
        sbc     PL_GDX
        sta     PL_TMPX
        lda     PL_TMPX+1
        sbc     #$00
        sta     PL_TMPX+1
gsh_range:
        lda     PL_TMPX+1
        bmi     gsh_out         ; negative
        bne     gsh_big         ; >= 256: ok iff < 288
        lda     PL_TMPX
        bra     gsh_fetch
gsh_big:
        lda     PL_TMPX+1
        cmp     #$01
        bne     gsh_out
        lda     PL_TMPX
        cmp     #32
        bcs     gsh_out
gsh_fetch:
        lda     PL_TMPX+1
        beq     gsh_f1
        ldx     PL_TMPX
        lda     $6100,x
        rts
gsh_f1:
        ldx     PL_TMPX
        lda     $6000,x
        rts
gsh_out:
        lda     PL_GK
        beq     gsh_color
        ; wrap into 0..287 (value is within one tile of
        ; the range, so one add/subtract of 288 suffices
        ; after the range check above: negatives are
        ; >= -5, positives <= 292)
        lda     PL_TMPX+1
        bmi     gsh_wadd
        sec
        lda     PL_TMPX
        sbc     #<288
        sta     PL_TMPX
        lda     PL_TMPX+1
        sbc     #>288
        sta     PL_TMPX+1
        bra     gsh_range
gsh_wadd:
        lda     PL_TMPX
        clc
        adc     #<288
        sta     PL_TMPX
        lda     PL_TMPX+1
        adc     #>288
        sta     PL_TMPX+1
        bra     gsh_range
gsh_color:
        lda     PL_COLOR
        rts

; gsv_stagebase: A = row count (1..11) ->
; PL_BBASE = 8192 - count*288 (staging area at the top
; of the 8 KB row buffer, clear of the offset-0 row the
; copy loops use).
gsv_stagebase:
        sta     PL_J
        lda     #$00
        sta     PL_BBASE
        lda     #$20
        sta     PL_BBASE+1      ; 8192
        lda     PL_BBASE+1
        sec
        sbc     PL_J            ; count*256
        sta     PL_BBASE+1
        lda     PL_J
        asl     a
        asl     a
        asl     a
        asl     a
        asl     a               ; count*32 (<= 352)
        sta     PL_TMPX
        lda     #$00
        rol     a
        sta     PL_TMPX+1
        sec
        lda     PL_BBASE
        sbc     PL_TMPX
        sta     PL_BBASE
        lda     PL_BBASE+1
        sbc     PL_TMPX+1
        sta     PL_BBASE+1
        rts

gfx_scroll_v:
        lda     PL_GDY
        bpl     gsv_dn
        jmp     gsv_up
gsv_dn:
        ; dy > 0 (content moves down).  In copy mode the
        ; band's source rows (192-dy..191) are overwritten
        ; by the descending copy loop, so stage them in
        ; the row buffer BEFORE the loop and write the
        ; band from the staging afterwards.
        lda     PL_GK
        beq     gsv_dn_loop
        lda     #192
        sec
        sbc     PL_GDY
        sta     PL_FBY          ; first band source row
        lda     PL_GDY
        jsr     gsv_stagebase   ; staging sits at the top
                                ; of the row buffer: the copy
                                ; loop's own row reads (base 0)
                                ; would otherwise overwrite
                                ; the staged rows
        lda     #$00
        sta     PL_E1           ; staged row counter
gsv_stg_d:
        jsr     grr_body
        inc     PL_FBY
        lda     PL_BBASE
        clc
        adc     #<288
        sta     PL_BBASE
        lda     PL_BBASE+1
        adc     #>288
        sta     PL_BBASE+1
        inc     PL_E1
        lda     PL_E1
        cmp     PL_GDY
        bne     gsv_stg_d
        lda     #$00
        sta     PL_BBASE
        sta     PL_BBASE+1
gsv_dn_loop:
        lda     #191
        sta     PL_FBY
gsv_dloop:
        lda     PL_FBY
        sec
        sbc     PL_GDY
        sta     PL_J            ; source row
        lda     PL_FBY
        pha
        lda     PL_J
        sta     PL_FBY
        jsr     gfx_row_read
        pla
        sta     PL_FBY
        jsr     gfx_row_write
        lda     PL_FBY
        and     #$07
        bne     gsv_dn1
        jsr     drain_burst     ; keep the FIFO drained
gsv_dn1:
        dec     PL_FBY
        lda     PL_FBY
        cmp     PL_GDY
        bcs     gsv_dloop
        ; top band: rows 0 .. dy-1
        lda     PL_GK
        beq     gsv_dfill
        lda     #$00
        sta     PL_FBY
        sta     PL_E1
        lda     PL_GDY
        jsr     gsv_stagebase
gsv_bw_d:
        jsr     grw_body
        inc     PL_FBY
        lda     PL_BBASE
        clc
        adc     #<288
        sta     PL_BBASE
        lda     PL_BBASE+1
        adc     #>288
        sta     PL_BBASE+1
        inc     PL_E1
        lda     PL_E1
        cmp     PL_GDY
        bne     gsv_bw_d
        lda     #$00
        sta     PL_BBASE
        sta     PL_BBASE+1
        rts
gsv_dfill:
        lda     #$00
        sta     PL_FBY
gsv_dfill_l:
        jsr     gsv_fillrow
        inc     PL_FBY
        lda     PL_FBY
        cmp     PL_GDY
        bne     gsv_dfill_l
        rts
gsv_up:
        ; dy < 0: PL_I2 = -PL_GDY; iterate y = 0 .. 191-dy
        lda     #$00
        sec
        sbc     PL_GDY
        sta     PL_I2           ; |dy|
        ; copy mode: stage the band sources (rows
        ; 0..|dy|-1) before the ascending loop overwrites
        ; them (mirror of the dy > 0 staging).
        lda     PL_GK
        beq     gsv_up_loop
        lda     #$00
        sta     PL_FBY
        sta     PL_E1
        lda     PL_I2
        jsr     gsv_stagebase
gsv_stg_u:
        jsr     grr_body
        inc     PL_FBY
        lda     PL_BBASE
        clc
        adc     #<288
        sta     PL_BBASE
        lda     PL_BBASE+1
        adc     #>288
        sta     PL_BBASE+1
        inc     PL_E1
        lda     PL_E1
        cmp     PL_I2
        bne     gsv_stg_u
        lda     #$00
        sta     PL_BBASE
        sta     PL_BBASE+1
gsv_up_loop:
        lda     #$00
        sta     PL_FBY
gsv_uloop:
        lda     PL_FBY
        clc
        adc     PL_I2
        sta     PL_J            ; source row = y + |dy|
        lda     PL_FBY
        pha
        lda     PL_J
        sta     PL_FBY
        jsr     gfx_row_read
        pla
        sta     PL_FBY
        jsr     gfx_row_write
        lda     PL_FBY
        and     #$07
        bne     gsv_un1
        jsr     drain_burst     ; keep the FIFO drained
gsv_un1:
        inc     PL_FBY
        lda     #192
        sec
        sbc     PL_I2
        cmp     PL_FBY
        bne     gsv_uloop
        ; bottom band: rows 192-|dy| .. 191
        lda     PL_GK
        beq     gsv_ufill
        lda     #192
        sec
        sbc     PL_I2
        sta     PL_FBY
        lda     #$00
        sta     PL_E1
        lda     PL_I2
        jsr     gsv_stagebase
gsv_bw_u:
        jsr     grw_body
        inc     PL_FBY
        lda     PL_BBASE
        clc
        adc     #<288
        sta     PL_BBASE
        lda     PL_BBASE+1
        adc     #>288
        sta     PL_BBASE+1
        inc     PL_E1
        lda     PL_E1
        cmp     PL_I2
        bne     gsv_bw_u
        lda     #$00
        sta     PL_BBASE
        sta     PL_BBASE+1
        rts
gsv_ufill:
        jsr     gsv_fillrow
        inc     PL_FBY
        lda     PL_FBY
        cmp     #192
        bne     gsv_ufill
        rts

; gsv_fillrow: fill one band row (PL_FBY) with PL_COLOR
; via gfx_fill_rows (which advances PL_FBY -- saved and
; restored around the call).
gsv_fillrow:
        lda     PL_COLOR
        sta     PL_J
        lda     PL_FBY
        sta     PL_I2
        lda     PL_FBY
        pha
        lda     #1
        sta     PL_GFR_I
        jsr     gfx_fill_rows
        pla
        sta     PL_FBY
        rts

PL_I2           = $2783

; --- Load Colour Table (low 30 / high 31) -------------------
gp_clut_lo:
        lda     #$00
        sta     PL_I
        bra     gcl_common
gp_clut_hi:
        lda     #$08
        sta     PL_I
gcl_common:
        lda     #$00
        sta     PL_J            ; entry counter 0..7
gcl_loop:
        lda     PL_J
        asl     a
        tax
        lda     PL_PKT+4,x      ; b0
        and     #$3F
        sta     PL_DIV
        lda     PL_PKT+5,x      ; b1
        and     #$3F
        sta     PL_DIV+1
        ; R = (b0 >> 2) & 0F; G = ((b0 & 3) << 2) |
        ; ((b1 >> 4) & 3); B = b1 & 0F
        lda     PL_DIV
        lsr     a
        lsr     a
        and     #$0F
        sta     PL_DIV2         ; R
        lda     PL_DIV
        and     #$03
        asl     a
        asl     a
        sta     PL_DIV2+1
        lda     PL_DIV+1
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        and     #$03
        ora     PL_DIV2+1
        sta     PL_DIV2+1       ; G
        lda     PL_DIV+1
        and     #$0F
        sta     PL_DIV2+2       ; B
        ; PCE word = ((G>>1) << 6) | ((R>>1) << 3) | (B>>1)
        lda     PL_DIV2+1
        lsr     a               ; G>>1 (0..7)
        sta     PL_K
        asl     a
        asl     a
        asl     a
        asl     a
        asl     a
        asl     a               ; (G>>1) << 6, low byte
        sta     PL_TY
        lda     PL_DIV2         ; R
        lsr     a
        asl     a
        asl     a
        asl     a               ; (R>>1) << 3
        ora     PL_TY
        sta     PL_TY
        lda     PL_DIV2+2       ; B
        lsr     a
        ora     PL_TY
        sta     PL_TY           ; PCE word low byte
        lda     PL_K            ; high byte = (G>>1) >> 2
        lsr     a
        lsr     a
        sta     PL_TX           ; PCE word high byte (0/1)
        ; store PL_CLUT[(PL_I + PL_J) * 2]
        lda     PL_I
        clc
        adc     PL_J
        asl     a
        tax
        lda     PL_TY
        sta     PL_CLUT,x
        lda     PL_TX
        sta     PL_CLUT+1,x
        ; write VCE entry PL_I + PL_J
        lda     PL_I
        clc
        adc     PL_J
        sta     VCE_PAL_LO
        lda     #$00
        sta     VCE_PAL_HI
        lda     PL_TY
        sta     VCE_PAL_DLO
        lda     PL_TX
        sta     VCE_PAL_DHI
        inc     PL_J
        lda     PL_J
        cmp     #8
        beq     gcl_done
        jmp     gcl_loop
gcl_done:
        rts

; ===================================================================
; Framebuffer helpers.
; ===================================================================

; gfx_xy_off: PL_DIV (16-bit) = PL_FBY*288 + PL_FBX.
gfx_xy_off:
        lda     PL_FBY
        sta     PL_DIV+1        ; y*256: high byte = y
        lda     #$00
        sta     PL_DIV
        lda     PL_FBY
        asl     a
        asl     a
        asl     a
        asl     a
        asl     a               ; y*32, low byte
        clc
        adc     PL_DIV
        sta     PL_DIV
        lda     PL_FBY
        lsr     a
        lsr     a
        lsr     a               ; (y*32) >> 8 = y >> 3
        clc                     ; the lsrs leave bit 2 of y
                                ; in the carry; the low add
                                ; above was +0 and owes no
                                ; carry, so it must not leak
                                ; into the high byte (it put
                                ; every pixel with (y & 4)
                                ; set 256 bytes too high --
                                ; the item 3.1 draw scramble)
        adc     PL_DIV+1
        sta     PL_DIV+1
        lda     PL_DIV
        clc
        adc     PL_FBX
        sta     PL_DIV
        lda     PL_DIV+1
        adc     PL_FBX+1
        sta     PL_DIV+1
        rts

; gfx_xy_ptr: zp_ptr -> pixel (PL_FBX, PL_FBY); sets MPR2.
gfx_xy_ptr:
        jsr     gfx_xy_off
        lda     PL_DIV+1
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        lsr     a               ; offset >> 13
        clc
        adc     #GFX_FB_BANK
        tam     #$04            ; MPR2 = framebuffer bank
        lda     PL_DIV
        sta     zp_ptr
        lda     PL_DIV+1
        and     #$1F
        ora     #$40
        sta     zp_ptr+1
        rts

; gfx_row_ptr: A = y -> zp_ptr at (0, y); sets MPR2.
gfx_row_ptr:
        sta     PL_FBY
        lda     #$00
        sta     PL_FBX
        sta     PL_FBX+1
        jsr     gfx_xy_ptr
        rts

; gfx_fb_fill: fill the whole framebuffer with PL_COLOR.
; ; drain_burst: poll CD_SUBRQ until the FIFO is empty
; (max 48 attempts), feeding the decoder.  Called from
; inside long operations so they cannot starve the
; stream.
;
; Re-entrancy: feeding a byte can emit and execute a
; nested CD+G packet, whose handlers use the same
; scratch as the interrupted one, so the handler
; scratch ($2764-$2788), PL_PKT, the upload temps
; ($2791-$2793) and zp_ptr / MPR2 are saved and
; restored around the burst.  The DECODER state is
; deliberately NOT saved: PL_PHASE / PL_RINGW /
; PL_GRPCNT / PL_RINGW_SYNC / PL_HCNT must keep every
; symbol the burst feeds -- restoring them afterwards
; would rewind the ring and corrupt the stream (the
; bug that kept the CD+G picture from ever forming:
; groups were re-emitted from rewound ring contents
; and the picture dissolved into noise).
drain_burst:
        lda     PL_HDEPTH       ; inside a packet handler a
        bne     db_raw          ; burst would feed MORE packets
                                ; recursively -- the scratch
                                ; save/restore patchwork could not
                                ; keep the outer handler's state
                                ; intact (this corrupted PL_GFX /
                                ; MB_STATE in testing).  Instead
                                ; the raw path below only moves
                                ; bytes from the 16-byte FIFO into
                                ; the 1 KB raw queue (no feeding,
                                ; no packet execution); the queue
                                ; is fed in order once the handler
                                ; returns.  (Before this, handler-
                                ; time bytes dropped out of the
                                ; FIFO and the resync ate the
                                ; first packets after every long
                                ; fill -- item 3.1 measurement.)
        lda     PL_DBBUSY       ; nested bursts return at
        bne     db_rts          ; once: the 256-byte stack
        inc     PL_DBBUSY       ; page cannot hold two
        ldx     #$00            ; burst frames (67 B each)
db_save_a:
        lda     PL_E1,x
        pha
        inx
        cpx     #$25            ; $2764..$2788
        bne     db_save_a
        ldx     #$00
db_save_p:
        lda     PL_PKT,x
        pha
        inx
        cpx     #24
        bne     db_save_p
        ldx     #$00
db_save_b:
        lda     PL_GDE_T,x
        pha
        inx
        cpx     #$03            ; $2791..$2793
        bne     db_save_b
        lda     zp_ptr
        pha
        lda     zp_ptr+1
        pha
        tma     #$04
        pha
        lda     #48
        sta     PL_DSLICE
db_loop:
        jsr     gfx_poll_feed
        bcs     db_out
        dec     PL_DSLICE
        bne     db_loop
db_out:
        pla
        tam     #$04
        pla
        sta     zp_ptr+1
        pla
        sta     zp_ptr
        ldx     #$03
db_rest_b:
        pla
        dex
        sta     PL_GDE_T,x
        bne     db_rest_b
        ldx     #24
db_rest_p:
        pla
        dex
        sta     PL_PKT,x
        bne     db_rest_p
        ldx     #$25
db_rest_a:
        pla
        dex
        sta     PL_E1,x
        bne     db_rest_a
        lda     #$00
        sta     PL_DBBUSY
db_rts:
        rts

; db_raw: handler-time drain.  Poll CD_SUBRQ (up to 48
; attempts) and push every received byte into the raw
; queue; nothing is fed or executed here, so no handler
; state can be disturbed.  zp_ptr and the fb window
; mapping (MPR2) are saved/restored around the burst,
; mirroring the full drain's idiom.
db_raw:
        lda     zp_ptr
        pha
        lda     zp_ptr+1
        pha
        tma     #$04
        pha
        lda     #48
        sta     PL_DSLICE
db_raw_loop:
        jsr     BIOS_SUBRQ
        bcs     db_raw_out
        jsr     q_push
        dec     PL_DSLICE
        bne     db_raw_loop
db_raw_out:
        pla
        tam     #$04
        pla
        sta     zp_ptr+1
        pla
        sta     zp_ptr
        rts

; q_push: A = byte -> raw queue (dropped when the queue
; already holds 1024 bytes).  Clobbers zp_ptr.
q_push:
        sta     PL_QBYTE
        lda     PL_QTAIL
        sec
        sbc     PL_QHEAD
        lda     PL_QTAIL+1
        sbc     PL_QHEAD+1
        cmp     #$04            ; occupancy >= 1024?
        bcs     qp_rts
        lda     PL_QTAIL
        sta     zp_ptr
        lda     PL_QTAIL+1
        and     #$03
        ora     #$29            ; PL_RAWQ = $2900
        sta     zp_ptr+1
        lda     PL_QBYTE
        ldy     #$00
        sta     (zp_ptr),y
        inc     PL_QTAIL
        bne     qp_rts
        inc     PL_QTAIL+1
qp_rts:
        rts

; q_pop: -> A = byte, carry clear; carry set when the
; queue is empty.  Clobbers zp_ptr.
q_pop:
        lda     PL_QHEAD
        cmp     PL_QTAIL
        bne     qo_go
        lda     PL_QHEAD+1
        cmp     PL_QTAIL+1
        beq     qo_empty
qo_go:
        lda     PL_QHEAD
        sta     zp_ptr
        lda     PL_QHEAD+1
        and     #$03
        ora     #$29            ; PL_RAWQ = $2900
        sta     zp_ptr+1
        ldy     #$00
        lda     (zp_ptr),y
        inc     PL_QHEAD
        bne     qo_ok
        inc     PL_QHEAD+1
qo_ok:
        clc
        rts
qo_empty:
        sec
        rts

; gfx_poll_feed: feed one stream byte.  Every call
; first pumps the live FIFO into the queue tail (up to
; 16 bytes), then feeds the queue head: queued bytes
; are always older than FIFO bytes, so the stream
; order is preserved, and a handler-time backlog can
; never starve the live FIFO while it is worked off
; (the first queue version fed the backlog first and
; lost live bytes during the catch-up).  Carry set
; when no byte was available from either source.
gfx_poll_feed:
        lda     #16
        sta     PL_QPUMP
gpf_pump:
        jsr     BIOS_SUBRQ
        bcs     gpf_take
        jsr     q_push
        dec     PL_QPUMP
        bne     gpf_pump
gpf_take:
        jsr     q_pop
        bcs     gpf_none
        jsr     gfx_feed
        clc
        rts
gpf_none:
        sec
        rts

; gfx_fb_fill: fill the whole framebuffer with PL_COLOR,
; sliced into 1 KB TII runs with a drain burst between them.
gfx_fb_fill:
        lda     #GFX_FB_BANK
        sta     PL_GFF_B
gff_bank:
        lda     PL_GFF_B
        tam     #$04
        lda     PL_COLOR
        sta     $4000
        tii     $4000, $4001, 1023
        jsr     drain_burst
        lda     PL_GFF_B
        tam     #$04
        lda     PL_COLOR
        sta     $4400
        tii     $4400, $4401, 1023
        jsr     drain_burst
        lda     PL_GFF_B
        tam     #$04
        lda     PL_COLOR
        sta     $4800
        tii     $4800, $4801, 1023
        jsr     drain_burst
        lda     PL_GFF_B
        tam     #$04
        lda     PL_COLOR
        sta     $4C00
        tii     $4C00, $4C01, 1023
        jsr     drain_burst
        lda     PL_GFF_B
        tam     #$04
        lda     PL_COLOR
        sta     $5000
        tii     $5000, $5001, 1023
        jsr     drain_burst
        lda     PL_GFF_B
        tam     #$04
        lda     PL_COLOR
        sta     $5400
        tii     $5400, $5401, 1023
        jsr     drain_burst
        lda     PL_GFF_B
        tam     #$04
        lda     PL_COLOR
        sta     $5800
        tii     $5800, $5801, 1023
        jsr     drain_burst
        lda     PL_GFF_B
        tam     #$04
        lda     PL_COLOR
        sta     $5C00
        tii     $5C00, $5C01, 1023
        jsr     drain_burst
        inc     PL_GFF_B
        lda     PL_GFF_B
        cmp     #GFX_FB_BANK + 7
        beq     gff_done
        jmp     gff_bank
gff_done:
        rts

; gfx_dirty_all: mark all 864 tiles dirty.
gfx_dirty_all:
        ldx     #107
        lda     #$FF
gda_loop:
        sta     PL_DIRTY,x
        dex
        bpl     gda_loop
        rts

; gfx_dirty_edges: border tiles (rows 0 and 23, cols 0
; and 35 of the 36x24 upload grid).
gfx_dirty_edges:
        ; (the loop counter lives in memory: gde_setdiv
        ; clobbers X -- an X counter here looped forever
        ; between tiles 0 and 1 on the first Border
        ; Preset, hanging the whole player)
        lda     #$00
        sta     PL_GDE_X
gde_top:
        lda     PL_GDE_X
        sta     PL_DIV
        lda     #$00
        sta     PL_DIV+1
        jsr     gde_setdiv
        jsr     drain_burst
        inc     PL_GDE_X
        lda     PL_GDE_X
        cmp     #36
        bne     gde_top
        lda     #$00
        sta     PL_GDE_X
gde_bot:
        lda     #<828
        sta     PL_DIV
        lda     #>828
        sta     PL_DIV+1
        lda     PL_GDE_X
        clc
        adc     PL_DIV
        sta     PL_DIV
        bcc     gde_b1
        inc     PL_DIV+1
gde_b1:
        jsr     gde_setdiv
        jsr     drain_burst
        inc     PL_GDE_X
        lda     PL_GDE_X
        cmp     #36
        bne     gde_bot
        lda     #$00
        sta     PL_TY
gde_side:
        lda     PL_TY
        jsr     gde_rowtile     ; PL_DIV = PL_TY*36
        jsr     gde_setdiv
        lda     PL_DIV
        clc
        adc     #35
        sta     PL_DIV
        bcc     gde_s1
        inc     PL_DIV+1
gde_s1:
        jsr     gde_setdiv
        jsr     drain_burst
        inc     PL_TY
        lda     PL_TY
        cmp     #24
        bne     gde_side
        rts

; gde_setdiv: set the dirty bit for tile PL_DIV (16-bit).
; Indices outside the 36x24 grid are dropped: the dirty
; map is 108 bytes, and an out-of-range index would
; write into the player scratch area beyond it.
gde_setdiv:
        lda     PL_DIV+1
        cmp     #>864
        bcc     gde_sd_ok
        bne     gde_sd_rts
        lda     PL_DIV
        cmp     #<864
        bcs     gde_sd_rts
gde_sd_ok:
        lda     PL_DIV+1
        sta     PL_GDE_T
        lda     PL_DIV
        lsr     PL_GDE_T
        ror     a
        lsr     PL_GDE_T
        ror     a
        lsr     PL_GDE_T
        ror     a               ; A = tile >> 3
        tax
        lda     PL_DIV
        and     #$07
        tay
        lda     gde_bits,y
        ora     PL_DIRTY,x
        sta     PL_DIRTY,x
gde_sd_rts:
        rts

; gde_rowtile: PL_DIV = A * 36 (16-bit).
gde_rowtile:
        sta     PL_GDE_T        ; temp (NOT PL_J: the caller
        asl     a               ; gfx_dirty_tileblock keeps
        asl     a               ; its tx walker in PL_J across
        sta     PL_DIV          ; the call -- clobbering it
        lda     #$00            ; made the walk run ~237
        sta     PL_DIV+1        ; steps instead of <=2)
        lda     PL_GDE_T
        asl     a
        asl     a
        asl     a
        asl     a
        asl     a               ; *32, low byte
        clc
        adc     PL_DIV
        sta     PL_DIV
        lda     PL_GDE_T
        lsr     a
        lsr     a
        lsr     a               ; *32 high = A >> 3
        adc     PL_DIV+1
        sta     PL_DIV+1
        rts

gde_bits:
        .byte $01, $02, $04, $08, $10, $20, $40, $80

; gfx_dirty_tileblock: mark the 8x8 upload tiles
; overlapped by the CD+G tile at (PL_TX, PL_TY) dirty.
; The tile is 6x12 px, so it overlaps at most 2 upload
; columns and 3 upload rows.  The ranges are computed
; with 16-bit shifts and clamped to the 36x24 grid --
; an earlier version computed (x0+5)>>3 on the low byte
; only, which wrapped to 0 for x0 >= 251 (columns
; 42-47) and sent the marking walk the long way around
; the byte, starving the stream.
gfx_dirty_tileblock:
        ; x0 = PL_TX*6, y0 = PL_TY*12
        lda     PL_TX
        asl     a
        sta     PL_J
        asl     a
        clc
        adc     PL_J            ; *6
        sta     PL_FBX
        lda     #$00
        sta     PL_FBX+1
        lda     PL_TY
        asl     a
        asl     a
        sta     PL_J            ; *4
        asl     a               ; *8
        clc
        adc     PL_J            ; *12
        sta     PL_FBY
        ; ty range: y0>>3 .. (y0+11)>>3 (y0 <= 191, so
        ; the 8-bit shifts are exact here)
        lsr     a
        lsr     a
        lsr     a
        sta     PL_I            ; first ty
        lda     PL_FBY
        clc
        adc     #11
        lsr     a
        lsr     a
        lsr     a
        cmp     #24
        bcc     gdb_k1
        lda     #23
gdb_k1:
        sta     PL_K            ; last ty (clamped)
        ; tx range: x0>>3 .. (x0+5)>>3, 16-bit (x0+5
        ; reaches 287, past the low byte's range)
        lda     PL_FBX
        sta     PL_DIV2
        lda     PL_FBX+1
        sta     PL_DIV2+1
        lsr     PL_DIV2+1
        ror     PL_DIV2
        lsr     PL_DIV2+1
        ror     PL_DIV2
        lsr     PL_DIV2+1
        ror     PL_DIV2
        lda     PL_DIV2
        sta     PL_J            ; first tx
        lda     PL_FBX
        clc
        adc     #5
        sta     PL_DIV2
        lda     PL_FBX+1
        adc     #$00
        sta     PL_DIV2+1
        lsr     PL_DIV2+1
        ror     PL_DIV2
        lsr     PL_DIV2+1
        ror     PL_DIV2
        lsr     PL_DIV2+1
        ror     PL_DIV2
        lda     PL_DIV2
        cmp     #36
        bcc     gdb_t1
        lda     #35
gdb_t1:
        sta     PL_TX           ; last tx (clamped)
gdb_row:
        lda     PL_I
        jsr     gde_rowtile     ; PL_DIV = ty*36
        lda     PL_DIV
        clc
        adc     PL_J
        sta     PL_DIV
        bcc     gdb_m1
        inc     PL_DIV+1
gdb_m1:
        jsr     gde_setdiv      ; (ty, first tx)
        lda     PL_TX
        cmp     PL_J
        beq     gdb_next
        lda     PL_DIV
        clc
        adc     PL_TX
        sta     PL_DIV
        lda     PL_DIV+1
        adc     #$00
        sta     PL_DIV+1
        lda     PL_DIV
        sec
        sbc     PL_J
        sta     PL_DIV
        lda     PL_DIV+1
        sbc     #$00
        sta     PL_DIV+1        ; PL_DIV = base + last tx
        jsr     gde_setdiv      ; (ty, last tx)
gdb_next:
        inc     PL_I
        lda     PL_I
        cmp     PL_K
        bcc     gdb_row
        beq     gdb_row
        rts

; gfx_upload: convert up to 96 dirty tiles to VRAM,
; scanning from PL_UPIDX (at most one full pass of 864).
gfx_upload:
        lda     #$00
        sta     PL_K            ; uploaded count
        sta     PL_CNT
        sta     PL_CNT+1        ; checked count
gu_loop:
        lda     PL_UPIDX
        sta     PL_DIV
        lda     PL_UPIDX+1
        sta     PL_DIV+1
        jsr     gde_testdiv     ; carry set if dirty
        bcc     gu_adv
        jsr     gde_clearidx
        jsr     gfx_upload_one
        inc     PL_K
        lda     PL_K
        cmp     PL_UPCAP
        beq     gu_done
gu_adv:
        ; PL_UPIDX = (PL_UPIDX + 1) mod 864
        inc     PL_UPIDX
        bne     gu_mod
        inc     PL_UPIDX+1
gu_mod:
        lda     PL_UPIDX+1
        cmp     #>864
        bcc     gu_cnt
        bne     gu_wrap
        lda     PL_UPIDX
        cmp     #<864
        bcc     gu_cnt
gu_wrap:
        lda     #$00
        sta     PL_UPIDX
        sta     PL_UPIDX+1
gu_cnt:
        inc     PL_CNT
        bne     gu_chk2
        inc     PL_CNT+1
gu_chk2:
        lda     PL_CNT+1
        cmp     PL_CHKCAP+1
        bcc     gu_loop
        bne     gu_done
        lda     PL_CNT
        cmp     PL_CHKCAP
        bcc     gu_loop
gu_done:
        rts

; gde_testdiv: carry = dirty bit of tile PL_DIV.
gde_testdiv:
        lda     PL_DIV+1
        sta     PL_GDE_T
        lda     PL_DIV
        lsr     PL_GDE_T
        ror     a
        lsr     PL_GDE_T
        ror     a
        lsr     PL_GDE_T
        ror     a
        tax
        lda     PL_DIV
        and     #$07
        tay
        lda     PL_DIRTY,x
        and     gde_bits,y
        beq     gdt_clean
        sec
        rts
gdt_clean:
        clc
        rts

; gde_clearidx: clear the dirty bit of tile PL_UPIDX.
gde_clearidx:
        lda     PL_UPIDX+1
        sta     PL_J
        lda     PL_UPIDX
        lsr     PL_J
        ror     a
        lsr     PL_J
        ror     a
        lsr     PL_J
        ror     a
        tax
        lda     PL_UPIDX
        and     #$07
        tay
        lda     gde_bits,y
        eor     #$FF
        and     PL_DIRTY,x
        sta     PL_DIRTY,x
        rts

; gfx_upload_one: tile PL_UPIDX (0..863) -> VRAM tile
; GFX_TILE0 + PL_UPIDX (4bpp planar, 16 words).
gfx_upload_one:
        ; tx = idx mod 36, ty = idx div 36
        lda     PL_UPIDX
        sta     PL_DIV
        lda     PL_UPIDX+1
        sta     PL_DIV+1
        lda     #$00
        sta     PL_TY
guo_div:
        lda     PL_DIV+1
        bne     guo_sub
        lda     PL_DIV
        cmp     #36
        bcc     guo_tx
guo_sub:
        sec
        lda     PL_DIV
        sbc     #36
        sta     PL_DIV
        lda     PL_DIV+1
        sbc     #$00
        sta     PL_DIV+1
        inc     PL_TY
        bra     guo_div
guo_tx:
        lda     PL_DIV
        sta     PL_TX
        ; pixel origin: x = PL_TX*8, ybase = PL_TY*8
        lda     PL_TX
        asl     a
        asl     a
        asl     a
        sta     PL_FBX
        lda     #$00
        sta     PL_FBX+1
        lda     PL_TY
        asl     a
        asl     a
        asl     a
        sta     PL_YBASE        ; ybase (row loop adds r)
        lda     #$00
        sta     PL_GUO_R            ; r
guo_row:
        ; One tile upload takes ~14K cycles (the 4-plane
        ; build dominates) -- about 14 subcode bytes of
        ; production, at the edge of the 16-byte FIFO.
        ; Drain between rows so an upload can never
        ; starve the stream (measured: un-drained
        ; uploads dropped 12-36 bytes each, ~1/3 of the
        ; stream, and the CD+G picture never formed).
        ; While paused/stopped there is no live stream
        ; to protect (the drive is off; at most 16 stale
        ; FIFO bytes remain, which the resync absorbs
        ; on resume), and the burst costs more than the
        ; upload itself -- skip it so the paused frame
        ; settles promptly.
        lda     PL_STATUS
        bne     guo_nodrain
        jsr     drain_burst
guo_nodrain:
        lda     PL_YBASE
        clc
        adc     PL_GUO_R
        sta     PL_FBY          ; pixel y for this row
        sta     PL_FBY_S
        ; read 8 pixels: fast span iff window offset
        ; <= $1FF7, else per pixel
        jsr     gfx_xy_ptr      ; (PL_FBX, PL_FBY)
        lda     zp_ptr+1
        cmp     #$5F
        bcc     guo_fast
        bne     guo_slow
        lda     zp_ptr
        cmp     #$F8
        bcs     guo_slow
guo_fast:
        ldy     #$00
guo_px:
        lda     (zp_ptr),y
        sta     PL_PX,y
        iny
        cpy     #8
        bne     guo_px
        bra     guo_planes
guo_slow:
        lda     #$00
        sta     PL_K2           ; pixel counter
guo_spx:
        lda     PL_FBX
        clc
        adc     PL_K2
        sta     PL_DIV
        lda     PL_FBX+1
        adc     #$00
        sta     PL_DIV+1
        lda     PL_FBX
        pha
        lda     PL_FBX+1
        pha
        lda     PL_DIV
        sta     PL_FBX
        lda     PL_DIV+1
        sta     PL_FBX+1
        lda     PL_FBY_S
        sta     PL_FBY
        jsr     gfx_xy_ptr
        pla
        sta     PL_FBX+1
        pla
        sta     PL_FBX
        ldy     #$00
        lda     (zp_ptr),y
        ldx     PL_K2
        sta     PL_PX,x
        inc     PL_K2
        lda     PL_K2
        cmp     #8
        bne     guo_spx
guo_planes:
        ; build 4 plane bytes for this row
        ldx     #$00            ; plane
guo_plane:
        lda     #$00
        sta     PL_ACC          ; byte accumulator (NOT PL_K:
                                ; the caller counts uploads
                                ; in PL_K)
        ldy     #$00            ; pixel
guo_bit:
        lda     PL_PX,y
        sta     PL_J
        txa
        beq     guo_bready
        sta     PL_DIV2         ; shift counter
guo_sh:
        lsr     PL_J
        dec     PL_DIV2
        bne     guo_sh
guo_bready:
        asl     PL_ACC
        lda     PL_J
        and     #$01
        ora     PL_ACC
        sta     PL_ACC
        iny
        cpy     #8
        bne     guo_bit
        ; PL_TILEBUF[plane*8 + r] = byte
        txa
        asl     a
        asl     a
        asl     a
        clc
        adc     PL_GUO_R
        tay
        lda     PL_ACC
        sta     PL_TILEBUF,y
        inx
        cpx     #4
        bne     guo_plane
        inc     PL_GUO_R
        lda     PL_GUO_R
        cmp     #8
        beq     guo_rows_done
        jmp     guo_row
guo_rows_done:
        ; write 16 words at (GFX_TILE0 + PL_UPIDX) * 16
        lda     PL_UPIDX
        sta     PL_DIV
        lda     PL_UPIDX+1
        sta     PL_DIV+1
        asl     PL_DIV
        rol     PL_DIV+1
        asl     PL_DIV
        rol     PL_DIV+1
        asl     PL_DIV
        rol     PL_DIV+1
        asl     PL_DIV
        rol     PL_DIV+1        ; idx * 16
        lda     PL_DIV
        clc
        adc     #<(GFX_TILE0 * 16)
        sta     zp_vdcval
        lda     PL_DIV+1
        adc     #>(GFX_TILE0 * 16)
        sta     zp_vdcval+1
        jsr     vdc_set_mawr
        ldy     #VDC_VWR
        sty     a:VDC_SEL
        ldx     #$00
guo_wr:
        txa
        and     #$07
        tay
        txa
        cmp     #8
        bcs     guo_hi
        lda     PL_TILEBUF,y
        sta     a:VDC_DLO
        lda     PL_TILEBUF+8,y
        sta     a:VDC_DHI
        bra     guo_nx
guo_hi:
        lda     PL_TILEBUF+16,y
        sta     a:VDC_DLO
        lda     PL_TILEBUF+24,y
        sta     a:VDC_DHI
guo_nx:
        inx
        cpx     #16
        bne     guo_wr
        rts

PL_FBY_S        = $2784
PL_YBASE        = $2785
PL_PAUSED       = $2786
PL_SAVEB        = $2788         ; CD+G: stream byte staging
PL_PHASE        = $2789         ; CD+G: decoder byte position
                                ; (0..97; $FE = entry hunt,
                                ; $FF = recovery hunt)
PL_RINGW        = $278A         ; CD+G: symbol ring write idx
PL_UPCAP        = $278C         ; CD+G: upload cap per call
PL_CHKCAP       = $278D         ; CD+G: scan cap per call (2)
PL_TBUD         = $278F         ; CD+G: tick attempt budget (2)
PL_FEDBUD       = $27B1         ; CD+G: fed-byte budget per
                                ; tick/drain call
PL_GDE_T        = $2791         ; CD+G: dirty-bit shift temp
PL_DSLICE       = $2792         ; CD+G: drain_burst counter
PL_ACC          = $2793         ; CD+G: upload plane accumulator
PL_RINGW_SYNC   = $2794         ; CD+G: RINGW at the last sync
PL_HCNT         = $2795         ; CD+G: recovery-hunt discarded
                                ; data symbol count
PL_GDX          = $2797         ; CD+G: scroll delta x (signed;
                                ; dedicated -- PL_DIV is reused
                                ; as the offset accumulator by
                                ; gfx_xy_off inside the scroll
                                ; routines themselves)
PL_GDY          = $2798         ; CD+G: scroll delta y (signed)
PL_SCPAUSED     = $278B         ; CD+G: 1 while a scroll has
                                ; CD-DA paused (see gs_apply)
PL_BBASE        = $27AF         ; CD+G: row-buffer base offset
                                ; (2 bytes; seg_setup adds it)
PL_GK           = $2796         ; CD+G: scroll copy flag (0 =
                                ; preset fill, 1 = copy wrap;
                                ; dedicated -- PL_K is seg_len's
                                ; internal scratch and does not
                                ; survive a scroll's own segment
                                ; machinery)
PL_GRPCNT       = $2799         ; CD+G: symbols in this group
PL_ZCNT         = $279A         ; CD+G: resync zero counter
PL_GOTBYTE      = $279B         ; CD+G: chunk received a byte
PL_DBBUSY       = $279D         ; CD+G: drain_burst re-entry guard
PL_GDE_X        = $279E         ; CD+G: dirty-edges loop counter
PL_GFR_I        = $279F         ; CD+G: fill-rows row counter
PL_GFF_B        = $27A0         ; CD+G: fb-fill bank counter
PL_GUO_R        = $27A1         ; CD+G: upload row counter
PL_GFR_C        = $27A2         ; CD+G: fill-rows byte count (2)
PL_GDS_C        = $27A4         ; CD+G: drain_some count (2)
PL_HDEPTH       = $27A6         ; CD+G: packet handler depth
                                ; (drain_burst is a no-op while
                                ; nonzero: the feed must never
                                ; recurse into packet handlers)
PL_UPCNT        = $279C         ; CD+G: chunks since upload
PL_QHEAD        = $27A7         ; CD+G: raw queue pop counter (2)
PL_QTAIL        = $27A9         ; CD+G: raw queue push counter (2)
PL_QBYTE        = $27AB         ; CD+G: raw queue byte staging
PL_QPUMP        = $27AC         ; CD+G: poll-feed FIFO pump counter
PL_HSKIP        = $27AD         ; CD+G: hunt first-byte count skip
PL_PREV         = $27AE         ; CD+G: previous byte fed
PL_RAWQ         = $2900         ; CD+G: 1024-byte raw symbol queue
                                ; (FIFO bytes captured during packet
                                ; handlers; fed in order afterwards)
PL_SYMRING      = $2800         ; CD+G: 256-byte symbol ring
        ; (work RAM $2800 is the IPL load area -- unused
        ; while the shell's player runs; re-initialised on
        ; every GRAPHICS entry and every sync lock)         ; 1 after CD_PAUSE until a play
        ; or stop: SUBQ reports status 3 both for paused and
        ; for stopped in this core (measured on the genuine
        ; card too, p005 case 22), so the pause state is
        ; tracked player-side.
