; COMPAT3 SCSI issuer for the CD unit, and disc classification.
; The bus handshake follows the public PC Engine CD interface
; documentation; the exact phase values were confirmed by
; black-box probing of this core in ws004 (the harness ROM in
; pce-web/gen_cdgrom.py speaks the same protocol):
;   $1800 read  = bus status (BSY $80, phase bits mask $78,
;                 REQ $40): command $50, data-in $48, status $58,
;                 message $78
;   $1801       = data port (CDB out / data, status, message in)
;   $1802       = write $80 to assert ACK, $00 to release
;   $1804       = write $02 then $00 to pulse bus reset
;   select: $1801 = target bit ($01), then write $1800 = $00,
;           wait for BSY.
; Error codes in zp_err mirror the harness ROM's: 1 BSY wait,
; 2 command phase, 3 REQ-off (ACK) wait, 4 data phase,
; 5 status phase, 6 message phase, $F0 bad status byte.
        .segment "CODE"

; wait1800: poll $1800 until (value & zp_waitmask) == zp_waitexpect.
; Carry clear = matched, carry set = timeout (65536 polls).
wait1800:
        ; Layer-5: the $FFFF timeout counts in X/Y, not in a
        ; memory cell. When the work block moved from ZP to WRAM
        ; every iteration of this loop gained ~4 cycles, and a
        ; full timeout (the no-disc path runs many back to back)
        ; stretched ~17% in wall time -- enough to push the
        ; shell's RUN->player transition past the frame budget
        ; the p001 S3 gate allows. Register counting is faster
        ; than even the old ZP form. X/Y are preserved for the
        ; callers that hold an index across the call.
        phx
        phy
        ldx     #$FF
        ldy     #$FF
w18_loop:
        lda     $1800
        and     zp_waitmask
        cmp     zp_waitexpect
        beq     w18_ok
        dex
        cpx     #$FF
        bne     w18_loop
        dey
        cpy     #$FF
        bne     w18_loop
        ply
        plx
        sec
        rts
w18_ok:
        ply
        plx
        clc
        rts

; ack_pulse: assert ACK, wait for REQ to drop, release ACK.
; Carry propagates the wait result (LDA does not touch carry).
; The release value preserves the ADPCM IRQ mask bits
; (zp_imask): $1802 bit 7 is ACK, bits 0-6 are the IRQ mask,
; and a raw $00 here muted the ADPCM full-play IRQ for the
; rest of a session (the IPL opening's repeat play died
; during the program load's ACK traffic, p004).
ack_pulse:
        lda     #$80
        ora     zp_imask
        sta     $1802
        lda     #$40
        sta     zp_waitmask
        lda     #$00
        sta     zp_waitexpect
        jsr     wait1800
        lda     zp_imask
        sta     $1802
        rts

; scsi_bus_reset: pulse the reset line.
scsi_bus_reset:
        lda     #$02
        sta     $1804
        lda     #$00
        sta     $1804
        rts

; scsi_cmd: issue the 10-byte CDB at zp_cdb; if zp_datalen > 0,
; read that many data-in bytes to (zp_dataptr). On success carry
; is clear and zp_scsi_stat / zp_scsi_msg hold the ending bytes.
; On failure carry is set, zp_err holds the phase code, and the
; bus is reset to leave the target in a clean state.
scsi_cmd:
        lda     #$00
        sta     zp_err
        ; select
        lda     #$01
        sta     $1801
        lda     #$00
        sta     $1800
        lda     #$80
        sta     zp_waitmask
        sta     zp_waitexpect
        jsr     wait1800
        bcc     sc_cdb
        lda     #$01
        sta     zp_err
        jmp     scsi_fail
sc_cdb:
        ldx     #$00
sc_cdb_loop:
        lda     #$78
        sta     zp_waitmask
        lda     #$50
        sta     zp_waitexpect
        jsr     wait1800
        bcc     sc_cdb_send
        lda     #$02
        sta     zp_err
        jmp     scsi_fail
sc_cdb_send:
        lda     zp_cdb,x
        sta     $1801
        jsr     ack_pulse
        bcc     sc_cdb_next
        lda     #$03
        sta     zp_err
        jmp     scsi_fail
sc_cdb_next:
        inx
        cpx     #$0A
        bne     sc_cdb_loop
        ; data-in phase (optional)
        lda     zp_datalen
        beq     sc_status
        ldy     #$00
sc_data_loop:
        lda     #$78
        sta     zp_waitmask
        lda     #$48
        sta     zp_waitexpect
        jsr     wait1800
        bcc     sc_data_get
        lda     #$04
        sta     zp_err
        jmp     scsi_fail
sc_data_get:
        lda     $1801
        sta     (zp_dataptr),y
        jsr     ack_pulse
        bcc     sc_data_next
        lda     #$03
        sta     zp_err
        jmp     scsi_fail
sc_data_next:
        iny
        cpy     zp_datalen
        bne     sc_data_loop
sc_status:
        lda     #$78
        sta     zp_waitmask
        lda     #$58
        sta     zp_waitexpect
        jsr     wait1800
        bcc     sc_status_get
        lda     #$05
        sta     zp_err
        jmp     scsi_fail
sc_status_get:
        lda     $1801
        sta     zp_scsi_stat
        jsr     ack_pulse
        bcc     sc_msg
        lda     #$03
        sta     zp_err
        jmp     scsi_fail
sc_msg:
        lda     #$78
        sta     zp_waitmask
        sta     zp_waitexpect
        jsr     wait1800
        bcc     sc_msg_get
        lda     #$06
        sta     zp_err
        jmp     scsi_fail
sc_msg_get:
        lda     $1801
        sta     zp_scsi_msg
        jsr     ack_pulse
        bcc     sc_done
        lda     #$03
        sta     zp_err
        jmp     scsi_fail
sc_done:
        ; wait for the bus to go free (BSY drop); see the note
        ; at read6_stream's r6_done in ipl.s. Bounded, ignored.
        lda     #$80
        sta     zp_waitmask
        lda     #$00
        sta     zp_waitexpect
        jsr     wait1800
        clc
        rts
scsi_fail:
        jsr     scsi_bus_reset
        sec
        rts

; de_cmd: NEC vendor command $DE (Get Dir Info). A = subcommand
; (goes in CDB byte 1), X = CDB byte 2 (BCD track for sub 2).
; Reads 4 bytes into zp_dirbuf. Carry set on transport error or a
; nonzero status byte.
de_cmd:
        sta     zp_cdb+1
        stx     zp_cdb+2
        lda     #$DE
        sta     zp_cdb
        lda     #$00
        sta     zp_cdb+3
        sta     zp_cdb+4
        sta     zp_cdb+5
        sta     zp_cdb+6
        sta     zp_cdb+7
        sta     zp_cdb+8
        sta     zp_cdb+9
        ; NOTE: the data pointer is a full logical address.
        ; zp_dirbuf lived in zero page until the layer-5 round
        ; and this site formed its address as $2000 + zp_dirbuf;
        ; the buffer is WRAM now, so the equate IS the address.
        ; (Forming $2000 + a WRAM address silently drops the
        ; received bytes into the $4000 window: the command
        ; completes GOOD with an all-zero reply buffer.)
        lda     #<zp_dirbuf
        sta     zp_dataptr
        lda     #>zp_dirbuf
        sta     zp_dataptr+1
        lda     #$04
        sta     zp_datalen
        jsr     scsi_cmd
        bcs     de_ret          ; transport error: carry already set
        lda     zp_scsi_stat    ; (LDA/BEQ do not disturb carry)
        beq     de_ret          ; status 0: carry still clear = ok
        lda     #$F0
        sta     zp_err
        sec
de_ret:
        rts

; delay_short: ~80K cycles of busy wait (spin-up pacing).
delay_short:
        ldx     #$40
ds_x:
        ldy     #$00
ds_y:
        dey
        bne     ds_y
        dex
        bne     ds_x
        rts

; from_bcd: A = BCD byte -> A = binary (0-99).
from_bcd:
        sta     zp_tmp0
        and     #$0F
        sta     zp_tmp2         ; units
        lda     zp_tmp0
        lsr     a
        lsr     a
        lsr     a
        lsr     a               ; tens
        sta     zp_tmp0
        lda     #$00
fb_loop:
        ldx     zp_tmp0
        beq     fb_done
        clc
        adc     #$0A
        dec     zp_tmp0
        bra     fb_loop
fb_done:
        clc
        adc     zp_tmp2
        rts

; to_bcd: A = binary (0-99) -> A = BCD byte.
to_bcd:
        ldx     #$00
tb_loop:
        cmp     #$0A
        bcc     tb_done
        sec
        sbc     #$0A
        inx
        bra     tb_loop
tb_done:
        sta     zp_tmp2
        txa
        asl     a
        asl     a
        asl     a
        asl     a
        ora     zp_tmp2
        rts

; msf_to_lba: convert the BCD-decoded MSF in zp_msf (M, S, F,
; binary) to a logical block address in zp_acc (3 bytes):
;   LBA = ((M * 60) + S) * 75 + F - 150, clamped at 0.
; (MSF 00:02:00 is LBA 0 by the usual 2-second offset.)
msf_to_lba:
        lda     #$00
        sta     zp_acc
        sta     zp_acc+1
        sta     zp_acc+2
        ldx     zp_msf          ; acc = M * 60
        beq     m2l_sec
m2l_mloop:
        lda     zp_acc
        clc
        adc     #$3C
        sta     zp_acc
        lda     zp_acc+1
        adc     #$00
        sta     zp_acc+1
        dex
        bne     m2l_mloop
m2l_sec:
        lda     zp_acc          ; acc += S
        clc
        adc     zp_msf+1
        sta     zp_acc
        lda     zp_acc+1
        adc     #$00
        sta     zp_acc+1
        ; save the 16-bit multiplicand, then frames = acc * 75
        lda     zp_acc
        sta     zp_lba
        lda     zp_acc+1
        sta     zp_lba+1
        lda     #$00
        sta     zp_acc
        sta     zp_acc+1
        sta     zp_acc+2
        ldx     #$4B            ; 75
m2l_floop:
        lda     zp_acc
        clc
        adc     zp_lba
        sta     zp_acc
        lda     zp_acc+1
        adc     zp_lba+1
        sta     zp_acc+1
        lda     zp_acc+2
        adc     #$00
        sta     zp_acc+2
        dex
        bne     m2l_floop
        lda     zp_acc          ; frames += F
        clc
        adc     zp_msf+2
        sta     zp_acc
        lda     zp_acc+1
        adc     #$00
        sta     zp_acc+1
        lda     zp_acc+2
        adc     #$00
        sta     zp_acc+2
        lda     zp_acc          ; LBA = frames - 150
        sec
        sbc     #$96
        sta     zp_acc
        lda     zp_acc+1
        sbc     #$00
        sta     zp_acc+1
        lda     zp_acc+2
        sbc     #$00
        sta     zp_acc+2
        bcs     m2l_done        ; no borrow: fine
        lda     #$00            ; negative: clamp to 0
        sta     zp_acc
        sta     zp_acc+1
        sta     zp_acc+2
m2l_done:
        rts

; disc_check: classify the inserted disc.
;   zp_disc   = DISC_NONE / DISC_AUDIO / DISC_DATA
;   zp_tracks = track count (0 when none / unknown)
;   zp_data_lba = start LBA of the first data track (if any),
;                 with zp_data_found nonzero
; Uses NEC $DE Get Dir Info: sub 0 gives first/last track (BCD);
; sub 2 per track gives type in reply byte 3 ($04 = data).
disc_check:
        lda     #DISC_NONE
        sta     zp_disc
        lda     #$00
        sta     zp_tracks
        sta     zp_data_found
        sta     zp_data_lba
        sta     zp_data_lba+1
        sta     zp_data_lba+2
        jsr     scsi_bus_reset
        ; The drive needs spin-up time after power-on: an early
        ; Get Dir Info can complete with GOOD status but a zeroed
        ; reply (observed on this core -- the harness ROMs that
        ; worked took far longer to reach their first command).
        ; Retry until the reply is plausible (last track != 0) or
        ; the budget runs out; a real failure keeps its zp_err.
        lda     #$10
        sta     zp_retry
dc_try:
        lda     #$00
        ldx     #$00
        jsr     de_cmd
        bcs     dc_retry        ; transport error: zp_err is set
        lda     zp_dirbuf+1     ; last track, BCD
        bne     dc_ready
        lda     #$F1            ; completed but not ready (zeros)
        sta     zp_err
dc_retry:
        dec     zp_retry
        bne     dc_retry_go
        jmp     dc_done         ; (trampoline: dc_done out of
                                ; branch range since the ZP
                                ; work area moved to WRAM)
dc_retry_go:
        jsr     delay_short
        bra     dc_try
dc_ready:
        lda     zp_dirbuf+1     ; last track, BCD
        jsr     from_bcd
        sta     zp_tracks
        beq     dc_done         ; no tracks -> treat as no disc
        lda     #$01
        sta     zp_tmp1         ; current track (binary)
dc_scan:
        lda     zp_tmp1
        jsr     to_bcd
        tax
        lda     #$02
        jsr     de_cmd
        bcs     dc_next
        lda     zp_dirbuf+3
        cmp     #$04
        bne     dc_next
        lda     #DISC_DATA
        sta     zp_disc
        lda     zp_data_found   ; remember the FIRST data track
        bne     dc_next
        lda     zp_dirbuf       ; reply MSF (BCD) -> binary
        jsr     from_bcd
        sta     zp_msf
        lda     zp_dirbuf+1
        jsr     from_bcd
        sta     zp_msf+1
        lda     zp_dirbuf+2
        jsr     from_bcd
        sta     zp_msf+2
        jsr     msf_to_lba
        lda     zp_acc
        sta     zp_data_lba
        lda     zp_acc+1
        sta     zp_data_lba+1
        lda     zp_acc+2
        sta     zp_data_lba+2
        lda     #$01
        sta     zp_data_found
dc_next:
        inc     zp_tmp1
        lda     zp_tmp1
        cmp     zp_tracks
        beq     dc_scan         ; do the last track too
        bcc     dc_scan
        ; scan complete
        lda     zp_disc
        bne     dc_toc
        lda     #DISC_AUDIO
        sta     zp_disc
dc_toc:
        ; fill the public TOC work variables ($226A-$226E),
        ; as the genuine BIOS does during its boot disc check
        lda     zp_tracks
        beq     dc_done
        jsr     toc_refresh
dc_done:
        lda     zp_disc
        sta     MB_DISC
        lda     zp_tracks
        sta     MB_TRACKS
        lda     zp_scsi_stat
        sta     MB_SCSI_STAT
        lda     zp_scsi_msg
        sta     MB_SCSI_MSG
        lda     zp_err
        sta     MB_SCSI_ERR
        rts
