#!/bin/sh
# Lock: hotplug + cron ga boleh bareng jalan. Kalau lock udah dipegang (ada yang jalan), skip.
exec 9>/var/lock/adb_tether.lock
flock -n 9 || exit 0

CONFIG="/etc/adb_tether.conf"
LOG="/var/log/adb_tether.log"
STATE_DIR="/var/run/adb_tether"
MAX_FAIL=3      # 3 siklus berturut-turut tanpa IP -> reboot HP via ADB
COOLDOWN=300    # skip 5 menit setelah reboot HP (tunggu HP boot penuh)
mkdir -p "$STATE_DIR"

echo "$(date): Watchdog started" >> $LOG

[ -f "$CONFIG" ] || exit 0

adb start-server >> $LOG 2>&1

in_cooldown() {
    f="$STATE_DIR/cooldown_$1"
    [ -f "$f" ] || return 1
    until=$(cat "$f" 2>/dev/null)
    now=$(date +%s)
    [ "$now" -lt "$until" ]
}

get_fail() { f="$STATE_DIR/fail_$1"; [ -f "$f" ] && cat "$f" || echo 0; }
set_fail() { echo "$2" > "$STATE_DIR/fail_$1"; }

connected=$(adb devices | grep -w "device" | awk '{print $1}')

for serial in $connected; do
    target_iface=$(grep "^$serial=" "$CONFIG" | cut -d'=' -f2)
    [ -z "$target_iface" ] && continue
    echo "$(date): Processing $serial -> $target_iface" >> $LOG

    current_func=$(adb -s "$serial" shell getprop sys.usb.config | tr -d '\r')
    echo "$(date): Current USB func for $serial is $current_func" >> $LOG

    case "$current_func" in
        *rndis*)
            echo "$(date): RNDIS already active" >> $LOG
            ;;
        *)
            echo "$(date): Enabling RNDIS..." >> $LOG

            # Coba 1: setFunctions rndis,adb (Android baru)
            adb -s "$serial" shell "svc usb setFunctions rndis,adb" >> $LOG 2>&1
            sleep 2
            check_func=$(adb -s "$serial" shell getprop sys.usb.config | tr -d '\r')
            if echo "$check_func" | grep -q "rndis"; then
                echo "$(date): Success via setFunctions" >> $LOG
            else
                # Coba 2: setFunction rndis (Android lama)
                echo "$(date): Retrying via setFunction..." >> $LOG
                adb -s "$serial" shell "svc usb setFunction rndis" >> $LOG 2>&1
                sleep 2
                check_func2=$(adb -s "$serial" shell getprop sys.usb.config | tr -d '\r')
                if echo "$check_func2" | grep -q "rndis"; then
                    echo "$(date): Success via setFunction" >> $LOG
                else
                    # Semua gagal (misal Samsung block) — skip, lanjut rename interface
                    echo "$(date): RNDIS commands failed (device may not support it via ADB), skipping setFunction" >> $LOG
                fi
            fi

            sleep 3
            ;;
    esac

    # Find and rename interface
    for usb_dir in /sys/bus/usb/devices/*; do
        if [ -f "$usb_dir/serial" ]; then
            usb_serial=$(cat "$usb_dir/serial" 2>/dev/null)
            if [ "$usb_serial" = "$serial" ]; then
                net_dir=$(ls -d $usb_dir/*/net/* 2>/dev/null | head -n 1)
                if [ -n "$net_dir" ]; then
                    current_iface=$(basename "$net_dir")
                    if [ "$current_iface" != "$target_iface" ]; then
                        echo "$(date): Renaming $current_iface to $target_iface" >> $LOG
                        if ip link show "$target_iface" >/dev/null 2>&1; then
                            echo "$(date): ERROR - Target $target_iface already exists!" >> $LOG
                        else
                            ip link set dev "$current_iface" down
                            ip link set dev "$current_iface" name "$target_iface"
                            ip link set dev "$target_iface" up
                            echo "$(date): Renamed successfully" >> $LOG
                        fi
                    else
                        ip link set dev "$target_iface" up
                    fi
                fi
            fi
        fi
    done

    # === IP watchdog: tether stuck (RNDIS aktif tapi no IP) -> reboot HP via ADB ===
    if in_cooldown "$serial"; then
        echo "$(date): $serial in cooldown (HP abis reboot), skip IP check" >> $LOG
        continue
    fi

    IP=$(ip -4 addr show "$target_iface" 2>/dev/null | grep -o 'inet [0-9.]*' | awk '{print $2}')
    if [ -n "$IP" ]; then
        [ "$(get_fail "$serial")" != "0" ] && echo "$(date): $serial IP recovered ($IP), fail counter cleared" >> $LOG
        set_fail "$serial" 0
    else
        FAIL=$(get_fail "$serial")
        FAIL=$((FAIL + 1))
        set_fail "$serial" "$FAIL"
        echo "$(date): $serial ($target_iface) NO IP, fail $FAIL/$MAX_FAIL" >> $LOG

        if [ "$FAIL" -ge "$MAX_FAIL" ]; then
            echo "$(date): Tether stuck -> REBOOTING $serial via adb" >> $LOG
            if adb -s "$serial" reboot >> $LOG 2>&1; then
                echo $(( $(date +%s) + COOLDOWN )) > "$STATE_DIR/cooldown_$serial"
                set_fail "$serial" 0
                echo "$(date): Reboot sent, cooldown ${COOLDOWN}s" >> $LOG
            else
                echo "$(date): ERROR: adb reboot gagal untuk $serial" >> $LOG
                set_fail "$serial" 0
            fi
        fi
    fi
done
