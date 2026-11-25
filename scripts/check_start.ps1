# Starts the program on empty settings and fails unless its main window is up and no error was logged.
# Windows PowerShell 5.1 (UI Automation is not in PowerShell 7).
#   powershell scripts/check_start.ps1 -Exe <path to LazyPrint.exe> [-Seconds 10]
# The user's own settings and log folders are moved aside for the run and put back afterwards.
param(
    [Parameter(Mandatory)] [string] $Exe,
    [int] $Seconds = 10,
    [string[]] $Arguments = @()
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

# Controls of the main window that are there on a first start. A message box that the crash handler shows has none of them.
$known = 'EmptyAddFilesButton', 'AddFilesButton', 'PrinterBox'

function Find-MainWindowControl([System.Diagnostics.Process] $process) {
    $process.Refresh()
    if ($process.MainWindowHandle -eq 0) { return $null }
    $window = [Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
    foreach ($id in $known) {
        $condition = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
        if ($window.FindFirst([Windows.Automation.TreeScope]::Descendants, $condition)) { return $id }
    }
    $null
}

$folders = foreach ($root in $env:APPDATA, $env:LOCALAPPDATA) { Join-Path $root 'Lazy Print' }
$errors = Join-Path $env:LOCALAPPDATA 'Lazy Print\Logs\errors.txt'
$aside = @{}
foreach ($folder in $folders) {
    if (-not (Test-Path $folder)) { continue }
    $moved = "$folder.before-start-check"
    if (Test-Path $moved) { throw "$moved is left over from an earlier run" }
    Move-Item $folder $moved
    $aside[$folder] = $moved
}

$process = $null
try {
    $process = if ($Arguments.Count) { Start-Process $Exe -ArgumentList $Arguments -PassThru } else { Start-Process $Exe -PassThru }
    $found = $null
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        Start-Sleep -Milliseconds 500
        if ($process.HasExited) { throw "$Exe stopped with exit code $($process.ExitCode) after starting" }
        if (Test-Path $errors) { throw "The program logged an error:`n$(Get-Content $errors -Raw)" }
        if (-not $found) { $found = Find-MainWindowControl $process }
    } while ((Get-Date) -lt $deadline)
    if (-not $found) { throw "No control of the main window was found in $Seconds seconds; the window is '$($process.MainWindowTitle)'" }
    Write-Host "started: found $found in '$($process.MainWindowTitle)'"
} finally {
    if ($process -and -not $process.HasExited) {
        [void]$process.CloseMainWindow()
        if (-not $process.WaitForExit(5000)) { $process.Kill(); $process.WaitForExit() }
    }
    foreach ($folder in $folders) {
        if (Test-Path $folder) { Remove-Item $folder -Recurse -Force -ErrorAction SilentlyContinue }
        if ($aside.ContainsKey($folder)) { Move-Item $aside[$folder] $folder }
    }
}
