# Micro Wi-Fi Guard

A small always-on-top Windows widget with a talking character, **Micro**, that watches your Wi-Fi.
PowerShell 5.1 + WinForms. No installs, no administrator rights for normal use, everything stored locally in `MonitorData\`.
Nothing is uploaded anywhere (the only network traffic besides your own is the speed test to `speed.cloudflare.com`).

## What it does

- **Corner widget** - borderless, rounded, always on top, never steals focus. Drag it; it snaps to the nearest screen corner and remembers it.
  `Ctrl+Alt+W` shows/hides it; tray icon left-click toggles, right-click opens the menu. Header buttons: minimize, voice on/off, settings, speed test, expand, close.
- **Live numbers** - signal gauge, Wi-Fi name, band/channel, this PC's live download/upload, router ping, internet ping, 2-minute traffic graph.
- **Devices on your Wi-Fi** - DHCP listener (UDP 67), ARP poll every 3 s, /24 ping sweep every 20 s. Online/offline, last seen, the name a device announces, "private MAC" flag, name devices yourself.
- **New device alert** - a blue **New device (N)** button + one notification; open it to see a popup with Micro, the IP and announced name, **It's mine** / **Block...** (a PC cannot remove devices from Wi-Fi, so it copies the MAC and explains how to block it on the router). Optional auto-popup mode.
- **Speed alerts** - background tests with `curl.exe` bound to the Wi-Fi adapter. Slow alert after two slow tests 20 s apart (max once per 15 min); good-speed alert once a day / on recovery / every time / off. A refused (HTTP 403) test is reported as "refused", never "slow".
- **DNS Shield** - classifies every connected adapter's DNS (scam-filtering resolver / plain / router), tests that each answers, flags typos like `8.8.8.4`, re-checks every 10 minutes and warns when protection turns off. **Fix it** sets Cloudflare's scam filter (1.1.1.2 / 1.0.0.2) only after you click, confirm and approve the Windows admin prompt; **Back to automatic** undoes it.
- **Voice** - `mp3`/`wav` clips from `assets\`; Micro bounces with the loudness of the voice. Extra characters via `<name>.gif`.
- **Full test + dashboard** - `WiFi-Analyzer.ps1`: speed, latency (Cloudflare, Google, router), loss, signal/RSSI, band/channel, radio type, link rate, DNS lookup time, DNS Shield, traceroute. Saves `MonitorData\history.csv` and builds an offline `dashboard.html` with 24H/7D/30D charts, a bottleneck assessment and PASS/INFO/WARN diagnostics. The router's address is hidden.
- **Admin / User view** - the widget starts in *User view* (watch, speed test, voice, alerts). *Admin view* (PIN, auto-locks after 10 min) unlocks Settings, naming/blocking devices, DNS changes, Full test and dashboard. The PIN is a guard against casual changes on a shared PC, not protection against someone who can edit the files. To reset it, close the app and delete `AdminPinHash` / `AdminPinSalt` from `MonitorData\settings.json`.
- **Start with Windows** - a shortcut in your Startup folder (no admin, no registry), waits 45 s for Wi-Fi at sign-in. On by default; turn it off in Settings.

## Run from source

1. Put the folder anywhere you can write to.
2. Double-click `Start-Floating-Widget.bat` (widget) or `Run-WiFi-Analyzer.bat` (Full test + dashboard).

Requires Windows 10/11 with Windows PowerShell 5.1 (built in) and `curl.exe` (built in since Windows 10 1803).
Windows Firewall may ask about PowerShell once; allow private networks so the DHCP listener can see device names.

## Install on other PCs

```powershell
.\Build-Installer.ps1          # -> dist\MicroWiFiGuard-Setup-<version>.exe
```

The setup is a per-user installer (installs to `%LOCALAPPDATA%\MicroWiFiGuard`, no admin needed, Start Menu + optional Desktop shortcut, uninstall entry in *Apps & features*).
It is built with the C# compiler that already ships with Windows, so nothing extra has to be installed to build or to run it.
Unattended: `MicroWiFiGuard-Setup-1.0.0.exe /silent` (optionally `/dir="D:\Micro"`); uninstall: `setup.exe /uninstall /quiet`.
The exe is **not code-signed**. Windows SmartScreen may show "unknown publisher" (choose *More info -> Run anyway*), and PCs with Windows 11 **Smart App Control**, AppLocker or WDAC will block it outright ("An Application Control policy has blocked this file").
On those PCs use the script installer instead - it does the same thing and runs as a normal PowerShell script:

```powershell
.\Install-MicroWiFi.bat                        # or: .\Install-MicroWiFi.ps1 [-Silent] [-Dir "D:\Micro"] [-NoDesktop] [-NoStartup]
.\Install-MicroWiFi.ps1 -Uninstall [-Silent] [-KeepData]
```

To get rid of the warning entirely, code-sign the exe with a certificate your organisation trusts.

## Files

| File | Purpose |
|---|---|
| `Micro-WiFi.ps1` | the widget |
| `WiFi-Analyzer.ps1` | Full test + dashboard |
| `Start-Floating-Widget.bat`, `Run-WiFi-Analyzer.bat` | launchers |
| `installer\Installer.cs`, `Build-Installer.ps1` | installer source and build script |
| `assets\` | your GIFs and voice clips (see `assets\README.md`) |
| `MonitorData\` | created at run time: settings, devices, logs, history, dashboard (git-ignored) |

## Privacy

Device names, MAC addresses, history and your PIN hash stay in `MonitorData\` on your PC and are never committed (`.gitignore`) or uploaded.
