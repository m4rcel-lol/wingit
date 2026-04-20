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
    @{ Name = 'CMake';   Files = @('CMakeLists.txt');                                        Tools = @('cmake', 'ninja') }
    @{ Name = 'Make';    Files = @('Makefile');                                              Tools = @('mingw32-make') }
    @{ Name = 'Meson';   Files = @('meson.build');                                           Tools = @('meson', 'ninja') }
    @{ Name = 'Cargo';   Files = @('Cargo.toml');                                            Tools = @('cargo') }
    @{ Name = 'npm';     Files = @('package.json');                                          Tools = @('node', 'npm') }
    @{ Name = 'Python';  Files = @('setup.py', 'setup.cfg', 'pyproject.toml', 'requirements.txt'); Tools = @('python', 'pip') }
    @{ Name = 'Gradle';  Files = @('build.gradle', 'build.gradle.kts');                     Tools = @('java', 'gradle') }
    @{ Name = 'Maven';   Files = @('pom.xml');                                               Tools = @('java', 'mvn') }
    @{ Name = 'MSBuild'; Files = @('*.sln', '*.vcxproj');                                   Tools = @('msbuild') }
    @{ Name = 'Go';      Files = @('go.mod');                                                Tools = @('go') }
    @{ Name = 'DotNet';  Files = @('*.csproj', '*.fsproj', '*.vbproj');                     Tools = @('dotnet') }
    @{ Name = 'Ruby';    Files = @('Gemfile');                                               Tools = @('ruby', 'bundle') }
    @{ Name = 'Deno';    Files = @('deno.json', 'deno.jsonc');                               Tools = @('deno') }
    @{ Name = 'Zig';     Files = @('build.zig');                                             Tools = @('zig') }
    @{ Name = 'Swift';   Files = @('Package.swift');                                         Tools = @('swift') }
    @{ Name = 'Just';    Files = @('justfile', 'Justfile');                                  Tools = @('just') }
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
            # Use -Recurse for wildcard patterns (e.g. *.sln) since solution files
            # may not always be at the root; exact filenames are checked at root level.
            $searchArgs = @{ Path = $SourceDir; Filter = $pattern; ErrorAction = 'SilentlyContinue' }
            if ($pattern.Contains('*')) { $searchArgs['Recurse'] = $true }
            $match = Get-ChildItem @searchArgs | Select-Object -First 1
            if (-not $match) {
                # Case-insensitive fallback for systems like 'justfile' / 'Justfile'
                $match = Get-ChildItem -Path $SourceDir -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -ieq $pattern } |
                    Select-Object -First 1
            }
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

function Copy-BuildExecutables {
    <#
    .SYNOPSIS Copies built executable files into the package bin directory.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Files,
        [Parameter(Mandatory)] [string] $InstallDir
    )

    $executables = @($Files | Where-Object { $_ })
    if ($executables.Count -eq 0) {
        throw 'Build completed but no executable outputs were found.'
    }

    $binDir = [System.IO.Path]::Combine($InstallDir, 'bin')
    if (-not (Test-Path $binDir)) { New-Item -ItemType Directory -Path $binDir -Force | Out-Null }

    $executables | Copy-Item -Destination $binDir -Force
    Write-SubItem 'Binaries' "→ $binDir"
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
        $result = Invoke-NativeCommand -FilePath 'cmake' -ArgumentList @('-S', '.', '-B', 'build', '-DCMAKE_BUILD_TYPE=Release')
        if ($result.ExitCode -ne 0) { throw "cmake configure failed (exit $($result.ExitCode))" }

        Write-Command 'cmake --build build --config Release'
        $result = Invoke-NativeCommand -FilePath 'cmake' -ArgumentList @('--build', 'build', '--config', 'Release')
        if ($result.ExitCode -ne 0) { throw "cmake build failed (exit $($result.ExitCode))" }

        Write-Command "cmake --install build --prefix `"$InstallDir`""
        $result = Invoke-NativeCommand -FilePath 'cmake' -ArgumentList @('--install', 'build', '--prefix', $InstallDir)
        if ($result.ExitCode -ne 0) { throw "cmake install failed (exit $($result.ExitCode))" }
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
        $result = Invoke-NativeCommand -FilePath 'cargo' -ArgumentList @('build', '--release')
        if ($result.ExitCode -ne 0) { throw "cargo build failed (exit $($result.ExitCode))" }

        Copy-BuildExecutables -Files (Get-ChildItem -Path (Join-Path $SourceDir 'target\release') -Filter '*.exe' -ErrorAction SilentlyContinue) -InstallDir $InstallDir
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
        $result = Invoke-NativeCommand -FilePath 'npm' -ArgumentList @('install')
        if ($result.ExitCode -ne 0) { throw "npm install failed (exit $($result.ExitCode))" }

        Write-Command 'npm run build'
        $result = Invoke-NativeCommand -FilePath 'npm' -ArgumentList @('run', 'build')
        if ($result.ExitCode -ne 0) { throw "npm run build failed (exit $($result.ExitCode))" }
    } finally {
        Pop-Location
    }
}

function Invoke-PythonBuild {
    <#
    .SYNOPSIS Runs the Python build/install sequence.
    .DESCRIPTION
        Supports setup.py, setup.cfg, pyproject.toml, and requirements.txt projects.
        Falls back to python3/pip3 when python/pip are not on PATH.
    .PARAMETER SourceDir Source root directory.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $SourceDir)

    # Resolve python / pip executables, accepting python3 / pip3 as fallbacks
    $pythonCmd = if (Test-ToolOnPath 'python') { 'python' }
                 elseif (Test-ToolOnPath 'python3') { 'python3' }
                 else { 'python' }
    $pipCmd    = if (Test-ToolOnPath 'pip') { 'pip' }
                 elseif (Test-ToolOnPath 'pip3') { 'pip3' }
                 else { 'pip' }

    Push-Location $SourceDir
    try {
        if (Test-Path (Join-Path $SourceDir 'setup.py')) {
            Write-Command "$pythonCmd setup.py install"
            $result = Invoke-NativeCommand -FilePath $pythonCmd -ArgumentList @('setup.py', 'install')
            if ($result.ExitCode -ne 0) { throw "$pythonCmd setup.py install failed (exit $($result.ExitCode))" }
        } elseif (Test-Path (Join-Path $SourceDir 'setup.cfg')) {
            # Modern setuptools — use pip install .
            Write-Command "$pipCmd install ."
            $result = Invoke-NativeCommand -FilePath $pipCmd -ArgumentList @('install', '.')
            if ($result.ExitCode -ne 0) { throw "$pipCmd install failed (exit $($result.ExitCode))" }
        } elseif (Test-Path (Join-Path $SourceDir 'pyproject.toml')) {
            Write-Command "$pipCmd install ."
            $result = Invoke-NativeCommand -FilePath $pipCmd -ArgumentList @('install', '.')
            if ($result.ExitCode -ne 0) { throw "$pipCmd install failed (exit $($result.ExitCode))" }
        } elseif (Test-Path (Join-Path $SourceDir 'requirements.txt')) {
            Write-Command "$pipCmd install -r requirements.txt"
            $result = Invoke-NativeCommand -FilePath $pipCmd -ArgumentList @('install', '-r', 'requirements.txt')
            if ($result.ExitCode -ne 0) { throw "$pipCmd install -r requirements.txt failed (exit $($result.ExitCode))" }
        } else {
            # Best-effort: try pip install .
            Write-Command "$pipCmd install ."
            $result = Invoke-NativeCommand -FilePath $pipCmd -ArgumentList @('install', '.')
            if ($result.ExitCode -ne 0) { throw "$pipCmd install failed (exit $($result.ExitCode))" }
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
        $result = Invoke-NativeCommand -FilePath 'go' -ArgumentList @('build', './...')
        if ($result.ExitCode -ne 0) { throw "go build failed (exit $($result.ExitCode))" }

        Copy-BuildExecutables -Files (Get-ChildItem -Path $SourceDir -Filter '*.exe' -ErrorAction SilentlyContinue) -InstallDir $InstallDir
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
    $result = Invoke-NativeCommand -FilePath 'msbuild' -ArgumentList @($slnFile.FullName, '/p:Configuration=Release', '/p:Platform=x64')
    if ($result.ExitCode -ne 0) { throw "msbuild failed (exit $($result.ExitCode))" }

    $builtExecutables = Get-ChildItem -Path $SourceDir -Filter '*.exe' -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\(Release|x64|bin)\\' }
    Copy-BuildExecutables -Files $builtExecutables -InstallDir $InstallDir
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
        Write-Command "meson setup build --prefix `"$InstallDir`""
        $result = Invoke-NativeCommand -FilePath 'meson' -ArgumentList @('setup', 'build', '--prefix', $InstallDir)
        if ($result.ExitCode -ne 0) { throw "meson setup failed (exit $($result.ExitCode))" }

        Write-Command 'meson compile -C build'
        $result = Invoke-NativeCommand -FilePath 'meson' -ArgumentList @('compile', '-C', 'build')
        if ($result.ExitCode -ne 0) { throw "meson compile failed (exit $($result.ExitCode))" }

        Write-Command 'meson install -C build'
        $result = Invoke-NativeCommand -FilePath 'meson' -ArgumentList @('install', '-C', 'build')
        if ($result.ExitCode -ne 0) { throw "meson install failed (exit $($result.ExitCode))" }
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
        $result = Invoke-NativeCommand -FilePath 'mingw32-make' -ArgumentList @()
        if ($result.ExitCode -ne 0) { throw "mingw32-make failed (exit $($result.ExitCode))" }

        Write-Command "mingw32-make install PREFIX=`"$InstallDir`""
        $result = Invoke-NativeCommand -FilePath 'mingw32-make' -ArgumentList @('install', "PREFIX=$InstallDir")
        if ($result.ExitCode -ne 0) { throw "mingw32-make install failed (exit $($result.ExitCode))" }
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
        $result = Invoke-NativeCommand -FilePath $gradleCmd -ArgumentList @('build')
        if ($result.ExitCode -ne 0) { throw "gradle build failed (exit $($result.ExitCode))" }
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
        $result = Invoke-NativeCommand -FilePath 'mvn' -ArgumentList @('package', '-DskipTests')
        if ($result.ExitCode -ne 0) { throw "mvn package failed (exit $($result.ExitCode))" }
    } finally {
        Pop-Location
    }
}

function Invoke-DotNetBuild {
    <#
    .SYNOPSIS Runs the .NET SDK build and publish sequence.
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
        $buildConfiguration = if ($env:BUILD_CONFIGURATION) { $env:BUILD_CONFIGURATION } else { 'Release' }

        Write-Command 'dotnet restore'
        $result = Invoke-NativeCommand -FilePath 'dotnet' -ArgumentList @('restore')
        if ($result.ExitCode -ne 0) { throw "dotnet restore failed (exit $($result.ExitCode))" }

        $publishDir = [System.IO.Path]::Combine($InstallDir, 'bin')
        $publishArgs = @('publish', '-c', $buildConfiguration, '-o', $publishDir)
        $projectFile = Get-ChildItem -Path $SourceDir -File -Recurse -Include *.csproj, *.fsproj, *.vbproj | Select-Object -First 1
        $isWindowsTarget = $false

        if ($projectFile) {
            try {
                [xml] $projectXml = Get-Content -Path $projectFile.FullName -Raw
                $tfmNodes = @(
                    $projectXml.Project.PropertyGroup.TargetFramework,
                    $projectXml.Project.PropertyGroup.TargetFrameworks
                ) | Where-Object { $_ }

                $tfms = @($tfmNodes) -join ';'
                if ($tfms -match 'windows') {
                    $isWindowsTarget = $true
                }
            } catch {
                Write-WarnMsg "Unable to inspect target framework in $($projectFile.Name). Continuing with default dotnet publish arguments."
            }
        }

        if ($isWindowsTarget) {
            $publishArgs += @(
                '-r', 'win-x64',
                '-p:Platform=x64',
                '-p:WindowsPackageType=None',
                '-p:WindowsAppSDKSelfContained=true',
                '-p:SelfContained=true',
                '-p:PublishSingleFile=false'
            )
        }

        Write-Command ("dotnet " + ($publishArgs -join ' '))
        $result = Invoke-NativeCommand -FilePath 'dotnet' -ArgumentList $publishArgs
        if ($result.ExitCode -ne 0) { throw "dotnet publish failed (exit $($result.ExitCode))" }

        Write-SubItem 'Output' "→ $publishDir"
    } finally {
        Pop-Location
    }
}

function Invoke-RubyBuild {
    <#
    .SYNOPSIS Runs the Ruby/Bundler build sequence.
    .PARAMETER SourceDir Source root directory.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $SourceDir)

    Push-Location $SourceDir
    try {
        Write-Command 'bundle install'
        $result = Invoke-NativeCommand -FilePath 'bundle' -ArgumentList @('install')
        if ($result.ExitCode -ne 0) { throw "bundle install failed (exit $($result.ExitCode))" }

        # If a Rakefile exists, run rake build/install
        if (Test-Path (Join-Path $SourceDir 'Rakefile')) {
            Write-Command 'bundle exec rake install'
            $result = Invoke-NativeCommand -FilePath 'bundle' -ArgumentList @('exec', 'rake', 'install')
            if ($result.ExitCode -ne 0) {
                Write-WarnMsg "rake install failed; dependencies installed but no rake install target."
            }
        }
    } finally {
        Pop-Location
    }
}

function Invoke-DenoBuild {
    <#
    .SYNOPSIS Runs the Deno build/compile sequence.
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
        # Detect entry point
        $entryPoint = $null
        foreach ($candidate in @('main.ts', 'main.js', 'src/main.ts', 'src/main.js', 'mod.ts', 'mod.js')) {
            $fullPath = Join-Path $SourceDir $candidate
            if (Test-Path $fullPath) { $entryPoint = $candidate; break }
        }

        if ($entryPoint) {
            $binDir = [System.IO.Path]::Combine($InstallDir, 'bin')
            if (-not (Test-Path $binDir)) { New-Item -ItemType Directory -Path $binDir -Force | Out-Null }
            $exeName = [System.IO.Path]::GetFileNameWithoutExtension($SourceDir) + '.exe'
            $outPath = [System.IO.Path]::Combine($binDir, $exeName)

            Write-Command "deno compile --allow-all --output `"$outPath`" $entryPoint"
            $result = Invoke-NativeCommand -FilePath 'deno' -ArgumentList @('compile', '--allow-all', '--output', $outPath, $entryPoint)
            if ($result.ExitCode -ne 0) { throw "deno compile failed (exit $($result.ExitCode))" }
            Write-SubItem 'Binary' "→ $outPath"
        } else {
            # No entry point found — run deno cache on all TS/JS files
            $tsFile = Get-ChildItem -Path $SourceDir -Filter '*.ts' -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 1 -ExpandProperty FullName
            if (-not $tsFile) {
                throw 'No Deno entry point or TypeScript files were found.'
            }
            Write-Command 'deno cache <first-ts-file>'
            $result = Invoke-NativeCommand -FilePath 'deno' -ArgumentList @('cache', $tsFile)
            if ($result.ExitCode -ne 0) { throw "deno cache failed (exit $($result.ExitCode))" }
            Write-WarnMsg "No entry point found; cached dependencies only."
        }
    } finally {
        Pop-Location
    }
}

function Invoke-ZigBuild {
    <#
    .SYNOPSIS Runs the Zig build sequence.
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
        Write-Command 'zig build -Doptimize=ReleaseSafe'
        $result = Invoke-NativeCommand -FilePath 'zig' -ArgumentList @('build', '-Doptimize=ReleaseSafe')
        if ($result.ExitCode -ne 0) { throw "zig build failed (exit $($result.ExitCode))" }

        # Zig outputs to zig-out/bin by default
        $zigOut = Join-Path $SourceDir 'zig-out\bin'
        if (Test-Path $zigOut) {
            Copy-BuildExecutables -Files (Get-ChildItem -Path $zigOut -Filter '*.exe' -ErrorAction SilentlyContinue) -InstallDir $InstallDir
        }
    } finally {
        Pop-Location
    }
}

function Invoke-SwiftBuild {
    <#
    .SYNOPSIS Runs the Swift Package Manager build sequence.
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
        Write-Command 'swift build -c release'
        $result = Invoke-NativeCommand -FilePath 'swift' -ArgumentList @('build', '-c', 'release')
        if ($result.ExitCode -ne 0) { throw "swift build failed (exit $($result.ExitCode))" }

        $swiftRelease = Join-Path $SourceDir '.build\release'
        if (Test-Path $swiftRelease) {
            Copy-BuildExecutables -Files (Get-ChildItem -Path $swiftRelease -Filter '*.exe' -ErrorAction SilentlyContinue) -InstallDir $InstallDir
        }
    } finally {
        Pop-Location
    }
}

function Invoke-JustBuild {
    <#
    .SYNOPSIS Runs the Just command runner build recipe.
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
        # Try common build/install recipe names in order
        $ran = $false
        foreach ($recipe in @('install', 'build', 'release')) {
            $result = Invoke-NativeCommand -FilePath 'just' -ArgumentList @('--list') -CaptureOutput
            $recipeList = $result.Output
            if ($recipeList -match "\b$recipe\b") {
                Write-Command "just $recipe"
                $result = Invoke-NativeCommand -FilePath 'just' -ArgumentList @($recipe)
                if ($result.ExitCode -ne 0) { throw "just $recipe failed (exit $($result.ExitCode))" }
                $ran = $true
                break
            }
        }
        if (-not $ran) {
            # Default recipe
            Write-Command 'just'
            $result = Invoke-NativeCommand -FilePath 'just' -ArgumentList @()
            if ($result.ExitCode -ne 0) { throw "just (default recipe) failed (exit $($result.ExitCode))" }
        }
    } finally {
        Pop-Location
    }
}

function Get-NormalizedDirectoryPath {
    <#
    .SYNOPSIS Normalises a directory path for case-insensitive PATH comparisons.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    $expanded = [Environment]::ExpandEnvironmentVariables($Path).Trim().Trim('"')
    try {
        $fullPath = [System.IO.Path]::GetFullPath($expanded)
    } catch {
        $fullPath = $expanded
    }

    if ($fullPath.Length -gt 3) {
        return $fullPath.TrimEnd('\\')
    }

    return $fullPath
}

function Get-SystemPathEntries {
    <#
    .SYNOPSIS Returns the machine PATH as a list of entries.
    #>
    [CmdletBinding()]
    param()

    $regKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
    $current = (Get-ItemProperty -Path $regKey -Name 'Path' -ErrorAction SilentlyContinue).Path
    if (-not $current) { return @() }

    return @(
        $current -split ';' |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }
    )
}

function Invoke-EnvironmentChangeBroadcast {
    <#
    .SYNOPSIS Broadcasts a system environment change to running processes.
    #>
    [CmdletBinding()]
    param()

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

function Add-DirectoryToSystemPath {
    <#
    .SYNOPSIS Adds a directory to the system PATH via the registry (persists across sessions).
    .PARAMETER Directory The directory path to add.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Directory)

    $regKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
    $entries = @(Get-SystemPathEntries)
    $targetPath = Get-NormalizedDirectoryPath -Path $Directory

    $alreadyPresent = $entries | Where-Object {
        (Get-NormalizedDirectoryPath -Path $_) -ieq $targetPath
    } | Select-Object -First 1

    if ($alreadyPresent) {
        Write-SubItem 'PATH' "already contains $Directory"
        return $false
    }

    $newPath = if ($entries.Count -gt 0) {
        (@($entries) + $Directory) -join ';'
    } else {
        $Directory
    }

    Set-ItemProperty -Path $regKey -Name 'Path' -Value $newPath -Type ExpandString
    Update-EnvironmentPath
    Write-SubItem 'PATH' "updated (system-wide)"
    Invoke-EnvironmentChangeBroadcast
    return $true
}

function Test-DirectoryInSystemPath {
    <#
    .SYNOPSIS Checks whether a directory is currently registered on the machine PATH.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Directory)

    $targetPath = Get-NormalizedDirectoryPath -Path $Directory
    return [bool](Get-SystemPathEntries | Where-Object {
        (Get-NormalizedDirectoryPath -Path $_) -ieq $targetPath
    } | Select-Object -First 1)
}

function Remove-DirectoryFromSystemPath {
    <#
    .SYNOPSIS Removes a directory from the system PATH when present.
    .PARAMETER Directory The directory path to remove.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Directory)

    $regKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
    $entries = @(Get-SystemPathEntries)
    $targetPath = Get-NormalizedDirectoryPath -Path $Directory
    $remaining = @($entries | Where-Object {
        (Get-NormalizedDirectoryPath -Path $_) -ine $targetPath
    })

    if ($remaining.Count -eq $entries.Count) {
        Write-SubItem 'PATH' "no entry for $Directory"
        return $false
    }

    Set-ItemProperty -Path $regKey -Name 'Path' -Value ($remaining -join ';') -Type ExpandString
    Update-EnvironmentPath
    Write-SubItem 'PATH' "removed $Directory"
    Invoke-EnvironmentChangeBroadcast
    return $true
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
        throw ("Could not detect a supported build system in '$Repo'.`n" +
               "       WinGit currently supports: CMake, Make, Meson, Cargo, npm, Python, Gradle, Maven, MSBuild, Go, DotNet, Ruby, Deno, Zig, Swift, Just.`n" +
               "       You may need to build this project manually.")
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
        'DotNet'  { Invoke-DotNetBuild  -SourceDir $SourceDir -InstallDir $InstallDir }
        'Ruby'    { Invoke-RubyBuild    -SourceDir $SourceDir }
        'Deno'    { Invoke-DenoBuild    -SourceDir $SourceDir -InstallDir $InstallDir }
        'Zig'     { Invoke-ZigBuild     -SourceDir $SourceDir -InstallDir $InstallDir }
        'Swift'   { Invoke-SwiftBuild   -SourceDir $SourceDir -InstallDir $InstallDir }
        'Just'    { Invoke-JustBuild    -SourceDir $SourceDir -InstallDir $InstallDir }
    }

    Write-Blank
    Write-Phase 'Installing' ''

    $pathEntries = @()
    $binDir = [System.IO.Path]::Combine($InstallDir, 'bin')
    if (Test-Path $binDir) {
        Write-SubItem 'Binaries' "→ $binDir"
        Add-DirectoryToSystemPath -Directory $binDir
        $pathEntries += $binDir
    } else {
        Add-DirectoryToSystemPath -Directory $InstallDir
        $pathEntries += $InstallDir
    }

    return @($pathEntries)
}
