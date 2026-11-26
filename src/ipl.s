; COMPAT3 IPL boot (ws005 p002) -- CD_BOOT path.
; Implemented from the public Hu7 CD System BIOS / Software
; Manual IPL description: at RUN on a data disc, the BIOS reads
; the first two records of the first data track (the 4 KB IPL
; area) into work RAM at $2800. The IPL Information Block is the
; 128-byte header at the start of the second record ($3000):
;   +$00 IPLBLK  load start record no. (3 bytes, big-endian,
;                relative to the data track start)
;   +$03 IPLBLN  load record count
;   +$04 IPLSTA  load address (little-endian)
;   +$06 IPLJMP  entry address (little-endian)
;   +$08..+$0C   IPLMPR2..IPLMPR6, stored as (bank - $80):
;                the loader adds $80 back to each byte before
;                loading the MPRs (see ib_mpr_loop)
;   +$0D OPENMODE
;   +$20 "PC Engine CD-ROM SYSTEM",0  (ID string)
; The IPL area is validated by the ID string; the program is
; then loaded from record IPLBLK to IPLSTA with MPR2-MPR6 set
; from the header, the CD_BASE record base is set to the IPL
; record (both recbase pairs = the data track start), and
; control jumps to IPLJMP. An invalid disc takes the LOAD
; ERROR-equivalent path (MB_IPL_STAT + STATE_BOOT_ERROR).
;
; Genuine-BIOS behaviour (black-box findings, ws005
; investigation 2026-11-20; full instruction traces, see
; pce-web/PROGRESS.md): the genuine System Card 3.0 validates
; IPL record 0 by byte-comparing the loaded area at $2800
; against the Hudson copyright notice in its own ROM (1237
; bytes, then 74 bytes that must be $00), and its RAM IPL
; routine re-checks the $3020 ID string, parses this control
; block, and applies IPLMPR2-6 as stored byte + $80.
; DELIBERATE DIVERGENCE: COMPAT3 does NOT clone the record-0
; notice byte-compare and does not embed the notice text --
; that check is a genuine-BIOS behaviour tied to Hudson's
; copyrighted notice, and COMPAT3 keeps its own validation
; policy (the $3020 ID-string check above). The IPLMPR +$80
; semantics, by contrast, are part of the disc format itself
; (real discs are authored in the stored form), so they are
; mirrored exactly: without them a real-format disc would
; load into the wrong banks.
        .segment "CODE"

; -------------------------------------------------------------------
; read6_stream: READ(6) zp_count records starting at zp_lba
; (3 bytes) into memory at zp_dst. The destination advances
; linearly through whatever mapping is in force; for the
; program load (zp_dstmode 1) that is the IPL header's
; MPR2-MPR6 mapping, which stays FIXED for the whole transfer:
; each 8 KB window shows its header bank for the entire load,
; so a load crossing a window boundary simply continues into
; the next window's header bank (positional semantics -- the
; genuine BIOS's transfer loop streams linearly through the
; mapping the header set, per the Hu7 IPL description).
;
; HISTORY (p009 fix): the p002 implementation ADVANCED the
; next window's MPR by one bank at each crossing. With the
; normal consecutive header banks ($80,$81,$82,...) the
; header value already IS the continuation bank, so the
; first crossing landed the rest of the image one bank high
; (found by the minigame project: content at $6000+ landed
; in bank $82 instead of $81; their loads stayed within one
; window to work around it). The advance block is removed;
; zp_dstmode is now informational only.
; Carry set + zp_err on failure (same codes as scsi_cmd).
; -------------------------------------------------------------------
read6_stream:
        lda     #$00
        sta     zp_err
        ; CDB: 08 lba2 lba1 lba0 count 00 (+ zeros)
        lda     #$08
        sta     zp_cdb
        lda     zp_lba+2
        sta     zp_cdb+1
        lda     zp_lba+1
        sta     zp_cdb+2
        lda     zp_lba
        sta     zp_cdb+3
        lda     zp_count
        sta     zp_cdb+4
        lda     #$00
        sta     zp_cdb+5
        sta     zp_cdb+6
        sta     zp_cdb+7
        sta     zp_cdb+8
        sta     zp_cdb+9
        ; total bytes = count * 2048 (24-bit)
        lda     #$00
        sta     zp_bytes
        lda     zp_count
        asl     a
        asl     a
        asl     a
        sta     zp_bytes+1
        lda     zp_count
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        sta     zp_bytes+2
        ; select
        lda     #$01
        sta     $1801
        lda     #$00
        sta     $1800
        lda     #$80
        sta     zp_waitmask
        sta     zp_waitexpect
        jsr     wait1800
        bcc     r6_cdb
        lda     #$01
        sta     zp_err
        jmp     r6_fail
r6_cdb:
        ldx     #$00
r6_cdb_loop:
        lda     #$78
        sta     zp_waitmask
        lda     #$50
        sta     zp_waitexpect
        jsr     wait1800
        bcc     r6_cdb_send
        lda     #$02
        sta     zp_err
        jmp     r6_fail
r6_cdb_send:
        lda     zp_cdb,x
        sta     $1801
        jsr     ack_pulse
        bcc     r6_cdb_next
        lda     #$03
        sta     zp_err
        jmp     r6_fail
r6_cdb_next:
        inx
        cpx     #$06            ; READ(6) has a 6-byte CDB (the
        bne     r6_cdb_loop     ; $DE vendor command's 10-byte CDB
                                ; in scsi_cmd does not apply here;
                                ; bytes past 6 are never requested
                                ; and the phase wait would time out
                                ; in the data-in phase)
        ; data-in phase: stream zp_bytes bytes to (zp_dst).
        ; NOTE: for READ(6) this core auto-ACKs a data-port read
        ; and stalls the CPU on BUSREQ until the next byte is
        ; ready (PCE::cdrom_read case $01/$08), so inside the
        ; loop the host must NOT pulse ACK per byte (each manual
        ; ACK consumes an extra byte). But the phase transition
        ; itself is delayed (~10 us event in the device): a data
        ; port read issued before the data-in phase begins
        ; returns the idle data register (0) without consuming
        ; anything, which would prefix the stream with zeros --
        ; so first poll $1800 until the data-in phase pattern
        ; (REQ|IO, CD and MSG clear) is actually presented.
        lda     #$78
        sta     zp_waitmask
        lda     #$48
        sta     zp_waitexpect
        jsr     wait1800
        bcc     r6_data_loop
        lda     #$04
        sta     zp_err
        jmp     r6_fail
; The data phase runs through cdbios.s's chunked stream
; helpers (layer 10 round 4, C-G4): same device-pacing
; contract as CD_READ -- the old per-byte loop measured
; 57.09 clocks/byte here against the device's 46.61.
; zp_dst advances linearly (positional semantics across
; the fixed IPL header mapping; no per-window MPR advance
; -- see the p009 note above read6_stream).
r6_data_loop:
        jsr     cs_chunk_calc
        beq     r6_loop_done    ; a zero-count load moves
                                ; nothing (defensive; the IPL
                                ; header's count is nonzero)
        jsr     cs_store_n
        jsr     cs_chunk_sub
        bne     r6_data_loop
r6_loop_done:
        ; status phase
        lda     #$78
        sta     zp_waitmask
        lda     #$58
        sta     zp_waitexpect
        jsr     wait1800
        bcc     r6_status_get
        lda     #$05
        sta     zp_err
        jmp     r6_fail
r6_status_get:
        lda     $1801
        sta     zp_scsi_stat
        jsr     ack_pulse
        bcc     r6_msg
        lda     #$03
        sta     zp_err
        jmp     r6_fail
r6_msg:
        lda     #$78
        sta     zp_waitmask
        sta     zp_waitexpect
        jsr     wait1800
        bcc     r6_msg_get
        lda     #$06
        sta     zp_err
        jmp     r6_fail
r6_msg_get:
        lda     $1801
        sta     zp_scsi_msg
        jsr     ack_pulse
        bcc     r6_done
        lda     #$03
        sta     zp_err
        jmp     r6_fail
r6_done:
        ; wait for the bus to go free (BSY drop) so the device
        ; is fully idle at handoff: this core latches BUSREQ at
        ; the last data-port read and only releases it on the
        ; next REQ edge; returning with the transaction merely
        ; message-complete left a window in which the loaded
        ; program's first instructions could stall/derail
        ; (p003 phase-4/exec2 flakiness, 2026-11-20). The poll
        ; is bounded by wait1800's timeout; its result is
        ; ignored (the status byte already decided success).
        lda     #$80
        sta     zp_waitmask
        lda     #$00
        sta     zp_waitexpect
        jsr     wait1800
        lda     zp_scsi_stat
        beq     r6_ok
        lda     #$F0
        sta     zp_err
        jmp     r6_fail
r6_ok:
        clc
        rts
r6_fail:
        jsr     scsi_bus_reset
        sec
        rts

; -------------------------------------------------------------------
; ipl_set_mprs: load MPR2-MPR6 from zp_iplmpr (5 bytes).
; -------------------------------------------------------------------
ipl_set_mprs:
        lda     zp_iplmpr
        tam     #$04
        lda     zp_iplmpr+1
        tam     #$08
        lda     zp_iplmpr+2
        tam     #$10
        lda     zp_iplmpr+3
        tam     #$20
        lda     zp_iplmpr+4
        tam     #$40
        rts

; -------------------------------------------------------------------
; ipl_boot: attempt the IPL boot for the data disc found by
; disc_check (zp_data_lba). Returns only on failure, with the
; boot-error screen drawn and MB_IPL_STAT / MB_STATE set.
; On success it jumps to the loaded program and never returns.
; -------------------------------------------------------------------
ipl_boot:
        lda     #STATE_BOOTING
        sta     MB_STATE
        lda     #$00
        sta     MB_IPL_STAT
        lda     zp_data_found
        bne     ib_have_track
        lda     #$04
        jmp     ipl_fail
ib_have_track:
        ; read the 4 KB IPL area (2 records) to $2800
        lda     zp_data_lba
        sta     zp_lba
        lda     zp_data_lba+1
        sta     zp_lba+1
        lda     zp_data_lba+2
        sta     zp_lba+2
        lda     #$02
        sta     zp_count
        lda     #$00
        sta     zp_dst
        lda     #$28
        sta     zp_dst+1
        lda     #$00
        sta     zp_dstmode
        jsr     read6_stream
        bcc     ib_read_ok
        lda     #$03
        jmp     ipl_fail
ib_read_ok:
        ; validate the ID string at $3000 + $20 (23 bytes)
        ldx     #$00
ib_id_loop:
        lda     ipl_id_str,x
        cmp     $3020,x
        bne     ib_bad_id
        inx
        cpx     #$17
        bne     ib_id_loop
        bra     ib_parse
ib_bad_id:
        lda     #$02
        jmp     ipl_fail
ib_parse:
        ; IPLBLK (big-endian 24-bit) at $3000
        lda     $3000
        sta     zp_blk+2
        lda     $3001
        sta     zp_blk+1
        lda     $3002
        sta     zp_blk
        lda     $3003
        sta     zp_bln
        lda     $3004
        sta     zp_iplsta
        lda     $3005
        sta     zp_iplsta+1
        lda     $3006
        sta     zp_ipljmp
        lda     $3007
        sta     zp_ipljmp+1
        ; IPLMPR2-6 are stored in the header as (bank - $80);
        ; add the $80 back so zp_iplmpr holds the effective
        ; bank numbers (the genuine BIOS's RAM IPL routine
        ; does exactly this, adding the byte at $FFF5 = $80).
        ldx     #$00
ib_mpr_loop:
        lda     $3008,x
        clc
        adc     #$80
        sta     zp_iplmpr,x
        inx
        cpx     #$05
        bne     ib_mpr_loop
        ; CD_BASE: both recbase pairs = the data track start
        ; (the IPL record base, per the manual's IPL
        ; description), stored big-endian (H, M, L) at the
        ; public work addresses $2274-$2279
        lda     zp_data_lba+2
        sta     WV_RECBASE0
        sta     WV_RECBASE1
        lda     zp_data_lba+1
        sta     WV_RECBASE0+1
        sta     WV_RECBASE1+1
        lda     zp_data_lba
        sta     WV_RECBASE0+2
        sta     WV_RECBASE1+2
        ; OPENMODE openings (ADP part; the graphics opening
        ; is p005) run before the program load
        jsr     ipl_adp_opening
        ; set MPR2-MPR6 from the header, then load the program:
        ; records [IPLBLK, IPLBLK+IPLBN) from the track start to
        ; IPLSTA under those MPRs
        jsr     ipl_set_mprs
        lda     zp_data_lba
        clc
        adc     zp_blk
        sta     zp_lba
        lda     zp_data_lba+1
        adc     zp_blk+1
        sta     zp_lba+1
        lda     zp_data_lba+2
        adc     zp_blk+2
        sta     zp_lba+2
        lda     zp_bln
        sta     zp_count
        lda     zp_iplsta
        sta     zp_dst
        lda     zp_iplsta+1
        sta     zp_dst+1
        lda     #$01
        sta     zp_dstmode
        jsr     read6_stream
        bcc     ib_loaded
        lda     #$03
        jmp     ipl_fail
ib_loaded:
        lda     #$01
        sta     MB_IPL_STAT
        ; Handoff argument shadows (measured on the
        ; genuine via Dracula X's IPL program, 2026-11-23):
        ; at the loaded program's first BIOS calls the
        ; shadows hold the genuine loader's own program-
        ; load CD_READ exit state -- _AL = _AH = 0,
        ; _BL/_BH = IPLSTA low / high + 8*IPLBLN - 1,
        ; (CL,CH,DL) = data_lba + IPLBLK (the absolute
        ; start LBA of the program load), _DH = $01
        ; (LOCAL). The game's loader reads (CH,DL) and
        ; _BH back as its stream state, so leaving the
        ; shell's zeroes there derails it. Mirror the
        ; public CD_READ exit contract for that load.
        lda     zp_bln
        beq     ib_sh_done      ; no load: no state
        lda     #$00
        sta     ARG_AL
        sta     ARG_AH
        lda     zp_iplsta
        sta     ARG_BL
        lda     zp_bln
        asl     a
        asl     a
        asl     a
        sec
        sbc     #$01
        clc
        adc     zp_iplsta+1
        sta     ARG_BH
        clc
        lda     zp_data_lba
        adc     zp_blk
        sta     ARG_DL
        lda     zp_data_lba+1
        adc     zp_blk+1
        sta     ARG_CH
        lda     zp_data_lba+2
        adc     zp_blk+2
        sta     ARG_CL
        lda     #$01
        sta     ARG_DH
ib_sh_done:
        ; Program-ZP handover (C-D4 fix-up): the genuine
        ; hands the loaded program its ZP $00-$D7 exactly as
        ; the reset RAM clear left it (measured via bmtest
        ; case 0: the genuine's BM_FREE logs the program
        ; cells $C8-$CB as $00). COMPAT3's boot path uses
        ; three shared ZP pointer cells -- zp_dataptr
        ; (de_cmd during disc_check leaves it at zp_dirbuf),
        ; zp_dst (the IPL streams above leave it at the load
        ; end) and zp_ptr (the shell's print path) -- so
        ; clear them back to their reset values here, at the
        ; last moment before the jump.
        stz     zp_dst
        stz     zp_dst+1
        stz     zp_dataptr
        stz     zp_dataptr+1
        stz     zp_ptr
        stz     zp_ptr+1
        ; Display configuration at handover: NONE (layer 10
        ; round 6, spec_gate.md S10 contract C-G5, replacing
        ; round 3's C-G3). Round-6 re-measurement with
        ; slot-entry correlation showed the genuine writes
        ; no VDC timing registers at the IPL handover: the
        ; burst round 3 attributed to the handover sits
        ; inside the game's own EX_SCMOD call. Each title's
        ; timing set now arrives via that call under the
        ; C-L6 apply (exbios.s scrmod_apply); the registers
        ; here stay exactly as BIOS init and the BIOS's own
        ; screens left them.
        ; Handoff state (measured 2026-11-22, Dracula X boot
        ; + irqtest probe):
        ; - at the loaded program's first park the genuine
        ;   card shows SP = $FF and the I flag CLEAR, while
        ;   COMPAT3's shell-inherited state (SP = $FD with
        ;   stale call returns, I set -- the shell runs
        ;   masked) differed.
        ; - at IPL entry the genuine leaves the CPU IRQ mask
        ;   register $1402 = $00 (all sources live); COMPAT3
        ;   handed over $0E (IRQ1 + timer masked), so a
        ;   program that relies on the handoff mask (Dracula
        ;   X never writes $1402 itself) never took an IRQ1
        ;   and parked forever.
        ; Mirror the genuine transfer: pristine stack,
        ; interrupts enabled, $1402 = $00.
        ldx     #$FF
        txs
        stz     IRQ_MASK
        cli
        ; jump to IPLJMP: push (target - 1) and RTS into it
        lda     zp_ipljmp
        bne     ib_jmp_lo
        dec     zp_ipljmp+1
ib_jmp_lo:
        dec     zp_ipljmp
        lda     zp_ipljmp+1
        pha
        lda     zp_ipljmp
        pha
        rts
ipl_id_str:
        .byte   "PC Engine CD-ROM SYSTEM"

; -------------------------------------------------------------------
; ipl_fail: A = MB_IPL_STAT code. Draw the title screen plus the
; LOAD ERROR line and park the shell in STATE_BOOT_ERROR.
; -------------------------------------------------------------------
ipl_fail:
        sta     MB_IPL_STAT
        lda     zp_err          ; publish the SCSI error code too
        sta     MB_IPL_ERR
        jsr     show_title
        ; "LOAD ERROR" -- row 18, col 2, palette 0
        lda     #$12
        ldx     #$02
        jsr     set_cursor
        lda     #$00
        sta     zp_pal
        lda     #<str_loaderr
        sta     zp_ptr
        lda     #>str_loaderr
        sta     zp_ptr+1
        jsr     print_str
        lda     #STATE_BOOT_ERROR
        sta     MB_STATE
        rts
str_loaderr:    .byte "LOAD ERROR", 0
