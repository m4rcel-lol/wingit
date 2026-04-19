<#
.SYNOPSIS
    Build tool availability checking and installation for WinGit.
.DESCRIPTION
    Checks whether required build tools exist on PATH, installs them via
    Chocolatey (Tier 1) or direct-installer downloads (Tier 2), and refreshes
    the environment after each install attempt.
#>

# Mapping: tool name -> Chocolatey package id
$script:ChocoPackages = @{
    cmake          = 'cmake'
    ninja          = 'ninja'
    make           = 'make'
    'mingw32-make' = 'mingw'
    cargo          = 'rust'
    rustc          = 'rust'
    node           = 'nodejs'
    npm            = 'nodejs'
    python         = 'python'
    python3        = 'python'
    pip            = 'python'
    pip3           = 'python'
    java           = 'openjdk'
    gradle         = 'gradle'
    mvn            = 'maven'
    msbuild        = 'visualstudio2022buildtools'
    go             = 'golang'
    git            = 'git'
    dotnet         = 'dotnet-sdk'
    ruby           = 'ruby'
    bundle         = 'ruby'
    deno           = 'deno'
    zig            = 'zig'
    just           = 'just'
    swift          = 'swift'
}

# Mapping: tool name -> direct installer URL resolver function name
$script:DirectInstallers = @{
    cmake   = 'Get-CmakeInstallerUrl'
    git     = 'Get-GitInstallerUrl'
    node    = 'Get-NodeInstallerUrl'
    python  = 'Get-PythonInstallerUrl'
    python3 = 'Get-PythonInstallerUrl'
    cargo   = 'Get-RustInstallerUrl'
    rustc   = 'Get-RustInstallerUrl'
    go      = 'Get-GoInstallerUrl'
    dotnet  = 'Get-DotNetInstallerUrl'
    deno    = 'Get-DenoInstallerUrl'
}

function Test-ToolOnPath {
    <#
    .SYNOPSIS
        Returns $true if a tool executable is found on the current PATH.
    .PARAMETER ToolName The executable name (without .exe extension).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ToolName)
    $result = Get-Command $ToolName -ErrorAction SilentlyContinue
    return ($null -ne $result)
}

function Update-EnvironmentPath {
    <#
    .SYNOPSIS
        Refreshes the current process PATH from the system and user registry values.
    #>
    $machinePath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath    = [System.Environment]::GetEnvironmentVariable('Path', 'User')
    $env:PATH    = "$machinePath;$userPath"
}

function Install-Chocolatey {
    <#
    .SYNOPSIS Installs Chocolatey package manager into the current (elevated) session.
    .OUTPUTS $true if installation succeeded, $false otherwise.
    #>
    [CmdletBinding()]
    param()

    Write-Action 'Chocolatey not found. Installing Chocolatey package manager...'
    try {
        $installScript = (New-Object System.Net.WebClient).DownloadString(
            'https://community.chocolatey.org/install.ps1')
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [System.Net.ServicePointManager]::SecurityProtocol =
            [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-Expression $installScript
        Update-EnvironmentPath
        return (Test-ToolOnPath 'choco')
    } catch {
        Write-WarnMsg "Chocolatey installation failed: $($_.Exception.Message)"
        return $false
    }
}

function Install-ToolViaChoco {
    <#
    .SYNOPSIS
        Installs a tool via Chocolatey.
    .PARAMETER ToolName   The logical tool name (used to look up the choco package id).
    .OUTPUTS $true if the tool is on PATH after installation, $false otherwise.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ToolName)

    $pkg = $script:ChocoPackages[$ToolName]
    if (-not $pkg) {
        Write-WarnMsg "No Chocolatey package mapping found for '$ToolName'."
        return $false
    }

    Write-Action "choco install $pkg -y"
    $output = & choco install $pkg -y --no-progress 2>&1
    Write-IndentedBlock ($output -join "`n")
    Update-EnvironmentPath
    return (Test-ToolOnPath $ToolName)
}

# --- Direct installer URL resolvers ---

function Get-CmakeInstallerUrl {
    <#
    .SYNOPSIS Returns the latest CMake Windows MSI download URL via the GitHub API.
    #>
    $release = Invoke-GitHubApi 'https://api.github.com/repos/Kitware/CMake/releases/latest'
    $asset   = $release.assets | Where-Object { $_.name -like '*windows-x86_64.msi' } | Select-Object -First 1
    if ($asset) { return $asset.browser_download_url }
    return $null
}

function Get-GitInstallerUrl {
    <#
    .SYNOPSIS Returns the latest Git for Windows installer URL.
    #>
    $release = Invoke-GitHubApi 'https://api.github.com/repos/git-for-windows/git/releases/latest'
    $asset   = $release.assets | Where-Object { $_.name -like '*64-bit.exe' } | Select-Object -First 1
    if ($asset) { return $asset.browser_download_url }
    return $null
}

function Get-NodeInstallerUrl {
    <#
    .SYNOPSIS Returns the latest Node.js Windows x64 MSI URL.
    #>
    try {
        $ProgressPreference = 'SilentlyContinue'
        $index = Invoke-WebRequest -Uri 'https://nodejs.org/dist/latest/' -UseBasicParsing -ErrorAction Stop
        $match = [regex]::Match($index.Content, 'node-v[\d.]+-x64\.msi')
        if ($match.Success) {
            return "https://nodejs.org/dist/latest/$($match.Value)"
        }
    } catch {}
    return $null
}

function Get-PythonInstallerUrl {
    <#
    .SYNOPSIS Returns the latest CPython Windows x64 installer URL.
    #>
    try {
        $ProgressPreference = 'SilentlyContinue'
        $page  = Invoke-WebRequest -Uri 'https://www.python.org/downloads/windows/' -UseBasicParsing -ErrorAction Stop
        $match = [regex]::Match($page.Content, 'https://www\.python\.org/ftp/python/[\d.]+/python-[\d.]+-amd64\.exe')
        if ($match.Success) { return $match.Value }
    } catch {}
    return $null
}

function Get-RustInstallerUrl {
    <#
    .SYNOPSIS Returns the rustup-init.exe URL for 64-bit Windows.
    #>
    return 'https://win.rustup.rs/x86_64'
}

function Get-GoInstallerUrl {
    <#
    .SYNOPSIS Returns the latest Go Windows amd64 MSI URL.
    #>
    try {
        $ProgressPreference = 'SilentlyContinue'
        $page  = Invoke-WebRequest -Uri 'https://go.dev/dl/' -UseBasicParsing -ErrorAction Stop
        $match = [regex]::Match($page.Content, 'go[\d.]+\.windows-amd64\.msi')
        if ($match.Success) {
            return "https://go.dev/dl/$($match.Value)"
        }
    } catch {}
    return $null
}

function Get-DotNetInstallerUrl {
    <#
    .SYNOPSIS Returns the latest .NET SDK Windows x64 installer URL via the GitHub API.
    #>
    $release = Invoke-GitHubApi 'https://api.github.com/repos/dotnet/sdk/releases/latest'
    if ($release -and $release.assets) {
        $asset = $release.assets |
            Where-Object { $_.name -like '*win-x64.exe' } |
            Select-Object -First 1
        if ($asset) { return $asset.browser_download_url }
    }
    # Fallback to the official dotnet-install script approach (downloads the SDK)
    return 'https://dot.net/v1/dotnet-install.ps1'
}

function Get-DenoInstallerUrl {
    <#
    .SYNOPSIS Returns the latest Deno Windows x64 zip URL via the GitHub API.
    #>
    $release = Invoke-GitHubApi 'https://api.github.com/repos/denoland/deno/releases/latest'
    if ($release -and $release.assets) {
        $asset = $release.assets |
            Where-Object { $_.name -like 'deno-x86_64-pc-windows-msvc.zip' } |
            Select-Object -First 1
        if ($asset) { return $asset.browser_download_url }
    }
    return $null
}

function Install-ToolDirect {
    <#
    .SYNOPSIS
        Installs a tool by downloading its official installer.
    .PARAMETER ToolName The logical tool name.
    .OUTPUTS $true if the tool is on PATH after installation, $false otherwise.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ToolName)

    $resolverName = $script:DirectInstallers[$ToolName]
    if (-not $resolverName) {
        Write-WarnMsg "No direct installer available for '$ToolName'."
        return $false
    }

    $installerUrl = & $resolverName
    if (-not $installerUrl) {
        Write-WarnMsg "Could not resolve installer URL for '$ToolName'."
        return $false
    }

    $installerDir  = [System.IO.Path]::Combine($env:TEMP, 'wingit', 'installers')
    $installerFile = [System.IO.Path]::Combine($installerDir, [System.IO.Path]::GetFileName($installerUrl))

    Write-Action "Downloading installer for $ToolName from $installerUrl"
    Invoke-Download -Url $installerUrl -Destination $installerFile

    $maxAttempts = 3
    for ($i = 1; $i -le $maxAttempts; $i++) {
        Write-Action "Running installer for $ToolName (attempt $i/$maxAttempts)..."

        $ext = [System.IO.Path]::GetExtension($installerFile).ToLower()
        if ($ext -eq '.msi') {
            $proc = Start-Process 'msiexec.exe' -ArgumentList "/i `"$installerFile`" /quiet /norestart" -Wait -PassThru
        } else {
            $proc = Start-Process $installerFile -ArgumentList '/S' -Wait -PassThru
        }

        Update-EnvironmentPath
        if (Test-ToolOnPath $ToolName) { return $true }

        if ($i -lt $maxAttempts) {
            Write-WarnMsg "$ToolName installation may have failed or been cancelled. Retrying..."
        }
    }

    Write-ErrorMsg "Failed to install $ToolName after $maxAttempts attempts."
    return $false
}

function Install-MissingTools {
    <#
    .SYNOPSIS
        Installs a list of missing tools using Chocolatey (Tier 1) then direct
        installers (Tier 2) as fallback.
    .PARAMETER MissingTools Array of tool names to install.
    .OUTPUTS Hashtable: tool name -> $true (installed) / $false (failed)
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string[]] $MissingTools)

    $results = @{}

    # Ensure Chocolatey is available
    $chocoAvailable = Test-ToolOnPath 'choco'
    if (-not $chocoAvailable) {
        $chocoAvailable = Install-Chocolatey
        if ($chocoAvailable) {
            Write-Action "Chocolatey installed successfully."
        } else {
            Write-WarnMsg "Chocolatey unavailable; will attempt direct installers."
        }
    } else {
        $chocoVersion = (& choco --version 2>&1 | Select-Object -First 1)
        Write-Action "Chocolatey found (v$chocoVersion)"
    }

    foreach ($tool in $MissingTools) {
        $installed = $false

        if ($chocoAvailable) {
            $installed = Install-ToolViaChoco -ToolName $tool
            if ($installed) {
                Write-StatusInstalled -Label $tool
            }
        }

        if (-not $installed) {
            Write-WarnMsg "choco install failed for '$tool'; trying direct installer..."
            $installed = Install-ToolDirect -ToolName $tool
            if ($installed) {
                Write-StatusInstalled -Label $tool
            } else {
                Write-StatusFail -Label $tool -Detail 'installation failed'
            }
        }

        $results[$tool] = $installed
    }

    return $results
}

function Assert-BuildTools {
    <#
    .SYNOPSIS
        Checks which required tools are present and installs any that are missing.
    .PARAMETER RequiredTools  Array of tool names required by the build.
    .OUTPUTS Hashtable: tool -> $true (available) / $false (unavailable).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string[]] $RequiredTools)

    Write-Phase 'Checking' 'build tools...'
    $missing = @()
    $found   = @()

    foreach ($tool in $RequiredTools) {
        # For python/pip, also accept python3/pip3 as equivalent
        $aliases = @{ python = @('python', 'python3'); pip = @('pip', 'pip3') }
        $candidates = if ($aliases.ContainsKey($tool)) { $aliases[$tool] } else { @($tool) }

        $resolvedTool = $candidates | Where-Object { Test-ToolOnPath $_ } | Select-Object -First 1

        if ($resolvedTool) {
            $version = & $resolvedTool --version 2>&1 | Select-Object -First 1
            if ($LASTEXITCODE -eq 0) {
                Write-StatusOk -Label $tool -Detail $version
                $found += $tool
            } else {
                # Tool stub found on PATH but non-functional (e.g. Windows App Execution
                # Alias for python.exe that opens the Microsoft Store instead of running).
                Write-StatusNotFound -Label $tool
                $missing += $tool
            }
        } else {
            Write-StatusNotFound -Label $tool
            $missing += $tool
        }
    }

    if ($missing.Count -eq 0) {
        return @{}   # all found, nothing to install
    }

    Write-Blank
    Write-Phase 'Installing' 'missing tools...'
    $results = Install-MissingTools -MissingTools $missing

    # Verify all required tools are now available (confirm they actually work, not just stubs)
    $unavailable = $RequiredTools | Where-Object {
        $candidates = if ($_ -eq 'python') { @('python', 'python3') }
                      elseif ($_ -eq 'pip') { @('pip', 'pip3') }
                      else { @($_) }
        $resolved = $candidates | Where-Object { Test-ToolOnPath $_ } | Select-Object -First 1
        if (-not $resolved) { return $true }
        & $resolved --version 2>&1 | Out-Null
        return $LASTEXITCODE -ne 0
    }
    if ($unavailable) {
        Write-ErrorMsg "The following tools could not be installed: $($unavailable -join ', ')" -ExitCode 1
    }

    return $results
}
