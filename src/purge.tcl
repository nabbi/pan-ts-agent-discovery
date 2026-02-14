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
if ($info) { puts "## Start PAN TS Agent Purge $time\n" }


## Delete
set delete {}
set found {}
# fetch not-connected terminal services agents from firewall
set notconn [myexec $path/exp/tsagent-not-connected.exp $config(firewall)]

if ($info) { puts "## Checking firewall for stale TS Agents\n" }
foreach n [split $notconn "\n"] {

    # filter input
    if {[string match "*not-conn:*" $n]} {
        set object [lindex $n 0]
        set hostname [lindex $n 1]

        lappend found $object

        # double check if the tls socket is not reachable
        # this protects against a momentary connection glitch
        if {! [mytsagent $hostname]} {
            if ($info) { puts "delete $object idle agent" }
            log "info" "delete ts-agent $hostname"
            lappend delete "$object"
        } else {
            if ($debug) { puts "keep $object agent was found" }
        }

    }
}

# perform the delete if needed
if {[string length $delete] > 0} {
    if ($info) { puts "## Not Connected [llength $found], Deleting [llength $delete] stale agents from configs\n"}
    if ($debug) { puts "debug delete::$delete"}
    if { $config(panorama) eq "disable" } {
        set d [myexec $path/exp/tsagent-modify-firewall.exp delete $config(firewall) $delete]
    } else {
        set d [myexec $path/exp/tsagent-modify-panorama.exp delete $config(panorama) $delete]
    }
} elseif { [llength $found] > 0} {
    if ($info) { puts "## Found [llength $found] not-connected agents but they are responding\n"}
}

set time [clock format [clock seconds] -format "%Y-%m-%d %H:%M"]
if ($info) { puts "## End PAN TS Agent Purge $time" }

exit
