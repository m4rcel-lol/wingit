<#
.SYNOPSIS
    GitHub REST API helper functions for WinGit.
.DESCRIPTION
    Wraps GitHub API calls with authentication support, rate-limit handling,
    and exponential-backoff retry logic.
#>

function Invoke-GitHubApi {
    <#
    .SYNOPSIS
        Performs a GitHub REST API GET request with retry and auth support.
    .PARAMETER Url
        The full GitHub API URL to request.
    .PARAMETER MaxRetries
        Maximum number of retry attempts (default: 3).
    .OUTPUTS
        Parsed JSON response object, or $null on failure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Url,
        [int] $MaxRetries = 3
    )

    $headers = @{
        'User-Agent' = 'WinGit/1.0'
        'Accept'     = 'application/vnd.github.v3+json'
    }

    if ($env:GITHUB_TOKEN) {
        $headers['Authorization'] = "token $env:GITHUB_TOKEN"
    }

    $delay = 1
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            $prevPref = $ProgressPreference
            $ProgressPreference = 'SilentlyContinue'
            $response = Invoke-WebRequest -Uri $Url -Headers $headers -UseBasicParsing -ErrorAction Stop
            $ProgressPreference = $prevPref
            return ($response.Content | ConvertFrom-Json)
        } catch {
            $statusCode = 0
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }

            if ($statusCode -eq 404) {
                return $null   # caller interprets as not found
            }

            if ($statusCode -eq 403) {
                $remaining = $_.Exception.Response.Headers['X-RateLimit-Remaining']
                if ($remaining -and $remaining -eq '0') {
                    Write-ErrorMsg ('GitHub API rate limit exceeded. Set the GITHUB_TOKEN environment variable ' +
                                   'to increase the limit from 60 to 5,000 requests/hour.') -ExitCode 1
                }
            }

            if ($attempt -lt $MaxRetries) {
                Write-WarnMsg "GitHub API request failed (attempt $attempt/$MaxRetries). Retrying in ${delay}s..."
                Write-Trace "Error detail: $($_.Exception.Message)"
                Start-Sleep -Seconds $delay
                $delay *= 2
            } else {
                Write-ErrorMsg "GitHub API request failed after $MaxRetries attempts: $($_.Exception.Message)" -ExitCode 1
            }
        }
    }
    return $null
}

function Get-RepoInfo {
    <#
    .SYNOPSIS
        Retrieves metadata for a GitHub repository.
    .PARAMETER Owner
        Repository owner (user or organisation).
    .PARAMETER Repo
        Repository name.
    .OUTPUTS
        Repository metadata object, or $null if not found.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Owner,
        [Parameter(Mandatory)] [string] $Repo
    )

    $url  = "https://api.github.com/repos/$Owner/$Repo"
    $info = Invoke-GitHubApi -Url $url
    return $info
}

function Get-LatestRelease {
    <#
    .SYNOPSIS
        Retrieves the latest GitHub release for a repository.
    .PARAMETER Owner
        Repository owner.
    .PARAMETER Repo
        Repository name.
    .OUTPUTS
        Release object (with .assets, .tag_name, etc.), or $null if none exists.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Owner,
        [Parameter(Mandatory)] [string] $Repo
    )

    $url     = "https://api.github.com/repos/$Owner/$Repo/releases/latest"
    $release = Invoke-GitHubApi -Url $url
    return $release
}

function Search-GitHubRepositories {
    <#
    .SYNOPSIS
        Searches GitHub repositories and returns ranked results.
    .PARAMETER Query
        Search query string.
    .PARAMETER Limit
        Maximum number of results to return (1-50).
    .OUTPUTS
        Array of repository result objects.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Query,
        [ValidateRange(1, 50)] [int] $Limit = 10
    )

    $encoded = [System.Uri]::EscapeDataString($Query)
    $url = "https://api.github.com/search/repositories?q=$encoded&sort=stars&order=desc&per_page=$Limit"
    $result = Invoke-GitHubApi -Url $url

    if (-not $result -or -not $result.items) { return @() }
    return @($result.items)
}

function Select-WindowsAsset {
    <#
    .SYNOPSIS
        Selects the best Windows binary asset from a release's asset list.
    .PARAMETER Assets
        The assets array from a GitHub release object.
    .OUTPUTS
        The best-match asset object, or $null if no suitable Windows asset found.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Assets
    )

    $windowsKeywords = @('windows', 'win64', 'win32', 'win-', 'x86_64-pc-windows', 'x64', 'amd64')
    $extensions      = @('.msi', '.exe', '.zip', '.tar.gz')

    # Filter to Windows-relevant assets only
    $candidates = $Assets | Where-Object {
        $name = $_.name.ToLower()
        $windowsKeywords | Where-Object { $name -like "*$_*" }
    }

    if (-not $candidates) {
        # Broaden: no platform keyword — include all assets matching an extension
        $candidates = $Assets | Where-Object {
            $name = $_.name.ToLower()
            $extensions | Where-Object { $name.EndsWith($_) }
        }
    }

    if (-not $candidates) { return $null }

    # Pick by extension priority
    foreach ($ext in $extensions) {
        $match = $candidates | Where-Object { $_.name.ToLower().EndsWith($ext) } | Select-Object -First 1
        if ($match) { return $match }
    }

    return $null
}
