param(
    [Parameter(Mandatory = $true)][string]$Hdl,               # ADI HDL tree (2023_R2_p1)
    [string]$VivadoBin = "C:\Xilinx\Vivado\2023.2\bin"
)
# Simulate pps_counter + pps_rx_sync_mux + ADI util_ext_sync with the Vivado
# simulator (no license needed). Prints PASS/FAIL and exits non-zero on FAIL.
$ErrorActionPreference = "Stop"
$Repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$Work = Join-Path $Repo "output\zu11eg-sim"
New-Item -ItemType Directory -Force $Work | Out-Null
$srcs = @(
    (Join-Path $Repo "hdl\pps_counter\pps_counter.v"),
    (Join-Path $PSScriptRoot "..\hdl\pps_rx_sync_mux.v"),
    (Join-Path $Hdl "library\common\util_ext_sync.v"),
    (Join-Path $PSScriptRoot "tb_rx_sync.v")
)
foreach ($s in $srcs) { if (-not (Test-Path $s)) { throw "missing source: $s" } }

Push-Location $Work
try {
    & (Join-Path $VivadoBin "xvlog.bat") --nolog @srcs
    if ($LASTEXITCODE -ne 0) { throw "xvlog failed" }
    & (Join-Path $VivadoBin "xelab.bat") --nolog -debug off tb_rx_sync -s tb_rx_sync
    if ($LASTEXITCODE -ne 0) { throw "xelab failed" }
    $out = & (Join-Path $VivadoBin "xsim.bat") --nolog tb_rx_sync -R 2>&1
    $out | ForEach-Object { Write-Host $_ }
    if (-not ($out -match "^PASS tb_rx_sync")) { exit 1 }
} finally {
    Pop-Location
}
