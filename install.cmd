@echo off
rem Double-click me to install TermNotify!
rem I'm just a helper button: I open PowerShell and ask it to run
rem install.ps1 (the real installer), which lives in the same folder as me.
rem "-ExecutionPolicy Bypass" means "it's OK to run this one script".
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
rem Wait for you to press a key, so the window doesn't vanish before you can read it.
pause
