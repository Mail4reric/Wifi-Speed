@echo off
rem Runs the Micro Wi-Fi Full test (about 1 minute) and opens the dashboard.
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0WiFi-Analyzer.ps1" -Pause
