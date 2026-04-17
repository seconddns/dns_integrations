# Nagios / Icinga Check Plugin for SecondDNS

Monitors DNS zone health via the SecondDNS API. Returns standard Nagios exit codes with perfdata.

## Requirements

- `bash`, `curl`, `grep`
- SecondDNS API key ([Dashboard → API Key](https://seconddns.com/dashboard/api-key))

## Installation

```bash
curl -o /usr/lib/nagios/plugins/check_seconddns.sh \
  https://raw.githubusercontent.com/0kaba0hub/dns_integrations/main/nagios_plugins/check_seconddns.sh

chmod +x /usr/lib/nagios/plugins/check_seconddns.sh
```

## Usage

```
check_seconddns.sh -k <API_KEY> [-u <URL>] [-t <TIMEOUT>] [-z <ZONE>]

Options:
  -k KEY       X-API-Key (required, or set SECONDDNS_API_KEY env)
  -u URL       API base URL (default: https://seconddns.com)
  -t SECONDS   Connection + response timeout (default: 30)
  -z ZONE      Check a single zone by name (default: all zones)
  -h           Show help
```

### Examples

```bash
# Check all zones
./check_seconddns.sh -k your-api-key

# Check a single zone
./check_seconddns.sh -k your-api-key -z example.com

# Custom timeout
./check_seconddns.sh -k your-api-key -t 10

# Using environment variable
export SECONDDNS_API_KEY="your-api-key"
./check_seconddns.sh
./check_seconddns.sh -z example.com
```

## Nagios Configuration

### Command definition

Add to `/etc/nagios/objects/commands.cfg`:

```
define command {
    command_name    check_seconddns
    command_line    /usr/lib/nagios/plugins/check_seconddns.sh -k $ARG1$ $ARG2$
}
```

### Service — all zones

```
define service {
    host_name               your-dns-host
    service_description     SecondDNS Zone Health
    check_command           check_seconddns!your-api-key-here!
    check_interval          15
    retry_interval          5
    max_check_attempts      3
    notification_interval   60
}
```

### Service — single zone

```
define service {
    host_name               your-dns-host
    service_description     SecondDNS: example.com
    check_command           check_seconddns!your-api-key-here!-z example.com
    check_interval          15
    retry_interval          5
    max_check_attempts      3
    notification_interval   60
}
```

## Output

```
# All zones healthy:
OK - all 12 zones synced

# Problems detected:
WARNING - example.com stale 135min master=2024041503 ours=2024041501 | stale_min=135;120;360
CRITICAL - broken.net master_unreachable since 2026-04-16T13:00:00Z | stale_min=390;120;360
```

## Exit Codes

| Code | Status | Meaning |
|------|--------|---------|
| 0 | OK | All zones synced |
| 1 | WARNING | One or more zones stale |
| 2 | CRITICAL | Master unreachable or NS error |
| 3 | UNKNOWN | API unreachable, missing key, or unexpected response |

## Perfdata

Each problem line includes `stale_min=VALUE;WARN;CRIT` for graphing:
- `VALUE` — minutes since zone went stale
- `WARN` — stale threshold (from zone or global config)
- `CRIT` — 3× stale threshold
