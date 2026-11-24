#!/system/bin/sh
# ==============================================================================
# Veux Smart Charge Limiter - Funzioni e percorsi condivisi
# Incluso (". common.sh") da daemon.sh, service.sh, action.sh, cli.sh,
# uninstall.sh. Scritto in POSIX sh: gira sia in mksh (/system/bin/sh) sia in
# BusyBox ash (usata da Magisk per action.sh).
# NB: mksh ha aritmetica a 32 bit -> niente epoch in millisecondi nei calcoli.
# ==============================================================================

# shellcheck disable=SC2034  # variabili usate dagli script che includono questo file

MODID="veux_charge_limiter"

# Prefissi sovrascrivibili solo per i test fuori dal telefono
SYSFS="${VCL_SYSFS:-/sys}"
SDCARD="${VCL_SDCARD:-/sdcard}"
DATA_DIR="${VCL_DATA:-/data/adb/$MODID}"
RUN_DIR="${VCL_RUN:-/data/local/tmp}"

# --- File utente (visibili dal file manager) ---
USER_CONF="$SDCARD/$MODID.conf"
LOG_FILE="$SDCARD/$MODID.log"
EXPORT_DIR="$SDCARD/VeuxChargeLimiter"

# --- File runtime (azzerati al riavvio dal demone) ---
PID_FILE="$RUN_DIR/$MODID.pid"
STATUS_FILE="$RUN_DIR/$MODID.status"
FALLBACK_LOG="$RUN_DIR/$MODID.log"

# --- File persistenti (solo root) ---
STATS_CSV="$DATA_DIR/stats.csv"
HEALTH_CSV="$DATA_DIR/health.csv"
COUNTERS_FILE="$DATA_DIR/counters"
ORIG_CURR_FILE="$DATA_DIR/orig_max_curr_ua"
FORCE_START_FILE="$DATA_DIR/force_full_since"
SMART_DONE_FILE="$DATA_DIR/smart_done_for"
BOOT_FAILS_FILE="$DATA_DIR/boot_fails"

# --- Nodi kernel (soc:qcom_wt_chg) ---
SUSPEND_NODE="$SYSFS/class/qcom-battery/input_suspend"
SOH_NODE="$SYSFS/class/qcom-battery/soh"
BAT="$SYSFS/class/power_supply/battery"
CAPACITY_NODE="$BAT/capacity"
TEMP_NODE="$BAT/temp"
CURRENT_NOW_NODE="$BAT/current_now"
VOLTAGE_NOW_NODE="$BAT/voltage_now"
MAX_CURR_NODE="$BAT/constant_charge_current_max"
STATUS_NODE="$BAT/status"
CHARGE_FULL_NODE="$BAT/charge_full"
CHARGE_FULL_DESIGN_NODE="$BAT/charge_full_design"
CYCLE_COUNT_NODE="$BAT/cycle_count"
USB_ONLINE_NODE="$SYSFS/class/power_supply/usb/online"
BACKLIGHT_NODE=""
for _b in "$SYSFS/class/backlight/panel0-backlight/brightness" \
          "$SYSFS/class/leds/lcd-backlight/brightness"; do
    [ -f "$_b" ] && { BACKLIGHT_NODE="$_b"; break; }
done
WAKELOCK_NODE="$SYSFS/power/wake_lock"
WAKEUNLOCK_NODE="$SYSFS/power/wake_unlock"

FALLBACK_MAX_CURR_UA=12200000
HARD_MIN_SAFETY=15

# Chiavi di configurazione ammesse (tutte numeriche intere >= 0)
CONF_KEYS="ENABLED MIN_LEVEL MAX_LEVEL CHARGE_ON_PLUG PLUG_RESUME_DELTA MAX_CHARGE_MA TEMP_SOFT_C SOFT_CHARGE_MA TEMP_STOP_C TEMP_RESUME_C FORCE_FULL_ONCE FORCE_FULL_EXPIRE_H SMART_CHARGE SMART_FIXED_TIME SMART_BUFFER_MIN NOTIFY STATS_INTERVAL_MIN POLL_CHARGING_SEC POLL_DISCHARGING_SEC POLL_UNPLUGGED_SEC"

is_conf_key() {
    case " $CONF_KEYS " in *" $1 "*) return 0 ;; esac
    return 1
}

is_uint() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    return 0
}

# Toglie gli zeri iniziali ("0700" -> "700") per evitare l'ottale di ash
strip0() {
    _s="$1"
    while [ "${#_s}" -gt 1 ] && [ "${_s#0}" != "$_s" ]; do _s="${_s#0}"; done
    echo "$_s"
}

# Lettura di un nodo intero SENZA fork: risultato in $_v (default $2)
rd() {
    _v=""
    [ -r "$1" ] && read -r _v 2>/dev/null < "$1"
    case "$_v" in
        ''|-|*[!0-9-]*) _v="$2" ;;
    esac
}

# Lettura di un nodo testuale (es. status) senza fork: risultato in $_t
rdt() {
    _t=""
    [ -r "$1" ] && read -r _t 2>/dev/null < "$1"
    [ -z "$_t" ] && _t="$2"
}

now_s() { date +%s; }

log_msg() {
    _line="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$_line" >> "$FALLBACK_LOG" 2>/dev/null
    if [ -d "$SDCARD" ]; then
        echo "$_line" >> "$LOG_FILE" 2>/dev/null
    fi
    LOG_WRITES=$(( ${LOG_WRITES:-0} + 1 ))
    # Controllo dimensione solo ogni 20 scritture (evita wc continui)
    if [ $((LOG_WRITES % 20)) -eq 1 ]; then
        for _lf in "$FALLBACK_LOG" "$LOG_FILE"; do
            if [ -f "$_lf" ] && [ "$(wc -l < "$_lf" 2>/dev/null || echo 0)" -gt 400 ]; then
                tail -n 300 "$_lf" > "$_lf.tmp" 2>/dev/null && mv -f "$_lf.tmp" "$_lf"
            fi
        done
    fi
}

# Notifica Android nativa (appare come app "Shell"). Una sola notifica,
# aggiornata ad ogni evento. Nessun apice singolo nel testo (quoting).
notify() {
    [ "${NOTIFY:-1}" = "1" ] || return 0
    [ -n "$VCL_NO_NOTIFY" ] && return 0
    _msg=$(echo "$1" | sed "s/'/’/g")
    _title="Charge Limiter"
    if command -v su >/dev/null 2>&1 && \
       su -lp 2000 -c "cmd notification post -S bigtext -t '$_title' veux_cl '$_msg'" >/dev/null 2>&1; then
        return 0
    fi
    cmd notification post -S bigtext -t "$_title" veux_cl "$_msg" >/dev/null 2>&1
}

# Config attiva: quella su /sdcard se leggibile, altrimenti la copia interna
active_conf() {
    if [ -f "$USER_CONF" ] && [ -r "$USER_CONF" ]; then
        echo "$USER_CONF"
    else
        echo "$MODDIR/config.conf"
    fi
}

# Imposta KEY=VALUE in un file config (aggiunge la riga se manca)
conf_write_key() {
    _f="$1"; _k="$2"; _val="$3"
    [ -f "$_f" ] || return 1
    if grep -q "^$_k=" "$_f" 2>/dev/null; then
        sed -i "s/^$_k=.*/$_k=$_val/" "$_f" 2>/dev/null
    else
        printf '\n%s=%s\n' "$_k" "$_val" >> "$_f"
    fi
}

# Scrive la chiave in entrambe le copie del config
conf_set() {
    is_conf_key "$1" || return 1
    is_uint "$2" || return 1
    _sv=$(strip0 "$2")
    conf_write_key "$USER_CONF" "$1" "$_sv"
    conf_write_key "$MODDIR/config.conf" "$1" "$_sv"
    return 0
}

# Legge una chiave dal config attivo (stdout), default $2
conf_get() {
    _cf=$(active_conf)
    _gv=$(grep "^$1=" "$_cf" 2>/dev/null | tail -n 1 | cut -d= -f2 | sed 's/#.*//; s/[ \t\r]//g')
    is_uint "$_gv" && strip0 "$_gv" || echo "$2"
}

# Vero se il processo esiste e non è uno zombie (terminato ma non raccolto)
proc_alive() {
    kill -0 "$1" 2>/dev/null || return 1
    _ps=""
    read -r _ps < "/proc/$1/stat" 2>/dev/null
    _ps=${_ps##*) }
    case "$_ps" in Z*|X*) return 1 ;; esac
    return 0
}

# PID del demone se vivo (verifica anche la cmdline), altrimenti vuoto
daemon_pid() {
    [ -f "$PID_FILE" ] || return 1
    read -r _p < "$PID_FILE" 2>/dev/null
    is_uint "$_p" || return 1
    proc_alive "$_p" || return 1
    case "$(tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null)" in
        *daemon.sh*) echo "$_p"; return 0 ;;
    esac
    return 1
}

# Sveglia il demone (rilegge subito config e stato)
wake_daemon() {
    _dp=$(daemon_pid) && kill -USR1 "$_dp" 2>/dev/null
}

start_daemon() {
    # shellcheck disable=SC2086  # VCL_SH (solo test) può essere "busybox sh"
    nohup ${VCL_SH:-/system/bin/sh} "$MODDIR/daemon.sh" >/dev/null 2>&1 &
}
