#!/bin/bash
#===============================================================================
#
# FILE: 00-check-env.sh
#
# USAGE: bash 00-check-env.sh
#
# DESCRIPTION: Environment diagnostic script for 802.1X EAP-TLS with TPM 2.0.
#              Checks all required components before provisioning.
#
# AUTHOR:
#    Mario Luz (ml), mario.mssl[at]gmail.com
#
# VERSION: 1.0
# CREATED: 2026-03-26
#
#===============================================================================

set -e

PASS="[  OK  ]"
FAIL="[ FAIL ]"
WARN="[ WARN ]"

echo "================================================================"
echo "  802.1X EAP-TLS TPM 2.0 — Environment Check"
echo "================================================================"

# OS
echo ""
echo "--- OS ---"
cat /etc/os-release | grep -E '^NAME|^VERSION='

# OpenSSL
echo ""
echo "--- OpenSSL ---"
OSSL_VER=$(openssl version)
echo "$OSSL_VER"
echo "$OSSL_VER" | grep -qE '3\.[0-9]' && \
  echo "$WARN OpenSSL 3.x detected — tpm2-tss-engine patch required" || \
  echo "$PASS OpenSSL 1.x — no patch required"

# TPM device
echo ""
echo "--- TPM Device ---"
if ls /dev/tpm0 &>/dev/null; then
  echo "$PASS /dev/tpm0 found"
  cat /sys/class/tpm/tpm0/tpm_version_major 2>/dev/null && \
    echo "$PASS TPM version: $(cat /sys/class/tpm/tpm0/tpm_version_major)"
else
  echo "$FAIL /dev/tpm0 not found — TPM not available"
fi

# tpm2-abrmd
echo ""
echo "--- tpm2-abrmd ---"
if systemctl is-active --quiet tpm2-abrmd; then
  echo "$PASS tpm2-abrmd.service is running"
else
  echo "$FAIL tpm2-abrmd.service is NOT running"
  echo "       Run: systemctl enable --now tpm2-abrmd.service"
fi

# tpm2-tss-engine
echo ""
echo "--- tpm2-tss-engine ---"
if openssl engine tpm2 -t 2>/dev/null | grep -q "available"; then
  echo "$PASS engine tpm2 is available"
else
  echo "$FAIL engine tpm2 NOT available"
  echo "       Check: ln -sf /usr/lib64/engines-3/tpm2tss.so /usr/lib64/engines-3/tpm2.so"
fi

# tpm2-openssl provider
echo ""
echo "--- tpm2-openssl provider ---"
if openssl list -providers 2>/dev/null | grep -q tpm2; then
  echo "$PASS tpm2 provider loaded"
else
  echo "$WARN tpm2 provider not listed (may still work via engine)"
fi

# tpmtest binary
echo ""
echo "--- tpmtest binary ---"
TPMTEST_BIN="/usr/local/src/tpmtest/build/tpmtest"
if [ -x "$TPMTEST_BIN" ]; then
  echo "$PASS tpmtest found at $TPMTEST_BIN"
else
  echo "$FAIL tpmtest not found at $TPMTEST_BIN"
  echo "       Build: cd /usr/local/src/tpmtest && meson setup build && meson compile -C build"
fi

# NetworkManager
echo ""
echo "--- NetworkManager ---"
if systemctl is-active --quiet NetworkManager; then
  echo "$PASS NetworkManager is running"
  nmcli -v 2>/dev/null | head -1
else
  echo "$FAIL NetworkManager is NOT running"
fi

# wpa_supplicant
echo ""
echo "--- wpa_supplicant ---"
if which wpa_supplicant &>/dev/null; then
  echo "$PASS $(wpa_supplicant -v 2>&1 | head -1)"
else
  echo "$FAIL wpa_supplicant not found"
fi

echo ""
echo "================================================================"
echo "  Check complete"
echo "================================================================"
