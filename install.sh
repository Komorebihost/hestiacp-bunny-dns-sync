#!/bin/bash
# HestiaCP Bunny DNS Plugin – install.sh
set -e

PLUGIN_DIR="/usr/local/hestia/plugins/bunny-dns"
SERVICE_FILE="/etc/systemd/system/bunny-dns.service"

# Dependencies
for pkg in jq curl inotify-tools; do
    command -v "${pkg/inotify-tools/inotifywait}" &>/dev/null && continue
    echo "Installing $pkg..."
    if command -v apt-get &>/dev/null; then apt-get install -y -q "$pkg" 2>/dev/null || true
    elif command -v yum &>/dev/null;   then yum install -y -q "$pkg" 2>/dev/null || true
    fi
done

mkdir -p "$PLUGIN_DIR/mapping"
chmod 750 "$PLUGIN_DIR/mapping"

# Config
if [ ! -f "$PLUGIN_DIR/config.conf" ]; then
    cp "$PLUGIN_DIR/config.conf.example" "$PLUGIN_DIR/config.conf"
    chmod 600 "$PLUGIN_DIR/config.conf"
    echo "→ Edit $PLUGIN_DIR/config.conf and set your BUNNY_API_KEY"
fi

# Permissions
chmod 750 "$PLUGIN_DIR/bunny-dns.sh"
chmod 750 "$PLUGIN_DIR/bunny-dns-watcher.sh"

# Log file
touch "$PLUGIN_DIR/bunny-dns.log"
chmod 640 "$PLUGIN_DIR/bunny-dns.log"

# Systemd service
cp "$PLUGIN_DIR/bunny-dns.service" "$SERVICE_FILE"
systemctl daemon-reload
systemctl enable bunny-dns
systemctl start  bunny-dns

echo "✅ Bunny DNS Plugin installed."
echo "   Edit: $PLUGIN_DIR/config.conf"
echo "   Then run: $PLUGIN_DIR/bunny-dns.sh sync_all"
exit 0
