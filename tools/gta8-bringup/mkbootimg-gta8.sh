#!/usr/bin/env bash
# Package a mainline kernel into a boot.img the SM-X200/X207 (UMS512) LK accepts.
#
# Requirements discovered from the LK (uboot_log) on this device:
#  * LK always jumps to 0x80080000. Mainline arm64 (text_offset=0) must start
#    2MB-aligned, so a 4K stub (reloc.S) with a stock-style header
#    (text_offset=0x80000) moves the kernel to the next 2MB boundary.
#  * The v2 "dtb" section must be an Android DT table (mkdtboimg, magic
#    d7b7ab1e) whose total_size equals the header's dtb_size (no padding).
#  * LK loads boot.img into DDR using the AVB footer's original_image_size,
#    so the image must carry its own AVB footer for the 64MB partition,
#    otherwise anything past the old footer's size (e.g. the DTB) is garbage
#    -> "invalid dtb partition / load dt error!" and an instant reset.
#  * LK merges the dtbo partition into our DT. Flash a no-op dtbo
#    (dtbo-noop.img, same sprd,sc-id/board_id 0x1100) or the stock Android
#    overlay corrupts the mainline DT and the kernel dies silently.
#
# usage: mkbootimg-gta8.sh <Image> <dtb> <initramfs.cpio.gz> <out.img> [cmdline]
set -euo pipefail
IMG=$1 DTB=$2 RD=$3 OUT=$4
CMDLINE=${5:-"console=tty0 console=ttyS1,115200n8 loglevel=7 rdinit=/init panic=0 cma=256M"}
HERE="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

aarch64-linux-gnu-as "$HERE/reloc.S" -o "$T/reloc.o"
aarch64-linux-gnu-objcopy -O binary "$T/reloc.o" "$T/reloc.bin"
python3 - "$T" "$IMG" <<'EOF'
import struct, subprocess, sys
t, img = sys.argv[1], sys.argv[2]
stub = bytearray(open(t + '/reloc.bin', 'rb').read()); stub += b'\0' * (4096 - len(stub))
k = bytearray(open(img, 'rb').read()); k += b'\0' * ((-len(k)) % 16)
off = {l.split()[2]: int(l.split()[0], 16) for l in
       subprocess.check_output(['aarch64-linux-gnu-nm', t + '/reloc.o']).decode().splitlines()}
assert off['payload'] == 4096
ks = struct.unpack('<Q', k[16:24])[0]
struct.pack_into('<Q', stub, off['payload_size'], len(k))
struct.pack_into('<Q', stub, 16, 0x200000 + max(ks, len(k)))
open(t + '/Image.reloc', 'wb').write(stub + k)
EOF

mkdtboimg create "$T/dtb.tab" --page_size=2048 "$DTB"
python3 - "$T/dtb.tab" <<'EOF'
import struct, sys
f = sys.argv[1]; d = open(f, 'rb').read()
open(f, 'wb').write(d[:struct.unpack('>I', d[4:8])[0]])
EOF

mkbootimg --header_version 2 --os_version 12.0.0 --os_patch_level 2099-12 \
	--kernel "$T/Image.reloc" --ramdisk "$RD" --dtb "$T/dtb.tab" \
	--pagesize 2048 --base 0 --kernel_offset 0x8000 --ramdisk_offset 0x05400000 \
	--tags_offset 0x100 --dtb_offset 0x01f00000 --cmdline "$CMDLINE" -o "$OUT"
avbtool add_hash_footer --image "$OUT" --partition_name boot \
	--partition_size 67108864 --algorithm NONE
echo "wrote $OUT (flash the whole 64MB image to the boot partition)"
