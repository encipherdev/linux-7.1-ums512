#!/usr/bin/env bash
# Build mainline for the Galaxy Tab A8 (SM-X200/X207, UMS512) and package a
# bootable boot.img.
#
#   tools/gta8-bringup/build.sh                 build kernel + initramfs + boot.img
#   tools/gta8-bringup/build.sh --flash         ...and flash it (device in recovery, adb root)
#   tools/gta8-bringup/build.sh --flash-dtbo    one-time: flash the no-op dtbo (stock backed up first)
#
# Env overrides: CROSS_COMPILE (default aarch64-linux-gnu-), O (default out),
# INITRAMFS_DIR (default ../initramfs next to the tree), BUSYBOX (static aarch64 busybox),
# OUT_IMG (default boot-gta8.img in the tree root), CMDLINE.
#
# Host tools: aarch64-linux-gnu-gcc/binutils, bc, cpio, gzip, python3,
#             mkbootimg, mkdtboimg, avbtool (android-tools), adb for flashing.
set -euo pipefail
export ANDROID_SERIAL=${ANDROID_SERIAL:-R9PW4053V6W}

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "$HERE/../.." && pwd)"
CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-}
O=${O:-out}
OUT_IMG=${OUT_IMG:-$SRC/boot-gta8.img}
INITRAMFS_DIR=${INITRAMFS_DIR:-$SRC/../initramfs}

if [ -z "${BUSYBOX:-}" ]; then
	for b in "$SRC/../busybox-src/busybox" "$INITRAMFS_DIR/bin/busybox" "$SRC/../enciphered-kernel-4.14/KernelSU/userspace/ksud/bin/aarch64/busybox"; do
		if [ -f "$b" ]; then BUSYBOX="$b"; break; fi
	done
fi
BUSYBOX=${BUSYBOX:-$SRC/../busybox-src/busybox}
DTB_NAME=sprd/ums512-samsung-gta8.dtb
JOBS=$(nproc)

FLASH=0 FLASH_DTBO=0
for a in "$@"; do
	case $a in
	--flash) FLASH=1 ;;
	--flash-dtbo) FLASH_DTBO=1 ;;
	-h|--help) sed -n '2,15p' "$0"; exit 0 ;;
	*) echo "unknown option $a" >&2; exit 1 ;;
	esac
done

need() { command -v "$1" >/dev/null || { echo "missing host tool: $1" >&2; exit 1; }; }
for t in "${CROSS_COMPILE}gcc" "${CROSS_COMPILE}as" bc cpio gzip python3 mkbootimg mkdtboimg avbtool; do need "$t"; done

# --- one-time dtbo ----------------------------------------------------------
if [ $FLASH_DTBO = 1 ]; then
	need adb
	bk="$SRC/dtbo-stock-backup.img"
	if [ ! -f "$bk" ]; then
		echo ">> backing up stock dtbo to $bk"
		adb shell 'cat /dev/block/by-name/dtbo' > "$bk"
	fi
	echo ">> flashing no-op dtbo"
	adb push "$HERE/dtbo-noop.img" /tmp/dtbo-noop.img >/dev/null
	adb shell 'dd if=/tmp/dtbo-noop.img of=/dev/block/by-name/dtbo bs=1M conv=fsync && sync'
	echo "   (restore $bk to the dtbo partition before booting Android)"
fi

# --- kernel -------------------------------------------------------------------
cd "$SRC"
mk() { make ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" O="$O" "$@"; }
echo ">> configuring (gta8_defconfig)"
mk gta8_defconfig >/dev/null
echo ">> building Image + $DTB_NAME"
mk -j"$JOBS" Image "$DTB_NAME"

# --- initramfs ------------------------------------------------------------------
mkdir -p "$INITRAMFS_DIR"/{bin,sbin,dev,proc,sys,tmp,etc,lib,usr/bin,usr/sbin,usr/local/bin,usr/local/lib,mnt,newroot,root}
if [ ! -f "$INITRAMFS_DIR/bin/busybox" ] || [ "${FORCE_BUSYBOX:-0}" = "1" ]; then
	[ -f "$BUSYBOX" ] || { echo "static aarch64 busybox not found; set BUSYBOX=" >&2; exit 1; }
	echo ">> installing busybox into $INITRAMFS_DIR"
	install -m755 "$BUSYBOX" "$INITRAMFS_DIR/bin/busybox"
fi
echo ">> syncing initramfs init and bring-up tools"
install -m755 "$HERE/initramfs-init" "$INITRAMFS_DIR/init"
[ -f "$HERE/libdrm_fix.so" ] && cp "$HERE/libdrm_fix.so" "$INITRAMFS_DIR/usr/local/lib/" && cp "$HERE/libdrm_fix.so" "$INITRAMFS_DIR/lib/"
[ -f "$HERE/start-sxmo" ] && install -m755 "$HERE/start-sxmo" "$INITRAMFS_DIR/usr/local/bin/"
[ -f "$HERE/tablet-rotate" ] && install -m755 "$HERE/tablet-rotate" "$INITRAMFS_DIR/usr/local/bin/"
[ -f "$HERE/tablet-keyboard" ] && install -m755 "$HERE/tablet-keyboard" "$INITRAMFS_DIR/usr/local/bin/"
echo ">> packing initramfs"
RD="$SRC/$O/initramfs.cpio.gz"
# gen_init_cpio so the archive can carry device nodes without root: the bionic
# busybox aborts ("getentropy failed") if /dev/urandom is missing before the
# RNG is ready, i.e. before init gets to mount devtmpfs.
mk usr/gen_init_cpio >/dev/null
LIST="$SRC/$O/initramfs.list"
{
	echo "dir /dev 0755 0 0"
	echo "nod /dev/console 0600 0 0 c 5 1"
	echo "nod /dev/null 0666 0 0 c 1 3"
	echo "nod /dev/zero 0666 0 0 c 1 5"
	echo "nod /dev/random 0666 0 0 c 1 8"
	echo "nod /dev/urandom 0666 0 0 c 1 9"
	echo "nod /dev/kmsg 0644 0 0 c 1 11"
	echo "nod /dev/tty0 0620 0 0 c 4 0"
	(cd "$INITRAMFS_DIR" && find . -mindepth 1 ! -path ./dev ! -path './dev/*' | sort) |
	while read -r f; do
		p=${f#.}; src="$INITRAMFS_DIR$p"
		m=$(stat -c %a "$src")
		if [ -L "$src" ]; then echo "slink $p $(readlink "$src") $m 0 0"
		elif [ -d "$src" ]; then echo "dir $p $m 0 0"
		else echo "file $p $src $m 0 0"; fi
	done
} > "$LIST"
"$SRC/$O/usr/gen_init_cpio" "$LIST" | gzip -9 > "$RD"

# --- boot.img ---------------------------------------------------------------------
echo ">> packaging $OUT_IMG"
"$HERE/mkbootimg-gta8.sh" "$O/arch/arm64/boot/Image" "$O/arch/arm64/boot/dts/$DTB_NAME" \
	"$RD" "$OUT_IMG" ${CMDLINE:+"$CMDLINE"}

# --- flash ------------------------------------------------------------------------
if [ $FLASH = 1 ]; then
	need adb
	echo ">> flashing boot (device must be in recovery with adb root)"
	adb push "$OUT_IMG" /tmp/boot-gta8.img >/dev/null
	adb shell 'dd if=/tmp/boot-gta8.img of=/dev/block/by-name/boot bs=1M conv=fsync && sync'
	adb reboot
	echo "   rebooting; after boot, a root shell is on the host's /dev/ttyACM0"
	echo "   previous boot's kernel log: boot to recovery, adb shell cat /sys/fs/pstore/console-ramoops-0"
fi
echo ">> done"
