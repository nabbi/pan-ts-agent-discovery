#!/bin/sh
# the next line restarts using tclsh \
exec tclsh "$0" "$@"
# nic@boet.cc

# shothand our logger
# syslog is the secondary/redundant sink -- the file log (via stdout) is primary,
# so a logger failure (missing binary, /dev/log unavailable, syslogd down) must not
# abort the run. catch it and fall back to stdout so the event is still recorded
# somewhere instead of taking down mid-run.
proc log {level msg} {
    # a bare \r (no \n) is untouched by a \n-only regsub and reaches logger raw --
    # some of what lands here is attacker-influenceable (e.g. the raw, unvalidated
    # PTR value logged when discover.tcl rejects it), and a stray \r lets that
    # content visually overwrite/hide the alert line in a terminal-based log
    # viewer (tail/less), a classic CR log-forging trick. Collapse \r\n, lone \r,
    # and lone \n uniformly instead of \n alone.
    set m [regsub -all {\r\n|\r|\n} ${msg} " :: "]
    if { [string length $m] > 200 } {
        set m "[string range $m 0 200] ..."
    }
    if {[catch {exec logger -p user.${level} "[info script] ${m}"} err]} {
        puts "## logger failed: $err"
        puts "## $level: $m"
    }
}


## exit if child process fails, otherwise return result
proc myexec {args} {
    set status 0
    if {[catch {exec {*}$args} results options]} {
        set details [dict get $options -errorcode]
        if {[lindex $details 0] eq "CHILDSTATUS"} {
        set status [lindex $details 2]
        } else {
        # Some other error; regenerate it to let caller handle
        #return -options $options -level 0 $results
        set status 70
        }
    }

    log [expr {$status ? "error" : "info"}] "$args $results"

    if { $status } {
        puts "## Error $status ##"
        puts $results
        exit 1
    }
    return $results
}


# fping exit 1 for non-alive hosts -- we are scanning subnets so special error handling needed
# Exit status is 0 if all the hosts are reachable, 1 if some hosts were unreachable, 2 if any IP addresses were not found, 3 for invalid command line arguments, and 4 for a system call failure.
proc myfping {args} {
    set status 0
    if {[catch {exec fping -a -g {*}$args} results options]} {
        set details [dict get $options -errorcode]
        if {[lindex $details 0] eq "CHILDSTATUS"} {
            set status [lindex $details 2]
        } else {
            # Some other error; regenerate it to let caller handle
            #return -options $options -level 0 $results
            set status 70
        }
    }

    # exit if error is not 1
    if { $status && $status != 1 } {
        log "error" "$args $status $results"
        puts "## Error $status ##"
        puts $results
        exit 1
    }

    # strip non-ipv4 address from the returned data. empty if none
    set valid {}
    foreach ip $results {
        set octets [split $ip .]
        # must be exactly 4 dot-separated octets -- otherwise inputs like ""
        # (zero octets) or "10.0.1" (3 octets) pass by default since the
        # per-octet loop below never runs long enough to flip ipv4 to 0
        set ipv4 [expr {[llength $octets] == 4}]
        foreach o $octets {
            if { ! ( ( $o >= 0 ) && ( $o <=255 ) && ([string is digit $o] ) ) } {
                set ipv4 0
            }
        }
        if {$ipv4} {
            lappend valid $ip
        }
    }

    return $valid
}



# validate Terminal Server Agent TLS socket is responding
proc mytsagent {host} {
    set status 0
    if {[catch {exec echo | timeout 2 openssl s_client -showcerts -connect $host:5009 2>/dev/null | openssl x509 -inform pem -noout -text 2>/dev/null} results options]} {
        set details [dict get $options -errorcode]
        if {[lindex $details 0] eq "CHILDSTATUS"} {
            set status [lindex $details 2]
        } else {
            # Some other error; regenerate it to let caller handle
            #return -options $options -level 0 $results
            set status 70
        }
    }

    # check result for certificate
    if { [string first "Terminal Server Agent" $results] >= 0 } {
        return 1
    }

    # silently ignore exit 1 errors
    if { $status == 1 } {
        return 0
    }

    # return false if error non-zero
    # seen a few occurrences with 104 ECONNREST returned
    # want the overall discovery process to continue but ignore this host
    if { $status } {
        log "error" "$host $status"
        puts "## Error $host $status ##"
        puts $results
        return 0
    }

    return 0
}


# reverse lookup ip address for hostname
proc mydig {ip} {
    set status 0
    if {[catch {exec dig -t ptr -x $ip +short | head -n1} results options]} {
        set details [dict get $options -errorcode]
        if {[lindex $details 0] eq "CHILDSTATUS"} {
            set status [lindex $details 2]
        } else {
            # Some other error; regenerate it to let caller handle
            #return -options $options -level 0 $results
            set status 70
        }
    }

    # exit if error non-zero
    if { $status } {
        log "error" "mydig $ip $status $results"
        puts "## Error $status ##"
        puts $results
        exit 1
    }

    return $results
}

