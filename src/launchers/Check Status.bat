@echo off
setlocal
title Dome Keeper Mod Loader Enabler
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\DomeKeeperModLoader.ps1" -Action Status
set "EXIT_CODE=%ERRORLEVEL%"
echo.
pause
exit /b %EXIT_CODE%
