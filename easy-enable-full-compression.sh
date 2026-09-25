#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────
# easy-enable-full-compression.sh
#
# आपके easyinstall.sh ने nginx.org के "mainline" repo से nginx इंस्टॉल किया है।
# Debian/Ubuntu के तैयार पैकेज (libnginx-mod-brotli, libnginx-mod-http-zstd)
# उस नginx के लिए **अलग binary** के हिसाब से बने होते हैं — इसलिए वो अक्सर
# load ही नहीं होते (ABI mismatch)। पक्का तरीका यही है कि brotli/zstd modules
# को आपके EXACT चल रहे nginx version के source के खिलाफ खुद compile किया
# जाए। यही स्क्रिप्ट करती है — मौजूदा nginx binary को न तो छूती है, न बदलती
# है, सिर्फ दो नई .so फाइलें बनाकर /usr/lib/nginx/modules/ में डालती है।
#
# चलाएँ: sudo bash easy-enable-full-compression.sh
# ─────────────────────────────────────────────────────────────────────────
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

[ "$(id -u)" -eq 0 ] || { err "root से चलाएँ (sudo bash $0)"; exit 1; }
command -v nginx >/dev/null || { err "nginx नहीं मिला।"; exit 1; }

NGINX_VERSION=$(nginx -v 2>&1 | grep -oP 'nginx/\K[0-9.]+') || true
if [ -z "${NGINX_VERSION:-}" ]; then
    err "nginx version पता नहीं चल पाया (nginx -v चेक करें)"
    exit 1
fi
log "चल रहा nginx version: $NGINX_VERSION"

# nginx.org का binary जिन configure arguments से बना, ठीक वही arguments
# हमारे नए मॉड्यूल्स के लिए भी दोबारा इस्तेमाल होंगे — इसी से ABI मैच
# गारंटी होती है (nginx.org के mainline builds हमेशा --with-compat के
# साथ बनते हैं, जो third-party dynamic modules को ठीक इसी तरह जोड़ने के
# लिए ही बनाया गया है)।
CONFIGURE_ARGS=$(nginx -V 2>&1 | grep 'configure arguments:' | sed 's/^configure arguments: //')
if [ -z "$CONFIGURE_ARGS" ]; then
    err "configure arguments नहीं पढ़ पाया — nginx -V का output चेक करें"
    exit 1
fi
log "मौजूदा build के configure arguments मिल गए"

log "Build dependencies इंस्टॉल हो रही हैं..."
apt-get update -qq
apt-get install -y build-essential git wget zlib1g-dev libssl-dev libzstd-dev >/dev/null
apt-get install -y libpcre2-dev >/dev/null 2>&1 || apt-get install -y libpcre3-dev >/dev/null 2>&1 || \
    warn "libpcre2-dev/libpcre3-dev दोनों नहीं मिले — अगर configure fail हो तो PCRE की वजह से हो सकता है"

WORKDIR=/usr/local/src/easyinstall-nginx-modules
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

log "nginx-$NGINX_VERSION का सोर्स डाउनलोड हो रहा है..."
wget -q "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" -O nginx.tar.gz || {
    err "nginx-$NGINX_VERSION.tar.gz nginx.org पर नहीं मिला (शायद बहुत नया/पुराना version है)"
    exit 1
}
tar xzf nginx.tar.gz

log "ngx_brotli (Google) क्लोन हो रहा है..."
git clone --quiet --recursive https://github.com/google/ngx_brotli.git

log "zstd-nginx-module (GetPageSpeed का actively-maintained fork) क्लोन हो रहा है..."
git clone --quiet https://github.com/GetPageSpeed/zstd-nginx-module.git

cd "nginx-${NGINX_VERSION}"

log "Configure चल रहा है (मौजूदा nginx के जैसे ही flags + brotli + zstd)..."
# शब्दश: वही आर्ग्युमेंट्स दोबारा, बस दो नए --add-dynamic-module जोड़े गए
eval ./configure "$CONFIGURE_ARGS" \
    --add-dynamic-module=../ngx_brotli \
    --add-dynamic-module=../zstd-nginx-module \
    > /tmp/eirt-nginx-configure.log 2>&1 || {
        err "configure fail हुआ — /tmp/eirt-nginx-configure.log देखें"
        tail -40 /tmp/eirt-nginx-configure.log
        exit 1
    }

log "मॉड्यूल्स compile हो रहे हैं (इसमें 1-3 मिनट लग सकते हैं, 1-core VPS पर थोड़ा ज़्यादा)..."
make modules -j"$(nproc)" > /tmp/eirt-nginx-make.log 2>&1 || {
    err "compile fail हुआ — /tmp/eirt-nginx-make.log देखें"
    tail -40 /tmp/eirt-nginx-make.log
    exit 1
}

mkdir -p /usr/lib/nginx/modules
for so in ngx_http_brotli_filter_module.so ngx_http_brotli_static_module.so \
          ngx_http_zstd_filter_module.so ngx_http_zstd_static_module.so; do
    if [ -f "objs/$so" ]; then
        cp -f "objs/$so" /usr/lib/nginx/modules/
        log "Installed: /usr/lib/nginx/modules/$so"
    else
        warn "$so नहीं बना — objs/ में देख लें"
    fi
done

mkdir -p /etc/nginx/modules-enabled

if [ -f /usr/lib/nginx/modules/ngx_http_brotli_filter_module.so ]; then
    mkdir -p /etc/nginx/modules-available
    cat > /etc/nginx/modules-available/50-mod-brotli.conf <<'EOF'
load_module modules/ngx_http_brotli_filter_module.so;
load_module modules/ngx_http_brotli_static_module.so;
EOF
    ln -sf /etc/nginx/modules-available/50-mod-brotli.conf /etc/nginx/modules-enabled/50-mod-brotli.conf
fi

if [ -f /usr/lib/nginx/modules/ngx_http_zstd_filter_module.so ]; then
    mkdir -p /etc/nginx/modules-available
    cat > /etc/nginx/modules-available/50-mod-http-zstd.conf <<'EOF'
load_module modules/ngx_http_zstd_filter_module.so;
load_module modules/ngx_http_zstd_static_module.so;
EOF
    ln -sf /etc/nginx/modules-available/50-mod-http-zstd.conf /etc/nginx/modules-enabled/50-mod-http-zstd.conf
fi

log "nginx.conf में modules-enabled का 'include' है या नहीं, चेक हो रहा है..."
if ! grep -q "include /etc/nginx/modules-enabled" /etc/nginx/nginx.conf; then
    warn "nginx.conf में 'include /etc/nginx/modules-enabled/*.conf;' नहीं मिला — जोड़ा जा रहा है"
    sed -i '/^pid /a include /etc/nginx/modules-enabled/*.conf;' /etc/nginx/nginx.conf
fi

log "nginx -t से जाँच हो रही है..."
if nginx -t; then
    systemctl reload nginx
    log "✅ nginx reload हो गया — brotli + zstd modules अब लोड हैं"
else
    err "nginx -t fail हुआ — ऊपर की गई नई load_module लाइनों को हटाकर दोबारा कोशिश करें"
    exit 1
fi

echo
log "अब बस एक step बाकी है — brotli.conf/zstd.conf (behaviour rules) दोबारा लिखने के लिए:"
echo "    python3 /usr/local/lib/easyinstall_config.py --stage nginx_extras"
echo "    nginx -t && systemctl reload nginx"
echo
log "जाँचने के लिए (होनी चाहिए 'br' या 'zstd', domain अपना डालें):"
echo "    curl -s -o /dev/null -D - -H 'Accept-Encoding: br' https://YOURDOMAIN/ | grep -i content-encoding"
echo "    curl -s -o /dev/null -D - -H 'Accept-Encoding: zstd' https://YOURDOMAIN/ | grep -i content-encoding"
