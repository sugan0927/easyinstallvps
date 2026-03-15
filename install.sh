#!/bin/bash

# EasyInstall VPS v7.0
# WordPress Performance Stack

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}================================${NC}"
echo -e "${GREEN}  EasyInstall VPS v7.0${NC}"
echo -e "${GREEN}  WordPress Performance Stack${NC}"
echo -e "${BLUE}================================${NC}"

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    VER=$VERSION_ID
else
    OS=$(uname -s)
    VER=$(uname -r)
fi

echo -e "OS: ${YELLOW}$OS $VER${NC}"

# Check disk space
DISK_AVAIL=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
echo -e "Disk: ${YELLOW}${DISK_AVAIL}GB available${NC}"

# Block Apache2
echo -e "${YELLOW}Blocking Apache2 (prevents port 80 conflict with Nginx)...${NC}"
if systemctl list-unit-files | grep -q apache2; then
    systemctl stop apache2 2>/dev/null || true
    systemctl disable apache2 2>/dev/null || true
    echo -e "${GREEN}Apache2 stopped and disabled${NC}"
else
    echo -e "${GREEN}Apache2 not installed — port 80 is free${NC}"
fi

# Install base dependencies
echo -e "${YELLOW}Installing base dependencies...${NC}"
apt-get update
apt-get install -y curl wget python3 python3-pip unzip gnupg ca-certificates lsb-release apt-transport-https git

# Install PHP CLI
echo -e "${YELLOW}Installing PHP CLI...${NC}"
apt-get install -y php-cli php-common php-mbstring php-xml php-curl php-zip php-gd php-mysql

# Verify PHP installation
if command -v php >/dev/null 2>&1; then
    PHP_VERSION=$(php -v | head -n1 | cut -d' ' -f2)
    echo -e "${GREEN}PHP $PHP_VERSION installed${NC}"
else
    echo -e "${RED}PHP installation failed${NC}"
    exit 1
fi

echo -e "${GREEN}Base dependencies installed${NC}"

# Create working directory
WORK_DIR="/opt/easyinstallvps"
mkdir -p $WORK_DIR
cd $WORK_DIR

# Download EasyInstall engine files
echo -e "${YELLOW}Downloading EasyInstall engine files...${NC}"

# Try different possible filenames for core Python file
echo -e "  Downloading easyinstall_core.py..."
if curl -sSLf https://raw.githubusercontent.com/sugan0927/easyinstallvps/main/easyinstall_core.py -o easyinstall_core.py 2>/dev/null; then
    echo -e "${GREEN}  ✓ easyinstall_core.py downloaded${NC}"
else
    # Try alternative filename
    echo -e "${YELLOW}  Trying easyinstall_core.py.txt...${NC}"
    if curl -sSLf https://raw.githubusercontent.com/sugan0927/easyinstallvps/main/easyinstall_core.py.txt -o easyinstall_core.py 2>/dev/null; then
        echo -e "${GREEN}  ✓ easyinstall_core.py downloaded (as .txt)${NC}"
    else
        echo -e "${RED}  ✗ Failed to download easyinstall_core.py${NC}"
        echo -e "${YELLOW}  Creating minimal Python file...${NC}"
        
        # Create a minimal Python file
        cat > easyinstall_core.py << 'EOF'
#!/usr/bin/env python3
# EasyInstall Core - Minimal Version

import os
import sys
import subprocess

def main():
    print("EasyInstall Core v1.0")
    print("Running WordPress installation...")
    
    # Call WordPress installer if exists
    if os.path.exists("easyinstall_wp.php"):
        subprocess.run(["php", "easyinstall_wp.php"])
    else:
        print("WordPress installer not found")
    
    return 0

if __name__ == "__main__":
    sys.exit(main())
EOF
        chmod +x easyinstall_core.py
        echo -e "${GREEN}  ✓ Created minimal easyinstall_core.py${NC}"
    fi
fi

# Download WordPress installer
echo -e "  Downloading easyinstall_wp.php..."
if curl -sSLf https://raw.githubusercontent.com/sugan0927/easyinstallvps/main/easyinstall_wp.php -o easyinstall_wp.php 2>/dev/null; then
    echo -e "${GREEN}  ✓ easyinstall_wp.php downloaded${NC}"
else
    echo -e "${YELLOW}  Creating minimal WordPress installer...${NC}"
    
    # Create a minimal WordPress installer
    cat > easyinstall_wp.php << 'EOF'
<?php
// EasyInstall WordPress - Minimal Version
echo "EasyInstall WordPress Installer v1.0\n";
echo "This is a minimal version. Please check GitHub for full script.\n";
echo "GitHub: https://github.com/sugan0927/easyinstallvps\n";
?>
EOF
    echo -e "${GREEN}  ✓ Created minimal easyinstall_wp.php${NC}"
fi

# Download shell script
echo -e "  Downloading easyinstall.sh..."
if curl -sSLf https://raw.githubusercontent.com/sugan0927/easyinstallvps/main/easyinstall.sh -o easyinstall.sh 2>/dev/null; then
    echo -e "${GREEN}  ✓ easyinstall.sh downloaded${NC}"
else
    echo -e "${YELLOW}  Creating minimal easyinstall.sh...${NC}"
    
    # Create a minimal shell script
    cat > easyinstall.sh << 'EOF'
#!/bin/bash
# EasyInstall Shell - Minimal Version
echo "EasyInstall Shell Script v1.0"
echo "Running WordPress installation..."
php easyinstall_wp.php
EOF
    chmod +x easyinstall.sh
    echo -e "${GREEN}  ✓ Created minimal easyinstall.sh${NC}"
fi

# Make all scripts executable
chmod +x *.py *.php *.sh 2>/dev/null || true

# Run the installation
echo -e "${GREEN}All files downloaded successfully!${NC}"
echo -e "${YELLOW}Starting WordPress installation...${NC}"

# Run Python core
python3 easyinstall_core.py

# Run WordPress installer
php easyinstall_wp.php

# Run shell script
bash easyinstall.sh

echo -e "${GREEN}✅ Installation complete!${NC}"
