#!/bin/bash
# create_cert.sh - Generates and trusts a local self-signed code signing certificate
set -e

echo "=== Generating Local Code-Signing Certificate ==="

# 1. Generate private key and certificate using openssl config
openssl req -new -x509 -newkey rsa:2048 -nodes \
  -keyout dev.key \
  -out dev.crt \
  -days 3650 \
  -config openssl.conf \
  -extensions v3_req

# 2. Package into P12 container
# We use a dummy password 'audiologue'
openssl pkcs12 -export \
  -out dev.p12 \
  -inkey dev.key \
  -in dev.crt \
  -passout pass:audiologue

# 3. Import P12 into the login keychain
echo "Importing certificate into your login keychain..."
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
security import dev.p12 \
  -k "$KEYCHAIN" \
  -P audiologue \
  -T /usr/bin/codesign

# 4. Set trust settings for code signing
echo "Requesting system trust for the certificate (you may be prompted for your password/TouchID)..."
security add-trusted-cert -d -r trustRoot -p codeSign -k "$KEYCHAIN" dev.crt

# 5. Clean up private key/certs from workspace for security
rm -f dev.key dev.crt dev.p12 openssl.conf

echo "=== Certificate setup completed successfully! ==="
echo "Signing identity 'Audiologue Dev' is now ready for codesigning."
