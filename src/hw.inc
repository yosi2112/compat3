; COMPAT3 -- hardware constants and shared conventions.
; Clean-room: everything here is from public PC Engine documentation
; (zeograd, Hu7 BIOS manual) and from the CSCP core sources in this
; repository. No NEC/Hudson code or data is used anywhere in COMPAT3.

; --- I/O page (MPR0 = $FF, logical $0000-$1FFF) -------------------
; NOTE: addresses < $0100 must be accessed with the ca65 `a:` prefix
; to force absolute addressing; plain $00xx assembles as zero page.
VDC_SEL         = $0000         ; VDC register select (write) /
                                ; status (read) -- USE a: PREFIX
VDC_DLO         = $0002         ; VDC data low   -- USE a: PREFIX
VDC_DHI         = $0003         ; VDC data high  -- USE a: PREFIX
VCE_CTL         = $0400         ; VCE control
VCE_PAL_LO      = $0402         ; VCE palette address low
VCE_PAL_HI      = $0403         ; VCE palette address high
VCE_PAL_DLO     = $0404         ; VCE palette data low
VCE_PAL_DHI     = $0405         ; VCE palette data high
PSG             = $0800         ; PSG registers $0800-$0807
TIMER           = $0C00
JOYPAD          = $1000         ; joypad port (write SEL/CLR, read)
IRQ_MASK        = $1402         ; IRQ disable register
IRQ_ACK         = $1403         ; IRQ acknowledge register
CD_PORT         = $1800         ; CD interface $1800-$180F
CD_ID1          = $18C1         ; core-synthesized ID bytes (read):
CD_ID2          = $18C2         ;   $AA, $55, ..., version at $18C7
CD_IDVER        = $18C7

; --- VDC register numbers -----------------------------------------
VDC_MAWR        = 0
VDC_MARR        = 1
VDC_VWR         = 2
VDC_VRR         = 3
VDC_CR          = 5
VDC_RCR         = 6
VDC_BXR         = 7
VDC_BYR         = 8
VDC_MWR         = 9
VDC_HSR         = 10
VDC_HDR         = 11
VDC_VPR         = 12
VDC_VDW         = 13
VDC_VCR         = 14
VDC_DCR         = 15
VDC_SOUR        = 16
VDC_DESR        = 17
VDC_LENR        = 18
VDC_DVSSR       = 19

VDC_STATUS_VD   = $20           ; status bit: vertical blank
VDC_STATUS_RR   = $04           ; status bit: raster compare

; --- Memory map ----------------------------------------------------
; MPR1 = $F8: work RAM at logical $2000-$3FFF (zero page is
; $2000-$20FF, stack $2100-$21FF). MPR7 = $00: this ROM bank at
; $E000-$FFFF. MPR0 = $FF: I/O page.
BANK_CD_RAM_LO  = $68           ; first CD RAM MPR bank ($68-$87)
BANK_CD_RAM_HI  = $87           ; last  CD RAM MPR bank

; --- Public BIOS argument shadows (work RAM $20F8-$20FF) -----------
; The documented calling convention: callers place arguments in
; these zero-page shadow bytes before JSR $E000+3*n (zeograd BIOS
; document; Hu7 manual's _AL/_AH/... notation). CD_STAT and
; CD_FADE are the exceptions: they take the real A register.
ARG_AL          = $20F8
ARG_AH          = $20F9
ARG_BL          = $20FA
ARG_BH          = $20FB
ARG_CL          = $20FC
ARG_CH          = $20FD
ARG_DL          = $20FE
ARG_DH          = $20FF

; --- Public BIOS work variables (Hu7 manual "BIOS ENTRY and WORK --
; --- equ" list, p.41-42; games may read these directly) -----------
WV_TNOMIN       = $226A         ; first track no. (BCD), CD_CONTNTS
WV_TNOMAX       = $226B         ; last track no. (BCD)
WV_OUTMIN       = $226C         ; lead-out start M (BCD)
WV_OUTSEC       = $226D         ; lead-out start S (BCD)
WV_OUTFRM       = $226E         ; lead-out start F (BCD)
WV_PLAYEND_M    = $226F         ; CD_PLAY's recorded end position
WV_PLAYEND_S    = $2270         ; (BCD MSF of lead-out frame - 1;
WV_PLAYEND_F    = $2271         ; measured on the genuine, p005)
WV_VDTIN_FLG    = $2272         ; 1 while a VRAM transfer runs
WV_RECBASE0     = $2274         ; CD_BASE pair 0: H, M, L (3 bytes)
WV_RECBASE1     = $2277         ; CD_BASE pair 1: H, M, L (3 bytes)
WV_REC1X        = $227A         ; one past pair 1: AD_CPLAY writes
                                ; $88 there for counts > 32 records,
                                ; $00 otherwise (measured, p004)
WV_SCSISTS      = $227B         ; last SCSI status (BIOS work)
WV_SUBERRC      = $227C         ; last SUB ERROR CODE (BIOS work)
WV_SENSE        = $227D         ; last REQUEST SENSE key byte
                                ; (stored by CD_STAT's ready check
                                ; on CHECK CONDITION; measured on
                                ; the genuine BIOS 2026-11-20: $06
                                ; after a media change, sticky)
WV_SUBCODE      = $227E         ; last raw subcode byte (CD_SUBRQ)
WV_PRIV_BASEC   = $27E4         ; cd_base: saved entry processor
                                ; status (carry restore, layer3)
WV_PRIV_SX      = $27E5         ; cd_play/cd_search: saved entry X
WV_PRIV_SY      = $27E6         ; cd_play/cd_search: saved entry Y
                                ; ($22A0-$22A7 = BM_TII stub)

; SUB ERROR CODEs (Hu7 manual p.40, public list).
ERR_OK          = $00
ERR_NOT_READY   = $04
ERR_NO_DISC     = $0B
ERR_NOT_DATA    = $1D           ; read address not in a data track
ERR_END_VOLUME  = $25           ; address beyond disc end
ERR_BAD_PARAM   = $22

; --- Player work area (work RAM $2300-$26FF; shell-only, used ---
; --- by player.s while the title/player shell runs) ---------------
PL_CURSOR       = $2300         ; selected track (binary)
PL_WIN          = $2301         ; first visible track index (0-based)
PL_PLAYTRK      = $2302         ; last started track (binary, 0=none)
PL_STATUS       = $2303         ; last CD_SUBQ status (0/2/3)
PL_TICK         = $2304         ; player frame counter
PL_DIRPREV      = $2305         ; previous zp_pad_dir (edge detect)
PL_GFX          = $2306         ; 1 while GRAPHICS (CD+G) mode runs
PL_NTRACKS      = $2307         ; track count (binary)
PL_TMIN         = $2308         ; first track (binary)
PL_TMAX         = $2309         ; last track (binary)
PL_DBUF         = $230A         ; CD_DINFO reply scratch (4 bytes)
PL_LASTRPT      = $230E         ; CD+G: last Memory Preset repeat
PL_PKTN         = $230F         ; CD+G: packet bytes collected
PL_SUBQBUF      = $2310         ; CD_SUBQ reply buffer (10 bytes)
PL_CLUT         = $231A         ; CD+G: 16 PCE palette words (32 B)
PL_PKT          = $2340         ; CD+G: packet assembly (24 bytes)
PL_TSTART       = $2360         ; 99 x 3 BCD MSF track starts
PL_TLENBCD      = $2520         ; 99 x 2 track lengths (BCD min, sec)
PL_DIRTY        = $26D0         ; CD+G: 108-byte tile dirty map
PL_TILEBUF      = $2740         ; CD+G: 32-byte tile conversion buf
PL_UPIDX        = $2760         ; CD+G: dirty-scan rotation index (2)
PL_GOFFX        = $2762         ; CD+G: scroll offsets (best-effort)
PL_GOFFY        = $2763

; --- Diagnostic mailbox (work RAM, logical) ------------------------
; COMPAT3 publishes boot/self-test observables here so the Node
; differential harness can compare outcomes across cards without
; any special hardware. Physical address = $1F0000 + (logical-$2000).
MB_GETVER_X     = $2F00         ; EX_GETVER self-test: X result
MB_GETVER_Y     = $2F01         ; EX_GETVER self-test: Y result
MB_MAGIC        = $2F02         ; $A5 once boot init has run
MB_ID0          = $2F03         ; captured $18C1 (expect $AA)
MB_ID1          = $2F04         ; captured $18C2 (expect $55)
MB_ID2          = $2F05         ; captured $18C7 (expect $03)
MB_STATE        = $2F10         ; boot state machine state:
                                ;   0 = booting / skeleton idle
                                ;   1 = title screen
                                ;   2 = disc check in progress
                                ;   3 = player, no disc
                                ;   4 = player, audio disc
                                ;   5 = player, data disc
MB_DISC         = $2F11         ; disc class: 0 none, 1 audio, 2 data
MB_TRACKS       = $2F12         ; track count (binary) if known
MB_SCSI_STAT    = $2F13         ; last SCSI status byte
MB_SCSI_MSG     = $2F14         ; last SCSI message byte
MB_SCSI_ERR     = $2F15         ; last SCSI issuer error (0 = ok)
MB_IPL_STAT     = $2F16         ; IPL boot result: 0 = not tried,
                                ;   1 = loaded + jumped, 2 = bad IPL
                                ;   ID string, 3 = transport error,
                                ;   4 = no data track
MB_IPL_ERR      = $2F17         ; zp_err captured at ipl_fail time
                                ;   (MB_SCSI_ERR gets overwritten by
                                ;   the error screen's disc_check)

; --- BIOS private work area -----------------------------------------
; --- Layer-3 fix (2026-11-23): the BIOS scratch cells that used
; --- to live in zero page $00-$7F now live in a private WRAM
; --- block at $2764-$27E3 (offsets preserved). The genuine BIOS
; --- keeps its work in WRAM and leaves the game's zero page
; --- alone during public calls; Dracula X's IPL loader keeps
; --- live stream state in zp $00-$09 across CD_READ calls and
; --- was derailed by COMPAT3's ZP scratch (zp_tmp0 = $4F after
; --- a 10-record read, etc.).
; --- Layer-5 fix (2026-11-24): the hot block that layer 3 parked
; --- at ZP $80-$BA (zp_tmp*, zp_cdb, the scsi_cmd state, the
; --- cdbios locals) moved again, to WRAM $2648-$2682 (offsets
; --- preserved). The zpprobe measurement (notes_layer5) shows
; --- the genuine preserves program ZP $80-$D7 across every CD
; --- call; $80-$BA is program territory -- the p003 test program
; --- keeps its variables at $8E-$AB, and layer 3's placement
; --- destroyed them on the first CD_READ (test_p003 case 8:
; --- the program lost its log/descriptor/counter state and
; --- control fell back to the shell).
; --- Layer-10 round-5 fix (2026-11-25, Lodoss C-L5): the hot
; --- block moved again, to WRAM $2490-$24CF (internal offsets
; --- preserved exactly). $2646-$26AB is Record of Lodoss War's
; --- script-state arrays (running ptrs $2646+x / $2668+x, step
; --- lengths $268A+x): AD_TRANS's bookkeeping writes to zp_cdb
; --- ($264C) and zp_alba ($266E) rewrote the waiting task 6's
; --- script pointer mid-transition and derailed the segment
; --- A->B choreography. The genuine keeps its AD transfer
; --- state in its $22xx work area and writes none of
; --- $2646-$26AB; no BIOS service may write that range as
; --- bookkeeping. The new span is the unallocated middle of
; --- the player page: $2489-$248F below it stays free (inside
; --- item4test's FDOUT snapshot window $246C-$248F) and
; --- $24D0-$251F above it is free up to PL_TLENBCD at $2520.
; --- Kept in zero page, with
; --- measured reasons: zp_bytes $BB-$BD (the IPL data loop lost
; --- bytes at buffer boundaries when it lived in WRAM, layer 3),
; --- zp_vdcval $BE (ZP speed; p005 GRAPHICS tick timing), and
; --- the four pointer cells that need (zp) indirect addressing
; --- at $D0-$D7; the ad_* state cells remain at $E3-$F6 (BIOS-owned
; --- state zone, as on the genuine). $F5 (irq_m) and $F8-$FF
; --- (argument shadows) are the public interface and never move.
; --- (C-D4 update, layer 10 round 2: the preservation range
; --- turned out to cover ALL calls, not just CD calls, so the
; --- cells above moved again -- zp_bytes to WRAM $24EA (the
; --- layer-3 IPL concern does not apply: the IPL loader's
; --- per-byte loop runs on zp_str_* / (zp_dst),y, and zp_bytes
; --- is only its per-chunk counter), zp_vdcval to $D8, the
; --- pointer cells to $DA-$DE and the BM borrows to $E0; see
; --- the equates below and the C-D4 block further down.)
zp_tmp0         = $2490
zp_tmp1         = $2491
zp_ex_a         = $2251           ; EX/MA trampoline: saved A input
zp_ex_idx       = $2252           ; EX/MA trampoline: slot number
zp_ex_x         = $2253           ; EX/MA dispatch: saved X input
zp_ex_y         = $2254           ; EX/MA dispatch: saved Y input
                                ; Were $276B-$276E (layer-3 band)
                                ; until C-D5 (layer 10, Dracula X
                                ; round 3): the trampoline latches
                                ; A/idx/X/Y there on EVERY
                                ; EX-family call (JOYSNS polls
                                ; included), and $276B-$276E is
                                ; inside Dracula X's object-state
                                ; array ($2750 row, slots
                                ; $1B-$1E): a poll during a handler
                                ; pass left the record
                                ; ($6C,$21,$FF,$00) standing in
                                ; the array, the game's object
                                ; scan dispatched the value-$6C
                                ; handler for slot $1B, and the
                                ; pass never returned (spec_drac
                                ; C-D5). $2251-$2254 is a free gap
                                ; in the $22xx system area, beside
                                ; BM_RES/BM_CARRYF ($22AA/$22AB),
                                ; which the same tail returns
                                ; from. Absolute->absolute: no
                                ; encoding size changes.
zp_ex_ret       = $DA           ; EX/MA trampoline: return ptr (2).
                                ; Was ZP $D2 until C-D4 (layer 10,
                                ; Dracula X round 2): the genuine
                                ; preserves ZP $80-$D7 across ALL
                                ; calls, and the trampoline writes
                                ; this cell on every EX-family call
                                ; (JOYSNS polls included). $DA is
                                ; above the C-D4 range; the
                                ; zp_ex_sav stash now preserves the
                                ; caller's $DA/$DB instead.
EX_XRES         = $24DD         ; EX BIOS exit: result X (bank 2).
                                ; Was ZP $3D until the C-D1
                                ; relocation (layer 10, Dracula X):
                                ; the trampoline result cells are
                                ; written on every EX-family call
                                ; and ZP $00-$7F is the caller's.
EX_YRES         = $24DC         ; EX BIOS exit: result Y (bank 2)
                                ; (was ZP $3C, same move)
zp_tmp2         = $2492
zp_vdcval       = $00D8           ; 16-bit value for vdc_write (2).
                                ; MUST stay in zero page: at any
                                ; WRAM address the p005 GRAPHICS
                                ; pause check fails (graphics tick
                                ; timing race; see notes_layer3).
                                ; Was $BE until C-D4 (layer 10,
                                ; Dracula X round 2): $80-$D7 is
                                ; program territory across all
                                ; calls; $D8 is still zero page
                                ; (same access timing) and above
                                ; the C-D4 range.
zp_ptr          = $D0           ; general pointer (2 bytes).
                                ; Slot-path use is only the
                                ; EX_GETFNT glue's copy loop,
                                ; which now saves/restores it
                                ; (GF_PTR_SAV, C-D4); the other
                                ; users are the BIOS shell / boot
                                ; era (title screen, print_str,
                                ; IPL error screen, player).
zp_cdb          = $2494           ; SCSI CDB, 10 bytes
zp_dataptr      = $DC           ; SCSI data-in pointer (2 bytes).
                                ; Was ZP $D4 until C-D4. $DC/$DD is
                                ; above the $80-$D7 preservation
                                ; range, but it aliases GRP_BITPAT
                                ; through the $2000 page (ZP $xx
                                ; IS WRAM $20xx), so every use is
                                ; wrapped: the cd_stat stub and
                                ; the bank-3 relay stubs save /
                                ; restore it (DP_SAV), and the
                                ; IPL handover re-zeroes it, so
                                ; vi_bitpat is preserved across
                                ; every call and at boot handover.
                                ; (An interim fix-up placement at
                                ; $CA satisfied the net-effect
                                ; probes but put transient writes
                                ; inside the census range; the
                                ; spec's C-D4 evidence is the
                                ; writer census itself, so the
                                ; cell lives above the range with
                                ; total wrap coverage instead.)
                                ; Borrowed as bm_dp during BM
                                ; bodies (see the C-D4 block).
zp_datalen      = $249E           ; SCSI data-in length (2 bytes)
zp_ex_sav       = $24A0           ; EX/MA trampoline: caller's
                                ; $DA/$DB stashed here while
                                ; zp_ex_ret borrows them (layer-5:
                                ; test programs keep live state at
                                ; $D2/$D3 across EX calls -- the
                                ; genuine preserves $C0-$E2; the
                                ; borrow moved to $DA/$DB at C-D4,
                                ; the stash discipline is unchanged).
                                ; Was zp_waitcnt until wait1800
                                ; moved its timeout into X/Y.
zp_waitmask     = $24A2
zp_waitexpect   = $24A3
zp_waiterr      = $24A4
zp_scsi_stat    = $24A5
zp_scsi_msg     = $24A6
zp_bank         = $24A7           ; bank counter for RAM clearing
zp_pad_cur      = $278A           ; pad buttons, active high (this frame)
zp_pad_prev     = $278B           ; pad buttons, previous frame
zp_pad_dir      = $278C           ; pad directions, active high
zp_textcol      = $278D
zp_textrow      = $278E
zp_disc         = $278F
zp_tracks       = $2790
zp_batpos       = $2791           ; BAT cursor word address (2 bytes)
zp_pal          = $2793           ; current text palette (0-15)
BM_RES          = $22AA         ; BM/EX BIOS exit: result A
                                ; (bank 2).  Was ZP $3F/$3E
                                ; until item 3.5: an aliased
                                ; BM_READ/FILES copy lands
                                ; file data on $203E/$203F
                                ; and the exit stash then
                                ; overwrote the last two
                                ; transferred bytes.
BM_CARRYF       = $22AB         ; BM/EX BIOS exit: result
                                ; carry bit0
FN_STAGE        = $2B80         ; EX_GETFNT staged 32-byte cell
                                ; (fnbios bank 2 -> bank-0 glue copy)
zp_dirbuf       = $24A8           ; Get Dir Info reply buffer (4 bytes)
zp_err          = $24AC           ; SCSI issuer error code
zp_retry        = $27A9           ; disc_check readiness retry counter
zp_data_lba     = $27AA           ; first data track start LBA (3 bytes)
zp_data_found   = $27AD           ; nonzero once zp_data_lba is set
zp_lba          = $27B1           ; read6_stream: start LBA (3 bytes)
zp_count        = $27B4           ; read6_stream: record count
zp_dst          = $DE           ; read6_stream: dest pointer (2
                                ; bytes). Was ZP $D6 until C-D4.
                                ; $DE/$DF is above the $80-$D7
                                ; preservation range, but it
                                ; aliases GRP_PADRS through the
                                ; $2000 page (ZP $xx IS WRAM
                                ; $20xx): the unwrapped IPL stream
                                ; load once left its end pointer
                                ; standing in vi_padrs ($A000),
                                ; and the first GRP POINT after
                                ; boot read it and returned carry
                                ; clear (measured, item4 R6/R7
                                ; arms). The fix-up completed the
                                ; wrap coverage -- cd_read_core's
                                ; zp_str_sav save/restore, cd_
                                ; seek's DST_SAV wrap, the SUBQ /
                                ; DINFO copy brackets -- and the
                                ; IPL handover re-zeroes the cell,
                                ; so vi_padrs is preserved across
                                ; every call and at boot handover.
                                ; Also borrowed as bm_tp during
                                ; BM bodies (see the C-D4 block).
zp_bytes        = $24EA         ; read6_stream: bytes left (3
                                ; bytes). Was ZP $BB-$BD until
                                ; C-D4: a plain counter (lda/sta/
                                ; dec/asl/rol only, per-chunk
                                ; frequency -- the C-G4 per-byte
                                ; loop already runs on zp_str_*),
                                ; and the AD paths (AD_TRANS /
                                ; AD_CPLAY) and CD_SEEK set it
                                ; without cd_read_core's wrapper,
                                ; leaving it standing in what is
                                ; program territory. Now WRAM.
zp_dstmode      = $27BA           ; read6_stream: 0 fixed window, 1 IPL
                                ; load (informational since p009: the
                                ; stream is linear in both modes; the
                                ; same byte is cd_stream's unrelated
                                ; destination-mode in cdbios.s)
zp_iplmpr       = $27BB           ; IPL header MPR2..MPR6 (5 bytes)
zp_iplsta       = $27C0           ; IPL header load address (2 bytes)
zp_ipljmp       = $27C2           ; IPL header entry address (2 bytes)
zp_blk          = $27C4           ; IPL header load record no. (3 bytes)
zp_bln          = $27C7           ; IPL header load record count
zp_acc          = $24B0           ; msf_to_lba accumulator (3 bytes)
zp_msf          = $24B3           ; msf_to_lba input M,S,F (3 bytes)
zp_alba         = $24B6           ; cdbios: absolute LBA (3 bytes)
zp_off          = $24B9           ; cdbios: record offset (3 bytes)
zp_rcount       = $24BC           ; cdbios: records left to read
zp_execjmp      = $27D5           ; cdbios: CD_EXEC jump target (2)
zp_subqbuf      = $24BE           ; cdbios: $DD reply buffer (10 bytes)
zp_saved_mpr    = $27D7           ; cdbios: saved MPR value (TMA).
                                ; Layer 10 round 2 (Gate C-G2'):
                                ; was $2680, inside the layer-5 hot
                                ; block -- but $2680 is Gate of
                                ; Thunder's attract scene-index cell:
                                ; this store (a bank value, e.g. $76)
                                ; overwrote the game's index inside
                                ; its load-phase CD call, and the
                                ; PLAY #3 stub then read index
                                ; $76+$0A=$80 instead of $00+$0A=$0A.
                                ; Moved into the free tail of the
                                ; layer-3 private band ($27D7-$27E3:
                                ; no equates, no player cells, no
                                ; literal/indexed references;
                                ; neighbours zp_execjmp $27D5,
                                ; WV_PRIV $27E4, PSG_SEQ $27E7).
zp_winbase      = $24C9           ; cdbios: MPR window base page
zp_errcode      = $24CA           ; cdbios: SUB ERROR CODE to return
zp_str_chunk    = $27D8           ; stream chunk size, 16-bit
                                  ; (lo + hi in {0,1}: 1..256);
                                  ; cd_stream / read6_stream
                                  ; chunked data phase (layer 10
                                  ; round 4, C-G4). In the free
                                  ; tail of the layer-3 private
                                  ; band beside zp_saved_mpr
                                  ; ($27D8-$27DC: no equates, no
                                  ; player cells, no references).
zp_str_pre      = $27DA           ; stream chunk Y preload /
                                  ; mode-2 tail-parity flag
zp_str_rem      = $27DB           ; stream chunk scratch
                                  ; (mode-1 window remainder,
                                  ; mode-2 pair count, mode-3
                                  ; store/discard split)
zp_str_aux      = $27DC           ; stream chunk scratch, 16-bit
zp_relay_a      = $27DE           ; A save for the cd_stat bank-2 relay
zp_relay_mpr    = $27DF           ; caller's MPR6 save for the bank-2
                                ; cluster relays (cd_subq_b2 & co)
                                  ; (mode-2 remaining count,
                                  ; mode-3 discard count)
zp_str_sav      = $24CB           ; cd_stream: program's zp_bytes
                                ; ($24CB-$24CF, 5 bytes)
                                  ; (3) + zp_dst (2) saved across
                                  ; the transfer (layer-5 item 3:
                                  ; the genuine preserves ALL of
                                  ; the program's ZP across a
                                  ; CD_READ; the stream's counter
                                  ; and pointer then lived in ZP
                                  ; $BB-$BD / $D6-$D7, so cd_stream
                                  ; saves and restores them. At
                                  ; C-D4 the cells themselves moved
                                  ; (zp_bytes to WRAM $24EA, zp_dst
                                  ; to $DE); the save/restore here
                                  ; is unchanged and now covers the
                                  ; $DE/$DF borrow window.)
; NOTE (p004 fix): the adbIOS ZP block lives at $E3-$F6, NOT
; in the $80-$9F range: the p003 test program (cdtest.s)
; owns $8E-$A0 as its variable page, and an earlier $80-$95
; placement made ack_pulse read cdtest's live $95 variable
; as the IRQ-mask shadow while the IRQ2 handler clobbered
; its $8F -- a deterministic test_p003_vram regression.
; $E3+ is free in every suite program (adtest ends at $E2).
zp_ad_ptr       = $E3           ; adbIOS: CPU-side stream pointer (2)
zp_ad_cnt       = $E5           ; adbIOS: stream bytes left (2)
zp_ad_start     = $E7           ; adbIOS: saved play start addr (2)
zp_ad_len       = $E9           ; adbIOS: saved play length (2)
zp_ad_rate      = $EB           ; adbIOS: saved play rate
zp_ad_state     = $EC           ; adbIOS: deferred $227A store flag
                                ; (was the AD_STAT X state byte;
                                ; AD_STAT now reads the $1803 HALF
                                ; latch live, p004)
zp_ad_rpt       = $ED           ; adbIOS: current play repeats
zp_ad_cp        = $EE           ; adbIOS: AD_CPLAY stream active
zp_ad_mask      = $EF           ; adbIOS: MPR TAM mask for streams
zp_ad_saved     = $F0           ; adbIOS: saved MPR (READ MPR form)
zp_ad_phase     = $F1           ; adbIOS: VRAM byte phase / scratch
zp_ad_irq3      = $F2           ; adbIOS: IRQ2 handler $1803 copy
zp_ad_rem       = $F3           ; adbIOS: CPLAY records left (3)
zp_imask        = $F6           ; shadow of $1802 bits 0-6 (the
                                ; ADPCM IRQ mask): the SCSI ACK
                                ; pulse preserves these bits, so
                                ; an unmask survives CD traffic
                                ; (the IPL opening's repeat play
                                ; depends on it, p004)

; --- EX BIOS public work variables (Hu7 equ list; p009) ------------
EX_CRLM         = $20F3         ; CR (reg5) low-byte shadow
EX_IRQM         = $20F5         ; IRQ mask work byte
EX_REGBOX       = $20F7         ; last VDC register no. selected
EX_USRVEC       = $2200         ; user vectors, 9 words ($2200-$2211)
EX_SATADR       = $2214         ; SATB VRAM address (word)
EX_SPRPTR       = $2216         ; sprite entry pointer (byte)
EX_SPRY         = $2217         ; SPRPUT fields: y,x,n,a (4 words)
EX_COLORCMD     = $221F         ; COLORC command (0 idle, 1 read,
                                ;   2 write; cleared on completion)
EX_BGCPTR       = $2220         ; COLORC BG buffer pointer (word)
EX_BGCLEN       = $2222         ; COLORC BG palette count (byte)
EX_SPRCPTR      = $2223         ; COLORC SPR buffer pointer (word)
EX_SPRCLEN      = $2225         ; COLORC SPR palette count (byte)
EX_JOYENA       = $2227         ; joypad enable mask (boot $1F)
EX_JOY          = $2228         ; current pad bytes, 5 slots
EX_JOYTRG       = $222D         ; trigger (edge) bytes, 5 slots
EX_JOYOLD       = $2232         ; held (cur & prev) bytes, 5 slots
EX_SRESET       = $2284         ; SETVEC(6) soft-reset vector cell
                                ;   (measured on the genuine, p009)
EX_DCRW         = $2243         ; DCR (reg15) work value
EX_RNDSEED      = $2249         ; RND state: seed / rndh / rndm
EX_RNDH         = $224A
EX_RNDM         = $224B
; --- COMPAT3-private EX state (work RAM, past the public area) -----
EX_MWR          = $2290         ; MWR (reg9) shadow, boot $00
EX_VSFLAG       = $2291         ; vsync flag (handler sets on VD)
EX_CRDIRTY      = $2292         ; deferred CR apply pending
EX_VCE          = $2293         ; VCE_CTL shadow
EX_CRHI         = $2294         ; CR (reg5) high-byte shadow
EX_SCRATCH      = $2295         ; EX BIOS scratch (4 bytes; sign
                                ;   cells and the SQRT loop state
                                ;   live here because the bank-2
                                ;   multiply helper owns the shared
                                ;   scratch block at $24D8-$24DB)

; --- C-D1 relocation (layer 10, Dracula X; spec_drac.md C-D1) ---
; The shared bank-2 scratch block that lived in ZP $30-$3B
; (EX/MA xs_*, EX_GETFNT fn_*, GRP_BIOS L_*/GP_PTR, PSG ps_* --
; one aliased block, calls never nest) now lives in WRAM at
; $24D0-$24DB with every offset and alias preserved, beside
; EX_YRES/EX_XRES ($24DC/$24DD; fn_mpr5 keeps its $3D offset as
; $24DD, aliasing EX_XRES exactly as before) and the CD_PLAY
; call-state cells zp_pl_* ($24E0-$24E2, were ZP $07-$09).
; $24D0-$251F is the free span above the C-L5 hot block.
; Three families dereference through a (zp),y pointer, which
; cannot encode a WRAM operand on HuC6280; each gets a
; dedicated borrowed ZP pointer cell in the free $C0-$CF zone
; (outside the C-D1 range $00-$7F), saved/restored around the
; owning call so the net effect on $C0-$CF is also zero (the
; zp_ex_ret precedent):
ZP_PTR_CC       = $C0           ; COLORC copy pointer (2);
                                ;   saved/restored in exb_colorc_go
ZP_PTR_FN       = $E0           ; EX_GETFNT font pointer (2);
                                ;   saved/restored in fnb_getfnt.
                                ;   Was $C2 until C-D5 round 3:
                                ;   $C2 is inside the C-D4 census
                                ;   range ($80-$D7), and once
                                ;   Dracula X reached its title
                                ;   era the run's 66 GETFNT calls
                                ;   showed transient writes there
                                ;   (the genuine's census is zero
                                ;   even transiently). $E0 is
                                ;   BM_EP's cell: BM and GETFNT
                                ;   are both top-level slot
                                ;   bodies and never overlap, and
                                ;   each side save/restores it
                                ;   (BM_SAV / FN_PTR_SAV), so the
                                ;   alias composes like bm_dp /
                                ;   bm_tp do.
ZP_PTR_GP       = $C4           ; GRP_BIOS glyph pointer (2);
                                ;   saved/restored in grp_entry
CC_PTR_SAV      = $24E4         ; ZP_PTR_CC saved bytes (2)
FN_PTR_SAV      = $24E6         ; ZP_PTR_FN saved bytes (2)
GP_PTR_SAV      = $24E8         ; ZP_PTR_GP saved bytes (2)

; --- C-D4 high zero page preservation (layer 10, Dracula X ---
; --- round 2; spec_drac.md C-D4) -----------------------------
; The genuine preserves ZP $80-$D7 across ALL jump-table
; calls, BM calls included (writer census over a full
; Dracula X run: zero ROM-space writes in $80-$D7 across
; 3,587 entries). COMPAT3's remaining occupants of the range
; were moved above it, into the free ZP span $D8-$E2 (the
; ad_* state zone starts at $E3), or into WRAM:
;   zp_vdcval $BE -> $D8, zp_ex_ret $D2 -> $DA,
;   zp_dataptr $D4 -> $DC, zp_dst $D6 -> $DE (see above;
;   both alias GRP state through the $2000 page, so the
;   fix-up wrapped every use and re-zeroes both at the IPL
;   handover -- an interim placement inside the range at
;   $C8/$CA failed the census standard, which counts
;   transient writes, and was reverted);
;   zp_bytes $BB-$BD -> WRAM $24EA (see above).
; The BM block ($80-$8D since item 3.5) is the last family:
; its plain counters now live in WRAM (BM_LEN/BM_N/BM_CK/
; BM_CNT), and its three (zp),y pointers are borrows, saved
; by bmb_enter and restored by bmb_ret (save area BM_SAV):
;   bm_ep -> BM_EP ($E0, dedicated borrow)
;   bm_dp -> aliases zp_dataptr ($DC) during BM bodies
;   bm_tp -> aliases zp_dst ($DE) during BM bodies
; zp_dataptr / zp_dst are dead inside BM calls (no SCSI or
; stream work there), and BM calls never nest inside an EX
; trampoline window, a stream, or each other, so the
; aliasing windows cannot overlap. GF_PTR_SAV is the
; EX_GETFNT glue's save cell for zp_ptr ($D0), whose only
; slot-path use is that glue's copy loop.
BM_LEN          = $24ED         ; BM: current entry length (2)
BM_N            = $24EF         ; BM: 16-bit work count (2)
BM_CK           = $24F1         ; BM: checksum accumulator (2)
BM_CNT          = $24F3         ; BM: FILES counter / scratch (2)
BM_SAV          = $24F5         ; BM: borrow saves: zp_dataptr /
                                ; zp_dst / BM_EP (6)
GF_PTR_SAV      = $24FB         ; EX_GETFNT glue: copy-pointer
                                ; save (2); held zp_ptr until
                                ; C-D5 round 3, now zp_dataptr
DP_SAV          = $24FD         ; C-D4 fix-up: zp_dataptr saves
                                ; for the cd_stat stub and the
                                ; bank-3 relay stubs (2)
DST_SAV         = $24FF         ; C-D4 fix-up: zp_dst save for
                                ; cd_seek (2)
BM_EP           = $E0           ; BM: entry / walk pointer borrow
                                ; (2); saved/restored in bmb_enter
                                ; / bmb_ret like the $DC/$DE aliases

; EX_GETVER entry point through the jump table ($E000 + 3 * $1E).
BIOS_GETVER     = $E05A
; Boot state values stored in MB_STATE.
STATE_BOOT      = 0
STATE_TITLE     = 1
STATE_CHECK     = 2
STATE_PLAYER_NODISC = 3
STATE_PLAYER_AUDIO  = 4
STATE_PLAYER_DATA   = 5
STATE_BOOT_ERROR    = 6         ; IPL boot failed (LOAD ERROR equiv.)
STATE_BOOTING       = 7         ; IPL boot in progress / jumped
; Disc classes stored in MB_DISC / zp_disc.
DISC_NONE       = 0
DISC_AUDIO      = 1
DISC_DATA       = 2
EX_PADTMP       = $2299         ; IRQ1 handler pad scratch (3)
EX_PADTMP2      = $229A
EX_PADSCR       = $229B

; --- AD stream state ($4D/$4E; ws005 item 2, measured) -------------
; The state byte, poll counter and parameter block live at the
; genuine's own work addresses (observable through the calls):
ST_COUNT        = $22C1         ; $4E state-2 counter (0..6)
ST_STATE        = $22C2         ; stream state (0 idle, 1 armed,
                                ;   2 phase seq, 3 transfer,
                                ;   4 drain)
ST_BX           = $22C3         ; stored BX (2 bytes)
ST_REC          = $224D         ; stored record addr CL,CH,DL (3)
ST_CNTB         = $2250         ; stored count AL
ST_POISON       = $229C         ; COMPAT3-private: armed while a
                                ;   previous stream was unfinished
ST_FSTAMP       = $229D         ; COMPAT3-private: EX_RNDSEED at
                                ;   state-4 entry (drain timing)

; --- Item 4: PSG_BIOS ($48) / PSG_DRIVE ($4B) / KEY_BIOS ($4A) --
; --- (two-side clean room, implementation side; contracts from
; --- item4_spec.md + public docs). Observable driver bytes live
; --- at the spec's own addresses in $22C0-$2307 and NOTHING
; --- else is written there: PSG_ON / PSG_PLAY / PSG_FDOUT /
; --- the stop family are pinned to change no work-RAM byte
; --- beyond their own stores (spec R3), so all COMPAT3-private
; --- bookkeeping lives in the PSG_SEQ block ($27E7), outside
; --- the documented work area.
PSG_TRACKB      = $22D0         ; PSG_TRACK store (spec 2.2)
PSG_WAVEA       = $22D2         ; PSG_WAVE store (spec 2.2 R1)
PSG_TEMPOB      = $22D4         ; tempo byte; bit 7 = drive flag
PSG_ENVBA       = $22D5         ; PSG_ENV store (spec 2.2 R1)
PSG_FMBA        = $22D7         ; PSG_FM store (spec 2.2 R1)
PSG_PEBA        = $22D9         ; PSG_PE store (spec 2.2 R1)
PSG_PCBA        = $22DB         ; PSG_PC store (spec 2.2 R1)
PSG_DCNTA       = $22DD         ; PSG_DCNT store (spec 2.2 R1)
PSG_DESTAT      = $22DE         ; driver status byte (INIT $C0)
PSG_INITMODE    = $22DF         ; PSG_INIT AL mode byte (spec 2.3)
PSG_ENDF        = $22E0         ; $FF once settled (spec 3)
PSG_SONGPTR     = $22E1         ; (R3) PSG_PLAY's stored song
                                ;   header pointer (word);
                                ;   bit 7 of the low byte is
                                ;   the started flag (spec 2.5)
PSG_BANKB       = $22EB         ; PSG_BANK store (verbatim)
PSG_FDOUTA      = $2488         ; PSG_FDOUT store (spec 2.2 R1)
PSG_SEQ         = $27E7         ; COMPAT3-private bookkeeping
                                ;   block (fields in psgbios.s);
                                ;   zeroed by PSG_INIT. Layer 7:
                                ;   was $2850 -- inside Lodoss's
                                ;   scheduler-table region
                                ;   ($2844-$2954); PSG_INIT's
                                ;   128-byte clear of the old
                                ;   block zeroed the game's task
                                ;   owners/SPs and the dispatched
                                ;   task resumed at $0000. Moved
                                ;   to $2688 in layer 7; layer 8
                                ;   measured that span is inside
                                ;   Lodoss's script-interpreter
                                ;   tables (running ptrs $2646+x /
                                ;   $2668+x, step lengths
                                ;   $268A+x): the game's PSG_INIT
                                ;   + PSG_PLAY at intro f~383
                                ;   zeroed the step lengths of
                                ;   script tasks 5-7 ($268F-
                                ;   $2691), the interpreters
                                ;   froze on a wait opcode, the
                                ;   segment-complete opcode was
                                ;   never reached and the loader
                                ;   never issued AD_TRANS #2.
                                ;   Now at $27E7, beside the
                                ;   layer-3 private band, below
                                ;   the $2800 test-prefill /
                                ;   program-scratch line and
                                ;   outside every measured game
                                ;   structure; only 4 fields are
                                ;   used, clear is 16 bytes.

; --- Item 4: GRP_BIOS ($49) driver state (spec 4: zero page
; --- $20DC-$20E5, work RAM $2616-$2648) -------------------------
GRP_BITPAT      = $20DC         ; vi_bitpat (public manual name)
GRP_PADRS       = $20DE         ; vi_padrs (2)
GRP_PORG        = $20E0         ; vi_porg
GRP_FTBACK      = $20E1         ; vi_ft_back (3)
GRP_STACKZP     = $20E4         ; vi_stack (2)
GRP_BASE        = $2616         ; graphic base word address (2)
GRP_FONTSEL     = $2618         ; current GFONT selection
GRP_GLYPHREC    = $2619         ; located glyph record (32 B);
                                ;   PUTFONT returns _BX = $2619
GRP_STACKP      = $2639         ; paint stack pointer (2)
GRP_STACKBASE   = $263B         ; paint stack base (2)
GRP_WIN         = $263D         ; GWINDOW store: x, y, w, h,
                                ;   colour bank (5 B, $263D-$2641)
GRP_STKDEF      = $2900         ; default paint stack area when
                                ;   GINIT _BX = 0 (COMPAT3-private)
