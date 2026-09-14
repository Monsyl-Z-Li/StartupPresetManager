@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0..\src\StartupPresetManager_zh-CN.ps1"
