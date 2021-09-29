YMMV on adjusting paths to suit your needs

# clone repo
```
cd ~/bin
git clone https://github.com/nabbi/pan-ts-agent-discovery
```

# config
Define inc/config.tcl from inc/config.example.tcl

# initialize log files
writable by the non-privileged account cron jobs are ran as
```
touch /var/log/pan-tsagent-discover.log /var/log/pan-tsagent-purge.log
chgrp $(USER) /var/log/pan-tsagent*.log
chmod g+w /var/log/pan-tsagent*.log
```

# logrotate
/etc/logrotate.d/local-logs
```
/var/log/pan-*.log {
    rotate 90
    daily
    missingok
    sharedscripts
}
```

# crontab
non-privileged account
```
# PAN TS Agent Discover
15 * * * *     ~/bin/pan-ts-agentdiscovery/discover.tcl >> /var/log/pan-tsagent-discover.log 2>&1
# PAN TS Agent Purge - do not run at same time as discovery add!
30 5 * * *     ~/bin/pan-ts-agent-discovery/purge.tcl >> /var/log/pan-tsagent-purge.log 2>&1
```
