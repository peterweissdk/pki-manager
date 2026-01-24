#!/bin/bash
#
# PKI Client - Certificate Request Script
# Downloads CA bundle and requests certificates from PKI server
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Default values
PKI_USER="pki-adm"
PKI_PORT="8889"
OUTPUT_DIR="."

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check required tools
check_requirements() {
    local missing=()
    
    if ! command -v ssh &> /dev/null; then
        missing+=("ssh")
    fi
    
    if ! command -v scp &> /dev/null; then
        missing+=("scp")
    fi
    
    if ! command -v curl &> /dev/null; then
        missing+=("curl")
    fi
    
    if ! command -v openssl &> /dev/null; then
        missing+=("openssl")
    fi
    
    if ! command -v jq &> /dev/null; then
        missing+=("jq")
    fi
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        log_error "Please install them and try again."
        exit 1
    fi
}

# Prompt for PKI server details
get_server_info() {
    echo
    read -rp "PKI Server address (IP or hostname): " PKI_HOST
    
    if [[ -z "$PKI_HOST" ]]; then
        log_error "PKI server address is required."
        exit 1
    fi
    
    read -rp "PKI SSH user [${PKI_USER}]: " input
    PKI_USER="${input:-$PKI_USER}"
    
    read -rp "PKI API port [${PKI_PORT}]: " input
    PKI_PORT="${input:-$PKI_PORT}"
    
    read -rp "Which intermediate CA to use? (1 or 2) [1]: " input
    CA_NUM="${input:-1}"
    CA_LABEL="intermediate_${CA_NUM}"
    CA_NAME="intermediate-${CA_NUM}"
}

# Download CA bundle and auth key
download_ca_bundle() {
    local need_download=true
    
    if [[ -f "${OUTPUT_DIR}/ca-bundle.crt" ]] && [[ -f "${OUTPUT_DIR}/.auth-key.txt" ]]; then
        read -rp "CA bundle and auth key already exist. Overwrite? [y/N]: " overwrite
        if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
            log_info "Using existing CA bundle and auth key."
            AUTH_KEY=$(cat "${OUTPUT_DIR}/.auth-key.txt")
            need_download=false
        fi
    fi
    
    if [[ "$need_download" == "true" ]]; then
        log_info "Downloading CA bundle and auth key from ${PKI_HOST}..."
        
        # Download both files in a single SCP command (one password prompt)
        if ! scp "${PKI_USER}@${PKI_HOST}:/opt/pki/certs/api/ca-bundle.crt" \
                 "${PKI_USER}@${PKI_HOST}:/opt/pki/config/${CA_NAME}-auth-key.txt" \
                 "${OUTPUT_DIR}/"; then
            log_error "Failed to download files. Check SSH access."
            exit 1
        fi
        
        # Rename auth key to hidden file
        mv "${OUTPUT_DIR}/${CA_NAME}-auth-key.txt" "${OUTPUT_DIR}/.auth-key.txt"
        chmod 600 "${OUTPUT_DIR}/.auth-key.txt"
        AUTH_KEY=$(cat "${OUTPUT_DIR}/.auth-key.txt")
        
        log_info "CA bundle and auth key downloaded successfully."
    fi
}

# Get certificate subject details
get_cert_details() {
    echo
    log_info "Enter certificate details:"
    echo
    
    read -rp "Common Name (CN) - e.g., myserver.example.com: " CERT_CN
    if [[ -z "$CERT_CN" ]]; then
        log_error "Common Name is required."
        exit 1
    fi
    
    read -rp "Additional hostnames/IPs (comma-separated, optional): " CERT_HOSTS
    
    read -rp "Organization (O) []: " CERT_O
    read -rp "Organizational Unit (OU) []: " CERT_OU
    read -rp "Country (C) - 2 letter code []: " CERT_C
    read -rp "State (ST) []: " CERT_ST
    read -rp "Locality/City (L) []: " CERT_L
    
    read -rp "Key algorithm (rsa/ecdsa) [rsa]: " KEY_ALGO
    KEY_ALGO="${KEY_ALGO:-rsa}"
    
    if [[ "$KEY_ALGO" == "rsa" ]]; then
        read -rp "RSA key size (2048/4096) [2048]: " KEY_SIZE
        KEY_SIZE="${KEY_SIZE:-2048}"
    else
        read -rp "ECDSA curve (256/384/521) [256]: " KEY_SIZE
        KEY_SIZE="${KEY_SIZE:-256}"
    fi
    
    read -rp "Output filename prefix [${CERT_CN}]: " OUTPUT_PREFIX
    OUTPUT_PREFIX="${OUTPUT_PREFIX:-$CERT_CN}"
    
    # Create output directory named after the CN
    CERT_OUTPUT_DIR="${OUTPUT_DIR}/${CERT_CN}"
    mkdir -p "$CERT_OUTPUT_DIR"
}

# Generate CSR locally
generate_csr() {
    log_info "Generating private key and CSR..."
    
    local key_file="${CERT_OUTPUT_DIR}/${OUTPUT_PREFIX}.key"
    local csr_file="${CERT_OUTPUT_DIR}/${OUTPUT_PREFIX}.csr"
    
    # Build subject string
    local subject="/CN=${CERT_CN}"
    [[ -n "$CERT_O" ]] && subject="${subject}/O=${CERT_O}"
    [[ -n "$CERT_OU" ]] && subject="${subject}/OU=${CERT_OU}"
    [[ -n "$CERT_C" ]] && subject="${subject}/C=${CERT_C}"
    [[ -n "$CERT_ST" ]] && subject="${subject}/ST=${CERT_ST}"
    [[ -n "$CERT_L" ]] && subject="${subject}/L=${CERT_L}"
    
    # Build SAN extension if additional hosts provided
    local san_ext=""
    if [[ -n "$CERT_HOSTS" ]]; then
        local san_entries="DNS:${CERT_CN}"
        IFS=',' read -ra hosts <<< "$CERT_HOSTS"
        for host in "${hosts[@]}"; do
            host=$(echo "$host" | xargs)  # trim whitespace
            if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                san_entries="${san_entries},IP:${host}"
            else
                san_entries="${san_entries},DNS:${host}"
            fi
        done
        san_ext="-addext subjectAltName=${san_entries}"
    fi
    
    # Generate key and CSR
    if [[ "$KEY_ALGO" == "rsa" ]]; then
        openssl req -new -newkey rsa:${KEY_SIZE} -nodes \
            -keyout "$key_file" \
            -out "$csr_file" \
            -subj "$subject" \
            $san_ext 2>/dev/null
    else
        openssl ecparam -name prime256v1 -genkey -noout -out "$key_file" 2>/dev/null
        openssl req -new -key "$key_file" \
            -out "$csr_file" \
            -subj "$subject" \
            $san_ext 2>/dev/null
    fi
    
    chmod 600 "$key_file"
    log_info "Private key saved to: ${key_file}"
    log_info "CSR generated: ${csr_file}"
}

# Request certificate from PKI server
request_certificate() {
    log_info "Requesting certificate from PKI server..."
    
    local csr_file="${CERT_OUTPUT_DIR}/${OUTPUT_PREFIX}.csr"
    local cert_file="${CERT_OUTPUT_DIR}/${OUTPUT_PREFIX}.crt"
    local chain_file="${CERT_OUTPUT_DIR}/${OUTPUT_PREFIX}-chain.crt"
    
    # Read CSR and escape for JSON
    local csr_content
    csr_content=$(cat "$csr_file" | awk 'NF {sub(/\r/, ""); printf "%s\\n",$0;}')
    
    # Build the inner request JSON
    local inner_request="{\"certificate_request\":\"${csr_content}\",\"label\":\"${CA_LABEL}\",\"profile\":\"server\"}"
    
    # Base64 encode the inner request for JSON transport (Go's []byte is base64 in JSON)
    local inner_request_b64
    inner_request_b64=$(echo -n "$inner_request" | base64 | tr -d '\n')
    
    # Create HMAC token for authentication
    # HMAC is computed over the RAW request bytes (before base64), then base64 encoded for JSON
    local token
    token=$(echo -n "$inner_request" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${AUTH_KEY}" -binary | base64 | tr -d '\n')
    
    # Build authenticated request (both token and request are base64-encoded for JSON []byte fields)
    local auth_request="{\"token\":\"${token}\",\"request\":\"${inner_request_b64}\"}"
    
    # Make API request to authsign endpoint
    local response
    local http_code
    local curl_exit_code
    local tmp_file=$(mktemp)
    
    http_code=$(curl -s -k --cacert "${OUTPUT_DIR}/ca-bundle.crt" \
        --connect-timeout 10 \
        --max-time 30 \
        -w "%{http_code}" \
        -o "$tmp_file" \
        -X POST -H "Content-Type: application/json" \
        -d "$auth_request" \
        "https://${PKI_HOST}:${PKI_PORT}/api/v1/cfssl/authsign" 2>&1)
    curl_exit_code=$?
    
    response=$(cat "$tmp_file")
    rm -f "$tmp_file"
    
    # Check if curl failed (connection error, timeout, etc.)
    if [[ $curl_exit_code -ne 0 ]]; then
        log_error "Failed to connect to PKI server at ${PKI_HOST}:${PKI_PORT}"
        case $curl_exit_code in
            6)  log_error "Could not resolve host." ;;
            7)  log_error "Failed to connect to host." ;;
            28) log_error "Connection timed out." ;;
            *)  log_error "Curl error code: ${curl_exit_code}" ;;
        esac
        exit 1
    fi
    
    if [[ "$http_code" != "200" ]]; then
        log_error "Failed to request certificate from PKI server."
        log_error "HTTP code: ${http_code}"
        log_error "Response: ${response}"
        exit 1
    fi
    
    # Check for success in JSON response
    local success
    success=$(echo "$response" | jq -r '.success' 2>/dev/null)
    
    if [[ "$success" != "true" ]]; then
        local error_msg
        error_msg=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"' 2>/dev/null)
        log_error "Certificate request failed: ${error_msg}"
        log_error "Full response: ${response}"
        exit 1
    fi
    
    # Extract certificate
    echo "$response" | jq -r '.result.certificate' > "$cert_file"
    
    # Create full chain (cert + CA bundle)
    cat "$cert_file" "${OUTPUT_DIR}/ca-bundle.crt" > "$chain_file"
    
    log_info "Certificate saved to: ${cert_file}"
    log_info "Full chain saved to: ${chain_file}"
}

# Display summary
display_summary() {
    echo
    log_info "Certificate request complete!"
    echo
    echo "Generated files in ${CERT_OUTPUT_DIR}/:"
    echo "  - Private key:  ${OUTPUT_PREFIX}.key"
    echo "  - Certificate:  ${OUTPUT_PREFIX}.crt"
    echo "  - Full chain:   ${OUTPUT_PREFIX}-chain.crt"
    echo "  - CA bundle:    ${OUTPUT_DIR}/ca-bundle.crt"
    echo
    echo "Usage examples:"
    echo "  # Nginx"
    echo "  ssl_certificate     ${CERT_OUTPUT_DIR}/${OUTPUT_PREFIX}-chain.crt;"
    echo "  ssl_certificate_key ${CERT_OUTPUT_DIR}/${OUTPUT_PREFIX}.key;"
    echo
    echo "  # Apache"
    echo "  SSLCertificateFile    ${CERT_OUTPUT_DIR}/${OUTPUT_PREFIX}.crt"
    echo "  SSLCertificateKeyFile ${CERT_OUTPUT_DIR}/${OUTPUT_PREFIX}.key"
    echo "  SSLCACertificateFile  ${OUTPUT_DIR}/ca-bundle.crt"
    echo
}

# Main
main() {
    echo -e "${BLUE}"
    cat << 'EOF'
  ____  _  _____    ____ _ _            _   
 |  _ \| |/ /_ _|  / ___| (_) ___ _ __ | |_ 
 | |_) | ' / | |  | |   | | |/ _ \ '_ \| __|
 |  __/| . \ | |  | |___| | |  __/ | | | |_ 
 |_|   |_|\_\___|  \____|_|_|\___|_| |_|\__|
EOF
    echo -e "${NC}"
    echo "PKI Client - Certificate Request Tool"
    echo "======================================"
    
    check_requirements
    get_server_info
    download_ca_bundle
    get_cert_details
    generate_csr
    request_certificate
    display_summary
}

main "$@"
