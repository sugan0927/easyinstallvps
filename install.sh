#!/bin/bash

# EasyInstallVPS - Master Installation Script
# एक ही कमांड से पूरा VPS सेटअप

set -e  # Error होने पर रुक जाए

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}================================${NC}"
echo -e "${GREEN}🚀 EasyInstallVPS Master Script${NC}"
echo -e "${BLUE}================================${NC}"
echo -e "${YELLOW}Starting complete VPS setup...${NC}"
echo ""

# Function to print section header
print_section() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}► $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to install package if not exists
ensure_package() {
    if ! command_exists "$1"; then
        echo -e "${YELLOW}Installing $1...${NC}"
        apt-get install -y "$1"
    else
        echo -e "${GREEN}✓ $1 already installed${NC}"
    fi
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root!${NC}" 
   echo -e "${YELLOW}Use: sudo bash install.sh${NC}"
   exit 1
fi

# Update system first
print_section "Updating System Packages"
apt-get update
apt-get upgrade -y

# Install required packages
print_section "Installing Required Packages"
apt-get install -y curl wget git unzip tar gzip

# Check PHP
print_section "Checking PHP Installation"
if ! command_exists php; then
    echo -e "${YELLOW}PHP not found. Installing PHP...${NC}"
    apt-get install -y php php-cli php-fpm php-mysql php-curl php-gd php-mbstring php-xml php-xmlrpc php-zip php-json php-bcmath
    echo -e "${GREEN}✓ PHP installed successfully${NC}"
else
    echo -e "${GREEN}✓ PHP is already installed: $(php -v | head -n1)${NC}"
fi

# Check Python
print_section "Checking Python Installation"
if ! command_exists python3; then
    echo -e "${YELLOW}Python3 not found. Installing Python...${NC}"
    apt-get install -y python3 python3-pip python3-venv
    echo -e "${GREEN}✓ Python3 installed successfully${NC}"
else
    echo -e "${GREEN}✓ Python3 is already installed: $(python3 --version)${NC}"
fi

# Check required Python packages
print_section "Installing Python Dependencies"
pip3 install --upgrade pip
pip3 install requests colorama

# Create installation directory
print_section "Creating Installation Directory"
INSTALL_DIR="/opt/easyinstallvps"
mkdir -p $INSTALL_DIR
cd $INSTALL_DIR
echo -e "${GREEN}✓ Working directory: $INSTALL_DIR${NC}"

# Download all scripts
print_section "Downloading Installation Scripts"

echo -e "${YELLOW}Downloading WordPress installer...${NC}"
curl -sSL https://raw.githubusercontent.com/sugan0927/easyinstallvps/main/easyinstall_wp.php -o easyinstall_wp.php
chmod +x easyinstall_wp.php
echo -e "${GREEN}✓ WordPress installer downloaded${NC}"

echo -e "${YELLOW}Downloading Shell installer...${NC}"
curl -sSL https://raw.githubusercontent.com/sugan0927/easyinstallvps/main/easyinstall.sh -o easyinstall.sh
chmod +x easyinstall.sh
echo -e "${GREEN}✓ Shell installer downloaded${NC}"

echo -e "${YELLOW}Downloading Python core...${NC}"
curl -sSL https://raw.githubusercontent.com/sugan0927/easyinstallvps/main/easyinstall_core.py -o easyinstall_core.py
chmod +x easyinstall_core.py
echo -e "${GREEN}✓ Python core downloaded${NC}"

# Run WordPress installation
print_section "Running WordPress LEMP Stack Installation"
echo -e "${YELLOW}This will install Nginx, MySQL, PHP and WordPress...${NC}"
echo -e "${YELLOW}Press Enter to continue or Ctrl+C to cancel${NC}"
read -p ""

php easyinstall_wp.php

# Run Shell installation
print_section "Running Additional Shell Configuration"
echo -e "${YELLOW}Configuring server optimizations...${NC}"
bash easyinstall.sh

# Run Python setup
print_section "Running Python Configuration"
echo -e "${YELLOW}Setting up Python environment...${NC}"
python3 easyinstall_core.py

# Create alias for easy access
print_section "Creating Command Aliases"
echo 'alias easyvps="cd /opt/easyinstallvps && bash install.sh"' >> ~/.bashrc
echo 'alias easywp="php /opt/easyinstallvps/easyinstall_wp.php"' >> ~/.bashrc
echo 'alias easypy="python3 /opt/easyinstallvps/easyinstall_core.py"' >> ~/.bashrc
source ~/.bashrc
echo -e "${GREEN}✓ Aliases created: easyvps, easywp, easypy${NC}"

# Show installation summary
print_section "Installation Complete! 🎉"
echo -e "${GREEN}✓ All components installed successfully${NC}"
echo ""
echo -e "${YELLOW}Installation Summary:${NC}"
echo -e "  • WordPress LEMP Stack: ${GREEN}Installed${NC}"
echo -e "  • Server Optimizations: ${GREEN}Applied${NC}"
echo -e "  • Python Environment: ${GREEN}Configured${NC}"
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Next Steps:${NC}"
echo -e "1. Check WordPress: ${YELLOW}http://your-server-ip${NC}"
echo -e "2. MySQL credentials saved in: ${YELLOW}/root/.mysql_info${NC}"
echo -e "3. WordPress admin: ${YELLOW}http://your-server-ip/wp-admin${NC}"
echo ""
echo -e "${YELLOW}Useful Commands:${NC}"
echo -e "  • ${GREEN}easyvps${NC} - Run complete setup again"
echo -e "  • ${GREEN}easywp${NC} - Run WordPress installer only"
echo -e "  • ${GREEN}easypy${NC} - Run Python tools only"
echo -e "  • ${GREEN}cd /opt/easyinstallvps${NC} - Go to installation directory"
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
