# PKI Manager - CFSSL Certificate Authority Server

A comprehensive bash script for setting up and managing a PKI (Public Key Infrastructure) and TLS Certificate Authority server using the CFSSL toolkit.

## Features

- **Root CA Generation** - Create a root certificate authority with configurable RSA key sizes (2048-8192 bits)
- **Intermediate CAs** - Automatically creates 2 intermediate CAs for day-to-day certificate issuance
- **CFSSL API Server** - Docker-based multirootca server for certificate requests via API
- **SSH Access** - Dedicated `pki-adm` user for secure certificate downloads
- **Certificate Rotation** - Built-in functionality to rotate expiring certificates
- **Expiry Monitoring** - Check certificate expiry dates with warning thresholds

## Requirements

- Linux operating system (Debian/Ubuntu, RHEL/CentOS/Fedora, Arch)
- Root privileges
- Docker and Docker Compose (script can install if missing)
- OpenSSH server (script can install if missing)

## Installation

```bash
# Clone or download the script
chmod +x pki-manager.sh

# Run as root
sudo ./pki-manager.sh
```

## Usage

### Main Menu Options

1. **Install a PKI and TLS certificate authority server**
   - Sets up SSH and creates `pki-adm` user
   - Installs Docker if not present
   - Prompts for Root CA certificate details (CN, C, L, O, ST)
   - Prompts for RSA key size (default: 4096, max: 8192)
   - Creates Root CA with 10-year validity and pathlen=2
   - Creates 2 Intermediate CAs with 8-year validity and pathlen=1
   - Generates certificate chain bundles
   - Starts CFSSL API server in Docker

2. **Rotate certificates**
   - Shows expiry status of all certificates
   - Allows selection of intermediate CA to rotate
   - Backs up existing certificate before rotation
   - Requires Root CA key to be available for signing

3. **Check certificate expiry**
   - Displays days remaining for all certificates
   - Color-coded status (Green: OK, Yellow: Warning <90 days, Red: Critical <30 days)

4. **View certificate summary**
   - Lists all certificates with subject and expiry information

5. **Start/Restart CFSSL services**
   - Starts the Docker containers for CFSSL API

6. **Stop CFSSL services**
   - Stops the Docker containers

## Directory Structure

After installation, the following directory structure is created:

```
/opt/pki/
├── certs/
│   ├── root/
│   │   ├── root-ca.pem          # Root CA certificate
│   │   ├── root-ca-key.pem      # Root CA private key (SECURE THIS!)
│   │   └── root-ca.csr          # Root CA CSR
│   ├── intermediate/
│   │   ├── intermediate-1/
│   │   │   ├── intermediate-1.pem
│   │   │   ├── intermediate-1-key.pem
│   │   │   └── intermediate-1.csr
│   │   └── intermediate-2/
│   │       ├── intermediate-2.pem
│   │       ├── intermediate-2-key.pem
│   │       └── intermediate-2.csr
│   └── bundle/
│       ├── intermediate-1-bundle.pem
│       ├── intermediate-2-bundle.pem
│       └── ca-bundle.crt
├── config/
│   ├── root-ca-csr.json
│   ├── root-ca-config.json
│   ├── intermediate-1-csr.json
│   ├── intermediate-1-config.json
│   ├── intermediate-2-csr.json
│   ├── intermediate-2-config.json
│   └── multiroot-config.ini
└── docker/
    └── docker-compose.yml
```

## CFSSL API Endpoints

After installation, the following API endpoints are available:

- **Multiroot CA API**: `http://localhost:8888`
- **CFSSL API**: `http://localhost:8889`

### Example API Usage

Request a new certificate:
```bash
curl -X POST -H "Content-Type: application/json" \
  -d '{"request":{"CN":"example.com","hosts":["example.com","www.example.com"]}}' \
  http://localhost:8889/api/v1/cfssl/newcert
```

Get CA info:
```bash
curl http://localhost:8889/api/v1/cfssl/info
```

## SSH Access for Certificate Download

Clients can download certificates via SSH:

```bash
# Download CA bundle
scp pki-adm@<server>:/opt/pki/certs/bundle/ca-bundle.crt ./

# Download specific intermediate bundle
scp pki-adm@<server>:/opt/pki/certs/bundle/intermediate-1-bundle.pem ./
```

## Certificate Validity

| Certificate Type | Validity | Path Length |
|-----------------|----------|-------------|
| Root CA | 10 years (87600h) | 2 |
| Intermediate CA | 8 years (70080h) | 1 |
| Server/Client certs | 1 year (8760h) | 0 |

## Security Recommendations

### Root CA Private Key Protection

**CRITICAL**: The Root CA private key (`/opt/pki/certs/root/root-ca-key.pem`) is the most sensitive asset in your PKI.

1. **Move to offline storage** after initial setup:
   ```bash
   # Copy to encrypted USB drive
   cp /opt/pki/certs/root/root-ca-key.pem /mnt/encrypted-usb/
   
   # Securely delete from server
   shred -vfz -n 5 /opt/pki/certs/root/root-ca-key.pem
   ```

2. **Create multiple backups** on separate encrypted drives stored in different physical locations

3. **Only bring online** when signing new intermediate certificates

4. **Consider using HSM** (Hardware Security Module) for production environments

## Exit Codes

| Code | Description |
|------|-------------|
| 0 | Success |
| 1 | Not running as root |
| 2 | User aborted operation |
| 3 | Missing dependency |
| 4 | Configuration error |
| 5 | Certificate generation error |
| 6 | SSH setup error |
| 7 | Docker error |

## License

See LICENSE file for details.
