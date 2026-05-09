#Requires -Version 5.1
# Clears all app data for Notepad on the device/emulator (same effect as resetting the app).
# Run after `maestro test` if you did not use collect-report.ps1 (which clears by default).
param([string] $AppId = "com.atomczak.notepat")
$ErrorActionPreference = "Continue"
if (-not (Get-Command adb -ErrorAction SilentlyContinue)) {
    throw "adb not found in PATH."
}
adb shell am force-stop $AppId
adb shell pm clear $AppId
exit $LASTEXITCODE
