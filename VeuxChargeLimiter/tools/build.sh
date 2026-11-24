#!/usr/bin/env bash
# ==============================================================================
# Crea lo zip flashabile in dist/ partendo da module/.
# Uso: tools/build.sh            -> dist/VeuxChargeLimiter-<versione>.zip
#      tools/build.sh --check    -> solo controlli di coerenza, nessuno zip
# ==============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOD="$ROOT/module"
NAME="VeuxChargeLimiter"

prop() { sed -n "s/^$1=//p" "$MOD/module.prop"; }
VERSION="$(prop version)"
VCODE="$(prop versionCode)"

fail() { echo "ERRORE: $*" >&2; exit 1; }

# --- Controlli di coerenza ---------------------------------------------------
[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version in module.prop non è nel formato vX.Y.Z ($VERSION)"
[[ "$VCODE" =~ ^[0-9]+$ ]] || fail "versionCode non numerico ($VCODE)"

EXPECTED_CODE=$(echo "${VERSION#v}" | awk -F. '{ print $1*100 + $2*10 + $3 }')
[ "$VCODE" = "$EXPECTED_CODE" ] || fail "versionCode=$VCODE ma per $VERSION ci si aspetta $EXPECTED_CODE"

UJ_VERSION=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$ROOT/update.json")
UJ_CODE=$(sed -n 's/.*"versionCode": *\([0-9]*\).*/\1/p' "$ROOT/update.json")
UJ_ZIP=$(sed -n 's/.*"zipUrl": *"\([^"]*\)".*/\1/p' "$ROOT/update.json")
[ "$UJ_VERSION" = "$VERSION" ] || fail "update.json version=$UJ_VERSION, module.prop=$VERSION"
[ "$UJ_CODE" = "$VCODE" ] || fail "update.json versionCode=$UJ_CODE, module.prop=$VCODE"
[[ "$UJ_ZIP" == */download/$VERSION/$NAME-$VERSION.zip ]] || fail "zipUrl in update.json non punta a $NAME-$VERSION.zip della release $VERSION"
grep -q "^## \[${VERSION#v}\]" "$ROOT/CHANGELOG.md" || fail "CHANGELOG.md non ha una sezione ## [${VERSION#v}]"

if grep -rlI $'\r' "$MOD" >/dev/null 2>&1; then
    grep -rlI $'\r' "$MOD" >&2
    fail "file con fine riga Windows (CRLF): gli script non girerebbero su Android"
fi
for f in "$MOD"/*.sh "$MOD/META-INF/com/google/android/update-binary"; do
    head -n 1 "$f" | grep -q '^#!' || fail "$f senza shebang"
done

echo "Controlli OK: $NAME $VERSION ($VCODE)"
[ "${1:-}" = "--check" ] && exit 0

# --- Build -----------------------------------------------------------------
command -v zip >/dev/null || fail "serve il comando zip"
mkdir -p "$ROOT/dist"
OUT="$ROOT/dist/$NAME-$VERSION.zip"
rm -f "$OUT" "$OUT.sha256"
(
    cd "$MOD"
    # Date fisse = zip riproducibile (stesso contenuto -> stesso hash)
    find . -exec touch -h -d '2000-01-01 00:00:00' {} +
    find . -type f -name '*.sh' -exec chmod 755 {} +
    zip -X -9 -q -r "$OUT" . -x '*.DS_Store' -x '*/.gitkeep'
)
(cd "$ROOT/dist" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256")
echo "Creato: dist/$(basename "$OUT")"
cat "$OUT.sha256"
