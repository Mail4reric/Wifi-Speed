#requires -Version 5.1
# Micro Wi-Fi Guard - floating widget  (PART 1: widget shell)
# PowerShell 5.1 + WinForms. No admin needed. Everything stays in .\MonitorData
param([switch]$AtLogon)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'
$Root     = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataDir  = Join-Path $Root 'MonitorData'
$AssetDir = Join-Path $Root 'assets'
foreach ($d in $DataDir, $AssetDir) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null } }
$LogFile      = Join-Path $DataDir 'micro.log'
$SettingsFile = Join-Path $DataDir 'settings.json'

# ---------------------------------------------------------------- logging
function Write-Log([string]$msg) {
    try {
        if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 200KB) {
            Move-Item $LogFile "$LogFile.old" -Force
        }
        Add-Content -Path $LogFile -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $msg)
    } catch {}
}
Write-Log '--- start ---'

# ---------------------------------------------------------------- single instance
$created = $false
$script:Mutex = New-Object System.Threading.Mutex($true, 'Local\MicroWiFiGuard', [ref]$created)
if (-not $created) { Write-Log 'second instance, exiting'; exit }

# ---------------------------------------------------------------- startup delay (sign-in launch)
if ($AtLogon) { Write-Log 'logon start: waiting 45s for Wi-Fi'; Start-Sleep -Seconds 45 }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing, PresentationCore, WindowsBase
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Windows.Forms;
using System.Runtime.InteropServices;

public class WidgetForm : Form {
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h, int id, uint mod, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h, int id);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    public event EventHandler HotKeyPressed;
    public bool HotKeyOk;
    const int HK_ID = 0x4D31;
    public WidgetForm() {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                 ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
    }
    protected override CreateParams CreateParams {
        get { CreateParams cp = base.CreateParams;
              cp.ExStyle |= 0x08000000 | 0x00000080 | 0x00000008;  // NOACTIVATE | TOOLWINDOW | TOPMOST
              return cp; }
    }
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override void OnHandleCreated(EventArgs e) {
        base.OnHandleCreated(e);
        HotKeyOk = RegisterHotKey(Handle, HK_ID, 0x3, 0x57);      // Ctrl+Alt+W
    }
    protected override void OnHandleDestroyed(EventArgs e) {
        UnregisterHotKey(Handle, HK_ID);
        base.OnHandleDestroyed(e);
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0312 && m.WParam.ToInt32() == HK_ID) {
            if (HotKeyPressed != null) HotKeyPressed(this, EventArgs.Empty);
            return;
        }
        if (m.Msg == 0x0021) { m.Result = (IntPtr)3; return; }   // WM_MOUSEACTIVATE -> MA_NOACTIVATE
        base.WndProc(ref m);
    }
}

// Per-pixel-alpha window (real transparency) for the alert popup. Never takes focus.
public class AlphaForm : Form {
    [StructLayout(LayoutKind.Sequential)] struct PT { public int x, y; }
    [StructLayout(LayoutKind.Sequential)] struct SZ { public int cx, cy; }
    [StructLayout(LayoutKind.Sequential, Pack = 1)] struct BL { public byte Op, Flags, Alpha, Fmt; }
    [DllImport("user32.dll", SetLastError = true)] static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref PT pptDst, ref SZ psize, IntPtr hdcSrc, ref PT pptSrc, int crKey, ref BL pblend, int dwFlags);
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr hDC);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr hDC, IntPtr h);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr h);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr hDC);
    protected override CreateParams CreateParams {
        get { CreateParams cp = base.CreateParams;
              cp.ExStyle |= 0x00080000 | 0x08000000 | 0x00000080 | 0x00000008;  // LAYERED | NOACTIVATE | TOOLWINDOW | TOPMOST
              return cp; }
    }
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0021) { m.Result = (IntPtr)3; return; }
        base.WndProc(ref m);
    }
    public void SetBitmap(Bitmap bmp, int x, int y) {
        if (!IsHandleCreated) return;
        IntPtr scr = GetDC(IntPtr.Zero); IntPtr mem = CreateCompatibleDC(scr);
        IntPtr hb = IntPtr.Zero; IntPtr old = IntPtr.Zero;
        try {
            hb = bmp.GetHbitmap(Color.FromArgb(0)); old = SelectObject(mem, hb);
            SZ sz; sz.cx = bmp.Width; sz.cy = bmp.Height;
            PT src; src.x = 0; src.y = 0;
            PT dst; dst.x = x; dst.y = y;
            BL bl; bl.Op = 0; bl.Flags = 0; bl.Alpha = 255; bl.Fmt = 1;      // AC_SRC_OVER, AC_SRC_ALPHA
            UpdateLayeredWindow(Handle, scr, ref dst, ref sz, mem, ref src, 0, ref bl, 2);
        } finally {
            ReleaseDC(IntPtr.Zero, scr);
            if (hb != IntPtr.Zero) { SelectObject(mem, old); DeleteObject(hb); }
            DeleteDC(mem);
        }
    }
}

public static class SndHelper {      // loudness (RMS) per frame from 16-bit PCM
    public static double[] Rms(byte[] d, int offset, int count, int frameSamples) {
        int frames = count / 2 / frameSamples; double[] r = new double[frames];
        for (int f = 0; f < frames; f++) {
            double s = 0; int b = offset + f * frameSamples * 2;
            for (int i = 0; i < frameSamples; i++) { short v = (short)(d[b + 2 * i] | (d[b + 2 * i + 1] << 8)); s += (double)v * v; }
            r[f] = Math.Sqrt(s / frameSamples);
        }
        return r;
    }
}
'@
[void][WidgetForm]::SetProcessDPIAware()
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({ param($s, $e) Write-Log ("UI exception: " + $e.Exception.ToString()) })
[AppDomain]::CurrentDomain.add_UnhandledException({ param($s, $e) Write-Log ("Fatal: " + $e.ExceptionObject.ToString()) })

# ---------------------------------------------------------------- settings
$Settings = [ordered]@{ Corner = 'BottomRight'; Screen = ''; Expanded = $false; Voice = $false; Character = 'micro'; AlertMode = 'button'
                        SlowLimit = 10; GoodLimit = 50; GoodMode = 'daily'; IntervalMin = 30; LastGoodDate = ''
                        StartWithWindows = $true; StartupNotified = $false; AdminPinSalt = ''; AdminPinHash = '' }
if (Test-Path $SettingsFile) {
    try {
        $j = Get-Content $SettingsFile -Raw | ConvertFrom-Json
        foreach ($k in @($Settings.Keys)) { if ($null -ne $j.$k) { $Settings[$k] = $j.$k } }
    } catch { Write-Log "settings load failed: $_" }
}
function Save-Settings { try { $Settings | ConvertTo-Json | Set-Content -Path $SettingsFile -Encoding UTF8 } catch { Write-Log "settings save failed: $_" } }

# ---------------------------------------------------------------- state shown by the widget
$State = @{
    Signal = 0; Ssid = 'Not connected'; Band = ''; Channel = ''
    Down = 0.0; Up = 0.0
    RouterPing = $null; Unnamed = 0; DnsShield = $null   # filled by later parts
}
$Samples = 120
$DownHist = New-Object 'System.Collections.Generic.List[double]'
$UpHist   = New-Object 'System.Collections.Generic.List[double]'
for ($i = 0; $i -lt $Samples; $i++) { $DownHist.Add(0); $UpHist.Add(0) }

# ================================================================ PART 2: devices
$StartTime  = Get-Date
$DevFile    = Join-Path $DataDir 'devices.json'
$Devices    = @{}                       # mac -> device object
$script:DevList = @(); $script:DevScroll = 0; $script:DevDirty = $false; $script:DialogOpen = $false
$State.Gateway = ''; $State.LocalMac = ''; $State.LocalIp = ''
$OnlineSeconds = 50; $AwaySeconds = 300; $WarmupSeconds = 25

function Test-BadMac([string]$m) {
    if (-not $m -or $m.Length -ne 17) { return $true }
    return ($m -eq 'ff:ff:ff:ff:ff:ff' -or $m -eq '00:00:00:00:00:00' -or $m.StartsWith('01:00:5e') -or $m.StartsWith('33:33'))
}
function Test-PrivateMac([string]$m) { return (([Convert]::ToInt32($m.Substring(0, 2), 16) -band 2) -ne 0) }
function Test-Online($d) {
    if ($d.LastSeen -eq [datetime]::MinValue) { return $false }
    return ((Get-Date) - $d.LastSeen).TotalSeconds -le $OnlineSeconds
}
function Get-DevTitle($d) {
    if ($d.Name) { return $d.Name }
    if ($d.AutoName) { return $d.AutoName }
    return 'Unnamed device'
}
function Format-Ago($dt) {
    if ($dt -eq [datetime]::MinValue) { return 'not seen yet' }
    $s = ((Get-Date) - $dt).TotalSeconds
    if ($s -lt 60) { return 'just now' }
    if ($s -lt 3600) { return ('{0} min ago' -f [int]($s / 60)) }
    if ($s -lt 86400) { return ('{0} h ago' -f [int]($s / 3600)) }
    return ('{0} d ago' -f [int]($s / 86400))
}

function Save-Devices {
    try {
        $arr = foreach ($d in $Devices.Values) {
            [ordered]@{ Mac = $d.Mac; Ip = $d.Ip; Hostname = $d.Hostname; Vendor = $d.Vendor; Name = $d.Name
                        FirstSeen = $d.FirstSeen.ToString('o'); LastSeen = $d.LastSeen.ToString('o') }
        }
        ConvertTo-Json -InputObject @($arr) | Set-Content -Path $DevFile -Encoding UTF8
        $script:DevDirty = $false
    } catch { Write-Log "devices save failed: $_" }
}
function Import-Devices {
    if (-not (Test-Path $DevFile)) { return }
    try {
        $ci = [Globalization.CultureInfo]::InvariantCulture
        foreach ($j in @(Get-Content $DevFile -Raw | ConvertFrom-Json)) {
            if (Test-BadMac $j.Mac) { continue }
            $Devices[$j.Mac] = [pscustomobject]@{
                Mac = $j.Mac; Ip = [string]$j.Ip; Hostname = [string]$j.Hostname; Vendor = [string]$j.Vendor
                Name = [string]$j.Name; AutoName = ''; Private = (Test-PrivateMac $j.Mac)
                FirstSeen = [datetime]::Parse($j.FirstSeen, $ci, 'RoundtripKind')
                LastSeen  = [datetime]::Parse($j.LastSeen,  $ci, 'RoundtripKind') }
        }
    } catch { Write-Log "devices load failed: $_" }
}
$FirstRun = -not (Test-Path $DevFile)          # first ever run: learn the network quietly for 2 minutes
if ($FirstRun) { $WarmupSeconds = 120; Write-Log 'first run: quiet learning for 120 s' }
Import-Devices

# Alerts are queued; Pump-Alerts (Part 3) shows them one at a time with a 10 s cooldown.
$script:AlertQueue = New-Object System.Collections.ArrayList
$script:Pending = New-Object System.Collections.ArrayList      # new devices waiting for the "New device" button
$script:BalloonKind = ''
function Raise-DeviceAlert($d, [string]$kind) {
    $who = if ($d.Hostname) { $d.Hostname } else { 'no name announced' }
    Write-Log "ALERT $kind $($d.Mac) $($d.Ip) $who"
    if ($Settings.AlertMode -eq 'popup') {                  # old behaviour: popup on its own
        foreach ($a in $script:AlertQueue) { if ($a.Dev.Mac -eq $d.Mac) { return } }
        [void]$script:AlertQueue.Add(@{ Dev = $d; Kind = $kind })
        while ($script:AlertQueue.Count -gt 5) { $script:AlertQueue.RemoveAt(0) }
        return
    }
    foreach ($a in $script:Pending) { if ($a.Dev.Mac -eq $d.Mac) { return } }       # default: wait for the button
    [void]$script:Pending.Add(@{ Dev = $d; Kind = $kind })
    while ($script:Pending.Count -gt 20) { $script:Pending.RemoveAt(0) }
    if ($script:Pending.Count -eq 1) {
        try { $script:BalloonKind = 'device'; $tray.BalloonTipTitle = 'New device on your Wi-Fi'; $tray.BalloonTipText = 'Click here (or the blue button on the widget) to see it.'; $tray.ShowBalloonTip(6000) } catch {}
    }
}
function Open-PendingDevice {
    while ($script:Pending.Count -gt 0) {
        $a = $script:Pending[0]; $script:Pending.RemoveAt(0)
        $d = $a.Dev
        if ($d.Name -or $d.AutoName) { continue }         # named in the meantime
        Show-DevicePopup $d $a.Kind; break
    }
    $form.Invalidate()
}

function Touch-Device([string]$mac, [string]$ip, [bool]$alive, [string]$hn, [string]$vendor) {
    if (Test-BadMac $mac) { return }
    $now = Get-Date
    $d = $Devices[$mac]; $isNew = $false
    if (-not $d) {
        if (-not $alive) { return }
        $d = [pscustomobject]@{ Mac = $mac; Ip = $ip; Hostname = ''; Vendor = ''; Name = ''; AutoName = ''
                                Private = (Test-PrivateMac $mac); FirstSeen = $now; LastSeen = [datetime]::MinValue }
        $Devices[$mac] = $d; $isNew = $true; $script:DevDirty = $true
    }
    if ($ip) { $d.Ip = $ip }
    if ($hn -and $d.Hostname -ne $hn)         { $d.Hostname = $hn;     $script:DevDirty = $true }
    if ($vendor -and $d.Vendor -ne $vendor)   { $d.Vendor = $vendor;   $script:DevDirty = $true }
    if ($mac -eq $State.LocalMac)               { $d.AutoName = "This PC ($env:COMPUTERNAME)" }
    elseif ($ip -and $ip -eq $State.Gateway)    { $d.AutoName = 'Router' }
    if ($alive) {
        $gap = if ($d.LastSeen -eq [datetime]::MinValue) { [double]::MaxValue } else { ($now - $d.LastSeen).TotalSeconds }
        $d.LastSeen = $now
        $unnamed = (-not $d.Name) -and (-not $d.AutoName)
        if ($unnamed -and (($now - $StartTime).TotalSeconds -gt $WarmupSeconds)) {
            if ($isNew) { Raise-DeviceAlert $d 'new' }
            elseif ($gap -gt $AwaySeconds) { Raise-DeviceAlert $d 'back' }
        }
    }
}

function Process-Events {
    $ev = $null; $n = 0
    while ($n -lt 300 -and $Sync.Queue.TryDequeue([ref]$ev)) {
        $n++
        try {
            switch ($ev.Type) {
                'Net'        { $State.Gateway = $ev.Gateway; $State.LocalIp = $ev.Ip; $State.LocalMac = $ev.Mac
                               Touch-Device $ev.Mac $ev.Ip $true '' '' }
                'Seen'       { Touch-Device $ev.Mac $ev.Ip $ev.Alive '' '' }
                'Dhcp'       { Touch-Device $ev.Mac $ev.Ip $true $ev.Hostname $ev.Vendor }
                'RouterPing' { $State.RouterPing = $(if ($null -ne $ev.Ms) { [int]$ev.Ms } else { $null }) }
                'InetPing'   { $State.InetPing = $(if ($null -ne $ev.Ms) { [int]$ev.Ms } else { $null }) }
                'Speed'      { Handle-Speed $ev }
                'Dns'        { Handle-Dns $ev }
                'Log'        { Write-Log ('scan: ' + $ev.Msg) }
            }
        } catch { Write-Log "event error: $_" }
    }
}

function Refresh-DevList {
    $script:DevList = @($Devices.Values | Sort-Object `
        @{ Expression = { if (Test-Online $_) { 0 } else { 1 } } },
        @{ Expression = { try { [int]($_.Ip.Split('.')[-1]) } catch { 999 } } })
    $u = 0
    foreach ($d in $script:DevList) { if ((Test-Online $d) -and -not $d.Name -and -not $d.AutoName) { $u++ } }
    $State.Unnamed = $u
}

function Edit-DeviceName([string]$mac) {
    $d = $Devices[$mac]
    if (-not $d -or $script:DialogOpen) { return }
    if (-not (Require-Admin)) { return }
    $script:DialogOpen = $true
    try {
        $f = New-Object Windows.Forms.Form
        $f.Text = 'Name this device'; $f.ClientSize = New-Object Drawing.Size(360, 170)
        $f.StartPosition = 'CenterScreen'; $f.FormBorderStyle = 'FixedDialog'
        $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.TopMost = $true; $f.ShowInTaskbar = $true
        $lbl = New-Object Windows.Forms.Label
        $calls = if ($d.Hostname) { "calls itself: $($d.Hostname)" } else { 'did not announce a name' }
        $priv = if ($d.Private) { '   (private MAC)' } else { '' }
        $lbl.Text = "IP $($d.Ip)    MAC $($d.Mac)$priv`r`n$calls`r`nGive it a name you will recognise, e.g. 'Mum's phone'."
        $lbl.SetBounds(14, 12, 332, 62)
        $tb = New-Object Windows.Forms.TextBox; $tb.SetBounds(14, 84, 332, 24); $tb.Text = $d.Name; $tb.MaxLength = 40
        $ok = New-Object Windows.Forms.Button; $ok.Text = 'Save'; $ok.SetBounds(186, 124, 78, 28); $ok.DialogResult = 'OK'
        $cn = New-Object Windows.Forms.Button; $cn.Text = 'Cancel'; $cn.SetBounds(270, 124, 78, 28); $cn.DialogResult = 'Cancel'
        $f.AcceptButton = $ok; $f.CancelButton = $cn
        $f.Controls.AddRange(@($lbl, $tb, $ok, $cn))
        if ($f.ShowDialog() -eq 'OK') {
            $d.Name = $tb.Text.Trim(); Save-Devices; Refresh-DevList; $form.Invalidate()
            Write-Log "device $mac named '$($d.Name)'"
        }
        $f.Dispose()
    } catch { Write-Log "name dialog: $_" }
    finally { $script:DialogOpen = $false }
}

# ---- device list drawing (called from the paint handler)
$sfEll = New-Object Drawing.StringFormat; $sfEll.Trimming = 'EllipsisCharacter'; $sfEll.FormatFlags = 'NoWrap'
$sfRight = New-Object Drawing.StringFormat; $sfRight.Alignment = 'Far'; $sfRight.Trimming = 'EllipsisCharacter'; $sfRight.FormatFlags = 'NoWrap'
function Draw-DeviceList($g) {
    $cx = 14; $cy = 386; $cw = 272; $ch = 186; $rowH = 32; $vis = 5; $top = $cy + 26
    Fill-Card $g $cx $cy $cw $ch $sbCard
    $total = $script:DevList.Count; $on = 0
    foreach ($d in $script:DevList) { if (Test-Online $d) { $on++ } }
    $g.DrawString("Devices on your Wi-Fi  ($on online / $total)", $fMid, $sbText, 22, ($cy + 4))
    $max = [math]::Max(0, $total - $vis); if ($script:DevScroll -gt $max) { $script:DevScroll = $max }
    $g.SetClip((New-Object Drawing.Rectangle($cx, $top, $cw, ($vis * $rowH))))
    if ($total -eq 0) { $g.DrawString('Listening... devices appear here.', $fSmall, $sbDim, 22, ($top + 6)) }
    for ($i = 0; $i -lt $vis; $i++) {
        $idx = $i + $script:DevScroll; if ($idx -ge $total) { break }
        $d = $script:DevList[$idx]; $y = $top + $i * $rowH
        $online = Test-Online $d
        $dotB = New-Object Drawing.SolidBrush($(if ($online) { $cOk } else { [Drawing.Color]::FromArgb(90, 98, 116) }))
        $g.FillEllipse($dotB, ($cx + 8), ($y + 12), 8, 8); $dotB.Dispose()
        $unnamed = (-not $d.Name) -and (-not $d.AutoName)
        $nameBrush = if ($unnamed) { New-Object Drawing.SolidBrush($cWarn) } else { $sbText }
        $nw = if ($d.Private) { 130 } else { 238 }
        $g.DrawString((Get-DevTitle $d), $fMid, $nameBrush, (New-Object Drawing.RectangleF(($cx + 22), ($y + 1), $nw, 16)), $sfEll)
        if ($unnamed) { $nameBrush.Dispose() }
        if ($d.Private) {
            $pb = New-Object Drawing.SolidBrush($cWarn)
            $g.DrawString('private MAC', $fSmall, $pb, (New-Object Drawing.RectangleF(($cx + 150), ($y + 3), 110, 14)), $sfRight); $pb.Dispose()
        }
        $info = $d.Ip; if ($d.Hostname) { $info += "  calls itself: $($d.Hostname)" }
        $g.DrawString($info, $fSmall, $sbDim, (New-Object Drawing.RectangleF(($cx + 22), ($y + 17), 160, 14)), $sfEll)
        $stTxt = if ($online) { 'online' } else { Format-Ago $d.LastSeen }
        $stB = New-Object Drawing.SolidBrush($(if ($online) { $cOk } else { $cDim }))
        $g.DrawString($stTxt, $fSmall, $stB, (New-Object Drawing.RectangleF(($cx + 180), ($y + 17), 80, 14)), $sfRight); $stB.Dispose()
        Add-Hit ('dev:' + $d.Mac) ($cx + 4) $y ($cw - 8) $rowH
    }
    $g.ResetClip()
    if ($total -gt $vis) {
        $th = ($vis * $rowH) * $vis / $total; $ty = $top + ($vis * $rowH - $th) * $script:DevScroll / $max
        $sb = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(90, 98, 116))
        $g.FillRectangle($sb, ($cx + $cw - 5), $ty, 3, $th); $sb.Dispose()
    }
}

# ---- background scanner (own runspace; talks to the UI only through a ConcurrentQueue)
$Sync = [hashtable]::Synchronized(@{ Queue = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'); Stop = $false })
$ScanScript = @'
param($Sync)
$q = $Sync.Queue
function Emit([string]$type, [hashtable]$d) { $d.Type = $type; $q.Enqueue([pscustomobject]$d) }
function Norm-Mac([string]$s) {
    $h = ($s -replace '[^0-9a-fA-F]', '').ToLower()
    if ($h.Length -ne 12) { return '' }
    return (($h -split '(..)' | Where-Object { $_ }) -join ':')
}
function Get-Net {
    foreach ($n in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($n.NetworkInterfaceType -ne 'Wireless80211' -or $n.OperationalStatus -ne 'Up') { continue }
        $p = $n.GetIPProperties()
        $ua = $p.UnicastAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
        if (-not $ua) { continue }
        $gw = $p.GatewayAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
        return @{ Ip = $ua.Address.ToString(); Gateway = $(if ($gw) { $gw.Address.ToString() } else { '' })
                  Mac = (Norm-Mac $n.GetPhysicalAddress().ToString()); Index = $p.GetIPv4Properties().Index }
    }
    return $null
}
function Parse-Dhcp([byte[]]$b, [int]$n) {
    if ($n -lt 241 -or $b[0] -ne 1) { return }                       # only client requests (BOOTREQUEST)
    if (-not ($b[236] -eq 99 -and $b[237] -eq 130 -and $b[238] -eq 83 -and $b[239] -eq 99)) { return }
    $hl = [Math]::Min([int]$b[2], 16)
    $mac = Norm-Mac ([BitConverter]::ToString($b, 28, $hl))
    $ci = '{0}.{1}.{2}.{3}' -f $b[12], $b[13], $b[14], $b[15]
    $i = 240; $type = 0; $hn = ''; $req = ''; $vend = ''
    while ($i -lt $n) {
        $c = $b[$i]
        if ($c -eq 255) { break }
        if ($c -eq 0) { $i++; continue }
        if ($i + 1 -ge $n) { break }
        $l = [int]$b[$i + 1]; $d = $i + 2
        if ($d + $l -gt $n) { break }
        switch ($c) {
            53 { $type = [int]$b[$d] }
            12 { $hn = [Text.Encoding]::UTF8.GetString($b, $d, $l).Trim([char]0, ' ') }
            50 { if ($l -eq 4) { $req = '{0}.{1}.{2}.{3}' -f $b[$d], $b[$d + 1], $b[$d + 2], $b[$d + 3] } }
            60 { $vend = [Text.Encoding]::UTF8.GetString($b, $d, $l).Trim([char]0, ' ') }
        }
        $i = $d + $l
    }
    if (-not $mac -or $type -eq 7) { return }                         # ignore releases
    $ip = if ($ci -ne '0.0.0.0') { $ci } else { $req }
    Emit 'Dhcp' @{ Mac = $mac; Ip = $ip; Hostname = $hn; Vendor = $vend; MsgType = $type }
}
function Sweep([string]$ip) {
    $pre = ($ip.Split('.')[0..2]) -join '.'
    $pings = New-Object System.Collections.ArrayList; $tasks = New-Object System.Collections.ArrayList
    foreach ($i in 1..254) {
        $pg = New-Object Net.NetworkInformation.Ping
        [void]$pings.Add($pg); [void]$tasks.Add($pg.SendPingAsync("$pre.$i", 600))
    }
    try { [void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$tasks.ToArray(), 4000) } catch {}
    foreach ($pg in $pings) { $pg.Dispose() }
}
function Poll-Arp($net) {
    $pre = ($net.Ip.Split('.')[0..2]) -join '.'
    foreach ($nb in (Get-NetNeighbor -AddressFamily IPv4 -InterfaceIndex $net.Index -ErrorAction SilentlyContinue)) {
        $ip = [string]$nb.IPAddress
        if (-not $ip.StartsWith("$pre.") -or $ip.EndsWith('.255') -or $ip.EndsWith('.0')) { continue }
        $mac = Norm-Mac ([string]$nb.LinkLayerAddress)
        if (-not $mac -or $mac -eq 'ff:ff:ff:ff:ff:ff' -or $mac -eq '00:00:00:00:00:00') { continue }
        Emit 'Seen' @{ Mac = $mac; Ip = $ip; Alive = ("$($nb.State)" -eq 'Reachable') }
    }
}

# DHCP listener (UDP 67). Optional: if the port is taken we just carry on without it.
$sock = $null
try {
    $sock = New-Object Net.Sockets.Socket([Net.Sockets.AddressFamily]::InterNetwork, [Net.Sockets.SocketType]::Dgram, [Net.Sockets.ProtocolType]::Udp)
    $sock.SetSocketOption([Net.Sockets.SocketOptionLevel]::Socket, [Net.Sockets.SocketOptionName]::ReuseAddress, $true)
    $sock.EnableBroadcast = $true
    $sock.Bind((New-Object Net.IPEndPoint([Net.IPAddress]::Any, 67)))
    Emit 'Log' @{ Msg = 'DHCP listener active on UDP 67' }
} catch { Emit 'Log' @{ Msg = "DHCP listener NOT active: $($_.Exception.Message)" }; $sock = $null }

$swArp = [Diagnostics.Stopwatch]::StartNew(); $swSweep = [Diagnostics.Stopwatch]::StartNew()
$first = $true; $buf = New-Object byte[] 1500
while (-not $Sync.Stop) {
    try {
        if ($sock) {
            while ($sock.Available -gt 0) {
                $len = $sock.Receive($buf)
                try { Parse-Dhcp $buf $len } catch { Emit 'Log' @{ Msg = "dhcp parse: $($_.Exception.Message)" } }
            }
        }
        if ($first -or $swArp.ElapsedMilliseconds -ge 3000) {
            $swArp.Restart()
            $net = Get-Net
            if ($net) {
                Emit 'Net' @{ Ip = $net.Ip; Gateway = $net.Gateway; Mac = $net.Mac }
                if ($net.Gateway) {
                    $pg = New-Object Net.NetworkInformation.Ping
                    try { $r = $pg.Send($net.Gateway, 800); Emit 'RouterPing' @{ Ms = $(if ($r.Status -eq 'Success') { [int]$r.RoundtripTime } else { $null }) } }
                    catch { Emit 'RouterPing' @{ Ms = $null } }
                    $pg.Dispose()
                }
                $pi = New-Object Net.NetworkInformation.Ping
                try { $r = $pi.Send('1.1.1.1', 800); Emit 'InetPing' @{ Ms = $(if ($r.Status -eq 'Success') { [int]$r.RoundtripTime } else { $null }) } }
                catch { Emit 'InetPing' @{ Ms = $null } }
                $pi.Dispose()
                if ($first -or $swSweep.ElapsedMilliseconds -ge 20000) { $swSweep.Restart(); Sweep $net.Ip }
                Poll-Arp $net
            } else { Emit 'RouterPing' @{ Ms = $null } }
            $first = $false
        }
    } catch { Emit 'Log' @{ Msg = "loop: $($_.Exception.Message)" } }
    Start-Sleep -Milliseconds 200
}
if ($sock) { $sock.Close() }
'@
function Start-Scanner {
    try {
        $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'MTA'; $rs.Open()
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        [void]$ps.AddScript($ScanScript).AddArgument($Sync)
        $script:ScanPs = $ps; $script:ScanHandle = $ps.BeginInvoke(); $script:ScanStarted = [DateTime]::UtcNow
        Write-Log 'scanner started'
    } catch { Write-Log "scanner start failed: $_" }
}

# ================================================================ PART 3: alert popup + voice
$PopW = 320; $PopH = 280
$script:PopHits = New-Object System.Collections.ArrayList
$script:PopHover = ''; $script:PopDev = $null; $script:PopKind = 'new'
$script:PopShownAt = Get-Date; $script:PopT0 = Get-Date; $script:PopLoc = New-Object Drawing.Point(0, 0)
$script:LastAlertAt = [datetime]::MinValue
$script:Frames = @(); $script:Delays = @()
$script:Mp = $null; $script:VoiceActive = $false; $script:VoiceStart = Get-Date

# ---- placeholder assets (only created when missing; replace with your own files any time)
function New-PlaceholderGif([string]$path) {
    $S = 180
    $bmp = New-Object Drawing.Bitmap($S, $S, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'; $g.Clear([Drawing.Color]::Transparent)
    $navy  = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(30, 70, 170))
    $blue  = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(70, 150, 255))
    $belly = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(225, 240, 255))
    $white = [Drawing.Brushes]::White; $black = [Drawing.Brushes]::Black
    $g.FillEllipse($navy, 50, 158, 34, 18); $g.FillEllipse($navy, 96, 158, 34, 18)
    $g.FillEllipse($blue, 28, 56, 124, 112)
    $pen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(30, 70, 170), 4); $g.DrawEllipse($pen, 28, 56, 124, 112)
    $g.FillEllipse($belly, 58, 108, 64, 54)
    $g.FillEllipse($white, 55, 80, 28, 32); $g.FillEllipse($white, 97, 80, 28, 32)
    $g.FillEllipse($black, 66, 92, 10, 15); $g.FillEllipse($black, 104, 92, 10, 15)
    $sm = New-Object Drawing.Pen([Drawing.Color]::FromArgb(30, 70, 170), 3); $sm.StartCap = 'Round'; $sm.EndCap = 'Round'
    $g.DrawArc($sm, 70, 112, 40, 22, 20, 140)
    $g.FillPie($navy, 34, 36, 112, 76, 180, 180)                 # guard cap
    $g.FillRectangle($navy, 30, 70, 120, 7)
    $wp = New-Object Drawing.Pen([Drawing.Color]::FromArgb(0, 210, 255), 3); $wp.StartCap = 'Round'; $wp.EndCap = 'Round'
    foreach ($r in 9, 17, 25) { $g.DrawArc($wp, (90 - $r), (30 - $r), (2 * $r), (2 * $r), 225, 90) }
    $g.FillEllipse((New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(0, 210, 255))), 86, 28, 8, 8)
    $g.Dispose()
    # GDI+ drops GIF transparency, so write the GIF with WPF's encoder (keeps a transparent background)
    $rect = New-Object Drawing.Rectangle(0, 0, $S, $S)
    $bd = $bmp.LockBits($rect, 'ReadOnly', [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $bytes = New-Object byte[] ($bd.Stride * $S)
    [Runtime.InteropServices.Marshal]::Copy($bd.Scan0, $bytes, 0, $bytes.Length)
    $stride = $bd.Stride; $bmp.UnlockBits($bd); $bmp.Dispose()
    $src = [Windows.Media.Imaging.BitmapSource]::Create($S, $S, 96, 96, [Windows.Media.PixelFormats]::Bgra32, $null, $bytes, $stride)
    $enc = New-Object Windows.Media.Imaging.GifBitmapEncoder
    $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($src))
    $fs = [IO.File]::Create($path); try { $enc.Save($fs) } finally { $fs.Dispose() }
}
function New-PlaceholderVoice([string]$path, [string]$text) {
    Add-Type -AssemblyName System.Speech
    $s = New-Object System.Speech.Synthesis.SpeechSynthesizer
    try { $s.SetOutputToWaveFile($path); $s.Speak($text) } finally { $s.Dispose() }
}
function Ensure-Assets {
    $gif = Join-Path $AssetDir 'micro.gif'
    if (-not (Test-Path $gif)) { try { New-PlaceholderGif $gif; Write-Log 'created placeholder micro.gif' } catch { Write-Log "placeholder gif: $_" } }
    $clips = @{ 'new-device' = 'Hey! A new device just joined your Wi-Fi. Is it yours?'
                'slow-wifi'  = 'Your Wi-Fi is running slow right now.'
                'fast-wifi'  = 'Your Wi-Fi is nice and fast!' }
    foreach ($k in $clips.Keys) {
        if (-not (Test-Path (Join-Path $AssetDir "$k.mp3")) -and -not (Test-Path (Join-Path $AssetDir "$k.wav"))) {
            try { New-PlaceholderVoice (Join-Path $AssetDir "$k.wav") $clips[$k]; Write-Log "created placeholder $k.wav" } catch { Write-Log "placeholder voice $k : $_" }
        }
    }
}

# ---- mascot frames (GIF, animated or not)
function Load-Mascot {
    $p = Join-Path $AssetDir ("{0}.gif" -f $Settings.Character)
    if (-not (Test-Path $p)) { $p = Join-Path $AssetDir 'micro.gif' }
    if (-not (Test-Path $p)) { return }
    $img = $null
    try {
        $img = [Drawing.Image]::FromFile($p)
        $dim = New-Object Drawing.Imaging.FrameDimension($img.FrameDimensionsList[0])
        $n = [math]::Min(80, $img.GetFrameCount($dim)); $frames = @(); $delays = @()
        $dl = $null; try { $dl = $img.GetPropertyItem(0x5100).Value } catch {}
        for ($i = 0; $i -lt $n; $i++) {
            [void]$img.SelectActiveFrame($dim, $i)
            $frames += (New-Object Drawing.Bitmap($img))
            $ms = 100; if ($dl -and $dl.Length -ge 4 * ($i + 1)) { $ms = [BitConverter]::ToInt32($dl, 4 * $i) * 10 }
            if ($ms -lt 40) { $ms = 100 }; $delays += $ms
        }
        $script:Frames = $frames; $script:Delays = $delays
    } catch { Write-Log "mascot load: $_" }
    finally { if ($img) { $img.Dispose() } }
}
function Get-MascotFrame([double]$ms) {
    $n = $script:Frames.Count
    if ($n -eq 0) { return $null }
    if ($n -eq 1) { return $script:Frames[0] }
    $total = 0; foreach ($d in $script:Delays) { $total += $d }
    $t = $ms % $total; $acc = 0
    for ($i = 0; $i -lt $n; $i++) { $acc += $script:Delays[$i]; if ($t -lt $acc) { return $script:Frames[$i] } }
    return $script:Frames[0]
}

# ---- voice (MediaPlayer). mp3 preferred, wav accepted. Part 6 adds the real loudness envelope.
function Get-VoiceFile([string]$kind) {
    $c = [string]$Settings.Character
    $names = @(); if ($c -and $c -ne 'micro') { $names += "$c-$kind" }; $names += $kind
    foreach ($n in $names) { foreach ($e in 'mp3', 'wav') { $p = Join-Path $AssetDir "$n.$e"; if (Test-Path $p) { return $p } } }
    return $null
}
$script:ForceVoice = $false; $script:Env = @{}; $script:CurEnv = $null
function Play-Voice([string]$kind) {
    if (-not $Settings.Voice -and -not $script:ForceVoice) { return }
    $p = Get-VoiceFile $kind; if (-not $p) { return }
    try {
        if (-not $script:Mp) {
            $script:Mp = New-Object System.Windows.Media.MediaPlayer
            $script:Mp.Add_MediaEnded({ $script:VoiceActive = $false })
            $script:Mp.Add_MediaFailed({ $script:VoiceActive = $false; Write-Log 'voice playback failed' })
        }
        $script:CurEnv = $script:Env[$p]
        $script:Mp.Open((New-Object Uri($p))); $script:Mp.Volume = 1.0; $script:Mp.Play()
        $script:VoiceActive = $true; $script:VoiceStart = Get-Date
    } catch { Write-Log "voice: $_" }
}
function Stop-Voice { try { if ($script:Mp) { $script:Mp.Stop() } } catch {}; $script:VoiceActive = $false }
function Get-VoiceLevel {      # 0..1 -> how hard Micro bounces (real loudness envelope when we have one)
    if (-not $script:VoiceActive) { return 0.0 }
    $t = ((Get-Date) - $script:VoiceStart).TotalSeconds
    try { $pos = $script:Mp.Position.TotalSeconds; if ($pos -gt 0.02) { $t = $pos } } catch {}
    $env = $script:CurEnv
    if ($env -and $env.Length -gt 1) {
        $x = $t / 0.04; $i = [int][math]::Floor($x)
        if ($i -ge $env.Length) { if ($t -gt ($env.Length * 0.04 + 0.5)) { $script:VoiceActive = $false }; return 0.0 }
        $b = if ($i + 1 -lt $env.Length) { $env[$i + 1] } else { 0.0 }
        return [math]::Min(1.0, [math]::Max(0.0, $env[$i] + ($b - $env[$i]) * ($x - $i)))
    }
    if ($t -gt 15) { $script:VoiceActive = $false; return 0.0 }       # no envelope: built-in rhythm
    return [math]::Min(1.0, [math]::Abs([math]::Sin($t * 14)) * (0.55 + 0.45 * [math]::Sin($t * 4.3)))
}

# ---- popup window
$pop = New-Object AlphaForm
$pop.FormBorderStyle = 'None'; $pop.StartPosition = 'Manual'; $pop.ShowInTaskbar = $false; $pop.TopMost = $true
$pop.Size = New-Object Drawing.Size($PopW, $PopH)
$animTimer = New-Object Windows.Forms.Timer; $animTimer.Interval = 40

function Get-PopupLocation {
    $b = $form.Bounds
    $wa = [Windows.Forms.Screen]::FromRectangle($b).WorkingArea
    $x = if ($Settings.Corner -like '*Left') { $b.Left } else { $b.Right - $PopW }
    $y = if ($Settings.Corner -like 'Top*') { $b.Bottom + 6 } else { $b.Top - $PopH - 6 }
    $x = [math]::Max($wa.Left, [math]::Min($wa.Right - $PopW, $x))
    $y = [math]::Max($wa.Top,  [math]::Min($wa.Bottom - $PopH, $y))
    New-Object Drawing.Point($x, $y)
}
function Draw-PopButton($g, [string]$name, [int]$x, [int]$y, [int]$w, [int]$h, [string]$text, [bool]$primary) {
    $hot = ($script:PopHover -eq $name)
    $c = if ($primary) { if ($hot) { [Drawing.Color]::FromArgb(110, 180, 255) } else { $cAccent } } else { if ($hot) { $cCardHot } else { $cCard } }
    $b = New-Object Drawing.SolidBrush($c); $p = New-RoundRect $x $y $w $h 9; $g.FillPath($b, $p); $p.Dispose(); $b.Dispose()
    $tb = if ($primary) { [Drawing.Brushes]::Black } else { $sbText }
    $g.DrawString($text, $fMid, $tb, (New-Object Drawing.RectangleF($x, $y, $w, $h)), $center)
    [void]$script:PopHits.Add([pscustomobject]@{ Name = $name; Rect = (New-Object Drawing.Rectangle($x, $y, $w, $h)) })
}
function Render-Popup {
    $bmp = New-Object Drawing.Bitmap($PopW, $PopH, [Drawing.Imaging.PixelFormat]::Format32bppPArgb)
    $g = [Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'; $g.InterpolationMode = 'HighQualityBicubic'
        $g.Clear([Drawing.Color]::Transparent)
        $script:PopHits.Clear()
        $t = ((Get-Date) - $script:PopT0).TotalSeconds
        $lvl = Get-VoiceLevel
        $cardTop = 124
        # dark card
        $path = New-RoundRect 4 $cardTop ($PopW - 8) ($PopH - $cardTop - 4) 16
        $cb = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(246, 24, 28, 38)); $g.FillPath($cb, $path)
        $bp = New-Object Drawing.Pen([Drawing.Color]::FromArgb(120, 80, 160, 255), 1.5); $g.DrawPath($bp, $path)
        $path.Dispose(); $cb.Dispose(); $bp.Dispose()
        Draw-PopButton $g 'x' ($PopW - 34) ($cardTop + 8) 24 24 ([string][char]0x2715) $false      # close the popup
        # Micro, standing on the card: scale + shake follow the voice
        $fr = Get-MascotFrame ($t * 1000)
        if ($fr) {
            $mh = 106.0; $mw = $mh * $fr.Width / $fr.Height
            $s = 1 + 0.17 * $lvl; $bob = [math]::Sin($t * 3) * 1.5
            $rot = [math]::Sin($t * 52) * 5 * $lvl; $dx = [math]::Sin($t * 31) * 4 * $lvl
            $st = $g.Save()
            $g.TranslateTransform([single]($PopW / 2 + $dx), [single]($cardTop + 12 + $bob))
            $g.RotateTransform([single]$rot); $g.ScaleTransform([single]$s, [single]$s)
            $g.DrawImage($fr, [single](-$mw / 2), [single](-$mh), [single]$mw, [single]$mh)
            $g.Restore($st)
        }
        $by = $PopH - 4 - 16 - 34
        if ($script:PopKind -in 'slow', 'good', 'manual') {
            # ---- speed result
            $r = $script:PopRes; $m = [double]$r.Mbps; $ok = ($r.Status -eq 'ok')
            $col = if (-not $ok) { $cWarn } elseif ($m -lt $Settings.SlowLimit) { $cBad } elseif ($m -ge $Settings.GoodLimit) { $cOk } else { $cWarn }
            $title = if ($r.Status -eq 'refused') { 'Speed test was refused' }
                     elseif ($r.Status -eq 'failed') { 'Speed test failed' }
                     elseif ($m -lt $Settings.SlowLimit) { 'Your Wi-Fi is slow!' }
                     elseif ($m -ge $Settings.GoodLimit) { 'Your Wi-Fi is fast!' }
                     else { 'Speed test result' }
            $g.DrawString($title, $fBig, $sbText, (New-Object Drawing.RectangleF(18, ($cardTop + 12), ($PopW - 36), 24)), $sfEll)
            $cb2 = New-Object Drawing.SolidBrush($col)
            if ($ok) {
                $num = '{0:N1}' -f $m
                $nw = $g.MeasureString($num, $fHuge).Width - 10; $uw = 46
                $x0 = ($PopW - ($nw + $uw)) / 2
                $g.DrawString($num, $fHuge, $cb2, [single]$x0, [single]($cardTop + 32))
                $g.DrawString('Mbps', $fBig, $sbDim, [single]($x0 + $nw), [single]($cardTop + 54))
                $sub = "Download speed.  Slow below $($Settings.SlowLimit), good from $($Settings.GoodLimit) Mbps."
            } elseif ($r.Status -eq 'refused') {
                $g.DrawString('Refused', $fHuge, $cb2, (New-Object Drawing.RectangleF(0, ($cardTop + 32), $PopW, 50)), $center)
                $sub = "Server said no (HTTP $($r.Http)). Not a slow Wi-Fi."
            } else {
                $g.DrawString('No result', $fHuge, $cb2, (New-Object Drawing.RectangleF(0, ($cardTop + 32), $PopW, 50)), $center)
                $sub = 'Could not reach the test server over Wi-Fi. Check that Wi-Fi is connected and has internet.'
            }
            $cb2.Dispose()
            $g.DrawString($sub, $fSmall, $sbDim, (New-Object Drawing.RectangleF(18, ($cardTop + 88), ($PopW - 36), 32)))
            Draw-PopButton $g 'again' 18  $by 96 34 'Test again' $true
            Draw-PopButton $g 'full'  118 $by 96 34 'Full test'  $true
            Draw-PopButton $g 'ok'    224 $by 78 34 'OK' $false
        } else {
            # ---- device alert
            $d = $script:PopDev
            $title = if ($script:PopKind -eq 'new') { 'New device on your Wi-Fi!' } else { 'Unknown device is back!' }
            $g.DrawString($title, $fBig, $sbText, (New-Object Drawing.RectangleF(18, ($cardTop + 14), ($PopW - 36), 24)), $sfEll)
            $g.DrawString("IP  $($d.Ip)", $fMid, $sbText, (New-Object Drawing.RectangleF(18, ($cardTop + 44), ($PopW - 36), 18)), $sfEll)
            $calls = if ($d.Hostname) { "Calls itself: $($d.Hostname)" } else { 'Did not announce a name' }
            $g.DrawString($calls, $fMid, $sbDim, (New-Object Drawing.RectangleF(18, ($cardTop + 64), ($PopW - 36), 18)), $sfEll)
            if ($d.Private) {
                $wb = New-Object Drawing.SolidBrush($cWarn)
                $g.DrawString('Private MAC (phone privacy feature)', $fSmall, $wb, 18, ($cardTop + 84)); $wb.Dispose()
            }
            Draw-PopButton $g 'mine'  18  $by 136 34 "It's mine" $true
            Draw-PopButton $g 'block' 166 $by 136 34 'Block...' $false
        }
    } finally { $g.Dispose() }
    $bmp
}
function Update-Popup {
    if (((Get-Date) - $script:PopShownAt).TotalSeconds -ge 20) { Hide-Popup; return }
    $bmp = Render-Popup
    try { $pop.SetBitmap($bmp, $script:PopLoc.X, $script:PopLoc.Y) } finally { $bmp.Dispose() }
}
function Hide-Popup { $animTimer.Stop(); $pop.Hide(); Stop-Voice }
function Show-DevicePopup($dev, [string]$kind) {
    $script:PopDev = $dev; $script:PopKind = $kind
    $script:PopT0 = Get-Date; $script:PopShownAt = Get-Date; $script:LastAlertAt = Get-Date
    $script:PopLoc = Get-PopupLocation; $pop.Location = $script:PopLoc
    if (-not $pop.Visible) { $pop.Show() }
    Update-Popup; $animTimer.Start()
    Play-Voice 'new-device'
    Write-Log "popup shown ($kind) $($dev.Mac)"
}
function Pump-Alerts {          # one popup at a time, at least 10 s apart
    for ($i = $script:Pending.Count - 1; $i -ge 0; $i--) { $pd = $script:Pending[$i].Dev; if ($pd.Name -or $pd.AutoName) { $script:Pending.RemoveAt($i) } }
    if ($pop.Visible -or $script:AlertQueue.Count -eq 0) { return }
    if (((Get-Date) - $script:LastAlertAt).TotalSeconds -lt 10) { return }
    while ($script:AlertQueue.Count -gt 0) {
        $a = $script:AlertQueue[0]; $script:AlertQueue.RemoveAt(0)
        if ($a.Kind -eq 'slow' -or $a.Kind -eq 'good') { Show-SpeedPopup $a.Res $a.Kind; break }
        $d = $a.Dev
        if ($d.Name -or $d.AutoName) { continue }            # got named meanwhile
        Show-DevicePopup $d $a.Kind; break
    }
}
function Test-Alert {
    $d = [pscustomobject]@{ Mac = 'aa:bb:cc:00:11:22'; Ip = '192.168.50.250'; Hostname = 'Test-iPhone'; Private = $true }
    Show-DevicePopup $d 'new'
}
function Show-BlockHelp($d) {
    if (-not (Require-Admin)) { return }
    try { [Windows.Forms.Clipboard]::SetText([string]$d.Mac) } catch { Write-Log "clipboard: $_" }
    $gw = if ($State.Gateway) { "http://$($State.Gateway)" } else { 'your router admin page' }
    $msg = "The MAC address $($d.Mac) was copied to your clipboard.`r`n`r`n" +
           "A PC cannot remove a device from Wi-Fi - only your router can. To block it:`r`n" +
           "  1. Open your router's app, or its admin page ($gw).`r`n" +
           "  2. Find 'Connected devices', 'Access control' or 'MAC filter'.`r`n" +
           "  3. Find this MAC (or IP $($d.Ip)) and choose Block / Deny.`r`n`r`n" +
           "If you still don't recognise it, change your Wi-Fi password too."
    [void](Show-Msg $msg 'Block this device' 'OK' 'Information' 'Button1')
}
function Get-PopHit($pt) { foreach ($h in $script:PopHits) { if ($h.Rect.Contains($pt)) { return $h.Name } }; return '' }
$pop.Add_MouseMove({ param($s, $e) $n = Get-PopHit $e.Location; if ($n -ne $script:PopHover) { $script:PopHover = $n; $pop.Cursor = $(if ($n) { [Windows.Forms.Cursors]::Hand } else { [Windows.Forms.Cursors]::Default }) } })
$pop.Add_MouseUp({
    param($s, $e)
    try {
        if ($e.Button -ne 'Left') { return }
        $d = $script:PopDev
        switch (Get-PopHit $e.Location) {
            'mine'  { Hide-Popup
                      if ($Devices.ContainsKey([string]$d.Mac)) { Edit-DeviceName ([string]$d.Mac) }
                      else { [void](Show-Msg 'This was only a test alert.' 'Micro' 'OK' 'Information' 'Button1') } }
            'block' { Hide-Popup; Show-BlockHelp $d }
            'again' { Hide-Popup; Start-SpeedTest $true }
            'full'  { Hide-Popup; Start-FullTest }
            'ok'    { Hide-Popup }
            'x'     { Hide-Popup }
        }
    } catch { Write-Log "popup click: $_" }
})
$animTimer.Add_Tick({ try { Update-Popup } catch { Write-Log "popup anim: $_" } })

# ================================================================ PART 4: speed test + speed alerts
$fHuge = New-Object Drawing.Font('Segoe UI Semibold', 28)
$SpeedCsv = Join-Path $DataDir 'speed-log.csv'
$State.InetPing = $null; $State.Testing = $false; $State.SpeedText = '--'
$script:PopRes = $null
$script:TestPs = $null; $script:TestHandle = $null; $script:TestStarted = [DateTime]::UtcNow
$script:SlowPending = $false; $script:ConfirmAt = [datetime]::MaxValue
$script:WasSlow = $false; $script:LastSlowAlert = [datetime]::MinValue
$script:NextAuto = (Get-Date).AddSeconds(45)

# show the last result on the tile after a restart
try {
    if (Test-Path $SpeedCsv) {
        $last = Get-Content $SpeedCsv -Tail 1
        $c = $last -split ','
        if ($c.Count -ge 3 -and $c[2] -eq 'ok') { $State.SpeedText = ('{0:N1} Mbps' -f [double]::Parse($c[1], [Globalization.CultureInfo]::InvariantCulture)) }
    }
} catch {}

$SpeedScript = @'
param($Sync, $Ip)
$q = $Sync.Queue
function Emit([string]$type, [hashtable]$d) { $d.Type = $type; $q.Enqueue([pscustomobject]$d) }
$curl = Join-Path $env:SystemRoot 'System32\curl.exe'
$status = 'failed'; $mbps = 0.0; $http = 0; $used = 0
if (-not (Test-Path $curl)) { Emit 'Log' @{ Msg = 'curl.exe not found' } }
else {
    foreach ($sz in 25000000, 10000000, 5000000, 2000000) {
        $url = "https://speed.cloudflare.com/__down?bytes=$sz"
        $a = @('-s', '-o', 'NUL', '--max-time', '25', '--connect-timeout', '8', '-w', '%{http_code} %{size_download} %{time_total} %{time_starttransfer}')
        if ($Ip) { $a += @('--interface', $Ip) }
        $a += $url
        $out = ''
        try { $out = (& $curl @a 2>$null | Out-String).Trim() } catch { Emit 'Log' @{ Msg = "curl failed: $($_.Exception.Message)" } }
        $p = $out -split '\s+'
        $http = 0; $size = 0.0; $tt = 0.0; $st = 0.0
        if ($p.Count -ge 4) { try { $http = [int]$p[0]; $size = [double]$p[1]; $tt = [double]$p[2]; $st = [double]$p[3] } catch {} }
        $used = $sz
        if ($http -eq 403) { $status = 'refused'; continue }            # refused, try a smaller file
        if ($http -eq 200 -and $size -gt 0 -and $tt -gt 0) {
            $t = $tt - $st; if ($t -lt 0.15) { $t = $tt }
            $mbps = $size * 8 / $t / 1e6; $status = 'ok'; break
        }
        $status = 'failed'; break                                       # network problem: smaller files will not help
    }
}
Emit 'Speed' @{ Mbps = [math]::Round($mbps, 2); Status = $status; Http = $http; SizeMB = [math]::Round($used / 1e6); At = (Get-Date) }
'@

function Start-SpeedTest([bool]$Manual = $false) {
    if ($State.Testing) { if ($Manual) { Show-Stub 'A speed test is already running.' }; return }
    if ($State.FullRunning) { if ($Manual) { Show-Stub 'A Full test is running - wait for it to finish.' } else { $script:NextAuto = (Get-Date).AddMinutes(2) }; return }
    $ip = $State.LocalIp
    if (-not $ip) {
        if ($Manual) { Show-Stub 'No Wi-Fi connection found.' } else { $script:NextAuto = (Get-Date).AddMinutes(1) }
        return
    }
    try {
        $State.Testing = $true; $script:TestManual = $Manual; $script:TestStarted = [DateTime]::UtcNow
        if (-not $Manual -and -not $script:SlowPending) { $script:NextAuto = (Get-Date).AddMinutes([int]$Settings.IntervalMin) }
        $script:ConfirmAt = [datetime]::MaxValue
        $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'MTA'; $rs.Open()
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        [void]$ps.AddScript($SpeedScript).AddArgument($Sync).AddArgument($ip)
        $script:TestPs = $ps; $script:TestHandle = $ps.BeginInvoke()
        Write-Log ("speed test started ({0}) via {1}" -f $(if ($Manual) { 'manual' } else { 'auto' }), $ip)
        $form.Invalidate()
    } catch { $State.Testing = $false; Write-Log "speed start failed: $_" }
}

function Handle-Speed($ev) {
    $State.Testing = $false
    $manual = [bool]$script:TestManual
    $res = [pscustomobject]@{ Mbps = [double]$ev.Mbps; Status = [string]$ev.Status; Http = $ev.Http; SizeMB = $ev.SizeMB }
    $State.SpeedText = switch ($res.Status) { 'ok' { '{0:N1} Mbps' -f $res.Mbps } 'refused' { 'refused' } default { 'failed' } }
    Write-Log ("speed result: {0} {1} Mbps (http {2}, {3} MB, {4})" -f $res.Status, $res.Mbps, $res.Http, $res.SizeMB, $(if ($manual) { 'manual' } else { 'auto' }))
    try {
        if (-not (Test-Path $SpeedCsv)) { Add-Content $SpeedCsv 'time,mbps,status,size_mb,manual' }
        Add-Content $SpeedCsv ('{0:yyyy-MM-dd HH:mm:ss},{1},{2},{3},{4}' -f (Get-Date), $res.Mbps.ToString([Globalization.CultureInfo]::InvariantCulture), $res.Status, $res.SizeMB, $manual)
    } catch {}

    if ($manual) {                                   # manual test: ALWAYS show the result
        $script:AlertQueue.Clear()
        Show-SpeedPopup $res 'manual'
        if ($res.Status -eq 'ok') { if ($res.Mbps -lt $Settings.SlowLimit) { $script:WasSlow = $true } elseif ($res.Mbps -ge $Settings.GoodLimit) { $script:WasSlow = $false } }
        $script:SlowPending = $false
        return
    }
    if ($res.Status -ne 'ok') { $script:SlowPending = $false; return }    # refused / failed: never call it "slow"

    $m = $res.Mbps
    if ($m -lt $Settings.SlowLimit) {
        if (-not $script:SlowPending) {              # first slow result: confirm in 20 s
            $script:SlowPending = $true; $script:ConfirmAt = (Get-Date).AddSeconds(20)
            Write-Log 'slow once - re-testing in 20 s'
            return
        }
        $script:SlowPending = $false; $script:WasSlow = $true      # slow twice in a row
        if (((Get-Date) - $script:LastSlowAlert).TotalMinutes -ge 15) {
            $script:LastSlowAlert = Get-Date
            [void]$script:AlertQueue.Add(@{ Kind = 'slow'; Res = $res })
            Write-Log 'SLOW alert queued'
        } else { Write-Log 'slow twice, but a slow alert was sent less than 15 min ago' }
        return
    }
    $script:SlowPending = $false
    if ($m -ge $Settings.GoodLimit) {
        $today = (Get-Date).ToString('yyyy-MM-dd')
        $alert = switch ([string]$Settings.GoodMode) {
            'always' { $true }
            'off'    { $false }
            default  { $script:WasSlow -or ($Settings.LastGoodDate -ne $today) }     # once a day, or when recovering from slow
        }
        if ($alert) {
            [void]$script:AlertQueue.Add(@{ Kind = 'good'; Res = $res })
            $Settings.LastGoodDate = $today; Save-Settings
            Write-Log 'GOOD alert queued'
        }
        $script:WasSlow = $false
    }
    # between the two limits: stay quiet
}

function Pump-SpeedSchedule {
    if ($script:TestHandle -and $script:TestHandle.IsCompleted) {
        try { $script:TestPs.Runspace.Dispose(); $script:TestPs.Dispose() } catch {}
        $script:TestPs = $null; $script:TestHandle = $null
    }
    if ($State.Testing) {
        if (([DateTime]::UtcNow - $script:TestStarted).TotalSeconds -gt 120) { $State.Testing = $false; Write-Log 'speed test watchdog reset' }
        return
    }
    $now = Get-Date
    if ($script:SlowPending) { if ($now -ge $script:ConfirmAt) { Start-SpeedTest $false }; return }
    if ($now -ge $script:NextAuto) { Start-SpeedTest $false }
}

function Show-SpeedPopup($res, [string]$kind) {
    $script:PopRes = $res; $script:PopKind = $kind; $script:PopDev = $null
    $script:PopT0 = Get-Date; $script:PopShownAt = Get-Date; $script:LastAlertAt = Get-Date
    $script:PopLoc = Get-PopupLocation; $pop.Location = $script:PopLoc
    if (-not $pop.Visible) { $pop.Show() }
    Update-Popup; $animTimer.Start()
    if ($res.Status -eq 'ok') {
        if ($res.Mbps -lt $Settings.SlowLimit) { Play-Voice 'slow-wifi' }
        elseif ($res.Mbps -ge $Settings.GoodLimit) { Play-Voice 'fast-wifi' }
    }
    Write-Log "speed popup shown ($kind)"
}

# ================================================================ PART 5: DNS Shield
$State.DnsShield = $null; $State.DnsStatus = 'checking'; $State.DnsSub = 'Checking...'; $State.DnsReport = 'No result yet.'
$State.DnsChecking = $false; $State.DnsAdapters = @()
$script:DnsPs = $null; $script:DnsHandle = $null; $script:DnsStarted = [DateTime]::UtcNow
$script:DnsPrev = ''; $script:DnsManual = $false; $script:NextDns = (Get-Date).AddSeconds(12); $script:DnsRecheckAt = [datetime]::MaxValue
$DnsLog = Join-Path $DataDir 'dns-fix.log'

$DnsScript = @'
param($Sync)
$q = $Sync.Queue
function Emit([string]$type, [hashtable]$d) { $d.Type = $type; $q.Enqueue([pscustomobject]$d) }
function Norm([string]$s) { try { [Net.IPAddress]::Parse(($s -replace '%.*$', '')).ToString() } catch { $s } }
$placeholders = @('fec0:0:0:ffff::1', 'fec0:0:0:ffff::2', 'fec0:0:0:ffff::3')      # Windows placeholders - ignore
$known = @{}
function Add-Known([string]$prov, [bool]$filter, [string[]]$ips) { foreach ($i in $ips) { $known[(Norm $i)] = @{ Provider = $prov; Filter = $filter } } }
Add-Known 'Cloudflare (scam/malware filter)' $true  @('1.1.1.2', '1.0.0.2', '1.1.1.3', '1.0.0.3', '2606:4700:4700::1112', '2606:4700:4700::1002', '2606:4700:4700::1113', '2606:4700:4700::1003')
Add-Known 'Cloudflare (plain, no filter)'    $false @('1.1.1.1', '1.0.0.1', '2606:4700:4700::1111', '2606:4700:4700::1001')
Add-Known 'Quad9 (malware filter)'           $true  @('9.9.9.9', '149.112.112.112', '9.9.9.11', '149.112.112.11', '2620:fe::fe', '2620:fe::9', '2620:fe::11', '2620:fe::fe:11')
Add-Known 'Quad9 (plain, no filter)'         $false @('9.9.9.10', '149.112.112.10', '2620:fe::10', '2620:fe::fe:10')
Add-Known 'AdGuard (filtering)'              $true  @('94.140.14.14', '94.140.15.15', '94.140.14.15', '94.140.15.16', '2a10:50c0::ad1:ff', '2a10:50c0::ad2:ff', '2a10:50c0::bad1:ff', '2a10:50c0::bad2:ff')
Add-Known 'AdGuard (non-filtering)'          $false @('94.140.14.140', '94.140.14.141', '94.140.15.140', '94.140.15.141')
Add-Known 'CleanBrowsing (filtering)'        $true  @('185.228.168.9', '185.228.169.9', '185.228.168.10', '185.228.169.11', '185.228.168.168', '185.228.169.168', '2a0d:2a00:1::2', '2a0d:2a00:2::2', '2a0d:2a00:1::1', '2a0d:2a00:2::1')
Add-Known 'OpenDNS FamilyShield (filtering)' $true  @('208.67.222.123', '208.67.220.123')
Add-Known 'OpenDNS (plain, no filter)'       $false @('208.67.222.222', '208.67.220.220')
Add-Known 'Google (plain, no filter)'        $false @('8.8.8.8', '8.8.4.4', '2001:4860:4860::8888', '2001:4860:4860::8844')

function Test-Private([string]$s) {
    $ip = [Net.IPAddress]::Parse($s); $b = $ip.GetAddressBytes()
    if ($ip.AddressFamily -eq 'InterNetwork') {
        return ($b[0] -eq 10 -or ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or ($b[0] -eq 192 -and $b[1] -eq 168) -or
                ($b[0] -eq 169 -and $b[1] -eq 254) -or ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127) -or $b[0] -eq 127)
    }
    return ($ip.IsIPv6LinkLocal -or $ip.IsIPv6SiteLocal -or (($b[0] -band 0xFE) -eq 0xFC) -or $ip.Equals([Net.IPAddress]::IPv6Loopback))
}
function Find-Typo([string]$s) {                 # public IPv4 that is one octet away from a famous resolver
    if ($s.Contains(':')) { return '' }
    $o = $s.Split('.'); $hits = @()
    foreach ($k in $known.Keys) {
        if ($k.Contains(':')) { continue }
        $p = $k.Split('.'); $d = 0
        for ($i = 0; $i -lt 4; $i++) { if ($o[$i] -ne $p[$i]) { $d++ } }
        if ($d -eq 1) { $hits += $k }
    }
    if ($hits.Count) { return (($hits | Sort-Object | Select-Object -First 2) -join ' or ') }
    return ''
}

$out = @()
foreach ($a in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })) {
    $v6 = @(Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike 'fe80*' })
    $gw = @(Get-NetRoute -InterfaceIndex $a.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | ForEach-Object { $_.NextHop })
    $addrs = @(Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ErrorAction SilentlyContinue | ForEach-Object { $_.ServerAddresses } | Where-Object { $_ } | Select-Object -Unique)
    $servers = @()
    foreach ($s in $addrs) {
        if ($placeholders -contains $s) { continue }
        $n = Norm $s; $kind = 'plain'; $prov = ''; $typo = ''
        if ($known.ContainsKey($n)) {
            $prov = $known[$n].Provider; $kind = $(if ($known[$n].Filter) { 'filter' } else { 'plain' })
        } else {
            $isR = $false
            if (Test-Private $n) { $isR = $true }
            elseif ($gw -contains $n) { $isR = $true }
            elseif ($n.Contains(':')) {
                $b = [Net.IPAddress]::Parse($n).GetAddressBytes()
                foreach ($x in $v6) { $xb = [Net.IPAddress]::Parse($x.IPAddress).GetAddressBytes(); if (-not (Compare-Object $b[0..7] $xb[0..7])) { $isR = $true } }
            }
            if ($isR) { $kind = 'router'; $prov = 'Router / local DNS' } else { $kind = 'plain'; $prov = 'Public DNS (not a known filter)'; $typo = Find-Typo $n }
        }
        $ok = $false; $ms = $null
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try { $r = Resolve-DnsName -Name example.com -Type A -Server $n -DnsOnly -QuickTimeout -ErrorAction Stop; if ($r) { $ok = $true } } catch {}
        $sw.Stop(); if ($ok) { $ms = [int]$sw.ElapsedMilliseconds }
        $servers += [pscustomobject]@{ Ip = $n; Kind = $kind; Provider = $prov; Answers = $ok; Ms = $ms; Typo = $typo }
    }
    $out += [pscustomobject]@{ Name = [string]$a.Name; Servers = $servers }
}
Emit 'Dns' @{ Adapters = $out }
'@

function Start-DnsCheck([bool]$Manual = $false) {
    if ($State.DnsChecking) { return }
    try {
        $State.DnsChecking = $true; $script:DnsManual = $Manual; $script:DnsStarted = [DateTime]::UtcNow
        $script:NextDns = (Get-Date).AddMinutes(10)
        $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'MTA'; $rs.Open()
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        [void]$ps.AddScript($DnsScript).AddArgument($Sync)
        $script:DnsPs = $ps; $script:DnsHandle = $ps.BeginInvoke()
        if ($Manual) { $State.DnsSub = 'Checking...' ; $form.Invalidate() }
    } catch { $State.DnsChecking = $false; Write-Log "dns check start failed: $_" }
}

function Handle-Dns($ev) {
    $State.DnsChecking = $false
    $adapters = @($ev.Adapters); $rank = @{ on = 0; partial = 1; broken = 2; off = 3 }
    $worst = 'on'; $worstName = ''; $provs = @(); $typos = @(); $lines = New-Object System.Collections.ArrayList
    foreach ($a in $adapters) {
        $sv = @($a.Servers)
        $nF = @($sv | Where-Object { $_.Kind -eq 'filter' }).Count
        $nO = $sv.Count - $nF
        $anyF = @($sv | Where-Object { $_.Kind -eq 'filter' -and $_.Answers }).Count
        $st = if ($nF -eq 0) { 'off' } elseif ($nO -gt 0) { 'partial' } elseif ($anyF -eq 0) { 'broken' } else { 'on' }
        if ($rank[$st] -gt $rank[$worst]) { $worst = $st; $worstName = $a.Name }
        $head = switch ($st) { 'on' { 'scam filter ON' } 'partial' { 'PARTLY protected - a non-filtering DNS is also listed' } 'broken' { 'filter set, but NOT answering' } default { 'NOT protected' } }
        [void]$lines.Add("$($a.Name)  -  $head")
        if ($sv.Count -eq 0) { [void]$lines.Add('    (no DNS servers found)') }
        foreach ($s in $sv) {
            $ans = if ($s.Answers) { "answers ($($s.Ms) ms)" } else { 'NO ANSWER' }
            $t = if ($s.Typo) { "   <-- looks like a typo of $($s.Typo)" } else { '' }
            [void]$lines.Add(("    {0,-26} {1}   {2}{3}" -f $s.Ip, $s.Provider, $ans, $t))
            if ($s.Kind -eq 'filter') { $provs += ($s.Provider -replace ' \(.*$', '') }
            if ($s.Typo) { $typos += $s.Ip }
        }
    }
    if ($adapters.Count -eq 0) { $worst = 'none'; [void]$lines.Add('No connected network adapter found.') }
    $State.DnsStatus = $worst; $State.DnsAdapters = $adapters
    $State.DnsShield = ($worst -eq 'on')
    $State.DnsReport = ("DNS Shield check  {0:HH:mm:ss}`r`n`r`n" -f (Get-Date)) + ($lines -join "`r`n")
    $sub = switch ($worst) {
        'on'      { 'Scam filter active (' + (($provs | Select-Object -Unique) -join ', ') + ')' }
        'partial' { "$worstName also uses a non-filter DNS" }
        'broken'  { "$worstName filter DNS not answering" }
        'off'     { "$worstName has no scam filter" }
        default   { 'No connected adapter found' }
    }
    if ($typos.Count) { $sub = 'Typo? ' + ($typos -join ', ') }
    $State.DnsSub = $sub
    Write-Log "dns check: $worst ($sub)"
    if ($script:DnsPrev -eq 'on' -and $worst -ne 'on') {
        try { $tray.BalloonTipTitle = 'DNS Shield turned OFF'; $tray.BalloonTipText = "Your scam protection is no longer active. $sub"; $tray.ShowBalloonTip(8000) } catch {}
        Write-Log 'ALERT dns protection lost'
    } elseif ($script:DnsManual) {
        Show-Stub ("DNS Shield: " + $sub)
    }
    $script:DnsPrev = $worst
}

function Pump-DnsSchedule {
    if ($script:DnsHandle -and $script:DnsHandle.IsCompleted) {
        try { $script:DnsPs.Runspace.Dispose(); $script:DnsPs.Dispose() } catch {}
        $script:DnsPs = $null; $script:DnsHandle = $null
    }
    if ($State.DnsChecking) {
        if (([DateTime]::UtcNow - $script:DnsStarted).TotalSeconds -gt 90) { $State.DnsChecking = $false; Write-Log 'dns watchdog reset' }
        return
    }
    $now = Get-Date
    if ($now -ge $script:DnsRecheckAt) { $script:DnsRecheckAt = [datetime]::MaxValue; Start-DnsCheck $true; return }
    if ($now -ge $script:NextDns) { Start-DnsCheck $false }
}

function Invoke-DnsChange([string]$mode) {       # 'fix' or 'auto' - only ever called after the user clicked and confirmed
    if (-not (Require-Admin)) { return }
    $names = (@($State.DnsAdapters | ForEach-Object { $_.Name }) -join ', '); if (-not $names) { $names = 'your connected adapters' }
    if ($mode -eq 'fix') {
        $q = "Set Cloudflare's scam filter as DNS on: $names ?`r`n`r`nDNS servers: 1.1.1.2 and 1.0.0.2 (blocks known scam, phishing and malware sites).`r`nWindows will now ask for administrator permission."
        $body = "Get-NetAdapter -Physical | Where-Object { `$_.Status -eq 'Up' } | ForEach-Object { Set-DnsClientServerAddress -InterfaceIndex `$_.ifIndex -ServerAddresses @('1.1.1.2','1.0.0.2','2606:4700:4700::1112','2606:4700:4700::1002') }"
    } else {
        $q = "Go back to automatic DNS (from your router / provider) on: $names ?`r`n`r`nThis removes the scam filter. Windows will ask for administrator permission."
        $body = "Get-NetAdapter -Physical | Where-Object { `$_.Status -eq 'Up' } | ForEach-Object { Set-DnsClientServerAddress -InterfaceIndex `$_.ifIndex -ResetServerAddresses }"
    }
    $r = Show-Msg $q 'DNS Shield' 'YesNo' 'Question' 'Button2'
    if ($r -ne 'Yes') { return }
    $cmd = "try { $body; Clear-DnsClientCache; ('{0:s} OK $mode' -f (Get-Date)) | Add-Content -Path '$DnsLog' } catch { ('{0:s} ERROR $mode ' -f (Get-Date)) + `$_ | Add-Content -Path '$DnsLog' }"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc
        Write-Log "dns $mode requested (admin prompt approved)"
        $State.DnsSub = 'Applying...'; $script:DnsRecheckAt = (Get-Date).AddSeconds(8)
    } catch { Write-Log "dns $mode cancelled or failed: $($_.Exception.Message)"; Show-Stub 'Cancelled - nothing was changed.' }
}

function Show-DnsDetails {
    if ($script:DialogOpen) { return }
    $script:DialogOpen = $true
    try {
        $f = New-Object Windows.Forms.Form
        $f.Text = 'DNS Shield'; $f.ClientSize = New-Object Drawing.Size(640, 400); $f.StartPosition = 'CenterScreen'
        $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.TopMost = $true
        $tb = New-Object Windows.Forms.TextBox; $tb.Multiline = $true; $tb.ReadOnly = $true; $tb.ScrollBars = 'Vertical'
        $tb.Font = New-Object Drawing.Font('Consolas', 9); $tb.SetBounds(12, 12, 616, 330); $tb.Text = $State.DnsReport + "`r`n`r`nA green 'ON' needs every connected adapter to use only scam-filtering DNS."
        $bRe = New-Object Windows.Forms.Button; $bRe.Text = 'Re-check now'; $bRe.SetBounds(12, 356, 110, 30); $bRe.DialogResult = 'Retry'
        $bFx = New-Object Windows.Forms.Button; $bFx.Text = 'Fix it (admin)...'; $bFx.SetBounds(132, 356, 130, 30); $bFx.DialogResult = 'Yes'
        $bAu = New-Object Windows.Forms.Button; $bAu.Text = 'Back to automatic...'; $bAu.SetBounds(272, 356, 140, 30); $bAu.DialogResult = 'No'
        $bCl = New-Object Windows.Forms.Button; $bCl.Text = 'Close'; $bCl.SetBounds(538, 356, 90, 30); $bCl.DialogResult = 'Cancel'
        $f.CancelButton = $bCl; $f.Controls.AddRange(@($tb, $bRe, $bFx, $bAu, $bCl))
        $res = $f.ShowDialog(); $f.Dispose()
        $script:DialogOpen = $false
        switch ($res) { 'Retry' { Start-DnsCheck $true } 'Yes' { Invoke-DnsChange 'fix' } 'No' { Invoke-DnsChange 'auto' } }
    } catch { Write-Log "dns dialog: $_" }
    finally { $script:DialogOpen = $false }
}

function Draw-DnsCard($g) {
    Fill-Card $g 14 334 272 44 $sbCard
    $st = [string]$State.DnsStatus
    $col = switch ($st) { 'on' { $cOk } 'partial' { $cWarn } 'checking' { $cDim } default { $cBad } }
    $word = switch ($st) { 'on' { 'ON' } 'partial' { 'PARTLY ON' } 'broken' { 'NOT ANSWERING' } 'off' { 'OFF' } 'none' { '--' } default { '...' } }
    $needFix = ($st -in 'off', 'partial', 'broken')
    if ($needFix) { Draw-Button $g 'dnsfix' 228 345 50 24 'Fix it' $fSmall }      # its hit is added first, so it wins over the card
    Add-Hit 'dnsinfo' 14 334 272 44
    $b = New-Object Drawing.SolidBrush($col); $g.FillEllipse($b, 22, 343, 9, 9)
    $g.DrawString("DNS Shield: $word", $fMid, $b, 36, 338); $b.Dispose()
    $subW = if ($needFix) { 206 } else { 256 }
    $g.DrawString([string]$State.DnsSub, $fSmall, $sbDim, (New-Object Drawing.RectangleF(22, 358, $subW, 16)), $sfEll)
}

# ================================================================ PART 6: voice envelope + characters
# Message box that always appears on top (a hidden topmost owner window does the trick).
function Show-Msg([string]$text, [string]$title, [string]$buttons = 'OK', [string]$icon = 'Information', [string]$default = 'Button1') {
    $o = New-Object Windows.Forms.Form
    try {
        $o.TopMost = $true; $o.ShowInTaskbar = $false; $o.FormBorderStyle = 'None'; $o.StartPosition = 'Manual'
        $o.Size = New-Object Drawing.Size(1, 1); $o.Location = New-Object Drawing.Point(-32000, -32000); $o.Show()
        return [Windows.Forms.MessageBox]::Show($o, $text, $title, $buttons, $icon, $default)
    } finally { $o.Dispose() }
}

function Find-Ffmpeg {
    foreach ($p in @((Join-Path $AssetDir 'ffmpeg.exe'), (Join-Path $Root 'ffmpeg.exe'))) { if (Test-Path $p) { return $p } }
    $c = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    return $null
}
function Read-WavRms([string]$path) {            # plain 16-bit PCM wav: no ffmpeg needed
    $b = [IO.File]::ReadAllBytes($path)
    if ($b.Length -lt 44 -or [Text.Encoding]::ASCII.GetString($b, 0, 4) -ne 'RIFF') { return $null }
    $pos = 12; $rate = 0; $ch = 0; $bits = 0; $fmt = 0
    while ($pos + 8 -le $b.Length) {
        $id = [Text.Encoding]::ASCII.GetString($b, $pos, 4); $size = [BitConverter]::ToInt32($b, $pos + 4)
        if ($id -eq 'fmt ') { $fmt = [BitConverter]::ToInt16($b, $pos + 8); $ch = [BitConverter]::ToInt16($b, $pos + 10); $rate = [BitConverter]::ToInt32($b, $pos + 12); $bits = [BitConverter]::ToInt16($b, $pos + 22) }
        elseif ($id -eq 'data') {
            if ($fmt -ne 1 -or $bits -ne 16 -or $rate -le 0 -or $ch -le 0) { return $null }
            $cnt = [math]::Min($size, $b.Length - $pos - 8)
            return [SndHelper]::Rms($b, $pos + 8, $cnt, [int]($rate * 0.04) * $ch)
        }
        $pos += 8 + $size + ($size % 2)
    }
    return $null
}
function Read-FfmpegRms([string]$ff, [string]$path) {     # mp3 (or anything else) through ffmpeg -> 8 kHz mono PCM
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $ff; $psi.Arguments = "-v error -nostdin -i `"$path`" -ac 1 -ar 8000 -f s16le -"
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    $ms = New-Object IO.MemoryStream
    $p.StandardOutput.BaseStream.CopyTo($ms)
    [void]$p.WaitForExit(20000)
    $b = $ms.ToArray()
    if ($b.Length -lt 640) { return $null }
    return [SndHelper]::Rms($b, 0, $b.Length, 320)         # 320 samples @ 8 kHz = 40 ms
}
function Get-EnvelopeFor([string]$clip) {
    $cache = [IO.Path]::ChangeExtension($clip, 'env.json')            # new-device.mp3 -> new-device.env.json
    try {
        if ((Test-Path $cache) -and ((Get-Item $cache).LastWriteTime -ge (Get-Item $clip).LastWriteTime)) {
            $j = Get-Content $cache -Raw | ConvertFrom-Json
            if ($j.values.Count -gt 1) { return [double[]]@($j.values) }
        }
    } catch {}
    $raw = $null
    try {
        if ([IO.Path]::GetExtension($clip).ToLower() -eq '.wav') { $raw = Read-WavRms $clip }
        if (-not $raw) { $ff = Find-Ffmpeg; if ($ff) { $raw = Read-FfmpegRms $ff $clip } }
    } catch { Write-Log "envelope $clip : $_" }
    if (-not $raw -or $raw.Length -lt 2) { return $null }
    $sorted = [double[]]$raw.Clone(); [Array]::Sort($sorted)
    $p95 = $sorted[[int](0.95 * ($sorted.Length - 1))]; if ($p95 -lt 1) { $p95 = 1 }
    $vals = New-Object 'double[]' $raw.Length
    for ($i = 0; $i -lt $raw.Length; $i++) { $vals[$i] = [math]::Round([math]::Pow([math]::Min(1.0, $raw[$i] / $p95), 0.9), 2) }
    try { (@{ step = 40; values = $vals } | ConvertTo-Json -Compress) | Set-Content -Path $cache -Encoding UTF8 } catch { Write-Log "envelope cache write: $_" }
    return $vals
}
function Ensure-Envelopes {
    $sw = [Diagnostics.Stopwatch]::StartNew(); $n = 0
    $stems = @{}
    foreach ($f in Get-ChildItem $AssetDir -File -ErrorAction SilentlyContinue) {
        $ext = $f.Extension.ToLower()
        if ($ext -ne '.mp3' -and $ext -ne '.wav') { continue }
        $stem = $f.BaseName.ToLower()
        if (-not $stems.ContainsKey($stem) -or $ext -eq '.mp3') { $stems[$stem] = $f.FullName }      # same rule as Get-VoiceFile: mp3 wins
    }
    foreach ($clip in $stems.Values) {
        $e = Get-EnvelopeFor $clip
        if ($e) { $script:Env[$clip] = $e; $n++ }
    }
    $ff = $(if (Find-Ffmpeg) { 'ffmpeg found' } else { 'no ffmpeg (wav clips still get real envelopes; mp3 use the built-in rhythm)' })
    Write-Log ("envelopes ready for {0} of {1} clips in {2} ms; {3}" -f $n, $stems.Count, $sw.ElapsedMilliseconds, $ff)
}

# ---- extra characters: <name>.gif (+ <name>-new-device / slow-wifi / fast-wifi .mp3)
function Get-Characters {
    $l = @('micro')
    foreach ($f in Get-ChildItem $AssetDir -Filter *.gif -File -ErrorAction SilentlyContinue) {
        $n = $f.BaseName.ToLower(); if ($n -ne 'micro' -and $l -notcontains $n) { $l += $n }
    }
    return $l
}
function Set-Character([string]$name) {
    $Settings.Character = $name; Save-Settings; Load-Mascot
    Write-Log "character: $name"
}
function Preview-Character {
    $script:ForceVoice = $true
    try { Test-Alert } finally { $script:ForceVoice = $false }
}
$script:miChar = $null
function Build-CharacterMenu {
    $script:miChar = New-Object Windows.Forms.ToolStripMenuItem('Alert character')
    foreach ($c in Get-Characters) {
        $it = New-Object Windows.Forms.ToolStripMenuItem($c); $it.Tag = $c; $it.Checked = ($c -eq $Settings.Character)
        $it.Add_Click({
            param($s, $e)
            Set-Character ([string]$s.Tag)
            foreach ($x in $script:miChar.DropDownItems) { if ($x.Tag) { $x.Checked = ([string]$x.Tag -eq [string]$s.Tag) } }
        })
        [void]$script:miChar.DropDownItems.Add($it)
    }
    [void]$script:miChar.DropDownItems.Add((New-Object Windows.Forms.ToolStripSeparator))
    $pv = New-Object Windows.Forms.ToolStripMenuItem('Preview (plays the voice)')
    $pv.Add_Click({ Preview-Character })
    [void]$script:miChar.DropDownItems.Add($pv)
    [void]$menu.Items.Add($script:miChar)
}

# ================================================================ PART 7: Full test + dashboard (WiFi-Analyzer.ps1)
$State.FullRunning = $false; $script:FullProc = $null; $script:FullStarted = Get-Date
function Start-FullTest {
    if (-not (Require-Admin)) { return }
    if ($State.FullRunning) { Show-Stub 'A Full test is already running.'; return }
    if ($State.Testing) { Show-Stub 'Wait for the quick speed test to finish first.'; return }
    $ps1 = Join-Path $Root 'WiFi-Analyzer.ps1'
    if (-not (Test-Path $ps1)) { Show-Stub 'WiFi-Analyzer.ps1 was not found next to the widget.'; return }
    try {
        $script:FullProc = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru -ArgumentList '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$ps1`""
        $State.FullRunning = $true; $script:FullStarted = Get-Date
        Write-Log 'full test started'
        Show-Stub 'Full test started (about 1 minute). The dashboard opens when it is done.'
        $form.Invalidate()
    } catch { Write-Log "full test start failed: $_"; Show-Stub 'Could not start the Full test.' }
}
function Open-Dashboard {
    if (-not (Require-Admin)) { return }
    $h = Join-Path $DataDir 'dashboard.html'
    if (Test-Path $h) { try { Start-Process $h } catch { Write-Log "open dashboard: $_" } }
    else { Show-Stub 'No report yet - running a Full test first.'; Start-FullTest }
}
function Pump-FullTest {
    if (-not $script:FullProc) { return }
    if ($script:FullProc.HasExited) {
        $code = $script:FullProc.ExitCode; $script:FullProc = $null; $State.FullRunning = $false
        Write-Log "full test finished (exit $code)"
        if ($code -eq 0) { Show-Stub 'Full test finished - dashboard opened in your browser.' }
        elseif ($code -eq 2) { Show-Stub 'A Full test was already running.' }
        else { Show-Stub 'Full test did not finish - see MonitorData\micro.log.' }
        $form.Invalidate()
    } elseif (((Get-Date) - $script:FullStarted).TotalMinutes -gt 6) {
        try { $script:FullProc.Kill() } catch {}
        Write-Log 'full test killed after 6 minutes'
    }
}

# ================================================================ PART 8: admin / user view, Settings, Start with Windows
# ---- admin view: a PIN-protected mode. User view = watch + alerts + speed tests. Admin view = change things.
# (A PIN guards against casual changes on a shared PC; it is not protection against someone who can edit the files.)
$script:AdminUntil = [datetime]::MinValue; $script:PinFails = 0; $script:PinLockUntil = [datetime]::MinValue
function Test-AdminActive { return ($script:AdminUntil -gt (Get-Date)) }
function Lock-Admin { $script:AdminUntil = [datetime]::MinValue; Write-Log 'admin view locked'; $form.Invalidate() }
function Get-PinHash([string]$pin, [string]$salt) {
    $sha = [Security.Cryptography.SHA256]::Create()
    ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($salt + ':' + $pin)))) -replace '-', ''
}
function Show-PinDialog([string]$mode) {       # mode: 'enter' or 'create' -> returns the PIN or $null
    $f = New-Object Windows.Forms.Form
    try {
        $f.Text = $(if ($mode -eq 'create') { 'Create admin PIN' } else { 'Admin PIN' }); $f.FormBorderStyle = 'FixedDialog'
        $f.StartPosition = 'CenterScreen'; $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.TopMost = $true
        $f.ClientSize = New-Object Drawing.Size(320, $(if ($mode -eq 'create') { 190 } else { 130 }))
        $l = New-Object Windows.Forms.Label; $l.SetBounds(14, 12, 292, 40)
        $l.Text = $(if ($mode -eq 'create') { 'Choose an admin PIN (4 to 12 characters). It unlocks Settings, DNS changes, naming devices and the Full test.' } else { 'Enter the admin PIN to unlock the admin view.' })
        $t1 = New-Object Windows.Forms.TextBox; $t1.UseSystemPasswordChar = $true; $t1.MaxLength = 12; $t1.SetBounds(14, 58, 292, 24)
        $t2 = New-Object Windows.Forms.TextBox; $t2.UseSystemPasswordChar = $true; $t2.MaxLength = 12; $t2.SetBounds(14, 90, 292, 24)
        $ok = New-Object Windows.Forms.Button; $ok.Text = 'OK'; $ok.DialogResult = 'OK'
        $cn = New-Object Windows.Forms.Button; $cn.Text = 'Cancel'; $cn.DialogResult = 'Cancel'
        $by = $(if ($mode -eq 'create') { 146 } else { 90 })
        $ok.SetBounds(146, $by, 78, 28); $cn.SetBounds(230, $by, 78, 28)
        $f.AcceptButton = $ok; $f.CancelButton = $cn
        $f.Controls.AddRange(@($l, $t1)); if ($mode -eq 'create') { $f.Controls.Add($t2) }
        $f.Controls.AddRange(@($ok, $cn))
        $f.Add_Shown({ $t1.Focus() })
        if ($f.ShowDialog() -ne 'OK') { return $null }
        if ($mode -eq 'create') {
            if ($t1.Text.Length -lt 4) { [void](Show-Msg 'The PIN needs at least 4 characters.' 'Admin PIN' 'OK' 'Warning'); return $null }
            if ($t1.Text -ne $t2.Text) { [void](Show-Msg 'The two PINs do not match.' 'Admin PIN' 'OK' 'Warning'); return $null }
        }
        return $t1.Text
    } finally { $f.Dispose() }
}
function Require-Admin {
    if (Test-AdminActive) { $script:AdminUntil = (Get-Date).AddMinutes(10); return $true }
    if ($script:DialogOpen) { return $false }
    if (-not $Settings.AdminPinHash) {                       # first time: create the PIN
        $pin = Show-PinDialog 'create'; if (-not $pin) { return $false }
        $salt = [guid]::NewGuid().ToString('N')
        $Settings.AdminPinSalt = $salt; $Settings.AdminPinHash = (Get-PinHash $pin $salt); Save-Settings
        Write-Log 'admin PIN created'
    } else {
        if ((Get-Date) -lt $script:PinLockUntil) { Show-Stub 'Too many wrong PINs - try again in a moment.'; return $false }
        $pin = Show-PinDialog 'enter'; if ($null -eq $pin) { return $false }
        if ((Get-PinHash $pin $Settings.AdminPinSalt) -ne $Settings.AdminPinHash) {
            $script:PinFails++
            if ($script:PinFails -ge 5) { $script:PinFails = 0; $script:PinLockUntil = (Get-Date).AddSeconds(30) }
            Write-Log 'admin PIN wrong'; [void](Show-Msg 'Wrong PIN.' 'Admin PIN' 'OK' 'Warning'); return $false
        }
    }
    $script:PinFails = 0; $script:AdminUntil = (Get-Date).AddMinutes(10)
    Write-Log 'admin view unlocked (auto-locks after 10 minutes without admin actions)'
    $form.Invalidate(); return $true
}
function Change-AdminPin {
    if (-not (Require-Admin)) { return }
    $pin = Show-PinDialog 'create'; if (-not $pin) { return }
    $salt = [guid]::NewGuid().ToString('N')
    $Settings.AdminPinSalt = $salt; $Settings.AdminPinHash = (Get-PinHash $pin $salt); Save-Settings
    Write-Log 'admin PIN changed'; Show-Stub 'Admin PIN changed.'
}

# ---- Start with Windows: a shortcut in the user's Startup folder (no admin, no registry)
function Get-StartupLinkPath { Join-Path ([Environment]::GetFolderPath('Startup')) 'Micro Wi-Fi Guard.lnk' }
function Set-Startup([bool]$on) {
    $p = Get-StartupLinkPath
    try {
        if ($on) {
            $sh = New-Object -ComObject WScript.Shell; $l = $sh.CreateShortcut($p)
            $l.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $l.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $Root 'Micro-WiFi.ps1') + '" -AtLogon'
            $l.WorkingDirectory = $Root; $l.WindowStyle = 7; $l.Description = 'Micro Wi-Fi Guard'
            $ico = Join-Path $Root 'micro.ico'; if (Test-Path $ico) { $l.IconLocation = $ico }
            $l.Save()
        } elseif (Test-Path $p) { Remove-Item $p -Force }
    } catch { Write-Log "startup shortcut: $_" }
}
function Ensure-Startup {
    if ($Settings.StartWithWindows) {
        Set-Startup $true
        if (-not $Settings.StartupNotified) {
            $Settings.StartupNotified = $true; Save-Settings
            Show-Stub 'Micro will start with Windows (45 s after sign-in). You can turn this off in Settings.'
        }
    } else { Set-Startup $false }
}

# ---- Settings window
$SettingsDefaults = [ordered]@{ SlowLimit = 10; GoodLimit = 50; GoodMode = 'daily'; IntervalMin = 30; Voice = $false; AlertMode = 'button'; Character = 'micro'; StartWithWindows = $true }
function Show-Settings {
    if ($script:DialogOpen) { return }
    $script:DialogOpen = $true
    $origChar = [string]$Settings.Character
    try {
        $f = New-Object Windows.Forms.Form
        $f.Text = 'Micro - Settings'; $f.ClientSize = New-Object Drawing.Size(440, 452); $f.StartPosition = 'CenterScreen'
        $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.TopMost = $true
        function Lbl([string]$t, [int]$y) { $x = New-Object Windows.Forms.Label; $x.Text = $t; $x.SetBounds(16, $y + 4, 200, 20); $f.Controls.Add($x) }
        $modes = @(@('daily', 'Once a day, or when speed recovers from slow'), @('always', 'Every time it is good'), @('off', 'Off'))
        $y = 16
        Lbl 'Slow limit (Mbps)' $y
        $nSlow = New-Object Windows.Forms.NumericUpDown; $nSlow.SetBounds(230, $y, 90, 24); $nSlow.Minimum = 1; $nSlow.Maximum = 10000; $f.Controls.Add($nSlow); $y += 36
        Lbl 'Good limit (Mbps, higher)' $y
        $nGood = New-Object Windows.Forms.NumericUpDown; $nGood.SetBounds(230, $y, 90, 24); $nGood.Minimum = 2; $nGood.Maximum = 10000; $f.Controls.Add($nGood); $y += 36
        Lbl 'Good-speed alert' $y
        $cbMode = New-Object Windows.Forms.ComboBox; $cbMode.DropDownStyle = 'DropDownList'; $cbMode.SetBounds(16, ($y + 24), 404, 24)
        foreach ($m in $modes) { [void]$cbMode.Items.Add($m[1]) }; $f.Controls.Add($cbMode); $y += 62
        Lbl 'Check speed every (minutes)' $y
        $cbInt = New-Object Windows.Forms.ComboBox; $cbInt.DropDownStyle = 'DropDownList'; $cbInt.SetBounds(230, $y, 90, 24)
        foreach ($m in 15, 30, 60, 120) { [void]$cbInt.Items.Add([string]$m) }; $f.Controls.Add($cbInt); $y += 36
        Lbl 'Alert character' $y
        $cbChar = New-Object Windows.Forms.ComboBox; $cbChar.DropDownStyle = 'DropDownList'; $cbChar.SetBounds(230, $y, 110, 24)
        foreach ($c in (Get-Characters)) { [void]$cbChar.Items.Add($c) }; $f.Controls.Add($cbChar)
        $bPrev = New-Object Windows.Forms.Button; $bPrev.Text = 'Preview'; $bPrev.SetBounds(346, ($y - 1), 74, 26); $f.Controls.Add($bPrev); $y += 40
        $ckVoice = New-Object Windows.Forms.CheckBox; $ckVoice.Text = 'Voice alerts (Micro talks)'; $ckVoice.SetBounds(16, $y, 404, 22); $f.Controls.Add($ckVoice); $y += 28
        $ckAuto = New-Object Windows.Forms.CheckBox; $ckAuto.Text = 'Pop up automatically for new devices (otherwise use the blue button)'; $ckAuto.SetBounds(16, $y, 410, 22); $f.Controls.Add($ckAuto); $y += 28
        $ckStart = New-Object Windows.Forms.CheckBox; $ckStart.Text = 'Start with Windows'; $ckStart.SetBounds(16, $y, 404, 22); $f.Controls.Add($ckStart); $y += 40
        $bReset = New-Object Windows.Forms.Button; $bReset.Text = 'Reset to default'; $bReset.SetBounds(16, $y, 120, 30); $f.Controls.Add($bReset)
        $bSave = New-Object Windows.Forms.Button; $bSave.Text = 'Save'; $bSave.SetBounds(266, $y, 74, 30); $f.Controls.Add($bSave)
        $bCancel = New-Object Windows.Forms.Button; $bCancel.Text = 'Cancel'; $bCancel.SetBounds(346, $y, 74, 30); $bCancel.DialogResult = 'Cancel'; $f.Controls.Add($bCancel)
        $f.CancelButton = $bCancel

        $load = {
            param($v)
            $nSlow.Value = [math]::Max($nSlow.Minimum, [math]::Min($nSlow.Maximum, [decimal]$v.SlowLimit))
            $nGood.Value = [math]::Max($nGood.Minimum, [math]::Min($nGood.Maximum, [decimal]$v.GoodLimit))
            $i = 0; for ($k = 0; $k -lt $modes.Count; $k++) { if ($modes[$k][0] -eq [string]$v.GoodMode) { $i = $k } }; $cbMode.SelectedIndex = $i
            $j = $cbInt.Items.IndexOf([string]$v.IntervalMin); $cbInt.SelectedIndex = $(if ($j -ge 0) { $j } else { 1 })
            $j = $cbChar.Items.IndexOf([string]$v.Character); $cbChar.SelectedIndex = $(if ($j -ge 0) { $j } else { 0 })
            $ckVoice.Checked = [bool]$v.Voice; $ckAuto.Checked = ([string]$v.AlertMode -eq 'popup'); $ckStart.Checked = [bool]$v.StartWithWindows
        }
        & $load $Settings
        $bReset.Add_Click({ & $load $SettingsDefaults })
        $bPrev.Add_Click({
            $Settings.Character = [string]$cbChar.SelectedItem; Load-Mascot; Preview-Character
        })
        $bSave.Add_Click({
            if ($nGood.Value -le $nSlow.Value) { [void](Show-Msg 'The good limit must be higher than the slow limit.' 'Settings' 'OK' 'Warning'); return }
            $f.DialogResult = 'OK'; $f.Close()
        })
        $res = $f.ShowDialog()
        if ($res -eq 'OK') {
            $Settings.SlowLimit = [int]$nSlow.Value; $Settings.GoodLimit = [int]$nGood.Value
            $Settings.GoodMode = $modes[$cbMode.SelectedIndex][0]
            $Settings.IntervalMin = [int]$cbInt.SelectedItem
            $miVoice.Checked = $ckVoice.Checked                      # their handlers save and stop voice
            $miAuto.Checked = $ckAuto.Checked
            $Settings.Character = [string]$cbChar.SelectedItem; Load-Mascot
            foreach ($x in $script:miChar.DropDownItems) { if ($x.Tag) { $x.Checked = ([string]$x.Tag -eq $Settings.Character) } }
            $Settings.StartWithWindows = $ckStart.Checked; Set-Startup $Settings.StartWithWindows
            $script:NextAuto = (Get-Date).AddMinutes([int]$Settings.IntervalMin)
            Save-Settings; $form.Invalidate()
            Write-Log ("settings saved (slow {0}, good {1}, mode {2}, every {3} min)" -f $Settings.SlowLimit, $Settings.GoodLimit, $Settings.GoodMode, $Settings.IntervalMin)
        } else { $Settings.Character = $origChar; Load-Mascot }
        $f.Dispose()
    } catch { Write-Log "settings dialog: $_" }
    finally { $script:DialogOpen = $false }
}

# ---------------------------------------------------------------- form
$W = 300; $HCompact = 190; $HExpanded = 626; $Margin = 12
$form = New-Object WidgetForm
$form.FormBorderStyle = 'None'
$form.StartPosition   = 'Manual'
$form.ShowInTaskbar   = $false
$form.TopMost         = $true
$form.BackColor       = [Drawing.Color]::FromArgb(24, 28, 38)
$form.Size            = New-Object Drawing.Size($W, $(if ($Settings.Expanded) { $HExpanded } else { $HCompact }))

function Set-Rounded {
    $p = New-Object Drawing.Drawing2D.GraphicsPath
    $r = 18; $d = $r * 2
    $p.AddArc(0, 0, $d, $d, 180, 90)
    $p.AddArc($form.Width - $d, 0, $d, $d, 270, 90)
    $p.AddArc($form.Width - $d, $form.Height - $d, $d, $d, 0, 90)
    $p.AddArc(0, $form.Height - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    $form.Region = New-Object Drawing.Region($p)
}

function Get-Screen {
    $s = [Windows.Forms.Screen]::AllScreens | Where-Object { $_.DeviceName -eq $Settings.Screen } | Select-Object -First 1
    if ($s) { $s } else { [Windows.Forms.Screen]::PrimaryScreen }
}

function Set-Corner {   # place the form in the saved corner of the saved screen
    $wa = (Get-Screen).WorkingArea
    $x = if ($Settings.Corner -like '*Left')   { $wa.Left + $Margin } else { $wa.Right - $form.Width - $Margin }
    $y = if ($Settings.Corner -like 'Top*')    { $wa.Top + $Margin }  else { $wa.Bottom - $form.Height - $Margin }
    $form.Location = New-Object Drawing.Point($x, $y)
}

function Snap-ToNearestCorner {
    $c = New-Object Drawing.Point(($form.Left + [int]($form.Width / 2)), ($form.Top + [int]($form.Height / 2)))
    $scr = [Windows.Forms.Screen]::FromPoint($c)
    $wa = $scr.WorkingArea
    $vert = if ($c.Y -lt ($wa.Top + $wa.Height / 2)) { 'Top' } else { 'Bottom' }
    $horz = if ($c.X -lt ($wa.Left + $wa.Width / 2)) { 'Left' } else { 'Right' }
    $Settings.Corner = "$vert$horz"; $Settings.Screen = $scr.DeviceName
    Set-Corner; Save-Settings
}

function Set-Expanded([bool]$on) {
    $Settings.Expanded = $on
    $form.Height = if ($on) { $HExpanded } else { $HCompact }
    Set-Rounded; Set-Corner; Save-Settings; $form.Invalidate()
}

function Toggle-Widget {
    if ($form.Visible) { $form.Hide() } else { $form.Show(); Set-Corner }
}

# ---------------------------------------------------------------- painting
$fTitle = New-Object Drawing.Font('Segoe UI Semibold', 10)
$fBig   = New-Object Drawing.Font('Segoe UI Semibold', 12)
$fMid   = New-Object Drawing.Font('Segoe UI', 9)
$fSmall = New-Object Drawing.Font('Segoe UI', 8)
$fSym   = New-Object Drawing.Font('Segoe UI Symbol', 10)
$fGauge = New-Object Drawing.Font('Segoe UI Semibold', 14)
$cText  = [Drawing.Color]::FromArgb(236, 240, 248)
$cDim   = [Drawing.Color]::FromArgb(140, 150, 170)
$cCard  = [Drawing.Color]::FromArgb(36, 42, 56)
$cCardHot = [Drawing.Color]::FromArgb(52, 60, 80)
$cOk    = [Drawing.Color]::FromArgb(70, 200, 120)
$cWarn  = [Drawing.Color]::FromArgb(240, 180, 60)
$cBad   = [Drawing.Color]::FromArgb(235, 80, 80)
$cAccent= [Drawing.Color]::FromArgb(80, 160, 255)
$sbText = New-Object Drawing.SolidBrush($cText)
$sbDim  = New-Object Drawing.SolidBrush($cDim)
$sbCard = New-Object Drawing.SolidBrush($cCard)
$sbCardHot = New-Object Drawing.SolidBrush($cCardHot)
$script:Hits = New-Object System.Collections.ArrayList
$script:Hover = ''

function New-RoundRect([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
    $p = New-Object Drawing.Drawing2D.GraphicsPath
    $d = $r * 2
    $p.AddArc($x, $y, $d, $d, 180, 90); $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90); $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure(); $p
}
function Fill-Card($g, [float]$x, [float]$y, [float]$w, [float]$h, $brush) {
    $p = New-RoundRect $x $y $w $h 8; $g.FillPath($brush, $p); $p.Dispose()
}
function Add-Hit([string]$name, [int]$x, [int]$y, [int]$w, [int]$h) {
    [void]$script:Hits.Add([pscustomobject]@{ Name = $name; Rect = (New-Object Drawing.Rectangle($x, $y, $w, $h)) })
}
$center = New-Object Drawing.StringFormat; $center.Alignment = 'Center'; $center.LineAlignment = 'Center'

function Draw-Button($g, [string]$name, [int]$x, [int]$y, [int]$w, [int]$h, [string]$text, $font) {
    $hot = ($script:Hover -eq $name)
    Fill-Card $g $x $y $w $h $(if ($hot) { $sbCardHot } else { $sbCard })
    $g.DrawString($text, $font, $sbText, (New-Object Drawing.RectangleF($x, $y, $w, $h)), $center)
    Add-Hit $name $x $y $w $h
}

function Draw-Chip($g, [string]$text, [int]$x, [int]$y, [int]$w, [Drawing.Color]$dot) {
    Fill-Card $g $x $y $w 24 $sbCard
    $b = New-Object Drawing.SolidBrush($dot); $g.FillEllipse($b, $x + 8, $y + 9, 7, 7); $b.Dispose()
    $g.DrawString($text, $fSmall, $sbText, ($x + 19), ($y + 4))
}

$form.Add_Paint({
    param($s, $e)
    try {
        $g = $e.Graphics
        $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'ClearTypeGridFit'
        $script:Hits.Clear()
        $exp = [bool]$Settings.Expanded
        $g.Clear($form.BackColor)

        # ---- header
        $dotB = New-Object Drawing.SolidBrush($cAccent); $g.FillEllipse($dotB, 14, 13, 10, 10); $dotB.Dispose()
        $g.DrawString('Micro', $fTitle, $sbText, 30, 7)
        if ($State.FullRunning) { $g.DrawString('Full test...', $fSmall, (New-Object Drawing.SolidBrush($cAccent)), 76, 11) }
        elseif ($State.Testing) { $g.DrawString('Testing...', $fSmall, (New-Object Drawing.SolidBrush($cAccent)), 76, 11) }
        elseif (Test-AdminActive) {
            Fill-Card $g 74 9 46 18 (New-Object Drawing.SolidBrush($cAccent))
            $g.DrawString('ADMIN', $fSmall, [Drawing.Brushes]::Black, (New-Object Drawing.RectangleF(74, 9, 46, 18)), $center)
        }
        $bx = $W - 14 - 24
        Draw-Button $g 'close'    $bx 5 24 26 ([string][char]0x2715) $fSym; $bx -= 26
        Draw-Button $g 'expand'   $bx 5 24 26 $(if ($exp) { [string][char]0x25B4 } else { [string][char]0x25BE }) $fSym; $bx -= 26
        Draw-Button $g 'speed'    $bx 5 24 26 ([string][char]0x26A1) $fSym; $bx -= 26
        Draw-Button $g 'settings' $bx 5 24 26 ([string][char]0x2699) $fSym; $bx -= 26
        Draw-Button $g 'voice'    $bx 5 24 26 ([string][char]0x266A) $fSym; $bx -= 26           # voice on/off
        if ($Settings.Voice) { $vb = New-Object Drawing.SolidBrush($cOk); $g.FillEllipse($vb, ($bx + 26 + 16), 7, 5, 5); $vb.Dispose() }
        else { $vp = New-Object Drawing.Pen($cBad, 2); $g.DrawLine($vp, ($bx + 26 + 5), 26, ($bx + 26 + 19), 10); $vp.Dispose() }
        Draw-Button $g 'minimize' $bx 5 24 26 ([string][char]0x2013) $fSym                     # hide to tray

        # ---- gauge
        $sig = [int]$State.Signal
        $col = if ($sig -ge 60) { $cOk } elseif ($sig -ge 35) { $cWarn } else { $cBad }
        $pen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(50, 58, 76), 7)
        $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
        $g.DrawArc($pen, 18, 46, 62, 62, 135, 270)
        $pen.Color = $col
        if ($sig -gt 0) { $g.DrawArc($pen, 18, 46, 62, 62, 135, [single](270 * $sig / 100)) }
        $pen.Dispose()
        $g.DrawString("$sig%", $fGauge, $sbText, (New-Object Drawing.RectangleF(18, 46, 62, 62)), $center)

        # ---- text block
        $ssid = [string]$State.Ssid; if ($ssid.Length -gt 22) { $ssid = $ssid.Substring(0, 21) + [string][char]0x2026 }
        $g.DrawString($ssid, $fBig, $sbText, 94, 44)
        $bandTxt = if ($State.Band) { "$($State.Band)  $([char]0xB7)  Ch $($State.Channel)" } else { 'No Wi-Fi link' }
        $g.DrawString($bandTxt, $fMid, $sbDim, 94, 68)
        $dl = '{0:N1}' -f $State.Down; $ul = '{0:N1}' -f $State.Up
        $g.DrawString(([string][char]0x2193 + " $dl"), $fBig, (New-Object Drawing.SolidBrush($cOk)), 94, 88)
        $g.DrawString(([string][char]0x2191 + " $ul  Mbps"), $fMid, $sbDim, 175, 92)

        # ---- chips
        $rp = if ($null -eq $State.RouterPing) { 'Router --' } else { "Router $($State.RouterPing) ms" }
        $rpCol = if ($null -eq $State.RouterPing) { $cDim } elseif ($State.RouterPing -lt 30) { $cOk } elseif ($State.RouterPing -lt 100) { $cWarn } else { $cBad }
        Draw-Chip $g $rp 14 122 88 $rpCol
        $np = $script:Pending.Count
        if ($np -gt 0) {            # button: open the waiting new device(s), one at a time
            $hot = ($script:Hover -eq 'newdev')
            Fill-Card $g 106 122 98 24 $(if ($hot) { (New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(130, 190, 255))) } else { (New-Object Drawing.SolidBrush($cAccent)) })
            $g.DrawString("New device ($np)", $fSmall, [Drawing.Brushes]::Black, (New-Object Drawing.RectangleF(106, 122, 98, 24)), $center)
            Add-Hit 'newdev' 106 122 98 24
        } else {
            Draw-Chip $g "Unnamed $($State.Unnamed)" 106 122 98 $(if ($State.Unnamed -gt 0) { $cWarn } else { $cDim })
        }
        $dnsTxt = if ($null -eq $State.DnsShield) { 'DNS --' } elseif ($State.DnsShield) { 'DNS ON' } else { 'DNS OFF' }
        $dnsCol = if ($null -eq $State.DnsShield) { $cDim } elseif ($State.DnsShield) { $cOk } else { $cBad }
        Draw-Chip $g $dnsTxt 208 122 78 $dnsCol

        # ---- expanded area
        if ($exp) {
            # graph
            Fill-Card $g 14 156 272 112 $sbCard
            $g.DrawString('Traffic - last 2 minutes', $fSmall, $sbDim, 22, 160)
            $max = 5.0
            foreach ($v in $DownHist) { if ($v -gt $max) { $max = $v } }
            foreach ($v in $UpHist)   { if ($v -gt $max) { $max = $v } }
            $max *= 1.15
            $gx = 22; $gy = 176; $gw = 256; $gh = 84
            $gp = New-Object Drawing.Pen([Drawing.Color]::FromArgb(48, 56, 74), 1)
            foreach ($f in 0.25, 0.5, 0.75) { $g.DrawLine($gp, $gx, ($gy + $gh * $f), ($gx + $gw), ($gy + $gh * $f)) }
            $gp.Dispose()
            $g.DrawString(('{0:N0} Mbps' -f $max), $fSmall, $sbDim, ($gx + $gw - 54), 160)
            foreach ($series in @(@($DownHist, $cOk), @($UpHist, $cAccent))) {
                $pts = New-Object 'System.Collections.Generic.List[Drawing.PointF]'
                for ($i = 0; $i -lt $Samples; $i++) {
                    $pts.Add((New-Object Drawing.PointF(($gx + $gw * $i / ($Samples - 1)), ($gy + $gh - $gh * [math]::Min(1, $series[0][$i] / $max)))))
                }
                $lp = New-Object Drawing.Pen($series[1], 1.8)
                $g.DrawLines($lp, $pts.ToArray()); $lp.Dispose()
            }
            # tiles (filled in later parts)
            $tw = 86
            $tiles = @(@('Router ping', $(if ($null -eq $State.RouterPing) { '--' } else { "$($State.RouterPing) ms" })), @('Internet ping', $(if ($null -eq $State.InetPing) { '--' } else { "$($State.InetPing) ms" })), @('Last speed test', $State.SpeedText))
            for ($i = 0; $i -lt 3; $i++) {
                $tx = 14 + $i * ($tw + 7)
                Fill-Card $g $tx 276 $tw 50 $sbCard
                $g.DrawString($tiles[$i][0], $fSmall, $sbDim, ($tx + 8), 281)
                $g.DrawString($tiles[$i][1], $fBig, $sbText, ($tx + 8), 297)
            }
            # DNS card
            Draw-DnsCard $g
            # devices
            Draw-DeviceList $g
        }

        # ---- footer
        $fy = $form.Height - 46
        $fw = 86
        Draw-Button $g 'ftest'  14               $fy $fw 32 'Speed test' $fSmall
        Draw-Button $g 'ffull'  (14 + $fw + 7)   $fy $fw 32 'Full test'  $fSmall
        Draw-Button $g 'fdash'  (14 + 2 * ($fw + 7)) $fy $fw 32 'Dashboard' $fSmall
    } catch { Write-Log "paint error: $_" }
})

# ---------------------------------------------------------------- mouse: drag + click
$script:DownPt = $null; $script:StartLoc = $null; $script:Dragging = $false
function Get-HitName($pt) {
    foreach ($h in $script:Hits) { if ($h.Rect.Contains($pt)) { return $h.Name } }
    return ''
}
$form.Add_MouseDown({
    param($s, $e)
    if ($e.Button -eq 'Left') {
        $script:DownPt = [Windows.Forms.Control]::MousePosition
        $script:StartLoc = $form.Location; $script:Dragging = $false
    }
})
$form.Add_MouseMove({
    param($s, $e)
    try {
        if ($script:DownPt -and ($e.Button -eq 'Left')) {
            $p = [Windows.Forms.Control]::MousePosition
            $dx = $p.X - $script:DownPt.X; $dy = $p.Y - $script:DownPt.Y
            if ($script:Dragging -or ([math]::Abs($dx) + [math]::Abs($dy)) -gt 5) {
                $script:Dragging = $true
                $form.Location = New-Object Drawing.Point(($script:StartLoc.X + $dx), ($script:StartLoc.Y + $dy))
            }
        } else {
            $n = Get-HitName $e.Location
            if ($n -ne $script:Hover) { $script:Hover = $n; $form.Cursor = $(if ($n) { [Windows.Forms.Cursors]::Hand } else { [Windows.Forms.Cursors]::Default }); $form.Invalidate() }
        }
    } catch { Write-Log "mousemove: $_" }
})
$form.Add_MouseLeave({ if ($script:Hover) { $script:Hover = ''; $form.Invalidate() } })
$form.Add_MouseUp({
    param($s, $e)
    try {
        if ($e.Button -ne 'Left' -or -not $script:DownPt) { return }
        $was = $script:Dragging; $script:DownPt = $null; $script:Dragging = $false
        if ($was) { Snap-ToNearestCorner; return }
        switch (Get-HitName $e.Location) {
            'close'    { Exit-App }
            'expand'   { Set-Expanded (-not $Settings.Expanded) }
            'settings' { if (Require-Admin) { Show-Settings } }
            'speed'    { Start-SpeedTest $true }
            'ftest'    { Start-SpeedTest $true }
            'ffull'    { Start-FullTest }
            'fdash'    { Open-Dashboard }
            'minimize' { $form.Hide(); Write-Log 'minimized to tray' }
            'voice'    { $miVoice.Checked = -not $miVoice.Checked; $form.Invalidate() }
            'newdev'   { Open-PendingDevice }
            'dnsfix'   { Invoke-DnsChange 'fix' }
            'dnsinfo'  { Show-DnsDetails }
            default    { if ($_ -like 'dev:*') { Edit-DeviceName $_.Substring(4) } }
        }
    } catch { Write-Log "mouseup: $_" }
})

# ---------------------------------------------------------------- tray
function Make-TrayIcon {
    $bmp = New-Object Drawing.Bitmap(32, 32)
    $g = [Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'
    $b = New-Object Drawing.SolidBrush($cAccent); $g.FillEllipse($b, 1, 1, 30, 30)
    $pen = New-Object Drawing.Pen([Drawing.Color]::White, 3)
    foreach ($r in 6, 11, 16) { $g.DrawArc($pen, (16 - $r), (24 - $r), (2 * $r), (2 * $r), 225, 90) }
    $wb = [Drawing.Brushes]::White; $g.FillEllipse($wb, 14, 22, 4, 4)
    $g.Dispose()
    [Drawing.Icon]::FromHandle($bmp.GetHicon())
}
$tray = New-Object Windows.Forms.NotifyIcon
$tray.Icon = Make-TrayIcon; $tray.Text = 'Micro Wi-Fi Guard'; $tray.Visible = $true
$menu = New-Object Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add('Show / hide  (Ctrl+Alt+W)', $null, { Toggle-Widget })
[void]$menu.Items.Add('Speed test',  $null, { Start-SpeedTest $true })
[void]$menu.Items.Add('Settings... (admin)', $null, { if (Require-Admin) { Show-Settings } })
$miAdmin = New-Object Windows.Forms.ToolStripMenuItem('Unlock admin view...')
$miAdmin.Add_Click({ if (Test-AdminActive) { Lock-Admin } else { [void](Require-Admin) } })
[void]$menu.Items.Add($miAdmin)
$miPin = New-Object Windows.Forms.ToolStripMenuItem('Change admin PIN...')
$miPin.Add_Click({ Change-AdminPin })
[void]$menu.Items.Add($miPin)
$menu.Add_Opening({ $miAdmin.Text = $(if (Test-AdminActive) { 'Lock admin view' } else { 'Unlock admin view...' }) })
$miVoice = New-Object Windows.Forms.ToolStripMenuItem('Voice alerts (Micro talks)')
$miVoice.CheckOnClick = $true; $miVoice.Checked = [bool]$Settings.Voice
$miVoice.Add_CheckedChanged({
    $Settings.Voice = [bool]$miVoice.Checked
    if (-not $Settings.Voice) { Stop-Voice }
    Save-Settings; Write-Log ("voice " + $(if ($Settings.Voice) { 'ON' } else { 'OFF' }))
})
[void]$menu.Items.Add($miVoice)
$miAuto = New-Object Windows.Forms.ToolStripMenuItem('New devices: pop up automatically')
$miAuto.CheckOnClick = $true; $miAuto.Checked = ($Settings.AlertMode -eq 'popup')
$miAuto.Add_CheckedChanged({
    $Settings.AlertMode = $(if ($miAuto.Checked) { 'popup' } else { 'button' }); Save-Settings
    Write-Log "alert mode: $($Settings.AlertMode)"
})
[void]$menu.Items.Add($miAuto)
Build-CharacterMenu
[void]$menu.Items.Add('Test new-device alert', $null, { Test-Alert })
[void]$menu.Items.Add('-')
[void]$menu.Items.Add('Exit', $null, { Exit-App })
$tray.ContextMenuStrip = $menu
$tray.Add_MouseClick({ param($s, $e) if ($e.Button -eq 'Left') { Toggle-Widget } })
$tray.Add_BalloonTipClicked({ if ($script:BalloonKind -eq 'device') { $script:BalloonKind = ''; Open-PendingDevice } })

function Show-Stub([string]$msg) {
    $script:BalloonKind = ''; $tray.BalloonTipTitle = 'Micro'; $tray.BalloonTipText = $msg; $tray.ShowBalloonTip(3000)
}
function Exit-App {
    Write-Log 'exit requested'
    try { $timer.Stop(); $animTimer.Stop(); Stop-Voice; $pop.Close() } catch {}
    try { $Sync.Stop = $true; Save-Devices; $script:ScanPs.BeginStop($null, $null) | Out-Null } catch {}
    try { $tray.Visible = $false; $tray.Dispose() } catch {}
    try { $script:Mutex.ReleaseMutex() } catch {}
    [Windows.Forms.Application]::Exit()
}
$form.Add_HotKeyPressed({ try { Toggle-Widget } catch { Write-Log "hotkey: $_" } })

# ---------------------------------------------------------------- live data (this PC)
function Get-WifiNic {
    [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
        Where-Object { $_.NetworkInterfaceType -eq 'Wireless80211' -and $_.OperationalStatus -eq 'Up' } |
        Select-Object -First 1
}
function Read-WlanInfo {
    $out = & netsh.exe wlan show interfaces 2>$null
    $info = @{ Ssid = ''; Signal = 0; Band = ''; Channel = '' }
    foreach ($line in $out) {
        if     ($line -match '^\s*SSID\s*:\s*(.+?)\s*$')    { $info.Ssid = $Matches[1] }
        elseif ($line -match '^\s*Signal\s*:\s*(\d+)\s*%')  { $info.Signal = [int]$Matches[1] }
        elseif ($line -match '^\s*Band\s*:\s*(.+?)\s*$')    { $info.Band = $Matches[1] }
        elseif ($line -match '^\s*Channel\s*:\s*(\d+)')     { $info.Channel = $Matches[1] }
    }
    if (-not $info.Band -and $info.Channel) { $info.Band = $(if ([int]$info.Channel -gt 14) { '5 GHz' } else { '2.4 GHz' }) }
    $info
}
$script:Nic = $null; $script:LastRx = 0L; $script:LastTx = 0L; $script:LastT = [DateTime]::UtcNow; $script:Tick = 0
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    try {
        $script:Tick++
        if (-not $script:Nic) { $script:Nic = Get-WifiNic; $script:LastRx = 0L }
        $down = 0.0; $up = 0.0
        if ($script:Nic) {
            $st = $script:Nic.GetIPv4Statistics()
            $now = [DateTime]::UtcNow
            $dt = ($now - $script:LastT).TotalSeconds
            if ($script:LastRx -gt 0 -and $dt -gt 0) {
                $down = [math]::Max(0, ($st.BytesReceived - $script:LastRx) * 8 / 1e6 / $dt)
                $up   = [math]::Max(0, ($st.BytesSent     - $script:LastTx) * 8 / 1e6 / $dt)
            }
            $script:LastRx = $st.BytesReceived; $script:LastTx = $st.BytesSent; $script:LastT = $now
            if ($script:Nic.OperationalStatus -ne 'Up') { $script:Nic = $null }
        }
        $State.Down = $down; $State.Up = $up
        $DownHist.RemoveAt(0); $DownHist.Add($down); $UpHist.RemoveAt(0); $UpHist.Add($up)
        if (($script:Tick % 5) -eq 1) {
            $w = Read-WlanInfo
            if ($w.Ssid) { $State.Ssid = $w.Ssid; $State.Signal = $w.Signal; $State.Band = $w.Band; $State.Channel = $w.Channel }
            else { $State.Ssid = 'Not connected'; $State.Signal = 0; $State.Band = ''; $State.Channel = '' }
        }
        Process-Events
        Refresh-DevList
        Pump-Alerts
        Pump-SpeedSchedule
        Pump-DnsSchedule
        Pump-FullTest
        if (($script:Tick % 30) -eq 0) { Save-Devices }
        if ($script:ScanHandle -and $script:ScanHandle.IsCompleted -and (([DateTime]::UtcNow - $script:ScanStarted).TotalSeconds -gt 30)) {
            Write-Log 'scanner stopped unexpectedly, restarting'
            try { foreach ($er in $script:ScanPs.Streams.Error) { Write-Log ("scanner error: " + $er) } } catch {}
            Start-Scanner
        }
        if ($form.Visible) { $form.Invalidate() }
    } catch { Write-Log "tick: $_" }
})

# ---------------------------------------------------------------- go
Set-Rounded
Set-Corner
Ensure-Assets
Ensure-Envelopes
Load-Mascot
$form.Add_MouseWheel({
    param($s, $e)
    if ($Settings.Expanded) {
        $max = [math]::Max(0, $script:DevList.Count - 5)
        $script:DevScroll = [math]::Max(0, [math]::Min($max, $script:DevScroll - [math]::Sign($e.Delta)))
        $form.Invalidate()
    }
})
Start-Scanner
$timer.Start()
$form.Show()
Set-Corner
Write-Log 'widget shown'
Ensure-Startup
if ($form.HotKeyOk) { Write-Log 'hotkey Ctrl+Alt+W registered' } else { Write-Log 'hotkey Ctrl+Alt+W could NOT be registered (another program owns it)' }
try { [Windows.Forms.Application]::Run($form) } catch { Write-Log "run: $_" }
$timer.Stop(); try { $tray.Dispose() } catch {}
try { $script:Mutex.ReleaseMutex() } catch {}
Write-Log '--- stop ---'
