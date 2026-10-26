# ZenOS testing: source comparison

Inspected on 2026-10-26 at ZenOS `main` commit
`a2d7230110eb1fa6f9e2e29944c49e5607a82bd6` (2026-10-15). This was source
inspection; ZenOS scripts and tests were not executed. The observations below
describe this revision, not a requirement for other plugins.

## Lua layer

ZenOS has its own orchestration script, `spec/run` (396 lines at this revision).
Its `lua` command runs LuaCheck, creates a temporary `KO_HOME`, changes into an
existing KOReader runtime, sets Lua paths, and invokes the actual Busted runner
with KOReader's bundled LuaJIT. It supplies its own helper and scans
`spec/lua/{unit,integration}`. It also saves and checks a JUnit report.
[Runner, lines 114–147](https://github.com/xZenLabs/zen-os/blob/a2d7230110eb1fa6f9e2e29944c49e5607a82bd6/spec/run#L114-L147).

That helper is not KOReader's `commonrequire`: it defines an in-memory settings
object and `ZenSpec.unload`/`ZenSpec.replace` around `package.loaded`, then installs
fake `G_reader_settings`.
[Lua helper](https://github.com/xZenLabs/zen-os/blob/a2d7230110eb1fa6f9e2e29944c49e5607a82bd6/spec/lua/support/helper.lua).
For example, the file called `integration/zen_renderer_spec.lua` replaces Device,
Font, TextWidget, container classes and BlitBuffer with explicit doubles. Thus
the directory label alone does not establish native rendering coverage.
[Renderer spec, lines 83–180](https://github.com/xZenLabs/zen-os/blob/a2d7230110eb1fa6f9e2e29944c49e5607a82bd6/spec/lua/integration/zen_renderer_spec.lua#L83-L180).

## Real emulator layer

The Python requirements are pytest, Pillow and PyAutoGUI. Their driver sends
JSON commands through a Unix socket to a test-only Lua plugin, can query visible
UI/reader state, capture framebuffers and send real pointer taps. Its launch
function starts KOReader's actual `reader.lua` with a private `KO_HOME` and socket.
[Requirements](https://github.com/xZenLabs/zen-os/blob/a2d7230110eb1fa6f9e2e29944c49e5607a82bd6/spec/python/requirements.txt),
[driver, lines 68–138](https://github.com/xZenLabs/zen-os/blob/a2d7230110eb1fa6f9e2e29944c49e5607a82bd6/spec/python/zen_driver.py#L68-L138),
[launch, lines 150–198](https://github.com/xZenLabs/zen-os/blob/a2d7230110eb1fa6f9e2e29944c49e5607a82bd6/spec/python/zen_driver.py#L150-L198).

The shell wrapper stages a disposable runtime overlay: it symlinks runtime
assets/bundled plugins, copies ZenOS production sources and the test driver,
then invokes pytest. Python fixture code separately copies a committed EPUB
corpus and can generate deterministic EPUB/CBZ libraries with fixed timestamps.
[Overlay and pytest orchestration](https://github.com/xZenLabs/zen-os/blob/a2d7230110eb1fa6f9e2e29944c49e5607a82bd6/spec/run#L161-L207),
[fixture generation](https://github.com/xZenLabs/zen-os/blob/a2d7230110eb1fa6f9e2e29944c49e5607a82bd6/spec/python/fixtures.py#L17-L41).

Direct pytest execution skips emulator scenarios unless
`ZEN_UI_RUN_EMULATOR=1`. However, `./spec/run smoke` and `full` force that flag
inside `run_test_suite`; they are not merely mock-only checks by default.
The stable CI job also runs these commands under Xvfb and uploads artifacts.
[Pytest guard](https://github.com/xZenLabs/zen-os/blob/a2d7230110eb1fa6f9e2e29944c49e5607a82bd6/spec/python/tests/test_emulator_smoke.py#L16-L19),
[suite dispatch](https://github.com/xZenLabs/zen-os/blob/a2d7230110eb1fa6f9e2e29944c49e5607a82bd6/spec/run#L279-L289),
[CI execution](https://github.com/xZenLabs/zen-os/blob/a2d7230110eb1fa6f9e2e29944c49e5607a82bd6/.github/workflows/test.yml#L73-L89).

## Runtime provisioning and limits

ZenOS pins stable KOReader `v2026.07`, compatibility `v2026.03`, and a Linux
800×600 visual profile. A separate provisioner clones/builds KOReader and caches
a dereferenced runtime. The nightly CI job builds master for compatibility
smoke tests on pull requests targeting `dev`.
[Version lock](https://github.com/xZenLabs/zen-os/blob/a2d7230110eb1fa6f9e2e29944c49e5607a82bd6/spec/koreader-lock.json),
[provisioner](https://github.com/xZenLabs/zen-os/blob/a2d7230110eb1fa6f9e2e29944c49e5607a82bd6/spec/provision-koreader.sh#L132-L156),
[nightly CI](https://github.com/xZenLabs/zen-os/blob/a2d7230110eb1fa6f9e2e29944c49e5607a82bd6/.github/workflows/test.yml#L91-L124).

There is screenshot comparison code and committed golden fixtures. That does
not mean every screenshot assertion is mandatory: the inspected smoke test's
`_assert_golden` helper returns early for some missing/platform baselines.
[Smoke golden helper](https://github.com/xZenLabs/zen-os/blob/a2d7230110eb1fa6f9e2e29944c49e5607a82bd6/spec/python/tests/test_emulator_smoke.py#L61-L73).
No dedicated LuaCov configuration or mutation-testing runner was found in this
committed tree or its test/CI orchestration. This is an inspection finding, not
a claim about historical branches or private workflows.

## Implication for FastReader

Python itself is not evidence of duplicated test logic: ZenOS uses both custom
shell orchestration and Python tooling around Busted and a real emulator.
FastReader's Python integration wrapper has a related environment-isolation
purpose, although FastReader tests real modules headlessly through upstream
Meson/Busted while ZenOS's Python layer drives a full emulator process.
ZenOS is therefore evidence that external-plugin setup glue can be legitimate;
its larger harness is not a reason to add equivalent complexity to FastReader.
Whether our wrapper can be shortened, or optional mutation tooling is worth
maintaining, is a separate design judgment about FastReader's needs.
