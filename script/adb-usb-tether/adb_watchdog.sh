#!/bin/sh
# === adb_watchdog.sh — menuadb watchdog v3 ===
# Fitur:
#   - flock guard (cron + hotplug ga bareng)
#   - per-device flag: SERIAL=IFACE (rndis) atau SERIAL=IFACE:norndis (skip rndis)
#   - auto-detect device ADB online yang ga terdaftar -> naming-only (no rndis)
#   - pipe-stall check: delta TX naik + RX diam
#   - ladder recovery STRICT:
#       stall 3 siklus -> adb reboot HP -> tunggu 3 menit -> cek
#       masih stall & adb konek -> reboot HP lagi, max 3x
#       habis 3x -> STB reboot (flag persisten, maksimal 1x seumur hidup)
#       ADB offline padahal kabel nancep -> STB reboot (setelah 3 siklus)
#   - STB reboot flag: /etc/adb_tether_stb_rebooted (hapus manual untuk reset)

# Lock: hotplug + cron ga boleh bareng jalan. Kalau lock udah dipegang, skip.
exec 9>/var/lock/adb_tether.lock
flock -n 9 || exit 0

CONFIG="/etc/adb_tether.conf"
AUTO_CONFIG="/etc/adb_tether_auto.conf"
LOG="/var/log/adb_tether.log"
STATE_DIR="/var/run/adb_tether"
STB_FLAG="/etc/adb_tether_stb_rebooted"

MAX_FAIL=3        # siklus stall sebelum mulai ladder
HP_REBOOT_MAX=3   # max adb reboot HP sebelum STB reboot
HP_COOLDOWN=180   # tunggu 3 menit setelah adb reboot HP
mkdir -p "$STATE_DIR"

# Gabung CONFIG + AUTO_CONFIG ke satu file tmp (ash ga support process substitution)
ALLDEV="$STATE_DIR/all_devices.tmp"
cat "$CONFIG" "$AUTO_CONFIG" > "$ALLDEV" 2>/dev/null

log() { echo "$(date): $*" >> $LOG; }
log "Watchdog started"

[ -f "$CONFIG" ] || exit 0
touch "$AUTO_CONFIG"

adb start-server >> $LOG 2>&1

# ---------- helpers ----------
in_cooldown() {
    f="$STATE_DIR/cooldown_$1"
    [ -f "$f" ] || return 1
    [ "$(date +%s)" -lt "$(cat "$f" 2>/dev/null)" ]
}
set_cooldown() { echo $(( $(date +%s) + $2 )) > "$STATE_DIR/cooldown_$1"; }
get_state() { f="$STATE_DIR/$1_$2"; [ -f "$f" ] && cat "$f" || echo 0; }
set_state() { echo "$3" > "$STATE_DIR/$1_$2"; }

sysfs_present() {
    # $1=serial — cek HP masih nancep fisik di bus USB
    for d in /sys/bus/usb/devices/*; do
        [ "$(cat "$d/serial" 2>/dev/null)" = "$1" ] && return 0
    done
    return 1
}

stb_reboot() {
    # LAST RESORT — STRICT: maksimal 1x, flag persisten di /etc
    if [ -f "$STB_FLAG" ]; then
        log "STB reboot sudah pernah dicoba. Menyerah. (hapus $STB_FLAG untuk reset hak reboot)"
        return 1
    fi
    log "LAST RESORT: reboot STB (flag persisten ditulis)"
    touch "$STB_FLAG"
    sync
    reboot
}

recovery_ladder() {
    # $1=serial — dipanggil saat stall terkonfirmasi (fail >= MAX_FAIL)
    serial=$1
    hprb=$(get_state hprb "$serial")

    if [ "$hprb" -ge "$HP_REBOOT_MAX" ]; then
        log "$serial: $HP_REBOOT_MAXx reboot HP gagal semua -> STB reboot"
        stb_reboot
        return
    fi

    if adb -s "$serial" get-state 2>/dev/null | grep -q device; then
        hprb=$((hprb + 1))
        set_state hprb "$serial" $hprb
        log "$serial: stall persisten -> adb reboot HP percobaan $hprb/$HP_REBOOT_MAX, tunggu ${HP_COOLDOWN}s"
        if adb -s "$serial" reboot >> $LOG 2>&1; then
            set_cooldown "$serial" $HP_COOLDOWN
            # fail TIDAK direset: kalau setelah cooldown masih stall, langsung ladder lagi
        else
            log "$serial: adb reboot gagal -> langsung STB reboot"
            stb_reboot
        fi
    else
        log "$serial: ADB offline saat ladder -> langsung STB reboot"
        stb_reboot
    fi
}

check_stall() {
    # $1=serial $2=iface — pipe-stall: delta TX naik, delta RX diam
    serial=$1
    iface=$2

    if in_cooldown "$serial"; then
        log "$serial: cooldown (HP abis reboot), skip stall check"
        return
    fi

    # Interface ga ada = tethering off (mtp/cabut) -> bukan stall
    if [ ! -d "/sys/class/net/$iface" ]; then
        set_state fail "$serial" 0
        return
    fi

    RX=$(cat /sys/class/net/$iface/statistics/rx_packets 2>/dev/null); RX=${RX:-0}
    TX=$(cat /sys/class/net/$iface/statistics/tx_packets 2>/dev/null); TX=${TX:-0}
    PRX=$(get_state rx "$serial")
    PTX=$(get_state tx "$serial")
    set_state rx "$serial" $RX
    set_state tx "$serial" $TX

    DRX=$((RX - PRX))
    DTX=$((TX - PTX))
    # Counter reset (interface re-register) -> reset state, jangan hitung
    if [ "$DRX" -lt 0 ] || [ "$DTX" -lt 0 ]; then
        set_state fail "$serial" 0
        return
    fi

    if [ "$DRX" -gt 0 ]; then
        # Ada trafik balik dari HP -> sehat. Reset semua ladder state + flag STB.
        if [ "$(get_state hprb "$serial")" != "0" ] || [ "$(get_state fail "$serial")" != "0" ]; then
            log "$serial: pulih (rx hidup), ladder state direset"
        fi
        set_state fail "$serial" 0
        set_state hprb "$serial" 0
        rm -f "$STB_FLAG"
        return
    fi

    if [ "$DTX" -gt 0 ]; then
        # STB kirim, HP ga pernah balas = pipe satu arah mati
        FAIL=$(get_state fail "$serial")
        FAIL=$((FAIL + 1))
        set_state fail "$serial" $FAIL
        log "$serial ($iface): STALL dtx=$DTX drx=0 (rx=$RX tx=$TX), fail $FAIL/$MAX_FAIL"
        [ "$FAIL" -ge "$MAX_FAIL" ] && recovery_ladder "$serial"
    fi
    # DTX=0 & DRX=0 -> idle, ga dihitung
}

# ---------- auto-detect device ga terdaftar ----------
# Masuk AUTO_CONFIG dengan mode norndis (naming-only + stall check).
connected=$(adb devices | grep -w "device" | awk '{print $1}')
for serial in $connected; do
    grep -q "^$serial=" "$CONFIG" && continue
    grep -q "^$serial=" "$AUTO_CONFIG" && continue
    # cari interface usbN yang bebas
    target=""
    for n in 0 1 2 3 4; do
        cand="usb$n"
        grep -q "=$cand" "$CONFIG" "$AUTO_CONFIG" 2>/dev/null && continue
        ip link show "$cand" >/dev/null 2>&1 && continue
        target=$cand
        break
    done
    [ -z "$target" ] && { log "AUTO: ga ada interface bebas untuk $serial"; continue; }
    echo "$serial=$target:norndis" >> "$AUTO_CONFIG"
    log "AUTO: $serial -> $target (naming-only, rndis SKIP)"
done

# ---------- loop utama: CONFIG + AUTO_CONFIG ----------
while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in \#*) continue ;; esac

    serial=${line%%=*}
    rest=${line#*=}
    target_iface=${rest%%:*}
    if [ "$rest" = "$target_iface" ]; then
        rndis_flag="rndis"        # default: auto rndis (backward compat)
    else
        rndis_flag=${rest##*:}    # "norndis"
    fi
    [ -z "$target_iface" ] && continue

    # Skip kalau ADB ga online buat serial ini (diurus blok offline di bawah)
    echo "$connected" | grep -qw "$serial" || continue

    log "Processing $serial -> $target_iface (mode: $rndis_flag)"

    # === RNDIS block — HANYA kalau flag rndis ===
    if [ "$rndis_flag" = "rndis" ]; then
        current_func=$(adb -s "$serial" shell getprop sys.usb.config | tr -d '\r')
        log "Current USB func for $serial is $current_func"

        case "$current_func" in
            *rndis*)
                log "RNDIS already active"
                ;;
            *)
                log "Enabling RNDIS..."
                adb -s "$serial" shell "svc usb setFunctions rndis,adb" >> $LOG 2>&1
                sleep 2
                check_func=$(adb -s "$serial" shell getprop sys.usb.config | tr -d '\r')
                if echo "$check_func" | grep -q "rndis"; then
                    log "Success via setFunctions"
                else
                    log "Retrying via setFunction..."
                    adb -s "$serial" shell "svc usb setFunction rndis" >> $LOG 2>&1
                    sleep 2
                    check_func2=$(adb -s "$serial" shell getprop sys.usb.config | tr -d '\r')
                    if echo "$check_func2" | grep -q "rndis"; then
                        log "Success via setFunction"
                    else
                        log "RNDIS commands failed (device block?), skipping setFunction"
                    fi
                fi
                sleep 3
                ;;
        esac
    else
        log "$serial: mode norndis — setFunction DILEWATI"
    fi

    # === Penamaan interface (SELALU jalan, semua mode) ===
    for usb_dir in /sys/bus/usb/devices/*; do
        if [ -f "$usb_dir/serial" ]; then
            usb_serial=$(cat "$usb_dir/serial" 2>/dev/null)
            if [ "$usb_serial" = "$serial" ]; then
                net_dir=$(ls -d $usb_dir/*/net/* 2>/dev/null | head -n 1)
                if [ -n "$net_dir" ]; then
                    current_iface=$(basename "$net_dir")
                    if [ "$current_iface" != "$target_iface" ]; then
                        log "Renaming $current_iface to $target_iface"
                        if ip link show "$target_iface" >/dev/null 2>&1; then
                            log "ERROR - Target $target_iface already exists!"
                        else
                            ip link set dev "$current_iface" down
                            ip link set dev "$current_iface" name "$target_iface"
                            ip link set dev "$target_iface" up
                            log "Renamed successfully"
                        fi
                    else
                        ip link set dev "$target_iface" up
                    fi
                fi
            fi
        fi
    done

    # === Stall check + ladder (semua mode) ===
    check_stall "$serial" "$target_iface"

done < "$ALLDEV"

# ---------- device terdaftar tapi ADB offline ----------
# Kabel masih nancep (sysfs present) tapi adb mati -> 3 siklus -> STB reboot.
# Kabel beneran dicabut -> diem, ga dihitung.
for line in $(cat "$CONFIG" "$AUTO_CONFIG" 2>/dev/null); do
    serial=${line%%=*}
    [ -z "$serial" ] && continue
    echo "$connected" | grep -qw "$serial" && { set_state off "$serial" 0; continue; }

    sysfs_present "$serial" || { set_state off "$serial" 0; continue; }

    in_cooldown "$serial" && continue

    OFF=$(get_state off "$serial")
    OFF=$((OFF + 1))
    set_state off "$serial" $OFF
    log "$serial: ADB OFFLINE padahal kabel nancep, off-fail $OFF/$MAX_FAIL"

    if [ "$OFF" -ge "$MAX_FAIL" ]; then
        # ADB offline = adb reboot ga mungkin -> langsung last resort
        log "$serial: adb ga bisa dipakai -> STB reboot"
        stb_reboot
    fi
done
