# NetSpeed Troubleshooter 1.1.2 - https://ihavenoram.com - https://github.com/ihavenoram/netspeed-troubleshooter
# MIT licence, (c) 2026 ihavenoram.com. If you publish something built on this, please credit ihavenoram.com.
<#
=========================================================
Script Name: Watch_NetSpeed_Egress
Description: Records the public address this site presents to the internet, so
             a WAN failover can be seen after the fact instead of guessed at.

             WHY: a single diagnostic run cannot tell you which internet
             connection it was measuring. If a site has a backup WAN - 4G, a
             second service, anything - a failover changes the public address,
             the latency and the route all at once, and every machine behind it
             goes slow together. Sampling the address on a schedule turns "the
             internet is sometimes slow" into a timestamped list of exactly
             when the site changed connection.

             ONE-SHOT BY DEFAULT. Each run appends a single line to
             egress-history.csv and exits in a couple of seconds. Schedule it
             every few minutes from an RMM or Task Scheduler - that survives
             reboots and needs nobody logged on, which a long-running process
             does not.

               -Report "true"        read the log back and print the findings
               -Continuous "true"    stay running and sample on an interval
               -IntervalSec "300"    interval for -Continuous (default 300)
               -Install "true"       create a scheduled task that calls this
               -Uninstall "true"     remove that scheduled task

             Report output ends with the standard fenced JSON envelope, so
             NetSpeed_HTML_Report.ps1 renders it like any other report.

Category:    ScriptLibrary
Run Time:    1 minute
Arguments:   [-Report "true"] [-Install "true"] [-IntervalSec "300"]
Run As:      System
=========================================================
#>
# Every parameter is [string]: an RMM passes an EMPTY STRING for anything left
# blank, and an empty string bound to [int] or [switch] throws at parameter
# binding before the script runs.
param(
    [string]$Report,
    [string]$Continuous,
    [string]$IntervalSec,
    [string]$Install,
    [string]$Uninstall,
    [string]$LogPath,
    [string]$LatencyTarget
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

#region NETSPEED_HELPERS --- loads the helpers from beside this script ---
# Dot-source the helpers from beside this script, so keep the toolkit's files
# together in one folder.
$script:NsHelpersPath = Join-Path $PSScriptRoot 'NetSpeed-Troubleshooter.Helpers.ps1'
if (Test-Path -LiteralPath $script:NsHelpersPath) {
    . $script:NsHelpersPath
} else {
    Write-Output '[ERROR] NetSpeed-Troubleshooter.Helpers.ps1 was not found beside this script.'
    Write-Output '[ERROR] Copy the whole NetSpeed-Troubleshooter folder, not just this script, and run it from there.'
    exit 2
}
#endregion NETSPEED_HELPERS

function ConvertTo-NsBool2 {
    param([string]$Value, [bool]$Default = $false)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $Default }
    $v = $Value.Trim().ToLower()
    if ($v -eq 'false' -or $v -eq '0' -or $v -eq 'no' -or $v -eq 'n' -or $v -eq 'off') { return $false }
    return $true
}
function ConvertTo-NsInt2 {
    param([string]$Value, [int]$Default)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $Default }
    $n = 0
    if ([int]::TryParse($Value.Trim(), [ref]$n)) { return $n }
    return $Default
}

$DoReport     = ConvertTo-NsBool2 -Value $Report
$DoContinuous = ConvertTo-NsBool2 -Value $Continuous
$DoInstall    = ConvertTo-NsBool2 -Value $Install
$DoUninstall  = ConvertTo-NsBool2 -Value $Uninstall
$Interval     = ConvertTo-NsInt2  -Value $IntervalSec -Default 300
if ($Interval -lt 30) { $Interval = 30 }
$Target = $LatencyTarget
if ([string]::IsNullOrWhiteSpace($Target)) { $Target = '1.1.1.1' }
$LogFile = $LogPath
if ([string]::IsNullOrWhiteSpace($LogFile)) { $LogFile = Get-NsEgressLogPath }

$TaskName = 'NetSpeed Egress Watch'

# ---------------------------------------------------------------------------
# Scheduled task
# ---------------------------------------------------------------------------
if ($DoUninstall) {
    try {
        $null = & schtasks.exe /Delete /TN $TaskName /F 2>&1
        Write-Output ('[OK] Removed the scheduled task "{0}".' -f $TaskName)
        exit 0
    } catch {
        Write-Output ('[FAIL] Could not remove the task: {0}' -f $_.Exception.Message)
        exit 1
    }
}

if ($DoInstall) {
    # schtasks.exe rather than the ScheduledTasks module: that module is not on
    # Server 2012 R2 with PowerShell 4.0, which is exactly the kind of box this
    # gets pointed at.
    $self = $PSCommandPath
    if ([string]::IsNullOrWhiteSpace($self)) { $self = Join-Path $PSScriptRoot 'Watch-NsEgress.ps1' }
    if (-not (Test-Path -LiteralPath $self)) {
        Write-Output '[FAIL] Cannot work out where this script lives, so the task would point at nothing.'
        exit 1
    }
    # The task runs this file as SYSTEM every few minutes, forever. If a
    # standard user can change the file, its folder, or the helpers it loads,
    # they can make SYSTEM run anything. So refuse unless only SYSTEM and
    # Administrators can write to all of them - which is what C:\Program Files is,
    # and what C:\temp, Downloads and C:\ProgramData are not.
    $mustBeLocked = @((Split-Path -Parent $self), $self)
    if ($script:NsHelpersPath -and (Test-Path -LiteralPath $script:NsHelpersPath)) { $mustBeLocked += $script:NsHelpersPath }
    foreach ($p in $mustBeLocked) {
        $lock = Test-NsAdminOnlyWritable -Path $p
        if (-not $lock.Ok) {
            Write-Output ('[FAIL] Not installing a SYSTEM task for a script that a standard user could change. {0}' -f $lock.Reason)
            Write-Output '[FAIL] As an administrator, copy the NetSpeed-Troubleshooter folder to C:\Program Files\NetSpeedTroubleshooter and run -Install from there. C:\temp, Downloads and C:\ProgramData can be changed by standard users.'
            exit 1
        }
    }
    $minutes = [int][math]::Max(1, [math]::Round($Interval / 60))
    # Full path: never let a powershell.exe sitting somewhere on the search
    # path stand in for the real one.
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action  = ('"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" -LogPath "{2}"' -f $ps, $self, $LogFile)
    $out = & schtasks.exe /Create /TN $TaskName /TR $action /SC MINUTE /MO $minutes /RU SYSTEM /RL HIGHEST /F 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Output ('[FAIL] Could not create the scheduled task: {0}' -f ($out -join ' '))
        exit 1
    }
    Write-Output ('[OK] Scheduled task "{0}" created - runs every {1} minute(s) as SYSTEM.' -f $TaskName, $minutes)
    Write-Output ('[INFO] Log: {0}' -f $LogFile)
    Write-Output ''
    Write-Output 'Leave it running while the fault is happening, then read it back with:'
    Write-Output ('  powershell.exe -NoProfile -File "{0}" -Report "true"' -f $self)
    Write-Output ''
    Write-Output 'Remove it afterwards with -Uninstall "true".'
    exit 0
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
if ($DoReport) {
    $hist = Get-NsEgressHistory -Path $LogFile
    if ($hist.State -ne 'measured') {
        Write-Output ('[INFO] {0}' -f $hist.Reason)
        exit 0
    }
    Write-Output ''
    Write-Output ('  Egress history: {0} samples over {1:N1} hours' -f $hist.Samples, $hist.SpanHours)
    Write-Output ('  {0}  ->  {1}' -f $hist.FirstUtc, $hist.LastUtc)
    Write-Output ''
    foreach ($a in @($hist.Addresses)) {
        $devTxt = ''
        if ($a.egressDevice) { $devTxt = ('   via ' + $a.egressDevice) }
        Write-Output ('    {0,-24} {1,8:N0} min   {2,5} samples   median {3} ms{4}' -f $a.address, $a.minutes, $a.samples, $a.medianLatencyMs, $devTxt)
    }
    Write-Output ''
    if (@($hist.Transitions).Count -eq 0) {
        Write-Output '  [OK] The public address never changed during this window - no failover was seen.'
    } else {
        foreach ($t in @($hist.Transitions)) {
            Write-Output ('  [WARN] {0}   {1} -> {2}   (held the previous one {3:N0} min)' -f $t.atUtc, $t.from, $t.to, $t.heldMinutes)
        }
        Write-Output ''
        if ($hist.Flapping) {
            Write-Output '  [WARN] More than one address and more than one change: this site is FLAPPING between'
            Write-Output '         internet connections. Every machine behind it degrades together whenever it does.'
            Write-Output '         The router or firewall failover log is the authority on why.'
        } else {
            Write-Output '  [NOTE] The address changed once. That can be a failover, or just a DHCP renumber -'
            Write-Output '         compare the median latency of each address to tell them apart.'
        }
    }
    Write-Output ''

    # Emit a normal report envelope so the HTML renderer can read it too.
    $ctx = Get-NsContext
    $sections = [pscustomobject]@{ egress = (New-NsEgressSection -History $hist) }
    $level = 'green'
    if ($hist.Flapping) { $level = 'red' } elseif (@($hist.Transitions).Count -gt 0) { $level = 'amber' }
    $sub = New-NsSubscore -Name 'WAN stability' -Level $level -Summary (
        $(if ($hist.Flapping) { ('the site changed public address {0} times in {1:N1} hours.' -f @($hist.Transitions).Count, $hist.SpanHours) }
          elseif (@($hist.Transitions).Count -gt 0) { 'the public address changed once during the window.' }
          else { ('the public address held steady for {0:N1} hours.' -f $hist.SpanHours) })
    ) -Remedy $(if (@($hist.Transitions).Count -gt 0) { 'Check the router or firewall WAN failover log against these timestamps.' } else { '' })
    $rep = New-NsReport -Context $ctx -Adapter (Get-NsActiveAdapter) -Sections $sections `
             -Verdict (Get-NsHealth -Subscores @($sub)) -StartedUtc (Get-Date) -DurationSec 0 -Mode 'watch'
    $m = Get-NsJsonMarkers
    Write-Host $m.Begin
    Write-Host (ConvertTo-NsJson -Object $rep -Compress)
    Write-Host $m.End
    exit 0
}

# ---------------------------------------------------------------------------
# Sample
# ---------------------------------------------------------------------------
function Write-NsSample {
    param([string]$Path, [string]$Target)
    $snap = Get-NsEgressSnapshot -LatencyTarget $Target
    $null = Add-NsEgressObservation -Snapshot $snap -Path $Path
    $ipTxt = $snap.PublicIp
    if (-not $ipTxt) { $ipTxt = '(none - offline)' }
    $latTxt = 'no reply'
    if ($snap.LatencyMs -ge 0) { $latTxt = ('{0} ms' -f $snap.LatencyMs) }
    $devTxt = $snap.Gateway
    if ($snap.EgressDevice -and $snap.EgressDevice -ne $snap.Gateway) { $devTxt = ('{0} -> {1}' -f $snap.Gateway, $snap.EgressDevice) }
    Write-Output ('[{0}] {1}   latency {2}   via {3}' -f $snap.TimestampUtc, $ipTxt, $latTxt, $devTxt)
    return $snap
}

if ($DoContinuous) {
    Write-Output ('[INFO] Watching the public address every {0}s. Ctrl-C to stop. Log: {1}' -f $Interval, $LogFile)
    $last = ''
    while ($true) {
        $snap = Write-NsSample -Path $LogFile -Target $Target
        if ($last -and $snap.PublicIp -and $snap.PublicIp -ne $last) {
            Write-Output ('[WARN] THE PUBLIC ADDRESS JUST CHANGED: {0} -> {1}. The site has moved to a different internet connection.' -f $last, $snap.PublicIp)
        }
        if ($snap.PublicIp) { $last = $snap.PublicIp }
        Start-Sleep -Seconds $Interval
    }
}

# Default: one sample, append, exit. This is the schedulable form.
$null = Write-NsSample -Path $LogFile -Target $Target
Write-Output ('[OK] Appended to {0}' -f $LogFile)
exit 0
