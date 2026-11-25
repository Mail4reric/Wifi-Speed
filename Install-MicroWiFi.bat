@echo off
rem Installs Micro Wi-Fi Guard for the current user (no administrator rights needed).
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Install-MicroWiFi.ps1" %*
