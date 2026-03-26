# Fix: EVP_MD_CTX_set_update_fn ignored in OpenSSL 3.x

## Problem

In OpenSSL 3.x, `EVP_MD_CTX_set_update_fn()` is deprecated and ignored in
certain EVP code paths. As a result, the custom `digest_update()` function
registered by `tpm2-tss-engine` (which routes data through `Esys_SequenceUpdate`)
is never called during a `EVP_DigestSign` operation.

When `digest_finish()` calls `Esys_SequenceComplete`, the TPM sequence has
received no data and returns the SHA-256 of an empty string:
`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`

This produces an RSA signature that fails verification on OpenSSL 3.x:

```
error:02000068:rsa routines:ossl_rsa_verify:bad signature
```

## Affected versions

- `tpm2-tss-engine` 1.2.0
- OpenSSL 3.x (confirmed on 3.1.4 and 3.5.0)
- OpenSSL 1.x: NOT affected (update callback is honoured)

## Root cause

`rsa_signctx()` in `tpm2-tss-engine-rsa.c` calls `digest_finish()` which
depends on `Esys_SequenceUpdate` having been called via the custom update
callback. On OpenSSL 3.x this callback is silently bypassed.

## Fix

In `rsa_signctx()`, replace the `digest_finish()` call with a direct
`EVP_DigestFinal_ex()` to finalise the hash in software, then pass the
resulting digest directly to `Esys_Sign()` with a null validation ticket.

This is valid for **unrestricted** TPM keys (the default for `tpmtest`
and `tpm2tss-genkey`). Restricted keys require the TPM to perform the
hash internally — a separate fix path may be needed for that case.

## Verified on

- openSUSE Leap 15.6, OpenSSL 3.1.4, vTPM VirtualBox
- wpa_supplicant 2.10, 802.1X EAP-TLS, hostapd 2.10
- `CTRL-EVENT-EAP-SUCCESS` confirmed via wpa_supplicant and NetworkManager
