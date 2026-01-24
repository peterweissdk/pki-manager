# 💾 PKI Manager

[![Static Badge](https://img.shields.io/badge/Cloudflare-CFSSL-white?style=flat&logo=cloudflare&logoColor=white&logoSize=auto&labelColor=black)](https://github.com/cloudflare/cfssl)
[![Static Badge](https://img.shields.io/badge/Docker-Compose-white?style=flat&logo=docker&logoColor=white&logoSize=auto&labelColor=black)](https://docker.com/)
[![Static Badge](https://img.shields.io/badge/Linux-white?style=flat&logo=linux&logoColor=white&logoSize=auto&labelColor=black)](https://www.linux.org/)
[![Static Badge](https://img.shields.io/badge/GPL-V3-white?style=flat&logo=gnu&logoColor=white&logoSize=auto&labelColor=black)](https://www.gnu.org/licenses/gpl-3.0.en.html/)

**Cloudflare SSL (CFSSL) Certificate Authority Server** — Bash script for setting up and managing a PKI (Public Key Infrastructure) and TLS Certificate Authority server using the CFSSL toolkit.

---

## 🚀 Quick Start

### Requirements

- Linux (Debian/Ubuntu and Alpine)
- Root privileges
- Docker & Docker Compose (auto-install available)
- CA server using CFSSL toolkit (auto-install available)

### Installation

```bash
# Clone the repository
git clone <repository-url>
cd pki-manager

# Make executable
chmod +x pki-manager.sh

# Run as root
sudo ./pki-manager.sh
```

### Secure Client Bootstrap

The CFSSL API runs over **HTTPS** with authentication. The easiest way to request certificates is using the client script.

### Using the Client Script (Recommended)

```bash
# The client script is included when cloning the repository
./pki-client.sh
```

---

## 🔧 Configuration

### Using pki-client-cli.sh (Automated/Scripted)

The `pki-client-cli.sh` script is designed for automated certificate management without user interaction. It uses an environment file for configuration.

#### Prerequisites

1. Download CA bundle and auth key from the PKI server:
```bash
scp pki-adm@<pki-server>:/opt/pki/certs/api/ca-bundle.crt /etc/pki/
scp pki-adm@<pki-server>:/opt/pki/config/intermediate-1-auth-key.txt /etc/pki/
# Or for intermediate CA 2:
scp pki-adm@<pki-server>:/opt/pki/config/intermediate-2-auth-key.txt /etc/pki/
```

2. Create an environment file (copy from `pki-cert-manager.env.example`):
```bash
cp pki-cert-manager.env.example /etc/pki/myserver.env
```

3. Edit the environment file with your certificate details:
```bash
# Required settings
PKI_HOST="192.168.1.40"
PKI_PORT="8888"
CA_NUM="1"
CA_BUNDLE_PATH="/etc/pki/ca-bundle.crt"
AUTH_KEY_PATH="/etc/pki/intermediate-1-auth-key.txt"
CERT_CN="myserver.example.com"
CERT_DIR="/etc/ssl/certs/myserver.example.com"

# Optional settings
CERT_HOSTS="www.example.com,192.168.1.100"
CERT_O="My Company"
KEY_ALGO="rsa"
KEY_SIZE="2048"
```

#### Usage

```bash
# Request new certificate (use -f to force if exists)
./pki-client-cli.sh -e /etc/pki/myserver.env -n

# Check certificate expiry (outputs days remaining to stdout)
./pki-client-cli.sh -c /path/to/certificate.crt

# Renew certificate (only if < 90 days remaining, or -f to force)
./pki-client-cli.sh -e /etc/pki/myserver.env -r
```

#### Scripting Example

```bash
# Check expiry and capture days remaining
days_left=$(./pki-client-cli.sh -c /etc/ssl/certs/myserver/myserver.crt)
exit_code=$?

echo "Certificate expires in ${days_left} days"
```

---

## 📝 Directory Structure

```
/opt/pki/
├── certs/
│   ├── root/
│   │   ├── root-ca.pem              # Root CA certificate
│   │   ├── root-ca-key.pem          # Root CA private key ⚠️
│   │   └── root-ca.csr
│   ├── intermediate/
│   │   ├── intermediate-1/
│   │   │   ├── intermediate-1.pem
│   │   │   ├── intermediate-1-key.pem
│   │   │   └── intermediate-1.csr
│   │   └── intermediate-2/
│   │       ├── intermediate-2.pem
│   │       ├── intermediate-2-key.pem
│   │       └── intermediate-2.csr
│   ├── api/
│   │   ├── api-server.pem           # HTTPS API server cert
│   │   ├── api-server-key.pem       # HTTPS API server key
│   │   └── ca-bundle.crt            # CA bundle for client download
│   └── bundle/
│       ├── intermediate-1-bundle.pem
│       ├── intermediate-2-bundle.pem
│       └── ca-bundle.crt
├── config/
│   ├── root-ca-csr.json
│   ├── root-ca-config.json
│   ├── api-server-csr.json
│   ├── intermediate-1-csr.json
│   ├── intermediate-1-config.json
│   ├── intermediate-2-csr.json
│   ├── intermediate-2-config.json
│   └── multiroot-config.ini
└── docker/
    └── docker-compose.yml
```

---

## 🔐 TLS Architecture

### Certificate Hierarchy

```
┌─────────────────────────────────────────────────────────┐
│                      ROOT CA                            │
│              Validity: 10 years                         │
│              Path Length: 2                             │
│              ⚠️ Keep offline after setup                │
└─────────────────────┬───────────────────────────────────┘
                      │
          ┌───────────┴───────────┐
          │                       │
          ▼                       ▼
┌─────────────────────┐ ┌─────────────────────┐
│  INTERMEDIATE CA 1  │ │  INTERMEDIATE CA 2  │
│  Validity: 8 years  │ │  Validity: 8 years  │
│  Path Length: 1     │ │  Path Length: 1     │
│  Usages: cert sign, │ │  Usages: cert sign, │
│          crl sign   │ │          crl sign   │
└──────────┬──────────┘ └──────────┬──────────┘
           │                       │
           ▼                       ▼
┌─────────────────────┐ ┌─────────────────────┐
│   LEAF CERTIFICATES │ │   LEAF CERTIFICATES │
│   Validity: 1 year  │ │   Validity: 1 year  │
│   (server, client,  │ │   (server, client,  │
│    peer)            │ │    peer)            │
└─────────────────────┘ └─────────────────────┘
```

### Certificate Validity

| Type | Validity | Path Length | Purpose |
|------|----------|-------------|---------|
| Root CA | 10 years | 2 | Trust anchor |
| Intermediate CA | 8 years | 1 | Issue leaf certs |
| Server/Client | 1 year | 0 | End-entity |

### Signing Profiles

| Profile | Key Usages | Purpose |
|---------|------------|---------|
| `intermediate` | cert sign, crl sign | Sign leaf certificates |
| `server` | digital signature, key encipherment, server auth | TLS servers |
| `client` | digital signature, key encipherment, client auth | TLS clients |
| `peer` | digital signature, key encipherment, server auth, client auth | Mutual TLS |

### Root CA Security

> ⚠️ **CRITICAL**: The Root CA private key is the most sensitive asset in your PKI.

**After initial setup:**

1. **Move to offline storage**
   ```bash
   cp /opt/pki/certs/root/root-ca-key.pem /mnt/encrypted-usb/
   shred -vfz -n 5 /opt/pki/certs/root/root-ca-key.pem
   ```

2. **Create multiple encrypted backups** in separate physical locations

3. **Only bring online** when signing new intermediate certificates

4. **Consider HSM** (Hardware Security Module) for production

---

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## 🆘 Support

If you encounter any issues or need support, please file an issue on the GitHub repository.

## 📄 License

This project is licensed under the GNU GENERAL PUBLIC LICENSE v3.0 - see the [LICENSE](LICENSE) file for details.