# NetSpeed Troubleshooter - technical notes

> This public release is drag-and-run: the GUI, its helpers, the launcher, the HTML report and the egress watch. The headless RMM collector, the build script and the test suite described below are not included.

A WinForms toolkit for Windows PowerShell 5.1, built to be launched inside a **ScreenConnect
Backstage** session when a client reports "the internet is slow".

`Quick Sweep` takes about a minute and answers most of those tickets on its own:

* **Is the physical link the cap?** A wired NIC negotiating 10 or 100 Mbps closes more of these
  tickets than everything else here combined. That line is coloured red in the title strip before
  anything is measured.
* **What does the link actually deliver**, up and down?
* **Does latency collapse under load?** This is what makes Teams stutter and pages hang while a
  speed test still reads fine.
* **Is something on this PC eating the link** — Windows Update, Office, OneDrive, a backup agent?

Then targeted deep dives behind that: real per-process bytes via ETW, a live traffic monitor,
Wi-Fi, path and DNS, and a soak mode for intermittent faults.

---

## Read this first: what this tool cannot see

**It sees THIS PC only.** A hog on another device on the LAN — the receptionist's Dropbox, a NAS
replicating, a TV streaming — is completely invisible to it. That is the single most common real
cause of "the internet is slow", and all three levels of hog detection inherit the limitation.

A clean report from this tool means *nothing on this machine is responsible*. It does not mean the
link is idle. The workaround is the **Live Monitor** tab plus a second machine: watch the adapter
totals while the user reproduces the fault, and if the link is busy while no local process is
moving anything, the traffic is coming from somewhere else on the network.

The remaining published limits are listed at the bottom, and they also ship inside every JSON
report under `knownLimits`.

---

## Files

| File | Role |
|---|---|
| `NetSpeed-Troubleshooter-Gui.ps1` | GUI: UI, background workers, rendering, export |
| `Get-NetSpeedDiagnostics.DEV.ps1` | **Headless collector** for Atera / any RMM. Dev form; dot-sources the helpers beside it. |
| `NetSpeed_HTML_Report.ps1` | **Render only.** Turns a report into a single self-contained HTML file. |
| `NetSpeed-Troubleshooter.Helpers.ps1` | **All** measurement logic. Function definitions only. |
| `Launch-NetSpeed-Troubleshooter.cmd` | Launcher; forces `-STA`, which WinForms requires |
| `Build-NetSpeedStager.ps1` | Generator — run on your workstation, not on a client |
| `build\Get-NetSpeedDiagnostics.Atera.ps1` | Generated, **self-contained** (~350 KB). Paste into Atera; needs nothing else on the machine. |
| `build\Atera_Deploy_NetSpeed.ps1` | Generated. Paste into Atera; stages the GUI and prints the Backstage command. |
| `build\Atera_Run_NetSpeed_Collector.ps1` | Generated, ~2 KB. Runs the collector that the deploy script staged. |
| `Watch-NsEgress.ps1` | **Egress watch.** Records the public address on a schedule to catch a WAN failover. |
| `tests\Run-Tests.ps1` | **The gate.** 271 checks. Run before shipping anything. |
| `tools\New-NetSpeedShowcase.ps1` | **Dev only.** Screenshots of the real GUI on a fictional machine, behind a privacy gate. Not built, staged or tested. |

The helpers file is loaded as **text** and rebuilt inside each background runspace, so one
definition serves the UI thread and every worker. The headless collector inlines that same file at
build time and the renderer reads the schema it produces, which is why none of the measurement
logic lives in any of the three front ends.

## Deploying

Run `Build-NetSpeedStager.ps1`, then paste `build\Atera_Deploy_NetSpeed.ps1` into Atera with
**Run As: System**. It finishes in seconds, stages to `C:\ProgramData\NetSpeedTroubleshooter`
with a per-file SHA256 check, locks that folder so only SYSTEM and Administrators can change it,
and prints the Backstage launch command. It refuses to run unelevated, and refuses an existing
folder that someone other than SYSTEM or Administrators owns (see the ProgramData fact below). It
does not launch anything itself — auto-starting a GUI from a SYSTEM context is both useless (no
desktop) and textbook loader behaviour.

```bash
powershell.exe -NoProfile -STA -File "C:\ProgramData\NetSpeedTroubleshooter\NetSpeed-Troubleshooter-Gui.ps1"
```

## The headless collector

For when nobody is sitting in front of the machine. Paste
`build\Get-NetSpeedDiagnostics.Atera.ps1` into a new Atera script, **Run As: System**, **Max Run
Time: 10 minutes**. It is self-contained — the helpers are inlined, so it needs nothing else on the
endpoint.

It prints a complete human-readable report (so the Atera result is useful on its own), writes a
`.txt` and a `.json` to `C:\ProgramData\NetSpeedTroubleshooter`, and ends with a fenced JSON
envelope that `NetSpeed_HTML_Report.ps1` renders directly.

Default sweep is about three minutes: link facts → what is already using the link → throughput and
bufferbloat → Wi-Fi → path/DNS/traceroute/MTU. ETW, Ookla and soak are opt-in.

```bash
powershell.exe -NoProfile -File ".\Get-NetSpeedDiagnostics.Atera.ps1" -PlanDown "100" -PlanUp "40"
```

Useful arguments (Atera passes everything as strings, and so does this script — see below):
`-PlanDown` / `-PlanUp` to grade against the customer's stated plan, `-TotalBudgetSec` to tighten
the wall-clock cap, `-DeepEtw "true"` for real per-process bytes, `-Quiet "true"` for JSON only,
`-FailOnRed "true"` if you want Atera to alert on a red verdict.

**Exit codes:** `0` normal, `1` a stage genuinely could not run (or `-FailOnRed` and a red verdict),
`2` you ran the development copy without the helpers beside it. A bad *finding* never sets a
non-zero exit — that is a network problem, not a script failure.

### Rendering a report

Run it with **no arguments** for a small window: drop a `.json` or `.txt` onto it, browse to one, or
paste a whole RMM log, then press Render.

```bash
powershell.exe -NoProfile -STA -File ".\NetSpeed_HTML_Report.ps1"
```

From the command line:

```bash
powershell.exe -NoProfile -File ".\NetSpeed_HTML_Report.ps1" -JsonPath ".\NetSpeed_PC01_20260807_101500.json" -NoGui
```

`-Json` is deliberately forgiving — it takes a **path**, raw JSON, *or* a whole pasted Atera log with
console noise around it. Someone typing `-Json test.json` means the file, not a JSON document that
happens to read "test.json". If the paste contains two runs it renders the later one and says so.
The renderer never collects anything and never loads the helpers.

### Catching a WAN failover

A single run cannot tell you which internet connection it measured. If a site has
a backup WAN, a failover changes the public address, the latency and the route all at once, and
every machine behind it goes slow together — which reads as "everything is broken" with no local
cause. `Watch-NsEgress.ps1` records the public address over time so the changeovers can be seen
after the fact:

```bash
powershell.exe -NoProfile -File "C:\ProgramData\NetSpeedTroubleshooter\Watch-NsEgress.ps1" -Install "true" -IntervalSec "300"
```

Install it from the **staged, locked copy**, as an administrator: `-Install` refuses to point a
SYSTEM task at a script in a folder a standard user can change. That creates a scheduled task
running as SYSTEM every five minutes. Each run appends one line and
exits in about two seconds — **one-shot by design**, so it survives reboots and needs nobody logged
on, which a long-running process does not. Leave it while the fault is happening, then:

```bash
powershell.exe -NoProfile -File ".\Watch-NsEgress.ps1" -Report "true"
```

```
  Egress history: 99 samples over 8.2 hours

    203.0.113.120                 405 min      84 samples   median 17.1 ms
    198.51.100.21                  65 min      15 samples   median 39.8 ms

  [WARN] 2026-08-22T22:00:00Z   203.0.113.120 -> 198.51.100.21   (held the previous one 235 min)
  ...
  [WARN] More than one address and more than one change: this site is FLAPPING between
         internet connections.
```

**The median latency per address is what separates a failover from a DHCP renumber** — two
addresses with very different latency are two different connections; two similar ones are the same
one renumbered. The report ends with the usual fenced JSON envelope, so
`NetSpeed_HTML_Report.ps1` renders it like any other. Remove the task with `-Uninstall "true"`.

### Is this even the right connection? — the route indicator

A failover log tells you when a link went *down*. It does not tell you that half a site's traffic
is going out a 4G bearer while both WAN links sit healthy and nothing ever fails over. That case
produces a ticket that reads "the internet is randomly slow", correlates with nothing, and survives
every test you run — because the tests keep landing on whichever link answered that minute.

The endpoint cannot see the firewall's WAN interfaces, so it cannot *know*. What it can do is
notice the fingerprints a backup path leaves, and say which ones it found. `Get-NsPathSanity`
scores four:

| Signal | Weight | Why it indicates a backup path |
|---|---|---|
| Public address differs from the historical majority | 3 | The site is out over a connection it does not normally use. Needs `Watch-NsEgress.ps1` history. |
| Path MTU below 1500, or unmeasurable because large packets vanish | 2 | A direct Ethernet path is 1500. Less means a tunnel, PPPoE, or a mobile bearer. A blackhole means transfers stall outright rather than merely running slow. |
| Three or more consecutive hops that answer nothing | 2 | Fixed carriers answer TTL expiry; mobile packet cores usually do not. A silent block mid-trace points at a mobile bearer. |
| Server-reported minimum round trip above 40 ms | 1 | Mobile bearers add 20–40 ms before anything else does. |

Three points or more is `suspect`, one or two is `watch`, and **no evidence yields `unknown`, never
a clean bill of health**. It appears in all three surfaces:

* **GUI** — a third banner line at the top, red on `suspect`, so a technician cannot read the
  numbers without seeing what they describe.
* **Collector** — a `[WARN]` block printed immediately *before* the verdict, because it changes what
  the verdict means.
* **HTML report** — a tinted callout under the verdict banner, plus the individual signals as rows.

Every row is `basis: inference`, never `measured`, and there is a test asserting the summary never
names a carrier or bearer technology. **"Two of the four indicators are true, and here they are" is
actionable. "You are on 4G" would be a guess wearing a fact's clothes.**

The signals live in `rows[]` and not in `data`, deliberately: the collector's shedding ladder
reaches into `section.data.Trace` and `.Qos` *by name*, so wrapping `data` in another object
silently stops it shedding. Rows are never shed, which is where an inference belongs anyway.

#### Proving it, rather than inferring it

Install `Watch-NsEgress.ps1` on **two machines at the same site** and compare. If they present
**different public addresses at the same timestamps**, the site is using both WANs concurrently —
load balancing or a policy route — because no failover can put two machines on two links at once.
If both show the same address and it changes together, it really is failover. That single
comparison separates the two explanations, and neither a dead-gateway-detection log nor any number
of speed tests can do it.

#### Which box does traffic actually leave through?

The public address tells you *which service* you came out of. It does not tell you *which piece of
equipment* sent you there — and on a site with two routers that is the question you actually need
answered, because it names the box whose config you have to go and look at.

The first few TTLs answer it in about a second. `Get-NsEgressPath` walks up to five hops and reads
the shape of the path:

```
  Default gateway                  10.20.30.254    <- what this machine is pointed at
  Device traffic leaves through    192.168.0.1     <- the box that faces the internet
  First hop on the internet        198.51.100.8
  Carrier-grade NAT in the path    yes
```

The **egress device** is the last privately-addressed hop before the internet. When it differs from
the default gateway, traffic is being handed on to another router, and *that* is the box deciding
which service the machine uses. Two machines at one site with different values here are not being
routed by the same equipment, whatever the firewall config says — which is a fact no amount of
reading firewall rules will give you.

It beats the public address on three counts: it names physical equipment rather than a service, it
still works when a public-IP lookup is filtered or the machine is offline, and it distinguishes two
routers that happen to NAT to the same address. Both are reported; neither replaces the other.

**Carrier-grade NAT** (`100.64.0.0/10`) is called out separately and scored, because
`Test-NsPrivateAddress` deliberately folds it in with RFC1918 — correct for deciding what counts as
internet bandwidth, wrong for this, where a carrier NAT hop is one of the clearest indications you
are on a mobile bearer rather than a business fixed service.

`Watch-NsEgress.ps1` records the egress device alongside the public address, so its history shows
equipment changes as well as address changes. **Logs written before that column existed keep their
own layout** — appending a wider row to a narrower header silently misaligns every field after it,
so the writer checks the existing header and matches it.

#### What kind of box is it?

Having named the egress device, the obvious next question is what it *is*. `Get-NsDeviceIdentity`
asks, of **one address** — a gateway this machine already sends every packet to — and never of a
range. A subnet sweep from an RMM agent is a different activity with a different risk profile.

| Source | Works across a route? | Notes |
|---|---|---|
| **TLS certificate subject** | Yes | The best identifier for an appliance. Self-signed by definition, and vendors put their own name and model in it. |
| Web interface `<title>` | Yes | Frequently names the product outright. |
| HTTP auth realm / `Server:` header | Yes | Weaker, but free once the socket is open. |
| **MAC address → vendor** | **No** | ARP only holds L2 neighbours. |
| Reverse DNS | Yes | Usually blank on consumer equipment. |

**The MAC is the one that surprises people.** The neighbour cache only contains hosts in your own
broadcast domain, so your *default gateway* has a readable MAC and anything *beyond* it does not,
however reachable it is over IP. That is a property of ARP, not a failure, so the report says so
explicitly rather than leaving the field blank — and it is exactly why the certificate is the
primary identifier here.

Every identification is `basis: inference` and **always names where it came from**: "read from its
TLS certificate", "read from its web interface title". A guess whose source is not stated is
indistinguishable from an invention.

**OUI lookups are an embedded table, not an API call.** `api.macvendors.com` is the obvious source
and the wrong one: this runs on sites whose internet is the thing under test, it is rate limited,
and an identification that needs working internet cannot help you when broken internet is the
complaint. A few dozen prefixes cover the routers, firewalls and modems an MSP actually meets, and
anything unknown says so.

Two bounded-call notes, both learned the hard way and both re-applied here: the port probes fire
**all at once and wait once** (sequentially, six ports against a silently-dropping device costs the
timeout six times), and `EndConnect` is called only on a *completed* operation. `GetHostEntry` has
no timeout parameter and a reverse lookup for a private address with no PTR waits out the resolver,
so it runs async against an 800 ms bound and is abandoned rather than waited on. Together these took
a real gateway from 9.8 s to 2.2 s.

In the collector this runs **only when the path stage got its full budget** — a squeezed run needs
the DNS comparison far more than it needs a device name.

### Where output goes

Both the collector and the renderer write to **the folder the script is running from** — that is
where whoever ran it will look. `C:\ProgramData\NetSpeedTroubleshooter` is only a fallback, for the
two cases where the script's own folder is the wrong answer: an RMM working directory under
`Windows\Temp` that gets cleaned up after the run, and a read-only location. The collector's inline
JSON is emitted either way, and `-NoFiles` turns file output off entirely.

### Three stages, one set of tests

The GUI, the collector and the renderer all work from the same
`NetSpeed-Troubleshooter.Helpers.ps1` and emit the same schema. The build enforces that: gate 11
extracts the helper block back out of the generated collector and fails if it is not byte-identical
to the source, so "there is exactly one copy of the measurement logic" is a checked fact rather
than a claim.

---

## Facts this toolkit is built around

Each of these was measured on a real machine during development, and each one contradicts an
approach that looks perfectly reasonable.

**`ServicePointManager.DefaultConnectionLimit` is 2.** A "6-stream" test silently runs two streams
and under-reports every fast link. Worse, `DefaultConnectionLimit` only affects `ServicePoint`
objects created *after* it is set, so it is also raised per request. The single most likely way for
a tool like this to be quietly wrong. There is a verification procedure for it below.

**Timing the whole request understates the link by ~41%.** Measured against Cloudflare: 1.441 s
full, 0.590 s to first byte, 0.851 s of body. Throughput is timed on body transfer only.

**Write-completion is not send-completion.** `GetRequestStream().Write()` returned in 0.569 s while
the response took 1.007 s. Upload is timed request-start to response-received, which includes one
round trip and is therefore pessimistic on high-latency links — the report says so on the row.

**`speed.cloudflare.com/meta` returns 403** to a plain `HttpWebRequest`. Most reference
implementations use it. The edge, client IP and ASN come from the `__down` response headers
instead, which cost nothing. (They arrive as bare `asn` / `city` / `country`, not the
`cf-meta-*` names the endpoint advertises.)

**A wall-clock timing of a polled probe measures the tool, not the network.** Probes are harvested
by polling, so fire-to-harvest includes the loop's own delay — and the loop is busiest exactly when
latency-under-load is being measured, so it inflates the number it is measuring. Caught by
comparing against a synchronous ping: wall-clock read 30 ms where the true RTT was 1 ms, which
traceroute independently confirmed as 1.8 ms. ICMP now uses the stack's `RoundtripTime`. The HTTP
probe cannot, so it publishes its own noise floor and is marked `withheld` when the reading sits
within 3× of it.

**A read chunk larger than one window inflates that window above line rate.** With a 256 KB chunk
on a real 10 Mbps link, p90 read 11.0 Mbps and max 13.4 Mbps — both physically impossible, because
one 256 KB read is 1.7 s of traffic landing in a 100 ms bucket. The chunk is sized so roughly eight
fit in a window, and re-sized from observed throughput once warm-up ends.

**`Win32_PerfRawData_Tcpip_NetworkInterface` costs 5040 ms.** Unusable. `Get-NetAdapterStatistics`
is 53 ms warm and `Get-NetTCPConnection` is 252 ms warm — the latter far too heavy for a 1 Hz
monitor, so it runs every third second. `NetworkInterface.GetIPv4Statistics()` on a cached object
is **0 ms**, which is what makes the live monitor possible at all.

**The byte counter wraps.** `BytesReceived` read 4,083,882,019 on the development machine — just
under 2³². Without wrap correction the next sample reads negative. There is a unit test for it.

**"The active adapter" is not "the first Up adapter".** The development machine has seven adapters
and *two* default routes. Windows chooses by route metric plus interface metric, so both are
summed rather than sorting on route metric alone.

**`Win32_PnPSignedDriver` takes 10-30 seconds.** The network class registry key is instant and
carries the same driver date and version plus `PnPCapabilities`. Enumerate it with
`-ErrorAction SilentlyContinue`: a non-elevated session cannot open the `Properties` subkey, and
`Stop` makes that one unreadable child abort the whole enumeration.

**Never `Test-NetConnection`.** Measured at ~500× the cost of a raw `TcpClient` in
an earlier tool, and it reports `PingSucceeded=False` on paths where the port is open.

**Atera's output capture budget is 45,000 characters, and it is the budget for the WHOLE capture.**
A full report compresses to ~40 KB on its own, and the collector prints another 18 KB of console —
so the inline JSON is shed in stages against `45000 − consoleChars − 512`. Reusing
a fixed `45000` constant from an earlier tool would ship a collector that is over budget on every
successful run. Measured on this machine: 43,191 total, console 17,979, JSON 25,174 at shed stage 3.

**Atera passes an empty string for any argument the technician left blank.** An empty string bound
to `[int]` or `[switch]` throws at *parameter binding* — before line 1 of the script runs — so the
technician sees a binding error instead of a report. Every collector parameter is `[string]` and is
coerced in the body.

**`Resolve-DnsName` has no `-Timeout`.** `-QuickTimeout` only drops 11 s to 7 s, so six lookups
against a resolver that never answers cost over a minute — measured at **66.7 s per resolver**, and
138.6 s for the whole path stage. A bounded raw UDP/53 probe now gates each server first, which
took that to 3.9 s. That probe also produces a better finding than the stall did: on this network,
ICMP to 1.1.1.1 succeeded in 18 ms and the default resolver answered in 0.5 s while a *direct* query
to 1.1.1.1:53 got nothing at all — the network intercepts port 53.

**A filtering DNS server does not refuse a blocked name, it answers `0.0.0.0`.** Which surfaces as
an opaque connect error that says nothing about the cause. Observed here: AdGuard DNS returning
`0.0.0.0` for `cloudflare.com` while every other name resolved normally. Without
`Get-NsNameResolutionDiagnosis` that reads as "the internet is broken" and sends a technician to the
ISP over what is really a DNS policy.

**A drain that calls `EndGetResponse` on an INCOMPLETE request blocks until that request's own
timeout.** Same for `.Result` on an incomplete ping task. The latency probes fire every 200 ms, so
on a link where they stop returning they accumulate without bound and the tidy-up then waits out
one timeout after another. Measured on a live Server 2012 R2 site: a 25-second stage took **4 min
31 s**, and each successive run was slower than the last. Two fixes, and **neither is version
specific** - this bit PowerShell 5.1 just as hard on any slow link:

* the drain now **abandons** anything still outstanding (`Abort()` / `SendAsyncCancel()`) instead of
  waiting on it, and
* no more than **four probes per target** may be in flight at once. A skipped probe is not counted
  as sent or lost, because it was never fired and folding it into the loss figure would be
  inventing packet loss.

Verified against an unroutable target: outstanding probes stay at 7 instead of ~60, and the drain
returns in 1.2 s instead of minutes. On a healthy link nothing changes - a 5-second idle phase
still yields 24 samples per target with zero skips.

**An unthemed server SKU renders a `DataGridView` unreadable.** Without the Desktop Experience
feature there are no visual styles, so cells that inherit their colours from the theme come out
white-on-white until you select a row. Every colour is now set explicitly, and
`EnableHeadersVisualStyles = $false` is required for the headers specifically - they ignore
`ColumnHeadersDefaultCellStyle` while it is true. On a normally themed client these are the values
it was already using.

**Server 2012 R2 ships PowerShell 4.0, and `[Type]::new()` is 5.0+.** The whole toolkit died there
with *"does not contain a method named 'new'"* — an error naming neither the version nor the
construct — and the adapter list came up empty for the same reason, because `Get-NsCandidateAdapters`
opens with one. Every constructor is `New-Object` or `[Activator]::CreateInstance` now, and a build
gate rejects `::new(` in code.

**...but `New-Object` returns a generic `List` wrapped in a PSObject, and `@($wrappedList)` throws
"Argument types do not match" on 5.1.** So the obvious fix for the 4.0 problem silently breaks every
array conversion in the toolkit — which is exactly what happened, and what the test suite caught.
Measured, same type either way:

| Construction | `@($list)` | `.ToArray()` |
|---|---|---|
| `New-Object 'System.Collections.Generic.List[object]'` | **throws** | ok |
| `[System.Collections.Generic.List[object]]::new()` | ok | ok, but PS 5.0+ only |
| `[Activator]::CreateInstance([System.Collections.Generic.List[object]])` | ok | ok |

`[Activator]::CreateInstance` returns it unwrapped and works on every version, so that is what the
toolkit uses and what the build gate enforces. The same landmine shows up elsewhere as
"`@($genericList).Count` throws on 5.1".

**On a `Regex` INSTANCE, `.Matches(input, x)` takes a START INDEX, not options.** Passing
`[RegexOptions]::Singleline` there silently becomes "start at character 16" and throws
`ArgumentOutOfRange` on any input shorter than that — which is how `-Json test.json` first failed,
with an error mentioning neither regexes nor the real problem. Put `(?s)` in the pattern instead.

**`Start-Process -NoNewWindow -PassThru` returns a process whose `ExitCode` reads `$null`.** With
`-NoNewWindow` or any redirection, Windows PowerShell creates the process itself and hands back a
`Process` from `GetProcessById`, which owns no handle; once it exits, the exit code cannot be read.
`$null -ne 0` is true, so **every successful Ookla run was reported as failed** - with the whole
result JSON pasted into the failure reason - and no test noticed, because the only Ookla test
covered the not-authorised path. Opening the handle while the process is alive (`$null =
$proc.Handle`) fixes it. Measured on 5.1.26100: null without the line, `0` with it. Any other
`Start-Process -NoNewWindow` that reads `ExitCode` has the same bug.

**`C:\ProgramData\<anything>` is writable by every standard user.** ProgramData carries
`BUILTIN\Users:(CI)(WD,AD,WEA,WA)`, and subfolders inherit it, so any user can create files and
folders in `C:\ProgramData\NetSpeedTroubleshooter`. The Ookla CLI used to live there: a user could
pre-create `ookla\speedtest.exe`, drop a DLL beside it or make `ookla` a junction, and the next
technician pressing the Ookla button under SYSTEM in Backstage would run it as SYSTEM. And a user
who creates `C:\ProgramData\NetSpeedTroubleshooter` *before* the first deploy **owns** it, so they
can rewrite the very scripts a technician then runs from it as SYSTEM. Since v1.1.0, everything that
runs, writes or deletes with SYSTEM rights is either private to the account or locked:

* The Ookla CLI and the ETW trace (`.etl`, written and then deleted, elevated) live in
  `%LOCALAPPDATA%` - the systemprofile under SYSTEM - never ProgramData.
* The **deploy stager** refuses to run unless elevated, refuses an install folder that is a junction
  or is owned by anyone but SYSTEM or Administrators, and after staging **locks** the folder: SYSTEM
  and Administrators full control, Users read and execute, nothing inherited. It reports, but does
  not delete, executables in the folder that the toolkit does not ship.
* The **RMM runner** refuses (exit 2) to run a collector from a folder a standard user can change.
* `Watch-NsEgress.ps1 -Install` refuses to register its SYSTEM task for a script in a user-writable
  folder - install it from the staged, locked copy.
* The launcher and the scheduled task call `powershell.exe` by **full path**: `cmd.exe` searches
  the current folder before `PATH`.

`Test-NsAdminOnlyWritable` is the shared check: the owner must be SYSTEM, Administrators or
TrustedInstaller, and no other principal may hold a write, delete, permissions or ownership right.
An existing install folder that fails it (one created by hand, or by v1.0.0) has to be deleted by an
administrator and deployed again.

**PowerShell resolves aliases BEFORE functions, and `h` is `Get-History`.** A `function H` is
therefore never called; every call instead binds its argument to `Get-History -Id` and dies with
"Cannot convert value ... to type System.Int64", which mentions nothing relevant. `r` is
`Invoke-History` and has the same problem. Do not use single-letter function names. `$Args` is the
same trap in variable form — naming a parameter `$Args` shadows the automatic variable and the
binding silently breaks.

---

## Honesty over overclaiming

Every figure says how it was obtained, and the tool would rather withhold a number than
publish one it cannot stand behind. Concretely:

**Every row states its basis.** `measured`, `inference`, `DO counter`, `BITS counter`,
`ETW bytes`, `server-reported`, `vendor tool`, `not measured`, or `withheld` — sortable, so a
technician can see at a glance which numbers are real.

**"Not measured" is not one thing.** Five states, and only two can move a verdict:

| State | Meaning | Effect on the verdict |
|---|---|---|
| `measured` | Numbers we stand behind | normal |
| `failed` | We tried and it errored | red **only** where the failure *is* the fault |
| `skipped` | Not requested | **never** drags down |
| `unsupported` | The machine cannot do it | **never** drags down |
| `refused` | We ran it and **withheld the number** | **never** drags down |

An untested machine must never read as a broken one.

**Numbers below the instrument's resolution are withheld, not published.** Fewer than 20
measurement windows and the percentile is withheld — but the *sustained* rate is kept, because it
is total bytes over total time and never divides by a window. That distinction matters: on a
saturated uplink each socket write blocks, windows stretch, and refusing outright would make the
tool silent on exactly the links it exists to diagnose.

**Bufferbloat is graded on the INCREASE, never the absolute.** A 250 ms satellite link that gains
5 ms is not bufferbloated; a 12 ms fibre link that gains 600 ms is catastrophic. Grading absolutes
inverts both calls. Scale cited as DSLReports'.

**The gateway probe is disqualified when it cannot answer the question.** The whole
gateway-versus-internet comparison assumes a ping to the gateway is dominated by the local hop.
On the development machine the gateway answered in 29.7 ms while 1.1.1.1 answered in 29.5 ms — the
router deprioritises ICMP to itself, so the figure carried no local information at all. Read
naively that says "the queue is local", the exact opposite of the truth. So the probe is
disqualified when its idle latency is too high to be a LAN hop, and the tool reports
`queue-present-location-unknown` rather than guessing.

**Inference can never convict.** A process holding eight sockets is a suspect. Only a real byte
counter — Delivery Optimization, BITS, or the ETW capture — can make the contention subscore red.

**Delivery Optimization's counters are cumulative.** 26 jobs and 540 MB "from HTTP" against an
actual current rate of 48 kbps. In-progress jobs are counted separately from history, and the only
figure presented as "now" is the current downlink rate.

**The tool's own traffic is labelled, not hidden.** Running a speed test while the Live Monitor is
open is the intended workflow. A banner says the figures include the tool's own streams, its PID
row is greyed and excluded from the verdict, and the adapter total is **not** "corrected" — we
cannot subtract our own bytes accurately, so the component is stated rather than a difference
invented.

**No 0-100 score, and no averaging.** The overall result is the worst *measured* subscore.
Aggregating one real measurement, two inferences and a threshold comparison into "73" would be
false precision, and an excellent throughput figure must not be allowed to average away a link
negotiated at 10 Mbps.

**Throughput is not graded without a stated plan.** Leave the plan boxes at 0 and that subscore
reads `unsupported`. The tool will not invent an expectation to grade against.

**Safety limits live in code, not the UI.** 2 GB down / 1 GB up per run, 16 streams, 30 s per
direction, a 20 s cooldown, and automatic cellular detection dropping to a 3 s / 2-stream / 50 MB
profile. None of it is reachable from the interface, because the person who most needs the guard
rail is the one least likely to tick a box asking for it.

---

## Design decisions worth not undoing

**One thread, N `HttpWebRequest`s via `BeginGetResponse`, round-robin chunked reads.** Three
alternatives were tried and each is silently broken on 5.1:

* *Nested runspace pool* — every child reparses the 209 KB helpers file, burning 1.5-4 s of startup
  inside a 10 s measurement. Kept as the documented escape hatch if the single thread ever caps out.
* *`[AsyncCallback]{...}` scriptblock delegates* — PowerShell invokes them on a threadpool thread
  with **no runspace attached**. Fails intermittently with "There is no Runspace available".
* *`WebClient` + `Register-ObjectEvent`* — engine events only drain when the pipeline is idle.
  Inside a busy worker they never fire, and the test reports zero with no error.

And one landmine: the worker runspace is STA, and **`WaitHandle.WaitAll` throws
`NotSupportedException` on an STA thread.**

**One `Ping` object per probe.** A single instance cannot have two async sends in flight — the
second throws `InvalidOperationException`.

**`logman … -ets`, not `netsh trace`.** `netsh trace` owns **one global session per machine**. If an
EDR agent, a Microsoft support script, `pktmon`, or a half-finished earlier run holds it, our start
fails — and far worse, our stop would tear down someone else's capture. `logman -ets` creates a
privately named session that cannot collide. `netsh` is kept only as a fallback and refuses to run
if a session is already in progress.

**One `Windows.Forms.Timer` for both the worker and the monitor.** Two timers means two teardown
paths and a second place to leak a runspace.

**The console is hidden in-process, not via `-WindowStyle Hidden`** — that switch hides the form
too. Hiding a *spawned* process's window is the loader pattern EDR products flag, which is why
nothing here launches a hidden child. Hiding one's **own** console in-process is a different
behaviour, used in production by other WinForms admin tools without complaint. If your EDR ever
flags it, the mitigation is to default `-NoHideConsole` on.

**The Ookla button modernises the existing `.bat`**, and every change is also a security
improvement: a TLS download instead of `curl.exe --insecure` (which disabled certificate
validation on a binary download); `Expand-Archive` instead of fetching `unzip.exe` from a
third-party site over plain HTTP; and `--accept-gdpr` as well as `--accept-license`, because in
EU/UK the CLI otherwise waits forever behind a hidden console. Since v1.1.0 also:

* **The CLI lives in the running account's own profile** (`%LOCALAPPDATA%\NetSpeedTroubleshooter\ookla`
  - the systemprofile under SYSTEM), never in `ProgramData`. See the facts below for why.
* **Both the zip and `speedtest.exe` are pinned by SHA256**, and the exe is re-checked before
  *every* run. `speedtest.exe` is not Authenticode-signed, so the pin is the only integrity check
  there is. A mismatch is deleted and re-fetched when a download is allowed, and refused otherwise.
* **The download can be stopped and has a real deadline.** `Invoke-WebRequest -TimeoutSec` only
  bounds the response headers; a trickling body ran past it with Stop doing nothing. One budget
  (`-TimeoutSec`) now covers download and test together, so the collector's stage budget holds.
* **The result is on screen**: Ookla rows (Result URL included) on the Throughput tab and a
  cross-check line on the Overview that never counts toward the verdict.

**Nothing on the UI thread touches the network.** `Build-Report` used to walk the first TTLs and
probe the gateway's ports, HTTP and TLS on *every* refresh - and a transfer test triggers a refresh
every 500 ms. Measured on a 61-second Quick Sweep: the window was frozen for 36 s in total, the worst
single stall was 6.8 s, and the gateway was probed over and over in the middle of the bufferbloat
measurement. The worker now measures the egress path and gateway identity once, in the path stage;
the same sweep blocks the UI for 0.6 s with a worst tick of 99 ms, and startup went from 2.4 s to
16 ms. A refresh also happens only when a result object actually changed.

**A render aimed at a grid that does not exist fails silently**, because `Render-Section` returns
on a `$null` grid. That is how the ETW capture - the only real per-process byte measurement here -
never reached any grid until v1.1.0: it rendered into `$script:gridEtw`, which was never created.
ETW now renders on the Bandwidth Hogs tab, above the inference rows, and a test asserts that every
grid `Refresh-AllTabs` renders into exists.

---

## Verifying a change

**Run the tests first.** 271 checks covering the statistics, the address filter, the
verdict rules, the section envelope, the safety caps, degradation paths, the Ookla exit-code,
pinning and parsing paths (through the real `Start-Process`, with a stand-in CLI), the GUI's
UI-thread and teardown rules, the JSON envelope, PowerShell 4.0 compatibility, and the built
collector and renderer end to end:

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "tests\Run-Tests.ps1"
```

**Static** — the builder enforces all of this and fails rather than shipping:

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Build-NetSpeedStager.ps1"
```

Both files parse; every top-level statement in the helpers is a function definition; no PS7-only
syntax and no `Test-NetConnection` (checked against the **token stream**, so the header comment
that names those constructs while forbidding them does not trip it); sources are plain ASCII; the
generated stager itself parses and contains no dynamic evaluation.

**The concurrency proof — the single most important test.** With a 6-stream run in flight, from a
second console:

```bash
powershell -NoProfile -Command "Get-NetTCPConnection -RemotePort 443 -State Established | Where-Object OwningProcess -eq <gui pid> | Measure-Object"
```

Must show 6, not 2. Per-stream byte counts should also come out roughly equal — four zeros against
two large numbers is the signature of a silent two-stream cap.

**Counter wrap:** `Measure-CounterDelta -Previous 4294967000 -Current 500` must return 796.

**No network:** disable the adapter and run Quick Sweep. Every section must return
`failed`/`unsupported` with a populated reason, no unhandled exception, and no empty grid without
an explanatory row.

**ETW:** run non-elevated first — the button must be disabled with a visible reason and the section
must read `unsupported`, never red. Then elevated. Afterwards confirm `logman query -ets` shows no
`NetSpeedKernelNet` and the `.etl` is gone. A leaked ETW session survives process exit and keeps
writing to disk; it is stopped in a `finally` **and** on form close.

**JSON:** the envelope must round-trip through `ConvertFrom-Json`, every section must have a
non-null `state`, every non-`measured` section a non-null `reason`, and nothing may serialise as
`"System.Object[]"` — `ConvertTo-Json` defaults to `-Depth 2` and silently truncates deeper objects
into that string.

**UI responsiveness:** a scratch harness that wraps the timer's Tick handler with a stopwatch is
how the 36 s freeze above was found and how the fix was proven - worst tick 6,792 ms before,
99 ms after, on the same sweep. Re-measure the same way after touching anything the tick calls.

### Showcase screenshots

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "tools\New-NetSpeedShowcase.ps1"
```

Renders every main tab of the **real** GUI on a fictional, seeded "busy site" into `screenshots\`.
Only the inputs are invented - `tools\showcase\Stubs.ps1` replaces the handful of functions that read
this machine, and `tools\showcase\Inject.ps1` hands the GUI raw stage results - so every row, colour
and verdict is drawn by the shipping code. Addresses are RFC1918 and RFC 5737 documentation ranges,
ASNs RFC 5398, MACs RFC 7042. Nothing is measured and nothing touches the network.

**Privacy gate:** before any PNG is kept, every string the window renders is checked against this
machine's real host, user and domain names, every real address, gateway, DNS server and MAC, and any
client or site names you list in `tools\showcase\deny.local.txt` (keep that file private - copy
`deny.local.example.txt` to start it); any IPv4 that is not the fixture's own,
documentation space or one of the tool's fixed probe targets also fails it. A failure keeps nothing.
Add `-DenyToken 'ClientName'` for anything else that must never appear, and `-Seed` for a different site.

---

## Known limits, stated up front

1. **This tool sees this PC only.** Another device saturating the same link is invisible to it.
2. Throughput is a **single-CDN measurement** — the path to one Cloudflare edge, not to any
   specific service the customer uses.
3. **Upload timing includes one round trip** and reads pessimistically on high-latency links.
4. The **ETW capture is a 20-second sample**. A process idle during it reads zero, and "no bytes
   attributed in the window" is not "no hog".
5. **ETW counts at the TCP/UDP layer**, roughly 3-6% below the adapter counters. The two are
   deliberately not reconciled.
6. The built-in engine is single-threaded and **cannot measure much above 900 Mbps**. Past that it
   reports a floor and points at the Ookla button.
7. **ICMP can be deprioritised** by the customer's router, which is why an HTTP probe runs
   alongside it — and why the gateway probe is disqualified when it is too slow to be a LAN hop.
8. **Wi-Fi parsing assumes English `netsh` output.** On a localised machine it reports
   `unsupported` rather than guessing at translated labels. **This path has not been tested on real
   hardware** — the development machine has no wireless interface, so only the unsupported path has
   been exercised. Validate on a laptop before trusting that tab.
9. A **clean soak proves only that nothing happened while it was watching**. Under 15 minutes the
   tool refuses to draw any conclusion at all from a clean run.

---

## Status

v1.1.0 (2026-10-08). A GUI review found the Ookla button reporting every successful run as failed,
its results never rendered, the ETW capture never rendered, the gateway probed on the UI thread on
every refresh, the final log lines dropped, a worker error cascading into a dialog every 200 ms, the
ETW button re-enabled after any run past its stated reason, and the Ookla CLI kept in a folder any
user can write to. The same ProgramData exposure turned out to reach the RMM install folder, the
ETW trace and the egress-watch task, so those were hardened too. All fixed and covered by tests. **The Ookla path was verified end to end on a live
link**: downloaded, pin-checked, run through the GUI, `measured` with a Result URL on the Throughput
tab and "Done." in the log.

Not changed, for a decision: the Overview's throughput subscore grades **download only**. An upload
at a fraction of the stated plan is red on the Throughput tab but does not reach the verdict. That
may be deliberate, since upload timing is pessimistic by design (known limit 3).

v1.0.0, all three parts built and verified on Windows 11 / PowerShell 5.1.26100.8875 against a real
10 Mbps-negotiated link.

**Exercised:** the link banner, the F bufferbloat grade, DNS comparison and interception detection,
hog inference, ETW and Wi-Fi degradation paths, JSON schema assertions, stager round-trip and
SHA256 corruption detection, the collector's capture budget and shed ladder, budget-skip reporting,
`-Quiet`, the dev-form guard, and all three renderer input paths. 62 phase-1 checks and 33 phase-2
checks pass, plus 12 build gates.

**Not verified, and you should know it:**

* **The deploy stager's folder lock has only been run on its refusal paths** (unelevated, and a
  folder a standard user owns - both covered by tests). The elevated run that applies the lock has
  not been executed yet. After the first real deploy, confirm with
  `icacls C:\ProgramData\NetSpeedTroubleshooter`: SYSTEM and Administrators `(F)`, Users `(RX)`,
  and nothing marked `(I)`.

* **The Wi-Fi tab and section have never run against real hardware.** This machine has no wireless
  interface, so only the `unsupported` path is exercised. Validate on a laptop before trusting it.
* **The generated collector is ~350 KB and has not been pasted into Atera.** The largest Atera
  paste proven so far is 225 KB, so this is well above known ground. If Atera rejects it, run `Atera_Deploy_NetSpeed.ps1` first and then the staged *dev form*
  of the collector — it lands beside the helpers it dot-sources, so no code change is needed.
* **A full successful throughput run through the collector.** The network this was built on
  blackholes `cloudflare.com` by DNS filtering, so the collector's throughput stage has only been
  exercised on its failure path (which it diagnoses correctly). The engine itself was verified
  end-to-end during phase 1 on a working link.
