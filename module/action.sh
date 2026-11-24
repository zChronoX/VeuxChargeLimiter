#!/system/bin/sh
# ==============================================================================
# Pulsante "Azione" (Magisk / KernelSU / APatch): stato live + menu rapido
#   Volume SU   -> attiva/disattiva la carica al 100% una tantum
#   Volume GIÙ  -> metti in pausa / riprendi il modulo
#   Nessun tasto per 8 secondi -> esci senza cambiare nulla
# ==============================================================================

MODDIR="${0%/*}"
# shellcheck source=common.sh
. "$MODDIR/common.sh"

kv() { grep "^$1=" "$TMP_STATUS" 2>/dev/null | head -n 1 | cut -d= -f2-; }

state_desc() {
    case "$1" in
        CHARGING) case "$2" in 8*|1|11) echo "In carica (si ferma all'${2}%)" ;; *) echo "In carica (si ferma al ${2}%)" ;; esac ;;
        CHARGING_SOFT) echo "In carica lenta (temperatura alta)" ;;
        FULL_ONCE) echo "Carica al 100% una tantum" ;;
        SMART) echo "Carica smart per la sveglia" ;;
        EMERGENCY) echo "Ricarica di emergenza (batteria bassa)" ;;
        HOLD) echo "Carica sospesa: il telefono usa la batteria" ;;
        THERMAL_PAUSE) echo "Pausa termica: attendo che si raffreddi" ;;
        UNPLUGGED) echo "Cavo scollegato" ;;
        PAUSED) echo "Modulo in pausa (ENABLED=0)" ;;
        STOPPED) echo "Demone fermo" ;;
        *) echo "$1" ;;
    esac
}

show_status() {
    TMP_STATUS="$RUN_DIR/$MODID.action.tmp"
    sh "$MODDIR/cli.sh" status > "$TMP_STATUS" 2>/dev/null
    _temp=$(kv TEMP_DEC); is_uint "$_temp" || _temp=0
    _min=$(kv MIN_LEVEL); _max=$(kv MAX_LEVEL)
    echo "=========================================="
    echo "   Veux Smart Charge Limiter $(kv VERSION)"
    echo "=========================================="
    if [ "$(kv DAEMON)" != "0" ]; then
        echo "Demone       : ATTIVO (PID $(kv DAEMON))"
    else
        echo "Demone       : FERMO"
    fi
    echo "Stato        : $(state_desc "$(kv STATE)" "$_max")"
    echo "Batteria     : $(kv CAPACITY)%  ($(kv VOLTAGE_MV) mV)"
    echo "Temperatura  : $((_temp / 10)).$((_temp % 10)) °C"
    echo "Corrente     : $(kv CURRENT_MA) mA  (limite $(kv LIMIT_MA) mA)"
    [ -n "$_min" ] && echo "Ciclo        : ${_min}% - ${_max}%"
    _soh=$(kv SOH); [ -n "$_soh" ] && echo "Salute (SOH) : ${_soh}%"
    _cf=$(kv CHARGE_FULL_MAH); _cd=$(kv DESIGN_MAH)
    [ "${_cf:-0}" -gt 0 ] && echo "Capacità     : ${_cf} / ${_cd} mAh"
    _in=$(kv PCT_IN); [ -n "$_in" ] && echo "Cicli equiv. : $((_in / 100)).$(( (_in % 100) / 10 )) (dall'installazione)"
    [ "$(kv FORCE_FULL)" = "1" ] && echo "Carica 100%  : ATTIVA (una tantum)"
    _st=$(kv SMART_TARGET)
    if [ "$(kv SMART_CHARGE)" = "1" ]; then
        if [ "${_st:-0}" -gt 0 ]; then
            echo "Carica smart : 100% per le $(date -d "@$_st" '+%H:%M' 2>/dev/null), inizio $(date -d "@$(kv SMART_START)" '+%H:%M' 2>/dev/null)"
        else
            echo "Carica smart : attiva, nessuna sveglia rilevata"
        fi
    fi
    rm -f "$TMP_STATUS"
}

# Attende un tasto volume (max $1 secondi). Stampa UP, DOWN o niente.
wait_volume_key() {
    _ev=$(timeout "$1" getevent -lq 2>/dev/null | grep -m 1 -E 'KEY_VOLUME(UP|DOWN) +DOWN')
    case "$_ev" in
        *KEY_VOLUMEUP*) echo UP ;;
        *KEY_VOLUMEDOWN*) echo DOWN ;;
    esac
}

# Avvia il demone se dovrebbe girare e non gira
if ! daemon_pid >/dev/null && [ ! -f "$MODDIR/disable" ]; then
    echo "! Demone non in esecuzione: avvio..."
    start_daemon
    sleep 2
fi

show_status
echo "------------------------------------------"
echo "Ultimi eventi:"
sh "$MODDIR/cli.sh" log 6
echo "------------------------------------------"

FF=$(conf_get FORCE_FULL_ONCE 0)
EN=$(conf_get ENABLED 1)
if [ "$FF" = "1" ]; then echo "[Vol +] Annulla la carica al 100%"; else echo "[Vol +] Carica al 100% una tantum"; fi
if [ "$EN" = "1" ]; then echo "[Vol -] Metti in pausa il modulo"; else echo "[Vol -] Riattiva il modulo"; fi
echo "(nessun tasto per 8 secondi = esci)"

KEY=$(wait_volume_key 8)
case "$KEY" in
    UP)
        sh "$MODDIR/cli.sh" toggle FORCE_FULL_ONCE >/dev/null
        if [ "$FF" = "1" ]; then echo ">> Carica al 100% annullata."; else echo ">> Carica al 100% attivata: si fermerà da sola al 100%."; fi
        ;;
    DOWN)
        sh "$MODDIR/cli.sh" toggle ENABLED >/dev/null
        if [ "$EN" = "1" ]; then echo ">> Modulo in pausa: carica standard."; else echo ">> Modulo riattivato."; fi
        ;;
    *)
        echo ">> Nessuna modifica."
        ;;
esac
echo "=========================================="
