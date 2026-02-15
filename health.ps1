$procInfo = Get-Process |
    Sort-Object WorkingSet -Descending |
    Select-Object -First 10 Id, CPU, ProcessName, SI

$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem

$report = [PSCustomObject]@{
    ComputerName   = $env:COMPUTERNAME
    Manufacturer   = $os.Manufacturer
    TotalMemoryGB  = [math]::Round(($cs.TotalPhysicalMemory / 1GB), 2)
    OSVersion      = $os.Version
    Architecture   = $os.OSArchitecture
    LastBootTime   = $os.LastBootUpTime
}

$diskSpace = Get-PSDrive -PSProvider FileSystem |
    Select-Object Name,
        @{Name="Free(GB)";  Expression={[math]::Round($_.Free / 1GB, 2)}},
        @{Name="Total(GB)"; Expression={[math]::Round(($_.Used + $_.Free) / 1GB, 2)}}

$uptime = (Get-Date) - $os.LastBootUpTime
$uptimeDays = [math]::Round($uptime.TotalDays, 2)

"Uptime: $uptime"
"Days: $uptimeDays"

$failedServices = Get-Service |
    Where-Object { $_.Status -ne "Running" -and $_.StartType -eq "Automatic" }
$failedCount = $failedServices.Count

$rebootPending = Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending"

$lowDisk = $diskSpace |
    Where-Object { $_.'Free(GB)' -lt 10 }

$score = 100
if ($uptimeDays -gt 7)   { $score -= 10 }
if ($failedCount -gt 0)  { $score -= ($failedCount * 5) }
if ($rebootPending)      { $score -= 15 }
if ($lowDisk)            { $score -= 10 }
if ($score -lt 0)        { $score = 0 }

$healthReport = [PSCustomObject]@{
    ComputerName    = $env:COMPUTERNAME
    HealthScore     = $score
    FailedServices  = $failedCount
    PendingReboot   = $rebootPending
    LowDisk         = ($lowDisk -ne $null)
    UptimeDays      = $uptimeDays
}

$healthReport | Format-Table -AutoSize


$startTime = (Get-Date).AddHours(-24)

Get-WinEvent -FilterHashtable @{
    LogName = @('System','Application')
    StartTime = $startTime
    Level = 2,3
} -ErrorAction Stop |

Sort-Object TimeCreated -Descending
Select-Object -First 200 TimeCreated, LogName, ProviderName, Id, LevelDisplayname, Message | 
Format-Table -AutoSize -Wrap

