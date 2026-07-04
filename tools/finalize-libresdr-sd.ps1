param(
    [string]$VivadoRoot = "C:\Xilinx",
    [string]$SdDirectory = ""
)

$ErrorActionPreference = "Stop"
if (-not $SdDirectory) {
    $SdDirectory = Join-Path (Split-Path $PSScriptRoot -Parent) "output\libresdr-sd"
}
$SdDirectory = (Resolve-Path $SdDirectory).Path
$Bootgen = Join-Path $VivadoRoot "Vivado\2022.2\bin\bootgen.bat"
if (-not (Test-Path $Bootgen)) {
    $Bootgen = Join-Path $VivadoRoot "Vitis\2022.2\bin\bootgen.bat"
}
if (-not (Test-Path $Bootgen)) { throw "bootgen 2022.2 not found below $VivadoRoot" }

foreach ($name in "boot.bif", "fsbl.elf", "system_top.bit", "u-boot.elf") {
    if (-not (Test-Path (Join-Path $SdDirectory $name))) {
        throw "Missing SD boot input: $SdDirectory\$name"
    }
}

Push-Location $SdDirectory
try {
    & $Bootgen -arch zynq -image boot.bif -w -o BOOT.bin
    if ($LASTEXITCODE -ne 0) { throw "bootgen failed with exit code $LASTEXITCODE" }
} finally {
    Pop-Location
}
if (-not (Test-Path (Join-Path $SdDirectory "BOOT.bin")) -or
    (Get-Item (Join-Path $SdDirectory "BOOT.bin")).Length -eq 0) {
    throw "bootgen reported success but BOOT.bin is missing or empty"
}

$hashNames = @(
    "BOOT.bin", "devicetree.dtb", "system_top.bit", "u-boot.elf",
    "uImage", "uramdisk.image.gz", "uEnv.txt"
)
$hashLines = foreach ($name in $hashNames) {
    $path = Join-Path $SdDirectory $name
    if (-not (Test-Path $path)) { throw "Missing finalized SD artifact: $path" }
    $hash = (Get-FileHash -Algorithm SHA256 $path).Hash.ToLowerInvariant()
    "$hash  $name"
}
[IO.File]::WriteAllLines(
    (Join-Path $SdDirectory "SHA256SUMS.txt"),
    $hashLines,
    [Text.UTF8Encoding]::new($false)
)
Write-Host "LibreSDR SD directory finalized: $SdDirectory"
Write-Host "Copy its contents to a FAT32 SD card; do not write QSPI during bring-up."
