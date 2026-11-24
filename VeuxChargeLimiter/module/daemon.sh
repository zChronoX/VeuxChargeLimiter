#!/system/bin/sh
# ==============================================================================
# Veux Smart Charge Limiter - Core Daemon
# ==============================================================================

MODDIR="${0%/*}"
if [ ! -f "$MODDIR/common.sh" ] && [ -d /data/adb/modules/veux_charge_limiter ]; then
    MODDIR=/data/adb/modules/veux_charge_limiter
fi
# shellcheck source=common.sh
. "$MODDIR/common.sh"

mkdir -p "$DATA_DIR" 2>/dev/null
STATE_FILE="$DATA_DIR/last_state"

# ------------------------------------------------------------------------------
# Istanza unica: chiude un vecchio demone e ATTENDE che sia davvero terminato
# ------------------------------------------------------------------------------
OLD_PID=$(daemon_pid)
if [ -n "$OLD_PID" ] && [ "$OLD_PID" != "$$" ]; then
    kill "$OLD_PID" 2>/dev/null
    _i=0
    while proc_alive "$OLD_PID" && [ "$_i" -lt 10 ]; do
        sleep 1; _i=$((_i + 1))
    done
    kill -9 "$OLD_PID" 2>/dev/null
fi
echo "$$" > "$PID_FILE"

# Corrente massima originale, salvata da service.sh al boot prima di toccarla
ORIG_MAX_CURR_UA=$FALLBACK_MAX_CURR_UA
if [ -f "$ORIG_CURR_FILE" ]; then
    read -r _o < "$ORIG_CURR_FILE" 2>/dev/null
    is_uint "$_o" && [ "$_o" -ge 1000000 ] && ORIG_MAX_CURR_UA=$_o
fi

# ------------------------------------------------------------------------------
# Sonno interrompibile, wakelock, uscita pulita
# ------------------------------------------------------------------------------
NAP_PID=""
nap() {
    sleep "$1" &
    NAP_PID=$!
    wait "$NAP_PID" 2>/dev/null
    NAP_PID=""
}

# SIGUSR1 (da cli.sh / WebUI / Azione): interrompe il sonno e rilegge il config
on_wake() {
    CONF_SIG=""
    ALARM_CHECKED=0
    [ -n "$NAP_PID" ] && kill "$NAP_PID" 2>/dev/null
}

WL_HELD=0
wl_acquire() {   # $1 = secondi (stringa, niente aritmetica a 64 bit)
    [ -w "$WAKELOCK_NODE" ] || return 0
    echo "veux_cl ${1}000000000" > "$WAKELOCK_NODE" 2>/dev/null && WL_HELD=1
}
wl_release() {
    [ "$WL_HELD" = "1" ] || return 0
    echo "veux_cl" > "$WAKEUNLOCK_NODE" 2>/dev/null
    WL_HELD=0
}

restore_hardware_defaults() {
    [ -w "$SUSPEND_NODE" ] && echo 0 > "$SUSPEND_NODE" 2>/dev/null
    [ -w "$MAX_CURR_NODE" ] && echo "$ORIG_MAX_CURR_UA" > "$MAX_CURR_NODE" 2>/dev/null
}

cleanup_and_exit() {
    trap - INT TERM EXIT USR1
    [ -n "$NAP_PID" ] && kill "$NAP_PID" 2>/dev/null
    log_msg "Arresto demone (PID $$): ripristino ricarica e corrente standard."
    restore_hardware_defaults
    wl_release
    save_counters
    _p=""
    read -r _p < "$PID_FILE" 2>/dev/null
    [ "$_p" = "$$" ] && rm -f "$PID_FILE" "$STATUS_FILE" 2>/dev/null
    exit 0
}

trap cleanup_and_exit INT TERM EXIT
trap on_wake USR1

# ------------------------------------------------------------------------------
# Configurazione (riletta solo quando il file cambia)
# ------------------------------------------------------------------------------
CONF_SIG=""

set_defaults() {
    ENABLED=1; MIN_LEVEL=20; MAX_LEVEL=80
    CHARGE_ON_PLUG=1; PLUG_RESUME_DELTA=5
    MAX_CHARGE_MA=2500
    TEMP_SOFT_C=36; SOFT_CHARGE_MA=1500
    TEMP_STOP_C=39; TEMP_RESUME_C=35
    FORCE_FULL_ONCE=0; FORCE_FULL_EXPIRE_H=24
    SMART_CHARGE=0; SMART_FIXED_TIME=0; SMART_BUFFER_MIN=30
    NOTIFY=1; STATS_INTERVAL_MIN=5
    POLL_CHARGING_SEC=25; POLL_DISCHARGING_SEC=60; POLL_UNPLUGGED_SEC=20
}

load_config_if_changed() {
    # Crea la config utente su /sdcard se manca (e la sdcard è accessibile)
    if [ -d "$SDCARD" ] && [ ! -f "$USER_CONF" ] && [ -f "$MODDIR/config.conf" ]; then
        cp -f "$MODDIR/config.conf" "$USER_CONF" 2>/dev/null
    fi
    if [ -f "$USER_CONF" ] && [ -r "$USER_CONF" ]; then
        ACF="$USER_CONF"
    else
        ACF="$MODDIR/config.conf"
    fi
    _sig="$ACF:$(stat -c '%Y:%s' "$ACF" 2>/dev/null)"
    [ "$_sig" = "$CONF_SIG" ] && return 1
    CONF_SIG="$_sig"

    set_defaults
    if [ -f "$ACF" ]; then
        _parsed=$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$ACF" 2>/dev/null | grep -E '^[A-Z_]+=[0-9]+$')
        while IFS='=' read -r _k _val; do
            [ -z "$_k" ] && continue
            is_conf_key "$_k" || continue
            eval "$_k=$(strip0 "$_val")"
        done <<EOF
$_parsed
EOF
        # Copia interna sempre allineata (serve prima dello sblocco al boot)
        if [ "$ACF" = "$USER_CONF" ]; then
            cp -f "$USER_CONF" "$MODDIR/config.conf" 2>/dev/null
        fi
    fi

    # --- Validazione limiti di sicurezza ---
    [ "$MAX_LEVEL" -gt 100 ] && MAX_LEVEL=100
    [ "$MAX_LEVEL" -lt $((HARD_MIN_SAFETY + 5)) ] && MAX_LEVEL=$((HARD_MIN_SAFETY + 5))
    [ "$MIN_LEVEL" -lt "$HARD_MIN_SAFETY" ] && MIN_LEVEL=$HARD_MIN_SAFETY
    [ "$MIN_LEVEL" -gt $((MAX_LEVEL - 5)) ] && MIN_LEVEL=$((MAX_LEVEL - 5))
    [ "$PLUG_RESUME_DELTA" -lt 1 ] && PLUG_RESUME_DELTA=1
    [ "$PLUG_RESUME_DELTA" -gt 50 ] && PLUG_RESUME_DELTA=50
    { [ "$TEMP_STOP_C" -lt 30 ] || [ "$TEMP_STOP_C" -gt 48 ]; } && TEMP_STOP_C=39
    [ "$TEMP_RESUME_C" -ge "$TEMP_STOP_C" ] && TEMP_RESUME_C=$((TEMP_STOP_C - 3))
    [ "$TEMP_SOFT_C" -ge "$TEMP_STOP_C" ] && TEMP_SOFT_C=0
    [ "$POLL_CHARGING_SEC" -lt 10 ] && POLL_CHARGING_SEC=10
    [ "$POLL_DISCHARGING_SEC" -lt 15 ] && POLL_DISCHARGING_SEC=15
    [ "$POLL_UNPLUGGED_SEC" -lt 10 ] && POLL_UNPLUGGED_SEC=10
    [ "$POLL_CHARGING_SEC" -gt 600 ] && POLL_CHARGING_SEC=600
    [ "$POLL_DISCHARGING_SEC" -gt 600 ] && POLL_DISCHARGING_SEC=600
    [ "$POLL_UNPLUGGED_SEC" -gt 600 ] && POLL_UNPLUGGED_SEC=600
    [ "$STATS_INTERVAL_MIN" -gt 60 ] && STATS_INTERVAL_MIN=60
    [ "$SMART_BUFFER_MIN" -gt 240 ] && SMART_BUFFER_MIN=240
    if [ "$SMART_FIXED_TIME" -gt 0 ]; then
        { [ $((SMART_FIXED_TIME / 100)) -gt 23 ] || [ $((SMART_FIXED_TIME % 100)) -gt 59 ]; } && SMART_FIXED_TIME=0
    fi
    return 0
}

reset_force_full_flag() {
    for _cf in "$USER_CONF" "$MODDIR/config.conf"; do
        [ -f "$_cf" ] && sed -i 's/^FORCE_FULL_ONCE=.*/FORCE_FULL_ONCE=0/' "$_cf" 2>/dev/null
    done
    FORCE_FULL_ONCE=0
    rm -f "$FORCE_START_FILE" 2>/dev/null
    CONF_SIG=""
}

# ------------------------------------------------------------------------------
# Hardware
# ------------------------------------------------------------------------------
LIMIT_UA=0
apply_charge_current_limit() {
    if [ "$MAX_CHARGE_MA" -gt 0 ]; then
        _ma=$MAX_CHARGE_MA
        [ "$_ma" -lt 500 ] && _ma=500
        [ "$_ma" -gt 12200 ] && _ma=12200
        LIMIT_UA=$((_ma * 1000))
    else
        LIMIT_UA=$ORIG_MAX_CURR_UA
    fi
    if [ "$SOFT_ACTIVE" = "1" ] && [ "$SOFT_CHARGE_MA" -gt 0 ]; then
        _sm=$SOFT_CHARGE_MA
        [ "$_sm" -lt 500 ] && _sm=500
        [ $((_sm * 1000)) -lt "$LIMIT_UA" ] && LIMIT_UA=$((_sm * 1000))
    fi
    [ -w "$MAX_CURR_NODE" ] || return 0
    rd "$MAX_CURR_NODE" "0"
    [ "$_v" != "$LIMIT_UA" ] && echo "$LIMIT_UA" > "$MAX_CURR_NODE" 2>/dev/null
}

set_suspend() {
    rd "$SUSPEND_NODE" "0"
    if [ "$_v" != "$1" ]; then
        echo "$1" > "$SUSPEND_NODE" 2>/dev/null
        return 0
    fi
    return 1
}

save_mode() {
    [ "$MODE" = "$SAVED_MODE" ] && return 0
    echo "$MODE" > "$STATE_FILE" 2>/dev/null
    SAVED_MODE=$MODE
}

hhmm() { date -d "@$1" '+%H:%M' 2>/dev/null || echo "?"; }

# ------------------------------------------------------------------------------
# Carica smart (sveglia / orario fisso)
# ------------------------------------------------------------------------------
SMART_TARGET=0
SMART_START=0
SMART_DONE=0
ALARM_CHECKED=0
ALARM_TS=0
[ -f "$SMART_DONE_FILE" ] && read -r SMART_DONE < "$SMART_DONE_FILE" 2>/dev/null
is_uint "$SMART_DONE" || SMART_DONE=0

read_next_alarm() {
    # Riga del dump di AlarmManager: "user:0 pendingSend:false time:1732510800000 = ..."
    _l=$(dumpsys alarm 2>/dev/null | grep -m 1 -E 'user:[0-9]+ pendingSend:[a-z]+ time:[0-9]+')
    _ms=${_l##*time:}
    _ms=${_ms%% *}
    ALARM_TS=0
    if is_uint "$_ms" && [ "${#_ms}" -gt 3 ]; then
        _s=${_ms%???}
        [ "$_s" -gt "$NOW" ] && ALARM_TS=$_s
    fi
}

compute_smart() {
    SMART_TARGET=0; SMART_START=0
    [ "$SMART_CHARGE" = "1" ] || return 0
    if [ "$SMART_FIXED_TIME" -gt 0 ]; then
        # shellcheck disable=SC2046  # split voluto: ore minuti secondi
        set -- $(date '+%H %M %S')
        _secs=$(( $(strip0 "$1") * 3600 + $(strip0 "$2") * 60 + $(strip0 "$3") ))
        _t=$(( NOW - _secs + (SMART_FIXED_TIME / 100) * 3600 + (SMART_FIXED_TIME % 100) * 60 ))
        [ "$_t" -le "$NOW" ] && _t=$((_t + 86400))
        SMART_TARGET=$_t
    else
        # La sveglia viene riletta ogni 10 minuti, solo con il cavo collegato
        if [ "$USB_ON" = "1" ] && [ $((NOW - ALARM_CHECKED)) -ge 600 ]; then
            read_next_alarm
            ALARM_CHECKED=$NOW
        fi
        [ "$ALARM_TS" -gt "$NOW" ] && SMART_TARGET=$ALARM_TS
    fi
    [ "$SMART_TARGET" -gt 0 ] || return 0
    # Tempo stimato per arrivare al 100% con la corrente impostata (+30% per
    # la fase finale a tensione costante) + margine configurabile
    rd "$CHARGE_FULL_DESIGN_NODE" "5000000"
    _mah=$((_v / 1000)); [ "$_mah" -lt 1000 ] && _mah=5000
    _ima=$MAX_CHARGE_MA; [ "$_ima" -le 0 ] && _ima=6000
    _spp=$(( _mah * 36 * 13 / (_ima * 10) ))
    _need=$(( (100 - CAP) * _spp + SMART_BUFFER_MIN * 60 ))
    [ "$_need" -lt 0 ] && _need=0
    SMART_START=$((SMART_TARGET - _need))
}

# ------------------------------------------------------------------------------
# Statistiche
# ------------------------------------------------------------------------------
PCT_IN=0; PCT_OUT=0; STATS_SINCE=0
if [ -f "$COUNTERS_FILE" ]; then
    while IFS='=' read -r _k _val; do
        case "$_k" in
            PCT_IN) is_uint "$_val" && PCT_IN=$_val ;;
            PCT_OUT) is_uint "$_val" && PCT_OUT=$_val ;;
            SINCE) is_uint "$_val" && STATS_SINCE=$_val ;;
        esac
    done < "$COUNTERS_FILE"
fi
LAST_CAP=""
LAST_SAMPLE=0
LAST_HEALTH_DAY=""
[ -f "$HEALTH_CSV" ] && LAST_HEALTH_DAY=$(tail -n 1 "$HEALTH_CSV" 2>/dev/null | cut -d, -f1)
SAMPLE_COUNT=0

save_counters() {
    [ "$STATS_SINCE" -gt 0 ] || return 0
    {
        echo "PCT_IN=$PCT_IN"
        echo "PCT_OUT=$PCT_OUT"
        echo "SINCE=$STATS_SINCE"
    } > "$COUNTERS_FILE" 2>/dev/null
}

screen_state() {
    if [ -n "$BACKLIGHT_NODE" ]; then
        rd "$BACKLIGHT_NODE" "0"
        [ "$_v" -gt 0 ] && echo 1 || echo 0
    else
        case "$(dumpsys power 2>/dev/null | grep -m 1 -o 'mWakefulness=[A-Za-z]*')" in
            *Awake*) echo 1 ;;
            *) echo 0 ;;
        esac
    fi
}

take_sample() {
    [ "$STATS_INTERVAL_MIN" -gt 0 ] || return 0
    [ $((NOW - LAST_SAMPLE)) -ge $((STATS_INTERVAL_MIN * 60 - 5)) ] || return 0
    LAST_SAMPLE=$NOW
    [ -f "$STATS_CSV" ] || echo "ts,cap,current_ma,voltage_mv,temp_dec,usb,state,screen" > "$STATS_CSV"
    echo "$NOW,$CAP,$CURR_MA,$VOLT_MV,$TEMP_DEC,$USB_ON,$EFFECTIVE_STATE,$(screen_state)" >> "$STATS_CSV"
    [ "$STATS_SINCE" -gt 0 ] || STATS_SINCE=$NOW
    save_counters

    SAMPLE_COUNT=$((SAMPLE_COUNT + 1))
    # Mantiene circa 30 giorni (a 5 min = 288 righe/giorno)
    if [ $((SAMPLE_COUNT % 100)) -eq 1 ] && [ "$(wc -l < "$STATS_CSV")" -gt 9500 ]; then
        { head -n 1 "$STATS_CSV"; tail -n 8640 "$STATS_CSV" | grep -v '^ts,'; } > "$STATS_CSV.tmp" && mv -f "$STATS_CSV.tmp" "$STATS_CSV"
    fi

    # Una riga al giorno sulla salute della batteria
    _day=$(date '+%Y-%m-%d')
    if [ "$_day" != "$LAST_HEALTH_DAY" ]; then
        LAST_HEALTH_DAY=$_day
        [ -f "$HEALTH_CSV" ] || echo "date,soh,charge_full_mah,design_mah,cycle_count,pct_in" > "$HEALTH_CSV"
        rd "$SOH_NODE" ""; _soh=$_v
        rd "$CHARGE_FULL_NODE" "0"; _cf=$((_v / 1000))
        rd "$CHARGE_FULL_DESIGN_NODE" "0"; _cd=$((_v / 1000))
        rd "$CYCLE_COUNT_NODE" ""; _cc=$_v
        echo "$_day,$_soh,$_cf,$_cd,$_cc,$PCT_IN" >> "$HEALTH_CSV"
    fi
}

write_status() {
    rd "$SUSPEND_NODE" "0"; _susp=$_v
    rdt "$STATUS_NODE" "Unknown"; _bst=$_t
    {
        echo "PID=$$"
        echo "STATE=$EFFECTIVE_STATE"
        echo "MODE=$MODE"
        echo "CAPACITY=$CAP"
        echo "CURRENT_MA=$CURR_MA"
        echo "VOLTAGE_MV=$VOLT_MV"
        echo "TEMP_DEC=$TEMP_DEC"
        echo "BAT_STATUS=$_bst"
        echo "USB_ONLINE=$USB_ON"
        echo "INPUT_SUSPEND=$_susp"
        echo "LIMIT_MA=$((LIMIT_UA / 1000))"
        echo "ORIG_MAX_MA=$((ORIG_MAX_CURR_UA / 1000))"
        echo "MIN_LEVEL=$MIN_LEVEL"
        echo "MAX_LEVEL=$MAX_LEVEL"
        echo "SOFT_ACTIVE=$SOFT_ACTIVE"
        echo "THERMAL_PAUSED=$THERMAL_PAUSED"
        echo "FORCE_FULL=$FORCE_FULL_ONCE"
        echo "SMART_CHARGE=$SMART_CHARGE"
        echo "SMART_TARGET=$SMART_TARGET"
        echo "SMART_START=$SMART_START"
        echo "PCT_IN=$PCT_IN"
        echo "PCT_OUT=$PCT_OUT"
        echo "STATS_SINCE=$STATS_SINCE"
        echo "WAKELOCK=$WL_HELD"
        echo "UPDATED=$NOW"
    } > "$STATUS_FILE.tmp" 2>/dev/null && mv -f "$STATUS_FILE.tmp" "$STATUS_FILE"
}

# ------------------------------------------------------------------------------
# Stato iniziale
# ------------------------------------------------------------------------------
MODE="CHARGING"
for _sf in "$STATE_FILE" "$MODDIR/last_state"; do
    if [ -f "$_sf" ]; then
        read -r _saved < "$_sf" 2>/dev/null
        [ "$_saved" = "DISCHARGING" ] && MODE="DISCHARGING"
        break
    fi
done
SAVED_MODE=$MODE
THERMAL_PAUSED=0
SOFT_ACTIVE=0
EMERGENCY=0
# Al boot un cavo già collegato conta come "inserimento" (CHARGE_ON_PLUG);
# se il demone viene solo riavviato (WebUI/Azione) no.
if [ "$VCL_BOOT" = "1" ]; then
    PREV_USB=0
else
    rd "$USB_ONLINE_NODE" "1"; PREV_USB=$_v
fi
LAST_LOGGED_STATE=""
WAS_MOD_DISABLED=0
CFG_PAUSED=0
EFFECTIVE_STATE="STARTING"
set_defaults

log_msg "Demone avviato (PID $$). Corrente originale: $((ORIG_MAX_CURR_UA / 1000)) mA."

# ------------------------------------------------------------------------------
# Ciclo principale
# ------------------------------------------------------------------------------
while true; do
    # 1. Modulo disattivato / rimosso dall'app root
    if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]; then
        if [ "$WAS_MOD_DISABLED" -eq 0 ]; then
            log_msg "Modulo disabilitato/rimosso: ripristino carica standard."
            restore_hardware_defaults
            wl_release
            WAS_MOD_DISABLED=1
        fi
        [ -f "$MODDIR/remove" ] && exit 0
        nap 30
        continue
    elif [ "$WAS_MOD_DISABLED" -eq 1 ]; then
        log_msg "Modulo riabilitato: ripresa gestione automatica."
        WAS_MOD_DISABLED=0
    fi

    load_config_if_changed
    NOW=$(now_s)

    rd "$CAPACITY_NODE" "50"; CAP=$_v
    rd "$TEMP_NODE" "280"; TEMP_DEC=$_v
    TEMP_C=$((TEMP_DEC / 10))
    rd "$USB_ONLINE_NODE" "1"; USB_ON=$_v
    rd "$CURRENT_NOW_NODE" "0"; CURR_MA=$((_v / 1000))
    rd "$VOLTAGE_NOW_NODE" "0"; VOLT_MV=$((_v / 1000))

    PLUG_EVENT=0
    [ "$USB_ON" = "1" ] && [ "$PREV_USB" != "1" ] && PLUG_EVENT=1
    PREV_USB=$USB_ON

    # Contatori % caricata / scaricata (cicli equivalenti)
    if [ -n "$LAST_CAP" ]; then
        if [ "$CAP" -gt "$LAST_CAP" ]; then
            PCT_IN=$((PCT_IN + CAP - LAST_CAP))
        elif [ "$CAP" -lt "$LAST_CAP" ]; then
            PCT_OUT=$((PCT_OUT + LAST_CAP - CAP))
        fi
    fi
    LAST_CAP=$CAP

    # 2. ENABLED=0 nel config: tutto standard
    if [ "$ENABLED" -eq 0 ]; then
        if [ "$CFG_PAUSED" -eq 0 ]; then
            restore_hardware_defaults
            wl_release
            log_msg "ENABLED=0 nel config: carica standard attiva (batteria ${CAP}%)."
            CFG_PAUSED=1
        fi
        LIMIT_UA=$ORIG_MAX_CURR_UA
        EFFECTIVE_STATE="PAUSED"
        LAST_LOGGED_STATE="PAUSED"
        take_sample
        write_status
        nap "$POLL_DISCHARGING_SEC"
        continue
    elif [ "$CFG_PAUSED" -eq 1 ]; then
        log_msg "ENABLED=1: gestione automatica riattivata."
        CFG_PAUSED=0
    fi

    # 3. Scadenza della carica al 100% una tantum
    if [ "$FORCE_FULL_ONCE" -eq 1 ]; then
        if [ ! -f "$FORCE_START_FILE" ]; then
            echo "$NOW" > "$FORCE_START_FILE" 2>/dev/null
            log_msg "Carica al 100% una tantum ATTIVATA."
        elif [ "$FORCE_FULL_EXPIRE_H" -gt 0 ]; then
            read -r _fs < "$FORCE_START_FILE" 2>/dev/null
            if is_uint "$_fs" && [ $((NOW - _fs)) -gt $((FORCE_FULL_EXPIRE_H * 3600)) ]; then
                reset_force_full_flag
                log_msg "Carica al 100% scaduta dopo ${FORCE_FULL_EXPIRE_H}h senza raggiungere il 100%: torno al ciclo normale."
                notify "Carica al 100% annullata: attiva da oltre ${FORCE_FULL_EXPIRE_H} ore."
            fi
        fi
    elif [ -f "$FORCE_START_FILE" ]; then
        rm -f "$FORCE_START_FILE" 2>/dev/null
    fi

    compute_smart
    SMART_NOW=0
    if [ "$SMART_TARGET" -gt 0 ] && [ "$USB_ON" = "1" ] && [ "$NOW" -ge "$SMART_START" ] && \
       [ "$NOW" -lt "$SMART_TARGET" ] && [ "$SMART_DONE" != "$SMART_TARGET" ]; then
        SMART_NOW=1
    fi

    # 4. Macchina a stati
    EMERGENCY=0
    if [ "$CAP" -le "$HARD_MIN_SAFETY" ]; then
        # Paracadute assoluto: sotto il 15% carica sempre
        [ "$MODE" != "CHARGING" ] && log_msg "EMERGENZA BATTERIA BASSA (${CAP}%): ricarica forzata!"
        [ "$MODE" != "CHARGING" ] && [ "$USB_ON" = "1" ] && notify "Batteria al ${CAP}%: ricarica di emergenza attivata."
        MODE="CHARGING"
        EMERGENCY=1
        THERMAL_PAUSED=0
    elif [ "$FORCE_FULL_ONCE" -eq 1 ]; then
        if [ "$CAP" -ge 100 ]; then
            reset_force_full_flag
            MODE="DISCHARGING"
            log_msg "Carica una tantum al 100% completata. Ritorno al ciclo ${MIN_LEVEL}%-${MAX_LEVEL}%."
            notify "Batteria al 100%. Carica sospesa, si torna al ciclo ${MIN_LEVEL}-${MAX_LEVEL}%."
        else
            MODE="FULL_ONCE"
        fi
    elif [ "$SMART_NOW" -eq 1 ]; then
        if [ "$CAP" -ge 100 ]; then
            SMART_DONE=$SMART_TARGET
            echo "$SMART_DONE" > "$SMART_DONE_FILE" 2>/dev/null
            MODE="DISCHARGING"
            log_msg "Carica smart completata: 100% pronto per le $(hhmm "$SMART_TARGET")."
            notify "Carica smart completata: 100% pronto per le $(hhmm "$SMART_TARGET")."
        elif [ "$MODE" != "SMART" ]; then
            MODE="SMART"
            log_msg "Carica smart avviata (${CAP}%): obiettivo 100% entro le $(hhmm "$SMART_TARGET")."
            notify "Carica smart avviata: 100% entro le $(hhmm "$SMART_TARGET")."
        fi
    else
        case "$MODE" in FULL_ONCE|SMART) MODE="CHARGING" ;; esac
        if [ "$PLUG_EVENT" -eq 1 ] && [ "$CHARGE_ON_PLUG" -eq 1 ] && [ "$MODE" = "DISCHARGING" ] && \
           [ "$CAP" -lt $((MAX_LEVEL - PLUG_RESUME_DELTA)) ]; then
            MODE="CHARGING"
            log_msg "Cavo collegato a ${CAP}% (< $((MAX_LEVEL - PLUG_RESUME_DELTA))%): carica fino al ${MAX_LEVEL}%."
        fi
        if [ "$CAP" -ge "$MAX_LEVEL" ] && [ "$MODE" != "DISCHARGING" ]; then
            MODE="DISCHARGING"
            THERMAL_PAUSED=0
            log_msg "Raggiunto ${CAP}% (soglia MAX ${MAX_LEVEL}%): sospendo la carica."
            [ "$USB_ON" = "1" ] && notify "Carica sospesa a ${CAP}% (limite ${MAX_LEVEL}%)."
        elif [ "$CAP" -le "$MIN_LEVEL" ] && [ "$MODE" != "CHARGING" ]; then
            MODE="CHARGING"
            log_msg "Raggiunto ${CAP}% (soglia MIN ${MIN_LEVEL}%): riattivo la ricarica fino al ${MAX_LEVEL}%."
        fi
    fi
    save_mode

    # 5. Protezione termica (solo in fase di carica)
    if [ "$MODE" != "DISCHARGING" ] && [ "$EMERGENCY" -eq 0 ]; then
        if [ "$THERMAL_PAUSED" -eq 0 ] && [ "$TEMP_DEC" -ge $((TEMP_STOP_C * 10)) ]; then
            THERMAL_PAUSED=1
            log_msg "PAUSA TERMICA: batteria a ${TEMP_C}°C (>= ${TEMP_STOP_C}°C). Riprendo a ${TEMP_RESUME_C}°C."
            [ "$USB_ON" = "1" ] && notify "Carica in pausa: batteria a ${TEMP_C}°C. Riprende sotto i ${TEMP_RESUME_C}°C."
        elif [ "$THERMAL_PAUSED" -eq 1 ] && [ "$TEMP_DEC" -le $((TEMP_RESUME_C * 10)) ]; then
            THERMAL_PAUSED=0
            log_msg "Temperatura scesa a ${TEMP_C}°C: riprendo la ricarica."
        fi
    else
        THERMAL_PAUSED=0
    fi
    # Corrente ridotta a gradino (con 1°C di isteresi)
    if [ "$TEMP_SOFT_C" -gt 0 ] && [ "$SOFT_CHARGE_MA" -gt 0 ]; then
        if [ "$SOFT_ACTIVE" -eq 0 ] && [ "$TEMP_DEC" -ge $((TEMP_SOFT_C * 10)) ]; then
            SOFT_ACTIVE=1
        elif [ "$SOFT_ACTIVE" -eq 1 ] && [ "$TEMP_DEC" -le $(((TEMP_SOFT_C - 1) * 10)) ]; then
            SOFT_ACTIVE=0
        fi
    else
        SOFT_ACTIVE=0
    fi

    # 6. Applica lo stato ai nodi del kernel
    apply_charge_current_limit
    if [ "$USB_ON" -eq 0 ]; then
        # Cavo scollegato: input_suspend=0 così il prossimo inserimento negozia subito
        set_suspend 0 >/dev/null
        wl_release
        EFFECTIVE_STATE="UNPLUGGED"
    elif [ "$MODE" = "DISCHARGING" ]; then
        if set_suspend 1; then
            log_msg "Applicato input_suspend=1 (batteria ${CAP}%, in attesa del ${MIN_LEVEL}%)."
        fi
        wl_release
        EFFECTIVE_STATE="HOLD"
    elif [ "$THERMAL_PAUSED" -eq 1 ]; then
        set_suspend 1 >/dev/null
        wl_release
        EFFECTIVE_STATE="THERMAL_PAUSE"
    else
        if set_suspend 0; then
            log_msg "Applicato input_suspend=0 (batteria ${CAP}%, carica attiva)."
        fi
        if [ "$EMERGENCY" -eq 1 ]; then
            EFFECTIVE_STATE="EMERGENCY"
        elif [ "$MODE" = "FULL_ONCE" ] || [ "$MODE" = "SMART" ]; then
            EFFECTIVE_STATE="$MODE"
        elif [ "$SOFT_ACTIVE" -eq 1 ]; then
            EFFECTIVE_STATE="CHARGING_SOFT"
        else
            EFFECTIVE_STATE="CHARGING"
        fi
        # Vicino alla soglia MAX il telefono non deve andare in deep sleep,
        # altrimenti il controllo successivo può arrivare tardi (sforamento).
        if [ "$MODE" = "CHARGING" ] && [ "$CAP" -ge $((MAX_LEVEL - 2)) ]; then
            wl_acquire $((POLL_CHARGING_SEC + 15))
        else
            wl_release
        fi
    fi

    if [ "$LAST_LOGGED_STATE" != "$EFFECTIVE_STATE" ]; then
        log_msg "Stato: $EFFECTIVE_STATE | Batteria: ${CAP}% | Temp: ${TEMP_C}°C | Limite: $((LIMIT_UA / 1000)) mA"
        LAST_LOGGED_STATE=$EFFECTIVE_STATE
    fi

    take_sample
    write_status

    # 7. Intervallo adattivo
    if [ "$USB_ON" -eq 0 ]; then
        nap "$POLL_UNPLUGGED_SEC"
    elif [ "$EFFECTIVE_STATE" = "HOLD" ] || [ "$EFFECTIVE_STATE" = "THERMAL_PAUSE" ]; then
        nap "$POLL_DISCHARGING_SEC"
    else
        nap "$POLL_CHARGING_SEC"
    fi
done
