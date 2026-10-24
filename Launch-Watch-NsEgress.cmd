@echo off
rem NetSpeed Troubleshooter - launcher for Watch-NsEgress.ps1
rem Waits for a key at the end so the output stays on screen. /nopause skips that.
setlocal
set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "L_ARGS= %* "
set "L_PAUSE=1"
set "L_ASK=1"
echo.%L_ARGS%| find /i " /nopause " >nul && set "L_PAUSE="
echo.%L_ARGS%| find /i " /noelevate " >nul && set "L_ASK="
echo.%L_ARGS%| find /i " /elevated " >nul && set "L_ASK="
set "L_ARGS=%L_ARGS: /noelevate=%"
set "L_ARGS=%L_ARGS: /elevated=%"
set "L_ARGS=%L_ARGS: /nopause=%"
:run
"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Watch-NsEgress.ps1"%L_ARGS%
set "L_RC=%errorlevel%"
if defined L_PAUSE (echo. & pause)
endlocal & exit /b %L_RC%
