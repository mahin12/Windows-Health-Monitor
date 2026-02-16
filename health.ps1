# Windows Health Monitor 
$ErrorActionPreference = "SilentlyContinue"
$ProgressPreference    = "SilentlyContinue"

# Config

$NameFilter = "*"
$MinCPU     = 0
$MinMemory  = 50

# Scoring caps (max penalty per category)

$CAP = @{
    Events        = 35
    Services      = 20
    Disk          = 25
    Network       = 15
    Uptime        = 10
    PendingReboot = 15
    GPU           = 10
}

# Event weights

$EventHours        = 24
$W_Critical        = 10
$W_Error           = 3
$W_Warning         = 1
$WarnSoftThreshold = 50  
# warnings above this start adding extra penalty

# Disk thresholds
$DiskHardFreeGB    = 10    # <10GB free = extra penalty
$DiskWarnPctFree   = 15    # <15% free starts hurting
$DiskCritPctFree   = 8     # <8% free hurts a lot

# Network thresholds
$LatencyWarnMs     = 50
$LatencyCritMs     = 120

# Uptime thresholds
$UptimeGraceDays   = 7     # no penalty up to 7 days
$UptimeMaxDays     = 30    # max penalty by 30 days


# Helpers

function Clamp([double]$value, [double]$min, [double]$max) {
    if ($value -lt $min) { return $min }
    if ($value -gt $max) { return $max }
    return $value
}

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
        Vendor  = if ($gpu.Name -match "AMD|Radeon") { "AMD" } elseif ($gpu.Name -match "Intel") { "Intel" } else { "Unknown" }
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


# Collect data

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

$uptime     = (Get-Date) - $os.LastBootUpTime
$uptimeDays = [math]::Round($uptime.TotalDays, 2)

$failedServices = Get-Service |
    Where-Object { $_.StartType -eq 'Automatic' -and $_.Status -ne 'Running' } |
    Select-Object Name, DisplayName, Status, StartType
$failedCount = @($failedServices).Count

$rebootPending = [bool](Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')

$eventWeighted = Get-EventSeverityWeightedPenalty `
    -Hours $EventHours `
    -Cap $CAP.Events `
    -W_Critical $W_Critical `
    -W_Error $W_Error `
    -W_Warning $W_Warning `
    -WarnSoftThreshold $WarnSoftThreshold

$testConnection = Test-NetConnection -ComputerName 8.8.8.8 -InformationLevel Detailed

$netResult = [PSCustomObject]@{
    Target      = $testConnection.RemoteAddress.IPAddressToString
    SourceIP    = $testConnection.SourceAddress.IPAddressToString
    Gateway     = $testConnection.NetRoute.NextHop.IPAddressToString
    PingOK      = [bool]$testConnection.PingSucceeded
    Latency_ms  = $testConnection.PingReplyDetails.RoundTripTime
}

$gpuStatus = Get-GPUStatus


# Scoring (extensive)

$pen = [ordered]@{
    PendingReboot = 0
    Uptime        = 0
    Services      = 0
    Disk          = 0
    Events        = 0
    Network       = 0
    GPU           = 0
}

$reasons = New-Object System.Collections.Generic.List[string]

# Pending reboot

if ($rebootPending) {
    $pen.PendingReboot = $CAP.PendingReboot
    $reasons.Add("Pending reboot detected (-$($pen.PendingReboot))")
}

# Uptime (gradual after grace)
if ($uptimeDays -gt $UptimeGraceDays) {
    $t = ($uptimeDays - $UptimeGraceDays) / ([math]::Max(1, ($UptimeMaxDays - $UptimeGraceDays)))
    $pen.Uptime = [math]::Round((Clamp $t 0 1) * $CAP.Uptime, 0)
    if ($pen.Uptime -gt 0) { $reasons.Add("High uptime: $uptimeDays days (-$($pen.Uptime))") }
}

# Services (scaled)
if ($failedCount -gt 0) {
    # 1-2 failed: mild, 3-5 moderate, 6+ heavy; capped
    $raw = 0
    if ($failedCount -le 2) { $raw = 4 * $failedCount }
    elseif ($failedCount -le 5) { $raw = 8 + (3 * ($failedCount - 2)) }
    else { $raw = 17 + (1 * ($failedCount - 5)) }

    $pen.Services = [int](Clamp $raw 0 $CAP.Services)
    $reasons.Add("Automatic services not running: $failedCount (-$($pen.Services))")
}

# Disk (evaluate worst drive)

$worst = $null
foreach ($d in $diskSpace) {
    if ($d.TotalGB -le 0) { continue }
    $pctFree = [math]::Round((($d.FreeGB / $d.TotalGB) * 100), 2)

    $drivePenalty = 0

    # % free penalty curve
    if ($pctFree -lt $DiskCritPctFree) {
        $drivePenalty += 18
    } elseif ($pctFree -lt $DiskWarnPctFree) {
        $drivePenalty += 10
    }

    # absolute free GB penalty
    if ($d.FreeGB -lt $DiskHardFreeGB) {
        $drivePenalty += 10
    }

    if (-not $worst -or $drivePenalty -gt $worst.Penalty) {
        $worst = [PSCustomObject]@{
            Name     = $d.Name
            FreeGB   = $d.FreeGB
            TotalGB  = $d.TotalGB
            PctFree  = $pctFree
            Penalty  = $drivePenalty
        }
    }
}

if ($worst -and $worst.Penalty -gt 0) {
    $pen.Disk = [int](Clamp $worst.Penalty 0 $CAP.Disk)
    $reasons.Add("Low disk on $($worst.Name): $($worst.FreeGB)GB free ($($worst.PctFree)% free) (-$($pen.Disk))")
}

# Events (already capped inside function)

$pen.Events = [int](Clamp $eventWeighted.Penalty 0 $CAP.Events)
if ($pen.Events -gt 0) {
    $reasons.Add("Event severity (last $EventHours h): C$($eventWeighted.CriticalCount)/E$($eventWeighted.ErrorCount)/W$($eventWeighted.WarningCount) (-$($pen.Events))")
}

# Network

if (-not $netResult.PingOK) {
    $pen.Network = $CAP.Network
    $reasons.Add("Network ping to 8.8.8.8 failed (-$($pen.Network))")
} else {
    $lat = [double]$netResult.Latency_ms
    $netPen = 0
    if ($lat -ge $LatencyCritMs) { $netPen = 10 }
    elseif ($lat -ge $LatencyWarnMs) { $netPen = 5 }

    $pen.Network = [int](Clamp $netPen 0 $CAP.Network)
    if ($pen.Network -gt 0) { $reasons.Add("High latency to 8.8.8.8: ${lat}ms (-$($pen.Network))") }
}

# GPU (only score if we have a numeric temp)

if ($gpuStatus -and $gpuStatus.Temp_C -is [int]) {
    $t = [int]$gpuStatus.Temp_C
    $gpuPen = 0
    if ($t -ge 90) { $gpuPen = 10 }
    elseif ($t -ge 80) { $gpuPen = 6 }
    elseif ($t -ge 75) { $gpuPen = 3 }

    $pen.GPU = [int](Clamp $gpuPen 0 $CAP.GPU)
    if ($pen.GPU -gt 0) { $reasons.Add("High GPU temp: ${t}C (-$($pen.GPU))") }
}

# Final score

$totalPenalty = ($pen.Values | Measure-Object -Sum).Sum
$score = [int](Clamp (100 - $totalPenalty) 0 100)


# Disk-related events (last 24h)

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


# Summary objects

$healthSummary = [PSCustomObject]@{
    ComputerName   = $env:COMPUTERNAME
    HealthScore    = $score
    TotalPenalty   = $totalPenalty
    Uptime         = $uptime.ToString()
    UptimeDays     = $uptimeDays
    PendingReboot  = $rebootPending
    FailedServices = $failedCount
    EventsWindowH  = $eventWeighted.WindowHours
    Events_C       = $eventWeighted.CriticalCount
    Events_E       = $eventWeighted.ErrorCount
    Events_W       = $eventWeighted.WarningCount
    EventsPenalty  = $pen.Events
    DiskWorstDrive = if ($worst) { $worst.Name } else { "N/A" }
    DiskPenalty    = $pen.Disk
    NetworkPenalty = $pen.Network
    ServicesPenalty= $pen.Services
    UptimePenalty  = $pen.Uptime
    RebootPenalty  = $pen.PendingReboot
    GPUPenalty     = $pen.GPU
}

$penaltyBreakdown = [PSCustomObject]$pen

$netDetail = [PSCustomObject]@{
    Target     = "8.8.8.8"
    PingStatus = if ($netResult.PingOK) { "Success" } else { "Failed" }
    Latency_ms = $netResult.Latency_ms
    SourceIP   = $netResult.SourceIP
    Gateway    = $netResult.Gateway
}


# Report (print once, readable)

$healthText   = $healthSummary      | Format-List | Out-String
$penText      = $penaltyBreakdown   | Format-List | Out-String
$whyText      = if ($reasons.Count -gt 0) { ($reasons | Select-Object -First 10 | ForEach-Object { " - $_" }) -join "`n" } else { " - No issues detected." }
$invText      = $systemInventory    | Format-List | Out-String
$diskText     = $diskSpace          | Format-Table -AutoSize | Out-String
$failText     = if ($failedCount -gt 0) { $failedServices | Format-Table -AutoSize | Out-String } else { "None`n" }
$procText     = $procInfo           | Format-Table -AutoSize | Out-String
$eventsText   = if (@($diskEvents).Count -gt 0) { $diskEvents | Format-Table -Wrap -AutoSize | Out-String } else { "No disk-related events found in the last 24 hours.`n" }
$netText      = $netDetail          | Format-List | Out-String
$gpuText      = if ($gpuStatus) { $gpuStatus | Format-List | Out-String } else { "No GPU detected.`n" }

$final = @"
===============================
   WINDOWS HEALTH MONITOR
===============================

=== HEALTH SUMMARY ===
$healthText
=== PENALTY BREAKDOWN ===
$penText
=== TOP ISSUES ===
$whyText

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

#Export report (txt and csv for now, will add json later)

$folder = "C:\Reports"

#create folder if not exists
if (-not (Test-Path $folder)) {
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
}

#timestamps
$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"

#filepaths

$txtPath = "$folder\WindowsHealthReport_$timestamp.txt"
$csvPath = "$folder\WindowsHealthReport_$timestamp.csv"

#txt = full report, csv = summary
$final | Out-File -FilePath $txtPath -Encoding utf8 -Force
$healthSummary | Export-Csv -Path $csvPath -NoTypeInformation

Write-Host "Reports generated:"
Write-Host " - $txtPath"
Write-Host " - $csvPath"
