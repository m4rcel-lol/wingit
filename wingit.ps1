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
    wingit remove cli/cli
#>

param(
    [Parameter(Position = 0)] [string] $Command  = '',
    [Parameter(Position = 1)] [string] $Target   = '',
    [Parameter(ValueFromRemainingArguments)] [object[]] $ExtraArgs
)

$ErrorActionPreference = 'Stop'

# Normalize: PowerShell 7 binds double-dash args (--version, --help) to
# $ExtraArgs rather than to $Command when [CmdletBinding()] is active.
# Merge them back so the switch works identically on PS 5.1 and PS 7+.
if (-not $Command -and $ExtraArgs -and $ExtraArgs.Count -gt 0) {
    $Command  = [string]$ExtraArgs[0]
    $Target   = if ($ExtraArgs.Count -gt 1) { [string]$ExtraArgs[1] } else { '' }
    $ExtraArgs = if ($ExtraArgs.Count -gt 2) { $ExtraArgs[2..($ExtraArgs.Count-1)] } else { @() }
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
$script:Version = '1.0.0'

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

    $repoInfo = Get-RepoInfo -Owner $owner -Repo $repo
    if (-not $repoInfo) {
        Write-ErrorMsg "Repository '$owner/$repo' not found on GitHub." -ExitCode 1
    }

    $stars    = if ($repoInfo.stargazers_count) { '{0:N0}' -f $repoInfo.stargazers_count } else { '0' }
    $language = if ($repoInfo.language)         { $repoInfo.language }                     else { 'Unknown' }

    Write-SubItem 'Repository' "https://github.com/$owner/$repo"
    Write-SubItem 'Stars'      $stars
    Write-SubItem 'Language'   $language
    Write-Blank

    # ── Phase 1b: Release detection ─────────────────────────────────────────
    Write-Phase 'Checking' 'releases...'

    $release    = Get-LatestRelease -Owner $owner -Repo $repo
    $assetToUse = $null

    if ($release -and $release.assets -and $release.assets.Count -gt 0) {
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
    Invoke-Download -Url $Asset.browser_download_url -Destination $downloadPath
    Write-Blank

    Write-Phase 'Installing' $Asset.name
    $installDir = [System.IO.Path]::Combine($env:PROGRAMFILES, 'WinGit', 'packages', "$Owner-$Repo")

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
        & git clone --depth=1 $cloneUrl $srcDir 2>&1 | ForEach-Object { Write-Host "  $_" }
        if ($LASTEXITCODE -ne 0) { Write-ErrorMsg "git clone failed." -ExitCode 1 }
    } else {
        # Fallback: download zip archive. Use the repo's default branch.
        $zipUrl  = "https://github.com/$Owner/$Repo/archive/refs/heads/$DefaultBranch.zip"
        $zipPath = [System.IO.Path]::Combine($env:TEMP, 'wingit', "$Repo-src.zip")

        Write-SubItem 'Downloading' $zipUrl
        try {
            Invoke-Download -Url $zipUrl -Destination $zipPath
        } catch {
            $zipUrl  = "https://github.com/$Owner/$Repo/archive/refs/heads/master.zip"
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
  wingit remove  <owner>/<repo>   Remove an installed package
  wingit list                     List packages installed by WinGit
  wingit --version                Print WinGit version
  wingit --help                   Show this help message

Examples:
  wingit install cli/cli
  wingit install neovim/neovim
  wingit install BurntSushi/ripgrep

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
    'remove' {
        if (-not $Target) {
            Write-ErrorMsg "Missing target. Usage: wingit remove <owner>/<repo>" -ExitCode 1
        }
        Invoke-Remove -PackageTarget $Target
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
