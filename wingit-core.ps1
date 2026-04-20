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
    [Alias('version')] [switch] $ShowVersion,
    [Alias('help', 'h', '?')] [switch] $ShowHelp,
    [Parameter(ValueFromRemainingArguments)] [object[]] $ExtraArgs
)

$ErrorActionPreference = 'Stop'

# Normalize: PowerShell 7 binds double-dash args (--version, --help) to
# $ExtraArgs rather than to $Command when [CmdletBinding()] is active.
# Merge them back so the switch works identically on PS 5.1 and PS 7+.
# Also detect -v / --verbose in ExtraArgs.
$script:VerboseMode = $v.IsPresent

if ($ShowVersion) {
    $Command = '--version'
    $Target = ''
    $ExtraArgs = @()
}
elseif ($ShowHelp) {
    $Command = '--help'
    $Target = ''
    $ExtraArgs = @()
}

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

switch ($Command.ToLower()) {
    '-version' { $Command = '--version' }
    'version'  { $Command = '--version' }
    '-help'    { $Command = '--help' }
    'help'     { $Command = '--help' }
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
$script:Version = '2.1.0'
$script:PreferredArchitecture = ''
$script:IncludePrerelease = $false
$script:ForceSourceInstall = $false

# ── Ctrl+C handler ──────────────────────────────────────────────────────────
# Do not treat Ctrl+C as regular input; let PowerShell handle it normally.
try {
    [Console]::TreatControlCAsInput = $false
} catch {}

# ── Helper: parse owner/repo ─────────────────────────────────────────────────
function Resolve-OwnerRepo {
    param([Parameter(Mandatory)] [string] $PackageTarget)

    if ($PackageTarget -match '^([A-Za-z0-9_.\-]+)/([A-Za-z0-9_.\-]+)$') {
        return @{ Owner = $Matches[1]; Repo = $Matches[2] }
    }
    Write-ErrorMsg "Invalid target format '$PackageTarget'. Expected: <owner>/<repo>" -ExitCode 1
}

function Resolve-InstallPreferences {
    param([object[]] $Arguments = @())

    $remaining = [System.Collections.Generic.List[object]]::new()
    $script:PreferredArchitecture = ''
    $script:IncludePrerelease = $false
    $script:ForceSourceInstall = $false

    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $token = [string]$Arguments[$i]
        switch ($token.ToLower()) {
            '--pre-release' { $script:IncludePrerelease = $true; continue }
            '--prerelease'  { $script:IncludePrerelease = $true; continue }
            '--source'      { $script:ForceSourceInstall = $true; continue }
            '--build-from-source' { $script:ForceSourceInstall = $true; continue }
            '--arch' {
                if (($i + 1) -ge $Arguments.Count) {
                    Write-ErrorMsg "Missing value for --arch. Allowed: x64, arm64, x86." -ExitCode 1
                }
                $i++
                $arch = ([string]$Arguments[$i]).ToLower()
                if ($arch -notin @('x64', 'arm64', 'x86')) {
                    Write-ErrorMsg "Invalid architecture '$arch'. Allowed: x64, arm64, x86." -ExitCode 1
                }
                $script:PreferredArchitecture = $arch
                continue
            }
            default { $remaining.Add($Arguments[$i]) | Out-Null }
        }
    }
    return if ($remaining.Count -gt 0) { $remaining.ToArray() } else { @() }
}

function Get-SystemReleaseArchitecture {
    <#
    .SYNOPSIS Detects whether the current Windows system is x64 or ARM64.
    #>
    [CmdletBinding()]
    param()

    try {
        $architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLower()
    } catch {
        $architecture = if ($env:PROCESSOR_ARCHITEW6432) {
            $env:PROCESSOR_ARCHITEW6432.ToLower()
        } elseif ($env:PROCESSOR_ARCHITECTURE) {
            $env:PROCESSOR_ARCHITECTURE.ToLower()
        } else {
            ''
        }
    }

    switch ($architecture) {
        { $_ -in @('amd64', 'x86_64', 'x64') } { return 'x64' }
        { $_ -in @('arm64', 'aarch64') }       { return 'arm64' }
        default                                { return '' }
    }
}

function Resolve-ReleaseArchitecturePreference {
    <#
    .SYNOPSIS Resolves which architecture should be used for release asset selection.
    #>
    [CmdletBinding()]
    param([string] $RequestedArchitecture = '')

    if ($RequestedArchitecture) {
        return [PSCustomObject]@{
            Architecture    = $RequestedArchitecture
            DisplayLabel    = $RequestedArchitecture
            AutoDetected    = $false
            ReleaseEligible = $true
        }
    }

    $detectedArchitecture = Get-SystemReleaseArchitecture
    return [PSCustomObject]@{
        Architecture    = $detectedArchitecture
        DisplayLabel    = if ($detectedArchitecture) { $detectedArchitecture } else { 'unsupported' }
        AutoDetected    = $true
        ReleaseEligible = [bool]$detectedArchitecture
    }
}

function Remove-StalePackagePathEntries {
    param(
        [Parameter(Mandatory)] [string] $Owner,
        [Parameter(Mandatory)] [string] $Repo,
        [string[]] $CurrentPathEntries = @()
    )

    $existingEntry = Get-RegistryEntry -Owner $Owner -Repo $Repo
    if (-not $existingEntry) { return }

    $currentLookup = @{}
    foreach ($pathEntry in @($CurrentPathEntries | Where-Object { $_ })) {
        $currentLookup[(Get-NormalizedDirectoryPath -Path $pathEntry)] = $true
    }

    foreach ($oldPathEntry in @(Get-PackagePathEntries -Entry $existingEntry)) {
        $normalizedPath = Get-NormalizedDirectoryPath -Path $oldPathEntry
        if (-not $currentLookup.ContainsKey($normalizedPath)) {
            Remove-DirectoryFromSystemPath -Directory $oldPathEntry | Out-Null
        }
    }
}

# ── Subcommand: install ───────────────────────────────────────────────────────
function Invoke-Install {
    param(
        [Parameter(Mandatory)] [string] $PackageTarget,
        [object[]] $Arguments = @()
    )

    $parsed = Resolve-OwnerRepo -PackageTarget $PackageTarget
    $owner  = $parsed.Owner
    $repo   = $parsed.Repo
    $null   = Resolve-InstallPreferences -Arguments $Arguments
    $releaseArchitecture = Resolve-ReleaseArchitecturePreference -RequestedArchitecture $script:PreferredArchitecture
    if ($releaseArchitecture.ReleaseEligible) {
        $script:PreferredArchitecture = $releaseArchitecture.Architecture
    }
    $elevationArgs = @('install', $PackageTarget) + @($Arguments | ForEach-Object { [string]$_ })

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

    if ($script:ForceSourceInstall) {
        Write-Phase 'Checking' 'releases...'
        Write-SubItem 'Mode' 'forced source build (--source)'
        Write-Blank
        Assert-Elevation -ScriptPath $PSCommandPath -Arguments $elevationArgs
        try {
            Invoke-SourceInstall -Owner $owner -Repo $repo -DefaultBranch $repoInfo.default_branch
        } catch {
            Write-ErrorMsg $_.Exception.Message -ExitCode 1
        }
        return
    }

    # ── Phase 1b: Release detection ─────────────────────────────────────────
    Write-Phase 'Checking' 'releases...'
    if ($releaseArchitecture.AutoDetected) {
        Write-SubItem 'Architecture' "$($releaseArchitecture.DisplayLabel) (auto-detected)"
    } else {
        Write-SubItem 'Architecture' "$($releaseArchitecture.DisplayLabel) (requested)"
    }

    if (-not $releaseArchitecture.ReleaseEligible) {
        Write-SubItem 'Action' 'architecture unsupported for release install; building from source'
        Write-Blank
        Assert-Elevation -ScriptPath $PSCommandPath -Arguments $elevationArgs
        try {
            Invoke-SourceInstall -Owner $owner -Repo $repo -DefaultBranch $repoInfo.default_branch
        } catch {
            Write-ErrorMsg $_.Exception.Message -ExitCode 1
        }
        return
    }

    Write-Trace "GET https://api.github.com/repos/$owner/$repo/releases/latest"

    $release    = Get-LatestRelease -Owner $owner -Repo $repo -IncludePrerelease:$script:IncludePrerelease
    $assetToUse = $null

    if ($release -and $release.assets -and $release.assets.Count -gt 0) {
        Write-Trace "Found $($release.assets.Count) release asset(s); selecting best Windows match"
        $assetToUse = Select-WindowsAsset -Assets $release.assets -Architecture $releaseArchitecture.Architecture
    }

    if ($assetToUse) {
        $tagName  = $release.tag_name
        $sizeStr  = Format-Bytes -Bytes $assetToUse.size
        Write-SubItem 'Latest'  "$tagName  ($($release.published_at -replace 'T.*',''))"
        Write-SubItem 'Asset'   "$($assetToUse.name)  ($sizeStr)"
        Write-Blank

        Assert-Elevation -ScriptPath $PSCommandPath -Arguments $elevationArgs
        try {
            Invoke-ReleaseInstall -Owner $owner -Repo $repo -Release $release -Asset $assetToUse
        } catch {
            Write-ErrorMsg $_.Exception.Message -ExitCode 1
        }

    } else {
        if ($release) {
            Write-Host 'no suitable Windows binary found.' -ForegroundColor DarkYellow
        } else {
            Write-Host 'no releases found.' -ForegroundColor DarkYellow
        }
        Write-Blank

        Assert-Elevation -ScriptPath $PSCommandPath -Arguments $elevationArgs
        try {
            Invoke-SourceInstall -Owner $owner -Repo $repo -DefaultBranch $repoInfo.default_branch
        } catch {
            Write-ErrorMsg $_.Exception.Message -ExitCode 1
        }
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
    $installDir = [System.IO.Path]::Combine($env:PROGRAMFILES, 'WinGit', 'packages', "$Owner-$Repo")

    $ext     = $Asset.name.ToLower()
    $success = $false
    $installDirCreated = $false
    $pathEntries = @()

    try {
        Write-Phase 'Downloading' $Asset.name
        Write-Trace "URL: $($Asset.browser_download_url)"
        Write-Trace "Destination: $downloadPath"
        Invoke-Download -Url $Asset.browser_download_url -Destination $downloadPath
        Write-Blank

        Write-Phase 'Installing' $Asset.name
        Write-Trace "Install directory: $installDir"

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
                $installDirCreated = $true
            }
            Expand-Archive-Compat -ArchivePath $downloadPath -Destination $installDir

            # Try to find and run an installer inside the archive
            $innerInstaller = Get-ChildItem -Path $installDir -Include '*.msi','*.exe' -Recurse |
                              Select-Object -First 1
            if ($innerInstaller) {
                Write-SubItem 'Running' $innerInstaller.Name
                if ($innerInstaller.Extension -eq '.msi') {
                    $proc = Start-Process 'msiexec.exe' -ArgumentList "/i `"$($innerInstaller.FullName)`" /quiet /norestart" -Wait -PassThru
                    if ($proc.ExitCode -ne 0) { throw "inner msiexec exited with code $($proc.ExitCode)" }
                } else {
                    $proc = Start-Process $innerInstaller.FullName -ArgumentList '/S' -Wait -PassThru
                    if ($proc.ExitCode -ne 0) { throw "inner installer exited with code $($proc.ExitCode)" }
                }
            } else {
                # No installer found — add extract dir to system PATH
                $binDir = [System.IO.Path]::Combine($installDir, 'bin')
                $pathToAdd = if (Test-Path $binDir) { $binDir } else { $installDir }
                Add-DirectoryToSystemPath -Directory $pathToAdd
                $pathEntries += $pathToAdd
            }
            $success = $true
        } else {
            throw "Unsupported release asset type: $($Asset.name)"
        }
    } catch {
        if ($installDirCreated -and (Test-Path $installDir)) {
            Write-SubItem 'Cleanup' "Removing incomplete install directory: $installDir"
            Remove-Item -Path $installDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-WarnMsg  "Downloaded file preserved at: $downloadPath"
        Write-InstallFailureLog -Operation 'release install' -Package "$Owner/$Repo" `
            -Message 'Installing a release asset failed.' `
            -Details @(
                "Asset     : $($Asset.name)",
                "Release   : $($Release.tag_name)",
                "URL       : $($Asset.browser_download_url)",
                "Download  : $downloadPath",
                "Install   : $installDir"
            ) `
            -ErrorRecord $_
        throw "Installation failed: $($_.Exception.Message)"
    }

    if (-not $success) {
        Write-InstallFailureLog -Operation 'release install' -Package "$Owner/$Repo" `
            -Message 'Installer did not report success.' `
            -Details @(
                "Asset     : $($Asset.name)",
                "Release   : $($Release.tag_name)",
                "URL       : $($Asset.browser_download_url)",
                "Download  : $downloadPath",
                "Install   : $installDir"
            )
        throw 'Installation failed.'
    }

    Remove-StalePackagePathEntries -Owner $Owner -Repo $Repo -CurrentPathEntries $pathEntries

    # Record in registry
    Add-RegistryEntry -Owner $Owner -Repo $Repo `
        -Version $Release.tag_name -InstallType 'release' `
        -InstallPath $installDir -AssetName $Asset.name `
        -Architecture $script:PreferredArchitecture `
        -IncludePrerelease $script:IncludePrerelease `
        -PathEntries $pathEntries

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

    $workRoot   = [System.IO.Path]::Combine($env:TEMP, 'wingit', "$Owner-$Repo-source")
    $srcDir     = [System.IO.Path]::Combine($workRoot, 'src')
    $extractTemp = [System.IO.Path]::Combine($workRoot, 'extract')
    $zipPath    = [System.IO.Path]::Combine($workRoot, "$Repo-src.zip")
    $installDir = [System.IO.Path]::Combine($env:PROGRAMFILES, 'WinGit', 'packages', "$Owner-$Repo")
    $cloneUrl   = "https://github.com/$Owner/${Repo}.git"
    $activeSourceUrl = $cloneUrl

    if (Test-Path $workRoot) {
        Write-SubItem 'Cleanup' "Removing existing source workspace: $workRoot"
        Remove-Item -Path $workRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    New-Item -ItemType Directory -Path $workRoot -Force | Out-Null

    try {
        Write-Phase 'Fetching' 'source...'

        try {
            if (Test-ToolOnPath 'git') {
                Write-SubItem 'Cloning' "$cloneUrl  ->  $srcDir"
                Write-Trace "git clone --depth=1 $cloneUrl $srcDir"
                $cloneResult = Invoke-NativeCommand -FilePath 'git' -ArgumentList @('clone', '--depth=1', $cloneUrl, $srcDir) -CaptureOutput
                if ($cloneResult.Output.Count -gt 0) {
                    Write-IndentedBlock ($cloneResult.Output -join "`n")
                }
                if ($cloneResult.ExitCode -ne 0) {
                    throw "git clone failed (exit $($cloneResult.ExitCode))"
                }
            } else {
                # Fallback: download zip archive. Use the repo's default branch.
                $activeSourceUrl = "https://github.com/$Owner/$Repo/archive/refs/heads/$DefaultBranch.zip"
                Write-SubItem 'Downloading' $activeSourceUrl
                Write-Trace "Destination: $zipPath"
                try {
                    Invoke-Download -Url $activeSourceUrl -Destination $zipPath
                } catch {
                    $fallbackBranch = if ($DefaultBranch -eq 'main') { 'master' } else { 'main' }
                    $activeSourceUrl = "https://github.com/$Owner/$Repo/archive/refs/heads/$fallbackBranch.zip"
                    Write-SubItem 'Retrying' $activeSourceUrl
                    Invoke-Download -Url $activeSourceUrl -Destination $zipPath
                }

                if (Test-Path $extractTemp) {
                    Remove-Item -Path $extractTemp -Recurse -Force -ErrorAction SilentlyContinue
                }

                Write-SubItem 'Extracting' $zipPath
                Expand-Archive-Compat -ArchivePath $zipPath -Destination $extractTemp

                # GitHub zip archives contain a top-level directory like repo-main/
                $innerDir = Get-ChildItem -Path $extractTemp -Directory | Select-Object -First 1
                if (-not $innerDir) {
                    throw 'Downloaded source archive did not contain a top-level source directory.'
                }

                Move-Item -Path $innerDir.FullName -Destination $srcDir -Force
            }
        } catch {
            if (Test-Path $srcDir) {
                Write-SubItem 'Cleanup' "Removing failed source directory: $srcDir"
                Remove-Item -Path $srcDir -Recurse -Force -ErrorAction SilentlyContinue
            }

            Write-InstallFailureLog -Operation 'source fetch' -Package "$Owner/$Repo" `
                -Message 'Fetching source code failed.' `
                -Details @(
                    "Source    : $activeSourceUrl",
                    "Workspace : $workRoot",
                    "SourceDir : $srcDir",
                    "Archive   : $zipPath",
                    "Branch    : $DefaultBranch"
                ) `
                -ErrorRecord $_
            throw "Source fetch failed: $($_.Exception.Message)"
        }

        Write-Blank

        $pathEntries = @()
        try {
            $pathEntries = @(Invoke-SourceBuild -Owner $Owner -Repo $Repo -SourceDir $srcDir -InstallDir $installDir)
        } catch {
            if (Test-Path $installDir) {
                Write-SubItem 'Cleanup' "Removing incomplete install directory: $installDir"
                Remove-Item -Path $installDir -Recurse -Force -ErrorAction SilentlyContinue
            }

            Write-InstallFailureLog -Operation 'source build' -Package "$Owner/$Repo" `
                -Message 'Building from source failed.' `
                -Details @(
                    "SourceDir : $srcDir",
                    "Install   : $installDir"
                ) `
                -ErrorRecord $_
            throw "Source build failed: $($_.Exception.Message)"
        }

        Remove-StalePackagePathEntries -Owner $Owner -Repo $Repo -CurrentPathEntries $pathEntries

        Add-RegistryEntry -Owner $Owner -Repo $Repo `
            -Version 'source' -InstallType 'source' `
            -InstallPath $installDir `
            -Architecture $script:PreferredArchitecture `
            -IncludePrerelease $script:IncludePrerelease `
            -PathEntries $pathEntries

        Write-Complete -Package "$Owner/$Repo" -InstallType 'source'
    } finally {
        if (Test-Path $workRoot) {
            Remove-Item -Path $workRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
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
        Assert-Elevation -ScriptPath $PSCommandPath -Arguments @('update', '--all')
        Write-Phase 'Updating' "all $($entries.Count) installed package(s)..."
        Write-Blank

        $updated = 0
        $upToDate = 0
        $failed = 0
        $pinned = 0

        foreach ($entry in $entries) {
            $pkg = "$($entry.owner)/$($entry.repo)"
            Write-Phase 'Checking' "$pkg..."
            if ($entry.PSObject.Properties.Name -contains 'pinned' -and $entry.pinned) {
                Write-SubItem 'Pinned' 'skipping during update --all'
                $pinned++
                Write-Blank
                continue
            }
            $result = Update-SinglePackage -Owner $entry.owner -Repo $entry.repo `
                -CurrentVersion $entry.version -InstallType $entry.install_type `
                -Architecture $entry.architecture -IncludePrerelease ([bool]$entry.include_prerelease)
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
        if ($pinned -gt 0)    { Write-Host "  $pinned package(s) skipped because they are pinned." -ForegroundColor DarkYellow }
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
    } elseif ($entry.PSObject.Properties.Name -contains 'pinned' -and $entry.pinned) {
        Write-SubItem 'Pinned' 'manual update requested; continuing'
    }

    Assert-Elevation -ScriptPath $PSCommandPath -Arguments @('update', $PackageTarget)
    $result = Update-SinglePackage -Owner $parsed.Owner -Repo $parsed.Repo `
        -CurrentVersion $currentVersion -InstallType $installType `
        -Architecture $entry.architecture -IncludePrerelease ([bool]$entry.include_prerelease)
    if ($result -eq 'uptodate') {
        Write-Host ''
        Write-Host 'Already up to date.' -ForegroundColor Green
        Write-Host ''
    }
}

# ── Subcommand: search ───────────────────────────────────────────────────────
function Invoke-Search {
    param([Parameter(Mandatory)] [string] $Query)

    Write-Header
    Write-Phase 'Searching' "GitHub repositories for '$Query'..."
    Write-Blank
    Write-Trace "GET https://api.github.com/search/repositories?q=$( [System.Uri]::EscapeDataString($Query) )"

    $results = Search-GitHubRepositories -Query $Query -Limit 10
    if (-not $results -or $results.Count -eq 0) {
        Write-Host 'No repositories found.' -ForegroundColor DarkGray
        Write-Blank
        return
    }

    $index = 1
    foreach ($repo in $results) {
        $name = "$($repo.owner.login)/$($repo.name)"
        $stars = '{0:N0}' -f [int]$repo.stargazers_count
        $lang = if ($repo.language) { $repo.language } else { 'Unknown' }

        Write-Host ("[{0}] {1}" -f $index.ToString().PadLeft(2), $name) -ForegroundColor Cyan
        Write-SubItem 'Stars'    $stars
        Write-SubItem 'Language' $lang
        if ($repo.description) { Write-SubItem 'About' $repo.description }
        Write-SubItem 'URL'      $repo.html_url
        Write-Blank
        $index++
    }
}

# ── Subcommand: doctor ───────────────────────────────────────────────────────
function Invoke-Doctor {
    Write-Header
    Write-Phase 'Doctor' 'environment diagnostics'
    Write-Blank

    Write-Host '  Core tools:' -ForegroundColor Cyan
    foreach ($tool in @('git', 'curl', 'tar')) {
        if (Test-ToolOnPath $tool) {
            Write-StatusOk -Label $tool
        } else {
            Write-StatusNotFound -Label $tool
        }
    }
    Write-Blank

    Write-Host '  Build tools:' -ForegroundColor Cyan
    foreach ($tool in @('cmake', 'ninja', 'mingw32-make', 'cargo', 'go', 'node', 'npm', 'python', 'pip', 'dotnet', 'java', 'mvn')) {
        if (Test-ToolOnPath $tool) {
            Write-StatusOk -Label $tool
        } else {
            Write-StatusNotFound -Label $tool
        }
    }
    Write-Blank

    Write-Host '  GitHub API:' -ForegroundColor Cyan
    if ($env:GITHUB_TOKEN) {
        Write-StatusOk -Label 'GITHUB_TOKEN' -Detail 'set'
    } else {
        Write-StatusFail -Label 'GITHUB_TOKEN' -Detail 'not set'
    }

    try {
        $rate = Invoke-GitHubApi -Url 'https://api.github.com/rate_limit'
        if ($rate -and $rate.resources -and $rate.resources.core) {
            $core = $rate.resources.core
            Write-SubItem 'Remaining' "$($core.remaining) / $($core.limit)"
            Write-SubItem 'Resets at' ([DateTimeOffset]::FromUnixTimeSeconds([int64]$core.reset).UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss') + ' UTC')
        }
    } catch {
        Write-WarnMsg "Unable to read GitHub rate limit: $($_.Exception.Message)"
    }

    Write-Blank
}

function Update-SinglePackage {
    <#
    .SYNOPSIS Checks for and applies an update for one package. Returns 'updated', 'uptodate', or 'failed'.
    #>
    param(
        [Parameter(Mandatory)] [string] $Owner,
        [Parameter(Mandatory)] [string] $Repo,
        [string] $CurrentVersion = '',
        [string] $InstallType    = '',
        [string] $Architecture   = '',
        [bool] $IncludePrerelease = $false
    )

    try {
        Write-Trace "GET https://api.github.com/repos/$Owner/$Repo/releases/latest"
        $release = Get-LatestRelease -Owner $Owner -Repo $Repo -IncludePrerelease:$IncludePrerelease
        $releaseArchitecture = Resolve-ReleaseArchitecturePreference -RequestedArchitecture $Architecture

        if ($InstallType -eq 'source' -or (-not $release) -or (-not $releaseArchitecture.ReleaseEligible)) {
            # Source installs: always re-fetch and rebuild
            Write-SubItem 'Type'    'source build'
            if (-not $releaseArchitecture.ReleaseEligible) {
                Write-SubItem 'Architecture' "$($releaseArchitecture.DisplayLabel) (source fallback)"
            }
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
            $assetToUse = Select-WindowsAsset -Assets $release.assets -Architecture $releaseArchitecture.Architecture
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

function Invoke-Outdated {
    Write-Header
    Write-Phase 'Outdated' 'checking installed packages against GitHub releases...'
    Write-Blank

    $entries = Read-Registry
    if (-not $entries -or $entries.Count -eq 0) {
        Write-Host 'No packages installed by WinGit.' -ForegroundColor DarkGray
        Write-Blank
        return
    }

    $outdated = @()
    foreach ($entry in $entries) {
        if ($entry.install_type -eq 'source') { continue }
        $release = Get-LatestRelease -Owner $entry.owner -Repo $entry.repo -IncludePrerelease:([bool]$entry.include_prerelease)
        if (-not $release) { continue }
        if ($entry.version -ne $release.tag_name) {
            $outdated += [PSCustomObject]@{
                package    = "$($entry.owner)/$($entry.repo)"
                installed  = if ($entry.version) { $entry.version } else { '(unknown)' }
                latest     = $release.tag_name
                prerelease = [bool]$release.prerelease
                pinned     = [bool]$entry.pinned
            }
        }
    }

    if ($outdated.Count -eq 0) {
        Write-Host 'All release-installed packages are up to date.' -ForegroundColor Green
        Write-Blank
        return
    }

    foreach ($pkg in $outdated) {
        Write-Host "  $($pkg.package)" -ForegroundColor Cyan
        Write-SubItem 'Installed' $pkg.installed
        Write-SubItem 'Latest' $pkg.latest
        if ($pkg.pinned) {
            Write-SubItem 'Pinned' 'yes'
        }
        if ($pkg.prerelease) {
            Write-SubItem 'Channel' 'pre-release'
        }
        Write-Blank
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
    $entry = Get-RegistryEntry -Owner $owner -Repo $repo
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
        if ($entry.PSObject.Properties.Name -contains 'path_entries' -and $entry.path_entries) {
            Write-SubItem 'PATH entries' ($entry.path_entries -join ', ')
        }
        if ($entry.architecture) {
            Write-SubItem 'Architecture' $entry.architecture
        }
        if ($entry.PSObject.Properties.Name -contains 'include_prerelease' -and $entry.include_prerelease) {
            Write-SubItem 'Release channel' 'pre-release enabled'
        }
        if ($entry.PSObject.Properties.Name -contains 'pinned' -and $entry.pinned) {
            Write-SubItem 'Pinned' 'yes'
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

function Resolve-UserPath {
    param(
        [string] $Path = '',
        [string] $DefaultLeaf = ''
    )

    $candidate = if ($Path) {
        if ([System.IO.Path]::IsPathRooted($Path)) {
            $Path
        } else {
            Join-Path (Get-Location).Path $Path
        }
    } elseif ($DefaultLeaf) {
        Join-Path (Get-Location).Path $DefaultLeaf
    } else {
        (Get-Location).Path
    }

    return [System.IO.Path]::GetFullPath($candidate)
}

function Invoke-Export {
    param([string] $ManifestPath = '')

    Write-Header
    Write-Phase 'Exporting' 'package manifest...'

    $resolvedPath = Resolve-UserPath -Path $ManifestPath -DefaultLeaf 'wingit-packages.json'
    $dir = [System.IO.Path]::GetDirectoryName($resolvedPath)
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $entries = @(Read-Registry | Sort-Object owner, repo)
    $packages = @(
        foreach ($entry in $entries) {
            [PSCustomObject]@{
                repository         = "$($entry.owner)/$($entry.repo)"
                install_type       = if ($entry.install_type) { $entry.install_type } else { 'release' }
                architecture       = if ($entry.architecture) { $entry.architecture } else { $null }
                include_prerelease = [bool]$entry.include_prerelease
                pinned             = [bool]$entry.pinned
            }
        }
    )

    $manifest = [PSCustomObject]@{
        manifest_version = 1
        generated_at     = ([datetime]::UtcNow.ToString('o'))
        generated_by     = "WinGit $script:Version"
        package_count    = $packages.Count
        packages         = @($packages)
    }

    $manifest | ConvertTo-Json -Depth 6 | Set-Content -Path $resolvedPath -Encoding UTF8

    Write-SubItem 'Path' $resolvedPath
    Write-SubItem 'Packages' $packages.Count
    Write-Blank
}

function Invoke-Import {
    param([Parameter(Mandatory)] [string] $ManifestPath)

    Write-Header
    Write-Phase 'Importing' 'package manifest...'

    $resolvedPath = Resolve-UserPath -Path $ManifestPath
    if (-not (Test-Path $resolvedPath)) {
        Write-ErrorMsg "Manifest file not found: $resolvedPath" -ExitCode 1
    }

    Write-SubItem 'Path' $resolvedPath

    try {
        $manifest = Get-Content -Path $resolvedPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-ErrorMsg "Could not parse manifest file '$resolvedPath': $($_.Exception.Message)" -ExitCode 1
    }

    $packages = if ($manifest -and $manifest.PSObject.Properties.Name -contains 'packages') {
        @($manifest.packages)
    } else {
        @($manifest)
    }

    if (-not $packages -or $packages.Count -eq 0) {
        Write-WarnMsg 'Manifest does not contain any packages.'
        Write-Blank
        return
    }

    Assert-Elevation -ScriptPath $PSCommandPath -Arguments @('import', $resolvedPath)

    $installed = 0
    $skipped = 0

    foreach ($package in $packages) {
        $packageTarget = if ($package.PSObject.Properties.Name -contains 'repository') {
            [string]$package.repository
        } else {
            ''
        }

        if (-not $packageTarget) {
            Write-ErrorMsg 'Manifest entries must define a repository value in <owner>/<repo> format.' -ExitCode 1
        }

        $parsed = Resolve-OwnerRepo -PackageTarget $packageTarget
        $existing = Get-RegistryEntry -Owner $parsed.Owner -Repo $parsed.Repo

        if ($existing) {
            Write-Phase 'Skipping' "$packageTarget..."
            Write-SubItem 'Status' 'already installed'
            if ($package.PSObject.Properties.Name -contains 'pinned') {
                Set-PackagePinned -Owner $parsed.Owner -Repo $parsed.Repo -Pinned ([bool]$package.pinned) | Out-Null
                Write-SubItem 'Pinned' $(if ([bool]$package.pinned) { 'yes' } else { 'no' })
            }
            Write-Blank
            $skipped++
            continue
        }

        $installArgs = @()
        if ($package.PSObject.Properties.Name -contains 'install_type' -and [string]$package.install_type -eq 'source') {
            $installArgs += '--source'
        }
        if ($package.PSObject.Properties.Name -contains 'architecture' -and $package.architecture) {
            $installArgs += '--arch'
            $installArgs += [string]$package.architecture
        }
        if ($package.PSObject.Properties.Name -contains 'include_prerelease' -and [bool]$package.include_prerelease) {
            $installArgs += '--pre-release'
        }

        Invoke-Install -PackageTarget $packageTarget -Arguments $installArgs
        if ($package.PSObject.Properties.Name -contains 'pinned' -and [bool]$package.pinned) {
            Set-PackagePinned -Owner $parsed.Owner -Repo $parsed.Repo -Pinned $true | Out-Null
        }
        $installed++
    }

    Write-Host 'Import summary:' -ForegroundColor Cyan
    if ($installed -gt 0) { Write-Host "  $installed package(s) installed." -ForegroundColor Green }
    if ($skipped -gt 0) { Write-Host "  $skipped package(s) already present." -ForegroundColor Gray }
    Write-Blank
}

function Invoke-Pin {
    param([Parameter(Mandatory)] [string] $PackageTarget)

    $parsed = Resolve-OwnerRepo -PackageTarget $PackageTarget
    Write-Header
    Assert-Elevation -ScriptPath $PSCommandPath -Arguments @('pin', $PackageTarget)
    Write-Phase 'Pinning' "$PackageTarget..."
    Set-PackagePinned -Owner $parsed.Owner -Repo $parsed.Repo -Pinned $true | Out-Null
    Write-SubItem 'Status' 'pinned'
    Write-Blank
}

function Invoke-Unpin {
    param([Parameter(Mandatory)] [string] $PackageTarget)

    $parsed = Resolve-OwnerRepo -PackageTarget $PackageTarget
    Write-Header
    Assert-Elevation -ScriptPath $PSCommandPath -Arguments @('unpin', $PackageTarget)
    Write-Phase 'Unpinning' "$PackageTarget..."
    Set-PackagePinned -Owner $parsed.Owner -Repo $parsed.Repo -Pinned $false | Out-Null
    Write-SubItem 'Status' 'updates re-enabled'
    Write-Blank
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
  wingit pin     <owner>/<repo>   Prevent update --all from upgrading a package
  wingit unpin   <owner>/<repo>   Re-enable update --all for a package
  wingit info    <owner>/<repo>   Show information about a package
  wingit list                     List packages installed by WinGit
  wingit outdated                 Show installed packages with newer releases available
  wingit export  [file]           Export installed packages to a manifest JSON file
  wingit import  <file>           Install packages from a manifest JSON file
  wingit search  <query>          Search GitHub repositories
  wingit doctor                   Run environment diagnostics
  wingit --version                Print WinGit version
  wingit --help                   Show this help message

Options:
  -v, --verbose                   Show verbose diagnostic output
  --arch <x64|arm64|x86>          Override the auto-detected release architecture
  --pre-release                   Allow prerelease versions in install/update checks
  --source                        Force a source build even when a release asset exists

Examples:
  wingit install cli/cli
  wingit install sharkdp/bat --source
  wingit install neovim/neovim
  wingit install BurntSushi/ripgrep
  wingit update  cli/cli
  wingit update  --all
  wingit pin     cli/cli
  wingit export  packages.json
  wingit import  packages.json
  wingit info    cli/cli
  wingit outdated
  wingit search  terminal
  wingit doctor

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
        Invoke-Install -PackageTarget $Target -Arguments $ExtraArgs
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
    'pin' {
        if (-not $Target) {
            Write-ErrorMsg "Missing target. Usage: wingit pin <owner>/<repo>" -ExitCode 1
        }
        Invoke-Pin -PackageTarget $Target
    }
    'unpin' {
        if (-not $Target) {
            Write-ErrorMsg "Missing target. Usage: wingit unpin <owner>/<repo>" -ExitCode 1
        }
        Invoke-Unpin -PackageTarget $Target
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
    'outdated' {
        Invoke-Outdated
    }
    'export' {
        Invoke-Export -ManifestPath $Target
    }
    'import' {
        if (-not $Target) {
            Write-ErrorMsg "Missing file. Usage: wingit import <file>" -ExitCode 1
        }
        Invoke-Import -ManifestPath $Target
    }
    'search' {
        if (-not $Target) {
            Write-ErrorMsg "Missing query. Usage: wingit search <query>" -ExitCode 1
        }
        # Allow multi-word query from remaining args
        if ($ExtraArgs -and $ExtraArgs.Count -gt 0) {
            $Target = @($Target) + @($ExtraArgs | ForEach-Object { [string]$_ }) -join ' '
        }
        Invoke-Search -Query $Target
    }
    'doctor' {
        Invoke-Doctor
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
