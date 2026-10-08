<#
    Showcase fixture, capture and privacy gate - dot-sourced into a PATCHED
    COPY of the GUI immediately before ShowDialog, by
    tools\New-NetSpeedShowcase.ps1. Never loaded by the shipping GUI.

    Builds the raw stage results a real run would leave in $script:R and lets
    the GUI's OWN code turn them into sections, subscores, banners and the
    report: New-NsLatencySection, Get-NsSubscores, Get-NsQueueLocation,
    Get-NsBufferbloatGrade, Get-NsPathSanity, Get-NsProcessClass and the rest
    are the real functions. Only the inputs are invented, so every row's
    wording, basis and colour is exactly what the tool would print.

    The story it tells: a front-desk PC where calls break up. The link and the
    download are fine; OneDrive is saturating the upload, which drags latency
    up by a few hundred ms (bufferbloat grade D), Windows Update has more to
    pull, and the router's DNS is slow.

    Writes manifest.json to $script:ShowcaseWork and closes the window.
#>

$script:ShowManifest = [ordered]@{ ok = $false; error = ''; seed = $script:ShowcaseSeed; host = $script:Showcase.Host; captures = @(); scan = $null }
function Write-ShowManifest {
    $script:ShowManifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $script:ShowcaseWork 'manifest.json') -Encoding UTF8
}

try {
    $sx = $script:Showcase
    $gw = $sx.Gw
    $base = New-Object System.DateTime(2026, 10, 6, 14, 31, 52)
    $baseUtc = $base.ToUniversalTime()

    # ---- probe summaries (Get-NsProbeSummary's shape) ------------------------
    function New-ShowProbe {
        param([double]$P50, [double]$Spread, [int]$N = 25, [switch]$Http)
        $q = { param($v) if ($Http) { [math]::Round($v, 1) } else { [math]::Round($v, 0) } }
        $basis = 'stack RoundtripTime - not affected by this tool''s polling'
        $noise = 0.0
        if ($Http) { $basis = 'polled wall-clock - an upper bound that includes this tool''s own poll delay'; $noise = 1.8 }
        [pscustomobject]@{
            n = $N; sent = $N; skipped = 0; lost = 0; lossPct = 0
            minMs = (& $q ([math]::Max(0.0, $P50 - ($Spread * 0.3))))
            p50Ms = (& $q $P50)
            p95Ms = (& $q ($P50 + $Spread))
            maxMs = (& $q ($P50 + ($Spread * 1.4)))
            jitterMs = [math]::Round(($Spread / 6.0), 1)
            noiseFloorMs = $noise; noiseMaxMs = [math]::Round(($noise * 2.5), 1)
            usable = $true; basis = $basis
        }
    }
    $idleWan  = [double](Get-ShowInt 9 13)
    $idleHttp = [math]::Round($idleWan + (Get-ShowDbl 8 12), 1)
    $incDown  = [double](Get-ShowInt 28 44)
    $incUp    = [double](Get-ShowInt 255 315)
    $idle = @{}
    $idle[$gw]       = New-ShowProbe -P50 1 -Spread 1
    $idle['1.1.1.1'] = New-ShowProbe -P50 $idleWan -Spread 3
    $idle['http']    = New-ShowProbe -P50 $idleHttp -Spread 5 -N 24 -Http
    $ldn = @{}
    $ldn[$gw]        = New-ShowProbe -P50 1 -Spread 2 -N 48
    $ldn['1.1.1.1']  = New-ShowProbe -P50 ($idleWan + $incDown) -Spread (Get-ShowInt 18 30) -N 48
    $ldn['http']     = New-ShowProbe -P50 ($idleHttp + $incDown + (Get-ShowDbl 4 9)) -Spread 22 -N 46 -Http
    $lup = @{}
    $lup[$gw]        = New-ShowProbe -P50 2 -Spread 2 -N 48
    $lup['1.1.1.1']  = New-ShowProbe -P50 ($idleWan + $incUp) -Spread (Get-ShowInt 60 95) -N 48
    $lup['http']     = New-ShowProbe -P50 ($idleHttp + $incUp + (Get-ShowDbl 6 14)) -Spread 90 -N 45 -Http

    # ---- throughput (Invoke-CfThroughput's shape) ---------------------------
    $meta = [pscustomobject]@{
        ClientIp = $sx.Pub; Colo = $sx.Colo; Asn = $sx.Asn; City = $sx.City; Country = $sx.Country; CfRay = ''
        EdgeMs = 0.4; WorkerMs = 1.1
        L4 = [pscustomobject]@{ Proto = 'TCP'; RttUs = (Get-ShowInt 13000 16500); MinRttUs = (Get-ShowInt 9800 11800); RttVarUs = 2100
                                Lost = 0; Retrans = (Get-ShowInt 4 14); Cwnd = (Get-ShowInt 2600 3400); DeliveryRateRaw = '' }
    }
    function New-ShowThroughput {
        param([string]$Dir, [double]$Center, [double]$Noise, [double]$Overall)
        $vals = [Activator]::CreateInstance([System.Collections.Generic.List[double]])
        for ($i = 0; $i -lt 80; $i++) {
            $g = ($script:ShowRng.NextDouble() + $script:ShowRng.NextDouble() + $script:ShowRng.NextDouble() - 1.5)
            $vals.Add([math]::Max(0.1, $Center + ($g * $Noise * 1.6)))
        }
        $arr = $vals.ToArray()
        $tb = [math]::Round($Overall * 1000000.0 / 8.0 * 12.0)
        [pscustomobject]@{
            Direction = $Dir; Ok = $true; State = 'measured'; Reason = ''
            Samples = $arr; Stats = (Get-NsStats -Values $arr); OverallMbps = $Overall
            BurstyWindows = $false; PercentileWithheld = $false; EndpointRefused = $false
            TotalBytes = $tb; MeasuredBytes = [math]::Round($tb * 0.83); WarmupBytes = [math]::Round($tb * 0.17); MeasuredSec = 10.0
            StreamsRequested = 6; StreamsEstablished = 6; PerStreamBytes = @(); Restarts = 0
            Meta = $meta; ServerTiming = [pscustomobject]@{ EdgeMs = $meta.EdgeMs; WorkerMs = $meta.WorkerMs; L4 = $meta.L4 }
            WindowMs = 100; WarmupSec = (Get-NsLimits).WarmupSec; CapHit = ''; Cancelled = $false; WwanProfile = $false; WwanBasis = ''
        }
    }
    $downC = Get-ShowDbl 445 462
    $upC   = Get-ShowDbl 18.6 20.2
    $down = New-ShowThroughput -Dir 'Down' -Center $downC -Noise 14 -Overall ([math]::Round($downC - (Get-ShowDbl 8 14), 1))
    $up   = New-ShowThroughput -Dir 'Up'   -Center $upC   -Noise 0.9 -Overall ([math]::Round($upC - (Get-ShowDbl 0.8 1.4), 1))

    # ---- latency result, analysed by the REAL rules -------------------------
    $lat = [pscustomobject]@{
        GatewayKey = $gw; Idle = $idle; LoadedDown = $ldn; LoadedUp = $lup; Down = $down; Up = $up
        DownIncreaseMs = [math]::Round(($ldn['1.1.1.1'].p50Ms - $idle['1.1.1.1'].p50Ms), 1)
        UpIncreaseMs   = [math]::Round(($lup['1.1.1.1'].p50Ms - $idle['1.1.1.1'].p50Ms), 1)
        WorstAddedMs   = [math]::Round(([math]::Max($ldn['1.1.1.1'].p95Ms, $lup['1.1.1.1'].p95Ms) - $idle['1.1.1.1'].p50Ms), 1)
        Grade = ''; GradeState = 'measured'; GradeReason = ''; GradeCause = ''; Queue = $null; Cancelled = $false
    }
    $lat.Grade = Get-NsBufferbloatGrade -IncreaseMs ([math]::Max($lat.DownIncreaseMs, $lat.UpIncreaseMs))
    $lat.Queue = Get-NsQueueLocation -Idle $idle -Loaded $lup -GatewayKey $gw

    # ---- what is on this PC -------------------------------------------------
    $docIp = { param($i) (Get-ShowPick @('192.0.2','198.51.100','203.0.113')) + '.' + (Get-ShowInt 1 254) + ':443' }
    $procDefs = @(
        @{ n='OneDrive';                    c=(Get-ShowInt 13 17); s='' },
        @{ n='ms-teams';                    c=(Get-ShowInt 9 12);  s='' },
        @{ n='msedge';                      c=(Get-ShowInt 8 11);  s='' },
        @{ n='OUTLOOK';                     c=(Get-ShowInt 5 7);   s='' },
        @{ n='svchost';                     c=(Get-ShowInt 4 6);   s='DoSvc' },
        @{ n='AteraAgent';                  c=(Get-ShowInt 3 4);   s='' },
        @{ n='MsMpEng';                     c=(Get-ShowInt 2 3);   s='' },
        @{ n='Spotify';                     c=(Get-ShowInt 2 3);   s='' },
        @{ n='ScreenConnect.ClientService'; c=2;                   s='' },
        @{ n='SearchHost';                  c=(Get-ShowInt 1 2);   s='' },
        @{ n='WINWORD';                     c=1;                   s='' },
        @{ n='powershell';                  c=2;                   s='' }
    )
    $procs = [Activator]::CreateInstance([System.Collections.Generic.List[object]])
    $pids = @{}
    foreach ($d in $procDefs) {
        $procId = $PID
        if ($d.n -ne 'powershell') { $procId = Get-ShowInt 1200 29000 }
        $pids[$d.n] = $procId
        $rem = @(1..([math]::Min(3, $d.c)) | ForEach-Object { & $docIp $_ })
        $procs.Add([pscustomobject]@{
            pid = $procId; name = $d.n; path = ''; services = $d.s; externalConns = $d.c
            topRemotes = [object[]]$rem
            classification = (Get-NsProcessClass -Name $d.n -Services $d.s)
            bytes = $null; basis = 'inference'
            note = 'Connection count only. This tool cannot attribute bytes to a process without the ETW deep capture.'
        })
    }
    $procArr = @($procs | Sort-Object -Property externalConns -Descending)
    $connTotal = 0; foreach ($p in $procArr) { $connTotal += $p.externalConns }
    $hogs = [pscustomobject]@{
        Link = [pscustomobject]@{ Ok = $true; DownMbps = (Get-ShowDbl 2.5 5.5); UpMbps = (Get-ShowDbl 16.2 18.4); InErrors = 0; OutDiscards = 0; Seconds = 3.02; Detail = '' }
        Tcp  = [pscustomobject]@{ Ok = $true; Processes = $procArr; Total = $connTotal; Detail = '' }
        DO   = [pscustomobject]@{ State = 'measured'; Reason = ''; ActiveJobs = 2; TotalJobs = 9
                                  ActiveRemainingBytes = [double](Get-ShowInt 1600 2100) * 1MB; TotalBytes = 4.2GB; CachedBytes = 1.1GB
                                  FromHttp = 2.31GB; FromLanPeers = 0; ToLanPeers = 0; DownlinkBps = [double](Get-ShowInt 150000 210000); Jobs = @(); Detail = '' }
        Bits = [pscustomobject]@{ State = 'measured'; Reason = ''; TransferringJobs = 1; TotalJobs = 4; RemainingBytes = 84MB; Jobs = @(); Caveat = '' }
        SelfPid = $PID
    }

    # ---- ETW: who actually moved the bytes ----------------------------------
    $etwDefs = @(
        @{ n='OneDrive'; s=(Get-ShowDbl 34 39) * 1MB; r=(Get-ShowDbl 1.2 2.0) * 1MB },
        @{ n='ms-teams'; s=(Get-ShowDbl 2.4 3.1) * 1MB; r=(Get-ShowDbl 3.0 3.8) * 1MB },
        @{ n='msedge';   s=(Get-ShowDbl 0.3 0.6) * 1MB; r=(Get-ShowDbl 3.2 4.4) * 1MB },
        @{ n='svchost';  s=(Get-ShowDbl 0.1 0.2) * 1MB; r=(Get-ShowDbl 2.6 3.4) * 1MB },
        @{ n='OUTLOOK';  s=(Get-ShowDbl 0.2 0.4) * 1MB; r=(Get-ShowDbl 0.8 1.3) * 1MB },
        @{ n='MsMpEng';  s=(Get-ShowDbl 0.05 0.1) * 1MB; r=(Get-ShowDbl 0.2 0.5) * 1MB },
        @{ n='AteraAgent'; s=(Get-ShowDbl 0.05 0.1) * 1MB; r=(Get-ShowDbl 0.1 0.2) * 1MB }
    )
    $etwProcs = [Activator]::CreateInstance([System.Collections.Generic.List[object]])
    $etwTotal = 0.0
    foreach ($d in $etwDefs) {
        $t = [math]::Round($d.s + $d.r)
        $etwTotal += $t
        $svc = ''; if ($d.n -eq 'svchost') { $svc = 'DoSvc' }
        $etwProcs.Add([pscustomobject]@{
            pid = $pids[$d.n]; name = $d.n; bytesSent = [math]::Round($d.s); bytesReceived = [math]::Round($d.r); bytesTotal = $t
            mbpsAvg = [math]::Round(($t * 8.0 / 20.0 / 1000000.0), 2)
            classification = (Get-NsProcessClass -Name $d.n -Services $svc); basis = 'ETW bytes'
        })
    }
    $etw = [pscustomobject]@{
        State = 'measured'; Reason = ''; Processes = @($etwProcs | Sort-Object -Property bytesTotal -Descending)
        TotalBytes = $etwTotal; EventsParsed = (Get-ShowInt 38000 46000); CaptureSec = 20.0; ParseSec = 6.4; Cancelled = $false; EtlSizeBytes = 31.2MB
    }

    # ---- path ---------------------------------------------------------------
    $cfgMs = [math]::Round((Get-ShowDbl 96 128), 1)
    $pubMs = [math]::Round((Get-ShowDbl 9 13), 1)
    $slower = [math]::Round(($cfgMs - $pubMs), 1)
    $dns = [pscustomobject]@{
        State = 'measured'; Reason = ''
        Default = [pscustomobject]@{ Server = $gw; MedianMs = $cfgMs }
        Configured = @([pscustomobject]@{ Server = $gw; MedianMs = $cfgMs })
        Public = @([pscustomobject]@{ Server = '1.1.1.1'; MedianMs = $pubMs })
        Verdict = ('Configured DNS ({0}) resolves in {1} ms median against {2} ms for {3} on the same link at the same moment - about {4} ms slower per lookup. A page that touches a dozen hostnames pays that delay every time, and it presents as slowness that no speed test explains.' -f $gw, $cfgMs, $pubMs, '1.1.1.1', [math]::Round($slower, 0))
        SlowerBy = $slower; ConfiguredIsPublic = $false; Note = ''; InterceptSuspected = $false
    }
    $hopRow = { param($n, $addr, $ms)
        if (-not $addr) { return [pscustomobject]@{ hop = $n; address = ''; replies = 0; minMs = 0; avgMs = 0; maxMs = 0; note = 'no reply (this hop does not answer TTL expiry - not necessarily a fault)' } }
        $j = Get-ShowDbl 0.2 1.8
        [pscustomobject]@{ hop = $n; address = $addr; replies = 3; minMs = [math]::Round($ms - $j / 2, 1); avgMs = [math]::Round($ms, 1); maxMs = [math]::Round($ms + $j, 1); note = '' }
    }
    $w = $idleWan
    $hops = @(
        (& $hopRow 1 $gw (Get-ShowDbl 0.5 0.9)),
        (& $hopRow 2 '' 0),
        (& $hopRow 3 $sx.Hops[0] ($w * 0.62)),
        (& $hopRow 4 $sx.Hops[1] ($w * 0.70)),
        (& $hopRow 5 $sx.Hops[2] ($w * 0.81)),
        (& $hopRow 6 '' 0),
        (& $hopRow 7 $sx.Hops[3] ($w * 0.93)),
        (& $hopRow 8 $sx.Hops[4] ($w * 0.97)),
        (& $hopRow 9 '1.1.1.1' $w)
    )
    $path = [pscustomobject]@{
        Vpn = [pscustomobject]@{ Suspected = $false
                                 Routes = @([pscustomobject]@{ InterfaceIndex = $sx.IfIndex; InterfaceAlias = 'Ethernet'; NextHop = $gw; RouteMetric = 0; InterfaceMetric = 25; TotalMetric = 25 })
                                 Adapters = @(); Detail = 'A single default route and no VPN or overlay adapters, so the measured path is the real one.' }
        Proxy = [pscustomobject]@{ WinHttp = 'direct'; WinInet = 'direct'; WinInetAutoConfig = ''; WinInetEnabled = $false; Disagree = $false; Detail = '' }
        Dns = $dns
        Trace = [pscustomobject]@{ Ok = $true; Hops = [object[]]$hops; Reached = $true; Reason = '' }
        PathMtu = [pscustomobject]@{ Ok = $true; PathMtu = 1500; LocalMtu = 1500; Constrained = $false; Probes = 2
                                     Detail = 'Path MTU is 1500, matching this machine''s interface MTU - no constraint on the path.' }
        Power = [pscustomobject]@{ Ok = $true; PnPCapabilities = 0; PowerSavingEnabled = $true; DriverDate = '3-14-2024'; DriverVersion = '12.19.2045.3'; DriverProvider = 'Intel'
                                   Detail = 'PnPCapabilities is not set, which leaves the default in force: the computer is allowed to power the adapter down.' }
        Qos = [pscustomobject]@{ State = 'measured'; Reason = ''; Policies = @() }
        PublicIp = $sx.Pub
        Cancelled = $false
    }
    $egress = [pscustomobject]@{
        Ok = $true; Reason = ''; LocalGateway = $gw; EgressDevice = $gw; FirstPublicHop = $sx.Hops[0]
        PrivateHopCount = 1; Cgnat = $false
        Hops = @([pscustomobject]@{ ttl = 1; address = $gw; class = 'rfc1918'; rttMs = -1 },
                 [pscustomobject]@{ ttl = 2; address = ''; class = 'none'; rttMs = -1 },
                 [pscustomobject]@{ ttl = 3; address = $sx.Hops[0]; class = 'public'; rttMs = -1 })
    }
    $gwId = [pscustomobject]@{
        Address = $gw; Reachable = $true; Hostname = ''; Mac = $sx.GwMac; Vendor = (Get-NsOuiVendor -Mac $sx.GwMac); OnLink = $true
        OpenPorts = @(22, 80, 443); HttpServer = ''; HttpTitle = 'Router Login'; HttpRealm = ''
        TlsSubject = 'CN=edge-gw.example, O=Example Networks'; TlsIssuer = 'CN=edge-gw.example, O=Example Networks'
        Guess = 'edge-gw.example'; GuessBasis = 'TLS certificate'
    }

    $wifi = [pscustomobject]@{ State = 'unsupported'; Reason = 'This machine has no wireless adapter, so nothing here applies. Wired connections are covered by the link section.'
                               Interface = $null; Neighbours = @(); CoChannelCount = 0; Scanned = $false; SameSsidBetterBss = @(); Findings = @() }

    # ---- hand it to the GUI exactly as a worker would ----------------------
    $script:R = @{
        Latency = $lat; Hogs = $hogs; Path = $path; EgressPath = $egress
        PathIds = @([pscustomobject]@{ Label = 'Default gateway'; Identity = $gwId })
        Wifi = $wifi; Etw = $etw
    }
    $script:Timing = @{
        throughput = @{ Started = $baseUtc.AddSeconds(13);  Sec = 31.4 }
        latency    = @{ Started = $baseUtc.AddSeconds(13);  Sec = 31.4 }
        hogs       = @{ Started = $baseUtc.AddSeconds(46);  Sec = 5.1 }
        wifi       = @{ Started = $baseUtc.AddSeconds(58);  Sec = 0.3 }
        etw        = @{ Started = $baseUtc.AddSeconds(89);  Sec = 27.2 }
        path       = @{ Started = $baseUtc.AddSeconds(138); Sec = 38.6 }
    }
    $script:startedUtc = $baseUtc
    $script:startedSw = [System.Diagnostics.Stopwatch]::StartNew()
    $script:numPlanDown.Value = 500
    $script:numPlanUp.Value = 50

    # ---- the log, in the worker's own message formats -----------------------
    $script:txtLog.Clear()
    $L ={ param([int]$Sec, [string]$Msg) $script:txtLog.AppendText(('[{0}] {1}' -f $base.AddSeconds($Sec).ToString('HH:mm:ss'), $Msg) + [Environment]::NewLine) }
    & $L 0  ('NetSpeed Troubleshooter v{0} ready.' -f (Get-NetSpeedVersion))
    & $L 0  'Testing over Ethernet (1000 Mbps). Change the adapter above if that is wrong.'
    & $L 0  'Quick Sweep takes about a minute and answers most "the internet is slow" tickets on its own.'
    if ($script:EgressHistory -and $script:EgressHistory.State -eq 'measured') {
        & $L 0 ('Egress history: {0} samples over {1:N1} hours, {2} public address(es) seen.' -f $script:EgressHistory.Samples, $script:EgressHistory.SpanHours, @($script:EgressHistory.Addresses).Count)
    }
    & $L 13 'Sizing the link with a short probe...'
    & $L 15 ('Probe suggests about {0}.' -f (Format-NsMbps ($downC * 0.94)))
    & $L 15 'Measuring idle latency, then latency under load in both directions...'
    & $L 45 ('Download: {0}' -f (Format-NsThroughputResult -Result $down))
    & $L 45 ('Upload: {0}' -f (Format-NsThroughputResult -Result $up))
    & $L 45 ('Bufferbloat grade {0} - latency rises up to {1} ms under load.' -f $lat.Grade, $lat.WorstAddedMs)
    & $L 45 $lat.Queue.Summary
    & $L 46 'Looking for anything on this PC using the link...'
    & $L 51 ('Delivery Optimization has {0} job(s) in progress with {1} still to fetch.' -f $hogs.DO.ActiveJobs, (Format-NsBytes $hogs.DO.ActiveRemainingBytes))
    & $L 51 ('{0} external connections across {1} processes.' -f $hogs.Tcp.Total, @($hogs.Tcp.Processes).Count)
    & $L 51 'Checking routes, proxy and DNS...'
    & $L 56 $dns.Verdict
    & $L 58 ('Traffic leaves straight out through the default gateway {0}.' -f $gw)
    & $L 58 'Done.'
    & $L 89 'Starting a private kernel network trace (this is the only true per-process byte measurement here)...'
    & $L 116 ('Captured {0:N0} events over {1:N0}s and attributed {2}.' -f $etw.EventsParsed, $etw.CaptureSec, (Format-NsBytes $etw.TotalBytes))
    & $L 116 'Done.'
    & $L 138 'Tracing the path, timing DNS and measuring path MTU...'
    & $L 175 $dns.Verdict
    & $L 177 ('Traffic leaves straight out through the default gateway {0}.' -f $gw)
    & $L 177 'Done.'
    & $L 190 'Live monitor started. Starting a speed test while this runs is supported - the tool''s own traffic is labelled, not hidden.'

    # ---- a live monitor that has been running a minute ----------------------
    $ms = [hashtable]::Synchronized(@{})
    $ms.Cancel = $false; $ms.Done = $false; $ms.Version = 1; $ms.Error = ''; $ms.SelfPid = $PID
    $ms.TotalErrors = 0.0; $ms.TotalDiscards = 0.0
    $samples = [Activator]::CreateInstance([System.Collections.Generic.List[object]])
    for ($i = 0; $i -lt 60; $i++) {
        $dn = Get-ShowDbl 1.5 6.0
        if ((Get-ShowInt 0 9) -eq 0) { $dn = Get-ShowDbl 30 140 }
        $samples.Add([pscustomobject]@{ DownMbps = $dn; UpMbps = (Get-ShowDbl 15.8 19.4); Errors = 0; Discards = 0; Wrapped = $false })
    }
    $ms.Samples = [object[]]$samples.ToArray()
    $ms.Top = [object[]]@($procArr | Select-Object -First 10)
    $script:MonShared = $ms
    $script:btnMonitor.Text = 'Stop Monitor'

    Refresh-AllTabs | Out-Null
    Render-Monitor -Mon $ms
    $script:form.Size = New-Object System.Drawing.Size([int]$script:ShowcaseWidth, [int]$script:ShowcaseHeight)
} catch {
    $script:ShowManifest.error = ('Fixture failed: {0} @ {1}' -f $_.Exception.Message, $_.InvocationInfo.PositionMessage)
    Write-ShowManifest
}

function Clear-ShowSelection {
    # A grid selects its first row when its tab is first shown, which paints
    # it blue and hides the colour of its Result cell. Cleared after the tab
    # is visible, not before - before, the grid simply selects it again.
    foreach ($g in @($script:gridOverview, $script:gridThroughput, $script:gridLatency, $script:gridHogs,
                     $script:gridWifi, $script:gridPath, $script:gridSoak, $script:gridLink, $script:gridMonitor)) {
        if ($g) { try { $g.CurrentCell = $null } catch { }; $g.ClearSelection() }
    }
    # The log box keeps the newest lines in view in a real session.
    $script:txtLog.SelectionStart = $script:txtLog.TextLength
    $script:txtLog.ScrollToCaret()
}

# ---- capture --------------------------------------------------------------
if (-not ('NsShowCap' -as [type])) {
    Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public static class NsShowCap {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT r);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out RECT r, int size);
}
"@
}

function Save-ShowPng {
    # PrintWindow with PW_RENDERFULLCONTENT (2) renders the window as DWM
    # composes it - modern title bar included, and correct even if another
    # window overlaps it. Cropped to the DWM frame so the invisible resize
    # border does not show as a strip of desktop. -Bitmap falls back to
    # DrawToBitmap, which needs no DWM but draws an old-style caption.
    param([string]$Path)
    if ($script:ShowcaseCapture -eq 'Bitmap') {
        $b = New-Object System.Drawing.Bitmap($script:form.Width, $script:form.Height)
        $script:form.DrawToBitmap($b, (New-Object System.Drawing.Rectangle(0, 0, $script:form.Width, $script:form.Height)))
        $b.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png); $b.Dispose(); return
    }
    $h = $script:form.Handle
    $wr = New-Object NsShowCap+RECT; [void][NsShowCap]::GetWindowRect($h, [ref]$wr)
    $bmp = New-Object System.Drawing.Bitmap(($wr.Right - $wr.Left), ($wr.Bottom - $wr.Top))
    $gr = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $gr.GetHdc(); [void][NsShowCap]::PrintWindow($h, $hdc, 2); $gr.ReleaseHdc($hdc); $gr.Dispose()
    $fr = New-Object NsShowCap+RECT
    if ([NsShowCap]::DwmGetWindowAttribute($h, 9, [ref]$fr, 16) -eq 0) {
        $rect = New-Object System.Drawing.Rectangle(($fr.Left - $wr.Left), ($fr.Top - $wr.Top), ($fr.Right - $fr.Left), ($fr.Bottom - $fr.Top))
        $crop = $bmp.Clone($rect, $bmp.PixelFormat); $bmp.Dispose(); $bmp = $crop
    }
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
}

# ---- privacy gate ---------------------------------------------------------
function Get-ShowUiText {
    $out = [Activator]::CreateInstance([System.Collections.Generic.List[string]])
    $out.Add([string]$script:form.Text)
    $stack = New-Object System.Collections.Stack
    $stack.Push($script:form)
    while ($stack.Count -gt 0) {
        $c = $stack.Pop()
        foreach ($k in $c.Controls) { $stack.Push($k) }
        if ($c -is [System.Windows.Forms.DataGridView]) {
            foreach ($row in $c.Rows) { foreach ($cell in $row.Cells) { if ($null -ne $cell.Value) { $out.Add([string]$cell.Value) } } }
        } elseif ($c -is [System.Windows.Forms.ComboBox]) {
            foreach ($it in $c.Items) { $out.Add([string]$it) }
            $out.Add([string]$c.Text)
        } elseif ($c -is [System.Windows.Forms.Control]) {
            if ($c.Text) { $out.Add([string]$c.Text) }
        }
    }
    return $out
}

function Test-ShowPrivacy {
    $deny = @{ tokens = @(); ips = @(); macs = @() }
    $dp = Join-Path $script:ShowcaseWork 'deny.json'
    if (Test-Path -LiteralPath $dp) { $deny = Get-Content -LiteralPath $dp -Raw | ConvertFrom-Json }
    $texts = Get-ShowUiText
    $all = ($texts -join "`n")
    $hits = [Activator]::CreateInstance([System.Collections.Generic.List[string]])
    foreach ($t in @($deny.tokens)) {
        if ($t -and $t.Length -ge 3 -and $all.IndexOf($t, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $hits.Add(('name: {0}' -f $t)) }
    }
    foreach ($ip in @($deny.ips)) {
        if ($ip -and [regex]::IsMatch($all, ('(?<![\d.:A-Fa-f])' + [regex]::Escape($ip) + '(?!\.?\d)'))) { $hits.Add(('real address: {0}' -f $ip)) }
    }
    foreach ($m in @($deny.macs)) {
        $norm = ($m -replace '[^0-9A-Fa-f]', '')
        if ($norm.Length -eq 12) {
            $re = (($norm -split '(..)' | Where-Object { $_ }) -join '[-:]?')
            if ([regex]::IsMatch($all, $re, 'IgnoreCase')) { $hits.Add(('real MAC: {0}' -f $m)) }
        }
    }
    # Every IPv4 on screen must be one the fixture made up, documentation
    # space, or one of the tool's own fixed public probe targets.
    $fixed = @('1.1.1.1','1.0.0.1','8.8.8.8','8.8.4.4','9.9.9.9')
    foreach ($m in [regex]::Matches($all, '(?<![\d.])(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?![\d])')) {
        $oct = @(1..4 | ForEach-Object { [int]$m.Groups[$_].Value })
        if (@($oct | Where-Object { $_ -gt 255 }).Count -gt 0) { continue }
        $v = $m.Value
        $ok = ($script:Showcase.Allowed -contains $v) -or ($fixed -contains $v) -or
              ($v -like '192.0.2.*') -or ($v -like '198.51.100.*') -or ($v -like '203.0.113.*')
        if (-not $ok) { $hits.Add(('unexpected IPv4: {0}' -f $v)) }
    }
    foreach ($m in [regex]::Matches($all, '\b([0-9A-Fa-f]{2}[-:]){5}[0-9A-Fa-f]{2}\b')) {
        if ($m.Value -notmatch '^00[-:]00[-:]5E[-:]00[-:]53[-:]') { $hits.Add(('MAC outside RFC 7042 documentation range: {0}' -f $m.Value)) }
    }
    return [pscustomobject]@{ ok = ($hits.Count -eq 0); hits = @($hits | Select-Object -Unique); stringsScanned = $texts.Count }
}

$script:ShowQueue = New-Object System.Collections.Queue
foreach ($pair in @(
    @('overview',   'Overview'),
    @('path',       'Path and Infrastructure'),
    @('latency',    'Latency / Bufferbloat'),
    @('hogs',       'Bandwidth Hogs'),
    @('throughput', 'Throughput'),
    @('monitor',    'Live Monitor'),
    @('link',       'Link Facts'))) { $script:ShowQueue.Enqueue($pair) }
$script:ShowPending = $null
$script:ShowTimer = New-Object System.Windows.Forms.Timer
$script:ShowTimer.Interval = 450
$script:ShowTimer.Add_Tick({
    try {
        if ($script:ShowPending) {
            $f = Join-Path $script:ShowcaseWork ('NetSpeed_showcase_{0}.png' -f $script:ShowPending[0])
            Save-ShowPng -Path $f
            $script:ShowManifest.captures += [System.IO.Path]::GetFileName($f)
            $script:ShowPending = $null
            return
        }
        if ($script:ShowQueue.Count -gt 0) {
            $next = $script:ShowQueue.Dequeue()
            foreach ($tp in $script:tabs.TabPages) { if ($tp.Text -eq $next[1]) { $script:tabs.SelectedTab = $tp } }
            [System.Windows.Forms.Application]::DoEvents()
            Clear-ShowSelection
            $script:form.Refresh()
            $script:ShowPending = $next
            return
        }
        $script:ShowTimer.Stop()
        $script:ShowManifest.scan = Test-ShowPrivacy
        $script:ShowManifest.ok = ($script:ShowManifest.scan.ok -and -not $script:ShowManifest.error)
        Write-ShowManifest
        $script:form.Close()
    } catch {
        $script:ShowTimer.Stop()
        $script:ShowManifest.error = ('Capture failed: {0}' -f $_.Exception.Message)
        Write-ShowManifest
        $script:form.Close()
    }
})
$script:form.Add_Shown({
    if ($script:ShowManifest.error) { $script:form.Close(); return }
    $script:form.Activate()
    $script:ShowTimer.Start()
})
