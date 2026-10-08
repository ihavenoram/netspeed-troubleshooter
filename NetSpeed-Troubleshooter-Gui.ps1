<#
    Internet / Network Speed Troubleshooter (WinForms)
    --------------------------------------------------
    On-site tool for Windows PowerShell 5.1, built to be launched inside a
    ScreenConnect Backstage session (often as SYSTEM) when a client reports
    "the internet is slow".

    Answers, in about a minute from Quick Sweep:
      * Is the physical link itself the cap? (a wired NIC negotiating 10 or
        100 Mbps closes more of these tickets than anything else here)
      * What does the link actually deliver, up and down?
      * Does latency collapse under load? That is what makes Teams stutter
        while a speed test still looks fine.
      * Is something on THIS PC eating the link - Windows Update, Office,
        OneDrive, a backup agent?
    Then targeted deep dives behind that: real per-process bytes via ETW, a
    live traffic monitor, Wi-Fi, path and DNS, and a soak mode for
    intermittent faults.

    All measurement logic lives in NetSpeed-Troubleshooter.Helpers.ps1, which
    is loaded as TEXT and rebuilt inside each background runspace. The future
    headless collector (not in this release) dot-sources that same file, so the tests are
    written once.

    Launch via Launch-NetSpeed-Troubleshooter.cmd (forces -STA, required for
    WinForms). No admin needed except for the ETW deep capture, which
    disables itself with a stated reason when not elevated.
#>
[CmdletBinding()]
param(
    # The console is hidden in-process by handle. -WindowStyle Hidden on the
    # launcher is NOT equivalent: it hides the form as well.
    [switch]$NoHideConsole
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

# ---------------------------------------------------------------------------
# Console window
# ---------------------------------------------------------------------------
if (-not $NoHideConsole) {
    try {
        if (-not ('NsNative.Win' -as [type])) {
            Add-Type -Namespace 'NsNative' -Name 'Win' -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[DllImport("user32.dll")]   public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
'@
        }
        $h = [NsNative.Win]::GetConsoleWindow()
        if ($h -ne [System.IntPtr]::Zero) { [void][NsNative.Win]::ShowWindow($h, 0) }
    } catch { }
}

# ---------------------------------------------------------------------------
# Helpers, loaded as TEXT so the identical definitions can be rebuilt inside
# each background runspace (which inherits no state whatsoever).
# ---------------------------------------------------------------------------
$HelpersPath = Join-Path $PSScriptRoot 'NetSpeed-Troubleshooter.Helpers.ps1'
if (-not (Test-Path -LiteralPath $HelpersPath)) {
    # A MessageBox in a non-interactive session (an RMM job running as SYSTEM
    # with no desktop) has nobody to dismiss it, so it would hang the job until
    # the RMM's timeout killed it. Write to output there instead.
    if (-not [Environment]::UserInteractive) {
        Write-Output '[ERROR] This is the GUI (NetSpeed-Troubleshooter-Gui.ps1) and it needs a desktop - it cannot run from an RMM job.'
        Write-Output '[ERROR] NetSpeed-Troubleshooter.Helpers.ps1 was not found beside it either.'
        Write-Output '[ERROR] Copy the whole NetSpeed-Troubleshooter folder to the machine (the files must stay together), then run Launch-NetSpeed-Troubleshooter.cmd from an interactive session or ScreenConnect Backstage.'
        exit 2
    }
    [void][System.Windows.Forms.MessageBox]::Show(
        ('Cannot find {0}.' + [Environment]::NewLine + [Environment]::NewLine +
         'It must sit in the same folder as NetSpeed-Troubleshooter-Gui.ps1.') -f $HelpersPath,
        'NetSpeed Troubleshooter', 'OK', 'Error')
    return
}
$HelpersSource = Get-Content -LiteralPath $HelpersPath -Raw
. ([scriptblock]::Create($HelpersSource))

# ---------------------------------------------------------------------------
# Script state
# ---------------------------------------------------------------------------
$script:Shared     = $null
$script:MonShared  = $null
$script:ps         = $null
$script:rs         = $null
$script:async      = $null
$script:monPs      = $null
$script:monRs      = $null
$script:monAsync   = $null
$script:timer      = $null
$script:logIndex   = 0
$script:busy       = $false
$script:owner      = ''
$script:startedUtc = [datetime]::MinValue
$script:startedSw  = $null
$script:lastRunAt  = [datetime]::MinValue
$script:R          = @{}     # accumulated raw stage results
$script:RouteSanity   = $null
$script:EgressPath    = $null
$script:PathIds       = @()
$script:EgressHistory = $null
$script:Timing     = @{}     # per-section {Started, Sec}, stamped by Set-NsSectionTiming
$script:rendered   = @{}     # one-shot render latches
$script:versions   = @{}     # streaming render version marks
$script:Adapter    = $null
$script:EtwAvailable = $true
$script:inTick     = $false  # timer re-entrancy guard
$script:adapterIndex = -1
$script:adapterReverting = $false
$script:btnClear   = $null
$script:btnSoak    = $null
$script:Context    = Get-NsContext

# ---------------------------------------------------------------------------
# Control factories
# ---------------------------------------------------------------------------
function New-Btn {
    param([string]$Text,[int]$W = 150,[int]$H = 30,[string]$Tip = '')
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text; $b.Width = $W; $b.Height = $H
    $b.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    if ($Tip) { $b.Tag = $Tip }
    return $b
}

function New-Lbl {
    param([string]$Text,[bool]$Bold = $false,[int]$Size = 9)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    # AutoSize so a longer string at a higher DPI can never be clipped.
    $l.AutoSize = $true
    $style = [System.Drawing.FontStyle]::Regular
    if ($Bold) { $style = [System.Drawing.FontStyle]::Bold }
    $l.Font = New-Object System.Drawing.Font('Segoe UI', $Size, $style)
    return $l
}

function New-ResultGrid {
    # One grid shape for every section. The Basis column is the honesty stance
    # made visible: a technician can sort by it and see at a glance which
    # numbers were measured, which were inferred, and which were withheld.
    $g = New-Object System.Windows.Forms.DataGridView
    $g.Dock = 'Fill'
    $g.ReadOnly = $true
    $g.AllowUserToAddRows = $false
    $g.AllowUserToDeleteRows = $false
    $g.AllowUserToResizeRows = $false
    $g.RowHeadersVisible = $false
    $g.SelectionMode = 'FullRowSelect'
    $g.MultiSelect = $false
    $g.AutoSizeColumnsMode = 'Fill'
    $g.BorderStyle = 'None'
    $g.BackgroundColor = [System.Drawing.Color]::White
    $g.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    # Colours set EXPLICITLY rather than inherited.
    #
    # On a server SKU without the Desktop Experience feature, visual styles are
    # not available and a DataGridView that relies on the theme for its cell and
    # header colours renders black on black - reported from a live Server 2012 R2
    # box where the log was readable but every grid was a solid black rectangle.
    # EnableHeadersVisualStyles = $false is the part that fixes the HEADERS,
    # which ignore ColumnHeadersDefaultCellStyle while it is true.
    #
    # On a normally themed Windows 10/11 client these are the values it was
    # already using, so nothing changes there.
    $g.EnableHeadersVisualStyles = $false
    $g.GridColor = [System.Drawing.Color]::FromArgb(221,227,234)
    $g.DefaultCellStyle.BackColor = [System.Drawing.Color]::White
    $g.DefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(29,33,38)
    $g.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(51,103,158)
    $g.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::White
    $g.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(242,245,248)
    $g.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(29,33,38)
    $g.ColumnHeadersDefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(242,245,248)
    $g.ColumnHeadersDefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::FromArgb(29,33,38)
    $g.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(250,251,252)
    $g.AlternatingRowsDefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(29,33,38)
    $g.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $g.DefaultCellStyle.WrapMode = 'False'
    foreach ($c in @(
        @{ N = 'Group';  W = 12 }, @{ N = 'Check';  W = 20 },
        @{ N = 'Result'; W = 17 }, @{ N = 'Basis';  W = 11 }, @{ N = 'Detail'; W = 40 })) {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.Name = $c.N; $col.HeaderText = $c.N; $col.FillWeight = $c.W
        [void]$g.Columns.Add($col)
    }
    return $g
}

function New-SummaryBox {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Multiline = $true; $t.ReadOnly = $true; $t.Dock = 'Fill'
    $t.ScrollBars = 'Vertical'
    $t.BackColor = [System.Drawing.Color]::FromArgb(245,245,245)
    # Explicit, for the same reason as the grid above: an unthemed server SKU
    # gives a read-only TextBox a black default foreground on a grey ground.
    $t.ForeColor = [System.Drawing.Color]::FromArgb(29,33,38)
    $t.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    return $t
}

function New-Tab {
    param([string]$Text)
    $t = New-Object System.Windows.Forms.TabPage
    $t.Text = $Text
    $t.BackColor = [System.Drawing.Color]::White
    $t.ForeColor = [System.Drawing.Color]::FromArgb(29,33,38)
    $t.Padding = New-Object System.Windows.Forms.Padding(6)
    return $t
}

function Get-StatusColor {
    param([string]$Status)
    switch ($Status) {
        'ok'   { return [System.Drawing.Color]::FromArgb(0,128,0) }
        'fail' { return [System.Drawing.Color]::FromArgb(192,0,0) }
        'warn' { return [System.Drawing.Color]::FromArgb(190,110,0) }
        default { return [System.Drawing.Color]::DimGray }
    }
}

function Write-Log {
    param([string]$Message)
    $line = ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message)
    if ($script:txtLog) { $script:txtLog.AppendText($line + [Environment]::NewLine) }
}

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------
function Add-SectionRows {
    param($Grid, $Rows)
    foreach ($r in @($Rows)) {
        if (-not $r) { continue }
        $i = $Grid.Rows.Add(@($r.group, $r.check, $r.result, $r.basis, $r.detail))
        $cell = $Grid.Rows[$i].Cells['Result']
        $cell.Style.ForeColor = Get-StatusColor -Status $r.status
        $cell.Style.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
        if ($r.basis -eq 'withheld' -or $r.basis -eq 'not measured') {
            $Grid.Rows[$i].Cells['Basis'].Style.ForeColor = [System.Drawing.Color]::DimGray
        }
    }
}

function Get-SectionSummaryText {
    param($Section, [string]$Title)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine(('{0} - {1}' -f $Title, ([string]$Section.state).ToUpper()))
    if ($Section.reason)  { [void]$sb.AppendLine(('Reason: {0}' -f $Section.reason)) }
    if ($Section.method)  { [void]$sb.AppendLine(('How: {0}' -f $Section.method)) }
    if ($Section.proxy)   { [void]$sb.AppendLine(('Proxy: {0}' -f $Section.proxy)) }
    foreach ($c in @($Section.caveats)) { [void]$sb.AppendLine(('Caveat: {0}' -f $c)) }
    return $sb.ToString()
}

function Get-ExtraSectionRows {
    # A section folded into another tab has no summary box of its own, so a
    # failed or refused one would otherwise vanish without trace. It gets one
    # row that carries its state and reason.
    #
    # -Group relabels the folded rows for DISPLAY only (copies, so the report
    # rows are untouched): ETW and the inference scan both call their rows
    # "Processes", and on one grid a measured byte count must not be mistaken
    # for a connection-count guess.
    param($Section, [string]$Group, [string]$Check, [switch]$Relabel)
    if (-not $Section -or $Section.state -eq 'skipped') { return @() }
    $rows = @($Section.rows | Where-Object { $_ })
    if ($rows.Count -gt 0) {
        if (-not $Relabel) { return $rows }
        return @($rows | ForEach-Object { New-NsRow -Group $Group -Check $_.check -Result $_.result -Basis $_.basis -Status $_.status -Detail $_.detail })
    }
    $st = 'info'; if ($Section.state -eq 'failed') { $st = 'warn' }
    return @(New-NsRow -Group $Group -Check $Check -Result $Section.state -Basis 'not measured' -Status $st -Detail $Section.reason)
}

function Render-Section {
    # Every section shares one row shape, so one renderer serves all of them.
    # -Extra folds a second section into the same tab: Ookla below Throughput,
    # where its button lives, and ETW ABOVE the hog inference on Bandwidth
    # Hogs (-ExtraFirst), because measured bytes outrank connection counts.
    param($Grid, $Summary, $Section, [string]$Title, $Extra = $null, [string]$ExtraTitle = '', [string]$ExtraCheck = '',
          [switch]$ExtraFirst, [switch]$RelabelExtra)
    if (-not $Grid) { return }
    $Grid.SuspendLayout()
    try {
        $Grid.Rows.Clear()
        if (-not $Section) { return }
        $extraRows = @()
        if ($Extra) { $extraRows = Get-ExtraSectionRows -Section $Extra -Group $ExtraTitle -Check $ExtraCheck -Relabel:$RelabelExtra }
        if ($ExtraFirst) { Add-SectionRows -Grid $Grid -Rows $extraRows }
        Add-SectionRows -Grid $Grid -Rows $Section.rows
        if (-not $ExtraFirst) { Add-SectionRows -Grid $Grid -Rows $extraRows }
    } finally { $Grid.ResumeLayout() }

    if ($Summary -and $Section) {
        $txt = Get-SectionSummaryText -Section $Section -Title $Title
        if ($Extra -and $Extra.state -ne 'skipped') {
            $txt = $txt + [Environment]::NewLine + (Get-SectionSummaryText -Section $Extra -Title $ExtraTitle)
        }
        $Summary.Text = $txt
    }
}

function Render-Overview {
    param($Verdict, $Ookla = $null)
    if (-not $Verdict) { return }
    $g = $script:gridOverview
    $g.SuspendLayout()
    try {
        $g.Rows.Clear()
        foreach ($s in @($Verdict.subscores)) {
            $status = 'info'
            switch ($s.level) {
                'green' { $status = 'ok' }
                'amber' { $status = 'warn' }
                'red'   { $status = 'fail' }
            }
            $i = $g.Rows.Add(@('Verdict', $s.name, $s.level, $(if ($s.level -eq 'notmeasured') { 'not measured' } else { 'measured' }), ('{0} {1}' -f $s.summary, $s.remedy)))
            $c = $g.Rows[$i].Cells['Result']
            $c.Style.ForeColor = Get-StatusColor -Status $status
            $c.Style.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
        }
        # Ookla is listed but never scored: a different server and a different
        # method from the built-in engine, so it is a cross-check and the
        # ISP-facing URL, not a subscore. Its row says so.
        if ($Ookla -and $Ookla.state -ne 'skipped') {
            if ($Ookla.state -eq 'measured') {
                $d = $Ookla.data
                $res = ('down {0} / up {1}' -f (Format-NsMbps $d.DownMbps), (Format-NsMbps $d.UpMbps))
                $det = 'Not part of the verdict - a different server and method from the built-in engine.'
                if ($d.ResultUrl) { $det = ('Result URL {0}  -  {1}' -f $d.ResultUrl, $det) }
                $i = $g.Rows.Add(@('Cross-check', 'Ookla speedtest', $res, 'vendor tool', $det))
            } else {
                $i = $g.Rows.Add(@('Cross-check', 'Ookla speedtest', $Ookla.state, 'not measured', $Ookla.reason))
            }
            $g.Rows[$i].Cells['Result'].Style.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
            $oc = [System.Drawing.Color]::DimGray
            if ($Ookla.state -eq 'measured') { $oc = [System.Drawing.Color]::FromArgb(29,33,38) }
            elseif ($Ookla.state -eq 'failed') { $oc = Get-StatusColor -Status 'warn' }
            $g.Rows[$i].Cells['Result'].Style.ForeColor = $oc
        }
    } finally { $g.ResumeLayout() }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine(('OVERALL: {0}' -f $Verdict.overall.ToUpper()))
    [void]$sb.AppendLine($Verdict.headline)
    foreach ($n in @($Verdict.notes)) { [void]$sb.AppendLine($n) }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('The overall result is the WORST measured subscore, never an average, and there is deliberately no 0-100 score. Anything not measured is listed but never counts against the result.')
    $script:txtOverview.Text = $sb.ToString()
}

function Render-Monitor {
    param($Mon)
    if (-not $Mon) { return }
    $g = $script:gridMonitor
    $samples = @($Mon.Samples)
    $g.SuspendLayout()
    try {
        $g.Rows.Clear()
        if ($script:Shared -and $script:Shared.SelfTestActive) {
            # Not subtle and not dismissible: the tool's own traffic is in
            # these numbers and a reader must not mistake it for the user's.
            $i = $g.Rows.Add(@('!!', 'SPEED TEST RUNNING', 'see detail', 'measured',
                'The figures below INCLUDE this tool''s own test streams. Any process row for this tool is excluded from the verdict.'))
            $g.Rows[$i].DefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(192,0,0)
            $g.Rows[$i].DefaultCellStyle.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
        }
        if ($samples.Count -gt 0) {
            $last = $samples[$samples.Count - 1]
            $note = 'Total on the adapter, from its own counters.'
            if ($script:Shared -and $script:Shared.SelfTestActive) {
                # NOT "corrected" by subtracting our own bytes - that cannot be
                # done accurately, so the component is stated instead of a
                # difference being invented.
                $note = 'Total on the adapter, INCLUDING traffic generated by this tool''s running speed test.'
            }
            $i = $g.Rows.Add(@('Link', 'Throughput now',
                ('down {0} / up {1}' -f (Format-NsMbps $last.DownMbps), (Format-NsMbps $last.UpMbps)),
                'measured', $note))
            $g.Rows[$i].Cells['Result'].Style.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
        }
        # Running totals, not just the last second: a burst of errors ten
        # seconds ago is exactly what a technician watching for a physical
        # fault needs to still see, and a per-second row vanished with it.
        $totE = [double]$Mon.TotalErrors; $totD = [double]$Mon.TotalDiscards
        if ($totE -gt 0 -or $totD -gt 0) {
            $nowE = 0; $nowD = 0
            if ($samples.Count -gt 0) { $nowE = $samples[$samples.Count - 1].Errors; $nowD = $samples[$samples.Count - 1].Discards }
            $i = $g.Rows.Add(@('Link', 'Errors / discards', ('{0:N0} / {1:N0} since start' -f $totE, $totD), 'measured',
                ('{0} / {1} in the last second. In and out, both directions. Non-zero while sampling points at a physical problem - cable, port or driver - rather than contention.' -f $nowE, $nowD)))
            $g.Rows[$i].Cells['Result'].Style.ForeColor = Get-StatusColor -Status 'warn'
        }
        $childPid = 0
        if ($script:Shared -and $script:Shared.ChildPid) { $childPid = [int]$script:Shared.ChildPid }
        foreach ($p in @($Mon.Top)) {
            $name = $p.name
            $note = 'Connection count only - this is inference, not measured bytes.'
            $isOwn = $false
            if ($script:MonShared -and $p.pid -eq $script:MonShared.SelfPid) {
                $name = ('{0} (this tool - NetSpeed Troubleshooter)' -f $p.name)
                $note = 'This is the troubleshooter itself. Always excluded from the verdict.'
                $isOwn = $true
            } elseif ($childPid -gt 0 -and $p.pid -eq $childPid) {
                # The Ookla CLI is a separate process, so the PID check above
                # never matched it and it read as somebody else's traffic.
                $name = ('{0} (this tool''s Ookla test)' -f $p.name)
                $note = 'Started by the troubleshooter''s Ookla button. Always excluded from the verdict.'
                $isOwn = $true
            }
            $i = $g.Rows.Add(@('Talkers', $name, ('{0} conn' -f $p.externalConns), 'inference',
                ('PID {0}, {1}. {2} {3}' -f $p.pid, $p.classification, (@($p.topRemotes) -join ', '), $note)))
            if ($isOwn) {
                $g.Rows[$i].DefaultCellStyle.ForeColor = [System.Drawing.Color]::DimGray
            }
        }
    } finally { $g.ResumeLayout() }

    # Text sparkline: cheap, readable, and pastes into a ticket intact.
    if ($samples.Count -gt 0) {
        $blocks = @('_','.',':','-','=','+','*','#','@')
        $maxD = 0.0
        foreach ($s in $samples) { if ($s.DownMbps -gt $maxD) { $maxD = $s.DownMbps }; if ($s.UpMbps -gt $maxD) { $maxD = $s.UpMbps } }
        if ($maxD -le 0) { $maxD = 1 }
        $mk = {
            param($sel)
            $sbb = New-Object System.Text.StringBuilder
            foreach ($s in $samples) {
                $v = & $sel $s
                $idx = [int][math]::Round(($v / $maxD) * ($blocks.Count - 1))
                if ($idx -lt 0) { $idx = 0 }
                if ($idx -ge $blocks.Count) { $idx = $blocks.Count - 1 }
                [void]$sbb.Append($blocks[$idx])
            }
            return $sbb.ToString()
        }
        $script:txtMonitor.Text = (
            ('last {0}s, scale 0-{1}' -f $samples.Count, (Format-NsMbps $maxD)) + [Environment]::NewLine +
            ('down |{0}|' -f (& $mk { param($s) $s.DownMbps })) + [Environment]::NewLine +
            ('up   |{0}|' -f (& $mk { param($s) $s.UpMbps }))
        )
    }
}

# ---------------------------------------------------------------------------
# Report assembly
# ---------------------------------------------------------------------------
function Update-RouteBanner {
    # The whole point of the indicator: a technician glancing at the top of the
    # window should be able to tell whether the numbers below describe the
    # connection this site is supposed to be using.
    param($Sanity)
    if (-not $script:lblRoute) { return }
    if (-not $Sanity -or $Sanity.Verdict -eq 'unknown') {
        $script:lblRoute.Text = 'Route: not checked yet - run Quick Sweep.'
        $script:lblRoute.ForeColor = [System.Drawing.Color]::DimGray
        return
    }
    $hits = @($Sanity.Signals | Where-Object { $_.hit })
    $ipTxt = 'address unknown'
    if ($Sanity.PublicIp) { $ipTxt = [string]$Sanity.PublicIp }
    # "via 192.168.0.1" is the half a technician can act on: it names the box.
    if ($Sanity.EgressDevice) { $ipTxt = ('{0}  via {1}' -f $ipTxt, $Sanity.EgressDevice) }
    $why = (@($hits | ForEach-Object { $_.name }) -join '; ')
    if ($Sanity.Verdict -eq 'suspect') {
        $script:lblRoute.Text = ('Route: LOOKS LIKE A BACKUP OR SECONDARY LINK  -  {0}  -  {1}' -f $ipTxt, $why)
        $script:lblRoute.ForeColor = [System.Drawing.Color]::Firebrick
    } elseif ($Sanity.Verdict -eq 'watch') {
        $script:lblRoute.Text = ('Route: one thing is unusual  -  {0}  -  {1}' -f $ipTxt, $why)
        $script:lblRoute.ForeColor = [System.Drawing.Color]::FromArgb(190, 110, 0)
    } else {
        $script:lblRoute.Text = ('Route: looks like the usual connection  -  {0}' -f $ipTxt)
        $script:lblRoute.ForeColor = [System.Drawing.Color]::FromArgb(0, 110, 0)
    }
}

function Build-Report {
    $planDown = [double]$script:numPlanDown.Value
    $planUp   = [double]$script:numPlanUp.Value
    $lat  = $script:R['Latency']
    $down = $script:R['Down']; if (-not $down -and $lat) { $down = $lat.Down }
    $up   = $script:R['Up'];   if (-not $up   -and $lat) { $up   = $lat.Up }
    $path = $script:R['Path']
    $power = $null; $vpn = $null; $proxy = $null
    if ($path) { $power = $path.Power; $vpn = $path.Vpn; $proxy = $path.Proxy }

    # Route sanity: does this look like the connection the site normally uses?
    # Drawn from the evidence already gathered plus any egress history this
    # machine has recorded, so it costs no extra network work.
    $idleMs = -1
    try {
        if ($lat -and $lat.Idle) {
            foreach ($k in @($lat.Idle.Keys)) {
                if ($k -eq '1.1.1.1') { $idleMs = [double]$lat.Idle[$k].p50Ms }
            }
        }
    } catch { }
    # Which box does traffic leave through, and what is it? Both are measured
    # by the WORKER in the path stage and only read here. They used to be
    # probed right here, on the UI thread, on every refresh - a TTL walk plus a
    # six-port connect burst and HTTP/TLS fetches against the gateway, every
    # 500 ms through a transfer test. Measured: 36 s of a 61 s sweep with the
    # window frozen, worst single stall 6.8 s, and the gateway probed over and
    # over in the middle of the bufferbloat measurement.
    $script:EgressPath = $script:R['EgressPath']
    $script:PathIds = @($script:R['PathIds'] | Where-Object { $_ })
    $script:RouteSanity = Get-NsPathSanity -PathInfo $path -Throughput $down `
                            -History $script:EgressHistory -EgressPath $script:EgressPath `
                            -IdleLatencyMs $idleMs


    $sections = [pscustomobject]@{
        link       = New-NsLinkSection       -Adapter $script:Adapter -Vpn $vpn -Power $power -Proxy $proxy
        throughput = New-NsThroughputSection -Down $down -Up $up -PlanDown $planDown -PlanUp $planUp
        latency    = New-NsLatencySection    -Result $lat
        hogs       = New-NsHogsSection       -Hogs $script:R['Hogs'] -SelfPid $PID
        etw        = New-NsEtwSection        -Etw $script:R['Etw']
        wifi       = New-NsWifiSection       -Wifi $script:R['Wifi']
        path       = New-NsPathSection       -Path $path -Sanity $script:RouteSanity -EgressPath $script:EgressPath -Identities $script:PathIds
        soak       = New-NsSoakSection       -Soak $script:R['Soak']
        ookla      = New-NsOoklaSection      -Ookla $script:R['Ookla']
    }
    # Stamp when each stage actually ran. The section builders do not carry
    # timings, so the caller that owned the stopwatch supplies them.
    foreach ($k in @('link','throughput','latency','hogs','etw','wifi','path','soak','ookla')) {
        if ($script:Timing.ContainsKey($k) -and $sections.$k) {
            [void](Set-NsSectionTiming -Section $sections.$k -StartedUtc $script:Timing[$k].Started -DurationSec $script:Timing[$k].Sec)
        }
    }

    $subs = Get-NsSubscores -Adapter $script:Adapter -Throughput $down -Latency $lat `
                -Hogs $script:R['Hogs'] -Etw $script:R['Etw'] -Wifi $script:R['Wifi'] `
                -Path $path -Soak $script:R['Soak'] -PlanDown $planDown
    $verdict = Get-NsHealth -Subscores $subs
    $dur = 0.0
    if ($script:startedSw) { $dur = $script:startedSw.Elapsed.TotalSeconds }
    $log = @()
    if ($script:txtLog -and $script:txtLog.Lines) { $log = @($script:txtLog.Lines | Where-Object { $_ }) }

    $report = New-NsReport -Context $script:Context -Adapter $script:Adapter -Sections $sections `
                -Verdict $verdict -StartedUtc $script:startedUtc -DurationSec $dur `
                -Mode 'gui' -PlanDown $planDown -PlanUp $planUp -Log $log
    return [pscustomobject]@{ Report = $report; Sections = $sections; Verdict = $verdict }
}

function Refresh-AllTabs {
    $b = Build-Report
    Render-Overview -Verdict $b.Verdict -Ookla $b.Sections.ookla
    Render-Section -Grid $script:gridThroughput -Summary $script:txtThroughput -Section $b.Sections.throughput -Title 'Throughput' `
        -Extra $b.Sections.ookla -ExtraTitle 'Ookla' -ExtraCheck 'Speedtest CLI'
    Render-Section -Grid $script:gridLatency    -Summary $script:txtLatency    -Section $b.Sections.latency    -Title 'Latency / bufferbloat'
    # ETW lives on the Hogs tab, beside the button that runs it. It used to be
    # rendered into $script:gridEtw - a grid that was never created - so the
    # only real per-process byte measurement in the tool reached the log and
    # the JSON and never a grid.
    Render-Section -Grid $script:gridHogs       -Summary $script:txtHogs       -Section $b.Sections.hogs       -Title 'Bandwidth hogs' `
        -Extra $b.Sections.etw -ExtraTitle 'ETW deep capture' -ExtraCheck 'Kernel network trace' -ExtraFirst -RelabelExtra
    Render-Section -Grid $script:gridWifi       -Summary $script:txtWifi       -Section $b.Sections.wifi       -Title 'Wi-Fi'
    Render-Section -Grid $script:gridPath       -Summary $script:txtPath       -Section $b.Sections.path       -Title 'Path and infrastructure'
    Render-Section -Grid $script:gridSoak       -Summary $script:txtSoak       -Section $b.Sections.soak       -Title 'Soak'
    Render-Section -Grid $script:gridLink       -Summary $script:txtLink       -Section $b.Sections.link       -Title 'Link'
    Update-RouteBanner -Sanity $script:RouteSanity
    $script:txtReport.Text = Format-NsJsonEnvelope -Report $b.Report
    return $b
}

# ---------------------------------------------------------------------------
# Background worker
# ---------------------------------------------------------------------------
$WorkerScript = {
    param($Shared, $HelpersSource, $Mode, $Opt)

    . ([scriptblock]::Create($HelpersSource))
    function WriteLog($m) { [void]$Shared.Log.Add(('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m)) }

    # Per-stage clock. The section builders do not carry timings, so whoever
    # owns the stopwatch has to record them - see Set-NsSectionTiming.
    $stageSw = $null
    function StageStart { $script:stageStartedUtc = (Get-Date).ToUniversalTime(); $script:stageSw = [System.Diagnostics.Stopwatch]::StartNew() }
    function StageStop($name) {
        if (-not $script:stageSw) { return }
        $script:stageSw.Stop()
        $Shared.Timing[$name] = @{ Started = $script:stageStartedUtc; Sec = $script:stageSw.Elapsed.TotalSeconds }
        $script:stageSw = $null
    }
    # Format-NsThroughputResult returns '' for a direction that produced no
    # figure, which logged a bare "Download: " and hid the reason.
    function DirLine($label, $r) {
        if (-not $r) { return }
        $t = Format-NsThroughputResult -Result $r
        if (-not $t) { $t = ('no figure - {0}' -f $r.Reason) }
        WriteLog ('{0}: {1}' -f $label, $t)
    }

    try {
        Set-NsNetDefaults -Quiet | Out-Null
        $adapter = $Opt.Adapter
        $gw = ''
        if ($adapter) { $gw = [string]$adapter.gateway }
        $wwanDet = Get-NsWwanDetection -AdapterInfo $adapter
        $wwan = $wwanDet.IsWwan
        $wwanBasis = $wwanDet.Basis
        if ($wwan) { WriteLog 'Cellular adapter detected - a reduced test profile will be applied automatically to limit data use.' }

        # ---- throughput + bufferbloat -----------------------------------
        if ($Mode -eq 'sweep' -or $Mode -eq 'latency' -or $Mode -eq 'throughput') {
            StageStart
            $Shared.SelfTestActive = $true
            $Shared.Progress = 5
            WriteLog 'Sizing the link with a short probe...'
            $probe = Measure-CfProbeRate -Seconds 2.0 -Shared $Shared -BypassProxy:$Opt.BypassProxy
            if ($probe.Ok) { WriteLog ('Probe suggests about {0}.' -f (Format-NsMbps $probe.Mbps)) }
            else { WriteLog ('Probe failed: {0}' -f $probe.Detail) }
            $Shared.Progress = 15

            if ($Mode -eq 'throughput') {
                WriteLog 'Measuring download...'
                $bagD = New-NsProbeBag -IcmpTargets @('1.1.1.1') -HttpUrl (Get-NsCfEndpoints).Latency -BypassProxy:$Opt.BypassProxy
                $d = Invoke-CfThroughput -Direction 'Down' -Streams $Opt.Streams -MeasureSec 10 -EstMbps $probe.Mbps `
                        -Shared $Shared -VersionKey 'ThroughputVersion' -ProbeBag $bagD -BypassProxy:$Opt.BypassProxy -Wwan:$wwan -WwanBasis $wwanBasis
                Close-NsProbeBag -Bag $bagD -Stopwatch ([System.Diagnostics.Stopwatch]::StartNew())
                $Shared.R_Down = $d
                DirLine 'Download' $d
                $Shared.Progress = 55
                if (-not $Shared.Cancel) {
                    WriteLog 'Measuring upload...'
                    $est = $probe.Mbps
                    if ($d.Ok -and $d.OverallMbps -gt 0) { $est = $d.OverallMbps }
                    $bagU = New-NsProbeBag -IcmpTargets @('1.1.1.1') -HttpUrl (Get-NsCfEndpoints).Latency -BypassProxy:$Opt.BypassProxy
                    $u = Invoke-CfThroughput -Direction 'Up' -Streams $Opt.Streams -MeasureSec 10 -EstMbps $est `
                            -Shared $Shared -VersionKey 'ThroughputVersion' -ProbeBag $bagU -BypassProxy:$Opt.BypassProxy -Wwan:$wwan -WwanBasis $wwanBasis
                    Close-NsProbeBag -Bag $bagU -Stopwatch ([System.Diagnostics.Stopwatch]::StartNew())
                    $Shared.R_Up = $u
                    DirLine 'Upload' $u
                }
                $Shared.ThroughputVersion = [int]$Shared.ThroughputVersion + 1
            } else {
                WriteLog 'Measuring idle latency, then latency under load in both directions...'
                $lat = Invoke-NsLatencyAndThroughput -Gateway $gw -IdleSec 5 -Streams $Opt.Streams `
                        -DownSec 10 -UpSec 10 -EstMbps $probe.Mbps -Shared $Shared `
                        -VersionKey 'LatencyVersion' -BypassProxy:$Opt.BypassProxy -Wwan:$wwan -WwanBasis $wwanBasis
                $Shared.R_Latency = $lat
                DirLine 'Download' $lat.Down
                DirLine 'Upload'   $lat.Up
                if ($lat.GradeState -eq 'measured') {
                    WriteLog ('Bufferbloat grade {0} - latency rises up to {1} ms under load.' -f $lat.Grade, $lat.WorstAddedMs)
                } else {
                    WriteLog ('Bufferbloat grade withheld: {0}' -f $lat.GradeReason)
                }
                if ($lat.Queue) { WriteLog $lat.Queue.Summary }
                $Shared.LatencyVersion = [int]$Shared.LatencyVersion + 1
            }
            $Shared.SelfTestActive = $false
            # One stage feeds two sections in a sweep - both get the same clock.
            StageStop 'throughput'
            if ($Shared.Timing.ContainsKey('throughput')) { $Shared.Timing['latency'] = $Shared.Timing['throughput'] }
            $Shared.Progress = 70
        }

        # ---- hogs --------------------------------------------------------
        if (($Mode -eq 'sweep' -or $Mode -eq 'hogs') -and -not $Shared.Cancel) {
            StageStart
            WriteLog 'Looking for anything on this PC using the link...'
            $h = Get-NsHogs -InterfaceIndex $adapter.interfaceIndex -LinkSpeedMbps $adapter.linkSpeedMbps -SampleSec 3 -Shared $Shared -SelfPid $Opt.SelfPid
            $Shared.R_Hogs = $h
            if ($h.DO -and $h.DO.State -eq 'measured' -and $h.DO.ActiveJobs -gt 0) {
                WriteLog ('Delivery Optimization has {0} job(s) in progress with {1} still to fetch.' -f $h.DO.ActiveJobs, (Format-NsBytes $h.DO.ActiveRemainingBytes))
            }
            if ($h.Tcp -and $h.Tcp.Ok) { WriteLog ('{0} external connections across {1} processes.' -f $h.Tcp.Total, @($h.Tcp.Processes).Count) }
            StageStop 'hogs'
            $Shared.HogsReady = $true
            $Shared.Progress = 85
        }

        # ---- path --------------------------------------------------------
        if (($Mode -eq 'sweep' -or $Mode -eq 'path') -and -not $Shared.Cancel) {
            StageStart
            $skipTrace = ($Mode -eq 'sweep')
            if ($skipTrace) { WriteLog 'Checking routes, proxy and DNS...' }
            else            { WriteLog 'Tracing the path, timing DNS and measuring path MTU...' }
            $p = Get-NsPathInfo -Adapter $adapter -Shared $Shared -SkipTrace:$skipTrace
            if ($p.Dns -and $p.Dns.Verdict) { WriteLog $p.Dns.Verdict }
            if ($p.Vpn -and $p.Vpn.Suspected) { WriteLog $p.Vpn.Detail }
            # Which box traffic leaves through, and what it is. Here, once per
            # path stage - never on the UI thread, where it used to run on
            # every refresh.
            if (-not $Shared.Cancel) {
                $Shared.Status = 'Mapping the local path and identifying the gateway...'
                $eg = $null
                try { $eg = Get-NsEgressPath } catch { }
                $ids = @()
                try { $ids = @(Get-NsPathDeviceIdentities -EgressPath $eg) } catch { }
                $Shared.R_EgressPath = $eg
                $Shared.R_PathIds = [object[]]$ids
                if ($eg -and $eg.Ok) {
                    if ($eg.EgressDevice -ne $eg.LocalGateway) { WriteLog ('Traffic leaves through {0}, behind the default gateway {1}.' -f $eg.EgressDevice, $eg.LocalGateway) }
                    else { WriteLog ('Traffic leaves straight out through the default gateway {0}.' -f $eg.LocalGateway) }
                }
            }
            # Published LAST, together: the UI re-renders when it sees R_Path.
            $Shared.R_Path = $p
            StageStop 'path'
            $Shared.PathVersion = [int]$Shared.PathVersion + 1
            $Shared.Progress = 95
        }

        # ---- wifi --------------------------------------------------------
        if (($Mode -eq 'sweep' -or $Mode -eq 'wifi') -and -not $Shared.Cancel) {
            StageStart
            $w = Get-NsWifi -IncludeScan:($Mode -eq 'wifi')
            $Shared.R_Wifi = $w
            if ($w.State -eq 'measured') { WriteLog ('Wi-Fi: {0} on channel {1}, signal {2}%.' -f $w.Interface.ssid, $w.Interface.channel, $w.Interface.signalPct) }
            elseif ($Mode -eq 'wifi')    { WriteLog ('Wi-Fi: {0}' -f $w.Reason) }
            StageStop 'wifi'
            $Shared.WifiReady = $true
        }

        # ---- ETW ---------------------------------------------------------
        if ($Mode -eq 'etw') {
            StageStart
            WriteLog 'Starting a private kernel network trace (this is the only true per-process byte measurement here)...'
            $e = Invoke-NsEtwCapture -Seconds $Opt.EtwSeconds -Shared $Shared -VersionKey 'EtwVersion'
            $Shared.R_Etw = $e
            if ($e.State -eq 'measured') { WriteLog ('Captured {0:N0} events over {1:N0}s and attributed {2}.' -f $e.EventsParsed, $e.CaptureSec, (Format-NsBytes $e.TotalBytes)) }
            else { WriteLog ('ETW capture {0}: {1}' -f $e.State, $e.Reason) }
            StageStop 'etw'
            $Shared.EtwVersion = [int]$Shared.EtwVersion + 1
        }

        # ---- Ookla -------------------------------------------------------
        if ($Mode -eq 'ookla') {
            StageStart
            $Shared.SelfTestActive = $true
            WriteLog 'Running the Ookla CLI...'
            $o = Invoke-NsOoklaSpeedtest -Shared $Shared -AllowDownload:$Opt.AllowDownload
            $Shared.R_Ookla = $o
            if ($o.State -eq 'measured') {
                WriteLog ('[OK] Ookla: down {0}, up {1}, idle latency {2} ms.' -f (Format-NsMbps $o.DownMbps), (Format-NsMbps $o.UpMbps), $o.IdleLatencyMs)
                if ($o.ResultUrl) { WriteLog ('Result URL: {0}' -f $o.ResultUrl) }
            } else {
                WriteLog ('[FAIL] Ookla {0}: {1}' -f $o.State, $o.Reason)
            }
            $Shared.SelfTestActive = $false
            StageStop 'ookla'
            $Shared.OoklaReady = $true
        }

        # ---- soak --------------------------------------------------------
        if ($Mode -eq 'soak') {
            StageStart
            WriteLog ('Soak started for {0} minutes. Leave this running and reproduce the fault.' -f $Opt.SoakMinutes)
            $s = Invoke-NsSoak -Minutes $Opt.SoakMinutes -Gateway $gw -InterfaceIndex $adapter.interfaceIndex `
                    -LinkSpeedMbps $adapter.linkSpeedMbps -Shared $Shared -VersionKey 'SoakVersion' -BypassProxy:$Opt.BypassProxy
            $Shared.R_Soak = $s
            WriteLog $s.DropoutVerdict
            StageStop 'soak'
            $Shared.SoakVersion = [int]$Shared.SoakVersion + 1
        }

        $Shared.Progress = 100
        if ($Shared.Cancel) { WriteLog 'Stopped at your request.' } else { WriteLog 'Done.' }
    } catch {
        $Shared.Error = ('{0}{1}{2}' -f $_.Exception.Message, [Environment]::NewLine, $_.ScriptStackTrace)
        [void]$Shared.Log.Add(('[{0}] ERROR: {1}' -f (Get-Date -Format 'HH:mm:ss'), $_.Exception.Message))
    } finally {
        $Shared.SelfTestActive = $false
        $Shared.Done = $true
    }
}

# ---------------------------------------------------------------------------
# Live monitor sampler - its own runspace, because the main worker spends
# tens of seconds blocked inside a socket read and a 1 Hz sampler cannot live
# there. It is still rendered by the single UI timer.
# ---------------------------------------------------------------------------
$MonitorScript = {
    param($Shared, $HelpersSource, $InterfaceIndex, $LinkSpeedMbps)

    . ([scriptblock]::Create($HelpersSource))
    try {
        $ni = Get-NsNetInterfaceRef -InterfaceIndex $InterfaceIndex
        if (-not $ni) { $Shared.Error = 'No .NET interface matched the selected adapter.'; return }
        $prev = Get-NsInterfaceCounters -NetInterface $ni
        $samples = [Activator]::CreateInstance([System.Collections.Generic.List[object]])
        $tick = 0
        $top = @()
        while (-not $Shared.Cancel) {
            Start-Sleep -Milliseconds 1000
            $cur = Get-NsInterfaceCounters -NetInterface $ni
            if ($cur.Ok -and $prev.Ok) {
                $span = ($cur.AtMs - $prev.AtMs) / 1000.0
                if ($span -le 0) { $span = 1.0 }
                $dRx = Measure-CounterDelta -Previous $prev.BytesReceived -Current $cur.BytesReceived -IntervalSec $span -LinkSpeedMbps $LinkSpeedMbps
                $dTx = Measure-CounterDelta -Previous $prev.BytesSent     -Current $cur.BytesSent     -IntervalSec $span -LinkSpeedMbps $LinkSpeedMbps
                if ($dRx.Valid -and $dTx.Valid) {
                    # Both directions of each. A counter that went backwards
                    # was reset, not negative - it contributes nothing.
                    $e = [math]::Max(0, ($cur.InErrors - $prev.InErrors)) + [math]::Max(0, ($cur.OutErrors - $prev.OutErrors))
                    $d = [math]::Max(0, ($cur.InDiscards - $prev.InDiscards)) + [math]::Max(0, ($cur.OutDiscards - $prev.OutDiscards))
                    $Shared.TotalErrors = [double]$Shared.TotalErrors + $e
                    $Shared.TotalDiscards = [double]$Shared.TotalDiscards + $d
                    $samples.Add([pscustomobject]@{
                        DownMbps = ($dRx.Bytes * 8.0) / $span / 1000000.0
                        UpMbps   = ($dTx.Bytes * 8.0) / $span / 1000000.0
                        Errors   = $e
                        Discards = $d
                        Wrapped  = ($dRx.Wrapped -or $dTx.Wrapped)
                    })
                    while ($samples.Count -gt 60) { $samples.RemoveAt(0) }
                }
            }
            $prev = $cur
            $tick++
            # The connection table costs ~250 ms warm, which is far too heavy
            # to run every second alongside a 1 Hz sampler.
            if (($tick % 3) -eq 0) {
                $t = Get-NsExternalTcpByProcess
                if ($t.Ok) { $top = @($t.Processes | Select-Object -First 10) }
            }
            $Shared.Samples = [object[]]@($samples)
            $Shared.Top = [object[]]$top
            $Shared.Version = [int]$Shared.Version + 1
        }
    } catch {
        $Shared.Error = $_.Exception.Message
    } finally {
        $Shared.Done = $true
    }
}

# ---------------------------------------------------------------------------
# Worker lifecycle
# ---------------------------------------------------------------------------
function Set-Busy {
    param([bool]$On, [string]$Owner = '')
    $script:busy = $On
    $script:owner = $Owner
    $script:form.Cursor = $(if ($On) { [System.Windows.Forms.Cursors]::WaitCursor } else { [System.Windows.Forms.Cursors]::Default })
    foreach ($b in $script:stageButtons) {
        # A button disabled for a stated reason (ETW without elevation) stays
        # disabled. Re-enabling every button at the end of a run used to switch
        # it back on, past the reason printed beside it.
        if ($b.Tag -eq 'etw' -and -not $script:EtwAvailable) { $b.Enabled = $false; continue }
        # Only the soak button doubles as its own way out - a soak can run for
        # hours. Every other stage stops with Stop; leaving their buttons live
        # meant clicking Ookla again re-showed the licence and data warning and
        # then silently did nothing.
        if ($On -and $Owner -eq 'soak' -and $b.Tag -eq 'soak') { $b.Enabled = $true } else { $b.Enabled = -not $On }
    }
    if ($script:btnSoak) { $script:btnSoak.Text = $(if ($On -and $Owner -eq 'soak') { 'Stop Soak' } else { 'Start Soak' }) }
    # Clear mid-run wiped the results while the worker was still producing them.
    if ($script:btnClear) { $script:btnClear.Enabled = -not $On }
    $script:btnStop.Enabled = $On
    $script:cmbAdapter.Enabled = -not $On
}

function Start-Stage {
    param([string]$Mode, [hashtable]$Extra = @{})
    if ($script:busy) { return }

    # Cooldown, enforced here rather than by disabling a button, so that
    # button-mashing cannot burn a customer's data allowance.
    if ($Mode -eq 'sweep' -or $Mode -eq 'throughput' -or $Mode -eq 'latency' -or $Mode -eq 'ookla') {
        if ($script:lastRunAt -ne [datetime]::MinValue) {
            $since = ((Get-Date) - $script:lastRunAt).TotalSeconds
            $cool = (Get-NsLimits).CooldownSec
            if ($since -lt $cool) {
                Write-Log ('Waiting {0:N0}s before another transfer test - this stops repeated runs burning a metered allowance.' -f ($cool - $since))
                return
            }
        }
        $script:lastRunAt = Get-Date
    }

    $sh = [hashtable]::Synchronized(@{})
    $sh.Log = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
    $sh.Progress = 0; $sh.Status = 'Starting...'; $sh.Done = $false; $sh.Cancel = $false; $sh.Error = ''
    $sh.ThroughputVersion = 0; $sh.LatencyVersion = 0; $sh.PathVersion = 0
    $sh.EtwVersion = 0; $sh.SoakVersion = 0
    $sh.HogsReady = $false; $sh.WifiReady = $false; $sh.OoklaReady = $false
    $sh.SelfTestActive = $false
    $sh.ChildPid = 0
    $sh.Timing = [hashtable]::Synchronized(@{})
    $script:Shared = $sh
    $script:logIndex = 0
    $script:rendered = @{}
    $script:versions = @{}
    if ($script:startedUtc -eq [datetime]::MinValue) {
        $script:startedUtc = (Get-Date).ToUniversalTime()
        $script:startedSw = [System.Diagnostics.Stopwatch]::StartNew()
    }

    $opt = @{
        Adapter      = $script:Adapter
        Streams      = 6
        BypassProxy  = [bool]$script:chkBypassProxy.Checked
        SelfPid      = $PID
        EtwSeconds   = 20
        SoakMinutes  = 15
        AllowDownload = $false
    }
    foreach ($k in $Extra.Keys) { $opt[$k] = $Extra[$k] }

    try {
        $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $script:rs = [runspacefactory]::CreateRunspace($iss)
        $script:rs.ApartmentState = 'STA'
        $script:rs.Open()
        $script:ps = [powershell]::Create()
        $script:ps.Runspace = $script:rs
        [void]$script:ps.AddScript($WorkerScript.ToString())
        [void]$script:ps.AddParameter('Shared', $sh)
        [void]$script:ps.AddParameter('HelpersSource', $HelpersSource)
        [void]$script:ps.AddParameter('Mode', $Mode)
        [void]$script:ps.AddParameter('Opt', $opt)
        $script:async = $script:ps.BeginInvoke()
        Set-Busy -On $true -Owner $Mode
        $script:timer.Start()
    } catch {
        Write-Log ('Could not start the background worker: {0}' -f $_.Exception.Message)
        Set-Busy -On $false
    }
}

function Stop-Worker {
    if ($script:Shared) { $script:Shared.Cancel = $true }
    if ($script:MonShared) { $script:MonShared.Cancel = $true }
}

function Complete-Worker {
    try { if ($script:ps -and $script:async) { [void]$script:ps.EndInvoke($script:async) } } catch {}
    try { if ($script:ps) { $script:ps.Dispose() } } catch {}
    try { if ($script:rs) { $script:rs.Close(); $script:rs.Dispose() } } catch {}
    $script:ps = $null; $script:rs = $null; $script:async = $null
}

function Complete-Monitor {
    try { if ($script:monPs -and $script:monAsync) { [void]$script:monPs.EndInvoke($script:monAsync) } } catch {}
    try { if ($script:monPs) { $script:monPs.Dispose() } } catch {}
    try { if ($script:monRs) { $script:monRs.Close(); $script:monRs.Dispose() } } catch {}
    $script:monPs = $null; $script:monRs = $null; $script:monAsync = $null
}

function Start-Monitor {
    if ($script:monPs) { return }
    $ms = [hashtable]::Synchronized(@{})
    $ms.Cancel = $false; $ms.Done = $false; $ms.Version = 0; $ms.Error = ''
    $ms.Samples = @(); $ms.Top = @(); $ms.SelfPid = $PID
    $ms.TotalErrors = 0.0; $ms.TotalDiscards = 0.0
    $script:MonShared = $ms
    try {
        $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $script:monRs = [runspacefactory]::CreateRunspace($iss)
        $script:monRs.ApartmentState = 'STA'
        $script:monRs.Open()
        $script:monPs = [powershell]::Create()
        $script:monPs.Runspace = $script:monRs
        [void]$script:monPs.AddScript($MonitorScript.ToString())
        [void]$script:monPs.AddParameter('Shared', $ms)
        [void]$script:monPs.AddParameter('HelpersSource', $HelpersSource)
        [void]$script:monPs.AddParameter('InterfaceIndex', $script:Adapter.interfaceIndex)
        [void]$script:monPs.AddParameter('LinkSpeedMbps', $script:Adapter.linkSpeedMbps)
        $script:monAsync = $script:monPs.BeginInvoke()
        $script:btnMonitor.Text = 'Stop Monitor'
        Write-Log 'Live monitor started. Starting a speed test while this runs is supported - the tool''s own traffic is labelled, not hidden.'
        $script:timer.Start()
    } catch {
        Write-Log ('Could not start the monitor: {0}' -f $_.Exception.Message)
    }
}

function Stop-Monitor {
    if ($script:MonShared) { $script:MonShared.Cancel = $true }
    $script:btnMonitor.Text = 'Start Monitor'
}

# ---------------------------------------------------------------------------
# Form
# ---------------------------------------------------------------------------
$script:form = New-Object System.Windows.Forms.Form
$script:form.Text = ('Internet / Network Speed Troubleshooter  v{0}' -f (Get-NetSpeedVersion))
$script:form.Size = New-Object System.Drawing.Size(1180, 860)
$script:form.MinimumSize = New-Object System.Drawing.Size(1000, 700)
$script:form.StartPosition = 'CenterScreen'
$script:form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$root = New-Object System.Windows.Forms.TableLayoutPanel
$root.Dock = 'Fill'; $root.ColumnCount = 1; $root.RowCount = 3
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 158)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 190)))
$script:form.Controls.Add($root)

# ---- top strip ------------------------------------------------------------
$top = New-Object System.Windows.Forms.Panel
$top.Dock = 'Fill'
$root.Controls.Add($top, 0, 0)

$script:Adapter = Get-NsActiveAdapter
$lblCtx = New-Lbl -Text '' -Bold $true
$lblCtx.Location = New-Object System.Drawing.Point(10, 8)
$sysTag = ''
if ($script:Context.isSystem) { $sysTag = '  [SYSTEM]' }
elseif ($script:Context.elevated) { $sysTag = '  [elevated]' }
$lblCtx.Text = ('Context: {0}{1}     Host: {2}     PS {3}' -f $script:Context.runAs, $sysTag, $script:Context.computerName, $script:Context.psVersion)
$top.Controls.Add($lblCtx)

$script:lblLink = New-Lbl -Text '' -Bold $true
$script:lblLink.Location = New-Object System.Drawing.Point(10, 30)
$top.Controls.Add($script:lblLink)

function Update-LinkBanner {
    $a = $script:Adapter
    if (-not $a -or -not $a.name) {
        $script:lblLink.Text = 'Link: no active adapter found'
        $script:lblLink.ForeColor = [System.Drawing.Color]::Firebrick
        return
    }
    # Duplex is only shown, and only ever coloured, for a WIRED link. Wi-Fi is
    # half duplex by design - a radio cannot send and receive at once - so
    # printing "HALF DUPLEX" in red here contradicted the report, which
    # correctly calls it info. New-NsLinkSection and Get-NsSubscores were fixed
    # for this; the banner was missed because the tests covered those two
    # functions and not this one.
    $dup = ''
    if ((-not $a.isWireless) -and $null -ne $a.fullDuplex) {
        $dup = $(if ($a.fullDuplex) { ', full duplex' } else { ', HALF DUPLEX' })
    } elseif ($a.isWireless) {
        $dup = ', Wi-Fi'
    }
    $script:lblLink.Text = ('Link: {0}  -  {1} Mbps{2}  -  gw {3}  -  DNS {4}' -f `
        $a.name, $a.linkSpeedMbps, $dup, $a.gateway, ((@($a.dnsServers) -join ', ')))
    # On a wired link this single line closes more tickets than anything else
    # in the tool, so it is coloured before anything has been measured. Both
    # clauses are wired-only: a slow negotiation and a half-duplex negotiation
    # are both autonegotiation faults, and neither concept applies to a radio.
    $bad = (-not $a.isWireless) -and (
            ($a.linkSpeedMbps -gt 0 -and $a.linkSpeedMbps -lt 100) -or
            ($null -ne $a.fullDuplex -and -not $a.fullDuplex))
    $script:lblLink.ForeColor = $(if ($bad) { [System.Drawing.Color]::Firebrick } else { [System.Drawing.Color]::FromArgb(0,100,0) })
}
Update-LinkBanner

# Third banner line: is this the connection the site normally uses?
# A machine on the LAN cannot see the firewall's WAN interfaces, so this reports
# the fingerprints of a backup or secondary path rather than claiming to know
# there is one.
$script:lblRoute = New-Lbl -Text 'Route: not checked yet - run Quick Sweep.' -Bold $true
$script:lblRoute.Location = New-Object System.Drawing.Point(10, 52)
$script:lblRoute.AutoSize = $false
$script:lblRoute.Size = New-Object System.Drawing.Size(940, 18)
$script:lblRoute.ForeColor = [System.Drawing.Color]::DimGray
$top.Controls.Add($script:lblRoute)

$lblAd = New-Lbl -Text 'Adapter:'
$lblAd.Location = New-Object System.Drawing.Point(10, 78)
$top.Controls.Add($lblAd)

$script:cmbAdapter = New-Object System.Windows.Forms.ComboBox
$script:cmbAdapter.Location = New-Object System.Drawing.Point(70, 75)
$script:cmbAdapter.Width = 330
$script:cmbAdapter.DropDownStyle = 'DropDownList'
$script:AdapterList = @(Get-NsCandidateAdapters)
foreach ($a in $script:AdapterList) {
    $mark = ''
    if ($a.HasDefaultRoute) { $mark = ' *' }
    if ($a.Virtual) { $mark = ($mark + ' (virtual)') }
    [void]$script:cmbAdapter.Items.Add(('{0} - {1}{2}' -f $a.Name, $a.LinkSpeed, $mark))
}
for ($i = 0; $i -lt $script:AdapterList.Count; $i++) {
    if ($script:AdapterList[$i].InterfaceIndex -eq $script:Adapter.interfaceIndex) { $script:cmbAdapter.SelectedIndex = $i; break }
}
if ($script:cmbAdapter.SelectedIndex -lt 0 -and $script:cmbAdapter.Items.Count -gt 0) { $script:cmbAdapter.SelectedIndex = 0 }
$script:adapterIndex = $script:cmbAdapter.SelectedIndex

function Clear-Results {
    param([switch]$KeepLog)
    $script:R = @{}
    $script:Timing = @{}
    $script:startedUtc = [datetime]::MinValue
    $script:startedSw = $null
    if (-not $KeepLog) { $script:txtLog.Clear() }
    Refresh-AllTabs | Out-Null
}

$script:cmbAdapter.Add_SelectedIndexChanged({
    if ($script:adapterReverting) { return }
    $i = $script:cmbAdapter.SelectedIndex
    if ($i -lt 0 -or $i -ge $script:AdapterList.Count -or $i -eq $script:adapterIndex) { return }
    # A report describes ONE link. Results already on screen were measured
    # over the old adapter, and switching used to leave them in place under
    # the new adapter's link facts - a report that contradicts itself.
    if ($script:R.Count -gt 0) {
        $old = '(unknown)'; if ($script:Adapter -and $script:Adapter.name) { $old = $script:Adapter.name }
        $ans = [System.Windows.Forms.MessageBox]::Show(
            ('The results on screen were measured over {0}. A report has to describe one link, so switching adapter clears them.{1}{1}Save the report first if you need it. Switch and clear?' -f $old, [Environment]::NewLine),
            'Switch adapter?', 'YesNo', 'Question')
        if ($ans -ne 'Yes') {
            $script:adapterReverting = $true
            try { $script:cmbAdapter.SelectedIndex = $script:adapterIndex } finally { $script:adapterReverting = $false }
            return
        }
    }
    $script:adapterIndex = $i
    $script:Adapter = Get-NsActiveAdapter -PreferInterfaceIndex $script:AdapterList[$i].InterfaceIndex
    Update-LinkBanner
    if ($script:R.Count -gt 0) { Clear-Results -KeepLog }
    Write-Log ('Now testing over {0}.' -f $script:Adapter.name)
})
$top.Controls.Add($script:cmbAdapter)

$lblPlan = New-Lbl -Text 'Stated plan (Mbps)   down:'
$lblPlan.Location = New-Object System.Drawing.Point(420, 78)
$top.Controls.Add($lblPlan)

$script:numPlanDown = New-Object System.Windows.Forms.NumericUpDown
$script:numPlanDown.Location = New-Object System.Drawing.Point(585, 75)
$script:numPlanDown.Width = 70; $script:numPlanDown.Maximum = 100000; $script:numPlanDown.Value = 0
$top.Controls.Add($script:numPlanDown)

$lblUp = New-Lbl -Text 'up:'
$lblUp.Location = New-Object System.Drawing.Point(663, 78)
$top.Controls.Add($lblUp)

$script:numPlanUp = New-Object System.Windows.Forms.NumericUpDown
$script:numPlanUp.Location = New-Object System.Drawing.Point(688, 75)
$script:numPlanUp.Width = 70; $script:numPlanUp.Maximum = 100000; $script:numPlanUp.Value = 0
$top.Controls.Add($script:numPlanUp)

# Short enough to fit beside the plan boxes at the default width - the longer
# wording ran off the right edge of the window.
$lblPlanHint = New-Lbl -Text '0 = unknown. Nothing is graded against an invented plan.'
$lblPlanHint.Location = New-Object System.Drawing.Point(766, 78)
$lblPlanHint.ForeColor = [System.Drawing.Color]::DimGray
$top.Controls.Add($lblPlanHint)

$script:btnSweep = New-Btn -Text 'Quick Sweep' -W 150 -H 34
$script:btnSweep.Location = New-Object System.Drawing.Point(10, 110)
$script:btnSweep.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$script:btnSweep.Tag = 'sweep'
$script:btnSweep.Add_Click({ Start-Stage -Mode 'sweep' })
$top.Controls.Add($script:btnSweep)

$script:btnStop = New-Btn -Text 'Stop' -W 90 -H 34
$script:btnStop.Location = New-Object System.Drawing.Point(168, 110)
$script:btnStop.Enabled = $false
$script:btnStop.Add_Click({ Stop-Worker; Write-Log 'Stop requested...' })
$top.Controls.Add($script:btnStop)

$script:chkBypassProxy = New-Object System.Windows.Forms.CheckBox
$script:chkBypassProxy.Text = 'Bypass system proxy for transfers'
$script:chkBypassProxy.Location = New-Object System.Drawing.Point(270, 116)
$script:chkBypassProxy.AutoSize = $true
$top.Controls.Add($script:chkBypassProxy)

$btnCopy = New-Btn -Text 'Copy Report' -W 110 -H 34
$btnCopy.Location = New-Object System.Drawing.Point(530, 110)
$btnCopy.Add_Click({
    # Refresh-AllTabs already serialised the report into the Report tab; a
    # 100+ KB envelope is not worth building twice.
    Refresh-AllTabs | Out-Null
    $txt = $script:txtReport.Text
    try {
        [System.Windows.Forms.Clipboard]::SetText($txt)
        Write-Log 'Report copied to the clipboard.'
    } catch {
        # Session 0 / SYSTEM has no clipboard. Save is the guaranteed path in
        # a Backstage session, so point at it rather than failing silently.
        Write-Log 'The clipboard is not available in this session (this is normal under SYSTEM). Use Save Report instead - it is on the Report tab too.'
    }
})
$top.Controls.Add($btnCopy)

$btnSave = New-Btn -Text 'Save Report...' -W 120 -H 34
$btnSave.Location = New-Object System.Drawing.Point(648, 110)
$btnSave.Add_Click({
    Refresh-AllTabs | Out-Null
    $txt = $script:txtReport.Text
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'JSON report (*.json)|*.json|All files (*.*)|*.*'
    $dlg.FileName = ('NetSpeed_{0}_{1}.json' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    if ($dlg.ShowDialog() -eq 'OK') {
        try {
            $txt | Set-Content -LiteralPath $dlg.FileName -Encoding UTF8
            Write-Log ('Report saved to {0}' -f $dlg.FileName)
        } catch { Write-Log ('Could not save: {0}' -f $_.Exception.Message) }
    }
})
$top.Controls.Add($btnSave)

$script:btnClear = New-Btn -Text 'Clear' -W 80 -H 34
$script:btnClear.Location = New-Object System.Drawing.Point(776, 110)
$script:btnClear.Add_Click({
    Clear-Results
    Write-Log 'Cleared.'
})
$top.Controls.Add($script:btnClear)

# ---- tabs -----------------------------------------------------------------
$script:tabs = New-Object System.Windows.Forms.TabControl
$script:tabs.Dock = 'Fill'
$root.Controls.Add($script:tabs, 0, 1)

function Add-StageTab {
    param([string]$Title, [scriptblock]$AddButtons = $null, [int]$ButtonPanelHeight = 0)
    $tab = New-Tab -Text $Title
    $lay = New-Object System.Windows.Forms.TableLayoutPanel
    $lay.Dock = 'Fill'; $lay.ColumnCount = 1; $lay.RowCount = 3
    [void]$lay.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, $ButtonPanelHeight)))
    [void]$lay.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$lay.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 96)))
    $btnPanel = New-Object System.Windows.Forms.Panel
    $btnPanel.Dock = 'Fill'
    $lay.Controls.Add($btnPanel, 0, 0)
    $grid = New-ResultGrid
    $lay.Controls.Add($grid, 0, 1)
    $summary = New-SummaryBox
    $lay.Controls.Add($summary, 0, 2)
    $tab.Controls.Add($lay)
    [void]$script:tabs.TabPages.Add($tab)
    if ($AddButtons) { & $AddButtons $btnPanel }
    return [pscustomobject]@{ Tab = $tab; Grid = $grid; Summary = $summary; Buttons = $btnPanel }
}

$script:stageButtons = [Activator]::CreateInstance([System.Collections.Generic.List[object]])

# 1. Overview
$tOv = Add-StageTab -Title 'Overview'
$script:gridOverview = $tOv.Grid; $script:txtOverview = $tOv.Summary

# 2. Throughput
$tTp = Add-StageTab -Title 'Throughput' -ButtonPanelHeight 68 -AddButtons {
    param($p)
    $b1 = New-Btn -Text 'Cloudflare Multi-Stream' -W 190
    $b1.Location = New-Object System.Drawing.Point(4, 6); $b1.Tag = 'throughput'
    $b1.Add_Click({ Start-Stage -Mode 'throughput' })
    $p.Controls.Add($b1); [void]$script:stageButtons.Add($b1)

    $b2 = New-Btn -Text 'Ookla (authoritative)' -W 170
    $b2.Location = New-Object System.Drawing.Point(200, 6); $b2.Tag = 'ookla'
    $b2.Add_Click({
        $msg = @(
            'The Ookla CLI produces a speedtest.net Result URL, which is what an ISP will accept in a ticket.'
            ''
            'Before you run it, note that it:'
            '  - downloads a third-party binary OVER THE LINK YOU ARE TESTING (about 1 MB), if not already present'
            '    (kept in this account''s own profile, checked against a pinned SHA256 before every run)'
            '  - can consume 100-500 MB of the customer''s data on a fast link'
            '  - auto-accepts Ookla''s licence and GDPR notice on the customer''s behalf'
            ''
            'Continue?'
        ) -join [Environment]::NewLine
        $r = [System.Windows.Forms.MessageBox]::Show($msg, 'Run the Ookla speed test?', 'YesNo', 'Warning')
        if ($r -eq 'Yes') { Start-Stage -Mode 'ookla' -Extra @{ AllowDownload = $true } }
    })
    $p.Controls.Add($b2); [void]$script:stageButtons.Add($b2)

    $l = New-Lbl -Text 'The built-in engine needs no download and works under SYSTEM. Use Ookla when you need a URL to hand an ISP.'
    $l.Location = New-Object System.Drawing.Point(6, 42); $l.ForeColor = [System.Drawing.Color]::DimGray
    $p.Controls.Add($l)
}
$script:gridThroughput = $tTp.Grid; $script:txtThroughput = $tTp.Summary

# 3. Latency / Bufferbloat
$tLa = Add-StageTab -Title 'Latency / Bufferbloat' -ButtonPanelHeight 68 -AddButtons {
    param($p)
    $b = New-Btn -Text 'Latency + Bufferbloat' -W 190
    $b.Location = New-Object System.Drawing.Point(4, 6); $b.Tag = 'latency'
    $b.Add_Click({ Start-Stage -Mode 'latency' })
    $p.Controls.Add($b); [void]$script:stageButtons.Add($b)
    $l = New-Lbl -Text 'Measures idle latency, then latency while the link is deliberately saturated. Graded on the INCREASE, not the absolute value.'
    $l.Location = New-Object System.Drawing.Point(6, 42); $l.ForeColor = [System.Drawing.Color]::DimGray
    $p.Controls.Add($l)
}
$script:gridLatency = $tLa.Grid; $script:txtLatency = $tLa.Summary

# 4. Bandwidth hogs
$tHg = Add-StageTab -Title 'Bandwidth Hogs' -ButtonPanelHeight 68 -AddButtons {
    param($p)
    $b1 = New-Btn -Text 'Detect Hogs (inference)' -W 180
    $b1.Location = New-Object System.Drawing.Point(4, 6); $b1.Tag = 'hogs'
    $b1.Add_Click({ Start-Stage -Mode 'hogs' })
    $p.Controls.Add($b1); [void]$script:stageButtons.Add($b1)

    $b2 = New-Btn -Text 'ETW Deep Capture (20s)' -W 180
    $b2.Location = New-Object System.Drawing.Point(190, 6); $b2.Tag = 'etw'
    $b2.Add_Click({ Start-Stage -Mode 'etw' -Extra @{ EtwSeconds = 20 } })
    $p.Controls.Add($b2); [void]$script:stageButtons.Add($b2)
    $script:btnEtw = $b2

    $l = New-Lbl -Text ''
    $l.Location = New-Object System.Drawing.Point(6, 42); $l.ForeColor = [System.Drawing.Color]::DimGray
    $pre = Test-NsEtwPreconditions
    $script:EtwAvailable = [bool]$pre.Ok
    if ($pre.Ok) {
        $l.Text = 'Inference identifies suspects from connection counts. The ETW capture measures real bytes per process, and needs 20s plus parse time.'
    } else {
        $b2.Enabled = $false
        $l.Text = ('ETW deep capture is unavailable: {0}' -f $pre.Reason)
        $l.ForeColor = [System.Drawing.Color]::Firebrick
    }
    $p.Controls.Add($l)
}
$script:gridHogs = $tHg.Grid; $script:txtHogs = $tHg.Summary

# 5. Live monitor
$tMon = New-Tab -Text 'Live Monitor'
$monLay = New-Object System.Windows.Forms.TableLayoutPanel
$monLay.Dock = 'Fill'; $monLay.ColumnCount = 1; $monLay.RowCount = 3
[void]$monLay.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 68)))
[void]$monLay.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$monLay.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 96)))
$monBtns = New-Object System.Windows.Forms.Panel
$monBtns.Dock = 'Fill'
$script:btnMonitor = New-Btn -Text 'Start Monitor' -W 150
$script:btnMonitor.Location = New-Object System.Drawing.Point(4, 6)
$script:btnMonitor.Add_Click({
    if ($script:monPs) { Stop-Monitor } else { Start-Monitor }
})
$monBtns.Controls.Add($script:btnMonitor)
$lmon = New-Lbl -Text 'Samples the adapter once a second and refreshes top talkers every third second. Leave it running while the user reproduces the fault.'
$lmon.Location = New-Object System.Drawing.Point(6, 42); $lmon.ForeColor = [System.Drawing.Color]::DimGray
$monBtns.Controls.Add($lmon)
$monLay.Controls.Add($monBtns, 0, 0)
$script:gridMonitor = New-ResultGrid
$monLay.Controls.Add($script:gridMonitor, 0, 1)
$script:txtMonitor = New-Object System.Windows.Forms.TextBox
$script:txtMonitor.Multiline = $true; $script:txtMonitor.ReadOnly = $true; $script:txtMonitor.Dock = 'Fill'
$script:txtMonitor.Font = New-Object System.Drawing.Font('Consolas', 9)
$script:txtMonitor.BackColor = [System.Drawing.Color]::FromArgb(245,245,245)
$monLay.Controls.Add($script:txtMonitor, 0, 2)
$tMon.Controls.Add($monLay)
[void]$script:tabs.TabPages.Add($tMon)

# 6. Wi-Fi
$tWf = Add-StageTab -Title 'Wi-Fi' -ButtonPanelHeight 68 -AddButtons {
    param($p)
    $b = New-Btn -Text 'Wi-Fi Deep Dive' -W 160
    $b.Location = New-Object System.Drawing.Point(4, 6); $b.Tag = 'wifi'
    $b.Add_Click({ Start-Stage -Mode 'wifi' })
    $p.Controls.Add($b); [void]$script:stageButtons.Add($b)
    $l = New-Lbl -Text 'Signal, band, channel, negotiated rate and a scan of the neighbourhood. Reports unsupported on a wired machine.'
    $l.Location = New-Object System.Drawing.Point(6, 42); $l.ForeColor = [System.Drawing.Color]::DimGray
    $p.Controls.Add($l)
}
$script:gridWifi = $tWf.Grid; $script:txtWifi = $tWf.Summary

# 7. Path & infrastructure
$tPa = Add-StageTab -Title 'Path and Infrastructure' -ButtonPanelHeight 68 -AddButtons {
    param($p)
    $b = New-Btn -Text 'Path and DNS' -W 160
    $b.Location = New-Object System.Drawing.Point(4, 6); $b.Tag = 'path'
    $b.Add_Click({ Start-Stage -Mode 'path' })
    $p.Controls.Add($b); [void]$script:stageButtons.Add($b)
    $l = New-Lbl -Text 'Hop-by-hop latency, DNS resolver timing against public resolvers, path MTU, VPN and proxy detection, NIC power settings.'
    $l.Location = New-Object System.Drawing.Point(6, 42); $l.ForeColor = [System.Drawing.Color]::DimGray
    $p.Controls.Add($l)
}
$script:gridPath = $tPa.Grid; $script:txtPath = $tPa.Summary

# 8. Soak
$tSo = Add-StageTab -Title 'Soak / Intermittent' -ButtonPanelHeight 68 -AddButtons {
    param($p)
    $b = New-Btn -Text 'Start Soak' -W 130
    $b.Location = New-Object System.Drawing.Point(4, 6); $b.Tag = 'soak'
    $script:btnSoak = $b
    $cmb = New-Object System.Windows.Forms.ComboBox
    $cmb.Location = New-Object System.Drawing.Point(142, 8); $cmb.Width = 150
    $cmb.DropDownStyle = 'DropDownList'
    foreach ($o in @('15 minutes','60 minutes','240 minutes')) { [void]$cmb.Items.Add($o) }
    $cmb.SelectedIndex = 0
    $script:cmbSoak = $cmb
    $p.Controls.Add($cmb)
    $b.Add_Click({
        if ($script:busy -and $script:owner -eq 'soak') { Stop-Worker; Write-Log 'Stop requested...'; return }
        $mins = 15
        switch ($script:cmbSoak.SelectedIndex) { 1 { $mins = 60 } 2 { $mins = 240 } }
        Start-Stage -Mode 'soak' -Extra @{ SoakMinutes = $mins }
    })
    $p.Controls.Add($b); [void]$script:stageButtons.Add($b)
    $l = New-Lbl -Text 'For "it only goes slow sometimes". Under 15 minutes the tool refuses to draw any conclusion from a clean run.'
    $l.Location = New-Object System.Drawing.Point(6, 42); $l.ForeColor = [System.Drawing.Color]::DimGray
    $p.Controls.Add($l)
}
$script:gridSoak = $tSo.Grid; $script:txtSoak = $tSo.Summary

# 9. Link facts
$tLk = Add-StageTab -Title 'Link Facts'
$script:gridLink = $tLk.Grid; $script:txtLink = $tLk.Summary

# 10. Report
$tRp = New-Tab -Text 'Report (JSON)'
$rpLay = New-Object System.Windows.Forms.TableLayoutPanel
$rpLay.Dock = 'Fill'; $rpLay.ColumnCount = 1; $rpLay.RowCount = 2
[void]$rpLay.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 44)))
[void]$rpLay.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$rpBtns = New-Object System.Windows.Forms.Panel
$rpBtns.Dock = 'Fill'
$bRebuild = New-Btn -Text 'Rebuild' -W 100 -H 28
$bRebuild.Location = New-Object System.Drawing.Point(4, 6)
$bRebuild.Add_Click({ Refresh-AllTabs | Out-Null; Write-Log 'Report rebuilt.' })
$rpBtns.Controls.Add($bRebuild)
$lrp = New-Lbl -Text 'Fenced JSON: what Save Report writes, and what NetSpeed_HTML_Report.ps1 renders. Copy Report and Save Report are in the top bar.'
$lrp.Location = New-Object System.Drawing.Point(115, 12); $lrp.ForeColor = [System.Drawing.Color]::DimGray
$rpBtns.Controls.Add($lrp)
$rpLay.Controls.Add($rpBtns, 0, 0)
$script:txtReport = New-Object System.Windows.Forms.TextBox
$script:txtReport.Multiline = $true; $script:txtReport.ReadOnly = $true; $script:txtReport.Dock = 'Fill'
$script:txtReport.ScrollBars = 'Both'; $script:txtReport.WordWrap = $false
# Programmatic assignment is not limited by MaxLength, but a technician who
# select-alls and copies out of this box would be, so it is lifted here too.
$script:txtReport.MaxLength = 0
$script:txtReport.BackColor = [System.Drawing.Color]::White
$script:txtReport.ForeColor = [System.Drawing.Color]::FromArgb(29,33,38)
$script:txtReport.Font = New-Object System.Drawing.Font('Consolas', 9)
$rpLay.Controls.Add($script:txtReport, 0, 1)
$tRp.Controls.Add($rpLay)
[void]$script:tabs.TabPages.Add($tRp)

# ---- bottom panel ---------------------------------------------------------
$bottom = New-Object System.Windows.Forms.Panel
$bottom.Dock = 'Fill'
$root.Controls.Add($bottom, 0, 2)

$script:prog = New-Object System.Windows.Forms.ProgressBar
$script:prog.Style = 'Continuous'
$script:prog.Location = New-Object System.Drawing.Point(10, 6)
$script:prog.Width = 1140; $script:prog.Height = 16
$script:prog.Anchor = 'Top,Left,Right'
$bottom.Controls.Add($script:prog)

$script:lblStatus = New-Lbl -Text 'Ready.'
$script:lblStatus.Location = New-Object System.Drawing.Point(10, 28)
$bottom.Controls.Add($script:lblStatus)

$script:txtLog = New-Object System.Windows.Forms.TextBox
$script:txtLog.Multiline = $true; $script:txtLog.ReadOnly = $true
$script:txtLog.ScrollBars = 'Vertical'
$script:txtLog.Location = New-Object System.Drawing.Point(10, 50)
$script:txtLog.Size = New-Object System.Drawing.Size(1140, 130)
$script:txtLog.Anchor = 'Top,Bottom,Left,Right'
$script:txtLog.BackColor = [System.Drawing.Color]::FromArgb(30,30,30)
$script:txtLog.ForeColor = [System.Drawing.Color]::Gainsboro
$script:txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$bottom.Controls.Add($script:txtLog)

# ---------------------------------------------------------------------------
# One timer renders BOTH the worker and the monitor. Two timers would mean two
# teardown paths and a second place to leak a runspace.
# ---------------------------------------------------------------------------
function Sync-WorkerLog {
    # Move any new worker log lines into the log box. Called at the top of
    # every tick AND once more when the worker finishes: the worker writes its
    # last lines ("Done.", the Ookla result URL) a moment before it sets Done,
    # and a tick that drained before them and then saw Done used to null the
    # shared state with those lines still in it. Measured: every sweep in the
    # baseline lost its final "Done.".
    param($Sh)
    if (-not $Sh) { return }
    while ($script:logIndex -lt $Sh.Log.Count) {
        $script:txtLog.AppendText([string]$Sh.Log[$script:logIndex] + [Environment]::NewLine)
        $script:logIndex++
    }
}

# Every raw result the worker can publish, as $script:R key -> $Shared.R_<key>.
$script:ResultKeys = @('Down','Up','Latency','Hogs','Path','EgressPath','PathIds','Wifi','Etw','Soak','Ookla')

function Update-FromShared {
    # Copy published results into $script:R, and say whether anything actually
    # changed. The worker bumps its version marks every 500 ms during a
    # transfer while the result objects stay null until the stage ends, and
    # re-rendering every tab and re-serialising the report on each bump was
    # pure cost on the UI thread. A reference compare is free.
    param($Sh)
    $changed = $false
    foreach ($k in $script:ResultKeys) {
        $val = $Sh.('R_' + $k)
        if ($null -ne $val -and -not [object]::ReferenceEquals($script:R[$k], $val)) {
            $script:R[$k] = $val
            $changed = $true
        }
    }
    return $changed
}

$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = 200
$script:timer.Add_Tick({
    # A modal dialog pumps WM_TIMER, so this handler can be re-entered from
    # inside itself. It used to show the worker-error MessageBox before
    # tearing the worker down, and every re-entrant tick then found the same
    # error and opened another box - one every 200 ms.
    if ($script:inTick) { return }
    $script:inTick = $true
    $pendingError = ''
    try {
        $needRefresh = $false
        # ---- main worker ----
        $sh = $script:Shared
        if ($sh) {
            if ($sh.Timing) {
                foreach ($tk in @($sh.Timing.Keys)) { $script:Timing[$tk] = $sh.Timing[$tk] }
            }
            Sync-WorkerLog -Sh $sh
            if ($sh.Status) { $script:lblStatus.Text = [string]$sh.Status }
            $p = [int]$sh.Progress
            if ($p -ge 0 -and $p -le 100) { $script:prog.Value = $p }
            if (Update-FromShared -Sh $sh) { $needRefresh = $true }

            if ($sh.Done) {
                Sync-WorkerLog -Sh $sh
                [void](Update-FromShared -Sh $sh)
                $pendingError = [string]$sh.Error
                if ($pendingError) { Write-Log ('ERROR: {0}' -f ($pendingError -split [Environment]::NewLine)[0]) }
                # The cooldown protects a metered allowance, so it counts from
                # when a transfer test ENDED. Stamped only at the start, it had
                # always expired by the time a one-minute sweep finished.
                $wasTransfer = (@('sweep','throughput','latency','ookla') -contains $script:owner)
                Complete-Worker
                $script:Shared = $null
                if ($wasTransfer) { $script:lastRunAt = Get-Date }
                Set-Busy -On $false
                $script:prog.Value = 0
                $script:lblStatus.Text = 'Ready.'
                $needRefresh = $true
            }
        }
        if ($needRefresh) { Refresh-AllTabs | Out-Null }

        # ---- live monitor (independent teardown) ----
        $ms = $script:MonShared
        if ($ms) {
            $v = [int]$ms.Version
            $seen = 0
            if ($script:versions.ContainsKey('MonVersion')) { $seen = [int]$script:versions['MonVersion'] }
            if ($v -ne $seen) {
                $script:versions['MonVersion'] = $v
                Render-Monitor -Mon $ms
            }
            if ($ms.Done) {
                if ($ms.Error) { Write-Log ('Monitor error: {0}' -f $ms.Error) }
                Complete-Monitor
                $script:MonShared = $null
                $script:btnMonitor.Text = 'Start Monitor'
                Write-Log 'Live monitor stopped.'
            }
        }

        if (-not $script:Shared -and -not $script:MonShared) { $script:timer.Stop() }
    } finally {
        $script:inTick = $false
    }
    # Only now, with the worker torn down and $script:Shared cleared, so a
    # re-entrant tick has nothing left to report.
    if ($pendingError) {
        [void][System.Windows.Forms.MessageBox]::Show($pendingError, 'NetSpeed Troubleshooter', 'OK', 'Error')
    }
})

$script:form.Add_FormClosing({
    Stop-Worker
    # Mirrors the teardown in the tick handler. A leaked ETW session survives
    # process exit and keeps writing to disk, so it is stopped unconditionally.
    Complete-Worker
    Complete-Monitor
    try { Stop-NsEtwSession } catch {}
    try { if ($script:timer) { $script:timer.Stop(); $script:timer.Dispose() } } catch {}
})

# ---------------------------------------------------------------------------
Write-Log ('NetSpeed Troubleshooter v{0} ready.' -f (Get-NetSpeedVersion))
Write-Log ('Testing over {0} ({1} Mbps). Change the adapter above if that is wrong.' -f $script:Adapter.name, $script:Adapter.linkSpeedMbps)
if (-not $script:Context.elevated) { Write-Log 'Not elevated: the ETW deep capture is disabled and BITS will only show this account''s jobs.' }
foreach ($pn in @(Get-NsPlatformNotes)) { Write-Log $pn }
Write-Log 'Quick Sweep takes about a minute and answers most "the internet is slow" tickets on its own.'
try { $script:EgressHistory = Get-NsEgressHistory } catch { }
if ($script:EgressHistory -and $script:EgressHistory.State -eq 'measured') {
    Write-Log ('Egress history: {0} samples over {1:N1} hours, {2} public address(es) seen.' -f `
        $script:EgressHistory.Samples, $script:EgressHistory.SpanHours, @($script:EgressHistory.Addresses).Count)
    if ($script:EgressHistory.Flapping) {
        Write-Log 'This site has changed public address more than once. It moves between internet connections, so anything measured here describes whichever one is live right now.'
    }
} else {
    Write-Log 'No egress history on this machine yet. Watch-NsEgress.ps1 -Install "true" records which internet connection the site is on over time, which is what makes the route indicator conclusive rather than suggestive.'
}

# Changing the stated plan re-grades what is already on screen. It used to
# need a manual Rebuild, so a plan typed in after a sweep left the verdict
# saying "no plan was entered". Debounced, because holding an arrow key on a
# NumericUpDown fires once per step and each refresh re-serialises the report.
$script:planDebounce = New-Object System.Windows.Forms.Timer
$script:planDebounce.Interval = 400
$script:planDebounce.Add_Tick({ $script:planDebounce.Stop(); Refresh-AllTabs | Out-Null })
$script:numPlanDown.Add_ValueChanged({ $script:planDebounce.Stop(); $script:planDebounce.Start() })
$script:numPlanUp.Add_ValueChanged({ $script:planDebounce.Stop(); $script:planDebounce.Start() })

Refresh-AllTabs | Out-Null
[void]$script:form.ShowDialog()
