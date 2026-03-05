#!/bin/bash
# Generate self-signed TLS certificates for QUIC/WebTransport benchmark.
# WebTransport spec requires short-lived certs (max 14 days) for serverCertificateHashes.
set -euo pipefail

CERT_DIR="$(dirname "$0")/certs"
mkdir -p "$CERT_DIR"

echo "Generating EC P-256 key pair..."
openssl ecparam -genkey -name prime256v1 -out "$CERT_DIR/key.pem" 2>/dev/null
openssl req -new -x509 -key "$CERT_DIR/key.pem" \
    -out "$CERT_DIR/cert.pem" \
    -days 14 \
    -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
    2>/dev/null

# Generate SHA-256 fingerprint for WebTransport serverCertificateHashes
FINGERPRINT=$(openssl x509 -in "$CERT_DIR/cert.pem" -outform der \
    | openssl dgst -sha256 -binary \
    | base64)

echo "$FINGERPRINT" > "$CERT_DIR/fingerprint.txt"

# Also copy to demo dir so the static file server can serve it
DEMO_DIR="$(dirname "$0")/../apps/browser/demo"
cp "$CERT_DIR/fingerprint.txt" "$DEMO_DIR/fingerprint.txt"

echo "✓ Certificate:  $CERT_DIR/cert.pem"
echo "✓ Key:          $CERT_DIR/key.pem"
echo "✓ Fingerprint:  $FINGERPRINT"
echo ""
echo "Certs valid for 14 days. Re-run this script to regenerate."
