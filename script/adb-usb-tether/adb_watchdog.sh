#!/bin/sh
# === adb_watchdog.sh — menuadb watchdog v5 ===
# ATATAN KERAS: JANGAN PERNAH reboot STB. Recovery = adb reboot HP saja.
# Habis 3x reboot HP gagal -> menyerah + log, tunggu intervensi manual.
#
# Fitur:
#   - flock guard (cron + hotplug ga bareng)
#   - per-device flag: SERIAL=IFACE (rndis) atau SERIAL=IFACE:norndis
#   - auto-detect device ADB online ga terdaftar -> naming-only (no rndis)
#   - pipe-stall check: delta TX naik + RX diam
#   - ladder STRICT: stall 3 siklus -> adb reboot HP -> tunggu 3 menit ->
#     cek lagi -> masih stall & adb konek -> reboot HP lagi, max 3x -> menyerah
#   - ADB offline + kabel nancep -> restart adb server dulu; kalau tetap
#     offline beruntun -> log menyerah (TIDAK ada aksi reboot apapun)
#   - BOOT_GRACE 180s + MIN_GAP 50s: anti false-positive saat STB boot

# Start adb server sebelum lock dibuka agar daemon tidak mewarisi fd lock
command adb start-server >/dev/null 2>&1

# Lock: hotplug + cron ga boleh bareng jalan.
exec 9>/var/lock/adb_tether.lock
flock -n 9 || exit 0

# Tutup fd 9 untuk semua pemanggilan adb agar daemon child ga pernah nahan lock
adb() {
    command adb "$@" 9>&-
}

CONFIG="/etc/adb_tether.conf"
AUTO_CONFIG="/etc/adb_tether_auto.conf"
LOG="/var/log/adb_tether.log"
STATE_DIR="/var/run/adb_tether"

MAX_FAIL=3        # siklus (berjarak) sebelum mulai ladder
HP_REBOOT_MAX=3   # max adb reboot HP, habis itu MENYERAH
HP_COOLDOWN=180   # tunggu 3 menit setelah adb reboot HP
MIN_GAP=50        # minimal jarak antar increment counter (detik)
BOOT_GRACE=180    # 3 menit pertama setelah STB boot: ga ada aksi reboot
mkdir -p "$STATE_DIR"

# Gabung CONFIG + AUTO_CONFIG (ash ga support process substitution)
ALLDEV="$STATE_DIR/all_devices.tmp"
cat "$CONFIG" "$AUTO_CONFIG" > "$ALLDEV" 2>/dev/null

log() { echo "$(date): $*" >> $LOG; }
log "Watchdog started"

[ -f "$CONFIG" ] || exit 0
touch "$AUTO_CONFIG"

adb start-server >> $LOG 2>&1

# ---------- helpers ----------
uptime_s() { awk '{print int($1)}' /proc/uptime; }

in_boot_grace() { [ "$(uptime_s)" -lt "$BOOT_GRACE" ]; }

in_cooldown() {
    f="$STATE_DIR/cooldown_$1"
    [ -f "$f" ] || return 1
    [ "$(date +%s)" -lt "$(cat "$f" 2>/dev/null)" ]
}
set_cooldown() { echo $(( $(date +%s) + $2 )) > "$STATE_DIR/cooldown_$1"; }
get_state() { f="$STATE_DIR/$1_$2"; [ -f "$f" ] && cat "$f" || echo 0; }
set_state() { echo "$3" > "$STATE_DIR/$1_$2"; }

# bump_counter <nama> <serial> — increment HANYA jika >= MIN_GAP sejak
# increment terakhir. Echo nilai baru jika increment, return 1 jika diabaikan.
bump_counter() {
    name=$1; serial=$2
    last=$(get_state lastbump_$name "$serial")
    now=$(date +%s)
    if [ $((now - last)) -lt "$MIN_GAP" ]; then
        return 1
    fi
    echo "$now" > "$STATE_DIR/lastbump_${name}_$serial"
    FAIL=$(get_state "$name" "$serial")
    FAIL=$((FAIL + 1))
    set_state "$name" "$serial" $FAIL
    echo "$FAIL"
    return 0
}

sysfs_present() {
    for d in /sys/bus/usb/devices/*; do
        [ "$(cat "$d/serial" 2>/dev/null)" = "$1" ] && return 0
    done
    return 1
}

recovery_ladder() {
    # $1=serial — stall terkonfirmasi (fail >= MAX_FAIL)
    serial=$1
    hprb=$(get_state hprb "$serial")

    # Udah menyerah? Diem sampai pulih (cek_stall reset flag ini saat rx hidup)
    if [ -f "$STATE_DIR/gaveup_$serial" ]; then
        return
    fi

    if [ "$hprb" -ge "$HP_REBOOT_MAX" ]; then
        log "$serial: $HP_REBOOT_MAXx adb reboot HP GAGAL semua -> MENYERAH, butuh cek fisik (kabel/port/HP). STB TIDAK akan di-reboot."
        touch "$STATE_DIR/gaveup_$serial"
        return
    fi

    if adb -s "$serial" get-state 2>/dev/null | grep -q device; then
        hprb=$((hprb + 1))
        set_state hprb "$serial" $hprb
        log "$serial: stall persisten -> adb reboot HP percobaan $hprb/$HP_REBOOT_MAX, tunggu ${HP_COOLDOWN}s"
        if adb -s "$serial" reboot >> $LOG 2>&1; then
            set_cooldown "$serial" $HP_COOLDOWN
        else
            log "$serial: adb reboot gagal dikirim -> MENYERAH (STB TIDAK di-reboot)"
            touch "$STATE_DIR/gaveup_$serial"
        fi
    else
        log "$serial: ADB ga konek saat ladder -> ga bisa adb reboot, MENYERAH (STB TIDAK di-reboot)"
        touch "$STATE_DIR/gaveup_$serial"
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
    if [ "$DRX" -lt 0 ] || [ "$DTX" -lt 0 ]; then
        set_state fail "$serial" 0
        return
    fi

    if [ "$DRX" -gt 0 ]; then
        if [ "$(get_state hprb "$serial")" != "0" ] || [ "$(get_state fail "$serial")" != "0" ] || [ -f "$STATE_DIR/gaveup_$serial" ]; then
            log "$serial: pulih (rx hidup), ladder state direset"
        fi
        set_state fail "$serial" 0
        set_state hprb "$serial" 0
        rm -f "$STATE_DIR/gaveup_$serial"
        return
    fi

    if [ "$DTX" -gt 0 ]; then
        FAIL=$(bump_counter fail "$serial") || return
        log "$serial ($iface): STALL dtx=$DTX drx=0 (rx=$RX tx=$TX), fail $FAIL/$MAX_FAIL"
        [ "$FAIL" -ge "$MAX_FAIL" ] && recovery_ladder "$serial"
    fi
}

# ---------- auto-detect device ga terdaftar ----------
connected=$(adb devices | grep -w "device" | awk '{print $1}')
for serial in $connected; do
    grep -q "^$serial=" "$CONFIG" && continue
    grep -q "^$serial=" "$AUTO_CONFIG" && continue
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
        rndis_flag="rndis"
    else
        rndis_flag=${rest##*:}
    fi
    [ -z "$target_iface" ] && continue

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
                # Coba 1: setFunctions rndis,adb (Android baru/standar)
                adb -s "$serial" shell "svc usb setFunctions rndis,adb" >> $LOG 2>&1
                sleep 2
                check_func=$(adb -s "$serial" shell getprop sys.usb.config | tr -d '\r')
                if echo "$check_func" | grep -q "rndis"; then
                    log "Success via setFunctions rndis,adb"
                else
                    # Coba 2: setFunctions rndis (Android 10 ColorOS/MediaTek)
                    log "Retrying via setFunctions rndis..."
                    adb -s "$serial" shell "svc usb setFunctions rndis" >> $LOG 2>&1
                    sleep 2
                    check_func2=$(adb -s "$serial" shell getprop sys.usb.config | tr -d '\r')
                    if echo "$check_func2" | grep -q "rndis"; then
                        log "Success via setFunctions rndis"
                    else
                        # Coba 3: setFunction rndis (Android lama tanpa s)
                        log "Retrying via setFunction..."
                        adb -s "$serial" shell "svc usb setFunction rndis" >> $LOG 2>&1
                        sleep 2
                        check_func3=$(adb -s "$serial" shell getprop sys.usb.config | tr -d '\r')
                        if echo "$check_func3" | grep -q "rndis"; then
                            log "Success via setFunction"
                        else
                            log "RNDIS commands failed (device block?), skipping setFunction"
                        fi
                    fi
                fi
                sleep 3
                ;;
        esac
    else
        log "$serial: mode norndis — setFunction DILEWATI"
    fi

    # === Penamaan interface (SELALU jalan) ===
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

    # === Stall check + ladder ===
    check_stall "$serial" "$target_iface"

done < "$ALLDEV"

# ---------- device terdaftar tapi ADB offline ----------
# Kabel nancep (sysfs present) tapi adb ga online:
#   1. coba restart adb server dulu (throttle 5 menit)
#   2. tetap offline beruntun 3 siklus -> log menyerah. TITIK.
#   (TIDAK ada adb reboot — adb offline ga bisa — dan TIDAK ada STB reboot)
for line in $(cat "$ALLDEV" 2>/dev/null); do
    serial=${line%%=*}
    [ -z "$serial" ] && continue
    echo "$connected" | grep -qw "$serial" && { set_state off "$serial" 0; rm -f "$STATE_DIR/gaveup_off_$serial"; continue; }
    sysfs_present "$serial" || { set_state off "$serial" 0; continue; }
    in_cooldown "$serial" && continue

    # Grace boot: ADB emang belum siap di 3 menit pertama — jangan increment
    if in_boot_grace; then
        log "$serial: ADB belum online tapi STB baru boot ($(uptime_s)s) — nunggu, ga dihitung"
        continue
    fi

    # Udah menyerah? Diem.
    [ -f "$STATE_DIR/gaveup_off_$serial" ] && continue

    # Coba selamatkan dulu: restart adb server (throttle 5 menit)
    LASTKILL=$(get_state adbkill "$serial")
    NOW=$(date +%s)
    if [ $((NOW - LASTKILL)) -ge 300 ]; then
        echo "$NOW" > "$STATE_DIR/adbkill_$serial"
        log "$serial: ADB offline, coba restart adb server dulu"
        adb kill-server >> $LOG 2>&1
        adb start-server >> $LOG 2>&1
        sleep 3
        adb -s "$serial" get-state 2>/dev/null | grep -q device && {
            log "$serial: ADB pulih setelah restart server"
            set_state off "$serial" 0
            continue
        }
    fi

    OFF=$(bump_counter off "$serial") || continue
    log "$serial: ADB OFFLINE padahal kabel nancep, off-fail $OFF/$MAX_FAIL"

    if [ "$OFF" -ge "$MAX_FAIL" ]; then
        log "$serial: ADB offline beruntun, adb reboot ga bisa. MENYERAH — butuh cek fisik (kabel/port/HP). STB TIDAK di-reboot."
        touch "$STATE_DIR/gaveup_off_$serial"
    fi
done
