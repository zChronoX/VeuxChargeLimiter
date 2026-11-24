#!/system/bin/sh
# ==============================================================================
# Disinstallazione pulita: ferma il demone e ripristina i valori hardware.
# Configurazione, log ed esportazioni su /sdcard restano (cancellali a mano).
# ==============================================================================

MODDIR="${0%/*}"
# shellcheck source=common.sh
. "$MODDIR/common.sh"

_dp=$(daemon_pid) && kill "$_dp" 2>/dev/null

ORIG=$FALLBACK_MAX_CURR_UA
if [ -f "$ORIG_CURR_FILE" ]; then
    read -r _o < "$ORIG_CURR_FILE" 2>/dev/null
    is_uint "$_o" && [ "$_o" -ge 1000000 ] && ORIG=$_o
fi
echo 0 > "$SUSPEND_NODE" 2>/dev/null
echo "$ORIG" > "$MAX_CURR_NODE" 2>/dev/null
echo veux_cl > "$WAKEUNLOCK_NODE" 2>/dev/null

rm -f "$PID_FILE" "$STATUS_FILE" "$FALLBACK_LOG" 2>/dev/null
rm -rf "$DATA_DIR" 2>/dev/null
