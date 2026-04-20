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

function Normalize-ForwardArguments {
    param([object[]] $Arguments = @())

    $normalized = [System.Collections.Generic.List[object]]::new()
    foreach ($argument in @($Arguments)) {
        $argumentText = [string]$argument
        if ([string]::IsNullOrWhiteSpace($argumentText)) {
            continue
        }
        $normalized.Add($argument) | Out-Null
    }

    if ($normalized.Count -gt 0) {
        return $normalized.ToArray()
    }

    return @()
}

$forwardArgs = @()
if ($Command) { $forwardArgs += $Command }
if ($Target) { $forwardArgs += $Target }
if ($v.IsPresent) { $forwardArgs += '-v' }
if ($ShowVersion) { $forwardArgs += '-version' }
if ($ShowHelp) { $forwardArgs += '-help' }
if ($ExtraArgs) {
    $forwardArgs += @(Normalize-ForwardArguments -Arguments ($ExtraArgs | ForEach-Object { [string]$_ }))
}

& (Join-Path $PSScriptRoot 'wingit-core.ps1') @forwardArgs
exit $LASTEXITCODE
