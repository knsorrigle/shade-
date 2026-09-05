#!/usr/bin/env bash
# Create a self-signed code-signing certificate so local builds keep a stable
# identity — and therefore keep their Screen Recording permission.
#
#   ./scripts/create-dev-cert.sh
#   ./scripts/build-app.sh --sign "MetalShade Dev"
#
# WHY THIS EXISTS
#
# macOS keys the Screen Recording grant to the bundle identifier *and* the code
# signature. An ad-hoc signature changes on every rebuild, so every rebuild
# looks like a different app and the permission has to be granted again. That
# makes it very easy to test a fresh build that silently has no permission.
#
# Signing with a certificate that stays the same across rebuilds fixes it: the
# grant is given once and survives.
#
# WHAT THIS CHANGES ON YOUR MACHINE
#
#   - Adds one certificate and private key named "MetalShade Dev" to your
#     *login* keychain. Nothing is installed system-wide and no sudo is used.
#   - Marks that certificate as trusted for code signing, in the login keychain
#     only. macOS may ask you to confirm.
#
# It is a local development certificate. It is not a Developer ID, cannot
# notarize, and does nothing for anyone else's Mac. Remove it any time with:
#
#   security delete-certificate -c "MetalShade Dev"
set -euo pipefail

name="MetalShade Dev"
keychain="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$name"; then
    echo "Identity '$name' already exists. Build with:"
    echo "  ./scripts/build-app.sh --sign \"$name\""
    exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "==> Generating a self-signed code-signing certificate"
openssl req -x509 -newkey rsa:2048 -keyout "$work/key.pem" -out "$work/cert.pem" \
    -days 3650 -nodes -subj "/CN=$name/O=MetalShade" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1

openssl pkcs12 -export -out "$work/dev.p12" -inkey "$work/key.pem" \
    -in "$work/cert.pem" -passout pass: -name "$name" >/dev/null 2>&1

echo "==> Importing into your login keychain"
# -T authorises codesign to use the key without prompting on every build.
security import "$work/dev.p12" -k "$keychain" -P "" -T /usr/bin/codesign

echo "==> Trusting it for code signing (login keychain only)"
# May prompt for confirmation. Failure here is not fatal; the identity can still
# work, so the check below is what decides.
security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$work/cert.pem" \
    2>/dev/null || echo "    (trust step declined or unavailable — continuing)"

echo
if security find-identity -v -p codesigning | grep -q "$name"; then
    echo "Ready. Build signed builds with:"
    echo "  ./scripts/build-app.sh --sign \"$name\""
    echo
    echo "Grant Screen Recording once to the resulting app. It will survive rebuilds."
else
    echo "The identity was not accepted as valid for code signing." >&2
    echo "Check what is present with: security find-identity -v -p codesigning" >&2
    exit 1
fi
