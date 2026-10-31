#!/usr/bin/env bash
# tablet_console.sh - Samsung Galaxy Tab A8 Ekran Terminali Yönetim Aracı

set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$1" in
    send|type)
        shift
        if [ -z "$*" ]; then
            echo "Kullanım: ./tablet_console.sh send \"komut\""
            exit 1
        fi
        adb shell "deb-console $*"
        echo "Komut tablet ekranındaki terminale gönderildi ve çalıştırıldı."
        ;;
    view|screen|capture)
        echo "=== Tablet Ekranındaki Terminalin Güncel Görüntüsü ==="
        adb shell "chroot /data/debian /usr/bin/env PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin tmux capture-pane -p -t console"
        ;;
    ssh)
        adb forward tcp:2222 tcp:2222 2>/dev/null || true
        echo "SSH üzerinden konsola bağlanılıyor..."
        ssh -p 2222 -t root@127.0.0.1 "tmux attach -t console"
        ;;
    *)
        echo "================================================================="
        echo "  Samsung Galaxy Tab A8 - Canlı Ekran Terminali (Debian 12)     "
        echo "================================================================="
        echo "  * Buraya yazacağın her şey tablet ekranında ANINDA görünür.    "
        echo "  * Ayrılmak için: Ctrl+B sonra D (detach) tuşla.                "
        echo "================================================================="
        echo ""
        adb shell -t deb-console
        ;;
esac
