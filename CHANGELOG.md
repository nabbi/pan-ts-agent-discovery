# Changelog

All notable changes to PAN TS Agent Discovery, grouped by tagged release.
Each entry links the commit that introduced it. **Upgrade guidance** at
the top of each section tells you whether the release is worth pulling in
for its own sake, or is safe to skip if you're only tracking major work.

No breaking changes have been introduced in any release covered here —
config file format, CLI usage, and cron/Docker invocation are unchanged
throughout.

## [Unreleased]

## [v1.8](https://github.com/nabbi/pan-ts-agent-discovery/releases/tag/v1.8) — 2026-08-06

**Upgrade guidance: recommended, security-relevant.** Closes three
defense-in-depth CRLF/charset injection gaps found via an expanded fuzz
suite and a new end-to-end test harness for the `.exp` scripts that
previously had no automated coverage at all — take this if you run
`purge.tcl` or either `tsagent-modify-*.exp` path regularly. Also adds
`config(loglevel)` verbosity control and structured `run=... status=start`/
`status=ok` operational-status and add/delete-metrics logging to syslog —
worth taking too if you want per-run health and change-volume visibility
in Splunk, but that half is a feature addition, not a fix.

- **feature:** added `config(loglevel)` (0=quiet, 1=info default, 2=debug, 3=trace) to control `discover.tcl`/`purge.tcl` stdout/file-log verbosity from `config.tcl`, replacing the hardcoded `set info 1 / set debug 0 / set trace 0` at the top of each script. Optional — defaults to `1` (prior behavior) when omitted. Does not affect syslog, which was never gated by these flags. ([c3feeaf](https://github.com/nabbi/pan-ts-agent-discovery/commit/c3feeaf))
- **feature:** `discover.tcl`/`purge.tcl` now log a `run=<job> status=start` line at the top of each run and a `run=<job> status=ok elapsed_sec=... ...` summary (scanned/discovered/added or notconn/deleted counts) at the bottom, both `info`-level `key=value` lines alongside the existing per-host add/delete logging. Gives syslog/Splunk overall operational status per run plus a countable add/delete metrics stream, and lets a missing `status=ok` after a `status=start` flag a crashed/hung/killed run. Documented in `SPLUNK_ALERTS.md` with a missing-completion alert recipe and an add/delete volume trend search. ([0fde8ff](https://github.com/nabbi/pan-ts-agent-discovery/commit/0fde8ff))
- **security fix:** a `not-conn` line with a brace-/quote-grouped field could carry a literal `\r` through `purge.tcl`'s `lindex`-based parsing into `$object`/`$hostname`, reaching a live `send "...ts-agent $object\r"`. Gated with the same `^[A-Za-z0-9._-]+$` hostname charset check `discover.tcl` already applies to PTR values. ([3cb1bcf](https://github.com/nabbi/pan-ts-agent-discovery/commit/3cb1bcf))
- **security fix:** `tsagent-modify-firewall.exp`/`tsagent-modify-panorama.exp` walk their `$input` argument with `foreach i $input`, which parses it as a Tcl list — an embedded `\r` in a single `"object,host"` add entry fanned out into extra list elements, one of which became a live `send` silently overwriting an unrelated, already-configured agent's host with an empty value. Neither script independently validated `object`/`host` before this (found via the new `exp-e2e.test.tcl` harness, which sources the real scripts rather than a mirrored copy). Both now gate on the same charset check, mirrored across the two files. ([3cb1bcf](https://github.com/nabbi/pan-ts-agent-discovery/commit/3cb1bcf))
- **fix:** `myfping` iterated `fping`'s raw output with `foreach ip $results`, parsing it as an implicit Tcl list — a stray unbalanced brace/quote token (a malfunctioning/corrupted `fping`) would throw uncaught and crash the entire `discover.tcl` run, with no `catch` protecting it. Fixed by splitting on `\n` first, which never throws. ([3cb1bcf](https://github.com/nabbi/pan-ts-agent-discovery/commit/3cb1bcf))
- **fix:** `myfping`'s per-octet IPv4 check used `string is digit` and `expr`'s `>=`/`<=`, both Unicode-aware — a non-ASCII decimal digit (e.g. Arabic-Indic `٥`) could pass as a valid octet, letting a non-IPv4 string slip through as "valid". Now requires a strict ASCII `^[0-9]{1,3}$` match first. ([3cb1bcf](https://github.com/nabbi/pan-ts-agent-discovery/commit/3cb1bcf))
- test: added `exp-e2e.test.tcl` (real end-to-end coverage for `tsagent-configured.exp`/`tsagent-not-connected.exp`/`tsagent-modify-firewall.exp`/`tsagent-modify-panorama.exp`, none of which had any automated test before) and `fuzz-myfping.test.tcl`; extended `fuzz-purge-parsing.test.tcl` with a no-crlf/gate-bypass invariant ([3cb1bcf](https://github.com/nabbi/pan-ts-agent-discovery/commit/3cb1bcf))
- **fix:** `myfping` accepted malformed addresses (empty string, or fewer than 4 octets, e.g. `"10.0.1"`) — its IPv4 flag defaulted to true and was only ever flipped false by an out-of-range octet, never by a missing one. Now requires exactly 4 dot-separated octets before accepting. ([16080ec](https://github.com/nabbi/pan-ts-agent-discovery/commit/16080ec))
- known limitation (documented, not fixed): `discover.tcl`'s `agent_host` reconstruction assumes exactly 3 dot-separated labels (`host.domain.tld`) and silently truncates/mangles anything else (nested subdomains, single-label domains, bare hostnames). Left as-is pending review — believed cosmetic since it's a label-only value not resolved by PAN-OS and unrelated to the already-configured match — but now locked in with characterization tests and a code comment. ([16080ec](https://github.com/nabbi/pan-ts-agent-discovery/commit/16080ec))
- docs: reconciled architecture/function-flow diagrams with current code, corrected a stale README caption ([aa49ec2](https://github.com/nabbi/pan-ts-agent-discovery/commit/aa49ec2), [a364135](https://github.com/nabbi/pan-ts-agent-discovery/commit/a364135), [52c894c](https://github.com/nabbi/pan-ts-agent-discovery/commit/52c894c))
- docs: split architecture diagram into per-flow diagrams (SSH session lifecycle, myexpect error tree, TS Agent lifecycle, log/alert pipeline), embedded PNGs in docs, corrected a stale TROUBLESHOOTING.md claim about platform-capacity error handling ([f77237f](https://github.com/nabbi/pan-ts-agent-discovery/commit/f77237f))
- docs: documented how to upgrade or pin to a specific tagged version ([036fb5e](https://github.com/nabbi/pan-ts-agent-discovery/commit/036fb5e))

## [v1.7](https://github.com/nabbi/pan-ts-agent-discovery/releases/tag/v1.7) — 2026-08-04

**Upgrade guidance: recommended, especially if you monitor syslog/Splunk
for failures.** Fixes a real gap where genuine SSH/timeout/capacity
failures from `myexec` were logged at the same `user.info` priority as
successes, and closes a log-forging hole. Also two purge.tcl robustness
fixes worth having if you run `purge.tcl` regularly.

- **fix:** `myexec` always logged at `user.info` regardless of outcome, so real failures (SSH failure, timeout, unknown command, HA sync, platform capacity) across all four `.exp` sub-scripts were indistinguishable from success by syslog priority. Now uses `user.error` on failure to match the other probes. ([f6707410](https://github.com/nabbi/pan-ts-agent-discovery/commit/f6707410))
- **fix:** the shared `log` proc's `exec logger` call was unguarded — a missing `logger` binary or unreachable syslog would crash the entire `discover.tcl`/`purge.tcl` run mid-batch. Now caught, falling back to stdout. ([f6707410](https://github.com/nabbi/pan-ts-agent-discovery/commit/f6707410))
- **security fix:** `log`'s newline sanitization only matched `\n`, letting a bare `\r` survive into the logger argument and visually overwrite/hide log lines (CWE-117 log forging) via attacker-influenceable content such as a rejected PTR value. Now collapses `\r\n`, lone `\r`, and lone `\n` uniformly. ([f6707410](https://github.com/nabbi/pan-ts-agent-discovery/commit/f6707410))
- **fix:** `purge.tcl` aborted the entire run when PAN-OS returned "Object doesn't exist" for a delete target (happens when firewall/Panorama config drifts out of sync). Now warns and continues so the rest of the batch still completes. ([c047405](https://github.com/nabbi/pan-ts-agent-discovery/commit/c047405))
- **fix:** if every object in a delete batch was already absent, `tsagent-modify-panorama.exp`/`tsagent-modify-firewall.exp` still issued a `commit`/`commit-all` with zero actual changes. Now skipped when nothing in the batch changed. ([7ca86ac](https://github.com/nabbi/pan-ts-agent-discovery/commit/7ca86ac))
- docs: documented the `commit`/`commit-all` coupling as an intentional tradeoff (preserves implicit retry, avoids an unconditional 15s wait+push on no-op cycles) ([9d3fc2c](https://github.com/nabbi/pan-ts-agent-discovery/commit/9d3fc2c))

## [v1.6](https://github.com/nabbi/pan-ts-agent-discovery/releases/tag/v1.6) — 2026-08-03

**Upgrade guidance: recommended, high-value security fix.** Closes an
actual injection vulnerability where DNS-controlled data reached live
PAN-OS CLI commands unsanitized — including a variant that could
silently make the tool stop adding any new hosts. Take this release if
you're on anything older.

- **security fix:** `mydig`'s reverse-DNS PTR output flowed unsanitized into live `send` commands and a `string match` glob pattern. A PTR value crafted by whoever controls DNS for a scanned subnet could inject CRLF into the live SSH session, corrupt the object/hostname CSV encoding with commas, or spoof the "already configured" check with glob metacharacters (a PTR of `*` made every existing-agent check succeed, silently preventing any host from ever being added). Fixed by validating PTR records against a plain hostname charset (`^[A-Za-z0-9._-]+$`) before use. Found via a new fuzz harness (`fuzz-injection.test.tcl`, not wired into pass/fail until this fix landed). ([b8332cd](https://github.com/nabbi/pan-ts-agent-discovery/commit/b8332cd), [c083f05](https://github.com/nabbi/pan-ts-agent-discovery/commit/c083f05))
- **fix:** `purge.tcl` parsed each not-conn line with plain `lindex`, so an unbalanced brace/quote in device output threw an uncaught Tcl error and aborted the whole purge run, leaving stale agents unremoved. Now catches and skips malformed lines instead of crashing, confirmed via a dedicated fuzz harness. ([693fda2](https://github.com/nabbi/pan-ts-agent-discovery/commit/693fda2))
- test: added coverage for the actual delete-vs-keep decision (`purge_decide`) which previously had the not-conn match and the reachability recheck tested only in isolation, never together ([693fda2](https://github.com/nabbi/pan-ts-agent-discovery/commit/693fda2))
- docs: documented the new PTR validation and not-conn parse-error log messages in CONFIGURATION/TROUBLESHOOTING ([73f8e85](https://github.com/nabbi/pan-ts-agent-discovery/commit/73f8e85))
- docs: added a Splunk alerting guide covering the 5 error conditions that reach syslog via the shared `log` proc, and noting which failure classes (SSH/timeout/HA-sync/capacity) only reach file logs, not syslog ([f5f1e95](https://github.com/nabbi/pan-ts-agent-discovery/commit/f5f1e95))

## [v1.5](https://github.com/nabbi/pan-ts-agent-discovery/releases/tag/v1.5) — 2026-02-13

**Upgrade guidance: required if on anything older.** Fixes three
crash/correctness bugs in the core discovery path, one of which crashes
`discover.tcl` outright in DNS mode.

- **fix:** `discover.tcl` referenced an undefined `$host` variable, crashing DNS-mode discovery outright — corrected to `$agent_name` ([cfaad9d](https://github.com/nabbi/pan-ts-agent-discovery/commit/cfaad9d))
- **fix:** `common-proc.tcl`'s `string first` comparison used `> 0`, which misses a match at position 0 — corrected to `>= 0` ([cfaad9d](https://github.com/nabbi/pan-ts-agent-discovery/commit/cfaad9d))
- **fix:** `common-proc.tcl`'s `mydig` error path referenced undefined `$args` — corrected to the actual variable `$ip` ([cfaad9d](https://github.com/nabbi/pan-ts-agent-discovery/commit/cfaad9d))
- **feature:** added standalone-firewall support — when `config(panorama)` is set to `disable`, `discover.tcl`/`purge.tcl` route SSH operations directly to `config(firewall)` via new firewall-specific expect scripts, decoupling the Panorama requirement. Existing Panorama workflow is untouched. ([92bc889](https://github.com/nabbi/pan-ts-agent-discovery/commit/92bc889))
- docs/test: added a unit test suite (`common-proc.test.tcl`) and DEVELOPMENT.md — the codebase's first automated tests ([32446cc](https://github.com/nabbi/pan-ts-agent-discovery/commit/32446cc))

## [v1.4](https://github.com/nabbi/pan-ts-agent-discovery/releases/tag/v1.4) — 2024-07-29

**Upgrade guidance: minor, low urgency.** One small logging fix; the
rest of the run-up since v1.3 is metrics/logging polish and typo fixes.

- **fix:** limited logger message length in `common-proc.tcl` (prevents oversized syslog messages) ([1703132](https://github.com/nabbi/pan-ts-agent-discovery/commit/1703132))
- fix: improved purge non-conn logging clarity ([80044a6](https://github.com/nabbi/pan-ts-agent-discovery/commit/80044a6))
- minor: spelling and blank-line cleanup in `.exp` scripts ([98f4ceb](https://github.com/nabbi/pan-ts-agent-discovery/commit/98f4ceb), [7ac6722](https://github.com/nabbi/pan-ts-agent-discovery/commit/7ac6722))

## [v1.3](https://github.com/nabbi/pan-ts-agent-discovery/releases/tag/v1.3) — 2024-07-15

**Upgrade guidance: recommended if running v1.2 or older**, mainly for
the syntax-error fix and the commit/commit-all timing fix, which affect
run correctness rather than cosmetics.

- **fix:** missing bracket in `discover.tcl` (syntax-level bug) ([ebe8785](https://github.com/nabbi/pan-ts-agent-discovery/commit/ebe8785))
- **fix:** IP object name handling and match pattern corrections in `discover.tcl` ([b0e7f5c](https://github.com/nabbi/pan-ts-agent-discovery/commit/b0e7f5c), [287bfc6](https://github.com/nabbi/pan-ts-agent-discovery/commit/287bfc6))
- fix: moved alive-host dedup outside the discovery for-loop (was likely re-checking/duplicating work per iteration) ([f522e42](https://github.com/nabbi/pan-ts-agent-discovery/commit/f522e42))
- fix: added a delay between `commit` and `commit-all` in `tsagent-modify.exp` (race/ordering fix) ([e049042](https://github.com/nabbi/pan-ts-agent-discovery/commit/e049042))
- minor: metrics/logging additions across `discover.tcl` and `purge.tcl` ([dc298e0](https://github.com/nabbi/pan-ts-agent-discovery/commit/dc298e0), [4c2246d](https://github.com/nabbi/pan-ts-agent-discovery/commit/4c2246d))

## [v1.2](https://github.com/nabbi/pan-ts-agent-discovery/releases/tag/v1.2) — 2023-12-20

**Upgrade guidance: recommended**, fixes a certificate-validation bug in
the TS Agent detection path plus vsys/template-search correctness fixes —
all directly affect discovery correctness.

- **fix:** corrected the certificate common-name check in `common-proc.tcl` used to confirm TS Agent presence ([8aebc1f](https://github.com/nabbi/pan-ts-agent-discovery/commit/8aebc1f))
- fix: improved vsys handling in `discover.tcl` ([7e1ecbb](https://github.com/nabbi/pan-ts-agent-discovery/commit/7e1ecbb))
- fix: improved Panorama template search in `discover.tcl` ([2038a59](https://github.com/nabbi/pan-ts-agent-discovery/commit/2038a59))
- minor: removed unused variables, indentation/spacing cleanup ([f7d6a19](https://github.com/nabbi/pan-ts-agent-discovery/commit/f7d6a19), [d393e4d](https://github.com/nabbi/pan-ts-agent-discovery/commit/d393e4d))
- infra: moved code into `src/`, added Docker support (non-root, config-missing check) ([622a563](https://github.com/nabbi/pan-ts-agent-discovery/commit/622a563), [1b1d642](https://github.com/nabbi/pan-ts-agent-discovery/commit/1b1d642), [a158e0e](https://github.com/nabbi/pan-ts-agent-discovery/commit/a158e0e))

## [v1.1](https://github.com/nabbi/pan-ts-agent-discovery/releases/tag/v1.1) — 2021-09-28

**Upgrade guidance: baseline.** First tagged release: `discover.tcl`,
`purge.tcl`, expect scripts, and common procs, plus a documentation/naming
adjustment.

- initial public release: `discover.tcl`, `purge.tcl`, expect scripts, common procs ([e25eed1](https://github.com/nabbi/pan-ts-agent-discovery/commit/e25eed1))
- docs: adjusted documentation to reflect repo name ([1350cb1](https://github.com/nabbi/pan-ts-agent-discovery/commit/1350cb1))
