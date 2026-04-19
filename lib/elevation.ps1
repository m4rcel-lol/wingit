<#
.SYNOPSIS
    Administrator privilege detection and elevation re-launch for WinGit.
.DESCRIPTION
    Detects whether the current process is running with administrator rights.
    If elevation is required for an operation, re-launches the full command
    in an elevated PowerShell window.
#>

function Test-IsAdministrator {
    <#
    .SYNOPSIS Returns $true if the current process is running as Administrator.
    #>
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Request-Elevation {
    <#
    .SYNOPSIS
        Re-launches the current wingit command in an elevated PowerShell window
        and exits the current non-elevated process.
    .PARAMETER ScriptPath   Full path to wingit.ps1.
    .PARAMETER Arguments    The original argument list to forward.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]   $ScriptPath,
        [Parameter(Mandatory)] [string[]] $Arguments
    )

    Write-WarnMsg 'This operation requires administrator privileges.'
    Write-WarnMsg 'Re-launching WinGit with elevated permissions...'

    $escapedArgs = $Arguments | ForEach-Object { "`"$_`"" }
    $argString   = $escapedArgs -join ' '

    Start-Process powershell.exe `
        -Verb RunAs `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" $argString" `
        -Wait

    exit 0
}

function Assert-Elevation {
    <#
    .SYNOPSIS
        Checks administrator status and re-launches elevated if needed.
        Call this before any operation that requires elevation.
    .PARAMETER ScriptPath Full path to wingit.ps1.
    .PARAMETER Arguments  The original argument list.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]   $ScriptPath,
        [Parameter(Mandatory)] [string[]] $Arguments
    )

    if (-not (Test-IsAdministrator)) {
        Request-Elevation -ScriptPath $ScriptPath -Arguments $Arguments
    }
}
