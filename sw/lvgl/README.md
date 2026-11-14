<p align="center">
  <img src="../../doc/img/aRVern_light.png" alt="aRVern" width="180">
</p>

# Belenos LVGL driver

*`lv_belenos.c`, an LVGL v9 display driver for Belenos at 16 bpp, with an optional GPU
draw unit, built on the [driver library](../README.md).*

The guide — configuration, flush modes, the GPU draw unit, faults, contexts, build and
host test — is [doc/lvgl_guide.md](../../doc/lvgl_guide.md).

---

## Layout

```
sw/lvgl/
├── lv_belenos.h          the API: lv_belenos_config_t, lv_belenos_create, lv_belenos_flush_cb,
│                         the extensions' options (LV_BELENOS_USE_*) and lv_belenos_drop_images
└── lv_belenos.c          the display (CPU, GPU or DIRECT flush) and the GPU draw unit
```

LVGL itself is not bundled; the host test is `sw/test/test_lvgl.c` with its
`sw/test/lvgl/lv_conf.h`.

---

## Using it

- **Set-up**: Belenos first, with the driver library (`blns_init`, 16 bpp, size, frame
  pointer, the display's bring-up), then `lv_init` and `lv_belenos_create`
  ([overview](../../doc/lvgl_guide.md#1-overview)).
- **Build**: `lv_belenos.c` with LVGL v9 and its `lv_conf.h`, LVGL's root directory on the
  include path ([build](../../doc/lvgl_guide.md#7-build)).
- **Blending**: with the GPU's blending, opacities, RGB565A8 images and (with the pool)
  labels and ARGB8888 images are drawn exactly (the GPU's MIX5 rule is LVGL's).
- **Extensions**: rounded shapes, a VRAM pool (staged images, glyphs, layers) and, opt-in,
  the GPU's gradients and rotated or scaled images (approximate: `cfg.approx`), each a
  build option off by default ([extensions](../../doc/lvgl_guide.md#42-extensions)).
- **Reference**: `lv_belenos.h` documents the driver in full; the reference integration
  is the arvern-soc `lvgl_demo` (Tang Console).
