#!/bin/sh
# Watchdog untuk WiFi STA (Client)
INTERFACE="phy0-sta0"
LOG="/var/log/wifi_watchdog.log"

while true; do
    # Cek apakah dapat IP DHCP
    IP=$(ip addr show $INTERFACE 2>/dev/null | grep -o 'inet [0-9.]*' | awk '{print $2}')
    
    if [ -z "$IP" ]; then
        echo "$(date): No IP on $INTERFACE, reconnecting..." >> $LOG
        ifdown wwan
        sleep 2
        ifup wwan
        sleep 10  # Tunggu DHCP
    else
        # Cek internet (ping ke gateway)
        GATEWAY=$(ip route show dev $INTERFACE | grep default | awk '{print $3}')
        if [ -n "$GATEWAY" ]; then
            if ! ping -c 1 -W 3 $GATEWAY > /dev/null 2>&1; then
                echo "$(date): No gateway ping, reconnecting..." >> $LOG
                ifdown wwan
                sleep 2
                ifup wwan
                sleep 10
            fi
        fi
    fi
    sleep 30
done