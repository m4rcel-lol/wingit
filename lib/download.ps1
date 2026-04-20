<#
.SYNOPSIS
    Download utilities with progress-bar display for WinGit.
.DESCRIPTION
    Downloads files using curl.exe (preferred on Windows 10+) or
    Invoke-WebRequest as a fallback, and renders an rpm-ostree-style
    progress bar during the transfer.
#>

function Get-CurlPath {
    <#
    .SYNOPSIS Returns the path to curl.exe if available, otherwise $null.
    #>
    try {
        $c = Get-Command 'curl.exe' -ErrorAction Stop
        return $c.Source
    } catch {
        try {
            $c = Get-Command 'curl' -ErrorAction Stop
            # Make sure it is the real curl, not the PowerShell alias
            if ($c.Source -and (Test-Path $c.Source)) { return $c.Source }
        } catch {}
    }
    return $null
}

function Invoke-Download {
    <#
    .SYNOPSIS
        Downloads a file to a local path, showing a progress bar.
    .PARAMETER Url
        The URL to download.
    .PARAMETER Destination
        Full local file path to write the downloaded file to.
    .PARAMETER MaxRetries
        Number of retry attempts on network failure (default: 3).
    .OUTPUTS
        $true on success, throws on failure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Url,
        [Parameter(Mandatory)] [string] $Destination,
        [int] $MaxRetries = 3
    )

    $destDir = [System.IO.Path]::GetDirectoryName($Destination)
    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    $curlPath = Get-CurlPath
    $delay    = 1

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            if ($curlPath) {
                Invoke-CurlDownload -CurlPath $curlPath -Url $Url -Destination $Destination
            } else {
                Invoke-WebRequestDownload -Url $Url -Destination $Destination
            }
            return $true
        } catch {
            if ($attempt -lt $MaxRetries) {
                Write-WarnMsg "Download failed (attempt $attempt/$MaxRetries). Retrying in ${delay}s..."
                Start-Sleep -Seconds $delay
                $delay *= 2
            } else {
                throw "Download failed after $MaxRetries attempts: $($_.Exception.Message)"
            }
        }
    }
}

function Invoke-CurlDownload {
    <#
    .SYNOPSIS Downloads a file via curl.exe and shows a progress bar.
    .PARAMETER CurlPath   Path to curl.exe.
    .PARAMETER Url        URL to download.
    .PARAMETER Destination Local file destination.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $CurlPath,
        [Parameter(Mandatory)] [string] $Url,
        [Parameter(Mandatory)] [string] $Destination
    )

    # Use --write-out to capture total size and --progress-bar for ASCII progress
    # We redirect stderr to a temp file to parse progress; stdout goes to the file.
    $progressFile = [System.IO.Path]::GetTempFileName()
    try {
        $process = Start-Process -FilePath $CurlPath `
            -ArgumentList @('-L', '--silent', '--show-error', '--output', $Destination,
                            '--write-out', '%{size_download}\n%{speed_download}\n%{http_code}',
                            $Url) `
            -NoNewWindow -Wait -PassThru -RedirectStandardOutput $progressFile

        $info = Get-Content $progressFile -Raw
        if ($process.ExitCode -ne 0) {
            throw "curl.exe exited with code $($process.ExitCode)"
        }

        # Parse http_code from write-out (last non-empty line)
        $lines = @(($info -split "`n") | Where-Object { $_.Trim() })
        if ($lines.Count -gt 0) {
            try {
                $httpCode = [int]($lines[-1])
                if ($httpCode -lt 200 -or $httpCode -ge 400) {
                    throw "HTTP $httpCode received from server."
                }
            } catch [System.FormatException] {
                # Could not parse HTTP code — assume success if file was written
            }
        }
    } finally {
        Remove-Item $progressFile -Force -ErrorAction SilentlyContinue
    }

    # Draw a 100% progress bar on completion
    $fileInfo = Get-Item $Destination -ErrorAction SilentlyContinue
    $fileSize = if ($fileInfo) { $fileInfo.Length } else { 0L }
    if ($fileSize) {
        Write-ProgressBar -Current $fileSize -Total $fileSize
    }
}

function Invoke-WebRequestDownload {
    <#
    .SYNOPSIS Downloads a file via Invoke-WebRequest with a live progress bar.
    .PARAMETER Url         URL to download.
    .PARAMETER Destination Local file destination.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Url,
        [Parameter(Mandatory)] [string] $Destination
    )

    $userAgent = if ($script:Version) { "WinGit/$script:Version" } else { 'WinGit' }
    $headers = @{ 'User-Agent' = $userAgent }
    if ($env:GITHUB_TOKEN -and $Url -like '*api.github.com*') {
        $headers['Authorization'] = "token $env:GITHUB_TOKEN"
    }

    # Stream download with manual progress tracking
    $request  = [System.Net.HttpWebRequest]::Create($Url)
    $request.UserAgent = $userAgent
    if ($env:GITHUB_TOKEN -and $Url -like '*api.github.com*') {
        $request.Headers['Authorization'] = "token $env:GITHUB_TOKEN"
    }
    $request.AllowAutoRedirect = $true

    $response     = $request.GetResponse()
    $totalBytes   = $response.ContentLength
    $stream       = $response.GetResponseStream()
    $fileStream   = [System.IO.File]::Create($Destination)
    $buffer       = New-Object byte[] 65536
    $downloaded   = 0L
    $startTime    = [datetime]::UtcNow

    try {
        while ($true) {
            $read = $stream.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) { break }
            $fileStream.Write($buffer, 0, $read)
            $downloaded += $read

            $elapsed  = ([datetime]::UtcNow - $startTime).TotalSeconds
            $speedBps = if ($elapsed -gt 0) { [long]($downloaded / $elapsed) } else { 0L }
            if ($totalBytes -gt 0) {
                Write-ProgressBar -Current $downloaded -Total $totalBytes -SpeedBps $speedBps
            }
        }
        if ($totalBytes -le 0 -and $downloaded -gt 0) {
            Write-ProgressBar -Current $downloaded -Total $downloaded
        }
    } finally {
        $fileStream.Close()
        $stream.Close()
        $response.Close()
    }
}

function Expand-Archive-Compat {
    <#
    .SYNOPSIS
        Extracts a .zip or .tar.gz archive to a destination directory.
    .PARAMETER ArchivePath Path to the archive file.
    .PARAMETER Destination Directory to extract into.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ArchivePath,
        [Parameter(Mandatory)] [string] $Destination
    )

    if (-not (Test-Path $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }

    $name = $ArchivePath.ToLower()
    if ($name.EndsWith('.zip')) {
        Expand-Archive -Path $ArchivePath -DestinationPath $Destination -Force
    } elseif ($name.EndsWith('.tar.gz') -or $name.EndsWith('.tgz')) {
        # Use tar.exe (available on Windows 10 1803+)
        $tarPath = Get-Command 'tar.exe' -ErrorAction SilentlyContinue
        if ($tarPath) {
            $result = Invoke-NativeCommand -FilePath 'tar.exe' -ArgumentList @('-xzf', $ArchivePath, '-C', $Destination)
            if ($result.ExitCode -ne 0) { throw "tar.exe extraction failed (exit $($result.ExitCode))" }
        } else {
            throw "tar.exe not found. Cannot extract .tar.gz archive."
        }
    } else {
        throw "Unsupported archive format: $ArchivePath"
    }
}
