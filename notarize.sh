#!/bin/bash
# Подписывает Developer ID, нотаризует у Apple, штампует тикет. После этого
# .app открывается двойным кликом на любом маке.
#
# Данные ключа для нотаризации берём из notary.env (в репозиторий не кладём):
#   NOTARY_KEY=/path/AuthKey_XXXX.p8
#   NOTARY_KEY_ID=XXXX
#   NOTARY_ISSUER=xxxxxxxx-....
#
# ./notarize.sh         полный прогон
# ./notarize.sh staple  доштамповать уже принятую отправку без пересборки
set -euo pipefail
cd "$(dirname "$0")"

app=build/LimitNotifier.app
zip=build/LimitNotifier.zip

repack() { rm -f "$zip"; ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"; }

if [ "${1:-}" = "staple" ]; then
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    repack
    spctl --assess --type execute --verbose=4 "$app" || true
    echo "готово: $zip"
    exit 0
fi

[ -f notary.env ] && source notary.env
: "${NOTARY_KEY:?нет notary.env с NOTARY_KEY/NOTARY_KEY_ID/NOTARY_ISSUER}"

id=$(security find-identity -v -p codesigning 2>/dev/null \
     | awk -F'"' '/Developer ID Application/{print $2; exit}')
if [ -z "$id" ]; then
    echo "нет сертификата Developer ID Application в связке (см. README)"
    exit 1
fi

./make-app.sh release

# Hardened runtime и метка времени обязательны для нотаризации.
echo "подписываю: $id"
codesign --force --options runtime --timestamp --sign "$id" "$app"
codesign --verify --strict --verbose=2 "$app"
repack

# Отправку и ожидание разделяем: с --wait процесс висит десятками минут и любой
# внешний таймаут убьёт прогон, хотя отправка на стороне Apple живёт.
echo "отправляю"
sub=$(xcrun notarytool submit "$zip" \
        --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" \
        --output-format json 2>/dev/null \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
[ -z "$sub" ] && { echo "не получил id отправки"; exit 1; }
echo "$sub" > build/.notarization-id
echo "отправка: $sub"

echo "жду вердикт"
xcrun notarytool wait "$sub" \
    --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --timeout 2h

# Штамп кладёт тикет в бандл, чтобы мак не ходил к Apple при запуске.
xcrun stapler staple "$app"
xcrun stapler validate "$app"
repack

echo
spctl --assess --type execute --verbose=4 "$app" || true
echo "готово: $zip"
