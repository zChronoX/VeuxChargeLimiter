#!/usr/bin/env bash
# ==============================================================================
# Test automatici del modulo, fuori dal telefono.
# Crea un finto /sys (nodi della batteria), una finta /sdcard e finti comandi
# Android (dumpsys, cmd, getevent...), poi fa girare il VERO daemon.sh e
# controlla le sue decisioni.
#
# Uso: tools/test/run-tests.sh [shell...]
#      default: mksh (la /system/bin/sh di Android) e busybox sh
# Requisiti: bash, mksh, busybox
# ==============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SHELLS=("$@")
[ ${#SHELLS[@]} -eq 0 ] && SHELLS=(mksh "busybox sh")

PASS=0
FAIL=0
CUR_SHELL=""

ok()   { PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
ko()   { FAIL=$((FAIL + 1)); printf '  \033[31m✗ %s\033[0m\n      %s\n' "$1" "$2"; }
check() { # check "descrizione" valore_atteso valore_reale
    if [ "$2" = "$3" ]; then ok "$1"; else ko "$1" "atteso '$2', ottenuto '$3'"; fi
}
section() { printf '\n\033[1m[%s] %s\033[0m\n' "$CUR_SHELL" "$1"; }

# ------------------------------------------------------------------ ambiente --
setup_env() {
    T="$(mktemp -d)"
    mkdir -p "$T"/sys/class/qcom-battery "$T"/sys/class/power_supply/battery \
             "$T"/sys/class/power_supply/usb "$T"/sys/class/backlight/panel0-backlight \
             "$T"/sys/power "$T"/sdcard "$T"/data "$T"/run "$T"/bin
    cp -r "$ROOT/module" "$T/mod"
    B="$T/sys/class/power_supply/battery"
    SUSP="$T/sys/class/qcom-battery/input_suspend"
    USB="$T/sys/class/power_supply/usb/online"
    echo 0 > "$SUSP"
    echo 92 > "$T/sys/class/qcom-battery/soh"
    echo 50 > "$B/capacity";            echo 300 > "$B/temp"
    echo -1500000 > "$B/current_now";   echo 4100000 > "$B/voltage_now"
    echo 7400000 > "$B/constant_charge_current_max"
    echo Charging > "$B/status"
    echo 4600000 > "$B/charge_full";    echo 5000000 > "$B/charge_full_design"
    echo 321 > "$B/cycle_count"
    echo 1 > "$USB"
    echo 200 > "$T/sys/class/backlight/panel0-backlight/brightness"
    : > "$T/sys/power/wake_lock"; : > "$T/sys/power/wake_unlock"
    echo 7400000 > "$T/data/orig_max_curr_ua"

    cat > "$T/bin/dumpsys" <<'S'
#!/bin/sh
case "$1" in
  alarm) echo "Next alarm clock information:"
         echo "  user:0 pendingSend:false time:${FAKE_ALARM_MS:-0} = 2026-01-01 07:00:00 = +8h" ;;
  power) echo "  mWakefulness=Asleep" ;;
esac
S
    printf '#!/bin/sh\necho "$*" >> "%s/notifications.log"\n' "$T" > "$T/bin/cmd"
    printf '#!/bin/sh\nexit 1\n' > "$T/bin/su"
    printf '#!/bin/sh\necho 1\n' > "$T/bin/getprop"
    printf '#!/bin/sh\necho '"'"'{"android.theme.customization.system_palette":"FF6750A4","android.theme.customization.theme_style":"TONAL_SPOT"}'"'"'\n' > "$T/bin/settings"
    chmod +x "$T"/bin/*

    export VCL_SYSFS="$T/sys" VCL_SDCARD="$T/sdcard" VCL_DATA="$T/data" VCL_RUN="$T/run"
    export VCL_SH="$CUR_SHELL"
    export PATH="$T/bin:$ORIG_PATH"
    STATUS="$T/run/veux_charge_limiter.status"
    PIDF="$T/run/veux_charge_limiter.pid"
    CONF="$T/sdcard/veux_charge_limiter.conf"
}

cleanup_env() {
    stop_daemon
    rm -rf "$T"
}

# $CUR_SHELL può essere "busybox sh": va diviso in parole
sh_run() { $CUR_SHELL "$@"; }
cli() { sh_run "$T/mod/cli.sh" "$@"; }

start_daemon() {
    rm -f "$STATUS"
    (VCL_BOOT="${1:-0}" $CUR_SHELL "$T/mod/daemon.sh" >/dev/null 2>&1 &)
    wait_status
}
stop_daemon() {
    local p
    p=$(cat "$PIDF" 2>/dev/null) || return 0
    kill "$p" 2>/dev/null
    for _ in $(seq 1 50); do alive "$p" || break; sleep 0.1; done
}
wait_status() {
    for _ in $(seq 1 60); do [ -f "$STATUS" ] && return 0; sleep 0.1; done
    return 1
}
# Un giro del demone: cancella lo stato, lo sveglia, aspetta il nuovo stato
step() {
    rm -f "$STATUS"
    kill -USR1 "$(cat "$PIDF")" 2>/dev/null
    wait_status
}
st() { sed -n "s/^$1=//p" "$STATUS" 2>/dev/null; }
node() { cat "$1" 2>/dev/null; }
# Vivo e non zombie (nel container nessuno raccoglie i processi orfani)
alive() { kill -0 "$1" 2>/dev/null && ! grep -q '^[^)]*) [ZX]' "/proc/$1/stat" 2>/dev/null; }

# ------------------------------------------------------------------ test ------
test_thresholds() {
    section "Soglie, sospensione e collegamento del cavo"
    start_daemon 1
    check "avvio al 50% col cavo: carica" CHARGING "$(st STATE)"
    check "limite di corrente applicato" 2500000 "$(node "$B/constant_charge_current_max")"
    check "config creata su /sdcard" yes "$([ -f "$CONF" ] && echo yes)"
    echo 79 > "$B/capacity"; step
    check "79%: wakelock vicino alla soglia" 1 "$(st WAKELOCK)"
    check "wakelock con timeout in ns" "veux_cl 40000000000" "$(node "$T/sys/power/wake_lock")"
    echo 80 > "$B/capacity"; step
    check "80%: carica sospesa (HOLD)" HOLD "$(st STATE)"
    check "80%: input_suspend=1" 1 "$(node "$SUSP")"
    check "80%: wakelock rilasciato" 0 "$(st WAKELOCK)"
    echo 60 > "$B/capacity"; step
    check "60% ancora collegato: resta HOLD" HOLD "$(st STATE)"
    echo 0 > "$USB"; step
    check "cavo staccato: UNPLUGGED" UNPLUGGED "$(st STATE)"
    check "cavo staccato: input_suspend=0" 0 "$(node "$SUSP")"
    echo 55 > "$B/capacity"; echo 1 > "$USB"; step
    check "ricollegato al 55%: riparte la carica" CHARGING "$(st STATE)"
    echo 80 > "$B/capacity"; step
    echo 0 > "$USB"; step; echo 77 > "$B/capacity"; echo 1 > "$USB"; step
    check "ricollegato al 77% (>= 80-5): resta HOLD" HOLD "$(st STATE)"
    sh_run "$T/mod/cli.sh" set CHARGE_ON_PLUG 0 >/dev/null; step
    echo 0 > "$USB"; step; echo 50 > "$B/capacity"; echo 1 > "$USB"; step
    check "CHARGE_ON_PLUG=0: al 50% resta HOLD" HOLD "$(st STATE)"
    echo 20 > "$B/capacity"; step
    check "soglia MIN raggiunta: carica" CHARGING "$(st STATE)"
    echo 14 > "$B/capacity"; step
    check "sotto il 15%: emergenza" EMERGENCY "$(st STATE)"
    stop_daemon
}

test_thermal() {
    section "Protezione termica"
    start_daemon
    echo 370 > "$B/temp"; step
    check "37°C: corrente ridotta" CHARGING_SOFT "$(st STATE)"
    check "37°C: limite 1500 mA" 1500000 "$(node "$B/constant_charge_current_max")"
    echo 395 > "$B/temp"; step
    check "39,5°C: pausa termica" THERMAL_PAUSE "$(st STATE)"
    check "pausa termica: input_suspend=1" 1 "$(node "$SUSP")"
    echo 360 > "$B/temp"; step
    check "36°C: ancora in pausa (isteresi)" THERMAL_PAUSE "$(st STATE)"
    echo 345 > "$B/temp"; step
    check "34,5°C: carica ripresa" CHARGING "$(st STATE)"
    check "34,5°C: limite pieno 2500 mA" 2500000 "$(node "$B/constant_charge_current_max")"
    check "notifica di pausa termica inviata" yes "$(grep -q 'Carica in pausa' "$T/notifications.log" && echo yes)"
    stop_daemon
}

test_force_full() {
    section "Carica al 100% una tantum"
    echo 70 > "$B/capacity"
    start_daemon
    cli set FORCE_FULL_ONCE 1 >/dev/null; step
    check "attivata: FULL_ONCE" FULL_ONCE "$(st STATE)"
    echo 85 > "$B/capacity"; step
    check "85%: continua oltre il MAX" FULL_ONCE "$(st STATE)"
    echo 100 > "$B/capacity"; step
    check "100%: sospende" HOLD "$(st STATE)"
    check "100%: flag azzerato nel config" "FORCE_FULL_ONCE=0" "$(grep '^FORCE_FULL_ONCE=' "$CONF")"
    echo 70 > "$B/capacity"
    cli set FORCE_FULL_ONCE 1 FORCE_FULL_EXPIRE_H 1 >/dev/null; step
    echo $(( $(date +%s) - 4000 )) > "$T/data/force_full_since"; step
    check "scaduta dopo 1h: flag azzerato" "FORCE_FULL_ONCE=0" "$(grep '^FORCE_FULL_ONCE=' "$CONF")"
    stop_daemon
}

test_smart() {
    section "Carica smart"
    echo 80 > "$B/capacity"
    cli set SMART_CHARGE 1 >/dev/null
    FAKE_ALARM_MS="$(( $(date +%s) + 7200 ))000" start_daemon
    check "sveglia fra 2h all'80%: troppo presto, HOLD" HOLD "$(st STATE)"
    stop_daemon
    export FAKE_ALARM_MS="$(( $(date +%s) + 1800 ))000"
    start_daemon
    check "sveglia fra 30 min: SMART" SMART "$(st STATE)"
    check "obiettivo = ora della sveglia" "${FAKE_ALARM_MS%???}" "$(st SMART_TARGET)"
    echo 100 > "$B/capacity"; step
    check "100%: completata, HOLD" HOLD "$(st STATE)"
    echo 99 > "$B/capacity"; step
    check "stessa sveglia: non riparte" HOLD "$(st STATE)"
    stop_daemon; unset FAKE_ALARM_MS
    echo 80 > "$B/capacity"
    cli set SMART_FIXED_TIME "$(date -d '+20 min' '+%H%M')" >/dev/null
    start_daemon
    check "orario fisso fra 20 min: SMART" SMART "$(st STATE)"
    cli set SMART_CHARGE 0 SMART_FIXED_TIME 0 >/dev/null; step
    check "smart disattivata: HOLD" HOLD "$(st STATE)"
    stop_daemon
}

test_pause_and_lifecycle() {
    section "Pausa, disattivazione e ciclo di vita del demone"
    echo 60 > "$B/capacity"
    start_daemon
    cli toggle ENABLED >/dev/null; step
    check "ENABLED=0: PAUSED" PAUSED "$(st STATE)"
    check "ENABLED=0: corrente originale ripristinata" 7400000 "$(node "$B/constant_charge_current_max")"
    check "ENABLED=0: input_suspend=0" 0 "$(node "$SUSP")"
    cli toggle ENABLED >/dev/null; step
    check "ENABLED=1: di nuovo in carica" CHARGING "$(st STATE)"
    touch "$T/mod/disable"; kill -USR1 "$(cat "$PIDF")"; sleep 0.5
    check "file disable: corrente ripristinata" 7400000 "$(node "$B/constant_charge_current_max")"
    rm -f "$T/mod/disable"; step
    check "disable rimosso: ripresa" CHARGING "$(st STATE)"

    local p1 p2
    p1=$(cat "$PIDF")
    cli restart >/dev/null
    p2=$(cat "$PIDF")
    check "restart: nuovo PID" yes "$([ "$p1" != "$p2" ] && echo yes)"
    check "restart: il vecchio demone è terminato" no "$(alive "$p1" && echo yes || echo no)"
    check "restart: il nuovo demone è attivo" yes "$(alive "$p2" && echo yes || echo no)"
    sleep 1.5
    check "restart: il vecchio non cancella il PID del nuovo" "$p2" "$(cat "$PIDF" 2>/dev/null)"

    local t0 t1
    t0=$(date +%s%N); kill "$p2"
    while alive "$p2"; do sleep 0.05; done
    t1=$(date +%s%N)
    check "SIGTERM: uscita entro 3 s" yes "$([ $(( (t1 - t0) / 1000000 )) -lt 3000 ] && echo yes)"
    check "SIGTERM: corrente ripristinata" 7400000 "$(node "$B/constant_charge_current_max")"
    check "SIGTERM: PID file rimosso" no "$([ -f "$PIDF" ] && echo yes || echo no)"
    check "contatori salvati" yes "$(grep -q '^PCT_IN=' "$T/data/counters" && echo yes)"
    check "statistiche CSV scritte" yes "$([ "$(wc -l < "$T/data/stats.csv")" -ge 2 ] && echo yes)"
    check "storico salute scritto" "92,4600,5000,321" "$(tail -n 1 "$T/data/health.csv" | cut -d, -f2-5)"
}

test_cli() {
    section "Comandi cli.sh"
    check "chiave sconosciuta rifiutata" "ERR chiave sconosciuta: FOO" "$(cli set FOO 1)"
    check "valore non numerico rifiutato" "ERR valore non valido per MAX_LEVEL: abc" "$(cli set MAX_LEVEL abc)"
    check "argomenti dispari rifiutati" "ERR numero di argomenti dispari" "$(cli set MAX_LEVEL 80 MIN_LEVEL)"
    check "tentativo di injection rifiutato" "ERR valore non valido per MAX_LEVEL: 1;reboot" "$(cli set MAX_LEVEL '1;reboot')"
    cli set MAX_LEVEL 075 >/dev/null
    check "zeri iniziali rimossi (no ottale)" "MAX_LEVEL=75" "$(grep '^MAX_LEVEL=' "$CONF")"
    check "config letta" 75 "$(cli config | sed -n 's/^MAX_LEVEL=//p')"
    check "status senza demone" STOPPED "$(cli status | sed -n 's/^STATE=//p')"
    check "theme legge il colore del tema Android" 'THEME={"android.theme.customization.system_palette":"FF6750A4","android.theme.customization.theme_style":"TONAL_SPOT"}' "$(cli theme)"
    local probe
    probe=$(cli probe)
    case "$probe" in *input_suspend*) ok "probe trova input_suspend" ;; *) ko "probe trova input_suspend" "non trovato" ;; esac
}

test_action() {
    section "Pulsante Azione"
    printf '#!/bin/sh\nsleep 0.3\necho "/dev/input/event1: EV_KEY       KEY_VOLUMEUP         DOWN"\nsleep 20\n' > "$T/bin/getevent"
    chmod +x "$T/bin/getevent"
    touch "$T/mod/disable"   # non avviare il demone dall'azione
    local out
    out=$(sh_run "$T/mod/action.sh" 2>&1)
    case "$out" in *"Veux Smart Charge Limiter"*) ok "mostra lo stato" ;; *) ko "mostra lo stato" "$out" ;; esac
    check "Volume su: carica al 100% attivata" "FORCE_FULL_ONCE=1" "$(grep '^FORCE_FULL_ONCE=' "$CONF")"
    rm -f "$T/mod/disable" "$T/bin/getevent"
}

test_boot_guard() {
    section "Boot guard"
    local svc="$T/mod/service_test.sh"
    # service.sh senza attese e senza avvio reale del demone; CRASH=1 simula un
    # riavvio prima che la sentinella venga rimossa
    # shellcheck disable=SC2016  # i $ devono finire letterali nello script generato
    sed -e 's/sleep [0-9]*/true/' -e 's/^) &$/)/' -e 's/^    start_daemon$/    :/' \
        -e 's/^    rm -f "\$BOOT_GUARD" 2>\/dev\/null$/    [ -n "$CRASH" ] || rm -f "$BOOT_GUARD"/' \
        -e 's/^    echo 0 > "\$BOOT_FAILS_FILE"$/    [ -n "$CRASH" ] || echo 0 > "$BOOT_FAILS_FILE"/' \
        "$T/mod/service.sh" > "$svc"
    echo 9100000 > "$B/constant_charge_current_max"
    CRASH=1 sh_run "$svc"
    check "salva la corrente originale al boot" 9100000 "$(cat "$T/data/orig_max_curr_ua")"
    CRASH=1 sh_run "$svc"; CRASH=1 sh_run "$svc"
    check "dopo 2 riavvii sospetti: ancora attivo" no "$([ -f "$T/mod/disable" ] && echo yes || echo no)"
    sh_run "$svc"
    check "al 3° riavvio sospetto di fila: modulo disattivato" yes "$([ -f "$T/mod/disable" ] && echo yes || echo no)"
    rm -f "$T/mod/disable" "$svc"
    sh_run "$T/mod/service.sh" >/dev/null 2>&1   # non deve bloccare
    ok "service.sh ritorna subito"
    pkill -f "$T/mod/service.sh" 2>/dev/null
}

test_migration() {
    section "Migrazione di una config precedente"
    local old="$T/old.conf" fn="$T/merge_fn.sh"
    printf 'ENABLED=1\nMIN_LEVEL=70\nMAX_LEVEL=75\nMAX_CHARGE_MA=1800\nTEMP_STOP_C=40\n' > "$old"
    sed -n '/^merge_conf()/,/^}/p' "$T/mod/customize.sh" > "$fn"
    sh_run -c ". '$fn'; merge_conf '$old' '$T/mod/config.conf' '$old'"
    check "valore utente mantenuto (MAX_LEVEL)" "MAX_LEVEL=75" "$(grep '^MAX_LEVEL=' "$old")"
    check "valore utente mantenuto (MAX_CHARGE_MA)" "MAX_CHARGE_MA=1800" "$(grep '^MAX_CHARGE_MA=' "$old")"
    check "nuova opzione aggiunta (SMART_CHARGE)" "SMART_CHARGE=0" "$(grep '^SMART_CHARGE=' "$old")"
    check "commenti del nuovo modello presenti" yes "$(grep -q 'Carica smart' "$old" && echo yes)"
}

# ------------------------------------------------------------------ main ------
ORIG_PATH="$PATH"
for sh in "${SHELLS[@]}"; do
    CUR_SHELL="$sh"
    for t in test_thresholds test_thermal test_force_full test_smart test_pause_and_lifecycle \
             test_cli test_action test_boot_guard test_migration; do
        setup_env
        $t
        cleanup_env
    done
done

printf '\n%d test superati, %d falliti\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
