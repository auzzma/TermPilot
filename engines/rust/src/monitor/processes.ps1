$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$os = Get-CimInstance Win32_OperatingSystem
$total = [double]$os.TotalVisibleMemorySize * 1024
$cores = [math]::Max(1,[Environment]::ProcessorCount)
$perf = @{}
Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -ErrorAction SilentlyContinue | Where-Object { $_.IDProcess -gt 0 } | ForEach-Object { $perf[[string]$_.IDProcess] = $_ }
$owners = @{}
try { Get-Process -IncludeUserName -ErrorAction Stop | ForEach-Object { $owners[[string]$_.Id] = $_.UserName } } catch { }
$now = Get-Date
$rows = @(Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -gt 0 } | ForEach-Object {
    $p = $_
    $counter = $perf[[string]$p.ProcessId]
    $cpu = if ($counter) { [math]::Max(0,[math]::Min(100,[double]$counter.PercentProcessorTime / $cores)) } else { 0 }
    $user = $owners[[string]$p.ProcessId]
    if (-not $user) { $user = '-' }
    $elapsed = if ($p.CreationDate) { ($now - $p.CreationDate).ToString('d\.hh\:mm\:ss') } else { '-' }
    $command = if ($p.CommandLine) { $p.CommandLine } else { $p.Name }
    [ordered]@{
        pid=[int]$p.ProcessId; ppid=[int]$p.ParentProcessId; user=$user; stat='-'
        cpuPercent=$cpu; cpuReady=($null -ne $counter)
        memPercent=$(if ($total -gt 0) { [double]$p.WorkingSetSize * 100 / $total } else { 0 })
        rssKB=[math]::Floor([double]$p.WorkingSetSize / 1024); vszKB=[math]::Floor([double]$p.VirtualSize / 1024)
        elapsed=$elapsed; command=$command
    }
})
Write-Output '__TERMPILOT_SYSTEM_JSON__'
@{schema=1; processes=$rows} | ConvertTo-Json -Depth 5 -Compress
