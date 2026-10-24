#!/bin/bash
# One-time: creates a stable "Meeting Agent Dev" signing certificate so macOS keeps the
# Screen Recording permission across rebuilds.
set -euo pipefail
NAME="Meeting Agent Dev"
KC="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning | grep -q "$NAME"; then
  echo "Certificate '$NAME' already exists. Nothing to do."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CNF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/openssl.cnf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/id.p12" -passout pass:meetingagent 2>/dev/null

security import "$TMP/id.p12" -k "$KC" -P meetingagent -T /usr/bin/codesign
echo "A macOS window may ask for your Mac password to trust the certificate. Enter it."
security add-trusted-cert -r trustRoot -p codeSign -k "$KC" "$TMP/cert.pem"
echo "Done. Certificate '$NAME' created."
