#!/usr/bin/env tclsh
# Fuzz harness: adversarial `show user ts-agent statistics | match not-conn`
# lines run through purge.tcl's per-line parsing loop.
#
# purge.tcl parses each not-conn line with plain `lindex`, which parses the
# line as a Tcl *list* -- an unbalanced brace or quote anywhere in the
# device's output throws a real Tcl error ("unmatched open brace/quote in
# list"). Without a catch around it, that error would propagate uncaught and
# abort the whole purge run, leaving stale agents unremoved -- a concrete
# mechanism for the "purge script has failed" scenario documented in
# docs/TROUBLESHOOTING.md's platform-capacity section.
#
# This checks that purge.tcl's per-line catch survives adversarial single
# lines without throwing, and that one malformed line does not prevent
# well-formed lines elsewhere in the same batch from being parsed correctly.
#
# Run: tclsh src/tests/fuzz-purge-parsing.test.tcl [iterations] [seed]
# Exits 1 (and prints repro cases) if any invariant is violated.

set iterations 2000
set seed 1
if {[llength $argv] >= 1} { set iterations [lindex $argv 0] }
if {[llength $argv] >= 2} { set seed [lindex $argv 1] }
expr {srand($seed)}

# ---- fixed corpus: named edge cases, always run first for reproducibility ----
set corpus [list \
    "server01   10.0.0.1   5009   vsys1   not-conn:   0/0/0" \
    "server01 \{ unbalanced not-conn: brace" \
    "server01 \"unterminated quote not-conn: x" \
    "not-conn:" \
    "a b c not-conn: \{d e" \
    "server01 not-conn: trailing\\" \
    "connected line, no keyword, should be ignored entirely" \
    "" \
    [string repeat "a" 5000] \
]

# ---- random mutator: combine adversarial fragments ----
set badfrags [list "\{" "\}" "\"" "\\" "not-conn:" " " "\t" "a" "0" "/" ""]
proc randfrag {} {
    global badfrags
    lindex $badfrags [expr {int(rand()*[llength $badfrags])}]
}
proc randline {} {
    set n [expr {int(rand()*10)+1}]
    set s ""
    for {set i 0} {$i < $n} {incr i} { append s [randfrag] }
    return $s
}

# ---- pipeline replication (mirrors purge.tcl's per-line parsing, including its catch) ----
proc purge_parse_line {n} {
    if {![string match "*not-conn:*" $n]} { return {} }
    if {[catch {
        set object   [lindex $n 0]
        set hostname [lindex $n 1]
    }]} {
        return {}
    }
    return [list $object $hostname]
}

set violations {}

proc check {input} {
    if {[catch { purge_parse_line $input } err]} {
        lappend ::violations [list "uncaught-error" $input "purge_parse_line threw: $err"]
    }
}

# a malformed line must not take out well-formed neighbors in the same batch
proc check_batch {lines} {
    if {[catch {
        set n 0
        foreach l $lines {
            if {[purge_parse_line $l] ne {}} { incr n }
        }
        if {$n < 2} {
            lappend ::violations [list "batch-neighbor-lost" $lines "expected 2 good lines to survive, got $n"]
        }
    } err]} {
        lappend ::violations [list "batch-abort" $lines "batch processing threw: $err"]
    }
}

# ---- run corpus + random single lines ----
foreach c $corpus { check $c }
for {set i 0} {$i < $iterations} {incr i} { check [randline] }

# ---- run batches: two known-good lines around one random adversarial line ----
set good1 "good01   10.0.0.1   5009   vsys1   not-conn:   0/0/0"
set good2 "good02   10.0.0.2   5009   vsys1   not-conn:   0/0/0"
for {set i 0} {$i < 200} {incr i} {
    check_batch [list $good1 [randline] $good2]
}

# ---- report ----
puts "Ran [expr {[llength $corpus] + $iterations + 200}] cases ([llength $corpus] corpus + $iterations random lines + 200 batches, seed=$seed)"
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
