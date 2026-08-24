#!/bin/sh
# Dependency: iw, jq (optional), uci

CONFIG_FILE="/etc/wifi_sta.conf"
touch "$CONFIG_FILE"

get_stations() {
    echo "Scanning WiFi networks..."
    iw dev phy0-sta0 scan 2>/dev/null | grep -E "^BSS|SSID:|signal:|freq:" | awk '
    /^BSS/{bss=$2; sig=""; ssid=""; freq=""}
    /signal:/{sig=$2}
    /freq:/{freq=$2}
    /SSID:/{ssid=substr($0, index($0,$2))}
    /^BSS/ && last_bss!="" {print last_sig"|"last_freq"|"last_bssid"|"last_ssid}
    {last_bss=bss; last_sig=sig; last_freq=freq; last_ssid=ssid}
    END {if(last_bss!="") print last_sig"|"last_freq"|"last_bssid"|"last_ssid}
    ' | sort -r | head -n 15
}

list_saved() {
    echo "=== Saved WiFi Networks ==="
    i=1
    while IFS='=' read -r ssid pass; do
        echo "  $i. SSID: $ssid"
        i=$((i+1))
    done < "$CONFIG_FILE"
}

connect_wifi() {
    read -p "Enter SSID: " ssid
    read -p "Enter Password (leave blank if open): " pass
    
    # Save to config
    grep -v "^$ssid=" "$CONFIG_FILE" > "$CONFIG_FILE.tmp"; mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    echo "$ssid=$pass" >> "$CONFIG_FILE"
    
    # Apply to OpenWrt
    uci set wireless.wwan=wifi-iface
    uci set wireless.wwan.device='radio0'
    uci set wireless.wwan.network='wwan'
    uci set wireless.wwan.mode='sta'
    uci set wireless.wwan.ssid="$ssid"
    if [ -z "$pass" ]; then
        uci set wireless.wwan.encryption='none'
        uci delete wireless.wwan.key 2>/dev/null
    else
        uci set wireless.wwan.encryption='psk2'
        uci set wireless.wwan.key="$pass"
    fi
    uci commit wireless
    
    echo "Connecting to $ssid..."
    ifdown wwan
    sleep 1
    wifi reload
    sleep 5
    ifup wwan
    sleep 5
    
    if ip addr show phy0-sta0 | grep -q "inet "; then
        echo "Success: Connected to $ssid"
    else
        echo "Failed: Could not get IP. Check password or signal."
    fi
}

connect_saved() {
    list_saved
    read -p "Select number to connect: " num
    ssid=$(sed -n "${num}p" "$CONFIG_FILE" | cut -d'=' -f1)
    pass=$(sed -n "${num}p" "$CONFIG_FILE" | cut -d'=' -f2)
    
    if [ -z "$ssid" ]; then
        echo "Invalid selection."
        return
    fi
    
    uci set wireless.wwan.ssid="$ssid"
    if [ -z "$pass" ]; then
        uci set wireless.wwan.encryption='none'
        uci delete wireless.wwan.key 2>/dev/null
    else
        uci set wireless.wwan.encryption='psk2'
        uci set wireless.wwan.key="$pass"
    fi
    uci commit wireless
    echo "Connecting to $ssid..."
    ifdown wwan; sleep 1; ifup wwan; sleep 5
    
    if ip addr show phy0-sta0 | grep -q "inet "; then
        echo "Success: Connected to $ssid"
    else
        echo "Failed: Could not get IP."
    fi
}

disconnect_wifi() {
    echo "Disconnecting WiFi STA..."
    ifdown wwan
    uci set wireless.wwan.disabled='1'
    uci commit wireless
    wifi reload
    echo "WiFi STA Disabled."
}

status_wifi() {
    echo "=== WiFi STA Status ==="
    iw dev phy0-sta0 link 2>/dev/null
    echo ""
    ip addr show phy0-sta0 | grep inet
}

while true; do
    echo "=== Menu WiFi STA ==="
    echo "1. Scan & List Networks"
    echo "2. Connect to New WiFi"
    echo "3. Connect to Saved WiFi"
    echo "4. Disconnect & Disable STA"
    echo "5. Status STA"
    echo "0. Exit"
    read -p "Pilih: " choice

    case $choice in
        1) get_stations ;;
        2) connect_wifi ;;
        3) connect_saved ;;
        4) disconnect_wifi ;;
        5) status_wifi ;;
        0) exit 0 ;;
        *) echo "Salah." ;;
    esac
    echo ""
done