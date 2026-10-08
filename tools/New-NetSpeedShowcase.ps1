<#
=========================================================
Script Name: New-NetSpeedShowcase
Description: Renders showcase screenshots of the GUI on a FICTIONAL machine.

             Runs the real NetSpeed-Troubleshooter-Gui.ps1 - every renderer,
             section builder and verdict rule is the shipping code - with the
             few functions that read this machine swapped for seeded fakes
             (tools\showcase\Stubs.ps1) and a randomized "busy site" handed to
             it as raw stage results (tools\showcase\Inject.ps1). Nothing is
             measured and nothing touches the network.

             Privacy gate: before any PNG is kept, every string the window
             renders is checked against this machine's real host, user and
             domain names, every real IPv4/IPv6 address, gateway, DNS server
             and MAC, and a list of known client names. Any IPv4 that is not
             the fixture's own, documentation space, or one of the tool's
             fixed public probe targets also fails it. A failed gate keeps
             nothing.

             Dev tool only. Not part of the build, the stager or the tests.

Usage:       powershell -NoProfile -ExecutionPolicy Bypass -File tools\New-NetSpeedShowcase.ps1
             ... -Seed 77            a different fictional site
             ... -Capture Bitmap     DrawToBitmap instead of PrintWindow
             ... -DenyToken 'Acme'   also refuse any screen showing these names
Output:      screenshots\NetSpeed_showcase_<tab>.png (pixels only - no metadata
             chunks) and showcase.txt
=========================================================
#>
[CmdletBinding()]
param(
    [int]$Seed = 4127,
    [string]$OutDir = '',
    [ValidateSet('Window','Bitmap')] [string]$Capture = 'Window',
    [int]$Width = 1280,
    [int]$Height = 1040,
    # Extra names that must never appear - a client or site name, say.
    [string[]]$DenyToken = @(),
    [switch]$KeepWork
)
$ErrorActionPreference = 'Stop'
$proj = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $proj 'screenshots' }
$gui = Join-Path $proj 'NetSpeed-Troubleshooter-Gui.ps1'
$stubs = Join-Path $PSScriptRoot 'showcase\Stubs.ps1'
$inject = Join-Path $PSScriptRoot 'showcase\Inject.ps1'
foreach ($f in @($gui, $stubs, $inject)) { if (-not (Test-Path -LiteralPath $f)) { throw ('Missing {0}' -f $f) } }

$work = Join-Path $env:TEMP ('NetSpeedShowcase_' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $work

# ---- what must never appear: this machine's real identity ---------------------
$tokens = [Activator]::CreateInstance([System.Collections.Generic.List[string]])
foreach ($t in @($env:COMPUTERNAME, $env:USERNAME, $env:USERDOMAIN)) { if ($t) { $tokens.Add($t) } }
try {
    $cs = Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 15 -ErrorAction Stop
    if ($cs.Domain -and $cs.Domain -ne 'WORKGROUP') { $tokens.Add([string]$cs.Domain) }
    if ($cs.UserName) { $tokens.Add([string]$cs.UserName); $tokens.Add(([string]$cs.UserName -split '\\')[-1]) }
} catch { }
# Client, site and personal names that must never appear. Kept OUT of this
# script on purpose - a denylist of client names is itself something you would
# not want to publish - in a local file beside it, one name per line (# for a
# comment). See showcase\deny.local.example.txt.
$denyLocal = Join-Path $PSScriptRoot 'showcase\deny.local.txt'
if (Test-Path -LiteralPath $denyLocal) {
    foreach ($t in @(Get-Content -LiteralPath $denyLocal)) { $t = $t.Trim(); if ($t -and -not $t.StartsWith('#')) { $tokens.Add($t) } }
}
foreach ($t in @($DenyToken)) { if ($t) { $tokens.Add($t) } }
$public = @('1.1.1.1','1.0.0.1','8.8.8.8','8.8.4.4','9.9.9.9','127.0.0.1','0.0.0.0','::1','::')
$ips = [Activator]::CreateInstance([System.Collections.Generic.List[string]])
try { foreach ($a in @(Get-NetIPAddress -ErrorAction Stop)) { $ips.Add(([string]$a.IPAddress -split '%')[0]) } } catch { }
try { foreach ($r in @(Get-NetRoute -ErrorAction Stop | Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' -and $_.NextHop -ne '::' })) { $ips.Add([string]$r.NextHop) } } catch { }
try { foreach ($d in @(Get-DnsClientServerAddress -ErrorAction Stop)) { foreach ($s in @($d.ServerAddresses)) { $ips.Add([string]$s) } } } catch { }
$macs = @()
try { $macs = @(Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object { $_.MacAddress } | ForEach-Object { [string]$_.MacAddress }) } catch { }
[pscustomobject]@{
    tokens = @($tokens | Where-Object { $_ } | Select-Object -Unique)
    ips    = @($ips | Where-Object { $_ -and ($public -notcontains $_) } | Select-Object -Unique)
    macs   = @($macs | Select-Object -Unique)
} | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $work 'deny.json') -Encoding UTF8

# ---- patch a copy of the real GUI ---------------------------------------------
function Replace-Once([string]$Text, [string]$Find, [string]$With) {
    $n = ([regex]::Matches($Text, [regex]::Escape($Find))).Count
    if ($n -ne 1) { throw ('The GUI no longer matches this tool: anchor found {0} times, expected once: {1}' -f $n, $Find) }
    return $Text.Replace($Find, $With)
}
$q = { param($s) "'" + ($s -replace "'", "''") + "'" }
$src = Get-Content -LiteralPath $gui -Raw
$nl = "`n"
$src = Replace-Once $src "`$HelpersPath = Join-Path `$PSScriptRoot 'NetSpeed-Troubleshooter.Helpers.ps1'" `
    ('$HelpersPath = ' + (& $q (Join-Path $proj 'NetSpeed-Troubleshooter.Helpers.ps1')))
# The FIRST helpers dot-source is the top-level one; the worker and monitor
# scriptblocks carry their own copies, which are never run here.
$anchor = '$HelpersSource = Get-Content -LiteralPath $HelpersPath -Raw' + $nl + '. ([scriptblock]::Create($HelpersSource))'
$src = Replace-Once $src $anchor ($anchor + $nl +
    ('$script:ShowcaseSeed = {0}; $script:ShowcaseWork = {1}; $script:ShowcaseCapture = {2}; $script:ShowcaseWidth = {3}; $script:ShowcaseHeight = {4}' -f `
        $Seed, (& $q $work), (& $q $Capture), $Width, $Height) + $nl +
    ('. ' + (& $q $stubs)))
$src = Replace-Once $src '[void]$script:form.ShowDialog()' (('. ' + (& $q $inject)) + $nl + '[void]$script:form.ShowDialog()')
$patched = Join-Path $work 'Gui.showcase.ps1'
[System.IO.File]::WriteAllText($patched, $src, (New-Object System.Text.UTF8Encoding($true)))

# ---- run it -------------------------------------------------------------------
Write-Host ('Rendering the showcase (seed {0}) - the window appears for a few seconds...' -f $Seed)
$p = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File', $patched) -PassThru
$null = $p.Handle   # without it ExitCode reads $null - see Invoke-NsOoklaSpeedtest
if (-not $p.WaitForExit(180000)) { try { $p.Kill() } catch { }; throw 'The showcase window did not finish within 3 minutes.' }

$manPath = Join-Path $work 'manifest.json'
if (-not (Test-Path -LiteralPath $manPath)) { throw ('No manifest was written (GUI exit code {0}). Re-run with -KeepWork and look in {1}.' -f $p.ExitCode, $work) }
$man = Get-Content -LiteralPath $manPath -Raw | ConvertFrom-Json
$pngs = @(Get-ChildItem -LiteralPath $work -Filter 'NetSpeed_showcase_*.png' -File)

if (-not $man.ok) {
    foreach ($png in $pngs) { Remove-Item -LiteralPath $png.FullName -Force }
    if ($man.error) { Write-Host ('[FAIL] {0}' -f $man.error) -ForegroundColor Red }
    if ($man.scan) { foreach ($h in @($man.scan.hits)) { Write-Host ('[FAIL] privacy: {0}' -f $h) -ForegroundColor Red } }
    Write-Host '[FAIL] Nothing was kept.' -ForegroundColor Red
    if (-not $KeepWork) { Remove-Item -LiteralPath $work -Recurse -Force }
    exit 1
}

function Save-PngPixelsOnly {
    # GDI+ writes sRGB, gAMA and pHYs chunks. Harmless, but a screenshot meant
    # for publishing should carry pixels and nothing else, so every chunk that
    # is not IHDR/PLTE/tRNS/IDAT/IEND is dropped. Chunks are copied verbatim,
    # CRCs included, so the image data is untouched.
    param([string]$From, [string]$To)
    $b = [System.IO.File]::ReadAllBytes($From)
    $ms = New-Object System.IO.MemoryStream
    $ms.Write($b, 0, 8)
    $o = 8
    while ($o + 8 -le $b.Length) {
        $len = ([int]$b[$o] -shl 24) -bor ([int]$b[$o + 1] -shl 16) -bor ([int]$b[$o + 2] -shl 8) -bor [int]$b[$o + 3]
        $type = [System.Text.Encoding]::ASCII.GetString($b, $o + 4, 4)
        if (@('IHDR','PLTE','tRNS','IDAT','IEND') -contains $type) { $ms.Write($b, $o, 12 + $len) }
        $o += 12 + $len
    }
    [System.IO.File]::WriteAllBytes($To, $ms.ToArray())
}

if (-not (Test-Path -LiteralPath $OutDir)) { $null = New-Item -ItemType Directory -Path $OutDir }
foreach ($png in $pngs) { Save-PngPixelsOnly -From $png.FullName -To (Join-Path $OutDir $png.Name) }
$note = @(
    'NetSpeed Troubleshooter - showcase screenshots'
    ('Rendered {0} by tools\New-NetSpeedShowcase.ps1, seed {1}, capture {2}, {3}x{4}.' -f (Get-Date -Format 'yyyy-MM-dd HH:mm'), $Seed, $Capture, $Width, $Height)
    ''
    'FICTIONAL DATA. The GUI is the real one; its inputs are invented. Host, user, addresses and'
    'measurements are seeded fakes: RFC1918 for the LAN, RFC 5737 documentation ranges for anything'
    'public, RFC 5398 ASNs, RFC 7042 MACs. The only real public addresses are the tool''s fixed probe'
    'targets (1.1.1.1 and similar).'
    ''
    ('Privacy gate: PASSED - {0} rendered strings checked against this machine''s real names,' -f $man.scan.stringsScanned)
    ('addresses and MACs ({0} names, {1} addresses, {2} MACs) and an allowlist for every IPv4.' -f @((Get-Content -LiteralPath (Join-Path $work 'deny.json') -Raw | ConvertFrom-Json).tokens).Count, @((Get-Content -LiteralPath (Join-Path $work 'deny.json') -Raw | ConvertFrom-Json).ips).Count, $macs.Count)
    ''
    'Files:'
) + @($pngs | ForEach-Object { '  ' + $_.Name })
Set-Content -LiteralPath (Join-Path $OutDir 'showcase.txt') -Value $note -Encoding UTF8
if (-not $KeepWork) { Remove-Item -LiteralPath $work -Recurse -Force }
Write-Host ('[OK] Privacy gate passed ({0} strings). {1} screenshot(s) in {2}' -f $man.scan.stringsScanned, $pngs.Count, $OutDir) -ForegroundColor Green
