# FastReader regression test plan

**Goal:** Establish a repeatable behavioral baseline before refactoring.

**Architecture:** Execute the unmodified plugin through its public entry points
in a fresh Lua environment per test. Replace only KOReader dependencies with
explicit test doubles, including a deterministic scheduler and drawing recorder.
Run on Lua 5.1 and LuaJIT without third-party test dependencies.

**Constraints:** Lua 5.1 syntax; no device, network, or parent checkout required;
no unrelated refactoring; preserve existing user files. Tests describe observable
behavior rather than private helper names. Fix a discovered defect only after a
focused test reproduces it. Device rendering remains a manual check.

## Tasks

- [x] Add a small test runner, isolated KOReader environment, assertions, and
  optional executable-line coverage using Lua debug hooks.
- [x] Test settings initialization and save/reload, registration and menu
  callbacks, text extraction and fallback/error paths, page identity and resume.
- [x] Test reading lifecycle with fake time: speed changes, pause/resume, stop,
  navigation, empty pages, end of book, pending callback cancellation and exit.
- [x] Test tap hit detection, keyboard controls, preview layout, Unicode OVP,
  clipping, widget reuse, resize, cleanup and e-ink refresh requests.
- [x] Add a single-command local/CI entry point, contributor instructions and
  explicit limits of simulated integration.
- [x] Run both runtimes, coverage, syntax checks, and deliberate mutations in
  temporary source copies to verify the suite catches representative regressions.
- [x] Review the complete diff and record any remaining manual checks.

## Verification

`make check`, `make check LUA=luajit`, `make mutations`, `make mutations LUA=luajit`.
The runner exits nonzero for failed assertions, invalid filters and empty suites.
Coverage reports only executable lines from the production module; it is an
indicator, not proof of device compatibility. Mutation checks must reject every
listed change without modifying the working source.

## Implementation record

The suite contains 116 cases. Independent review found two fidelity/lifecycle
gaps: real key objects and restart after EOF. Both were reproduced RED before
minimal fixes; shortened-page resume is also covered. Earlier RED cases caught
disabled-indicator reload and native MuPDF word boxes. Production changes are
limited to those four defects; no structural refactoring was performed.

Coverage uses Lua 5.1 as the reference. LuaJIT line events differ from the Lua
5.1 compiler listing, as explained in `docs/testing.md`. Mutation checks remain
optional rather than part of CI because source-snippet edits need maintenance
after behavior-preserving refactoring. Device rendering, native event dispatch
and actual settings-file durability still need manual KOReader verification.

Final checks: 116/116 cases on both runtimes; Lua 5.1 line coverage 862/878
(98.2%); 14/14 representative mutations rejected on each runtime; Lua syntax
checks passed. New Lua tests lint clean independently. The existing module's
87 luacheck warnings also occur in HEAD before these changes.
