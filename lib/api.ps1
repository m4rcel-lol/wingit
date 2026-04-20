<#
.SYNOPSIS
    Forge API helper functions for WinGit.
.DESCRIPTION
    Wraps GitHub, GitLab, Gitea, and Forgejo API calls with authentication,
    retry handling, and normalized repository/release metadata.
#>

function Get-SupportedForgeProviders {
    return @('github', 'gitlab', 'gitea', 'forgejo')
}

function Get-NormalizedForgeProvider {
    [CmdletBinding()]
    param([string] $Provider = 'github')

    $providerName = if ($Provider) { $Provider.ToLower() } else { 'github' }
    if ($providerName -notin (Get-SupportedForgeProviders)) {
        Write-ErrorMsg "Unsupported forge provider '$Provider'. Supported: github, gitlab, gitea, forgejo." -ExitCode 1
    }

    return $providerName
}

function Get-ProviderDefaultHost {
    [CmdletBinding()]
    param([string] $Provider = 'github')

    switch (Get-NormalizedForgeProvider -Provider $Provider) {
        'github'  { return 'github.com' }
        'gitlab'  { return 'gitlab.com' }
        'forgejo' { return 'codeberg.org' }
        'gitea'   { return '' }
    }
}

function Get-NormalizedForgeHost {
    [CmdletBinding()]
    param(
        [string] $Provider = 'github',
        [string] $ForgeHost = ''
    )

    $providerName = Get-NormalizedForgeProvider -Provider $Provider
    $resolvedHost = if ($ForgeHost) { $ForgeHost.Trim().Trim('/') } else { Get-ProviderDefaultHost -Provider $providerName }
    if (-not $resolvedHost) {
        Write-ErrorMsg "A host is required for provider '$providerName'. Expected: $providerName <host>/<owner>/<repo>" -ExitCode 1
    }

    return $resolvedHost.ToLower()
}

function Get-ForgeWebRoot {
    [CmdletBinding()]
    param(
        [string] $Provider = 'github',
        [string] $ForgeHost = ''
    )

    return 'https://' + (Get-NormalizedForgeHost -Provider $Provider -ForgeHost $ForgeHost)
}

function Get-ForgeApiRoot {
    [CmdletBinding()]
    param(
        [string] $Provider = 'github',
        [string] $ForgeHost = ''
    )

    $providerName = Get-NormalizedForgeProvider -Provider $Provider
    $hostName = Get-NormalizedForgeHost -Provider $providerName -ForgeHost $ForgeHost

    switch ($providerName) {
        'github' {
            if ($hostName -eq 'github.com') {
                return 'https://api.github.com'
            }
            return "https://$hostName/api/v3"
        }
        'gitlab' {
            return "https://$hostName/api/v4"
        }
        'gitea' {
            return "https://$hostName/api/v1"
        }
        'forgejo' {
            return "https://$hostName/api/v1"
        }
    }
}

function Get-ForgeAuthHeaders {
    [CmdletBinding()]
    param([string] $Provider = 'github')

    $providerName = Get-NormalizedForgeProvider -Provider $Provider
    $userAgent = if ($script:Version) { "WinGit/$script:Version" } else { 'WinGit' }
    $headers = @{
        'User-Agent' = $userAgent
        'Accept'     = 'application/json'
    }

    switch ($providerName) {
        'github' {
            $headers['Accept'] = 'application/vnd.github.v3+json'
            if ($env:GITHUB_TOKEN) {
                $headers['Authorization'] = "token $env:GITHUB_TOKEN"
            }
        }
        'gitlab' {
            if ($env:GITLAB_TOKEN) {
                $headers['PRIVATE-TOKEN'] = $env:GITLAB_TOKEN
            }
        }
        'gitea' {
            if ($env:GITEA_TOKEN) {
                $headers['Authorization'] = "token $env:GITEA_TOKEN"
            }
        }
        'forgejo' {
            if ($env:FORGEJO_TOKEN) {
                $headers['Authorization'] = "token $env:FORGEJO_TOKEN"
            }
        }
    }

    return $headers
}

function Invoke-ApiRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Url,
        [Parameter(Mandatory)] [hashtable] $Headers,
        [Parameter(Mandatory)] [string] $ProviderLabel,
        [int] $MaxRetries = 3
    )

    $delay = 1
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            $prevPref = $ProgressPreference
            $ProgressPreference = 'SilentlyContinue'
            $response = Invoke-WebRequest -Uri $Url -Headers $Headers -UseBasicParsing -ErrorAction Stop
            $ProgressPreference = $prevPref
            return ($response.Content | ConvertFrom-Json)
        } catch {
            $statusCode = 0
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }

            if ($statusCode -eq 404) {
                return $null
            }

            if ($statusCode -eq 403 -and $ProviderLabel -eq 'GitHub') {
                $remaining = $_.Exception.Response.Headers['X-RateLimit-Remaining']
                if ($remaining -and $remaining -eq '0') {
                    Write-ErrorMsg ('GitHub API rate limit exceeded. Set the GITHUB_TOKEN environment variable ' +
                                   'to increase the limit from 60 to 5,000 requests/hour.') -ExitCode 1
                }
            }

            if ($attempt -lt $MaxRetries) {
                Write-WarnMsg "$ProviderLabel API request failed (attempt $attempt/$MaxRetries). Retrying in ${delay}s..."
                Write-Trace "Error detail: $($_.Exception.Message)"
                Start-Sleep -Seconds $delay
                $delay *= 2
            } else {
                Write-ErrorMsg "$ProviderLabel API request failed after $MaxRetries attempts: $($_.Exception.Message)" -ExitCode 1
            }
        }
    }

    return $null
}

function Invoke-GitHubApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Url,
        [int] $MaxRetries = 3
    )

    return Invoke-ApiRequest -Url $Url -Headers (Get-ForgeAuthHeaders -Provider 'github') -ProviderLabel 'GitHub' -MaxRetries $MaxRetries
}

function Invoke-ForgeApi {
    [CmdletBinding()]
    param(
        [string] $Provider = 'github',
        [string] $ForgeHost = '',
        [Parameter(Mandatory)] [string] $RelativePath,
        [int] $MaxRetries = 3
    )

    $providerName = Get-NormalizedForgeProvider -Provider $Provider
    $hostName = Get-NormalizedForgeHost -Provider $providerName -ForgeHost $ForgeHost
    $apiRoot = Get-ForgeApiRoot -Provider $providerName -ForgeHost $hostName
    $url = $apiRoot.TrimEnd('/') + '/' + $RelativePath.TrimStart('/')
    $providerLabel = (Get-Culture).TextInfo.ToTitleCase($providerName)
    return Invoke-ApiRequest -Url $url -Headers (Get-ForgeAuthHeaders -Provider $providerName) -ProviderLabel $providerLabel -MaxRetries $MaxRetries
}

function Resolve-AbsoluteAssetUrl {
    [CmdletBinding()]
    param(
        [string] $Provider = 'github',
        [string] $ForgeHost = '',
        [Parameter(Mandatory)] [string] $Url
    )

    if ($Url -match '^https?://') {
        return $Url
    }

    return (Get-ForgeWebRoot -Provider $Provider -ForgeHost $ForgeHost).TrimEnd('/') + '/' + $Url.TrimStart('/')
}

function Get-RepoWebUrl {
    [CmdletBinding()]
    param(
        [string] $Provider = 'github',
        [string] $ForgeHost = '',
        [Parameter(Mandatory)] [string] $Owner,
        [Parameter(Mandatory)] [string] $Repo
    )

    return (Get-ForgeWebRoot -Provider $Provider -ForgeHost $ForgeHost).TrimEnd('/') + "/$Owner/$Repo"
}

function Get-RepoCloneUrl {
    [CmdletBinding()]
    param(
        [string] $Provider = 'github',
        [string] $ForgeHost = '',
        [Parameter(Mandatory)] [string] $Owner,
        [Parameter(Mandatory)] [string] $Repo
    )

    return (Get-RepoWebUrl -Provider $Provider -ForgeHost $ForgeHost -Owner $Owner -Repo $Repo) + '.git'
}

function Get-RepoArchiveUrl {
    [CmdletBinding()]
    param(
        [string] $Provider = 'github',
        [string] $ForgeHost = '',
        [Parameter(Mandatory)] [string] $Owner,
        [Parameter(Mandatory)] [string] $Repo,
        [Parameter(Mandatory)] [string] $Ref
    )

    $providerName = Get-NormalizedForgeProvider -Provider $Provider
    $webUrl = Get-RepoWebUrl -Provider $providerName -ForgeHost $ForgeHost -Owner $Owner -Repo $Repo

    switch ($providerName) {
        'github' {
            return "$webUrl/archive/refs/heads/$Ref.zip"
        }
        'gitlab' {
            return "$webUrl/-/archive/$Ref/$Repo-$Ref.zip"
        }
        default {
            return "$webUrl/archive/$Ref.zip"
        }
    }
}

function ConvertTo-StandardRepoInfo {
    [CmdletBinding()]
    param(
        [string] $Provider = 'github',
        [string] $ForgeHost = '',
        [Parameter(Mandatory)] [string] $Owner,
        [Parameter(Mandatory)] [string] $Repo,
        [object] $RawInfo
    )

    if (-not $RawInfo) { return $null }

    $providerName = Get-NormalizedForgeProvider -Provider $Provider
    $hostName = Get-NormalizedForgeHost -Provider $providerName -ForgeHost $ForgeHost
    $licenseId = ''
    if ($RawInfo.license) {
        if ($RawInfo.license.spdx_id) {
            $licenseId = [string]$RawInfo.license.spdx_id
        } elseif ($RawInfo.license.name) {
            $licenseId = [string]$RawInfo.license.name
        }
    }

    return [PSCustomObject]@{
        provider          = $providerName
        host              = $hostName
        stargazers_count  = if ($null -ne $RawInfo.stargazers_count) { $RawInfo.stargazers_count } elseif ($null -ne $RawInfo.stars_count) { $RawInfo.stars_count } elseif ($null -ne $RawInfo.star_count) { $RawInfo.star_count } else { 0 }
        forks_count       = if ($null -ne $RawInfo.forks_count) { $RawInfo.forks_count } else { 0 }
        language          = if ($RawInfo.language) { $RawInfo.language } elseif ($RawInfo.primary_language) { $RawInfo.primary_language } else { $null }
        description       = $RawInfo.description
        default_branch    = if ($RawInfo.default_branch) { $RawInfo.default_branch } else { 'main' }
        html_url          = if ($RawInfo.html_url) { $RawInfo.html_url } elseif ($RawInfo.web_url) { $RawInfo.web_url } elseif ($RawInfo.website) { $RawInfo.website } else { Get-RepoWebUrl -Provider $providerName -ForgeHost $hostName -Owner $Owner -Repo $Repo }
        homepage          = if ($RawInfo.homepage) { $RawInfo.homepage } elseif ($RawInfo.website) { $RawInfo.website } else { $null }
        license           = [PSCustomObject]@{ spdx_id = $licenseId }
        full_name         = if ($RawInfo.full_name) { $RawInfo.full_name } elseif ($RawInfo.path_with_namespace) { $RawInfo.path_with_namespace } else { "$Owner/$Repo" }
    }
}

function ConvertTo-StandardReleaseAsset {
    [CmdletBinding()]
    param(
        [string] $Provider = 'github',
        [string] $ForgeHost = '',
        [Parameter(Mandatory)] [object] $RawAsset
    )

    $downloadUrl = if ($RawAsset.browser_download_url) {
        [string]$RawAsset.browser_download_url
    } elseif ($RawAsset.direct_asset_url) {
        Resolve-AbsoluteAssetUrl -Provider $Provider -ForgeHost $ForgeHost -Url ([string]$RawAsset.direct_asset_url)
    } elseif ($RawAsset.url) {
        Resolve-AbsoluteAssetUrl -Provider $Provider -ForgeHost $ForgeHost -Url ([string]$RawAsset.url)
    } else {
        ''
    }

    if (-not $downloadUrl) { return $null }

    return [PSCustomObject]@{
        name                 = [string]$RawAsset.name
        browser_download_url = $downloadUrl
        size                 = if ($null -ne $RawAsset.size) { [int64]$RawAsset.size } else { 0 }
    }
}

function ConvertTo-StandardRelease {
    [CmdletBinding()]
    param(
        [string] $Provider = 'github',
        [string] $ForgeHost = '',
        [object] $RawRelease
    )

    if (-not $RawRelease) { return $null }

    $providerName = Get-NormalizedForgeProvider -Provider $Provider
    $assets = @()
    switch ($providerName) {
        'gitlab' {
            if ($RawRelease.assets -and $RawRelease.assets.links) {
                $assets = @(
                    $RawRelease.assets.links |
                        ForEach-Object { ConvertTo-StandardReleaseAsset -Provider $providerName -ForgeHost $ForgeHost -RawAsset $_ } |
                        Where-Object { $_ }
                )
            }
        }
        default {
            if ($RawRelease.assets) {
                $assets = @(
                    $RawRelease.assets |
                        ForEach-Object { ConvertTo-StandardReleaseAsset -Provider $providerName -ForgeHost $ForgeHost -RawAsset $_ } |
                        Where-Object { $_ }
                )
            }
        }
    }

    return [PSCustomObject]@{
        tag_name      = if ($RawRelease.tag_name) { [string]$RawRelease.tag_name } elseif ($RawRelease.name) { [string]$RawRelease.name } else { '' }
        published_at  = if ($RawRelease.published_at) { [string]$RawRelease.published_at } elseif ($RawRelease.released_at) { [string]$RawRelease.released_at } elseif ($RawRelease.created_at) { [string]$RawRelease.created_at } else { '' }
        prerelease    = if ($null -ne $RawRelease.prerelease) { [bool]$RawRelease.prerelease } else { $false }
        draft         = if ($null -ne $RawRelease.draft) { [bool]$RawRelease.draft } else { $false }
        assets        = @($assets)
    }
}

function ConvertTo-StandardSearchResult {
    [CmdletBinding()]
    param(
        [string] $Provider = 'github',
        [string] $ForgeHost = '',
        [Parameter(Mandatory)] [object] $RawResult
    )

    $providerName = Get-NormalizedForgeProvider -Provider $Provider
    $hostName = Get-NormalizedForgeHost -Provider $providerName -ForgeHost $ForgeHost

    $ownerLogin = ''
    if ($RawResult.owner -and $RawResult.owner.login) {
        $ownerLogin = [string]$RawResult.owner.login
    } elseif ($RawResult.namespace -and $RawResult.namespace.full_path) {
        $ownerLogin = [string]$RawResult.namespace.full_path
    } elseif ($RawResult.owner -and $RawResult.owner.username) {
        $ownerLogin = [string]$RawResult.owner.username
    }

    return [PSCustomObject]@{
        provider          = $providerName
        host              = $hostName
        owner             = [PSCustomObject]@{ login = $ownerLogin }
        name              = if ($RawResult.name) { [string]$RawResult.name } else { '' }
        stargazers_count  = if ($null -ne $RawResult.stargazers_count) { $RawResult.stargazers_count } elseif ($null -ne $RawResult.stars_count) { $RawResult.stars_count } elseif ($null -ne $RawResult.star_count) { $RawResult.star_count } else { 0 }
        language          = if ($RawResult.language) { $RawResult.language } elseif ($RawResult.primary_language) { $RawResult.primary_language } else { $null }
        description       = $RawResult.description
        html_url          = if ($RawResult.html_url) { $RawResult.html_url } elseif ($RawResult.web_url) { $RawResult.web_url } else { Get-RepoWebUrl -Provider $providerName -ForgeHost $hostName -Owner $ownerLogin -Repo ([string]$RawResult.name) }
    }
}

function Get-RepoInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Owner,
        [Parameter(Mandatory)] [string] $Repo,
        [string] $Provider = 'github',
        [string] $ForgeHost = ''
    )

    $providerName = Get-NormalizedForgeProvider -Provider $Provider
    $hostName = Get-NormalizedForgeHost -Provider $providerName -ForgeHost $ForgeHost

    switch ($providerName) {
        'github' {
            return ConvertTo-StandardRepoInfo -Provider $providerName -ForgeHost $hostName -Owner $Owner -Repo $Repo -RawInfo (Invoke-ForgeApi -Provider $providerName -ForgeHost $hostName -RelativePath "/repos/$Owner/$Repo")
        }
        'gitlab' {
            $projectId = [System.Uri]::EscapeDataString("$Owner/$Repo")
            return ConvertTo-StandardRepoInfo -Provider $providerName -ForgeHost $hostName -Owner $Owner -Repo $Repo -RawInfo (Invoke-ForgeApi -Provider $providerName -ForgeHost $hostName -RelativePath "/projects/$projectId")
        }
        default {
            return ConvertTo-StandardRepoInfo -Provider $providerName -ForgeHost $hostName -Owner $Owner -Repo $Repo -RawInfo (Invoke-ForgeApi -Provider $providerName -ForgeHost $hostName -RelativePath "/repos/$Owner/$Repo")
        }
    }
}

function Get-LatestRelease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Owner,
        [Parameter(Mandatory)] [string] $Repo,
        [string] $Provider = 'github',
        [string] $ForgeHost = '',
        [switch] $IncludePrerelease
    )

    $providerName = Get-NormalizedForgeProvider -Provider $Provider
    $hostName = Get-NormalizedForgeHost -Provider $providerName -ForgeHost $ForgeHost

    switch ($providerName) {
        'github' {
            if (-not $IncludePrerelease) {
                return ConvertTo-StandardRelease -Provider $providerName -ForgeHost $hostName -RawRelease (Invoke-ForgeApi -Provider $providerName -ForgeHost $hostName -RelativePath "/repos/$Owner/$Repo/releases/latest")
            }

            $releases = Invoke-ForgeApi -Provider $providerName -ForgeHost $hostName -RelativePath "/repos/$Owner/$Repo/releases?per_page=20"
            if (-not $releases) { return $null }
            $candidate = $releases |
                Where-Object { -not $_.draft } |
                Sort-Object { [datetime]$_.published_at } -Descending |
                Select-Object -First 1
            return ConvertTo-StandardRelease -Provider $providerName -ForgeHost $hostName -RawRelease $candidate
        }
        'gitlab' {
            $projectId = [System.Uri]::EscapeDataString("$Owner/$Repo")
            $releases = Invoke-ForgeApi -Provider $providerName -ForgeHost $hostName -RelativePath "/projects/$projectId/releases?per_page=20"
            if (-not $releases) { return $null }
            $candidate = $releases |
                Where-Object { -not $_.upcoming_release } |
                Sort-Object {
                    if ($_.released_at) { [datetime]$_.released_at }
                    elseif ($_.created_at) { [datetime]$_.created_at }
                    else { [datetime]::MinValue }
                } -Descending |
                Select-Object -First 1
            return ConvertTo-StandardRelease -Provider $providerName -ForgeHost $hostName -RawRelease $candidate
        }
        default {
            if (-not $IncludePrerelease) {
                return ConvertTo-StandardRelease -Provider $providerName -ForgeHost $hostName -RawRelease (Invoke-ForgeApi -Provider $providerName -ForgeHost $hostName -RelativePath "/repos/$Owner/$Repo/releases/latest")
            }

            $releases = Invoke-ForgeApi -Provider $providerName -ForgeHost $hostName -RelativePath "/repos/$Owner/$Repo/releases?limit=20"
            if (-not $releases) { return $null }
            $candidate = $releases |
                Where-Object { -not $_.draft } |
                Sort-Object { [datetime]$_.published_at } -Descending |
                Select-Object -First 1
            return ConvertTo-StandardRelease -Provider $providerName -ForgeHost $hostName -RawRelease $candidate
        }
    }
}

function Search-ForgeRepositories {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Query,
        [string] $Provider = 'github',
        [string] $ForgeHost = '',
        [ValidateRange(1, 50)] [int] $Limit = 10
    )

    $providerName = Get-NormalizedForgeProvider -Provider $Provider
    $hostName = Get-NormalizedForgeHost -Provider $providerName -ForgeHost $ForgeHost
    $encoded = [System.Uri]::EscapeDataString($Query)

    switch ($providerName) {
        'github' {
            $result = Invoke-ForgeApi -Provider $providerName -ForgeHost $hostName -RelativePath "/search/repositories?q=$encoded&sort=stars&order=desc&per_page=$Limit"
            if (-not $result -or -not $result.items) { return @() }
            return @($result.items | ForEach-Object { ConvertTo-StandardSearchResult -Provider $providerName -ForgeHost $hostName -RawResult $_ })
        }
        'gitlab' {
            $result = Invoke-ForgeApi -Provider $providerName -ForgeHost $hostName -RelativePath "/projects?search=$encoded&per_page=$Limit&simple=true"
            if (-not $result) { return @() }
            $projects = @($result | Sort-Object { if ($null -ne $_.star_count) { [int]$_.star_count } else { 0 } } -Descending)
            return @($projects | ForEach-Object { ConvertTo-StandardSearchResult -Provider $providerName -ForgeHost $hostName -RawResult $_ })
        }
        default {
            $result = Invoke-ForgeApi -Provider $providerName -ForgeHost $hostName -RelativePath "/repos/search?q=$encoded&limit=$Limit"
            if (-not $result) { return @() }
            $items = if ($result.data) { @($result.data) } elseif ($result.items) { @($result.items) } else { @($result) }
            return @($items | ForEach-Object { ConvertTo-StandardSearchResult -Provider $providerName -ForgeHost $hostName -RawResult $_ })
        }
    }
}

function Search-GitHubRepositories {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Query,
        [ValidateRange(1, 50)] [int] $Limit = 10
    )

    return Search-ForgeRepositories -Query $Query -Provider 'github' -ForgeHost 'github.com' -Limit $Limit
}

function Select-WindowsAsset {
    <#
    .SYNOPSIS
        Selects the best Windows binary asset from a release's asset list.
    .PARAMETER Assets
        The assets array from a release object.
    .OUTPUTS
        The best-match asset object, or $null if no suitable Windows asset found.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Assets,
        [string] $Architecture = ''
    )

    $extensions = @('.msi', '.exe', '.zip', '.tar.gz')

    $normalizedArch = switch ($Architecture.ToLower()) {
        { $_ -in @('amd64', 'x86_64', 'x64') } { 'x64'; break }
        { $_ -in @('arm64', 'aarch64') }       { 'arm64'; break }
        { $_ -in @('x86', 'i386', 'i686') }    { 'x86'; break }
        default                                { '' }
    }

    $archKeywords = @{
        x64   = @('x86_64', 'x64', 'amd64', 'win64')
        arm64 = @('arm64', 'aarch64')
        x86   = @('x86', 'i386', 'i686', 'win32')
    }

    $windowsKeywords = @('windows', 'win', 'pc-windows')

    $candidates = @()
    if ($normalizedArch -and $archKeywords.ContainsKey($normalizedArch)) {
        $archTokens = $archKeywords[$normalizedArch]
        $candidates = @($Assets | Where-Object {
            $name = $_.name.ToLower()
            ($windowsKeywords | Where-Object { $name -like "*$_*" }) -and
            ($archTokens | Where-Object { $name -like "*$_*" })
        })
    }

    if (-not $candidates -or $candidates.Count -eq 0) {
        $allArchTokens = @($archKeywords.Values | ForEach-Object { $_ }) | Select-Object -Unique
        $candidates = @($Assets | Where-Object {
            $name = $_.name.ToLower()
            ($windowsKeywords | Where-Object { $name -like "*$_*" }) -and
            -not ($allArchTokens | Where-Object { $name -like "*$_*" })
        })
    }

    if ($normalizedArch -and (-not $candidates -or $candidates.Count -eq 0)) {
        return $null
    }

    if (-not $candidates -or $candidates.Count -eq 0) {
        $candidates = @($Assets | Where-Object {
            $name = $_.name.ToLower()
            $windowsKeywords | Where-Object { $name -like "*$_*" }
        })
    }

    if (-not $candidates -or $candidates.Count -eq 0) {
        $candidates = @($Assets | Where-Object {
            $name = $_.name.ToLower()
            $extensions | Where-Object { $name.EndsWith($_) }
        })
    }

    if (-not $candidates -or $candidates.Count -eq 0) { return $null }

    foreach ($ext in $extensions) {
        $match = $candidates | Where-Object { $_.name.ToLower().EndsWith($ext) } | Select-Object -First 1
        if ($match) { return $match }
    }

    return $candidates | Select-Object -First 1
}
