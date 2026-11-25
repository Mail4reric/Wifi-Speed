#requires -Version 5.1
# Micro Wi-Fi Analyzer - Full test + local HTML dashboard  (PART 7)
# Measures speed, latency, loss, signal, DNS, traceroute; saves history; builds MonitorData\dashboard.html
# Nothing is uploaded anywhere except the speed-test traffic to speed.cloudflare.com. The router address is never written to the report.
param([switch]$RebuildOnly, [switch]$NoOpen, [switch]$Pause)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'
$Root    = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataDir = Join-Path $Root 'MonitorData'
if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir | Out-Null }
$HistoryCsv = Join-Path $DataDir 'history.csv'
$LastJson   = Join-Path $DataDir 'last-run.json'
$HtmlFile   = Join-Path $DataDir 'dashboard.html'
$SpeedCsv   = Join-Path $DataDir 'speed-log.csv'
$SettingsFile = Join-Path $DataDir 'settings.json'
$LogFile    = Join-Path $DataDir 'micro.log'
$inv = [Globalization.CultureInfo]::InvariantCulture

function Write-Log([string]$m) { try { Add-Content -Path $LogFile -Value ("{0:yyyy-MM-dd HH:mm:ss}  analyzer: {1}" -f (Get-Date), $m) } catch {} }
function Say([string]$m) { Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $m) }
function Rnd([double]$v, [int]$d = 1) { [math]::Round($v, $d) }

$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\MicroWiFiAnalyzer', [ref]$created)
if (-not $created) { Say 'Another Full test is already running.'; exit 2 }

try {
$slowLimit = 10; $goodLimit = 50
try { $s = Get-Content $SettingsFile -Raw | ConvertFrom-Json; if ($s.SlowLimit) { $slowLimit = [double]$s.SlowLimit }; if ($s.GoodLimit) { $goodLimit = [double]$s.GoodLimit } } catch {}

# ======================================================================= measuring helpers
function Get-WifiNic {
    [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
        Where-Object { $_.NetworkInterfaceType -eq 'Wireless80211' -and $_.OperationalStatus -eq 'Up' } | Select-Object -First 1
}
function Get-WifiInfo {
    $i = @{ Ssid = ''; State = ''; Radio = ''; Band = ''; Channel = ''; RxRate = $null; TxRate = $null; Signal = $null; Rssi = $null }
    foreach ($l in (& netsh.exe wlan show interfaces 2>$null)) {
        if     ($l -match '^\s*SSID\s*:\s*(.+?)\s*$')                  { $i.Ssid = $Matches[1] }
        elseif ($l -match '^\s*State\s*:\s*(.+?)\s*$')                 { $i.State = $Matches[1] }
        elseif ($l -match '^\s*Radio type\s*:\s*(.+?)\s*$')            { $i.Radio = $Matches[1] }
        elseif ($l -match '^\s*Band\s*:\s*(.+?)\s*$')                  { $i.Band = $Matches[1] }
        elseif ($l -match '^\s*Channel\s*:\s*(\d+)')                   { $i.Channel = $Matches[1] }
        elseif ($l -match '^\s*Receive rate \(Mbps\)\s*:\s*([\d\.]+)') { $i.RxRate = [double]::Parse($Matches[1], $inv) }
        elseif ($l -match '^\s*Transmit rate \(Mbps\)\s*:\s*([\d\.]+)'){ $i.TxRate = [double]::Parse($Matches[1], $inv) }
        elseif ($l -match '^\s*Signal\s*:\s*(\d+)\s*%')                { $i.Signal = [int]$Matches[1] }
        elseif ($l -match '^\s*RSSI\s*:\s*(-?\d+)')                    { $i.Rssi = [int]$Matches[1] }
    }
    if ($null -eq $i.Rssi -and $null -ne $i.Signal) { $i.Rssi = [int]([math]::Round($i.Signal / 2 - 100)); $i.RssiEstimated = $true }
    if (-not $i.Band -and $i.Channel) { $i.Band = $(if ([int]$i.Channel -gt 14) { '5 GHz' } else { '2.4 GHz' }) }
    $i
}
function Get-PingStats([string]$target, [int]$count, [int]$timeout = 1000) {
    $p = New-Object Net.NetworkInformation.Ping; $rtts = New-Object System.Collections.Generic.List[double]; $lost = 0
    for ($n = 0; $n -lt $count; $n++) {
        try { $r = $p.Send($target, $timeout); if ($r.Status -eq 'Success') { $rtts.Add($r.RoundtripTime) } else { $lost++ } } catch { $lost++ }
        Start-Sleep -Milliseconds 150
    }
    $p.Dispose()
    $jit = 0.0; if ($rtts.Count -gt 1) { $sum = 0.0; for ($k = 1; $k -lt $rtts.Count; $k++) { $sum += [math]::Abs($rtts[$k] - $rtts[$k - 1]) }; $jit = $sum / ($rtts.Count - 1) }
    $avg = $null; $min = $null; $max = $null
    if ($rtts.Count) { $avg = Rnd (($rtts | Measure-Object -Average).Average); $min = $rtts | Measure-Object -Minimum | ForEach-Object { $_.Minimum }; $max = $rtts | Measure-Object -Maximum | ForEach-Object { $_.Maximum } }
    @{ Avg = $avg; Min = $min; Max = $max; Jitter = (Rnd $jit); Loss = (Rnd (100.0 * $lost / $count)); Sent = $count }
}
function Start-CurlProc([string[]]$a) {
    $quoted = foreach ($x in $a) { if ($x -match '[\s%]') { '"' + $x + '"' } else { $x } }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32\curl.exe'; $psi.Arguments = ($quoted -join ' ')
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    $p | Add-Member -NotePropertyName OutTask -NotePropertyValue $p.StandardOutput.ReadToEndAsync() -Force
    $p
}
function Wait-Curls($procs, [int]$ms) {
    $res = @()
    foreach ($p in $procs) {
        [void]$p.WaitForExit($ms); if (-not $p.HasExited) { try { $p.Kill() } catch {} }
        $o = ''; try { $o = ($p.OutTask.Result).Trim() } catch {}
        $res += , ($o -split '\s+')
    }
    ,$res
}
function Test-Download([string]$ip, [int]$streams = 4) {
    $out = @{ Mbps = 0.0; Status = 'failed'; Http = 0; SizeMB = 0; Streams = 0 }
    foreach ($sz in 25000000, 10000000, 5000000, 2000000) {
        $procs = @(); for ($n = 0; $n -lt $streams; $n++) {
            $procs += Start-CurlProc @('-s', '-o', 'NUL', '--max-time', '25', '--connect-timeout', '8', '-w', '%{http_code} %{size_download} %{time_total} %{time_starttransfer}', '--interface', $ip, "https://speed.cloudflare.com/__down?bytes=$sz")
        }
        $rows = Wait-Curls $procs 45000
        $sum = 0.0; $ok = 0; $http = 0
        foreach ($r in $rows) {
            if ($r.Count -lt 4) { continue }
            try {
                $h = [int]$r[0]; $size = [double]::Parse($r[1], $inv); $tt = [double]::Parse($r[2], $inv); $st = [double]::Parse($r[3], $inv)
                if ($h -gt 0) { $http = $h }
                if ($h -eq 200 -and $size -gt 0) { $t = $tt - $st; if ($t -lt 0.15) { $t = $tt }; $sum += $size * 8 / $t / 1e6; $ok++ }
            } catch {}
        }
        $out.Http = $http; $out.SizeMB = [math]::Round($sz / 1e6)
        if ($ok -gt 0) { $out.Mbps = Rnd $sum 1; $out.Status = 'ok'; $out.Streams = $ok; return $out }
        if ($http -eq 403) { $out.Status = 'refused'; continue }
        $out.Status = 'failed'; return $out
    }
    $out
}
function Invoke-UploadRound([string]$ip, [int]$size, [int]$n) {
    $o = @{ Mbps = 0.0; Status = 'failed'; Http = 0; SizeMB = [math]::Round($size / 1e6, 1) }
    $tmp = Join-Path $DataDir '_upload.tmp'
    $bytes = New-Object byte[] $size; (New-Object Random).NextBytes($bytes); [IO.File]::WriteAllBytes($tmp, $bytes)
    $procs = @(); for ($i = 0; $i -lt $n; $i++) {
        $procs += Start-CurlProc @('-s', '-o', 'NUL', '--max-time', '22', '--connect-timeout', '8', '-X', 'POST', '-H', 'Content-Type: application/octet-stream', '--data-binary', "@$tmp",
                                   '-w', '%{http_code} %{size_upload} %{time_total} %{time_pretransfer}', '--interface', $ip, 'https://speed.cloudflare.com/__up')
    }
    $rows = Wait-Curls $procs 40000
    $sum = 0.0; $ok = 0
    foreach ($r in $rows) {
        if ($r.Count -lt 4) { continue }
        try {
            $h = [int]$r[0]; $sent = [double]::Parse($r[1], $inv); $tt = [double]::Parse($r[2], $inv); $pre = [double]::Parse($r[3], $inv)
            if ($h -gt 0) { $o.Http = $h }
            $t = $tt - $pre                                  # the server answers early, so time the whole upload
            if ($h -eq 200 -and $sent -gt 0 -and $t -gt 0.05) { $sum += $sent * 8 / $t / 1e6; $ok++ }
        } catch {}
    }
    Remove-Item $tmp -ErrorAction SilentlyContinue
    if ($ok -gt 0) { $o.Mbps = Rnd $sum 1; $o.Status = 'ok' } elseif ($o.Http -eq 403) { $o.Status = 'refused' }
    $o
}
function Test-Upload([string]$ip, [int]$streams = 3) {
    $probe = Invoke-UploadRound $ip 1000000 1                  # quick 1 MB probe to size the real test (~6 s per stream)
    if ($probe.Status -ne 'ok') { return $probe }
    $size = [int][math]::Min(8000000, $probe.Mbps * 1e6 / 8 * 6 / $streams)
    if ($size -lt 1500000) { return $probe }                   # slow link: the probe already took long enough
    $main = Invoke-UploadRound $ip $size $streams
    if ($main.Status -eq 'ok') { return $main }
    $probe
}
function Test-DnsLookup([string[]]$servers) {
    $times = @()
    $srv = $servers | Select-Object -First 1
    foreach ($n in 'example.com', 'cloudflare.com', 'wikipedia.org') {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try { if ($srv) { [void](Resolve-DnsName -Name $n -Type A -Server $srv -DnsOnly -QuickTimeout -ErrorAction Stop) } else { [void](Resolve-DnsName -Name $n -Type A -DnsOnly -ErrorAction Stop) }; $sw.Stop(); $times += $sw.ElapsedMilliseconds } catch { }
    }
    if ($times.Count) { Rnd (($times | Measure-Object -Average).Average) 0 } else { $null }
}
function Get-DnsShield([string]$gateway) {      # same rules as the widget's DNS Shield
    $known = @{}
    function Norm([string]$s) { try { [Net.IPAddress]::Parse(($s -replace '%.*$', '')).ToString() } catch { $s } }
    function AddK([string]$prov, [bool]$f, [string[]]$ips) { foreach ($i in $ips) { $known[(Norm $i)] = @{ Provider = $prov; Filter = $f } } }
    AddK 'Cloudflare (scam/malware filter)' $true  @('1.1.1.2', '1.0.0.2', '1.1.1.3', '1.0.0.3', '2606:4700:4700::1112', '2606:4700:4700::1002', '2606:4700:4700::1113', '2606:4700:4700::1003')
    AddK 'Cloudflare (plain)' $false @('1.1.1.1', '1.0.0.1', '2606:4700:4700::1111', '2606:4700:4700::1001')
    AddK 'Quad9 (malware filter)' $true  @('9.9.9.9', '149.112.112.112', '9.9.9.11', '149.112.112.11', '2620:fe::fe', '2620:fe::9', '2620:fe::11', '2620:fe::fe:11')
    AddK 'Quad9 (plain)' $false @('9.9.9.10', '149.112.112.10', '2620:fe::10', '2620:fe::fe:10')
    AddK 'AdGuard (filtering)' $true @('94.140.14.14', '94.140.15.15', '94.140.14.15', '94.140.15.16', '2a10:50c0::ad1:ff', '2a10:50c0::ad2:ff')
    AddK 'CleanBrowsing (filtering)' $true @('185.228.168.9', '185.228.169.9', '185.228.168.10', '185.228.169.11', '185.228.168.168', '185.228.169.168', '2a0d:2a00:1::2', '2a0d:2a00:2::2')
    AddK 'OpenDNS FamilyShield (filtering)' $true @('208.67.222.123', '208.67.220.123')
    AddK 'OpenDNS (plain)' $false @('208.67.222.222', '208.67.220.220')
    AddK 'Google (plain)' $false @('8.8.8.8', '8.8.4.4', '2001:4860:4860::8888', '2001:4860:4860::8844')
    function IsPriv([string]$s) {
        $ip = [Net.IPAddress]::Parse($s); $b = $ip.GetAddressBytes()
        if ($ip.AddressFamily -eq 'InterNetwork') { return ($b[0] -eq 10 -or ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or ($b[0] -eq 192 -and $b[1] -eq 168) -or ($b[0] -eq 169 -and $b[1] -eq 254) -or ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127)) }
        return ($ip.IsIPv6LinkLocal -or $ip.IsIPv6SiteLocal -or (($b[0] -band 0xFE) -eq 0xFC))
    }
    function Typo([string]$s) {
        if ($s.Contains(':')) { return '' }
        $o = $s.Split('.'); $h = @()
        foreach ($k in $known.Keys) { if ($k.Contains(':')) { continue }; $p = $k.Split('.'); $d = 0; for ($i = 0; $i -lt 4; $i++) { if ($o[$i] -ne $p[$i]) { $d++ } }; if ($d -eq 1) { $h += $k } }
        ($h | Sort-Object | Select-Object -First 2) -join ' or '
    }
    $list = @(); $allServers = @()
    foreach ($a in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })) {
        $servers = @()
        $addrs = @(Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ErrorAction SilentlyContinue | ForEach-Object { $_.ServerAddresses } | Where-Object { $_ } | Select-Object -Unique)
        foreach ($s in $addrs) {
            if ($s -like 'fec0:0:0:ffff::*') { continue }
            $n = Norm $s; $kind = 'plain'; $prov = ''; $typo = ''
            if ($known.ContainsKey($n)) { $prov = $known[$n].Provider; $kind = $(if ($known[$n].Filter) { 'filter' } else { 'plain' }) }
            elseif ((IsPriv $n) -or ($gateway -and $n -eq $gateway)) { $kind = 'router'; $prov = 'Your router (address hidden)' }
            else { $prov = 'Public DNS (not a known filter)'; $typo = Typo $n }
            $ok = $false; $ms = $null; $sw = [Diagnostics.Stopwatch]::StartNew()
            try { if (Resolve-DnsName -Name example.com -Type A -Server $n -DnsOnly -QuickTimeout -ErrorAction Stop) { $ok = $true } } catch {}
            $sw.Stop(); if ($ok) { $ms = [int]$sw.ElapsedMilliseconds }
            $allServers += $n
            $label = $(if ($kind -eq 'router') { 'router' } else { $n })
            $servers += @{ Server = $label; Kind = $kind; Provider = $prov; Answers = $ok; Ms = $ms; Typo = $typo }
        }
        $nF = @($servers | Where-Object { $_.Kind -eq 'filter' }).Count; $nO = $servers.Count - $nF
        $anyF = @($servers | Where-Object { $_.Kind -eq 'filter' -and $_.Answers }).Count
        $st = if ($nF -eq 0) { 'off' } elseif ($nO -gt 0) { 'partial' } elseif ($anyF -eq 0) { 'broken' } else { 'on' }
        $list += @{ Adapter = [string]$a.Name; Status = $st; Servers = $servers }
    }
    @{ Adapters = $list; ServerIps = $allServers }
}
function Get-Trace([string]$gateway, [string]$target = '1.1.1.1') {
    $hops = @(); $p = New-Object Net.NetworkInformation.Ping
    for ($ttl = 1; $ttl -le 10; $ttl++) {
        $opt = New-Object Net.NetworkInformation.PingOptions($ttl, $true)
        try { $r = $p.Send($target, 1000, (New-Object byte[] 32), $opt) } catch { $r = $null }
        $host_ = '*'; $ms = $null
        if ($r -and ($r.Status -eq 'TtlExpired' -or $r.Status -eq 'Success')) {
            $addr = $r.Address.ToString(); $ms = [int]$r.RoundtripTime
            $b = $r.Address.GetAddressBytes()
            $priv = ($b[0] -eq 10 -or ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or ($b[0] -eq 192 -and $b[1] -eq 168) -or ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127))
            $host_ = if ($ttl -eq 1 -or $addr -eq $gateway) { 'Your router (hidden)' } elseif ($priv) { 'Private network (hidden)' } else { $addr }
        }
        $hops += @{ Hop = $ttl; Host = $host_; Ms = $ms }
        if ($r -and $r.Status -eq 'Success') { break }
    }
    $p.Dispose(); $hops
}

# ======================================================================= the run
$ts = Get-Date
if (-not $RebuildOnly) {
    Say 'Micro Wi-Fi Full test starting (about 1 minute). Nothing is uploaded except the speed-test traffic.'
    $nic = Get-WifiNic
    if (-not $nic) { Say 'No connected Wi-Fi adapter found. Connect to Wi-Fi and try again.'; Write-Log 'full test: no wifi'; if ($Pause) { Read-Host 'Press Enter' }; exit 1 }
    $props = $nic.GetIPProperties()
    $ip = ($props.UnicastAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1).Address.ToString()
    $gwObj = $props.GatewayAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
    $gw = if ($gwObj) { $gwObj.Address.ToString() } else { '' }

    Say 'Wi-Fi details...';          $wifi = Get-WifiInfo
    Say 'Router latency + loss...';  $rt = if ($gw) { Get-PingStats $gw 20 } else { @{ Avg = $null; Loss = $null; Jitter = $null } }
    Say 'Internet latency (Cloudflare)...'; $cf = Get-PingStats '1.1.1.1' 12
    Say 'Internet latency (Google)...';     $go = Get-PingStats '8.8.8.8' 12
    Say 'DNS Shield checks...';      $dns = Get-DnsShield $gw
    Say 'DNS lookup time...';        $dnsMs = Test-DnsLookup $dns.ServerIps
    Say 'Download speed (4 streams)...'; $dl = Test-Download $ip 4
    Say 'Upload speed (3 streams)...';   $ul = Test-Upload $ip 3
    Say 'Traceroute...';             $trace = Get-Trace $gw
    $route = $null; try { $route = (Find-NetRoute -RemoteIPAddress 1.1.1.1 -ErrorAction Stop | Select-Object -First 1).InterfaceIndex } catch {}
    $wifiIdx = $props.GetIPv4Properties().Index
    $viaWifi = ($null -eq $route) -or ($route -eq $wifiIdx)

    # ---------------------------------------------------------------- diagnostics (PASS / INFO / WARN)
    $diag = New-Object System.Collections.ArrayList
    function D([string]$check, [string]$result, [string]$status, [string]$note) { [void]$diag.Add(@{ Check = $check; Result = $result; Status = $status; Note = $note }) }
    $sig = $wifi.Signal; $rssi = $wifi.Rssi
    if ($null -ne $sig) { D 'Wi-Fi signal' "$sig %" $(if ($sig -ge 70) { 'PASS' } elseif ($sig -ge 40) { 'INFO' } else { 'WARN' }) 'Strength of the link to your router. Above 70% is comfortable; below 40% means distance or walls are hurting.' }
    if ($null -ne $rssi) { D 'Signal (RSSI)' ("$rssi dBm" + $(if ($wifi.RssiEstimated) { ' (estimated)' } else { '' })) $(if ($rssi -ge -60) { 'PASS' } elseif ($rssi -ge -72) { 'INFO' } else { 'WARN' }) 'Closer to 0 is better. Stronger than -60 dBm is excellent, weaker than -72 dBm gets unreliable.' }
    D 'Band / channel' ("$($wifi.Band), channel $($wifi.Channel)") 'INFO' $(if ($wifi.Band -like '2.4*') { '2.4 GHz reaches farther but is slower and more crowded. 5 GHz is faster at closer range.' } else { 'Higher bands are faster but do not travel as far through walls.' })
    if ($wifi.Radio) { D 'Radio type' $wifi.Radio $(if ($wifi.Radio -match '802\.11(n|g|b|a)\b') { 'WARN' } else { 'PASS' }) 'The Wi-Fi standard in use. 802.11n or older limits speed; 802.11ac / ax is modern.' }
    if ($wifi.RxRate) { D 'Link rate' ("{0} / {1} Mbps (receive / send)" -f $wifi.RxRate, $wifi.TxRate) $(if ($wifi.RxRate -ge 300) { 'PASS' } elseif ($wifi.RxRate -ge 100) { 'INFO' } else { 'WARN' }) 'The speed your PC and router negotiated. Real internet speed is always lower than this.' }
    if ($dl.Status -eq 'ok') { D 'Download speed' "$($dl.Mbps) Mbps" $(if ($dl.Mbps -ge $goodLimit) { 'PASS' } elseif ($dl.Mbps -lt $slowLimit) { 'WARN' } else { 'INFO' }) "Measured with $($dl.Streams) parallel streams from Cloudflare. Slow limit $slowLimit, good from $goodLimit Mbps." }
    else { D 'Download speed' $(if ($dl.Status -eq 'refused') { 'refused by server' } else { 'could not measure' }) 'INFO' $(if ($dl.Status -eq 'refused') { 'The test server answered 403. That is the server saying no - it does NOT mean your Wi-Fi is slow.' } else { 'No connection to the test server over Wi-Fi.' }) }
    if ($ul.Status -eq 'ok') { D 'Upload speed' "$($ul.Mbps) Mbps" $(if ($ul.Mbps -ge 10) { 'PASS' } elseif ($ul.Mbps -ge 3) { 'INFO' } else { 'WARN' }) 'Matters for video calls, backups and sending big files.' }
    else { D 'Upload speed' $(if ($ul.Status -eq 'refused') { 'refused by server' } else { 'could not measure' }) 'INFO' 'The upload test did not complete.' }
    if ($null -ne $rt.Avg) { D 'Router latency' "$($rt.Avg) ms (jitter $($rt.Jitter) ms)" $(if ($rt.Avg -lt 10) { 'PASS' } elseif ($rt.Avg -lt 30) { 'INFO' } else { 'WARN' }) 'Time to reach your router over Wi-Fi. This part is entirely your Wi-Fi.' }
    if ($null -ne $rt.Loss) { D 'Router packet loss' "$($rt.Loss) %" $(if ($rt.Loss -eq 0) { 'PASS' } elseif ($rt.Loss -le 2) { 'INFO' } else { 'WARN' }) 'Lost packets between this PC and the router point at interference or weak signal.' }
    if ($null -ne $cf.Avg) { D 'Internet latency (Cloudflare)' "$($cf.Avg) ms" $(if ($cf.Avg -lt 40) { 'PASS' } elseif ($cf.Avg -lt 100) { 'INFO' } else { 'WARN' }) 'Round trip to the internet. Includes your Wi-Fi hop plus your provider.' }
    if ($null -ne $go.Avg) { D 'Internet latency (Google)' "$($go.Avg) ms" $(if ($go.Avg -lt 40) { 'PASS' } elseif ($go.Avg -lt 100) { 'INFO' } else { 'WARN' }) 'A second target, to tell a slow site from a slow connection.' }
    $inLoss = [math]::Max([double]$cf.Loss, [double]$go.Loss)
    D 'Internet packet loss' "$inLoss %" $(if ($inLoss -eq 0) { 'PASS' } elseif ($inLoss -le 2) { 'INFO' } else { 'WARN' }) 'Packets that never came back from Cloudflare or Google.'
    $jmax = [math]::Max([double]$cf.Jitter, [double]$go.Jitter)
    D 'Jitter' "$jmax ms" $(if ($jmax -lt 10) { 'PASS' } elseif ($jmax -lt 30) { 'INFO' } else { 'WARN' }) 'How much latency jumps around. High jitter hurts calls and games.'
    if ($null -ne $dnsMs) { D 'DNS lookup time' "$dnsMs ms" $(if ($dnsMs -lt 50) { 'PASS' } elseif ($dnsMs -lt 150) { 'INFO' } else { 'WARN' }) 'How long your DNS server takes to turn a name into an address.' }
    foreach ($a in $dns.Adapters) {
        $st = switch ($a.Status) { 'on' { 'PASS' } 'partial' { 'INFO' } 'broken' { 'WARN' } default { 'INFO' } }
        $txt = switch ($a.Status) { 'on' { 'scam filter ON' } 'partial' { 'partly protected' } 'broken' { 'filter not answering' } default { 'no scam filter' } }
        D "DNS Shield - $($a.Adapter)" $txt $st 'Whether this adapter uses a scam-filtering DNS (Cloudflare 1.1.1.2, Quad9, AdGuard, CleanBrowsing, OpenDNS FamilyShield).'
        foreach ($s in $a.Servers) { if ($s.Typo) { D 'DNS address typo?' "$($s.Server) looks like $($s.Typo)" 'WARN' 'This DNS address is one digit away from a well-known one. A typo here can break or slow name lookups.' } }
    }
    if (-not $viaWifi) { D 'Internet route' 'not through Wi-Fi' 'INFO' 'Internet traffic currently leaves through another connection (for example Ethernet). Ping numbers may not describe Wi-Fi.' }
    D 'Traceroute' ("{0} hops to 1.1.1.1" -f $trace.Count) 'INFO' 'The path from this PC to the internet. The first hop (your router) is hidden in this report.'

    # ---------------------------------------------------------------- bottleneck
    $ev = @(); $title = ''; $detail = ''
    $rate = $wifi.RxRate
    if (($null -ne $sig -and $sig -lt 40) -or ($null -ne $rssi -and $rssi -lt -75)) {
        $title = 'Wi-Fi signal strength'; $detail = 'The signal between this PC and your router is weak. Move closer, reduce walls in between, or use a router/extender nearer to you.'
        $ev += "Signal $sig% ($rssi dBm)"
    } elseif (($null -ne $rt.Avg -and $rt.Avg -gt 30) -or ($null -ne $rt.Loss -and $rt.Loss -gt 2)) {
        $title = 'Wi-Fi quality (interference or congestion)'; $detail = 'Even the short hop to your router is slow or drops packets. Other networks or busy devices on the same channel are the likely cause. Try 5 GHz or another channel.'
        $ev += "Router latency $($rt.Avg) ms, loss $($rt.Loss)%"
    } elseif ($rate -and $dl.Status -eq 'ok' -and $dl.Mbps -ge 0.6 * $rate) {
        $title = 'Wi-Fi link speed'; $detail = 'Your download is close to what the Wi-Fi link itself can carry, so the wireless connection is the ceiling. A newer router, the 5 GHz band or a closer position would raise it.'
        $ev += "Download $($dl.Mbps) Mbps vs link rate $rate Mbps"
    } elseif (($null -ne $cf.Avg -and $null -ne $rt.Avg -and ($cf.Avg - $rt.Avg) -gt 60) -or $inLoss -gt 2) {
        $title = 'Internet connection / provider'; $detail = 'Your Wi-Fi is healthy, but the path beyond your router is slow or lossy. This points at your internet provider or the line, not the Wi-Fi.'
        $ev += "Cloudflare $($cf.Avg) ms vs router $($rt.Avg) ms, internet loss $inLoss%"
    } elseif ($dl.Status -eq 'ok' -and $dl.Mbps -lt $slowLimit) {
        $title = 'Internet plan or provider throughput'; $detail = 'Wi-Fi and latency look fine but throughput is low. Check your plan speed or try again later when the network is less busy.'
        $ev += "Download $($dl.Mbps) Mbps (slow limit $slowLimit)"
    } elseif ($null -ne $dnsMs -and $dnsMs -gt 150) {
        $title = 'DNS speed'; $detail = 'Name lookups are slow, which makes pages feel sluggish even when speed is fine. Try a different DNS server (Cloudflare 1.1.1.2 also blocks scam sites).'
        $ev += "DNS lookup $dnsMs ms"
    } elseif ($dl.Status -ne 'ok') {
        $title = 'Could not measure speed'; $detail = 'The speed test did not complete, so the bottleneck cannot be judged for throughput. Latency and signal results are still shown below.'
        $ev += "Download status: $($dl.Status)"
    } else {
        $title = 'No bottleneck found'; $detail = 'Signal, latency, loss and speed all look healthy.'
        $ev += "Download $($dl.Mbps) Mbps, router $($rt.Avg) ms, internet $($cf.Avg) ms"
    }
    $bottle = @{ Title = $title; Detail = $detail; Evidence = $ev }

    # ---------------------------------------------------------------- save
    $last = @{
        Time = $ts.ToString('s'); Epoch = [int64]([DateTimeOffset]$ts).ToUnixTimeMilliseconds(); Ssid = $wifi.Ssid
        Signal = $sig; Rssi = $rssi; RssiEstimated = [bool]$wifi.RssiEstimated; Band = $wifi.Band; Channel = $wifi.Channel; Radio = $wifi.Radio; RxRate = $wifi.RxRate; TxRate = $wifi.TxRate
        Down = $dl.Mbps; DownStatus = $dl.Status; Up = $ul.Mbps; UpStatus = $ul.Status
        RouterMs = $rt.Avg; RouterLoss = $rt.Loss; RouterJitter = $rt.Jitter; CfMs = $cf.Avg; GoogleMs = $go.Avg; InetLoss = $inLoss; Jitter = $jmax; DnsMs = $dnsMs
        DnsShield = $(if (@($dns.Adapters).Count -and -not @($dns.Adapters | Where-Object { $_.Status -ne 'on' }).Count) { 'ON' } else { 'OFF' })
        Diag = @($diag); Bottleneck = $bottle; Trace = @($trace); Dns = @($dns.Adapters)
    }
    $json = $last | ConvertTo-Json -Depth 8
    if ($gw) { $json = $json.Replace($gw, '[router]') }
    Set-Content -Path $LastJson -Value $json -Encoding UTF8
    $row = [pscustomobject][ordered]@{
        time = $ts.ToString('s'); ssid = $wifi.Ssid; signal = $sig; rssi = $rssi; band = $wifi.Band; channel = $wifi.Channel; radio = $wifi.Radio
        link_rx = $wifi.RxRate; link_tx = $wifi.TxRate; down = $dl.Mbps; up = $ul.Mbps; ping_router = $rt.Avg; loss_router = $rt.Loss
        ping_cf = $cf.Avg; ping_google = $go.Avg; loss_inet = $inLoss; jitter = $jmax; dns_ms = $dnsMs; dns_shield = $last.DnsShield; bottleneck = $title
    }
    $row | Export-Csv -Path $HistoryCsv -Append -NoTypeInformation -Encoding UTF8
    Write-Log ("full test done: down {0} up {1} router {2} ms, bottleneck: {3}" -f $dl.Mbps, $ul.Mbps, $rt.Avg, $title)
    Say ("Done. Download {0} Mbps, upload {1} Mbps, router {2} ms, internet {3} ms." -f $dl.Mbps, $ul.Mbps, $rt.Avg, $cf.Avg)
    Say "Assessment: $title"
}

# ======================================================================= dashboard
if (-not (Test-Path $LastJson)) { Say 'No Full test has been run yet.'; exit 1 }
$lastObj = Get-Content $LastJson -Raw | ConvertFrom-Json
$hist = @()
if (Test-Path $HistoryCsv) {
    foreach ($r in (Import-Csv $HistoryCsv)) {
        try {
            $t = [DateTime]::Parse($r.time, $inv)
            $hist += @{ t = [int64]([DateTimeOffset]$t).ToUnixTimeMilliseconds(); down = $(if ($r.down) { [double]::Parse($r.down, $inv) } else { $null }); up = $(if ($r.up) { [double]::Parse($r.up, $inv) } else { $null })
                        router = $(if ($r.ping_router) { [double]::Parse($r.ping_router, $inv) } else { $null }); cf = $(if ($r.ping_cf) { [double]::Parse($r.ping_cf, $inv) } else { $null })
                        google = $(if ($r.ping_google) { [double]::Parse($r.ping_google, $inv) } else { $null }); signal = $(if ($r.signal) { [double]::Parse($r.signal, $inv) } else { $null }) }
        } catch {}
    }
}
$quick = @()
if (Test-Path $SpeedCsv) {
    foreach ($r in (Import-Csv $SpeedCsv)) {
        try { if ($r.status -eq 'ok') { $t = [DateTime]::Parse($r.time, $inv); $quick += @{ t = [int64]([DateTimeOffset]$t).ToUnixTimeMilliseconds(); down = [double]::Parse($r.mbps, $inv) } } } catch {}
    }
}
$payload = @{ Generated = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Last = $lastObj; History = @($hist); Quick = @($quick); Slow = $slowLimit; Good = $goodLimit }
$dataJson = ($payload | ConvertTo-Json -Depth 10 -Compress).Replace('</', '<\/')

$template = @'
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Micro Wi-Fi Report</title>
<style>
:root{color-scheme:light;--bg:#f6f6f4;--surface:#fcfcfb;--ink:#0b0b0b;--ink2:#52514e;--muted:#7b7a75;--grid:#e4e3de;--line:#dcdbd5;--s1:#2a78d6;--s2:#eb6834;--s3:#1baf7a;--pass:#0a6a0a;--passbg:#dff3df;--info:#1c5cab;--infobg:#dbe9fb;--warn:#7a4f00;--warnbg:#fdecc8}
@media (prefers-color-scheme:dark){:root:where(:not([data-theme="light"])){color-scheme:dark;--bg:#121211;--surface:#1a1a19;--ink:#f0efec;--ink2:#c3c2b7;--muted:#97968d;--grid:#2c2c2a;--line:#333330;--s1:#3987e5;--s2:#d95926;--s3:#199e70;--pass:#7fdc7f;--passbg:#173817;--info:#8fbaf3;--infobg:#17304f;--warn:#f0c04a;--warnbg:#4a3500}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.45 "Segoe UI",system-ui,sans-serif}
main{max-width:1100px;margin:0 auto;padding:20px 16px 48px}
h1{font-size:22px;margin:0 0 2px}h2{font-size:16px;margin:28px 0 10px}.sub{color:var(--ink2);margin:0 0 18px;font-size:13px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px}
.card{background:var(--surface);border:1px solid var(--line);border-radius:12px;padding:14px 16px}
.card .k{color:var(--ink2);font-size:12px;text-transform:uppercase;letter-spacing:.04em}.card .v{font-size:28px;font-weight:600;margin:4px 0 2px}.card .v small{font-size:13px;font-weight:400;color:var(--ink2)}.card .n{color:var(--muted);font-size:12px;min-height:16px}
.badge{display:inline-block;font-size:11px;font-weight:700;padding:2px 8px;border-radius:999px;letter-spacing:.03em}
.PASS{color:var(--pass);background:var(--passbg)}.INFO{color:var(--info);background:var(--infobg)}.WARN{color:var(--warn);background:var(--warnbg)}
.bott{border-left:4px solid var(--s1)}.bott h3{margin:0 0 4px;font-size:18px}.bott p{margin:4px 0;color:var(--ink2)}.bott ul{margin:6px 0 0;padding-left:18px;color:var(--ink2)}
.tabs{display:flex;gap:6px;align-items:center;margin:0 0 12px;flex-wrap:wrap}.tabs button,.tog{font:inherit;font-size:13px;padding:5px 14px;border-radius:8px;border:1px solid var(--line);background:var(--surface);color:var(--ink);cursor:pointer}
.tabs button.on{background:var(--s1);border-color:var(--s1);color:#fff}.tabs .sp{flex:1}
.charts{display:grid;grid-template-columns:repeat(auto-fit,minmax(420px,1fr));gap:12px}
.chartbox{position:relative}.chartbox h3{font-size:14px;margin:0 0 6px}
.legend{display:flex;gap:14px;flex-wrap:wrap;font-size:12px;color:var(--ink2);margin:0 0 4px}.legend i{display:inline-block;width:14px;height:3px;border-radius:2px;vertical-align:middle;margin-right:5px}
svg{width:100%;height:auto;display:block}.axis{fill:var(--muted);font-size:11px}.gl{stroke:var(--grid);stroke-width:1}
.tip{position:absolute;pointer-events:none;background:var(--surface);color:var(--ink);border:1px solid var(--line);border-radius:8px;padding:6px 9px;font-size:12px;box-shadow:0 4px 14px #0003;display:none;white-space:nowrap;z-index:3}
.empty{color:var(--muted);padding:30px 0;text-align:center;font-size:13px}
table{width:100%;border-collapse:collapse;background:var(--surface);border:1px solid var(--line);border-radius:12px;overflow:hidden;font-size:13px}
th,td{text-align:left;padding:9px 12px;border-bottom:1px solid var(--line);vertical-align:top}th{color:var(--ink2);font-weight:600;font-size:12px}tr:last-child td{border-bottom:0}td.note{color:var(--ink2)}
.two{display:grid;grid-template-columns:repeat(auto-fit,minmax(380px,1fr));gap:12px}
footer{color:var(--muted);font-size:12px;margin-top:28px}
@media (max-width:520px){.charts,.two{grid-template-columns:1fr}.card .v{font-size:24px}}
</style></head><body><main>
<h1>Micro Wi-Fi Report</h1>
<p class="sub" id="sub"></p>
<div class="grid" id="cards"></div>
<h2>Where might the bottleneck be?</h2>
<div class="card bott" id="bott"></div>
<h2>Trends</h2>
<div class="tabs" id="tabs"><button data-r="86400000">24H</button><button data-r="604800000">7D</button><button data-r="2592000000">30D</button><span class="sp"></span><button class="tog" id="tog">Show as table</button></div>
<div class="charts" id="charts"></div>
<h2>Diagnostics</h2>
<table id="diag"><thead><tr><th>Check</th><th>Result</th><th>Status</th><th>What it means</th></tr></thead><tbody></tbody></table>
<div class="two"><div><h2>Path to the internet</h2><table id="trace"><thead><tr><th>Hop</th><th>Address</th><th>Time</th></tr></thead><tbody></tbody></table></div>
<div><h2>DNS Shield</h2><table id="dns"><thead><tr><th>Adapter / server</th><th>Type</th><th>Answer</th></tr></thead><tbody></tbody></table></div></div>
<footer>Generated locally on __GEN__. Everything stays on this PC. Your router's address is hidden. Speed numbers use Cloudflare's test servers over the Wi-Fi adapter; if an Ethernet cable is also connected, ping numbers may use it.</footer>
</main>
<script>
const DATA=__DATA__;
const L=DATA.Last, $=id=>document.getElementById(id);
const esc=s=>String(s==null?'':s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const fmtT=(t,long)=>{const d=new Date(t);return long?d.toLocaleString([], {month:'short',day:'numeric',hour:'2-digit',minute:'2-digit'}):d.toLocaleTimeString([], {hour:'2-digit',minute:'2-digit'})};
$('sub').textContent='Last Full test '+L.Time.replace('T',' ')+'  \u00b7  '+(L.Ssid||'Wi-Fi')+'  \u00b7  '+(L.Band||'')+(L.Channel?' ch '+L.Channel:'')+'  \u00b7  '+(L.Radio||'');
const st=(name)=>{const d=(L.Diag||[]).find(x=>x.Check===name);return d?d.Status:'INFO'};
const cards=[
 ['Download',L.DownStatus==='ok'?L.Down:null,'Mbps','Download speed','Cloudflare, parallel streams'],
 ['Upload',L.UpStatus==='ok'?L.Up:null,'Mbps','Upload speed','Cloudflare, parallel streams'],
 ['Internet latency',L.CfMs,'ms','Internet latency (Cloudflare)','Google '+(L.GoogleMs==null?'--':L.GoogleMs+' ms')],
 ['Router latency',L.RouterMs,'ms','Router latency','jitter '+(L.RouterJitter==null?'--':L.RouterJitter+' ms')],
 ['Packet loss',L.InetLoss,'%','Internet packet loss','router '+(L.RouterLoss==null?'--':L.RouterLoss+' %')],
 ['Wi-Fi signal',L.Signal,'%','Wi-Fi signal',(L.Rssi==null?'':L.Rssi+' dBm'+(L.RssiEstimated?' (est.)':''))],
 ['Link rate',L.RxRate,'Mbps','Link rate','send '+(L.TxRate==null?'--':L.TxRate+' Mbps')],
 ['DNS lookup',L.DnsMs,'ms','DNS lookup time','DNS Shield '+L.DnsShield]];
$('cards').innerHTML=cards.map(c=>`<div class="card"><div class="k">${c[0]}</div><div class="v">${c[1]==null?'--':esc(c[1])} <small>${c[2]}</small></div><div class="n">${esc(c[4])}</div><span class="badge ${st(c[3])}">${st(c[3])}</span></div>`).join('');
const B=L.Bottleneck||{};
$('bott').innerHTML=`<h3>${esc(B.Title)}</h3><p>${esc(B.Detail)}</p><ul>${[].concat(B.Evidence||[]).map(e=>'<li>'+esc(e)+'</li>').join('')}</ul>`;
$('diag').querySelector('tbody').innerHTML=(L.Diag||[]).map(d=>`<tr><td>${esc(d.Check)}</td><td>${esc(d.Result)}</td><td><span class="badge ${d.Status}">${d.Status}</span></td><td class="note">${esc(d.Note)}</td></tr>`).join('');
$('trace').querySelector('tbody').innerHTML=(L.Trace||[]).map(h=>`<tr><td>${h.Hop}</td><td>${esc(h.Host)}</td><td>${h.Ms==null?'--':h.Ms+' ms'}</td></tr>`).join('');
$('dns').querySelector('tbody').innerHTML=[].concat(L.Dns||[]).map(a=>{const lab={on:'scam filter ON',partial:'partly protected',broken:'not answering',off:'no scam filter'}[a.Status];
 return `<tr><td><b>${esc(a.Adapter)}</b></td><td colspan="2"><span class="badge ${a.Status==='on'?'PASS':a.Status==='broken'?'WARN':'INFO'}">${lab}</span></td></tr>`+[].concat(a.Servers||[]).map(s=>`<tr><td>&nbsp;&nbsp;${esc(s.Server)}</td><td>${esc(s.Provider)}</td><td>${s.Answers?s.Ms+' ms':'no answer'}${s.Typo?' &middot; typo? '+esc(s.Typo):''}</td></tr>`).join('')}).join('');

let range=604800000, table=false;
const defs=[
 {id:'c1',title:'Throughput (Mbps)',unit:'Mbps',series:[{n:'Download (Full test)',c:'var(--s1)',src:'History',k:'down'},{n:'Upload (Full test)',c:'var(--s2)',src:'History',k:'up'},{n:'Download (quick tests)',c:'var(--s3)',src:'Quick',k:'down'}]},
 {id:'c2',title:'Latency (ms)',unit:'ms',series:[{n:'Router',c:'var(--s1)',src:'History',k:'router'},{n:'Cloudflare',c:'var(--s2)',src:'History',k:'cf'},{n:'Google',c:'var(--s3)',src:'History',k:'google'}]}];
function nice(m){const p=Math.pow(10,Math.floor(Math.log10(m||1)));const f=m/p;return (f<=1?1:f<=2?2:f<=5?5:10)*p}
function draw(def){
 const now=Date.now(), from=now-range;
 const ser=def.series.map(s=>({...s,pts:(DATA[s.src]||[]).filter(r=>r.t>=from&&r[s.k]!=null).map(r=>[r.t,r[s.k]])})).filter(s=>s.pts.length);
 const box=$(def.id);
 const legend='<div class="legend">'+def.series.map(s=>`<span><i style="background:${s.c}"></i>${s.n}</span>`).join('')+'</div>';
 if(!ser.length){box.innerHTML='<h3>'+def.title+'</h3>'+legend+'<p class="empty">No data in this range yet. Run a Full test (or wait for automatic tests) to build the trend.</p>';return}
 if(table){const rows={};ser.forEach(s=>s.pts.forEach(p=>{(rows[p[0]]=rows[p[0]]||{})[s.n]=p[1]}));
  const ts=Object.keys(rows).sort((a,b)=>b-a).slice(0,60);
  box.innerHTML='<h3>'+def.title+'</h3><table><thead><tr><th>Time</th>'+ser.map(s=>'<th>'+s.n+'</th>').join('')+'</tr></thead><tbody>'+ts.map(t=>'<tr><td>'+fmtT(+t,1)+'</td>'+ser.map(s=>'<td>'+(rows[t][s.n]==null?'':rows[t][s.n])+'</td>').join('')+'</tr>').join('')+'</tbody></table>';return}
 const W=640,H=230,pl=44,pr=14,pt=10,pb=26;
 let t0=Infinity,t1=-Infinity,ym=0;ser.forEach(s=>s.pts.forEach(p=>{t0=Math.min(t0,p[0]);t1=Math.max(t1,p[0]);ym=Math.max(ym,p[1])}));
 if(t1-t0<600000){t0-=300000;t1+=300000}
 const ymax=nice(ym*1.1||1), X=t=>pl+(W-pl-pr)*(t-t0)/(t1-t0), Y=v=>pt+(H-pt-pb)*(1-v/ymax);
 let g='';for(let i=0;i<=4;i++){const v=ymax*i/4,y=Y(v);g+=`<line class="gl" x1="${pl}" x2="${W-pr}" y1="${y}" y2="${y}"/><text class="axis" x="${pl-6}" y="${y+4}" text-anchor="end">${+v.toFixed(1)}</text>`}
 for(let i=0;i<=3;i++){const t=t0+(t1-t0)*i/3;g+=`<text class="axis" x="${X(t)}" y="${H-6}" text-anchor="${i==0?'start':i==3?'end':'middle'}">${fmtT(t,(t1-t0)>864e5)}</text>`}
 ser.forEach(s=>{const pts=s.pts.sort((a,b)=>a[0]-b[0]);if(pts.length>1)g+=`<polyline fill="none" stroke="${s.c}" stroke-width="2" stroke-linejoin="round" points="${pts.map(p=>X(p[0])+','+Y(p[1])).join(' ')}"/>`;
  pts.forEach(p=>g+=`<circle cx="${X(p[0])}" cy="${Y(p[1])}" r="4" fill="${s.c}" stroke="var(--surface)" stroke-width="2"/>`)});
 box.innerHTML=`<h3>${def.title}</h3>${legend}<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="${def.title}">${g}<line id="${def.id}x" class="gl" y1="${pt}" y2="${H-pb}" style="display:none;stroke:var(--muted)"/><rect id="${def.id}r" x="${pl}" y="${pt}" width="${W-pl-pr}" height="${H-pt-pb}" fill="transparent"/></svg><div class="tip" id="${def.id}t"></div>`;
 const r=$(def.id+'r'),xl=$(def.id+'x'),tip=$(def.id+'t'),all=[...new Set(ser.flatMap(s=>s.pts.map(p=>p[0])))].sort((a,b)=>a-b);
 r.addEventListener('mousemove',e=>{const b=r.getBoundingClientRect(),sx=(e.clientX-b.left)/b.width*(W-pl-pr)+pl,tv=t0+(sx-pl)/(W-pl-pr)*(t1-t0);
  let best=all[0];all.forEach(t=>{if(Math.abs(t-tv)<Math.abs(best-tv))best=t});xl.setAttribute('x1',X(best));xl.setAttribute('x2',X(best));xl.style.display='';
  tip.innerHTML='<b>'+fmtT(best,1)+'</b><br>'+ser.map(s=>{const p=s.pts.find(q=>q[0]===best);return p?`<span style="color:${s.c}">&#9679;</span> ${s.n}: ${p[1]} ${def.unit}`:''}).filter(Boolean).join('<br>');
  tip.style.display='block';const bb=box.getBoundingClientRect();tip.style.left=Math.min(e.clientX-bb.left+12,bb.width-190)+'px';tip.style.top=(e.clientY-bb.top+12)+'px'});
 r.addEventListener('mouseleave',()=>{tip.style.display='none';xl.style.display='none'});
}
$('charts').innerHTML=defs.map(d=>`<div class="card chartbox" id="${d.id}"></div>`).join('');
function render(){defs.forEach(draw);[...$('tabs').querySelectorAll('button[data-r]')].forEach(b=>b.classList.toggle('on',+b.dataset.r===range));$('tog').textContent=table?'Show as chart':'Show as table'}
$('tabs').addEventListener('click',e=>{const b=e.target.closest('button');if(!b)return;if(b.id==='tog')table=!table;else if(b.dataset.r)range=+b.dataset.r;render()});
render();
</script></body></html>
'@
$html = $template.Replace('__DATA__', $dataJson).Replace('__GEN__', $payload.Generated)
[IO.File]::WriteAllText($HtmlFile, $html, (New-Object Text.UTF8Encoding($false)))
Say "Dashboard saved: $HtmlFile"
Write-Log 'dashboard built'
if (-not $NoOpen) { Start-Process $HtmlFile }
if ($Pause) { Read-Host 'Press Enter to close' }
exit 0
} catch {
    Write-Log "FAILED: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)"
    Say "Something went wrong: $($_.Exception.Message)"
    if ($Pause) { Read-Host 'Press Enter to close' }
    exit 1
} finally { try { $mutex.ReleaseMutex() } catch {} }
