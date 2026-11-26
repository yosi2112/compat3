; COMPAT3 joypad reading.
; Port protocol per public documentation and the core's joypad
; model: writing the port with bit 1 set (CLR) toggles the
; 6-button pad phase and resets the nibble counter; bit 0 (SEL)
; selects the nibble -- 1 = directions (Up, Right, Down, Left),
; 0 = buttons (I, II, Select, Run). A second CLR pulse switches
; to the extended phase, whose buttons nibble carries III-VI.
; All nibbles are active low. The two-pulse sequence below is the
; same pattern the ws001/ws004 harness ROMs verified against this
; core. Results are stored active-high:
;   zp_pad_dir: bit0 Up, bit1 Right, bit2 Down, bit3 Left
;   zp_pad_cur: bit0 I, bit1 II, bit2 Select, bit3 Run,
;               bit4 III, bit5 IV, bit6 V, bit7 VI
        .segment "CODE"
read_pad:
        ; phase A
        lda     #$02
        sta     JOYPAD          ; CLR pulse
        lda     #$01
        sta     JOYPAD          ; SEL = 1
        lda     JOYPAD
        and     #$0F
        eor     #$0F
        sta     zp_pad_dir
        lda     #$00
        sta     JOYPAD          ; SEL = 0
        lda     JOYPAD
        and     #$0F
        eor     #$0F
        sta     zp_pad_cur      ; I, II, Select, Run in bits 0-3
        ; phase B (III-VI)
        lda     #$02
        sta     JOYPAD          ; CLR pulse
        lda     #$01
        sta     JOYPAD          ; SEL = 1
        lda     JOYPAD          ; extended directions (unused)
        lda     #$00
        sta     JOYPAD          ; SEL = 0
        lda     JOYPAD
        and     #$0F
        eor     #$0F
        asl     a
        asl     a
        asl     a
        asl     a
        ora     zp_pad_cur
        sta     zp_pad_cur
        rts
