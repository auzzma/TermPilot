# Dot-source from release entry points. Values never contain credentials.
if ($IsWindows -and -not $env:CMAKE_TOOLCHAIN_FILE) {
    $env:CMAKE_TOOLCHAIN_FILE = "$PSScriptRoot/windows-cmake-toolchain.cmake"
}
$privacyEnvironment = python "$PSScriptRoot/build-privacy.py" --environment | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Cannot configure anonymous build paths' }
foreach ($property in $privacyEnvironment.PSObject.Properties) {
    [Environment]::SetEnvironmentVariable($property.Name, [string]$property.Value, 'Process')
}
