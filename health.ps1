# Windows Health Monitor 
# -------------------------


$ErrorActionPreference = "SilentlyContinue"

Write-Host "`n==============================="
Write-Host "   WINDOWS HEALTH MONITOR"
Write-Host "===============================`n"
# -----------------------------
# Process Filters (edit values anytime)
# -----------------------------
$NameFilter = "*"        # example: "*chrome*"
$MinCPU     = 0          # seconds of CPU time
$MinMemory  = 50         # MB working set minimum

# -----------------------------
# Filtered process list
# -----------------------------
$procInfo = Get-Process |
    Where-Object {
        $_.ProcessName -like $NameFilter -and
        $_.CPU -ge $MinCPU -and
        (($_.WorkingSet / 1MB) -ge $MinMemory)
    } |
    Sort-Object WorkingSet -Descending |
    Select-Object -First 10 `
        Id,
        ProcessName,
        CPU,
        @{Name="MemoryMB";Expression={[math]::Round($_.WorkingSet/1MB,2)}},
        SI

Write-Host "`n=== FILTERED PROCESSES ==="
$procInfo | Format-Table -AutoSize | Out-Host


# Disk space

$diskSpace = Get-PSDrive -PSProvider FileSystem |
    Select-Object Name,
        @{ Name = 'FreeGB';  Expression = { [math]::Round($_.Free / 1GB, 2) } },
        @{ Name = 'TotalGB'; Expression = { [math]::Round(($_.Used + $_.Free) / 1GB, 2) } }

# Uptime

$uptime = (Get-Date) - $os.LastBootUpTime
$uptimeDays = [math]::Round($uptime.TotalDays, 2)

# Failed auto services
$failedServices = Get-Service |
    Where-Object { $_.StartType -eq 'Automatic' -and $_.Status -ne 'Running' } |
    Select-Object Name, DisplayName, Status, StartType

$failedCount = @($failedServices).Count

# Pending reboot (suppress raw boolean output)
$rebootPending = [bool](Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')

# Low disk flag
$lowDisk = $diskSpace | Where-Object { $_.FreeGB -lt 10 }

# Health score
$score = 100
if ($uptimeDays -gt 7)          { $score -= 10 }
if ($failedCount -gt 0)         { $score -= ($failedCount * 5) }
if ($rebootPending)             { $score -= 15 }
if (@($lowDisk).Count -gt 0)    { $score -= 10 }
if ($score -lt 0)               { $score = 0 }

$healthReport = [PSCustomObject]@{
    ComputerName   = $env:COMPUTERNAME
    HealthScore    = $score
    Uptime         = $uptime.ToString()
    UptimeDays     = $uptimeDays
    PendingReboot  = $rebootPending
    FailedServices = $failedCount
    LowDisk        = (@($lowDisk).Count -gt 0)
    LowDiskDrives  = (@($lowDisk).Name -join ', ')
}

# Event Log: Disk-related (last 24h)

$startTime = (Get-Date).AddHours(-24)

$diskProviderCandidates = @(
    "Microsoft-Windows-Disk",
    "disk",
    "Microsoft-Windows-Storage-ClassPnP",
    "Microsoft-Windows-StorPort",
    "Microsoft-Windows-Ntfs"
)

$diskEvents = foreach ($prov in $diskProviderCandidates) {
    Get-WinEvent -FilterHashtable @{
        LogName      = 'System'
        ProviderName = $prov
        StartTime    = $startTime
        Level        = 2,3   # Error, Warning
    }
}

$diskEvents = @($diskEvents) |
    Sort-Object TimeCreated -Descending |
    Select-Object -First 200 TimeCreated, ProviderName, Id, LevelDisplayName,
        @{Name="Message";Expression={
            if ($_.Message) { $_.Message.Substring(0, [Math]::Min(180, $_.Message.Length)) } else { "" }
        }}

# PRINT EVERYTHING (forced)

Write-Host "=== HEALTH SUMMARY ==="
$healthReport | Format-Table -AutoSize | Out-Host

Write-Host "`n=== SYSTEM INVENTORY ==="
$report | Format-List | Out-Host

Write-Host "`n=== DISK SPACE ==="
$diskSpace | Format-Table -AutoSize | Out-Host

Write-Host "`n=== FAILED AUTO SERVICES ==="
if ($failedCount -gt 0) {
    $failedServices | Format-Table -AutoSize | Out-Host
} else {
    Write-Host "None"
}

Write-Host "`n=== TOP PROCESSES (by WorkingSet) ==="
$procInfo | Format-Table -AutoSize | Out-Host

Write-Host "`n=== DISK EVENTS (System log, last 24h, Errors/Warnings) ==="
if (@($diskEvents).Count -gt 0) {
    $diskEvents | Format-Table -AutoSize | Out-Host
} else {
    Write-Host "No disk-related events found in the last 24 hours."
}

Write-Host "`nDone.`n"

# Test connection to a host (e.g., google.com)

Test-NetConnection -ComputerName 8.8.8.8 -InformationLevel Detailed

