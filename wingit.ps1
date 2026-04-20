<#
.SYNOPSIS
    Compatibility shim that delegates to wingit-core.ps1.
.DESCRIPTION
    Kept for source-tree compatibility only. All real command handling lives in
    wingit-core.ps1 so PowerShell and CMD use the same implementation.
#>

param(
    [Parameter(Position = 0)] [string] $Command  = '',
    [Parameter(Position = 1)] [string] $Target   = '',
    [switch] $v,
    [Alias('version')] [switch] $ShowVersion,
    [Alias('help', 'h', '?')] [switch] $ShowHelp,
    [Parameter(ValueFromRemainingArguments)] [object[]] $ExtraArgs
)

$forwardArgs = @()
if ($Command) { $forwardArgs += $Command }
if ($Target) { $forwardArgs += $Target }
if ($v.IsPresent) { $forwardArgs += '-v' }
if ($ShowVersion) { $forwardArgs += '-version' }
if ($ShowHelp) { $forwardArgs += '-help' }
if ($ExtraArgs) {
    $forwardArgs += @($ExtraArgs | ForEach-Object { [string]$_ })
}

& (Join-Path $PSScriptRoot 'wingit-core.ps1') @forwardArgs
exit $LASTEXITCODE
