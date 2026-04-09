#!/bin/bash
# =============================================================================
# HestiaCP → Bunny DNS  –  Engine  v2.0.0
# /usr/local/hestia/plugins/bunny-dns/bunny-dns.sh
#
# Compatible: Ubuntu 20/22/24, Debian 11/12, Rocky/AlmaLinux 8/9
#
# Bunny API notes:
#   Auth:    AccessKey header
#   Types:   0=A 1=AAAA 2=CNAME 3=TXT 4=MX 5=RDR 6=NS 8=SRV 9=CAA 10=PTR
#   Add:     PUT  /dnszone/{id}/records
#   NS/SOA:  POST /dnszone/{id}
#
# Cache files:
#   mapping/zones.json              {"domain.tld": zone_id}
#   mapping/records_DOMAIN.json     {"hestia_domain:line_id": bunny_record_id}
# =============================================================================

PLUGIN_DIR="/usr/local/hestia/plugins/bunny-dns"
CONFIG="$PLUGIN_DIR/config.conf"
MAPPING_DIR="$PLUGIN_DIR/mapping"
LOG="$PLUGIN_DIR/bunny-dns.log"
HESTIA_USER_DIR="/usr/local/hestia/data/users"
API="https://api.bunny.net"

[ -f "$CONFIG" ] || { echo "[ERROR] Config not found: $CONFIG" >&2; exit 1; }
source "$CONFIG"
[ -n "$BUNNY_API_KEY" ] || { echo "[ERROR] BUNNY_API_KEY not set" >&2; exit 1; }
mkdir -p "$MAPPING_DIR"

DEFAULT_TTL="${DEFAULT_TTL:-3600}"
BUNNY_NS1="${BUNNY_NS1:-}"
BUNNY_NS2="${BUNNY_NS2:-}"
BUNNY_SOA_EMAIL="${BUNNY_SOA_EMAIL:-}"

log()       { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] ${*:2}" >> "$LOG"; }
log_info()  { log "INFO" "$@"; }
log_warn()  { log "WARN" "$@"; }
log_error() { log "ERR " "$@"; }

# ── API ───────────────────────────────────────────────────────────────────────
_api() {
    local method="$1" endpoint="$2" body="${3:-}"
    local args=(-s -X "$method"
        -H "AccessKey: $BUNNY_API_KEY"
        -H "Content-Type: application/json"
        --max-time 30 --retry 2 --retry-delay 2)
    [ -n "$body" ] && args+=(-d "$body")
    curl "${args[@]}" "${API}${endpoint}"
}

# ── Record type → Bunny integer ───────────────────────────────────────────────
type_to_int() {
    case "${1^^}" in
        A)     echo 0  ;;
        AAAA)  echo 1  ;;
        CNAME) echo 2  ;;
        TXT)   echo 3  ;;
        MX)    echo 4  ;;
        RDR)   echo 5  ;;
        NS)    echo 6  ;;
        SRV)   echo 8  ;;
        CAA)   echo 9  ;;
        PTR)   echo 10 ;;
        *)     echo ""  ;;
    esac
}

# ── Zone cache ────────────────────────────────────────────────────────────────
zone_get_id() {
    local domain="$1" cache="$MAPPING_DIR/zones.json"
    if [ -f "$cache" ]; then
        local v; v=$(jq -r --arg d "$domain" '.[$d] // empty' "$cache" 2>/dev/null)
        [ -n "$v" ] && { echo "$v"; return 0; }
    fi
    local resp zone_id
    resp=$(_api GET "/dnszone?page=1&perPage=1000&search=${domain}")
    zone_id=$(echo "$resp" | jq -r \
        --arg d "$domain" '.Items[] | select(.Domain==$d) | .Id // empty' 2>/dev/null | head -1)
    [ -n "$zone_id" ] && { zone_cache_set "$domain" "$zone_id"; echo "$zone_id"; return 0; }
    return 1
}

zone_cache_set() {
    local cache="$MAPPING_DIR/zones.json"
    [ -f "$cache" ] || echo '{}' > "$cache"
    jq --arg d "$1" --argjson id "$2" '.[$d]=$id' "$cache" \
        > "${cache}.tmp" && mv "${cache}.tmp" "$cache"
}

zone_cache_del() {
    local cache="$MAPPING_DIR/zones.json"
    [ -f "$cache" ] || return 0
    jq --arg d "$1" 'del(.[$d])' "$cache" \
        > "${cache}.tmp" && mv "${cache}.tmp" "$cache"
}

zone_exists_on_bunny() {
    local domain="$1" zone_id="$2"
    local found; found=$(_api GET "/dnszone/${zone_id}" | jq -r '.Domain // empty' 2>/dev/null)
    [ "$found" = "$domain" ]
}

# ── Record cache ──────────────────────────────────────────────────────────────
rec_cache_file() { echo "$MAPPING_DIR/records_${1//./_}.json"; }

rec_cache_set() {
    local cache; cache=$(rec_cache_file "$1")
    [ -f "$cache" ] || echo '{}' > "$cache"
    jq --arg k "${2}:${3}" --argjson id "$4" '.[$k]=$id' "$cache" \
        > "${cache}.tmp" && mv "${cache}.tmp" "$cache"
}

rec_cache_owned_ids() {
    local cache; cache=$(rec_cache_file "$1")
    [ -f "$cache" ] || return 0
    jq -r --arg p "${2}:" \
        'to_entries[] | select(.key|startswith($p)) | .value' "$cache" 2>/dev/null
}

rec_cache_purge() {
    local cache; cache=$(rec_cache_file "$1")
    [ -f "$cache" ] || return 0
    jq --arg p "${2}:" 'with_entries(select(.key|startswith($p)|not))' "$cache" \
        > "${cache}.tmp" && mv "${cache}.tmp" "$cache"
}

# ── Parse a single HestiaCP DNS conf line ────────────────────────────────────
# Format: RECORD='x' TTL='n' TYPE='T' PRIORITY='n' VALUE='v' SUSPENDED='no'
parse_line() {
    p_record=$(   echo "$1" | sed -n "s/.*RECORD='\([^']*\)'.*/\1/p")
    p_ttl=$(      echo "$1" | sed -n "s/.*TTL='\([^']*\)'.*/\1/p")
    p_type=$(     echo "$1" | sed -n "s/.*TYPE='\([^']*\)'.*/\1/p")
    p_priority=$( echo "$1" | sed -n "s/.*PRIORITY='\([^']*\)'.*/\1/p")
    p_value=$(    echo "$1" | sed -n "s/.*VALUE='\([^']*\)'.*/\1/p")
    p_suspended=$(echo "$1" | sed -n "s/.*SUSPENDED='\([^']*\)'.*/\1/p")
}

# ── Build Bunny record JSON body ──────────────────────────────────────────────
build_record_body() {
    local type_int="$1" name="$2" value="$3" ttl="$4" priority="$5" type_str="${6^^}"

    case "$type_str" in
        MX)
            value="${value%.}"
            jq -n --argjson t "$type_int" --arg n "$name" --arg v "$value" \
               --argjson l "${ttl:-3600}" --argjson p "${priority:-10}" \
               '{Type:$t,Name:$n,Value:$v,Ttl:$l,Priority:$p}'
            ;;
        SRV)
            local w p_ tgt
            w=$(echo "$value"   | awk '{print $1}' | grep -o '[0-9]*')
            p_=$(echo "$value"  | awk '{print $2}' | grep -o '[0-9]*')
            tgt=$(echo "$value" | awk '{print $3}'); tgt="${tgt%.}"
            jq -n --argjson t "$type_int" --arg n "$name" --arg v "$tgt" \
               --argjson l "${ttl:-3600}" --argjson pr "${priority:-0}" \
               --argjson w "${w:-0}" --argjson p "${p_:-0}" \
               '{Type:$t,Name:$n,Value:$v,Ttl:$l,Priority:$pr,Weight:$w,Port:$p}'
            ;;
        CAA)
            local flags tag cval
            flags=$(echo "$value" | awk '{print $1}')
            tag=$(  echo "$value" | awk '{print $2}')
            cval=$( echo "$value" | awk '{$1=$2="";print $0}' | sed 's/^ *//' | tr -d '"')
            jq -n --argjson t "$type_int" --arg n "$name" --arg v "$cval" \
               --argjson l "${ttl:-3600}" --argjson f "${flags:-0}" --arg tg "$tag" \
               '{Type:$t,Name:$n,Value:$v,Ttl:$l,Flags:$f,Tag:$tg}'
            ;;
        TXT)
            value="${value#\"}"; value="${value%\"}"
            jq -n --argjson t "$type_int" --arg n "$name" --arg v "$value" \
               --argjson l "${ttl:-3600}" '{Type:$t,Name:$n,Value:$v,Ttl:$l}'
            ;;
        CNAME|NS|PTR|RDR)
            value="${value%.}"
            jq -n --argjson t "$type_int" --arg n "$name" --arg v "$value" \
               --argjson l "${ttl:-3600}" '{Type:$t,Name:$n,Value:$v,Ttl:$l}'
            ;;
        *)
            jq -n --argjson t "$type_int" --arg n "$name" --arg v "$value" \
               --argjson l "${ttl:-3600}" '{Type:$t,Name:$n,Value:$v,Ttl:$l}'
            ;;
    esac
}

# ── Build Bunny record name from HestiaCP RECORD field ────────────────────────
build_name() {
    local raw="$1" hestia_domain="$2" zone_domain="$3"
    local name="${raw%.}"
    name="${name%.${hestia_domain}}"
    [ "$name" = "$hestia_domain" ] && name=""
    [ "$name" = "@" ]              && name=""

    if [ "$hestia_domain" != "$zone_domain" ]; then
        local prefix="${hestia_domain%.$zone_domain}"
        [ -z "$name" ] && name="$prefix" || name="${name}.${prefix}"
    fi

    echo "$name"
}

# ── Find HestiaCP user owning a domain ───────────────────────────────────────
find_user() {
    local domain="$1" hint="${2:-}"
    if [ -n "$hint" ] && [ -f "$HESTIA_USER_DIR/$hint/dns/$domain.conf" ]; then
        echo "$hint"; return 0
    fi
    for conf in "$HESTIA_USER_DIR"/*/dns/"$domain.conf"; do
        [ -f "$conf" ] && basename "$(dirname "$(dirname "$conf")")" && return 0
    done
    return 1
}

# ── Apply custom nameservers and SOA email to a Bunny zone ───────────────────
zone_apply_settings() {
    local zone_id="$1" domain="$2"
    [ -n "$BUNNY_NS1" ] && [ -n "$BUNNY_NS2" ] || [ -n "$BUNNY_SOA_EMAIL" ] || return 0

    local body
    if [ -n "$BUNNY_NS1" ] && [ -n "$BUNNY_NS2" ]; then
        local email="${BUNNY_SOA_EMAIL:-hostmaster@${domain}}"
        body=$(jq -n \
            --argjson e true \
            --arg ns1 "$BUNNY_NS1" \
            --arg ns2 "$BUNNY_NS2" \
            --arg soa "$email" \
            '{CustomNameserversEnabled:$e,Nameserver1:$ns1,Nameserver2:$ns2,SoaEmail:$soa}')
    else
        body=$(jq -n --arg soa "$BUNNY_SOA_EMAIL" '{SoaEmail:$soa}')
    fi

    local resp err
    resp=$(_api POST "/dnszone/${zone_id}" "$body")
    err=$(echo "$resp" | jq -r '.Message // .ErrorKey // empty' 2>/dev/null)
    [ -n "$err" ] \
        && log_error "  NS/SOA apply failed (zone $zone_id): $err" \
        || log_info  "  NS/SOA applied (zone $zone_id)"
}

# ── Sync all records of a hestia_domain into its Bunny zone ──────────────────
# Strategy: delete all existing records owned by this hestia_domain, then
# push fresh ones from the conf file. Simple and reliable.
sync_domain() {
    local hestia_domain="$1" zone_domain="$2" zone_id="$3" user_hint="${4:-}"

    local user; user=$(find_user "$hestia_domain" "$user_hint") || {
        log_error "User not found for $hestia_domain"; return 1
    }
    local conf="$HESTIA_USER_DIR/$user/dns/$hestia_domain.conf"
    [ -f "$conf" ] || { log_warn "Conf not found: $conf"; return 0; }

    log_info "sync_domain: $hestia_domain → zone $zone_domain (id=$zone_id)"

    # 1. Delete existing Bunny records owned by this hestia_domain
    local old_id
    while IFS= read -r old_id; do
        [ -z "$old_id" ] && continue
        _api DELETE "/dnszone/${zone_id}/records/${old_id}" >/dev/null
        log_info "  -rec bunny_id=$old_id"
    done < <(rec_cache_owned_ids "$zone_domain" "$hestia_domain")
    rec_cache_purge "$zone_domain" "$hestia_domain"

    # 2. Push all active records from conf
    local line_id=1 pushed=0 skipped=0 failed=0

    while IFS= read -r line; do
        [ -z "$line" ] && { ((line_id++)); continue; }
        parse_line "$line"

        [ -z "$p_type" ] || [ "$p_type" = "SOA" ] && { ((line_id++)); continue; }

        # Skip apex NS — Bunny manages its own nameservers
        if [ "$p_type" = "NS" ]; then
            local rn="${p_record%.}"; rn="${rn%.${hestia_domain}}"
            if [ "$rn" = "@" ] || [ -z "$rn" ] || [ "$rn" = "$hestia_domain" ]; then
                log_info "  skip #$line_id NS apex (managed by Bunny)"
                ((skipped++)); ((line_id++)); continue
            fi
        fi

        if [ "$p_suspended" = "yes" ]; then
            log_info "  skip #$line_id $p_record $p_type (suspended)"
            ((skipped++)); ((line_id++)); continue
        fi

        local type_int; type_int=$(type_to_int "$p_type")
        if [ -z "$type_int" ]; then
            log_info "  skip #$line_id $p_type (not supported by Bunny)"
            ((skipped++)); ((line_id++)); continue
        fi

        local name; name=$(build_name "$p_record" "$hestia_domain" "$zone_domain")
        local body; body=$(build_record_body \
            "$type_int" "$name" "$p_value" "${p_ttl:-$DEFAULT_TTL}" "$p_priority" "$p_type")

        local resp rec_id
        resp=$(_api PUT "/dnszone/${zone_id}/records" "$body")
        rec_id=$(echo "$resp" | jq -r '.Id // empty' 2>/dev/null)

        if [ -n "$rec_id" ]; then
            rec_cache_set "$zone_domain" "$hestia_domain" "$line_id" "$rec_id"
            log_info "  +rec #$line_id $name $p_type → bunny_id=$rec_id"
            ((pushed++))
        else
            local err; err=$(echo "$resp" | jq -r '.Message // .ErrorKey // "?"' 2>/dev/null)
            log_error "  +rec #$line_id $name $p_type FAILED: $err"
            ((failed++))
        fi

        ((line_id++))
    done < "$conf"

    log_info "sync done: $hestia_domain | +$pushed skip=$skipped ERR=$failed"
}

# ── action_sync ───────────────────────────────────────────────────────────────
action_sync() {
    local hestia_domain="$1" user_hint="${2:-}"
    log_info "=== sync: $hestia_domain (user=${user_hint:-?}) ==="

    # Subdomain? Check if parent zone exists on Bunny
    local parent="${hestia_domain#*.}"
    if [[ "$hestia_domain" == *.*.* ]]; then
        local pid; pid=$(zone_get_id "$parent") || true
        if [ -n "$pid" ]; then
            if zone_exists_on_bunny "$parent" "$pid"; then
                log_info "$hestia_domain is subdomain → parent zone $parent (id=$pid)"
                sync_domain "$hestia_domain" "$parent" "$pid" "$user_hint"
                zone_apply_settings "$pid" "$parent"
                return $?
            fi
            log_warn "Parent zone $parent (id=$pid) gone from Bunny → clearing cache"
            zone_cache_del "$parent"
            rm -f "$(rec_cache_file "$parent")"
        fi
    fi

    # Get or create zone on Bunny
    local zone_id; zone_id=$(zone_get_id "$hestia_domain") || true

    if [ -n "$zone_id" ]; then
        if ! zone_exists_on_bunny "$hestia_domain" "$zone_id"; then
            log_warn "Zone $hestia_domain (id=$zone_id) gone from Bunny → recreating"
            zone_cache_del "$hestia_domain"
            rm -f "$(rec_cache_file "$hestia_domain")"
            zone_id=""
        fi
    fi

    if [ -z "$zone_id" ]; then
        local body resp
        body=$(jq -n --arg d "$hestia_domain" '{Domain:$d}')
        resp=$(_api POST "/dnszone" "$body")
        zone_id=$(echo "$resp" | jq -r '.Id // empty' 2>/dev/null)
        if [ -z "$zone_id" ]; then
            local err; err=$(echo "$resp" | jq -r '.Message // .ErrorKey // "?"' 2>/dev/null)
            log_error "Failed to create zone $hestia_domain: $err"
            return 1
        fi
        log_info "Zone CREATED: $hestia_domain (id=$zone_id)"
        zone_cache_set "$hestia_domain" "$zone_id"
    else
        log_info "Zone exists: $hestia_domain (id=$zone_id)"
    fi

    zone_apply_settings "$zone_id" "$hestia_domain"
    sync_domain "$hestia_domain" "$hestia_domain" "$zone_id" "$user_hint"
}

# ── action_delete ─────────────────────────────────────────────────────────────
action_delete() {
    local hestia_domain="$1" user_hint="${2:-}"
    log_info "=== delete: $hestia_domain ==="

    # Subdomain: remove only its records from parent zone
    local parent="${hestia_domain#*.}"
    if [[ "$hestia_domain" == *.*.* ]]; then
        local pid; pid=$(zone_get_id "$parent") || true
        if [ -n "$pid" ]; then
            log_info "$hestia_domain is subdomain → removing records from $parent"
            local old_id
            while IFS= read -r old_id; do
                [ -z "$old_id" ] && continue
                _api DELETE "/dnszone/${pid}/records/${old_id}" >/dev/null
                log_info "  -rec bunny_id=$old_id"
            done < <(rec_cache_owned_ids "$parent" "$hestia_domain")
            rec_cache_purge "$parent" "$hestia_domain"
            return 0
        fi
    fi

    # Root zone: delete entire Bunny zone
    local zone_id; zone_id=$(zone_get_id "$hestia_domain") || {
        log_warn "Zone not found on Bunny: $hestia_domain"
        return 0
    }
    _api DELETE "/dnszone/${zone_id}" >/dev/null
    log_info "Zone DELETED: $hestia_domain (id=$zone_id)"
    zone_cache_del "$hestia_domain"
    rm -f "$(rec_cache_file "$hestia_domain")"
}

# ── action_sync_all ───────────────────────────────────────────────────────────
action_sync_all() {
    local filter_user="${1:-}" users

    if [ -n "$filter_user" ]; then
        [ -d "$HESTIA_USER_DIR/$filter_user" ] || {
            echo "User not found: $filter_user"; exit 1
        }
        users="$filter_user"
    else
        users=$(ls "$HESTIA_USER_DIR" 2>/dev/null)
    fi

    local total=0 ok=0 fail=0
    for user in $users; do
        local dns_dir="$HESTIA_USER_DIR/$user/dns"
        [ -d "$dns_dir" ] || continue
        for conf in "$dns_dir"/*.conf; do
            [ -f "$conf" ] || continue
            local domain; domain=$(basename "$conf" .conf)
            ((total++))
            echo "→ $domain (user=$user)"
            action_sync "$domain" "$user" && ok=$((ok+1)) || fail=$((fail+1))
        done
    done

    echo ""
    echo "Total: $total | OK: $ok | Errors: $fail"
}

# ── action_debug ──────────────────────────────────────────────────────────────
action_debug() {
    local domain="$1"
    echo "=== DEBUG: $domain ==="

    local user; user=$(find_user "$domain") \
        && echo "HestiaCP user: $user" \
        || echo "HestiaCP user: not found"

    local conf="$HESTIA_USER_DIR/${user:-?}/dns/$domain.conf"
    if [ -f "$conf" ]; then
        echo ""
        echo "Records in HestiaCP conf:"
        local line_id=1
        while IFS= read -r line; do
            [ -z "$line" ] && { ((line_id++)); continue; }
            parse_line "$line"
            [ -z "$p_type" ] && { ((line_id++)); continue; }
            printf "  #%-3s %-8s %-30s %s\n" "$line_id" "$p_type" "$p_record" "$p_value"
            ((line_id++))
        done < "$conf"
    fi

    echo ""
    echo "Current records on Bunny:"
    local zone_id; zone_id=$(zone_get_id "$domain") || true
    if [ -n "$zone_id" ]; then
        echo "Zone ID: $zone_id"
        _api GET "/dnszone/${zone_id}" \
            | jq -r '.Records[] | "  \(.Name)\t\(.Type)\t\(.Value)"' 2>/dev/null
    else
        echo "Zone not found on Bunny"
    fi

    echo ""
    echo "Record cache:"
    local rcf; rcf=$(rec_cache_file "$domain")
    [ -f "$rcf" ] && jq '.' "$rcf" || echo "(empty)"
}

# ── MAIN ──────────────────────────────────────────────────────────────────────
case "${1:-}" in
    sync)     action_sync     "${2:?'Usage: $0 sync DOMAIN [USER]'}" "${3:-}" ;;
    delete)   action_delete   "${2:?'Usage: $0 delete DOMAIN [USER]'}" "${3:-}" ;;
    sync_all) action_sync_all "${2:-}" ;;
    debug)    action_debug    "${2:?'Usage: $0 debug DOMAIN'}" ;;
    *) echo "Usage: $0 {sync DOMAIN [USER]|delete DOMAIN [USER]|sync_all [USER]|debug DOMAIN}"; exit 1 ;;
esac
