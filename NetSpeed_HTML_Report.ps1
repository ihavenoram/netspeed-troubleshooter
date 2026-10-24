# NetSpeed Troubleshooter 1.1.2 - https://ihavenoram.com - https://github.com/ihavenoram/netspeed-troubleshooter
# MIT licence, (c) 2026 ihavenoram.com. If you publish something built on this, please credit ihavenoram.com.
<#
=========================================================
Script Name: NetSpeed_HTML_Report
Description: RENDER ONLY - this script never collects anything and never touches
             the network. It turns a NetSpeed diagnostic into a single
             self-contained HTML file you can email to a client or an ISP.

             Run it with no arguments for a small window: browse or drop a file
             in, or paste the report text, and press Render.

             From the command line it takes any of:
               -JsonPath  a .json saved by the GUI
               -Json      EITHER a path, OR raw JSON, OR a whole pasted report
                          log with console output around it
               (nothing)  the newest report next to this script, then the newest
                          under -ReportPath

             Output lands in the folder this script is running from, which is
             where a technician expects to find it. It falls back to
             C:\ProgramData\NetSpeedTroubleshooter only when that folder is not
             writable or is a temp location an RMM will clean up.

             It deliberately does not load NetSpeed-Troubleshooter.Helpers.ps1.
             A renderer that can measure is a renderer that can be blamed for a
             measurement, and this one is meant to be safe to run anywhere.

Category:    ScriptLibrary
Run Time:    1 minute
Arguments:   [-JsonPath <file>] [-Json <path|text>] [-OutPath <file>] [-NoOpen] [-NoGui]
Run As:      Current logged-on user
=========================================================
#>
[CmdletBinding()]
param(
    [string]$JsonPath,
    [string]$Json,
    [string]$ReportPath,
    [string]$OutPath,
    [switch]$NoOpen,
    [switch]$Gui,
    [switch]$NoGui
)

$ErrorActionPreference = 'Stop'
$RendererVersion = '1.1.0'

function Fail { param([string]$m) Write-Host ('[FAIL] {0}' -f $m) -ForegroundColor Red; exit 1 }
function Say  { param([string]$m, [string]$t = 'INFO') Write-Host ('[{0}] {1}' -f $t, $m) }

# ---------------------------------------------------------------------------
# Where output goes
# ---------------------------------------------------------------------------
function Get-NsDefaultOutDir {
    # The folder the script is running from, because that is where whoever ran
    # it will look. ProgramData is only a fallback: it is the right answer under
    # an RMM (whose working directory is a temp path that gets cleaned) and the
    # wrong answer for a technician who just ran the script from a folder.
    $cand = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($cand)) { $cand = (Get-Location).Path }
    $isTemp = ($cand -match '(?i)\\Windows\\Temp(\\|$)|\\AppData\\Local\\Temp(\\|$)')
    if (-not $isTemp) {
        try {
            $probe = Join-Path $cand ('.nswrite_' + [guid]::NewGuid().ToString('N') + '.tmp')
            [System.IO.File]::WriteAllText($probe, 'x')
            Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
            return $cand
        } catch { }
    }
    return (Join-Path $env:ProgramData 'NetSpeedTroubleshooter')
}
if ([string]::IsNullOrWhiteSpace($ReportPath)) { $ReportPath = Get-NsDefaultOutDir }

# ---------------------------------------------------------------------------
# Input resolution
# ---------------------------------------------------------------------------
function Resolve-NsReportText {
    # Turns whatever was supplied into the raw text of a report.
    #
    # -Json is deliberately forgiving: a technician who types
    # "-Json test.json" means the file, not a JSON document that happens to
    # read "test.json". Anything that resolves to an existing file is read;
    # anything else is treated as literal text.
    param([string]$PathArg, [string]$TextArg, [string]$SearchDir)
    $out = [pscustomobject]@{ Text = ''; Source = ''; Ok = $false; Error = '' }

    if ($PathArg) {
        if (-not (Test-Path -LiteralPath $PathArg)) { $out.Error = ('No such file: {0}' -f $PathArg); return $out }
        $out.Text = Get-Content -LiteralPath $PathArg -Raw
        $out.Source = (Resolve-Path -LiteralPath $PathArg).Path
        $out.Ok = $true
        return $out
    }

    if ($TextArg) {
        $trimmed = $TextArg.Trim()
        # Short, single-line, no braces -> almost certainly a path.
        $looksLikePath = ($trimmed.Length -lt 260 -and $trimmed -notmatch '[\r\n]' -and $trimmed -notmatch '[{}]')
        if ($looksLikePath) {
            $try = @($trimmed, (Join-Path (Get-Location).Path $trimmed))
            if ($SearchDir) { $try += (Join-Path $SearchDir $trimmed) }
            foreach ($t in $try) {
                try { if (Test-Path -LiteralPath $t -PathType Leaf) {
                    $out.Text = Get-Content -LiteralPath $t -Raw
                    $out.Source = (Resolve-Path -LiteralPath $t).Path
                    $out.Ok = $true
                    return $out
                } } catch { }
            }
            if ($trimmed -notmatch '<<<NETSPEED' -and $trimmed -notmatch '^\s*\{') {
                $out.Error = ('"{0}" is neither a file that exists nor JSON. If you meant a file, check the path; if you meant to paste a report, paste the whole thing.' -f $trimmed)
                return $out
            }
        }
        $out.Text = $TextArg
        $out.Source = 'pasted text'
        $out.Ok = $true
        return $out
    }

    # Nothing supplied: newest report beside the script, then under ReportPath.
    $dirs = @()
    if ($SearchDir) { $dirs += $SearchDir }
    $pd = Join-Path $env:ProgramData 'NetSpeedTroubleshooter'
    if ($dirs -notcontains $pd) { $dirs += $pd }
    foreach ($dir in $dirs) {
        $newest = @(Get-ChildItem -LiteralPath $dir -Filter 'NetSpeed_*.json' -File -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1)
        if ($newest.Count -gt 0) {
            $out.Text = Get-Content -LiteralPath $newest[0].FullName -Raw
            $out.Source = $newest[0].FullName
            $out.Ok = $true
            return $out
        }
    }
    $out.Error = ('Nothing to render. Pass a .json file, paste a report, or put a NetSpeed_*.json in {0}.' -f ($dirs -join ' or '))
    return $out
}

function Get-NsJsonMarkerNames {
    # Hard-coded on purpose: this script renders and never loads the helpers.
    @{ Begin = '<<<NETSPEED_JSON_BEGIN>>>'; End = '<<<NETSPEED_JSON_END>>>' }
}

function ConvertFrom-NsReportText {
    param([string]$Raw)
    $out = [pscustomobject]@{ Doc = $null; Ok = $false; Error = ''; Count = 1 }
    $text = $Raw

    # Extract the fenced envelope, tolerating console noise on both sides.
    #
    # (?s) is inline in the PATTERN, not passed to Matches(): on a Regex
    # INSTANCE the two-argument Matches overload is Matches(input, startat), so
    # passing RegexOptions::Singleline (16) silently becomes "start at index 16"
    # and throws ArgumentOutOfRange on any input shorter than that. That is not
    # a hypothetical - it is how "-Json test.json" first failed.
    # A half-arrived report is the single most likely thing to be handed to this
    # function, so it is detected explicitly. A JSON parser error tells the
    # reader nothing about the real cause.
    $m = Get-NsJsonMarkerNames
    if ($text -match [regex]::Escape($m.Begin) -and $text -notmatch [regex]::Escape($m.End)) {
        $out.Error = ('This report is incomplete - it has the opening {0} marker but not the closing {1}. It was cut off in transit. If you pasted it, the source was probably truncated: use Save Report in the GUI and point this at the .json file instead, which has no size limit.' -f $m.Begin, $m.End)
        return $out
    }
    $rx = [regex]'(?s)<<<NETSPEED_JSON_BEGIN>>>\s*(?<j>.*?)\s*<<<NETSPEED_JSON_END>>>'
    $ms = $rx.Matches($text)
    if ($ms.Count -gt 0) {
        # The LAST match, not the first: a technician pastes two runs into one
        # buffer more often than you would think, and silently rendering the
        # older one is a nasty way to waste an afternoon.
        $out.Count = $ms.Count
        $text = $ms[$ms.Count - 1].Groups['j'].Value
    }

    # Assign FIRST, then normalise. Never @($raw | ConvertFrom-Json) - piping
    # collapses the object on PS 5.1.
    $d = $null
    try {
        $d = $text | ConvertFrom-Json
    } catch {
        if ($_.Exception.Message -match 'maxJsonLength|exceeds the value set') {
            $out.Error = 'This report is too large for Windows PowerShell 5.1''s JSON parser (about 2 MB). Render it with PowerShell 7, or use the inline copy from the RMM log, which is shed to fit.'
        } elseif ($text.TrimStart().StartsWith('{') -and -not $text.TrimEnd().EndsWith('}')) {
            $out.Error = ('This looks like a report that was cut off - it starts with "{" but never closes. Use Save Report in the GUI and point this at the .json file, which has no size limit. ({0} characters received.)' -f $text.Length)
        } else {
            $out.Error = ('That does not parse as JSON: {0}' -f $_.Exception.Message)
        }
        return $out
    }
    if (-not $d -or -not $d.schema) {
        $out.Error = 'That parsed as JSON, but it is not a NetSpeed diagnostic report (no schema field).'
        return $out
    }
    $out.Doc = $d
    $out.Ok = $true
    return $out
}

# ---------------------------------------------------------------------------
# HTML helpers
# ---------------------------------------------------------------------------
function HtmlEnc {
    # NOT named "H". PowerShell resolves ALIASES BEFORE FUNCTIONS, and `h` is a
    # built-in alias for Get-History - so a `function H` is never called, and
    # every call instead binds its argument to Get-History's -Id parameter and
    # dies with "Cannot convert value ... to type System.Int64". Nothing about
    # that error mentions the real cause. Avoid single-letter function names;
    # `r` (Invoke-History) is the same trap.
    param($Text)
    if ($null -eq $Text) { return '' }
    $s = [string]$Text
    $s = $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
    return $s
}
function Slug { param([string]$s) return (($s -replace '[^A-Za-z0-9]+', '-').Trim('-').ToLower()) }

function Get-ReportCss {
@'
:root{--bg:#f6f7f9;--card:#fff;--ink:#1d2126;--muted:#63707e;--line:#dde3ea;
--ok:#0a7d32;--warn:#b06a00;--bad:#c02020;--info:#5a6673;--accentbg:#eef2f7}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);
font:14px/1.5 "Segoe UI",system-ui,-apple-system,sans-serif}
.wrap{max-width:1180px;margin:0 auto;padding:24px 20px 64px}
h1{font-size:22px;margin:0 0 4px} h2{font-size:17px;margin:0}
.sub{color:var(--muted);font-size:13px}
.banner{border-radius:10px;padding:18px 20px;margin:18px 0;color:#fff}
.note-bad{border-left:5px solid #b3261e;background:#fdecea;color:#5f1512}
.banner h1{color:#fff} .banner .lede{font-size:15px;margin-top:6px}
.b-red{background:#b3251f} .b-amber{background:#9a6400} .b-green{background:#116b2e}
.b-grey{background:#5c6773}
.note{background:#fff6e5;border:1px solid #f0d9a8;border-left:4px solid #c9922b;
border-radius:8px;padding:12px 14px;margin:14px 0;font-size:13px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;
margin:16px 0;overflow:hidden}
.card>header{display:flex;align-items:center;gap:10px;padding:12px 16px;
border-bottom:1px solid var(--line);background:var(--accentbg)}
.card>.body{padding:14px 16px}
.pill{display:inline-block;padding:2px 9px;border-radius:999px;font-size:11px;
font-weight:600;letter-spacing:.03em;text-transform:uppercase}
.p-ok{background:#e2f3e7;color:var(--ok)} .p-warn{background:#fdf0dc;color:var(--warn)}
.p-bad{background:#fbe4e4;color:var(--bad)} .p-info{background:#e9edf1;color:var(--info)}
.callout{border-radius:8px;padding:11px 13px;margin:0 0 12px;font-size:13px}
.c-bad{background:#fbe9e9;border:1px solid #f0c4c4;border-left:4px solid var(--bad)}
.c-grey{background:#f1f3f5;border:1px solid #dfe4e9;border-left:4px solid #97a3af}
.c-proxy{background:#eef4fb;border:1px solid #ccdcf0;border-left:4px solid #3a6ea5}
.meta{color:var(--muted);font-size:12.5px;margin:0 0 10px}
ul.cav{margin:6px 0 10px 18px;padding:0;color:var(--muted);font-size:12.5px}
table{width:100%;border-collapse:collapse;font-size:13px}
th,td{text-align:left;padding:7px 9px;border-bottom:1px solid var(--line);
vertical-align:top}
th{background:#f2f5f8;font-weight:600;cursor:pointer;user-select:none;white-space:nowrap}
th:hover{background:#e7edf3}
td.res{font-weight:600;white-space:nowrap}
.t-ok{color:var(--ok)} .t-warn{color:var(--warn)} .t-bad{color:var(--bad)}
.t-info{color:var(--info)}
td.det{color:var(--muted);font-size:12.5px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:10px}
.kv{background:#fafbfc;border:1px solid var(--line);border-radius:8px;padding:9px 11px}
.kv .k{color:var(--muted);font-size:11.5px;text-transform:uppercase;letter-spacing:.04em}
.kv .v{font-weight:600;margin-top:2px;word-break:break-word}
ol.limits{margin:6px 0 0 20px;padding:0;font-size:13px;color:#3c4550}
ol.limits li{margin:5px 0}
footer{color:var(--muted);font-size:12px;margin-top:26px;text-align:center}
.badge{background:#33404d;color:#fff;padding:2px 7px;border-radius:5px;font-size:11px}
@media print{body{background:#fff}.card{break-inside:avoid}}
'@
}

function Get-SortScript {
@'
function sortTable(th){
  var t=th.closest("table"),tb=t.tBodies[0],
      i=Array.prototype.indexOf.call(th.parentNode.children,th),
      dir=(t.getAttribute("data-dir")==="asc"&&t.getAttribute("data-col")==String(i))?"desc":"asc";
  var rows=Array.prototype.slice.call(tb.rows);
  rows.sort(function(a,b){
    var x=(a.cells[i]?a.cells[i].innerText:"").trim().toLowerCase(),
        y=(b.cells[i]?b.cells[i].innerText:"").trim().toLowerCase(),
        nx=parseFloat(x),ny=parseFloat(y);
    if(!isNaN(nx)&&!isNaN(ny)){return dir==="asc"?nx-ny:ny-nx;}
    return dir==="asc"?x.localeCompare(y):y.localeCompare(x);
  });
  rows.forEach(function(r){tb.appendChild(r);});
  t.setAttribute("data-dir",dir);t.setAttribute("data-col",String(i));
}
document.addEventListener("DOMContentLoaded",function(){
  var ths=document.querySelectorAll("table.sortable th");
  Array.prototype.forEach.call(ths,function(th){
    th.addEventListener("click",function(){sortTable(th);});
  });
});
'@
}

function Get-StatusClass {
    param([string]$Status, [string]$Basis = '')
    # A withheld or unmeasured number is not a finding, whatever status the
    # section builder attached to it.
    if ($Basis -eq 'withheld' -or $Basis -eq 'not measured') { return 'info' }
    switch ($Status) { 'ok' { 'ok' } 'warn' { 'warn' } 'fail' { 'bad' } default { 'info' } }
}
function Get-LevelClass {
    param([string]$Level)
    switch ($Level) { 'green' { 'ok' } 'amber' { 'warn' } 'red' { 'bad' } default { 'info' } }
}

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------
function ConvertTo-NsHtml {
    param($Doc, [string]$SourceLabel = '')
    $d = $Doc
    $sb = New-Object System.Text.StringBuilder
    $w  = { param([string]$s) [void]$sb.AppendLine($s) }

    $overall = 'notmeasured'
    if ($d.verdict -and $d.verdict.overall) { $overall = [string]$d.verdict.overall }
    $bannerClass = switch ($overall) { 'red' { 'b-red' } 'amber' { 'b-amber' } 'green' { 'b-green' } default { 'b-grey' } }

    & $w '<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">'
    & $w '<meta name="viewport" content="width=device-width,initial-scale=1">'
    & $w ('<title>NetSpeed report - {0}</title>' -f (HtmlEnc $d.host.computerName))
    & $w ('<style>{0}</style>' -f (Get-ReportCss))
    & $w ('<script>{0}</script>' -f (Get-SortScript))
    & $w '</head><body><div class="wrap">'

    & $w ('<div class="banner {0}">' -f $bannerClass)
    & $w ('<h1>{0} &mdash; {1}</h1>' -f (HtmlEnc $d.host.computerName), (HtmlEnc $overall.ToUpper()))
    if ($d.verdict -and $d.verdict.headline) { & $w ('<div class="lede">{0}</div>' -f (HtmlEnc $d.verdict.headline)) }
    & $w '</div>'
    foreach ($n in @($d.verdict.notes)) { if ($n) { & $w ('<div class="note">{0}</div>' -f (HtmlEnc $n)) } }

    if ($d.inline -and [int]$d.inline.applied -gt 0) {
        if ($d.inline.overflow) {
            $msg = 'This report <b>overflowed</b> the RMM capture budget, so only states, reasons and the verdict were kept inline.'
        } else {
            $msg = ('This report was rendered from the <b>inline (shortened) copy</b> - shed to stage {0} of {1} to fit the RMM console capture budget. Every row and the whole verdict are intact; raw sample arrays and per-item detail were dropped. Dropped: {2}.' -f `
                    (HtmlEnc $d.inline.applied), (HtmlEnc $d.inline.maxStage), (HtmlEnc ((@($d.inline.shed) -join ', '))))
        }
        if ($d.inline.fullReport) { $msg += (' The full report is at <code>{0}</code> on the machine.' -f (HtmlEnc $d.inline.fullReport)) }
        & $w ('<div class="note">{0}</div>' -f $msg)
    }

    # Route sanity, immediately under the verdict. If this report was taken over a
    # backup WAN then every number below describes THAT connection, and a reader
    # who misses that fact draws the wrong conclusion from an otherwise correct
    # report. Reconstructed from the path rows because those are never shed.
    $rsRows = @()
    if ($d.sections -and $d.sections.path -and $d.sections.path.rows) {
        $rsRows = @($d.sections.path.rows | Where-Object { $_.group -eq 'Route' -or $_.group -eq 'Route signal' })
    }
    $rsHead = @($rsRows | Where-Object { $_.group -eq 'Route' })
    if ($rsHead.Count -gt 0 -and $rsHead[0].result -ne 'normal') {
        $rsCls = 'note'
        if ($rsHead[0].result -eq 'suspect') { $rsCls = 'note note-bad' }
        $rsWhy = @($rsRows | Where-Object { $_.group -eq 'Route signal' -and $_.result -eq 'yes' } | ForEach-Object { $_.check })
        $rsMsg = ('<b>Check which internet connection this was measured over.</b> {0}' -f (HtmlEnc $rsHead[0].detail))
        if ($rsWhy.Count -gt 0) {
            $rsMsg += ('<br><br>What was observed: {0}. These are <b>inferences from the endpoint</b>, not a reading from the router - the firewall or router WAN status is the authority.' -f (HtmlEnc ($rsWhy -join '; ')))
        }
        & $w ('<div class="{0}">{1}</div>' -f $rsCls, $rsMsg)
    }

    $sysBadge = ''
    if ($d.host.isSystem) { $sysBadge = ' <span class="badge">SYSTEM</span>' }
    elseif ($d.host.elevated) { $sysBadge = ' <span class="badge">elevated</span>' }
    & $w '<div class="card"><header><h2>Context</h2></header><div class="body"><div class="grid">'
    $ad = $null
    if ($d.network) { $ad = $d.network.adapter }
    $kvs = @(
        @{ k = 'Collected';  v = (HtmlEnc $d.collectedUtc) },
        @{ k = 'Duration';   v = ('{0} s' -f (HtmlEnc $d.durationSec)) },
        @{ k = 'Ran as';     v = ((HtmlEnc $d.host.runAs) + $sysBadge) },
        @{ k = 'OS';         v = (HtmlEnc ('{0} (build {1})' -f $d.host.osCaption, $d.host.osBuild)) },
        @{ k = 'PowerShell'; v = (HtmlEnc $d.host.psVersion) },
        @{ k = 'Tool';       v = (HtmlEnc ('{0} v{1} ({2})' -f $d.tool.name, $d.tool.version, $d.tool.mode)) }
    )
    if ($ad) {
        $kvs += @{ k = 'Adapter';      v = (HtmlEnc ('{0} - {1} Mbps' -f $ad.name, $ad.linkSpeedMbps)) }
        $kvs += @{ k = 'IP / gateway'; v = (HtmlEnc ('{0} via {1}' -f $ad.ipv4, $ad.gateway)) }
    }
    if ($d.planMbps -and $d.planMbps.stated) {
        $kvs += @{ k = 'Stated plan'; v = (HtmlEnc ('{0} down / {1} up Mbps' -f $d.planMbps.down, $d.planMbps.up)) }
    }
    foreach ($kv in $kvs) { & $w ('<div class="kv"><div class="k">{0}</div><div class="v">{1}</div></div>' -f (HtmlEnc $kv.k), $kv.v) }
    & $w '</div></div></div>'

    & $w '<div class="card"><header><h2>Verdict by area</h2></header><div class="body">'
    & $w '<p class="meta">The overall result is the <b>worst measured</b> subscore, never an average, and there is deliberately no 0-100 score. Anything not measured is listed but never counts against the result - a healthy machine has to be distinguishable from an untested one.</p>'
    & $w '<table class="sortable"><thead><tr><th>Area</th><th>Level</th><th>Finding</th><th>What to do</th></tr></thead><tbody>'
    foreach ($s in @($d.verdict.subscores)) {
        $lc = Get-LevelClass -Level $s.level
        & $w ('<tr><td>{0}</td><td><span class="pill p-{1}">{2}</span></td><td>{3}</td><td class="det">{4}</td></tr>' -f `
            (HtmlEnc $s.name), $lc, (HtmlEnc $s.level), (HtmlEnc $s.summary), (HtmlEnc $s.remedy))
    }
    & $w '</tbody></table></div></div>'

    # Known limits go ABOVE the sections. The first entry is the most common
    # real cause of the ticket; burying it in a footer defeats publishing it.
    $limits = @($d.knownLimits)
    if ($limits.Count -gt 0) {
        & $w '<div class="card"><header><h2>What this report cannot tell you</h2></header><div class="body"><ol class="limits">'
        foreach ($l in $limits) { & $w ('<li>{0}</li>' -f (HtmlEnc $l)) }
        & $w '</ol></div></div>'
    }

    # `sections` is a pscustomobject of NINE NAMED sections, not an array, so it
    # is enumerated through PSObject.Properties. The same trap applies to any
    # target-keyed map inside `data` - .Keys returns nothing after a JSON round trip.
    $order = @('link','throughput','latency','hogs','path','wifi','etw','soak','ookla')
    $titles = @{
        link='Link and adapter'; throughput='Throughput'; latency='Latency under load'
        hogs='What is using the link'; path='Path, DNS and infrastructure'; wifi='Wireless'
        etw='Per-process bytes (ETW)'; soak='Soak / intermittent'; ookla='Ookla'
    }
    $present = @{}
    foreach ($p in $d.sections.PSObject.Properties) { $present[$p.Name] = $p.Value }
    $ordered = @()
    foreach ($k in $order) { if ($present.ContainsKey($k)) { $ordered += $k } }
    foreach ($k in @($present.Keys)) { if ($order -notcontains $k) { $ordered += $k } }

    foreach ($k in $ordered) {
        $sec = $present[$k]
        if (-not $sec) { continue }
        $title = $k
        if ($titles.ContainsKey($k)) { $title = $titles[$k] }
        $state = [string]$sec.state
        $sc = switch ($state) { 'measured' { 'ok' } 'failed' { 'bad' } default { 'info' } }

        & $w ('<div class="card" id="{0}"><header><h2>{1}</h2><span class="pill p-{2}">{3}</span>' -f (Slug $k), (HtmlEnc $title), $sc, (HtmlEnc $state))
        if ($sec.durationSec -gt 0) { & $w ('<span class="sub">{0} s</span>' -f (HtmlEnc $sec.durationSec)) }
        & $w '</header><div class="body">'

        if ($state -ne 'measured' -and $sec.reason) {
            if ($state -eq 'failed') {
                & $w ('<div class="callout c-bad"><b>This check could not run.</b> {0}</div>' -f (HtmlEnc $sec.reason))
            } else {
                & $w ('<div class="callout c-grey"><b>{0}.</b> {1}<br><span class="sub">This does not count against the result.</span></div>' -f `
                    (HtmlEnc $state.ToUpper()), (HtmlEnc $sec.reason))
            }
        }
        if ($sec.proxy)  { & $w ('<div class="callout c-proxy"><b>This is a proxy for something else:</b> {0}</div>' -f (HtmlEnc $sec.proxy)) }
        if ($sec.method) { & $w ('<p class="meta"><b>How:</b> {0}</p>' -f (HtmlEnc $sec.method)) }
        $cav = @($sec.caveats)
        if ($cav.Count -gt 0) {
            & $w '<ul class="cav">'
            foreach ($c in $cav) { & $w ('<li>{0}</li>' -f (HtmlEnc $c)) }
            & $w '</ul>'
        }

        $rows = @($sec.rows)
        if ($rows.Count -gt 0) {
            # The Basis column is the honesty stance made operable: sortable, so
            # a reader can separate measured from inferred from withheld in one
            # click. It is the one thing this renderer must never omit.
            & $w '<table class="sortable"><thead><tr><th>Group</th><th>Check</th><th>Result</th><th>Basis</th><th>Detail</th></tr></thead><tbody>'
            foreach ($r in $rows) {
                $cls = Get-StatusClass -Status $r.status -Basis $r.basis
                $bp = 'p-info'
                if ($r.basis -eq 'measured') { $bp = 'p-ok' }
                & $w ('<tr><td>{0}</td><td>{1}</td><td class="res t-{2}">{3}</td><td><span class="pill {4}">{5}</span></td><td class="det">{6}</td></tr>' -f `
                    (HtmlEnc $r.group), (HtmlEnc $r.check), $cls, (HtmlEnc $r.result), $bp, (HtmlEnc $r.basis), (HtmlEnc $r.detail))
            }
            & $w '</tbody></table>'
        } elseif ($state -eq 'measured') {
            & $w '<p class="meta">No rows were produced for this section.</p>'
        }
        & $w '</div></div>'
    }

    if ($d.collector -and $d.collector.budget) {
        $skipped = @($d.collector.budget.skipped)
        if ($skipped.Count -gt 0) {
            & $w ('<div class="note"><b>Skipped for time budget:</b> {0}. Re-run with a higher -TotalBudgetSec to include them. Nothing skipped counts against the result.</div>' -f (HtmlEnc ($skipped -join ', ')))
        }
    }

    $src = $SourceLabel
    if (-not $src) { $src = 'pasted text' }
    & $w ('<footer>{0} schema v{1} &middot; {2} v{3} ({4}) &middot; rendered by NetSpeed_HTML_Report v{5} &middot; source: {6}</footer>' -f `
        (HtmlEnc $d.schema), (HtmlEnc $d.schemaVersion), (HtmlEnc $d.tool.name), (HtmlEnc $d.tool.version), (HtmlEnc $d.tool.mode), $RendererVersion, (HtmlEnc $src))
    & $w '</div></body></html>'
    return $sb.ToString()
}

function Invoke-NsRender {
    # One code path for both the command line and the window.
    param([string]$PathArg, [string]$TextArg, [string]$OutFile, [string]$OutDir, [string]$SearchDir)
    $res = [pscustomobject]@{ Ok = $false; OutPath = ''; Message = ''; Source = ''; Count = 1 }

    $src = Resolve-NsReportText -PathArg $PathArg -TextArg $TextArg -SearchDir $SearchDir
    if (-not $src.Ok) { $res.Message = $src.Error; return $res }
    $res.Source = $src.Source

    $parsed = ConvertFrom-NsReportText -Raw $src.Text
    if (-not $parsed.Ok) { $res.Message = $parsed.Error; return $res }
    $res.Count = $parsed.Count

    $html = ConvertTo-NsHtml -Doc $parsed.Doc -SourceLabel $src.Source

    $target = $OutFile
    if (-not $target) {
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $name  = ('NetSpeed_{0}_{1}.html' -f $parsed.Doc.host.computerName, $stamp)
        $dir   = $OutDir
        if (-not $dir) { $dir = (Get-NsDefaultOutDir) }
        if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
        $target = Join-Path $dir $name
    }
    [System.IO.File]::WriteAllText($target, $html, (New-Object System.Text.UTF8Encoding($false)))
    $res.OutPath = $target
    $res.Ok = $true
    return $res
}

# ---------------------------------------------------------------------------
# The window
# ---------------------------------------------------------------------------
function Show-NsRenderGui {
    param([string]$DefaultOutDir, [string]$SearchDir)
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object System.Windows.Forms.Form
    $form.Text = ('NetSpeed HTML Report  v{0}' -f $RendererVersion)
    $form.Size = New-Object System.Drawing.Size(760, 560)
    $form.MinimumSize = New-Object System.Drawing.Size(640, 480)
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $form.AllowDrop = $true

    $mk = {
        param([string]$t, [int]$x, [int]$y, [bool]$bold = $false)
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $t; $l.AutoSize = $true
        $l.Location = New-Object System.Drawing.Point($x, $y)
        $style = [System.Drawing.FontStyle]::Regular
        if ($bold) { $style = [System.Drawing.FontStyle]::Bold }
        $l.Font = New-Object System.Drawing.Font('Segoe UI', 9, $style)
        $form.Controls.Add($l); return $l
    }

    [void](& $mk 'Report file' 12 14 $true)
    [void](& $mk 'Drop a .json or .txt anywhere on this window, or browse to it.' 92 14 $false)

    $txtFile = New-Object System.Windows.Forms.TextBox
    $txtFile.Location = New-Object System.Drawing.Point(12, 34)
    $txtFile.Size = New-Object System.Drawing.Size(620, 24)
    $txtFile.Anchor = 'Top,Left,Right'
    $form.Controls.Add($txtFile)

    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = 'Browse...'
    $btnBrowse.Location = New-Object System.Drawing.Point(640, 33)
    $btnBrowse.Size = New-Object System.Drawing.Size(90, 26)
    $btnBrowse.Anchor = 'Top,Right'
    $form.Controls.Add($btnBrowse)

    [void](& $mk 'or paste a whole RMM log / the JSON itself' 12 70 $true)
    $txtPaste = New-Object System.Windows.Forms.TextBox
    $txtPaste.Location = New-Object System.Drawing.Point(12, 90)
    $txtPaste.Size = New-Object System.Drawing.Size(718, 230)
    $txtPaste.Multiline = $true
    $txtPaste.ScrollBars = 'Both'
    $txtPaste.WordWrap = $false
    $txtPaste.Font = New-Object System.Drawing.Font('Consolas', 9)
    # TextBox.MaxLength defaults to 32,767 and is enforced on USER INPUT -
    # including a paste - while programmatic assignment passes straight through.
    # So a report pasted in here was being silently cut at 32 KB while the same
    # report loaded from a file worked perfectly, which is exactly how this
    # surfaced. 0 means "as much as memory allows".
    $txtPaste.MaxLength = 0
    $txtPaste.Anchor = 'Top,Bottom,Left,Right'
    $form.Controls.Add($txtPaste)

    [void](& $mk 'Save the report to' 12 332 $true)
    $txtOut = New-Object System.Windows.Forms.TextBox
    $txtOut.Location = New-Object System.Drawing.Point(12, 352)
    $txtOut.Size = New-Object System.Drawing.Size(620, 24)
    $txtOut.Text = $DefaultOutDir
    $txtOut.Anchor = 'Bottom,Left,Right'
    $form.Controls.Add($txtOut)

    $btnOut = New-Object System.Windows.Forms.Button
    $btnOut.Text = 'Change...'
    $btnOut.Location = New-Object System.Drawing.Point(640, 351)
    $btnOut.Size = New-Object System.Drawing.Size(90, 26)
    $btnOut.Anchor = 'Bottom,Right'
    $form.Controls.Add($btnOut)

    $chkOpen = New-Object System.Windows.Forms.CheckBox
    $chkOpen.Text = 'Open the report when it is ready'
    $chkOpen.Checked = $true
    $chkOpen.AutoSize = $true
    $chkOpen.Location = New-Object System.Drawing.Point(12, 388)
    $chkOpen.Anchor = 'Bottom,Left'
    $form.Controls.Add($chkOpen)

    $btnRender = New-Object System.Windows.Forms.Button
    $btnRender.Text = 'Render report'
    $btnRender.Location = New-Object System.Drawing.Point(560, 384)
    $btnRender.Size = New-Object System.Drawing.Size(170, 34)
    $btnRender.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $btnRender.Anchor = 'Bottom,Right'
    $form.Controls.Add($btnRender)
    $form.AcceptButton = $btnRender

    $lblStatus = New-Object System.Windows.Forms.TextBox
    $lblStatus.Location = New-Object System.Drawing.Point(12, 426)
    $lblStatus.Size = New-Object System.Drawing.Size(718, 84)
    $lblStatus.Multiline = $true
    $lblStatus.ReadOnly = $true
    $lblStatus.ScrollBars = 'Vertical'
    $lblStatus.BackColor = [System.Drawing.Color]::FromArgb(30,30,30)
    $lblStatus.ForeColor = [System.Drawing.Color]::Gainsboro
    $lblStatus.Font = New-Object System.Drawing.Font('Consolas', 9)
    $lblStatus.Anchor = 'Bottom,Left,Right'
    $form.Controls.Add($lblStatus)

    $log = {
        param([string]$m)
        $lblStatus.AppendText(('[{0}] {1}{2}' -f (Get-Date -Format 'HH:mm:ss'), $m, [Environment]::NewLine))
    }
    & $log 'Ready. Drop a report file here, browse to one, or paste an RMM log.'
    if ($SearchDir) { & $log ('Looking for reports in {0}' -f $SearchDir) }

    $btnBrowse.Add_Click({
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = 'NetSpeed reports (*.json;*.txt)|*.json;*.txt|All files (*.*)|*.*'
        $dlg.Title = 'Pick a NetSpeed report'
        if ($SearchDir -and (Test-Path -LiteralPath $SearchDir)) { $dlg.InitialDirectory = $SearchDir }
        if ($dlg.ShowDialog() -eq 'OK') { $txtFile.Text = $dlg.FileName }
    })

    $btnOut.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Where should the HTML report be saved?'
        if ($dlg.ShowDialog() -eq 'OK') { $txtOut.Text = $dlg.SelectedPath }
    })

    # Drag and drop anywhere on the window.
    $onDrop = {
        param($sender, $e)
        try {
            $files = @($e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop))
            if ($files.Count -gt 0) {
                $txtFile.Text = $files[0]
                & $log ('Dropped: {0}' -f $files[0])
            }
        } catch { }
    }
    $onDragEnter = {
        param($sender, $e)
        if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
            $e.Effect = [System.Windows.Forms.DragDropEffects]::Copy
        }
    }
    $form.Add_DragEnter($onDragEnter);   $form.Add_DragDrop($onDrop)
    $txtPaste.AllowDrop = $true
    $txtPaste.Add_DragEnter($onDragEnter); $txtPaste.Add_DragDrop($onDrop)

    $btnRender.Add_Click({
        $btnRender.Enabled = $false
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            $pathArg = $txtFile.Text.Trim().Trim('"')
            $textArg = $txtPaste.Text
            if (-not $pathArg -and -not $textArg.Trim()) {
                & $log 'Nothing to render yet - pick a file or paste a report.'
                return
            }
            # A path in the box wins; the paste box is the fallback.
            $r = Invoke-NsRender -PathArg $pathArg -TextArg $textArg -OutDir ($txtOut.Text.Trim()) -SearchDir $SearchDir
            if (-not $r.Ok) {
                & $log ('FAILED: ' + $r.Message)
                [void][System.Windows.Forms.MessageBox]::Show($r.Message, 'Could not render that', 'OK', 'Warning')
                return
            }
            if ($r.Count -gt 1) { & $log ('Found {0} reports in that text - rendered the LAST one.' -f $r.Count) }
            & $log ('Source : ' + $r.Source)
            & $log ('Written: ' + $r.OutPath)
            if ($chkOpen.Checked) {
                try { Start-Process $r.OutPath } catch { & $log 'Could not open it automatically - the path is above.' }
            }
        } catch {
            & $log ('ERROR: ' + $_.Exception.Message)
        } finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
            $btnRender.Enabled = $true
        }
    })

    [void]$form.ShowDialog()
}

# ---------------------------------------------------------------------------
# Go
# ---------------------------------------------------------------------------
$searchDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($searchDir)) { $searchDir = (Get-Location).Path }

$wantGui = $false
if ($Gui) { $wantGui = $true }
elseif (-not $NoGui -and -not $JsonPath -and -not $Json -and -not $OutPath) {
    # No input given and someone is sitting there: show the window rather than
    # guessing or printing usage at them.
    $wantGui = [Environment]::UserInteractive
}

if ($wantGui) {
    Show-NsRenderGui -DefaultOutDir $ReportPath -SearchDir $searchDir
    exit 0
}

$r = Invoke-NsRender -PathArg $JsonPath -TextArg $Json -OutFile $OutPath -OutDir $ReportPath -SearchDir $searchDir
if (-not $r.Ok) { Fail $r.Message }
if ($r.Count -gt 1) { Say ('Found {0} reports in that text - rendered the LAST one.' -f $r.Count) 'NOTE' }
Say ('Source: {0}' -f $r.Source)
Say ('Report written: {0}' -f $r.OutPath) 'OK'

# Never try to launch a browser from a Backstage or scheduled context.
if (-not $NoOpen -and [Environment]::UserInteractive) {
    try { Start-Process $r.OutPath } catch { Say 'Could not open it automatically - open the file above.' }
}
exit 0
