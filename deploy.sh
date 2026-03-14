#!/bin/bash

echo "🚀 EasyInstallVPS Cloudflare Worker Deployment"
echo "=============================================="

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Step 1: Clean up
echo -e "${YELLOW}📦 Cleaning up...${NC}"
rm -rf node_modules package-lock.json .wrangler

# Step 2: Create minimal package.json
echo -e "${YELLOW}📝 Creating package.json...${NC}"
cat > package.json << 'EOF'
{
  "name": "easyinstallvps",
  "version": "1.0.0",
  "main": "src/index.js",
  "scripts": {
    "deploy": "wrangler deploy --node-compat"
  },
  "devDependencies": {
    "wrangler": "^4.73.0"
  }
}
EOF

# Step 3: Create wrangler.toml
echo -e "${YELLOW}🔧 Creating wrangler.toml...${NC}"
cat > wrangler.toml << 'EOF'
name = "easyinstallvps"
main = "src/index.js"
compatibility_date = "2024-01-01"
compatibility_flags = ["nodejs_compat", "nodejs_compat_v2"]
EOF

# Step 4: Create src directory and index.js
echo -e "${YELLOW}📁 Creating src/index.js...${NC}"
mkdir -p src
cat > src/index.js << 'EOF'
export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    
    if (url.pathname === '/health') {
      return new Response(JSON.stringify({ status: 'ok' }), {
        headers: { 'Content-Type': 'application/json' }
      });
    }

    const html = \`
      <!DOCTYPE html>
      <html>
      <head>
          <title>EasyInstallVPS</title>
          <meta http-equiv="refresh" content="0;url=https://github.com/sugan0927/easyinstallvps">
      </head>
      <body>
          <h1>Redirecting to GitHub...</h1>
          <p><a href="https://github.com/sugan0927/easyinstallvps">Click here if not redirected</a></p>
      </body>
      </html>
    \`;

    return new Response(html, {
      headers: { 'Content-Type': 'text/html' }
    });
  }
};
EOF

# Step 5: Install dependencies
echo -e "${YELLOW}📥 Installing dependencies...${NC}"
npm install

# Step 6: Deploy
echo -e "${YELLOW}🌍 Deploying to Cloudflare Workers...${NC}"
npx wrangler deploy --node-compat

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Deployment successful!${NC}"
    echo -e "${GREEN}🌐 Your worker is live at: https://easyinstallvps.${YELLOW}your-subdomain${GREEN}.workers.dev${NC}"
else
    echo -e "${RED}❌ Deployment failed!${NC}"
    exit 1
fi
