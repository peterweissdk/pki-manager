## ALPHA RELEASE

# 💾 PKI Manager

**CFSSL Certificate Authority Server** — A comprehensive bash script for setting up and managing a PKI (Public Key Infrastructure) and TLS Certificate Authority server using the CFSSL toolkit.

| Feature | Description |
|---------|-------------|
| Root CA Generation | Configurable RSA key sizes (2048-8192 bits) |
| Intermediate CAs | 2 intermediate CAs for day-to-day issuance |
| CFSSL API Server | Docker-based multirootca with HTTPS API |
| SSH Access | Dedicated `pki-adm` user for secure CA bundle download |
| Certificate Rotation | Built-in rotation for expiring certificates |
| Expiry Monitoring | Color-coded expiry warnings |
| Secure Bootstrap | SSH-based CA distribution for trusted HTTPS access |

---

## 🚀 Quick Start

### Requirements

- Linux (Debian/Ubuntu, RHEL/CentOS/Fedora, Arch, Alpine)
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

### Menu Options

| Option | Action |
|--------|--------|
| 1 | Install PKI and TLS CA server |
| 2 | Rotate certificates |
| 3 | Check certificate expiry |
| 4 | View certificate summary |
| 5 | Start/Restart CFSSL services |
| 6 | Stop CFSSL services |
| 0 | Exit |

### Secure Client Bootstrap

The CFSSL API runs over **HTTPS**. Clients must first download the CA bundle via SSH to establish trust:

```bash
# Step 1: Download CA bundle via SSH (secure, authenticated)
scp pki-adm@<server>:/opt/pki/certs/api/ca-bundle.crt ./

# Step 2: Request leaf certificate via HTTPS (verified connection)
curl --cacert ca-bundle.crt \
  -X POST -H "Content-Type: application/json" \
  -d '{"request":{"CN":"myserver.example.com","hosts":["myserver.example.com"]}, "bundle": true}' \
  https://<server>:8889/api/v1/cfssl/newcert
```

### API Endpoint

| Endpoint | Protocol | Port | Purpose |
|----------|----------|------|---------|
| Multiroot CA | HTTPS | 8889 | Certificate issuance |

The API uses `multirootca` and supports the `label` parameter to choose which intermediate CA signs the certificate.

### Choosing the Signing CA

Use the `label` parameter to specify which intermediate CA signs your certificate:

| Label | Signing CA |
|-------|------------|
| `intermediate-1` | Intermediate CA 1 |
| `intermediate-2` | Intermediate CA 2 |

```bash
# Request certificate signed by intermediate-1
curl --cacert ca-bundle.crt \
  -X POST -H "Content-Type: application/json" \
  -d '{"request":{"CN":"example.com","hosts":["example.com"]}, "label": "intermediate-1", "bundle": true}' \
  https://<server>:8889/api/v1/cfssl/newcert

# Request certificate signed by intermediate-2
curl --cacert ca-bundle.crt \
  -X POST -H "Content-Type: application/json" \
  -d '{"request":{"CN":"example.com","hosts":["example.com"]}, "label": "intermediate-2", "bundle": true}' \
  https://<server>:8889/api/v1/cfssl/newcert
```

### Extract Certificate and Key

```bash
# Single API call, extract both cert chain and key
response=$(curl -s --cacert ca-bundle.crt \
  -X POST -H "Content-Type: application/json" \
  -d '{"request":{"CN":"example.com","hosts":["example.com"]}, "label": "intermediate-1", "bundle": true}' \
  https://<server>:8889/api/v1/cfssl/newcert)

echo "$response" | jq -r '.result.bundle.bundle' > fullchain.pem
echo "$response" | jq -r '.result.private_key' > privkey.pem
```

---

## 🔧 Configuration

### Certificate Details Prompted

During installation, you'll be prompted for:

| Field | Description | Example |
|-------|-------------|---------|
| CN | Common Name | My Root CA |
| C | Country | US |
| L | Locality | San Francisco |
| O | Organization | My Company |
| ST | State | California |

### RSA Key Size

| Size | Security Level | Use Case |
|------|----------------|----------|
| 2048 | Minimum | Legacy compatibility |
| 3072 | Good | General purpose |
| 4096 | Strong (default) | Recommended |
| 8192 | Maximum | High security |

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

### File Permissions

| File Type | Permission | Description |
|-----------|------------|-------------|
| Private keys | `400` | Read-only, owner only |
| Certificates | `644` | Readable by all |
| Config files | `640` | Owner read/write, group read |
| API directory | `755` | Readable for SSH download |

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