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

set time [clock format [clock seconds] -format "%Y-%m-%d %H:%M"]
if ($info) { puts "## Start PAN TS Agent Discovery $time\n" }


## icmp reachable test
if ($info) { puts "## ICMP discovery\n" }

set alive {}
foreach n $config(networks) {
    if ($debug) { puts "debug: icmp ping: $n\n" }
    #returned value is a list. list-concatenate together
    set alive [list {*}$alive {*}[myfping $n]]
    ##if ($trace) { puts "trace: $alive\n" }
}

## Add
set add {}
## retrieve panorama existing config, we do this once and cache it
set panorama [myexec $path/exp/tsagent-configured.exp $config(panorama)]

if ($info) { puts "## probing for TS Agents and comparing against Panorama config\n" }
if ($trace) { puts "trace: $alive\n" }
foreach ip $alive {

    #test if tls socket is listening
    if {[mytsagent $ip]} {

        #lookup hostname
        set dig [mydig $ip]
        
        #2018-04-10 nic@boet.cc
        ## initially we had used the ip address if no valid hostname was returned.
        ## This eventually resulted in duplicate TS Agents in the configs, during the next scan?,
        ## the hostname would become registered and that first entry was never purged
        ##
        ## This appeared to be a result of the server in maintenance mode, not fully deployed
        ## So we skip those servers now
        if {[llength $dig] != 0} {

            #we need an object name (ie host) and fqdn for the firewall configs
            set host [lindex [split $dig "."] 0]
            set domain [lindex [split $dig "."] 1]
            set tld [lindex [split $dig "."] 2]
            set fqdn "$host.$domain.$tld"
            ##if ($trace) { puts "trace: $ip $host $fqdn\n" }

            #check if we already have this configured
            if {[string match "*$config(template)*ts-agent $host*" $panorama] } {
                if ($debug) { puts "skip $host agent already configured" }
            } else {
                if ($info) { puts "new $host agent add into panorama" }
                log "info" "new ts-agent $host"
                lappend add "$host,$fqdn"
            }


        }
    } else {
        if ($debug) { puts "none $ip" } 
    }
}

# perform the add if needed
if {[string length $add] > 0} {
    if ($info) { puts "## Adding new agents into $config(panorama)\n"}
    if ($debug) { puts "debug add:$add"}
    set a [myexec $path/exp/tsagent-modify.exp add $config(panorama) $add]
}



set time [clock format [clock seconds] -format "%Y-%m-%d %H:%M"]
if ($info) { puts "## End PAN TS Agent Discovery $time" }

exit
