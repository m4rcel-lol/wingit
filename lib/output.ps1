<#
.SYNOPSIS
    Terminal output and formatting functions for WinGit.
.DESCRIPTION
    Provides rpm-ostree-style terminal output: phase headers, status lines,
    progress bars, spinners, and error/warning messages. Automatically detects
    Unicode support and falls back to ASCII equivalents when needed.
#>

$script:ColumnWidth   = 12
$script:SupportsAnsi  = ($env:WT_SESSION -or $env:TERM -eq 'xterm-256color' -or $env:TERM_PROGRAM -eq 'vscode')
$script:SupportsUnicode = $true
try {
    [System.Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {
    $script:SupportsUnicode = $false
}

function Get-CheckMark {
    <#
    .SYNOPSIS Returns a success symbol appropriate for the current terminal.
    #>
    if ($script:SupportsUnicode) { return [char]0x2713 } else { return '[OK]' }
}

function Get-CrossMark {
    <#
    .SYNOPSIS Returns a failure symbol appropriate for the current terminal.
    #>
    if ($script:SupportsUnicode) { return [char]0x2717 } else { return '[FAIL]' }
}

function Write-Header {
    <#
    .SYNOPSIS Writes the WinGit application header banner.
    #>
    Write-Host ''
    Write-Host 'WinGit  -- GitHub-native package manager for Windows' -ForegroundColor Cyan
    Write-Host ''
}

function Write-Phase {
    <#
    .SYNOPSIS Writes a left-aligned phase header padded to a fixed column width.
    .PARAMETER Label The phase name (e.g. 'Resolving', 'Downloading').
    .PARAMETER Detail The detail text following the label.
    #>
    param(
        [Parameter(Mandatory)] [string] $Label,
        [Parameter(Mandatory)] [string] $Detail
    )
    $padded = $Label.PadRight($script:ColumnWidth)
    Write-Host "$padded $Detail" -ForegroundColor White
}

function Write-SubItem {
    <#
    .SYNOPSIS Writes a 2-space-indented sub-item line under a phase header.
    .PARAMETER Key   Left-side label (padded to align values).
    .PARAMETER Value Right-side value.
    .PARAMETER Color Optional foreground color for the value.
    #>
    param(
        [Parameter(Mandatory)] [string] $Key,
        [string] $Value = '',
        [System.ConsoleColor] $Color = [System.ConsoleColor]::Gray
    )
    $padded = "  $Key".PadRight($script:ColumnWidth + 2)
    if ($Value) {
        Write-Host "$padded : " -NoNewline
        Write-Host $Value -ForegroundColor $Color
    } else {
        Write-Host $padded
    }
}

function Write-Action {
    <#
    .SYNOPSIS Writes a '-->' action step line (indented).
    .PARAMETER Message The action message.
    #>
    param([Parameter(Mandatory)] [string] $Message)
    Write-Host "  --> $Message" -ForegroundColor Yellow
}

function Write-Command {
    <#
    .SYNOPSIS Writes a '$ command' line showing a command being executed.
    .PARAMETER Command The command string.
    #>
    param([Parameter(Mandatory)] [string] $Command)
    Write-Host "  `$ $Command" -ForegroundColor DarkCyan
}

function Write-StatusOk {
    <#
    .SYNOPSIS Writes a tool/step name followed by a success checkmark.
    .PARAMETER Label The tool or step label.
    .PARAMETER Detail Optional extra detail (e.g. version).
    #>
    param(
        [Parameter(Mandatory)] [string] $Label,
        [string] $Detail = ''
    )
    $check = Get-CheckMark
    $padded = "  $Label".PadRight($script:ColumnWidth + 2)
    $suffix = if ($Detail) { " ($Detail)" } else { '' }
    Write-Host "$padded : " -NoNewline
    Write-Host "$check$suffix" -ForegroundColor Green
}

function Write-StatusFail {
    <#
    .SYNOPSIS Writes a tool/step name followed by a failure cross.
    .PARAMETER Label The tool or step label.
    .PARAMETER Detail Optional extra detail.
    #>
    param(
        [Parameter(Mandatory)] [string] $Label,
        [string] $Detail = ''
    )
    $cross = Get-CrossMark
    $padded = "  $Label".PadRight($script:ColumnWidth + 2)
    $suffix = if ($Detail) { " ($Detail)" } else { '' }
    Write-Host "$padded : " -NoNewline
    Write-Host "$cross$suffix" -ForegroundColor Red
}

function Write-StatusNotFound {
    <#
    .SYNOPSIS Writes a tool/step name followed by 'not found'.
    .PARAMETER Label The tool or step label.
    #>
    param([Parameter(Mandatory)] [string] $Label)
    $padded = "  $Label".PadRight($script:ColumnWidth + 2)
    Write-Host "$padded : " -NoNewline
    Write-Host 'not found' -ForegroundColor DarkYellow
}

function Write-StatusInstalled {
    <#
    .SYNOPSIS Writes a tool/step name followed by 'installed checkmark'.
    .PARAMETER Label The tool or step label.
    #>
    param([Parameter(Mandatory)] [string] $Label)
    $check = Get-CheckMark
    $padded = "  $Label".PadRight($script:ColumnWidth + 2)
    Write-Host "$padded : " -NoNewline
    Write-Host "installed $check" -ForegroundColor Green
}

function Write-ErrorMsg {
    <#
    .SYNOPSIS Writes a formatted error message and optionally exits.
    .PARAMETER Message The error message text.
    .PARAMETER ExitCode If provided, calls exit with this code after printing.
    #>
    param(
        [Parameter(Mandatory)] [string] $Message,
        [int] $ExitCode = -1
    )
    Write-Host "error: $Message" -ForegroundColor Red
    if ($ExitCode -ge 0) {
        exit $ExitCode
    }
}

function Write-WarnMsg {
    <#
    .SYNOPSIS Writes a formatted warning message.
    .PARAMETER Message The warning message text.
    #>
    param([Parameter(Mandatory)] [string] $Message)
    Write-Host "warn: $Message" -ForegroundColor DarkYellow
}

function Write-Complete {
    <#
    .SYNOPSIS Writes the final 'Complete.' footer block.
    .PARAMETER Package    The owner/repo string.
    .PARAMETER Version    Version string (optional).
    .PARAMETER InstallType 'release' or 'source'.
    .PARAMETER VerifyCmd  Command the user can run to verify (optional).
    #>
    param(
        [Parameter(Mandatory)] [string] $Package,
        [string] $Version = '',
        [string] $InstallType = 'release',
        [string] $VerifyCmd = ''
    )
    Write-Host ''
    Write-Host 'Complete.' -ForegroundColor Green
    $versionStr = if ($Version) { " $Version" } else { '' }
    $typeStr    = if ($InstallType -eq 'source') { ' (source build)' } else { '' }
    Write-Host "  $Package$versionStr$typeStr is now installed." -ForegroundColor Gray
    if ($VerifyCmd) {
        Write-Host "  Run '$VerifyCmd' to verify." -ForegroundColor Gray
    }
    Write-Host ''
}

function Write-Blank {
    <#
    .SYNOPSIS Writes a blank line.
    #>
    Write-Host ''
}

function Show-Spinner {
    <#
    .SYNOPSIS Displays an inline spinner for long-running operations.
    .PARAMETER ScriptBlock The work to perform while the spinner runs.
    .PARAMETER Message     The message to display beside the spinner.
    #>
    param(
        [Parameter(Mandatory)] [scriptblock] $ScriptBlock,
        [string] $Message = 'Working...'
    )
    $frames  = @('|', '/', '-', '\')
    $index   = 0
    $job     = Start-Job -ScriptBlock $ScriptBlock

    while ($job.State -eq 'Running') {
        $frame = $frames[$index % $frames.Length]
        Write-Host "`r  $frame $Message" -NoNewline
        $index++
        Start-Sleep -Milliseconds 120
    }
    Write-Host "`r  $(' ' * ($Message.Length + 4))`r" -NoNewline

    $result = Receive-Job -Job $job -Wait
    Remove-Job -Job $job -Force
    return $result
}

function Write-ProgressBar {
    <#
    .SYNOPSIS Writes an rpm-ostree-style download progress bar.
    .PARAMETER Current    Bytes downloaded so far.
    .PARAMETER Total      Total bytes to download.
    .PARAMETER SpeedBps   Current speed in bytes per second.
    .PARAMETER BarWidth   Width of the progress bar in characters.
    #>
    param(
        [Parameter(Mandatory)] [long]   $Current,
        [Parameter(Mandatory)] [long]   $Total,
        [long]   $SpeedBps = 0,
        [int]    $BarWidth = 45
    )
    if ($Total -le 0) { return }

    $pct      = [math]::Min(100, [int](($Current / $Total) * 100))
    $filled   = [math]::Floor($BarWidth * $pct / 100)
    $empty    = $BarWidth - $filled

    $bar = ('=' * [math]::Max(0, $filled - 1))
    if ($filled -gt 0 -and $pct -lt 100) { $bar += '>' }
    elseif ($filled -gt 0)               { $bar += '=' }
    $bar += (' ' * $empty)

    $speedStr = ''
    if ($SpeedBps -gt 0) {
        $speedStr = "  $(Format-Bytes $SpeedBps)/s"
    }

    $line = "  [$bar]  $($pct.ToString().PadLeft(3))%$speedStr"
    Write-Host "`r$line" -NoNewline
    if ($pct -ge 100) { Write-Host '' }
}

function Format-Bytes {
    <#
    .SYNOPSIS Formats a byte count as a human-readable string (KB, MB, GB).
    .PARAMETER Bytes The byte count.
    #>
    param([Parameter(Mandatory)] [long] $Bytes)
    if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N1} KB' -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Write-IndentedBlock {
    <#
    .SYNOPSIS Writes multi-line text with consistent 6-space indentation.
    .PARAMETER Text The text to indent (may contain newlines).
    #>
    param([Parameter(Mandatory)] [string] $Text)
    foreach ($line in ($Text -split "`n")) {
        Write-Host "      $($line.TrimEnd())"
    }
}
