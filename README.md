# HestiaCP → Bunny DNS Sync

Automatically synchronize DNS zones and records from [HestiaCP](https://hestiacp.com) to [Bunny.net DNS](https://bunny.net?ref=rkvns7hoyl) in real time.

When a DNS record is added, modified, or deleted in HestiaCP, this plugin detects the change via `inotifywait` and immediately syncs the zone to Bunny.net — no manual intervention required.

---

## Features

- **Real-time sync** — file watcher detects HestiaCP DNS changes instantly
- **Full record support** — A, AAAA, CNAME, MX, TXT, NS, SRV, CAA, PTR, RDR
- **Subdomain support** — subdomains managed by separate HestiaCP users are synced as prefixed records inside the parent zone (e.g. `shop.example.com` → records `shop`, `www.shop` inside the `example.com` zone)
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
cp bunny-dns.sh bunny-dns-watcher.sh bunny-dns.service config.conf.example install.sh \
   /usr/local/hestia/plugins/bunny-dns/

# 3. Run installer
bash /usr/local/hestia/plugins/bunny-dns/install.sh

# 4. Configure your API key
nano /usr/local/hestia/plugins/bunny-dns/config.conf

# 5. Initial sync of all existing zones
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
       ▼
inotifywait detects .conf file write
       │
       ▼
Lock acquired (prevents duplicate syncs)
       │
       ▼  sleep 2s (waits for HestiaCP to finish all writes)
bunny-dns.sh sync DOMAIN
       │
       ├─ Zone exists on Bunny? → delete old records → push fresh records
       │
       └─ Zone missing? → create zone → push records
```

### Subdomain logic

If HestiaCP has both `example.com` (user A) and `shop.example.com` (user B):

- `example.com` gets its own Bunny zone
- Records from `shop.example.com` are synced as `shop`, `www.shop`, `mail.shop`, etc. **inside the `example.com` zone** — no separate zone is created for the subdomain

When `shop.example.com` is modified, only its prefixed records are updated. Records belonging to `example.com` are never touched.

### Custom nameservers

If `BUNNY_NS1` and `BUNNY_NS2` are set, the plugin applies them to every zone after each sync via the Bunny API (`POST /dnszone/{id}`). This lets you white-label your DNS with your own nameserver hostnames (e.g. `ns1.yourdomain.com`).

You will also need to create glue records at your domain registrar pointing `ns1` and `ns2` to Bunny's IP addresses:

| Nameserver | IPv4          | IPv6                  |
|------------|---------------|-----------------------|
| NS1        | `91.200.176.1`  | `2400:52e0:fff0::1` |
| NS2        | `109.104.147.1` | `2400:52e0:fff2::1` |

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

# Debug: show HestiaCP records and current Bunny state
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
├── bunny-dns.sh          # Main sync engine
├── bunny-dns-watcher.sh  # inotifywait file watcher
├── bunny-dns.service     # systemd unit
├── config.conf           # Your configuration (not in repo)
├── config.conf.example   # Configuration template
├── install.sh            # Installer
├── bunny-dns.log         # Runtime log
└── mapping/
    ├── zones.json              # Zone ID cache {"domain": zone_id}
    └── records_DOMAIN.json     # Record ID cache per zone
```

---

## Update

To update the plugin without losing your configuration:

```bash
# Download the latest version
git clone https://github.com/Komorebihost/hestiacp-bunny-dns-sync /tmp/bunny-dns-update

# Copy only the scripts — config.conf is never overwritten
cp /tmp/bunny-dns-update/bunny-dns.sh        /usr/local/hestia/plugins/bunny-dns/
cp /tmp/bunny-dns-update/bunny-dns-watcher.sh /usr/local/hestia/plugins/bunny-dns/
cp /tmp/bunny-dns-update/bunny-dns.service    /usr/local/hestia/plugins/bunny-dns/
cp /tmp/bunny-dns-update/install.sh           /usr/local/hestia/plugins/bunny-dns/

# Set permissions
chmod 750 /usr/local/hestia/plugins/bunny-dns/bunny-dns.sh
chmod 750 /usr/local/hestia/plugins/bunny-dns/bunny-dns-watcher.sh

# Restart watcher
systemctl restart bunny-dns

# Cleanup
rm -rf /tmp/bunny-dns-update
```

> `config.conf` and `mapping/` are **never touched** during an update.

---

## Uninstall

```bash
systemctl stop bunny-dns
systemctl disable bunny-dns
rm -f /etc/systemd/system/bunny-dns.service
systemctl daemon-reload
rm -rf /usr/local/hestia/plugins/bunny-dns
```

---

## Disclaimer

> This plugin is an independent, community-developed tool. It is **not affiliated with, endorsed by, or supported by** Bunny.net or HestiaCP.
>
> Use at your own risk. Always keep backups of your DNS configuration before performing bulk sync operations. The authors accept no responsibility for DNS outages, data loss, or misconfiguration resulting from the use of this software.
>
> Bunny.net API usage is subject to [Bunny.net Terms of Service](https://bunny.net?ref=rkvns7hoyl).

---

## License

MIT License — © 2024 [Komorebihost](https://komorebihost.com)

Permission is hereby granted, free of charge, to any person obtaining a copy of this software to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the software, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the software.

**THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.**

---

## Contributing

Issues and pull requests are welcome.  
Repository: [github.com/Komorebihost/hestiacp-bunny-dns-sync](https://github.com/Komorebihost/hestiacp-bunny-dns-sync)
