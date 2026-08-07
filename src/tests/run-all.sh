#!/usr/bin/env bash
# Runs the full pass/fail test suite plus all fuzz harnesses and reports a
# single summary. Fuzz harnesses are not part of the pass/fail suite per
# CLAUDE.md, but this script runs them too since regressions there are real
# and easy to miss otherwise.
#
# Usage:
#   src/tests/run-all.sh                  # tests + fuzz (default iterations/seed)
#   src/tests/run-all.sh --tests-only      # skip fuzz harnesses
#   src/tests/run-all.sh --fuzz-only       # skip tcltest/expect suite
#   src/tests/run-all.sh --iterations 5000 --seed 42

set -u

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

iterations=""
seed=""
run_tests=1
run_fuzz=1

while [ $# -gt 0 ]; do
    case "$1" in
        --tests-only) run_fuzz=0 ;;
        --fuzz-only) run_tests=0 ;;
        --iterations) shift; iterations="${1:-}" ;;
        --seed) shift; seed="${1:-}" ;;
        -h|--help)
            sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            exit 2
            ;;
    esac
    shift
done

pass=0
fail=0
declare -a failed_names=()

run_one() {
    local name="$1"
    shift
    echo "==> $name"
    if "$@"; then
        echo "--- PASS: $name"
        pass=$((pass + 1))
    else
        echo "--- FAIL: $name (exit $?)"
        fail=$((fail + 1))
        failed_names+=("$name")
    fi
    echo
}

if [ "$run_tests" = "1" ]; then
    run_one "common-proc.test.tcl" tclsh "$script_dir/common-proc.test.tcl"
    run_one "myexpect.test.tcl" expect "$script_dir/myexpect.test.tcl"
    run_one "exp-e2e.test.tcl" expect "$script_dir/exp-e2e.test.tcl"
fi

if [ "$run_fuzz" = "1" ]; then
    for f in fuzz-injection fuzz-purge-parsing fuzz-log fuzz-myfping; do
        args=()
        [ -n "$iterations" ] && args+=("$iterations")
        [ -n "$seed" ] && args+=("$seed")
        run_one "$f.test.tcl" tclsh "$script_dir/$f.test.tcl" "${args[@]}"
    done
fi

echo "================================================================"
echo "$pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    echo "failed:"
    for n in "${failed_names[@]}"; do
        echo "  - $n"
    done
    exit 1
fi
exit 0
