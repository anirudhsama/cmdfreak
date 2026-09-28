#!/usr/bin/env bash
# One-time setup for .github/workflows/release.yml. Run from the repo root, authed with `gh`.
#
# 1. Creates the "CmdFreak Self-Signed" code-signing identity in the login keychain and stores it
#    as SIGNING_P12_BASE64 / SIGNING_P12_PASSWORD. Every release must be signed with this same
#    identity: Sparkle refuses an update whose signature does not match the running app's.
# 2. Creates the Sparkle EdDSA key pair (private half in the login keychain, account "cmdfreak"),
#    stores the private half as SPARKLE_PRIVATE_KEY and writes the public half into project.yml.
#
# Losing either key strands installed copies: they can no longer verify an update. Both live only
# in the login keychain and in the repo secrets, so back up the keychain items.
set -euo pipefail

IDENTITY="CmdFreak Self-Signed"
SPARKLE_VERSION=2.10.0
SPARKLE_ACCOUNT=cmdfreak
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
# LibreSSL writes a PKCS#12 `security import` accepts; OpenSSL 3 needs -legacy for the same.
OPENSSL=/usr/bin/openssl

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# MARK: Code-signing identity

if security find-identity -p codesigning "$KEYCHAIN" | grep -q "\"$IDENTITY\""; then
    echo "▸ \"$IDENTITY\" already in the login keychain; leaving it and its secrets alone."
else
    echo "▸ Creating \"$IDENTITY\""
    "$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -subj "/CN=$IDENTITY" \
        -addext "basicConstraints=critical,CA:false" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
    P12_PASSWORD="$("$OPENSSL" rand -base64 24)"
    "$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
        -name "$IDENTITY" -out "$WORK/signing.p12" -passout "pass:$P12_PASSWORD"
    security import "$WORK/signing.p12" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign
    base64 -i "$WORK/signing.p12" | tr -d '\n' | gh secret set SIGNING_P12_BASE64
    gh secret set SIGNING_P12_PASSWORD --body "$P12_PASSWORD"
fi

# MARK: Sparkle EdDSA key

echo "▸ Fetching Sparkle $SPARKLE_VERSION tools"
curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
    | tar -xJ -C "$WORK" ./bin/generate_keys
GENERATE_KEYS="$WORK/bin/generate_keys"

# Creates the key on first run and reuses it after. The keychain may ask to allow access.
"$GENERATE_KEYS" --account "$SPARKLE_ACCOUNT" >/dev/null
PUBLIC_KEY="$("$GENERATE_KEYS" --account "$SPARKLE_ACCOUNT" -p)"
"$GENERATE_KEYS" --account "$SPARKLE_ACCOUNT" -x "$WORK/sparkle.key"
gh secret set SPARKLE_PRIVATE_KEY < "$WORK/sparkle.key"

sed -i '' -E "s|^( *SPARKLE_PUBLIC_KEY:).*|\1 \"$PUBLIC_KEY\"|" "$ROOT/project.yml"
echo "▸ SPARKLE_PUBLIC_KEY in project.yml set to $PUBLIC_KEY — commit it."
