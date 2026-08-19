<#
.SYNOPSIS
    Install and wire up rtk (Rust Token Killer) for this engine — Windows.

.DESCRIPTION
    Detects the CPU architecture, then runs the install method the official
    rtk-ai/rtk repo documents for it:

      Arch    Method (first that works wins)
      -----   -------------------------------------------------------------
      x64     prebuilt rtk-x86_64-pc-windows-msvc.zip -> cargo install
      ARM64   same x64 zip via Windows x64 emulation -> cargo install
              (upstream publishes no native ARM64 Windows binary)

    Steps:
      1. Installs rtk.exe to ~\.local\bin if not already on PATH.
      2. Adds ~\.local\bin to the user PATH if missing.
      3. Registers the global Claude Code hook non-interactively
         (rtk init -g --auto-patch).
      4. Verifies the install (rtk --version, rtk init --show).

    Safe to re-run: every step is idempotent. rtk itself is optional — this
    repo's project hook ends in `|| exit 0`, so skipping this script only
    costs tokens.

.PARAMETER DryRun
    Print the detected platform and the install plan, change nothing.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\install-rtk.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\install-rtk.ps1 -DryRun
#>
param(
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$RtkRepo  = 'rtk-ai/rtk'
$AssetName = 'x86_64-pc-windows-msvc.zip'
$LocalBin = Join-Path $env:USERPROFILE '.local\bin'

function Write-Log([string]$Message) { Write-Host "[install-rtk] $Message" }

# --- Platform detection -----------------------------------------------------

$arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
Write-Log "Detected platform: OS=Windows, arch=$arch"

switch ($arch) {
    'X64'   { Write-Log "Matching release asset: rtk-$AssetName" }
    'Arm64' { Write-Log "No native ARM64 Windows binary upstream - will use the x64 build via Windows x64 emulation (works on Windows 11 ARM)." }
    default { Write-Log "Unsupported architecture '$arch' for prebuilt binaries - will fall back to cargo." }
}
$useReleaseAsset = $arch -in @('X64', 'Arm64')

# Make ~\.local\bin visible to this session even before the PATH edit lands.
if (($env:Path -split ';') -notcontains $LocalBin) {
    $env:Path = "$LocalBin;$env:Path"
}

# --- Dry run ----------------------------------------------------------------

if ($DryRun) {
    $existing = Get-Command rtk -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Log "DRY RUN: rtk already installed ($(rtk --version) at $($existing.Source)) - would skip install."
    }
    elseif ($useReleaseAsset) {
        Write-Log "DRY RUN: would install latest rtk-$AssetName to $LocalBin, falling back to cargo."
    }
    else {
        Write-Log 'DRY RUN: would install via cargo only.'
    }
    Write-Log "DRY RUN: would then ensure $LocalBin is on the user PATH, run 'rtk init -g --auto-patch', and verify. No changes made."
    exit 0
}

# --- Install methods --------------------------------------------------------

function Install-RtkFromRelease {
    Write-Log 'Fetching latest release metadata...'
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$RtkRepo/releases/latest"
    $asset = $release.assets | Where-Object { $_.name -like "*$AssetName" } | Select-Object -First 1
    if (-not $asset) { throw "No release asset matching *$AssetName found." }

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "rtk-install-$([System.IO.Path]::GetRandomFileName())"
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $zip = Join-Path $tmp 'rtk.zip'
        Write-Log "Downloading $($asset.browser_download_url)..."
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip
        Expand-Archive -Path $zip -DestinationPath $tmp -Force

        $exe = Get-ChildItem -Path $tmp -Recurse -Filter 'rtk.exe' | Select-Object -First 1
        if (-not $exe) { throw 'rtk.exe not found inside the release zip.' }

        New-Item -ItemType Directory -Force -Path $LocalBin | Out-Null
        Copy-Item -Path $exe.FullName -Destination (Join-Path $LocalBin 'rtk.exe') -Force
        Write-Log "Installed rtk.exe to $LocalBin"
    }
    finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
}

function Install-RtkFromCargo {
    if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) { return $false }
    Write-Log 'Installing via cargo (compiles from source, may take a few minutes)...'
    cargo install --git "https://github.com/$RtkRepo"
    return $LASTEXITCODE -eq 0
}

# --- Install ----------------------------------------------------------------

$existing = Get-Command rtk -ErrorAction SilentlyContinue
if ($existing) {
    Write-Log "rtk already installed: $(rtk --version) ($($existing.Source))"
}
else {
    Write-Log 'rtk not found - installing...'
    $installed = $false
    if ($useReleaseAsset) {
        try {
            Install-RtkFromRelease
            $installed = $true
        }
        catch {
            Write-Log "Release download failed: $($_.Exception.Message)"
        }
    }
    if (-not $installed -and -not (Install-RtkFromCargo)) {
        throw 'Install failed. Install Rust (https://rustup.rs) and re-run, or download rtk manually from https://github.com/rtk-ai/rtk/releases.'
    }
    if (-not (Get-Command rtk -ErrorAction SilentlyContinue)) {
        throw "rtk installed but not resolvable on PATH. Add $LocalBin to PATH and re-run."
    }
    Write-Log "Installed: $(rtk --version)"
}

# Persist ~\.local\bin on the user PATH so rtk survives new shells.
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (($userPath -split ';') -notcontains $LocalBin) {
    Write-Log "Adding $LocalBin to user PATH..."
    [Environment]::SetEnvironmentVariable('Path', "$userPath;$LocalBin", 'User')
}

# --- Hook setup + verify ----------------------------------------------------

Write-Log 'Registering global Claude Code hook (rtk init -g --auto-patch)...'
rtk init -g --auto-patch
if ($LASTEXITCODE -ne 0) { throw "rtk init failed with exit code $LASTEXITCODE" }

Write-Log 'Verifying...'
rtk --version
rtk init --show

Write-Log 'Done. Restart Claude Code so the hook loads, then approve this repo''s project-level hook prompt on first run.'
