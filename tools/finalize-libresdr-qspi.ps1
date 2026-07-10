param(
    [string]$VivadoRoot = "C:\Xilinx",
    [string]$SdDirectory = "",
    [string]$OutputDirectory = ""
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path $PSScriptRoot -Parent
if (-not $SdDirectory) {
    $SdDirectory = Join-Path $RepoRoot "output\libresdr-sd"
}
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $RepoRoot "output\libresdr-qspi"
}
$SdDirectory = (Resolve-Path $SdDirectory).Path
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$OutputDirectory = (Resolve-Path $OutputDirectory).Path

$Bootgen = Join-Path $VivadoRoot "Vivado\2022.2\bin\bootgen.bat"
if (-not (Test-Path $Bootgen)) {
    $Bootgen = Join-Path $VivadoRoot "Vitis\2022.2\bin\bootgen.bat"
}
if (-not (Test-Path $Bootgen)) { throw "bootgen 2022.2 not found below $VivadoRoot" }

foreach ($name in "fsbl.elf", "u-boot.elf", "uEnv.txt") {
    if (-not (Test-Path (Join-Path $SdDirectory $name))) {
        throw "Missing LibreSDR input: $SdDirectory\$name"
    }
}

$bootBif = Join-Path $OutputDirectory "boot-qspi.bif"
$bootBin = Join-Path $OutputDirectory "BOOT-qspi.bin"
$envBin = Join-Path $OutputDirectory "uboot-env.bin"
$normalizedEnv = Join-Path $OutputDirectory "uboot-env.normalized.txt"

Copy-Item -Force (Join-Path $SdDirectory "fsbl.elf") (Join-Path $OutputDirectory "fsbl.elf")
Copy-Item -Force (Join-Path $SdDirectory "u-boot.elf") (Join-Path $OutputDirectory "u-boot.elf")
Copy-Item -Force (Join-Path $SdDirectory "uEnv.txt") (Join-Path $OutputDirectory "uEnv.txt")

[IO.File]::WriteAllText(
    $bootBif,
    "img : {[bootloader] fsbl.elf u-boot.elf}`n",
    [Text.UTF8Encoding]::new($false)
)

Push-Location $OutputDirectory
try {
    & $Bootgen -arch zynq -image boot-qspi.bif -w -o BOOT-qspi.bin
    if ($LASTEXITCODE -ne 0) { throw "bootgen failed with exit code $LASTEXITCODE" }
} finally {
    Pop-Location
}

if (-not (Test-Path $bootBin) -or (Get-Item $bootBin).Length -eq 0) {
    throw "bootgen reported success but BOOT-qspi.bin is missing or empty"
}
if ((Get-Item $bootBin).Length -gt 0x100000) {
    throw "BOOT-qspi.bin is larger than mtd0 qspi-fsbl-uboot (0x100000 bytes)"
}

& python (Join-Path $PSScriptRoot "make-uboot-env.py") `
    (Join-Path $SdDirectory "uEnv.txt") `
    $envBin `
    --size 0x20000
if ($LASTEXITCODE -ne 0) { throw "make-uboot-env.py failed with exit code $LASTEXITCODE" }
if ((Get-Item $envBin).Length -ne 0x20000) {
    throw "uboot-env.bin size is not exactly 0x20000 bytes"
}

$envLines = @{}
$ordered = New-Object System.Collections.Generic.List[string]
foreach ($line in Get-Content (Join-Path $SdDirectory "uEnv.txt")) {
    $trim = $line.Trim()
    if (-not $trim -or $trim.StartsWith("#") -or -not $trim.Contains("=")) { continue }
    $key = $trim.Split("=", 2)[0]
    if ($envLines.ContainsKey($key)) {
        $ordered.Remove($key) | Out-Null
    }
    $envLines[$key] = $trim
    $ordered.Add($key)
}
$normalizedText = (($ordered | ForEach-Object { $envLines[$_] }) -join "`n") + "`n"
[IO.File]::WriteAllText($normalizedEnv, $normalizedText, [Text.UTF8Encoding]::new($false))

$hashNames = @(
    "BOOT-qspi.bin", "uboot-env.bin", "uEnv.txt", "u-boot.elf", "fsbl.elf"
)
$hashLines = foreach ($name in $hashNames) {
    $path = Join-Path $OutputDirectory $name
    if (-not (Test-Path $path)) { throw "Missing QSPI artifact: $path" }
    $hash = (Get-FileHash -Algorithm SHA256 $path).Hash.ToLowerInvariant()
    "$hash  $name"
}
[IO.File]::WriteAllText(
    (Join-Path $OutputDirectory "SHA256SUMS.txt"),
    (($hashLines -join "`n") + "`n"),
    [Text.UTF8Encoding]::new($false)
)

Write-Host "LibreSDR QSPI boot artifacts finalized: $OutputDirectory"
Write-Host ("BOOT-qspi.bin size: {0} bytes / 1048576" -f (Get-Item $bootBin).Length)
Write-Host "uboot-env.bin size: 131072 bytes"
Write-Host "Do not flash these until current QSPI mtd0/mtd1 are backed up."
