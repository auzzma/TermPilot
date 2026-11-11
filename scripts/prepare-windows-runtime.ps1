param([ValidateSet('x64', 'arm64')][string]$Architecture = 'x64')
# Build the shared Rust library and engine for the native Windows architecture.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot/build-privacy.ps1"
Push-Location $root
try {
    if (-not $IsWindows) { throw 'Build on a Windows runner with PowerShell 7.' }
    $osArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    if ($osArchitecture -ne $Architecture) { throw "Expected a native $Architecture Windows runner, got $osArchitecture" }
    $expectedHost = if ($Architecture -eq 'arm64') { 'aarch64-pc-windows-msvc' } else { 'x86_64-pc-windows-msvc' }
    $rustInfo = rustc -vV
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect Rust toolchain' }
    if ($rustInfo -notcontains "host: $expectedHost") { throw "Select the Rust $expectedHost toolchain before building" }
    if ($env:CARGO_BUILD_TARGET -and $env:CARGO_BUILD_TARGET -ne $expectedHost) { throw 'Cross-compilation is not supported by this native build script' }
    # Keep the output location consistent with both native project bindings.
    Remove-Item Env:CARGO_BUILD_TARGET -ErrorAction SilentlyContinue
    $env:CARGO_TARGET_DIR = "$root/target"
    & "$PSScriptRoot/build-windows-media.ps1" -Architecture $Architecture
    cargo build --release --locked -p termpilot-core -p termpilot-engine
    if ($LASTEXITCODE -ne 0) { throw 'Shared Rust engine build failed' }
} finally { Pop-Location }
