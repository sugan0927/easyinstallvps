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
    
    apt-get install -y curl wget git unzip zip tar gzip python3 python3-pip python3-venv software-properties-common apt-transport-https ca-certificates gnupg lsb-release ufw fail2ban htop neofetch tree vim nano
    
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
    
    WORK_DIR="/opt/easyinstallvps"
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"
    
    print_success "Working directory: $WORK_DIR"
}

# ==============================================
# Create Embedded Scripts
# ==============================================
create_embedded_scripts() {
    print_section "Creating Embedded Scripts"
    
    # -------------------------------------------------
    # 1. easyinstall_core.py - Python Core Module
    # -------------------------------------------------
    print_info "Creating easyinstall_core.py..."
    cat > easyinstall_core.py << 'EOF_PYTHON'
#!/usr/bin/env python3
"""
EasyInstall Python Core Module
Version: 7.0
Author: sugan0927
Description: Core Python functions for VPS management
"""

import os
import sys
import subprocess
import platform
import json
import time
import socket
from datetime import datetime

# Colors for terminal output
class Colors:
    HEADER = '\033[95m'
    BLUE = '\033[94m'
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    RED = '\033[91m'
    END = '\033[0m'
    BOLD = '\033[1m'

def print_banner():
    """Print banner"""
    print(f"{Colors.BLUE}========================================{Colors.END}")
    print(f"{Colors.GREEN}  EasyInstall Python Core v7.0{Colors.END}")
    print(f"{Colors.BLUE}========================================{Colors.END}")
    print()

def print_success(msg):
    print(f"{Colors.GREEN}✅ {msg}{Colors.END}")

def print_info(msg):
    print(f"{Colors.YELLOW}ℹ️ {msg}{Colors.END}")

def print_error(msg):
    print(f"{Colors.RED}❌ {msg}{Colors.END}")

def run_command(cmd, shell=True):
    """Run shell command and return output"""
    try:
        result = subprocess.run(cmd, shell=shell, capture_output=True, text=True)
        return result.stdout.strip(), result.stderr.strip(), result.returncode
    except Exception as e:
        return "", str(e), 1

def get_system_info():
    """Get system information"""
    info = {
        "hostname": socket.gethostname(),
        "os": platform.system(),
        "os_release": platform.release(),
        "python_version": platform.python_version(),
        "cpu_count": os.cpu_count(),
        "timestamp": datetime.now().isoformat()
    }
    
    # Get load average
    try:
        info["load_avg"] = os.getloadavg()
    except:
        info["load_avg"] = [0, 0, 0]
    
    # Get memory info
    try:
        with open('/proc/meminfo', 'r') as f:
            meminfo = f.read()
        
        for line in meminfo.split('\n'):
            if 'MemTotal' in line:
                info["memory_total"] = int(line.split()[1]) // 1024
            if 'MemFree' in line:
                info["memory_free"] = int(line.split()[1]) // 1024
    except:
        info["memory_total"] = 0
        info["memory_free"] = 0
    
    return info

def check_services():
    """Check if required services are running"""
    services = ['nginx', 'mysql', 'php8.2-fpm']
    status = {}
    
    for service in services:
        out, err, code = run_command(f"systemctl is-active {service}")
        status[service] = code == 0
    
    return status

def optimize_system():
    """System optimization tasks"""
    print_info("Optimizing system...")
    
    # Optimize swappiness
    run_command("echo 'vm.swappiness=10' >> /etc/sysctl.conf")
    
    # Optimize file limits
    run_command("echo 'fs.file-max=65535' >> /etc/sysctl.conf")
    
    # Apply sysctl changes
    run_command("sysctl -p")
    
    print_success("System optimization completed")

def setup_wordpress_db(db_name, db_user, db_pass):
    """Setup WordPress database"""
    print_info(f"Creating WordPress database: {db_name}")
    
    # Get MySQL root password
    try:
        with open('/root/.mysql_info', 'r') as f:
            content = f.read()
            for line in content.split('\n'):
                if 'MySQL Root Password:' in line:
                    root_pass = line.split(': ')[1]
                    break
    except:
        print_error("Could not read MySQL root password")
        return False
    
    # Create database and user
    commands = [
        f'mysql -u root -p"{root_pass}" -e "CREATE DATABASE IF NOT EXISTS {db_name};"',
        f'mysql -u root -p"{root_pass}" -e "CREATE USER IF NOT EXISTS \'{db_user}\'@\'localhost\' IDENTIFIED BY \'{db_pass}\';"',
        f'mysql -u root -p"{root_pass}" -e "GRANT ALL PRIVILEGES ON {db_name}.* TO \'{db_user}\'@\'localhost\';"',
        f'mysql -u root -p"{root_pass}" -e "FLUSH PRIVILEGES;"'
    ]
    
    for cmd in commands:
        out, err, code = run_command(cmd)
        if code != 0:
            print_error(f"Failed: {err}")
            return False
    
    print_success("WordPress database created")
    return True

def main():
    """Main function"""
    print_banner()
    
    # Get system info
    info = get_system_info()
    print_info(f"System: {info['os']} {info['os_release']}")
    print_info(f"Python: {info['python_version']}")
    print_info(f"CPU Cores: {info['cpu_count']}")
    print_info(f"Memory: {info.get('memory_total', 0)} MB total, {info.get('memory_free', 0)} MB free")
    print()
    
    # Check services
    print_info("Checking services...")
    services = check_services()
    for service, active in services.items():
        if active:
            print_success(f"{service} is running")
        else:
            print_error(f"{service} is not running")
    print()
    
    # Optimize system
    response = input(f"{Colors.YELLOW}Optimize system? (y/n): {Colors.END}")
    if response.lower() == 'y':
        optimize_system()
    
    # Setup WordPress DB
    response = input(f"{Colors.YELLOW}Setup WordPress database? (y/n): {Colors.END}")
    if response.lower() == 'y':
        db_name = input("Database name [wordpress]: ") or "wordpress"
        db_user = input("Database user [wpuser]: ") or "wpuser"
        db_pass = input("Database password [random]: ") or os.urandom(12).hex()
        setup_wordpress_db(db_name, db_user, db_pass)
    
    print_success("Python core tasks completed")
    return 0

if __name__ == "__main__":
    sys.exit(main())
EOF_PYTHON
    chmod +x easyinstall_core.py
    print_success "easyinstall_core.py created"
    
    # -------------------------------------------------
    # 2. easyinstall_wp.php - WordPress Installer
    # -------------------------------------------------
    print_info "Creating easyinstall_wp.php..."
    cat > easyinstall_wp.php << 'EOF_PHP'
<?php
/**
 * EasyInstall WordPress Installer
 * Version: 7.0
 * Author: sugan0927
 * Description: Automated WordPress installation with LEMP stack
 */

// Colors for CLI output
class Colors {
    const RED = "\033[0;31m";
    const GREEN = "\033[0;32m";
    const YELLOW = "\033[1;33m";
    const BLUE = "\033[0;34m";
    const CYAN = "\033[0;36m";
    const NC = "\033[0m"; // No Color
}

function println($message, $color = null) {
    if ($color && php_sapi_name() === 'cli') {
        echo $color . $message . Colors::NC . PHP_EOL;
    } else {
        echo $message . PHP_EOL;
    }
}

function print_section($title) {
    println("");
    println(str_repeat("━", 60), Colors::CYAN);
    println("► " . $title, Colors::GREEN);
    println(str_repeat("━", 60), Colors::CYAN);
    println("");
}

function print_success($msg) {
    println("✅ " . $msg, Colors::GREEN);
}

function print_info($msg) {
    println("ℹ️ " . $msg, Colors::YELLOW);
}

function print_error($msg) {
    println("❌ " . $msg, Colors::RED);
}

function run_command($cmd) {
    $output = [];
    $return_var = 0;
    exec($cmd . " 2>&1", $output, $return_var);
    return [
        'output' => implode("\n", $output),
        'code' => $return_var
    ];
}

function get_system_info() {
    $info = [
        'os' => PHP_OS,
        'php_version' => PHP_VERSION,
        'hostname' => gethostname(),
        'ip' => trim(file_get_contents('https://ifconfig.me') ?: 'unknown'),
        'memory' => [
            'total' => 0,
            'free' => 0
        ]
    ];
    
    // Get memory info on Linux
    if (PHP_OS === 'Linux') {
        $meminfo = file_get_contents('/proc/meminfo');
        if ($meminfo) {
            if (preg_match('/MemTotal:\s+(\d+)/', $meminfo, $matches)) {
                $info['memory']['total'] = round($matches[1] / 1024 / 1024, 2);
            }
            if (preg_match('/MemFree:\s+(\d+)/', $meminfo, $matches)) {
                $info['memory']['free'] = round($matches[1] / 1024 / 1024, 2);
            }
        }
    }
    
    return $info;
}

function check_services() {
    $services = ['nginx', 'mysql', 'php8.2-fpm'];
    $status = [];
    
    foreach ($services as $service) {
        $result = run_command("systemctl is-active $service");
        $status[$service] = $result['code'] === 0;
    }
    
    return $status;
}

function install_wordpress() {
    print_section("WordPress Installation");
    
    $wp_dir = "/var/www/html";
    
    // Create web directory
    if (!is_dir($wp_dir)) {
        mkdir($wp_dir, 0755, true);
    }
    
    chdir($wp_dir);
    
    // Download WordPress
    print_info("Downloading WordPress...");
    
    // Try wp-cli first, fallback to curl
    $result = run_command("wp core download --locale=en_US --allow-root");
    if ($result['code'] !== 0) {
        // Fallback to curl if wp-cli not available
        run_command("curl -O https://wordpress.org/latest.tar.gz");
        run_command("tar -xzf latest.tar.gz --strip-components=1");
        run_command("rm latest.tar.gz");
    }
    
    // Create wp-config
    print_info("Creating wp-config.php...");
    $db_name = "wordpress";
    $db_user = "wpuser";
    $db_pass = bin2hex(random_bytes(12));
    
    $config = "<?php
define('DB_NAME', '$db_name');
define('DB_USER', '$db_user');
define('DB_PASSWORD', '$db_pass');
define('DB_HOST', 'localhost');
define('DB_CHARSET', 'utf8');
define('DB_COLLATE', '');

define('AUTH_KEY',         '" . bin2hex(random_bytes(32)) . "');
define('SECURE_AUTH_KEY',  '" . bin2hex(random_bytes(32)) . "');
define('LOGGED_IN_KEY',    '" . bin2hex(random_bytes(32)) . "');
define('NONCE_KEY',        '" . bin2hex(random_bytes(32)) . "');
define('AUTH_SALT',        '" . bin2hex(random_bytes(32)) . "');
define('SECURE_AUTH_SALT', '" . bin2hex(random_bytes(32)) . "');
define('LOGGED_IN_SALT',   '" . bin2hex(random_bytes(32)) . "');
define('NONCE_SALT',       '" . bin2hex(random_bytes(32)) . "');

\$table_prefix = 'wp_';

define('WP_DEBUG', false);

if ( ! defined('ABSPATH') ) {
    define('ABSPATH', __DIR__ . '/');
}

require_once ABSPATH . 'wp-settings.php';
";
    
    file_put_contents($wp_dir . "/wp-config.php", $config);
    
    // Set permissions
    run_command("chown -R www-data:www-data $wp_dir");
    run_command("find $wp_dir -type d -exec chmod 755 {} \\;");
    run_command("find $wp_dir -type f -exec chmod 644 {} \\;");
    
    print_success("WordPress installed at $wp_dir");
    
    // Save credentials
    $creds = "/root/.wp_credentials";
    file_put_contents($creds, 
        "WordPress Installation: $wp_dir\n" .
        "Database Name: $db_name\n" .
        "Database User: $db_user\n" .
        "Database Password: $db_pass\n" .
        "Site URL: http://" . gethostbyname(gethostname()) . "\n" .
        "Date: " . date('Y-m-d H:i:s') . "\n"
    );
    chmod($creds, 600);
    
    print_success("WordPress credentials saved in $creds");
}

function configure_nginx() {
    print_section("Configuring Nginx");
    
    $config = "/etc/nginx/sites-available/wordpress";
    $content = 'server {
    listen 80;
    listen [::]:80;
    
    root /var/www/html;
    index index.php index.html index.htm;
    
    server_name _;
    
    client_max_body_size 100M;
    
    location / {
        try_files $uri $uri/ /index.php?$args;
    }
    
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.2-fpm.sock;
    }
    
    location ~ /\.ht {
        deny all;
    }
    
    # Cache static files
    location ~* \.(jpg|jpeg|png|gif|ico|css|js)$ {
        expires 365d;
        add_header Cache-Control "public, immutable";
    }
    
    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
}
';
    
    file_put_contents($config, $content);
    
    // Enable site
    if (!is_link("/etc/nginx/sites-enabled/wordpress")) {
        symlink($config, "/etc/nginx/sites-enabled/wordpress");
    }
    
    // Remove default site
    if (is_file("/etc/nginx/sites-enabled/default")) {
        unlink("/etc/nginx/sites-enabled/default");
    }
    
    // Test and reload
    run_command("nginx -t");
    run_command("systemctl reload nginx");
    
    print_success("Nginx configured for WordPress");
}

function main() {
    print_section("EasyInstall WordPress Installer v7.0");
    
    // Check if running as root
    if (posix_getuid() !== 0) {
        print_error("This script must be run as root!");
        exit(1);
    }
    
    // Show system info
    $info = get_system_info();
    print_info("System: " . $info['os']);
    print_info("PHP: " . $info['php_version']);
    print_info("Hostname: " . $info['hostname']);
    print_info("IP Address: " . $info['ip']);
    print_info("Memory: " . $info['memory']['total'] . "GB total, " . $info['memory']['free'] . "GB free");
    print("");
    
    // Check services
    $services = check_services();
    foreach ($services as $service => $active) {
        if ($active) {
            print_success("$service is running");
        } else {
            print_error("$service is not running");
        }
    }
    print("");
    
    // Ask for confirmation
    print_info("This will install WordPress in /var/www/html");
    print_info("Existing files may be overwritten");
    echo "Continue? (y/n): ";
    $handle = fopen("php://stdin", "r");
    $response = trim(fgets($handle));
    
    if (strtolower($response) === 'y') {
        install_wordpress();
        configure_nginx();
        print_section("Installation Complete!");
        print_success("WordPress has been installed successfully!");
        print_info("Site URL: http://" . $info['ip']);
        print_info("Admin URL: http://" . $info['ip'] . "/wp-admin");
        print_info("Credentials saved in: /root/.wp_credentials");
    } else {
        print_info("Installation cancelled");
    }
}

main();
?>
EOF_PHP
    chmod +x easyinstall_wp.php
    print_success "easyinstall_wp.php created"
    
    # -------------------------------------------------
    # 3. easyinstall.sh - Shell Script
    # -------------------------------------------------
    print_info "Creating easyinstall.sh..."
    cat > easyinstall.sh << 'EOF_SHELL'
#!/bin/bash

# EasyInstall Shell Script
# Version: 7.0
# Author: sugan0927

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}  EasyInstall Shell Script v7.0${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Function to check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}This script must be run as root!${NC}"
        exit 1
    fi
}

# Function to display menu
show_menu() {
    echo -e "${YELLOW}Select an option:${NC}"
    echo "1. Install WordPress"
    echo "2. Configure Nginx"
    echo "3. Setup Database"
    echo "4. Optimize System"
    echo "5. Security Hardening"
    echo "6. Create Backup"
    echo "7. Show System Info"
    echo "8. Exit"
    echo ""
    echo -n "Choice [1-8]: "
}

# Function to show system info
show_system_info() {
    echo -e "${YELLOW}System Information:${NC}"
    echo "  OS: $(uname -a)"
    echo "  CPU: $(nproc) cores"
    echo "  Memory: $(free -h | grep Mem | awk '{print $2}') total"
    echo "  Disk: $(df -h / | awk 'NR==2 {print $2}') total, $(df -h / | awk 'NR==2 {print $4}') free"
    echo "  Load: $(uptime | awk -F'load average:' '{print $2}')"
    echo ""
}

# Function to install WordPress
install_wordpress() {
    echo -e "${YELLOW}Installing WordPress...${NC}"
    php /opt/easyinstallvps/easyinstall_wp.php
}

# Function to configure Nginx
configure_nginx() {
    echo -e "${YELLOW}Configuring Nginx...${NC}"
    
    # Test configuration
    nginx -t
    
    # Reload if test passes
    if [ $? -eq 0 ]; then
        systemctl reload nginx
        echo -e "${GREEN}Nginx reloaded${NC}"
    else
        echo -e "${RED}Nginx configuration test failed${NC}"
    fi
}

# Function to setup database
setup_database() {
    echo -e "${YELLOW}Setting up database...${NC}"
    
    # Check if mysql is running
    if systemctl is-active --quiet mysql; then
        echo -e "${GREEN}MySQL is running${NC}"
        
        # Show MySQL info
        if [ -f /root/.mysql_info ]; then
            cat /root/.mysql_info
        else
            echo -e "${RED}MySQL credentials not found${NC}"
        fi
    else
        echo -e "${RED}MySQL is not running${NC}"
    fi
}

# Function to optimize system
optimize_system() {
    echo -e "${YELLOW}Optimizing system...${NC}"
    
    # Optimize kernel parameters
    cat >> /etc/sysctl.conf << EOF
# EasyInstall Optimizations
net.core.somaxconn = 1024
net.ipv4.tcp_max_syn_backlog = 512
net.ipv4.tcp_fin_timeout = 30
vm.swappiness = 10
EOF
    
    sysctl -p
    
    # Optimize limits
    cat >> /etc/security/limits.conf << EOF
* soft nofile 65535
* hard nofile 65535
root soft nofile 65535
root hard nofile 65535
EOF
    
    echo -e "${GREEN}System optimized${NC}"
}

# Function for security hardening
security_hardening() {
    echo -e "${YELLOW}Security hardening...${NC}"
    
    # Configure UFW
    ufw allow 22/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw --force enable
    
    # Configure fail2ban
    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true

[nginx-http-auth]
enabled = true

[nginx-botsearch]
enabled = true
EOF
    
    systemctl restart fail2ban
    
    # Secure shared memory
    echo "tmpfs /run/shm tmpfs defaults,noexec,nosuid 0 0" >> /etc/fstab
    
    echo -e "${GREEN}Security hardening completed${NC}"
}

# Function to create backup
create_backup() {
    echo -e "${YELLOW}Creating backup...${NC}"
    
    BACKUP_DIR="/root/backups"
    DATE=$(date +%Y%m%d_%H%M%S)
    BACKUP_FILE="$BACKUP_DIR/backup_$DATE.tar.gz"
    
    mkdir -p "$BACKUP_DIR"
    
    # Backup important directories
    tar -czf "$BACKUP_FILE" \
        /var/www/html \
        /etc/nginx \
        /etc/php/*/fpm/pool.d \
        /etc/mysql \
        2>/dev/null || true
    
    # Backup MySQL databases
    if [ -f /root/.mysql_info ]; then
        mysqldump --all-databases > "$BACKUP_DIR/mysql_$DATE.sql" 2>/dev/null || true
    fi
    
    echo -e "${GREEN}Backup created: $BACKUP_FILE${NC}"
    ls -lh "$BACKUP_FILE"
}

# Main script
main() {
    check_root
    
    while true; do
        echo ""
        show_menu
        read choice
        
        case $choice in
            1)
                install_wordpress
                ;;
            2)
                configure_nginx
                ;;
            3)
                setup_database
                ;;
            4)
                optimize_system
                ;;
            5)
                security_hardening
                ;;
            6)
                create_backup
                ;;
            7)
                show_system_info
                ;;
            8)
                echo -e "${GREEN}Exiting...${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option${NC}"
                ;;
        esac
        
        echo ""
        echo -n "Press Enter to continue..."
        read
    done
}

# Run main function
main
EOF_SHELL
    chmod +x easyinstall.sh
    print_success "easyinstall.sh created"
    
    # -------------------------------------------------
    # 4. easyinstall_backup.sh - Backup Script
    # -------------------------------------------------
    print_info "Creating easyinstall_backup.sh..."
    cat > easyinstall_backup.sh << 'EOF_BACKUP'
#!/bin/bash

# EasyInstall Backup Script
# Version: 1.0

BACKUP_DIR="/root/backups"
DATE=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$BACKUP_DIR/backup_$DATE.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

mkdir -p "$BACKUP_DIR"

echo "========================================" | tee -a "$LOG_FILE"
echo "EasyInstall Backup - $DATE" | tee -a "$LOG_FILE"
echo "========================================" | tee -a "$LOG_FILE"
echo ""

# Backup websites
echo -e "${YELLOW}Backing up websites...${NC}" | tee -a "$LOG_FILE"
if [ -d "/var/www/html" ]; then
    tar -czf "$BACKUP_DIR/www_$DATE.tar.gz" /var/www/html 2>/dev/null
    echo "✅ Websites backed up" | tee -a "$LOG_FILE"
else
    echo "⚠️ No websites found" | tee -a "$LOG_FILE"
fi
echo "" | tee -a "$LOG_FILE"

# Backup Nginx config
echo -e "${YELLOW}Backing up Nginx configuration...${NC}" | tee -a "$LOG_FILE"
if [ -d "/etc/nginx" ]; then
    tar -czf "$BACKUP_DIR/nginx_$DATE.tar.gz" /etc/nginx 2>/dev/null
    echo "✅ Nginx config backed up" | tee -a "$LOG_FILE"
else
    echo "⚠️ Nginx not found" | tee -a "$LOG_FILE"
fi
echo "" | tee -a "$LOG_FILE"

# Backup PHP config
echo -e "${YELLOW}Backing up PHP configuration...${NC}" | tee -a "$LOG_FILE"
if [ -d "/etc/php" ]; then
    tar -czf "$BACKUP_DIR/php_$DATE.tar.gz" /etc/php 2>/dev/null
    echo "✅ PHP config backed up" | tee -a "$LOG_FILE"
else
    echo "⚠️ PHP not found" | tee -a "$LOG_FILE"
fi
echo "" | tee -a "$LOG_FILE"

# Backup MySQL databases
echo -e "${YELLOW}Backing up MySQL databases...${NC}" | tee -a "$LOG_FILE"
if command -v mysql >/dev/null 2>&1; then
    if [ -f /root/.mysql_info ]; then
        MYSQL_PASS=$(grep "MySQL Root Password:" /root/.mysql_info | cut -d':' -f2 | xargs)
        mysqldump -u root -p"$MYSQL_PASS" --all-databases > "$BACKUP_DIR/mysql_$DATE.sql" 2>/dev/null
        echo "✅ MySQL databases backed up" | tee -a "$LOG_FILE"
    else
        echo "⚠️ MySQL credentials not found" | tee -a "$LOG_FILE"
    fi
else
    echo "⚠️ MySQL not installed" | tee -a "$LOG_FILE"
fi
echo "" | tee -a "$LOG_FILE"

# Show backup size
echo -e "${GREEN}Backup completed!${NC}" | tee -a "$LOG_FILE"
echo "Backup directory: $BACKUP_DIR" | tee -a "$LOG_FILE"
echo "Backup size: $(du -sh $BACKUP_DIR | cut -f1)" | tee -a "$LOG_FILE"
echo "Log file: $LOG_FILE" | tee -a "$LOG_FILE"

# Clean old backups (keep last 7 days)
find "$BACKUP_DIR" -name "*.tar.gz" -mtime +7 -delete 2>/dev/null
find "$BACKUP_DIR" -name "*.sql" -mtime +7 -delete 2>/dev/null
find "$BACKUP_DIR" -name "*.log" -mtime +7 -delete 2>/dev/null
EOF_BACKUP
    chmod +x easyinstall_backup.sh
    print_success "easyinstall_backup.sh created"
    
    # -------------------------------------------------
    # 5. easyinstall_optimize.sh - Optimization Script
    # -------------------------------------------------
    print_info "Creating easyinstall_optimize.sh..."
    cat > easyinstall_optimize.sh << 'EOF_OPTIMIZE'
#!/bin/bash

# EasyInstall Optimization Script
# Version: 1.0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}  EasyInstall System Optimizer${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Function to optimize kernel parameters
optimize_kernel() {
    echo -e "${YELLOW}Optimizing kernel parameters...${NC}"
    
    cat >> /etc/sysctl.conf << EOF

# EasyInstall Optimizations
net.core.somaxconn = 1024
net.core.netdev_max_backlog = 5000
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_max_syn_backlog = 512
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_slow_start_after_idle = 0
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF
    
    sysctl -p
    echo -e "${GREEN}✓ Kernel parameters optimized${NC}"
}

# Function to optimize limits
optimize_limits() {
    echo -e "${YELLOW}Optimizing system limits...${NC}"
    
    cat >> /etc/security/limits.conf << EOF

# EasyInstall Limits
* soft nofile 65535
* hard nofile 65535
* soft nproc 65535
* hard nproc 65535
root soft nofile 65535
root hard nofile 65535
root soft nproc 65535
root hard nproc 65535
EOF
    
    echo -e "${GREEN}✓ System limits optimized${NC}"
}

# Function to optimize Nginx
optimize_nginx() {
    echo -e "${YELLOW}Optimizing Nginx...${NC}"
    
    if [ -f /etc/nginx/nginx.conf ]; then
        # Backup original
        cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.backup
        
        # Update worker processes
        sed -i "s/worker_processes.*/worker_processes auto;/" /etc/nginx/nginx.conf
        
        # Add optimizations if not present
        if ! grep -q "worker_rlimit_nofile" /etc/nginx/nginx.conf; then
            sed -i "/worker_processes/a worker_rlimit_nofile 65535;" /etc/nginx/nginx.conf
        fi
        
        # Update events block
        if ! grep -q "use epoll" /etc/nginx/nginx.conf; then
            sed -i "/events {/a \ \ \ use epoll;\n    multi_accept on;" /etc/nginx/nginx.conf
        fi
        
        # Test configuration
        nginx -t && systemctl reload nginx
        echo -e "${GREEN}✓ Nginx optimized${NC}"
    else
        echo -e "${RED}✗ Nginx not found${NC}"
    fi
}

# Function to optimize PHP
optimize_php() {
    echo -e "${YELLOW}Optimizing PHP...${NC}"
    
    # Find PHP ini files
    for ini in $(find /etc/php -name "php.ini" 2>/dev/null); do
        # Backup
        cp "$ini" "$ini.backup"
        
        # Update settings
        sed -i "s/memory_limit.*/memory_limit = 256M/" "$ini"
        sed -i "s/max_execution_time.*/max_execution_time = 300/" "$ini"
        sed -i "s/max_input_time.*/max_input_time = 300/" "$ini"
        sed -i "s/post_max_size.*/post_max_size = 100M/" "$ini"
        sed -i "s/upload_max_filesize.*/upload_max_filesize = 100M/" "$ini"
        sed -i "s/max_file_uploads.*/max_file_uploads = 20/" "$ini"
        sed -i "s/;date.timezone.*/date.timezone = UTC/" "$ini"
        
        # Opcache settings
        if ! grep -q "opcache.enable=1" "$ini"; then
            echo "
[opcache]
opcache.enable=1
opcache.memory_consumption=128
opcache.interned_strings_buffer=8
opcache.max_accelerated_files=4000
opcache.revalidate_freq=60
opcache.fast_shutdown=1
opcache.enable_cli=1
" >> "$ini"
        fi
    done
    
    # Restart PHP-FPM
    systemctl restart php*-fpm 2>/dev/null || true
    echo -e "${GREEN}✓ PHP optimized${NC}"
}

# Function to optimize MySQL
optimize_mysql() {
    echo -e "${YELLOW}Optimizing MySQL...${NC}"
    
    if [ -f /etc/mysql/my.cnf ]; then
        # Backup
        cp /etc/mysql/my.cnf /etc/mysql/my.cnf.backup
        
        # Add optimizations
        cat >> /etc/mysql/my.cnf << EOF

# EasyInstall MySQL Optimizations
[mysqld]
key_buffer_size = 256M
max_allowed_packet = 64M
table_open_cache = 256
sort_buffer_size = 4M
net_buffer_length = 8K
read_buffer_size = 2M
read_rnd_buffer_size = 8M
myisam_sort_buffer_size = 64M
thread_cache_size = 8
query_cache_size = 0
query_cache_type = 0
tmp_table_size = 64M
max_heap_table_size = 64M
max_connections = 500
wait_timeout = 600
interactive_timeout = 600
EOF
        
        systemctl restart mysql
        echo -e "${GREEN}✓ MySQL optimized${NC}"
    else
        echo -e "${RED}✗ MySQL not found${NC}"
    fi
}

# Function to clean system
clean_system() {
    echo -e "${YELLOW}Cleaning system...${NC}"
    
    # Clean package cache
    apt-get clean
    apt-get autoclean
    
    # Remove old kernels
    apt-get autoremove --purge -y
    
    # Clean logs
    journalctl --vacuum-time=7d
    
    # Clean temp files
    rm -rf /tmp/*
    rm -rf /var/tmp/*
    
    # Clean Nginx cache
    rm -rf /var/cache/nginx/* 2>/dev/null || true
    
    # Clean PHP session files
    find /var/lib/php/sessions -type f -mtime +7 -delete 2>/dev/null || true
    
    echo -e "${GREEN}✓ System cleaned${NC}"
}

# Main menu
main() {
    echo "Select optimization to run:"
    echo "1. Kernel Parameters"
    echo "2. System Limits"
    echo "3. Nginx Optimization"
    echo "4. PHP Optimization"
    echo "5. MySQL Optimization"
    echo "6. System Cleanup"
    echo "7. Run All"
    echo "8. Exit"
    echo ""
    echo -n "Choice [1-8]: "
    read choice
    
    case $choice in
        1) optimize_kernel ;;
        2) optimize_limits ;;
        3) optimize_nginx ;;
        4) optimize_php ;;
        5) optimize_mysql ;;
        6) clean_system ;;
        7)
            optimize_kernel
            optimize_limits
            optimize_nginx
            optimize_php
            optimize_mysql
            clean_system
            ;;
        8) exit 0 ;;
        *) echo -e "${RED}Invalid option${NC}" ;;
    esac
}

main
EOF_OPTIMIZE
    chmod +x easyinstall_optimize.sh
    print_success "easyinstall_optimize.sh created"
    
    # -------------------------------------------------
    # 6. easyinstall_security.sh - Security Script
    # -------------------------------------------------
    print_info "Creating easyinstall_security.sh..."
    cat > easyinstall_security.sh << 'EOF_SECURITY'
#!/bin/bash

# EasyInstall Security Hardening Script
# Version: 1.0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}  EasyInstall Security Hardening${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Function to configure firewall
configure_firewall() {
    echo -e "${YELLOW}Configuring firewall (UFW)...${NC}"
    
    # Reset UFW
    ufw --force reset
    
    # Default policies
    ufw default deny incoming
    ufw default allow outgoing
    
    # Allow essential services
    ufw allow 22/tcp comment 'SSH'
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'
    
    # Enable UFW
    ufw --force enable
    
    echo -e "${GREEN}✓ Firewall configured${NC}"
    ufw status verbose
}

# Function to configure fail2ban
configure_fail2ban() {
    echo -e "${YELLOW}Configuring fail2ban...${NC}"
    
    # Create local jail configuration
    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
ignoreip = 127.0.0.1/8 ::1
destemail = root@localhost
sender = fail2ban@localhost
action = %(action_mwl)s

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3

[nginx-http-auth]
enabled = true
filter = nginx-http-auth
port = http,https
logpath = /var/log/nginx/error.log

[nginx-botsearch]
enabled = true
filter = nginx-botsearch
port = http,https
logpath = /var/log/nginx/access.log
maxretry = 2

[php-url-fopen]
enabled = true
filter = php-url-fopen
port = http,https
logpath = /var/log/nginx/access.log

[wordpress]
enabled = true
filter = wordpress
port = http,https
logpath = /var/log/nginx/access.log
maxretry = 5
EOF
    
    # Create WordPress filter if not exists
    if [ ! -f /etc/fail2ban/filter.d/wordpress.conf ]; then
        cat > /etc/fail2ban/filter.d/wordpress.conf << 'EOFF'
[Definition]
failregex = ^<HOST> .* "POST .*wp-login\.php
            ^<HOST> .* "POST .*xmlrpc\.php
ignoreregex =
EOFF
    fi
    
    # Restart fail2ban
    systemctl restart fail2ban
    systemctl enable fail2ban
    
    echo -e "${GREEN}✓ fail2ban configured${NC}"
    fail2ban-client status
}

# Function to secure SSH
secure_ssh() {
    echo -e "${YELLOW}Securing SSH...${NC}"
    
    # Backup SSH config
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
    
    # Disable root login
    sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
    
    # Disable password authentication
    sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    
    # Use key-based authentication only
    sed -i 's/^#PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
    sed -i 's/^PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
    
    # Change SSH port (optional)
    # sed -i 's/^#Port 22/Port 2222/' /etc/ssh/sshd_config
    
    # Restrict users
    echo "AllowUsers $(whoami)" >> /etc/ssh/sshd_config
    
    # Restart SSH
    systemctl restart sshd
    
    echo -e "${GREEN}✓ SSH secured${NC}"
    echo -e "${YELLOW}⚠️ Make sure you have SSH keys configured before disconnecting!${NC}"
}

# Function to secure Nginx
secure_nginx() {
    echo -e "${YELLOW}Securing Nginx...${NC}"
    
    # Add security headers to all sites
    for conf in /etc/nginx/sites-available/*; do
        if [ -f "$conf" ]; then
            # Add security headers if not present
            if ! grep -q "X-Frame-Options" "$conf"; then
                sed -i '/server {/a \    add_header X-Frame-Options "SAMEORIGIN" always;\n    add_header X-Content-Type-Options "nosniff" always;\n    add_header X-XSS-Protection "1; mode=block" always;\n    add_header Referrer-Policy "strict-origin-when-cross-origin" always;' "$conf"
            fi
        fi
    done
    
    # Disable server tokens
    sed -i 's/^# server_tokens off;/server_tokens off;/' /etc/nginx/nginx.conf
    
    # Test and reload
    nginx -t && systemctl reload nginx
    
    echo -e "${GREEN}✓ Nginx secured${NC}"
}

# Function to secure PHP
secure_php() {
    echo -e "${YELLOW}Securing PHP...${NC}"
    
    # Find all php.ini files
    for ini in $(find /etc/php -name "php.ini" 2>/dev/null); do
        # Backup
        cp "$ini" "$ini.backup"
        
        # Disable dangerous functions
        sed -i 's/^disable_functions.*/disable_functions = exec,passthru,shell_exec,system,proc_open,popen,curl_exec,curl_multi_exec,parse_ini_file,show_source,phpinfo/' "$ini"
        
        # Disable file uploads if not needed
        # sed -i 's/^file_uploads.*/file_uploads = Off/' "$ini"
        
        # Limit file upload size
        sed -i 's/^upload_max_filesize.*/upload_max_filesize = 10M/' "$ini"
        
        # Disable remote file inclusion
        sed -i 's/^allow_url_fopen.*/allow_url_fopen = Off/' "$ini"
        sed -i 's/^allow_url_include.*/allow_url_include = Off/' "$ini"
        
        # Hide PHP version
        sed -i 's/^expose_php.*/expose_php = Off/' "$ini"
    done
    
    # Restart PHP-FPM
    systemctl restart php*-fpm 2>/dev/null || true
    
    echo -e "${GREEN}✓ PHP secured${NC}"
}

# Function to install and configure automatic updates
configure_updates() {
    echo -e "${YELLOW}Configuring automatic updates...${NC}"
    
    apt-get install -y unattended-upgrades
    
    # Configure unattended upgrades
    cat > /etc/apt/apt.conf.d/50unattended-upgrades << EOF
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}";
    "\${distro_id}:\${distro_codename}-security";
    "\${distro_id}ESMApps:\${distro_codename}-apps-security";
    "\${distro_id}ESM:\${distro_codename}-infra-security";
};
Unattended-Upgrade::Package-Blacklist {
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
EOF
    
    # Enable automatic updates
    cat > /etc/apt/apt.conf.d/20auto-upgrades << EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF
    
    echo -e "${GREEN}✓ Automatic updates configured${NC}"
}

# Main menu
main() {
    echo "Select security option:"
    echo "1. Configure Firewall"
    echo "2. Configure fail2ban"
    echo "3. Secure SSH"
    echo "4. Secure Nginx"
    echo "5. Secure PHP"
    echo "6. Configure Automatic Updates"
    echo "7. Run All Security Measures"
    echo "8. Exit"
    echo ""
    echo -n "Choice [1-8]: "
    read choice
    
    case $choice in
        1) configure_firewall ;;
        2) configure_fail2ban ;;
        3) secure_ssh ;;
        4) secure_nginx ;;
        5) secure_php ;;
        6) configure_updates ;;
        7)
            configure_firewall
            configure_fail2ban
            secure_ssh
            secure_nginx
            secure_php
            configure_updates
            ;;
        8) exit 0 ;;
        *) echo -e "${RED}Invalid option${NC}" ;;
    esac
}

main
EOF_SECURITY
    chmod +x easyinstall_security.sh
    print_success "easyinstall_security.sh created"
    
    # Create a master script that will run everything
    cat > run_all.sh << 'EOF_RUN'
#!/bin/bash
# Run all EasyInstall scripts

echo "========================================"
echo "Running all EasyInstall scripts..."
echo "========================================"

cd /opt/easyinstallvps

echo "1. Running Python Core..."
python3 easyinstall_core.py

echo "2. Running WordPress Installer..."
php easyinstall_wp.php

echo "3. Running Shell Script..."
bash easyinstall.sh

echo "4. Running Optimization..."
bash easyinstall_optimize.sh

echo "5. Running Security Hardening..."
bash easyinstall_security.sh

echo "========================================"
echo "All scripts completed!"
echo "========================================"
EOF_RUN
    chmod +x run_all.sh
    
    print_success "All embedded scripts created successfully"
    ls -la /opt/easyinstallvps/
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
alias easyvps='cd /opt/easyinstallvps && bash run_all.sh'
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
# Run All Scripts
# ==============================================
run_scripts() {
    print_section "Running Installation Scripts"
    
    cd /opt/easyinstallvps
    
    # Ask user which scripts to run
    echo -e "${YELLOW}Select scripts to run:${NC}"
    echo "1. Run Python Core only"
    echo "2. Run WordPress Installer only"
    echo "3. Run Shell Script only"
    echo "4. Run Optimization only"
    echo "5. Run Security only"
    echo "6. Run All Scripts"
    echo "7. Skip all (run manually later)"
    echo ""
    echo -n "Choice [1-7]: "
    read choice
    
    case $choice in
        1)
            print_info "Running Python Core..."
            python3 easyinstall_core.py
            ;;
        2)
            print_info "Running WordPress Installer..."
            php easyinstall_wp.php
            ;;
        3)
            print_info "Running Shell Script..."
            bash easyinstall.sh
            ;;
        4)
            print_info "Running Optimization..."
            bash easyinstall_optimize.sh
            ;;
        5)
            print_info "Running Security Hardening..."
            bash easyinstall_security.sh
            ;;
        6)
            print_info "Running all scripts..."
            bash run_all.sh
            ;;
        7)
            print_info "Skipping script execution"
            ;;
        *)
            print_error "Invalid choice"
            ;;
    esac
    
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
    echo -e "  • Path: ${YELLOW}/opt/easyinstallvps${NC}"
    ls -la /opt/easyinstallvps/ | grep -E "\.(sh|php|py)$" | while read line; do
        echo -e "    ${GREEN}✓${NC} $(echo $line | awk '{print $9}')"
    done
    echo ""
    
    echo -e "${CYAN}⚡ Available Commands:${NC}"
    echo -e "  • ${GREEN}easyvps${NC}     - Run complete setup"
    echo -e "  • ${GREEN}easywp${NC}      - Run WordPress installer"
    echo -e "  • ${GREEN}easypy${NC}      - Run Python tools"
    echo -e "  • ${GREEN}easybackup${NC}  - Create backup"
    echo -e "  • ${GREEN}easyopt${NC}     - Optimize system"
    echo -e "  • ${GREEN}easysec${NC}     - Security hardening"
    echo -e "  • ${GREEN}easylogs${NC}    - View Nginx logs"
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
    create_embedded_scripts
    install_python_deps
    configure_firewall
    configure_fail2ban
    create_aliases
    run_scripts
    show_summary
    
    echo -e "${GREEN}✅ EasyInstall VPS Setup Complete!${NC}"
    echo -e "${YELLOW}To run again, type: easyvps${NC}"
    echo -e "${YELLOW}Or navigate to: cd /opt/easyinstallvps${NC}"
}

# ==============================================
# Run Main Function
# ==============================================
main "$@"
