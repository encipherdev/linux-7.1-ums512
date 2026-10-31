# Linux 7.1 Mainline for Samsung Galaxy Tab A8 10.5 (SM-X200)

Linux 7.1.0-rc1 mainline kernel bring-up for Samsung Galaxy Tab A8 10.5 (2021) with Unisoc Tiger T618 (`ums512_25c10` / `sharkl5pro`).

> **Status: Experimental Bring-Up (WIP)**
> Boots to Linux userspace with earlycon and SimpleFB.

---

## 🐛 Documented Bugs & Issues to Fix

### 1. SimpleFB Display Glitches & Color Inversion
- **Symptom:** Display shows image with visible horizontal striping, color channel swapping (BGR vs RGB), and stride artifacts across the 1200x1920 panel.
- **Root Cause:** Bootloader framebuffer at `0x9e000000` is handed off with a specific stride and format that needs exact alignment in the simple-framebuffer DT node (`stride = <(1200 * 4)>`, `format = "x8r8g8b8"`).
- **Userspace Fix Attempt:** `tools/gta8-bringup/drm_fix.c` intercepts DRM ioctls to compensate for framebuffer stride discrepancies.

### 2. Native DRM / DPU Driver Missing in Mainline
- **Symptom:** No hardware-accelerated 2D/3D compositing; relies purely on software rasterization via SimpleFB.
- **Next Step:** Port the Unisoc `sprd_disp` DRM driver (DPU1 + DPHY) from the vendor tree to modern Linux 7.x DRM KMS interfaces.

### 3. Touchscreen Controller Driver
- **Symptom:** Incell touchscreen input is not mapped in mainline DTS.
- **Next Step:** Map the Goodix / FocalTech / Chipone incell touch I2C bus and interrupt lines into `ums512-samsung-gta8.dts`.

---

## 📁 Key Files
- **Device Tree:** `arch/arm64/boot/dts/sprd/ums512-samsung-gta8.dts`
- **Defconfig:** `arch/arm64/configs/gta8_defconfig`
- **Bring-up Scripts & Fixes:** `tools/gta8-bringup/`

## 🛠️ Build
```bash
make ARCH=arm64 gta8_defconfig
make -j$(nproc) ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- Image dtbs
```
