# WinGit — GitHub-native package manager for Windows

WinGit installs software directly from GitHub repositories. It downloads the
latest release binary when one is available, or clones the source and compiles
it locally when no binary release exists.

---

## Features

- **Release install** — auto-detects `x64` or `arm64` and downloads the matching Windows binary asset (`.msi`, `.exe`, `.zip`, `.tar.gz`) from the latest GitHub release.
- **Source build** — auto-detects the build system (CMake, Cargo, Go, npm, Python, Gradle, Maven, MSBuild, Meson, Make) and compiles from source.
- **Update** — updates an installed package to the latest version, or updates all packages at once with `--all`.
- **Package pinning** — pin packages to keep them out of `update --all` until you explicitly unpin them.
- **Outdated report** — checks installed release packages and shows which ones have updates available.
- **Info** — shows GitHub metadata and local install details for any package.
- **Manifest export/import** — snapshot installed packages to JSON and recreate them on another machine.
- **Search** — searches GitHub repositories and prints the top matches with stars, language, and URLs.
- **Doctor** — checks environment readiness (core/build tools + GitHub API rate-limit status).
- **Dependency bootstrapping** — installs missing build tools automatically via Chocolatey, with direct-installer fallback.
- **rpm-ostree-style output** — structured, phase-labelled terminal output with progress bars and spinners.
- **CMD & PowerShell** — works identically from both `cmd.exe` and `powershell.exe` (no execution-policy errors).
- **Verbose mode** — pass `-v` or `--verbose` to see diagnostic URLs and extra detail.
- **Source fallback** — if the machine architecture is not `x64` or `arm64`, WinGit skips release binaries and builds from source in `%TEMP%`.
- **Forced source builds** — pass `--source` when you want to compile from source even if a release asset exists.
- **Package registry** — tracks installed packages in `%PROGRAMDATA%\WinGit\registry.json`.
- **PATH hygiene** — records package PATH entries so `remove` cleans them up instead of leaving stale entries behind.
- **GitHub API auth** — set `GITHUB_TOKEN` to increase the API rate limit from 60 to 5,000 requests/hour.

---

## Installation

Run the self-installer from an **elevated** (Administrator) PowerShell prompt:

```powershell
git clone https://github.com/m4rcel-lol/wingit.git
cd wingit
.\install.ps1
```

Then open a new terminal — `wingit` will be on your PATH.

---

## Usage

```
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
wingit --help                   Show help
```

### Options

```
-v, --verbose   Show verbose diagnostic output (API URLs, paths, extra detail)
--arch <x64|arm64|x86>   Override the auto-detected release architecture
--pre-release   Allow prerelease versions in install and update checks
--source   Force a source build even when a release asset exists
```

### Examples

```powershell
# Install GitHub CLI (release binary)
wingit install cli/cli

# Install Neovim (source build if no Windows binary found)
wingit install neovim/neovim

# Force a source build even when a release asset exists
wingit install sharkdp/bat --source

# Install ripgrep
wingit install BurntSushi/ripgrep

# Update a package to the latest version
wingit update cli/cli

# Update all installed packages
wingit update --all

# Pin a package so update --all leaves it alone
wingit pin cli/cli

# Show package info (GitHub metadata + local install details)
wingit info cli/cli

# List installed packages
wingit list

# Check outdated packages
wingit outdated

# Search for packages related to "terminal"
wingit search terminal

# Check environment/tooling health
wingit doctor

# Remove a package
wingit remove cli/cli

# Export installed packages to a reusable manifest
wingit export packages.json

# Install packages from a saved manifest
wingit import packages.json

# Install with verbose diagnostic output
wingit install cli/cli -v
```

### Manifest format

```json
{
  "manifest_version": 1,
  "packages": [
    {
      "repository": "cli/cli",
      "install_type": "release",
      "architecture": "x64",
      "include_prerelease": false,
      "pinned": true
    },
    {
      "repository": "BurntSushi/ripgrep",
      "install_type": "source",
      "include_prerelease": false,
      "pinned": false
    }
  ]
}
```

### Environment variables

| Variable       | Description |
|----------------|-------------|
| `GITHUB_TOKEN` | Personal access token — raises API rate limit to 5,000/hr |

---

## Output style

WinGit emulates the rpm-ostree terminal style:

```
WinGit  -- GitHub-native package manager for Windows

Resolving    cli/cli...
  Repository : https://github.com/cli/cli
  Stars      : 37,842
  Language   : Go
  About      : GitHub's official command line tool

Checking     releases...
  Latest     : v2.62.0  (2024-11-15)
  Asset      : gh_2.62.0_windows_amd64.msi  (12.4 MB)

Downloading  gh_2.62.0_windows_amd64.msi
  [=============================================>    ]   89%  10.2 MB/s

Installing   gh_2.62.0_windows_amd64.msi
  Method     : msiexec /quiet

Complete.
  cli/cli v2.62.0 is now installed.
  Run 'gh --version' to verify.
```

---

## Project structure

```
WinGit/
├── wingit.cmd          ← Entry point for CMD and PowerShell (uses -ExecutionPolicy Bypass)
├── wingit-core.ps1     ← Core logic (argument parsing + command dispatch)
├── lib/
│   ├── api.ps1         ← GitHub API functions
│   ├── download.ps1    ← Download + progress bar utilities
│   ├── build.ps1       ← Build system detection + execution
│   ├── tools.ps1       ← Build tool installation (Chocolatey / direct)
│   ├── registry.ps1    ← Package registry read/write
│   ├── output.ps1      ← Terminal output/formatting functions
│   └── elevation.ps1   ← Admin privilege detection and re-launch
├── install.ps1         ← WinGit self-installer
└── README.md
```

> **Note:** The core logic lives in `wingit-core.ps1`, not `wingit.ps1`. This ensures
> that typing `wingit` in PowerShell resolves to `wingit.cmd` (which passes
> `-ExecutionPolicy Bypass`), rather than directly invoking the `.ps1` script and
> hitting an execution-policy error.

---

## Supported build systems

| Indicator file(s)              | Build system  |
|--------------------------------|---------------|
| `CMakeLists.txt`               | CMake         |
| `Makefile`                     | GNU Make      |
| `meson.build`                  | Meson         |
| `Cargo.toml`                   | Rust / Cargo  |
| `package.json`                 | Node.js / npm |
| `setup.py` / `pyproject.toml`  | Python        |
| `build.gradle` / `build.gradle.kts` | Gradle   |
| `pom.xml`                      | Maven         |
| `*.sln` / `*.vcxproj`          | MSBuild / VS  |
| `go.mod`                       | Go            |

---

## License

See [LICENSE](LICENSE).
