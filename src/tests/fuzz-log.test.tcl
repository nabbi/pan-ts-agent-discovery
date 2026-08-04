#!/usr/bin/env tclsh
# Fuzz harness: adversarial messages run through the shared `log` proc
# (src/inc/common-proc.tcl), which is the one function every logged event in
# discover.tcl/purge.tcl passes through on its way to syslog.
#
# Some of what reaches `log` is attacker-influenceable -- e.g. discover.tcl
# logs the raw, unvalidated PTR value when it rejects one (the one log line
# documented as "security-relevant" in docs/SPLUNK_ALERTS.md), and purge.tcl
# logs the raw, unparsed not-conn line from firewall CLI output. This harness
# checks three invariants that matter for that reason, plus one for runtime
# stability:
#
#   no-throw         log must never raise an uncaught error for any level/msg
#                     content, regardless of whether the underlying `logger`
#                     call itself succeeds or fails (syslog is a secondary
#                     sink and must not be able to abort the run)
#   no-raw-crlf      the message argument actually handed to `logger` must
#                     never contain a raw \r or \n -- either would let the
#                     logged content visually overwrite/hide the line in a
#                     terminal-based log viewer (log forging / CWE-117)
#   length-bound      the message body must never exceed 200 chars (plus the
#                     " ..." suffix when truncated), regardless of input
#                     length or byte content (multibyte, control chars, etc)
#   logger-attempted   log must still attempt the logger call (not silently
#                     skip it) even when the mock is set to fail it
#
# Run: tclsh src/tests/fuzz-log.test.tcl [iterations] [seed]
# Exits 1 (and prints repro cases) if any invariant is violated.

set iterations 2000
set seed 1
if {[llength $argv] >= 1} { set iterations [lindex $argv 0] }
if {[llength $argv] >= 2} { set seed [lindex $argv 1] }
expr {srand($seed)}

# ---- mock exec/logger so this never touches the real host syslog ----
rename exec _real_exec
set ::mock_logger_calls {}
set ::mock_logger_fail 0

proc exec {args} {
    set clean $args
    if {[lindex $clean 0] eq "--"} { set clean [lrange $clean 1 end] }
    set cmd [lindex $clean 0]
    if {$cmd eq "logger"} {
        lappend ::mock_logger_calls $clean
        if {$::mock_logger_fail} {
            return -code error -errorcode {POSIX ENOENT {no such file}} \
                "couldn't execute \"logger\": no such file or directory"
        }
        return ""
    }
    error "unmocked exec call: $args"
}

# source the real log proc under test
set path [file dirname [file normalize [info script]]]
source $path/../inc/common-proc.tcl

# ---- fixed corpus: named edge cases, always run first for reproducibility ----
set corpus [list \
    "" \
    "\n" \
    "\r" \
    "\r\n" \
    "line1\nline2\nline3" \
    "line1\rline2" \
    "line1\r\nline2\r\nline3" \
    "mixed\ra\nb\r\nc" \
    "server01\rSAFE LOOKING TEXT" \
    "suspicious PTR record for 10.0.0.5, skipping: evil\rall clear, nothing to see" \
    "not-conn: server01 \{ unbalanced\r\ndelete vsys vsys1 ts-agent legituser01" \
    [string repeat "a" 199] \
    [string repeat "a" 200] \
    [string repeat "a" 201] \
    [string repeat "a" 5000] \
    [string repeat "\n" 500] \
    [string repeat "\r" 500] \
    "\x1b\[2J\x1b\[H fake cleared screen" \
    "null\x00byte" \
    "tab\ttab" \
    "ééé unicode ñ 日本語" \
    "server\"01.example.com" \
    "server'01.example.com" \
]

# ---- random mutator: combine adversarial fragments ----
set badfrags [list "\r" "\n" "\r\n" "\t" " " "\x1b" "\x00" "a" "" "ééé" \
    "server01" "not-conn:" "\{" "\}" "\"" "'" "\\"]
proc randfrag {} {
    global badfrags
    lindex $badfrags [expr {int(rand()*[llength $badfrags])}]
}
proc randstr {} {
    set n [expr {int(rand()*12)+1}]
    set s ""
    for {set i 0} {$i < $n} {incr i} { append s [randfrag] }
    return $s
}
proc randlevel {} {
    lindex {info error warning debug ""} [expr {int(rand()*5)}]
}

# ---- invariant checks ----
set violations {}

proc check {level msg failmode} {
    set ::mock_logger_calls {}
    set ::mock_logger_fail $failmode

    if {[catch { log $level $msg } err]} {
        lappend ::violations [list "no-throw" [list $level $msg $failmode] "log threw: $err"]
        return
    }

    if {[llength $::mock_logger_calls] == 0} {
        lappend ::violations [list "logger-attempted" [list $level $msg $failmode] "logger was never invoked"]
        return
    }

    set call [lindex $::mock_logger_calls 0]
    set body [lindex $call end]

    if {[string first "\r" $body] >= 0} {
        lappend ::violations [list "no-raw-crlf" [list $level $msg $failmode] "raw CR survived into logger arg: [list $body]"]
    }
    if {[string first "\n" $body] >= 0} {
        lappend ::violations [list "no-raw-crlf" [list $level $msg $failmode] "raw LF survived into logger arg: [list $body]"]
    }

    # body is "[info script] <message>" -- strip that known prefix before
    # checking the length bound, which applies to the message portion only
    set prefix_end [string first " " $body]
    set message_part [expr {$prefix_end >= 0 ? [string range $body [expr {$prefix_end+1}] end] : $body}]
    if {[string length $message_part] > 205} {
        lappend ::violations [list "length-bound" [list $level $msg $failmode] "message portion is [string length $message_part] chars: [list $message_part]"]
    }
}

# ---- run corpus + random mutations, each against both a working and a failing logger ----
foreach c $corpus {
    check "info" $c 0
    check "error" $c 1
}
for {set i 0} {$i < $iterations} {incr i} {
    check [randlevel] [randstr] [expr {int(rand()*2)}]
}

# ---- report ----
puts "Ran [expr {2*[llength $corpus] + $iterations}] cases ([llength $corpus] corpus x2 + $iterations random, seed=$seed)"
if {[llength $violations] == 0} {
    puts "No invariant violations found."
    exit 0
}

array set bycat {}
foreach v $violations {
    lassign $v cat input detail
    lappend bycat($cat) [list $input $detail]
}
puts "\n[llength $violations] violations across [array size bycat] categories:\n"
foreach cat [array names bycat] {
    set examples [lrange $bycat($cat) 0 2]
    puts "== $cat ([llength $bycat($cat)] cases, showing up to 3) =="
    foreach ex $examples {
        lassign $ex input detail
        puts "  input: [list $input]"
        puts "  ->     $detail"
    }
    puts ""
}
exit 1
