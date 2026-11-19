[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$GameRoot,
    [string]$OutputRoot = '',
    [ValidateRange(200, 10000)] [int]$PollMilliseconds = 1000,
    [ValidateRange(1, 3600)] [int]$ScreenshotSeconds = 10,
    [ValidateRange(0, 10080)] [int]$DurationMinutes = 0,
    [ValidateRange(0, 10080)] [int]$WaitTimeoutMinutes = 0,
    [switch]$NoScreenshots,
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$GameRoot = [IO.Path]::GetFullPath($GameRoot)
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $GameRoot 'logs\observations'
}
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
$GameExe = Join-Path $GameRoot 'GT7.exe'
$StdoutPath = Join-Path $GameRoot 'logs\stdout.log'
$StderrPath = Join-Path $GameRoot 'logs\stderr.log'
$ArchivedLogPath = Join-Path $GameRoot 'download0\APP_DATA\logs\archived.log'
$PipelineCachePath = Join-Path $GameRoot 'shaders\CUSA03220.vkpipelinecache'

if (!(Test-Path -LiteralPath $GameRoot -PathType Container)) { throw "Game directory not found: $GameRoot" }
if (!(Test-Path -LiteralPath $GameExe -PathType Leaf)) { throw "GT7.exe not found: $GameExe" }

$nativeSource = '
using System;
using System.Runtime.InteropServices;

[StructLayout(LayoutKind.Sequential)]
public struct GT7ObserverRect
{
    public int Left;
    public int Top;
    public int Right;
    public int Bottom;
}

public static class GT7ObserverNative
{
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out GT7ObserverRect rect);
}
'
if (-not ('GT7ObserverNative' -as [type])) { Add-Type -TypeDefinition $nativeSource }
try { Add-Type -AssemblyName System.Drawing } catch { throw "Windows screen capture is unavailable: $($_.Exception.Message)" }

function Get-GameProcess {
    foreach ($process in (Get-Process -Name GT7 -ErrorAction SilentlyContinue)) {
        try {
            if ($process.Path -and [IO.Path]::GetFullPath($process.Path) -ieq $GameExe) { return $process }
        } catch { }
    }
    return $null
}

function Get-FileLength([string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) { return [long](Get-Item -LiteralPath $Path).Length }
    return [long]0
}

function Get-TraceSettings {
    $result = [ordered]@{ launcherStdoutLevel = $null; runtimeStdoutLevel = $null; relevantEnvironment = @() }
    $files = @(
        @{ Path = (Join-Path $GameRoot 'RyGT.ini'); Setting = 'launcherStdoutLevel' },
        @{ Path = (Join-Path $GameRoot 'RyGT7.ini'); Setting = 'runtimeStdoutLevel' }
    )
    foreach ($file in $files) {
        if (!(Test-Path -LiteralPath $file.Path -PathType Leaf)) { continue }
        foreach ($line in (Get-Content -LiteralPath $file.Path)) {
            if ($line -match '^\s*stdout_level\s*=\s*(.*?)\s*$') { $result[$file.Setting] = $Matches[1] }
            if ($line -match '^\s*env=[01]\|([A-Za-z0-9_]+)=(.*)$') {
                $name = $Matches[1]
                $value = $Matches[2]
                if ($name -match '(?i)(DIAG|TRACE|TELEMETRY|PERF|PROFILE|LOG|PIPELINE|SHADER|CAPTURE|HOOK)' -and
                    $name -notmatch '(?i)(TOKEN|SECRET|PASSWORD|ACCOUNT|AUTH|KEY)') {
                    $result.relevantEnvironment += [ordered]@{ name = $name; value = $value }
                }
            }
        }
    }
    return $result
}

function Write-Event([string]$Type, [object]$Data = @{}) {
    if ($script:EventWriter) {
        $record = [ordered]@{
            observedAt = [DateTimeOffset]::Now.ToString('o')
            observedAtUtc = [DateTime]::UtcNow.ToString('o')
            type = $Type
            data = $Data
        }
        $script:EventWriter.WriteLine(($record | ConvertTo-Json -Compress -Depth 8))
    }
}

function Save-LogTail([string]$Source, [string]$Destination, [long]$MaximumBytes = 262144) {
    if (!(Test-Path -LiteralPath $Source -PathType Leaf)) { return [long]0 }
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $stream = [IO.FileStream]::new($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    try {
        $stream.Position = [Math]::Max(0, $stream.Length - $MaximumBytes)
        $buffer = [byte[]]::new([int]($stream.Length - $stream.Position))
        $read = $stream.Read($buffer, 0, $buffer.Length)
        [IO.File]::WriteAllText($Destination, [Text.Encoding]::UTF8.GetString($buffer, 0, $read), [Text.UTF8Encoding]::new($false))
        return [long]$read
    } finally { $stream.Dispose() }
}

function Test-InterestingLogLine([string]$Line) {
    if ($Line -match '(?i)<(Warning|Error|Critical)>|\[(patch|unimplemented|assert|memory|batchmap|triggers|ryty_gpu|stub)\]|device.?lost|fatal|assertion|exception|timeout|stuck|failed|crash') { return $true }
    if ($Line -match '(?i)<Info>' -and $Line -match '(?i)(load|scene|race|grid|course|event|pipeline|shader|cache|progress|mount|download|device)') { return $true }
    if ($Line -match '(?i)<Debug>' -and $Line -match '(?i)(DIAG-|PERF-|FIX-|scePlayGo|sceFios|sceSaveDataMount|scePadOpenExt|pipeline cache|shader (load|compile)|script (load|read))') { return $true }
    return $false
}

function Read-AppendedLog([string]$Path, [string]$Name, [hashtable]$State, [IO.StreamWriter]$Writer) {
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $stream = $null
    try {
        $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share, 65536, [IO.FileOptions]::SequentialScan)
        if ($stream.Length -lt $State.Offset) {
            Write-Event 'log_truncated_or_replaced' @{ stream = $Name; previousOffset = $State.Offset; newLength = $stream.Length }
            $State.Offset = 0L
            $State.Pending = ''
            $State.Decoder = [Text.Encoding]::UTF8.GetDecoder()
        }
        $available = $stream.Length - $State.Offset
        if ($available -le 0) { return }
        $count = [int][Math]::Min(16777216L, $available)
        $buffer = [byte[]]::new($count)
        $stream.Position = $State.Offset
        $read = $stream.Read($buffer, 0, $count)
        if ($read -le 0) { return }
        $State.Offset += $read
        $chars = [char[]]::new([Text.Encoding]::UTF8.GetMaxCharCount($read))

        $charCount = $State.Decoder.GetChars($buffer, 0, $read, $chars, 0, $false)
        $text = $State.Pending + [string]::new($chars, 0, $charCount)
        $newline = $text.LastIndexOf("`n")
        if ($newline -lt 0) { $State.Pending = $text; return }
        $State.Pending = $text.Substring($newline + 1)
        $observedAt = [DateTimeOffset]::Now.ToString('o')
        foreach ($line in $text.Substring(0, $newline).Split([char]"`n")) {
            $line = $line.TrimEnd("`r")
            if ($Name -in @('stderr', 'archived') -or (Test-InterestingLogLine $line)) {
                $Writer.WriteLine((([ordered]@{ observedAt = $observedAt; stream = $Name; text = $line }) | ConvertTo-Json -Compress -Depth 5))
            }
        }
        if ($available -gt $count) { Write-Event 'log_backlog' @{ stream = $Name; remainingBytes = ($available - $read) } }
    } finally { if ($stream) { $stream.Dispose() } }
}

function Get-ForegroundProcessId {
    $window = [GT7ObserverNative]::GetForegroundWindow()
    [uint32]$processId = 0
    if ($window -ne [IntPtr]::Zero) { [void][GT7ObserverNative]::GetWindowThreadProcessId($window, [ref]$processId) }
    return [uint32]$processId
}

function Save-GameScreenshot([int]$ProcessId, [long]$WindowHandle, [string]$Directory) {
    $foregroundId = Get-ForegroundProcessId
    if ($foregroundId -ne $ProcessId) {
        Write-Event 'screenshot_skipped_not_foreground' @{ foregroundProcessId = $foregroundId; gameProcessId = $ProcessId }
        return $false
    }
    $rect = [GT7ObserverRect]::new()
    if (-not [GT7ObserverNative]::GetWindowRect([IntPtr]$WindowHandle, [ref]$rect)) {
        Write-Event 'screenshot_failed' @{ reason = 'GetWindowRect failed' }
        return $false
    }
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    if ($width -lt 64 -or $height -lt 64 -or $width -gt 16384 -or $height -gt 16384) {
        Write-Event 'screenshot_skipped_invalid_window_rect' @{ width = $width; height = $height }
        return $false
    }
    $path = Join-Path $Directory ('screen-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '.jpg')
    $bitmap = [Drawing.Bitmap]::new($width, $height)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, [Drawing.Size]::new($width, $height), [Drawing.CopyPixelOperation]::SourceCopy)
        $bitmap.Save($path, [Drawing.Imaging.ImageFormat]::Jpeg)
    } catch {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        Write-Event 'screenshot_failed' @{ reason = $_.Exception.Message }
        return $false
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
    Write-Event 'screenshot' @{ path = $path; bytes = (Get-Item -LiteralPath $path).Length; width = $width; height = $height }
    return $true
}

function Get-PipelineState {
    if (!(Test-Path -LiteralPath $PipelineCachePath -PathType Leaf)) { return $null }
    $item = Get-Item -LiteralPath $PipelineCachePath
    return [ordered]@{ bytes = $item.Length; lastWriteUtc = $item.LastWriteTimeUtc.ToString('o') }
}

function Start-ShaderWatcher([string]$Directory) {
    if (!(Test-Path -LiteralPath $Directory -PathType Container)) { return $null }
    $script:ShaderEventPrefix = 'GT7Observer.Shader.' + [guid]::NewGuid().ToString('N') + '.'
    $script:ShaderEventIdentifiers = @()
    $watcher = [IO.FileSystemWatcher]::new($Directory, '*.spv')
    $watcher.InternalBufferSize = 32768
    $watcher.NotifyFilter = [IO.NotifyFilters]::FileName -bor [IO.NotifyFilters]::LastWrite -bor [IO.NotifyFilters]::Size
    try {
        foreach ($name in @('Created', 'Changed', 'Renamed', 'Error')) {
            $identifier = $script:ShaderEventPrefix + $name
            Register-ObjectEvent -InputObject $watcher -EventName $name -SourceIdentifier $identifier | Out-Null
            $script:ShaderEventIdentifiers += $identifier
        }
        $watcher.EnableRaisingEvents = $true
        return $watcher
    } catch {
        $watcher.Dispose()
        foreach ($identifier in $script:ShaderEventIdentifiers) { Unregister-Event -SourceIdentifier $identifier -ErrorAction SilentlyContinue }
        throw
    }
}
function Drain-ShaderEvents {
    $batch = @()
    foreach ($identifier in $script:ShaderEventIdentifiers) {
        $remaining = 128 - $batch.Count
        if ($remaining -le 0) { break }
        $batch += @(Get-Event -SourceIdentifier $identifier -ErrorAction SilentlyContinue | Select-Object -First $remaining)
    }
    if ($batch.Count -eq 0) { return }
    $paths = @($batch | Select-Object -First 8 | ForEach-Object {
        if ($_.SourceEventArgs -is [IO.ErrorEventArgs]) { 'watcher-error: ' + $_.SourceEventArgs.GetException().Message }
        else { $_.SourceEventArgs.FullPath }
    })
    $changes = @($batch | Group-Object SourceIdentifier | ForEach-Object { [ordered]@{ event = $_.Name.Substring($script:ShaderEventPrefix.Length); count = $_.Count } })
    foreach ($entry in $batch) { Remove-Event -EventIdentifier $entry.EventIdentifier -ErrorAction SilentlyContinue }
    Write-Event 'shader_file_activity' @{ eventsDrained = $batch.Count; changes = $changes; samplePaths = $paths; queueMayHaveBacklog = ($batch.Count -eq 128) }
}

function Stop-ShaderWatcher($Watcher) {
    if ($Watcher) { $Watcher.EnableRaisingEvents = $false; $Watcher.Dispose() }
    foreach ($identifier in $script:ShaderEventIdentifiers) {
        Unregister-Event -SourceIdentifier $identifier -ErrorAction SilentlyContinue
        Get-Event -SourceIdentifier $identifier -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue
    }
}

if ($ValidateOnly) {
    $bitmap = [Drawing.Bitmap]::new(1, 1)
    $bitmap.Dispose()
    [ordered]@{
        gameRoot = $GameRoot
        executableExists = (Test-Path -LiteralPath $GameExe -PathType Leaf)
        stdoutLogExists = (Test-Path -LiteralPath $StdoutPath -PathType Leaf)
        stderrLogExists = (Test-Path -LiteralPath $StderrPath -PathType Leaf)
        archivedGameLogExists = (Test-Path -LiteralPath $ArchivedLogPath -PathType Leaf)
        pipelineCacheExists = (Test-Path -LiteralPath $PipelineCachePath -PathType Leaf)
        screenshotApiAvailable = $true
        currentGameProcess = [bool](Get-GameProcess)
        outputRoot = $OutputRoot
    } | ConvertTo-Json -Depth 4
    exit 0
}

Write-Host "GT7 observer ready; waiting for $GameExe"
Write-Host 'It attaches to the current process or waits for the next launch. Ctrl+C stops only the observer.'
$waitStarted = [DateTime]::UtcNow
$game = Get-GameProcess
while (-not $game) {
    if ($WaitTimeoutMinutes -gt 0 -and ([DateTime]::UtcNow - $waitStarted).TotalMinutes -ge $WaitTimeoutMinutes) { throw "Timed out waiting for GT7.exe after $WaitTimeoutMinutes minute(s)." }
    Start-Sleep -Milliseconds $PollMilliseconds
    $game = Get-GameProcess
}

$sessionId = [DateTime]::Now.ToString('yyyyMMddTHHmmssfffzzz').Replace(':', '')
$sessionDirectory = Join-Path $OutputRoot $sessionId
$screenshotDirectory = Join-Path $sessionDirectory 'screenshots'
New-Item -ItemType Directory -Force -Path $screenshotDirectory | Out-Null
$script:EventWriter = [IO.StreamWriter]::new((Join-Path $sessionDirectory 'events.jsonl'), $false, [Text.UTF8Encoding]::new($false))
$signalWriter = [IO.StreamWriter]::new((Join-Path $sessionDirectory 'log-signals.jsonl'), $false, [Text.UTF8Encoding]::new($false))
$metricsWriter = [IO.StreamWriter]::new((Join-Path $sessionDirectory 'process-metrics.jsonl'), $false, [Text.UTF8Encoding]::new($false))
$script:EventWriter.AutoFlush = $true
$signalWriter.AutoFlush = $true
$metricsWriter.AutoFlush = $true
$shaderWatcher = $null

try {
    $game = Get-Process -Id $game.Id
    $processInfo = Get-CimInstance Win32_Process -Filter "ProcessId = $($game.Id)" -ErrorAction SilentlyContinue
    $launcher = if ($processInfo.ParentProcessId) { Get-Process -Id $processInfo.ParentProcessId -ErrorAction SilentlyContinue } else { $null }
    $build = $null
    $buildPath = Join-Path $GameRoot 'BUILD_INFO.json'
    if (Test-Path -LiteralPath $buildPath -PathType Leaf) { $build = Get-Content -LiteralPath $buildPath -Raw | ConvertFrom-Json }
    $traceSettings = Get-TraceSettings
    $stdoutOffset = Get-FileLength $StdoutPath
    $stderrOffset = Get-FileLength $StderrPath
    $archivedOffset = Get-FileLength $ArchivedLogPath
    $baselineStdoutBytes = Save-LogTail $StdoutPath (Join-Path $sessionDirectory 'baseline-stdout-tail.txt')
    $baselineStderrBytes = Save-LogTail $StderrPath (Join-Path $sessionDirectory 'baseline-stderr-tail.txt')
    $baselineArchivedBytes = Save-LogTail $ArchivedLogPath (Join-Path $sessionDirectory 'baseline-archived-log-tail.txt')
    $instrumentation = @()
    $baselineStderrPath = Join-Path $sessionDirectory 'baseline-stderr-tail.txt'
    if (Test-Path -LiteralPath $baselineStderrPath -PathType Leaf) {
        $instrumentation = @(Get-Content -LiteralPath $baselineStderrPath | Where-Object { $_ -match '(?i)(\[patch\]|\[triggers\]|\[ryty_gpu\]|\[memory\]|\[batchmap\]|diag|trace|telemetry|instrument|profile)' })
    }
    $manifest = [ordered]@{
        schema = 1
        sessionId = $sessionId
        observerStartLocal = [DateTimeOffset]::Now.ToString('o')
        observerStartUtc = [DateTime]::UtcNow.ToString('o')
        gameRoot = $GameRoot
        process = [ordered]@{
            id = $game.Id
            parentId = $processInfo.ParentProcessId
            executablePath = $processInfo.ExecutablePath
            commandLine = $processInfo.CommandLine
            creationDate = $processInfo.CreationDate
            windowTitle = $game.MainWindowTitle
            windowHandle = $game.MainWindowHandle.ToInt64()
        }
        launcher = if ($launcher) { [ordered]@{ id = $launcher.Id; name = $launcher.ProcessName; path = $launcher.Path } } else { $null }
        build = if ($build) { [ordered]@{ rygt7Commit = $build.rygt7_commit; rendererCommit = $build.renderer_commit } } else { $null }
        traceConfiguration = $traceSettings
        instrumentationAlreadyReported = $instrumentation
        capture = [ordered]@{ screenshotsEnabled = (-not $NoScreenshots); screenshotIntervalSeconds = $ScreenshotSeconds; pollMilliseconds = $PollMilliseconds; stdoutStartOffset = $stdoutOffset; stderrStartOffset = $stderrOffset; baselineStdoutTailBytes = $baselineStdoutBytes; baselineStderrTailBytes = $baselineStderrBytes; archivedStartOffset = $archivedOffset; baselineArchivedLogTailBytes = $baselineArchivedBytes }
        limitations = @('External read-only observation only; no game input, code injection, or executable changes.', 'Startup-only instrumentation cannot be enabled retroactively.', 'Log timestamps record when appended lines were observed, not the exact emit time.')
    }
    $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $sessionDirectory 'session.json') -Encoding UTF8
    Write-Event 'observer_attached' @{ processId = $game.Id; title = $game.MainWindowTitle; sessionDirectory = $sessionDirectory; traceConfiguration = $traceSettings; instrumentationAlreadyReported = $instrumentation }
    Write-Event 'baseline' @{ stdoutBytes = $stdoutOffset; stderrBytes = $stderrOffset; pipelineCache = (Get-PipelineState) }
    Write-Host "Attached to GT7.exe PID $($game.Id). Artifacts: $sessionDirectory"
    $screenshots = 0
    if (-not $NoScreenshots -and (Save-GameScreenshot $game.Id $game.MainWindowHandle.ToInt64() $screenshotDirectory)) { $screenshots++ }

    $states = @{
        stdout = @{ Offset = $stdoutOffset; Pending = ''; Decoder = [Text.Encoding]::UTF8.GetDecoder() }
        stderr = @{ Offset = $stderrOffset; Pending = ''; Decoder = [Text.Encoding]::UTF8.GetDecoder() }
        archived = @{ Offset = $archivedOffset; Pending = ''; Decoder = [Text.Encoding]::UTF8.GetDecoder() }
    }
    $started = [DateTime]::UtcNow
    $lastSample = $started
    $nextSample = $started
    $nextScreenshot = $started.AddSeconds($ScreenshotSeconds)
    $nextPipeline = $started
    $previousCpu = [double]$game.CPU
    $previousStdout = $stdoutOffset
    $previousStderr = $stderrOffset
    $previousPipeline = Get-PipelineState
    $shaderDirectory = Join-Path $GameRoot 'shaders\CUSA03220-direct-sets'
    $shaderWatcher = Start-ShaderWatcher $shaderDirectory
    Write-Event 'shader_watcher' @{ enabled = [bool]$shaderWatcher; directory = $shaderDirectory }
    $samples = 0
    $lastConsole = $started

    while ($true) {
        Drain-ShaderEvents
        $now = [DateTime]::UtcNow
        Read-AppendedLog $StdoutPath 'stdout' $states.stdout $signalWriter
        Read-AppendedLog $StderrPath 'stderr' $states.stderr $signalWriter
        Read-AppendedLog $ArchivedLogPath 'archived' $states.archived $signalWriter
        $game = Get-Process -Id $game.Id -ErrorAction SilentlyContinue
        if (-not $game) { Write-Event 'game_process_exit' @{ processId = $manifest.process.id }; break }
        if ($DurationMinutes -gt 0 -and ($now - $started).TotalMinutes -ge $DurationMinutes) { Write-Event 'observer_duration_limit' @{ minutes = $DurationMinutes }; break }

        if ($now -ge $nextSample) {
            $elapsed = [Math]::Max(0.001, ($now - $lastSample).TotalSeconds)
            $cpu = [double]$game.CPU
            $stdoutLength = Get-FileLength $StdoutPath
            $stderrLength = Get-FileLength $StderrPath
            $metrics = [ordered]@{
                observedAt = [DateTimeOffset]::Now.ToString('o')
                observedAtUtc = $now.ToString('o')
                elapsedSeconds = [Math]::Round(($now - $started).TotalSeconds, 3)
                processId = $game.Id
                responding = $game.Responding
                windowTitle = $game.MainWindowTitle
                cpuSecondsTotal = [Math]::Round($cpu, 3)
                cpuPercentOfOneCore = [Math]::Round((100.0 * ($cpu - $previousCpu) / $elapsed), 1)
                workingSetBytes = $game.WorkingSet64
                privateBytes = $game.PrivateMemorySize64
                threadCount = $game.Threads.Count
                handleCount = $game.HandleCount
                stdoutBytes = $stdoutLength
                stdoutBytesPerSecond = [Math]::Round(($stdoutLength - $previousStdout) / $elapsed, 1)
                stderrBytes = $stderrLength
                stderrBytesPerSecond = [Math]::Round(($stderrLength - $previousStderr) / $elapsed, 1)
            }
            $metricsWriter.WriteLine(($metrics | ConvertTo-Json -Compress -Depth 5))
            $samples++
            $previousCpu = $cpu
            $previousStdout = $stdoutLength
            $previousStderr = $stderrLength
            $lastSample = $now
            $nextSample = $now.AddSeconds(2)
        }

        if ($now -ge $nextPipeline) {
            $pipeline = Get-PipelineState
            $oldBytes = if ($previousPipeline) { [long]$previousPipeline.bytes } else { [long]0 }
            $newBytes = if ($pipeline) { [long]$pipeline.bytes } else { [long]0 }
            Write-Event 'pipeline_cache_activity' @{ cache = $pipeline; bytesDelta = ($newBytes - $oldBytes) }
            $previousPipeline = $pipeline
            $nextPipeline = $now.AddSeconds(5)
        }
        if (-not $NoScreenshots -and $now -ge $nextScreenshot) {
            if (Save-GameScreenshot $game.Id $game.MainWindowHandle.ToInt64() $screenshotDirectory) { $screenshots++ }
            $nextScreenshot = $now.AddSeconds($ScreenshotSeconds)
        }
        if (($now - $lastConsole).TotalSeconds -ge 60) {
            Write-Host ('Observed {0:mm\:ss}; CPU {1:N0}s; RAM {2:N1} GiB; screenshots {3}' -f ($now - $started), $game.CPU, ($game.WorkingSet64 / 1GB), $screenshots)
            $lastConsole = $now
        }
        Start-Sleep -Milliseconds $PollMilliseconds
    }

    Read-AppendedLog $StdoutPath 'stdout' $states.stdout $signalWriter
    Read-AppendedLog $StderrPath 'stderr' $states.stderr $signalWriter
    Read-AppendedLog $ArchivedLogPath 'archived' $states.archived $signalWriter
    [ordered]@{
        schema = 1
        sessionId = $sessionId
        observerStartUtc = $manifest.observerStartUtc
        observerEndUtc = [DateTime]::UtcNow.ToString('o')
        durationSeconds = [Math]::Round(([DateTime]::UtcNow - $started).TotalSeconds, 3)
        processId = $manifest.process.id
        metricSamples = $samples
        screenshotsSaved = $screenshots
        finalStdoutOffset = $states.stdout.Offset
        finalStderrOffset = $states.stderr.Offset
        finalArchivedLogOffset = $states.archived.Offset
        artifacts = @('session.json', 'events.jsonl', 'log-signals.jsonl', 'process-metrics.jsonl', 'baseline-stdout-tail.txt', 'baseline-stderr-tail.txt', 'baseline-archived-log-tail.txt', 'screenshots/*.jpg')
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $sessionDirectory 'summary.json') -Encoding UTF8
    Write-Host "Observation complete. Artifacts: $sessionDirectory"
} finally {
    Stop-ShaderWatcher $shaderWatcher
    $script:EventWriter.Dispose()
    $signalWriter.Dispose()
    $metricsWriter.Dispose()
}
