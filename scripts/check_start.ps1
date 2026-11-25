# Starts the program, waits, and fails unless it is still running with a window. Closes it afterwards.
#   pwsh scripts/check_start.ps1 -Exe <path to LazyPrint.exe> [-Seconds 10]
param(
    [Parameter(Mandatory)] [string] $Exe,
    [int] $Seconds = 10
)

$ErrorActionPreference = 'Stop'
$process = Start-Process $Exe -PassThru
try {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        Start-Sleep -Milliseconds 500
        $process.Refresh()
        if ($process.HasExited) { throw "$Exe stopped with exit code $($process.ExitCode) after starting" }
    } while ((Get-Date) -lt $deadline)
    if ($process.MainWindowHandle -eq 0) { throw "$Exe is running but opened no window in $Seconds seconds" }
    Write-Host "started: $($process.MainWindowTitle)"
} finally {
    if (-not $process.HasExited) {
        [void]$process.CloseMainWindow()
        if (-not $process.WaitForExit(5000)) { $process.Kill() }
    }
}
