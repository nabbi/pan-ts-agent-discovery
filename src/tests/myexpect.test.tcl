#!/usr/bin/expect
# Tests for exp/myexpect.exp - pattern matching and branch priority
# Run: expect src/tests/myexpect.test.tcl

package require tcltest
namespace import -force ::tcltest::*

# mock exit: record the code instead of terminating. Throwing a Tcl error out of
# an `expect` action block corrupts Expect's internal state (closes stdout), so
# unlike common-proc.test.tcl's mock, this one just records and returns.
rename exit _real_exit
set ::exit_code {}
proc exit {{code 0}} {
    set ::exit_code $code
}

set path [file dirname [file normalize [info script]]]
source $path/../exp/myexpect.exp

log_user 0
set timeout 5

# spawn a process that prints $text verbatim (no shell involved, no quoting concerns)
# then invoke myexpect against its output
proc run_myexpect {text {prompt "NEVERMATCH#"}} {
    global spawn_id
    set ::exit_code {}
    spawn /bin/echo $text
    myexpect $prompt
    if {$::exit_code ne {}} {
        return [list EXIT $::exit_code]
    }
    return [list OK {}]
}

test myexpect-unknown-command {"Unknown command" triggers exit 1} -body {
    run_myexpect "Unknown command: foo"
} -result {EXIT 1}

test myexpect-object-doesnt-exist {"Object doesn't exist" triggers exit 65} -body {
    run_myexpect "Object doesn't exist"
} -result {EXIT 65}

test myexpect-ha-sync-warning {HA sync warning triggers exit 1} -body {
    run_myexpect "WARNING: The running configuration is not currently synchronized to the HA peer"
} -result {EXIT 1}

test myexpect-platform-capacity {platform capacity error triggers exit 1} -body {
    run_myexpect "Error: Number of ts-agent (600) exceeds platform capacity (500)"
} -result {EXIT 1}

test myexpect-platform-capacity-beats-generic-error {
    platform-capacity branch is checked before the generic error/fail catch-alls
} -body {
    # this text also matches -nocase "error" and -nocase "fail" -- the specific
    # "exceeds platform capacity" branch must win since it is listed first
    run_myexpect "exceeds platform capacity, commit failed"
} -result {EXIT 1}

test myexpect-generic-error {unrecognized error text falls through to generic error catch} -body {
    run_myexpect "some other error occurred"
} -result {EXIT 1}

test myexpect-generic-invalid {unrecognized invalid text falls through to generic invalid catch} -body {
    run_myexpect "invalid syntax"
} -result {EXIT 1}

test myexpect-generic-fail {unrecognized fail text falls through to generic fail catch} -body {
    run_myexpect "operation fail"
} -result {EXIT 1}

test myexpect-clean-prompt-returns {matching prompt with no error keywords returns normally} -body {
    run_myexpect {admin@fw#} {admin@fw#}
} -result {OK {}}

test myexpect-timeout {no matching output before timeout exits 1} -body {
    set ::exit_code {}
    spawn sleep 3
    set timeout 1
    myexpect "NEVERMATCH#"
    set timeout 5
    if {$::exit_code ne {}} {
        list EXIT $::exit_code
    } else {
        list OK {}
    }
} -result {EXIT 1}

rename exit {}
rename _real_exit exit

cleanupTests
