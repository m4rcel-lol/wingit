<#
.SYNOPSIS
    Package registry read/write functions for WinGit.
.DESCRIPTION
    Maintains a JSON registry at %PROGRAMDATA%\WinGit\registry.json that
    records every package installed by WinGit.
#>

function Get-RegistryPath {
    <#
    .SYNOPSIS Returns the full path to the WinGit registry file.
    #>
    $dir = [System.IO.Path]::Combine($env:PROGRAMDATA, 'WinGit')
    return [System.IO.Path]::Combine($dir, 'registry.json')
}

function Read-Registry {
    <#
    .SYNOPSIS Reads and returns the registry as a list of package objects.
    .OUTPUTS  Array of package hashtables (may be empty).
    #>
    [CmdletBinding()]
    param()

    $path = Get-RegistryPath
    if (-not (Test-Path $path)) { return @() }

    try {
        $content = Get-Content -Path $path -Raw -Encoding UTF8
        $parsed  = $content | ConvertFrom-Json
        # ConvertFrom-Json returns a PSCustomObject array; normalise to list
        return @($parsed)
    } catch {
        Write-WarnMsg "Could not read registry file '$path': $($_.Exception.Message)"
        return @()
    }
}

function Save-Registry {
    <#
    .SYNOPSIS Serialises and saves the registry list to disk.
    .PARAMETER Entries Array of package entry objects to save.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object[]] $Entries)

    $path = Get-RegistryPath
    $dir  = [System.IO.Path]::GetDirectoryName($path)

    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $json = $Entries | ConvertTo-Json -Depth 5
    Set-Content -Path $path -Value $json -Encoding UTF8
}

function Add-RegistryEntry {
    <#
    .SYNOPSIS
        Adds or updates a package entry in the registry.
    .PARAMETER Owner       Repository owner.
    .PARAMETER Repo        Repository name.
    .PARAMETER Version     Package version string.
    .PARAMETER InstallType 'release' or 'source'.
    .PARAMETER InstallPath Absolute path where the package was installed.
    .PARAMETER AssetName   For release installs: the asset filename.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Owner,
        [Parameter(Mandatory)] [string] $Repo,
        [string] $Version     = '',
        [string] $InstallType = 'release',
        [string] $InstallPath = '',
        [string] $AssetName   = ''
    )

    $entries = Read-Registry
    # Remove any existing entry for this owner/repo
    $entries = @($entries | Where-Object { -not ($_.owner -eq $Owner -and $_.repo -eq $Repo) })

    $newEntry = [PSCustomObject]@{
        owner        = $Owner
        repo         = $Repo
        version      = $Version
        install_type = $InstallType
        install_path = $InstallPath
        installed_at = ([datetime]::UtcNow.ToString('o'))
        asset_name   = $AssetName
    }

    $entries += $newEntry
    Save-Registry -Entries $entries
}

function Remove-RegistryEntry {
    <#
    .SYNOPSIS Removes a package entry from the registry.
    .PARAMETER Owner Repository owner.
    .PARAMETER Repo  Repository name.
    .OUTPUTS   The removed entry object, or $null if not found.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Owner,
        [Parameter(Mandatory)] [string] $Repo
    )

    $entries = Read-Registry
    $target  = $entries | Where-Object { $_.owner -eq $Owner -and $_.repo -eq $Repo } | Select-Object -First 1

    if (-not $target) { return $null }

    $entries = @($entries | Where-Object { -not ($_.owner -eq $Owner -and $_.repo -eq $Repo) })
    Save-Registry -Entries $entries
    return $target
}

function Show-InstalledPackages {
    <#
    .SYNOPSIS Displays a formatted table of all packages installed by WinGit.
    #>
    [CmdletBinding()]
    param()

    $entries = Read-Registry

    if (-not $entries -or $entries.Count -eq 0) {
        Write-Host 'No packages installed by WinGit.' -ForegroundColor DarkGray
        return
    }

    $colPkg     = 30
    $colVer     = 12
    $colType    = 10
    $colDate    = 12

    $header = 'Package'.PadRight($colPkg) + 'Version'.PadRight($colVer) + 'Type'.PadRight($colType) + 'Installed'
    $divider = '-' * ($colPkg + $colVer + $colType + $colDate)

    Write-Host $header -ForegroundColor Cyan
    Write-Host $divider

    foreach ($e in $entries) {
        $pkg  = "$($e.owner)/$($e.repo)".PadRight($colPkg)
        $ver  = ($e.version -replace '^v','').PadRight($colVer)
        $type = $e.install_type.PadRight($colType)
        $date = if ($e.installed_at) {
            ([datetime]::Parse($e.installed_at, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)).ToString('yyyy-MM-dd')
        } else { '?' }

        Write-Host "$pkg$ver$type$date"
    }

    Write-Host ''
}

function Invoke-RemovePackage {
    <#
    .SYNOPSIS
        Removes a WinGit-installed package: uninstalls files and removes the
        registry entry.
    .PARAMETER Owner Repository owner.
    .PARAMETER Repo  Repository name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Owner,
        [Parameter(Mandatory)] [string] $Repo
    )

    $entry = Read-Registry | Where-Object { $_.owner -eq $Owner -and $_.repo -eq $Repo } | Select-Object -First 1

    if (-not $entry) {
        Write-ErrorMsg "Package '$Owner/$Repo' is not installed via WinGit." -ExitCode 1
    }

    Write-Phase 'Removing' "$Owner/$Repo..."

    # Try to run an uninstaller if found
    if ($entry.install_path -and (Test-Path $entry.install_path)) {
        $uninstallers = Get-ChildItem -Path $entry.install_path -Filter 'uninst*.exe' -Recurse -ErrorAction SilentlyContinue |
                        Select-Object -First 1
        if ($uninstallers) {
            Write-Action "Running uninstaller: $($uninstallers.FullName)"
            Start-Process -FilePath $uninstallers.FullName -ArgumentList '/S' -Wait
        } else {
            Write-SubItem 'Deleting' $entry.install_path
            Remove-Item -Path $entry.install_path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Remove-RegistryEntry -Owner $Owner -Repo $Repo | Out-Null
    Write-Host ''
    Write-Host "Complete." -ForegroundColor Green
    Write-Host "  $Owner/$Repo has been removed." -ForegroundColor Gray
    Write-Host ''
}
