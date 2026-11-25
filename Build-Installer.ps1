#requires -Version 5.1
# Builds dist\MicroWiFiGuard-Setup-<version>.exe  - a per-user installer (no admin needed on the target PC).
# Uses only what Windows already has: the .NET Framework C# compiler (csc.exe). Nothing to install.
$ErrorActionPreference = 'Stop'
$Root  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Dist  = Join-Path $Root 'dist'
$Stage = Join-Path $Dist 'payload'
$ver   = (Get-Content (Join-Path $Root 'version.txt') -Raw).Trim()
$csc   = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { throw 'csc.exe (.NET Framework 4) not found.' }

if (Test-Path $Dist) { Remove-Item $Dist -Recurse -Force }
New-Item -ItemType Directory -Path $Stage, (Join-Path $Stage 'assets') | Out-Null

# --- icon (generated, so there is nothing extra to maintain)
Add-Type -AssemblyName System.Drawing
$icoPath = Join-Path $Root 'micro.ico'
if (-not (Test-Path $icoPath)) {
    $bmp = New-Object Drawing.Bitmap(48, 48); $g = [Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'
    $g.FillEllipse((New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(80, 160, 255))), 1, 1, 46, 46)
    $pen = New-Object Drawing.Pen([Drawing.Color]::White, 4)
    foreach ($r in 9, 16, 23) { $g.DrawArc($pen, (24 - $r), (36 - $r), (2 * $r), (2 * $r), 225, 90) }
    $g.FillEllipse([Drawing.Brushes]::White, 21, 33, 6, 6); $g.Dispose()
    $icon = [Drawing.Icon]::FromHandle($bmp.GetHicon())
    $fs = [IO.File]::Create($icoPath); $icon.Save($fs); $fs.Dispose()
}

# --- payload: scripts, launchers, readme, icon, and any assets (GIFs / voice clips) you added
foreach ($f in 'Micro-WiFi.ps1', 'WiFi-Analyzer.ps1', 'Start-Floating-Widget.bat', 'Run-WiFi-Analyzer.bat', 'README.md', 'version.txt', 'micro.ico') {
    $p = Join-Path $Root $f; if (Test-Path $p) { Copy-Item $p $Stage }
}
$assets = Join-Path $Root 'assets'
if (Test-Path $assets) { Get-ChildItem $assets -File | Where-Object { $_.Name -notlike '*.env.json' -and $_.Name -ne '.gitkeep' } | Copy-Item -Destination (Join-Path $Stage 'assets') }

# zip with forward-slash entry names
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$zipPath = Join-Path $Dist 'payload.zip'
$zip = [IO.Compression.ZipFile]::Open($zipPath, 'Create')
try {
    Get-ChildItem $Stage -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($Stage.Length + 1).Replace('\', '/')
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $_.FullName, $rel, 'Optimal')
    }
} finally { $zip.Dispose() }

$out = Join-Path $Dist "MicroWiFiGuard-Setup-$ver.exe"
& $csc /nologo /target:winexe "/out:$out" "/win32icon:$icoPath" "/resource:$zipPath,payload.zip" `
    /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll `
    (Join-Path $Root 'installer\Installer.cs')
if ($LASTEXITCODE -ne 0) { throw "csc failed ($LASTEXITCODE)" }
Remove-Item $Stage -Recurse -Force
Write-Host ("Built: {0}  ({1:N0} KB)" -f $out, ((Get-Item $out).Length / 1KB))
