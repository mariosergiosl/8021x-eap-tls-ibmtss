#!/bin/bash
#===============================================================================
#
# FILE: 01-provision-tpm.sh
#
# USAGE: bash 01-provision-tpm.sh
#
# DESCRIPTION: Generates RSA key inside TPM 2.0 and creates a CSR using
#              the tpmtest utility (PerryWerneck/tpmtest).
#              Requires tpm2-abrmd running and tpmtest compiled.
#
# AUTHOR:
#    Mario Luz (ml), mario.mssl[at]gmail.com
#
# VERSION: 1.0
# CREATED: 2026-03-26
#
#===============================================================================

set -e

WORK_DIR="/opt/8021x-eap-tls-ibmtss/client"
TPMTEST="/usr/local/src/tpmtest/build/tpmtest"

echo "================================================================"
echo "  TPM 2.0 Provisioning — Key generation + CSR"
echo "================================================================"

# Check tpm2-abrmd
if ! systemctl is-active --quiet tpm2-abrmd; then
  echo "[ERROR] tpm2-abrmd is not running."
  echo "        Run: systemctl enable --now tpm2-abrmd.service"
  exit 1
fi

# Check tpmtest
if [ ! -x "$TPMTEST" ]; then
  echo "[ERROR] tpmtest not found at $TPMTEST"
  echo "        Build: cd /usr/local/src/tpmtest && meson setup build && meson compile -C build"
  exit 1
fi

# Create work directory
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Remove previous keys if present
if [ -f tpmtest.key ]; then
  echo "[WARN] Existing tpmtest.key found — backing up to tpmtest.key.bak"
  mv tpmtest.key tpmtest.key.bak
  mv tpmtest.pub tpmtest.pub.bak 2>/dev/null || true
  mv tpmtest.csr tpmtest.csr.bak 2>/dev/null || true
fi

echo ""
echo "--- Generating RSA key in TPM and CSR ---"
"$TPMTEST" genkey gencsr

echo ""
echo "--- Verifying generated files ---"
ls -la "$WORK_DIR"/tpmtest.*

echo ""
echo "--- Key format ---"
head -1 tpmtest.key

echo ""
echo "--- CSR verification ---"
openssl req -in tpmtest.csr -noout -verify
openssl req -in tpmtest.csr -noout -text | grep -E 'Subject:|Public Key Algorithm|Public-Key'

echo ""
echo "================================================================"
echo "  Provisioning complete."
echo "  Next step: transfer tpmtest.csr to the CA and run 02-sign-cert.sh"
echo "  SCP command:"
echo "    scp $WORK_DIR/tpmtest.csr root@192.168.56.200:/opt/8021x-eap-tls-ibmtss/certs/"
echo "================================================================"
