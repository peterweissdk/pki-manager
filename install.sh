#!/bin/bash
#
# PKI Manager - Installation Script
# Usage: curl -fsSL https://raw.githubusercontent.com/peterweissdk/pki-manager/main/install.sh | bash
#

set -e

# Configuration
GITHUB_RAW_URL="https://raw.githubusercontent.com/peterweissdk/pki-manager/main"
DEFAULT_INSTALL_DIR="/usr/local/bin"

# Scripts to install (source-file:target-name:description)
SCRIPTS=(
    "pki-manager.sh:pki-manager:setup and manage a PKI Certificate Authority server"
    "pki-client.sh:pki-client:request certificates interactively from a PKI server"
    "pki-client-cli.sh:pki-client-cli:automate certificate requests and renewals"
)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}⛔ This script must be run as root${NC}"
        echo "   Please run: curl -fsSL <url> | sudo bash"
        exit 1
    fi
}

# Prompt for installation directory
get_install_dir() {
    echo
    echo -e "${BLUE}📦 PKI Manager Installation${NC}"
    echo "============================"
    echo
    read -rp "Installation directory [${DEFAULT_INSTALL_DIR}]: " INSTALL_DIR </dev/tty
    INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
    
    # Expand ~ to home directory
    INSTALL_DIR="${INSTALL_DIR/#\~/$HOME}"
    
    # Create directory if it doesn't exist
    if [[ ! -d "$INSTALL_DIR" ]]; then
        echo -e "${YELLOW}⚠️  Directory does not exist. Creating...${NC}"
        if ! mkdir -p "$INSTALL_DIR"; then
            echo -e "${RED}⛔ Failed to create directory: ${INSTALL_DIR}${NC}"
            exit 1
        fi
    fi
    
    # Check if directory is writable
    if [[ ! -w "$INSTALL_DIR" ]]; then
        echo -e "${RED}⛔ Directory is not writable: ${INSTALL_DIR}${NC}"
        exit 1
    fi
    
    echo
}

# Download and install a script
install_script() {
    local source_file="$1"
    local target_name="$2"
    local description="$3"
    local target_path="${INSTALL_DIR}/${target_name}"
    
    echo -e "${BLUE}📥 Downloading ${source_file}...${NC}"
    
    # Download script
    if ! curl -fsSL "${GITHUB_RAW_URL}/${source_file}" -o "$target_path"; then
        echo -e "${RED}⛔ Failed to download ${source_file}${NC}"
        return 1
    fi
    
    echo -e "${BLUE}⚙️  Installing to ${target_path}...${NC}"
    
    # Set permissions
    chmod 755 "$target_path"
    chown root:root "$target_path"
    
    echo -e "${GREEN}✅ Script installed successfully to ${target_path}${NC}"
    echo -e "${GREEN}🚀 Run '${target_name}' to ${description}.${NC}"
    echo
}

# Main installation
main() {
    check_root
    get_install_dir
    
    local failed=0
    
    for script_info in "${SCRIPTS[@]}"; do
        IFS=':' read -r source_file target_name description <<< "$script_info"
        
        echo -e "${BLUE}📦 Installing ${target_name}...${NC}"
        
        if ! install_script "$source_file" "$target_name" "$description"; then
            echo -e "${RED}⛔ Installation failed for ${target_name}${NC}"
            failed=1
        fi
    done
    
    if [[ $failed -eq 1 ]]; then
        echo -e "${RED}⛔ Some installations failed. Please check the errors above.${NC}"
        exit 1
    fi
    
    echo "============================"
    echo -e "${GREEN}✅ All scripts installed successfully!${NC}"
    echo
    echo "Installed scripts:"
    for script_info in "${SCRIPTS[@]}"; do
        IFS=':' read -r _ target_name description <<< "$script_info"
        echo "  - ${target_name}: ${description}"
    done
    echo
}

main "$@"
