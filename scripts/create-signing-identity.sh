#!/usr/bin/env bash
# Creates the self-signed code signing identity "MeetingAssistant Dev" in the login keychain.
# A stable identity keeps the macOS permissions (TCC) across rebuilds; never sign ad-hoc.
# The identity is trusted for code signing only. macOS asks for the Mac password once.
set -euo pipefail

NAME="MeetingAssistant Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Captured first: with pipefail, `security … | grep -q` can fail although the identity exists.
IDENTITIES="$(security find-identity -v -p codesigning)"
if [[ "$IDENTITIES" == *"\"$NAME\""* ]]; then
  echo "Identity \"$NAME\" already exists."
  exit 0
fi

WORK="$(mktemp -d)"
# The private key exists on disk only for the moment of the import.
trap 'rm -f "$WORK"/key.pem "$WORK"/cert.p12 "$WORK"/cert.pem "$WORK"/cert.conf; rmdir "$WORK"' EXIT

cat > "$WORK/cert.conf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no

[ dn ]
CN = $NAME

[ ext ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.conf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
PASSWORD="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
  -out "$WORK/cert.p12" -passout "pass:$PASSWORD"

security import "$WORK/cert.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign
echo "Trusting the certificate for code signing (macOS asks for your password)…"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

security find-identity -v -p codesigning | grep "\"$NAME\""
