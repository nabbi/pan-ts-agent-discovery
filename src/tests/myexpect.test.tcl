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
    unset -nocomplain ::skipped_deletes
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

test myexpect-object-doesnt-exist-does-not-abort {
    "Object doesn't exist" warns and keeps waiting instead of exiting, so a
    prompt arriving right after it in the same output still completes normally
} -body {
    run_myexpect "Object doesn't exist\nadmin@fw#" "admin@fw#"
} -result {OK {}}

test myexpect-object-doesnt-exist-counts-skip {
    "Object doesn't exist" increments the skipped_deletes counter so callers
    can report a summary instead of the run silently swallowing it
} -body {
    run_myexpect "Object doesn't exist\nadmin@fw#" "admin@fw#"
    set ::skipped_deletes
} -result {1}

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

# a fake PAN-OS-like CLI: echoes a prompt after every line it reads, and additionally
# emits "Object doesn't exist" first for specific objects -- mirrors the real multi-command
# interaction pattern used by tsagent-modify-panorama.exp/tsagent-modify-firewall.exp's
# delete loop (repeated send "delete ... $object\r"; myexpect "$prompt#" over one PTY),
# so this exercises the actual session shape rather than a single isolated myexpect call.
set fake_cli_script {
while IFS= read -r line; do
    case "$line" in
        *missing1*|*missing2*) echo "Object doesn't exist" ;;
    esac
    echo "admin@fw#"
done
}

proc run_delete_batch {objects} {
    global spawn_id fake_cli_script
    set ::exit_code {}
    unset -nocomplain ::skipped_deletes
    spawn /bin/sh -c $fake_cli_script
    foreach o $objects {
        send "delete vsys vsys1 ts-agent $o\r"
        myexpect "admin@fw#"
        if {$::exit_code ne {}} {
            catch {close}
            catch {wait}
            return [list EXIT $::exit_code]
        }
    }
    catch {close}
    catch {wait}
    set skipped 0
    if {[info exists ::skipped_deletes]} { set skipped $::skipped_deletes }
    return [list OK $skipped]
}

test myexpect-delete-batch-mixed {
    a delete batch with some missing and some present objects processes every
    object in order -- no early abort -- and tallies exactly the missing ones
} -body {
    run_delete_batch {present1 missing1 present2 missing2 present3}
} -result {OK 2}

test myexpect-delete-batch-all-present {
    a batch where nothing is missing leaves the skip counter at zero
} -body {
    run_delete_batch {present1 present2 present3}
} -result {OK 0}

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
