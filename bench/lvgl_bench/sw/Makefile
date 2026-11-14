# ----------------------------------------------------------------------------
#          _    _           Family:    aRVern Graphic Controller
#         / \__/ \          File:      Makefile (bench/lvgl_bench/sw)
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
# ----------------------------------------------------------------------------
# Firmware of the LVGL benchmark bench (bin/lvgl_bench.py runs it): LVGL
# v9.6.0's lv_demo_benchmark on the Belenos driver (sw/src) and its LVGL glue
# (sw/lvgl/lv_belenos.c), for aRVern's Performance persona (verilog/tb_lvgl_bench.v).
#
#   make OUT=<dir> LB_W=480 LB_H=272 [PLAT=<platform header>] [PERSONA=<name>]
#        [FLUSH=direct|cpu] [TICK=lockstep|real] [DUMP=<n>] [APPROX=<0..7>]
#
# PLAT names the persona's Belenos platform header (sw/include/belenos_hw.h;
# bin/lvgl_bench.py writes one per persona); without it the driver detects the
# features at run time. The options of a build are stamped in OUT/build.cfg:
# a build directory rebuilt with other options (or another PLAT) recompiles
# what they reach. LVGL is fetched once from its release archive, checked
# against its SHA-256, into ../lvgl_src (git-ignored): src/, include/, the
# top-level headers and the demos the benchmark needs (demos/lv_demos.*,
# demos/benchmark, demos/widgets: the benchmark runs the widgets demo as its
# last scene). LVGL is compiled once per resolution (obj_lvgl_<W>x<H> in the
# parent of OUT), the driver, the glue and main.c per build (OUT). LVGL is
# linked whole (--whole-archive: its objects in the archive's order, not in
# the order the build's references pull them) and link.ld keeps every one of
# its functions and places them first, at a fixed address: LVGL's code is
# then the same bytes at the same address in every persona and option.
# Output: OUT/fw.elf, fw.map, fw.hex (the code memory image, one 32-bit word
# per line from 0x20000000).
#
#   make coremark OUT=<dir> [CM_ITER=<n>]
#
# EEMBC CoreMark on the same core, memories and flags (coremark/: the port;
# the benchmark's sources from the arvern repository next to this one, not
# copied): OUT/coremark.hex.
# ----------------------------------------------------------------------------
LB_W      ?= 480
LB_H      ?= 272
PERSONA   ?= unnamed
FLUSH     ?= direct
TICK      ?= lockstep
DUMP      ?= 0
APPROX    ?=
PLAT      ?=
OUT       ?= ../run/build/$(LB_W)x$(LB_H)_$(PERSONA)

CC        = riscv-none-elf-gcc
OBJCOPY   = riscv-none-elf-objcopy
SIZE      = riscv-none-elf-size
MARCH     = rv32imc_zbb_zba_zbs_zbc_zcb_zicsr_zifencei
MABI      = ilp32
OPT       = -O2

BLNS_SW   = ../../../sw
LVGL_VER  = 9.6.0
LVGL_URL  = https://github.com/lvgl/lvgl/archive/refs/tags/v$(LVGL_VER).tar.gz
LVGL_SHA  = b20ee3acc1bba13c62d854f9ebd62e4c51e0b443b1e0225892e86442defa84df
LVGL_TOP  = ../lvgl_src
LVGL      = $(LVGL_TOP)/lvgl-$(LVGL_VER)

# Layers in chunks of at least 1/20 of the screen (lv_conf.h): above LVGL's 24 KB default only
LAYER_BUF = $(shell echo $$(( ($(LB_W) * $(LB_H) * 2 / 20 + 1023) / 1024 * 1024 )))
LV_DEFS   = $(if $(filter 1,$(shell test $(LAYER_BUF) -gt 24576 && echo 1)),-DLB_LAYER_BUF=$(LAYER_BUF)U)

ARCH      = -march=$(MARCH) -mabi=$(MABI)
BASE      = $(ARCH) $(OPT) -g -std=gnu11 -ffunction-sections -fdata-sections -DLV_CONF_INCLUDE_SIMPLE \
            -I. -I$(LVGL) $(LV_DEFS)
APP_DEFS  = -DLB_PERSONA='"$(PERSONA)"' -DLB_DUMP_FRAME=$(DUMP)u $(if $(APPROX),-DLB_APPROX=$(APPROX)u) \
            $(if $(filter cpu,$(FLUSH)),-DLB_FLUSH_CPU) $(if $(filter real,$(TICK)),-DLB_TICK_REAL) \
            $(if $(PLAT),-I$(dir $(PLAT)) -DBLNS_PLATFORM_HEADER='"$(notdir $(PLAT))"')
APP_INC   = -I$(BLNS_SW)/include -I$(BLNS_SW)/lvgl
LDFLAGS   = $(ARCH) $(OPT) -nostartfiles -T link.ld -Wl,--gc-sections --specs=nano.specs \
            -Wl,--wrap=blns_gpu_recover

LV_OBJDIR = $(dir $(OUT:/=))obj_lvgl_$(LB_W)x$(LB_H)
LV_SRCS   = $(if $(wildcard $(LVGL)/lvgl.h),$(shell find $(LVGL)/src -name '*.c') $(LVGL)/demos/lv_demos.c \
            $(shell find $(LVGL)/demos/benchmark $(LVGL)/demos/widgets -name '*.c'))
LV_OBJS   = $(patsubst $(LVGL)/%.c,$(LV_OBJDIR)/%.o,$(LV_SRCS))
DRV_SRCS  = $(BLNS_SW)/src/belenos.c $(BLNS_SW)/src/blns_gpu.c $(BLNS_SW)/src/blns_dpi.c \
            $(BLNS_SW)/src/blns_ddc.c $(BLNS_SW)/lvgl/lv_belenos.c
APP_OBJS  = $(OUT)/main.o $(OUT)/startup.o $(addprefix $(OUT)/,$(notdir $(DRV_SRCS:.c=.o)))

CM_DIR    = ../../../../arvern/sim/rtl_sim/src-c/coremark
CM_ITER  ?= 10
CM_SRCS   = $(addprefix $(CM_DIR)/,core_list_join.c core_main.c core_matrix.c core_state.c core_util.c) \
            coremark/core_portme.c
CM_FLAGS  = $(ARCH) $(OPT) -std=gnu11 -Icoremark -I$(CM_DIR) -DITERATIONS=$(CM_ITER) \
            -DFLAGS_STR='"$(OPT) -march=$(MARCH) -mabi=$(MABI)"'

# The fetch first, then the build in a sub-make (LV_SRCS is read from the tree)
all: lvgl_fetch
	@$(MAKE) --no-print-directory fw

fw: $(OUT)/fw.hex

lvgl_fetch:
	@test -f $(LVGL)/lvgl.h || { \
	    mkdir -p $(LVGL_TOP) && curl -fsSL -o $(LVGL_TOP)/lvgl.tar.gz $(LVGL_URL) && \
	    { command -v sha256sum >/dev/null && sum=$$(sha256sum $(LVGL_TOP)/lvgl.tar.gz) || \
	      sum=$$(shasum -a 256 $(LVGL_TOP)/lvgl.tar.gz); } && \
	    test "$${sum%% *}" = "$(LVGL_SHA)" || { echo "LVGL archive: SHA-256 mismatch"; rm -f $(LVGL_TOP)/lvgl.tar.gz; exit 1; }; \
	    tar -xzf $(LVGL_TOP)/lvgl.tar.gz -C $(LVGL_TOP) lvgl-$(LVGL_VER)/src lvgl-$(LVGL_VER)/include \
	        lvgl-$(LVGL_VER)/lvgl.h lvgl-$(LVGL_VER)/lvgl_private.h lvgl-$(LVGL_VER)/lv_version.h \
	        lvgl-$(LVGL_VER)/LICENCE.txt lvgl-$(LVGL_VER)/demos/lv_demos.c lvgl-$(LVGL_VER)/demos/lv_demos.h \
	        lvgl-$(LVGL_VER)/demos/benchmark lvgl-$(LVGL_VER)/demos/widgets && \
	    rm -f $(LVGL_TOP)/lvgl.tar.gz; }

$(LV_OBJDIR)/%.o: $(LVGL)/%.c lv_conf.h lb_assert.h
	@mkdir -p $(@D)
	@$(CC) $(BASE) -c $< -o $@

$(LV_OBJDIR)/liblvgl.a: $(LV_OBJS)
	@rm -f $@
	@$(SIZE) -t $^ | tail -1 | awk '{print "LVGL objects: text " $$1 ", data " $$2 ", bss " $$3}'
	@riscv-none-elf-ar rcs $@ $^

DRV_HDRS  = $(BLNS_SW)/lvgl/lv_belenos.h $(BLNS_SW)/include/belenos.h $(BLNS_SW)/include/belenos_hw.h

# The build's configuration (compiler, flags, defines: DUMP, APPROX, FLUSH,
# TICK, PERSONA, PLAT...; the quotes left out) in a stamp, rewritten when it
# changes: the objects and the link depend on it, so an option changed for an
# existing OUT rebuilds them (make compares only the files' dates otherwise)
CFG_STAMP = $(OUT)/build.cfg
CFG_TEXT  = $(strip $(subst ',,$(subst ",,$(CC) $(BASE) $(APP_DEFS) $(APP_INC) $(LDFLAGS))))
ifneq ($(strip $(shell cat $(CFG_STAMP) 2>/dev/null)),$(CFG_TEXT))
.PHONY: $(CFG_STAMP)
endif
$(CFG_STAMP):
	@mkdir -p $(@D)
	@echo '$(CFG_TEXT)' > $@

$(OUT)/main.o: main.c lv_conf.h lb_assert.h $(PLAT) $(DRV_HDRS) Makefile $(CFG_STAMP)
	@mkdir -p $(@D)
	$(CC) $(BASE) $(APP_DEFS) $(APP_INC) -Wall -Wextra -c $< -o $@
$(OUT)/startup.o: startup.S $(CFG_STAMP)
	@mkdir -p $(@D)
	$(CC) $(ARCH) -c $< -o $@
define drv_rule
$(OUT)/$(notdir $(1:.c=.o)): $(1) lv_conf.h $(PLAT) $(DRV_HDRS) Makefile $(CFG_STAMP)
	@mkdir -p $$(@D)
	$$(CC) $$(BASE) $$(APP_DEFS) $$(APP_INC) -Wall -c $$< -o $$@
endef
$(foreach s,$(DRV_SRCS),$(eval $(call drv_rule,$(s))))

$(OUT)/fw.elf: $(APP_OBJS) $(LV_OBJDIR)/liblvgl.a link.ld $(CFG_STAMP)
	$(CC) $(LDFLAGS) -Wl,-Map,$(OUT)/fw.map $(APP_OBJS) -Wl,--whole-archive $(LV_OBJDIR)/liblvgl.a \
	    -Wl,--no-whole-archive -lm -o $@
	$(SIZE) $@

# The image from 0x20000000 (the code sections and the .data image): one word per line
$(OUT)/fw.hex: $(OUT)/fw.elf
	$(OBJCOPY) -O binary -j .init -j .lvgl -j .text -j .data $< $(OUT)/fw.bin
	python3 -I -c "import sys,struct; b=open(sys.argv[1],'rb').read(); b+=bytes(-len(b)%4); \
	open(sys.argv[2],'w').write(''.join('%08x\n'%w for w in struct.unpack('<%dI'%(len(b)//4),b)))" \
	    $(OUT)/fw.bin $@

coremark: $(OUT)/coremark.hex

$(OUT)/coremark.elf: $(CM_SRCS) coremark/core_portme.h startup.S link.ld
	@mkdir -p $(@D)
	$(CC) $(CM_FLAGS) $(CM_SRCS) startup.S -nostartfiles -T link.ld --specs=nano.specs \
	    -Wl,--gc-sections -Wl,-Map,$(OUT)/coremark.map -o $@
	$(SIZE) $@

$(OUT)/coremark.hex: $(OUT)/coremark.elf
	$(OBJCOPY) -O binary -j .init -j .lvgl -j .text -j .data $< $(OUT)/coremark.bin
	python3 -I -c "import sys,struct; b=open(sys.argv[1],'rb').read(); b+=bytes(-len(b)%4); \
	open(sys.argv[2],'w').write(''.join('%08x\n'%w for w in struct.unpack('<%dI'%(len(b)//4),b)))" \
	    $(OUT)/coremark.bin $@

clean:
	rm -rf $(OUT) $(LV_OBJDIR)

.PHONY: all fw coremark lvgl_fetch clean
