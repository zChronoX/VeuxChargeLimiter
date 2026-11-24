#!/system/bin/sh
# ==============================================================================
# Veux Smart Charge Limiter - late_start service
# Sicurezza anti-bootloop:
# 1. Ritorna subito (exit 0), tutto il resto gira in background.
# 2. Non tocca nessun nodo hardware finché Android non ha finito il boot
#    (sys.boot_completed=1) + 20 secondi di stabilizzazione.
# 3. Se il telefono si riavvia entro ~2 minuti dall'avvio del demone per 3 boot
#    di fila, il modulo si DISATTIVA da solo (file "disable") e lascia la carica
#    standard. Dopo il primo riavvio sospetto aspetta 60s in più, così hai tempo
#    di disattivarlo a mano dall'app.
# ==============================================================================

MODDIR="${0%/*}"
# shellcheck source=common.sh
. "$MODDIR/common.sh"
BOOT_GUARD="$MODDIR/boot_guard"
MAX_BOOT_FAILS=3

(
    WAIT_COUNT=0
    while [ "$(getprop sys.boot_completed)" != "1" ]; do
        sleep 3
        WAIT_COUNT=$((WAIT_COUNT + 3))
        [ "$WAIT_COUNT" -ge 300 ] && exit 0
    done

    mkdir -p "$DATA_DIR" 2>/dev/null

    # Salva la corrente massima originale PRIMA di modificarla (sysfs si
    # azzera ad ogni riavvio, quindi qui c'è sempre il valore di fabbrica)
    rd "$MAX_CURR_NODE" "0"
    if [ "$_v" -ge 1000000 ]; then
        echo "$_v" > "$ORIG_CURR_FILE"
    fi

    # Contatore di riavvii ravvicinati consecutivi
    FAILS=0
    [ -f "$BOOT_FAILS_FILE" ] && read -r FAILS < "$BOOT_FAILS_FILE" 2>/dev/null
    is_uint "$FAILS" || FAILS=0
    if [ -f "$BOOT_GUARD" ]; then
        FAILS=$((FAILS + 1))
        rm -f "$BOOT_GUARD" 2>/dev/null
    else
        FAILS=0
    fi
    echo "$FAILS" > "$BOOT_FAILS_FILE"

    if [ "$FAILS" -ge "$MAX_BOOT_FAILS" ]; then
        echo 0 > "$BOOT_FAILS_FILE"
        touch "$MODDIR/disable"
        log_msg "BOOT-GUARD: $FAILS riavvii ravvicinati di fila. Modulo DISATTIVATO per sicurezza (riattivalo dall'app root)."
        sleep 30
        notify "Modulo disattivato dopo $FAILS riavvii anomali di fila. Carica standard ripristinata."
        exit 0
    elif [ "$FAILS" -ge 1 ]; then
        log_msg "BOOT-GUARD: riavvio ravvicinato rilevato ($FAILS/$MAX_BOOT_FAILS), attendo 60s extra."
        sleep 60
    fi

    touch "$BOOT_GUARD" 2>/dev/null
    sleep 20

    export VCL_BOOT=1
    start_daemon

    # Dopo 90s di sistema stabile azzera la sentinella e il contatore
    sleep 90
    rm -f "$BOOT_GUARD" 2>/dev/null
    echo 0 > "$BOOT_FAILS_FILE"
) &

exit 0
