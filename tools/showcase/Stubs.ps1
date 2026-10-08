<#
    Showcase stubs - dot-sourced into a PATCHED COPY of the GUI, straight
    after the helpers, by tools\New-NetSpeedShowcase.ps1. Never loaded by the
    shipping GUI, the collector or the build.

    Replaces every function the GUI calls on its own thread that reads this
    machine, so nothing about the real host can reach the screen. Each stub
    returns the same SHAPE as the real function; the values are fictional and
    driven by one seeded RNG so a given seed always renders the same picture.

    Address space used, all reserved for documentation or private use:
      RFC1918 for the LAN, RFC 5737 (192.0.2/24, 198.51.100/24, 203.0.113/24)
      for anything public, RFC 5398 (AS64496-64511) for ASNs, RFC 7042
      (00-00-5E-00-53-xx) for MACs. The only real public addresses on screen
      are the tool's own fixed probe targets (1.1.1.1 and friends).

    Expects $script:ShowcaseSeed and $script:ShowcaseWork to be set first.
#>

$script:ShowRng = New-Object System.Random([int]$script:ShowcaseSeed)
function Get-ShowInt  { param([int]$Min, [int]$Max) return $script:ShowRng.Next($Min, $Max + 1) }
function Get-ShowDbl  { param([double]$Min, [double]$Max) return $Min + ($script:ShowRng.NextDouble() * ($Max - $Min)) }
function Get-ShowPick { param([object[]]$From) return $From[$script:ShowRng.Next(0, $From.Count)] }

# ---- the fictional site -----------------------------------------------------
$sx = @{}
$sx.Host    = Get-ShowPick @('FRONTDESK-04','RECEPTION-07','ACCOUNTS-PC2','WORKSHOP-PC1','ADMIN-LT03','STUDIO-PC05')
$sx.Domain  = 'EXAMPLE'
$sx.User    = 'EXAMPLE\' + (Get-ShowPick @('frontdesk','reception','accounts','workshop','studio'))
$lanStyle   = Get-ShowInt 0 1
if ($lanStyle -eq 0) { $sx.Net = ('10.{0}.{1}' -f (Get-ShowInt 10 250), (Get-ShowInt 0 250)) }
else                 { $sx.Net = ('192.168.{0}' -f (Get-ShowInt 2 250)) }
$sx.Gw      = ('{0}.{1}' -f $sx.Net, (Get-ShowPick @(1, 254)))
$sx.Ip      = ('{0}.{1}' -f $sx.Net, (Get-ShowInt 20 199))
$sx.Pub     = ('203.0.113.{0}' -f (Get-ShowInt 10 240))
$sx.Asn     = Get-ShowInt 64496 64511
$sx.Mac     = ('00-00-5E-00-53-{0:X2}' -f (Get-ShowInt 16 250))
$sx.GwMac   = ('00-00-5E-00-53-{0:X2}' -f (Get-ShowInt 1 15))
$sx.Ps      = '5.1.19041.' + (Get-ShowInt 4000 6500)
$sx.IfIndex = Get-ShowInt 4 24
# Deliberately far from wherever the screenshots are made: a Cloudflare edge
# names a city, and a showcase should not hint at its author's location.
$colo       = Get-ShowPick @(@('AMS','Amsterdam','NL'), @('FRA','Frankfurt','DE'), @('ORD','Chicago','US'), @('YYZ','Toronto','CA'))
$sx.Colo = $colo[0]; $sx.City = $colo[1]; $sx.Country = $colo[2]
# ISP-side hops, all documentation space.
$sx.Hops = @(
    ('198.51.100.{0}' -f (Get-ShowInt 1 60)),
    ('198.51.100.{0}' -f (Get-ShowInt 61 120)),
    ('192.0.2.{0}' -f (Get-ShowInt 1 120)),
    ('192.0.2.{0}' -f (Get-ShowInt 121 250)),
    ('198.51.100.{0}' -f (Get-ShowInt 121 250))
)
$sx.Allowed = @($sx.Gw, $sx.Ip, $sx.Pub) + $sx.Hops
$script:Showcase = $sx

# ---- environment stubs ------------------------------------------------------
function Get-NsContext {
    [pscustomobject]@{
        computerName     = $script:Showcase.Host
        domain           = $script:Showcase.Domain
        osCaption        = 'Microsoft Windows 11 Pro'
        osBuild          = '26100'
        psVersion        = $script:Showcase.Ps
        runAs            = 'NT AUTHORITY\SYSTEM'
        isSystem         = $true
        elevated         = $true
        pid              = $PID
        interactiveUsers = [object[]]@($script:Showcase.User)
    }
}

function Get-NsActiveAdapter {
    param([int]$PreferInterfaceIndex = 0)
    $s = $script:Showcase
    [pscustomobject]@{
        interfaceIndex       = $s.IfIndex
        interfaceGuid        = '{00000000-0000-4000-8000-000000000000}'
        name                 = 'Ethernet'
        interfaceDescription = 'Intel(R) Ethernet Connection (7) I219-LM'
        macAddress           = $s.Mac
        status               = 'Up'
        linkSpeedMbps        = 1000
        linkSpeedText        = '1 Gbps'
        fullDuplex           = $true
        mediaType            = '802.3'
        physicalMediaType    = '802.3'
        interfaceType        = 6
        isWireless           = $false
        isVirtual            = $false
        mtuBytes             = 1500
        ipv4                 = $s.Ip
        ipv4PrefixLength     = 24
        dhcpEnabled          = $true
        gateway              = $s.Gw
        dnsServers           = [object[]]@($s.Gw)
        driverDate           = '2024-03-14'
        driverVersion        = '12.19.2045.3'
        driverProvider       = 'Intel'
        powerSaving          = ''
    }
}

function Get-NsCandidateAdapters {
    @([pscustomobject]@{
        InterfaceIndex  = $script:Showcase.IfIndex
        Name            = 'Ethernet'
        Description     = 'Intel(R) Ethernet Connection (7) I219-LM'
        LinkSpeed       = '1 Gbps'
        HasDefaultRoute = $true
        Virtual         = $false
    })
}

function Test-NsEtwPreconditions { [pscustomobject]@{ Ok = $true; Reason = ''; Elevated = $true; NetshBusy = $false } }
function Get-NsPlatformNotes { return [object[]]@() }
function Stop-NsEtwSession { }

# Egress history: the REAL Get-NsEgressHistory, reading a synthetic log of a
# site that has sat on one address the whole time.
function Get-NsEgressLogPath { return (Join-Path $script:ShowcaseWork 'egress-history.csv') }
& {
    $s = $script:Showcase
    $t0 = New-Object System.DateTime(2026, 10, 2, 22, 0, 0, [System.DateTimeKind]::Utc)
    $lines = [Activator]::CreateInstance([System.Collections.Generic.List[string]])
    $lines.Add('TimestampUtc,PublicIp,LatencyMs,EgressDevice,Note')
    for ($i = 0; $i -lt 1150; $i++) {
        $lines.Add(('{0},{1},{2},{3},' -f $t0.AddMinutes($i * 5).ToString('yyyy-MM-ddTHH:mm:ssZ'), $s.Pub, (Get-ShowInt 9 14), $s.Gw))
    }
    [System.IO.File]::WriteAllLines((Get-NsEgressLogPath), $lines)
}
