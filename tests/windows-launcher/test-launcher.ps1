param(
    [Parameter(Mandatory)][string]$Launcher,
    [Parameter(Mandatory)][string]$Target
)
$ErrorActionPreference = 'Stop'
$temporary = Join-Path ([System.IO.Path]::GetTempPath()) ("TermPilot launcher 中文 " + [guid]::NewGuid())
try {
    $payload = New-Item -ItemType Directory -Path "$temporary/app" -Force
    Copy-Item $Launcher "$temporary/TermPilot.exe"
    rustc --edition=2021 --target $Target -C target-feature=+crt-static "$PSScriptRoot/probe.rs" -o "$payload/TermPilot.exe"
    if ($LASTEXITCODE -ne 0) { throw 'Launcher test fixture build failed' }
    $start = [System.Diagnostics.ProcessStartInfo]::new()
    $start.FileName = "$temporary/TermPilot.exe"
    # Launch from an unrelated working directory, with exact Unicode/empty args.
    $start.WorkingDirectory = [System.Environment]::SystemDirectory
    $start.UseShellExecute = $false
    foreach ($argument in @('', 'plain', '中文 空格', 'quote"inside', 'trailing\')) { $start.ArgumentList.Add($argument) }
    $start.Environment['TERMPILOT_LAUNCHER_TEST_RESULT'] = "$temporary/result.txt"
    $process = [System.Diagnostics.Process]::Start($start)
    try {
        if (-not $process.WaitForExit(15000)) { $process.Kill($true); throw 'Launcher test timed out' }
        if ($process.ExitCode -ne 37) { throw "Child exit code was not forwarded: $($process.ExitCode)" }
    } finally { $process.Dispose() }
    if ((Get-Content "$temporary/result.txt" -Raw) -ne 'passed') { throw 'Launcher child did not complete' }
    Write-Host 'Launcher passed: relocated Unicode path, unrelated working directory, argument forwarding, child exit status.'
} finally {
    if (Test-Path $temporary) { Remove-Item -Recurse -Force $temporary }
}
