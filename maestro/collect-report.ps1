#Requires -Version 5.1
<#
  Runs Maestro and keeps a single on-disk snapshot: reports/latest/
  - Always: one short report.txt (last run only; all other folders under reports/ are deleted first).
  - On failure only: maestro-artifacts/ (screenshots, etc. from ~/.maestro/tests).
  - No full console log file, no summary/failed split files.
  ~/.maestro/tests is emptied after each run (copy runs before clear only if something failed).
  From the Note repo root:
    .\maestro\collect-report.ps1
    .\maestro\collect-report.ps1 -Flows @("maestro\flows\01_new_note.yaml")
  Physical device (USB): serial from "adb devices -l" — VS Code "Select Android emulator" only lists AVDs.
    .\maestro\collect-report.ps1 -Device RKCY600NB6A
  After the run, by default: force-stop + pm clear (full app data wipe on device). To skip cleanup:
    .\maestro\collect-report.ps1 -SkipAppDataCleanup
  If you run maestro manually: .\maestro\cleanup-notepad-app.ps1
  Test strings: only maestro\data\test-data.yaml (passed as maestro -e). Do not duplicate env inside flows.
#>
param(
    [string[]] $Flows = @("maestro\flows"),
    # Skip adb pm clear after the run (cleanup runs by default)
    [switch] $SkipAppDataCleanup,
    [string] $AppId = "com.atomczak.notepat",
    [string] $TestData = "",
    # ADB serial from "adb devices -l" (physical phone or a specific emulator). Omit to let Maestro choose.
    [string] $Device = ""
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot

if (-not $TestData) {
    $TestData = Join-Path $PSScriptRoot "data\test-data.yaml"
}

function Get-MaestroEnvArgsFromTestDataFile {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Warning "Test data file not found: $Path (flows that need -e may fail)"
        return @()
    }
    $envList = [System.Collections.ArrayList]::new()
    Get-Content -LiteralPath $Path | ForEach-Object {
        $line = $_.Trim()
        if ($line -eq "" -or $line.StartsWith("#")) { return }
        if ($line -notmatch '^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.+)$') { return }
        $key = $Matches[1]
        $val = $Matches[2].Trim()
        if ($val -match '^"(.*)"$') { $val = $Matches[1] }
        elseif ($val -match "^'(.*)'$") { $val = $Matches[1] }
        $val = ($val -replace '\s+#.*$', '').Trim()
        # One argv per KEY=value so values with spaces are not split by maestro.bat
        [void]$envList.Add("-e")
        [void]$envList.Add($key + "=" + $val)
    }
    return ,$envList.ToArray()
}

function Invoke-AfterMaestroAppDataClear {
    param([string] $PackageId, [string] $AdbSerial = "")
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        if (-not (Get-Command adb -ErrorAction SilentlyContinue)) {
            Write-Warning "adb not found in PATH; skipping pm clear for $PackageId"
            return
        }
        $devices = @(adb devices 2>&1 | Where-Object { $_ -match "`tdevice$" })
        if ($devices.Count -lt 1) {
            Write-Warning "No device/emulator connected (adb devices); skipping pm clear for $PackageId"
            return
        }
        if ($AdbSerial) {
            $esc = [regex]::Escape($AdbSerial)
            $match = $devices | Where-Object { $_ -match "^$esc\s" }
            if (-not $match) {
                Write-Warning "Device serial $AdbSerial not in adb devices; skipping pm clear for $PackageId"
                return
            }
        }
        $s = if ($AdbSerial) { @("-s", $AdbSerial) } else { @() }
        Write-Host ""
        Write-Host "Post-run: force-stop + pm clear (full wipe) - $PackageId$(if ($AdbSerial) { " (device $AdbSerial)" })"
        & adb @s shell am force-stop $PackageId 2>&1 | ForEach-Object { Write-Host $_ }
        & adb @s shell pm clear $PackageId 2>&1 | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "pm clear exited with code $LASTEXITCODE (package missing or device denied the operation)."
        }
    }
    finally {
        $ErrorActionPreference = $prevEap
    }
}

function Clear-MaestroRunOutputFolders {
    # Empty ~/.maestro/tests (CLI run artifacts). Do not wipe other .maestro dirs (may affect Studio auth).
    param([string] $MaestroHome)
    $testsDir = Join-Path $MaestroHome "tests"
    if (-not (Test-Path -LiteralPath $testsDir)) { return }
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        Get-ChildItem -LiteralPath $testsDir -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    finally {
        $ErrorActionPreference = $prevEap
    }
}

$timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
$maestroHome = Join-Path $env:USERPROFILE ".maestro"
$testsRoot = Join-Path $maestroHome "tests"

$beforeDirs = @()
if (Test-Path -LiteralPath $testsRoot) {
    $beforeDirs = @(Get-ChildItem -LiteralPath $testsRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
}

$maestroEnvArgs = Get-MaestroEnvArgsFromTestDataFile -Path $TestData
if ($maestroEnvArgs.Count -lt 2) {
    throw "No variables loaded from $TestData. Fix the file or pass -TestData. Flows need collect-report.ps1 (or manual maestro -e for each key)."
}

# Remove every subdirectory under reports/ (legacy reports/runs/*, old latest, etc.). Files like README.md stay.
$reportsDir = Join-Path $repoRoot "reports"
if (Test-Path -LiteralPath $reportsDir) {
    Get-ChildItem -LiteralPath $reportsDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force
    }
}
$runDir = Join-Path $reportsDir "latest"
New-Item -ItemType Directory -Force -Path $runDir | Out-Null

$logLines = [System.Collections.ArrayList]::new()
Push-Location $repoRoot
$prevEapForMaestro = $ErrorActionPreference
try {
    # Maestro/JVM may write benign warnings to stderr; Stop would treat them as terminating errors.
    $ErrorActionPreference = "Continue"
    $devicePrefix = if ($Device) { "maestro --device $Device " } else { "maestro " }
    Write-Host ("Running: " + $devicePrefix + "test " + ($maestroEnvArgs -join " ") + " " + ($Flows -join " "))
    if ($Device) {
        & maestro --device $Device test @maestroEnvArgs @Flows 2>&1 | ForEach-Object {
            $line = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { "$_" }
            [void]$logLines.Add($line)
            Write-Host $line
        }
    }
    else {
        & maestro test @maestroEnvArgs @Flows 2>&1 | ForEach-Object {
            $line = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { "$_" }
            [void]$logLines.Add($line)
            Write-Host $line
        }
    }
    $exitCode = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $prevEapForMaestro
    Pop-Location
}

if ($null -eq $exitCode) {
    $exitCode = if ($?) { 0 } else { 1 }
}

$logContent = if ($logLines.Count -gt 0) { $logLines -join [Environment]::NewLine } else { "" }
$passed = ([regex]::Matches($logContent, "\[Passed\]")).Count
$failed = ([regex]::Matches($logContent, "\[Failed\]")).Count
$total = $passed + $failed
$failedLines = @($logLines | Where-Object { $_ -match "\[Failed\]" })
$keepArtifacts = ($failed -gt 0) -or ($exitCode -ne 0)

try {
    Start-Sleep -Milliseconds 200
    try {
        if ($keepArtifacts -and (Test-Path -LiteralPath $testsRoot)) {
            $afterDirs = Get-ChildItem -LiteralPath $testsRoot -Directory -ErrorAction SilentlyContinue
            $newDirs = @($afterDirs | Where-Object { $beforeDirs -notcontains $_.FullName } | Sort-Object LastWriteTime -Descending)
            $latest = $newDirs | Select-Object -First 1
            if (-not $latest) {
                $latest = $afterDirs | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            }
            if ($latest) {
                $dest = Join-Path $runDir "maestro-artifacts"
                Copy-Item -LiteralPath $latest.FullName -Destination $dest -Recurse -Force
            }
        }
    }
    finally {
        Clear-MaestroRunOutputFolders -MaestroHome $maestroHome
    }

    $reportPath = Join-Path $runDir "report.txt"
    $reportLines = [System.Collections.ArrayList]::new()
    [void]$reportLines.Add("Last Maestro run")
    [void]$reportLines.Add("================")
    [void]$reportLines.Add("Time (local): $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    [void]$reportLines.Add("Run started:  $timestamp")
    [void]$reportLines.Add("Repository:   $repoRoot")
    [void]$reportLines.Add("ADB device:   $(if ($Device) { $Device } else { 'default (Maestro / adb chooses)' })")
    [void]$reportLines.Add("Exit code:    $exitCode")
    [void]$reportLines.Add("")
    [void]$reportLines.Add("Passed: $passed   Failed: $failed   Total: $total")
    [void]$reportLines.Add("")

    if ($failed -gt 0 -or $exitCode -ne 0) {
        [void]$reportLines.Add("Status: completed with failure(s). See [Failed] lines below.")
        if ($keepArtifacts -and (Test-Path -LiteralPath (Join-Path $runDir "maestro-artifacts"))) {
            [void]$reportLines.Add("Attachments: maestro-artifacts/ (screenshots, device output, etc.)")
        }
        else {
            [void]$reportLines.Add("Attachments: (none copied - Maestro did not leave a tests folder to copy)")
        }
        [void]$reportLines.Add("")
        [void]$reportLines.Add("--- Failures ---")
        if ($failedLines.Count -gt 0) {
            foreach ($fl in $failedLines) {
                [void]$reportLines.Add($fl)
            }
        }
        else {
            [void]$reportLines.Add("(No [Failed] lines in console output; check exit code and device.)")
        }
    }
    else {
        [void]$reportLines.Add("Status: all reported flows passed.")
        [void]$reportLines.Add("Attachments: not saved (only kept when a flow fails).")
        $artifactDir = Join-Path $runDir "maestro-artifacts"
        if (Test-Path -LiteralPath $artifactDir) {
            Remove-Item -LiteralPath $artifactDir -Recurse -Force
        }
    }

    ($reportLines -join [Environment]::NewLine) | Set-Content -LiteralPath $reportPath -Encoding UTF8

    $summaryForHost = ($reportLines -join [Environment]::NewLine)
    Write-Host ""
    Write-Host $summaryForHost
    Write-Host ""
    Write-Host "Report folder: $runDir"
    Write-Host "Saved: report.txt only (plus maestro-artifacts/ if the run failed). Cleared $maestroHome\tests."
}
finally {
    if (-not $SkipAppDataCleanup) {
        Invoke-AfterMaestroAppDataClear -PackageId $AppId -AdbSerial $Device
    }
}

exit $exitCode
