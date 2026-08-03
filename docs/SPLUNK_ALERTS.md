# Splunk Alerts

SPL and alert definitions for the `error`-level events the scripts write to syslog,
assuming host syslog is already flowing into Splunk (no file monitoring/onboarding
covered here).

## Log format

Both scripts log through the shared `log` proc in `src/inc/common-proc.tcl`:

```tcl
exec logger -p user.${level} "[info script] ${m}"
```

The invoking script's path (e.g. `.../discover.tcl` or `.../purge.tcl`) is the first
token of the message body -- it's plain text in the message, not a separate syslog
field, so match it as a substring rather than a `tag=` field. Adjust
`sourcetype`/`index` below to whatever your syslog input uses (commonly
`sourcetype=syslog`).

**Scope note:** some errors documented in
[TROUBLESHOOTING.md](TROUBLESHOOTING.md#common-errors) -- SSH failure, session
timeout, HA sync warning, platform capacity exceeded, unrecognized PAN-OS error -- are
written via `send_user` in the `.exp` scripts, not the `log` proc, so they never reach
syslog; they only land in the cron-redirected file logs. They're excluded here for
that reason. If you need alerting on those too, they'd need forwarding the file logs
separately, or routing `.exp` output through `log`.

## Alert catalog

Discovery runs hourly (`:15`), purge runs daily (`05:30`) -- see
[INSTALL.md](INSTALL.md#crontab). Size each search window to comfortably cover one
cron interval.

| # | Condition | Source | Log line matched |
|---|-----------|--------|-------------------|
| 1 | Suspicious PTR record rejected | discover.tcl | `suspicious PTR record for * skipping:` |
| 2 | Could not parse `not-conn` line | purge.tcl | `purge: could not parse not-conn line, skipping:` |
| 3 | TS Agent TLS probe error (incl. ECONNRESET) | discover.tcl (mytsagent) | `<host> <status>` after myexec/mytsagent error |
| 4 | Reverse DNS lookup failed | discover.tcl (mydig) | `mydig <ip> <status> ...` |
| 5 | fping fatal error (exit 2+) | discover.tcl (myfping) | `<args> <status> <results>` |

### 1. Suspicious PTR record rejected

Security-relevant: fires when `discover.tcl`'s PTR validation (`^[A-Za-z0-9._-]+$`)
rejects a value that would otherwise flow unsanitized into a PAN-OS CLI command. A
single hit can be a DNS misconfiguration; a burst, or one from an unexpected subnet,
warrants checking who controls that PTR record.

```spl
index=paloalto sourcetype=syslog "discover.tcl" "suspicious PTR record"
| rex field=_raw "suspicious PTR record for (?<ip>\S+), skipping: (?<ptr_value>.+)$"
| table _time ip ptr_value
```

### 2. Could not parse `not-conn` line

Doesn't abort the run -- alert on repeats of the *same* line rather than a single
occurrence, since one-off CLI formatting glitches are expected:

```spl
index=paloalto sourcetype=syslog "purge.tcl" "could not parse not-conn line"
| rex field=_raw "skipping: (?<line>.+?) \("
| stats count by line
| where count > 1
```

### 3. TS Agent TLS probe error

Covers any non-1 exit from the port 5009 probe, including the ECONNRESET (104) case
noted in TROUBLESHOOTING.md. Expected occasionally; alert on volume rather than any
single hit:

```spl
index=paloalto sourcetype=syslog "discover.tcl" "## Error"
| stats count
| where count > 5
```

### 4. Reverse DNS lookup failed

`mydig` errors are fatal -- they `exit 1` and halt `discover.tcl` -- so alert on any
occurrence:

```spl
index=paloalto sourcetype=syslog "discover.tcl" "mydig"
```

### 5. fping fatal error

Also fatal (halts `discover.tcl`). `exit 1` (some hosts unreachable) is normal for
subnet scans and excluded; anything else (`2`+) is not:

```spl
index=paloalto sourcetype=syslog "discover.tcl" "## Error"
| rex field=_raw "## Error (?<exit_code>\d+)"
| search exit_code!=1
```

Note searches 3 and 5 share the same `"## Error"` text pattern from `myexec`'s
generic error path -- if you need to tell them apart in Splunk, that requires
distinguishing the message content further (e.g. `mytsagent` errors carry only a
host and status code, `myfping` errors carry the fping args) rather than the log
proc adding separate markers.

## Example `savedsearches.conf`

```conf
[PAN TS Agent - suspicious PTR record rejected]
search = index=paloalto sourcetype=syslog "discover.tcl" "suspicious PTR record"
dispatch.earliest_time = -15m
dispatch.latest_time = now
cron_schedule = */15 * * * *
alert.severity = 4
alert.suppress = 1
alert.suppress.period = 1h
alert.suppress.fields = ip
counttype = number of events
relation = greater than
quantity = 0
enableSched = 1
```

`alert.suppress.fields = ip` means a single misbehaving host only pages once per hour
instead of once per discovery cycle while it remains unresolved.
