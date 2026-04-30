# dns_integrations

Integrations for [SecondDNS](https://seconddns.com) secondary DNS service.

## Hosting Panels

| Directory | Description |
|-----------|-------------|
| [hosting-panels/cyberpanel/](hosting-panels/cyberpanel/) | CyberPanel hosting panel — auto-sync zones on domain create/delete. Tested on CyberPanel v2.4.5 |
| [hosting-panels/directadmin/](hosting-panels/directadmin/) | DirectAdmin hosting panel — auto-sync zones via dns_create_post / dns_delete_post. Tested on DA 1.699 |
| [hosting-panels/plesk/](hosting-panels/plesk/) | Plesk hosting panel — auto-sync zones on domain create/delete/rename via Event Manager |

## Monitoring

| Directory | Description |
|-----------|-------------|
| [nagios_plugins/](nagios_plugins/) | Nagios / Icinga health check plugin |
| [zabbix_templates/](zabbix_templates/) | Zabbix HTTP Agent template with triggers |

See README.md in each directory for installation and usage.
