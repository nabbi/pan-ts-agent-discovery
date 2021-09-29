# PAN TS Agent Discovery

Automation routines for provisioning [Palo Alto Networks Terminal Services Agents](https://docs.paloaltonetworks.com/compatibility-matrix/terminal-services-ts-agent.html) into Panorama from dynamically deployed [Citrix XenApp](https://www.citrix.com/) "golden" images.

I run the discovery hourly and purge daily (after the overnight maintenance server reboots)

##  discover.tcl

Performs network probing to "discover" which servers have the PAN Terminal Services Agent running
- icmp ping subnets for alive servers
- openssl client socket connects to confirm presence of TSAgent certificate
- reverse ddns lookup ip address for constructing object and hostname
- Panorama running configurations are checked if the discovered agents are new, or skipped if already defined

Changes are committed and pushed to defined template stacks


##  purge.tcl

Removes stale not-connected PAN TS Agents from Panorama
- Retrieve idle agents from an active firewall member
- confirms again with an openssl tls connect that
- removes config from panorama

Changes are committed and pushed to defined template stacks

