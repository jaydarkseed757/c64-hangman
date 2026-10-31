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
#   make ultimate send build/hangman.prg to the C64 Ultimate over its REST
#                 API and RUN it (tools/run_ultimate.sh; ULT_HOST,
#                 ULT_FILE=build/hangman.d64 mounts a disk instead,
#                 ULT_PASSWORD, ULT_DRY=1 only prints)
#   make ultimate-xl  the same with build/hangman-xl.prg
#   make words    regenerate words.asm and words_xl.asm from wordsrc/
#                 (tools/gen_words.py)
#   make internet-archive
#                 package every PRG, the d64, a zip and README.TXT
#                 (from dist/README.TXT.in) in internet-archive/ for
#                 upload to archive.org; VERSION=x.y names the zip
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

GAME     := c64-hangman
IA_DIR   := internet-archive
IA_README := dist/README.TXT.in
# the latest git tag, or "dev" until there is one
VERSION  ?= $(or $(shell git describe --tags --abbrev=0 2>/dev/null),dev)
IA_ZIP   := $(GAME)-$(VERSION).zip

# md5sum/sha1sum (Linux, newer macOS) or md5/shasum (older macOS);
# both forms print the hash first.
MD5      := $(shell command -v md5sum >/dev/null 2>&1 && echo md5sum || echo 'md5 -r')
SHA1     := $(shell command -v sha1sum >/dev/null 2>&1 && echo sha1sum || echo 'shasum -a 1')

.PHONY: all xl crunch d64 run run-xl run-d64 ultimate ultimate-xl words internet-archive clean

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

# Run on the C64 Ultimate: the PRG is DMA-loaded and RUN over the REST API
# (nothing written to its storage). ULT_FILE picks another build file; a .d64
# is mounted on drive A and the machine reset.
ULT_FILE ?= $(PRG)
ultimate: $(ULT_FILE)
	ULT_FILE="$(ULT_FILE)" tools/run_ultimate.sh

ultimate-xl: $(XL_PRG)
	ULT_FILE="$(XL_PRG)" tools/run_ultimate.sh

# ~35 KB of words fits below $$A000; pass a smaller budget if the code grows.
# The XL budget (to $$D000) is more than the whole list needs.
words:
	python3 -I tools/gen_words.py 35500
	python3 -I tools/gen_words.py --packed 46000

# Rebuilt from scratch on every run.  The d64 is skipped (with a warning)
# when c1541 is missing.  README.TXT's checksums cover the PRGs and the
# d64; the zip holds those plus README.TXT.
internet-archive: $(PRG) $(XL_PRG) $(CRUNCHED) $(XL_CRUNCHED) $(IA_README)
	rm -rf $(IA_DIR)
	mkdir -p $(IA_DIR)
	cp $(PRG) $(XL_PRG) $(CRUNCHED) $(XL_CRUNCHED) $(IA_DIR)/
	@if command -v $(C1541) >/dev/null 2>&1; then \
		$(MAKE) --no-print-directory d64 && cp $(D64) $(IA_DIR)/; \
	else \
		echo "warning: $(C1541) not found, no .d64 in the package"; \
	fi
	@set -e; \
	list=$(IA_DIR)/.files; : > $$list; \
	for f in $(IA_DIR)/*.d64 $(IA_DIR)/*.prg; do \
		[ -f "$$f" ] || continue; \
		printf '%s  (%s bytes)\n  MD5:  %s\n  SHA1: %s\n\n' "$${f##*/}" \
			"$$(wc -c < "$$f" | tr -d ' ')" \
			"$$($(MD5) "$$f" | cut -d' ' -f1)" \
			"$$($(SHA1) "$$f" | cut -d' ' -f1)" >> $$list; \
	done; \
	ver='$(VERSION)'; \
	[ "$$ver" = dev ] && ver='dev (TODO: tag a release, e.g. git tag v1.0)'; \
	hash=$$(git rev-parse --short HEAD 2>/dev/null || echo unknown); \
	acme=$$($(ACME) --version 2>&1 | sed -n 's/.*release \([0-9.]*\).*/\1/p' | head -1); \
	exo=$$($(EXOMIZER) -v 2>&1 | sed -n 's/.*Exomizer v\([0-9.]*\).*/\1/p' | head -1); \
	vice=$$($(C1541) -version 2>&1 | sed -n 's/.*(VICE \([0-9.]*\)).*/\1/p' | head -1); \
	end=$$(printf '%04X' $$((0x0801 + $$(wc -c < $(PRG)) - 3))); \
	endxl=$$(printf '%04X' $$((0x0801 + $$(wc -c < $(XL_PRG)) - 3))); \
	awk -v files="$$list" \
		-v ver="$$ver" \
		-v date="$$(date -u '+%Y-%m-%d %H:%M UTC')" \
		-v hash="$$hash" \
		-v acme="$${acme:-unknown}" -v exo="$${exo:-unknown}" -v vice="$${vice:-unknown}" \
		-v end="$$end" -v endxl="$$endxl" \
		-v words="$$(sed -n 's/^WORD_COUNT = //p' words.asm)" \
		-v wordsxl="$$(sed -n 's/^WORD_COUNT = //p' words_xl.asm)" \
		-v d64='$(notdir $(D64))' -v zip='$(IA_ZIP)' \
		'$$0 == "@FILES@" { while ((getline l < files) > 0) print l; next } \
		{ gsub(/@VERSION@/, ver); gsub(/@DATE@/, date); gsub(/@GITHASH@/, hash); \
		  gsub(/@ACME@/, acme); gsub(/@EXOMIZER@/, exo); gsub(/@VICE@/, vice); \
		  gsub(/@END@/, end); gsub(/@END_XL@/, endxl); \
		  gsub(/@WORDS@/, words); gsub(/@WORDS_XL@/, wordsxl); \
		  gsub(/@D64@/, d64); gsub(/@ZIP@/, zip); print }' \
		$(IA_README) > $(IA_DIR)/README.TXT; \
	rm -f $$list
	@if command -v zip >/dev/null 2>&1; then \
		cd $(IA_DIR) && zip -q -X $(IA_ZIP) $$(ls *.d64 *.prg 2>/dev/null) README.TXT; \
	else \
		echo "warning: zip not found, no $(IA_ZIP) in the package"; \
	fi
	@echo; echo "Internet Archive package: $(CURDIR)/$(IA_DIR)/"; \
	for f in $(IA_DIR)/*; do \
		printf '  %-28s %8s bytes\n' "$${f##*/}" "$$(wc -c < "$$f" | tr -d ' ')"; \
	done

clean:
	rm -rf build $(IA_DIR)
