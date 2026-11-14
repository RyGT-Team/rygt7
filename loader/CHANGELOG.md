# ryGT7 launcher changelog

The launcher (RyGT7.exe) is versioned on its own with semantic versioning
(MAJOR.MINOR.PATCH), separately from the game, emulator and release packages.
The version lives in `loader/Version.cs`. To release a change, bump
`LauncherVersion.Value` there and add a section here with the same number;
CI fails when the two disagree.

## 0.1.7 - 2026-11-13

* FEAT-GTS-259: On the Advanced page, switches of a group whose names share their first two words
  (RYGT_PARALLEL_*, RYGT_NATIVE_*, SHADGT_DIAG_*, ...) sit under one family row, closed at first,
  instead of scattered through the list; in each group the families come first, then the other
  switches. The row shows how many switches it holds and how many are
  changed; a click anywhere on it opens or closes it, except on the row's own switch when the
  family is named after one (RYGT_NATIVE), which still flips as usual. Right and Left open and
  close it from the keyboard. Searching or "Only changed" opens the families with a match, and a
  column sort lists every switch flat.

## 0.1.6 - 2026-11-13

* FEAT-GTS-258: Settings > About shows the copyright notice ("Copyright © 2026 RyGT-Team.") and
  "Gran Turismo is a trademark of Sony Interactive Entertainment. This project is independent of
  Sony and Polyphony Digital."

## 0.1.5 - 2026-11-13

* FEAT-GTS-257: Three update channels (Settings > Display > "Update channel"): Stable (the
  default), the newest GitHub release; Prerelease, the newest release or prerelease; and Nightly,
  the newest successful build of main. Releases now come from GitHub instead of GitLab. Nightlies
  are downloaded through nightly.link (GitHub's own artifact download needs a signed-in account),
  checked against their SHA-256 and manifest, and installed like a release, with Roll back.
  Changing the channel checks it right away.

## 0.1.4 - 2026-11-13

* FEAT-GTS-256: The Advanced page also lists the runtime's switches (libkernel, libc, libScePad,
  libSceNet, libSceUserService, ...): it reads every `libs\*.prx`, not only the renderer, including
  names the runtime reads as UTF-16 (`RYGT_USER_NAME`, `RYGT_APP0_LAYERS`). Their descriptions come
  from shadgt7's table like the renderer's. The page is built the first time it is opened, so the
  launcher starts as fast as before (from RyGTS FEAT-GTS-271).

* FEAT-GTS-255: Profiles on the Advanced page (from RyGTS FEAT-GTS-270). A dropdown of saved
  profiles with Save and Load next to it: Save keeps the current switches and other variables under
  a name (`launcher\profiles\<name>.ini`, the same `env=` lines as `RyGT7.ini`), Load replaces them
  with a profile's, to swap between configurations instead of tracking several similar switches.

## 0.1.3 - 2026-11-13

* FEAT-GT7-161: Photos the game's gallery exports (Export on a Scapes or race photo) are written as
  JPEGs to a `Photos` folder next to RyGT7.exe. Set up creates the folder, updates never touch it, and
  About > Folders has a row that opens it.

## 0.1.2 - 2026-11-12

* FEAT-GTS-254: An Advanced page (last in the settings sidebar) for the renderer's experimental `RYGT_*`
  and `SHADGT_*` switches, ported from the RyGTS launcher. The launcher reads them from
  `libs\libSceVideoOut.prx` itself, with the renderer's own descriptions as hover tooltips; on/off
  switches are toggles, others text boxes. Search, sort by column, Reset all, Refresh after a renderer
  rebuild, and a table for any other environment variable. Saved as `env=` lines in `RyGT7.ini` and set
  for `GT7.exe` after the launcher's own variables. The page is hidden until About > Logging >
  "Show the Advanced page" is turned on; switches set there keep applying when it is hidden again.

## 0.1.1 - 2026-11-11

* FEAT-GTS-251: Set up no longer links the game's files into `app0` (Explorer counted the links,
  and those in every `app0.previous-*` folder, as more copies of the game): the game reads them
  from the game and update folders. Links left by earlier versions are removed, and a previous
  `app0` holding nothing else goes with them; copies are kept. ryGT7 can be on any drive.

## 0.1.0 - 2026-11-11

* First tracked launcher version.
* The version is in the exe's file properties (File version, Product version),
  in the launcher window, and on the first line of `setup.log`.
* CI packages record it as `launcher_version` in their build information.
