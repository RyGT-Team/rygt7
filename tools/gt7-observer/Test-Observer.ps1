param(
    [string]$Observer = '',
    [Parameter(Mandatory=$true)][string]$Fixture
)
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($Observer)){$Observer=Join-Path $PSScriptRoot 'Watch-GT7.ps1'}
if(Test-Path -LiteralPath $Fixture){throw 'Choose a new fixture directory; existing paths are not overwritten.'}
$tokens=$null
$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($Observer,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw ($parseErrors | Out-String)}
$wanted=@('Get-FileLength','Get-TraceSettings','Save-LogTail','Test-InterestingLogLine','Read-AppendedLog')
$functions=$ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$true)
foreach($function in $functions){if($function.Name -in $wanted){. ([scriptblock]::Create($function.Extent.Text))}}
function Write-Event([string]$Type,[object]$Data=@{}){}
function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:Assertions++}
$script:Assertions=0
$GameRoot=Join-Path $Fixture 'game'
$signals=Join-Path $Fixture 'signals.jsonl'
$log=Join-Path $Fixture 'stdout.log'
$utf8=[Text.UTF8Encoding]::new($false)
New-Item -ItemType Directory -Path $GameRoot -Force | Out-Null
[IO.File]::WriteAllBytes((Join-Path $GameRoot 'GT7.exe'),[byte[]]@())
Assert-True ((Get-FileLength (Join-Path $Fixture 'missing')) -eq 0) 'Missing log must have zero length'
Assert-True (Test-InterestingLogLine '<Warning> shader missed') 'Warning not selected'
Assert-True (Test-InterestingLogLine '<Info> loading scene') 'Scene information not selected'
Assert-True (-not (Test-InterestingLogLine '<Info> ordinary message')) 'Ordinary info must be filtered'
[IO.File]::WriteAllText((Join-Path $GameRoot 'RyGT.ini'),"stdout_level=debug`nenv=1|RYGT_PIPELINE_TRACE=1`nenv=1|RYGT_LOG_TOKEN=secret`n",$utf8)
$settings=Get-TraceSettings
Assert-True ($settings.launcherStdoutLevel -eq 'debug') 'Trace level not read'
Assert-True ($settings.relevantEnvironment.Count -eq 1) 'Credential-named setting must be omitted'
Assert-True ($settings.relevantEnvironment[0].name -eq 'RYGT_PIPELINE_TRACE') 'Trace environment missing'
Assert-True ($settings.relevantEnvironment[0].value -eq '1') 'Trace environment value lost'
$state=@{Offset=0L;Pending='';Decoder=[Text.Encoding]::UTF8.GetDecoder()}
$writer=[IO.StreamWriter]::new($signals,$false,$utf8)
try{
    $line="<Warning> caf$([char]0xe9)`n"
    $bytes=$utf8.GetBytes($line)
    [IO.File]::WriteAllBytes($log,$bytes[0..($bytes.Length-3)])
    Read-AppendedLog $log 'stdout' $state $writer
    $writer.Flush()
    Assert-True ((Get-Item -LiteralPath $signals).Length -eq 0) 'Incomplete line emitted early'
    $stream=[IO.File]::Open($log,[IO.FileMode]::Append)
    try{$stream.Write($bytes,$bytes.Length-2,2)}finally{$stream.Dispose()}
    Read-AppendedLog $log 'stdout' $state $writer
    $writer.Flush()
    $records=@(Get-Content -LiteralPath $signals -Encoding UTF8 | ForEach-Object{$_ | ConvertFrom-Json})
    Assert-True ($records.Count -eq 1) 'UTF-8 line not emitted once'
    Assert-True ($records[0].text -eq $line.TrimEnd("`n")) 'Split UTF-8 character corrupted'
    Read-AppendedLog $log 'stdout' $state $writer
    $writer.Flush()
    Assert-True (@(Get-Content -LiteralPath $signals -Encoding UTF8).Count -eq 1) 'Duplicate line emitted'
    [IO.File]::WriteAllText($log,"error`n",$utf8)
    Read-AppendedLog $log 'stderr' $state $writer
    $writer.Flush()
    $records=@(Get-Content -LiteralPath $signals -Encoding UTF8 | ForEach-Object{$_ | ConvertFrom-Json})
    Assert-True ($records.Count -eq 2 -and $records[1].text -eq 'error') 'Truncation not handled'
    Assert-True ($state.Offset -eq 6) 'Offset not reset after truncation'
}finally{$writer.Dispose()}
$tail=Join-Path $Fixture 'tail.txt'
[IO.File]::WriteAllText($log,'0123456789',$utf8)
$count=Save-LogTail $log $tail 4
Assert-True ($count -eq 4 -and [IO.File]::ReadAllText($tail) -eq '6789') 'Tail not bounded'
Assert-True ((Get-FileLength $log) -eq 10) 'Source log changed'
[ordered]@{hostVersion=$PSVersionTable.PSVersion.ToString();assertions=$script:Assertions;result='PASS'} | ConvertTo-Json -Compress
