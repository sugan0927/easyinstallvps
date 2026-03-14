// src/index.js - EasyInstallVPS Cloudflare Worker
export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    
    // Handle different paths
    const files = {
      '/': 'index.html',
      '/install': 'install.sh',
      '/install.sh': 'install.sh',
      '/master': 'install.sh',
      '/easyinstall_wp.php': 'easyinstall_wp.php',
      '/easyinstall_core.py': 'easyinstall_core.py',
      '/easyinstall.sh': 'easyinstall.sh',
      '/wp': 'easyinstall_wp.php',
      '/python': 'easyinstall_core.py',
      '/shell': 'easyinstall.sh',
      '/health': 'health',
      '/status': 'health'
    };

    // Get requested file
    const file = files[url.pathname];
    
    // Handle health check
    if (file === 'health') {
      return new Response(JSON.stringify({
        status: 'healthy',
        timestamp: new Date().toISOString(),
        worker: 'easyinstallvps',
        version: '1.0.0'
      }), {
        headers: { 
          'Content-Type': 'application/json',
          'Cache-Control': 'no-cache'
        }
      });
    }
    
    // Handle install script request
    if (file === 'install.sh') {
      return serveInstallScript();
    }
    
    // Handle PHP file request
    if (file === 'easyinstall_wp.php') {
      return redirectToGitHub('easyinstall_wp.php');
    }
    
    // Handle Python file request
    if (file === 'easyinstall_core.py') {
      return redirectToGitHub('easyinstall_core.py');
    }
    
    // Handle Shell file request
    if (file === 'easyinstall.sh') {
      return redirectToGitHub('easyinstall.sh');
    }
    
    // Default: Serve main page
    return serveMainPage();
  }
};

// Function to redirect to GitHub raw content
function redirectToGitHub(filename) {
  const rawUrl = `https://raw.githubusercontent.com/sugan0927/easyinstallvps/main/${filename}`;
  return Response.redirect(rawUrl, 302);
}

// Function to serve the master installation script
function serveInstallScript() {
  const installScript = `#!/bin/bash

# EasyInstallVPS - Master Installation Script
# एक ही कमांड से पूरा VPS सेटअप

set -e

# Colors
RED='\\033[0;31m'
GREEN='\\033[0;32m'
YELLOW='\\033[1;33m'
BLUE='\\033[0;34m'
NC='\\033[0m'

echo -e "\${BLUE}================================\${NC}"
echo -e "\${GREEN}🚀 EasyInstallVPS Master Script\${NC}"
echo -e "\${BLUE}================================\${NC}"
echo -e "\${YELLOW}Starting complete VPS setup...\${NC}"
echo ""

# Function to print section header
print_section() {
    echo ""
    echo -e "\${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\${NC}"
    echo -e "\${GREEN}► \$1\${NC}"
    echo -e "\${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\${NC}"
}

# Function to check if command exists
command_exists() {
    command -v "\$1" >/dev/null 2>&1
}

# Check if running as root
if [[ \$EUID -ne 0 ]]; then
   echo -e "\${RED}This script must be run as root!\${NC}" 
   echo -e "\${YELLOW}Use: sudo bash install.sh\${NC}"
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
    echo -e "\${YELLOW}PHP not found. Installing PHP...\${NC}"
    apt-get install -y php php-cli php-fpm php-mysql php-curl php-gd php-mbstring php-xml php-xmlrpc php-zip php-json php-bcmath
    echo -e "\${GREEN}✓ PHP installed successfully\${NC}"
else
    echo -e "\${GREEN}✓ PHP is already installed: \$(php -v | head -n1)\${NC}"
fi

# Check Python
print_section "Checking Python Installation"
if ! command_exists python3; then
    echo -e "\${YELLOW}Python3 not found. Installing Python...\${NC}"
    apt-get install -y python3 python3-pip python3-venv
    echo -e "\${GREEN}✓ Python3 installed successfully\${NC}"
else
    echo -e "\${GREEN}✓ Python3 is already installed: \$(python3 --version)\${NC}"
fi

# Check MySQL
print_section "Checking MySQL Installation"
if ! command_exists mysql; then
    echo -e "\${YELLOW}MySQL not found. Installing MySQL...\${NC}"
    apt-get install -y mariadb-server mariadb-client
    systemctl start mariadb
    systemctl enable mariadb
    echo -e "\${GREEN}✓ MySQL installed successfully\${NC}"
else
    echo -e "\${GREEN}✓ MySQL is already installed\${NC}"
fi

# Check Nginx
print_section "Checking Nginx Installation"
if ! command_exists nginx; then
    echo -e "\${YELLOW}Nginx not found. Installing Nginx...\${NC}"
    apt-get install -y nginx
    systemctl start nginx
    systemctl enable nginx
    echo -e "\${GREEN}✓ Nginx installed successfully\${NC}"
else
    echo -e "\${GREEN}✓ Nginx is already installed\${NC}"
fi

# Create installation directory
print_section "Creating Installation Directory"
INSTALL_DIR="/opt/easyinstallvps"
mkdir -p \$INSTALL_DIR
cd \$INSTALL_DIR
echo -e "\${GREEN}✓ Working directory: \$INSTALL_DIR\${NC}"

# Download all scripts
print_section "Downloading Installation Scripts"

echo -e "\${YELLOW}Downloading WordPress installer...\${NC}"
curl -sSL https://raw.githubusercontent.com/sugan0927/easyinstallvps/main/easyinstall_wp.php -o easyinstall_wp.php
chmod +x easyinstall_wp.php
echo -e "\${GREEN}✓ WordPress installer downloaded\${NC}"

echo -e "\${YELLOW}Downloading Shell installer...\${NC}"
curl -sSL https://raw.githubusercontent.com/sugan0927/easyinstallvps/main/easyinstall.sh -o easyinstall.sh
chmod +x easyinstall.sh
echo -e "\${GREEN}✓ Shell installer downloaded\${NC}"

echo -e "\${YELLOW}Downloading Python core...\${NC}"
curl -sSL https://raw.githubusercontent.com/sugan0927/easyinstallvps/main/easyinstall_core.py -o easyinstall_core.py
chmod +x easyinstall_core.py
echo -e "\${GREEN}✓ Python core downloaded\${NC}"

# Run WordPress installation
print_section "Running WordPress LEMP Stack Installation"
echo -e "\${YELLOW}This will install complete WordPress with LEMP stack...\${NC}"
echo -e "\${YELLOW}Press Enter to continue or Ctrl+C to cancel\${NC}"
read -p ""

php easyinstall_wp.php

# Run Shell installation
print_section "Running Additional Shell Configuration"
echo -e "\${YELLOW}Configuring server optimizations...\${NC}"
bash easyinstall.sh

# Run Python setup
print_section "Running Python Configuration"
echo -e "\${YELLOW}Setting up Python environment...\${NC}"
python3 easyinstall_core.py

# Create alias for easy access
print_section "Creating Command Aliases"
echo 'alias easyvps="cd /opt/easyinstallvps && bash install.sh"' >> ~/.bashrc
echo 'alias easywp="php /opt/easyinstallvps/easyinstall_wp.php"' >> ~/.bashrc
echo 'alias easypy="python3 /opt/easyinstallvps/easyinstall_core.py"' >> ~/.bashrc
source ~/.bashrc 2>/dev/null || true
echo -e "\${GREEN}✓ Aliases created: easyvps, easywp, easypy\${NC}"

# Create MySQL info file
print_section "Saving MySQL Credentials"
MYSQL_ROOT_PASS=\$(openssl rand -base64 32)
mysqladmin -u root password "\$MYSQL_ROOT_PASS" 2>/dev/null || true

cat > /root/.mysql_info << EOF
MySQL Root Password: \$MYSQL_ROOT_PASS
MySQL Secure Installation: mysql_secure_installation
Login: mysql -u root -p
EOF

chmod 600 /root/.mysql_info
echo -e "\${GREEN}✓ MySQL credentials saved in /root/.mysql_info\${NC}"

# Show installation summary
print_section "Installation Complete! 🎉"
echo -e "\${GREEN}✓ All components installed successfully\${NC}"
echo ""
echo -e "\${YELLOW}Installation Summary:\${NC}"
echo -e "  • PHP: \$(php -v | head -n1 | cut -d' ' -f2)"
echo -e "  • Nginx: \$(nginx -v 2>&1 | cut -d'/' -f2)"
echo -e "  • MySQL: \$(mysql --version | cut -d' ' -f6 | cut -d',' -f1)"
echo -e "  • Python: \$(python3 --version | cut -d' ' -f2)"
echo ""
echo -e "\${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\${NC}"
echo -e "\${GREEN}🌐 WordPress Access:\${NC}"
echo -e "  • Site: \${YELLOW}http://\$(curl -s ifconfig.me)\${NC}"
echo -e "  • Admin: \${YELLOW}http://\$(curl -s ifconfig.me)/wp-admin\${NC}"
echo ""
echo -e "\${GREEN}🔑 MySQL Credentials:\${NC}"
echo -e "  • File: \${YELLOW}/root/.mysql_info\${NC}"
echo ""
echo -e "\${GREEN}📦 Installation Directory:\${NC}"
echo -e "  • Path: \${YELLOW}/opt/easyinstallvps\${NC}"
echo ""
echo -e "\${GREEN}⚡ Useful Commands:\${NC}"
echo -e "  • \${YELLOW}easyvps\${NC} - Run complete setup again"
echo -e "  • \${YELLOW}easywp\${NC} - Run WordPress installer only"
echo -e "  • \${YELLOW}easypy\${NC} - Run Python tools only"
echo -e "  • \${YELLOW}cd /opt/easyinstallvps\${NC} - Go to installation directory"
echo ""
echo -e "\${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\${NC}"
echo -e "\${GREEN}🚀 To reinstall anytime, run:\${NC}"
echo -e "\${YELLOW}sudo bash -c \"\$(curl -fsSL https://\$(curl -s ifconfig.me)/install.sh)\"\${NC}"
echo -e "\${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\${NC}"
`;

  return new Response(installScript, {
    headers: {
      'Content-Type': 'text/plain;charset=UTF-8',
      'Cache-Control': 'public, max-age=3600'
    }
  });
}

// Function to serve main HTML page
function serveMainPage() {
  const mainCommand = 'sudo bash -c "$(curl -fsSL https://easyinstallvps.your-subdomain.workers.dev/install.sh)"';
  
  const html = `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>EasyInstallVPS - One Command VPS Setup</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            padding: 20px;
        }
        
        .container {
            background: white;
            border-radius: 20px;
            padding: 40px;
            max-width: 1000px;
            width: 100%;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
        }
        
        .header {
            text-align: center;
            margin-bottom: 40px;
        }
        
        h1 {
            font-size: 48px;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            margin-bottom: 10px;
        }
        
        .subtitle {
            color: #666;
            font-size: 18px;
        }
        
        .one-command {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 30px;
            border-radius: 10px;
            margin: 30px 0;
            text-align: center;
        }
        
        .command-box {
            background: #1e1e2f;
            color: #00ff00;
            padding: 20px;
            border-radius: 10px;
            font-family: 'Courier New', monospace;
            font-size: 16px;
            margin: 20px 0;
            word-break: break-all;
            border: 2px solid #4CAF50;
        }
        
        .copy-btn {
            background: #4CAF50;
            color: white;
            border: none;
            padding: 12px 30px;
            border-radius: 5px;
            cursor: pointer;
            font-size: 16px;
            margin: 10px 0;
            transition: background 0.3s ease;
        }
        
        .copy-btn:hover {
            background: #45a049;
        }
        
        .features {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
            gap: 20px;
            margin: 30px 0;
        }
        
        .feature-card {
            background: #f8f9fa;
            padding: 20px;
            border-radius: 10px;
            text-align: center;
            border: 1px solid #e0e0e0;
        }
        
        .feature-icon {
            font-size: 40px;
            margin-bottom: 15px;
        }
        
        .feature-title {
            font-size: 18px;
            font-weight: bold;
            margin-bottom: 10px;
            color: #333;
        }
        
        .feature-desc {
            color: #666;
            font-size: 14px;
        }
        
        .files-section {
            margin: 40px 0;
        }
        
        .files-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 20px;
            margin-top: 20px;
        }
        
        .file-item {
            background: #f8f9fa;
            padding: 20px;
            border-radius: 10px;
            text-align: center;
            border: 1px solid #e0e0e0;
        }
        
        .file-name {
            font-family: monospace;
            font-weight: bold;
            margin: 10px 0;
            color: #333;
        }
        
        .file-link {
            display: inline-block;
            padding: 8px 16px;
            background: #667eea;
            color: white;
            text-decoration: none;
            border-radius: 5px;
            font-size: 14px;
            margin-top: 10px;
        }
        
        .file-link:hover {
            background: #764ba2;
        }
        
        .badge {
            display: inline-block;
            padding: 4px 8px;
            background: #28a745;
            color: white;
            border-radius: 4px;
            font-size: 12px;
            margin-left: 5px;
        }
        
        .footer {
            text-align: center;
            margin-top: 40px;
            padding-top: 20px;
            border-top: 1px solid #e0e0e0;
            color: #999;
        }
        
        .github-link {
            display: inline-flex;
            align-items: center;
            gap: 10px;
            padding: 12px 24px;
            background: #333;
            color: white;
            text-decoration: none;
            border-radius: 5px;
            margin: 20px 0;
        }
        
        .github-link:hover {
            background: #444;
        }
        
        .note {
            background: #fff3cd;
            color: #856404;
            padding: 15px;
            border-radius: 5px;
            margin: 20px 0;
            border-left: 4px solid #ffc107;
        }
        
        @media (max-width: 768px) {
            .container {
                padding: 20px;
            }
            
            h1 {
                font-size: 32px;
            }
            
            .command-box {
                font-size: 14px;
                padding: 15px;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🚀 EasyInstallVPS</h1>
            <div class="subtitle">एक कमांड - पूरा VPS सेटअप</div>
        </div>
        
        <div class="one-command">
            <h2 style="margin-bottom: 20px;">⚡ एक ही कमांड से इंस्टॉल करें</h2>
            <div class="command-box" id="installCommand">${mainCommand}</div>
            <button class="copy-btn" onclick="copyCommand()">📋 कमांड कॉपी करें</button>
            <p style="margin-top: 15px; font-size: 14px;">sudo के साथ चलाएं (रूट एक्सेस जरूरी)</p>
        </div>
        
        <div class="features">
            <div class="feature-card">
                <div class="feature-icon">🐘</div>
                <div class="feature-title">WordPress + LEMP</div>
                <div class="feature-desc">Nginx, MySQL, PHP, WordPress एक साथ</div>
            </div>
            <div class="feature-card">
                <div class="feature-icon">🐍</div>
                <div class="feature-title">Python Tools</div>
                <div class="feature-desc">Python 3 और जरूरी पैकेज</div>
            </div>
            <div class="feature-card">
                <div class="feature-icon">⚡</div>
                <div class="feature-title">Server Optimizations</div>
                <div class="feature-desc">परफॉरमेंस और सिक्योरिटी सेटअप</div>
            </div>
            <div class="feature-card">
                <div class="feature-icon">🔄</div>
                <div class="feature-title">Auto Configuration</div>
                <div class="feature-desc">सब कुछ अपने आप कॉन्फ़िगर</div>
            </div>
        </div>
        
        <div class="note">
            <strong>📌 नोट:</strong> यह स्क्रिप्ट Ubuntu/Debian VPS पर काम करती है। रूट एक्सेस जरूरी है।
        </div>
        
        <div class="files-section">
            <h2>📁 अलग-अलग स्क्रिप्ट्स</h2>
            <div class="files-grid">
                <div class="file-item">
                    <div class="file-icon">🐘</div>
                    <div class="file-name">easyinstall_wp.php</div>
                    <div>WordPress Installer</div>
                    <a href="/wp" class="file-link">Download</a>
                    <span class="badge">PHP</span>
                </div>
                
                <div class="file-item">
                    <div class="file-icon">🐍</div>
                    <div class="file-name">easyinstall_core.py</div>
                    <div>Python Core</div>
                    <a href="/python" class="file-link">Download</a>
                    <span class="badge">Python</span>
                </div>
                
                <div class="file-item">
                    <div class="file-icon">📜</div>
                    <div class="file-name">easyinstall.sh</div>
                    <div>Shell Script</div>
                    <a href="/shell" class="file-link">Download</a>
                    <span class="badge">Bash</span>
                </div>
                
                <div class="file-item">
                    <div class="file-icon">⚙️</div>
                    <div class="file-name">install.sh</div>
                    <div>Master Script</div>
                    <a href="/install" class="file-link">Download</a>
                    <span class="badge">Master</span>
                </div>
            </div>
        </div>
        
        <a href="https://github.com/sugan0927/easyinstallvps" class="github-link" target="_blank">
            <svg height="20" width="20" viewBox="0 0 16 16" fill="currentColor">
                <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"></path>
            </svg>
            GitHub पर देखें
        </a>
        
        <div class="footer">
            <p>EasyInstallVPS v1.0.0 | Cloudflare Workers पर होस्टेड</p>
            <p style="font-size: 12px; margin-top: 10px;">
                <a href="/health" style="color: #667eea;">Health Check</a> | 
                <a href="https://github.com/sugan0927/easyinstallvps/issues" style="color: #667eea;">Report Issue</a>
            </p>
        </div>
    </div>
    
    <script>
        function copyCommand() {
            const command = document.getElementById('installCommand').innerText;
            navigator.clipboard.writeText(command).then(() => {
                alert('✅ कमांड कॉपी हो गया!\n\nअब VPS पर पेस्ट करें और चलाएं:\n' + command);
            }).catch(() => {
                // Fallback
                const textarea = document.createElement('textarea');
                textarea.value = command;
                document.body.appendChild(textarea);
                textarea.select();
                document.execCommand('copy');
                document.body.removeChild(textarea);
                alert('✅ कमांड कॉपी हो गया!');
            });
        }
    </script>
</body>
</html>`;

  return new Response(html, {
    headers: {
      'Content-Type': 'text/html;charset=UTF-8',
      'Cache-Control': 'public, max-age=3600'
    }
  });
}
