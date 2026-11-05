# Testing FastReader

FastReader follows KOReader's Busted/Luassert conventions. Isolated tests live in
`spec/unit/*_spec.lua`; native integration tests live in `spec/integration` and
are staged as frontend specs for KOReader's own Meson/Busted runner.

## Install test dependencies

Use Lua 5.1 or LuaJIT, Make and LuaRocks configured for Lua 5.1:

```sh
luarocks --lua-version=5.1 install busted 2.3.0
luarocks --lua-version=5.1 install luacov 0.17.0
luarocks --lua-version=5.1 install luacheck 1.2.0
eval "$(luarocks --lua-version=5.1 path)"
```

LuaJIT uses Lua 5.1 modules. The explicit LuaRocks environment is useful with
non-default rock trees or when the system's default Lua is a newer version.
Syntax checks also need `luac5.1`. `tests/busted.lua` is the standard two-line
Busted CLI entry point, not a separate assertion or test-runner implementation;
it lets Make select an interpreter without losing quoted filter arguments.

## Commands from the plugin directory

```sh
make test                           # LuaJIT, Busted unit specs
make test LUA=lua5.1
make test TEST_ARGS='--filter=resume --shuffle --repeat=3'
make syntax                         # Lua 5.1 parse checks
make lint                           # production and test Lua checks
make coverage                       # LuaCov unit report
make integration                    # real headless KOReader integration
make integration-coverage           # native specs with LuaCov
make package                        # dist/fastreader.koplugin.zip
make package-check                  # native tests on an extracted ZIP installation
make check                          # syntax, lint, unit tests and unit coverage
make check-all                      # check, native integration and installed ZIP
```

Failed assertions, setup errors and missing native dependencies return a nonzero
exit status. The native tests are not silently skipped if KOReader is missing.
`LUA`, `LUAC` and `PYTHON` select binaries. `TEST_ARGS` goes to Busted; its filters
are Lua patterns. The unit specs are discoverable with `busted --list` as well.

## Native KOReader setup and discovery

Build a KOReader emulator following its [building instructions][building]:

```sh
# From a KOReader checkout:
./kodev fetch-thirdparty
./kodev build
```

For this plugin's tests, return to the plugin directory and run:

```sh
make integration KOREADER_DIR=/path/to/koreader
make integration-coverage KOREADER_DIR=/path/to/koreader
```

The default `KOREADER_DIR` is `../..`, matching installation under
`koreader/plugins/fastreader.koplugin`. `tests/run_koreader.py` selects a built
`koreader-emulator-*/koreader` runtime. To select one explicitly:

```sh
make integration INTEGRATION_ARGS='--runtime /path/to/built/koreader'
```

The wrapper stages read-only runtime assets and the actual upstream
`spec/runtests`, Busted configuration, helper and Meson build file in a temporary
directory. It registers our native `*_spec.lua` as `spec/front/unit` tests next
to upstream `commonrequire` and `mock_time`. Meson is used when available; the
upstream Busted fallback can be requested explicitly. This performs real test
discovery rather than calling the native cases through the isolated harness.

```sh
make integration INTEGRATION_ARGS='--busted'
make integration INTEGRATION_ARGS='--busted -- --filter=resize'
make integration INTEGRATION_ARGS='--busted -- --busted=--shuffle --busted=--repeat=3'
```

`KO_HOME` is private. The specs copy each source EPUB/PDF into that directory
before opening it and remove the copy and sidecars afterwards. They close the
real reader, free allocated buffers, cancel UI tasks, restore settings/stubs
and uninstall MockTime. No personal KOReader settings or source fixtures are
modified. Temporary runtime files are removed even after assertion failures.
Native coverage is saved to `coverage/koreader/luacov.report.out`. Meson logs,
including its JUnit report, are preserved in the same directory after both
successful and failing runs; the direct Busted fallback writes to stdout.

To contribute the native spec to KOReader itself, place it in that project's
`spec/unit/fastreader_koreader_spec.lua`, with FastReader installed in its
plugins directory. It then uses the usual command from the KOReader root:

```sh
./kodev test front fastreader_koreader
```

There is no automatic upstream scan of an external plugin's `spec` directory;
the temporary staging above supplies that registration for local and CI runs.

## Test scope

| Specs | Behavior |
| --- | --- |
| `spec/unit/fastreader_settings_spec.lua` | Defaults, save/reload, registration, menu toggles/presets/custom controls, metadata |
| `spec/unit/fastreader_extraction_spec.lua` | Native-shaped MuPDF boxes, string providers, screen selection, XPointer string fallback, punctuation, Unicode and extraction failures |
| `spec/unit/fastreader_reading_spec.lua` | WPM timing, page transitions, empty pages, cancellation, position identity/resume, EOF restart, indicator lifetime and lifecycle |
| `spec/unit/fastreader_input_spec.lua` | Key objects, keyboard controls, gesture propagation, coordinate transforms, footer and margins |
| `spec/unit/fastreader_widget_spec.lua` | Preview limits, clipping, Unicode fixation, erasing/borders, regional refresh requests, widget reuse/free, resize and old import path |
| `spec/integration/fastreader_koreader_spec.lua` | Real PluginLoader/ReaderUI, crengine EPUB and MuPDF PDF, TextWidget/FreeType/BlitBuffer painting, key/tap routing, real scheduled tasks and indicator expiry, cross-page reading, EOF, cancellation, resume and settings saved/reloaded on disk |

The isolated tests retain explicit boundary doubles in `spec/support/koreader.lua`
for speed and controlled failures. They load the real plugin in a fresh Lua
environment, including a private cache of the `fastreader/` modules per harness;
unknown dependencies fail. They do not validate the replacement
APIs themselves. The native layer uses actual modules and only substitutes
clock sources via upstream MockTime, plus a scoped primary-selection failure
for the XPointer fallback case. It leaves the real UIManager scheduler intact.

Add cases with `describe`, `it`, Luassert assertions and, where appropriate,
`before_each`/`after_each`. For native cases require `commonrequire`, load the
plugin through PluginLoader/ReaderUI and use `finally` to restore selective
stubs or free buffers after failed assertions. Reproduce bugs before fixing
production code. Run both layers after refactors.

## Coverage and CI

Coverage is standard LuaCov, configured by `.luacov` to include `main.lua`,
`_meta.lua` and every runtime module under `fastreader/`. `make coverage` reports on
the isolated suite; `make integration-coverage` merges the native process stats
using KOReader's own `merge_luacov_stats.lua` and generates a separate report.
These percentages describe different test layers. They replace the earlier
custom compiler-line/debug-hook metric and are not directly comparable with it.

GitHub Actions runs the unit specs on Lua 5.1 and LuaJIT. A separate job builds
the pinned KOReader revision used for local verification, using KOReader's own
build-container image, then runs native specs with coverage and repeated,
shuffled execution. It also runs the native specs against the actual ZIP built
by `make package`, catching omitted modules and broken installed search paths.
Native coverage and Meson logs are uploaded as an artifact.

Run all Lua lint checks with `make lint`. Production lint preserves the existing
gettext message IDs even when a literal exceeds 100 columns; test code enforces
the 100-column limit. To lint the specs independently:

```sh
luacheck --no-config --std luajit+busted --no-unused-args --no-self \
  --max-line-length 100 spec tests/busted.lua .busted .luacov
```

## Hardware checks

Native tests run real rendering into a dummy framebuffer without an SDL window.
They can verify pixels, clipping, font metrics and refresh requests, but cannot
measure physical e-ink ghosting or refresh quality. Before release, manually
check launch/stop, preview and speed changes, screen rotation, Unicode words,
page transitions and restart persistence on an actual device; inspect its log
for unexpected warnings or excessive output.

[building]: https://github.com/koreader/koreader/blob/master/doc/Building.md
