<#
.SYNOPSIS
    WinGit self-installer — adds WinGit to the system PATH.
.DESCRIPTION
    Copies the WinGit files to %PROGRAMFILES%\WinGit and registers the
    install directory on the system PATH so that 'wingit' is available from
    any terminal session.
.NOTES
    Must be run with administrator privileges.
#>

[CmdletBinding()]
param(
    [string] $InstallDir = (Join-Path $env:PROGRAMFILES 'WinGit')
)

$ErrorActionPreference = 'Stop'

# ── Elevation check ──────────────────────────────────────────────────────────
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'warn: install.ps1 must be run as Administrator.' -ForegroundColor DarkYellow
    Write-Host '      Re-launching with elevated permissions...'
    Start-Process powershell.exe `
        -Verb RunAs `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-InstallDir', "`"$InstallDir`"")
    exit 0
}

# ── Source directory (where this script lives) ───────────────────────────────
$sourceDir = $PSScriptRoot

Write-Host ''
Write-Host 'WinGit Installer' -ForegroundColor Cyan
Write-Host ''
Write-Host "  Install directory : $InstallDir"
Write-Host ''

# ── Create install directory ─────────────────────────────────────────────────
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

# ── Copy files ───────────────────────────────────────────────────────────────
$filesToCopy = @(
    'wingit.ps1',
    'wingit.cmd'
)

foreach ($file in $filesToCopy) {
    $src = Join-Path $sourceDir $file
    $dst = Join-Path $InstallDir $file
    Copy-Item -Path $src -Destination $dst -Force
    Write-Host "  Copied : $file"
}

# Copy lib directory
$libSrc = Join-Path $sourceDir 'lib'
$libDst = Join-Path $InstallDir 'lib'
if (-not (Test-Path $libDst)) {
    New-Item -ItemType Directory -Path $libDst -Force | Out-Null
}
Get-ChildItem -Path $libSrc -Filter '*.ps1' | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination (Join-Path $libDst $_.Name) -Force
    Write-Host "  Copied : lib\$($_.Name)"
}

# ── Register on system PATH ───────────────────────────────────────────────────
$regKey  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
$current = (Get-ItemProperty -Path $regKey -Name 'Path').Path

$entries = $current -split ';' | Where-Object { $_ -ne '' }

if ($entries -notcontains $InstallDir) {
    $newPath = "$current;$InstallDir"
    Set-ItemProperty -Path $regKey -Name 'Path' -Value $newPath -Type ExpandString
    $env:PATH = "$env:PATH;$InstallDir"
    Write-Host ''
    Write-Host "  PATH   : updated — $InstallDir added."

    # Broadcast environment change to running processes
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class EnvBroadcast {
    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
    public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam,
        string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
}
'@
        $result = [UIntPtr]::Zero
        [EnvBroadcast]::SendMessageTimeout([IntPtr]0xffff, 0x1a, [UIntPtr]::Zero,
            'Environment', 0, 1000, [ref]$result) | Out-Null
    } catch {}
} else {
    Write-Host ''
    Write-Host "  PATH   : already contains $InstallDir (no change needed)."
}

Write-Host ''
Write-Host 'Complete.' -ForegroundColor Green
Write-Host "  WinGit is installed. Open a new terminal and run 'wingit --help'." -ForegroundColor Gray
Write-Host ''
