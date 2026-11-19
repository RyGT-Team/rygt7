# GT7 Live Observer

A read-only Windows PowerShell watcher for RyGT7's `GT7.exe`. It attaches to the current process or waits for the next launch, then records external runtime evidence without sending input, injecting code, changing configuration, or restarting the game.

## Run

Pass the directory containing `GT7.exe`, or double-click `Start-GT7-Observer.cmd` and enter that directory when prompted:

```powershell
.\tools\gt7-observer\Start-GT7-Observer.cmd -GameRoot 'C:\Games\RyGT7'
```

The command file selects `pwsh` when available and falls back to Windows PowerShell. You can also invoke `Watch-GT7.ps1` directly.

If `GT7.exe` is running, observation starts immediately. Otherwise the command waits for it. Keep this PowerShell window open while the game runs; `Ctrl+C` stops only the observer. By default, each session is saved under `<GameRoot>\logs\observations\<session timestamp>`. Use `-OutputRoot <path>` to choose another destination.

Options:

- `-ScreenshotSeconds 5` captures the GT7 window more often; default is 10 seconds.
- `-NoScreenshots` disables screen capture.
- `-DurationMinutes 30` ends observation after a fixed duration; default is until GT7 exits.
- `-WaitTimeoutMinutes 10` stops waiting if GT7 is not launched in time; default is unlimited.
- `-PollMilliseconds 500` checks process and log state more frequently; default is 1000 ms.
- `-ValidateOnly` checks paths and capture prerequisites without waiting for or attaching to the game.

## Session files

- `session.json`: process identity, parent process, build commits, trace/log settings, instrumentation already reported at startup, and observation boundaries.
- `events.jsonl`: attach/exit, pipeline-cache changes, new or changed shader-cache files, screenshot outcomes, and other observer events with local and UTC timestamps.
- `log-signals.jsonl`: newly appended stderr and archived game-log lines, plus selected stdout warnings, errors, patch/diagnostic messages, and loading/pipeline signals. Each record is timestamped when the observer reads the line.
- `process-metrics.jsonl`: responsiveness, CPU, memory, thread/handle counts, and stdout/stderr growth about every two seconds.
- `baseline-*-tail.txt`: bounded log context present at attach time; the large existing stdout log is not copied in full.
- `screenshots/*.jpg`: periodic window captures only while GT7 owns the foreground window. Captures are skipped when another app is foreground.

Startup-only environment switches, hooks, and trace levels cannot be enabled retroactively; the session records relevant configuration and instrumentation already present. The game logs do not include wall-clock timestamps per line, so recorded log times show when the observer read appended lines, not their exact emit time. Screenshots provide visual evidence for interpreting transitions.

The shader and pipeline paths currently target the `CUSA03220` cache layout. File watching can lose events on overflow, and a log replaced by an equal-sized or larger file is not detected as a rotation. A very long log line without a newline can grow the in-memory pending buffer. Process CPU samples and screenshots do not measure frame time, GPU time or audio latency. This is a diagnostic tool, not a performance benchmark.

Session files can contain local paths, command-line arguments, configuration values and player log text. Screenshots can include overlays. Review captured files before sharing them; use `-NoScreenshots` to disable image collection. The observer does not upload its output.

## Checks

Run `Test-Observer.ps1 -Fixture <new-disposable-directory>` with `pwsh` or Windows PowerShell. It checks configuration filtering, partial UTF-8 lines, log truncation and bounded log tails using synthetic files. It leaves the fixture for inspection, refuses an existing fixture directory, and does not execute `GT7.exe`.

`Watch-GT7.ps1 -GameRoot <directory> -ValidateOnly` checks paths and drawing prerequisites without starting an observation session. Screen capture and a full live process session require separate manual validation.
