#!/usr/bin/env bash
#
# Create a stable, self-signed code-signing identity for local builds.
#
# Why this exists: ad-hoc signing (codesign -s -) derives the app's identity
# from the binary's own hash, so every rebuild looks like a different app to
# macOS. Privacy grants are keyed to that identity, which means the Screen
# Recording permission the screenshot pipeline needs is revoked on every
# build. Signing with a fixed certificate instead keeps the identity stable,
# so the grant is given once and then persists.
#
# This is for local development only. It is not a Developer ID, it cannot
# notarise, and it does nothing for anyone else who builds this repo.
#
# Run it once:
#   ./tools/make-signing-identity.sh
#
# macOS will ask for your login password when the certificate is marked as
# trusted for code signing. That prompt is expected and is the only one.

set -euo pipefail

NAME="Runbranch Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$NAME"; then
  echo "==> identity already present: $NAME"
  echo "    nothing to do. ./make-app.sh will use it."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> generating a self-signed code-signing certificate"

# extendedKeyUsage=codeSigning is what makes codesign willing to use it, and
# basicConstraints=CA:true lets it be trusted as its own root.
cat > "$WORK/openssl.cnf" <<CNF
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no

[ dn ]
CN = $NAME

[ ext ]
basicConstraints       = critical,CA:true
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
subjectKeyIdentifier   = hash
CNF

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -config "$WORK/openssl.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

# A single .p12 keeps the key and certificate together on import, which is
# what codesign needs to find a usable identity rather than a bare cert.
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/identity.p12" -passout pass: -name "$NAME" 2>/dev/null

echo "==> importing into the login keychain"
# -T /usr/bin/codesign pre-authorises codesign so it does not prompt on every
# single build.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "" \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null

echo "==> marking it trusted for code signing (macOS will ask for your password)"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$NAME"; then
  cat <<DONE

==> done. "$NAME" is ready.

    Next, and only once:
      1. ./make-app.sh
      2. System Settings > Privacy & Security > Screen Recording
         Remove any old Runbranch entries, then add:
           $(cd "$(dirname "$0")/.." && pwd)/Runbranch.app
      3. ./tools/screenshot.sh

    Rebuilds keep the same identity from now on, so the grant sticks and
    step 2 never needs repeating.
DONE
else
  echo "!! the identity did not become valid for code signing." >&2
  echo "   check it in Keychain Access under login > My Certificates:" >&2
  echo "   '$NAME' should be set to Always Trust for Code Signing." >&2
  exit 1
fi
