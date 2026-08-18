#!/bin/sh
CONFIG="/etc/adb_tether.conf"
touch "$CONFIG"

toggle_cron() {
    if grep -q "adb_watchdog.sh" /etc/crontabs/root 2>/dev/null; then
        sed -i '/adb_watchdog.sh/d' /etc/crontabs/root
        echo "Watchdog (Cron): OFF"
    else
        echo '* * * * * /usr/bin/adb_watchdog.sh' >> /etc/crontabs/root
        echo "Watchdog (Cron): ON"
    fi
    /etc/init.d/cron restart
}

while true; do
    echo "=== Menu ADB Tethering ==="
    echo "1. List Attached ADB Devices"
    echo "2. Set Device to usb0/usb1 and Auto RNDIS"
    echo "3. Show Configured Devices"
    echo "4. Remove Device Configuration"
    echo "5. Trigger Watchdog Sekarang"
    echo "6. Toggle (On/Off) Watchdog Cron"
    echo "7. Lihat Log"
    echo "0. Exit"
    read -p "Pilih: " choice

    case $choice in
        1)
            adb devices
            ;;
        2)
            read -p "Masukkan Serial Device: " sn
            read -p "Pilih interface tujuan (cth: usb0 / usb1): " iface
            grep -v "^$sn=" "$CONFIG" > "$CONFIG.tmp"; mv "$CONFIG.tmp" "$CONFIG"
            echo "$sn=$iface" >> "$CONFIG"
            echo "Tersimpan: $sn -> $iface"
            ;;
        3)
            cat "$CONFIG"
            ;;
        4)
            read -p "Masukkan Serial Device untuk dihapus: " sn
            grep -v "^$sn=" "$CONFIG" > "$CONFIG.tmp"; mv "$CONFIG.tmp" "$CONFIG"
            echo "Dihapus."
            ;;
        5)
            echo "Menjalankan watchdog manual..."
            /usr/bin/adb_watchdog.sh
            echo "Selesai."
            ;;
        6)
            toggle_cron
            ;;
        7)
            tail -n 20 /var/log/adb_tether.log 2>/dev/null || echo "Belum ada log."
            ;;
        0) exit 0 ;;
        *) echo "Salah." ;;
    esac
    echo ""
done