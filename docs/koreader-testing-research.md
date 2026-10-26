# KOReader testing conventions: comparison with FastReader

This is the research snapshot before migration. FastReader now uses Busted and
LuaCov and includes native KOReader integration specs. Current commands and
scope are documented in [testing.md](testing.md).

Investigated on 2026-10-26 using the local KOReader checkout at
`b539d24b97e52845841af6d7bb521cbba64e34dd` (2026-09-29) and its `base`
submodule at `fe41d7698ad8a6a7caf794d9b601229009a34053`. The referenced
local files have no working-tree modifications. This note describes KOReader's
own tests; it does not establish a mandatory policy for external plugins.

## Upstream workflow

KOReader documents **Busted** as its unit-test framework, supplied by the build
system, with parallel execution through **Meson**. Commands run from the KOReader
root include `./kodev test`, `./kodev test front`, `./kodev test base util`, and
`./kodev test -l`. Building instructions also show selecting a frontend test with
`./kodev test front readerbookmark`, and static analysis with `make static-check`.
Sources: `doc/Unit_tests.md:3`, `doc/Building.md:250`.
[Unit-test documentation](https://github.com/koreader/koreader/blob/b539d24b97e52845841af6d7bb521cbba64e34dd/doc/Unit_tests.md),
[building instructions](https://github.com/koreader/koreader/blob/b539d24b97e52845841af6d7bb521cbba64e34dd/doc/Building.md#L250).

Frontend tests live in KOReader's `spec/unit/*_spec.lua`; examples use
`describe`, `it`, `setup`/`teardown`, `before_each`/`after_each`, and assertions
from Busted/Luassert. The emulator build links the frontend suite as
`spec/front/unit`, and fixtures from `test/` as `spec/front/unit/data`.
Meson discovers `*_spec.lua` and `*_bench.lua` below the built installation's
`spec/`, invokes its LuaJIT/Busted runner, and assigns each test process a
separate `KO_HOME`. Sources: `Makefile:137`,
`base/test-runner/meson.build:13`, `base/test-runner/busted_config.lua:6`.
[frontend staging](https://github.com/koreader/koreader/blob/b539d24b97e52845841af6d7bb521cbba64e34dd/Makefile#L137),
[test discovery and invocation](https://github.com/koreader/koreader-base/blob/fe41d7698ad8a6a7caf794d9b601229009a34053/test-runner/meson.build),
[Busted suite roots](https://github.com/koreader/koreader-base/blob/fe41d7698ad8a6a7caf794d9b601229009a34053/test-runner/busted_config.lua).

## Tests can use real KOReader headlessly

`spec/unit/commonrequire.lua` initializes real LuaSettings, Device, Screen and
CanvasContext. It enables dummy framebuffer/input so tests do not open an SDL
window. Therefore automated integration with real widgets/providers does not
inherently require an e-reader or a visible emulator window; it does require
KOReader's built runtime and native dependencies.
Source: `spec/unit/commonrequire.lua:6`.
[shared setup](https://github.com/koreader/koreader/blob/b539d24b97e52845841af6d7bb521cbba64e34dd/spec/unit/commonrequire.lua#L6).

There are at least two concrete plugin-loading patterns:

- `exporter_plugin_main_spec.lua` calls `require("commonrequire")`,
  `disable_plugins()`, then `load_plugin("exporter.koplugin")`. It constructs
  real `ReaderUI` with `DocumentRegistry:openDocument` on the EPUB fixture and
  closes the reader in teardown. Export tests inspect actual output files;
  another replaces only `shareText` and restores it after the assertion.
  [Exporter tests](https://github.com/koreader/koreader/blob/b539d24b97e52845841af6d7bb521cbba64e34dd/spec/unit/exporter_plugin_main_spec.lua).
- `batterystat_spec.lua` calls common setup, installs `MockTime`, and loads
  `dofile("plugins/batterystat.koplugin/main.lua")` in `before_each`. It
  uninstalls the clock override in teardown.
  [BatteryState tests](https://github.com/koreader/koreader/blob/b539d24b97e52845841af6d7bb521cbba64e34dd/spec/unit/batterystat_spec.lua#L8).

`load_plugin` is not a module-returning convenience function: it discovers
the named plugin and calls `PluginLoader:_load{...}` without returning its class
or instance. The exporter test then gets the instantiated plugin through
`ReaderUI`. Sources: `spec/unit/commonrequire.lua:57`,
`spec/unit/exporter_plugin_main_spec.lua:8`.
[loader helper](https://github.com/koreader/koreader/blob/b539d24b97e52845841af6d7bb521cbba64e34dd/spec/unit/commonrequire.lua#L57).

## Mocking, clocks and coverage

Upstream also uses test doubles. `pluginloader_spec.lua` replaces the filesystem
module with a focused fake using `package.replace`/`package.reload`, and uses
`stub(...):revert()` around selected methods. `commonrequire` defines those
package helpers. This is selective substitution around real modules, rather
than one replacement implementation of every KOReader dependency.
[PluginLoader tests](https://github.com/koreader/koreader/blob/b539d24b97e52845841af6d7bb521cbba64e34dd/spec/unit/pluginloader_spec.lua),
[package helpers](https://github.com/koreader/koreader/blob/b539d24b97e52845841af6d7bb521cbba64e34dd/spec/unit/commonrequire.lua#L37).

`mock_time.lua` overrides clock sources and exposes install/uninstall/increase
operations; it does not replace the entire UIManager scheduler. The shared
`fastforward_ui_events()` helper advances the real UIManager task queue and
processes input once. `uimanager_spec.lua` tests the real queue directly.
[clock helper](https://github.com/koreader/koreader/blob/b539d24b97e52845841af6d7bb521cbba64e34dd/spec/unit/mock_time.lua),
[UI event helper](https://github.com/koreader/koreader/blob/b539d24b97e52845841af6d7bb521cbba64e34dd/spec/unit/commonrequire.lua#L77),
[scheduler tests](https://github.com/koreader/koreader/blob/b539d24b97e52845841af6d7bb521cbba64e34dd/spec/unit/uimanager_spec.lua).

Upstream coverage uses **LuaCov**: `./kodev cov` dispatches to the coverage
Make targets; `make/emulator.mk` runs frontend tests with `--coverage`, merges
per-process statistics and invokes the LuaCov reporter. `.luacov` includes
frontend and plugin modules. This differs from FastReader's custom Lua-hook and
`luac5.1` line-table report; percentages from the two are not interchangeable.
Sources: `kodev:628`, `make/emulator.mk:39`, `.luacov`.
[coverage command](https://github.com/koreader/koreader/blob/b539d24b97e52845841af6d7bb521cbba64e34dd/kodev#L628),
[coverage pipeline](https://github.com/koreader/koreader/blob/b539d24b97e52845841af6d7bb521cbba64e34dd/make/emulator.mk#L39),
[LuaCov configuration](https://github.com/koreader/koreader/blob/b539d24b97e52845841af6d7bb521cbba64e34dd/.luacov).

## What this means for FastReader

Our `tests/run.lua`, assertion library, full dependency harness, fake scheduler
and Python coverage tooling are a standalone approach, not KOReader's own
testing convention. `tests/*_test.lua` below the plugin directory are not
automatically discovered by the upstream Meson spec scan. Their line coverage
demonstrates exercised plugin lines under those fixtures, not compatibility
with real ReaderUI, font metrics, provider return values or event routing.
These conclusions follow from the source and discovery rules above, compared
with local `tests/run.lua`, `tests/support/koreader.lua` and `tests/coverage.py`.

The smallest useful alignment is to retain the fast isolated regression cases
and add a focused Busted integration suite using commonrequire, a real ReaderUI,
the FastReader plugin and the existing EPUB/PDF fixtures. It should cover real
text extraction, tap/key event routing, widget construction/paint/resize, and
stop while a real UIManager continuation is pending. Such tests can run
headlessly in a built KOReader environment; physical e-ink refresh quality
still needs a device check. This is a recommendation inferred from the upstream
examples, not an upstream requirement specific to external plugins.

A broader migration could replace the custom runner/assertions/coverage with
Busted/Luassert/LuaCov and preserve only the narrow doubles needed for pure
logic tests. An adapter that registers existing cases as Busted `it` blocks
would align reporting and discovery, but would not by itself validate native
KOReader behavior while those cases still use the full dependency harness.
No migration or new integration tests were implemented as part of this review.
