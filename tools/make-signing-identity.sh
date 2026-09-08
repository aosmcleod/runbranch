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

# An earlier run can leave a certificate that imported but never became
# trusted, and that one is invisible to the check above because it is not
# valid. Clear it out so re-running is safe rather than stacking duplicates.
if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "==> removing an earlier, unusable '$NAME' certificate"
  while security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; do
    security delete-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1 || break
  done
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
#
# The passphrase is random rather than empty on purpose: an empty-password
# PKCS#12 fails macOS's import with "MAC verification failed (wrong password?)",
# which reads like the password is wrong when the real problem is that there
# isn't one. It never leaves this function, and the bundle is deleted on exit.
P12_PASS="$(openssl rand -hex 16)"
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/identity.p12" -passout "pass:$P12_PASS" -name "$NAME" 2>/dev/null

# Confirm the bundle is readable before handing it to the keychain, so a bad
# export is reported here rather than as a confusing import failure.
if ! openssl pkcs12 -in "$WORK/identity.p12" -passin "pass:$P12_PASS" \
     -nokeys -noout 2>/dev/null; then
  echo "!! the generated PKCS#12 bundle could not be read back." >&2
  echo "   openssl version: $(openssl version)" >&2
  exit 1
fi

echo "==> importing into the login keychain"
# -T /usr/bin/codesign pre-authorises codesign so it does not prompt on every
# single build.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$P12_PASS" \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null

# Without this the identity imports fine but reports CSSMERR_TP_NOT_TRUSTED and
# codesign refuses to use it.
echo "==> marking it trusted for code signing (macOS will ask for your password)"
if ! security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"; then
  echo "!! could not mark the certificate as trusted." >&2
  echo "   If you cancelled the password prompt, just run this script again." >&2
  echo "   The certificate is imported but unusable until it is trusted." >&2
  exit 1
fi

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
