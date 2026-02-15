# Windows Health Monitor
$ErrorActionPreference = "SilentlyContinue"
$ProgressPreference    = "SilentlyContinue"

# -----------------------------
# Config
# -----------------------------
$NameFilter = "*"   # example: "*chrome*"
$MinCPU     = 0     # seconds
$MinMemory  = 50    # MB

$EventHours        = 24
$EventPenaltyCap   = 35   # max score hit from event logs
$W_Critical        = 10
$W_Error           = 3
$W_Warning         = 1
$WarnSoftThreshold = 50

# -----------------------------
# Functions
# -----------------------------
function Get-GPUStatus {
    $gpu = Get-CimInstance Win32_VideoController | Select-Object -First 1 Name, AdapterRAM
    if (-not $gpu) { return $null }

    $nvsmi = "$env:windir\System32\nvidia-smi.exe"
    if ($gpu.Name -match "NVIDIA" -and (Test-Path $nvsmi)) {
        $raw = & $nvsmi --query-gpu=temperature.gpu,clocks.sm,clocks.mem --format=csv,noheader,nounits 2>$null
        if ($raw) {
            $p = $raw -split ',\s*'
            return [PSCustomObject]@{
                Vendor  = "NVIDIA"
                Name    = $gpu.Name
                Temp_C  = [int]$p[0]
                CoreMHz = [int]$p[1]
                MemMHz  = [int]$p[2]
            }
        }
    }

    [PSCustomObject]@{
        Vendor  = if ($gpu.Name -match "AMD|Radeon") { "AMD" }
                  elseif ($gpu.Name -match "Intel") { "Intel" }
                  else { "Unknown" }
        Name    = $gpu.Name
        Temp_C  = "N/A"
        CoreMHz = "N/A"
        MemMHz  = "N/A"
    }
}

function Get-EventSeverityWeightedPenalty {
    param(
        [int]$Hours,
        [int]$Cap,
        [int]$W_Critical,
        [int]$W_Error,
        [int]$W_Warning,
        [int]$WarnSoftThreshold
    )

    $start = (Get-Date).AddHours(-1 * $Hours)

    $events = foreach ($log in @("System","Application")) {
        Get-WinEvent -FilterHashtable @{ LogName=$log; StartTime=$start; Level=1,2,3 } -ErrorAction SilentlyContinue
    }
    $events = @($events)

    $crit = @($events | Where-Object { $_.Level -eq 1 }).Count
    $err  = @($events | Where-Object { $_.Level -eq 2 }).Count
    $warn = @($events | Where-Object { $_.Level -eq 3 }).Count

    $raw = ($crit * $W_Critical) + ($err * $W_Error) + ($warn * $W_Warning)

    if ($warn -gt $WarnSoftThreshold) {
        $raw += [math]::Ceiling(($warn - $WarnSoftThreshold) / 25)
    }

    $penalty = [math]::Min($raw, $Cap)

    $topProviders = ($events |
        Group-Object ProviderName |
        Sort-Object Count -Descending |
        Select-Object -First 5 |
        ForEach-Object { "$($_.Name)($($_.Count))" }) -join ", "

    $topIds = ($events |
        Group-Object Id |
        Sort-Object Count -Descending |
        Select-Object -First 5 |
        ForEach-Object { "$($_.Name)($($_.Count))" }) -join ", "

    [PSCustomObject]@{
        WindowHours   = $Hours
        CriticalCount = $crit
        ErrorCount    = $err
        WarningCount  = $warn
        RawPenalty    = $raw
        Penalty       = $penalty
        TopProviders  = $topProviders
        TopEventIds   = $topIds
    }
}

# -----------------------------
# Collect data
# -----------------------------
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem

$systemInventory = [PSCustomObject]@{
    ComputerName  = $env:COMPUTERNAME
    Manufacturer  = $cs.Manufacturer
    Model         = $cs.Model
    TotalMemoryGB = [math]::Round(($cs.TotalPhysicalMemory / 1GB), 2)
    OSVersion     = $os.Version
    Architecture  = $os.OSArchitecture
    LastBootTime  = $os.LastBootUpTime
}

$procInfo = Get-Process |
    Where-Object {
        $_.ProcessName -like $NameFilter -and
        $_.CPU -ge $MinCPU -and
        (($_.WorkingSet / 1MB) -ge $MinMemory)
    } |
    Sort-Object WorkingSet -Descending |
    Select-Object -First 10 `
        Id, ProcessName, CPU,
        @{Name="MemoryMB";Expression={[math]::Round($_.WorkingSet/1MB,2)}},
        SI

$diskSpace = Get-PSDrive -PSProvider FileSystem |
    Select-Object Name,
        @{ Name = 'FreeGB';  Expression = { [math]::Round($_.Free / 1GB, 2) } },
        @{ Name = 'TotalGB'; Expression = { [math]::Round(($_.Used + $_.Free) / 1GB, 2) } }

$lowDisk = $diskSpace | Where-Object { $_.FreeGB -lt 10 }

$uptime     = (Get-Date) - $os.LastBootUpTime
$uptimeDays = [math]::Round($uptime.TotalDays, 2)

$failedServices = Get-Service |
    Where-Object { $_.StartType -eq 'Automatic' -and $_.Status -ne 'Running' } |
    Select-Object Name, DisplayName, Status, StartType

$failedCount = @($failedServices).Count

$rebootPending = [bool](Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')

$eventWeighted = Get-EventSeverityWeightedPenalty `
    -Hours $EventHours `
    -Cap $EventPenaltyCap `
    -W_Critical $W_Critical `
    -W_Error $W_Error `
    -W_Warning $W_Warning `
    -WarnSoftThreshold $WarnSoftThreshold

# -----------------------------
# Score (computed once)
# -----------------------------
$score = 100
if ($uptimeDays -gt 7)       { $score -= 10 }
if ($failedCount -gt 0)      { $score -= ($failedCount * 5) }
if ($rebootPending)          { $score -= 15 }
if (@($lowDisk).Count -gt 0) { $score -= 10 }
$score -= $eventWeighted.Penalty
if ($score -lt 0) { $score = 0 }

$healthSummary = [PSCustomObject]@{
    ComputerName        = $env:COMPUTERNAME
    HealthScore         = $score
    Uptime              = $uptime.ToString()
    UptimeDays          = $uptimeDays
    PendingReboot       = $rebootPending
    FailedServices      = $failedCount
    LowDisk             = (@($lowDisk).Count -gt 0)
    LowDiskDrives       = (@($lowDisk).Name -join ', ')
    EventWindowHours    = $eventWeighted.WindowHours
    EventCriticalCount  = $eventWeighted.CriticalCount
    EventErrorCount     = $eventWeighted.ErrorCount
    EventWarningCount   = $eventWeighted.WarningCount
    EventPenaltyApplied = $eventWeighted.Penalty
    TopEventProviders   = $eventWeighted.TopProviders
    TopEventIds         = $eventWeighted.TopEventIds
}

# -----------------------------
# Disk-related events (last 24h)
# -----------------------------
$startTime = (Get-Date).AddHours(-24)

$diskEvents = Get-WinEvent -FilterHashtable @{
    LogName   = 'System'
    StartTime = $startTime
    Level     = 2,3
} |
Where-Object { $_.ProviderName -match 'disk|stor|ntfs|vol|stornvme|partmgr|iastor' } |
Sort-Object TimeCreated -Descending |
Select-Object -First 200 TimeCreated, ProviderName, Id, LevelDisplayName,
    @{Name="Message";Expression={
        if ($_.Message) { $_.Message.Substring(0, [Math]::Min(180, $_.Message.Length)) } else { "" }
    }}

# -----------------------------
# Network test (8.8.8.8)
# -----------------------------
$testConnection = Test-NetConnection -ComputerName 8.8.8.8 -InformationLevel Detailed

$netResult = [PSCustomObject]@{
    Target           = $testConnection.RemoteAddress.IPAddressToString
    Hostname         = if ($testConnection.NameResolutionResults) { $testConnection.NameResolutionResults -join ", " } else { "N/A" }
    Interface        = if ($testConnection.InterfaceAlias) { $testConnection.InterfaceAlias } else { "N/A" }
    SourceIP         = $testConnection.SourceAddress.IPAddressToString
    Gateway          = $testConnection.NetRoute.NextHop.IPAddressToString
    PingStatus       = if ($testConnection.PingSucceeded) { "Success" } else { "Failed" }
    Latency_ms       = $testConnection.PingReplyDetails.RoundTripTime
    TcpTestSucceeded = $testConnection.TcpTestSucceeded
    Port             = if ($testConnection.RemotePort -and $testConnection.RemotePort -ne 0) { $testConnection.RemotePort } else { "N/A" }
}

# -----------------------------
# GPU status
# -----------------------------
$gpuStatus = Get-GPUStatus

# -----------------------------
# Report (avoid table wrapping on wide objects)
# -----------------------------
$healthText = $healthSummary     | Format-List | Out-String
$invText    = $systemInventory   | Format-List | Out-String
$diskText   = $diskSpace         | Format-Table -AutoSize | Out-String
$failText   = if ($failedCount -gt 0) { $failedServices | Format-Table -AutoSize | Out-String } else { "None`n" }
$procText   = $procInfo          | Format-Table -AutoSize | Out-String
$eventsText = if (@($diskEvents).Count -gt 0) { $diskEvents | Format-Table -Wrap -AutoSize | Out-String } else { "No disk-related events found in the last 24 hours.`n" }
$netText    = $netResult         | Format-List | Out-String
$gpuText    = if ($gpuStatus)    { $gpuStatus | Format-List | Out-String } else { "No GPU detected.`n" }

$final = @"
===============================
   WINDOWS HEALTH MONITOR
===============================

=== HEALTH SUMMARY ===
$healthText
=== SYSTEM INVENTORY ===
$invText
=== DISK SPACE ===
$diskText
=== FAILED AUTO SERVICES ===
$failText
=== FILTERED PROCESSES ===
$procText
=== DISK EVENTS (System log, last 24h, Errors/Warnings) ===
$eventsText
=== NETWORK TEST (8.8.8.8) ===
$netText
=== GPU STATUS ===
$gpuText
Done.
"@

Write-Output $final
