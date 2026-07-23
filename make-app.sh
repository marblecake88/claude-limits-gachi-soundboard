#!/bin/bash
# Собирает LimitNotifier.app из SwiftPM. Без Xcode-проекта.
# ./make-app.sh release          собрать
# ./make-app.sh release install  собрать и поставить в /Applications
# ./make-app.sh release zip      собрать и упаковать в zip
set -euo pipefail
cd "$(dirname "$0")"

config="${1:-release}"
app="build/LimitNotifier.app"

# Тикет нотаризации привязан к хэшу бандла. Пока в build/ лежит отправленный,
# но ещё не заштампованный бандл, пересборка сделает тикет непригодным.
if [ -f build/.notarization-id ] && [ -d "$app" ] && ! xcrun stapler validate "$app" >/dev/null 2>&1; then
    echo "build/ ждёт штамп нотаризации ($(cat build/.notarization-id))"
    echo "  доштамповать: ./notarize.sh staple"
    echo "  собрать всё:  rm build/.notarization-id && $0 $*"
    exit 1
fi

swift build -c "$config"
bin="$(swift build -c "$config" --show-bin-path)/LimitNotifier"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/sounds"
cp "$bin" "$app/Contents/MacOS/LimitNotifier"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/cat.png "$app/Contents/Resources/"
cp Resources/sounds/*.mp3 Resources/sounds/index.json "$app/Contents/Resources/sounds/"

# Не-ASCII имя файла ломает подпись после zip: macOS и zip нормализуют юникод
# по-разному, и на другом маке Gatekeeper пишет "приложение повреждено".
if find "$app/Contents/Resources" | LC_ALL=C grep -q '[^ -~]'; then
    echo "не-ASCII имя в бандле, сломает подпись:"
    find "$app/Contents/Resources" | LC_ALL=C grep '[^ -~]' | sed 's/^/  /'
    exit 1
fi

# Подписываем одним сертификатом и локально, и для раздачи: разрешение на связку
# привязано к сертификату и слетает, если сборки подписаны разным. Developer ID
# в приоритете, иначе Apple Development, иначе ad-hoc.
id="${CODESIGN_ID:-}"
if [ -z "$id" ]; then
    list=$(security find-identity -v -p codesigning 2>/dev/null)
    id=$(awk -F'"' '/Developer ID Application/{print $2; exit}' <<<"$list")
    [ -z "$id" ] && id=$(awk -F'"' '/Apple Development/{print $2; exit}' <<<"$list")
fi
if [ -n "$id" ]; then
    codesign --force --options runtime --sign "$id" "$app"
    echo "подписано: $id"
else
    codesign --force --sign - "$app"
    echo "ad-hoc подпись, сертификата нет"
fi
echo "готово: $app"

case "${2:-}" in
install)
    # open не перезапускает уже запущенное приложение, поэтому сначала гасим старое.
    pkill -f "LimitNotifier.app/Contents/MacOS/LimitNotifier" 2>/dev/null || true
    for _ in 1 2 3 4 5; do pgrep -f "LimitNotifier.app/Contents/MacOS/LimitNotifier" >/dev/null || break; sleep 0.5; done
    pkill -9 -f "LimitNotifier.app/Contents/MacOS/LimitNotifier" 2>/dev/null || true
    rm -rf /Applications/LimitNotifier.app
    cp -R "$app" /Applications/
    open /Applications/LimitNotifier.app
    echo "установлено в /Applications"
    ;;
zip)
    # ditto, а не zip: сохраняет подпись бандла.
    ditto -c -k --sequesterRsrc --keepParent "$app" build/LimitNotifier.zip
    echo "архив: build/LimitNotifier.zip"
    ;;
*)
    echo "дальше: $0 $config install   или   $0 $config zip"
    ;;
esac
