#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables
POD_NAME=""
SUCCESS=false
TEMP_DIR=$(mktemp -d)
CREDS_FILE="${TEMP_DIR}/vpn_creds.enc"
KEY_FILE="${TEMP_DIR}/encryption.key"
IRC_USER="ircuser"
IRC_UID=1000

# Cleanup function
cleanup() {
    local exit_code=$?
    
    echo
    echo -e "${YELLOW}Cleaning up resources...${NC}"
    
    # Always remove temp files
    if [ -d "${TEMP_DIR}" ]; then
        rm -rf "${TEMP_DIR}"
        echo "Removed temporary files"
    fi
    
    # Only remove pod/containers on failure or interrupt
    if [ "${SUCCESS}" = false ]; then
        for container in irssi-client openvpn-gateway; do
            if sudo podman ps -a --format "{{.Names}}" | grep -q "^${container}$" 2>/dev/null; then
                echo "Removing container: ${container}"
                sudo podman rm -f "${container}" 2>/dev/null || true
            fi
        done
        
        if [ -n "${POD_NAME}" ]; then
            if sudo podman pod exists "${POD_NAME}" 2>/dev/null; then
                echo "Removing pod: ${POD_NAME}"
                sudo podman pod rm -f "${POD_NAME}" 2>/dev/null || true
            fi
        fi
    fi
    
    if [ $exit_code -ne 0 ] && [ "${SUCCESS}" = false ]; then
        echo -e "${RED}Cleanup completed (script interrupted or failed)${NC}"
    else
        echo -e "${GREEN}Cleanup completed${NC}"
    fi
}

# Interrupt handler
interrupt_handler() {
    echo
    echo -e "${YELLOW}==================================${NC}"
    echo -e "${YELLOW}  Script interrupted by user      ${NC}"
    echo -e "${YELLOW}==================================${NC}"
    SUCCESS=false
    exit 130
}

# Set trap for cleanup and interrupts
trap cleanup EXIT
trap interrupt_handler INT TERM

# Function to check sudo access
check_sudo() {
    echo -e "${GREEN}=== Checking Sudo Access ===${NC}"
    if ! sudo -n true 2>/dev/null; then
        echo "This script requires sudo access for podman commands."
        echo "Please enter your password:"
        sudo -v
    fi
    echo -e "${GREEN}✓ Sudo access confirmed${NC}"
}

# Function to prompt for credentials
get_credentials() {
    echo -e "${GREEN}=== VPN Credentials ===${NC}"
    echo -e "${BLUE}(Press Ctrl+C at any time to cancel)${NC}"
    echo
    
    read -p "Enter VPN username: " VPN_USER
    read -sp "Enter VPN password: " VPN_PASS
    echo
    
    if [ -z "${VPN_USER}" ] || [ -z "${VPN_PASS}" ]; then
        echo -e "${RED}Error: Username and password cannot be empty${NC}"
        exit 1
    fi
}

# Function to encrypt credentials
encrypt_credentials() {
    echo -e "${GREEN}=== Encrypting Credentials ===${NC}"
    
    # Generate random encryption key
    openssl rand -base64 32 > "${KEY_FILE}"
    
    # Create credentials file
    echo "${VPN_USER}" > "${TEMP_DIR}/vpn_creds.txt"
    echo "${VPN_PASS}" >> "${TEMP_DIR}/vpn_creds.txt"
    
    # Encrypt credentials
    openssl enc -aes-256-cbc -salt -pbkdf2 \
        -in "${TEMP_DIR}/vpn_creds.txt" \
        -out "${CREDS_FILE}" \
        -pass file:"${KEY_FILE}"
    
    # Remove plaintext file
    rm -f "${TEMP_DIR}/vpn_creds.txt"
    
    echo -e "${GREEN}✓ Credentials encrypted${NC}"
}

# Function to decrypt credentials
decrypt_credentials() {
    openssl enc -aes-256-cbc -d -pbkdf2 \
        -in "${CREDS_FILE}" \
        -pass file:"${KEY_FILE}" 2>/dev/null
}

# Function to get pod name
get_pod_name() {
    echo -e "${GREEN}=== Pod Configuration ===${NC}"
    echo -e "${BLUE}(Press Ctrl+C to cancel)${NC}"
    echo
    
    read -p "Enter pod name: " POD_NAME
    
    if [ -z "${POD_NAME}" ]; then
        echo -e "${RED}Error: Pod name cannot be empty${NC}"
        exit 1
    fi
    
    # Check if pod already exists
    if sudo podman pod exists "${POD_NAME}" 2>/dev/null; then
        echo -e "${RED}Error: Pod '${POD_NAME}' already exists${NC}"
        exit 1
    fi
}

# Function to create OpenVPN config
create_openvpn_config() {
    echo -e "${GREEN}=== Creating OpenVPN Configuration ===${NC}"
    echo -e "${BLUE}(Press Ctrl+C to cancel)${NC}"
    echo
    
    # Prompt for OpenVPN config file
    read -p "Enter path to OpenVPN config file (.ovpn): " OVPN_CONFIG
    
    if [ ! -f "${OVPN_CONFIG}" ]; then
        echo -e "${RED}Error: OpenVPN config file not found: ${OVPN_CONFIG}${NC}"
        exit 1
    fi
    
    # Copy config to temp directory
    cp "${OVPN_CONFIG}" "${TEMP_DIR}/client.ovpn"
    
    # Modify config to use auth-user-pass
    if ! grep -q "auth-user-pass" "${TEMP_DIR}/client.ovpn"; then
        echo "auth-user-pass /vpn/auth.txt" >> "${TEMP_DIR}/client.ovpn"
    else
        sed -i 's|auth-user-pass.*|auth-user-pass /vpn/auth.txt|' "${TEMP_DIR}/client.ovpn"
    fi
    
    echo -e "${GREEN}✓ OpenVPN config prepared${NC}"
}

# Function to confirm setup
confirm_setup() {
    echo
    echo -e "${BLUE}==================================${NC}"
    echo -e "${BLUE}  Setup Summary                   ${NC}"
    echo -e "${BLUE}==================================${NC}"
    echo "Pod name: ${POD_NAME}"
    echo "VPN config: ${OVPN_CONFIG}"
    echo "VPN user: ${VPN_USER}"
    echo "IRC user: ${IRC_USER} (UID: ${IRC_UID})"
    echo
    echo "The script will:"
    echo "  1. Create pod '${POD_NAME}'"
    echo "  2. Create OpenVPN container with your credentials"
    echo "  3. Create Irssi container with non-root user"
    echo "  4. Verify VPN tunnel is working"
    echo
    echo -e "${BLUE}==================================${NC}"
    echo
    
    read -p "Continue with setup? (y/N): " -n 1 -r CONFIRM
    echo
    
    if [[ ! $CONFIRM =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Setup cancelled by user${NC}"
        exit 0
    fi
}

# Function to create pod
create_pod() {
    echo -e "${GREEN}=== Creating Pod ===${NC}"
    
    sudo podman pod create --name "${POD_NAME}"
    
    echo -e "${GREEN}✓ Pod '${POD_NAME}' created${NC}"
}

# Function to create OpenVPN container
create_openvpn_container() {
    echo -e "${GREEN}=== Creating OpenVPN Container ===${NC}"
    
    # Decrypt credentials
    CREDS=$(decrypt_credentials)
    VPN_USER=$(echo "${CREDS}" | sed -n '1p')
    VPN_PASS=$(echo "${CREDS}" | sed -n '2p')
    
    # Create auth file
    echo "${VPN_USER}" > "${TEMP_DIR}/auth.txt"
    echo "${VPN_PASS}" >> "${TEMP_DIR}/auth.txt"
    chmod 600 "${TEMP_DIR}/auth.txt"
    
    # Create OpenVPN container WITHOUT mounting credentials
    sudo podman run -d \
        --name openvpn-gateway \
        --pod "${POD_NAME}" \
        --cap-add=NET_ADMIN \
        --device /dev/net/tun \
        docker.io/alpine:latest \
        sh -c "apk add --no-cache openvpn curl && mkdir -p /vpn && tail -f /dev/null"
    
    echo -e "${GREEN}✓ OpenVPN container created${NC}"
    
    # Wait for container to be fully running
    sleep 3
    
    # Copy files into container (not mounted, actual copies)
    sudo podman cp "${TEMP_DIR}/client.ovpn" openvpn-gateway:/vpn/client.ovpn
    sudo podman cp "${TEMP_DIR}/auth.txt" openvpn-gateway:/vpn/auth.txt
    
    echo -e "${GREEN}✓ Configuration files copied into container${NC}"
    
    # Start OpenVPN in the background
    sudo podman exec -d openvpn-gateway openvpn --config /vpn/client.ovpn --daemon
    
    # Wait for OpenVPN to read the credentials and establish connection
    sleep 10
    
    # Now securely delete the credential files from inside the container
    sudo podman exec openvpn-gateway sh -c "
        # Overwrite auth file with random data
        dd if=/dev/urandom of=/vpn/auth.txt bs=1 count=1024 2>/dev/null
        # Delete both files
        rm -f /vpn/auth.txt /vpn/client.ovpn
        # Remove the directory
        rmdir /vpn 2>/dev/null || true
    "
    
    echo -e "${GREEN}✓ Credentials securely deleted from container filesystem${NC}"
    echo -e "${GREEN}✓ VPN connection established and running in memory${NC}"
}

# Function to create irssi container
create_irssi_container() {
    echo -e "${GREEN}=== Creating Irssi Container ===${NC}"
    
    # Create persistent directory for Irssi config
    IRSSI_CONFIG_DIR="${HOME}/.irssi-pod-config"
    mkdir -p "${IRSSI_CONFIG_DIR}"
    
    # Set proper ownership for the config directory
    # The container will map UID 1000 inside to your user outside
    chown -R $(id -u):$(id -g) "${IRSSI_CONFIG_DIR}"
    
    # Create irssi container with non-root user
    sudo podman run -d \
        --name irssi-client \
        --pod "${POD_NAME}" \
        -v "${IRSSI_CONFIG_DIR}:/home/${IRC_USER}/.irssi:z" \
        docker.io/alpine:latest \
        sh -c "adduser -D -u ${IRC_UID} -h /home/${IRC_USER} ${IRC_USER} && \
               apk add --no-cache irssi curl nano tzdata && \
               su - ${IRC_USER} -c 'tail -f /dev/null'"
    
    echo -e "${GREEN}✓ Irssi container created with user '${IRC_USER}' (UID: ${IRC_UID})${NC}"
    echo -e "${BLUE}Config directory: ${IRSSI_CONFIG_DIR}${NC}"
}

# Function to test OpenVPN connection
test_openvpn_connection() {
    echo -e "${GREEN}=== Testing OpenVPN Connection ===${NC}"
    
    # Wait for VPN to establish
    echo "Waiting 20 seconds for VPN connection to establish..."
    echo -e "${BLUE}(Press Ctrl+C to cancel)${NC}"
    sleep 20
    
    # Get host IP
    HOST_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "unavailable")
    echo "Host IP: ${HOST_IP}"
    
    # Get OpenVPN container IP
    VPN_IP=$(sudo podman exec openvpn-gateway curl -s --max-time 10 ifconfig.me 2>/dev/null || echo "unavailable")
    
    if [ "${VPN_IP}" = "unavailable" ]; then
        echo -e "${RED}✗ OpenVPN connection test failed${NC}"
        echo "Checking OpenVPN logs..."
        sudo podman logs --tail 30 openvpn-gateway
        return 1
    fi
    
    echo "VPN IP: ${VPN_IP}"
    
    if [ "${HOST_IP}" != "${VPN_IP}" ] && [ "${VPN_IP}" != "unavailable" ]; then
        echo -e "${GREEN}✓ OpenVPN connection verified (IP changed)${NC}"
        return 0
    else
        echo -e "${YELLOW}⚠ Warning: Host IP matches VPN IP${NC}"
        echo "This might mean:"
        echo "  - VPN hasn't fully connected yet"
        echo "  - Your host is already behind a VPN"
        echo "  - Network configuration issue"
        return 1
    fi
}

# Function to test irssi tunnel
test_irssi_tunnel() {
    echo -e "${GREEN}=== Testing Irssi Network Tunnel ===${NC}"
    
    # Get irssi container IP (should match VPN IP)
    IRSSI_IP=$(sudo podman exec -u ${IRC_USER} irssi-client curl -s --max-time 10 ifconfig.me 2>/dev/null || echo "unavailable")
    
    if [ "${IRSSI_IP}" = "unavailable" ]; then
        echo -e "${RED}✗ Irssi network test failed${NC}"
        return 1
    fi
    
    echo "Irssi Container IP: ${IRSSI_IP}"
    
    # Get VPN IP for comparison
    VPN_IP=$(sudo podman exec openvpn-gateway curl -s --max-time 10 ifconfig.me 2>/dev/null || echo "unavailable")
    
    if [ "${IRSSI_IP}" = "${VPN_IP}" ] && [ "${IRSSI_IP}" != "unavailable" ]; then
        echo -e "${GREEN}✓ Irssi container is tunneled through OpenVPN${NC}"
        echo -e "${GREEN}✓ Both containers share the same pod network namespace${NC}"
        return 0
    else
        echo -e "${RED}✗ Irssi container is NOT tunneled through OpenVPN${NC}"
        return 1
    fi
}

# Function to display summary
display_summary() {
    echo
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}       Setup Completed Successfully        ${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo
    echo "Pod Name: ${POD_NAME}"
    echo "OpenVPN Container: openvpn-gateway"
    echo "Irssi Container: irssi-client"
    echo "IRC User: ${IRC_USER} (UID: ${IRC_UID})"
    echo "Config Directory: ${IRSSI_CONFIG_DIR}"
    echo
    echo "Connect to Irssi:"
    echo "  sudo podman exec -it -u ${IRC_USER} irssi-client irssi"
    echo
    echo "Set your timezone inside container"
    echo "  ln -sf /usr/share/zoneinfo/Europe/London /etc/localtime"
    echo "  echo \"Europe/London\" > /etc/timezone"
    echo
    echo "Edit config from host:"
    echo "  nano ${IRSSI_CONFIG_DIR}/config"
    echo
    echo "Configure Irssi username (inside irssi):"
    echo "  /SET user_name myusername"
    echo "  /SET real_name \"My Real Name\""
    echo "  /SET nick mynick"
    echo "  /SAVE"
    echo
    echo "View logs:"
    echo "  sudo podman logs openvpn-gateway"
    echo "  sudo podman logs irssi-client"
    echo
    echo "Check pod status:"
    echo "  sudo podman pod ps"
    echo "  sudo podman ps --pod"
    echo
    echo "Stop pod:"
    echo "  sudo podman pod stop ${POD_NAME}"
    echo
    echo "Remove pod:"
    echo "  sudo podman pod rm -f ${POD_NAME}"
    echo -e "${GREEN}============================================${NC}"
}

# Main execution
main() {
    echo -e "${GREEN}================================================${NC}"
    echo -e "${GREEN}  OpenVPN + Irssi Pod Setup (Rootful Podman)  ${NC}"
    echo -e "${GREEN}================================================${NC}"
    echo
    echo -e "${BLUE}Press Ctrl+C at ANY time to cancel setup${NC}"
    echo
    
    # Check sudo access
    check_sudo
    
    # Step 1-3: Get credentials
    get_credentials
    
    # Step 4: Encrypt credentials
    encrypt_credentials
    
    # Step 5: Prepare OpenVPN config
    create_openvpn_config
    
    # Step 6: Get pod name
    get_pod_name
    
    # Confirmation before proceeding
    confirm_setup
    
    # Step 7: Create pod
    create_pod
    
    # Step 8-9: Create OpenVPN container
    create_openvpn_container
    
    # Step 10: Create irssi container
    create_irssi_container
    
    # Step 11: Test OpenVPN connection
    if ! test_openvpn_connection; then
        echo -e "${RED}OpenVPN connection test failed. Cleaning up...${NC}"
        exit 1
    fi
    
    # Step 12: Test irssi tunnel
    if ! test_irssi_tunnel; then
        echo -e "${RED}Irssi tunnel test failed. Cleaning up...${NC}"
        exit 1
    fi
    
    # Mark success
    SUCCESS=true
    
    # Display summary
    display_summary
}

# Run main function
main

