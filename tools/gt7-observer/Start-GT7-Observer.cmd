@echo off
setlocal
where.exe pwsh >nul 2>&1
if not errorlevel 1 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0Watch-GT7.ps1" %*
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Watch-GT7.ps1" %*
)
exit /b %errorlevel%
