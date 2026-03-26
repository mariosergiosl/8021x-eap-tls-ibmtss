#!/bin/bash
#===============================================================================
#
# FILE: 02-sign-cert.sh
#
# USAGE: bash 02-sign-cert.sh <CLIENT_IP>
#
# DESCRIPTION: Signs the client CSR with the lab CA and transfers the
#              resulting certificate back to the client.
#              Run this script on gwlocal (the CA host).
#
# AUTHOR:
#    Mario Luz (ml), mario.mssl[at]gmail.com
#
# VERSION: 1.0
# CREATED: 2026-03-26
#
#===============================================================================

set -e

CLIENT_IP="${1:-192.168.56.163}"
CERTS_DIR="/opt/8021x-eap-tls-ibmtss/certs"
CA_DIR="/opt/8021x-eap-tls-lab"
CLIENT_DIR="/opt/8021x-eap-tls-ibmtss/client"

echo "================================================================"
echo "  CA Signing — tpmtest.csr → tpmtest.crt"
echo "  Client IP: $CLIENT_IP"
echo "================================================================"

# Check CA files
if [ ! -f "$CA_DIR/certs/ca-lab.crt" ] || [ ! -f "$CA_DIR/private/ca-lab.key" ]; then
  echo "[ERROR] CA files not found at $CA_DIR"
  echo "        Expected: $CA_DIR/certs/ca-lab.crt and $CA_DIR/private/ca-lab.key"
  exit 1
fi

# Create certs directory
mkdir -p "$CERTS_DIR"

# Receive CSR from client
echo ""
echo "--- Receiving CSR from client ($CLIENT_IP) ---"
scp root@"$CLIENT_IP":"$CLIENT_DIR/tpmtest.csr" "$CERTS_DIR/"

# Sign with CA
echo ""
echo "--- Signing CSR with lab CA ---"
openssl x509 -req \
  -in "$CERTS_DIR/tpmtest.csr" \
  -CA "$CA_DIR/certs/ca-lab.crt" \
  -CAkey "$CA_DIR/private/ca-lab.key" \
  -CAcreateserial \
  -out "$CERTS_DIR/tpmtest.crt" \
  -days 365 -sha256

# Verify signed certificate
echo ""
echo "--- Certificate details ---"
openssl x509 -in "$CERTS_DIR/tpmtest.crt" -noout -text | \
  grep -E 'Issuer:|Subject:|Not After|Public Key Algorithm'

# Transfer back to client
echo ""
echo "--- Transferring certificate and CA cert to client ---"
scp "$CERTS_DIR/tpmtest.crt" root@"$CLIENT_IP":"$CLIENT_DIR/"
scp "$CA_DIR/certs/ca-lab.crt" root@"$CLIENT_IP":"$CLIENT_DIR/"

echo ""
echo "================================================================"
echo "  Signing complete."
echo "  Files transferred to $CLIENT_IP:$CLIENT_DIR/"
echo "  Next step: run wpa_supplicant or nmcli on the client"
echo "================================================================"
