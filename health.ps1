$procInfo = Get-Process | Sort-Object WorkingSet -Descending | Select-Object -First 10 Id, CPU, ProcessName, SI 

$os = Get-CimInstance Win32_OperatingSystem 
$cs = Get-CimInstance Win32_ComputerSystem 


$report = [PSCustomObject]@{ 
    ComputerName = $env:COMPUTERNAME 
    Manufacturer = $os.Manufacturer 
    # Model = $os.Model TotalMemoryGB = [math]::Round(($cs.TotalPhysicalMemory / 1GB), 2) 
    OSVersion = $os.Version 
    Architecture = $os.OSArchitecture 
    LastBootTime = $os.LastBootUpTime 
} 
    
# $report | Format-Table -AutoSize

# Shows free and total space for all drives
$diskSpace = Get-PSDrive -PSProvider FileSystem | Select-Object Name, @{Name="Free(GB)";Expression={[math]::Round($_.Free/1GB,2)}}, @{Name="Total(GB)";Expression={[math]::Round($_.Used/1GB + $_.Free/1GB,2)}}

# $diskSpace

$uptime = (Get-Date) - $os.LastBootUpTime
$uptimeDays = [math]::Round($uptime.TotalDays, 2)


"Uptime: $uptime"
"Days: $uptimeDays"


