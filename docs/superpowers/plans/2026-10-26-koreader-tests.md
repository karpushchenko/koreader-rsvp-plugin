# KOReader-style tests

**Goal:** Preserve FastReader's regression scenarios while using Busted/Luassert
and verify plugin integration against real KOReader modules headlessly.

**Design:** Put Busted specs in `spec/unit` and `spec/integration`; retain the
explicit external-dependency doubles only for isolated unit tests. Integration
specs use upstream `commonrequire`, `PluginLoader`, `ReaderUI`, existing EPUB/PDF
fixtures, actual widgets, `UIManager`, and selective clock/stub overrides.
Use LuaCov for coverage. Do not structurally refactor production code.

**Environment:** Work in the existing plugin checkout so earlier uncommitted
changes stay together. Any native test runtime is staged under a temporary
directory from an existing KOReader emulator build. Do not write to the parent
checkout, the user's reader settings, or source document sidecars.

## Tasks and evidence

- [x] Migrate all 116 existing cases to Busted `describe`/`it` and Luassert;
  remove custom assertion/runner/coverage implementations. Run on Lua 5.1 and
  LuaJIT. Configure independent unit discovery and LuaCov reporting.
- [x] Provide an explicit command for native integration using an existing
  KOReader emulator build. Stage native assets and the actual upstream test
  runner in a fresh temporary directory with a private `KO_HOME`, copied
  document fixtures and discoverable Busted specs.
- [x] Add real integration coverage for loader/registration, EPUB/PDF text,
  menu settings saved to disk, actual widgets and drawing, key/tap routing,
  real scheduled reading, page navigation, cancellation, resume and lifecycle.
  Exercise both reflowable and paged documents. Close documents/free buffers,
  cancel tasks, restore modified globals/stubs and uninstall clock overrides.
- [x] Run native specs through upstream Busted/Meson; also run shuffled and
  repeated cases to detect shared-state leaks. Investigate failures against
  real API contracts; production fixes require reproducing tests first.
- [x] Update Makefile, mutation checker, CI and contributor instructions to
  use the new paths and Busted/LuaCov. CI must exercise the native integration
  layer in addition to the isolated cases.
- [x] Verify syntax, unit tests, native integration, coverage and representative
  mutations. Independently review the complete change and resolve important
  findings before the completion audit.

## Completion audit

The objective is complete only when actual Busted tests execute successfully
with real KOReader widgets/providers/scheduler as well as the isolated cases;
the previous all-double suite alone is insufficient. Record exact commands and
results, CI configuration and any hardware-only checks remaining. Build setup
failures are work to resolve, not successful or skipped integration tests.

## Completion evidence (2026-10-26)

- `make check-all`: 117 Busted unit cases pass on LuaJIT, syntax checks pass,
  LuaCov report succeeds, and the actual upstream Meson frontend suite passes.
- `make check LUA=lua5.1`: 117 cases pass; unit LuaCov reports 788 hits and
  13 misses (98.38%). LuaJIT's report is 733 hits and 13 misses (98.26%).
- `make integration-coverage`: 37 native cases pass on built KOReader
  `b539d24b97e52845841af6d7bb521cbba64e34dd`; native LuaCov reports 605 hits and
  117 misses (83.80%). The fixture set covers EPUB page/scroll views and PDF.
  Meson stdout and JUnit results are preserved under `coverage/koreader`.
- Native Busted fallback with `--shuffle --repeat=3`: all 37 cases pass in
  each of the three runs. Isolated shuffled repeats also pass on LuaJIT.
- `make mutations` and `make mutations LUA=lua5.1`: 18/18 representative
  source mutations cause Busted assertion failures, without framework errors.
- Independent review found a false-positive pixel assertion: OVP ticks could
  count as text. The sampled band now excludes guides and borders. A separate
  native mutation experiment omitting glyph painting causes the EPUB and PDF
  pixel tests to fail; both pass with the real source.
- Native RED-to-GREEN tests justified three additional minimal production
  fixes: forwarding visible RSVP-widget key events, checking actual rolling
  movement at EOF, and honoring the native XPointer string/selection API.
- Test Lua files/configs pass luacheck without warnings; Python syntax and
  workflow YAML parse checks pass. Independent review has no remaining
  Critical/Important findings. Its minor log-retention observation was also
  addressed by preserving Meson diagnostics alongside native coverage.

CI is configured to run both layers, using the tested KOReader revision and
upstream build image. Remote Actions were not dispatched from this session.
Physical e-ink ghosting/refresh quality remains the documented hardware check.
