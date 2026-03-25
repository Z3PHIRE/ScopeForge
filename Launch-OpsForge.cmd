@echo off
setlocal
set "SCRIPT_DIR=%~dp0"

where pwsh >nul 2>nul
if errorlevel 1 (
    echo PowerShell 7 ^(pwsh^) est requis pour lancer OpsForge.
    echo Installe PowerShell 7 puis relance ce fichier.
    pause
    exit /b 1
)

pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Launch-OpsForge.ps1"
endlocal
