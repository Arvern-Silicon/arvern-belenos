# Host unit test of the driver (sw/): make -C sw/test
# Three builds of the same test: without a platform header (run-time
# detection), with every feature stated present (plat_all.h), and with the
# essential persona's set (plat_essential.h: absent features as inline stubs). The
# first build runs under AddressSanitizer and UBSan (make SAN= without them,
# for a compiler that has none). Two host checks of the GPU's arithmetic
# against LVGL's (no LVGL needed: its kernels are quoted): check_mix5 (the
# MIX5 blend rule, bit-exact) and check_bilinear (the bounds of bilinear
# sampling).
#
# Host test of the LVGL glue (sw/lvgl): make -C sw/test -j8 lvgl
# LVGL v9.6.0 (fetched on first use into lvgl_src/, or LVGL=<root>) is built
# once per configuration: 'std' (LVGL's defaults, as the demo), 'a8' (buffers and
# strides aligned to 8 bytes, LV_DRAW_SW_COMPLEX 0), and 'ext', 'exta8' the same
# with the glue's extensions built (LV_BELENOS_USE_*; a 256 KB VRAM); GLUE=<file> tests
# another lv_belenos.c (a change of GLUE alone rebuilds nothing: rm test_lvgl_*).
# The glue's blns_gpu_fence_status and lv_display_add_event_cb calls go to the
# test's wrappers (lvt_*: a recover requested as one returns, a callback
# refused as out of memory).
CC      ?= cc
SAN     ?= -fsanitize=address,undefined -fno-sanitize-recover=all
CFLAGS  = -std=c11 -O1 -g -Wall -Wextra -Werror -pedantic -I../include -I. -include blns_model.h
DRV_SRCS = ../src/belenos.c ../src/blns_gpu.c ../src/blns_dpi.c ../src/blns_ddc.c ../src/blns_hotplug.c \
           ../src/blns_dbi.c
SRCS    = test_driver.c $(DRV_SRCS)
DEPS    = $(SRCS) blns_model.h blns_model_impl.h ../include/belenos.h ../include/belenos_hw.h ../include/belenos_regs.h \
          ../src/blns_priv.h Makefile
BUILDS  = test_driver test_driver_all test_driver_essential
CHECKS  = check_mix5 check_bilinear

all: run

test_driver: $(DEPS)
	$(CC) $(CFLAGS) $(SAN) $(SRCS) -lm -o $@
test_driver_all: $(DEPS) plat_all.h
	$(CC) $(CFLAGS) -DBLNS_PLATFORM_HEADER='"plat_all.h"' $(SRCS) -lm -o $@
test_driver_essential: $(DEPS) plat_essential.h
	$(CC) $(CFLAGS) -DBLNS_PLATFORM_HEADER='"plat_essential.h"' $(SRCS) -lm -o $@

check_%: check_%.c Makefile
	$(CC) -std=c11 -O2 -Wall -Wextra -Werror -pedantic $< -o $@

run: $(BUILDS) $(CHECKS)
	@for t in $(BUILDS) $(CHECKS); do echo "== $$t"; ./$$t || exit 1; done

#--------------------------------- LVGL glue ---------------------------------
# LVGL v9.6.0, fetched once from its release archive (checked against its SHA-256) into
# lvgl_src/ (git-ignored): only src/, include/ and the top-level headers are kept. Another copy:
# make lvgl LVGL=<its root>
LVGL_VER   = 9.6.0
LVGL_URL   = https://github.com/lvgl/lvgl/archive/refs/tags/v$(LVGL_VER).tar.gz
LVGL_SHA   = b20ee3acc1bba13c62d854f9ebd62e4c51e0b443b1e0225892e86442defa84df
LVGL_DIR   = lvgl_src/lvgl-$(LVGL_VER)
LVGL      ?= $(LVGL_DIR)
GLUE      ?= ../lvgl/lv_belenos.c
LV_CFGS    = std a8 ext exta8
LV_EXT     = -DLV_BELENOS_USE_CORNERS=1 -DLV_BELENOS_USE_POOL=1 -DLV_BELENOS_USE_APPROX=1 -DMODEL_WORDS=65536u
LV_DEFS_std =
LV_DEFS_a8  = -DLV_DRAW_BUF_STRIDE_ALIGN=8 -DLV_DRAW_BUF_ALIGN=8 -DLV_DRAW_SW_COMPLEX=0
LV_DEFS_ext = $(LV_EXT)
LV_DEFS_exta8 = $(LV_DEFS_a8) $(LV_EXT)
LV_SRCS    = $(if $(wildcard $(LVGL)/lvgl.h),$(shell find $(LVGL)/src -name '*.c'))
LV_CFLAGS  = -std=gnu11 -O1 -g -DLV_CONF_INCLUDE_SIMPLE -Ilvgl -I$(LVGL)
# the glue and the test: the driver's warnings; the model's unused helpers allowed in the test
LVT_CFLAGS = $(LV_CFLAGS) -Wall -Wextra -Werror -I../include -I../lvgl -I. -include blns_model.h
LVT_DEPS   = $(GLUE) ../lvgl/lv_belenos.h test_lvgl.c lvgl/lv_conf.h $(DEPS)
LV_BUILDS  = $(addprefix test_lvgl_,$(LV_CFGS))

# The fetch first, then the builds in a sub-make (LV_SRCS is read from the tree)
lvgl: lvgl_fetch
	@$(MAKE) --no-print-directory lvgl_run

lvgl_run: $(LV_BUILDS)
	@for t in $(LV_BUILDS); do echo "== $$t"; ./$$t || exit 1; done

lvgl_fetch:
	@test -f $(LVGL)/lvgl.h || test "$(LVGL)" != "$(LVGL_DIR)" || { \
	    mkdir -p lvgl_src && curl -fsSL -o lvgl_src/lvgl.tar.gz $(LVGL_URL) && \
	    { command -v sha256sum >/dev/null && sum=$$(sha256sum lvgl_src/lvgl.tar.gz) || \
	      sum=$$(shasum -a 256 lvgl_src/lvgl.tar.gz); } && \
	    test "$${sum%% *}" = "$(LVGL_SHA)" || { echo "LVGL archive: SHA-256 mismatch"; rm -f lvgl_src/lvgl.tar.gz; exit 1; }; \
	    tar -xzf lvgl_src/lvgl.tar.gz -C lvgl_src lvgl-$(LVGL_VER)/src lvgl-$(LVGL_VER)/include lvgl-$(LVGL_VER)/lvgl.h \
	        lvgl-$(LVGL_VER)/lvgl_private.h lvgl-$(LVGL_VER)/lv_version.h lvgl-$(LVGL_VER)/LICENCE.txt && \
	    rm -f lvgl_src/lvgl.tar.gz; }

lvgl_tree:
	@test -f $(LVGL)/lvgl.h || { echo "LVGL v$(LVGL_VER) not found at $(LVGL): make lvgl (fetches it) or make lvgl LVGL=<its root>"; exit 1; }

define lv_cfg
LV_OBJS_$(1) = $$(patsubst $$(LVGL)/%.c,obj_lvgl/$(1)/%.o,$$(LV_SRCS))
obj_lvgl/$(1)/%.o: $$(LVGL)/%.c lvgl/lv_conf.h | lvgl_tree
	@mkdir -p $$(@D)
	@$$(CC) $$(LV_CFLAGS) $$(LV_DEFS_$(1)) $$(SAN) -c $$< -o $$@
obj_lvgl/$(1)/liblvgl.a: $$(LV_OBJS_$(1))
	@rm -f $$@
	ar rcs $$@ $$^
test_lvgl_$(1): $$(LVT_DEPS) obj_lvgl/$(1)/liblvgl.a | lvgl_tree
	$$(CC) $$(LVT_CFLAGS) $$(LV_DEFS_$(1)) $$(SAN) -Dblns_gpu_fence_status=lvt_fence_status \
	    -Dlv_display_add_event_cb=lvt_display_add_event_cb -c $$(GLUE) \
	    -o obj_lvgl/$(1)/lv_belenos.o
	$$(CC) $$(LVT_CFLAGS) $$(LV_DEFS_$(1)) $$(SAN) -Wno-unused-function -c test_lvgl.c -o obj_lvgl/$(1)/test_lvgl.o
	$$(CC) $$(CFLAGS) $$(SAN) $$(DRV_SRCS) obj_lvgl/$(1)/test_lvgl.o obj_lvgl/$(1)/lv_belenos.o \
	    obj_lvgl/$(1)/liblvgl.a -lm -o $$@
endef
$(foreach c,$(LV_CFGS),$(eval $(call lv_cfg,$(c))))

clean:
	rm -rf $(BUILDS) $(addsuffix .dSYM,$(BUILDS)) $(CHECKS) $(LV_BUILDS) $(addsuffix .dSYM,$(LV_BUILDS)) obj_lvgl

.PHONY: all run lvgl lvgl_run lvgl_fetch lvgl_tree clean
