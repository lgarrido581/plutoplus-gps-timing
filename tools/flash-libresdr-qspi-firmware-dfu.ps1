param(
  [string]$Image = "output/libre.frm",
  [string]$Device = "0456:b674",
  [string]$Alt = "firmware.dfu",
  [switch]$Verify,
  [switch]$Reset
)

$ErrorActionPreference = "Stop"

function Get-MD5Prefix {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][Int64]$Length
  )

  $md5 = [System.Security.Cryptography.MD5]::Create()
  $stream = [System.IO.File]::OpenRead((Resolve-Path $Path))
  try {
    $buffer = New-Object byte[] 1048576
    $remaining = $Length
    while ($remaining -gt 0) {
      $want = [Math]::Min($buffer.Length, $remaining)
      $read = $stream.Read($buffer, 0, $want)
      if ($read -le 0) {
        throw "Unexpected EOF while hashing $Path"
      }
      $remaining -= $read
      if ($remaining -eq 0) {
        [void]$md5.TransformFinalBlock($buffer, 0, $read)
      } else {
        [void]$md5.TransformBlock($buffer, 0, $read, $null, 0)
      }
    }
    return ([BitConverter]::ToString($md5.Hash) -replace "-", "").ToLowerInvariant()
  } finally {
    $stream.Dispose()
    $md5.Dispose()
  }
}

if (!(Test-Path $Image)) {
  throw "Firmware image not found: $Image"
}

$dfu = Get-Command dfu-util -ErrorAction SilentlyContinue
if (!$dfu) {
  $dfu = Get-Command dfu-util-static -ErrorAction SilentlyContinue
}
if (!$dfu) {
  throw "dfu-util was not found on PATH. Install dfu-util or run this script from a shell where dfu-util/dfu-util-static is available."
}

$item = Get-Item $Image
$maxFirmwareBytes = 0x1e00000
if ($item.Length -gt $maxFirmwareBytes) {
  throw "Image is $($item.Length) bytes, larger than the LibreSDR qspi-linux partition ($maxFirmwareBytes bytes)."
}

$imageHash = Get-FileHash -Algorithm MD5 $item.FullName
Write-Host "[*] Image: $($item.FullName) ($($item.Length) bytes)"
Write-Host "[*] MD5:   $($imageHash.Hash.ToLowerInvariant())"
Write-Host "[*] Looking for DFU device $Device / alt '$Alt'..."

$listOutput = & $dfu.Source -d $Device -l 2>&1
$listText = ($listOutput | Out-String)
Write-Host $listText.TrimEnd()
if ($LASTEXITCODE -ne 0) {
  throw "dfu-util could not list device $Device. Put LibreSDR in U-Boot Serial-Flash DFU mode first."
}
if ($listText -notmatch [regex]::Escape($Alt)) {
  throw "DFU alt '$Alt' was not found. Check that U-Boot is in Serial-Flash DFU mode, not RAM or another DFU mode."
}

Write-Host "[*] Flashing $Alt from $Image. Do not power off..."
& $dfu.Source -d $Device -a $Alt -D $item.FullName
if ($LASTEXITCODE -ne 0) {
  throw "dfu-util download failed."
}

if ($Verify) {
  $readback = Join-Path "output" "libresdr-qspi-firmware-readback.bin"
  Write-Host "[*] Uploading DFU readback to $readback for prefix hash verification..."
  & $dfu.Source -d $Device -a $Alt -U $readback
  if ($LASTEXITCODE -ne 0) {
    throw "dfu-util upload/readback failed."
  }
  $readHash = Get-MD5Prefix -Path $readback -Length $item.Length
  Write-Host "[*] Readback MD5 prefix: $readHash"
  if ($readHash -ne $imageHash.Hash.ToLowerInvariant()) {
    throw "Readback MD5 did not match image MD5."
  }
  Write-Host "[*] Readback verified."
}

if ($Reset) {
  Write-Host "[*] Requesting DFU detach/reset..."
  & $dfu.Source -d $Device -a $Alt -e
}

Write-Host "[*] Firmware DFU flash complete. Power-cycle or reset the board to boot from QSPI."
