#!/usr/bin/env tclsh
# Fuzz harness: adversarial DNS PTR / hostname strings run through the
# discover.tcl / purge.tcl / tsagent-modify-*.exp data pipeline.
#
# `mydig`'s output (a reverse DNS PTR record -- attacker-influenceable if the
# attacker controls DNS for a scanned subnet) flows with no sanitization into
# live PAN-OS CLI `send` commands and into `string match` glob patterns. This
# harness generates adversarial candidate hostnames and checks three
# invariants that matter for that reason:
#
#   no-crlf        agent_name/agent_host/object/hostname must never contain
#                   \r or \n -- an embedded newline would submit a
#                   premature/extra command into the live SSH session
#   csv-roundtrip   the "$agent_name,$agent_host" add-list encoding
#                   (discover.tcl) must round-trip through the
#                   "[lindex [split $i ,] 0/1]" decoding
#                   (tsagent-modify-*.exp) without corruption
#   glob-injection  discover.tcl's "already configured" check
#                   (string match "*...ts-agent $agent_name*" $existing)
#                   must not be foolable by glob metacharacters in
#                   agent_name into a false match against an unrelated
#                   existing agent
#
# Run: tclsh src/tests/fuzz-injection.test.tcl [iterations] [seed]
# Exits 1 (and prints repro cases) if any invariant is violated.

set iterations 2000
set seed 1
if {[llength $argv] >= 1} { set iterations [lindex $argv 0] }
if {[llength $argv] >= 2} { set seed [lindex $argv 1] }
expr {srand($seed)}

# ---- fixed corpus: named edge cases, always run first for reproducibility ----
set corpus [list \
    "" \
    "." \
    ".." \
    "..." \
    "a" \
    "a." \
    "a.b" \
    "a.b.c" \
    "a.b.c.d.e.f" \
    "server01,evil,extra" \
    "server01\r\nset ts-agent evil host evil.example.com port 5009 disabled no" \
    "server01\r\ndelete template shared_temp config vsys vsys1 ts-agent legituser01" \
    "server01\ninjected.example.com" \
    "*" \
    "*.example.com" \
    "?.example.com" \
    "\[a-z\].example.com" \
    "legituser01.corp.example.com" \
    "server\"01.example.com" \
    "server'01.example.com" \
    "server 01.example.com" \
    "server\t01.example.com" \
    "ééé.example.com" \
    [string repeat "a" 5000] \
]

# ---- random mutator: combine adversarial fragments ----
set badfrags [list "\r" "\n" "\r\n" "," "*" "?" "\[" "\]" "\\" "\"" "'" " " "\t" "." ".." "ts-agent" "shared_temp" ""]
proc randfrag {} {
    global badfrags
    lindex $badfrags [expr {int(rand()*[llength $badfrags])}]
}
proc randstr {} {
    set n [expr {int(rand()*8)+1}]
    set s ""
    for {set i 0} {$i < $n} {incr i} { append s [randfrag] }
    return $s
}

# ---- pipeline replication (mirrors discover.tcl / tsagent-modify-*.exp) ----

# discover.tcl: PTR record validation gate -- reject anything outside a plain
# hostname charset before it ever reaches the CSV/CLI/glob pipeline below
proc pipeline_valid_ptr {dig} {
    regexp {^[A-Za-z0-9._-]+$} $dig
}

# discover.tcl: FQDN split -> agent_name/agent_host
proc pipeline_split {dig} {
    set agent_name [lindex [split $dig "."] 0]
    set domain     [lindex [split $dig "."] 1]
    set tld        [lindex [split $dig "."] 2]
    set agent_host "$agent_name.$domain.$tld"
    return [list $agent_name $agent_host]
}

# discover.tcl: add-list CSV encoding ("lappend add \"$agent_name,$agent_host\"")
proc pipeline_encode {agent_name agent_host} {
    return "$agent_name,$agent_host"
}

# tsagent-modify-panorama.exp / tsagent-modify-firewall.exp: CSV decoding
proc pipeline_decode {entry} {
    set object   [lindex [split $entry ","] 0]
    set hostname [lindex [split $entry ","] 1]
    return [list $object $hostname]
}

# discover.tcl's "already configured" check, against a fixed unrelated fixture
set fixture_existing "set template shared_temp config vsys vsys1 ts-agent legituser01 host legituser01.corp.example.com port 5009 disabled no"

proc glob_escape {s} {
    set out ""
    foreach c [split $s ""] {
        switch -- $c {
            "\\" - "*" - "?" - "\[" - "\]" { append out "\\" $c }
            default { append out $c }
        }
    }
    return $out
}

# what discover.tcl actually does today
proc pipeline_already_configured_raw {agent_name} {
    global fixture_existing
    string match "*shared_temp*ts-agent $agent_name*" $fixture_existing
}

# what it *should* mean if agent_name were treated as a literal string
proc pipeline_already_configured_literal {agent_name} {
    global fixture_existing
    string match "*shared_temp*ts-agent [glob_escape $agent_name]*" $fixture_existing
}

# ---- invariant checks ----
set violations {}

proc check {input} {
    # discover.tcl skips (continue) anything that fails the PTR validation gate
    # before it ever reaches the vulnerable pipeline -- mirror that here
    if { ![pipeline_valid_ptr $input] } { return }

    if {[catch {
        set parts [pipeline_split $input]
        set agent_name [lindex $parts 0]
        set agent_host [lindex $parts 1]
    } err]} {
        lappend ::violations [list "pipeline-error" $input "split/join threw: $err"]
        return
    }

    # invariant: no-crlf
    foreach {label val} [list agent_name $agent_name agent_host $agent_host] {
        if {[string first "\r" $val] >= 0 || [string first "\n" $val] >= 0} {
            lappend ::violations [list "no-crlf" $input "$label=[list $val] contains CR/LF -- would inject an extra command into the live CLI send"]
        }
    }

    # invariant: csv-roundtrip
    set entry [pipeline_encode $agent_name $agent_host]
    set decoded [pipeline_decode $entry]
    set object [lindex $decoded 0]
    set hostname [lindex $decoded 1]
    if {$object ne $agent_name || $hostname ne $agent_host} {
        lappend ::violations [list "csv-roundtrip" $input "encode/decode mismatch: object=[list $object] hostname=[list $hostname] vs agent_name=[list $agent_name] agent_host=[list $agent_host]"]
    }

    # invariant: glob-safety of the already-configured check
    set raw [pipeline_already_configured_raw $agent_name]
    set literal [pipeline_already_configured_literal $agent_name]
    if {$raw != $literal} {
        lappend ::violations [list "glob-injection" $input "agent_name=[list $agent_name] -- raw string match ($raw) disagrees with literal containment ($literal) against an unrelated existing agent"]
    }
}

# ---- run corpus + random mutations ----
foreach c $corpus { check $c }
for {set i 0} {$i < $iterations} {incr i} { check [randstr] }

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
