# Linux 7.1 Mainline for Samsung Galaxy Tab A8 10.5 (SM-X200)

Linux 7.1.0-rc1 mainline kernel bring-up for Samsung Galaxy Tab A8 10.5 (2021) with Unisoc Tiger T618 (`ums512_25c10` / `sharkl5pro`).

## Current Status
- Boots to userspace using SimpleFB and earlycon
- Framebuffer handoff and DRM display pipeline active
- 8x CPUs (2x Cortex-A75 + 6x Cortex-A55) brought up
- Tested with Debian rootfs and sxmo/wayland user environments

## Key Files
- **Device Tree:** `arch/arm64/boot/dts/sprd/ums512-samsung-gta8.dts`
- **Defconfig:** `arch/arm64/configs/gta8_defconfig`
- **Bring-up Scripts & Fixes:** `tools/gta8-bringup/`

## Compilation
```bash
make ARCH=arm64 gta8_defconfig
make -j$(nproc) ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- Image dtbs
```
