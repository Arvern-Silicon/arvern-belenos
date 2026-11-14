<p align="center">
  <img src="../doc/img/aRVern_light.png" alt="aRVern" width="180">
</p>

# Belenos driver library

*Bare-metal C driver for the Belenos graphic controller: register definitions, a small
API for the controller, the GPU and the built-in display drivers, and panel
drivers.*

The guide to the library — build, porting, conventions, concurrency, recovery, the API,
display bring-up and examples — is [doc/driver_guide.md](../doc/driver_guide.md); the
registers behind each call are in [doc/programming_model.md](../doc/programming_model.md),
[doc/register_map.md](../doc/register_map.md) and [doc/gpu_commands.md](../doc/gpu_commands.md).

---

## Layout

```
sw/
├── include/
│   ├── belenos_regs.h    register map: BLNS_TypeDef overlay, BLNS_<REG>_<FIELD>_Pos/_Msk
│   ├── belenos_hw.h      compile-time platform features (BLNS_HW_*, BLNS_HAS)
│   ├── belenos.h         the API
│   └── persona/          platform headers of the personas (blns_<persona>.h)
├── src/
│   ├── belenos.c         init and build detection, mode, size, orientation, frame
│   │                     pointers, refresh, page flip, LUT, interrupts, debug freeze
│   ├── blns_gpu.c        GPU: drawing, x/y and effects, lists, fences, errors
│   ├── blns_dbi.c        built-in MIPI-DBI transport: bus, power and reset pins,
│   │                     commands, full-screen fill, scanline / TE sync
│   ├── blns_dpi.c        built-in MIPI-DPI driver: panel timing presets, image
│   │                     size, position and scaling, picture policy, border, test
│   │                     bars, detect, HDMI mode (InfoFrames, audio, packets)
│   ├── blns_ddc.c        HDMI DDC: the I2C master in software, the EDID read and
│   │                     parser
│   ├── blns_hotplug.c    HDMI hot-plug machine (blns_dpi_hotplug_init / _poll)
│   └── blns_priv.h       internals shared by the files above (not the API)
├── panel/
│   └── ili9341.c / .h    ILI9341 panel driver (e.g. the Terasic LT24)
├── lvgl/
│   └── lv_belenos.c / .h LVGL v9 display driver at 16 bpp: CPU, GPU or DIRECT
│                         flush, and a GPU draw unit (LVGL itself is not bundled)
└── test/
    ├── test_driver.c     host unit test against a register / VRAM / GPU model
    ├── test_lvgl.c       host test of lv_belenos.c with LVGL v9.6 (make lvgl)
    ├── blns_model_impl.h the model (one copy per test program)
    ├── blns_model.h      routes the GPU_CMD stores to the model
    ├── lvgl/lv_conf.h    LVGL's configuration of test_lvgl.c
    └── Makefile          make -C sw/test
```

| Layer | Files | Use it for |
|---|---|---|
| Registers | `belenos_regs.h` | direct register access; every other layer is built on it |
| Controller | `belenos.h`, `src/*.c` | everything Belenos does, independent of the panel |
| Panel | `panel/*.c` | the start-up sequence and window commands of one panel type, on top of the DBI transport (a DPI panel needs none: its timing is a `blns_dpi_timing_t`) |
| LVGL | `lvgl/lv_belenos.c` | an LVGL v9 display on Belenos at 16 bpp, with an optional GPU draw unit: see [lvgl/README.md](lvgl/README.md) |

---

## Using it

- **Build**: add `src/belenos.c` and `src/blns_gpu.c`, the files of the build's display
  driver and the two include directories `include/` and `panel/` to the application
  ([build](../doc/driver_guide.md#1-build)); a board with a fixed configuration names a
  [platform header](../doc/driver_guide.md#21-platform-header-optional).
- **Start**: `blns_init`, the depth, the size and the frame pointer, then the display's
  bring-up ([quick start](../doc/driver_guide.md#31-quick-start),
  [bring-up](../doc/driver_guide.md#8-bring-up)).
- **Reference**: `include/belenos.h` documents each function; the
  [API summary](../doc/driver_guide.md#7-api-summary) lists them by area.
- **Tests**: `make -C sw/test` (host unit test) and `make -C sw/test -j8 lvgl` (LVGL host
  test) ([driver host tests](../doc/verification_guide.md#3-driver-host-tests)).
