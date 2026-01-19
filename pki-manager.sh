#!/bin/bash
#
# PKI Manager - Root CA Certificate Server using CFSSL
# This script sets up a PKI infrastructure with cfssl toolkit
# Requires: root privileges
#

set -e

# Exit codes
EXIT_SUCCESS=0
EXIT_NOT_ROOT=1
EXIT_USER_ABORT=2
EXIT_DEPENDENCY_MISSING=3
EXIT_CONFIG_ERROR=4
EXIT_CERT_ERROR=5
EXIT_SSH_ERROR=6
EXIT_DOCKER_ERROR=7

# Configuration
PKI_BASE_DIR="/opt/pki"
PKI_CERTS_DIR="${PKI_BASE_DIR}/certs"
PKI_CONFIG_DIR="${PKI_BASE_DIR}/config"
PKI_ROOT_DIR="${PKI_CERTS_DIR}/root"
PKI_INTERMEDIATE_DIR="${PKI_CERTS_DIR}/intermediate"
PKI_BUNDLE_DIR="${PKI_CERTS_DIR}/bundle"
PKI_USER="pki-adm"
PKI_GROUP="pki-adm"
DOCKER_COMPOSE_DIR="${PKI_BASE_DIR}/docker"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_section() {
    echo -e "\n${BLUE}=== $1 ===${NC}\n"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit $EXIT_NOT_ROOT
    fi
}

# Prompt for yes/no confirmation
confirm() {
    local prompt="$1"
    local response
    read -rp "$prompt [y/n]: " response
    case "$response" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}

# Prompt for input with default value
prompt_input() {
    local prompt="$1"
    local default="$2"
    local response
    if [[ -n "$default" ]]; then
        read -rp "$prompt [$default]: " response
        echo "${response:-$default}"
    else
        read -rp "$prompt: " response
        echo "$response"
    fi
}

# Prompt for password (hidden input)
prompt_password() {
    local prompt="$1"
    local password
    local password_confirm
    while true; do
        read -rsp "$prompt: " password
        echo
        read -rsp "Confirm password: " password_confirm
        echo
        if [[ "$password" == "$password_confirm" ]]; then
            echo "$password"
            return 0
        else
            log_error "Passwords do not match. Please try again."
        fi
    done
}

# Validate RSA key size
validate_rsa_size() {
    local size="$1"
    if [[ ! "$size" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    if [[ "$size" -lt 2048 ]] || [[ "$size" -gt 8192 ]]; then
        return 1
    fi
    # Check if power of 2 or common sizes
    case "$size" in
        2048|3072|4096|8192) return 0 ;;
        *) return 1 ;;
    esac
}

# Check if SSH is installed
check_ssh_installed() {
    if command -v sshd &> /dev/null; then
        return 0
    fi
    return 1
}

# Install SSH server
install_ssh() {
    log_info "Installing OpenSSH server..."
    if command -v apt-get &> /dev/null; then
        apt-get update && apt-get install -y openssh-server
    elif command -v dnf &> /dev/null; then
        dnf install -y openssh-server
    elif command -v yum &> /dev/null; then
        yum install -y openssh-server
    elif command -v pacman &> /dev/null; then
        pacman -S --noconfirm openssh
    elif command -v apk &> /dev/null; then
        # Alpine Linux
        apk update
        apk add openssh-server
    else
        log_error "Unable to detect package manager. Please install OpenSSH manually."
        exit $EXIT_SSH_ERROR
    fi
    
    # Start SSH service (handle both systemd and OpenRC)
    if command -v systemctl &> /dev/null; then
        systemctl enable sshd
        systemctl start sshd
    elif command -v rc-service &> /dev/null; then
        # Alpine Linux uses OpenRC
        rc-update add sshd default
        rc-service sshd start
    else
        log_warn "Unable to detect init system. Please start SSH service manually."
    fi
    log_info "SSH server installed and started"
}

# Check if user exists
user_exists() {
    local username="$1"
    id "$username" &>/dev/null
}

# Check if user has SSH keys
user_has_ssh_keys() {
    local username="$1"
    local home_dir
    home_dir=$(getent passwd "$username" | cut -d: -f6)
    [[ -f "${home_dir}/.ssh/id_rsa" ]] || [[ -f "${home_dir}/.ssh/id_ed25519" ]]
}

# Setup PKI admin user
setup_pki_user() {
    log_section "Setting up PKI Admin User"
    
    # Check if user already exists
    if user_exists "$PKI_USER"; then
        log_info "User '$PKI_USER' already exists"
        if user_has_ssh_keys "$PKI_USER"; then
            log_info "SSH keys already exist for user '$PKI_USER'"
        else
            log_warn "SSH keys not found for user '$PKI_USER'"
            if confirm "Generate SSH keys for '$PKI_USER'?"; then
                generate_ssh_keys "$PKI_USER"
            fi
        fi
    else
        log_info "Creating user '$PKI_USER'..."
        
        # Prompt for password
        local password
        password=$(prompt_password "Enter password for user '$PKI_USER'")
        
        # Create group if not exists
        if ! getent group "$PKI_GROUP" &>/dev/null; then
            groupadd "$PKI_GROUP"
        fi
        
        # Create user
        useradd -m -g "$PKI_GROUP" -s /bin/bash "$PKI_USER"
        echo "${PKI_USER}:${password}" | chpasswd
        
        log_info "User '$PKI_USER' created successfully"
        
        # Generate SSH keys
        generate_ssh_keys "$PKI_USER"
    fi
    
    # Setup permissions for certificate directories
    setup_pki_permissions
}

# Generate SSH keys for user
generate_ssh_keys() {
    local username="$1"
    local home_dir
    home_dir=$(getent passwd "$username" | cut -d: -f6)
    local ssh_dir="${home_dir}/.ssh"
    
    log_info "Generating SSH keys for user '$username'..."
    
    # Create .ssh directory
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    
    # Generate ED25519 key (more secure and faster than RSA)
    sudo -u "$username" ssh-keygen -t ed25519 -f "${ssh_dir}/id_ed25519" -N "" -C "${username}@pki-server"
    
    # Also generate RSA key for compatibility
    sudo -u "$username" ssh-keygen -t rsa -b 4096 -f "${ssh_dir}/id_rsa" -N "" -C "${username}@pki-server"
    
    # Set proper ownership
    chown -R "${username}:${PKI_GROUP}" "$ssh_dir"
    chmod 600 "${ssh_dir}/id_ed25519" "${ssh_dir}/id_rsa"
    chmod 644 "${ssh_dir}/id_ed25519.pub" "${ssh_dir}/id_rsa.pub"
    
    log_info "SSH keys generated at ${ssh_dir}/"
}

# Setup PKI directory permissions
setup_pki_permissions() {
    log_info "Setting up PKI directory permissions..."
    
    # Create directories if they don't exist
    mkdir -p "$PKI_CERTS_DIR" "$PKI_CONFIG_DIR" "$PKI_ROOT_DIR" \
             "$PKI_INTERMEDIATE_DIR" "$PKI_BUNDLE_DIR" "$DOCKER_COMPOSE_DIR"
    
    # Set ownership
    chown -R "${PKI_USER}:${PKI_GROUP}" "$PKI_BASE_DIR"
    
    # Set permissions - restrictive for private keys
    chmod 750 "$PKI_BASE_DIR"
    chmod 750 "$PKI_CERTS_DIR"
    chmod 700 "$PKI_ROOT_DIR"
    chmod 750 "$PKI_INTERMEDIATE_DIR"
    chmod 755 "$PKI_BUNDLE_DIR"
    
    log_info "PKI directory permissions configured"
}

# Check if Docker is installed
check_docker_installed() {
    command -v docker &> /dev/null
}

# Check if Docker Compose is installed
check_docker_compose_installed() {
    docker compose version &> /dev/null || docker-compose --version &> /dev/null
}

# Install Docker
install_docker() {
    log_info "Installing Docker..."
    
    if command -v apt-get &> /dev/null; then
        # Debian/Ubuntu
        apt-get update
        apt-get install -y ca-certificates curl gnupg
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
        
        # Detect distro
        if [[ -f /etc/os-release ]]; then
            . /etc/os-release
            if [[ "$ID" == "ubuntu" ]]; then
                echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
            elif [[ "$ID" == "debian" ]]; then
                echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $VERSION_CODENAME stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
            fi
        fi
        
        apt-get update
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        
    elif command -v dnf &> /dev/null; then
        # Fedora/RHEL
        dnf -y install dnf-plugins-core
        dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
        dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        
    elif command -v yum &> /dev/null; then
        # CentOS
        yum install -y yum-utils
        yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        
    elif command -v pacman &> /dev/null; then
        # Arch Linux
        pacman -Sy --noconfirm docker docker-compose
        
    elif command -v apk &> /dev/null; then
        # Alpine Linux
        apk update
        apk add docker docker-cli-compose
        
    else
        log_error "Unable to detect package manager. Please install Docker manually."
        exit $EXIT_DOCKER_ERROR
    fi
    
    # Start and enable Docker (handle both systemd and OpenRC)
    if command -v systemctl &> /dev/null; then
        systemctl enable docker
        systemctl start docker
    elif command -v rc-service &> /dev/null; then
        # Alpine Linux uses OpenRC
        rc-update add docker default
        rc-service docker start
    else
        log_warn "Unable to detect init system. Please start Docker service manually."
    fi
    
    # Add pki-adm user to docker group
    usermod -aG docker "$PKI_USER"
    
    log_info "Docker installed successfully"
}

# Setup Docker and Docker Compose
setup_docker() {
    log_section "Setting up Docker"
    
    if check_docker_installed; then
        log_info "Docker is already installed"
    else
        log_warn "Docker is not installed"
        if confirm "Would you like to install Docker?"; then
            install_docker
        else
            log_error "Docker is required for this setup"
            exit $EXIT_USER_ABORT
        fi
    fi
    
    if check_docker_compose_installed; then
        log_info "Docker Compose is available"
    else
        log_error "Docker Compose plugin is not available. Please reinstall Docker with compose plugin."
        exit $EXIT_DOCKER_ERROR
    fi
    
    # Verify Docker is running
    if ! docker info &>/dev/null; then
        log_info "Starting Docker service..."
        systemctl start docker
    fi
}

# Check SSH setup
setup_ssh() {
    log_section "Setting up SSH"
    
    if check_ssh_installed; then
        log_info "SSH server is already installed"
    else
        log_warn "SSH server is not installed"
        if confirm "Would you like to install SSH server?"; then
            install_ssh
        else
            log_warn "SSH server not installed. Remote certificate access will not be available."
        fi
    fi
}

# Prompt for certificate details
prompt_cert_details() {
    local cert_type="$1"
    
    log_section "Enter ${cert_type} Certificate Details"
    
    CERT_CN=$(prompt_input "Common Name (CN)" "")
    while [[ -z "$CERT_CN" ]]; do
        log_error "Common Name is required"
        CERT_CN=$(prompt_input "Common Name (CN)" "")
    done
    
    CERT_C=$(prompt_input "Country (C)" "US")
    CERT_L=$(prompt_input "Locality (L)" "")
    CERT_O=$(prompt_input "Organization (O)" "")
    CERT_ST=$(prompt_input "State (ST)" "")
}

# Prompt for RSA key size
prompt_rsa_size() {
    local default="$1"
    local size
    
    while true; do
        size=$(prompt_input "RSA key size (2048, 3072, 4096, 8192)" "$default")
        if validate_rsa_size "$size"; then
            echo "$size"
            return 0
        else
            log_error "Invalid RSA key size. Must be 2048, 3072, 4096, or 8192"
        fi
    done
}

# Create Root CA CSR config
create_root_ca_csr_config() {
    local cn="$1"
    local c="$2"
    local l="$3"
    local o="$4"
    local st="$5"
    local key_size="$6"
    
    cat > "${PKI_CONFIG_DIR}/root-ca-csr.json" << EOF
{
    "CN": "${cn}",
    "key": {
        "algo": "rsa",
        "size": ${key_size}
    },
    "names": [
        {
            "C": "${c}",
            "L": "${l}",
            "O": "${o}",
            "ST": "${st}"
        }
    ],
    "ca": {
        "expiry": "87600h",
        "pathlen": 2
    }
}
EOF
    log_info "Root CA CSR config created at ${PKI_CONFIG_DIR}/root-ca-csr.json"
}

# Create Root CA signing config
create_root_ca_config() {
    cat > "${PKI_CONFIG_DIR}/root-ca-config.json" << EOF
{
    "signing": {
        "default": {
            "expiry": "87600h"
        },
        "profiles": {
            "intermediate": {
                "usages": [
                    "signing",
                    "digital signature",
                    "key encipherment",
                    "cert sign",
                    "crl sign"
                ],
                "expiry": "70080h",
                "ca_constraint": {
                    "is_ca": true,
                    "max_path_len": 1
                }
            },
            "server": {
                "usages": [
                    "signing",
                    "digital signature",
                    "key encipherment",
                    "server auth"
                ],
                "expiry": "8760h"
            },
            "client": {
                "usages": [
                    "signing",
                    "digital signature",
                    "key encipherment",
                    "client auth"
                ],
                "expiry": "8760h"
            },
            "peer": {
                "usages": [
                    "signing",
                    "digital signature",
                    "key encipherment",
                    "server auth",
                    "client auth"
                ],
                "expiry": "8760h"
            }
        }
    }
}
EOF
    log_info "Root CA signing config created at ${PKI_CONFIG_DIR}/root-ca-config.json"
}

# Create Intermediate CA CSR config
create_intermediate_ca_csr_config() {
    local name="$1"
    local cn="$2"
    local c="$3"
    local l="$4"
    local o="$5"
    local st="$6"
    local key_size="$7"
    
    cat > "${PKI_CONFIG_DIR}/${name}-csr.json" << EOF
{
    "CN": "${cn}",
    "key": {
        "algo": "rsa",
        "size": ${key_size}
    },
    "names": [
        {
            "C": "${c}",
            "L": "${l}",
            "O": "${o}",
            "ST": "${st}"
        }
    ],
    "ca": {
        "expiry": "70080h",
        "pathlen": 1
    }
}
EOF
    log_info "Intermediate CA CSR config created at ${PKI_CONFIG_DIR}/${name}-csr.json"
}

# Create Intermediate CA signing config
create_intermediate_ca_config() {
    local name="$1"
    
    cat > "${PKI_CONFIG_DIR}/${name}-config.json" << EOF
{
    "signing": {
        "default": {
            "expiry": "8760h"
        },
        "profiles": {
            "server": {
                "usages": [
                    "signing",
                    "digital signature",
                    "key encipherment",
                    "server auth"
                ],
                "expiry": "8760h"
            },
            "client": {
                "usages": [
                    "signing",
                    "digital signature",
                    "key encipherment",
                    "client auth"
                ],
                "expiry": "8760h"
            },
            "peer": {
                "usages": [
                    "signing",
                    "digital signature",
                    "key encipherment",
                    "server auth",
                    "client auth"
                ],
                "expiry": "8760h"
            }
        }
    }
}
EOF
    log_info "Intermediate CA signing config created at ${PKI_CONFIG_DIR}/${name}-config.json"
}

# Generate Root CA certificate
generate_root_ca() {
    log_section "Generating Root CA Certificate"
    
    # Prompt for certificate details
    prompt_cert_details "Root CA"
    
    # Prompt for RSA key size
    log_info "Select RSA key size for Root CA"
    RSA_SIZE=$(prompt_rsa_size "4096")
    
    # Store RSA size for intermediate CAs
    echo "$RSA_SIZE" > "${PKI_CONFIG_DIR}/.rsa_size"
    
    # Create configs
    create_root_ca_csr_config "$CERT_CN" "$CERT_C" "$CERT_L" "$CERT_O" "$CERT_ST" "$RSA_SIZE"
    create_root_ca_config
    
    # Generate Root CA using cfssl in Docker
    log_info "Generating Root CA certificate..."
    
    docker run --rm \
        -v "${PKI_CONFIG_DIR}:/config" \
        -v "${PKI_ROOT_DIR}:/certs" \
        cfssl/cfssl:latest \
        cfssl gencert -initca /config/root-ca-csr.json | \
    docker run --rm -i \
        -v "${PKI_ROOT_DIR}:/certs" \
        cfssl/cfssl:latest \
        cfssljson -bare /certs/root-ca
    
    # Set restrictive permissions on private key
    chmod 600 "${PKI_ROOT_DIR}/root-ca-key.pem"
    chown "${PKI_USER}:${PKI_GROUP}" "${PKI_ROOT_DIR}"/*
    
    log_info "Root CA certificate generated successfully"
}

# Generate Intermediate CA certificate
generate_intermediate_ca() {
    local name="$1"
    local display_name="$2"
    
    log_section "Generating ${display_name} Certificate"
    
    # Prompt for certificate details
    prompt_cert_details "$display_name"
    
    # Get RSA size from root CA
    local rsa_size
    if [[ -f "${PKI_CONFIG_DIR}/.rsa_size" ]]; then
        rsa_size=$(cat "${PKI_CONFIG_DIR}/.rsa_size")
    else
        rsa_size="4096"
    fi
    log_info "Using RSA key size: ${rsa_size} (same as Root CA)"
    
    # Create intermediate directory
    local int_dir="${PKI_INTERMEDIATE_DIR}/${name}"
    mkdir -p "$int_dir"
    
    # Create configs
    create_intermediate_ca_csr_config "$name" "$CERT_CN" "$CERT_C" "$CERT_L" "$CERT_O" "$CERT_ST" "$rsa_size"
    create_intermediate_ca_config "$name"
    
    # Generate Intermediate CA CSR
    log_info "Generating ${display_name} CSR..."
    
    docker run --rm \
        -v "${PKI_CONFIG_DIR}:/config" \
        -v "${int_dir}:/certs" \
        cfssl/cfssl:latest \
        cfssl gencert -initca /config/${name}-csr.json | \
    docker run --rm -i \
        -v "${int_dir}:/certs" \
        cfssl/cfssl:latest \
        cfssljson -bare /certs/${name}
    
    # Sign with Root CA
    log_info "Signing ${display_name} with Root CA..."
    
    docker run --rm \
        -v "${PKI_CONFIG_DIR}:/config" \
        -v "${PKI_ROOT_DIR}:/root-ca" \
        -v "${int_dir}:/certs" \
        cfssl/cfssl:latest \
        cfssl sign \
            -ca /root-ca/root-ca.pem \
            -ca-key /root-ca/root-ca-key.pem \
            -config /config/root-ca-config.json \
            -profile intermediate \
            /certs/${name}.csr | \
    docker run --rm -i \
        -v "${int_dir}:/certs" \
        cfssl/cfssl:latest \
        cfssljson -bare /certs/${name}
    
    # Set permissions
    chmod 600 "${int_dir}/${name}-key.pem"
    chown -R "${PKI_USER}:${PKI_GROUP}" "$int_dir"
    
    log_info "${display_name} certificate generated and signed successfully"
}

# Create certificate chain bundle
create_cert_bundle() {
    log_section "Creating Certificate Chain Bundle"
    
    # Create bundle for each intermediate
    for int_dir in "${PKI_INTERMEDIATE_DIR}"/*; do
        if [[ -d "$int_dir" ]]; then
            local name=$(basename "$int_dir")
            local bundle_file="${PKI_BUNDLE_DIR}/${name}-bundle.pem"
            
            log_info "Creating bundle for ${name}..."
            
            # Concatenate intermediate + root (order matters: leaf to root)
            cat "${int_dir}/${name}.pem" "${PKI_ROOT_DIR}/root-ca.pem" > "$bundle_file"
            
            log_info "Bundle created: ${bundle_file}"
        fi
    done
    
    # Create full chain bundle using mkbundle
    log_info "Creating full CA bundle with mkbundle..."
    
    # Collect all CA certs
    local all_certs=""
    all_certs="${PKI_ROOT_DIR}/root-ca.pem"
    for int_dir in "${PKI_INTERMEDIATE_DIR}"/*; do
        if [[ -d "$int_dir" ]]; then
            local name=$(basename "$int_dir")
            all_certs="${all_certs} ${int_dir}/${name}.pem"
        fi
    done
    
    # Use mkbundle to create the bundle
    docker run --rm \
        -v "${PKI_CERTS_DIR}:/certs" \
        cfssl/cfssl:latest \
        mkbundle -f /certs/bundle/ca-bundle.crt /certs/root/root-ca.pem
    
    # Add intermediates to bundle
    for int_dir in "${PKI_INTERMEDIATE_DIR}"/*; do
        if [[ -d "$int_dir" ]]; then
            local name=$(basename "$int_dir")
            cat "${int_dir}/${name}.pem" >> "${PKI_BUNDLE_DIR}/ca-bundle.crt"
        fi
    done
    
    chown -R "${PKI_USER}:${PKI_GROUP}" "${PKI_BUNDLE_DIR}"
    chmod 644 "${PKI_BUNDLE_DIR}"/*
    
    log_info "Certificate bundles created successfully"
}

# Create multiroot CA config
create_multiroot_config() {
    log_section "Creating Multiroot CA Configuration"
    
    local config_file="${PKI_CONFIG_DIR}/multiroot-config.ini"
    
    cat > "$config_file" << 'EOF'
# Multiroot CA Configuration
# Each section defines a signing identity

EOF
    
    # Add each intermediate as a signer
    local signer_num=1
    for int_dir in "${PKI_INTERMEDIATE_DIR}"/*; do
        if [[ -d "$int_dir" ]]; then
            local name=$(basename "$int_dir")
            cat >> "$config_file" << EOF
[${name}]
private = /certs/intermediate/${name}/${name}-key.pem
certificate = /certs/intermediate/${name}/${name}.pem
config = /config/${name}-config.json

EOF
            signer_num=$((signer_num + 1))
        fi
    done
    
    chown "${PKI_USER}:${PKI_GROUP}" "$config_file"
    log_info "Multiroot config created at ${config_file}"
}

# Create Docker Compose file
create_docker_compose() {
    log_section "Creating Docker Compose Configuration"
    
    cat > "${DOCKER_COMPOSE_DIR}/docker-compose.yml" << EOF
version: '3.8'

services:
  cfssl-multirootca:
    image: cfssl/cfssl:latest
    container_name: cfssl-multirootca
    restart: unless-stopped
    ports:
      - "8888:8888"
    volumes:
      - ${PKI_CERTS_DIR}:/certs:ro
      - ${PKI_CONFIG_DIR}:/config:ro
    command: >
      multirootca
      -a 0.0.0.0:8888
      -roots /config/multiroot-config.ini
      -loglevel 1
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:8888/api/v1/cfssl/info"]
      interval: 30s
      timeout: 10s
      retries: 3
    networks:
      - pki-network

  cfssl-api:
    image: cfssl/cfssl:latest
    container_name: cfssl-api
    restart: unless-stopped
    ports:
      - "8889:8889"
    volumes:
      - ${PKI_CERTS_DIR}:/certs:ro
      - ${PKI_CONFIG_DIR}:/config:ro
    command: >
      serve
      -address 0.0.0.0
      -port 8889
      -ca /certs/intermediate/intermediate-1/intermediate-1.pem
      -ca-key /certs/intermediate/intermediate-1/intermediate-1-key.pem
      -config /config/intermediate-1-config.json
    depends_on:
      - cfssl-multirootca
    networks:
      - pki-network

networks:
  pki-network:
    driver: bridge
EOF
    
    chown "${PKI_USER}:${PKI_GROUP}" "${DOCKER_COMPOSE_DIR}/docker-compose.yml"
    log_info "Docker Compose file created at ${DOCKER_COMPOSE_DIR}/docker-compose.yml"
}

# Start CFSSL services
start_cfssl_services() {
    log_section "Starting CFSSL Services"
    
    cd "$DOCKER_COMPOSE_DIR"
    docker compose up -d
    
    log_info "CFSSL services started"
    log_info "Multiroot CA API: http://localhost:8888"
    log_info "CFSSL API: http://localhost:8889"
}

# Print certificate information
print_cert_info() {
    local cert_file="$1"
    local cert_name="$2"
    
    if [[ -f "$cert_file" ]]; then
        local expiry
        expiry=$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | cut -d= -f2)
        local subject
        subject=$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null | sed 's/subject=//')
        
        echo -e "  ${GREEN}${cert_name}${NC}"
        echo "    File: ${cert_file}"
        echo "    Subject: ${subject}"
        echo "    Expires: ${expiry}"
        echo
    fi
}

# Display certificate summary
display_cert_summary() {
    log_section "Certificate Summary"
    
    echo -e "${BLUE}Root CA:${NC}"
    print_cert_info "${PKI_ROOT_DIR}/root-ca.pem" "Root CA"
    
    echo -e "${BLUE}Intermediate CAs:${NC}"
    for int_dir in "${PKI_INTERMEDIATE_DIR}"/*; do
        if [[ -d "$int_dir" ]]; then
            local name=$(basename "$int_dir")
            print_cert_info "${int_dir}/${name}.pem" "$name"
        fi
    done
    
    echo -e "${BLUE}Certificate Bundles:${NC}"
    for bundle in "${PKI_BUNDLE_DIR}"/*.pem "${PKI_BUNDLE_DIR}"/*.crt; do
        if [[ -f "$bundle" ]]; then
            echo "  - ${bundle}"
        fi
    done
}

# Display security guidance
display_security_guidance() {
    log_section "Security Guidance for Root CA Private Key"
    
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════════════════════╗
║                    IMPORTANT: ROOT CA PRIVATE KEY SECURITY                   ║
╠══════════════════════════════════════════════════════════════════════════════╣
║                                                                              ║
║  The Root CA private key is the most critical asset in your PKI.            ║
║  Compromise of this key would allow an attacker to issue trusted            ║
║  certificates for any domain.                                               ║
║                                                                              ║
║  RECOMMENDED ACTIONS:                                                        ║
║                                                                              ║
║  1. MOVE TO OFFLINE STORAGE                                                  ║
║     - Copy the root CA private key to an encrypted USB drive                 ║
║     - Use: cp /opt/pki/certs/root/root-ca-key.pem /mnt/usb/                 ║
║     - Securely delete the key from the server after copying                  ║
║     - Store the USB drive in a physical safe or secure location              ║
║                                                                              ║
║  2. CREATE MULTIPLE BACKUPS                                                  ║
║     - Create at least 2-3 copies on separate encrypted drives                ║
║     - Store in different physical locations                                  ║
║     - Consider using a Hardware Security Module (HSM) for production         ║
║                                                                              ║
║  3. DOCUMENT ACCESS PROCEDURES                                               ║
║     - Establish a formal process for accessing the root key                  ║
║     - Require multiple authorized personnel for key access                   ║
║     - Log all access to the root CA key                                      ║
║                                                                              ║
║  4. LIMIT ROOT CA USAGE                                                      ║
║     - Only use the root CA to sign intermediate CA certificates              ║
║     - Use intermediate CAs for day-to-day certificate issuance               ║
║     - The root CA should remain offline except during signing                ║
║                                                                              ║
║  5. SECURE DELETION (after backup)                                           ║
║     - Use: shred -vfz -n 5 /opt/pki/certs/root/root-ca-key.pem             ║
║                                                                              ║
╚══════════════════════════════════════════════════════════════════════════════╝
EOF
}

# Check certificate expiry
check_cert_expiry() {
    local cert_file="$1"
    local warn_days="${2:-30}"
    
    if [[ ! -f "$cert_file" ]]; then
        return 1
    fi
    
    local expiry_date
    expiry_date=$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | cut -d= -f2)
    local expiry_epoch
    expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null)
    local now_epoch
    now_epoch=$(date +%s)
    local days_left
    days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
    
    echo "$days_left"
}

# Check all certificates expiry
check_all_certs_expiry() {
    log_section "Certificate Expiry Check"
    
    local warn_days=90
    local critical_days=30
    local has_issues=false
    
    echo -e "Checking certificates (Warning: <${warn_days} days, Critical: <${critical_days} days)\n"
    
    # Check Root CA
    if [[ -f "${PKI_ROOT_DIR}/root-ca.pem" ]]; then
        local days_left
        days_left=$(check_cert_expiry "${PKI_ROOT_DIR}/root-ca.pem")
        local status_color="$GREEN"
        local status_text="OK"
        
        if [[ "$days_left" -lt "$critical_days" ]]; then
            status_color="$RED"
            status_text="CRITICAL"
            has_issues=true
        elif [[ "$days_left" -lt "$warn_days" ]]; then
            status_color="$YELLOW"
            status_text="WARNING"
            has_issues=true
        fi
        
        echo -e "Root CA: ${status_color}${status_text}${NC} (${days_left} days remaining)"
    else
        echo -e "Root CA: ${RED}NOT FOUND${NC}"
    fi
    
    # Check Intermediates
    for int_dir in "${PKI_INTERMEDIATE_DIR}"/*; do
        if [[ -d "$int_dir" ]]; then
            local name=$(basename "$int_dir")
            local cert_file="${int_dir}/${name}.pem"
            
            if [[ -f "$cert_file" ]]; then
                local days_left
                days_left=$(check_cert_expiry "$cert_file")
                local status_color="$GREEN"
                local status_text="OK"
                
                if [[ "$days_left" -lt "$critical_days" ]]; then
                    status_color="$RED"
                    status_text="CRITICAL"
                    has_issues=true
                elif [[ "$days_left" -lt "$warn_days" ]]; then
                    status_color="$YELLOW"
                    status_text="WARNING"
                    has_issues=true
                fi
                
                echo -e "${name}: ${status_color}${status_text}${NC} (${days_left} days remaining)"
            fi
        fi
    done
    
    echo
    if $has_issues; then
        log_warn "Some certificates need attention!"
        return 1
    else
        log_info "All certificates are valid"
        return 0
    fi
}

# Rotate intermediate certificate
rotate_intermediate_cert() {
    local name="$1"
    local int_dir="${PKI_INTERMEDIATE_DIR}/${name}"
    
    if [[ ! -d "$int_dir" ]]; then
        log_error "Intermediate CA '${name}' not found"
        return 1
    fi
    
    log_section "Rotating Intermediate CA: ${name}"
    
    # Backup existing certificate
    local backup_dir="${int_dir}/backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"
    cp "${int_dir}/${name}.pem" "${int_dir}/${name}-key.pem" "${int_dir}/${name}.csr" "$backup_dir/" 2>/dev/null || true
    log_info "Existing certificate backed up to ${backup_dir}"
    
    # Check if root CA key is available
    if [[ ! -f "${PKI_ROOT_DIR}/root-ca-key.pem" ]]; then
        log_error "Root CA private key not found!"
        log_error "Please restore the root CA key from secure storage to sign the new intermediate."
        return 1
    fi
    
    # Regenerate intermediate
    log_info "Generating new intermediate certificate..."
    
    docker run --rm \
        -v "${PKI_CONFIG_DIR}:/config" \
        -v "${int_dir}:/certs" \
        cfssl/cfssl:latest \
        cfssl gencert -initca /config/${name}-csr.json | \
    docker run --rm -i \
        -v "${int_dir}:/certs" \
        cfssl/cfssl:latest \
        cfssljson -bare /certs/${name}
    
    # Sign with Root CA
    log_info "Signing with Root CA..."
    
    docker run --rm \
        -v "${PKI_CONFIG_DIR}:/config" \
        -v "${PKI_ROOT_DIR}:/root-ca" \
        -v "${int_dir}:/certs" \
        cfssl/cfssl:latest \
        cfssl sign \
            -ca /root-ca/root-ca.pem \
            -ca-key /root-ca/root-ca-key.pem \
            -config /config/root-ca-config.json \
            -profile intermediate \
            /certs/${name}.csr | \
    docker run --rm -i \
        -v "${int_dir}:/certs" \
        cfssl/cfssl:latest \
        cfssljson -bare /certs/${name}
    
    # Set permissions
    chmod 600 "${int_dir}/${name}-key.pem"
    chown -R "${PKI_USER}:${PKI_GROUP}" "$int_dir"
    
    # Update bundle
    local bundle_file="${PKI_BUNDLE_DIR}/${name}-bundle.pem"
    cat "${int_dir}/${name}.pem" "${PKI_ROOT_DIR}/root-ca.pem" > "$bundle_file"
    
    log_info "Intermediate CA '${name}' rotated successfully"
    
    # Restart services to pick up new cert
    if confirm "Restart CFSSL services to use new certificate?"; then
        cd "$DOCKER_COMPOSE_DIR"
        docker compose restart
        log_info "Services restarted"
    fi
}

# Certificate rotation menu
rotate_certificates_menu() {
    log_section "Certificate Rotation"
    
    # First check expiry
    check_all_certs_expiry
    
    echo
    echo "Available certificates for rotation:"
    echo
    
    local certs=()
    local i=1
    
    for int_dir in "${PKI_INTERMEDIATE_DIR}"/*; do
        if [[ -d "$int_dir" ]]; then
            local name=$(basename "$int_dir")
            certs+=("$name")
            echo "  $i) ${name}"
            i=$((i + 1))
        fi
    done
    
    if [[ ${#certs[@]} -eq 0 ]]; then
        log_warn "No intermediate certificates found"
        return 1
    fi
    
    echo "  0) Cancel"
    echo
    
    local choice
    read -rp "Select certificate to rotate: " choice
    
    if [[ "$choice" == "0" ]]; then
        return 0
    fi
    
    if [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#certs[@]} ]]; then
        local selected="${certs[$((choice - 1))]}"
        if confirm "Are you sure you want to rotate '${selected}'?"; then
            rotate_intermediate_cert "$selected"
        fi
    else
        log_error "Invalid selection"
        return 1
    fi
}

# Install PKI infrastructure
install_pki() {
    log_section "Installing PKI and TLS Certificate Authority Server"
    
    # Setup SSH
    setup_ssh
    
    # Setup PKI user
    setup_pki_user
    
    # Setup Docker
    setup_docker
    
    # Generate Root CA
    generate_root_ca
    
    # Generate Intermediate CAs
    log_info "Creating 2 Intermediate CAs..."
    
    echo
    log_info "=== Intermediate CA 1 ==="
    generate_intermediate_ca "intermediate-1" "Intermediate CA 1"
    
    echo
    log_info "=== Intermediate CA 2 ==="
    generate_intermediate_ca "intermediate-2" "Intermediate CA 2"
    
    # Create bundles
    create_cert_bundle
    
    # Create multiroot config
    create_multiroot_config
    
    # Create Docker Compose
    create_docker_compose
    
    # Start services
    if confirm "Start CFSSL services now?"; then
        start_cfssl_services
    fi
    
    # Display summary
    display_cert_summary
    
    # Display security guidance
    display_security_guidance
    
    log_section "Installation Complete"
    log_info "PKI infrastructure has been set up successfully!"
    log_info ""
    log_info "Key locations:"
    log_info "  - Certificates: ${PKI_CERTS_DIR}"
    log_info "  - Configuration: ${PKI_CONFIG_DIR}"
    log_info "  - Docker Compose: ${DOCKER_COMPOSE_DIR}"
    log_info ""
    log_info "SSH access for certificate download:"
    log_info "  - User: ${PKI_USER}"
    log_info "  - Certificates readable at: ${PKI_BUNDLE_DIR}"
    log_info ""
    log_info "CFSSL API endpoints:"
    log_info "  - Multiroot CA: http://localhost:8888"
    log_info "  - CFSSL API: http://localhost:8889"
}

# Main menu
main_menu() {
    clear
    echo -e "${BLUE}"
    cat << 'EOF'
  ____  _  _____ __  __                                   
 |  _ \| |/ /_ _|  \/  | __ _ _ __   __ _  __ _  ___ _ __ 
 | |_) | ' / | || |\/| |/ _` | '_ \ / _` |/ _` |/ _ \ '__|
 |  __/| . \ | || |  | | (_| | | | | (_| | (_| |  __/ |   
 |_|   |_|\_\___|_|  |_|\__,_|_| |_|\__,_|\__, |\___|_|   
                                          |___/           
EOF
    echo -e "${NC}"
    echo "PKI Manager - CFSSL Certificate Authority Server"
    echo "================================================"
    echo
    echo "  1) Install a PKI and TLS certificate authority server"
    echo "  2) Rotate certificates"
    echo "  3) Check certificate expiry"
    echo "  4) View certificate summary"
    echo "  5) Start/Restart CFSSL services"
    echo "  6) Stop CFSSL services"
    echo "  0) Exit"
    echo
    read -rp "Select an option: " choice
    
    case "$choice" in
        1)
            install_pki
            ;;
        2)
            rotate_certificates_menu
            ;;
        3)
            check_all_certs_expiry
            ;;
        4)
            display_cert_summary
            ;;
        5)
            if [[ -f "${DOCKER_COMPOSE_DIR}/docker-compose.yml" ]]; then
                cd "$DOCKER_COMPOSE_DIR"
                docker compose up -d
                log_info "CFSSL services started"
            else
                log_error "Docker Compose file not found. Please install PKI first."
            fi
            ;;
        6)
            if [[ -f "${DOCKER_COMPOSE_DIR}/docker-compose.yml" ]]; then
                cd "$DOCKER_COMPOSE_DIR"
                docker compose down
                log_info "CFSSL services stopped"
            else
                log_error "Docker Compose file not found."
            fi
            ;;
        0)
            log_info "Exiting..."
            exit $EXIT_SUCCESS
            ;;
        *)
            log_error "Invalid option"
            ;;
    esac
    
    echo
    read -rp "Press Enter to continue..."
    main_menu
}

# Script entry point
main() {
    # Check if running as root
    check_root
    
    # Show main menu
    main_menu
}

# Run main function
main "$@"
