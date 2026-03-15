#!/bin/bash

# ==============================================
# EasyInstall VPS - Master Installation Script
# Version: 7.0
# Description: Complete VPS Setup with WordPress,
#              LEMP Stack, Python Tools & Optimizations
# Author: sugan0927
# GitHub: https://github.com/sugan0927/easyinstallvps
# ==============================================

set -e  # Exit on error

# ==============================================
# Configuration
# ==============================================
GITHUB_RAW="https://raw.githubusercontent.com/sugan0927/easyinstallvps/main"
GITHUB_API="https://api.github.com/repos/sugan0927/easyinstallvps/contents"
WORK_DIR="/opt/easyinstallvps"
GITHUB_TOKEN="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"  # Your GitHub token

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
# Check GitHub Token
# ==============================================
check_github_token() {
    print_section "Checking GitHub Token"
    
    if [ -z "$GITHUB_TOKEN" ]; then
        print_warning "GitHub token not set"
        print_info "Using public access (may have rate limits)"
    else
        # Test token
        TEST_URL="https://api.github.com/repos/sugan0927/easyinstallvps"
        RESPONSE=$(curl -s -H "Authorization: token $GITHUB_TOKEN" "$TEST_URL")
        if echo "$RESPONSE" | grep -q "Not Found"; then
            print_warning "GitHub token invalid or expired"
        else
            print_success "GitHub token valid"
        fi
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
    
    apt-get install -y curl wget git unzip zip tar gzip python3 python3-pip python3-venv software-properties-common apt-transport-https ca-certificates gnupg lsb-release ufw fail2ban htop neofetch tree vim nano jq
    
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
    
    apt-get install -y php php-cli php-fpm php-mysql php-pgsql php-sqlite3 php-curl php-gd php-mbstring php-xml php-xmlrpc php-zip php-bcmath php-json php-tokenizer php-soap php-intl php-imagick php-redis php-memcached php-opcache php-readline
    
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
    
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"
    
    print_success "Working directory: $WORK_DIR"
}

# ==============================================
# Get List of Scripts from GitHub
# ==============================================
get_github_scripts() {
    print_section "Fetching Scripts from GitHub"
    
    # Create headers for GitHub API
    if [ -n "$GITHUB_TOKEN" ]; then
        HEADER="Authorization: token $GITHUB_TOKEN"
    else
        HEADER=""
    fi
    
    # Fetch repository contents
    print_info "Fetching file list from GitHub..."
    
    # Use GitHub API to get all files
    if [ -n "$HEADER" ]; then
        FILES_JSON=$(curl -s -H "$HEADER" "$GITHUB_API")
    else
        FILES_JSON=$(curl -s "$GITHUB_API")
    fi
    
    # Check if API call was successful
    if echo "$FILES_JSON" | grep -q "API rate limit exceeded"; then
        print_warning "GitHub API rate limit exceeded"
        print_info "Using default file list instead"
        # Return default file list
        echo "easyinstall_core.py easyinstall_wp.php easyinstall.sh easyinstall_backup.sh easyinstall_optimize.sh easyinstall_security.sh install.sh README.md LICENSE"
        return
    fi
    
    if echo "$FILES_JSON" | grep -q "Not Found"; then
        print_error "Repository not found or private"
        exit 1
    fi
    
    # Parse JSON to get file names (only scripts and configs)
    SCRIPTS=$(echo "$FILES_JSON" | jq -r '.[] | select(.type == "file") | .name' | grep -E '\.(sh|php|py|conf|md|txt)$' | tr '\n' ' ')
    
    if [ -z "$SCRIPTS" ]; then
        print_warning "No scripts found on GitHub"
        print_info "Using default file list"
        echo "easyinstall_core.py easyinstall_wp.php easyinstall.sh easyinstall_backup.sh easyinstall_optimize.sh easyinstall_security.sh install.sh README.md LICENSE"
    else
        print_success "Found $(echo $SCRIPTS | wc -w) files on GitHub"
        echo "$SCRIPTS"
    fi
}

# ==============================================
# Download Script from GitHub
# ==============================================
download_script() {
    local script=$1
    
    echo -ne "Downloading ${YELLOW}$script${NC}... "
    
    # Create headers for download
    if [ -n "$GITHUB_TOKEN" ]; then
        HEADER="Authorization: token $GITHUB_TOKEN"
    else
        HEADER=""
    fi
    
    # Try to download from GitHub
    if [ -n "$HEADER" ]; then
        curl -s -H "$HEADER" -L "$GITHUB_RAW/$script" -o "$script"
    else
        curl -s -L "$GITHUB_RAW/$script" -o "$script"
    fi
    
    # Check if download was successful
    if [ -f "$script" ] && [ -s "$script" ]; then
        # Make executable if it's a script
        if [[ "$script" == *.sh ]] || [[ "$script" == *.py ]] || [[ "$script" == *.php ]]; then
            chmod +x "$script"
        fi
        echo -e "${GREEN}OK${NC}"
        return 0
    else
        echo -e "${RED}FAILED${NC}"
        rm -f "$script"
        return 1
    fi
}

# ==============================================
# Download All Scripts from GitHub
# ==============================================
download_all_scripts() {
    print_section "Downloading Scripts from GitHub"
    
    # Get list of scripts
    SCRIPTS=$(get_github_scripts)
    
    if [ -z "$SCRIPTS" ]; then
        print_error "No scripts found to download"
        return 1
    fi
    
    # Download each script
    SUCCESS_COUNT=0
    FAIL_COUNT=0
    
    for script in $SCRIPTS; do
        if download_script "$script"; then
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    done
    
    print_success "Downloaded $SUCCESS_COUNT files successfully"
    if [ $FAIL_COUNT -gt 0 ]; then
        print_warning "$FAIL_COUNT files failed to download"
    fi
    
    # List downloaded files
    echo ""
    print_info "Downloaded files:"
    ls -la | grep -E "\.(sh|php|py|conf|md|txt)$" | while read line; do
        perms=$(echo "$line" | awk '{print $1}')
        size=$(echo "$line" | awk '{print $5}')
        name=$(echo "$line" | awk '{print $9}')
        
        if [[ "$name" == *.sh ]] || [[ "$name" == *.py ]] || [[ "$name" == *.php ]]; then
            echo -e "  ${GREEN}✓${NC} $name ($(numfmt --to=iec $size))"
        else
            echo -e "  ${YELLOW}📄${NC} $name ($(numfmt --to=iec $size))"
        fi
    done
}

# ==============================================
# Check for Script Updates
# ==============================================
check_updates() {
    print_section "Checking for Script Updates"
    
    if [ ! -d "$WORK_DIR" ]; then
        print_info "No existing installation found"
        return
    fi
    
    cd "$WORK_DIR"
    
    # Get list of remote scripts
    REMOTE_SCRIPTS=$(get_github_scripts)
    
    UPDATES_AVAILABLE=0
    
    for script in $REMOTE_SCRIPTS; do
        if [ -f "$script" ]; then
            # Compare file sizes (simple check)
            LOCAL_SIZE=$(stat -c%s "$script" 2>/dev/null || stat -f%z "$script" 2>/dev/null)
            
            # Get remote file info
            if [ -n "$GITHUB_TOKEN" ]; then
                REMOTE_INFO=$(curl -s -H "Authorization: token $GITHUB_TOKEN" "https://api.github.com/repos/sugan0927/easyinstallvps/contents/$script")
            else
                REMOTE_INFO=$(curl -s "https://api.github.com/repos/sugan0927/easyinstallvps/contents/$script")
            fi
            
            REMOTE_SIZE=$(echo "$REMOTE_INFO" | jq -r '.size')
            
            if [ "$REMOTE_SIZE" != "null" ] && [ "$LOCAL_SIZE" != "$REMOTE_SIZE" ]; then
                echo -e "  ${YELLOW}⚠️ Update available: $script${NC}"
                UPDATES_AVAILABLE=$((UPDATES_AVAILABLE + 1))
            fi
        fi
    done
    
    if [ $UPDATES_AVAILABLE -eq 0 ]; then
        print_success "All scripts are up to date"
    else
        print_warning "$UPDATES_AVAILABLE updates available"
        echo ""
        echo -n "Download updates? (y/n): "
        read update_choice
        if [[ "$update_choice" == "y" ]]; then
            download_all_scripts
        fi
    fi
}

# ==============================================
# Install Python Dependencies
# ==============================================
install_python_deps() {
    print_section "Installing Python Dependencies"
    
    pip3 install --upgrade pip
    pip3 install requests colorama psutil jq
        
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
alias easyupdate='cd /opt/easyinstallvps && bash install.sh --update'
alias easylist='ls -la /opt/easyinstallvps/'
alias easywp='php /opt/easyinstallvps/easyinstall_wp.php'
alias easypy='python3 /opt/easyinstallvps/easyinstall_core.py'
alias easybackup='bash /opt/easyinstallvps/easyinstall_backup.sh'
alias easyopt='bash /opt/easyinstallvps/easyinstall_optimize.sh'
alias easysec='bash /opt/easyinstallvps/easyinstall_security.sh'
alias easylogs='tail -f /var/log/nginx/access.log'
EOF
    
    source ~/.bashrc 2>/dev/null || true
    print_success "Aliases created"
}

# ==============================================
# Run Selected Scripts
# ==============================================
run_scripts() {
    print_section "Running Installation Scripts"
    
    cd "$WORK_DIR"
    
    # Show available scripts
    echo -e "${YELLOW}Available scripts in $WORK_DIR:${NC}"
    
    SCRIPTS=($(ls -1 *.sh *.php *.py 2>/dev/null | grep -v "install.sh"))
    
    if [ ${#SCRIPTS[@]} -eq 0 ]; then
        print_warning "No scripts found to run"
        return
    fi
    
    for i in "${!SCRIPTS[@]}"; do
        echo "  $((i+1)). ${SCRIPTS[$i]}"
    done
    echo "  $(( ${#SCRIPTS[@]}+1 )). Run all scripts"
    echo "  $(( ${#SCRIPTS[@]}+2 )). Skip"
    echo ""
    echo -n "Select scripts to run [1-$(( ${#SCRIPTS[@]}+2 ))]: "
    read choice
    
    if [ "$choice" -eq $(( ${#SCRIPTS[@]}+2 )) ]; then
        print_info "Skipping script execution"
        return
    fi
    
    if [ "$choice" -eq $(( ${#SCRIPTS[@]}+1 )) ]; then
        # Run all scripts
        for script in "${SCRIPTS[@]}"; do
            print_info "Running $script..."
            if [[ "$script" == *.py ]]; then
                python3 "$script"
            elif [[ "$script" == *.php ]]; then
                php "$script"
            else
                bash "$script"
            fi
            echo ""
        done
    else
        # Run selected script
        index=$((choice-1))
        if [ $index -ge 0 ] && [ $index -lt ${#SCRIPTS[@]} ]; then
            script="${SCRIPTS[$index]}"
            print_info "Running $script..."
            if [[ "$script" == *.py ]]; then
                python3 "$script"
            elif [[ "$script" == *.php ]]; then
                php "$script"
            else
                bash "$script"
            fi
        else
            print_error "Invalid choice"
        fi
    fi
    
    print_success "Selected scripts executed"
}

# ==============================================
# Show Summary
# ==============================================
show_summary() {
    print_section "Installation Summary"
    
    IP_ADDR=$(curl -s ifconfig.me 2>/dev/null || echo "unknown")
    
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
    echo -e "  • Path: ${YELLOW}$WORK_DIR${NC}"
    echo -e "  • Total Scripts: ${GREEN}$(ls -1 $WORK_DIR/*.{sh,php,py} 2>/dev/null | wc -l)${NC}"
    echo ""
    
    echo -e "${CYAN}⚡ Available Commands:${NC}"
    echo -e "  • ${GREEN}easyvps${NC}     - Run main installer"
    echo -e "  • ${GREEN}easyupdate${NC}  - Check and download updates"
    echo -e "  • ${GREEN}easylist${NC}    - List all scripts"
    echo -e "  • ${GREEN}easywp${NC}      - Run WordPress installer"
    echo -e "  • ${GREEN}easypy${NC}      - Run Python tools"
    echo -e "  • ${GREEN}easybackup${NC}  - Create backup"
    echo -e "  • ${GREEN}easyopt${NC}     - Optimize system"
    echo -e "  • ${GREEN}easysec${NC}     - Security hardening"
    echo -e "  • ${GREEN}easylogs${NC}    - View Nginx logs"
    echo ""
    
    echo -e "${CYAN}📦 GitHub Integration:${NC}"
    echo -e "  • Repository: ${YELLOW}https://github.com/sugan0927/easyinstallvps${NC}"
    echo -e "  • Auto-updates: ${GREEN}Enabled${NC}"
    echo -e "  • To add new features: Just push to GitHub and run ${GREEN}easyupdate${NC}"
    echo ""
    
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}              🚀 SYSTEM READY FOR PRODUCTION!                ${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# ==============================================
# Show Help
# ==============================================
show_help() {
    echo "EasyInstall VPS - Master Installation Script"
    echo ""
    echo "Usage: ./install.sh [OPTION]"
    echo ""
    echo "Options:"
    echo "  --help        Show this help message"
    echo "  --update      Check for updates and download new scripts"
    echo "  --list        List all available scripts"
    echo "  --download    Download all scripts from GitHub"
    echo "  --run         Run scripts after installation"
    echo "  --no-run      Skip running scripts"
    echo ""
    echo "Examples:"
    echo "  ./install.sh              Full installation"
    echo "  ./install.sh --update     Update only"
    echo "  ./install.sh --list       List scripts"
}

# ==============================================
# Main Function
# ==============================================
main() {
    # Parse command line arguments
    UPDATE_ONLY=false
    LIST_ONLY=false
    DOWNLOAD_ONLY=false
    RUN_SCRIPTS=true
    
    for arg in "$@"; do
        case $arg in
            --help)
                show_help
                exit 0
                ;;
            --update)
                UPDATE_ONLY=true
                ;;
            --list)
                LIST_ONLY=true
                ;;
            --download)
                DOWNLOAD_ONLY=true
                ;;
            --no-run)
                RUN_SCRIPTS=false
                ;;
        esac
    done
    
    if [ "$LIST_ONLY" = true ]; then
        print_banner
        check_github_token
        create_workdir
        cd "$WORK_DIR"
        SCRIPTS=$(ls -1 *.sh *.php *.py 2>/dev/null | grep -v "install.sh")
        echo -e "${YELLOW}Available scripts in $WORK_DIR:${NC}"
        for script in $SCRIPTS; do
            echo "  • $script"
        done
        exit 0
    fi
    
    if [ "$UPDATE_ONLY" = true ]; then
        print_banner
        check_github_token
        create_workdir
        check_updates
        exit 0
    fi
    
    if [ "$DOWNLOAD_ONLY" = true ]; then
        print_banner
        check_github_token
        create_workdir
        download_all_scripts
        exit 0
    fi
    
    # Full installation
    print_banner
    check_root
    detect_os
    check_disk_space
    check_internet
    check_github_token
    block_apache
    update_system
    install_base_deps
    install_php
    install_nginx
    install_mysql
    install_redis
    install_certbot
    create_workdir
    download_all_scripts
    install_python_deps
    configure_firewall
    configure_fail2ban
    create_aliases
    
    if [ "$RUN_SCRIPTS" = true ]; then
        run_scripts
    fi
    
    show_summary
    
    echo -e "${GREEN}✅ EasyInstall VPS Setup Complete!${NC}"
    echo -e "${YELLOW}To check for updates later, run: easyupdate${NC}"
    echo -e "${YELLOW}To run again, type: easyvps${NC}"
    echo -e "${YELLOW}Or navigate to: cd $WORK_DIR${NC}"
}

# ==============================================
# Run Main Function
# ==============================================
main "$@"
