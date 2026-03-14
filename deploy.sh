#!/bin/bash

echo "🚀 EasyInstallPHP Cloudflare Worker Deployment"
echo "=============================================="

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Step 1: Clean up old files
echo -e "${YELLOW}📦 Cleaning up old files...${NC}"
rm -rf node_modules package-lock.json .wrangler
rm -f wrangler.toml.bak

# Step 2: Update package.json
echo -e "${YELLOW}📝 Updating package.json...${NC}"
npm install --save-dev wrangler@4
npm install php-wasm@0.0.8

# Step 3: Fix wrangler.toml
echo -e "${YELLOW}🔧 Fixing wrangler.toml...${NC}"
cat > wrangler.toml << 'EOF'
name = "easyinstall-php"
main = "src/index.js"
compatibility_date = "2024-01-01"

[vars]
APP_NAME = "EasyInstallPHP"
APP_VERSION = "1.0.0"
GITHUB_REPO_OWNER = "sugan0927"
GITHUB_REPO_NAME = "easyinstallvps"
GITHUB_BRANCH = "main"

[env.production]
vars = { ENVIRONMENT = "production" }

[env.development]
vars = { ENVIRONMENT = "development" }

compatibility_flags = ["nodejs_compat"]
EOF

# Step 4: Set secrets
echo -e "${YELLOW}🔑 Setting up GitHub Token...${NC}"
echo "ghp_jkMCu4JyMU5Lq7q2sOrb8UmQdTDxsEv4T69Wi" | npx wrangler secret put GITHUB_TOKEN

echo -e "${YELLOW}👤 Setting GitHub username...${NC}"
echo "sugan0927" | npx wrangler secret put GITHUB_REPO_OWNER

echo -e "${YELLOW}📁 Setting repository name...${NC}"
echo "easyinstallvps" | npx wrangler secret put GITHUB_REPO_NAME

# Step 5: Deploy
echo -e "${YELLOW}🌍 Deploying to Cloudflare Workers...${NC}"
npx wrangler deploy

# Step 6: Check status
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Deployment successful!${NC}"
    echo -e "${GREEN}🌐 Your worker is live at: https://easyinstall-php.${YELLOW}your-subdomain${GREEN}.workers.dev${NC}"
else
    echo -e "${RED}❌ Deployment failed!${NC}"
    exit 1
fi
