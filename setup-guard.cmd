@echo off
setlocal
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Requesting administrator rights...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

echo [1/3] Restarting Windows audio service...
powershell -NoProfile -Command "Restart-Service Audiosrv -Force"
if %errorlevel% neq 0 (echo    FAILED) else (echo    OK)

echo [2/3] Turning OFF USB selective suspend (AC + DC)...
powercfg /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0
powercfg /setdcvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0
powercfg /setactive SCHEME_CURRENT
echo    OK

echo [3/3] Installing audio guard scheduled task...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0guard-task.ps1" -Action install
echo.
echo ---- status ----
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0guard-task.ps1" -Action status

echo.
echo All done.
pause
