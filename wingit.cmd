@echo off
:: WinGit — CMD/PowerShell entry point
:: Delegates all logic to wingit.ps1 so the tool works identically from both
:: cmd.exe and powershell.exe without the user needing to type .\wingit.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0wingit.ps1" %*
