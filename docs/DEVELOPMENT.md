# Development

## Testing

Tests use Tcl's built-in `tcltest` package -- no additional dependencies required beyond `tcl`.

### Run tests

```shell
tclsh src/tests/common-proc.test.tcl
```

### What is tested

The test suite validates the core logic with mocked external commands (no network or SSH required).

**common-proc.tcl procedures**
- `log` -- newline replacement, message truncation at 200 chars, syslog level forwarding
- `myfping` -- IPv4 address validation/filtering, fping exit code handling (0, 1, 2+)
- `mytsagent` -- TLS certificate string matching, error code handling (1, 104, etc)

**discover.tcl logic**
- Panorama config pattern matching (DNS and IP modes)
- Multi-agent and wrong-template rejection
- FQDN parsing (hostname, domain, TLD extraction)
- IP deduplication
- Add-list `object,hostname` format construction and parsing

**purge.tcl logic**
- `not-conn:` line pattern matching
- Object and hostname extraction from firewall output
- Multi-line output filtering with mixed connected/not-connected agents

### Test approach

External commands (`fping`, `openssl`, `dig`, `logger`, `ssh`) are mocked at the `exec` level. The `exit` command is also mocked so fatal error paths can be tested without terminating the interpreter.

Tests focus on the pure logic and string parsing that is most likely to break during refactoring -- the parts you can validate without live infrastructure.

### Adding tests

Place new test files in `src/tests/` using the `*.test.tcl` naming convention and the same mock pattern established in `common-proc.test.tcl`.
