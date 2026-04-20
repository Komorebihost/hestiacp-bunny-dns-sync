# HestiaCP → Bunny DNS Sync

Automatically synchronize DNS zones and records from [HestiaCP](https://hestiacp.com) to [Bunny.net DNS](https://bunny.net?ref=rkvns7hoyl) in real time.

When a DNS record is added, modified, or deleted in HestiaCP, this plugin detects the change and immediately syncs the zone to Bunny.net — no manual intervention required.

---

## Features

- **Real-time sync** — file watcher detects HestiaCP DNS changes instantly
- **Hook-based sync** — HestiaCP hooks trigger sync directly on domain add/delete, bypassing the inotifywait race condition that affects new users
- **User deletion support** — deleting a HestiaCP user automatically removes all their Bunny zones via the `v-delete-user` hook
- **Full record support** — A, AAAA, CNAME, MX, TXT, NS, SRV, CAA, PTR, RDR
- **Subdomain support** — subdomains managed by separate HestiaCP users are synced as prefixed records inside the parent zone (e.g. `shop.example.com` → records `shop`, `www.shop` inside the `example.com` zone)
- **Zone-owner priority** — if `domain.xx` already defines a record named `shop`, that record is never overridden when `shop.domain.xx` is synced; the zone owner always wins
- **Custom nameservers** — optionally apply your own NS1/NS2 and SOA email to every synced zone on Bunny
- **Automatic zone creation** — zones are created on Bunny when a new domain is added in HestiaCP
- **Automatic zone deletion** — zones are removed from Bunny when a domain is deleted in HestiaCP
- **Lock-based debounce** — prevents duplicate syncs when HestiaCP writes a file multiple times in quick succession
- **Compatible** — Ubuntu 20/22/24, Debian 11/12

---

## Requirements

- HestiaCP installed and running
- Bunny.net account with DNS enabled
- Bunny.net API Key with **Read & Write** permissions
- `jq`, `curl`, `inotify-tools` (installed automatically by `install.sh`)

---

## Installation

```bash
# 1. Clone the repository
git clone https://github.com/Komorebihost/hestiacp-bunny-dns-sync
cd hestiacp-bunny-dns-sync

# 2. Copy files to plugin directory
mkdir -p /usr/local/hestia/plugins/bunny-dns
cp -r bunny-dns.sh bunny-dns-watcher.sh bunny-dns.service config.conf.example install.sh hooks \
   /usr/local/hestia/plugins/bunny-dns/

# 3. Run installer
bash /usr/local/hestia/plugins/bunny-dns/install.sh

# 4. Configure your API key
nano /usr/local/hestia/plugins/bunny-dns/config.conf

# 5. Initial sync of all existing zones (also builds the user→domain cache)
/usr/local/hestia/plugins/bunny-dns/bunny-dns.sh sync_all
```

---

## Configuration

Edit `/usr/local/hestia/plugins/bunny-dns/config.conf`:

```bash
# Bunny.net API Key (required)
BUNNY_API_KEY="your_api_key_here"

# Default TTL for DNS records in seconds
DEFAULT_TTL=3600

# Custom nameservers (optional)
# If both are set, applied to every zone synced on Bunny.
# Leave empty to use Bunny defaults: kiki.bunny.net / coco.bunny.net
BUNNY_NS1=""
BUNNY_NS2=""

# SOA contact email (optional)
BUNNY_SOA_EMAIL=""
```

Get your API key at: **dash.bunny.net → Account → API Keys**

---

## How It Works

```
HestiaCP DNS change
       │
       ├─── inotifywait (file watcher)
       │         Detects .conf writes on existing domains
       │         Acquires lock → sleep 2s → bunny-dns.sh sync
       │
       └─── HestiaCP hooks
                 v-add-domain / v-add-dns-domain
                   sleep 3s → bunny-dns.sh sync         ← fixes new-user race condition
                 v-delete-domain / v-delete-dns-domain
                   bunny-dns.sh delete
                 v-delete-user
                   bunny-dns.sh delete_user              ← removes all user's zones

```

### Why two sync paths?

`inotifywait --recursive` watches the directory tree as it exists when the service starts. When HestiaCP creates a **new user**, it creates the full directory tree and writes the DNS conf file in a few milliseconds — faster than inotifywait can add a watch to the new directory. The `CLOSE_WRITE` event is lost, and the domain never appears on Bunny.

The HestiaCP hooks fix this: they are called directly by HestiaCP after each command succeeds, regardless of the filesystem watcher state. A 3-second sleep inside each hook gives HestiaCP time to finish writing all conf files before the sync runs.

### User deletion

When a HestiaCP user is deleted, HestiaCP removes their domains internally without triggering per-domain hooks. The `v-delete-user` hook handles the full cleanup by calling `bunny-dns.sh delete_user USERNAME`, which reads the user's domain list from the local cache (`mapping/users.json`) and removes each zone from Bunny.

The cache is populated automatically on every sync. If you upgraded from v2.1.0, run `sync_all` once to build it before deleting any users.

### Subdomain logic and zone-owner priority

If HestiaCP has both `example.com` (user A) and `shop.example.com` (user B):

- `example.com` gets its own Bunny zone
- Records from `shop.example.com` are synced as `shop`, `www.shop`, `mail.shop`, etc. **inside the `example.com` zone** — no separate zone is created for the subdomain

**Zone-owner priority:** if user A has already defined a record named `shop` in `example.com`, that record is never overridden when user B's `shop.example.com` is synced. The zone owner's records always win. This applies regardless of record type (A, CNAME, etc.).

When `shop.example.com` is modified, only its own prefixed records are updated. Records belonging to `example.com` are never touched.

### Custom nameservers

If `BUNNY_NS1` and `BUNNY_NS2` are set, the plugin applies them to every zone after each sync via the Bunny API (`POST /dnszone/{id}`). This lets you white-label your DNS with your own nameserver hostnames (e.g. `ns1.yourdomain.com`).

You will also need to create glue records at your domain registrar pointing `ns1` and `ns2` to Bunny's IP addresses:

| Nameserver | IPv4            | IPv6                  |
|------------|----------------|-----------------------|
| NS1        | `91.200.176.1`  | `2400:52e0:fff0::1`  |
| NS2        | `109.104.147.1` | `2400:52e0:fff2::1`  |

---

## Manual Commands

```bash
ENGINE=/usr/local/hestia/plugins/bunny-dns/bunny-dns.sh

# Sync a specific domain
$ENGINE sync example.com

# Sync all domains for a specific user
$ENGINE sync_all username

# Sync all domains on the server
$ENGINE sync_all

# Delete a zone from Bunny
$ENGINE delete example.com

# Delete all Bunny zones for a user (normally called automatically by v-delete-user hook)
$ENGINE delete_user username

# Debug: show HestiaCP records, current Bunny state and cache info
$ENGINE debug example.com
```

---

## Service Management

```bash
# Check watcher status
systemctl status bunny-dns

# View live log
tail -f /usr/local/hestia/plugins/bunny-dns/bunny-dns.log

# Restart watcher
systemctl restart bunny-dns
```

---

## File Structure

```
/usr/local/hestia/plugins/bunny-dns/
├── bunny-dns.sh              # Main sync engine
├── bunny-dns-watcher.sh      # inotifywait file watcher
├── bunny-dns.service         # systemd unit
├── config.conf               # Your configuration (not in repo)
├── config.conf.example       # Configuration template
├── install.sh                # Installer
├── bunny-dns.log             # Runtime log
├── hooks/                    # HestiaCP hook scripts (installed to /usr/local/hestia/data/hooks/)
│   ├── v-add-domain          #   → sync on domain creation
│   ├── v-delete-domain       #   → delete on domain removal
│   ├── v-add-dns-domain      #   → sync on DNS-only zone creation
│   ├── v-delete-dns-domain   #   → delete on DNS-only zone removal
│   └── v-delete-user         #   → delete all zones when a user is removed
└── mapping/
    ├── zones.json              # Zone ID cache          {"domain": zone_id}
    ├── records_DOMAIN.json     # Record ID cache per zone
    └── users.json              # User → domains cache   {"user": ["domain1", "domain2"]}
```

> If a hook file already exists in `/usr/local/hestia/data/hooks/` (from another plugin), `install.sh` appends the Bunny DNS logic instead of overwriting it.

---

## Update

```bash
# 1. Download the latest version
git clone https://github.com/Komorebihost/hestiacp-bunny-dns-sync /tmp/bunny-dns-update

# 2. Copy scripts — config.conf is never overwritten
cp /tmp/bunny-dns-update/bunny-dns.sh          /usr/local/hestia/plugins/bunny-dns/
cp /tmp/bunny-dns-update/bunny-dns-watcher.sh  /usr/local/hestia/plugins/bunny-dns/
cp /tmp/bunny-dns-update/bunny-dns.service     /usr/local/hestia/plugins/bunny-dns/
cp /tmp/bunny-dns-update/install.sh            /usr/local/hestia/plugins/bunny-dns/
cp -r /tmp/bunny-dns-update/hooks              /usr/local/hestia/plugins/bunny-dns/

# 3. Re-run the installer (idempotent — skips anything already in place)
bash /usr/local/hestia/plugins/bunny-dns/install.sh

# 4. Cleanup
rm -rf /tmp/bunny-dns-update
```

> `config.conf`, `mapping/`, and any pre-existing hooks from other plugins are **never modified** during an update.

### Updating from v2.1.0 to v2.2.0

v2.1.0 is missing `v-delete-user` and the user→domain cache. Run the update procedure above, then:

```bash
# Rebuild cache and populate users.json
/usr/local/hestia/plugins/bunny-dns/bunny-dns.sh sync_all
```

### Updating from v2.0.0 to v2.2.0

Run the update procedure above — `install.sh` installs all hooks automatically.  
Then run `sync_all` once to build the user→domain cache.

---

## Uninstall

```bash
# Stop and remove the service
systemctl stop bunny-dns
systemctl disable bunny-dns
rm -f /etc/systemd/system/bunny-dns.service
systemctl daemon-reload

# Remove hooks (only if no other plugin shares them)
for hook in v-add-domain v-delete-domain v-add-dns-domain v-delete-dns-domain v-delete-user; do
    rm -f /usr/local/hestia/data/hooks/$hook
done


# Remove plugin directory
rm -rf /usr/local/hestia/plugins/bunny-dns
```

> If `install.sh` had appended to a shared hook file (instead of creating it), remove only the `# --- bunny-dns ---` block manually rather than deleting the whole file.

---

## Disclaimer

> This plugin is an independent, community-developed tool by [Komorebihost](https://komorebihost.com). It is **not affiliated with, endorsed by, or supported by** Bunny.net or HestiaCP.
>
> Use at your own risk. Always keep backups of your DNS configuration before performing bulk sync operations. The authors accept no responsibility for DNS outages, data loss, or misconfiguration resulting from the use of this software.
>
> Bunny.net API usage is subject to [Bunny.net Terms of Service](https://bunny.net?ref=rkvns7hoyl).

---

## License

MIT License — © 2024 [Komorebihost](https://komorebihost.com)

Permission is hereby granted, free of charge, to any person obtaining a copy of this software to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the software, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

**THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.**

---

## Contributing

Issues and pull requests are welcome.  
Repository: [github.com/Komorebihost/hestiacp-bunny-dns-sync](https://github.com/Komorebihost/hestiacp-bunny-dns-sync)  
Website: [komorebihost.com](https://komorebihost.com)
