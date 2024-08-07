# Docker

Dockerfile is experimental yet should be super good enough (please provide feedback or PR if it isn't)

## clone repo

```shell
git clone https://github.com/nabbi/pan-ts-agent-discovery
cd pan-ts-agent-discovery
```

## Build
Once config.tcl is defined, build your custom image with:

```shell
docker build .
```

This will build everything in your local repo (not cloning from github) so you can customize the crontab or code to test within your custom deployment.


## Run

Copy the image where ever you spin your containers.

```shell
docker run -d <hash>
```

# Manual

YMMV

## dependencies

These commands should be in the system default paths

* curl
* dig
* echo
* expect
* fping
* logger
* openssl
* ssh
* ssh-keygen
* tcl
* timeout

### Ubuntu

```shell
sudo apt install fping expect
```

## clone repo

```shell
cd ~/bin
git clone https://github.com/nabbi/pan-ts-agent-discovery
```

## config

Define inc/config.tcl from inc/config.example.tcl

## initialize log files

writable by the non-privileged account cron jobs are ran as

```shell
mkdir /var/log/paloalto
touch /var/log/paloalto/pan-tsagent-discover.log /var/log/paloalto/pan-tsagent-purge.log
chgrp -R $(USER) /var/log/paloalto
chmod -R g+w /var/log/paloalto
```

## logrotate
/etc/logrotate.d/pan-tsa-discovery

```logrotate
/var/log/paloalto/pan-*.log {
    rotate 90
    daily
    missingok
    compress
    sharedscripts
}
```

## crontab

non-privileged account

```cron
# PAN TS Agent Discover
15 * * * *     ~/pan-ts-agent-discovery/src/discover.tcl >> /var/log/paloalto/pan-tsagent-discover.log 2>&1
# PAN TS Agent Purge - do not run at same time as discovery add!
30 5 * * *     ~/pan-ts-agent-discovery/src/purge.tcl >> /var/log/paloalto/pan-tsagent-purge.log 2>&1
```

## ssh config

newer OpenSSH defaults are sticter than Panorama

~/.ssh/config
```
host *
    HostKeyAlgorithms=+ssh-rsa
```

