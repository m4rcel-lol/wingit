# WinGit — GitHub-native package manager for Windows

WinGit installs software directly from GitHub repositories. It downloads the
latest release binary when one is available, or clones the source and compiles
it locally when no binary release exists.

---

## Features

- **Release install** — downloads the best Windows binary asset (`.msi`, `.exe`, `.zip`, `.tar.gz`) from the latest GitHub release.
- **Source build** — auto-detects the build system (CMake, Cargo, Go, npm, Python, Gradle, Maven, MSBuild, Meson, Make) and compiles from source.
- **Dependency bootstrapping** — installs missing build tools automatically via Chocolatey, with direct-installer fallback.
- **rpm-ostree-style output** — structured, phase-labelled terminal output with progress bars and spinners.
- **CMD & PowerShell** — works identically from both `cmd.exe` and `powershell.exe`.
- **Package registry** — tracks installed packages in `%PROGRAMDATA%\WinGit\registry.json`.
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
wingit remove  <owner>/<repo>   Remove an installed package
wingit list                     List packages installed by WinGit
wingit --version                Print WinGit version
wingit --help                   Show help
```

### Examples

```powershell
# Install GitHub CLI (release binary)
wingit install cli/cli

# Install Neovim (source build if no Windows binary found)
wingit install neovim/neovim

# Install ripgrep
wingit install BurntSushi/ripgrep

# List installed packages
wingit list

# Remove a package
wingit remove cli/cli
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
├── wingit.cmd          ← Entry point for CMD and PowerShell
├── wingit.ps1          ← Core logic (argument parsing + command dispatch)
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
