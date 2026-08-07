#!/bin/sh
# the next line restarts using tclsh \
exec tclsh "$0" "$@"
# nic@boet.cc

set info 1
set debug 0
set trace 0

set path [file dirname [file normalize [info script]]]
if { [catch { source $path/inc/config.tcl }] } {
    puts "config.tcl does not exist, please create it from config.tcl.example"
    exit 1
}
source $path/inc/common-proc.tcl

set start_epoch [clock seconds]
set time [clock format $start_epoch -format "%Y-%m-%d %H:%M"]
if ($info) { puts "## Start PAN TS Agent Discovery $time\n" }
log "info" "run=discover status=start networks=[llength $config(networks)]"


## icmp reachable test
if ($info) { puts "## ICMP discovery\n" }

set alive {}
foreach n $config(networks) {
    if ($debug) { puts "debug: icmp ping: $n\n" }
    #returned value is a list. list-concatenate together
    set alive [list {*}$alive {*}[myfping $n]]
    ##if ($trace) { puts "trace: $alive\n" }
}
# if networks has overlapping ranges we might see duplicates
set alive [lsort -unique $alive]

## Add
set add {}
set found {}
## retrieve existing config, we do this once and cache it
if { $config(panorama) eq "disable" } {
    set existing [myexec $path/exp/tsagent-configured.exp $config(firewall)]
} else {
    set existing [myexec $path/exp/tsagent-configured.exp $config(panorama)]
}

if ($info) { puts "## probing [llength $alive] hosts for TS Agents and comparing against existing config\n" }
if ($trace) { puts "trace: $alive\n" }
foreach ip $alive {

    # test if tls socket is listening
    if {[mytsagent $ip]} {
        
        if { $config(dns) } {

            # lookup hostname
            set dig [mydig $ip]

            # 2018-04-10 nic@boet.cc
            ## initially we had used the ip address if no valid hostname was returned.
            ## This eventually resulted in duplicate TS Agents in the configs, during the next scan?,
            ## the hostname would become registered and that first entry was never purged
            ##
            ## This appeared to be a result of the server in maintenance mode, not fully deployed
            ## So we skip those servers now
            if {[llength $dig] == 0} { continue }

            # PTR records are attacker-influenceable (whoever controls reverse DNS for the
            # scanned subnet). agent_name/agent_host derived from $dig get sent verbatim into
            # live PAN-OS CLI commands and into a string match glob pattern, so anything
            # outside a normal hostname charset could inject a second CLI command (via \r\n),
            # desync the object/host CSV encoding (via ,), or spoof the "already configured"
            # check (via */?/[]). Reject anything that isn't a plain hostname before using it.
            if { ![regexp {^[A-Za-z0-9._-]+$} $dig] } {
                log "error" "suspicious PTR record for $ip, skipping: $dig"
                if ($debug) { puts "skip $ip suspicious PTR record: $dig" }
                continue
            }

            # we need an object name (ie host) and fqdn for the firewall configs
            #
            # KNOWN LIMITATION: this assumes exactly 3 dot-separated labels
            # (host.domain.tld). A PTR with a nested/subdomain name (e.g.
            # host.dc1.corp.example.com, common in AD environments) silently
            # truncates -- trailing labels beyond position 2 are dropped. A
            # single-label domain (host.lan) or a bare hostname with no
            # domain leaves a trailing-dot artifact instead. See the
            # "discover-agent-host-*" characterization tests in
            # common-proc.test.tcl for the exact current outputs.
            #
            # This is believed low-risk today because agent_host is only a
            # display/label value on the firewall object -- PAN-OS does not
            # resolve it to connect (connectivity is always via the IP
            # already fping/TLS-verified above), and the "already
            # configured" match below keys on agent_name, not agent_host.
            # Left as-is pending confirmation before changing the format of
            # a value written into live firewall/Panorama config.
            set agent_name [lindex [split $dig "."] 0]
            set domain [lindex [split $dig "."] 1]
            set tld [lindex [split $dig "."] 2]
            set agent_host "$agent_name.$domain.$tld"

        } else {
            set agent_name $ip
            set agent_host $ip
        }

        lappend found $agent_name

        # check if we already have this configured
        if { $config(dns) && [string match "*$config(template)*ts-agent $agent_name*" $existing] } {
            if ($debug) { puts "skip $agent_name agent dns already configured" }

        } elseif { ! $config(dns) && [string match "*$config(template)*ts-agent $agent_name host*" $existing] } {
            if ($debug) { puts "skip $agent_name agent ip already configured" }

        } else {
            if ($info) { puts "new $agent_name agent found" }
            log "info" "new ts-agent $agent_name"
            lappend add "$agent_name,$agent_host"
        }

    } else {
        if ($debug) { puts "none $ip" } 
    }
}

# perform the add if needed
if {[string length $add] > 0} {
    if ($info) { puts "## Discovered [llength $found], Adding [llength $add] new agents\n"}
    if ($debug) { puts "debug add:$add"}
    if { $config(panorama) eq "disable" } {
        set a [myexec $path/exp/tsagent-modify-firewall.exp add $config(firewall) $add]
    } else {
        set a [myexec $path/exp/tsagent-modify-panorama.exp add $config(panorama) $add]
    }
} else {
    if ($info) { puts "## All [llength $found] agents discovered are already defined\n"}
}

log "info" "run=discover status=ok elapsed_sec=[expr {[clock seconds] - $start_epoch}] scanned=[llength $alive] discovered=[llength $found] added=[llength $add]"

set time [clock format [clock seconds] -format "%Y-%m-%d %H:%M"]
if ($info) { puts "## End PAN TS Agent Discovery $time" }

exit
