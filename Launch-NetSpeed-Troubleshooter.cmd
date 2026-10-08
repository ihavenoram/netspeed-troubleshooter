@echo off
REM ===========================================================================
REM  Internet / Network Speed Troubleshooter - launcher
REM
REM  -STA is REQUIRED. WinForms will not run reliably in a multi-threaded
REM  apartment, and the failure is intermittent rather than obvious.
REM
REM  -WindowStyle Hidden is deliberately NOT used here: it hides the form as
REM  well as the console. The script hides its own console window in-process
REM  instead. Pass -NoHideConsole if you want to see the console for debugging.
REM
REM  -ExecutionPolicy Bypass is kept only for this launcher, so the tool still
REM  runs on an unknown machine and on files carrying a mark-of-the-web.
REM
REM  powershell.exe is called by FULL PATH. cmd.exe searches the current folder
REM  before PATH, so a bare name would run a powershell.exe dropped beside this
REM  launcher - as SYSTEM, in a Backstage session.
REM ===========================================================================
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0NetSpeed-Troubleshooter-Gui.ps1" %*
if errorlevel 1 (
  echo.
  echo The troubleshooter exited with an error. Re-run with -NoHideConsole to see it:
  echo   "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -File "%~dp0NetSpeed-Troubleshooter-Gui.ps1" -NoHideConsole
  echo.
  pause
)
