# Troubleshooting — Erros Encontrados e Soluções

Esta seção documenta todos os erros encontrados durante o desenvolvimento, em ordem cronológica, incluindo tentativas que não funcionaram. O objetivo é servir como referência para quem enfrentar o mesmo caminho.

---

## T01 — `libnm` não encontrado no build do tpmtest

**Sintoma:**

```
Run-time dependency libnm found: NO (tried pkgconfig and cmake)
meson.build:67:2: ERROR: Dependency "libnm" not found
```

**Causa:** O pacote `libnm0` (runtime) estava instalado mas o pacote de desenvolvimento (`NetworkManager-devel`) com o arquivo `libnm.pc` estava ausente.

**Solução:**

```bash
zypper install -y NetworkManager-devel
```

---

## T02 — `tpmtest --help` aborta com `Error loading OSSL tpm2 provider`

**Sintoma:**

```
terminate called after throwing an instance of 'std::runtime_error'
  what():  Error loading OSSL tpm2 provider
Aborted (core dumped)
```

**Causa:** O binário `tpmtest` usa `OSSL_PROVIDER_load("tpm2")` internamente para inicializar o provider OpenSSL 3. O pacote `tpm2-openssl` não estava instalado.

**Solução:**

```bash
zypper install -y tpm2-openssl
```

---

## T03 — Wicked impede o NetworkManager de iniciar

**Sintoma:**

```
Failed to enable unit: File /etc/systemd/system/network.service already
exists and is a symlink to /usr/lib/systemd/system/wicked.service.
```

**Causa:** O openSUSE Leap 15.6 usa Wicked como gestor de rede padrão. O symlink `/etc/systemd/system/network.service` conflita com o NetworkManager.

**Solução:**

```bash
systemctl stop wicked
systemctl disable wicked
systemctl enable --now NetworkManager
```

O `systemctl disable wicked` remove o symlink automaticamente na Leap 15.6 — o `rm` manual não é necessário.

---

## T04 — SSH derrubado ao ativar conexão 802.1X na interface de gestão

**Sintoma:** Sessão SSH encerrada ao executar `nmcli connection up` quando a interface de teste (eth0) era a mesma usada para gestão.

**Causa:** O NM derrubou e reconfigurou a interface eth0 durante a ativação da conexão 802.1X, encerrando a sessão SSH que dependia dela.

**Solução estrutural:** Adicionar um segundo adaptador de rede na VM (eth4) dedicado ao teste 802.1X, mantendo eth0 exclusivamente para gestão.

```bash
# Configurar eth0 com IP fixo para gestão
nmcli connection add type ethernet ifname eth0 con-name "mgmt-eth0" \
  ipv4.method manual ipv4.addresses 192.168.56.163/24 \
  ipv4.gateway 192.168.56.200 ipv4.dns "192.168.56.200 8.8.8.8" \
  connection.autoconnect yes
```

---

## T05 — `802-3-ethernet.auth-8021x` inválido no nmcli

**Sintoma:**

```
Error: invalid property 'auth-8021x': 'auth-8021x' not among [port, speed...]
```

**Causa:** O parâmetro `802-3-ethernet.auth-8021x` não existe no NetworkManager 1.44.x. A autenticação 802.1X é habilitada automaticamente quando as configurações `802-1x.*` estão presentes.

**Solução:** Remover o parâmetro `802-3-ethernet.auth-8021x yes` do comando `nmcli connection add`.

---

## T06 — `Secrets were required, but not provided` ao ativar conexão 802.1X

**Sintoma:**

```
Error: Connection activation failed: Secrets were required, but not provided
Warning: password for '802-1x.identity' not given in 'passwd-file'
```

**Causa:** O NM interpretou o campo `private-key-password ""` como senha vazia e solicitou credenciais interativamente — comportamento incompatível com chaves TSS2 que não usam senha tradicional.

**Solução:** Usar o flag `4` (not-required) para o campo de senha:

```bash
802-1x.private-key-password-flags 4
```

---

## T07 — Engine `tpm2` não disponível — `ENGINE_by_id: no such engine`

**Sintoma:**

```
SSL: Initializing TLS engine tpm2
ENGINE: engine tpm2 not available [error:1300006D:engine routines::init failed]
EAP-TLS: Failed to initialize SSL.
```

**Causa:** O wpa_supplicant detecta o header `BEGIN TSS2 PRIVATE KEY` e procura pelo engine `tpm2.so`. O pacote `tpm2-tss-engine` instala o engine como `tpm2tss.so` — o nome difere.

**Solução:** Criar symlink:

```bash
ln -sf /usr/lib64/engines-3/tpm2tss.so /usr/lib64/engines-3/tpm2.so
openssl engine tpm2 -t
# Saída esperada: [ available ]
```

---

## T08 — `Verification failure` — assinatura RSA inválida no OpenSSL 3.x

**Sintoma:**

```
error:02000068:rsa routines:ossl_rsa_verify:bad signature
error:1C880004:Provider routines:rsa_verify:RSA lib
```

**Causa (raiz do problema principal):** O `tpm2-tss-engine` v1.2.0 registra `digest_update()` via `EVP_MD_CTX_set_update_fn()` para rotear dados pelo TPM. No OpenSSL 3.x, esta função está deprecada e é **ignorada silenciosamente**. O `Esys_SequenceComplete` é chamado sem dados → TPM retorna SHA-256 de string vazia → assinatura inválida.

**Diagnóstico confirmado:** O hash assinado era invariavelmente `e3b0c44298fc1c...` (SHA-256 de `""`).

**Solução:** Patch em `rsa_signctx()` substituindo `digest_finish()` por `EVP_DigestFinal_ex()` direto.

Ver [`patch/fix-openssl3-digest-sign.patch`](../patch/fix-openssl3-digest-sign.patch).

---

## T09 — `double free or corruption` após primeiro patch

**Sintoma:**

```
double free or corruption (out)
Aborted (core dumped)
```

**Causa:** A primeira versão do patch atribuía `digest_ptr = &local_digest` e `validation_ptr = &local_validation` (variáveis na stack). O bloco `out:` chamava `Esys_Free(digest_ptr)` e `Esys_Free(validation_ptr)` sobre ponteiros para stack — corrompendo a memória.

**Solução:** Passar `&local_digest` e `&local_validation` diretamente ao `Esys_Sign()`, sem atribuir a `digest_ptr`/`validation_ptr`, deixando-os `NULL` para o `Esys_Free` no `out:`.

---

## T10 — Race condition de sessões EAP (NAK espúrio)

**Sintoma:** O servidor recebia um `EAP-NAK` com o mesmo `id` do `ClientHello`, causando `FAILURE` antes do handshake TLS completar.

**Causa:** Instância anterior do wpa_supplicant ainda ativa enviou pacotes com estado stale (do engine falhando). A nova instância e a antiga transmitiram com o mesmo `id=19` ao servidor.

**Solução:**

```bash
pkill -9 wpa_supplicant
sleep 1
rm -f /var/run/wpa_supplicant/eth4
# Reiniciar hostapd na gwlocal
kill $(pgrep hostapd) && sleep 1
hostapd -ddKt /etc/hostapd/hostapd.conf > /var/log/hostapd.log 2>&1 &
``
