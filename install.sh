#!/bin/bash
# =============================================================================
# HestiaCP → Bunny DNS Plugin  –  install.sh  v2.1.0
# https://komorebihost.com
# =============================================================================
set -e

PLUGIN_DIR="/usr/local/hestia/plugins/bunny-dns"
SERVICE_FILE="/etc/systemd/system/bunny-dns.service"
HOOKS_SRC="$PLUGIN_DIR/hooks"
HOOKS_DST="/usr/local/hestia/data/hooks"
CRON_MARKER="# bunny-dns-reconcile"

# ── Dependencies ──────────────────────────────────────────────────────────────
for pkg in jq curl inotify-tools; do
    cmd="${pkg/inotify-tools/inotifywait}"
    command -v "$cmd" &>/dev/null && continue
    echo "Installing $pkg..."
    if   command -v apt-get &>/dev/null; then apt-get install -y -q "$pkg" 2>/dev/null || true
    elif command -v yum     &>/dev/null; then yum     install -y -q "$pkg" 2>/dev/null || true
    fi
done

# ── Directories ───────────────────────────────────────────────────────────────
mkdir -p "$PLUGIN_DIR/mapping"
chmod 750 "$PLUGIN_DIR/mapping"

# ── Config ────────────────────────────────────────────────────────────────────
if [ ! -f "$PLUGIN_DIR/config.conf" ]; then
    cp "$PLUGIN_DIR/config.conf.example" "$PLUGIN_DIR/config.conf"
    chmod 600 "$PLUGIN_DIR/config.conf"
    echo "→ Edit $PLUGIN_DIR/config.conf and set your BUNNY_API_KEY"
fi

# ── Permissions ───────────────────────────────────────────────────────────────
chmod 750 "$PLUGIN_DIR/bunny-dns.sh"
chmod 750 "$PLUGIN_DIR/bunny-dns-watcher.sh"

# ── Log file ──────────────────────────────────────────────────────────────────
touch "$PLUGIN_DIR/bunny-dns.log"
chmod 640 "$PLUGIN_DIR/bunny-dns.log"

# ── Systemd service ───────────────────────────────────────────────────────────
cp "$PLUGIN_DIR/bunny-dns.service" "$SERVICE_FILE"
systemctl daemon-reload
systemctl enable bunny-dns
systemctl start  bunny-dns

# ── HestiaCP hooks ────────────────────────────────────────────────────────────
# Hooks call bunny-dns.sh directly when a domain is added or deleted in HestiaCP.
# This fixes the inotifywait race condition that causes new-user domains to be missed.
if [ -d "$HOOKS_SRC" ]; then
    mkdir -p "$HOOKS_DST"
    for hook in v-add-domain v-delete-domain v-add-dns-domain v-delete-dns-domain; do
        src="$HOOKS_SRC/$hook"
        dst="$HOOKS_DST/$hook"
        [ -f "$src" ] || continue
        if [ -f "$dst" ]; then
            if grep -q "bunny-dns" "$dst" 2>/dev/null; then
                echo "→ Hook $hook already installed, skipping"
                continue
            fi
            # Append to an existing hook from another plugin
            echo "" >> "$dst"
            echo "# --- bunny-dns ---" >> "$dst"
            tail -n +2 "$src" >> "$dst"
            echo "→ Hook $hook appended to existing hook"
        else
            cp "$src" "$dst"
            chmod 750 "$dst"
            echo "→ Hook $hook installed"
        fi
    done
else
    echo "⚠  hooks/ directory not found in $PLUGIN_DIR — skipping hook installation"
    echo "   Copy hooks/ from the repository and re-run install.sh to enable hook support."
fi

# ── Cron reconciliation ───────────────────────────────────────────────────────
# Runs sync_all every hour as a safety net for any events missed by inotifywait.
if ! crontab -l 2>/dev/null | grep -qF "$CRON_MARKER"; then
    ( crontab -l 2>/dev/null
      echo "0 * * * * $PLUGIN_DIR/bunny-dns.sh sync_all >> $PLUGIN_DIR/bunny-dns.log 2>&1 $CRON_MARKER"
    ) | crontab -
    echo "→ Cron reconciliation added (runs every hour)"
else
    echo "→ Cron reconciliation already present, skipping"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "✅ Bunny DNS Plugin installed (v2.1.0)"
echo "   Config : $PLUGIN_DIR/config.conf"
echo "   Verify : systemctl status bunny-dns"
echo "   Sync   : $PLUGIN_DIR/bunny-dns.sh sync_all"
exit 0
