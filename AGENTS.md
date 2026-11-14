# Notes for agents working on ryGT7

## Switch names: SHADGT_, RYGT_ or SHARED_ (FEAT-GTS-260)

From FEAT-GTS-260 on, an environment switch is named after where it takes effect:

| Prefix | Read by | Example |
|---|---|---|
| `SHADGT_` | only the renderer (shadgt7: `src/`, `ryty_gpu/`) | `SHADGT_PARALLEL_WORKERS` |
| `RYGT_` | only the runtime (ryGT7: `core/`, `app/`, `plugins/`) | `RYGT_LOG_DIRECTORY` |
| `SHARED_` | both the renderer and the runtime | `SHARED_DIAG` |

- **A new switch** gets the prefix of the code that reads it. Never add a new `RYGT_` switch to the
  renderer or a `SHADGT_` one to the runtime.
- **A switch that starts being read on the other side too** is renamed to `SHARED_` in every
  repository (renderer, runtime, launcher, docs), and added to `SHARED` in the renderer's
  `tools/switch_prefix.py`.
- **The rename is a hard one**: the old names are not read any more. At start the launchers list
  switches saved under an old name in their obsolete-settings question and rename them on Yes
  (`SwitchWalker.FindRenames`), so players keep their settings.
- **A branch from before the rename** brings old names back on merge. Run the tool there after
  merging; a second run changes nothing:

  ```
  python tools/switch_prefix.py --game gt7 --write-map switch-map.json .   # in shadgt7
  python <shadgt7>/tools/switch_prefix.py --apply-map switch-map.json <ryGT7>   # the launcher and runtime
  ```

  It renames exact switch names only (not macros such as `RYGT_SWITCH_EXPORT`), in code, comments
  and docs. `CHANGES.MD` and `CHANGELOG.md` keep the names of their time.

## Renderer switches on the launcher's Advanced page

The launcher does not keep a list of the renderer's and runtime's `SHADGT_*`, `RYGT_*` and `SHARED_*` switches.
`SwitchWalker` in `loader/AdvancedPage.cs` reads `libs\libSceVideoOut.prx` as a file (it never loads it)
and lists every `"SHADGT_..."`, `"RYGT_..."` and `"SHARED_..."` string the renderer passes to `getenv`. Descriptions
come from the same DLL: `"RYGTSW1|NAME|kind|group|default|values|description"` strings in shadgt7's
`src/video_core/rygt_switches.cpp`. See `loader/ADVANCED-PAGE.md`.

- **Adding a renderer switch:** add its description line in shadgt7's `src/video_core/rygt_switches.cpp`
  (format in shadgt7's `AGENTS.md`). Do not add switch names, tooltips or defaults to the launcher.
- **Adding a switch read by the ryGT7 runtime** (`core/`): the walker reads every `libs\*.prx`, the
  runtime modules included (ASCII and UTF-16 names, so `_wgetenv(L"RYGT_...")` is found), so it is
  listed. Describe it in shadgt7's `src/video_core/rygt_switches.cpp` like a renderer switch (group
  `Runtime` or the one that fits); the walker takes descriptions from any of the files.
- **A variable the launcher always sets itself** (in `StartGame`): add it to
  `SwitchWalker.LauncherManaged` so the page does not offer it.
- The launcher compiles with the .NET Framework 4 `csc`: **C# 5** only (no local functions, `out var`,
  tuples or string interpolation). New `.cs` files go in `loader/build.cmd` and in the test build's
  file list in `loader/test-gt7.cmd` (CI runs it; a file missing there fails the build).

## Launcher version

The launcher is versioned on its own: `LauncherVersion.Value` in `loader/Version.cs`, with a
matching section in `loader/CHANGELOG.md`.

- **Bump only the patch number:** 0.1.0, 0.1.1, 0.1.2, and so on. Launcher changes count as minor
  updates, new features and new looks included. Do not raise the minor or major number unless the
  maintainer says so.
- Change `Version.cs` and the changelog's newest `## x.y.z - date` heading together:
  `ci/rygt7/tests/test_launcher_version.py` fails when they disagree.
