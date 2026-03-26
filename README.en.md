# 802.1X EAP-TLS with TPM 2.0 — IBM TSS Engine

This repository documents the research, diagnosis, and compatibility fix for `tpm2-tss-engine` with OpenSSL 3.x, enabling 802.1X EAP-TLS authentication using an RSA key protected by TPM 2.0.

> **Main result:** `tpm2-tss-engine` v1.2.0 has a compatibility bug with OpenSSL 3.x that prevents correct RSA signing during EAP-TLS handshakes. This repository documents the full diagnosis and the applied fix, validated on openSUSE Leap 15.6 (OpenSSL 3.1.4) and SLES 16 (OpenSSL 3.5.0).

> **Related repository:** [8021x-eap-tls-lab](https://github.com/mariosergiosl/8021x-eap-tls-lab) — PKCS#11 solution validated on SLES 16 (previous workaround before this patch).

> **Reference:** [PerryWerneck/tpmtest](https://github.com/PerryWerneck/tpmtest) — test application used to scope and reproduce the problem.

---

## Architecture and Topology

The lab simulates a simplified corporate environment without FreeRADIUS, where `gwlocal` acts simultaneously as the 802.1X Authenticator and internal EAP server via `hostapd`.

| Host | Role | OS | Interface | IP |
|---|---|---|---|---|
| **gwlocal** | Authenticator + EAP-TLS Server (`hostapd`) | openSUSE Leap 15.6 | eth3 | 192.168.56.200/24 |
| **sles156a16a** | Supplicant (`wpa_supplicant` / NetworkManager) | openSUSE Leap 15.6 | eth4 | 192.168.56.166/24 |

Virtualization: VirtualBox on Windows 11. TPM: VirtualBox native vTPM 2.0.

---

## Component Stack

| Component | Role | Availability |
|---|---|---|
| `tpm2-tss-engine` | OpenSSL engine for TPM 2.0 (RSA key) | RPM SLES/Leap — **requires patch** |
| `tpm2-openssl` | Native OpenSSL 3 provider for TPM 2.0 | RPM SLES/Leap |
| `tpm2.0-abrmd` | TPM Resource Manager (required) | RPM SLES/Leap |
| `tpmtest` | TPM key + CSR generation utility | Build from source (PerryWerneck/tpmtest) |
| `NetworkManager` | Network manager with 802.1X support | Default on SLES/Leap |
| `wpa_supplicant` | EAP-TLS supplicant | RPM SLES/Leap |

---

## The Bug — `EVP_MD_CTX_set_update_fn` ignored in OpenSSL 3.x

### Problem

`tpm2-tss-engine` v1.2.0 registers a custom update function via
`EVP_MD_CTX_set_update_fn()` to route data through the TPM via
`Esys_SequenceUpdate`. In OpenSSL 3.x, this function is **deprecated and
silently ignored** in certain EVP code paths.

Result: `Esys_SequenceComplete` is called with no data → TPM returns
SHA-256 of empty string → invalid RSA signature:

```
error:02000068:rsa routines:ossl_rsa_verify:bad signature
error:1C880004:Provider routines:rsa_verify:RSA lib
```

### Diagnosis

The hash signed by the TPM was invariably:

```
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
```

This is the SHA-256 of an empty string — confirming `digest_update` never received the data.

### Fix

In `rsa_signctx()` in `tpm2-tss-engine-rsa.c`, replace the `digest_finish()`
call with a direct `EVP_DigestFinal_ex()`, passing the resulting hash directly
to `Esys_Sign()` with a null validation ticket.

Valid for **unrestricted** keys (default for `tpmtest` and `tpm2tss-genkey`).

See [`patch/fix-openssl3-digest-sign.patch`](patch/fix-openssl3-digest-sign.patch) and [`patch/README.md`](patch/README.md).

---

## Installation and Build

### Prerequisites (openSUSE Leap 15.6 / SLES 15 SP6+)

```bash
zypper install -y \
  tpm2-tss-engine tpm2-tss-engine-devel \
  tpm2-openssl tpm2.0-abrmd tpm2.0-tools \
  tpm2-0-tss tpm2-0-tss-devel \
  NetworkManager NetworkManager-devel \
  wpa_supplicant gcc-c++ meson git \
  autoconf automake libtool autoconf-archive
 
systemctl enable --now tpm2-abrmd.service
```

### Build tpmtest (PerryWerneck/tpmtest)

```bash
cd /usr/local/src
git clone https://github.com/PerryWerneck/tpmtest.git
cd tpmtest
meson setup build
cd build
meson compile
```

### Apply patch to tpm2-tss-engine

```bash
cd /usr/local/src
git clone https://github.com/tpm2-software/tpm2-tss-engine.git
cd tpm2-tss-engine
./bootstrap
./configure PKG_CONFIG_PATH=/usr/lib64/pkgconfig
 
patch -p1 < /opt/8021x-eap-tls-ibmtss/patch/fix-openssl3-digest-sign.patch
 
make -j$(nproc) CFLAGS="-Wno-deprecated-declarations -Wno-error"
cp .libs/libtpm2tss.so /usr/lib64/engines-3/libtpm2tss.so
 
ln -sf /usr/lib64/engines-3/tpm2tss.so /usr/lib64/engines-3/tpm2.so
 
openssl engine tpm2 -t
# Expected: [ available ]
```

---

## TPM Provisioning

```bash
mkdir -p /opt/8021x-eap-tls-ibmtss/client
cd /opt/8021x-eap-tls-ibmtss/client
 
/usr/local/src/tpmtest/build/tpmtest genkey gencsr
 
head -1 tpmtest.key
# Expected: -----BEGIN TSS2 PRIVATE KEY-----
 
openssl req -in tpmtest.csr -noout -verify
# Expected: Certificate request self-signature verify OK
```

### Sign certificate at CA (gwlocal)

```bash
scp root@<CLIENT_IP>:/opt/8021x-eap-tls-ibmtss/client/tpmtest.csr \
  /opt/8021x-eap-tls-ibmtss/certs/
 
openssl x509 -req \
  -in /opt/8021x-eap-tls-ibmtss/certs/tpmtest.csr \
  -CA /opt/8021x-eap-tls-lab/certs/ca-lab.crt \
  -CAkey /opt/8021x-eap-tls-lab/private/ca-lab.key \
  -CAcreateserial \
  -out /opt/8021x-eap-tls-ibmtss/certs/tpmtest.crt \
  -days 365 -sha256
 
scp /opt/8021x-eap-tls-ibmtss/certs/tpmtest.crt \
  root@<CLIENT_IP>:/opt/8021x-eap-tls-ibmtss/client/
scp /opt/8021x-eap-tls-lab/certs/ca-lab.crt \
  root@<CLIENT_IP>:/opt/8021x-eap-tls-ibmtss/client/
```

---

## Running

### Server (gwlocal)

```bash
hostapd -ddKt /etc/hostapd/hostapd.conf > /var/log/hostapd.log 2>&1 &
```

### Client via wpa_supplicant

```bash
wpa_supplicant -D wired -i eth4 \
  -c /etc/wpa_supplicant/wpa_supplicant_ibmtss.conf -d
```

### Client via NetworkManager

```bash
nmcli connection add \
  type ethernet ifname eth4 con-name "8021x-ibmtss" \
  802-1x.eap tls \
  802-1x.identity "TPM2 Test Certificate" \
  802-1x.ca-cert /opt/8021x-eap-tls-ibmtss/client/ca-lab.crt \
  802-1x.client-cert /opt/8021x-eap-tls-ibmtss/client/tpmtest.crt \
  802-1x.private-key /opt/8021x-eap-tls-ibmtss/client/tpmtest.key \
  802-1x.private-key-password-flags 4
 
nmcli connection up "8021x-ibmtss"
```

### Expected success output

**Client:**

```
eth4: CTRL-EVENT-EAP-SUCCESS EAP authentication completed successfully
eth4: CTRL-EVENT-CONNECTED - Connection to 01:80:c2:00:00:03 completed
```

**Server:**

```
IEEE 802.1X: BE_AUTH entering state SUCCESS
AUTH_PAE entering state AUTHENTICATED
AP-STA-CONNECTED 08:00:27:13:33:54
IEEE 802.1X: authorizing port
```

---

## Repository Structure

```
8021x-eap-tls-ibmtss/
├── README.md                           # Main documentation (PT-BR)
├── README.en.md                        # This file (EN)
├── docs/
│   ├── architecture.md                 # Stack diagram and design decisions
│   └── troubleshooting.md              # Errors and solutions
├── server/
│   ├── hostapd.conf                    # Authenticator configuration
│   └── hostapd.eap_user                # EAP policy
├── client/
│   ├── leap156/
│   │   └── wpa_supplicant.conf         # Config validated on Leap 15.6
│   └── nm/
│       └── 8021x-ibmtss.nmconnection   # NetworkManager config
├── tpm/
│   └── scripts/
│       ├── 00-check-env.sh             # Environment check
│       ├── 01-provision-tpm.sh         # Automatic TPM provisioning
│       └── 02-sign-cert.sh             # CA signing
├── patch/
│   ├── fix-openssl3-digest-sign.patch  # Patch for tpm2-tss-engine
│   ├── README.md                       # Bug explanation and fix
│   └── src/
│       ├── tpm2-tss-engine-rsa.c.orig  # Original file (before patch)
│       └── tpm2-tss-engine-rsa.c       # Patched file
└── update_git.bash                     # Repository update script
```

---

## References

| Resource | URL |
|---|---|
| tpm2-tss-engine | <https://github.com/tpm2-software/tpm2-tss-engine> |
| PerryWerneck/tpmtest | <https://github.com/PerryWerneck/tpmtest> |
| tpm2-openssl — OpenSSL 3 Provider | <https://github.com/tpm2-software/tpm2-openssl> |
| Previous lab (PKCS#11 SLES 16) | <https://github.com/mariosergiosl/8021x-eap-tls-lab> |
| hostapd — Official docs | <https://w1.fi/hostapd/> |
| wpa_supplicant — Official docs | <https://w1.fi/wpa_supplicant/> |
