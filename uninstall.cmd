@echo off
rem Double-click me to remove TermNotify.
rem I'm just a helper button: I open PowerShell and ask it to run
rem uninstall.ps1 (the real uninstaller), which lives in the same folder as me.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1"
rem Wait for you to press a key, so the window doesn't vanish before you can read it.
pause
