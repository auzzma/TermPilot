param(
    [ValidateSet('x64', 'arm64')][string]$Architecture = 'x64',
    [string]$Version,
    [switch]$SkipIntegrationTests
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$originalTargetDirectory = $env:CARGO_TARGET_DIR
Push-Location $root
try {
    if (-not $Version) {
        $Version = python scripts/release.py version
        if ($LASTEXITCODE -ne 0) { throw 'Cannot read release version' }
    }
    if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw 'Version must be major.minor.patch' }
    & "$PSScriptRoot/prepare-windows-runtime.ps1" -Architecture $Architecture
    cargo test --locked --workspace
    if ($LASTEXITCODE -ne 0) { throw 'Shared Rust tests failed' }
    $env:CARGO_TARGET_DIR = "$root/engines/rdp/target"
    cargo test --release --locked --manifest-path engines/rdp/Cargo.toml
    if ($LASTEXITCODE -ne 0) { throw 'Shared RDP tests failed' }
    npm.cmd ci --prefix apps/windows --ignore-scripts --no-audit --no-fund
    if ($LASTEXITCODE -ne 0) { throw 'Windows frontend dependency setup failed' }
    npm.cmd test --prefix apps/windows
    if ($LASTEXITCODE -ne 0) { throw 'Windows frontend tests failed' }
    npm.cmd run build --prefix apps/windows
    if ($LASTEXITCODE -ne 0) { throw 'Windows frontend build failed' }
    $env:CARGO_TARGET_DIR = "$root/target/windows-ui"
    cargo test --locked --manifest-path apps/windows/src-tauri/Cargo.toml --lib
    if ($LASTEXITCODE -ne 0) { throw 'Windows Tauri adapter tests failed' }
    if (-not $SkipIntegrationTests) {
        npm.cmd ci --prefix tests/node --ignore-scripts --no-audit --no-fund
        if ($LASTEXITCODE -ne 0) { throw 'SSH fixture setup failed' }
        $env:TERMPILOT_TEST_ENGINE = "$root/target/release/termpilot-engine.exe"
        node --test tests/node/native-worker.test.cjs
        if ($LASTEXITCODE -ne 0) { throw 'Rust SSH/SFTP integration tests failed' }
    }
    & "$PSScriptRoot/package-windows.ps1" -Architecture $Architecture -Version $Version
} finally {
    $env:CARGO_TARGET_DIR = $originalTargetDirectory
    Pop-Location
}
