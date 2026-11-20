# ryGT7 launcher changelog

The launcher (RyGT7.exe) is versioned on its own with semantic versioning
(MAJOR.MINOR.PATCH), separately from the game, emulator and release packages.
The version lives in `loader/Version.cs`. To release a change, bump
`LauncherVersion.Value` there and add a section here with the same number;
CI fails when the two disagree.

## 0.1.8 - 2026-11-19

* Shaders page: adds an opt-in "Precompile shaders before starting game" toggle (`GPU.precompile_before_play`)
  that runs `tools\ryty_prewarm.exe` before launching `GT7.exe` with live progress, clean cancellation,
  incremental SPIR-V store auditing, `.meta` OS page-cache pre-warming, and monotonic `VkPipelineCache`
  compute pipeline warming.

## 0.1.7 - 2026-11-16

* FIX-GTS-271: GT7's online-service keys are no longer in ryGT7. RyGTServer reads them from your own
  GT7 eboot.bin, which the Online page passes when it starts hosting; without it, GT7's online
  service stays off.

## 0.1.6 - 2026-11-15

* FEAT-GTS-269: Settings > About carries NVIDIA's DLSS attribution, as the NVIDIA RTX SDKs License
  asks of software shipping its NGX loader: the package now includes the DLSS plugin
  (dlss\ryGT_dlss.dll), which contains it. NVIDIA's runtime still comes from Download NVIDIA DLSS.

## 0.1.5 - 2026-11-14

* FEAT-GT7-181: Graphics page, Upscaling. With NVIDIA DLSS, a "Texture detail" list sets how much finer the
  renderer's temporal DLSS reads the game's textures: Full (the default: as much as DLSS enlarges the picture
  plus one level, as NVIDIA advises, so 2 levels to 3840 x 2160 and about 1.4 to 2560 x 1440), Reduced (one
  level less) or Off. The note gives the amount for the chosen quality. The row only shows with NVIDIA DLSS
  through Streamline, no frame generation, and an installed renderer that has the setting; it applies at the
  next game start.

## 0.1.4 - 2026-11-14

* FEAT-GT7-180: Graphics page. NVIDIA DLSS and the PS4 Pro 3200 x 1800 picture can no longer be turned on
  together: the game rebuilds that picture itself, so picking one while the other is on is refused with a
  message, and a configuration that already has both shows a warning in both sections. NVIDIA DLSS frame
  generation shows a line saying it is not recommended for now (in our tests, on an RTX 4070, the game ran
  smoother without it). The 60 fps race frame rate is no longer labelled experimental. The PS4 Pro mode
  section loses its last paragraph (the test notes).

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
