param([ValidateSet('x64','arm64')][string]$Architecture='x64')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$build="$root/target/windows-media-$Architecture"
$cmakeArch=if($Architecture -eq 'arm64'){'ARM64'}else{'x64'}
cmake -S "$root/engines/media-codec" -B $build -A $cmakeArch -DCMAKE_BUILD_TYPE=Release
if($LASTEXITCODE -ne 0){throw 'Windows media codec configuration failed'}
cmake --build $build --config Release --parallel 4
if($LASTEXITCODE -ne 0){throw 'Windows media codec build failed'}
New-Item -ItemType Directory "$root/target/release" -Force | Out-Null
Copy-Item "$build/runtime/termpilot-media.exe" "$root/target/release/"
Get-ChildItem "$build/runtime/*.dll" | Copy-Item -Destination "$root/target/release/"

python "$root/tests/media-codec/test_codec.py" "$build/runtime/termpilot-media.exe"
if($LASTEXITCODE -ne 0){throw "HEVC / AAC native codec smoke test failed"}
python "$root/tests/media-codec/test_avc.py" "$build/runtime/termpilot-media.exe"
if($LASTEXITCODE -ne 0){throw "H.264 native codec smoke test failed"}
