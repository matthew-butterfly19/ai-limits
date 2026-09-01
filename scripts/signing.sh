#!/bin/bash
# Tworzy lokalną tożsamość podpisu dla AILimits — po to, żeby Keychain
# przestał pytać o hasło po każdej instalacji.
#
# Sedno problemu: przy podpisie ad-hoc (`codesign --sign -`) tożsamością kodu
# jest odcisk (cdhash) samego pliku, więc **każdy build to dla systemu inna
# aplikacja**. Zgoda "Zawsze zezwalaj", którą klika się w oknie Keychaina,
# zapisuje się dla tej jednej tożsamości i po kolejnym `install.sh` już nie
# obowiązuje. Podpis własnym certyfikatem daje wymaganie
# `identifier "dev.ailimits.AILimits" and certificate leaf = H"…"`, które jest
# takie samo dla wszystkich buildów — zgodę klika się raz.
#
# Certyfikat jest self-signed, ważny 10 lat, leży w keychainie login i nigdzie
# nie wychodzi. Usunięcie: `./scripts/signing.sh --remove`.
set -euo pipefail

NAME="AI Limits Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if [[ "${1:-}" == "--remove" ]]; then
  security delete-identity -c "$NAME" "$KEYCHAIN" 2>/dev/null || true
  echo "usunięto tożsamość „${NAME}”"
  exit 0
fi

if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "$NAME"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -subj "/CN=$NAME" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false" >/dev/null 2>&1

# `security` nie umie zweryfikować MAC-a nowego formatu PKCS#12 z OpenSSL 3
# ("MAC verification failed"), stąd wymuszone stare algorytmy i hasło — puste
# hasło wywraca import na tej samej ścieżce.
openssl pkcs12 -export -legacy -macalg sha1 \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES \
  -in "$WORK/cert.pem" -inkey "$WORK/key.pem" -name "$NAME" \
  -out "$WORK/id.p12" -passout pass:ailimits >/dev/null 2>&1

# -A: /usr/bin/codesign używa klucza bez pytania o zgodę przy każdym buildzie.
security import "$WORK/id.p12" -k "$KEYCHAIN" -P ailimits -T /usr/bin/codesign -A >/dev/null
# Bez zaufania do podpisu certyfikat nie liczy się jako tożsamość do podpisu
# kodu (`find-identity` pokazuje 0). Domena użytkownika, nie systemowa — nie
# wymaga hasła administratora.
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem" >/dev/null

echo "$NAME"
