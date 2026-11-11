param(
    [ValidateSet('x64', 'arm64')][string]$Architecture = 'x64',
    [string]$Version
)
# Run after preparing the matching native Rust core and engine.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot/build-privacy.ps1"
$originalTargetDirectory = $env:CARGO_TARGET_DIR
Push-Location $root
try {
    if (-not $IsWindows) { throw 'Package on Windows with PowerShell 7.' }
    $nativeArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    if ($nativeArch -ne $Architecture) { throw "Expected a native $Architecture Windows runner, got $nativeArch" }
    $projectVersion = python scripts/release.py version
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read consistent application versions' }
    if (-not $Version) { $Version = $projectVersion }
    if ($Version -ne $projectVersion) { throw 'Package version must match the application source version' }
    if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw 'Version must be major.minor.patch' }
    $destination = "$root/dist/windows-$Architecture"
    if ((Test-Path "$destination/AppData") -and @(Get-ChildItem "$destination/AppData" -Force).Count -gt 0) {
        throw 'The previous distribution contains user AppData. Move it to a safe location before rebuilding.'
    }
    if (Test-Path $destination) { Remove-Item -Recurse -Force $destination }
    $payload = "$destination/app"
    $target = if ($Architecture -eq 'arm64') { 'aarch64-pc-windows-msvc' } else { 'x86_64-pc-windows-msvc' }
    npm.cmd run build --prefix apps/windows
    if ($LASTEXITCODE -ne 0) { throw 'Windows frontend build failed' }
    $env:CARGO_TARGET_DIR = "$root/target/windows-ui"
    cargo build --release --locked --manifest-path apps/windows/src-tauri/Cargo.toml
    if ($LASTEXITCODE -ne 0) { throw 'Windows Tauri application build failed' }
    $env:CARGO_TARGET_DIR = "$root/engines/rdp/target"
    cargo build --release --locked --manifest-path engines/rdp/Cargo.toml
    if ($LASTEXITCODE -ne 0) { throw 'RDP engine build failed' }
    New-Item -ItemType Directory -Path "$payload/engine", "$payload/Assets" -Force | Out-Null
    Copy-Item "$root/target/windows-ui/release/TermPilot.exe" "$payload/TermPilot.exe"
    Copy-Item "$root/target/release/termpilot-engine.exe" "$payload/engine/termpilot-engine.exe"
    & "$PSScriptRoot/build-windows-media.ps1" -Architecture $Architecture
    Copy-Item "$root/target/windows-media-$Architecture/runtime/termpilot-media.exe" "$payload/engine/"
    Get-ChildItem "$root/target/windows-media-$Architecture/runtime/*.dll" | Copy-Item -Destination "$payload/engine/"
    Copy-Item "$root/engines/rdp/target/release/termpilot-rdp.exe" "$payload/engine/termpilot-rdp.exe"
    Copy-Item "$root/apps/windows/Assets/TermPilot.ico" "$payload/Assets/TermPilot.ico"
    Copy-Item "$root/apps/windows/public/AutocompleteSpecs.bundledata" "$payload/AutocompleteSpecs.bundledata"
    Copy-Item "$root/NOTICE.md" "$payload/NOTICE.md"
    Copy-Item "$root/LICENSE" "$payload/LICENSE.txt"
    Copy-Item "$root/engines/rust/LICENSE" "$payload/LICENSE-ISHARESCREEN.txt"
    # A small GUI-subsystem launcher with a static CRT needs no adjacent runtime.
    # Compile independently so this flag does not affect the shared engine/DLL.
    $launcherBuild = "$root/target/windows-launcher/$Architecture"
    New-Item -ItemType Directory -Path $launcherBuild -Force | Out-Null
    $kits = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots').KitsRoot10
    $rc = Get-ChildItem "$kits/bin/*/$Architecture/rc.exe" | Sort-Object FullName -Descending | Select-Object -First 1
    if (-not $rc -and $Architecture -eq 'arm64') {
        $rc = Get-ChildItem "$kits/bin/*/x64/rc.exe" | Sort-Object FullName -Descending | Select-Object -First 1
    }
    if (-not $rc) { throw 'Windows SDK resource compiler (rc.exe) was not found' }
    $resources = (Get-Content "$root/apps/windows/launcher/TermPilot.rc" -Raw).
        Replace('VERSION_COMPONENTS', ($Version.Replace('.', ',') + ',0')).
        Replace('VERSION_STRING', ('"' + $Version + '\0"'))
    Set-Content "$launcherBuild/TermPilot.rc" -Value $resources -Encoding utf8
    Copy-Item "$root/apps/windows/Assets/TermPilot.ico" "$launcherBuild/TermPilot.ico" -Force
    Copy-Item "$root/apps/windows/app.manifest" "$launcherBuild/app.manifest" -Force
    & $rc.FullName /nologo /c65001 /i $launcherBuild /fo "$launcherBuild/TermPilot.res" "$launcherBuild/TermPilot.rc"
    if ($LASTEXITCODE -ne 0) { throw 'Windows launcher icon/resource build failed' }
    $privacyRustFlags = $env:CARGO_ENCODED_RUSTFLAGS.Split([char]31)
    rustc @privacyRustFlags --edition=2021 --target $target -C opt-level=s -C lto -C strip=debuginfo -C target-feature=+crt-static -C "link-arg=$launcherBuild/TermPilot.res" apps/windows/launcher/main.rs -o "$launcherBuild/TermPilot.exe"
    if ($LASTEXITCODE -ne 0) { throw 'Windows launcher build failed' }
    # MSVC can emit a PDB even when Rust debuginfo is stripped; keep it in target/.
    Copy-Item "$launcherBuild/TermPilot.exe" "$destination/TermPilot.exe"
    New-Item -ItemType Directory -Path "$destination/AppData" | Out-Null
    & "$root/tests/windows-launcher/test-launcher.ps1" -Launcher "$destination/TermPilot.exe" -Target $target
    python scripts/package-source.py "$payload/CorrespondingSource.tar.gz"
    if ($LASTEXITCODE -ne 0) { throw 'Source packaging failed' }
    python scripts/package-licenses.py "$payload/Licenses"
    if ($LASTEXITCODE -ne 0) { throw 'License packaging failed' }
    python scripts/package-windows-licenses.py "$payload/Licenses"
    if ($LASTEXITCODE -ne 0) { throw 'Windows Tauri license packaging failed' }
    python scripts/release.py audit --platform windows --arch $Architecture --input $destination
    if ($LASTEXITCODE -ne 0) { throw 'Windows distribution audit failed' }
    python scripts/audit-privacy.py $destination
    if ($LASTEXITCODE -ne 0) { throw 'Windows privacy audit failed' }
} finally {
    $env:CARGO_TARGET_DIR = $originalTargetDirectory
    Pop-Location
}
