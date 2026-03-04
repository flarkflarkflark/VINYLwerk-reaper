Write-Host 'Installing VINYLwerk for REAPER...' -ForegroundColor Cyan

$reaperPath = "$env:APPDATA\REAPER"
if (-not (Test-Path $reaperPath)) {
    Write-Error "REAPER resource directory not found at $reaperPath"
    exit 1
}

$installDir = "$reaperPath\Scripts\flarkAUDIO\VINYLwerk"
if (-not (Test-Path $installDir)) {
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
}

# Copy files
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Copy-Item "$scriptDir\..\Scripts\VINYLwerk.lua" "$installDir" -Force

if (Test-Path "$scriptDir\..\build\vinylwerk_cli_artefacts\Release\vinylwerk_cli.exe") {
    Copy-Item "$scriptDir\..\build\vinylwerk_cli_artefacts\Release\vinylwerk_cli.exe" "$installDir" -Force
} elseif (Test-Path "$scriptDir\vinylwerk_cli.exe") {
    Copy-Item "$scriptDir\vinylwerk_cli.exe" "$installDir" -Force
}

Write-Host "Successfully installed to $installDir" -ForegroundColor Green
Write-Host 'Please restart REAPER and load the script from the Actions list.'
