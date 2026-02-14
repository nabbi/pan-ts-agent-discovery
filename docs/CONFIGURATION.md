# Configuration

Copy the example configuration to create your local config file:

```shell
cp src/inc/config.example.tcl src/inc/config.tcl
```

The `config.tcl` file is sourced by both `discover.tcl` and `purge.tcl` at startup. It is excluded from version control to keep credentials out of the repository.

## Parameters

### networks

```tcl
set config(networks) {10.10.10.0/24 192.168.0.0/16 172.16.0.1 172.16.0.5}
```

Space-separated list of Citrix server subnets and individual IPs to probe for active TS Agents. Supports CIDR notation. These are swept with ICMP (fping) during discovery.

### strict

```tcl
set config(strict) {1}
```

When enabled (`1`), the configured firewall hostname must match its DNS hostname. One fuzzy character is allowed to accommodate active/standby naming conventions (e.g. `fw1a` / `fw1b` behind a `fw1` CNAME).

Set to `0` if you do not use GSLB and need to reach the active firewall member directly via an inside interface.

### dns

```tcl
set config(dns) {1}
```

When enabled (`1`), discovered DNS resource records are used for the Panorama template object name and hostname. Both a reverse PTR and a matching forward A record are required.

When disabled (`0`), the raw IP address is used instead.

### panorama

```tcl
set config(panorama) {pan-hostname}
```

Hostname (or IP) of the active Panorama instance. Used by `discover.tcl` to query existing TS Agent configuration and to add or delete agents.

### firewall

```tcl
set config(firewall) {fw-hostname}
```

Hostname (or IP) of an active firewall member. Used by `purge.tcl` to retrieve the list of not-connected TS Agents. In an HA pair, all firewalls should share the same TS Agent set, so querying one is sufficient.

### username / password

```tcl
set config(username) {admin}
set config(password) {password123}
```

PAN-OS admin credentials used for SSH access to both Panorama and the firewall. The account needs permission to read/modify TS Agent configuration and perform commits.

### template

```tcl
set config(template) {temp_shared}
```

The Panorama configuration template where TS Agents are defined. Agents are added and removed under this template's vsys.

### vsys

```tcl
set config(vsys) {vsys1}
```

The virtual system within the template where TS Agents are configured.

### templatestacks

```tcl
set config(templatestacks) {stack_once stack_two}
```

Space-separated list of Panorama template-stacks. After a commit, changes are pushed (`commit-all`) to each stack listed here.

## Notes

- The TS Agent TLS port (`5009`) is hardcoded and not configurable. This is the default port used by the Palo Alto Networks Terminal Services Agent.
- `config.tcl` is listed in `.gitignore` to prevent credentials from being committed.
