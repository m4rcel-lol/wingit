<#
.SYNOPSIS
    WinGit — GitHub-native package manager for Windows.
.DESCRIPTION
    Installs software directly from GitHub repositories: downloads the latest
    release binary when available, or clones the source and builds it locally.
.EXAMPLE
    wingit install cli/cli
.EXAMPLE
    wingit list
.EXAMPLE
    wingit update cli/cli
.EXAMPLE
    wingit remove cli/cli
#>

param(
    [Parameter(Position = 0)] [string] $Command  = '',
    [Parameter(Position = 1)] [string] $Target   = '',
    [switch] $v,
    [Parameter(ValueFromRemainingArguments)] [object[]] $ExtraArgs
)

$ErrorActionPreference = 'Stop'

# Normalize: PowerShell 7 binds double-dash args (--version, --help) to
# $ExtraArgs rather than to $Command when [CmdletBinding()] is active.
# Merge them back so the switch works identically on PS 5.1 and PS 7+.
# Also detect -v / --verbose in ExtraArgs.
$script:VerboseMode = $v.IsPresent

if ($ExtraArgs -and $ExtraArgs.Count -gt 0) {
    $filteredArgs = [System.Collections.Generic.List[object]]::new()
    foreach ($arg in $ExtraArgs) {
        $argStr = [string]$arg
        if ($argStr -eq '-v' -or $argStr -eq '--verbose') {
            $script:VerboseMode = $true
        } else {
            $filteredArgs.Add($arg)
        }
    }
    $ExtraArgs = if ($filteredArgs.Count -gt 0) { $filteredArgs.ToArray() } else { @() }
}

if (-not $Command -and $ExtraArgs -and $ExtraArgs.Count -gt 0) {
    $Command  = [string]$ExtraArgs[0]
    $Target   = if ($ExtraArgs.Count -gt 1) { [string]$ExtraArgs[1] } else { '' }
    $ExtraArgs = if ($ExtraArgs.Count -gt 2) { $ExtraArgs[2..($ExtraArgs.Count-1)] } else { @() }
}

# If Command is set but Target is still empty, check if ExtraArgs has a positional value
# (e.g. 'wingit update --all' binds '--all' to ExtraArgs, not to $Target position)
if ($Command -and -not $Target -and $ExtraArgs -and $ExtraArgs.Count -gt 0) {
    $Target    = [string]$ExtraArgs[0]
    $ExtraArgs = if ($ExtraArgs.Count -gt 1) { $ExtraArgs[1..($ExtraArgs.Count-1)] } else { @() }
}

# ── Load library modules ────────────────────────────────────────────────────
$libDir = [System.IO.Path]::Combine($PSScriptRoot, 'lib')

. "$libDir\output.ps1"
. "$libDir\api.ps1"
. "$libDir\download.ps1"
. "$libDir\tools.ps1"
. "$libDir\build.ps1"
. "$libDir\registry.ps1"
. "$libDir\elevation.ps1"

# ── Version ─────────────────────────────────────────────────────────────────
$script:Version = '1.1.0'

# ── Ctrl+C handler ──────────────────────────────────────────────────────────
# Do not treat Ctrl+C as regular input; let PowerShell handle it normally.
[Console]::TreatControlCAsInput = $false

# ── Helper: parse owner/repo ─────────────────────────────────────────────────
function Resolve-OwnerRepo {
    param([Parameter(Mandatory)] [string] $PackageTarget)

    if ($PackageTarget -match '^([A-Za-z0-9_.\-]+)/([A-Za-z0-9_.\-]+)$') {
        return @{ Owner = $Matches[1]; Repo = $Matches[2] }
    }
    Write-ErrorMsg "Invalid target format '$PackageTarget'. Expected: <owner>/<repo>" -ExitCode 1
}

# ── Subcommand: install ───────────────────────────────────────────────────────
function Invoke-Install {
    param([Parameter(Mandatory)] [string] $PackageTarget)

    $parsed = Resolve-OwnerRepo -PackageTarget $PackageTarget
    $owner  = $parsed.Owner
    $repo   = $parsed.Repo

    Write-Header

    # ── Phase 1: Repository validation ──────────────────────────────────────
    Write-Phase 'Resolving' "$owner/$repo..."
    Write-Trace "GET https://api.github.com/repos/$owner/$repo"

    $repoInfo = Get-RepoInfo -Owner $owner -Repo $repo
    if (-not $repoInfo) {
        Write-ErrorMsg "Repository '$owner/$repo' not found on GitHub." -ExitCode 1
    }

    $stars    = if ($repoInfo.stargazers_count) { '{0:N0}' -f $repoInfo.stargazers_count } else { '0' }
    $language = if ($repoInfo.language)         { $repoInfo.language }                     else { 'Unknown' }

    Write-SubItem 'Repository' "https://github.com/$owner/$repo"
    Write-SubItem 'Stars'      $stars
    Write-SubItem 'Language'   $language
    if ($repoInfo.description) {
        Write-SubItem 'About' $repoInfo.description
    }
    Write-Blank

    # ── Phase 1b: Release detection ─────────────────────────────────────────
    Write-Phase 'Checking' 'releases...'
    Write-Trace "GET https://api.github.com/repos/$owner/$repo/releases/latest"

    $release    = Get-LatestRelease -Owner $owner -Repo $repo
    $assetToUse = $null

    if ($release -and $release.assets -and $release.assets.Count -gt 0) {
        Write-Trace "Found $($release.assets.Count) release asset(s); selecting best Windows match"
        $assetToUse = Select-WindowsAsset -Assets $release.assets
    }

    if ($assetToUse) {
        $tagName  = $release.tag_name
        $sizeStr  = Format-Bytes -Bytes $assetToUse.size
        Write-SubItem 'Latest'  "$tagName  ($($release.published_at -replace 'T.*',''))"
        Write-SubItem 'Asset'   "$($assetToUse.name)  ($sizeStr)"
        Write-Blank

        Assert-Elevation -ScriptPath $PSCommandPath -Arguments @('install', $PackageTarget)
        Invoke-ReleaseInstall -Owner $owner -Repo $repo -Release $release -Asset $assetToUse

    } else {
        if ($release) {
            Write-Host 'no suitable Windows binary found.' -ForegroundColor DarkYellow
        } else {
            Write-Host 'no releases found.' -ForegroundColor DarkYellow
        }
        Write-Blank

        Assert-Elevation -ScriptPath $PSCommandPath -Arguments @('install', $PackageTarget)
        Invoke-SourceInstall -Owner $owner -Repo $repo -DefaultBranch $repoInfo.default_branch
    }
}

# ── Release install flow ──────────────────────────────────────────────────────
function Invoke-ReleaseInstall {
    param(
        [string] $Owner,
        [string] $Repo,
        [object] $Release,
        [object] $Asset
    )

    $downloadDir  = [System.IO.Path]::Combine($env:TEMP, 'wingit', $Repo)
    $downloadPath = [System.IO.Path]::Combine($downloadDir, $Asset.name)

    Write-Phase 'Downloading' $Asset.name
    Write-Trace "URL: $($Asset.browser_download_url)"
    Write-Trace "Destination: $downloadPath"
    Invoke-Download -Url $Asset.browser_download_url -Destination $downloadPath
    Write-Blank

    Write-Phase 'Installing' $Asset.name
    $installDir = [System.IO.Path]::Combine($env:PROGRAMFILES, 'WinGit', 'packages', "$Owner-$Repo")
    Write-Trace "Install directory: $installDir"

    $ext     = $Asset.name.ToLower()
    $success = $false

    try {
        if ($ext.EndsWith('.msi')) {
            Write-SubItem 'Method' 'msiexec /quiet'
            $proc = Start-Process 'msiexec.exe' `
                -ArgumentList "/i `"$downloadPath`" /quiet /norestart" `
                -Wait -PassThru
            if ($proc.ExitCode -ne 0) { throw "msiexec exited with code $($proc.ExitCode)" }
            $success = $true

        } elseif ($ext.EndsWith('.exe')) {
            $silentFlags = @('/S', '/silent', '/quiet', '/install')
            foreach ($flag in $silentFlags) {
                Write-SubItem 'Method' "silent ($flag)"
                $proc = Start-Process $downloadPath -ArgumentList $flag -Wait -PassThru -ErrorAction SilentlyContinue
                if ($proc -and $proc.ExitCode -eq 0) { $success = $true; break }
            }
            if (-not $success) {
                Write-WarnMsg "Silent install failed; launching installer interactively."
                $proc = Start-Process $downloadPath -Wait -PassThru
                $success = ($proc.ExitCode -eq 0)
            }

        } elseif ($ext.EndsWith('.zip') -or $ext.EndsWith('.tar.gz')) {
            Write-SubItem 'Method' "extract to $installDir"
            if (-not (Test-Path $installDir)) {
                New-Item -ItemType Directory -Path $installDir -Force | Out-Null
            }
            Expand-Archive-Compat -ArchivePath $downloadPath -Destination $installDir

            # Try to find and run an installer inside the archive
            $innerInstaller = Get-ChildItem -Path $installDir -Include '*.msi','*.exe' -Recurse |
                              Select-Object -First 1
            if ($innerInstaller) {
                Write-SubItem 'Running' $innerInstaller.Name
                if ($innerInstaller.Extension -eq '.msi') {
                    Start-Process 'msiexec.exe' -ArgumentList "/i `"$($innerInstaller.FullName)`" /quiet /norestart" -Wait
                } else {
                    Start-Process $innerInstaller.FullName -ArgumentList '/S' -Wait
                }
            } else {
                # No installer found — add extract dir to system PATH
                $binDir = [System.IO.Path]::Combine($installDir, 'bin')
                $pathToAdd = if (Test-Path $binDir) { $binDir } else { $installDir }
                Add-DirectoryToSystemPath -Directory $pathToAdd
            }
            $success = $true
        }
    } catch {
        Write-ErrorMsg "Installation failed: $($_.Exception.Message)"
        Write-WarnMsg  "Downloaded file preserved at: $downloadPath"
        exit 1
    }

    if (-not $success) {
        Write-ErrorMsg 'Installation failed.' -ExitCode 1
    }

    # Record in registry
    Add-RegistryEntry -Owner $Owner -Repo $Repo `
        -Version $Release.tag_name -InstallType 'release' `
        -InstallPath $installDir -AssetName $Asset.name

    # Cleanup temp files
    Remove-Item -Path $downloadPath -Force -ErrorAction SilentlyContinue

    Write-Complete -Package "$Owner/$Repo" -Version $Release.tag_name -InstallType 'release'
}

# ── Source build flow ─────────────────────────────────────────────────────────
function Invoke-SourceInstall {
    param(
        [string] $Owner,
        [string] $Repo,
        [string] $DefaultBranch = 'main'
    )

    $srcDir    = [System.IO.Path]::Combine($env:TEMP, 'wingit', "$Repo-src")
    $installDir = [System.IO.Path]::Combine($env:PROGRAMFILES, 'WinGit', 'packages', "$Owner-$Repo")

    Write-Phase 'Fetching' 'source...'

    if (Test-ToolOnPath 'git') {
        $cloneUrl = "https://github.com/$Owner/$Repo.git"
        Write-SubItem 'Cloning' "$cloneUrl  ->  $srcDir"
        Write-Trace "git clone --depth=1 $cloneUrl $srcDir"
        # Temporarily lower ErrorActionPreference so that git's informational
        # stderr lines (e.g. "Cloning into '...'") do not raise a
        # NativeCommandError and terminate the script under PS 5.1.
        $savedPref = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & git clone --depth=1 $cloneUrl $srcDir 2>&1 | ForEach-Object { Write-Host "  $_" }
        $cloneExit = $LASTEXITCODE
        $ErrorActionPreference = $savedPref
        if ($cloneExit -ne 0) { Write-ErrorMsg "git clone failed." -ExitCode 1 }
    } else {
        # Fallback: download zip archive. Use the repo's default branch.
        $zipUrl  = "https://github.com/$Owner/$Repo/archive/refs/heads/$DefaultBranch.zip"
        $zipPath = [System.IO.Path]::Combine($env:TEMP, 'wingit', "$Repo-src.zip")

        Write-SubItem 'Downloading' $zipUrl
        Write-Trace "Destination: $zipPath"
        try {
            Invoke-Download -Url $zipUrl -Destination $zipPath
        } catch {
            # Fall back to the other common default branch name
            $fallback = if ($DefaultBranch -eq 'main') { 'master' } else { 'main' }
            $zipUrl   = "https://github.com/$Owner/$Repo/archive/refs/heads/$fallback.zip"
            Write-SubItem 'Retrying' $zipUrl
            Invoke-Download -Url $zipUrl -Destination $zipPath
        }

        Write-SubItem 'Extracting' $zipPath
        $extractTemp = [System.IO.Path]::Combine($env:TEMP, 'wingit', "$Repo-extract")
        Expand-Archive-Compat -ArchivePath $zipPath -Destination $extractTemp

        # GitHub zip archives contain a top-level directory like repo-main/
        $innerDir = Get-ChildItem -Path $extractTemp -Directory | Select-Object -First 1
        if ($innerDir) {
            Move-Item -Path $innerDir.FullName -Destination $srcDir -Force
        } else {
            $srcDir = $extractTemp
        }

        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    }

    Write-Blank

    Invoke-SourceBuild -Owner $Owner -Repo $Repo -SourceDir $srcDir -InstallDir $installDir

    Add-RegistryEntry -Owner $Owner -Repo $Repo `
        -Version 'source' -InstallType 'source' `
        -InstallPath $installDir

    Write-Complete -Package "$Owner/$Repo" -InstallType 'source'
}

# ── Subcommand: update ────────────────────────────────────────────────────────
function Invoke-Update {
    param([string] $PackageTarget)

    Write-Header

    if ($PackageTarget -eq '--all' -or $PackageTarget -eq '-a') {
        # Update all installed packages
        $entries = Read-Registry
        if (-not $entries -or $entries.Count -eq 0) {
            Write-Host 'No packages installed by WinGit.' -ForegroundColor DarkGray
            return
        }
        Write-Phase 'Updating' "all $($entries.Count) installed package(s)..."
        Write-Blank

        $updated = 0
        $upToDate = 0
        $failed = 0

        foreach ($entry in $entries) {
            $pkg = "$($entry.owner)/$($entry.repo)"
            Write-Phase 'Checking' "$pkg..."
            $result = Update-SinglePackage -Owner $entry.owner -Repo $entry.repo -CurrentVersion $entry.version -InstallType $entry.install_type
            switch ($result) {
                'updated'   { $updated++   }
                'uptodate'  { $upToDate++  }
                'failed'    { $failed++    }
            }
            Write-Blank
        }

        Write-Host 'Update summary:' -ForegroundColor Cyan
        if ($updated -gt 0)   { Write-Host "  $updated package(s) updated."    -ForegroundColor Green }
        if ($upToDate -gt 0)  { Write-Host "  $upToDate package(s) up to date." -ForegroundColor Gray }
        if ($failed -gt 0)    { Write-Host "  $failed package(s) failed."       -ForegroundColor Red }
        Write-Blank
        return
    }

    if (-not $PackageTarget) {
        Write-ErrorMsg "Missing target. Usage: wingit update <owner>/<repo>  or  wingit update --all" -ExitCode 1
    }

    $parsed = Resolve-OwnerRepo -PackageTarget $PackageTarget
    Write-Phase 'Updating' "$($parsed.Owner)/$($parsed.Repo)..."

    $entry = Read-Registry | Where-Object { $_.owner -eq $parsed.Owner -and $_.repo -eq $parsed.Repo } | Select-Object -First 1
    $currentVersion = if ($entry) { $entry.version } else { $null }
    $installType    = if ($entry) { $entry.install_type } else { $null }

    if (-not $entry) {
        Write-WarnMsg "'$PackageTarget' is not in the WinGit registry. Running fresh install..."
        Write-Blank
    }

    Assert-Elevation -ScriptPath $PSCommandPath -Arguments @('update', $PackageTarget)
    $result = Update-SinglePackage -Owner $parsed.Owner -Repo $parsed.Repo -CurrentVersion $currentVersion -InstallType $installType
    if ($result -eq 'uptodate') {
        Write-Host ''
        Write-Host 'Already up to date.' -ForegroundColor Green
        Write-Host ''
    }
}

function Update-SinglePackage {
    <#
    .SYNOPSIS Checks for and applies an update for one package. Returns 'updated', 'uptodate', or 'failed'.
    #>
    param(
        [Parameter(Mandatory)] [string] $Owner,
        [Parameter(Mandatory)] [string] $Repo,
        [string] $CurrentVersion = '',
        [string] $InstallType    = ''
    )

    try {
        Write-Trace "GET https://api.github.com/repos/$Owner/$Repo/releases/latest"
        $release = Get-LatestRelease -Owner $Owner -Repo $Repo

        if ($InstallType -eq 'source' -or (-not $release)) {
            # Source installs: always re-fetch and rebuild
            Write-SubItem 'Type'    'source build'
            Write-SubItem 'Action' 're-building from latest source'
            $repoInfo = Get-RepoInfo -Owner $Owner -Repo $Repo
            Invoke-SourceInstall -Owner $Owner -Repo $Repo -DefaultBranch ($repoInfo.default_branch)
            return 'updated'
        }

        $latestTag = $release.tag_name
        Write-SubItem 'Installed' $(if ($CurrentVersion) { $CurrentVersion } else { '(unknown)' })
        Write-SubItem 'Latest'    $latestTag

        if ($CurrentVersion -and $CurrentVersion -eq $latestTag) {
            Write-Trace "$Owner/$Repo is already at $latestTag"
            return 'uptodate'
        }

        $assetToUse = $null
        if ($release.assets -and $release.assets.Count -gt 0) {
            $assetToUse = Select-WindowsAsset -Assets $release.assets
        }

        if ($assetToUse) {
            Write-SubItem 'Asset'  "$($assetToUse.name)  ($(Format-Bytes -Bytes $assetToUse.size))"
            Write-Blank
            Invoke-ReleaseInstall -Owner $Owner -Repo $Repo -Release $release -Asset $assetToUse
        } else {
            Write-Blank
            $repoInfo = Get-RepoInfo -Owner $Owner -Repo $Repo
            Invoke-SourceInstall -Owner $Owner -Repo $Repo -DefaultBranch ($repoInfo.default_branch)
        }
        return 'updated'

    } catch {
        Write-WarnMsg "Update failed for $Owner/$Repo`: $($_.Exception.Message)"
        return 'failed'
    }
}

# ── Subcommand: info ──────────────────────────────────────────────────────────
function Invoke-Info {
    param([Parameter(Mandatory)] [string] $PackageTarget)

    $parsed = Resolve-OwnerRepo -PackageTarget $PackageTarget
    $owner  = $parsed.Owner
    $repo   = $parsed.Repo

    Write-Header
    Write-Phase 'Info' "$owner/$repo"
    Write-Blank

    # Registry entry
    $entry = Read-Registry | Where-Object { $_.owner -eq $owner -and $_.repo -eq $repo } | Select-Object -First 1
    if ($entry) {
        Write-Host '  Installed (WinGit registry):' -ForegroundColor Cyan
        $ver  = if ($entry.version) { $entry.version } else { 'unknown' }
        $type = if ($entry.install_type) { $entry.install_type } else { 'unknown' }
        $date = if ($entry.installed_at) {
            ([datetime]::Parse($entry.installed_at, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)).ToString('yyyy-MM-dd HH:mm') + ' UTC'
        } else { 'unknown' }
        Write-SubItem 'Version'      $ver
        Write-SubItem 'Install type' $type
        Write-SubItem 'Installed at' $date
        if ($entry.install_path) {
            Write-SubItem 'Install path' $entry.install_path
        }
        if ($entry.asset_name) {
            Write-SubItem 'Asset' $entry.asset_name
        }
    } else {
        Write-Host '  Not installed via WinGit.' -ForegroundColor DarkGray
    }

    Write-Blank
    Write-Host '  GitHub:' -ForegroundColor Cyan
    Write-Trace "GET https://api.github.com/repos/$owner/$repo"

    $repoInfo = Get-RepoInfo -Owner $owner -Repo $repo
    if ($repoInfo) {
        $stars   = if ($repoInfo.stargazers_count) { '{0:N0}' -f $repoInfo.stargazers_count } else { '0' }
        $forks   = if ($repoInfo.forks_count)      { '{0:N0}' -f $repoInfo.forks_count }      else { '0' }
        $lang    = if ($repoInfo.language)          { $repoInfo.language }                      else { 'Unknown' }
        $license = if ($repoInfo.license -and $repoInfo.license.spdx_id) { $repoInfo.license.spdx_id } else { 'None' }

        Write-SubItem 'URL'      "https://github.com/$owner/$repo"
        Write-SubItem 'Stars'    $stars
        Write-SubItem 'Forks'    $forks
        Write-SubItem 'Language' $lang
        Write-SubItem 'License'  $license
        if ($repoInfo.description) {
            Write-SubItem 'About' $repoInfo.description
        }
        if ($repoInfo.homepage) {
            Write-SubItem 'Homepage' $repoInfo.homepage
        }

        Write-Blank
        Write-Trace "GET https://api.github.com/repos/$owner/$repo/releases/latest"
        $release = Get-LatestRelease -Owner $owner -Repo $repo
        if ($release) {
            Write-Host '  Latest release:' -ForegroundColor Cyan
            Write-SubItem 'Tag'       $release.tag_name
            Write-SubItem 'Published' ($release.published_at -replace 'T.*', '')
            if ($release.assets -and $release.assets.Count -gt 0) {
                Write-SubItem 'Assets'   "$($release.assets.Count) file(s)"
                $winAsset = Select-WindowsAsset -Assets $release.assets
                if ($winAsset) {
                    Write-SubItem 'Windows'  "$($winAsset.name)  ($(Format-Bytes -Bytes $winAsset.size))"
                }
            }
        } else {
            Write-Host '  No releases published.' -ForegroundColor DarkGray
        }

    } else {
        Write-Host "  Repository '$owner/$repo' not found on GitHub." -ForegroundColor Red
    }

    Write-Blank
}

# ── Subcommand: list ──────────────────────────────────────────────────────────
function Invoke-List {
    Write-Header
    Write-Phase 'Installed' 'packages:'
    Write-Blank
    Show-InstalledPackages
}

# ── Subcommand: remove ────────────────────────────────────────────────────────
function Invoke-Remove {
    param([string] $PackageTarget)

    $parsed = Resolve-OwnerRepo -PackageTarget $PackageTarget
    Write-Header
    Assert-Elevation -ScriptPath $PSCommandPath -Arguments @('remove', $PackageTarget)
    Invoke-RemovePackage -Owner $parsed.Owner -Repo $parsed.Repo
}

# ── Help ──────────────────────────────────────────────────────────────────────
function Show-Help {
    Write-Header
    @"
Usage:
  wingit install <owner>/<repo>   Install a package from GitHub
  wingit update  <owner>/<repo>   Update an installed package to the latest version
  wingit update  --all            Update all packages installed by WinGit
  wingit remove  <owner>/<repo>   Remove an installed package
  wingit info    <owner>/<repo>   Show information about a package
  wingit list                     List packages installed by WinGit
  wingit --version                Print WinGit version
  wingit --help                   Show this help message

Options:
  -v, --verbose                   Show verbose diagnostic output

Examples:
  wingit install cli/cli
  wingit install neovim/neovim
  wingit install BurntSushi/ripgrep
  wingit update  cli/cli
  wingit update  --all
  wingit info    cli/cli

Environment variables:
  GITHUB_TOKEN    GitHub personal access token (increases API rate limit to 5,000/hr)
"@ | Write-Host
}

# ── Entry point ───────────────────────────────────────────────────────────────
switch ($Command.ToLower()) {
    'install' {
        if (-not $Target) {
            Write-ErrorMsg "Missing target. Usage: wingit install <owner>/<repo>" -ExitCode 1
        }
        Invoke-Install -PackageTarget $Target
    }
    'update' {
        Invoke-Update -PackageTarget $Target
    }
    'remove' {
        if (-not $Target) {
            Write-ErrorMsg "Missing target. Usage: wingit remove <owner>/<repo>" -ExitCode 1
        }
        Invoke-Remove -PackageTarget $Target
    }
    'info' {
        if (-not $Target) {
            Write-ErrorMsg "Missing target. Usage: wingit info <owner>/<repo>" -ExitCode 1
        }
        Invoke-Info -PackageTarget $Target
    }
    'list' {
        Invoke-List
    }
    '--version' {
        Write-Host "WinGit $script:Version"
    }
    '--help' {
        Show-Help
    }
    '' {
        Show-Help
    }
    default {
        Write-ErrorMsg "Unknown command '$Command'. Run 'wingit --help' for usage." -ExitCode 1
    }
}
