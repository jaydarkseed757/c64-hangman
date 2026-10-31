# C64 HANGMAN - build system
#
#   make          build build/hangman.prg (uncompressed, for development)
#   make crunch   build build/hangman-packed.prg: the same program compressed
#                 with exomizer into one self-extracting file (the XL
#                 build too: build/hangman-xl-packed.prg)
#   make d64      build build/hangman.d64 with both compressed programs
#                 (files "HANGMAN" and "HANGMAN XL")
#   make run      build and autostart the uncompressed PRG in x64sc
#                 (PAL, no warp, injected straight into RAM: fastest)
#   make run-d64  build the disk image and boot it like a real C64:
#                 LOAD"*",8,1 from the emulated 1541, unpack, run
#   make xl       build build/hangman-xl.prg: every word in the list
#                 (~7,500), 5-bit packed, using the RAM under BASIC ROM
#   make run-xl   build and autostart the XL PRG in x64sc
#   make words    regenerate words.asm and words_xl.asm from wordsrc/
#                 (tools/gen_words.py)
#   make clean    remove build outputs

ACME     ?= acme
X64      ?= x64sc
C1541    ?= c1541
EXOMIZER ?= exomizer

PRG      := build/hangman.prg
CRUNCHED := build/hangman-packed.prg
XL_PRG   := build/hangman-xl.prg
XL_CRUNCHED := build/hangman-xl-packed.prg
D64      := build/hangman.d64

.PHONY: all xl crunch d64 run run-xl run-d64 words clean

all: $(PRG)

$(PRG): hangman.asm words.asm | build
	$(ACME) -f cbm -o $@ $<

xl: $(XL_PRG)

$(XL_PRG): hangman.asm words_xl.asm | build
	$(ACME) -f cbm -DXL=1 -o $@ $<

crunch: $(CRUNCHED) $(XL_CRUNCHED)

# sfx sys: a self-extracting PRG that finds our "SYS 2061" line and jumps
# there after unpacking. -x1: flash the border while it unpacks.
$(CRUNCHED): $(PRG)
	$(EXOMIZER) sfx sys -x1 -q -o $@ $<

# The unpacker handles the RAM under the BASIC ROM ($A000-) itself.
$(XL_CRUNCHED): $(XL_PRG)
	$(EXOMIZER) sfx sys -x1 -q -o $@ $<

d64: $(D64)

$(D64): $(CRUNCHED) $(XL_CRUNCHED)
	rm -f $@
	$(C1541) -format "hangman,64" d64 $@ -write $(CRUNCHED) "hangman" \
		-write $(XL_CRUNCHED) "hangman xl" >/dev/null

build:
	mkdir -p build

# -pal: force PAL machine. +warp: make sure warp/turbo is off.
# -autostartprgmode 1: inject the PRG straight into RAM (skips the slow
# emulated disk load).
run: $(PRG)
	$(X64) -pal +warp -autostartprgmode 1 -autostart $(PRG)

run-xl: $(XL_PRG)
	$(X64) -pal +warp -autostartprgmode 1 -autostart $(XL_PRG)

run-d64: $(D64)
	$(X64) -pal +warp -autostart $(D64)

# ~35 KB of words fits below $$A000; pass a smaller budget if the code grows.
# The XL budget (to $$D000) is more than the whole list needs.
words:
	python3 -I tools/gen_words.py 35500
	python3 -I tools/gen_words.py --packed 46000

clean:
	rm -rf build
