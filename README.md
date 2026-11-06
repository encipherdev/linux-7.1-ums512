# Linux 7.1 Mainline for Samsung Galaxy Tab A8 10.5 (SM-X200 / SM-X207)

Linux 7.1.0-rc1 mainline kernel bring-up for Samsung Galaxy Tab A8 10.5 (2021) based on the Unisoc Tiger T618 SoC (`ums512_25c10` / `sharkl5pro`).

> **Current Milestone: Native Linux Desktop Booting**  
> Boots native Ubuntu 24.04 LTS (Noble Numbat) arm64 on the internal eMMC (`/dev/mmcblk3p56`) directly into a full KDE Plasma Wayland session with hardware-accelerated 3D rendering (Panfrost Mali-G52 MC2), native 1200x1920 @ 60 Hz KMS display, and responsive 10-point multi-touch (Novatek NT36523B TDDI).

---

## Hardware Status

| Subsystem | Component | Status | Details |
|---|---|---|---|
| **Bootloader Handoff** | Stock Samsung LK | ✅ Working | Relocated 2 MiB stub (`reloc.S`), AVB 64 MiB hash footer, `dtbo-noop.img` |
| **Display (KMS)** | Unisoc DPU r4p0 | ✅ Working | Native atomic KMS driver (`ums512_dpu_kms.c`), adopts LK MIPI-DSI, native 1200x1920 @ 60 Hz |
| **3D Acceleration** | Mali-G52 MC2 | ✅ Working | `panfrost` (`card1` / `renderD128`), paired with DPU KMS (`card0`) under Wayland / KWin |
| **Touchscreen** | Novatek NT36523B TDDI | ✅ Working | SPI2 (`0x70a00000`, `spi2.1`), autoloads `nt36523b_qc_inx_fw.bin`, 10-point multi-touch |
| **USB Peripheral** | MUSB / CDC ACM | ✅ Working | USB Gadget serial console on host `/dev/ttyACM0` (`/dev/ttyGS0` device) |
| **Fuel Gauge / Battery** | SC2730 FGU | ⚠️ In Progress | DT node mapped (`sprd,sc2730-fgu` @ `0x4002e000`), battery monitoring driver in progress |
| **USB Host / OTG** | MUSB Dual-Role | ⚠️ In Progress | Controller mapped; Type-C VBUS role switching under test |
| **Audio** | SC2730 Codec + AW88266 | ❌ WIP | SIPC/AGDSP loads; machine sound card and codec DAI links pending |
| **Wi-Fi / Bluetooth** | Unisoc Marlin3-Lite (SC2355) | ❌ WIP | WCN bus probes; SDIO DT nodes and cfg80211 driver (`sprdwl_ng`) port pending |

See **`tools/gta8-bringup/BRINGUP-NOTES.md`** for detailed register maps, errata, timing fixes, and driver architecture.

---

## Repository Structure

- `arch/arm64/boot/dts/sprd/ums512-samsung-gta8.dts`: Target device tree (touchscreen, DPU, GPU, PMIC, memory reserves).
- `arch/arm64/boot/dts/sprd/ums512.dtsi`: SoC core dtsi (SPI2, DPU, HSIC/PHY, clocks, interrupts).
- `arch/arm64/configs/gta8_defconfig`: Dedicated defconfig (256 MiB CMA, DPU KMS, Panfrost, Novatek TS, no top-DVFS).
- `drivers/gpu/drm/sprd/ums512_dpu_kms.c`: Native DRM KMS driver for Unisoc DPU r4p0.
- `drivers/input/touchscreen/novatek_nt36xxx/`: Novatek NT36523B SPI touchscreen driver with Samsung-specific trimming.
- `tools/gta8-bringup/`:
  - `build.sh`: Orchestrates kernel build, initramfs packing, and image packaging.
  - `mkbootimg-gta8.sh`: Packages `boot.img` with LK-compliant header, DTB table, reloc stub, and AVB footer.
  - `initramfs-init`: Lightweight bring-up init script (auto-detects rootfs on eMMC `/dev/mmcblk3p56`, handles fallback shell).
  - `BRINGUP-NOTES.md`: Comprehensive bring-up documentation and hardware notes.

---

## Building and Flashing

### 1. Host Dependencies
Cross compiler (`aarch64-linux-gnu-gcc`), `bc`, `cpio`, `gzip`, `python3`, `mkbootimg`, `mkdtboimg`, `avbtool` (`android-tools`), `adb`.

### 2. Neutralise Stock DTBO (One-time step)
Stock Samsung LK merges overlays from the `dtbo` partition that reference vendor kernel 4.14 nodes and crash mainline. Flash the empty matching dtbo table once:
```bash
tools/gta8-bringup/build.sh --flash-dtbo
```
*(Automatically backs up stock dtbo to `dtbo-stock-backup.img` before writing)*.

### 3. Build & Flash Kernel
With the tablet connected in recovery mode (`adb root`):
```bash
tools/gta8-bringup/build.sh --flash
```
This builds `Image`, compiles `sprd/ums512-samsung-gta8.dtb`, packages `boot-gta8.img` with AVB signature, and flashes `/dev/block/by-name/boot`.

---

## Userspace & Wayland Setup (KDE Plasma on Ubuntu 24.04)

The rootfs is placed on partition 56 of the internal eMMC (`/dev/mmcblk3p56`, or `/dev/block/mmcblk0p56` in recovery).

### Environment Configuration (`/etc/environment`)
To ensure KWin / Wayland correctly binds to the DPU KMS scanout while dispatching 3D rendering to Panfrost:
```bash
KWIN_DRM_DEVICES=/dev/dri/card0
KWIN_FORCE_SW_CURSOR=1
KWIN_DRM_USE_MODIFIERS=0
QT_QPA_PLATFORM=wayland;xcb
```

### Touchscreen Firmware
Place Novatek firmware files in `/lib/firmware/`:
- `nt36523b_qc_inx_fw.bin` (symlinked as `novatek_ts_fw.bin`)
- `nt36523b_qc_inx_mp.bin`
