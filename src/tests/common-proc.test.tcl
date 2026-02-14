#!/bin/sh
# the next line restarts using tclsh \
exec tclsh "$0" "$@"
# Tests for common-proc.tcl
# Run: tclsh src/tests/common-proc.test.tcl

package require tcltest
namespace import ::tcltest::*

# ---- test helpers ----

# mock logger and exec - save the original, replace with a controllable stub
rename exec _real_exec

# track calls to logger
set ::mock_logger_calls {}

# mock exec: intercepts logger and returns canned responses for other commands
proc exec {args} {
    # strip -- if present (tclsh sometimes passes it)
    set clean $args
    if {[lindex $clean 0] eq "--"} {
        set clean [lrange $clean 1 end]
    }

    set cmd [lindex $clean 0]

    if {$cmd eq "logger"} {
        lappend ::mock_logger_calls $clean
        return ""
    }

    # for everything else, check our mock registry
    if {[info exists ::mock_exec_result]} {
        set r $::mock_exec_result
        if {[info exists ::mock_exec_error] && $::mock_exec_error} {
            set code $::mock_exec_errorcode
            return -code error -errorcode $code $r
        }
        return $r
    }

    error "unmocked exec call: $args"
}

# helper to configure mock exec result
proc mock_exec_ok {result} {
    set ::mock_exec_result $result
    set ::mock_exec_error 0
}

proc mock_exec_fail {result status} {
    set ::mock_exec_result $result
    set ::mock_exec_error 1
    set ::mock_exec_errorcode [list CHILDSTATUS 12345 $status]
}

proc mock_exec_other_error {result} {
    set ::mock_exec_result $result
    set ::mock_exec_error 1
    set ::mock_exec_errorcode [list POSIX ENOENT "no such file"]
}

proc mock_exec_clear {} {
    unset -nocomplain ::mock_exec_result
    unset -nocomplain ::mock_exec_error
    unset -nocomplain ::mock_exec_errorcode
}

# mock exit so fatal paths throw a catchable error instead of killing the interpreter
rename exit _real_exit
proc exit {{code 0}} {
    error "EXIT $code" "" [list EXIT $code]
}

# source the code under test
set path [file dirname [file normalize [info script]]]
source $path/../inc/common-proc.tcl


# ========================================================================
# log proc tests
# ========================================================================

test log-newline-replacement {log replaces newlines with separator} -setup {
    set ::mock_logger_calls {}
} -body {
    log "info" "line1\nline2\nline3"
    set call [lindex $::mock_logger_calls 0]
    # the message arg should contain " :: " instead of newlines
    set msg [lindex $call end]
    string match "*line1 :: line2 :: line3*" $msg
} -result 1

test log-truncation {log truncates messages longer than 200 chars} -setup {
    set ::mock_logger_calls {}
} -body {
    set longmsg [string repeat "x" 300]
    log "info" $longmsg
    set call [lindex $::mock_logger_calls 0]
    set msg [lindex $call end]
    # message should end with " ..." (script path is prepended, so just check suffix)
    string match "* ..." $msg
} -result 1

test log-short-message {log does not truncate short messages} -setup {
    set ::mock_logger_calls {}
} -body {
    log "info" "short message"
    set call [lindex $::mock_logger_calls 0]
    set msg [lindex $call end]
    string match "*short message*" $msg
} -result 1

test log-level-passed {log passes level to logger} -setup {
    set ::mock_logger_calls {}
} -body {
    log "error" "test"
    set call [lindex $::mock_logger_calls 0]
    # should contain "-p" "user.error"
    expr {[lsearch $call "user.error"] >= 0}
} -result 1

test log-exactly-200 {log does not truncate message of exactly 200 chars} -setup {
    set ::mock_logger_calls {}
} -body {
    set msg200 [string repeat "a" 200]
    log "info" $msg200
    set call [lindex $::mock_logger_calls 0]
    set msg [lindex $call end]
    expr {![string match "* ..." $msg]}
} -result 1

test log-201-chars {log truncates message of 201 chars} -setup {
    set ::mock_logger_calls {}
} -body {
    set msg201 [string repeat "b" 201]
    log "info" $msg201
    set call [lindex $::mock_logger_calls 0]
    set msg [lindex $call end]
    string match "* ..." $msg
} -result 1


# ========================================================================
# myfping - IPv4 validation logic
# ========================================================================

test myfping-valid-ips {myfping returns valid IPv4 addresses} -setup {
    mock_exec_ok "10.0.0.1\n10.0.0.2\n10.0.0.3"
} -body {
    myfping "10.0.0.0/24"
} -cleanup {
    mock_exec_clear
} -result {10.0.0.1 10.0.0.2 10.0.0.3}

test myfping-filters-non-ip {myfping filters out non-IPv4 strings} -setup {
    mock_exec_ok "10.0.0.1\nICMP Host Unreachable\n10.0.0.2"
} -body {
    myfping "10.0.0.0/24"
} -cleanup {
    mock_exec_clear
} -result {10.0.0.1 10.0.0.2}

test myfping-filters-octet-out-of-range {myfping filters IPs with octets > 255} -setup {
    mock_exec_ok "10.0.0.1\n10.0.0.256\n10.0.999.1"
} -body {
    myfping "10.0.0.0/24"
} -cleanup {
    mock_exec_clear
} -result {10.0.0.1}

test myfping-empty-result {myfping returns empty list when no hosts alive} -setup {
    mock_exec_ok ""
} -body {
    myfping "10.0.0.0/24"
} -cleanup {
    mock_exec_clear
} -result {}

test myfping-exit-1-partial {myfping handles exit code 1 (some unreachable)} -setup {
    mock_exec_fail "10.0.0.1\n10.0.0.5" 1
} -body {
    myfping "10.0.0.0/24"
} -cleanup {
    mock_exec_clear
} -result {10.0.0.1 10.0.0.5}

test myfping-exit-2-fatal {myfping exits on error code 2} -setup {
    mock_exec_fail "address not found" 2
} -body {
    # should call exit 1, which our mock turns into a catchable error
    set caught [catch {myfping "bad.host"} err opts]
    set code [dict get $opts -errorcode]
    list $caught [lindex $code 0] [lindex $code 1]
} -cleanup {
    mock_exec_clear
} -result {1 EXIT 1}

test myfping-filters-negative-octet {myfping filters IP with negative octet} -setup {
    mock_exec_ok "10.0.0.1\n10.0.-1.2"
} -body {
    myfping "10.0.0.0/24"
} -cleanup {
    mock_exec_clear
} -result {10.0.0.1}

test myfping-filters-alpha-octet {myfping filters IP with alphabetic octet} -setup {
    mock_exec_ok "10.0.0.1\n10.0.abc.2"
} -body {
    myfping "10.0.0.0/24"
} -cleanup {
    mock_exec_clear
} -result {10.0.0.1}

test myfping-zero-ip {myfping accepts 0.0.0.0} -setup {
    mock_exec_ok "0.0.0.0"
} -body {
    myfping "0.0.0.0/32"
} -cleanup {
    mock_exec_clear
} -result {0.0.0.0}

test myfping-max-ip {myfping accepts 255.255.255.255} -setup {
    mock_exec_ok "255.255.255.255"
} -body {
    myfping "255.255.255.0/24"
} -cleanup {
    mock_exec_clear
} -result {255.255.255.255}


# ========================================================================
# mytsagent - TLS certificate validation
# ========================================================================

test mytsagent-found {mytsagent returns 1 when cert contains Terminal Server Agent} -setup {
    mock_exec_ok "Subject: CN = Terminal Server Agent\nIssuer: CN = Something"
} -body {
    mytsagent "10.0.0.1"
} -cleanup {
    mock_exec_clear
} -result 1

test mytsagent-not-found {mytsagent returns 0 when cert does not contain Terminal Server Agent} -setup {
    mock_exec_ok "Subject: CN = SomeOtherCert\nIssuer: CN = Something"
} -body {
    mytsagent "10.0.0.1"
} -cleanup {
    mock_exec_clear
} -result 0

test mytsagent-empty-response {mytsagent returns 0 on empty response} -setup {
    mock_exec_ok ""
} -body {
    mytsagent "10.0.0.1"
} -cleanup {
    mock_exec_clear
} -result 0

test mytsagent-exit-1 {mytsagent returns 0 silently on exit code 1} -setup {
    mock_exec_fail "connection refused" 1
} -body {
    mytsagent "10.0.0.1"
} -cleanup {
    mock_exec_clear
} -result 0

test mytsagent-exit-104 {mytsagent returns 0 on ECONNRESET (exit 104)} -setup {
    mock_exec_fail "connection reset by peer" 104
} -body {
    mytsagent "10.0.0.1"
} -cleanup {
    mock_exec_clear
} -result 0

test mytsagent-other-error {mytsagent returns 0 on non-CHILDSTATUS errors} -setup {
    mock_exec_other_error "no such file"
} -body {
    mytsagent "10.0.0.1"
} -cleanup {
    mock_exec_clear
} -result 0

test mytsagent-cert-with-extra-text {mytsagent detects agent even in verbose output} -setup {
    mock_exec_ok "Certificate:\n    Data:\n        Subject: CN = Terminal Server Agent v1.2\n        Validity:\n            Not Before: Jan 1 00:00:00 2024"
} -body {
    mytsagent "10.0.0.1"
} -cleanup {
    mock_exec_clear
} -result 1


# ========================================================================
# discover.tcl pattern matching logic (tested as standalone string ops)
# ========================================================================

test discover-dns-match-existing {discover skips agent already configured (DNS mode)} -body {
    set config(template) "temp_shared"
    set agent_name "server01"
    set panorama "set template temp_shared config vsys vsys1 ts-agent server01 host server01.domain.com port 5009"
    string match "*$config(template)*ts-agent $agent_name*" $panorama
} -result 1

test discover-dns-no-match {discover detects new agent not yet configured (DNS mode)} -body {
    set config(template) "temp_shared"
    set agent_name "newserver"
    set panorama "set template temp_shared config vsys vsys1 ts-agent server01 host server01.domain.com port 5009"
    string match "*$config(template)*ts-agent $agent_name*" $panorama
} -result 0

test discover-ip-match-existing {discover skips agent already configured (IP mode)} -body {
    set config(template) "temp_shared"
    set agent_name "10.0.0.1"
    set panorama "set template temp_shared config vsys vsys1 ts-agent 10.0.0.1 host 10.0.0.1 port 5009"
    string match "*$config(template)*ts-agent $agent_name host*" $panorama
} -result 1

test discover-ip-no-match {discover detects new agent not yet configured (IP mode)} -body {
    set config(template) "temp_shared"
    set agent_name "10.0.0.99"
    set panorama "set template temp_shared config vsys vsys1 ts-agent 10.0.0.1 host 10.0.0.1 port 5009"
    string match "*$config(template)*ts-agent $agent_name host*" $panorama
} -result 0

test discover-multi-agent-panorama {discover matches among multiple configured agents} -body {
    set config(template) "temp_shared"
    set agent_name "server02"
    set panorama "set template temp_shared config vsys vsys1 ts-agent server01 host server01.dom.com port 5009
set template temp_shared config vsys vsys1 ts-agent server02 host server02.dom.com port 5009
set template temp_shared config vsys vsys1 ts-agent server03 host server03.dom.com port 5009"
    string match "*$config(template)*ts-agent $agent_name*" $panorama
} -result 1

test discover-wrong-template-no-match {discover does not match agent in different template} -body {
    set config(template) "temp_shared"
    set agent_name "server01"
    set panorama "set template other_template config vsys vsys1 ts-agent server01 host server01.dom.com port 5009"
    string match "*$config(template)*ts-agent $agent_name*" $panorama
} -result 0


# ========================================================================
# discover.tcl DNS parsing logic
# ========================================================================

test discover-dns-split-hostname {dns split extracts agent name from FQDN} -body {
    set dig "server01.domain.com."
    set agent_name [lindex [split $dig "."] 0]
    set agent_name
} -result "server01"

test discover-dns-split-domain {dns split extracts domain from FQDN} -body {
    set dig "server01.domain.com."
    set domain [lindex [split $dig "."] 1]
    set domain
} -result "domain"

test discover-dns-split-tld {dns split extracts TLD from FQDN} -body {
    set dig "server01.domain.com."
    set tld [lindex [split $dig "."] 2]
    set tld
} -result "com"

test discover-dns-empty-skip {empty dig result means skip (llength == 0)} -body {
    set dig ""
    expr {[llength $dig] == 0}
} -result 1

test discover-dns-valid-continue {non-empty dig result means continue} -body {
    set dig "server01.domain.com."
    expr {[llength $dig] == 0}
} -result 0


# ========================================================================
# purge.tcl pattern matching logic
# ========================================================================

test purge-not-conn-match {purge matches not-conn lines} -body {
    set n "server01            10.0.0.1        5009    vsys1        not-conn:       0/0/0"
    string match "*not-conn:*" $n
} -result 1

test purge-not-conn-no-match {purge does not match connected lines} -body {
    set n "server01            10.0.0.1        5009    vsys1        connected:      192.168.1.1"
    string match "*not-conn:*" $n
} -result 0

test purge-extract-object {purge extracts object name from not-conn line} -body {
    set n "server01            10.0.0.1        5009    vsys1        not-conn:       0/0/0"
    lindex $n 0
} -result "server01"

test purge-extract-hostname {purge extracts hostname from not-conn line} -body {
    set n "server01            10.0.0.1        5009    vsys1        not-conn:       0/0/0"
    lindex $n 1
} -result "10.0.0.1"

test purge-extract-object-dns {purge extracts dns-based object name} -body {
    set n "citrix-app01        citrix-app01.domain.com  5009    vsys1   not-conn:       0/0/0"
    lindex $n 0
} -result "citrix-app01"

test purge-extract-hostname-dns {purge extracts dns-based hostname} -body {
    set n "citrix-app01        citrix-app01.domain.com  5009    vsys1   not-conn:       0/0/0"
    lindex $n 1
} -result "citrix-app01.domain.com"

test purge-multiline-filter {purge filters only not-conn lines from mixed output} -body {
    set notconn "show user ts-agent statistics | match not-conn
server01    10.0.0.1    5009    vsys1   not-conn:   0/0/0
server02    10.0.0.2    5009    vsys1   not-conn:   0/0/0
admin@fw>"
    set found {}
    foreach n [split $notconn "\n"] {
        if {[string match "*not-conn:*" $n]} {
            lappend found [lindex $n 0]
        }
    }
    set found
} -result {server01 server02}

test purge-no-stale-agents {purge produces empty list when no not-conn lines} -body {
    set notconn "show user ts-agent statistics | match not-conn
admin@fw>"
    set found {}
    foreach n [split $notconn "\n"] {
        if {[string match "*not-conn:*" $n]} {
            lappend found [lindex $n 0]
        }
    }
    set found
} -result {}


# ========================================================================
# discover.tcl dedup logic (lsort -unique)
# ========================================================================

test discover-dedup-alive {lsort -unique removes duplicate IPs} -body {
    set alive {10.0.0.1 10.0.0.2 10.0.0.1 10.0.0.3 10.0.0.2}
    lsort -unique $alive
} -result {10.0.0.1 10.0.0.2 10.0.0.3}

test discover-dedup-empty {lsort -unique on empty list returns empty} -body {
    lsort -unique {}
} -result {}


# ========================================================================
# discover.tcl add list construction
# ========================================================================

test discover-add-format {add list entry has correct object,host format} -body {
    set agent_name "server01"
    set agent_host "server01.domain.com"
    set entry "$agent_name,$agent_host"
    set entry
} -result "server01,server01.domain.com"

test discover-add-split {tsagent-modify can parse the add entry} -body {
    set i "server01,server01.domain.com"
    set object [lindex [split $i ","] 0]
    set hostname [lindex [split $i ","] 1]
    list $object $hostname
} -result {server01 server01.domain.com}


# ========================================================================
# run tests and report
# ========================================================================

# restore real exit before cleanup (tcltest calls exit internally)
rename exit {}
rename _real_exit exit

cleanupTests
