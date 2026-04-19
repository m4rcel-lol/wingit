<#
.SYNOPSIS
    Build system detection and execution for WinGit.
.DESCRIPTION
    Scans a source directory for known build-system indicator files and runs
    the appropriate build sequence, installing the output under the WinGit
    packages directory.
#>

# Priority-ordered list of build system descriptors
$script:BuildSystems = @(
    @{ Name = 'CMake';   Files = @('CMakeLists.txt');                            Tools = @('cmake', 'ninja') }
    @{ Name = 'Make';    Files = @('Makefile');                                  Tools = @('mingw32-make') }
    @{ Name = 'Meson';   Files = @('meson.build');                               Tools = @('meson', 'ninja') }
    @{ Name = 'Cargo';   Files = @('Cargo.toml');                                Tools = @('cargo') }
    @{ Name = 'npm';     Files = @('package.json');                              Tools = @('node', 'npm') }
    @{ Name = 'Python';  Files = @('setup.py', 'pyproject.toml');                Tools = @('python', 'pip') }
    @{ Name = 'Gradle';  Files = @('build.gradle', 'build.gradle.kts');          Tools = @('java', 'gradle') }
    @{ Name = 'Maven';   Files = @('pom.xml');                                   Tools = @('java', 'mvn') }
    @{ Name = 'MSBuild'; Files = @('*.sln', '*.vcxproj');                        Tools = @('msbuild') }
    @{ Name = 'Go';      Files = @('go.mod');                                    Tools = @('go') }
)

function Find-BuildSystem {
    <#
    .SYNOPSIS
        Detects the build system used in a source directory.
    .PARAMETER SourceDir Path to the cloned/extracted source tree.
    .OUTPUTS  A build-system descriptor hashtable, or $null if none detected.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $SourceDir)

    foreach ($bs in $script:BuildSystems) {
        foreach ($pattern in $bs.Files) {
            $match = Get-ChildItem -Path $SourceDir -Filter $pattern -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($match) {
                return @{
                    Name      = $bs.Name
                    Indicator = $match.Name
                    Tools     = $bs.Tools
                }
            }
        }
    }
    return $null
}

function Invoke-CMakeBuild {
    <#
    .SYNOPSIS Runs the CMake build sequence.
    .PARAMETER SourceDir   Source root directory.
    .PARAMETER InstallDir  Destination installation prefix.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SourceDir,
        [Parameter(Mandatory)] [string] $InstallDir
    )

    Push-Location $SourceDir
    try {
        Write-Command 'cmake -S . -B build -DCMAKE_BUILD_TYPE=Release'
        & cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
        if ($LASTEXITCODE -ne 0) { throw "cmake configure failed (exit $LASTEXITCODE)" }

        Write-Command 'cmake --build build --config Release'
        & cmake --build build --config Release
        if ($LASTEXITCODE -ne 0) { throw "cmake build failed (exit $LASTEXITCODE)" }

        Write-Command "cmake --install build --prefix `"$InstallDir`""
        & cmake --install build --prefix $InstallDir
        if ($LASTEXITCODE -ne 0) { throw "cmake install failed (exit $LASTEXITCODE)" }
    } finally {
        Pop-Location
    }
}

function Invoke-CargoBuild {
    <#
    .SYNOPSIS Runs the Cargo build sequence and copies binaries.
    .PARAMETER SourceDir   Source root directory.
    .PARAMETER InstallDir  Destination installation prefix.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SourceDir,
        [Parameter(Mandatory)] [string] $InstallDir
    )

    Push-Location $SourceDir
    try {
        Write-Command 'cargo build --release'
        & cargo build --release
        if ($LASTEXITCODE -ne 0) { throw "cargo build failed (exit $LASTEXITCODE)" }

        $binDir = [System.IO.Path]::Combine($InstallDir, 'bin')
        if (-not (Test-Path $binDir)) { New-Item -ItemType Directory -Path $binDir -Force | Out-Null }

        Get-ChildItem -Path (Join-Path $SourceDir 'target\release') -Filter '*.exe' |
            Copy-Item -Destination $binDir -Force

        Write-SubItem 'Binaries' "→ $binDir"
    } finally {
        Pop-Location
    }
}

function Invoke-NpmBuild {
    <#
    .SYNOPSIS Runs the npm build sequence.
    .PARAMETER SourceDir Source root directory.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $SourceDir)

    Push-Location $SourceDir
    try {
        Write-Command 'npm install'
        & npm install
        if ($LASTEXITCODE -ne 0) { throw "npm install failed (exit $LASTEXITCODE)" }

        Write-Command 'npm run build'
        & npm run build
        if ($LASTEXITCODE -ne 0) { throw "npm run build failed (exit $LASTEXITCODE)" }
    } finally {
        Pop-Location
    }
}

function Invoke-PythonBuild {
    <#
    .SYNOPSIS Runs the Python build sequence.
    .PARAMETER SourceDir Source root directory.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $SourceDir)

    Push-Location $SourceDir
    try {
        if (Test-Path (Join-Path $SourceDir 'setup.py')) {
            Write-Command 'python setup.py install'
            & python setup.py install
            if ($LASTEXITCODE -ne 0) { throw "python setup.py install failed (exit $LASTEXITCODE)" }
        } else {
            Write-Command 'pip install .'
            & pip install .
            if ($LASTEXITCODE -ne 0) { throw "pip install failed (exit $LASTEXITCODE)" }
        }
    } finally {
        Pop-Location
    }
}

function Invoke-GoBuild {
    <#
    .SYNOPSIS Runs the Go build sequence and copies binaries.
    .PARAMETER SourceDir   Source root directory.
    .PARAMETER InstallDir  Destination installation prefix.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SourceDir,
        [Parameter(Mandatory)] [string] $InstallDir
    )

    Push-Location $SourceDir
    try {
        Write-Command 'go build ./...'
        & go build ./...
        if ($LASTEXITCODE -ne 0) { throw "go build failed (exit $LASTEXITCODE)" }

        $binDir = [System.IO.Path]::Combine($InstallDir, 'bin')
        if (-not (Test-Path $binDir)) { New-Item -ItemType Directory -Path $binDir -Force | Out-Null }

        Get-ChildItem -Path $SourceDir -Filter '*.exe' -Depth 0 |
            Copy-Item -Destination $binDir -Force

        Write-SubItem 'Binaries' "→ $binDir"
    } finally {
        Pop-Location
    }
}

function Invoke-MSBuildBuild {
    <#
    .SYNOPSIS Runs the MSBuild build sequence.
    .PARAMETER SourceDir   Source root directory.
    .PARAMETER InstallDir  Destination installation prefix.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SourceDir,
        [Parameter(Mandatory)] [string] $InstallDir
    )

    $slnFile = Get-ChildItem -Path $SourceDir -Filter '*.sln' -Recurse | Select-Object -First 1
    if (-not $slnFile) {
        $slnFile = Get-ChildItem -Path $SourceDir -Filter '*.vcxproj' -Recurse | Select-Object -First 1
    }
    if (-not $slnFile) { throw "No .sln or .vcxproj file found in source tree." }

    Write-Command "msbuild `"$($slnFile.FullName)`" /p:Configuration=Release /p:Platform=x64"
    & msbuild $slnFile.FullName /p:Configuration=Release /p:Platform=x64
    if ($LASTEXITCODE -ne 0) { throw "msbuild failed (exit $LASTEXITCODE)" }
}

function Invoke-MesonBuild {
    <#
    .SYNOPSIS Runs the Meson build sequence.
    .PARAMETER SourceDir   Source root directory.
    .PARAMETER InstallDir  Destination installation prefix.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SourceDir,
        [Parameter(Mandatory)] [string] $InstallDir
    )

    Push-Location $SourceDir
    try {
        Write-Command 'meson setup build'
        & meson setup build
        if ($LASTEXITCODE -ne 0) { throw "meson setup failed (exit $LASTEXITCODE)" }

        Write-Command 'ninja -C build'
        & ninja -C build
        if ($LASTEXITCODE -ne 0) { throw "ninja build failed (exit $LASTEXITCODE)" }

        Write-Command 'ninja -C build install'
        & ninja -C build install
        if ($LASTEXITCODE -ne 0) { throw "ninja install failed (exit $LASTEXITCODE)" }
    } finally {
        Pop-Location
    }
}

function Invoke-MakeBuild {
    <#
    .SYNOPSIS Runs the GNU Make build sequence via mingw32-make.
    .PARAMETER SourceDir   Source root directory.
    .PARAMETER InstallDir  Destination installation prefix.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SourceDir,
        [Parameter(Mandatory)] [string] $InstallDir
    )

    Push-Location $SourceDir
    try {
        Write-Command 'mingw32-make'
        & mingw32-make
        if ($LASTEXITCODE -ne 0) { throw "mingw32-make failed (exit $LASTEXITCODE)" }

        Write-Command "mingw32-make install PREFIX=`"$InstallDir`""
        & mingw32-make install PREFIX=$InstallDir
        if ($LASTEXITCODE -ne 0) { throw "mingw32-make install failed (exit $LASTEXITCODE)" }
    } finally {
        Pop-Location
    }
}

function Invoke-GradleBuild {
    <#
    .SYNOPSIS Runs the Gradle build sequence.
    .PARAMETER SourceDir Source root directory.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $SourceDir)

    Push-Location $SourceDir
    try {
        $gradleCmd = if (Test-Path (Join-Path $SourceDir 'gradlew.bat')) { '.\gradlew.bat' } else { 'gradle' }
        Write-Command "$gradleCmd build"
        & $gradleCmd build
        if ($LASTEXITCODE -ne 0) { throw "gradle build failed (exit $LASTEXITCODE)" }
    } finally {
        Pop-Location
    }
}

function Invoke-MavenBuild {
    <#
    .SYNOPSIS Runs the Maven build sequence.
    .PARAMETER SourceDir Source root directory.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $SourceDir)

    Push-Location $SourceDir
    try {
        Write-Command 'mvn package -DskipTests'
        & mvn package -DskipTests
        if ($LASTEXITCODE -ne 0) { throw "mvn package failed (exit $LASTEXITCODE)" }
    } finally {
        Pop-Location
    }
}

function Add-DirectoryToSystemPath {
    <#
    .SYNOPSIS Adds a directory to the system PATH via the registry (persists across sessions).
    .PARAMETER Directory The directory path to add.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Directory)

    $regKey  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
    $current = (Get-ItemProperty -Path $regKey -Name 'Path').Path

    $entries = $current -split ';' | Where-Object { $_ -ne '' }
    if ($entries -contains $Directory) {
        Write-SubItem 'PATH' "already contains $Directory"
        return
    }

    $newPath = "$current;$Directory"
    Set-ItemProperty -Path $regKey -Name 'Path' -Value $newPath -Type ExpandString
    $env:PATH = "$env:PATH;$Directory"
    Write-SubItem 'PATH' "updated (system-wide)"

    # Notify running processes about environment change
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class WinEnv {
    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
    public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam,
        string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
}
'@
        $result = [UIntPtr]::Zero
        [WinEnv]::SendMessageTimeout([IntPtr]0xffff, 0x1a, [UIntPtr]::Zero,
            'Environment', 0, 1000, [ref]$result) | Out-Null
    } catch {}
}

function Invoke-SourceBuild {
    <#
    .SYNOPSIS
        Orchestrates the full source-build pipeline: detect build system,
        check/install tools, and execute the build.
    .PARAMETER Owner     Repository owner.
    .PARAMETER Repo      Repository name.
    .PARAMETER SourceDir Path to the cloned/extracted source tree.
    .PARAMETER InstallDir Destination installation prefix.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Owner,
        [Parameter(Mandatory)] [string] $Repo,
        [Parameter(Mandatory)] [string] $SourceDir,
        [Parameter(Mandatory)] [string] $InstallDir
    )

    # Detect build system
    Write-Phase 'Detecting' 'build system...'
    $bs = Find-BuildSystem -SourceDir $SourceDir

    if (-not $bs) {
        Write-ErrorMsg ("Could not detect a supported build system in '$Repo'.`n" +
                        "       WinGit currently supports: CMake, Make, Meson, Cargo, npm, Python, Gradle, Maven, MSBuild, Go.`n" +
                        "       You may need to build this project manually.") -ExitCode 1
    }

    Write-SubItem 'Found'      $bs.Indicator
    Write-SubItem 'Build type' $bs.Name
    Write-Blank

    # Ensure required tools are installed
    Assert-BuildTools -RequiredTools $bs.Tools | Out-Null
    Write-Blank

    # Execute build
    Write-Phase 'Building' "$Owner/$Repo..."
    switch ($bs.Name) {
        'CMake'   { Invoke-CMakeBuild   -SourceDir $SourceDir -InstallDir $InstallDir }
        'Make'    { Invoke-MakeBuild    -SourceDir $SourceDir -InstallDir $InstallDir }
        'Meson'   { Invoke-MesonBuild   -SourceDir $SourceDir -InstallDir $InstallDir }
        'Cargo'   { Invoke-CargoBuild   -SourceDir $SourceDir -InstallDir $InstallDir }
        'npm'     { Invoke-NpmBuild     -SourceDir $SourceDir }
        'Python'  { Invoke-PythonBuild  -SourceDir $SourceDir }
        'Gradle'  { Invoke-GradleBuild  -SourceDir $SourceDir }
        'Maven'   { Invoke-MavenBuild   -SourceDir $SourceDir }
        'MSBuild' { Invoke-MSBuildBuild -SourceDir $SourceDir -InstallDir $InstallDir }
        'Go'      { Invoke-GoBuild      -SourceDir $SourceDir -InstallDir $InstallDir }
    }

    Write-Blank
    Write-Phase 'Installing' ''

    $binDir = [System.IO.Path]::Combine($InstallDir, 'bin')
    if (Test-Path $binDir) {
        Write-SubItem 'Binaries' "→ $binDir"
        Add-DirectoryToSystemPath -Directory $binDir
    } else {
        Add-DirectoryToSystemPath -Directory $InstallDir
    }
}
