#!/bin/bash
# Сводит присланный .cer с приватным ключом, оставшимся на этой машине, и кладёт
# готовое удостоверение в связку.
#   ./install-cert.sh ~/Downloads/developerID_application.cer
set -euo pipefail
cd "$(dirname "$0")"

cer="${1:-}"
key="${DEVID_KEY:-signing/devid.key}"

[ -f "$cer" ] || { echo "нужен путь до .cer: ./install-cert.sh file.cer"; exit 1; }
[ -f "$key" ] || { echo "нет приватного ключа $key (парный к CSR, без него .cer бесполезен)"; exit 1; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# .cer в DER, для p12 нужен PEM.
openssl x509 -inform DER -in "$cer" -out "$tmp/cert.pem" 2>/dev/null || cp "$cer" "$tmp/cert.pem"

# Одноразовый пароль, p12 живёт секунды во временной папке.
pass=$(openssl rand -hex 16)
openssl pkcs12 -export -legacy -out "$tmp/devid.p12" -inkey "$key" -in "$tmp/cert.pem" -passout "pass:$pass"

# -T разрешает codesign брать ключ без диалога на каждую подпись.
security import "$tmp/devid.p12" -P "$pass" -T /usr/bin/codesign

echo
security find-identity -v -p codesigning | grep "Developer ID Application" \
    && echo "готово, дальше: ./notarize.sh" \
    || echo "удостоверение не появилось: .cer не от этой пары ключей?"
