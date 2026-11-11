$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$os = Get-CimInstance Win32_OperatingSystem
$total = [double]$os.TotalVisibleMemorySize * 1024
if ($total -le 0) { throw 'Windows did not return physical memory information.' }
$cpu = @(Get-CimInstance Win32_Processor)
$cores = [int](($cpu | Measure-Object NumberOfLogicalProcessors -Sum).Sum)
$perf = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction SilentlyContinue
$interfaces = @([Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | Where-Object {
    $_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -ne 'Loopback'
} | ForEach-Object {
    try {
        $stats = $_.GetIPStatistics()
        [ordered]@{ id=$_.Id; name=$_.Name; rx=[uint64]$stats.BytesReceived; tx=[uint64]$stats.BytesSent }
    } catch { }
})
$disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Where-Object { $_.Size -gt 0 } | ForEach-Object {
    $used = [double]$_.Size - [double]$_.FreeSpace
    [ordered]@{ mount=$_.DeviceID; used=$used; total=[double]$_.Size; percent=$used * 100 / [double]$_.Size }
})
$pages = @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)
$pageUsed = [double](($pages | Measure-Object CurrentUsage -Sum).Sum)
$pageTotal = [double](($pages | Measure-Object AllocatedBaseSize -Sum).Sum)
$top = @(Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 5 | ForEach-Object {
    [ordered]@{ pid=$_.Id; memoryPercent=[double]$_.WorkingSet64 * 100 / $total; command=$_.ProcessName }
})
$uptime = (Get-Date) - $os.LastBootUpTime
$sample = [ordered]@{
    schema=1; platform='windows'; hostname=$env:COMPUTERNAME; username=[Environment]::UserName
    os=$os.Caption; kernel=$os.Version; uptimeSeconds=[math]::Max(0,[math]::Floor($uptime.TotalSeconds))
    cpuModel=($cpu | Select-Object -First 1).Name; cpuCoreCount=$cores; cpuReady=($null -ne $perf)
    cpuUsage=$(if ($null -ne $perf) { [math]::Max(0,[math]::Min(100,100 - [double]$perf.PercentIdleTime)) } else { 0 })
    cpuUserUsage=$(if ($null -ne $perf) { [double]$perf.PercentUserTime } else { 0 })
    cpuSystemUsage=$(if ($null -ne $perf) { [double]$perf.PercentPrivilegedTime } else { 0 })
    memoryTotal=$total; memoryUsed=[double]($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) * 1024
    disks=$disks; interfaces=$interfaces; pageFileUsedMB=$pageUsed; pageFileTotalMB=$pageTotal
    topMemoryProcesses=$top
    timestampMs=[double][Diagnostics.Stopwatch]::GetTimestamp() * 1000 / [Diagnostics.Stopwatch]::Frequency
}
Write-Output '__TERMPILOT_SYSTEM_JSON__'
$sample | ConvertTo-Json -Depth 6 -Compress
