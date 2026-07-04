param(
    [string]$VivadoRoot = "C:\Xilinx",
    [string]$HdlRoot = "",
    [string]$MakeExe = ""
)

$ErrorActionPreference = "Stop"
if (-not $HdlRoot) {
    $HdlRoot = Join-Path (Split-Path $PSScriptRoot -Parent) "output\libresdr-hdl"
}
$HdlRoot = (Resolve-Path $HdlRoot).Path
$Project = Join-Path $HdlRoot "projects\libre"
$Settings = Join-Path $VivadoRoot "Vivado\2022.2\settings64.bat"
$Vivado = Join-Path $VivadoRoot "Vivado\2022.2\bin\vivado.bat"

if (-not (Test-Path $Settings)) { throw "Vivado 2022.2 settings not found: $Settings" }
if (-not (Test-Path $Vivado)) { throw "Vivado 2022.2 executable not found: $Vivado" }
if (-not (Test-Path (Join-Path $Project "system_project.tcl"))) {
    throw "Prepared HDL tree not found. Run: bash docker-run.sh --target libresdr --prepare-hdl"
}

if (-not $MakeExe) {
    $cmd = Get-Command make.exe -ErrorAction SilentlyContinue
    if ($cmd) { $MakeExe = $cmd.Source }
}
if (-not $MakeExe -or -not (Test-Path $MakeExe)) {
    throw "GNU make.exe is required by ADI HDL. Install Cygwin make and pass -MakeExe C:\cygwin64\bin\make.exe"
}

$log = Join-Path $HdlRoot "windows-vivado-build.log"
Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
$ProjectMake = $Project.Replace('\', '/')
$MakeDir = Split-Path $MakeExe -Parent
$MsysRoot = Split-Path (Split-Path $MakeDir -Parent) -Parent
$MsysUsrBin = Join-Path $MsysRoot "usr\bin"
$ShimDir = Join-Path $HdlRoot ".win-tools"
New-Item -ItemType Directory -Force $ShimDir | Out-Null
$VivadoPosix = $Vivado.Replace('\', '/')
if ($VivadoPosix -match '^([A-Za-z]):/(.*)$') {
    $VivadoPosix = "/" + $Matches[1].ToLower() + "/" + $Matches[2]
}
$shim = Join-Path $ShimDir "vivado"
[IO.File]::WriteAllText($shim, "#!/bin/sh`nexec `"$VivadoPosix`" `"`$@`"`n",
    [Text.UTF8Encoding]::new($false))
$PathPrefix = "$ShimDir;$MakeDir"
if (Test-Path $MsysUsrBin) { $PathPrefix = "$MsysUsrBin;$PathPrefix" }
$libraryCommand = "call `"$Settings`" && set `"PATH=$PathPrefix;%PATH%`" && `"$MakeExe`" -C `"$ProjectMake`" lib"
Write-Host "Building LibreSDR HDL with Vivado 2022.2..."

# Package ADI libraries under MSYS, but launch the project with native Vivado.
# Launching Vivado through MSYS intermittently makes built-in IP catalog Tcl
# files appear unreadable on Windows.
$ErrorActionPreference = "Continue"
cmd.exe /d /s /c $libraryCommand 2>&1 | Tee-Object -FilePath $log -Append
$libraryExit = $LASTEXITCODE
$ErrorActionPreference = "Stop"
if ($libraryExit -ne 0) { throw "ADI library build failed; see $log" }

Push-Location $Project
try {
    Remove-Item libre, libre.cache, libre.gen, libre.hw, libre.ip_user_files,
        libre.runs, libre.sdk, libre.sim, libre.srcs -Recurse -Force -ErrorAction SilentlyContinue
    $ErrorActionPreference = "Continue"
    & $Vivado -mode batch -source system_project.tcl -nojournal 2>&1 |
        Tee-Object -FilePath $log -Append
    $buildExit = $LASTEXITCODE
    $ErrorActionPreference = "Stop"
} finally {
    Pop-Location
}
if ($buildExit -ne 0) { throw "Native Vivado project build failed; see $log" }

$candidates = @(
    (Join-Path $Project "libre.sdk\system_top.bit"),
    (Join-Path $Project "libre.runs\impl_1\system_top.bit")
)
$bit = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $bit) {
    $bit = Get-ChildItem $Project -Recurse -Filter system_top.bit |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $bit) { throw "Vivado completed but system_top.bit was not found under $Project" }

$timingReport = Join-Path $Project "libre.runs\impl_1\system_top_timing_summary_routed.rpt"
if (-not (Test-Path $timingReport)) {
    throw "Vivado completed but routed timing report is missing: $timingReport"
}
if (-not (Select-String -LiteralPath $timingReport `
        -SimpleMatch "All user specified timing constraints are met." -Quiet)) {
    throw "Routed design does not meet all timing constraints; see $timingReport"
}

$dest = Join-Path $HdlRoot "system_top.bit"
Copy-Item $bit $dest -Force
Write-Host "Bitstream ready: $dest"
Write-Host "Routed timing constraints: MET"
Write-Host "Next: bash docker-run.sh --target libresdr --prebuilt-bit output/libresdr-hdl/system_top.bit"
