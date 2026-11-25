@echo off
rem Starts the Micro Wi-Fi widget with no console window.
start "" /b powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Micro-WiFi.ps1"
