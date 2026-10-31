; ============================================================
; C64 HANGMAN  (v2)
; Single-file 6502 assembly game
;
; Assembler: ACME (tested with 0.96.4)
; Target:    Commodore 64 / 6510
; Load:      $0801, BASIC stub -> SYS 2061
;
; Build:
;   make        (acme -f cbm -o build/hangman.prg hangman.asm)
;   make xl     (adds -DXL=1: build/hangman-xl.prg)
; Run:
;   make run / make run-xl
;
; XL build: the word list is 5-bit packed (words_xl.asm) and runs
; on past $A000 into the RAM under BASIC ROM and on to $CFFF, so
; BASIC is banked out at startup. The game never calls BASIC.
;
; Sound: voices 1 and 2 play the title jingle and effects (key
; click, right/wrong letter, win, lose) from simple step tables;
; voice 3 stays the random number source.
;
; Everything is drawn straight into screen RAM ($0400) and
; colour RAM ($D800) using C64 screen codes, so the gallows,
; panel and title bar use real PETSCII graphics.
;
; NOTE ON TEXT: ACME's !scr turns lowercase source letters into
; screen codes $01-$1A, which display as UPPERCASE in the C64's
; default character set. That is why on-screen strings below are
; typed in lowercase. Uppercase in !scr gives graphics glyphs.
;
; Words are stored as plain ASCII caps ($41-$5A); that matches
; what GETIN returns for unshifted letter keys. A letter's screen
; code is its ASCII value minus $40.
; ============================================================

!cpu 6510

!ifndef XL { XL = 0 }

* = $0801

; 10 SYS2061
!byte $0b,$08,$0a,$00,$9e,$32,$30,$36,$31,$00,$00,$00

; ------------------------------------------------------------
; KERNAL / HARDWARE
; ------------------------------------------------------------

CHROUT   = $FFD2
GETIN    = $FFE4

SCREEN   = $0400
COLRAM   = $D800
BORDER   = $D020
BGCOL    = $D021
RASTER   = $D012
SID_FREQ1 = $D400           ; voice 1 frequency lo/hi (+2/+3 pulse width)
SID_PW1   = $D402
SID_CTRL1 = $D404           ; voice 1 control (waveform | gate)
SID_AD1   = $D405
SID_SR1   = $D406
SID_PW2   = $D409           ; voice 2 = voice 1 + 7
SID_CTRL2 = $D40B
SID_AD2   = $D40C
SID_SR2   = $D40D
SID_FREQ3 = $D40E           ; voice 3 frequency lo/hi
SID_CTRL3 = $D412           ; voice 3 control
SID_VOL   = $D418           ; volume; bit 7 mutes voice 3
SID_RAND  = $D41B           ; voice 3 oscillator output

; Voice 3 is the random number generator (noise, never gated, and
; muted in the mix), so music and effects use voices 1 and 2 only.
WAVE_TRI   = $10
WAVE_SAW   = $20
WAVE_PULSE = $40
KEYCOUNT = $C6              ; chars in keyboard buffer
SHFLAG   = $0291            ; bit7=1 locks SHIFT+C= charset swap
JIFFY    = $A2
BLNSW    = $CC              ; nonzero = KERNAL cursor blink disabled

; ------------------------------------------------------------
; ZERO PAGE  (free while BASIC isn't running)
; ------------------------------------------------------------

SRC  = $F7                  ; $F7/$F8 data pointer
CPTR = $F9                  ; $F9/$FA colour RAM pointer
SPTR = $FB                  ; $FB/$FC screen RAM pointer
SNG  = $FD                  ; $FD/$FE song / letter list pointer

; ------------------------------------------------------------
; COLOURS
; ------------------------------------------------------------

BLACK  = 0
WHITE  = 1
RED    = 2
CYAN   = 3
PURPLE = 4
GREEN  = 5
BLUE   = 6
YELLOW = 7
ORANGE = 8
BROWN  = 9
LRED   = 10
DGREY  = 11
GREY   = 12
LGREEN = 13
LBLUE  = 14
LGREY  = 15

REV    = $80                ; OR into a text colour = reverse video

; ------------------------------------------------------------
; SCREEN CODES (uppercase/graphics set)
; ------------------------------------------------------------

SC_SPACE  = $20
SC_SOLID  = $A0             ; reverse space = solid block
SC_HLINE  = $40             ; horizontal line
SC_VLINE  = $5D             ; vertical line
SC_DIAG_D = $4D             ; diagonal top-left -> bottom-right
SC_DIAG_U = $4E             ; diagonal bottom-left -> top-right
SC_BALL   = $51             ; filled circle (head)
SC_HEART  = $53
SC_CROSS  = $56             ; X  (dead head)
SC_BAR_LO = $64             ; thin bar along bottom of cell
SC_BAR_HI = $63             ; thin bar along top of cell
SC_CHECK  = $66             ; checkerboard
SC_TL     = $70             ; box corners
SC_TR     = $6E
SC_BL     = $6D
SC_BR     = $7D
SC_DOT    = $2E

; ------------------------------------------------------------
; GAME CONSTANTS / LAYOUT
; ------------------------------------------------------------

MAX_WRONG = 6

WORD_ROW   = 17
PROMPT_ROW = 21
MSG_ROW    = 19
SCORE_ROW  = 24

MISS_ROW  = 7
LIVES_ROW = 11
PANEL_COL = 23

PRESS_OFF = 20*40+9         ; title prompt (colour blink)
HEAD_OFF  = 6*40+10         ; where the head sits (row 6, col 10)

; ------------------------------------------------------------
; MACROS
; ------------------------------------------------------------

; One drawable cell: drawn once wrong_count >= stage,
; otherwise blanked. Stage 0 = always drawn.
!macro cell .stage, .row, .col, .chr, .color {
    !byte .stage
    !word .row*40+.col
    !byte .chr, .color
}

; Text header: screen offset + colour (OR REV for reverse)
!macro at .row, .col, .color {
    !word .row*40+.col
    !byte .color
}

; ============================================================
; ENTRY
; ============================================================

start:
!if XL {
    lda #$36                ; BASIC ROM out: words live under it
    sta $01
}
    lda #BLACK
    sta BGCOL
    lda #DGREY
    sta BORDER

    lda #142                ; uppercase/graphics charset
    jsr CHROUT
    lda #$80                ; lock SHIFT+C= so it can't switch
    sta SHFLAG
    lda #1                  ; KERNAL cursor blink off (it would
    sta BLNSW               ; flicker the top-left title cell)

    ; SID: wipe it, full volume with voice 3 muted
    ldx #$18
    lda #0
sid_clr:
    sta SID_FREQ1,x
    dex
    bpl sid_clr
    lda #$8F
    sta SID_VOL
    lda #$08                ; 50% pulse on voices 1 and 2
    sta SID_PW1+1
    sta SID_PW2+1
    ; Attack, decay and release share one rate on each voice.  The
    ; SID's envelope counter wraps (up to ~33 ms of silence) whenever
    ; it switches to a faster rate, which swallowed short notes.
    lda #$22                ; lead: 16 ms attack, 48 ms decay
    sta SID_AD1
    lda #$A2                ; sustain 10, 48 ms release
    sta SID_SR1
    lda #$22                ; bass: same rates, lower sustain
    sta SID_AD2
    lda #$82
    sta SID_SR2

    ; SID voice 3 as a noise generator for randomness
    lda #$FF
    sta SID_FREQ3
    sta SID_FREQ3+1
    lda #$80
    sta SID_CTRL3

    lda #$FF                ; no word picked yet
    sta last_word
    sta last_word+1

    jsr title_screen

; ============================================================
; NEW GAME
; ============================================================

new_game:
    jsr pick_word

    lda #0
    sta wrong_count
    sta reveal

    ldx #25
ng_clear:
    sta guessed,x
    dex
    bpl ng_clear

    jsr draw_static

; ============================================================
; MAIN LOOP
; ============================================================

game_loop:
    jsr draw_board

    jsr check_win
    bcc gl_not_won
    jmp game_won
gl_not_won:
    lda wrong_count
    cmp #MAX_WRONG
    bcc get_key
    jmp game_lost

get_key:
    inc rnd_seed            ; stirs while waiting for a key
    jsr GETIN
    beq get_key

    and #$7F                ; SHIFT+letter ($C1-$DA) -> $41-$5A
    cmp #'A'
    bcc get_key
    cmp #'Z'+1
    bcs get_key

    sta guess_char
    sec
    sbc #'A'
    tax

    lda guessed,x           ; already tried? ignore
    bne get_key
    lda #1
    sta guessed,x

    lda #<song_tick         ; key accepted
    ldx #>song_tick
    jsr play_song

    ; is the letter in the word?
    ldy #0
gk_search:
    cpy word_length
    beq gk_miss
    lda word_buf,y
    cmp guess_char
    beq gk_hit
    iny
    bne gk_search

gk_hit:
    jsr draw_board          ; show the letter before the chime
    lda #<song_right
    ldx #>song_right
    jsr play_song
    lda #0                  ; drop keys typed during the chime,
    sta KEYCOUNT            ; same as after the wrong buzz
    jmp game_loop

gk_miss:
    ldx wrong_count
    lda guess_char
    sta miss_list,x
    inc wrong_count
    jsr draw_board
    jsr flash_border
    jmp game_loop

; ============================================================
; PICK A RANDOM WORD -> word_buf / word_length
;
; words.asm holds WORD_COUNT words plus an index of every 32nd
; word, so we jump to the block and skip at most 31 words.
; The XL build does the same over 5-bit packed words.
; ============================================================

; PICK_MASK: WORD_COUNT-1 with every lower bit set, so a masked
; random number is below WORD_COUNT at least half the time.
PM0 = WORD_COUNT - 1
PM1 = PM0 | (PM0 >> 1)
PM2 = PM1 | (PM1 >> 2)
PM3 = PM2 | (PM2 >> 4)
PICK_MASK = PM3 | (PM3 >> 8)

pick_word:                  ; re-roll until in range: no modulo bias
    lda SID_RAND
    eor JIFFY
    eor RASTER
    eor rnd_seed
    and #<PICK_MASK
    sta pick_lo
    lda SID_RAND
    eor RASTER
    eor rnd_seed
    and #>PICK_MASK
    sta pick_hi

    cmp #>WORD_COUNT        ; pick >= WORD_COUNT? roll again
    bcc pw_range
    bne pick_word
    lda pick_lo
    cmp #<WORD_COUNT
    bcs pick_word

pw_range:                   ; no repeats back to back
    lda pick_lo
    cmp last_word
    bne pw_new
    lda pick_hi
    cmp last_word+1
    beq pick_word

pw_new:
    lda pick_lo
    sta last_word
    lda pick_hi
    sta last_word+1

    lda pick_lo             ; block = pick / 32
    lsr
    lsr
    lsr
    lsr
    lsr
    sta tmp_x
    lda pick_hi
    asl
    asl
    asl
    ora tmp_x
    tax
    lda widx_lo,x
    sta SRC
    lda widx_hi,x
    sta SRC+1

!if XL {
    lda #0                  ; blocks start on a fresh byte
    sta bit_cnt
    lda pick_lo             ; skip (pick mod 32) words
    and #31
    sta tmp_x
pw_skipw:
    lda tmp_x
    beq pw_unpack
pw_sk:
    jsr read_sym
    bne pw_sk
    dec tmp_x
    jmp pw_skipw

pw_unpack:
    lda #0
    sta word_length
pw_un:
    jsr read_sym
    beq pw_end
    ora #$40                ; 1-26 -> ASCII 'A'-'Z'
    ldy word_length
    sta word_buf,y
    inc word_length
    bne pw_un
pw_end:
    ldy word_length         ; A = 0: terminate
    sta word_buf,y
    rts

; Next 5-bit symbol from the bit stream at SRC, MSB first -> A
; (Z set when it is 0, the end of a word).
read_sym:
    lda #0
    sta bit_sym
    ldx #5
rs_bit:
    lda bit_cnt
    bne rs_have
    ldy #0
    lda (SRC),y
    sta bit_buf
    inc SRC
    bne rs_nc
    inc SRC+1
rs_nc:
    lda #8
    sta bit_cnt
rs_have:
    asl bit_buf
    rol bit_sym
    dec bit_cnt
    dex
    bne rs_bit
    lda bit_sym
    rts

} else {
    lda pick_lo             ; skip (pick mod 32) words
    and #31
    tax
pw_skipw:
    beq pw_copy
    ldy #0
pw_sk:
    lda (SRC),y
    iny
    cmp #0
    bne pw_sk
    tya
    clc
    adc SRC
    sta SRC
    bcc pw_nc
    inc SRC+1
pw_nc:
    dex
    jmp pw_skipw

pw_copy:
    ldy #0
pw_cp:
    lda (SRC),y
    sta word_buf,y
    beq pw_done
    iny
    bne pw_cp
pw_done:
    sty word_length
    rts
}

; ============================================================
; CHECK WIN  ->  carry set if every letter is guessed
; ============================================================

check_win:
    ldy #0
cw_loop:
    cpy word_length
    beq cw_yes
    lda word_buf,y
    sec
    sbc #'A'
    tax
    lda guessed,x
    beq cw_no
    iny
    bne cw_loop
cw_yes:
    sec
    rts
cw_no:
    clc
    rts

; ============================================================
; STATIC SCREEN  (once per game)
; ============================================================

draw_static:
    lda #147                ; clear screen
    jsr CHROUT

    ; --- title bar: thin rule, solid bar, thin rule ---
    lda #LBLUE
    sta cur_color
    lda #<(0*40)
    ldx #>(0*40)
    jsr set_pos
    lda #SC_BAR_LO
    ldx #40
    jsr fill

    lda #<(1*40)
    ldx #>(1*40)
    jsr set_pos
    lda #SC_SOLID
    ldx #40
    jsr fill

    lda #<(2*40)
    ldx #>(2*40)
    jsr set_pos
    lda #SC_BAR_HI
    ldx #40
    jsr fill

    lda #<txt_title
    ldx #>txt_title
    jsr print_at

    ; --- ground: grass + dirt ---
    lda #GREEN
    sta cur_color
    lda #<(14*40+1)
    ldx #>(14*40+1)
    jsr set_pos
    lda #SC_SOLID
    ldx #15
    jsr fill

    lda #BROWN
    sta cur_color
    lda #<(15*40+1)
    ldx #>(15*40+1)
    jsr set_pos
    lda #SC_CHECK
    ldx #15
    jsr fill

    ; --- side panel box ---
    lda #GREY
    sta cur_color
    lda #<(4*40+21)
    ldx #>(4*40+21)
    jsr set_pos
    lda #SC_HLINE
    ldx #15
    jsr fill
    lda #<(13*40+21)
    ldx #>(13*40+21)
    jsr set_pos
    lda #SC_HLINE
    ldx #15
    jsr fill

    lda #<panel_cells
    ldx #>panel_cells
    jsr draw_cells

    lda #<txt_misses
    ldx #>txt_misses
    jsr print_at
    lda #<txt_lives
    ldx #>txt_lives
    jsr print_at
    lda #<txt_prompt
    ldx #>txt_prompt
    jsr print_at

    jsr draw_score
    rts

; ============================================================
; DYNAMIC BOARD  (every turn)
; ============================================================

draw_board:
    lda #<gallows_cells
    ldx #>gallows_cells
    jsr draw_cells
    jsr draw_word
    jsr draw_misses
    jsr draw_lives
    rts

; ------------------------------------------------------------
; Word: guessed letters in white, blanks as underline bars.
; When reveal=1 (lost), missing letters show in red.
; ------------------------------------------------------------

draw_word:
    lda #<(WORD_ROW*40)
    ldx #>(WORD_ROW*40)
    jsr set_pos

    lda #20                 ; centre: 2 cells per letter
    sec
    sbc word_length
    tay
    ldx #0
dw_loop:
    cpx word_length
    beq dw_done

    lda word_buf,x
    sta tmp_chr
    stx tmp_x
    sec
    sbc #'A'
    tax
    lda guessed,x
    ldx tmp_x               ; NB: ldx sets Z from X...
    cmp #0                  ; ...so re-test the flag in A
    bne dw_known

    lda reveal
    bne dw_reveal
    lda #SC_BAR_LO
    sta (SPTR),y
    lda #LGREY
    sta (CPTR),y
    jmp dw_next

dw_reveal:
    lda tmp_chr
    sec
    sbc #$40
    sta (SPTR),y
    lda #RED
    sta (CPTR),y
    jmp dw_next

dw_known:
    lda tmp_chr
    sec
    sbc #$40
    sta (SPTR),y
    lda #WHITE
    sta (CPTR),y

dw_next:
    iny
    iny
    inx
    bne dw_loop
dw_done:
    rts

; ------------------------------------------------------------
; Missed letters: 6 slots, unused slots are grey dots
; ------------------------------------------------------------

draw_misses:
    lda #<(MISS_ROW*40+PANEL_COL)
    ldx #>(MISS_ROW*40+PANEL_COL)
    jsr set_pos
    ldx #0
    ldy #0
dm_loop:
    cpx wrong_count
    bcs dm_dot
    lda miss_list,x
    sec
    sbc #$40
    sta (SPTR),y
    lda #LRED
    sta (CPTR),y
    jmp dm_next
dm_dot:
    lda #SC_DOT
    sta (SPTR),y
    lda #DGREY
    sta (CPTR),y
dm_next:
    iny
    iny
    inx
    cpx #MAX_WRONG
    bne dm_loop
    rts

; ------------------------------------------------------------
; Lives: red hearts left, dark grey hearts lost
; ------------------------------------------------------------

draw_lives:
    lda #<(LIVES_ROW*40+PANEL_COL)
    ldx #>(LIVES_ROW*40+PANEL_COL)
    jsr set_pos
    lda #MAX_WRONG
    sec
    sbc wrong_count
    sta tmp_x               ; lives remaining
    ldx #0
    ldy #0
dl_loop:
    lda #SC_HEART
    sta (SPTR),y
    lda #RED
    cpx tmp_x
    bcc dl_col
    lda #DGREY
dl_col:
    sta (CPTR),y
    iny
    iny
    inx
    cpx #MAX_WRONG
    bne dl_loop
    rts

; ------------------------------------------------------------
; Score line: WINS nn   LOSSES nn  (BCD counters)
; ------------------------------------------------------------

draw_score:
    lda #<txt_score
    ldx #>txt_score
    jsr print_at

    lda #<(SCORE_ROW*40+15)
    ldx #>(SCORE_ROW*40+15)
    jsr set_pos
    lda wins
    jsr put_bcd

    lda #<(SCORE_ROW*40+30)
    ldx #>(SCORE_ROW*40+30)
    jsr set_pos
    lda losses
    jsr put_bcd
    rts

; A = BCD byte -> two digits at (SPTR), yellow
put_bcd:
    pha
    lsr
    lsr
    lsr
    lsr
    ora #$30                ; screen code for '0'
    ldy #0
    sta (SPTR),y
    lda #YELLOW
    sta (CPTR),y
    pla
    and #$0F
    ora #$30
    iny
    sta (SPTR),y
    lda #YELLOW
    sta (CPTR),y
    rts

; ============================================================
; WIN / LOSE
; ============================================================

game_won:
    sei                     ; IRQ must not run with D set
    sed
    lda wins
    clc
    adc #1
    bcs gw_max              ; stop at 99
    sta wins
gw_max:
    cld
    cli

    lda #<txt_win
    ldx #>txt_win
    jsr print_at
    lda #<song_win
    ldx #>song_win
    jmp end_round

game_lost:
    sei
    sed
    lda losses
    clc
    adc #1
    bcs gl_max              ; stop at 99
    sta losses
gl_max:
    cld
    cli

    lda #1
    sta reveal
    jsr draw_word

    ; dead man's head
    lda #<HEAD_OFF
    ldx #>HEAD_OFF
    jsr set_pos
    ldy #0
    lda #SC_CROSS
    sta (SPTR),y
    lda #RED
    sta (CPTR),y

    lda #<txt_lose
    ldx #>txt_lose
    jsr print_at
    lda #<song_lose
    ldx #>song_lose

; A/X = jingle to play once the screen is up
end_round:
    sta end_sng
    stx end_sng+1
    jsr draw_score

    lda #<(PROMPT_ROW*40)
    ldx #>(PROMPT_ROW*40)
    jsr set_pos
    lda #SC_SPACE
    ldx #40
    jsr fill
    lda #<txt_again
    ldx #>txt_again
    jsr print_at

    lda end_sng
    ldx end_sng+1
    jsr play_song
    lda #0                  ; ignore keys mashed during the jingle
    sta KEYCOUNT            ; flush keyboard buffer
er_wait:
    inc rnd_seed
    jsr GETIN
    beq er_wait
    jmp new_game

; ============================================================
; EFFECTS
; ============================================================

flash_border:
    lda #RED
    sta BORDER
    lda #<song_wrong
    ldx #>song_wrong
    jsr play_song
    lda #DGREY
    sta BORDER
    lda #0
    sta KEYCOUNT            ; drop keys typed during the flash
    rts

; ============================================================
; TITLE SCREEN
; ============================================================

title_screen:
    lda #147
    jsr CHROUT

    lda #LBLUE
    sta cur_color
    lda #<(1*40)
    ldx #>(1*40)
    jsr set_pos
    lda #SC_HLINE
    ldx #40
    jsr fill
    lda #<(23*40)
    ldx #>(23*40)
    jsr set_pos
    lda #SC_HLINE
    ldx #40
    jsr fill

    lda #<(3*40+8)          ; HANG
    sta big_off
    lda #>(3*40+8)
    sta big_off+1
    lda #<big_hang
    ldx #>big_hang
    jsr draw_big

    lda #<(9*40+11)         ; MAN
    sta big_off
    lda #>(9*40+11)
    sta big_off+1
    lda #<big_man
    ldx #>big_man
    jsr draw_big

    lda #<txt_sub1
    ldx #>txt_sub1
    jsr print_at
    lda #<txt_sub2
    ldx #>txt_sub2
    jsr print_at
    lda #<txt_count
    ldx #>txt_count
    jsr print_at
    lda #<txt_press
    ldx #>txt_press
    jsr print_at
    lda #<txt_author
    ldx #>txt_author
    jsr print_at

    lda #0
    sta KEYCOUNT
    lda #1                  ; any key cuts the jingle short
    sta song_skip
    lda #<song_title
    ldx #>song_title
    jsr play_song
    lda #0
    sta song_skip

tl_wait:
    inc rnd_seed
    lda JIFFY               ; blink the prompt
    and #$20
    beq tl_on
    lda #DGREY
    bne tl_col
tl_on:
    lda #YELLOW
tl_col:
    ldy #20
tl_cl:
    sta COLRAM+PRESS_OFF,y
    dey
    bpl tl_cl
    jsr GETIN
    beq tl_wait
    rts

; Big 5x5 block letters.  A/X = list of letter numbers ($FF ends),
; big_off = screen offset of the top-left cell.  Colour comes from
; big_pal, one entry per row.
draw_big:
    sta SNG
    stx SNG+1
    lda #0
    sta big_row
db_row:
    ldx big_row
    lda big_pal,x
    sta cur_color
    lda big_off
    ldx big_off+1
    jsr set_pos
    ldx #0                  ; position in letter list
    ldy #0                  ; screen column
db_letter:
    stx big_ix
    sty big_col
    ldy big_ix
    lda (SNG),y             ; (zp),y only: fetch via Y, then restore it
    ldy big_col
    cmp #$FF
    beq db_rowdone
    sta big_bits            ; letter * 5 + row -> font byte
    asl
    asl
    clc
    adc big_bits
    clc
    adc big_row
    tax
    lda big_font,x
    asl                     ; park the 5 bits in the top of the byte
    asl
    asl
    sta big_bits
    ldx #5
db_col:
    asl big_bits
    bcc db_blank
    lda #SC_SOLID
    sta (SPTR),y
    lda cur_color
    sta (CPTR),y
db_blank:
    iny
    dex
    bne db_col
    iny                     ; gap between letters
    ldx big_ix
    inx
    jmp db_letter
db_rowdone:
    lda big_off
    clc
    adc #40
    sta big_off
    bcc db_nc
    inc big_off+1
db_nc:
    inc big_row
    lda big_row
    cmp #5
    bne db_row
    rts

; ============================================================
; SOUND
;
; A song is: !byte wave1, wave2, then steps of (jiffies, note1,
; note2), ended by a 0 duration.  Voice 1 and 2 play note1/note2
; (0 = rest).  Each step is gated for all but its last jiffy so
; repeated notes re-trigger.  Durations must be 2 or more.
; Plays blocking; with song_skip set a keypress ends it early.
; ============================================================

play_song:
    sta SNG
    stx SNG+1
    lda #1                  ; start on a jiffy edge so every step
    jsr wait_jiff           ; lasts exactly its duration
    bcs ps_quit
    ldy #0
    lda (SNG),y
    sta ps_w1
    iny
    lda (SNG),y
    sta ps_w2
    iny
    sty ps_idx
ps_step:
    ldy ps_idx
    lda (SNG),y
    beq ps_done
    sta ps_dur
    iny
    lda (SNG),y
    sta ps_n1
    iny
    lda (SNG),y
    sta ps_n2
    iny
    sty ps_idx

    lda ps_w1
    sta ps_wave
    lda ps_n1
    ldx #0
    jsr ps_setvoice
    lda ps_w2
    sta ps_wave
    lda ps_n2
    ldx #7
    jsr ps_setvoice

    lda ps_dur
    sec
    sbc #1
    jsr wait_jiff
    bcs ps_done
    lda ps_w1               ; gate off for the last jiffy
    sta SID_CTRL1
    lda ps_w2
    sta SID_CTRL2
    lda #1
    jsr wait_jiff
    bcc ps_step
ps_done:
    lda ps_w1
    sta SID_CTRL1
    lda ps_w2
    sta SID_CTRL2
ps_quit:
    rts

; A = note (0 = rest), X = voice offset (0 or 7), ps_wave = waveform
ps_setvoice:
    tay
    beq psv_rest
    lda note_lo,y
    sta SID_FREQ1,x
    lda note_hi,y
    sta SID_FREQ1+1,x
    lda ps_wave
    ora #1                  ; gate on
    sta SID_CTRL1,x
    rts
psv_rest:
    lda ps_wave
    sta SID_CTRL1,x
    rts

; Wait A jiffies (IRQ clock).  Carry set = cut short by a key.
wait_jiff:
    tax
    beq wj_done
wj_next:
    lda JIFFY
wj_spin:
    ldy song_skip
    beq wj_chk
    ldy KEYCOUNT
    bne wj_abort
wj_chk:
    cmp JIFFY
    beq wj_spin
    dex
    bne wj_next
wj_done:
    clc
    rts
wj_abort:
    sec
    rts

; ============================================================
; DRAWING PRIMITIVES
; ============================================================

; A/X = screen offset (0-999) -> SPTR, CPTR
set_pos:
    sta SPTR
    sta CPTR
    txa
    clc
    adc #>SCREEN
    sta SPTR+1
    txa
    clc
    adc #>COLRAM
    sta CPTR+1
    rts

; A = screen code, X = count, cur_color = colour.
; Fills from SPTR/CPTR.
fill:
    ldy #0
fl_loop:
    sta (SPTR),y
    pha
    lda cur_color
    sta (CPTR),y
    pla
    iny
    dex
    bne fl_loop
    rts

; A/X -> text record: !word offset, !byte colour[|REV], text, 0
print_at:
    sta SRC
    stx SRC+1
    ldy #0
    lda (SRC),y
    sta SPTR
    sta CPTR
    iny
    lda (SRC),y
    clc
    adc #>SCREEN
    sta SPTR+1
    lda (SRC),y
    clc
    adc #>COLRAM
    sta CPTR+1
    iny
    lda (SRC),y
    and #REV
    sta cur_rev
    lda (SRC),y
    and #$0F
    sta cur_color

    lda SRC                 ; skip 3-byte header
    clc
    adc #3
    sta SRC
    bcc pa_go
    inc SRC+1
pa_go:
    ldy #0
pa_loop:
    lda (SRC),y
    beq pa_done
    ora cur_rev
    sta (SPTR),y
    lda cur_color
    sta (CPTR),y
    iny
    bne pa_loop
pa_done:
    rts

; A/X -> cell table (see !macro cell), $FF terminated.
; A cell is drawn when wrong_count >= its stage, else blanked.
draw_cells:
    sta SRC
    stx SRC+1
    ldy #0
dc_loop:
    lda (SRC),y
    cmp #$FF
    beq dc_done
    sta tmp_stage
    iny
    lda (SRC),y
    sta SPTR
    sta CPTR
    iny
    lda (SRC),y
    clc
    adc #>SCREEN
    sta SPTR+1
    lda (SRC),y
    clc
    adc #>COLRAM
    sta CPTR+1
    iny
    lda (SRC),y
    sta tmp_chr
    iny
    lda (SRC),y
    sta tmp_col
    iny
    sty tmp_y

    ldy #0
    lda wrong_count
    cmp tmp_stage
    bcc dc_blank
    lda tmp_col
    sta (CPTR),y
    lda tmp_chr
    jmp dc_put
dc_blank:
    lda #SC_SPACE
dc_put:
    sta (SPTR),y
    ldy tmp_y
    jmp dc_loop
dc_done:
    rts

; ============================================================
; DATA: TEXT  (lowercase source = uppercase on screen)
; ============================================================

txt_title:
    +at 1, 12, LBLUE|REV
    !scr "c64  hangman",0

txt_misses:
    +at 5, PANEL_COL, CYAN
    !scr "misses",0

txt_lives:
    +at 9, PANEL_COL, CYAN
    !scr "lives",0

txt_prompt:
    +at PROMPT_ROW, 9, LGREY
    !scr "type a letter  a-z",0

txt_win:
    +at MSG_ROW, 13, LGREEN|REV
    !scr " you win! ",0

txt_lose:
    +at MSG_ROW, 13, RED|REV
    !scr " game over ",0

txt_again:
    +at PROMPT_ROW, 6, YELLOW
    !scr "press any key for a new word",0

txt_sub1:
    +at 16, 8, CYAN
    !scr "a word game for the c64",0

txt_sub2:
    +at 17, 4, GREY
    !scr "six wrong guesses and it's over",0

; "nnnn words to guess": digits worked out at assembly time
; (screen code of '0' is $30; WORD_COUNT is 1000-8191)
txt_count:
    +at 18, 10, LGREEN
    !byte $30 + (WORD_COUNT / 1000) % 10
    !byte $30 + (WORD_COUNT / 100) % 10
    !byte $30 + (WORD_COUNT / 10) % 10
    !byte $30 + WORD_COUNT % 10
    !scr " words to guess",0

txt_press:
    +at 20, 9, YELLOW
    !scr "press any key to play",0

txt_author:
    +at 22, 15, LGREY
    !scr "author jdc",0

txt_score:
    +at SCORE_ROW, 10, GREY
    !scr "wins         losses",0

; ============================================================
; DATA: GALLOWS + MAN
;
;   col: 3         10
;  row 4  #########          beam (brown)
;  row 5  #/      |          brace, rope (yellow)
;  row 6  #       O          1 head
;  row 7  #      /|\         3 left arm, 2 body, 4 right arm
;  row 8  #       |          2 body
;  row 9  #      / \         5 left leg, 6 right leg
;  ...    #
;  row14 ############### grass, row15 dirt (drawn in draw_static)
; ============================================================

gallows_cells:
    ; beam
    +cell 0, 4, 3,  SC_SOLID, BROWN
    +cell 0, 4, 4,  SC_SOLID, BROWN
    +cell 0, 4, 5,  SC_SOLID, BROWN
    +cell 0, 4, 6,  SC_SOLID, BROWN
    +cell 0, 4, 7,  SC_SOLID, BROWN
    +cell 0, 4, 8,  SC_SOLID, BROWN
    +cell 0, 4, 9,  SC_SOLID, BROWN
    +cell 0, 4, 10, SC_SOLID, BROWN
    +cell 0, 4, 11, SC_SOLID, BROWN
    ; post
    +cell 0, 5,  3, SC_SOLID, BROWN
    +cell 0, 6,  3, SC_SOLID, BROWN
    +cell 0, 7,  3, SC_SOLID, BROWN
    +cell 0, 8,  3, SC_SOLID, BROWN
    +cell 0, 9,  3, SC_SOLID, BROWN
    +cell 0, 10, 3, SC_SOLID, BROWN
    +cell 0, 11, 3, SC_SOLID, BROWN
    +cell 0, 12, 3, SC_SOLID, BROWN
    +cell 0, 13, 3, SC_SOLID, BROWN
    ; brace + rope
    +cell 0, 5, 4,  SC_DIAG_U, BROWN
    +cell 0, 5, 10, SC_VLINE,  YELLOW
    ; the man, one part per wrong guess
    +cell 1, 6, 10, SC_BALL,   WHITE
    +cell 2, 7, 10, SC_VLINE,  WHITE
    +cell 2, 8, 10, SC_VLINE,  WHITE
    +cell 3, 7, 9,  SC_DIAG_U, WHITE
    +cell 4, 7, 11, SC_DIAG_D, WHITE
    +cell 5, 9, 9,  SC_DIAG_U, WHITE
    +cell 6, 9, 11, SC_DIAG_D, WHITE
    !byte $FF

; side panel: corners + vertical edges (horizontals via fill)
panel_cells:
    +cell 0, 4,  20, SC_TL, GREY
    +cell 0, 4,  36, SC_TR, GREY
    +cell 0, 13, 20, SC_BL, GREY
    +cell 0, 13, 36, SC_BR, GREY
    +cell 0, 5,  20, SC_VLINE, GREY
    +cell 0, 6,  20, SC_VLINE, GREY
    +cell 0, 7,  20, SC_VLINE, GREY
    +cell 0, 8,  20, SC_VLINE, GREY
    +cell 0, 9,  20, SC_VLINE, GREY
    +cell 0, 10, 20, SC_VLINE, GREY
    +cell 0, 11, 20, SC_VLINE, GREY
    +cell 0, 12, 20, SC_VLINE, GREY
    +cell 0, 5,  36, SC_VLINE, GREY
    +cell 0, 6,  36, SC_VLINE, GREY
    +cell 0, 7,  36, SC_VLINE, GREY
    +cell 0, 8,  36, SC_VLINE, GREY
    +cell 0, 9,  36, SC_VLINE, GREY
    +cell 0, 10, 36, SC_VLINE, GREY
    +cell 0, 11, 36, SC_VLINE, GREY
    +cell 0, 12, 36, SC_VLINE, GREY
    !byte $FF

; ============================================================
; DATA: TITLE LETTERS  (5x5, one byte per row, bit 4 = left)
; ============================================================

big_font:
    !byte %00010001,%00010001,%00011111,%00010001,%00010001   ; 0 H
    !byte %00001110,%00010001,%00011111,%00010001,%00010001   ; 1 A
    !byte %00010001,%00011001,%00010101,%00010011,%00010001   ; 2 N
    !byte %00001111,%00010000,%00010011,%00010001,%00001111   ; 3 G
    !byte %00010001,%00011011,%00010101,%00010001,%00010001   ; 4 M

big_hang: !byte 0,1,2,3,$FF
big_man:  !byte 4,1,2,$FF

big_pal:  !byte RED,LRED,ORANGE,YELLOW,WHITE   ; top to bottom

; ============================================================
; DATA: SOUND
;
; Note numbers index note_lo/note_hi.  Frequencies are for a PAL
; C64 (985248 Hz clock); on NTSC everything is ~4% sharp.
; Tempo follows the jiffy clock, which the KERNAL runs at 60 Hz
; on both PAL and NTSC.
; ============================================================

REST = 0
C2  = 1
CS2 = 2
D2  = 3
DS2 = 4
E2  = 5
F2  = 6
FS2 = 7
G2  = 8
GS2 = 9
A2  = 10
AS2 = 11
B2  = 12
C3  = 13
CS3 = 14
D3  = 15
DS3 = 16
E3  = 17
F3  = 18
FS3 = 19
G3  = 20
GS3 = 21
A3  = 22
AS3 = 23
B3  = 24
C4  = 25
CS4 = 26
D4  = 27
DS4 = 28
E4  = 29
F4  = 30
FS4 = 31
G4  = 32
GS4 = 33
A4  = 34
AS4 = 35
B4  = 36
C5  = 37
CS5 = 38
D5  = 39
DS5 = 40
E5  = 41
F5  = 42
FS5 = 43
G5  = 44
GS5 = 45
A5  = 46
AS5 = 47
B5  = 48
C6  = 49
CS6 = 50
D6  = 51
DS6 = 52
E6  = 53
F6  = 54
FS6 = 55
G6  = 56
GS6 = 57
A6  = 58
AS6 = 59
B6  = 60

note_lo:
    !byte 0
    !byte $5A,$9C,$E2,$2D,$7B,$CF,$27,$85,$E8,$51,$C1,$37
    !byte $B4,$38,$C4,$59,$F7,$9D,$4E,$0A,$D0,$A2,$81,$6D
    !byte $67,$70,$89,$B2,$ED,$3B,$9C,$13,$A0,$45,$02,$DA
    !byte $CE,$E0,$11,$64,$DA,$76,$39,$26,$40,$89,$04,$B4
    !byte $9C,$C0,$23,$C8,$B4,$EB,$72,$4C,$80,$12,$08,$68
note_hi:
    !byte 0
    !byte $04,$04,$04,$05,$05,$05,$06,$06,$06,$07,$07,$08
    !byte $08,$09,$09,$0A,$0A,$0B,$0C,$0D,$0D,$0E,$0F,$10
    !byte $11,$12,$13,$14,$15,$17,$18,$1A,$1B,$1D,$1F,$20
    !byte $22,$24,$27,$29,$2B,$2E,$31,$34,$37,$3A,$3E,$41
    !byte $45,$49,$4E,$52,$57,$5C,$62,$68,$6E,$75,$7C,$83

!macro step .dur, .n1, .n2 {
    !byte .dur, .n1, .n2
}

; key accepted: short high blip
song_tick:
    !byte WAVE_PULSE, WAVE_TRI
    +step 3, E6, REST
    !byte 0

; right letter: two rising chimes
song_right:
    !byte WAVE_PULSE, WAVE_TRI
    +step 5,  E5, E4
    +step 14, A5, A4
    !byte 0

; wrong letter: dissonant falling buzz
song_wrong:
    !byte WAVE_SAW, WAVE_SAW
    +step 6,  D3,  CS3
    +step 6,  AS2, A2
    +step 16, G2,  FS2
    !byte 0

; round won: rising C major fanfare
song_win:
    !byte WAVE_PULSE, WAVE_TRI
    +step 6,  C5, C3
    +step 6,  E5, E3
    +step 6,  G5, G3
    +step 6,  C6, C4
    +step 6,  E6, E4
    +step 40, C6, C3
    !byte 0

; round lost: sinking semitones
song_lose:
    !byte WAVE_SAW, WAVE_TRI
    +step 10, D4, D2
    +step 10, CS4, CS2
    +step 10, C4, C2
    +step 44, B3, B2
    !byte 0

; title jingle: A minor arpeggios, F - G - E, then home to Am
song_title:
    !byte WAVE_PULSE, WAVE_TRI
    +step 6, A4, A2
    +step 6, C5, A3
    +step 6, E5, A2
    +step 6, A5, A3
    +step 6, E5, A2
    +step 6, C5, A3
    +step 6, E5, A2
    +step 6, A5, A3

    +step 6, F4, F2
    +step 6, A4, F3
    +step 6, C5, F2
    +step 6, F5, F3
    +step 6, C5, F2
    +step 6, A4, F3
    +step 6, C5, F2
    +step 6, F5, F3

    +step 6, G4, G2
    +step 6, B4, G3
    +step 6, D5, G2
    +step 6, G5, G3
    +step 6, D5, G2
    +step 6, B4, G3
    +step 6, D5, G2
    +step 6, G5, G3

    +step 6, E4, E2
    +step 6, GS4, E3
    +step 6, B4, E2
    +step 6, E5, E3
    +step 6, B4, E2
    +step 6, GS4, E3
    +step 6, B4, E2
    +step 6, E5, E3

    +step 8, A5, A2
    +step 36, A5, A2
    !byte 0

; ============================================================
; VARIABLES
; ============================================================

word_length: !byte 0
wrong_count: !byte 0
guess_char:  !byte 0
reveal:      !byte 0
rnd_seed:    !byte 0
last_word:   !word 0
pick_lo:     !byte 0
pick_hi:     !byte 0
wins:        !byte 0        ; BCD
losses:      !byte 0        ; BCD
cur_color:   !byte 0
cur_rev:     !byte 0
tmp_stage:   !byte 0
tmp_chr:     !byte 0
tmp_col:     !byte 0
tmp_x:       !byte 0
tmp_y:       !byte 0
song_skip:   !byte 0        ; nonzero: a keypress cuts a song short
ps_w1:       !byte 0
ps_w2:       !byte 0
ps_wave:     !byte 0
ps_dur:      !byte 0
ps_n1:       !byte 0
ps_n2:       !byte 0
ps_idx:      !byte 0
end_sng:     !word 0
big_off:     !word 0
big_row:     !byte 0
big_ix:      !byte 0
big_col:     !byte 0
big_bits:    !byte 0
bit_buf:     !byte 0        ; XL word unpacker
bit_cnt:     !byte 0
bit_sym:     !byte 0

guessed:     !fill 26,0     ; one flag per letter A-Z
miss_list:   !fill MAX_WRONG,0
word_buf:    !fill 17,0     ; longest word is 16 letters

; ============================================================
; DATA: WORDS  (generated: make words / make words_xl.asm)
;
; Last in memory so code and variables stay below $A000.
; ============================================================

!if XL {
!source "words_xl.asm"
!if * > $D000 { !error "XL word list runs into I/O at $D000" }
} else {
!source "words.asm"
!if * > $A000 { !error "word list runs into BASIC ROM at $A000" }
}
