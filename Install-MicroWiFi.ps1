#requires -Version 5.1
# Script installer for Micro Wi-Fi Guard - same result as the setup .exe, but works on PCs where unsigned .exe files are blocked
# (Windows 11 Smart App Control, AppLocker / WDAC). Per-user, no administrator rights needed.
#   Install:    right-click Install-MicroWiFi.bat -> Run   (or: .\Install-MicroWiFi.ps1)
#   Unattended: .\Install-MicroWiFi.ps1 -Silent [-Dir "D:\Micro"] [-NoDesktop] [-NoStartup] [-NoLaunch]
#   Uninstall:  .\Install-MicroWiFi.ps1 -Uninstall [-Silent] [-KeepData]
param(
    [string]$Dir = (Join-Path $env:LOCALAPPDATA 'MicroWiFiGuard'),
    [switch]$Silent, [switch]$NoDesktop, [switch]$NoStartup, [switch]$NoLaunch,
    [switch]$Uninstall, [switch]$KeepData
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$App = 'Micro Wi-Fi Guard'
$Src = Split-Path -Parent $MyInvocation.MyCommand.Path
$UninstKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\MicroWiFiGuard'
$StartMenu = Join-Path ([Environment]::GetFolderPath('Programs')) $App
$StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Micro Wi-Fi Guard.lnk'
$DesktopLnk = Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) "$App.lnk"
$PsExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Say([string]$m) { Write-Host $m }
function Box([string]$m, [string]$buttons = 'OK', [string]$icon = 'Information') {
    if ($Silent) { Say $m; return 'OK' }
    $o = New-Object Windows.Forms.Form; $o.TopMost = $true; $o.ShowInTaskbar = $false; $o.StartPosition = 'Manual'; $o.Location = '-32000,-32000'; $o.Size = '1,1'; $o.Show()
    try { [Windows.Forms.MessageBox]::Show($o, $m, "$App setup", $buttons, $icon) } finally { $o.Dispose() }
}
function Test-AppRunning { $m = $null; $r = [Threading.Mutex]::TryOpenExisting('Local\MicroWiFiGuard', [ref]$m); if ($m) { $m.Dispose() }; $r }
function New-Link([string]$lnk, [string]$target, [string]$arguments, [string]$work, [string]$icon, [string]$desc) {
    $sh = New-Object -ComObject WScript.Shell; $l = $sh.CreateShortcut($lnk)
    $l.TargetPath = $target; $l.Arguments = $arguments; $l.WorkingDirectory = $work; $l.Description = $desc
    if (Test-Path $icon) { $l.IconLocation = $icon }
    $l.Save()
}

if ($Uninstall) {
    if (Test-AppRunning) { Box 'Micro is running. Right-click its tray icon, choose Exit, then uninstall again.' 'OK' 'Information' | Out-Null; exit 1 }
    $deleteData = -not $KeepData
    if (-not $Silent) {
        $r = Box "Remove $App?`r`n`r`nYes = remove everything including saved data (device names, history, settings).`r`nNo = remove the program but keep my data.`r`nCancel = do nothing." 'YesNoCancel' 'Question'
        if ($r -eq 'Cancel') { exit 1 }; $deleteData = ($r -eq 'Yes')
    }
    foreach ($p in $StartupLnk, $DesktopLnk) { if (Test-Path $p) { Remove-Item $p -Force } }
    if (Test-Path $StartMenu) { Remove-Item $StartMenu -Recurse -Force }
    if (Test-Path $UninstKey) { Remove-Item $UninstKey -Recurse -Force }
    if (Test-Path $Dir) {
        $self = $MyInvocation.MyCommand.Path
        Get-ChildItem $Dir -Recurse -File -Force | Where-Object { $_.FullName -ne $self } | ForEach-Object {
            $rel = $_.FullName.Substring($Dir.Length).TrimStart('\')
            if (-not $deleteData -and ($rel -like 'MonitorData\*' -or $rel -like 'assets\*')) { return }
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
        }
        Get-ChildItem $Dir -Recurse -Directory -Force | Sort-Object { $_.FullName.Length } -Descending | Where-Object { -not (Get-ChildItem $_.FullName -Force) } | Remove-Item -Force -ErrorAction SilentlyContinue
        if ($self -like "$Dir\*") {            # this script lives in the folder: remove it a moment after we exit
            $cmd = "/c ping 127.0.0.1 -n 3 >nul & del /f /q `"$self`" & rmdir `"$Dir`""
            Start-Process cmd.exe -ArgumentList $cmd -WindowStyle Hidden
        } else { Remove-Item $Dir -Force -ErrorAction SilentlyContinue }
    }
    Box "$App was removed." | Out-Null
    exit 0
}

# ---------------------------------------------------------------- install
if (Test-AppRunning) { Box 'Micro is running. Right-click its tray icon, choose Exit, then run setup again.' 'OK' 'Warning' | Out-Null; exit 1 }
$files = 'Micro-WiFi.ps1', 'WiFi-Analyzer.ps1', 'Start-Floating-Widget.bat', 'Run-WiFi-Analyzer.bat', 'README.md', 'version.txt', 'micro.ico', 'Install-MicroWiFi.ps1', 'Install-MicroWiFi.bat'
if (-not $Silent) {
    $r = Box "Install $App to:`r`n$Dir`r`n`r`nNo administrator rights are needed. Continue?" 'OKCancel' 'Question'
    if ($r -eq 'Cancel') { exit 1 }
}
New-Item -ItemType Directory -Path $Dir -Force | Out-Null
if ((Resolve-Path $Src).Path -ne (Resolve-Path $Dir).Path) {
    foreach ($f in $files) { $p = Join-Path $Src $f; if (Test-Path $p) { Copy-Item $p (Join-Path $Dir $f) -Force } }
    $srcAssets = Join-Path $Src 'assets'
    if (Test-Path $srcAssets) {
        New-Item -ItemType Directory -Path (Join-Path $Dir 'assets') -Force | Out-Null
        Get-ChildItem $srcAssets -File | Where-Object { $_.Name -notlike '*.env.json' -and $_.Name -ne '.gitkeep' } | ForEach-Object {
            $dest = Join-Path $Dir "assets\$($_.Name)"; if (-not (Test-Path $dest)) { Copy-Item $_.FullName $dest }      # keep the user's own files
        }
    }
}
New-Item -ItemType Directory -Path (Join-Path $Dir 'MonitorData') -Force | Out-Null
$settings = Join-Path $Dir 'MonitorData\settings.json'
if ($NoStartup -and -not (Test-Path $settings)) { '{ "StartWithWindows": false, "StartupNotified": true }' | Set-Content $settings -Encoding UTF8 }

$ps1 = Join-Path $Dir 'Micro-WiFi.ps1'; $ico = Join-Path $Dir 'micro.ico'
$args1 = '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $ps1 + '"'
New-Item -ItemType Directory -Path $StartMenu -Force | Out-Null
New-Link (Join-Path $StartMenu "$App.lnk") $PsExe $args1 $Dir $ico 'Wi-Fi guard widget'
New-Link (Join-Path $StartMenu 'Full test and dashboard.lnk') (Join-Path $Dir 'Run-WiFi-Analyzer.bat') '' $Dir $ico 'Run the Full Wi-Fi test'
New-Link (Join-Path $StartMenu 'Uninstall.lnk') $PsExe ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $Dir 'Install-MicroWiFi.ps1') + '" -Uninstall -Dir "' + $Dir + '"') $Dir $ico "Remove $App"
if (-not $NoDesktop) { New-Link $DesktopLnk $PsExe $args1 $Dir $ico 'Wi-Fi guard widget' }

$ver = '1.0.0'; try { $ver = (Get-Content (Join-Path $Dir 'version.txt') -Raw).Trim() } catch {}
New-Item -Path $UninstKey -Force | Out-Null
$uninst = '"' + $PsExe + '" -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $Dir 'Install-MicroWiFi.ps1') + '" -Uninstall -Dir "' + $Dir + '"'
Set-ItemProperty $UninstKey DisplayName $App; Set-ItemProperty $UninstKey DisplayVersion $ver; Set-ItemProperty $UninstKey Publisher 'Micro'
Set-ItemProperty $UninstKey InstallLocation $Dir; Set-ItemProperty $UninstKey DisplayIcon $ico; Set-ItemProperty $UninstKey UninstallString $uninst
Set-ItemProperty $UninstKey NoModify 1 -Type DWord; Set-ItemProperty $UninstKey NoRepair 1 -Type DWord

if (-not $NoLaunch) { Start-Process $PsExe -ArgumentList $args1 -WorkingDirectory $Dir -WindowStyle Hidden }
Box "$App is installed.`r`n`r`nLook for the Wi-Fi icon in the tray (bottom-right). Ctrl+Alt+W shows or hides the widget.`r`nThe admin PIN is created the first time you open Settings." | Out-Null
