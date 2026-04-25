# dns_integrations

Integrations for [SecondDNS](https://seconddns.com) secondary DNS service.

| Directory | Description |
|-----------|-------------|
| [cyberpanel/](cyberpanel/) | CyberPanel plugin — auto-sync zones on domain create/delete. Tested on CyberPanel v2.4.5 |
| [directadmin/](directadmin/) | DirectAdmin hooks — auto-sync zones via dns_create_post / dns_delete_post. Tested on DA 1.699 |
| [plesk/](plesk/) | Plesk event handlers — auto-sync zones on domain create/delete via Event Manager |
| [nagios_plugins/](nagios_plugins/) | Nagios / Icinga health check plugin |
| [zabbix_templates/](zabbix_templates/) | Zabbix HTTP Agent template with triggers |

See README.md in each directory for installation and usage.
