@echo off
rem Dry run of the 19:00 end-message automation. Opens the chat window but never sends.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\send_hiworks_end_message.ps1" -DryRun
echo.
echo exit code: %ERRORLEVEL%
pause
