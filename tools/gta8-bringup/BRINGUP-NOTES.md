# Galaxy Tab A8 (SM-X200/X207, UMS512 / T618) — Mainline Bring-Up Notes

Kernel-side status, hardware findings, and register-level errata for Linux 7.1.0-rc1 mainline bring-up.

---

## 1. Building and Booting

```bash
tools/gta8-bringup/build.sh --flash-dtbo   # once per device (backs up stock dtbo first)
tools/gta8-bringup/build.sh --flash        # build + package + flash boot (device in recovery, adb root)
```

`build.sh` builds `Image` + `ums512-samsung-gta8.dtb`, packs the initramfs (`initramfs-init` + static busybox) and calls `mkbootimg-gta8.sh`.

### Samsung/Unisoc LK Boot Requirements (Verified from `uboot_log`)

| Requirement | Symptom if violated |
|---|---|
| v2 `dtb` section is an **Android DT table** (`mkdtboimg`, magic `d7b7ab1e`) whose `total_size` equals the header `dtb_size` (no padding) | `invalid dtb partition` / `load dt error!` → instant reset |
| boot.img carries **its own AVB hash footer** for the 64 MiB partition and is flashed whole. LK loads only `original_image_size` bytes into DDR | Anything past the stale footer's size (e.g. the DTB) is garbage → same instant reset |
| **dtbo partition neutralised** (`dtbo-noop.img`, `sprd,sc-id = "ums512 25c10 1000"`, id `0x1100`). LK merges the matching dtbo into our DT; the stock overlay references 4.14 labels | Kernel hangs before any console (Samsung logo forever) |
| Kernel relocated to a 2 MiB boundary. LK always jumps to `0x80080000`; mainline `text_offset=0` needs 2 MiB alignment. `reloc.S` is a 4 KiB stub with a stock-style header (`text_offset=0x80000`) that copies the kernel to the next 2 MiB boundary | Undefined / early hang |
| DT `sprd,sc-id = "ums512 1000 1000"` (same as the stock base DTB) | — |

LK ignores the header load addresses: kernel → `0x80080000`, ramdisk → `0xa0000000`, DT → `0x83f00000`.

Restore `dtbo-stock-backup.img` to `dtbo` (and a stock/Android boot.img) before booting Android again.

### Debugging without UART

- The mainline `ramoops@fff80000` matches the stock kernel's, so after a mainline boot, reboot to recovery and read `adb shell cat /sys/fs/pstore/console-ramoops-0`.
- The LK log is in the `uboot_log` partition: `adb shell 'dd if=/dev/block/by-name/uboot_log bs=1M' | strings`.
- The initramfs init writes `initdbg:` lines to `/dev/kmsg` (hence pstore).
- USB: `g_serial` (CDC ACM) → host `/dev/ttyACM0`, root shell. The UDC binds ~4 s into boot.

---

## 2. Display (DPU r4p0 + DSI) — WORKING (Native 60 Hz)

Driver: `drivers/gpu/drm/sprd/ums512_dpu_kms.c` (`CONFIG_DRM_UMS512_DPU`), DT node `display@20300000` (`sprd,ums512-dpu-kms`). Replaces `DRM_SPRD` in `gta8_defconfig`.

- **Adopts** the MIPI-DSI link + panel initialised by the bootloader (video burst mode, 4 lanes). The mode timings are read back directly from hardware registers `PANEL_SIZE` (`0x00`) and `DPI_H/V_TIMING` (`0x04` / `0x08`).
- **60 Hz Pixel Clock Fix:** In hardware, `dpi_clk` is a divided internal clock (~76–80 MHz). Reading `clk_get_rate(dpi_clk)` caused DRM to compute an incorrect ~30 Hz mode. The driver now enforces native 60 Hz pixel clock calculation:
  ```c
  m->clock = DIV_ROUND_UP((unsigned long)m->htotal * m->vtotal * 60, 1000);
  ```
- **CMA Memory Allocation:** CMA size increased to 256 MiB (`CONFIG_CMA_SIZE_MBYTES=256`) in `gta8_defconfig` to accommodate double/triple-buffered 1200x1920 ARGB8888 scanout buffers across multiple hardware planes.
- 4 hardware layers → 1 primary + 3 overlay planes (immutable zpos, alpha, blend mode), XRGB/ARGB/XBGR/ABGR8888, RGB/BGR565.
- Atomic commits latched with `REG_UPDATE`; vblank from `INT_VSYNC`, flip completion from `INT_UPDATE_DONE`; `commit_tail_rpm` ordering.
- CMA (`drm_gem_dma`) buffers, 32-bit DMA mask; display IOMMU (VAU at `+0x800`) put in bypass.
- DPU AXI QoS (`CFG1`/`CFG2`) programmed with the vendor values.
- `framebuffer0` (simple-framebuffer) is disabled; the KMS driver reads its `reg` to evict any early fb via aperture helpers.

### Root Cause of the DPU FIFO Underflow Bug

The DPU reported layer FIFO underflows on every frame when `sprd_top_dvfs` probed because Top-DVFS scaled the bus clocks down without a display driver vote. `CONFIG_ARM_SPRD_TOP_DVFS` remains disabled in `gta8_defconfig`.

---

## 3. GPU (Mali-G52 MC2, Panfrost) — WORKING

- Probes cleanly: `panfrost 60000000.gpu: mali-g52 id 0x7402`, 2 shader cores, core clock 384 MHz, OPP table `gpu_opp_table`.
- DRM nodes:
  - `card0`: `ums512-dpu` (KMS modeset, display scanout)
  - `card1` + `renderD128`: `panfrost` (render-only 3D acceleration)
- **Wayland / KWin Desktop Pairing:**
  In `/etc/environment`:
  ```bash
  KWIN_DRM_DEVICES=/dev/dri/card0
  KWIN_FORCE_SW_CURSOR=1
  KWIN_DRM_USE_MODIFIERS=0
  ```
  KWin uses `card0` as the primary modeset device and automatically dispatches OpenGL/EGL rendering to `renderD128` (Panfrost). Software cursor avoids DPU cursor plane mismatch.

---

## 4. Touchscreen (Novatek NT36523B TDDI) — WORKING

Driver: `drivers/input/touchscreen/novatek_nt36xxx/` (`CONFIG_TOUCHSCREEN_NT36XXX_HOSTDL_SPI`), DT node `touchscreen@1` under `&spi2` (`0x70a00000`).

- **Hardware Specs:** Novatek NT36523B TDDI controller embedded in Inx / BOE panel, 1200x1920 native resolution, 10-touch multi-touch.
- **Bus & Signaling:**
  - SPI2 bus (`0x70a00000`, `spi2.1`), `max_speed_hz = 9600000`, SPI mode 0.
  - IRQ GPIO: 416 (`irq_flags = 0x2001`, active low / falling edge).
  - Reset GPIO: 417 (`active low`).
- **Bring-up & Fixes:**
  - **SPI Controller CS Conflict:** In `spi-sprd.c`, hardware slave select was conflicting with driver-managed CS GPIOs. Bypassed `gpio_cs` so `spi-sprd` native hardware CS drives the chip select cleanly.
  - **Chip ID & Verification:** Successfully identifies PID `0x723A` and trim `0x0365230B`.
  - **Firmware Loading:** Autoloads `nt36523b_qc_inx_fw.bin` from `/lib/firmware/` via `request_firmware()`, handles bootloader handoff and normal touch reporting.

---

## 5. Battery & Fuel Gauge (SC2730 FGU) — IN PROGRESS

- DT node `fgu@4002e000` added under the SC2730 PMIC SPI child bus (`sc2730.dtsi` / `ums512-samsung-gta8.dts`).
- Uses `sprd,sc2730-fgu` compatible string.
- Currently reading battery cell parameters and calibrating ADC fuelgauge curves.

---

## 6. USB Peripheral & Host (MUSB) — IN PROGRESS

- Peripheral mode: `dr_mode = "peripheral"` active, providing CDC ACM serial console (`/dev/ttyGS0`) on host `/dev/ttyACM0`.
- Host / OTG mode: MUSB dual-role controller mapped with `vbus-supply = <&usb_otg_vbus>`. `pmic_typec_pd` is disabled to prevent calibration hangs; autonomous VBUS role switching is being verified.

---

## 7. Wi-Fi / Bluetooth (Marlin3-Lite SC2355 over SDIO) — WIP

- `drivers/net/wireless/sprdwcn/` (`CONFIG_UNISOC_WCN_BSP`): trimmed vendor BSP (bus, SDIO HAL, boot, sleep). Probes (`WCN BOOT: sprd_wcn_init entry!`).
- **No Wi-Fi netdev driver yet**: the vendor `sprdwl_ng` (cfg80211) driver must be ported to 7.x APIs.
- Bluetooth: `CONFIG_BT_SPRDSDIO=y` is built and awaits the WCN SDIO bus bring-up.
- Needed: Board DTS SDIO nodes (`sprd-wlan`, `sprd-marlin3` with GPIOs, clocks, regulator supplies) and vendor firmware (`wcnmodem.bin`).

---

## 8. Audio — WIP

- AGDSP access and audio SIPC (`sprd-aud-agdsp`, `aud_ipc_init`) probe; `CONFIG_SPRD_AUDCP_BOOT` loads the AUDCP firmware.
- The SC2730 codec node is currently disabled.
- Needed: Enable codec in `sc2730.dtsi`, wire DAI links to the I2C smart amplifier (AW88266), and provide AUDCP DSP firmware.
