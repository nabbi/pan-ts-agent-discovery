# Troubleshooting

## Log files

Both scripts append stdout to log files when run from cron:

| Script | Log |
|--------|-----|
| discover.tcl | `/var/log/paloalto/pan-tsagent-discover.log` |
| purge.tcl | `/var/log/paloalto/pan-tsagent-purge.log` |

Syslog messages are also written via `logger` at `user.info` and `user.error` levels.

### Reviewing logs

Tail a running discovery:

```shell
tail -f /var/log/paloalto/pan-tsagent-discover.log
```

Search syslog for recent activity:

```shell
grep ts-agent /var/log/syslog
# or journalctl
journalctl -t discover.tcl --since "1 hour ago"
```

### Log output format

A normal discovery run looks like:

```
## Start PAN TS Agent Discovery 2024-01-15 09:15

## ICMP discovery

## probing 42 hosts for TS Agents and comparing against existing config

new server01 agent found
## Discovered 42, Adding 1 new agents

## End PAN TS Agent Discovery 2024-01-15 09:17
```

A normal purge run looks like:

```
## Start PAN TS Agent Purge 2024-01-15 05:30

## Checking firewall for stale TS Agents

delete server99 idle agent
## Not Connected 3, Deleting 1 stale agents from configs

## End PAN TS Agent Purge 2024-01-15 05:31
```

### Verbosity

Both scripts have verbosity flags at the top of the file:

```tcl
set info 1    ;# standard operational output
set debug 0   ;# detailed per-host decisions (skip/keep/new/none)
set trace 0   ;# raw data dumps (alive list, panorama config)
```

Set `debug` to `1` to see why individual hosts are skipped or kept. Set `trace` to `1` to dump full intermediate data.

## PAN-OS CLI checks

### View configured TS Agents in Panorama

```
> configure
# show | match "ts-agent.*host"
```

### View TS Agent status on firewall

```
> show user ts-agent statistics
> show user ts-agent statistics | match not-conn
```

### Verify commit history

```
> show jobs all
```

## Common errors

### Timeout occurred

```
## Timeout occurred. Did not get the expected prompt!
```

The SSH session to Panorama or the firewall did not respond within the 45-second timeout. Check network connectivity, SSH access, and that the device is not under heavy load (e.g. a pending commit).

### SSH failure / Password incorrect

```
SSH failure for fw-hostname
Login failed. Password incorrect.
```

Verify `config(username)` and `config(password)` in `config.tcl`. Confirm the account is not locked and SSH is enabled on the management interface.

### HA sync warning

```
## local firewall config not synced
```

Panorama's running config is out of sync with the HA peer. Sync before retrying:

```
> request high-availability sync-to-remote running-config
```

### Object doesn't exist (exit 65)

```
## Did you attempt to delete a record which was not present!?
```

Purge tried to delete a TS Agent that was already removed from the Panorama template. This can happen if another admin or process deleted the agent between the firewall query and the Panorama commit. Usually harmless on the next run.

### Error with exit code 104 (ECONNRESET)

```
## Error server01.example.com 104 ##
```

The TLS connection to port 5009 was reset. The TS Agent service may be starting up or shutting down. The host is skipped for this run and will be retried on the next cycle.

### fping errors (exit 2+)

```
## Error 2 ##
```

fping exit codes: `0` = all reachable, `1` = some unreachable (normal for subnet scans), `2` = IP not found, `3` = invalid arguments, `4` = system call failure. Exit codes 2+ are fatal and halt the script. Check that the `config(networks)` CIDR notation is valid.

### No DNS PTR record

When `config(dns)` is enabled and a host has no reverse PTR record, the host is silently skipped. If agents are consistently missed, verify reverse DNS is configured:

```shell
dig -x 10.10.10.5 +short
```

The returned PTR must also have a matching forward A record.

### Too many agents configured (platform capacity exceeded)

PAN-OS enforces a maximum number of configured TS Agents per firewall platform/model. The limit is documented per hardware/VM-Series model and PAN-OS version in the official [Terminal Server (TS) Agent compatibility matrix](https://docs.paloaltonetworks.com/compatibility-matrix/reference/terminal-services-ts-agent) — it ranges from 400 on smaller platforms up to 2,500 on the high end (e.g. PA-7000 Series with SMC-B, VM-700).

When a `commit-all template-stack` push would exceed a managed firewall's TS Agent capacity, PAN-OS rejects it with a platform-capacity validation error. This is the same error class Panorama uses for other object types, e.g.:

```
Error: Number of services (xxxx) exceeds platform capacity (yyyy) (Module: device)
Commit failed
```

This ceiling can be reached two ways:

1. **Genuine growth** — more Citrix/XenApp hosts are online and discovered than the target firewall model supports.
2. **`purge.tcl` is not removing stale agents** — if the purge cron job has stopped running or is failing, idle agents accumulate indefinitely until the total crosses the platform limit.

To check which of these applies:

```
> configure
# show | match "ts-agent.*host"
```

Count the results and compare against the platform's documented maximum for the firewall model and PAN-OS version (link above). Then check whether `purge.tcl` is actually running and succeeding:

```shell
tail -100 /var/log/paloalto/pan-tsagent-purge.log
crontab -l
```

Look for gaps in the purge log's timestamps or repeated non-zero exits — either indicates the purge cron job isn't keeping the configured agent count down.

**Detection caveat:** `myexpect.exp` only recognizes a small set of named PAN-OS strings (`Unknown command`, `Object doesn't exist`, the HA sync warning); anything else, including a platform-capacity commit failure, falls through to the generic `-nocase "error"`/`-nocase "fail"` match and is reported simply as `## unknown error -- please report this condition`. If a `commit-all` push to a large template stack is slow enough to exceed the 45-second `timeout`, the same failure can instead surface as `Timeout occurred`. In both cases, the actual PAN-OS response text is captured immediately above that line in the log (via `myexec`'s `log "info" "$args $results"`) — check it for the real error rather than relying on the generic message.

**Config drift caveat:** `discover.tcl`'s "already configured" check (`tsagent-configured.exp`) reads the configuration in configure mode, which reflects the *candidate* config, not the committed/running config. If a `set template ... ts-agent ...` edit lands in the candidate config but the following commit or commit-all then fails (e.g. due to platform capacity), that host will still be reported as "already configured" on the next discovery run and won't be retried or re-flagged. If an agent seems to have gone missing without ever reappearing as newly discovered, cross-check Panorama for a failed or partial commit job around the relevant timestamp:

```
> show jobs all
> show jobs id <job-id>
```

## Manual verification

### Test ICMP reachability

```shell
fping -a -g 10.10.10.0/24
```

### Test TS Agent TLS on port 5009

```shell
echo | timeout 2 openssl s_client -showcerts -connect 10.10.10.5:5009 2>/dev/null | openssl x509 -inform pem -noout -text 2>/dev/null | grep "Terminal Server Agent"
```

A match confirms the agent is running and presenting the expected certificate.

### Test reverse DNS

```shell
dig -t ptr -x 10.10.10.5 +short
```
