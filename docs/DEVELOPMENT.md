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
- Branch coverage for every named pattern (`Unknown command`, `Object doesn't exist` -> exit 65, HA sync warning, platform-capacity commit failure, generic error/invalid/fail catch-alls, timeout)
- Priority: the platform-capacity branch is confirmed to win over the generic error/fail catch-alls when a message matches both
- A clean prompt match with no error keywords returns normally

This suite uses `expect` (not `tclsh`) since `myexpect.exp` drives the real `expect` command against a spawned process rather than pure Tcl logic. It spawns `/bin/echo`/`sleep` in place of an SSH session and asserts on the resulting exit code.

## Fuzzing

```shell
tclsh src/tests/fuzz-injection.test.tcl [iterations] [seed]
```

`mydig`'s output is a reverse DNS PTR record, which is attacker-influenceable if the attacker controls DNS for a scanned subnet. That string flows with no sanitization into live PAN-OS CLI `send` commands and into `string match` glob patterns. `fuzz-injection.test.tcl` replicates that data pipeline (FQDN split -> CSV add-list encode/decode -> CLI command construction -> the "already configured" `string match` check) and generates adversarial hostnames against it -- a fixed corpus of named edge cases plus randomized mutations (seeded, so a failing run is reproducible with the same seed).

It checks three invariants and currently finds violations of all three, i.e. these are real, unfixed issues in the current code, not hypothetical:

- **no-crlf** -- a PTR value containing `\r`/`\n` is not stripped, so it can inject a second command into the live SSH session (e.g. a PTR record of `server01<CRLF>delete template ... ts-agent legituser01` would delete an unrelated agent).
- **csv-roundtrip** -- a PTR value containing a comma corrupts the `"$agent_name,$agent_host"` encoding used to pass discovered hosts to `tsagent-modify-*.exp`, desyncing the object name from its host.
- **glob-injection** -- discover.tcl's "already configured" check (`string match "*...ts-agent $agent_name*" $existing`) treats `agent_name` as a glob pattern, not a literal string. A PTR value of `*` (or containing `*`/`?`/`[`) makes every existing-agent check succeed regardless of the real name, so the tool silently believes any host is already configured and never adds it.

This harness intentionally exits 1 while these hold -- it is not wired into the pass/fail suite run by `common-proc.test.tcl`. Treat a clean run as confirmation a fix actually closed the gap, not as a gate to keep permanently green without addressing the findings.

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

### Test approach

External commands (`fping`, `openssl`, `dig`, `logger`, `ssh`) are mocked at the `exec` level. The `exit` command is also mocked so fatal error paths can be tested without terminating the interpreter. In `common-proc.test.tcl` the mock `exit` raises a catchable error; in `myexpect.test.tcl` it instead just records the code, since throwing an error out of an `expect` action block corrupts Expect's internal state. Note also that `spawn` sets `spawn_id` in the calling proc's local scope -- if you spawn from inside a test helper proc, `global spawn_id` is required before the spawn or `myexpect`'s own `expect` call won't find it and will hang until timeout.

Tests focus on the pure logic and string parsing that is most likely to break during refactoring -- the parts you can validate without live infrastructure.

### Adding tests

Place new test files in `src/tests/` using the `*.test.tcl` naming convention and the same mock pattern established in `common-proc.test.tcl`.
