#!/bin/bash
#
# pki-cert-manager.sh - Automated PKI Certificate Management
#
# Non-interactive script for checking, requesting, and renewing certificates
# from a CFSSL multirootca PKI server.
#
# Usage: pki-cert-manager.sh -e <env-file> [-c|-n|-r] [-f] [-v] [-h]
#

set -euo pipefail

# =============================================================================
# Exit Codes
# =============================================================================
readonly EXIT_SUCCESS=0
readonly EXIT_ERROR=1
readonly EXIT_MISSING_DEPS=2
readonly EXIT_MISSING_ENV=3
readonly EXIT_INVALID_CONFIG=4
readonly EXIT_CONNECTION_ERROR=5
readonly EXIT_AUTH_ERROR=6
readonly EXIT_CERT_EXISTS=7
readonly EXIT_CERT_NOT_FOUND=8
readonly EXIT_CERT_VALID=9

# =============================================================================
# Default Configuration
# =============================================================================
DEFAULT_LOG_FILE="/var/log/pki-cert-manager.log"
DEFAULT_PKI_PORT="8888"
DEFAULT_CA_NUM="1"
DEFAULT_KEY_ALGO="rsa"
DEFAULT_KEY_SIZE="2048"
DEFAULT_RENEW_THRESHOLD=90

# =============================================================================
# Global Variables
# =============================================================================
VERBOSE=false
FORCE=false
ACTION=""
ENV_FILE=""
LOG_FILE=""
CHECK_CERT_FILE=""

# =============================================================================
# Logging Functions
# =============================================================================
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_entry="[${timestamp}] [${level}] ${message}"
    
    # Always write to log file if set
    if [[ -n "$LOG_FILE" ]]; then
        echo "$log_entry" >> "$LOG_FILE" 2>/dev/null || true
    fi
    
    # Output to console if verbose or error (all to stderr to keep stdout clean for scripting)
    if [[ "$VERBOSE" == "true" ]] || [[ "$level" == "ERROR" ]]; then
        case "$level" in
            ERROR) echo -e "\033[0;31m${log_entry}\033[0m" >&2 ;;
            WARN)  echo -e "\033[0;33m${log_entry}\033[0m" >&2 ;;
            INFO)  echo -e "\033[0;32m${log_entry}\033[0m" >&2 ;;
            *)     echo "$log_entry" >&2 ;;
        esac
    fi
}

log_info()  { log "INFO" "$@"; }
log_warn()  { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }
log_debug() { [[ "$VERBOSE" == "true" ]] && log "DEBUG" "$@" || true; }

# =============================================================================
# Usage and Help
# =============================================================================
usage() {
    cat << EOF
Usage: $(basename "$0") [-e <env-file>] [-c <cert-file>|-n|-r] [-f] [-v] [-h]

Automated PKI Certificate Management Script

Download ca-bundle.crt and auth-key.txt from the PKI server and place them in /etc/pki/
  scp user[pki-admin]@pki-server:/opt/pki/certs/api/ca-bundle.crt /etc/pki/
  scp user[pki-admin]@pki-server:/opt/pki/config/intermediate-1-auth-key.txt /etc/pki/
  scp user[pki-admin]@pki-server:/opt/pki/config/intermediate-2-auth-key.txt /etc/pki/

Options:
  -e <file>   Environment file with certificate configuration (required for -n and -r)
  -c <file>   Check certificate expiry date (specify path to .crt file)
  -n          Request new certificate
  -r          Renew certificate (only if < ${DEFAULT_RENEW_THRESHOLD} days remaining)
  -f          Force mode:
                With -n: Overwrite existing certificates
                With -r: Renew even if > ${DEFAULT_RENEW_THRESHOLD} days remaining
  -v          Verbose output (default: log file only)
  -h          Show this help message

Exit Codes:
  ${EXIT_SUCCESS}  - Success
  ${EXIT_ERROR}  - General error
  ${EXIT_MISSING_DEPS}  - Missing required dependencies
  ${EXIT_MISSING_ENV}  - Environment file not found
  ${EXIT_INVALID_CONFIG}  - Invalid configuration
  ${EXIT_CONNECTION_ERROR}  - Connection error to PKI server
  ${EXIT_AUTH_ERROR}  - Authentication error
  ${EXIT_CERT_EXISTS}  - Certificate already exists (use -f to overwrite)
  ${EXIT_CERT_NOT_FOUND}  - Certificate not found (for -c or -r)
  ${EXIT_CERT_VALID}  - Certificate still valid (for -r without -f)

Environment File Variables:
  LOG_FILE          - Path to log file (default: ${DEFAULT_LOG_FILE})
  CA_BUNDLE_PATH    - Path to CA bundle file
  AUTH_KEY_PATH     - Path to authentication key file
  PKI_HOST          - PKI server address (IP or hostname)
  PKI_PORT          - PKI API port (default: ${DEFAULT_PKI_PORT})
  CA_NUM            - Intermediate CA number (1 or 2, default: ${DEFAULT_CA_NUM})
  CERT_CN           - Certificate Common Name
  CERT_HOSTS        - Additional hostnames/IPs (comma-separated, optional)
  CERT_O            - Organization (optional)
  CERT_OU           - Organizational Unit (optional)
  CERT_C            - Country code (optional)
  CERT_ST           - State (optional)
  CERT_L            - Locality/City (optional)
  KEY_ALGO          - Key algorithm: rsa or ecdsa (default: ${DEFAULT_KEY_ALGO})
  KEY_SIZE          - Key size (default: ${DEFAULT_KEY_SIZE})
  OUTPUT_PREFIX     - Output filename prefix (default: CERT_CN)
  CERT_DIR          - Directory for certificate files

Example:
  $(basename "$0") -c /etc/ssl/certs/myserver/myserver.crt
  $(basename "$0") -e /etc/pki/myserver.env -n -v
  $(basename "$0") -e /etc/pki/myserver.env -r -f

EOF
    exit $EXIT_SUCCESS
}

# =============================================================================
# Dependency Check
# =============================================================================
check_dependencies() {
    local missing=()
    local deps=(openssl curl jq base64)
    
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing[*]}"
        log_error "Please install them before running this script."
        exit $EXIT_MISSING_DEPS
    fi
    
    log_debug "All dependencies found: ${deps[*]}"
}

# =============================================================================
# Configuration Loading
# =============================================================================
load_env_file() {
    if [[ -z "$ENV_FILE" ]]; then
        log_error "Environment file not specified. Use -e <file>"
        exit $EXIT_MISSING_ENV
    fi
    
    if [[ ! -f "$ENV_FILE" ]]; then
        log_error "Environment file not found: ${ENV_FILE}"
        exit $EXIT_MISSING_ENV
    fi
    
    log_debug "Loading environment file: ${ENV_FILE}"
    
    # Source the environment file
    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +a
    
    # Set defaults for optional values
    LOG_FILE="${LOG_FILE:-$DEFAULT_LOG_FILE}"
    PKI_PORT="${PKI_PORT:-$DEFAULT_PKI_PORT}"
    CA_NUM="${CA_NUM:-$DEFAULT_CA_NUM}"
    KEY_ALGO="${KEY_ALGO:-$DEFAULT_KEY_ALGO}"
    KEY_SIZE="${KEY_SIZE:-$DEFAULT_KEY_SIZE}"
    OUTPUT_PREFIX="${OUTPUT_PREFIX:-$CERT_CN}"
    
    # Derived values
    CA_LABEL="intermediate_${CA_NUM}"
}

validate_config() {
    local errors=()
    
    # Required fields
    [[ -z "${CA_BUNDLE_PATH:-}" ]] && errors+=("CA_BUNDLE_PATH is required")
    [[ -z "${AUTH_KEY_PATH:-}" ]] && errors+=("AUTH_KEY_PATH is required")
    [[ -z "${PKI_HOST:-}" ]] && errors+=("PKI_HOST is required")
    [[ -z "${CERT_CN:-}" ]] && errors+=("CERT_CN is required")
    [[ -z "${CERT_DIR:-}" ]] && errors+=("CERT_DIR is required")
    
    # File existence checks
    [[ -n "${CA_BUNDLE_PATH:-}" ]] && [[ ! -f "$CA_BUNDLE_PATH" ]] && errors+=("CA bundle not found: ${CA_BUNDLE_PATH}")
    [[ -n "${AUTH_KEY_PATH:-}" ]] && [[ ! -f "$AUTH_KEY_PATH" ]] && errors+=("Auth key not found: ${AUTH_KEY_PATH}")
    
    # Validate key algorithm
    if [[ "$KEY_ALGO" != "rsa" ]] && [[ "$KEY_ALGO" != "ecdsa" ]]; then
        errors+=("KEY_ALGO must be 'rsa' or 'ecdsa'")
    fi
    
    # Validate CA number
    if [[ "$CA_NUM" != "1" ]] && [[ "$CA_NUM" != "2" ]]; then
        errors+=("CA_NUM must be '1' or '2'")
    fi
    
    if [[ ${#errors[@]} -gt 0 ]]; then
        log_error "Configuration errors:"
        for err in "${errors[@]}"; do
            log_error "  - ${err}"
        done
        exit $EXIT_INVALID_CONFIG
    fi
    
    log_debug "Configuration validated successfully"
    log_debug "  PKI_HOST: ${PKI_HOST}"
    log_debug "  PKI_PORT: ${PKI_PORT}"
    log_debug "  CERT_CN: ${CERT_CN}"
    log_debug "  CERT_DIR: ${CERT_DIR}"
    log_debug "  CA_LABEL: ${CA_LABEL}"
}

# =============================================================================
# Certificate Functions
# =============================================================================
get_cert_days_left() {
    local cert_file="$1"
    
    if [[ ! -f "$cert_file" ]]; then
        echo "-1"
        return
    fi
    
    # Use binary search with openssl x509 -checkend
    local low=0
    local high=7300  # ~20 years max
    
    # First check if cert is already expired
    if ! openssl x509 -in "$cert_file" -checkend 0 &>/dev/null; then
        echo "0"
        return
    fi
    
    # Binary search to find exact days left
    while [[ $((high - low)) -gt 1 ]]; do
        local mid=$(( (low + high) / 2 ))
        local mid_seconds=$((mid * 86400))
        if openssl x509 -in "$cert_file" -checkend "$mid_seconds" &>/dev/null; then
            low=$mid
        else
            high=$mid
        fi
    done
    
    echo "$low"
}

check_expiry() {
    local cert_file="$CHECK_CERT_FILE"
    
    if [[ ! -f "$cert_file" ]]; then
        log_error "Certificate not found: ${cert_file}"
        exit $EXIT_CERT_NOT_FOUND
    fi
    
    local days_left
    days_left=$(get_cert_days_left "$cert_file")
    
    local status="OK"
    local exit_code=$EXIT_SUCCESS
    
    if [[ "$days_left" -le 0 ]]; then
        status="EXPIRED"
        exit_code=$EXIT_ERROR
    elif [[ "$days_left" -lt 30 ]]; then
        status="CRITICAL"
        exit_code=$EXIT_ERROR
    elif [[ "$days_left" -lt "$DEFAULT_RENEW_THRESHOLD" ]]; then
        status="WARNING"
    fi
    
    log_info "Certificate: ${cert_file}"
    log_info "Days until expiry: ${days_left}"
    log_info "Status: ${status}"
    
    # Output days to stdout only when not verbose (for scripting)
    if [[ "$VERBOSE" != "true" ]]; then
        echo "${days_left}"
    fi
    
    exit $exit_code
}

generate_csr() {
    local key_file="${CERT_DIR}/${OUTPUT_PREFIX}.key"
    local csr_file="${CERT_DIR}/${OUTPUT_PREFIX}.csr"
    
    log_info "Generating private key and CSR..."
    
    # Build subject string
    local subject="/CN=${CERT_CN}"
    [[ -n "${CERT_O:-}" ]] && subject="${subject}/O=${CERT_O}"
    [[ -n "${CERT_OU:-}" ]] && subject="${subject}/OU=${CERT_OU}"
    [[ -n "${CERT_C:-}" ]] && subject="${subject}/C=${CERT_C}"
    [[ -n "${CERT_ST:-}" ]] && subject="${subject}/ST=${CERT_ST}"
    [[ -n "${CERT_L:-}" ]] && subject="${subject}/L=${CERT_L}"
    
    # Build SAN extension if additional hosts provided
    local san_ext=""
    if [[ -n "${CERT_HOSTS:-}" ]]; then
        san_ext="subjectAltName=DNS:${CERT_CN}"
        IFS=',' read -ra hosts <<< "$CERT_HOSTS"
        for host in "${hosts[@]}"; do
            host=$(echo "$host" | xargs)  # trim whitespace
            if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                san_ext="${san_ext},IP:${host}"
            else
                san_ext="${san_ext},DNS:${host}"
            fi
        done
    fi
    
    # Build extension arguments array
    local -a ext_args=()
    [[ -n "$san_ext" ]] && ext_args+=("-addext" "$san_ext")
    [[ -n "${KEY_USAGE:-}" ]] && ext_args+=("-addext" "keyUsage=${KEY_USAGE}")
    [[ -n "${EXT_KEY_USAGE:-}" ]] && ext_args+=("-addext" "extendedKeyUsage=${EXT_KEY_USAGE}")
    
    # Generate key and CSR
    if [[ "$KEY_ALGO" == "rsa" ]]; then
        openssl genrsa -out "$key_file" "$KEY_SIZE" 2>/dev/null
    else
        local curve="prime256v1"
        [[ "$KEY_SIZE" == "384" ]] && curve="secp384r1"
        [[ "$KEY_SIZE" == "521" ]] && curve="secp521r1"
        openssl ecparam -genkey -name "$curve" -out "$key_file" 2>/dev/null
    fi
    
    if [[ ${#ext_args[@]} -gt 0 ]]; then
        openssl req -new -key "$key_file" -out "$csr_file" -subj "$subject" \
            "${ext_args[@]}" 2>/dev/null
    else
        openssl req -new -key "$key_file" -out "$csr_file" -subj "$subject" 2>/dev/null
    fi
    
    chmod 600 "$key_file"
    
    log_info "Private key saved: ${key_file}"
    log_info "CSR generated: ${csr_file}"
}

request_certificate() {
    local csr_file="${CERT_DIR}/${OUTPUT_PREFIX}.csr"
    local cert_file="${CERT_DIR}/${OUTPUT_PREFIX}.crt"
    local chain_file="${CERT_DIR}/${OUTPUT_PREFIX}-chain.crt"
    
    log_info "Requesting certificate from PKI server..."
    
    # Read CSR and escape for JSON
    local csr_content
    csr_content=$(awk 'NF {sub(/\r/, ""); printf "%s\\n",$0;}' "$csr_file")
    
    # Read auth key
    local auth_key
    auth_key=$(cat "$AUTH_KEY_PATH")
    
    # Build the inner request JSON
    local inner_request="{\"certificate_request\":\"${csr_content}\",\"label\":\"${CA_LABEL}\",\"profile\":\"server\"}"
    
    # Base64 encode the inner request
    local inner_request_b64
    inner_request_b64=$(echo -n "$inner_request" | base64 | tr -d '\n')
    
    # Create HMAC token (over RAW request, not base64)
    local token
    token=$(echo -n "$inner_request" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${auth_key}" -binary | base64 | tr -d '\n')
    
    # Build authenticated request
    local auth_request="{\"token\":\"${token}\",\"request\":\"${inner_request_b64}\"}"
    
    # Make API request
    local response
    local http_code
    local curl_exit_code
    local tmp_file
    tmp_file=$(mktemp)
    
    http_code=$(curl -s -k --cacert "$CA_BUNDLE_PATH" \
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
    
    # Check connection errors
    if [[ $curl_exit_code -ne 0 ]]; then
        log_error "Failed to connect to PKI server at ${PKI_HOST}:${PKI_PORT}"
        case $curl_exit_code in
            6)  log_error "Could not resolve host." ;;
            7)  log_error "Failed to connect to host." ;;
            28) log_error "Connection timed out." ;;
            *)  log_error "Curl error code: ${curl_exit_code}" ;;
        esac
        exit $EXIT_CONNECTION_ERROR
    fi
    
    # Check HTTP response
    if [[ "$http_code" != "200" ]]; then
        log_error "PKI server returned HTTP ${http_code}"
        log_error "Response: ${response}"
        if [[ "$http_code" == "401" ]] || [[ "$http_code" == "403" ]]; then
            exit $EXIT_AUTH_ERROR
        fi
        exit $EXIT_ERROR
    fi
    
    # Check JSON response
    local success
    success=$(echo "$response" | jq -r '.success' 2>/dev/null)
    
    if [[ "$success" != "true" ]]; then
        local error_msg
        error_msg=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"' 2>/dev/null)
        log_error "Certificate request failed: ${error_msg}"
        exit $EXIT_ERROR
    fi
    
    # Extract and save certificate
    echo "$response" | jq -r '.result.certificate' > "$cert_file"
    
    # Create full chain
    cat "$cert_file" "$CA_BUNDLE_PATH" > "$chain_file"
    
    # Copy CA bundle to cert directory
    cp "$CA_BUNDLE_PATH" "${CERT_DIR}/ca-bundle.crt"
    
    log_info "Certificate saved: ${cert_file}"
    log_info "Full chain saved: ${chain_file}"
    log_info "CA bundle copied: ${CERT_DIR}/ca-bundle.crt"
}

new_certificate() {
    local cert_file="${CERT_DIR}/${OUTPUT_PREFIX}.crt"
    
    # Check if certificate already exists
    if [[ -f "$cert_file" ]] && [[ "$FORCE" != "true" ]]; then
        log_error "Certificate already exists: ${cert_file}"
        log_error "Use -f to overwrite existing certificate"
        exit $EXIT_CERT_EXISTS
    fi
    
    # Create output directory
    mkdir -p "$CERT_DIR"
    
    # Generate CSR and request certificate
    generate_csr
    request_certificate
    
    log_info "New certificate created successfully"
    exit $EXIT_SUCCESS
}

renew_certificate() {
    local cert_file="${CERT_DIR}/${OUTPUT_PREFIX}.crt"
    
    # Check if certificate exists
    if [[ ! -f "$cert_file" ]]; then
        log_error "Certificate not found: ${cert_file}"
        log_error "Use -n to create a new certificate"
        exit $EXIT_CERT_NOT_FOUND
    fi
    
    # Check days remaining
    local days_left
    days_left=$(get_cert_days_left "$cert_file")
    
    log_info "Certificate has ${days_left} days remaining"
    
    # Check if renewal is needed
    if [[ "$days_left" -ge "$DEFAULT_RENEW_THRESHOLD" ]] && [[ "$FORCE" != "true" ]]; then
        log_info "Certificate is still valid (${days_left} days > ${DEFAULT_RENEW_THRESHOLD} days threshold)"
        log_info "Use -f to force renewal"
        exit $EXIT_CERT_VALID
    fi
    
    # Backup existing certificate
    local backup_dir="${CERT_DIR}/backup"
    local backup_date
    backup_date=$(date '+%Y%m%d_%H%M%S')
    mkdir -p "$backup_dir"
    
    for ext in key csr crt; do
        if [[ -f "${CERT_DIR}/${OUTPUT_PREFIX}.${ext}" ]]; then
            cp "${CERT_DIR}/${OUTPUT_PREFIX}.${ext}" "${backup_dir}/${OUTPUT_PREFIX}.${ext}.${backup_date}"
        fi
    done
    if [[ -f "${CERT_DIR}/${OUTPUT_PREFIX}-chain.crt" ]]; then
        cp "${CERT_DIR}/${OUTPUT_PREFIX}-chain.crt" "${backup_dir}/${OUTPUT_PREFIX}-chain.crt.${backup_date}"
    fi
    
    log_info "Existing certificates backed up to: ${backup_dir}"
    
    # Generate new CSR and request certificate
    generate_csr
    request_certificate
    
    log_info "Certificate renewed successfully"
    exit $EXIT_SUCCESS
}

# =============================================================================
# Argument Parsing
# =============================================================================
parse_args() {
    while getopts ":e:c:nrfvh" opt; do
        case $opt in
            e) ENV_FILE="$OPTARG" ;;
            c) ACTION="check"; CHECK_CERT_FILE="$OPTARG" ;;
            n) ACTION="new" ;;
            r) ACTION="renew" ;;
            f) FORCE=true ;;
            v) VERBOSE=true ;;
            h) usage ;;
            :)
                echo "Error: Option -$OPTARG requires an argument." >&2
                exit $EXIT_ERROR
                ;;
            \?)
                echo "Error: Invalid option -$OPTARG" >&2
                exit $EXIT_ERROR
                ;;
        esac
    done
    
    # Validate action is specified
    if [[ -z "$ACTION" ]]; then
        echo "Error: No action specified. Use -c <cert-file>, -n, or -r" >&2
        echo "Use -h for help" >&2
        exit $EXIT_ERROR
    fi
    
    # Validate env file is provided for new/renew actions
    if [[ "$ACTION" != "check" ]] && [[ -z "$ENV_FILE" ]]; then
        echo "Error: Environment file required for -n or -r. Use -e <file>" >&2
        exit $EXIT_ERROR
    fi
}

# =============================================================================
# Main
# =============================================================================
main() {
    parse_args "$@"
    check_dependencies
    
    # For check action, we don't need the env file
    if [[ "$ACTION" == "check" ]]; then
        check_expiry
    else
        load_env_file
        validate_config
        log_info "Starting pki-cert-manager (action: ${ACTION}, force: ${FORCE})"
        
        case "$ACTION" in
            new)   new_certificate ;;
            renew) renew_certificate ;;
        esac
    fi
}

main "$@"
