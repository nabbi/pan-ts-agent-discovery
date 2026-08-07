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

        # $n is parsed as a Tcl list below -- an unbalanced brace or quote
        # anywhere in the device's output throws a Tcl error. Don't let one
        # malformed/corrupted line abort the whole purge run.
        if {[catch {
            set object [lindex $n 0]
            set hostname [lindex $n 1]
        } err]} {
            log "error" "purge: could not parse not-conn line, skipping: $n ($err)"
            if ($debug) { puts "skip unparsable line: $n" }
            continue
        }

        # object/hostname come from live firewall CLI output -- normally a bare \r
        # is just inter-field whitespace to lindex's list parsing, but a
        # brace-/quote-grouped field in a malformed or spoofed line can carry a
        # literal \r straight through. Both values eventually reach a live
        # `send` command (delete ...$object\r) and mytsagent's exec, so apply
        # the same hostname-charset gate discover.tcl uses at its mydig call
        # site before using either.
        if { ![regexp {^[A-Za-z0-9._-]+$} $object] || ![regexp {^[A-Za-z0-9._-]+$} $hostname] } {
            log "error" "purge: suspicious not-conn object/hostname, skipping: $n"
            if ($debug) { puts "skip suspicious not-conn line: $n" }
            continue
        }

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
