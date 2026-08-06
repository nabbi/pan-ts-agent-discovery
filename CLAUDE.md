# CLAUDE.md

## Project

Tcl/Expect automation that discovers Palo Alto Terminal Services Agents
on a network (`src/discover.tcl`) and purges stale ones (`src/purge.tcl`),
driving PAN-OS/Panorama over SSH via `src/exp/*.exp`. Two parallel target
modes exist: Panorama-managed (`tsagent-modify-panorama.exp`) and direct
firewall (`tsagent-modify-firewall.exp`, used when `config(panorama)` is
`disable`) — a change to one almost always needs the mirrored change in
the other. No package manager/build step; runs via cron inside the Alpine
container built from `Dockerfile`.

Full docs index: `docs/README.md` (CONFIGURATION, INSTALL, DEVELOPMENT,
TROUBLESHOOTING, SPLUNK_ALERTS, plus one `.drawio`/`.png` diagram pair
per architectural flow).

## Tests

```shell
tclsh src/tests/common-proc.test.tcl      # pure-Tcl unit tests
expect src/tests/myexpect.test.tcl        # drives real `expect` against mocked spawns
tclsh src/tests/fuzz-injection.test.tcl   # PTR-derived CLI/CSV/glob injection
tclsh src/tests/fuzz-purge-parsing.test.tcl
tclsh src/tests/fuzz-log.test.tcl
```

The three `fuzz-*.test.tcl` harnesses are **not** wired into the
pass/fail suite — run them explicitly, especially after touching
`discover.tcl`'s PTR handling, `purge.tcl`'s line parsing, or the shared
`log` proc. See `docs/DEVELOPMENT.md` for what each covers and the mock
patterns to follow when adding new tests. There is no CI config in this
repo — these are the only correctness signal before a commit.

## Security-sensitive data flow

`mydig`'s reverse-DNS PTR output (`discover.tcl`) is attacker-controllable
by whoever holds DNS for the scanned subnet, and both it and `purge.tcl`'s
parsed firewall CLI output eventually reach live `send` commands over an
active PAN-OS SSH session and `string match` glob checks. Any new code
path that derives a value from PTR/CLI output and feeds it into `send` or
`string match` needs the same hostname-charset validation already applied
at the `mydig` call site (`^[A-Za-z0-9._-]+$`) — don't assume downstream
callers re-validate.

## Diagrams

`docs/*.drawio` sources are rendered to their paired `.png` via the local
`drawio2png` tool (not part of this repo) — regenerate the PNG whenever
you edit a `.drawio` file, one page per file, matching the existing
diagrams' pattern.

## CHANGELOG.md maintenance

`CHANGELOG.md` is maintained by hand, grouped by tagged release
(`## [vX.Y]`), newest first, with an `## [Unreleased]` section at the top
for commits since the latest tag. Each entry links back to its commit
(`https://github.com/nabbi/pan-ts-agent-discovery/commit/<sha>`).

Whenever you make a commit that changes anything under `src/` (bug fix,
security fix, behavior change, new capability), add a bullet for it to
`## [Unreleased]` in the same session, prefixed `**fix:**`,
`**security fix:**`, or `**feature:**` as appropriate. Pure `docs/`-only
or diagram-only commits get a plain `docs:` bullet — keep those terse,
they exist for completeness, not for upgrade decisions.

When a new version is tagged, retitle `## [Unreleased]` to
`## [vX.Y](https://github.com/nabbi/pan-ts-agent-discovery/releases/tag/vX.Y) — YYYY-MM-DD`
and add a one- or two-sentence **Upgrade guidance** line under the
heading (skip / minor / recommended / required, and why) — that line is
the reason this file exists: it lets someone decide whether upgrading is
worth it without reading every commit. Start a fresh empty `## [Unreleased]`
above it.

Verify claims against the actual diff before writing them, not just the
commit message — commit messages can overstate or omit scope (e.g. a
commit whose message emphasizes a docs change can still carry a real
`src/` fix, or vice versa). Double-check which release section a commit
belongs to using `git log vX.Y..vX.Z`, not by eyeballing chronological
order — a commit landing between two tags belongs to the *later* tag's
section, not the earlier one.
