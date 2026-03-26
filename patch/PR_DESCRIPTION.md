# Pull Request — Fix: EVP_MD_CTX_set_update_fn ignored in OpenSSL 3.x

## Summary

`rsa_signctx()` in `tpm2-tss-engine-rsa.c` calls `digest_finish()` which
depends on the custom `digest_update()` callback having been called via
`EVP_MD_CTX_set_update_fn()`. In OpenSSL 3.x, this function is deprecated
and silently ignored in certain EVP code paths, so `Esys_SequenceUpdate`
never receives the data to hash.

As a result, `Esys_SequenceComplete` returns the SHA-256 of an empty string:
```
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
```

This produces an RSA signature that fails verification:
```
error:02000068:rsa routines:ossl_rsa_verify:bad signature
error:1C880004:Provider routines:rsa_verify:RSA lib
```

The authentication then fails at the EAP-TLS `CertificateVerify` stage.

## Root cause

```
EVP_DigestSignFinal()
  └─ rsa_signctx()          ← called with valid mctx
       └─ digest_finish()
            └─ Esys_SequenceComplete()  ← sequence has no data
                 └─ returns SHA-256("")  ← wrong hash
```

`EVP_MD_CTX_set_update_fn()` is marked `OSSL_DEPRECATEDIN_3_0` and the
OpenSSL 3 provider-based digest path does not honour the overridden update
function.

## Fix

In `rsa_signctx()`, replace `digest_finish()` with a direct call to
`EVP_DigestFinal_ex()` to finalise the hash in software, then pass the
resulting `TPM2B_DIGEST` directly to `Esys_Sign()` with a zeroed
`TPMT_TK_HASHCHECK` (null validation ticket, `TPM2_RH_NULL` hierarchy).

This is correct and safe for **unrestricted** TPM keys — the TPM spec
allows signing an externally-computed hash for unrestricted signing keys.
Restricted keys require the TPM to perform the hash (via the sequence
mechanism); a separate fix path would be needed for that case.

## Testing

Verified on:
- **openSUSE Leap 15.6**, OpenSSL 3.1.4, VirtualBox vTPM 2.0
- **SLES 16**, OpenSSL 3.5.0, VirtualBox vTPM 2.0
- wpa_supplicant 2.10, 802.1X EAP-TLS wired, hostapd 2.10
- NetworkManager 1.44.2 with `802-1x.private-key-password-flags 4`

Signature verification before fix:
```
$ openssl dgst -engine tpm2 -keyform engine -sign tpmtest.key -sha256 -out test.sig test.txt
$ openssl dgst -verify <(openssl x509 -in tpmtest.crt -pubkey -noout) -sha256 -signature test.sig test.txt
Verification failure
```

Signature verification after fix:
```
$ openssl dgst -engine tpm2 -keyform engine -sign tpmtest.key -sha256 -out test.sig test.txt
$ openssl dgst -verify <(openssl x509 -in tpmtest.crt -pubkey -noout) -sha256 -signature test.sig test.txt
Verified OK
```

EAP-TLS result after fix:
```
eth4: CTRL-EVENT-EAP-SUCCESS EAP authentication completed successfully
eth4: CTRL-EVENT-CONNECTED - Connection to 01:80:c2:00:00:03 completed
```

## Notes

- OpenSSL 1.x is NOT affected — `EVP_MD_CTX_set_update_fn` is honoured
- The fix does not affect `rsa_priv_enc()` (legacy RSA method path)
- `Esys_Free(digest_ptr)` and `Esys_Free(validation_ptr)` in the `out:`
  block remain safe — they are only called when set by `digest_finish()`,
  which this patch bypasses; the local stack variables are not heap-allocated
