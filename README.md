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

The `pki-client-cli.sh` script is designed for automating certificate requests, to use in scripts or cron jobs. It uses an environment file for configuration.

#### Prerequisites

1. Download CA bundle and auth key from the PKI server:
```bash
scp pki-adm@<pki-server>:/opt/pki/certs/api/ca-bundle.crt /etc/pki/
scp pki-adm@<pki-server>:/opt/pki/config/intermediate-1-auth-key.txt /etc/pki/
# Or for intermediate CA 2:
scp pki-adm@<pki-server>:/opt/pki/config/intermediate-2-auth-key.txt /etc/pki/
```

2. Create an environment file (copy from `pki-client-cli.env.example`):
```bash
cp pki-client-cli.env.example /etc/pki/myserver.env
```

3. Edit the environment file with your certificate details:
```bash
# PKI server settings
PKI_HOST="192.168.1.40"
PKI_PORT="8889"
CA_NUM="1"
# Key settings
KEY_ALGO="rsa"
KEY_SIZE="2048"
# File paths
AUTH_KEY_PATH="/etc/pki/intermediate-1-auth-key.txt"
OUTPUT_PREFIX="myserver.example.com"
CA_BUNDLE_PATH="/etc/pki/ca-bundle.crt"
LOG_FILE="/var/log/pki-cert-manager.log"
CERT_DIR="/etc/ssl/certs/myserver.example.com"
# Certificate Subject
CERT_CN="myserver.example.com"
CERT_HOSTS="www.example.com,192.168.1.100"
CERT_O="My Company"
CERT_OU="IT Department"
CERT_C="DK"
CERT_ST="Capital Region"
CERT_L="Copenhagen"
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
/opt/pki
├── certs
│   ├── api
│   │   ├── api-server-key.pem
│   │   ├── api-server.csr
│   │   ├── api-server.pem
│   │   └── ca-bundle.crt
│   ├── bundle
│   │   ├── ca-bundle.crt
│   │   ├── intermediate-1-bundle.pem
│   │   └── intermediate-2-bundle.pem
│   ├── intermediate
│   │   ├── intermediate-1
│   │   │   ├── intermediate-1-key.pem
│   │   │   ├── intermediate-1.csr
│   │   │   └── intermediate-1.pem
│   │   └── intermediate-2
│   │       ├── intermediate-2-key.pem
│   │       ├── intermediate-2.csr
│   │       └── intermediate-2.pem
│   └── root
│       ├── root-ca-key.pem          # ⚠️ Keep offline after setup
│       ├── root-ca.csr
│       └── root-ca.pem
├── config
│   ├── api-server-csr.json
│   ├── intermediate-1-auth-key.txt
│   ├── intermediate-1-config.json
│   ├── intermediate-1-csr.json
│   ├── intermediate-2-auth-key.txt
│   ├── intermediate-2-config.json
│   ├── intermediate-2-csr.json
│   ├── multiroot-config.ini
│   ├── root-ca-config.json
│   └── root-ca-csr.json
└── docker
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
│              ⚠️ Keep private key offline after setup    │
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