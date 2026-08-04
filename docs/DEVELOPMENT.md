# Development

## Testing

Tests use Tcl's built-in `tcltest` package -- no additional dependencies required beyond `tcl`.

### Run tests

```shell
tclsh src/tests/common-proc.test.tcl
expect src/tests/myexpect.test.tcl
```

### What is tested

The test suite validates the core logic with mocked external commands (no network or SSH required).

**common-proc.tcl procedures**
- `log` -- newline replacement, message truncation at 200 chars, syslog level forwarding
- `myexec` -- results passthrough on success, exit-1 on non-zero CHILDSTATUS and on other exec errors, logging of args/results
- `myfping` -- IPv4 address validation/filtering, fping exit code handling (0, 1, 2+)
- `mytsagent` -- TLS certificate string matching, error code handling (1, 104, etc)
- `mydig` -- hostname passthrough on success, exit-1 on failure, error-level logging on failure

**exp/myexpect.exp**
- Branch coverage for every named pattern (`Unknown command`, HA sync warning, platform-capacity commit failure, generic error/invalid/fail catch-alls, timeout)
- `Object doesn't exist` -> warns, increments a `skipped_deletes` counter, and keeps waiting on the same expect (`exp_continue`) instead of aborting, so a prompt arriving right after it still completes the call normally
- Priority: the platform-capacity branch is confirmed to win over the generic error/fail catch-alls when a message matches both
- A clean prompt match with no error keywords returns normally

This suite uses `expect` (not `tclsh`) since `myexpect.exp` drives the real `expect` command against a spawned process rather than pure Tcl logic. It spawns `/bin/echo`/`sleep` in place of an SSH session and asserts on the resulting exit code.

**discover.tcl logic**
- Panorama config pattern matching (DNS and IP modes)
- Firewall-mode config pattern matching (DNS and IP modes, multi-agent)
- Multi-agent and wrong-template rejection
- FQDN parsing (hostname, domain, TLD extraction)
- IP deduplication
- Add-list `object,hostname` format construction and parsing

**purge.tcl logic**
- `not-conn:` line pattern matching
- Object and hostname extraction from firewall output
- Multi-line output filtering with mixed connected/not-connected agents
- Combined decision logic (`purge_decide`): a not-conn agent is only deleted if it *also* fails the `mytsagent` recheck; connected lines are never evaluated; a malformed line is skipped without disturbing other lines in the same batch

### Test approach

External commands (`fping`, `openssl`, `dig`, `logger`, `ssh`) are mocked at the `exec` level. The `exit` command is also mocked so fatal error paths can be tested without terminating the interpreter. In `common-proc.test.tcl` the mock `exit` raises a catchable error; in `myexpect.test.tcl` it instead just records the code, since throwing an error out of an `expect` action block corrupts Expect's internal state. Note also that `spawn` sets `spawn_id` in the calling proc's local scope -- if you spawn from inside a test helper proc, `global spawn_id` is required before the spawn or `myexpect`'s own `expect` call won't find it and will hang until timeout.

Tests focus on the pure logic and string parsing that is most likely to break during refactoring -- the parts you can validate without live infrastructure.

### Adding tests

Place new test files in `src/tests/` using the `*.test.tcl` naming convention and the same mock pattern established in `common-proc.test.tcl`.

## Fuzzing

```shell
tclsh src/tests/fuzz-injection.test.tcl [iterations] [seed]
tclsh src/tests/fuzz-purge-parsing.test.tcl [iterations] [seed]
```

Both harnesses are seeded (default seed `1`) so a failing run is reproducible, and both exit 0 on a clean run / 1 with repro cases printed on a violation. Neither is wired into `common-proc.test.tcl`'s pass/fail suite -- run them separately.

### fuzz-injection.test.tcl

`mydig`'s output is a reverse DNS PTR record, which is attacker-influenceable if the attacker controls DNS for a scanned subnet. That string flows with no sanitization into live PAN-OS CLI `send` commands and into `string match` glob patterns. This harness replicates that data pipeline (FQDN split -> CSV add-list encode/decode -> CLI command construction -> the "already configured" `string match` check) and generates adversarial hostnames against it -- a fixed corpus of named edge cases plus randomized mutations.

It checks three invariants:

- **no-crlf** -- a PTR value containing `\r`/`\n` could inject a second command into the live SSH session (e.g. a PTR record of `server01<CRLF>delete template ... ts-agent legituser01` would delete an unrelated agent).
- **csv-roundtrip** -- a PTR value containing a comma would corrupt the `"$agent_name,$agent_host"` encoding used to pass discovered hosts to `tsagent-modify-*.exp`, desyncing the object name from its host.
- **glob-injection** -- discover.tcl's "already configured" check (`string match "*...ts-agent $agent_name*" $existing`) treats `agent_name` as a glob pattern, not a literal string. A PTR value of `*` (or containing `*`/`?`/`[`) would make every existing-agent check succeed regardless of the real name, so the tool would silently believe any host is already configured and never add it.

This harness originally found live violations of all three, fixed by a validation gate right after the `mydig` call in `discover.tcl`: any PTR record outside a plain hostname charset (`^[A-Za-z0-9._-]+$`) is rejected (`continue`, logged at `error` level) before `agent_name`/`agent_host` are ever derived from it. That closes all three at once since none of the three payload shapes are valid hostname characters. The harness's `pipeline_valid_ptr` mirrors that same regex so it accurately reflects the fixed pipeline.

Note this only covers `discover.tcl`'s path (DNS mode). `purge.tcl`'s `$object`/`$hostname` come from the firewall's own `not-conn` stats output for agents that were already accepted through this same gate, so they inherit the fix transitively; `purge.tcl` does not independently re-validate them.

### fuzz-purge-parsing.test.tcl

`purge.tcl` parses each `not-conn` line with plain `lindex`, which parses the line as a Tcl *list* -- an unbalanced brace or quote anywhere in the device's output throws a real Tcl error (`unmatched open brace/quote in list`). Without a catch around it, that error would propagate uncaught and abort the whole purge run, leaving stale agents unremoved -- a concrete mechanism for the "purge script has failed" scenario documented in `docs/TROUBLESHOOTING.md`'s platform-capacity section.

This harness generates adversarial single lines (unbalanced braces/quotes, trailing backslashes, oversized input) plus batches that sandwich one adversarial line between two well-formed ones, and checks that `purge.tcl`'s per-line `catch` (added alongside this harness) never lets a parse error escape, and that one malformed line never takes out its neighbors in the same batch.
