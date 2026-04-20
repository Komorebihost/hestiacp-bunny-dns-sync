# HestiaCP Fail2Ban — Jails & Filters for Hestia, WordPress & Roundcube

Hardened Fail2Ban configuration for servers running [HestiaCP](https://hestiacp.com).  
Protects the control panel, Roundcube webmail, Nginx virtual hosts and WordPress installations with ready-to-use jails and filters.

---

## Features

- **Hestia panel jail** — monitors Nginx errors on ports `8083`/`8087`
- **Roundcube webmail jail** — blocks brute-force login attempts on webmail
- **Nginx domains jail** — watches all virtual host error logs for suspicious activity
- **WordPress jail** — detects and bans probes for common malicious PHP shells (`xmlrpc.php`, `wp-is.php`, `shell.php`, etc.)
- **IP whitelist** — global `ignoreip` via `jail.local` to prevent locking yourself out
- **Manual ban/unban** — quick reference commands included
- **iptables hardening** — persistent blocking of known-bad IP ranges via `iptables-persistent`

---

## Requirements

- HestiaCP installed and running
- Fail2Ban ≥ 0.10
- Nginx as web server
- Roundcube (if using webmail jail)
- `iptables-persistent` (installed automatically by `install.sh`)

---

## Installation

```bash
git clone https://github.com/Komorebihost/hestiacp-failtoban.git
cd hestiacp-failtoban
chmod +x install.sh
sudo ./install.sh
```

The script will:
1. Install jails for Hestia panel, Roundcube and Nginx domains
2. Install the WordPress filter and jail
3. Restart Fail2Ban and verify all jails are active

---

## Files

| File | Description |
|------|-------------|
| `install.sh` | Automated installer |
| `jail.d/hestia-base.conf` | Jails for Hestia panel, Roundcube and Nginx domains |
| `jail.d/hestia-wordpress.conf` | Jail for WordPress shell probes |
| `filter.d/nginx-wordpress.conf` | Filter rules for WordPress attacks |

---

## Manual Usage

### Check jail status
```bash
fail2ban-client status nginx-wordpress
fail2ban-client status nginx-hestia-panel
fail2ban-client status roundcube-auth
```

### Ban an IP manually
```bash
fail2ban-client set nginx-hestia-panel banip 1.2.3.4
```

### Unban an IP
```bash
fail2ban-client set nginx-hestia-panel unbanip 1.2.3.4
```

### Add an IP to the global whitelist
Edit `/etc/fail2ban/jail.local` and add your IP to `ignoreip`:
```ini
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 YOUR.IP.HERE
```
Then restart: `systemctl restart fail2ban`

Or set it at runtime (temporary, resets on restart):
```bash
fail2ban-client set nginx-hestia-panel addignoreip YOUR.IP.HERE
```

### Block IPs permanently with iptables
```bash
iptables -A INPUT -s 1.2.3.4 -j DROP
netfilter-persistent save
```

---

## Quick Health Check

```bash
systemctl status hestia fail2ban --no-pager | grep -E "Active|Memory"
fail2ban-client status nginx-hestia-panel | grep "Banned IP"
```

---

## Disclaimer

> This project is an independent, community-developed tool. It is **not affiliated with, endorsed by, or supported by** HestiaCP.
>
> Use at your own risk. Always back up your existing Fail2Ban configuration before running the installer. The authors accept no responsibility for data loss, service disruptions, or misconfiguration resulting from the use of this software.

---

## License

MIT License — © 2025 [Komorebihost](https://komorebihost.com)

Permission is hereby granted, free of charge, to any person obtaining a copy of this software to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the software, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the software.

**THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.**

---

## Contributing

Issues and pull requests are welcome.  
Repository: [github.com/Komorebihost/hestiacp-failtoban](https://github.com/Komorebihost/hestiacp-failtoban)
