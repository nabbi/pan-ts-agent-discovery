#!/usr/bin/expect
# End-to-end tests for the four .exp scripts that were previously untested by
# any automated test: tsagent-configured.exp, tsagent-not-connected.exp,
# tsagent-modify-firewall.exp, tsagent-modify-panorama.exp (and, as a side
# effect of running through them, ssh-init.exp).
#
# Run: expect src/tests/exp-e2e.test.tcl
#
# Approach: this sandbox pins the `ssh` binary regardless of PATH (verified
# separately -- shadowing any other binary name via PATH works fine, only
# `ssh` specifically is not interceptable that way here), so a real ssh
# session to a fake local sshd is not a workable test strategy in this
# environment. Instead this intercepts Expect's own `spawn` command (same
# rename-and-wrap mock pattern already used for `exec`/`exit` elsewhere in
# this test suite): when the script under test calls `spawn ssh ...`, we
# redirect that spawn to a local fake PAN-OS CLI shell script instead. The
# four .exp files themselves are `source`d unmodified, so their real
# send/expect control flow, real commit-vs-skip arithmetic, and real `send`
# line construction all execute for real -- this is not a mirrored copy of
# their logic.
#
# The fake CLI stub is a small POSIX shell state machine (operational vs
# config mode, matching how "exit" behaves differently in each) that logs
# every line it receives to a per-scenario file, which the test then reads
# back to assert on the exact commands the real .exp file sent.
#
# Known cost: ssh-init.exp does two real `sleep 1` calls and
# tsagent-modify-panorama.exp does one real `after 15000` before its
# commit-all loop -- these are intercepted below (recorded, not executed) so
# the suite stays fast and deterministic rather than clock-dependent.

package require tcltest
namespace import -force ::tcltest::*

# ---- mock exit: record the code instead of terminating (see myexpect.test.tcl
# for why -- throwing out of an expect action block corrupts Expect's state) ----
rename exit _real_exit
set ::exit_code {}
proc exit {{code 0}} {
    set ::exit_code $code
}

# ---- mock sleep/after: the real .exp files call these for real pacing
# against a real device; against our instant-responding fake CLI they'd just
# be pure wall-clock tax. Record calls, don't actually wait. ----
rename sleep _real_sleep
set ::sleep_calls {}
proc sleep {secs} { lappend ::sleep_calls $secs }

rename after _real_after
set ::after_calls {}
proc after {args} {
    if {[llength $args] == 1 && [string is integer -strict [lindex $args 0]]} {
        lappend ::after_calls [lindex $args 0]
        return
    }
    _real_after {*}$args
}

# ---- mock spawn: redirect `spawn ssh ...` to a local fake CLI, pass
# everything else through untouched ----
rename spawn _real_spawn
set ::current_stub {}
proc spawn {args} {
    global spawn_id
    if {[lindex $args 0] eq "ssh"} {
        return [uplevel 1 [list _real_spawn /bin/sh -c $::current_stub]]
    }
    return [uplevel 1 [list _real_spawn {*}$args]]
}

log_user 0
set timeout 10

set path [file dirname [file normalize [info script]]]
set expdir [file normalize "$path/../exp"]
set configtcl "$expdir/../inc/config.tcl"

# ---- gitignored config.tcl: create for the duration of this test file, remove after ----
if {[file exists $configtcl]} {
    error "refusing to overwrite an existing src/inc/config.tcl -- remove it or move it aside before running this test"
}
set cf [open $configtcl w]
puts $cf {
set config(networks) {}
set config(strict) 0
set config(dns) 1
set config(panorama) disable
set config(firewall) fw-host
set config(username) admin
set config(password) testpass123
set config(template) temp_shared
set config(vsys) vsys1
set config(templatestacks) {stack1}
}
close $cf

# ---- scratch dir for per-scenario command logs ----
set scratch [file normalize "$path/../../.e2e-scratch"]
file mkdir $scratch

proc reset_state {} {
    set ::exit_code {}
    set ::sleep_calls {}
    set ::after_calls {}
    unset -nocomplain ::skipped_deletes
}

proc read_log {logfile} {
    if {![file exists $logfile]} { return {} }
    set fh [open $logfile r]
    set data [read $fh]
    close $fh
    return [split [string trim $data] "\n"]
}

# generic fake PAN-OS CLI: tracks operational vs config mode (exit means
# different things in each), logs every received line, and answers "set cli
# ..."/generic commands with the right prompt by default. %LOG%/%EXTRA% are
# substituted per scenario.
set stub_template {
LOG="%LOG%"
: > "$LOG"
mode=operational
printf 'Password:'
read -r pw
printf 'admin@fw>\n'
while IFS= read -r line; do
  printf '%s\n' "$line" >> "$LOG"
  case "$line" in
    configure)
      mode=config
      printf 'admin@fw#\n'
      ;;
    exit)
      if [ "$mode" = "config" ]; then
        mode=operational
        printf 'admin@fw>\n'
      else
        exit 0
      fi
      ;;
%EXTRA%
    *)
      if [ "$mode" = "config" ]; then
        printf 'admin@fw#\n'
      else
        printf 'admin@fw>\n'
      fi
      ;;
  esac
done
}

proc build_stub {logfile {extra {}}} {
    global stub_template
    set s [string map [list %LOG% $logfile %EXTRA% $extra] $stub_template]
    return $s
}


# ========================================================================
# tsagent-not-connected.exp
# ========================================================================

test e2e-not-connected-basic {
    tsagent-not-connected.exp: the real script runs the full ssh-init.exp
    negotiation plus its own show command against a fake CLI, end to end
} -setup {
    reset_state
    set logfile [file join $scratch "not-connected-basic.log"]
    set ::current_stub [build_stub $logfile {
    *not-conn*)
      printf 'server01            10.0.0.1        5009    vsys1        not-conn:       0/0/0\n'
      printf 'server02            10.0.0.2        5009    vsys1        not-conn:       0/0/0\n'
      printf 'admin@fw>\n'
      ;;}]
    set argv [list fw-host]
} -body {
    source $expdir/tsagent-not-connected.exp
    list $::exit_code [read_log $logfile]
} -result {0 {{set cli pager off} {set cli scripting-mode on} {show user ts-agent statistics | match not-conn} exit}}


# ========================================================================
# tsagent-configured.exp
# ========================================================================

test e2e-configured-basic {
    tsagent-configured.exp: enters config mode, runs its show|match, exits
    config mode, then exits the session -- verifies the real command
    sequence and mode transitions, not a mirrored copy
} -setup {
    reset_state
    set logfile [file join $scratch "configured-basic.log"]
    set ::current_stub [build_stub $logfile {
    *match*ts-agent*)
      printf 'set template temp_shared config vsys vsys1 ts-agent existingagent host existingagent.domain.com port 5009 disabled no\n'
      printf 'admin@fw#\n'
      ;;}]
    set argv [list fw-host]
} -body {
    source $expdir/tsagent-configured.exp
    list $::exit_code [read_log $logfile]
} -result {0 {{set cli pager off} {set cli scripting-mode on} {set cli config-output-format set} configure {show | match "ts-agent.*host"} exit exit}}


# ========================================================================
# tsagent-modify-firewall.exp -- add
# ========================================================================

test e2e-modify-firewall-add-single {
    tsagent-modify-firewall.exp add: real send line for a single new agent,
    and a commit is issued since the config was actually modified
} -setup {
    reset_state
    set logfile [file join $scratch "firewall-add-single.log"]
    set ::current_stub [build_stub $logfile {}]
    set argv [list add fw-host "server01,server01.domain.com"]
} -body {
    source $expdir/tsagent-modify-firewall.exp
    list $::exit_code [read_log $logfile]
} -result {0 {{set cli pager off} {set cli scripting-mode on} {set cli config-output-format set} configure {set vsys vsys1 ts-agent server01 host server01.domain.com port 5009 disabled no} {commit description BackgroundInfrastructureTask-TerminalServicesAgent partial admin admin} exit exit}}

test e2e-modify-firewall-add-multiple {
    tsagent-modify-firewall.exp add: multiple agents in one add-list each get
    their own send line, and exactly one commit covers all of them
} -setup {
    reset_state
    set logfile [file join $scratch "firewall-add-multi.log"]
    set ::current_stub [build_stub $logfile {}]
    set argv [list add fw-host [list "server01,server01.domain.com" "server02,server02.domain.com"]]
} -body {
    source $expdir/tsagent-modify-firewall.exp
    read_log $logfile
} -result {{set cli pager off} {set cli scripting-mode on} {set cli config-output-format set} configure {set vsys vsys1 ts-agent server01 host server01.domain.com port 5009 disabled no} {set vsys vsys1 ts-agent server02 host server02.domain.com port 5009 disabled no} {commit description BackgroundInfrastructureTask-TerminalServicesAgent partial admin admin} exit exit}


# ========================================================================
# tsagent-modify-firewall.exp -- delete
# ========================================================================

test e2e-modify-firewall-delete-mixed {
    tsagent-modify-firewall.exp delete: a batch with some missing and some
    present objects sends a delete for every one of them (no early abort on
    "Object doesn't exist"), and still commits since at least one delete
    actually changed candidate config
} -setup {
    reset_state
    set logfile [file join $scratch "firewall-delete-mixed.log"]
    set ::current_stub [build_stub $logfile {
    *"ts-agent missing1"*)
      printf "Object doesn't exist\n"
      printf 'admin@fw#\n'
      ;;}]
    set argv [list delete fw-host [list server01 missing1 server02]]
} -body {
    source $expdir/tsagent-modify-firewall.exp
    list $::exit_code $::skipped_deletes [read_log $logfile]
} -result {0 1 {{set cli pager off} {set cli scripting-mode on} {set cli config-output-format set} configure {delete vsys vsys1 ts-agent server01} {delete vsys vsys1 ts-agent missing1} {delete vsys vsys1 ts-agent server02} {commit description BackgroundInfrastructureTask-TerminalServicesAgent partial admin admin} exit exit}}

test e2e-modify-firewall-delete-all-missing-skips-commit {
    tsagent-modify-firewall.exp delete: DEVELOPMENT.md flagged this exact
    branch as untested -- when every delete target is already absent
    (modified == 0), no commit should be sent at all. This is the real
    production arithmetic (llength(input) - skipped_deletes), not a
    mirrored copy.
} -setup {
    reset_state
    set logfile [file join $scratch "firewall-delete-all-missing.log"]
    set ::current_stub [build_stub $logfile {
    *"ts-agent missing1"*|*"ts-agent missing2"*)
      printf "Object doesn't exist\n"
      printf 'admin@fw#\n'
      ;;}]
    set argv [list delete fw-host [list missing1 missing2]]
} -body {
    source $expdir/tsagent-modify-firewall.exp
    list $::exit_code $::skipped_deletes \
        [expr {[lsearch [read_log $logfile] "commit*"] >= 0}] \
        [read_log $logfile]
} -result {0 2 0 {{set cli pager off} {set cli scripting-mode on} {set cli config-output-format set} configure {delete vsys vsys1 ts-agent missing1} {delete vsys vsys1 ts-agent missing2} exit exit}}


# ========================================================================
# tsagent-modify-panorama.exp -- add / delete / commit-all gating
# ========================================================================

test e2e-modify-panorama-add-commits-and-pushes-stacks {
    tsagent-modify-panorama.exp add: real send line uses the template, a
    commit is sent, and -- since config actually changed -- commit-all fires
    for every configured template-stack (the 15s `after` delay before this
    loop is intercepted, not really waited on)
} -setup {
    reset_state
    set logfile [file join $scratch "panorama-add.log"]
    set ::current_stub [build_stub $logfile {}]
    set argv [list add panorama-host "server01,server01.domain.com"]
} -body {
    source $expdir/tsagent-modify-panorama.exp
    list $::exit_code $::after_calls [read_log $logfile]
} -result {0 15000 {{set cli pager off} {set cli scripting-mode on} {set cli config-output-format set} configure {set template temp_shared config vsys vsys1 ts-agent server01 host server01.domain.com port 5009 disabled no} {commit description BackgroundInfrastructureTask-TerminalServicesAgent partial admin admin} exit {commit-all template-stack description BackgroundInfrastructureTask-TerminalServicesAgent name stack1} exit}}

test e2e-modify-panorama-delete-all-missing-skips-commit-and-commitall {
    tsagent-modify-panorama.exp delete: the panorama variant deliberately
    gates BOTH commit and commit-all on modified > 0 (per the comment in the
    source) -- when nothing was actually deleted, neither should fire, and
    the 15s after-delay before commit-all should never even be reached
} -setup {
    reset_state
    set logfile [file join $scratch "panorama-delete-all-missing.log"]
    set ::current_stub [build_stub $logfile {
    *"ts-agent ghost"*)
      printf "Object doesn't exist\n"
      printf 'admin@fw#\n'
      ;;}]
    set argv [list delete panorama-host [list ghost]]
} -body {
    source $expdir/tsagent-modify-panorama.exp
    list $::exit_code $::skipped_deletes $::after_calls \
        [expr {[lsearch [read_log $logfile] "commit*"] >= 0}] \
        [expr {[lsearch [read_log $logfile] "commit-all*"] >= 0}]
} -result {0 1 {} 0 0}

test e2e-modify-panorama-multi-stack-commit-all {
    tsagent-modify-panorama.exp: commit-all is sent once per configured
    template-stack, each with the correct stack name, in order
} -setup {
    reset_state
    set logfile [file join $scratch "panorama-multi-stack.log"]
    set ::current_stub [build_stub $logfile {}]
    set argv [list add panorama-host "server01,server01.domain.com"]
    set savedconfig [read [set f [open $configtcl r]]]
    close $f
} -body {
    # override templatestacks for this one scenario only
    set cf [open $configtcl a]
    puts $cf {set config(templatestacks) {stack1 stack2}}
    close $cf
    source $expdir/tsagent-modify-panorama.exp
    set log [read_log $logfile]
    list [lsearch $log "commit-all template-stack description BackgroundInfrastructureTask-TerminalServicesAgent name stack1"] \
         [lsearch $log "commit-all template-stack description BackgroundInfrastructureTask-TerminalServicesAgent name stack2"]
} -cleanup {
    set cf [open $configtcl w]
    puts $cf $savedconfig
    close $cf
} -result {7 8}


# ========================================================================
# real send-line injection probe: exercises the ACTUAL send construction in
# tsagent-modify-firewall.exp (not a mirrored copy) against an adversarial
# object name, to prove -- independent of discover.tcl's upstream charset
# gate -- what these scripts would do if that gate were ever weakened
# ========================================================================

test e2e-firewall-delete-glob-metachars-rejected {
    an object name containing glob metacharacters is rejected by the new
    charset gate before it can ever reach a live send -- proves the gate
    (added alongside this harness) actually closes the glob-injection class
    of risk CLAUDE.md calls out for anything reaching `send`/`string match`,
    for the real production code path, not a mirrored copy. Since nothing
    was sent, modified stays 0 and no commit fires either.
} -setup {
    reset_state
    set logfile [file join $scratch "firewall-delete-glob.log"]
    set ::current_stub [build_stub $logfile {}]
    set argv [list delete fw-host [list {server*01?}]]
} -body {
    source $expdir/tsagent-modify-firewall.exp
    read_log $logfile
} -result {{set cli pager off} {set cli scripting-mode on} {set cli config-output-format set} configure exit exit}

test e2e-firewall-add-crlf-injection-blocked {
    real end-to-end proof of a genuine finding from this harness: $input is
    walked as a Tcl list inside tsagent-modify-firewall.exp, and Tcl
    list-whitespace includes \r (not just space/tab/newline). Before the
    charset gate added alongside this test, a single "object,host" add entry
    with an embedded \r fanned out into extra list elements -- one of which
    became the live send "set vsys vsys1 ts-agent legituser01 host  port
    5009 disabled no", silently overwriting an unrelated, already-configured
    ts-agent's host with an empty value. discover.tcl's PTR gate and
    purge.tcl's object/hostname gate both already exclude \r today, so this
    was not reachable via either caller -- but tsagent-modify-firewall.exp
    itself applied no independent validation, violating the "don't assume
    downstream callers re-validate" policy. This proves the new gate blocks
    it: only the one well-formed entry is sent, and "legituser01" never
    appears in any live command.
} -setup {
    reset_state
    set logfile [file join $scratch "firewall-add-crlf.log"]
    set ::current_stub [build_stub $logfile {}]
    set argv [list add fw-host "server01,evil.example.com\rdelete vsys vsys1 ts-agent legituser01"]
} -body {
    source $expdir/tsagent-modify-firewall.exp
    set log [read_log $logfile]
    list [llength $log] \
         [expr {[lsearch -glob $log "*legituser01*"] < 0}] \
         [lindex $log 4]
} -result {8 1 {set vsys vsys1 ts-agent server01 host evil.example.com port 5009 disabled no}}

test e2e-panorama-add-crlf-injection-blocked {
    mirrored proof for tsagent-modify-panorama.exp -- same Tcl-list-fanout
    mechanism, same gate, same expected outcome
} -setup {
    reset_state
    set logfile [file join $scratch "panorama-add-crlf.log"]
    set ::current_stub [build_stub $logfile {}]
    set argv [list add panorama-host "server01,evil.example.com\rdelete template temp_shared config vsys vsys1 ts-agent legituser01"]
} -body {
    source $expdir/tsagent-modify-panorama.exp
    set log [read_log $logfile]
    expr {[lsearch -glob $log "*legituser01*"] < 0}
} -result {1}

cleanupTests

