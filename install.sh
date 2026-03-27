#!/bin/bash
set -e

# ─── Prompt for required values ───────────────────────────────────────────────
read -p "Domain (e.g. desktop.example.com): " DOMAIN
read -p "Linux username to run the desktop: " USER
read -p "Certbot email: " CERTBOT_EMAIL
read -p "Basic auth username: " AUTH_USER
read -s -p "Basic auth password: " AUTH_PASS; echo
read -p "Selkies port [8080]: " SELKIES_PORT
SELKIES_PORT="${SELKIES_PORT:-8080}"

UID_NUM=$(id -u "$USER")
TURN_SECRET="$(openssl rand -hex 32)"
HTPASSWD_FILE="/etc/nginx/.htpasswd-selkies"
SELKIES_VERSION="1.6.2"

echo ""
echo "Installing Selkies for domain: ${DOMAIN}"
echo ""

# ─── 1. System dependencies ───────────────────────────────────────────────────
echo "[1/8] Installing system dependencies..."
apt-get update -qq
apt-get install -y \
  xvfb x11-utils x11-xserver-utils xdotool wmctrl xsel \
  python3-pip python3-gi python3-gi-cairo python3-dev \
  python3-gst-1.0 \
  gir1.2-gtk-3.0 gir1.2-gst-plugins-base-1.0 gir1.2-gstreamer-1.0 \
  gir1.2-gst-plugins-bad-1.0 \
  gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
  gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly \
  gstreamer1.0-x gstreamer1.0-libav gstreamer1.0-tools \
  gstreamer1.0-nice \
  libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
  libcairo2-dev libgirepository1.0-dev \
  coturn certbot python3-certbot-nginx apache2-utils \
  dbus-x11 at-spi2-core pulseaudio

# ─── 2. Selkies-GStreamer ──────────────────────────────────────────────────────
echo "[2/8] Installing selkies-gstreamer..."
curl -fsSL "https://github.com/selkies-project/selkies/releases/download/v${SELKIES_VERSION}/selkies_gstreamer-${SELKIES_VERSION}-py3-none-any.whl" \
  -o "/tmp/selkies_gstreamer-${SELKIES_VERSION}-py3-none-any.whl"
pip3 install --break-system-packages "/tmp/selkies_gstreamer-${SELKIES_VERSION}-py3-none-any.whl"

echo "[2b/8] Downloading web assets..."
mkdir -p /opt/selkies/web
curl -fsSL "https://github.com/selkies-project/selkies/releases/download/v${SELKIES_VERSION}/selkies-gstreamer-web_v${SELKIES_VERSION}.tar.gz" \
  -o /tmp/selkies-gstreamer-web.tar.gz
tar -xzf /tmp/selkies-gstreamer-web.tar.gz -C /opt/selkies/web

# ─── 3. coturn ────────────────────────────────────────────────────────────────
echo "[3/8] Setting up coturn (TURN server)..."
PUBLIC_IP=$(curl -fsSL https://ifconfig.me)
cat > /etc/turnserver.conf <<EOF
listening-port=3478
tls-listening-port=5349
listening-ip=0.0.0.0
relay-ip=${PUBLIC_IP}
external-ip=${PUBLIC_IP}
realm=${DOMAIN}
server-name=${DOMAIN}
use-auth-secret
static-auth-secret=${TURN_SECRET}
no-multicast-peers
no-cli
log-file=/var/log/turnserver.log
min-port=49152
max-port=65535
EOF

# Open TURN relay port range in firewall
if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow 49152:65535/udp
fi

echo "TURN_SECRET=${TURN_SECRET}" > /etc/selkies.env
chmod 600 /etc/selkies.env
chown ${USER}: /etc/selkies.env

# ─── 4. Systemd services ──────────────────────────────────────────────────────
echo "[4/8] Creating systemd services..."

cat > /etc/systemd/system/selkies-xvfb.service <<EOF
[Unit]
Description=Xvfb virtual display for Selkies
After=network.target

[Service]
User=${USER}
ExecStart=/usr/bin/Xvfb :99 -screen 0 1920x1080x24 +extension GLX +render -noreset
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/selkies-gnome.service <<EOF
[Unit]
Description=GNOME session for Selkies
After=selkies-xvfb.service
Requires=selkies-xvfb.service

[Service]
User=${USER}
Environment=DISPLAY=:99
Environment=XDG_SESSION_TYPE=x11
Environment=XDG_RUNTIME_DIR=/run/user/${UID_NUM}
Environment=GNOME_SHELL_SESSION_MODE=ubuntu
Environment=XDG_CURRENT_DESKTOP=ubuntu:GNOME
Environment=XDG_CONFIG_DIRS=/etc/xdg/xdg-ubuntu:/etc/xdg
Environment=XDG_SESSION_CLASS=user
ExecStartPre=/bin/sleep 2
ExecStart=/usr/bin/dbus-run-session -- /usr/bin/gnome-session --disable-acceleration-check
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Stop and disable GDM so it doesn't interfere with the virtual display
systemctl stop gdm3 2>/dev/null || true
systemctl disable gdm3 2>/dev/null || true

cat > /etc/systemd/system/selkies.service <<EOF
[Unit]
Description=Selkies GStreamer Remote Desktop
After=selkies-gnome.service
Requires=selkies-gnome.service

[Service]
User=${USER}
EnvironmentFile=/etc/selkies.env
Environment=DISPLAY=:99
Environment=XDG_RUNTIME_DIR=/run/user/${UID_NUM}
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${UID_NUM}/bus
ExecStartPre=/bin/sleep 3
ExecStart=/usr/local/bin/selkies-gstreamer \
  --addr=127.0.0.1 \
  --port=${SELKIES_PORT} \
  --web_root=/opt/selkies/web/gst-web \
  --turn_host=${DOMAIN} \
  --turn_port=3478 \
  --turn_shared_secret=\${TURN_SECRET} \
  --enable_basic_auth=false \
  --encoder=vp8enc \
  --framerate=30
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# ─── 5. Basic auth ────────────────────────────────────────────────────────────
echo "[5/8] Setting up nginx basic auth..."
htpasswd -bc ${HTPASSWD_FILE} "${AUTH_USER}" "${AUTH_PASS}"
chmod 640 ${HTPASSWD_FILE}
chown root:www-data ${HTPASSWD_FILE}

# ─── 6. Nginx (HTTP only for certbot) ─────────────────────────────────────────
echo "[6/8] Creating nginx server block..."
cat > /etc/nginx/sites-available/selkies <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

ln -sf /etc/nginx/sites-available/selkies /etc/nginx/sites-enabled/selkies
nginx -t && systemctl reload nginx

# ─── 7. Let's Encrypt ─────────────────────────────────────────────────────────
echo "[7/8] Obtaining Let's Encrypt certificate..."
certbot certonly --nginx -d ${DOMAIN} --non-interactive --agree-tos --email ${CERTBOT_EMAIL} --keep-until-expiring

echo "[7b/8] Updating nginx with HTTPS config..."
cat > /etc/nginx/sites-available/selkies <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name ${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    auth_basic "Selkies Remote Desktop";
    auth_basic_user_file ${HTPASSWD_FILE};

    location / {
        proxy_pass http://127.0.0.1:${SELKIES_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
    }
}
EOF

nginx -t && systemctl reload nginx

# ─── 8. Start services ────────────────────────────────────────────────────────
echo "[8/8] Enabling and starting all services..."
systemctl daemon-reload
systemctl enable coturn selkies-xvfb selkies-gnome selkies
systemctl start coturn
systemctl start selkies-xvfb
sleep 3
systemctl start selkies-gnome
sleep 5
systemctl start selkies

# Disable GNOME screen lock and idle timeout
sleep 3
sudo -u ${USER} DISPLAY=:99 \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${UID_NUM}/bus \
  gsettings set org.gnome.desktop.screensaver lock-enabled false 2>/dev/null || true
sudo -u ${USER} DISPLAY=:99 \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${UID_NUM}/bus \
  gsettings set org.gnome.desktop.session idle-delay 0 2>/dev/null || true

echo ""
echo "============================================"
echo " Selkies installation complete!"
echo " Access: https://${DOMAIN}"
echo " User: ${AUTH_USER}"
echo "============================================"
echo ""
echo "Check status with:"
echo "  systemctl status selkies selkies-gnome selkies-xvfb coturn"
