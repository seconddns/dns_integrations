# Zabbix Template for SecondDNS

Monitors DNS zone health via the SecondDNS API. Polls every 5 minutes, extracts counters with JSONPath, fires triggers on problems.

## Requirements

- Zabbix Server 7.0+ LTS
- SecondDNS API key ([Dashboard → API Key](https://seconddns.com/dashboard/api-key))

## Installation

### 1. Download

```bash
curl -O https://raw.githubusercontent.com/0kaba0hub/dns_integrations/main/zabbix_templates/seconddns_health.yaml
```

### 2. Import

1. Go to **Data collection → Templates → Import**
2. Select `seconddns_health.yaml`
3. Click **Import**

### 3. Link to a host

Link the template **SecondDNS Health** to any host (can be the Zabbix server itself — the checks are HTTP-based, no agent needed).

### 4. Set macros

On the linked host, configure the macros:

| Macro | Type | Value |
|-------|------|-------|
| `{$SECONDDNS_API_URL}` | Text | `https://seconddns.com` (default, change if self-hosted) |
| `{$SECONDDNS_API_KEY}` | Secret text | Your API key |

## What the template provides

### Items

| Item | Type | Key | Interval | Description |
|------|------|-----|----------|-------------|
| Zone health JSON | HTTP Agent | `seconddns.health.json` | 5m | Raw JSON from `/api/health/zones` |
| Total zones | Dependent | `seconddns.zones.total` | — | `$.summary.total` |
| Synced zones | Dependent | `seconddns.zones.synced` | — | `$.summary.synced` |
| Stale zones | Dependent | `seconddns.zones.stale` | — | `$.summary.stale` |
| Master unreachable | Dependent | `seconddns.zones.master_unreachable` | — | `$.summary.masterUnreachable` |
| Nagios output | HTTP Agent | `seconddns.health.nagios` | 5m | Plain text from `?format=nagios` |

The master item (`seconddns.health.json`) makes one HTTP call. All counter items are **dependent** — they extract values via JSONPath with zero extra network traffic.

### Triggers

| Trigger | Severity | Expression |
|---------|----------|------------|
| Zone(s) stale | **Warning** | `last(seconddns.zones.stale) > 0` |
| Zone(s) master unreachable | **High** | `last(seconddns.zones.master_unreachable) > 0` |
| Health API not responding | **High** | No data for 30 minutes |

### Graphs & Latest data

- **Total / Synced / Stale / Unreachable** counters are available for custom graphs and dashboards
- **Nagios output** item shows human-readable text in **Latest data** — useful for quick overview without opening the API

## How it works

```
Every 5 minutes:
  Zabbix HTTP Agent → GET /api/health/zones → JSON response
                                                 ↓
                                    JSONPath preprocessing
                                    ├── $.summary.total → seconddns.zones.total
                                    ├── $.summary.synced → seconddns.zones.synced
                                    ├── $.summary.stale → seconddns.zones.stale
                                    └── $.summary.masterUnreachable → seconddns.zones.master_unreachable
                                                 ↓
                                    Trigger evaluation
                                    ├── stale > 0 → WARNING
                                    └── masterUnreachable > 0 → HIGH

  Zabbix HTTP Agent → GET /api/health/zones?format=nagios → plain text
                      (for "Latest data" view, no triggers attached)
```

## Customization

- **Change polling interval**: Edit the master item `seconddns.health.json` → Interval
- **Adjust trigger thresholds**: e.g. fire only when stale > 2: `last(seconddns.zones.stale) > 2`
- **Add per-zone monitoring**: Use LLD (Low-Level Discovery) on the `zones` array from the JSON response to create per-zone items and triggers. Not included by default to keep the template simple.
