# Linux 7.1 Mainline for Samsung Galaxy Tab A8 10.5 (SM-X200)

Linux 7.1.0-rc1 mainline kernel bring-up for Samsung Galaxy Tab A8 10.5 (2021) with Unisoc Tiger T618 (`ums512_25c10` / `sharkl5pro`).

> **Status: Experimental Bring-Up (WIP)**
> Boots to an initramfs shell with a native KMS display driver.

---

## Status

| Area | State |
|---|---|
| Boot via stock LK | ✅ (needs the packaging in `tools/gta8-bringup/mkbootimg-gta8.sh` and a no-op dtbo) |
| Display (DPU + bootloader-initialised DSI) | ✅ native KMS driver `ums512_dpu_kms.c` |
| GPU (Mali-G52, panfrost) | ⚠️ probes; render-only, needs userspace pairing with the KMS device |
| USB gadget (ACM shell) | ✅ initramfs root shell on host `/dev/ttyACM0` |
| Wi-Fi / Bluetooth | ❌ WCN BSP only, no Wi-Fi driver, no DT |
| Audio | ❌ codec disabled, no machine card |
| Touchscreen | ❌ not mapped |

Details, root causes and TODOs: **`tools/gta8-bringup/BRINGUP-NOTES.md`**.

## 📁 Key Files
- **Device Tree:** `arch/arm64/boot/dts/sprd/ums512-samsung-gta8.dts`
- **Defconfig:** `arch/arm64/configs/gta8_defconfig`
- **Bring-up Scripts & Notes:** `tools/gta8-bringup/` (`build.sh`, `mkbootimg-gta8.sh`, `BRINGUP-NOTES.md`)
- **Display driver:** `drivers/gpu/drm/sprd/ums512_dpu_kms.c`

## 🛠️ Build & flash
```bash
tools/gta8-bringup/build.sh --flash-dtbo   # once: back up stock dtbo, flash the no-op one
tools/gta8-bringup/build.sh --flash        # build Image + DTB + initramfs, package boot.img, flash
```
The device must be in recovery with root adb. Restore the stock dtbo and boot
image before booting Android.
