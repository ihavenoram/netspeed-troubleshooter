<#
    Internet / Network Speed Troubleshooter - worker helpers
    --------------------------------------------------------
    Loaded as TEXT by NetSpeed-Troubleshooter-Gui.ps1 (Get-Content -Raw) and
    dot-sourced into BOTH the UI thread and the background runspaces from that
    single definition. The future headless collector (not in this release) dot-sources the same
    file, which is why none of the test logic lives in the GUI script.

    Rules for anything added here:
      * Windows PowerShell 5.1 only. No PS7 syntax (no ternary, no ?., no ??,
        no -Parallel, no -SkipCertificateCheck) and no [System.Buffers.*]
        (BinaryPrimitives does not exist in .NET Framework 4.x).
      * Function definitions ONLY - nothing may execute at load time, because
        this file is dot-sourced onto the UI thread during form construction.
        Build-NetSpeedStager.ps1 asserts this against the AST and fails the
        build if any other top-level statement appears. Constants therefore
        live inside functions (see Get-NsLimits), never in script variables.
      * A runspace does not inherit script variables, so helpers must not
        reference any script-scope state. Pass it in, or return it.
      * Windows PowerShell 4.0 must survive this file. Server 2012 R2 ships
        4.0, and [Type]::new() is 5.0+ - the whole toolkit died there with
        "does not contain a method named 'new'", an error that names neither
        the version nor the construct. Use New-Object.
      * ...but build a generic List with
            [Activator]::CreateInstance([System.Collections.Generic.List[T]])
        and NOT New-Object. New-Object returns the List wrapped in a PSObject,
        and @($wrappedList) then throws "Argument types do not match" on 5.1 -
        so the obvious PS4-safe fix silently breaks every array conversion.
        Activator returns it unwrapped and works on every version. Verified
        both ways; the build gate enforces it.
      * ASCII only. PS 5.1 mis-parses BOM-less UTF-8 the moment a non-ASCII
        character appears, and keeping the source plain sidesteps the whole
        encoding question. The builder enforces this too.
      * Never Test-NetConnection. Measured at ~500x the cost of a raw
        TcpClient in an earlier tool, and it reports PingSucceeded=False
        on paths where the port is demonstrably open.
#>

function Get-NetSpeedVersion { '1.1.0' }

function Get-NsLimits {
    # Safety and refusal constants, in one place, as a function because the
    # helpers file may not execute anything at load time.
    #
    # The throughput caps are deliberately not reachable from the UI. An
    # unbounded speed test on a metered or cellular link is a bill, and a
    # technician under pressure should not be able to raise the ceiling by
    # ticking something.
    @{
        MaxDownBytes      = 2147483648   # 2 GB per run, hard
        MaxUpBytes        = 1073741824   # 1 GB per run, hard
        MaxStreams        = 16
        MaxSecPerDir      = 30
        CooldownSec       = 20           # between full throughput runs
        MinSamples        = 20           # below this a PERCENTILE is withheld
        # A median needs far fewer samples than a 90th percentile. Reusing the
        # p90 threshold for the idle latency baseline made a 4-second idle
        # phase refuse on 19 replies against a minimum of 20, which is the
        # tool being pedantic rather than careful.
        MinLatencySamples = 12
        MinMeasureSec     = 3.0
        EngineCeilingMbps = 900          # single-threaded TLS decrypt ceiling
        WarmupSec         = 2.0
        WindowMs          = 100          # aggregate sample window
        # Cellular light profile - applied by code, not by choice
        WwanSec           = 3
        WwanStreams       = 2
        WwanMaxBytes      = 52428800     # 50 MB
        # ETW
        EtwMaxCaptureSec  = 30
        EtwBufferMb       = 64
        # Soak
        SoakMinMinutes    = 15           # below this, no dropout verdict
        SoakFailDebounce  = 5            # consecutive failures before "outage"
    }
}

# ===========================================================================
#  Result object factories
#
#  Every section of the report shares one envelope, and every row carries a
#  Basis. That column is the honesty stance made visible: a technician can
#  sort by it and see instantly which numbers were measured, which were
#  inferred, and which the tool refused to produce.
#
#  The five states are not interchangeable:
#
#    measured    - numbers we stand behind.
#    failed      - we tried and the attempt errored. Reason carries the error.
#                  Only ever red where the failure IS the fault.
#    skipped     - not requested; the stage never ran.
#    unsupported - the machine cannot do it (no Wi-Fi radio, not elevated,
#                  cmdlet absent, another trace session holding the provider).
#    refused     - we ran it and DELIBERATELY WITHHELD the number, because it
#                  was below the instrument's resolution or known-invalid.
#
#  Only 'measured' and (sometimes) 'failed' may move a verdict. The other
#  three never drag a result down - an untested machine must not read as a
#  broken one.
# ===========================================================================

function New-NsRow {
    param(
        [string]$Group,
        [string]$Check,
        [string]$Result,
        [ValidateSet('measured','inference','DO counter','BITS counter','ETW bytes',
                     'server-reported','vendor tool','not measured','withheld')]
        [string]$Basis = 'measured',
        [ValidateSet('ok','warn','fail','info')][string]$Status = 'info',
        [string]$Detail = ''
    )
    [pscustomobject]@{
        group  = $Group
        check  = $Check
        result = $Result
        basis  = $Basis
        status = $Status
        detail = $Detail
    }
}

function New-NsSection {
    # Reason is REQUIRED whenever State is not 'measured'. A section that says
    # "unsupported" without saying why is worse than no section: the reader
    # cannot tell a limitation from a bug.
    param(
        [ValidateSet('measured','failed','skipped','unsupported','refused')]
        [string]$State,
        [string]$Reason      = '',
        [string]$Method      = '',
        [string]$Proxy       = '',       # what this is a proxy FOR; '' when direct
        [string[]]$Caveats   = @(),
        $Rows                = @(),
        $Data                = $null,
        [datetime]$StartedUtc = [datetime]::MinValue,
        [double]$DurationSec  = 0
    )
    if ($State -ne 'measured' -and [string]::IsNullOrWhiteSpace($Reason)) {
        $Reason = 'No reason recorded - this is a bug in the tool, not a finding about the network.'
    }
    $started = $null
    if ($StartedUtc -ne [datetime]::MinValue) { $started = ConvertTo-NsIso8601 $StartedUtc }

    $proxyVal = $null
    if (-not [string]::IsNullOrWhiteSpace($Proxy)) { $proxyVal = $Proxy }
    $reasonVal = $null
    if (-not [string]::IsNullOrWhiteSpace($Reason)) { $reasonVal = $Reason }

    [pscustomobject]@{
        state       = $State
        reason      = $reasonVal
        startedUtc  = $started
        durationSec = [math]::Round($DurationSec, 2)
        method      = $Method
        proxy       = $proxyVal
        caveats     = [object[]]$Caveats
        rows        = [object[]]$Rows
        data        = $Data
    }
}

function Set-NsSectionTiming {
    # Stamps when a section ran and how long it took.
    #
    # New-NsSection has always ACCEPTED -StartedUtc/-DurationSec, but not one of
    # the nine section builders passes them through - so every section in every
    # report shipped `startedUtc: null, durationSec: 0`, the GUI's included.
    # Rather than thread two more parameters through nine builders, the caller
    # that actually owns the clock stamps the returned object here. One
    # definition, so the GUI and the headless collector cannot disagree.
    param($Section, [datetime]$StartedUtc, [double]$DurationSec)
    if (-not $Section) { return $Section }
    try {
        $Section.startedUtc  = ConvertTo-NsIso8601 $StartedUtc
        $Section.durationSec = [math]::Round($DurationSec, 2)
    } catch { }
    return $Section
}

function New-NsMetric {
    # A MEASURED quantity. Anything merely read from the OS as a fact stays a
    # bare scalar (linkSpeedMbps = 10), so a consumer can always tell the two
    # apart without consulting the schema.
    param(
        [double]$Value,
        [string]$Unit,
        [ValidateSet('measured','refused','unsupported','failed')][string]$State = 'measured',
        [string]$Basis = '',
        [int]$N = 0,
        [int]$Round = 2
    )
    $v = $null
    if ($State -eq 'measured') { $v = [math]::Round($Value, $Round) }
    [pscustomobject]@{
        v     = $v
        unit  = $Unit
        state = $State
        basis = $Basis
        n     = $N
    }
}

function New-NsSubscore {
    param(
        [string]$Name,
        [ValidateSet('green','amber','red','notmeasured')][string]$Level,
        [string]$Summary,
        [string]$Remedy = ''
    )
    [pscustomobject]@{ name = $Name; level = $Level; summary = $Summary; remedy = $Remedy }
}

function Get-NsHealth {
    # Worst of the MEASURED subscores. Never an average, and deliberately no
    # 0-100 number: aggregating one real measurement, two inferences and a
    # threshold comparison into "73" would be false precision.
    #
    # 'notmeasured' is a first-class fourth state. It is always listed - so a
    # healthy machine can be told apart from an untested one - but it never
    # drags the overall down.
    param($Subscores)
    $list = @($Subscores | Where-Object { $_ })
    $out = [pscustomobject]@{
        overall   = 'notmeasured'
        headline  = 'Nothing was measured.'
        subscores = [object[]]$list
        notes     = [object[]]@()
    }
    if ($list.Count -eq 0) { return $out }

    $measured = @($list | Where-Object { $_.level -ne 'notmeasured' })
    if ($measured.Count -eq 0) {
        $out.headline = 'No test produced a usable result. See each section''s reason.'
        return $out
    }

    $rank  = @{ 'green' = 0; 'amber' = 1; 'red' = 2 }
    $worst = $measured[0]
    foreach ($s in $measured) {
        if ($rank[$s.level] -gt $rank[$worst.level]) { $worst = $s }
    }
    $out.overall = $worst.level

    if ($worst.level -eq 'green') {
        $out.headline = 'Nothing measured here explains a slow connection on this PC.'
    } else {
        $out.headline = ('{0}: {1}' -f $worst.name, $worst.summary)
        if ($worst.remedy) { $out.headline = ('{0} {1}' -f $out.headline, $worst.remedy) }
    }

    $notMeasured = @($list | Where-Object { $_.level -eq 'notmeasured' } | ForEach-Object { $_.name })
    if ($notMeasured.Count -gt 0) {
        $out.notes = [object[]]@(('Not measured, and therefore not counted either way: {0}.' -f ($notMeasured -join ', ')))
    }
    return $out
}

function Get-NsKnownLimits {
    # Published false negatives. These ship in the JSON and in the README
    # because a clean report must not be mistaken for a clean network - the
    # first one in this list is the single most common real cause of "the
    # internet is slow" and this tool is structurally blind to it.
    [object[]]@(
        'This tool sees THIS PC only. A hog on another device on the LAN - another workstation syncing, a NAS replicating, a TV streaming - is completely invisible to it. All three levels of hog detection inherit this limit.',
        'Throughput is a single-CDN measurement: the path to one Cloudflare edge, not to any specific SaaS the customer actually uses.',
        'Upload timing is measured request-start to response-received, so it includes one round trip and reads pessimistically on high-latency links.',
        'The ETW capture is a 20-second sample. A bursty process that happens to be idle during it will read zero. "No bytes attributed in the window" is not "no hog".',
        'ETW counts bytes at the TCP/UDP layer, roughly 3-6 percent below the adapter counters, which include headers and retransmissions. The two are not reconciled.',
        'The built-in engine is single-threaded and cannot measure much above 900 Mbps. Past that it reports a floor, not a figure - use the Ookla button.',
        'ICMP latency can be deprioritised or rate-limited by the customer premises equipment, which is exactly why an HTTP probe runs alongside it.',
        'Wi-Fi parsing reads netsh output and assumes English Windows. On a localised machine it reports unsupported rather than guessing.'
    )
}

# ===========================================================================
#  Formatting and small conversions
# ===========================================================================

function ConvertTo-NsIso8601 {
    # ConvertTo-Json renders [datetime] as /Date(1785985400391)/, which nothing
    # downstream wants. Every timestamp is pre-formatted as a string.
    param([datetime]$When)
    if ($When -eq [datetime]::MinValue) { return $null }
    return $When.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Format-NsMbps {
    param([double]$Mbps)
    if ($Mbps -ge 100) { return ('{0:N0} Mbps' -f $Mbps) }
    if ($Mbps -ge 10)  { return ('{0:N1} Mbps' -f $Mbps) }
    return ('{0:N2} Mbps' -f $Mbps)
}

function Format-NsBytes {
    param([double]$Bytes)
    if ($Bytes -ge 1073741824) { return ('{0:N2} GB' -f ($Bytes / 1073741824)) }
    if ($Bytes -ge 1048576)    { return ('{0:N1} MB' -f ($Bytes / 1048576)) }
    if ($Bytes -ge 1024)       { return ('{0:N1} KB' -f ($Bytes / 1024)) }
    return ('{0:N0} B' -f $Bytes)
}

function Format-NsIncrease {
    # A null increase means that phase produced no probes, which must read as
    # "not measured" rather than an empty gap in the sentence.
    param($Ms)
    if ($null -eq $Ms) { return 'not measured' }
    return ('+{0} ms' -f $Ms)
}

function Format-NsMs {
    param([double]$Ms)
    if ($Ms -ge 100) { return ('{0:N0} ms' -f $Ms) }
    return ('{0:N1} ms' -f $Ms)
}

# ===========================================================================
#  Statistics - ported verbatim from 3CX-Checker.Helpers.ps1
# ===========================================================================

function Get-Percentile {
    # Linear-interpolated percentile. $Sorted must already be ascending.
    param([double[]]$Sorted,[double]$Q)
    $n = @($Sorted).Count
    if ($n -eq 0) { return 0.0 }
    if ($n -eq 1) { return [double]$Sorted[0] }
    $r  = ($n - 1) * $Q
    $lo = [int][math]::Floor($r)
    $hi = [int][math]::Ceiling($r)
    if ($lo -eq $hi) { return [double]$Sorted[$lo] }
    return [double]($Sorted[$lo] + ($Sorted[$hi] - $Sorted[$lo]) * ($r - $lo))
}

function Get-StdDev {
    param([double[]]$Values)
    $v = @($Values)
    if ($v.Count -lt 2) { return 0.0 }
    $mean = ($v | Measure-Object -Average).Average
    $ss = 0.0
    foreach ($x in $v) { $ss += ($x - $mean) * ($x - $mean) }
    return [math]::Sqrt($ss / ($v.Count - 1))
}

function Get-NsStats {
    # One pass over a sample set, returning everything the report needs.
    #
    # p90 is the headline throughput figure rather than max, mean or last:
    #   max  is a noise detector - a single window aligned with a buffer drain
    #        reads far above anything the link ever sustained.
    #   last is whatever the link happened to be doing at an arbitrary instant.
    #   mean is dragged down by slow start and by any stream that finished and
    #        re-ramped.
    #   p90  is what the link does when it is actually going, and still needs
    #        10 percent of windows to have reached it, so one outlier cannot
    #        set it. It is also what Cloudflare's own web tester reports, which
    #        matters when the customer has already run that in their browser.
    #
    # p50 and the spread are returned alongside and must be REPORTED alongside.
    # A link reading p90 94 / p50 31 is not a 94 Mbps link, and that gap is
    # itself the finding.
    param([double[]]$Values)
    $v = @($Values | Where-Object { $_ -ne $null })
    $out = [pscustomobject]@{
        N = 0; Min = 0.0; Max = 0.0; Mean = 0.0
        P50 = 0.0; P90 = 0.0; P95 = 0.0; Spread = 0.0; StdDev = 0.0
    }
    if ($v.Count -eq 0) { return $out }
    $sorted = [double[]]($v | Sort-Object)
    $out.N      = $sorted.Count
    $out.Min    = [double]$sorted[0]
    $out.Max    = [double]$sorted[$sorted.Count - 1]
    $out.Mean   = [double](($sorted | Measure-Object -Average).Average)
    $out.P50    = Get-Percentile -Sorted $sorted -Q 0.50
    $out.P90    = Get-Percentile -Sorted $sorted -Q 0.90
    $out.P95    = Get-Percentile -Sorted $sorted -Q 0.95
    $out.Spread = $out.P90 - $out.P50
    $out.StdDev = Get-StdDev -Values $sorted
    return $out
}

function Get-NsJitter {
    # Mean absolute difference between consecutive samples. This is the figure
    # speed tests and Zoom-readiness tools display, so it is what a technician
    # will be comparing against.
    #
    # Only CONSECUTIVE successful probes are paired. Spanning a lost probe
    # would fold a loss artefact into the jitter number.
    param([double[]]$Values)
    $v = @($Values)
    if ($v.Count -lt 2) { return 0.0 }
    $sum = 0.0
    for ($i = 1; $i -lt $v.Count; $i++) { $sum += [math]::Abs($v[$i] - $v[$i - 1]) }
    return $sum / ($v.Count - 1)
}

function Measure-CounterDelta {
    # Delta between two readings of a network byte counter, correcting for
    # 32-bit wrap.
    #
    # NetworkInterface.GetIPv4Statistics() returns Int64 but the underlying
    # MIB counter is 32-bit on many drivers. On the machine this was written
    # on, BytesReceived read 4,083,882,019 - about to wrap. Without the
    # correction the next sample reads as a large negative number and, if
    # naively clamped to zero, silently loses a second of traffic.
    #
    # The correction is provably right below 34 Gbps: a wrap can only be
    # MISSED if more than 4.29 GB moved within one sample interval.
    #
    # LinkSpeedMbps, when known, is a second gate. If the corrected delta
    # still implies more than 1.5x line rate the counter was reset (adapter
    # reconnect, driver restart) rather than wrapped, and the sample is
    # discarded - publishing a 900 Gbps spike would discredit the whole tab.
    param(
        [double]$Previous,
        [double]$Current,
        [double]$IntervalSec  = 1.0,
        [double]$LinkSpeedMbps = 0
    )
    $out = [pscustomobject]@{ Bytes = 0.0; Valid = $true; Wrapped = $false; Note = '' }
    $delta = $Current - $Previous
    if ($delta -lt 0) {
        $delta += 4294967296.0
        $out.Wrapped = $true
        $out.Note = '32-bit counter wrap corrected'
    }
    if ($LinkSpeedMbps -gt 0 -and $IntervalSec -gt 0) {
        $maxBytes = ($LinkSpeedMbps * 1000000.0 / 8.0) * $IntervalSec * 1.5
        if ($delta -gt $maxBytes) {
            $out.Valid = $false
            $out.Bytes = 0.0
            $out.Note  = 'sample discarded: implies more than 1.5x line rate, so the counter was reset rather than wrapped'
            return $out
        }
    }
    $out.Bytes = $delta
    return $out
}

# ===========================================================================
#  Timing and waiting - ported from 3CX-Checker.Helpers.ps1
# ===========================================================================

function Enter-HighResTimer {
    # Windows' default timer resolution is ~15.6 ms. timeBeginPeriod(1) brings
    # that to ~1.4 ms, which is what lets the probe pacer wait rather than spin.
    # Process-scoped; Exit-HighResTimer gives it back.
    #
    # Returns $true if the resolution was raised. Callers must degrade
    # gracefully when it was not.
    if (-not ('NetSpeed.NativeTimer' -as [type])) {
        try {
            Add-Type -Namespace 'NetSpeed' -Name 'NativeTimer' -ErrorAction Stop -MemberDefinition @'
[DllImport("winmm.dll", EntryPoint="timeBeginPeriod")] public static extern uint Begin(uint period);
[DllImport("winmm.dll", EntryPoint="timeEndPeriod")]   public static extern uint End(uint period);
'@
        } catch { return $false }
    }
    try { return ([NetSpeed.NativeTimer]::Begin(1) -eq 0) } catch { return $false }
}

function Exit-HighResTimer {
    param([bool]$WasRaised)
    if (-not $WasRaised) { return }
    try { [void][NetSpeed.NativeTimer]::End(1) } catch {}
}

function Wait-Cancellable {
    # Idle wait that stays responsive: checks for cancellation and pushes a
    # countdown so a multi-minute stage does not look like a hang.
    param([int]$Seconds,$Shared = $null,[string]$Message = 'Waiting')
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
        if ($Shared -and $Shared.Cancel) { $sw.Stop(); return $false }
        if ($Shared) {
            $left = [int][math]::Ceiling($Seconds - $sw.Elapsed.TotalSeconds)
            $Shared.Status = ('{0} - {1}s remaining...' -f $Message, $left)
        }
        Start-Sleep -Milliseconds 250
    }
    $sw.Stop()
    return $true
}

# ===========================================================================
#  Machine and network context
# ===========================================================================

function Test-NsElevated {
    # SYSTEM is in the Administrators role, so a Backstage session passes this.
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object Security.Principal.WindowsPrincipal($id)
        return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Get-NsPlatformNotes {
    # What this machine cannot do, found BEFORE anything tries it.
    #
    # This exists because of a real field failure: on Server 2012 R2 the whole
    # tool died with "does not contain a method named 'new'". Server 2012 R2
    # ships PowerShell 4.0, and the [Type]::new() constructor syntax is 5.0+.
    # Every such call is now New-Object instead - but the lesson is that the
    # tool should SAY what it cannot do on a given host rather than let a
    # technician discover it through a .NET error with no useful text in it.
    param()
    $notes = [Activator]::CreateInstance([System.Collections.Generic.List[string]])
    $major = 0
    try { $major = [int]$PSVersionTable.PSVersion.Major } catch { }

    if ($major -lt 3) {
        $notes.Add(('PowerShell {0} is too old for this tool - it needs 3.0 or later. Install WMF 5.1 on this machine.' -f $PSVersionTable.PSVersion))
    } elseif ($major -lt 5) {
        $notes.Add(('This machine runs PowerShell {0}. Everything here works, but WMF 5.1 is worth installing on any box you troubleshoot regularly.' -f $PSVersionTable.PSVersion))
    }
    if (-not (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue)) {
        $notes.Add('Get-NetAdapter is missing, so adapter facts cannot be read. That cmdlet arrived with Windows 8 / Server 2012 - on anything older this tool cannot identify the link.')
    }
    if (-not (Get-Command Get-DeliveryOptimizationStatus -ErrorAction SilentlyContinue)) {
        $notes.Add('Delivery Optimization is not present on this build of Windows (it arrived with Windows 10 / Server 2016), so Windows Update bandwidth cannot be measured here. BITS is still checked.')
    }
    if (-not (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue)) {
        $notes.Add('Resolve-DnsName is missing, so per-resolver DNS timing cannot be measured.')
    }
    if (-not (Get-Command Expand-Archive -ErrorAction SilentlyContinue)) {   # ps5-ok: probed, not assumed
        $notes.Add('Expand-Archive is missing (PowerShell 5.0+), so the Ookla download falls back to the .NET zip classes.')
    }
    return [object[]]$notes
}

function Get-NsContext {
    param()
    $ctx = [pscustomobject]@{
        computerName     = $env:COMPUTERNAME
        domain           = ''
        osCaption        = ''
        osBuild          = ''
        psVersion        = $PSVersionTable.PSVersion.ToString()
        runAs            = ''
        isSystem         = $false
        elevated         = (Test-NsElevated)
        pid              = $PID
        interactiveUsers = [object[]]@()
    }
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $ctx.runAs = $id.Name
        $ctx.isSystem = ($id.User.Value -eq 'S-1-5-18')
    } catch {}
    try {
        $os = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 15 -ErrorAction Stop
        $ctx.osCaption = $os.Caption
        $ctx.osBuild   = $os.BuildNumber
    } catch {}
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 15 -ErrorAction Stop
        $ctx.domain = $cs.Domain
        if ($cs.UserName) { $ctx.interactiveUsers = [object[]]@($cs.UserName) }
    } catch {}
    return $ctx
}

function Get-NsDefaultRoutes {
    # Every 0.0.0.0/0 route, best first.
    #
    # "The active adapter" is not "the first Up adapter". The machine this was
    # developed on has seven adapters and TWO default routes (a real NIC at
    # metric 0 and ZeroTier at 9999); a tool that picks the wrong one measures
    # the wrong link and reports a confident, useless answer.
    #
    # Windows chooses by RouteMetric + the interface metric, so both are summed
    # here rather than sorting on RouteMetric alone.
    param()
    $out = [Activator]::CreateInstance([System.Collections.Generic.List[object]])
    try {
        $routes = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop
    } catch { return @() }

    foreach ($r in $routes) {
        $ifMetric = 0
        $alias    = ''
        try {
            $ifx = Get-NetIPInterface -InterfaceIndex $r.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop | Select-Object -First 1
            if ($ifx) { $ifMetric = [int]$ifx.InterfaceMetric }
        } catch {}
        try { $alias = $r.InterfaceAlias } catch {}
        $out.Add([pscustomobject]@{
            InterfaceIndex  = [int]$r.InterfaceIndex
            InterfaceAlias  = $alias
            NextHop         = [string]$r.NextHop
            RouteMetric     = [int]$r.RouteMetric
            InterfaceMetric = $ifMetric
            TotalMetric     = ([int]$r.RouteMetric + $ifMetric)
        })
    }
    return @($out | Sort-Object TotalMetric, RouteMetric)
}

function Get-NsAdapterInfo {
    # Physical and configuration facts for one adapter. Everything here is a
    # FACT read from the OS, not a measurement, so the caller emits these as
    # bare scalars in the JSON.
    param([int]$InterfaceIndex)
    $out = [pscustomobject]@{
        interfaceIndex       = $InterfaceIndex
        interfaceGuid        = ''
        name                 = ''
        interfaceDescription = ''
        macAddress           = ''
        status               = ''
        linkSpeedMbps        = 0
        linkSpeedText        = ''
        fullDuplex           = $null
        mediaType            = ''
        physicalMediaType    = ''
        interfaceType        = 0
        isWireless           = $false
        isVirtual            = $false
        mtuBytes             = 0
        ipv4                 = ''
        ipv4PrefixLength     = 0
        dhcpEnabled          = $null
        gateway              = ''
        dnsServers           = [object[]]@()
        driverDate           = ''
        driverVersion        = ''
        driverProvider       = ''
        powerSaving          = ''
    }
    $a = $null
    try { $a = Get-NetAdapter -InterfaceIndex $InterfaceIndex -ErrorAction Stop | Select-Object -First 1 } catch {}
    if ($a) {
        $out.name                 = [string]$a.Name
        $out.interfaceDescription = [string]$a.InterfaceDescription
        $out.macAddress           = [string]$a.MacAddress
        try { $out.interfaceGuid  = [string]$a.InterfaceGuid } catch {}
        $out.status               = [string]$a.Status
        $out.linkSpeedText        = [string]$a.LinkSpeed
        $out.mediaType            = [string]$a.MediaType
        $out.physicalMediaType    = [string]$a.PhysicalMediaType
        # IANA ifType - the only unambiguous cellular signal Windows gives.
        try { if ($null -ne $a.InterfaceType) { $out.interfaceType = [int]$a.InterfaceType } } catch { }
        try { if ($null -ne $a.FullDuplex) { $out.fullDuplex = [bool]$a.FullDuplex } } catch {}
        try { $out.isVirtual = [bool]$a.Virtual } catch {}
        try {
            if ($a.Speed -gt 0) { $out.linkSpeedMbps = [int]([double]$a.Speed / 1000000.0) }
        } catch {}
        if ($out.linkSpeedMbps -le 0 -and $out.linkSpeedText) {
            # LinkSpeed is a display string ("1 Gbps", "100 Mbps"). Only used
            # when the numeric Speed property is missing.
            $m = [regex]::Match($out.linkSpeedText, '^\s*([\d\.]+)\s*(G|M|K)?bps', 'IgnoreCase')
            if ($m.Success) {
                $n = [double]$m.Groups[1].Value
                switch ($m.Groups[2].Value.ToUpper()) {
                    'G'     { $out.linkSpeedMbps = [int]($n * 1000) }
                    'M'     { $out.linkSpeedMbps = [int]$n }
                    'K'     { $out.linkSpeedMbps = [int]($n / 1000) }
                    default { $out.linkSpeedMbps = [int]($n / 1000000) }
                }
            }
        }
        $out.isWireless = (($out.physicalMediaType -match '802\.11') -or ($out.mediaType -match '802\.11'))
        $out.driverDate     = ''
        try { if ($a.DriverDate)    { $out.driverDate = ([datetime]$a.DriverDate).ToString('yyyy-MM-dd') } } catch {}
        try { $out.driverVersion  = [string]$a.DriverVersion } catch {}
        try { $out.driverProvider = [string]$a.DriverProvider } catch {}
    }

    try {
        $ifx = Get-NetIPInterface -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop | Select-Object -First 1
        if ($ifx) {
            $out.mtuBytes = [int]$ifx.NlMtu
            $out.dhcpEnabled = ($ifx.Dhcp -eq 'Enabled')
        }
    } catch {}
    try {
        $ip = Get-NetIPAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop |
              Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1
        if ($ip) {
            $out.ipv4 = [string]$ip.IPAddress
            $out.ipv4PrefixLength = [int]$ip.PrefixLength
        }
    } catch {}
    try {
        $dns = Get-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop | Select-Object -First 1
        if ($dns -and $dns.ServerAddresses) { $out.dnsServers = [object[]]@($dns.ServerAddresses) }
    } catch {}
    return $out
}

function Get-NsActiveAdapter {
    # The adapter that traffic to the internet actually leaves by.
    #
    # Chosen from the best default route rather than from "first adapter that
    # is Up", because on a machine with VPN, hypervisor and TAP adapters those
    # are not the same thing and the difference is a wrong answer.
    param([int]$PreferInterfaceIndex = 0)

    if ($PreferInterfaceIndex -gt 0) {
        $info = Get-NsAdapterInfo -InterfaceIndex $PreferInterfaceIndex
        if ($info.name) {
            $routes = @(Get-NsDefaultRoutes | Where-Object { $_.InterfaceIndex -eq $PreferInterfaceIndex })
            if ($routes.Count -gt 0) { $info.gateway = $routes[0].NextHop }
            return $info
        }
    }

    $best = @(Get-NsDefaultRoutes) | Select-Object -First 1
    if (-not $best) {
        # No default route at all. Fall back to any Up, non-virtual adapter
        # holding a real IPv4 address, and let the caller notice the gateway
        # is empty.
        try {
            $a = Get-NetAdapter -ErrorAction Stop |
                 Where-Object { $_.Status -eq 'Up' -and -not $_.Virtual } |
                 Sort-Object -Property InterfaceIndex | Select-Object -First 1
            if ($a) { return Get-NsAdapterInfo -InterfaceIndex ([int]$a.InterfaceIndex) }
        } catch {}
        return Get-NsAdapterInfo -InterfaceIndex 0
    }
    $info = Get-NsAdapterInfo -InterfaceIndex $best.InterfaceIndex
    $info.gateway = $best.NextHop
    return $info
}

function Get-NsCandidateAdapters {
    # Everything the technician might legitimately want to test over, for the
    # adapter combo. Virtual adapters are listed but flagged, because on a
    # machine with ZeroTier or a hypervisor bridge they are a plausible
    # (and occasionally correct) choice.
    param()
    $out = [Activator]::CreateInstance([System.Collections.Generic.List[object]])
    try {
        $adapters = Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' }
    } catch { return @() }
    $defaults = @{}
    foreach ($r in @(Get-NsDefaultRoutes)) {
        if (-not $defaults.ContainsKey($r.InterfaceIndex)) { $defaults[$r.InterfaceIndex] = $r }
    }
    foreach ($a in $adapters) {
        $idx = [int]$a.InterfaceIndex
        $isDefault = $defaults.ContainsKey($idx)
        $out.Add([pscustomobject]@{
            InterfaceIndex = $idx
            Name           = [string]$a.Name
            Description    = [string]$a.InterfaceDescription
            LinkSpeed      = [string]$a.LinkSpeed
            HasDefaultRoute = $isDefault
            Virtual        = [bool]$a.Virtual
        })
    }
    return @($out | Sort-Object -Property @{ E = { -not $_.HasDefaultRoute } }, @{ E = { $_.Virtual } }, Name)
}

function Get-NsWwanDetection {
    # Cellular detection. Drives a code-enforced light test profile - not a
    # checkbox, because the person who most needs the guard rail is the one
    # least likely to tick it. Which is exactly why a FALSE positive here is
    # expensive: it silently shortens the run and every figure comes from a
    # 3-second test the technician did not ask for.
    #
    # This used to regex the adapter DESCRIPTION for 'WWAN|Mobile Broadband|
    # Cellular|LTE|5G Modem'. PowerShell's -match is case-insensitive and
    # unanchored, so "LTE" matched "Rea<LTE>k" - every Realtek adapter ever
    # made, wired ones included. Realtek is one of the most common NICs in
    # existence, so a large share of machines were quietly being measured on
    # the cellular profile.
    #
    # Structured fields first, therefore. Windows already knows what kind of
    # link this is; there is no need to guess from a marketing string.
    param($AdapterInfo)
    $out = [pscustomobject]@{ IsWwan = $false; Basis = '' }
    if (-not $AdapterInfo) { return $out }

    # IANA ifType: 243 = wwanPP, 244 = wwanPP2. Unambiguous when present.
    $it = 0
    try { $it = [int]$AdapterInfo.interfaceType } catch { }
    if ($it -eq 243 -or $it -eq 244) {
        $out.IsWwan = $true
        $out.Basis = ('Windows reports this interface as type {0} (mobile broadband).' -f $it)
        return $out
    }

    # Get-NetAdapter's PhysicalMediaType / MediaType are a closed vocabulary,
    # so these are compared WHOLE rather than searched.
    $pm = ([string]$AdapterInfo.physicalMediaType).Trim()
    $mt = ([string]$AdapterInfo.mediaType).Trim()
    foreach ($v in @($pm, $mt)) {
        if ($v -and ($v -eq 'Wireless WAN' -or $v -eq 'WirelessWan' -or $v -eq 'Native WWAN')) {
            $out.IsWwan = $true
            $out.Basis = ('The adapter reports its physical media as "{0}".' -f $v)
            return $out
        }
    }

    # Last resort, and only on whole words. \b stops the Realtek class of
    # false positive dead: 'Rea<lte>k' has no word boundary around 'lte'.
    $desc = [string]$AdapterInfo.interfaceDescription
    if ($desc -match '(?i)\b(WWAN|Cellular|LTE|NR5G)\b' -or $desc -match '(?i)\bMobile Broadband\b' -or $desc -match '(?i)\b5G Modem\b') {
        $out.IsWwan = $true
        $out.Basis = ('The adapter is named "{0}", which identifies it as mobile broadband.' -f $desc)
        return $out
    }
    return $out
}

function Test-NsWwanAdapter {
    param($AdapterInfo)
    return [bool](Get-NsWwanDetection -AdapterInfo $AdapterInfo).IsWwan
}

function Get-NsNicPowerSaving {
    # Driver power-management flags, from the class registry key.
    #
    # NOT Win32_PnPSignedDriver: that takes 10-30 seconds on a normal machine
    # because it enumerates and verifies every signed driver on the system.
    # The class key is instant and carries the same DriverDate/DriverVersion
    # plus PnPCapabilities, which is the flag that actually matters here -
    # "allow the computer to turn off this device to save power" is a common
    # cause of intermittent stalls on wired links.
    param([string]$MacAddress = '', [string]$InterfaceDescription = '', [string]$InterfaceGuid = '')
    $out = [pscustomobject]@{
        Ok = $false; PnPCapabilities = $null; PowerSavingEnabled = $null
        DriverDate = ''; DriverVersion = ''; DriverProvider = ''; Detail = ''
    }
    $root = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'
    # SilentlyContinue, NOT Stop. This key contains a "Properties" subkey that
    # a non-elevated session cannot open, and -ErrorAction Stop makes that one
    # unreadable child abort the whole enumeration - so the function reported
    # "class key not readable" on a machine where every numbered subkey it
    # actually wanted was readable.
    $keys = @(Get-ChildItem -Path $root -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' })
    if ($keys.Count -eq 0) {
        $out.Detail = 'No readable network adapter class registry keys.'
        return $out
    }
    $normMac  = ($MacAddress -replace '[^0-9A-Fa-f]', '').ToUpper()
    $normGuid = ([string]$InterfaceGuid).Trim().ToUpper()
    foreach ($k in $keys) {
        $p = $null
        try { $p = Get-ItemProperty -Path $k.PSPath -ErrorAction Stop } catch { continue }
        $match = $false
        # NetCfgInstanceId is the interface GUID and is the only field here
        # that is both always present and genuinely unique. MAC is only set
        # when it has been administratively overridden, and DriverDesc repeats
        # across identical NICs in the same machine.
        if ($normGuid -and $p.NetCfgInstanceId) {
            if (([string]$p.NetCfgInstanceId).Trim().ToUpper() -eq $normGuid) { $match = $true }
        }
        if (-not $match -and $normMac) {
            $net = ($p.NetworkAddress -replace '[^0-9A-Fa-f]', '').ToUpper()
            if ($net -and $net -eq $normMac) { $match = $true }
        }
        if (-not $match -and $InterfaceDescription -and $p.DriverDesc) {
            if ([string]$p.DriverDesc -eq $InterfaceDescription) { $match = $true }
        }
        if (-not $match) { continue }

        $out.Ok = $true
        try { $out.DriverDate    = [string]$p.DriverDate } catch {}
        try { $out.DriverVersion = [string]$p.DriverVersion } catch {}
        try { $out.DriverProvider= [string]$p.ProviderName } catch {}
        if ($null -ne $p.PnPCapabilities) {
            $cap = [int]$p.PnPCapabilities
            $out.PnPCapabilities = $cap
            # Bit 0x18 set means "do not allow the computer to turn this device
            # off". Absent or zero means power management is permitted.
            $out.PowerSavingEnabled = (($cap -band 0x18) -ne 0x18)
        } else {
            $out.PnPCapabilities = 0
            $out.PowerSavingEnabled = $true
            $out.Detail = 'PnPCapabilities is not set, which leaves the default in force: the computer is allowed to power the adapter down.'
        }
        break
    }
    if (-not $out.Ok) { $out.Detail = 'No registry entry matched this adapter.' }
    return $out
}

# ===========================================================================
#  Raw socket probes - ported from 3CX-Checker.Helpers.ps1
# ===========================================================================

function Test-TcpPort {
    param([string]$ComputerName,[int]$Port,[int]$TimeoutMs = 1500)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $client = New-Object System.Net.Sockets.TcpClient
    $open = $false
    try {
        $iar = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            try { $client.EndConnect($iar); $open = $client.Connected } catch { $open = $false }
        }
    } catch { $open = $false } finally { try { $client.Close() } catch {} }
    $sw.Stop()
    [pscustomobject]@{ Port = $Port; Open = $open; LatencyMs = [int]$sw.ElapsedMilliseconds }
}

function Get-LocalIpForTarget {
    # The source IP the stack would actually use to reach $TargetHost. Taken
    # from a throwaway connected UDP socket rather than from Get-NetIPAddress,
    # because that is what makes multi-homed and VPN machines behave.
    param([string]$TargetHost,[int]$Port = 9)
    $ip = ''
    $s = $null
    try {
        $s = New-Object System.Net.Sockets.Socket ([System.Net.Sockets.AddressFamily]::InterNetwork), ([System.Net.Sockets.SocketType]::Dgram), ([System.Net.Sockets.ProtocolType]::Udp)
        $s.Connect($TargetHost, $Port)
        $ip = ([System.Net.IPEndPoint]$s.LocalEndPoint).Address.ToString()
    } catch { $ip = '' } finally { if ($s) { try { $s.Close() } catch {} } }
    return $ip
}

function Get-PublicIp {
    param([int]$TimeoutMs = 3000)
    foreach ($u in @('https://checkip.amazonaws.com','https://api.ipify.org','https://ifconfig.me/ip')) {
        try {
            $req = [System.Net.HttpWebRequest]::Create($u)
            $req.Timeout = $TimeoutMs
            $req.UserAgent = 'NetSpeed-Troubleshooter'
            $resp = $req.GetResponse()
            $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
            $txt = $sr.ReadToEnd().Trim()
            $sr.Close(); $resp.Close()
            $m = [regex]::Match($txt, '\d{1,3}(?:\.\d{1,3}){3}')
            if ($m.Success) { return $m.Value }
        } catch {}
    }
    return ''
}

function Get-LocalInterfaceMtu {
    # MTU of the interface that actually carries traffic to $ForTarget.
    #
    # Deliberately NOT "the interface with a default gateway": on a machine
    # running ZeroTier that picks the overlay and reports 2800, which would
    # then be compared against a real path MTU and reported as a constraint
    # that does not exist. Resolving the source address for the specific
    # target is VPN-proof.
    param([string]$ForTarget = '')
    $mtu = 0
    try {
        $lip = ''
        if ($ForTarget) { $lip = Get-LocalIpForTarget -TargetHost $ForTarget }
        if ($lip) {
            $addr = Get-NetIPAddress -IPAddress $lip -AddressFamily IPv4 -ErrorAction Stop | Select-Object -First 1
            if ($addr) {
                $ifx = Get-NetIPInterface -InterfaceIndex $addr.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop | Select-Object -First 1
                if ($ifx) { return [int]$ifx.NlMtu }
            }
        }
        $cfg = Get-NetIPConfiguration -ErrorAction Stop | Where-Object { $_.IPv4DefaultGateway -and $_.IPv4Address } | Select-Object -First 1
        if ($cfg) {
            $ifx = Get-NetIPInterface -InterfaceIndex $cfg.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop | Select-Object -First 1
            if ($ifx) { $mtu = [int]$ifx.NlMtu }
        }
    } catch { $mtu = 0 }
    return $mtu
}

function Get-PathMtu {
    # Path MTU by ICMP with the Don't Fragment bit set, binary searched.
    #
    # A DF-blackhole path - MTU below ~1400 with ICMP fragmentation-needed
    # filtered - breaks TLS handshakes part-way through. That presents as
    # "some sites load and some hang forever", which is reported as slowness
    # and is not slowness at all.
    param(
        [string]$ComputerName,
        [int]$TimeoutMs  = 1500,
        [int]$BudgetMs   = 20000,
        [int]$LocalMtu   = 0
    )
    $out = [pscustomobject]@{
        Ok = $false; PathMtu = 0; LocalMtu = $LocalMtu
        Constrained = $false; Detail = ''; Probes = 0
    }
    if ($out.LocalMtu -le 0) { $out.LocalMtu = Get-LocalInterfaceMtu -ForTarget $ComputerName }

    $ping = New-Object System.Net.NetworkInformation.Ping
    $opts = New-Object System.Net.NetworkInformation.PingOptions
    $opts.DontFragment = $true
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    # $true = fits, $false = too big, $null = no answer.
    $probe = {
        param([int]$payload)
        $buf = New-Object byte[] $payload
        for ($try = 0; $try -lt 3; $try++) {
            try {
                $r = $ping.Send($ComputerName, $TimeoutMs, $buf, $opts)
                if ($r.Status -eq [System.Net.NetworkInformation.IPStatus]::Success)      { return $true }
                if ($r.Status -eq [System.Net.NetworkInformation.IPStatus]::PacketTooBig) { return $false }
                # TimedOut and friends: retry - loss must not be read as "too big".
            } catch { }
        }
        return $null
    }

    try {
        # Gate: if plain ICMP does not come back, the whole search is eleven
        # timeouts that would end in a fabricated MTU.
        $out.Probes++
        $base = & $probe 32
        if ($base -ne $true) {
            $out.Detail = 'ICMP echo is filtered or unanswered on this path, so path MTU is not measurable from here.'
            return $out
        }

        $lo = 32          # known to fit
        $hi = 1473        # known-or-assumed too big (1472 + 28 = 1500)
        $out.Probes++
        $top = & $probe 1472
        if ($top -eq $true) {
            $out.Ok = $true
            $out.PathMtu = 1500
        } else {
            if ($null -eq $top) {
                $out.Detail = 'ICMP answered at 32 bytes but not at 1472, and not with a too-big response - the path is filtering large echoes, so path MTU is not measurable.'
                return $out
            }
            while (($hi - $lo) -gt 1) {
                if ($sw.Elapsed.TotalMilliseconds -gt $BudgetMs) {
                    $out.Detail = 'Path MTU search ran out of time.'
                    return $out
                }
                $mid = [int](($lo + $hi) / 2)
                $out.Probes++
                $r = & $probe $mid
                if ($r -eq $true)       { $lo = $mid }
                elseif ($r -eq $false)  { $hi = $mid }
                else {
                    $out.Detail = ('Path MTU search stalled: no answer at {0} bytes.' -f $mid)
                    return $out
                }
            }
            $out.Ok = $true
            $out.PathMtu = $lo + 28      # IPv4 header 20 + ICMP header 8
        }

        if ($out.LocalMtu -gt 0 -and $out.PathMtu -lt $out.LocalMtu) {
            $out.Constrained = $true
            $out.Detail = ('Path MTU is {0}, below this machine''s interface MTU of {1} - something on the path is constraining it. If ICMP fragmentation-needed is also filtered, TLS handshakes stall part-way, which presents as some sites loading and others hanging.' -f $out.PathMtu, $out.LocalMtu)
        } elseif ($out.LocalMtu -gt 0) {
            $out.Detail = ('Path MTU is {0}, matching this machine''s interface MTU - no constraint on the path.' -f $out.PathMtu)
        } else {
            $out.Detail = ('Path MTU is {0}.' -f $out.PathMtu)
        }
    } catch {
        $out.Detail = $_.Exception.Message
    } finally {
        $sw.Stop()
        try { $ping.Dispose() } catch {}
    }
    return $out
}

# ===========================================================================
#  HTTP stack defaults
#
#  Every one of these was measured wrong on a stock Windows PowerShell 5.1
#  session, and each one silently degrades a measurement rather than failing
#  it. That is the worst kind of bug in a diagnostic tool: it produces a
#  number, the number looks plausible, and it is wrong.
# ===========================================================================

function Set-NsNetDefaults {
    # Call once per runspace, before any request is created.
    param([switch]$Quiet)
    $applied = [Activator]::CreateInstance([System.Collections.Generic.List[string]])
    try {
        # MEASURED DEFAULT: 2. .NET caps concurrent connections per host at two
        # unless told otherwise, so a "6-stream" test silently runs two streams
        # and under-reports every fast link. This is the single most likely way
        # for this tool to be quietly wrong.
        if ([System.Net.ServicePointManager]::DefaultConnectionLimit -lt 64) {
            [System.Net.ServicePointManager]::DefaultConnectionLimit = 64
            $applied.Add('DefaultConnectionLimit 2 -> 64')
        }
    } catch {}
    try {
        # MEASURED DEFAULT: True. Costs an extra round trip on every upload POST.
        if ([System.Net.ServicePointManager]::Expect100Continue) {
            [System.Net.ServicePointManager]::Expect100Continue = $false
            $applied.Add('Expect100Continue disabled')
        }
    } catch {}
    try {
        [System.Net.ServicePointManager]::UseNagleAlgorithm = $false
        $applied.Add('Nagle disabled')
    } catch {}
    try {
        # MEASURED DEFAULT: SystemDefault, which on older builds negotiates
        # TLS 1.0 and gets refused outright by Cloudflare.
        $proto = [System.Net.SecurityProtocolType]::Tls12 -bor
                 [System.Net.SecurityProtocolType]::Tls11 -bor
                 [System.Net.SecurityProtocolType]::Tls
        # Tls13 is absent from the enum on .NET Framework below 4.8 and
        # referencing the member directly throws, so it is probed by name.
        $tls13 = 'Tls13' -as [System.Net.SecurityProtocolType]
        if ($null -ne $tls13) { $proto = $proto -bor $tls13 }
        [System.Net.ServicePointManager]::SecurityProtocol = $proto
        $applied.Add('TLS 1.2 forced')
    } catch {}
    if (-not $Quiet) { return ($applied -join '; ') }
    return ''
}

function New-NsWebRequest {
    # One place where every request in the tool is configured, so a per-request
    # setting cannot be forgotten on one code path and present on another.
    param(
        [string]$Uri,
        [string]$Method = 'GET',
        [int]$TimeoutMs = 15000,
        [int]$ReadWriteTimeoutMs = 8000,
        [switch]$BypassProxy,
        [switch]$NoCacheBuster
    )
    $u = $Uri
    if (-not $NoCacheBuster) {
        # A caching proxy between here and Cloudflare would serve the zero-fill
        # from RAM and report a LAN speed as an internet speed. The buster plus
        # NoCacheNoStore makes that impossible to mistake for a real result.
        $sep = '?'
        if ($u.Contains('?')) { $sep = '&' }
        $u = ('{0}{1}nsb={2}' -f $u, $sep, [guid]::NewGuid().ToString('N'))
    }
    $req = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($u)
    $req.Method            = $Method
    $req.Timeout           = $TimeoutMs
    $req.ReadWriteTimeout  = $ReadWriteTimeoutMs
    $req.AllowAutoRedirect = $false
    $req.KeepAlive         = $true
    $req.UserAgent         = ('NetSpeed-Troubleshooter/{0}' -f (Get-NetSpeedVersion))
    try { $req.CachePolicy = New-Object System.Net.Cache.RequestCachePolicy([System.Net.Cache.RequestCacheLevel]::NoCacheNoStore) } catch {}
    # DefaultConnectionLimit only applies to ServicePoints created AFTER it is
    # set. If anything in this process already touched this host, that
    # ServicePoint keeps the old limit of 2 - so it is raised per request too.
    try { $req.ServicePoint.ConnectionLimit = 64 } catch {}
    if ($BypassProxy) { try { $req.Proxy = $null } catch {} }
    return $req
}

function Get-NsProxyInfo {
    # What the HTTP stack would actually do with a request to $TestUri.
    #
    # Worth a row of its own because under SYSTEM in a Backstage session the
    # effective proxy is usually NOT the signed-in user's, and a throughput
    # figure measured through a different proxy than the user's traffic takes
    # is not a measurement of the user's experience.
    param([string]$TestUri = 'https://speed.cloudflare.com/')
    $out = [pscustomobject]@{
        Configured = $false; ProxyUri = ''; Bypassed = $false; Detail = ''
    }
    try {
        $p = [System.Net.WebRequest]::DefaultWebProxy
        if ($null -eq $p) { $out.Detail = 'No default proxy object.'; return $out }
        $target = [uri]$TestUri
        $via = $p.GetProxy($target)
        if ($null -ne $via -and $via.AbsoluteUri.TrimEnd('/') -ne $target.AbsoluteUri.TrimEnd('/') -and
            $via.Host -ne $target.Host) {
            $out.Configured = $true
            $out.ProxyUri   = $via.AbsoluteUri
            $out.Detail     = ('Requests to {0} go via {1}.' -f $target.Host, $via.AbsoluteUri)
        } else {
            $out.Bypassed = $true
            $out.Detail   = 'Direct - no proxy applies to this host.'
        }
    } catch { $out.Detail = $_.Exception.Message }
    return $out
}

function Get-NsCfMeta {
    # Cloudflare tells us where we landed and what its own TCP stack saw, in
    # the response headers of the transfer we were doing anyway.
    #
    # NOTE: speed.cloudflare.com/meta returns 403 to a plain HttpWebRequest -
    # verified, and most reference implementations get this wrong. Everything
    # here comes from the __down/__up response instead, which costs nothing.
    param($Response)
    $out = [pscustomobject]@{
        ClientIp = ''; Colo = ''; Asn = $null; City = ''; Country = ''; CfRay = ''
        EdgeMs = $null; WorkerMs = $null
        L4 = $null
    }
    if ($null -eq $Response) { return $out }
    $h = $null
    try { $h = $Response.Headers } catch { return $out }
    if ($null -eq $h) { return $out }

    $get = {
        param([string]$name)
        try { $v = $h[$name]; if ($v) { return [string]$v } } catch {}
        return ''
    }
    # VERIFIED against a live response: the endpoint advertises cf-meta-asn /
    # cf-meta-city / cf-meta-country in access-control-expose-headers but
    # actually SENDS them bare as asn / city / country, while the client IP
    # really is cf-meta-ip. Both spellings are tried so a change either way
    # degrades to a blank field rather than a wrong one.
    $first = {
        param([string[]]$names)
        foreach ($n in $names) { $v = & $get $n; if ($v) { return $v } }
        return ''
    }
    $out.ClientIp = & $first @('cf-meta-ip','ip')
    $out.Colo     = & $first @('colo','cf-meta-colo')
    $out.City     = & $first @('city','cf-meta-city')
    $out.Country  = & $first @('country','cf-meta-country')
    $out.CfRay    = & $first @('cf-ray')
    $asnTxt       = & $first @('asn','cf-meta-asn')
    if ($asnTxt -match '^\d+$') { $out.Asn = [int]$asnTxt }

    $st = & $get 'Server-Timing'
    if ($st) {
        # Tolerant parsing: this header's format has already changed once
        # (older clients look for cfRequestDuration), so a miss must degrade to
        # null rather than throw.
        $m = [regex]::Match($st, 'cfSpeedEdge;dur=([\d\.]+)')
        if ($m.Success) { $out.EdgeMs = [double]$m.Groups[1].Value }
        $m = [regex]::Match($st, 'cfSpeedWorker;dur=([\d\.]+)')
        if ($m.Success) { $out.WorkerMs = [double]$m.Groups[1].Value }
        $m = [regex]::Match($st, 'cfL4;desc="([^"]*)"')
        if ($m.Success) {
            $desc = $m.Groups[1].Value
            $l4 = [pscustomobject]@{
                Proto = ''; RttUs = $null; MinRttUs = $null; RttVarUs = $null
                Lost = $null; Retrans = $null; Cwnd = $null; DeliveryRateRaw = $null
            }
            foreach ($pair in ($desc.TrimStart('?') -split '&')) {
                $kv = $pair -split '=', 2
                if ($kv.Count -ne 2) { continue }
                switch ($kv[0]) {
                    'proto'         { $l4.Proto    = $kv[1] }
                    'rtt'           { $l4.RttUs    = [double]$kv[1] }
                    'min_rtt'       { $l4.MinRttUs = [double]$kv[1] }
                    'rtt_var'       { $l4.RttVarUs = [double]$kv[1] }
                    'lost'          { $l4.Lost     = [double]$kv[1] }
                    'retrans'       { $l4.Retrans  = [double]$kv[1] }
                    'cwnd'          { $l4.Cwnd     = [double]$kv[1] }
                    # delivery_rate does not reconcile with observed throughput
                    # in any obvious unit, so it is carried as opaque data and
                    # must never be published as a speed.
                    'delivery_rate' { $l4.DeliveryRateRaw = $kv[1] }
                }
            }
            $out.L4 = $l4
        }
    }
    return $out
}

# ===========================================================================
#  Latency probe bag
#
#  Probes have to be fired from inside the throughput read loop without ever
#  blocking it, because the whole point of a loaded-latency measurement is
#  that the load must not pause while latency is sampled.
#
#  SendPingAsync returns a Task and completes on an IO completion port, so it
#  costs nothing to have several outstanding. The trap: a single Ping instance
#  cannot have two async sends in flight - the second throws
#  InvalidOperationException. So one Ping object is created per probe and
#  disposed on harvest. At 5 probes/second that is a few dozen short-lived
#  objects, which is irrelevant next to being able to measure at all.
# ===========================================================================

function New-NsProbeBag {
    param([string[]]$IcmpTargets = @(), [string]$HttpUrl = '', [switch]$BypassProxy)
    $res = @{}
    foreach ($t in $IcmpTargets) { if ($t) { $res[$t] = [Activator]::CreateInstance([System.Collections.Generic.List[double]]) } }
    if ($HttpUrl) { $res['http'] = [Activator]::CreateInstance([System.Collections.Generic.List[double]]) }
    @{
        IcmpTargets = [string[]]@($IcmpTargets | Where-Object { $_ })
        HttpUrl     = $HttpUrl
        BypassProxy = [bool]$BypassProxy
        Pending     = [Activator]::CreateInstance([System.Collections.Generic.List[object]])
        Results     = $res
        Sent        = @{}
        Lost        = @{}
        Phase       = 'idle'
        # Instrument noise floor. Probes are harvested by polling, so the gap
        # between one harvest and the next bounds how much of this tool's own
        # scheduling can appear in a wall-clock timing. ICMP is immune (see
        # Receive-NsProbes) but the HTTP probe is not, so the worst gap is
        # tracked and published beside the HTTP figure.
        MaxPollGapMs = 0.0
        SumPollGapMs = 0.0
        PollGapCount = 0
        LastPollMs   = -1.0
        # Per target. Four in flight is ample for a 200 ms send interval on any
        # link where probes come back at all, and it bounds both the connection
        # pool cost and the drain cost when they do not.
        MaxOutstanding = 4
        Skipped        = @{}
    }
}

function Send-NsProbes {
    # Fire one probe at every target. Never blocks.
    #
    # A probe is only fired if that target has fewer than MaxOutstanding still
    # in flight. Without the cap, a link slow enough that probes do not return
    # inside the send interval accumulates them without bound: they compete for
    # the same connection pool as the transfer being measured, and draining
    # them at the end costs a timeout each. Observed on a real Server 2012 R2
    # site - a ten-second stage took four and a half minutes.
    #
    # A skipped probe is NOT counted as sent or lost. It was never fired, so
    # folding it into the loss figure would be inventing packet loss.
    param($Bag, $Stopwatch)
    $outstanding = @{}
    foreach ($e in $Bag.Pending) {
        if (-not $outstanding.ContainsKey($e.Target)) { $outstanding[$e.Target] = 0 }
        $outstanding[$e.Target] = $outstanding[$e.Target] + 1
    }
    $cap = $Bag.MaxOutstanding
    foreach ($t in $Bag.IcmpTargets) {
        if ($outstanding.ContainsKey($t) -and $outstanding[$t] -ge $cap) {
            if (-not $Bag.Skipped.ContainsKey($t)) { $Bag.Skipped[$t] = 0 }
            $Bag.Skipped[$t] = $Bag.Skipped[$t] + 1
            continue
        }
        try {
            $p = New-Object System.Net.NetworkInformation.Ping
            $task = $p.SendPingAsync($t, 1000)
            $Bag.Pending.Add([pscustomobject]@{
                Kind = 'icmp'; Target = $t; Ping = $p; Task = $task
                Req = $null; Iar = $null
                At = $Stopwatch.Elapsed.TotalMilliseconds
            })
            if (-not $Bag.Sent.ContainsKey($t)) { $Bag.Sent[$t] = 0 }
            $Bag.Sent[$t] = $Bag.Sent[$t] + 1
        } catch {
            # A Ping that cannot even be created is not a network finding.
        }
    }
    if ($Bag.HttpUrl -and -not ($outstanding.ContainsKey('http') -and $outstanding['http'] -ge $cap)) {
        try {
            $req = New-NsWebRequest -Uri $Bag.HttpUrl -TimeoutMs 5000 -ReadWriteTimeoutMs 5000 -BypassProxy:$Bag.BypassProxy
            $iar = $req.BeginGetResponse($null, $null)
            $Bag.Pending.Add([pscustomobject]@{
                Kind = 'http'; Target = 'http'; Ping = $null; Task = $null
                Req = $req; Iar = $iar
                At = $Stopwatch.Elapsed.TotalMilliseconds
            })
            if (-not $Bag.Sent.ContainsKey('http')) { $Bag.Sent['http'] = 0 }
            $Bag.Sent['http'] = $Bag.Sent['http'] + 1
        } catch {}
    } elseif ($Bag.HttpUrl) {
        if (-not $Bag.Skipped.ContainsKey('http')) { $Bag.Skipped['http'] = 0 }
        $Bag.Skipped['http'] = $Bag.Skipped['http'] + 1
    }
}

function Receive-NsProbes {
    # Harvest whatever has completed. Walks backwards so entries can be removed
    # in place. Never blocks, never touches .Result on a faulted task.
    param($Bag, $Stopwatch, [switch]$Drain)
    $nowPoll = $Stopwatch.Elapsed.TotalMilliseconds
    if ($Bag.LastPollMs -ge 0) {
        $gap = $nowPoll - $Bag.LastPollMs
        if ($gap -gt $Bag.MaxPollGapMs) { $Bag.MaxPollGapMs = $gap }
        $Bag.SumPollGapMs += $gap
        $Bag.PollGapCount++
    }
    $Bag.LastPollMs = $nowPoll
    for ($i = $Bag.Pending.Count - 1; $i -ge 0; $i--) {
        $e = $Bag.Pending[$i]
        $done = $false
        $rttMs = -1.0
        if ($e.Kind -eq 'icmp') {
            if (-not $e.Task.IsCompleted -and $Drain) {
                # Abandon it. Do NOT touch .Result on an incomplete task - that
                # BLOCKS until the ping times out, and draining fifty of them
                # serially is how a ten-second stage became four minutes.
                $done = $true
                try { $e.Ping.SendAsyncCancel() } catch { }
                try { $e.Ping.Dispose() } catch { }
            } elseif ($e.Task.IsCompleted) {
                $done = $true
                if (-not $e.Task.IsFaulted -and -not $e.Task.IsCanceled) {
                    try {
                        $r = $e.Task.Result
                        if ($r.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                            # RoundtripTime, NOT a stopwatch delta.
                            #
                            # These probes are harvested by polling, so a
                            # wall-clock measurement spans fire-to-HARVEST, not
                            # fire-to-reply. That is catastrophic here: the
                            # loop is busiest exactly when latency-under-load
                            # is being measured, so the tool's own scheduling
                            # delay gets reported as network latency and the
                            # bufferbloat figure inflates itself.
                            #
                            # Caught by comparing against a synchronous ping to
                            # the same gateway in the soak stage: wall-clock
                            # read 30 ms where the true RTT was 1 ms, which
                            # traceroute independently confirmed as 1.8 ms.
                            #
                            # RoundtripTime is computed in the network stack
                            # from the reply itself, so it is immune. The cost
                            # is 1 ms quantisation, which is irrelevant against
                            # WAN latencies and is stated where it is not.
                            $rttMs = [double]$r.RoundtripTime
                        }
                    } catch {}
                }
                try { $e.Ping.Dispose() } catch {}
            }
        } else {
            if (-not $e.Iar.IsCompleted -and $Drain) {
                # Same trap, worse: EndGetResponse on an INCOMPLETE request
                # blocks until that request's own 5-second timeout expires.
                # Abort and count it lost instead.
                $done = $true
                try { $e.Req.Abort() } catch { }
            } elseif ($e.Iar.IsCompleted) {
                $done = $true
                try {
                    $resp = $e.Req.EndGetResponse($e.Iar)
                    # Unlike ICMP there is no stack-provided timing here, so
                    # this measurement necessarily spans fire-to-harvest and
                    # carries however long the loop took to come back round.
                    # It is therefore an UPPER BOUND, and the bag's
                    # MaxPollGapMs is published beside it so a reader can see
                    # how much of it could be this tool rather than the link.
                    $rttMs = $Stopwatch.Elapsed.TotalMilliseconds - $e.At
                    try { $resp.Close() } catch {}
                } catch {
                    try { $e.Req.Abort() } catch {}
                }
            }
        }
        if ($done) {
            if ($rttMs -ge 0) {
                $Bag.Results[$e.Target].Add($rttMs)
            } else {
                if (-not $Bag.Lost.ContainsKey($e.Target)) { $Bag.Lost[$e.Target] = 0 }
                $Bag.Lost[$e.Target] = $Bag.Lost[$e.Target] + 1
            }
            $Bag.Pending.RemoveAt($i)
        }
    }
}

function Close-NsProbeBag {
    # Give outstanding probes a brief moment, then drop them. Anything still
    # outstanding is counted as lost rather than silently discarded.
    param($Bag, $Stopwatch)
    $wait = [System.Diagnostics.Stopwatch]::StartNew()
    while ($Bag.Pending.Count -gt 0 -and $wait.ElapsedMilliseconds -lt 1200) {
        Receive-NsProbes -Bag $Bag -Stopwatch $Stopwatch
        if ($Bag.Pending.Count -gt 0) { Start-Sleep -Milliseconds 25 }
    }
    # The drain ABANDONS anything still outstanding rather than waiting on it.
    # This call is bounded by the number of pending probes, not by their
    # timeouts - see Receive-NsProbes.
    Receive-NsProbes -Bag $Bag -Stopwatch $Stopwatch -Drain
    $wait.Stop()
}

function Get-NsProbeSummary {
    # Per-target latency statistics for one phase.
    param($Bag)
    $out = @{}
    foreach ($k in @($Bag.Results.Keys)) {
        $vals = [double[]]@($Bag.Results[$k])
        $sent = 0; if ($Bag.Sent.ContainsKey($k)) { $sent = $Bag.Sent[$k] }
        $lost = 0; if ($Bag.Lost.ContainsKey($k)) { $lost = $Bag.Lost[$k] }
        $st = Get-NsStats -Values $vals
        $lossPct = 0.0
        if ($sent -gt 0) { $lossPct = ([double]$lost / [double]$sent) * 100.0 }
        # ICMP figures come from the stack and carry no instrument noise. The
        # HTTP figure is polled and therefore carries up to one poll gap.
        $noise = 0.0
        $noiseMax = 0.0
        $usable = $true
        $basis = 'stack RoundtripTime - not affected by this tool''s polling'
        if ($k -eq 'http') {
            # Mean gap for the typical case, max for the worst. The mean is
            # what a median measurement should be judged against; a single
            # long stall should not disqualify the whole series.
            if ($Bag.PollGapCount -gt 0) { $noise = [math]::Round(($Bag.SumPollGapMs / $Bag.PollGapCount), 1) }
            $noiseMax = [math]::Round($Bag.MaxPollGapMs, 1)
            $basis = 'polled wall-clock - an upper bound that includes this tool''s own poll delay'
            # Below three times the noise floor the tool is largely measuring
            # itself, which is the same resolution rule applied everywhere else
            # here. The figure is still reported, but flagged as unusable so no
            # conclusion is drawn from it.
            $usable = ($st.P50 -gt ($noise * 3))
        }
        $skipped = 0
        if ($Bag.Skipped -and $Bag.Skipped.ContainsKey($k)) { $skipped = $Bag.Skipped[$k] }
        $out[$k] = [pscustomobject]@{
            n           = $st.N
            sent        = $sent
            skipped     = $skipped
            lost        = $lost
            lossPct     = [math]::Round($lossPct, 1)
            minMs       = [math]::Round($st.Min, 1)
            p50Ms       = [math]::Round($st.P50, 1)
            p95Ms       = [math]::Round($st.P95, 1)
            maxMs       = [math]::Round($st.Max, 1)
            jitterMs    = [math]::Round((Get-NsJitter -Values $vals), 1)
            noiseFloorMs = $noise
            noiseMaxMs   = $noiseMax
            usable       = $usable
            basis       = $basis
        }
    }
    return $out
}

# ===========================================================================
#  Cloudflare multi-stream throughput engine
#
#  CONCURRENCY MODEL - one thread, N HttpWebRequests issued together with
#  BeginGetResponse, then a round-robin chunked read loop.
#
#  This works because the kernel keeps all N TCP receive windows filled
#  whether or not user code is reading them; a 256 KB round-robin drain is
#  memory-copy bound and cannot become the bottleneck at any speed this tool
#  claims to measure. Cancellation and progress reporting are then free,
#  because we are sitting in an ordinary loop rather than inside a callback.
#
#  Three alternatives were tried and rejected. They are recorded here because
#  each one LOOKS more idiomatic and each one is silently broken on 5.1:
#
#    * Nested runspace pool - each child runspace must reparse this entire
#      helpers file, burning 1.5-4 s of startup inside a 10 s measurement.
#      Kept as the documented escape hatch if the single thread ever caps out.
#    * [AsyncCallback]{...} scriptblock delegates - PowerShell invokes them on
#      a threadpool thread with NO RUNSPACE ATTACHED. Fails intermittently and
#      non-deterministically with "There is no Runspace available".
#    * WebClient + Register-ObjectEvent - engine events only drain when the
#      pipeline is idle. Inside a busy worker they never fire at all, and the
#      test reports zero throughput with no error.
#
#  And one landmine: the worker runspace is STA (house rule), and
#  WaitHandle.WaitAll throws NotSupportedException on an STA thread. Never
#  use it here - EndGetResponse in a loop, or WaitOne per handle.
# ===========================================================================

function Get-NsCfEndpoints {
    @{
        Host     = 'speed.cloudflare.com'
        Down     = 'https://speed.cloudflare.com/__down?bytes={0}'
        Up       = 'https://speed.cloudflare.com/__up'
        Latency  = 'https://speed.cloudflare.com/__down?bytes=0'
        MaxPerReq = 104857600      # 100 MB per request, capped in code
    }
}

function Get-NsCfQuickMeta {
    # Colo / client IP / ASN / cfL4 in one zero-byte request.
    #
    # Needed because an upload run only sees a response when a POST completes,
    # and a 10-second upload that never finishes a request would otherwise
    # report no edge, no ASN and no server-side loss figures at all.
    param([switch]$BypassProxy)
    $ep = Get-NsCfEndpoints
    $req = $null; $resp = $null
    try {
        $req = New-NsWebRequest -Uri $ep.Latency -TimeoutMs 8000 -ReadWriteTimeoutMs 5000 -BypassProxy:$BypassProxy
        $resp = $req.GetResponse()
        return (Get-NsCfMeta -Response $resp)
    } catch {
        return $null
    } finally {
        if ($resp) { try { $resp.Close() } catch {} }
        if ($req)  { try { $req.Abort() }  catch {} }
    }
}

function Get-NsNameResolutionDiagnosis {
    # Why can't we reach this host? Turns an opaque "the remote name could not
    # be resolved" into something a technician can act on.
    #
    # The case that matters most is DNS FILTERING. A filtering resolver does not
    # refuse a blocked name, it answers with 0.0.0.0 (or 127.0.0.1), so the
    # connection fails at connect time with a message that says nothing about
    # the cause. Observed on the machine this was written on: AdGuard DNS
    # (94.140.14.14) returning 0.0.0.0 for cloudflare.com while every other
    # name resolved normally and ICMP to 1.1.1.1 was fine.
    #
    # Getting this wrong sends a technician to the ISP over a DNS policy.
    param([string]$HostName)
    $out = [pscustomobject]@{
        Resolvable = $false; Blackholed = $false; Addresses = @()
        Diagnosis = ''; Detail = ''
    }
    $addrs = @()
    try {
        if (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
            $r = Resolve-DnsName -Name $HostName -Type A -QuickTimeout -ErrorAction Stop
            $addrs = @($r | Where-Object { $_.IPAddress } | ForEach-Object { [string]$_.IPAddress })
        } else {
            # GetHostAddresses has no timeout parameter, so it is started async
            # and ABANDONED if it does not come back - End* is only ever called
            # on a completed operation. Same pattern as Get-NsDeviceIdentity.
            $dnsIar = [System.Net.Dns]::BeginGetHostAddresses($HostName, $null, $null)
            if ($dnsIar.AsyncWaitHandle.WaitOne(4000, $false) -and $dnsIar.IsCompleted) {
                $addrs = @([System.Net.Dns]::EndGetHostAddresses($dnsIar) | ForEach-Object { $_.IPAddressToString })
            } else {
                throw ('Name resolution for {0} did not complete within 4 seconds.' -f $HostName)
            }
        }
    } catch {
        $out.Diagnosis = ('DNS could not resolve {0} at all.' -f $HostName)
        $out.Detail    = ('This machine cannot look up {0}, so nothing can be measured against it. Check the configured DNS servers and whether they are reachable.' -f $HostName)
        return $out
    }
    $out.Addresses = [object[]]$addrs
    if ($addrs.Count -eq 0) {
        $out.Diagnosis = ('DNS returned no address for {0}.' -f $HostName)
        $out.Detail    = ('The name exists but no A record came back. On a filtering resolver that is how a blocked domain often looks.')
        return $out
    }
    $blackhole = @($addrs | Where-Object { $_ -eq '0.0.0.0' -or $_ -eq '127.0.0.1' -or $_ -eq '::' })
    if ($blackhole.Count -eq $addrs.Count) {
        $out.Blackholed = $true
        $out.Diagnosis  = ('{0} resolves to {1}, which means DNS filtering is blocking it.' -f $HostName, ($addrs -join ', '))
        $out.Detail     = ('A filtering DNS server answers a blocked name with a null address rather than refusing it, so the connection fails with a message that says nothing about the cause. This is a DNS POLICY on this network, not a fault with the internet connection - do not take it to the ISP. Allow-list {0} on the filtering service, or point this machine at a resolver that does not block it, then re-run.' -f $HostName)
        return $out
    }
    $out.Resolvable = $true
    $out.Diagnosis  = ('{0} resolves to {1}.' -f $HostName, ($addrs -join ', '))
    return $out
}

function Get-NsHttpErrorReason {
    # A WebException carries the HTTP status, but the default message
    # ("The remote server returned an error: (403) Forbidden.") tells a
    # technician nothing about what to do. Seen live on a customer site: the
    # sizing probe succeeded at 57.7 Mbps and the very next request - the real
    # multi-stream download - came back 403 while the UPLOAD kept working. That
    # is the shape of endpoint-side rate limiting, not a network fault, and
    # reporting it as a bare exception sends people hunting a phantom.
    param($Exception)
    $out = [pscustomobject]@{ Status = 0; Reason = ''; RateLimited = $false }
    if (-not $Exception) { return $out }
    $we = $Exception
    if ($we -isnot [System.Net.WebException] -and $we.InnerException) { $we = $we.InnerException }
    $resp = $null
    try { $resp = $we.Response } catch { }
    if ($resp) {
        try { $out.Status = [int]$resp.StatusCode } catch { }
    }
    switch ($out.Status) {
        403 {
            $out.RateLimited = $true
            $out.Reason = 'speed.cloudflare.com refused the transfer with 403 Forbidden. The link is not at fault - the test endpoint is declining this site. That is almost always rate limiting after repeated runs from one public IP, and it clears on its own after a few minutes. It can also mean a filtering appliance or an upstream proxy is blocking that host. Wait and re-run, or use the Ookla button for an independent figure.'
        }
        429 {
            $out.RateLimited = $true
            $out.Reason = 'speed.cloudflare.com returned 429 Too Many Requests. This site has run too many tests too quickly from one public IP. Leave it a few minutes and re-run.'
        }
        default {
            if ($out.Status -gt 0) {
                $out.Reason = ('speed.cloudflare.com returned HTTP {0}. The transfer was refused before any throughput could be measured, so this is an endpoint or filtering problem rather than a link problem.' -f $out.Status)
            } else {
                $out.Reason = [string]$Exception.Message
            }
        }
    }
    return $out
}

function Measure-CfProbeRate {
    # A short single-stream probe used only to SIZE the real test.
    #
    # A fixed byte ladder (100 kB / 1 MB / 10 MB) cannot serve a fixed-duration
    # test on an unknown link: on 10 Mbps a 10 MB request is the whole run, and
    # on 1 Gbps it is over before slow start finishes. So the link is probed
    # first, and the clock - never the byte count - stays authoritative.
    param([double]$Seconds = 2.0, [switch]$BypassProxy, $Shared = $null)
    $ep  = Get-NsCfEndpoints
    $out = [pscustomobject]@{ Ok = $false; Mbps = 0.0; Meta = $null; Detail = '' }
    $req = $null; $resp = $null; $stm = $null
    try {
        $req = New-NsWebRequest -Uri ($ep.Down -f 26214400) -TimeoutMs 15000 -ReadWriteTimeoutMs 8000 -BypassProxy:$BypassProxy
        $sw  = [System.Diagnostics.Stopwatch]::StartNew()
        $resp = $req.GetResponse()
        $tHeaders = $sw.Elapsed.TotalSeconds
        $out.Meta = Get-NsCfMeta -Response $resp
        $stm = $resp.GetResponseStream()
        $buf = New-Object byte[] 262144
        $bytes = 0.0
        while ($sw.Elapsed.TotalSeconds -lt ($tHeaders + $Seconds)) {
            if ($Shared -and $Shared.Cancel) { break }
            $n = $stm.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $bytes += $n
        }
        $elapsed = $sw.Elapsed.TotalSeconds - $tHeaders
        $sw.Stop()
        if ($elapsed -gt 0.2 -and $bytes -gt 0) {
            $out.Mbps = ($bytes * 8.0) / $elapsed / 1000000.0
            $out.Ok = $true
        } else {
            $out.Detail = 'Probe transferred nothing measurable.'
        }
    } catch {
        $out.Detail = $_.Exception.Message
    } finally {
        if ($stm)  { try { $stm.Close() }  catch {} }
        if ($resp) { try { $resp.Close() } catch {} }
        if ($req)  { try { $req.Abort() }  catch {} }
    }
    return $out
}

function Invoke-CfThroughput {
    # The measurement. Returns a raw result object; formatting into rows and a
    # section envelope is the caller's job.
    param(
        [ValidateSet('Down','Up')][string]$Direction = 'Down',
        [int]$Streams        = 6,
        [double]$MeasureSec  = 10.0,
        [double]$WarmupSec   = -1,
        [double]$EstMbps     = 0,
        $Shared              = $null,
        [string]$VersionKey  = '',
        [string]$StatusPrefix = '',
        [switch]$BypassProxy,
        [switch]$Wwan,
        [string]$WwanBasis = '',
        $ProbeBag            = $null,
        [double]$ProbeIntervalMs = 200
    )
    $lim = Get-NsLimits
    $ep  = Get-NsCfEndpoints
    if ($WarmupSec -lt 0) { $WarmupSec = $lim.WarmupSec }

    $out = [pscustomobject]@{
        Direction          = $Direction
        Ok                 = $false
        State              = 'failed'
        Reason             = ''
        Samples            = [double[]]@()
        Stats              = $null
        # Total measured bytes over total measured seconds. Immune to window
        # quantisation because it never divides by a window, so it is the
        # cross-check that catches a percentile drifting above line rate.
        OverallMbps        = 0.0
        BurstyWindows      = $false
        PercentileWithheld = $false
        EndpointRefused    = $false
        TotalBytes         = 0.0
        MeasuredBytes      = 0.0
        WarmupBytes        = 0.0
        MeasuredSec        = 0.0
        StreamsRequested   = $Streams
        StreamsEstablished = 0
        PerStreamBytes     = @()
        Restarts           = 0
        Meta               = $null
        ServerTiming       = $null
        WindowMs           = 0
        WarmupSec          = $WarmupSec
        CapHit             = ''
        Cancelled          = $false
        WwanProfile        = $false
        WwanBasis          = ''
    }

    # ---- code-enforced safety caps -----------------------------------------
    # Deliberately not reachable from the UI. An unbounded speed test on a
    # metered link is a bill, and the person who most needs this guard rail is
    # the one least likely to tick a box asking for it.
    if ($Wwan) {
        $out.WwanProfile = $true
        $out.WwanBasis   = $WwanBasis
        $Streams    = $lim.WwanStreams
        $MeasureSec = $lim.WwanSec
        $maxBytes   = [double]$lim.WwanMaxBytes
    } else {
        if ($Direction -eq 'Down') { $maxBytes = [double]$lim.MaxDownBytes }
        else                       { $maxBytes = [double]$lim.MaxUpBytes }
    }
    if ($Streams -lt 1) { $Streams = 1 }
    if ($Streams -gt $lim.MaxStreams) { $Streams = $lim.MaxStreams }
    if ($MeasureSec -gt $lim.MaxSecPerDir) { $MeasureSec = $lim.MaxSecPerDir }
    $out.StreamsRequested = $Streams

    # Upload windows are quantised by how fast the socket send buffer accepts
    # data, not by how fast it drains, so they are lumpier than download
    # windows. A wider window smooths that without hiding real variation.
    $windowMs = $lim.WindowMs
    if ($Direction -eq 'Up') { $windowMs = 250 }
    # ...but the window must never be so wide that the configured duration
    # cannot produce enough of them to support a percentile, or the run is
    # refused for a reason that is purely the tool's own arithmetic. A 6 s
    # upload at a 250 ms window yields 24 windows against a minimum of 20, and
    # the 3 s cellular profile yields 12 - so it would refuse every single
    # time. Targeting ~30 windows keeps every profile self-consistent.
    $maxWindow = [int](($MeasureSec * 1000.0) / 30.0)
    if ($maxWindow -lt 50) { $maxWindow = 50 }
    if ($windowMs -gt $maxWindow) { $windowMs = $maxWindow }
    $out.WindowMs = $windowMs

    # ---- sizing -------------------------------------------------------------
    if ($EstMbps -le 0) { $EstMbps = 50 }
    $perStream = ($EstMbps * 1000000.0 / 8.0) * ($MeasureSec + 5.0) / $Streams
    if ($perStream -lt 5242880)  { $perStream = 5242880 }
    if ($perStream -gt $ep.MaxPerReq) { $perStream = $ep.MaxPerReq }
    $perStream = [long]$perStream

    # ---- read/write chunk, sized against the window -------------------------
    # This is a correctness fix, not a tuning knob. A single Read returns up to
    # one chunk and all of it is credited to whichever window is open when the
    # call returns. If the chunk is large relative to what the link can deliver
    # in one window, individual windows are inflated far above line rate:
    # measured on a real 10 Mbps link with a 256 KB chunk, p90 read 11.0 Mbps
    # and max 13.4 Mbps - both physically impossible - because one 256 KB read
    # is 1.7 s of traffic landing inside a 100 ms bucket.
    #
    # Sizing the chunk so roughly eight of them fit in a window keeps the
    # quantisation error under about an eighth of a window and makes the
    # percentile meaningful. Fast links keep the big chunk they need; slow
    # links get a small one, which costs nothing because the link is the
    # bottleneck anyway.
    $windowSec  = $windowMs / 1000.0
    $bytesPerSec = ($EstMbps * 1000000.0 / 8.0)
    $chunk = [int]($bytesPerSec * $windowSec / 8.0)
    if ($chunk -lt 8192)   { $chunk = 8192 }
    if ($chunk -gt 262144) { $chunk = 262144 }
    if ($Direction -eq 'Up' -and $chunk -gt 65536) { $chunk = 65536 }

    # Upload payload is pseudo-random, not zeros: a transparent compressing
    # middlebox would ship a zero-fill almost for free and report an upload
    # speed the link cannot actually deliver.
    $sendBuf = $null
    if ($Direction -eq 'Up') {
        $sendBuf = New-Object byte[] $chunk
        (New-Object System.Random).NextBytes($sendBuf)
    }

    $slots = [Activator]::CreateInstance([System.Collections.Generic.List[object]])
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $warmupMs = $WarmupSec * 1000.0
    $deadlineMs = $warmupMs + ($MeasureSec * 1000.0)

    $newSlot = {
        param([int]$id)
        $s = [pscustomobject]@{
            Id = $id; Req = $null; Resp = $null; Stream = $null
            Buf = $null; Bytes = 0.0; Written = 0L; Length = $perStream
            Live = $false; Iar = $null
        }
        try {
            if ($Direction -eq 'Down') {
                $s.Req = New-NsWebRequest -Uri ($ep.Down -f $perStream) -TimeoutMs 15000 -ReadWriteTimeoutMs 8000 -BypassProxy:$BypassProxy
                $s.Iar = $s.Req.BeginGetResponse($null, $null)
            } else {
                $s.Req = New-NsWebRequest -Uri $ep.Up -Method 'POST' -TimeoutMs 15000 -ReadWriteTimeoutMs 8000 -BypassProxy:$BypassProxy
                $s.Req.ContentType = 'application/octet-stream'
                # Without this .NET buffers the entire body in memory before
                # sending a byte, and the "upload time" measures a memcpy.
                $s.Req.AllowWriteStreamBuffering = $false
                $s.Req.SendChunked = $false
                $s.Req.ContentLength = $perStream
                $s.Iar = $s.Req.BeginGetRequestStream($null, $null)
            }
        } catch { $s.Req = $null }
        return $s
    }

    try {
        if ($Shared) { $Shared.Status = ('{0}Opening {1} streams...' -f $StatusPrefix, $Streams) }
        for ($i = 0; $i -lt $Streams; $i++) { $slots.Add((& $newSlot $i)) }

        # All N are already in flight; EndGet* just collects them in turn.
        foreach ($s in $slots) {
            if (-not $s.Req) { continue }
            try {
                if ($Direction -eq 'Down') {
                    $s.Resp = $s.Req.EndGetResponse($s.Iar)
                    if (-not $out.Meta) {
                        $m = Get-NsCfMeta -Response $s.Resp
                        $out.Meta = $m
                        $out.ServerTiming = [pscustomobject]@{ EdgeMs = $m.EdgeMs; WorkerMs = $m.WorkerMs; L4 = $m.L4 }
                    }
                    $s.Stream = $s.Resp.GetResponseStream()
                } else {
                    $s.Stream = $s.Req.EndGetRequestStream($s.Iar)
                }
                $s.Buf = New-Object byte[] $chunk
                $s.Live = $true
                $out.StreamsEstablished++
            } catch {
                $s.Live = $false
                if (-not $out.Reason) {
                    $he = Get-NsHttpErrorReason -Exception $_.Exception
                    $out.Reason = $he.Reason
                    if ($he.RateLimited) { $out.EndpointRefused = $true }
                }
            }
        }

        if ($out.StreamsEstablished -eq 0) {
            $out.State = 'failed'
            if (-not $out.Reason) { $out.Reason = 'No stream could be established to speed.cloudflare.com.' }
            return $out
        }

        # An upload only yields response headers when a POST finishes, and a
        # short run may never finish one. Fetch the edge metadata separately so
        # the section still reports which colo was measured and what the
        # server's own TCP stack saw.
        if ($Direction -eq 'Up' -and -not $out.Meta) {
            $m = Get-NsCfQuickMeta -BypassProxy:$BypassProxy
            if ($m) {
                $out.Meta = $m
                $out.ServerTiming = [pscustomobject]@{ EdgeMs = $m.EdgeMs; WorkerMs = $m.WorkerMs; L4 = $m.L4 }
            }
        }

        # ---- the loop -------------------------------------------------------
        $samples     = [Activator]::CreateInstance([System.Collections.Generic.List[double]])
        $windowStart = $sw.Elapsed.TotalMilliseconds
        $windowBytes = 0.0
        $lastProbe   = -9999.0
        $lastPush    = 0.0
        $totalBytes  = 0.0
        $warmBytes   = 0.0
        $rechunked   = $false

        while ($true) {
            $now = $sw.Elapsed.TotalMilliseconds
            if ($now -ge $deadlineMs) { break }
            if ($Shared -and $Shared.Cancel) { $out.Cancelled = $true; break }
            if ($totalBytes -ge $maxBytes) {
                $out.CapHit = ('Stopped at the {0} transfer cap for one run.' -f (Format-NsBytes $maxBytes))
                break
            }

            $moved = 0.0
            foreach ($s in $slots) {
                if (-not $s.Live) { continue }
                try {
                    if ($Direction -eq 'Down') {
                        $n = $s.Stream.Read($s.Buf, 0, $chunk)
                        if ($n -le 0) {
                            # Request satisfied before the clock ran out. Re-issue
                            # on the same keep-alive connection and keep counting;
                            # the byte count is not what bounds this test.
                            try { $s.Stream.Close() } catch {}
                            try { $s.Resp.Close() } catch {}
                            $fresh = & $newSlot $s.Id
                            if ($fresh.Req) {
                                try {
                                    $s.Resp   = $fresh.Req.EndGetResponse($fresh.Iar)
                                    $s.Req    = $fresh.Req
                                    $s.Stream = $s.Resp.GetResponseStream()
                                    $out.Restarts++
                                } catch { $s.Live = $false }
                            } else { $s.Live = $false }
                        } else {
                            $s.Bytes += $n; $moved += $n
                        }
                    } else {
                        $remaining = $s.Length - $s.Written
                        $take = $chunk
                        if ($remaining -lt $take) { $take = [int]$remaining }
                        if ($take -gt 0) {
                            $s.Stream.Write($sendBuf, 0, $take)
                            $s.Written += $take
                            $s.Bytes += $take; $moved += $take
                        }
                        if ($s.Written -ge $s.Length) {
                            try { $s.Stream.Close() } catch {}
                            try {
                                $r = $s.Req.GetResponse()
                                if (-not $out.Meta) {
                                    $m = Get-NsCfMeta -Response $r
                                    $out.Meta = $m
                                    $out.ServerTiming = [pscustomobject]@{ EdgeMs = $m.EdgeMs; WorkerMs = $m.WorkerMs; L4 = $m.L4 }
                                }
                                try { $r.Close() } catch {}
                            } catch {}
                            $fresh = & $newSlot $s.Id
                            if ($fresh.Req) {
                                try {
                                    $s.Stream  = $fresh.Req.EndGetRequestStream($fresh.Iar)
                                    $s.Req     = $fresh.Req
                                    $s.Written = 0L
                                    $out.Restarts++
                                } catch { $s.Live = $false }
                            } else { $s.Live = $false }
                        }
                    }
                } catch {
                    $s.Live = $false
                }
            }

            $totalBytes += $moved
            $windowBytes += $moved
            $now = $sw.Elapsed.TotalMilliseconds
            if ($now -lt $warmupMs) { $warmBytes += $moved }

            # Re-size the chunk from what the link ACTUALLY did during warm-up,
            # rather than trusting the pre-flight probe for the whole run.
            #
            # This matters in both directions. A probe that read low on a fast
            # link would leave an 8 KB chunk in place and force ~15,000 reads a
            # second, at which point the read loop itself becomes the
            # bottleneck and the tool measures its own overhead. A probe that
            # read high on a slow link leaves the chunk too coarse and inflates
            # individual windows. The warm-up is real traffic on the real link,
            # so it is a strictly better estimate - and it is already being
            # discarded, so using it costs nothing.
            if (-not $rechunked -and $now -ge $warmupMs -and $warmupMs -gt 0) {
                $rechunked = $true
                $obs = ($warmBytes * 8.0) / ($warmupMs / 1000.0) / 1000000.0
                if ($obs -gt 0) {
                    $newChunk = [int](($obs * 1000000.0 / 8.0) * $windowSec / 8.0)
                    if ($newChunk -lt 8192)   { $newChunk = 8192 }
                    if ($newChunk -gt 262144) { $newChunk = 262144 }
                    if ($Direction -eq 'Up' -and $newChunk -gt 65536) { $newChunk = 65536 }
                    if ($newChunk -ne $chunk) {
                        $chunk = $newChunk
                        if ($Direction -eq 'Up') {
                            $sendBuf = New-Object byte[] $chunk
                            (New-Object System.Random).NextBytes($sendBuf)
                        } else {
                            foreach ($s in $slots) { if ($s.Live) { $s.Buf = New-Object byte[] $chunk } }
                        }
                    }
                }
            }

            # Close the window
            if (($now - $windowStart) -ge $windowMs) {
                $span = ($now - $windowStart) / 1000.0
                if ($span -gt 0) {
                    $mbps = ($windowBytes * 8.0) / $span / 1000000.0
                    # Only windows that STARTED after warm-up count. TLS
                    # handshake, TCP slow start and CDN cache-fill make the
                    # first seconds unrepresentative of the link.
                    if ($windowStart -ge $warmupMs) { $samples.Add($mbps) }
                }
                $windowStart = $now
                $windowBytes = 0.0
            }

            # Latency interleave - this is what makes the figure a bufferbloat
            # measurement rather than two unrelated tests.
            if ($ProbeBag -and (($now - $lastProbe) -ge $ProbeIntervalMs)) {
                Send-NsProbes -Bag $ProbeBag -Stopwatch $sw
                $lastProbe = $now
            }
            if ($ProbeBag) { Receive-NsProbes -Bag $ProbeBag -Stopwatch $sw }

            if (($now - $lastPush) -ge 500) {
                $lastPush = $now
                if ($Shared) {
                    $secsIn = [math]::Round($now / 1000.0, 1)
                    $cur = 0.0
                    if ($samples.Count -gt 0) { $cur = $samples[$samples.Count - 1] }
                    $phase = 'measuring'
                    if ($now -lt $warmupMs) { $phase = 'warm-up (discarded)' }
                    $Shared.Status = ('{0}{1} {2} - {3}s, {4}' -f $StatusPrefix, $Direction, $phase, $secsIn, (Format-NsMbps $cur))
                    if ($VersionKey) { $Shared.$VersionKey = [int]$Shared.$VersionKey + 1 }
                }
            }

            if ($out.StreamsEstablished -gt 0) {
                $liveCount = @($slots | Where-Object { $_.Live }).Count
                if ($liveCount -eq 0) {
                    $out.Reason = 'All streams stopped before the measurement window closed.'
                    break
                }
            }
        }

        $out.MeasuredSec  = ($sw.Elapsed.TotalMilliseconds - $warmupMs) / 1000.0
        if ($out.MeasuredSec -lt 0) { $out.MeasuredSec = 0 }
        $out.TotalBytes    = $totalBytes
        $out.WarmupBytes   = $warmBytes
        $out.MeasuredBytes = $totalBytes - $warmBytes
        $out.Samples       = [double[]]@($samples)
        $out.PerStreamBytes = @($slots | ForEach-Object { [double]$_.Bytes })
        $out.Stats = Get-NsStats -Values $out.Samples
        if ($out.MeasuredSec -gt 0) {
            $out.OverallMbps = ($out.MeasuredBytes * 8.0) / $out.MeasuredSec / 1000000.0
        }
        # If the percentile has drifted well above the quantisation-immune
        # mean, the windows are bursty and the percentile is describing the
        # burst rather than the link. Say so on the row rather than quietly
        # publishing the higher number.
        if ($out.OverallMbps -gt 0 -and $out.Stats.P90 -gt ($out.OverallMbps * 1.25)) {
            $out.BurstyWindows = $true
        }

        # ---- refusal rules --------------------------------------------------
        # Publishing 340 Mbps off four samples is exactly the overclaiming this
        # tool exists not to do. A withheld number with a stated reason is more
        # use to a technician than a confident wrong one.
        if ($out.Cancelled) {
            $out.State  = 'refused'
            $out.Reason = 'Cancelled before the measurement window completed, so no figure is reported.'
        } elseif ($out.MeasuredSec -lt $lim.MinMeasureSec) {
            $out.State  = 'refused'
            $out.Reason = ('The measured window was only {0:N1}s (minimum {1}s), which is too short to characterise the link.' -f $out.MeasuredSec, $lim.MinMeasureSec)
        } elseif ($out.MeasuredBytes -le 0) {
            $out.State  = 'failed'
            $out.Reason = 'No data moved during the measurement window.'
        } elseif ($out.Samples.Count -lt $lim.MinSamples) {
            # Too few windows for a trustworthy percentile - but the SUSTAINED
            # rate is total bytes over total seconds and never divides by a
            # window, so it is unaffected and still worth reporting.
            #
            # This case is not hypothetical: on a saturated uplink each socket
            # write blocks until the send buffer drains, so loop iterations
            # stretch and fewer windows close. Refusing outright would make the
            # tool silent on exactly the links it exists to diagnose. So the
            # distribution is withheld and the throughput figure is kept.
            $out.Ok    = $true
            $out.State = 'measured'
            $out.PercentileWithheld = $true
            $out.Reason = ('Only {0} measurement windows closed (minimum {1} for a percentile), because the link stalled often enough to stretch them. The sustained figure is still valid - it is total bytes over total time and does not depend on windowing - but the median and spread are withheld.' -f $out.Samples.Count, $lim.MinSamples)
        } else {
            $out.Ok    = $true
            $out.State = 'measured'
        }
    } catch {
        $out.State  = 'failed'
        $out.Reason = $_.Exception.Message
    } finally {
        $sw.Stop()
        foreach ($s in $slots) {
            if ($s.Stream) { try { $s.Stream.Close() } catch {} }
            if ($s.Resp)   { try { $s.Resp.Close() }   catch {} }
            if ($s.Req)    { try { $s.Req.Abort() }    catch {} }
        }
    }
    return $out
}

function Test-NsThroughputCeiling {
    # The engine is single-threaded and TLS decrypt in PowerShell tops out well
    # below a gigabit link. Past the ceiling the honest output is a floor, not
    # a figure - and a pointer at the tool that can do better.
    param([double]$Mbps)
    $lim = Get-NsLimits
    return ($Mbps -ge $lim.EngineCeilingMbps)
}

function Format-NsThroughputResult {
    # The headline plus the two numbers that must always travel with it.
    #
    # p90 alone is a half-truth. A link reading p90 94 / p50 31 is not a
    # 94 Mbps link, and that gap IS the instability finding - more actionable
    # than either number on its own.
    param($Result)
    if (-not $Result -or -not $Result.Ok) { return '' }
    $s = $Result.Stats
    if ($Result.PercentileWithheld) {
        return ('{0} sustained  (distribution withheld - too few windows closed to support a percentile)' -f (Format-NsMbps $Result.OverallMbps))
    }
    if (Test-NsThroughputCeiling -Mbps $s.P90) {
        $lim = Get-NsLimits
        return ('>{0} Mbps (this tool''s ceiling - confirm with Ookla)' -f $lim.EngineCeilingMbps)
    }
    $txt = ('{0}  (median {1}, spread {2}, sustained {3})' -f `
            (Format-NsMbps $s.P90), (Format-NsMbps $s.P50), (Format-NsMbps $s.Spread), (Format-NsMbps $Result.OverallMbps))
    if ($Result.BurstyWindows) {
        $txt = ('{0} - bursty, trust the sustained figure' -f $txt)
    }
    return $txt
}

# ===========================================================================
#  Latency under load (bufferbloat)
#
#  This is the measurement that explains most "the internet feels slow"
#  tickets where the Mbps figure looks fine. A link whose latency collapses
#  from 20 ms to 400 ms the moment anyone uploads a file will make Teams
#  stutter and web pages hang, at any bandwidth.
#
#  THE GRADE IS ON THE INCREASE, NEVER THE ABSOLUTE. A 250 ms satellite link
#  that gains 5 ms under load is not bufferbloated; a 12 ms fibre link that
#  gains 600 ms is catastrophic. Grading absolutes would invert both calls.
#
#  Three probe targets, because each answers a different question and any one
#  of them alone can be misread:
#
#    gateway  - is the queue inside the building (this NIC, the Wi-Fi, the
#               switch), or is the CPE itself too busy to answer?
#    1.1.1.1  - is the queue on the WAN uplink, which is the classic case?
#    HTTP     - the same question over a real TCP/443 flow. Many routers
#               deprioritise or rate-limit ICMP, so an ICMP-only bufferbloat
#               test has a structural blind spot. This closes it.
# ===========================================================================

function Get-NsBufferbloatGrade {
    # DSLReports' scale, cited as such rather than presented as our own.
    param([double]$IncreaseMs)
    if ($IncreaseMs -lt 5)   { return 'A+' }
    if ($IncreaseMs -lt 30)  { return 'A' }
    if ($IncreaseMs -lt 60)  { return 'B' }
    if ($IncreaseMs -lt 200) { return 'C' }
    if ($IncreaseMs -lt 400) { return 'D' }
    return 'F'
}

function Measure-NsIdleLatency {
    # Baseline with nothing running. Everything else is measured against this,
    # so if this phase is unusable the whole section has to be refused.
    param(
        [string[]]$IcmpTargets,
        [string]$HttpUrl = '',
        [double]$Seconds = 5.0,
        [double]$IntervalMs = 200,
        $Shared = $null,
        [switch]$BypassProxy,
        [string]$StatusPrefix = ''
    )
    $bag = New-NsProbeBag -IcmpTargets $IcmpTargets -HttpUrl $HttpUrl -BypassProxy:$BypassProxy
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $last = -9999.0
    while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
        if ($Shared -and $Shared.Cancel) { break }
        $now = $sw.Elapsed.TotalMilliseconds
        if (($now - $last) -ge $IntervalMs) {
            Send-NsProbes -Bag $bag -Stopwatch $sw
            $last = $now
        }
        Receive-NsProbes -Bag $bag -Stopwatch $sw
        if ($Shared) {
            $Shared.Status = ('{0}Idle latency baseline - {1:N1}s of {2:N0}s' -f $StatusPrefix, $sw.Elapsed.TotalSeconds, $Seconds)
        }
        Start-Sleep -Milliseconds 20
    }
    Close-NsProbeBag -Bag $bag -Stopwatch $sw
    $sw.Stop()
    return (Get-NsProbeSummary -Bag $bag)
}

function Get-NsLoadedProbeDiagnosis {
    # WHY were there no usable probes during the loaded phase?
    #
    # "No latency probes survived" is true but blames the wrong thing. It sends
    # a technician to look at latency when the actual cause is almost always one
    # of three quite different situations, only one of which is about probing:
    #
    #   1. the throughput test never moved any data, so there was no loaded
    #      phase to probe during. The bufferbloat result is a CONSEQUENCE of
    #      that failure, not an independent finding.
    #   2. the transfer ran but was over too quickly to fire enough probes.
    #   3. probes were fired and went unanswered. That is itself a finding -
    #      ICMP is commonly deprioritised or dropped once a link saturates -
    #      but it means the increase cannot be quantified.
    #
    # Reporting all three as the same sentence is how a broken speed test gets
    # mistaken for a latency problem.
    param($Down, $Up, $LoadedDown, $LoadedUp, [string]$RefKey = '1.1.1.1', [int]$MinSamples = 5)
    $out = [pscustomobject]@{ Cause = 'unknown'; Reason = ''; Sent = 0; Answered = 0; LoadedSec = 0.0 }

    $sent = 0; $ans = 0
    foreach ($sum in @($LoadedDown, $LoadedUp)) {
        if ($sum -and $sum.ContainsKey($RefKey)) {
            $sent += [int]$sum[$RefKey].sent
            $ans  += [int]$sum[$RefKey].n
        }
    }
    $out.Sent = $sent; $out.Answered = $ans

    $secs = 0.0; $moved = $false; $failReasons = [Activator]::CreateInstance([System.Collections.Generic.List[string]])
    foreach ($t in @(@{ R = $Down; N = 'download' }, @{ R = $Up; N = 'upload' })) {
        if (-not $t.R) { continue }
        if ($t.R.Ok) { $moved = $true; $secs += [double]$t.R.MeasuredSec }
        elseif ($t.R.Reason) { $failReasons.Add(('{0}: {1}' -f $t.N, $t.R.Reason)) }
    }
    $out.LoadedSec = [math]::Round($secs, 1)

    if (-not $moved) {
        $out.Cause = 'no-load'
        $why = ''
        if (@($failReasons).Count -gt 0) { $why = (' The transfer failed because - ' + (@($failReasons) -join '; ') + '.') }
        $out.Reason = ('No load was ever applied to the link, because the throughput test itself did not move any data.{0} There was no loaded phase to measure latency during, so this is a CONSEQUENCE of that failure and not a separate fault - fix the throughput failure and this resolves with it.' -f $why)
    } elseif ($sent -gt 0 -and $ans -lt $MinSamples -and (($sent - $ans) -ge ($sent / 2))) {
        $out.Cause = 'probes-unanswered'
        $out.Reason = ('{0} of {1} latency probes went unanswered while the link was loaded. That is itself consistent with a badly congested link - ICMP is commonly deprioritised or dropped once a link saturates - but it leaves nothing to measure the increase from, so no grade is given rather than a flattering one.' -f ($sent - $ans), $sent)
    } elseif ($secs -gt 0 -and $sent -lt $MinSamples) {
        $out.Cause = 'too-short'
        $out.Reason = ('The loaded phase lasted only {0:N1}s and fired {1} probe(s), fewer than the {2} needed. The transfer finished or was capped before enough samples could be taken - re-run with a longer measurement window.' -f $secs, $sent, $MinSamples)
    } else {
        $out.Cause = 'insufficient'
        $out.Reason = ('Only {0} of {1} latency probes returned during the loaded phases, fewer than the {2} needed to state an increase.' -f $ans, $sent, $MinSamples)
    }
    return $out
}

function Get-NsQueueLocation {
    # Where the queue actually is, in words, from the differential between the
    # three probes. This is the part a technician can act on: "enable SQM on
    # the router" and "stop using the 2.4 GHz radio" are different jobs.
    param($Idle, $Loaded, [string]$GatewayKey, $Diagnosis = $null)
    # When the caller already worked out WHY there is no loaded data, say that
    # instead of the generic line - the two messages otherwise appear together
    # and neither one names the actual cause.
    $noData = 'Not enough probe data to say where the delay is being added.'
    if ($Diagnosis -and $Diagnosis.Reason) { $noData = ('Where the delay is being added cannot be determined. {0}' -f $Diagnosis.Reason) }
    $out = [pscustomobject]@{
        Location = 'indeterminate'
        Summary  = $noData
        GwIncreaseMs = $null; WanIncreaseMs = $null; HttpIncreaseMs = $null
        GatewayProbeUsable = $true
        GatewayProbeNote   = ''
        State              = 'measured'
    }

    # If the grade was refused, STOP. Everything below derives a location from
    # the differential between idle and loaded latency, and a refusal means one
    # of those is not trustworthy. Previously a diagnosis only changed the
    # default summary text and the analysis ran on regardless, so the tool
    # could say "the baseline is not usable" and then, from that same baseline,
    # "this is classic bufferbloat, enable SQM on the router" - a change to a
    # customer's router recommended off data it had just disowned.
    if ($Diagnosis) {
        $out.State = 'refused'
        return $out
    }

    # Is the gateway probe capable of telling us anything about the LOCAL
    # segment at all?
    #
    # The whole gateway-versus-internet comparison assumes a ping to the
    # default gateway is dominated by the local hop. That assumption fails on
    # any router that answers ICMP to its own address slowly - and many do,
    # because replying to a ping is a control-plane job that gets scheduled
    # behind forwarding. Measured on the machine this was written on, the
    # gateway answered in 29.7 ms while 1.1.1.1 answered in
    # 29.5 ms, so the gateway figure carried no local information whatever.
    #
    # Read naively, that reads as "the gateway rose as much as the internet,
    # therefore the queue is local" - the exact opposite of the truth. So the
    # probe is disqualified up front when its IDLE latency is already too high
    # to be a LAN hop, and the tool says so rather than guessing.
    if ($GatewayKey -and $Idle.ContainsKey($GatewayKey) -and $Idle[$GatewayKey].n -ge 5) {
        $gwIdle = [double]$Idle[$GatewayKey].p50Ms
        if ($gwIdle -gt 10) {
            $out.GatewayProbeUsable = $false
            $out.GatewayProbeNote = ('The gateway answered ping in {0} ms even when idle, which is far too slow to be a LAN hop. That means it deprioritises ICMP to itself, so the gateway probe cannot be used to separate a local queue from an uplink queue on this site.' -f $gwIdle)
        }
    } elseif ($GatewayKey) {
        $out.GatewayProbeUsable = $false
        $out.GatewayProbeNote = 'The gateway did not answer enough pings to be used as a reference.'
    }

    $inc = {
        param($key)
        if (-not $key) { return $null }
        if (-not $Idle.ContainsKey($key) -or -not $Loaded.ContainsKey($key)) { return $null }
        if ($Idle[$key].n -lt 5 -or $Loaded[$key].n -lt 5) { return $null }
        return ([double]$Loaded[$key].p50Ms - [double]$Idle[$key].p50Ms)
    }
    $gw   = & $inc $GatewayKey
    $wan  = & $inc '1.1.1.1'
    $http = & $inc 'http'
    $out.GwIncreaseMs   = $gw
    $out.WanIncreaseMs  = $wan
    $out.HttpIncreaseMs = $http

    if ($null -eq $wan -and $null -eq $http) { return $out }

    # ICMP being deprioritised is checked FIRST, because if it is true then
    # every ICMP-derived conclusion below is unsafe.
    #
    # But the HTTP probe is polled, so part of its rise under load is this
    # tool's own loop being busy. Firing this branch on that noise would
    # accuse the customer's router of something it is not doing, so the HTTP
    # increase has to clear the measured noise floor by a wide margin - three
    # times, matching the resolution rule used elsewhere - before it is
    # allowed to overrule the ICMP evidence.
    $httpUsable = $false
    $httpNoise = 0.0
    if ($Loaded.ContainsKey('http')) {
        if ($null -ne $Loaded['http'].noiseFloorMs) { $httpNoise = [double]$Loaded['http'].noiseFloorMs }
        if ($null -ne $Loaded['http'].usable)       { $httpUsable = [bool]$Loaded['http'].usable }
    }
    if ($httpUsable -and $null -ne $http -and $http -gt 60 -and $http -gt ($httpNoise * 3)) {
        $icmpQuiet = (($null -eq $wan) -or ($wan -lt ($http * 0.4)))
        if ($icmpQuiet) {
            $out.Location = 'icmp-deprioritised'
            $out.Summary  = 'Real TCP traffic slows under load but ICMP does not, so this router is deprioritising or rate-limiting ping. The ping-based figures understate what users actually experience - trust the HTTP probe here.'
            return $out
        }
    }
    if ($null -eq $wan) { return $out }

    if ($wan -lt 30) {
        $out.Location = 'none'
        $out.Summary  = 'Latency barely moves under load. There is no meaningful queue on this path.'
        return $out
    }

    # Without a usable gateway reference the two cases cannot be separated.
    # Naming the queue anyway would be a coin toss dressed up as a diagnosis.
    if (-not $out.GatewayProbeUsable) {
        $out.Location = 'queue-present-location-unknown'
        $out.Summary  = ('Latency climbs by around {0} ms under load, so there is definitely a queue - but this site''s gateway cannot be used as a reference, so the tool will not say whether it sits inside the building or on the uplink. {1} To narrow it down, re-run from a machine wired directly to the router.' -f [math]::Round($wan, 0), $out.GatewayProbeNote)
        return $out
    }

    if ($null -ne $gw -and $gw -ge ($wan * 0.5) -and $gw -gt 30) {
        $out.Location = 'local'
        $out.Summary  = 'The delay appears on the hop to the gateway itself, so the queue is inside the building - this PC''s adapter, the Wi-Fi, or the switch - rather than on the internet uplink.'
        return $out
    }
    $out.Location = 'wan-uplink'
    $out.Summary  = 'Latency to the internet climbs under load while the hop to the gateway stays flat, which puts the queue in the router''s outbound buffer on the WAN uplink. This is classic bufferbloat, and the fix is smart queue management (SQM/QoS) on the router.'
    return $out
}

# ===========================================================================
#  Link throughput sampling
#
#  GetIPv4Statistics() on a cached NetworkInterface object was measured at
#  143 ms for the first call and 0 ms for all eight adapters thereafter, which
#  is what makes a 1 Hz live monitor possible at all. The alternatives were
#  both rejected on measurement: Get-NetAdapterStatistics costs 53 ms warm
#  (usable, but only as an occasional cross-check) and
#  Win32_PerfRawData_Tcpip_NetworkInterface costs 5040 ms, which is not usable
#  for anything.
# ===========================================================================

function Get-NsNetInterfaceRef {
    # The .NET NetworkInterface matching a Windows interface index. Matched on
    # GUID first because names and descriptions are neither unique nor stable.
    param([int]$InterfaceIndex)
    $guid = ''; $desc = ''
    try {
        $a = Get-NetAdapter -InterfaceIndex $InterfaceIndex -ErrorAction Stop | Select-Object -First 1
        if ($a) { $guid = [string]$a.InterfaceGuid; $desc = [string]$a.InterfaceDescription }
    } catch {}
    $all = @()
    try { $all = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() } catch { return $null }
    if ($guid) {
        foreach ($ni in $all) { if ($ni.Id -eq $guid) { return $ni } }
    }
    if ($desc) {
        foreach ($ni in $all) { if ($ni.Description -eq $desc) { return $ni } }
    }
    return $null
}

function Get-NsInterfaceCounters {
    # One instantaneous counter snapshot. Deliberately does no arithmetic -
    # deltas and wrap correction are Measure-CounterDelta's job.
    param($NetInterface)
    $out = [pscustomobject]@{
        Ok = $false; AtMs = 0.0
        BytesReceived = 0.0; BytesSent = 0.0
        InErrors = 0.0; OutDiscards = 0.0
        InDiscards = 0.0; OutErrors = 0.0
    }
    if ($null -eq $NetInterface) { return $out }
    try {
        $s = $NetInterface.GetIPv4Statistics()
        $out.BytesReceived = [double]$s.BytesReceived
        $out.BytesSent     = [double]$s.BytesSent
        $out.InErrors      = [double]$s.IncomingPacketsWithErrors
        $out.OutDiscards   = [double]$s.OutgoingPacketsDiscarded
        $out.InDiscards    = [double]$s.IncomingPacketsDiscarded
        $out.OutErrors     = [double]$s.OutgoingPacketsWithErrors
        $out.AtMs = [double]([System.Diagnostics.Stopwatch]::GetTimestamp() / [System.Diagnostics.Stopwatch]::Frequency * 1000.0)
        $out.Ok = $true
    } catch {}
    return $out
}

function Measure-NsLinkThroughput {
    # Actual bytes moving on the wire over a short window. This is the only
    # figure in the hog section that is a measurement rather than an
    # inference - it says HOW MUCH is moving, but nothing about by whom.
    param(
        [int]$InterfaceIndex,
        [double]$Seconds = 3.0,
        [double]$LinkSpeedMbps = 0,
        $Shared = $null
    )
    $out = [pscustomobject]@{
        Ok = $false; DownMbps = 0.0; UpMbps = 0.0
        InErrors = 0.0; OutDiscards = 0.0
        Seconds = 0.0; Detail = ''
    }
    $ni = Get-NsNetInterfaceRef -InterfaceIndex $InterfaceIndex
    if (-not $ni) { $out.Detail = 'No .NET interface matched this adapter.'; return $out }
    $a = Get-NsInterfaceCounters -NetInterface $ni
    if (-not $a.Ok) { $out.Detail = 'Interface counters unavailable.'; return $out }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
        if ($Shared -and $Shared.Cancel) { break }
        Start-Sleep -Milliseconds 100
    }
    $sw.Stop()
    $b = Get-NsInterfaceCounters -NetInterface $ni
    if (-not $b.Ok) { $out.Detail = 'Interface counters unavailable on the second read.'; return $out }
    $span = $sw.Elapsed.TotalSeconds
    if ($span -le 0) { $out.Detail = 'Zero-length sample.'; return $out }
    $dRx = Measure-CounterDelta -Previous $a.BytesReceived -Current $b.BytesReceived -IntervalSec $span -LinkSpeedMbps $LinkSpeedMbps
    $dTx = Measure-CounterDelta -Previous $a.BytesSent     -Current $b.BytesSent     -IntervalSec $span -LinkSpeedMbps $LinkSpeedMbps
    if (-not $dRx.Valid -or -not $dTx.Valid) {
        $out.Detail = 'Counter reset during the sample, so it was discarded.'
        return $out
    }
    $out.DownMbps    = ($dRx.Bytes * 8.0) / $span / 1000000.0
    $out.UpMbps      = ($dTx.Bytes * 8.0) / $span / 1000000.0
    $out.InErrors    = $b.InErrors - $a.InErrors
    $out.OutDiscards = $b.OutDiscards - $a.OutDiscards
    $out.Seconds     = $span
    $out.Ok = $true
    return $out
}

# ===========================================================================
#  Bandwidth hogs - inference tier
#
#  Windows has no per-process byte counter. Resource Monitor gets its figures
#  from an ETW session, which is what the deep-capture stage does. Everything
#  here is therefore INFERENCE, and every row says so - a process with eight
#  external connections is a suspect, not a culprit.
#
#  What saves this from being guesswork is that the two heaviest offenders in
#  practice - Delivery Optimization and BITS - both expose real byte counters,
#  so those rows are measurements and are labelled differently.
# ===========================================================================

function Test-NsPrivateAddress {
    # RFC1918 / loopback / link-local / CGNAT / multicast, v4 and v6.
    #
    # Connections to these are LAN traffic and must not be counted as internet
    # bandwidth. The naive filter in most scripts misses IPv6 entirely, which
    # on a modern network is most of the connection table.
    param([string]$Address)
    if ([string]::IsNullOrWhiteSpace($Address)) { return $true }
    $a = $Address
    if ($a.Contains('%')) { $a = $a.Split('%')[0] }
    if ($a -eq '::' -or $a -eq '::1' -or $a -eq '0.0.0.0') { return $true }
    if ($a -match '^127\.')                     { return $true }
    if ($a -match '^10\.')                      { return $true }
    if ($a -match '^192\.168\.')                { return $true }
    if ($a -match '^172\.(1[6-9]|2[0-9]|3[01])\.') { return $true }
    if ($a -match '^169\.254\.')                { return $true }   # link-local
    if ($a -match '^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.') { return $true }  # CGNAT
    if ($a -match '^22[4-9]\.|^23[0-9]\.')      { return $true }   # multicast
    if ($a -match '^(?i)fe[89ab][0-9a-f]:')     { return $true }   # IPv6 link-local
    if ($a -match '^(?i)f[cd][0-9a-f]{2}:')     { return $true }   # IPv6 ULA
    if ($a -match '^(?i)ff[0-9a-f]{2}:')        { return $true }   # IPv6 multicast
    return $false
}

function Get-NsProcessClass {
    # What kind of thing this is, so the report can group suspects by the
    # question a technician actually asks: "is this something I can pause?"
    param([string]$Name, [string]$Path, [string]$Services = '')
    # The service list is folded in DELIBERATELY - dosvc, usosvc and wuauserv
    # are service names, not executables, so Windows Update is only detectable
    # this way. The cost is that every token is matched against a long
    # arbitrary string, so the short generic ones carry a LEADING \b: without
    # it 'eset' hit "preset", 'cove' hit "recovery" and 'riot' hit "patriot",
    # all three confirmed. Leading-only, not \b...\b, so product variants like
    # eset_nod32 and covebackup still match - '_' is a word character, so a
    # trailing \b would have broken exactly the detections these tokens exist
    # for.
    $n = ('{0} {1}' -f $Name, $Services).ToLower()
    $p = ([string]$Path).ToLower()
    if ($n -match 'dosvc|usosvc|wuauserv|tiworker|wuauclt|mousocore') { return 'windows-update' }
    if ($n -match 'officec2r|officeclicktorun')                       { return 'office-update' }
    if ($n -match 'onedrive')                                         { return 'file-sync' }
    if ($n -match 'dropbox|googledrive|drivefs|box(sync|drive)|egnyte|sharepoint') { return 'file-sync' }
    if ($n -match 'ms-teams|\bteams\b|\blync\b|zoom|webex|slack|discord') { return 'collaboration' }
    if ($n -match 'chrome|msedge|firefox|opera|brave|iexplore')        { return 'browser' }
    if ($n -match 'outlook|thunderbird')                              { return 'mail' }
    # Datto ships an RMM agent AND a backup agent, and 'datto' was in both this
    # line and the backup line below. First match wins, so every Datto backup
    # agent reported as remote-access software - sending a technician to look
    # at remote support while a backup ate the link. The RMM side is matched by
    # its real executables; a bare 'datto' now falls through to backup, because
    # for a BANDWIDTH classifier the backup product is the one that saturates.
    if ($n -match 'ateraagent|screenconnect|teamviewer|logmein|splashtop|srmanager|ninjarmm|dattormm|aemagent|cagservice|connectwise|anydesk') { return 'rmm-remote' }
    if ($n -match 'sentinel|cylance|csfalcon|crowdstrike|msmpeng|mssense|defender|sophos|webroot|bitdefender|\beset') { return 'security' }
    if ($n -match 'backup|acronis|veeam|shadowprotect|carbonite|idrive|\bcove|datto') { return 'backup' }
    if ($n -match 'steam|epicgames|battle\.net|\borigin|\briot')        { return 'games' }
    if ($n -match 'spotify|itunes|netflix|\bvlc')                     { return 'media' }
    if ($p -match '\\windows\\system32\\svchost')                     { return 'windows-service' }
    return 'other'
}

function Get-NsExternalTcpByProcess {
    # Established TCP connections to addresses outside this network, grouped by
    # the process that owns them.
    #
    # Measured cost: 1791 ms cold, 252 ms warm. Fine for a one-shot scan, far
    # too heavy to run at 1 Hz - the live monitor calls it every third second
    # for exactly that reason.
    param([switch]$IncludeServices)
    $out = [pscustomobject]@{ Ok = $false; Processes = @(); Total = 0; Detail = '' }
    $conns = @()
    try {
        $conns = @(Get-NetTCPConnection -State Established -ErrorAction Stop)
    } catch {
        $out.Detail = ('Could not read the TCP connection table: {0}' -f $_.Exception.Message)
        return $out
    }
    $ext = @($conns | Where-Object { -not (Test-NsPrivateAddress -Address ([string]$_.RemoteAddress)) })
    $out.Total = $ext.Count

    $svcMap = @{}
    if ($IncludeServices) {
        # Names the svchost instances, which is the difference between
        # "svchost is using the link" and "Delivery Optimization is".
        try {
            foreach ($s in @(Get-CimInstance Win32_Service -Filter 'State="Running"' -OperationTimeoutSec 20 -ErrorAction Stop)) {
                if ($s.ProcessId -gt 0) {
                    if (-not $svcMap.ContainsKey([int]$s.ProcessId)) { $svcMap[[int]$s.ProcessId] = [Activator]::CreateInstance([System.Collections.Generic.List[string]]) }
                    [void]$svcMap[[int]$s.ProcessId].Add([string]$s.Name)
                }
            }
        } catch {}
    }

    $rows = [Activator]::CreateInstance([System.Collections.Generic.List[object]])
    foreach ($g in @($ext | Group-Object -Property OwningProcess)) {
        $procId = 0
        try { $procId = [int]$g.Name } catch { continue }
        $pname = ''; $ppath = ''
        try {
            $pr = Get-Process -Id $procId -ErrorAction Stop
            $pname = $pr.ProcessName
            try { $ppath = $pr.Path } catch { $ppath = '' }
        } catch {
            # A PID that vanished between the two calls, or one this session
            # cannot open. Both are normal; neither is a finding.
            $pname = '(exited or not accessible)'
        }
        $svcs = ''
        if ($svcMap.ContainsKey($procId)) { $svcs = (($svcMap[$procId] | Sort-Object) -join ', ') }
        $remotes = @($g.Group | ForEach-Object { ('{0}:{1}' -f $_.RemoteAddress, $_.RemotePort) } | Select-Object -Unique)
        $top = @($remotes | Select-Object -First 3)
        $rows.Add([pscustomobject]@{
            pid            = $procId
            name           = $pname
            path           = $ppath
            services       = $svcs
            externalConns  = $g.Count
            topRemotes     = [object[]]$top
            classification = (Get-NsProcessClass -Name $pname -Path $ppath -Services $svcs)
            bytes          = $null
            basis          = 'inference'
            note           = 'Connection count only. This tool cannot attribute bytes to a process without the ETW deep capture.'
        })
    }
    $out.Processes = @($rows | Sort-Object -Property externalConns -Descending)
    $out.Ok = $true
    return $out
}

function Get-NsDeliveryOptimization {
    # Real byte counters, so these rows are measurements, not inference.
    #
    # In practice this is the single most common answer to "why is the
    # internet slow" on a managed fleet: Windows Update and Office pulling
    # hundreds of megabytes in the background at Background priority, which
    # still saturates a small link.
    param()
    # NOTE ON WHAT THESE NUMBERS MEAN. Get-DeliveryOptimizationStatus returns
    # every job DO still knows about, including ones that finished hours ago,
    # and its byte counters are CUMULATIVE. Measured on the development
    # machine: 26 jobs and 540 MB "from HTTP", against an actual current rate
    # of 48 kbps. Reporting that as a live bandwidth hog would be flatly
    # wrong, so in-progress jobs are counted separately from history, and the
    # only figure presented as "now" is DownlinkBps.
    $out = [pscustomobject]@{
        State = 'unsupported'; Reason = ''
        ActiveJobs = 0; TotalJobs = 0
        ActiveRemainingBytes = 0.0
        TotalBytes = 0.0; CachedBytes = 0.0
        FromHttp = 0.0; FromLanPeers = 0.0; ToLanPeers = 0.0
        DownlinkBps = $null; Jobs = @(); Detail = ''
    }
    if (-not (Get-Command Get-DeliveryOptimizationStatus -ErrorAction SilentlyContinue)) {
        $out.Reason = 'The DeliveryOptimization module is not present on this build of Windows.'
        return $out
    }
    try {
        $st = @(Get-DeliveryOptimizationStatus -ErrorAction Stop)
        $jobs = [Activator]::CreateInstance([System.Collections.Generic.List[object]])
        foreach ($j in $st) {
            $size = [double]$j.FileSize
            $got  = [double]$j.TotalBytesDownloaded
            $out.TotalBytes   += $size
            $out.CachedBytes  += $got
            $out.FromHttp     += [double]$j.BytesFromHttp
            $out.FromLanPeers += [double]$j.BytesFromLanPeers
            $out.ToLanPeers   += [double]$j.BytesToLanPeers
            # In progress = the job still has bytes to fetch and has not been
            # parked. Anything else is history and must not be presented as
            # current consumption.
            $active = (($size -gt 0) -and ($got -lt $size) -and ([string]$j.Status -notmatch 'Complete|Caching Paused|Failed'))
            if ($active) {
                $out.ActiveJobs++
                $out.ActiveRemainingBytes += ($size - $got)
            }
            $jobs.Add([pscustomobject]@{
                caller       = [string]$j.PredefinedCallerApplication
                status       = [string]$j.Status
                priority     = [string]$j.Priority
                fileSize     = $size
                downloaded   = $got
                # [double]0, not 0. PowerShell picks the [math]::Max overload
                # from the FIRST argument, so a bare 0 selects Max(int,int) and
                # then fails converting the second - "Value was either too large
                # or too small for an Int32" - for anything over 2.1 GB. Which
                # is precisely the case this section exists to catch: a Windows
                # Update backlog big enough to matter. Seen live at 2,456,441,936
                # bytes pending.
                remaining    = [math]::Max([double]0, ($size - $got))
                inProgress   = $active
                peerPct      = [math]::Round([double]$j.PercentPeerCaching, 1)
                downloadMode = [string]$j.DownloadMode
            })
        }
        $out.TotalJobs = $st.Count
        $out.Jobs = [object[]]@($jobs | Sort-Object -Property @{ E = { -not $_.inProgress } }, @{ E = { $_.remaining }; Descending = $true } | Select-Object -First 12)
        $out.State = 'measured'
    } catch {
        $out.State  = 'failed'
        $out.Reason = $_.Exception.Message
        return $out
    }
    try {
        $snap = Get-DeliveryOptimizationPerfSnap -ErrorAction Stop | Select-Object -First 1
        if ($snap -and $null -ne $snap.DownlinkBps) { $out.DownlinkBps = [double]$snap.DownlinkBps }
    } catch {}
    return $out
}

function Get-NsBitsJobs {
    param()
    $out = [pscustomobject]@{
        State = 'unsupported'; Reason = ''
        TransferringJobs = 0; TotalJobs = 0; RemainingBytes = 0.0; Jobs = @()
        Caveat = ''
    }
    if (-not (Get-Command Get-BitsTransfer -ErrorAction SilentlyContinue)) {
        $out.Reason = 'The BitsTransfer module is not available in this session.'
        return $out
    }
    $elevated = Test-NsElevated
    if (-not $elevated) {
        $out.Caveat = 'Not elevated, so only this account''s BITS jobs are visible. A background job owned by SYSTEM or another user would not appear here.'
    }
    try {
        $jobs = @()
        if ($elevated) { $jobs = @(Get-BitsTransfer -AllUsers -ErrorAction Stop) }
        else           { $jobs = @(Get-BitsTransfer -ErrorAction Stop) }
        $list = [Activator]::CreateInstance([System.Collections.Generic.List[object]])
        foreach ($j in $jobs) {
            $remaining = [double]$j.BytesTotal - [double]$j.BytesTransferred
            if ($remaining -lt 0) { $remaining = 0 }
            if ([string]$j.JobState -match 'Transferring|Connecting|Queued') {
                $out.TransferringJobs++
                $out.RemainingBytes += $remaining
            }
            $list.Add([pscustomobject]@{
                displayName = [string]$j.DisplayName
                state       = [string]$j.JobState
                owner       = [string]$j.OwnerAccount
                priority    = [string]$j.Priority
                total       = [double]$j.BytesTotal
                transferred = [double]$j.BytesTransferred
            })
        }
        $out.TotalJobs = $jobs.Count
        $out.Jobs = [object[]]@($list | Sort-Object -Property total -Descending | Select-Object -First 12)
        $out.State = 'measured'
    } catch {
        $out.State  = 'failed'
        $out.Reason = $_.Exception.Message
    }
    return $out
}

function Get-NsHogs {
    # The whole inference tier in one call.
    param(
        [int]$InterfaceIndex,
        [double]$LinkSpeedMbps = 0,
        [double]$SampleSec = 3.0,
        $Shared = $null,
        [int]$SelfPid = 0
    )
    if ($SelfPid -le 0) { $SelfPid = $PID }
    if ($Shared) { $Shared.Status = 'Sampling link throughput...' }
    $link = Measure-NsLinkThroughput -InterfaceIndex $InterfaceIndex -Seconds $SampleSec -LinkSpeedMbps $LinkSpeedMbps -Shared $Shared
    if ($Shared) { $Shared.Status = 'Reading connection table...' }
    $tcp  = Get-NsExternalTcpByProcess -IncludeServices
    if ($Shared) { $Shared.Status = 'Reading Delivery Optimization counters...' }
    $do   = Get-NsDeliveryOptimization
    if ($Shared) { $Shared.Status = 'Reading BITS jobs...' }
    $bits = Get-NsBitsJobs
    [pscustomobject]@{
        Link    = $link
        Tcp     = $tcp
        DO      = $do
        Bits    = $bits
        SelfPid = $SelfPid
    }
}

# ===========================================================================
#  Wireless
#
#  Everything here comes from netsh, which prints LOCALISED labels. Parsing
#  those labels by their English text is the standard approach and it fails
#  silently on a German or French machine: the regex misses, the field reads
#  empty, and the tool reports "no wireless" on a laptop that is plainly on
#  Wi-Fi. So a failure to recognise the output is reported as UNSUPPORTED
#  with the reason, never as an absence of Wi-Fi.
#
#  NOT TESTED ON REAL HARDWARE. The machine this was developed on has no
#  wireless interface, so only the unsupported path has been exercised. This
#  must be validated on a laptop before the Wi-Fi tab is trusted.
# ===========================================================================

function ConvertFrom-NsNetshPairs {
    # netsh prints "Label : value" blocks. Returns an ordered list of pairs
    # rather than a hashtable, because "show networks" repeats keys per BSSID.
    param([string[]]$Lines)
    $out = [Activator]::CreateInstance([System.Collections.Generic.List[object]])
    foreach ($ln in $Lines) {
        if ($null -eq $ln) { continue }
        $m = [regex]::Match($ln, '^\s*([^:]+?)\s*:\s*(.*?)\s*$')
        if ($m.Success) {
            $out.Add([pscustomobject]@{
                Key    = $m.Groups[1].Value.Trim()
                Value  = $m.Groups[2].Value.Trim()
                Indent = ($ln.Length - $ln.TrimStart().Length)
            })
        }
    }
    return $out
}

function Get-NsWifiBand {
    # Band from the channel number. Windows only reports a Band field on newer
    # builds, so it is preferred when present and this is the fallback.
    #
    # 6 GHz reuses channel numbers 1-233, which collide with 2.4 GHz. That
    # ambiguity is real and is reported as unknown rather than guessed.
    param([int]$Channel, [string]$RadioType = '')
    if ($Channel -le 0) { return '' }
    if ($Channel -ge 36 -and $Channel -le 177) { return '5 GHz' }
    if ($Channel -le 14) {
        if ($RadioType -match '802\.11be|802\.11ax') { return '2.4 GHz or 6 GHz (channel number is ambiguous on this radio)' }
        return '2.4 GHz'
    }
    return ''
}

function Get-NsWifi {
    # Radio state, negotiated rate, and what else is on the same channel.
    param([switch]$IncludeScan)
    $out = [pscustomobject]@{
        State = 'unsupported'; Reason = ''
        Interface = $null
        Neighbours = @()
        CoChannelCount = 0
        # 0 co-channel APs and "we never looked" are different facts. Without
        # this the row was simply absent and the subscore branch that reads
        # CoChannelCount was silently dead in any run without -IncludeScan.
        Scanned = $false
        SameSsidBetterBss = @()
        Findings = @()
    }
    $raw = $null
    try {
        $raw = & netsh.exe wlan show interfaces 2>&1
    } catch {
        $out.Reason = 'netsh could not be run in this session.'
        return $out
    }
    $text = ($raw | Out-String)
    # Decide from the SERVICE and the adapter inventory, not by grepping the
    # blob. 'not running' was matched against the entire multi-interface
    # output including SSID and profile names, so one network called e.g.
    # "Warehouse - not running" suppressed Wi-Fi analysis for the whole
    # machine and reported it as having no radio at all.
    $hasRadio = $false
    try { $hasRadio = @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.PhysicalMediaType -match '802\.11' }).Count -gt 0 } catch { }
    $svcRunning = $true
    try {
        $svc = Get-Service -Name 'WlanSvc' -ErrorAction Stop
        $svcRunning = ($svc.Status -eq 'Running')
    } catch { $svcRunning = $false }
    if (-not $hasRadio) {
        $out.Reason = 'This machine has no wireless adapter, so nothing here applies. Wired connections are covered by the link section.'
        return $out
    }
    if (-not $svcRunning) {
        $out.Reason = 'This machine has a wireless adapter, but the WLAN AutoConfig service (WlanSvc) is not running, so Windows cannot report anything about the radio. That is a machine configuration issue, not a network one.'
        return $out
    }
    # netsh still gets the last word when it says so on its OWN first line,
    # which is where it reports "There is no wireless interface on the system".
    $firstLine = ''
    foreach ($l in @($raw)) { if (([string]$l).Trim()) { $firstLine = ([string]$l).Trim(); break } }
    if ($firstLine -match '(?i)no wireless interface') {
        $out.Reason = 'netsh reports no wireless interface on this system, although an 802.11 adapter is present - the radio may be disabled in hardware or by policy.'
        return $out
    }

    $pairs = ConvertFrom-NsNetshPairs -Lines @($raw)
    $map = @{}
    foreach ($p in $pairs) { if (-not $map.ContainsKey($p.Key)) { $map[$p.Key] = $p.Value } }

    $find = {
        param([string[]]$names)
        foreach ($n in $names) {
            foreach ($k in $map.Keys) {
                if ($k -ieq $n) { return [string]$map[$k] }
            }
        }
        return ''
    }

    $ssid   = & $find @('SSID')
    $signal = & $find @('Signal')
    $state  = & $find @('State')

    # The recognition gate. If neither SSID nor Signal is present, this output
    # is not in a shape we understand - almost always a localised Windows -
    # and saying so is the only honest option.
    if (-not $ssid -and -not $signal) {
        if ($state -and $state -imatch 'disconnect') {
            $out.Reason = 'A wireless adapter is present but not connected to any network.'
            return $out
        }
        $out.Reason = 'netsh wlan output was not in a recognised format. This is usually a non-English Windows, where the field labels are translated. Wi-Fi details cannot be read on this machine.'
        return $out
    }
    if ($state -and $state -imatch 'disconnect') {
        $out.Reason = 'The wireless adapter is present but disconnected.'
        return $out
    }

    $chanTxt = & $find @('Channel')
    $chan = 0; if ($chanTxt -match '^\d+') { $chan = [int]([regex]::Match($chanTxt,'\d+').Value) }
    $radio = & $find @('Radio type')
    $band  = & $find @('Band')
    if (-not $band) { $band = Get-NsWifiBand -Channel $chan -RadioType $radio }

    $sigPct = 0
    if ($signal -match '(\d+)') { $sigPct = [int]$matches[1] }
    # Windows exposes signal as a percentage. The documented linear mapping
    # back to dBm is rssi = (pct / 2) - 100. It is an approximation of a
    # figure the driver already rounded, so it is labelled as derived.
    $sigDbm = $null
    if ($sigPct -gt 0) { $sigDbm = [int](($sigPct / 2.0) - 100) }

    $rxTxt = & $find @('Receive rate (Mbps)')
    $txTxt = & $find @('Transmit rate (Mbps)')
    $rx = 0.0; if ($rxTxt -match '[\d\.]+') { $rx = [double]([regex]::Match($rxTxt,'[\d\.]+').Value) }
    $tx = 0.0; if ($txTxt -match '[\d\.]+') { $tx = [double]([regex]::Match($txTxt,'[\d\.]+').Value) }

    $out.Interface = [pscustomobject]@{
        name        = (& $find @('Name'))
        description = (& $find @('Description'))
        ssid        = $ssid
        bssid       = (& $find @('BSSID'))
        radioType   = $radio
        auth        = (& $find @('Authentication'))
        cipher      = (& $find @('Cipher'))
        channel     = $chan
        band        = $band
        signalPct   = $sigPct
        signalDbm   = $sigDbm
        rxMbps      = $rx
        txMbps      = $tx
    }

    $findings = [Activator]::CreateInstance([System.Collections.Generic.List[string]])
    if ($sigDbm -ne $null -and $sigDbm -lt -75) {
        $findings.Add(('Signal is about {0} dBm ({1}%), which is weak enough to cost throughput and cause retries. Move closer to the access point or add one.' -f $sigDbm, $sigPct))
    }
    if ($chan -gt 0 -and $chan -le 14) {
        $findings.Add('This client is associated on 2.4 GHz. That band is slower and far more congested than 5 GHz; if the access point offers 5 GHz, this is worth chasing.')
    }

    # ---- neighbourhood scan ------------------------------------------------
    if ($IncludeScan) {
        $scanRaw = $null
        try { $scanRaw = & netsh.exe wlan show networks mode=bssid 2>&1 } catch {}
        if ($scanRaw) {
            $nb = [Activator]::CreateInstance([System.Collections.Generic.List[object]])
            $curSsid = ''; $curBssid = ''; $curSig = 0; $curChan = 0; $curRadio = ''
            $flush = {
                if ($curBssid) {
                    $nb.Add([pscustomobject]@{
                        ssid = $curSsid; bssid = $curBssid; signalPct = $curSig
                        channel = $curChan; radioType = $curRadio
                    })
                }
            }
            foreach ($p in (ConvertFrom-NsNetshPairs -Lines @($scanRaw))) {
                # SSID lines look like "SSID 3 : name"; BSSID lines like
                # "BSSID 1 : aa:bb:...". Anchored on the keyword plus the MAC
                # shape rather than on an exact label, so a trailing index or
                # extra spacing does not break it.
                if ($p.Key -imatch '^SSID\s+\d+$') {
                    & $flush; $curBssid = ''
                    $curSsid = $p.Value
                } elseif ($p.Key -imatch '^BSSID\s+\d+$') {
                    & $flush
                    $curBssid = $p.Value; $curSig = 0; $curChan = 0; $curRadio = ''
                } elseif ($p.Key -imatch '^Signal$') {
                    if ($p.Value -match '(\d+)') { $curSig = [int]$matches[1] }
                } elseif ($p.Key -imatch '^Channel$') {
                    if ($p.Value -match '(\d+)') { $curChan = [int]$matches[1] }
                } elseif ($p.Key -imatch '^Radio type$') {
                    $curRadio = $p.Value
                }
            }
            & $flush
            $out.Neighbours = [object[]]@($nb | Sort-Object -Property signalPct -Descending)
            $out.Scanned = $true

            if ($chan -gt 0) {
                $co = @($nb | Where-Object { $_.channel -eq $chan -and $_.bssid -ne $out.Interface.bssid })
                $out.CoChannelCount = $co.Count
                if ($co.Count -ge 3) {
                    $findings.Add(('{0} other access points are broadcasting on channel {1}. They all share the airtime with this client, so this looks like a congested channel rather than a slow internet connection.' -f $co.Count, $chan))
                }
            }
            if ($ssid) {
                $better = @($nb | Where-Object { $_.ssid -eq $ssid -and $_.bssid -ne $out.Interface.bssid -and $_.signalPct -gt ($sigPct + 15) })
                $out.SameSsidBetterBss = [object[]]$better
                if ($better.Count -gt 0) {
                    $findings.Add(('Another access point on the same SSID is {0}% stronger than the one this client is using. The client is holding on to a weaker radio instead of roaming.' -f ($better[0].signalPct - $sigPct)))
                }
            }
        }
    }

    # Negotiated PHY rate versus what is actually achievable. Reported as a
    # ceiling, not as throughput: the PHY rate is shared airtime and real
    # throughput is typically half of it at best.
    if ($rx -gt 0) {
        $findings.Add(('Negotiated receive rate is {0} Mbps. That is a shared-airtime ceiling, not a throughput figure - expect roughly half of it in practice, less with other clients on the same radio.' -f $rx))
    }

    $out.Findings = [object[]]$findings
    $out.State = 'measured'
    return $out
}

# ===========================================================================
#  Path and infrastructure
# ===========================================================================

function Invoke-NsTraceroute {
    # Hop-by-hop latency using Ping with an increasing TTL.
    #
    # Not tracert.exe: parsing its localised console output is fragile, and
    # doing it directly gives three timed probes per hop and a cancel check
    # between them.
    #
    # A hop that does not answer is NOT a fault. Plenty of routers drop TTL
    # expiry or deprioritise it; the trace continues past a silent hop and
    # says "no reply" rather than "failed".
    param(
        [string]$Target = '1.1.1.1',
        [int]$MaxHops = 20,
        [int]$TimeoutMs = 1200,
        [int]$ProbesPerHop = 3,
        $Shared = $null
    )
    $out = [pscustomobject]@{ Ok = $false; Hops = @(); Reason = ''; Reached = $false }
    $hops = [Activator]::CreateInstance([System.Collections.Generic.List[object]])
    $ping = New-Object System.Net.NetworkInformation.Ping
    $buf  = New-Object byte[] 32
    try {
        for ($ttl = 1; $ttl -le $MaxHops; $ttl++) {
            if ($Shared -and $Shared.Cancel) { $out.Reason = 'Cancelled.'; break }
            if ($Shared) { $Shared.Status = ('Tracing hop {0} to {1}...' -f $ttl, $Target) }
            $opts = New-Object System.Net.NetworkInformation.PingOptions
            $opts.Ttl = $ttl
            $opts.DontFragment = $false
            $addr = ''; $times = [Activator]::CreateInstance([System.Collections.Generic.List[double]]); $final = $false
            for ($p = 0; $p -lt $ProbesPerHop; $p++) {
                try {
                    $sw = [System.Diagnostics.Stopwatch]::StartNew()
                    $r = $ping.Send($Target, $TimeoutMs, $buf, $opts)
                    $sw.Stop()
                    if ($r.Status -eq [System.Net.NetworkInformation.IPStatus]::TtlExpired -or
                        $r.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                        if ($r.Address) { $addr = $r.Address.ToString() }
                        $t = $sw.Elapsed.TotalMilliseconds
                        if ($r.RoundtripTime -gt $t) { $t = [double]$r.RoundtripTime }
                        $times.Add($t)
                        if ($r.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) { $final = $true }
                    }
                } catch {}
            }
            $stat = Get-NsStats -Values ([double[]]@($times))
            $hops.Add([pscustomobject]@{
                hop      = $ttl
                address  = $addr
                replies  = $times.Count
                minMs    = [math]::Round($stat.Min, 1)
                avgMs    = [math]::Round($stat.Mean, 1)
                maxMs    = [math]::Round($stat.Max, 1)
                note     = $(if ($times.Count -eq 0) { 'no reply (this hop does not answer TTL expiry - not necessarily a fault)' } else { '' })
            })
            if ($final) { $out.Reached = $true; break }
        }
        $out.Hops = [object[]]@($hops)
        $out.Ok = ($hops.Count -gt 0)
        if (-not $out.Reached -and $out.Ok) {
            $out.Reason = ('The trace did not reach {0} within {1} hops. Intermediate routers commonly suppress TTL-expired replies, so this alone is not a fault.' -f $Target, $MaxHops)
        }
    } catch {
        $out.Reason = $_.Exception.Message
    } finally {
        try { $ping.Dispose() } catch {}
    }
    return $out
}

function Test-NsDnsServerReachable {
    # Can we actually get a DNS answer out of this specific server?
    #
    # This exists because Resolve-DnsName -Server has no timeout parameter
    # (-QuickTimeout only drops 11 s to 7 s), so six lookups against a server
    # that never answers cost over a minute - measured at 66.7 s per resolver
    # on a network that silently drops outbound UDP/53.
    #
    # And that network is not hypothetical: on the machine this was written on,
    # ICMP to 1.1.1.1 succeeded in 18 ms and the DEFAULT resolver path answered
    # in 0.5 s, while a direct query to 1.1.1.1:53 got nothing at all. Plenty of
    # CPE and guest networks intercept port 53 and answer from their own
    # forwarder. That is a finding worth reporting, not a stall worth suffering.
    #
    # A hand-built query is used rather than Resolve-DnsName precisely because
    # it is the only way to bound the wait.
    param([string]$Server, [int]$TimeoutMs = 1500)
    $out = [pscustomobject]@{ Reachable = $false; Ms = 0.0; Detail = '' }
    $udp = $null
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Client.ReceiveTimeout = $TimeoutMs
        $udp.Client.SendTimeout    = $TimeoutMs
        $udp.Connect($Server, 53)
        # Standard A query for www.google.com, recursion desired. Transaction
        # id is randomised so a stale reply cannot be mistaken for ours.
        $r = New-Object System.Random
        $id1 = [byte]$r.Next(0, 256); $id2 = [byte]$r.Next(0, 256)
        $q = [byte[]]@(
            $id1, $id2, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0,
            3, 119, 119, 119, 6, 103, 111, 111, 103, 108, 101, 3, 99, 111, 109, 0,
            0, 1, 0, 1
        )
        [void]$udp.Send($q, $q.Length)
        $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $resp = $udp.Receive([ref]$ep)
        $sw.Stop()
        if ($resp.Length -ge 12 -and $resp[0] -eq $id1 -and $resp[1] -eq $id2) {
            $out.Reachable = $true
            $out.Ms = $sw.Elapsed.TotalMilliseconds
        } else {
            $out.Detail = 'Answered, but not with a reply to our query.'
        }
    } catch {
        $sw.Stop()
        $out.Detail = ('No answer on UDP 53 within {0} ms.' -f $TimeoutMs)
    } finally {
        if ($udp) { try { $udp.Close() } catch {} }
    }
    return $out
}

function Measure-NsDnsResolver {
    # Time a set of lookups against one resolver.
    #
    # Names are chosen to defeat caching where possible and are resolved with
    # -DnsOnly -NoHostsFile so the hosts file and NetBIOS cannot contribute.
    param(
        [string]$Server = '',
        [string[]]$Names = @(),
        [int]$ProbeTimeoutMs = 1500,
        [switch]$SkipReachabilityProbe
    )
    $out = [pscustomobject]@{
        Server = $Server; Ok = $false; N = 0; Failures = 0
        MinMs = 0.0; MedianMs = 0.0; MaxMs = 0.0; Detail = ''
        Reachable = $true; IsDefaultPath = (-not $Server)
    }
    if (-not (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue)) {
        $out.Detail = 'Resolve-DnsName is not available on this build, so per-resolver timing cannot be measured.'
        return $out
    }

    # Gate a named server on a bounded probe BEFORE spending six unbounded
    # lookups on it. Resolve-DnsName has no timeout parameter, so a server that
    # never answers costs ~11 s per name. The default path (no -Server) is not
    # probed - it is whatever the stack is configured to do, and if it is broken
    # that is the finding.
    if ($Server -and -not $SkipReachabilityProbe) {
        $probe = Test-NsDnsServerReachable -Server $Server -TimeoutMs $ProbeTimeoutMs
        if (-not $probe.Reachable) {
            $out.Reachable = $false
            $out.Detail = ('{0} did not answer a direct DNS query. {1} Either it is unreachable, or something on this network intercepts outbound port 53 - which is common on CPE and guest networks. Timing it was skipped rather than spending about a minute waiting.' -f $Server, $probe.Detail)
            return $out
        }
    }

    $times = [Activator]::CreateInstance([System.Collections.Generic.List[double]])
    foreach ($n in $Names) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            # -QuickTimeout still costs ~7 s on a dead server, which is why the
            # probe above matters more than this flag does.
            # QuickTimeout on BOTH paths. It used to be set only when a
            # server was named, which left the DEFAULT resolver path - the one
            # the comment above calls the important one - unbounded at ~11 s a
            # lookup, about 66 s for six against a resolver that never answers.
            $p = @{ Name = $n; Type = 'A'; DnsOnly = $true; NoHostsFile = $true; ErrorAction = 'Stop'; QuickTimeout = $true }
            if ($Server) { $p['Server'] = $Server }
            $null = Resolve-DnsName @p
            $sw.Stop()
            $times.Add($sw.Elapsed.TotalMilliseconds)
        } catch {
            $sw.Stop()
            $out.Failures++
        }
    }
    if ($times.Count -gt 0) {
        $st = Get-NsStats -Values ([double[]]@($times))
        $out.N = $st.N
        $out.MinMs    = [math]::Round($st.Min, 1)
        $out.MedianMs = [math]::Round($st.P50, 1)
        $out.MaxMs    = [math]::Round($st.Max, 1)
        $out.Ok = $true
    } else {
        $out.Detail = 'No lookup succeeded against this resolver.'
    }
    return $out
}

function Get-NsDnsComparison {
    # The configured resolvers against two public ones, using the SAME names.
    #
    # This is deliberately a comparison rather than a threshold. "Your DNS is
    # slow" is only a claim worth making if a different resolver on the same
    # link is measurably faster at the same moment - otherwise the delay is
    # the link, not the resolver, and swapping DNS would fix nothing.
    param([string[]]$ConfiguredServers = @(), $Shared = $null)
    $names = @(
        'www.microsoft.com','outlook.office365.com','teams.microsoft.com',
        'www.google.com','speed.cloudflare.com','login.microsoftonline.com'
    )
    $out = [pscustomobject]@{
        State = 'measured'; Reason = ''
        Default = $null
        Configured = @(); Public = @(); Verdict = ''; SlowerBy = $null
        ConfiguredIsPublic = $false; Note = ''
        InterceptSuspected = $false
    }

    # The DEFAULT path first, and it is the one that matters: it is what every
    # application on this machine actually experiences. Everything below it is
    # a comparison against that.
    if ($Shared) { $Shared.Status = 'Timing DNS on the default path...' }
    $out.Default = Measure-NsDnsResolver -Names $names

    $cfgList = @($ConfiguredServers | Select-Object -First 2)
    $cfg = [Activator]::CreateInstance([System.Collections.Generic.List[object]])
    foreach ($s in $cfgList) {
        if ($Shared) { $Shared.Status = ('Timing DNS via {0}...' -f $s) }
        if ($Shared -and $Shared.Cancel) { break }
        $cfg.Add((Measure-NsDnsResolver -Server $s -Names $names))
    }

    # The comparator must not be a resolver this machine is already using, or
    # the tool ends up timing 1.1.1.1 against 1.1.1.1 and printing a verdict
    # comparing a server with itself. Observed on the development machine,
    # whose configured DNS is 1.1.1.1.
    $wellKnown = @('1.1.1.1','8.8.8.8','9.9.9.9','208.67.222.222')
    $comparators = @($wellKnown | Where-Object { $cfgList -notcontains $_ } | Select-Object -First 2)
    $usedPublic = @($cfgList | Where-Object { $wellKnown -contains $_ })
    if ($usedPublic.Count -gt 0) {
        $out.ConfiguredIsPublic = $true
        $out.Note = ('This machine resolves directly against the public resolver {0} rather than a local or domain DNS server. That is fine for a standalone PC, but on a domain-joined machine it breaks internal name resolution and Group Policy.' -f ($usedPublic -join ', '))
    }

    $pub = [Activator]::CreateInstance([System.Collections.Generic.List[object]])
    foreach ($s in $comparators) {
        if ($Shared) { $Shared.Status = ('Timing DNS via {0} for comparison...' -f $s) }
        if ($Shared -and $Shared.Cancel) { break }
        $pub.Add((Measure-NsDnsResolver -Server $s -Names $names))
    }
    $out.Configured = [object[]]@($cfg)
    $out.Public     = [object[]]@($pub)

    # Direct queries blocked while the default path works is a DIAGNOSIS, not a
    # failure: something between here and the internet is intercepting port 53.
    # It also explains why the per-resolver comparison below has nothing to say,
    # so it has to be checked before that is treated as a fault.
    $unreachable = @(@($cfg) + @($pub) | Where-Object { -not $_.Reachable })
    $anyReachable = @(@($cfg) + @($pub) | Where-Object { $_.Reachable -and $_.Ok })
    if ($unreachable.Count -gt 0 -and $anyReachable.Count -eq 0 -and $out.Default -and $out.Default.Ok) {
        $out.InterceptSuspected = $true
        $out.Verdict = ('Name resolution works on the default path ({0} ms median), but a direct query to every DNS server tried was dropped. Something on this network is intercepting or blocking outbound port 53 - normal on CPE and guest networks, and worth knowing because it means the client cannot be pointed at a different resolver to work around a slow one.' -f $out.Default.MedianMs)
        return $out
    }

    $bestCfg = @($cfg | Where-Object { $_.Ok } | Sort-Object MedianMs | Select-Object -First 1)
    $bestPub = @($pub | Where-Object { $_.Ok } | Sort-Object MedianMs | Select-Object -First 1)
    if ($bestCfg.Count -eq 0) {
        # Only a broken DEFAULT path is a failure. If the default path resolves,
        # the machine is fine and the direct-query result is a network policy
        # observation, not an outage.
        if ($out.Default -and $out.Default.Ok) {
            $out.Verdict = ('Name resolution works on the default path ({0} ms median). The configured servers did not answer direct queries, so no per-resolver comparison was possible.' -f $out.Default.MedianMs)
            return $out
        }
        $out.State  = 'failed'
        $out.Reason = 'Name resolution failed on the default path and against every server tried. This will look exactly like "the internet is down" to the user.'
        return $out
    }
    if ($bestPub.Count -eq 0) {
        $out.Verdict = ('Configured DNS answers in {0} ms median. Public resolvers could not be reached for comparison, so there is nothing to judge it against.' -f $bestCfg[0].MedianMs)
        return $out
    }
    $delta = $bestCfg[0].MedianMs - $bestPub[0].MedianMs
    $out.SlowerBy = [math]::Round($delta, 1)
    if ($delta -gt 80) {
        $out.Verdict = ('Configured DNS ({0}) resolves in {1} ms median against {2} ms for {3} on the same link at the same moment - about {4} ms slower per lookup. A page that touches a dozen hostnames pays that delay every time, and it presents as slowness that no speed test explains.' -f `
            $bestCfg[0].Server, $bestCfg[0].MedianMs, $bestPub[0].MedianMs, $bestPub[0].Server, $out.SlowerBy)
    } else {
        $out.Verdict = ('Configured DNS ({0}) resolves in {1} ms median, against {2} ms for {3}. No meaningful penalty - changing DNS would not help here.' -f `
            $bestCfg[0].Server, $bestCfg[0].MedianMs, $bestPub[0].MedianMs, $bestPub[0].Server)
    }
    return $out
}

function Get-NsProxyConfig {
    # WinHTTP and WinINET are different settings and both matter: WinHTTP is
    # what services and SYSTEM-context tools use, WinINET is what the signed-in
    # user's browser uses. When they disagree, a tool run as SYSTEM measures a
    # different path from the one the user complains about - which is a finding
    # in itself, not a footnote.
    param()
    $out = [pscustomobject]@{
        WinHttp = ''; WinInet = ''; WinInetAutoConfig = ''; WinInetEnabled = $false
        Disagree = $false; Detail = ''
    }
    try {
        $raw = (& netsh.exe winhttp show proxy 2>&1 | Out-String)
        if ($raw -match 'Direct access|no proxy server') { $out.WinHttp = 'direct' }
        else {
            $m = [regex]::Match($raw, '(?im)^\s*Proxy Server\(s\)\s*:\s*(.+)$')
            if ($m.Success) { $out.WinHttp = $m.Groups[1].Value.Trim() } else { $out.WinHttp = 'unknown' }
        }
    } catch { $out.WinHttp = 'unknown' }
    try {
        $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
        if (Test-Path $k) {
            $p = Get-ItemProperty -Path $k -ErrorAction Stop
            $out.WinInetEnabled = ([int]$p.ProxyEnable -eq 1)
            if ($out.WinInetEnabled -and $p.ProxyServer) { $out.WinInet = [string]$p.ProxyServer }
            elseif (-not $out.WinInetEnabled) { $out.WinInet = 'direct' }
            if ($p.AutoConfigURL) { $out.WinInetAutoConfig = [string]$p.AutoConfigURL }
        }
    } catch {}
    $a = $out.WinHttp; $b = $out.WinInet
    if ($a -and $b -and $a -ne 'unknown' -and $a -ne $b) {
        $out.Disagree = $true
        $out.Detail = ('WinHTTP is set to "{0}" while the current user''s WinINET setting is "{1}". Services and anything running as SYSTEM take the first path; the user''s browser takes the second. A speed test run in one context does not describe the other.' -f $a, $b)
    }
    return $out
}

function Get-NsVpnIndicators {
    # A VPN or overlay changes which link is actually being measured, so it has
    # to be surfaced before any throughput number is believed.
    param()
    $out = [pscustomobject]@{ Suspected = $false; Routes = @(); Adapters = @(); Detail = '' }
    $routes = @(Get-NsDefaultRoutes)
    $out.Routes = [object[]]$routes
    $susp = [Activator]::CreateInstance([System.Collections.Generic.List[string]])
    try {
        foreach ($a in @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })) {
            $d = ('{0} {1}' -f $a.Name, $a.InterfaceDescription)
            # Structured field first, text second - the same order Get-NsWwanDetection
            # uses, and for the same reason. IANA ifType 131 is a tunnel, which
            # Windows knows without anyone parsing a marketing string.
            #
            # The text fallback is \b-anchored on the short and generic tokens:
            # 'vpn', 'pulse' and 'meraki' unanchored will match inside ordinary
            # adapter names, and a false "VPN / overlay: Present" warn row tells
            # a technician the link they are measuring is not the real one.
            $isTunnel = $false
            try { if ([int]$a.InterfaceType -eq 131) { $isTunnel = $true } } catch { }
            if ($isTunnel -or $d -match '(?i)\bvpn|zerotier|tailscale|wireguard|openvpn|anyconnect|globalprotect|forticlient|\bpulse\b|sonicwall|tap-windows|nordlynx|expressvpn|\bmeraki\b') {
                $susp.Add(('{0} ({1})' -f $a.Name, $a.InterfaceDescription))
            }
        }
    } catch {}
    $out.Adapters = [object[]]$susp
    if ($susp.Count -gt 0 -or $routes.Count -gt 1) {
        $out.Suspected = $true
        $parts = [Activator]::CreateInstance([System.Collections.Generic.List[string]])
        if ($routes.Count -gt 1) {
            $parts.Add(('There are {0} default routes on this machine. Windows will use "{1}" (metric {2}) for internet traffic, and that is the link measured here.' -f `
                $routes.Count, $routes[0].InterfaceAlias, $routes[0].TotalMetric))
        }
        if ($susp.Count -gt 0) {
            $parts.Add(('VPN or overlay adapters are present: {0}. If any of them carries the user''s traffic, the figures below describe the tunnel rather than the underlying link.' -f ($susp -join '; ')))
        }
        $out.Detail = ($parts -join ' ')
    } else {
        $out.Detail = 'A single default route and no VPN or overlay adapters, so the measured path is the real one.'
    }
    return $out
}

function Get-NsQosPolicies {
    param()
    $out = [pscustomobject]@{ State = 'measured'; Reason = ''; Policies = @() }
    $list = [Activator]::CreateInstance([System.Collections.Generic.List[object]])
    try {
        foreach ($p in @(Get-NetQosPolicy -ErrorAction Stop)) {
            $list.Add([pscustomobject]@{
                name = [string]$p.Name; app = [string]$p.AppPathNameMatchCondition
                dscp = $p.DSCPAction; throttle = $p.ThrottleRateActionBitsPerSecond
            })
        }
    } catch {
        # No policy store, or the cmdlet is absent on this SKU. Not a fault.
        $out.State  = 'unsupported'
        $out.Reason = 'QoS policy could not be read on this machine (Get-NetQosPolicy is unavailable or there is no local policy store).'
        return $out
    }
    $out.Policies = [object[]]$list
    return $out
}

function Get-NsPathInfo {
    # Everything on the Path and Infrastructure tab, in one call.
    #
    # The two expensive sub-steps are separately skippable and separately
    # bounded, because a headless run under an RMM timeout has to be able to
    # buy the cheap findings without gambling the whole stage on the dear ones.
    #
    # On a BROKEN link the cost inverts: every traceroute probe waits the full
    # timeout, so 3 probes x 20 hops x 1.2 s is 72 s, and path MTU is an
    # 11-probe binary search each waiting 1.5 s. Get-PathMtu already self-caps
    # via -BudgetMs; Invoke-NsTraceroute does not, which is exactly why hops and
    # timeout are passed through rather than left at their defaults.
    #
    # Every default reproduces the previous behaviour exactly, so the GUI is
    # unaffected.
    param(
        $Adapter,
        [string]$TraceTarget = '1.1.1.1',
        $Shared = $null,
        [switch]$SkipTrace,
        [int]$TraceMaxHops   = 20,
        [int]$TraceTimeoutMs = 1200,
        [switch]$SkipMtu,
        [int]$MtuBudgetMs    = 20000
    )
    $out = [pscustomobject]@{
        Vpn = $null; Proxy = $null; Dns = $null; Trace = $null
        PathMtu = $null; Power = $null; Qos = $null; PublicIp = ''
        Cancelled = $false
    }
    if ($Shared) { $Shared.Status = 'Checking routes and VPN...' }
    $out.Vpn   = Get-NsVpnIndicators
    $out.Proxy = Get-NsProxyConfig
    if ($Shared -and $Shared.Cancel) { $out.Cancelled = $true; return $out }

    if ($Shared) { $Shared.Status = 'Timing DNS resolvers...' }
    $dnsServers = @()
    if ($Adapter -and $Adapter.dnsServers) { $dnsServers = @($Adapter.dnsServers) }
    $out.Dns = Get-NsDnsComparison -ConfiguredServers $dnsServers -Shared $Shared
    if ($Shared -and $Shared.Cancel) { $out.Cancelled = $true; return $out }

    if ($Shared) { $Shared.Status = 'Detecting public egress IP...' }
    $out.PublicIp = Get-PublicIp
    if ($Shared -and $Shared.Cancel) { $out.Cancelled = $true; return $out }

    if (-not $SkipTrace) {
        $out.Trace = Invoke-NsTraceroute -Target $TraceTarget -Shared $Shared `
                        -MaxHops $TraceMaxHops -TimeoutMs $TraceTimeoutMs
        if ($Shared -and $Shared.Cancel) { $out.Cancelled = $true; return $out }
    } else {
        $out.Trace = [pscustomobject]@{
            Ok = $false; Hops = @(); Reached = $false
            Reason = 'Traceroute was skipped to stay inside the run''s time budget. The DNS and route findings above are unaffected.'
        }
    }

    if (-not $SkipMtu) {
        if ($Shared) { $Shared.Status = 'Measuring path MTU...' }
        $localMtu = 0
        if ($Adapter -and $Adapter.mtuBytes) { $localMtu = [int]$Adapter.mtuBytes }
        $out.PathMtu = Get-PathMtu -ComputerName $TraceTarget -LocalMtu $localMtu -BudgetMs $MtuBudgetMs
        if ($Shared -and $Shared.Cancel) { $out.Cancelled = $true; return $out }
    } else {
        $out.PathMtu = [pscustomobject]@{
            Ok = $false; PathMtu = 0; LocalMtu = 0; Constrained = $false; Probes = 0
            Detail = 'Path MTU was skipped to stay inside the run''s time budget.'
        }
    }

    if ($Shared) { $Shared.Status = 'Reading adapter power settings...' }
    if ($Adapter) {
        $out.Power = Get-NsNicPowerSaving -MacAddress $Adapter.macAddress `
                        -InterfaceDescription $Adapter.interfaceDescription -InterfaceGuid $Adapter.interfaceGuid
    }
    $out.Qos = Get-NsQosPolicies
    return $out
}

# ===========================================================================
#  ETW deep capture - the only true per-process byte measurement
#
#  WHY logman -ets AND NOT netsh trace.
#
#  netsh trace owns ONE GLOBAL SESSION per machine, named NetTrace. If an EDR
#  agent, a Microsoft support script, pktmon, or a half-finished earlier run
#  of this tool is holding it, our start fails - and far worse, our stop would
#  TEAR DOWN SOMEONE ELSE'S CAPTURE. On the managed fleet this tool is aimed
#  at, that is an unacceptable thing to risk for a diagnostic. netsh trace
#  also does report generation and cab collection by default, which is slow
#  and writes files nobody asked for.
#
#  logman ... -ets creates a privately named session that cannot collide with
#  anything. netsh is kept only as a documented fallback, and it refuses to
#  run at all if a session is already in progress.
# ===========================================================================

function Get-NsEtwPaths {
    # The account's own profile, never ProgramData. The capture runs elevated
    # and writes, then DELETES, its .etl here. ProgramData subfolders let any
    # standard user create folders, so a user could pre-create "etw" as a
    # junction and aim that elevated write and delete at any file on the box.
    $la = ''
    try { $la = [Environment]::GetFolderPath('LocalApplicationData') } catch { }
    if (-not $la) { $la = $env:TEMP }
    $base = Join-Path $la 'NetSpeedTroubleshooter\etw'
    @{
        Dir         = $base
        Etl         = (Join-Path $base 'netspeed.etl')
        SessionName = 'NetSpeedKernelNet'
        Provider    = 'Microsoft-Windows-Kernel-Network'
        ProviderGuid = '{7DD42A49-5329-4832-8DFD-43D979153A88}'
    }
}

function Test-NsEtwPreconditions {
    # Everything that must be true before a capture is attempted, each with the
    # reason a technician needs. Never returns a red verdict - an unmeasured
    # thing is not a broken thing.
    param()
    $out = [pscustomobject]@{ Ok = $false; Reason = ''; Elevated = $false; NetshBusy = $false }
    $out.Elevated = Test-NsElevated
    if (-not $out.Elevated) {
        $out.Reason = 'ETW kernel tracing requires elevation, and this session is not elevated. Run the tool as administrator, or from a ScreenConnect Backstage session, to use the deep capture.'
        return $out
    }
    if (-not (Get-Command logman.exe -ErrorAction SilentlyContinue)) {
        $out.Reason = 'logman.exe is not available on this machine.'
        return $out
    }
    $out.Ok = $true
    return $out
}

function Stop-NsEtwSession {
    # Idempotent, and called from the finally block AND from form close. A
    # leaked ETW session survives process exit and keeps writing to disk until
    # the disk fills - it is the worst failure mode this tool has.
    param([string]$SessionName = '')
    if (-not $SessionName) { $SessionName = (Get-NsEtwPaths).SessionName }
    try { $null = & logman.exe stop $SessionName -ets 2>&1 } catch {}
}

function Invoke-NsEtwCapture {
    # Capture, parse, and clean up. Returns real bytes per PID.
    param(
        [double]$Seconds = 20,
        $Shared = $null,
        [string]$VersionKey = ''
    )
    $lim = Get-NsLimits
    if ($Seconds -gt $lim.EtwMaxCaptureSec) { $Seconds = $lim.EtwMaxCaptureSec }
    $p = Get-NsEtwPaths
    $out = [pscustomobject]@{
        State = 'unsupported'; Reason = ''
        Processes = @(); TotalBytes = 0.0; EventsParsed = 0
        CaptureSec = 0.0; ParseSec = 0.0; Cancelled = $false
        EtlSizeBytes = 0.0
    }

    $pre = Test-NsEtwPreconditions
    if (-not $pre.Ok) { $out.Reason = $pre.Reason; return $out }

    try {
        if (-not (Test-Path -LiteralPath $p.Dir)) { $null = New-Item -ItemType Directory -Path $p.Dir -Force }
    } catch {
        $out.State = 'failed'
        $out.Reason = ('Could not create {0}: {1}' -f $p.Dir, $_.Exception.Message)
        return $out
    }

    # A stale session from a previous run would make create fail; stopping our
    # OWN named session is always safe.
    Stop-NsEtwSession -SessionName $p.SessionName
    if (Test-Path -LiteralPath $p.Etl) { try { Remove-Item -LiteralPath $p.Etl -Force -ErrorAction Stop } catch {} }

    try {
        if ($Shared) { $Shared.Status = 'Starting kernel network trace...' }
        $args = @(
            'create','trace', $p.SessionName, '-ets',
            '-p', $p.Provider, '0xffffffffffffffff', '0xff',
            '-o', $p.Etl,
            '-bs', '64', '-nb', '16', '256',
            '-mode', 'Circular', '-max', [string]$lim.EtwBufferMb
        )
        # ONE success pattern for both attempts. These were two separate
        # literals and the retry had dropped 'Der Befehl', so a German host
        # whose first attempt failed and whose RETRY SUCCEEDED was still
        # reported as "Could not start the kernel network trace".
        #
        # Matching localised console prose is fragile whatever we do here, so
        # the exit code is checked first and the text is only a fallback.
        $etwOk = {
            param([string]$Text, [int]$Code)
            if ($Code -eq 0) { return $true }
            return [bool]($Text -match '(?i)success|completed|Der Befehl')
        }
        $start = (& logman.exe @args 2>&1 | Out-String); $startCode = $LASTEXITCODE
        if (-not (& $etwOk $start $startCode)) {
            # Retry once by provider GUID: the friendly name lookup fails on
            # some builds where the manifest is not registered.
            $args[4] = $p.ProviderGuid
            $start = (& logman.exe @args 2>&1 | Out-String); $startCode = $LASTEXITCODE
        }
        if (-not (& $etwOk $start $startCode)) {
            $out.State  = 'failed'
            $out.Reason = ('Could not start the kernel network trace. logman said: {0}' -f ($start.Trim() -replace '\s+', ' '))
            return $out
        }

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
            if ($Shared -and $Shared.Cancel) { $out.Cancelled = $true; break }
            if ($Shared) {
                $Shared.Status = ('Capturing network events - {0:N0}s of {1:N0}s...' -f $sw.Elapsed.TotalSeconds, $Seconds)
            }
            Start-Sleep -Milliseconds 250
        }
        $sw.Stop()
        $out.CaptureSec = $sw.Elapsed.TotalSeconds
    } finally {
        if ($Shared) { $Shared.Status = 'Stopping trace...' }
        Stop-NsEtwSession -SessionName $p.SessionName
    }

    if ($out.Cancelled) {
        $out.State  = 'refused'
        $out.Reason = 'Cancelled during capture, so no attribution is reported.'
        try { Remove-Item -LiteralPath $p.Etl -Force -ErrorAction SilentlyContinue } catch {}
        return $out
    }
    if (-not (Test-Path -LiteralPath $p.Etl)) {
        $out.State  = 'failed'
        $out.Reason = 'The trace produced no file.'
        return $out
    }
    try { $out.EtlSizeBytes = (Get-Item -LiteralPath $p.Etl).Length } catch {}

    # ---- parse ---------------------------------------------------------
    $parseSw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        if ($Shared) { $Shared.Status = 'Parsing captured events...' }
        # Streamed straight into a hashtable accumulator. NEVER assigned to a
        # variable first: a busy machine produces hundreds of thousands of
        # records and materialising them exhausts memory.
        $acc = @{}
        $n = 0
        $ids = @(10,11,26,27,42,43,58,59)
        $filter = "*[System[(EventID=10 or EventID=11 or EventID=26 or EventID=27 or EventID=42 or EventID=43 or EventID=58 or EventID=59)]]"
        $events = $null
        try {
            $events = Get-WinEvent -Path $p.Etl -Oldest -FilterXPath $filter -ErrorAction Stop
        } catch {
            # Some builds refuse FilterXPath against an ETL. Fall back to an
            # unfiltered read and discriminate in the pipeline.
            $events = Get-WinEvent -Path $p.Etl -Oldest -ErrorAction Stop
        }
        $events | ForEach-Object {
            $e = $_
            $n++
            if (($n % 5000) -eq 0) {
                if ($Shared) {
                    $Shared.Status = ('Parsing captured events - {0:N0} so far...' -f $n)
                    if ($VersionKey) { $Shared.$VersionKey = [int]$Shared.$VersionKey + 1 }
                }
                if ($Shared -and $Shared.Cancel) { throw 'cancelled-by-user' }
            }
            $id = [int]$e.Id
            if ($ids -notcontains $id) { return }
            $props = $e.Properties
            # The manifest differs across Windows builds, so the shape is
            # checked rather than assumed.
            if ($null -eq $props -or $props.Count -lt 2) { return }
            # PID comes from the PAYLOAD, not the record header: the header PID
            # is frequently the deferred-procedure-call context rather than the
            # process that owns the socket.
            $procId = 0
            try { $procId = [int]$props[0].Value } catch { return }
            $size = 0.0
            try { $size = [double]$props[1].Value } catch { return }
            if ($size -le 0) { return }
            $sent = ($id -eq 10 -or $id -eq 26 -or $id -eq 42 -or $id -eq 58)
            if (-not $acc.ContainsKey($procId)) {
                $acc[$procId] = [pscustomobject]@{ Pid = $procId; Sent = 0.0; Recv = 0.0; Events = 0 }
            }
            if ($sent) { $acc[$procId].Sent += $size } else { $acc[$procId].Recv += $size }
            $acc[$procId].Events++
        }
        $out.EventsParsed = $n

        $rows = [Activator]::CreateInstance([System.Collections.Generic.List[object]])
        foreach ($k in $acc.Keys) {
            $a = $acc[$k]
            $name = ''; $path = ''
            try {
                $pr = Get-Process -Id $a.Pid -ErrorAction Stop
                $name = $pr.ProcessName
                try { $path = $pr.Path } catch {}
            } catch { $name = '(exited during capture)' }
            $total = $a.Sent + $a.Recv
            $out.TotalBytes += $total
            $rows.Add([pscustomobject]@{
                pid            = $a.Pid
                name           = $name
                path           = $path
                bytesSent      = $a.Sent
                bytesReceived  = $a.Recv
                bytesTotal     = $total
                mbpsAvg        = $(if ($out.CaptureSec -gt 0) { [math]::Round(($total * 8.0 / $out.CaptureSec / 1000000.0), 3) } else { 0 })
                classification = (Get-NsProcessClass -Name $name -Path $path)
                basis          = 'ETW bytes'
            })
        }
        $out.Processes = [object[]]@($rows | Sort-Object -Property bytesTotal -Descending)
        $out.State = 'measured'
    } catch {
        if ($_.Exception.Message -eq 'cancelled-by-user') {
            $out.State  = 'refused'
            $out.Reason = 'Cancelled during parsing, so no attribution is reported.'
        } else {
            $out.State  = 'failed'
            $out.Reason = ('Could not parse the capture: {0}' -f $_.Exception.Message)
        }
    } finally {
        $parseSw.Stop()
        $out.ParseSec = $parseSw.Elapsed.TotalSeconds
        # The .etl is diagnostic scratch and can be tens of megabytes. It is
        # never left behind.
        try { Remove-Item -LiteralPath $p.Etl -Force -ErrorAction SilentlyContinue } catch {}
    }
    return $out
}

# ===========================================================================
#  Ookla CLI
#
#  The built-in engine is the default because it needs no binary and works
#  under SYSTEM. This exists for one reason: speedtest.net produces a Result
#  URL, and that URL is what an ISP will accept in a ticket.
# ===========================================================================

function Get-NsOoklaPaths {
    # Kept PER ACCOUNT, never in ProgramData.
    #
    # C:\ProgramData\NetSpeedTroubleshooter inherits BUILTIN\Users:(CI)(WD,AD)
    # from ProgramData itself, so any standard user can create files and
    # folders inside it. The CLI used to live there, which meant a user could
    # pre-create ookla\speedtest.exe - or drop a DLL beside it, or turn ookla
    # into a junction - and the next technician to press the Ookla button
    # under SYSTEM in Backstage would run it as SYSTEM.
    #
    # LocalApplicationData is the systemprofile under SYSTEM and the user's own
    # profile otherwise; no other account can write there. There is
    # deliberately NO fallback to a shared temp folder: C:\Windows\Temp has the
    # same create-anything ACL, and an empty Dir makes the caller refuse.
    $la = ''
    try { $la = [Environment]::GetFolderPath('LocalApplicationData') } catch { }
    $base = ''
    if ($la) { $base = Join-Path $la 'NetSpeedTroubleshooter\ookla' }
    @{
        Dir = $base
        Exe = $(if ($base) { Join-Path $base 'speedtest.exe' } else { '' })
        Zip = $(if ($base) { Join-Path $base 'ookla-speedtest.zip' } else { '' })
        Url = 'https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-win64.zip'
        # SHA256 of the official v1.2.0 win64 build, recorded from
        # install.speedtest.net over TLS on 2026-10-08. speedtest.exe is NOT
        # Authenticode-signed, so this pin is the only thing standing between
        # the Ookla button and running whatever happens to be in the folder.
        # The URL is versioned, so the pin only changes when the URL does.
        ZipSha256 = '13E3D888B845D301A556419E31F14AB9BFF57E3F06089EF2FD3BDC9BA6841EFA'
        ExeSha256 = 'C73C4AC2A7CDC48829FE0F9D7EC91CA41C8B434490D4EB3205AAD69C7AA3B921'
    }
}

function Test-NsAdminOnlyWritable {
    # Can anyone other than SYSTEM, Administrators or TrustedInstaller change
    # this file or folder? Anything that runs as SYSTEM - a scheduled task, a
    # Backstage session - must be "no", or a standard user can rewrite it and
    # have it run with the keys to the machine.
    #
    # Checks the owner (an owner can always rewrite the permissions) and every
    # allow ACE that applies to the object itself. Inherit-only ACEs, including
    # CREATOR OWNER, apply to children, so a caller checks the files it cares
    # about individually as well as their folder.
    param([string]$Path)
    $out = [pscustomobject]@{ Ok = $false; Reason = '' }
    $trusted = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    $sidName = {
        param([string]$Sid)
        try { return (New-Object System.Security.Principal.SecurityIdentifier($Sid)).Translate([System.Security.Principal.NTAccount]).Value } catch { return $Sid }
    }
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            $out.Reason = ('{0} is a junction or link, so what it points at can be changed.' -f $Path)
            return $out
        }
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        $owner = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        if ($trusted -notcontains $owner) {
            $out.Reason = ('{0} is owned by {1}, who can change its permissions at any time.' -f $Path, (& $sidName $owner))
            return $out
        }
        # Write data / create files, append / create folders, attributes,
        # delete, change permissions, take ownership - plus GENERIC_WRITE and
        # GENERIC_ALL, which can appear raw.
        $writeMask = 0x0002 -bor 0x0004 -bor 0x0010 -bor 0x0100 -bor 0x0040 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x40000000 -bor 0x10000000
        foreach ($ace in @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))) {
            if ($ace.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
            if ($ace.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly) { continue }
            $sid = $ace.IdentityReference.Value
            if ($trusted -contains $sid) { continue }
            if (([int64][int]$ace.FileSystemRights -band $writeMask) -ne 0) {
                $out.Reason = ('{0} lets {1} change it.' -f $Path, (& $sidName $sid))
                return $out
            }
        }
        $out.Ok = $true
    } catch {
        $out.Reason = ('Could not read the permissions on {0}: {1}' -f $Path, $_.Exception.Message)
    }
    return $out
}

function Get-NsFileSha256 {
    # .NET rather than Get-FileHash, so there is one code path on every
    # PowerShell version this toolkit supports.
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs = $null
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        return (([System.BitConverter]::ToString($sha.ComputeHash($fs))) -replace '-', '')
    } finally {
        if ($fs) { $fs.Dispose() }
        $sha.Dispose()
    }
}

function Test-NsOoklaBinary {
    # Is the file at $Path byte-for-byte the build that was pinned? Checked
    # before EVERY run, not only after a download: the pin protects against
    # whatever is in the folder, whoever put it there.
    param([string]$Path, [string]$ExpectedSha256)
    $out = [pscustomobject]@{ Ok = $false; Sha256 = ''; Reason = '' }
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { $out.Reason = 'not present'; return $out }
    try { $out.Sha256 = Get-NsFileSha256 -Path $Path }
    catch { $out.Reason = ('could not be read: {0}' -f $_.Exception.Message); return $out }
    if ($ExpectedSha256 -and $out.Sha256 -eq $ExpectedSha256.ToUpperInvariant()) { $out.Ok = $true }
    else { $out.Reason = ('SHA256 {0} does not match the pinned {1}' -f $out.Sha256, $ExpectedSha256) }
    return $out
}

function Save-NsHttpFile {
    # A download that can be STOPPED and has a real deadline.
    #
    # Invoke-WebRequest -TimeoutSec only bounds the wait for the response
    # headers. A body that trickles in carries on past any limit, and nothing
    # in it checks a cancel flag. On a site whose internet is the thing under
    # test that is exactly the failure that matters: a live run on a
    # 0.17 Mbps link sat in the Ookla download for over nine minutes, the Stop
    # button did nothing, and closing the window would have hung on it too.
    #
    # The deadline is checked between reads, so the worst overshoot is one
    # ReadWriteTimeout (5 s) - and so is the worst delay before a cancel lands.
    param(
        [string]$Uri,
        [string]$OutFile,
        [double]$DeadlineSec = 60,
        $Shared = $null,
        [string]$StatusPrefix = 'Downloading'
    )
    $out = [pscustomobject]@{ Ok = $false; Bytes = [long]0; Reason = ''; Cancelled = $false }
    $req = New-NsWebRequest -Uri $Uri -NoCacheBuster -TimeoutMs ([int][math]::Min(15000, [math]::Max(1000, $DeadlineSec * 1000))) -ReadWriteTimeoutMs 5000
    # New-NsWebRequest refuses redirects because a redirected speed test is
    # a wrong answer. A download is different, and the pinned hash, not the
    # host, is what vouches for the bytes.
    $req.AllowAutoRedirect = $true
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $resp = $null; $rs = $null; $fs = $null
    try {
        $resp = $req.GetResponse()
        if ($resp.ResponseUri -and $resp.ResponseUri.Scheme -ne 'https') {
            throw ('Redirected to a non-HTTPS address ({0}), so the download was refused.' -f $resp.ResponseUri)
        }
        $total = [long]$resp.ContentLength
        $rs = $resp.GetResponseStream()
        $fs = New-Object System.IO.FileStream($OutFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $buf = New-Object byte[] 65536
        $lastStatus = -1000.0
        while ($true) {
            if ($Shared -and $Shared.Cancel) { $out.Cancelled = $true; $out.Reason = 'Cancelled during the download.'; break }
            if ($sw.Elapsed.TotalSeconds -gt $DeadlineSec) {
                $out.Reason = ('The download did not finish within {0:N0} seconds ({1:N0} KB received) and was abandoned.' -f $DeadlineSec, ($out.Bytes / 1024.0))
                break
            }
            $n = $rs.Read($buf, 0, $buf.Length)
            if ($n -le 0) {
                if ($total -gt 0 -and $out.Bytes -ne $total) {
                    $out.Reason = ('The download ended after {0:N0} of {1:N0} bytes.' -f $out.Bytes, $total)
                } else { $out.Ok = $true }
                break
            }
            $fs.Write($buf, 0, $n)
            $out.Bytes += $n
            if ($Shared -and ($sw.Elapsed.TotalMilliseconds - $lastStatus) -ge 500) {
                $lastStatus = $sw.Elapsed.TotalMilliseconds
                if ($total -gt 0) { $Shared.Status = ('{0}... {1:N0} of {2:N0} KB' -f $StatusPrefix, ($out.Bytes / 1024.0), ($total / 1024.0)) }
                else { $Shared.Status = ('{0}... {1:N0} KB' -f $StatusPrefix, ($out.Bytes / 1024.0)) }
            }
        }
    } catch {
        $out.Reason = $_.Exception.Message
    } finally {
        if ($fs) { try { $fs.Dispose() } catch {} }
        if (-not $out.Ok) { try { $req.Abort() } catch {} }
        if ($rs) { try { $rs.Dispose() } catch {} }
        if ($resp) { try { $resp.Close() } catch {} }
        if (-not $out.Ok) { try { Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue } catch {} }
    }
    return $out
}

function Expand-NsZip {
    # Expand-Archive is PowerShell 5.0+, and Server 2012 R2 ships PowerShell
    # 4.0. On 4.0 the .NET ZipFile class is present (it arrived in .NET 4.5) but
    # its assembly is not loaded by default, so it has to be added first.
    #
    # ExtractToDirectory will not overwrite, so an existing folder is cleared
    # first - Expand-Archive -Force behaviour, reproduced.
    param([string]$ZipPath, [string]$Destination)
    if (Get-Command Expand-Archive -ErrorAction SilentlyContinue) {   # ps5-ok: probed, not assumed
        Expand-Archive -LiteralPath $ZipPath -DestinationPath $Destination -Force -ErrorAction Stop   # ps5-ok
        return
    }
    Add-Type -AssemblyName 'System.IO.Compression.FileSystem' -ErrorAction Stop
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($entry in $zip.Entries) {
            if ([string]::IsNullOrEmpty($entry.Name)) { continue }   # directory entry
            $target = Join-Path $Destination $entry.FullName
            $dir = Split-Path -Parent $target
            if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
    } finally { $zip.Dispose() }
}

function Install-NsOoklaCli {
    # Modernised from the existing InternetSpeedTest.bat. Every change here is
    # also a security improvement over what that script did:
    #
    #   * A TLS download instead of "curl.exe --insecure", which disabled
    #     certificate validation on a binary download.
    #   * Expand-Archive instead of fetching unzip.exe from a third-party site
    #     over plain HTTP - an unsigned executable from an unauthenticated
    #     source is exactly what an EDR agent is meant to stop.
    #   * The archive and the exe are both checked against a pinned SHA256
    #     before anything is extracted or run.
    #   * The folder is per-account (see Get-NsOoklaPaths), not ProgramData.
    param($Shared = $null, [double]$DeadlineSec = 60)
    $p = Get-NsOoklaPaths
    $out = [pscustomobject]@{ Ok = $false; Exe = $p.Exe; Reason = ''; Downloaded = $false; Cancelled = $false }
    if (-not $p.Dir) {
        $out.Reason = 'This account has no local application data folder, and the Ookla CLI is deliberately never kept anywhere another account can write to.'
        return $out
    }
    if ((Test-NsOoklaBinary -Path $p.Exe -ExpectedSha256 $p.ExeSha256).Ok) { $out.Ok = $true; return $out }
    try {
        if (-not (Test-Path -LiteralPath $p.Dir)) { $null = New-Item -ItemType Directory -Path $p.Dir -Force -ErrorAction Stop }
        # The exe is missing or is not the pinned build, so nothing else in
        # this folder can be vouched for either - a stale build, a half-done
        # extraction, or a DLL waiting to be side-loaded by the next run.
        foreach ($f in @(Get-ChildItem -LiteralPath $p.Dir -Force -File -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
        }
        Set-NsNetDefaults -Quiet | Out-Null
        if ($Shared) { $Shared.Status = 'Downloading the Ookla CLI...' }
        $dl = Save-NsHttpFile -Uri $p.Url -OutFile $p.Zip -DeadlineSec $DeadlineSec -Shared $Shared -StatusPrefix 'Downloading the Ookla CLI'
        if (-not $dl.Ok) {
            $out.Cancelled = $dl.Cancelled
            throw ('Download failed: {0}' -f $dl.Reason)
        }
        $zh = Test-NsOoklaBinary -Path $p.Zip -ExpectedSha256 $p.ZipSha256
        if (-not $zh.Ok) { throw ('The downloaded archive is not the pinned Ookla build ({0}), so it was not extracted.' -f $zh.Reason) }
        if ($Shared) { $Shared.Status = 'Extracting the Ookla CLI...' }
        Expand-NsZip -ZipPath $p.Zip -Destination $p.Dir
        $eh = Test-NsOoklaBinary -Path $p.Exe -ExpectedSha256 $p.ExeSha256
        if (-not $eh.Ok) { throw ('speedtest.exe after extraction is not the pinned build: {0}' -f $eh.Reason) }
        $out.Downloaded = $true
        $out.Ok = $true
    } catch {
        $out.Reason = $_.Exception.Message
        try { if ($p.Exe) { Remove-Item -LiteralPath $p.Exe -Force -ErrorAction SilentlyContinue } } catch {}
    } finally {
        try { if ($p.Zip) { Remove-Item -LiteralPath $p.Zip -Force -ErrorAction SilentlyContinue } } catch {}
    }
    return $out
}

function New-NsOoklaResult {
    [pscustomobject]@{
        State = 'unsupported'; Reason = ''
        DownMbps = $null; UpMbps = $null
        IdleLatencyMs = $null; IdleJitterMs = $null
        DownLoadedMs = $null; UpLoadedMs = $null
        PacketLossPct = $null
        Isp = ''; ServerName = ''; ServerLocation = ''; ServerId = ''
        ResultUrl = ''; ExternalIp = ''
        Downloaded = $false; RawFirstLine = ''; ExitCode = $null
    }
}

function ConvertFrom-NsOoklaOutput {
    # Pure: what the CLI printed, plus its exit code, in; a result out. Split
    # from the process handling so every branch is testable without the binary.
    #
    # A NULL exit code means "could not be read", not "failed". The parsed
    # result decides then. (It used to be read as failed: see the ExitCode note
    # in Invoke-NsOoklaSpeedtest - every successful run came back 'failed'.)
    param([string]$Raw = '', [string]$ErrorText = '', $ExitCode = $null)
    $out = New-NsOoklaResult
    $out.ExitCode = $ExitCode

    # The CLI writes one JSON object per line: progress and "log" records,
    # then a final "result". With -f json it may be the result alone.
    $obj = $null
    $errMsgs = [Activator]::CreateInstance([System.Collections.Generic.List[string]])
    foreach ($line in @((([string]$Raw) + "`n" + ([string]$ErrorText)) -split "`n")) {
        $t = $line.Trim()
        if (-not $t.StartsWith('{')) { continue }
        try {
            $cand = $t | ConvertFrom-Json -ErrorAction Stop
            if ($cand.type -eq 'result' -or ($cand.download -and $cand.upload)) { $obj = $cand }
            elseif ($cand.type -eq 'log' -and $cand.level -eq 'error' -and $cand.message) { $errMsgs.Add([string]$cand.message) }
        } catch {}
    }
    $why = (@($errMsgs) -join ' ')
    if (-not $why) {
        $firstErr = @(([string]$ErrorText) -split "`n" | Where-Object { $_.Trim() }) | Select-Object -First 1
        if ($firstErr) { $why = [string]$firstErr }
    }
    $why = ($why -replace '\s+', ' ').Trim()
    if ($why.Length -gt 300) { $why = $why.Substring(0, 300) + '...' }

    if ($null -ne $ExitCode -and [int]$ExitCode -ne 0) {
        $out.State  = 'failed'
        $out.Reason = ('The Ookla CLI exited with code {0}. {1}' -f $ExitCode, $why).Trim()
        return $out
    }
    if (-not $obj) {
        $out.State  = 'failed'
        if ($why) { $out.Reason = ('The Ookla CLI produced no result. {0}' -f $why) }
        else      { $out.Reason = 'The Ookla CLI produced output that could not be parsed as a result.' }
        $out.RawFirstLine = [string](@(([string]$Raw) -split "`n") | Select-Object -First 1)
        if ($out.RawFirstLine.Length -gt 200) { $out.RawFirstLine = $out.RawFirstLine.Substring(0, 200) }
        return $out
    }

    # download.bandwidth and upload.bandwidth are BYTES per second.
    if ($obj.download -and $null -ne $obj.download.bandwidth) { $out.DownMbps = [math]::Round(([double]$obj.download.bandwidth * 8.0 / 1000000.0), 2) }
    if ($obj.upload   -and $null -ne $obj.upload.bandwidth)   { $out.UpMbps   = [math]::Round(([double]$obj.upload.bandwidth   * 8.0 / 1000000.0), 2) }
    if ($obj.ping) {
        if ($null -ne $obj.ping.latency) { $out.IdleLatencyMs = [math]::Round([double]$obj.ping.latency, 1) }
        if ($null -ne $obj.ping.jitter)  { $out.IdleJitterMs  = [math]::Round([double]$obj.ping.jitter, 1) }
    }
    # Ookla's own loaded latency, which maps directly onto our bufferbloat
    # rows and is worth carrying for cross-checking.
    if ($obj.download -and $obj.download.latency -and $null -ne $obj.download.latency.iqm) { $out.DownLoadedMs = [math]::Round([double]$obj.download.latency.iqm, 1) }
    if ($obj.upload   -and $obj.upload.latency   -and $null -ne $obj.upload.latency.iqm)   { $out.UpLoadedMs   = [math]::Round([double]$obj.upload.latency.iqm, 1) }
    if ($null -ne $obj.packetLoss) { $out.PacketLossPct = [math]::Round([double]$obj.packetLoss, 1) }
    if ($obj.isp) { $out.Isp = [string]$obj.isp }
    if ($obj.server) {
        $out.ServerName     = [string]$obj.server.name
        $out.ServerLocation = [string]$obj.server.location
        $out.ServerId       = [string]$obj.server.id
    }
    # Kept verbatim - this is the whole reason the button exists.
    if ($obj.result -and $obj.result.url) { $out.ResultUrl = [string]$obj.result.url }
    if ($obj.interface -and $obj.interface.externalIp) { $out.ExternalIp = [string]$obj.interface.externalIp }
    $out.State = 'measured'
    return $out
}

function Invoke-NsOoklaSpeedtest {
    # -TimeoutSec is the budget for EVERYTHING - download, extraction and the
    # test itself - so a caller with a stage budget (the collector) can pass it
    # and know it holds.
    #
    # -ExePath/-ExpectedSha256 exist for the tests, which run a stand-in that
    # prints canned CLI output. They travel together: nothing runs unless its
    # hash matches the one stated alongside it.
    param(
        $Shared = $null,
        [int]$TimeoutSec = 210,
        [switch]$AllowDownload,
        [string]$ExePath = '',
        [string]$ExpectedSha256 = ''
    )
    $p = Get-NsOoklaPaths
    $exe = $p.Exe; $pin = $p.ExeSha256; $workDir = $p.Dir
    if ($ExePath) { $exe = $ExePath; $pin = $ExpectedSha256; $workDir = Split-Path -Parent $ExePath }
    $out = New-NsOoklaResult
    $total = [System.Diagnostics.Stopwatch]::StartNew()

    if (-not $workDir) {
        $out.Reason = 'This account has no local application data folder, and the Ookla CLI is deliberately never kept anywhere another account can write to.'
        return $out
    }
    $check = Test-NsOoklaBinary -Path $exe -ExpectedSha256 $pin
    if (-not $check.Ok) {
        $present = ($check.Reason -ne 'not present')
        if (-not $AllowDownload -or $ExePath) {
            if ($present) {
                $out.State  = 'failed'
                $out.Reason = ('The Ookla CLI on this machine is not the pinned build ({0}), so it was not run.' -f $check.Reason)
            } else {
                $out.Reason = 'The Ookla CLI is not installed on this machine, and downloading it was not authorised for this run.'
            }
            return $out
        }
        $dlBudget = [math]::Max(10.0, [math]::Min(60.0, $TimeoutSec / 3.0))
        $inst = Install-NsOoklaCli -Shared $Shared -DeadlineSec $dlBudget
        if (-not $inst.Ok) {
            if ($inst.Cancelled) { $out.State = 'refused'; $out.Reason = 'Cancelled while downloading the Ookla CLI.' }
            else { $out.State = 'failed'; $out.Reason = ('Could not obtain the Ookla CLI: {0}' -f $inst.Reason) }
            return $out
        }
        $out.Downloaded = $inst.Downloaded
    }

    $stdout = Join-Path $workDir 'out.json'
    $stderr = Join-Path $workDir 'err.txt'
    $proc = $null
    try {
        if ($Shared) { $Shared.Status = 'Running the Ookla speed test...' }
        # --accept-gdpr as well as --accept-license: the existing .bat has only
        # the licence flag, and in EU/UK the CLI additionally prompts for GDPR
        # consent and will then wait forever behind a hidden console.
        #
        # Start-Process rather than "& $exe" so the wait is bounded and
        # cancellable. A bare call from a runspace with no console can block
        # indefinitely on a network stall with no way out.
        $proc = Start-Process -FilePath $exe `
                    -ArgumentList @('--accept-license','--accept-gdpr','-f','json') `
                    -NoNewWindow -PassThru `
                    -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        # MEASURED on PS 5.1.26100: with -NoNewWindow (or any redirection)
        # Start-Process creates the process itself and hands back a Process
        # from GetProcessById, which owns no handle. Once it exits, ExitCode
        # reads $null - and "$null -ne 0" is TRUE, so every successful Ookla
        # run used to be reported as failed. Opening the handle while the
        # process is still alive is what makes the exit code readable later.
        $null = $proc.Handle
        if ($Shared) { $Shared.ChildPid = $proc.Id }
        while (-not $proc.HasExited) {
            if ($total.Elapsed.TotalSeconds -gt $TimeoutSec) {
                try { $proc.Kill() } catch {}
                $out.State  = 'failed'
                $out.Reason = ('The Ookla test did not finish within {0} seconds and was stopped.' -f $TimeoutSec)
                return $out
            }
            if ($Shared -and $Shared.Cancel) {
                try { $proc.Kill() } catch {}
                $out.State  = 'refused'
                $out.Reason = 'Cancelled before the Ookla test completed.'
                return $out
            }
            Start-Sleep -Milliseconds 250
        }
        $raw = ''
        if (Test-Path -LiteralPath $stdout) { $raw = [string](Get-Content -LiteralPath $stdout -Raw -ErrorAction SilentlyContinue) }
        $err = ''
        if (Test-Path -LiteralPath $stderr) { $err = [string](Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue) }
        $code = $null
        try { $code = $proc.ExitCode } catch { }
        $parsed = ConvertFrom-NsOoklaOutput -Raw $raw -ErrorText $err -ExitCode $code
        $parsed.Downloaded = $out.Downloaded
        $out = $parsed
    } catch {
        $out.State  = 'failed'
        $out.Reason = $_.Exception.Message
    } finally {
        if ($Shared) { $Shared.ChildPid = 0 }
        foreach ($f in @($stdout, $stderr)) { try { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } catch {} }
    }
    return $out
}

# ===========================================================================
#  Soak / intermittent fault mode
#
#  For "it only goes slow in the afternoon". The single most important thing
#  this stage does is refuse to say anything reassuring about a short run:
#  "no dropouts" after four minutes is not evidence of anything, and printing
#  it would actively mislead.
# ===========================================================================

# ===========================================================================
#  Egress watch
#
#  A WAN failover is invisible to a single run: everything looks fine, or
#  everything looks broken, and you cannot tell which connection you were on
#  unless you happen to compare two reports by eye.
#
#  The public egress address is the tell. When a site fails over to a backup
#  WAN the address changes, and so do the latency and the route. Sampling it on
#  a schedule turns "the internet is sometimes slow" into a timestamped list of
#  when the site changed connection.
#
#  Deliberately a CSV appended by short one-shot runs rather than a long-lived
#  process: it survives reboots, needs no session, and can be driven by a
#  scheduled task or an RMM job every few minutes.
# ===========================================================================

function Get-NsAddressClass {
    # Deliberately NOT Test-NsPrivateAddress. That one folds CGNAT in with
    # RFC1918 because both are "not internet bandwidth", which is right for
    # accounting and wrong here: seeing 100.64/10 in a path is one of the
    # strongest signals available that you are behind a carrier NAT, which on a
    # fixed service is unusual and on a mobile bearer is the norm.
    param([string]$Address)
    if ([string]::IsNullOrWhiteSpace($Address)) { return 'none' }
    $a = $Address
    if ($a.Contains('%')) { $a = $a.Split('%')[0] }
    if ($a -eq '::' -or $a -eq '::1' -or $a -eq '0.0.0.0') { return 'none' }
    if ($a -match '^127\.')                        { return 'loopback' }
    if ($a -match '^169\.254\.')                   { return 'linklocal' }
    if ($a -match '^10\.')                         { return 'rfc1918' }
    if ($a -match '^192\.168\.')                   { return 'rfc1918' }
    if ($a -match '^172\.(1[6-9]|2[0-9]|3[01])\.') { return 'rfc1918' }
    if ($a -match '^(?i)f[cd][0-9a-f]{2}:')        { return 'rfc1918' }
    if ($a -match '^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.') { return 'cgnat' }
    return 'public'
}

function Get-NsEgressPath {
    # Which physical box does this machine's traffic actually leave through?
    #
    # On any site with more than one router this is THE question, and the public
    # address does not answer it: two WAN devices can present the same address,
    # a lookup needs the internet to work in the first place, and a filtered or
    # offline machine returns nothing at all. The first few TTLs answer it
    # locally, in about a second, and keep working when nothing else does.
    #
    # Read it as: local gateway -> [any further private hops] -> EGRESS DEVICE
    # -> first hop that is actually on the internet. The egress device is the
    # last privately-addressed hop, and it is the box whose WAN config decides
    # everything downstream of it.
    param(
        [string]$Target = '1.1.1.1',
        [int]$MaxHops = 5,
        [int]$TimeoutMs = 800
    )
    $out = [pscustomobject]@{
        Ok = $false; Reason = ''
        LocalGateway = ''       # hop 1 - what this machine is configured to use
        EgressDevice = ''       # last private hop - the box that faces the internet
        FirstPublicHop = ''     # first hop genuinely on the internet
        PrivateHopCount = 0
        Cgnat = $false          # carrier NAT seen before reaching public space
        Hops = @()
    }
    $hops = [Activator]::CreateInstance([System.Collections.Generic.List[object]])
    $ping = New-Object System.Net.NetworkInformation.Ping
    $buf  = New-Object byte[] 32
    try {
        for ($ttl = 1; $ttl -le $MaxHops; $ttl++) {
            $addr = ''; $rtt = -1
            try {
                $opt = New-Object System.Net.NetworkInformation.PingOptions($ttl, $false)
                $r = $ping.Send($Target, $TimeoutMs, $buf, $opt)
                if ($r -and $r.Address) { $addr = $r.Address.ToString() }
                # TtlExpired is the normal answer from an intermediate router;
                # Success means this hop IS the target and the walk is over.
                if ($r -and ($r.Status -eq [System.Net.NetworkInformation.IPStatus]::Success)) {
                    $rtt = [double]$r.RoundtripTime
                }
            } catch { }
            $cls = Get-NsAddressClass -Address $addr
            $hops.Add([pscustomobject]@{ ttl = $ttl; address = $addr; class = $cls; rttMs = $rtt })
            if ($cls -eq 'cgnat') { $out.Cgnat = $true }
            # Stop as soon as we are demonstrably on the internet.
            if ($cls -eq 'public') { $out.FirstPublicHop = $addr; break }
        }
    } finally { try { $ping.Dispose() } catch { } }
    $out.Hops = $hops.ToArray()

    $priv = @($out.Hops | Where-Object { $_.class -eq 'rfc1918' })
    $out.PrivateHopCount = $priv.Count
    if ($priv.Count -gt 0) {
        $out.LocalGateway = [string]$priv[0].address
        $out.EgressDevice = [string]$priv[$priv.Count - 1].address
        $out.Ok = $true
    } else {
        $out.Reason = 'No privately addressed hop answered, so the local path could not be mapped. Some routers drop TTL-expired replies entirely; that is not a fault on its own.'
    }
    return $out
}

function New-NsEgressPathRows {
    param($EgressPath)
    $rows = [Activator]::CreateInstance([System.Collections.Generic.List[object]])
    if (-not $EgressPath) { return $rows.ToArray() }
    if (-not $EgressPath.Ok) {
        $rows.Add((New-NsRow -Group 'Local path' -Check 'Device traffic leaves through' -Result 'not determined' `
            -Basis 'not measured' -Status 'info' -Detail $EgressPath.Reason))
        return $rows.ToArray()
    }
    $sameBox = ($EgressPath.LocalGateway -eq $EgressPath.EgressDevice)
    $rows.Add((New-NsRow -Group 'Local path' -Check 'Default gateway' -Result $EgressPath.LocalGateway `
        -Basis 'measured' -Status 'info' `
        -Detail 'The first hop - what this machine is configured to send to. Two machines on one site with DIFFERENT values here are not being routed by the same device, whatever the firewall config says.'))
    $rows.Add((New-NsRow -Group 'Local path' -Check 'Device traffic leaves through' -Result $EgressPath.EgressDevice `
        -Basis 'measured' -Status 'info' `
        -Detail $(if ($sameBox) {
            'The last privately addressed hop, and the same box as the default gateway - this machine goes straight out through its gateway.'
        } else {
            ('The last privately addressed hop before the internet. Traffic goes {0} -> {1} -> out. It is {1} whose WAN configuration decides which service this machine actually uses, so that is the box to check, not necessarily the one it is pointed at.' -f $EgressPath.LocalGateway, $EgressPath.EgressDevice)
        })))
    if ($EgressPath.FirstPublicHop) {
        $rows.Add((New-NsRow -Group 'Local path' -Check 'First hop on the internet' -Result $EgressPath.FirstPublicHop `
            -Basis 'measured' -Status 'info' -Detail 'The first address in this path that is not private. Everything before it is equipment on site or on the carrier''s access network.'))
    }
    if ($EgressPath.Cgnat) {
        $rows.Add((New-NsRow -Group 'Local path' -Check 'Carrier-grade NAT in the path' -Result 'yes' `
            -Basis 'measured' -Status 'warn' `
            -Detail 'A hop in 100.64.0.0/10 means the carrier is NATting this connection rather than routing it. Normal on mobile broadband and on some budget fixed services; unusual on a business fixed service. Inbound connections and anything needing a stable public address will not work through it.'))
    }
    return $rows.ToArray()
}

function Get-NsOuiVendor {
    # A small embedded table rather than an online lookup.
    #
    # api.macvendors.com is the obvious source and the wrong one here: this runs
    # on sites whose internet is the thing under test, it is rate limited, and a
    # gateway identification that needs the internet to work cannot help you
    # when the internet is what is broken. Gateways are routers, firewalls and
    # modems, so a few dozen prefixes cover most of what an MSP actually meets.
    # Anything unknown says so rather than guessing.
    param([string]$Mac)
    if ([string]::IsNullOrWhiteSpace($Mac)) { return '' }
    $p = ($Mac -replace '[^0-9A-Fa-f]', '').ToUpper()
    if ($p.Length -lt 6) { return '' }
    $p = $p.Substring(0, 6)
    $t = @{
        '000C29' = 'VMware'; '005056' = 'VMware'; '001C14' = 'VMware'
        '00155D' = 'Microsoft (Hyper-V)'; '0003FF' = 'Microsoft'
        '001B21' = 'Intel'; '00E04C' = 'Realtek'; '0050F2' = 'Microsoft'
        '2C3033' = 'NETGEAR'; '000FB5' = 'NETGEAR'; '00095B' = 'NETGEAR'
        '001E2A' = 'NETGEAR'; '20E52A' = 'NETGEAR'; '9C3DCF' = 'NETGEAR'
        'A00460' = 'NETGEAR'; 'C03F0E' = 'NETGEAR'; '3894ED' = 'NETGEAR'
        '000E8F' = 'Sophos'; '001A8C' = 'Sophos'; '0017A4' = 'Sophos'
        '0090FB' = 'Sophos (Astaro)'; '001C42' = 'Parallels'
        '00E0FC' = 'Huawei'; '0025BC' = 'Huawei'; '48DB50' = 'Huawei'
        '00095E' = 'Cisco'; '0018BA' = 'Cisco'; '001A2F' = 'Cisco'
        '00000C' = 'Cisco'; 'F4CFE2' = 'Cisco'; '001B54' = 'Cisco'
        '245A4C' = 'Ubiquiti'; '788A20' = 'Ubiquiti'; 'FCECDA' = 'Ubiquiti'
        '0418D6' = 'Ubiquiti'; '24A43C' = 'Ubiquiti'; '802AA8' = 'Ubiquiti'
        '000D9D' = 'Hewlett Packard'; '001871' = 'Hewlett Packard'
        '3C4A92' = 'Hewlett Packard'; '9457A5' = 'Hewlett Packard'
        '001A1E' = 'Aruba'; '6CF37F' = 'Aruba'; '000B86' = 'Aruba'
        '00090F' = 'Fortinet'; '0009F5' = 'Fortinet'; '907601' = 'Fortinet'
        '4C5E0C' = 'TP-Link'; '5C63BF' = 'TP-Link'; 'A42BB0' = 'TP-Link'
        'E894F6' = 'TP-Link'; '1027F5' = 'TP-Link'
        '001CF0' = 'D-Link'; '00265A' = 'D-Link'; '1CBDB9' = 'D-Link'
        '000C42' = 'MikroTik'; '18FD74' = 'MikroTik'; 'DC2C6E' = 'MikroTik'
        '6C3B6B' = 'MikroTik'; '48A98A' = 'MikroTik'; 'CC2DE0' = 'MikroTik'
        '001D7E' = 'Cisco-Linksys'; '00259C' = 'Cisco-Linksys'
        '002401' = 'D-Link'; '000625' = 'Linksys'
        '0024D4' = 'Technicolor'; '00265B' = 'Technicolor'; '30913C' = 'Technicolor'
        'D404FF' = 'Technicolor'; '8C6A8D' = 'Technicolor'
        '001878' = 'Arris'; '0015CE' = 'Arris'; '3C7A8A' = 'Arris'
        '442B03' = 'Cisco'; '7079B3' = 'Cisco'
        '000469' = 'Nokia'; '18A6F7' = 'Nokia (Alcatel-Lucent)'
        '001347' = 'Askey'; '001E74' = 'Askey'
        '00037F' = 'Atheros'; 'B0B98A' = 'Sagemcom'; '0011E3' = 'Sagemcom'
        '7C034C' = 'Sagemcom'; '4C17EB' = 'Sagemcom'
        '001FB3' = 'Sagemcom'; 'F81547' = 'Sagemcom'
        '000B6B' = 'Wistron'; '0019CB' = 'ZTE'; '00259E' = 'ZTE'; '344B50' = 'ZTE'
        '9CA9E4' = 'ZyXEL'; '001349' = 'ZyXEL'; '5CF4AB' = 'ZyXEL'
        '00A0C5' = 'ZyXEL'; '40B89A' = 'ZyXEL'
        '001120' = 'Cisco'; '000102' = '3Com'
    }
    if ($t.ContainsKey($p)) { return $t[$p] }
    return ''
}

function Get-NsArpEntry {
    # The neighbour cache is a PASSIVE read - nothing is sent by looking.
    #
    # It only holds L2 neighbours, so this answers for an on-link address and
    # cannot answer for anything beyond the local gateway, however reachable
    # that is over IP. That limit is reported rather than hidden: "no MAC" here
    # means "not on this subnet", not "unidentifiable".
    param([string]$Address)
    if ([string]::IsNullOrWhiteSpace($Address)) { return '' }
    try {
        # Get-NetNeighbor is Win8/2012+. On anything older only arp.exe exists,
        # which is why the fallback is not optional.
        $ns = @(Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -eq $Address -and $_.LinkLayerAddress -and
                               $_.LinkLayerAddress -ne '00-00-00-00-00-00' })
        if ($ns.Count -gt 0) { return [string]$ns[0].LinkLayerAddress }
    } catch { }
    try {
        $esc = [regex]::Escape($Address)
        foreach ($line in (& arp.exe -a 2>$null)) {
            if ($line -match ('^\s+' + $esc + '\s+([0-9a-fA-F-]{17})\s')) { return $matches[1] }
        }
    } catch { }
    return ''
}

function Get-NsHttpIdentity {
    # One request to a device this machine already talks to constantly, read for
    # the strings that name it. Raw sockets rather than Invoke-WebRequest: no
    # proxy to route around, no IE engine to initialise, and a hard timeout.
    param([string]$Address, [int]$Port = 80, [int]$TimeoutMs = 1800)
    $out = [pscustomobject]@{ Ok = $false; Server = ''; Title = ''; Realm = '' }
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $tcp.BeginConnect($Address, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $out }
        $tcp.EndConnect($iar)
        $tcp.ReceiveTimeout = $TimeoutMs
        $tcp.SendTimeout = $TimeoutMs
        $st = $tcp.GetStream()
        $req = ("GET / HTTP/1.1`r`nHost: {0}`r`nUser-Agent: NetSpeed-Troubleshooter`r`nConnection: close`r`n`r`n" -f $Address)
        $b = [System.Text.Encoding]::ASCII.GetBytes($req)
        $st.Write($b, 0, $b.Length); $st.Flush()
        $buf = New-Object byte[] 8192
        $sb = New-Object System.Text.StringBuilder
        $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
        while ((Get-Date) -lt $deadline -and $sb.Length -lt 16384) {
            $n = 0
            try { $n = $st.Read($buf, 0, $buf.Length) } catch { break }
            if ($n -le 0) { break }
            [void]$sb.Append([System.Text.Encoding]::ASCII.GetString($buf, 0, $n))
        }
        $txt = $sb.ToString()
        if ($txt) {
            $out.Ok = $true
            if ($txt -match '(?im)^Server:\s*(.+?)\s*$')            { $out.Server = $matches[1] }
            if ($txt -match '(?is)<title[^>]*>(.*?)</title>')        { $out.Title  = ($matches[1] -replace '\s+', ' ').Trim() }
            if ($txt -match '(?im)^WWW-Authenticate:.*realm="([^"]+)"') { $out.Realm = $matches[1] }
        }
    } catch { } finally { try { $tcp.Close() } catch { } }
    return $out
}

function Get-NsTlsIdentity {
    # The certificate subject is the single best identifier for an appliance
    # across a route: it survives NAT, needs no ARP entry, and vendors put their
    # own name in it.
    param([string]$Address, [int]$Port = 443, [int]$TimeoutMs = 1800)
    $out = [pscustomobject]@{ Ok = $false; Subject = ''; Issuer = ''; SelfSigned = $false }
    $tcp = New-Object System.Net.Sockets.TcpClient
    $ssl = $null
    try {
        $iar = $tcp.BeginConnect($Address, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $out }
        $tcp.EndConnect($iar)
        # Validation is bypassed DELIBERATELY and only here. Appliance
        # certificates are self-signed by definition, and the certificate is
        # being read as an identifying STRING, not trusted with any data. The
        # callback is attached to this SslStream instance, never to
        # ServicePointManager - a global override would weaken every other
        # request this process makes.
        $cb = [System.Net.Security.RemoteCertificateValidationCallback] { param($a, $b, $c, $d) return $true }
        $ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false, $cb)
        $ssl.ReadTimeout = $TimeoutMs; $ssl.WriteTimeout = $TimeoutMs
        $proto = [System.Security.Authentication.SslProtocols]'Tls12, Tls11, Tls'
        $ssl.AuthenticateAsClient($Address, $null, $proto, $false)
        $rc = $ssl.RemoteCertificate
        if ($rc) {
            $c2 = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($rc)
            $out.Ok = $true
            $out.Subject = [string]$c2.Subject
            $out.Issuer  = [string]$c2.Issuer
            $out.SelfSigned = ($c2.Subject -eq $c2.Issuer)
        }
    } catch { } finally {
        if ($ssl) { try { $ssl.Dispose() } catch { } }
        try { $tcp.Close() } catch { }
    }
    return $out
}

function Get-NsDeviceIdentity {
    # What is this box? Asked of ONE address - a gateway this machine already
    # sends every packet to - never of a range. A subnet sweep from an RMM agent
    # is a different activity with a different risk profile, and this is not it.
    param(
        [string]$Address,
        [int[]]$Ports = @(80, 443, 8080, 8443, 22, 23),
        [int]$TimeoutMs = 1200,
        [bool]$Probe = $true
    )
    $out = [pscustomobject]@{
        Address = $Address; Reachable = $false; Hostname = ''
        Mac = ''; Vendor = ''; OnLink = $false
        OpenPorts = @(); HttpServer = ''; HttpTitle = ''; HttpRealm = ''
        TlsSubject = ''; TlsIssuer = ''
        Guess = ''; GuessBasis = ''
    }
    if ([string]::IsNullOrWhiteSpace($Address)) { return $out }

    try {
        $ping = New-Object System.Net.NetworkInformation.Ping
        try { $out.Reachable = (($ping.Send($Address, 1500)).Status -eq [System.Net.NetworkInformation.IPStatus]::Success) }
        finally { try { $ping.Dispose() } catch { } }
    } catch { }

    # Passive: reads a cache, sends nothing.
    $out.Mac = Get-NsArpEntry -Address $Address
    if ($out.Mac) { $out.OnLink = $true; $out.Vendor = Get-NsOuiVendor -Mac $out.Mac }

    # GetHostEntry has NO timeout parameter, and a reverse lookup for a private
    # address with no PTR record waits out the resolver - seconds, every run.
    # Same trap as Resolve-DnsName, same fix: start it async, wait a bounded
    # time, and ABANDON it rather than calling End* on an incomplete operation.
    try {
        $dnsIar = [System.Net.Dns]::BeginGetHostEntry($Address, $null, $null)
        if ($dnsIar.AsyncWaitHandle.WaitOne(800, $false) -and $dnsIar.IsCompleted) {
            $he = [System.Net.Dns]::EndGetHostEntry($dnsIar)
            if ($he -and $he.HostName -and $he.HostName -ne $Address) { $out.Hostname = [string]$he.HostName }
        }
    } catch { }

    if ($Probe) {
        # All connects fired at once, then ONE wait. Sequentially this costs the
        # timeout for every filtered port - six ports at 1200 ms is 7 seconds
        # against a device that silently drops, and this runs twice per report.
        #
        # EndConnect is called only on a completed operation. Calling it on an
        # incomplete one blocks for that socket's own timeout, which is the
        # same trap that once turned a 25 s stage into 4 minutes.
        $open = [Activator]::CreateInstance([System.Collections.Generic.List[object]])
        $pending = [Activator]::CreateInstance([System.Collections.Generic.List[object]])
        foreach ($pt in $Ports) {
            try {
                $tcp = New-Object System.Net.Sockets.TcpClient
                $pending.Add([pscustomobject]@{ Port = $pt; Tcp = $tcp; Iar = $tcp.BeginConnect($Address, $pt, $null, $null) })
            } catch { }
        }
        $psw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($psw.ElapsedMilliseconds -lt $TimeoutMs) {
            $left = 0
            foreach ($e in $pending) { if (-not $e.Iar.IsCompleted) { $left++ } }
            if ($left -eq 0) { break }
            Start-Sleep -Milliseconds 40
        }
        $psw.Stop()
        foreach ($e in $pending) {
            if ($e.Iar.IsCompleted) {
                try { $e.Tcp.EndConnect($e.Iar); $open.Add($e.Port) } catch { }
            }
            try { $e.Tcp.Close() } catch { }
        }
        $out.OpenPorts = @(@($open.ToArray()) | Sort-Object)
        foreach ($hp in @(80, 8080)) {
            if ($out.OpenPorts -contains $hp -and -not $out.HttpServer -and -not $out.HttpTitle) {
                $h = Get-NsHttpIdentity -Address $Address -Port $hp
                if ($h.Ok) { $out.HttpServer = $h.Server; $out.HttpTitle = $h.Title; $out.HttpRealm = $h.Realm }
            }
        }
        foreach ($sp in @(443, 8443)) {
            if ($out.OpenPorts -contains $sp -and -not $out.TlsSubject) {
                $t = Get-NsTlsIdentity -Address $Address -Port $sp
                if ($t.Ok) { $out.TlsSubject = $t.Subject; $out.TlsIssuer = $t.Issuer }
            }
        }
    }

    # Strongest evidence first, and the basis is always named. A guess whose
    # source is not stated is indistinguishable from an invention.
    $cands = @(
        @{ V = $out.TlsSubject; B = 'TLS certificate' }
        @{ V = $out.HttpTitle;  B = 'web interface title' }
        @{ V = $out.HttpRealm;  B = 'HTTP auth realm' }
        @{ V = $out.Vendor;     B = 'MAC address prefix' }
        @{ V = $out.Hostname;   B = 'reverse DNS' }
        @{ V = $out.HttpServer; B = 'HTTP Server header' }
    )
    foreach ($c in $cands) {
        if ($c.V -and -not $out.Guess) {
            $v = [string]$c.V
            if ($c.B -eq 'TLS certificate' -and $v -match 'CN=([^,]+)') { $v = $matches[1].Trim() }
            $out.Guess = $v; $out.GuessBasis = $c.B
        }
    }
    return $out
}

function New-NsDeviceIdentityRows {
    param($Identity, [string]$Label = 'Gateway')
    $rows = [Activator]::CreateInstance([System.Collections.Generic.List[object]])
    if (-not $Identity -or -not $Identity.Address) { return $rows.ToArray() }
    if ($Identity.Guess) {
        $rows.Add((New-NsRow -Group $Label -Check ('What {0} appears to be' -f $Identity.Address) `
            -Result $Identity.Guess -Basis 'inference' -Status 'info' `
            -Detail ('Read from its {0}. This is what the device says about itself, not a lookup - treat it as a strong hint and confirm on the device.' -f $Identity.GuessBasis)))
    }
    if ($Identity.Mac) {
        $vTxt = $Identity.Vendor
        if (-not $vTxt) { $vTxt = 'prefix not in the built-in table' }
        $rows.Add((New-NsRow -Group $Label -Check 'MAC address' -Result $Identity.Mac -Basis 'measured' -Status 'info' `
            -Detail ('{0}. Read from this machine''s neighbour cache, so it is on the same subnet as this machine.' -f $vTxt)))
    } elseif ($Identity.Reachable) {
        $rows.Add((New-NsRow -Group $Label -Check 'MAC address' -Result 'not obtainable' -Basis 'not measured' -Status 'info' `
            -Detail 'This address is reachable but is not on this machine''s subnet, so it has no entry in the neighbour cache and no MAC can be read. That is a property of how ARP works, not a fault, and it is why the certificate and web interface are used to identify it instead.'))
    }
    if ($Identity.Hostname) {
        $rows.Add((New-NsRow -Group $Label -Check 'Reverse DNS' -Result $Identity.Hostname -Basis 'measured' -Status 'info' `
            -Detail 'The name this address resolves back to. Often blank on consumer equipment and occasionally names the service rather than the device.'))
    }
    if (@($Identity.OpenPorts).Count -gt 0) {
        $rows.Add((New-NsRow -Group $Label -Check 'Management ports open' -Result ((@($Identity.OpenPorts)) -join ', ') `
            -Basis 'measured' -Status 'info' `
            -Detail 'Ports answering a TCP connect from here. Useful for reaching the device''s admin interface, and worth noting if a WAN-facing box is answering management ports it should not be.'))
    }
    if ($Identity.TlsSubject) {
        $rows.Add((New-NsRow -Group $Label -Check 'TLS certificate' -Result $Identity.TlsSubject -Basis 'measured' -Status 'info' `
            -Detail ('Issued by: {0}. Appliance certificates are self-signed and usually carry the vendor and model, which makes this the most reliable way to identify a device you cannot ARP.' -f $Identity.TlsIssuer)))
    }
    return $rows.ToArray()
}

function Get-NsPathDeviceIdentities {
    # Identify the boxes named by Get-NsEgressPath: what this machine is pointed
    # at, and - when it is a different box - what actually faces the internet.
    # Only ever these one or two addresses, never a range.
    param($EgressPath, [bool]$Probe = $true)
    $out = [Activator]::CreateInstance([System.Collections.Generic.List[object]])
    if (-not $EgressPath -or -not $EgressPath.Ok) { return $out.ToArray() }
    if ($EgressPath.LocalGateway) {
        $out.Add([pscustomobject]@{
            Label = 'Default gateway'
            Identity = (Get-NsDeviceIdentity -Address $EgressPath.LocalGateway -Probe $Probe)
        })
    }
    if ($EgressPath.EgressDevice -and $EgressPath.EgressDevice -ne $EgressPath.LocalGateway) {
        $out.Add([pscustomobject]@{
            Label = 'Egress device'
            Identity = (Get-NsDeviceIdentity -Address $EgressPath.EgressDevice -Probe $Probe)
        })
    }
    return $out.ToArray()
}

function Get-NsEgressLogPath {
    param([string]$Dir = '')
    if ([string]::IsNullOrWhiteSpace($Dir)) { $Dir = Join-Path $env:ProgramData 'NetSpeedTroubleshooter' }
    return (Join-Path $Dir 'egress-history.csv')
}

function Get-NsEgressSnapshot {
    # One observation: who the internet thinks we are, and how far away it is.
    param([string]$LatencyTarget = '1.1.1.1', [int]$TimeoutMs = 4000)
    $out = [pscustomobject]@{
        TimestampUtc = (ConvertTo-NsIso8601 (Get-Date))
        PublicIp     = ''
        LatencyMs    = -1
        Reachable    = $false
        Gateway      = ''
        Adapter      = ''
        EgressDevice = ''
        Cgnat        = $false
        Note         = ''
    }
    try {
        $a = Get-NsActiveAdapter
        if ($a) { $out.Gateway = [string]$a.gateway; $out.Adapter = [string]$a.name }
    } catch { }
    try {
        $ping = New-Object System.Net.NetworkInformation.Ping
        try {
            $r = $ping.Send($LatencyTarget, 2000)
            if ($r.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                $out.LatencyMs = [int]$r.RoundtripTime
                $out.Reachable = $true
            }
        } finally { try { $ping.Dispose() } catch { } }
    } catch { }
    # The box traffic actually leaves through. Worth more than the public address
    # on a multi-router site, and it still works when the lookup below cannot.
    try {
        $ep = Get-NsEgressPath -Target $LatencyTarget
        if ($ep -and $ep.Ok) { $out.EgressDevice = $ep.EgressDevice; $out.Cgnat = $ep.Cgnat }
    } catch { }
    try {
        $ip = Get-PublicIp -TimeoutMs $TimeoutMs
        if ($ip) { $out.PublicIp = $ip } else { $out.Note = 'public address lookup returned nothing' }
    } catch { $out.Note = $_.Exception.Message }
    if (-not $out.PublicIp -and -not $out.Reachable) { $out.Note = 'no connectivity at all at this sample' }
    return $out
}

function Add-NsEgressObservation {
    # Append one line. Creates the file with a header if it is not there yet.
    param($Snapshot, [string]$Path = '')
    if (-not $Path) { $Path = Get-NsEgressLogPath }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    $note = ([string]$Snapshot.Note).Replace('"', "'")
    $enc = New-Object System.Text.UTF8Encoding($false)
    # A log written before EgressDevice existed keeps its own shape: appending a
    # wider row to a narrower header silently misaligns every field after it.
    $wide = $true
    if (Test-Path -LiteralPath $Path) {
        try {
            $hdr = ''
            $sr = New-Object System.IO.StreamReader($Path)
            try { $hdr = [string]$sr.ReadLine() } finally { $sr.Dispose() }
            if ($hdr -and ($hdr -notmatch 'EgressDevice')) { $wide = $false }
        } catch { }
    } else {
        [System.IO.File]::WriteAllText($Path, 'TimestampUtc,PublicIp,LatencyMs,Reachable,Gateway,Adapter,EgressDevice,Cgnat,Note' + [Environment]::NewLine, $enc)
    }
    if ($wide) {
        $line = ('{0},{1},{2},{3},{4},{5},{6},{7},"{8}"' -f $Snapshot.TimestampUtc, $Snapshot.PublicIp,
                 $Snapshot.LatencyMs, $Snapshot.Reachable, $Snapshot.Gateway, $Snapshot.Adapter,
                 $Snapshot.EgressDevice, $Snapshot.Cgnat, $note)
    } else {
        $line = ('{0},{1},{2},{3},{4},{5},"{6}"' -f $Snapshot.TimestampUtc, $Snapshot.PublicIp,
                 $Snapshot.LatencyMs, $Snapshot.Reachable, $Snapshot.Gateway, $Snapshot.Adapter, $note)
    }
    # AppendAllText rather than Add-Content: two scheduled runs can overlap, and
    # this opens and closes the handle in one call.
    [System.IO.File]::AppendAllText($Path, $line + [Environment]::NewLine, $enc)
    return $Path
}

function Get-NsEgressHistory {
    # Collapse the log into SPANS - runs of consecutive samples on one address -
    # and the transitions between them. A span list is what a technician needs:
    # "on A for four hours, on B for eleven minutes, changed three times".
    param([string]$Path = '', [int]$MaxSamples = 20000)
    if (-not $Path) { $Path = Get-NsEgressLogPath }
    $out = [pscustomobject]@{
        State = 'unsupported'; Reason = ''; Path = $Path
        Samples = 0; FirstUtc = ''; LastUtc = ''; SpanHours = 0.0
        Addresses = @(); Spans = @(); Transitions = @()
        OutageSamples = 0; Flapping = $false
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        $out.Reason = ('No egress history at {0}. Run Watch-NsEgress.ps1 on a schedule to build one.' -f $Path)
        return $out
    }
    $rows = @()
    try { $rows = @(Import-Csv -LiteralPath $Path -ErrorAction Stop | Select-Object -Last $MaxSamples) }
    catch { $out.State = 'failed'; $out.Reason = $_.Exception.Message; return $out }
    if ($rows.Count -eq 0) { $out.Reason = 'The egress history file is empty.'; return $out }

    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $out.Samples  = $rows.Count
    $out.FirstUtc = [string]$rows[0].TimestampUtc
    $out.LastUtc  = [string]$rows[$rows.Count - 1].TimestampUtc
    try {
        $t0 = [datetime]::Parse($out.FirstUtc, $inv)
        $t1 = [datetime]::Parse($out.LastUtc, $inv)
        $out.SpanHours = [math]::Round(($t1 - $t0).TotalHours, 2)
    } catch { }

    $spans = [Activator]::CreateInstance([System.Collections.Generic.List[object]])
    $trans = [Activator]::CreateInstance([System.Collections.Generic.List[object]])
    $cur = $null
    foreach ($r in $rows) {
        $ip = [string]$r.PublicIp
        if ([string]::IsNullOrWhiteSpace($ip)) { $ip = '(no address - offline)'; $out.OutageSamples++ }
        $lat = -1
        try { $lat = [int]$r.LatencyMs } catch { }
        if ($null -eq $cur -or $cur.address -ne $ip) {
            if ($null -ne $cur) {
                $spans.Add($cur)
                $trans.Add([pscustomobject]@{
                    atUtc = [string]$r.TimestampUtc; from = $cur.address; to = $ip
                    heldMinutes = $cur.minutes
                })
            }
            $cur = [pscustomobject]@{
                address = $ip; startUtc = [string]$r.TimestampUtc; endUtc = ''
                samples = 0; minutes = 0.0; latSum = 0.0; latN = 0; medianLatencyMs = -1
                egressDevice = ''
            }
        }
        $cur.samples++
        # Absent in logs written before the column existed - stays blank rather
        # than being reported as a change to nothing.
        $dev = ''
        try { if ($null -ne $r.PSObject.Properties['EgressDevice']) { $dev = [string]$r.EgressDevice } } catch { }
        if ($dev -and -not $cur.egressDevice) { $cur.egressDevice = $dev }
        if ($lat -ge 0) { $cur.latSum += $lat; $cur.latN++ }
        $cur.endUtc = [string]$r.TimestampUtc
        try {
            $a = [datetime]::Parse($cur.startUtc, $inv)
            $b = [datetime]::Parse($cur.endUtc, $inv)
            $cur.minutes = [math]::Round(($b - $a).TotalMinutes, 1)
        } catch { }
    }
    if ($null -ne $cur) { $spans.Add($cur) }
    foreach ($sp in $spans) {
        if ($sp.latN -gt 0) { $sp.medianLatencyMs = [math]::Round($sp.latSum / $sp.latN, 1) }
    }
    $out.Spans = $spans.ToArray()
    $out.Transitions = $trans.ToArray()

    $byAddr = @{}
    foreach ($sp in $out.Spans) {
        if (-not $byAddr.ContainsKey($sp.address)) {
            $byAddr[$sp.address] = [pscustomobject]@{
                address = $sp.address; samples = 0; minutes = 0.0
                latSum = 0.0; latN = 0; medianLatencyMs = -1; egressDevice = ''
            }
        }
        $byAddr[$sp.address].samples += $sp.samples
        $byAddr[$sp.address].minutes += $sp.minutes
        if ($sp.egressDevice -and -not $byAddr[$sp.address].egressDevice) { $byAddr[$sp.address].egressDevice = $sp.egressDevice }
        if ($sp.latN -gt 0) { $byAddr[$sp.address].latSum += $sp.latSum; $byAddr[$sp.address].latN += $sp.latN }
    }
    foreach ($k in @($byAddr.Keys)) {
        if ($byAddr[$k].latN -gt 0) { $byAddr[$k].medianLatencyMs = [math]::Round($byAddr[$k].latSum / $byAddr[$k].latN, 1) }
    }
    $out.Addresses = @($byAddr.Values | Sort-Object -Property samples -Descending)
    # Two or more addresses AND two or more changes is flapping, rather than a
    # single renumber that happened to fall inside the window.
    $out.Flapping = ((@($out.Addresses).Count -gt 1) -and (@($out.Transitions).Count -ge 2))
    $out.State = 'measured'
    return $out
}

function New-NsEgressSection {
    param($History)
    if (-not $History) { return New-NsSection -State 'skipped' -Reason 'The egress watch was not run.' -Method '' }
    if ($History.State -ne 'measured') {
        return New-NsSection -State $History.State -Reason $History.Reason `
            -Method 'Public egress address sampled on a schedule and collapsed into spans.'
    }
    $rows = [Activator]::CreateInstance([System.Collections.Generic.List[object]])
    $addrCount = @($History.Addresses).Count
    $st = 'ok'
    if ($History.Flapping) { $st = 'fail' } elseif ($addrCount -gt 1) { $st = 'warn' }
    $rows.Add((New-NsRow -Group 'Egress' -Check 'Addresses seen' -Result ('{0}' -f $addrCount) -Basis 'measured' -Status $st `
        -Detail ('Over {0:N1} hours and {1} samples. More than one public address means this site changed internet connection during the window - a WAN failover - and everything downstream changes with it: latency, route, and often MTU.' -f $History.SpanHours, $History.Samples)))
    foreach ($a in @($History.Addresses)) {
        $rows.Add((New-NsRow -Group 'Address' -Check $a.address -Result ('{0:N0} min' -f $a.minutes) -Basis 'measured' -Status 'info' `
            -Detail ('{0} samples, median latency {1} ms to the internet while on this address.' -f $a.samples, $a.medianLatencyMs)))
    }
    foreach ($t in @($History.Transitions)) {
        $rows.Add((New-NsRow -Group 'Changed' -Check $t.atUtc -Result ('{0} -> {1}' -f $t.from, $t.to) -Basis 'measured' -Status 'warn' `
            -Detail ('Held the previous address for {0:N0} minutes. Match this timestamp against what the user reported.' -f $t.heldMinutes)))
    }
    if ($History.OutageSamples -gt 0) {
        $rows.Add((New-NsRow -Group 'Egress' -Check 'Samples with no address' -Result ('{0}' -f $History.OutageSamples) -Basis 'measured' -Status 'warn' `
            -Detail 'Samples where the public address could not be determined at all - either fully offline, or caught mid-changeover.'))
    }
    $caveats = [string[]]@(
        'A public address can also change on a DHCP lease renewal with no failover involved. Two addresses with very different latency is a failover; two similar ones may only be a renumber.',
        'This watches the address the site presents to the internet. It cannot tell you WHY it changed - the router or firewall failover log is the authority on that.'
    )
    New-NsSection -State 'measured' `
        -Method ('Public egress address sampled {0} times over {1:N1} hours and collapsed into spans.' -f $History.Samples, $History.SpanHours) `
        -Caveats $caveats -Rows $rows.ToArray() -Data $History
}

function Invoke-NsSoak {
    param(
        [double]$Minutes = 60,
        [string]$Gateway = '',
        [int]$InterfaceIndex = 0,
        [double]$LinkSpeedMbps = 0,
        [double]$ThroughputEveryMin = 5,
        $Shared = $null,
        [string]$VersionKey = '',
        [switch]$BypassProxy,
        [switch]$NoThroughput
    )
    $lim = Get-NsLimits
    $out = [pscustomobject]@{
        State = 'measured'; Reason = ''
        Minutes = 0.0; Samples = 0
        Outages = @(); OutageCount = 0; TotalOutageSec = 0.0
        Latency = $null; ThroughputSamples = @()
        Cancelled = $false; DropoutVerdict = ''
    }
    $targets = [Activator]::CreateInstance([System.Collections.Generic.List[string]])
    if ($Gateway) { $targets.Add($Gateway) }
    $targets.Add('1.1.1.1')

    $rtts = @{}
    foreach ($t in $targets) { $rtts[$t] = [Activator]::CreateInstance([System.Collections.Generic.List[double]]) }
    $outages = [Activator]::CreateInstance([System.Collections.Generic.List[object]])
    $thr = [Activator]::CreateInstance([System.Collections.Generic.List[object]])

    $consecFail = 0
    $outageStart = $null
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastThroughput = -99999.0
    $ping = $null

    try {
        while ($sw.Elapsed.TotalMinutes -lt $Minutes) {
            if ($Shared -and $Shared.Cancel) { $out.Cancelled = $true; break }
            $tick = [System.Diagnostics.Stopwatch]::StartNew()
            $anyOk = $false
            foreach ($t in $targets) {
                try {
                    $ping = New-Object System.Net.NetworkInformation.Ping
                    $r = $ping.Send($t, 1000)
                    if ($r.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                        $rtts[$t].Add([double]$r.RoundtripTime)
                        if ($t -eq '1.1.1.1') { $anyOk = $true }
                    }
                } catch {} finally { if ($ping) { try { $ping.Dispose() } catch {} } }
            }
            $out.Samples++

            # Debounce. A single dropped ICMP is normal on any link and calling
            # it an outage would fill the report with noise; five consecutive
            # seconds of silence is a real event.
            if ($anyOk) {
                if ($null -ne $outageStart) {
                    $dur = ($sw.Elapsed.TotalSeconds - $outageStart)
                    $outages.Add([pscustomobject]@{
                        startedAt  = (Get-Date).AddSeconds(-$dur).ToString('yyyy-MM-dd HH:mm:ss')
                        durationSec = [math]::Round($dur, 1)
                    })
                    $out.TotalOutageSec += $dur
                    $outageStart = $null
                }
                $consecFail = 0
            } else {
                $consecFail++
                if ($consecFail -eq $lim.SoakFailDebounce -and $null -eq $outageStart) {
                    $outageStart = $sw.Elapsed.TotalSeconds - $lim.SoakFailDebounce
                }
            }

            if (-not $NoThroughput -and $ThroughputEveryMin -gt 0 -and
                (($sw.Elapsed.TotalMinutes - $lastThroughput) -ge $ThroughputEveryMin)) {
                $lastThroughput = $sw.Elapsed.TotalMinutes
                if ($Shared) { $Shared.Status = 'Soak: taking a throughput sample...' }
                $r = Invoke-CfThroughput -Direction 'Down' -Streams 2 -MeasureSec 4 -WarmupSec 1.0 `
                        -EstMbps 25 -Shared $Shared -BypassProxy:$BypassProxy
                $thr.Add([pscustomobject]@{
                    at      = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                    atMin   = [math]::Round($sw.Elapsed.TotalMinutes, 1)
                    mbps    = [math]::Round($r.OverallMbps, 2)
                    state   = $r.State
                })
                if ($VersionKey -and $Shared) { $Shared.$VersionKey = [int]$Shared.$VersionKey + 1 }
            }

            if ($Shared) {
                $Shared.Status = ('Soak running - {0:N1} of {1:N0} min, {2} dropouts so far' -f $sw.Elapsed.TotalMinutes, $Minutes, $outages.Count)
                if (($out.Samples % 5) -eq 0 -and $VersionKey) { $Shared.$VersionKey = [int]$Shared.$VersionKey + 1 }
                $Shared.SoakOutages = [object[]]@($outages)
                $Shared.SoakThroughput = [object[]]@($thr)
                $Shared.SoakMinutes = [math]::Round($sw.Elapsed.TotalMinutes, 2)
            }

            $tick.Stop()
            $rest = 1000 - [int]$tick.ElapsedMilliseconds
            if ($rest -gt 0) { Start-Sleep -Milliseconds $rest }
        }
    } finally {
        $sw.Stop()
    }

    # Close an outage still open at the end of the run.
    if ($null -ne $outageStart) {
        $dur = ($sw.Elapsed.TotalSeconds - $outageStart)
        $outages.Add([pscustomobject]@{
            startedAt   = (Get-Date).AddSeconds(-$dur).ToString('yyyy-MM-dd HH:mm:ss')
            durationSec = [math]::Round($dur, 1)
        })
        $out.TotalOutageSec += $dur
    }

    $out.Minutes = [math]::Round($sw.Elapsed.TotalMinutes, 2)
    $out.Outages = [object[]]@($outages)
    $out.OutageCount = $outages.Count
    $out.ThroughputSamples = [object[]]@($thr)
    $lat = @{}
    foreach ($t in $targets) {
        $st = Get-NsStats -Values ([double[]]@($rtts[$t]))
        $lat[$t] = [pscustomobject]@{
            n = $st.N; minMs = [math]::Round($st.Min,1); p50Ms = [math]::Round($st.P50,1)
            p95Ms = [math]::Round($st.P95,1); maxMs = [math]::Round($st.Max,1)
            jitterMs = [math]::Round((Get-NsJitter -Values ([double[]]@($rtts[$t]))),1)
        }
    }
    $out.Latency = $lat

    # THE POINT OF THIS STAGE. A clean short run proves nothing, and saying
    # "no dropouts" would be read as "the link is fine" - which is exactly the
    # wrong conclusion to hand someone chasing an intermittent fault.
    if ($out.OutageCount -gt 0) {
        $out.DropoutVerdict = ('{0} dropout(s) recorded in {1:N0} minutes, totalling {2:N0} seconds offline. Timestamps are listed so they can be matched against the user''s account of when it happened.' -f `
            $out.OutageCount, $out.Minutes, $out.TotalOutageSec)
    } elseif ($out.Minutes -lt $lim.SoakMinMinutes) {
        $out.State  = 'refused'
        $out.Reason = ('The soak ran for only {0:N1} minutes (minimum {1}). No dropouts were seen, but that is not evidence of anything over a window this short, so no verdict is given.' -f $out.Minutes, $lim.SoakMinMinutes)
        $out.DropoutVerdict = $out.Reason
    } else {
        $out.DropoutVerdict = ('No dropouts observed in {0:N0} minutes of continuous monitoring. That is not the same as "no dropouts" - an intermittent fault outside this window would not have been seen.' -f $out.Minutes)
    }
    if ($out.Cancelled -and $out.State -eq 'measured' -and $out.OutageCount -eq 0 -and $out.Minutes -lt $lim.SoakMinMinutes) {
        $out.State = 'refused'
    }
    return $out
}

# ===========================================================================
#  Section builders - raw measurement objects into report rows
# ===========================================================================

function New-NsLinkSection {
    param($Adapter, $Vpn = $null, $Power = $null, $Proxy = $null)
    $rows = [Activator]::CreateInstance([System.Collections.Generic.List[object]])
    if (-not $Adapter -or -not $Adapter.name) {
        return New-NsSection -State 'failed' -Reason 'No usable network adapter was found on this machine.' `
                             -Method 'Get-NetAdapter and Get-NetRoute'
    }
    $wired = -not $Adapter.isWireless
    $speedStatus = 'ok'
    $speedDetail = 'Negotiated link speed.'
    if ($wired -and $Adapter.linkSpeedMbps -gt 0 -and $Adapter.linkSpeedMbps -lt 100) {
        $speedStatus = 'fail'
        $speedDetail = 'A wired adapter negotiating below 100 Mbps almost always means a damaged or low-grade cable, a dirty port, or a switch port forced to a legacy speed. This caps everything else measured here, so fix it before investigating anything upstream.'
    } elseif ($wired -and $Adapter.linkSpeedMbps -ge 100 -and $Adapter.linkSpeedMbps -lt 1000) {
        $speedStatus = 'warn'
        $speedDetail = 'Negotiated at 100 Mbps. Fine unless the site''s internet plan approaches or exceeds that.'
    }
    $rows.Add((New-NsRow -Group 'Adapter' -Check 'Link speed' `
        -Result ('{0} Mbps' -f $Adapter.linkSpeedMbps) -Basis 'measured' -Status $speedStatus -Detail $speedDetail))
    $rows.Add((New-NsRow -Group 'Adapter' -Check 'Name' -Result $Adapter.name -Basis 'measured' -Status 'info' -Detail $Adapter.interfaceDescription))

    if ($null -ne $Adapter.fullDuplex) {
        if ($Adapter.isWireless) {
            # Wi-Fi is half duplex BY DESIGN. A radio cannot transmit and
            # receive on the same channel at once, so 802.11 takes turns via
            # CSMA/CA. Reporting that as a fault is not merely redundant - it
            # is wrong, there is nothing to change, and as a red it dragged the
            # whole verdict down through worst-of-measured.
            $rows.Add((New-NsRow -Group 'Adapter' -Check 'Duplex' `
                -Result $(if ($Adapter.fullDuplex) { 'Reported full duplex' } else { 'Half duplex (normal for Wi-Fi)' }) `
                -Basis 'measured' -Status 'info' `
                -Detail 'Wi-Fi is a shared half-duplex medium - a radio cannot send and receive at the same time, so stations take turns. This is how 802.11 works, not an autonegotiation fault, and there is nothing to set. Duplex only indicates a fault on a WIRED link.'))
        } else {
            $dup = 'Full duplex'
            $ds  = 'ok'
            $dd  = ''
            if (-not $Adapter.fullDuplex) {
                $dup = 'HALF DUPLEX'; $ds = 'fail'
                $dd = 'Half duplex on a modern WIRED link means an autonegotiation mismatch. It produces late collisions and retransmissions that look exactly like a slow or unreliable internet connection.'
            }
            $rows.Add((New-NsRow -Group 'Adapter' -Check 'Duplex' -Result $dup -Basis 'measured' -Status $ds -Detail $dd))
        }
    }
    $rows.Add((New-NsRow -Group 'Adapter' -Check 'Media' `
        -Result $(if ($Adapter.isWireless) { 'Wireless' } else { 'Wired' }) -Basis 'measured' -Status 'info' -Detail $Adapter.physicalMediaType))
    $rows.Add((New-NsRow -Group 'IP' -Check 'Address' -Result ('{0}/{1}' -f $Adapter.ipv4, $Adapter.ipv4PrefixLength) -Basis 'measured' -Status 'info' -Detail ('MTU {0}' -f $Adapter.mtuBytes)))
    $rows.Add((New-NsRow -Group 'IP' -Check 'Gateway' -Result $Adapter.gateway -Basis 'measured' -Status $(if ($Adapter.gateway) { 'ok' } else { 'fail' }) -Detail $(if ($Adapter.gateway) { '' } else { 'No default gateway - this machine has no route to the internet.' })))
    $rows.Add((New-NsRow -Group 'IP' -Check 'DNS servers' -Result (@($Adapter.dnsServers) -join ', ') -Basis 'measured' -Status 'info' -Detail ''))

    if ($Power) {
        if ($Power.Ok) {
            $ps = 'ok'; $pr = 'Power saving disabled'
            $pd = ''
            if ($Power.PowerSavingEnabled) {
                $pr = 'Power saving ALLOWED'
                # Wired only. On Wi-Fi, power save (PSM / U-APSD) is normal,
                # expected and often required for battery life - warning about
                # it there, with prose that talks about wired links, sends a
                # technician to change a setting that should stay on.
                if ($Adapter -and $Adapter.isWireless) {
                    $ps = 'info'
                    $pd = 'Windows may power-manage this radio. On Wi-Fi that is normal and expected - 802.11 power save is part of how a client conserves battery between beacons - so it is reported for completeness rather than as a fault. It is only worth changing if this machine is mains-powered and showing unexplained brief stalls.'
                } else {
                    $ps = 'warn'
                    $pd = 'Windows is permitted to power this adapter down to save energy. On wired links this causes brief stalls that users report as the connection "dropping for a second". Clear the checkbox in the adapter''s Power Management tab.'
                }
            }
            $rows.Add((New-NsRow -Group 'Driver' -Check 'NIC power management' -Result $pr -Basis 'measured' -Status $ps -Detail $pd))
            if ($Power.DriverVersion) {
                $rows.Add((New-NsRow -Group 'Driver' -Check 'Driver' -Result ('{0} ({1})' -f $Power.DriverVersion, $Power.DriverDate) -Basis 'measured' -Status 'info' -Detail $Power.DriverProvider))
            }
        } else {
            $rows.Add((New-NsRow -Group 'Driver' -Check 'NIC power management' -Result 'Not read' -Basis 'not measured' -Status 'info' -Detail $Power.Detail))
        }
    }
    if ($Vpn) {
        $vs = 'ok'; if ($Vpn.Suspected) { $vs = 'warn' }
        $rows.Add((New-NsRow -Group 'Routing' -Check 'VPN / overlay' `
            -Result $(if ($Vpn.Suspected) { 'Present' } else { 'None detected' }) -Basis 'measured' -Status $vs -Detail $Vpn.Detail))
    }
    if ($Proxy) {
        $prs = 'ok'; if ($Proxy.Disagree) { $prs = 'warn' }
        $det = $Proxy.Detail
        if (-not $det) { $det = ('WinHTTP: {0}; WinINET: {1}' -f $Proxy.WinHttp, $Proxy.WinInet) }
        $rows.Add((New-NsRow -Group 'Routing' -Check 'Proxy' -Result $Proxy.WinHttp -Basis 'measured' -Status $prs -Detail $det))
    }

    New-NsSection -State 'measured' -Method 'Adapter, route, DNS and driver facts read from Windows. These are configuration facts, not measurements.' `
        -Rows $rows -Data ([pscustomobject]@{
            adapter = $Adapter
            vpn     = $Vpn
            power   = $Power
            proxy   = $Proxy
        })
}

function New-NsThroughputSection {
    param($Down, $Up, [double]$PlanDown = 0, [double]$PlanUp = 0)
    $rows = [Activator]::CreateInstance([System.Collections.Generic.List[object]])
    $lim = Get-NsLimits
    $caveats = [Activator]::CreateInstance([System.Collections.Generic.List[string]])
    $caveats.Add('This is a single-CDN measurement: the path to one Cloudflare edge, not to any particular service the customer uses.')

    if (-not $Down -and -not $Up) {
        return New-NsSection -State 'skipped' -Reason 'The throughput stage was not run.' -Method ''
    }

    $meta = $null
    foreach ($r in @($Down, $Up)) { if ($r -and $r.Meta) { $meta = $r.Meta; break } }

    $addDir = {
        param($r, [string]$label, [double]$plan)
        if (-not $r) { return }
        if (-not $r.Ok) {
            $rows.Add((New-NsRow -Group $label -Check 'Throughput' -Result 'withheld' -Basis 'withheld' -Status 'info' -Detail $r.Reason))
            return
        }
        $st = 'ok'
        $detail = ('{0} streams, {1:N0} ms windows, {2:N1}s warm-up discarded, {3} transferred. Timed on body transfer only, excluding time-to-first-byte.' -f `
                   $r.StreamsEstablished, $r.WindowMs, $r.WarmupSec, (Format-NsBytes $r.TotalBytes))
        if ($r.Reason) { $detail = ('{0} {1}' -f $r.Reason, $detail) }
        if ($plan -gt 0) {
            $pct = ($r.OverallMbps / $plan) * 100.0
            $detail = ('{0} That is {1:N0}% of the stated {2:N0} Mbps plan.' -f $detail, $pct, $plan)
            if ($pct -lt 50) { $st = 'fail' } elseif ($pct -lt 80) { $st = 'warn' }
        }
        $rows.Add((New-NsRow -Group $label -Check 'Throughput' -Result (Format-NsThroughputResult -Result $r) -Basis 'measured' -Status $st -Detail $detail))
        if ($r.BurstyWindows) {
            $rows.Add((New-NsRow -Group $label -Check 'Stability' -Result 'Bursty' -Basis 'measured' -Status 'warn' `
                -Detail 'The 90th percentile sits well above the sustained rate, so this link delivers in bursts rather than steadily. The sustained figure is the one to quote.'))
        }
    }
    & $addDir $Down 'Download' $PlanDown
    & $addDir $Up   'Upload'   $PlanUp

    if ($Up -and $Up.Ok) {
        $caveats.Add('Upload is timed from the first write to the response arriving, so it includes one round trip and reads pessimistically on high-latency links.')
    }
    if ($meta) {
        $rows.Add((New-NsRow -Group 'Path' -Check 'Cloudflare edge' `
            -Result ('{0} ({1})' -f $meta.Colo, $meta.City) -Basis 'server-reported' -Status 'info' `
            -Detail ('Client IP {0}, AS{1} {2}. This names the edge the measurement actually reached.' -f $meta.ClientIp, $meta.Asn, $meta.Country)))
        if ($meta.L4) {
            $l4 = $meta.L4
            $lossTxt = ('lost {0}, retransmits {1}' -f $l4.Lost, $l4.Retrans)
            $st = 'ok'
            if ($l4.Retrans -gt 0 -and $l4.Cwnd -gt 0) {
                if (($l4.Retrans / [math]::Max([double]1, $l4.Cwnd)) -gt 0.02) { $st = 'warn' }
            }
            $rows.Add((New-NsRow -Group 'Path' -Check 'Server-side loss' -Result $lossTxt -Basis 'server-reported' -Status $st `
                -Detail ('Cloudflare''s own view of the TCP connections used for this test: RTT {0:N1} ms, minimum {1:N1} ms. This is the only true packet-loss figure in the tool - everything else here infers loss from missing replies.' -f `
                         ($l4.RttUs / 1000.0), ($l4.MinRttUs / 1000.0))))
        }
    }
    if ($Down -and $Down.WwanProfile) {
        $why = ''
        if ($Down.WwanBasis) { $why = (' ' + $Down.WwanBasis) }
        $caveats.Add(('A cellular adapter was detected, so a reduced test profile was applied automatically to limit data use - the figures are from a shorter run than usual.{0} If this machine is NOT on mobile broadband, that detection is wrong and the figures understate the link: re-run and check which adapter is selected.' -f $why))
    }
    $capHits = @(@($Down, $Up) | Where-Object { $_ -and $_.CapHit } | ForEach-Object { $_.CapHit })
    foreach ($c in $capHits) { $caveats.Add($c) }

    $anyOk = (($Down -and $Down.Ok) -or ($Up -and $Up.Ok))
    $state = 'measured'; $reason = ''
    if (-not $anyOk) {
        $state = 'refused'
        $reason = 'Neither direction produced a figure this tool is willing to stand behind. The per-direction reasons are on the rows.'
        foreach ($r in @($Down, $Up)) {
            if ($r -and $r.State -eq 'failed') { $state = 'failed'; $reason = $r.Reason }
        }
    }
    New-NsSection -State $state -Reason $reason `
        -Method ('Concurrent HTTPS streams to speed.cloudflare.com, body-transfer time only, {0:N1}s warm-up discarded, aggregated into fixed windows and reported as the 90th percentile with the median and the sustained rate alongside.' -f $lim.WarmupSec) `
        -Caveats ([string[]]$caveats) -Rows $rows `
        -Data ([pscustomobject]@{
            engine = 'cloudflare-multistream'
            target = $meta
            download = $Down
            upload   = $Up
            planMbps = [pscustomobject]@{ down = $PlanDown; up = $PlanUp; stated = (($PlanDown -gt 0) -or ($PlanUp -gt 0)) }
            capsApplied = [pscustomobject]@{
                maxBytesDown = $lim.MaxDownBytes; maxBytesUp = $lim.MaxUpBytes
                maxStreams = $lim.MaxStreams; maxSecPerDirection = $lim.MaxSecPerDir
                engineCeilingMbps = $lim.EngineCeilingMbps
            }
        })
}

function New-NsLatencySection {
    param($Result)
    if (-not $Result) { return New-NsSection -State 'skipped' -Reason 'The latency stage was not run.' -Method '' }
    $rows = [Activator]::CreateInstance([System.Collections.Generic.List[object]])
    $caveats = [Activator]::CreateInstance([System.Collections.Generic.List[string]])

    $emit = {
        param($phase, $summary)
        if (-not $summary) { return }
        foreach ($k in @($summary.Keys | Sort-Object)) {
            $v = $summary[$k]
            if ($v.n -eq 0) {
                $rows.Add((New-NsRow -Group $phase -Check $k -Result 'no replies' -Basis 'not measured' -Status 'info' `
                    -Detail 'Nothing came back from this target during this phase.'))
                continue
            }
            $basis = 'measured'
            $status = 'info'
            $detail = ('min {0} / p50 {1} / p95 {2} / max {3} ms, jitter {4} ms, {5}% of probes lost. {6}' -f `
                       $v.minMs, $v.p50Ms, $v.p95Ms, $v.maxMs, $v.jitterMs, $v.lossPct, $v.basis)
            if ($k -eq 'http' -and -not $v.usable) {
                $basis = 'withheld'
                $status = 'info'
                $detail = ('{0} This tool''s own polling accounts for about {1} ms of it, so the figure is within the instrument''s noise and no conclusion is drawn from it.' -f $detail, $v.noiseFloorMs)
            }
            $rows.Add((New-NsRow -Group $phase -Check $k -Result (Format-NsMs $v.p50Ms) -Basis $basis -Status $status -Detail $detail))
        }
    }
    & $emit 'Idle'          $Result.Idle
    & $emit 'Under download' $Result.LoadedDown
    & $emit 'Under upload'   $Result.LoadedUp

    if ($Result.GradeState -ne 'measured') {
        $rows.Add((New-NsRow -Group 'Verdict' -Check 'Bufferbloat grade' -Result 'withheld' -Basis 'withheld' -Status 'info' -Detail $Result.GradeReason))
    } else {
        $gs = 'ok'
        if ($Result.Grade -eq 'C') { $gs = 'warn' }
        if ($Result.Grade -eq 'D' -or $Result.Grade -eq 'F') { $gs = 'fail' }
        $rows.Add((New-NsRow -Group 'Verdict' -Check 'Bufferbloat grade' -Result $Result.Grade -Basis 'measured' -Status $gs `
            -Detail ('Graded on the INCREASE in latency under load, not the absolute value: download {0}, upload {1}, worst case {2}. Scale is DSLReports: A+ under 5 ms, A under 30, B under 60, C under 200, D under 400, F at 400 or more.' -f `
                     (Format-NsIncrease $Result.DownIncreaseMs), (Format-NsIncrease $Result.UpIncreaseMs), (Format-NsIncrease $Result.WorstAddedMs))))
    }
    if ($Result.Queue) {
        # A refused queue location is an INFERENCE that could not be drawn, not
        # a measurement. Marking it 'measured' put a withheld answer in the same
        # visual class as a real one.
        $qBasis = 'measured'
        $qResult = $Result.Queue.Location
        if ($Result.Queue.State -eq 'refused') { $qBasis = 'not measured'; $qResult = 'not determined' }
        $rows.Add((New-NsRow -Group 'Verdict' -Check 'Where the queue is' -Result $qResult -Basis $qBasis -Status 'info' -Detail $Result.Queue.Summary))
        if ($Result.Queue.GatewayProbeNote) { $caveats.Add($Result.Queue.GatewayProbeNote) }
    }
    $caveats.Add('Ping figures come from the network stack''s own round-trip time and are quantised to whole milliseconds, which matters on a LAN hop but not on a WAN path.')

    $state = 'measured'; $reason = ''
    if ($Result.GradeState -eq 'refused' -and -not $Result.Idle) { $state = 'refused'; $reason = $Result.GradeReason }
    New-NsSection -State $state -Reason $reason `
        -Method 'Latency sampled continuously against the gateway, 1.1.1.1 and an HTTPS endpoint, first with the link idle and then while the same link was deliberately saturated in each direction.' `
        -Caveats ([string[]]$caveats) -Rows $rows `
        -Data ([pscustomobject]@{
            idle = $Result.Idle; loadedDown = $Result.LoadedDown; loadedUp = $Result.LoadedUp
            downIncreaseMs = $Result.DownIncreaseMs; upIncreaseMs = $Result.UpIncreaseMs
            worstAddedMs = $Result.WorstAddedMs
            grade = $Result.Grade; gradeState = $Result.GradeState; gradeReason = $Result.GradeReason
            gradeScale = 'DSLReports: A+ <5, A <30, B <60, C <200, D <400, F >=400 ms of INCREASE under load'
            queue = $Result.Queue
        })
}

function New-NsHogsSection {
    param($Hogs, [int]$SelfPid = 0)
    if (-not $Hogs) { return New-NsSection -State 'skipped' -Reason 'The bandwidth hog stage was not run.' -Method '' }
    $rows = [Activator]::CreateInstance([System.Collections.Generic.List[object]])
    $caveats = [Activator]::CreateInstance([System.Collections.Generic.List[string]])
    $caveats.Add('Windows exposes no per-process byte counter. Everything attributed to a process here is INFERRED from how many external connections it holds - it identifies suspects, not culprits. Use the ETW deep capture for real per-process bytes.')
    $caveats.Add('This tool sees this PC only. A device elsewhere on the LAN saturating the same link is invisible to it.')

    if ($Hogs.Link -and $Hogs.Link.Ok) {
        $rows.Add((New-NsRow -Group 'Link' -Check 'Traffic on the wire' `
            -Result ('down {0} / up {1}' -f (Format-NsMbps $Hogs.Link.DownMbps), (Format-NsMbps $Hogs.Link.UpMbps)) `
            -Basis 'measured' -Status 'info' `
            -Detail ('Sampled from the adapter''s own counters over {0:N1}s. This is how much is moving in total; it says nothing about which process is responsible.' -f $Hogs.Link.Seconds)))
        if ($Hogs.Link.OutDiscards -gt 0 -or $Hogs.Link.InErrors -gt 0) {
            $rows.Add((New-NsRow -Group 'Link' -Check 'Errors / discards' `
                -Result ('{0} errors, {1} discards' -f $Hogs.Link.InErrors, $Hogs.Link.OutDiscards) -Basis 'measured' -Status 'warn' `
                -Detail 'Non-zero discards or errors during a sample point at a physical problem - cable, port, or driver - rather than at contention.'))
        }
    } else {
        $d = ''
        if ($Hogs.Link) { $d = $Hogs.Link.Detail }
        $rows.Add((New-NsRow -Group 'Link' -Check 'Traffic on the wire' -Result 'not measured' -Basis 'not measured' -Status 'info' -Detail $d))
    }

    if ($Hogs.DO -and $Hogs.DO.State -eq 'measured') {
        $doStatus = 'ok'
        $rateMbps = 0.0
        if ($null -ne $Hogs.DO.DownlinkBps) { $rateMbps = [double]$Hogs.DO.DownlinkBps * 8.0 / 1000000.0 }
        if ($Hogs.DO.ActiveJobs -gt 0) { $doStatus = 'warn' }
        if ($rateMbps -gt 2) { $doStatus = 'fail' }
        $rows.Add((New-NsRow -Group 'Windows Update' -Check 'Delivery Optimization' `
            -Result ('{0} job(s) in progress, {1} pending' -f $Hogs.DO.ActiveJobs, (Format-NsBytes $Hogs.DO.ActiveRemainingBytes)) `
            -Basis 'DO counter' -Status $doStatus `
            -Detail ('Currently pulling {0}. The pending figure is what is still to come, not what has been used. Cumulative totals for jobs DO still remembers: {1} over HTTP, {2} from LAN peers - those are history, not current consumption.' -f `
                     (Format-NsMbps $rateMbps), (Format-NsBytes $Hogs.DO.FromHttp), (Format-NsBytes $Hogs.DO.FromLanPeers))))
    } elseif ($Hogs.DO) {
        $rows.Add((New-NsRow -Group 'Windows Update' -Check 'Delivery Optimization' -Result 'not measured' -Basis 'not measured' -Status 'info' -Detail $Hogs.DO.Reason))
    }

    if ($Hogs.Bits -and $Hogs.Bits.State -eq 'measured') {
        $bs = 'ok'; if ($Hogs.Bits.TransferringJobs -gt 0) { $bs = 'warn' }
        $rows.Add((New-NsRow -Group 'Background' -Check 'BITS transfers' `
            -Result ('{0} active of {1}' -f $Hogs.Bits.TransferringJobs, $Hogs.Bits.TotalJobs) -Basis 'BITS counter' -Status $bs `
            -Detail ('{0} still to transfer. {1}' -f (Format-NsBytes $Hogs.Bits.RemainingBytes), $Hogs.Bits.Caveat)))
        if ($Hogs.Bits.Caveat) { $caveats.Add($Hogs.Bits.Caveat) }
    } elseif ($Hogs.Bits) {
        $rows.Add((New-NsRow -Group 'Background' -Check 'BITS transfers' -Result 'not measured' -Basis 'not measured' -Status 'info' -Detail $Hogs.Bits.Reason))
    }

    if ($Hogs.Tcp -and $Hogs.Tcp.Ok) {
        foreach ($p in @($Hogs.Tcp.Processes | Select-Object -First 15)) {
            $isSelf = ($SelfPid -gt 0 -and $p.pid -eq $SelfPid)
            $name = $p.name
            $note = $p.note
            if ($isSelf) {
                $name = ('{0} (this tool)' -f $p.name)
                $note = 'This is the troubleshooter itself. Excluded from any verdict.'
            }
            $svc = ''
            if ($p.services) { $svc = (' [{0}]' -f $p.services) }
            $rows.Add((New-NsRow -Group 'Processes' -Check ('{0}{1}' -f $name, $svc) `
                -Result ('{0} connection(s)' -f $p.externalConns) -Basis 'inference' -Status 'info' `
                -Detail ('PID {0}, classified as {1}. Top remotes: {2}. {3}' -f $p.pid, $p.classification, (@($p.topRemotes) -join ', '), $note)))
        }
        if (@($Hogs.Tcp.Processes).Count -eq 0) {
            $rows.Add((New-NsRow -Group 'Processes' -Check 'External connections' -Result 'none' -Basis 'inference' -Status 'info' `
                -Detail 'No process on this PC currently holds a connection outside the local network. That does not mean the link is idle - another device on the LAN would not show up here.'))
        }
    }

    New-NsSection -State 'measured' `
        -Method 'Adapter counters sampled for total throughput; the TCP table grouped by owning process for attribution; Delivery Optimization and BITS read from their own counters.' `
        -Proxy 'Connection count is a proxy for bandwidth use. It is a good one for spotting sync clients and updaters, and a poor one for anything that moves a lot of data over a single connection.' `
        -Caveats ([string[]]$caveats) -Rows $rows `
        -Data ([pscustomobject]@{
            linkSample = $Hogs.Link
            processes  = $(if ($Hogs.Tcp) { $Hogs.Tcp.Processes } else { @() })
            deliveryOptimization = $Hogs.DO
            bits = $Hogs.Bits
            selfPid = $SelfPid
        })
}

function New-NsEtwSection {
    param($Etw)
    if (-not $Etw) { return New-NsSection -State 'skipped' -Reason 'The ETW deep capture was not run.' -Method '' }
    if ($Etw.State -ne 'measured') {
        return New-NsSection -State $Etw.State -Reason $Etw.Reason `
            -Method 'A private ETW session on the Microsoft-Windows-Kernel-Network provider, parsed for per-process byte counts.'
    }
    $rows = [Activator]::CreateInstance([System.Collections.Generic.List[object]])
    foreach ($p in @($Etw.Processes | Select-Object -First 20)) {
        $rows.Add((New-NsRow -Group 'Processes' -Check $p.name `
            -Result ('{0} ({1})' -f (Format-NsBytes $p.bytesTotal), (Format-NsMbps $p.mbpsAvg)) -Basis 'ETW bytes' -Status 'info' `
            -Detail ('PID {0}, sent {1}, received {2}, classified as {3}.' -f $p.pid, (Format-NsBytes $p.bytesSent), (Format-NsBytes $p.bytesReceived), $p.classification)))
    }
    if (@($Etw.Processes).Count -eq 0) {
        $rows.Add((New-NsRow -Group 'Processes' -Check 'Attributed traffic' -Result 'none in the window' -Basis 'ETW bytes' -Status 'info' `
            -Detail 'No process moved measurable traffic during the capture window.'))
    }
    New-NsSection -State 'measured' `
        -Method ('A private ETW session (logman -ets) on Microsoft-Windows-Kernel-Network for {0:N0}s, parsed for {1:N0} events. These are real per-process byte counts, not inference.' -f $Etw.CaptureSec, $Etw.EventsParsed) `
        -Caveats ([string[]]@(
            ('The capture is a {0:N0}-second SAMPLE. A process that happened to be idle during it reads zero, and "no bytes attributed in the window" is not the same as "no hog".' -f $Etw.CaptureSec),
            'Kernel-Network counts bytes at the TCP/UDP layer, so it excludes headers and retransmissions and sits roughly 3-6 percent below the adapter counters. The two are deliberately not reconciled.'
        )) -Rows $rows -Data $Etw
}

function New-NsWifiSection {
    param($Wifi)
    if (-not $Wifi) { return New-NsSection -State 'skipped' -Reason 'The Wi-Fi stage was not run.' -Method '' }
    if ($Wifi.State -ne 'measured') {
        return New-NsSection -State 'unsupported' -Reason $Wifi.Reason -Method 'netsh wlan show interfaces / show networks mode=bssid'
    }
    $i = $Wifi.Interface
    $rows = [Activator]::CreateInstance([System.Collections.Generic.List[object]])
    $sigStatus = 'ok'
    if ($null -ne $i.signalDbm -and $i.signalDbm -lt -75) { $sigStatus = 'fail' }
    elseif ($null -ne $i.signalDbm -and $i.signalDbm -lt -67) { $sigStatus = 'warn' }
    $rows.Add((New-NsRow -Group 'Radio' -Check 'Signal' -Result ('{0}% (about {1} dBm)' -f $i.signalPct, $i.signalDbm) -Basis 'measured' -Status $sigStatus `
        -Detail 'Windows reports signal as a percentage; the dBm value is the documented linear conversion of it, not an independent reading.'))
    $rows.Add((New-NsRow -Group 'Radio' -Check 'SSID / BSSID' -Result $i.ssid -Basis 'measured' -Status 'info' -Detail ('BSSID {0}, {1}, {2}' -f $i.bssid, $i.auth, $i.cipher)))
    $bandStatus = 'ok'
    if ($i.channel -gt 0 -and $i.channel -le 14) { $bandStatus = 'warn' }
    $rows.Add((New-NsRow -Group 'Radio' -Check 'Band / channel' -Result ('{0}, channel {1}' -f $i.band, $i.channel) -Basis 'measured' -Status $bandStatus -Detail $i.radioType))
    $rows.Add((New-NsRow -Group 'Radio' -Check 'Negotiated rate' -Result ('{0} / {1} Mbps' -f $i.rxMbps, $i.txMbps) -Basis 'measured' -Status 'info' `
        -Detail 'Receive / transmit PHY rate. This is a shared-airtime ceiling, not throughput - expect roughly half of it at best.'))
    if (-not $Wifi.Scanned) {
        $rows.Add((New-NsRow -Group 'Neighbourhood' -Check 'Co-channel access points' -Result 'not scanned' `
            -Basis 'not measured' -Status 'info' `
            -Detail 'No radio scan was run, so neighbouring access points were not counted. A scan takes a few seconds and briefly interrupts the radio, which is why it is not done on every sweep - run the Wi-Fi tab for it.'))
    } elseif ($Wifi.CoChannelCount -gt 0) {
        $ccStatus = 'ok'; if ($Wifi.CoChannelCount -ge 3) { $ccStatus = 'warn' }
        $rows.Add((New-NsRow -Group 'Neighbourhood' -Check 'Co-channel access points' -Result ('{0}' -f $Wifi.CoChannelCount) -Basis 'measured' -Status $ccStatus `
            -Detail 'Other access points broadcasting on the same channel. They share airtime with this client, which reduces real throughput without showing up as a fault anywhere.'))
    }
    foreach ($f in @($Wifi.Findings)) {
        $rows.Add((New-NsRow -Group 'Findings' -Check 'Observation' -Result '' -Basis 'measured' -Status 'info' -Detail $f))
    }
    New-NsSection -State 'measured' -Method 'netsh wlan show interfaces, plus a BSSID scan of the neighbourhood.' `
        -Caveats ([string[]]@('Parsed from netsh output, which is localised. On a non-English Windows this stage reports unsupported rather than guessing at translated labels.')) `
        -Rows $rows -Data $Wifi
}

function Get-NsPathSanity {
    # Does the route out of here look like the connection this site normally
    # uses, or like a backup?
    #
    # A machine on the LAN cannot see the firewall's WAN interfaces, so it
    # cannot KNOW it is on a failover link. What it can do is notice the
    # fingerprints a backup path leaves - a different public address, a smaller
    # path MTU, a carrier core that hides its hops, latency well above what this
    # site normally shows - and say which of those it found.
    #
    # It deliberately reports SIGNALS, not a carrier. "Two of the four things
    # that indicate a backup path are true, and here they are" is honest and
    # actionable. "You are on 4G" would be a guess dressed as a fact.
    param(
        $PathInfo = $null,          # from Get-NsPathInfo
        $Throughput = $null,        # from Invoke-CfThroughput (for cfL4 RTT)
        $History = $null,           # from Get-NsEgressHistory
        $EgressPath = $null,        # from Get-NsEgressPath
        [double]$IdleLatencyMs = -1 # measured idle latency to the internet
    )
    $out = [pscustomobject]@{
        Verdict = 'unknown'         # unknown | normal | watch | suspect
        Score = 0
        PublicIp = ''
        EgressDevice = ''
        Summary = 'The route has not been checked yet - run Quick Sweep.'
        Signals = @()
    }
    $sig = [Activator]::CreateInstance([System.Collections.Generic.List[object]])
    $add = {
        param([string]$Name, [bool]$Hit, [int]$Weight, [string]$Detail)
        $sig.Add([pscustomobject]@{ name = $Name; hit = $Hit; weight = $Weight; detail = $Detail })
        if ($Hit) { $script:nsSanityScore += $Weight }
    }
    $script:nsSanityScore = 0
    $haveAnything = $false

    # --- 1. is this the address the site normally uses? ---------------------
    $ip = ''
    if ($PathInfo -and $PathInfo.PublicIp) { $ip = [string]$PathInfo.PublicIp }
    $out.PublicIp = $ip
    if ($ip -and $History -and $History.State -eq 'measured' -and @($History.Addresses).Count -gt 0) {
        $haveAnything = $true
        $usual = @($History.Addresses)[0]
        $isUsual = ($usual.address -eq $ip)
        & $add 'Different public address than usual' (-not $isUsual) 3 (
            $(if ($isUsual) {
                ('{0} is the address this site has spent most of its time on ({1:N0} minutes of history).' -f $ip, $usual.minutes)
            } else {
                ('This site is presenting {0}, but it normally uses {1} ({2:N0} minutes of history against {3:N0}). That means it is out over a different internet connection than usual.' -f $ip, $usual.address, $usual.minutes, (@($History.Addresses | Where-Object { $_.address -eq $ip } | ForEach-Object { $_.minutes }) + 0)[0])
            }))
        # ...and is it slower than the usual one?
        if (-not $isUsual -and $IdleLatencyMs -gt 0 -and $usual.medianLatencyMs -gt 0) {
            $slower = ($IdleLatencyMs -gt ($usual.medianLatencyMs * 1.8))
            & $add 'Latency well above this site''s normal' $slower 2 (
                ('{0} ms now against {1} ms median on the usual address.' -f [math]::Round($IdleLatencyMs, 0), $usual.medianLatencyMs))
        }
    }

    # --- 1b. which box does traffic actually leave through? -----------------
    # On a site with more than one router this outranks the public address: it
    # names the physical device, it works when a lookup is blocked, and two
    # machines differing here are not being routed by the same box at all.
    if ($EgressPath -and $EgressPath.Ok) {
        $haveAnything = $true
        $out.EgressDevice = [string]$EgressPath.EgressDevice
        $usualDev = ''
        if ($History -and $History.State -eq 'measured') {
            foreach ($a in @($History.Addresses)) { if ($a.egressDevice -and -not $usualDev) { $usualDev = [string]$a.egressDevice } }
        }
        if ($usualDev) {
            $devChanged = ($usualDev -ne $out.EgressDevice)
            & $add 'Leaving through a different device than usual' $devChanged 3 (
                $(if ($devChanged) {
                    ('Traffic is leaving through {0}, but this machine normally goes out through {1}. That is a different piece of equipment, not just a different address.' -f $out.EgressDevice, $usualDev)
                } else { ('Leaving through {0}, the same device as usual.' -f $out.EgressDevice) }))
        }
        & $add 'Carrier-grade NAT in the path' ([bool]$EgressPath.Cgnat) 2 (
            $(if ($EgressPath.Cgnat) {
                'A hop in 100.64.0.0/10 means the carrier is NATting rather than routing this connection. Standard on mobile broadband, unusual on a business fixed service.'
            } else { 'No carrier NAT seen between here and the internet.' }))
    }

    # --- 2. path MTU below 1500 --------------------------------------------
    # A plain Ethernet path to the internet is 1500. Anything less means a
    # tunnel, PPPoE, or a mobile bearer sitting in the way.
    if ($PathInfo -and $PathInfo.PathMtu) {
        $m = $PathInfo.PathMtu
        if ($m.Ok -and $m.PathMtu -gt 0) {
            $haveAnything = $true
            # 1492 is 1500 minus the 8-byte PPPoE header, and PPPoE is how a
            # large share of DSL and FTTN services are delivered. Scoring it the
            # same as an arbitrary low MTU would put every PPPoE site
            # permanently one signal away from "suspect" for being configured
            # exactly as its carrier intended. It is reported, not counted.
            $isPppoe = ($m.PathMtu -eq 1492)
            & $add 'Path MTU below 1500' (($m.PathMtu -lt 1500) -and -not $isPppoe) 2 (
                $(if ($isPppoe) {
                    'Path MTU is 1492, which is 1500 minus the 8-byte PPPoE header. That is normal and expected on a PPPoE service - it is not a fault and is not counted against this route. What matters is that TCP MSS clamping is configured on the router so sessions negotiate 1452; without it, large transfers can stall while ping still works.'
                } elseif ($m.PathMtu -lt 1500) {
                    ('Path MTU is {0}. A direct Ethernet path to the internet is 1500, and this is not the 1492 that PPPoE explains - so something else is encapsulating this traffic: a tunnel, a VPN, or a mobile bearer.' -f $m.PathMtu)
                } else { 'Path MTU is 1500, which is what a direct path looks like.' }))
        } elseif (-not $m.Ok -and $m.Detail -match 'stalled|no answer') {
            $haveAnything = $true
            & $add 'Path MTU could not be measured (silent drops)' $true 2 (
                'Large packets are being dropped with no ICMP reply at all. That is a blackhole, and it is common on mobile bearers - transfers stall completely rather than merely running slowly.')
        }
    }

    # --- 3. a carrier core that hides its hops ------------------------------
    if ($PathInfo -and $PathInfo.Trace -and $PathInfo.Trace.Ok) {
        $hops = @($PathInfo.Trace.Hops)
        if ($hops.Count -gt 2) {
            $haveAnything = $true
            $run = 0; $maxRun = 0
            foreach ($h in $hops) {
                if ([int]$h.replies -eq 0) { $run++; if ($run -gt $maxRun) { $maxRun = $run } }
                else { $run = 0 }
            }
            & $add 'Consecutive hops that do not answer' ($maxRun -ge 3) 2 (
                $(if ($maxRun -ge 3) {
                    ('{0} hops in a row answered nothing before the path resumed. Fixed-line carriers normally answer TTL expiry; mobile packet cores normally do not, so a silent block in the middle of a trace points at a mobile bearer.' -f $maxRun)
                } else { 'No unusual block of silent hops in the trace.' }))
        }
    }

    # --- 4. the server's own view of round-trip time ------------------------
    if ($Throughput -and $Throughput.ServerTiming -and $Throughput.ServerTiming.L4) {
        $l4 = $Throughput.ServerTiming.L4
        if ($null -ne $l4.MinRttUs -and $l4.MinRttUs -gt 0) {
            $haveAnything = $true
            $minMs = [math]::Round(($l4.MinRttUs / 1000.0), 1)
            & $add 'High minimum round-trip to the CDN' ($minMs -gt 40) 1 (
                ('The server measured a minimum round trip of {0} ms. Fixed services in a capital city usually sit well under 30 ms; mobile bearers add 20-40 ms of their own before anything else.' -f $minMs))
        }
    }

    $out.Signals = $sig.ToArray()
    $out.Score = $script:nsSanityScore
    if (-not $haveAnything) { return $out }

    $hits = @($out.Signals | Where-Object { $_.hit })
    if ($out.Score -ge 3) {
        $out.Verdict = 'suspect'
        $out.Summary = ('This route looks like a BACKUP or tunnelled path, not the connection this site normally uses. {0} of {1} indicators are true. Every figure below describes THAT connection - check the router or firewall WAN status before drawing conclusions about the link.' -f $hits.Count, @($out.Signals).Count)
    } elseif ($out.Score -ge 1) {
        $out.Verdict = 'watch'
        $out.Summary = ('One thing about this route is unusual, though not enough to call it a backup path: {0}' -f (@($hits | ForEach-Object { $_.name }) -join '; '))
    } else {
        $out.Verdict = 'normal'
        $out.Summary = 'Nothing about this route suggests a backup or tunnelled path.'
        if ($out.PublicIp) { $out.Summary = ('{0} Presenting {1}.' -f $out.Summary, $out.PublicIp) }
        if ($out.EgressDevice) { $out.Summary = ('{0} Leaving through {1}.' -f $out.Summary, $out.EgressDevice) }
    }
    return $out
}

function New-NsSanityRows {
    # The signals as report rows, for folding into the path section.
    param($Sanity)
    $rows = [Activator]::CreateInstance([System.Collections.Generic.List[object]])
    if (-not $Sanity -or $Sanity.Verdict -eq 'unknown') { return $rows.ToArray() }
    $st = 'ok'
    if ($Sanity.Verdict -eq 'suspect') { $st = 'fail' } elseif ($Sanity.Verdict -eq 'watch') { $st = 'warn' }
    $rows.Add((New-NsRow -Group 'Route' -Check 'Does this look like the usual connection?' `
        -Result $Sanity.Verdict -Basis 'inference' -Status $st -Detail $Sanity.Summary))
    foreach ($s in @($Sanity.Signals)) {
        $rs = 'ok'
        if ($s.hit) { $rs = 'warn' }
        $rows.Add((New-NsRow -Group 'Route signal' -Check $s.name `
            -Result $(if ($s.hit) { 'yes' } else { 'no' }) -Basis 'inference' -Status $rs -Detail $s.detail))
    }
    return $rows.ToArray()
}

function New-NsPathSection {
    param($Path, $Sanity = $null, $EgressPath = $null, $Identities = $null)
    if (-not $Path) { return New-NsSection -State 'skipped' -Reason 'The path stage was not run.' -Method '' }
    $rows = [Activator]::CreateInstance([System.Collections.Generic.List[object]])

    if ($Path.Dns) {
        $d = $Path.Dns
        $st = 'ok'
        if ($d.State -eq 'failed') { $st = 'fail' }
        elseif ($null -ne $d.SlowerBy -and $d.SlowerBy -gt 80) { $st = 'warn' }
        $rows.Add((New-NsRow -Group 'DNS' -Check 'Resolver timing' -Result $(if ($d.State -eq 'failed') { 'FAILED' } else { 'compared' }) `
            -Basis $(if ($d.State -eq 'failed') { 'not measured' } else { 'measured' }) -Status $st -Detail ('{0} {1}' -f $d.Verdict, $d.Reason)))
        if ($d.Note) { $rows.Add((New-NsRow -Group 'DNS' -Check 'Resolver choice' -Result 'public resolver in use' -Basis 'measured' -Status 'info' -Detail $d.Note)) }
    }
    if ($Path.PublicIp) {
        $rows.Add((New-NsRow -Group 'Path' -Check 'Public egress IP' -Result $Path.PublicIp -Basis 'measured' -Status 'info' -Detail 'The address this site presents to the internet.'))
    }
    if ($Path.Trace -and $Path.Trace.Ok) {
        foreach ($h in @($Path.Trace.Hops)) {
            $label = $h.address
            if (-not $label) { $label = '*' }
            $rows.Add((New-NsRow -Group 'Traceroute' -Check ('Hop {0}' -f $h.hop) -Result $label -Basis $(if ($h.replies -gt 0) { 'measured' } else { 'not measured' }) -Status 'info' `
                -Detail ('min {0} / avg {1} / max {2} ms over {3} probe(s). {4}' -f $h.minMs, $h.avgMs, $h.maxMs, $h.replies, $h.note)))
        }
        if ($Path.Trace.Reason) {
            $rows.Add((New-NsRow -Group 'Traceroute' -Check 'Completion' -Result 'partial' -Basis 'not measured' -Status 'info' -Detail $Path.Trace.Reason))
        }
    }
    if ($Path.PathMtu) {
        $m = $Path.PathMtu
        $st = 'ok'; if ($m.Constrained) { $st = 'warn' }
        $rows.Add((New-NsRow -Group 'Path' -Check 'Path MTU' -Result $(if ($m.Ok) { ('{0} bytes' -f $m.PathMtu) } else { 'not measurable' }) `
            -Basis $(if ($m.Ok) { 'measured' } else { 'not measured' }) -Status $st -Detail $m.Detail))
    }
    if ($Path.Qos) {
        if ($Path.Qos.State -eq 'measured') {
            $rows.Add((New-NsRow -Group 'QoS' -Check 'Local QoS policies' -Result ('{0}' -f @($Path.Qos.Policies).Count) -Basis 'measured' -Status 'info' `
                -Detail 'Policies configured on this machine. Note that a local policy cannot fix a queue that forms in the router.'))
        } else {
            $rows.Add((New-NsRow -Group 'QoS' -Check 'Local QoS policies' -Result 'not measured' -Basis 'not measured' -Status 'info' -Detail $Path.Qos.Reason))
        }
    }
    # Route sanity last, so its signals sit under the evidence they are drawn from.
    # It goes in as ROWS and not into -Data on purpose: the collector's shedding
    # ladder reaches into $section.data.Trace / .Qos by name, so wrapping data in
    # another object silently stops it shedding. Rows are never shed, which is
    # where this belongs anyway.
    if ($EgressPath) { foreach ($r in @(New-NsEgressPathRows -EgressPath $EgressPath)) { $rows.Add($r) } }
    foreach ($d in @($Identities)) { if ($d) { foreach ($r in @(New-NsDeviceIdentityRows -Identity $d.Identity -Label $d.Label)) { $rows.Add($r) } } }
    if ($Sanity) { foreach ($r in @(New-NsSanityRows -Sanity $Sanity)) { $rows.Add($r) } }

    # Every other builder propagates the state of its input; this one used to
    # hard-code 'measured' whatever happened, so a section whose DNS failed and
    # whose traceroute never ran still claimed to be a measurement at envelope
    # level. Downgrade when nothing substantive came back.
    $pState = 'measured'
    $pReason = ''
    $dnsFailed = ($Path -and $Path.Dns -and $Path.Dns.State -eq 'failed')
    $traceOk   = ($Path -and $Path.Trace -and $Path.Trace.Ok)
    $mtuOk     = ($Path -and $Path.PathMtu -and $Path.PathMtu.Ok)
    if ($dnsFailed -and -not $traceOk -and -not $mtuOk) {
        $pState  = 'failed'
        $pReason = 'DNS comparison failed and neither the traceroute nor the path MTU probe returned anything. That combination is what a machine with no working path to the internet looks like, so nothing in this section should be read as a measurement of the path itself.'
    }
    New-NsSection -State $pState -Reason $pReason `
        -Method 'Per-hop latency by TTL-limited echo, DNS resolver timing compared against public resolvers on the same link, path MTU by DF-bit binary search, plus route, proxy and QoS configuration.' `
        -Rows $rows -Data $Path
}

function New-NsSoakSection {
    param($Soak)
    if (-not $Soak) { return New-NsSection -State 'skipped' -Reason 'The soak stage was not run.' -Method '' }
    $rows = [Activator]::CreateInstance([System.Collections.Generic.List[object]])
    $st = 'ok'; if ($Soak.OutageCount -gt 0) { $st = 'fail' }
    $rows.Add((New-NsRow -Group 'Soak' -Check 'Dropouts' -Result ('{0}' -f $Soak.OutageCount) `
        -Basis $(if ($Soak.State -eq 'measured') { 'measured' } else { 'withheld' }) -Status $st -Detail $Soak.DropoutVerdict))
    foreach ($o in @($Soak.Outages | Select-Object -First 20)) {
        $rows.Add((New-NsRow -Group 'Dropout' -Check $o.startedAt -Result ('{0}s offline' -f $o.durationSec) -Basis 'measured' -Status 'fail' `
            -Detail 'Five or more consecutive seconds with no reply. Match this timestamp against what the user reports.'))
    }
    if ($Soak.Latency) {
        foreach ($k in @($Soak.Latency.Keys | Sort-Object)) {
            $v = $Soak.Latency[$k]
            $rows.Add((New-NsRow -Group 'Latency over time' -Check $k -Result (Format-NsMs $v.p50Ms) -Basis 'measured' -Status 'info' `
                -Detail ('over {0} samples: min {1} / p95 {2} / max {3} ms, jitter {4} ms' -f $v.n, $v.minMs, $v.p95Ms, $v.maxMs, $v.jitterMs)))
        }
    }
    foreach ($t in @($Soak.ThroughputSamples)) {
        $rows.Add((New-NsRow -Group 'Throughput over time' -Check $t.at -Result (Format-NsMbps $t.mbps) -Basis 'measured' -Status 'info' `
            -Detail ('short 2-stream sample at {0} minutes in ({1})' -f $t.atMin, $t.state)))
    }
    New-NsSection -State $Soak.State -Reason $Soak.Reason `
        -Method ('Continuous 1 Hz reachability monitoring for {0:N1} minutes, with a dropout declared only after five consecutive seconds of silence, plus periodic short throughput samples.' -f $Soak.Minutes) `
        -Caveats ([string[]]@('A clean soak proves only that nothing happened while it was watching. An intermittent fault outside the window is not ruled out.')) `
        -Rows $rows -Data $Soak
}

function New-NsOoklaSection {
    param($Ookla)
    if (-not $Ookla) { return New-NsSection -State 'skipped' -Reason 'The Ookla test was not run.' -Method '' }
    if ($Ookla.State -ne 'measured') {
        return New-NsSection -State $Ookla.State -Reason $Ookla.Reason -Method 'Ookla speedtest CLI, JSON output.'
    }
    $rows = [Activator]::CreateInstance([System.Collections.Generic.List[object]])
    $rows.Add((New-NsRow -Group 'Ookla' -Check 'Download' -Result (Format-NsMbps $Ookla.DownMbps) -Basis 'vendor tool' -Status 'info' -Detail ('loaded latency {0} ms' -f $Ookla.DownLoadedMs)))
    $rows.Add((New-NsRow -Group 'Ookla' -Check 'Upload' -Result (Format-NsMbps $Ookla.UpMbps) -Basis 'vendor tool' -Status 'info' -Detail ('loaded latency {0} ms' -f $Ookla.UpLoadedMs)))
    $rows.Add((New-NsRow -Group 'Ookla' -Check 'Idle latency' -Result (Format-NsMs $Ookla.IdleLatencyMs) -Basis 'vendor tool' -Status 'info' -Detail ('jitter {0} ms, packet loss {1}%' -f $Ookla.IdleJitterMs, $Ookla.PacketLossPct)))
    $rows.Add((New-NsRow -Group 'Ookla' -Check 'Server / ISP' -Result ('{0} - {1}' -f $Ookla.ServerName, $Ookla.ServerLocation) -Basis 'vendor tool' -Status 'info' -Detail $Ookla.Isp))
    if ($Ookla.ResultUrl) {
        $rows.Add((New-NsRow -Group 'Ookla' -Check 'Result URL' -Result $Ookla.ResultUrl -Basis 'vendor tool' -Status 'info' `
            -Detail 'A shareable speedtest.net result. This is the figure an ISP will accept in a ticket.'))
    }
    New-NsSection -State 'measured' -Method 'Ookla speedtest CLI with JSON output, run against its own choice of nearby server.' `
        -Caveats ([string[]]@('A different measurement to a different server than the built-in engine uses. The two are not expected to agree exactly.')) `
        -Rows $rows -Data $Ookla
}

# ===========================================================================
#  Verdict
# ===========================================================================

function Get-NsSubscores {
    param($Adapter, $Throughput, $Latency, $Hogs, $Etw, $Wifi, $Path, $Soak, [double]$PlanDown = 0)
    $subs = [Activator]::CreateInstance([System.Collections.Generic.List[object]])

    # --- link / physical ---------------------------------------------------
    if ($Adapter -and $Adapter.name) {
        if (-not $Adapter.isWireless -and $Adapter.linkSpeedMbps -gt 0 -and $Adapter.linkSpeedMbps -lt 100) {
            $subs.Add((New-NsSubscore -Name 'Link / physical' -Level 'red' `
                -Summary ('the wired adapter has negotiated {0} Mbps, which caps everything else on this machine.' -f $Adapter.linkSpeedMbps) `
                -Remedy 'Replace the patch lead and try a different switch port before investigating anything upstream.'))
        } elseif ((-not $Adapter.isWireless) -and $null -ne $Adapter.fullDuplex -and -not $Adapter.fullDuplex) {
            # WIRED only. Wi-Fi is half duplex by design, and scoring that red
            # turned every wireless machine's overall verdict red for a
            # non-fault - worst-of-measured means one bogus red is enough.
            $subs.Add((New-NsSubscore -Name 'Link / physical' -Level 'red' `
                -Summary 'the wired adapter is running half duplex, which indicates an autonegotiation mismatch.' `
                -Remedy 'Set both the NIC and the switch port back to autonegotiate.'))
        } elseif ($Adapter.isWireless) {
            $subs.Add((New-NsSubscore -Name 'Link / physical' -Level 'green' `
                -Summary ('associated at {0} Mbps over Wi-Fi. Duplex is not meaningful on a radio, so it is not judged here - see the Wi-Fi section for signal quality, which is what limits a wireless link.' -f $Adapter.linkSpeedMbps)))
        } else {
            $subs.Add((New-NsSubscore -Name 'Link / physical' -Level 'green' -Summary ('link is {0} Mbps, full duplex.' -f $Adapter.linkSpeedMbps)))
        }
    } else {
        $subs.Add((New-NsSubscore -Name 'Link / physical' -Level 'notmeasured' -Summary 'no adapter information.'))
    }

    # --- throughput against the plan ---------------------------------------
    # Deliberately NOT graded when no plan was entered. Without a stated
    # expectation the tool has no basis for calling a number good or bad, and
    # inventing one would be the worst kind of false authority.
    if ($PlanDown -le 0) {
        $subs.Add((New-NsSubscore -Name 'Throughput vs plan' -Level 'notmeasured' `
            -Summary 'no service plan was entered, so there is nothing to judge the measured speed against.'))
    } elseif ($Throughput -and $Throughput.Ok) {
        $pct = ($Throughput.OverallMbps / $PlanDown) * 100.0
        if ($pct -lt 50) {
            $subs.Add((New-NsSubscore -Name 'Throughput vs plan' -Level 'red' `
                -Summary ('download is {0} against a stated {1:N0} Mbps plan, about {2:N0}% of it.' -f (Format-NsMbps $Throughput.OverallMbps), $PlanDown, $pct) `
                -Remedy 'Confirm with the Ookla button, then raise it with the ISP quoting the result URL.'))
        } elseif ($pct -lt 80) {
            $subs.Add((New-NsSubscore -Name 'Throughput vs plan' -Level 'amber' `
                -Summary ('download is {0}, about {1:N0}% of the stated plan.' -f (Format-NsMbps $Throughput.OverallMbps), $pct)))
        } else {
            $subs.Add((New-NsSubscore -Name 'Throughput vs plan' -Level 'green' `
                -Summary ('download is {0}, in line with the stated plan.' -f (Format-NsMbps $Throughput.OverallMbps))))
        }
    } else {
        $subs.Add((New-NsSubscore -Name 'Throughput vs plan' -Level 'notmeasured' -Summary 'no throughput figure was produced.'))
    }

    # --- latency under load -------------------------------------------------
    if ($Latency -and $Latency.GradeState -eq 'measured' -and $Latency.Grade) {
        $g = $Latency.Grade
        if ($g -eq 'D' -or $g -eq 'F') {
            $subs.Add((New-NsSubscore -Name 'Latency under load' -Level 'red' `
                -Summary ('latency rises by up to {0} ms when the link is busy (grade {1}), which will make calls and video conferencing break up regardless of the speed figure.' -f $Latency.WorstAddedMs, $g) `
                -Remedy 'Enable smart queue management (SQM/QoS) on the router, or fix whatever is capping the link.'))
        } elseif ($g -eq 'C') {
            $subs.Add((New-NsSubscore -Name 'Latency under load' -Level 'amber' `
                -Summary ('latency rises noticeably under load (grade {0}).' -f $g)))
        } else {
            $subs.Add((New-NsSubscore -Name 'Latency under load' -Level 'green' -Summary ('latency holds up under load (grade {0}).' -f $g)))
        }
    } else {
        $r = 'the bufferbloat test did not run.'
        if ($Latency -and $Latency.GradeReason) { $r = $Latency.GradeReason }
        $subs.Add((New-NsSubscore -Name 'Latency under load' -Level 'notmeasured' -Summary $r))
    }

    # --- contention ---------------------------------------------------------
    # Inference alone can never make this red. A process holding eight sockets
    # is a suspect; only a real byte counter convicts it.
    $measuredHog = $false
    $hogSummary = ''
    if ($Hogs -and $Hogs.DO -and $Hogs.DO.State -eq 'measured' -and $null -ne $Hogs.DO.DownlinkBps) {
        $doMbps = [double]$Hogs.DO.DownlinkBps * 8.0 / 1000000.0
        if ($doMbps -gt 2) {
            $measuredHog = $true
            $hogSummary = ('Delivery Optimization is pulling {0} right now.' -f (Format-NsMbps $doMbps))
        }
    }
    if ($Etw -and $Etw.State -eq 'measured' -and @($Etw.Processes).Count -gt 0) {
        $top = @($Etw.Processes)[0]
        if ($top.mbpsAvg -gt 2) {
            $measuredHog = $true
            $hogSummary = ('{0} moved {1} during the capture ({2} average).' -f $top.name, (Format-NsBytes $top.bytesTotal), (Format-NsMbps $top.mbpsAvg))
        }
    }
    if ($measuredHog) {
        $subs.Add((New-NsSubscore -Name 'Contention' -Level 'red' -Summary $hogSummary `
            -Remedy 'Pause or reschedule it, then re-run the speed test to see the link without it.'))
    } elseif ($Hogs -and $Hogs.DO -and $Hogs.DO.ActiveJobs -gt 0) {
        $subs.Add((New-NsSubscore -Name 'Contention' -Level 'amber' `
            -Summary ('{0} Delivery Optimization job(s) are in progress with {1} still to fetch, though not much is moving at this moment.' -f $Hogs.DO.ActiveJobs, (Format-NsBytes $Hogs.DO.ActiveRemainingBytes)) `
            -Remedy 'Expect this to consume the link later. Consider setting an update deferral or a DO bandwidth cap by policy.'))
    } elseif ($Hogs) {
        $subs.Add((New-NsSubscore -Name 'Contention' -Level 'green' -Summary 'nothing on this PC appears to be consuming the link.'))
    } else {
        $subs.Add((New-NsSubscore -Name 'Contention' -Level 'notmeasured' -Summary 'the hog scan did not run.'))
    }

    # --- path / DNS ---------------------------------------------------------
    if ($Path -and $Path.Dns) {
        if ($Path.Dns.State -eq 'failed') {
            $subs.Add((New-NsSubscore -Name 'Path / DNS' -Level 'red' -Summary 'name resolution is failing on this machine.' `
                -Remedy 'Fix DNS first - broken resolution presents as "the internet is down" no matter how good the link is.'))
        } elseif ($null -ne $Path.Dns.SlowerBy -and $Path.Dns.SlowerBy -gt 80) {
            $subs.Add((New-NsSubscore -Name 'Path / DNS' -Level 'amber' `
                -Summary ('the configured DNS server is about {0} ms slower per lookup than a public resolver on the same link.' -f $Path.Dns.SlowerBy) `
                -Remedy 'Every page load pays that delay several times over. Worth investigating the resolver.'))
        } else {
            $subs.Add((New-NsSubscore -Name 'Path / DNS' -Level 'green' -Summary 'DNS resolves promptly and the path looks normal.'))
        }
    } else {
        $subs.Add((New-NsSubscore -Name 'Path / DNS' -Level 'notmeasured' -Summary 'the path checks did not run.'))
    }

    # --- wireless -----------------------------------------------------------
    # Only judge the radio when the radio is CARRYING THE TRAFFIC.
    #
    # Windows does not disassociate Wi-Fi when a dock's Ethernet comes up, so a
    # docked laptop routinely reports a measured, weak wireless interface that
    # is moving nothing. Scoring that red turned the whole report red - the
    # verdict is worst-of-measured - and made a -80 dBm idle radio the headline
    # on a machine doing 1 Gbps over copper. Same mistake as judging duplex on
    # a radio, in the opposite direction.
    $wifiIsPath = ($Adapter -and $Adapter.isWireless)
    if ($Wifi -and $Wifi.State -eq 'measured' -and $wifiIsPath) {
        $i = $Wifi.Interface
        # signalDbm is DERIVED from the percentage Windows reports, not read
        # from the radio, so the summary says so - the row already did.
        if ($null -ne $i.signalDbm -and $i.signalDbm -lt -75) {
            $subs.Add((New-NsSubscore -Name 'Wireless' -Level 'red' -Summary ('Wi-Fi signal works out at about {0} dBm (derived from the percentage Windows reports, not read from the radio), which is too weak for reliable throughput.' -f $i.signalDbm) `
                -Remedy 'Move closer to the access point, or add one. No amount of internet bandwidth fixes a weak radio link.'))
        } elseif (($i.channel -gt 0 -and $i.channel -le 14) -or ($Wifi.Scanned -and $Wifi.CoChannelCount -ge 3)) {
            $subs.Add((New-NsSubscore -Name 'Wireless' -Level 'amber' `
                -Summary 'the client is on a congested or low-band channel, which costs throughput before the internet link is even involved.' `
                -Remedy 'Move the client to 5 GHz, or change the access point''s channel.'))
        } else {
            $subs.Add((New-NsSubscore -Name 'Wireless' -Level 'green' -Summary 'the wireless link looks healthy.'))
        }
    } elseif ($Wifi -and $Wifi.State -eq 'measured' -and -not $wifiIsPath) {
        $subs.Add((New-NsSubscore -Name 'Wireless' -Level 'notmeasured' `
            -Summary 'this machine has an associated Wi-Fi radio, but it is not the adapter being tested - the traffic is going over the wired link, so the radio is reported in the Wi-Fi section and not judged here.'))
    } else {
        $r = 'this machine is not on Wi-Fi.'
        if ($Wifi -and $Wifi.Reason) { $r = $Wifi.Reason }
        $subs.Add((New-NsSubscore -Name 'Wireless' -Level 'notmeasured' -Summary $r))
    }

    # --- stability ----------------------------------------------------------
    if ($Soak -and $Soak.State -eq 'measured') {
        if ($Soak.OutageCount -gt 0) {
            $subs.Add((New-NsSubscore -Name 'Stability' -Level 'red' `
                -Summary ('{0} dropout(s) in {1:N0} minutes of monitoring.' -f $Soak.OutageCount, $Soak.Minutes) `
                -Remedy 'Match the timestamps against the user''s account, then take it to the ISP or the on-site hardware.'))
        } else {
            $subs.Add((New-NsSubscore -Name 'Stability' -Level 'green' -Summary ('no dropouts in {0:N0} minutes of monitoring.' -f $Soak.Minutes)))
        }
    } else {
        $r = 'no soak was run, so intermittent faults are neither confirmed nor ruled out.'
        if ($Soak -and $Soak.Reason) { $r = $Soak.Reason }
        $subs.Add((New-NsSubscore -Name 'Stability' -Level 'notmeasured' -Summary $r))
    }

    return [object[]]@($subs)
}

# ===========================================================================
#  JSON envelope
# ===========================================================================

function Get-NsJsonMarkers { @{ Begin = '<<<NETSPEED_JSON_BEGIN>>>'; End = '<<<NETSPEED_JSON_END>>>' } }

function New-NsReport {
    param(
        $Context, $Adapter, $Sections, $Verdict,
        [datetime]$StartedUtc = [datetime]::MinValue,
        [double]$DurationSec = 0,
        [string]$Mode = 'gui',
        [double]$PlanDown = 0, [double]$PlanUp = 0,
        $Log = @()
    )
    $lim = Get-NsLimits
    [pscustomobject]@{
        schema        = 'netspeed-diagnostic'
        schemaVersion = 1
        tool = [pscustomobject]@{
            name = 'NetSpeed Troubleshooter'
            version = (Get-NetSpeedVersion)
            mode = $Mode
            engineCeilingMbps = $lim.EngineCeilingMbps
        }
        collectedUtc = (ConvertTo-NsIso8601 (Get-Date))
        startedUtc   = (ConvertTo-NsIso8601 $StartedUtc)
        durationSec  = [math]::Round($DurationSec, 2)
        host         = $Context
        network      = [pscustomobject]@{ adapter = $Adapter }
        planMbps     = [pscustomobject]@{ down = $PlanDown; up = $PlanUp; stated = (($PlanDown -gt 0) -or ($PlanUp -gt 0)) }
        sections     = $Sections
        verdict      = $Verdict
        knownLimits  = (Get-NsKnownLimits)
        log          = [object[]]@($Log)
    }
}

function ConvertTo-NsJson {
    # -Depth 12 is not a preference. ConvertTo-Json defaults to 2 and silently
    # renders anything deeper as the literal string "System.Object[]", which
    # produces a file that looks fine and carries none of the data.
    param($Object, [switch]$Compress)
    if ($Compress) { return ($Object | ConvertTo-Json -Depth 12 -Compress) }
    return ($Object | ConvertTo-Json -Depth 12)
}

function Format-NsJsonEnvelope {
    # Fenced so the future Atera collector's console output can be scraped by
    # a renderer without having to guess where the JSON starts.
    param($Report, [switch]$Compress)
    $m = Get-NsJsonMarkers
    $json = ConvertTo-NsJson -Object $Report -Compress:$Compress
    return ('{0}{1}{2}{1}{3}' -f $m.Begin, [Environment]::NewLine, $json, $m.End)
}

function Invoke-NsLatencyAndThroughput {
    # Runs idle baseline, then loaded download, then loaded upload, sharing one
    # set of probes with the transfers so the loaded figures are genuinely
    # concurrent with the load rather than measured next to it.
    #
    # Returns BOTH the throughput results and the bufferbloat analysis, so the
    # caller never has to saturate the customer's link twice to get both.
    param(
        [string]$Gateway     = '',
        [double]$IdleSec     = 5.0,
        [int]$Streams        = 6,
        [double]$DownSec     = 10.0,
        [double]$UpSec       = 8.0,
        [double]$EstMbps     = 0,
        $Shared              = $null,
        [string]$VersionKey  = '',
        [switch]$BypassProxy,
        [switch]$Wwan,
        [string]$WwanBasis = '',
        [switch]$SkipUpload,
        [string]$StatusPrefix = ''
    )
    $ep = Get-NsCfEndpoints
    $icmp = [Activator]::CreateInstance([System.Collections.Generic.List[string]])
    if ($Gateway) { $icmp.Add($Gateway) }
    $icmp.Add('1.1.1.1')

    $out = [pscustomobject]@{
        GatewayKey   = $Gateway
        Idle         = $null
        LoadedDown   = $null
        LoadedUp     = $null
        Down         = $null
        Up           = $null
        DownIncreaseMs = $null
        UpIncreaseMs   = $null
        WorstAddedMs   = $null
        Grade          = ''
        GradeState     = 'measured'
        GradeReason    = ''
        GradeCause     = ''
        Queue          = $null
        Cancelled      = $false
    }

    # ---- 1. idle baseline ---------------------------------------------------
    $out.Idle = Measure-NsIdleLatency -IcmpTargets ([string[]]$icmp) -HttpUrl $ep.Latency `
                    -Seconds $IdleSec -Shared $Shared -BypassProxy:$BypassProxy -StatusPrefix $StatusPrefix
    if ($Shared -and $Shared.Cancel) { $out.Cancelled = $true; return $out }
    if ($VersionKey -and $Shared) { $Shared.$VersionKey = [int]$Shared.$VersionKey + 1 }

    # ---- 2. loaded download -------------------------------------------------
    $bagDown = New-NsProbeBag -IcmpTargets ([string[]]$icmp) -HttpUrl $ep.Latency -BypassProxy:$BypassProxy
    $out.Down = Invoke-CfThroughput -Direction 'Down' -Streams $Streams -MeasureSec $DownSec `
                    -EstMbps $EstMbps -Shared $Shared -VersionKey $VersionKey -ProbeBag $bagDown `
                    -BypassProxy:$BypassProxy -Wwan:$Wwan -WwanBasis $WwanBasis -StatusPrefix $StatusPrefix
    Close-NsProbeBag -Bag $bagDown -Stopwatch ([System.Diagnostics.Stopwatch]::StartNew())
    $out.LoadedDown = Get-NsProbeSummary -Bag $bagDown
    if ($Shared -and $Shared.Cancel) { $out.Cancelled = $true; return $out }

    # ---- 3. loaded upload ---------------------------------------------------
    if (-not $SkipUpload) {
        $estUp = $EstMbps
        if ($out.Down -and $out.Down.Ok -and $out.Down.OverallMbps -gt 0) { $estUp = $out.Down.OverallMbps }
        $bagUp = New-NsProbeBag -IcmpTargets ([string[]]$icmp) -HttpUrl $ep.Latency -BypassProxy:$BypassProxy
        $out.Up = Invoke-CfThroughput -Direction 'Up' -Streams $Streams -MeasureSec $UpSec `
                        -EstMbps $estUp -Shared $Shared -VersionKey $VersionKey -ProbeBag $bagUp `
                        -BypassProxy:$BypassProxy -Wwan:$Wwan -WwanBasis $WwanBasis -StatusPrefix $StatusPrefix
        Close-NsProbeBag -Bag $bagUp -Stopwatch ([System.Diagnostics.Stopwatch]::StartNew())
        $out.LoadedUp = Get-NsProbeSummary -Bag $bagUp
    }
    if ($Shared -and $Shared.Cancel) { $out.Cancelled = $true }

    # ---- 4. analysis --------------------------------------------------------
    $lim = Get-NsLimits
    $refKey = '1.1.1.1'
    $idleN  = 0
    if ($out.Idle -and $out.Idle.ContainsKey($refKey)) { $idleN = $out.Idle[$refKey].n }

    # EVERY refusal path must set GradeCause. Get-NsQueueLocation keys off it to
    # decide whether it may speak, and a blank cause let the queue analysis
    # print "the fix is smart queue management on the router" from the very
    # baseline this branch just declared unusable.
    if ($idleN -lt $lim.MinLatencySamples) {
        $out.GradeState  = 'refused'
        $out.GradeCause  = 'baseline-too-few-samples'
        $out.GradeReason = ('The idle baseline returned only {0} replies (minimum {1}). Without a trustworthy baseline there is nothing to measure an increase against, so no grade is given.' -f $idleN, $lim.MinLatencySamples)
    } elseif ($out.Idle[$refKey].p50Ms -gt 400) {
        # At this point ICMP is being rate-limited or the path is already
        # saturated by something else. Either way the "baseline" is not one.
        $out.GradeState  = 'refused'
        $out.GradeCause  = 'baseline-not-idle'
        $out.GradeReason = ('Idle latency to 1.1.1.1 was already {0} ms before any load was applied. That is not a usable baseline - either ICMP is being rate-limited, or something else was already saturating this link.' -f $out.Idle[$refKey].p50Ms)
    } else {
        $idleP50 = [double]$out.Idle[$refKey].p50Ms
        $worst = $null
        if ($out.LoadedDown -and $out.LoadedDown.ContainsKey($refKey) -and $out.LoadedDown[$refKey].n -ge 5) {
            $out.DownIncreaseMs = [math]::Round(([double]$out.LoadedDown[$refKey].p50Ms - $idleP50), 1)
            $worst = [double]$out.LoadedDown[$refKey].p95Ms
        }
        if ($out.LoadedUp -and $out.LoadedUp.ContainsKey($refKey) -and $out.LoadedUp[$refKey].n -ge 5) {
            $out.UpIncreaseMs = [math]::Round(([double]$out.LoadedUp[$refKey].p50Ms - $idleP50), 1)
            $p95 = [double]$out.LoadedUp[$refKey].p95Ms
            if ($null -eq $worst -or $p95 -gt $worst) { $worst = $p95 }
        }
        if ($null -eq $out.DownIncreaseMs -and $null -eq $out.UpIncreaseMs) {
            $out.GradeState  = 'refused'
            $diag = Get-NsLoadedProbeDiagnosis -Down $out.Down -Up $out.Up `
                        -LoadedDown $out.LoadedDown -LoadedUp $out.LoadedUp `
                        -RefKey $refKey -MinSamples 5
            $out.GradeReason = $diag.Reason
            $out.GradeCause  = $diag.Cause
        } else {
            if ($null -ne $worst) { $out.WorstAddedMs = [math]::Round(($worst - $idleP50), 1) }
            $peak = 0.0
            if ($null -ne $out.DownIncreaseMs -and $out.DownIncreaseMs -gt $peak) { $peak = $out.DownIncreaseMs }
            if ($null -ne $out.UpIncreaseMs   -and $out.UpIncreaseMs   -gt $peak) { $peak = $out.UpIncreaseMs }
            $out.Grade = Get-NsBufferbloatGrade -IncreaseMs $peak
        }
    }

    # Worst of the two loaded phases drives the queue-location call, because a
    # link can be clean downstream and appalling upstream.
    $loadedWorst = $out.LoadedDown
    if ($out.LoadedUp -and $out.LoadedUp.ContainsKey($refKey)) {
        if (-not $loadedWorst -or -not $loadedWorst.ContainsKey($refKey) -or
            $out.LoadedUp[$refKey].p50Ms -gt $loadedWorst[$refKey].p50Ms) {
            $loadedWorst = $out.LoadedUp
        }
    }
    if ($out.Idle -and $loadedWorst) {
        # Keyed on GradeState alone. Requiring GradeCause as well meant a
        # refusal that forgot to set one silently re-enabled the confident
        # answer - the failure mode should be silence, not confidence.
        $qDiag = $null
        if ($out.GradeState -eq 'refused') {
            $cause = $out.GradeCause
            if (-not $cause) { $cause = 'refused' }
            $qDiag = [pscustomobject]@{ Cause = $cause; Reason = $out.GradeReason }
        }
        $out.Queue = Get-NsQueueLocation -Idle $out.Idle -Loaded $loadedWorst -GatewayKey $Gateway -Diagnosis $qDiag
    }
    return $out
}
