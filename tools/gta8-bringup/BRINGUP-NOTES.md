# Galaxy Tab A8 (SM-X200/X207, UMS512 / T618) — mainline bring-up notes

Kernel-side status and findings. Rootfs/userspace bring-up is out of scope here.

## 1. Building and booting

```
tools/gta8-bringup/build.sh --flash-dtbo   # once per device (backs up stock dtbo first)
tools/gta8-bringup/build.sh --flash        # build + package + flash boot (device in recovery, adb root)
```

`build.sh` builds `Image` + `ums512-samsung-gta8.dtb`, packs the initramfs
(`initramfs-init` + static busybox) and calls `mkbootimg-gta8.sh`.

### What the Samsung/Unisoc LK requires (all verified from its `uboot_log`)

| Requirement | Symptom if violated |
|---|---|
| v2 `dtb` section is an **Android DT table** (`mkdtboimg`, magic `d7b7ab1e`) whose `total_size` equals the header `dtb_size` (no padding) | `invalid dtb partition` / `load dt error!` → instant reset |
| boot.img carries **its own AVB hash footer** for the 64 MiB partition and is flashed whole. LK loads only `original_image_size` bytes into DDR | Anything past the stale footer's size (e.g. the DTB) is garbage → same instant reset |
| **dtbo partition neutralised** (`dtbo-noop.img`, `sprd,sc-id = "ums512 25c10 1000"`, id `0x1100`). LK merges the matching dtbo into our DT; the stock overlay references 4.14 labels | Kernel hangs before any console (Samsung logo forever) |
| Kernel relocated to a 2 MiB boundary. LK always jumps to `0x80080000`; mainline `text_offset=0` needs 2 MiB alignment. `reloc.S` is a 4 KiB stub with a stock-style header (`text_offset=0x80000`) that copies the kernel to the next 2 MiB boundary | Undefined / early hang |
| DT `sprd,sc-id = "ums512 1000 1000"` (same as the stock base DTB) | — |

LK ignores the header load addresses: kernel → `0x80080000`, ramdisk →
`0xa0000000`, DT → `0x83f00000`.

Restore `dtbo-stock-backup.img` to `dtbo` (and a stock/Android boot.img)
before booting Android again.

### Debugging without UART

- The mainline `ramoops@fff80000` matches the stock kernel's, so after a
  mainline boot, reboot to recovery and read
  `adb shell cat /sys/fs/pstore/console-ramoops-0`.
- The LK log is in the `uboot_log` partition:
  `adb shell 'dd if=/dev/block/by-name/uboot_log bs=1M' | strings`.
  It is a ring of several boots; search for `start linux`, `invalid dtb`,
  `merge_dtbo`, `boot count = (...)`.
- The initramfs init writes `initdbg:` lines to `/dev/kmsg` (hence pstore).
- USB: `g_serial` (CDC ACM) → host `/dev/ttyACM0`, root shell. The UDC binds
  ~4 s into boot.

### Initramfs gotchas

The bundled busybox (`KernelSU/.../aarch64/busybox`) is a static **bionic**
binary: no `getty`, and it aborts with `getentropy failed` if
`/dev/urandom` does not exist before the CRNG is ready (≈10 s). `build.sh`
uses `usr/gen_init_cpio` to put device nodes into the archive. `/proc` must
be mounted before `busybox --install`.

## 2. Display (DPU r4p0 + DSI) — WORKING

Driver: `drivers/gpu/drm/sprd/ums512_dpu_kms.c` (`CONFIG_DRM_UMS512_DPU`),
DT node `display@20300000` (`sprd,ums512-dpu-kms`). Replaces `DRM_SPRD` in
`gta8_defconfig`.

- **Adopts** the MIPI-DSI link + panel the bootloader initialised (video
  burst mode, 4 lanes). Re-initialising DSI from Linux never produced a
  picture (see the old `sprd_dpu.c`/`sprd_dsi.c` comments), and the board
  ships six panel variants selected by LK (`lcd_name=` on the cmdline, e.g.
  `lcd_nt36523b_qc_inx_mipi_hdp`), so the mode is read back from
  `PANEL_SIZE` / `DPI_H/V_TIMING`.
- 4 hardware layers → 1 primary + 3 overlay planes (immutable zpos, alpha,
  blend mode), XRGB/ARGB/XBGR/ABGR8888, RGB/BGR565.
- Atomic commits latched with `REG_UPDATE`; vblank from `INT_VSYNC`,
  flip completion from `INT_UPDATE_DONE`; `commit_tail_rpm` ordering.
- CMA (`drm_gem_dma`) buffers, 32-bit DMA mask; display IOMMU (VAU at
  `+0x800`) put in bypass.
- DPU AXI QoS (`CFG1`/`CFG2`) programmed with the vendor values.
- "Disabling" the CRTC only blanks the layers: the DSI link/panel cannot be
  restarted from Linux yet, so there is no real DPMS-off / panel power
  management, and no backlight control.
- `framebuffer0` (simple-framebuffer) is disabled; the KMS driver reads its
  `reg` to evict any early fb via the aperture helpers.

### Root cause of the old "only the top part is visible, rest garbage" bug

Not a format/stride problem: the DPU reported **layer FIFO underflow on every
frame** starting right after `sprd_top_dvfs` probed. Top-DVFS scales the core
rail / bus clocks down, and nothing in mainline votes for the display (the
vendor kernel has `sprd_dvfs_dpu` + DDR-DFS `lcdon` scene). With the DPU
starved, each frame runs dry and the panel shows a partial/repeated image.
**`CONFIG_ARM_SPRD_TOP_DVFS` is disabled** in `gta8_defconfig`. Proper fix
(TODO): a DPU devfreq/DVFS consumer or a minimum-level vote before
re-enabling top-DVFS; possibly also the DDR-DFS `lcdon` scene (768 MHz) via the
pm_sys `dfs` SIPC channel (`drivers/rpmsg/sprd_sipc_dfs.c` only has a
debugfs sender today; the protocol is in the vendor
`drivers/devfreq/sprd/sprd_dfs_auto_drv.c`).

## 3. GPU (Mali-G52 MC2, panfrost) — probes; not paired with the display

`panfrost 60000000.gpu: mali-g52 id 0x7402`, 2 shader cores, core clock
384 MHz, OPP table `gpu_opp_table`. (The `bus_clock`/`mem_clock` = 26 MHz
lines are the gate clocks' parent rate, not the shader clock.)

DRM nodes: `card0` = `ums512-dpu` (KMS, no rendering), `card1` +
`renderD128` = panfrost (render only). **The GPU does not drive the panel by
itself**; userspace must combine the two:

- **Mesa kmsro** pairs a KMS-only driver with a render-only GPU, but it only
  matches display drivers whose name is in Mesa's kmsro list. `ums512-dpu`
  is not, so a one-line Mesa patch (or upstreaming the driver name) is
  needed for transparent GBM/EGL scanout.
- **Without patching Mesa**: use a compositor that supports separate
  render/KMS devices (wlroots/sway: `WLR_DRM_DEVICES=/dev/dri/card0`,
  render on `renderD128`; it renders on the GPU and copies each frame into a
  KMS-allocated buffer). Zero-copy import of panfrost buffers into the DPU is
  not possible: the DPU needs physically contiguous memory (no IOMMU in use)
  and panfrost allocates shmem pages.
- The alternative hack — registering the KMS driver under a name Mesa already
  knows — works but is not recommended.
- TODO: GPU DVFS / thermal validation; top-DVFS is currently off, so verify
  the GPU rail is adequate at higher OPPs.

## 4. Wi-Fi / Bluetooth (Marlin3-Lite SC2355 over SDIO) — NOT working

- `drivers/net/wireless/sprdwcn/` (`CONFIG_UNISOC_WCN_BSP`): trimmed vendor
  BSP (bus, SDIO HAL, boot, sleep). Probes (`WCN BOOT: sprd_wcn_init entry!`)
  but the board DTS has no WCN/SDIO node, so nothing is bound.
- **No Wi-Fi netdev driver**: the vendor `sprdwl_ng` (cfg80211) driver is not
  in the tree and must be ported to 7.x cfg80211/netdev APIs.
- Bluetooth: `CONFIG_BT_SPRDSDIO=y` is built but depends on the WCN bus being
  up.
- Needed: DT for the SDIO host the combo chip sits on (vendor
  `ums512-25c10-overlay.dts` / `sharkl5Pro.dtsi`: `sprd-wlan`, `sprd-marlin3`
  nodes with reset/enable GPIOs, clocks, power), firmware from the vendor
  partition (`wcnmodem.bin`, `connectivity_configure.ini`,
  `connectivity_calibration.ini`, `tsx_data`) installed under
  `/lib/firmware`, and the sdiohal tuning delays.

## 5. Audio — NOT working

- AGDSP access / audio SIPC (`sprd-aud-agdsp`, `aud_ipc_init`) probe;
  `CONFIG_SPRD_AUDCP_BOOT` can load the AUDCP firmware.
- The SC2730 codec node is disabled (`node 'unisoc,sc2730-audio-codec' is
  disabled`) and there is no machine card, so ALSA reports
  `No soundcards found`.
- Needed: enable the codec in `sc2730.dtsi`/board DTS with supplies, add the
  machine card from `sprd-sound-fe-be.dtsi` with the board's DAI links
  (speaker amp: check the vendor `Tab_A8_audio.dtsi` for the smart-PA on I2C),
  AUDCP firmware, and verify the `sprd-agdsp` mailbox/IPC path.

## 6. Other

- `CONFIG_SPRD_WATCHDOG` (AP wdt) node disabled in the board DTS for
  bring-up; the PMIC wdt driver (`sc27xx_wdt`) stays to feed a
  bootloader-armed watchdog (in normal mode LK arms it).
- Touchscreen: not mapped yet (see README).
