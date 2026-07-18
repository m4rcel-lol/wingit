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
    # Quote paths explicitly: Start-Process joins the argument list with spaces
    # and does not quote, so paths like "C:\Program Files\WinGit" would split.
    Start-Process powershell.exe `
        -Verb RunAs `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -InstallDir `"$InstallDir`""
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
    'wingit-core.ps1',
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
# Read/write the raw (unexpanded) value so existing %VARIABLE% entries in the
# machine PATH are preserved instead of being written back expanded.
$envKey  = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
    'SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $true)
$current = [string]$envKey.GetValue('Path', '',
    [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)

$entries = $current -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }

if ($entries -notcontains $InstallDir) {
    $newPath = (@($entries) + $InstallDir) -join ';'
    $envKey.SetValue('Path', $newPath, [Microsoft.Win32.RegistryValueKind]::ExpandString)
    $env:PATH = "$env:PATH;$InstallDir"
    Write-Host ''
    Write-Host ('  PATH   : updated - ' + $InstallDir + ' added.')

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

$envKey.Close()

Write-Host ''
Write-Host 'Complete.' -ForegroundColor Green
Write-Host '  WinGit is installed. Open a new terminal and run ''wingit --help''.' -ForegroundColor Gray
Write-Host ''
