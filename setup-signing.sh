#!/bin/zsh
# One-time: create a self-signed "Hephaestus Dev" code-signing certificate in your login keychain.
# A stable signature stops macOS from forgetting the Accessibility permission after every rebuild.
set -euo pipefail
NAME="Hephaestus Dev"
if security find-identity -p codesigning | grep -q "$NAME"; then echo "'$NAME' already exists."; exit 0; fi
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > "$T/o.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
# OpenSSL 3.x writes a PKCS12 format macOS `security import` rejects; -legacy fixes it (LibreSSL lacks the flag).
LEGACY=""; [[ "$(openssl pkcs12 -help 2>&1)" == *-legacy* ]] && LEGACY="-legacy" || true
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$T/o.cnf" -keyout "$T/k.pem" -out "$T/c.pem"
openssl pkcs12 -export $LEGACY -inkey "$T/k.pem" -in "$T/c.pem" -out "$T/id.p12" -passout pass:tmp
KC="$HOME/Library/Keychains/login.keychain-db"
security import "$T/id.p12" -k "$KC" -P tmp -T /usr/bin/codesign
security add-trusted-cert -p codeSign -k "$KC" "$T/c.pem"   # asks for your login password
echo "Done. Now run ./build.sh"
