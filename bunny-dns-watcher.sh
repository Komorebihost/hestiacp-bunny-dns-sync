#!/bin/bash
# =============================================================================
# HestiaCP → Bunny DNS  –  File Watcher  v2.2.0
# /usr/local/hestia/plugins/bunny-dns/bunny-dns-watcher.sh
# https://komorebihost.com
# =============================================================================

PLUGIN_DIR="/usr/local/hestia/plugins/bunny-dns"
ENGINE="$PLUGIN_DIR/bunny-dns.sh"
LOG="$PLUGIN_DIR/bunny-dns.log"
WATCH_DIR="/usr/local/hestia/data/users"
LOCK_DIR="/tmp/bunny-dns-locks"

mkdir -p "$LOCK_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WATCH] $*" >> "$LOG"; }
log "Watcher started. Watching: $WATCH_DIR"

inotifywait \
    --monitor --recursive --quiet \
    --format '%e %w %f' \
    --event CLOSE_WRITE \
    --event DELETE \
    --event MOVED_FROM \
    --event MOVED_TO \
    "$WATCH_DIR" \
| while read -r event dir file; do
    [[ "$file" == *.conf ]] || continue
    [[ "$dir"  == */dns/ ]] || continue

    domain="${file%.conf}"
    [[ "$domain" == "."* ]] && continue
    [[ "$domain" == *"~"  ]] && continue
    [[ "$domain" == "dns" ]] && continue

    # Extract username from path: .../users/USERNAME/dns/
    user=$(echo "$dir" | sed 's|.*/users/\([^/]*\)/dns/.*|\1|')

    log "Event: $event | user=$user | domain=$domain"

    case "$event" in
        CLOSE_WRITE|MOVED_TO)
            lockfile="$LOCK_DIR/${domain}.lock"
            # If sync already running for this domain, skip
            if ! mkdir "$lockfile" 2>/dev/null; then
                log "Skip $domain: sync already in progress"
                continue
            fi
            # Run sync in background, release lock when done
            (
                sleep 2
                "$ENGINE" sync "$domain" "$user"
                rmdir "$lockfile" 2>/dev/null
            ) &
            ;;
        DELETE|MOVED_FROM)
            rmdir "$LOCK_DIR/${domain}.lock" 2>/dev/null
            "$ENGINE" delete "$domain" "$user"
            ;;
    esac
done
