# FastReader contributor instructions

@/home/karps/.codex/RTK.md

## Runtime layout and compatibility

- `main.lua`: KOReader entry point, initialization, dispatcher and input handlers.
- `fastreader/reader.lua`: RSVP sessions, timers, page navigation and resume state.
- `fastreader/widget.lua`: word layout, OVP alignment, clipping and widget cleanup.
- `fastreader/text.lua`: crengine/MuPDF extraction and word normalization.
- `fastreader/settings.lua`: persisted settings keys, defaults and save/flush.
- `fastreader/menu.lua`: reader-facing menu and setting dialogs.
- `fastreader/position.lua`: position overlay and its hide timer.
- `_meta.lua`: authoritative plugin identity, description and version.

Target Lua 5.1 and KOReader's widget contracts. Preserve existing plugin methods,
state fields and settings keys during refactors. Keep mutable state on each
plugin/widget instance. Load `fastreader/` modules eagerly at entry: PluginLoader
restores its temporary search path after loading the plugin. Bind event handlers
on the exported plugin table so KOReader's handler sandbox still wraps them.

Use four-space indentation, local variables and PascalCase modules/classes.
Aim for roughly 100 columns while preserving existing gettext message IDs.
Wrap reader-facing text in `_()`; ordinary logging should stay at info or below.

## Required validation

Before changing test setup or native APIs, read [docs/testing.md](docs/testing.md)
for dependencies, isolation rules and the real KOReader test environment.

For every runtime change:

1. Add a regression case for changed behavior; reproduce bugs before fixing them.
2. Run `make check-all`: syntax, lint, Busted unit tests, LuaCov, native integration,
   and native tests loading the actual release ZIP.
3. Run `make test LUA=lua5.1`; default tests use LuaJIT.
4. For changes to timing, navigation or input, also run native shuffled repeats:
   `make integration INTEGRATION_ARGS='--busted -- --busted=--shuffle --busted=--repeat=3'`.
5. When changing module layout, run `make integration-coverage` and verify the
   report includes every production module, not only the small entry point.

Keep isolated specs in `spec/unit`; they must load the real local module graph
with a private cache per harness. Keep real KOReader specs in `spec/integration`.
Use actual providers/widgets/UIManager there, with scoped clock or error-path
substitutions. Close readers, cancel tasks, restore stubs and free buffers.
Report exact commands/results; distinguish checks that passed from checks not run.
Physical e-ink ghosting and refresh quality still require a device check.

## Metadata, versions and releases

Store the version as a literal string in `_meta.lua` (for example `"1.2.3-dev"`
while developing, `"1.2.3"` for a final release). ZenPM scans that assignment as
text; keep the metadata self-contained apart from gettext. This is the only
source version file: a separate `VERSION` file or computed version is unnecessary.
KOReader derives the internal ID from the `fastreader.koplugin` folder.

Whenever a version changes, review `_meta.lua` fullname, description, author,
license and repository URL for accuracy; update README/release notes for user
changes. Keep license information consistent with the existing MIT `LICENSE`.
The metadata and native loader tests must pass after metadata changes.

For a release:

1. Choose the final version in `_meta.lua` and run the required validation above.
2. Run `make package-check`. It builds `dist/fastreader.koplugin.zip` and tests the
   extracted installation with real KOReader. The ZIP must have exactly one
   `fastreader.koplugin/` root containing main, metadata, all `fastreader/` modules,
   README, license and reference media; test/build artifacts stay outside it.
3. When publishing is requested, use a matching `v<version>` Git tag and GitHub
   Release, and attach that ZIP. A Git tag alone is not a GitHub Release.
4. Verify the published release metadata/asset when checking ZenPM updates.
   ZenPM's catalog is generated separately from installed-plugin metadata; this
   repository does not need its own ZenPM repository `manifest.json`.

Before committing, verify author and committer use `theblackkarps@gmail.com`.
Use concise imperative subjects and reference the relevant issue; preserve
unrelated work in the shared checkout.
