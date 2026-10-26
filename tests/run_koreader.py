"""Run native Busted specs with an existing KOReader emulator build, in isolation."""

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


PLUGIN = Path(__file__).resolve().parents[1]


def link(source, target):
    if not source.exists():
        raise FileNotFoundError(f"Missing KOReader build asset: {source}")
    target.symlink_to(source.resolve(), target_is_directory=source.is_dir())


def find_runtime(root, requested):
    if requested:
        candidates = [Path(requested).resolve()]
    else:
        candidates = sorted(
            root.glob("koreader-emulator-*/koreader"),
            key=lambda path: (path / "luajit").stat().st_mtime
            if (path / "luajit").exists() else 0,
            reverse=True,
        )
    for path in candidates:
        if (path / "luajit").is_file() and (path / "spec/rocks").is_dir():
            return path
    raise FileNotFoundError(
        "No built KOReader emulator found. Run ./kodev build in the KOReader "
        "checkout, or pass --runtime /path/to/koreader-emulator-.../koreader."
    )


def stage(root, runtime, destination):
    # Read-only assets stay symlinked. Every writable directory lives under the
    # temporary destination. In particular, never use the user's KO_HOME.
    for name in ("luajit", "common", "libs", "ffi", "fonts", "resources",
                 "frontend", "l10n", "datastorage.lua", "defaults.lua", "setupkoenv.lua"):
        link(runtime / name, destination / name)
    (destination / "cache").mkdir()
    (destination / "plugins").mkdir()
    link(PLUGIN, destination / "plugins/fastreader.koplugin")
    spec = destination / "spec"
    unit = spec / "front/unit"
    unit.mkdir(parents=True)
    for name in ("config.lua", "helper.lua", "meson.build", "runtests", "rocks"):
        link(runtime / "spec" / name, spec / name)
    for name in ("commonrequire.lua", "mock_time.lua"):
        link(root / "spec/unit" / name, unit / name)
    # Specs copy input documents into their private KO_HOME before opening
    # them, so DocumentRegistry can never save sidecars beside source fixtures.
    link(root / "test", unit / "data")
    for source in sorted((PLUGIN / "spec/integration").glob("*_spec.lua")):
        link(source, unit / source.name)
    return spec


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--koreader-dir", default=str(PLUGIN.parent.parent))
    parser.add_argument("--runtime", help="Built emulator's koreader directory")
    parser.add_argument("--busted", action="store_true", help="Use upstream Busted fallback")
    parser.add_argument("--coverage", action="store_true")
    parser.add_argument("--coverage-dir", default=str(PLUGIN / "coverage/koreader"))
    parser.add_argument("args", nargs=argparse.REMAINDER, help="Extra upstream runner arguments")
    options = parser.parse_args()
    root = Path(options.koreader_dir).resolve()
    runtime = find_runtime(root, options.runtime)
    with tempfile.TemporaryDirectory(prefix="fastreader-koreader-") as directory:
        destination = Path(directory)
        stage(root, runtime, destination)
        env = os.environ.copy()
        rocks = destination / "spec/rocks"
        env["LUA_PATH"] = (
            f"{rocks}/share/lua/5.1/?.lua;{rocks}/share/lua/5.1/?/init.lua;"
            "common/?.lua;frontend/?.lua;;"
        )
        env["LUA_CPATH"] = f"{rocks}/lib/lua/5.1/?.so;;"
        # runtests supplies KO_HOME for each process. Do not inherit platform
        # selectors that might make Device detect a physical reader.
        for key in ("KO_HOME", "APPIMAGE", "APPDIR", "IS_ANDROID", "KO_MULTIUSER"):
            env.pop(key, None)
        command = [str(destination / "spec/runtests")]
        if options.busted:
            command.append("--busted")
        if options.coverage:
            shutil.copyfile(PLUGIN / ".luacov", destination / ".luacov")
            command.append("--coverage")
        extra = options.args
        if extra and extra[0] == "--":
            extra = extra[1:]
        command += extra + ["front"]
        print(f"KOReader runtime: {runtime}", flush=True)
        print("Runner: upstream spec/runtests; settings and fixtures: temporary", flush=True)
        result = subprocess.run(command, cwd=destination, env=env)
        output = Path(options.coverage_dir).resolve()
        logs = destination / "spec/run/meson-logs"
        if logs.is_dir():
            output.mkdir(parents=True, exist_ok=True)
            for log in logs.iterdir():
                if log.is_file():
                    shutil.copyfile(log, output / log.name)
            print(f"Meson logs: {output}", flush=True)
        if options.coverage:
            inputs = sorted((destination / "spec/run").rglob("luacov.stats.out"))
            if not inputs:
                raise RuntimeError("KOReader did not produce LuaCov statistics")
            stats = destination / "luacov.stats.out"
            subprocess.run(
                [str(destination / "luajit"), str(root / "tools/merge_luacov_stats.lua"),
                 str(stats)] + [str(path) for path in inputs],
                cwd=destination, env=env, check=True,
            )
            env["KO_HOME"] = str(destination)
            subprocess.run(
                [str(destination / "luajit"), "-e",
                 'require("luacov.runner").run_report()', "/dev/null"],
                cwd=destination, env=env, check=True,
            )
            output.mkdir(parents=True, exist_ok=True)
            report = destination / "luacov.report.out"
            shutil.copyfile(report, output / report.name)
            print(report.read_text().split("Summary\n")[-1], flush=True)
            print(f"Native LuaCov report: {output / report.name}", flush=True)
        return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
