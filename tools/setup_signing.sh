#!/usr/bin/env bash
# Creates a stable, self-signed code-signing identity for local builds.
#
# Why this exists: an ad-hoc signature (`codesign -s -`) changes on every build,
# and macOS TCC keys Full Disk Access to the code signature. That means every
# rebuild silently revokes the permission and macOS falls back to per-folder
# prompts. A stable identity makes the grant survive rebuilds.
set -euo pipefail

CN="Dustloft Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CN"; then
  echo "==> Identity '$CN' already exists"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.cnf" <<CNF
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[ dn ]
CN = $CN
[ v3 ]
basicConstraints       = critical,CA:false
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
CNF

echo "==> Generating self-signed code-signing certificate"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/openssl.cnf" 2>/dev/null

# macOS's security tool cannot read OpenSSL 3 defaults (AES + SHA-256 MAC),
# so the archive must be written with legacy PBE algorithms.
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/id.p12" -passout pass:dustloft -name "$CN" \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 2>/dev/null

echo "==> Importing into your login keychain"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P dustloft -T /usr/bin/codesign -A >/dev/null

echo "==> Trusting it for code signing (user-level, no sudo needed)"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" 2>/dev/null \
  || echo "    (trust step reported an issue; continuing)"

security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CN"; then
  echo "==> Ready. Builds will now use '$CN'."
else
  echo "!! Identity not usable; builds will fall back to ad-hoc signing."
  exit 1
fi
