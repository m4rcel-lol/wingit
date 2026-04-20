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

    $json = if ($Entries.Count -eq 0) {
        '[]'
    } else {
        @($Entries) | ConvertTo-Json -Depth 6
    }
    Set-Content -Path $path -Value $json -Encoding UTF8
}

function Get-RegistryEntry {
    <#
    .SYNOPSIS Returns a single registry entry for an owner/repo pair.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Owner,
        [Parameter(Mandatory)] [string] $Repo
    )

    return Read-Registry |
        Where-Object { $_.owner -eq $Owner -and $_.repo -eq $Repo } |
        Select-Object -First 1
}

function Get-PackagePathEntries {
    <#
    .SYNOPSIS Returns PATH entries associated with a package registry entry.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object] $Entry)

    $paths = @()
    if ($Entry.PSObject.Properties.Name -contains 'path_entries' -and $Entry.path_entries) {
        $paths += @($Entry.path_entries)
    }

    if ($paths.Count -eq 0 -and $Entry.install_path) {
        $paths += [System.IO.Path]::Combine($Entry.install_path, 'bin')
        $paths += $Entry.install_path
    }

    return @($paths | Where-Object { $_ } | Select-Object -Unique)
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
        [string] $AssetName   = '',
        [string] $Architecture = '',
        [bool] $IncludePrerelease = $false,
        [string[]] $PathEntries = @(),
        [object] $Pinned = $null
    )

    $entries = Read-Registry
    $existing = $entries | Where-Object { $_.owner -eq $Owner -and $_.repo -eq $Repo } | Select-Object -First 1
    # Remove any existing entry for this owner/repo
    $entries = @($entries | Where-Object { -not ($_.owner -eq $Owner -and $_.repo -eq $Repo) })

    $pinnedValue = if ($null -ne $Pinned) {
        [bool] $Pinned
    } elseif ($existing -and $existing.PSObject.Properties.Name -contains 'pinned') {
        [bool] $existing.pinned
    } else {
        $false
    }

    $newEntry = [PSCustomObject]@{
        owner        = $Owner
        repo         = $Repo
        version      = $Version
        install_type = $InstallType
        install_path = $InstallPath
        installed_at = ([datetime]::UtcNow.ToString('o'))
        asset_name   = $AssetName
        architecture = $Architecture
        include_prerelease = $IncludePrerelease
        path_entries = @($PathEntries | Where-Object { $_ } | Select-Object -Unique)
        pinned       = $pinnedValue
    }

    $entries += $newEntry
    Save-Registry -Entries $entries
}

function Set-PackagePinned {
    <#
    .SYNOPSIS Updates the pinned state for an installed package.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Owner,
        [Parameter(Mandatory)] [string] $Repo,
        [Parameter(Mandatory)] [bool] $Pinned
    )

    $entries = Read-Registry
    $updatedEntries = @()
    $updatedEntry = $null

    foreach ($entry in $entries) {
        if ($entry.owner -eq $Owner -and $entry.repo -eq $Repo) {
            $copy = $entry | Select-Object *
            if ($copy.PSObject.Properties.Name -contains 'pinned') {
                $copy.pinned = $Pinned
            } else {
                $copy | Add-Member -NotePropertyName 'pinned' -NotePropertyValue $Pinned
            }
            $updatedEntry = $copy
            $updatedEntries += $copy
        } else {
            $updatedEntries += $entry
        }
    }

    if (-not $updatedEntry) {
        Write-ErrorMsg "Package '$Owner/$Repo' is not installed via WinGit." -ExitCode 1
    }

    Save-Registry -Entries $updatedEntries
    return $updatedEntry
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
    $colVer     = 14
    $colType    = 10
    $colFlags   = 18
    $colDate    = 12

    $header = 'Package'.PadRight($colPkg) + 'Version'.PadRight($colVer) + 'Type'.PadRight($colType) + 'Flags'.PadRight($colFlags) + 'Installed'
    $divider = '-' * ($colPkg + $colVer + $colType + $colFlags + $colDate)

    Write-Host $header -ForegroundColor Cyan
    Write-Host $divider

    foreach ($e in $entries) {
        $pkg  = "$($e.owner)/$($e.repo)".PadRight($colPkg)
        $ver  = ($e.version -replace '^v','').PadRight($colVer)
        $type = $e.install_type.PadRight($colType)
        $flags = @()
        if ($e.PSObject.Properties.Name -contains 'pinned' -and $e.pinned) {
            $flags += 'pinned'
        }
        if ($e.PSObject.Properties.Name -contains 'include_prerelease' -and $e.include_prerelease) {
            $flags += 'pre'
        }
        if ($e.PSObject.Properties.Name -contains 'architecture' -and $e.architecture) {
            $flags += [string]$e.architecture
        }
        $flagText = if ($flags.Count -gt 0) { ($flags -join ',') } else { '-' }
        $flagCol = $flagText.PadRight($colFlags)
        $date = if ($e.installed_at) {
            ([datetime]::Parse($e.installed_at, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)).ToString('yyyy-MM-dd')
        } else { '?' }

        Write-Host "$pkg$ver$type$flagCol$date"
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

    $entry = Get-RegistryEntry -Owner $Owner -Repo $Repo

    if (-not $entry) {
        Write-ErrorMsg "Package '$Owner/$Repo' is not installed via WinGit." -ExitCode 1
    }

    Write-Phase 'Removing' "$Owner/$Repo..."
    $pathEntries = @(Get-PackagePathEntries -Entry $entry)

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

    foreach ($pathEntry in $pathEntries) {
        Remove-DirectoryFromSystemPath -Directory $pathEntry | Out-Null
    }

    Remove-RegistryEntry -Owner $Owner -Repo $Repo | Out-Null
    Write-Host ''
    Write-Host "Complete." -ForegroundColor Green
    Write-Host "  $Owner/$Repo has been removed." -ForegroundColor Gray
    Write-Host ''
}
