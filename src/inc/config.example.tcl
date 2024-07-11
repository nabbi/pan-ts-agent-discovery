
# Citrix server networks to probe for active TS Agents
set config(networks) {10.10.10.0/24 192.168.0.0/16 172.16.0.1 172.16.0.5}

# The configured hostname on the device must match the dns hostname
# Hint: deploy GTM/GSLB with health checks to respond with the active address.
set config(strict) {1}

# Use discovered DNS RR for object name and hostname
# PTR and A resource records match
set config(dns) {1}

# Hostname of active Panorama instance
set config(panorama) {pan-hostname}

# Hostname of active Firewall instance
# In a perfect world, all firewalls have the same set of TS Agents configured
# So checking one of your deployments should be enough to sample the idle status of configured agents
set config(firewall) {fw-hostname}

# PAN-OS Admin credentials
# Used for both Panorama and Firewall
set config(username) {admin}
set config(password) {password123}

# Panorama configuration template name for where ts-agents are defined
set config(template) {temp_shared}

# Virtual System name for where ts-agets are define
set config(vsys) {vsys1}

# template-stacks for performing commit-all
set config(templatestacks) {stack_once stack_two}

