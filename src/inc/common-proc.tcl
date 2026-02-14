#!/bin/sh
# the next line restarts using tclsh \
exec tclsh "$0" "$@"
# nic@boet.cc

# shothand our logger
proc log {level msg} {
    set m [regsub -all "\n" ${msg} " :: "]
    if { [string length $m] > 200 } {
        set m "[string range $m 0 200] ..."
    }
    exec logger -p user.${level} "[info script] ${m}"
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

    log "info" "$args $results"

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
        set ipv4 1
        foreach o [split $ip .] {
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

