# dns_integrations

Hosting panel integrations for secondary DNS service.

## Supported Panels

| Panel | Directory | Status |
|---|---|---|
| CyberPanel | [cyberpanel/](cyberpanel/) | Ready |

## How It Works

1. Register an account at your secondary DNS service
2. Get your API key from Dashboard → API Key
3. Install the integration on your hosting server
4. New domains are automatically registered as secondary zones
5. Zone transfers (AXFR) happen automatically

## API

All integrations use the same REST API:

```
GET    /api/zones                    — List zones
POST   /api/zones                    — Add zone { "name": "example.com", "masterIp": "1.2.3.4" }
GET    /api/zones/by-name/{name}     — Find zone by domain name
DELETE  /api/zones/{id}               — Remove zone
```

Authentication: `X-API-Key` header.
