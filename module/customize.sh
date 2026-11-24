#!/system/bin/sh

# shellcheck disable=SC2034  # letto da Magisk/KernelSU
SKIPUNZIP=0

MODVER=$(sed -n 's/^version=//p' "$MODPATH/module.prop")
ui_print "=========================================="
ui_print "   Veux Smart Charge Limiter $MODVER"
ui_print "   Redmi Note 11 Pro 5G (veux - wt_chg)"
ui_print "   github.com/zChronoX/VeuxChargeLimiter"
ui_print "=========================================="

DEVICE=$(getprop ro.product.device)
ui_print "- Dispositivo: $DEVICE (Android $(getprop ro.build.version.release))"
case "$DEVICE" in
    veux|peux) ;;
    *) ui_print "! Attenzione: modulo pensato per veux, rilevato '$DEVICE'." ;;
esac

if [ -e /sys/class/qcom-battery/input_suspend ]; then
    ui_print "- Nodo kernel input_suspend trovato [OK]"
else
    ui_print "! input_suspend non visibile ora, verrà ricontrollato all'avvio."
fi

# ------------------------------------------------------------------------------
# Migrazione config: il nuovo modello (con le nuove opzioni e i commenti
# aggiornati) viene riempito con i valori che avevi già impostato.
# ------------------------------------------------------------------------------
merge_conf() {   # $1 = vecchia config, $2 = modello nuovo, $3 = destinazione
    _tmp="$3.new"
    : > "$_tmp" || return 1
    while IFS= read -r _line || [ -n "$_line" ]; do
        case "$_line" in
            [A-Z]*=*)
                _k=${_line%%=*}
                _old=$(grep "^$_k=" "$1" 2>/dev/null | tail -n 1 | cut -d= -f2 | sed 's/#.*//; s/[ \t\r]//g')
                case "$_old" in
                    ''|*[!0-9]*) echo "$_line" >> "$_tmp" ;;
                    *) echo "$_k=$_old" >> "$_tmp" ;;
                esac
                ;;
            *) echo "$_line" >> "$_tmp" ;;
        esac
    done < "$2"
    mv -f "$_tmp" "$3"
}

TEMPLATE="$MODPATH/config.conf"
cp -f "$TEMPLATE" "$TMPDIR/config.template" 2>/dev/null || cp -f "$TEMPLATE" "$MODPATH/config.template"
[ -f "$TMPDIR/config.template" ] && TPL="$TMPDIR/config.template" || TPL="$MODPATH/config.template"

OLD_MOD="/data/adb/modules/veux_charge_limiter"
USER_CONF="/sdcard/veux_charge_limiter.conf"

if [ -f "$USER_CONF" ]; then
    cp -f "$USER_CONF" "/sdcard/veux_charge_limiter.conf.bak" 2>/dev/null
    merge_conf "$USER_CONF" "$TPL" "$USER_CONF" && \
        ui_print "- Config utente aggiornata, valori mantenuti (backup: .conf.bak)"
    merge_conf "$USER_CONF" "$TPL" "$MODPATH/config.conf"
elif [ -f "$OLD_MOD/config.conf" ]; then
    merge_conf "$OLD_MOD/config.conf" "$TPL" "$MODPATH/config.conf"
    ui_print "- Mantenuta la configurazione interna esistente"
fi

if [ -d /sdcard ] && [ ! -f "$USER_CONF" ]; then
    cp -f "$MODPATH/config.conf" "$USER_CONF" 2>/dev/null && \
        ui_print "- Creato file config: $USER_CONF"
fi
rm -f "$MODPATH/config.template" 2>/dev/null

set_perm_recursive "$MODPATH" 0 0 0755 0644
for f in service.sh daemon.sh action.sh cli.sh uninstall.sh common.sh; do
    set_perm "$MODPATH/$f" 0 0 0755
done

ui_print "- Anti-bootloop: nulla viene toccato prima del boot completo;"
ui_print "  3 riavvii anomali di fila = modulo disattivato da solo."
ui_print "- WebUI: apribile con KernelSU/APatch, oppure su Magisk"
ui_print "  con l'app WebUI X o KsuWebUI Standalone."
ui_print "- Installazione completata! Riavvia per attivare il modulo."
ui_print "=========================================="
