#!/usr/bin/env tclsh
# Fuzz harness: adversarial `fping -a -g` output run through myfping's
# (src/inc/common-proc.tcl) IPv4 filtering logic.
#
# myfping's output feeds discover.tcl's main host loop (mytsagent/mydig get
# called per surviving "valid" entry), so two invariants matter here:
#
#   no-throw          myfping must never raise an uncaught error for any
#                       fping output content -- a single malformed/corrupted
#                       line must degrade (get filtered out), not crash the
#                       whole discover.tcl run. This harness exists because
#                       exactly this was found and fixed: "foreach ip
#                       $results" parsed fping's raw output as an implicit
#                       Tcl list, and a stray unbalanced brace/quote token
#                       threw "unmatched open brace in list" uncaught. The
#                       fix (splitting on "\n" first) is what this harness
#                       regression-guards.
#   well-formed-output every IP myfping returns as "valid" must actually be
#                       a syntactically well-formed dotted-quad (4 groups of
#                       1-3 digits, each 0-255) -- nothing malformed should
#                       ever leak through the filter.
#
# Run: tclsh src/tests/fuzz-myfping.test.tcl [iterations] [seed]
# Exits 1 (and prints repro cases) if any invariant is violated.

set iterations 2000
set seed 1
if {[llength $argv] >= 1} { set iterations [lindex $argv 0] }
if {[llength $argv] >= 2} { set seed [lindex $argv 1] }
expr {srand($seed)}

# ---- mock exec so this never touches the real fping binary ----
rename exec _real_exec
set ::mock_fping_output {}

proc exec {args} {
    global ::mock_fping_output
    return $::mock_fping_output
}

# source the real myfping proc under test
set path [file dirname [file normalize [info script]]]
source $path/../inc/common-proc.tcl

# ---- fixed corpus: named edge cases, always run first for reproducibility ----
set corpus [list \
    "10.0.0.1\n10.0.0.2\n10.0.0.3" \
    "" \
    "\n\n\n" \
    "\{unbalanced\n10.0.0.1" \
    "10.0.0.1\n\{unbalanced" \
    "\"unterminated\n10.0.0.1" \
    "10.0.0.1\n\}stray-close\n10.0.0.2" \
    "010.0.0.1" \
    "10.0.0.256" \
    "10.0.-1.2" \
    "10.0.abc.2" \
    "::1" \
    "10.0.0.1 (some-hostname.example.com)" \
    "ICMP Host Unreachable" \
    "10.0.0.1\r\n10.0.0.2\r\n" \
    "10.0.0.1\x00\n10.0.0.2" \
    "٥.0.0.1" \
    [string repeat "9" 500] \
    [string repeat "10.0.0.1\n" 2000] \
    [string repeat "a" 5000] \
]

set violations {}

# a well-formed dotted-quad: 4 groups of 1-3 digits each, each numerically 0-255
proc looks_well_formed {ip} {
    if { ![regexp {^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$} $ip -> a b c d] } {
        return 0
    }
    foreach o [list $a $b $c $d] {
        if { $o > 255 } { return 0 }
    }
    return 1
}

proc check {input} {
    set ::mock_fping_output $input
    if {[catch { myfping "10.0.0.0/24" } result]} {
        lappend ::violations [list "no-throw" $input "myfping threw: $result"]
        return
    }
    foreach ip $result {
        if { ![looks_well_formed $ip] } {
            lappend ::violations [list "well-formed-output" $input "myfping returned malformed entry as valid: [list $ip]"]
        }
    }
}

# ---- random mutator: combine adversarial fragments ----
set badfrags [list "\{" "\}" "\"" "\\" "\n" "\r" "\r\n" " " "\t" "." "0" "9" \
    "10.0.0.1" "256" "-1" "abc" "٥" ""]
proc randfrag {} {
    global badfrags
    lindex $badfrags [expr {int(rand()*[llength $badfrags])}]
}
proc randblob {} {
    set n [expr {int(rand()*15)+1}]
    set s ""
    for {set i 0} {$i < $n} {incr i} { append s [randfrag] }
    return $s
}

# ---- run corpus + random mutations ----
foreach c $corpus { check $c }
for {set i 0} {$i < $iterations} {incr i} { check [randblob] }

# ---- report ----
puts "Ran [expr {[llength $corpus] + $iterations}] cases ([llength $corpus] corpus + $iterations random, seed=$seed)"
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
