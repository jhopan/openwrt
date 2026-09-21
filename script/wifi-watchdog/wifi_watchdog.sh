#!/bin/sh
# Watchdog WiFi STA (phy0-sta0) — v3 SELF-HEALING
# Perubahan v3 (satu-satunya):
#   - Lapis recovery baru: kalau ifdown/ifup gagal 3x berturut, reload driver
#     rtl8189fs (rmmod + modprobe + wifi up) — satu2nya obat buat TX buffer
#     habis (free_xmitbuf_cnt: 0), terbukti 2026-09-21.
#
# BATAS SENTUHAN:
#   - Cuma radio0/phy0-sta0 (wifi dev) + interface wwan (DHCP client)
#   - GA nyentuh: br-lan, eth0, usb0, wwan0 (modem), tailscale, openclash,
#     firewall, crontab, service lain. wifi reload radio0 = SDIO wifi doang.
#
INTERFACE="phy0-sta0"
NETWORK="wwan"
DRIVER="8189fs"
LOG="/var/log/wifi_watchdog.log"
FAILS=0
DRV_FAILS=0

log() { echo "$(date): $*" >> $LOG; }

wifi_full_restart() {
    log "Recovery penuh radio via ubus (wpa stuck INTERFACE_DISABLED)"
    ubus call network.wireless down '{"name":"radio0"}' >> $LOG 2>&1
    sleep 3
    ubus call network.wireless up '{"name":"radio0"}' >> $LOG 2>&1
    sleep 12
}

driver_reload() {
    log "FAILS>=3 -> DRIVER RELOAD $DRIVER (TX buffer leak suspect)"
    wifi down >> $LOG 2>&1
    sleep 2
    rmmod $DRIVER >> $LOG 2>&1
    sleep 2
    modprobe $DRIVER >> $LOG 2>&1
    sleep 2
    wifi up >> $LOG 2>&1
    sleep 15
    # netifd kadang butuh re-fire DHCP abis re-enumerate
    ifdown $NETWORK >> $LOG 2>&1
    sleep 2
    ifup $NETWORK >> $LOG 2>&1
    sleep 15
    DRV_FAILS=$((DRV_FAILS + 1))
    # Kalau 2x reload driver pun masih gagal -> backoff panjang, jangan spam
    if [ "$DRV_FAILS" -ge 2 ]; then
        log "Driver reload 2x masih gagal — menyerah cycle ini, tunggu 10 menit"
        sleep 600
        DRV_FAILS=0
    fi
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
        elif [ "$FAILS" -ge 3 ]; then
            driver_reload
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
                elif [ "$FAILS" -ge 3 ]; then
                    driver_reload
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
                DRV_FAILS=0
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
