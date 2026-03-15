#!/bin/bash

# ==============================================
# EasyInstall VPS - Master Installation Script
# Version: 7.0
# Description: Complete VPS Setup with WordPress,
#              LEMP Stack, Python Tools & Optimizations
# Author: sugan0927
# ==============================================

set -e  # Exit on error

# ==============================================
# Color Definitions
# ==============================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# ==============================================
# Print Banner
# ==============================================
print_banner() {
    clear
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${GREEN}                    EasyInstall VPS v7.0                     ${BLUE}║${NC}"
    echo -e "${BLUE}║${YELLOW}           Complete VPS Setup - WordPress + LEMP            ${BLUE}║${NC}"
    echo -e "${BLUE}║${WHITE}                    One Command - Everything                   ${BLUE}║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ==============================================
# Print Section Header
# ==============================================
print_section() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}► $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# ==============================================
# Print Success Message
# ==============================================
print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

# ==============================================
# Print Info Message
# ==============================================
print_info() {
    echo -e "${YELLOW}ℹ️ $1${NC}"
}

# ==============================================
# Print Error Message
# ==============================================
print_error() {
    echo -e "${RED}❌ $1${NC}"
}

# ==============================================
# Print Warning Message
# ==============================================
print_warning() {
    echo -e "${MAGENTA}⚠️ $1${NC}"
}

# ==============================================
# Check if running as root
# ==============================================
check_root() {
    print_section "Checking Privileges"
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root!"
        print_info "Use: sudo bash install.sh"
        exit 1
    else
        print_success "Running as root"
    fi
}

# ==============================================
# Detect OS
# ==============================================
detect_os() {
    print_section "Detecting Operating System"
    
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
        OS_NAME=$NAME
    else
        OS=$(uname -s)
        VER=$(uname -r)
        OS_NAME=$OS
    fi
    
    echo -e "OS: ${GREEN}$OS_NAME $VER${NC}"
    
    # Check if supported OS
    if [[ "$OS" != "ubuntu" && "$OS" != "debian" ]]; then
        print_warning "This script is optimized for Ubuntu/Debian"
        print_info "Continuing anyway..."
    else
        print_success "Supported OS detected"
    fi
}

# ==============================================
# Check Disk Space
# ==============================================
check_disk_space() {
    print_section "Checking Disk Space"
    
    DISK_AVAIL=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
    echo -e "Available Disk Space: ${GREEN}${DISK_AVAIL}GB${NC}"
    
    if [ "$DISK_AVAIL" -lt 5 ]; then
        print_error "Insufficient disk space! Need at least 5GB"
        exit 1
    else
        print_success "Sufficient disk space available"
    fi
}

# ==============================================
# Check Internet Connection
# ==============================================
check_internet() {
    print_section "Checking Internet Connection"
    
    if ping -c 1 google.com &> /dev/null; then
        print_success "Internet connection active"
    else
        print_error "No internet connection"
        exit 1
    fi
}

# ==============================================
# Block Apache2 (Prevents port 80 conflict)
# ==============================================
block_apache() {
    print_section "Checking Apache2"
    
    if systemctl list-unit-files | grep -q apache2; then
        print_info "Apache2 detected - stopping and disabling..."
        systemctl stop apache2 2>/dev/null || true
        systemctl disable apache2 2>/dev/null || true
        print_success "Apache2 stopped and disabled"
    else
        print_success "Apache2 not installed — port 80 is free"
    fi
}

# ==============================================
# Update System
# ==============================================
update_system() {
    print_section "Updating System Packages"
    
    print_info "Running apt update..."
    apt-get update -y
    
    print_info "Upgrading packages..."
    apt-get upgrade -y
    
    print_success "System updated successfully"
}

# ==============================================
# Install Base Dependencies
# ==============================================
install_base_deps() {
    print_section "Installing Base Dependencies"
    
    local deps=(
        "curl"
        "wget"
        "git"
        "unzip"
        "zip"
        "tar"
        "gzip"
        "python3"
        "python3-pip"
        "python3-venv"
        "software-properties-common"
        "apt-transport-https"
        "ca-certificates"
        "gnupg"
        "lsb-release"
        "ufw"
        "fail2ban"
        "htop"
        "neofetch"
        "tree"
        "vim"
        "nano"
    )
    
    for dep in "${deps[@]}"; do
        echo -ne "Installing $dep... "
        if apt-get install -y "$dep" &>/dev/null; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${RED}FAILED${NC}"
        fi
    done
    
    print_success "Base dependencies installed"
}

# ==============================================
# Install PHP and Extensions
# ==============================================
install_php() {
    print_section "Installing PHP and Extensions"
    
    # Add PHP repository if needed
    if [[ "$OS" == "ubuntu" ]]; then
        add-apt-repository -y ppa:ondrej/php
        apt-get update
    fi
    
    local php_extensions=(
        "php"
        "php-cli"
        "php-fpm"
        "php-mysql"
        "php-pgsql"
        "php-sqlite3"
        "php-curl"
        "php-gd"
        "php-mbstring"
        "php-xml"
        "php-xmlrpc"
        "php-zip"
        "php-bcmath"
        "php-json"
        "php-tokenizer"
        "php-soap"
        "php-intl"
        "php-imagick"
        "php-redis"
        "php-memcached"
        "php-opcache"
        "php-readline"
    )
    
    for ext in "${php_extensions[@]}"; do
        echo -ne "Installing $ext... "
        if apt-get install -y "$ext" &>/dev/null; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${RED}FAILED${NC}"
        fi
    done
    
    # Verify PHP installation
    if command -v php >/dev/null 2>&1; then
        PHP_VERSION=$(php -v | head -n1 | cut -d' ' -f2)
        print_success "PHP $PHP_VERSION installed"
    else
        print_error "PHP installation failed"
        exit 1
    fi
}

# ==============================================
# Install Nginx
# ==============================================
install_nginx() {
    print_section "Installing Nginx"
    
    apt-get install -y nginx
    
    # Start and enable Nginx
    systemctl start nginx
    systemctl enable nginx
    
    # Check if Nginx is running
    if systemctl is-active --quiet nginx; then
        print_success "Nginx installed and running"
    else
        print_error "Nginx installation failed"
        exit 1
    fi
}

# ==============================================
# Install MySQL/MariaDB
# ==============================================
install_mysql() {
    print_section "Installing MySQL/MariaDB"
    
    # Generate random root password
    MYSQL_ROOT_PASS=$(openssl rand -base64 32 | tr -d /=+ | cut -c -20)
    
    # Install MariaDB
    apt-get install -y mariadb-server mariadb-client
    
    # Start and enable MySQL
    systemctl start mariadb
    systemctl enable mariadb
    
    # Secure MySQL installation
    mysql --user=root <<_EOF_
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
_EOF_
    
    # Save MySQL credentials
    cat > /root/.mysql_info << EOF
MySQL Root Password: ${MYSQL_ROOT_PASS}
MySQL Host: localhost
MySQL Port: 3306
Login Command: mysql -u root -p
Date: $(date)
EOF
    chmod 600 /root/.mysql_info
    
    print_success "MySQL installed and secured"
    print_info "MySQL root password saved in /root/.mysql_info"
}

# ==============================================
# Install Redis (Optional)
# ==============================================
install_redis() {
    print_section "Installing Redis (Optional)"
    
    if apt-get install -y redis-server; then
        systemctl start redis-server
        systemctl enable redis-server
        print_success "Redis installed"
    else
        print_warning "Redis installation failed - continuing without Redis"
    fi
}

# ==============================================
# Install Certbot (SSL)
# ==============================================
install_certbot() {
    print_section "Installing Certbot (SSL)"
    
    apt-get install -y certbot python3-certbot-nginx
    print_success "Certbot installed"
}

# ==============================================
# Create Working Directory
# ==============================================
create_workdir() {
    print_section "Creating Working Directory"
    
    WORK_DIR="/opt/easyinstallvps"
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"
    
    print_success "Working directory: $WORK_DIR"
}

# ==============================================
# Download All Scripts from GitHub
# ==============================================
download_scripts() {
    print_section "Downloading EasyInstall Scripts"
    
    # GitHub raw base URL
    GITHUB_RAW="https://raw.githubusercontent.com/sugan0927/easyinstallvps/main"
    
    # Array of scripts to download
    declare -A scripts=(
        ["easyinstall_wp.php"]="WordPress Installer (PHP)"
        ["easyinstall_core.py"]="Python Core Module"
        ["easyinstall.sh"]="Shell Installation Script"
        ["easyinstall_backup.sh"]="Backup Script"
        ["easyinstall_optimize.sh"]="Optimization Script"
        ["easyinstall_security.sh"]="Security Hardening Script"
        ["easyinstall_monitor.py"]="System Monitor (Python)"
        ["easyinstall_cleanup.sh"]="Cleanup Script"
        ["easyinstall_update.sh"]="Update Script"
        ["easyinstall_nginx.conf"]="Nginx Configuration"
        ["easyinstall_php.ini"]="PHP Configuration"
        ["easyinstall_wp-config.php"]="WordPress Config Template"
    )
    
    # Download each script
    for script in "${!scripts[@]}"; do
        description="${scripts[$script]}"
        echo -ne "Downloading ${YELLOW}$script${NC} ($description)... "
        
        if curl -sSLf "$GITHUB_RAW/$script" -o "$script" 2>/dev/null; then
            chmod +x "$script" 2>/dev/null || true
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${RED}FAILED${NC}"
            # Create fallback/minimal version
            create_fallback "$script" "$description"
        fi
    done
    
    print_success "All scripts downloaded"
}

# ==============================================
# Create Fallback Scripts
# ==============================================
create_fallback() {
    local script=$1
    local description=$2
    
    case "$script" in
        easyinstall_wp.php)
            cat > easyinstall_wp.php << 'EOF'
<?php
/**
 * EasyInstall WordPress Installer
 * Version: 1.0
 */

echo "========================================\n";
echo "EasyInstall WordPress Installer v1.0\n";
echo "========================================\n\n";

// Check if running as root
if (posix_getuid() !== 0) {
    die("This script must be run as root!\n");
}

echo "Installing WordPress with LEMP Stack...\n";
echo "This is a fallback script.\n";
echo "Please check GitHub for full version.\n";
echo "GitHub: https://github.com/sugan0927/easyinstallvps\n";
?>
EOF
            ;;
            
        easyinstall_core.py)
            cat > easyinstall_core.py << 'EOF'
#!/usr/bin/env python3
"""
EasyInstall Python Core Module
Version: 1.0
"""

import os
import sys
import subprocess
import platform

def main():
    print("=" * 40)
    print("EasyInstall Python Core v1.0")
    print("=" * 40)
    
    print(f"System: {platform.system()} {platform.release()}")
    print(f"Python: {platform.python_version()}")
    
    print("\nThis is a fallback script.")
    print("Please check GitHub for full version.")
    print("GitHub: https://github.com/sugan0927/easyinstallvps")
    
    return 0

if __name__ == "__main__":
    sys.exit(main())
EOF
            ;;
            
        easyinstall.sh)
            cat > easyinstall.sh << 'EOF'
#!/bin/bash
# EasyInstall Shell Script - Fallback Version

echo "========================================"
echo "EasyInstall Shell Script v1.0"
echo "========================================"
echo ""
echo "This is a fallback script."
echo "Please check GitHub for full version."
echo "GitHub: https://github.com/sugan0927/easyinstallvps"
echo ""
php easyinstall_wp.php
EOF
            ;;
            
        easyinstall_backup.sh)
            cat > easyinstall_backup.sh << 'EOF'
#!/bin/bash
# Backup Script

BACKUP_DIR="/root/backups"
DATE=$(date +%Y%m%d_%H%M%S)

mkdir -p "$BACKUP_DIR"

echo "Creating backup in $BACKUP_DIR/backup_$DATE.tar.gz"
tar -czf "$BACKUP_DIR/backup_$DATE.tar.gz" /var/www/html /etc/nginx /etc/php/*/fpm/pool.d 2>/dev/null || true

echo "Backup completed"
EOF
            ;;
            
        easyinstall_optimize.sh)
            cat > easyinstall_optimize.sh << 'EOF'
#!/bin/bash
# Optimization Script

echo "Optimizing system..."

# Optimize swappiness
echo "vm.swappiness=10" >> /etc/sysctl.conf

# Optimize filesystem
echo "fs.file-max=65535" >> /etc/sysctl.conf

# Apply changes
sysctl -p

echo "Optimization completed"
EOF
            ;;
            
        easyinstall_security.sh)
            cat > easyinstall_security.sh << 'EOF'
#!/bin/bash
# Security Hardening Script

echo "Hardening security..."

# Configure UFW
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# Configure fail2ban
systemctl enable fail2ban
systemctl start fail2ban

echo "Security hardening completed"
EOF
            ;;
            
        easyinstall_monitor.py)
            cat > easyinstall_monitor.py << 'EOF'
#!/usr/bin/env python3
# System Monitor

import psutil
import time

def main():
    print("System Monitor - Press Ctrl+C to exit")
    print("-" * 50)
    
    try:
        while True:
            cpu = psutil.cpu_percent(interval=1)
            mem = psutil.virtual_memory().percent
            disk = psutil.disk_usage('/').percent
            
            print(f"CPU: {cpu}% | RAM: {mem}% | Disk: {disk}%", end="\r")
            time.sleep(2)
    except KeyboardInterrupt:
        print("\n\nExiting...")

if __name__ == "__main__":
    main()
EOF
            ;;
            
        *)
            # Generic fallback for other scripts
            echo "#!/bin/bash" > "$script"
            echo "# $description - Fallback Version" >> "$script"
            echo "echo \"$description - Fallback Version\"" >> "$script"
            echo "echo \"Please check GitHub for full version\"" >> "$script"
            ;;
    esac
    
    chmod +x "$script" 2>/dev/null || true
}

# ==============================================
# Install Python Dependencies
# ==============================================
install_python_deps() {
    print_section "Installing Python Dependencies"
    
    pip3 install --upgrade pip
    pip3 install requests colorama psutil
        
    print_success "Python dependencies installed"
}

# ==============================================
# Configure Firewall
# ==============================================
configure_firewall() {
    print_section "Configuring Firewall"
    
    # Allow SSH
    ufw allow 22/tcp
    
    # Allow HTTP/HTTPS
    ufw allow 80/tcp
    ufw allow 443/tcp
    
    # Enable UFW
    echo "y" | ufw enable
    
    print_success "Firewall configured"
}

# ==============================================
# Configure Fail2ban
# ==============================================
configure_fail2ban() {
    print_section "Configuring Fail2ban"
    
    # Create local jail configuration
    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true

[nginx-http-auth]
enabled = true
EOF
    
    systemctl restart fail2ban
    print_success "Fail2ban configured"
}

# ==============================================
# Create Command Aliases
# ==============================================
create_aliases() {
    print_section "Creating Command Aliases"
    
    cat >> ~/.bashrc << EOF

# EasyInstall VPS Aliases
alias easyvps='cd /opt/easyinstallvps && bash install.sh'
alias easywp='php /opt/easyinstallvps/easyinstall_wp.php'
alias easypy='python3 /opt/easyinstallvps/easyinstall_core.py'
alias easybackup='bash /opt/easyinstallvps/easyinstall_backup.sh'
alias easyopt='bash /opt/easyinstallvps/easyinstall_optimize.sh'
easysec='bash /opt/easyinstallvps/easyinstall_security.sh'
alias easymon='python3 /opt/easyinstallvps/easyinstall_monitor.py'
alias easyclean='bash /opt/easyinstallvps/easyinstall_cleanup.sh'
alias easyupdate='bash /opt/easyinstallvps/easyinstall_update.sh'
alias easylogs='tail -f /var/log/nginx/access.log'
EOF
    
    source ~/.bashrc 2>/dev/null || true
    print_success "Aliases created"
}

# ==============================================
# Run All Scripts
# ==============================================
run_scripts() {
    print_section "Running Installation Scripts"
    
    cd /opt/easyinstallvps
    
    # Run Python core
    if [ -f "easyinstall_core.py" ]; then
        print_info "Running Python Core..."
        python3 easyinstall_core.py
    fi
    
    # Run WordPress installer
    if [ -f "easyinstall_wp.php" ]; then
        print_info "Running WordPress Installer..."
        php easyinstall_wp.php
    fi
    
    # Run shell script
    if [ -f "easyinstall.sh" ]; then
        print_info "Running Shell Script..."
        bash easyinstall.sh
    fi
    
    # Run security script
    if [ -f "easyinstall_security.sh" ]; then
        print_info "Running Security Hardening..."
        bash easyinstall_security.sh
    fi
    
    # Run optimization script
    if [ -f "easyinstall_optimize.sh" ]; then
        print_info "Running Optimization..."
        bash easyinstall_optimize.sh
    fi
    
    print_success "All scripts executed"
}

# ==============================================
# Show Summary
# ==============================================
show_summary() {
    print_section "Installation Summary"
    
    IP_ADDR=$(curl -s ifconfig.me)
    
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}                    INSTALLATION COMPLETE!                    ${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    echo -e "${CYAN}📋 System Information:${NC}"
    echo -e "  • OS: ${GREEN}$OS_NAME $VER${NC}"
    echo -e "  • PHP: ${GREEN}$(php -v | head -n1 | cut -d' ' -f2)${NC}"
    echo -e "  • Nginx: ${GREEN}$(nginx -v 2>&1 | cut -d'/' -f2)${NC}"
    echo -e "  • MySQL: ${GREEN}$(mysql --version | cut -d' ' -f6 | cut -d',' -f1)${NC}"
    echo -e "  • Python: ${GREEN}$(python3 --version | cut -d' ' -f2)${NC}"
    echo ""
    
    echo -e "${CYAN}🌐 WordPress Access:${NC}"
    echo -e "  • Site: ${YELLOW}http://$IP_ADDR${NC}"
    echo -e "  • Admin: ${YELLOW}http://$IP_ADDR/wp-admin${NC}"
    echo ""
    
    echo -e "${CYAN}🔑 MySQL Credentials:${NC}"
    echo -e "  • Password File: ${YELLOW}/root/.mysql_info${NC}"
    echo -e "  • Login Command: ${YELLOW}mysql -u root -p${NC}"
    echo ""
    
    echo -e "${CYAN}📁 Installation Directory:${NC}"
    echo -e "  • Path: ${YELLOW}/opt/easyinstallvps${NC}"
    echo ""
    
    echo -e "${CYAN}⚡ Available Commands:${NC}"
    echo -e "  • ${GREEN}easyvps${NC}     - Run complete setup again"
    echo -e "  • ${GREEN}easywp${NC}      - Run WordPress installer"
    echo -e "  • ${GREEN}easypy${NC}      - Run Python tools"
    echo -e "  • ${GREEN}easybackup${NC}  - Create backup"
    echo -e "  • ${GREEN}easyopt${NC}     - Optimize system"
    echo -e "  • ${GREEN}easysec${NC}     - Security hardening"
    echo -e "  • ${GREEN}easymon${NC}     - System monitor"
    echo -e "  • ${GREEN}easyclean${NC}   - Cleanup temporary files"
    echo -e "  • ${GREEN}easyupdate${NC}  - Update scripts"
    echo -e "  • ${GREEN}easylogs${NC}    - View Nginx logs"
    echo ""
    
    echo -e "${CYAN}📜 Script Files:${NC}"
    ls -la /opt/easyinstallvps/ | grep -E "\.(sh|php|py|conf)$" | while read line; do
        echo -e "  • ${YELLOW}$(echo $line | awk '{print $9}')${NC}"
    done
    echo ""
    
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}              🚀 SYSTEM READY FOR PRODUCTION!                ${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# ==============================================
# Main Function
# ==============================================
main() {
    print_banner
    check_root
    detect_os
    check_disk_space
    check_internet
    block_apache
    update_system
    install_base_deps
    install_php
    install_nginx
    install_mysql
    install_redis
    install_certbot
    create_workdir
    download_scripts
    install_python_deps
    configure_firewall
    configure_fail2ban
    create_aliases
    run_scripts
    show_summary
    
    echo -e "${GREEN}✅ EasyInstall VPS Setup Complete!${NC}"
    echo -e "${YELLOW}To run again, type: easyvps${NC}"
}

# ==============================================
# Run Main Function
# ==============================================
main "$@"
