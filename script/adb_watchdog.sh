#!/bin/sh
CONFIG="/etc/adb_tether.conf"
LOG="/var/log/adb_tether.log"
echo "$(date): Watchdog started" >> $LOG

[ -f "$CONFIG" ] || exit 0

adb start-server >> $LOG 2>&1
connected=$(adb devices | grep -w "device" | awk '{print $1}')

for serial in $connected; do
    target_iface=$(grep "^$serial=" "$CONFIG" | cut -d'=' -f2)
    if [ -n "$target_iface" ]; then
        echo "$(date): Processing $serial -> $target_iface" >> $LOG
        
        # Check current RNDIS state
        current_func=$(adb -s "$serial" shell getprop sys.usb.config | tr -d '\r')
        echo "$(date): Current USB func for $serial is $current_func" >> $LOG
        
        case "$current_func" in
            *rndis*)
                echo "$(date): RNDIS already active" >> $LOG
                ;;
            *)
                echo "$(date): Enabling RNDIS..." >> $LOG
                # Format penulisan di OS HP berbeda. Android baru pakai setFunction.
                adb -s "$serial" shell "svc usb setFunction rndis true || svc usb setFunction rndis,adb || setprop sys.usb.config rndis,adb" >> $LOG 2>&1
                sleep 7 # Tunggu HP re-connect sbg USB Network
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
    fi
done