# Split FastReader modules and complete package metadata

**Goal:** Keep FastReader's current reading behavior while separating its
responsibilities, exposing accurate package metadata, and documenting release
checks for future contributors.

**Design:** `main.lua` retains plugin registration, initialization and input
entry points. Namespaced `fastreader/` modules own RSVP control, word rendering,
text extraction, settings, menu construction and the position indicator.
The plugin's existing methods, state fields, settings keys and callbacks remain
the compatibility surface. Bind event methods on the exported plugin table so
KOReader's PluginLoader still applies its handler sandbox.

**Loading:** Load local modules eagerly while PluginLoader has the plugin path
on `package.path`. Use a `fastreader/` prefix to avoid collisions with core or
other plugins. Unit tests load the real module graph into a private environment
per case while retaining explicit external API doubles.

**Metadata:** Verify fields against actual ZenPM code before choosing them.
Use `_meta.lua` as the version authority, with literal fields usable by static
scanners. Keep the MIT license and repository identity accurate. Do not publish
a release or edit an external catalog as part of this task.

## Implementation and checks

- [x] Record the passing baseline (117 isolated and 39 native cases, green CI).
- [x] Extract the existing function bodies into `fastreader/` modules; preserve
  names, state ownership, timer behavior, event handling and reader-facing text.
- [x] Keep isolated loader caches private per harness; add a regression showing
  two loaded plugin environments cannot share their scheduler or widget state.
- [x] Update syntax checks and LuaCov to include every production Lua module.
  Test packaging and installed loading so the split cannot omit runtime files.
- [x] Add metadata assertions before filling the verified viewer fields.
  Validate native PluginLoader metadata and the installed module graph.
- [x] Provide a distributable archive with a single `fastreader.koplugin/` root,
  production modules, metadata, README and license, excluding test artifacts.
- [x] Update README/testing instructions and AGENTS.md for module ownership,
  mandatory tests, metadata/version consistency and release archive checks.
  Preserve the existing CLAUDE.md user file.
- [x] Run Busted on Lua 5.1/LuaJIT, native Meson and shuffled repeats, both
  LuaCov layers, lint and the packaged-plugin load checks. Independently review
  the refactor and verify no functionality has disappeared.

## Completion criteria

Every production module is included in coverage and the release archive;
existing tests still exercise real plugin behavior; native tests load all
modules through KOReader after its temporary plugin search path is restored.
Metadata is readable by the confirmed scanner contracts and version procedures
are documented with executable checks. Remote catalog visibility is distinguished
from the metadata an installed plugin supplies.

## Verification results (2026-10-26)

- `make check-all LUACHECK=/tmp/fastreader-luarocks/bin/luacheck`: clean syntax
  and lint; 118 unit cases; 39 native cases; 39 cases against the installed ZIP.
- `make test LUA=lua5.1`: 118 passed; default LuaJIT also passed all 118.
- `make integration INTEGRATION_ARGS='--busted -- --busted=--shuffle --busted=--repeat=3'`:
  all 39 cases passed in each of three shuffled runs.
- Unit LuaCov: 98.39%; native LuaCov: 85.53%. Both include the entry point,
  metadata and every extracted runtime module.
- A temporary ZIP with `fastreader/reader.lua` removed was rejected by native
  tests. The complete archive passed; no broken archive was retained.
- Independent read-only review found no Critical or Important issues. All 28
  original plugin methods remain exposed; instance state and KOReader handler
  sandbox bindings are preserved. Physical e-ink behavior was not checked.
