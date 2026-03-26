# Laboratório 802.1X EAP-TLS com TPM 2.0 — IBM TSS Engine

Este repositório documenta a pesquisa, diagnóstico e correção de compatibilidade do `tpm2-tss-engine` com OpenSSL 3.x para autenticação 802.1X EAP-TLS com chave RSA protegida por TPM 2.0.

> **Resultado principal:** O `tpm2-tss-engine` v1.2.0 possui um bug de compatibilidade com OpenSSL 3.x que impede a assinatura RSA correta em handshakes EAP-TLS. Este repositório documenta o diagnóstico completo e a correção aplicada, validada em openSUSE Leap 15.6 com OpenSSL 3.1.4 e SLES 16 com OpenSSL 3.5.0.

> **Repositório relacionado:** [8021x-eap-tls-lab](https://github.com/mariosergiosl/8021x-eap-tls-lab) — solução PKCS#11 validada no SLES 16 (workaround anterior ao patch documentado aqui).

---

## Arquitetura e Topologia

O laboratório simula um ambiente corporativo simplificado sem FreeRADIUS, onde o servidor `gwlocal` atua simultaneamente como Autenticador (IEEE 802.1X) e Servidor EAP interno via `hostapd`.

| Ativo | Função | Sistema Operacional | Interface | IP |
|---|---|---|---|---|
| **gwlocal** | Autenticador + Servidor EAP-TLS (`hostapd`) | openSUSE Leap 15.6 | eth3 | 192.168.56.200/24 |
| **sles156a16a** | Supplicant (`wpa_supplicant` / NetworkManager) | openSUSE Leap 15.6 | eth4 | 192.168.56.166/24 |

Ambiente de virtualização: VirtualBox no Windows 11. TPM: vTPM 2.0 nativo do VirtualBox.

---

## Stack de Componentes

| Componente | Função | Disponibilidade |
|---|---|---|
| `tpm2-tss-engine` | Engine OpenSSL para TPM 2.0 (chave RSA) | RPM SLES/Leap — **requer patch** |
| `tpm2-openssl` | Provider OpenSSL 3 nativo para TPM 2.0 | RPM SLES/Leap |
| `tpm2.0-abrmd` | Resource Manager do TPM (obrigatório) | RPM SLES/Leap |
| `tpmtest` | Utilitário de geração de chave + CSR via TPM | Compilar da fonte (PerryWerneck/tpmtest) |
| `NetworkManager` | Gestor de rede com suporte 802.1X | Padrão SLES/Leap |
| `wpa_supplicant` | Supplicant EAP-TLS | RPM SLES/Leap |

---

## O Bug — `EVP_MD_CTX_set_update_fn` ignorado no OpenSSL 3.x

### Problema

O `tpm2-tss-engine` v1.2.0 registra uma função customizada de update via `EVP_MD_CTX_set_update_fn()` para rotear os dados pelo TPM via `Esys_SequenceUpdate`. No OpenSSL 3.x, esta função está **deprecada e ignorada** em determinados code paths do EVP layer.

Resultado: `Esys_SequenceComplete` é chamado sem dados → TPM retorna SHA-256 de string vazia → assinatura RSA inválida:

```
error:02000068:rsa routines:ossl_rsa_verify:bad signature
error:1C880004:Provider routines:rsa_verify:RSA lib
```

### Diagnóstico

O hash assinado pelo TPM era invariavelmente:

```
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
```

Este é o SHA-256 de string vazia — confirmando que `digest_update` nunca recebia os dados.

### Correção

Em `rsa_signctx()` em `tpm2-tss-engine-rsa.c`, substituir a chamada `digest_finish()` por `EVP_DigestFinal_ex()` direto, passando o hash resultante diretamente ao `Esys_Sign()` com um validation ticket nulo.

Válido para chaves **unrestricted** (padrão do `tpmtest` e `tpm2tss-genkey`).

O patch completo está em [`patch/fix-openssl3-digest-sign.patch`](patch/fix-openssl3-digest-sign.patch) com explicação detalhada em [`patch/README.md`](patch/README.md).

---

## Instalação e Compilação

### Pré-requisitos (openSUSE Leap 15.6 / SLES 15 SP6+)

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

### Compilação do tpmtest (PerryWerneck/tpmtest)

```bash
cd /usr/local/src
git clone https://github.com/PerryWerneck/tpmtest.git
cd tpmtest
meson setup build
cd build
meson compile
```

### Aplicação do patch no tpm2-tss-engine

```bash
cd /usr/local/src
git clone https://github.com/tpm2-software/tpm2-tss-engine.git
cd tpm2-tss-engine
./bootstrap
./configure PKG_CONFIG_PATH=/usr/lib64/pkgconfig
 
# Aplicar o patch
patch -p1 < /opt/8021x-eap-tls-ibmtss/patch/fix-openssl3-digest-sign.patch
 
# Compilar e instalar
make -j$(nproc) CFLAGS="-Wno-deprecated-declarations -Wno-error"
cp .libs/libtpm2tss.so /usr/lib64/engines-3/libtpm2tss.so
 
# Criar symlink necessário para o wpa_supplicant
ln -sf /usr/lib64/engines-3/tpm2tss.so /usr/lib64/engines-3/tpm2.so
 
# Verificar
openssl engine tpm2 -t
# Saída esperada: [ available ]
```

---

## Provisionamento do TPM

```bash
mkdir -p /opt/8021x-eap-tls-ibmtss/client
cd /opt/8021x-eap-tls-ibmtss/client
 
# Gerar chave RSA no TPM e CSR
/usr/local/src/tpmtest/build/tpmtest genkey gencsr
 
# Verificar
head -1 tpmtest.key
# Esperado: -----BEGIN TSS2 PRIVATE KEY-----
 
openssl req -in tpmtest.csr -noout -verify
# Esperado: Certificate request self-signature verify OK
```

### Assinatura do certificado na CA (gwlocal)

```bash
# Na gwlocal — transferir o CSR
scp root@<IP_CLIENTE>:/opt/8021x-eap-tls-ibmtss/client/tpmtest.csr \
  /opt/8021x-eap-tls-ibmtss/certs/
 
# Assinar com a CA do lab
openssl x509 -req \
  -in /opt/8021x-eap-tls-ibmtss/certs/tpmtest.csr \
  -CA /opt/8021x-eap-tls-lab/certs/ca-lab.crt \
  -CAkey /opt/8021x-eap-tls-lab/private/ca-lab.key \
  -CAcreateserial \
  -out /opt/8021x-eap-tls-ibmtss/certs/tpmtest.crt \
  -days 365 -sha256
 
# Devolver ao cliente
scp /opt/8021x-eap-tls-ibmtss/certs/tpmtest.crt \
  root@<IP_CLIENTE>:/opt/8021x-eap-tls-ibmtss/client/
scp /opt/8021x-eap-tls-lab/certs/ca-lab.crt \
  root@<IP_CLIENTE>:/opt/8021x-eap-tls-ibmtss/client/
```

---

## Execução

### Servidor (gwlocal)

```bash
hostapd -ddKt /etc/hostapd/hostapd.conf > /var/log/hostapd.log 2>&1 &
```

### Cliente via wpa_supplicant

```bash
wpa_supplicant -D wired -i eth4 \
  -c /etc/wpa_supplicant/wpa_supplicant_ibmtss.conf -d
```

### Cliente via NetworkManager

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

### Verificação de sucesso

**Cliente:**

```
eth4: CTRL-EVENT-EAP-SUCCESS EAP authentication completed successfully
eth4: CTRL-EVENT-CONNECTED - Connection to 01:80:c2:00:00:03 completed
```

**Servidor:**

```
IEEE 802.1X: BE_AUTH entering state SUCCESS
AUTH_PAE entering state AUTHENTICATED
AP-STA-CONNECTED 08:00:27:13:33:54
IEEE 802.1X: authorizing port
```

---

## Estrutura do Repositório

```
8021x-eap-tls-ibmtss/
├── README.md                           # Este arquivo (PT-BR)
├── README.en.md                        # Versão em inglês
├── docs/
│   ├── architecture.md                 # Diagrama e decisões de design
│   └── troubleshooting.md              # Erros encontrados e soluções
├── server/
│   ├── hostapd.conf                    # Configuração do autenticador
│   └── hostapd.eap_user                # Política EAP do servidor
├── client/
│   ├── leap156/
│   │   └── wpa_supplicant.conf         # Config validada na Leap 15.6
│   └── nm/
│       └── 8021x-ibmtss.nmconnection   # Config NetworkManager
├── tpm/
│   └── scripts/
│       ├── 00-check-env.sh             # Diagnóstico do ambiente
│       ├── 01-provision-tpm.sh         # Provisionamento automático
│       └── 02-sign-cert.sh             # Assinatura na CA
├── patch/
│   ├── fix-openssl3-digest-sign.patch  # Patch para tpm2-tss-engine
│   └── README.md                       # Explicação do bug e correção
└── update_git.bash                     # Script de atualização do repositório
```

---

## Referências

| Recurso | URL |
|---|---|
| tpm2-tss-engine | <https://github.com/tpm2-software/tpm2-tss-engine> |
| PerryWerneck/tpmtest | <https://github.com/PerryWerneck/tpmtest> |
| tpm2-openssl — Provider OpenSSL 3 | <https://github.com/tpm2-software/tpm2-openssl> |
| Lab anterior (PKCS#11 SLES 16) | <https://github.com/mariosergiosl/8021x-eap-tls-lab> |
| hostapd — Documentação oficial | <https://w1.fi/hostapd/> |
| wpa_supplicant — Documentação oficial | <https://w1.fi/wpa_supplicant/> |
