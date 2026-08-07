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
        if {[info exists ::mock_logger_fail] && $::mock_logger_fail} {
            return -code error -errorcode {POSIX ENOENT {no such file}} \
                "couldn't execute \"logger\": no such file or directory"
        }
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

proc mock_logger_fail {} {
    set ::mock_logger_fail 1
}

proc mock_logger_ok {} {
    unset -nocomplain ::mock_logger_fail
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

test log-bare-cr-replacement {
    log replaces a bare \r (no accompanying \n) too, not just \n -- a stray CR
    reaching logger raw lets a log viewer visually overwrite/hide the line
    (log forging), which matters because some logged content is
    attacker-influenceable (e.g. the raw PTR value discover.tcl logs when it
    rejects one)
} -setup {
    set ::mock_logger_calls {}
} -body {
    log "error" "suspicious PTR record for 10.0.0.5, skipping: evil\rSAFE LOOKING TEXT"
    set call [lindex $::mock_logger_calls 0]
    set msg [lindex $call end]
    list [string first "\r" $msg] [string match "*evil :: SAFE LOOKING TEXT*" $msg]
} -result {-1 1}

test log-crlf-replacement {
    log collapses a \r\n pair into a single separator rather than two (one from
    matching \r, one from matching \n)
} -setup {
    set ::mock_logger_calls {}
} -body {
    log "info" "line1\r\nline2"
    set call [lindex $::mock_logger_calls 0]
    set msg [lindex $call end]
    string match "*line1 :: line2*" $msg
} -result 1

test log-mixed-cr-lf-replacement {
    log handles a message mixing bare \r, bare \n, and \r\n in the same string,
    with no raw CR or LF surviving into the logger argument
} -setup {
    set ::mock_logger_calls {}
} -body {
    log "info" "a\rb\nc\r\nd"
    set call [lindex $::mock_logger_calls 0]
    set msg [lindex $call end]
    list [string first "\r" $msg] [string first "\n" $msg]
} -result {-1 -1}

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

test log-logger-failure-does-not-abort {
    log must not let a failing logger call (missing binary, /dev/log unavailable,
    syslogd down) propagate an error -- syslog is the secondary/redundant sink and
    a transient failure there must not crash a discover.tcl/purge.tcl run mid-batch
} -setup {
    set ::mock_logger_calls {}
    mock_logger_fail
} -body {
    catch {log "info" "test message"}
} -cleanup {
    mock_logger_ok
} -result 0

test log-logger-failure-still-attempts-call {
    log still attempts the logger call (and records it) even though the mock is
    set to fail it -- confirms the catch wraps the call rather than skipping it
} -setup {
    set ::mock_logger_calls {}
    mock_logger_fail
} -body {
    catch {log "info" "test message"}
    llength $::mock_logger_calls
} -cleanup {
    mock_logger_ok
} -result 1


# ========================================================================
# myexec - generic exec wrapper used by .exp script invocations
# ========================================================================

test myexec-success {myexec returns results on success} -setup {
    mock_exec_ok "Success"
} -body {
    myexec "some-script.exp" "arg1"
} -cleanup {
    mock_exec_clear
} -result "Success"

test myexec-success-logs {myexec logs args and results on success} -setup {
    mock_exec_ok "Success"
    set ::mock_logger_calls {}
} -body {
    myexec "some-script.exp" "arg1"
    set call [lindex $::mock_logger_calls 0]
    set msg [lindex $call end]
    string match "*some-script.exp*Success*" $msg
} -cleanup {
    mock_exec_clear
} -result 1

test myexec-success-logs-info-level {myexec logs at user.info on success} -setup {
    mock_exec_ok "Success"
    set ::mock_logger_calls {}
} -body {
    myexec "some-script.exp" "arg1"
    set call [lindex $::mock_logger_calls 0]
    expr {[lsearch $call "user.info"] >= 0}
} -cleanup {
    mock_exec_clear
} -result 1

test myexec-childstatus-fail-exits {myexec exits 1 on non-zero CHILDSTATUS} -setup {
    mock_exec_fail "commit failed" 1
} -body {
    set caught [catch {myexec "some-script.exp"} err opts]
    set code [dict get $opts -errorcode]
    list $caught [lindex $code 0] [lindex $code 1]
} -cleanup {
    mock_exec_clear
} -result {1 EXIT 1}

test myexec-childstatus-fail-logs-error-level {
    myexec logs at user.error, not user.info, when the child process fails --
    otherwise SSH failures/timeouts/unknown-command/HA-sync/platform-capacity
    rejections from the four .exp sub-scripts are indistinguishable from
    routine success by syslog priority
} -setup {
    mock_exec_fail "commit failed" 1
    set ::mock_logger_calls {}
} -body {
    catch {myexec "some-script.exp"}
    set call [lindex $::mock_logger_calls 0]
    expr {[lsearch $call "user.error"] >= 0}
} -cleanup {
    mock_exec_clear
} -result 1

test myexec-other-error-exits {myexec exits 1 on non-CHILDSTATUS error} -setup {
    mock_exec_other_error "no such file"
} -body {
    set caught [catch {myexec "missing-script.exp"} err opts]
    set code [dict get $opts -errorcode]
    list $caught [lindex $code 0] [lindex $code 1]
} -cleanup {
    mock_exec_clear
} -result {1 EXIT 1}

test myexec-other-error-logs-error-level {
    myexec logs at user.error on a non-CHILDSTATUS exec error too
} -setup {
    mock_exec_other_error "no such file"
    set ::mock_logger_calls {}
} -body {
    catch {myexec "missing-script.exp"}
    set call [lindex $::mock_logger_calls 0]
    expr {[lsearch $call "user.error"] >= 0}
} -cleanup {
    mock_exec_clear
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
# mydig - reverse DNS lookup wrapper
# ========================================================================

test mydig-success {mydig returns hostname on success} -setup {
    mock_exec_ok "server01.domain.com."
} -body {
    mydig "10.0.0.1"
} -cleanup {
    mock_exec_clear
} -result "server01.domain.com."

test mydig-empty-result {mydig returns empty string when no PTR record} -setup {
    mock_exec_ok ""
} -body {
    mydig "10.0.0.1"
} -cleanup {
    mock_exec_clear
} -result ""

test mydig-childstatus-fail-exits {mydig exits 1 on non-zero CHILDSTATUS} -setup {
    mock_exec_fail "dig: couldn't get address" 1
} -body {
    set caught [catch {mydig "10.0.0.1"} err opts]
    set code [dict get $opts -errorcode]
    list $caught [lindex $code 0] [lindex $code 1]
} -cleanup {
    mock_exec_clear
} -result {1 EXIT 1}

test mydig-other-error-exits {mydig exits 1 on non-CHILDSTATUS error} -setup {
    mock_exec_other_error "no such file"
} -body {
    set caught [catch {mydig "10.0.0.1"} err opts]
    set code [dict get $opts -errorcode]
    list $caught [lindex $code 0] [lindex $code 1]
} -cleanup {
    mock_exec_clear
} -result {1 EXIT 1}

test mydig-fail-logs-error-level {mydig logs at error level on failure} -setup {
    mock_exec_fail "dig: couldn't get address" 1
    set ::mock_logger_calls {}
} -body {
    catch {mydig "10.0.0.1"}
    set call [lindex $::mock_logger_calls 0]
    expr {[lsearch $call "user.error"] >= 0}
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

test discover-firewall-dns-match {firewall mode: skip agent already configured (DNS)} -body {
    set config(template) ""
    set agent_name "server01"
    set existing "set vsys vsys1 ts-agent server01 host server01.domain.com port 5009"
    string match "*$config(template)*ts-agent $agent_name*" $existing
} -result 1

test discover-firewall-dns-no-match {firewall mode: detect new agent (DNS)} -body {
    set config(template) ""
    set agent_name "newserver"
    set existing "set vsys vsys1 ts-agent server01 host server01.domain.com port 5009"
    string match "*$config(template)*ts-agent $agent_name*" $existing
} -result 0

test discover-firewall-ip-match {firewall mode: skip agent already configured (IP)} -body {
    set config(template) ""
    set agent_name "10.0.0.1"
    set existing "set vsys vsys1 ts-agent 10.0.0.1 host 10.0.0.1 port 5009"
    string match "*$config(template)*ts-agent $agent_name host*" $existing
} -result 1

test discover-firewall-ip-no-match {firewall mode: detect new agent (IP)} -body {
    set config(template) ""
    set agent_name "10.0.0.99"
    set existing "set vsys vsys1 ts-agent 10.0.0.1 host 10.0.0.1 port 5009"
    string match "*$config(template)*ts-agent $agent_name host*" $existing
} -result 0

test discover-firewall-multi-agent {firewall mode: match among multiple agents} -body {
    set config(template) ""
    set agent_name "server02"
    set existing "set vsys vsys1 ts-agent server01 host server01.dom.com port 5009
set vsys vsys1 ts-agent server02 host server02.dom.com port 5009
set vsys vsys1 ts-agent server03 host server03.dom.com port 5009"
    string match "*$config(template)*ts-agent $agent_name*" $existing
} -result 1


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

# ------------------------------------------------------------------------
# Characterization tests: discover.tcl's agent_host reconstruction
# (see the KNOWN LIMITATION comment above the split in discover.tcl).
# These pin down the CURRENT behavior, including the known-wrong outputs
# for non-3-label PTR values, so a future change to that logic is a
# deliberate, visible decision rather than an accidental behavior change.
# agent_host is a display/label value on the firewall object, not a value
# PAN-OS resolves to connect (connectivity is always via the
# already fping/TLS-verified IP), so these wrong outputs are cosmetic today
# -- but "cosmetic" is exactly why it's easy to change by accident without
# a test noticing.
# ------------------------------------------------------------------------

proc build_agent_host {dig} {
    set agent_name [lindex [split $dig "."] 0]
    set domain [lindex [split $dig "."] 1]
    set tld [lindex [split $dig "."] 2]
    set agent_host "$agent_name.$domain.$tld"
    return [list $agent_name $agent_host]
}

test discover-agent-host-3-labels {agent_host: exactly 3 labels reconstructs correctly} -body {
    build_agent_host "server01.domain.com."
} -result {server01 server01.domain.com}

test discover-agent-host-more-than-3-labels {
    agent_host: KNOWN LIMITATION -- more than 3 labels (e.g. a nested/AD
    domain) silently truncates, dropping the trailing labels
} -body {
    build_agent_host "server01.dc1.corp.example.com."
} -result {server01 server01.dc1.corp}

test discover-agent-host-2-labels {
    agent_host: KNOWN LIMITATION -- a single-label domain (no TLD split
    position) leaves a trailing-dot artifact
} -body {
    build_agent_host "server01.lan."
} -result {server01 server01.lan.}

test discover-agent-host-1-label {
    agent_host: KNOWN LIMITATION -- a bare hostname with no domain at all
    leaves a double trailing-dot artifact
} -body {
    build_agent_host "server01"
} -result {server01 server01..}


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
# purge.tcl combined decision logic (not-conn match AND mytsagent recheck)
# ========================================================================

# mirrors purge.tcl's actual loop, including its malformed-line catch and
# object/hostname charset gate
proc purge_decide {notconn} {
    set delete {}
    set found {}
    foreach n [split $notconn "\n"] {
        if {[string match "*not-conn:*" $n]} {
            if {[catch {
                set object   [lindex $n 0]
                set hostname [lindex $n 1]
            }]} {
                continue
            }
            if { ![regexp {^[A-Za-z0-9._-]+$} $object] || ![regexp {^[A-Za-z0-9._-]+$} $hostname] } {
                continue
            }
            lappend found $object
            if {! [mytsagent $hostname]} {
                lappend delete $object
            }
        }
    }
    return [list $found $delete]
}

test purge-decide-deletes-unreachable {agent stays not-conn and fails the recheck -> deleted} -setup {
    mock_exec_fail "connection refused" 1
} -body {
    purge_decide "server01   10.0.0.1   5009   vsys1   not-conn:   0/0/0"
} -cleanup {
    mock_exec_clear
} -result {server01 server01}

test purge-decide-keeps-reachable {agent shows not-conn but responds to the recheck -> kept, not deleted} -setup {
    mock_exec_ok "Subject: CN = Terminal Server Agent"
} -body {
    purge_decide "server01   10.0.0.1   5009   vsys1   not-conn:   0/0/0"
} -cleanup {
    mock_exec_clear
} -result {server01 {}}

test purge-decide-ignores-connected-lines {connected lines are never evaluated or deleted} -setup {
    mock_exec_fail "connection refused" 1
} -body {
    purge_decide "server01   10.0.0.1   5009   vsys1   connected:   192.168.1.1"
} -cleanup {
    mock_exec_clear
} -result {{} {}}

test purge-decide-multiline-all-unreachable {multiple not-conn agents, all unreachable -> all deleted} -setup {
    mock_exec_fail "connection refused" 1
} -body {
    purge_decide "server01   10.0.0.1   5009   vsys1   not-conn:   0/0/0
server02   10.0.0.2   5009   vsys1   not-conn:   0/0/0"
} -cleanup {
    mock_exec_clear
} -result {{server01 server02} {server01 server02}}

test purge-decide-skips-malformed-line {malformed not-conn line is skipped, not counted as found or deleted} -setup {
    mock_exec_fail "connection refused" 1
} -body {
    purge_decide "server01 \{ unbalanced not-conn: brace
server02   10.0.0.2   5009   vsys1   not-conn:   0/0/0"
} -cleanup {
    mock_exec_clear
} -result {server02 server02}

test purge-decide-rejects-embedded-cr-in-object {
    a braced list element carrying a literal \r in the object field parses
    cleanly (no Tcl list error) but must be rejected by the charset gate --
    otherwise the \r would reach send "...ts-agent $object\r" and inject an
    extra CLI command
} -setup {
    mock_exec_fail "connection refused" 1
} -body {
    purge_decide "\{server\r01\}   10.0.0.1   5009   vsys1   not-conn:   0/0/0
server02   10.0.0.2   5009   vsys1   not-conn:   0/0/0"
} -cleanup {
    mock_exec_clear
} -result {server02 server02}

test purge-decide-rejects-embedded-cr-in-hostname {
    same as above but the \r is smuggled in the hostname field, which flows
    into mytsagent's exec and, on delete, is not sent directly but must still
    be rejected symmetrically with object
} -setup {
    mock_exec_fail "connection refused" 1
} -body {
    purge_decide "server01   \{10.0.0.1\r\}   5009   vsys1   not-conn:   0/0/0
server02   10.0.0.2   5009   vsys1   not-conn:   0/0/0"
} -cleanup {
    mock_exec_clear
} -result {server02 server02}

test purge-decide-accepts-normal-object {
    sanity check: the new charset gate does not reject ordinary object/hostname
    values -- a plain not-conn line still gets found/deleted as before
} -setup {
    mock_exec_fail "connection refused" 1
} -body {
    purge_decide "server01.domain-01   10.0.0.1   5009   vsys1   not-conn:   0/0/0"
} -cleanup {
    mock_exec_clear
} -result {server01.domain-01 server01.domain-01}


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
