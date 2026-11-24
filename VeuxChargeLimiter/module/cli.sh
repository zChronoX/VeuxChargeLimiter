#!/system/bin/sh
# ==============================================================================
# Veux Smart Charge Limiter - Comandi (usati da WebUI e pulsante Azione)
# Uso da terminale root:
#   sh /data/adb/modules/veux_charge_limiter/cli.sh <comando> [argomenti]
# Comandi:
#   status              stato live (chiave=valore)
#   config              configurazione attiva (chiave=valore)
#   set K V [K V ...]   modifica la configurazione (solo chiavi note, interi)
#   toggle K            inverte un'opzione 0/1
#   stats [giorni]      campioni CSV degli ultimi N giorni (default 7)
#   health              storico giornaliero salute batteria (CSV)
#   log [righe]         ultime righe del log (default 60)
#   export              copia CSV e log in /sdcard/VeuxChargeLimiter/
#   reset-stats         azzera statistiche e contatori
#   probe               elenca i nodi di ricarica presenti nel kernel
#   theme               colore del tema Android (Monet) per la WebUI
#   restart             (ri)avvia il demone
# ==============================================================================

MODDIR="${0%/*}"
if [ ! -f "$MODDIR/common.sh" ]; then MODDIR=/data/adb/modules/veux_charge_limiter; fi
# shellcheck source=common.sh
. "$MODDIR/common.sh"

cmd_status() {
    _dp=$(daemon_pid)
    echo "DAEMON=${_dp:-0}"
    echo "VERSION=$(grep '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)"
    if [ -f "$MODDIR/disable" ]; then echo "MAGISK_DISABLED=1"; else echo "MAGISK_DISABLED=0"; fi
    if [ -n "$_dp" ] && [ -f "$STATUS_FILE" ]; then
        cat "$STATUS_FILE"
    else
        # Demone fermo: valori letti direttamente dai nodi
        rd "$CAPACITY_NODE" ""; echo "CAPACITY=$_v"
        rd "$TEMP_NODE" ""; echo "TEMP_DEC=$_v"
        rd "$CURRENT_NOW_NODE" "0"; echo "CURRENT_MA=$((_v / 1000))"
        rd "$VOLTAGE_NOW_NODE" "0"; echo "VOLTAGE_MV=$((_v / 1000))"
        rd "$USB_ONLINE_NODE" ""; echo "USB_ONLINE=$_v"
        rd "$SUSPEND_NODE" ""; echo "INPUT_SUSPEND=$_v"
        rd "$MAX_CURR_NODE" "0"; echo "LIMIT_MA=$((_v / 1000))"
        rdt "$STATUS_NODE" "Unknown"; echo "BAT_STATUS=$_t"
        echo "STATE=STOPPED"
        echo "UPDATED=$(date +%s)"
    fi
    # Dati di salute (letti al volo, economici)
    rd "$SOH_NODE" ""; echo "SOH=$_v"
    rd "$CHARGE_FULL_NODE" "0"; echo "CHARGE_FULL_MAH=$((_v / 1000))"
    rd "$CHARGE_FULL_DESIGN_NODE" "0"; echo "DESIGN_MAH=$((_v / 1000))"
    rd "$CYCLE_COUNT_NODE" ""; echo "CYCLE_COUNT=$_v"
}

cmd_config() {
    _cf=$(active_conf)
    echo "CONF_FILE=$_cf"
    for _k in $CONF_KEYS; do
        echo "$_k=$(conf_get "$_k" "")"
    done
}

cmd_set() {
    [ $# -ge 2 ] || { echo "ERR uso: set CHIAVE VALORE [CHIAVE VALORE ...]"; return 1; }
    # Valida tutto prima di scrivere qualsiasi cosa
    _args="$*"
    while [ $# -ge 2 ]; do
        is_conf_key "$1" || { echo "ERR chiave sconosciuta: $1"; return 1; }
        is_uint "$2" || { echo "ERR valore non valido per $1: $2"; return 1; }
        shift 2
    done
    [ $# -eq 0 ] || { echo "ERR numero di argomenti dispari"; return 1; }
    [ -f "$USER_CONF" ] || cp -f "$MODDIR/config.conf" "$USER_CONF" 2>/dev/null
    # shellcheck disable=SC2086  # split voluto: argomenti già validati
    set -- $_args
    while [ $# -ge 2 ]; do
        conf_set "$1" "$2"
        shift 2
    done
    wake_daemon
    echo "OK"
}

cmd_toggle() {
    is_conf_key "$1" || { echo "ERR chiave sconosciuta: $1"; return 1; }
    _cur=$(conf_get "$1" "0")
    if [ "$_cur" = "1" ]; then _new=0; else _new=1; fi
    cmd_set "$1" "$_new" >/dev/null && echo "$1=$_new"
}

cmd_stats() {
    _days=${1:-7}
    is_uint "$_days" || _days=7
    [ -f "$STATS_CSV" ] || { echo "ts,cap,current_ma,voltage_mv,temp_dec,usb,state,screen"; return 0; }
    head -n 1 "$STATS_CSV"
    # ~288 campioni/giorno a 5 minuti: margine abbondante, il filtro esatto lo fa la WebUI
    tail -n $((_days * 300 + 10)) "$STATS_CSV" | grep -v '^ts,'
}

cmd_health() {
    [ -f "$HEALTH_CSV" ] && cat "$HEALTH_CSV" || echo "date,soh,charge_full_mah,design_mah,cycle_count,pct_in"
}

cmd_log() {
    _n=${1:-60}
    is_uint "$_n" || _n=60
    if [ -f "$LOG_FILE" ]; then tail -n "$_n" "$LOG_FILE"
    elif [ -f "$FALLBACK_LOG" ]; then tail -n "$_n" "$FALLBACK_LOG"
    fi
}

cmd_export() {
    mkdir -p "$EXPORT_DIR" 2>/dev/null || { echo "ERR /sdcard non accessibile"; return 1; }
    _ts=$(date '+%Y%m%d_%H%M')
    [ -f "$STATS_CSV" ] && cp -f "$STATS_CSV" "$EXPORT_DIR/stats_$_ts.csv"
    [ -f "$HEALTH_CSV" ] && cp -f "$HEALTH_CSV" "$EXPORT_DIR/health_$_ts.csv"
    echo "OK $EXPORT_DIR"
}

cmd_reset_stats() {
    rm -f "$STATS_CSV" "$HEALTH_CSV" "$COUNTERS_FILE" 2>/dev/null
    # Il demone tiene i contatori in memoria: va riavviato
    if daemon_pid >/dev/null; then start_daemon; fi
    echo "OK"
}

cmd_probe() {
    echo "== Nodi di controllo ricarica trovati =="
    for _n in \
        "$SYSFS/class/qcom-battery/input_suspend" \
        "$SYSFS/class/qcom-battery/night_charging" \
        "$SYSFS/class/qcom-battery/smart_batt" \
        "$SYSFS/class/qcom-battery/soh" \
        "$SYSFS/class/power_supply/battery/input_suspend" \
        "$SYSFS/class/power_supply/battery/charging_enabled" \
        "$SYSFS/class/power_supply/battery/battery_charging_enabled" \
        "$SYSFS/class/power_supply/battery/charge_control_limit" \
        "$SYSFS/class/power_supply/battery/charge_control_limit_max" \
        "$SYSFS/class/power_supply/battery/charge_stop_level" \
        "$SYSFS/class/power_supply/battery/night_charging" \
        "$SYSFS/class/power_supply/battery/constant_charge_current_max" \
        "$SYSFS/class/power_supply/battery/input_current_limit" \
        "$SYSFS/class/power_supply/usb/present" \
        "$SYSFS/class/power_supply/usb/online" \
        "$SYSFS/class/power_supply/usb/input_current_limit" \
        "$SYSFS/class/power_supply/usb/real_type"; do
        if [ -e "$_n" ]; then
            _w="ro"; [ -w "$_n" ] && _w="rw"
            echo "[$_w] $_n = $(cat "$_n" 2>/dev/null)"
        fi
    done
    echo "== power_supply disponibili =="
    ls "$SYSFS/class/power_supply/" 2>/dev/null
}

cmd_theme() {
    # JSON con colore base e stile del tema scelti in Sfondo e stile
    _th=$(settings get secure theme_customization_overlay_packages 2>/dev/null | tr -d '\n')
    [ "$_th" = "null" ] && _th=""
    echo "THEME=$_th"
}

cmd_restart() {
    start_daemon
    sleep 2
    _dp=$(daemon_pid) && echo "OK PID $_dp" || echo "ERR demone non avviato"
}

CMD="$1"; [ $# -gt 0 ] && shift
case "$CMD" in
    status) cmd_status ;;
    config) cmd_config ;;
    set) cmd_set "$@" ;;
    toggle) cmd_toggle "$1" ;;
    stats) cmd_stats "$1" ;;
    health) cmd_health ;;
    log) cmd_log "$1" ;;
    export) cmd_export ;;
    reset-stats) cmd_reset_stats ;;
    probe) cmd_probe ;;
    theme) cmd_theme ;;
    restart) cmd_restart ;;
    wake) wake_daemon; echo "OK" ;;
    *) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' ; exit 1 ;;
esac
