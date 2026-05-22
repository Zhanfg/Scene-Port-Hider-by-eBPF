param(
    [string]$Output = "..\hideSceneport_module.zip"
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Loader = Join-Path $Root "system\bin\hideport_loader"
$BpfObject = Join-Path $Root "system\bin\hideport.bpf.o"
if ([System.IO.Path]::IsPathRooted($Output)) {
    $OutputPath = $Output
} else {
    $OutputPath = Join-Path $Root $Output
}

if (-not (Test-Path -LiteralPath $Loader)) {
    throw "Missing executable: $Loader. Build it first."
}

if (-not (Test-Path -LiteralPath $BpfObject)) {
    throw "Missing BPF object: $BpfObject. Build it first."
}

if (Test-Path -LiteralPath $OutputPath) {
    Remove-Item -LiteralPath $OutputPath -Force
}

$Fingerprint = Join-Path $Root "kernel_btf.sha256"
$BtfCandidates = @(
    (Join-Path $Root "btf\vmlinux.btf"),
    (Join-Path $Root "vmlinux.btf")
)
$BtfSource = $BtfCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

if ($BtfSource) {
    (Get-FileHash -Algorithm SHA256 -LiteralPath $BtfSource).Hash.ToLowerInvariant() |
        Set-Content -LiteralPath $Fingerprint -NoNewline -Encoding ascii
    Write-Host "Wrote kernel BTF fingerprint from $BtfSource"
} elseif (Test-Path -LiteralPath $Fingerprint) {
    Remove-Item -LiteralPath $Fingerprint -Force
    Write-Host "Removed stale kernel BTF fingerprint"
} else {
    Write-Warning "No vmlinux.btf found; package will not enforce kernel BTF match."
}

$items = @(
    "module.prop",
    "hideport.conf",
    "post-fs-data.sh",
    "service.sh",
    "hideport_start.sh",
    "customize.sh",
    "uninstall.sh",
    "system"
)

if (Test-Path -LiteralPath $Fingerprint) {
    $items += "kernel_btf.sha256"
}

$paths = $items | ForEach-Object { Join-Path $Root $_ }
Compress-Archive -LiteralPath $paths -DestinationPath $OutputPath -Force
Write-Host "Wrote $OutputPath"
