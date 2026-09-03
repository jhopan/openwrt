#!/bin/sh
# Watchdog untuk WiFi STA (Client) — v2
# Fix v2:
#   - Delay awal 90s setelah boot: radio wireless belum tentu siap saat
#     watchdog mulai; ifdown/ifup keburu-keburu bikin wpa INTERFACE_DISABLED
#   - Deteksi INTERFACE_DISABLED -> recovery pakai ubus wireless down/up
#     (ifdown/ifup wwan biasa ga bisa nembus state disabled)
#   - Backoff: kalau recovery gagal, jeda makin panjang (30s -> 120s -> 300s)
INTERFACE="phy0-sta0"
NETWORK="wwan"
LOG="/var/log/wifi_watchdog.log"
FAILS=0

log() { echo "$(date): $*" >> $LOG; }

wifi_full_restart() {
    log "Recovery penuh radio via ubus (wpa stuck INTERFACE_DISABLED)"
    ubus call network.wireless down '{"name":"radio0"}' >> $LOG 2>&1
    sleep 3
    ubus call network.wireless up '{"name":"radio0"}' >> $LOG 2>&1
    sleep 12
}

wpa_disabled() {
    wpa_cli -i $INTERFACE status 2>/dev/null | grep -q "wpa_state=INTERFACE_DISABLED"
}

# Boot grace — jangan sentuh wifi sebelum wireless bringup selesai
sleep 90

while true; do
    # Cek apakah dapat IP DHCP
    IP=$(ip addr show $INTERFACE 2>/dev/null | grep -o 'inet [0-9.]*' | awk '{print $2}')

    if [ -z "$IP" ]; then
        if wpa_disabled; then
            log "No IP + wpa INTERFACE_DISABLED -> full radio restart"
            wifi_full_restart
        else
            log "No IP on $INTERFACE, reconnecting..."
            ifdown $NETWORK
            sleep 2
            ifup $NETWORK
            sleep 10
        fi
        FAILS=$((FAILS + 1))
    else
        # Cek internet (ping ke gateway)
        GATEWAY=$(ip route show dev $INTERFACE | grep default | awk '{print $3}')
        if [ -n "$GATEWAY" ]; then
            if ! ping -c 1 -W 3 $GATEWAY > /dev/null 2>&1; then
                if wpa_disabled; then
                    log "No gateway + wpa INTERFACE_DISABLED -> full radio restart"
                    wifi_full_restart
                else
                    log "No gateway ping, reconnecting..."
                    ifdown $NETWORK
                    sleep 2
                    ifup $NETWORK
                    sleep 10
                fi
                FAILS=$((FAILS + 1))
            else
                FAILS=0
            fi
        else
            FAILS=0
        fi
    fi

    # Backoff kalau gagal terus
    if [ "$FAILS" -ge 6 ]; then
        SLEEP=300
    elif [ "$FAILS" -ge 3 ]; then
        SLEEP=120
    else
        SLEEP=30
    fi
    sleep $SLEEP
done
