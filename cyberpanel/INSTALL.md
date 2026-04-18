# CyberPanel — Installation

## Requirements

- CyberPanel 2.x+ with PowerDNS
- Root access
- SecondDNS API key — [get one here](https://seconddns.com/dashboard/api-key)

## Install

```bash
curl -sL https://raw.githubusercontent.com/0kaba0hub/dns_integrations/main/cyberpanel/install.sh \
  | bash -s -- --api-key=YOUR_API_KEY
```

## Uninstall

```bash
curl -sL https://raw.githubusercontent.com/0kaba0hub/dns_integrations/main/cyberpanel/uninstall.sh \
  | bash
```

## Troubleshooting

**Check logs:**
```bash
tail -f /var/log/seconddns.log
```

**Re-register signals after CyberPanel update:**
```bash
seconddns ensure-signals && systemctl restart lscpd
```

**Verify AXFR config:**
```bash
grep -E "^master=|^allow-axfr-ips=|^also-notify=" /etc/pdns/pdns.conf
```
