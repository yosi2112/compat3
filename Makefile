# COMPAT3.PCE production build. Toolchain: ca65/ld65 from cc65 (zlib
# license), vendored at ~/workspace/pce-compat3/tools/cc65 (pinned
# commit eebf54af545f4ae52f8489a2f6d4d5f93e7942d2). Override with
# CC65_DIR to use another cc65 installation.
CC65_DIR ?= $(HOME)/workspace/pce-compat3/tools/cc65
CA65 := $(CC65_DIR)/bin/ca65
LD65 := $(CC65_DIR)/bin/ld65

BUILD := build

PROD_OBJS := $(BUILD)/bank0.o $(BUILD)/player.o $(BUILD)/bmbios.o \
	$(BUILD)/fnbios.o $(BUILD)/exbios.o $(BUILD)/psgbios.o \
	$(BUILD)/grpbios.o $(BUILD)/fontdata.o

all: $(BUILD)/COMPAT3.PCE

$(BUILD)/COMPAT3.PCE: $(PROD_OBJS) cfg/compat3.cfg src/hw.inc
	$(LD65) -C cfg/compat3.cfg -o $@ $(PROD_OBJS)

# Objects and font intermediates are build-time only: make removes
# them again once the ROM is linked, so a finished build leaves just
# COMPAT3.PCE in build/.
.INTERMEDIATE: $(PROD_OBJS) $(BUILD)/font16.bin $(BUILD)/font12.bin \
	$(BUILD)/fontdata.s

$(BUILD)/bank0.o: src/bank0.s src/hw.inc src/video.s src/font8.s src/pad.s src/scsi.s src/cdbios.s src/cdplay.s src/adbios.s src/ipl.s
	@mkdir -p $(BUILD)
	$(CA65) --cpu huc6280 -I src -o $@ src/bank0.s

$(BUILD)/player.o: src/player.s src/hw.inc
	@mkdir -p $(BUILD)
	$(CA65) --cpu huc6280 -I src -o $@ src/player.s

$(BUILD)/bmbios.o: src/bmbios.s src/hw.inc
	@mkdir -p $(BUILD)
	$(CA65) --cpu huc6280 -I src -o $@ src/bmbios.s

$(BUILD)/fnbios.o: src/fnbios.s src/hw.inc
	@mkdir -p $(BUILD)
	$(CA65) --cpu huc6280 -I src -o $@ src/fnbios.s

$(BUILD)/exbios.o: src/exbios.s src/hw.inc
	@mkdir -p $(BUILD)
	$(CA65) --cpu huc6280 -I src -o $@ src/exbios.s

$(BUILD)/psgbios.o: src/psgbios.s src/hw.inc
	@mkdir -p $(BUILD)
	$(CA65) --cpu huc6280 -I src -o $@ src/psgbios.s

$(BUILD)/grpbios.o: src/grpbios.s src/hw.inc
	@mkdir -p $(BUILD)
	$(CA65) --cpu huc6280 -I src -o $@ src/grpbios.s

# KH-Dot-Dougenzaka font (fonts/, SIL OFL 1.1): pack the TTFs into
# the EX_GETFNT glyph set; fontdata.s then references ranges of the
# two packed binaries directly (no per-bank chunk files).
$(BUILD)/font16.bin $(BUILD)/font12.bin &: fonts/KH-Dot-Dougenzaka-16.ttf fonts/KH-Dot-Dougenzaka-12.ttf tools/pack_font.py tools/kh_extract.py
	@mkdir -p $(BUILD)
	python3 tools/pack_font.py

$(BUILD)/fontdata.s: $(BUILD)/font16.bin $(BUILD)/font12.bin tools/split_font.py
	python3 tools/split_font.py

$(BUILD)/fontdata.o: $(BUILD)/fontdata.s
	$(CA65) --cpu huc6280 -I $(BUILD) -o $@ $(BUILD)/fontdata.s

clean:
	rm -f $(BUILD)/*.o $(BUILD)/COMPAT3.PCE \
		$(BUILD)/font16.bin $(BUILD)/font12.bin $(BUILD)/fontdata.s \
		$(BUILD)/font_coverage.txt $(BUILD)/*.map $(BUILD)/*.lbl \
		$(BUILD)/map.txt $(BUILD)/labels.txt
	rm -rf $(BUILD)/fontbnk

.PHONY: all clean
