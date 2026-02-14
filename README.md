# PAN TS Agent Discovery

Automation routines for provisioning [Palo Alto Networks Terminal Services Agents](https://docs.paloaltonetworks.com/compatibility-matrix/terminal-services-ts-agent.html) into Panorama from dynamically deployed [Citrix XenApp](https://www.citrix.com/) "golden" images.

![traffic flows](https://raw.githubusercontent.com/nabbi/pan-ts-agent-discovery/master/docs/flows.png)


##  discover.tcl

Performs network probing to "discover" which servers have the PAN Terminal Services Agent running
- icmp ping sweep subnets for alive servers
- openssl client socket connects to confirm presence of TSAgent certificate
- reverse ddns lookup ip address for constructing object and hostname
- Panorama running configurations are checked if the discovered agents are new, or skipped if already defined

Changes are committed and pushed to defined template stacks


##  purge.tcl

Removes stale not-connected PAN TS Agents from Panorama
- Retrieve idle agents from an active firewall member
- confirms again with an openssl tls connect that agent is unreachable
- removes config from panorama template

Changes are committed and pushed to defined template stacks

## configuration

Create your local [inc/config.tcl](src/inc/config.example.tcl) file.

## crontab

I run the [crontab](crontab) discovery hourly and purge daily (after the overnight server reboot maintenance window).

Use the provided [logrotate](logrotate) to manage the logs files this generates.

##  Install

See [INSTALL](INSTALL.md) for more hints on setting up your environment, a [Dockerfile](Dockerfile) exists now too.
