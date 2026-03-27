# Selkies Remote Desktop Setup

## What Was Installed

### Packages
- `xvfb` — virtual display (X server without monitor)
- `python3-gst-1.0`, `gir1.2-gst-plugins-bad-1.0`, `gstreamer1.0-*` — GStreamer + Python bindings
- `coturn` — TURN/STUN server for WebRTC relay
- `certbot`, `python3-certbot-nginx` — Let's Encrypt SSL
- `apache2-utils` — htpasswd for basic auth
- `xsel`, `xdotool`, `wmctrl` — clipboard and window control
- `selkies-gstreamer==1.6.2` — installed from GitHub release wheel

### Files
| File | Purpose |
|------|---------|
| `/usr/local/bin/selkies-gstreamer` | Main selkies binary |
| `/opt/selkies/web/gst-web/` | Web UI assets |
| `/etc/selkies.env` | TURN secret env var (chmod 600) |
| `/etc/turnserver.conf` | coturn config |
| `/etc/nginx/sites-available/selkies` | Nginx config |
| `/etc/nginx/.htpasswd-selkies` | Basic auth credentials |
| `/etc/letsencrypt/live/<domain>/` | SSL cert (auto-renews) |

### Systemd Services
All enabled and start on boot:

| Service | Role |
|---------|------|
| `selkies-xvfb` | Xvfb virtual display on :99 (1920x1080x24) |
| `selkies-gnome` | GNOME session on display :99 |
| `selkies` | Selkies WebRTC streamer on 127.0.0.1:8080 |
| `coturn` | TURN server on port 3478 |

Start order: xvfb → gnome (waits 2s) → selkies (waits 3s)

### Nginx
- New server block in `/etc/nginx/sites-available/selkies` (symlinked to sites-enabled)
- Handles HTTPS, basic auth, and WebSocket proxy to 127.0.0.1:8080

## Key Fixes Applied During Setup
1. **GStreamer not found** — had to install `python3-gst-1.0` and `gir1.2-gst-plugins-bad-1.0` separately after the wheel install
2. **`--display=:99` not valid** — removed; display is set via `DISPLAY=:99` env var in service
3. **"Unauthorized" loop** — selkies v1.6.2 has its own built-in basic auth enabled by default; disabled with `--enable_basic_auth=false` since nginx handles auth

## Useful Commands
```bash
# Check all service status
systemctl status selkies selkies-gnome selkies-xvfb coturn

# Restart desktop stack
sudo systemctl restart selkies-xvfb selkies-gnome selkies

# View selkies logs
sudo journalctl -u selkies -f

# Renew SSL manually
sudo certbot renew

# Change basic auth password
sudo htpasswd /etc/nginx/.htpasswd-selkies <username>
```
