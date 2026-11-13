#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Headroom: a Windows 11 debloat and gaming tune-up tool in which every setting is its own switch.

.DESCRIPTION
    Opens a window with about 160 settings in 20 groups. Each setting shows what it does and exactly which registry values,
    services, tasks, features or apps it touches, and reads its current state from this PC. The switch on a card shows the
    feature itself: on means the feature is on (or the service is enabled), off means it is off (or the service is disabled),
    and every card says what Windows has by default. Nothing changes until you move a switch and apply it. Before the first
    change a restore point is created. Putting a setting back restores the Windows default for everything that setting
    changed (not the values the PC had before Headroom); Game Mode and the windowed-games optimizations are the exception:
    switching those off really turns them off. Settings that remove apps cannot be switched back on from here.

    The window opens on a welcome screen and then on Home, which shows the PC as it is right now: Windows, processor, graphics
    card, memory, motherboard, displays and drives. Windows does not report CPU temperature, CPU power or memory timings, so
    those come from HWiNFO or LibreHardwareMonitor. The Start HWiNFO button turns on HWiNFO's sensor sharing for you, after
    asking, and keeps a copy of its settings file. Headroom installs no driver and downloads nothing.

    Select Optimization Preset offers two presets, and each one lists what it will change before anything is applied:
      Question Preset       you answer short questions about how you use this PC (gaming, Riot or FACEIT games, VPN, virtual
                            machines, printing and so on) and it changes only what fits your answers; a setting you are unsure
                            about is left alone
      Custom Preset         your own saved configuration, which can be applied again after a clean install of Windows

    Preview only lists what would happen and changes nothing. Settings that can stop FACEIT or Riot Vanguard, printing, or
    virtual machines ask first.

    Where things are kept:
      undo record   %ProgramData%\Win11GamingDebloat\undo-record.xml
      log           debloat-log.txt on the Desktop (or in %TEMP% if there is no Desktop)

.NOTES
    Needs an administrator PowerShell, or double-click Start-Headroom.bat, which asks Windows for permission and opens the window.

.PARAMETER NoGui
    Do not open the window; work in this console. Without -List, -Preset, -Apply or -Undo it shows the state of every setting.

.PARAMETER DryRun
    Window: starts with Preview only switched on. Console: shows what would happen and changes nothing.

.PARAMETER List
    Console: print every setting with its id, the state of its switch (on / off), the Windows default and which way -Apply turns it.

.PARAMETER Preset
    Console: apply the Recommended preset. A setting that asks a question first asks it when the console is interactive,
    and is skipped with a warning when it is not.

.PARAMETER Apply
    Console: apply these setting ids (see -List: each one says whether -Apply turns its switch on or off). Naming an id is your answer to its question. A setting with options takes
    one as id=option (for example mpo=full); without an option the first one is used. id=default is the same as -Undo id.

.PARAMETER Undo
    Console: put these setting ids back. Every value the setting changed goes back to the Windows default (a setting with
    options goes back to its Windows default option).

.EXAMPLE
    .\Headroom.ps1                                    # opens the window
    .\Headroom.ps1 -NoGui -List                       # which settings are applied?
    .\Headroom.ps1 -NoGui -Preset -DryRun             # preview the Recommended preset
    .\Headroom.ps1 -NoGui -Apply mouse,gamedvr        # just those two
    .\Headroom.ps1 -NoGui -Apply mpo=full             # Multiplane Overlay: Fully disabled
    .\Headroom.ps1 -NoGui -Undo mpo                   # and back to Enabled (the Windows default)
#>

[CmdletBinding()]
param(
    [switch]$NoGui,
    [switch]$DryRun,
    [switch]$List,
    [switch]$Preset,
    [string[]]$Apply,
    [string[]]$Undo
)

# The log goes to the real Desktop folder (it may be redirected), or %TEMP% if that is not writable
$desk = [Environment]::GetFolderPath('Desktop')
if (-not $desk -or -not (Test-Path $desk)) { $desk = [IO.Path]::GetTempPath() }
$log = Join-Path $desk 'debloat-log.txt'
$pd = $env:ProgramData; if (-not $pd) { $pd = [IO.Path]::GetTempPath() }
$StorePath = Join-Path (Join-Path $pd 'Win11GamingDebloat') 'undo-record.xml'
$Q = $null   # event queue for the window; stays $null when running in the console

$engine = {
# =============================================================================
# ENGINE: the catalog of settings and the code that detects, applies and undoes them.
# It is loaded into the window's process (to build the list) and into a background
# thread (to scan and apply), so the window never freezes.
# Needs these variables from whoever loads it:  $DryRun  $log  $StorePath  $Q (or $null)
# =============================================================================
$script:Cache  = @{}
$script:Why    = ''
$script:Now    = ''       # what the part that was just checked read from this PC (set by Get-PartState; custom checks set it themselves)
$script:RunResult = ''    # what a run-once action (Add-Tweak -Once) says it did; Invoke-Plan shows it on the card
$script:InRdp  = ($env:SESSIONNAME -like 'RDP-*')
$script:CurTweak = $null
$script:Catalog = New-Object System.Collections.ArrayList
$script:ById    = @{}
$script:ScanMode = $false     # true while the check of the PC runs: read-only look-ups may then be remembered
$script:NoValue = New-Object System.Object
$script:RegRoot = @{}
try {
    $script:RegRoot['HKLM'] = [Microsoft.Win32.Registry]::LocalMachine
    $script:RegRoot['HKCU'] = [Microsoft.Win32.Registry]::CurrentUser
} catch { }

# ---------------------------------------------------------------- messages --
function Say {
    param($msg, [string]$color = 'Gray')
    $text = ([string]$msg).TrimEnd()
    # the check of the PC only reads: while it runs nothing is written, not even to the log file (the lines still show on screen)
    if ($log -and -not $script:ScanMode) { try { Add-Content -LiteralPath $log -Encoding UTF8 -Value $text } catch { } }
    if ($null -ne $Q) {
        $Q.Enqueue([pscustomobject]@{ Kind = 'log'; Id = ''; State = ''; Detail = ''; Text = $text; Color = $color; A = 0; B = 0 })
    } else {
        Write-Host $text -ForegroundColor $color
    }
}
function Emit {
    # Choice: for a setting with several options (see Add-Tweak -Choices), the key of the option that is in force ('' for the others)
    # Read:   what the check actually read from this PC, one line per value (see Get-PartState)
    # Mine:   'yes' = this app has an undo record for the setting (it changed it), 'no' = it was already like this, '' = not known / not applied
    param([string]$Kind, [string]$Id = '', [string]$State = '', [string]$Detail = '', [string]$Text = '', [string]$Color = 'Gray', [int]$A = 0, [int]$B = 0, [string]$Choice = '', [string]$Read = '', [string]$Mine = '')
    if ($null -eq $Q) { return }
    $Q.Enqueue([pscustomobject]@{ Kind = $Kind; Id = $Id; State = $State; Detail = $Detail; Text = $Text; Color = $Color; A = $A; B = $B; Choice = $Choice; Read = $Read; Mine = $Mine })
}

# --------------------------------------------------- the undo record (store) --
# Before a setting is changed for the first time, what it was is saved here. Switching the setting off does NOT replay those values: it
# puts the Windows default back. The record only tells "changed by this app" from "already like this", and it is the fallback for what
# Windows has no fixed default for (optional features and capabilities, firewall rules when Windows' own list cannot be read) and for
# what this app created itself (a power plan).
function Get-Store {
    $s = @{}
    try {
        if ($StorePath -and (Test-Path -LiteralPath $StorePath)) {
            $x = Import-Clixml -LiteralPath $StorePath -ErrorAction Stop
            if ($x -is [hashtable]) { $s = $x }
        }
    } catch { }
    try { Import-SplitRecords $s } catch { }
    return $s
}
# A setting that was later split into smaller ones keeps its old undo record under the old id. Each new setting is handed the part
# of that record that is its own (and the old record loses it), so switching the new setting off still puts back the values that
# were there before the old setting changed them. Nothing is written here; the next Save-Store keeps the result.
#   new id -> old id
$script:SplitFrom = @{ 'sysresp' = 'netthrottle'; 'gamesched' = 'netthrottle' }
function Import-SplitRecords {
    param($s)
    foreach ($newId in @($script:SplitFrom.Keys)) {
        $t = $script:ById[$newId]
        $old = $s[[string]$script:SplitFrom[$newId]]
        if (-not $t -or -not $old -or $s.ContainsKey($newId) -or -not $old.Reg) { continue }
        $reg = @{}
        foreach ($p in $t.Parts) {
            if ($p.T -ne 'reg') { continue }
            $k = "$($p.Path)|$($p.Name)"
            $v = $old.Reg[$k]
            if ($null -ne $v) { $reg[$k] = $v; $old.Reg.Remove($k) }
        }
        if ($reg.Count -eq 0) { continue }
        $s[$newId] = @{ When = $old.When; Reg = $reg; Svc = @{}; Fw = @{}; Bind = @{}; Feat = @{}; Cap = @{}; Custom = @{} }
    }
}
function Save-Store($s) {
    if ($DryRun -or -not $StorePath) { return }
    try {
        $dir = [IO.Path]::GetDirectoryName($StorePath)
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
        Export-Clixml -InputObject $s -LiteralPath $StorePath -Depth 8 -Force -ErrorAction Stop
    } catch { Say "  ! could not save the undo record: $($_.Exception.Message)" 'Yellow' }
}

# ------------------------------------------------------------ registry -------
function Reg-Read {
    param([string]$Path, [string]$Name)
    $r = @{ Exists = $false; Value = $null; Kind = '' }
    # Fast path: ask the registry directly for HKLM:\ and HKCU:\ paths (about 50 times quicker than the
    # provider, and a check reads hundreds of values). Anything unexpected falls through to the provider below.
    if ($Path.Length -gt 6 -and $Path[4] -eq ':' -and $Path[5] -eq '\') {
        $root = $script:RegRoot[$Path.Substring(0, 4).ToUpperInvariant()]
        if ($root) {
            $k = $null
            $done = $false
            try {
                $k = $root.OpenSubKey($Path.Substring(6))
                if ($k) {
                    $v = $k.GetValue($Name, $script:NoValue, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                    if (-not [object]::ReferenceEquals($v, $script:NoValue)) {
                        $r.Exists = $true
                        $r.Value  = $v
                        $r.Kind   = [string]$k.GetValueKind($Name)
                    }
                }
                $done = $true
            } catch {
                $r = @{ Exists = $false; Value = $null; Kind = '' }
            } finally {
                if ($k) { try { $k.Close() } catch { } }
            }
            if ($done) { return $r }
        }
    }
    if (-not (Test-Path -LiteralPath $Path)) { return $r }
    $k = Get-Item -LiteralPath $Path -ErrorAction Ignore
    if (-not $k) { return $r }
    if ($k.GetValueNames() -contains $Name) {
        $r.Exists = $true
        $r.Value  = $k.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $r.Kind   = [string]$k.GetValueKind($Name)
    }
    return $r
}
function Reg-SubKeys {
    param([string]$Path)
    $o = @()
    foreach ($k in @(Get-ChildItem -LiteralPath $Path -ErrorAction Ignore)) { $o += [string]$k.PSPath }
    return $o
}
function Reg-Equal {
    param($a, $b, [string]$Kind)
    if ($null -eq $a -or $null -eq $b) { return ($null -eq $a -and $null -eq $b) }
    switch ($Kind) {
        'DWord'       { return ([uint32](([long]$a) -band 4294967295L) -eq [uint32](([long]$b) -band 4294967295L)) }
        'QWord'       { return ([int64]$a -eq [int64]$b) }
        'Binary'      { return ((@($a) -join ',') -eq (@($b) -join ',')) }
        'MultiString' { return ((@($a) -join "`n") -eq (@($b) -join "`n")) }
        default       { return ([string]$a -eq [string]$b) }
    }
}
# Takes an error that was caught on purpose out of $Error, so the run does not list it afterwards as a problem
function Drop-Error {
    param($rec)
    try {
        $n = [Math]::Min($Error.Count, 6)
        for ($i = 0; $i -lt $n; $i++) {
            if ([object]::ReferenceEquals($Error[$i].Exception, $rec.Exception) -or $Error[$i].Exception.Message -eq $rec.Exception.Message) { $Error.RemoveAt($i); return }
        }
    } catch { }
}
# Takes every error added to $Error since it held $n0 out again: they were expected, and the caller reports what matters itself
# ($Error is newest first)
function Drop-ErrorsSince {
    param([int]$n0)
    try { while ($Error.Count -gt $n0) { $Error.RemoveAt(0) } } catch { }
}
# -Soft: a switch that newer Windows 11 builds protect (programs get "Attempted to perform an unauthorized operation").
# A refusal is then only noted, not reported as a failure.
function Reg-Write {
    param([string]$Path, [string]$Name, $Value, [string]$Kind = 'DWord', [switch]$Quiet, [switch]$Soft)
    if ($DryRun) { if (-not $Quiet) { Say "  [dry] set $Path\$Name = $Value" 'DarkGray' }; return $true }
    # A DWord is stored as 32 bits, but Windows PowerShell hands it to .NET as a signed number: a value above 2147483647
    # (0xFFFFFFFF, say) is refused unless it is passed as the same 32 bits read as a negative number.
    $data = $Value
    if ($Kind -eq 'DWord' -and $null -ne $Value) {
        $wide = 0L
        if ([long]::TryParse([string]$Value, [ref]$wide) -and $wide -gt 2147483647L -and $wide -le 4294967295L) { $data = [int]($wide - 4294967296L) }
    }
    try {
        if ($Name -eq '') {
            # the key's own (Default) value: New-ItemProperty cannot take an empty name, so it is written through .NET (HKLM:\ and HKCU:\ only)
            $root = $null; if ($Path.Length -gt 6 -and $Path[4] -eq ':' -and $Path[5] -eq '\') { $root = $script:RegRoot[$Path.Substring(0, 4).ToUpperInvariant()] }
            if (-not $root) { throw 'the (Default) value can only be written under HKLM:\ or HKCU:\' }
            $dk = $root.CreateSubKey($Path.Substring(6))
            try { $dk.SetValue('', [string]$data, [Microsoft.Win32.RegistryValueKind]::String) } finally { $dk.Close() }
            if (-not $Quiet) { Say "  set $Path\(Default) = $Value" 'DarkGray' }
            return $true
        }
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $data -PropertyType $Kind -Force -ErrorAction Stop | Out-Null
        if (-not $Quiet) { Say "  set $Path\$Name = $Value" 'DarkGray' }
        return $true
    } catch {
        if ($Soft) {
            Drop-Error $_
            Say "  note: Windows protects $Path\$Name and did not let it be changed; it was left as it is (the other parts of this setting still apply)" 'DarkGray'
        } else {
            Say "  ! could not set $Path\$Name  ($($_.Exception.Message))" 'Yellow'
        }
        return $false
    }
}
function Reg-Remove {
    param([string]$Path, [string]$Name, [switch]$Quiet, [switch]$Soft)
    if (-not (Reg-Read $Path $Name).Exists) { return $true }
    if ($DryRun) { if (-not $Quiet) { Say "  [dry] remove $Path\$Name" 'DarkGray' }; return $true }
    try {
        Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        if (-not $Quiet) { Say "  removed $Path\$Name" 'DarkGray' }
        return $true
    } catch {
        if ($Soft) {
            Drop-Error $_
            Say "  note: Windows protects $Path\$Name and did not let it be changed; it was left as it is" 'DarkGray'
        } else {
            Say "  ! could not remove $Path\$Name  ($($_.Exception.Message))" 'Yellow'
        }
        return $false
    }
}
# Whole registry keys (some switches are just "this key exists")
function Reg-KeyExists { param([string]$Path) return (Test-Path -LiteralPath $Path) }
function Reg-KeyAdd {
    param([string]$Path)
    if (Reg-KeyExists $Path) { return $true }
    if ($DryRun) { Say "  [dry] create registry key $Path" 'DarkGray'; return $true }
    try {
        New-Item -Path $Path -Force -Value '' -ErrorAction Stop | Out-Null
        Say "  created registry key $Path" 'DarkGray'
        return $true
    } catch {
        Say "  ! could not create $Path  ($($_.Exception.Message))" 'Yellow'
        return $false
    }
}
# A key that may be deleted as a whole: at least three levels below the hive (HKLM:\SOFTWARE\Classes\ms-gamebar), and never one of the
# keys that hold whole parts of Windows (a mistake in a path must not take, say, every CLSID or every service with it). A second lock:
# the settings only name keys of their own.
$script:RegKeyKeep = @('software\classes\clsid', 'software\classes\interface', 'software\classes\typelib', 'software\classes\appid',
    'software\classes\applications', 'software\classes\systemfileassociations', 'software\classes\directory', 'software\classes\folder',
    'software\classes\*', 'software\classes\drive', 'software\classes\local settings', 'software\microsoft\windows',
    'software\microsoft\windows nt', 'software\policies\microsoft', 'software\wow6432node\microsoft', 'software\wow6432node\classes',
    'system\currentcontrolset\services', 'system\currentcontrolset\control', 'system\currentcontrolset\enum', 'system\currentcontrolset\hardware profiles')
function Reg-KeyIsDeep {
    param([string]$Path)
    $p = ([string]$Path).Trim()
    $m = [regex]::Match($p, '^(?i)(HKLM:|HKCU:|Registry::HKEY_[A-Z_]+)\\(.+)$')
    if (-not $m.Success) { return $false }
    $parts = @($m.Groups[2].Value.Split('\') | ForEach-Object { $_.Trim() })
    if (@($parts | Where-Object { -not $_ }).Count -gt 0) { return $false }          # (an empty level: a name that was missing)
    $root = $m.Groups[1].Value.ToUpperInvariant()
    if ($root -eq 'REGISTRY::HKEY_USERS') { if ($parts.Count -lt 4) { return $false }; $parts = @($parts | Select-Object -Skip 1) }
    if ($parts.Count -lt 3) { return $false }
    if ($parts.Count -eq 3 -and $script:RegKeyKeep -contains (($parts -join '\').ToLowerInvariant())) { return $false }
    return $true
}
function Reg-KeyRemove {
    param([string]$Path)
    if (-not (Reg-KeyIsDeep $Path)) { Say "  ! $Path was not deleted: it is too near the top of the registry to be a key of this app's own" 'Yellow'; return $false }
    if (-not (Reg-KeyExists $Path)) { return $true }
    if ($DryRun) { Say "  [dry] delete registry key $Path" 'DarkGray'; return $true }
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        Say "  deleted registry key $Path" 'DarkGray'
        return $true
    } catch {
        Say "  ! could not delete $Path  ($($_.Exception.Message))" 'Yellow'
        return $false
    }
}
# Every named value in a key:  @{ Name; Value; Kind }  (the unnamed default value is left out)
function Reg-Values {
    param([string]$Path)
    $o = @()
    if (-not (Test-Path -LiteralPath $Path)) { return $o }
    $k = Get-Item -LiteralPath $Path -ErrorAction Ignore
    if (-not $k) { return $o }
    foreach ($n in $k.GetValueNames()) {
        if (-not $n) { continue }
        $o += ,@{ Name = [string]$n
                  Value = $k.GetValue($n, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                  Kind = [string]$k.GetValueKind($n) }
    }
    return $o
}

# --------------------------------------- look-ups that are remembered during a check --
# While the PC is being checked ($script:ScanMode) a read-only question that several settings ask is
# put to Windows once and the answer is reused. Outside a check every call asks Windows afresh.
# Whatever the question printed is returned exactly as the plain call would have returned it.
function Scan-Memo {
    param([string]$MemoKey, [scriptblock]$MemoMake)
    if (-not $script:ScanMode) { return (& $MemoMake) }
    if (-not $script:Cache.ContainsKey($MemoKey)) { $script:Cache[$MemoKey] = @(& $MemoMake) }
    return $script:Cache[$MemoKey]
}

# --------------------------------------- slow questions asked in the background --
# Windows answers some questions slowly (optional features, capabilities, apps, firewall rules, scheduled
# tasks, adapter bindings, USB devices). A check starts them all at once in the background and carries on with
# the fast settings meanwhile; a setting that needs an answer waits for it. The three that use DISM
# (features, apps' provisioned packages, capabilities) run one after the other, never side by side.
# If a background question fails or comes back empty, the very same question is asked again in place, so
# the result never depends on the background work.
$script:Pre = $null
$script:PreOff = $false       # true: always ask in place (the tests do this)
$script:PreWait = 300         # most seconds Pre-Wait itself waits for one background answer
$script:PreStall = 60         # seconds in which nothing at all moves forward before the check stops waiting for a background answer and asks in place
$script:PreStallDism = 240    # the same for the three DISM questions (asking those twice side by side only makes both slower)
$script:PreGiven = @{}        # background answers the check has stopped waiting for (they are asked in place instead)
$script:PreSeen = @{}         # background answers the log has already mentioned
$script:PreLabels = @{ feat = 'optional features'; prov = 'installed apps'; appx = 'installed apps'; cap = 'Windows capabilities'; tasks = 'scheduled tasks'
                       fw = 'firewall rules'; bind = 'network adapter settings'; net = 'network adapters'; usb = 'USB devices' }
$script:PreInit = ''          # extra text run first in every background script (the tests put stand-in commands here)
# Started in this order, at most $script:PreSlots at a time: the long ones first, the quick ones as soon as a place is free.
# (Asking everything of Windows at once makes every question slower.)
$script:PreSlots = 4
$script:PreGroups = @(@('prov', 'feat', 'cap'), @('tasks'), @('fw'), @('appx'), @('bind'), @('net'), @('usb'))
$script:PreScripts = @{
    feat = @'
Get-WindowsOptionalFeature -Online -ErrorAction Ignore | ForEach-Object { [pscustomobject]@{ N = [string]$_.FeatureName; S = [string]$_.State } }
'@
    prov = @'
Get-AppxProvisionedPackage -Online -ErrorAction Ignore | ForEach-Object { [pscustomobject]@{ N = [string]$_.DisplayName; P = [string]$_.PackageName } }
'@
    cap = @'
Get-WindowsCapability -Online -ErrorAction Ignore | ForEach-Object { [pscustomobject]@{ N = [string]$_.Name; S = [string]$_.State } }
'@
    appx = @'
Get-AppxPackage -AllUsers -ErrorAction Ignore | ForEach-Object {
    # L: is the app installed for at least one user? A package that is only "Staged" (what stays behind when the app was uninstalled
    # from Start or Settings: the copy kept for new accounts) is not, and neither is one whose removal is pending (it was in use: Windows
    # finishes removing it at the next restart). When Windows does not say, it counts as installed.
    $live = $true; $sys = $false
    try {
        $ui = @($_.PackageUserInformation)
        if ($ui.Count -gt 0) {
            # (a copy that only Windows' own system account, S-1-5-18, has is installed for no one who signs in: S)
            $live = $false
            foreach ($u in $ui) {
                $s = ([string]$u.InstallState + ' ' + [string]$u); if ($s -match 'Staged' -or $s -match 'pending\s*removal') { continue }
                $sid = ''; try { $sid = [string]$u.UserSecurityId.Sid } catch { }
                if ($sid -notmatch '^S-1-') { $sid = [regex]::Match([string]$u, 'S-1-[0-9-]+').Value }
                if ($sid -eq 'S-1-5-18') { $sys = $true } else { $live = $true }
            }
        }
    } catch { $live = $true }
    [pscustomobject]@{ N = [string]$_.Name; F = [string]$_.PackageFullName; R = [bool]$_.NonRemovable; L = $live; S = $sys }
}
'@
    tasks = @'
Get-ScheduledTask -ErrorAction Ignore | ForEach-Object { [pscustomobject]@{ P = [string]$_.TaskPath; N = [string]$_.TaskName; S = [string]$_.State } }
'@
    fw = @'
Get-NetFirewallRule -ErrorAction Ignore | ForEach-Object { [pscustomobject]@{ N = [string]$_.Name; G = [string]$_.DisplayGroup; E = [string]$_.Enabled } }
'@
    bind = @'
Get-NetAdapterBinding -ErrorAction Ignore | ForEach-Object { [pscustomobject]@{ N = [string]$_.Name; C = [string]$_.ComponentID; E = [bool]$_.Enabled } }
'@
    net = @'
$nics = @(Get-NetAdapter -Physical -ErrorAction Ignore)
foreach ($n in $nics) { [pscustomobject]@{ K = 'nic'; A = [string]$n.Name; D = [string]$n.InterfaceDescription; G = [string]$n.InterfaceGuid; P = [string]$n.PnPDeviceID } }
foreach ($i in @(Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -ErrorAction Ignore)) { [pscustomobject]@{ K = 'pm'; I = [string]$i.InstanceName; E = [bool]$i.Enable } }
foreach ($n in $nics) {
    foreach ($a in @(Get-NetAdapterAdvancedProperty -Name $n.Name -ErrorAction Ignore)) {
        $valid = @(); foreach ($v in @($a.ValidDisplayValues)) { $valid += [string]$v }
        [pscustomobject]@{ K = 'adv'; A = [string]$n.Name; N = [string]$a.DisplayName; V = [string]$a.DisplayValue; W = [string]$a.RegistryKeyword; R = [string](@($a.RegistryValue)[0]); L = $valid }
    }
    $r = Get-NetAdapterPowerManagement -Name $n.Name -ErrorAction Ignore
    if ($r) { [pscustomobject]@{ K = 'npm'; A = [string]$n.Name; S = [string]$r.SelectiveSuspend; D = [string]$r.DeviceSleepOnDisconnect; T = [string]$r.AllowComputerToTurnOffDevice } }
}
'@
    usb = @'
$all = @(Get-PnpDevice -Class USB -ErrorAction Ignore) + @(Get-PnpDevice -ErrorAction Ignore | Where-Object { $_.InstanceId -like 'USB\*' })
$seen = @{}
foreach ($d in $all) {
    $id = [string]$d.InstanceId
    if ($id -and -not $seen.ContainsKey($id)) { $seen[$id] = 1; [pscustomobject]@{ I = $id; N = [string]$d.FriendlyName } }
}
'@
}
$script:PreRunner = @'
param($Data, $Init, $Names, $Scripts)
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
if ($Init) { . ([scriptblock]::Create($Init)) }
foreach ($n in $Names) {
    $ok = $true
    $items = @()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try { $items = @(& ([scriptblock]::Create([string]$Scripts[$n]))) } catch { $ok = $false }
    $Data[$n] = @{ Ok = $ok; Items = $items; Secs = $sw.Elapsed.TotalSeconds }
}
'@
function Start-Prefetch {
    $script:Pre = $null
    $script:PreGiven = @{}
    $script:PreSeen = @{}
    if ($script:PreOff) { return }
    $pool = $null
    $handles = @()
    $map = @{}
    try {
        # Same rule as the worker: modules may load whatever the machine's script policy says (the pool only runs our own text).
        # If this PowerShell does not accept that, the plain pool is used.
        try {
            $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
            $iss.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass
            $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $script:PreSlots, $iss, $Host)
            $pool.Open()
        } catch {
            if ($pool) { try { $pool.Dispose() } catch { } }
            $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $script:PreSlots)
            $pool.Open()
        }
        $data = [hashtable]::Synchronized(@{})
        foreach ($names in $script:PreGroups) {
            $ps = [System.Management.Automation.PowerShell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($script:PreRunner).AddArgument($data).AddArgument($script:PreInit).AddArgument($names).AddArgument($script:PreScripts)
            $h = @{ PS = $ps; Async = $ps.BeginInvoke() }
            $handles += ,$h
            foreach ($nm in $names) { $map[[string]$nm] = $h }
        }
        $script:Pre = @{ Pool = $pool; Data = $data; Handles = $handles; Map = $map }
    } catch {
        foreach ($h in $handles) { try { $h.PS.Dispose() } catch { } }
        if ($pool) { try { $pool.Dispose() } catch { } }
        $script:Pre = $null
    }
}
function Stop-Prefetch {
    $p = $script:Pre
    $script:Pre = $null
    if (-not $p) { return }
    $running = $false
    foreach ($h in @($p.Handles)) {
        if (-not $h.Async.IsCompleted) { $running = $true; try { [void]$h.PS.BeginStop($null, $null) } catch { } }
    }
    if ($running) {
        try { [void]$p.Pool.CloseAsync() } catch { }          # do not wait for a query that cannot be interrupted
    } else {
        foreach ($h in @($p.Handles)) { try { $h.PS.Dispose() } catch { } }
        try { $p.Pool.Close() } catch { }
        try { $p.Pool.Dispose() } catch { }
    }
}
# Is the background answer called $Name there (or its work finished, or given up on)? True when there is no background work at all.
function Pre-Done {
    param([string]$Name)
    $p = $script:Pre
    if (-not $p) { return $true }
    if ($p.Data.ContainsKey($Name)) { return $true }
    if ($script:PreGiven.ContainsKey($Name)) { return $true }
    $h = $p.Map[$Name]
    if (-not $h) { return $true }
    return [bool]$h.Async.IsCompleted
}
# The background answer called $Name as an array of objects, or $null when there is none (ask in place then)
function Pre-Wait {
    param([string]$Name)
    $p = $script:Pre
    if (-not $p) { return $null }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not (Pre-Done $Name)) {
        if ($sw.Elapsed.TotalSeconds -gt $script:PreWait) { return $null }
        Start-Sleep -Milliseconds 30
    }
    if (-not $p.Data.ContainsKey($Name)) { return $null }
    $r = $p.Data[$Name]
    if (-not $r -or -not $r.Ok) { return $null }
    $items = @($r.Items)
    if ($items.Count -eq 0) { return $null }
    return ,$items
}
# Which background answers a setting's check asks for (so the check can leave it until they have arrived).
# Settings that use a slow question without saying so in their parts are listed here; the tests compare this list with
# what the checks really ask for.
$script:CustomNeeds = @{ UsbPower = @('usb', 'net'); NicTurnOff = @('net'); NicEee = @('net'); NicSuspend = @('net'); AiCore = @('appx', 'prov'); Hypervisor = @('feat') }
$script:NeedsMemo = @{}
function Get-TweakNeeds {
    param($t)
    $id = [string]$t.Id
    if ($script:NeedsMemo.ContainsKey($id)) { return $script:NeedsMemo[$id] }
    $n = @{}
    foreach ($p in $t.Parts) {
        switch ([string]$p.T) {
            'task'   { $n['tasks'] = 1 }
            'taskdyn' { $n['tasks'] = 1 }
            'fw'     { $n['fw'] = 1 }
            'bind'   { $n['bind'] = 1 }
            'feat'   { $n['feat'] = 1 }
            'cap'    { $n['cap'] = 1 }
            'appx'   { $n['appx'] = 1; $n['prov'] = 1 }
            'svc'    { if ([string]$p.SkipIf -match 'Test-UsesVirtualization') { $n['feat'] = 1 } }
            'custom' { foreach ($x in @($script:CustomNeeds[[string]$p.Name])) { if ($x) { $n[[string]$x] = 1 } } }
        }
    }
    $r = @($n.Keys | Sort-Object)
    $script:NeedsMemo[$id] = $r
    return $r
}
function Pre-Ready {
    param($needs)
    foreach ($nm in @($needs)) { if (-not (Pre-Done ([string]$nm))) { return $false } }
    return $true
}
# Writes a line to the log for every background answer that has arrived since the last call. True when there was a new one.
function Pre-Note {
    $p = $script:Pre
    if (-not $p) { return $false }
    $any = $false
    foreach ($nm in @($p.Map.Keys)) {
        if ($script:PreSeen.ContainsKey($nm) -or -not $p.Data.ContainsKey($nm)) { continue }
        $script:PreSeen[$nm] = 1
        $any = $true
        if ($null -eq $Q) { continue }          # in the console the list is the output; the timings go to the window's log only
        $r = $p.Data[$nm]
        if ($r.Ok) { Say ('  Windows answered: {0} ({1} found, {2:N1} s)' -f $script:PreLabels[$nm], @($r.Items).Count, [double]$r.Secs) 'DarkGray' }
        else { Say ('  Windows could not answer in the background: {0} (it is asked again directly)' -f $script:PreLabels[$nm]) 'DarkGray' }
    }
    return $any
}
# The background answers that the settings still waiting need and that have not arrived
function Pre-Missing {
    param($pending)
    $m = @{}
    foreach ($t in $pending) { foreach ($nm in @(Get-TweakNeeds $t)) { if (-not (Pre-Done ([string]$nm))) { $m[[string]$nm] = 1 } } }
    return @($m.Keys | Sort-Object)
}

# ------------------------------------------------------------ services -------
# Start type is read and written through the registry (Start + DelayedAutostart), which also
# works for services that Set-Service refuses to touch.
$script:SvcRoot = 'HKLM:\SYSTEM\CurrentControlSet\Services'
function Svc-Read {
    param([string]$Name)
    $s = Reg-Read "$script:SvcRoot\$Name" 'Start'
    if (-not $s.Exists) { return $null }
    $d = Reg-Read "$script:SvcRoot\$Name" 'DelayedAutostart'
    $delayed = 0; if ($d.Exists) { $delayed = [int]$d.Value }
    return @{ Start = [int]$s.Value; Delayed = $delayed }
}
function Svc-Decode {
    param([string]$s)
    switch ($s) {
        'Automatic'        { return @{ Start = 2; Delayed = 0 } }
        'AutomaticDelayed' { return @{ Start = 2; Delayed = 1 } }
        'Manual'           { return @{ Start = 3; Delayed = 0 } }
        'Disabled'         { return @{ Start = 4; Delayed = 0 } }
        default            { throw ('unknown service start type "{0}"' -f $s) }      # (a typo must never disable a service)
    }
}
function Svc-Label {
    param($cur)
    if ($null -eq $cur) { return 'missing' }
    switch ($cur.Start) {
        2 { if ($cur.Delayed) { return 'Automatic (delayed)' } else { return 'Automatic' } }
        3 { return 'Manual' }
        4 { return 'Disabled' }
        default { return "start=$($cur.Start)" }
    }
}
function Svc-IsApplied {
    param($cur, $p)
    if ($p.Set -eq 'Manual') { return ($cur.Start -eq 3 -or $cur.Start -eq 4) }
    return ($cur.Start -eq 4)
}
function Svc-Write {
    param([string]$Name, $Want)
    $type = @{ 2 = 'Automatic'; 3 = 'Manual'; 4 = 'Disabled' }[[int]$Want.Start]
    if ($DryRun) { Say ("  [dry] service {0} -> {1}" -f $Name, (Svc-Label $Want)) 'DarkGray'; return }
    # Remote Desktop services are not stopped while you are connected through Remote Desktop
    $keepRunning = ($script:InRdp -and ('TermService', 'UmRdpService', 'SessionEnv') -contains $Name)
    if ($Want.Start -eq 4 -and -not $keepRunning) { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue }
    Set-Service -Name $Name -StartupType $type -ErrorAction SilentlyContinue
    [void](Reg-Write "$script:SvcRoot\$Name" 'Start' ([int]$Want.Start) 'DWord' -Quiet)
    if ($Want.Delayed) { [void](Reg-Write "$script:SvcRoot\$Name" 'DelayedAutostart' 1 'DWord' -Quiet) }
    else               { [void](Reg-Remove "$script:SvcRoot\$Name" 'DelayedAutostart' -Quiet) }
    if ($Want.Start -eq 2) { Start-Service -Name $Name -ErrorAction SilentlyContinue }
    Say ("  service {0} -> {1}" -f $Name, (Svc-Label $Want)) 'DarkGray'
}

# ------------------------------------------------------ scheduled tasks ------
function Task-Split { param([string]$full) $i = $full.LastIndexOf('\'); return @{ Path = $full.Substring(0, $i + 1); Name = $full.Substring($i + 1) } }
# All scheduled tasks at once (path + name, lower case -> enabled). Asking for every task one by one is slow.
function Task-All {
    if (-not $script:Cache.ContainsKey('tasks')) {
        $m = @{}
        $pre = Pre-Wait 'tasks'
        if ($null -ne $pre) {
            foreach ($x in $pre) { $m[(([string]$x.P + [string]$x.N).ToLowerInvariant())] = ([string]$x.S -ne 'Disabled') }
        } else {
            foreach ($t in @(Get-ScheduledTask -ErrorAction Ignore)) { $m[(([string]$t.TaskPath + [string]$t.TaskName).ToLowerInvariant())] = ([string]$t.State -ne 'Disabled') }
        }
        $script:Cache['tasks'] = $m
    }
    return $script:Cache['tasks']
}
function Task-Read {
    param([string]$full)
    $s = Task-Split $full
    if ($script:ScanMode) {
        $m = Task-All
        if ($m.Count -ge 20) {       # a real list; a short or empty one means the question failed, so ask for this task alone
            $k = ($s.Path + $s.Name).ToLowerInvariant()
            if ($m.ContainsKey($k)) { return @{ Enabled = $m[$k] } }
            return $null
        }
    }
    $t = Get-ScheduledTask -TaskPath $s.Path -TaskName $s.Name -ErrorAction Ignore
    if (-not $t) { return $null }
    return @{ Enabled = ([string]$t.State -ne 'Disabled') }
}
# The full names of the scheduled tasks in one folder whose name starts with a prefix.
# While scanning they come from the one list of all tasks (names in lower case); otherwise Windows is asked for that folder.
function Task-Match {
    param([string]$Folder, [string]$Prefix)
    $out = @()
    $m = $null
    if ($script:ScanMode) { $m = Task-All; if ($m.Count -lt 20) { $m = $null } }
    if ($null -ne $m) {
        $f = ($Folder + $Prefix).ToLowerInvariant()
        foreach ($k in $m.Keys) { if ($k.StartsWith($f) -and $k.IndexOf('\', $Folder.Length) -lt 0) { $out += [string]$k } }
    } else {
        foreach ($t in @(Get-ScheduledTask -TaskPath $Folder -ErrorAction Ignore)) {
            if ([string]$t.TaskName -like ($Prefix + '*')) { $out += ([string]$t.TaskPath + [string]$t.TaskName) }
        }
    }
    return @($out | Sort-Object)
}
function Task-Write {
    param([string]$full, [bool]$enable)
    $s = Task-Split $full
    if ($DryRun) { Say ("  [dry] task {0} -> {1}" -f $s.Name, $(if ($enable) { 'enabled' } else { 'disabled' })) 'DarkGray'; return }
    if ($enable) { Enable-ScheduledTask  -TaskPath $s.Path -TaskName $s.Name -ErrorAction SilentlyContinue | Out-Null }
    else         { Disable-ScheduledTask -TaskPath $s.Path -TaskName $s.Name -ErrorAction SilentlyContinue | Out-Null }
    Say ("  task {0} -> {1}" -f $s.Name, $(if ($enable) { 'enabled' } else { 'disabled' })) 'DarkGray'
}

# --------------------------------------------------------- firewall ----------
# Every firewall rule at once, sorted into groups (group name in lower case -> rules)
function Fw-Index {
    if (-not $script:Cache.ContainsKey('fw')) {
        $idx = @{}
        $count = 0
        $pre = Pre-Wait 'fw'
        $rules = @()
        if ($null -ne $pre) {
            foreach ($x in $pre) { $rules += ,@{ Name = [string]$x.N; Group = [string]$x.G; Enabled = ([string]$x.E -eq 'True') } }
        } else {
            foreach ($r in @(Get-NetFirewallRule -ErrorAction Ignore)) { $rules += ,@{ Name = [string]$r.Name; Group = [string]$r.DisplayGroup; Enabled = ([string]$r.Enabled -eq 'True') } }
        }
        foreach ($r in $rules) {
            $g = $r.Group.ToLowerInvariant()
            if (-not $idx.ContainsKey($g)) { $idx[$g] = New-Object System.Collections.ArrayList }
            [void]$idx[$g].Add(@{ Name = $r.Name; Enabled = $r.Enabled })
            $count++
        }
        $script:Cache['fw'] = @{ Groups = $idx; Count = $count }
    }
    return $script:Cache['fw']
}
function Fw-Rules {
    param([string]$group)
    $out = @()
    if ($script:ScanMode -and $group -notmatch '[\*\?\[]') {
        $ix = Fw-Index
        if ($ix.Count -ge 20) {      # a real list; a short or empty one means the question failed, so ask for this group alone
            $k = $group.ToLowerInvariant()
            if ($ix.Groups.ContainsKey($k)) { foreach ($r in $ix.Groups[$k]) { $out += ,@{ Name = $r.Name; Enabled = $r.Enabled } } }
            return $out
        }
    }
    foreach ($r in @(Get-NetFirewallRule -DisplayGroup $group -ErrorAction Ignore)) {
        $out += ,@{ Name = [string]$r.Name; Enabled = ([string]$r.Enabled -eq 'True') }
    }
    return $out
}
function Fw-DisableGroup {
    param([string]$group)
    if ($DryRun) { Say "  [dry] firewall rules off: $group" 'DarkGray'; return }
    Disable-NetFirewallRule -DisplayGroup $group -ErrorAction SilentlyContinue
    Say "  firewall rules off: $group" 'DarkGray'
}
function Fw-EnableNames {
    param([string]$group, [string[]]$names)
    if ($DryRun) { Say "  [dry] firewall rules back on: $group ($($names.Count) rule(s))" 'DarkGray'; return }
    Enable-NetFirewallRule -Name $names -ErrorAction SilentlyContinue
    Say "  firewall rules back on: $group ($($names.Count) rule(s))" 'DarkGray'
}
# Windows' own list of its firewall rules as they ship (the one "restore defaults" uses; one text per rule, with Active=TRUE or Active=FALSE).
# Returns the names of the rules of this group that ship switched on (an empty list when none does), or $null when the list cannot be read
# or does not know any rule of the group: then nothing is known about how they ship. Rules of the group that Windows did not ship are left out.
function Fw-DefaultOn {
    param([string]$group)
    $root = 'HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Defaults\FirewallPolicy\FirewallRules'
    if (-not (Reg-KeyExists $root)) { return $null }
    $on = @(); $known = 0
    foreach ($r in @(Fw-Rules $group)) {
        $c = Reg-Read $root ([string]$r.Name)
        if (-not $c.Exists) { continue }
        $known++
        if ([string]$c.Value -match '(?i)\|Active=TRUE\|') { $on += [string]$r.Name }
    }
    if ($known -eq 0) { return $null }
    return ,$on
}

# ------------------------------------------------------ adapter bindings -----
# Every adapter binding at once (component id in lower case -> bindings)
function Bind-Index {
    if (-not $script:Cache.ContainsKey('bind')) {
        $idx = @{}
        $count = 0
        $pre = Pre-Wait 'bind'
        $list = @()
        if ($null -ne $pre) {
            foreach ($x in $pre) { $list += ,@{ Comp = [string]$x.C; Name = [string]$x.N; Enabled = [bool]$x.E } }
        } else {
            foreach ($b in @(Get-NetAdapterBinding -ErrorAction Ignore)) { $list += ,@{ Comp = [string]$b.ComponentID; Name = [string]$b.Name; Enabled = [bool]$b.Enabled } }
        }
        foreach ($b in $list) {
            $c = $b.Comp.ToLowerInvariant()
            if (-not $idx.ContainsKey($c)) { $idx[$c] = New-Object System.Collections.ArrayList }
            [void]$idx[$c].Add(@{ Name = $b.Name; Enabled = $b.Enabled })
            $count++
        }
        $script:Cache['bind'] = @{ Comps = $idx; Count = $count }
    }
    return $script:Cache['bind']
}
function Bind-Read {
    param([string]$comp)
    $out = @()
    if ($script:ScanMode) {
        $ix = Bind-Index
        if ($ix.Count -gt 0) {       # an empty list may mean the question failed, so ask for this component alone
            $k = $comp.ToLowerInvariant()
            if ($ix.Comps.ContainsKey($k)) { foreach ($b in $ix.Comps[$k]) { $out += ,@{ Name = $b.Name; Enabled = $b.Enabled } } }
            return $out
        }
    }
    foreach ($b in @(Get-NetAdapterBinding -ComponentID $comp -ErrorAction Ignore)) {
        $out += ,@{ Name = [string]$b.Name; Enabled = [bool]$b.Enabled }
    }
    return $out
}
function Bind-Set {
    param([string]$adapter, [string]$comp, [bool]$enable)
    $word = 'off'; if ($enable) { $word = 'on' }
    if ($DryRun) { Say "  [dry] adapter $adapter : $comp $word" 'DarkGray'; return }
    if ($enable) { Enable-NetAdapterBinding  -Name $adapter -ComponentID $comp -ErrorAction SilentlyContinue }
    else         { Disable-NetAdapterBinding -Name $adapter -ComponentID $comp -ErrorAction SilentlyContinue }
    Say "  adapter $adapter : $comp $word" 'DarkGray'
}

# ------------------------------------------- optional features, capabilities --
function Feat-State {
    param([string]$name)
    if (-not $script:Cache.ContainsKey('feat')) {
        $m = @{}
        $pre = Pre-Wait 'feat'
        if ($null -ne $pre) {
            foreach ($f in $pre) { $m[[string]$f.N] = [string]$f.S }
        } else {
            foreach ($f in @(Get-WindowsOptionalFeature -Online -ErrorAction Ignore)) { $m[[string]$f.FeatureName] = [string]$f.State }
        }
        $script:Cache['feat'] = $m
    }
    return $script:Cache['feat'][$name]
}
function Feat-Set {
    param([string]$name, [bool]$enable)
    $word = 'removed'; if ($enable) { $word = 'added back' }
    if ($DryRun) { Say "  [dry] Windows feature $name $word" 'DarkGray'; return }
    Say "  Windows feature $name : $word (this can take a minute)..." 'Gray'
    if ($enable) { Enable-WindowsOptionalFeature  -Online -FeatureName $name -All -NoRestart -ErrorAction SilentlyContinue | Out-Null }
    else         { Disable-WindowsOptionalFeature -Online -FeatureName $name -NoRestart -ErrorAction SilentlyContinue | Out-Null }
}
function Cap-List {
    param([string]$pattern)
    if (-not $script:Cache.ContainsKey('cap')) {
        $l = @()
        $pre = Pre-Wait 'cap'
        if ($null -ne $pre) {
            foreach ($c in $pre) { $l += ,@{ Name = [string]$c.N; State = [string]$c.S } }
        } else {
            foreach ($c in @(Get-WindowsCapability -Online -ErrorAction Ignore)) { $l += ,@{ Name = [string]$c.Name; State = [string]$c.State } }
        }
        $script:Cache['cap'] = $l
    }
    $hit = @()
    foreach ($c in $script:Cache['cap']) { if ($c.Name -like $pattern) { $hit += ,$c } }
    return $hit
}
function Cap-Set {
    param([string]$name, [bool]$install)
    $word = 'removed'; if ($install) { $word = 'added back' }
    if ($DryRun) { Say "  [dry] Windows capability $name $word" 'DarkGray'; return }
    Say "  Windows capability $name : $word..." 'Gray'
    if ($install) { Add-WindowsCapability    -Online -Name $name -ErrorAction SilentlyContinue | Out-Null }
    else          { Remove-WindowsCapability -Online -Name $name -ErrorAction SilentlyContinue | Out-Null }
}

# ------------------------------------------------------------ apps -----------
# Never removed, even when a wildcard in the catalog matches them (a setting that names one of them exactly can still remove it:
# Camera, Paint, Snipping Tool and Sound Recorder have settings of their own; Calculator, Photos, Notepad and the rest have none)
$script:Protect = @('Microsoft.DesktopAppInstaller',
    'Microsoft.WindowsCalculator', 'Microsoft.Windows.Photos', 'Microsoft.WindowsTerminal',
    'Microsoft.WindowsNotepad', 'Microsoft.Paint', 'Microsoft.WindowsCamera',
    'Microsoft.WindowsSoundRecorder', 'Microsoft.ScreenSketch', 'Microsoft.HEVCVideoExtension',
    'Microsoft.VP9VideoExtensions', 'Microsoft.WebMediaExtensions', 'Microsoft.WebpImageExtension',
    'Microsoft.HEIFImageExtension', 'Microsoft.RawImageExtension', 'Microsoft.SecHealthUI',
    'Microsoft.UI.Xaml*', 'Microsoft.VCLibs*', 'Microsoft.NET.Native*', 'Microsoft.WindowsAppRuntime*',
    'Microsoft.AV1VideoExtension', 'NVIDIACorp.NVIDIAControlPanel', 'AdvancedMicroDevicesInc*',
    'RealtekSemiconductorCorp*')
function Test-Protected { param([string]$name) foreach ($p in $script:Protect) { if ($name -like $p) { return $true } } return $false }
# A protected app is only touched when a setting names it exactly (no wildcard in the pattern); a wildcard never reaches it
function Appx-Allowed {
    param([string]$name, [string]$pat)
    if (-not (Test-Protected $name)) { return $true }
    return ($pat -notmatch '[*?]' -and $pat -ieq $name)
}
# The account of one entry of PackageUserInformation ("S-1-5-21-... [PC\name]: Installed"): its SID, '' when Windows does not name it
function Appx-UiSid {
    param($u)
    $s = ''
    try { $s = [string]$u.UserSecurityId.Sid } catch { }
    if ($s -notmatch '^S-1-') { try { $s = [string]$u.UserSecurityId } catch { $s = '' } }
    if ($s -notmatch '^S-1-') { $s = [regex]::Match([string]$u, 'S-1-[0-9-]+').Value }
    return $s
}
# Is a package (from Get-AppxPackage -AllUsers) installed for at least one user? "Staged" for every user = only the copy kept for new
# accounts is left. A copy that only Windows' own system account (S-1-5-18) has is installed for no one who signs in either: Windows
# keeps such a copy of some built-in packages for itself and puts it back when it is removed, so it counts as removed. Anything unclear
# counts as installed.
function Appx-IsLive {
    param($p)
    try {
        $ui = @($p.PackageUserInformation)
        if ($ui.Count -eq 0) { return $true }
        foreach ($u in $ui) { $s = ([string]$u.InstallState + ' ' + [string]$u); if ($s -notmatch 'Staged' -and $s -notmatch 'pending\s*removal' -and (Appx-UiSid $u) -ne 'S-1-5-18') { return $true } }
        return $false
    } catch { return $true }
}
# Does Windows' own system account (S-1-5-18) still have this package installed? (what the check of the PC does not count)
function Appx-IsSysKept {
    param($p)
    try {
        foreach ($u in @($p.PackageUserInformation)) { $s = ([string]$u.InstallState + ' ' + [string]$u); if ($s -notmatch 'Staged' -and $s -notmatch 'pending\s*removal' -and (Appx-UiSid $u) -eq 'S-1-5-18') { return $true } }
    } catch { }
    return $false
}
function Appx-Data {
    if (-not $script:Cache.ContainsKey('appx')) {
        $pk = @(); $pv = @()
        $preA = Pre-Wait 'appx'
        if ($null -ne $preA) {
            foreach ($p in $preA) { $pk += ,@{ Name = [string]$p.N; Full = [string]$p.F; NonRemovable = [bool]$p.R; Live = ($null -eq $p.L -or [bool]$p.L); Sys = [bool]$p.S } }
        } else {
            foreach ($p in @(Get-AppxPackage -AllUsers -ErrorAction Ignore)) { $pk += ,@{ Name = [string]$p.Name; Full = [string]$p.PackageFullName; NonRemovable = [bool]$p.NonRemovable; Live = (Appx-IsLive $p); Sys = (Appx-IsSysKept $p) } }
        }
        $preP = Pre-Wait 'prov'
        if ($null -ne $preP) {
            foreach ($p in $preP) { $pv += ,@{ Name = [string]$p.N; Pkg = [string]$p.P } }
        } else {
            foreach ($p in @(Get-AppxProvisionedPackage -Online -ErrorAction Ignore)) { $pv += ,@{ Name = [string]$p.DisplayName; Pkg = [string]$p.PackageName } }
        }
        $script:Cache['appx'] = @{ Pkgs = $pk; Prov = $pv }
    }
    return $script:Cache['appx']
}
# Removes one installed package from every account. "Remove-AppxPackage -AllUsers" is the usual way, but Windows refuses it for some
# apps (one that another program installed for a single account, such as Edge Game Assist, can have no all-users entry under its own
# name). Then the name of the bundle it came in is tried, then the current account, then each other account it is installed for.
# The app's own running processes are closed first. Returns '' when it is installed for nobody any more, else what Windows said.
function Appx-RemoveOne {
    param([string]$Full, [string]$Name)
    # a try that Windows refuses is expected (the next one may work), so its error is not left in $Error for the run to list: what
    # Windows said is returned when no try removed the app
    $n0 = $Error.Count
    $errs = @()
    Appx-StopApp $Full $Name
    $tries = @(@{ Pkg = $Full; All = $true; User = '' })
    foreach ($b in @(Appx-BundleNames $Name)) { if ($b -and $b -ne $Full) { $tries += ,@{ Pkg = $b; All = $true; User = '' } } }
    $tries += ,@{ Pkg = $Full; All = $false; User = '' }
    $me = ''; try { $me = [string][System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { }
    foreach ($sid in @(Appx-UserSids $Full)) { if ($sid -and $sid -ne $me) { $tries += ,@{ Pkg = $Full; All = $false; User = $sid } } }
    foreach ($t in $tries) {
        try {
            if ($t.All) { Remove-AppxPackage -Package $t.Pkg -AllUsers -ErrorAction Stop }
            elseif ($t.User) { Remove-AppxPackage -Package $t.Pkg -User $t.User -ErrorAction Stop }
            else { Remove-AppxPackage -Package $t.Pkg -ErrorAction Stop }
        } catch {
            $msg = ([string]$_.Exception.Message -split "`r?`n")[0].Trim()
            if ($msg -and $errs -notcontains $msg) { $errs += $msg }
        }
        if (-not (Appx-LiveFull $Full $Name)) { Drop-ErrorsSince $n0; return '' }
    }
    Drop-ErrorsSince $n0
    if ($errs.Count -eq 0) { return 'Windows reported no error, but it is still installed' }
    return (($errs | Select-Object -First 2) -join ' / ')
}
# Is this exact package's removal waiting for a restart? (it was in use: Windows shows it as "Installed(pending removal)")
function Appx-PendingFull {
    param([string]$Full, [string]$Name)
    foreach ($x in @(Get-AppxPackage -AllUsers -Name $Name -ErrorAction Ignore)) {
        if ([string]$x.PackageFullName -ne $Full) { continue }
        try { foreach ($u in @($x.PackageUserInformation)) { if (([string]$u.InstallState + ' ' + [string]$u) -match 'pending\s*removal') { return $true } } } catch { }
    }
    return $false
}
# Is this exact package still installed for an account? (only the copy kept for new accounts, or one whose removal waits for a restart,
# counts as removed, as in the check)
function Appx-LiveFull {
    param([string]$Full, [string]$Name)
    # a query Windows does not answer is no proof that the app is gone: it then counts as still installed
    $n0 = $Error.Count
    try { $all = @(Get-AppxPackage -AllUsers -Name $Name -ErrorAction Stop) } catch { Drop-ErrorsSince $n0; return $true }
    foreach ($x in $all) {
        if ([string]$x.PackageFullName -eq $Full -and (Appx-IsLive $x)) { return $true }
    }
    return $false
}
# The accounts an app is still installed for, as Windows lists them ("S-1-5-21-... [PC\name]: Installed"); a copy that is only kept for
# new accounts, or whose removal waits for a restart, is left out, and so is Windows' own system account. @() when it is installed for nobody.
function Appx-UserStates {
    param([string]$Full, [string]$Name)
    $o = @()
    $n0 = $Error.Count
    try {
        foreach ($x in @(Get-AppxPackage -AllUsers -Name $Name -ErrorAction Stop)) {
            if ([string]$x.PackageFullName -ne $Full) { continue }
            $ui = @($x.PackageUserInformation)
            if ($ui.Count -eq 0) { $o += 'an account Windows does not name: Installed'; continue }
            foreach ($u in $ui) {
                $s = ([string]$u.InstallState + ' ' + [string]$u)
                if ($s -match 'Staged' -or $s -match 'pending\s*removal') { continue }
                if ((Appx-UiSid $u) -eq 'S-1-5-18') { continue }          # (Windows' own system account: see Appx-IsLive)
                $t = ([string]$u).Trim(); if (-not $t) { $t = [string]$u.InstallState }
                if ($o -notcontains $t) { $o += $t }
            }
        }
    } catch { $o += ('Windows did not say: ' + (([string]$_.Exception.Message -split "`r?`n")[0])) }
    Drop-ErrorsSince $n0
    return $o
}
# The full names of the bundles an app was installed from (the name Windows sometimes wants for removing it)
function Appx-BundleNames {
    param([string]$Name)
    $o = @()
    foreach ($x in @(Get-AppxPackage -AllUsers -PackageTypeFilter Bundle -Name $Name -ErrorAction Ignore)) { $o += [string]$x.PackageFullName }
    return $o
}
# Windows' own processes, which are never closed (closing some of them stops Windows at once)
$script:CoreProcs = @('system', 'idle', 'smss', 'csrss', 'wininit', 'winlogon', 'services', 'lsass', 'lsaiso', 'svchost', 'dwm', 'explorer',
    'fontdrvhost', 'sihost', 'ctfmon', 'runtimebroker', 'searchhost', 'startmenuexperiencehost', 'shellexperiencehost', 'textinputhost',
    'memory compression', 'registry', 'secure system', 'audiodg', 'conhost', 'taskhostw', 'spoolsv')
# Is this an app's install folder of its own? (at least three folders deep, and not Windows', System32, SysWOW64, Program Files or a
# drive root: an app whose install folder Windows reports as one of those has no processes of its own to close)
function Appx-OwnFolder {
    param([string]$Root)
    $r = ([string]$Root).TrimEnd('\')
    if (@($r.Split('\') | Where-Object { $_ }).Count -lt 3) { return $false }
    $deny = @()
    foreach ($b in @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData)) {
        if ($b) { $deny += ([string]$b).TrimEnd('\') }
    }
    if ($env:SystemRoot) { $deny += (([string]$env:SystemRoot).TrimEnd('\') + '\System32'); $deny += (([string]$env:SystemRoot).TrimEnd('\') + '\SysWOW64'); $deny += (([string]$env:SystemRoot).TrimEnd('\') + '\SystemApps') }
    if ($env:ProgramFiles) { $deny += (([string]$env:ProgramFiles).TrimEnd('\') + '\WindowsApps') }
    foreach ($d in $deny) { if ($r -ieq $d) { return $false } }
    return $true
}
# Closes the app's own processes (those started from its install folder), so a running app does not hold up its removal
function Appx-StopApp {
    param([string]$Full, [string]$Name)
    $loc = ''
    foreach ($x in @(Get-AppxPackage -AllUsers -Name $Name -ErrorAction Ignore | Where-Object { $_.PackageFullName -eq $Full })) { if ($x.InstallLocation) { $loc = [string]$x.InstallLocation } }
    if (-not $loc) { return }
    $root = $loc.TrimEnd('\') + '\'
    if (-not (Appx-OwnFolder $root)) { return }
    $n0 = $Error.Count                   # (a process whose path Windows does not show, or that is already gone, is no problem)
    foreach ($pr in @(Get-Process -ErrorAction Ignore)) {
        if ($script:CoreProcs -contains ([string]$pr.ProcessName).ToLowerInvariant()) { continue }
        $path = ''; try { $path = [string]$pr.Path } catch { }
        if ($path -and $path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
            Say ('  closing {0} (it belongs to the app)' -f $pr.ProcessName) 'DarkGray'
            try { Stop-Process -Id $pr.Id -Force -ErrorAction Stop } catch { }
        }
    }
    Drop-ErrorsSince $n0
}
function Appx-Matches {
    param([string[]]$patterns)
    $d = Appx-Data
    $pk = @{}; $pv = @{}; $lv = @{}; $sy = @{}
    foreach ($pat in $patterns) {
        foreach ($p in $d.Pkgs) {
            if ($p.Name -like $pat -and -not $p.NonRemovable -and (Appx-Allowed $p.Name $pat)) { $pk[$p.Full] = $p.Name; $lv[$p.Full] = ($null -eq $p.Live -or [bool]$p.Live); $sy[$p.Full] = [bool]$p.Sys }
        }
        foreach ($p in $d.Prov) { if ($p.Name -like $pat -and (Appx-Allowed $p.Name $pat)) { $pv[$p.Pkg] = $p.Name } }
    }
    return @{ Pkgs = $pk; Prov = $pv; Live = $lv; Sys = $sy }
}

# -------------------------------------------------------- small helpers ------
function Fs-Exists { param([string]$p) return (Test-Path -LiteralPath $p) }
function Pwr { $o = & powercfg @args 2>&1; return (($o | Out-String).TrimEnd()) }
function Battery-Present { Scan-Memo 'battery' { [bool](Get-CimInstance -ClassName Win32_Battery -ErrorAction Ignore) } }
# Files in one folder:  @{ Name; Path }  (desktop.ini left out)
function Fs-Files {
    param([string]$Dir)
    $o = @()
    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir)) { return $o }
    foreach ($f in @(Get-ChildItem -LiteralPath $Dir -File -Force -ErrorAction Ignore)) {
        if ($f.Name -ieq 'desktop.ini') { continue }
        $o += ,@{ Name = [string]$f.Name; Path = [string]$f.FullName }
    }
    return $o
}
# Where a shortcut points ('' if it is not a shortcut or cannot be read)
function Lnk-Target {
    param([string]$Path)
    if ($Path -notmatch '\.lnk$') { return '' }
    try {
        $l = (New-Object -ComObject WScript.Shell).CreateShortcut($Path)
        return (([string]$l.TargetPath + ' ' + [string]$l.Arguments).Trim())
    } catch { return '' }
}
# The two Startup folders:  User / Common  ('' if Windows does not say)
function Startup-Dirs {
    $u = ''; $c = ''
    try { $u = [string][Environment]::GetFolderPath('Startup') } catch { }
    try { $c = [string][Environment]::GetFolderPath('CommonStartup') } catch { }
    return @{ User = $u; Common = $c }
}
# bcdedit (the boot configuration). $null when the boot store cannot be read or the change is refused; then $script:BcdSaid has what
# bcdedit said.
function Bcd {
    $script:BcdSaid = ''
    try { $o = & bcdedit @args 2>&1 } catch { $script:BcdSaid = (([string]$_.Exception.Message -split "`r?`n")[0]).Trim(); return $null }
    if ($LASTEXITCODE -ne 0) { $script:BcdSaid = (@($o | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ }) -join ' '); return $null }
    return (($o | Out-String).TrimEnd())
}
# Windows Security (Defender) scan preferences. $null when it is not there / not usable.
function Mp-Read {
    $m = $null
    try { $m = Get-MpPreference -ErrorAction Stop } catch { return $null }
    if (-not $m) { return $null }
    return @{ Idle = [bool]$m.ScanOnlyIfIdleEnabled; LowPri = [bool]$m.EnableLowCpuPriority; Cpu = [int]$m.ScanAvgCPULoadFactor }
}
function Mp-Write {
    param([bool]$Idle, [bool]$LowPri, [int]$Cpu)
    if ($DryRun) { return $true }
    try {
        Set-MpPreference -ScanOnlyIfIdleEnabled $Idle -EnableLowCpuPriority $LowPri -ScanAvgCPULoadFactor $Cpu -ErrorAction Stop
        return $true
    } catch {
        Say "  ! Windows Security did not accept the change: $($_.Exception.Message)" 'Yellow'
        return $false
    }
}
# BitLocker drive encryption. Bl-State: Ok = $false when BitLocker cannot be asked about on this PC (some editions of Windows have no BitLocker),
# else Ok = $true and Vols = one entry per drive letter: Mount, Type (OperatingSystem | Data | ...), Status (FullyEncrypted, FullyDecrypted, ...), Lock (Locked | Unlocked), Pct.
# Via says which tool answered ('Get-BitLockerVolume' or 'manage-bde').
function Bl-State {
    $v = $null
    if (Get-Command Get-BitLockerVolume -ErrorAction Ignore) {
        try { $v = @(Get-BitLockerVolume -ErrorAction Stop) } catch { $v = $null }
    }
    if ($null -ne $v) {
        $out = @()
        foreach ($x in $v) {
            $m = [string]$x.MountPoint
            if (-not $m) { continue }
            $out += ,@{ Mount = $m; Type = [string]$x.VolumeType; Status = [string]$x.VolumeStatus; Lock = [string]$x.LockStatus; Pct = [int]$x.EncryptionPercentage }
        }
        return @{ Ok = $true; Vols = $out; Via = 'Get-BitLockerVolume' }
    }
    # Windows Home has the "Device encryption" switch (the same encryption as BitLocker) and manage-bde.exe, but not always the PowerShell
    # BitLocker commands: ask manage-bde instead. Its text is read as English only; in any other language nothing is found and the
    # setting reads "not available" rather than guessing.
    $t = Bde '-status'
    if ($null -ne $t) {
        $vols = Bl-ParseManageBde $t
        if ($null -ne $vols) { return @{ Ok = $true; Vols = @($vols); Via = 'manage-bde' } }
    }
    return @{ Ok = $false; Vols = @(); Via = '' }
}
# manage-bde.exe. $null when it is not there or refuses.
function Bde {
    try { $o = & manage-bde @args 2>&1 } catch { return $null }
    if ($LASTEXITCODE -ne 0) { return $null }
    return (($o | Out-String).TrimEnd())
}
# The text of "manage-bde -status" (English) as the same list Bl-State makes, or $null when no drive can be found in it.
# Status is written the way Get-BitLockerVolume writes it: "Fully Encrypted" = FullyEncrypted, "Decryption in Progress" = DecryptionInProgress, ...
function Bl-ParseManageBde {
    param([string]$Text)
    $vols = @(); $cur = $null
    foreach ($line in (([string]$Text) -split "`r?`n")) {
        $m = [regex]::Match($line, '^\s*Volume\s+(\S+)')
        if ($m.Success) {
            if ($cur) { $vols += ,$cur }
            $cur = $null
            # only drives with a letter are listed (one without a letter is skipped, and its lines must not land on the drive before it)
            if ($m.Groups[1].Value -match '^[A-Za-z]:$') { $cur = @{ Mount = $m.Groups[1].Value.ToUpper(); Type = 'Data'; Status = ''; Lock = 'Unlocked'; Pct = 0 } }
            continue
        }
        if (-not $cur) { continue }
        if ($line -match '^\s*\[OS Volume\]') { $cur.Type = 'OperatingSystem'; continue }
        if ($line -match '^\s*\[Data Volume\]') { $cur.Type = 'Data'; continue }
        $kv = [regex]::Match($line, '^\s*([^:]+?):\s*(.*?)\s*$')
        if (-not $kv.Success) { continue }
        $k = $kv.Groups[1].Value.Trim(); $val = $kv.Groups[2].Value.Trim()
        if ($k -eq 'Conversion Status') { $cur.Status = ($val -replace '\s+', '') }
        elseif ($k -eq 'Percentage Encrypted') { $n = 0.0; if ([double]::TryParse(($val -replace '[%\s]', '' -replace ',', '.'), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) { $cur.Pct = [int][Math]::Round($n) } }
        elseif ($k -eq 'Lock Status') { if ($val -match '^Locked') { $cur.Lock = 'Locked' } else { $cur.Lock = 'Unlocked' } }
    }
    if ($cur) { $vols += ,$cur }
    $good = @($vols | Where-Object { $_.Status })
    if ($good.Count -eq 0) { return $null }
    return $good
}
# Start decrypting one drive. It carries on in the background and the drive stays usable. $true when it was started.
function Bl-Decrypt {
    param([string]$Mount)
    if ($DryRun) { return $true }
    if (Get-Command Disable-BitLocker -ErrorAction Ignore) {
        try { Disable-BitLocker -MountPoint $Mount -ErrorAction Stop | Out-Null; return $true }
        catch { Say "  ! $Mount could not be decrypted: $($_.Exception.Message)" 'Yellow'; return $false }
    }
    if ($null -ne (Bde '-off' $Mount)) { return $true }
    Say "  ! $Mount could not be decrypted (manage-bde -off was refused)" 'Yellow'
    return $false
}
function Test-UsesVirtualization {
    foreach ($f in 'VirtualMachinePlatform', 'Microsoft-Hyper-V-All', 'Containers-DisposableClientVM') { if ((Feat-State $f) -eq 'Enabled') { return $true } }
    return $false
}
function Ensure-Win32Ui {
    if ('Win32Ui' -as [type]) { return }
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class Win32Ui {
    [StructLayout(LayoutKind.Sequential)]
    public struct ANIMATIONINFO { public uint cbSize; public int iMinAnimate; }
    [DllImport("user32.dll", EntryPoint="SystemParametersInfo", SetLastError=true)]
    public static extern bool SpiPtr(uint action, uint param, IntPtr vparam, uint flags);
    [DllImport("user32.dll", EntryPoint="SystemParametersInfo", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern bool SpiStr(uint action, uint param, string vparam, uint flags);
    [DllImport("user32.dll", EntryPoint="SystemParametersInfo", SetLastError=true)]
    public static extern bool SpiAnim(uint action, uint param, ref ANIMATIONINFO vparam, uint flags);
    [DllImport("user32.dll", EntryPoint="SystemParametersInfo", SetLastError=true)]
    public static extern bool SpiInts(uint action, uint param, int[] vparam, uint flags);
    [DllImport("user32.dll", EntryPoint="SystemParametersInfo", SetLastError=true)]
    public static extern bool SpiGetInt(uint action, uint param, ref int vparam, uint flags);
    [DllImport("user32.dll")]
    public static extern bool SetSysColors(int count, int[] elements, int[] colors);
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYFLAGS { public uint cbSize; public uint dwFlags; }
    [StructLayout(LayoutKind.Sequential)]
    public struct FILTERFLAGS { public uint cbSize; public uint dwFlags; public uint iWaitMSec; public uint iDelayMSec; public uint iRepeatMSec; public uint iBounceMSec; }
    [DllImport("user32.dll", EntryPoint="SystemParametersInfo", SetLastError=true)]
    public static extern bool SpiKeys(uint action, uint param, ref KEYFLAGS vparam, uint flags);
    [DllImport("user32.dll", EntryPoint="SystemParametersInfo", SetLastError=true)]
    public static extern bool SpiFilter(uint action, uint param, ref FILTERFLAGS vparam, uint flags);
}
"@
}

# ------------------------------------------------------- catalog builders ----
# A setting ("tweak") is made of parts. Each part knows how to be detected, applied and undone.
function pReg    { param($Path, $Name, $Value, $Default = $null, [string]$Type = 'DWord') @{ T = 'reg'; Path = $Path; Name = $Name; Value = $Value; Default = $Default; Type = $Type } }
# A registry value that Windows protects on some builds: tried, but a refusal is not a failure and it never counts as "not applied"
function pRegSoft { param($Path, $Name, $Value, $Default = $null, [string]$Type = 'DWord') @{ T = 'reg'; Path = $Path; Name = $Name; Value = $Value; Default = $Default; Type = $Type; Soft = $true } }
function pRegDyn { param([scriptblock]$Gen, [string]$Info) @{ T = 'regdyn'; Gen = $Gen; Info = $Info } }
function pSvc    { param([string]$Name, [string]$Set, [string]$Default, [string]$SkipIf = '', [string]$SkipWhy = '') @{ T = 'svc'; Name = $Name; Set = $Set; Default = $Default; SkipIf = $SkipIf; SkipWhy = $SkipWhy } }
function pTask   { param([string]$Path) @{ T = 'task'; Path = $Path } }
# Scheduled tasks whose name starts with $Like inside one folder (for tasks that carry a changing id in their name).
# Turns into one pTask per task found, so it is a no-op on a PC that has none.
function pTaskDyn { param([string]$Folder, [string]$Like, [string]$Info) @{ T = 'taskdyn'; Folder = $Folder; Like = $Like; Info = $Info } }
function pFw     { param([string]$Group) @{ T = 'fw'; Group = $Group } }
function pBind   { param([string]$Comp) @{ T = 'bind'; Comp = $Comp } }
function pFeat   { param([string]$Name) @{ T = 'feat'; Name = $Name } }
function pCap    { param([string]$Pattern) @{ T = 'cap'; Pattern = $Pattern } }
function pAppx   { param([string[]]$Patterns) @{ T = 'appx'; Patterns = $Patterns } }
function pCustom { param([string]$Name, [string]$Info = '', $Data = $null) @{ T = 'custom'; Name = $Name; Info = $Info; Data = $Data } }
# "This registry key exists" = applied.  Undo deletes $Root (default: the key itself) with everything below it.
function pKey    { param([string]$Path, [string]$Root = '') @{ T = 'key'; Path = $Path; Root = $(if ($Root) { $Root } else { $Path }) } }
# Marks a part as one that is used only on some editions of Windows: pEd 'Ent' (pReg ...) is used on Enterprise and Education only,
# pEd 'Home,Pro' (pReg ...) on Home and Pro only. Classes: Home (Windows Home), Pro (Windows Pro) and Ent (Enterprise, Education and
# every other edition, and also a PC whose edition cannot be read, so that nothing is left out by mistake). On an edition that is not
# in the list the part is left out of everything: it is not read, not set and not undone. Use it only where Microsoft documents that
# an edition ignores the value; a value nobody has documented is left as it is.
function pEd     { param([string]$Only, $Part) $Part['Ed'] = @(($Only -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }); return $Part }

function Add-Tweak {
    # -Ask: a question the window (and an interactive console) puts to the user before this is turned on; if the answer is no
    # the setting is left alone. -AskTitle is its heading; settings with the same -AskGroup are asked about together.
    # -Unproven: the setting is harmless as far as is known, but it may not change anything on a PC (the description says why);
    # the card carries a "May do nothing" tag (on the "Placebo Tweaks - Not Recommended" page the page name says it, so the tag is not repeated).
    # -Untested: an idea taken from other debloat scripts that has not been checked for gaming. The card carries an "Untested" tag, and
    # "Apply all" and "Turn all on" leave it out wherever it is listed (you switch it on yourself).
    # -NotRec: a short reason why this script does not recommend switching the setting on. The card then shows "Not recommended" next
    # to its risk badge and the reason on hover and in the details. Every -Unproven setting counts as not recommended without it.
    param([string]$Id, [string]$Cat, [string]$Name, [string]$Desc, $Parts,
          [switch]$Preset, [switch]$OneWay, [switch]$Reboot, [switch]$Explorer, [switch]$Unproven, [switch]$Untested, [switch]$Once, [switch]$Cleanup, [switch]$Inv, [string]$Def = '', [string]$Risk = '', [int]$At = -1,
          [string]$Ask = '', [string]$AskTitle = '', [string]$AskGroup = '', [object[]]$Choices = @(), [string]$NotRec = '', [string]$Plan = '')
    # What the switch on the card shows is the state of the FEATURE: on = the feature is on, off = it is off (or, for a service, disabled).
    # -Inv: this setting's Apply turns the feature OFF (a debloat: "Windows diagnostic data" on = Windows default, Apply puts it off) and its
    #   Undo puts the Windows default back, so the switch is the opposite of "applied".  Without -Inv, Apply turns the feature on (Dark mode,
    #   Ultimate Performance power plan) and the switch follows "applied".
    # -Def: what the Windows default looks like on the switch: 'On' or 'Off' (without -Def: On for an -Inv setting, Off for the others),
    #   or a short text such as 'Depends on the PC' where it differs from PC to PC.  The card shows it as "Windows default: ...".
    # -Once: an action that is run when asked (a clean-up), not a switch. It is never "applied": it reads Off (Ready to run) every time,
    # keeps no undo record, has nothing to undo, and is never part of the Recommended preset, "Apply all" or "Turn all on".
    # Its custom part's Apply says what it did by setting $script:RunResult.
    # -Cleanup: a run-once action that deletes files (Disk Cleanup, Temporary files): the details and the question before it runs say
    # that what it deletes is gone for good. A run-once action without it changes something else (it puts a power plan back, for example).
    # -Plan: the setting is a power plan switch (the key of its plan in $script:PlanDefs, which is also the name of its custom part).
    # On = the plan is installed; Off = it is not. Its card shows whether it is the active plan and offers "Make active".
    # -Choices: instead of one on/off switch the setting offers options, shown as a selector on the card. The first entry is the
    # Windows default (Key 'default', no parts); each further entry is @{ Key; Label; Short; Parts } where Parts are pReg values.
    # The setting's own Parts are all the registry values of all options (one definition per value), so undo puts every one of them back.
    $t = @{ Id = $Id; Cat = $Cat; Name = $Name; Desc = $Desc; Parts = @($Parts); Preset = [bool]$Preset
            OneWay = [bool]$OneWay; Reboot = [bool]$Reboot; Explorer = [bool]$Explorer; Unproven = [bool]$Unproven; Untested = [bool]$Untested; Risk = $Risk
            Ask = $Ask; AskTitle = $AskTitle; AskGroup = $AskGroup; Choices = $null; Once = [bool]$Once; Cleanup = [bool]$Cleanup; NotRec = $NotRec.Trim(); Inv = [bool]$Inv; Def = '' }
    if ($Cleanup -and -not $Once) { throw "setting ${Id}: -Cleanup is for a run-once action" }
    if ($Ask -and -not $AskTitle) { throw "setting $Id has a question but no title for it" }
    if ($Untested -and ($Preset -or $Once)) { throw "setting ${Id}: an untested setting is never part of the Recommended preset and is not a run-once action" }
    if ($NotRec -and $Unproven) { throw "setting ${Id}: an unproven setting already counts as not recommended, so it takes no reason of its own" }
    if ($Inv -and ($Once -or $Choices.Count -gt 0)) { throw "setting ${Id}: -Inv is for a plain on/off switch (not a run-once action or a setting with options)" }
    if ($Once -and $Def) { throw "setting ${Id}: a run-once action has no Windows default" }
    if ($OneWay -and -not $Inv) { throw "setting ${Id}: a one-way setting takes something away, so its switch is -Inv" }
    if ($NotRec -and $Once) { throw "setting ${Id}: a run-once action is not a switch, so it cannot be marked not recommended" }
    if ($Once -and ($Preset -or $OneWay -or $Choices.Count -gt 0)) { throw "setting ${Id}: a run-once action cannot be in the Recommended preset, one-way or have options" }
    if ($Choices.Count -gt 0) {
        if ($Choices.Count -lt 2 -or [string]$Choices[0].Key -ne 'default' -or @($Choices[0].Parts).Count -ne 0) { throw "setting ${Id}: the first option must be the Windows default (Key 'default', no parts) and there must be one more" }
        if ($Preset -or $OneWay) { throw "setting ${Id}: a setting with options cannot be part of the Recommended preset or one-way" }
        $union = @{}; $parts = @(); $keys = @{}
        foreach ($c in $Choices) {
            $k = [string]$c.Key
            if (-not $k -or $keys.ContainsKey($k.ToLowerInvariant())) { throw "setting ${Id}: option key '$k' is empty or used twice" }
            $keys[$k.ToLowerInvariant()] = 1
            if (-not [string]$c.Label -or -not [string]$c.Short) { throw "setting ${Id}: option '$k' needs a Label and a Short label" }
            foreach ($p in @($c.Parts)) {
                if ([string]$p.T -ne 'reg') { throw "setting ${Id}: options are made of registry values only" }
                $vid = [string]$p.Path + '|' + [string]$p.Name
                if ($union.ContainsKey($vid)) {
                    if (-not (Reg-Equal $union[$vid].Value $p.Value $p.Type)) { throw "setting ${Id}: $vid has two different values in two options" }
                } else { $union[$vid] = $p; $parts += ,$p }
            }
        }
        $t.Choices = @($Choices)
        $t.Parts = @($parts)
    }
    foreach ($p in @($t.Parts)) {
        if ($null -eq $p.Ed) { continue }
        if ($t.Choices) { throw "setting ${Id}: options cannot be limited to an edition" }
        $eds = @($p.Ed)
        if ($eds.Count -eq 0 -or @($eds | Where-Object { $_ -notin 'Home', 'Pro', 'Ent' }).Count -gt 0) { throw "setting ${Id}: an edition list can only hold Home, Pro and Ent" }
    }
    $byVal = @{}
    foreach ($p in @($t.Parts)) {
        if ([string]$p.T -ne 'reg') { continue }
        $vid = [string]$p.Path + '|' + [string]$p.Name
        if ($byVal.ContainsKey($vid)) {
            $a = $byVal[$vid]
            $overlap = ($null -eq $a.Ed -or $null -eq $p.Ed -or @(@($a.Ed) | Where-Object { @($p.Ed) -contains $_ }).Count -gt 0)
            if ($overlap -and -not $t.Choices) { throw "setting ${Id}: $vid is set twice for the same edition" }
        } else { $byVal[$vid] = $p }
    }
    # the Windows default as the card shows it
    if ($Once) { $t.Def = '' }
    elseif ($Def) { $t.Def = $Def.Trim() }
    elseif ($t.Choices) { $t.Def = (([string]$Choices[0].Short) -replace '\s*\(default\)\s*$', '').Trim() }
    elseif ($Inv) { $t.Def = 'On' }
    else { $t.Def = 'Off' }
    if ($script:ById.ContainsKey($Id)) { throw "duplicate setting id: $Id" }
    if ($Plan) {
        if ($Once -or $Inv -or $Choices.Count -gt 0) { throw "setting ${Id}: a power plan switch is a plain switch (not run-once, -Inv or with options)" }
        if (@($t.Parts).Count -ne 1 -or [string]@($t.Parts)[0].T -ne 'custom' -or [string]@($t.Parts)[0].Name -ne $Plan) { throw "setting ${Id}: a power plan switch has one custom part named after its plan" }
    }
    $t.Plan = $Plan
    if ($At -ge 0 -and $At -le $script:Catalog.Count) { $script:Catalog.Insert($At, $t) } else { [void]$script:Catalog.Add($t) }
    $script:ById[$Id] = $t
}
# ---- the edition of Windows ----
# Home / Pro / Ent (see pEd). Read once from the registry (EditionID: "Core" is Home, "Professional" is Pro).
function Get-WinEdition {
    $m = $script:Cache['edition']
    if ($m) { return $m }
    $id = ''
    try { $r = Reg-Read 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'EditionID'; if ($r.Exists) { $id = ([string]$r.Value).Trim() } } catch { }
    $cls = 'Ent'
    if ($id -match '^core') { $cls = 'Home' }
    elseif ($id -match '^professional(n|workstation|workstationn)?$') { $cls = 'Pro' }
    $o = @{ Id = $id; Class = $cls }
    $script:Cache['edition'] = $o
    return $o
}
function Ed-Allows { param($Ed) return (@($Ed) -contains [string](Get-WinEdition).Class) }
function Ed-ClassName { param([string]$Class) switch ($Class) { 'Home' { return 'Windows Home' } 'Pro' { return 'Windows Pro' } default { return 'this edition of Windows' } } }
# why a part is left out on an edition that is not in its list
function Ed-Reason {
    param($Ed)
    $e = @($Ed)
    if ($e -contains 'Ent' -and $e -contains 'Pro') { return 'Windows only obeys it on Pro, Enterprise and Education' }
    if ($e -contains 'Ent') { return 'Windows only obeys it on Enterprise and Education' }
    if ($e -contains 'Pro' -and $e -contains 'Home') { return 'this value is for Windows Home and Pro; this edition uses the other one' }
    return 'it is not used on this edition'
}
# The parts of a setting that this edition leaves out, except those that have another part for the same value that this edition uses
function Get-GatedParts {
    param($t)
    $out = @()
    $used = @{}
    foreach ($p in $t.Parts) {
        if ([string]$p.T -eq 'reg' -and (-not $p.Ed -or (Ed-Allows $p.Ed))) { $used[[string]$p.Path + '|' + [string]$p.Name] = $true }
    }
    foreach ($p in $t.Parts) {
        if (-not $p.Ed -or (Ed-Allows $p.Ed)) { continue }
        if ([string]$p.T -eq 'reg' -and $used.ContainsKey([string]$p.Path + '|' + [string]$p.Name)) { continue }
        $out += ,$p
    }
    return $out
}
function Expand-Parts {
    param($t)
    $out = @()
    foreach ($p in $t.Parts) {
        if ($p.Ed -and -not (Ed-Allows $p.Ed)) { continue }
        if ($p.T -eq 'regdyn') { foreach ($e in @(& $p.Gen)) { $out += ,$e } }
        elseif ($p.T -eq 'taskdyn') { foreach ($full in @(Task-Match ([string]$p.Folder) ([string]$p.Like))) { $out += ,(pTask $full) } }
        else { $out += ,$p }
    }
    return $out
}

# --------------------------------------------------------------- detect ------
# What a check read from the PC, as short plain text (shown to the person as "Read from your PC")
function Now-Clip { param([string]$s, [int]$n = 70) if ($s.Length -gt $n) { return ($s.Substring(0, $n - 3) + '...') }; return $s }
function Now-RegText {
    param($c)
    if (-not $c.Exists) { return 'not set' }
    $v = $c.Value
    try {
        switch ([string]$c.Kind) {
            'DWord'       { return ('{0} (DWord)' -f ([uint32](([long]$v) -band 4294967295L))) }
            'QWord'       { return ('{0} (QWord)' -f [int64]$v) }
            'Binary'      {
                $b = @($v)
                $t = ((@($b | Select-Object -First 8 | ForEach-Object { '{0:X2}' -f [int]$_ })) -join ' ')
                if ($b.Count -gt 8) { $t += ' ...' }
                return ('{0} (Binary, {1} bytes)' -f $t, $b.Count)
            }
            'MultiString' { return ('"' + (Now-Clip ((@($v) -join ' | '))) + '" (MultiString)') }
            default       { return ('"' + (Now-Clip ([string]$v)) + '" (' + [string]$c.Kind + ')') }
        }
    } catch { return ('"' + (Now-Clip ([string]$v)) + '"') }
}
# Returns 'On' | 'Off' | 'Partial' | 'NA' (not applicable on this PC) | 'Skip' (no state of its own)
# and leaves in $script:Now what it read ("<where>: <what is there>, wanted <what the setting sets>")
function Get-PartState {
    param($p)
    $script:Now = ''
    switch ($p.T) {
        'reg' {
            $c = Reg-Read $p.Path $p.Name
            $script:Now = ('{0}\{1}: {2}, wanted {3}' -f $p.Path, $p.Name, (Now-RegText $c), (Now-RegText @{ Exists = $true; Value = $p.Value; Kind = [string]$p.Type }))
            if ($c.Exists -and $c.Kind -eq $p.Type -and (Reg-Equal $c.Value $p.Value $p.Type)) { return 'On' }
            if ($p.Soft) { return 'Skip' }          # a protected switch can show that a setting is on, never that it is off
            return 'Off'
        }
        'key' {
            $e = Reg-KeyExists $p.Path
            $script:Now = ('Key {0}: {1}' -f $p.Path, $(if ($e) { 'exists' } else { 'not there' }))
            if ($e) { return 'On' }
            return 'Off'
        }
        'svc' {
            if ($p.SkipIf -and (& $p.SkipIf)) { $script:Why = $p.SkipWhy; $script:Now = ('Service {0}: left alone ({1})' -f $p.Name, $p.SkipWhy); return 'NA' }
            $c = Svc-Read $p.Name
            if ($null -eq $c) { $script:Now = ('Service {0}: not on this PC' -f $p.Name); return 'NA' }
            $script:Now = ('Service {0}: {1}, wanted {2}' -f $p.Name, (Svc-Label $c), $p.Set)
            if (Svc-IsApplied $c $p) { return 'On' }
            return 'Off'
        }
        'task' {
            $c = Task-Read $p.Path
            if ($null -eq $c) { $script:Now = ('Task {0}: not on this PC' -f $p.Path); return 'NA' }
            $script:Now = ('Task {0}: {1}, wanted disabled' -f $p.Path, $(if ($c.Enabled) { 'enabled' } else { 'disabled' }))
            if ($c.Enabled) { return 'Off' }
            return 'On'
        }
        'fw' {
            $r = @(Fw-Rules $p.Group)
            if ($r.Count -eq 0) { $script:Now = ('Firewall rules "{0}": none on this PC' -f $p.Group); return 'NA' }
            $n = 0; foreach ($x in $r) { if ($x.Enabled) { $n++ } }
            $script:Now = ('Firewall rules "{0}": {1} of {2} switched on, wanted all off' -f $p.Group, $n, $r.Count)
            if ($n -gt 0) { return 'Off' }
            return 'On'
        }
        'bind' {
            $r = @(Bind-Read $p.Comp)
            if ($r.Count -eq 0) { $script:Now = ('Network adapter item {0}: no adapter has it' -f $p.Comp); return 'NA' }
            $n = 0; foreach ($x in $r) { if ($x.Enabled) { $n++ } }
            $script:Now = ('Network adapter item {0}: on for {1} of {2} adapter(s), wanted off' -f $p.Comp, $n, $r.Count)
            if ($n -gt 0) { return 'Off' }
            return 'On'
        }
        'feat' {
            $s = Feat-State $p.Name
            if (-not $s) { $script:Now = ('Windows feature {0}: not on this PC' -f $p.Name); return 'NA' }
            $script:Now = ('Windows feature {0}: {1}, wanted removed' -f $p.Name, $s)
            if ($s -eq 'Enabled') { return 'Off' }
            return 'On'
        }
        'cap' {
            $r = @(Cap-List $p.Pattern)
            if ($r.Count -eq 0) { $script:Now = ('Windows capability {0}: not on this PC' -f $p.Pattern); return 'NA' }
            $n = 0; foreach ($x in $r) { if ($x.State -eq 'Installed') { $n++ } }
            $script:Now = ('Windows capability {0}: {1} of {2} installed, wanted removed' -f $p.Pattern, $n, $r.Count)
            if ($n -gt 0) { return 'Off' }
            return 'On'
        }
        'appx' {
            $m = Appx-Matches $p.Patterns
            # Removed = installed for nobody. What stays behind after an uninstall from Start or Settings (the copy kept for new accounts) is not an
            # installed app: it is mentioned in the reading, and the setting counts as done.
            $inst = 0; $sysk = 0; foreach ($k in @($m.Pkgs.Keys)) { if ($m.Live[$k]) { $inst++ } elseif ($m.Sys -and $m.Sys[$k]) { $sysk++ } }
            $left = ($m.Pkgs.Count - $inst - $sysk) + $m.Prov.Count
            $script:Now = ('Apps {0}: {1} installed' -f ((@($p.Patterns) | ForEach-Object { [string]$_ }) -join ', '), $inst)
            if ($sysk -gt 0) { $script:Now += (', {0} kept only for Windows'' own system account (S-1-5-18, not for anyone who signs in)' -f $sysk) }
            if ($left -gt 0) { $script:Now += (', {0} only kept for new accounts (not installed for anyone)' -f $left) }
            $script:Now += ', wanted none installed'
            if ($inst -gt 0) { return 'Off' }
            return 'On'
        }
        'custom' {
            $res = @(& "Custom-$($p.Name)-Detect" $p)
            if ($res.Count -eq 0) { return 'Skip' }
            return [string]$res[$res.Count - 1]
        }
    }
    return 'Skip'
}
# ------------------------------------------------------------- choices -------
# A setting made with -Choices (see Add-Tweak). The options in order: the Windows default first, then the others.
function Get-ChoiceList { param($t) return @($t.Choices) }
function Get-ChoiceLabel {
    param($t, [string]$key)
    foreach ($c in @($t.Choices)) { if ([string]$c.Key -eq $key) { return [string]$c.Label } }
    return $key
}
# The option for a key; no key = the first option that changes something (the one -Apply without a choice means). Throws for an unknown key.
function Resolve-Choice {
    param($t, [string]$key = '')
    $list = @($t.Choices)
    if (-not $key) { return $list[1] }
    foreach ($c in $list) { if ([string]$c.Key -ieq $key) { return $c } }
    throw ("'{0}' is not an option of {1} (options: {2})" -f $key, $t.Id, ((@($list | ForEach-Object { [string]$_.Key })) -join ', '))
}
function Get-PartId { param($p) return ([string]$p.Path + '|' + [string]$p.Name) }
# Which option is in force: State 'On' + Choice = its key (an option that changes something), 'Off' + Choice 'default' (no value set), or
# 'Partial' (values that match no option, e.g. only one of the two set by hand)
function Get-ChoiceState {
    param($t)
    $script:CurTweak = $t
    $st = @{}
    $reads = New-Object System.Collections.ArrayList
    foreach ($p in (Expand-Parts $t)) {
        $script:Why = ''
        $st[(Get-PartId $p)] = (Get-PartState $p)
        if ($script:Now) { [void]$reads.Add([string]$script:Now) }
    }
    $rd = Join-Reads $reads
    $anyOn = $false
    foreach ($k in @($st.Keys)) { if ($st[$k] -eq 'On') { $anyOn = $true } }
    if (-not $anyOn) { return @{ State = 'Off'; Choice = 'default'; Read = $rd; Detail = 'Not applied (' + (Get-ChoiceLabel $t 'default') + ')' } }
    foreach ($c in @($t.Choices)) {
        if ([string]$c.Key -eq 'default') { continue }
        $mine = @{}
        foreach ($p in @($c.Parts)) { $mine[(Get-PartId $p)] = $true }
        $ok = $true
        foreach ($k in @($st.Keys)) {
            $on = ($st[$k] -eq 'On')
            if ($mine.ContainsKey($k)) { if (-not $on) { $ok = $false } } elseif ($on) { $ok = $false }
        }
        if ($ok) { return @{ State = 'On'; Choice = [string]$c.Key; Read = $rd; Detail = 'Applied: ' + [string]$c.Label } }
    }
    $n = 0; foreach ($k in @($st.Keys)) { if ($st[$k] -eq 'On') { $n++ } }
    return @{ State = 'Partial'; Choice = ''; Read = $rd; Detail = "Partly applied: $n of $($st.Count) values (they match none of the options)" }
}
# The lines a check read, as one text (one line per value; a long list is cut after 14 lines and says how many were left out)
function Join-Reads {
    param($lines)
    $l = @($lines | ForEach-Object { [string]$_ } | Where-Object { $_ })
    if ($l.Count -gt 14) { $l = @($l | Select-Object -First 14) + ('... and {0} more value(s)' -f ($lines.Count - 14)) }
    return ($l -join "`n")
}
# A unit counts as evidence that the setting was applied only if applying it really changes something
# from Windows' own default (a service that is Disabled out of the box, or firewall rules that are off
# out of the box, say nothing). Without this a brand-new PC would show half the list as "partly applied".
function Test-Informative {
    param($p)
    switch ($p.T) {
        'reg'   { if ($null -eq $p.Default) { return $true }; return (-not (Reg-Equal $p.Default $p.Value $p.Type)) }
        'svc'   { return ($p.Set -ne $p.Default) }
        'fw'    { return $false }
        'feat'  { return $false }
        'cap'   { return $false }
        'appx'  { return $false }
        default { return $true }
    }
}
function Get-TweakState {
    param($t)
    $script:CurTweak = $t
    if ($t.Choices) { return (Get-ChoiceState $t) }
    if (-not $t.Plan) { return (Get-PartsState $t) }
    # a power plan switch: Choice says whether it is the active plan ('active') or not ('')
    $script:PlanActive = $false
    $r = Get-PartsState $t
    $r.Choice = ''
    if ($script:PlanActive -and $r.State -eq 'On') { $r.Choice = 'active' }
    return $r
}
function Get-PartsState {
    param($t)
    $on = 0; $off = 0; $onI = 0; $na = 0; $why = @()
    $reads = New-Object System.Collections.ArrayList
    foreach ($p in (Expand-Parts $t)) {
        $script:Why = ''
        $r = Get-PartState $p
        if ($script:Now) { [void]$reads.Add([string]$script:Now) }
        switch ($r) {
            'On'      { $on++; if (Test-Informative $p) { $onI++ } }
            'Off'     { $off++ }
            'Partial' { $on++; $off++; $onI++ }
            'NA'      { $na++; if ($script:Why) { $why += $script:Why } }
        }
    }
    $note = ''; if ($why.Count) { $note = ' (' + (($why | Select-Object -Unique) -join '; ') + ')' }
    $gated = @(Get-GatedParts $t)
    $rd = Join-Reads $reads
    if ($on + $off -eq 0) {
        $d = 'Nothing to change on this PC'; if ($why.Count) { $d = ($why | Select-Object -First 1) }
        elseif ($gated.Count) { $d = (Ed-ClassName (Get-WinEdition).Class) + ' ignores this setting: ' + (Ed-Reason $gated[0].Ed) }
        if (-not $rd) { $rd = $d }          # nothing was read (every value is one this edition ignores): the reason is the reading
        return @{ State = 'NA'; Read = $rd; Detail = $d }
    }
    if ($gated.Count) {
        # one reason when every left-out value has the same one; otherwise the details window gives each value its own
        $gWhy = @($gated | ForEach-Object { Ed-Reason $_.Ed } | Select-Object -Unique)
        $gWhyText = 'the details give the reason for each'; if ($gWhy.Count -eq 1) { $gWhyText = [string]$gWhy[0] }
        $note += (' ({0} value{1} left out on {2}: {3})' -f $gated.Count, $(if ($gated.Count -gt 1) { 's' } else { '' }), (Ed-ClassName (Get-WinEdition).Class), $gWhyText)
    }
    if ($off -eq 0)  { return @{ State = 'On';  Read = $rd; Detail = 'Applied' + $note } }
    if ($onI -eq 0)  { return @{ State = 'Off'; Read = $rd; Detail = $(if ($t.Once) { 'Ready to run' } else { 'Not applied' }) + $note } }
    return @{ State = 'Partial'; Read = $rd; Detail = "Partly applied: $on of $($on + $off) parts" + $note }
}

# ------------------------------------------------------------ snapshot -------
function Take-Snapshot {
    param($t)
    $script:CurTweak = $t
    $snap = @{ When = (Get-Date -Format 's'); Reg = @{}; Svc = @{}; Task = @{}; Fw = @{}; Bind = @{}; Feat = @{}; Cap = @{}; Custom = @{} }
    foreach ($p in (Expand-Parts $t)) {
        switch ($p.T) {
            'reg' {
                $c = Reg-Read $p.Path $p.Name
                $already = ($c.Exists -and $c.Kind -eq $p.Type -and (Reg-Equal $c.Value $p.Value $p.Type))
                $snap.Reg["$($p.Path)|$($p.Name)"] = @{ Exists = $c.Exists; Value = $c.Value; Kind = $c.Kind; Unknown = $already }
            }
            'svc' {
                $c = Svc-Read $p.Name
                if ($null -ne $c) { $snap.Svc[$p.Name] = @{ Start = $c.Start; Delayed = $c.Delayed; Unknown = (Svc-IsApplied $c $p) } }
            }
            'task' {
                $c = Task-Read $p.Path
                if ($null -ne $c) { $snap.Task[$p.Path] = @{ Enabled = [bool]$c.Enabled } }
            }
            'fw' {
                $names = @(); foreach ($r in @(Fw-Rules $p.Group)) { if ($r.Enabled) { $names += $r.Name } }
                $snap.Fw[$p.Group] = $names
            }
            'bind' {
                $names = @(); foreach ($r in @(Bind-Read $p.Comp)) { if ($r.Enabled) { $names += $r.Name } }
                $snap.Bind[$p.Comp] = $names
            }
            'feat' { $snap.Feat[$p.Name] = [string](Feat-State $p.Name) }
            'cap'  { foreach ($c in @(Cap-List $p.Pattern)) { $snap.Cap[$c.Name] = $c.State } }
            'custom' {
                if (Get-Command "Custom-$($p.Name)-Snapshot" -ErrorAction Ignore) { $snap.Custom[$p.Name] = (& "Custom-$($p.Name)-Snapshot" $p) }
            }
        }
    }
    return $snap
}

# --------------------------------------------------------------- apply -------
function Apply-Part {
    param($p, $snap)
    switch ($p.T) {
        'reg' {
            $c = Reg-Read $p.Path $p.Name
            if ($c.Exists -and $c.Kind -eq $p.Type -and (Reg-Equal $c.Value $p.Value $p.Type)) { return }
            [void](Reg-Write $p.Path $p.Name $p.Value $p.Type -Soft:([bool]$p.Soft))
        }
        'key' { [void](Reg-KeyAdd $p.Path) }
        'svc' {
            if ($p.SkipIf -and (& $p.SkipIf)) { Say ("  service {0} left alone ({1})" -f $p.Name, $p.SkipWhy) 'Yellow'; return }
            $c = Svc-Read $p.Name
            if ($null -eq $c) { return }
            if (Svc-IsApplied $c $p) { return }
            Svc-Write $p.Name (Svc-Decode $p.Set)
        }
        'task' {
            $c = Task-Read $p.Path
            if ($null -eq $c -or -not $c.Enabled) { return }
            Task-Write $p.Path $false
        }
        'fw' {
            $r = @(Fw-Rules $p.Group)
            if ($r.Count -eq 0) { return }
            Fw-DisableGroup $p.Group
        }
        'bind' {
            foreach ($b in @(Bind-Read $p.Comp)) { if ($b.Enabled) { Bind-Set $b.Name $p.Comp $false } }
        }
        'feat' {
            if ((Feat-State $p.Name) -eq 'Enabled') { Feat-Set $p.Name $false }
        }
        'cap' {
            foreach ($c in @(Cap-List $p.Pattern)) { if ($c.State -eq 'Installed') { Cap-Set $c.Name $false } }
        }
        'appx' {
            $m = Appx-Matches $p.Patterns
            $fails = @()
            foreach ($k in @($m.Pkgs.Keys)) {
                Say "  removing app $($m.Pkgs[$k])" 'Gray'
                if ($DryRun) { continue }
                $why = Appx-RemoveOne $k ([string]$m.Pkgs[$k])
                if ($why) { $fails += ('{0}: {1}' -f $m.Pkgs[$k], $why); Say "  ! $($m.Pkgs[$k]) was not removed: $why" 'Yellow' }
                elseif (Appx-PendingFull $k ([string]$m.Pkgs[$k])) { Say '  Windows finishes removing it at the next restart (it is in use)' 'DarkGray' }
            }
            foreach ($k in $m.Prov.Keys) {
                if (-not $DryRun) { Remove-AppxProvisionedPackage -Online -PackageName $k -ErrorAction SilentlyContinue | Out-Null }
            }
            if ($DryRun -and ($m.Pkgs.Count + $m.Prov.Count) -eq 0) { Say '  (no matching apps installed)' 'DarkGray' }
            $script:Cache.Remove('appx')
            if ($fails.Count) { throw ('Windows did not remove ' + ($fails -join '; ')) }
        }
        'custom' {
            $mine = $null; if ($snap -and $snap.Custom) { $mine = $snap.Custom[$p.Name] }
            & "Custom-$($p.Name)-Apply" $p $mine
        }
    }
}
# Puts one value of a setting with options back: the Windows default (the value is removed, as Windows does not set it)
function Revert-ChoicePart {
    param($t, $p, $snap)
    Revert-Part $p $null
}
function Invoke-TweakApply {
    # $Choice: for a setting with options, the key of the option to set ('' = the first one that changes something)
    param($t, [string]$Choice = '')
    $script:CurTweak = $t
    if ($t.Once) {
        # an action, not a switch: it runs, and there is no snapshot or undo record
        foreach ($p in (Expand-Parts $t)) { Apply-Part $p $null }
        return
    }
    $c = $null
    if ($t.Choices) {
        $c = Resolve-Choice $t $Choice
        if ([string]$c.Key -eq 'default') { Invoke-TweakRevert $t; return }
    }
    $store = Get-Store
    $snap = $store[$t.Id]
    if (-not $snap) { $snap = Take-Snapshot $t; $store[$t.Id] = $snap; Save-Store $store }
    if ($c) {
        # this option's values are set; the values that only another option sets go back to the Windows default
        $mine = @{}
        foreach ($p in @($c.Parts)) { $mine[(Get-PartId $p)] = $true }
        foreach ($p in (Expand-Parts $t)) {
            if ($mine.ContainsKey((Get-PartId $p))) { Apply-Part $p $snap } else { Revert-ChoicePart $t $p $snap }
        }
    } else {
        foreach ($p in (Expand-Parts $t)) { Apply-Part $p $snap }
    }
    $store[$t.Id] = $snap
    Save-Store $store
}

# --------------------------------------------------------------- revert ------
function Revert-Part {
    param($p, $snap)
    switch ($p.T) {
        'reg' {
            # Switching a setting off puts the Windows default back, never the value the PC had before this app changed it:
            # a value that Windows does not set is deleted, one that Windows sets is written with its default.
            if ($null -eq $p.Default) {
                [void](Reg-Remove $p.Path $p.Name -Soft:([bool]$p.Soft))
            } else {
                [void](Reg-Write $p.Path $p.Name $p.Default $p.Type -Soft:([bool]$p.Soft))
            }
        }
        'key' { [void](Reg-KeyRemove $p.Root) }
        'svc' {
            if ($null -eq (Svc-Read $p.Name)) { return }
            Svc-Write $p.Name (Svc-Decode $p.Default)
        }
        'task' {
            # Windows ships these tasks switched on
            $c = Task-Read $p.Path
            if ($null -eq $c -or $c.Enabled) { return }
            Task-Write $p.Path $true
        }
        'fw' {
            # Windows keeps a list of its own firewall rules as they ship (the list "restore defaults" uses). Each built-in rule of the
            # group that ships switched on is switched on again; the ones that ship off stay off. Only when that list cannot be read are
            # the rules that were on when this app first changed the group used instead.
            $def = Fw-DefaultOn $p.Group
            if ($null -ne $def) {
                if ($def.Count) { Fw-EnableNames $p.Group $def } else { Say "  firewall group '$($p.Group)': Windows ships these rules switched off, so they stay off" 'DarkGray' }
            } elseif ($snap -and $snap.Fw -and $snap.Fw.ContainsKey($p.Group)) {
                $names = @($snap.Fw[$p.Group])
                if ($names.Count) { Fw-EnableNames $p.Group $names } else { Say "  firewall group '$($p.Group)': its rules were already off before, so they stay off" 'DarkGray' }
            } else {
                Say "  firewall group '$($p.Group)': Windows' list of its default rules could not be read and there is no record, so no rule was switched back on (Windows Security > Firewall can do it)" 'Yellow'
            }
        }
        'bind' {
            # Windows binds every adapter to these components: switch every one that is off back on
            foreach ($b in @(Bind-Read $p.Comp)) { if (-not $b.Enabled) { Bind-Set $b.Name $p.Comp $true } }
        }
        'feat' {
            $s = Feat-State $p.Name
            $was = ''; if ($snap -and $snap.Feat -and $snap.Feat.ContainsKey($p.Name)) { $was = [string]$snap.Feat[$p.Name] }
            # only add back what was really there before (a feature that was already off stays off)
            if ($s -and $s -ne 'Enabled' -and (-not $was -or $was -eq 'Enabled')) { Feat-Set $p.Name $true }
        }
        'cap' {
            foreach ($c in @(Cap-List $p.Pattern)) {
                if ($c.State -eq 'Installed') { continue }
                if ($snap -and $snap.Cap -and $snap.Cap.ContainsKey($c.Name) -and $snap.Cap[$c.Name] -ne 'Installed') { continue }
                Cap-Set $c.Name $true
            }
        }
        'appx' { Say '  (removed apps cannot be put back from here)' 'Yellow' }
        'custom' {
            $mine = $null; if ($snap -and $snap.Custom) { $mine = $snap.Custom[$p.Name] }
            & "Custom-$($p.Name)-Revert" $p $mine
        }
    }
}
function Invoke-TweakRevert {
    param($t)
    $script:CurTweak = $t
    $store = Get-Store
    $snap = $store[$t.Id]
    # The record is only consulted for what Windows has no fixed default for (see Revert-Part: optional features, Windows capabilities,
    # the firewall fallback) and for what this app created itself (a power plan); every value goes back to the Windows default.
    foreach ($p in (Expand-Parts $t)) { if ($t.Choices) { Revert-ChoicePart $t $p $snap } else { Revert-Part $p $snap } }
}
function Remove-Snapshot {
    param([string]$id)
    $store = Get-Store
    if ($store.ContainsKey($id)) { $store.Remove($id); Save-Store $store }
}
function Clear-CacheFor {
    param($t)
    foreach ($p in $t.Parts) {
        switch ($p.T) { 'appx' { $script:Cache.Remove('appx') } 'feat' { $script:Cache.Remove('feat') } 'cap' { $script:Cache.Remove('cap') } 'custom' { $script:Cache.Remove('usb'); $script:Cache.Remove('bl') } }
    }
}

# --------------------------------------------------------- describe ----------
# The "what exactly does this change" lines shown next to each setting.
function Describe-Tweak {
    param($t)
    $lines = @()
    if ($t.Choices) {
        $lines += ((Get-ChoiceLabel $t 'default') + ': none of the values below is set    (choosing it removes the values of the options below, which is how Windows ships)')
        foreach ($c in @($t.Choices)) {
            if ([string]$c.Key -eq 'default') { continue }
            $lines += ([string]$c.Label + ':')
            foreach ($p in @($c.Parts)) { $lines += ("  {0}\{1} = {2}" -f $p.Path, $p.Name, $p.Value) }
        }
        return $lines
    }
    foreach ($p in $t.Parts) {
        if ($p.Ed -and -not (Ed-Allows $p.Ed)) {
            if ([string]$p.T -eq 'reg') { $lines += ("{0}\{1} = {2}    [left out on {3}: {4}]" -f $p.Path, $p.Name, $p.Value, (Ed-ClassName (Get-WinEdition).Class), (Ed-Reason $p.Ed)) }
            continue
        }
        switch ($p.T) {
            'reg'    { $d = 'delete'; if ($null -ne $p.Default) { $d = [string]$p.Default }; $sf = ''; if ($p.Soft) { $sf = '    [tried; some Windows 11 builds protect this one]' }; $lines += ("{0}\{1} = {2}    (undo: {3}){4}" -f $p.Path, $p.Name, $p.Value, $d, $sf) }
            'regdyn' { $lines += $p.Info }
            'key'    { $lines += ("registry key {0}: created    (undo: {1} deleted)" -f $p.Path, $p.Root) }
            'svc'    { $lines += ("service {0}: {1}    (undo: {2})" -f $p.Name, $p.Set, $p.Default) }
            'task'   { $lines += ("scheduled task {0}: off" -f $p.Path) }
            'taskdyn' { $lines += $p.Info }
            'fw'     { $lines += ("firewall rules '{0}': off" -f $p.Group) }
            'bind'   { $lines += ("network adapter component {0}: unbound" -f $p.Comp) }
            'feat'   { $lines += ("Windows feature {0}: removed" -f $p.Name) }
            'cap'    { $lines += ("Windows capability {0}: removed" -f $p.Pattern) }
            'appx'   { foreach ($x in $p.Patterns) { $lines += ("app {0}: removed" -f $x) } }
            'custom' { if ($p.Info) { $lines += $p.Info } }
        }
    }
    return $lines
}

# ---------------------------------------------------------- restore point ----
# The highest restore point number Windows has, 0 when it has none, $null when it cannot be asked
function Rp-Last {
    try {
        $m = 0
        foreach ($x in @(Get-ComputerRestorePoint -ErrorAction Stop)) { if ([int]$x.SequenceNumber -gt $m) { $m = [int]$x.SequenceNumber } }
        return $m
    } catch { return $null }
}
function New-RestorePoint {
    if ($DryRun) { Say 'Restore point: [dry] would create "Before Headroom changes"' 'DarkGray'; return }
    Say 'Creating a restore point first (can take a minute)...' 'Gray'
    $k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $old = Reg-Read $k 'SystemRestorePointCreationFrequency'
    Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue | Out-Null
    # Windows allows one restore point per 24 h by default; lift that for this moment only
    [void](Reg-Write $k 'SystemRestorePointCreationFrequency' 0 'DWord' -Quiet)
    $before = Rp-Last
    Checkpoint-Computer -Description 'Before Headroom changes' -RestorePointType MODIFY_SETTINGS -ErrorAction SilentlyContinue
    $after = Rp-Last
    if ($old.Exists) { [void](Reg-Write $k 'SystemRestorePointCreationFrequency' $old.Value 'DWord' -Quiet) }
    else { [void](Reg-Remove $k 'SystemRestorePointCreationFrequency' -Quiet) }
    # Windows says nothing when it declines (System Restore switched off by a policy or by other software): look, and tell
    if ($null -ne $before -and $null -ne $after) {
        if ($after -gt $before) { Say '  restore point created' 'DarkGray' }
        else { Say '  ! Windows did not create a restore point (System Restore may be switched off by a policy or by other software). The changes go ahead; every setting still keeps its own undo record.' 'Yellow' }
    }
}

# ---------------------------------------------------------------- scan -------
# How long a setting's check is likely to take, so the quick ones are shown first and the ones that wait for a
# slow Windows question come last:  0 registry / services,  1 other custom checks,  2 firewall / tasks / adapters,
# 3 apps and USB,  4 optional features,  5 capabilities
$script:ScanHeavyCustom = @{ UsbPower = 3; NicTurnOff = 2; NicEee = 2; NicSuspend = 2; PlanBalanced = 1; PlanHighPerf = 1; Ultimate = 1; UltimateMod = 1; Khorvie = 1; LowLatency = 1 }
function Get-ScanWeight {
    param($t)
    $w = 0
    foreach ($p in $t.Parts) {
        $x = 0
        switch ($p.T) {
            'regdyn' { $x = 1 }
            'custom' { $x = 1; if ($script:ScanHeavyCustom.ContainsKey([string]$p.Name)) { $x = $script:ScanHeavyCustom[[string]$p.Name] } }
            'task'   { $x = 2 }
            'taskdyn' { $x = 2 }
            'fw'     { $x = 2 }
            'bind'   { $x = 2 }
            'appx'   { $x = 3 }
            'feat'   { $x = 4 }
            'cap'    { $x = 5 }
        }
        if ($x -gt $w) { $w = $x }
    }
    return $w
}
function Get-ScanOrder {
    $w = @{}
    foreach ($t in $script:Catalog) { $w[$t.Id] = Get-ScanWeight $t }
    $order = New-Object System.Collections.ArrayList
    for ($k = 0; $k -le 5; $k++) {
        foreach ($t in $script:Catalog) { if ($w[$t.Id] -eq $k) { [void]$order.Add($t) } }
    }
    return $order
}
# 'yes' when the setting is applied and this app has an undo record for it (the app changed it), 'no' when it is applied but there is
# no record (it was already like this when the app first looked, or it was set by hand), '' for any other state
function Get-MineText {
    param([string]$State, $Store, [string]$Id)
    if ($State -ne 'On') { return '' }
    if ($Store -and $Store.ContainsKey($Id)) { return 'yes' }
    return 'no'
}
function Invoke-Scan {
    $ErrorActionPreference = 'SilentlyContinue'
    $ProgressPreference = 'SilentlyContinue'
    $script:Cache = @{}
    $n = $script:Catalog.Count; $i = 0
    $store = Get-Store          # once: it is read from disk on every call; tells which settings this app has changed itself
    $script:ScanMode = $true
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $lastWait = ''
    try {
        Start-Prefetch
        # The settings are taken in quick-first order, but one whose slow answer has not arrived yet is left for later:
        # nothing waits behind a slow question that it does not need itself.
        $pending = New-Object System.Collections.ArrayList
        foreach ($t in (Get-ScanOrder)) { [void]$pending.Add($t) }
        $moved = 0.0
        while ($pending.Count -gt 0) {
            if (Pre-Note) { $moved = $clock.Elapsed.TotalSeconds }
            $pick = -1
            for ($k = 0; $k -lt $pending.Count; $k++) {
                if (Pre-Ready @(Get-TweakNeeds $pending[$k])) { $pick = $k; break }
            }
            if ($pick -lt 0) {
                $missing = @(Pre-Missing $pending)
                if ($missing.Count -eq 0) { $pick = 0 }
                else {
                    $text = (@($missing | ForEach-Object { $script:PreLabels[[string]$_] } | Select-Object -Unique) -join ', ')
                    if ($text -ne $lastWait) { $lastWait = $text; Emit 'wait' '' '' '' $text 'Gray' 0 0 }
                    $idle = $clock.Elapsed.TotalSeconds - $moved
                    $gave = $false
                    foreach ($nm in $missing) {
                        $limit = $script:PreStall
                        if (@('feat', 'prov', 'cap') -contains $nm) { $limit = $script:PreStallDism }
                        if ($idle -gt $limit) {
                            $script:PreGiven[$nm] = 1
                            $gave = $true
                            Say ('  Windows has not answered for {0:N0} s: {1}. Asking it directly instead.' -f $idle, $script:PreLabels[$nm]) 'Yellow'
                        }
                    }
                    if (-not $gave) { Start-Sleep -Milliseconds 40 }
                    continue
                }
            }
            if ($lastWait) { $lastWait = ''; Emit 'wait' '' '' '' '' 'Gray' 0 0 }
            $t = $pending[$pick]
            $pending.RemoveAt($pick)
            $i++
            $r = $null
            try { $r = Get-TweakState $t } catch { $r = @{ State = 'Unknown'; Detail = "Could not check: $($_.Exception.Message)" } }
            Emit 'state' $t.Id $r.State $r.Detail '' 'Gray' $i $n ([string]$r.Choice) ([string]$r.Read) (Get-MineText $r.State $store $t.Id)
            $moved = $clock.Elapsed.TotalSeconds
        }
        [void](Pre-Note)
        if ($null -ne $Q) { Say ('  Check of the PC finished in {0:N1} s' -f $clock.Elapsed.TotalSeconds) 'DarkGray' }
    } finally {
        $script:ScanMode = $false
        Stop-Prefetch
    }
    if ($lastWait) { Emit 'wait' '' '' '' '' 'Gray' 0 0 }
    Emit 'scandone' '' '' '' '' 'Gray' $n $n
}

# ---------------------------------------------------------------- the switch -------
# A setting is "applied" (State On) when this app's change is in place. The switch on the card shows the FEATURE: for an -Inv setting
# (Apply turns the feature off) the switch is on while the setting is NOT applied; for the others it is on while the setting is applied.
function Get-SwitchOn {
    param($t, [bool]$applied)
    return ($applied -ne [bool]$t.Inv)
}
# Does the switch go on when this action is done? ($undo = the action is Undo)
function Get-SwitchGoesOn {
    param($t, [bool]$undo)
    return ((-not $undo) -ne [bool]$t.Inv)
}
# ---------------------------------------------------------------- plan -------
# $Plan = array of @{ Id = '...'; Action = 'Apply' | 'Undo' }
function Invoke-Plan {
    param($Plan)
    $ErrorActionPreference = 'SilentlyContinue'
    $ProgressPreference = 'SilentlyContinue'
    $Plan = @($Plan)
    $total = $Plan.Count
    $mode = 'for real'; if ($DryRun) { $mode = 'DRY RUN - nothing is changed' }
    Say ("`n=== {0}: {1} change(s), {2} ===" -f (Get-Date -Format 'HH:mm:ss'), $total, $mode) 'Cyan'
    if ($script:InRdp) { Say 'You are connected through Remote Desktop: its services are switched off for the next boot but not stopped now.' 'Yellow' }
    # a restore point is for changes it can bring back: a plan of clean-up actions only does not get one (deleted files are not in it),
    # and neither does making a power plan the active one (another click switches back)
    $needRp = $false; foreach ($pi in $Plan) { $pt = $script:ById[[string]$pi.Id]; if ($pt -and -not $pt.Cleanup -and [string]$pi.Action -ne 'Activate') { $needRp = $true } }
    if (-not $DryRun -and $total -gt 0 -and $needRp) { New-RestorePoint }
    $i = 0; $good = 0; $bad = 0; $reboot = @(); $explorer = $false
    foreach ($item in $Plan) {
        $i++
        $t = $script:ById[[string]$item.Id]
        if (-not $t) { Say "  unknown setting '$($item.Id)'" 'Red'; $bad++; continue }
        $undo = ($item.Action -eq 'Undo')
        $activate = ($item.Action -eq 'Activate')
        $reinstall = ($item.Action -eq 'Reinstall')
        # the verb says what the SWITCH does: an -Inv setting that is applied turns its feature off, and undone turns it back on
        $verb = 'Turning on'; if (-not (Get-SwitchGoesOn $t $undo)) { $verb = 'Turning off' }
        if ($t.Once) { $verb = 'Running' }
        if ($t.Plan) { if ($undo) { $verb = 'Deleting' } else { $verb = 'Installing' } }
        if ($activate) { $verb = 'Making active' }
        if ($reinstall) { $verb = 'Reinstalling' }
        $failed = $null
        # a setting with options: the one to set (the plan item names it; none named = the first that changes something)
        $choiceKey = ''
        $shown = [string]$t.Name
        if ($t.Choices -and -not $undo) {
            try {
                $cc = Resolve-Choice $t ([string]$item.Choice)
                $choiceKey = [string]$cc.Key
                $verb = 'Setting'; $shown = ('{0} to {1}' -f $t.Name, $cc.Label)
            } catch { $failed = $_.Exception.Message }
        }
        Emit 'item' $t.Id 'running' '' '' 'Cyan' $i $total
        Say ("`n[{0}/{1}] {2}: {3}" -f $i, $total, $verb, $shown) 'Cyan'
        $Error.Clear()
        if ($failed) {
            # nothing to do: the failure is reported below
        } elseif ($activate) {
            if (-not $t.Plan) { $failed = 'only a power plan can be made the active plan' }
            else {
                try {
                    $script:RunResult = ''
                    $s0 = (Get-Store)[[string]$t.Id]; $mine = $null; if ($s0 -and $s0.Custom) { $mine = $s0.Custom[[string]$t.Plan] }
                    Plan-Activate ([string]$t.Plan) $mine
                } catch { $failed = $_.Exception.Message }
            }
        } elseif ($reinstall) {
            if (-not $t.Plan) { $failed = 'only a power plan can be reinstalled' }
            else {
                try { $script:RunResult = ''; Plan-Reinstall $t } catch { $failed = $_.Exception.Message }
            }
        } elseif ($undo -and $t.Once) {
            $failed = 'it is a one-time action: there is nothing to undo'
        } elseif ($t.Once -and (Get-TweakState $t).State -eq 'NA') {
            $failed = ('not available on this PC: ' + [string](Get-TweakState $t).Detail)
        } elseif ($undo -and $t.OneWay) {
            $failed = 'cannot be undone from here'
        } elseif ($undo -and -not (Get-Store).ContainsKey([string]$t.Id) -and (Get-TweakState $t).State -eq 'Off') {
            # not applied by this app and not applied now (switched off by hand since the list was made): nothing to put back, and writing
            # Windows' defaults over your own values would only do harm.  (With an undo record the setting always goes through the undo.)
            Say '  not applied - nothing to put back' 'DarkGray'
        } else {
            try {
                $script:RunResult = ''
                if ($undo) { Invoke-TweakRevert $t } else { Invoke-TweakApply $t $choiceKey }
            } catch { $failed = $_.Exception.Message }
        }
        $errs = @($Error | ForEach-Object { $_.Exception.Message } | Select-Object -Unique | Select-Object -First 5)
        $Error.Clear()
        foreach ($m in $errs) { Say "  ! $m" 'Yellow' }
        Clear-CacheFor $t
        $after = Get-TweakState $t
        if ($failed) {
            Say "  FAILED: $failed" 'Red'; $bad++
            Emit 'item' $t.Id 'failed' $failed '' 'Red' $i $total
        } elseif ($DryRun) {
            Emit 'item' $t.Id 'dry' 'Preview only' '' 'Gray' $i $total
            $good++
        } elseif ($t.Once -or $activate -or $reinstall) {
            # a run-once action reads "ready to run" before and after (and making a plan active leaves the switch as it was): it
            # succeeded when nothing went wrong, and says what it did
            $res = [string]$script:RunResult
            if ($res) { Say ('  done: ' + $res) 'Green' } else { Say '  done' 'Green' }
            $good++
            Emit 'item' $t.Id 'done' $res '' 'Green' $i $total
        } elseif ($after.State -eq 'NA' -or ($undo -and $after.State -ne 'On') -or (-not $undo -and $after.State -eq 'On' -and (-not $choiceKey -or [string]$after.Choice -eq $choiceKey))) {
            Say '  done' 'Green'; $good++
            if ($undo) { Remove-Snapshot $t.Id }
            if ($t.Reboot) { $reboot += $t.Name }
            if ($t.Explorer) { $explorer = $true }
            Emit 'item' $t.Id 'done' $after.Detail '' 'Green' $i $total
        } else {
            Say ("  finished, but Windows still reports it as: {0}" -f $after.Detail) 'Yellow'; $bad++
            if ($t.Reboot) { $reboot += $t.Name }
            Emit 'item' $t.Id 'failed' ('Still shows as: ' + $after.Detail) '' 'Yellow' $i $total
        }
        Emit 'state' $t.Id $after.State $after.Detail '' 'Gray' $i $total ([string]$after.Choice) ([string]$after.Read) (Get-MineText $after.State (Get-Store) $t.Id)
        # a power plan was installed, deleted or made active: which plan is active may have changed, so every plan switch is read again
        if ($t.Plan) {
            foreach ($o in @($script:Catalog | Where-Object { $_.Plan -and $_.Id -ne $t.Id })) {
                Clear-CacheFor $o
                $oa = Get-TweakState $o
                Emit 'state' $o.Id $oa.State $oa.Detail '' 'Gray' $i $total ([string]$oa.Choice) ([string]$oa.Read) (Get-MineText $oa.State (Get-Store) $o.Id)
            }
        }
    }
    if ($explorer -and -not $DryRun) {
        # Windows starts Explorer again by itself (AutoRestartShell = 1, its default). Where that is switched off, Explorer is not closed: the
        # desktop and the taskbar would stay gone until the next sign-in.
        $ars = Reg-Read 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' 'AutoRestartShell'
        if ($ars.Exists -and ([string]$ars.Value).Trim() -eq '0') {
            Say "`nExplorer is not restarted here (Windows is set not to start it again by itself): sign out and in to see the taskbar and theme changes." 'Yellow'
        } else {
            Say "`nRestarting Explorer so the taskbar and theme changes show up..." 'Gray'
            Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        }
    }
    $tail = "{0} done, {1} need attention." -f $good, $bad
    if ($DryRun) { $tail = "Preview finished - nothing was changed. ($total setting(s) checked)" }
    $col = 'Green'; if ($bad) { $col = 'Yellow' }
    Say "`n$tail" $col
    if ($reboot.Count -and -not $DryRun) { Say ('Restart the PC for these to fully apply: ' + ((($reboot | Select-Object -Unique)) -join ', ')) 'Yellow' }
    Say "Log: $log" 'DarkGray'
    Emit 'finished' '' '' $tail ((($reboot | Select-Object -Unique)) -join ', ') $col $good $bad
    return [pscustomobject]@{ Good = $good; Bad = $bad }
}

# =============================================================================
# Parts that need their own code. Each has  Custom-<Name>-Detect / -Snapshot / -Apply / -Revert.
# (Snapshot is optional. 'Skip' from Detect means "no state of its own".)
# =============================================================================
function Count-State {
    param([int]$on, [int]$off)
    if ($on + $off -eq 0) { return 'NA' }
    if ($off -eq 0) { return 'On' }
    if ($on -eq 0)  { return 'Off' }
    return 'Partial'
}

# ------------------------------------------------------------- OneDrive ------
function Custom-OneDrive-Detect {
    param($p)
    foreach ($f in @("$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe", "$env:ProgramFiles\Microsoft OneDrive\OneDrive.exe", "${env:ProgramFiles(x86)}\Microsoft OneDrive\OneDrive.exe")) {
        if (Fs-Exists $f) { $script:Now = ('OneDrive program found at {0}, wanted uninstalled' -f $f); return 'Off' }
    }
    $script:Now = 'OneDrive program: not found where it is normally installed, wanted uninstalled'
    return 'On'
}
function Custom-OneDrive-Apply {
    param($p, $mine)
    if ($DryRun) { Say '  [dry] stop OneDrive, run OneDriveSetup /uninstall, delete leftovers' 'DarkGray'; return }
    Say '  stopping and uninstalling OneDrive...' 'Gray'
    Stop-Process -Name OneDrive -Force -ErrorAction Ignore
    Stop-Process -Name OneDriveSetup -Force -ErrorAction Ignore
    $setup = $null
    foreach ($f in @("$env:SystemRoot\SysWOW64\OneDriveSetup.exe", "$env:SystemRoot\System32\OneDriveSetup.exe")) { if (-not $setup -and (Fs-Exists $f)) { $setup = $f } }
    if ($setup) { Start-Process $setup -ArgumentList '/uninstall' -Wait -ErrorAction SilentlyContinue }
    # Leftovers: OneDrive's own folders only. A folder variable that is not set is skipped (never read as the root of the drive), and
    # the paths are taken as written (a [ or ] in a user name is not read as a wildcard that could match another folder).
    foreach ($d in @(@([string]$env:LOCALAPPDATA, 'Microsoft\OneDrive'), @([string]$env:ProgramData, 'Microsoft OneDrive'), @([string]$env:SystemDrive, 'OneDriveTemp'))) {
        $base = ([string]$d[0]).Trim().TrimEnd('\')
        if ($base.Length -lt 2) { continue }
        $path = $base + '\' + [string]$d[1]
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Ignore }
    }
    $od = ''; if (([string]$env:USERPROFILE).Trim().Length -ge 3) { $od = ([string]$env:USERPROFILE).Trim().TrimEnd('\') + '\OneDrive' }
    if ($od -and (Fs-Exists $od)) {
        if (-not (Get-ChildItem -LiteralPath $od -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) { Remove-Item -LiteralPath $od -Force -ErrorAction SilentlyContinue }
        else { Say "  NOTE: $od still has files in it - left alone. Move them out and delete it yourself." 'Yellow' }
    }
    [void](Reg-Remove 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' 'OneDrive')
}

# --------------------------------------------------------- power plans -------
$script:GuidRx = '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}'
$script:UltimateTemplate = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
$script:HighPerfTemplate = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$script:BalancedTemplate = '381b4222-f694-41f0-9685-ff5bb260df2e'
$script:SaverTemplate    = 'a1841308-3541-4fab-bc81-f71556f20b4a'
function Pwr-Active {
    $o = Pwr '/getactivescheme'
    $g = [regex]::Match($o, $script:GuidRx).Value.ToLower()
    $n = ''; $m = [regex]::Match($o, '\((.+)\)'); if ($m.Success) { $n = $m.Groups[1].Value }
    return @{ Guid = $g; Name = $n }
}
function Pwr-Plans {
    $out = @()
    foreach ($line in ((Pwr '/list') -split "`r?`n")) {
        $g = [regex]::Match($line, $script:GuidRx).Value
        if (-not $g) { continue }
        $n = ''; $m = [regex]::Match($line, '\((.+?)\)'); if ($m.Success) { $n = $m.Groups[1].Value }
        $out += ,@{ Guid = $g.ToLower(); Name = $n; Active = ($line.TrimEnd() -match '\*$') }
    }
    return $out
}
function Pwr-NewFrom {
    param([string]$template)
    $out = Pwr '/duplicatescheme' $template
    return [regex]::Match($out, $script:GuidRx).Value.ToLower()
}

# Plan-Find: the plan with this ID, or $null.  Pwr-Restore: makes a standard plan from Windows' own definition under its usual ID
# ("powercfg /duplicatescheme <id> <id>" when no plan has that ID); returns the ID, or '' when Windows did not make it.
function Plan-Find { param([string]$Guid) foreach ($x in @(Pwr-Plans)) { if ($x.Guid -eq $Guid) { return $x } }; return $null }
function Pwr-Restore {
    param([string]$Guid)
    [void](Pwr '/duplicatescheme' $Guid $Guid)
    if (Plan-Find $Guid) { return $Guid }
    return ''
}
# Windows' own default values of one of its standard plans, the ones its "restore plan defaults" uses:
# HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\<subgroup>\<setting>\DefaultPowerSchemeValues\<plan ID> (ACSettingIndex,
# DCSettingIndex); a setting that belongs to no subgroup sits directly under PowerSettings. Only reads. @(@{ Sub; Set; AC; DC }).
$script:PowerSettingsKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerSettings'
# A registry number as the unsigned 32-bit index powercfg uses: a DWORD of 0xFFFFFFFF reads as -1 in PowerShell and is 4294967295 here
# (the literal 0xffffffff is itself -1 in PowerShell, so the mask is written out). $null when it is no number.
function Pwr-U32 {
    param($v)
    if ($null -eq $v) { return $null }
    if ($v -is [byte[]]) { if ($v.Length -ge 4) { return [int64][BitConverter]::ToUInt32($v, 0) }; return $null }
    $n = [int64]0
    if (-not [int64]::TryParse([string]$v, [ref]$n)) { return $null }
    return ($n -band [int64]4294967295)
}
function Plan-DefaultsAt {
    param([string]$Key, [string]$Guid)
    $p = $Key + '\DefaultPowerSchemeValues\' + $Guid
    $ac = Reg-Read $p 'ACSettingIndex'; $dc = Reg-Read $p 'DCSettingIndex'
    if (-not $ac.Exists -and -not $dc.Exists) { return $null }
    $o = @{ AC = $null; DC = $null }
    if ($ac.Exists) { $o.AC = Pwr-U32 $ac.Value }
    if ($dc.Exists) { $o.DC = Pwr-U32 $dc.Value }
    if ($null -eq $o.AC -and $null -eq $o.DC) { return $null }
    return $o
}
function Plan-WindowsDefaults {
    param([string]$Guid)
    $out = @()
    $root = $script:PowerSettingsKey
    foreach ($k1 in @(Reg-SubKeys $root)) {
        $n1 = ([string]$k1 -split '\\')[-1]
        if ($n1 -notmatch ('^' + $script:GuidRx + '$')) { continue }
        $p1 = $root + '\' + $n1
        $d = Plan-DefaultsAt $p1 $Guid
        if ($d) { $out += ,@{ Sub = $script:SubNone; Set = $n1.ToLower(); AC = $d.AC; DC = $d.DC }; continue }
        foreach ($k2 in @(Reg-SubKeys $p1)) {
            $n2 = ([string]$k2 -split '\\')[-1]
            if ($n2 -notmatch ('^' + $script:GuidRx + '$')) { continue }
            $d = Plan-DefaultsAt ($p1 + '\' + $n2) $Guid
            if ($d) { $out += ,@{ Sub = $n1.ToLower(); Set = $n2.ToLower(); AC = $d.AC; DC = $d.DC } }
        }
    }
    return $out
}
# Puts a standard plan back that Windows will not copy any more (after "powercfg /delete" Windows no longer finds Balanced or High
# Performance to copy: "The power scheme, subgroup or setting specified does not exist"). A copy of a plan that is there is made under
# the plan's usual ID (or a new one when Windows does not take that ID), it gets the plan's name, kind and description, and every value
# Windows keeps as that plan's default is set. Returns the ID, or '' when Windows keeps no default values for the plan on this PC (then
# nothing is left behind).
$script:PlanStdText = @{
    PlanBalanced = @{ Name = 'Balanced'; Desc = 'Automatically balances performance with energy consumption on capable hardware.'; Kind = 2 }
    PlanHighPerf = @{ Name = 'High performance'; Desc = 'Favors performance, but may use more energy.'; Kind = 1 }
    Ultimate     = @{ Name = 'Ultimate Performance'; Desc = 'Provides ultimate performance on higher end PCs.'; Kind = 1 }
}
function Plan-Rebuild {
    param([string]$Key)
    $def = $script:PlanDefs[$Key]
    $g = [string]$def.Guid
    $txt = $script:PlanStdText[$Key]
    $vals = @(Plan-WindowsDefaults $g)
    if ($vals.Count -lt 20 -or -not $txt) { return '' }
    $plans = @(Pwr-Plans)
    if ($plans.Count -eq 0) { return '' }
    $base = @($plans | Where-Object { $_.Active })[0]; if (-not $base) { $base = $plans[0] }
    [void](Pwr '/duplicatescheme' ([string]$base.Guid) $g)
    $at = $g
    if (-not (Plan-Find $g)) {
        $at = Pwr-NewFrom ([string]$base.Guid)
        if (-not $at -or -not (Plan-Find $at)) { return '' }
    }
    [void](Pwr '/changename' $at ([string]$txt.Name) ([string]$txt.Desc))
    $want = @($vals)
    if (@($vals | Where-Object { $_.Set -eq '245d8541-3943-4422-b025-13a784f679b7' }).Count -eq 0) {
        $want += ,@{ Sub = $script:SubNone; Set = '245d8541-3943-4422-b025-13a784f679b7'; AC = [int64]$txt.Kind; DC = [int64]$txt.Kind }    # the plan's kind, when Windows keeps none
    }
    $r = Plan-SetValues $at $want
    $m = '  made from Windows'' own default values for it: {0} value(s) set' -f $r.Set
    if ($r.Bad) { $m += (', {0} not accepted' -f $r.Bad) }
    Say $m 'DarkGray'
    return $at
}
# Sets values (@(@{ Sub; Set; AC; DC })) in a plan; only the ones that differ from what the plan has now (one powercfg call each).
# @{ Set = how many were set; Bad = how many Windows did not accept }
function Plan-SetValues {
    param([string]$Guid, $Vals)
    $cur = Pwr-ParseQuery (Pwr '/qh' $Guid) -Both
    $n = 0; $bad = 0
    foreach ($s in @($Vals)) {
        foreach ($side in @(@('AC', '/setacvalueindex', 0), @('DC', '/setdcvalueindex', 1))) {
            $v = $s[$side[0]]
            if ($null -eq $v) { continue }
            $c = $cur[[string]$s.Set]
            if ($c -and @($c).Count -gt [int]$side[2] -and [int64]@($c)[[int]$side[2]] -eq [int64]$v) { continue }
            $n++
            $o = Pwr ([string]$side[1]) $Guid ([string]$s.Sub) ([string]$s.Set) ([string]$v)
            if (([string]$o).Trim()) { $bad++ }
        }
    }
    return @{ Set = ($n - $bad); Bad = $bad }
}
# A plan of Windows' own (Balanced, High Performance) compared with the values Windows keeps as that plan's defaults, the ones its
# "Restore plan defaults" uses. Only reads. @{ Checked = how many of them the plan lists; Diff = @(@{ Sub; Set; AC; DC }) that differ,
# plugged in or on battery }; Checked = 0 when Windows keeps no defaults for it or the plan cannot be read.
function Plan-DefaultsDiff {
    param([string]$Key, [string]$Guid, $Cur = $null)
    $o = @{ Checked = 0; Diff = @() }
    $def = $script:PlanDefs[$Key]
    if (-not $def -or $def.Kind -ne 'windows') { return $o }
    $vals = @(Plan-WindowsDefaults ([string]$def.Guid))
    if ($vals.Count -lt 20) { return $o }
    $cur = $Cur
    if ($null -eq $cur) { $cur = @{}; try { $cur = Pwr-ParseQuery (Pwr '/qh' $Guid) -Both } catch { } }     # (or what the caller has read already)
    foreach ($s in $vals) {
        $c = $cur[[string]$s.Set]
        if (-not $c) { continue }                       # (a setting this PC does not list for the plan)
        $o.Checked++
        $d = $false
        if ($null -ne $s.AC -and @($c).Count -gt 0 -and [int64]@($c)[0] -ne [int64]$s.AC) { $d = $true }
        if ($null -ne $s.DC -and @($c).Count -gt 1 -and [int64]@($c)[1] -ne [int64]$s.DC) { $d = $true }
        if ($d) { $o.Diff += ,$s }
    }
    return $o
}
# Windows' own "Restore plan defaults" for one of its plans (powrprof.dll, PowerRestoreIndividualDefaultPowerScheme): the plan is replaced
# with the copy Windows keeps for new accounts, with Windows' own name for it. 0 when Windows did it, else the error number Windows gave.
function Pwr-RestoreDefault {
    param([string]$Guid)
    if ($DryRun) { return 0 }
    try {
        if (-not ('HrPowrProf' -as [type])) {
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class HrPowrProf {
    [DllImport("powrprof.dll")]
    public static extern uint PowerRestoreIndividualDefaultPowerScheme(ref Guid SchemeGuid);
}
"@
        }
        $id = [Guid]$Guid
        return [int64][HrPowrProf]::PowerRestoreIndividualDefaultPowerScheme([ref]$id)
    } catch { return [int64]-1 }
}

# ------------------------------------------------- built-in plan files (third-party plans) ----
# Plans that are not Windows' own: each plan file (what "powercfg /export" writes) is kept here, compressed, and checked against its
# SHA-256 and size before it is used ("powercfg /import <file> <id>", see the power plan switches below).
$script:PlanFileKhorvie = @(
    'H4sIAAAAAAAC/+1ba4xc112/u961N/FrbW+T9TNjJ46d2Cc57wctxIGAFyIVSyUiwAd8nrFx4qwc07iiiJWKkOFTKgSyKB+MqIThS41Uqa4agUsLmJdYJIgM',
    'SNSFVFqBFC1IgBGo5n/unZmdmZ2bvQP+BHPk2Xvn7t17f+f//P3/5/hSfC1NFEWRP39w+Le/8Cv+byby+aaiGvm8lU9OVef/2/EdP/+xdy/++Qe7fvfsF3/5',
    's60f/+vB7/mejw5cu/TG5TeK8XjoY3rbi6fHUhiP8RiP8RiP8RiP8RiP8RiP8fj/Mc658xfLk9nhv7/64MGDixdOFj/38oXzuTeQr8GlB9vbvz/7XPV9Es7v',
    'wo9r7d8vtH8/D5/j7fOn4KOxwg4riYjWCXGqA7ImSBSJpcmYZIMI5d/BM966AM/fVH2m4dpy2Y+YWroFx6+3nzkHn8ni88WWcg7zxV74NjFZlbe5b3E4n+/L',
    'KIqlddeH3N+qub+8PjtXvFDsLCaqRsj07vxz31z55iHXltrXylZK7+97z+/CPD95YWt5f1HOJc/RFi/Ft/yl84uXz795sfjO4sX2fdtKWS5PdO4LxfddOh8v',
    'htc/9XH7RnzzUijuf/vBg5eLc8WbxaXik8X5IhbHireKVnEGrrwN3y7B2evw/Kz0VvG9cE++9n+vtbEK8loCOd2Y6LXjVvGZ//oS+Ym2Hbfa8s7j+nRltx37',
    'zjbXa8e9I9sxxoTGyBUymBPEnQjIOKWQYCI5qx3hnBbth2U7zn6RPy/A5/22Hf9p1n+fHd8qZtpeM5IdFyPacdHQjuG+8rn/Q9vOI+vh9TRRLG4uCoZN6Ojh',
    '03/4xa4eVibXZPugPcq+43Tl+x295HEAPlM9epCK6Ug9R1FbgbjlFDkiLYqY46ikUULGfO99eMat6eq4srnjdzvys0q/myqq/uaL3/OJePny+Yuvff/FEK9U',
    '99+fGm4/dbhXpjbGnbxiijqJrKMBcRYj0sooREQ0mpNEvbflO0r5TRaLU9Vcj09Xfzsc/2cnB/F3cP/bG7/2+dRj951e7tmpEe0+qOBspBC6DUccU4vA3COi',
    'UikVNdfah468781UxxuPVMfjM8Px3JseLsfVBnLMNuWjccjFBHgIMcgYSpDVgiRHaMKJF0Wdvj8xoO+JLr5tv9Qvrw7ElUdHkxdl2kNW0whbC3omMSDNAKlR',
    'LlJOvU4Ud+S1sr063txRHXH7+7XZ6nh2VzEU3+yW4fI7t3lj+VERkiXcIBECxDHFJHLCuuxOTDnhNNFqUH4Ttf6ycyR8rzbAp5znmRmgoJNHnEuDgD44xFh0',
    'Sgtrve3Kb+HR6rjUtrc7O/txX+ninhrAHUfCfbYBbsOtl4EapJiPoHcrkcYmIckkc5YSx1Wst8utr/Tj+8JPDZf/jYk6f28yjzszG8/DuuSpAK9iEmvEPfi7',
    '4dEioojDMQgurWtuHz9wrYPv/KNf6cbROnzLDfC5wJwi2iIsNUY8GPAvCKnAJwN1oAONZRmPbpdxdLq4uaWy+TMzlW3NPFLpavmRaq6Lj1bPHM6D18eFQdw5',
    'JaxuXePBtX7HRdACqAMznIFdU8hbmApEmFWaJ6mATdTL9Wvr9F4n/5f67vu9IzkfXwd8d7b2z+tnPvfVPl7UWf+7umPEeGchr3GYFzEM9AEJAukAvMhRF52z',
    'DENc6fjr0lw7vn2kH/+mWvu585f5/qvb1nBfeOF3uriLbcPt6NqWje0Ia8Gs1ARR5cHOCcYIwg4YE8WERaPAvFi9v/7rcj/OP54YJtc6fFcb4OM6Sqcgigic',
    'gOcoTZEVgQPfdE4nrCKlspdvFUDAKNhzlteV3U35zp4f6eBW7399Q9zvNMAdOPCZxAgSKUEc9JFApoavxDEN/7jH2HTk+nraVNzaVuni1e3VnGd3VM/oPL/Z',
    'PLiv89eOXetdI9p1lJgQMGkg+KQdZ4BjIiqokdLZgAWvixN3dwyX390G8c0zmXB08CKjwS6twvBeIItYQ5Tw1FPOPsQuX/EDdvlctoczj1V+N/94u/6f3aj+',
    'bzaf6w3swXPqlLEWWcss4po7qP91QtQnRq012FJdP5+7tflO7L3Ttdc6fDea2KvANCkQMAleIR4hBFgBxV3C3MkkPKhZ9NrrmZ2Vjlqz1dxuz1bP+HB7ffmb',
    '/fP4xkSdvXZ4+vL20eyVa6loYhopa0DODlKidkkjBlnHRWJC5LFXv/rjf9KV39Vdw+V3b3sDPpn5Age+JqKFIkFjAiGUMHgvVA2YgNZNGJTL5q5cvtmIz/TW',
    '7efm+uUy2H9aJ5dkFInaoBgd8HEuBJQKISIThSlLRsZVl4/j6niVNOU3//hCWefsqTDmd90AfGAyrPUs8A1B5PJJiD2SmGHzur57uNxvbtuYTygJ0TJZhkIw',
    'wJMji8DjZZkuDDVMS6pxnT/XvfdKg/caaYx0HrIlWD3kpeiRocwhmThUDhzQRNdbx17ZU2Fd3VP97XC5bj7YL9f3u/4Rfvq1c7/YYweHOnHq2Gj+kXXCgNiC',
    'dTrIS5pCSSZ9roCcxE5xHHCfvPyRz73Xee+NueHyWtrWgGdIbwNEdCR5zPYHzFUbqpCPyiUDkZ6Jdf4RunL5o1r/+LFv/EXXf+vwre58KPjW+imPV8fVdj6Z',
    '3VuH+1uN/LoO9/0muL0XTnIASkJCXDIFuIlFIXomPCNa6HV9gLlaP3bvNuMZP/SfnXn8+7G/2lD++rGN50GoxdZxjlKkkO+ThXqX5UgFk0ucG4mtrLePzbX9',
    'nyff3VjOpx4OPlWf9+Ymh/XXXp1v9zv2V8fl/aPhXmiCO1mfvIRoX9YlzgtkcnoUmEePjXIQwwZx07U6+5/7cT//w6Pgu7u3Qd7kDOQqE7ANmusmSJ4gS4KS',
    'ShBOBWHckUF8tovv7Qf9+OYmyz7S3jU5Hpz+Qb5h/Jpv0G9zmAcOrIj4zI8AHLKOeBQIY0oT44FqDOL80S5OPlz/+/rvv7qnzt/2vVvm432j2cfVBvPiOLmY',
    'YEo0ArXnAUpxC0EDYZ+AMSnurFfN64+vnh4F3ztN8EkRSYIU6yTJeRbIs3VCI4wDwUoFD+l2EN9kF9+X/6MfH57s4Nv55b/dMG5dO9AAnzM0KAAkLKRSriGz',
    'Wp6LFSKC0jZGQkx93PrUgPxsyHpePDCanpf2NcEZbIJ6EgwWM8gTQYHHJYwyPyKUSCJjqo8D3z3UfucP1s2L2WH3LwzcP1VrR7/5mbJ+P7gmh90f/N2G+rrZ',
    'RA6BOkwERSoI4ItGO6R1pIhxBszIUEu96OU/f/8vpz/YKH7cPrTxe8EaJDzboqiBNHIotsDPGEOUQIIGExLahno/u97ql48u49y1Q6PZybknGqwrEemDtQJJ',
    'I4AfAl1ERtkAP4KngbgQtK63EzPUTk49MRrOlYeD03T4WqtVHW+3j9efbNf/rfr6v1m8+8qvjjKv1UbzMk4JDAEYQzXBo6aobH9BRUGNZxhS9rp86Nfwfakf',
    '34uTI/Gggw8FH23eF9//T+X6zuHR7AMfadDP0DFEZxwywgMvTgbymmIeOQwzUEwa5g1QjFSTN97rx3m29LeZI2s4f//CtzaMR4sHm6zzUMq1ZsAmPcSjoAyk',
    'DpOQZopDmPIuKt8bj5rI53qT98LcQTIWJYJ9rgMBAWRaFA2zUYvEpeuLg/eOvvT2RnHwfgP71oaFGPPCKdCOvC4IqdL4vPgmAoaK3Uju6/PllgH7mRot/j3V',
    'YP2KOe1k8AhLAzw/AMUzMXL4yiF7Yuz1+jp1uovvu369H9/p0m5OPTWa/maPNllnY157J5FMBvI5hVLVBq1Af5alCNReh3Vx4mNdnKeHxumVEXHeaoAzd7+0',
    'y+sLIcdpqTXglBYRlju4QkrBXT1/G4wXu1XG+c7R0XCefboBzgg8nkJhhAOENE64hIpJQqZO4IgmAKVbz4PXcPoD/ThfKfWunx4N58yxJn1koQnU9eA1FuKv',
    'MFDvRwphzhuf61Mc5Tp5nvlaty8+VO/3RsR59fBDib8lj7j17dwfO1S0PlL1YG63j1ceq3obpx6vau977eO1+aqm1Xur2vHe3qo2u7WvqmVe3V/VDPf3V9z8',
    '+oGK+944WHG/1qGKi905VHGIxSeq40Krym0r7aM+UsXmm0eqWHn8ySp23XmyihGLT1U+OH+0svHbRysbOvd0paPZY5UM3jlcHZePwzEFcuWZokiKiYe98WsU',
    '/S0+00B/gBVKLIXAbbOdhYC0UhZBeIFUH4jwmtb3lexQO1t4ZjSc88822E8EsrRSAZHGElhI0hhZ7AUKkGWghiUurY/X9f2vlxfKvl4Pzo/+w/B1tKWTo/Vd',
    'cw/cGZFQUkrm/RwcaS8Y5BUiVeJg6sb06rHvvc/W9H9ONOj/KGstBT/ULq+3O8ORtSkiJpLkQKATid2+5r0T7X1LJ/vl9ZObOvLatadfXqGMc60To+GebYCb',
    'eew8pgR5bSEPRwz5DeIGko5w77yjrtpH0ln3XUDg1za4kuejOv7+Zm2fsAnu+Qa4dfTcsVyXaAm4tQd+HJXIeQRz7qLWa33CvI527dlKR2dOVHOeOVk9Y1gd',
    'spa/T/1Z/zwuT9bZa2cd7c6J0ew1r9U4QySKGPPM7jUyDjwsADuU4GUS6FGdvea1nqH9wAbyyzp0yQH/Uhz4QrAEOQtpOQAtY9LljWPr1n1Xu3L5dDP99vjx',
    'bTyaXKJiFnMdkEs09wEJhZIzp2NHsZKgXkPKPspiqd/t5V7JvGc27/XLewjznp+8N+741movTN5jkPeO5LXbvNae1yDzGmZem/qwdbQVVGGZBZaXiBBN80Ov',
    'HPIzhunpzJ4m/QznlIdCheloEMchy4GbHIEtjgaCC06jvvf+8w3qT6aizd0TB0EA3ktE5j8eWeKVM+BAgsvO/vu87rb6XIX13PPV35bxCrfrf9ys/l/jea3f',
    '6Levn50cZX7zDeTqfIjBCIKIVjC/AJW281AZJhUFAULqqdC98WNwfgu4esawedTX4VdOdeZxeXLTb134kH1e5f7kBvPINpn9ARntwE+IhhLPcI6iTVbKvD8q',
    'mPo+y3sD+wB/YfLMjvH/WRmP8RiP8RiP8RiP8RiP8RiP8RiP0cd/A/VnaSgAUAAA'
) -join ''
$script:PlanFileLowLatency = @(
    'H4sIAAAAAAAC/+1YX2hlRxmf/NtNmm2SXVeIqw9XEMzDTp2/Z2ZEcGUX2bLWBlR86MvOzJnZDZu9icnddvsgRkQp6EOxKqsgDSISUKR9kYAIpQiGdh+kRVp8',
    'kH2uD+6LsA9i/Oace3P/7DnNDfrm+ZJzZs7M3G++7zffn5nZCjfiBEIoPb++eGf6r8+9N5HqU6ikVG+h8jWB/nt69u133rr/p7+f/aHf/O6b+fe/M/qdxqyO',
    'tG3d7txGDf3P6dWvbr/boNBQQw011FBDDTXUUEMNNfT/QTfdWruoLFX3v3R4eNi+dRG98tY/fnb/ufeKKwBoOpzr9h8slN+TUJ+dQuhet/9qt38Zni9165+C',
    'x0hPpBcEB+UcFumlnY04UskcCTRG74vfAY/tWyW/9FyA58/FfcT0D/ah/GOX53l4JtEv0elCh2X0MfiamCy6ZtK9xSdT/UKSAu081l4xvlUzvmhfOo8+jxbR',
    'RHkRMnMuvS+cL2auaNvpthVXKYP9g/X3Qc/nb80XGO1NJF2SjhvoStj2W2ubnbWNNtpGHXQVxgW0jtbQbXjayEJbgJ4W2oTRL0B9C74ser7ovQHtL0Ctg24W',
    '3+VXG+XF2G2YY7C+BvWS1x2YoVPMUfJP3BPnCGO3itY28kX7RsE1cb8B7zSmBe/EtYVW0WXg9hRw7nT1O4M+m2xpsq/fF7fWQjtff/HL9nbAiKIdGGcL3Tro',
    '04Us64V8qSxlSTO/OKTvZtGXzHcDJHwK5l6Hv4so8TNQfu0xbVYrtUn0EObfAfyvTw7afQt96/W/XOvZfQv178X2Z0o77/nDqN0PUrJ7QigLQShsiKBYOJlj',
    '45TCksvorHZUCNaTYz1OoJ1TCHFi8p4cv7r2zG/e7sqxPNXnfdilJPbd6b7/9fo/Ac/0gByZ4jowL3DQVmJhBcOOZhYHIkhQmVEyKwB5BDyWZ8rywUzPThcS',
    'rx3U5ZmE+cLlr4ROZ6194+l2Hu7WjZP4ysi4pOcKdK5OD+P9+k//9vT9D9EzdSyPoWfOcylDzLGHkIIFEwGb3HMsBHVBac4JJYN4H0AAcTl3Sd9Ls8N6XP+g',
    'Tt/lSjupk7s1jtwZN5JqWBCZ5VhwIbG2ERbJRM6iYxklBnXjxnqcQrtT5Zq+NF3qfGmm5NHjX63H9Ige3zzS4+cXLr8yaO+9O9+Xp05o77nKnQ0MoDcCC8Is',
    'BjMPmGVKqaCF1j4fXPfBeWdP1eB3+nj8ks/4YBx2IcK8lBpsDKPYakmjoyySKEZxmTiy04URXD7+u2QPj06hY/FBJ4wHjGtvotWYWAvrTEOONQeJjXKBCeZ1',
    'ZKTnhyvzZfmwW24+0bfbl8/AekvCquRbOV2N49LM8TgmX1DJDkmmCRa5AfmsYzjQnDlhvSZZPopj39+fGcHx8LAqjrVQdRwjc8fLx4TMtYRQyo1IXs3ARQiT',
    'mHKrtIiZguhav84fHrcmB8ZdGfH3hPsDiA+zc8Nxa9QueiHgYP6EdmEVVxCkMDUccAfHwTqHPOGYC85ZTrTlPbvYXyxLfbZOzx8/tg5p/MFcX+4O/dGzPbkv',
    'zVXby2tj+B3RkttMU8yU12DPhGDLIPxqRigPRoEZ8dH12P3eRFfOzc6wnJ+rxLVOvt0x5BM6ZE7ZDEsSIe8pzbCVuYD865yORAXGsh6us0/2/WsP6sxFX23n',
    'GyP4dk4k994YcuciGB05xTLGgIUPFCIbfFLHNfwLT4bzwaO5ci3uPVHqvDpf8qjKBwP+emtYjzt/OC7e7Z8+oV2HjFAKJg0bHtqNJ7DnwEwyk2XO5kSKOn9a',
    'PlMTx+bHwA9iY1QhYJp7hUXaEVgJm69IhMtiOowIWY9LzIZxWTg2Dyyf0N+FzhSLXGNljYV9IYRY7aLGHKKbC9TkQYQ6XMiT1bhcXRgjfoJNMxENlsFCktaE',
    'gqtSDvNC1ibUWm4ei+9TR7hcf20YF/9B8pvWQl/OV3/7z58M4jPTnfvuuZPhA8vDOZNJOgf2rxmkyMzTdHLMiFOC5KTIk7uF/c8Ve6+01057iLQHSTkw5dqb',
    's2XOSL6YYmyyqWSTCcO0BqsL5Vz7IJ+SNKs+B7fQL/6VhZ5e6TdV+D8cI3+RzNs8koAzAalfCMi02jCFPZyLoyHBcZn34tH7Z8tyqVvufaQu3tuReGSP4hiB',
    '33BP3FLV+X/puPN/C/0+/3c8Tu/9MfSmzBLrhMAxMMgT0RrsuAMEXCaiECYjNquz97p53xhjXu6IyAV4P/UpDkTGsXXU45xyrjQ1Hlxv1N7zI1w/8/VhXL99',
    'b7zz0Fr7JHrsLo6Rx5xhuZIaSwuuIGBXi61QBGsqc6VtCLDjrddDrwzLd2Wlyl/r5NsbQz7lGIPNPYdV9R7ivDIgmomwuVWCSubh8FXc77xR2OUMWlksfaG1',
    'VNrGvaVyra6fLXVF50qedXY5eC81GIcfLJ4sziSfd0ZGHJXKwB8zgbWXHLa/NFNREO+NqZt3/1zNvmkMvJJPegIHFK/hMCACUdgaxXHmqPDOw7ZPhfr89NGD',
    '4fW89g1yprnTbKihhhpqqKGGGmqooYaq6T8nm+uNADAAAA=='
) -join ''
$script:BuiltinPlans = @{
    Khorvie = @{ Guid = '8070b076-188f-428d-a9d6-e1a2f99fad5d'; Name = 'Khorvie''s PowerPlan'; Size = 20480
                 Sha = '0e41edd749126d44c4f92d2c5f67e7a1abe0809a4bd69aff2a88f8f90c206b61'; B64 = $script:PlanFileKhorvie }
    # amit's low latency powerplan (idle enabled, v3); Headroom gives it the name "Low Latency Power Plan" (powercfg /changename)
    LowLatency = @{ Guid = '95c05c40-e7bb-47bb-8baf-f152b0e1ffcc'; Name = 'Low Latency Power Plan'; FileName = 'amit''s low latency powerplan'; Size = 12288
                 Desc = 'Eliminates power saving within Windows (amit''s low latency powerplan, idle enabled, v3).'
                 Sha = 'ed98a09f99e0b46355b6f0044b61fb742ecb4da56be2f1e383a306caa7cf891b'; B64 = $script:PlanFileLowLatency }
}
function Get-BuiltinPlanBytes {
    param([string]$Key)
    $def = $script:BuiltinPlans[$Key]
    $ms = New-Object IO.MemoryStream(, [Convert]::FromBase64String([string]$def.B64))
    $gz = New-Object IO.Compression.GZipStream($ms, [IO.Compression.CompressionMode]::Decompress)
    $out = New-Object IO.MemoryStream
    try { $gz.CopyTo($out) } finally { $gz.Dispose(); $ms.Dispose() }
    $b = $out.ToArray()
    $sha = [Security.Cryptography.SHA256]::Create()
    $h = (($sha.ComputeHash($b) | ForEach-Object { $_.ToString('x2') }) -join '')
    $sha.Dispose()
    if ($h -ne [string]$def.Sha -or $b.Length -ne [int]$def.Size) { throw ('the built-in file of {0} did not pass its check (SHA-256), so it was not used' -f $def.Name) }
    return ,$b
}
# Where a plan file is written for powercfg: a local folder with a plain (ASCII) path, because powercfg /import can fail on other paths.
# Windows' own Temp folder first (this app runs as administrator), then the user's Temp folder.
function Get-PlanTempDir {
    $c = @()
    if ($env:SystemRoot) { $c += (Join-Path $env:SystemRoot 'Temp') }
    $c += [IO.Path]::GetTempPath()
    foreach ($d in $c) { if ($d -and $d -notmatch '[^\x20-\x7E]' -and [IO.Directory]::Exists($d)) { return $d } }
    return [IO.Path]::GetTempPath()
}
# Imports a plan file under the given ID (or, where Windows does not take an ID, under a new one). Returns the ID, or '' if it failed.
$script:PwrImportSaid = ''      # what powercfg said when it refused the last import (for the log)
function Pwr-Import {
    param([byte[]]$Bytes, [string]$Guid)
    $script:PwrImportSaid = ''
    $f = Join-Path (Get-PlanTempDir) ('headroom-plan-' + [guid]::NewGuid().ToString('N') + '.pow')
    try {
        [IO.File]::WriteAllBytes($f, $Bytes)
        $o1 = Pwr '/import' $f $Guid
        if (Plan-Find $Guid) { return $Guid }
        $o = Pwr '/import' $f
        $g = [regex]::Match([string]$o, $script:GuidRx).Value.ToLower()
        if ($g -and (Plan-Find $g)) { return $g }
        $script:PwrImportSaid = ((([string]$o1).Trim()) -split "`r?`n")[0]
        return ''
    } finally {
        try { if ([IO.File]::Exists($f)) { [IO.File]::Delete($f) } } catch { }
    }
}

# What a plan file holds. A .pow file is a small registry hive: the plan's key (named after its ID, with FriendlyName and Description),
# under it one key per subgroup with one key per setting (ACSettingIndex / DCSettingIndex), and settings that belong to no subgroup
# directly under the plan. Returns @{ Guid; Name; Desc; Settings = @(@{ Sub; Set; AC; DC }) }; AC or DC is $null when the file has none.
$script:SubNone = 'fea3413e-7e05-4911-9a71-700331f1c294'
function Pow-Cell { param([byte[]]$B, [int64]$Off) $o = 4096 + $Off; return @{ At = [int]($o + 4); Len = [int]([Math]::Abs([BitConverter]::ToInt32($B, [int]$o)) - 4) } }
function Pow-Key {
    param([byte[]]$B, [int64]$Off)
    $c = Pow-Cell $B $Off; $o = $c.At
    if ([Text.Encoding]::ASCII.GetString($B, $o, 2) -ne 'nk') { throw 'the plan file is damaged' }
    $flags = [BitConverter]::ToUInt16($B, $o + 2)
    $nlen = [BitConverter]::ToUInt16($B, $o + 0x48)
    $name = if ($flags -band 0x20) { [Text.Encoding]::GetEncoding(28591).GetString($B, $o + 0x4c, $nlen) } else { [Text.Encoding]::Unicode.GetString($B, $o + 0x4c, $nlen) }
    return @{ Name = $name; NSub = [BitConverter]::ToUInt32($B, $o + 0x14); SubList = [BitConverter]::ToUInt32($B, $o + 0x1c); NVal = [BitConverter]::ToUInt32($B, $o + 0x24); ValList = [BitConverter]::ToUInt32($B, $o + 0x28) }
}
function Pow-Subs {
    param([byte[]]$B, [int64]$List)
    $c = Pow-Cell $B $List; $o = $c.At
    $sig = [Text.Encoding]::ASCII.GetString($B, $o, 2); $n = [BitConverter]::ToUInt16($B, $o + 2)
    $out = @()
    if ($sig -eq 'lf' -or $sig -eq 'lh') { for ($i = 0; $i -lt $n; $i++) { $out += [int64][BitConverter]::ToUInt32($B, $o + 4 + $i * 8) } }
    elseif ($sig -eq 'li') { for ($i = 0; $i -lt $n; $i++) { $out += [int64][BitConverter]::ToUInt32($B, $o + 4 + $i * 4) } }
    elseif ($sig -eq 'ri') { for ($i = 0; $i -lt $n; $i++) { $out += @(Pow-Subs $B ([int64][BitConverter]::ToUInt32($B, $o + 4 + $i * 4))) } }
    else { throw 'the plan file is damaged' }
    return $out
}
function Pow-Values {
    param([byte[]]$B, $K)
    $out = @{}
    if ($K.NVal -eq 0 -or $K.ValList -eq [uint32]::MaxValue) { return $out }
    $c = Pow-Cell $B $K.ValList
    for ($i = 0; $i -lt $K.NVal; $i++) {
        $v = Pow-Cell $B ([int64][BitConverter]::ToUInt32($B, $c.At + $i * 4)); $o = $v.At
        if ([Text.Encoding]::ASCII.GetString($B, $o, 2) -ne 'vk') { throw 'the plan file is damaged' }
        $nlen = [BitConverter]::ToUInt16($B, $o + 2); $dlen = [BitConverter]::ToUInt32($B, $o + 4); $doff = [BitConverter]::ToUInt32($B, $o + 8)
        $typ = [BitConverter]::ToUInt32($B, $o + 12); $vfl = [BitConverter]::ToUInt16($B, $o + 16)
        $name = if ($nlen -eq 0) { '' } elseif ($vfl -band 1) { [Text.Encoding]::GetEncoding(28591).GetString($B, $o + 0x14, $nlen) } else { [Text.Encoding]::Unicode.GetString($B, $o + 0x14, $nlen) }
        $inline = ($dlen -band 0x80000000) -ne 0; $len = [int]($dlen -band 0x7fffffff)
        if ($inline) { $data = [BitConverter]::GetBytes([uint32]$doff)[0..([Math]::Max(0, $len - 1))] } else { $d = Pow-Cell $B ([int64]$doff); $data = $B[$d.At..($d.At + [Math]::Max(0, $len - 1))] }
        if ($len -eq 0) { $data = @() }
        $out[$name] = @{ Type = [int]$typ; Data = [byte[]]$data }
    }
    return $out
}
function Pow-Num {
    param($v)
    if (-not $v -or @($v.Data).Count -lt 4) { return $null }
    return [int64][BitConverter]::ToUInt32([byte[]]$v.Data, 0)          # a DWORD, or a 4-byte binary value (the way some plan files keep an index)
}
function Pow-Read {
    param([byte[]]$Bytes)
    if ($Bytes.Length -lt 4100 -or [Text.Encoding]::ASCII.GetString($Bytes, 0, 4) -ne 'regf') { throw 'not a plan file' }
    $root = Pow-Key $Bytes ([int64][BitConverter]::ToUInt32($Bytes, 0x24))
    $rv = Pow-Values $Bytes $root
    $str = { param($x) if (-not $x) { return '' }; return ([Text.Encoding]::Unicode.GetString([byte[]]$x.Data)).TrimEnd([char]0) }
    $out = @{ Guid = ([string]$root.Name).ToLower(); Name = (& $str $rv['FriendlyName']); Desc = (& $str $rv['Description']); Settings = @() }
    if ($root.NSub -eq 0 -or $root.SubList -eq [uint32]::MaxValue) { return $out }
    foreach ($o1 in @(Pow-Subs $Bytes $root.SubList)) {
        $k1 = Pow-Key $Bytes $o1
        $v1 = Pow-Values $Bytes $k1
        if ($v1.ContainsKey('ACSettingIndex') -or $v1.ContainsKey('DCSettingIndex')) {
            $out.Settings += ,@{ Sub = $script:SubNone; Set = ([string]$k1.Name).ToLower(); AC = (Pow-Num $v1['ACSettingIndex']); DC = (Pow-Num $v1['DCSettingIndex']) }
            continue
        }
        if ($k1.NSub -eq 0 -or $k1.SubList -eq [uint32]::MaxValue) { continue }
        foreach ($o2 in @(Pow-Subs $Bytes $k1.SubList)) {
            $k2 = Pow-Key $Bytes $o2
            $v2 = Pow-Values $Bytes $k2
            if (-not ($v2.ContainsKey('ACSettingIndex') -or $v2.ContainsKey('DCSettingIndex'))) { continue }
            $out.Settings += ,@{ Sub = ([string]$k1.Name).ToLower(); Set = ([string]$k2.Name).ToLower(); AC = (Pow-Num $v2['ACSettingIndex']); DC = (Pow-Num $v2['DCSettingIndex']) }
        }
    }
    return $out
}
# When Windows refuses to import a plan file as a whole (one value it does not accept on this PC is enough, for example "The value
# specified is malformed, or is not within the range of the target power setting"), the plan is made the other way: a copy of High
# Performance (the kind of plan both built-in plans are; Balanced when this PC has no High Performance) under the plan's own ID, with
# the plan's name, and then every value of the file set one by one. A value Windows does not accept keeps the High Performance one,
# and the log says how many that were. Returns the plan's ID, or '' when no copy could be made.
$script:PlanBuildRefused = @()
function Plan-BuildFromFile {
    param([byte[]]$Bytes, [string]$Guid)
    $script:PlanBuildRefused = @()
    $pow = Pow-Read $Bytes
    $made = $false
    foreach ($tpl in @($script:HighPerfTemplate, $script:BalancedTemplate)) {
        [void](Pwr '/duplicatescheme' $tpl $Guid)
        if (Plan-Find $Guid) { $made = $true; break }
    }
    if (-not $made) { return '' }
    [void](Pwr '/changename' $Guid ([string]$pow.Name) ([string]$pow.Desc))
    $n = 0; $bad = @()
    foreach ($s in @($pow.Settings)) {
        foreach ($side in @(@('AC', '/setacvalueindex'), @('DC', '/setdcvalueindex'))) {
            $v = $s[$side[0]]
            if ($null -eq $v) { continue }
            $n++
            $o = Pwr ([string]$side[1]) $Guid ([string]$s.Sub) ([string]$s.Set) ([string]$v)
            if (([string]$o).Trim()) { $bad += ('{0} {1}={2}' -f $s.Set, $side[0], $v) }
        }
    }
    $script:PlanBuildRefused = $bad
    Say ('  {0} of its {1} values set' -f ($n - $bad.Count), $n) 'DarkGray'
    if ($bad.Count) { Say ('  Windows did not accept {0} value(s), which keep the High Performance setting: {1}' -f $bad.Count, ($bad -join ', ')) 'DarkGray' }
    return $Guid
}
# ------------------------------------------------- the power plan switches ----
# Each switch is one plan: On = the plan is installed, Off = it is not. Switching one on installs it (Windows' own plans are made from
# Windows' definition under their usual ID; the built-in plan files are imported) and does not change which plan is active. Switching
# one off deletes that plan and no other: when it is the active plan another one is made active first (Balanced, else High
# Performance, else Ultimate Performance, else the first other plan), and the last plan on the PC is never deleted. "Make active" on a
# card (Invoke-Plan action 'Activate') makes that plan the active one.
# Ultimate Plan Modified: Windows' own Ultimate Performance plan with the three changes Headroom made inside Ultimate Performance up to build
# 112, under an ID of its own, so that Windows' Ultimate Performance can stay as Windows ships it next to it. Each change is set for plugged
# in (AC) and on battery (DC).
$script:UltimateModGuid = '96159c62-1115-4153-83ea-271a2032c250'
$script:UltimateModChanges = @(
    @{ Sub = '2a737441-1930-4402-8d77-b2bebba308a3'; Set = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'; AC = 0; DC = 0; What = 'USB selective suspend off' }
    @{ Sub = '2a737441-1930-4402-8d77-b2bebba308a3'; Set = 'd4e98f31-5ffe-4ce1-be31-1b38b384c009'; AC = 0; DC = 0; What = 'USB 3 link power management off' }
    @{ Sub = '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1'; Set = '12bbebe6-58d6-4636-95bb-3217ef867c1a'; AC = 0; DC = 0; What = 'Wi-Fi adapter power saving at Maximum performance' }
)
$script:PlanDefs = [ordered]@{
    PlanBalanced = @{ Guid = $script:BalancedTemplate; Name = 'Balanced'; Kind = 'windows'; NameRx = '' }
    PlanHighPerf = @{ Guid = $script:HighPerfTemplate; Name = 'High Performance'; Kind = 'windows'; NameRx = '' }
    Ultimate     = @{ Guid = $script:UltimateTemplate; Name = 'Ultimate Performance'; Kind = 'windows'; NameRx = '^Ultimate Performance$' }
    UltimateMod  = @{ Guid = $script:UltimateModGuid; Name = 'Ultimate Plan Modified'; Kind = 'mod'; NameRx = ''; From = $script:UltimateTemplate
                      Desc = 'Ultimate Performance with USB selective suspend, USB 3 link power management and Wi-Fi power saving off (made by Headroom).'; Changes = $script:UltimateModChanges }
    Khorvie      = @{ Guid = [string]$script:BuiltinPlans.Khorvie.Guid; Name = [string]$script:BuiltinPlans.Khorvie.Name; Kind = 'file'; NameRx = '' }
    LowLatency   = @{ Guid = [string]$script:BuiltinPlans.LowLatency.Guid; Name = [string]$script:BuiltinPlans.LowLatency.Name; Kind = 'file'; NameRx = '' }
}
$script:PlanActive = $false      # set by a plan's check: the plan is the active one
# The IDs this plan has on the PC: its usual ID first, then the one it got when this app made it under a new ID (an older build made
# Ultimate Performance that way), then (for Ultimate Performance only) a plan with its English name.
function Plan-Where {
    param([string]$Key, $mine, $plans = $null)
    $def = $script:PlanDefs[$Key]
    if ($null -eq $plans) { $plans = @(Pwr-Plans) }
    $own = @(); $more = @()
    foreach ($x in @($plans)) {
        if ($x.Guid -eq [string]$def.Guid) { $own += [string]$x.Guid }
        elseif ($mine -and $mine.New -and $x.Guid -eq [string]$mine.New) { $more += [string]$x.Guid }
        elseif ($def.NameRx -and [string]$x.Name -match $def.NameRx) { $more += [string]$x.Guid }
    }
    return @($own + $more)
}
function Plan-Mine {
    param([string]$Key)
    $snap = (Get-Store)[$script:CurTweak.Id]
    if ($snap -and $snap.Custom) { return $snap.Custom[$Key] }
    return $null
}
# "Balanced plan", but "Low Latency Power Plan" and "Khorvie's PowerPlan" as they are (no "plan plan")
function Plan-Label { param([string]$Name) if ($Name -match '(?i)plan$' -or $Name -match '(?i)\bplan\b') { return $Name }; return ($Name + ' plan') }
function Plan-Detect {
    param([string]$Key)
    $def = $script:PlanDefs[$Key]
    $script:PlanActive = $false
    $plans = @(Pwr-Plans)
    if ($plans.Count -eq 0) { $script:Why = 'the power plans could not be listed'; $script:Now = 'Power plans: none could be listed'; return 'NA' }
    $at = @(Plan-Where $Key (Plan-Mine $Key) $plans)
    $act = @($plans | Where-Object { $_.Active })[0]
    $an = 'not known'; if ($act) { $an = [string]$act.Name }
    if ($at.Count -eq 0) { $script:Now = ('{0}: not installed (the active plan is {1})' -f (Plan-Label $def.Name), $an); return 'Off' }
    if ($act -and $at -contains [string]$act.Guid) {
        $script:PlanActive = $true
        $script:Now = ('{0}: installed, and it is the active plan' -f (Plan-Label $def.Name))
    } else {
        $script:Now = ('{0}: installed (the active plan is {1})' -f (Plan-Label $def.Name), $an)
    }
    return 'On'
}
function Plan-Snapshot {
    param([string]$Key)
    return @{ Had = (@(Plan-Where $Key $null).Count -gt 0); New = '' }
}
# After Balanced or High Performance is installed: every value is checked against the defaults Windows keeps for it; one that differs
# (a value Windows' copy did not bring) is set to Windows' default, and the log says how it came out.
function Plan-CheckDefaults {
    param([string]$Key, [string]$Guid)
    $d = Plan-DefaultsDiff $Key $Guid
    if ($d.Checked -eq 0) { Say '  (Windows keeps no default values for this plan to check it against)' 'DarkGray'; return }
    if ($d.Diff.Count) {
        $r = Plan-SetValues $Guid $d.Diff
        Say ('  {0} value(s) differed from Windows'' own defaults and were set to them' -f $d.Diff.Count) 'DarkGray'
        $d = Plan-DefaultsDiff $Key $Guid
    }
    if ($d.Diff.Count) {
        Say ('  checked against Windows'' own default values: {0} of {1} still differ ({2})' -f $d.Diff.Count, $d.Checked, ((@($d.Diff | Select-Object -First 3) | ForEach-Object { [string]$_.Set }) -join ', ')) 'Yellow'
    } else {
        Say ('  checked against Windows'' own default values: all {0} match' -f $d.Checked) 'DarkGray'
    }
}
function Plan-Install {
    param([string]$Key, $mine)
    $def = $script:PlanDefs[$Key]
    $at = @(Plan-Where $Key $mine)
    if ($at.Count) { Say ('  {0} is already installed' -f $def.Name) 'DarkGray'; return }
    if ($DryRun) { Say ('  [dry] install the {0} (the active plan stays the same)' -f (Plan-Label $def.Name)) 'DarkGray'; return }
    $g = ''
    if ($def.Kind -eq 'file') {
        $bytes = Get-BuiltinPlanBytes $Key
        $n0 = $Error.Count
        $g = Pwr-Import $bytes ([string]$def.Guid)
        if (-not $g) {
            $said = [string]$script:PwrImportSaid; if (-not $said) { $said = 'no reason given' }
            Say ('  Windows did not import the plan file as a whole ({0}); making it from High Performance and setting its values one by one' -f $said) 'DarkGray'
            $g = Plan-BuildFromFile $bytes ([string]$def.Guid)
        }
        Drop-ErrorsSince $n0          # (what powercfg said on the way is in the log lines above; only a plan that could not be made at all is a failure)
        $bp = $script:BuiltinPlans[$Key]
        if ($g -and $bp.FileName) {
            # the name Headroom gives this plan instead of the one in its file
            [void](Pwr '/changename' $g ([string]$bp.Name) ([string]$bp.Desc))
            Drop-ErrorsSince $n0
            Say ('  named "{0}" (its file calls it "{1}")' -f $bp.Name, $bp.FileName) 'DarkGray'
        }
    } elseif ($def.Kind -eq 'mod') {
        # a copy of Windows' Ultimate Performance under this plan's own ID (a new ID where Windows does not take it), named, and changed
        $n0 = $Error.Count
        $src = [string]$def.From
        $from = 'Windows'' own hidden Ultimate Performance plan'
        if (Plan-Find $src) { $from = 'the Ultimate Performance plan on this PC' }
        [void](Pwr '/duplicatescheme' $src ([string]$def.Guid))
        if (Plan-Find ([string]$def.Guid)) { $g = [string]$def.Guid }
        else { $n = Pwr-NewFrom $src; if ($n -and (Plan-Find $n)) { $g = $n } }
        if ($g) {
            [void](Pwr '/changename' $g ([string]$def.Name) ([string]$def.Desc))
            $r = Plan-SetValues $g @($def.Changes)
            Say ('  made from {0}, named "{1}", with these changes inside it (plugged in and on battery): {2}' -f $from, $def.Name, ((@($def.Changes) | ForEach-Object { [string]$_.What }) -join ', ')) 'DarkGray'
            if ($r.Bad) { Say ('  ! Windows did not accept {0} of these values; the plan keeps Ultimate Performance''s own value for them' -f $r.Bad) 'Yellow' }
        }
        Drop-ErrorsSince $n0
    } else {
        $n0 = $Error.Count
        $std = ($Key -eq 'PlanBalanced' -or $Key -eq 'PlanHighPerf')
        $g = Pwr-Restore ([string]$def.Guid)
        if (-not $g -and $std) {
            # Windows' own "Restore plan defaults" can put back the copy it keeps for new accounts
            if ((Pwr-RestoreDefault ([string]$def.Guid)) -eq 0 -and (Plan-Find ([string]$def.Guid))) {
                $g = [string]$def.Guid
                Say ('  Windows put back its own {0} (the copy it keeps for new accounts)' -f (Plan-Label $def.Name)) 'DarkGray'
            }
        }
        if (-not $g) { $n = Pwr-NewFrom ([string]$def.Guid); if ($n -and (Plan-Find $n)) { $g = $n } }
        if (-not $g) {
            # Windows no longer finds the plan to copy (it was deleted): it is made again from Windows' own default values for it
            Say ('  Windows has no {0} left to copy; making it from Windows'' own default values for it' -f (Plan-Label $def.Name)) 'DarkGray'
            try { $g = Plan-Rebuild $Key } catch { Drop-ErrorsSince $n0; throw }      # (the refused copy above is no part of what went wrong)
            if ($g) {
                # then Windows' own "Restore plan defaults" on it, which also gives it Windows' own name where Windows can
                if ((Pwr-RestoreDefault $g) -eq 0) {
                    if (Plan-Find $g) { Say '  Windows reset it to its own defaults ("Restore plan defaults")' 'DarkGray' }
                    else { Say '  Windows removed it when asked to reset it; making it again' 'DarkGray'; $g = Plan-Rebuild $Key }
                }
            }
        }
        if ($g -and $std) { Plan-CheckDefaults $Key $g }
        Drop-ErrorsSince $n0          # (what powercfg said on the way is no failure when the plan was made after all)
    }
    if (-not $g) {
        $why = ''; if ($Key -ne 'PlanBalanced' -and ($def.Kind -eq 'windows' -or $def.Kind -eq 'mod')) { $why = ' (a PC with Modern Standby may offer only Balanced)' }
        if ($def.Kind -eq 'file') { throw ('Windows did not import {0} and did not make a copy of High Performance or Balanced for it either, so nothing was changed' -f $def.Name) }
        throw ('Windows did not create the {0}{1}, so nothing was changed' -f (Plan-Label $def.Name), $why)
    }
    if ($mine -and $g -ne [string]$def.Guid) { $mine.New = $g }
    Say ('  the {0} is installed ({1}); the active plan is unchanged' -f (Plan-Label $def.Name), $g) 'DarkGray'
}
# The plan that is made active when the active one is deleted
function Plan-Fallback {
    param($rest)
    foreach ($g in $script:BalancedTemplate, $script:HighPerfTemplate, $script:UltimateTemplate) { foreach ($x in @($rest)) { if ($x.Guid -eq $g) { return $x } } }
    return @($rest)[0]
}
function Plan-Remove {
    param([string]$Key, $mine)
    $def = $script:PlanDefs[$Key]
    $plans = @(Pwr-Plans)
    $at = @(Plan-Where $Key $mine $plans)
    if ($at.Count -eq 0) { Say ('  the {0} is not installed: nothing to delete' -f (Plan-Label $def.Name)) 'DarkGray'; return }
    $rest = @($plans | Where-Object { $at -notcontains [string]$_.Guid })
    if ($rest.Count -eq 0) { throw ('{0} is the only power plan on this PC and one plan must stay, so it was not deleted' -f $def.Name) }
    $act = Pwr-Active
    $to = $null; if ($at -contains [string]$act.Guid) { $to = Plan-Fallback $rest }
    if ($DryRun) {
        if ($to) { Say ('  [dry] make {0} the active plan, then delete the {1}' -f $to.Name, (Plan-Label $def.Name)) 'DarkGray' }
        else { Say ('  [dry] delete the {0}' -f (Plan-Label $def.Name)) 'DarkGray' }
        return
    }
    if ($to) {
        [void](Pwr '/setactive' ([string]$to.Guid))
        if ((Pwr-Active).Guid -ne [string]$to.Guid) { throw ('{0} is the active plan and Windows did not switch to {1} first, so it was not deleted' -f $def.Name, $to.Name) }
        Say ('  {0} is the active plan now' -f $to.Name) 'DarkGray'
    }
    foreach ($g in $at) { [void](Pwr '/delete' $g) }
    if (@(Plan-Where $Key $mine).Count) { throw ('Windows did not delete the {0}' -f (Plan-Label $def.Name)) }
    Say ('  the {0} was deleted' -f (Plan-Label $def.Name)) 'DarkGray'
}
# "Reinstall" on the card of an installed plan: the plan is made again the way Headroom installs it (Windows' own plans as Windows ships
# them, the others from their built-in plan files), so whatever was changed inside it is gone. Balanced and High Performance: Windows' own
# "Restore plan defaults" is asked first, which keeps the plan where it is. Otherwise the plan is deleted and installed again, and only after
# Headroom has made sure it can be made again (Windows keeps defaults for Balanced and High Performance; Windows makes Ultimate Performance,
# tried under a spare ID that is deleted again; the plan file is intact). The active plan is the active plan again afterwards.
function Plan-Reinstall {
    param($t)
    $Key = [string]$t.Plan
    $def = $script:PlanDefs[$Key]
    $s0 = (Get-Store)[[string]$t.Id]; $mine = $null; if ($s0 -and $s0.Custom) { $mine = $s0.Custom[$Key] }
    $plans = @(Pwr-Plans)
    $at = @(Plan-Where $Key $mine $plans)
    if ($at.Count -eq 0) { throw ('the {0} is not installed: switch it on first' -f (Plan-Label $def.Name)) }
    $act = [string](Pwr-Active).Guid
    $wasActive = ($at -contains $act)
    $std = ($Key -eq 'PlanBalanced' -or $Key -eq 'PlanHighPerf')
    if ($DryRun) { Say ('  [dry] make the {0} again the way Headroom installs it (it stays the active plan if it is)' -f (Plan-Label $def.Name)) 'DarkGray'; return }
    $n0 = $Error.Count
    if ($std -and $at.Count -eq 1 -and [string]$at[0] -eq [string]$def.Guid) {
        if ((Pwr-RestoreDefault ([string]$def.Guid)) -eq 0 -and (Plan-Find ([string]$def.Guid))) {
            Say ('  Windows restored the {0} to its own defaults ("Restore plan defaults"); the plan stayed where it is' -f (Plan-Label $def.Name)) 'DarkGray'
            Plan-CheckDefaults $Key ([string]$def.Guid)
            Drop-ErrorsSince $n0
            $script:RunResult = ('{0} was reset to Windows'' own defaults' -f $def.Name)
            return
        }
    }
    # before anything is deleted: can it be made again?
    if ($std -and @(Plan-WindowsDefaults ([string]$def.Guid)).Count -lt 20) {
        throw ('Windows did not restore it and keeps no default values for the {0} on this PC to make it again from, so it was left as it is' -f (Plan-Label $def.Name))
    }
    if ($Key -eq 'Ultimate' -or $def.Kind -eq 'mod') {
        $probe = Pwr-NewFrom $script:UltimateTemplate
        if (-not $probe -or -not (Plan-Find $probe)) { Drop-ErrorsSince $n0; throw 'Windows would not make the Ultimate Performance plan again on this PC, so it was left as it is' }
        [void](Pwr '/delete' $probe)
    }
    if ($def.Kind -eq 'file') { [void](Get-BuiltinPlanBytes $Key) }        # (throws when the built-in plan file is not intact)
    if (@($plans | Where-Object { $at -notcontains [string]$_.Guid }).Count -eq 0) {
        throw ('{0} is the only power plan on this PC, so it cannot be taken off to be made again' -f $def.Name)
    }
    Drop-ErrorsSince $n0
    Plan-Remove $Key $mine
    $made = $false; $err = ''; $through = $false
    try {
        foreach ($k in 1, 2) { try { Invoke-TweakApply $t; $made = $true; break } catch { if (-not $err) { $err = $_.Exception.Message } } }
        $through = $true
    } finally {
        # stopped half-way (the old plan deleted, the new one not made yet): one more try, so the PC is not left without it
        if (-not $through) { try { if (@(Plan-Where $Key $null).Count -eq 0) { Invoke-TweakApply $t } } catch { } }
    }
    if (-not $made) { throw ('the old {0} was deleted, but making it again failed: {1}. Switch it on to try once more' -f (Plan-Label $def.Name), $err) }
    $s1 = (Get-Store)[[string]$t.Id]; $mine1 = $null; if ($s1 -and $s1.Custom) { $mine1 = $s1.Custom[$Key] }
    $new = @(Plan-Where $Key $mine1)
    if ($new.Count -eq 0) { throw ('the old {0} was deleted, and Windows did not make it again. Switch it on to try once more' -f (Plan-Label $def.Name)) }
    $script:RunResult = ('{0} was reinstalled' -f $def.Name)
    if ($wasActive) {
        [void](Pwr '/setactive' ([string]$new[0]))
        if ((Pwr-Active).Guid -eq [string]$new[0]) { Say ('  {0} is the active plan again' -f $def.Name) 'DarkGray'; $script:RunResult += ' and is the active plan again' }
        else { Say ('  ! Windows did not make {0} the active plan again: "Make active" on its card does' -f $def.Name) 'Yellow'; $script:RunResult += ' (it is not the active plan now)' }
    }
}
function Plan-Activate {
    param([string]$Key, $mine)
    $def = $script:PlanDefs[$Key]
    $at = @(Plan-Where $Key $mine)
    if ($at.Count -eq 0) { throw ('the {0} is not installed: switch it on first' -f (Plan-Label $def.Name)) }
    $g = [string]$at[0]
    if ((Pwr-Active).Guid -eq $g) { $script:RunResult = ('{0} is already the active plan' -f $def.Name); return }
    if ($DryRun) { Say ('  [dry] make {0} the active plan' -f $def.Name) 'DarkGray'; return }
    [void](Pwr '/setactive' $g)
    if ((Pwr-Active).Guid -ne $g) { throw ('Windows did not make {0} the active plan' -f $def.Name) }
    Say ('  {0} is now the active plan' -f $def.Name) 'DarkGray'
    $script:RunResult = ('{0} is now the active plan' -f $def.Name)
}
function Custom-PlanBalanced-Detect   { param($p) return (Plan-Detect 'PlanBalanced') }
function Custom-PlanBalanced-Snapshot { param($p) return (Plan-Snapshot 'PlanBalanced') }
function Custom-PlanBalanced-Apply    { param($p, $mine) Plan-Install 'PlanBalanced' $mine }
function Custom-PlanBalanced-Revert   { param($p, $mine) Plan-Remove 'PlanBalanced' $mine }
function Custom-PlanHighPerf-Detect   { param($p) return (Plan-Detect 'PlanHighPerf') }
function Custom-PlanHighPerf-Snapshot { param($p) return (Plan-Snapshot 'PlanHighPerf') }
function Custom-PlanHighPerf-Apply    { param($p, $mine) Plan-Install 'PlanHighPerf' $mine }
function Custom-PlanHighPerf-Revert   { param($p, $mine) Plan-Remove 'PlanHighPerf' $mine }
function Custom-Ultimate-Detect       { param($p) return (Plan-Detect 'Ultimate') }
function Custom-Ultimate-Snapshot     { param($p) return (Plan-Snapshot 'Ultimate') }
function Custom-Ultimate-Apply        { param($p, $mine) Plan-Install 'Ultimate' $mine }
function Custom-Ultimate-Revert       { param($p, $mine) Plan-Remove 'Ultimate' $mine }
function Custom-UltimateMod-Detect    { param($p) return (Plan-Detect 'UltimateMod') }
function Custom-UltimateMod-Snapshot  { param($p) return (Plan-Snapshot 'UltimateMod') }
function Custom-UltimateMod-Apply     { param($p, $mine) Plan-Install 'UltimateMod' $mine }
function Custom-UltimateMod-Revert    { param($p, $mine) Plan-Remove 'UltimateMod' $mine }
function Custom-Khorvie-Detect        { param($p) return (Plan-Detect 'Khorvie') }
function Custom-Khorvie-Snapshot      { param($p) return (Plan-Snapshot 'Khorvie') }
function Custom-Khorvie-Apply         { param($p, $mine) Plan-Install 'Khorvie' $mine }
function Custom-Khorvie-Revert        { param($p, $mine) Plan-Remove 'Khorvie' $mine }
function Custom-LowLatency-Detect     { param($p) return (Plan-Detect 'LowLatency') }
function Custom-LowLatency-Snapshot   { param($p) return (Plan-Snapshot 'LowLatency') }
function Custom-LowLatency-Apply      { param($p, $mine) Plan-Install 'LowLatency' $mine }
function Custom-LowLatency-Revert     { param($p, $mine) Plan-Remove 'LowLatency' $mine }

function Custom-Hibernate-Detect { param($p) return 'Skip' }
function Custom-Hibernate-Apply {
    param($p, $mine)
    if ($DryRun) { Say '  [dry] powercfg /h off' 'DarkGray'; return }
    [void](Pwr '/h' 'off'); Say '  powercfg /h off  (hibernation and Fast Startup)' 'DarkGray'
}
function Custom-Hibernate-Revert {
    param($p, $mine)
    if ($DryRun) { Say '  [dry] powercfg /h on' 'DarkGray'; return }
    [void](Pwr '/h' 'on'); Say '  powercfg /h on  (hibernation back)' 'DarkGray'
}

# ------------------------------------------------- comparing the power plans (read only) ----
# What the "Compare Power Plans" window on the Power page shows: the six plans side by side, every value the plugged-in (AC) one. A plan
# that is installed is read from this PC with "powercfg /qh <plan>", which only reads (and also lists the settings Windows hides). A plan
# that is not installed shows what it would bring: Khorvie's and the Low Latency Power Plan from their built-in plan files, Windows' own plans only where their
# behaviour is documented, and "Windows default" for the rest. Nothing here changes anything.
$script:PlanCmpRows = @(
    @{ Id = 'min';   Group = 'Processor'; Name = 'Minimum processor state'; Hint = 'How low the CPU may clock when idle'; Set = '893dee8e-2bef-41e0-89c6-b55d0929964c' }
    @{ Id = 'park';  Group = 'Processor'; Name = 'Core parking'; Hint = 'Idle cores put to sleep'; Set = '0cc5b647-c1df-4637-891a-dec35c318583' }
    @{ Id = 'boost'; Group = 'Processor'; Name = 'Boost mode'; Hint = 'How eagerly the CPU boosts'; Set = 'be337238-0d82-4146-a960-4f3749d470c7' }
    @{ Id = 'epp';   Group = 'Processor'; Name = 'Energy performance preference'; Hint = '0 = speed first, 100 = power first'; Set = '36687f9e-e3a5-4dbf-b1dc-15eb381c6863' }
    @{ Id = 'ramp';  Group = 'Processor'; Name = 'Ramp-up policy'; Hint = 'How fast clocks rise under load'; Set = '465e1f50-b610-473a-ab58-00d1077dc418' }
    @{ Id = 'incdec'; Group = 'Processor'; Name = 'Clock-change thresholds'; Hint = 'Core load that raises / lowers clocks'; Set = '06cadf0e-64ed-448a-8927-ce7bf90eb35d'; Set2 = '12a0ab44-fe28-4fa9-b3bd-4b64f44960a6' }
    @{ Id = 'thr';   Group = 'Processor'; Name = 'Throttle states'; Hint = 'Clock-modulation power saving'; Set = '3b04d4fd-1cc7-4f23-ab1c-d1337819c4bb' }
    @{ Id = 'idle';  Group = 'Processor'; Name = 'CPU idle states'; Hint = 'C-states when a core has nothing to do'; Set = '5d76a2ca-e8c0-402f-a133-2158492d58ad' }
    @{ Id = 'idlepd'; Group = 'Processor'; Name = 'Idle promote / demote'; Hint = 'Thresholds for deeper / lighter C-states'; Set = '7b224883-b3cc-4d79-819f-8374152cbe7c'; Set2 = '4b92d758-5a24-4851-a470-815d78aee119' }
    @{ Id = 'irq';   Group = 'Processor'; Name = 'Interrupt steering'; Hint = 'Where device interrupts go'; Set = '2bfc24f9-5ea2-4801-8213-3dbae01aa39d' }
    @{ Id = 'usbss'; Group = 'Devices and drives'; Name = 'USB selective suspend'; Hint = 'Idle USB devices powered down'; Set = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226' }
    @{ Id = 'usb3';  Group = 'Devices and drives'; Name = 'USB 3 link power management'; Hint = 'Low-power link states on USB 3'; Set = 'd4e98f31-5ffe-4ce1-be31-1b38b384c009' }
    @{ Id = 'aspm';  Group = 'Devices and drives'; Name = 'PCI Express link power'; Hint = 'ASPM on the GPU and NVMe links'; Set = 'ee12f906-d277-404b-b6da-e5fa1a576df5' }
    @{ Id = 'wifi';  Group = 'Devices and drives'; Name = 'Wi-Fi adapter power saving'; Hint = 'Wireless power-saving mode'; Set = '12bbebe6-58d6-4636-95bb-3217ef867c1a' }
    @{ Id = 'nvme';  Group = 'Devices and drives'; Name = 'NVMe idle timeout'; Hint = 'Idle time before low-power states'; Set = 'd639518a-e56d-4345-8af2-b9f32fb26109' }
    @{ Id = 'disk';  Group = 'Devices and drives'; Name = 'Turn off hard disk after'; Hint = 'Drive power-down'; Set = '6738e2c4-e8a5-4a42-b16a-e040e769756e' }
    @{ Id = 'disp';  Group = 'Display, sleep and wake'; Name = 'Turn off display after'; Hint = 'Screen timeout'; Set = '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e' }
    @{ Id = 'sleep'; Group = 'Display, sleep and wake'; Name = 'Sleep'; Hint = 'When the PC goes to sleep on its own'; Set = '29f6c1db-86da-48c5-9fdb-f2b67b1f44da'; Set2 = 'abfc2519-3608-4c2a-94ea-171b0ed546ab' }
    @{ Id = 'wake';  Group = 'Display, sleep and wake'; Name = 'Wake timers'; Hint = 'Scheduled tasks waking the PC'; Set = 'bd3b718a-0680-4d9d-8ab2-e1d2b4ac806d' }
)
# What a plan that is not installed would bring. A number is the setting's index as powercfg shows it, 'unset' = the plan file does not
# include it (Windows then uses its own default), a hashtable is a fixed text, and a row that is left out is Windows' default. Sleep is
# @(timeout in seconds, "allow standby states"), -1 / 'unset' = not in the file. Khorvie's and Low Latency come from their plan files; Windows' own plans
# only where Microsoft documents them (High Performance and Ultimate keep the processor at its highest state with every core unparked).
$script:PlanCmpRef = @{
    PlanBalanced = @{ min = 5; park = @{ T = 'On: idle cores park'; K = 'save' }; idle = 0; usbss = 1; disk = 1200; sleep = @{ T = 'Allowed'; K = 'def' } }
    PlanHighPerf = @{ min = 100; park = 100; idle = 0; usbss = 1; disk = 1200; sleep = @{ T = 'Allowed'; K = 'def' } }
    Ultimate     = @{ min = 100; park = 100; idle = 0; disk = 0; sleep = @{ T = 'Allowed'; K = 'def' } }
    UltimateMod  = @{ min = 100; park = 100; idle = 0; usbss = 0; usb3 = 0; wifi = 0; disk = 0; sleep = @{ T = 'Allowed'; K = 'def' } }
    Khorvie      = @{ min = 100; park = 'unset'; boost = 2; epp = 'unset'; ramp = 2; incdec = @(100, 100); thr = 0; idle = 0; idlepd = @(100, 100); irq = 6; usbss = 0; usb3 = 0; aspm = 'unset'; wifi = 'unset'; nvme = 'unset'; disk = 0; disp = 0; sleep = @(-1, 1); wake = 0 }
    LowLatency   = @{ min = 'unset'; park = 'unset'; boost = 'unset'; epp = 'unset'; ramp = 'unset'; incdec = @(1, 1); thr = 0; idle = 'unset'; idlepd = @(100, 100); irq = 3; usbss = 0; usb3 = 0; aspm = 'unset'; wifi = 'unset'; nvme = 60000; disk = 0; disp = 0; sleep = @(-1, 'unset'); wake = 0 }
}
$script:PlanCmpBy = @{
    PlanBalanced = 'Microsoft'; PlanHighPerf = 'Microsoft'; Ultimate = 'Microsoft'; UltimateMod = 'Microsoft + Headroom'
    Khorvie = 'Khorvie (third party)'; LowLatency = 'Amit (third party)'
}
# The plugged-in value of every setting in "powercfg /q(h)" output: setting ID -> number. The words around the numbers are in the language of
# Windows, so the lines are told apart by their place: the plan's line, then a subgroup a little further in, then each setting further in
# again; a setting's own "current" lines are as far in as the setting's ID line (AC first, then DC), its range lines are further in.
function Pwr-ParseQuery {
    param([string]$Text, [switch]$Both)
    $o = @{}
    $subInd = -1; $setInd = -1; $cur = ''; $vals = @()
    foreach ($ln in ($Text -split "`r?`n")) {
        if (-not $ln.Trim()) { continue }
        $ind = $ln.Length - $ln.TrimStart().Length
        $m = [regex]::Match($ln, $script:GuidRx)
        if ($m.Success) {
            if ($cur -and $vals.Count) { if ($Both) { $o[$cur] = $vals } else { $o[$cur] = $vals[0] } }
            $cur = ''; $vals = @()
            if ($subInd -lt 0 -or $ind -le $subInd) {
                if ($ind -gt 0) { $subInd = $ind }                     # (the plan's own line is the one at the left edge)
            } else {
                $setInd = $ind; $cur = $m.Value.ToLower()
            }
            continue
        }
        if ($cur -and $ind -eq $setInd) {
            $h = [regex]::Match($ln, ':\s*0x([0-9a-fA-F]+)\s*$')
            if ($h.Success) { $vals += [Convert]::ToInt64($h.Groups[1].Value, 16) }
        }
    }
    if ($cur -and $vals.Count) { if ($Both) { $o[$cur] = $vals } else { $o[$cur] = $vals[0] } }
    return $o
}
function PlanCmp-Time {
    param([int64]$s)
    if ($s % 3600 -eq 0 -and $s -ge 3600) { return ('{0} h' -f ($s / 3600)) }
    if ($s % 60 -eq 0) { return ('{0} min' -f ($s / 60)) }
    return ('{0} s' -f $s)
}
# One cell: @{ T = the text; K = speed | save | block | none | def (Windows' default) | unset (not in the plan, or not listed) }
function PlanCmp-Cell {
    param([string]$Id, $v, $v2 = $null)
    if ($v -is [hashtable]) { return $v }
    if ($Id -eq 'sleep') {
        if ($null -ne $v2 -and [string]$v2 -ne 'unset' -and [int64]$v2 -eq 0) { return @{ T = 'Blocked (sleep states off)'; K = 'block' } }
        if ($null -eq $v -or [string]$v -eq 'unset' -or [int64]$v -lt 0) { return @{ T = 'Allowed'; K = 'def' } }
        if ([int64]$v -eq 0) { return @{ T = 'Never on its own'; K = 'none' } }
        return @{ T = ('After ' + (PlanCmp-Time ([int64]$v))); K = 'save' }
    }
    if ($Id -eq 'incdec' -or $Id -eq 'idlepd') {
        $u1 = ($null -eq $v -or [string]$v -eq 'unset'); $u2 = ($null -eq $v2 -or [string]$v2 -eq 'unset')
        if ($u1 -and $u2) { if ([string]$v -eq 'unset' -or [string]$v2 -eq 'unset') { return @{ T = 'Not set'; K = 'unset' } }; return @{ T = 'Windows default'; K = 'def' } }
        $a = '-'; if (-not $u1) { $a = ('{0}%' -f [int64]$v) }
        $b = '-'; if (-not $u2) { $b = ('{0}%' -f [int64]$v2) }
        if ($Id -eq 'incdec') {
            $k = 'none'; if (-not $u1 -and [int64]$v -le 10) { $k = 'speed' }
            return @{ T = ('Up above {0}, down below {1}' -f $a, $b); K = $k }
        }
        return @{ T = ('Promote {0}, demote {1}' -f $a, $b); K = 'none' }
    }
    if ([string]$v -eq 'unset') { return @{ T = 'Not set'; K = 'unset' } }
    if ($null -eq $v) { return @{ T = 'Windows default'; K = 'def' } }
    $n = [int64]$v
    switch ($Id) {
        'min'   { if ($n -ge 100) { return @{ T = '100%'; K = 'speed' } }; return @{ T = ('{0}%' -f $n); K = 'save' } }
        'park'  { if ($n -ge 100) { return @{ T = 'Off: all cores unparked'; K = 'speed' } }; return @{ T = ('On: {0}% of cores stay unparked' -f $n); K = 'save' } }
        'boost' {
            $nm = @('Disabled', 'Enabled', 'Aggressive', 'Efficient Enabled', 'Efficient Aggressive', 'Aggressive At Guaranteed', 'Efficient Aggressive At Guaranteed')
            $t = ('Mode {0}' -f $n); if ($n -ge 0 -and $n -lt $nm.Count) { $t = $nm[$n] }
            $k = 'none'; if ($n -eq 2 -or $n -eq 5) { $k = 'speed' } elseif ($n -eq 0) { $k = 'save' }
            return @{ T = $t; K = $k }
        }
        'epp'   { if ($n -eq 0) { return @{ T = '0 (speed first)'; K = 'speed' } }; $k = 'none'; if ($n -ge 50) { $k = 'save' }; return @{ T = [string]$n; K = $k } }
        'ramp'  {
            $nm = @('Ideal', 'Single step', 'Rocket (straight to the top)', 'Ideal Aggressive')
            $t = ('Policy {0}' -f $n); if ($n -ge 0 -and $n -lt $nm.Count) { $t = $nm[$n] }
            $k = 'none'; if ($n -eq 2) { $k = 'speed' }
            return @{ T = $t; K = $k }
        }
        'thr'   { if ($n -eq 0) { return @{ T = 'Off'; K = 'speed' } }; if ($n -eq 1) { return @{ T = 'On'; K = 'save' } }; return @{ T = 'Automatic'; K = 'none' } }
        'idle'  { if ($n -eq 0) { return @{ T = 'Allowed'; K = 'none' } }; return @{ T = 'Off: cores never idle'; K = 'speed' } }
        'irq'   {
            $nm = @('Default', 'Any processor', 'Any unparked processor, with delay', 'Any unparked processor', 'Lock interrupt routing', 'Processor 0', 'Processor 1')
            if ($n -eq 0) { return @{ T = 'Default'; K = 'none' } }
            $t = ('Mode {0}' -f $n); if ($n -gt 0 -and $n -lt $nm.Count) { $t = ('Mode {0}: {1}' -f $n, $nm[$n].ToLower()) }
            return @{ T = $t; K = 'none' }
        }
        'usbss' { if ($n -eq 0) { return @{ T = 'Off'; K = 'speed' } }; return @{ T = 'On'; K = 'save' } }
        'usb3'  { $nm = @('Off', 'Minimum power savings', 'Moderate power savings', 'Maximum power savings'); $t = ('Level {0}' -f $n); if ($n -ge 0 -and $n -lt $nm.Count) { $t = $nm[$n] }; if ($n -eq 0) { return @{ T = $t; K = 'speed' } }; return @{ T = $t; K = 'save' } }
        'aspm'  { $nm = @('Off', 'Moderate power savings', 'Maximum power savings'); $t = ('Level {0}' -f $n); if ($n -ge 0 -and $n -lt $nm.Count) { $t = $nm[$n] }; if ($n -eq 0) { return @{ T = $t; K = 'speed' } }; return @{ T = $t; K = 'save' } }
        'wifi'  { $nm = @('Maximum performance', 'Low power saving', 'Medium power saving', 'Maximum power saving'); $t = ('Level {0}' -f $n); if ($n -ge 0 -and $n -lt $nm.Count) { $t = $nm[$n] }; if ($n -eq 0) { return @{ T = $t; K = 'speed' } }; return @{ T = $t; K = 'save' } }
        'nvme'  { if ($n -ge 1000 -and $n % 1000 -eq 0) { return @{ T = ('{0} s' -f ($n / 1000)); K = 'none' } }; return @{ T = ('{0} ms' -f $n); K = 'none' } }
        'disk'  { if ($n -eq 0) { return @{ T = 'Never'; K = 'speed' } }; return @{ T = (PlanCmp-Time $n); K = 'save' } }
        'disp'  { if ($n -eq 0) { return @{ T = 'Never'; K = 'speed' } }; return @{ T = (PlanCmp-Time $n); K = 'none' } }
        'wake'  { if ($n -eq 0) { return @{ T = 'Off'; K = 'speed' } }; if ($n -eq 2) { return @{ T = 'Important ones only'; K = 'none' } }; return @{ T = 'On'; K = 'none' } }
    }
    return @{ T = [string]$n; K = 'none' }
}
# The six plans: Key, Name, By, Guid, Installed, Active, Source (pc = read from this PC, file = from its built-in plan file, ref = documented
# values, unread = installed but Windows listed none of its settings) and Cells (row id -> cell). Only reads: powercfg /list and /qh.
function Get-PlanCompare {
    $plans = @(Pwr-Plans)
    $act = ''; foreach ($x in $plans) { if ($x.Active) { $act = [string]$x.Guid } }
    $store = $null; try { $store = Get-Store } catch { }
    $out = @()
    foreach ($key in @($script:PlanDefs.Keys)) {
        $def = $script:PlanDefs[$key]
        $mine = $null
        foreach ($t in @($script:Catalog | Where-Object { [string]$_.Plan -eq $key })) {
            if ($store -and $store.ContainsKey([string]$t.Id) -and $store[[string]$t.Id].Custom) { $mine = $store[[string]$t.Id].Custom[$key] }
        }
        $at = @(Plan-Where $key $mine $plans)
        $p = [ordered]@{ Key = [string]$key; Name = [string]$def.Name; By = [string]$script:PlanCmpBy[$key]; Guid = [string]$def.Guid; Installed = ($at.Count -gt 0); Active = $false; Source = ''; Cells = @{}; Check = $null }
        $std = ($key -eq 'PlanBalanced' -or $key -eq 'PlanHighPerf')
        if ($at.Count) {
            $g = [string]$at[0]
            $p.Guid = $g; $p.Active = ($g -eq $act)
            $both = @{}; try { $both = Pwr-ParseQuery (Pwr '/qh' $g) -Both } catch { }
            $vals = @{}; foreach ($k in @($both.Keys)) { $vals[$k] = @($both[$k])[0] }
            if ($vals.Count -eq 0) { $p.Source = 'unread' } else { $p.Source = 'pc' }
            foreach ($r in $script:PlanCmpRows) {
                if ($p.Source -eq 'unread') { $p.Cells[$r.Id] = @{ T = 'Could not be read'; K = 'unset' }; continue }
                $v = $null; if ($vals.ContainsKey([string]$r.Set)) { $v = $vals[[string]$r.Set] }
                $v2 = $null; if ($r.Set2 -and $vals.ContainsKey([string]$r.Set2)) { $v2 = $vals[[string]$r.Set2] }
                if ($null -eq $v -and $null -eq $v2 -and $r.Id -ne 'sleep') { $p.Cells[$r.Id] = @{ T = 'Not listed by Windows'; K = 'unset' }; continue }
                $p.Cells[$r.Id] = PlanCmp-Cell ([string]$r.Id) $v $v2
            }
            # Balanced and High Performance: are they as Windows ships them? (compared with the defaults Windows keeps for them)
            if ($std -and $p.Source -eq 'pc') { $d = $null; try { $d = Plan-DefaultsDiff $key $g $both } catch { }; if ($d -and $d.Checked -gt 0) { $p.Check = @{ Checked = [int]$d.Checked; Diff = @($d.Diff).Count } } }
            $out += ,$p
            continue
        }
        # Balanced and High Performance that are not installed: the defaults Windows keeps for them on this PC, when it keeps them
        $wd = @(); if ($std) { try { $wd = @(Plan-WindowsDefaults ([string]$def.Guid)) } catch { } }
        if ($wd.Count -ge 20) {
            $p.Source = 'defaults'
            $byS = @{}; foreach ($s in $wd) { $byS[[string]$s.Set] = $s.AC }
            foreach ($r in $script:PlanCmpRows) {
                $v = $null; $v2 = $null
                if ($byS.ContainsKey([string]$r.Set)) { $v = $byS[[string]$r.Set] }
                if ($r.Set2 -and $byS.ContainsKey([string]$r.Set2)) { $v2 = $byS[[string]$r.Set2] }
                if ($null -eq $v -and $null -eq $v2 -and $r.Id -ne 'sleep') { $p.Cells[$r.Id] = @{ T = 'Windows default'; K = 'def' }; continue }
                $p.Cells[$r.Id] = PlanCmp-Cell ([string]$r.Id) $v $v2
            }
        } else {
            $p.Source = 'ref'; if ($def.Kind -eq 'file') { $p.Source = 'file' }
            $ref = $script:PlanCmpRef[$key]
            foreach ($r in $script:PlanCmpRows) {
                $v = $null; $v2 = $null
                if ($ref -and $ref.ContainsKey([string]$r.Id)) {
                    $x = $ref[[string]$r.Id]
                    if ($r.Set2 -and $x -is [array]) { $v = $x[0]; $v2 = $x[1] } else { $v = $x }
                }
                $p.Cells[$r.Id] = PlanCmp-Cell ([string]$r.Id) $v $v2
            }
        }
        $out += ,$p
    }
    return $out
}

# -------------------------------------------------------- USB devices --------
function Usb-Devices {
    if (-not $script:Cache.ContainsKey('usb')) {
        $seen = @{}; $l = @()
        $pre = Pre-Wait 'usb'
        if ($null -ne $pre) {
            foreach ($d in $pre) {
                $id = [string]$d.I
                if ($id -and -not $seen.ContainsKey($id)) { $seen[$id] = 1; $l += ,@{ Id = $id; Name = [string]$d.N } }
            }
        } else {
            $all = @(Get-PnpDevice -Class USB -ErrorAction Ignore) + @(Get-PnpDevice -ErrorAction Ignore | Where-Object { $_.InstanceId -like 'USB\*' })
            foreach ($d in $all) {
                $id = [string]$d.InstanceId
                if ($id -and -not $seen.ContainsKey($id)) { $seen[$id] = 1; $l += ,@{ Id = $id; Name = [string]$d.FriendlyName } }
            }
        }
        $script:Cache['usb'] = $l
    }
    return $script:Cache['usb']
}
# "Allow the computer to turn off this device to save power" (the live switch behind the Device Manager checkbox)
function Pm-List {
    if ($script:ScanMode) { $x = Net-Pre; if ($x -and $x.Pm.Count -gt 0) { return $x.Pm } }
    Scan-Memo 'pm' {
        $out = @()
        foreach ($i in @(Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -ErrorAction Ignore)) {
            $out += ,@{ Id = ([string]$i.InstanceName -replace '_\d+$', ''); Enable = [bool]$i.Enable }
        }
        return $out
    }
}
function Pm-Set {
    param([string]$id, [bool]$enable)
    if ($DryRun) { return }
    foreach ($i in @(Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -ErrorAction Ignore)) {
        if (([string]$i.InstanceName -replace '_\d+$', '') -eq $id) { $i.Enable = $enable; Set-CimInstance -InputObject $i -ErrorAction SilentlyContinue }
    }
}
$script:UsbRegNames = 'EnhancedPowerManagementEnabled', 'AllowIdleIrpInD3', 'SelectiveSuspendEnabled'
function Custom-UsbPower-Detect {
    param($p)
    $ids = @{}; foreach ($d in @(Usb-Devices)) { $ids[$d.Id] = 1 }
    $on = 0; $off = 0
    foreach ($i in @(Pm-List)) { if ($ids.ContainsKey($i.Id)) { if ($i.Enable) { $off++ } else { $on++ } } }
    if ($on + $off -eq 0) { $script:Why = 'no USB devices with power management found'; $script:Now = 'USB devices with a power saving switch: none found'; return 'NA' }
    $script:Now = ('USB devices: {0} of {1} have "allow the computer to turn off this device" switched off, wanted all' -f $on, ($on + $off))
    return (Count-State $on $off)
}
function Custom-UsbPower-Snapshot {
    param($p)
    $ids = @{}; foreach ($d in @(Usb-Devices)) { $ids[$d.Id] = 1 }
    $dev = @{}
    foreach ($i in @(Pm-List)) {
        if (-not $ids.ContainsKey($i.Id)) { continue }
        $e = @{ Enable = $i.Enable; Reg = @{} }
        foreach ($n in $script:UsbRegNames) {
            $c = Reg-Read "HKLM:\SYSTEM\CurrentControlSet\Enum\$($i.Id)\Device Parameters" $n
            $e.Reg[$n] = @{ Exists = $c.Exists; Value = $c.Value }
        }
        $dev[$i.Id] = $e
    }
    return @{ Dev = $dev }
}
function Custom-UsbPower-Apply {
    param($p, $mine)
    $ids = @{}; foreach ($d in @(Usb-Devices)) { $ids[$d.Id] = $d.Name }
    $n = 0
    foreach ($i in @(Pm-List)) {
        if (-not $ids.ContainsKey($i.Id)) { continue }
        $key = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($i.Id)\Device Parameters"
        if ($DryRun) { Say ("  [dry] {0}  [{1}]" -f $ids[$i.Id], $i.Id) 'DarkGray'; $n++; continue }
        Pm-Set $i.Id $false
        if (Fs-Exists $key) { foreach ($rn in $script:UsbRegNames) { [void](Reg-Write $key $rn 0 'DWord' -Quiet) } }
        Say ("  {0}  [{1}]" -f $ids[$i.Id], $i.Id) 'DarkGray'
        $n++
    }
    Say "  ($n USB device(s). Devices plugged in later get Windows' defaults - switch this on again after adding new ones.)" 'DarkGray'
}
function Custom-UsbPower-Revert {
    param($p, $mine)
    $ids = @{}; foreach ($d in @(Usb-Devices)) { $ids[$d.Id] = $d.Name }
    foreach ($i in @(Pm-List)) {
        if (-not $ids.ContainsKey($i.Id)) { continue }
        $key = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($i.Id)\Device Parameters"
        $s = $null; if ($mine -and $mine.Dev) { $s = $mine.Dev[$i.Id] }
        if ($DryRun) { Say ("  [dry] {0} : power saving back on" -f $ids[$i.Id]) 'DarkGray'; continue }
        # what the device had before this app first changed it: its driver can ship its own values (some USB devices need selective suspend
        # off, for example), and those are written back as they were. A device without a record gets the Windows default: "allow the
        # computer to turn off this device" on, and no value of ours left in the device's settings.
        $en = $true; if ($s -and $null -ne $s.Enable) { $en = [bool]$s.Enable }
        Pm-Set $i.Id $en
        if (Fs-Exists $key) {
            foreach ($rn in $script:UsbRegNames) {
                $o = $null; if ($s -and $s.Reg) { $o = $s.Reg[$rn] }
                if ($o -and $o.Exists -and $null -ne $o.Value) { [void](Reg-Write $key $rn ([int64]$o.Value) 'DWord' -Quiet) } else { [void](Reg-Remove $key $rn -Quiet) }
            }
        }
        Say ("  {0} : power saving back to the Windows default" -f $ids[$i.Id]) 'DarkGray'
    }
}

# ------------------------------------------------- network adapters ---------
# What the background work found out about the network adapters (see Start-Prefetch), or $null: then every
# question is asked in place.
function Net-Pre {
    if (-not $script:Cache.ContainsKey('netpre')) {
        $r = $null
        $pre = Pre-Wait 'net'
        if ($null -ne $pre) {
            $nic = @(); $pm = @(); $adv = @{}; $npm = @{}
            foreach ($x in $pre) {
                switch ([string]$x.K) {
                    'nic' { $nic += ,@{ Name = [string]$x.A; Desc = [string]$x.D; Guid = [string]$x.G; PnpId = [string]$x.P } }
                    'pm'  { $pm += ,@{ Id = ([string]$x.I -replace '_\d+$', ''); Enable = [bool]$x.E } }
                    'adv' {
                        $an = [string]$x.A
                        if (-not $adv.ContainsKey($an)) { $adv[$an] = @() }
                        $adv[$an] += ,@{ DisplayName = [string]$x.N; DisplayValue = [string]$x.V; Keyword = [string]$x.W; RegValue = [string]$x.R; Valid = @($x.L) }
                    }
                    'npm' { $npm[[string]$x.A] = @{ SelectiveSuspend = [string]$x.S; DeviceSleepOnDisconnect = [string]$x.D; TurnOff = [string]$x.T } }
                }
            }
            $r = @{ Nic = $nic; Pm = $pm; Adv = $adv; Npm = $npm }
        }
        $script:Cache['netpre'] = $r
    }
    return $script:Cache['netpre']
}
function Nic-List {
    if ($script:ScanMode) { $x = Net-Pre; if ($x -and $x.Nic.Count -gt 0) { return $x.Nic } }
    Scan-Memo 'nic' {
        $out = @()
        foreach ($n in @(Get-NetAdapter -Physical -ErrorAction Ignore)) {
            $out += ,@{ Name = [string]$n.Name; Desc = [string]$n.InterfaceDescription; Guid = [string]$n.InterfaceGuid; PnpId = [string]$n.PnPDeviceID }
        }
        return $out
    }
}
function Nic-ClassKey {
    param([string]$guid)
    $root = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'
    foreach ($k in @(Reg-SubKeys $root)) {
        $v = Reg-Read $k 'NetCfgInstanceId'
        if ($v.Exists -and [string]$v.Value -eq $guid) { return $k }
    }
    return ''
}
function Nic-PmRead {
    param([string]$name)
    if ($script:ScanMode) { $x = Net-Pre; if ($x -and $x.Npm.ContainsKey($name)) { return $x.Npm[$name] } }
    $r = Get-NetAdapterPowerManagement -Name $name -ErrorAction Ignore
    if (-not $r) { return $null }
    return @{ SelectiveSuspend = [string]$r.SelectiveSuspend; DeviceSleepOnDisconnect = [string]$r.DeviceSleepOnDisconnect; TurnOff = [string]$r.AllowComputerToTurnOffDevice }
}
# "Allow the computer to turn off this device to save power" through Windows' own network adapter settings (what Device Manager's box
# shows on Windows 11): the adapter's power settings are read, that one is changed, and they are written back. Unless $restart, the adapter
# is not restarted (the change then counts from the next restart). Returns '' or what Windows said.
function Nic-TurnOffWrite {
    param([string]$name, [string]$value, [bool]$restart)
    if ($DryRun) { return '' }
    try {
        $r = Get-NetAdapterPowerManagement -Name $name -ErrorAction Stop
        $r.AllowComputerToTurnOffDevice = $value
        if ($restart) { $r | Set-NetAdapterPowerManagement -ErrorAction Stop } else { $r | Set-NetAdapterPowerManagement -NoRestart -ErrorAction Stop }
        return ''
    } catch { Drop-Error $_; return ([string]$_.Exception.Message -split "`r?`n")[0].Trim() }     # (the caller says it, once)
}
function Nic-PmWrite {
    param([string]$name, [string]$setting, [string]$value)
    if ($DryRun) { return }
    $pm = @{ Name = $name; NoRestart = $true; $setting = $value }   # one setting per call: an unsupported one cannot block the other
    Set-NetAdapterPowerManagement @pm -ErrorAction SilentlyContinue
}
function Nic-AdvList {
    param([string]$name)
    if ($script:ScanMode) { $x = Net-Pre; if ($x -and $x.Adv.ContainsKey($name)) { return $x.Adv[$name] } }
    Scan-Memo ('nicadv:' + $name) {
        $out = @()
        foreach ($a in @(Get-NetAdapterAdvancedProperty -Name $name -ErrorAction Ignore)) {
            $valid = @(); foreach ($v in @($a.ValidDisplayValues)) { $valid += [string]$v }
            $out += ,@{ DisplayName = [string]$a.DisplayName; DisplayValue = [string]$a.DisplayValue; Keyword = [string]$a.RegistryKeyword; RegValue = [string](@($a.RegistryValue)[0]); Valid = $valid }
        }
        return $out
    }
}
function Nic-AdvWrite {
    param([string]$name, [string]$kind, [string]$key, [string]$value)
    if ($DryRun) { return }
    if ($kind -eq 'kw') { Set-NetAdapterAdvancedProperty -Name $name -RegistryKeyword $key -RegistryValue $value -NoRestart -ErrorAction SilentlyContinue }
    else                { Set-NetAdapterAdvancedProperty -Name $name -DisplayName $key -DisplayValue $value -NoRestart -ErrorAction SilentlyContinue }
}
# Puts one driver property back to the value its driver ships with (Windows' own reset; nothing happens for a property the driver does not list)
function Nic-AdvReset {
    param([string]$name, [string]$kind, [string]$key)
    if ($DryRun) { return }
    if ($kind -eq 'kw') { Reset-NetAdapterAdvancedProperty -Name $name -RegistryKeyword $key -NoRestart -ErrorAction SilentlyContinue }
    else                { Reset-NetAdapterAdvancedProperty -Name $name -DisplayName $key -NoRestart -ErrorAction SilentlyContinue }
}
$script:NicPowerRx = 'Energy.?Efficient|Green Ethernet|Power Sav|\bEEE\b|Ultra Low Power|Gigabit Lite|Reduce Speed|Auto Disable|Link Speed Battery'
$script:OffValueRx = '^(Disabled|Off|Maximum Performance|No|Never)$'

# 1) "Allow the computer to turn off this device to save power"
# Windows 11 keeps this box in the adapter's own power settings (Get/Set-NetAdapterPowerManagement, AllowComputerToTurnOffDevice:
# Enabled, Disabled or Unsupported). That is what is read and changed. An adapter for which Windows does not report it falls back to
# the older ways: the PnPCapabilities value Microsoft documents (KB 2740020) and the Device Manager switch behind the box (WMI).
function Nic-TurnOffState {
    # 'off' = the box is unticked, 'on' = it is ticked, '' = this adapter has no such box
    param($n, $pm)
    $r = Nic-PmRead $n.Name
    $tf = ''; if ($r) { $tf = [string]$r.TurnOff }
    if ($tf -eq 'Disabled') { return 'off' }
    if ($tf -eq 'Enabled') { return 'on' }
    $ck = Nic-ClassKey $n.Guid
    if ($ck) { $c = Reg-Read $ck 'PnPCapabilities'; if ($c.Exists -and (([int]$c.Value -band 0x10) -ne 0)) { return 'off' } }
    foreach ($i in @($pm)) { if ($i.Id -eq $n.PnpId) { if ($i.Enable) { return 'on' } else { return 'off' } } }
    return ''
}
function Custom-NicTurnOff-Detect {
    param($p)
    $pm = @(Pm-List)
    $on = 0; $off = 0
    foreach ($n in @(Nic-List)) {
        switch (Nic-TurnOffState $n $pm) { 'off' { $on++ } 'on' { $off++ } }
    }
    if ($on + $off -eq 0) { $script:Why = 'no network adapter has this power box'; $script:Now = 'Network adapters: none has an "allow the computer to turn off this device" box'; return 'NA' }
    $script:Now = ('Network adapters: {0} of {1} have "allow the computer to turn off this device" switched off, wanted all' -f $on, ($on + $off))
    return (Count-State $on $off)
}
function Custom-NicTurnOff-Snapshot {
    param($p)
    $nic = @{}
    $pm = @(Pm-List)
    foreach ($n in @(Nic-List)) {
        $e = @{ ClassKey = ''; PnPExists = $false; PnPValue = 0; Enable = $null; TurnOff = '' }
        $r = Nic-PmRead $n.Name; if ($r) { $e.TurnOff = [string]$r.TurnOff }
        $ck = Nic-ClassKey $n.Guid
        if ($ck) { $e.ClassKey = $ck; $c = Reg-Read $ck 'PnPCapabilities'; $e.PnPExists = $c.Exists; if ($c.Exists) { $e.PnPValue = [int]$c.Value } }
        foreach ($i in $pm) { if ($i.Id -eq $n.PnpId) { $e.Enable = $i.Enable } }
        $nic[$n.Guid] = $e
    }
    return @{ Nic = $nic }
}
function Custom-NicTurnOff-Apply {
    param($p, $mine)
    $pm = @(Pm-List)
    foreach ($n in @(Nic-List)) {
        Say "  $($n.Name) ($($n.Desc))" 'Gray'
        $r = Nic-PmRead $n.Name
        $tf = ''; if ($r) { $tf = [string]$r.TurnOff }
        if ($tf -eq 'Disabled') { Say '    already off' 'DarkGray'; continue }
        if ($DryRun) { Say '    [dry] power-saving box off' 'DarkGray'; continue }
        if ($tf -eq 'Enabled') {
            # the adapter restarts for a moment so the change counts at once (not over Remote Desktop: then it counts from the next restart)
            $err = Nic-TurnOffWrite $n.Name 'Disabled' (-not $script:InRdp)
            if ($err) { Say "    ! Windows did not change it: $err" 'Yellow' } else { Say '    "Allow the computer to turn off this device" is now off' 'DarkGray' }
            continue
        }
        if ((Nic-TurnOffState $n $pm) -eq '') { Say '    this adapter has no such box' 'DarkGray'; continue }
        # an adapter whose box Windows does not report: the older ways. PnPCapabilities 24 (0x18) is the value Microsoft documents for the
        # box cleared; it is OR-ed in, so a wake setting you chose (0x100) is kept.
        Pm-Set $n.PnpId $false
        $ck = Nic-ClassKey $n.Guid
        if ($ck) {
            $c = Reg-Read $ck 'PnPCapabilities'
            $cur = 0; if ($c.Exists) { $cur = [int]$c.Value }
            [void](Reg-Write $ck 'PnPCapabilities' ($cur -bor 0x18) 'DWord' -Quiet)
        }
        Say '    "Allow the computer to turn off this device" is now off (it counts from the next restart)' 'DarkGray'
    }
}
function Custom-NicTurnOff-Revert {
    param($p, $mine)
    foreach ($n in @(Nic-List)) {
        Say "  $($n.Name) ($($n.Desc))" 'Gray'
        if ($DryRun) { Say '    [dry] power-saving box back to the Windows default (on)' 'DarkGray'; continue }
        $r = Nic-PmRead $n.Name
        $tf = ''; if ($r) { $tf = [string]$r.TurnOff }
        if ($tf -eq 'Disabled') {
            $err = Nic-TurnOffWrite $n.Name 'Enabled' (-not $script:InRdp)
            if ($err) { Say "    ! Windows did not change it: $err" 'Yellow' }
        }
        $ck = Nic-ClassKey $n.Guid
        if ($ck) {
            # the two "turn off this device" bits that this app (or an older build) may have set are cleared, so a wake setting you chose
            # (0x100) is kept; with none left the value is deleted (the Windows default)
            $c = Reg-Read $ck 'PnPCapabilities'
            if ($c.Exists) {
                $v = [int]$c.Value -band (-bnot 0x18)
                if ($v -ne [int]$c.Value) { if ($v -eq 0) { [void](Reg-Remove $ck 'PnPCapabilities' -Quiet) } else { [void](Reg-Write $ck 'PnPCapabilities' $v 'DWord' -Quiet) } }
            }
        }
        Pm-Set $n.PnpId $true
        Say '    "Allow the computer to turn off this device" is back on (the Windows default)' 'DarkGray'
    }
}

# 2) Energy-Efficient Ethernet / Green Ethernet / Wi-Fi power save (driver "Advanced" tab)
function Nic-EeeProps {
    param([string]$name)
    $out = @()
    foreach ($a in @(Nic-AdvList $name)) {
        if ($a.Keyword -eq '*EEE') { $out += ,@{ Kind = 'kw'; Key = '*EEE'; Cur = $a.RegValue; Off = '0'; IsOff = ($a.RegValue -eq '0') }; continue }
        if ($a.Keyword -eq '*SelectiveSuspend' -or $a.Keyword -eq '*DeviceSleepOnDisconnect') { continue }
        if ($a.DisplayName -match $script:NicPowerRx -and $a.DisplayName -notmatch 'Selective Suspend') {
            $isOff = ($a.DisplayValue -match $script:OffValueRx)
            $target = ''; foreach ($v in $a.Valid) { if (-not $target -and $v -match $script:OffValueRx) { $target = $v } }
            if ($isOff -or $target) { $out += ,@{ Kind = 'dn'; Key = $a.DisplayName; Cur = $a.DisplayValue; Off = $target; IsOff = $isOff } }
        }
    }
    return $out
}
function Custom-NicEee-Detect {
    param($p)
    $on = 0; $off = 0
    foreach ($n in @(Nic-List)) {
        $props = @(Nic-EeeProps $n.Name)
        if ($props.Count -eq 0) { continue }
        $bad = $false; foreach ($x in $props) { if (-not $x.IsOff) { $bad = $true } }
        if ($bad) { $off++ } else { $on++ }
    }
    if ($on + $off -eq 0) { $script:Why = 'your adapters have no such driver setting'; $script:Now = 'Network adapter driver power-saving settings: none found'; return 'NA' }
    $script:Now = ('Network adapters with an energy-saving driver setting: {0} have it off, {1} have it on, wanted off' -f $on, $off)
    if ($off -gt 0) { return 'Off' }     # some drivers already default to "off", so a mixed result is not shown as partly applied
    return 'On'
}
function Custom-NicEee-Snapshot {
    param($p)
    $nic = @{}
    foreach ($n in @(Nic-List)) {
        $l = @(); foreach ($x in @(Nic-EeeProps $n.Name)) { if (-not $x.IsOff) { $l += ,@{ Kind = $x.Kind; Key = $x.Key; Cur = $x.Cur } } }
        $nic[$n.Guid] = $l
    }
    return @{ Nic = $nic }
}
function Custom-NicEee-Apply {
    param($p, $mine)
    foreach ($n in @(Nic-List)) {
        $props = @(Nic-EeeProps $n.Name)
        if ($props.Count -eq 0) { continue }
        Say "  $($n.Name) ($($n.Desc))" 'Gray'
        foreach ($x in $props) {
            if ($x.IsOff) { continue }
            Say "    $($x.Key) -> $($x.Off)" 'DarkGray'
            Nic-AdvWrite $n.Name $x.Kind $x.Key $x.Off
        }
    }
    Say '  (driver settings take effect after the restart)' 'DarkGray'
}
function Custom-NicEee-Revert {
    param($p, $mine)
    foreach ($n in @(Nic-List)) {
        $props = @(Nic-EeeProps $n.Name)
        if ($props.Count -eq 0) { continue }
        Say "  $($n.Name) ($($n.Desc))" 'Gray'
        foreach ($x in $props) {
            Say "    $($x.Key) -> the driver's default" 'DarkGray'
            Nic-AdvReset $n.Name $x.Kind $x.Key
        }
    }
    Say '  (driver settings take effect after the restart)' 'DarkGray'
}

# 3) USB adapter selective suspend + sleep-on-disconnect
function Nic-SuspendProps {
    param([string]$name)
    $out = @()
    $pm = Nic-PmRead $name
    if ($pm) {
        foreach ($s in 'SelectiveSuspend', 'DeviceSleepOnDisconnect') {
            $v = $pm[$s]
            if ($v -eq 'Enabled')  { $out += ,@{ Kind = 'pm'; Key = $s; Cur = 'Enabled'; Off = 'Disabled'; IsOff = $false } }
            if ($v -eq 'Disabled') { $out += ,@{ Kind = 'pm'; Key = $s; Cur = 'Disabled'; Off = 'Disabled'; IsOff = $true } }
        }
    }
    foreach ($a in @(Nic-AdvList $name)) {
        if ($a.Keyword -eq '*SelectiveSuspend' -or $a.Keyword -eq '*DeviceSleepOnDisconnect') {
            $out += ,@{ Kind = 'kw'; Key = $a.Keyword; Cur = $a.RegValue; Off = '0'; IsOff = ($a.RegValue -eq '0') }
        } elseif ($a.DisplayName -match 'Selective Suspend') {
            $isOff = ($a.DisplayValue -match $script:OffValueRx)
            $target = ''; foreach ($v in $a.Valid) { if (-not $target -and $v -match $script:OffValueRx) { $target = $v } }
            if ($isOff -or $target) { $out += ,@{ Kind = 'dn'; Key = $a.DisplayName; Cur = $a.DisplayValue; Off = $target; IsOff = $isOff } }
        }
    }
    return $out
}
function Nic-PropWrite {
    param([string]$name, $x, [string]$value)
    if ($x.Kind -eq 'pm') { Nic-PmWrite $name $x.Key $value } else { Nic-AdvWrite $name $x.Kind $x.Key $value }
}
# One property back to its default: the driver's own value; selective suspend, which Windows ships switched on, is switched on when the
# driver does not list it as a property of its own (the power-management switches have no reset of their own)
function Nic-PropReset {
    param([string]$name, $x)
    if ($DryRun) { return }
    if ($x.Kind -eq 'pm') {
        # only a keyword the driver lists is reset (Windows would report an error for one it does not)
        $kw = '*' + [string]$x.Key
        if (@(Nic-AdvList $name | Where-Object { $_.Keyword -eq $kw }).Count -gt 0) { Nic-AdvReset $name 'kw' $kw }
        $now = Nic-PmRead $name
        if ($now -and [string]$x.Key -eq 'SelectiveSuspend' -and [string]$now.SelectiveSuspend -eq 'Disabled') { Nic-PmWrite $name 'SelectiveSuspend' 'Enabled' }
    } else { Nic-AdvReset $name $x.Kind $x.Key }
}
function Custom-NicSuspend-Detect {
    param($p)
    $on = 0; $off = 0
    foreach ($n in @(Nic-List)) {
        $props = @(Nic-SuspendProps $n.Name)
        if ($props.Count -eq 0) { continue }
        $bad = $false; foreach ($x in $props) { if (-not $x.IsOff) { $bad = $true } }
        if ($bad) { $off++ } else { $on++ }
    }
    if ($on + $off -eq 0) { $script:Why = 'your adapters do not expose selective suspend'; $script:Now = 'Network adapter selective suspend: not offered by any adapter'; return 'NA' }
    $script:Now = ('Network adapters with selective suspend: {0} have it off, {1} have it on, wanted off' -f $on, $off)
    if ($off -gt 0) { return 'Off' }
    return 'On'
}
function Custom-NicSuspend-Snapshot {
    param($p)
    $nic = @{}
    foreach ($n in @(Nic-List)) {
        $l = @(); foreach ($x in @(Nic-SuspendProps $n.Name)) { if (-not $x.IsOff) { $l += ,@{ Kind = $x.Kind; Key = $x.Key; Cur = $x.Cur } } }
        $nic[$n.Guid] = $l
    }
    return @{ Nic = $nic }
}
function Custom-NicSuspend-Apply {
    param($p, $mine)
    foreach ($n in @(Nic-List)) {
        $props = @(Nic-SuspendProps $n.Name)
        if ($props.Count -eq 0) { continue }
        Say "  $($n.Name) ($($n.Desc))" 'Gray'
        foreach ($x in $props) {
            if ($x.IsOff) { continue }
            Say "    $($x.Key) -> $($x.Off)" 'DarkGray'
            Nic-PropWrite $n.Name $x $x.Off
        }
    }
}
function Custom-NicSuspend-Revert {
    param($p, $mine)
    foreach ($n in @(Nic-List)) {
        $props = @(Nic-SuspendProps $n.Name)
        if ($props.Count -eq 0) { continue }
        Say "  $($n.Name) ($($n.Desc))" 'Gray'
        foreach ($x in $props) {
            Say "    $($x.Key) -> the default" 'DarkGray'
            Nic-PropReset $n.Name $x
        }
    }
}

# ---------------------------------------- push registry changes to the live desktop --
function Custom-DesktopLive-Detect { param($p) return 'Skip' }
function Custom-DesktopLive-Apply {
    param($p, $mine)
    if ($DryRun) { Say '  [dry] apply the wallpaper / background colour to the running desktop' 'DarkGray'; return }
    Ensure-Win32Ui
    $wp = Reg-Read 'HKCU:\Control Panel\Desktop' 'WallPaper'
    $path = ''; if ($wp.Exists) { $path = [string]$wp.Value }
    [void][Win32Ui]::SpiStr(0x0014, 0, $path, 3)
    $bg = Reg-Read 'HKCU:\Control Panel\Colors' 'Background'
    $rgb = @(0, 0, 0)
    if ($bg.Exists -and ([string]$bg.Value) -match '^\s*(\d+)\s+(\d+)\s+(\d+)') { $rgb = @([int]$Matches[1], [int]$Matches[2], [int]$Matches[3]) }
    $ref = $rgb[0] -bor ($rgb[1] -shl 8) -bor ($rgb[2] -shl 16)
    [void][Win32Ui]::SetSysColors(1, [int[]]@(1), [int[]]@($ref))
    Say '  desktop updated in the running session' 'DarkGray'
}
function Custom-DesktopLive-Revert { param($p, $mine) Custom-DesktopLive-Apply $p $mine }

# The animation switches the running session understands (the SPI_SET code of each; its SPI_GET code is one less)
#   client-area, menu, combo box, list box smooth scrolling, menu fade, selection fade, tooltip, cursor shadow, shadows under windows
$script:AnimFlags = 0x1043, 0x1003, 0x1005, 0x1007, 0x1013, 0x1015, 0x1017, 0x101B, 0x1025
# What the running session has now: SET code (as text) -> 0 / 1, 'Min' = minimise / maximise animation, 'Drag' = show window contents
# while dragging, 'Font' = smooth font edges, 'FontType' = their kind (2 = ClearType). $null when Windows cannot be asked.
function Anim-Read {
    Ensure-Win32Ui
    $o = @{}
    foreach ($a in $script:AnimFlags) {
        $v = 0
        if ([Win32Ui]::SpiGetInt([uint32]($a - 1), 0, [ref]$v, 0)) { $o[[string]$a] = [int]$v }
    }
    $ai = New-Object Win32Ui+ANIMATIONINFO
    $ai.cbSize = 8
    if ([Win32Ui]::SpiAnim(0x0048, 8, [ref]$ai, 0)) { $o['Min'] = [int]$ai.iMinAnimate }          # SPI_GETANIMATION
    $dg = 0; if ([Win32Ui]::SpiGetInt(0x0026, 0, [ref]$dg, 0)) { $o['Drag'] = [int]$dg }           # SPI_GETDRAGFULLWINDOWS
    $f = 0; if ([Win32Ui]::SpiGetInt(0x004A, 0, [ref]$f, 0)) { $o['Font'] = [int]$f }              # SPI_GETFONTSMOOTHING
    $ft = 0; if ([Win32Ui]::SpiGetInt(0x200A, 0, [ref]$ft, 0)) { $o['FontType'] = [int]$ft }       # SPI_GETFONTSMOOTHINGTYPE
    if ($o.Count -eq 0) { return $null }
    return $o
}
# $values: SET code (text) -> 0 / 1, 'Min', 'Drag', 'Font', 'FontType' (anything missing is left as it is)
function Live-AnimationValues {
    param($values)
    Ensure-Win32Ui
    $flags = 3   # SPIF_UPDATEINIFILE | SPIF_SENDCHANGE
    foreach ($a in $script:AnimFlags) {
        $k = [string]$a
        if (-not $values.ContainsKey($k)) { continue }
        $v = [IntPtr]::Zero; if ([int]$values[$k]) { $v = [IntPtr]1 }
        [void][Win32Ui]::SpiPtr([uint32]$a, 0, $v, $flags)
    }
    if ($values.ContainsKey('Min')) {
        $ai = New-Object Win32Ui+ANIMATIONINFO
        $ai.cbSize = 8; $ai.iMinAnimate = [int]$values['Min']
        [void][Win32Ui]::SpiAnim(0x0049, 8, [ref]$ai, $flags)                                      # SPI_SETANIMATION: minimize / maximize animation
    }
    if ($values.ContainsKey('Drag')) { [void][Win32Ui]::SpiPtr(0x0025, [uint32][int]$values['Drag'], [IntPtr]::Zero, $flags) }                  # SPI_SETDRAGFULLWINDOWS (the flag is the second argument)
    if ($values.ContainsKey('Font')) { [void][Win32Ui]::SpiPtr(0x004B, [uint32][int]$values['Font'], [IntPtr]::Zero, $flags) }                  # SPI_SETFONTSMOOTHING
    if ($values.ContainsKey('FontType')) { [void][Win32Ui]::SpiPtr(0x200B, 0, [IntPtr][int]$values['FontType'], $flags) }                        # SPI_SETFONTSMOOTHINGTYPE
}
function Live-Animations {
    param([bool]$enable)
    if ($DryRun) { Say '  [dry] apply animation settings to the running session' 'DarkGray'; return }
    $v = 0; if ($enable) { $v = 1 }
    $all = @{ Min = $v; Drag = $v; Font = 1; FontType = 2 }       # smooth font edges stay ON, using ClearType
    foreach ($a in $script:AnimFlags) { $all[[string]$a] = $v }
    Live-AnimationValues $all
    Say '  animation settings updated in the running session' 'DarkGray'
}
function Custom-AnimLive-Detect { param($p) return 'Skip' }
# What the running session had before (kept in the record; undo does not use it: it puts back the Windows default)
function Custom-AnimLive-Snapshot {
    param($p)
    $saved = $null
    try { $saved = Anim-Read } catch { }
    if (-not $saved) { return $null }
    $allOff = $true
    foreach ($a in $script:AnimFlags) { if ($saved.ContainsKey([string]$a) -and [int]$saved[[string]$a] -ne 0) { $allOff = $false } }
    if ($saved.ContainsKey('Min') -and [int]$saved['Min'] -ne 0) { $allOff = $false }
    if ($saved.ContainsKey('Drag') -and [int]$saved['Drag'] -ne 0) { $allOff = $false }
    return @{ Saved = $saved; Unknown = $allOff }
}
function Custom-AnimLive-Apply  { param($p, $mine) Live-Animations $false }
# Windows' own default for the running session: every animation and effect on
function Custom-AnimLive-Revert { param($p, $mine) Live-Animations $true }

function Custom-MouseLive-Detect { param($p) return 'Skip' }
function Custom-MouseLive-Apply {
    param($p, $mine)
    if ($DryRun) { Say '  [dry] apply the mouse settings to the running session' 'DarkGray'; return }
    Ensure-Win32Ui
    $m = 'HKCU:\Control Panel\Mouse'
    $vals = @{}
    foreach ($pair in @(@('MouseThreshold1', 6), @('MouseThreshold2', 10), @('MouseSpeed', 1), @('MouseSensitivity', 10))) {
        $c = Reg-Read $m $pair[0]; $n = $pair[1]
        $parsed = 0; if ($c.Exists -and [int]::TryParse([string]$c.Value, [ref]$parsed)) { $n = $parsed }
        $vals[$pair[0]] = $n
    }
    [void][Win32Ui]::SpiInts(0x0004, 0, [int[]]@($vals['MouseThreshold1'], $vals['MouseThreshold2'], $vals['MouseSpeed']), 3)   # SPI_SETMOUSE
    [void][Win32Ui]::SpiPtr(0x0071, 0, [IntPtr]([int]$vals['MouseSensitivity']), 3)                                              # SPI_SETMOUSESPEED
    Say '  mouse settings updated in the running session' 'DarkGray'
}
function Custom-MouseLive-Revert { param($p, $mine) Custom-MouseLive-Apply $p $mine }

# ------------------------------- Sticky / Filter / Toggle Keys: push to the running session --
# The registry values are written by the setting's own parts; this makes the running desktop pick them up
# without signing out. $which = Sticky | Filter | Toggle
function Live-Access {
    param([string]$which)
    if ($DryRun) { Say '  [dry] apply the keyboard shortcut setting to the running session' 'DarkGray'; return }
    $reg = ''
    switch ($which) {
        'Sticky' { $reg = 'HKCU:\Control Panel\Accessibility\StickyKeys' }
        'Filter' { $reg = 'HKCU:\Control Panel\Accessibility\Keyboard Response' }
        'Toggle' { $reg = 'HKCU:\Control Panel\Accessibility\ToggleKeys' }
    }
    if (-not $reg) { return }
    $c = Reg-Read $reg 'Flags'
    $f = [uint32]0
    if (-not ($c.Exists -and [uint32]::TryParse([string]$c.Value, [ref]$f))) { return }
    Ensure-Win32Ui
    if ($which -eq 'Filter') {
        $k = New-Object Win32Ui+FILTERFLAGS
        $k.cbSize = 24
        [void][Win32Ui]::SpiFilter(0x0032, 24, [ref]$k, 0)             # SPI_GETFILTERKEYS: keep the delay / repeat / bounce times
        $k.cbSize = 24; $k.dwFlags = $f
        [void][Win32Ui]::SpiFilter(0x0033, 24, [ref]$k, 3)             # SPI_SETFILTERKEYS
    } else {
        $action = 0x003B; if ($which -eq 'Toggle') { $action = 0x0035 }   # SPI_SETSTICKYKEYS / SPI_SETTOGGLEKEYS
        $k = New-Object Win32Ui+KEYFLAGS
        $k.cbSize = 8; $k.dwFlags = $f
        [void][Win32Ui]::SpiKeys($action, 8, [ref]$k, 3)
    }
    Say '  keyboard shortcut setting updated in the running session' 'DarkGray'
}
function Custom-AccessLive-Detect { param($p) return 'Skip' }
function Custom-AccessLive-Apply  { param($p, $mine) Live-Access ([string]$p.Data) }
function Custom-AccessLive-Revert { param($p, $mine) Live-Access ([string]$p.Data) }

# ------------------------------------------------ hypervisor launch (bcdedit) --
# 'off', 'auto', ... or '' when the value is not set; $null when the boot settings cannot be read
function Hv-Type {
    $o = Bcd '/enum' '{current}'
    if ($null -eq $o) { return $null }
    $m = [regex]::Match($o, '(?im)^\s*hypervisorlaunchtype\s+(\S+)')
    if ($m.Success) { return $m.Groups[1].Value.ToLower() }
    return ''
}
function Hv-Shown { param($t) if ($null -eq $t) { return 'could not be read' }; if (-not $t) { return 'not set (Windows decides)' }; return [string]$t }
# What on this PC uses the Windows hypervisor (it does not start while the hypervisor is off; turning it on, or its installer or an
# update to it, can set the boot setting back to Auto): Windows features and virtualization-based security. Only reads. @() when none.
function Hv-Users {
    $o = @()
    foreach ($f in @(@('Microsoft-Hyper-V-All', 'Hyper-V'), @('VirtualMachinePlatform', 'Virtual Machine Platform (WSL 2, Android apps)'), @('HypervisorPlatform', 'Windows Hypervisor Platform (Android emulators)'), @('Containers-DisposableClientVM', 'Windows Sandbox'))) {
        $st = ''; try { $st = [string](Feat-State ([string]$f[0])) } catch { }
        if ($st -eq 'Enabled') { $o += [string]$f[1] }
    }
    $dg = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard'
    $hv = Reg-Read "$dg\Scenarios\HypervisorEnforcedCodeIntegrity" 'Enabled'
    $vb = Reg-Read $dg 'EnableVirtualizationBasedSecurity'
    if ($hv.Exists -and [string]$hv.Value -eq '1') { $o += 'Memory integrity (Core isolation)' }
    elseif ($vb.Exists -and [string]$vb.Value -eq '1') { $o += 'Virtualization-based security' }
    $cg = Reg-Read 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'LsaCfgFlags'
    if ($cg.Exists -and ([string]$cg.Value -eq '1' -or [string]$cg.Value -eq '2')) { $o += 'Credential Guard' }
    return $o
}
# Is the hypervisor running right now? $true / $false, $null when Windows does not say
function Hv-Running {
    $n0 = $Error.Count
    $r = $null
    try { $c = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop; if ($null -ne $c.HypervisorPresent) { $r = [bool]$c.HypervisorPresent } } catch { }
    Drop-ErrorsSince $n0
    return $r
}
function Custom-Hypervisor-Detect {
    param($p)
    $t = Hv-Type
    if ($null -eq $t) { $script:Why = 'the boot settings cannot be read on this PC'; $script:Now = 'Boot setting hypervisorlaunchtype: could not be read'; return 'NA' }
    $script:Now = ('Boot setting hypervisorlaunchtype: {0}, wanted off' -f (Hv-Shown $t))
    if ($t -eq 'off') { return 'On' }
    $u = @(); try { $u = @(Hv-Users) } catch { }
    if ($u.Count) { $script:Now += ('. Uses the hypervisor on this PC (and can set it back to Auto): ' + ($u -join ', ')) }
    return 'Off'
}
function Custom-Hypervisor-Snapshot {
    param($p)
    $t = Hv-Type
    return @{ Was = [string]$t; Unknown = ($t -eq 'off') }
}
function Custom-Hypervisor-Apply {
    param($p, $mine)
    if ($DryRun) { Say '  [dry] bcdedit /set hypervisorlaunchtype off' 'DarkGray'; return }
    # what the boot entry had and whether the hypervisor runs now (when it keeps coming back, these lines show what set it back)
    $was = Hv-Type
    $run = Hv-Running
    $m = '  the boot entry had: hypervisorlaunchtype {0}' -f (Hv-Shown $was)
    if ($null -ne $run) { if ($run) { $m += '; the hypervisor is running now' } else { $m += '; the hypervisor is not running now' } }
    Say $m 'DarkGray'
    $u = @(); try { $u = @(Hv-Users) } catch { }
    if ($u.Count) {
        Say ('  NOTE: uses the hypervisor on this PC: ' + ($u -join ', ') + '. It does not start while this is switched on, and turning it on, or its installer or an update to it, can set the boot setting back to Auto.') 'Yellow'
    }
    [void](Bcd '/set' 'hypervisorlaunchtype' 'off')
    $said = [string]$script:BcdSaid
    $now = Hv-Type
    if ($now -ne 'off') {
        if (-not $said) { $said = ('the boot entry still has ' + (Hv-Shown $now)) }
        throw ('bcdedit did not turn the hypervisor off: ' + $said)
    }
    Say '  bcdedit /set hypervisorlaunchtype off   (takes effect after a restart)' 'DarkGray'
}
function Custom-Hypervisor-Revert {
    param($p, $mine)
    if ($DryRun) { Say '  [dry] bcdedit /deletevalue hypervisorlaunchtype' 'DarkGray'; return }
    # the Windows default is no value at all, so Windows decides again
    [void](Bcd '/deletevalue' 'hypervisorlaunchtype')
    Say '  bcdedit /deletevalue hypervisorlaunchtype   (Windows decides again)' 'DarkGray'
}

# ----------------------------------------- Windows Security scans: idle only -----
$script:MpIdleCpu = 20
function Mp-IsQuiet { param($m) return ($m.Idle -and $m.LowPri -and $m.Cpu -le $script:MpIdleCpu) }
function Custom-DefenderIdle-Detect {
    param($p)
    $m = Mp-Read
    if (-not $m) { $script:Why = 'Windows Security (Defender) is not available on this PC'; $script:Now = 'Windows Security scan settings: could not be read'; return 'NA' }
    $script:Now = ('Windows Security scans: only when idle = {0}, low priority = {1}, CPU limit {2}%, wanted idle only, low priority, at most {3}%' -f $m.Idle, $m.LowPri, $m.Cpu, $script:MpIdleCpu)
    if (Mp-IsQuiet $m) { return 'On' }
    return 'Off'
}
function Custom-DefenderIdle-Snapshot {
    param($p)
    $m = Mp-Read
    if (-not $m) { return $null }
    return @{ Idle = $m.Idle; LowPri = $m.LowPri; Cpu = $m.Cpu; Unknown = (Mp-IsQuiet $m) }
}
function Custom-DefenderIdle-Apply {
    param($p, $mine)
    if ($DryRun) { Say ('  [dry] Windows Security: scan only when idle, low CPU priority, at most {0}% CPU' -f $script:MpIdleCpu) 'DarkGray'; return }
    if (Mp-Write $true $true $script:MpIdleCpu) { Say ('  Windows Security scans: only when idle, low priority, at most {0}% CPU' -f $script:MpIdleCpu) 'DarkGray' }
}
function Custom-DefenderIdle-Revert {
    param($p, $mine)
    $idle = $true; $low = $false; $cpu = 50          # Windows' own defaults
    if ($DryRun) { Say '  [dry] Windows Security scan settings back to the Windows defaults' 'DarkGray'; return }
    if (Mp-Write $idle $low $cpu) { Say ('  Windows Security scans: idle only = {0}, low priority = {1}, CPU limit {2}%' -f $idle, $low, $cpu) 'DarkGray' }
}

# ------------------------------- Display: graphics switches that share one text -----
# Settings > System > Display > Graphics > Default graphics settings keeps its switches in ONE text value, a list of NAME=value;
# pairs (for example "SwapEffectUpgradeEnable=1;VRROptimizeEnable=1;"). Each switch here changes only its own pair and leaves every
# other pair in the text exactly as it was, whoever wrote it.
$script:DxPath = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
$script:DxName = 'DirectXUserGlobalSettings'
# the pieces of the text: whole "NAME=value" parts without the semicolons, empty parts dropped
function Dx-Parts { param([string]$Text) return @(([string]$Text -split ';') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
# the value of one name, or $null when the text has no such name
function Dx-Get {
    param([string]$Text, [string]$Key)
    foreach ($part in (Dx-Parts $Text)) {
        $i = $part.IndexOf('=')
        if ($i -gt 0 -and $part.Substring(0, $i).Trim() -ieq $Key) { return $part.Substring($i + 1).Trim() }
    }
    return $null
}
# the text with one name set to $Value (added at the end when it is not there yet), or removed when $Value is $null
function Dx-Set {
    param([string]$Text, [string]$Key, $Value)
    $out = @()
    $done = $false
    foreach ($part in (Dx-Parts $Text)) {
        $i = $part.IndexOf('=')
        if ($i -gt 0 -and $part.Substring(0, $i).Trim() -ieq $Key) {
            if (-not $done -and $null -ne $Value) { $out += ($Key + '=' + [string]$Value) }
            $done = $true
        } else { $out += $part }
    }
    if (-not $done -and $null -ne $Value) { $out += ($Key + '=' + [string]$Value) }
    if ($out.Count -eq 0) { return '' }
    return (($out -join ';') + ';')
}
function Dx-ReadText {
    $r = Reg-Read $script:DxPath $script:DxName
    if ($r.Exists) { return [string]$r.Value }
    return ''
}
# Writes the text; an empty text removes the value (an empty list and no list mean the same to Windows)
function Dx-WriteText {
    param([string]$Text)
    if ($Text) { return (Reg-Write $script:DxPath $script:DxName $Text 'String') }
    return (Reg-Remove $script:DxPath $script:DxName)
}
# The lowest Windows build that has the switch, as the build number is known: an unknown build counts as supported
$script:DxMinBuild = @{ 'SwapEffectUpgradeEnable' = 22621; 'VRROptimizeEnable' = 19041 }
# The value each setting writes into its own pair: both switches are turned ON (1). "Applied" means the entry reads 1. A missing entry
# means Windows' own default: on for "Optimizations for windowed games" from Windows 11 24H2 (see Dx-DefaultOn), and off for "Variable
# refresh rate" (the Windows guides list it as off out of the box; Microsoft does not publish it). Windows shows the variable refresh
# rate switch in Settings only where the monitor and the graphics driver support it, so on a PC where no screen can do it (Vrr-Check)
# the setting reads "not available" and is never written.
$script:DxWant = @{ 'SwapEffectUpgradeEnable' = '1'; 'VRROptimizeEnable' = '1' }
function Dx-Want {
    param([string]$Key)
    $w = [string]$script:DxWant[$Key]
    if ($w) { return $w }
    return '1'
}
function Dx-Build {
    $r = Reg-Read 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'CurrentBuildNumber'
    $n = 0
    if ($r.Exists) { [void][int]::TryParse([string]$r.Value, [ref]$n) }
    return $n
}
# From this build on (Windows 11 24H2) a clean Windows has no entry for "Optimizations for windowed games" and Settings shows it ON, so a
# missing entry is read as On there. Older builds, and a PC whose build cannot be read, read a missing entry as Off. For "Variable refresh
# rate" a missing entry is Off on every build: it is never turned on by Windows itself.
$script:DxDefaultOnBuild = 26100
function Dx-DefaultOn {
    param([string]$Key)
    if ($Key -ne 'SwapEffectUpgradeEnable') { return $false }
    $b = Dx-Build
    return ($b -ge $script:DxDefaultOnBuild)
}
# False on a Windows build that is older than the one that has the switch (an unknown build counts as supported)
function Dx-Supported {
    param([string]$Key)
    $min = [int]$script:DxMinBuild[$Key]
    $b = Dx-Build
    return (-not ($b -gt 0 -and $min -gt 0 -and $b -lt $min))
}

# ---- Is there a variable refresh rate switch on this PC? ----
# Windows shows the "Variable refresh rate" switch in Settings only when all three are there: Windows 10 2004 or newer, a screen that can do
# variable refresh rate (G-SYNC Compatible, FreeSync, Adaptive-Sync, HDMI VRR) and a graphics driver that supports it. Windows has no question
# that returns "is the switch shown", so this reads what can be read: how each connected screen is attached (a VGA or DVI cable cannot carry
# it) and what the screen says about itself (its EDID: a FreeSync block or an HDMI VRR block means it can; for DisplayPort the range of
# refresh rates the screen accepts, which a fixed-rate screen does not have or has very narrow). The switch counts as missing only when every
# connected screen plainly cannot do it. Whatever cannot be read, or is unclear, counts as "the switch may be there" and the setting stays usable.
# Connection types (D3DKMDT_VIDEO_OUTPUT_TECHNOLOGY) that cannot carry variable refresh rate at all, with a plain name
$script:VrrNoLink = @{ 0 = 'a VGA cable'; 1 = 'an analog cable'; 2 = 'an analog cable'; 3 = 'an analog cable'; 4 = 'a DVI cable'; 6 = 'an LVDS panel'
                       8 = 'an analog cable'; 9 = 'an SDI cable'; 14 = 'an analog adapter'; 15 = 'a wireless display link' }
# a range of refresh rates this much wider than 10 Hz is what a screen with variable refresh rate reports (the Linux AMD driver draws the same line)
$script:VrrMinSpan = 10
# The connection type as a plain number: -1 when it is not known; the "internal" flag (0x80000000) is taken off, and a bare "internal" is an embedded panel (11)
function Vrr-LinkKind {
    param($Tech)
    $t = 4294967295L
    if ($null -ne $Tech) { try { $t = ([int64]$Tech) -band 4294967295L } catch { $t = 4294967295L } }
    if ($t -eq 4294967295L) { return -1 }
    $internal = (($t -band 2147483648L) -ne 0)
    $base = [int]($t -band 2147483647L)
    if ($internal -and $base -eq 0) { return 11 }
    return $base
}
# What the EDID bytes of one screen say about variable refresh rate: the refresh rate range of the base block (descriptor 0xFD, with the
# EDID 1.4 offsets), the AMD FreeSync block and the HDMI Forum block of the CTA extension, and whether a DisplayID extension is there.
function Vrr-ParseEdid {
    param($Edid)
    $r = @{ Ok = $false; HasRange = $false; Min = 0; Max = 0; Amd = $false; Hdmi = $false; DispId = $false }
    $b = @()
    foreach ($x in @($Edid)) { $b += [int]$x }
    if ($b.Count -lt 128) { return $r }
    $head = @(0, 255, 255, 255, 255, 255, 255, 0)
    for ($i = 0; $i -lt 8; $i++) { if ($b[$i] -ne $head[$i]) { return $r } }
    $r.Ok = $true
    foreach ($o in @(54, 72, 90, 108)) {
        if ($b[$o] -eq 0 -and $b[$o + 1] -eq 0 -and $b[$o + 3] -eq 253) {
            $lo = $b[$o + 5]; $hi = $b[$o + 6]
            if ($b[19] -ge 4 -and ($b[$o + 4] -band 2) -ne 0) { $hi += 255; if (($b[$o + 4] -band 1) -ne 0) { $lo += 255 } }
            if ($hi -gt 0) { $r.HasRange = $true; $r.Min = $lo; $r.Max = $hi }
        }
    }
    $n = $b[126]
    for ($e = 1; $e -le $n; $e++) {
        $s = 128 * $e
        if ($b.Count -lt $s + 128) { break }
        if ($b[$s] -eq 112) { $r.DispId = $true }
        if ($b[$s] -ne 2) { continue }
        $d = $b[$s + 2]
        if ($d -lt 4) { continue }
        $p = $s + 4
        $end = [Math]::Min($s + $d, $s + 127)
        while ($p -lt $end) {
            $len = $b[$p] -band 31
            if ($p + $len -gt $s + 127) { break }
            if (($b[$p] -shr 5) -eq 3 -and $len -ge 3) {
                $oui = ('{0:X2}{1:X2}{2:X2}' -f $b[$p + 3], $b[$p + 2], $b[$p + 1])
                if ($oui -eq '00001A') { if ($len -lt 5 -or ($b[$p + 5] -band 1) -ne 0) { $r.Amd = $true } }
                elseif ($oui -eq 'C45DD8' -and $len -ge 8) { $r.Hdmi = $true }
            }
            $p += 1 + $len
        }
    }
    return $r
}
# One screen: @{ State = yes | no | unknown; Why } from @{ Tech; Edid }
function Vrr-Judge {
    param($Screen)
    $kind = Vrr-LinkKind $Screen.Tech
    if ($script:VrrNoLink.ContainsKey($kind)) { return @{ State = 'no'; Why = ('connected by {0}, which cannot carry variable refresh rate' -f $script:VrrNoLink[$kind]) } }
    $e = $null
    if ($Screen.Edid) { $e = Vrr-ParseEdid $Screen.Edid }
    if (-not $e -or -not $e.Ok) { return @{ State = 'unknown'; Why = 'its display information could not be read' } }
    if ($e.Amd) { return @{ State = 'yes'; Why = 'announces FreeSync' } }
    if ($e.Hdmi) { return @{ State = 'yes'; Why = 'announces HDMI variable refresh rate' } }
    if ($kind -eq 5) { return @{ State = 'no'; Why = 'connected by HDMI and announces neither FreeSync nor HDMI variable refresh rate' } }
    if ($e.HasRange) {
        if (($e.Max - $e.Min) -gt $script:VrrMinSpan) { return @{ State = 'yes'; Why = ('accepts refresh rates from {0} to {1} Hz' -f $e.Min, $e.Max) } }
        return @{ State = 'no'; Why = ('refresh rate range {0}-{1} Hz is too narrow for variable refresh rate' -f $e.Min, $e.Max) }
    }
    if ($e.DispId) { return @{ State = 'unknown'; Why = 'its refresh rate range is not in the part of its display information that could be read' } }
    return @{ State = 'no'; Why = 'does not report a range of refresh rates' }
}
# The screens that are connected now: name, connection type and the raw EDID bytes that Windows keeps in the registry
function Vrr-Screens {
    $out = @()
    try {
        $conn = @{}
        foreach ($c in @(Get-CimInstance -Namespace 'root\wmi' -ClassName WmiMonitorConnectionParams -ErrorAction Stop)) { $conn[([string]$c.InstanceName).ToUpperInvariant()] = $c.VideoOutputTechnology }
        foreach ($m in @(Get-CimInstance -Namespace 'root\wmi' -ClassName WmiMonitorID -ErrorAction Stop)) {
            if ($null -ne $m.Active -and -not [bool]$m.Active) { continue }
            $inst = [string]$m.InstanceName
            $edid = $null
            $reg = Reg-Read ('HKLM:\SYSTEM\CurrentControlSet\Enum\' + ($inst -replace '_\d+$', '') + '\Device Parameters') 'EDID'
            if ($reg.Exists -and $reg.Value -is [byte[]]) { $edid = $reg.Value }
            $code = ''
            $q = @($inst -split '\\')
            if ($q.Count -ge 2) { $code = $q[1] }
            $name = ''
            $fn = @($m.UserFriendlyName | Where-Object { $_ -ne 0 } | ForEach-Object { [byte]$_ })
            if ($fn.Count) { $name = ([System.Text.Encoding]::ASCII.GetString([byte[]]$fn)).Trim() }
            if (-not $name) { $name = $code }
            if (-not $name) { $name = 'a screen' }
            $out += ,@{ Name = $name; Tech = $conn[$inst.ToUpperInvariant()]; Edid = $edid; Code = $code }
        }
    } catch { }
    return $out
}
# All connected screens together: State = yes (at least one can), no (every one plainly cannot) or unknown (anything else, also no screen found);
# Seen = one short sentence per screen. A check asks once and the answer is reused; call it as @(Vrr-Check)[0].
function Vrr-Check {
    Scan-Memo 'vrr' {
        $seen = @(); $yes = 0; $no = 0; $unk = 0
        foreach ($s in @(Vrr-Screens)) {
            $j = Vrr-Judge $s
            $seen += ('{0}: {1}' -f $s.Name, $j.Why)
            switch ($j.State) { 'yes' { $yes++ } 'no' { $no++ } default { $unk++ } }
        }
        $state = 'unknown'
        if ($yes -gt 0) { $state = 'yes' } elseif ($unk -eq 0 -and $no -gt 0) { $state = 'no' }
        return @{ State = $state; Seen = $seen }
    }
}
# True when the variable refresh rate switch is missing on this PC (a Windows build without it, or no screen that can do it)
function Vrr-Missing {
    param([string]$Key)
    if ($Key -ne 'VRROptimizeEnable') { return $false }
    return ((@(Vrr-Check)[0]).State -eq 'no')
}
function Custom-DxGlobal-Detect {
    param($p)
    $key = [string]$p.Data
    $min = [int]$script:DxMinBuild[$key]
    $b = Dx-Build
    if (-not (Dx-Supported $key)) {
        if ($min -ge 22000) { $script:Why = 'this switch exists on Windows 11 22H2 and newer' } else { $script:Why = 'this switch exists on Windows 10 version 2004 and newer' }
        $script:Now = ('Graphics switch {0}: needs Windows build {1}, this PC has {2}' -f $key, $min, $b)
        return 'NA'
    }
    if (Vrr-Missing $key) {
        $script:Why = 'Windows shows this switch only for a screen that supports variable refresh rate, and none of the screens on this PC does'
        $script:Now = ('Variable refresh rate switch not available. ' + ((@(Vrr-Check)[0]).Seen -join '; '))
        return 'NA'
    }
    $v = Dx-Get (Dx-ReadText) $key
    $shown = $v
    if ($null -eq $v) {
        $shown = 'no entry'
        if (Dx-DefaultOn $key) { $shown += ' (Windows treats that as on)' }
        else { $shown += ' (Windows treats that as off)' }
    }
    $want = Dx-Want $key
    $script:Now = ('Graphics switch {0}: {1}, wanted {2}' -f $key, $shown, $want)
    # for variable refresh rate also say what each screen reported about itself, so it is visible why this switch is offered here
    if ($key -eq 'VRROptimizeEnable') {
        $seen = @((@(Vrr-Check)[0]).Seen)
        if ($seen.Count -gt 0) { $script:Now += ('. Screens: ' + ($seen -join '; ')) } else { $script:Now += '. No screen could be read, so the switch is left available' }
    }
    if ($v -eq $want) { return 'On' }
    # no entry: Windows' own default. Where Windows' default is on (the windowed-games switch on Windows 11 24H2 and newer) that already counts as
    # applied; for variable refresh rate a missing entry is Off, the setting is there to be turned on
    if ($null -eq $v -and $want -eq '1' -and (Dx-DefaultOn $key)) { return 'On' }
    return 'Off'
}
function Custom-DxGlobal-Snapshot {
    param($p)
    $key = [string]$p.Data
    $v = Dx-Get (Dx-ReadText) $key
    $want = Dx-Want $key
    # a switch that already has the wanted value when this app first looks (an entry with it, or no entry on a build where Windows'
    # default is on): what it was before is unknown, undo then puts it back to the other value (or to no entry)
    return @{ Key = $key; Had = ($null -ne $v); Was = [string]$v; Unknown = ($v -eq $want -or ($null -eq $v -and $want -eq '1' -and (Dx-DefaultOn $key))) }
}
function Custom-DxGlobal-Apply {
    param($p, $mine)
    $key = [string]$p.Data
    # a switch that this Windows build does not have, or that no screen of this PC can use, is never written (the plan skips it too; this is the second lock)
    if (-not (Dx-Supported $key)) { return }
    if (Vrr-Missing $key) { return }
    [void](Dx-WriteText (Dx-Set (Dx-ReadText) $key (Dx-Want $key)))
}
function Custom-DxGlobal-Revert {
    param($p, $mine)
    $key = [string]$p.Data
    if (-not (Dx-Supported $key)) { return }
    if (Vrr-Missing $key) { return }
    $want = Dx-Want $key
    $val = $null
    if ($want -eq '1' -and (Dx-DefaultOn $key)) { $val = '0' }     # removing the entry would leave Windows' default, which is on: switching off needs an explicit 0
    # otherwise the entry is removed, which leaves the Windows default (off, for variable refresh rate)
    [void](Dx-WriteText (Dx-Set (Dx-ReadText) $key $val))
}

# ------------------------------- Game Mode -----
# Windows Game Mode (Settings > Gaming > Game Mode) is a switch of the current account: HKCU\Software\Microsoft\GameBar, AutoGameModeEnabled
# (1 on, 0 off). Windows has it on by default and a clean Windows has no entry for it, so a missing entry is On. Guides for turning it off
# also set AllowAutoGameMode, an older value of the same key, so both are read and Game Mode counts as on unless one of them is 0.
$script:GmPath = 'HKCU:\Software\Microsoft\GameBar'
$script:GmNames = @('AutoGameModeEnabled', 'AllowAutoGameMode')
function Gm-Read {
    $r = @{}
    foreach ($n in $script:GmNames) { $r[$n] = Reg-Read $script:GmPath $n }
    return $r
}
function Gm-IsOn {
    param($r)
    foreach ($n in $script:GmNames) { if ($r[$n].Exists -and [string]$r[$n].Value -eq '0') { return $false } }
    return $true
}
function Custom-GameMode-Detect {
    param($p)
    $r = Gm-Read
    $txt = @()
    foreach ($n in $script:GmNames) {
        $v = 'no entry (Windows treats that as on)'
        if ($r[$n].Exists) { $v = [string]$r[$n].Value }
        $txt += ('{0} = {1}' -f $n, $v)
    }
    $script:Now = ('{0}: {1}; wanted on' -f $script:GmPath, ($txt -join ', '))
    if (Gm-IsOn $r) { return 'On' }
    return 'Off'
}
function Custom-GameMode-Snapshot {
    param($p)
    $r = Gm-Read
    $snap = @{ On = [bool](Gm-IsOn $r) }
    # what each value was: when Game Mode was already on, nothing is known about "before" (undo then turns it off)
    foreach ($n in $script:GmNames) { $snap[$n] = @{ Had = [bool]$r[$n].Exists; Was = $r[$n].Value; Kind = [string]$r[$n].Kind } }
    return $snap
}
function Custom-GameMode-Apply {
    param($p, $mine)
    [void](Reg-Write $script:GmPath 'AutoGameModeEnabled' 1 'DWord')
    # the older value is only changed where it exists (it is not created from nothing)
    if ((Reg-Read $script:GmPath 'AllowAutoGameMode').Exists) { [void](Reg-Write $script:GmPath 'AllowAutoGameMode' 1 'DWord') }
}
function Custom-GameMode-Revert {
    param($p, $mine)
    # Windows' default is Game Mode on, so removing the entries would leave this setting reading as on: switching it off needs an explicit 0
    foreach ($n in $script:GmNames) { [void](Reg-Write $script:GmPath $n 0 'DWord') }
}

# ------------------------------- Automatic color management -----
# "Automatically manage color for apps" (Settings > System > Display > Color profile; on some builds under Advanced display) is kept for each
# screen on its own: a DWord AutoColorManagementEnabled (1 on, 0 off) in one key per screen under ...\GraphicsDrivers\MonitorDataStore.
# Windows ships it off, and a missing value is read as off. The name of a screen's key starts with the 7-character code of the screen in the
# monitor list (SAM105C, say), which is how the keys of the screens that are connected now are found. A screen with no key of its own is left
# alone: the name of a key cannot be worked out from here, and this app does not make up keys. The switch exists from Windows 11 22H2 with the
# October 2023 update (build 22621.2506) and applies to screens in standard dynamic range (SDR) only.
$script:AcmRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\MonitorDataStore'
$script:AcmName = 'AutoColorManagementEnabled'
# False on a Windows build that is older than the one with the switch (a build that cannot be read counts as supported)
function Acm-Supported {
    $b = Dx-Build
    if ($b -le 0) { return $true }
    if ($b -lt 22621) { return $false }
    if ($b -gt 22621) { return $true }
    $u = Reg-Read 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'UBR'
    $n = 0
    if ($u.Exists) { [void][int]::TryParse([string]$u.Value, [ref]$n) }
    return ($n -le 0 -or $n -ge 2506)
}
# The color keys of the screens that are connected now: @{ Name = the screen; Key = the full registry path }, each key once
function Acm-Keys {
    Scan-Memo 'acm' {
        $leaves = @()
        foreach ($k in @(Reg-SubKeys $script:AcmRoot)) { $s = [string]$k; $leaves += $s.Substring($s.LastIndexOf('\') + 1) }
        $out = @(); $seen = @{}
        foreach ($sc in @(Vrr-Screens)) {
            $code = [string]$sc.Code
            if ($code.Length -lt 3) { continue }
            foreach ($l in $leaves) {
                if (-not $l.StartsWith($code, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                $full = $script:AcmRoot + '\' + $l
                if ($seen.ContainsKey($full)) { continue }
                $seen[$full] = 1
                $out += ,@{ Name = [string]$sc.Name; Key = $full }
            }
        }
        return $out
    }
}
function Custom-AcmApps-Detect {
    param($p)
    if (-not (Acm-Supported)) {
        $script:Why = 'this switch exists on Windows 11 22H2 with the October 2023 update (build 22621.2506) and newer'
        $script:Now = ('Automatic color management: needs Windows build 22621.2506, this PC has build {0}' -f (Dx-Build))
        return 'NA'
    }
    $ks = @(Acm-Keys)
    if ($ks.Count -eq 0) {
        $script:Why = 'Windows keeps this switch in a color entry of each screen, and none of the screens that are connected has one'
        $script:Now = 'Automatic color management: no color entry found for the connected screens'
        return 'NA'
    }
    $on = 0; $off = 0; $txt = @()
    foreach ($k in $ks) {
        $r = Reg-Read $k.Key $script:AcmName
        $v = 'no value (Windows treats that as off)'
        if ($r.Exists) { $v = [string]$r.Value }
        if ($r.Exists -and [string]$r.Value -eq '1') { $on++ } else { $off++ }
        $txt += ('{0}: {1}' -f $k.Name, $v)
    }
    $script:Now = ('{0}, wanted 1. Screens: {1}' -f $script:AcmName, ($txt -join '; '))
    return (Count-State $on $off)
}
# (kept as a record of what this app found; the undo does not depend on it)
function Custom-AcmApps-Snapshot {
    param($p)
    $dev = @{}
    foreach ($k in @(Acm-Keys)) {
        $r = Reg-Read $k.Key $script:AcmName
        $dev[$k.Key] = @{ Had = [bool]$r.Exists; Was = $r.Value; Kind = [string]$r.Kind }
    }
    return @{ Dev = $dev }
}
function Custom-AcmApps-Apply {
    param($p, $mine)
    # a Windows build without the switch is never written (the plan skips it too; this is the second lock)
    if (-not (Acm-Supported)) { return }
    $n = 0
    foreach ($k in @(Acm-Keys)) { if (Reg-Write $k.Key $script:AcmName 1 'DWord') { $n++ } }
    Say "  ($n screen(s). A screen that is connected later gets Windows' default - switch this on again after adding one.)" 'DarkGray'
}
function Custom-AcmApps-Revert {
    param($p, $mine)
    if (-not (Acm-Supported)) { return }
    foreach ($k in @(Acm-Keys)) {
        # Off is an explicit 0 on every screen that has a value (whatever it is now: our 1, one that Windows or a graphics driver wrote, or none of
        # ours). Removing the value would also read as off, but users report that a graphics driver install or a change of the color depth turns the
        # switch on again, and a 0 is the one answer that reads as off with certainty. A screen with no value at all is left alone: nothing to undo.
        $cur = Reg-Read $k.Key $script:AcmName
        if ($cur.Exists -and [string]$cur.Value -ne '0') { [void](Reg-Write $k.Key $script:AcmName 0 'DWord') }
    }
}

# ------------------------------- Windows AI core package -----
# MicrosoftWindows.Client.CoreAI is part of Windows and is marked "not removable". Windows allows removing such a package once it is
# marked end of life: a key named after the package under ...\Appx\AppxAllUserStore\EndOfLife\<account SID>. The removal goes the way
# the other removal tools do it:
#   1. the package's family is marked deprovisioned (AppxAllUserStore\Deprovisioned\<family>, the key Windows itself writes when a
#      provisioned app is removed), so Windows does not install it again for new accounts or with an update
#   2. Windows' own "not removable" mark is taken off (Set-NonRemovableAppsPolicy -NonRemovable 0, on the Windows versions that have it)
#   3. it is marked end of life for SYSTEM (S-1-5-18), every account that has an app store entry, and every account it is installed for
#   4. it is removed for all users, else for each account it is installed for (Appx-RemoveOne), and its provisioned copy is removed
#   5. the end-of-life marks are taken out again: left in place they can stop Windows Update from installing updates
# Then it is checked: when it is still installed for any account the setting fails with what Windows said.
$script:AiCorePat = 'MicrosoftWindows.Client.CoreAI*'
$script:AiCoreSettleMs = 1500    # how long Windows is given after a removal before it is checked
$script:AppxStore = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore'
$script:EolRoot = $script:AppxStore + '\EndOfLife'
function Ai-CoreFind {
    $d = Appx-Data
    $pk = @{}; $pv = @{}; $lv = @{}; $sy = @{}
    foreach ($p in $d.Pkgs) { if ([string]$p.Name -like $script:AiCorePat) { $pk[[string]$p.Full] = [string]$p.Name; $lv[[string]$p.Full] = ($null -eq $p.Live -or [bool]$p.Live); $sy[[string]$p.Full] = [bool]$p.Sys } }
    foreach ($p in $d.Prov) { if ([string]$p.Name -like $script:AiCorePat) { $pv[[string]$p.Pkg] = [string]$p.Name } }
    return @{ Pkgs = $pk; Prov = $pv; Live = $lv; Sys = $sy }
}
# The package family of a full package name (Name_Version_Arch_Resource_Publisher -> Name_Publisher)
function Appx-FamilyOf {
    param([string]$Full)
    $s = $Full -split '_'
    if ($s.Count -lt 3) { return $Full }
    return ($s[0] + '_' + $s[-1])
}
# The accounts a package is installed for (the current account is always in the list)
function Appx-UserSids {
    param([string]$Full)
    $sids = @()
    $n0 = $Error.Count
    try { $sids += [string][System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { }
    try {
        $nm = ($Full -split '_')[0]
        foreach ($x in @(Get-AppxPackage -AllUsers -Name $nm -ErrorAction Stop | Where-Object { $_.PackageFullName -eq $Full })) {
            foreach ($u in @($x.PackageUserInformation)) {
                $s = ''
                try { $s = [string]$u.UserSecurityId.Sid } catch { }
                if ($s -and $sids -notcontains $s) { $sids += $s }
            }
        }
    } catch { }
    Drop-ErrorsSince $n0
    return @($sids | Where-Object { $_ })
}
# The accounts that have an entry in Windows' app store (AppxAllUserStore\S-1-5-21-...)
function Appx-StoreSids {
    $o = @()
    foreach ($k in @(Reg-SubKeys $script:AppxStore)) { $leaf = ([string]$k -split '\\')[-1]; if ($leaf -like 'S-1-5-21-*' -and $o -notcontains $leaf) { $o += $leaf } }
    return $o
}
# Every account the end-of-life mark is written for: SYSTEM, the accounts with an app store entry, the accounts it is installed for
function Ai-CoreSids {
    param([string]$Full)
    $o = @('S-1-5-18')
    foreach ($s in @(@(Appx-StoreSids) + @(Appx-UserSids $Full))) { if ($s -and $o -notcontains $s) { $o += [string]$s } }
    return $o
}
# (a mark is only written or taken out for one account and one exact package name: never for a whole account or every package)
function Appx-EolOk { param([string]$Sid, [string]$Full) return ($Sid -match '^S-1-[0-9-]+$' -and $Full -match '^[A-Za-z0-9][A-Za-z0-9._-]*_[A-Za-z0-9._~-]+$' -and $Full -notmatch '[\\*?]') }
function Appx-EolMark {
    param([string]$Sid, [string]$Full)
    if ($DryRun) { return '' }
    if (-not (Appx-EolOk $Sid $Full)) { return ('it could not be marked as end of life for {0}: not a package name or an account' -f $Sid) }
    try { New-Item -Path ($script:EolRoot + '\' + $Sid + '\' + $Full) -Force -ErrorAction Stop | Out-Null; return '' }
    catch { Drop-Error $_; return ('it could not be marked as end of life for {0}: {1}' -f $Sid, $_.Exception.Message) }
}
function Appx-EolClear {
    param([string]$Sid, [string]$Full)
    if ($DryRun) { return }
    if (-not (Appx-EolOk $Sid $Full)) { return }
    $k = $script:EolRoot + '\' + $Sid + '\' + $Full
    $n0 = $Error.Count
    if (Test-Path -LiteralPath $k) { Remove-Item -LiteralPath $k -Recurse -Force -ErrorAction SilentlyContinue }
    Drop-ErrorsSince $n0
}
function Appx-DeprovMark {
    param([string]$Family)
    if ($DryRun) { return '' }
    try { New-Item -Path ($script:AppxStore + '\Deprovisioned\' + $Family) -Force -ErrorAction Stop | Out-Null; return '' }
    catch { Drop-Error $_; return ('it could not be marked as deprovisioned: ' + $_.Exception.Message) }
}
function Appx-NonRemovableOff {
    param([string]$Family)
    if ($DryRun) { return '' }
    if (-not (Get-Command Set-NonRemovableAppsPolicy -ErrorAction Ignore)) { return '' }       # (older Windows 11 versions do not have it)
    try { Set-NonRemovableAppsPolicy -Online -PackageFamilyName $Family -NonRemovable 0 -ErrorAction Stop | Out-Null; return '' }
    catch { Drop-Error $_; return ('Windows kept its "not removable" mark: ' + $_.Exception.Message) }
}
function Custom-AiCore-Detect {
    param($p)
    $m = Ai-CoreFind
    # removed = installed for nobody: the copy that is only kept for new accounts does not count as installed
    $inst = 0; $sysk = 0; foreach ($k in @($m.Pkgs.Keys)) { if ($m.Live[$k]) { $inst++ } elseif ($m.Sys[$k]) { $sysk++ } }
    $left = ($m.Pkgs.Count - $inst - $sysk) + $m.Prov.Count
    $script:Now = ('Windows AI core package: {0} installed' -f $inst)
    if ($sysk -gt 0) { $script:Now += (', {0} kept only for Windows'' own system account (S-1-5-18, not for anyone who signs in)' -f $sysk) }
    if ($left -gt 0) { $script:Now += (', {0} only kept for new accounts (not installed for anyone)' -f $left) }
    $script:Now += ', wanted none installed'
    if ($inst -gt 0) { return 'Off' }
    return 'On'
}
function Custom-AiCore-Snapshot { param($p) return $null }
function Custom-AiCore-Apply {
    param($p, $mine)
    $m = Ai-CoreFind
    if ($m.Pkgs.Count -eq 0 -and $m.Prov.Count -eq 0) { Say '  (the Windows AI core package is not on this PC)' 'DarkGray'; return }
    $fails = @()
    foreach ($full in @($m.Pkgs.Keys)) {
        $name = [string]$m.Pkgs[$full]
        Say "  removing app $name" 'Gray'
        if ($DryRun) { continue }
        $notes = @()
        $fam = Appx-FamilyOf $full
        $r = Appx-DeprovMark $fam; if ($r) { $notes += $r }
        $r = Appx-NonRemovableOff $fam; if ($r) { $notes += $r }
        $sids = @(Ai-CoreSids $full)
        $why = ''
        try {
            foreach ($sid in $sids) { $r = Appx-EolMark $sid $full; if ($r) { $notes += $r } }
            Say ('  marked as end of life for {0} account(s); removing it...' -f $sids.Count) 'DarkGray'
            $why = Appx-RemoveOne $full $name
            if (-not $why) {
                # checked the way the check of the PC does it, a moment later: Windows can still have it for an account (or put it back);
                # then once more for each account it still lists, while the end-of-life marks are still in place
                Start-Sleep -Milliseconds $script:AiCoreSettleMs
                $left = @(Appx-UserStates $full $name)
                if ($left.Count) {
                    Say ('  Windows still lists it for: {0}; removing it for those accounts too' -f ($left -join '; ')) 'DarkGray'
                    $n0 = $Error.Count
                    foreach ($st in $left) {
                        $sid = [regex]::Match([string]$st, 'S-1-[0-9-]+').Value
                        if (-not $sid) { continue }
                        if ($sids -notcontains $sid) { [void](Appx-EolMark $sid $full); $sids += $sid }
                        try { Remove-AppxPackage -Package $full -User $sid -ErrorAction Stop } catch { $notes += (([string]$_.Exception.Message -split "`r?`n")[0]) }
                    }
                    Drop-ErrorsSince $n0
                    Start-Sleep -Milliseconds $script:AiCoreSettleMs
                    $left = @(Appx-UserStates $full $name)
                    if ($left.Count) { $why = ('Windows still has it for ' + ($left -join '; ')) }
                }
            } else {
                # name the accounts Windows still has it for, so the reason is plain
                $left = @(Appx-UserStates $full $name)
                if ($left.Count) { $why += (' (still installed for ' + ($left -join '; ') + ')') }
            }
        } finally {
            # the marks always come out again, also when something fails on the way or the run is stopped
            foreach ($sid in $sids) { Appx-EolClear $sid $full }
        }
        Say '  the end-of-life marks are taken out again (left in place they can stop Windows Update)' 'DarkGray'
        if ($why) {
            if ($notes.Count) { $why += ' (' + (($notes | Select-Object -First 2) -join '; ') + ')' }
            $fails += ('{0}: {1}' -f $name, $why)
            Say "  ! $name was not removed: $why" 'Yellow'
        } elseif (Appx-PendingFull $full $name) {
            Say '  Windows finishes removing it at the next restart (it is in use)' 'DarkGray'
        }
    }
    foreach ($k in @($m.Prov.Keys)) {
        if (-not $DryRun) { Remove-AppxProvisionedPackage -Online -PackageName $k -ErrorAction SilentlyContinue | Out-Null }
    }
    $script:Cache.Remove('appx')
    if ($fails.Count) { throw ('Windows did not remove ' + ($fails -join '; ')) }
    if (-not $DryRun) {
        # the last word is the check's own: a copy of the package under another name that is still installed is named too
        $m2 = Ai-CoreFind
        $still = @($m2.Pkgs.Keys | Where-Object { $m2.Live[$_] })
        if ($still.Count) {
            $what = @($still | ForEach-Object { $st = @(Appx-UserStates ([string]$_) ([string]$m2.Pkgs[$_])); if ($st.Count) { ('{0} ({1})' -f $_, ($st -join '; ')) } else { [string]$_ } })
            throw ('Windows still lists the AI core package as installed: ' + ($what -join '; '))
        }
        if (@($m2.Pkgs.Keys | Where-Object { $m2.Sys[$_] }).Count) {
            Say '  Windows keeps a copy for its own system account (S-1-5-18), as it does for some built-in packages; it is removed for every account that signs in, which is what counts' 'DarkGray'
        }
    }
}
function Custom-AiCore-Revert { param($p, $mine) Say '  (the removed AI package cannot be put back from here)' 'Yellow' }

# ------------------------------- Settings pages hidden by name -----
# Settings keeps its page-hiding policy in ONE text value, "hide:page1;page2" (or "showonly:..."). A setting here adds or takes out only
# its own page and leaves every other page in the list exactly as it was.
$script:ShPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'
$script:ShName = 'SettingsPageVisibility'
function Sh-Parse {
    param([string]$Text)
    $t = ([string]$Text).Trim()
    $mode = ''; $rest = ''
    $i = $t.IndexOf(':')
    if ($i -gt 0) { $mode = $t.Substring(0, $i).Trim().ToLowerInvariant(); $rest = $t.Substring($i + 1) }
    $pages = @(([string]$rest -split ';') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    return @{ Mode = $mode; Pages = $pages }
}
function Sh-Has {
    param($Pages, [string]$Key)
    foreach ($x in @($Pages)) { if ([string]$x -ieq $Key) { return $true } }
    return $false
}
function Sh-ReadText {
    $r = Reg-Read $script:ShPath $script:ShName
    if ($r.Exists) { return [string]$r.Value }
    return ''
}
function Custom-SettingsHide-Detect {
    param($p)
    $key = [string]$p.Data
    $t = Sh-Parse (Sh-ReadText)
    $listText = 'no page list'; if ($t.Mode) { $listText = ('{0} list: {1}' -f $t.Mode, (Now-Clip (@($t.Pages) -join '; '))) }
    $script:Now = ('Settings page "{0}": {1}, wanted hidden' -f $key, $listText)
    if ($t.Mode -eq 'showonly') { $script:Why = 'Settings here is limited to a list of pages (a "showonly" list), so a page cannot be hidden by name'; return 'NA' }
    if ($t.Mode -eq 'hide' -and (Sh-Has $t.Pages $key)) { return 'On' }
    return 'Off'
}
function Custom-SettingsHide-Snapshot { param($p) return $null }
function Custom-SettingsHide-Apply {
    param($p, $mine)
    $key = [string]$p.Data
    $t = Sh-Parse (Sh-ReadText)
    if ($t.Mode -eq 'showonly') { Say '  ! Settings is limited to a "showonly" list of pages here: nothing was changed' 'Yellow'; return }
    $pages = @($t.Pages)
    if ($t.Mode -ne 'hide') { $pages = @() }
    if (-not (Sh-Has $pages $key)) { $pages += $key }
    [void](Reg-Write $script:ShPath $script:ShName ('hide:' + ($pages -join ';')) 'String')
}
function Custom-SettingsHide-Revert {
    param($p, $mine)
    $key = [string]$p.Data
    $t = Sh-Parse (Sh-ReadText)
    if ($t.Mode -ne 'hide') { return }
    $left = @($t.Pages | Where-Object { [string]$_ -ine $key })
    if ($left.Count -eq 0) { [void](Reg-Remove $script:ShPath $script:ShName) }
    else { [void](Reg-Write $script:ShPath $script:ShName ('hide:' + ($left -join ';')) 'String') }
}

# ------------------------------------------------------------ Game Bar link handlers ---
# Without Game Bar, Windows answers an ms-gamebar:// link with "You'll need a new app to open this ms-gamebar link". Registering a handler
# that does nothing (systray.exe) for the two link types stops that. Both keys are ours only while their command is exactly the one below:
# a link handler that another program registered is never touched.
$script:GbSchemes = @('ms-gamebar', 'ms-gamebarservices')
$script:GbCmd = '%SystemRoot%/System32/systray.exe'
function Gb-Root { param([string]$scheme) return ('HKLM:\SOFTWARE\Classes\' + $scheme) }
# 'ours' | 'none' | 'other' for one link type
function Gb-Handler {
    param([string]$scheme)
    $c = Reg-Read ((Gb-Root $scheme) + '\shell\open\command') ''
    if (-not $c.Exists) { return 'none' }
    if ([string]$c.Value -ieq $script:GbCmd) { return 'ours' }
    return 'other'
}
function Custom-GameBarLinks-Detect {
    param($p)
    $h = @{}; $parts = @()
    foreach ($s in $script:GbSchemes) {
        $h[$s] = Gb-Handler $s
        $word = @{ ours = 'does nothing (set by this app)'; none = 'not set, Windows handles it'; other = 'another program handles it' }[$h[$s]]
        $parts += ('{0}: {1}' -f $s, $word)
    }
    $script:Now = (($parts -join '; ') + ', wanted a do-nothing handler')
    # a link another program handles is left alone, so it counts neither for nor against the setting
    $n = @($script:GbSchemes | Where-Object { $h[$_] -eq 'ours' }).Count
    $z = @($script:GbSchemes | Where-Object { $h[$_] -eq 'none' }).Count
    if ($n -eq 0 -and $z -eq 0) { $script:Why = 'another program has registered the ms-gamebar links here, so they are left alone'; return 'NA' }
    if ($z -eq 0) { return 'On' }
    if ($n -gt 0) { return 'Partial' }
    return 'Off'
}
function Custom-GameBarLinks-Snapshot { param($p) return $null }
function Custom-GameBarLinks-Apply {
    param($p, $mine)
    foreach ($s in $script:GbSchemes) {
        if ((Gb-Handler $s) -eq 'other') { Say "  note: another program handles $s links; it was left as it is" 'DarkGray'; continue }
        $root = Gb-Root $s
        [void](Reg-Write $root '' ('URL:' + $s) 'String')
        [void](Reg-Write $root 'URL Protocol' '' 'String')
        [void](Reg-Write $root 'NoOpenWith' '' 'String')
        [void](Reg-Write ($root + '\shell\open\command') '' $script:GbCmd 'String')
    }
}
function Custom-GameBarLinks-Revert {
    param($p, $mine)
    foreach ($s in $script:GbSchemes) {
        if ((Gb-Handler $s) -ne 'ours') { continue }
        [void](Reg-KeyRemove (Gb-Root $s))
    }
}

# ------------------------------------------------------------ startup apps -----
# Task Manager > Startup apps lists the Run keys and the two Startup folders. Whether an entry runs is a
# small binary value under ...\Explorer\StartupApproved (first byte 02 = on, 03 = off, then the time it was
# switched off). Writing that value for the current user is exactly what Task Manager does, and it changes
# nothing else: the entry itself is never deleted.
$script:ApprRoot = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
function Appr-Path { param([string]$hive, [string]$kind) return ($hive + ':\' + $script:ApprRoot + '\' + $kind) }
# Same text -> same short code on every run (the undo record is keyed by it)
function Short-Hash {
    param([string]$s)
    $h = 5381
    foreach ($ch in $s.ToCharArray()) { $h = ((($h * 33) -bxor [int]$ch) -band 0xFFFFFF) }
    return $h.ToString('x6')
}
function Startup-Entries {
    $out = @()
    $runKeys = @(
        @{ Kind = 'Run';   Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';             Label = 'the Run list of your account'; Tag = 'your account' }
        @{ Kind = 'Run';   Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';             Label = 'the Run list for all users'; Tag = 'all users' }
        @{ Kind = 'Run32'; Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Label = 'the Run list for all users (32-bit programs)'; Tag = 'all users, 32-bit' }
    )
    foreach ($rk in $runKeys) {
        $vals = @()
        try { $vals = @(Reg-Values $rk.Path) } catch { }          # one unreadable list must not hide the others
        foreach ($v in $vals) {
            $out += ,@{ Source = 'run'; From = $rk.Label; Tag = $rk.Tag; Show = [string]$v.Name; Name = [string]$v.Name; Appr = $rk.Kind; ApprName = [string]$v.Name
                        Run = $rk.Path; Full = ''; Cmd = [string]$v.Value }
        }
    }
    $dirs = @{ User = ''; Common = '' }
    try { $dirs = Startup-Dirs } catch { }
    $folders = @(
        @{ Path = [string]$dirs.User;   Label = 'the Startup folder of your account'; Tag = 'your Startup folder' }
        @{ Path = [string]$dirs.Common; Label = 'the Startup folder for all users'; Tag = 'all users Startup folder' }
    )
    foreach ($d in $folders) {
        if (-not $d.Path) { continue }
        $files = @()
        try { $files = @(Fs-Files $d.Path) } catch { }
        foreach ($f in $files) {
            $cmd = ''
            try { $cmd = Lnk-Target $f.Path } catch { }
            if (-not $cmd) { $cmd = [string]$f.Path }
            $show = $f.Name -replace '\.(lnk|url)$', ''
            $out += ,@{ Source = 'folder'; From = $d.Label; Tag = $d.Tag; Show = [string]$show; Name = [string]$f.Name; Appr = 'StartupFolder'; ApprName = [string]$f.Name
                        Run = ''; Full = [string]$f.Path; Cmd = $cmd }
        }
    }
    return $out
}
function Startup-Exists {
    param($e)
    if ($e.Source -eq 'run') { return [bool](Reg-Read $e.Run $e.Name).Exists }
    return [bool](Fs-Exists $e.Full)
}
function Appr-Read {
    param([string]$hive, $e)
    $r = @{ Exists = $false; Disabled = $false; Bytes = $null }
    $c = Reg-Read (Appr-Path $hive $e.Appr) $e.ApprName
    if ($c.Exists -and $c.Kind -eq 'Binary') {
        $b = @($c.Value)
        $r.Exists = $true
        $r.Bytes = $c.Value
        if ($b.Count -gt 0 -and (([int]$b[0]) -band 1) -eq 1) { $r.Disabled = $true }
    }
    return $r
}
# What Windows does for this user: this user's own record wins, else the machine-wide one, else it runs
function Startup-Disabled {
    param($e)
    foreach ($h in 'HKCU', 'HKLM') {
        $r = Appr-Read $h $e
        if ($r.Exists) { return [bool]$r.Disabled }
    }
    return $false
}
function Appr-Bytes {
    param([bool]$disabled)
    $b = New-Object byte[] 12
    if ($disabled) {
        $b[0] = 3
        $ts = [BitConverter]::GetBytes([int64][DateTime]::UtcNow.ToFileTimeUtc())
        [Array]::Copy($ts, 0, $b, 4, 8)
    } else {
        $b[0] = 2
    }
    return ,$b
}
function Custom-Startup-Detect {
    param($p)
    $e = $p.Data
    if (-not (Startup-Exists $e)) { $script:Why = 'it is no longer on the startup list'; $script:Now = ('Startup entry {0} ({1}): no longer on the list' -f $e.Show, $e.Tag); return 'NA' }
    $dis = Startup-Disabled $e
    $script:Now = ('Startup entry {0} ({1}): {2}, wanted switched off' -f $e.Show, $e.Tag, $(if ($dis) { 'switched off' } else { 'runs at sign-in' }))
    if ($dis) { return 'On' }
    return 'Off'
}
function Custom-Startup-Snapshot {
    param($p)
    $e = $p.Data
    $mine = Appr-Read 'HKCU' $e
    return @{ Exists = $mine.Exists; Bytes = $mine.Bytes; Unknown = (Startup-Disabled $e) }
}
function Custom-Startup-Apply {
    param($p, $mine)
    $e = $p.Data
    if ($DryRun) { Say ("  [dry] {0}: switched off in the Startup apps list" -f $e.Show) 'DarkGray'; return }
    $now = Appr-Read 'HKCU' $e
    if ($now.Exists -and $now.Disabled) { Say ("  {0} is already switched off for your account" -f $e.Show) 'DarkGray'; return }     # keeps the time Windows recorded
    $b = Appr-Bytes $true
    if (Reg-Write (Appr-Path 'HKCU' $e.Appr) $e.ApprName $b 'Binary' -Quiet) { Say ("  {0} will not start with Windows any more" -f $e.Show) 'DarkGray' }
}
function Custom-Startup-Revert {
    param($p, $mine)
    $e = $p.Data
    if ($DryRun) { Say ("  [dry] {0}: switched back on in the Startup apps list" -f $e.Show) 'DarkGray'; return }
    $path = Appr-Path 'HKCU' $e.Appr
    # the Windows default is no record of its own for the entry (it runs); only when a machine-wide record still keeps it off is an "on" record written for your account
    [void](Reg-Remove $path $e.ApprName -Quiet)
    if (Startup-Disabled $e) {
        $b = Appr-Bytes $false
        [void](Reg-Write $path $e.ApprName $b 'Binary' -Quiet)
    }
    Say ("  {0} starts with Windows again" -f $e.Show) 'DarkGray'
}

# (Re)builds the "Startup apps" rows from what is on this PC right now. Safe to call again at any time:
# it replaces the earlier rows, in the same place of the list.
function Add-StartupTweaks {
    if ($null -eq $script:StartupAt) { $script:StartupAt = $script:Catalog.Count }
    for ($i = $script:Catalog.Count - 1; $i -ge 0; $i--) {
        if ($script:Catalog[$i].Cat -eq $script:StartupCat) {
            [void]$script:ById.Remove([string]$script:Catalog[$i].Id)
            $script:Catalog.RemoveAt($i)
        }
    }
    $at = [Math]::Min([int]$script:StartupAt, $script:Catalog.Count)
    $seen = @{}
    $entries = @(Startup-Entries | Sort-Object { $_.Show.ToLower() }, { $_.From })
    $count = @{}
    foreach ($e in $entries) { $k = $e.Show.ToLower(); if ($count.ContainsKey($k)) { $count[$k]++ } else { $count[$k] = 1 } }
    foreach ($e in $entries) {
        $slug = ($e.Show.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
        if ($count[$e.Show.ToLower()] -gt 1) { $e.Show = $e.Show + ' (' + $e.Tag + ')' }     # the id above does not depend on this
        if ($slug.Length -gt 14) { $slug = $slug.Substring(0, 14).Trim('-') }
        if (-not $slug) { $slug = 'item' }
        $id = 'startup-' + $slug + '-' + (Short-Hash ($e.Source + '|' + $e.From + '|' + $e.Name))
        if ($seen.ContainsKey($id)) { continue }
        $seen[$id] = 1
        $shown = $e.Show; if ($shown.Length -gt 48) { $shown = $shown.Substring(0, 45) + '...' }
        $nl = "`r`n"
        $desc = 'On: ' + $shown + ' starts by itself when you sign in to Windows (the Windows default). Off: it does not start by itself. The program stays installed and you can still open it yourself; switching it back on puts it on the startup list again.' + $nl + $nl +
                'It starts from: ' + $e.From + $nl +
                'What it runs: ' + $e.Cmd + $nl + $nl +
                'If this belongs to a driver or hardware tool (audio, mouse or keyboard software, RGB lighting, a printer, antivirus), its tray icon, shortcuts and profiles will not work until you open it yourself. ' +
                'This is the same switch as Task Manager > Startup apps, for your account only; the entry itself is not deleted.'
        $info = 'Startup apps switch for "' + $e.Show + '": HKCU\' + $script:ApprRoot + '\' + $e.Appr + '\' + $e.ApprName + ' = off    (undo: the entry is removed, so it starts with Windows again)'
        Add-Tweak -Id $id -Cat $script:StartupCat -Inv -Def 'On' -Name ($shown + ' starts with Windows') -Desc $desc -At $at -Parts @(pCustom 'Startup' $info $e)
        $at++
    }
}

# --------------------------------------------- BitLocker drive encryption off -----
# A drive counts as encrypted while it is encrypted or being encrypted and can be unlocked now (a locked drive cannot be changed from here).
# A drive that is already being decrypted counts as done: the decryption carries on by itself.
function Bl-IsEncrypted {
    param($v)
    if ([string]$v.Lock -eq 'Locked') { return $false }
    $s = [string]$v.Status
    return ($s -ne 'FullyDecrypted' -and $s -ne 'DecryptionInProgress')
}
function Bl-Get { return @(Scan-Memo 'bl' { Bl-State })[0] }
# One drive in plain words: "C: (Windows drive): NOT encrypted - fully decrypted". Status words are the ones Windows reports, split into words.
function Bl-Describe {
    param($v)
    $kind = 'drive'
    if ([string]$v.Type -eq 'OperatingSystem') { $kind = 'Windows drive' } elseif ([string]$v.Type -eq 'Data') { $kind = 'data drive' }
    $words = ([string]$v.Status -creplace '([a-z])([A-Z])', '$1 $2').ToLower()
    if (-not $words) { $words = 'status not reported' }
    if ([string]$v.Lock -eq 'Locked') { return ('{0} ({1}): locked - {2}; it cannot be changed from here' -f $v.Mount, $kind, $words) }
    switch ([string]$v.Status) {
        'FullyDecrypted'       { return ('{0} ({1}): NOT encrypted - {2}' -f $v.Mount, $kind, $words) }
        'DecryptionInProgress' { return ('{0} ({1}): being decrypted - {2}, {3}% still encrypted; it carries on by itself' -f $v.Mount, $kind, $words, [int]$v.Pct) }
        'EncryptionInProgress' { return ('{0} ({1}): ENCRYPTED, still encrypting - {2}, {3}% done' -f $v.Mount, $kind, $words, [int]$v.Pct) }
        default                { return ('{0} ({1}): ENCRYPTED - {2}, {3}%' -f $v.Mount, $kind, $words, [int]$v.Pct) }
    }
}
function Custom-BitLocker-Detect {
    param($p)
    $b = Bl-Get
    if (-not $b.Ok) {
        $script:Now = 'BitLocker: could not be asked (neither Get-BitLockerVolume nor manage-bde gave an answer on this PC)'
        if ((Get-WinEdition).Class -eq 'Home') { $script:Why = 'BitLocker is not available from here (on Windows Home the encryption is called Device encryption: see Settings > Privacy & security > Device encryption)' }
        else { $script:Why = 'BitLocker is not available on this PC (some editions of Windows do not have it)' }
        return 'NA'
    }
    $enc = 0; $lines = @()
    foreach ($v in @($b.Vols)) { if (Bl-IsEncrypted $v) { $enc++ }; $lines += (Bl-Describe $v) }
    $via = ''; if ($b.Via) { $via = (' (asked through {0})' -f $b.Via) }
    $head = ('BitLocker{0}: {1} drive(s) listed, {2} encrypted, wanted none encrypted' -f $via, @($b.Vols).Count, $enc)
    if (@($b.Vols).Count -eq 0) { $head = ('BitLocker{0}: no drive with a letter was listed, so nothing is encrypted' -f $via) }
    $script:Now = (@($head) + $lines) -join "`n"
    if ($enc -gt 0) { return 'Off' }
    return 'On'
}
function Custom-BitLocker-Apply {
    param($p, $mine)
    $b = @(Bl-State)[0]
    if (-not $b.Ok) { Say '  BitLocker cannot be asked about on this PC, nothing was changed' 'Yellow'; return }
    $todo = @($b.Vols | Where-Object { Bl-IsEncrypted $_ })
    foreach ($v in @($b.Vols | Where-Object { [string]$_.Lock -eq 'Locked' })) { Say ("  {0} is locked, so it is left as it is (unlock it first to decrypt it)" -f $v.Mount) 'Yellow' }
    if ($todo.Count -eq 0) { Say '  no drive is encrypted, nothing to do' 'DarkGray'; return }
    # the other drives first, the Windows drive last (a drive that unlocks itself needs the Windows drive's key)
    $order = @($todo | Where-Object { [string]$_.Type -ne 'OperatingSystem' }) + @($todo | Where-Object { [string]$_.Type -eq 'OperatingSystem' })
    foreach ($v in $order) {
        if ($DryRun) { Say ("  [dry] Disable-BitLocker -MountPoint {0}" -f $v.Mount) 'DarkGray'; continue }
        if (Bl-Decrypt ([string]$v.Mount)) { Say ("  decrypting {0}: it carries on in the background and the drive stays usable" -f $v.Mount) 'DarkGray' }
    }
}
function Custom-BitLocker-Revert {
    param($p, $mine)
    # not offered: turning encryption on needs a key protector and a recovery key that you have to save yourself
    Say '  BitLocker is not turned back on from here. Use Settings > Privacy & security > Device encryption, or Control Panel > BitLocker Drive Encryption (it also lets you save the new recovery key).' 'Yellow'
}

# ------------------------------------------------ clean-up actions (run once) ----
# Disk Cleanup and the Temp folders are run when asked (Add-Tweak -Once): they never read "applied" and there is nothing to undo.
# Everything that touches the PC goes through the small functions Cm-* and Temp-* so that a test can stand in for them.
$script:VcRoot   = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
$script:CleanSet = 7351          # the number used with  cleanmgr /sagerun:7351  (the marks are the values StateFlags7351)
$script:CleanMinutes = 45        # how long the run is waited for
# The Disk Cleanup items that are run: the names of their keys under VolumeCaches. Left out ON PURPOSE (never marked): Recycle Bin,
# the Downloads folder (DownloadsFolder), Previous Windows installations (Windows.old), Device driver packages, the DirectX shader
# cache (D3D Shader Cache), Language resource files and User file versions.
$script:CleanItems = @('Active Setup Temp Folders', 'Delivery Optimization Files', 'Downloaded Program Files', 'Internet Cache Files', 'Old ChkDsk Files',
                       'Setup Log Files', 'System error memory dump files', 'System error minidump files', 'Temporary Files', 'Temporary Setup Files',
                       'Thumbnail Cache', 'Update Cleanup', 'Windows Error Reporting Files', 'Windows Upgrade Log Files')
$script:TempMinutes = 60         # what was changed more recently than this is left alone
function Cm-Exe { return ([string]$env:SystemRoot + '\System32\cleanmgr.exe') }
function Cm-FlagName { return ('StateFlags{0:0000}' -f [int]$script:CleanSet) }
# The names of the items Windows offers in Disk Cleanup
function Cm-Handlers {
    $o = @()
    foreach ($k in @(Reg-SubKeys $script:VcRoot)) { $o += ([string]$k -split '\\')[-1] }
    return $o
}
# Free bytes on the system drive, -1 when it cannot be read
function Cm-FreeBytes {
    try { $d = New-Object System.IO.DriveInfo (([string]$env:SystemDrive) + '\'); return [long]$d.AvailableFreeSpace } catch { return [long]-1 }
}
# Runs the marked items and waits (at most $Minutes). Returns Done, Code, Seconds and Error.
function Cm-Run {
    param([int]$Minutes = 45)
    $o = @{ Done = $false; Code = $null; Seconds = 0; Error = '' }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $pr = Start-Process -FilePath (Cm-Exe) -ArgumentList ('/sagerun:' + [int]$script:CleanSet) -PassThru -ErrorAction Stop
        if ($pr.WaitForExit($Minutes * 60000)) { $o.Done = $true; $o.Code = $pr.ExitCode }
    } catch { $o.Error = $_.Exception.Message }
    $o.Seconds = [int]$sw.Elapsed.TotalSeconds
    return $o
}
function Cm-Size {
    param([long]$b)
    if ($b -ge 1GB) { return ('{0:N1} GB' -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ('{0:N0} MB' -f ($b / 1MB)) }
    if ($b -ge 1KB) { return ('{0:N0} KB' -f ($b / 1KB)) }
    return ('{0} bytes' -f $b)
}
function Cm-Span {
    param([int]$s)
    if ($s -lt 90) { return ('{0} seconds' -f $s) }
    return ('{0} minutes' -f [int][math]::Round($s / 60))
}
function Custom-DiskCleanup-Detect {
    param($p)
    if (-not (Fs-Exists (Cm-Exe))) { $script:Why = 'Disk Cleanup (cleanmgr.exe) is not on this PC'; $script:Now = 'Disk Cleanup program (cleanmgr.exe): not found'; return 'NA' }
    $have = @(Cm-Handlers)
    $n = 0; foreach ($i in $script:CleanItems) { if ($have -contains $i) { $n++ } }
    if ($n -eq 0) {
        $script:Why = 'Windows lists none of the Disk Cleanup items this action cleans'
        $script:Now = ('Disk Cleanup program: found. Items it lists that are cleaned here: none of {0}' -f $script:CleanItems.Count)
        return 'NA'
    }
    $script:Now = ('Disk Cleanup program (cleanmgr.exe): found. Windows lists {0} of the {1} items cleaned here. It runs when you press Apply.' -f $n, $script:CleanItems.Count)
    return 'Off'
}
function Custom-DiskCleanup-Snapshot { param($p) return $null }
function Custom-DiskCleanup-Apply {
    param($p, $mine)
    if (-not (Fs-Exists (Cm-Exe))) { throw 'Disk Cleanup (cleanmgr.exe) is not on this PC' }
    $have = @(Cm-Handlers)
    $want = @(); foreach ($i in $script:CleanItems) { if ($have -contains $i) { $want += $i } }
    if ($want.Count -eq 0) { throw 'Windows lists none of the Disk Cleanup items this action cleans' }
    $flag = Cm-FlagName
    if ($DryRun) { Say ('  [dry] mark {0} Disk Cleanup items ({1} = 2), run cleanmgr /sagerun:{2}, then remove the marks' -f $want.Count, $flag, $script:CleanSet) 'DarkGray'; return }
    Say ('  marking {0} Disk Cleanup items...' -f $want.Count) 'Gray'
    # a mark of this number on any other item is removed first, so that only the items in the list are run
    foreach ($h in $have) {
        $key = $script:VcRoot + '\' + $h
        if ($want -contains $h) { [void](Reg-Write $key $flag 2 'DWord' -Quiet) } else { [void](Reg-Remove $key $flag -Quiet) }
    }
    $before = Cm-FreeBytes
    $res = $null
    try {
        Say '  running Disk Cleanup: a progress window opens, and Windows Update Cleanup can take several minutes...' 'Gray'
        $res = Cm-Run $script:CleanMinutes
    } finally {
        foreach ($h in $want) { [void](Reg-Remove ($script:VcRoot + '\' + $h) $flag -Quiet) }
    }
    $after = Cm-FreeBytes
    if ($res.Error) { throw ('Disk Cleanup could not be started: ' + $res.Error) }
    if (-not $res.Done) { $script:RunResult = ('Disk Cleanup was still running after {0} minutes; it carries on in its own window' -f $script:CleanMinutes); return }
    $txt = ('Disk Cleanup finished in {0}' -f (Cm-Span $res.Seconds))
    if ($before -ge 0 -and $after -ge 0) {
        $drive = [string]$env:SystemDrive
        if ($after -gt $before) { $txt += ('; free space on {0} went from {1} to {2} ({3} freed)' -f $drive, (Cm-Size $before), (Cm-Size $after), (Cm-Size ($after - $before))) }
        else { $txt += ('; free space on {0} is {1} (no gain measured)' -f $drive, (Cm-Size $after)) }
    }
    if ($null -ne $res.Code -and [int]$res.Code -ne 0) { $txt += ('; cleanmgr reported exit code {0}' -f $res.Code) }
    $script:RunResult = $txt
}
function Custom-DiskCleanup-Revert { param($p, $mine) Say '  (Disk Cleanup is a one-time action: there is nothing to put back)' 'DarkGray' }

# ---- the Temp folders ----
# A folder is only cleaned when it is named Temp (or Tmp) and is not a drive root: a TEMP variable that points somewhere else
# (a whole drive, a profile folder) is never emptied.
function Temp-Safe {
    param([string]$Path)
    $leaf = ''; $parent = ''
    try { $leaf = [string](Split-Path -Leaf $Path); $parent = [string](Split-Path -Parent $Path) } catch { }
    return ([bool]$leaf -and [bool]$parent -and ($leaf -imatch '^(temp|tmp)$'))
}
# The Temp folders that exist: your own (TEMP) and the one of Windows. Safe = it may be cleaned.
function Temp-Candidates {
    $o = @()
    foreach ($f in @([string]$env:TEMP, ([string]$env:SystemRoot + '\Temp'))) {
        $f = $f.Trim().TrimEnd('\')
        if (-not $f) { continue }
        if (-not (Fs-Exists $f)) { continue }
        if (@($o | Where-Object { $_.Path -ieq $f }).Count -gt 0) { continue }
        $o += ,@{ Path = $f; Safe = (Temp-Safe $f) }
    }
    return $o
}
function Temp-Count {
    param([string]$Path)
    $n = 0
    try { $n = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Ignore).Count } catch { }
    return $n
}
# Deletes what is old and not in use below one folder. A link to somewhere else is removed as a link: what it points to is never entered.
function Temp-Walk {
    param([string]$Dir, [datetime]$Cut, $R)
    foreach ($it in @(Get-ChildItem -LiteralPath $Dir -Force -ErrorAction Ignore)) {
        $link = (($it.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
        $old = ($it.LastWriteTime -lt $Cut)
        if ($it.PSIsContainer) {
            if ($link) {
                if ($old) { try { [System.IO.Directory]::Delete($it.FullName); $R.Removed++ } catch { $R.Left++ } } else { $R.Left++ }
                continue
            }
            Temp-Walk $it.FullName $Cut $R
            $kids = @(Get-ChildItem -LiteralPath $it.FullName -Force -ErrorAction Ignore)
            if ($kids.Count -eq 0) {
                if ($old) { try { [System.IO.Directory]::Delete($it.FullName); $R.Removed++ } catch { $R.Left++ } } else { $R.Left++ }
            }
        } else {
            if (-not $old) { $R.Left++; continue }
            $len = [long]0
            if (-not $link) { try { $len = [long]$it.Length } catch { } }
            try { Remove-Item -LiteralPath $it.FullName -Force -ErrorAction Stop; $R.Removed++; $R.Bytes += $len } catch { $R.Left++ }
        }
    }
}
# Cleans one Temp folder (the folder itself stays). Returns Removed, Left, Bytes.
function Temp-Clean {
    param([string]$Path, [int]$MinAgeMinutes = 60)
    $r = @{ Removed = 0; Left = 0; Bytes = [long]0 }
    Temp-Walk $Path ((Get-Date).AddMinutes(-$MinAgeMinutes)) $r
    return $r
}
function Custom-TempClean-Detect {
    param($p)
    $cand = @(Temp-Candidates)
    $safe = @($cand | Where-Object { $_.Safe })
    if ($safe.Count -eq 0) {
        $script:Why = 'no Temp folder was found'
        $script:Now = 'Temp folders: none found'
        if ($cand.Count -gt 0) { $script:Why = 'the TEMP folder is not named Temp, so it is never emptied'; $script:Now = ('Temp folders: {0} is not named Temp, left alone' -f $cand[0].Path) }
        return 'NA'
    }
    $lines = @('Temp folders (items at the top level):')
    foreach ($c in $cand) {
        if ($c.Safe) { $lines += ('  {0}: {1}' -f $c.Path, (Temp-Count $c.Path)) } else { $lines += ('  {0}: left alone (not named Temp)' -f $c.Path) }
    }
    $lines += 'It runs when you press Apply.'
    $script:Now = ($lines -join "`n")
    return 'Off'
}
function Custom-TempClean-Snapshot { param($p) return $null }
function Custom-TempClean-Apply {
    param($p, $mine)
    $cand = @(Temp-Candidates)
    $tot = @{ Removed = 0; Left = 0; Bytes = [long]0 }
    $used = 0
    foreach ($c in $cand) {
        if (-not $c.Safe) { Say ('  left alone: {0} (the folder is not named Temp)' -f $c.Path) 'Yellow'; continue }
        $used++
        if ($DryRun) { Say ('  [dry] delete what is in {0} (not changed in the last {1} minutes, not in use)' -f $c.Path, $script:TempMinutes) 'DarkGray'; continue }
        Say ('  cleaning {0} ...' -f $c.Path) 'Gray'
        $r = Temp-Clean $c.Path $script:TempMinutes
        Say ('    removed {0} item(s), {1}; left {2} (in use, or changed in the last {3} minutes)' -f $r.Removed, (Cm-Size $r.Bytes), $r.Left, $script:TempMinutes) 'DarkGray'
        $tot.Removed += $r.Removed; $tot.Left += $r.Left; $tot.Bytes += $r.Bytes
    }
    if ($used -eq 0) { throw 'no Temp folder to clean was found' }
    if ($DryRun) { return }
    $script:RunResult = ('Removed {0} item(s) from {1} Temp folder(s), {2} freed; {3} left (in use, or changed in the last {4} minutes)' -f $tot.Removed, $used, (Cm-Size $tot.Bytes), $tot.Left, $script:TempMinutes)
}
function Custom-TempClean-Revert { param($p, $mine) Say '  (removing temporary files is a one-time action: there is nothing to put back)' 'DarkGray' }

# =============================================================================
# THE CATALOG. One entry per setting you can switch on.
#   pReg  path name value [undo-value]  : undo-value = the WINDOWS DEFAULT that switching the setting off puts back; $null = delete the value (Windows default is "not set")
#   pSvc  name Disabled|Manual  undo-start-type  : the Windows default start type, put back when the setting is switched off
# "Preset" = part of Recommended Debloat (everything the original script did, except the UAC engine switch).
# =============================================================================
$cPriv   = 'Privacy and telemetry'
$cCloud  = 'Cloud, sync and OneDrive'
$cRemote = 'Remote access and VPN'
$cVpn    = $cRemote           # the one VPN setting lives on the Remote access page
$cShare  = 'Network sharing and discovery'
$cNic    = 'Network adapters and USB power'
$cPower  = 'Power plan and startup'
$script:PowerCat = $cPower             # the window puts "Compare Power Plans" on this page
$cGame   = 'Gaming and performance'
$script:DisplayCat = 'Display'          # the window puts its live display cards on this page
$cDisplay = $script:DisplayCat
$cNothing = 'Placebo Tweaks - Not Recommended (may do nothing, no proven benefit - each one says why)'
$cSec    = 'Security prompts (turning these off lowers protection)'
$cSvc    = 'Services'
$cLook   = 'Look and feel'
$cExplorer = 'File Explorer'
$cAi     = 'AI features'
$cEdge   = 'Microsoft Edge'
$cApps   = 'Remove apps'
$cLegacy = 'Legacy Windows features'
$cStore  = 'Storage and clean-up'
$script:TestingCat = 'Testing'          # always the last page in the menu; "Apply all" on "All settings" leaves it out
$cTest   = $script:TestingCat
$script:StartupCat ='Startup apps (switch off = does not start with Windows)'

$edge = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
$pol  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows'
$adv  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'

# ------------------------------------------------------------ Privacy ---------
Add-Tweak -Id 'telemetry' -Cat $cPriv -Inv -Def 'On' -Preset -Name 'Windows diagnostic data and error reports' `
    -Desc 'On: Windows sends diagnostic data to Microsoft and reports errors, as it does by default. Off: diagnostic data is set to the minimum Windows allows and error reporting is turned off. That covers the current error-reporting policy, the older error-reporting policy and sending extra data with a report. The Customer Experience program, app inventory collection and remote diagnostic-config downloads are turned off too. The minimum is "Off" (0) on Enterprise and Education; Windows Home and Pro treat 0 as 1 ("Required" only), so there the app sets 1, which also stops the optional diagnostic data from being switched on in Settings.' `
    -Parts @(
        pEd 'Ent' (pReg "$pol\DataCollection" 'AllowTelemetry' 0)
        pEd 'Home,Pro' (pReg "$pol\DataCollection" 'AllowTelemetry' 1)
        pReg "$pol\DataCollection" 'DoNotShowFeedbackNotifications' 1
        pReg "$pol\DataCollection" 'AllowDeviceNameInTelemetry' 0
        pReg "$pol\DataCollection" 'DisableOneSettingsDownloads' 1
        pReg "$pol\DataCollection" 'LimitDiagnosticLogCollection' 1
        pReg "$pol\DataCollection" 'LimitDumpCollection' 1
        pEd 'Ent' (pReg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry' 0)
        pEd 'Home,Pro' (pReg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry' 1)
        pReg "$pol\AppCompat" 'AITEnable' 0
        pReg "$pol\AppCompat" 'DisableInventory' 1
        pReg 'HKLM:\SOFTWARE\Policies\Microsoft\SQMClient\Windows' 'CEIPEnable' 0
        pReg "$pol\Windows Error Reporting" 'Disabled' 1
        pReg 'HKLM:\SOFTWARE\Policies\Microsoft\PCHealth\ErrorReporting' 'DoReport' 0
        pReg 'HKCU:\Software\Microsoft\Windows\Windows Error Reporting' 'DontSendAdditionalData' 1
    )

Add-Tweak -Id 'telemetry-tasks' -Cat $cPriv -Inv -Def 'On' -Preset -Name 'Telemetry scheduled tasks' `
    -Desc 'On: the compatibility appraiser, customer-experience, disk-diagnostic data and error-reporting tasks are enabled and run in the background, as Windows has them. Off: those tasks are disabled.' `
    -Parts @(
        pTask '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser'
        pTask '\Microsoft\Windows\Application Experience\ProgramDataUpdater'
        pTask '\Microsoft\Windows\Application Experience\StartupAppTask'
        pTask '\Microsoft\Windows\Application Experience\MareBackup'
        pTask '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator'
        pTask '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip'
        pTask '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector'
        pTask '\Microsoft\Windows\Feedback\Siuf\DmClient'
        pTask '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload'
        pTask '\Microsoft\Windows\Windows Error Reporting\QueueReporting'
        pTask '\Microsoft\Windows\Autochk\Proxy'
    )

Add-Tweak -Id 'ads' -Cat $cPriv -Inv -Def 'On' -Preset -Name 'Advertising ID and tailored experiences' `
    -Desc 'On: apps can use your advertising ID and Microsoft can tailor tips and ads (the Windows default). Off: apps can no longer use your advertising ID and tips and ads are not tailored. Microsoft no longer uses your diagnostic data to tailor tips and ads.' `
    -Parts @(
        pReg "$pol\AdvertisingInfo" 'DisabledByGroupPolicy' 1
        pReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0 1
        pReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0 1
        pReg 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent' 'DisableTailoredExperiencesWithDiagnosticData' 1
    )

Add-Tweak -Id 'activity' -Cat $cPriv -Inv -Def 'On' -Preset -Name 'Activity history' `
    -Desc 'On: Windows records what you open and do (the old Timeline) and can upload it. Off: Windows stops recording and uploading it.' `
    -Parts @(
        pReg "$pol\System" 'PublishUserActivities' 0
        pReg "$pol\System" 'EnableActivityFeed' 0
        pReg "$pol\System" 'UploadUserActivities' 0
    )

Add-Tweak -Id 'feedback' -Cat $cPriv -Inv -Def 'On' -Preset -Name 'Feedback pop-ups' `
    -Desc 'On: Windows asks you for feedback now and then. Off: Windows no longer asks you for feedback.' `
    -Parts @(
        pReg 'HKCU:\Software\Microsoft\Siuf\Rules' 'NumberOfSIUFInPeriod' 0
    )

Add-Tweak -Id 'inking' -Cat $cPriv -Inv -Def 'On' -Preset -Name 'Inking, typing and speech data collection' `
    -Desc 'On: Windows may collect what you type and write to personalise suggestions. It may also send handwriting data. Off: that collection is stopped and your consent to online speech recognition is withdrawn. Typing insights (the statistics Windows keeps about your typing) are turned off as well, and so is the "Improve inking and typing" switch that sends your inking and typing samples to Microsoft.' `
    -Parts @(
        pReg 'HKCU:\Software\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 1 0
        pReg 'HKCU:\Software\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 1 0
        pReg 'HKCU:\Software\Microsoft\InputPersonalization\TrainedDataStore' 'HarvestContacts' 0 1
        pReg 'HKCU:\Software\Microsoft\Personalization\Settings' 'AcceptedPrivacyPolicy' 0
        pReg 'HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted' 0
        pReg 'HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization' 'AllowInputPersonalization' 0
        pReg "$pol\TabletPC" 'PreventHandwritingDataSharing' 1
        pReg "$pol\HandwritingErrorReports" 'PreventHandwritingErrorReports' 1
        pReg 'HKCU:\Software\Microsoft\input\Settings' 'InsightsEnabled' 0
        pReg 'HKCU:\Software\Microsoft\Input\TIPC' 'Enabled' 0 1
    )

Add-Tweak -Id 'location' -Cat $cPriv -Inv -Def 'On' -Name 'Location services' `
    -Desc 'On: Windows can tell apps where you are (the Location switch in Settings still decides per app). Off: location is turned off for the whole PC, and so is the Geolocation service. Weather, Maps and "find my device" no longer know where you are. "Set time zone automatically" in Settings also stops working (it is greyed out while location is off), so the clock will not follow you to a new time zone by itself.' `
    -Parts @(
        pReg "$pol\LocationAndSensors" 'DisableLocation' 1
        pReg "$pol\LocationAndSensors" 'DisableWindowsLocationProvider' 1
        pReg "$pol\LocationAndSensors" 'DisableLocationScripting' 1
        pReg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' 'Value' 'Deny' 'Allow' 'String'
        pSvc 'lfsvc' 'Disabled' 'Manual'
    )

Add-Tweak -Id 'find-my-device' -Cat $cPriv -Inv -Def 'Depends on the PC' -Name 'Find my device' `
    -Desc 'On: Find my device is left to Windows. If you switched it on in Settings > Privacy and security > Find my device, this PC and its location are registered with your Microsoft account so you can locate it from account.microsoft.com/devices. Off: it is turned off by policy, the PC is not registered and Find my device stops working. Location services are a separate setting. Microsoft lists this policy for Windows Pro, Enterprise and Education and does not list Home, so Windows Home may ignore it; if the switch in Settings still works there, turn it off by hand.' `
    -Parts @(
        pReg 'HKLM:\SOFTWARE\Policies\Microsoft\FindMyDevice' 'AllowFindMyDevice' 0
    )

Add-Tweak -Id 'device-metadata' -Cat $cPriv -Inv -Def 'On' -Name 'Device info and apps from the internet' `
    -Desc 'On: when you plug in a device, Windows can ask Microsoft for its details (name, picture and the maker''s device app) and download them. Off: Windows does not download device information from the internet, and the policy overrides the "Device Installation Settings" choice. Drivers are not affected, they still come from Windows Update or your own installer. A new device may show with a generic icon and name. "Driver updates through Windows Update" sets that dialog''s own switch too; this one adds the policy.' `
    -Parts @(
        pReg "$pol\Device Metadata" 'PreventDeviceMetadataFromNetwork' 1
    )

Add-Tweak -Id 'tracking' -Cat $cPriv -Inv -Def 'On' -Preset -Name 'Language list sharing and app tracking' `
    -Desc 'On: websites can read your language list, and Start tracks which apps you launch to rank them. Off: websites cannot read your language list and Start no longer tracks which apps you launch.' `
    -Parts @(
        pReg 'HKCU:\Control Panel\International\User Profile' 'HttpAcceptLanguageOptOut' 1
        pReg $adv 'Start_TrackProgs' 0 1
    )

Add-Tweak -Id 'bgapps' -Cat $cPriv -Inv -Def 'On' -Preset -Risk 'note' -Name 'Store apps running in the background' -NotRec 'Reported to stop programs from showing up in Start search.' `
    -Desc 'On: Microsoft Store (UWP) apps can run and fetch data while you are not using them. Off: they stop running and fetching data in the background. Normal desktop programs such as Steam, Discord and browsers are not affected.' `
    -Parts @(
        pReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1 0
        pReg "$pol\AppPrivacy" 'LetAppsRunInBackground' 2
    )

Add-Tweak -Id 'defender-samples' -Cat $cPriv -Inv -Def 'On' -Preset -Name 'Defender automatic sample submission' `
    -Desc 'On: Windows Defender may upload suspicious files to Microsoft by itself. Off: Defender keeps scanning as normal; it just never uploads suspicious files by itself.' `
    -Parts @(
        pReg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet' 'SubmitSamplesConsent' 2
    )

Add-Tweak -Id 'clipboard-history' -Cat $cPriv -Inv -Def 'On' -Preset -Name 'Allow clipboard history (Win+V)' `
    -Desc 'On: clipboard history is allowed. Windows keeps it off until you turn it on in Settings > System > Clipboard, and Win+V then shows your list. Off: Windows stops keeping a list of the things you copied, so Win+V shows no history and the switch in Settings is greyed out. Normal copy and paste (Ctrl+C, Ctrl+V) is not affected. This is separate from "Allow cloud clipboard", which only controls sharing the list with your other devices.' `
    -Parts @(
        pReg "$pol\System" 'AllowClipboardHistory' 0
        pReg 'HKCU:\Software\Microsoft\Clipboard' 'EnableClipboardHistory' 0
    )

# -------------------------------------------------------------- Cloud ---------
Add-Tweak -Id 'settingsync' -Cat $cCloud -Inv -Def 'On' -Name 'Settings sync with your Microsoft account' `
    -Desc 'On: your theme, Wi-Fi passwords and other Windows settings can sync with your Microsoft account. Off: settings sync is blocked and its two background tasks are disabled.' `
    -Parts @(
        pReg "$pol\SettingSync" 'DisableSettingSync' 2
        pReg "$pol\SettingSync" 'DisableSettingSyncUserOverride' 1
        pTask '\Microsoft\Windows\SettingSync\BackgroundUploadTask'
        pTask '\Microsoft\Windows\SettingSync\NetworkStateChangeTask'
    )

Add-Tweak -Id 'clipboard' -Cat $cCloud -Inv -Def 'On' -Name 'Allow cloud clipboard' `
    -Desc 'On: you can share your clipboard history with your other devices. Windows keeps this off until you turn it on in Settings. Off: clipboard history (Win+V) still works, but it is not uploaded or shared with other devices.' `
    -Parts @(
        pReg "$pol\System" 'AllowCrossDeviceClipboard' 0
        pReg 'HKCU:\Software\Microsoft\Clipboard' 'CloudClipboardAutomaticUpload' 0
    )

Add-Tweak -Id 'crossdevice' -Cat $cCloud -Inv -Def 'On' -Name 'Nearby sharing and Share across devices' `
    -Desc 'On: Nearby Sharing, "Continue on this PC" and the Connected Devices Platform service that powers them are available. Off: all three are turned off.' `
    -Parts @(
        pReg "$pol\System" 'EnableCdp' 0
        pReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CDP' 'CdpSessionUserAuthzPolicy' 0 1
        pReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CDP' 'NearShareChannelUserAuthzPolicy' 0 1
        pReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CDP' 'RomeSdkChannelUserAuthzPolicy' 0 1
        pSvc 'CDPSvc' 'Disabled' 'AutomaticDelayed'
    )

Add-Tweak -Id 'onedrive-policy' -Cat $cCloud -Inv -Def 'On' -Name 'OneDrive sync and its File Explorer entry' `
    -Desc 'On: OneDrive can sync, and it shows in the File Explorer side bar. Off: a policy stops OneDrive from syncing even if it is installed, and its entry in File Explorer''s side bar is hidden. Fully reversible.' `
    -Parts @(
        pReg "$pol\OneDrive" 'DisableFileSyncNGSC' 1
        pReg 'Registry::HKEY_CLASSES_ROOT\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}' 'System.IsPinnedToNameSpaceTree' 0 1
    )

Add-Tweak -Id 'onedrive-remove' -Cat $cCloud -Inv -Def 'On' -OneWay -Risk 'note' -Name 'OneDrive app' `
    -Desc 'On: OneDrive is installed. Off: runs the OneDrive uninstaller and removes leftovers (a OneDrive folder that still has files in it is left alone). It cannot be switched back on from here; reinstall it later with  winget install Microsoft.OneDrive.' `
    -Parts @(
        pCustom 'OneDrive' 'OneDrive is stopped and uninstalled, leftover folders and its startup entry are removed'
    )

Add-Tweak -Id 'deliveryopt' -Cat $cCloud -Inv -Def 'On' -Name 'Windows Update peer-to-peer sharing' `
    -Desc 'On: Windows can fetch updates from other PCs and share them with other PCs (the Windows default). That is Delivery Optimization; the sharing can reach PCs on your network or on the internet. Off: it downloads updates only from Microsoft and never uploads them to other PCs. The "Allow downloads from other PCs" switch in Settings is set to off too (that value belongs to the Delivery Optimization service account; Windows protects it on some builds, and where it does it is left as it is).' `
    -Parts @(
        pReg "$pol\DeliveryOptimization" 'DODownloadMode' 0
        pRegSoft 'Registry::HKEY_USERS\S-1-5-20\Software\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Settings' 'DownloadMode' 0
        pSvc 'DoSvc' 'Manual' 'AutomaticDelayed'
    )

# -------------------------------------------------------------- Remote --------
Add-Tweak -Id 'rdp' -Cat $cRemote -Inv -Def 'On' -Name 'Remote Desktop services' `
    -Desc 'On: the Remote Desktop services and firewall rules are left as Windows has them. Windows blocks Remote Desktop connections until you allow them in Settings, so nobody can connect unless you have done that. Off: Remote Desktop is blocked: the services are disabled and the firewall rules are switched off. A setting also blocks connections, so nobody can connect to this PC with Remote Desktop.' `
    -Parts @(
        pReg 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' 'fDenyTSConnections' 1 1
        pReg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' 'fDenyTSConnections' 1
        pSvc 'TermService' 'Disabled' 'Manual'
        pSvc 'UmRdpService' 'Disabled' 'Manual'
        pSvc 'SessionEnv' 'Disabled' 'Manual'
        pFw 'Remote Desktop'
    )

Add-Tweak -Id 'remote-assist' -Cat $cRemote -Inv -Def 'On' -Name 'Remote Assistance' `
    -Desc 'On: "Allow Remote Assistance connections to this computer" is left as Windows has it (allowed). Off: it is turned off and its firewall rules are switched off.' `
    -Parts @(
        pReg 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' 'fAllowToGetHelp' 0 1
        pReg 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' 'fAllowFullControl' 0 1
        pReg 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance' 'fAllowToGetHelp' 0 1
        pReg 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance' 'fAllowFullControl' 0 1
        pReg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' 'fAllowToGetHelp' 0
        pFw 'Remote Assistance'
    )

Add-Tweak -Id 'quickassist' -Cat $cRemote -Inv -Def 'On' -OneWay -Name 'Quick Assist app' `
    -Desc 'On: the Quick Assist remote-help app is installed. Off: the app (and the older Quick Assist Windows capability) is removed. It cannot be switched back on from here; reinstall it from the Microsoft Store if you ever need it.' `
    -Parts @(
        pCap 'App.Support.QuickAssist*'
        pAppx 'MicrosoftCorporationII.QuickAssist'
    )

Add-Tweak -Id 'winrm' -Cat $cRemote -Inv -Def 'On' -Name 'PowerShell remoting (WinRM)' `
    -Desc 'On: the Windows Remote Management service and its firewall rules are left as Windows has them. Off: the service is disabled and its firewall rules are switched off. This PC then cannot be managed over the network with PowerShell remoting.' `
    -Parts @(
        pSvc 'WinRM' 'Disabled' 'Manual'
        pFw 'Windows Remote Management'
        pFw 'Windows Remote Management (Compatibility)'
    )

Add-Tweak -Id 'remote-mgmt' -Cat $cRemote -Inv -Def 'On' -Name 'Other remote management services' `
    -Desc 'On: the remote-management services and firewall rules are left as Windows has them. These are Remote Registry, Routing and Remote Access, the legacy RPC locator and the OpenSSH server (if installed), and the remote event log, scheduled task, service, volume and WMI firewall rules. Off: those services are disabled and those firewall rules are switched off.' `
    -Parts @(
        pSvc 'RemoteRegistry' 'Disabled' 'Disabled'
        pSvc 'RpcLocator' 'Disabled' 'Manual'
        pSvc 'RemoteAccess' 'Disabled' 'Disabled'
        pSvc 'sshd' 'Disabled' 'Manual'
        pFw 'Remote Event Log Management'
        pFw 'Remote Scheduled Tasks Management'
        pFw 'Remote Service Management'
        pFw 'Remote Volume Management'
        pFw 'Windows Management Instrumentation (WMI)'
    )

# ---------------------------------------------------------------- VPN ---------
# ------------------------------------------------------------- Sharing --------
Add-Tweak -Id 'fileshare' -Cat $cShare -Inv -Def 'On' -Preset -Risk 'note' -Name 'File and printer sharing' `
    -Desc 'On: file and printer sharing is left as Windows has it. That covers the Server service, the default C$ and ADMIN$ shares, the File and Printer Sharing firewall rules and the adapter binding. Off: file and printer sharing is switched off, so other PCs cannot reach files or printers on this PC. The Server service is disabled, the default shares are off, the firewall rules are switched off and File and Printer Sharing is unbound from your network adapters. You can still open shares on a NAS or other PCs (Client for Microsoft Networks stays on).' `
    -Parts @(
        pSvc 'LanmanServer' 'Disabled' 'Automatic'
        pReg 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' 'AutoShareWks' 0
        pFw 'File and Printer Sharing'
        pBind 'ms_server'
    )

Add-Tweak -Id 'discovery' -Cat $cShare -Inv -Def 'On' -Preset -Name 'Network discovery and UPnP hosting' `
    -Desc 'On: network discovery is left as Windows has it. Off: this PC stops announcing itself and stops looking for devices on the network. The Function Discovery, Link-Layer Topology Discovery, UPnP Device Host and Network Connected Devices services are disabled, and Network Discovery''s firewall rules and adapter bindings are removed. SSDP Discovery is deliberately left alone, so games that use UPnP port mapping keep working. Side effect: Windows may stop finding new network printers and other devices by itself; adding a printer by its IP address still works.' `
    -Parts @(
        pSvc 'FDResPub' 'Disabled' 'Manual'
        pSvc 'fdPHost' 'Disabled' 'Manual'
        pSvc 'lltdsvc' 'Disabled' 'Manual'
        pSvc 'upnphost' 'Disabled' 'Manual'
        pSvc 'NcdAutoSetup' 'Disabled' 'Manual'
        pFw 'Network Discovery'
        pBind 'ms_lltdio'
        pBind 'ms_rspndr'
    )

Add-Tweak -Id 'legacy-names' -Cat $cShare -Inv -Def 'On' -Preset -Risk 'note' -Name 'Old name lookups (LLMNR, mDNS, NetBIOS)' `
    -Desc 'On: the three legacy ways of finding devices by name (LLMNR, mDNS and NetBIOS over TCP/IP) work as Windows has them. Off: all three are turned off. Names that DNS can resolve keep working; a few old NAS boxes or printers that are only found by NetBIOS name may no longer show up by name.' `
    -Parts @(
        pReg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' 'EnableMulticast' 0
        pReg 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' 'EnableMDNS' 0
        pRegDyn -Info 'NetBIOS over TCP/IP: NetbiosOptions = 2 on every network interface    (undo: 0)' -Gen {
            foreach ($k in @(Reg-SubKeys 'HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces')) {
                pReg $k 'NetbiosOptions' 2 0
            }
        }
    )

Add-Tweak -Id 'smb1' -Cat $cShare -Inv -Def 'Off' -Preset -Reboot -Name 'SMB1 protocol' `
    -Desc 'On: the SMB1 Windows feature is installed (SMB1 is an obsolete, insecure file-sharing protocol that modern Windows no longer needs). Off: it is removed. A clean Windows 11 does not have it installed, so on most PCs this already reads Off. Only switch it on for very old devices.' `
    -Parts @(
        pFeat 'SMB1Protocol'
    )

# ----------------------------------------------------- Adapters and USB -------
Add-Tweak -Id 'nic-turnoff' -Cat $cNic -Inv -Def 'On' -Reboot -Name 'Windows turning off network adapters' `
    -Desc 'On: Windows may turn off a network adapter to save power (the Windows default). The box "Allow the computer to turn off this device to save power" is ticked. Off: the "turn off this device to save power" box is unticked on every physical network adapter, through Windows'' own adapter settings (what Device Manager shows); each adapter restarts for a moment, so the connection drops for a few seconds. Wake-on-LAN settings you chose are kept.' `
    -Parts @(
        pCustom 'NicTurnOff' 'Device Manager > network adapter > Power Management > "Allow the computer to turn off this device": off, on every physical adapter'
    )

Add-Tweak -Id 'nic-eee' -Cat $cNic -Inv -Def 'On' -Preset -Reboot -Name 'Network adapter power saving' `
    -Desc 'On: the driver''s own power-saving options (Energy-Efficient Ethernet, Green Ethernet, Wi-Fi power save and similar) stay as the driver has them. That includes Power Saving Mode and Ultra Low Power. Off: those options are switched off on your adapters. They can cause latency spikes and brief disconnects. Only options your adapter actually has are touched.' `
    -Parts @(
        pCustom 'NicEee' 'Adapter driver "Advanced" tab: Energy-Efficient Ethernet, Green Ethernet, power-saving mode options -> off (where present)'
    )

Add-Tweak -Id 'nic-suspend' -Cat $cNic -Inv -Def 'On' -Preset -Reboot -Name 'Network adapter selective suspend' `
    -Desc 'On: Windows may suspend USB network adapters and put adapters to sleep when the cable is unplugged, as it does by default. Off: Windows does neither. Not shown as available on PCs whose adapters do not offer these options.' `
    -Parts @(
        pCustom 'NicSuspend' 'Adapter power management: Selective Suspend and Device Sleep on Disconnect -> off (where present)'
    )

Add-Tweak -Id 'usb-power' -Cat $cNic -Inv -Def 'On' -Preset -Name 'USB power saving' `
    -Desc 'On: Windows may turn off USB devices to save power (the Windows default). The box "Allow the computer to turn off this device to save power" is ticked and selective suspend is on. Off: the "turn off this device" box is unticked for every USB device and selective suspend is off. Devices plugged in later start with Windows'' defaults, so press Apply again after adding new ones. Switching it back on gives each device what it had before this app first changed it (its driver can ship its own values, and some USB devices need selective suspend off).' `
    -Parts @(
        pCustom 'UsbPower' 'Every USB device: "Allow the computer to turn off this device" off, and selective suspend off in its driver settings'
    )

# --------------------------------------------------------------- Power --------
# The six power plan switches (-Plan): On = the plan is installed, Off = it is deleted. Switching one on does not change the active plan;
# "Make active" on its card does. Switching the active plan off makes another plan active first; the last plan is never deleted.
$planTail = ' Switching it on only installs it: "Make active" on its card makes it the plan Windows uses, and the card says which plan is active. Switching it off deletes this plan and no other; if it is the active plan, Balanced (or another installed plan) is made active first, and the last plan on the PC is never deleted. "Reinstall" on the card of an installed plan makes it again the way Headroom installs it (anything changed inside it is gone); the active plan stays the active plan.'
Add-Tweak -Id 'plan-balanced' -Cat $cPower -Def 'On' -Plan 'PlanBalanced' -Name 'Balanced power plan' `
    -Desc ('On: the Balanced plan is installed, under its usual ID and with the settings Windows ships it with. It is the plan Windows uses unless you choose another. Off: the Balanced plan is deleted. Once it was deleted Windows has no copy left: Headroom asks Windows to put back its own (Restore plan defaults), or makes it under its usual ID from the values Windows keeps as its defaults. Every value is then checked against those defaults, and Compare Power Plans shows whether it still matches them.' + $planTail) `
    -Parts @(
        pCustom 'PlanBalanced' 'powercfg /duplicatescheme 381b4222-f694-41f0-9685-ff5bb260df2e under the same ID; once it was deleted, Windows'' own Restore plan defaults (PowerRestoreIndividualDefaultPowerScheme), else a copy under that ID with the values Windows keeps as its defaults; then each value is checked against those defaults (to install) / powercfg /delete (to delete)'
    )

Add-Tweak -Id 'plan-highperf' -Cat $cPower -Def 'On' -Plan 'PlanHighPerf' -Name 'High Performance power plan' `
    -Desc ('On: the High Performance plan is installed, under its usual ID and with the settings Windows ships it with (once it was deleted, as for Balanced: Windows'' own Restore plan defaults, or the values Windows keeps as its defaults, each one checked). Off: it is deleted. On a PC with Modern Standby (most laptops and some desktops) Windows may offer only Balanced and refuse to create it; nothing is changed then.' + $planTail) `
    -Parts @(
        pCustom 'PlanHighPerf' 'powercfg /duplicatescheme 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c under the same ID; once it was deleted, Windows'' own Restore plan defaults (PowerRestoreIndividualDefaultPowerScheme), else a copy under that ID with the values Windows keeps as its defaults; then each value is checked against those defaults (to install) / powercfg /delete (to delete)'
    )

Add-Tweak -Id 'ultimate' -Cat $cPower -Def 'Off' -Plan 'Ultimate' -Name 'Ultimate Performance power plan' `
    -Desc ('On: the Ultimate Performance plan is installed. It is High Performance with the small delays of fine-grained power management removed. It is installed exactly as Windows makes it, from Windows'' own hidden copy; Headroom changes nothing in it (builds before 113 also turned off USB and Wi-Fi power saving in it: switch it off and on again to get Windows'' own). Off: it is deleted, also a copy an older Headroom build made under another ID. On a PC with Modern Standby Windows may refuse to create it; nothing is changed then.' + $planTail) `
    -Parts @(
        pCustom 'Ultimate' 'powercfg /duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 under the same ID, nothing changed in it (to install) / powercfg /delete (to delete)'
    )

Add-Tweak -Id 'ultimate-mod' -Cat $cPower -Def 'Off' -Plan 'UltimateMod' -Name 'Ultimate Plan Modified' `
    -Desc ('On: Ultimate Plan Modified is installed: Windows'' own Ultimate Performance plan with three changes inside it, the way Headroom installed Ultimate Performance up to build 112. USB selective suspend is off, USB 3 link power management is off and the Wi-Fi adapter''s power saving is at Maximum performance, plugged in and on battery. It has an ID of its own, so Windows'' Ultimate Performance can stay installed next to it as Windows ships it. Off: it is deleted. On a PC with Modern Standby Windows may refuse to make Ultimate Performance; nothing is changed then.' + $planTail) `
    -Parts @(
        pCustom 'UltimateMod' 'powercfg /duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 96159c62-1115-4153-83ea-271a2032c250, named "Ultimate Plan Modified", then /setacvalueindex and /setdcvalueindex 0 for USB selective suspend, USB 3 link power management and Wi-Fi power saving (to install) / powercfg /delete (to delete)'
    )

Add-Tweak -Id 'khorvie-plan' -Cat $cPower -Def 'Off' -Plan 'Khorvie' -Name 'Khorvie''s power plan' `
    -Desc ('On: Khorvie''s PowerPlan, a third-party gaming power plan (not one of Windows'' own), is installed. Its plan file is built into Headroom and checked before it is used. Among its settings: minimum processor state 100%, processor boost mode Aggressive, USB selective suspend and USB 3 link power management off, interrupts that Windows may move sent to logical processor 1, wake timers off, and the display and hard disk never turned off. Keeping the processor at its highest state means more power use and heat when the PC is idle. Off: it is deleted.' + $planTail) `
    -Parts @(
        pCustom 'Khorvie' 'powercfg /import of the built-in plan file (Khorvie''s PowerPlan, ID 8070b076-188f-428d-a9d6-e1a2f99fad5d) (to install) / powercfg /delete (to delete)'
    )

Add-Tweak -Id 'lowlatency-plan' -Cat $cPower -Def 'Off' -Plan 'LowLatency' -Name 'Low Latency power plan' `
    -Desc ('On: the Low Latency Power Plan is installed. It is amit''s low latency powerplan (the idle enabled version, v3), a third-party gaming power plan (not one of Windows'' own), which Headroom installs under the name Low Latency Power Plan. Its plan file is built into Headroom and checked before it is used. Among its settings: performance increase and decrease thresholds 1% (the clock speed goes up as soon as a core is busy), throttle states off, idle promote and demote thresholds 100%, interrupts that Windows may move sent to any unparked processor, USB selective suspend and USB 3 link power management off, NVMe drives given 60 seconds before their idle power states, wake timers off, and the display and hard disk never turned off. It does not set the minimum processor state, boost mode, energy performance preference, core parking, idle states or PCI Express power management, so Windows'' defaults apply to those; idle states stay allowed. Sleep works as usual. Off: it is deleted.' + $planTail) `
    -Parts @(
        pCustom 'LowLatency' 'powercfg /import of the built-in plan file (amit''s low latency powerplan, ID 95c05c40-e7bb-47bb-8baf-f152b0e1ffcc), then powercfg /changename to "Low Latency Power Plan" (to install) / powercfg /delete (to delete)'
    )

Add-Tweak -Id 'hibernate' -Cat $cPower -Inv -Def 'On' -Risk 'note' -Name 'Fast Startup and hibernation' `
    -Desc 'On: Fast Startup and hibernation work (hiberfil.sys, several GB, is kept on the drive). Off: Shut down becomes a real shutdown and hiberfil.sys is deleted. That means no half-hibernated kernel state, which helps with driver and update glitches. Hibernate is no longer available; Sleep still works.' `
    -Parts @(
        pReg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 0 1
        pReg 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled' 0 1
        pCustom 'Hibernate' 'powercfg /h off   (undo: powercfg /h on)'
    )

# ------------------------------------------------------- Startup apps ---------
# One switch per program on Task Manager's Startup apps list (built from this PC, so it can differ each run).
# If the PC cannot be read for some reason, the group is simply missing; the rest of the app is not affected.
try { Add-StartupTweaks } catch { }

# ---------------------------------------------------------------- Gaming ------
Add-Tweak -Id 'gamedvr' -Cat $cGame -Inv -Def 'On' -Preset -Name 'Xbox Game Bar and background recording' `
    -Desc 'On: Xbox Game Bar can record clips in the background and the Xbox button on a controller opens it. Its start-up tip shows. Off: it stops recording clips in the background, which can cost frames. The controller button no longer opens it and the start-up tip is hidden. Windows Game Mode is not affected. The Game Bar app itself stays installed and Win+G may still open it; "Game Bar app" under Remove apps takes the app out completely. Off also tries to turn off Game Bar''s presence writer, a background helper that tells Game Bar which game is running; Windows protects that value on some builds, and where it does it is left as it is and the rest of the setting still applies.' `
    -Parts @(
        pReg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0 1
        pReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0 1
        pReg "$pol\GameDVR" 'AllowGameDVR' 0
        pReg 'HKCU:\Software\Microsoft\GameBar' 'UseNexusForGameBarEnabled' 0
        pReg 'HKCU:\Software\Microsoft\GameBar' 'ShowStartupPanel' 0
        pRegSoft 'HKLM:\SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId\Windows.Gaming.GameBar.PresenceServer.Internal.PresenceWriter' 'ActivationType' 0 1
    )

Add-Tweak -Id 'gamebar-links' -Cat $cGame -Def 'Off' -Risk 'note' -Name 'No "ms-gamebar" pop-up (Game Bar gone)' `
    -Desc 'On: ms-gamebar and ms-gamebarservices links are sent to a program that does nothing (systray.exe), so Windows never shows "You''ll need a new app to open this ms-gamebar link". Off: Windows handles those links as shipped. Game Bar opens them, and if Game Bar has been removed the pop-up appears. Switch this on only if you removed Game Bar (Remove apps) or never use it: while it is on, anything that opens an ms-gamebar link, such as the Game Bar button on a controller, does nothing. Switching it off deletes the two link entries again. If another program has registered one of the links, that one is left alone.' `
    -Parts @(
        pCustom 'GameBarLinks' 'makes HKLM\SOFTWARE\Classes\ms-gamebar and ms-gamebarservices open systray.exe, a program that does nothing    (undo: deletes both keys)'
    )

Add-Tweak -Id 'mouse' -Cat $cGame -Inv -Def 'On' -Preset -Name 'Mouse acceleration (pointer precision)' `
    -Desc 'On: Windows speeds the pointer up when you move the mouse faster ("Enhance pointer precision"). Off: the pointer moves 1:1 with your hand, with the pointer speed at 10/20.' `
    -Parts @(
        pReg 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '0' '1' 'String'
        pReg 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '0' '6' 'String'
        pReg 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '0' '10' 'String'
        pReg 'HKCU:\Control Panel\Mouse' 'MouseSensitivity' '10' '10' 'String'
        pCustom 'MouseLive' 'also applied to the running session'
    )

Add-Tweak -Id 'wu-drivers' -Cat $cGame -Inv -Def 'On' -Risk 'note' -Name 'Driver updates through Windows Update' -NotRec 'It also stops Windows Update drivers for new devices, and the part that blocks driver updates is a policy that Windows Home may ignore.' `
    -Desc 'On: Windows Update can replace drivers you installed yourself. It also searches Windows Update for a driver when you plug in new hardware. Off: Windows Update leaves your drivers alone, so you update them manually (the GPU maker''s installer or your motherboard''s site). It also no longer searches for a driver when you plug in new hardware. The switches are set in each place Windows keeps them: the Windows Update policy, the driver search policy, the driver search setting, Windows Update''s own settings key and the copy of the driver exclusion in its update policy state. Windows rewrites that last copy itself, so it is tried but never counted.' `
    -Parts @(
        pReg "$pol\WindowsUpdate" 'ExcludeWUDriversInQualityUpdate' 1
        pReg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching' 'SearchOrderConfig' 0 1
        pReg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Metadata' 'PreventDeviceMetadataFromNetwork' 1
        pReg "$pol\DriverSearching" 'SearchOrderConfig' 0
        pReg "$pol\DriverSearching" 'DontSearchWindowsUpdate' 1
        pReg 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' 'ExcludeWUDriversInQualityUpdate' 1
        pRegSoft 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UpdatePolicy\PolicyState' 'ExcludeWUDrivers' 1
    )

# One setting, three options. Windows Update itself is never switched off here; the strongest option only stops it from installing
# updates without being asked. Not in any preset and left out of "Apply all" (see $script:ApplyAllSkip).
$wuStore = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'
$wuMrt   = 'HKLM:\SOFTWARE\Policies\Microsoft\MRT'
$wuAU    = "$pol\WindowsUpdate\AU"
Add-Tweak -Id 'wu-auto' -Cat $cGame -Def 'Automatic' -Risk 'security' -Name 'Store and Malware Removal Tool updates' `
    -Desc ('Windows Update itself stays on whichever option you choose: security updates, drivers and feature updates can still be installed. ' +
           'Choose one of three options on the card. Automatic (Windows default): nothing is set. Store and MRT off: the Microsoft Store stops downloading and installing app updates by itself (AutoDownload = 2), and Windows Update stops offering the monthly Malicious Software Removal Tool, MRT (DontOfferThroughWUAU = 1); Windows Security is not affected. ' +
           'No auto-updates: the same two values and NoAutoUpdate = 1 (the "Configure Automatic Updates" policy set to Disabled). Windows then no longer downloads and installs updates by itself: open Settings > Windows Update and press Check for updates when you want them, and do it at least once a month, or the PC goes without security fixes. ' +
           'Limits: a manual check in the Store or in Windows Update still installs updates. It is not confirmed that Windows Home obeys the NoAutoUpdate policy, so on Home that option may change nothing; look at Settings > Windows Update after a restart. Nothing says which editions obey the MRT value. ' +
           'Changing the option or choosing Automatic again removes the values that no longer apply, which is how Windows ships (Windows sets none of the three).') `
    -Choices @(
        @{ Key = 'default'; Label = 'Automatic (Windows default)'; Short = 'Automatic (default)'; Parts = @() }
        @{ Key = 'apps'; Label = 'Store app and MRT updates off'; Short = 'Store and MRT off'; Parts = @( (pReg $wuStore 'AutoDownload' 2), (pReg $wuMrt 'DontOfferThroughWUAU' 1) ) }
        @{ Key = 'all'; Label = 'Also stop automatic Windows updates'; Short = 'No auto-updates'; Parts = @( (pReg $wuStore 'AutoDownload' 2), (pReg $wuMrt 'DontOfferThroughWUAU' 1), (pReg $wuAU 'NoAutoUpdate' 1) ) }
    )

Add-Tweak -Id 'wu-noreboot' -Cat $cGame -Def 'Off' -Risk 'note' -Name 'No auto-restart while you are signed in' `
    -Desc 'On: after an update that Windows installs on its schedule, it does not restart the PC by itself while someone is signed in. It shows a notice and waits for you to restart. Off: Windows can restart the PC by itself after installing updates, about five minutes after a scheduled install (the Windows default). That is how it stops a restart in the middle of a game. The update stays unfinished until you restart yourself, so do that now and then. The policy only covers scheduled installs; your active hours in Settings > Windows Update are not changed.' `
    -Parts @(
        pReg $wuAU 'NoAutoRebootWithLoggedOnUsers' 1
    )

Add-Tweak -Id 'wpbt' -Cat $cGame -Inv -Def 'On' -Reboot -Risk 'note' -Name 'WPBT (firmware programs at startup)' `
    -Desc 'On: motherboard firmware can copy a program into Windows and run it at every boot (the Windows Platform Binary Table, WPBT). Some boards use it to deliver their own software: Gigabyte firmware has been reported installing an updater this way, and ASUS boards have a BIOS option, on by default, that downloads Armoury Crate. Off: Windows does not run such programs. Side effects: tools that PC makers deliver this way, including some anti-theft software, are no longer installed, and a program the firmware already installed stays until you remove it. Your board''s BIOS setting for its own software is the other place to turn this off. Needs a restart.' `
    -Parts @(
        pReg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' 'DisableWpbtExecution' 1
    )

Add-Tweak -Id 'hags' -Cat $cDisplay -Def 'Depends on the graphics card' -Preset -Reboot -Name 'Hardware-accelerated GPU scheduling (HAGS)' `
    -Desc 'On: the graphics card manages its own memory scheduling, which can lower latency and CPU load in some games. Off: Windows and the driver decide (the Windows default). It only does anything on graphics cards and drivers that support it (roughly NVIDIA GTX 10-series and newer, AMD RX 5600 and newer, recent Intel graphics); if Settings > System > Display > Graphics does not show the switch, your card does not support it. A few games stutter with it on: switch it off if yours do.' `
    -Parts @(
        pReg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2
    )

$mpoDwm = 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm'
$mpoGfx = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
Add-Tweak -Id 'mpo' -Cat $cDisplay -Def 'Enabled' -Reboot -Name 'Multiplane Overlay (MPO)' -NotRec 'A fix for flicker, not a speed-up: leave it on Enabled unless you see flicker.' `
    -Desc ('Fix for screen flicker and stutter; not a speed-up. Multiplane Overlay lets the graphics hardware combine the game, the desktop and overlays itself, instead of Windows blending them into one picture. On some graphics card, driver and monitor combinations, switching between those layers is reported to cause flicker, black flashes or stutter, and turning MPO off makes Windows blend everything itself again. ' +
           'That comes from user reports, not measurements, and it is not a speed-up: leave it on Enabled unless you see those problems. ' +
           'Choose one of three options on the card. Enabled (Windows default): nothing is set. Disabled: OverlayTestMode = 5, the usual fix. Fully disabled: OverlayTestMode = 5 and DisableOverlays = 1 (the second value is what the Fully Disabled option of Chris Titus Tech''s WinUtil sets). ' +
           'No Microsoft documentation for either value was found; they come from community guides and tools like WinUtil. Needs a restart. Changing the option or choosing Enabled again removes the values that no longer apply, which is how Windows ships (neither value is set by default).') `
    -Choices @(
        @{ Key = 'default'; Label = 'Enabled (Windows default)'; Short = 'Enabled (default)'; Parts = @() }
        @{ Key = 'disabled'; Label = 'Disabled'; Short = 'Disabled'; Parts = @( (pReg $mpoDwm 'OverlayTestMode' 5) ) }
        @{ Key = 'full'; Label = 'Fully disabled'; Short = 'Fully disabled'; Parts = @( (pReg $mpoDwm 'OverlayTestMode' 5), (pReg $mpoGfx 'DisableOverlays' 1) ) }
    )

Add-Tweak -Id 'defender-idle' -Cat $cGame -Def 'Off' -Preset -Name 'Low-impact Windows Security scans' `
    -Desc 'On: Windows Security scans run only while the PC is idle, at low priority, using at most 20% of the CPU. Real-time protection keeps working exactly as before. Scans take longer to finish. Off: Windows'' own scan settings come back (idle only, normal priority, up to 50% CPU). Shown as not available on PCs where Windows Security is turned off or replaced by another antivirus.' `
    -Parts @(
        pCustom 'DefenderIdle' 'Set-MpPreference: ScanOnlyIfIdleEnabled = on, EnableLowCpuPriority = on, ScanAvgCPULoadFactor = 20    (undo: the Windows defaults: on / off / 50)'
    )

Add-Tweak -Id 'sticky-keys' -Cat $cGame -Inv -Def 'On' -Preset -Name 'Sticky Keys shortcut' `
    -Desc 'On: pressing Shift five times in a row opens the "Do you want to turn on Sticky Keys?" window, which can interrupt a game. Off: that shortcut is turned off. Only the shortcut is affected; Sticky Keys itself is still there under Settings > Accessibility > Keyboard. It takes effect straight away; if the window still shows up once, sign out and back in.' `
    -Parts @(
        pReg 'HKCU:\Control Panel\Accessibility\StickyKeys' 'Flags' '506' '510' 'String'
        pCustom 'AccessLive' 'also applied to the running session' 'Sticky'
    )

Add-Tweak -Id 'filter-keys' -Cat $cGame -Inv -Def 'On' -Preset -Name 'Filter Keys shortcut' `
    -Desc 'On: holding the right Shift key for eight seconds opens the "Do you want to turn on Filter Keys?" window, with beeps. Off: that shortcut is turned off. Only the shortcut is affected; Filter Keys itself is still there under Settings > Accessibility > Keyboard. It takes effect straight away; if the window still shows up once, sign out and back in.' `
    -Parts @(
        pReg 'HKCU:\Control Panel\Accessibility\Keyboard Response' 'Flags' '122' '126' 'String'
        pCustom 'AccessLive' 'also applied to the running session' 'Filter'
    )

Add-Tweak -Id 'toggle-keys' -Cat $cGame -Inv -Def 'On' -Preset -Name 'Toggle Keys shortcut' `
    -Desc 'On: holding Num Lock for five seconds opens the Toggle Keys window. Toggle Keys beeps whenever Caps Lock, Num Lock or Scroll Lock is pressed. Off: that shortcut is turned off, so the beeps and the window do not appear. Only the shortcut is affected; Toggle Keys itself is still there under Settings > Accessibility > Keyboard.' `
    -Parts @(
        pReg 'HKCU:\Control Panel\Accessibility\ToggleKeys' 'Flags' '58' '62' 'String'
        pCustom 'AccessLive' 'also applied to the running session' 'Toggle'
    )

# ------------------------------------------------------------ Display ----------
# The Display page also shows live cards (resolution, refresh rate, HDR, the modes of each screen); those are drawn by the window and
# are not settings. Windows has no switch that forces a refresh rate: Settings > System > Display > Advanced display sets it, and the
# card on the page says what else keeps a game at the full rate. The two switches below are real: they are the "Optimizations for windowed
# games" and "Variable refresh rate" switches of Settings > System > Display > Graphics > Default graphics settings, which Windows
# keeps as two NAME=value; pairs in one text value (see Custom-DxGlobal in e2-custom.ps1).
Add-Tweak -Id 'windowed-opt' -Cat $cDisplay -Def 'On' -Preset -Name 'Optimizations for windowed games' `
    -Desc 'On: Windows presents DirectX 10 and 11 games in a window or borderless mode in its newer way (the flip model). That lowers latency and lets those games use Auto HDR and variable refresh rate. Off: the optimization is off, so those games are not presented the newer way. Windows 11 22H2 and newer. It does nothing for games in exclusive fullscreen, and nothing for DirectX 12 and Vulkan games, which already present that way. It is the switch "Optimizations for windowed games" under Settings > System > Display > Graphics > Default graphics settings, so you can also change it there. It applies the next time a game starts. On Windows 11 24H2 and newer a clean Windows has no entry for it and Settings shows it as on, so a missing entry is shown as on there (and as off on older builds). Switching it off writes an explicit 0 on those builds (on older builds the entry is removed, which Windows reads as off).' `
    -Parts @(
        pCustom 'DxGlobal' 'sets SwapEffectUpgradeEnable=1; inside HKCU\Software\Microsoft\DirectX\UserGpuPreferences\DirectXUserGlobalSettings and leaves every other entry of that text as it is    (undo: the entry is removed, or set to 0 on Windows 11 24H2 and newer where the default is on)' 'SwapEffectUpgradeEnable'
    )

Add-Tweak -Id 'vrr-games' -Cat $cDisplay -Name 'Variable refresh rate (DirectX 11 games)' `
    -Desc 'On: Windows adds variable refresh rate to full-screen DirectX 11 games that were not written for it, so the screen follows the frame rate of the game. That works with G-SYNC, FreeSync and Adaptive-Sync screens. Off: those games run at the fixed refresh rate of the screen, which is how Windows ships. Only turn it on if you have a variable refresh rate screen: on any other screen it does nothing. Some games flicker or change brightness while the refresh rate varies, and this is the switch to turn off again for them. It is the switch "Variable refresh rate" under Settings > System > Display > Graphics > Advanced graphics settings (on some builds: Change default graphics settings), so you can also change it there. Windows 10 version 2004 and newer. It does not touch G-SYNC or FreeSync in the graphics driver, and it does not change DirectX 10 and 11 games in a window or borderless window: those follow "Optimizations for windowed games". Windows shows the switch in Settings only where the monitor and the graphics driver support variable refresh rate, so this setting is shown as not available (nothing is written) when none of the screens that are connected can do it: a VGA or DVI cable, an HDMI screen that announces neither FreeSync nor HDMI variable refresh rate, or a DisplayPort screen with a fixed refresh rate. Windows has no test for "is the switch shown", so this reads the information each screen reports about itself (its EDID) and only a clear no on every screen counts; when that information cannot be read, or is not clear, the setting stays available. It applies the next time a game starts. Windows has no entry for this switch out of the box, and a missing entry is shown here as off. Turning it on writes an explicit 1; turning it off removes the entry, which leaves the Windows default. An entry of 1 can come from this app, from a guide or tool used earlier, or from Windows itself when you changed the switch in Settings, and this app cannot tell which.' `
    -Parts @(
        pCustom 'DxGlobal' 'sets VRROptimizeEnable=1; inside HKCU\Software\Microsoft\DirectX\UserGpuPreferences\DirectXUserGlobalSettings and leaves every other entry of that text as it is    (undo: the entry is removed, which leaves the Windows default, off)' 'VRROptimizeEnable'
    )

Add-Tweak -Id 'game-mode' -Cat $cDisplay -Def 'On' -Preset -Name 'Game Mode' `
    -Desc 'On: Windows Game Mode (Settings > Gaming > Game Mode) is on, as Windows has it by default. Microsoft describes Game Mode as giving a game priority for the processor and graphics card and holding back some background work, such as driver installs by Windows Update, while it runs. How much that changes depends on the game and the PC, and it is not a speed-up by itself. Off: Game Mode is turned off (an explicit 0 is written). It is a setting of your Windows account (stored under HKEY_CURRENT_USER), so it applies to the account you run this app from. A missing entry is shown as on, because that is what Windows does when nothing has been changed. Windows also keeps an older value, AllowAutoGameMode, in the same key: it is read too (Game Mode counts as on only when neither value is 0), and this setting writes it only where it already exists.' `
    -Parts @(
        pCustom 'GameMode' 'sets AutoGameModeEnabled = 1 in HKCU\Software\Microsoft\GameBar (and AllowAutoGameMode = 1 there when that older value exists); a missing entry already counts as on    (undo: both are set to 0, which is Game Mode off)'
    )

Add-Tweak -Id 'auto-color' -Cat $cDisplay -Reboot -Name 'Automatically manage color for apps' `
    -Desc 'On: Windows applies automatic color management (ACM) to the apps on the screen. Microsoft describes it as making colors look more accurate and consistent across apps, whether or not an app manages color itself, and as letting newer apps show more colors with finer steps, which reduces banding in gradients, shadows and dark scenes (on a screen with 8 bits per color it uses dithering for that). Off: apps send their colors to the screen as they are, which is how Windows ships. This is a color-quality setting and not a speed-up: it is not part of the question preset, and it is only worth turning on if color accuracy matters to you. It is the switch "Automatically manage color for apps" under Settings > System > Display > Color profile (on some builds under Advanced display), so you can also change it there. It exists from Windows 11 22H2 with the October 2023 update (build 22621.2506) and newer, and it applies to screens in standard dynamic range (SDR) only. Windows keeps the switch for each screen on its own, in the color entry it stores for that screen (HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\MonitorDataStore): this app sets it for every screen that is connected now and has such an entry, and shows the setting as not available when the build is older or no connected screen has an entry. A screen that is connected later gets Windows'' default, so turn this on again after adding one. Windows applies the switch at once when you change it in Settings, but a value written to the registry is read at the next start, so restart the PC after turning it on or off here. A missing value is shown as off. Switching it off here writes an explicit 0 for every connected screen that has a value (a screen with no value is left alone), because a 0 reads as off with certainty. A value of 1 can come from this app, from Windows itself when you changed the switch in Settings, or from the graphics driver, and this app cannot tell which. Users report that on PCs with an NVIDIA card, installing a driver, or changing the color depth (bits per color) in the NVIDIA settings, turns this switch on again; when that happens this setting shows as on, and switching it off here (and restarting) turns it off again.' `
    -Parts @(
        pCustom 'AcmApps' 'sets AutoColorManagementEnabled = 1 in the color entry of every connected screen under HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\MonitorDataStore    (undo: sets 0, which is off, on every connected screen that has a value; a screen with no value is left alone)'
    )

# ------------------------------------------------------- Placebo Tweaks - Not Recommended (may do nothing) -------
# Settings whose benefit is not proven, or that Windows ignores in the way they are usually used. They are harmless as far as is
# known (the descriptions give the reason for each), so they stay available, but they are kept on a page of their own so
# that nobody takes them for proven gaming tweaks. Every setting here carries -Unproven. What each description rests on:
#   power-throttle : Microsoft's "Introducing Power Throttling" post (Windows Insider blog, 2017) and its Quality of Service page
#   netthrottle    : Mark Russinovich's 2007 post on the multimedia network throttle; djdallmann's GamingPCSetup network research
#   sysresp, gamesched : Microsoft's Multimedia Class Scheduler Service page (SystemResponsiveness, GPU / SFIO Priority, Priority);
#                    djdallmann's GamingPCSetup trace of which MMCSS tasks games use
#   tcp-nodelay    : Microsoft KB 328890 and KB 935458 (TcpAckFrequency); no Microsoft page was found for TCPNoDelay / TcpDelAckTicks
#   svc-sysmain    : forum reports (no benchmark was found)
#   desktop-delay  : Microsoft Q&A answers from community members and forum reports (no Microsoft documentation was found)
Add-Tweak -Id 'power-throttle' -Cat $cNothing -Inv -Def 'On' -Reboot -Unproven -Name 'Power throttling' `
    -Desc 'On: Windows can slow background programs down to save power, as it does by default. Off: PowerThrottlingOff = 1 is written (power throttling off). Little to turn off on a plugged-in desktop: Microsoft said power throttling does not apply on AC power. That comes from its announcement of the feature in Windows 10 (2017), which also says the program you are using and anything playing audio are left alone and that, at the time, it needed an Intel CPU with Speed Shift. Windows 11 adds Efficiency mode (EcoQoS), which programs and Windows ask for themselves; Microsoft''s documentation does not say this setting switches that off, and the reports that it does are unverified (some readers say the value does not survive a restart). It matters most on laptops running on battery. It needs a restart and can raise power use and heat a little. Switching it back on removes the value, which is how Windows ships.' `
    -Parts @(
        pReg 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 1
    )

$mm = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
Add-Tweak -Id 'netthrottle' -Cat $cNothing -Inv -Def 'On' -Unproven -Name 'Network throttling (multimedia scheduler)' `
    -Desc 'On: Windows limits incoming traffic while media plays, as it does by default. Off: NetworkThrottlingIndex is set to 0xFFFFFFFF (throttling off). It should not change your ping: the limit only applies while media plays, and a game receives far fewer packets than the limit. Windows applies it only while a media-playback program is being boosted, and then caps received traffic at 10 packets per millisecond (about 15 MB/s, roughly 120 Mbps), so turning it off only matters for fast downloads while media plays. The one published measurement found (a Windows latency trace, build not stated) showed slightly higher network-driver latency with it off, and no measured ping gain was found. Microsoft''s current multimedia scheduler documentation does not mention this value, and it is not confirmed that Windows 11 still enforces it. Switching it back on puts Windows'' default of 10 back.' `
    -Parts @(
        pReg $mm 'NetworkThrottlingIndex' ([uint32]4294967295) 10
    )

Add-Tweak -Id 'sysresp' -Cat $cNothing -Def 'Off' -Unproven -Name 'System responsiveness set to 10%' `
    -Desc 'On: SystemResponsiveness is set to 10 (the Windows default is 20). That lowers the share of CPU kept free for everything else from 20% to 10%, so programs that use the Windows multimedia scheduler (a game''s audio threads, say) can take more when the CPU is completely busy. Off: Windows'' default of 20 is used. It may change nothing in games: it only matters when the CPU is maxed out, and only for programs that use the multimedia scheduler. Microsoft rounds values below 10 up to 20, so 10 is the lowest that does anything. No frame-rate or latency gain from it has been shown on current Windows.' `
    -Parts @(
        pReg $mm 'SystemResponsiveness' 10 20
    )

Add-Tweak -Id 'gamesched' -Cat $cNothing -Def 'Off' -Unproven -Name 'Game scheduling priority set to High' `
    -Desc 'On: Scheduling Category and SFIO Priority of the "Games" task are set to High, Priority to 6 and GPU Priority to 8. Off: Windows'' defaults (Medium, Normal, 2 and 8) are used. Three of the four values are ignored by Windows, and the fourth only applies to the "Games" task, which no game is shown to use. Microsoft lists GPU Priority as not yet used and disk (SFIO) Priority as not used, and treats Priority as 2 whenever the category is High, so those three change nothing. Only the High scheduling category is real, and it only affects threads that register under the "Games" task; a published trace of CS:GO, Fortnite and Apex Legends (Windows 10 era) found their threads using the Audio or Pro Audio tasks, none using Games.' `
    -Parts @(
        pReg "$mm\Tasks\Games" 'GPU Priority' 8 8
        pReg "$mm\Tasks\Games" 'Priority' 6 2
        pReg "$mm\Tasks\Games" 'Scheduling Category' 'High' 'Medium' 'String'
        pReg "$mm\Tasks\Games" 'SFIO Priority' 'High' 'Normal' 'String'
    )

Add-Tweak -Id 'tcp-nodelay' -Cat $cNothing -Def 'Off' -Reboot -Unproven -Name 'TCP no-delay on every connection' `
    -Desc 'On: Windows acknowledges each TCP packet at once instead of waiting up to 200 ms to bundle replies. TcpAckFrequency = 1, TCPNoDelay = 1 and TcpDelAckTicks = 0 are set on every network interface. Off: the three values are deleted (how Windows ships). It only affects TCP: games that send their action data over UDP are untouched, and no measured ping gain was found. Microsoft documents TcpAckFrequency for Windows Server and fixed it in Vista SP1; no Microsoft page describing TCPNoDelay or TcpDelAckTicks for Windows 10 or 11 was found. A 2009 TechNet post warns it can slow transfers between local machines. A network adapter or VPN added later needs this applied again.' `
    -Parts @(
        pRegDyn -Info 'Every network interface under HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces: TcpAckFrequency = 1, TCPNoDelay = 1, TcpDelAckTicks = 0    (undo: values deleted)' -Gen {
            foreach ($k in @(Reg-SubKeys 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces')) {
                pReg $k 'TcpAckFrequency' 1
                pReg $k 'TCPNoDelay' 1
                pReg $k 'TcpDelAckTicks' 0
            }
        }
    )

Add-Tweak -Id 'desktop-delay' -Cat $cNothing -Def 'Off' -Unproven -Name 'Startup programs load without delay' `
    -Desc 'On: StartupDelayInMSec and WaitforIdleState are set to 0. Off: both are deleted (how Windows ships). It may do nothing: no Microsoft documentation was found for these values, and the reports of an effect disagree. They are not present on a normal Windows install; some people see startup programs open sooner after adding them on Windows 11, others see no change, and one forum user reports that some Windows updates delete them. Where Windows does hold startup programs back, this removes the wait so they load straight away. It applies from your next sign-in. On a slow PC the first seconds after signing in can feel busier because everything starts at once.' `
    -Parts @(
        pReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'StartupDelayInMSec' 0
        pReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'WaitforIdleState' 0
    )

# ------------------------------------------------------------- Security -------
$sys ='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
Add-Tweak -Id 'uac' -Cat $cSec -Inv -Def 'On' -Reboot -Risk 'security' -Name 'UAC prompts' -NotRec 'It gives no speed-up; it only removes a protection.' `
    -Desc 'On: Windows asks you before programs start with administrator rights (the Windows default). Off: programs can start with administrator rights without asking you first. The same values the Windows UAC slider writes at "Never notify" are set. Malware benefits from this too.' `
    -Parts @(
        pReg $sys 'ConsentPromptBehaviorAdmin' 0 5
        pReg $sys 'PromptOnSecureDesktop' 0 1
    )

Add-Tweak -Id 'uac-lua' -Cat $cSec -Inv -Def 'On' -Reboot -Risk 'security' -Name 'User Account Control (UAC engine)' -NotRec 'It gives no speed-up, and modern apps can refuse to start.' `
    -Desc 'On: User Account Control works (the Windows default). Off: EnableLUA = 0 switches User Account Control off completely, beyond the slider. Modern apps (Settings, Calculator, Photos, Terminal) can refuse to launch. Not part of the Recommended preset.' `
    -Parts @(
        pReg $sys 'EnableLUA' 0 1
    )

$dg = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard'
# Asked before either of the two settings below is turned on (FACEIT: support.faceit.com "Windows Security Requirements FAQ";
# Riot: support.riotgames.com "Vanguard security requirements")
$acTitle = 'Turn off Memory Integrity / VBS?'
$acAsk = 'Do you play FACEIT or Valorant?' + "`r`n" + "`r`n" + `
    'Memory Integrity and Virtualization-Based Security (VBS) are Windows security features that these anti-cheats look for:' + "`r`n" + `
    '  - FACEIT: its Anti-Cheat requires VBS on Windows (it needs it to protect against DMA cheats), and it is switching the requirement on in waves. If your PC does not meet it, FACEIT may not let you play.' + "`r`n" + `
    '  - Riot Vanguard (Valorant and other Riot games): can ask you to turn on Memory Integrity before it lets you launch the game.' + "`r`n" + `
    'Applying this setting turns those features off.' + "`r`n" + "`r`n" + `
    'If you play on either, answer No: the setting stays off and nothing is changed. You can apply it later from the window.'
Add-Tweak -Id 'vbs' -Cat $cSec -Inv -Def 'Depends on the PC' -Reboot -Risk 'security' -Name 'Memory Integrity and VBS (HVCI)' `
    -Ask $acAsk -AskTitle $acTitle -AskGroup 'anticheat' `
    -Desc 'On: Memory Integrity and Virtualization-Based Security are left to Windows (new Windows 11 installs on capable hardware usually have them on). Off: both are turned off, and Credential Guard with them. That can give a few percent more FPS in some games, but it removes protection against kernel-level malware. Anti-cheat warning: FACEIT requires Virtualization-Based Security to be on, and Riot Vanguard can ask for Memory Integrity, so leave this on if you play on those - you are asked about it before it is applied. Switching it back on leaves the values unset, so Windows decides again.' `
    -Parts @(
        pReg "$dg\Scenarios\HypervisorEnforcedCodeIntegrity" 'Enabled' 0
        pReg "$dg\Scenarios\HypervisorEnforcedCodeIntegrity" 'WasEnabledBy' 0
        pReg $dg 'EnableVirtualizationBasedSecurity' 0
        pReg 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'LsaCfgFlags' 0
    )

Add-Tweak -Id 'hypervisor' -Cat $cSec -Inv -Def 'Depends on the PC' -Reboot -Risk 'security' -Name 'Windows hypervisor at startup' `
    -Ask $acAsk -AskTitle $acTitle -AskGroup 'anticheat' `
    -Desc 'On: Windows decides whether the hypervisor loads at boot (its default). Off: the hypervisor does not load at boot, which removes the small overhead it adds to games on some PCs. While it is off, Memory Integrity / Virtualization-Based Security cannot run (so the FACEIT / Riot Vanguard note on the Memory Integrity setting applies here too - you are asked first), and WSL2, Hyper-V virtual machines, Windows Sandbox, Docker (WSL2 mode) and the Android subsystem will not start. Switching it back on deletes the boot setting, so Windows decides again. Turning on one of those features or memory integrity, or its installer or an update to it, can set the boot setting back to Auto; the check then offers this again, and the log names what on the PC uses the hypervisor.' `
    -Parts @(
        pCustom 'Hypervisor' 'bcdedit /set hypervisorlaunchtype off    (undo: bcdedit /deletevalue hypervisorlaunchtype)'
    )

Add-Tweak -Id 'bitlocker' -Cat $cSec -Inv -Def 'Depends on the PC' -OneWay -Risk 'security' -Name 'BitLocker drive encryption' `
    -Ask ('BitLocker (and the Windows 11 "Device encryption" that uses it) protects your files if this PC or its drive is lost or stolen.' + "`r`n" + "`r`n" +
          'Applying this setting starts decrypting every drive that is encrypted and unlocked:' + "`r`n" +
          '  - anyone who gets this PC, or just its drive, can then read your files' + "`r`n" +
          '  - it runs in the background and can take a long time on a big drive; the PC stays usable, and it is best kept plugged in' + "`r`n" +
          '  - it cannot be undone from this window: to encrypt again use Settings > Privacy & security > Device encryption, or Control Panel > BitLocker Drive Encryption (that makes a new recovery key, which you must save)' + "`r`n" + "`r`n" +
          'If you are not sure, answer No: nothing is changed. You can apply it later from the window.') `
    -AskTitle 'Turn off BitLocker?' `
    -Desc 'On: your drives stay as they are; drives that BitLocker or Device encryption protects stay encrypted. Off: starts decrypting every unlocked drive that BitLocker or Device encryption protects. Why: software encryption makes the drive do extra work on every read and write. One published test (Tom''s Hardware, reported by TechSpot; Samsung 990 Pro, Windows 11 22H2, software BitLocker) measured about 11% slower file copies, about 20% lower PCMark 10 storage scores and 45% slower random writes; the effect depends on the drive and the CPU. Windows 11 version 24H2 and newer can turn Device encryption on by default, which is why a new PC may be encrypted without you having set it up. Cost: if the PC or the drive is lost or stolen, anyone can read your files. Decryption carries on in the background and can take hours. This cannot be undone from here (switching it back on only prints a note): to encrypt again use Windows'' own Device encryption or BitLocker settings, which make a new recovery key for you to save. Works on Windows Home too: if Windows has no BitLocker commands there, the drives are read and decrypted through the manage-bde tool of Windows (English Windows only). Shown as not available when neither can be asked, and as off when no drive is encrypted. Not part of the Recommended preset, and left out of Apply all.' `
    -Parts @(
        pCustom 'BitLocker' 'Drive encryption: Disable-BitLocker on every drive that is encrypted and unlocked (other drives first, the Windows drive last)    (undo: not possible from here)'
    )

Add-Tweak -Id 'device-encryption-block' -Cat $cSec -Inv -Def 'On' -Risk 'security' -Name 'Automatic Device encryption' `
    -Desc 'On: Windows may turn on Device encryption (the simple form of BitLocker) by itself. Windows 11 can do that on a new install, or when you sign in with a Microsoft account on a PC that qualifies, which is how a PC ends up encrypted without you having set it up. Off: Windows is stopped from doing that. It only blocks the automatic start: it does not decrypt anything and does not touch a drive that is already encrypted (the BitLocker setting does that), and you can still turn BitLocker on yourself whenever you like. Cost: if the PC or its drive is lost or stolen, an unencrypted drive can be read by whoever has it. Switching it back on removes the value, which is the Windows default.' `
    -Parts @(
        pReg 'HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker' 'PreventDeviceEncryption' 1
    )

# ------------------------------------------------------------- Services -------
Add-Tweak -Id 'svc-search' -Cat $cSvc -Inv -Def 'On' -Risk 'note' -Name 'Windows Search indexer starts with Windows' -NotRec 'File and program search can stop finding things.' `
    -Desc 'On: the Windows Search service (the file indexer) starts with Windows (Automatic, delayed start, as Windows has it). Off: it is set to Manual, so it no longer starts with Windows. Start-menu results for installed apps keep working, but results that come from the index can stop appearing: files, and programs that are not installed, such as a portable program that runs from its own folder. Benefit of off: a little less background disk and CPU use while Windows builds the index, which is small on a fast SSD. This is not part of the Recommended preset. If search stops finding something, switch this back on: the service goes back to Automatic (Delayed Start) and starts again straight away.' `
    -Parts @(
        pSvc 'WSearch' 'Manual' 'AutomaticDelayed'
    )

Add-Tweak -Id 'svc-misc' -Cat $cSvc -Inv -Def 'On' -Preset -Name 'Rarely used services' `
    -Desc 'On: eight rarely used services keep the start types Windows gives them. They are Retail Demo, Fax, Parental Controls, NFC / payments, Phone service, Windows Insider service, Downloaded Maps Manager and Distributed Link Tracking. Off: the first seven are disabled and Distributed Link Tracking is set to Manual.' `
    -Parts @(
        pSvc 'RetailDemo' 'Disabled' 'Manual'
        pSvc 'Fax' 'Disabled' 'Manual'
        pSvc 'WpcMonSvc' 'Disabled' 'Manual'
        pSvc 'SEMgrSvc' 'Disabled' 'Manual'
        pSvc 'PhoneSvc' 'Disabled' 'Manual'
        pSvc 'wisvc' 'Disabled' 'Manual'
        pSvc 'MapsBroker' 'Disabled' 'AutomaticDelayed'
        pSvc 'TrkWks' 'Manual' 'Automatic'
    )

Add-Tweak -Id 'svc-smartcard' -Cat $cSvc -Inv -Def 'On' -Risk 'note' -Name 'Smart card services' `
    -Desc 'On: the smart card services are enabled (they start when needed). Off: they are disabled. They are needed only for smart-card logins and some hardware security keys. Leave this on if you use one.' `
    -Parts @(
        pSvc 'SCardSvr' 'Disabled' 'Manual'
        pSvc 'ScDeviceEnum' 'Disabled' 'Manual'
    )

Add-Tweak -Id 'printing' -Cat $cSvc -Inv -Def 'On' -Risk 'note' -Name 'Printing (Print Spooler)' `
    -Ask ('Do you need printing?' + "`r`n" + "`r`n" + `
          'Applying this setting stops the Print Spooler and its notification service. From then on this PC cannot print at all:' + "`r`n" + `
          '  - no paper printing, to a USB printer or to a network printer' + "`r`n" + `
          '  - no "Microsoft Print to PDF" and no "Microsoft XPS Document Writer" (they are printers too)' + "`r`n" + `
          '  - programs that print or save through the Windows print dialog just fail' + "`r`n" + "`r`n" + `
          'If you ever print, or save things as PDF that way, answer No: the setting stays off and printing keeps working. You can apply it later from the window.') `
    -AskTitle 'Turn off printing?' `
    -Desc 'On: printing works (the Print Spooler and its notification service are enabled, as Windows has them). Off: both services are disabled, so this PC cannot print at all. There is also no "Microsoft Print to PDF" or "Microsoft XPS Document Writer". Switch it back on to print again. You are asked first whether you need printing.' `
    -Parts @(
        pSvc 'Spooler' 'Disabled' 'Automatic'
        pSvc 'PrintNotify' 'Disabled' 'Manual'
    )

Add-Tweak -Id 'xbox-svc' -Cat $cSvc -Inv -Def 'On' -Risk 'note' -Name 'Xbox services' `
    -Desc 'On: Xbox sign-in, cloud saves, accessory and network services are enabled (they start when needed). Off: they are disabled. Game Pass, the Xbox app and Microsoft Store games stop working. Steam, Epic and GOG are not affected.' `
    -Parts @(
        pSvc 'XblAuthManager' 'Disabled' 'Manual'
        pSvc 'XblGameSave' 'Disabled' 'Manual'
        pSvc 'XboxGipSvc' 'Disabled' 'Manual'
        pSvc 'XboxNetApiSvc' 'Disabled' 'Manual'
    )

# (The usage-reporting, NetBIOS and Storage Service ones sit on the Privacy, Network sharing and Storage pages, where they belong.)
# More background services that a gaming PC does not need. Health and Optimized Experiences, diagnostics, Program Compatibility Assistant and the data usage meter are in the Recommended preset; the others are yours to switch on.
Add-Tweak -Id 'svc-whe' -Cat $cSvc -Inv -Def 'On' -Preset -Risk 'note' -Name 'Health and Optimized Experiences service' `
    -Desc 'On: the service that watches CPU, heat and battery and records performance traces on this PC when Windows feels slow is enabled. Off: it is disabled. Microsoft says the traces stay on the PC unless you send them in a Feedback Hub report. Little downside on a desktop; on a laptop it may weaken battery optimisation.' `
    -Parts @(
        pSvc 'whesvc' 'Disabled' 'Automatic'
    )

Add-Tweak -Id 'svc-diag' -Cat $cSvc -Inv -Def 'On' -Preset -Name 'Troubleshooting and diagnostics services' -NotRec 'Little to gain, and the built-in Troubleshoot wizards stop working.' `
    -Desc 'On: the Diagnostic Policy Service, Diagnostic System Host and Diagnostic Service Host are enabled. Off: all three are disabled. The built-in "Troubleshoot" wizards (network, audio, Windows Update) stop working until you switch this back on.' `
    -Parts @(
        pSvc 'DPS' 'Disabled' 'Automatic'
        pSvc 'WdiSystemHost' 'Disabled' 'Manual'
        pSvc 'WdiServiceHost' 'Disabled' 'Manual'
    )

Add-Tweak -Id 'svc-pca' -Cat $cSvc -Inv -Def 'On' -Preset -Name 'Program Compatibility Assistant' `
    -Desc 'On: the service behind the "this program might not have installed correctly" pop-ups and the automatic compatibility fixes for old programs is enabled. Off: it is disabled. Compatibility settings you choose yourself in a program''s Properties still apply. Leave this on if you play old games and like those prompts.' `
    -Parts @(
        pSvc 'PcaSvc' 'Disabled' 'AutomaticDelayed'
    )

Add-Tweak -Id 'svc-datausage' -Cat $cSvc -Inv -Def 'On' -Preset -Name 'Data usage meter service' `
    -Desc 'On: the service that counts how much data each app uses (Settings > Network & internet > Data usage) is enabled. Off: it is disabled, so that page shows nothing; networking itself is not affected.' `
    -Parts @(
        pSvc 'DusmSvc' 'Disabled' 'Automatic'
    )

# Windows gives every service its own svchost.exe process once a PC has more than 3.5 GB of RAM. A threshold above the
# installed memory makes it group them again after a restart. The value is far above any home PC (256 GB in KB); undo removes it,
# which gives Windows' own default (3.5 GB).
Add-Tweak -Id 'svchost-merge' -Cat $cSvc -Inv -Def 'On' -Preset -Reboot -Risk 'note' -Name 'Separate svchost.exe per service' -NotRec 'Saves little memory, and one crashing service can take others down with it.' `
    -Desc 'On: each background service runs in its own svchost.exe process (the default with over 3.5 GB of RAM). Off: services are grouped again after a restart (about 50 fewer processes). That uses a little less memory. The costs: one service that crashes can take others in its group with it, and Task Manager can no longer show which service uses the CPU. WinUtil warns that it can interfere with Xbox services.' `
    -Parts @(
        pReg 'HKLM:\SYSTEM\CurrentControlSet\Control' 'SvcHostSplitThresholdInKB' 268435456 3670016
    )

# Every setting that only changes services is on this page, so they are all in one place. The last eight are untested ideas from
# other debloat scripts (-Untested): "Apply all" and "Turn all on" leave them out, and each one is its own card so it can be switched alone.
Add-Tweak -Id 'telemetry-svc' -Cat $cSvc -Inv -Def 'On' -Preset -Name 'Telemetry services (DiagTrack and related)' `
    -Desc 'On: the four telemetry and error-reporting services are enabled, with the start types Windows gives them. They are the Connected User Experiences and Telemetry service (DiagTrack), WAP push message routing, the diagnostics hub collector and the Windows Error Reporting service. Off: all four are stopped and disabled.' `
    -Parts @(
        pSvc 'DiagTrack' 'Disabled' 'Automatic'
        pSvc 'dmwappushservice' 'Disabled' 'Manual'
        pSvc 'diagnosticshub.standardcollector.service' 'Disabled' 'Manual'
        pSvc 'WerSvc' 'Disabled' 'Manual'
    )

Add-Tweak -Id 'svc-telemetry2' -Cat $cSvc -Inv -Def 'On' -Preset -Name 'Compatibility and usage reporting services' `
    -Desc 'On: the Inventory and Compatibility Appraisal service and Microsoft Usage and Quality Insights are enabled (they start when Windows asks for them). Off: both are disabled. They collect information about your apps and how Windows is used, for Microsoft. Windows and your games run the same without them.' `
    -Parts @(
        pSvc 'InventorySvc' 'Disabled' 'Manual'
        pSvc 'wuqisvc' 'Disabled' 'Manual'
    )

Add-Tweak -Id 'syncsvc' -Cat $cSvc -Inv -Def 'On' -Risk 'note' -Name 'Contacts, mail and calendar sync services' `
    -Desc 'On: the per-user background services behind the Mail, Calendar and People apps and Phone Link are enabled. Off: they are disabled. Leave this on if you use those apps.' `
    -Parts @(
        pSvc 'OneSyncSvc' 'Disabled' 'AutomaticDelayed'
        pSvc 'CDPUserSvc' 'Disabled' 'Automatic'
        pSvc 'UnistoreSvc' 'Disabled' 'Manual'
        pSvc 'UserDataSvc' 'Disabled' 'Manual'
        pSvc 'PimIndexMaintenanceSvc' 'Disabled' 'Manual'
    )

Add-Tweak -Id 'offlinefiles' -Cat $cSvc -Inv -Def 'On' -Name 'Offline Files service' `
    -Desc 'On: the Offline Files service is enabled (Windows starts it when needed) and can keep copies of network folders for use without a connection. Off: the service is disabled.' `
    -Parts @(
        pSvc 'CscService' 'Disabled' 'Manual'
    )

Add-Tweak -Id 'svc-netbios' -Cat $cSvc -Inv -Def 'On' -Preset -Name 'NetBIOS name helper service' `
    -Desc 'On: the TCP/IP NetBIOS Helper service is enabled; it looks up other computers by their old-style NetBIOS name. Off: the service is disabled. The internet and reaching devices by IP address or DNS name are not affected; only an old device that can be found by NetBIOS name alone might stop showing up by name.' `
    -Parts @(
        pSvc 'lmhosts' 'Disabled' 'Manual'
    )

Add-Tweak -Id 'ics' -Cat $cSvc -Inv -Def 'On' -Preset -Name 'Connection sharing (ICS and hotspot)' `
    -Desc 'On: Internet Connection Sharing, the Mobile Hotspot service and Windows Media Player library sharing are enabled, with the start types Windows gives them. Off: all three are disabled. Internet Connection Sharing is left alone automatically when WSL2, Hyper-V or Windows Sandbox is turned on, because their default network uses it.' `
    -Parts @(
        pSvc 'SharedAccess' 'Disabled' 'Manual' 'Test-UsesVirtualization' 'WSL2 / Hyper-V / Sandbox is on, so Internet Connection Sharing is left alone'
        pSvc 'icssvc' 'Disabled' 'Manual'
        pSvc 'WMPNetworkSvc' 'Disabled' 'Manual'
    )

Add-Tweak -Id 'vpn' -Cat $cSvc -Inv -Def 'On' -Risk 'note' -Name 'Windows'' built-in VPN services' `
    -Desc 'On: the services behind Windows'' own VPN client (IKEv2, SSTP, L2TP) and dial-up (Remote Access Connection Manager) are enabled. Off: they are disabled. VPN apps that bring their own driver, such as WireGuard, usually keep working, but some VPN clients need these services. Off also breaks PPPoE broadband dial-ups.' `
    -Parts @(
        pSvc 'SstpSvc' 'Disabled' 'Manual'
        pSvc 'IKEEXT' 'Disabled' 'Manual'
        pSvc 'RasMan' 'Disabled' 'Manual'
        pSvc 'RasAuto' 'Disabled' 'Manual'
    )

Add-Tweak -Id 'edge-upd' -Cat $cSvc -Inv -Def 'On' -Preset -Name 'Edge update services start with Windows' `
    -Desc 'On: the Edge update and elevation services start with Windows, the way Windows ships them. Off: they are set to Manual, so they start on demand. Edge still updates itself through its scheduled update tasks, so the "Microsoft Edge Update" process still shows up in the background list; "Edge background update tasks" stops those tasks too.' `
    -Parts @(
        pSvc 'edgeupdate' 'Manual' 'AutomaticDelayed'
        pSvc 'edgeupdatem' 'Manual' 'Manual'
        pSvc 'MicrosoftEdgeElevationService' 'Manual' 'Manual'
    )

Add-Tweak -Id 'svc-storage' -Cat $cSvc -Inv -Def 'On' -Name 'Storage Service starts with Windows' `
    -Desc 'On: Storage Service (storage settings and external-drive handling) starts with Windows (Automatic with a delayed start, as Windows has it). Off: it is set to Manual, so it starts when Windows needs it. One background process fewer while it is idle.' `
    -Parts @(
        pSvc 'StorSvc' 'Manual' 'AutomaticDelayed'
    )

Add-Tweak -Id 'svc-sysmain' -Cat $cSvc -Inv -Def 'On' -Unproven -Name 'SysMain (Superfetch) service' `
    -Desc 'On: the SysMain service is enabled (Automatic, as Windows has it) and pre-loads frequently used apps into memory, which mainly helps hard drives. Off: the service is disabled. There is little or nothing to gain on an SSD or NVMe drive: people report no measurable difference, and no benchmark showing a gain was found. The only certain effect is one background service fewer; one forum post quotes Intel''s SSD guidance as saying not to disable it.' `
    -Parts @(
        pSvc 'SysMain' 'Disabled' 'Automatic'
    )

Add-Tweak -Id 'svc-smsrouter' -Cat $cSvc -Untested -Inv -Def 'On' -Name 'SMS Router service (SmsRouter)' `
    -Desc 'On: the service that sends text messages (SMS) to the right app is enabled (Manual, as Windows has it). Off: it is set to Disabled. It is only used with a mobile-broadband modem or a phone link that carries texts; a desktop PC does not use it.' `
    -Parts @(
        pSvc 'SmsRouter' 'Disabled' 'Manual'
    )

Add-Tweak -Id 'svc-wallet' -Cat $cSvc -Untested -Inv -Def 'On' -Name 'Wallet service (WalletService)' `
    -Desc 'On: the Wallet service, used for payment cards, tickets and passes, is enabled (Manual, as Windows has it). Off: it is set to Disabled. A desktop gaming PC does not use it.' `
    -Parts @(
        pSvc 'WalletService' 'Disabled' 'Manual'
    )

Add-Tweak -Id 'svc-scpolicy' -Cat $cSvc -Untested -Inv -Def 'On' -Risk 'note' -Name 'Smart Card Removal Policy service' `
    -Desc 'On: the service that locks the PC or signs you out when a smart card is pulled out of its reader is enabled (Manual, as Windows has it). Off: it is set to Disabled. It only matters if you sign in with a smart card. The other two smart-card services are in "Smart card services" on the Services page; this one is separate so it can be switched on its own.' `
    -Parts @(
        pSvc 'SCPolicySvc' 'Disabled' 'Manual'
    )

Add-Tweak -Id 'svc-spotverifier' -Cat $cSvc -Untested -Inv -Def 'On' -Risk 'note' -Name 'Spot Verifier service (svsvc)' `
    -Desc 'On: the service that checks a drive for damage after Windows notices a problem is enabled (Manual, the default). Off: it is set to Disabled, so that automatic check does not run. You can still run a check yourself (chkdsk).' `
    -Parts @(
        pSvc 'svsvc' 'Disabled' 'Manual'
    )

Add-Tweak -Id 'svc-biometric' -Cat $cSvc -Untested -Inv -Def 'On' -Risk 'note' -Name 'Windows Biometric Service (WbioSrvc)' `
    -Desc 'On: the service behind fingerprint and face sign-in (Windows Hello) is enabled (Manual, as Windows has it). Off: it is set to Disabled. A PIN or a password does not use it. Leave this on if you sign in with a fingerprint reader or a face camera.' `
    -Parts @(
        pSvc 'WbioSrvc' 'Disabled' 'Manual'
    )

Add-Tweak -Id 'svc-sensormon' -Cat $cSvc -Untested -Inv -Def 'On' -Name 'Sensor Monitoring service (SensrSvc)' `
    -Desc 'On: the service that watches sensors such as ambient light and screen orientation, for automatic brightness and rotation, is enabled (Manual, as Windows has it). Off: it is set to Disabled. A desktop PC with a normal monitor does not have those sensors.' `
    -Parts @(
        pSvc 'SensrSvc' 'Disabled' 'Manual'
    )

Add-Tweak -Id 'svc-sensordata' -Cat $cSvc -Untested -Inv -Def 'On' -Name 'Sensor Data service (SensorDataService)' `
    -Desc 'On: the service that passes sensor readings on to apps is enabled (Manual, as Windows has it). Off: it is set to Disabled. A desktop PC with a normal monitor does not have those sensors.' `
    -Parts @(
        pSvc 'SensorDataService' 'Disabled' 'Manual'
    )

Add-Tweak -Id 'svc-mixedreality' -Cat $cSvc -Untested -Inv -Def 'On' -Name 'Windows Mixed Reality service' `
    -Desc 'On: the service used by Windows Mixed Reality headsets is enabled (Manual, as Windows has it). Off: it is set to Disabled. Other headsets bring their own software. Recent Windows versions may not have this service at all, and then the setting reads as not available.' `
    -Parts @(
        pSvc 'MixedRealityOpenXRSvc' 'Disabled' 'Manual'
    )

Add-Tweak -Id 'defender-core' -Cat $cPriv -Inv -Def 'On' -Preset -Risk 'note' -Name 'Defender Core telemetry and experiments' `
    -Desc 'On: the Defender Core Service sends telemetry and uses Microsoft''s experimentation service to deliver fixes. Off: both are turned off. Fixes still arrive through the normal Defender updates, and Windows Security keeps scanning as normal. Microsoft recommends leaving both on, because turning them off can slow how quickly it spots problems such as false alarms. If Tamper Protection is on, Windows may refuse these two values; the log then says so.' `
    -Parts @(
        pReg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Features' 'DisableCoreServiceECSIntegration' 1
        pReg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Features' 'DisableCoreService1DSTelemetry' 1
    )

# ------------------------------------------------------- Storage and clean-up ---
Add-Tweak -Id 'storage-sense' -Cat $cStore -Inv -Def 'Depends on the PC' -Name 'Storage Sense' `
    -Desc 'On: Storage Sense is left as Windows has it. It deletes temporary files and old Recycle Bin files on its own (Settings > System > Storage > Storage Sense), and can be set up to clear your Downloads folder as well. Windows turns it on by itself when disk space runs low, and on many PCs it is off until you switch it on. Off: Storage Sense is turned off, so Windows deletes nothing by itself: you decide when to clear space, for example with the two clean-up actions below. Only that one switch is written; switching it back on removes the value, which is the Windows default.' `
    -Parts @(
        pReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy' '01' 0
    )

Add-Tweak -Id 'disk-cleanup' -Cat $cStore -Once -Cleanup -Risk 'note' -Name 'Disk Cleanup (run once)' `
    -Desc 'A one-time action, not a switch. Runs the Disk Cleanup program that comes with Windows (cleanmgr) once, on every drive, for these items only: temporary files, temporary setup files, setup and upgrade log files, Active Setup temp folders, thumbnail cache, Windows error reports, downloaded program files, old browser cache files, Delivery Optimization files, old Check Disk files, system error memory dumps and minidumps, and Windows Update Cleanup. It never touches the Recycle Bin, your Downloads folder, the old Windows installation (Windows.old), device driver packages, the DirectX shader cache, language files or file history versions. Windows Update Cleanup removes the files of updates that were replaced by newer ones: updates that are already installed can no longer be uninstalled afterwards. A Disk Cleanup window shows the progress and it can take several minutes. It runs when you press Apply, files it deletes do not go to the Recycle Bin, and it is never part of Apply all, Tweak all or the Recommended preset.' `
    -Parts @(
        pCustom 'DiskCleanup' 'cleanmgr /sagerun for 14 items: temporary and setup files, logs, thumbnail and error report caches, Delivery Optimization, old update files, memory dumps (not the Recycle Bin, Downloads, Windows.old, drivers or shader cache)'
    )

Add-Tweak -Id 'temp-files' -Cat $cStore -Once -Cleanup -Risk 'note' -Name 'Temporary files (clean up once)' `
    -Desc 'A one-time action, not a switch. Deletes what is inside your own Temp folder (the TEMP folder of your account) and inside C:\Windows\Temp, once. Anything that was changed in the last hour is left alone, and so is anything a running program is using, because Windows does not allow it to be deleted. Folders that end up empty are removed; the two Temp folders themselves stay. Shortcuts and links inside them are removed but never followed, so nothing outside the Temp folders is touched, and a TEMP folder that is not named Temp is never emptied. When it is done it says how many items were removed and how much space that freed. It runs when you press Apply, deleted files do not go to the Recycle Bin, and it is never part of Apply all, Tweak all or the Recommended preset.' `
    -Parts @(
        pCustom 'TempClean' 'delete the files in %TEMP% and C:\Windows\Temp that are older than an hour and not in use; empty sub-folders are removed'
    )

# ------------------------------------------------------------ Look and feel ---
$pers = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
Add-Tweak -Id 'dark' -Cat $cLook -Def 'Off' -Preset -Explorer -Name 'Dark mode for apps and Windows' `
    -Desc 'On: dark theme for apps, the taskbar and Start, with no accent colour on the taskbar. Off: the light theme (the Windows default).' `
    -Parts @(
        pReg $pers 'AppsUseLightTheme' 0 1
        pReg $pers 'SystemUsesLightTheme' 0 1
        pReg $pers 'ColorPrevalence' 0 0
    )

Add-Tweak -Id 'transparency' -Cat $cLook -Inv -Def 'On' -Preset -Explorer -Name 'Transparency effects' `
    -Desc 'On: windows and menus use the see-through effect (the Windows default). Off: they use solid backgrounds instead.' `
    -Parts @(
        pReg $pers 'EnableTransparency' 0 1
    )

Add-Tweak -Id 'taskbar-left' -Cat $cLook -Def 'Off' -Preset -Explorer -Name 'Taskbar icons on the left' `
    -Desc 'On: the taskbar icons are on the left, like Windows 10. (Windows 11 cannot dock the taskbar to the side of the screen.) Off: the icons are centred (the Windows 11 default).' `
    -Parts @(
        pReg $adv 'TaskbarAl' 0 1
    )

Add-Tweak -Id 'taskbar-endtask' -Cat $cLook -Def 'Off' -Preset -Name 'End task in the taskbar right-click menu' `
    -Desc 'On: right-clicking a program on the taskbar shows "End task", so a frozen game or app can be closed in one click without opening Task Manager. Off: the menu has no "End task" (the Windows default). It is the same switch as Settings > System > For developers > End Task, which needs Windows 11 version 23H2 (build 22631.2715) or newer; on an older build the value does nothing.' `
    -Parts @(
        pReg "$adv\TaskbarDeveloperSettings" 'TaskbarEndTask' 1
    )

Add-Tweak -Id 'taskbar-clutter' -Cat $cLook -Inv -Def 'On' -Preset -Explorer -Name 'Widgets and Chat taskbar buttons' `
    -Desc 'On: the Widgets and Chat / Teams buttons show on the taskbar (the Windows default). Off: both buttons are hidden and the Widgets feed is turned off by policy. The Widgets button switch itself is protected on newer Windows 11 builds and may refuse to change; the Widgets policy hides the button anyway, so the setting still counts as off.' `
    -Parts @(
        pRegSoft $adv 'TaskbarDa' 0 1
        pReg $adv 'TaskbarMn' 0 1
        pReg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0
        pReg "$pol\Windows Chat" 'ChatIcon' 3
    )

Add-Tweak -Id 'taskbar-search' -Cat $cLook -Inv -Def 'On' -Preset -Explorer -Name 'Taskbar search button' `
    -Desc 'On: the search box or search icon shows on the taskbar, the way Windows ships it. Off: it is hidden. Search still opens with Win+S, and typing in the Start menu still searches.' `
    -Parts @(
        pReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'SearchboxTaskbarMode' 0
    )

Add-Tweak -Id 'taskbar-taskview' -Cat $cLook -Inv -Def 'On' -Preset -Explorer -Name 'Taskbar Task View button' `
    -Desc 'On: the Task View button (the two overlapping rectangles) shows on the taskbar. Off: it is hidden. Win+Tab still opens Task View and your virtual desktops keep working.' `
    -Parts @(
        pReg $adv 'ShowTaskViewButton' 0 1
    )

# Settings > Personalization > Dynamic Lighting: both switches are per-user values in HKCU\Software\Microsoft\Lighting (1 = on, the default)
$lighting = 'HKCU:\Software\Microsoft\Lighting'
Add-Tweak -Id 'dynamic-lighting' -Cat $cLook -Inv -Def 'On' -Preset -Name 'Dynamic Lighting (RGB devices)' `
    -Desc 'On: Windows can control the lights of keyboards, mice and other RGB devices that support it. "Use Dynamic Lighting on my devices" in Settings > Personalization > Dynamic Lighting is on. Off: Windows stops controlling them, so only the lighting software of your devices sets them. That can be the software that came with the devices or one you chose yourself. Nothing is removed and the devices keep their own lighting settings. If the lights do not change at once, sign out of Windows and back in.' `
    -Parts @(
        pReg $lighting 'AmbientLightingEnabled' 0 1
    )

Add-Tweak -Id 'dynamic-lighting-foreground' -Cat $cLook -Inv -Def 'On' -Preset -Name '"Foreground apps always control lighting"' `
    -Desc 'On: the app you are using controls the lights first if it supports Dynamic Lighting. "Compatible apps in the foreground always control lighting" is on in Settings > Personalization > Dynamic Lighting. Off: the order under "Background light control" decides, so apps in the background can control the lights as well. It only matters while Dynamic Lighting itself is on: with "Dynamic Lighting (RGB devices)" off you will see no difference.' `
    -Parts @(
        pReg $lighting 'ControlledByForegroundApp' 0 1
    )

Add-Tweak -Id 'start-recommended' -Cat $cLook -Inv -Def 'On' -Preset -Explorer -Risk 'note' -Name 'Start menu Recommended section' `
    -Desc 'On: the Recommended section (recent files and suggested apps) shows in the Start menu. Off: it is hidden, so only your pinned apps show. Off sets the Start policy, the matching group policy and a flag that marks the PC as an education device. Microsoft supports the policy on Education and Enterprise only; the education flag is the workaround people report works on Pro and Home, but Microsoft does not document it, so check the Start menu after Explorer restarts. Side effect: the education flag also turns Windows Spotlight off on the lock screen. The tips setting on the Privacy page and the switches under Settings > Personalization > Start are separate.' `
    -Parts @(
        pReg 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start' 'HideRecommendedSection' 1
        pReg 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Education' 'IsEducationEnvironment' 1
        pReg "$pol\Explorer" 'HideRecommendedSection' 1
    )

Add-Tweak -Id 'blackdesk' -Cat $cLook -Def 'Off' -Preset -Name 'Solid black desktop' `
    -Desc 'On: no wallpaper, a plain black background. Off: the default Windows wallpaper and background colour are put back.' `
    -Parts @(
        pReg 'HKCU:\Control Panel\Colors' 'Background' '0 0 0' '0 0 0' 'String'
        pReg 'HKCU:\Control Panel\Desktop' 'WallPaper' '' "$env:SystemRoot\web\wallpaper\Windows\img0.jpg" 'String'
        pReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers' 'BackgroundType' 1 0
        pCustom 'DesktopLive' 'also applied to the running desktop'
    )

Add-Tweak -Id 'animations' -Cat $cLook -Inv -Def 'On' -Preset -Explorer -Name 'Visual effects (animations, shadows)' `
    -Desc 'On: Windows visual effects are as Windows has them (the Windows default). Off: Visual Effects is set to Custom with only "Smooth edges of screen fonts" left on. That keeps ClearType, so text stays sharp. The setting is in Performance Options > Visual Effects. Everything else is switched off: the window, taskbar, control, menu, tooltip, combo box and list scrolling animations, Aero Peek, the shadows under windows, the mouse pointer and desktop icon labels, the translucent selection rectangle, showing window contents while you drag (a window moves as an outline), keeping taskbar thumbnail previews, and picture and video thumbnails in File Explorer (they show as plain icons). It is applied to the running session at once and Explorer restarts. Switching it back on puts back the Windows default for all of these.' `
    -Parts @(
        pReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 3 0
        pReg 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' '1' 'String'
        pReg $adv 'TaskbarAnimations' 0 1
        pReg $adv 'ListviewAlphaSelect' 0 1
        pReg $adv 'ListviewShadow' 0 1
        pReg $adv 'IconsOnly' 1 0
        pReg 'HKCU:\Software\Microsoft\Windows\DWM' 'EnableAeroPeek' 0 1
        pReg 'HKCU:\Software\Microsoft\Windows\DWM' 'AlwaysHibernateThumbnails' 0 1
        pReg 'HKCU:\Control Panel\Desktop' 'DragFullWindows' '0' '1' 'String'
        pReg 'HKCU:\Control Panel\Desktop' 'FontSmoothing' '2' '2' 'String'
        pReg 'HKCU:\Control Panel\Desktop' 'FontSmoothingType' 2 2
        pCustom 'AnimLive' 'also applied to the running session'
    )

Add-Tweak -Id 'notifications' -Cat $cLook -Inv -Def 'On' -Preset -Explorer -Risk 'note' -Name 'Notifications and notification centre' `
    -Desc 'On: apps, games and Windows can show toast pop-ups, and the notification centre works. Off: no toast pop-ups, and the notification centre is switched off; the calendar flyout goes with it. Windows Security pop-ups may be hidden too, so look at its status page now and then. The push notification services stay as they are.' `
    -Parts @(
        pReg 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableNotificationCenter' 1
        pReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' 0 1
    )

# ------------------------------------------------------------ File Explorer ---
Add-Tweak -Id 'launchto' -Cat $cExplorer -Def 'Off' -Explorer -Name 'File Explorer opens to This PC' `
    -Desc 'On: File Explorer starts at This PC (your drives). Off: it starts at Home (the Windows default).' `
    -Parts @(
        pReg $adv 'LaunchTo' 1
    )

Add-Tweak -Id 'showext' -Cat $cExplorer -Def 'Off' -Explorer -Name 'Always show file extensions' `
    -Desc 'On: file names show .exe, .txt, .jpg and so on, which makes disguised files easier to spot. Off: Windows hides the extensions of known file types (the Windows default).' `
    -Parts @(
        pReg $adv 'HideFileExt' 0 1
    )

$clsidMenu = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}'
Add-Tweak -Id 'classic-menu' -Cat $cExplorer -Def 'Off' -Preset -Explorer -Name 'Classic right-click menu' `
    -Desc 'On: File Explorer and the desktop show the full right-click menu of Windows 10 instead of Windows 11''s short menu with "Show more options". Off: the short Windows 11 menu (the default). File Explorer restarts when this is changed, so open Explorer windows close for a moment. Only does something on Windows 11.' `
    -Parts @(
        pKey "$clsidMenu\InprocServer32" $clsidMenu
    )

# The side pane entries are per-user switches (System.IsPinnedToNameSpaceTree = 0 in the entry's own class key); 0 hides, no value = Windows default.
$clsidHome    = 'HKCU:\Software\Classes\CLSID\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}'
$clsidGallery = 'HKCU:\Software\Classes\CLSID\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}'
Add-Tweak -Id 'nav-home' -Cat $cExplorer -Inv -Def 'On' -Preset -Explorer -Name 'Home in the File Explorer side pane' `
    -Desc 'On: "Home" shows as the first entry of the left-hand pane in File Explorer. Off: it is hidden for your account. File Explorer restarts when this is changed, so open Explorer windows close for a moment. It does not change where File Explorer opens: "File Explorer opens to This PC" does that. If "Show all folders" is switched on in File Explorer''s options, Home can still show.' `
    -Parts @(
        pReg $clsidHome 'System.IsPinnedToNameSpaceTree' 0
    )

Add-Tweak -Id 'nav-gallery' -Cat $cExplorer -Inv -Def 'On' -Preset -Explorer -Name 'Gallery in the File Explorer side pane' `
    -Desc 'On: "Gallery" (the photo view of your Pictures folder, Windows 11 23H2 and newer) shows in the left-hand pane in File Explorer. Off: it is hidden for your account. File Explorer restarts when this is changed, so open Explorer windows close for a moment. Your pictures are not touched. If "Show all folders" is switched on in File Explorer''s options, Gallery can still show.' `
    -Parts @(
        pReg $clsidGallery 'System.IsPinnedToNameSpaceTree' 0
    )

$cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
Add-Tweak -Id 'suggestions' -Cat $cLook -Inv -Def 'On' -Preset -Name 'Ads, suggestions and auto-installed apps' `
    -Desc 'On: Windows shows promoted apps in Start, tips and suggestions on the lock screen and in Settings, and may install sponsored apps by itself. That includes account notifications in Start and Settings, Phone Link suggestions, "Suggested" pop-ups and Windows Backup reminders. Off: none of that, and no Spotlight extras. The three policies in it (consumer features, tips and Spotlight) are only obeyed by Enterprise and Education, and the online-tips policy (Settings does not fetch tips and help from Microsoft) only by Pro, Enterprise and Education, so the app leaves out the ones your edition ignores; the per-user switches work on every edition.' `
    -Parts @(
        pEd 'Ent' (pReg "$pol\CloudContent" 'DisableWindowsConsumerFeatures' 1)
        pEd 'Ent' (pReg "$pol\CloudContent" 'DisableSoftLanding' 1)
        pEd 'Ent' (pReg "$pol\CloudContent" 'DisableWindowsSpotlightFeatures' 1)
        pEd 'Pro,Ent' (pReg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'AllowOnlineTips' 0)
        pReg $cdm 'ContentDeliveryAllowed' 0 1
        pReg $cdm 'OemPreInstalledAppsEnabled' 0 1
        pReg $cdm 'PreInstalledAppsEnabled' 0 1
        pReg $cdm 'PreInstalledAppsEverEnabled' 0 1
        pReg $cdm 'SilentInstalledAppsEnabled' 0 1
        pReg $cdm 'SystemPaneSuggestionsEnabled' 0 1
        pReg $cdm 'SoftLandingEnabled' 0 1
        pReg $cdm 'SubscribedContentEnabled' 0 1
        pReg $cdm 'SubscribedContent-310093Enabled' 0 1
        pReg $cdm 'SubscribedContent-338387Enabled' 0 1
        pReg $cdm 'SubscribedContent-338388Enabled' 0 1
        pReg $cdm 'SubscribedContent-338389Enabled' 0 1
        pReg $cdm 'SubscribedContent-338393Enabled' 0 1
        pReg $cdm 'SubscribedContent-353694Enabled' 0 1
        pReg $cdm 'SubscribedContent-353696Enabled' 0 1
        pReg $cdm 'SubscribedContent-353698Enabled' 0 1
        pReg $cdm 'RotatingLockScreenOverlayEnabled' 0 1
        pReg $adv 'Start_IrisRecommendations' 0 1
        pReg $adv 'ShowSyncProviderNotifications' 0 1
        pReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' 'ScoobeSystemSettingEnabled' 0 1
        pReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SystemSettings\AccountNotifications' 'EnableAccountNotifications' 0 1
        pReg $adv 'Start_AccountNotifications' 0 1
        pReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Mobility' 'OptedIn' 0 1
        pReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.Suggested' 'Enabled' 0 1
        pReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.BackupReminder' 'Enabled' 0 1
    )

Add-Tweak -Id 'settings-promo' -Cat $cLook -Inv -Def 'On' -Preset -Name 'Copilot and account cards in Settings' `
    -Desc 'On: the Microsoft account and Copilot subscription cards show on the Settings home page, and Windows pulls in cloud-optimized suggestions. Off: both are hidden. Both policies are only obeyed by Enterprise and Education, so on Home and Pro this setting is shown as not available.' `
    -Parts @(
        pEd 'Ent' (pReg "$pol\CloudContent" 'DisableConsumerAccountStateContent' 1)
        pEd 'Ent' (pReg "$pol\CloudContent" 'DisableCloudOptimizedContent' 1)
    )

$wsch = "$pol\Windows Search"
$ssm  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings'
Add-Tweak -Id 'search-web' -Cat $cLook -Inv -Def 'On' -Preset -Name 'Web and cloud results in Start search' `
    -Desc 'On: Start search also shows Bing results, Microsoft Store suggestions, cloud account search, search highlights and search history on the device. Off: Start search only looks on this PC, and under Settings > Privacy & security > Search both "Show suggested search results" switches (Web searches and Microsoft Store) are off.' `
    -Parts @(
        pReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0 1
        pReg 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1
        pReg $wsch 'AllowCloudSearch' 0
        pEd 'Ent' (pReg $wsch 'ConnectedSearchUseWeb' 0)
        pReg $wsch 'AllowSearchToUseLocation' 0
        pReg $wsch 'DisableWebSearch' 1
        pReg $wsch 'AllowCortana' 0
        pReg $ssm 'IsDeviceSearchHistoryEnabled' 0 1
        pReg $ssm 'IsMSACloudSearchEnabled' 0 1
        pReg $ssm 'IsAADCloudSearchEnabled' 0 1
        pReg $ssm 'IsDynamicSearchBoxEnabled' 0 1
        pReg $ssm 'IsWebSuggestionsEnabled' 0 1
        pReg $ssm 'IsStoreSuggestionsEnabled' 0 1
    )

Add-Tweak -Id 'snap-suggestions' -Cat $cLook -Inv -Def 'On' -Explorer -Name 'Snap suggestions and layouts flyout' `
    -Desc 'On: Windows shows what you can snap next to a window right after you snap it, the snap-layouts box when you point at a window''s maximize button, and the layouts bar when you drag a window to the top of the screen. Off: all three are switched off (the three "Snap windows" options in Settings > System > Multitasking). Snapping itself still works: dragging a window to a screen edge and Win+Arrow keys are not touched. File Explorer restarts when this is changed, so open Explorer windows close for a moment.' `
    -Parts @(
        pReg $adv 'SnapAssist' 0 1
        pReg $adv 'EnableSnapAssistFlyout' 0 1
        pReg $adv 'EnableSnapBar' 0 1
    )

Add-Tweak -Id 'window-shake' -Cat $cLook -Def 'Off' -Explorer -Name 'Block title bar window shake' `
    -Desc 'On: grabbing a window by its title bar and shaking it no longer minimizes all the other windows (DisallowShaking = 1). Off: Windows decides. Windows 11 ships with this shake already switched off ("Title bar window shake" in Settings > System > Multitasking), so on most PCs this changes nothing; it only matters on a PC where the shake was switched on. File Explorer restarts when this is changed, so open Explorer windows close for a moment.' `
    -Parts @(
        pReg $adv 'DisallowShaking' 1
    )

# ------------------------------------------------------------------ AI ---------
Add-Tweak -Id 'copilot' -Cat $cAi -Inv -Def 'On' -Preset -Explorer -Name 'Copilot' `
    -Desc 'On: the old Windows Copilot side panel and the Copilot button on the taskbar are available. Off: the side panel is turned off by policy and the taskbar button is hidden. Microsoft has marked that policy as deprecated. The newer Copilot is an app: "Copilot and Cortana apps" under Remove apps takes that out.' `
    -Parts @(
        pReg "$pol\WindowsCopilot" 'TurnOffWindowsCopilot' 1
        pReg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
        pReg $adv 'ShowCopilotButton' 0 1
    )

Add-Tweak -Id 'recall' -Cat $cAi -Inv -Def 'On' -Preset -Reboot -Name 'Recall, Click to Do and Settings AI search' `
    -Desc 'On: Recall snapshots, Click to Do, AI analysis of your data and the AI search in Settings are left to Windows. Off: all of them are turned off by policy. A second snapshot value, TurnOffSavingSnapshots, is set as well; Microsoft does not list it, so Windows may ignore it; it does no harm. On Copilot+ PCs the Recall optional feature is also removed and the Windows AI Fabric service is switched off. The Settings AI search policy is only obeyed by Enterprise and Education and is left out on Home and Pro; the others need a recent build of Windows 11 and do no harm on an older one.' `
    -Parts @(
        pReg "$pol\WindowsAI" 'DisableAIDataAnalysis' 1
        pReg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1
        pReg "$pol\WindowsAI" 'AllowRecallEnablement' 0
        pReg "$pol\WindowsAI" 'TurnOffSavingSnapshots' 1
        pReg "$pol\WindowsAI" 'DisableClickToDo' 1
        pReg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsAI' 'DisableClickToDo' 1
        pEd 'Ent' (pReg "$pol\WindowsAI" 'DisableSettingsAgent' 1)
        pFeat 'Recall'
        pSvc 'WSAIFabricSvc' 'Disabled' 'Manual'
    )

$paintPol = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint'
Add-Tweak -Id 'ai-apps' -Cat $cAi -Inv -Def 'On' -Preset -Risk 'note' -Name 'AI features in Notepad and Paint' `
    -Desc 'On: Notepad''s AI features (Rewrite, Summarize, Write) and Paint''s Image Creator, Cocreator, Generative Fill, Generative erase and Remove background are available. Off: they are turned off by policy. Microsoft documents the policies for the first three but not for Generative erase and Remove background, so Paint may ignore those two and still show them. A few Windows builds have refused to start Paint while Image Creator is blocked; if that happens, switch this back on and restart.' `
    -Parts @(
        pReg 'HKLM:\SOFTWARE\Policies\WindowsNotepad' 'DisableAIFeatures' 1
        pReg $paintPol 'DisableImageCreator' 1
        pReg $paintPol 'DisableCocreator' 1
        pReg $paintPol 'DisableGenerativeFill' 1
        pReg $paintPol 'DisableGenerativeErase' 1
        pReg $paintPol 'DisableRemoveBackground' 1
    )

Add-Tweak -Id 'ai-generative' -Cat $cAi -Inv -Def 'On' -Preset -Name 'Text and image generation (Windows AI)' `
    -Desc 'On: apps can use Windows'' text and image generation and system AI models. The "Text and image generation" and "System AI models" privacy settings in Settings > Privacy and security are left to you. Off: text and image generation and system AI models are set to Deny for every app, by policy. An app cannot switch them back on. It only concerns Windows'' own AI features; ordinary apps and games are not touched.' `
    -Parts @(
        pReg "$pol\AppPrivacy" 'LetAppsAccessGenerativeAI' 2
        pReg "$pol\AppPrivacy" 'LetAppsAccessSystemAIModels' 2
    )

Add-Tweak -Id 'ai-voice' -Cat $cAi -Inv -Def 'On' -Preset -Name 'Voice activation (wake word)' `
    -Desc 'On: apps can be started by a spoken wake word ("Hey Copilot", the old "Hey Cortana"), also from the lock screen. Off: they cannot. Voice typing and the microphone in games or chat programs are not meant to be affected. The Agent Activation Runtime service is left alone: it only starts when something asks for it.' `
    -Parts @(
        pReg "$pol\AppPrivacy" 'LetAppsActivateWithVoice' 2
        pReg "$pol\AppPrivacy" 'LetAppsActivateWithVoiceAboveLock' 2
        pReg 'HKCU:\Software\Microsoft\Speech_OneCore\Settings\VoiceActivation\UserPreferenceForAllApps' 'AgentActivationEnabled' 0 1
    )

Add-Tweak -Id 'ai-core' -Cat $cAi -Inv -Def 'On' -OneWay -Risk 'note' -Name 'Windows AI core package' `
    -Desc 'On: MicrosoftWindows.Client.CoreAI is installed; it is the Windows package that Windows'' AI features run on (Click to Do and Recall, for example). Off: the package is removed. Windows treats it as part of the system, so this app first marks it as deprovisioned (so Windows does not install it again for new accounts or with an update), takes off Windows'' own "not removable" mark where Windows has that command, and marks it as end of life for SYSTEM and every account, which is the way Windows allows such a package to be removed. Then it is removed for all users (or account by account when Windows refuses that), and from the list of apps new accounts get, and the end-of-life marks are taken out again, because left in place they can stop Windows Update from installing updates. Windows keeps a copy for its own system account (S-1-5-18) and puts that copy back when it is removed; that copy is installed for no one who signs in, so it does not count. If Windows still keeps it for an account that signs in, the setting says Failed with what Windows said. If it is in use, Windows finishes removing it at the next restart. On a PC that does not have it, the setting reads as off and nothing happens. It cannot be put back from here, and a Windows feature update can bring it back. The other settings on this page are policies and keep working whether or not the package is there.' `
    -Parts @(
        pCustom 'AiCore' 'marks MicrosoftWindows.Client.CoreAI deprovisioned (HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned), turns its "not removable" policy off (Set-NonRemovableAppsPolicy), marks it end of life for SYSTEM and every account (AppxAllUserStore\EndOfLife), removes it for all users and from the apps new accounts get, then takes the end-of-life marks out again    (cannot be undone from here)'
    )

Add-Tweak -Id 'ai-page' -Cat $cAi -Inv -Def 'On' -Preset -Name 'AI components page in Settings' `
    -Desc 'On: the "AI components" page shows in Settings (System > AI components, on the Windows versions that have it). Off: it is hidden by adding it to the list of Settings pages that policy hides. Pages that are already in that list stay in it. The AI features themselves are not changed, the page only stops being shown. Switching it back on takes just that page off the list again. If Settings on this PC is limited to a "showonly" list of pages, this setting reads as not available.' `
    -Parts @(
        pCustom 'SettingsHide' 'adds aicomponents to the hide: list in HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer\SettingsPageVisibility and leaves every other page in that list as it is    (undo: takes only aicomponents out again)' 'aicomponents'
    )

Add-Tweak -Id 'ai-agentic' -Cat $cAi -Def 'Off' -Reboot -Name 'Keep experimental agentic features off' `
    -Desc 'On: the "Experimental agentic features" switch (Settings > System > AI components > Agent tools, on the Windows builds that have it) is held off, so AI agents cannot be given their own workspace and account on this PC. Off: Windows decides, and the switch in Settings stays yours; it is off by default. This uses the value Enabled (0 = off) under HKLM\SYSTEM\CurrentControlSet\Services\IsoEnvBroker. Only a Windows build that has the feature has that key, so on any other PC the setting reads as not available and nothing is written. Switching this off again removes the value, which is how Windows ships it (the feature off); the switch in Settings is then yours again. A restart makes sure Windows reads the change.' `
    -Parts @(
        pRegDyn -Info 'HKLM\SYSTEM\CurrentControlSet\Services\IsoEnvBroker: Enabled = 0, only when that key exists on this PC    (undo: the value Windows had)' -Gen {
            if (Reg-KeyExists 'HKLM:\SYSTEM\CurrentControlSet\Services\IsoEnvBroker') { pReg 'HKLM:\SYSTEM\CurrentControlSet\Services\IsoEnvBroker' 'Enabled' 0 }
        }
    )

$chrome = 'HKLM:\SOFTWARE\Policies\Google\Chrome'
Add-Tweak -Id 'chrome-ai' -Cat $cAi -Inv -Def 'On' -Name 'Chrome: Gemini and other AI features' `
    -Desc 'On: Chrome''s AI features are left to Chrome. Off: sixteen Chrome policies turn them off. Among them are Gemini in Chrome, AI Mode, "Help me write", AI themes, AI history search, tab compare, the AI helper in DevTools, third-party AI chat, voice typing and the local AI model (Chrome then stops downloading it). Chrome shows "Managed by your organization" while any policy is set. Chrome only reads the policies for features it has, so an older Chrome ignores some of them. Switching it back on removes the policies.' `
    -Parts @(
        pReg $chrome 'AIModeSettings' 1
        pReg $chrome 'AutofillPredictionSettings' 2
        pReg $chrome 'ChromeSuggestionsSettings' 1
        pReg $chrome 'CreateThemesSettings' 2
        pReg $chrome 'DevToolsGenAiSettings' 2
        pReg $chrome 'FindAndFillWithGeminiSettings' 2
        pReg $chrome 'GeminiSettings' 1
        pReg $chrome 'GeminiSparkSettings' 1
        pReg $chrome 'GenAILocalFoundationalModelSettings' 1
        pReg $chrome 'HelpMeWriteSettings' 2
        pReg $chrome 'HistorySearchSettings' 2
        pReg $chrome 'SearchContentSharingSettings' 1
        pReg $chrome 'SmartTabSharingSettings' 1
        pReg $chrome 'TabCompareSettings' 2
        pReg $chrome 'ThirdPartyAiChatSettings' 1
        pReg $chrome 'VoiceTypingSettings' 2
    )

# ----------------------------------------------------------------- Edge --------
Add-Tweak -Id 'edge-ai' -Cat $cEdge -Inv -Def 'On' -Preset -Name 'Edge: Copilot sidebar and recommendations' `
    -Desc 'On: Edge''s sidebar, Copilot page context, Microsoft 365 Copilot icon, shopping assistant and recommendations are available. Off: all of them are turned off by policy.' `
    -Parts @(
        pReg $edge 'HubsSidebarEnabled' 0
        pReg $edge 'CopilotPageContext' 0
        pReg $edge 'Microsoft365CopilotChatIconEnabled' 0
        pReg $edge 'ShowRecommendationsEnabled' 0
        pReg $edge 'EdgeShoppingAssistantEnabled' 0
    )

Add-Tweak -Id 'edge-ai-more' -Cat $cEdge -Inv -Def 'On' -Preset -Name 'Edge: AI writing help and local AI model' `
    -Desc 'On: Edge''s extra AI features are available. These are Rewrite, AI-enhanced history search, AI-generated themes, the Bing chat entries and the Copilot page on the new tab page, browsing with Copilot, sharing history with Microsoft 365 Copilot Search, Copilot access to page content for work accounts, tab group name suggestions (they need Edge to send your tab data to an online service) and the built-in AI interfaces for websites. Off: all of those AI features are turned off. Edge also stops downloading its local AI model, and deletes it if it is already there (this frees disk space). Edge ignores several of these policies in a profile that is signed in with a personal Microsoft account; there, switch the same features off in Edge''s own settings.' `
    -Parts @(
        pReg $edge 'ComposeInlineEnabled' 0
        pReg $edge 'EdgeHistoryAISearchEnabled' 0
        pReg $edge 'AIGenThemesEnabled' 0
        pReg $edge 'NewTabPageBingChatEnabled' 0
        pReg $edge 'CopilotNewTabPageEnabled' 0
        pReg $edge 'AllowBrowsingWithCopilot' 0
        pReg $edge 'EdgeEntraCopilotPageContext' 0
        pReg $edge 'CopilotCDPPageContext' 0
        pReg $edge 'TabServicesEnabled' 0
        pReg $edge 'ShareBrowsingHistoryWithCopilotSearchAllowed' 0
        pReg $edge 'BuiltInAIAPIsEnabled' 0
        pReg $edge 'GenAILocalFoundationalModelSettings' 1
    )

Add-Tweak -Id 'edge-bg' -Cat $cEdge -Inv -Def 'On' -Preset -Name 'Edge: startup boost and background running' `
    -Desc 'On: Edge pre-loads at sign-in and keeps running after you close it. Off: it does neither.' `
    -Parts @(
        pReg $edge 'StartupBoostEnabled' 0
        pReg $edge 'BackgroundModeEnabled' 0
    )

Add-Tweak -Id 'edge-tele' -Cat $cEdge -Inv -Def 'On' -Preset -Name 'Edge: telemetry and sync' `
    -Desc 'On: Edge sends usage reporting, personalisation reporting, diagnostic data and feedback, and syncs your profile. Off: all of that is turned off.' `
    -Parts @(
        pReg $edge 'MetricsReportingEnabled' 0
        pReg $edge 'PersonalizationReportingEnabled' 0
        pReg $edge 'DiagnosticData' 0
        pReg $edge 'SyncDisabled' 1
        pReg $edge 'UserFeedbackAllowed' 0
        pReg $edge 'SendSiteInfoToImproveServices' 0
    )

Add-Tweak -Id 'edge-debloat' -Cat $cEdge -Inv -Def 'On' -Preset -Name 'Edge: first-run page, rewards and nags' `
    -Desc 'On: Edge shows its first-run page, promotions and other extras, as it does by default. That is the first-run welcome page, a desktop shortcut made when it updates, suggestions on error pages, Collections, Insider promotion, Microsoft Rewards, the web widget, Microsoft content pushed to Edge, the donation prompt in Wallet, "make Edge your default browser" campaigns and the check that asks whether Edge is your default browser. Spotlight tips and recommendations for Microsoft services and the Adobe Acrobat subscription button in Edge''s PDF viewer go too. Off: Edge policies turn all of those off and Do Not Track is set on (sites may ignore it). Edge shows "Managed by your organization" while any policy is set. Switching it back on removes the policies.' `
    -Parts @(
        pReg $edge 'HideFirstRunExperience' 1
        pReg $edge 'ConfigureDoNotTrack' 1
        pReg $edge 'AlternateErrorPagesEnabled' 0
        pReg $edge 'EdgeCollectionsEnabled' 0
        pReg $edge 'MicrosoftEdgeInsiderPromotionEnabled' 0
        pReg $edge 'ShowMicrosoftRewards' 0
        pReg $edge 'WebWidgetAllowed' 0
        pReg $edge 'EdgeAssetDeliveryServiceEnabled' 0
        pReg $edge 'WalletDonationEnabled' 0
        pReg $edge 'DefaultBrowserSettingsCampaignEnabled' 0
        pReg $edge 'DefaultBrowserSettingEnabled' 0
        pReg $edge 'SpotlightExperiencesAndRecommendationsEnabled' 0
        pReg $edge 'ShowAcrobatSubscriptionButton' 0
        pReg 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' 'CreateDesktopShortcutDefault' 0
    )

Add-Tweak -Id 'edge-newtab' -Cat $cEdge -Inv -Def 'On' -Name 'Edge: news feed on the new tab page' `
    -Desc 'On: the new tab page in Edge shows Microsoft''s news and content feed and the shortcut tiles Microsoft fills in for you. Off: the content feed is turned off ("Content off") and the pre-filled shortcut tiles are hidden. Edge shows "Managed by your organization" while any policy is set. Switching it back on removes the policies.' `
    -Parts @(
        pReg $edge 'NewTabPageContentEnabled' 0
        pReg $edge 'NewTabPageHideDefaultTopSites' 1
    )

Add-Tweak -Id 'edge-tasks' -Cat $cEdge -Inv -Def 'On' -Preset -Risk 'note' -Name 'Edge background update tasks' `
    -Desc 'On: Edge Update starts at sign-in and every hour (its two scheduled tasks are enabled). Off: both tasks are disabled, which keeps the "Microsoft Edge Update" process out of your background list. Edge, and the WebView2 component that many apps use, then stop getting background updates, so only switch this off if you do not use Edge.' `
    -Parts @(
        pTaskDyn '\' 'MicrosoftEdgeUpdateTask' 'scheduled tasks \MicrosoftEdgeUpdateTask* (Edge Update, at sign-in and hourly): off    (undo: on)'
    )

# ----------------------------------------------------------------- Apps --------
Add-Tweak -Id 'apps-ai' -Cat $cApps -Inv -Def 'On' -OneWay -Name 'Copilot and Cortana apps' `
    -Desc 'On: the Copilot app and the Cortana app are installed. Off: both are removed for all users. They cannot be switched back on from here; install them again from the Microsoft Store.' `
    -Parts @(
        pAppx 'Microsoft.Copilot', 'Microsoft.Windows.Ai.Copilot.Provider', 'Microsoft.549981C3F5F10'
    )

Add-Tweak -Id 'apps-news' -Cat $cApps -Inv -Def 'On' -OneWay -Name 'News, Weather, Maps and Bing Search apps' `
    -Desc 'On: the Bing News, Weather, Search and Windows Maps apps are installed. Off: they are removed. They cannot be switched back on from here; install them again from the Microsoft Store.' `
    -Parts @(
        pAppx 'Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.BingSearch', 'Microsoft.WindowsMaps'
    )

Add-Tweak -Id 'apps-mail' -Cat $cApps -Inv -Def 'On' -OneWay -Name 'Mail, Calendar, Outlook, People and Teams' `
    -Desc 'On: the Mail and Calendar app, the new Outlook, People, and the Teams chat apps are installed. Off: they are removed. They cannot be switched back on from here; install them again from the Microsoft Store.' `
    -Parts @(
        pAppx 'microsoft.windowscommunicationsapps', 'Microsoft.OutlookForWindows', 'Microsoft.People', 'MSTeams', 'MicrosoftTeams'
    )

Add-Tweak -Id 'apps-phone' -Cat $cApps -Inv -Def 'On' -OneWay -Name 'Phone Link and Cross Device' `
    -Desc 'On: the Phone Link (Your Phone) and Cross Device apps are installed. Off: they are removed. They cannot be switched back on from here; install them again from the Microsoft Store.' `
    -Parts @(
        pAppx 'Microsoft.YourPhone', 'MicrosoftWindows.CrossDevice'
    )

Add-Tweak -Id 'apps-media' -Cat $cApps -Inv -Def 'On' -OneWay -Risk 'note' -Name 'Media Player and Movies & TV' `
    -Desc 'On: the ZuneMusic and ZuneVideo packages are installed. On Windows 11, ZuneMusic IS the Media Player app. Off: both are removed, so Media Player goes too. They cannot be switched back on from here; install them again from the Microsoft Store.' `
    -Parts @(
        pAppx 'Microsoft.ZuneMusic', 'Microsoft.ZuneVideo'
    )

Add-Tweak -Id 'apps-notes' -Cat $cApps -Inv -Def 'On' -OneWay -Name 'Sticky Notes, To Do, OneNote and more' `
    -Desc 'On: the Sticky Notes, Microsoft To Do, OneNote, Whiteboard and Power Automate apps are installed. Off: they are removed. They cannot be switched back on from here; install them again from the Microsoft Store.' `
    -Parts @(
        pAppx 'Microsoft.MicrosoftStickyNotes', 'Microsoft.Todos', 'Microsoft.Office.OneNote', 'Microsoft.Whiteboard', 'Microsoft.PowerAutomateDesktop'
    )

Add-Tweak -Id 'apps-extras' -Cat $cApps -Inv -Def 'On' -OneWay -Name 'Extra Microsoft apps (Tips, Clipchamp)' `
    -Desc 'On: the extra apps that come with Windows are installed. These are Get Help, Tips, Feedback Hub, Dev Home, the Microsoft 365 hub, Solitaire Collection, Clipchamp, 3D Viewer, Mixed Reality Portal, Print 3D, Paint 3D, Skype, OneConnect and Microsoft Family. Off: they are removed. They cannot be switched back on from here; install them again from the Microsoft Store.' `
    -Parts @(
        pAppx 'Microsoft.GetHelp', 'Microsoft.Getstarted', 'Microsoft.WindowsFeedbackHub', 'Microsoft.Windows.DevHome',
              'Microsoft.MicrosoftOfficeHub', 'Microsoft.MicrosoftSolitaireCollection', 'Clipchamp.Clipchamp',
              'Microsoft.Microsoft3DViewer', 'Microsoft.MixedReality.Portal', 'Microsoft.Print3D', 'Microsoft.MSPaint',
              'Microsoft.SkypeApp', 'Microsoft.OneConnect', 'MicrosoftCorporationII.MicrosoftFamily'
    )

Add-Tweak -Id 'apps-widgets' -Cat $cApps -Inv -Def 'On' -OneWay -Name 'Widgets (Windows Web Experience Pack)' `
    -Desc 'On: the Widgets panel is installed. Off: it is removed completely. If you only want to hide the button, use "Widgets and Chat taskbar buttons" instead, which can be switched back on. The panel cannot be switched back on from here; install it again from the Microsoft Store.' `
    -Parts @(
        pAppx 'MicrosoftWindows.Client.WebExperience'
    )

Add-Tweak -Id 'apps-promo' -Cat $cApps -Inv -Def 'On' -OneWay -Risk 'note' -Name 'Promo apps (LinkedIn, Spotify, TikTok...)' `
    -Desc 'On: the promo apps that come with Windows stay installed. Off: the promo apps that come with Windows are removed by name. These are LinkedIn, Disney+, Spotify, TikTok, Instagram, Facebook, Twitter, Netflix, Amazon / Prime Video, Hulu, Candy Crush, Duolingo, Flipboard, McAfee and Norton. Careful: this also removes the Microsoft Store versions of those apps if you installed them yourself. Games such as Roblox are not touched. They cannot be switched back on from here.' `
    -Parts @(
        pAppx '*LinkedIn*', '*Disney*', '*Spotify*', '*TikTok*', '*Instagram*', '*Facebook*', '*Twitter*', '*Netflix*', '*Amazon*',
              '*PrimeVideo*', '*Hulu*', '*CandyCrush*', '*Duolingo*', '*Flipboard*', '*McAfee*', '*Norton*'
    )

Add-Tweak -Id 'apps-dolby' -Cat $cApps -Inv -Def 'On' -OneWay -Risk 'note' -Name 'Dolby Access' `
    -Desc 'On: the Dolby Access app is installed. Off: it is removed (the Dolby audio drivers are not). Without it Dolby Atmos for headphones and home theatre stops working, so leave this on if you use Atmos. It cannot be switched back on from here; install it again from the Microsoft Store.' `
    -Parts @(
        pAppx 'DolbyLaboratories.DolbyAccess'
    )

Add-Tweak -Id 'apps-gamebar' -Cat $cApps -Inv -Def 'On' -OneWay -Risk 'note' -Name 'Game Bar app' `
    -Desc 'On: the Xbox Game Bar overlay (Win+G, the screenshot and recording widgets) and its speech-to-text overlay are installed. Off: they are removed. The Xbox app and Game Pass are not touched; "Xbox app and Xbox sign-in" takes those out. Removing Game Bar can make an "ms-gamingoverlay" pop-up appear in some games or on controller buttons; switching off "Xbox Game Bar and background recording" under Gaming and performance is the usual fix. It cannot be switched back on from here; get it back with winget install 9pfhdd62mxs1.' `
    -Parts @(
        pAppx 'Microsoft.XboxGamingOverlay', 'Microsoft.XboxGameOverlay', 'Microsoft.XboxSpeechToTextOverlay'
    )

Add-Tweak -Id 'apps-gameassist' -Cat $cApps -Inv -Def 'On' -OneWay -Name 'Microsoft Edge Game Assist' `
    -Desc 'On: Microsoft Edge Game Assist is installed. It is the Edge browser widget for Game Bar (EdgeGameAssist.exe) and shows in Settings > Apps as "Microsoft Edge Game Assist". Off: it is removed for every user account. Edge itself and Game Bar are not touched. Edge can install it again when it updates; the next check of the PC then offers to remove it again. It cannot be switched back on from here; get it back from the Game Bar widget store.' `
    -Parts @(
        pAppx 'Microsoft.Edge.GameAssist'
    )

Add-Tweak -Id 'apps-xbox' -Cat $cApps -Inv -Def 'On' -OneWay -Risk 'note' -Name 'Xbox app and Xbox sign-in' `
    -Desc 'On: the Xbox app, Xbox Identity Provider and the Xbox sign-in dialog package are installed. Off: they are removed, which breaks Game Pass, the Xbox app and Microsoft Store games. Game Bar is a separate setting above this one. They cannot be switched back on from here; install them again from the Microsoft Store.' `
    -Parts @(
        pAppx 'Microsoft.GamingApp', 'Microsoft.XboxIdentityProvider', 'Microsoft.Xbox.TCUI', 'Microsoft.XboxApp'
    )

Add-Tweak -Id 'apps-store' -Cat $cApps -Inv -Def 'On' -OneWay -Risk 'note' -Name 'Microsoft Store app' `
    -Desc 'On: the Microsoft Store app and its purchase / engagement helpers are installed. Off: they are removed (this is the setting that works on every edition of Windows). winget (App Installer) stays. Apps that come from the Store (for example NVIDIA Control Panel and Photos) stop receiving updates. It cannot be switched back on from here; get it back later with  wsreset -i.' `
    -Parts @(
        pAppx 'Microsoft.WindowsStore', 'Microsoft.StorePurchaseApp', 'Microsoft.Services.Store.Engagement'
    )

Add-Tweak -Id 'apps-clock' -Cat $cApps -Inv -Def 'On' -OneWay -Name 'Clock app (alarms, timers, stopwatch)' `
    -Desc 'On: the Clock app (Microsoft.WindowsAlarms) is installed. Off: it is removed for all users. If it is not on this PC the setting reads as off and nothing happens. It cannot be switched back on from here; install it again from the Microsoft Store if you want it.' `
    -Parts @(
        pAppx 'Microsoft.WindowsAlarms'
    )

Add-Tweak -Id 'apps-startexp' -Cat $cApps -Inv -Def 'On' -OneWay -Name 'Start Experiences App' `
    -Desc 'On: the Start Experiences App (Microsoft.StartExperiencesApp) is installed. Off: it is removed for all users. It is a Microsoft app listed under Installed apps; nothing else was found that depends on it, and a forum report says removing it harms nothing. If it is not on this PC the setting reads as off and nothing happens. It cannot be switched back on from here.' `
    -Parts @(
        pAppx 'Microsoft.StartExperiencesApp'
    )

Add-Tweak -Id 'apps-camera' -Cat $cApps -Inv -Def 'On' -OneWay -Name 'Camera app' `
    -Desc 'On: the Camera app (Microsoft.WindowsCamera) is installed. Off: it is removed for all users. Your webcam keeps working in other programs (browsers, Discord, Teams) and for Windows Hello; only the Camera app itself goes. If it is not on this PC the setting reads as off and nothing happens. It cannot be switched back on from here; install it again from the Microsoft Store.' `
    -Parts @(
        pAppx 'Microsoft.WindowsCamera'
    )

Add-Tweak -Id 'apps-paint' -Cat $cApps -Inv -Def 'On' -OneWay -Name 'Paint app' `
    -Desc 'On: the Paint app (Microsoft.Paint) is installed. Off: it is removed for all users. Paint 3D is a different app and is removed by "Extra Microsoft apps (Tips, Clipchamp)". If Paint is not on this PC the setting reads as off and nothing happens. It cannot be switched back on from here; install it again from the Microsoft Store.' `
    -Parts @(
        pAppx 'Microsoft.Paint'
    )

Add-Tweak -Id 'apps-snip' -Cat $cApps -Inv -Def 'On' -OneWay -Risk 'note' -Name 'Snipping Tool' `
    -Desc 'On: the Snipping Tool app (Microsoft.ScreenSketch) is installed. Off: it is removed for all users. It is Windows'' own screenshot tool: the editing window that follows Win+Shift+S and what the Print Screen key opens go with it, so keep it on if you use them. Screenshots from Steam, the NVIDIA overlay and other programs are not affected. If it is not on this PC the setting reads as off and nothing happens. It cannot be switched back on from here; install it again from the Microsoft Store.' `
    -Parts @(
        pAppx 'Microsoft.ScreenSketch'
    )

Add-Tweak -Id 'apps-recorder' -Cat $cApps -Inv -Def 'On' -OneWay -Name 'Sound Recorder app' `
    -Desc 'On: the Sound Recorder app (Microsoft.WindowsSoundRecorder) is installed. Off: it is removed for all users. Recording in other programs is not affected. If it is not on this PC the setting reads as off and nothing happens. It cannot be switched back on from here; install it again from the Microsoft Store.' `
    -Parts @(
        pAppx 'Microsoft.WindowsSoundRecorder'
    )

Add-Tweak -Id 'apps-journal' -Cat $cApps -Inv -Def 'On' -OneWay -Name 'Journal app' `
    -Desc 'On: the Journal app (Microsoft.MicrosoftJournal, the pen and notebook app) is installed. Off: it is removed for all users. If it is not on this PC the setting reads as off and nothing happens. It cannot be switched back on from here; install it again from the Microsoft Store if you want it.' `
    -Parts @(
        pAppx 'Microsoft.MicrosoftJournal'
    )

Add-Tweak -Id 'store-policy' -Cat $cApps -Inv -Def 'On' -Name 'Store policy and install service' `
    -Desc 'On: the Microsoft Store and its Install Service work as Windows has them. Off: the "Turn off the Store application" policy is set and the Microsoft Store Install Service is disabled. Only Enterprise and Education editions honour the policy; on Home and Pro Windows ignores it, but the service part works on every edition and stops Store installs and updates. To make the Store app itself disappear, use "Microsoft Store app" above. Fully reversible.' `
    -Parts @(
        pEd 'Ent' (pReg 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' 'RemoveWindowsStore' 1)
        pSvc 'InstallService' 'Disabled' 'Manual'
    )

# --------------------------------------------------------------- Legacy --------
Add-Tweak -Id 'legacy' -Cat $cLegacy -Inv -Def 'On' -Reboot -Name 'Legacy features (IE mode, Fax and more)' `
    -Desc 'On: the four legacy components (Internet Explorer mode, Steps Recorder, Work Folders and Fax) are installed. Off: they are removed. Switching them back on adds them again from Windows Update (internet connection needed).' `
    -Parts @(
        pCap 'Browser.InternetExplorer*'
        pCap 'App.StepsRecorder*'
        pFeat 'WorkFolders-Client'
        pFeat 'FaxServicesClientPackage'
    )
# --------------------------------------------------------------- Testing -------
# Settings taken from other debloat scripts that have not been proven to matter for gaming. They live on their own page, are not part
# of the Recommended preset and are left out of "Apply all" and "Turn all on" on "All settings" (the Testing page's own buttons take them).
# Every scheduled task is its own card, so any one of them can be turned back on without touching the others. The untested services are on the
# Services page (marked -Untested).
Add-Tweak -Id 'mouse-keys' -Cat $cTest -Inv -Def 'On' -Preset -Name 'Mouse Keys shortcut' `
    -Desc 'On: pressing Left Alt, Left Shift and Num Lock together opens the "Do you want to turn on Mouse Keys?" window with beeps, which is easy to hit in a game. Off: that shortcut is turned off. Only the shortcut is affected; Mouse Keys itself is still there under Settings > Accessibility > Mouse. This one is saved for your account and Windows reads it when you sign in, so a change works from your next sign-in, not in the session that is open now.' `
    -Parts @(
        pReg 'HKCU:\Control Panel\Accessibility\MouseKeys' 'Flags' '186' '190' 'String'
    )

Add-Tweak -Id 'contrast-keys' -Cat $cTest -Inv -Def 'On' -Preset -Name 'High Contrast shortcut' `
    -Desc 'On: pressing Left Alt, Left Shift and Print Screen together opens the "Do you want to turn on High Contrast?" window. Off: that shortcut is turned off. Only the shortcut is affected; High Contrast themes are still there under Settings > Accessibility > Contrast themes. This one is saved for your account and Windows reads it when you sign in, so a change works from your next sign-in, not in the session that is open now.' `
    -Parts @(
        pReg 'HKCU:\Control Panel\Accessibility\HighContrast' 'Flags' '122' '126' 'String'
    )

Add-Tweak -Id 'audio-ducking' -Cat $cTest -Inv -Def 'On' -Name 'Windows volume ducking' `
    -Desc 'On: Windows turns other sounds down by 80% when it sees a call or voice chat start (the Windows default). That is Sound > Communications: reduce by 80%. Off: Sound > Communications is set to "Do nothing". A game keeps its full volume while you talk. It only matters for programs that tell Windows their stream is a call; for most game voice chat that is the case, and for the rest nothing changes. It takes effect the next time a program opens its audio.' `
    -Parts @(
        pReg 'HKCU:\Software\Microsoft\Multimedia\Audio' 'UserDuckingPreference' 3
    )

Add-Tweak -Id 'auto-maintenance' -Cat $cTest -Inv -Def 'On' -Risk 'note' -Name 'Automatic Maintenance' -NotRec 'Little to gain: maintenance only runs while the PC is idle, and turning it off stops updates, scans and clean-up.' `
    -Desc 'On: Windows Automatic Maintenance runs background tasks while the PC is idle. These are Store app updates, drive optimisation (TRIM on an SSD), Windows Security scans, system diagnostics and some clean-up. Off: those tasks do not start on their own schedule. You can still update from Windows Update and run Optimize Drives by hand. Windows can switch it back on after a large update, so look again after one.' `
    -Parts @(
        pReg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance' 'MaintenanceDisabled' 1
    )

$clsidCmdA = 'HKCU:\Software\Classes\CLSID\{2aa9162e-c906-4dd9-ad0b-3d24a8eef5a0}'
$clsidCmdB = 'HKCU:\Software\Classes\CLSID\{6480100b-5a83-4d1e-9f69-8ae5a88e9a33}'
Add-Tweak -Id 'classic-ribbon' -Cat $cTest -Def 'Off' -Explorer -Risk 'note' -Name 'Classic File Explorer toolbar' `
    -Desc 'On: tries to bring back the older File Explorer toolbar instead of the slim Windows 11 command bar (Copy, Paste, Sort, View). It switches off the two components that draw the new command bar, for your account, so File Explorer falls back to its older interface. Off: the Windows 11 command bar (the default). Microsoft does not document this and removed the real ribbon in Windows 11 22H2. Sources disagree on whether it still works: some say it does on 23H2 and newer, others that it no longer works on 24H2 and 25H2, and it has not been tried on build 26300. It may change nothing, or show an incomplete toolbar. File Explorer restarts when this is changed; if it still looks the same, sign out and in. It is on the Testing page for that reason.' `
    -Parts @(
        pKey "$clsidCmdA\InprocServer32" $clsidCmdA
        pKey "$clsidCmdB\InprocServer32" $clsidCmdB
    )

Add-Tweak -Id 'task-sqm' -Cat $cTest -Inv -Def 'On' -Name 'Scheduled task: Software Quality Metrics' `
    -Desc 'On: the scheduled task that gathers software-quality and reliability data for Microsoft is enabled. Off: the task is disabled. If this PC does not have the task the setting reads as not available.' `
    -Parts @(
        pTask '\Microsoft\Windows\PI\Sqm-Tasks'
    )

Add-Tweak -Id 'task-maps' -Cat $cTest -Inv -Def 'On' -Name 'Scheduled task: Maps update' `
    -Desc 'On: the task that downloads updates for offline maps used by the Maps app is enabled. Off: the task is disabled. It only matters if you use downloaded maps. If this PC does not have the task the setting reads as not available.' `
    -Parts @(
        pTask '\Microsoft\Windows\Maps\MapsUpdateTask'
    )

Add-Tweak -Id 'task-familysafety' -Cat $cTest -Inv -Def 'On' -Name 'Scheduled task: Family Safety monitor' `
    -Desc 'On: the Microsoft Family Safety task (parental controls and screen-time limits) is enabled. Off: the task is disabled. It only matters if this PC is used by a child account in a Microsoft family group. If this PC does not have the task the setting reads as not available.' `
    -Parts @(
        pTask '\Microsoft\Windows\Shell\FamilySafetyMonitor'
    )

Add-Tweak -Id 'task-powerdiag' -Cat $cTest -Inv -Def 'On' -Name 'Scheduled task: Power diagnostics' `
    -Desc 'On: the task that looks at how the PC uses power while it is idle, to feed the Windows power-efficiency diagnostics report, is enabled. Off: the task is disabled. Nothing else depends on it. If this PC does not have the task the setting reads as not available.' `
    -Parts @(
        pTask '\Microsoft\Windows\Power Efficiency Diagnostics\AnalyzeSystem'
    )

Add-Tweak -Id 'task-winsat' -Cat $cTest -Inv -Def 'On' -Name 'Scheduled task: WinSAT benchmark' `
    -Desc 'On: the task that runs the Windows System Assessment Tool (WinSAT) in the background during automatic maintenance, to refresh the Windows performance score, is enabled. Off: the task is disabled, so no benchmark runs while the PC is idle. The score stays as last measured, and a few old programs read it. If this PC does not have the task the setting reads as not available.' `
    -Parts @(
        pTask '\Microsoft\Windows\Maintenance\WinSAT'
    )

Add-Tweak -Id 'task-pca' -Cat $cTest -Inv -Def 'On' -Name 'Scheduled task: Compatibility Assistant' `
    -Desc 'On: the Program Compatibility Assistant task (PcaPatchDbTask) that keeps its list of known program-compatibility fixes up to date is enabled. Off: the task is disabled. The list stays as it is; the "this program might not have installed correctly" prompts for old software can then be out of date. If this PC does not have the task the setting reads as not available.' `
    -Parts @(
        pTask '\Microsoft\Windows\Application Experience\PcaPatchDbTask'
    )

Add-Tweak -Id 'task-dusm' -Cat $cTest -Inv -Def 'On' -Name 'Scheduled task: Data usage' `
    -Desc 'On: the Data Usage task (DUSM), which belongs with the data usage meter shown in Settings > Network & internet > Data usage, is enabled. Off: the task is disabled. "Data usage meter service" under Services is a separate setting. If this PC does not have the task the setting reads as not available.' `
    -Parts @(
        pTask '\Microsoft\Windows\DUSM\dusmtask'
    )

Add-Tweak -Id 'task-xblsave' -Cat $cTest -Inv -Def 'On' -Risk 'note' -Name 'Scheduled task: Xbox game save sync' `
    -Desc 'On: the two Xbox game save tasks (XblGameSaveTask and XblGameSaveTaskLogon) that help sync cloud saves of Game Pass and Microsoft Store games are enabled. Off: both tasks are disabled, so those saves may not sync until you start the game or the Xbox app. Steam, Epic and GOG saves are not affected. If this PC does not have the tasks the setting reads as not available.' `
    -Parts @(
        pTask '\Microsoft\XblGameSave\XblGameSaveTask'
        pTask '\Microsoft\XblGameSave\XblGameSaveTaskLogon'
    )

Add-Tweak -Id 'task-officetelemetry' -Cat $cTest -Inv -Def 'On' -Name 'Scheduled task: Office telemetry' `
    -Desc 'On: the four Office telemetry agent tasks (OfficeTelemetryAgentLogOn and OfficeTelemetryAgentFallBack, each with a 2016 version) that collect and upload Office usage data are enabled. Off: all four are disabled. Office itself keeps working. A PC without Microsoft Office does not have the tasks; the setting then reads as not available.' `
    -Parts @(
        pTask '\Microsoft\Office\OfficeTelemetryAgentFallBack'
        pTask '\Microsoft\Office\OfficeTelemetryAgentFallBack2016'
        pTask '\Microsoft\Office\OfficeTelemetryAgentLogOn'
        pTask '\Microsoft\Office\OfficeTelemetryAgentLogOn2016'
    )
}   # ---- end of $engine ----

# =============================================================================
# SYSTEM INFORMATION (read only): what the Home page and the Display page show.
# Nothing here changes a setting or installs anything: it only looks.
#
# Where each number comes from:
#   Windows version, CPU / RAM / board names   Windows' own WMI (CIM) and the registry
#   CPU usage, clock, processes, memory used   Windows performance counters
#   GPU temperature, power, clock, memory      nvidia-smi (installed with the NVIDIA driver), when there is one
#   Drive model, size, health, temperature     Windows' storage service (Get-PhysicalDisk, Get-StorageReliabilityCounter): no driver needed
#   CPU temperature, CPU power, RAM timings    Windows does not report these. They are read from HWiNFO (its shared memory, or
#                                              failing that its "Gadget" registry export) or LibreHardwareMonitor /
#                                              OpenHardwareMonitor (their WMI provider), but only while one of those programs is
#                                              running; otherwise the page says so.
#   Resolution, refresh rate, HDR              the display driver (EnumDisplaySettings, QueryDisplayConfig)
#   Timer resolution                           NtQueryTimerResolution (it only asks what the tick is; it never sets one)
#   HPET, TSC, ACPI timer, boot timer options  the device list (Win32_PnPEntity), "bcdedit /enum {current}" (it only lists) and how long
#                                              one read of the performance counter takes
#   VBS, memory integrity (HVCI)               Windows' own report, Win32_DeviceGuard (it only reports)
#   IOMMU                                      the list of the firmware's ACPI tables (EnumSystemFirmwareTables: it only lists them)
#   Mouse: pointer precision and speed         the registry (HKCU\Control Panel\Mouse), only read
#   USB selective suspend                      "powercfg /q" for the power plan in use (it only shows the setting)
#
# Everything lives in $sysEngine so the same text can run in a background worker and in the tests.
# C# note: the helper classes are compiled by Windows PowerShell 5.1 (C# 5), so no newer syntax is used in them.
# Names to avoid for local variables here (the engine uses them as shared names): $log $DryRun $StorePath $Q
# =============================================================================
$SysShared = $null    # the shared state of the background reader (its host sets it; the code below reads and writes its fields)
$sysEngine = {

$script:SysSrcDisp = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class SysDisp
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    public struct DEVMODE
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion;
        public short dmDriverVersion;
        public short dmSize;
        public short dmDriverExtra;
        public int dmFields;
        public int dmPositionX;
        public int dmPositionY;
        public int dmDisplayOrientation;
        public int dmDisplayFixedOutput;
        public short dmColor;
        public short dmDuplex;
        public short dmYResolution;
        public short dmTTOption;
        public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel;
        public int dmPelsWidth;
        public int dmPelsHeight;
        public int dmDisplayFlags;
        public int dmDisplayFrequency;
        public int dmICMMethod;
        public int dmICMIntent;
        public int dmMediaType;
        public int dmDitherType;
        public int dmReserved1;
        public int dmReserved2;
        public int dmPanningWidth;
        public int dmPanningHeight;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    public struct DISPLAY_DEVICE
    {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }

    [DllImport("user32.dll", CharSet = CharSet.Ansi)]
    static extern bool EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE devMode);
    [DllImport("user32.dll", CharSet = CharSet.Ansi)]
    static extern bool EnumDisplayDevices(string device, uint devNum, ref DISPLAY_DEVICE dd, uint flags);

    static DEVMODE NewMode()
    {
        DEVMODE d = new DEVMODE();
        d.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        return d;
    }

    // "device name|1 if primary|monitor id|monitor name", one per screen that is part of the desktop
    public static string[] Screens()
    {
        List<string> res = new List<string>();
        for (uint i = 0; i < 16; i++)
        {
            DISPLAY_DEVICE dd = new DISPLAY_DEVICE();
            dd.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
            if (!EnumDisplayDevices(null, i, ref dd, 0)) { break; }
            if ((dd.StateFlags & 1) == 0) { continue; }
            string mon = "";
            string monName = "";
            DISPLAY_DEVICE md = new DISPLAY_DEVICE();
            md.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
            if (EnumDisplayDevices(dd.DeviceName, 0, ref md, 0)) { mon = md.DeviceID; monName = md.DeviceString; }
            res.Add(dd.DeviceName + "|" + (((dd.StateFlags & 4) != 0) ? "1" : "0") + "|" + mon + "|" + monName);
        }
        return res.ToArray();
    }

    // "width|height|hertz|bits per pixel" of the mode in use now, or "" when it cannot be read
    public static string Current(string device)
    {
        DEVMODE m = NewMode();
        if (!EnumDisplaySettings(device, -1, ref m)) { return ""; }
        return m.dmPelsWidth + "|" + m.dmPelsHeight + "|" + m.dmDisplayFrequency + "|" + m.dmBitsPerPel;
    }

    // "width|height|hertz" for every mode the screen offers (each combination once)
    public static string[] Modes(string device)
    {
        List<string> res = new List<string>();
        HashSet<string> seen = new HashSet<string>();
        for (int i = 0; i < 20000; i++)
        {
            DEVMODE m = NewMode();
            if (!EnumDisplaySettings(device, i, ref m)) { break; }
            string k = m.dmPelsWidth + "|" + m.dmPelsHeight + "|" + m.dmDisplayFrequency;
            if (seen.Add(k)) { res.Add(k); }
        }
        return res.ToArray();
    }
}
'@

# HDR ("advanced colour") and the exact refresh rate of each active screen. The structures are read from plain memory by offset
# (a path is 72 bytes, a packet 20 bytes of header plus its data), so nothing depends on how a struct is laid out in C#.
$script:SysSrcColor = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class SysColor
{
    [DllImport("user32.dll")]
    static extern int GetDisplayConfigBufferSizes(uint flags, out uint numPaths, out uint numModes);
    [DllImport("user32.dll")]
    static extern int QueryDisplayConfig(uint flags, ref uint numPaths, IntPtr paths, ref uint numModes, IntPtr modes, IntPtr topology);
    [DllImport("user32.dll")]
    static extern int DisplayConfigGetDeviceInfo(IntPtr packet);

    // one line per active screen: "GDI name|colour supported|colour enabled|wide colour only|bits per channel|refresh numerator|refresh denominator"
    public static string[] Query()
    {
        List<string> res = new List<string>();
        uint np;
        uint nm;
        if (GetDisplayConfigBufferSizes(2, out np, out nm) != 0 || np == 0) { return res.ToArray(); }
        IntPtr paths = Marshal.AllocHGlobal((int)(np * 144));
        IntPtr modes = Marshal.AllocHGlobal((int)((nm + 1) * 128));
        IntPtr pkt = Marshal.AllocHGlobal(256);
        try
        {
            if (QueryDisplayConfig(2, ref np, paths, ref nm, modes, IntPtr.Zero) != 0) { return res.ToArray(); }
            for (int i = 0; i < (int)np; i++)
            {
                int p = i * 72;
                for (int b = 0; b < 256; b += 4) { Marshal.WriteInt32(pkt, b, 0); }
                Marshal.WriteInt32(pkt, 0, 1);                                  // the name of the screen (source) this path starts at
                Marshal.WriteInt32(pkt, 4, 84);
                Marshal.WriteInt32(pkt, 8, Marshal.ReadInt32(paths, p));
                Marshal.WriteInt32(pkt, 12, Marshal.ReadInt32(paths, p + 4));
                Marshal.WriteInt32(pkt, 16, Marshal.ReadInt32(paths, p + 8));
                string name = "";
                if (DisplayConfigGetDeviceInfo(pkt) == 0)
                {
                    name = Marshal.PtrToStringUni(new IntPtr(pkt.ToInt64() + 20), 32);
                    int z = name.IndexOf('\0');
                    if (z >= 0) { name = name.Substring(0, z); }
                }
                for (int b = 0; b < 256; b += 4) { Marshal.WriteInt32(pkt, b, 0); }
                Marshal.WriteInt32(pkt, 0, 9);                                  // advanced colour information of the monitor (target)
                Marshal.WriteInt32(pkt, 4, 32);
                Marshal.WriteInt32(pkt, 8, Marshal.ReadInt32(paths, p + 20));
                Marshal.WriteInt32(pkt, 12, Marshal.ReadInt32(paths, p + 24));
                Marshal.WriteInt32(pkt, 16, Marshal.ReadInt32(paths, p + 28));
                int sup = 0; int en = 0; int wide = 0; int bits = 0;
                if (DisplayConfigGetDeviceInfo(pkt) == 0)
                {
                    int v = Marshal.ReadInt32(pkt, 20);
                    sup = v & 1;
                    en = (v >> 1) & 1;
                    wide = (v >> 2) & 1;
                    bits = Marshal.ReadInt32(pkt, 28);
                }
                uint num = (uint)Marshal.ReadInt32(paths, p + 48);
                uint den = (uint)Marshal.ReadInt32(paths, p + 52);
                res.Add(name + "|" + sup + "|" + en + "|" + wide + "|" + bits + "|" + num + "|" + den);
            }
        }
        finally
        {
            Marshal.FreeHGlobal(paths);
            Marshal.FreeHGlobal(modes);
            Marshal.FreeHGlobal(pkt);
        }
        return res.ToArray();
    }
}
'@

# The tick of Windows' clock, and how long a read of the performance counter takes. Both only look: NtQueryTimerResolution reports the tick
# (it is not the call that sets one), and Stopwatch.GetTimestamp reads the counter.
$script:SysSrcClock = @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

public static class SysClock
{
    [DllImport("ntdll.dll")]
    static extern int NtQueryTimerResolution(out uint maximum, out uint minimum, out uint current);

    // "coarsest|finest|current" in units of 100 ns, or "" when Windows does not answer. The coarsest tick is the default (156250 = 15.625 ms),
    // the finest is the shortest this PC allows (often 5000 = 0.5 ms) and the current one is the tick in use now.
    public static string Timer()
    {
        uint mx = 0;
        uint mn = 0;
        uint cur = 0;
        if (NtQueryTimerResolution(out mx, out mn, out cur) != 0) { return ""; }
        return mx + "|" + mn + "|" + cur;
    }

    // How long one read of the performance counter takes, in nanoseconds: the fastest of five short runs, so that a busy moment does not count
    public static double CounterCostNs()
    {
        const int N = 20000;
        double best = -1;
        for (int run = 0; run < 5; run++)
        {
            long t0 = Stopwatch.GetTimestamp();
            for (int i = 0; i < N; i++) { Stopwatch.GetTimestamp(); }
            long t1 = Stopwatch.GetTimestamp();
            double ns = (double)(t1 - t0) * 1000000000.0 / (double)Stopwatch.Frequency / (double)N;
            if (best < 0 || ns < best) { best = ns; }
        }
        return best;
    }
}
'@

# The signatures of the firmware's ACPI tables. It only lists them: EnumSystemFirmwareTables reads the list Windows already has and
# changes nothing. The IOMMU is described to Windows by one of them: IVRS on AMD (AMD-Vi), DMAR on Intel (VT-d).
$script:SysSrcFw = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class SysFw
{
    [DllImport("kernel32.dll")]
    static extern uint EnumSystemFirmwareTables(uint provider, byte[] buffer, uint size);

    // "APIC,FACP,IVRS,..." (four letters each), or "" when Windows does not answer
    public static string AcpiTables()
    {
        const uint ACPI = 0x41435049;
        uint need = EnumSystemFirmwareTables(ACPI, null, 0);
        if (need == 0 || need > 65536) { return ""; }
        byte[] buf = new byte[need];
        uint got = EnumSystemFirmwareTables(ACPI, buf, need);
        if (got == 0 || got > need) { return ""; }
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i + 4 <= (int)got; i += 4)
        {
            if (sb.Length > 0) { sb.Append(","); }
            sb.Append(Encoding.ASCII.GetString(buf, i, 4));
        }
        return sb.ToString();
    }
}
'@

# Returns '' when the helper is ready, otherwise the reason it could not be built.
function Sys-Ensure {
    param([string]$Which)
    $type = 'SysDisp'; $src = $script:SysSrcDisp
    if ($Which -eq 'Color') { $type = 'SysColor'; $src = $script:SysSrcColor }
    elseif ($Which -eq 'Clock') { $type = 'SysClock'; $src = $script:SysSrcClock }
    elseif ($Which -eq 'Fw') { $type = 'SysFw'; $src = $script:SysSrcFw }
    if ($type -as [type]) { return '' }
    try {
        Add-Type -TypeDefinition $src -Language CSharp -ErrorAction Stop
        return ''
    } catch {
        return [string]$_.Exception.Message
    }
}

# ------------------------------------------------------------------ small helpers ----
# A number out of a text: '12.5', '4,198 MHz', '52,5' (decimal comma, when $Raw says the text is an unformatted number),
# '[N/A]' and '' give $null
function Sys-Num {
    param($v, [switch]$Raw)
    if ($null -eq $v) { return $null }
    $s = ([string]$v).Trim()
    if (-not $s) { return $null }
    if ($s -match '^\[?\s*(N/A|Not Supported|Unknown Error|Not Available)\s*\]?$') { return $null }
    $m = [regex]::Match($s, '^-?[\d.,]*\d')
    if (-not $m.Success) { return $null }
    $t = $m.Value
    if ($t.Contains(',') -and $t.Contains('.')) { $t = $t.Replace(',', '') }
    elseif ($t.Contains(',')) { if ($Raw) { $t = $t.Replace(',', '.') } else { $t = $t.Replace(',', '') } }
    $d = 0.0
    if ([double]::TryParse($t, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
    return $null
}

function Sys-RegGet {
    param([string]$Hive, [string]$Sub, [string]$Name)
    $root = $null
    try {
        if ($Hive -eq 'HKCU') { $root = [Microsoft.Win32.Registry]::CurrentUser } else { $root = [Microsoft.Win32.Registry]::LocalMachine }
        $k = $root.OpenSubKey($Sub)
        if (-not $k) { return $null }
        try { return $k.GetValue($Name, $null) } finally { $k.Close() }
    } catch { return $null }
}
# every value of a key as name -> value; $null when the key is not there
function Sys-RegAll {
    param([string]$Hive, [string]$Sub)
    try {
        if ($Hive -eq 'HKCU') { $root = [Microsoft.Win32.Registry]::CurrentUser } else { $root = [Microsoft.Win32.Registry]::LocalMachine }
        $k = $root.OpenSubKey($Sub)
        if (-not $k) { return $null }
        try {
            $h = @{}
            foreach ($n in $k.GetValueNames()) { if ($n) { $h[[string]$n] = $k.GetValue($n, $null) } }
            return $h
        } finally { $k.Close() }
    } catch { return $null }
}
function Sys-RegSubKeys {
    param([string]$Hive, [string]$Sub)
    try {
        if ($Hive -eq 'HKCU') { $root = [Microsoft.Win32.Registry]::CurrentUser } else { $root = [Microsoft.Win32.Registry]::LocalMachine }
        $k = $root.OpenSubKey($Sub)
        if (-not $k) { return @() }
        try { return @($k.GetSubKeyNames()) } finally { $k.Close() }
    } catch { return @() }
}

function Sys-ProcRunning {
    param([string[]]$Names)
    foreach ($n in $Names) {
        try { if (@([System.Diagnostics.Process]::GetProcessesByName($n)).Count -gt 0) { return $true } } catch { }
    }
    return $false
}

# Runs a program and returns what it printed, or $null when it failed or took longer than $TimeoutMs
function Sys-RunTool {
    param([string]$Exe, [string]$ToolArgs, [int]$TimeoutMs = 4000)
    $p = $null
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Exe
        $psi.Arguments = $ToolArgs
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        [void]$p.Start()
        $task = $p.StandardOutput.ReadToEndAsync()
        $err = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutMs)) { try { $p.Kill() } catch { }; return $null }
        [void]$task.Wait(2000)
        return [string]$task.Result
    } catch {
        return $null
    } finally {
        if ($p) { try { $p.Dispose() } catch { } }
    }
}

# A CIM date (or text) as a date, $null when it is none
function Sys-Date {
    param($v)
    if ($null -eq $v) { return $null }
    if ($v -is [datetime]) { if ($v.Year -lt 1990) { return $null }; return $v }
    $s = ([string]$v).Trim()
    if (-not $s) { return $null }
    if ($s -match '^\d{14}\.\d+[+-]\d+$') {
        try { return [Management.ManagementDateTimeConverter]::ToDateTime($s) } catch { return $null }
    }
    if ($s -match '^\d{10}$') { return ([datetime]'1970-01-01').AddSeconds([double]$s) }
    if ($s -match '^\d{13}$') { return ([datetime]'1970-01-01').AddMilliseconds([double]$s) }
    $d = [datetime]::MinValue
    if ([datetime]::TryParse($s, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeLocal, [ref]$d)) { if ($d.Year -ge 1990) { return $d } }
    return $null
}

# ----------------------------------------------------------------- the PC, once ----
# "Microsoft Windows 11 Pro" / "Windows 10 Pro" with a Windows 11 build number -> "Windows 11 Pro"
function Sys-OsName {
    param([string]$Caption, [string]$Build, [string]$Product)
    $c = ([string]$Caption).Trim()
    if ($c.StartsWith('Microsoft ')) { $c = $c.Substring(10).Trim() }
    $b = 0; [void][int]::TryParse([string]$Build, [ref]$b)
    if (-not $c) { $c = ([string]$Product).Trim() }
    if ($b -ge 22000 -and $c -match '^Windows 10') { $c = 'Windows 11' + $c.Substring(10) }
    if (-not $c) { $c = 'Windows' }
    return $c
}
# the vendor name as people write it
function Sys-Vendor {
    param([string]$Text)
    $t = [string]$Text
    if ($t -match 'AuthenticAMD|Advanced Micro Devices|\bAMD\b') { return 'AMD' }
    if ($t -match 'GenuineIntel|Intel') { return 'Intel' }
    if ($t -match 'NVIDIA') { return 'NVIDIA' }
    return ''
}

function Get-SysOs {
    $o = @{ Name = ''; Edition = ''; Display = ''; Build = ''; Ubr = ''; Full = ''; Arch = ''; Installed = $null; Boot = $null; TotalMB = 0 }
    $cv = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $caption = ''
    try {
        $c = @(Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop)[0]
        $caption = [string]$c.Caption
        $o.Arch = [string]$c.OSArchitecture
        $o.Installed = Sys-Date $c.InstallDate
        $o.Boot = Sys-Date $c.LastBootUpTime
        $o.TotalMB = [int]([double]$c.TotalVisibleMemorySize / 1024)
        $o.Build = [string]$c.BuildNumber
    } catch { }
    $b = [string](Sys-RegGet 'HKLM' $cv 'CurrentBuild')
    if (-not $b) { $b = [string](Sys-RegGet 'HKLM' $cv 'CurrentBuildNumber') }
    if ($b) { $o.Build = $b }
    $o.Ubr = [string](Sys-RegGet 'HKLM' $cv 'UBR')
    $dv = [string](Sys-RegGet 'HKLM' $cv 'DisplayVersion')
    if (-not $dv) { $dv = [string](Sys-RegGet 'HKLM' $cv 'ReleaseId') }
    $o.Display = $dv
    $o.Edition = [string](Sys-RegGet 'HKLM' $cv 'EditionID')
    $o.Name = Sys-OsName $caption $o.Build ([string](Sys-RegGet 'HKLM' $cv 'ProductName'))
    if ($o.Build) { $o.Full = $o.Build; if ($o.Ubr) { $o.Full = $o.Build + '.' + $o.Ubr } }
    return $o
}

function Get-SysCpu {
    $o = @{ Name = ''; Vendor = ''; Cores = 0; Threads = 0; BaseMHz = 0; L3MB = 0 }
    try {
        $c = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)[0]
        $o.Name = ([regex]::Replace([string]$c.Name, '\s+', ' ')).Trim()
        $o.Vendor = Sys-Vendor ([string]$c.Manufacturer + ' ' + [string]$c.Name)
        $o.Cores = [int]$c.NumberOfCores
        $o.Threads = [int]$c.NumberOfLogicalProcessors
        $o.BaseMHz = [int]$c.MaxClockSpeed
        $o.L3MB = [int]([double]$c.L3CacheSize / 1024)
    } catch { }
    return $o
}

# The graphics card shown on the page: an NVIDIA card first, then any other that is not the basic one built into the processor
function Sys-PickGpu {
    param($Names)
    $list = @($Names | Where-Object { $_ })
    foreach ($n in $list) { if ($n -match 'NVIDIA|GeForce|RTX|GTX|Quadro') { return [string]$n } }
    foreach ($n in $list) { if ($n -match 'Radeon (RX|PRO)|Arc\b|Intel.*Arc') { return [string]$n } }
    foreach ($n in $list) { if ($n -notmatch 'Basic|Remote|Virtual|Microsoft') { return [string]$n } }
    if ($list.Count) { return [string]$list[0] }
    return ''
}
function Get-SysGpu {
    $o = @{ Name = ''; Vendor = ''; Driver = ''; VramMB = 0; Others = @(); Bar1MB = $null }
    try {
        $v = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop)
        $names = @($v | ForEach-Object { ([string]$_.Name).Trim() } | Where-Object { $_ })
        $o.Name = Sys-PickGpu $names
        $o.Others = @($names | Where-Object { $_ -ne $o.Name })
        $o.Vendor = Sys-Vendor $o.Name
        foreach ($x in $v) {
            if (([string]$x.Name).Trim() -eq $o.Name) {
                $o.Driver = [string]$x.DriverVersion
                $o.VramMB = [int]([double]$x.AdapterRAM / 1MB)       # a 32-bit number: at most 4 GB, so the real size is read below
            }
        }
    } catch { }
    # the real video memory: the driver writes it as a 64-bit number under the display adapter class
    try {
        $cls = 'SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
        foreach ($k in (Sys-RegSubKeys 'HKLM' $cls)) {
            if ($k -notmatch '^\d{4}$') { continue }
            $desc = [string](Sys-RegGet 'HKLM' ($cls + '\' + $k) 'DriverDesc')
            if ($desc.Trim() -ne $o.Name) { continue }
            $q = Sys-RegGet 'HKLM' ($cls + '\' + $k) 'HardwareInformation.qwMemorySize'
            # a 64-bit number on most PCs, 8 bytes of plain data on some
            if ($q -is [array] -and @($q).Count -eq 8) { $q = [BitConverter]::ToInt64([byte[]]@($q), 0) }
            if ($null -ne $q -and [double]$q -gt 0) { $o.VramMB = [int]([double]$q / 1MB); break }
        }
    } catch { }
    # Resizable BAR is read from nvidia-smi (BAR1 size); other makers' cards are not read
    if ($o.Vendor -eq 'NVIDIA') { try { $o.Bar1MB = Sys-Bar1MB } catch { } }
    return $o
}

# DDR type from the SMBIOS memory type code
function Sys-RamType {
    param([int]$Code)
    switch ($Code) { 34 { return 'DDR5' } 26 { return 'DDR4' } 24 { return 'DDR3' } 35 { return 'LPDDR5' } 29 { return 'LPDDR3' } 30 { return 'LPDDR4' } }
    return ''
}
# Win32_PhysicalMemory passes on what the memory's SMBIOS entry says, and a few firmware versions write the clock (half the transfer rate)
# instead of the rate. DDR5 does not exist below 3200 MT/s nor DDR4 below 1600, so a lower number is a clock and is doubled.
function Sys-FixMT {
    param([string]$Type, [int]$MT)
    if ($MT -le 0) { return $MT }
    if ($Type -eq 'DDR5' -and $MT -lt 3200) { return ($MT * 2) }
    if ($Type -eq 'DDR4' -and $MT -lt 1600) { return ($MT * 2) }
    return $MT
}
function Get-SysRam {
    $o = @{ TotalGB = 0.0; Type = ''; Modules = @(); SpeedMT = 0; RatedMT = 0 }
    try {
        $m = @(Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction Stop)
        $bytes = 0.0
        $mods = @()
        foreach ($x in $m) {
            $bytes += [double]$x.Capacity
            $ty = Sys-RamType ([int]$x.SMBIOSMemoryType)
            $mods += ,@{ Slot = ([string]$x.DeviceLocator).Trim(); GB = [Math]::Round([double]$x.Capacity / 1GB, 0); Maker = ([string]$x.Manufacturer).Trim()
                         Part = ([string]$x.PartNumber).Trim(); RatedMT = (Sys-FixMT $ty ([int]$x.Speed)); MT = (Sys-FixMT $ty ([int]$x.ConfiguredClockSpeed)); Type = $ty }
        }
        $o.Modules = $mods
        $o.TotalGB = [Math]::Round($bytes / 1GB, 0)
        if ($mods.Count) {
            $o.Type = [string]$mods[0].Type
            $o.SpeedMT = [int](($mods | ForEach-Object { [int]$_.MT } | Measure-Object -Maximum).Maximum)
            $o.RatedMT = [int](($mods | ForEach-Object { [int]$_.RatedMT } | Measure-Object -Maximum).Maximum)
        }
    } catch { }
    return $o
}

function Get-SysBoard {
    $o = @{ Maker = ''; Product = ''; Version = ''; Model = ''; BiosVendor = ''; BiosVersion = ''; BiosDate = $null }
    try {
        $b = @(Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction Stop)[0]
        $o.Maker = ([string]$b.Manufacturer).Trim()
        $o.Product = ([string]$b.Product).Trim()
        $o.Version = ([string]$b.Version).Trim()
    } catch { }
    try {
        $s = @(Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop)[0]
        $o.Model = ([string]$s.Model).Trim()
    } catch { }
    try {
        $bios = @(Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop)[0]
        $o.BiosVendor = ([string]$bios.Manufacturer).Trim()
        $o.BiosVersion = ([string]$bios.SMBIOSBIOSVersion).Trim()
        $o.BiosDate = Sys-Date $bios.ReleaseDate
    } catch { }
    return $o
}

function Get-SysStatic {
    $s = @{ Os = $null; Cpu = $null; Gpu = $null; Ram = $null; Board = $null; Storage = $null; At = (Get-Date) }
    try { $s.Os = Get-SysOs } catch { }
    try { $s.Cpu = Get-SysCpu } catch { }
    try { $s.Gpu = Get-SysGpu } catch { }
    try { $s.Ram = Get-SysRam } catch { }
    try { $s.Board = Get-SysBoard } catch { }
    try { $s.Storage = @(Get-SysStorage) } catch { }
    return $s
}

# ------------------------------------------------- the clock and the timer (read only) ----
# Nothing here sets a timer, changes a boot option or switches a device. Four things are read:
#   the timer resolution    how often Windows' system clock ticks right now. A program can ask for a finer tick and Windows then runs at the
#                           finest one asked for. NtQueryTimerResolution only reports it: 156250 (15.625 ms) is the default tick.
#   the boot timer options  "bcdedit /enum {current}" prints the boot entry; the lines of the timer options are picked out of it. (It only
#                           lists: the other forms of bcdedit, which change the entry, are never used.)
#   the HPET device         Windows' device list (Win32_PnPEntity). ACPI\PNP0103 is the ID of the HPET (high precision event timer).
#   the cost of a read      how long one read of the performance counter takes. Windows picks the clock behind QueryPerformanceCounter when
#                           it starts: a read of the CPU's own counter (the TSC) takes some 20 nanoseconds, a read of the HPET or the ACPI
#                           power management timer goes through the kernel and takes far longer (hundreds to thousands).

# "156250|5000|10000" (100 ns units: coarsest, finest, current) -> milliseconds. $null for anything that is not a plausible answer.
function Sys-TimerParse {
    param([string]$Text)
    $p = @(([string]$Text).Trim() -split '\|')
    if ($p.Count -ne 3) { return $null }
    $v = @()
    foreach ($x in $p) {
        $n = 0.0
        if (-not [double]::TryParse($x, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) { return $null }
        if ($n -le 0 -or $n -gt 1000000) { return $null }          # 100 ms and more is not a tick of any real PC
        $v += $n
    }
    if ($v[1] -gt $v[0]) { return $null }                           # the finest tick cannot be coarser than the coarsest
    return @{ CoarsestMs = ($v[0] / 10000.0); FinestMs = ($v[1] / 10000.0); CurrentMs = ($v[2] / 10000.0) }
}
# The helper is built once; when it cannot be built (the compiler is not there) this says so at once afterwards instead of trying again every pass
$script:SysClockBroken = $false
function Sys-TimerRead {
    if ($script:SysClockBroken) { return $null }
    if ((Sys-Ensure 'Clock') -ne '') { $script:SysClockBroken = $true; return $null }
    try { return (Sys-TimerParse ([string][SysClock]::Timer())) } catch { return $null }
}

# The timer options out of the text "bcdedit /enum {current}" prints. Read = $true when the text is a boot entry (an error message or nothing
# is not). Opts = option name (lower case) -> the text after it, only for the options that are set in the entry.
function Sys-ParseBcd {
    param([string]$Text)
    $o = @{ Read = $false; Opts = @{} }
    $t = [string]$Text
    if (-not $t) { return $o }
    if ($t -notmatch '(?im)^\s*identifier\s+\S') { return $o }
    $o.Read = $true
    foreach ($line in ($t -split "`r?`n")) {
        $m = [regex]::Match($line, '^\s*(useplatformclock|useplatformtick|disabledynamictick|tscsyncpolicy)\s+(\S.*?)\s*$', 'IgnoreCase')
        if ($m.Success) { $o.Opts[$m.Groups[1].Value.ToLowerInvariant()] = $m.Groups[2].Value }
    }
    return $o
}
function Get-SysBcd {
    $o = $null
    try {
        $exe = "$env:SystemRoot\System32\bcdedit.exe"
        $txt = Sys-RunTool $exe '/enum {current}' 6000
        $o = Sys-ParseBcd ([string]$txt)
    } catch { }
    if (-not $o) { $o = @{ Read = $false; Opts = @{} } }
    return $o
}

# The HPET as Windows lists it. Read = the list could be asked; Present = the firmware offers an HPET and Windows has it; Disabled = it is
# switched off in Device Manager (problem code 22). A device that is not there any more (code 45, or Present = false) does not count.
function Get-SysHpet {
    $o = @{ Read = $false; Present = $false; Disabled = $false }
    $d = @(Get-CimInstance -ClassName Win32_PnPEntity -Filter "PNPDeviceID LIKE 'ACPI\\PNP0103%'" -ErrorAction Stop)
    $o.Read = $true
    foreach ($x in $d) {
        $code = 0
        try { $code = [int]$x.ConfigManagerErrorCode } catch { }
        if ($code -eq 45) { continue }
        if ($null -ne $x.Present -and -not [bool]$x.Present) { continue }
        $o.Present = $true
        $o.Disabled = ($code -eq 22)
        break
    }
    return $o
}

# Everything about the clock that does not change while Windows runs, read once: the speed of the performance counter (Hz), how long one read
# of it takes (CostNs), the boot timer options (Bcd) and the HPET device (Hpet, $null when the list could not be asked).
function Get-SysClock {
    $o = @{ Hz = $null; CostNs = $null; Bcd = $null; Hpet = $null }
    try { $o.Hz = [double][System.Diagnostics.Stopwatch]::Frequency } catch { }
    if ((Sys-Ensure 'Clock') -eq '') { try { $o.CostNs = [double][SysClock]::CounterCostNs() } catch { } }
    try { $o.Bcd = Get-SysBcd } catch { }
    try { $o.Hpet = Get-SysHpet } catch { }
    return $o
}

# ------------------------------------------------- the protections: VBS, memory integrity, IOMMU (read only) ----
# Nothing here switches a protection on or off. Two things are read, once:
#   Win32_DeviceGuard       Windows' own report of virtualization-based security (root\Microsoft\Windows\DeviceGuard). The numbers are the
#                           ones Microsoft documents: VirtualizationBasedSecurityStatus 0 = off, 1 = turned on but not running, 2 = running;
#                           in SecurityServicesConfigured / SecurityServicesRunning 2 is memory integrity (HVCI); in AvailableSecurityProperties
#                           3 is DMA protection.
#   the ACPI table list     the IOMMU is described to Windows by the firmware's IVRS table (AMD-Vi) or DMAR table (Intel VT-d). Without one
#                           of them Windows has no IOMMU to use.
function Get-SysDeviceGuard {
    $o = @{ Read = $false; Vbs = $null; Configured = @(); Running = @(); Available = @() }
    $d = @(Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop)
    if ($d.Count -lt 1 -or $null -eq $d[0]) { return $o }
    $x = $d[0]
    $o.Read = $true
    try { if ($null -ne $x.VirtualizationBasedSecurityStatus) { $o.Vbs = [int]$x.VirtualizationBasedSecurityStatus } } catch { }
    foreach ($p in @(@('Configured', 'SecurityServicesConfigured'), @('Running', 'SecurityServicesRunning'), @('Available', 'AvailableSecurityProperties'))) {
        $v = @()
        try { $v = @(@($x.($p[1])) | Where-Object { $null -ne $_ } | ForEach-Object { [int]$_ }) } catch { }
        $o[$p[0]] = $v
    }
    return $o
}
# The ACPI table list ("APIC,FACP,IVRS,...") -> the IOMMU: Read = the list could be had; Kind = 'AMD-Vi' (IVRS), 'VT-d' (DMAR) or '' (none).
# A name that is not four plain letters (some firmware has a table with an odd name) is skipped, not the whole list. The list counts as read
# when it has the two tables every ACPI PC has (FACP and APIC); without them it is not a table list at all.
function Sys-IommuParse {
    param([string]$Text)
    $o = @{ Read = $false; Kind = '' }
    $t = ([string]$Text).Trim()
    if (-not $t) { return $o }
    $names = @($t -split ',' | Where-Object { $_ -match '^[ -~]{4}$' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (-not ($names -contains 'FACP' -and $names -contains 'APIC')) { return $o }
    $o.Read = $true
    if ($names -contains 'IVRS') { $o.Kind = 'AMD-Vi' } elseif ($names -contains 'DMAR') { $o.Kind = 'VT-d' }
    return $o
}
function Get-SysIommu {
    if ((Sys-Ensure 'Fw') -ne '') { return @{ Read = $false; Kind = '' } }
    $t = ''
    try { $t = [string][SysFw]::AcpiTables() } catch { $t = '' }
    return (Sys-IommuParse $t)
}
# Secure Boot (read only): at every start Windows writes down what the firmware reported, under
# HKLM\SYSTEM\CurrentControlSet\Control\SecureBoot\State (UEFISecureBootEnabled: 1 = on, 0 = off). That key is only there on a PC that
# started in UEFI mode; PEFirmwareType under HKLM\SYSTEM\CurrentControlSet\Control says how it started (1 = legacy BIOS, 2 = UEFI).
# @{ Read; State = 'on' | 'off' | 'legacy' }
function Get-SysSecureBoot {
    $o = @{ Read = $false; State = '' }
    $t = ([string](Sys-RegGet 'HKLM' 'SYSTEM\CurrentControlSet\Control\SecureBoot\State' 'UEFISecureBootEnabled')).Trim()
    if ($t -eq '1') { $o.Read = $true; $o.State = 'on'; return $o }
    if ($t -eq '0') { $o.Read = $true; $o.State = 'off'; return $o }
    $fw = ([string](Sys-RegGet 'HKLM' 'SYSTEM\CurrentControlSet\Control' 'PEFirmwareType')).Trim()
    if ($fw -eq '1') { $o.Read = $true; $o.State = 'legacy' }
    elseif ($fw -eq '2') { $o.Read = $true; $o.State = 'off' }          # (UEFI, and Windows wrote down no state: it is not on)
    return $o
}
# Each on its own (one that cannot be read leaves the others): Dg = Get-SysDeviceGuard ($null when it could not be asked), Iommu, Sb (Secure Boot)
function Get-SysSec {
    $o = @{ Dg = $null; Iommu = $null; Sb = $null }
    try { $o.Dg = Get-SysDeviceGuard } catch { }
    try { $o.Iommu = Get-SysIommu } catch { }
    try { $o.Sb = Get-SysSecureBoot } catch { }
    return $o
}
# Fast startup (read only): HiberbootEnabled under HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power (0 = off; 1 or not there =
# on, the Windows default), the policy "Require use of fast startup" (HiberbootEnabled = 1 under HKLM\SOFTWARE\Policies\Microsoft\Windows\System)
# and hibernation, which it needs (HibernateEnabled under HKLM\SYSTEM\CurrentControlSet\Control\Power, else HibernateEnabledDefault;
# 0 = off). It can change while Windows runs, so it is read in every live pass (three registry values).
# @{ Read; On (what Shut down does now); Setting (the switch in Power Options); Policy; Hib }
function Get-SysFastStartup {
    $o = @{ Read = $true; On = $true; Setting = $true; Policy = $false; Hib = $true }
    $p = 'SYSTEM\CurrentControlSet\Control'
    if (([string](Sys-RegGet 'HKLM' ($p + '\Session Manager\Power') 'HiberbootEnabled')).Trim() -eq '0') { $o.Setting = $false }
    if (([string](Sys-RegGet 'HKLM' 'SOFTWARE\Policies\Microsoft\Windows\System' 'HiberbootEnabled')).Trim() -eq '1') { $o.Policy = $true }
    $he = ([string](Sys-RegGet 'HKLM' ($p + '\Power') 'HibernateEnabled')).Trim()
    if (-not $he) { $he = ([string](Sys-RegGet 'HKLM' ($p + '\Power') 'HibernateEnabledDefault')).Trim() }
    if ($he -eq '0') { $o.Hib = $false }
    $o.On = (($o.Setting -or $o.Policy) -and $o.Hib)
    return $o
}

# --------------------------------------------------------------- the mouse (read only) ----
# The three Windows settings that change how the pointer follows the mouse, read, never written:
#   HKCU\Control Panel\Mouse   MouseSpeed (0 = "Enhance pointer precision" off, 1 or 2 = on), MouseSensitivity (the pointer speed, 1 to 20;
#                              10 is the middle notch). A value that is not there is what Windows has by default (on, 10).
#   USB selective suspend      in the power plan in use, as "powercfg /q" prints it (it only shows the setting; the other forms of powercfg,
#                              which change plans, are never used). The two hexadecimal numbers it prints are the setting while plugged in,
#                              then on battery: 0 = off, 1 = on.
$script:UsbSsSub = '2a737441-1930-4402-8d77-b2bebba308a3'     # the USB settings of a power plan
$script:UsbSsSet = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'     # USB selective suspend
function Get-SysMouse {
    $o = @{ Read = $false; Precision = $null; Speed = $null }
    $k = 'Control Panel\Mouse'
    $sp = Sys-RegGet 'HKCU' $k 'MouseSpeed'
    $se = Sys-RegGet 'HKCU' $k 'MouseSensitivity'
    $o.Read = $true
    $t = ([string]$sp).Trim()
    if ($null -eq $sp -or $t -eq '') { $o.Precision = $true }                        # not set: the Windows default, on
    elseif ($t -match '^\d+$') { $o.Precision = ([int]$t -ne 0) }
    $t = ([string]$se).Trim()
    if ($null -eq $se -or $t -eq '') { $o.Speed = 10 }                               # not set: the Windows default, the middle notch
    elseif ($t -match '^\d+$' -and [int]$t -ge 1 -and [int]$t -le 20) { $o.Speed = [int]$t }
    return $o
}
# "powercfg /q SCHEME_CURRENT <USB> <selective suspend>" text -> @{ Read; Ac (0 / 1, plugged in) }. Only the 0x numbers are used, so the
# language of Windows does not matter.
function Sys-UsbSsParse {
    param([string]$Text)
    $o = @{ Read = $false; Ac = $null }
    $t = [string]$Text
    if (-not $t -or $t -notmatch [regex]::Escape($script:UsbSsSet)) { return $o }
    $hx = @([regex]::Matches($t, '0x([0-9a-fA-F]{8})') | ForEach-Object { $_.Groups[1].Value })
    if ($hx.Count -lt 2) { return $o }
    $ac = [Convert]::ToInt32([string]$hx[$hx.Count - 2], 16)
    if ($ac -ne 0 -and $ac -ne 1) { return $o }
    $o.Read = $true
    $o.Ac = $ac
    return $o
}
function Get-SysUsbSuspend {
    $o = $null
    try {
        $exe = "$env:SystemRoot\System32\powercfg.exe"
        $txt = Sys-RunTool $exe ('/q SCHEME_CURRENT ' + $script:UsbSsSub + ' ' + $script:UsbSsSet) 6000
        $o = Sys-UsbSsParse ([string]$txt)
    } catch { }
    if (-not $o) { $o = @{ Read = $false; Ac = $null } }
    return $o
}

# --------------------------------------------------------------- drives ----
# Windows' own storage service knows each drive's model, size, kind and (through the drive's SMART data) its temperature and wear, so
# none of this needs a driver or another program. A drive or a driver that does not report a number gives $null for it.
function Get-SysStorage {
    $list = @()
    $pci = $null
    foreach ($d in @(Get-PhysicalDisk -ErrorAction Stop)) {
        $sz = $null; try { $sz = [double]$d.Size } catch { }
        $bus = [string]$d.BusType
        # an NVMe drive: the PCI device it is on, for its PCIe link (asked once; the drives do not move)
        $p = ''
        if ($bus -eq 'NVMe') {
            if ($null -eq $pci) { $pci = @{}; try { $pci = Sys-DiskPciIds } catch { } }
            if ($pci.ContainsKey([string]$d.DeviceId)) { $p = [string]$pci[[string]$d.DeviceId] }
        }
        $list += ,@{ Id = [string]$d.DeviceId; Name = ([string]$d.FriendlyName).Trim(); Media = [string]$d.MediaType; Bus = $bus; Bytes = $sz; Health = [string]$d.HealthStatus; Pci = $p }
    }
    return $list
}
# The PCIe link of an NVMe drive. Windows keeps it on the PCI device the drive hangs off (its NVMe controller, the drive's parent device)
# as device properties: DEVPKEY_PciDevice_CurrentLinkSpeed and CurrentLinkWidth (the link as it is now) and MaxLinkSpeed and MaxLinkWidth
# (what the drive supports). The speed is the PCIe generation (1 = 2.5 GT/s, 2 = 5, 3 = 8, 4 = 16, 5 = 32 GT/s), the width the lanes.
# Only reads. Sys-DiskPciIds: disk number -> the instance ID of that PCI device (a drive that is not on a PCI device of its own is left out).
function Sys-DiskPciIds {
    $o = @{}
    foreach ($dd in @(Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction Stop)) {
        $id = [string]$dd.PNPDeviceID
        if (-not $id) { continue }
        $par = ''
        try { $par = [string](@(Get-PnpDeviceProperty -InstanceId $id -KeyName 'DEVPKEY_Device_Parent' -ErrorAction Stop)[0].Data) } catch { }
        if ($par -like 'PCI\*') { $o[[string]$dd.Index] = $par }
    }
    return $o
}
function Sys-PciLink {
    param([string]$InstanceId)
    $o = @{ Gen = $null; Width = $null; GenMax = $null; WidthMax = $null }
    $keys = @('DEVPKEY_PciDevice_CurrentLinkSpeed', 'DEVPKEY_PciDevice_CurrentLinkWidth', 'DEVPKEY_PciDevice_MaxLinkSpeed', 'DEVPKEY_PciDevice_MaxLinkWidth')
    foreach ($p in @(Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName $keys -ErrorAction Stop)) {
        $v = Sys-Num $p.Data
        switch ([string]$p.KeyName) {
            'DEVPKEY_PciDevice_CurrentLinkSpeed' { $o.Gen = Sys-Plausible $v 1 7 }
            'DEVPKEY_PciDevice_CurrentLinkWidth' { $o.Width = Sys-Plausible $v 1 32 }
            'DEVPKEY_PciDevice_MaxLinkSpeed'     { $o.GenMax = Sys-Plausible $v 1 7 }
            'DEVPKEY_PciDevice_MaxLinkWidth'     { $o.WidthMax = Sys-Plausible $v 1 32 }
        }
    }
    return $o
}
# Id -> @{ Temp; Wear; Hours; Link } for every drive Windows has numbers for ($Drives: the static list, for the NVMe drives' PCIe links)
function Sys-StorageLive {
    param($Drives = $null)
    $o = @{}
    foreach ($d in @(Get-PhysicalDisk -ErrorAction Stop)) {
        $rc = $null
        try { $rc = $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch { }
        if (-not $rc) { continue }
        $t = Sys-Num $rc.Temperature
        if ($null -ne $t -and ([double]$t -le 0 -or [double]$t -ge 150)) { $t = $null }          # 0 means "not reported"
        $w = Sys-Num $rc.Wear
        if ($null -ne $w -and ([double]$w -lt 0 -or [double]$w -gt 100)) { $w = $null }
        $h = Sys-Num $rc.PowerOnHours
        if ($null -ne $h -and [double]$h -lt 0) { $h = $null }
        $o[[string]$d.DeviceId] = @{ Temp = $t; Wear = $w; Hours = $h; Link = $null }
    }
    foreach ($x in @($Drives)) {
        if (-not $x -or -not $x.Pci) { continue }
        $lk = $null; try { $lk = Sys-PciLink ([string]$x.Pci) } catch { }
        if (-not $lk) { continue }
        $k = [string]$x.Id
        if (-not $o.ContainsKey($k)) { $o[$k] = @{ Temp = $null; Wear = $null; Hours = $null; Link = $null } }
        $o[$k].Link = $lk
    }
    return $o
}

# --------------------------------------------------------------- the live numbers ----
# Performance counters are created once and kept (a rate counter needs two readings). The names are English: on a Windows in
# another language a counter is simply missing and the page shows "not available" for it.
$script:SysPc = $null
function Sys-PcNew {
    $o = @{}
    $defs = @(
        @('CpuUtil', 'Processor Information', '% Processor Utility', '_Total'),
        @('CpuPerf', 'Processor Information', '% Processor Performance', '_Total'),
        @('CpuFreq', 'Processor Information', 'Processor Frequency', '_Total'),
        @('Procs', 'System', 'Processes', ''),
        @('Threads', 'System', 'Threads', ''),
        @('MemAvail', 'Memory', 'Available MBytes', '')
    )
    foreach ($d in $defs) {
        try {
            if ($d[3]) { $c = New-Object System.Diagnostics.PerformanceCounter($d[1], $d[2], $d[3], $true) }
            else { $c = New-Object System.Diagnostics.PerformanceCounter($d[1], $d[2], '', $true) }
            [void]$c.NextValue()
            $o[$d[0]] = $c
        } catch { }
    }
    return $o
}
function Sys-PcRead {
    param($c)
    if (-not $c) { return $null }
    try { return [double]$c.NextValue() } catch { return $null }
}

# The clock the CPU runs at: the nominal frequency times "% Processor Performance" (what Task Manager's Speed shows)
function Sys-CpuClock {
    param($FreqMHz, $PerfPct)
    if ($null -eq $FreqMHz -or $null -eq $PerfPct) { return $null }
    if ([double]$FreqMHz -le 0 -or [double]$PerfPct -le 0) { return $null }
    return [Math]::Round([double]$FreqMHz * [double]$PerfPct / 100.0, 0)
}

# ---- NVIDIA ----
$script:SysSmi = $null              # the path of nvidia-smi, '' when there is none, $null before the first look
$script:SmiSets = @(
    @('name', 'driver_version', 'temperature.gpu', 'power.draw', 'power.limit', 'clocks.gr', 'clocks.max.gr', 'clocks.mem', 'utilization.gpu', 'memory.used', 'memory.total', 'fan.speed', 'pstate', 'pcie.link.gen.current', 'pcie.link.gen.max', 'pcie.link.width.current', 'pcie.link.width.max'),
    @('name', 'driver_version', 'temperature.gpu', 'power.draw', 'power.limit', 'clocks.gr', 'clocks.max.gr', 'clocks.mem', 'utilization.gpu', 'memory.used', 'memory.total', 'fan.speed', 'pstate'),
    @('name', 'driver_version', 'temperature.gpu', 'power.draw', 'clocks.gr', 'utilization.gpu', 'memory.used', 'memory.total')
)
$script:SmiSet = 0
function Sys-FindSmi {
    foreach ($p in @("$env:SystemRoot\System32\nvidia-smi.exe", "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe")) {
        try { if ($p -and (Test-Path -LiteralPath $p)) { return $p } } catch { }
    }
    try { $c = Get-Command 'nvidia-smi.exe' -ErrorAction Ignore; if ($c) { return [string]$c.Source } } catch { }
    return ''
}
# "NVIDIA GeForce RTX 5080, 581.80, 45, 38.52, 360.00, 2640, 3090, 14001, 3, 1062, 16303, 0, P8" -> a table of the fields. $null when the
# line does not have as many values as asked for.
function Sys-ParseSmi {
    param([string]$Text, [string[]]$Fields)
    foreach ($line in ([string]$Text -split "`r?`n")) {
        $l = $line.Trim()
        if (-not $l -or $l -match 'not a valid field|Failed to initialize|No devices were found|NVIDIA-SMI has failed') { continue }
        $parts = @($l -split ',' | ForEach-Object { $_.Trim() })
        if ($parts.Count -ne $Fields.Count) { return $null }
        $h = @{}
        for ($i = 0; $i -lt $Fields.Count; $i++) { $h[[string]$Fields[$i]] = [string]$parts[$i] }
        return $h
    }
    return $null
}
function Sys-GpuNvidia {
    if ($null -eq $script:SysSmi) { $script:SysSmi = Sys-FindSmi }
    if (-not $script:SysSmi) { return $null }
    for ($tries = 0; $tries -lt $script:SmiSets.Count; $tries++) {
        $f = @($script:SmiSets[$script:SmiSet])
        $txt = Sys-RunTool $script:SysSmi ('--query-gpu=' + ($f -join ',') + ' --format=csv,noheader,nounits') 5000
        if ($null -eq $txt) { return $null }        # the program did not run or did not answer in time: nothing to learn about the fields
        $h = Sys-ParseSmi $txt $f
        if ($h) { return (Sys-GpuFromSmi $h) }
        # an older driver may not know every field: try the shorter list once, and remember which one worked
        if ($script:SmiSet -lt ($script:SmiSets.Count - 1)) { $script:SmiSet++ } else { break }
    }
    return $null
}
# A number outside what a graphics card can report (a glitch, or a driver's placeholder) is no reading: $null
function Sys-Plausible {
    param($v, $Min, $Max)
    if (Sys-InRange $v $Min $Max) { return [double]$v }
    return $null
}
function Sys-GpuFromSmi {
    param($h)
    $used = Sys-Plausible (Sys-Num $h['memory.used']) 0 1000000
    $tot = Sys-Plausible (Sys-Num $h['memory.total']) 1 1000000
    if ($null -ne $used -and $null -ne $tot -and $used -gt $tot) { $used = $null }
    return @{ Source = 'nvidia-smi'; Name = [string]$h['name']; Driver = [string]$h['driver_version']
              Temp = (Sys-Plausible (Sys-Num $h['temperature.gpu']) 1 130); Power = (Sys-Plausible (Sys-Num $h['power.draw']) 0 2000)
              PowerLimit = (Sys-Plausible (Sys-Num $h['power.limit']) 1 2000)
              ClockMHz = (Sys-Plausible (Sys-Num $h['clocks.gr']) 0 6000); ClockMaxMHz = (Sys-Plausible (Sys-Num $h['clocks.max.gr']) 1 6000)
              MemClockMHz = (Sys-Plausible (Sys-Num $h['clocks.mem']) 0 20000)
              Usage = (Sys-Plausible (Sys-Num $h['utilization.gpu']) 0 100); MemUsedMB = $used; MemTotalMB = $tot
              Fan = (Sys-Plausible (Sys-Num $h['fan.speed']) 0 100); PState = [string]$h['pstate']
              # the PCIe link: generation and width now, and the most the card and this PC's slot allow (a driver that does not know the fields gives none)
              PcieGen = (Sys-Plausible (Sys-Num $h['pcie.link.gen.current']) 1 7); PcieGenMax = (Sys-Plausible (Sys-Num $h['pcie.link.gen.max']) 1 7)
              PcieWidth = (Sys-Plausible (Sys-Num $h['pcie.link.width.current']) 1 32); PcieWidthMax = (Sys-Plausible (Sys-Num $h['pcie.link.width.max']) 1 32) }
}
# Resizable BAR. The BAR1 aperture is the window the CPU has into video memory: 256 MB without Resizable BAR, as large as the video memory
# (or a big part of it) with it. "nvidia-smi -q -d MEMORY" prints it as
#     BAR1 Memory Usage
#         Total                             : 16384 MiB
# The size in MB of the first card's BAR1 Total, $null when there is no such line or no number in it ("N/A").
function Sys-ParseBar1 {
    param([string]$Text)
    $in = $false
    foreach ($line in ([string]$Text -split "`r?`n")) {
        $l = $line.Trim()
        if (-not $l) { continue }
        if ($l -match '^BAR1 Memory Usage$') { $in = $true; continue }
        if (-not $in) { continue }
        if ($l -match '^Total\s*:\s*(\S+)\s*MiB$') { return (Sys-Plausible (Sys-Num $Matches[1]) 1 4000000) }
        if ($l -notmatch ':') { break }         # the next heading: this section had no usable Total
    }
    return $null
}
function Sys-Bar1MB {
    if ($null -eq $script:SysSmi) { $script:SysSmi = Sys-FindSmi }
    if (-not $script:SysSmi) { return $null }
    $txt = Sys-RunTool $script:SysSmi '-q -d MEMORY' 6000
    if ($null -eq $txt) { return $null }
    return (Sys-ParseBar1 $txt)
}
# without nvidia-smi: what Windows itself counts (usage of the 3D engine, video memory in use)
function Sys-GpuWindows {
    $g = @{ Source = 'windows'; Name = ''; Driver = ''; Temp = $null; Power = $null; PowerLimit = $null; ClockMHz = $null; ClockMaxMHz = $null; MemClockMHz = $null
            Usage = $null; MemUsedMB = $null; MemTotalMB = $null; Fan = $null; PState = ''; PcieGen = $null; PcieGenMax = $null; PcieWidth = $null; PcieWidthMax = $null }
    try {
        $s = @((Get-Counter -Counter '\GPU Engine(*engtype_3D)\Utilization Percentage' -ErrorAction Stop).CounterSamples)
        if ($s.Count) { $sum = 0.0; foreach ($x in $s) { $sum += [double]$x.CookedValue }; $g.Usage = [Math]::Min(100.0, [Math]::Round($sum, 0)) }
    } catch { }
    try {
        $s = @((Get-Counter -Counter '\GPU Adapter Memory(*)\Dedicated Usage' -ErrorAction Stop).CounterSamples)
        if ($s.Count) { $max = 0.0; foreach ($x in $s) { if ([double]$x.CookedValue -gt $max) { $max = [double]$x.CookedValue } }; $g.MemUsedMB = [Math]::Round($max / 1MB, 0) }
    } catch { }
    return $g
}

# ---- sensors from HWiNFO and LibreHardwareMonitor ----
# HWiNFO writes one group of values per sensor the person ticked ("Report value in Gadget") under HKCU\SOFTWARE\HWiNFO64\VSB:
# Sensor<N> (the group), Label<N> (the reading), Value<N> (formatted, with unit) and ValueRaw<N> (the plain number).
function Sys-HwiItems {
    param($Values)
    $items = @()
    $idx = @()
    foreach ($k in @($Values.Keys)) { if ([string]$k -match '^Label(\d+)$') { $idx += [int]$Matches[1] } }
    foreach ($ix in @($idx | Sort-Object)) {
        $n = [string]$ix
        $k = 'Label' + $n
        $text = [string]$Values["Value$n"]
        $v = Sys-Num $Values["ValueRaw$n"] -Raw
        if ($null -eq $v) { $v = Sys-Num $text }
        $unit = ''
        $m = [regex]::Match($text, '^\s*-?[\d.,]+\s*(.*)$')
        if ($m.Success) { $unit = $m.Groups[1].Value.Trim() }
        $items += ,@{ Sensor = [string]$Values["Sensor$n"]; Label = ([string]$Values[$k]).Trim(); Text = $text; Value = $v; Unit = $unit }
    }
    return $items
}
# HWiNFO's shared memory ("Shared Memory Support" in its Settings, off by default) holds EVERY reading, with no need to tick them one by
# one. It is a memory-mapped file named Global\HWiNFO_SENS_SM2: a header, a list of sensors and a list of readings (HWiNFO's own
# hwisenssm2.h describes it). The free HWiNFO switches it off again after 12 hours; HWiNFO Pro does not.
#   header   signature 'HWiS' (0x53695748; 'DEAD' or 'DAED' once HWiNFO has ended), version, revision, poll time (8 bytes),
#            then six numbers: offset, element size and count of the sensor list, and of the reading list, then the polling period (ms)
#   sensor   id, instance, name (128 bytes), your name for it (128 bytes)
#   reading  type, sensor index, id, label (128), your label (128), unit (16), value, min, max, average (doubles)
# The reading is cut out of a byte array so that it can be tested without Windows.
$script:Latin1 = [System.Text.Encoding]::GetEncoding('iso-8859-1')
function Sys-HwiText {
    param([byte[]]$B, [int]$Off, [int]$Len)
    $cnt = [Math]::Min($Len, $B.Length - $Off)
    if ($cnt -le 0) { return '' }
    $z = [Array]::IndexOf($B, [byte]0, $Off, $cnt)
    $n = $cnt
    if ($z -ge 0) { $n = $z - $Off }
    if ($n -le 0) { return '' }
    return $script:Latin1.GetString($B, $Off, $n)
}
# Where the two lists are, from the first bytes. $null when this is not a HWiNFO header.  Why: signature | ended | layout | short
function Sys-HwiLayout {
    param([byte[]]$Hdr)
    $r = @{ Ok = $false; Why = ''; Base = 20; OffS = 0; SizeS = 0; NumS = 0; OffR = 0; SizeR = 0; NumR = 0 }
    if (-not $Hdr -or $Hdr.Length -lt 48) { $r.Why = 'short'; return $r }
    $sig = [BitConverter]::ToUInt32($Hdr, 0)
    # "DEAD" once HWiNFO has ended. Programs that read this memory spell it both ways ("DEAD" = 0x44414544, "DAED" = 0x44454144), and which
    # one HWiNFO writes was not checked here, so both count
    if ($sig -eq 0x44414544 -or $sig -eq 0x44454144) { $r.Why = 'ended'; return $r }
    if ($sig -ne 0x53695748) { $r.Why = 'signature'; return $r }
    # the header is packed (the six numbers start at byte 20); a build that aligns the poll time to 8 bytes has them from byte 24
    foreach ($b in 20, 24) {
        if ($Hdr.Length -lt ($b + 24)) { continue }
        $offS = [uint32][BitConverter]::ToUInt32($Hdr, $b);      $sizeS = [uint32][BitConverter]::ToUInt32($Hdr, $b + 4);  $numS = [uint32][BitConverter]::ToUInt32($Hdr, $b + 8)
        $offR = [uint32][BitConverter]::ToUInt32($Hdr, $b + 12); $sizeR = [uint32][BitConverter]::ToUInt32($Hdr, $b + 16); $numR = [uint32][BitConverter]::ToUInt32($Hdr, $b + 20)
        if ($offS -ge ($b + 24) -and $offS -le 256 -and $sizeS -ge 8 -and $sizeS -le 4096 -and $numS -le 4096 -and $sizeR -ge 316 -and $sizeR -le 8192 -and $numR -le 100000 -and $offR -ge $offS) {
            $r.Ok = $true; $r.Base = $b; $r.OffS = [int]$offS; $r.SizeS = [int]$sizeS; $r.NumS = [int]$numS; $r.OffR = [int]$offR; $r.SizeR = [int]$sizeR; $r.NumR = [int]$numR
            return $r
        }
    }
    $r.Why = 'layout'
    return $r
}
# HWiNFO writes the time of its last poll (seconds since 1970, UTC) into the header, and the polling period (milliseconds) after the six
# numbers. When its Sensors window is closed or paused, the memory stays but nothing in it changes any more: the numbers are frozen. $Now is
# the current time in the same unit. A poll time that is 0 or lies far in the future (a clock that is wrong) is not judged.
function Sys-HwiUnixNow {
    return [int64]([DateTime]::UtcNow - (New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc))).TotalSeconds
}
function Sys-HwiStale {
    param([byte[]]$Hdr, $Lay, $Now = $null)
    if (-not $Hdr -or -not $Lay -or -not $Lay.Ok) { return $false }
    $pAt = [int]$Lay.Base - 8
    if ($pAt -lt 12 -or $Hdr.Length -lt ($pAt + 8)) { return $false }
    $poll = [BitConverter]::ToInt64($Hdr, $pAt)
    if ($poll -le 0) { return $false }
    if ($null -eq $Now) { $Now = Sys-HwiUnixNow }
    $age = [int64]$Now - $poll
    if ($age -lt -600) { return $false }
    $limit = 60.0
    $perAt = [int]$Lay.Base + 24
    if ($Hdr.Length -ge ($perAt + 4)) {
        $per = [BitConverter]::ToUInt32($Hdr, $perAt)
        if ($per -ge 100 -and $per -le 600000) { $limit = [Math]::Max($limit, 5.0 * $per / 1000.0) }
    }
    return ($age -gt $limit)
}
# $Want (a regular expression) keeps only the readings whose label matches: the others are not cut out at all. Total is the number of
# readings in the memory, whatever was kept.
function Sys-HwiParseShared {
    param([byte[]]$Bytes, $Now = $null, [string]$Want = '')
    $r = @{ Ok = $false; Why = ''; Items = @(); Total = 0 }
    $lay = Sys-HwiLayout $Bytes
    if (-not $lay.Ok) { $r.Why = [string]$lay.Why; return $r }
    if (Sys-HwiStale $Bytes $lay $Now) { $r.Why = 'stale'; return $r }
    $end = [Math]::Max($lay.OffS + $lay.SizeS * $lay.NumS, $lay.OffR + $lay.SizeR * $lay.NumR)
    if ($Bytes.Length -lt $end) { $r.Why = 'short'; return $r }
    $r.Total = [int]$lay.NumR
    $names = @()
    for ($i = 0; $i -lt $lay.NumS; $i++) {
        $o = $lay.OffS + $i * $lay.SizeS
        $nm = ''
        if ($lay.SizeS -ge 136 + 128) { $nm = Sys-HwiText $Bytes ($o + 136) 128 }
        if (-not $nm) { $nm = Sys-HwiText $Bytes ($o + 8) 128 }
        $names += $nm
    }
    $items = @()
    $rx = $null
    if ($Want) { $rx = New-Object System.Text.RegularExpressions.Regex($Want, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) }
    for ($j = 0; $j -lt $lay.NumR; $j++) {
        $o = $lay.OffR + $j * $lay.SizeR
        # the label is cut out in place (this runs for every reading, up to a thousand, every two seconds)
        $label = ''
        $z = [Array]::IndexOf($Bytes, [byte]0, $o + 12, 128)
        $n = 128; if ($z -ge 0) { $n = $z - ($o + 12) }
        if ($n -gt 0) { $label = $script:Latin1.GetString($Bytes, $o + 12, $n).Trim() }
        if (-not $label) { $label = (Sys-HwiText $Bytes ($o + 140) 128).Trim() }
        if (-not $label) { continue }
        if ($rx -and -not $rx.IsMatch($label)) { continue }
        $si = [int][BitConverter]::ToUInt32($Bytes, $o + 4)
        $unit = (Sys-HwiText $Bytes ($o + 268) 16).Trim()
        $val = [BitConverter]::ToDouble($Bytes, $o + 284)
        $num = $null
        if (-not [double]::IsNaN($val) -and -not [double]::IsInfinity($val)) { $num = [double]$val }
        $sensor = ''; if ($si -ge 0 -and $si -lt $names.Count) { $sensor = [string]$names[$si] }
        $text = ''
        if ($null -ne $num) { $text = ([double]$num).ToString('0.###', [Globalization.CultureInfo]::InvariantCulture); if ($unit) { $text += ' ' + $unit } }
        $items += ,@{ Sensor = $sensor; Label = $label; Text = $text; Value = $num; Unit = $unit }
    }
    $r.Items = $items
    $r.Ok = $true
    if ($r.Total -eq 0) { $r.Why = 'empty' }
    return $r
}
# The bytes HWiNFO shares, or $null with the reason: off (nothing is shared: Shared Memory Support is off or its sensors are not running),
# denied (Windows refused access), error
#
# HWiNFO refills the list of readings while it polls: it counts the number of readings down to zero and back up again. A copy made at that
# moment would be empty or half old, half new, so the copy is checked: the header is read again afterwards and must be the same, and a list
# of zero readings is waited out. $Read is a script block (offset, count) that returns the bytes it could read (fewer at the end of the
# memory); a block is used so that this can be tested without Windows.
function Sys-HwiSnapshot {
    param([scriptblock]$Read, [int]$Tries = 4, [int]$WaitMs = 120)
    $r = @{ Bytes = $null; Why = '' }
    $last = $null
    for ($t = 0; $t -lt $Tries; $t++) {
        if ($t -gt 0) { Start-Sleep -Milliseconds $WaitMs }
        $hdr = [byte[]](& $Read 0 64)
        $lay = Sys-HwiLayout $hdr
        if (-not $lay.Ok) { $r.Why = [string]$lay.Why; return $r }
        $need = [Math]::Max($lay.OffS + $lay.SizeS * $lay.NumS, $lay.OffR + $lay.SizeR * $lay.NumR)
        if ($need -gt 64MB) { $r.Why = 'layout'; return $r }
        $refill = ($lay.NumR -eq 0 -or $lay.NumS -eq 0)
        $buf = [byte[]](& $Read 0 $need)
        if ($buf.Length -lt $need) { $r.Why = 'short'; continue }
        $last = $buf
        $r.Why = ''
        if ($refill) { continue }
        $again = [byte[]](& $Read 0 64)
        $same = ($again.Length -ge 48)
        for ($i = 0; $same -and $i -lt 48; $i++) { if ($again[$i] -ne $buf[$i]) { $same = $false } }
        if ($same) { $r.Bytes = $buf; return $r }
    }
    # still changing after every try: the numbers are all single readings, so the last copy is as good as any
    if ($last) { $r.Bytes = $last; $r.Why = '' }
    return $r
}
# The script block that reads (offset, count) from a stream: the bytes it got, fewer at the end of the stream
function Sys-HwiStreamReader {
    param([System.IO.Stream]$Stream)
    $st = $Stream
    return {
        param([int]$Off, [int]$Cnt)
        $st.Position = $Off
        $b = New-Object byte[] $Cnt
        $have = 0
        while ($have -lt $Cnt) { $n = $st.Read($b, $have, $Cnt - $have); if ($n -le 0) { break }; $have += $n }
        if ($have -lt $Cnt) { $x = New-Object byte[] $have; [Array]::Copy($b, $x, $have); return , $x }
        return , $b
    }.GetNewClosure()
}
function Sys-HwiSharedBytes {
    $r = @{ Bytes = $null; Why = '' }
    $mmf = $null; $st = $null
    try {
        $mmf = [System.IO.MemoryMappedFiles.MemoryMappedFile]::OpenExisting('Global\HWiNFO_SENS_SM2', [System.IO.MemoryMappedFiles.MemoryMappedFileRights]::Read)
        $st = $mmf.CreateViewStream(0, 0, [System.IO.MemoryMappedFiles.MemoryMappedFileAccess]::Read)
        return (Sys-HwiSnapshot (Sys-HwiStreamReader $st))
    } catch [System.IO.FileNotFoundException] { $r.Why = 'off' }
    catch [System.UnauthorizedAccessException] { $r.Why = 'denied' }
    catch { $r.Why = 'off' }
    finally {
        if ($st) { try { $st.Dispose() } catch { } }
        if ($mmf) { try { $mmf.Dispose() } catch { } }
    }
    return $r
}
# HWiNFO: running or not, its readings (shared memory first, the Gadget list in the registry second), where they came from (Via) and,
# when there are none, why not (Why: off | denied | ended | layout | short | signature | empty | error)
function Sys-ReadHwi {
    $r = @{ Running = $false; Items = @(); Via = ''; Why = '' }
    if (-not (Sys-ProcRunning @('HWiNFO64', 'HWiNFO32'))) { return $r }
    $r.Running = $true
    $why = 'off'
    try {
        $b = Sys-HwiSharedBytes
        if ($b.Bytes) {
            $p = Sys-HwiParseShared $b.Bytes $null $script:HwiWanted
            if ($p.Ok -and [int]$p.Total -gt 0) { $r.Items = @($p.Items); $r.Via = 'shared memory'; return $r }
            $why = [string]$p.Why
        } else { $why = [string]$b.Why }
    } catch { $why = 'error' }
    # frozen shared memory means HWiNFO's sensors are paused: its gadget list in the registry is frozen too, so it is not used
    if ($why -ne 'stale') {
        foreach ($hive in 'HKCU', 'HKLM') {
            $h = Sys-RegAll $hive 'SOFTWARE\HWiNFO64\VSB'
            if ($h -and $h.Count) { $r.Items = @(Sys-HwiItems $h); $r.Via = 'gadget list'; break }
        }
    }
    if ($r.Items.Count -eq 0) { $r.Why = $why }
    return $r
}
function Sys-ReadLhm {
    $r = @{ Running = $false; Name = ''; Items = @() }
    $pn = ''
    if (Sys-ProcRunning @('LibreHardwareMonitor')) { $pn = 'LibreHardwareMonitor' }
    elseif (Sys-ProcRunning @('OpenHardwareMonitor')) { $pn = 'OpenHardwareMonitor' }
    if (-not $pn) { return $r }
    $r.Name = $pn
    foreach ($ns in @('root\LibreHardwareMonitor', 'root\OpenHardwareMonitor')) {
        try {
            $rows = @(Get-CimInstance -Namespace $ns -ClassName Sensor -ErrorAction Stop)
            $r.Running = $true
            $items = @()
            foreach ($x in $rows) { $items += ,@{ Parent = [string]$x.Parent; Label = [string]$x.Name; Type = [string]$x.SensorType; Id = [string]$x.Identifier; Value = (Sys-Num $x.Value) } }
            if ($items.Count) { $r.Items = $items; break }
        } catch { }
    }
    return $r
}
# A number is "plausible" when it lies in [Min, Max] (either end may be $null = open). Sensors do glitch: a Ryzen 9800X3D has been seen
# to report a die temperature of 203.2 degrees for one poll. Such a reading is skipped, so the next candidate row (or none) is used.
function Sys-InRange {
    param($Value, $Min = $null, $Max = $null)
    if ($null -eq $Value) { return $false }
    $v = [double]$Value
    if ([double]::IsNaN($v) -or [double]::IsInfinity($v)) { return $false }
    if ($null -ne $Min -and $v -lt [double]$Min) { return $false }
    if ($null -ne $Max -and $v -gt [double]$Max) { return $false }
    return $true
}
# The first item whose label matches one of the patterns (in the order of the patterns) and that has a plausible number and, if asked, the unit
function Sys-FindHwi {
    param($Items, [string[]]$Labels, [string]$Unit = '', $Min = $null, $Max = $null, [string]$Not = '')
    foreach ($pat in $Labels) {
        foreach ($i in @($Items)) {
            if ([string]$i.Label -notmatch $pat) { continue }
            if ($Not -and [string]$i.Label -match $Not) { continue }
            if ($null -eq $i.Value) { continue }
            if ($Unit -and [string]$i.Unit -notmatch $Unit) { continue }
            if (-not (Sys-InRange $i.Value $Min $Max)) { continue }
            return $i
        }
    }
    return $null
}
# A temperature from HWiNFO in degrees Celsius: HWiNFO can be set to show Fahrenheit, and the unit comes with the reading. Returns
# @{ Value; Label } or $null. A value of 0 or below, or above 125 degrees, is not a CPU temperature.
function Sys-HwiTemp {
    param($Items, [string[]]$Labels)
    foreach ($pat in $Labels) {
        foreach ($i in @($Items)) {
            if ([string]$i.Label -notmatch $pat) { continue }
            if ($null -eq $i.Value) { continue }
            $u = [string]$i.Unit
            if ($u -notmatch '[CF]$') { continue }
            $c = [double]$i.Value
            if ($u -match 'F$') { $c = ($c - 32.0) / 1.8 }
            if (-not (Sys-InRange $c 1 125)) { continue }
            return @{ Value = [Math]::Round($c, 1); Label = [string]$i.Label }
        }
    }
    return $null
}
function Sys-FindLhm {
    param($Items, [string]$Type, [string]$IdLike, [string[]]$Labels, $Min = $null, $Max = $null)
    foreach ($pat in $Labels) {
        foreach ($i in @($Items)) {
            if ([string]$i.Type -ne $Type) { continue }
            if ($IdLike -and [string]$i.Id -notmatch $IdLike) { continue }
            if ([string]$i.Label -notmatch $pat) { continue }
            if ($null -eq $i.Value) { continue }
            if (-not (Sys-InRange $i.Value $Min $Max)) { continue }
            return $i
        }
    }
    return $null
}
# The rows this app reads out of HWiNFO, by label. They are kept in one place so that the reader of the shared memory can skip every other
# reading (a PC has some 500 to 1000 of them and the memory is read every two seconds) without a second list that could go out of step.
$script:HwiLabTemp  = @('^CPU \(Tctl/Tdie\)$', '^CPU Die \(average\)$', '^CPU Package$', '^CPU \(Tctl\)$', '^CPU \(Tdie\)$', '^CPU Tdie$', '^CPU Tctl$', '^CPU Temperature$')
$script:HwiLabPower = @('^CPU Package Power( \(SMU\))?$', '^CPU PPT$', '^Package Power$', '^CPU Power$')
$script:HwiLabMclk  = @('^Memory Clock$')
$script:HwiLabTime  = [ordered]@{ Tcas = '^Tcas$'; Trcd = '^Trcd(rd| \(read\))?$'; Trp = '^Trp$'; Tras = '^Tras$'; Trc = '^Trc$'; Trfc = '^Trfc$' }
$script:HwiLabCr    = @('^Command Rate$')
# The memory controller clock (UCLK on Ryzen; HWiNFO calls the row "Memory Controller Clock", newer builds may add "(UCLK)")
$script:HwiLabUclk  = @('^Memory Controller Clock( \(UCLK\))?$', '^UCLK( \(.*\))?$')
# The DRAM voltage. The board's own chip usually gives it as "DRAM" (or DIMM / VDIMM); the last pattern catches names such as "DIMM[1] VDD".
# DDR5 also has VPP (1.8 V), VDDQ and VDDIO rows that must not be taken for it, and a memory temperature or power row never counts.
$script:HwiLabVdimm = @('^DRAM$', '^DRAM Voltage$', '^VDIMM$', '^DIMM$', '^DIMM Voltage$', '^Memory Voltage$', '^VDD_MEM$', '^DRAM VDD$', '^DIMM VDD$', '(DRAM|DIMM).*\b(Voltage|VDD)\b')
$script:HwiNotVdimm = 'VPP|VDDQ|VDDIO|VTT|Temp|Current|Power'
# The memory I/O voltage as the CPU itself reads it (Ryzen VDDIO). It is the supply of the memory interface, which a BIOS can set apart from
# the DRAM's own voltage, so it is only used when no DRAM row exists, and the card says so.
$script:HwiLabVddio = @('^CPU VDDIO / MC Voltage$', '^CPU VDDIO( / MC)?$', '^VDDIO( MEM)?$', '^VDDIO_MEM$')
$script:HwiWanted   = ((@($script:HwiLabTemp) + @($script:HwiLabPower) + @($script:HwiLabMclk) + @($script:HwiLabTime.Values) + @($script:HwiLabCr) + @($script:HwiLabUclk) + @($script:HwiLabVdimm) + @($script:HwiLabVddio)) -join '|')
# What the two programs report, boiled down:  CpuTemp, CpuPower (numbers or $null) with CpuTempFrom / CpuPowerFrom (the row they came
# from, so the Sensors card can say which one it is), RAM timings Tcas Trcd Trp Tras Trc Trfc (numbers) and Cr (text such as "1T"),
# RamMclk, RamUclk (the memory controller clock, with UclkFrom), Vdimm (the DRAM voltage in volts, with VdimmFrom; VdimmIo is $true when
# the row is the CPU's memory I/O voltage because no DRAM row exists), and Source (who gave them).
function Sys-PickSensors {
    param($Hwi, $Lhm)
    $o = @{ CpuTemp = $null; CpuPower = $null; CpuTempFrom = ''; CpuPowerFrom = ''; RamMclk = $null; RamUclk = $null; UclkFrom = ''; Vdimm = $null; VdimmFrom = ''; VdimmIo = $false; Tcas = $null; Trcd = $null; Trp = $null; Tras = $null; Trc = $null; Trfc = $null; Cr = ''; Source = '' }
    $src = @()
    $hi = @(); if ($Hwi) { $hi = @($Hwi.Items) }
    $li = @(); if ($Lhm) { $li = @($Lhm.Items) }
    if ($hi.Count) {
        $x = Sys-HwiTemp $hi $script:HwiLabTemp
        if ($x) { $o.CpuTemp = [double]$x.Value; $o.CpuTempFrom = [string]$x.Label }
        $x = Sys-FindHwi $hi $script:HwiLabPower 'W$' 0 1000
        if ($x) { $o.CpuPower = [double]$x.Value; $o.CpuPowerFrom = [string]$x.Label }
        $x = Sys-FindHwi $hi $script:HwiLabMclk 'MHz' 100 6000
        if ($x) { $o.RamMclk = [double]$x.Value }
        $x = Sys-FindHwi $hi $script:HwiLabUclk 'MHz' 100 6000
        if ($x) { $o.RamUclk = [double]$x.Value; $o.UclkFrom = [string]$x.Label }
        # 1.0 to 2.0 V: DDR5 runs at 1.1 V and up, and a chip that reads half the true voltage (seen on some boards) is below that and skipped
        $x = Sys-FindHwi $hi $script:HwiLabVdimm '^V$' 1.0 2.0 $script:HwiNotVdimm
        if (-not $x) {
            $x = Sys-FindHwi $hi $script:HwiLabVddio '^V$' 1.0 2.0
            if ($x) { $o.VdimmIo = $true }
        }
        if ($x) { $o.Vdimm = [double]$x.Value; $o.VdimmFrom = [string]$x.Label }
        foreach ($t in @($script:HwiLabTime.Keys)) {
            $x = Sys-FindHwi $hi @([string]$script:HwiLabTime[$t]) '' 1 4096
            if ($x) { $o[$t] = [double]$x.Value }
        }
        $x = Sys-FindHwi $hi $script:HwiLabCr '' 1 3
        if ($x) { $o.Cr = ('{0:0}T' -f [double]$x.Value) }
        if ($null -ne $o.CpuTemp -or $null -ne $o.CpuPower -or $null -ne $o.Tcas -or $null -ne $o.RamMclk -or $null -ne $o.RamUclk -or $null -ne $o.Vdimm) { $src += 'HWiNFO' }
    }
    if ($li.Count -and ($null -eq $o.CpuTemp -or $null -eq $o.CpuPower -or $null -eq $o.Vdimm)) {
        $used = $false
        # the DRAM voltage from the board's chip as LibreHardwareMonitor names it (it has no memory controller clock)
        if ($null -eq $o.Vdimm) {
            $x = Sys-FindLhm $li 'Voltage' '' @('^DRAM$', '^DIMM$', '^VDIMM$', '^DRAM Voltage$', '^Memory Voltage$') 1.0 2.0
            if ($x) { $o.Vdimm = [double]$x.Value; $o.VdimmFrom = [string]$x.Label; $used = $true }
        }
        if ($null -eq $o.CpuTemp) {
            $x = Sys-FindLhm $li 'Temperature' '/(amd|intel)cpu/' @('Core \(Tctl/Tdie\)', 'CPU Package', 'Package', 'Tdie', 'Tctl', 'CPU Die', 'Core Max') 1 125
            if ($x) { $o.CpuTemp = [double]$x.Value; $o.CpuTempFrom = [string]$x.Label; $used = $true }
        }
        if ($null -eq $o.CpuPower) {
            $x = Sys-FindLhm $li 'Power' '/(amd|intel)cpu/' @('^Package$', 'CPU Package', 'Package') 0 1000
            if ($x) { $o.CpuPower = [double]$x.Value; $o.CpuPowerFrom = [string]$x.Label; $used = $true }
        }
        if ($used) { $src += [string]$Lhm.Name }
    }
    $o.Source = ($src -join ' + ')
    return $o
}

# ---- displays ----
# The picture of one screen from what the driver lists. $Current = @(width, height, hertz, bits); $Modes = @(@(w, h, hz), ...)
function Sys-ModeSummary {
    param($Current, $Modes)
    $w = [int]$Current[0]; $h = [int]$Current[1]; $hz = [int]$Current[2]
    $atRes = @()
    $bestPix = 0; $best = $null
    foreach ($m in @($Modes)) {
        $mw = [int]$m[0]; $mh = [int]$m[1]; $mhz = [int]$m[2]
        if ($mw -eq $w -and $mh -eq $h) { $atRes += $mhz }
        # the biggest picture, and the highest rate it comes with
        $pix = $mw * $mh
        if ($pix -gt $bestPix -or ($pix -eq $bestPix -and $best -and $mhz -gt $best.Hz)) { $bestPix = $pix; $best = @{ W = $mw; H = $mh; Hz = $mhz } }
    }
    $rates = @($atRes | Sort-Object -Unique)
    $maxHz = 0; if ($rates.Count) { $maxHz = [int]$rates[$rates.Count - 1] }
    # the highest rate of any mode of the screen, whatever the resolution
    $topHz = 0; $topW = 0; $topH = 0
    foreach ($m in @($Modes)) { if ([int]$m[2] -gt $topHz) { $topHz = [int]$m[2]; $topW = [int]$m[0]; $topH = [int]$m[1] } }
    return @{ W = $w; H = $h; Hz = $hz; MaxHzHere = $maxHz; RatesHere = $rates; Biggest = $best; TopHz = $topHz; TopW = $topW; TopH = $topH; ModeCount = @($Modes).Count }
}
# "ACI27A3" (from "MONITOR\ACI27A3\{4d36e96e-...}\0004") -> the code of the monitor model
function Sys-MonitorCode {
    param([string]$DeviceId)
    $p = @([string]$DeviceId -split '\\')
    if ($p.Count -ge 2) { return $p[1].ToUpperInvariant() }
    return ''
}
$script:SysVendors = @{ ACI = 'ASUS'; AUS = 'ASUS'; AOC = 'AOC'; GSM = 'LG'; SAM = 'Samsung'; DEL = 'Dell'; BNQ = 'BenQ'; GBT = 'Gigabyte'; MSI = 'MSI'; ACR = 'Acer'
                        LEN = 'Lenovo'; HWP = 'HP'; VSC = 'ViewSonic'; PHL = 'Philips'; AUO = 'AU Optronics'; CMN = 'Chimei'; LGD = 'LG Display'; NVD = 'NVIDIA'; ENC = 'Eizo'
                        MEG = 'MSI'; XMI = 'Xiaomi'; KOG = 'Koorui'; ECO = 'ECO' }
# A readable monitor name from the model code and the name in its EDID; the maker is put in front when the name does not have it
function Sys-MonitorName {
    param([string]$Code, [string]$Friendly)
    $f = ([string]$Friendly).Trim()
    $mk = ''
    if ($Code.Length -ge 3) { $mk = [string]$script:SysVendors[$Code.Substring(0, 3)] }
    if (-not $f) { if ($mk) { return ($mk + ' monitor (' + $Code + ')') }; return '' }
    if ($mk -and $f -notmatch ('^' + [regex]::Escape($mk))) { return ($mk + ' ' + $f) }
    return $f
}
# monitor model code -> name, from the EDID that Windows keeps (WMI root\wmi)
function Sys-MonitorNames {
    $h = @{}
    try {
        foreach ($m in @(Get-CimInstance -Namespace 'root\wmi' -ClassName WmiMonitorID -ErrorAction Stop)) {
            $inst = @(([string]$m.InstanceName) -split '\\')
            if ($inst.Count -lt 2) { continue }
            $bytes = @($m.UserFriendlyName | Where-Object { $_ -ne 0 } | ForEach-Object { [byte]$_ })
            $name = ''
            if ($bytes.Count) { $name = [System.Text.Encoding]::ASCII.GetString([byte[]]$bytes) }
            $code = $inst[1].ToUpperInvariant()
            if (-not $h.ContainsKey($code) -or $name) { $h[$code] = (Sys-MonitorName $code $name) }
        }
    } catch { }
    return $h
}
function Get-SysDisplays {
    $r = @{ Why = ''; List = @() }
    $why = Sys-Ensure 'Disp'
    if ($why) { $r.Why = $why; return $r }
    $color = @{}
    if ((Sys-Ensure 'Color') -eq '') {
        try {
            foreach ($l in @([SysColor]::Query())) {
                $p = @(([string]$l) -split '\|')
                if ($p.Count -ge 7) { $color[$p[0]] = @{ Supported = ($p[1] -eq '1'); Enabled = ($p[2] -eq '1'); WideOnly = ($p[3] -eq '1'); Bits = [int]$p[4]; Num = [double]$p[5]; Den = [double]$p[6] } }
            }
        } catch { }
    }
    $names = Sys-MonitorNames
    $list = @()
    try {
        foreach ($sc in @([SysDisp]::Screens())) {
            $p = @(([string]$sc) -split '\|')
            $dev = [string]$p[0]
            $cur = @(([string][SysDisp]::Current($dev)) -split '\|')
            if ($cur.Count -lt 4) { continue }
            $modes = @()
            foreach ($m in @([SysDisp]::Modes($dev))) { $q = @(([string]$m) -split '\|'); if ($q.Count -ge 3) { $modes += ,@([int]$q[0], [int]$q[1], [int]$q[2]) } }
            $sum = Sys-ModeSummary @([int]$cur[0], [int]$cur[1], [int]$cur[2], [int]$cur[3]) $modes
            $code = Sys-MonitorCode ([string]$p[2])
            $nm = [string]$names[$code]
            if (-not $nm) { $nm = ([string]$p[3]).Trim() }
            $hdr = 'unknown'
            $exact = $null
            $c = $color[$dev]
            if ($c) {
                if (-not $c.Supported) { $hdr = 'none' } elseif ($c.Enabled -and -not $c.WideOnly) { $hdr = 'on' } else { $hdr = 'off' }
                if ($c.Den -gt 0 -and $c.Num -gt 0) { $exact = [Math]::Round($c.Num / $c.Den, 3) }
            }
            $list += ,@{ Device = $dev; Primary = ($p[1] -eq '1'); Name = $nm; Code = $code; Bits = [int]$cur[3]; Summary = $sum; Hdr = $hdr; HzExact = $exact }
        }
    } catch { $r.Why = [string]$_.Exception.Message }
    $r.List = $list
    return $r
}

# ---- one pass over the live numbers ----
function Get-SysLive {
    param([int]$Round, $Static)
    $o = @{ At = (Get-Date); CpuUsage = $null; CpuClockMHz = $null; Procs = $null; Threads = $null; RamUsedMB = $null; RamTotalMB = $null; Uptime = $null
            Gpu = $null; Sensors = $null; Hwi = $false; HwiVia = ''; HwiWhy = ''; Lhm = $false; Smi = ''; Displays = $null; Storage = $null; Timer = $null; Mouse = $null; UsbSs = $null; FastStart = $null }
    if ($null -eq $script:SysPc) {
        $script:SysPc = Sys-PcNew
        Start-Sleep -Milliseconds 700          # a rate counter needs two readings a little apart
    }
    $pc = $script:SysPc
    $u = Sys-PcRead $pc.CpuUtil
    if ($null -eq $u) { try { $u = [double]@(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)[0].LoadPercentage } catch { } }
    if ($null -ne $u) { $o.CpuUsage = [Math]::Min(100.0, [Math]::Max(0.0, [Math]::Round($u, 0))) }
    $o.CpuClockMHz = Sys-CpuClock (Sys-PcRead $pc.CpuFreq) (Sys-PcRead $pc.CpuPerf)
    $np = Sys-PcRead $pc.Procs
    if ($null -eq $np) { try { $np = @(Get-Process).Count } catch { } }
    if ($null -ne $np) { $o.Procs = [int]$np }
    $nt = Sys-PcRead $pc.Threads
    if ($null -ne $nt) { $o.Threads = [int]$nt }
    $tot = 0; if ($Static -and $Static.Os) { $tot = [int]$Static.Os.TotalMB }
    $av = Sys-PcRead $pc.MemAvail
    if ($tot -gt 0) { $o.RamTotalMB = $tot; if ($null -ne $av) { $o.RamUsedMB = [Math]::Max(0, $tot - [int]$av) } }
    if ($Static -and $Static.Os -and $Static.Os.Boot) { try { $o.Uptime = [int]((Get-Date) - $Static.Os.Boot).TotalSeconds } catch { } }
    # the graphics card
    $g = $null
    try { $g = Sys-GpuNvidia } catch { }
    if (-not $g) { try { $g = Sys-GpuWindows } catch { } }
    $o.Gpu = $g
    $o.Smi = [string]$script:SysSmi
    # the tick of Windows' clock changes whenever a program asks for another one, so it is read in every pass (it only asks)
    try { $o.Timer = Sys-TimerRead } catch { }
    # sensors
    $hwi = $null; $lhm = $null
    try { $hwi = Sys-ReadHwi } catch { }
    try { $lhm = Sys-ReadLhm } catch { }
    if ($hwi) { $o.Hwi = [bool]$hwi.Running; $o.HwiVia = [string]$hwi.Via; $o.HwiWhy = [string]$hwi.Why }
    if ($lhm) { $o.Lhm = [bool]$lhm.Running }
    try { $o.Sensors = Sys-PickSensors $hwi $lhm } catch { }
    # the screens: every 5th round (the list of modes is long and changes rarely)
    if ($Round % 5 -eq 0) { try { $o.Displays = Get-SysDisplays } catch { } }
    # the drives' temperature and wear change slowly and take a moment to ask for: every 5th round as well
    if ($Round % 5 -eq 0) { $sd = $null; if ($Static) { $sd = $Static.Storage }; try { $o.Storage = Sys-StorageLive $sd } catch { } }
    # the mouse settings: every pass (three registry values); USB selective suspend runs powercfg, so every 5th round like the drives
    try { $o.Mouse = Get-SysMouse } catch { }
    try { $o.FastStart = Get-SysFastStartup } catch { }
    if ($Round % 5 -eq 0) { try { $o.UsbSs = Get-SysUsbSuspend } catch { } }
    return $o
}

# The background reader: the PC once, then the live numbers every two seconds for as long as the window is open.
# Shared state (set by the host): Stop (the host wants it to end), Active (the Home or Display page is showing: only then are the live
# numbers read), Ver (counts every new Live), Static, Live, Displays.
function Invoke-SysLoop {
    try { $SysShared.Static = Get-SysStatic } catch { }
    $SysShared.Ver = [int]$SysShared.Ver + 1
    # the clock facts come after the cards have their first data (asking for them takes a moment); the next live pass draws them
    try { $SysShared.Clock = Get-SysClock } catch { }
    # VBS, memory integrity and the IOMMU do not change while Windows runs either: read once, after the clock
    try { $SysShared.Sec = Get-SysSec } catch { }
    $round = 0
    $lastDisp = $null
    $lastSto = $null
    $lastUsb = $null
    while (-not $SysShared.Stop) {
        if ($SysShared.Force) { $SysShared.Force = $false; $round = 0 }
        if ($SysShared.Active) {
            try {
                $live = Get-SysLive $round $SysShared.Static
                if ($live.Displays) { $lastDisp = $live.Displays } else { $live.Displays = $lastDisp }
                if ($null -ne $live.Storage) { $lastSto = $live.Storage } else { $live.Storage = $lastSto }
                if ($null -ne $live.UsbSs) { $lastUsb = $live.UsbSs } else { $live.UsbSs = $lastUsb }
                $SysShared.Live = $live
                $SysShared.Ver = [int]$SysShared.Ver + 1
            } catch { }
            $round++
        }
        for ($i = 0; $i -lt 20 -and -not $SysShared.Stop -and -not $SysShared.Force; $i++) { Start-Sleep -Milliseconds 100 }
    }
}

}   # ---- end of $sysEngine ----

# =============================================================================
# THE LIST: what is ticked, what will change, what the texts say.
# Nothing in this part touches a control, so it works the same in the window and in the console.
# =============================================================================
$script:Rows = [ordered]@{}     # setting id -> row
$script:Cats = @()              # category names, in catalog order
$script:Scanning = $false       # the check of the PC is running
$script:Applying = $false       # changes are being made
$script:Building = $false       # the list is being filled in; ignore tick events
# One page of the side menu is not a list of settings but a read-out (an "info page"): the Home page the app opens to. It takes the
# place of a category name in $script:NavCat.
$script:PageHome = '#home'
function Test-InfoPage { param([string]$cat) return ($cat -eq $script:PageHome) }

# A row:  T = the catalog entry, State = Checking|On|Off|Partial|NA|Unknown, Detail = text from the check,
#         Want = is the box ticked, Force = 'Undo' when "put fully back" was chosen for a partly applied one,
#         Choice / Pick = for a setting with options (T.Choices): the option that is in force now, and the one that is chosen on the card
#         ('' while it is not known or when the values match no option),
#         Note/NoteDetail = result of the last run, Item = the list line (or $null), Visible = shown by the filter
function New-Rows {
    $script:Rows = [ordered]@{}
    $script:Cats = @()
    foreach ($t in $script:Catalog) {
        $script:Rows[$t.Id] = @{ T = $t; State = 'Checking'; Detail = 'Checking...'; Want = $false; Force = ''; Choice = ''; Pick = ''
                                 Note = ''; NoteDetail = ''; Item = $null; Visible = $true; Read = ''; Mine = '' }
        if ($script:Cats -notcontains $t.Cat) { $script:Cats += $t.Cat }
    }
}

# Programs come and go on the startup list. Before a new check, look at the PC again and bring the
# rows in line with it (rows for programs that are gone disappear, new ones appear as "Checking...").
# The background worker builds its own catalog the same way, so both sides end up with the same list.
function Sync-StartupRows {
    Add-StartupTweaks
    $fresh = [ordered]@{}
    $script:Cats = @()
    foreach ($t in $script:Catalog) {
        $old = $script:Rows[$t.Id]
        if ($old) {
            $old.T = $t
            $fresh[$t.Id] = $old
        } else {
            $fresh[$t.Id] = @{ T = $t; State = 'Checking'; Detail = 'Checking...'; Want = $false; Force = ''; Choice = ''; Pick = ''
                               Note = ''; NoteDetail = ''; Item = $null; Visible = $true; Read = ''; Mine = '' }
        }
        if ($script:Cats -notcontains $t.Cat) { $script:Cats += $t.Cat }
    }
    $script:Rows = $fresh
}

# 'Apply' (move the setting to this app's position), 'Undo' (put the Windows default back) or '' (nothing to do) for one row.
# What that does to the SWITCH depends on the setting: see Get-SwitchGoesOn.
function Get-Action {
    param($row)
    if ($row.State -eq 'Checking' -or $row.State -eq 'NA') { return '' }
    if ($row.Force) { return [string]$row.Force }
    if ($row.T.Choices) {
        # a setting with options: nothing to do while the option on the card is the one in force; the Windows default means undo
        $now = ''
        if ($row.State -eq 'On') { $now = [string]$row.Choice } elseif ($row.State -eq 'Off') { $now = 'default' }
        $pick = [string]$row.Pick
        if (-not $pick -or $pick -eq $now) { return '' }
        if ($pick -eq 'default') { return 'Undo' }
        return 'Apply'
    }
    $cur = ($row.State -eq 'On')
    if ($row.Want -and -not $cur) { return 'Apply' }
    if (-not $row.Want -and $cur) { return 'Undo' }
    return ''
}

# A row that is neither "applied" nor "not applied": a setting with options (a fix to use only when you have the problem, like Multiplane
# Overlay, or the update options for Store apps) that sits on its Windows default option, or a run-once action (a clean-up) that has not
# been asked for, while nothing asks for anything else (nothing lined up, not in the saved configuration). The default is the intended
# state there, so there is nothing to apply; the row is only counted under All settings, and again as soon as something is lined up.
function Test-NothingToApply {
    param($row)
    if ([string]$row.State -ne 'Off') { return $false }
    if (-not $row.T.Choices -and -not $row.T.Once) { return $false }
    if (Get-Action $row) { return $false }
    if ($script:Personal.Picks.ContainsKey([string]$row.T.Id)) { return $false }
    return $true
}

function Get-BusyReason {
    if ($script:Scanning) { return 'Please wait - still checking your PC.' }
    if ($script:Applying) { return 'Please wait - changes are being made.' }
    return ''
}

# '' when the row may be changed now, otherwise the reason it may not
function Test-CanChange {
    param($row)
    $b = Get-BusyReason
    if ($b) { return $b }
    if ($row.State -eq 'Checking') { return 'Still checking this one.' }
    if ($row.State -eq 'NA') { return ('Not available on this PC: ' + $row.Detail) }
    return ''
}

# The user ticked (want = true) or unticked (false) a box. Returns '' when accepted, else why not.
function Try-SetWant {
    param([string]$id, [bool]$want)
    $row = $script:Rows[$id]
    if (-not $row) { return 'Unknown setting.' }
    $why = Test-CanChange $row
    if ($why) { return $why }
    if ((-not $want) -and $row.State -eq 'On' -and $row.T.OneWay) {
        return ('"' + $row.T.Name + '" cannot be switched back on from here. Its description says how to get it back.')
    }
    if ($row.T.Choices) {
        # no single switch: "off" means the Windows default; "on" is not guessed, one of the options has to be picked
        if ($want) { return ('"' + $row.T.Name + '" has several options: pick one on its card.') }
        return (Try-SetPick $id 'default')
    }
    $row.Want = $want
    $row.Force = ''
    $row.Note = ''
    $row.NoteDetail = ''
    return ''
}

# The user picked one option of a setting that has options. Returns '' when accepted, else why not.
function Try-SetPick {
    param([string]$id, [string]$key)
    $row = $script:Rows[$id]
    if (-not $row) { return 'Unknown setting.' }
    if (-not $row.T.Choices) { return 'This setting has no options.' }
    $why = Test-CanChange $row
    if ($why) { return $why }
    $found = $false
    foreach ($c in @($row.T.Choices)) { if ([string]$c.Key -eq $key) { $found = $true } }
    if (-not $found) { return 'Unknown option.' }
    $row.Pick = $key
    $row.Want = ($key -ne 'default')
    $row.Force = ''
    $row.Note = ''
    $row.NoteDetail = ''
    return ''
}

# "Put this one fully back" for a partly applied (or applied) setting
function Try-ForceUndo {
    param([string]$id)
    $row = $script:Rows[$id]
    if (-not $row) { return 'Unknown setting.' }
    $why = Test-CanChange $row
    if ($why) { return $why }
    if ($row.T.OneWay) { return ('"' + $row.T.Name + '" cannot be undone from here.') }
    if ($row.State -eq 'Off') { return 'It is not applied, so there is nothing to undo.' }
    $row.Want = $false
    if ($row.T.Choices) { $row.Pick = 'default' }
    $row.Force = 'Undo'
    $row.Note = ''
    $row.NoteDetail = ''
    return ''
}

# A setting whose Windows default is the position the app applies (Game Mode on): switching it off turns the feature off for real
# (an explicit value is written) instead of putting the Windows default back.
function Test-OffIsExplicit {
    param($t)
    return ((-not [bool]$t.Inv) -and [string]$t.Def -eq 'On')
}

# Tick or untick everything in one group that the filter is showing. Returns how many rows changed.
function Set-GroupWant {
    # $cat = '' means every page ("All settings"). Never ticked in bulk: a run-once action (a clean-up), and the settings "Apply all" leaves
    # out on purpose (Get-ApplyAllSkip). "Turn all off" on "All settings" leaves those alone too.
    param([string]$cat, [bool]$want)
    $changed = 0
    foreach ($id in @($script:Rows.Keys)) {
        $row = $script:Rows[$id]
        if ($cat -and $row.T.Cat -ne $cat) { continue }
        if (-not $row.Visible) { continue }
        if ($row.T.Once) { continue }
        if ((Get-ApplyAllSkip $row $cat) -and ($want -or -not $cat)) { continue }
        # "Reset all" puts the Windows default back. For a setting whose Windows default is the position the app applies (Game Mode on),
        # that means making sure it is on: its off position turns the feature off for real, so it is not the default
        $w = $want
        if ((-not $want) -and (Test-OffIsExplicit $row.T)) { $w = $true }
        $before = Get-Action $row
        if ((Try-SetWant $id $w) -eq '') {
            if ((Get-Action $row) -ne $before) { $changed++ }
        }
    }
    return $changed
}

# The settings "Turn all on" leaves out on this page ($cat = '' for all of them): the ones "Apply all" leaves out, that are not on yet
function Get-GroupLeftOut {
    param([string]$cat)
    $left = @()
    foreach ($id in @($script:Rows.Keys)) {
        $row = $script:Rows[$id]
        if ($cat -and $row.T.Cat -ne $cat) { continue }
        if (-not $row.Visible -or $row.T.Once -or $row.State -eq 'NA' -or $row.State -eq 'On') { continue }
        if (Get-ApplyAllSkip $row $cat) { $left += [string]$row.T.Name }
    }
    return $left
}

# ------------------------------------------------------------ the presets ----
# The "Select Optimization Preset" button (bottom left) opens a window with three presets. A preset is a set of settings; applying one
# switches on the ones that are not on yet (after the list of changes has been shown and confirmed):
#   recommended  the settings marked T.Preset ("Recommended Debloat"); the window describes them in groups (see $script:RecommendedSummary)
#   advanced     the Recommended set plus $script:AdvancedExtra ("Advanced Debloat"): the further settings the user chose, in catalog
#                order by page. Every entry must be a setting id, and none may be a run-once or an option (Choices) setting.
#   personal     the settings the user saved from this PC ("Custom Preset"), kept in a file the user can take along
$script:PresetNames = @{ recommended = 'Recommended Debloat'; advanced = 'Advanced Debloat'; guided = 'Question Preset'; personal = 'Custom Preset' }
$script:AdvancedExtra = @(
    # Cloud, sync and OneDrive (all)
    'settingsync', 'clipboard', 'crossdevice', 'syncsvc', 'offlinefiles', 'onedrive-policy', 'onedrive-remove', 'deliveryopt',
    # Remote access and VPN (all)
    'rdp', 'remote-assist', 'quickassist', 'winrm', 'remote-mgmt', 'vpn',
    # Network adapters and USB power: the one Recommended leaves out
    'nic-turnoff',
    # Power plan and startup: Fast Startup and hibernation (the power plan switches are in no preset)
    'hibernate',
    # Gaming and performance (all but WPBT; Recommended has the rest)
    'wu-drivers',
    # Security prompts (all but BitLocker and automatic device encryption)
    'uac', 'uac-lua', 'vbs', 'hypervisor',
    # Services (all that are in the Advanced preset; Recommended has the other six)
    'svc-search', 'svc-smartcard', 'printing', 'xbox-svc',
    # File Explorer opens to This PC
    'launchto',
    # AI features (all)
    'ai-core',
    # Remove apps (all but Snipping Tool, Xbox app and sign-in, and the Microsoft Store)
    'apps-ai', 'apps-news', 'apps-mail', 'apps-phone', 'apps-media', 'apps-notes', 'apps-extras', 'apps-widgets', 'apps-promo',
    'apps-dolby', 'apps-gamebar', 'apps-clock', 'apps-startexp', 'apps-camera', 'apps-paint', 'apps-recorder',
    # more services and the four scheduled tasks
    'svc-smsrouter', 'svc-scpolicy', 'svc-biometric', 'svc-sensormon', 'svc-sensordata',
    'task-sqm', 'task-maps', 'task-familysafety', 'task-powerdiag'
)
# the warning for Advanced Debloat: shown in its part of the window, and (with Yes / No) before it does anything
$script:AdvancedWarningText = 'Advanced Debloat is only recommended for PCs that are used mainly for gaming.' + "`r`n" + "`r`n" +
    'It can switch off services and features that other uses of this PC need (work, printing, remote access, virtual machines, ' +
    'sharing and so on). If you also use this PC for anything besides gaming, use Recommended Debloat instead.'
$script:AdvancedWarning = $script:AdvancedWarningText + "`r`n" + "`r`n" +
    'Yes = go on: the list of changes is shown next and nothing is changed before you confirm it.' + "`r`n" + 'No = cancel.'
# the saved Custom Preset: Picks = setting id -> the option picked on its card ('' for a plain on/off setting), Saved = when,
# Source = the file it was saved to or opened from ('' when it is only kept inside the app)
$script:Personal = @{ Saved = ''; Picks = @{}; Source = '' }

# Is this row in the preset? ($key: recommended | advanced | personal)
function Test-InPreset {
    param($row, [string]$key)
    $id = [string]$row.T.Id
    switch ($key) {
        'recommended' { return [bool]$row.T.Preset }
        'advanced'    { return ([bool]$row.T.Preset -or (@($script:AdvancedExtra) -contains $id)) }
        'personal'    { return $script:Personal.Picks.ContainsKey($id) }
        'guided'      { return (Get-GuidedSets).Final.ContainsKey($id) }       # worked out from the answers (u1b-guided.ps1)
    }
    return $false
}

# Tick the settings of a preset that are not applied yet. Returns how many rows are now waiting to be turned on.
function Select-PresetKey {
    param([string]$key)
    $n = 0
    foreach ($id in @($script:Rows.Keys)) {
        $row = $script:Rows[$id]
        if (-not (Test-InPreset $row $key)) { continue }
        if ($row.T.Once) { continue }          # a run-once action (a clean-up) is never part of a preset
        $pick = ''
        if ($row.T.Choices) { $pick = [string]$script:Personal.Picks[[string]$id] }
        if ($row.T.Choices -and $pick) {
            if ($row.State -eq 'On' -and [string]$row.Choice -eq $pick) { continue }
            if ((Try-SetPick $id $pick) -eq '' -and (Get-Action $row) -eq 'Apply') { $n++ }
            continue
        }
        if ($row.State -eq 'On') { continue }
        if ((Try-SetWant $id $true) -eq '') { $n++ }
    }
    if ($key -eq 'guided') {
        # the questions answered Use default: their settings that are not at the Windows default are put back (see Get-GuidedResetAction)
        foreach ($row in @(Get-GuidedResetRows)) {
            $id = [string]$row.T.Id
            $act = Get-GuidedResetAction $row
            $r = ''
            if ($act -eq 'Apply') { $r = Try-SetWant $id $true }
            elseif ([string]$row.State -eq 'Partial') { $r = Try-ForceUndo $id }
            else { $r = Try-SetWant $id $false }
            if ($r -eq '') { $n++ }
        }
    }
    return $n
}

# Tick everything of the Recommended preset that is not applied yet. Returns how many rows were ticked.
function Select-Preset { return (Select-PresetKey 'recommended') }

# The settings that are on in the window right now (applied, or waiting to be turned on, and not waiting to be turned off):
# what the Custom Preset saves. Returns setting id -> picked option ('' for a plain setting). Run-once actions are not part of it.
function Get-PersonalCapture {
    $cap = [ordered]@{}
    foreach ($id in @($script:Rows.Keys)) {
        $row = $script:Rows[$id]
        if ($row.T.Once -or $row.State -eq 'NA' -or $row.State -eq 'Checking') { continue }
        $act = Get-Action $row
        if ($row.T.Choices) {
            $k = [string]$row.Pick
            if (-not $k) { if ($row.State -eq 'On') { $k = [string]$row.Choice } }
            if ($k -and $k -ne 'default') { $cap[[string]$id] = $k }
            continue
        }
        if (($row.State -eq 'On' -and $act -ne 'Undo') -or $act -eq 'Apply') { $cap[[string]$id] = '' }
    }
    return $cap
}

# Where the Custom Preset is kept inside the app: beside the undo record
function Get-PersonalPath {
    if ($script:PersonalFile) { return [string]$script:PersonalFile }
    if ($StorePath) { return (Join-Path ([IO.Path]::GetDirectoryName([string]$StorePath)) 'personal-preset.xml') }
    return ''
}

# Make these picks (setting id -> option) the Custom Preset, and keep a copy beside the undo record so that it is there the next
# time the window opens. Returns '' when the copy was written, else why not (it is then only kept until the window closes).
function Set-Personal {
    param($picks, [string]$saved, [string]$source = '')
    $script:Personal = @{ Saved = $saved; Picks = $picks; Source = $source }
    $p = Get-PersonalPath
    if (-not $p) { return 'There is no place to keep it.' }
    try {
        $dir = [IO.Path]::GetDirectoryName($p)
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $ids = @($picks.Keys | Sort-Object)
        $keys = @($ids | ForEach-Object { [string]$picks[$_] })
        Export-Clixml -InputObject @{ Saved = $saved; Source = $source; Ids = [string[]]$ids; Keys = [string[]]$keys } -LiteralPath $p -Depth 4 -Force -ErrorAction Stop
        return ''
    } catch { return $_.Exception.Message }
}

# Make $cap (setting id -> option, from Get-PersonalCapture) the Custom Preset inside the app. Returns '' or why the copy could not be kept.
function Save-Personal {
    param($cap, [string]$source = '')
    $picks = @{}
    foreach ($k in @($cap.Keys)) { $picks[[string]$k] = [string]$cap[$k] }
    return (Set-Personal $picks ((Get-Date).ToString('yyyy-MM-dd HH:mm')) $source)
}

# Read the Custom Preset kept inside the app (if there is one). Never throws: a missing or damaged copy means none.
function Load-Personal {
    $script:Personal = @{ Saved = ''; Picks = @{}; Source = '' }
    $p = Get-PersonalPath
    if (-not $p -or -not (Test-Path -LiteralPath $p)) { return }
    try {
        $x = Import-Clixml -LiteralPath $p -ErrorAction Stop
        $ids = @($x.Ids); $keys = @($x.Keys)
        $picks = @{}
        for ($i = 0; $i -lt $ids.Count; $i++) {
            $k = ''
            if ($i -lt $keys.Count) { $k = [string]$keys[$i] }
            if ([string]$ids[$i]) { $picks[[string]$ids[$i]] = $k }
        }
        $script:Personal = @{ Saved = [string]$x.Saved; Picks = $picks; Source = [string]$x.Source }
    } catch { $script:Personal = @{ Saved = ''; Picks = @{}; Source = '' } }
}

# ---- the configuration file: the Custom Preset in a file the user keeps, so that it survives a clean install of Windows.
# Plain JSON (readable in Notepad): the format name, a version, when it was saved and each setting's id, name and option.
$script:ConfigFormat = 'Headroom configuration'
$script:ConfigFormatOld = 'FasterWin configuration'     # what the files saved before the app was called Headroom say; they are still read
$script:ConfigVersion = 1

# Write the settings in $cap (setting id -> option) to $Path. When the file was written the same settings also become the Custom
# Configuration inside the app. Returns @{ Error; Saved; Count; PersonalError }: Error is '' when the file was written.
function Save-Configuration {
    param([string]$Path, $cap)
    $saved = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    $res = @{ Error = ''; Saved = $saved; Count = @($cap.Keys).Count; PersonalError = '' }
    if (-not $Path) { $res.Error = 'No file was chosen.'; return $res }
    $list = @()
    $picks = @{}
    foreach ($k in @($cap.Keys)) {
        $nm = ''
        if ($script:ById[[string]$k]) { $nm = [string]$script:ById[[string]$k].Name }
        $list += [pscustomobject]@{ Id = [string]$k; Name = $nm; Option = [string]$cap[$k] }
        $picks[[string]$k] = [string]$cap[$k]
    }
    try {
        $doc = [ordered]@{ Format = $script:ConfigFormat; Version = $script:ConfigVersion; Saved = $saved; Count = $list.Count; Settings = @($list) }
        $json = ConvertTo-Json -InputObject $doc -Depth 5
        $dir = [IO.Path]::GetDirectoryName($Path)
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        [IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch { $res.Error = $_.Exception.Message; return $res }
    $res.PersonalError = Set-Personal $picks $saved $Path
    return $res
}

# Read a configuration file without changing anything. Returns @{ Ok; Error; Saved; Picks; Count; Skipped }: Picks = setting id -> option
# for the settings this version of the app knows, Skipped = how many in the file it does not know.
function Read-Configuration {
    param([string]$Path)
    $r = @{ Ok = $false; Error = ''; Saved = ''; Picks = @{}; Count = 0; Skipped = 0 }
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { $r.Error = 'The file was not found.'; return $r }
    $doc = $null
    try { $doc = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path)) -ErrorAction Stop } catch { $doc = $null }
    if (-not $doc -or ([string]$doc.Format -ne $script:ConfigFormat -and [string]$doc.Format -ne $script:ConfigFormatOld)) { $r.Error = 'This is not a Headroom configuration file.'; return $r }
    $ver = 0
    [void][int]::TryParse([string]$doc.Version, [ref]$ver)
    if ($ver -lt 1) { $r.Error = 'This is not a Headroom configuration file.'; return $r }
    if ($ver -gt $script:ConfigVersion) { $r.Error = 'This file was saved by a newer version of Headroom. Update the app, then open it again.'; return $r }
    foreach ($it in @($doc.Settings)) {
        $id = [string]$it.Id
        if (-not $id) { continue }
        if ($script:ById[$id]) { $r.Picks[$id] = [string]$it.Option } else { $r.Skipped++ }
    }
    if ($r.Picks.Count -eq 0) { $r.Error = 'The file has no settings that this version of Headroom knows.'; return $r }
    $r.Ok = $true
    $r.Saved = [string]$doc.Saved
    $r.Count = $r.Picks.Count
    return $r
}

# Open a configuration file and make it the Custom Preset (inside the app too). Returns what Read-Configuration returns,
# plus PersonalError ('' unless the copy inside the app could not be kept; the opened configuration is used either way).
function Open-Configuration {
    param([string]$Path)
    $r = Read-Configuration $Path
    $r.PersonalError = ''
    if (-not $r.Ok) { return $r }
    $saved = [string]$r.Saved
    if (-not $saved) { $saved = (Get-Item -LiteralPath $Path).LastWriteTime.ToString('yyyy-MM-dd HH:mm') }
    $r.PersonalError = Set-Personal $r.Picks $saved $Path
    return $r
}

# The names of the saved Custom Preset's settings that exist on this PC now (in catalog order), and which of them are not on yet
function Get-PersonalInfo {
    $names = @(); $off = @(); $na = 0
    foreach ($id in @($script:Rows.Keys)) {
        $row = $script:Rows[$id]
        if (-not (Test-InPreset $row 'personal')) { continue }
        $names += [string]$row.T.Name
        if ($row.State -eq 'NA') { $na++ }
        if ($row.State -ne 'NA' -and $row.State -ne 'On') { $off += [string]$row.T.Name }
        elseif ($row.T.Choices -and $row.State -eq 'On' -and [string]$row.Choice -ne [string]$script:Personal.Picks[[string]$id]) { $off += [string]$row.T.Name }
    }
    return @{ Names = $names; NotOn = $off; Na = $na; Saved = [string]$script:Personal.Saved; Source = [string]$script:Personal.Source }
}

# "Apply all": offered on "All settings" and on every group page (not while a search is showing).
# Left out of "Apply all" on purpose (the reason is shown in the question that is asked first).
$script:ApplyAllSkip = @{ 'uac-lua' = 'it can stop Settings, Calculator and other apps from opening'
                         'bitlocker' = 'it decrypts your drives, which is a decision of its own'
                         'mpo' = 'it is a fix for flicker and stutter, not a speed-up, so you choose it yourself'
                         'wu-auto' = 'its last option stops Windows from installing updates by itself, so you choose it yourself' }

# '' when "Apply all" takes this setting, otherwise why it does not. $cat is the page ('' = All settings).
# The Startup apps and the Testing settings are left out of "All settings" only: which programs start with Windows is your own
# choice and the Testing page holds untested ideas, so they are switched on in bulk only when you press Apply all on their own page.
# The untested services (-Untested) are on the Services page next to the others, so they are left out wherever they are listed.
function Get-ApplyAllSkip {
    param($row, [string]$cat = '')
    if (-not $cat -and [string]$row.T.Cat -like 'Startup apps*') { return 'which programs start with Windows is your own choice' }
    if (-not $cat -and [string]$row.T.Cat -eq $script:TestingCat) { return 'they are untested ideas from other debloat scripts, so you pick them yourself on the Testing page' }
    if ($row.T.Untested) { return 'they are untested ideas from other debloat scripts, so you pick them yourself' }
    $why = $script:ApplyAllSkip[[string]$row.T.Id]
    if ($why) { return [string]$why }
    return ''
}

# Is "Apply all" offered on this page? ($cat is '' for "All settings"; a search is not a page)
function Test-ApplyAllPage {
    param([string]$cat, [string]$searchText)
    if ($searchText) { return $false }
    if (Test-InfoPage $cat) { return $false }
    return $true
}

# Tick every setting on one page ($cat = '' means all of them) that "Apply all" takes. The filter buttons and the search
# box do not matter: it is the whole page. A waiting "turn off" on such a setting is cancelled.
# Returns  Ticked = how many will be turned on, Left = the settings left out (Name, Why) that are not on yet.
function Select-ApplyAll {
    param([string]$cat)
    $left = @()
    $startN = 0; $startWhy = ''
    $testN = 0; $testWhy = ''
    $untN = 0; $untWhy = ''
    $ticked = 0
    foreach ($id in @($script:Rows.Keys)) {
        $row = $script:Rows[$id]
        if ($cat -and [string]$row.T.Cat -ne $cat) { continue }
        if ($row.State -eq 'NA') { continue }
        if ($row.T.Once) { continue }          # a run-once action (a clean-up) is only ever started on purpose, never in bulk
        $why = Get-ApplyAllSkip $row $cat
        if ($why) {
            if ($row.State -ne 'On') {
                if ([string]$row.T.Cat -like 'Startup apps*') { $startN++; $startWhy = $why }
                elseif ($row.T.Untested) { $untN++; $untWhy = $why }
                elseif ([string]$row.T.Cat -eq $script:TestingCat) { $testN++; $testWhy = $why }
                else { $left += ,@{ Name = [string]$row.T.Name; Why = $why } }
            }
            continue
        }
        if ((Try-SetWant $id $true) -eq '') {
            if ((Get-Action $row) -eq 'Apply') { $ticked++ }
        }
    }
    if ($startN -gt 0) { $left += ,@{ Name = ('Startup apps ({0})' -f $startN); Why = $startWhy } }
    if ($testN -gt 0) { $left += ,@{ Name = ('Testing ({0})' -f $testN); Why = $testWhy } }
    if ($untN -gt 0) { $left += ,@{ Name = ('Untested settings ({0})' -f $untN); Why = $untWhy } }
    return @{ Ticked = $ticked; Left = $left }
}

# Throw away all waiting changes
function Reset-Ticks {
    foreach ($id in @($script:Rows.Keys)) {
        $row = $script:Rows[$id]
        $row.Want = ($row.State -eq 'On')
        $row.Pick = Get-RealPick $row
        $row.Force = ''
        $row.Note = ''
        $row.NoteDetail = ''
    }
}

# For a setting with options: the key of the option that is in force now ('' when the values match none, and for the others)
function Get-RealPick {
    param($row)
    if (-not $row.T.Choices) { return '' }
    if ($row.State -eq 'On') { return [string]$row.Choice }
    if ($row.State -eq 'Off') { return 'default' }
    return ''
}

# The state of a row was (re)checked. During the first check the tick follows the real state.
function Set-RowState {
    param([string]$id, [string]$state, [string]$detail, [bool]$followReality, [string]$choice = '', [string]$read = '', [string]$mine = '')
    $row = $script:Rows[$id]
    if (-not $row) { return }
    $row.State = $state
    $row.Detail = $detail
    $row.Choice = $choice
    $row.Read = $read          # what the check read from the PC (one line per value)
    $row.Mine = $mine          # 'yes' = this app changed it, 'no' = already like this (no undo record), '' = not known
    $row.Force = ''
    if ($followReality -or $state -eq 'NA') { $row.Want = ($state -eq 'On'); $row.Pick = Get-RealPick $row }
}

# The changes the user has queued, in catalog order:  @{ Id; Action = 'Apply'|'Undo' }  (+ Choice = the option to set, for a setting with options)
function Get-Pending {
    $out = @()
    foreach ($id in @($script:Rows.Keys)) {
        $row = $script:Rows[$id]
        $a = Get-Action $row
        if (-not $a) { continue }
        if ($row.T.Choices -and $a -eq 'Apply') { $out += ,@{ Id = $id; Action = $a; Choice = [string]$row.Pick } }
        else { $out += ,@{ Id = $id; Action = $a } }
    }
    return $out
}

function Get-Counts {
    $c = @{ Total = 0; On = 0; Off = 0; Idle = 0; RunOnce = 0; Partial = 0; NA = 0; Unknown = 0; Checking = 0; Apply = 0; Undo = 0; GoOn = 0; GoOff = 0; GoRun = 0 }
    foreach ($id in @($script:Rows.Keys)) {
        $row = $script:Rows[$id]
        $c.Total++
        switch ([string]$row.State) {
            'On'       { $c.On++ }
            'Off'      { if (Test-NothingToApply $row) { if ($row.T.Once) { $c.RunOnce++ } else { $c.Idle++ } } else { $c.Off++ } }
            'Partial'  { $c.Partial++ }
            'NA'       { $c.NA++ }
            'Checking' { $c.Checking++ }
            default    { $c.Unknown++ }
        }
        $a = Get-Action $row
        if ($a -eq 'Apply') { $c.Apply++ }
        if ($a -eq 'Undo') { $c.Undo++ }
        if ($a -and $row.T.Once) { $c.GoRun++ }
        elseif ($a -and -not $row.T.Choices) { if (Get-SwitchGoesOn $row.T ($a -eq 'Undo')) { $c.GoOn++ } else { $c.GoOff++ } }
    }
    return $c
}

# ---------------------------------------------------------------- the texts ----
# A power plan switch whose plan is the active one (Get-TweakState puts 'active' in Choice)
function Test-PlanActive {
    param($row)
    return [bool]($row -and $row.T -and $row.T.Plan -and [string]$row.State -eq 'On' -and [string]$row.Choice -eq 'active')
}
function Get-StateText {
    # What the setting is now, in the words of the switch: "On" / "Off". 'Already on' / 'Already off' = it was like this before this
    # app did anything (no undo record), so there is nothing of ours to take back. A power plan switch says Installed / Not installed.
    param($row)
    $t = $row.T
    if ($t -and $t.Plan) {
        switch ([string]$row.State) {
            'On'  { if (Test-PlanActive $row) { return 'Installed, active plan' } else { return 'Installed' } }
            'Off' { return 'Not installed' }
        }
    }
    $once = ($row.Once -or ($t -and $t.Once))
    switch ([string]$row.State) {
        'Checking' { return 'Checking...' }
        'On'       {
            $already = ($row.Mine -eq 'no')
            if ($t -and $t.Choices) { return ($(if ($already) { 'Already set: ' } else { 'Set: ' }) + (Get-ChoiceLabel $t ([string]$row.Choice))) }
            if ($t) {
                $w = 'Off'; if (Get-SwitchOn $t $true) { $w = 'On' }
                if ($already) { $w = 'Already ' + $w.ToLower() }
                return $w
            }
            if ($already) { return 'Already applied' }
            return 'Applied'
        }
        'Off'      {
            # a run-once action is never "applied": it is ready to be run
            if ($once) { return 'Ready to run' }
            if ($t -and $t.Choices) { return ('Windows default: ' + ((Get-ChoiceLabel $t 'default') -replace '\s*\(Windows default\)\s*$', '')) }
            if ($t) { if (Get-SwitchOn $t $false) { return 'On' } else { return 'Off' } }
            return 'Not applied'
        }
        'Partial'  { return 'Partly changed' }
        'NA'       { return 'Not on this PC' }
    }
    return 'Unknown'
}

function Get-NextText {
    param($row)
    if ($row.Note) { return [string]$row.Note }
    $a = Get-Action $row
    if ($row.T.Choices -and $a) { return ('Set to ' + (Get-ChoiceLabel $row.T ([string]$row.Pick))) }
    if ($a -eq 'Apply' -and $row.T.Once) { return 'Run now' }
    if ($a -and $row.T.Plan) { if ($a -eq 'Apply') { return 'Install' } else { return 'Delete' } }
    if ($a) { if (Get-SwitchGoesOn $row.T ($a -eq 'Undo')) { return 'Turn on' } else { return 'Turn off' } }
    return ''
}

function Get-HeadsUp {
    param($t)
    if ($t.OneWay) { return 'One-way' }
    if ($t.Risk -eq 'security') { return 'Lowers security' }
    if ($t.Risk -eq 'note') { return 'Has side effects' }
    return ''
}

function Get-SummaryText {
    $c = Get-Counts
    if ($c.Checking -gt 0) { return 'Checking your PC...' }
    $n = $c.Apply + $c.Undo
    $s = ('{0} settings: {1} applied, {2} not applied' -f ($c.Total - $c.NA), $c.On, ($c.Off + $c.Partial + $c.Unknown))
    if ($c.Idle -gt 0) { $s += (', {0} left on the Windows default' -f $c.Idle) }
    if ($c.RunOnce -gt 0) { $s += (', {0} run-once action{1} not run' -f $c.RunOnce, $(if ($c.RunOnce -eq 1) { '' } else { 's' })) }
    if ($c.NA -gt 0) { $s += (', {0} not on this PC' -f $c.NA) }
    if ($n -gt 0) {
        $s += ('.  {0} change(s) waiting: {1} to turn on, {2} to turn off' -f $n, $c.GoOn, $c.GoOff)
        if ($c.GoRun -gt 0) { $s += (', {0} to run once' -f $c.GoRun) }
        $s += '.'
    } else {
        $s += '.  Switch settings on or off to choose changes.'
    }
    return $s
}

function Get-GroupHeader {
    param([string]$cat)
    $tot = 0; $on = 0; $checking = 0
    foreach ($id in @($script:Rows.Keys)) {
        $row = $script:Rows[$id]
        if ($row.T.Cat -ne $cat) { continue }
        if ($row.State -eq 'NA') { continue }
        if ($row.State -eq 'Checking') { $checking++ }
        $tot++
        if ($row.State -eq 'On') { $on++ }
    }
    if ($checking -gt 0) { return $cat }
    return ('{0}   ({1} of {2} applied)' -f $cat, $on, $tot)
}

# The same counts for every group in one pass:  category -> @{ Total; On; Checking }  (settings that are not on this PC are left out)
function Get-GroupCounts {
    $h = @{}
    foreach ($id in @($script:Rows.Keys)) {
        $row = $script:Rows[$id]
        $cat = [string]$row.T.Cat
        if (-not $h.ContainsKey($cat)) { $h[$cat] = @{ Total = 0; On = 0; Checking = 0 } }
        if ($row.State -eq 'NA') { continue }
        $g = $h[$cat]
        if ($row.State -eq 'Checking') { $g.Checking++ }
        $g.Total++
        if ($row.State -eq 'On') { $g.On++ }
    }
    return $h
}
function Get-GroupCountText {
    param($g)
    if (-not $g -or $g.Checking -gt 0) { return '' }
    return ('{0} of {1} applied' -f $g.On, $g.Total)
}

# ---------------------------------------------------------------- names and counts for the window's pages ----
# Titles (pages, groups, cards and boxes - not the descriptions) show every word with a capital letter. Only the first letter of a word is
# changed, so OneDrive, HWiNFO, USB and (HAGS) stay as they are; file names and a few program names are left alone.
$script:TitleKeep = @('svchost.exe', 'ms-gamebar', 'nvidia-smi', 'x')
$script:TitleCache = @{}                 # (the same names are asked for again and again while the list is painted)
function Get-TitleCase {
    param([string]$s)
    if (-not $s) { return $s }
    if ($script:TitleCache.ContainsKey($s)) { return [string]$script:TitleCache[$s] }
    $ev = [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $m.Groups[1].Value + $m.Groups[2].Value.ToUpperInvariant() }
    $sb = New-Object System.Text.StringBuilder
    foreach ($tok in [regex]::Split($s, '(\s+)')) {
        $core = $tok.ToLowerInvariant().Trim('"', '(', ')', ',', ':', ';')
        if ($tok -eq '' -or $tok -match '^\s+$' -or $script:TitleKeep -contains $core -or $core -match '^[a-z0-9_-]+\.(exe|dll|sys|msc|com|ps1)$') { [void]$sb.Append($tok); continue }
        [void]$sb.Append([regex]::Replace($tok, '(^[^A-Za-z0-9]*|-|/)([a-z])', $ev))
    }
    $script:TitleCache[$s] = $sb.ToString()
    return $script:TitleCache[$s]
}

# A page name for a title: the name itself in capitals, the hint in brackets after it as it is
function Get-CatTitle {
    param([string]$cat)
    $i = $cat.IndexOf(' (')
    if ($i -gt 0 -and $cat.EndsWith(')')) { return ((Get-TitleCase $cat.Substring(0, $i)) + $cat.Substring($i)) }
    return (Get-TitleCase $cat)
}

# "Security prompts (turning these off lowers protection)" -> Short = "Security prompts", Hint = "Turning these off lowers protection"
function Split-CatName {
    param([string]$cat)
    if ($cat -eq $script:PageHome) { return @{ Short = 'Home'; Hint = '' } }
    $short = $cat
    $hint = ''
    $i = $cat.IndexOf(' (')
    if ($i -gt 0 -and $cat.EndsWith(')')) {
        $short = $cat.Substring(0, $i)
        $hint = $cat.Substring($i + 2, $cat.Length - $i - 3)
    }
    if ($hint -match '^switch off = does not start') { $hint = 'Turn a switch off to stop that program starting with Windows' }
    elseif ($hint.Length -gt 1) { $hint = $hint.Substring(0, 1).ToUpper() + $hint.Substring(1) }
    return @{ Short = $short; Hint = $hint }
}

# The name in the side menu (a few are shortened so that they fit; the page itself, and its title, carry the full name)
function Get-NavTitle {
    param([string]$cat)
    $s = (Split-CatName $cat).Short
    switch ($s) {
        'Privacy and telemetry' { return 'Privacy' }
        'Cloud, sync and OneDrive' { return 'Cloud and OneDrive' }
        'Network sharing and discovery' { return 'Network sharing' }
        'Network adapters and USB power' { return 'Adapters and USB' }
        'Power plan and startup' { return 'Power and startup' }
        'Remote access and VPN' { return 'Remote and VPN' }
        'Gaming and performance' { return 'Gaming' }
        'Legacy Windows features' { return 'Legacy features' }
        'Placebo Tweaks - Not Recommended' { return 'Placebo Tweaks' }
    }
    return $s
}

# The risk level of a setting: 'Risky' (lowers a protection), 'Medium risk' (has side effects, or cannot be undone from here),
# else 'Low risk'. "Low risk" is only what this script's own notes say; the description still tells the whole story.
function Get-RiskLevel {
    param($t)
    if ([string]$t.Risk -eq 'security') { return 'Risky' }
    if ([string]$t.Risk -eq 'note' -or [bool]$t.OneWay) { return 'Medium risk' }
    return 'Low risk'
}

# The badge on a card: the risk level and its colour name in the theme. The three risk filter buttons use the same three words.
function Get-RiskBadge {
    param($t)
    $l = Get-RiskLevel $t
    if ($l -eq 'Risky') { return @{ Text = $l; Key = 'Bad' } }
    if ($l -eq 'Medium risk') { return @{ Text = $l; Key = 'Warn' } }
    return @{ Text = $l; Key = 'Good' }
}

# "Not recommended": the setting is one this script's notes advise against switching on (no proven benefit, or it is known to
# break something common). Returns the reason, or '' when the setting is not marked. A setting marked -Unproven always counts,
# with the same reason its "May do nothing" tag stands for. The card shows the words next to its risk badge.
$script:NotRecText = 'Not recommended'
function Get-NotRecReason {
    param($t)
    if ([string]$t.NotRec) { return [string]$t.NotRec }
    if ([bool]$t.Unproven) { return 'No proven benefit: it may change nothing. The description says why.' }
    return ''
}

# The small tags on a card, most useful first
function Get-CardTags {
    param($t)
    $tags = @((Get-NavTitle ([string]$t.Cat)))
    # what the Windows default is, so the card shows whether the switch is on or off out of the box (a run-once action has none)
    if ([string]$t.Def) { $tags = @(('Windows default: ' + [string]$t.Def)) + $tags }
    if ($t.Reboot) { $tags += 'Needs restart' }
    if ($t.OneWay) { $tags += 'One-way' }
    if ($t.Once) { $tags += 'Runs once' }
    if ($t.Ask) { $tags += 'Asks first' }
    if ($t.Untested) { $tags += 'Untested' }
    # on the "Placebo Tweaks - Not Recommended" page the first tag already says it
    if ($t.Unproven -and (Get-NavTitle ([string]$t.Cat)) -ne 'Placebo Tweaks') { $tags += 'May do nothing' }
    if ($t.Preset) { $tags += 'Recommended preset' }
    return $tags
}

# How many settings each filter would show (for the numbers on the filter buttons). $cat = '' means all categories;
# $text is the search, which narrows every number the same way it narrows the list. The state buttons (All, Applied, ...) count
# within the risk button that is on ($risk); the risk buttons count within the state button that is on ($mode), so every number is
# what pressing that button next to the current choice would show.
function Get-ModeCounts {
    param([string]$cat = '', [string]$text = '', [string]$mode = 'All settings', [string]$risk = 'Any risk')
    $c = @{ 'All settings' = 0; 'Applied' = 0; 'Not applied' = 0; 'Waiting to change' = 0; 'Recommended' = 0; 'Personal' = 0; Checking = 0
            'Any risk' = 0; 'Low risk' = 0; 'Medium risk' = 0; 'Risky' = 0 }
    foreach ($id in @($script:Rows.Keys)) {
        $row = $script:Rows[$id]
        if ($cat -and [string]$row.T.Cat -ne $cat) { continue }
        if ($text -and -not (Test-RowVisible $row $text 'All settings')) { continue }
        $level = Get-RiskLevel $row.T
        if ($row.State -eq 'Checking') { $c.Checking++ }
        # the risk buttons: rows that the state button that is on lets through
        if (Test-RowVisible $row '' $mode) {
            $c['Any risk']++
            $c[$level]++
        }
        # the state buttons: rows that the risk button that is on lets through
        if ($risk -ne 'Any risk' -and $level -ne $risk) { continue }
        $c['All settings']++
        if ($row.State -eq 'On') { $c['Applied']++ }
        elseif (($row.State -eq 'Off' -and -not (Test-NothingToApply $row)) -or $row.State -eq 'Partial' -or $row.State -eq 'Unknown') { $c['Not applied']++ }
        if (Get-Action $row) { $c['Waiting to change']++ }
        if ($row.T.Preset) { $c['Recommended']++ }
        if ($script:Personal.Picks.ContainsKey([string]$row.T.Id)) { $c['Personal']++ }
    }
    return $c
}

# The big title and the line under it for the page that is showing ($shown = how many settings the list has)
function Get-PageInfo {
    param([string]$cat, [string]$text, [int]$shown)
    $c = Get-Counts
    if ($text) {
        return @{ Title = 'Search Results'; Sub = ('{0} setting(s) match "{1}"' -f $shown, $text) }
    }
    if ($cat -eq $script:PageHome) { return @{ Title = 'Home'; Sub = 'Your PC right now, every 2 seconds. Changes nothing on its own.' } }
    if ($c.Checking -gt 0) {
        $t = 'All Settings'
        if ($cat) { $t = Get-TitleCase (Split-CatName $cat).Short }
        return @{ Title = $t; Sub = 'Checking your PC...' }
    }
    if (-not $cat) {
        $s = ('{0} settings, {1} applied' -f ($c.Total - $c.NA), $c.On)
        $n = $c.Apply + $c.Undo
        if ($n -gt 0) { $s += (', {0} waiting to change' -f $n) }
        return @{ Title = 'All Settings'; Sub = $s }
    }
    $nm = Split-CatName $cat
    $g = (Get-GroupCounts)[$cat]
    $s = ''
    if ($g) { $s = ('{0} of {1} applied' -f $g.On, $g.Total) }
    if ($nm.Hint) { if ($s) { $s += '  -  ' }; $s += $nm.Hint }
    return @{ Title = (Get-TitleCase $nm.Short); Sub = $s }
}

# The text next to a setting, in styled pieces:  S = style (title|sub|now|wait|last|body|warn|note|head|mono),
# C = colour hint (good|warn|sub), T = the text. Get-DetailText joins them, so both always agree.
function Get-DetailParts {
    param($row)
    $t = $row.T
    $nl = "`r`n"
    $p = New-Object System.Collections.ArrayList
    $c = 'sub'
    if ([string]$row.State -eq 'On') { $c = 'good' }
    elseif ([string]$row.State -eq 'Partial' -or [string]$row.State -eq 'Unknown') { $c = 'warn' }
    [void]$p.Add(@{ S = 'title'; C = ''; T = (Get-TitleCase ([string]$t.Name)) + $nl })
    [void]$p.Add(@{ S = 'sub'; C = ''; T = (Get-CatTitle ([string]$t.Cat)) + $nl + $nl })
    $nowT = [string]$row.Detail
    if ($t.Plan -and ([string]$row.State -eq 'On' -or [string]$row.State -eq 'Off')) { $nowT = Get-StateText $row }     # a power plan: installed / not installed
    [void]$p.Add(@{ S = 'now'; C = $c; T = 'Now: ' + $nowT + $nl })
    # the switch, in words: where it is now and what Windows has out of the box
    if (-not $t.Once) {
        if ($t.Choices) {
            [void]$p.Add(@{ S = 'sub'; C = ''; T = ('Windows default: ' + (Get-ChoiceLabel $t 'default') + $nl) })
        } elseif ($row.State -eq 'On' -or $row.State -eq 'Off') {
            $sw = 'off'; if (Get-SwitchOn $t ($row.State -eq 'On')) { $sw = 'on' }
            [void]$p.Add(@{ S = 'sub'; C = ''; T = ('Switch: ' + $sw + '.   Windows default: ' + [string]$t.Def + $nl) })
        } else {
            [void]$p.Add(@{ S = 'sub'; C = ''; T = ('Windows default: ' + [string]$t.Def + $nl) })
        }
    }
    $explicit = (Test-OffIsExplicit $t)
    $a = Get-Action $row
    if ($t.Choices -and $a) {
        [void]$p.Add(@{ S = 'wait'; C = ''; T = ('Waiting: will be set to "' + (Get-ChoiceLabel $t ([string]$row.Pick)) + '" when you press the button' + $(if ($a -eq 'Undo') { ' (the Windows default is put back)' } else { '' }) + $nl) })
    } elseif ($a -eq 'Apply' -and $t.Once) { [void]$p.Add(@{ S = 'wait'; C = ''; T = 'Waiting: will run once when you press the button' + $nl }) }
    elseif ($a -and $t.Plan) {
        if ($a -eq 'Apply') { $wt = 'Waiting: will be installed when you press the button (the active plan stays the same)' }
        elseif (Test-PlanActive $row) { $wt = 'Waiting: will be deleted when you press the button; it is the active plan, so another plan is made active first' }
        else { $wt = 'Waiting: will be deleted when you press the button' }
        [void]$p.Add(@{ S = 'wait'; C = ''; T = $wt + $nl })
    }
    elseif ($a) {
        $dir = 'OFF'; if (Get-SwitchGoesOn $t ($a -eq 'Undo')) { $dir = 'ON' }
        $tail = ''
        if ($a -eq 'Undo' -and -not $explicit) { $tail = ' (the Windows default is put back)' }
        [void]$p.Add(@{ S = 'wait'; C = ''; T = ('Waiting: will be turned ' + $dir + $tail + ' when you press the button' + $nl) })
    }
    # the status lines stay at the top (where the setting is now, the switch and the Windows default, what is waiting), and the
    # description comes right under them, so it is the first thing to read
    [void]$p.Add(@{ S = 'body'; C = ''; T = $nl + $t.Desc + $nl + $nl })
    # below the description: the warnings and notes, what was found on this PC, and the exact values the setting changes
    $nr = Get-NotRecReason $t
    if ($nr) { [void]$p.Add(@{ S = 'warn'; C = ''; T = ($script:NotRecText + ': ' + $nr) + $nl }) }
    if ($t.Risk -eq 'security') { [void]$p.Add(@{ S = 'warn'; C = ''; T = 'Heads-up: this lowers a security protection. Read the description above before you change it.' + $nl }) }
    if ($t.Risk -eq 'note')     { [void]$p.Add(@{ S = 'warn'; C = ''; T = 'Heads-up: this has side effects. Read the description above before you change it.' + $nl }) }
    if ($t.OneWay) { [void]$p.Add(@{ S = 'warn'; C = ''; T = 'One-way: once it is switched off it cannot be switched back on from this window.' + $nl }) }
    if ($t.Unproven) { [void]$p.Add(@{ S = 'note'; C = ''; T = 'May have no effect: read the description above for why.' + $nl }) }
    if ($t.Reboot) { [void]$p.Add(@{ S = 'note'; C = ''; T = 'Needs a restart of the PC to take full effect.' + $nl }) }
    if ($t.Plan) {
        $pa = 'Not the active plan: "Make active" on its card switches to it.'
        if ([string]$row.State -ne 'On') { $pa = 'Not installed: switch it on (and apply) to install it; then "Make active" on its card switches to it.' }
        elseif (Test-PlanActive $row) { $pa = 'This is the active plan: the one Windows uses now.' }
        if ([string]$row.State -eq 'On') { $pa += ' "Reinstall" on its card makes it again the way Headroom installs it.' }
        [void]$p.Add(@{ S = 'note'; C = ''; T = $pa + $nl })
    }
    if ($t.Once -and -not $t.Cleanup) { [void]$p.Add(@{ S = 'note'; C = ''; T = 'One-time action: it runs when you press the button and has nothing to undo here (a restore point is created first). It is never part of Apply all, Tweak all or any preset.' + $nl }) }
    elseif ($t.Once)   { [void]$p.Add(@{ S = 'note'; C = ''; T = 'One-time action: it runs when you press the button, deletes files for good and has nothing to undo. It is never part of Apply all, Tweak all or any preset.' + $nl }) }
    elseif ($t.Preset) { [void]$p.Add(@{ S = 'note'; C = ''; T = 'Part of the Recommended preset (and so of Advanced Debloat).' + $nl }) }
    else           { [void]$p.Add(@{ S = 'note'; C = ''; T = 'Not part of the Recommended preset (change it yourself if you want it).' + $nl }) }
    if ([string]$row.State -eq 'On' -and $row.Mine -eq 'no') {
        $back = ' Switching it back puts the Windows default back.'
        if ($explicit) { $back = ' Switching it off turns it off.' }
        [void]$p.Add(@{ S = 'note'; C = ''; T = 'Already like this: Windows was already set this way when the app looked, or you set it yourself. The app has not changed it.' + $back + $nl })
    }
    if ([string]$row.State -eq 'On' -and $row.Mine -eq 'yes') {
        $back = 'switching it back puts the Windows default back.'
        if ($explicit) { $back = 'switching it off turns it off.' }
        [void]$p.Add(@{ S = 'note'; C = ''; T = 'Set by this app: ' + $back + $nl })
    }
    if ($row.NoteDetail) { [void]$p.Add(@{ S = 'last'; C = ''; T = 'Last result: ' + [string]$row.Note + ' - ' + [string]$row.NoteDetail + $nl }) }
    if ([string]$row.Read) {
        [void]$p.Add(@{ S = 'head'; C = ''; T = $nl + 'Read from your PC (the last check):' + $nl })
        foreach ($l in @(([string]$row.Read) -split "`n")) { if ($l.Trim()) { [void]$p.Add(@{ S = 'mono'; C = ''; T = '  ' + $l.TrimEnd() + $nl }) } }
    }
    [void]$p.Add(@{ S = 'head'; C = ''; T = $nl + 'What it changes:' + $nl })
    foreach ($l in @(Describe-Tweak $t)) { [void]$p.Add(@{ S = 'mono'; C = ''; T = '  ' + [string]$l + $nl }) }
    return $p
}
function Get-DetailText {
    param($row)
    $s = ''
    foreach ($x in @(Get-DetailParts $row)) { $s += [string]$x.T }
    return $s
}

# $mode: 'All settings' | 'Applied' | 'Not applied' | 'Waiting to change' | 'Recommended' | 'Personal'
# $risk: 'Any risk' | 'Low risk' | 'Medium risk' | 'Risky'   (both must let the row through)
function Test-RowVisible {
    param($row, [string]$text, [string]$mode, [string]$risk = 'Any risk')
    if ($risk -and $risk -ne 'Any risk' -and (Get-RiskLevel $row.T) -ne $risk) { return $false }
    if ($text) {
        $hay = $row.T.Name + ' ' + $row.T.Desc + ' ' + $row.T.Id + ' ' + $row.T.Cat
        if (Get-NotRecReason $row.T) { $hay += ' ' + $script:NotRecText }        # a search for "not recommended" finds the marked ones
        if ($row.T.Unproven) { $hay += ' May do nothing' }                       # ... and "may do nothing" and "untested" find the cards that carry those tags
        if ($row.T.Untested) { $hay += ' Untested' }
        if ($hay.IndexOf($text, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
    }
    switch ($mode) {
        'Applied'              { return ($row.State -eq 'On') }
        'Not applied'          { return (($row.State -eq 'Off' -and -not (Test-NothingToApply $row)) -or $row.State -eq 'Partial' -or $row.State -eq 'Unknown') }
        'Waiting to change'    { return [bool](Get-Action $row) }
        'Recommended'          { return [bool]$row.T.Preset }
        'Personal'             { return [bool]$script:Personal.Picks.ContainsKey([string]$row.T.Id) }
    }
    return $true
}

function Format-NameList {
    param($names, [int]$max = 12)
    $names = @($names)
    $nl = "`r`n"
    $s = ''
    $i = 0
    foreach ($n in $names) {
        $i++
        if ($i -gt $max) { $s += ('  ...and {0} more' -f ($names.Count - $max)) + $nl; break }
        $s += '  - ' + [string]$n + $nl
    }
    return $s
}

# The name of a planned change; a setting with options also says which option is set
function Get-PlanName {
    param($item)
    $t = $script:ById[[string]$item.Id]
    if ($t.Choices -and [string]$item.Action -eq 'Apply') {
        $k = [string]$item.Choice
        if (-not $k) { $k = [string](Resolve-Choice $t '').Key }
        return ('{0}: set to {1}' -f $t.Name, (Get-ChoiceLabel $t $k))
    }
    return [string]$t.Name
}

# The question asked before real changes are made
function Get-ConfirmText {
    param($Plan, [string]$Extra = '')
    $Plan = @($Plan)
    $nl = "`r`n"
    # "ON" / "OFF" are the positions the SWITCH goes to (a setting that turns its feature off when applied goes OFF when applied);
    # a setting with options is listed with the option it is set to
    $goesOn = { param($x) $tt = $script:ById[$x.Id]; if ($tt.Choices) { return ($x.Action -eq 'Apply') }; return [bool](Get-SwitchGoesOn $tt ($x.Action -eq 'Undo')) }
    $on = @($Plan | Where-Object { -not $script:ById[$_.Id].Once -and -not $script:ById[$_.Id].Plan -and (& $goesOn $_) } | ForEach-Object { Get-PlanName $_ })
    $pInst = @($Plan | Where-Object { $script:ById[$_.Id].Plan -and $_.Action -eq 'Apply' } | ForEach-Object { $script:ById[$_.Id].Name })
    $pDel = @($Plan | Where-Object { $script:ById[$_.Id].Plan -and $_.Action -eq 'Undo' } | ForEach-Object { $script:ById[$_.Id].Name })
    $run = @($Plan | Where-Object { $_.Action -eq 'Apply' -and $script:ById[$_.Id].Once -and $script:ById[$_.Id].Cleanup } | ForEach-Object { $script:ById[$_.Id].Name })
    $runOther = @($Plan | Where-Object { $_.Action -eq 'Apply' -and $script:ById[$_.Id].Once -and -not $script:ById[$_.Id].Cleanup } | ForEach-Object { $script:ById[$_.Id].Name })
    $off = @($Plan | Where-Object { -not $script:ById[$_.Id].Once -and -not $script:ById[$_.Id].Plan -and -not (& $goesOn $_) } | ForEach-Object { $script:ById[$_.Id].Name })
    $one = @($Plan | Where-Object { $_.Action -eq 'Apply' -and $script:ById[$_.Id].OneWay } | ForEach-Object { $script:ById[$_.Id].Name })
    $rb = @($Plan | Where-Object { $script:ById[$_.Id].Reboot } | ForEach-Object { $script:ById[$_.Id].Name })
    $s = ('Make {0} change(s) on this PC?' -f $Plan.Count) + $nl + $nl
    if ($Extra) { $s += $Extra + $nl }
    if ($on.Count)  { $s += ('Turn ON ({0}):' -f $on.Count) + $nl + (Format-NameList $on) + $nl }
    if ($run.Count) { $s += ('RUN once ({0}); files they delete are gone for good, they do not go to the Recycle Bin:' -f $run.Count) + $nl + (Format-NameList $run) + $nl }
    if ($runOther.Count) { $s += ('RUN once ({0}):' -f $runOther.Count) + $nl + (Format-NameList $runOther) + $nl }
    if ($off.Count) { $s += ('Turn OFF ({0}):' -f $off.Count) + $nl + (Format-NameList $off) + $nl }
    if ($pInst.Count) { $s += ('INSTALL ({0}); the active plan stays the same:' -f $pInst.Count) + $nl + (Format-NameList $pInst) + $nl }
    if ($pDel.Count) { $s += ('DELETE ({0}); if one is the active plan, another plan is made active first:' -f $pDel.Count) + $nl + (Format-NameList $pDel) + $nl }
    if ($one.Count) { $s += ('These cannot be switched back on from here ({0}):' -f $one.Count) + $nl + (Format-NameList $one 20) + $nl }
    if ($rb.Count)  { $s += 'A restart is needed afterwards for: ' + (($rb | Select-Object -First 6) -join ', ') + $(if ($rb.Count -gt 6) { ', ...' } else { '' }) + $nl + $nl }
    if (@($Plan | Where-Object { -not $script:ById[$_.Id].Once }).Count -gt 0) {
        $s += 'A restore point is created first. Putting a setting back later restores the Windows default.'
    } elseif ($runOther.Count) {
        $s += 'A restore point is created first. A one-time action has no undo here, but the restore point can bring back what it changed.'
    } else {
        $s += 'Nothing here can be undone, so no restore point is made.'
    }
    return $s
}

# The warning lists shared by the heads-up texts of "Apply all" and the presets: what lowers protection, what can stop something
# working, what may do nothing, which programs stop starting. $apply = the planned changes that turn something on.
function Get-NoteSections {
    param($apply)
    $nl = "`r`n"
    $apply = @($apply)
    $sec = @($apply | Where-Object { $script:ById[$_.Id].Risk -eq 'security' } | ForEach-Object { $script:ById[$_.Id].Name })
    $note = @($apply | Where-Object { $script:ById[$_.Id].Risk -eq 'note' } | ForEach-Object { $script:ById[$_.Id].Name })
    $dud = @($apply | Where-Object { $script:ById[$_.Id].Unproven } | ForEach-Object { $script:ById[$_.Id].Name })
    $start = @($apply | Where-Object { [string]$script:ById[$_.Id].Cat -like 'Startup apps*' } | ForEach-Object { $script:ById[$_.Id].Name })
    $s = ''
    if ($sec.Count)  { $s += ('These lower protection or turn a feature off ({0}):' -f $sec.Count) + $nl + (Format-NameList $sec 12) + $nl }
    if ($note.Count) { $s += ('These can stop something you use from working ({0}):' -f $note.Count) + $nl + (Format-NameList $note 40) + $nl }
    if ($dud.Count)  { $s += ('These may do nothing on your PC; each description says why ({0}):' -f $dud.Count) + $nl + (Format-NameList $dud 12) + $nl }
    if ($start.Count) { $s += ('These programs will no longer start with Windows ({0}); switch one back on here or in Task Manager to let it start again:' -f $start.Count) + $nl + (Format-NameList $start 20) + $nl }
    return $s
}

# The heads-up shown first when "Apply all" is pressed: what it takes in, what can stop working, what was left out
function Get-ApplyAllNote {
    param($Plan, $Left, [string]$Where)
    $nl = "`r`n"
    $Plan = @($Plan)
    $apply = @($Plan | Where-Object { $_.Action -eq 'Apply' })
    $s = ('APPLY ALL: this applies every setting on "{0}" ({1} of them) in one go. Each switch moves to the position this app sets (diagnostic data off, dark mode on, and so on).' -f $Where, $apply.Count) + $nl
    $s += 'Read the list before you say yes. Each setting''s description says what it changes.' + $nl + $nl
    $s += Get-NoteSections $apply
    $lf = @($Left)
    if ($lf.Count) {
        $s += 'Left out on purpose:' + $nl
        foreach ($l in $lf) { $s += ('  - {0}: {1}' -f $l.Name, $l.Why) + $nl }
        $s += $nl
    }
    return $s
}

# The settings in a plan that FACEIT's Anti-Cheat or Riot Vanguard (Valorant, League of Legends) can refuse to run with: the ones
# that ask the anti-cheat question (AskGroup 'anticheat': Memory Integrity / VBS, the hypervisor)
function Get-AntiCheatNames {
    param($Plan)
    return @(@($Plan) | Where-Object { $_.Action -eq 'Apply' -and [string]$script:ById[[string]$_.Id].AskGroup -eq 'anticheat' } | ForEach-Object { [string]$script:ById[[string]$_.Id].Name })
}

# The heads-up shown first when a preset button is pressed. $Key = recommended | advanced | personal, $Before = how many
# changes were already lined up before the preset added its own.
function Get-PresetNote {
    param([string]$Key, $Plan, [int]$Before = 0)
    $nl = "`r`n"
    $Plan = @($Plan)
    $apply = @($Plan | Where-Object { $_.Action -eq 'Apply' })
    $name = [string]$script:PresetNames[$Key]
    $back = @()
    if ($Key -eq 'guided') {
        # the settings of the questions answered Use default go back to the Windows default: they are not "applied" and carry no warnings
        $rs = (Get-GuidedSets).Reset
        $back = @($Plan | Where-Object { $rs.Contains([string]$_.Id) } | ForEach-Object { [string]$script:ById[[string]$_.Id].Name })
        $apply = @($apply | Where-Object { -not $rs.Contains([string]$_.Id) })
    }
    if ($Key -eq 'guided' -and $back.Count -gt 0 -and $apply.Count -eq 0) {
        $s = ('{0}: this puts {1} setting(s) back to the Windows default in one go.' -f $name.ToUpper(), $back.Count) + $nl
    } else {
        $s = ('{0}: this applies {1} setting(s) in one go. Each switch moves to the position this app sets (diagnostic data off, dark mode on, and so on).' -f $name.ToUpper(), $apply.Count) + $nl
    }
    if ($Key -eq 'advanced') {
        $s += 'Advanced Debloat is only recommended for PCs that are used mainly for gaming: it can remove services other uses need.' + $nl
    } elseif ($Key -eq 'guided') {
        $s += 'These are the settings your answers to the questions come to. Settings you said you use are not in the list.' + $nl
        if ($back.Count -gt 0 -and $apply.Count -gt 0) { $s += ('You answered Use default to some questions, so {0} more setting(s) go back to the Windows default.' -f $back.Count) + $nl }
        if ($back.Count -gt 0) { $s += ('Put back to the Windows default ({0}):' -f $back.Count) + $nl + (Format-NameList $back 40) + $nl }
    } elseif ($Key -eq 'personal') {
        $s += ('These are the settings of your Custom Preset (saved {0}).' -f [string]$script:Personal.Saved) + $nl
    }
    if ($Before -gt 0) { $s += ('{0} change(s) you had already lined up are in this list too.' -f $Before) + $nl }
    $s += 'Read the list before you say yes. Each setting''s description says what it changes.' + $nl + $nl
    $ac = @(Get-AntiCheatNames $Plan)
    if ($ac.Count) {
        $s += ('WARNING for FACEIT and Riot Vanguard (Valorant, League of Legends) players: these can stop those games from starting or from letting you play ({0}):' -f $ac.Count) + $nl
        $s += (Format-NameList $ac 12) + 'If you play on either, answer No here, switch these off in the list, and apply again.' + $nl + $nl
    }
    $nr = @($apply | Where-Object { Get-NotRecReason $script:ById[[string]$_.Id] } | ForEach-Object { [string]$script:ById[[string]$_.Id].Name })
    if ($nr.Count) { $s += ('These carry a "{0}" mark; the reason is in each setting''s description ({1}):' -f $script:NotRecText, $nr.Count) + $nl + (Format-NameList $nr 12) + $nl }
    $s += Get-NoteSections $apply
    return $s
}

# ------------------------------------------------ settings that are only partly applied ----
# After a check, two kinds of setting are offered for applying again:
#   - one that reads "partly applied" (some of its values are set, the others are not), and
#   - one that this app applied earlier (it has an undo record) and that now reads off.
# That happens when a newer version of this app changes a setting an older version applied, and when Windows or another
# program (a driver install, for example) changes a value back. Nothing is written to disk for this: the check only reads,
# and the question is made from what the check found. The settings asked about stay in memory, so the question is not repeated
# for them until the window is opened again.
# Left out: run-once actions, settings with options (T.Choices, because there is no telling which option was meant), and, for the
# second kind only, a setting whose Windows default is the position the app applies (Game Mode): reading off there is a choice
# somebody made in Windows, not something that was put back.
$script:ReapplyAsked = @{}
$script:ReapplyPending = $false      # a check has finished and the offer has not been made yet (the timer makes it when the window is free)

# The ids (in list order) of the settings to offer that have not been asked about since the window was opened
function Get-ReapplyOffer {
    $out = @()
    $store = $null
    try { $store = Get-Store } catch { $store = $null }      # read only: which settings this app has applied before
    foreach ($id in @($script:Rows.Keys)) {
        $row = $script:Rows[$id]
        if ($row.T.Once -or $row.T.Choices) { continue }
        if ($script:ReapplyAsked.ContainsKey([string]$id)) { continue }
        $st = [string]$row.State
        if ($st -eq 'Partial') { }
        elseif ($st -eq 'Off' -and $store -and $store.ContainsKey([string]$id) -and -not (Test-OffIsExplicit $row.T)) { }
        else { continue }
        $out += [string]$id
    }
    return $out
}

# These settings were asked about (whatever the answer): do not ask about them again until the window is opened again
function Set-ReapplyAsked {
    param($ids)
    foreach ($id in @($ids)) { $script:ReapplyAsked[[string]$id] = $true }
}

# The heads-up at the top of the question, above the usual list of changes: which settings are listed and why
function Get-ReapplyNote {
    param($Plan)
    $nl = "`r`n"
    $apply = @(@($Plan) | Where-Object { $_.Action -eq 'Apply' })
    $part = @(); $back = @()
    foreach ($p in $apply) {
        $row = $script:Rows[[string]$p.Id]
        if (-not $row) { continue }
        if ([string]$row.State -eq 'Partial') { $part += [string]$row.T.Name } else { $back += [string]$row.T.Name }
    }
    $s = ''
    if ($part.Count) {
        $s += ('{0} setting(s) are only partly applied on this PC: some of their values are set and the others are not.' -f $part.Count) + $nl + (Format-NameList $part 12) + $nl
    }
    if ($back.Count) {
        $s += ('{0} setting(s) that Headroom applied earlier are off now.' -f $back.Count) + $nl + (Format-NameList $back 12) + $nl
    }
    $s += 'That happens when a newer version of Headroom changes a setting you applied, or when Windows or another program (a driver install, for example) changes a value back.' + $nl
    $s += 'Yes applies them again. No leaves everything as it is.' + $nl + $nl
    $s += Get-NoteSections $apply
    return $s
}

# ------------------------------------------------------------ the questions ----
# Some settings ask a question before they are turned on (anti-cheat, printing). These work out what to ask for a plan.
# One entry per question: Group, Title, Ask (the text), Ids and Names of the settings it covers (in plan order).
# Settings with the same AskGroup are asked about once. Only "turn on" is asked about; turning a setting off never is.
function Get-GuardQuestions {
    param($Plan)
    $out = @(); $byGroup = @{}
    foreach ($p in @($Plan)) {
        if ([string]$p.Action -ne 'Apply') { continue }
        $t = $script:ById[[string]$p.Id]
        if (-not $t -or -not $t.Ask) { continue }
        $g = [string]$t.AskGroup
        if (-not $g) { $g = [string]$t.Id }
        if (-not $byGroup.ContainsKey($g)) {
            $q = @{ Group = $g; Title = [string]$t.AskTitle; Ask = [string]$t.Ask; Ids = @(); Names = @() }
            $byGroup[$g] = $q
            $out += ,$q
        }
        $q = $byGroup[$g]
        $q.Ids += [string]$t.Id
        $q.Names += [string]$t.Name
    }
    return $out
}

# The text of one question: what it is about, which settings the answer covers, and what Yes and No do
function Get-GuardText {
    param($q)
    $nl = "`r`n"
    $s = [string]$q.Ask + $nl + $nl
    $names = @($q.Names)
    if ($names.Count -eq 1) { $s += 'This is about: ' + [string]$names[0] + $nl + $nl }
    else {
        $s += 'The answer covers these settings:' + $nl
        foreach ($n in $names) { $s += '  - ' + [string]$n + $nl }
        $s += $nl
    }
    $s += 'Yes = go ahead and apply it.' + $nl + 'No = leave it as it is (nothing is changed for it).'
    return $s
}

# A plan without the given setting ids
function Remove-FromPlan {
    param($Plan, $Ids)
    $drop = @{}
    foreach ($i in @($Ids)) { $drop[[string]$i] = $true }
    $out = @()
    foreach ($p in @($Plan)) { if (-not $drop.ContainsKey([string]$p.Id)) { $out += ,$p } }
    return $out
}

# ----------------------------------------------- events from the background job ----
# The window part supplies Ui-Log, Ui-Progress, Ui-RefreshRow, Ui-Reveal, Ui-ScanFinished, Ui-RunFinished.
function Handle-Event {
    param($ev)
    switch ([string]$ev.Kind) {
        'log' { Ui-Log ([string]$ev.Text) ([string]$ev.Color) }
        'state' {
            Set-RowState ([string]$ev.Id) ([string]$ev.State) ([string]$ev.Detail) ([bool]$script:Scanning) ([string]$ev.Choice) ([string]$ev.Read) ([string]$ev.Mine)
            if ($script:Scanning) { Ui-Progress ([int]$ev.A) ([int]$ev.B) }
            Ui-RefreshRow ([string]$ev.Id)
        }
        'item' {
            $row = $script:Rows[[string]$ev.Id]
            if ($row) {
                switch ([string]$ev.State) {
                    'running' { $row.Note = 'Working...'; $row.NoteDetail = ''; Ui-Progress ([int]$ev.A - 1) ([int]$ev.B); Ui-Reveal ([string]$ev.Id) }
                    'done'    { $row.Note = 'Done'; $row.NoteDetail = [string]$ev.Detail; if ($row.T.Once) { $row.Want = $false }; Ui-Progress ([int]$ev.A) ([int]$ev.B) }
                    'failed'  { $row.Note = 'Failed'; $row.NoteDetail = [string]$ev.Detail; Ui-Progress ([int]$ev.A) ([int]$ev.B) }
                    'dry'     { $row.Note = 'Preview only'; $row.NoteDetail = ''; Ui-Progress ([int]$ev.A) ([int]$ev.B) }
                }
                Ui-RefreshRow ([string]$ev.Id)
            }
        }
        'wait' {
            $script:WaitText = [string]$ev.Text
            $script:DProg = $true
        }
        'scandone' {
            $script:Scanning = $false
            $script:WaitText = ''
            # a row the worker never reported on (the startup list changed between the window and the worker)
            # must not sit on "Checking..." for ever
            foreach ($id in @($script:Rows.Keys)) {
                $r = $script:Rows[$id]
                if ($r.State -eq 'Checking') { $r.State = 'Unknown'; $r.Detail = 'Not checked - press "Check again"' }
            }
            Ui-ScanFinished
            $script:ReapplyPending = $true      # partly applied and put-back settings are offered for applying again (Ui-OfferReapply)
        }
        'finished' {
            $script:Applying = $false
            Ui-RunFinished $ev
        }
    }
}

# =============================================================================
# THE QUESTION PRESET (DRAFT): a preset that is worked out from the user's answers instead of a fixed list.
#
# Every question is a yes / no / not sure question about how the PC is used. A question owns some settings:
#   Yes   the settings that are applied when the answer is Yes ("Do you want ...?" questions)
#   No    the settings that are applied when the answer is No  ("Do you use ...?" questions: no use, so switch the feature off)
#   Keep  the settings that a Yes (or Not sure) protects: no other question may apply them, and they are left as Windows has them.
#         When it is left out it is the same list as No ("I use it, so leave it on" is the usual meaning of Yes).
# Not sure (and a question that was not answered yet) applies nothing and keeps whatever Keep names, so the careful side wins.
# A question with a Gate is only asked when the answer to the gate question is not No (no gaming: no questions about anti-cheat);
# a gate with a plus ('uninstall+') needs a Yes (no uninstalling: no questions about which apps to remove; no advanced questions
# unless the user wants them). Several gates are written as a comma-separated list.
# The settings that remove something for good (T.OneWay) are only applied when the "uninstall" question was answered Yes.
# A fourth answer, Use default, leaves a question's own settings (the Yes and No lists) as Windows has them: the ones that are changed on
# this PC are put back to the Windows default when the answers are confirmed (the same position "Reset all" uses). It protects the Keep
# list like Not sure. The settings that remove something for good cannot be put back, so they are skipped.
# Apart from that a preset only applies settings: it never switches anything off again. A setting is applied by at most one question,
# and a Keep from any question beats an Apply from any other.
# =============================================================================
$script:GuidedQuestions = New-Object System.Collections.ArrayList
$script:GuidedAnswers = @{}          # question id -> 'Yes' | 'No' | 'Unsure' | 'Default'
$script:GuidedPos = 0                # the question the window shows: 0..Count-1, or Count for the review page
$script:GuidedCache = $null          # the worked-out sets (cleared whenever an answer changes)

function Add-GQ {
    param([string]$Id, [string]$Group, [string]$Q, [string]$Help, [string[]]$Yes = @(), [string[]]$No = @(), $Keep = $null, [string]$Gate = '')
    if ($null -eq $Keep) { $Keep = @($No) }
    [void]$script:GuidedQuestions.Add(@{ Id = $Id; Group = $Group; Q = $Q; Help = $Help; Yes = @($Yes); No = @($No); Keep = @($Keep); Gate = $Gate })
}

Add-GQ -Id 'uninstall' -Group 'Before you start' -Gate '' `
    -Q 'Are you OK with uninstalling built-in apps and components that you do not use?' `
    -Help 'Some settings do not just switch a feature off, they remove something for good: built-in apps, OneDrive, Quick Assist and the Windows AI package. Headroom cannot put those back (most apps can be installed again from the Microsoft Store). Yes allows them. No or Not sure skips every setting that removes something, and the questions about the built-in apps are not asked. Settings that only switch features off are still applied, and each of those can be undone from this app.'
Add-GQ -Id 'advanced' -Group 'Before you start' `
    -Q 'Do you also want to be asked the advanced questions?' `
    -Help 'The everyday questions are about how you use this PC. The advanced ones are about settings that lower protection or can get in the way of other things: Windows security prompts (UAC), drive encryption, Windows Update and drivers, the file indexer, troubleshooters, firmware programs, the Microsoft Store and similar. They are what the old Advanced Debloat was made of, and each one is marked in the lists. Yes asks them. No or Not sure skips all of them and applies nothing from them.'
Add-GQ -Id 'laptop' -Group 'Your PC' `
    -Q 'Is this a laptop or a tablet that often runs on battery?' `
    -Help 'Laptops need power saving to make the battery last. A desktop does not, and power saving there can cause stutter, dropped network connections and USB devices that go to sleep. Answer No (a desktop) and power saving is switched off for network adapters and USB devices, and the Health and Optimized Experiences and sensor services are switched off. Yes keeps all of that as Windows has it, and keeps Fast Startup and hibernation off the list too.' `
    -No @('nic-turnoff', 'nic-eee', 'nic-suspend', 'usb-power', 'svc-whe', 'svc-sensormon', 'svc-sensordata') `
    -Keep @('nic-turnoff', 'nic-eee', 'nic-suspend', 'usb-power', 'svc-whe', 'svc-sensormon', 'svc-sensordata', 'hibernate')
Add-GQ -Id 'gaming' -Group 'Your PC' `
    -Q 'Do you play games on this PC?' `
    -Help 'Yes tunes Windows for games: Game Mode, hardware-accelerated GPU scheduling (HAGS), optimizations for windowed games, and Windows Security scans that only run while the PC is idle. No skips all of that and the questions that only matter for games. (Power plans are not part of this: install them and choose the active one on the Power plan and startup page.)' `
    -Yes @('game-mode', 'hags', 'windowed-opt', 'defender-idle')
Add-GQ -Id 'shooters' -Group 'Your PC' -Gate 'gaming' `
    -Q 'Do you play shooters or other games where precise aiming matters?' `
    -Help 'Mouse acceleration moves the pointer farther when you move the mouse faster, which works against muscle memory in aim-heavy games. Yes turns it off, so the pointer moves 1:1 with your hand. Most people notice little on the desktop, but some like acceleration for work.' `
    -Yes @('mouse')
Add-GQ -Id 'riot' -Group 'Your PC' -Gate 'gaming,advanced+' `
    -Q 'Do you play Riot games (Valorant, League of Legends) or use FACEIT?' `
    -Help 'Riot Vanguard and FACEIT Anti-Cheat can refuse to start, or refuse to let you play, when Memory Integrity (virtualization-based security) is off. Yes or Not sure means the two settings that turn those off are never applied, whatever else you answer. Valve games (Counter-Strike 2, Dota 2) and VAC do not need them.' `
    -Keep @('vbs', 'hypervisor')
Add-GQ -Id 'perfsec' -Group 'Your PC' -Gate 'gaming,advanced+' `
    -Q 'Do you want a few percent more FPS even if it lowers some of the protection in Windows?' `
    -Help 'Memory Integrity and the Windows hypervisor are security features that protect against malicious drivers. Switching them off can give a few percent more FPS in some games, and removes that protection. Yes lines both up (each one asks once more before it is switched on). A Yes to Riot / FACEIT or to virtual machines overrules it.' `
    -Yes @('vbs', 'hypervisor')
Add-GQ -Id 'vrr' -Group 'Your PC' -Gate 'gaming' `
    -Q 'Do you have a variable refresh rate monitor (G-SYNC, FreeSync or Adaptive-Sync)?' `
    -Help 'Yes turns on variable refresh rate for full-screen DirectX 11 games that were not written for it, so the screen follows the frame rate. Windows ships with this off. Some games flicker or change brightness while the refresh rate varies; this is the switch to turn off again for them. No or Not sure leaves it off, as Windows has it, and it does nothing on a screen without variable refresh rate.' `
    -Yes @('vrr-games')
Add-GQ -Id 'vm' -Group 'Your PC' `
    -Q 'Do you use virtual machines, WSL, Docker, Windows Sandbox or Android emulators?' `
    -Help 'Hyper-V, WSL2, Docker Desktop, Windows Sandbox and many emulators need the Windows hypervisor, and their network uses Internet Connection Sharing. Yes or Not sure leaves the hypervisor, Memory Integrity and connection sharing as Windows has them.' `
    -Keep @('hypervisor', 'vbs', 'ics')
Add-GQ -Id 'xbox' -Group 'Your PC' `
    -Q 'Do you use Game Pass, the Xbox app, Microsoft Store games or Game Bar clips?' `
    -Help 'Without the Xbox services, Game Pass, the Xbox app and Microsoft Store games stop working. Steam, Epic and GOG games are not affected. Game Bar (Win+G) records clips in the background, which can cost frames. No switches off the Xbox services, Game Bar recording and its save-sync task, and (if you allowed uninstalling) removes the Game Bar app and the Xbox app with its sign-in. Yes also keeps the Microsoft Store and merged service hosts off the advanced list, because Game Pass and Xbox need them.' `
    -No @('xbox-svc', 'gamedvr', 'gamebar-links', 'apps-gamebar', 'apps-xbox', 'task-xblsave') `
    -Keep @('xbox-svc', 'gamedvr', 'gamebar-links', 'apps-gamebar', 'apps-xbox', 'task-xblsave', 'svchost-merge', 'apps-store', 'store-policy')
Add-GQ -Id 'rgb' -Group 'Your PC' `
    -Q 'Do you control RGB lighting with Windows Dynamic Lighting?' `
    -Help 'That is the Dynamic Lighting page in Settings > Personalization. RGB software from your hardware maker (iCUE, G HUB, Armoury Crate, OpenRGB and so on) is not affected. No stops Windows from controlling the lights, so only that software does, and Windows cannot fight with it.' `
    -No @('dynamic-lighting', 'dynamic-lighting-foreground')
Add-GQ -Id 'ducking' -Group 'Your PC' -Gate 'gaming' `
    -Q 'Do you want Windows to turn other sounds down when it sees a call or voice chat start?' `
    -Help 'That is Sound > Communications: reduce other sounds by 80 %. With voice chat running, the game volume can drop every time someone talks. No sets it to Do nothing, so the game keeps its full volume while you talk.' `
    -No @('audio-ducking')
Add-GQ -Id 'vr' -Group 'Your PC' -Gate 'gaming' `
    -Q 'Do you use a Windows Mixed Reality headset?' `
    -Help 'Other headsets (Quest, Index, Vive) bring their own software and do not need the Windows Mixed Reality service. No switches that service off. On Windows versions that no longer have it, the setting is skipped.' `
    -No @('svc-mixedreality')
Add-GQ -Id 'noreboot' -Group 'Your PC' `
    -Q 'Do you want Windows to restart this PC by itself after installing updates while you are signed in?' `
    -Help 'Windows can restart about five minutes after a scheduled update install, which can be in the middle of a game or of unsaved work. No stops that: it shows a notice and waits for you to restart. The update stays unfinished until you restart yourself, so do that now and then.' `
    -No @('wu-noreboot')
Add-GQ -Id 'storagesense' -Group 'Your PC' `
    -Q 'Do you want Windows to delete temporary files and old Recycle Bin items by itself (Storage Sense)?' `
    -Help 'Storage Sense deletes temporary files and old Recycle Bin files on its own, and can clear Downloads too if it is set up that way. No turns it off, so Windows deletes nothing by itself and you decide when to clear space. Yes or Not sure leaves it as Windows has it.' `
    -No @('storage-sense')
Add-GQ -Id 'work' -Group 'Work and network' `
    -Q 'Is this PC on a company or school network, or do you sign in with a smart card or security key?' `
    -Help 'Company and school PCs can rely on Offline Files, smart cards and remote management. No switches off Offline Files, the smart card services, PowerShell remoting (WinRM) and the other remote-management services. Yes or Not sure leaves them alone.' `
    -No @('offlinefiles', 'svc-smartcard', 'svc-scpolicy', 'winrm', 'remote-mgmt')
Add-GQ -Id 'remote' -Group 'Work and network' `
    -Q 'Do you use Remote Desktop, Remote Assistance or Quick Assist to reach this PC or to get help?' `
    -Help 'No blocks Remote Desktop, turns off Remote Assistance and removes the Quick Assist app (it cannot be put back from this app). Remote play and streaming apps such as Steam Remote Play and Parsec are separate and are not affected by these three.' `
    -No @('rdp', 'remote-assist', 'quickassist')
Add-GQ -Id 'vpn' -Group 'Work and network' `
    -Q 'Do you use a VPN (a work VPN, or an app such as NordVPN, ProtonVPN or WireGuard)?' `
    -Help 'Windows has its own VPN client (IKEv2, SSTP, L2TP). VPN apps that bring their own driver, such as WireGuard, usually keep working without it, but some VPN clients need it. No switches the Windows VPN services off, which also breaks PPPoE broadband dial-ups. Yes or Not sure leaves them on.' `
    -No @('vpn')
Add-GQ -Id 'lan' -Group 'Work and network' `
    -Q 'Do you share files, printers or media with other PCs, a NAS or a TV on your home network?' `
    -Help 'No turns off file and printer sharing, network discovery, UPnP hosting, the old name lookups (LLMNR, mDNS, NetBIOS) and SMB1. This PC can still open shared folders and printers on other devices; what stops is other devices reaching this one. A few old NAS boxes or printers that are only found by NetBIOS name may stop showing up by name.' `
    -No @('fileshare', 'discovery', 'legacy-names', 'svc-netbios', 'smb1')
Add-GQ -Id 'hotspot' -Group 'Work and network' `
    -Q 'Do you share this PC''s internet connection with other devices (Mobile Hotspot, Internet Connection Sharing)?' `
    -Help 'No turns off Internet Connection Sharing, the Mobile Hotspot service and Windows Media Player library sharing. WSL2, Hyper-V and Windows Sandbox use connection sharing too, and the virtual machine question above protects it for them.' `
    -No @('ics')
Add-GQ -Id 'print' -Group 'Work and network' `
    -Q 'Do you print, or use Microsoft Print to PDF?' `
    -Help 'No switches the Print Spooler off, so this PC cannot print at all, and Microsoft Print to PDF and the XPS Document Writer go away. You are asked once more before it is switched on.' `
    -No @('printing')
Add-GQ -Id 'hello' -Group 'Work and network' `
    -Q 'Do you sign in with Windows Hello (a fingerprint reader or a face camera)?' `
    -Help 'A PIN or a password does not use the Windows Biometric Service. No switches it off; Yes or Not sure leaves it on.' `
    -No @('svc-biometric')
Add-GQ -Id 'legacy' -Group 'Work and network' `
    -Q 'Do you use Internet Explorer mode, Work Folders, Fax or the Steps Recorder?' `
    -Help 'These four legacy Windows features are only needed for old company sites, Work Folders sync, faxing and recording steps for support. No removes them; they can be added again from Windows Update (internet connection needed).' `
    -No @('legacy')
Add-GQ -Id 'onedrive' -Group 'Accounts and cloud' `
    -Q 'Do you use OneDrive (cloud backup or sync of your files)?' `
    -Help 'No stops OneDrive from syncing, hides it in File Explorer and, if you allowed uninstalling, removes the app (a OneDrive folder that still has files in it is left alone). Reinstall later with winget install Microsoft.OneDrive.' `
    -No @('onedrive-policy', 'onedrive-remove')
Add-GQ -Id 'phone' -Group 'Accounts and cloud' `
    -Q 'Do you use Phone Link, Nearby Sharing or text messages on this PC?' `
    -Help 'No turns off Nearby Sharing and Continue on this PC, the text message (SMS) router, and removes the Phone Link and Cross Device apps.' `
    -No @('crossdevice', 'svc-smsrouter', 'apps-phone')
Add-GQ -Id 'settingsync' -Group 'Accounts and cloud' `
    -Q 'Do you want your theme, Wi-Fi passwords and other Windows settings to sync with your Microsoft account?' `
    -Help 'No blocks settings sync and disables its two background tasks. Your files and apps are not affected.' `
    -No @('settingsync')
Add-GQ -Id 'mail' -Group 'Accounts and cloud' `
    -Q 'Do you use the Mail, Calendar, People, Outlook (new) or Teams (chat) apps that come with Windows?' `
    -Help 'No removes those apps and switches off the background services behind them. Yes or Not sure keeps them. Outlook and Teams that you installed yourself are not affected.' `
    -No @('apps-mail', 'syncsvc')
Add-GQ -Id 'clip' -Group 'Accounts and cloud' `
    -Q 'Do you use clipboard history (Win+V) or the cloud clipboard?' `
    -Help 'No stops Windows from keeping a list of what you copied and from syncing the clipboard between your devices. Normal copy and paste (Ctrl+C, Ctrl+V) is not affected.' `
    -No @('clipboard-history', 'clipboard')
Add-GQ -Id 'diag' -Group 'Privacy' `
    -Q 'Do you want to stop Windows sending diagnostic data and error reports to Microsoft, and update sharing with other PCs?' `
    -Help 'Yes sets diagnostic data to the least Windows allows, turns off error reporting, the telemetry services and scheduled tasks, the data usage meter, Defender sample sending, Defender Core telemetry, inking and typing data collection, the data usage and Office telemetry tasks, and Windows Update sharing with other PCs. Windows Security keeps scanning and updating as normal.' `
    -Yes @('telemetry', 'telemetry-tasks', 'telemetry-svc', 'svc-telemetry2', 'task-sqm', 'svc-datausage', 'defender-samples', 'defender-core', 'inking', 'deliveryopt', 'task-dusm', 'task-officetelemetry')
Add-GQ -Id 'ads' -Group 'Privacy' `
    -Q 'Do you want to stop ads, suggestions and tracking in Windows?' `
    -Help 'Yes turns off the advertising ID, tailored tips, suggested and auto-installed apps, promo cards in Settings, feedback pop-ups, activity history, app-launch tracking and web results in Start search.' `
    -Yes @('ads', 'tracking', 'suggestions', 'settings-promo', 'feedback', 'activity', 'search-web')
Add-GQ -Id 'location' -Group 'Privacy' `
    -Q 'Do you use location (Weather, Maps, automatic time zone) or Find my device?' `
    -Help 'No turns location off for the whole PC and turns Find my device off, so the PC is not registered with your Microsoft account. Weather and Maps no longer know where you are, and Set time zone automatically stops working, so the clock will not follow you to a new time zone by itself. Yes or Not sure leaves both as Windows has them.' `
    -No @('location', 'find-my-device')
Add-GQ -Id 'devmeta' -Group 'Privacy' `
    -Q 'Do you want Windows to look up device names, pictures and maker apps online when you plug in hardware?' `
    -Help 'No stops Windows from downloading device information from the internet. Drivers are not affected: they still come from Windows Update or your own installer. A new device may show with a generic icon and name.' `
    -No @('device-metadata')
Add-GQ -Id 'trouble' -Group 'Privacy' `
    -Q 'Do you run old games or programs and rely on the compatibility prompts that Windows shows?' `
    -Help 'That is the Program Compatibility Assistant ("this program might not have installed correctly"), its update task and the power diagnostics task. Compatibility settings you choose yourself in a program''s Properties still apply without it. No switches the assistant off.' `
    -No @('svc-pca', 'task-pca', 'task-powerdiag')
Add-GQ -Id 'rare' -Group 'Privacy' `
    -Q 'Do you use Fax, NFC or tap-to-pay, Parental Controls or Family Safety, Windows Insider builds or offline maps?' `
    -Help 'No switches off the rarely used services for those (Retail Demo, Fax, Parental Controls, NFC and payments, Wallet, Phone service, Windows Insider, Downloaded Maps Manager, Distributed Link Tracking) and the Family Safety and Maps update tasks.' `
    -No @('svc-misc', 'svc-wallet', 'task-familysafety', 'task-maps')
Add-GQ -Id 'ai' -Group 'AI and Edge' `
    -Q 'Do you use Copilot or other AI features in Windows, Edge or Chrome?' `
    -Help 'No switches off Copilot, Recall, Click to Do, AI in Notepad and Paint, text and image generation for apps, voice activation, the AI page in Settings, experimental agentic features and AI in Edge and Chrome. If you allowed uninstalling, it also removes the Copilot app and the Windows AI package.' `
    -No @('copilot', 'recall', 'ai-apps', 'ai-generative', 'ai-voice', 'ai-page', 'ai-agentic', 'ai-core', 'apps-ai', 'edge-ai', 'edge-ai-more', 'chrome-ai')
Add-GQ -Id 'edge' -Group 'AI and Edge' `
    -Q 'Do you use Microsoft Edge as a browser?' `
    -Help 'Yes still hides the first-run page, rewards and nags and stops Edge from running in the background when it is closed, but leaves Edge''s telemetry and profile sync, its update tasks and its update services as they are. No switches all of that off. The update tasks also keep the WebView2 component up to date, which many apps use: they are only switched off when you answer No.' `
    -Yes @('edge-debloat', 'edge-bg') `
    -No @('edge-debloat', 'edge-bg', 'edge-tele', 'edge-newtab', 'edge-tasks', 'edge-upd') `
    -Keep @('edge-tele', 'edge-tasks', 'edge-upd')
Add-GQ -Id 'theme' -Group 'Look and feel' `
    -Q 'Do you want dark mode and a solid black desktop (no wallpaper)?' `
    -Help 'Yes turns on dark mode for apps and Windows and sets a plain black desktop.' `
    -Yes @('dark', 'blackdesk')
Add-GQ -Id 'taskbar' -Group 'Look and feel' `
    -Q 'Do you want the taskbar tidied: icons on the left, no Search or Task View button, and End task in the right-click menu?' `
    -Help 'Yes moves the taskbar icons to the left (Windows 10 style), hides the Search and Task View buttons and adds End task to the taskbar right-click menu.' `
    -Yes @('taskbar-left', 'taskbar-search', 'taskbar-taskview', 'taskbar-endtask')
Add-GQ -Id 'widgets' -Group 'Look and feel' `
    -Q 'Do you use Widgets (the weather, news and stocks panel) or Chat on the taskbar?' `
    -Help 'No hides the Widgets and Chat buttons, turns the Widgets feed off by policy and, if you allowed uninstalling, removes the Widgets panel.' `
    -No @('taskbar-clutter', 'apps-widgets')
Add-GQ -Id 'effects' -Group 'Look and feel' `
    -Q 'Do you want Windows without animations, shadows and transparency?' `
    -Help 'Yes turns off window animations and shadows and the transparency effects: a plainer, snappier look.' `
    -Yes @('animations', 'transparency')
Add-GQ -Id 'notif' -Group 'Look and feel' `
    -Q 'Do you want Windows notifications (pop-ups from apps, games, the calendar)?' `
    -Help 'No turns off all pop-up notifications and the notification centre. Windows Security pop-ups may be hidden too, so look at its status page now and then.' `
    -No @('notifications')
Add-GQ -Id 'startrec' -Group 'Look and feel' `
    -Q 'Do you want the Recommended section (recent files and suggested apps) in the Start menu?' `
    -Help 'No hides the Recommended section of the Start menu.' `
    -No @('start-recommended')
Add-GQ -Id 'explorer' -Group 'Look and feel' `
    -Q 'Do you want File Explorer the classic way (full right-click menu, no Home or Gallery, opens to This PC)?' `
    -Help 'Yes brings back the full right-click menu, removes Home and Gallery from the side pane and makes File Explorer open to This PC.' `
    -Yes @('classic-menu', 'nav-home', 'nav-gallery', 'launchto')
Add-GQ -Id 'showext' -Group 'Look and feel' `
    -Q 'Do you want File Explorer to show file extensions (.exe, .txt, .jpg)?' `
    -Help 'Yes shows the full file names, which makes disguised files (a program named like a picture) easier to spot.' `
    -Yes @('showext')
Add-GQ -Id 'snap' -Group 'Look and feel' `
    -Q 'Do you use Snap layouts, snap suggestions or shaking a window to minimize the others?' `
    -Help 'No switches off the snap suggestions and layouts flyouts and the title bar window shake.' `
    -No @('snap-suggestions', 'window-shake')
Add-GQ -Id 'shortcuts' -Group 'Look and feel' `
    -Q 'Do you use the Sticky Keys, Filter Keys, Toggle Keys, Mouse Keys or High Contrast keyboard shortcuts?' `
    -Help 'These are accessibility shortcuts that pop up a box when a key is held or pressed five times, which is a nuisance in games. No switches all five shortcuts off.' `
    -No @('sticky-keys', 'filter-keys', 'toggle-keys', 'mouse-keys', 'contrast-keys')
Add-GQ -Id 'faststart' -Group 'Look and feel' `
    -Q 'Do you use Fast Startup or Hibernate?' `
    -Help 'No turns both off: Shut down becomes a real shutdown and the hiberfil.sys file (several GB) is deleted, which can help with driver and update glitches. Sleep still works.' `
    -No @('hibernate')
Add-GQ -Id 'newsmedia' -Group 'Built-in apps' -Gate 'uninstall+' `
    -Q 'Do you use the News, Weather, Maps, Bing, Media Player or Movies & TV apps?' `
    -Help 'No removes those apps.' `
    -No @('apps-news', 'apps-media')
Add-GQ -Id 'notesextras' -Group 'Built-in apps' -Gate 'uninstall+' `
    -Q 'Do you use Sticky Notes, To Do, OneNote, Clipchamp, Tips or other Microsoft extras?' `
    -Help 'No removes those apps and the other small Microsoft extras.' `
    -No @('apps-notes', 'apps-extras', 'apps-startexp')
Add-GQ -Id 'promo' -Group 'Built-in apps' -Gate 'uninstall+' `
    -Q 'Do you use the promo apps that come with Windows (LinkedIn, Spotify, TikTok, Netflix, Disney+ and so on)?' `
    -Help 'No removes them by name. That includes the Microsoft Store versions of these apps, so answer Yes if you installed Spotify, Netflix or similar from the Store.' `
    -No @('apps-promo')
Add-GQ -Id 'dolby' -Group 'Built-in apps' -Gate 'uninstall+' `
    -Q 'Do you use Dolby Atmos (the Dolby Access app) for headphones or a home theatre?' `
    -Help 'Without the app, Dolby Atmos stops working (the Dolby drivers stay). No removes it.' `
    -No @('apps-dolby')
Add-GQ -Id 'smallapps' -Group 'Built-in apps' -Gate 'uninstall+' `
    -Q 'Do you use the Clock, Camera, Paint, Sound Recorder or Journal apps?' `
    -Help 'No removes those apps.' `
    -No @('apps-clock', 'apps-camera', 'apps-paint', 'apps-recorder', 'apps-journal')
Add-GQ -Id 'snip' -Group 'Built-in apps' -Gate 'uninstall+' `
    -Q 'Do you use the Snipping Tool (Win+Shift+S or Print Screen screenshots)?' `
    -Help 'The editing window that follows Win+Shift+S and what the Print Screen key opens go with the app, so answer Yes if you use them. Screenshots from Steam, the NVIDIA overlay and other programs are not affected. No removes it.' `
    -No @('apps-snip')
Add-GQ -Id 'uac' -Group 'Advanced' -Gate 'advanced+' `
    -Q 'Do you want Windows to ask before programs get administrator rights (UAC prompts)?' `
    -Help 'No turns the prompts off and switches the User Account Control engine off completely. That removes a safety net: programs can get administrator rights without asking, and malware benefits too. With the engine off, modern apps (Settings, Calculator, Photos, Terminal) can refuse to open. Yes or Not sure leaves UAC as Windows has it.' `
    -No @('uac', 'uac-lua')
Add-GQ -Id 'encrypt' -Group 'Advanced' -Gate 'advanced+' `
    -Q 'Do you want Windows to turn on drive encryption (Device encryption) by itself?' `
    -Help 'Windows 11 can start Device encryption (the simple form of BitLocker) on its own on a new install, or when you sign in with a Microsoft account. No stops that automatic start. It does not decrypt anything and does not touch a drive that is already encrypted.' `
    -No @('device-encryption-block')
Add-GQ -Id 'drivers' -Group 'Advanced' -Gate 'advanced+' `
    -Q 'Do you want Windows Update to install and replace drivers for you?' `
    -Help 'Windows Update can replace a driver you installed yourself (a graphics driver, for example) and searches for one when you plug in new hardware. No leaves your drivers alone: you update them yourself from the maker (the GPU maker''s installer, your motherboard''s site). Yes or Not sure leaves it as Windows has it.' `
    -No @('wu-drivers')
Add-GQ -Id 'wpbt' -Group 'Advanced' -Gate 'advanced+' `
    -Q 'Do you want your motherboard firmware to be able to install its own software in Windows?' `
    -Help 'That is the Windows Platform Binary Table (WPBT). Some boards use it to deliver their own software (a Gigabyte updater, Armoury Crate on ASUS boards with that BIOS option on), and some anti-theft tools use it. No stops Windows from running such programs, so tools delivered that way are no longer installed.' `
    -No @('wpbt')
Add-GQ -Id 'indexer' -Group 'Advanced' -Gate 'advanced+' `
    -Q 'Do you search for files with the Windows Search index (File Explorer and Start search)?' `
    -Help 'No stops the indexer from starting with Windows (it starts when needed). Start menu results for installed apps keep working, but results that come from the index can stop appearing: files, and programs that are not installed, such as a portable program that runs from its own folder. The gain is a little less background disk and CPU use.' `
    -No @('svc-search')
Add-GQ -Id 'troubleshoot' -Group 'Advanced' -Gate 'advanced+' `
    -Q 'Do you use the built-in Windows troubleshooters (network, audio, Windows Update)?' `
    -Help 'No switches off the three diagnostic services, so those Troubleshoot wizards stop working until you switch this back on.' `
    -No @('svc-diag')
Add-GQ -Id 'svchost' -Group 'Advanced' -Gate 'advanced+' `
    -Q 'Do you look at single Windows services in Task Manager, or troubleshoot them?' `
    -Help 'No lets Windows group its services again after a restart (about 50 fewer svchost.exe processes, a little less memory). The costs: one service that crashes can take others in its group with it, and Task Manager can no longer show which service uses the CPU. It can interfere with the Xbox services, so a Yes to the Xbox question keeps it off the list too.' `
    -No @('svchost-merge')
Add-GQ -Id 'bgapps' -Group 'Advanced' -Gate 'advanced+' `
    -Q 'Do you use Microsoft Store apps that need to update or notify you in the background?' `
    -Help 'No stops Store apps from running and fetching data while you are not using them. Normal desktop programs such as Steam, Discord and browsers are not affected. Store apps such as Mail, Weather or a Store game may then only update when you open them.' `
    -No @('bgapps')
Add-GQ -Id 'automaint' -Group 'Advanced' -Gate 'advanced+' `
    -Q 'Do you want Windows to run automatic maintenance while the PC is idle?' `
    -Help 'Automatic Maintenance runs Store app updates, drive optimisation (TRIM on an SSD), Windows Security scans, system diagnostics and some clean-up in the background. No stops those tasks from starting on their own, and the WinSAT benchmark task with them. You can still update from Windows Update and run Optimize Drives by hand. Windows can switch it back on after a large update.' `
    -No @('auto-maintenance', 'task-winsat')
Add-GQ -Id 'storagesvc' -Group 'Advanced' -Gate 'advanced+' `
    -Q 'Do you rely on Windows to check a drive by itself when it notices a problem?' `
    -Help 'No sets the Storage Service to start on demand and turns off the automatic check of a drive after Windows notices damage (Spot Verifier). You can still run a check yourself with chkdsk.' `
    -No @('svc-storage', 'svc-spotverifier')
Add-GQ -Id 'store' -Group 'Advanced' -Gate 'advanced+' `
    -Q 'Do you install or update apps from the Microsoft Store?' `
    -Help 'No stops Store installs and updates (the install service is disabled) and, if you allowed uninstalling, removes the Store app. Apps that come from the Store (the NVIDIA Control Panel and Photos, for example) stop receiving updates; winget keeps working. Game Pass and Xbox need the Store, so a Yes to the Xbox question keeps this one off the list too.' `
    -No @('apps-store', 'store-policy')

Remove-Variable g -ErrorAction SilentlyContinue

# ------------------------------------------------------------------- the engine ----
function Get-GuidedQuestion {
    param([string]$Id)
    foreach ($q in $script:GuidedQuestions) { if ([string]$q.Id -ceq $Id) { return $q } }
    return $null
}

# Is this question asked? A Gate is a comma-separated list of question ids; the question is asked only when every one of them lets it
# through. 'gaming' lets it through unless the answer is No; 'advanced+' (with a plus) only when the answer is Yes or not given yet.
# A gate question that is not asked itself counts as No.
function Test-GuidedAsked {
    param($q)
    foreach ($entry in @(([string]$q.Gate) -split ',' | Where-Object { $_ })) {
        $needYes = $entry.EndsWith('+')
        $gate = $entry.TrimEnd('+')
        $gq = Get-GuidedQuestion $gate
        if ($gq -and -not (Test-GuidedAsked $gq)) { return $false }
        $ans = [string]$script:GuidedAnswers[$gate]
        if ($needYes) { if ($ans -ceq 'No' -or $ans -ceq 'Unsure' -or $ans -ceq 'Default') { return $false } }
        elseif ($ans -ceq 'No') { return $false }
    }
    return $true
}

# The questions that are asked right now, in order
function Get-GuidedAsked {
    return @($script:GuidedQuestions | Where-Object { Test-GuidedAsked $_ })
}

function Set-GuidedAnswer {
    param([string]$Id, [string]$Answer)
    if ($Answer -cne 'Yes' -and $Answer -cne 'No' -and $Answer -cne 'Unsure' -and $Answer -cne 'Default') { return }
    $script:GuidedAnswers[$Id] = $Answer
    $script:GuidedCache = $null
}

function Reset-GuidedAnswers {
    $script:GuidedAnswers = @{}
    $script:GuidedPos = 0
    $script:GuidedCache = $null
}

# What the answers come to:
#   Apply   setting id -> the question that applies it (before the Keep and uninstall filters)
#   Keep    setting id -> the question that protects it
#   Final   the setting ids that are applied, in catalog order
#   Blocked setting id -> the question that kept it, for the ones some other question would have applied
#   NoUninstall  the ids left out because uninstalling was not allowed
#   Reset   setting id -> the question answered Use default that owns it (its Yes and No lists), minus the settings that cannot be put
#           back (T.OneWay) and the ones another question applies; whether each one needs putting back depends on the PC (Get-GuidedResetRows)
#   ResetList  those ids, in catalog order
function Get-GuidedSets {
    if ($script:GuidedCache) { return $script:GuidedCache }
    $apply = [ordered]@{}; $keep = @{}; $resetQ = [ordered]@{}
    foreach ($q in $script:GuidedQuestions) {
        if (-not (Test-GuidedAsked $q)) { continue }
        $a = [string]$script:GuidedAnswers[[string]$q.Id]
        if ($a -ceq 'Default') { foreach ($id in @(@($q.Yes) + @($q.No))) { if (-not $resetQ.Contains($id)) { $resetQ[$id] = [string]$q.Id } } }
        if ($a -ceq 'Yes') { foreach ($id in @($q.Yes)) { if (-not $apply.Contains($id)) { $apply[$id] = [string]$q.Id } } }
        if ($a -ceq 'No')  { foreach ($id in @($q.No))  { if (-not $apply.Contains($id)) { $apply[$id] = [string]$q.Id } } }
        # a Yes, a Not sure and a question not answered yet all protect the Keep list
        if ($a -cne 'No') {
            foreach ($id in @($q.Keep)) { if (-not $keep.ContainsKey($id)) { $keep[$id] = [string]$q.Id } }
        }
    }
    # a "Do you want X?" question (Yes applies, No / Not sure applies nothing) protects nothing when it is not Yes: its Keep list is
    # empty then. A question that applies on Yes and keeps on No (none yet) would need its own rule.
    $allowOneWay = ([string]$script:GuidedAnswers['uninstall'] -ceq 'Yes')
    $final = @(); $blocked = [ordered]@{}; $noUn = @()
    foreach ($id in @($script:Rows.Keys)) {
        if (-not $apply.Contains([string]$id)) { continue }
        if ($keep.ContainsKey([string]$id)) { $blocked[[string]$id] = [string]$keep[[string]$id]; continue }
        $row = $script:Rows[$id]
        if ($row.T.OneWay -and -not $allowOneWay) { $noUn += [string]$id; continue }
        $final += [string]$id
    }
    $reset = [ordered]@{}
    foreach ($id in @($script:Rows.Keys)) {
        if (-not $resetQ.Contains([string]$id)) { continue }
        if ($apply.Contains([string]$id)) { continue }          # another question applies it: that answer is the more definite one
        $row = $script:Rows[$id]
        if ($row.T.OneWay -or $row.T.Once) { continue }         # removed apps cannot be put back
        $reset[[string]$id] = [string]$resetQ[[string]$id]
    }
    $script:GuidedCache = @{ Apply = $apply; Keep = $keep; Final = @{}; FinalList = @($final); Blocked = $blocked; NoUninstall = @($noUn); Reset = $reset; ResetList = @($reset.Keys) }
    foreach ($id in $final) { $script:GuidedCache.Final[[string]$id] = [string]$apply[[string]$id] }
    return $script:GuidedCache
}

# Settings that are applied on this PC right now but that the answers say are in use: the preset leaves them as they are.
function Get-GuidedInUseApplied {
    $sets = Get-GuidedSets
    $out = @()
    foreach ($id in @($script:Rows.Keys)) {
        if (-not $sets.Keep.ContainsKey([string]$id)) { continue }
        $row = $script:Rows[$id]
        if ($row.T.Once -or $row.State -ne 'On') { continue }
        if ($sets.Reset.Contains([string]$id)) { continue }          # its question was answered Use default: it is put back, not left
        $qid = [string]$sets.Keep[[string]$id]
        if ([string]$script:GuidedAnswers[$qid] -cne 'Yes') { continue }      # only where the user really said Yes
        $out += $row
    }
    return $out
}

# What Use default does to one setting on this PC: 'Undo' or 'Apply' when it is not at its Windows default, '' when it is (or cannot be
# changed). The Windows default is the position "Reset all" lines up: not applied, except for a setting whose Windows default is the
# position the app applies (Game Mode on), which has to be on.
function Get-GuidedResetAction {
    param($row)
    $st = [string]$row.State
    if ($st -eq 'NA' -or $st -eq 'Checking' -or $st -eq 'Unknown') { return '' }
    if ($row.T.OneWay -or $row.T.Once) { return '' }
    if ($row.T.Choices) { if ($st -eq 'On') { return 'Undo' }; return '' }       # an option is in force: back to the Windows default option
    if (Test-OffIsExplicit $row.T) {
        if ($st -eq 'On') { return '' }
        return 'Apply'
    }
    if ($st -eq 'On' -or $st -eq 'Partial') { return 'Undo' }
    return ''
}

# The settings that Use default puts back on this PC right now, in catalog order (the rows, not the ids)
function Get-GuidedResetRows {
    $sets = Get-GuidedSets
    $out = @()
    foreach ($id in @($sets.ResetList)) {
        $row = $script:Rows[[string]$id]
        if (-not $row) { continue }
        if ((Get-GuidedResetAction $row) -ne '') { $out += $row }
    }
    return $out
}

function Get-GuidedCounts {
    $asked = @(Get-GuidedAsked)
    $done = @($asked | Where-Object { $script:GuidedAnswers.ContainsKey([string]$_.Id) }).Count
    return @{ Asked = $asked.Count; Done = $done; Left = ($asked.Count - $done) }
}

# =============================================================================
# CONSOLE MODE (-NoGui, -List, -Preset, -Apply, -Undo)
# =============================================================================
function Split-Ids {
    param($values)
    $out = @()
    foreach ($v in @($values)) {
        foreach ($p in ([string]$v -split ',')) {
            $p = $p.Trim()
            if ($p) { $out += $p }
        }
    }
    return $out
}

# Check every setting; returns id -> event (State, Detail). Messages from the check are printed.
# One name from -Apply / -Undo:  "id"  or  "id=option"  (an option is for a setting that has options, e.g. mpo=full).
# Returns @{ Id; Choice } ('' when no option was given).
function Split-IdChoice {
    param([string]$raw)
    $i = $raw.IndexOf('=')
    if ($i -lt 0) { return @{ Id = $raw.Trim(); Choice = '' } }
    return @{ Id = $raw.Substring(0, $i).Trim(); Choice = $raw.Substring($i + 1).Trim() }
}

function Invoke-ConsoleScan {
    $script:Q = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    Write-Host 'Checking this PC...' -ForegroundColor Cyan
    $null = Invoke-Scan
    $states = @{}
    $ev = $null
    while ($script:Q.TryDequeue([ref]$ev)) {
        if ($ev.Kind -eq 'state') { $states[$ev.Id] = $ev }
        elseif ($ev.Kind -eq 'log') { Write-Host $ev.Text -ForegroundColor $ev.Color }
    }
    $script:Q = $null
    return $states
}

function Get-ConsoleState {
    param($States, [string]$id)
    if ($States.ContainsKey($id)) { return [string]$States[$id].State }
    return 'Unknown'
}

function Write-ConsoleList {
    param($States)
    foreach ($cat in @($script:Catalog | ForEach-Object { $_.Cat } | Select-Object -Unique)) {
        Write-Host ''
        Write-Host $cat -ForegroundColor Cyan
        foreach ($t in $script:Catalog) {
            if ($t.Cat -ne $cat) { continue }
            $st = Get-ConsoleState $States $t.Id
            $mine = ''; if ($States.ContainsKey($t.Id)) { $mine = [string]$States[$t.Id].Mine }
            $text = Get-StateText @{ State = $st; Mine = $mine; Once = [bool]$t.Once; T = $t; Choice = $(if ($States.ContainsKey($t.Id)) { [string]$States[$t.Id].Choice } else { '' }) }
            $col = 'Gray'
            if ($st -eq 'On') { $col = 'Green' }
            elseif ($st -eq 'Partial') { $col = 'Yellow' }
            elseif ($st -eq 'NA') { $col = 'DarkGray' }
            # the switch: the Windows default, and where -Apply puts it
            $mark = ''
            if (-not $t.Once -and -not $t.Choices) {
                $goes = 'off'; if (Get-SwitchGoesOn $t $false) { $goes = 'on' }
                $mark = ('  [Windows default: {0}; -Apply turns it {1}]' -f $t.Def, $goes)
            }
            if ($t.OneWay) { $mark += '  [one-way]' }
            if ($t.Once) { $mark = '  [runs once when you use -Apply]' }
            if ($t.Choices) {
                $opts = @($t.Choices | Where-Object { [string]$_.Key -ne 'default' } | ForEach-Object { [string]$_.Key })
                $mark = '  [options: ' + ($opts -join ', ') + '; Windows default: ' + [string]$t.Def + ']'
                $now = ''
                if ($st -eq 'On' -and $States.ContainsKey($t.Id)) { $now = [string]$States[$t.Id].Choice }
                if ($now) { $mark += '  [now: ' + $now + ']' }
            }
            if (Get-NotRecReason $t) { $mark += '  [not recommended]' }
            # a setting that cannot be used on this PC says why (for example: Windows Home ignores it)
            if ($st -eq 'NA' -and $States.ContainsKey($t.Id) -and [string]$States[$t.Id].Detail) { $mark += '  (' + [string]$States[$t.Id].Detail + ')' }
            Write-Host ('  {0,-30} {1,-15} {2}{3}' -f $t.Id, $text, $t.Name, $mark) -ForegroundColor $col
        }
    }
    Write-Host ''
    Write-Host 'The state column is the switch (on / off). Apply settings with  -Apply id1,id2  (each one says which way it turns the switch),  put the Windows default back with  -Undo id1,id2,  the Recommended preset with  -Preset' -ForegroundColor DarkGray
    Write-Host 'A setting that lists options takes one:  -Apply id=option  (without an option the first one is used);  -Undo id  puts the Windows default back' -ForegroundColor DarkGray
}

# Works out what -Preset / -Apply / -Undo mean on this PC. Returns Plan (what to do) and Warn (what was skipped, and why).
function Build-ConsolePlan {
    param($States, [bool]$UsePreset, $ApplyIds, $UndoIds)
    $plan = @(); $warn = @(); $seen = @{}; $unknown = 0
    $applyList = @(Split-Ids $ApplyIds)
    $undoList = @(Split-Ids $UndoIds)
    # the same id in both lists is a contradiction: skip it rather than guess
    $both = @{}
    foreach ($a in $applyList) {
        $aid = [string](Split-IdChoice $a).Id
        foreach ($u in $undoList) {
            if ($aid -eq [string](Split-IdChoice $u).Id -and $script:ById.ContainsKey($aid)) { $both[$script:ById[$aid].Id] = $true }
        }
    }
    foreach ($id in @($both.Keys)) { $warn += ("{0}: asked to apply and undo in the same run, skipped" -f $id) }
    if ($UsePreset) {
        foreach ($t in $script:Catalog) {
            if (-not $t.Preset) { continue }
            $st = Get-ConsoleState $States $t.Id
            if ($st -eq 'On' -or $st -eq 'NA') { continue }
            $plan += ,@{ Id = $t.Id; Action = 'Apply' }
            $seen[$t.Id] = 'Apply'
        }
    }
    foreach ($raw in $applyList) {
        $sp = Split-IdChoice $raw
        $t = $script:ById[[string]$sp.Id]
        if (-not $t) { $warn += ("unknown setting '{0}' (run with -List to see the ids)" -f $sp.Id); $unknown++; continue }
        if ($seen.ContainsKey($t.Id) -or $both.ContainsKey($t.Id)) { continue }
        $st = Get-ConsoleState $States $t.Id
        if ($t.Choices) {
            # a setting with options: name one (id=option), or leave it out for the first option; id=default means the Windows default
            $opt = $null
            try { $opt = Resolve-Choice $t ([string]$sp.Choice) } catch {
                $keys = @($t.Choices | ForEach-Object { [string]$_.Key })
                $warn += ("{0}: unknown option '{1}' (options: {2})" -f $t.Id, $sp.Choice, ($keys -join ', ')); $unknown++; continue
            }
            if ($st -eq 'NA') { $warn += ("{0}: not available on this PC, skipped" -f $t.Id); continue }
            $nowKey = ''
            if ($States.ContainsKey($t.Id)) { $nowKey = [string]$States[$t.Id].Choice }
            if ([string]$opt.Key -eq 'default') {
                if ($st -eq 'Off') { $warn += ("{0}: already the Windows default, skipped" -f $t.Id); continue }
                $plan += ,@{ Id = $t.Id; Action = 'Undo' }
                $seen[$t.Id] = 'Undo'
                continue
            }
            if ($st -eq 'On' -and -not [string]$sp.Choice) { $warn += ("{0}: already set ({1}); name an option to change it, e.g. -Apply {0}={2}" -f $t.Id, $nowKey, [string]$opt.Key); continue }
            if ($st -eq 'On' -and $nowKey -eq [string]$opt.Key) { $warn += ("{0}: already set to {1}, skipped" -f $t.Id, $nowKey); continue }
            $plan += ,@{ Id = $t.Id; Action = 'Apply'; Choice = [string]$opt.Key }
            $seen[$t.Id] = 'Apply'
            continue
        }
        if ($sp.Choice) { $warn += ("{0}: has no options, so '{1}' is not understood; use -Apply {0}" -f $t.Id, $sp.Choice); $unknown++; continue }
        if ($st -eq 'NA') { $warn += ("{0}: not available on this PC, skipped" -f $t.Id); continue }
        if ($st -eq 'On') { $warn += ("{0}: already applied, skipped" -f $t.Id); continue }
        $plan += ,@{ Id = $t.Id; Action = 'Apply' }
        $seen[$t.Id] = 'Apply'
    }
    foreach ($raw in $undoList) {
        $sp = Split-IdChoice $raw
        $t = $script:ById[[string]$sp.Id]
        if (-not $t) { $warn += ("unknown setting '{0}' (run with -List to see the ids)" -f $sp.Id); $unknown++; continue }
        if ($both.ContainsKey($t.Id)) { continue }
        if ($sp.Choice) { $warn += ("{0}: -Undo takes no option (it puts the Windows default back); use  -Undo {0}" -f $t.Id); $unknown++; continue }
        if ($seen.ContainsKey($t.Id)) { $warn += ("{0}: applied by -Preset in the same run, not undone" -f $t.Id); continue }
        if ($t.OneWay) { $warn += ("{0}: cannot be undone from here, skipped" -f $t.Id); continue }
        if ($t.Once) { $warn += ("{0}: a one-time action, nothing to undo" -f $t.Id); continue }
        $st = Get-ConsoleState $States $t.Id
        if ($st -eq 'NA') { $warn += ("{0}: not available on this PC, skipped" -f $t.Id); continue }
        if ($st -eq 'Off') { $warn += ("{0}: not applied, nothing to undo" -f $t.Id); continue }
        $plan += ,@{ Id = $t.Id; Action = 'Undo' }
        $seen[$t.Id] = 'Undo'
    }
    return [pscustomobject]@{ Plan = $plan; Warn = $warn; Unknown = $unknown }
}

# Can this console be asked a question? (Not when the input is piped or redirected, e.g. from a scheduled task.)
function Test-ConsoleCanAsk {
    try { return ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) } catch { return $false }
}

function Read-ConsoleYesNo {
    param([string]$Prompt)
    $a = Read-Host $Prompt
    return ([string]$a -match '^\s*(y|yes)\s*$')
}

# The questions some settings ask before they are turned on (see Get-GuardQuestions). In the console:
#   - a setting you named yourself with -Apply counts as your answer, so it is not asked again (a note is printed);
#   - one that -Preset pulled in is asked about here when this console can be answered, otherwise it is skipped.
# Nothing is asked for a -DryRun (nothing changes). Returns the plan that is left, and warnings for what was left out.
function Resolve-ConsoleGuards {
    param($Plan, $ApplyIds, [bool]$Dry)
    $keep = @($Plan); $warn = @()
    if ($Dry) { return [pscustomobject]@{ Plan = $keep; Warn = $warn } }
    $named = @{}
    foreach ($raw in @(Split-Ids $ApplyIds)) { $rid = [string](Split-IdChoice $raw).Id; if ($script:ById.ContainsKey($rid)) { $named[$script:ById[$rid].Id] = $true } }
    $canAsk = Test-ConsoleCanAsk
    foreach ($q in @(Get-GuardQuestions $keep)) {
        $ask = @($q.Ids | Where-Object { -not $named.ContainsKey([string]$_) })
        $said = @($q.Ids | Where-Object { $named.ContainsKey([string]$_) })
        foreach ($id in $said) { $warn += ("{0}: you named it with -Apply, so it is not asked about: {1}" -f $id, $q.Title) }
        if ($ask.Count -eq 0) { continue }
        $drop = $false
        if ($canAsk) {
            Write-Host ''
            Write-Host $q.Title -ForegroundColor Yellow
            Write-Host ([string]$q.Ask) -ForegroundColor Gray
            Write-Host ('This covers: ' + ((@($ask | ForEach-Object { [string]$script:ById[[string]$_].Name })) -join '; ')) -ForegroundColor Gray
            if (-not (Read-ConsoleYesNo 'Apply it anyway? (y = yes, anything else = leave it as it is)')) { $drop = $true; $warn += ("{0}: you answered no, left as it is" -f ($ask -join ', ')) }
        } else {
            $drop = $true
            $warn += ("{0}: skipped - it asks a question first ({1}) and this console cannot be asked. Name it with -Apply {2} to turn it on." -f ($ask -join ', '), $q.Title, ($ask -join ','))
        }
        if ($drop) { $keep = @(Remove-FromPlan $keep $ask) }
    }
    return [pscustomobject]@{ Plan = $keep; Warn = $warn }
}

# Returns the exit code: 0 = fine, 1 = something needs attention
function Start-ConsoleMode {
    param([bool]$ShowList, [bool]$UsePreset, $ApplyIds, $UndoIds)
    Write-Host 'Headroom  -  Debloat Tool' -ForegroundColor Magenta
    $wanted = ($UsePreset -or @(Split-Ids $ApplyIds).Count -gt 0 -or @(Split-Ids $UndoIds).Count -gt 0)
    $states = Invoke-ConsoleScan
    if ($ShowList -or -not $wanted) { Write-ConsoleList $states }
    if (-not $wanted) { return 0 }
    $r = Build-ConsolePlan $states $UsePreset $ApplyIds $UndoIds
    $g = Resolve-ConsoleGuards $r.Plan $ApplyIds ([bool]$DryRun)
    $r = [pscustomobject]@{ Plan = @($g.Plan); Warn = @(@($r.Warn) + @($g.Warn)); Unknown = $r.Unknown }
    Write-Host ''
    foreach ($w in @($r.Warn)) { Write-Host ('  ' + $w) -ForegroundColor Yellow }
    if (@($r.Plan).Count -eq 0) {
        Write-Host 'Nothing to change.' -ForegroundColor Green
        return $(if ($r.Unknown -gt 0) { 1 } else { 0 })
    }
    $last = @(Invoke-Plan $r.Plan)[-1]
    if ($r.Unknown -gt 0) { return 1 }
    if ($last -and $last.Bad -gt 0) { return 1 }
    return 0
}

# =============================================================================
# THE WINDOW, part 1: colours, fonts, sizes, the few Windows calls, and the small helpers.
# All controls live in $script:UI (a hashtable) so every function below can reach them.
# Names to avoid in here (they are also script-level variables / parameters): log, Q, DryRun, List, Preset, Apply, Undo, engine.
# =============================================================================
$script:UI = @{}
$script:Job = $null
$script:LastErr = ''
$script:Scale = 1.0
$script:Th = @{}                  # colours
$script:M = @{}                   # sizes (already scaled for the screen)
$script:TF = @{}                  # text drawing flags
$script:Fonts = @{}
$script:Brushes = @{}
$script:Pens = @{}
$script:Native = $null            # the Windows calls (dark title bar, ...), $null if they could not be set up
$script:LogBuf = New-Object System.Collections.ArrayList
$script:DList = $false            # the list needs repainting
$script:DHead = $false            # group counts need recomputing
$script:DNav = $false             # the side menu, the page title and the numbers on the filter buttons need recomputing
$script:DCounts = $false          # the button / change count needs recomputing
$script:DDetail = $false          # the details panel needs refilling
$script:DProg = $false            # the progress bar needs updating
$script:ProgA = 0
$script:WaitText = ''          # what the check is still waiting for Windows to answer (shown in the status line)
$script:ProgB = 1
$script:BarShown = 0
$script:Mode = 'All settings'     # which state filter button is on (All / Applied / Not applied / Waiting / Recommended / Personal)
$script:Risk = 'Any risk'         # which risk filter button is on (Any risk / Low risk / Medium risk / Risky); it combines with the state filter
$script:RiskNames = @('Any risk', 'Low risk', 'Medium risk', 'Risky')
$script:BtnHot = $null            # the button under the mouse
$script:BtnDown = $null           # the button being pressed
$script:ChipCount = @{}           # filter name -> the number shown on its button ('' = none yet)
$script:TabAccent = @{}           # tab name -> the colour of its box and number when it is not the accent one (the preset window's tabs)
$script:StartupSynced = $false    # the startup list was just read, no need to read it again for the first check

# a size in pixels, scaled for the screen
function Px {
    param([double]$v)
    return [int][math]::Round($v * $script:Scale)
}

function Rgb {
    param([int]$r, [int]$g, [int]$b)
    return [System.Drawing.Color]::FromArgb($r, $g, $b)
}

function Ui-InitTheme {
    # Near-black navy with one light-purple accent: the window and side menu are the darkest navy (#0f0f19), the page is a little lighter,
    # cards lighter again. Purple (accent) is used for the selected tab, switches that are on, the main button and a change that is waiting.
    # The look is flat: a card, a page of the side menu and a panel are a fill with round corners and no outline. An outline is only drawn
    # where it says something: the selected setting and a text box that is being typed in (purple).
    $script:Th = @{
        Bg        = (Rgb 18 18 30)       # the page
        Side      = (Rgb 15 15 25)       # the window frame and the side menu
        SideHot   = (Rgb 31 31 49)       # the page of the side menu under the pointer
        SideSel   = (Rgb 36 32 62)       # the open page of the side menu (a soft purple fill)
        SideBox   = (Rgb 24 24 39)       # a choice in a list at rest (the preset window)
        Panel     = (Rgb 24 24 39)       # dialogs
        Card      = (Rgb 24 24 39)       # cards
        CardHot   = (Rgb 29 29 46)
        CardSel   = (Rgb 33 33 52)
        Head      = (Rgb 24 24 39)
        HeadHot   = (Rgb 29 29 46)
        Raised    = (Rgb 40 40 62)       # buttons, tags
        RaisedHot = (Rgb 52 52 78)
        RaisedDown = (Rgb 31 31 48)
        Border    = (Rgb 64 64 92)
        Tag       = (Rgb 34 34 53)       # the tag pills on a card (quieter than the buttons)
        TagText   = (Rgb 170 170 194)
        Edge      = (Rgb 40 40 60)       # hairlines (under the app name when the menu is scrolled, the track of the progress bar)
        Text      = (Rgb 244 244 251)
        Sub       = (Rgb 200 200 216)
        Mute      = (Rgb 152 152 174)    # descriptions
        Dim       = (Rgb 106 106 128)
        Accent    = (Rgb 183 156 255)    # light purple
        AccentHot = (Rgb 62 51 102)
        AccentDim = (Rgb 49 40 82)
        AccentSoft = (Rgb 43 35 74)      # tinted chips and buttons
        Good      = (Rgb 112 206 100)
        GoodSoft  = (Rgb 28 52 44)
        Warn      = (Rgb 255 160 92)
        WarnSoft  = (Rgb 66 47 40)
        Bad       = (Rgb 255 138 138)
        BadSoft   = (Rgb 70 38 52)
        TintApply = (Rgb 30 28 50)       # a card waiting to be turned on
        TintUndo  = (Rgb 36 27 43)       # a card waiting to be turned off
        TintApplySel = (Rgb 35 33 57)
        TintUndoSel  = (Rgb 42 31 50)
        Hover     = (Rgb 29 29 46)
        Sel       = (Rgb 33 33 52)
        Track     = (Rgb 46 46 68)       # switch, off
        TrackEdge = (Rgb 100 100 130)    # the outline of a switch that is off
        TrackOff  = (Rgb 28 28 44)       # switch, not available
        KnobOff   = (Rgb 196 196 214)
        KnobOn    = (Rgb 22 16 48)
        KnobDim   = (Rgb 72 72 96)
        Thumb     = (Rgb 76 76 104)
        ThumbHot  = (Rgb 124 124 162)
        ThumbTrack = (Rgb 27 27 42)      # the faint groove behind a scroll thumb while the pointer is on the scroll bar
        LogBg     = (Rgb 13 13 22)
        BtnText   = (Rgb 24 16 52)
        GoodText  = (Rgb 118 214 106)       # the green dot of Low risk
        WarnText  = (Rgb 255 170 90)        # the orange dot of Medium risk
        BadText   = (Rgb 255 142 142)       # the red dot of Risky
    }
}

function Ui-InitMetrics {
    $script:M = @{
        Row = (Px 66); Gap = (Px 10); Head = (Px 46); Pad = (Px 20); TogW = (Px 46); TogH = (Px 24); IconD = (Px 44); IconGap = (Px 14); RiskDot = (Px 10); ChoiceY = (Px 52); ChoiceH = (Px 30); ChoiceExtra = (Px 40)
        Sb = (Px 14); Top = (Px 2); Bottom = (Px 20); Radius = (Px 14); BtnR = (Px 10)
        ChipW = (Px 112); ChipH = (Px 24); CountW = (Px 112)
        CardMin = (Px 380); RowMin = (Px 560); ColGap = (Px 18); Wheel = (Px 168)
        Side = (Px 244); Gutter = (Px 28); Details = (Px 340); HeaderH = (Px 190); HeaderInfoH = (Px 108); FooterH = (Px 88)
        NavTop = (Px 132); SearchY = (Px 80); SearchH = (Px 40); NavRow = (Px 40); NavGap = (Px 4); NavLabel = (Px 40); NavSb = (Px 12); NavWheel = (Px 80)
    }
}

function Ui-InitFlags {
    $base = 'VerticalCenter, EndEllipsis, NoPrefix, SingleLine, NoPadding'
    $script:TF = @{
        L = [System.Windows.Forms.TextFormatFlags]('Left, ' + $base)
        R = [System.Windows.Forms.TextFormatFlags]('Right, ' + $base)
        C = [System.Windows.Forms.TextFormatFlags]('HorizontalCenter, ' + $base)
        N = [System.Windows.Forms.TextFormatFlags]'NoPadding, SingleLine, NoPrefix'
        W = [System.Windows.Forms.TextFormatFlags]'Left, Top, WordBreak, EndEllipsis, NoPrefix, NoPadding'
        CW = [System.Windows.Forms.TextFormatFlags]'HorizontalCenter, Top, WordBreak, EndEllipsis, NoPrefix, NoPadding'
    }
}

# ----------------------------------------------------------- fonts, brushes, pens ----
function Ui-NewFont {
    param([string]$family, [double]$size)
    return (New-Object System.Drawing.Font($family, [single]$size))
}

function Ui-Font {
    param([string]$key)
    $f = $script:Fonts[$key]
    if ($f) { return $f }
    switch ($key) {
        'uib'      { $f = Ui-NewFont 'Segoe UI Semibold' 9 }
        'btn'      { $f = Ui-NewFont 'Segoe UI Semibold' 9 }
        'row'      { $f = Ui-NewFont 'Segoe UI' 9.5 }
        'rowName'  { $f = Ui-NewFont 'Segoe UI Semibold' 10 }
        'desc'     { $f = Ui-NewFont 'Segoe UI' 9 }
        'head'     { $f = Ui-NewFont 'Segoe UI Semibold' 10.5 }
        'small'    { $f = Ui-NewFont 'Segoe UI' 8.5 }
        'smallb'   { $f = Ui-NewFont 'Segoe UI Semibold' 8.5 }
        'cap'      { $f = Ui-NewFont 'Segoe UI Semibold' 8 }
        'title'    { $f = Ui-NewFont 'Segoe UI Semibold' 22 }
        'titleS'   { $f = Ui-NewFont 'Segoe UI Semibold' 16 }       # the page title when the name is too long for the big size
        'cardName' { $f = Ui-NewFont 'Segoe UI Semibold' 11.5 }
        'cardId'   { $f = Ui-NewFont 'Segoe UI' 8 }
        'cardDesc' { $f = Ui-NewFont 'Segoe UI' 9.5 }
        'sub'      { $f = Ui-NewFont 'Segoe UI' 10 }
        'brand'    { $f = Ui-NewFont 'Segoe UI Semibold' 11.5 }
        'hero'     { $f = Ui-NewFont 'Segoe UI Semibold' 34 }        # the welcome screen
        'heroSub'  { $f = Ui-NewFont 'Segoe UI' 12 }
        'bigbtn'   { $f = Ui-NewFont 'Segoe UI Semibold' 12 }
        'stepcap'  { $f = Ui-NewFont 'Segoe UI Semibold' 8.5 }
        'wbody'    { $f = Ui-NewFont 'Segoe UI' 11.5 }
        'nav'      { $f = Ui-NewFont 'Segoe UI' 9.5 }
        'navb'     { $f = Ui-NewFont 'Segoe UI Semibold' 9.5 }
        'body'     { $f = Ui-NewFont 'Segoe UI' 9.5 }
        'detTitle' { $f = Ui-NewFont 'Segoe UI Semibold' 14 }
        'mono'     { $f = Ui-NewFont 'Consolas' 9 }
        'monoS'    { $f = Ui-NewFont 'Consolas' 8.5 }
        default    { $f = Ui-NewFont 'Segoe UI' 9 }
    }
    $script:Fonts[$key] = $f
    return $f
}

function Ui-Brush {
    param($c)
    $k = $c.ToArgb()
    $b = $script:Brushes[$k]
    if (-not $b) {
        $b = New-Object System.Drawing.SolidBrush($c)
        $script:Brushes[$k] = $b
    }
    return $b
}

function Ui-Pen {
    param($c, [double]$width = 1)
    $k = [string]$c.ToArgb() + '/' + [string]$width
    $p = $script:Pens[$k]
    if (-not $p) {
        $p = New-Object System.Drawing.Pen($c, [single]$width)
        $script:Pens[$k] = $p
    }
    return $p
}

# The only places that draw. Tests swap these for recording versions.
function Ui-Fill {
    param($g, $c, [int]$x, [int]$y, [int]$w, [int]$h)
    $g.FillRectangle((Ui-Brush $c), $x, $y, $w, $h)
}
function Ui-FillOval {
    param($g, $c, [int]$x, [int]$y, [int]$w, [int]$h)
    $g.FillEllipse((Ui-Brush $c), $x, $y, $w, $h)
}
# a filled shape with straight sides; $pts is a list of @(x, y) corners
function Ui-FillPoly {
    param($g, $c, $pts)
    $list = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
    foreach ($p in $pts) { $list.Add([System.Drawing.PointF]::new([single]$p[0], [single]$p[1])) }
    $g.FillPolygon((Ui-Brush $c), $list.ToArray())
}
function Ui-Line {
    param($g, $c, [double]$width, [int]$x1, [int]$y1, [int]$x2, [int]$y2)
    $g.DrawLine((Ui-Pen $c $width), $x1, $y1, $x2, $y2)
}
# a pen with round ends and round corners (the icons are drawn with it)
function Ui-IconPen {
    param($c, [double]$width)
    $k = 'i' + [string]$c.ToArgb() + '/' + [string]$width
    $p = $script:Pens[$k]
    if (-not $p) {
        $p = New-Object System.Drawing.Pen($c, [single]$width)
        $p.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
        $p.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
        $p.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
        $script:Pens[$k] = $p
    }
    return $p
}
# the outline of an oval
function Ui-StrokeOval {
    param($g, $c, [double]$width, [double]$x, [double]$y, [double]$w, [double]$h)
    $g.DrawEllipse((Ui-IconPen $c $width), [single]$x, [single]$y, [single]$w, [single]$h)
}
# a line through several points, round at the ends and at the corners; $pts is a list of @(x, y)
function Ui-StrokePoly {
    param($g, $c, [double]$width, $pts)
    $list = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
    foreach ($p in $pts) { $list.Add([System.Drawing.PointF]::new([single]$p[0], [single]$p[1])) }
    if ($list.Count -ge 2) { $g.DrawLines((Ui-IconPen $c $width), $list.ToArray()) }
}
function Ui-Text {
    param($g, [string]$s, $font, $c, [int]$x, [int]$y, [int]$w, [int]$h, $flags)
    if ($w -le 0) { return }
    [System.Windows.Forms.TextRenderer]::DrawText($g, $s, $font, [System.Drawing.Rectangle]::new($x, $y, $w, $h), $c, $flags)
}
# the outline of a rectangle with round corners (radius r), as a path
function Ui-RoundPath {
    param([double]$x, [double]$y, [double]$w, [double]$h, [double]$r)
    $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = [Math]::Min(($r * 2.0), [Math]::Min($w, $h))
    if ($d -le 0) {
        $gp.AddRectangle([System.Drawing.RectangleF]::new([single]$x, [single]$y, [single]$w, [single]$h))
        return $gp
    }
    $fx = [single]$x; $fy = [single]$y; $fd = [single]$d
    $fr = [single]($x + $w - $d); $fb = [single]($y + $h - $d)
    $gp.AddArc($fx, $fy, $fd, $fd, [single]180, [single]90)
    $gp.AddArc($fr, $fy, $fd, $fd, [single]270, [single]90)
    $gp.AddArc($fr, $fb, $fd, $fd, [single]0, [single]90)
    $gp.AddArc($fx, $fb, $fd, $fd, [single]90, [single]90)
    $gp.CloseFigure()
    return $gp
}
function Ui-FillRound {
    param($g, $c, [int]$x, [int]$y, [int]$w, [int]$h, [int]$r)
    $gp = Ui-RoundPath $x $y $w $h $r
    try { $g.FillPath((Ui-Brush $c), $gp) } finally { $gp.Dispose() }
}
# A scroll thumb: a thin rounded pill with its right edge at $right. $trackTop / $trackH = the strip it travels in, $thumbY = where the
# thumb starts in that strip, $thumbH = its length. It is slim at rest and grows (with a faint groove behind it) while the pointer is
# on the scroll bar or the thumb is being dragged.
function Ui-PaintThumb {
    param($g, [int]$right, [int]$trackTop, [int]$trackH, [int]$thumbY, [int]$thumbH, [bool]$hot, [bool]$drag)
    $Th = $script:Th
    $bw = Px 5
    $c = $Th.Thumb
    if ($drag -or $hot) { $bw = Px 8; $c = $Th.ThumbHot }
    $x = $right - $bw
    if ($drag -or $hot) { Ui-FillRound $g $Th.ThumbTrack $x $trackTop $bw $trackH ([int]($bw / 2)) }
    Ui-FillRound $g $c $x ($trackTop + $thumbY) $bw $thumbH ([int]($bw / 2))
}
function Ui-StrokeRound {
    param($g, $c, [double]$width, [int]$x, [int]$y, [int]$w, [int]$h, [int]$r)
    $o = $width / 2.0
    $gp = Ui-RoundPath ($x + $o) ($y + $o) ($w - $width) ($h - $width) ([Math]::Max(0.0, ($r - $o)))
    try { $g.DrawPath((Ui-Pen $c $width), $gp) } finally { $gp.Dispose() }
}
# the width of a text in pixels (for putting one thing right after another)
function Ui-Measure {
    param($g, [string]$s, $font)
    if (-not $s) { return 0 }
    $sz = [System.Windows.Forms.TextRenderer]::MeasureText($g, $s, $font, [System.Drawing.Size]::new(10000, 200), $script:TF.N)
    return [int]$sz.Width
}

# the width of a text in pixels when there is no drawing surface at hand (for fitting a text into a label)
function Ui-TextWidth {
    param([string]$s, $font)
    if (-not $s) { return 0 }
    $sz = [System.Windows.Forms.TextRenderer]::MeasureText($s, $font, [System.Drawing.Size]::new(10000, 200), $script:TF.N)
    return [int]$sz.Width
}
# The big page title: the normal size, or the smaller one when the name does not fit the space it has (a long name such as
# "Placebo Tweaks - Not Recommended" would otherwise be cut short with "..." and lose its last words).
function Ui-FitTitle {
    $t = $script:UI.title
    if (-not $t) { return }
    $want = 'title'
    if ([int]$t.Width -gt 0 -and (Ui-TextWidth ([string]$t.Text) (Ui-Font 'title')) -gt [int]$t.Width) { $want = 'titleS' }
    if ($script:TitleFont -ne $want) { $script:TitleFont = $want; $t.Font = (Ui-Font $want) }
}

# ----------------------------------------------------------- calls into Windows ----
# Builds a small class of static methods that call into DLLs, without compiling anything (so it is instant).
# $Defs: array of @{ Name; Lib; Entry (optional); Ret; Args = types; Ansi (optional) }
function Ui-EmitNative {
    param($Defs, [string]$TypeName = 'GamingWinNative')
    $an = New-Object System.Reflection.AssemblyName ('GamingUi' + [guid]::NewGuid().ToString('N'))
    $ab = [System.Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly($an, [System.Reflection.Emit.AssemblyBuilderAccess]::Run)
    $mb = $ab.DefineDynamicModule('GamingUiModule')
    $tb = $mb.DefineType($TypeName, [System.Reflection.TypeAttributes]'Public, Abstract, Sealed')
    foreach ($d in $Defs) {
        $cs = [System.Runtime.InteropServices.CharSet]::Unicode
        if ($d.Ansi) { $cs = [System.Runtime.InteropServices.CharSet]::Ansi }
        $entry = [string]$d.Entry
        if (-not $entry) { $entry = [string]$d.Name }
        $argTypes = [Type[]]@($d.Args)
        $m = $tb.DefinePInvokeMethod([string]$d.Name, [string]$d.Lib, $entry,
            [System.Reflection.MethodAttributes]'Public, Static, PinvokeImpl',
            [System.Reflection.CallingConventions]::Standard, $d.Ret, $argTypes,
            [System.Runtime.InteropServices.CallingConvention]::Winapi, $cs)
        $m.SetImplementationFlags([System.Reflection.MethodImplAttributes]::PreserveSig)
    }
    return $tb.CreateType()
}

function Ui-InitNative {
    $script:Native = $null
    try {
        $defs = @(
            @{ Name = 'DwmSetWindowAttribute'; Lib = 'dwmapi.dll'; Ret = [int]; Args = @([IntPtr], [int], [int].MakeByRefType(), [int]) }
            @{ Name = 'SetWindowTheme'; Lib = 'uxtheme.dll'; Ret = [int]; Args = @([IntPtr], [string], [string]) }
            @{ Name = 'SendMessageText'; Entry = 'SendMessageW'; Lib = 'user32.dll'; Ret = [IntPtr]; Args = @([IntPtr], [int], [IntPtr], [string]) }
            @{ Name = 'SendMessageNum'; Entry = 'SendMessageW'; Lib = 'user32.dll'; Ret = [IntPtr]; Args = @([IntPtr], [int], [IntPtr], [IntPtr]) }
            @{ Name = 'SetProcessDPIAware'; Lib = 'user32.dll'; Ret = [bool]; Args = @() }
        )
        $script:Native = Ui-EmitNative $defs
    } catch {
        $script:Native = $null
    }
    # crisp text on high-DPI screens (must happen before the first window is created)
    $n = $script:Native
    if ($n) { try { [void]$n::SetProcessDPIAware() } catch { } }
}

function Ui-GetScale {
    $s = 1.0
    try {
        $g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
        try { $s = [double]$g.DpiX / 96.0 } finally { $g.Dispose() }
    } catch {
        $s = 1.0
    }
    if ($s -lt 1.0) { $s = 1.0 }
    if ($s -gt 3.0) { $s = 3.0 }
    return $s
}

function Ui-WorkArea {
    return [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
}

# dark title bar (Windows 10 2004 and later, Windows 11)
function Ui-DarkTitle {
    param($form)
    $n = $script:Native
    if (-not $n) { return }
    try {
        $v = 1
        $r = $n::DwmSetWindowAttribute($form.Handle, 20, [ref]$v, 4)
        if ($r -ne 0) { [void]$n::DwmSetWindowAttribute($form.Handle, 19, [ref]$v, 4) }
    } catch { }
}

# Windows 11: paint the title bar and the window border in the page colour (older Windows ignores this)
function Ui-TitleColor {
    param($form)
    $n = $script:Native
    if (-not $n) { return }
    $bg = $script:Th.Side
    $fg = $script:Th.Text
    try {
        $c = [int]($bg.R + 256 * $bg.G + 65536 * $bg.B)          # a COLORREF is 0x00BBGGRR
        $t = [int]($fg.R + 256 * $fg.G + 65536 * $fg.B)
        [void]$n::DwmSetWindowAttribute($form.Handle, 35, [ref]$c, 4)     # caption colour
        [void]$n::DwmSetWindowAttribute($form.Handle, 34, [ref]$c, 4)     # border colour
        [void]$n::DwmSetWindowAttribute($form.Handle, 36, [ref]$t, 4)     # caption text colour
    } catch { }
}

# dark scroll bars on a text box
function Ui-DarkScroll {
    param($ctl)
    $n = $script:Native
    if (-not $n) { return }
    try { [void]$n::SetWindowTheme($ctl.Handle, 'DarkMode_Explorer', $null) } catch { }
}

# the grey hint text inside the search box
function Ui-Cue {
    param($ctl, [string]$text)
    $n = $script:Native
    if (-not $n) { return }
    try { [void]$n::SendMessageText($ctl.Handle, 0x1501, [IntPtr]1, $text) } catch { }
}

# stop / allow a text box to repaint while it is being filled
function Ui-Redraw {
    param($ctl, [bool]$on)
    $n = $script:Native
    if (-not $n) { return }
    try {
        $w = 0; if ($on) { $w = 1 }
        [void]$n::SendMessageNum($ctl.Handle, 0x000B, [IntPtr]$w, [IntPtr]::Zero)
        if ($on) { $ctl.Invalidate() }
    } catch { }
}

# a stand-in for the list control's double buffering (the property is protected, so it goes through reflection)
function Ui-DoubleBuffer {
    param($ctl)
    $flags = [System.Reflection.BindingFlags]'Instance, NonPublic'
    try {
        $styles = [System.Windows.Forms.ControlStyles]'UserPaint, AllPaintingInWmPaint, OptimizedDoubleBuffer, ResizeRedraw'
        [void][System.Windows.Forms.Control].GetMethod('SetStyle', $flags).Invoke($ctl, @($styles, $true))
    } catch {
        try { [System.Windows.Forms.Control].GetProperty('DoubleBuffered', $flags).SetValue($ctl, $true, $null) } catch { }
    }
}

# ----------------------------------------------------------- log, status, progress ----
function Get-LogColor {
    param([string]$name)
    switch ($name) {
        'Cyan'     { return (Rgb 96 200 230) }
        'Green'    { return (Rgb 120 220 140) }
        'Yellow'   { return (Rgb 240 200 100) }
        'Red'      { return (Rgb 255 120 120) }
        'DarkGray' { return (Rgb 124 124 136) }
        'White'    { return (Rgb 245 245 248) }
    }
    return (Rgb 196 196 206)
}

# Lines are collected and written to the log box together (Ui-FlushLog), which is much faster than one by one
function Ui-Log {
    param([string]$text, [string]$color = 'Gray')
    [void]$script:LogBuf.Add(@{ T = $text; C = $color })
}

function Ui-FlushLog {
    if ($script:LogBuf.Count -eq 0) { return }
    $items = $script:LogBuf.ToArray()
    $script:LogBuf.Clear()
    $b = $script:UI.log
    if (-not $b) { return }
    foreach ($it in $items) {
        $b.SelectionStart = $b.TextLength
        $b.SelectionLength = 0
        $b.SelectionColor = (Get-LogColor $it.C)
        $b.AppendText($it.T + "`n")
    }
    $b.SelectionStart = $b.TextLength
    $b.ScrollToCaret()
}

# A line from the window itself: into the log box and into the log file
function Ui-Note {
    param([string]$text, [string]$color = 'Gray', [switch]$NoFile)
    if ($log -and -not $NoFile) { try { Add-Content -LiteralPath $log -Encoding UTF8 -Value $text } catch { } }
    Ui-Log $text $color
}

function Ui-Fail {
    param($err)
    $m = ''
    try { $m = $err.Exception.Message } catch { }
    if (-not $m) { $m = [string]$err }
    if ($m -eq $script:LastErr) { return }
    $script:LastErr = $m
    try { Ui-Note ('! internal error in the window: ' + $m) 'Red' } catch { }
}

function Ui-Status {
    param([string]$text)
    $s = $script:UI.status
    if ($s -and [string]$s.Text -ne $text) { $s.Text = $text }
}

# The progress bar is thin and drawn by two panels: a track and the part that is filled
function Ui-Progress {
    param([int]$a, [int]$b)
    $script:ProgA = $a
    $script:ProgB = $b
    $script:DProg = $true
}

function Ui-ApplyBar {
    $v = 0
    if ($script:ProgB -gt 0) { $v = [int][math]::Round(100.0 * $script:ProgA / $script:ProgB) }
    if ($v -lt 0) { $v = 0 }
    if ($v -gt 100) { $v = 100 }
    $script:BarShown = $v
    $t = $script:UI.barTrack
    $f = $script:UI.barFill
    if ($t -and $f) { $f.Width = [int]($t.Width * $v / 100) }
}

# ----------------------------------------------------------- buttons ----------------
# Buttons are ordinary flat buttons whose Paint event draws over everything (round corners, quiet colours).
# Ui-StyleBtn only sets the colours; Ui-PaintBtn reads them back, so there is one place that decides how a button looks.
# kinds: primary (the purple one) | accent (tinted purple) | secondary | ghost (no background) | chip | chipon | tab | tabon (the filter tabs)
function Ui-StyleBtn {
    param($b)
    $Th = $script:Th
    $kind = [string]$b.Tag
    $on = [bool]$b.Enabled
    $back = $Th.Raised; $fore = $Th.Text; $hover = $Th.RaisedHot; $down = $Th.RaisedDown
    $bsize = 0
    $kind = $kind -replace '^big', ''           # 'bigprimary' / 'bigghost' (the welcome screen) look like 'primary' / 'ghost', only larger
    if ($kind -eq 'primary') {
        if ($on) { $back = $Th.Accent; $fore = $Th.BtnText; $hover = (Rgb 203 184 255); $down = (Rgb 158 128 236) }
        else { $back = $Th.Raised; $fore = $Th.Dim; $hover = $back; $down = $back }
    } elseif ($kind -eq 'accent') {
        $back = $Th.AccentSoft; $fore = $Th.Accent; $hover = $Th.AccentHot; $down = $Th.AccentDim
        if (-not $on) { $back = $Th.Card; $fore = $Th.Dim; $hover = $back; $down = $back }
    } elseif ($kind -eq 'ghost') {
        $back = $Th.Bg; $fore = $Th.Sub; $hover = $Th.Raised; $down = $Th.RaisedDown
        if (-not $on) { $fore = $Th.Dim; $hover = $back; $down = $back }
    } elseif ($kind -eq 'chip') {
        $back = $Th.Card; $fore = $Th.Sub; $hover = $Th.Raised; $down = $Th.RaisedDown
    } elseif ($kind -eq 'chipon') {
        $back = $Th.AccentSoft; $fore = $Th.Accent; $hover = $Th.AccentSoft; $down = $Th.AccentSoft
    } elseif ($kind -eq 'choice' -or $kind -eq 'choiceon') {
        $back = $Th.SideBox; $fore = $Th.Mute; $hover = $Th.SideHot; $down = $Th.SideHot
        if ($kind -eq 'choiceon') { $back = $Th.SideSel; $fore = $Th.Text }
    } elseif ($kind -eq 'tab') {
        $back = $Th.Bg; $fore = $Th.Mute; $hover = $Th.Bg; $down = $Th.Bg
    } elseif ($kind -eq 'tabon') {
        $back = $Th.Bg; $fore = $Th.Text; $hover = $Th.Bg; $down = $Th.Bg
    } else {
        if (-not $on) { $back = $Th.Card; $fore = $Th.Dim; $hover = $back; $down = $back }
    }
    $b.BackColor = $back
    $b.ForeColor = $fore
    $fa = $b.FlatAppearance
    $fa.BorderSize = $bsize
    $fa.BorderColor = $Th.Border
    $fa.MouseOverBackColor = $hover
    $fa.MouseDownBackColor = $down
    $b.Invalidate()
}

# The colour behind a control (what shows in the corners): the fill of the card it sits on, or the colour of its parent
function Ui-BehindColor {
    param($ctl)
    $p = $null
    try { $p = $ctl.Parent } catch { }
    if ($p) {
        $t = $null
        try { $t = $p.Tag } catch { }
        if ($t -is [hashtable] -and $t.Fill) { return $t.Fill }
        $bc = $null
        try { $bc = $p.BackColor } catch { }
        if ($bc -is [System.Drawing.Color]) { return $bc }
    }
    return $script:Th.Bg
}

function Ui-PaintBtn {
    param($b, $g)
    $Th = $script:Th
    $M = $script:M
    $TF = $script:TF
    $w = [int]$b.Width
    $h = [int]$b.Height
    if ($w -le 2 -or $h -le 2) { return }
    $kind = [string]$b.Tag
    $big = ($kind -like 'big*')
    $kind = $kind -replace '^big', ''
    $on = [bool]$b.Enabled
    $fa = $b.FlatAppearance
    $behind = Ui-BehindColor $b
    $hot = ($on -and ($script:BtnHot -eq $b))
    $down = ($hot -and ($script:BtnDown -eq $b))
    $isTab = ($kind -eq 'tab' -or $kind -eq 'tabon')
    $back = $b.BackColor
    if ($down) { $back = $fa.MouseDownBackColor } elseif ($hot) { $back = $fa.MouseOverBackColor }
    elseif ($kind -eq 'ghost' -or $kind -eq 'chip') { $back = $behind }
    if ($isTab) { $back = $behind }                      # a tab that is not open has no box, only its text
    $r = [Math]::Min($M.BtnR, [int]($h / 2))
    Ui-Fill $g $behind 0 0 $w $h
    if ($kind -eq 'choice' -or $kind -eq 'choiceon') {
        # a choice in a list (the preset window): flat like a page of the side menu - a fill and no outline, the name at the left
        $csel = ($kind -eq 'choiceon')
        if ($csel) { Ui-FillRound $g $Th.SideSel 0 0 $w $h (Px 12) }
        elseif ($hot) { Ui-FillRound $g $Th.SideHot 0 0 $w $h (Px 12) }
        else { Ui-FillRound $g $Th.SideBox 0 0 $w $h (Px 12) }
        $ccol = $Th.Mute
        $cfont = Ui-Font 'nav'
        if ($csel) { $ccol = $Th.Text; $cfont = Ui-Font 'navb' } elseif ($hot) { $ccol = $Th.Text }
        Ui-Text $g ([string]$b.Text) $cfont $ccol (Px 16) 0 ($w - (Px 32)) $h $TF.L
        if ($on -and ($b.Focused -eq $true)) { Ui-StrokeRound $g $Th.Accent 1.5 0 0 $w $h (Px 12) }
        return
    }
    if ($kind -eq 'tabon') {
        # the open tab is a filled box (no line under it): the soft purple, or a tint of the tab's own colour (the preset window's tabs)
        $boxFill = $Th.AccentSoft
        if ($script:TabAccent.ContainsKey([string]$b.Name)) {
            $ta = $script:TabAccent[[string]$b.Name]
            $boxFill = Rgb ([int]($behind.R + ($ta.R - $behind.R) * 0.18)) ([int]($behind.G + ($ta.G - $behind.G) * 0.18)) ([int]($behind.B + ($ta.B - $behind.B) * 0.18))
        }
        $iy = Px 2
        Ui-FillRound $g $boxFill 0 $iy $w ($h - 2 * $iy) $r
    } else {
        Ui-FillRound $g $back 0 0 $w $h $r
    }
    if ([int]$fa.BorderSize -gt 0) { Ui-StrokeRound $g $fa.BorderColor 1 0 0 $w $h $r }
    $fore = $b.ForeColor
    if (($kind -eq 'chip' -or $kind -eq 'tab') -and $hot) { $fore = $Th.Text }
    $font = Ui-Font 'btn'
    if ($big) { $font = Ui-Font 'bigbtn' }
    $label = [string]$b.Text
    $cnt = ''
    if ($kind -eq 'chip' -or $kind -eq 'chipon' -or $isTab) { $cnt = [string]$script:ChipCount[[string]$b.Name] }
    if ($cnt) {
        # the label, then the number in a quieter colour, the two together centred
        $sf = Ui-Font 'small'
        $lw = Ui-Measure $g $label $font
        $cw = Ui-Measure $g $cnt $sf
        $gap = Px 7
        $x0 = [int](($w - ($lw + $gap + $cw)) / 2)
        $cc = $Th.Dim
        if ($kind -eq 'chipon') { $cc = $Th.Accent }
        if ($kind -eq 'tabon') { $cc = $Th.Accent }
        if ($isTab -and $script:TabAccent.ContainsKey([string]$b.Name)) { $cc = $script:TabAccent[[string]$b.Name] }
        Ui-Text $g $label $font $fore $x0 0 ($lw + (Px 6)) $h $TF.L
        Ui-Text $g $cnt $sf $cc ($x0 + $lw + $gap) 0 ($cw + (Px 6)) $h $TF.L
    } else {
        Ui-Text $g $label $font $fore 0 0 $w $h $TF.C
    }
    if ($on -and ($b.Focused -eq $true)) { Ui-StrokeRound $g $Th.Accent 1.5 0 0 $w $h $r }
}

# "Preview only": the label on the left and a small switch on the right
function Ui-PaintSwitch {
    param($b, $g)
    $Th = $script:Th
    $M = $script:M
    $TF = $script:TF
    $w = [int]$b.Width
    $h = [int]$b.Height
    if ($w -le 2 -or $h -le 2) { return }
    $on = [bool]$b.Checked
    $behind = Ui-BehindColor $b
    $hot = ($script:BtnHot -eq $b)
    $back = $Th.Card
    if ($hot) { $back = $Th.CardHot }
    Ui-Fill $g $behind 0 0 $w $h
    Ui-FillRound $g $back 0 0 $w $h $M.BtnR
    $fore = $Th.Sub
    if ($on) { $fore = $Th.Text }
    $swW = Px 36
    $swH = Px 20
    Ui-Text $g ([string]$b.Text) (Ui-Font 'btn') $fore (Px 14) 0 ($w - $swW - (Px 36)) $h $TF.L
    Ui-DrawToggle $g ($w - $swW - (Px 14)) ([int](($h - $swH) / 2)) $on $true $swW $swH
    if ($b.Focused -eq $true) { Ui-StrokeRound $g $Th.Accent 1.5 0 0 $w $h $M.BtnR }
}

function New-Btn {
    param([string]$text, [int]$w, [string]$kind = 'secondary', [string]$tip = '', [int]$h = 36)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Size = New-Object System.Drawing.Size((Px $w), (Px $h))
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.UseVisualStyleBackColor = $false
    $b.Tag = $kind
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.Font = (Ui-Font 'btn')
    Ui-DoubleBuffer $b
    Ui-StyleBtn $b
    Ui-WireBtn $b
    if ($tip -and $script:UI.tip) { $script:UI.tip.SetToolTip($b, $tip) }
    return $b
}

# hover, pressed and the round-cornered drawing
function Ui-WireBtn {
    param($b, [string]$how = 'button')
    $b.Add_MouseEnter({ param($s, $e) try { $script:BtnHot = $s; $s.Invalidate() } catch { } })
    $b.Add_MouseLeave({ param($s, $e) try { if ($script:BtnHot -eq $s) { $script:BtnHot = $null }; if ($script:BtnDown -eq $s) { $script:BtnDown = $null }; $s.Invalidate() } catch { } })
    $b.Add_MouseDown({ param($s, $e) try { $script:BtnDown = $s; $s.Invalidate() } catch { } })
    $b.Add_MouseUp({ param($s, $e) try { if ($script:BtnDown -eq $s) { $script:BtnDown = $null }; $s.Invalidate() } catch { } })
    if ($how -eq 'switch') {
        $b.Add_Paint({ param($s, $e) try { $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias; Ui-PaintSwitch $s $e.Graphics } catch { Ui-Fail $_ } })
    } else {
        $b.Add_Paint({ param($s, $e) try { $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias; Ui-PaintBtn $s $e.Graphics } catch { Ui-Fail $_ } })
    }
}

function Ui-SetEnabled {
    param($b, [bool]$on)
    if ($b -and [bool]$b.Enabled -ne $on) {
        $b.Enabled = $on
        Ui-StyleBtn $b
    }
}

# ----------------------------------------------------------- cards ----------------
# A card is a panel with round corners. Its Tag holds how it looks:  Fill, Edge (the outline; the same colour as the fill = none), R (corner radius),
# Icon ('search' draws a magnifying glass at the left). The panel's own colour is the colour of what is behind it.
function Ui-NewCard {
    param($fill, $edge, [int]$radius, [string]$icon = '')
    $c = New-Object System.Windows.Forms.Panel
    $c.BackColor = $script:Th.Bg
    $c.Tag = @{ Fill = $fill; Edge = $edge; R = $radius; Icon = $icon }
    Ui-DoubleBuffer $c
    $c.Add_Paint({ param($s, $e) try { $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias; Ui-PaintCard $s $e.Graphics } catch { Ui-Fail $_ } })
    return $c
}

function Ui-PaintCard {
    param($c, $g)
    $t = $c.Tag
    if ($t -isnot [hashtable]) { return }
    $w = [int]$c.Width
    $h = [int]$c.Height
    if ($w -le 2 -or $h -le 2) { return }
    Ui-FillRound $g $t.Fill 0 0 $w $h $t.R
    Ui-StrokeRound $g $t.Edge 1 0 0 $w $h $t.R
    if ($t.Icon -eq 'search') {
        # a magnifying glass: a ring and a short handle
        $d = Px 12
        $x = Px 14
        $y = [int](($h - $d) / 2) - (Px 1)
        Ui-StrokeRound $g $script:Th.Mute 1.6 $x $y $d $d ([int]($d / 2))
        Ui-Line $g $script:Th.Mute 1.6 ($x + $d - (Px 1)) ($y + $d - (Px 1)) ($x + $d + (Px 4)) ($y + $d + (Px 4))
    }
}

# ----------------------------------------------------------- the question box ----------
# Yes / No in the window's own colours. Falls back to the plain Windows message box if it cannot be built.
function Ui-AskDark {
    param([string]$text, [string]$title, [bool]$warn)
    $Th = $script:Th
    $f = New-Object System.Windows.Forms.Form
    try {
        $f.Text = $title
        $f.Font = (Ui-Font 'ui')
        $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $f.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
        $f.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
        $f.MaximizeBox = $false
        $f.MinimizeBox = $false
        $f.ShowInTaskbar = $false
        $f.BackColor = $Th.Panel
        # long lines wrap at about 80 characters, so count them as more than one
        $lines = 0
        foreach ($ln in @($text -split "`n")) { $lines += [Math]::Max(1, [int][Math]::Ceiling(($ln.Trim("`r").Length) / 80.0)) }
        $hh = (Px 160) + $lines * (Px 19)
        $hh = [Math]::Max((Px 250), [Math]::Min((Px 580), $hh))
        $f.ClientSize = New-Object System.Drawing.Size((Px 580), $hh)

        $strip = New-Object System.Windows.Forms.Panel
        $strip.Dock = [System.Windows.Forms.DockStyle]::Top
        $strip.Height = (Px 3)
        $strip.BackColor = $Th.Accent
        if ($warn) { $strip.BackColor = $Th.Warn }

        $head = New-Object System.Windows.Forms.Label
        $head.Dock = [System.Windows.Forms.DockStyle]::Top
        $head.Height = (Px 50)
        $head.Text = $title
        $head.Font = (Ui-Font 'detTitle')
        $head.ForeColor = $Th.Text
        $head.BackColor = $Th.Panel
        $head.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
        $head.Padding = New-Object System.Windows.Forms.Padding((Px 20), (Px 4), (Px 20), 0)

        $bar = New-Object System.Windows.Forms.Panel
        $bar.Dock = [System.Windows.Forms.DockStyle]::Bottom
        $bar.Height = (Px 64)
        $bar.BackColor = $Th.Bg
        $no = New-Btn 'No' 96 'secondary' '' 36
        $yes = New-Btn 'Yes' 96 'primary' '' 36
        $no.DialogResult = [System.Windows.Forms.DialogResult]::No
        $yes.DialogResult = [System.Windows.Forms.DialogResult]::Yes
        $cw = $f.ClientSize.Width
        $no.Location = New-Object System.Drawing.Point(($cw - (Px 20) - $no.Width), (Px 14))
        $yes.Location = New-Object System.Drawing.Point(($no.Left - (Px 10) - $yes.Width), (Px 14))
        $bar.Controls.Add($yes)
        $bar.Controls.Add($no)

        $body = New-Object System.Windows.Forms.Panel
        $body.Dock = [System.Windows.Forms.DockStyle]::Fill
        $body.BackColor = $Th.Panel
        $body.Padding = New-Object System.Windows.Forms.Padding((Px 20), 0, (Px 12), (Px 10))
        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Multiline = $true
        $tb.ReadOnly = $true
        $tb.BorderStyle = [System.Windows.Forms.BorderStyle]::None
        $tb.BackColor = $Th.Panel
        $tb.ForeColor = $Th.Text
        $tb.Font = (Ui-Font 'body')
        $tb.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
        $tb.TabStop = $false
        $tb.Dock = [System.Windows.Forms.DockStyle]::Fill
        $tb.Text = ($text -replace "`r?`n", "`r`n")
        $body.Controls.Add($tb)

        # the one added first fills what is left; each one added later is laid out before it
        $f.Controls.Add($body)
        $f.Controls.Add($bar)
        $f.Controls.Add($head)
        $f.Controls.Add($strip)
        $f.CancelButton = $no
        $f.ActiveControl = $no
        $f.Add_HandleCreated({ param($s, $e) try { Ui-DarkTitle $s } catch { } })
        $owner = $script:UI.form
        if ($owner) { $ans = $f.ShowDialog($owner) } else { $ans = $f.ShowDialog() }
        return ($ans -eq [System.Windows.Forms.DialogResult]::Yes)
    } finally {
        try { $f.Dispose() } catch { }
    }
}

function Ui-Ask {
    param([string]$text, [string]$title, [bool]$warn = $false)
    $res = $null
    try { $res = Ui-AskDark $text $title $warn } catch { $res = $null }
    if ($null -ne $res) { return [bool]$res }
    $icon = [System.Windows.Forms.MessageBoxIcon]::Question
    if ($warn) { $icon = [System.Windows.Forms.MessageBoxIcon]::Warning }
    $ans = [System.Windows.Forms.MessageBox]::Show($script:UI.form, $text, $title, [System.Windows.Forms.MessageBoxButtons]::YesNo, $icon, [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
    return ($ans -eq [System.Windows.Forms.DialogResult]::Yes)
}

# =============================================================================
# THE WINDOW, part 2: the settings list.
# It is one custom-drawn control instead of a ListView. Only the rows that are on screen are ever drawn and a
# change repaints once, which is what makes it fast. A "view entry" is a small hashtable per line:
#   row:  Kind='row'  Id Key Cat Name Desc Y H Idx Checked Enabled State Action StateText NextText HeadText Tint
#         StateKey NextKey HeadKey ChipText ChipKey Failed   Choices Pick Now
#         (Choices = $null, or for a setting with options the list of @{ Key; Short; Label }; Pick = the key that is picked on the card,
#          Now = the key of the option that is in force, '' when not known. Such a card has a row of option buttons instead of a switch.)
#   head: Kind='head' Key Cat Title CountText Y H Idx Open
#   info: Kind='info' Key Cat Title Sub Lines Note Chip ChipKey Span Y H Idx  (a read-out card, see u6-sys.ps1; it has no switch and cannot be
#         selected. Its height depends on what it says, so a line of the list is as tall as its tallest card.)
# Each row is drawn as a card: its id in small grey letters, the title, a few tags, the description (two lines), then a risk badge,
# a small status chip and the switch. Cards sit in one column, or in two when the list is wide enough (X and W of an entry say where).
# A head is a section title across the whole width; it is only in the list on the "All settings" page (a category page has no heads).
# Names used for local variables in this file: $Th = colours, $M = sizes, $Cl = column positions.
# =============================================================================
$script:Groups = New-Object System.Collections.ArrayList     # @{ Cat; Head; Rows } for every group that has something to show
$script:View = New-Object System.Collections.ArrayList       # the entries that are in the list now, top to bottom
$script:Total = 0                                            # height of everything in the list
$script:ScrollY = 0
$script:ListW = 700
$script:ListH = 500
$script:SelKey = ''                                          # key of the selected entry ('' = none)
$script:HotEntry = $null                                     # the entry under the mouse
$script:HotZone = ''
$script:HotLine = ''                                          # the line of a Home card under the pointer that has an explanation (its Id)
$script:Collapsed = @{}
$script:Filtering = $false                                   # a search or a filter button is hiding rows: show every group open
$script:Single = $false                                      # one category page: no section titles
$script:NavCat = ''                                          # the category page that is showing ('' = all settings)
$script:DragOff = -1                                         # >= 0 while the scroll thumb is being dragged
$script:MX = -1
$script:MY = -1
$script:Col = @{}
$script:CursorIs = ''
$script:FirstSel = -1                                        # index of the first entry that can be selected (-1 = none: a page of read-outs only)

# ----------------------------------------------------------- sizes and scrolling ----
function Ui-ListSize {
    $l = $script:UI.list
    if ($l) {
        $cs = $l.ClientSize
        if ([int]$cs.Width -gt 0) { $script:ListW = [int]$cs.Width }
        if ([int]$cs.Height -gt 0) { $script:ListH = [int]$cs.Height }
    }
    $M = $script:M
    $right = $script:ListW - $M.Sb                      # where the cards end (the scroll bar lives to the right of that)
    # one column of cards, or two when each card can still be wide enough
    $cols = 1
    if ($right -ge (2 * $M.CardMin + $M.ColGap)) { $cols = 2 }
    $cw = [int][Math]::Floor(($right - ($cols - 1) * $M.ColGap) / $cols)        # rounded down: two cards and the gap never run past the list
    $oldCols = [int]$script:Col.Cols
    $oldCw = [int]$script:Col.CardW
    $script:Col = @{ Right = $right; Cols = $cols; CardW = $cw }
    if ($oldCols -ne $cols -or $oldCw -ne $cw) { Ui-Layout }
    Ui-ClampScroll
}

function Ui-ClampScroll {
    $max = [Math]::Max(0, $script:Total - $script:ListH)
    if ($script:ScrollY -gt $max) { $script:ScrollY = $max }
    if ($script:ScrollY -lt 0) { $script:ScrollY = 0 }
}

function Ui-InvalidateAll {
    $l = $script:UI.list
    if ($l) { $l.Invalidate() }
}

function Ui-InvalidateEntry {
    param($e)
    $l = $script:UI.list
    if (-not $l -or -not $e) { return }
    $l.Invalidate([System.Drawing.Rectangle]::new([int]$e.X, ($e.Y - $script:ScrollY), [int]$e.W, $e.H))
}

function Ui-ScrollTo {
    param([int]$y)
    $max = [Math]::Max(0, $script:Total - $script:ListH)
    if ($y -gt $max) { $y = $max }
    if ($y -lt 0) { $y = 0 }
    if ($y -eq $script:ScrollY) { return }
    $script:ScrollY = $y
    Ui-InvalidateAll
}

# index of the first entry that ends below y (the first one that has to be drawn)
function Ui-FirstAt {
    param([int]$y)
    $v = $script:View
    $lo = 0
    $hi = $v.Count
    while ($lo -lt $hi) {
        $mid = ($lo + $hi) -shr 1
        $e = $v[$mid]
        if (($e.Y + $e.H) -le $y) { $lo = $mid + 1 } else { $hi = $mid }
    }
    return $lo
}

# index of the entry that contains the point (list coordinates, scroll included), or -1. Without x it is the first entry on that line.
function Ui-HitIndex {
    param([int]$y, [int]$x = -1)
    $i = Ui-FirstAt $y
    $v = $script:View
    if ($i -ge $v.Count) { return -1 }
    $e = $v[$i]
    if ($e.Y -gt $y) { return -1 }
    if ($x -lt 0) { return $i }
    # in a grid several cards share a line: find the one under x
    $j = $i
    while ($j -lt $v.Count -and $v[$j].Y -eq $e.Y) {
        $c = $v[$j]
        if ($x -ge $c.X -and $x -lt ($c.X + $c.W)) { return $j }
        $j++
    }
    return -1
}

function Ui-OnListResize {
    Ui-ListSize
    Ui-InvalidateAll
}

# ----------------------------------------------------------- filling the entries ----
# Copy what the row says into its line (cheap: it only sets fields, nothing is drawn)
function Ui-FillEntry {
    param($row)
    $e = $row.Item
    if (-not $e) { return }
    $a = Get-Action $row
    $st = [string]$row.State
    $note = [string]$row.Note
    # the switch shows the feature: for a setting that turns its feature off when applied, wanting it applied is the switch OFF
    # (a setting that is not on this PC, or not checked yet, has nothing to switch: its switch is off and greyed)
    $e.Checked = $false
    if ($st -ne 'NA' -and $st -ne 'Checking') { $e.Checked = (Get-SwitchOn $row.T ([bool]$row.Want)) }
    if ($row.T.Choices) { $e.Pick = [string]$row.Pick; $e.Now = [string](Get-RealPick $row) }
    $e.State = $st
    # a power plan switch: the card says which plan is active, and an installed plan that is not active offers "Make active"
    $e.Plan = [bool]$row.T.Plan
    $e.PlanActive = (Test-PlanActive $row)
    $e.CanActivate = ($e.Plan -and $st -eq 'On' -and -not $e.PlanActive)
    $e.CanReinstall = ($e.Plan -and $st -eq 'On')                       # "Reinstall": made again the way Headroom installs it
    $e.Action = $a
    $e.Enabled = ($st -ne 'NA' -and $st -ne 'Checking')
    $e.StateText = Get-StateText $row
    $e.NextText = Get-NextText $row
    $e.HeadText = Get-HeadsUp $row.T
    $e.Failed = $note.StartsWith('Failed')
    $e.Tint = ''
    if ($a -eq 'Apply') { $e.Tint = 'TintApply' } elseif ($a -eq 'Undo') { $e.Tint = 'TintUndo' }
    $sk = 'Sub'
    if ($st -eq 'On') { $sk = 'Good' }
    elseif ($st -eq 'Partial' -or $st -eq 'Unknown') { $sk = 'Warn' }
    elseif ($st -eq 'NA' -or $st -eq 'Checking') { $sk = 'Dim' }
    $e.StateKey = $sk
    $nk = 'Sub'
    if ($e.Failed) { $nk = 'Bad' }
    elseif ($note -eq 'Done') { $nk = 'Good' }
    elseif ($note -eq 'Working...') { $nk = 'Accent' }
    elseif (-not $note) {
        if ($a -eq 'Apply') { $nk = 'Accent' } elseif ($a -eq 'Undo') { $nk = 'Warn' }
    }
    $e.NextKey = $nk
    $hk = 'Sub'
    if ($row.T.Risk -eq 'security') { $hk = 'Warn' }
    $e.HeadKey = $hk
    # the chip on the right says something only when there is something to say
    $ct = ''; $ck = 'Sub'
    if ($note) { $ct = $note; $ck = $nk }
    elseif ($a) {
        # the chip says what the SWITCH will do (an -Inv setting that is applied goes off)
        $goOn = $false
        if (-not $row.T.Choices) { $goOn = [bool](Get-SwitchGoesOn $row.T ($a -eq 'Undo')) } else { $goOn = ($a -eq 'Apply') }
        if ($goOn) { $ct = 'Will turn on'; $ck = 'Accent' } else { $ct = 'Will turn off'; $ck = 'Warn' }
        if ($row.T.Choices) { if ($a -eq 'Apply') { $ct = 'Will change' } else { $ct = 'Will reset' } }
        if ($row.T.Once) { $ct = 'Will run' }
        if ($row.T.Plan) { if ($a -eq 'Apply') { $ct = 'Will install' } else { $ct = 'Will delete' } }
    }
    elseif ($st -eq 'Partial') { $ct = 'Partly changed'; $ck = 'Warn' }
    elseif ($st -eq 'On' -and $row.Mine -eq 'no' -and -not $row.T.Plan) {
        if ($row.T.Choices) { $ct = 'Already set'; $ck = 'Good' }
        elseif (Get-SwitchOn $row.T $true) { $ct = 'Already on'; $ck = 'Good' }
        else { $ct = 'Already off'; $ck = 'Good' }
    }
    elseif ($st -eq 'Unknown') { $ct = 'Unknown'; $ck = 'Warn' }
    elseif ($st -eq 'NA') { $ct = 'Not on this PC'; $ck = 'Dim' }
    elseif ($st -eq 'Checking') { $ct = 'Checking...'; $ck = 'Dim' }
    $e.ChipText = $ct
    $e.ChipKey = $ck
}

# The "3 of 12 applied" text of every group header (one pass over all rows)
function Ui-FillHeads {
    $gc = Get-GroupCounts
    foreach ($g in $script:Groups) {
        $g.Head.CountText = Get-GroupCountText $gc[[string]$g.Cat]
    }
}

# Put the entries in order, top to bottom, and work out where each one is (X and W too: a line holds one card, or two in a grid).
# A group has Info (read-out cards, on top) and Rows (settings). A read-out may take the whole width (Span 2); the cards of one line
# all get the height of the tallest of them.
function Ui-Layout {
    $M = $script:M
    $view = New-Object System.Collections.ArrayList
    $y = $M.Top
    $single = [bool]$script:Single
    $cols = [Math]::Max(1, [int]$script:Col.Cols)
    $cw = [int]$script:Col.CardW
    if ($cw -le 0) { $cw = [Math]::Max((Px 100), $script:ListW - $M.Sb) }
    $full = $cw * $cols + $M.ColGap * ($cols - 1)
    # the read-out cards use the grid as soon as two of them fit; a settings row needs more room for its text, so while the columns are
    # narrower than RowMin the rows keep to one per line, the whole width
    $rowWide = [bool]($cols -gt 1 -and $cw -lt $M.RowMin)
    foreach ($g in $script:Groups) {
        $open = ($single -or $script:Filtering -or -not [bool]$script:Collapsed[[string]$g.Cat])
        $h = $g.Head
        $h.Open = $open
        $h.X = 0
        $h.W = $full
        if ($single) {
            $h.Y = -1
            $h.H = 0
            $h.Idx = -1
        } else {
            $h.Y = $y
            $h.H = $M.Head
            $h.Idx = $view.Count
            [void]$view.Add($h)
            $y += $M.Head
        }
        $c = 0
        $line = @()
        $lineH = 0
        $prev = ''
        $items = New-Object System.Collections.ArrayList
        if ($g.Info) { foreach ($x in @($g.Info)) { [void]$items.Add($x) } }
        foreach ($x in @($g.Rows)) { [void]$items.Add($x) }
        foreach ($r in $items) {
            if (-not $open) {
                $r.Y = -1
                $r.Idx = -1
                continue
            }
            # a line ends when the next entry is a read-out that wants the whole width, or the first settings card after read-outs
            $wide = (($r.Kind -eq 'info' -and ($cols -le 1 -or [int]$r.Span -ge 2)) -or ($r.Kind -ne 'info' -and $rowWide))
            if (($wide -or ($prev -eq 'info' -and $r.Kind -ne 'info')) -and $c -gt 0) {
                foreach ($e in $line) { $e.H = $lineH }
                $y += $lineH
                $c = 0; $line = @(); $lineH = 0
            }
            if ($r.Kind -eq 'info') {
                $iw = $cw
                if ($wide) { $iw = $full }
                Info-Prepare $r $iw
            } else {
                $r.W = $cw
                if ($rowWide) { $r.W = $full }
                $r.H = (Ui-RowGeom $r).NatH                       # as tall as its title needs (one line: the usual height)
            }
            if ($wide) {
                $r.X = 0
                $r.Y = $y
                $r.Idx = $view.Count
                [void]$view.Add($r)
                $y += $r.H
            } else {
                $r.X = $c * ($cw + $M.ColGap)
                $r.Y = $y
                $r.Idx = $view.Count
                [void]$view.Add($r)
                $line += $r
                if ($r.H -gt $lineH) { $lineH = $r.H }
                $c++
                if ($c -ge $cols) {
                    foreach ($e in $line) { $e.H = $lineH }
                    $y += $lineH
                    $c = 0; $line = @(); $lineH = 0
                }
            }
            $prev = [string]$r.Kind
        }
        if ($c -gt 0) {                               # the last line of the group is only part full
            foreach ($e in $line) { $e.H = $lineH }
            $y += $lineH
        }
    }
    $script:View = $view
    $script:Total = $y + $M.Bottom
    $script:FirstSel = -1
    for ($i = 0; $i -lt $view.Count; $i++) { if ($view[$i].Kind -ne 'info') { $script:FirstSel = $i; break } }
    Ui-ClampScroll
}

# Build the list again from the rows, using the search text, the category page and the chosen filter button
function Ui-RebuildList {
    $text = ''
    if ($script:UI.find) { $text = ([string]$script:UI.find.Text).Trim() }
    $mode = [string]$script:Mode
    $risk = [string]$script:Risk
    # a search looks at every category; with nothing typed the list shows the category that is picked in the side menu
    $pageCat = ''
    if ($text -eq '') { $pageCat = [string]$script:NavCat }
    $infoPage = [bool](Test-InfoPage $pageCat)
    if ($infoPage) { $mode = 'All settings'; $risk = 'Any risk' }   # the filter buttons do not apply to a page of read-outs
    $script:Filtering = [bool]($text -ne '' -or $mode -ne 'All settings' -or $risk -ne 'Any risk')
    $script:Single = [bool]($pageCat -ne '')
    $byCat = @{}
    foreach ($id in @($script:Rows.Keys)) {
        $row = $script:Rows[$id]
        $row.Item = $null
        $row.Visible = $false
        if ($pageCat -ne '' -and [string]$row.T.Cat -ne $pageCat) { continue }
        if (-not (Test-RowVisible $row $text $mode $risk)) { continue }
        $cat = [string]$row.T.Cat
        if (-not $byCat.ContainsKey($cat)) { $byCat[$cat] = New-Object System.Collections.ArrayList }
        $rb = Get-RiskBadge $row.T
        $nrWhy = Get-NotRecReason $row.T
        $e = @{ Kind = 'row'; Id = [string]$id; Key = [string]$id; Cat = $cat; Name = [string]$row.T.Name; X = 0; W = 0; Y = 0; H = 0; Idx = 0
                Checked = $false; Enabled = $false; State = ''; Action = ''; StateText = ''; NextText = ''; HeadText = ''; Tint = ''
                StateKey = 'Sub'; NextKey = 'Sub'; HeadKey = 'Sub'; ChipText = ''; ChipKey = 'Sub'; Failed = $false
                Risk = [string]$rb.Text; RiskKey = [string]$rb.Key; Tags = @(Get-CardTags $row.T)
                NotRec = [bool]$nrWhy; NotRecWhy = [string]$nrWhy
                Choices = $null; Pick = ''; Now = '' }
        if ($row.T.Choices) { $e.Choices = @($row.T.Choices | ForEach-Object { @{ Key = [string]$_.Key; Short = [string]$_.Short; Label = [string]$_.Label } }) }
        $row.Item = $e
        $row.Visible = $true
        Ui-FillEntry $row
        [void]$byCat[$cat].Add($e)
    }
    $groups = New-Object System.Collections.ArrayList
    foreach ($cat in $script:Cats) {
        # the Display page shows its live cards on top of its settings (not while a filter is narrowing the settings down)
        $info = @()
        if ([string]$cat -eq $pageCat -and -not $script:Filtering) { $info = @(Get-PageCards $pageCat) }
        if (-not $byCat.ContainsKey($cat) -and $info.Count -eq 0) { continue }
        $rows = $byCat[$cat]
        if (-not $rows) { $rows = New-Object System.Collections.ArrayList }
        $head = @{ Kind = 'head'; Key = ('#' + $cat); Cat = [string]$cat; Title = (Split-CatName $cat).Short; CountText = ''; X = 0; W = 0; Y = 0; H = 0; Idx = 0; Open = $true }
        [void]$groups.Add(@{ Cat = [string]$cat; Head = $head; Rows = $rows; Info = $info })
    }
    if ($infoPage) {
        $head = @{ Kind = 'head'; Key = ('#' + $pageCat); Cat = [string]$pageCat; Title = (Split-CatName $pageCat).Short; CountText = ''; X = 0; W = 0; Y = 0; H = 0; Idx = 0; Open = $true }
        [void]$groups.Add(@{ Cat = [string]$pageCat; Head = $head; Rows = (New-Object System.Collections.ArrayList); Info = @(Get-PageCards $pageCat) })
    }
    $script:Groups = $groups
    $script:HotEntry = $null
    $script:HotZone = ''
    $script:HotLine = ''
    Ui-FillHeads
    Ui-Layout
    # keep the selection while its line is still there
    if ($script:SelKey) {
        $found = $false
        foreach ($e in $script:View) { if ($e.Key -eq $script:SelKey) { $found = $true; break } }
        if (-not $found) { $script:SelKey = '' }
    }
    $script:DList = $true
    $script:DCounts = $true
    $script:DDetail = $true
    $script:DNav = $true
    Ui-Flush
}

# the search text or a filter button changed: show the matches from the top
function Ui-OnFilterChanged {
    Ui-RebuildList
    Ui-ScrollTo 0
}

function Ui-StyleChips {
    foreach ($b in @($script:UI.chips)) {
        $k = 'tab'
        # two rows of buttons: the state filter and the risk filter, each with its own one that is on
        if ($script:RiskNames -contains [string]$b.Name) {
            if ([string]$b.Name -eq $script:Risk) { $k = 'tabon' }
        } elseif ([string]$b.Name -eq $script:Mode) { $k = 'tabon' }
        $b.Tag = $k
        Ui-StyleBtn $b
    }
}

function Ui-SetMode {
    param([string]$mode)
    if ($script:RiskNames -contains $mode) { $script:Risk = $mode } else { $script:Mode = $mode }
    Ui-StyleChips
    Ui-OnFilterChanged
}

# ----------------------------------------------------------- painting ---------------
# The switch. $w and $h default to the size used in the list. On: purple with a dark knob. Off: grey with an outline and a light knob.
function Ui-DrawToggle {
    param($g, [int]$x, [int]$y, [bool]$on, [bool]$enabled, [int]$w = 0, [int]$h = 0)
    $Th = $script:Th
    $M = $script:M
    if ($w -le 0) { $w = $M.TogW }
    if ($h -le 0) { $h = $M.TogH }
    $track = $Th.Track
    $knob = $Th.KnobOff
    $edge = $Th.TrackEdge
    if (-not $enabled) { $track = $Th.TrackOff; $knob = $Th.KnobDim; $edge = $null }
    elseif ($on) { $track = $Th.Accent; $knob = $Th.KnobOn; $edge = $null }
    Ui-FillRound $g $track $x $y $w $h ([int]($h / 2))
    if ($edge) { Ui-StrokeRound $g $edge 1 $x $y $w $h ([int]($h / 2)) }
    $pad = [Math]::Max(3, [int]($h / 5))
    $d = $h - 2 * $pad
    if ($on -and $enabled) { $d += [Math]::Max(1, [int]($h / 12)) }       # a slightly bigger knob when on, like Windows 11
    $kx = $x + $pad
    if ($on) { $kx = $x + $w - $d - $pad }
    Ui-FillOval $g $knob $kx ($y + [int](($h - $d) / 2)) $d $d
}

function Ui-PaintHead {
    param($g, $e, [int]$y)
    $Th = $script:Th
    $M = $script:M
    $Cl = $script:Col
    $TF = $script:TF
    $sel = ($e.Key -eq $script:SelKey)
    $hot = ($script:HotEntry -and $script:HotEntry.Key -eq $e.Key)
    $top = Px 16
    $hh = $e.H - $top
    $ty = $y + $top
    # the little arrow: pointing down when open, right when closed
    $cx = Px 9
    $cy = $ty + [int]($hh / 2)
    $d = Px 4
    $d2 = Px 2
    $ac = $Th.Mute
    if ($sel -or $hot) { $ac = $Th.Accent }
    if ($e.Open) {
        Ui-Line $g $ac 1.6 ($cx - $d) ($cy - $d2) $cx ($cy + $d2)
        Ui-Line $g $ac 1.6 $cx ($cy + $d2) ($cx + $d) ($cy - $d2)
    } else {
        Ui-Line $g $ac 1.6 ($cx - $d2) ($cy - $d) ($cx + $d2) $cy
        Ui-Line $g $ac 1.6 ($cx + $d2) $cy ($cx - $d2) ($cy + $d)
    }
    $tx0 = Px 26
    # the heading only carries its title and the count: "Turn all on" and "Turn all off" are the two buttons at the top right of the window
    Ui-Text $g (Get-TitleCase ([string]$e.Title)) (Ui-Font 'head') $Th.Text $tx0 $ty ($Cl.Right - $M.CountW - $tx0 - (Px 6)) $hh $TF.L
    if ($e.CountText) {
        Ui-Text $g $e.CountText (Ui-Font 'small') $Th.Mute ($Cl.Right - $M.CountW) $ty $M.CountW $hh $TF.R
    }
}

# the colour a chip is filled with, for the colour key of its text
function Ui-SoftKey {
    param([string]$key)
    switch ($key) {
        'Accent' { return 'AccentSoft' }
        'Warn'   { return 'WarnSoft' }
        'Good'   { return 'GoodSoft' }
        'Bad'    { return 'BadSoft' }
    }
    return 'Raised'
}

# ---- the compact settings row --------------------------------------------------------------------------------------
# One row is: the title (with small marks after it, level with the middle of the card) and at the right a status chip, the risk
# pill and the switch. There is no description line: the details panel has the whole text. A row with options has the option pill
# on a second line under the title instead of the switch.
# Ui-RowGeom works out where each part goes (offsets from the row's top-left corner); the painter and the hit test both
# use it, so they cannot disagree.

# The tags that become small marks after the title: not the Windows default or the preset (the details say them) and not the category (the page says it)
function Ui-RowTags {
    param($e)
    $own = ''
    try { $own = [string](Get-NavTitle ([string]$e.Cat)) } catch { }
    $list = @()
    foreach ($tg in @($e.Tags)) {
        $s = [string]$tg
        if (-not $s -or $s.StartsWith('Windows default') -or $s -eq $own -or $s -eq 'Recommended preset') { continue }
        $list += $s
    }
    return $list
}

function Ui-RowGeom {
    param($e)
    $M = $script:M
    $f = Ui-Font 'smallb'
    $w = [int]$e.W
    $o = @{}
    $o.TextX = $M.Pad                                   # no icon tile: the title starts at the left padding
    # from the right edge inwards: the switch (not on a row with options), the risk pill, the status chip (left to right here, up and down below)
    $x = $w - $M.Pad
    $o.TogX = -1
    if (-not $e.Choices) { $x -= $M.TogW; $o.TogX = $x; $x -= (Px 12) }
    $rw = (Ui-TextWidth 'Medium risk' $f) + (Px 20)                    # one width for all three, so the pills line up in a column
    $o.RiskDot = $false
    $o.RiskH = Px 22
    if (($x - $rw - $o.TextX) -lt (Px 200)) { $o.RiskDot = $true; $rw = $M.RiskDot; $o.RiskH = $M.RiskDot }       # a narrow row: the risk is a coloured dot
    $o.RiskW = $rw
    $o.RiskX = $x - $rw
    $x = $o.RiskX - (Px 10)
    $o.ChipX = -1
    $o.ChipW = 0
    $o.ChipH = Px 22
    if ($e.ChipText) {
        $cw = (Ui-TextWidth ([string]$e.ChipText) $f) + (Px 22)
        $need = [Math]::Max((Px 280), (Ui-TextWidth (Get-TitleCase ([string]$e.Name)) (Ui-Font 'cardName')) + (Px 4))        # the chip only takes room the whole title can spare: a name is not cut for a chip
        # the "Not recommended" mark matters more than a status chip: the chip only takes room the title and the mark can spare (except "Not on this PC": a setting that is not there cannot be switched, so its reason comes first)
        if ($e.NotRec -and [string]$e.State -ne 'NA') { $need = [Math]::Max($need, (Ui-TextWidth (Get-TitleCase ([string]$e.Name)) (Ui-Font 'cardName')) + (Px 4) + (Px 8) + (Ui-TextWidth ([string]$script:NotRecText) $f) + (Px 16)) }
        if ($e.Failed -or (($x - $cw - $o.TextX) -ge $need)) { $o.ChipW = $cw; $o.ChipX = $x - $cw; $x = $o.ChipX - (Px 10) }
    }
    $o.TextEnd = $x
    $o.TextW = [Math]::Max(0, $x - $o.TextX)
    # the title: one line (names are kept short; the details panel has the rest). A name that is still too long ends with "..."
    $o.TitleH = Px 24
    $tfont = Ui-Font 'cardName'
    $shownName = Get-TitleCase ([string]$e.Name)
    $tw = Ui-TextWidth $shownName $tfont
    $o.Lines = @($shownName)
    $nl = @($o.Lines).Count
    $lastW = Ui-TextWidth ([string]$o.Lines[$nl - 1]) $tfont
    $o.TitleCut = [bool]($lastW -gt $o.TextW)                          # still too long after all that: the last line ends with "..."
    $o.TitleW = [Math]::Min($o.TextW, ($tw + (Px 4)))                  # (one line) as wide as the text
    if ($nl -gt 1) { $o.TitleW = $o.TextW }
    $o.LastW = [Math]::Min($o.TextW, ($lastW + (Px 4)))
    # the height: the lines of the title with room above and below (a line holds the tallest card of its row, so the card may be taller than this)
    $padV = Px 16
    $o.NatTop = [Math]::Max(($M.Row - $M.Gap), ($nl * $o.TitleH + 2 * $padV))
    $o.NatH = $o.NatTop + $M.Gap
    if ($e.Choices) { $o.NatH += $M.ChoiceExtra }
    $o.CardH = [int]$e.H - $M.Gap
    if ([int]$e.H -le 0) { $o.CardH = $o.NatH - $M.Gap }
    $o.TopH = $o.CardH
    if ($e.Choices) { $o.TopH = $o.CardH - $M.ChoiceExtra }
    $o.ChoiceY = $o.TopH - (Px 4)                                      # the option buttons: on a line of their own, under the title
    $o.TogY = [int](($o.TopH - $M.TogH) / 2)
    $o.RiskY = [int](($o.TopH - $o.RiskH) / 2)
    $o.ChipY = [int](($o.TopH - $o.ChipH) / 2)
    $o.TitleY = [int](($o.TopH - $nl * $o.TitleH) / 2)                 # the lines are level with the middle of the card, like the pills and the switch
    # the small marks after the last line of the title (the "Not recommended" mark first), as many as fit
    $px = $o.TextX + $o.LastW + (Px 8)
    $ph = Px 20
    $py = $o.TitleY + ($nl - 1) * $o.TitleH + [int](($o.TitleH - $ph) / 2)
    $o.Pills = @()
    $o.Hidden = 0
    $o.NotRec = $null
    $o.MakeAct = $null
    $o.Reinst = $null
    $items = @()
    if ($e.PlanActive) { $items += , @('active', 'Active plan') }
    elseif ($e.CanActivate) { $items += , @('makeact', 'Make active') }
    if ($e.CanReinstall) { $items += , @('reinst', 'Reinstall') }
    if ($e.NotRec) { $items += , @('notrec', [string]$script:NotRecText) }
    foreach ($t in @(Ui-RowTags $e)) { $items += , @('tag', [string]$t) }
    $room = $true
    foreach ($it in $items) {
        $pw = (Ui-TextWidth ([string]$it[1]) $f) + (Px 16)
        if ($room -and -not $o.TitleCut -and (($px + $pw) -le $o.TextEnd)) {
            $p = @{ Kind = [string]$it[0]; Text = [string]$it[1]; X = $px; Y = $py; W = $pw; H = $ph }
            $o.Pills += , $p
            if ($p.Kind -eq 'notrec') { $o.NotRec = $p }
            if ($p.Kind -eq 'makeact') { $o.MakeAct = $p }
            if ($p.Kind -eq 'reinst') { $o.Reinst = $p }
            $px += $pw + (Px 6)
        } else {
            $room = $false
            $o.Hidden++
        }
    }
    return $o
}

# Where the "Not recommended" mark sits on a row (right after the title), or $null when the row has no mark or no room for it
# (the details panel still says it). X is in the list's own coordinates; Y is the offset from the row's top.
function Ui-NotRecRect {
    param($e)
    if (-not $e -or -not $e.NotRec) { return $null }
    $o = Ui-RowGeom $e
    $p = $o.NotRec
    if (-not $p) { return $null }
    return @{ X = ([int]$e.X + [int]$p.X); W = [int]$p.W; Y = [int]$p.Y; H = [int]$p.H; Top = $false }
}

function Ui-PaintRow {
    param($g, $e, [int]$y)
    $Th = $script:Th
    $M = $script:M
    $TF = $script:TF
    $sel = ($e.Key -eq $script:SelKey)
    $hot = ($script:HotEntry -and $script:HotEntry.Key -eq $e.Key)
    $x = [int]$e.X
    $cw = [int]$e.W
    $o = Ui-RowGeom $e
    $ch = $o.CardH                                        # the card is a little shorter than its line: that is the gap
    # a flat card: a fill and no outline. Only the selected card has an outline (purple); the one under the pointer is a little lighter.
    $fill = $Th.Card
    if ($e.Tint) { $fill = $Th[$e.Tint] }
    if ($sel) {
        if ($e.Tint) { $fill = $Th[$e.Tint + 'Sel'] } else { $fill = $Th.CardSel }
    } elseif ($hot -and -not $e.Tint) {
        $fill = $Th.CardHot
    }
    Ui-FillRound $g $fill $x $y $cw $ch $M.Radius
    if ($sel) { Ui-StrokeRound $g $Th.Accent 1 $x $y $cw $ch $M.Radius }
    if ($e.Tint) {
        # a change waiting to be made: a short bar at the left edge (purple: the switch will go on, orange: it will go off)
        $bar = $Th.Accent
        if (([string]$e.Tint) -like '*Undo*') { $bar = $Th.Warn }
        Ui-FillRound $g $bar ($x + (Px 1)) ($y + (Px 14)) (Px 3) ($o.TopH - (Px 28)) (Px 1)
    }
    $on = [bool]$e.Enabled
    $nameCol = $Th.Text
    if (-not $on) { $nameCol = $Th.Dim }
    # the title, then the marks after it
    $textX = $x + $o.TextX
    for ($li = 0; $li -lt @($o.Lines).Count; $li++) { Ui-Text $g ([string]$o.Lines[$li]) (Ui-Font 'cardName') $nameCol $textX ($y + $o.TitleY + $li * $o.TitleH) $o.TitleW $o.TitleH $TF.L }
    $tagFont = Ui-Font 'smallb'
    foreach ($p in @($o.Pills)) {
        if ($p.Kind -eq 'notrec') {
            $nc = $Th.Bad
            if (-not $on) { $nc = $Th.Dim }
            Ui-StrokeRound $g $nc 1 ($x + $p.X) ($y + $p.Y) $p.W $p.H (Px 6)
            Ui-Text $g $p.Text $tagFont $nc ($x + $p.X) ($y + $p.Y) $p.W $p.H $TF.C
        } elseif ($p.Kind -eq 'active') {
            Ui-FillRound $g $Th[(Ui-SoftKey 'Good')] ($x + $p.X) ($y + $p.Y) $p.W $p.H (Px 6)
            Ui-Text $g $p.Text $tagFont $Th.Good ($x + $p.X) ($y + $p.Y) $p.W $p.H $TF.C
        } elseif ($p.Kind -eq 'makeact' -or $p.Kind -eq 'reinst') {
            # a small button: it makes this plan the active one, or makes it again
            $busy = [bool]($script:Scanning -or $script:Applying)
            $bf = $Th.Raised
            if (-not $busy -and $hot -and $script:HotZone -eq [string]$p.Kind) { $bf = $Th.RaisedHot }
            Ui-FillRound $g $bf ($x + $p.X) ($y + $p.Y) $p.W $p.H (Px 6)
            Ui-StrokeRound $g $Th.Border 1 ($x + $p.X) ($y + $p.Y) $p.W $p.H (Px 6)
            $bc = $Th.Text; if ($busy -or -not $on) { $bc = $Th.Dim }
            Ui-Text $g $p.Text $tagFont $bc ($x + $p.X) ($y + $p.Y) $p.W $p.H $TF.C
        } else {
            Ui-FillRound $g $Th.Tag ($x + $p.X) ($y + $p.Y) $p.W $p.H (Px 6)
            Ui-Text $g $p.Text $tagFont $Th.TagText ($x + $p.X) ($y + $p.Y) $p.W $p.H $TF.C
        }
    }
    # a row with options has its option pill on a second line, under the text
    if ($e.Choices) { Ui-DrawChoices $g $e $textX ($y + $o.ChoiceY) ($cw - $M.Pad - $o.TextX) $M.ChoiceH }
    # the right side: status chip, the risk (a coloured dot and its name in a quiet colour; on a narrow row only the dot), switch
    if ($o.ChipX -ge 0) {
        Ui-FillRound $g $Th[(Ui-SoftKey $e.ChipKey)] ($x + $o.ChipX) ($y + $o.ChipY) $o.ChipW $o.ChipH (Px 6)
        Ui-Text $g ([string]$e.ChipText) $tagFont $Th[$e.ChipKey] ($x + $o.ChipX) ($y + $o.ChipY) $o.ChipW $o.ChipH $TF.C
    }
    $tk = $e.RiskKey + 'Text'
    if (-not $on) { $tk = 'Dim' }
    if ($o.RiskDot) {
        Ui-FillOval $g $Th[$tk] ($x + $o.RiskX) ($y + $o.RiskY) $o.RiskW $o.RiskH
    } else {
        $rd = Px 8
        Ui-FillOval $g $Th[$tk] ($x + $o.RiskX + (Px 6)) ($y + $o.RiskY + [int](($o.RiskH - $rd) / 2)) $rd $rd
        $rcol = $Th.Mute
        if (-not $on) { $rcol = $Th.Dim }
        Ui-Text $g ([string]$e.Risk) (Ui-Font 'small') $rcol ($x + $o.RiskX + (Px 6) + $rd + (Px 8)) ($y + $o.RiskY) ($o.RiskW - $rd - (Px 14)) $o.RiskH $TF.L
    }
    if (-not $e.Choices) { Ui-DrawToggle $g ($x + $o.TogX) ($y + $o.TogY) ([bool]$e.Checked) $on }
}

# The option buttons of a row with options: one pill split in equal parts. The picked part is filled, the option that is in force
# (when it is not the picked one) has a green outline, the part under the pointer lights up.
function Ui-DrawChoices {
    param($g, $e, [int]$x, [int]$y, [int]$w, [int]$h)
    $Th = $script:Th
    $TF = $script:TF
    $font = Ui-Font 'smallb'
    $list = @($e.Choices)
    $n = $list.Count
    if ($n -lt 1) { return }
    $on = [bool]$e.Enabled
    $hot = ($script:HotEntry -and $script:HotEntry.Key -eq $e.Key)
    Ui-FillRound $g $Th.Raised $x $y $w $h ([int]($h / 2))
    Ui-StrokeRound $g $Th.Border 1 $x $y $w $h ([int]($h / 2))
    $inset = Px 3
    $segW = [int][Math]::Floor($w / $n)
    for ($i = 0; $i -lt $n; $i++) {
        $c = $list[$i]
        $sx = $x + $i * $segW
        $sw = $segW
        if ($i -eq ($n - 1)) { $sw = $w - $i * $segW }
        $px = $sx + $inset
        $pw = $sw - 2 * $inset
        $py = $y + $inset
        $ph = $h - 2 * $inset
        $rad = [int]($ph / 2)
        $isPick = ($on -and [string]$c.Key -eq [string]$e.Pick)
        $isNow = ($on -and [string]$c.Key -eq [string]$e.Now)
        $isHot = ($on -and $hot -and $script:HotZone -eq ('seg' + $i))
        $col = $Th.Sub
        if ($isPick) {
            Ui-FillRound $g $Th.Accent $px $py $pw $ph $rad
            $col = $Th.BtnText
        } else {
            if ($isHot) { Ui-FillRound $g $Th.CardHot $px $py $pw $ph $rad; $col = $Th.Text }
            if ($isNow) { Ui-StrokeRound $g $Th.Good 1 $px $py $pw $ph $rad; $col = $Th.Text }
            if (-not $on) { $col = $Th.Dim }
        }
        Ui-Text $g ([string]$c.Short) $font $col $px $py $pw $ph $TF.C
    }
}

function Ui-Thumb {
    $vh = $script:ListH
    $tot = [Math]::Max($script:Total, 1)
    $thumbH = [Math]::Max((Px 36), [int]($vh * $vh / $tot))
    if ($thumbH -gt $vh) { $thumbH = $vh }
    $range = $tot - $vh
    $ty = 0
    if ($range -gt 0) { $ty = [int](($vh - $thumbH) * $script:ScrollY / $range) }
    return @{ Y = $ty; H = $thumbH }
}

function Ui-PaintScroll {
    param($g)
    if ($script:Total -le $script:ListH) { return }
    $t = Ui-Thumb
    Ui-PaintThumb $g ($script:ListW - (Px 3)) 0 $script:ListH $t.Y $t.H ([bool]($script:HotZone -eq 'sb')) ([bool]($script:DragOff -ge 0))
}

# Draw the part of the list between two heights of the control
function Ui-PaintList {
    param($g, [int]$clipTop, [int]$clipBottom)
    $v = $script:View
    $n = $v.Count
    $sy = $script:ScrollY
    Ui-Fill $g $script:Th.Bg 0 $clipTop $script:ListW ($clipBottom - $clipTop)
    if ($n -eq 0) {
        Ui-Text $g 'No settings match.' (Ui-Font 'row') $script:Th.Sub 0 (Px 40) $script:ListW (Px 30) $script:TF.C
        return
    }
    $i = Ui-FirstAt ($sy + $clipTop)
    while ($i -lt $n) {
        $e = $v[$i]
        $y = $e.Y - $sy
        if ($y -ge $clipBottom) { break }
        if ($e.Kind -eq 'head') { Ui-PaintHead $g $e $y }
        elseif ($e.Kind -eq 'info') { Ui-PaintInfo $g $e $y }
        else { Ui-PaintRow $g $e $y }
        $i++
    }
    Ui-PaintScroll $g
}

function Ui-OnPaint {
    param($pe)
    $g = $pe.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $clip = $pe.ClipRectangle
    Ui-PaintList $g $clip.Top $clip.Bottom
}

# ----------------------------------------------------------- the mouse ----------------
# What is at (x, y) of the control?  Zone: sb | toggle | view | notrec | makeact | reinst | row | head | ''
function Ui-Zone {
    param([int]$x, [int]$y)
    $M = $script:M
    if ($x -lt 0 -or $y -lt 0 -or $x -ge $script:ListW -or $y -ge $script:ListH) { return @{ Zone = ''; Entry = $null } }
    if ($script:Total -gt $script:ListH -and $x -ge ($script:ListW - $M.Sb)) { return @{ Zone = 'sb'; Entry = $null } }
    $ly = $y + $script:ScrollY
    $i = Ui-HitIndex $ly $x
    if ($i -lt 0) { return @{ Zone = ''; Entry = $null } }
    $e = $script:View[$i]
    if ($e.Kind -eq 'info') {
        # a read-out: only a line that has an explanation can be clicked (it opens the explanation)
        $hl = Info-HitLine $e ($x - [int]$e.X) ($ly - [int]$e.Y)
        if ($hl) { return @{ Zone = 'info'; Entry = $e; Line = [string]$hl.Id } }
        return @{ Zone = ''; Entry = $null }
    }
    if ($e.Kind -eq 'row') {
        $o = Ui-RowGeom $e
        $rx = $x - [int]$e.X
        $ry = $ly - [int]$e.Y
        if ($ry -ge $o.CardH) { return @{ Zone = 'row'; Entry = $e } }
        if ($e.Choices) {
            # the option buttons: seg0, seg1, ... from the left
            $cl = [int]$e.X + $o.TextX
            $cwid = [int]$e.W - $M.Pad - $o.TextX
            $ctop = $o.ChoiceY
            if ($ry -ge $ctop -and $ry -lt ($ctop + $M.ChoiceH) -and $x -ge $cl -and $x -lt ($cl + $cwid)) {
                $cn = @($e.Choices).Count
                $segw = [Math]::Max(1, [int][Math]::Floor($cwid / $cn))          # the same split as Ui-DrawChoices: equal parts, the last takes the remainder
                $k = [int][Math]::Floor(($x - $cl) / $segw)
                if ($k -ge $cn) { $k = $cn - 1 }
                return @{ Zone = ('seg' + $k); Entry = $e }
            }
        }
        # "Make active" on an installed power plan that is not the active one
        $ma = $o.MakeAct
        if ($ma -and $ry -ge $ma.Y -and $ry -lt ($ma.Y + $ma.H) -and $rx -ge $ma.X -and $rx -lt ($ma.X + $ma.W)) { return @{ Zone = 'makeact'; Entry = $e } }
        # "Reinstall" on an installed power plan
        $rb = $o.Reinst
        if ($rb -and $ry -ge $rb.Y -and $ry -lt ($rb.Y + $rb.H) -and $rx -ge $rb.X -and $rx -lt ($rb.X + $rb.W)) { return @{ Zone = 'reinst'; Entry = $e } }
        # the "Not recommended" mark after the title
        $nrr = Ui-NotRecRect $e
        if ($nrr -and $ry -ge $nrr.Y -and $ry -lt ($nrr.Y + $nrr.H) -and $x -ge $nrr.X -and $x -lt ($nrr.X + $nrr.W)) { return @{ Zone = 'notrec'; Entry = $e } }
        # the switch (a little more than the switch itself) turns the setting on or off
        if (-not $e.Choices -and $rx -ge ($o.TogX - (Px 6)) -and $rx -lt [int]$e.W) { return @{ Zone = 'toggle'; Entry = $e } }
        if ($o.RiskDot -and $ry -lt $o.TopH -and $rx -ge ($o.RiskX - (Px 4)) -and $rx -lt ($o.RiskX + $o.RiskW + (Px 4))) { return @{ Zone = 'risk'; Entry = $e } }
        return @{ Zone = 'row'; Entry = $e }
    }
    return @{ Zone = 'head'; Entry = $e }
}

function Ui-SetCursor {
    param([string]$kind)
    $l = $script:UI.list
    if (-not $l -or $script:CursorIs -eq $kind) { return }
    $script:CursorIs = $kind
    if ($kind -eq 'hand') { $l.Cursor = [System.Windows.Forms.Cursors]::Hand } else { $l.Cursor = [System.Windows.Forms.Cursors]::Default }
}

function Ui-UpdateHot {
    param([int]$x, [int]$y)
    $z = Ui-Zone $x $y
    $old = $script:HotEntry
    $new = $z.Entry
    $oldKey = ''; if ($old) { $oldKey = [string]$old.Key }
    $newKey = ''; if ($new) { $newKey = [string]$new.Key }
    $newLine = [string]$z.Line
    $oldLine = [string]$script:HotLine
    if ($z.Zone -eq $script:HotZone -and $newKey -eq $oldKey -and $newLine -eq $oldLine) { return }
    $oldZone = $script:HotZone
    $script:HotEntry = $new
    $script:HotZone = $z.Zone
    $script:HotLine = $newLine
    if ($old) { Ui-InvalidateEntry $old }
    if ($new -and ($newKey -ne $oldKey -or $newLine -ne $oldLine)) { Ui-InvalidateEntry $new }
    if ($z.Zone -eq 'sb' -or $oldZone -eq 'sb') { Ui-InvalidateAll }
    $hand = 'arrow'
    if ($z.Zone -eq 'toggle' -or ([string]$z.Zone).StartsWith('seg') -or $z.Zone -eq 'head' -or $z.Zone -eq 'info' -or $z.Zone -eq 'makeact' -or $z.Zone -eq 'reinst') { $hand = 'hand' }
    Ui-SetCursor $hand
}

function Ui-OnMouseMove {
    param([int]$x, [int]$y)
    $script:MX = $x
    $script:MY = $y
    if ($script:DragOff -ge 0) { Ui-DragTo $y; return }
    Ui-UpdateHot $x $y
}

function Ui-OnMouseLeave {
    if ($script:DragOff -ge 0) { return }
    $script:MX = -1
    $script:MY = -1
    Ui-UpdateHot -1 -1
}

function Ui-OnMouseUp {
    if ($script:DragOff -ge 0) {
        $script:DragOff = -1
        Ui-InvalidateAll
    }
}

function Ui-OnWheel {
    param([int]$delta)
    $step = [int]($delta / 120.0 * $script:M.Wheel)
    if ($step -eq 0) { return }
    Ui-ScrollTo ($script:ScrollY - $step)
    if ($script:MX -ge 0) { Ui-UpdateHot $script:MX $script:MY }
}

function Ui-ScrollbarDown {
    param([int]$y)
    $t = Ui-Thumb
    if ($y -ge $t.Y -and $y -lt ($t.Y + $t.H)) {
        $script:DragOff = $y - $t.Y
        Ui-InvalidateAll
        return
    }
    $page = [Math]::Max($script:M.Row, $script:ListH - $script:M.Row)
    if ($y -lt $t.Y) { Ui-ScrollTo ($script:ScrollY - $page) } else { Ui-ScrollTo ($script:ScrollY + $page) }
}

function Ui-DragTo {
    param([int]$y)
    $t = Ui-Thumb
    $range = $script:Total - $script:ListH
    $travel = $script:ListH - $t.H
    if ($range -le 0 -or $travel -le 0) { return }
    $ty = $y - $script:DragOff
    if ($ty -lt 0) { $ty = 0 }
    if ($ty -gt $travel) { $ty = $travel }
    Ui-ScrollTo ([int]($ty * $range / $travel))
}

function Ui-OnMouseDown {
    param([int]$x, [int]$y, [string]$button)
    if ($button -ne 'Left') { return }
    $z = Ui-Zone $x $y
    $zone = [string]$z.Zone
    if ($zone -eq 'sb') { Ui-ScrollbarDown $y; return }
    if ($zone -eq 'toggle') { Ui-Select $z.Entry; Ui-ToggleRow $z.Entry }
    elseif ($zone.StartsWith('seg')) { Ui-Select $z.Entry; Ui-PickRow $z.Entry ([int]$zone.Substring(3)) }
    elseif ($zone -eq 'makeact') { Ui-Select $z.Entry; Ui-MakeActive $z.Entry }
    elseif ($zone -eq 'reinst') { Ui-Select $z.Entry; Ui-Reinstall $z.Entry }
    elseif ($zone -eq 'row' -or $zone -eq 'notrec') { Ui-Select $z.Entry }
    elseif ($zone -eq 'head') { Ui-Select $z.Entry; Ui-ToggleHead $z.Entry }
    elseif ($zone -eq 'info') { Ui-ToggleInfoLine $z.Entry ([string]$z.Line) }
    Ui-Flush
}

# ----------------------------------------------------------- selection and keys --------
function Ui-Select {
    param($e)
    if (-not $e) { return }
    if ([string]$e.Key -eq $script:SelKey) { return }
    $script:SelKey = [string]$e.Key
    $script:DList = $true
    $script:DDetail = $true
}

function Ui-SelIndex {
    $v = $script:View
    for ($i = 0; $i -lt $v.Count; $i++) {
        if ($v[$i].Key -eq $script:SelKey) { return $i }
    }
    return -1
}

# scroll so that the whole entry can be seen
function Ui-EnsureVisible {
    param($e)
    if (-not $e -or $e.Y -lt 0) { return }
    if ($e.Y -lt $script:ScrollY) {
        $to = $e.Y
        if ($e.Idx -le $script:FirstSel) { $to = 0 }                    # the first line: show the space above it (and any read-outs) too
        Ui-ScrollTo $to
    } elseif (($e.Y + $e.H) -gt ($script:ScrollY + $script:ListH)) {
        $to = $e.Y + $e.H - $script:ListH
        if ($e.Idx -eq ($script:View.Count - 1)) { $to = $script:Total - $script:ListH }     # the last line: show the space below it too
        Ui-ScrollTo $to
    }
}

# A read-out cannot be selected: go on to the nearest entry that can, looking in direction $dir first, then the other way
function Ui-Selectable {
    param([int]$i, [int]$dir)
    $v = $script:View
    $n = $v.Count
    if ($i -ge 0 -and $i -lt $n -and $v[$i].Kind -ne 'info') { return $i }
    for ($k = $i; $k -ge 0 -and $k -lt $n; $k += $dir) { if ($v[$k].Kind -ne 'info') { return $k } }
    for ($k = $i; $k -ge 0 -and $k -lt $n; $k -= $dir) { if ($v[$k].Kind -ne 'info') { return $k } }
    return -1
}

function Ui-SelectIdx {
    param([int]$i, [int]$dir = 1)
    $n = $script:View.Count
    if ($n -eq 0) { return }
    if ($i -lt 0) { $i = 0 }
    if ($i -ge $n) { $i = $n - 1 }
    $i = Ui-Selectable $i $dir
    if ($i -lt 0) { return }
    $e = $script:View[$i]
    Ui-Select $e
    Ui-EnsureVisible $e
}

# open or close a group (not while a search or a filter is hiding rows: then everything that matches is shown)
function Ui-ToggleHead {
    param($e)
    if ($script:Filtering) { return }
    if ($script:Single) { return }
    $cat = [string]$e.Cat
    $script:Collapsed[$cat] = -not [bool]$script:Collapsed[$cat]
    Ui-Layout
    $script:DList = $true
}

# the first and last index of the entries that share one line of the list (one entry in a single column, up to two in a grid)
function Ui-LineSpan {
    param([int]$i)
    $v = $script:View
    $y = $v[$i].Y
    $a = $i
    while ($a -gt 0 -and $v[$a - 1].Y -eq $y) { $a-- }
    $b = $i
    while ($b -lt ($v.Count - 1) -and $v[$b + 1].Y -eq $y) { $b++ }
    return @{ First = $a; Last = $b }
}

# the index one line down (dir = 1) or up (dir = -1) from entry i, staying in the same column when the line has one
function Ui-StepLine {
    param([int]$i, [int]$dir)
    $v = $script:View
    $cur = $v[$i]
    $sp = Ui-LineSpan $i
    if ($dir -gt 0) { $k = $sp.Last + 1 } else { $k = $sp.First - 1 }
    if ($k -lt 0 -or $k -ge $v.Count) { return $i }
    if ($v[$k].Kind -eq 'head') { return $k }
    $s2 = Ui-LineSpan $k
    $pick = $s2.Last
    for ($j = $s2.First; $j -le $s2.Last; $j++) { if ($v[$j].X -eq $cur.X) { $pick = $j; break } }
    return $pick
}

function Test-ListKey {
    param([string]$k)
    return (@('Up', 'Down', 'Left', 'Right', 'Prior', 'Next', 'PageUp', 'PageDown', 'Home', 'End') -contains $k)
}

# On a page of read-outs nothing can be selected: the keys scroll. Returns $true when the key was used.
function Ui-ScrollKey {
    param([string]$key)
    $line = Px 60
    $page = [Math]::Max($script:M.Row, $script:ListH - $script:M.Row)
    if ($key -eq 'Down') { Ui-ScrollTo ($script:ScrollY + $line) }
    elseif ($key -eq 'Up') { Ui-ScrollTo ($script:ScrollY - $line) }
    elseif ($key -eq 'Next' -or $key -eq 'PageDown') { Ui-ScrollTo ($script:ScrollY + $page) }
    elseif ($key -eq 'Prior' -or $key -eq 'PageUp') { Ui-ScrollTo ($script:ScrollY - $page) }
    elseif ($key -eq 'Home') { Ui-ScrollTo 0 }
    elseif ($key -eq 'End') { Ui-ScrollTo $script:Total }
    else { return $false }
    return $true
}

# A key was pressed in the list. Returns $true when it was used.
function Ui-OnKey {
    param([string]$key)
    $n = $script:View.Count
    if ($n -eq 0) { return $false }
    if ($script:FirstSel -lt 0) { return (Ui-ScrollKey $key) }
    $i = Ui-SelIndex
    $page = [Math]::Max(1, [int][Math]::Floor($script:ListH / $script:M.Row) - 1)
    $cur = $null
    if ($i -ge 0) { $cur = $script:View[$i] }
    $done = $true
    if ($key -eq 'Down') { if ($i -lt 0) { Ui-SelectIdx 0 } else { Ui-SelectIdx (Ui-StepLine $i 1) } }
    elseif ($key -eq 'Up') { if ($i -lt 0) { Ui-SelectIdx 0 } else { Ui-SelectIdx (Ui-StepLine $i -1) -1 } }
    elseif ($key -eq 'Next' -or $key -eq 'PageDown') {
        if ($i -lt 0) { Ui-SelectIdx 0 } else { $k = $i; for ($m = 0; $m -lt $page; $m++) { $k = Ui-StepLine $k 1 }; Ui-SelectIdx $k }
    }
    elseif ($key -eq 'Prior' -or $key -eq 'PageUp') {
        if ($i -lt 0) { Ui-SelectIdx 0 } else { $k = $i; for ($m = 0; $m -lt $page; $m++) { $k = Ui-StepLine $k -1 }; Ui-SelectIdx $k -1 }
    }
    elseif ($key -eq 'Home') { Ui-SelectIdx 0 }
    elseif ($key -eq 'End') { Ui-SelectIdx ($n - 1) -1 }
    elseif ($key -eq 'Space' -or $key -eq 'Return' -or $key -eq 'Enter') {
        if ($cur) {
            if ($cur.Kind -eq 'row') { Ui-ToggleRow $cur } else { Ui-ToggleHead $cur }
        }
    }
    elseif ($key -eq 'Left') {
        if ($cur -and $cur.Kind -eq 'head') {
            if ($cur.Open) { Ui-ToggleHead $cur }
        } elseif ($cur -and $i -gt 0 -and $script:View[$i - 1].Y -eq $cur.Y) {
            Ui-SelectIdx ($i - 1)                                   # the card to the left in a grid
        } elseif ($cur) {
            for ($j = $i - 1; $j -ge 0; $j--) {
                if ($script:View[$j].Kind -eq 'head') { Ui-SelectIdx $j; break }
            }
        }
    }
    elseif ($key -eq 'Right') {
        if ($cur -and $cur.Kind -eq 'head') {
            if (-not $cur.Open) { Ui-ToggleHead $cur } else { Ui-SelectIdx ($i + 1) }
        } elseif ($cur -and ($i + 1) -lt $n -and $script:View[$i + 1].Y -eq $cur.Y) {
            Ui-SelectIdx ($i + 1)                                   # the card to the right in a grid
        }
    }
    else { $done = $false }
    if ($done) { Ui-Flush }
    return $done
}

# =============================================================================
# THE WINDOW, part 3: buttons, the details panel, what the user can do, and the background job.
# Things that change on screen only set a "needs updating" flag (Ui-RefreshRow, Handle-Event); Ui-Flush then
# brings the screen up to date once. User actions end with Ui-Flush, the timer calls it after every batch of events.
# =============================================================================
$script:StartScanPending = $false

# ----------------------------------------------------------- buttons ------------
function Ui-Buttons {
    $c = Get-Counts
    $busy = ($script:Scanning -or $script:Applying -or ($c.Checking -gt 0))
    Ui-SetEnabled $script:UI.apply ((-not $busy) -and (($c.Apply + $c.Undo) -gt 0))
    Ui-SetEnabled $script:UI.stop ([bool]$script:Applying)
    foreach ($k in 'presetBtn', 'discard', 'rescan', 'allOn', 'allOff', 'applyAll') { Ui-SetEnabled $script:UI[$k] (-not $busy) }
}

function Ui-Counts {
    $c = Get-Counts
    $n = $c.Apply + $c.Undo
    $verb = 'Apply'
    if ($script:UI.dry -and $script:UI.dry.Checked) { $verb = 'Preview' }
    $label = $verb + ' changes'
    if ($n -eq 1) { $label = $verb + ' 1 change' }
    elseif ($n -gt 1) { $label = ('{0} {1} changes' -f $verb, $n) }
    if ([string]$script:UI.apply.Text -ne $label) { $script:UI.apply.Text = $label }
    Ui-Buttons
}

# ----------------------------------------------------------- details panel -----------
$script:DetailHint = "Click a setting to read what it does and exactly what it changes.`r`n`r`nUse the switch on the right of a setting to turn the feature on or off: on means the feature is on, off means it is off (or the service is disabled). Every card says what Windows has by default. Nothing is changed until you press the Apply button at the bottom."

# which font and colour a piece of the details text gets
function Ui-PartStyle {
    param($p)
    $Th = $script:Th
    switch ([string]$p.S) {
        'title' { return @{ F = 'detTitle'; C = $Th.Text } }
        'sub'   { return @{ F = 'small'; C = $Th.Sub } }
        'now'   {
            $c = $Th.Sub
            if ($p.C -eq 'good') { $c = $Th.Good } elseif ($p.C -eq 'warn') { $c = $Th.Warn }
            return @{ F = 'uib'; C = $c }
        }
        'wait'  { return @{ F = 'uib'; C = $Th.Accent } }
        'last'  { return @{ F = 'ui'; C = $Th.Sub } }
        'body'  { return @{ F = 'body'; C = $Th.Text } }
        'warn'  { return @{ F = 'ui'; C = $Th.Warn } }
        'note'  { return @{ F = 'ui'; C = $Th.Dim } }
        'head'  { return @{ F = 'uib'; C = $Th.Sub } }
        'mono'  { return @{ F = 'monoS'; C = $Th.Mute } }
        'good'   { return @{ F = 'uib'; C = $Th.Good } }
        'goodl'  { return @{ F = 'ui'; C = $Th.Good } }
    }
    return @{ F = 'ui'; C = $Th.Text }
}

# put the pieces of a description into a rich text box, each in its own font and colour
function Ui-FillRich {
    param($d, $parts)
    Ui-Redraw $d $false
    try {
        $d.Clear()
        foreach ($p in $parts) {
            $st = Ui-PartStyle $p
            $d.SelectionStart = $d.TextLength
            $d.SelectionLength = 0
            $d.SelectionFont = (Ui-Font $st.F)
            $d.SelectionColor = $st.C
            $d.AppendText([string]$p.T)
        }
        $d.SelectionStart = 0
        $d.SelectionLength = 0
        $d.ScrollToCaret()
    } finally {
        Ui-Redraw $d $true
    }
}

function Ui-ShowDetails {
    $d = $script:UI.detail
    if (-not $d) { return }
    $row = $null
    if ($script:SelKey -and $script:Rows.Contains($script:SelKey)) { $row = $script:Rows[$script:SelKey] }
    if ($row) {
        $parts = Get-DetailParts $row
    } else {
        $parts = New-Object System.Collections.ArrayList
        [void]$parts.Add(@{ S = 'title'; C = ''; T = "Settings`r`n" })
        [void]$parts.Add(@{ S = 'body'; C = ''; T = "`r`n" + $script:DetailHint })
    }
    Ui-FillRich $d $parts
    $fb = $script:UI.forceBtn
    if ($fb) {
        $show = [bool]($row -and ($row.State -eq 'Partial' -or $row.State -eq 'Unknown') -and -not $row.T.OneWay)
        if ([bool]$fb.Visible -ne $show) { $fb.Visible = $show }
    }
}

# ----------------------------------------------------------- keeping the screen up to date ----
# A row changed: copy it into its line and remember what has to be redrawn
function Ui-RefreshRow {
    param([string]$id)
    $row = $script:Rows[$id]
    if (-not $row -or -not $row.Item) { return }
    Ui-FillEntry $row
    $script:DList = $true
    $script:DHead = $true
    $script:DCounts = $true
    if ($script:SelKey -eq $id) { $script:DDetail = $true }
}

function Ui-RefreshAll {
    foreach ($id in @($script:Rows.Keys)) { Ui-RefreshRow $id }
    $script:DList = $true
    $script:DHead = $true
    $script:DCounts = $true
    $script:DDetail = $true
    Ui-Flush
}

function Ui-Reveal {
    param([string]$id)
    $row = $script:Rows[$id]
    if ($row -and $row.Item) { Ui-EnsureVisible $row.Item }
}

# Bring the screen up to date: group counts, buttons, details, progress, the list (one repaint), the log.
# Every part has its own try, so a problem in one never keeps the others from updating.
function Ui-Flush {
    try { if ($script:DHead) { $script:DHead = $false; $script:DNav = $true; Ui-FillHeads } } catch { Ui-Fail $_ }
    try { if ($script:DNav) { $script:DNav = $false; Ui-FillNav; Ui-UpdatePage } } catch { Ui-Fail $_ }
    try { if ($script:DCounts) { $script:DCounts = $false; Ui-Counts } } catch { Ui-Fail $_ }
    try { if ($script:DDetail) { $script:DDetail = $false; Ui-ShowDetails } } catch { Ui-Fail $_ }
    try {
        if ($script:DProg) {
            $script:DProg = $false
            Ui-ApplyBar
            if ($script:Scanning -and $script:ProgB -gt 1) {
                $line = 'Checking your PC...  {0} of {1}' -f $script:ProgA, $script:ProgB
                if ($script:WaitText) { $line += '   (still waiting for Windows: ' + $script:WaitText + ')' }
                Ui-Status $line
            }
        }
    } catch { Ui-Fail $_ }
    try { if ($script:DList) { $script:DList = $false; Ui-InvalidateAll } } catch { Ui-Fail $_ }
    try { Ui-FlushLog } catch { Ui-Fail $_ }
}

# ----------------------------------------------------------- user actions -------
# A switch was clicked (or Space was pressed on the line; on a card with options Space goes to the next option)
function Ui-ToggleRow {
    param($e)
    if (-not $e -or $e.Kind -ne 'row') { return }
    $id = [string]$e.Id
    $row = $script:Rows[$id]
    if (-not $row) { return }
    if ($row.T.Choices) {
        # no switch on this card: Space goes to the next option (the Windows default, then each option in turn)
        $keys = @($row.T.Choices | ForEach-Object { [string]$_.Key })
        $at = [array]::IndexOf($keys, [string]$row.Pick)
        $next = [string]$keys[(($at + 1) % $keys.Count)]
        if ($at -lt 0) { $next = [string]$keys[1] }
        $msg = Try-SetPick $id $next
    } else {
        $msg = Try-SetWant $id (-not [bool]$row.Want)
    }
    Ui-RefreshRow $id          # also puts the switch back if the change was refused
    if ($msg) { Ui-Status $msg } else { Ui-Status (Get-SummaryText) }
    Ui-Flush
}

# One of the option buttons of a card with options was clicked ($index counts from the left)
function Ui-PickRow {
    param($e, [int]$index)
    if (-not $e -or $e.Kind -ne 'row') { return }
    $id = [string]$e.Id
    $row = $script:Rows[$id]
    if (-not $row -or -not $row.T.Choices) { return }
    $list = @($row.T.Choices)
    if ($index -lt 0 -or $index -ge $list.Count) { return }
    $msg = Try-SetPick $id ([string]$list[$index].Key)
    Ui-RefreshRow $id
    if ($msg) { Ui-Status $msg } else { Ui-Status (Get-SummaryText) }
    Ui-Flush
}

# "Tweak all" / "Reset all" (the two buttons at the top right). $cat is the page that is open, '' for "All settings".
# They only tick the switches: nothing is changed on the PC until Apply changes is pressed (and confirmed).
function Ui-GroupTick {
    param([string]$cat, [bool]$want)
    $b = Get-BusyReason
    if ($b) { Ui-Status $b; return }
    $left = @(Get-GroupLeftOut $cat)
    $n = Set-GroupWant $cat $want
    if ($cat) { foreach ($id in @($script:Rows.Keys)) { if ($script:Rows[$id].T.Cat -eq $cat) { Ui-RefreshRow $id } } }
    else { Ui-RefreshAll }
    $where = 'All settings'; if ($cat) { $where = (Split-CatName $cat).Short }
    $s = ('{0} setting(s) on "{1}" changed.  ' -f $n, $where)
    if ($want -and $left.Count -gt 0) { $s += ('{0} left out on purpose (the ones "Apply all" leaves out too: change them yourself).  ' -f $left.Count) }
    Ui-Status ($s + (Get-SummaryText))
    Ui-Flush
}

# "Put this one fully back (undo)" for the selected setting
function Ui-ForceUndo {
    $id = [string]$script:SelKey
    if (-not $id -or -not $script:Rows.Contains($id)) { Ui-Status 'Click a setting first.'; return }
    $msg = Try-ForceUndo $id
    Ui-RefreshRow $id
    if ($msg) { Ui-Status $msg } else { Ui-Status (Get-SummaryText) }
    Ui-Flush
}

# What the window "Select Optimization Preset" does with the choice that was made in it (see Ui-ShowPresets): Confirm changes was pressed
# there, after the window showed what is already enabled and what will be changed. Advanced Debloat asks its warning first. The preset's
# settings that are not on yet are ticked and applied (after the questions some settings ask). $key = recommended | advanced | personal
function Ui-DoPreset {
    param([string]$key = 'recommended')
    $b = Get-BusyReason
    if ($b) { Ui-Status $b; return }
    $name = [string]$script:PresetNames[$key]
    if ($key -eq 'personal' -and @($script:Personal.Picks.Keys).Count -eq 0) {
        Ui-Status 'There is no saved Custom Preset yet. Open Select Optimization Preset, choose Custom Preset, and save one first.'
        return
    }
    if ($key -eq 'advanced') {
        # a warning before anything is lined up: Advanced Debloat is meant for gaming PCs
        if (-not (Ui-Ask $script:AdvancedWarning 'Advanced Debloat warning' $true)) {
            Ui-Status 'Nothing was changed.'
            return
        }
    }
    Ui-LineUpPreset $key
}

# Tick the settings of a preset and apply them (the preset window's Confirm changes was pressed). $key = recommended | advanced | personal
function Ui-LineUpPreset {
    param([string]$key)
    $name = [string]$script:PresetNames[$key]
    $before = @(Get-Pending).Count
    $n = Select-PresetKey $key
    Ui-RefreshAll
    $plan = @(Get-Pending)
    if ($plan.Count -eq 0) {
        Ui-Status ('Everything in "{0}" is already on (or not available on this PC).' -f $name)
        Ui-Flush
        return
    }
    $note = { param($p) Get-PresetNote $key $p $before }.GetNewClosure()
    # the preset window already showed what is enabled and what will be changed, and Confirm changes was pressed there; only when
    # other changes had been lined up before (they were not in that window) is the list of changes shown as well
    Ui-DoApply $note ($name + '?') $true ($before -eq 0)
    if ($script:ApplyCancelled) {
        Ui-Status ('Nothing was changed. {0} setting(s) stay lined up - press Apply changes to go ahead, or Clear changes to remove them.' -f $n)
        Ui-Flush
    }
}

# "Apply all": tick everything on this page (every page when "All settings" is open), then go through the usual Apply,
# which asks first. If you say no, the settings stay lined up and Apply / Discard work as always.
function Ui-DoApplyAll {
    $b = Get-BusyReason
    if ($b) { Ui-Status $b; return }
    $cat = ''
    if ($script:Single) { $cat = [string]$script:NavCat }
    $where = 'All settings'
    if ($cat) { $where = (Split-CatName $cat).Short }
    $r = Select-ApplyAll $cat
    Ui-RefreshAll
    $plan = @(Get-Pending)
    if ($plan.Count -eq 0) {
        Ui-Status ('Everything on "{0}" is already on (or not available on this PC).' -f $where)
        Ui-Flush
        return
    }
    $left = $r.Left
    $note = { param($p) Get-ApplyAllNote $p $left $where }.GetNewClosure()
    Ui-DoApply $note 'Apply all?' $true
    if ($script:ApplyCancelled) {
        Ui-Status ('Nothing was changed. {0} setting(s) stay lined up - press Apply changes to go ahead, or Discard to clear them.' -f $r.Ticked)
        Ui-Flush
    }
}

# True when the main window is the one in front: the app is the active program and no other window of it (a details window, the
# preset window, a question) is open on top
function Test-MainWindowActive {
    try { $af = [System.Windows.Forms.Form]::ActiveForm } catch { return $true }
    return [bool]($af -and $script:UI.form -and [object]::ReferenceEquals($af, $script:UI.form))
}

# After a check: the settings that are only partly applied, or that this app applied earlier and that read off now, are offered for applying again (Get-ReapplyOffer says which). One question
# lists them all. Yes ticks them and goes through the usual Apply (the questions some settings ask, the restore point, the undo
# record); No leaves them as they are. A setting is asked about once each time the window is opened, whatever the answer was.
function Ui-OfferReapply {
    if (Get-BusyReason) { return }
    if ($script:UI.dry -and [bool]$script:UI.dry.Checked) { return }     # "Preview only" is on: a preview of this would only confuse
    if (@(Get-Pending).Count -gt 0) { return }                           # the user has changes lined up already; do not mix these in
    $ids = @(Get-ReapplyOffer)
    if ($ids.Count -eq 0) { return }
    [void](Set-ReapplyAsked $ids)
    foreach ($id in $ids) { [void](Try-SetWant ([string]$id) $true) }
    $plan = @(Get-Pending)
    if ($plan.Count -eq 0) { Reset-Ticks; return }
    # the timer is stopped while the question is open, so that it cannot run the screen update inside the question
    $tm = $script:UI.timer
    if ($tm) { try { $tm.Stop() } catch { } }
    try {
        if (Ui-Ask (Get-ConfirmText $plan (Get-ReapplyNote $plan)) 'Finish applying these settings?' $false) {
            Ui-DoApply '' 'Finish applying these settings?' $false $true
        } else {
            Reset-Ticks
            Ui-RefreshAll
            Ui-Status ('Nothing was changed.  ' + (Get-SummaryText))
            Ui-Flush
        }
    } finally {
        if ($tm) { try { $tm.Start() } catch { } }
    }
}

function Ui-DoDiscard {
    $b = Get-BusyReason
    if ($b) { Ui-Status $b; return }
    Reset-Ticks
    Ui-RefreshAll
    Ui-Status ('Waiting changes cleared.  ' + (Get-SummaryText))
}

function Ui-DoRescan {
    $b = Get-BusyReason
    if ($b) { Ui-Status $b; return }
    $c = Get-Counts
    if (($c.Apply + $c.Undo) -gt 0) {
        if (-not (Ui-Ask 'Checking again clears the changes you have lined up. Go ahead?' 'Check again')) { return }
    }
    Ui-StartScan
}

function Ui-DoOpenLog {
    if ($log -and (Test-Path -LiteralPath $log)) {
        try { Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $log + '"') } catch { Ui-Status ('Could not open the log: ' + $_.Exception.Message) }
    } else {
        Ui-Status 'There is no log yet - it is created when the first changes are made.'
    }
}

function Ui-DoRestart {
    if (-not (Ui-Ask "Restart the PC in 15 seconds?`r`nSave your work first." 'Restart' $true)) { return }
    try {
        Start-Process -FilePath 'shutdown.exe' -ArgumentList '/r', '/t', '15', '/c', 'Restart after Headroom changes'
        Ui-Status 'Restarting in 15 seconds. To cancel, open a command prompt and type:  shutdown /a'
    } catch { Ui-Status ('Could not start the restart: ' + $_.Exception.Message) }
}

function Ui-ShowLog {
    param([bool]$on)
    $card = $script:UI.logCard
    if ($card -and [bool]$card.Visible -ne $on) { $card.Visible = $on }
    $b = $script:UI.logBtn
    if ($b) {
        if ($on) { $b.Text = 'Hide log' } else { $b.Text = 'Show log' }
    }
}

function Ui-ToggleLog {
    $card = $script:UI.logCard
    if (-not $card) { return }
    Ui-ShowLog (-not [bool]$card.Visible)
    Ui-ListSize
}

# The questions some settings ask before they are turned on (anti-cheat, printing). Each one that is answered No is left alone:
# it is unticked and dropped from the plan. Returns the plan that is left; the names left alone go in $script:GuardKept.
function Ui-AskGuards {
    param($plan)
    $script:GuardKept = @()
    $drop = @()
    foreach ($q in @(Get-GuardQuestions $plan)) {
        if (-not (Ui-Ask (Get-GuardText $q) $q.Title $true)) {
            $drop += @($q.Ids)
            $script:GuardKept += @($q.Names)
        }
    }
    if ($drop.Count -eq 0) { return $plan }
    foreach ($id in $drop) { [void](Try-SetWant ([string]$id) $false) }
    return @(Remove-FromPlan $plan $drop)
}

# $Extra is a text for the top of the confirmation, or a script block that is given the plan (after the questions) and returns it
function Ui-DoApply {
    param($Extra = '', [string]$Title = 'Make these changes?', [bool]$Warn = $false, [bool]$ListShown = $false)
    # $ListShown: the list of changes was already shown and confirmed (the preset window's Confirm changes), so it is not asked again
    $script:ApplyCancelled = $false
    $script:GuardKept = @()
    $b = Get-BusyReason
    if ($b) { Ui-Status $b; return }
    $plan = @(Get-Pending)
    if ($plan.Count -eq 0) { Ui-Status 'Nothing to do - switch some settings on or off first.'; return }
    $dry = [bool]$script:UI.dry.Checked
    if (-not $dry) {
        $plan = @(Ui-AskGuards $plan)
        if (@($script:GuardKept).Count -gt 0) { Ui-RefreshAll }
        if ($plan.Count -eq 0) {
            Ui-Status ('Nothing was changed: you chose to leave {0} as it is.' -f ((@($script:GuardKept) | ForEach-Object { '"' + $_ + '"' }) -join ', '))
            Ui-Flush
            return
        }
        if (-not $ListShown) {
            if ($Extra -is [scriptblock]) { $x = [string](& $Extra $plan) } else { $x = [string]$Extra }
            if (-not (Ui-Ask (Get-ConfirmText $plan $x) $Title $Warn)) { $script:ApplyCancelled = $true; return }
        }
    }
    foreach ($p in $plan) { $r = $script:Rows[[string]$p.Id]; $r.Note = 'Waiting...'; $r.NoteDetail = '' }
    $script:Applying = $true
    Ui-ShowLog $true
    Ui-RefreshAll
    Ui-Progress 0 1
    if (@($script:GuardKept).Count -gt 0) { Ui-Note ('Left as it is because you answered No: ' + ((@($script:GuardKept)) -join '; ')) 'Yellow' }
    if ($dry) { Ui-Status 'Preview running - nothing is changed...' } else { Ui-Status 'Making changes... (the log below shows each step)' }
    try {
        Start-EngineJob 'apply' $plan $dry
    } catch {
        $script:Applying = $false
        foreach ($p in $plan) { $script:Rows[[string]$p.Id].Note = '' }
        Ui-Note ('Could not start the background worker: ' + $_.Exception.Message) 'Red'
        Ui-RefreshAll
        Ui-Status 'Could not start - see the log.'
    }
    Ui-Flush
}

# "Make active" on a power plan's card: that plan becomes the one Windows uses. It runs at once (no question: another click switches
# back), through the background worker like any change; "Preview only" only shows what would happen.
function Ui-MakeActive {
    param($e)
    if (-not $e) { return }
    $row = $script:Rows[[string]$e.Id]
    if (-not $row -or -not $row.T.Plan) { return }
    $b = Get-BusyReason
    if ($b) { Ui-Status $b; return }
    if ([string]$row.State -ne 'On') { Ui-Status ('"{0}" is not installed: switch it on and apply first.' -f $row.T.Name); return }
    if (Test-PlanActive $row) { Ui-Status ('"{0}" is already the active plan.' -f $row.T.Name); return }
    $dry = [bool]$script:UI.dry.Checked
    $row.Note = 'Working...'; $row.NoteDetail = ''
    $script:Applying = $true
    Ui-ShowLog $true
    Ui-RefreshAll
    Ui-Progress 0 1
    if ($dry) { Ui-Status 'Preview running - nothing is changed...' } else { Ui-Status ('Making "{0}" the active plan...' -f $row.T.Name) }
    try {
        Start-EngineJob 'apply' @(@{ Id = [string]$row.T.Id; Action = 'Activate' }) $dry
    } catch {
        $script:Applying = $false
        $row.Note = ''
        Ui-Note ('Could not start the background worker: ' + $_.Exception.Message) 'Red'
        Ui-RefreshAll
        Ui-Status 'Could not start - see the log.'
    }
    Ui-Flush
}

# "Reinstall" on an installed power plan's card: the plan is made again the way Headroom installs it. It asks first (whatever was changed
# inside the plan is gone), then runs through the background worker like any change, with a restore point; "Preview only" only shows it.
function Ui-Reinstall {
    param($e)
    if (-not $e) { return }
    $row = $script:Rows[[string]$e.Id]
    if (-not $row -or -not $row.T.Plan) { return }
    $b = Get-BusyReason
    if ($b) { Ui-Status $b; return }
    if ([string]$row.State -ne 'On') { Ui-Status ('"{0}" is not installed: switch it on and apply first.' -f $row.T.Name); return }
    $dry = [bool]$script:UI.dry.Checked
    if (-not $dry) {
        $how = 'from its built-in plan file'
        $k = [string]$row.T.Plan
        if ($k -eq 'PlanBalanced' -or $k -eq 'PlanHighPerf' -or $k -eq 'Ultimate') { $how = 'as Windows ships it' }
        elseif ($k -eq 'UltimateMod') { $how = 'from Windows'' Ultimate Performance with its three changes' }
        $askText = ('Reinstall "{0}"?{1}It is made again {2}. Any setting you changed inside it goes back.' -f $row.T.Name, "`r`n", $how)
        if (Test-PlanActive $row) { $askText += ' It stays the active plan.' }
        if (-not (Ui-Ask $askText 'Reinstall power plan' $false)) { return }
    }
    $row.Note = 'Working...'; $row.NoteDetail = ''
    $script:Applying = $true
    Ui-ShowLog $true
    Ui-RefreshAll
    Ui-Progress 0 1
    if ($dry) { Ui-Status 'Preview running - nothing is changed...' } else { Ui-Status ('Reinstalling "{0}"...' -f $row.T.Name) }
    try {
        Start-EngineJob 'apply' @(@{ Id = [string]$row.T.Id; Action = 'Reinstall' }) $dry
    } catch {
        $script:Applying = $false
        $row.Note = ''
        Ui-Note ('Could not start the background worker: ' + $_.Exception.Message) 'Red'
        Ui-RefreshAll
        Ui-Status 'Could not start - see the log.'
    }
    Ui-Flush
}

function Ui-DoStop {
    if (-not $script:Applying -or -not $script:Job) { return }
    $script:Job.Stopping = $true
    try { [void]$script:Job.PS.BeginStop($null, $null) } catch { }
    Ui-Status 'Stopping after the step that is running...'
    Ui-SetEnabled $script:UI.stop $false
}

function Ui-OnClosing {
    param($e)
    if ($script:Applying) {
        if (-not (Ui-Ask "Changes are still being made.`r`nClosing now stops them half-way. Close anyway?" 'Still working' $true)) { $e.Cancel = $true }
        return
    }
    if ($script:Scanning) { return }
    $c = Get-Counts
    $n = $c.Apply + $c.Undo
    if ($n -gt 0) {
        if (-not (Ui-Ask ("You have {0} change(s) lined up that were not applied.`r`nClose anyway?" -f $n) 'Close' $false)) { $e.Cancel = $true }
    }
}

# ----------------------------------------------------------- the background job ----
# A fresh runspace for a worker. First try with scripts/modules allowed whatever the machine's policy says (the worker only
# runs our own text); if this PowerShell does not support that setting, try again with the plain defaults.
function Open-WorkerRunspace {
    $rs = $null
    $openErr = $null
    foreach ($bypass in $true, $false) {
        try {
            $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
            if ($bypass) { $iss.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass }
            $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
            $rs.Open()
            break
        } catch {
            $openErr = $_
            if ($rs) { try { $rs.Dispose() } catch { } }
            $rs = $null
        }
    }
    if (-not $rs) { throw $openErr }
    return $rs
}

function Start-EngineJob {
    param([string]$Kind, $Plan, [bool]$Dry)
    $script:LastErr = ''
    if ($script:Job) { Finish-Job }     # tidy up a worker that has already said it is done
    $rs = Open-WorkerRunspace
    $rs.SessionStateProxy.SetVariable('DryRun', $Dry)
    $rs.SessionStateProxy.SetVariable('log', $log)
    $rs.SessionStateProxy.SetVariable('StorePath', $StorePath)
    $rs.SessionStateProxy.SetVariable('Q', $script:Q)
    $call = 'Invoke-Scan'
    if ($Kind -eq 'apply') {
        $rs.SessionStateProxy.SetVariable('Plan', $Plan)
        $call = 'Invoke-Plan -Plan $Plan'
    }
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($engine.ToString() + "`r`n" + $call)
    $async = $ps.BeginInvoke()
    $script:Job = @{ PS = $ps; RS = $rs; Async = $async; Kind = $Kind; Stopping = $false }
}

function Ui-StartScan {
    if ($script:Scanning -or $script:Applying) { return }
    if ($script:StartupSynced) {
        $script:StartupSynced = $false      # the list was read a moment ago when the window was made
    } else {
        try { Sync-StartupRows } catch { Ui-Note ('Could not read the startup list: ' + $_.Exception.Message) 'Yellow' -NoFile }
    }
    foreach ($id in @($script:Rows.Keys)) {
        $r = $script:Rows[$id]
        $r.State = 'Checking'; $r.Detail = 'Checking...'; $r.Want = $false; $r.Force = ''; $r.Choice = ''; $r.Pick = ''; $r.Note = ''; $r.NoteDetail = ''
    }
    $script:Scanning = $true
    $script:WaitText = ''
    Ui-RebuildList
    Ui-Status 'Checking your PC...'
    Ui-Progress 0 1
    try {
        Start-EngineJob 'scan' $null $false
    } catch {
        $script:Scanning = $false
        foreach ($id in @($script:Rows.Keys)) { $script:Rows[$id].State = 'Unknown'; $script:Rows[$id].Detail = 'Could not be checked' }
        Ui-Note ('Could not start the background worker: ' + $_.Exception.Message) 'Red' -NoFile
        Ui-ScanFinished
    }
    Ui-Flush
}

function Ui-ScanFinished {
    Ui-RebuildList
    Ui-Progress 0 1
    Ui-Status (Get-SummaryText)
}

function Ui-RunFinished {
    param($ev)
    $script:DHead = $true
    $script:DCounts = $true
    Ui-Progress 1 1
    $s = [string]$ev.Detail
    if ($ev.Text) { $s += '  Restart the PC for: ' + [string]$ev.Text + '.' }
    Ui-Status $s
    Ui-Counts
}

# The worker finished (or died): collect it, and tidy up if it never said it was done
function Finish-Job {
    $j = $script:Job
    $script:Job = $null
    if (-not $j) { return }
    $err = ''
    try { [void]$j.PS.EndInvoke($j.Async) } catch {
        $err = $_.Exception.Message
        if ($_.Exception.InnerException) { $err = $_.Exception.InnerException.Message }
    }
    try { $j.PS.Dispose() } catch { }
    try { $j.RS.Close(); $j.RS.Dispose() } catch { }
    if ($j.Kind -eq 'scan' -and $script:Scanning) {
        $script:Scanning = $false
        foreach ($id in @($script:Rows.Keys)) {
            $r = $script:Rows[$id]
            if ($r.State -eq 'Checking') { $r.State = 'Unknown'; $r.Detail = 'Could not be checked' }
        }
        Ui-Note ('The check of your PC stopped early: ' + $err) 'Yellow' -NoFile
        Ui-ScanFinished
    }
    if ($j.Kind -eq 'apply' -and $script:Applying) {
        $script:Applying = $false
        if ($j.Stopping) { Ui-Note 'Stopped. Checking what state everything is in now...' 'Yellow' }
        else { Ui-Note ('The run ended unexpectedly: ' + $err) 'Red' }
        Ui-StartScan
    }
}

# Called by the timer: take what the worker has reported, then update the screen once
function Ui-Tick {
    if ($script:StartScanPending) {
        $script:StartScanPending = $false
        try { Ui-StartScan } catch { Ui-Fail $_ }
    }
    $n = 0
    $ev = $null
    while ($n -lt 300 -and $script:Q.TryDequeue([ref]$ev)) {
        $n++
        try { Handle-Event $ev } catch { Ui-Fail $_ }
    }
    if ($script:Job -and $script:Job.Async.IsCompleted -and $script:Q.IsEmpty) {
        try { Finish-Job } catch { Ui-Fail $_ }
    }
    # a check has finished: offer to apply the partly applied (or put-back) settings again, once the welcome screen is gone and nothing else is open
    if ($script:ReapplyPending -and -not $script:Job -and -not $script:Scanning -and -not $script:Applying -and -not (Test-WelcomeShowing) -and (Test-MainWindowActive)) {
        $script:ReapplyPending = $false
        try { Ui-OfferReapply } catch { Ui-Fail $_ }
    }
    try { Ui-SysTick } catch { Ui-Fail $_ }
    try { Ui-WelcomeTick } catch { Ui-Fail $_ }
    Ui-Flush
}

# =============================================================================
# THE WINDOW, part 5: the side menu, and what changes when another page is picked.
# The side menu is one custom-drawn control, like the list: the app name, "All settings", one line per category (with how many
# are applied). "Home" (at the top) is a page of read-outs, not of settings (see Test-InfoPage).
# The rows are roomy and keep their height: when they do not all fit, the pages scroll (mouse wheel, the thin rounded scroll bar at
# the right, or the keys) under the app name, which stays where it is.
# The "Select Optimization Preset" button is below the menu (a real button, see Ui-Build).
# A "nav entry" is a hashtable:  Kind ('item' | 'label')  Key  Cat  Title  CountText  Pending  CY (its place in the whole list)  Y (its
# place on screen: CY less the scroll)  H
# Names used for local variables in this file: $Th = colours, $M = sizes, $TF = text flags.
# =============================================================================
$script:NavItems = New-Object System.Collections.ArrayList
$script:NavHot = ''                 # key of the entry under the mouse
$script:NavW = 244
$script:NavH = 700
$script:NavRowH = 42
$script:NavCursor = ''
$script:NavScroll = 0               # how far the pages are scrolled up (pixels); the app name at the top does not scroll
$script:NavMaxScroll = 0            # how far they can be scrolled (0 when they all fit)
$script:NavContentH = 0             # the height of the head and every entry, with a little room at the end
$script:NavDrag = -1                # >= 0 while the scroll thumb is being dragged (where in the thumb it was grabbed)
$script:NavSbHot = $false           # the pointer is on the scroll bar
$script:NavMX = -1
$script:NavMY = -1
$script:NavReveal = $false          # the page that was just picked is scrolled into view the next time the menu is built
$script:AppBuild = '117'           # the number in the small pill beside the name (the version of this file)
$script:HoldFilter = $false         # true while the program itself clears the search box (no need to rebuild twice)

function Ui-InvalidateNav {
    $n = $script:UI.nav
    if ($n) { $n.Invalidate() }
}

# Build the entries again from the rows (names, counts), then lay them out
function Ui-FillNav {
    $gc = Get-GroupCounts
    $pend = @{}
    foreach ($id in @($script:Rows.Keys)) {
        $row = $script:Rows[$id]
        if (Get-Action $row) { $pend[[string]$row.T.Cat] = $true }
    }
    $allOn = 0; $allTot = 0; $allCk = 0
    foreach ($cat in $script:Cats) {
        $g = $gc[[string]$cat]
        if ($g) { $allOn += $g.On; $allTot += $g.Total; $allCk += $g.Checking }
    }
    $items = New-Object System.Collections.ArrayList
    $ct = ''
    if ($allCk -eq 0 -and $allTot -gt 0) { $ct = ('{0}/{1}' -f $allOn, $allTot) }
    [void]$items.Add(@{ Kind = 'label'; Key = 'nav-label-general'; Cat = ''; Title = 'General'; CountText = ''; Pending = $false; CY = 0; Y = 0; H = 0 })
    [void]$items.Add(@{ Kind = 'item'; Key = ('nav:' + $script:PageHome); Cat = [string]$script:PageHome; Title = 'Home'; CountText = ''; Pending = $false; CY = 0; Y = 0; H = 0 })
    [void]$items.Add(@{ Kind = 'item'; Key = 'nav:'; Cat = ''; Title = 'All settings'; CountText = $ct; Pending = [bool]($pend.Count -gt 0); CY = 0; Y = 0; H = 0 })
    [void]$items.Add(@{ Kind = 'label'; Key = 'nav-label'; Cat = ''; Title = 'Categories'; CountText = ''; Pending = $false; CY = 0; Y = 0; H = 0 })
    foreach ($cat in $script:Cats) {
        $g = $gc[[string]$cat]
        $ct = ''
        if ($g -and $g.Checking -eq 0 -and $g.Total -gt 0) { $ct = ('{0}/{1}' -f $g.On, $g.Total) }
        [void]$items.Add(@{ Kind = 'item'; Key = ('nav:' + $cat); Cat = [string]$cat; Title = (Get-NavTitle $cat); CountText = $ct; Pending = [bool]$pend[[string]$cat]; CY = 0; Y = 0; H = 0 })
    }
    $script:NavItems = $items
    Ui-NavLayout
    if ($script:NavReveal) { $script:NavReveal = $false; Ui-NavRevealCurrent }
    Ui-InvalidateNav
}

# Where each entry goes. The rows keep their height; CY is the place in the whole list and Y the place on screen (CY less the scroll).
function Ui-NavLayout {
    $M = $script:M
    $c = $script:UI.nav
    if ($c) {
        $cs = $c.ClientSize
        if ([int]$cs.Width -gt 0) { $script:NavW = [int]$cs.Width }
        if ([int]$cs.Height -gt 0) { $script:NavH = [int]$cs.Height }
    }
    $rowH = [int]$M.NavRow
    $labelH = [int]$M.NavLabel
    $script:NavRowH = $rowH
    $y = [int]$M.NavTop
    foreach ($e in $script:NavItems) {
        $e.CY = $y
        if ($e.Kind -eq 'label') { $e.H = $labelH } else { $e.H = $rowH }
        $y += $e.H
    }
    $script:NavContentH = $y + (Px 14)
    $max = [Math]::Max(0, [int]($script:NavContentH - $script:NavH))
    $script:NavMaxScroll = $max
    if ($script:NavScroll -gt $max) { $script:NavScroll = $max }
    if ($script:NavScroll -lt 0) { $script:NavScroll = 0 }
    foreach ($e in $script:NavItems) { $e.Y = $e.CY - $script:NavScroll }
}

# Scroll the pages to this position (pixels from the top, kept between 0 and the most there is)
function Ui-NavSetScroll {
    param([int]$to)
    $to = [Math]::Max(0, [Math]::Min([int]$to, [int]$script:NavMaxScroll))
    if ($to -eq [int]$script:NavScroll) { return }
    $script:NavScroll = $to
    foreach ($e in $script:NavItems) { $e.Y = $e.CY - $to }
    if ($script:NavMX -ge 0 -and $script:NavDrag -lt 0) { Ui-NavMove $script:NavMX $script:NavMY }      # another line is now under a pointer that did not move
    Ui-InvalidateNav
}

# Scroll so that this page is whole on screen (with its heading, when it is the first one under that heading)
function Ui-NavReveal {
    param([string]$cat)
    $target = $null
    $prev = $null
    foreach ($e in $script:NavItems) {
        if ($e.Kind -eq 'item' -and [string]$e.Cat -eq $cat) { $target = $e; break }
        $prev = $e
    }
    if (-not $target) { return }
    $top = [int]$target.CY
    if ($prev -and $prev.Kind -eq 'label') { $top = [int]$prev.CY }
    $viewTop = [int]$script:M.NavTop
    $viewBottom = [int]$script:NavH
    $pad = Px 8
    $s = [int]$script:NavScroll
    if (($top - $s) -lt ($viewTop + $pad)) { $s = $top - $viewTop - $pad }
    elseif (($target.CY + $target.H - $s) -gt ($viewBottom - $pad)) { $s = $target.CY + $target.H - $viewBottom + $pad }
    Ui-NavSetScroll $s
}
function Ui-NavRevealCurrent {
    $cat = ''
    if ($script:Single) { $cat = [string]$script:NavCat }
    Ui-NavReveal $cat
}

# The scroll thumb: where it is in the strip at the right of the pages (null when everything fits)
function Ui-NavThumb {
    if ([int]$script:NavMaxScroll -le 0) { return $null }
    $top = [int]$script:M.NavTop + (Px 4)
    $trackH = [int]$script:NavH - $top - (Px 6)
    if ($trackH -lt (Px 24)) { return $null }
    $view = [double]($script:NavH - $script:M.NavTop)
    $whole = [double]($script:NavContentH - $script:M.NavTop)
    $thumbH = [int][Math]::Round($trackH * $view / [Math]::Max($whole, 1.0))
    $thumbH = [Math]::Max((Px 36), [Math]::Min($thumbH, $trackH))
    $travel = $trackH - $thumbH
    $ty = $top
    if ($script:NavMaxScroll -gt 0) { $ty = $top + [int][Math]::Round($travel * [double]$script:NavScroll / [double]$script:NavMaxScroll) }
    return @{ Top = $top; TrackH = $trackH; Y = $ty; H = $thumbH; Travel = $travel }
}

function Ui-OnNavResize {
    Ui-NavLayout
    Ui-InvalidateNav
}

# ----------------------------------------------------------- painting ---------------
# The Headroom mark: a light purple rounded square holding a tall meter that is only part full, with a chevron pointing at the free space
# above the fill (that free space is the headroom). $x, $y, $s = the top-left corner of the square and its size.
# The meter is laid out on a grid of 120 units that is 74% as tall as the square; its outline is 55 x 103 units wide and tall.
# At small sizes the outline, the gap and the chevron keep a minimum thickness so that they stay clear.
function Ui-PaintLogo {
    param($g, [int]$x, [int]$y, [int]$s)
    $Th = $script:Th
    Ui-FillRound $g $Th.Accent $x $y $s $s ([int]($s * 0.29))
    $b = $s * 0.74
    $u = $b / 120.0
    $ox = $x + ($s - $b) / 2.0
    $oy = $y + ($s - $b) / 2.0
    $pw = 55.0 * $u
    $ph = 103.0 * $u
    $px = $ox + 32.5 * $u
    $py = $oy + 8.5 * $u
    $t = [Math]::Max(1.6, 7.0 * $u)              # the outline
    $gap = [Math]::Max(1.4, 6.5 * $u)            # between the outline and the fill
    Ui-StrokeRound $g $Th.KnobOn $t ([int][Math]::Round($px)) ([int][Math]::Round($py)) ([int][Math]::Round($pw)) ([int][Math]::Round($ph)) ([int][Math]::Round($pw / 2.0))
    $fw = $pw - 2.0 * ($t + $gap)
    $fh = [Math]::Max($fw, 0.5 * ($ph - 2.0 * ($t + $gap)))
    $fx = $px + $t + $gap
    $fy = $py + $ph - $t - $gap - $fh
    Ui-FillRound $g $Th.KnobOn ([int][Math]::Round($fx)) ([int][Math]::Round($fy)) ([int][Math]::Round($fw)) ([int][Math]::Round($fh)) ([int][Math]::Round($fw / 2.0))
    $cx = $ox + 60.0 * $u
    $cw = [Math]::Max(1.4, 6.0 * $u)
    $dim = Blend-Color $Th.Accent $Th.KnobOn 0.6
    Ui-StrokePoly $g $dim $cw @(@(($cx - 10.0 * $u), ($oy + 42.0 * $u)), @($cx, ($oy + 32.0 * $u)), @(($cx + 10.0 * $u), ($oy + 42.0 * $u)))
}
# The window's icon (title bar, taskbar, Alt+Tab): the same mark, drawn once into a small picture. Returns $null when that does not work;
# the window then keeps the plain default icon.
function Ui-MakeAppIcon {
    try {
        $n = 64
        $bmp = New-Object System.Drawing.Bitmap($n, $n, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            Ui-PaintLogo $g 0 0 $n
        } finally { $g.Dispose() }
        $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
        $bmp.Dispose()
        return $icon
    } catch { return $null }
}
# The little line icons of the side menu. Each is a list of drawing steps on a 24 x 24 grid:
#   p = a line through points (x1,y1, x2,y2, ...)   c = the same, closed   r = rounded square (x,y,w,h,radius)   o = oval outline (x,y,w,h)
#   d = a dot (centre x, centre y, radius)   a = an arc (centre x, centre y, radius, start angle, sweep in degrees)
#   k = short rays around a centre (centre x, centre y, inner radius, outer radius, how many, first angle)
$script:NavIcons = @{
    '_'                   = @(, @('o', 5, 5, 14, 14))
    'Home'                = @(@('p', 3, 11, 12, 3, 21, 11), @('p', 5, 9.5, 5, 20, 19, 20, 19, 9.5), @('p', 10, 20, 10, 14, 14, 14, 14, 20))
    'All settings'        = @(@('r', 4, 4, 7, 7, 2), @('r', 13, 4, 7, 7, 2), @('r', 4, 13, 7, 7, 2), @('r', 13, 13, 7, 7, 2))
    'Privacy'             = @(@('c', 2, 12, 6, 7.5, 12, 5.5, 18, 7.5, 22, 12, 18, 16.5, 12, 18.5, 6, 16.5), @('o', 9, 9, 6, 6))
    'Cloud and OneDrive'  = @(, @('c', 7, 18, 4.5, 17.5, 3, 15.5, 3, 13, 5, 11, 7.2, 10.5, 8, 8, 10, 6, 13, 5.5, 15.5, 7, 16.5, 9.5, 19, 10, 21, 12.5, 21, 15.5, 19.5, 17.5, 17.5, 18))
    'Remote and VPN'      = @(@('c', 12, 3, 20, 6, 20, 12, 12, 21, 4, 12, 4, 6), @('p', 8.5, 12, 11, 14.5, 15.5, 9.5))
    'Network sharing'     = @(@('o', 9.5, 3, 5, 5), @('o', 3, 15, 5, 5), @('o', 16, 15, 5, 5), @('p', 12, 8, 12, 12), @('p', 5.5, 15, 5.5, 12, 18.5, 12, 18.5, 15))
    'Adapters and USB'    = @(@('p', 12, 5, 12, 18), @('p', 9.5, 7, 12, 4.5, 14.5, 7), @('p', 12, 10.5, 7, 10.5, 7, 8.5), @('d', 7, 7, 1.5), @('p', 12, 14, 17, 14, 17, 12), @('d', 17, 11, 1.5), @('d', 12, 19.5, 2.2))
    'Power and startup'   = @(@('a', 12, 13, 8, -60, 300), @('p', 12, 3, 12, 12))
    'Startup apps'        = @(@('r', 3, 4, 18, 16, 3), @('p', 3, 9, 21, 9), @('c', 10, 12, 10, 17.5, 15, 14.75))
    'Gaming'              = @(@('r', 2.5, 7, 19, 11, 5.5), @('p', 8, 10.5, 8, 14.5), @('p', 6, 12.5, 10, 12.5), @('d', 15, 11.5, 1.1), @('d', 17.5, 13.5, 1.1))
    'Display'             = @(@('r', 3, 4, 18, 12, 2), @('p', 12, 16, 12, 20), @('p', 8, 20, 16, 20))
    'Placebo Tweaks'      = @(@('c', 9, 3, 9, 9, 4.5, 18, 5.2, 20, 18.8, 20, 19.5, 18, 15, 9, 15, 3), @('p', 8, 3, 16, 3), @('p', 7.5, 14, 16.5, 14))
    'Security prompts'    = @(@('r', 5, 11, 14, 10, 2.5), @('a', 12, 11, 4, 180, 180), @('d', 12, 16, 1.2))
    'Services'            = @(@('o', 6, 6, 12, 12), @('o', 9.5, 9.5, 5, 5), @('k', 12, 12, 6, 9, 8, 22.5))
    'Storage and clean-up' = @(@('p', 4, 6, 20, 6), @('p', 9, 6, 9, 4, 15, 4, 15, 6), @('p', 6, 6, 7, 20, 17, 20, 18, 6), @('p', 10, 10, 10, 16), @('p', 14, 10, 14, 16))
    'Look and feel'       = @(@('o', 3, 3, 18, 18), @('d', 8, 10, 1.3), @('d', 12, 7.5, 1.3), @('d', 16, 10, 1.3), @('d', 9, 15, 1.3))
    'File Explorer'       = @(, @('c', 3, 6, 9.5, 6, 11.5, 8.5, 21, 8.5, 21, 19, 3, 19))
    'AI features'         = @(@('c', 12, 3, 14, 10, 21, 12, 14, 14, 12, 21, 10, 14, 3, 12, 10, 10), @('p', 19, 3, 19, 7), @('p', 17, 5, 21, 5))
    'Microsoft Edge'      = @(@('o', 3, 3, 18, 18), @('o', 8, 3, 8, 18), @('p', 3, 12, 21, 12))
    'Remove apps'         = @(@('r', 4, 4, 16, 16, 3), @('p', 9, 9, 15, 15), @('p', 15, 9, 9, 15))
    'Legacy features'     = @(@('o', 3, 3, 18, 18), @('p', 12, 7, 12, 12, 15.5, 14))
    'Testing'             = @(, @('p', 2, 12, 7, 12, 9.5, 5, 14, 19, 16.5, 12, 22, 12))
    # the Home cards
    'Windows'             = @(@('r', 3, 4, 8, 7, 1), @('r', 13, 3, 8, 8, 1), @('r', 3, 13, 8, 8, 1), @('r', 13, 14, 8, 7, 1))
    'Processor'           = @(@('r', 6, 6, 12, 12, 2), @('r', 9.5, 9.5, 5, 5, 1), @('p', 9, 3, 9, 6), @('p', 15, 3, 15, 6), @('p', 9, 18, 9, 21), @('p', 15, 18, 15, 21), @('p', 3, 9, 6, 9), @('p', 3, 15, 6, 15), @('p', 18, 9, 21, 9), @('p', 18, 15, 21, 15))
    'Graphics card'       = @(@('r', 2, 6, 20, 11, 2), @('o', 9, 8.5, 6, 6), @('d', 12, 11.5, 1), @('p', 5, 17, 5, 20))
    'Memory'              = @(@('r', 2, 7, 20, 9, 1.5), @('r', 5, 9.5, 3.5, 4, 0.5), @('r', 10.25, 9.5, 3.5, 4, 0.5), @('r', 15.5, 9.5, 3.5, 4, 0.5), @('p', 6, 16, 6, 19), @('p', 10, 16, 10, 19), @('p', 14, 16, 14, 19), @('p', 18, 16, 18, 19))
    'Storage'             = @(@('r', 3, 5, 18, 14, 3), @('p', 3, 14, 21, 14), @('d', 17.5, 16.5, 1))
    'Motherboard'         = @(@('r', 3, 3, 18, 18, 2), @('r', 7, 7, 6, 6, 1), @('p', 16, 6, 16, 11), @('p', 7, 16, 17, 16))
    'Timer and clock'     = @(@('o', 4, 5, 16, 16), @('p', 12, 9, 12, 13, 15, 15), @('p', 9.5, 2.5, 14.5, 2.5), @('p', 12, 2.5, 12, 5))
    'Security'            = @(@('c', 12, 3, 20, 6, 20, 12, 12, 21, 4, 12, 4, 6), @('d', 12, 11, 1.5), @('p', 12, 12, 12, 15.5))
    'Mouse'               = @(@('r', 6, 2.5, 12, 19, 6), @('p', 12, 6, 12, 9.5), @('p', 6, 10.5, 18, 10.5))
    'Sensors'             = @(@('r', 9.5, 3, 5, 13, 2.5), @('o', 7.5, 13, 9, 9), @('p', 12, 8, 12, 16))
}
# the points of one icon step (the numbers after its letter, in pairs), moved and scaled to the place the icon is drawn
function Get-IconPts {
    param($op, [double]$x, [double]$y, [double]$k, [bool]$close)
    $pts = @()
    for ($i = 1; $i -lt ($op.Count - 1); $i += 2) { $pts += , @(($x + [double]$op[$i] * $k), ($y + [double]$op[$i + 1] * $k)) }
    if ($close -and $pts.Count -gt 0) { $pts += , @($pts[0][0], $pts[0][1]) }
    return $pts
}
# Draws the icon called $name at $x, $y, $size pixels square, in one colour
function Ui-PaintIcon {
    param($g, [string]$name, [double]$x, [double]$y, [double]$size, $color)
    $ops = $script:NavIcons[$name]
    if (-not $ops) { $ops = $script:NavIcons['_'] }
    $k = $size / 24.0
    $wd = [Math]::Max(1.3, 1.7 * $k)
    foreach ($op in @($ops)) {
        switch ([string]$op[0]) {
            'p' { Ui-StrokePoly $g $color $wd (Get-IconPts $op $x $y $k $false) }
            'c' { Ui-StrokePoly $g $color $wd (Get-IconPts $op $x $y $k $true) }
            'r' { Ui-StrokeRound $g $color $wd ([int][Math]::Round($x + $op[1] * $k)) ([int][Math]::Round($y + $op[2] * $k)) ([int][Math]::Round($op[3] * $k)) ([int][Math]::Round($op[4] * $k)) ([int][Math]::Max(1, [Math]::Round($op[5] * $k))) }
            'o' { Ui-StrokeOval $g $color $wd ($x + $op[1] * $k) ($y + $op[2] * $k) ($op[3] * $k) ($op[4] * $k) }
            'd' {
                $r = [Math]::Max(1.0, $op[3] * $k)
                Ui-FillOval $g $color ([int][Math]::Round($x + $op[1] * $k - $r)) ([int][Math]::Round($y + $op[2] * $k - $r)) ([int][Math]::Round(2 * $r)) ([int][Math]::Round(2 * $r))
            }
            'a' {
                $pts = @()
                $steps = [int][Math]::Max(6, [Math]::Ceiling([Math]::Abs([double]$op[5]) / 12))
                for ($i = 0; $i -le $steps; $i++) {
                    $ang = ([double]$op[4] + [double]$op[5] * $i / $steps) * [Math]::PI / 180.0
                    $pts += , @(($x + ($op[1] + $op[3] * [Math]::Cos($ang)) * $k), ($y + ($op[2] + $op[3] * [Math]::Sin($ang)) * $k))
                }
                Ui-StrokePoly $g $color $wd $pts
            }
            'k' {
                for ($i = 0; $i -lt [int]$op[5]; $i++) {
                    $ang = ([double]$op[6] + 360.0 * $i / [int]$op[5]) * [Math]::PI / 180.0
                    $c = [Math]::Cos($ang); $sn = [Math]::Sin($ang)
                    Ui-StrokePoly $g $color $wd @(@(($x + ($op[1] + $op[3] * $c) * $k), ($y + ($op[2] + $op[3] * $sn) * $k)), @(($x + ($op[1] + $op[4] * $c) * $k), ($y + ($op[2] + $op[4] * $sn) * $k)))
                }
            }
        }
    }
}
function Ui-PaintNav {
    param($g)
    $Th = $script:Th
    $M = $script:M
    $TF = $script:TF
    $w = $script:NavW
    $h = $script:NavH
    Ui-Fill $g $Th.Side 0 0 $w $h
    # the pages (while a search is showing, every setting is in the list, so "All settings" is the one that is lit)
    $curCat = ''
    if ($script:Single) { $curCat = [string]$script:NavCat }
    $ix = Px 14                                              # a box starts here (clear of the scroll bar at the right)
    $iw = $w - 2 * $ix
    foreach ($e in $script:NavItems) {
        if (($e.Y + $e.H) -le ($M.NavTop - (Px 2)) -or $e.Y -ge $h) { continue }          # scrolled out of sight (under the app name, or below the menu)
        if ($e.Kind -eq 'label') {
            Ui-Text $g $e.Title (Ui-Font 'small') $Th.Dim (Px 24) ($e.Y + $e.H - (Px 22)) ($w - (Px 40)) (Px 18) $TF.L
            continue
        }
        $sel = ([string]$e.Cat -eq $curCat)
        $hot = ($script:NavHot -eq $e.Key)
        $ih = $e.H - $M.NavGap
        # a flat list: a page at rest is only its icon, name and count. The open page has a soft purple fill, the one under the pointer a
        # lighter fill. Nothing has an outline.
        if ($sel) { Ui-FillRound $g $Th.SideSel $ix $e.Y $iw $ih (Px 12) }
        elseif ($hot) { Ui-FillRound $g $Th.SideHot $ix $e.Y $iw $ih (Px 12) }
        $col = $Th.Mute
        $icol = $Th.Dim
        $font = Ui-Font 'nav'
        if ($sel) { $col = $Th.Text; $icol = $Th.Accent; $font = Ui-Font 'navb' } elseif ($hot) { $col = $Th.Text; $icol = $Th.Sub }
        # the icon, then the name; a fixed column for the count at the right edge, the name gets what is left
        $isz = [int][Math]::Min((Px 18), [Math]::Max((Px 12), $ih - (Px 6)))
        $ixx = $ix + (Px 12)
        Ui-PaintIcon $g ([string]$e.Title) $ixx ($e.Y + [int](($ih - $isz) / 2)) $isz $icol
        $tx2 = $ixx + $isz + (Px 11)
        $right = $w - $ix - (Px 10)
        $limit = $right
        $pw = 0
        if ($e.CountText) {
            # the count is a plain number at the right edge (purple for the open page)
            $cf = Ui-Font 'small'
            $pw = (Ui-Measure $g ([string]$e.CountText) $cf) + (Px 12)
            $ph = Px 20
            $pxx = $right - $pw
            $pyy = $e.Y + [int](($ih - $ph) / 2)
            $pcol = $Th.Dim
            if ($sel) { $pcol = $Th.Accent }
            Ui-Text $g ([string]$e.CountText) $cf $pcol $pxx $pyy $pw $ph $TF.R
            $limit = $pxx - (Px 6)
        }
        Ui-Text $g (Get-TitleCase ([string]$e.Title)) $font $col $tx2 $e.Y ($limit - $tx2) $ih $TF.L
    }
    # the app name stays put: it is drawn over the pages that have scrolled under it
    Ui-Fill $g $Th.Side 0 0 $w $M.NavTop
    # the app name, with its mark, and the version in a small pill at the right
    $lx = Px 20
    $ly = Px 26
    $ls = Px 34
    Ui-PaintLogo $g $lx $ly $ls
    $tx = $lx + $ls + (Px 12)
    $pillT = 'v' + [string]$script:AppBuild
    $pw = (Ui-Measure $g $pillT (Ui-Font 'small')) + (Px 18)
    $ph = Px 22
    $px = $w - (Px 18) - $pw
    Ui-Text $g 'Headroom' (Ui-Font 'brand') $Th.Text $tx ($ly - (Px 2)) ($px - $tx - (Px 6)) (Px 22) $TF.L
    Ui-Text $g 'Debloat Tool' (Ui-Font 'small') $Th.Mute $tx ($ly + (Px 18)) ($px - $tx - (Px 6)) (Px 16) $TF.L
    Ui-FillRound $g $Th.Card $px ($ly + [int](($ls - $ph) / 2)) $pw $ph ([int]($ph / 2))
    Ui-Text $g $pillT (Ui-Font 'small') $Th.Mute $px ($ly + [int](($ls - $ph) / 2)) $pw $ph $TF.C
    if ($script:NavScroll -gt 0) { Ui-Line $g $Th.Edge 1 (Px 16) ($M.NavTop - 1) ($w - (Px 16)) ($M.NavTop - 1) }
    # the scroll bar (only when the pages do not all fit)
    $t = Ui-NavThumb
    if ($t) { Ui-PaintThumb $g ($w - (Px 4)) $t.Top $t.TrackH ($t.Y - $t.Top) $t.H ([bool]$script:NavSbHot) ([bool]($script:NavDrag -ge 0)) }
}

function Ui-OnNavPaint {
    param($pe)
    $g = $pe.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    Ui-PaintNav $g
}

# ----------------------------------------------------------- the mouse and keys ----------
function Ui-NavInSb {
    param([int]$x, [int]$y)
    return [bool]([int]$script:NavMaxScroll -gt 0 -and $x -ge ($script:NavW - $script:M.NavSb) -and $x -lt $script:NavW -and $y -ge $script:M.NavTop -and $y -lt $script:NavH)
}

function Ui-NavHit {
    param([int]$x, [int]$y)
    if ($x -lt 0 -or $x -ge $script:NavW) { return $null }
    if ($y -lt $script:M.NavTop -or $y -ge $script:NavH) { return $null }          # the app name does not click, and nothing outside the menu does
    if (Ui-NavInSb $x $y) { return $null }
    foreach ($e in $script:NavItems) {
        if ($e.Kind -ne 'item') { continue }
        if ($y -ge $e.Y -and $y -lt ($e.Y + $e.H - $script:M.NavGap)) { return $e }
    }
    return $null
}

function Ui-NavMove {
    param([int]$x, [int]$y)
    $script:NavMX = $x
    $script:NavMY = $y
    if ($script:NavDrag -ge 0) { Ui-NavDragTo $y; return }
    $sb = [bool](Ui-NavInSb $x $y)
    $e = Ui-NavHit $x $y
    $k = ''
    if ($e) { $k = [string]$e.Key }
    $changed = $false
    if ($sb -ne [bool]$script:NavSbHot) { $script:NavSbHot = $sb; $changed = $true }
    if ($k -ne $script:NavHot) { $script:NavHot = $k; $changed = $true }
    if ($changed) { Ui-InvalidateNav }
    $c = $script:UI.nav
    $want = 'arrow'
    if ($k) { $want = 'hand' }
    if ($c -and $script:NavCursor -ne $want) {
        $script:NavCursor = $want
        if ($want -eq 'hand') { $c.Cursor = [System.Windows.Forms.Cursors]::Hand } else { $c.Cursor = [System.Windows.Forms.Cursors]::Default }
    }
}

function Ui-NavLeave {
    if ($script:NavDrag -ge 0) { return }
    Ui-NavMove -1 -1
}

function Ui-NavDown {
    param([int]$x, [int]$y, [string]$button)
    if ($button -ne 'Left') { return }
    if (Ui-NavInSb $x $y) { Ui-NavScrollbarDown $y; return }
    $e = Ui-NavHit $x $y
    if ($e) { Ui-SetNav ([string]$e.Cat); Ui-Flush }
}

# A press on the scroll bar: on the thumb it starts a drag, above or below it the pages move a screenful
function Ui-NavScrollbarDown {
    param([int]$y)
    $t = Ui-NavThumb
    if (-not $t) { return }
    if ($y -ge $t.Y -and $y -lt ($t.Y + $t.H)) {
        $script:NavDrag = $y - $t.Y
        Ui-InvalidateNav
        return
    }
    $page = [Math]::Max((Px 80), [int]($script:NavH - $script:M.NavTop - (Px 40)))
    if ($y -lt $t.Y) { Ui-NavSetScroll ($script:NavScroll - $page) } else { Ui-NavSetScroll ($script:NavScroll + $page) }
}

function Ui-NavDragTo {
    param([int]$y)
    $t = Ui-NavThumb
    if (-not $t -or $t.Travel -le 0) { return }
    $ty = $y - $script:NavDrag - $t.Top
    if ($ty -lt 0) { $ty = 0 }
    if ($ty -gt $t.Travel) { $ty = $t.Travel }
    Ui-NavSetScroll ([int][Math]::Round($ty * [double]$script:NavMaxScroll / [double]$t.Travel))
}

function Ui-NavUp {
    if ($script:NavDrag -lt 0) { return }
    $script:NavDrag = -1
    Ui-InvalidateNav
    if ($script:NavMX -ge 0) { Ui-NavMove $script:NavMX $script:NavMY }
}

# The mouse wheel over the menu
function Ui-NavWheel {
    param([int]$delta)
    if ([int]$script:NavMaxScroll -le 0) { return }
    $step = [int]($delta / 120.0 * $script:M.NavWheel)
    if ($step -eq 0) { return }
    Ui-NavSetScroll ($script:NavScroll - $step)
}

# Up / Down / Home / End change the page. Returns $true when the key was used.
function Ui-NavKey {
    param([string]$key)
    $items = @($script:NavItems | Where-Object { $_.Kind -eq 'item' })
    if ($items.Count -eq 0) { return $false }
    $i = 0
    for ($j = 0; $j -lt $items.Count; $j++) { if ([string]$items[$j].Cat -eq [string]$script:NavCat) { $i = $j; break } }
    if ($key -eq 'Down') { $i++ }
    elseif ($key -eq 'Up') { $i-- }
    elseif ($key -eq 'Home') { $i = 0 }
    elseif ($key -eq 'End') { $i = $items.Count - 1 }
    else { return $false }
    if ($i -lt 0) { $i = 0 }
    if ($i -ge $items.Count) { $i = $items.Count - 1 }
    Ui-SetNav ([string]$items[$i].Cat)
    Ui-Flush
    return $true
}

# ----------------------------------------------------------- changing the page ----------
# Show another category (or all settings). A search that is typed in is cleared: picking a page leaves the search.
function Ui-SetNav {
    param([string]$cat)
    $changed = ($cat -ne [string]$script:NavCat)
    $script:NavCat = $cat
    $f = $script:UI.find
    $hadText = $false
    if ($f -and ([string]$f.Text).Trim() -ne '') {
        $hadText = $true
        $script:HoldFilter = $true
        try { $f.Text = '' } finally { $script:HoldFilter = $false }
    }
    if (-not $changed -and -not $hadText) { return }
    $script:NavReveal = $true
    $script:DNav = $true
    Ui-OnFilterChanged
}

# The big title, the line under it, the numbers on the filter buttons and the "turn all" buttons
function Ui-UpdatePage {
    $ui = $script:UI
    $text = ''
    if ($ui.find) { $text = ([string]$ui.find.Text).Trim() }
    $shown = 0
    foreach ($id in @($script:Rows.Keys)) { if ($script:Rows[$id].Visible) { $shown++ } }
    $info = Get-PageInfo ([string]$script:NavCat) $text $shown
    if ($ui.title -and [string]$ui.title.Text -cne [string]$info.Title) { $ui.title.Text = [string]$info.Title; Ui-FitTitle }
    if ($ui.sub -and [string]$ui.sub.Text -cne [string]$info.Sub) { $ui.sub.Text = [string]$info.Sub }
    $cat = [string]$script:NavCat
    if ($text) { $cat = '' }
    $mc = Get-ModeCounts $cat $text ([string]$script:Mode) ([string]$script:Risk)
    foreach ($b in @($ui.chips)) {
        $n = ''
        if ($mc.Checking -eq 0) { $n = [string]$mc[[string]$b.Name] }
        if ([string]$script:ChipCount[[string]$b.Name] -ne $n) {
            $script:ChipCount[[string]$b.Name] = $n
            $b.Invalidate()
        }
    }
    $page = [string]$script:NavCat
    if ($text) { $page = '' }
    $isInfo = [bool](Test-InfoPage $page)
    # "Turn all on / off" are at the top right of every page that has a list of settings (All settings too), not while a search is showing
    $showAll = [bool](-not $text -and -not $isInfo)
    foreach ($k in 'allOn', 'allOff') {
        $b = $ui[$k]
        if ($b -and [bool]$b.Visible -ne $showAll) { $b.Visible = $showAll }
    }
    $showApplyAll = [bool](Test-ApplyAllPage ([string]$script:NavCat) $text)
    $b = $ui.applyAll
    if ($b -and [bool]$b.Visible -ne $showApplyAll) { $b.Visible = $showApplyAll }
    # a page of read-outs has no filter buttons, no details card (the list takes the whole width) and no settings to turn on
    foreach ($k in 'segBox', 'detCard', 'gap') {
        $c = $ui[$k]
        if ($c -and [bool]$c.Visible -eq $isInfo) { $c.Visible = (-not $isInfo) }
    }
    # without the filter buttons the header is shorter, so the cards start higher
    $hh = [int]$script:M.HeaderH
    if ($isInfo) { $hh = [int]$script:M.HeaderInfoH }
    if ($ui.header -and [int]$ui.header.Height -ne $hh) { $ui.header.Height = $hh }
    # the button that belongs to the page (Display settings / Start HWiNFO / Compare Power Plans), left of the search box
    $pb = $ui.pageBtn
    if ($pb) {
        $pt = Ui-PageButtonText $page
        $want = [bool]($pt -ne '')
        if ($want -and [string]$pb.Text -ne $pt) {
            $pb.Text = $pt
            $bw = [Math]::Max((Px 140), ((Ui-TextWidth $pt (Ui-Font 'btn')) + (Px 36)))     # (as wide as its text needs)
            if ([int]$pb.Width -ne $bw) { $pb.Width = $bw }
        }
        if ([bool]$pb.Visible -ne $want) { $pb.Visible = $want }
        Ui-PlacePageBtn
    }
    Ui-OnPageShown
}

# =============================================================================
# THE WINDOW, part 4: building the form and showing it.
# The form has two parts side by side: the side menu (docked left) and the main area (fills the rest). The main area holds
# the header (title, search, filter buttons), the list and the details card, the log and the footer (status and buttons).
# Docking rule used below: the control added FIRST fills what is left; each docked control added later is laid out before it.
# Positions of things on the right-hand side are set in Ui-PlaceBars (not with Anchor), so they are right at every size.
# =============================================================================
function New-Pnl {
    param([string]$dock, [int]$size, $back)
    $p = New-Object System.Windows.Forms.Panel
    $p.BackColor = $back
    if ($dock -eq 'Top') { $p.Dock = [System.Windows.Forms.DockStyle]::Top; $p.Height = $size }
    elseif ($dock -eq 'Bottom') { $p.Dock = [System.Windows.Forms.DockStyle]::Bottom; $p.Height = $size }
    elseif ($dock -eq 'Right') { $p.Dock = [System.Windows.Forms.DockStyle]::Right; $p.Width = $size }
    elseif ($dock -eq 'Left') { $p.Dock = [System.Windows.Forms.DockStyle]::Left; $p.Width = $size }
    elseif ($dock -eq 'Fill') { $p.Dock = [System.Windows.Forms.DockStyle]::Fill }
    return $p
}

function New-Lbl {
    param([string]$text, [string]$font, $fore, $back, [int]$x, [int]$y)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.Font = (Ui-Font $font)
    $l.ForeColor = $fore
    $l.BackColor = $back
    $l.AutoSize = $true
    $l.Location = New-Object System.Drawing.Point($x, $y)
    return $l
}

function New-Rich {
    param($back, $fore, [string]$font)
    $r = New-Object System.Windows.Forms.RichTextBox
    $r.Dock = [System.Windows.Forms.DockStyle]::Fill
    $r.ReadOnly = $true                  # (before the colours: ReadOnly resets the back colour)
    $r.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $r.BackColor = $back
    $r.ForeColor = $fore
    $r.Font = (Ui-Font $font)
    $r.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::Vertical
    $r.WordWrap = $true
    $r.DetectUrls = $false
    $r.HideSelection = $false
    $r.TabStop = $false
    $r.Add_HandleCreated({ param($s, $e) try { Ui-DarkScroll $s } catch { } })
    return $r
}

function Ui-StyleDry {
    $d = $script:UI.dry
    if (-not $d) { return }
    $d.BackColor = $script:Th.Card
    if ($d.Checked) { $d.ForeColor = $script:Th.Accent } else { $d.ForeColor = $script:Th.Sub }
    $d.Invalidate()
}

# Things that sit against the right edge, and things as wide as the window
function Ui-PlaceBars {
    $ui = $script:UI
    $M = $script:M
    if (-not $ui.form) { return }
    $fw = [int]$ui.form.ClientSize.Width
    if ($fw -lt (Px 300)) { return }       # minimised
    $mw = $fw - $M.Side                    # the width of the main area
    $g = $M.Gutter
    $wv = $ui.welcome
    if ($wv -and [bool]$wv.Visible) { $wv.Size = $ui.form.ClientSize }
    $ui.allOff.Left = $mw - $g - $ui.allOff.Width
    $ui.allOn.Left = $ui.allOff.Left - (Px 4) - $ui.allOn.Width
    $ui.applyAll.Left = $ui.allOn.Left - (Px 8) - $ui.applyAll.Width         # the three page buttons are one group on the tab row
    Ui-PlacePageBtn
    $ui.barTrack.Width = $mw
    $ui.status.Width = $mw - 2 * $g
    $x = $mw - $g
    foreach ($k in 'apply', 'stop', 'discard', 'restart') {
        $b = $ui[$k]
        $x -= $b.Width
        $b.Left = $x
        $x -= (Px 8)
    }
    Ui-ApplyBar
}

# The button that belongs to the page sits at the right end of the title row; the title stops before it
function Ui-PlacePageBtn {
    $ui = $script:UI
    $M = $script:M
    if (-not $ui.form -or -not $ui.title) { return }
    $fw = [int]$ui.form.ClientSize.Width
    if ($fw -lt (Px 300)) { return }
    $edge = ($fw - $M.Side) - $M.Gutter
    $limit = $edge
    $pb = $ui.pageBtn
    if ($pb) {
        $pb.Left = $edge - $pb.Width
        if ([bool]$pb.Visible) { $limit = $pb.Left }
    }
    $ui.title.Width = [Math]::Max((Px 100), ($limit - $M.Gutter - (Px 16)))
    $ui.sub.Width = [Math]::Max((Px 100), ($edge - $M.Gutter - (Px 16)))
    Ui-FitTitle
}

function Ui-Build {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Ui-InitNative                                   # also makes the process DPI-aware: must come before the first window
    try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch { }
    $script:Scale = Ui-GetScale
    Ui-InitMetrics
    Ui-InitTheme
    Ui-InitFlags
    $script:Fonts = @{}
    $script:Brushes = @{}
    $script:Pens = @{}
    $script:ChipCount = @{}
    $script:TitleFont = 'title'
    $script:BtnHot = $null
    $script:BtnDown = $null
    $Th = $script:Th
    $M = $script:M
    $script:UI = @{}
    $script:UI.tip = New-Object System.Windows.Forms.ToolTip

    # --- the window
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Headroom'
    $appIcon = Ui-MakeAppIcon
    if ($appIcon) { try { $form.Icon = $appIcon } catch { } }
    $form.Font = (Ui-Font 'ui')
    $form.BackColor = $Th.Side
    $form.ForeColor = $Th.Text
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.KeyPreview = $true
    $wa = Ui-WorkArea
    $w = [Math]::Min((Px 1480), ([int]$wa.Width - (Px 40)))
    $h = [Math]::Min((Px 900), ([int]$wa.Height - (Px 40)))
    $minW = [Math]::Min((Px 1060), $w)
    $minH = [Math]::Min((Px 720), $h)       # (the side menu scrolls when its pages do not fit; 720 leaves a good part of it, and the block under it, in view)
    $form.ClientSize = New-Object System.Drawing.Size($w, $h)
    $form.MinimumSize = New-Object System.Drawing.Size($minW, $minH)
    $script:UI.form = $form
    $mw = $w - $M.Side                                # width of the main area

    # --- side menu: the pages (drawn by us), then the two app-wide controls at the bottom
    $side = New-Pnl 'Left' $M.Side $Th.Side
    $nav = New-Object System.Windows.Forms.Control
    $nav.Dock = [System.Windows.Forms.DockStyle]::Fill
    $nav.BackColor = $Th.Side
    $nav.TabStop = $true
    Ui-DoubleBuffer $nav
    $sideBottom = New-Pnl 'Bottom' (Px 140) $Th.Side
    $btnPresets = New-Btn 'Select Optimization Preset' 220 'accent' 'Choose how to set up this PC: answer a few questions (Question Preset) or use your own Custom Preset. Each one shows what it changes first, and nothing is changed until you confirm.' 40
    $btnPresets.Location = New-Object System.Drawing.Point((Px 12), (Px 6))
    $dry = New-Object System.Windows.Forms.CheckBox
    $dry.Appearance = [System.Windows.Forms.Appearance]::Button
    $dry.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $dry.UseVisualStyleBackColor = $false
    $dry.Text = 'Preview only'
    $dry.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $dry.Font = (Ui-Font 'btn')
    $dry.Cursor = [System.Windows.Forms.Cursors]::Hand
    $dry.Size = New-Object System.Drawing.Size(($M.Side - (Px 24)), (Px 40))
    $dry.Location = New-Object System.Drawing.Point((Px 12), (Px 52))
    $dry.FlatAppearance.BorderSize = 0
    $dry.FlatAppearance.CheckedBackColor = $Th.Card
    $dry.FlatAppearance.MouseOverBackColor = $Th.Card
    $dry.FlatAppearance.MouseDownBackColor = $Th.Card
    $dry.Checked = [bool]$DryRun
    Ui-DoubleBuffer $dry
    Ui-WireBtn $dry 'switch'
    $script:UI.tip.SetToolTip($dry, 'When on, the Apply button only lists what would happen and changes nothing.')
    $btnRescan = New-Btn 'Check again' 100 'ghost' 'Look at the PC again and show what is applied now.' 38
    $btnRescan.Size = New-Object System.Drawing.Size(($M.Side - (Px 24)), (Px 38))
    $btnRescan.Location = New-Object System.Drawing.Point((Px 12), (Px 98))
    $sideBottom.Controls.Add($btnPresets)
    $sideBottom.Controls.Add($dry)
    $sideBottom.Controls.Add($btnRescan)
    $side.Controls.Add($nav)
    $side.Controls.Add($sideBottom)
    $script:UI.sideBottom = $sideBottom
    $script:UI.side = $side
    $script:UI.nav = $nav
    $script:UI.dry = $dry
    $script:UI.presetBtn = $btnPresets            # Select Optimization Preset (opens the window with the three presets)
    $script:UI.rescan = $btnRescan

    # --- header: page title, the filter buttons
    $header = New-Pnl 'Top' $M.HeaderH $Th.Bg
    $title = New-Lbl 'All Settings' 'title' $Th.Text $Th.Bg $M.Gutter (Px 20)
    $title.AutoSize = $false
    $title.AutoEllipsis = $true
    $title.Size = New-Object System.Drawing.Size((Px 400), (Px 38))
    $sub = New-Lbl '' 'sub' $Th.Sub $Th.Bg ($M.Gutter + (Px 2)) (Px 62)
    $sub.AutoSize = $false
    $sub.AutoEllipsis = $true
    $sub.Size = New-Object System.Drawing.Size((Px 400), (Px 22))
    $btnApplyAll = New-Btn 'Apply all' 128 'accent' 'Applies every setting on this page: each switch moves to the position this app sets (diagnostic data off, dark mode on, and so on). You are asked to confirm first.' 34
    $btnApplyAll.Top = (Px 141)            # in the same row as "Tweak all" and "Reset all": the three page actions sit together
    $btnApplyAll.Visible = $false
    $btnPage = New-Btn 'Start HWiNFO' 140 'secondary' 'Do what this page is for: start HWiNFO with its sensors shared with this app (Home), open Windows display settings (Display), or compare the six power plans side by side (Power; it only reads).' 32
    $btnPage.Top = (Px 24)
    $btnPage.Visible = $false
    # the search box lives in the side menu, under the app name
    $searchBox = Ui-NewCard $Th.Card $Th.Card $M.Radius 'search'
    $searchBox.BackColor = $Th.Side
    $searchBox.Size = New-Object System.Drawing.Size(($M.Side - (Px 24)), $M.SearchH)
    $searchBox.Location = New-Object System.Drawing.Point((Px 12), $M.SearchY)
    $find = New-Object System.Windows.Forms.TextBox
    $find.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $find.BackColor = $Th.Card
    $find.ForeColor = $Th.Text
    $find.Font = (Ui-Font 'row')
    $find.Location = New-Object System.Drawing.Point((Px 40), (Px 11))
    $find.Width = ($M.Side - (Px 24)) - (Px 40) - (Px 12)
    $searchBox.Controls.Add($find)
    $script:UI.find = $find
    $script:UI.searchBox = $searchBox
    $nav.Controls.Add($searchBox)

    # the filter tabs are plain text with the number next to it; the open one is a filled box.
    # Two rows: the state of the setting (top) and its risk (below); one tab is open in each row and they work together.
    $chipClick = { param($s, $e) try { Ui-SetMode ([string]$s.Name) } catch { Ui-Fail $_ } }
    $chipRows = @(
        @(
            @('All settings', 'All', 70),
            @('Applied', 'Applied', 96),
            @('Not applied', 'Not applied', 118),
            @('Waiting to change', 'Waiting', 98),
            @('Recommended', 'Recommended', 124),
            @('Personal', 'Custom', 92)
        ),
        @(
            @('Any risk', 'Any risk', 100),
            @('Low risk', 'Low risk', 100),
            @('Medium risk', 'Medium risk', 118),
            @('Risky', 'Risky', 84)
        )
    )
    $segBox = Ui-NewCard $Th.Bg $Th.Bg 0
    $chips = New-Object System.Collections.ArrayList
    $rowTop = 0
    $segW = 0
    foreach ($chipDefs in $chipRows) {
        $x = 0
        foreach ($cd in $chipDefs) {
            $cb = New-Btn ([string]$cd[1]) ([int]$cd[2]) 'tab' '' 38
            $cb.Name = [string]$cd[0]
            $cb.Location = New-Object System.Drawing.Point($x, $rowTop)
            $cb.Add_Click($chipClick)
            $segBox.Controls.Add($cb)
            [void]$chips.Add($cb)
            $x += $cb.Width + (Px 2)
        }
        if ($x -gt $segW) { $segW = $x }
        $rowTop += (Px 40)
    }
    $segBox.Size = New-Object System.Drawing.Size($segW, ($rowTop - (Px 2)))
    $segBox.Location = New-Object System.Drawing.Point(($M.Gutter - (Px 4)), (Px 98))
    $script:UI.chips = $chips
    $script:UI.segBox = $segBox
    $btnAllOn = New-Btn 'Tweak all' 100 'secondary' 'Line up every setting on this page at the position this app sets (the ones Apply all leaves out stay as they are). Nothing is changed until you press Apply changes.' 34
    $btnAllOff = New-Btn 'Reset all' 104 'secondary' 'Line up every setting on this page at its Windows default (Game Mode and the windowed-games optimizations go back to on). Nothing is changed until you press Apply changes.' 34
    $btnAllOn.Top = (Px 141)               # level with the second row of tabs (the risk tabs), which is short: the first row would run into them in a narrow window
    $btnAllOff.Top = (Px 141)
    $btnAllOn.Visible = $false
    $btnAllOff.Visible = $false
    foreach ($hc in $title, $sub, $btnApplyAll, $btnPage, $segBox, $btnAllOn, $btnAllOff) { $header.Controls.Add($hc) }
    $script:UI.header = $header
    $script:UI.title = $title
    $script:UI.sub = $sub
    $script:UI.applyAll = $btnApplyAll
    $script:UI.pageBtn = $btnPage
    $script:UI.allOn = $btnAllOn
    $script:UI.allOff = $btnAllOff

    # --- middle: the list on the left, the details card on the right
    $mid = New-Pnl 'Fill' 0 $Th.Bg
    $mid.Padding = New-Object System.Windows.Forms.Padding($M.Gutter, (Px 4), $M.Gutter, (Px 10))
    $lst = New-Object System.Windows.Forms.Control
    $lst.Dock = [System.Windows.Forms.DockStyle]::Fill
    $lst.BackColor = $Th.Bg
    $lst.TabStop = $true
    Ui-DoubleBuffer $lst
    $gap = New-Pnl 'Right' (Px 16) $Th.Bg
    $detCard = Ui-NewCard $Th.Card $Th.Card $M.Radius
    $detCard.Dock = [System.Windows.Forms.DockStyle]::Right
    $detCard.Width = $M.Details
    $detCard.Padding = New-Object System.Windows.Forms.Padding((Px 22), (Px 20), (Px 12), (Px 16))
    $detail = New-Rich $Th.Card $Th.Text 'body'
    $forceBtn = New-Btn 'Put this one fully back (undo)' 200 'secondary' 'Turn this setting fully off and put the Windows default back.' 38
    $forceBtn.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $forceBtn.Visible = $false
    $detCard.Controls.Add($detail)
    $detCard.Controls.Add($forceBtn)
    $mid.Controls.Add($lst)
    $mid.Controls.Add($gap)
    $mid.Controls.Add($detCard)
    $script:UI.list = $lst
    $script:UI.gap = $gap
    $script:UI.detCard = $detCard
    $script:UI.detail = $detail
    $script:UI.forceBtn = $forceBtn

    # --- log
    $logCard = New-Pnl 'Bottom' (Px 176) $Th.Bg
    $logCard.Padding = New-Object System.Windows.Forms.Padding($M.Gutter, 0, $M.Gutter, (Px 12))
    $logBorder = Ui-NewCard $Th.LogBg $Th.LogBg $M.Radius
    $logBorder.Dock = [System.Windows.Forms.DockStyle]::Fill
    $logBorder.Padding = New-Object System.Windows.Forms.Padding((Px 16), (Px 12), (Px 10), (Px 12))
    $logBox = New-Rich $Th.LogBg (Rgb 196 200 214) 'mono'
    $logBorder.Controls.Add($logBox)
    $logCard.Controls.Add($logBorder)
    $script:UI.logCard = $logCard
    $script:UI.log = $logBox

    # --- footer: progress line, status text, buttons
    $footer = New-Pnl 'Bottom' $M.FooterH $Th.Bg
    $barTrack = New-Pnl 'None' 0 $Th.Edge
    $barTrack.Location = New-Object System.Drawing.Point(0, 0)
    $barTrack.Size = New-Object System.Drawing.Size($mw, (Px 2))
    $barFill = New-Pnl 'None' 0 $Th.Accent
    $barFill.Location = New-Object System.Drawing.Point(0, 0)
    $barFill.Size = New-Object System.Drawing.Size(0, (Px 2))
    $barTrack.Controls.Add($barFill)
    $status = New-Lbl '' 'ui' $Th.Sub $Th.Bg $M.Gutter (Px 8)
    $status.AutoSize = $false
    $status.AutoEllipsis = $true
    $status.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft       # room for two lines: a long summary wraps instead of being cut off
    $status.Size = New-Object System.Drawing.Size(($mw - 2 * $M.Gutter), (Px 34))
    $btnLog = New-Btn 'Hide log' 86 'ghost' 'Show or hide the log below the list.' 36
    $btnOpenLog = New-Btn 'Open log' 92 'ghost' 'Open the log file in Notepad.' 36
    $btnRestart = New-Btn 'Restart PC...' 124 'secondary' 'Restart Windows (asks first).' 36
    $btnDiscard = New-Btn 'Clear changes' 120 'secondary' 'Forget the changes you have lined up (the switches go back to how the PC is now).' 36
    $btnStop = New-Btn 'Stop' 72 'secondary' 'Stop after the step that is running, then check the PC again.' 36
    $btnApply = New-Btn 'Apply changes' 176 'primary' 'Make the changes you lined up. A restore point is created first.' 36
    $btnApply.Enabled = $false
    Ui-StyleBtn $btnApply
    $btnStop.Enabled = $false
    Ui-StyleBtn $btnStop
    $rowTop = Px 44
    foreach ($fb in $btnLog, $btnOpenLog, $btnRestart, $btnDiscard, $btnStop, $btnApply) { $fb.Top = $rowTop }
    $btnLog.Left = $M.Gutter - (Px 8)
    $btnOpenLog.Left = $btnLog.Left + $btnLog.Width + (Px 4)
    foreach ($fc in $barTrack, $status, $btnLog, $btnOpenLog, $btnRestart, $btnDiscard, $btnStop, $btnApply) { $footer.Controls.Add($fc) }
    $script:UI.footer = $footer
    $script:UI.barTrack = $barTrack
    $script:UI.barFill = $barFill
    $script:UI.status = $status
    $script:UI.logBtn = $btnLog
    $script:UI.openlog = $btnOpenLog
    $script:UI.restart = $btnRestart
    $script:UI.discard = $btnDiscard
    $script:UI.stop = $btnStop
    $script:UI.apply = $btnApply

    # Docking: the Fill control first, then the edge panels (the last one added ends up outermost)
    $main = New-Pnl 'Fill' 0 $Th.Bg
    $main.Controls.Add($mid)
    $main.Controls.Add($logCard)
    $main.Controls.Add($footer)
    $main.Controls.Add($header)
    $form.Controls.Add($main)
    $form.Controls.Add($side)
    $script:UI.main = $main
    Ui-PlaceBars
    Ui-StyleDry
    Ui-StyleChips

    # --- events (every handler is wrapped so a mistake never crashes the window)
    $lst.Add_Paint({ param($s, $e) try { Ui-OnPaint $e } catch { Ui-Fail $_ } })
    $lst.Add_Resize({ try { Ui-OnListResize } catch { Ui-Fail $_ } })
    $lst.Add_MouseMove({ param($s, $e) try { Ui-OnMouseMove $e.X $e.Y } catch { Ui-Fail $_ } })
    $lst.Add_MouseDown({ param($s, $e) try { [void]$s.Focus(); Ui-OnMouseDown $e.X $e.Y ([string]$e.Button) } catch { Ui-Fail $_ } })
    $lst.Add_MouseUp({ param($s, $e) try { Ui-OnMouseUp } catch { Ui-Fail $_ } })
    $lst.Add_MouseLeave({ try { Ui-OnMouseLeave } catch { Ui-Fail $_ } })
    $lst.Add_MouseEnter({ param($s, $e) try { [void]$s.Focus() } catch { } })
    $lst.Add_MouseWheel({ param($s, $e) try { Ui-OnWheel $e.Delta } catch { Ui-Fail $_ } })
    $lst.Add_PreviewKeyDown({ param($s, $e) try { if (Test-ListKey ([string]$e.KeyCode)) { $e.IsInputKey = $true } } catch { Ui-Fail $_ } })
    $lst.Add_KeyDown({ param($s, $e) try { if (Ui-OnKey ([string]$e.KeyCode)) { $e.Handled = $true; $e.SuppressKeyPress = $true } } catch { Ui-Fail $_ } })
    $nav.Add_Paint({ param($s, $e) try { Ui-OnNavPaint $e } catch { Ui-Fail $_ } })
    $nav.Add_Resize({ try { Ui-OnNavResize } catch { Ui-Fail $_ } })
    $nav.Add_MouseMove({ param($s, $e) try { Ui-NavMove $e.X $e.Y } catch { Ui-Fail $_ } })
    $nav.Add_MouseLeave({ try { Ui-NavLeave } catch { Ui-Fail $_ } })
    $nav.Add_MouseUp({ try { Ui-NavUp } catch { Ui-Fail $_ } })
    $nav.Add_MouseWheel({ param($s, $e) try { Ui-NavWheel $e.Delta } catch { Ui-Fail $_ } })
    $nav.Add_MouseDown({ param($s, $e) try { [void]$s.Focus(); Ui-NavDown $e.X $e.Y ([string]$e.Button) } catch { Ui-Fail $_ } })
    $nav.Add_PreviewKeyDown({ param($s, $e) try { if (@('Up', 'Down', 'Home', 'End') -contains [string]$e.KeyCode) { $e.IsInputKey = $true } } catch { Ui-Fail $_ } })
    $nav.Add_KeyDown({ param($s, $e) try { if (Ui-NavKey ([string]$e.KeyCode)) { $e.Handled = $true; $e.SuppressKeyPress = $true } } catch { Ui-Fail $_ } })
    $find.Add_TextChanged({ try { if (-not $script:HoldFilter) { Ui-OnFilterChanged } } catch { Ui-Fail $_ } })
    $find.Add_KeyDown({ param($s, $e) try { if ([string]$e.KeyCode -eq 'Escape') { $s.Text = ''; $e.Handled = $true; $e.SuppressKeyPress = $true } } catch { Ui-Fail $_ } })
    $find.Add_Enter({ try { $script:UI.searchBox.Tag.Edge = $script:Th.Accent; $script:UI.searchBox.Invalidate() } catch { } })
    $find.Add_Leave({ try { $script:UI.searchBox.Tag.Edge = $script:Th.Card; $script:UI.searchBox.Invalidate() } catch { } })
    $find.Add_HandleCreated({ param($s, $e) try { Ui-Cue $s 'Find a setting' } catch { } })
    $dry.Add_CheckedChanged({ try { Ui-StyleDry; Ui-Counts } catch { Ui-Fail $_ } })
    $forceBtn.Add_Click({ try { Ui-ForceUndo } catch { Ui-Fail $_ } })
    $btnApply.Add_Click({ try { Ui-DoApply } catch { Ui-Fail $_ } })
    $btnStop.Add_Click({ try { Ui-DoStop } catch { Ui-Fail $_ } })
    $btnPresets.Add_Click({ try { Ui-ShowPresets } catch { Ui-Fail $_ } })
    $btnApplyAll.Add_Click({ try { Ui-DoApplyAll } catch { Ui-Fail $_ } })
    $btnPage.Add_Click({ try { Ui-DoPageButton } catch { Ui-Fail $_ } })
    $btnDiscard.Add_Click({ try { Ui-DoDiscard } catch { Ui-Fail $_ } })
    $btnRescan.Add_Click({ try { Ui-DoRescan } catch { Ui-Fail $_ } })
    $btnOpenLog.Add_Click({ try { Ui-DoOpenLog } catch { Ui-Fail $_ } })
    $btnRestart.Add_Click({ try { Ui-DoRestart } catch { Ui-Fail $_ } })
    $btnLog.Add_Click({ try { Ui-ToggleLog } catch { Ui-Fail $_ } })
    $btnAllOn.Add_Click({ try { Ui-GroupTick ($(if ($script:Single) { [string]$script:NavCat } else { '' })) $true } catch { Ui-Fail $_ } })
    $btnAllOff.Add_Click({ try { Ui-GroupTick ($(if ($script:Single) { [string]$script:NavCat } else { '' })) $false } catch { Ui-Fail $_ } })
    $form.Add_HandleCreated({ param($s, $e) try { Ui-DarkTitle $s; Ui-TitleColor $s } catch { } })
    $form.Add_Resize({ try { Ui-PlaceBars } catch { Ui-Fail $_ } })
    $form.Add_FormClosing({ param($s, $e) try { Ui-OnClosing $e } catch { Ui-Fail $_ } })
    $form.Add_KeyDown({ param($s, $e) try { if ($e.Control -and [string]$e.KeyCode -eq 'F' -and -not (Test-WelcomeShowing)) { [void]$script:UI.find.Focus(); $e.Handled = $true; $e.SuppressKeyPress = $true } } catch { } })
    $form.Add_Shown({
        try {
            Ui-PlaceBars
            Ui-ListSize
            Ui-NavLayout
            if (Test-WelcomeShowing) { Ui-WelcomeFocus } else { $script:UI.form.ActiveControl = $script:UI.list }
            Ui-InvalidateAll
            Ui-InvalidateNav
        } catch { Ui-Fail $_ }
        $script:StartScanPending = $true       # the first check starts on the next tick, after the window has been painted
    })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 80
    $timer.Add_Tick({ try { Ui-Tick } catch { Ui-Fail $_ } })
    $script:UI.timer = $timer
    Ui-BuildWelcome                                  # the welcome screen, on top of everything until Begin / Skip
}

function Show-Window {
    $script:Q = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    New-Rows
    Load-Personal                       # the saved Personal Preset, if there is one
    $script:StartupSynced = $true       # the catalog was just built from this PC, so the first check need not read the startup list again
    Ui-Build
    $script:NavCat = $script:PageHome   # the app opens to the Home page
    try { Start-SysWorker } catch { $script:SysShared = $null; $script:SysWorker = $null; Ui-Note ('The system information could not be read: ' + $_.Exception.Message) 'Yellow' }
    Ui-ShowLog $false                   # the log starts folded away (the list gets the room); Apply opens it, or use the button
    Ui-RebuildList
    Ui-Log ('Log file: ' + $log) 'DarkGray'
    Ui-Flush
    $script:UI.timer.Start()
    try {
        [void]$script:UI.form.ShowDialog()
    } finally {
        try { $script:UI.timer.Stop(); $script:UI.timer.Dispose() } catch { }
        try { $script:UI.wtimer.Stop(); $script:UI.wtimer.Dispose() } catch { }
        try { Stop-SysWorker } catch { }
        if ($script:Job) {
            try { $script:Job.PS.Stop() } catch { }
            try { $script:Job.RS.Close() } catch { }
            $script:Job = $null
        }
        try { $script:UI.form.Dispose() } catch { }
        foreach ($d in (@($script:Brushes.Values) + @($script:Pens.Values) + @($script:Fonts.Values))) { try { $d.Dispose() } catch { } }
    }
}

# =============================================================================
# THE WINDOW, part 6: the Home page and the live cards on the Display page.
# These pages show read-outs, not settings. A read-out is an "info card": one entry of the list (Kind = 'info') that is drawn
# like a settings card but has no switch and cannot be selected. What the cards say comes from a background reader ($sysEngine in
# e5-sys.ps1) that fills $script:SysShared; this file only turns that data into cards and draws them.
#   info card:  Kind='info'  Key Cat Title Sub Lines NoteLines Note Chip ChipKey Span Top X W Y H Idx
#               Lines = list of @{ L = label; V = value; K = colour name; Bar = $null or 0..100 }
# Names used for local variables here: $Th = colours, $M = sizes, $TF = text flags, $d = the data (static, live).
# =============================================================================
$script:SysShared = $null            # what the background reader writes (a synchronized hashtable); $null before it starts
$script:SysWorker = $null            # the background reader that runs while the window is open
$script:SysSeen = -1
$script:Deg = [string][char]0xB0

# ----------------------------------------------------------- numbers as text ----
function Fmt-N {
    param($v, [int]$dec = 0)
    if ($null -eq $v) { return '' }
    return ([double]$v).ToString(('N' + $dec), [Globalization.CultureInfo]::InvariantCulture)
}
function Fmt-Gb {
    param($mb, [int]$dec = 1)
    if ($null -eq $mb) { return '' }
    return ((Fmt-N ([double]$mb / 1024.0) $dec) + ' GB')
}
# seconds -> "2 d 3 h 12 min"
function Fmt-Span {
    param($sec)
    if ($null -eq $sec) { return '' }
    $s = [int]$sec
    $d = [int][Math]::Floor($s / 86400); $h = [int][Math]::Floor(($s % 86400) / 3600); $m = [int][Math]::Floor(($s % 3600) / 60)
    if ($d -gt 0) { return ('{0} d {1} h {2} min' -f $d, $h, $m) }
    if ($h -gt 0) { return ('{0} h {1} min' -f $h, $m) }
    if ($m -gt 0) { return ('{0} min' -f $m) }
    return 'under a minute'
}
# Windows keeps its edition under an internal name ("Core" is Home, "Professional" is Pro); this is the name Settings shows.
# A name that is not known is shown as it is.
function Fmt-Edition {
    param([string]$Id)
    $k = ([string]$Id).Trim()
    if (-not $k) { return '' }
    $map = @{
        'core' = 'Home'; 'coren' = 'Home N'; 'coresinglelanguage' = 'Home Single Language'; 'corecountryspecific' = 'Home China'
        'professional' = 'Pro'; 'professionaln' = 'Pro N'; 'professionalworkstation' = 'Pro for Workstations'; 'professionalworkstationn' = 'Pro N for Workstations'
        'professionaleducation' = 'Pro Education'; 'professionaleducationn' = 'Pro Education N'
        'education' = 'Education'; 'educationn' = 'Education N'; 'enterprise' = 'Enterprise'; 'enterprisen' = 'Enterprise N'
        'enterprises' = 'Enterprise LTSC'; 'enterprisesn' = 'Enterprise N LTSC'; 'iotenterprise' = 'IoT Enterprise'; 'iotenterprises' = 'IoT Enterprise LTSC'
    }
    $v = $map[$k.ToLowerInvariant()]
    if ($v) { return [string]$v }
    return $k
}
function Fmt-Day {
    param($d)
    if ($null -eq $d -or -not $d) { return '' }
    try { return ([datetime]$d).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) } catch { return '' }
}
# Windows writes an NVIDIA driver as 32.0.15.8180; the number NVIDIA's page and installer show is 581.80 (the last digit of the third
# part and the whole fourth part, with a point after the third digit)
function Info-NvDriver {
    param([string]$Win)
    $p = @(([string]$Win).Trim() -split '\.')
    if ($p.Count -ne 4) { return [string]$Win }
    $a = [string]$p[2]; $b = [string]$p[3]
    if (-not $a -or $b.Length -lt 3) { return [string]$Win }
    $t = $a.Substring($a.Length - 1) + $b
    if ($t.Length -lt 5) { return [string]$Win }
    return ($t.Substring(0, $t.Length - 2) + '.' + $t.Substring($t.Length - 2))
}

# ----------------------------------------------------------- building cards ----
function Info-Card {
    param([string]$Key, [string]$Title, [string]$Sub = '', $Lines = @(), [string]$Note = '', [string]$Chip = '', [string]$ChipKey = 'Sub', [int]$Span = 1)
    return @{ Kind = 'info'; Key = $Key; Id = $Key; Cat = ''; Title = $Title; Sub = $Sub; Lines = @($Lines); Note = $Note; NoteLines = @(); Chip = $Chip; ChipKey = $ChipKey
              Span = $Span; Top = 0; X = 0; W = 0; Y = 0; H = 0; Idx = 0 }
}
function Info-Line {
    param([string]$L, [string]$V, [string]$K = 'Text', $Bar = $null)
    return @{ L = $L; V = $V; K = $K; Bar = $Bar }
}
function Info-Reading { return (Info-Line 'Status' 'Reading your PC...' 'Dim') }

# what the background reader has so far
function Info-Data {
    $d = @{ Static = $null; Live = $null; Clock = $null; Sec = $null }
    $s = $script:SysShared
    if ($s) { $d.Static = $s.Static; $d.Live = $s.Live; $d.Clock = $s.Clock; $d.Sec = $s.Sec }
    return $d
}
# a temperature as a line: green is not used, only a warning when it is hot
function Info-TempLine {
    param([string]$Label, $T, [string]$Missing)
    if ($null -eq $T) { return (Info-Line $Label $Missing 'Dim') }
    $k = 'Text'
    if ([double]$T -ge 90) { $k = 'Bad' } elseif ([double]$T -ge 80) { $k = 'Warn' }
    return (Info-Line $Label ((Fmt-N $T 0) + ' ' + $script:Deg + 'C') $k)
}
function Info-UsageKey {
    param($Pct)
    if ($null -eq $Pct) { return 'Text' }
    if ([double]$Pct -ge 95) { return 'Bad' }
    if ([double]$Pct -ge 85) { return 'Warn' }
    return 'Text'
}

$script:NeedSensors = 'needs HWiNFO or LibreHardwareMonitor'

# ----------------------------------------------------------- the timer lines of the Windows card (read only) ----
# The speed the performance counter has when Windows uses the ACPI power management timer (3.579545 MHz); no other clock runs at it
$script:AcpiPmHz = 3579545
# The speed of the HPET as most boards give it (14.31818 MHz). Some chipsets use a faster one, so this is only used as one more hint.
$script:HpetHz = 14318180
$script:BcdOrder = @('useplatformclock', 'useplatformtick', 'disabledynamictick', 'tscsyncpolicy')

# A boot option of "bcdedit /enum": $true when it is set to Yes, $false when it is not in the entry or is No, $null when it could not be read
# or its value is not a Yes / No spelling (another language, or tscsyncpolicy's own words)
function Info-BcdOn {
    param($Bcd, [string]$Name)
    if (-not $Bcd -or -not $Bcd.Read) { return $null }
    $v = $Bcd.Opts[$Name]
    if ($null -eq $v) { return $false }
    $t = ([string]$v).Trim().ToLowerInvariant()
    if ($t -match '^(yes|true|on|1)$') { return $true }
    if ($t -match '^(no|false|off|0)$') { return $false }
    return $null
}

# Which clock sits behind QueryPerformanceCounter, worked out from how long one read of it takes (the PC is only measured, nothing is changed).
#   Speed  'fast' (under 120 ns: the CPU's own counter, the TSC), 'mid' (120 to 400 ns: through the kernel, most likely the TSC), 'slow' (400 ns
#          and more: a platform timer, the HPET or the ACPI timer), '' (not measured)
#   Which  'tsc', 'maybe-tsc', 'hpet', 'acpi', 'platform' (one of the two platform timers, not known which), '' (not known)
# The ACPI timer is named only when the counter runs at its own speed (3.579545 MHz), and the HPET only when Windows is told to use the
# platform clock on a PC that has an enabled HPET, or the counter runs at the HPET's usual speed. A guess is never made beyond that.
function Info-ClockSource {
    param($c)
    $r = @{ Speed = ''; Which = ''; CostNs = $null }
    if (-not $c) { return $r }
    $hz = $null; if ($null -ne $c.Hz) { $hz = [double]$c.Hz }
    $cost = $null; if ($null -ne $c.CostNs) { $cost = [double]$c.CostNs }
    $r.CostNs = $cost
    if ($null -ne $cost) {
        if ($cost -lt 120) { $r.Speed = 'fast' } elseif ($cost -lt 400) { $r.Speed = 'mid' } else { $r.Speed = 'slow' }
    }
    if ($null -ne $hz -and [Math]::Abs($hz - $script:AcpiPmHz) -le ($script:AcpiPmHz * 0.005)) { $r.Which = 'acpi'; return $r }
    if ($r.Speed -eq 'fast') { $r.Which = 'tsc' }
    elseif ($r.Speed -eq 'mid') { $r.Which = 'maybe-tsc' }
    elseif ($r.Speed -eq 'slow') {
        $h = $c.Hpet
        $hpetOk = ($h -and $h.Read -and $h.Present -and -not $h.Disabled)
        $forced = (Info-BcdOn $c.Bcd 'useplatformclock')
        if ($hpetOk -and $forced -eq $true) { $r.Which = 'hpet' }
        elseif ($null -ne $hz -and [Math]::Abs($hz - $script:HpetHz) -le ($script:HpetHz * 0.005)) { $r.Which = 'hpet' }
        else { $r.Which = 'platform' }
    }
    return $r
}

function Info-TimerLine {
    param($lv)
    if (-not $lv) { return (Info-Line 'Timer resolution' 'Reading...' 'Dim') }
    $t = $lv.Timer
    if (-not $t) { return (Info-Line 'Timer resolution' 'not available' 'Dim') }
    $v = (Fmt-N $t.CurrentMs 3) + ' ms   (default ' + (Fmt-N $t.CoarsestMs 3) + ', finest ' + (Fmt-N $t.FinestMs 3) + ')'
    return (Info-Line 'Timer resolution' $v 'Text')
}
function Info-HpetLine {
    param($c, $src)
    if (-not $c) { return (Info-Line 'HPET' 'Reading...' 'Dim') }
    $h = $c.Hpet
    if (-not $h -or -not $h.Read) { return (Info-Line 'HPET' 'could not be read' 'Dim') }
    if (-not $h.Present) { return (Info-Line 'HPET' 'Not found   (off in the BIOS, or none)' 'Text') }
    if ($h.Disabled) { return (Info-Line 'HPET' 'Switched off in Device Manager' 'Text') }
    $w = [string]$src.Which
    if ($w -eq 'hpet') { return (Info-Line 'HPET' 'Enabled, used as the clock' 'Text') }
    if ($w -eq 'tsc' -or $w -eq 'maybe-tsc' -or $w -eq 'acpi') { return (Info-Line 'HPET' 'Enabled, not used as the clock' 'Text') }
    return (Info-Line 'HPET' 'Enabled' 'Text')
}
function Info-TscLine {
    param($c, $src)
    if (-not $c) { return (Info-Line 'TSC' 'Reading...' 'Dim') }
    $w = [string]$src.Which
    $ns = ''; if ($null -ne $src.CostNs) { $ns = '   (' + (Fmt-N $src.CostNs 0) + ' ns per read)' }
    if ($w -eq 'tsc') { return (Info-Line 'TSC' ('Used as the clock' + $ns) 'Text') }
    if ($w -eq 'maybe-tsc') { return (Info-Line 'TSC' ('Probably used as the clock' + $ns) 'Text') }
    if ($w -eq 'acpi') { return (Info-Line 'TSC' 'Not used as the clock' 'Text') }
    if ($w -eq 'hpet' -or $w -eq 'platform') { return (Info-Line 'TSC' ('Not used as the clock' + $ns) 'Text') }
    return (Info-Line 'TSC' 'not measured' 'Dim')
}
function Info-AcpiLine {
    param($c, $src)
    if (-not $c) { return (Info-Line 'ACPI timer' 'Reading...' 'Dim') }
    $w = [string]$src.Which
    if ($w -eq 'acpi') { return (Info-Line 'ACPI timer' 'Used as the clock   (counter at 3.58 MHz)' 'Text') }
    if ($w -eq 'platform') { return (Info-Line 'ACPI timer' 'May be used as the clock' 'Text') }
    if ($w -eq 'tsc' -or $w -eq 'maybe-tsc' -or $w -eq 'hpet') { return (Info-Line 'ACPI timer' 'Not used as the clock' 'Text') }
    return (Info-Line 'ACPI timer' 'not measured' 'Dim')
}
# The timer options set in the boot entry ("bcdedit /enum {current}"), as the entry writes them, one line each (the first line carries the label);
# any of them overrides what Windows would choose. Returns the lines.
function Info-BootTimerLines {
    param($c)
    if (-not $c) { return @((Info-Line 'Boot timer options' 'Reading...' 'Dim')) }
    $b = $c.Bcd
    if (-not $b -or -not $b.Read) { return @((Info-Line 'Boot timer options' 'could not be read' 'Dim')) }
    $set = @()
    $warn = $false
    foreach ($n in $script:BcdOrder) {
        $v = $b.Opts[$n]
        if ($null -eq $v) { continue }
        $set += ($n + ' ' + [string]$v)
        $on = Info-BcdOn $b $n
        if ($n -eq 'tscsyncpolicy') { if (([string]$v).Trim() -notmatch '^default$') { $warn = $true } }
        elseif ($on -ne $false) { $warn = $true }
    }
    if ($set.Count -eq 0) { return @((Info-Line 'Boot timer options' 'none set   (Windows decides)' 'Text')) }
    $k = 'Text'; if ($warn) { $k = 'Warn' }
    $out = @()
    for ($i = 0; $i -lt $set.Count; $i++) {
        $lab = ''; if ($i -eq 0) { $lab = 'Boot timer options' }
        $out += , (Info-Line $lab ([string]$set[$i]) $k)
    }
    return $out
}
# ----------------------------------------------------------- VBS, memory integrity, IOMMU (read only) ----
# What Windows reports about VBS and memory integrity, and whether the firmware gives Windows an IOMMU. $sec is what the reader found:
# @{ Dg = @{ Read; Vbs; Configured; Running; Available }; Iommu = @{ Read; Kind } }, or $null before it has come.
function Info-VbsLine {
    param($sec)
    if (-not $sec) { return (Info-Line 'VBS' 'Reading...' 'Dim') }
    $g = $sec.Dg
    if (-not $g -or -not $g.Read) { return (Info-Line 'VBS' 'could not be read' 'Dim') }
    if ($null -eq $g.Vbs) { return (Info-Line 'VBS' 'not reported' 'Dim') }
    $v = [int]$g.Vbs
    if ($v -eq 2) { return (Info-Line 'VBS' 'Running' 'Text') }
    if ($v -eq 1) { return (Info-Line 'VBS' 'Turned on, but not running' 'Text') }
    if ($v -eq 0) { return (Info-Line 'VBS' 'Off' 'Text') }
    return (Info-Line 'VBS' 'not reported' 'Dim')
}
function Info-HvciLine {
    param($sec)
    if (-not $sec) { return (Info-Line 'HVCI' 'Reading...' 'Dim') }
    $g = $sec.Dg
    if (-not $g -or -not $g.Read) { return (Info-Line 'HVCI' 'could not be read' 'Dim') }
    if (@($g.Running) -contains 2) { return (Info-Line 'HVCI' 'On   (memory integrity)' 'Text') }
    if (@($g.Configured) -contains 2) { return (Info-Line 'HVCI' 'Turned on, but not running' 'Text') }
    return (Info-Line 'HVCI' 'Off   (memory integrity)' 'Text')
}
function Info-SecureBootLine {
    param($sec)
    if (-not $sec) { return (Info-Line 'Secure Boot' 'Reading...' 'Dim') }
    $s = $sec.Sb
    if (-not $s -or -not $s.Read) { return (Info-Line 'Secure Boot' 'could not be read' 'Dim') }
    switch ([string]$s.State) {
        'on'     { return (Info-Line 'Secure Boot' 'On' 'Good') }
        'off'    { return (Info-Line 'Secure Boot' 'Off   (it is switched on in the BIOS)' 'Warn') }
        'legacy' { return (Info-Line 'Secure Boot' 'Not available   (legacy BIOS boot, CSM)' 'Warn') }
    }
    return (Info-Line 'Secure Boot' 'could not be read' 'Dim')
}
# Fast startup on the Windows card: green when it is off (Shut down then starts Windows and its drivers fresh), plain when it is on
function Info-FastStartupLine {
    param($lv)
    if (-not $lv -or -not $lv.FastStart) { return (Info-Line 'Fast startup' 'Reading...' 'Dim') }
    $f = $lv.FastStart
    if (-not $f.Read) { return (Info-Line 'Fast startup' 'could not be read' 'Dim') }
    if ($f.On) {
        if ($f.Policy -and -not $f.Setting) { return (Info-Line 'Fast startup' 'On   (required by a policy)' 'Text') }
        return (Info-Line 'Fast startup' 'On' 'Text')
    }
    if (-not $f.Hib -and ($f.Setting -or $f.Policy)) { return (Info-Line 'Fast startup' 'Off   (hibernation is off, which it needs)' 'Good') }
    return (Info-Line 'Fast startup' 'Off' 'Good')
}
function Info-IommuLine {
    param($sec)
    if (-not $sec) { return (Info-Line 'IOMMU' 'Reading...' 'Dim') }
    $m = $sec.Iommu
    if (-not $m -or -not $m.Read) { return (Info-Line 'IOMMU' 'could not be read' 'Dim') }
    $kind = [string]$m.Kind
    if (-not $kind) { return (Info-Line 'IOMMU' 'Off in the BIOS, or not supported' 'Text') }
    $dma = ($sec.Dg -and $sec.Dg.Read -and (@($sec.Dg.Available) -contains 3))
    if ($dma) { return (Info-Line 'IOMMU' ('On   (' + $kind + ', DMA protection available)') 'Text') }
    return (Info-Line 'IOMMU' ('On   (' + $kind + ')') 'Text')
}

# ----------------------------------------------------------- the mouse card (read only) ----
# The three Windows settings that change how the pointer follows the mouse. A line is green when it is set the way that is best for games;
# otherwise it is in the plain colour (each only matters where Windows moves the pointer: the desktop and games without raw input).
function Info-MouseCard {
    param($d)
    $lv = $d.Live
    $lines = @()
    $good = 0; $read = 0
    $m = $null; if ($lv) { $m = $lv.Mouse }
    if (-not $lv) {
        $lines += , (Info-Line 'Pointer precision' 'Reading...' 'Dim')
        $lines += , (Info-Line 'Pointer speed' 'Reading...' 'Dim')
    } else {
        if ($m -and $m.Read -and $null -ne $m.Precision) {
            $read++
            if (-not $m.Precision) { $good++; $lines += , (Info-Line 'Pointer precision' 'Off   (no acceleration)' 'Good') }
            else { $lines += , (Info-Line 'Pointer precision' 'On   (acceleration)' 'Text') }
        } else { $lines += , (Info-Line 'Pointer precision' 'could not be read' 'Dim') }
        if ($m -and $m.Read -and $null -ne $m.Speed) {
            $read++
            if ([int]$m.Speed -eq 10) { $good++; $lines += , (Info-Line 'Pointer speed' '10 of 20   (1:1)' 'Good') }
            else { $lines += , (Info-Line 'Pointer speed' ([string][int]$m.Speed + ' of 20') 'Text') }
        } else { $lines += , (Info-Line 'Pointer speed' 'could not be read' 'Dim') }
    }
    $u = $null; if ($lv) { $u = $lv.UsbSs }
    if (-not $lv -or $null -eq $u) { $lines += , (Info-Line 'USB selective suspend' 'Reading...' 'Dim') }
    elseif (-not $u.Read) { $lines += , (Info-Line 'USB selective suspend' 'could not be read' 'Dim') }
    else {
        $read++
        if ([int]$u.Ac -eq 0) { $good++; $lines += , (Info-Line 'USB selective suspend' 'Off   (power plan in use)' 'Good') }
        else { $lines += , (Info-Line 'USB selective suspend' 'On   (power plan in use)' 'Text') }
    }
    $lines[0] = Info-Help $lines[0] 'mprec'
    $lines[1] = Info-Help $lines[1] 'mspeed'
    $lines[2] = Info-Help $lines[2] 'usbss'
    $sub = ''
    if ($read -eq 3 -and $good -eq 3) { $sub = 'Set for gaming' } elseif ($read -gt 0) { $sub = ([string]$good + ' of 3 set for gaming') }
    return (Info-Card 'info:mouse' 'Mouse' $sub $lines)
}

# ----------------------------------------------------------- what a line means (shown when it is clicked) ----
# A line of a Home card can carry an explanation: Id (the same for every line of a group, such as the boot options), Help (what it is) and
# Def (what Windows has by default). A click on the line opens the explanation under it (under the last line of its group), a second click
# closes it. Which ones are open is kept by card and Id, so it stays open while the numbers refresh.
$script:InfoOpen = @{}
$script:InfoHelp = @{
    timer = @{ T = 'How often Windows'' clock ticks right now. A program (a game, a browser, a music or video app) can ask for a finer tick, and Windows ticks at the finest one asked for while that program runs. Since Windows 10 version 2004 a finer tick is only promised to the program that asked for it, and on Windows 11 a program whose window is minimized or hidden loses it. The number updates about every 2 seconds.'
               D = '15.625 ms (64 ticks a second) while no program asks for a finer one.' }
    hpet  = @{ T = 'The High Precision Event Timer, a timer on the motherboard. Windows can use it as the clock behind QueryPerformanceCounter, but reading it is far slower than reading the CPU''s own counter (the TSC), so a current PC uses the TSC instead. This line comes from Windows'' device list.'
               D = 'Windows takes the HPET as the BIOS gives it and does not use it as the clock, unless the boot option useplatformclock is set.' }
    tsc   = @{ T = 'The CPU''s own time stamp counter. On current CPUs it runs at a steady rate on every core, so Windows uses it behind QueryPerformanceCounter: one read takes some tens of nanoseconds. Windows does not say which clock it picked, so this page works it out from how long one read takes; a read that goes through a platform timer takes hundreds or thousands of nanoseconds.'
               D = 'Windows picks the TSC by itself when the CPU''s counter can be trusted, which is the case on a current PC. Nothing has to be set.' }
    acpi  = @{ T = 'The ACPI power management timer, an old 3.58 MHz timer on the motherboard. Windows only falls back to it, or to the HPET, when the TSC cannot be used. When it is the clock, QueryPerformanceCounter runs at exactly its speed, which is how this line can tell.'
               D = 'Not used on a current PC: Windows uses the TSC.' }
    boot  = @{ T = 'Options in the boot entry that change how Windows picks its clock and its tick: useplatformclock (use the HPET or the ACPI timer as the clock), useplatformtick (take the tick from a platform timer), disabledynamictick (keep ticking while idle) and tscsyncpolicy (how the TSC is synced across cores). Microsoft lists them as debugging options. Headroom only lists the boot entry; it never changes it.'
               D = 'None of them is set: Windows decides. An option that is set shows in orange.' }
    vbs   = @{ T = 'Virtualization-based security: Windows uses the hypervisor to keep a small part of memory apart from the rest of Windows, and runs protections such as memory integrity (HVCI) and Credential Guard there. "Turned on, but not running" means it is set to start but is not running now, for example until the next restart or because virtualization is off in the BIOS.'
               D = 'On for a clean install of Windows 11 on a PC that meets the requirements, together with memory integrity; an upgrade does not turn it on. Since October 2026 Windows updates also turn it on for eligible PCs that are already set up, unless it was turned off.' }
    hvci  = @{ T = 'Memory integrity (hypervisor-protected code integrity), in Windows Security under Device security > Core isolation. VBS checks every driver before it may run in the kernel, and a driver that does not pass is blocked. Microsoft has said it can lower gaming performance on some PCs. Headroom can switch it on its Security Prompts page; this line only shows what Windows reports.'
               D = 'On for a clean install of Windows 11 on hardware that meets the requirements (Intel 8th generation or AMD Zen 2 or newer, 8 GB of memory, an SSD, compatible drivers, virtualization on in the BIOS); an upgrade does not turn it on. Since October 2026 Windows updates also turn it on for eligible PCs that are already set up, unless it was turned off.' }
    sboot = @{ T = 'Secure Boot, a feature of the UEFI firmware: the PC only starts a boot loader and early drivers that are signed with keys the firmware trusts, so nothing can slip in before Windows. Some anti-cheats refuse to run without it: Riot Vanguard on Windows 11 (VAN 9003), Battlefield 6 and Call of Duty: Black Ops 7. It is switched on or off in the BIOS / UEFI setup, not in Windows, and a PC that starts in legacy BIOS mode (CSM) cannot use it. This line shows what the firmware reported to Windows at the last start (HKLM\SYSTEM\CurrentControlSet\Control\SecureBoot\State).'
               D = 'Not a Windows setting: it is set in the BIOS. PCs sold with Windows 11 have it on; a self-built PC can have it off until it is switched on in the BIOS.' }
    fstart = @{ T = 'Fast startup (Control Panel > Power Options > Choose what the power buttons do). When it is on, Shut down does not end Windows completely: it signs you out, saves the Windows kernel and the drivers to the hibernation file, and the next start resumes them. Restart always does a full start. With it on, drivers do not start fresh after Shut down, which is why many gaming guides turn it off, and "Running for" keeps counting across Shut down. It needs hibernation. The setting Fast Startup and hibernation on the Power page turns both off.'
               D = 'On, as long as hibernation is on (it is on most PCs).' }
    iommu = @{ T = 'The IOMMU (AMD-Vi on AMD, VT-d on Intel) lets Windows control which memory a device may reach. Windows uses it for Kernel DMA Protection, and Riot Vanguard needs it on. The firmware tells Windows about it in an ACPI table (IVRS on AMD, DMAR on Intel), and this line looks for that table: without one Windows has no IOMMU to use, which usually means it is off in the BIOS. "DMA protection available" is what Windows reports when it can use the IOMMU to protect memory.'
               D = 'Not a Windows setting: it is set in the BIOS (AMD: IOMMU or AMD-Vi; Intel: VT-d). When it is on, Windows turns on Kernel DMA Protection by itself on PCs that support it.' }
    mprec = @{ T = 'Enhance pointer precision, in the mouse settings of Windows (Additional mouse settings > Pointer Options). When it is on, the pointer goes further the faster you move the mouse, so the same hand movement does not always cover the same distance. Games that read the mouse directly (raw input, as most current shooters do) are not affected; the desktop and games that use the Windows pointer are. Headroom''s Mouse acceleration setting on the Gaming page turns it off. Green: off.'
               D = 'On.' }
    mspeed = @{ T = 'The pointer speed, the slider in the mouse settings of Windows. 10 of 20, the middle notch, moves the pointer one pixel for each count the mouse sends; other values scale the movement up or down. Like pointer precision it only matters on the desktop and in games that use the Windows pointer: set your sensitivity in the game and the DPI in the mouse''s own software. Green: 10.'
               D = '10 of 20, the middle notch.' }
    usbss = @{ T = 'USB selective suspend, a setting of the power plan in use (here: while plugged in). When it is on, Windows can put a USB device that is idle into a low-power state. A mouse that is being moved is not suspended, so this mostly matters for devices that are slow to wake after a pause. Headroom''s USB power saving setting and its Ultimate Performance plan turn it off. Green: off.'
               D = 'On, in the power plans that come with Windows.' }
}
# Give a line its explanation (by Id) and return it
function Info-Help {
    param($l, [string]$Id)
    $h = $script:InfoHelp[$Id]
    if (-not $l -or -not $h) { return $l }
    $l.Id = $Id
    $l.Help = [string]$h.T
    $l.Def = [string]$h.D
    return $l
}

function Info-OsCard {
    param($d)
    $o = $null; if ($d.Static) { $o = $d.Static.Os }
    if (-not $o) { return (Info-Card 'info:os' 'Windows' '' @((Info-Reading))) }
    $lv = $d.Live
    $sub = [string]$o.Name
    if ($o.Display) { $sub += ' ' + [string]$o.Display }
    $up = $null
    if ($lv -and $null -ne $lv.Uptime) { $up = [int]$lv.Uptime }
    elseif ($o.Boot) { try { $up = [int]((Get-Date) - [datetime]$o.Boot).TotalSeconds } catch { } }
    $lines = @()
    $build = [string]$o.Full; if (-not $build) { $build = '-' }
    $lines += , (Info-Line 'Version' $(if ($o.Display) { [string]$o.Display } else { '-' }))
    $lines += , (Info-Line 'OS build' $build)
    $lines += , (Info-Line 'Edition' $(if ($o.Edition) { Fmt-Edition ([string]$o.Edition) } else { '-' }))
    if ($o.Arch) { $lines += , (Info-Line 'Architecture' ([string]$o.Arch)) }
    $day = Fmt-Day $o.Installed
    if ($day) { $lines += , (Info-Line 'Installed' $day) }
    if ($null -ne $up) { $lines += , (Info-Line 'Running for' (Fmt-Span $up)) }
    $lines += , (Info-Help (Info-FastStartupLine $lv) 'fstart')
    if ($lv -and $null -ne $lv.Procs) { $lines += , (Info-Line 'Processes' (Fmt-N $lv.Procs 0)) } else { $lines += , (Info-Line 'Processes' 'Reading...' 'Dim') }
    if ($lv -and $null -ne $lv.Threads) { $lines += , (Info-Line 'Threads' (Fmt-N $lv.Threads 0)) }
    return (Info-Card 'info:os' 'Windows' $sub $lines)
}

# The timer and the clocks (read only): a card of its own under the Windows card. Its name says the two things most people look for, the tick
# in use and the clock behind QueryPerformanceCounter ("1.000 ms tick, TSC clock").
function Info-TimerCard {
    param($d)
    $lv = $d.Live
    $clock = $d.Clock
    $src = Info-ClockSource $clock
    $lines = @()
    $lines += , (Info-Help (Info-TimerLine $lv) 'timer')
    $lines += , (Info-Help (Info-HpetLine $clock $src) 'hpet')
    $lines += , (Info-Help (Info-TscLine $clock $src) 'tsc')
    $lines += , (Info-Help (Info-AcpiLine $clock $src) 'acpi')
    foreach ($bl in @(Info-BootTimerLines $clock)) { $lines += , (Info-Help $bl 'boot') }
    $parts = @()
    if ($lv -and $lv.Timer) { $parts += ((Fmt-N $lv.Timer.CurrentMs 3) + ' ms tick') }
    $w = [string]$src.Which
    if ($w -eq 'tsc') { $parts += 'TSC clock' } elseif ($w -eq 'maybe-tsc') { $parts += 'probably TSC clock' } elseif ($w -eq 'hpet') { $parts += 'HPET clock' }
    elseif ($w -eq 'acpi') { $parts += 'ACPI timer clock' } elseif ($w -eq 'platform') { $parts += 'platform timer clock' }
    return (Info-Card 'info:timer' 'Timer and clock' ($parts -join ', ') $lines)
}

# Secure Boot, VBS, memory integrity and the IOMMU (read only): the card beside the timer card. Its name sums them up ("Memory integrity on,
# IOMMU on, Secure Boot on").
function Info-SecCard {
    param($d)
    $sec = $d.Sec
    $lines = @()
    $lines += , (Info-Help (Info-SecureBootLine $sec) 'sboot')
    $lines += , (Info-Help (Info-VbsLine $sec) 'vbs')
    $lines += , (Info-Help (Info-HvciLine $sec) 'hvci')
    $lines += , (Info-Help (Info-IommuLine $sec) 'iommu')
    $parts = @()
    if ($sec -and $sec.Dg -and $sec.Dg.Read) {
        $g = $sec.Dg
        if (@($g.Running) -contains 2) { $parts += 'Memory integrity on' }
        elseif (@($g.Configured) -contains 2) { $parts += 'Memory integrity not running' }
        elseif ($null -ne $g.Vbs -and [int]$g.Vbs -eq 2) { $parts += 'VBS on, memory integrity off' }
        elseif ($null -ne $g.Vbs -and [int]$g.Vbs -eq 0) { $parts += 'VBS off' }
    }
    if ($sec -and $sec.Iommu -and $sec.Iommu.Read) { if ([string]$sec.Iommu.Kind) { $parts += 'IOMMU on' } else { $parts += 'IOMMU off' } }
    if ($sec -and $sec.Sb -and $sec.Sb.Read) { if ([string]$sec.Sb.State -eq 'on') { $parts += 'Secure Boot on' } else { $parts += 'Secure Boot off' } }
    return (Info-Card 'info:sec' 'Security' ($parts -join ', ') $lines)
}

function Info-CpuCard {
    param($d)
    $c = $null; if ($d.Static) { $c = $d.Static.Cpu }
    if (-not $c) { return (Info-Card 'info:cpu' 'Processor' '' @((Info-Reading))) }
    $lv = $d.Live
    $sn = $null; if ($lv) { $sn = $lv.Sensors }
    $lines = @()
    if ($lv -and $null -ne $lv.CpuUsage) { $lines += , (Info-Line 'Usage' ((Fmt-N $lv.CpuUsage 0) + ' %') (Info-UsageKey $lv.CpuUsage) $lv.CpuUsage) }
    else { $lines += , (Info-Line 'Usage' 'Reading...' 'Dim') }
    if ($lv -and $null -ne $lv.CpuClockMHz) {
        $t = (Fmt-N $lv.CpuClockMHz 0) + ' MHz'
        if ($c.BaseMHz -gt 0) { $t += '   (base ' + (Fmt-N $c.BaseMHz 0) + ')' }
        $lines += , (Info-Line 'Clock speed' $t)
    } else { $lines += , (Info-Line 'Clock speed' 'Reading...' 'Dim') }
    $temp = $null; $pow = $null; if ($sn) { $temp = $sn.CpuTemp; $pow = $sn.CpuPower }
    $lines += , (Info-TempLine 'Temperature' $temp $script:NeedSensors)
    if ($null -ne $pow) { $lines += , (Info-Line 'Power' ((Fmt-N $pow 1) + ' W')) } else { $lines += , (Info-Line 'Power' $script:NeedSensors 'Dim') }
    if ($c.Cores -gt 0) { $lines += , (Info-Line 'Cores' ('{0} cores, {1} threads' -f $c.Cores, $c.Threads)) }
    if ($c.L3MB -gt 0) { $lines += , (Info-Line 'L3 cache' ((Fmt-N $c.L3MB 0) + ' MB')) }
    $chip = ''; $ck = 'Sub'
    if ($sn -and $sn.Source) { $chip = 'Sensors: ' + [string]$sn.Source; $ck = 'Good' }
    return (Info-Card 'info:cpu' 'Processor' ([string]$c.Name) $lines '' $chip $ck)
}

# "Gen 5 x16": the PCIe link between the card and the CPU as it is right now. A card slows its link down when it is idle, so a lower
# generation than the top one is normal at rest and is only shown; a link that is narrower than the card supports (x8 for an x16 card) is
# flagged, and a link at the top is green.
function Info-PcieLine {
    param($lv, $x, [bool]$nv)
    if (-not $lv) { return (Info-Line 'PCIe link' 'Reading...' 'Dim') }
    if (-not $nv) { return (Info-Line 'PCIe link' 'needs nvidia-smi' 'Dim') }
    if ($null -eq $x.PcieGen -or $null -eq $x.PcieWidth) { return (Info-Line 'PCIe link' 'not reported by this driver' 'Dim') }
    $g = [int]$x.PcieGen; $w = [int]$x.PcieWidth
    $gm = $g; if ($null -ne $x.PcieGenMax) { $gm = [Math]::Max($g, [int]$x.PcieGenMax) }
    $wm = $w; if ($null -ne $x.PcieWidthMax) { $wm = [Math]::Max($w, [int]$x.PcieWidthMax) }
    $t = ('Gen {0} x{1}' -f $g, $w)
    if ($w -lt $wm) { return (Info-Line 'PCIe link' ($t + ('   (the card supports Gen {0} x{1})' -f $gm, $wm)) 'Warn') }
    if ($g -lt $gm) {
        $idle = ''; if ($null -ne $x.Usage -and [double]$x.Usage -lt 10) { $idle = '; slows down when idle' }
        return (Info-Line 'PCIe link' ($t + ('   (up to Gen {0}{1})' -f $gm, $idle)) 'Text')
    }
    return (Info-Line 'PCIe link' $t 'Good')
}
# Resizable BAR: on when the window into video memory (BAR1) is bigger than the classic 256 MB
function Info-BarLine {
    param($g, [bool]$nv)
    $mb = $g.Bar1MB
    if ($null -ne $mb -and [double]$mb -gt 0) {
        $m = [double]$mb
        $size = (Fmt-N $m 0) + ' MB'
        if ($m -ge 1024 -and (($m % 1024) -eq 0)) { $size = (Fmt-N ($m / 1024.0) 0) + ' GB' }
        if ($m -gt 256) { return (Info-Line 'Resizable BAR' ('On   (BAR1 ' + $size + ')') 'Good') }
        return (Info-Line 'Resizable BAR' ('Off   (BAR1 ' + $size + ')') 'Warn')
    }
    if ([string]$g.Vendor -ne 'NVIDIA') { return (Info-Line 'Resizable BAR' 'not read for this card' 'Dim') }
    if ($nv) { return (Info-Line 'Resizable BAR' 'not reported by nvidia-smi' 'Dim') }
    return (Info-Line 'Resizable BAR' 'needs nvidia-smi' 'Dim')
}
function Info-GpuCard {
    param($d)
    $g = $null; if ($d.Static) { $g = $d.Static.Gpu }
    if (-not $g) { return (Info-Card 'info:gpu' 'Graphics card' '' @((Info-Reading))) }
    $lv = $d.Live
    $x = $null; if ($lv) { $x = $lv.Gpu }
    $name = [string]$g.Name
    if (-not $name -and $x -and $x.Name) { $name = [string]$x.Name }
    if (-not $name) { $name = 'No graphics card found' }
    $lines = @()
    if ($x -and $null -ne $x.Usage) { $lines += , (Info-Line 'Usage' ((Fmt-N $x.Usage 0) + ' %') (Info-UsageKey $x.Usage) $x.Usage) }
    elseif ($lv) { $lines += , (Info-Line 'Usage' 'not available' 'Dim') }
    else { $lines += , (Info-Line 'Usage' 'Reading...' 'Dim') }
    $nv = ($x -and $x.Source -eq 'nvidia-smi')
    $missing = 'needs nvidia-smi'
    if ($nv -and $null -ne $x.ClockMHz) {
        $t = (Fmt-N $x.ClockMHz 0) + ' MHz'
        if ($null -ne $x.ClockMaxMHz) { $t += '   (up to ' + (Fmt-N $x.ClockMaxMHz 0) + ')' }
        $lines += , (Info-Line 'Clock speed' $t)
    } else { $lines += , (Info-Line 'Clock speed' $missing 'Dim') }
    $tmp = $null; if ($nv) { $tmp = $x.Temp }
    $lines += , (Info-TempLine 'Temperature' $tmp $missing)
    if ($nv -and $null -ne $x.Power) {
        $t = (Fmt-N $x.Power 1) + ' W'
        if ($null -ne $x.PowerLimit) { $t += '   (limit ' + (Fmt-N $x.PowerLimit 0) + ' W)' }
        $lines += , (Info-Line 'Power' $t)
    } else { $lines += , (Info-Line 'Power' $missing 'Dim') }
    if ($x -and $null -ne $x.MemUsedMB) {
        $tot = $null
        if ($null -ne $x.MemTotalMB) { $tot = [double]$x.MemTotalMB } elseif ($g.VramMB -gt 0) { $tot = [double]$g.VramMB }
        if ($tot -and $tot -gt 0) {
            $pct = [Math]::Round(100.0 * [double]$x.MemUsedMB / $tot, 0)
            $lines += , (Info-Line 'Video memory' ((Fmt-N $x.MemUsedMB 0) + ' of ' + (Fmt-N $tot 0) + ' MB') 'Text' $pct)
        } else { $lines += , (Info-Line 'Video memory' ((Fmt-N $x.MemUsedMB 0) + ' MB in use')) }
    } elseif ($g.VramMB -gt 0) { $lines += , (Info-Line 'Video memory' ((Fmt-N $g.VramMB 0) + ' MB')) }
    $lines += , (Info-BarLine $g $nv)
    $lines += , (Info-PcieLine $lv $x $nv)
    if ($nv -and $null -ne $x.Fan) { $lines += , (Info-Line 'Fan' ((Fmt-N $x.Fan 0) + ' %')) }
    $drv = ''
    if ($nv -and $x.Driver) { $drv = [string]$x.Driver }
    elseif ($g.Driver) { $drv = [string]$g.Driver; if ($g.Vendor -eq 'NVIDIA') { $drv = Info-NvDriver $drv } }
    if ($drv) { $lines += , (Info-Line 'Driver' $drv) }
    $chip = ''; $ck = 'Sub'
    if ($nv) { $chip = 'Sensors: nvidia-smi'; $ck = 'Good' }
    elseif ($lv) { $chip = 'Windows counters only'; $ck = 'Dim' }
    return (Info-Card 'info:gpu' 'Graphics card' $name $lines '' $chip $ck)
}

# the memory timings as the usual four numbers, "30-36-36-96", or '' when HWiNFO has not given them
function Info-Timings {
    param($sn)
    if (-not $sn) { return '' }
    foreach ($k in 'Tcas', 'Trcd', 'Trp', 'Tras') { if ($null -eq $sn[$k]) { return '' } }
    return ('{0}-{1}-{2}-{3}' -f [int]$sn.Tcas, [int]$sn.Trcd, [int]$sn.Trp, [int]$sn.Tras)
}
# The memory controller clock against the memory clock: Mode is "1:1" when they are equal (what a Ryzen runs best at), "1:2" when the
# controller runs at half the memory clock (usual above about DDR5-6400), "Other" for anything else. Each clock in MHz; the memory clock
# is half the transfer rate (DDR5-6000 = 3000 MHz). A few percent of difference is measuring noise. $null when either clock is missing or
# impossible. (This is window code: the functions of the background reader are not available here.)
function Info-MemMode {
    param($Mclk, $Uclk)
    if ($null -eq $Mclk -or $null -eq $Uclk) { return $null }
    $m = [double]$Mclk; $u = [double]$Uclk
    if ([double]::IsNaN($m) -or [double]::IsNaN($u) -or $m -lt 100 -or $m -gt 6000 -or $u -lt 100 -or $u -gt 6000) { return $null }
    $ratio = $u / $m
    $mode = 'Other'
    if ([Math]::Abs($ratio - 1.0) -le 0.03) { $mode = '1:1' }
    elseif ([Math]::Abs($ratio - 0.5) -le 0.03) { $mode = '1:2' }
    return @{ Mode = $mode; Ratio = [Math]::Round($ratio, 3) }
}
# The memory controller clock set against the memory clock: the "Memory controller" line, e.g. "3,000 MHz   1:1 with the memory clock".
# The memory clock comes from HWiNFO, else from the speed Windows reports (DDR: half the transfer rate).
function Info-CtrlLine {
    param($sn, $r, $lv)
    $u = $null; if ($sn -and $null -ne $sn.RamUclk) { $u = [double]$sn.RamUclk }
    if ($null -eq $u) {
        if (-not $lv) { return (Info-Line 'Memory controller' 'Reading...' 'Dim') }
        if ($lv.Hwi -and [string]$lv.HwiVia) { return (Info-Line 'Memory controller' 'no controller clock row in HWiNFO' 'Dim') }
        return (Info-Line 'Memory controller' 'needs HWiNFO running' 'Dim')
    }
    $m = $null
    if ($sn -and $null -ne $sn.RamMclk) { $m = [double]$sn.RamMclk }
    elseif ($r -and [double]$r.SpeedMT -gt 0) { $m = [double]$r.SpeedMT / 2.0 }
    $t = (Fmt-N $u 0) + ' MHz'
    $mode = Info-MemMode $m $u
    if (-not $mode) { return (Info-Line 'Memory controller' $t 'Text') }
    if ($mode.Mode -eq '1:1') { return (Info-Line 'Memory controller' ($t + '   1:1 with the memory clock') 'Good') }
    if ($mode.Mode -eq '1:2') { return (Info-Line 'Memory controller' ($t + '   1:2 (half the memory clock)') 'Sub') }
    return (Info-Line 'Memory controller' ($t + '   not 1:1 or 1:2 (memory clock ' + (Fmt-N $m 0) + ' MHz)') 'Warn')
}
# The "DRAM voltage" line
function Info-VoltLine {
    param($sn, $lv)
    if ($sn -and $null -ne $sn.Vdimm) {
        $t = (Fmt-N $sn.Vdimm 2) + ' V'
        if ($sn.VdimmIo) { $t += '   (the CPU''s memory I/O reading)' }
        return (Info-Line 'DRAM voltage' $t 'Text')
    }
    if (-not $lv) { return (Info-Line 'DRAM voltage' 'Reading...' 'Dim') }
    if ($lv.Hwi -and [string]$lv.HwiVia) { return (Info-Line 'DRAM voltage' 'no DRAM voltage row in HWiNFO' 'Dim') }
    return (Info-Line 'DRAM voltage' 'needs HWiNFO running' 'Dim')
}
function Info-RamCard {
    param($d)
    $r = $null; if ($d.Static) { $r = $d.Static.Ram }
    if (-not $r) { return (Info-Card 'info:ram' 'Memory' '' @((Info-Reading))) }
    $lv = $d.Live
    $sn = $null; if ($lv) { $sn = $lv.Sensors }
    $mods = @($r.Modules)
    $sub = (Fmt-N $r.TotalGB 0) + ' GB'
    if ($r.Type) { $sub += ' ' + [string]$r.Type }
    if ($mods.Count -gt 0) { $sub += ('   ({0} x {1} GB)' -f $mods.Count, (Fmt-N $mods[0].GB 0)) }
    $lines = @()
    if ($lv -and $null -ne $lv.RamUsedMB -and $null -ne $lv.RamTotalMB -and [double]$lv.RamTotalMB -gt 0) {
        $pct = [Math]::Round(100.0 * [double]$lv.RamUsedMB / [double]$lv.RamTotalMB, 0)
        $lines += , (Info-Line 'In use' ((Fmt-Gb $lv.RamUsedMB) + ' of ' + (Fmt-Gb $lv.RamTotalMB)) (Info-UsageKey $pct) $pct)
    } else { $lines += , (Info-Line 'In use' 'Reading...' 'Dim') }
    if ($r.SpeedMT -gt 0) {
        $t = (Fmt-N $r.SpeedMT 0) + ' MT/s'
        if ($r.Type) { $t = [string]$r.Type + '-' + [string][int]$r.SpeedMT + '   (' + (Fmt-N $r.SpeedMT 0) + ' MT/s)' }
        $lines += , (Info-Line 'Speed' $t)
        if ($sn -and $null -ne $sn.RamMclk) { $lines += , (Info-Line 'Memory clock' ((Fmt-N $sn.RamMclk 0) + ' MHz')) }
        if ($r.RatedMT -gt 0 -and $r.RatedMT -ne $r.SpeedMT) { $lines += , (Info-Line 'Module rating' ((Fmt-N $r.RatedMT 0) + ' MT/s')) }
    } else { $lines += , (Info-Line 'Speed' 'not reported by Windows' 'Dim') }
    $tm = Info-Timings $sn
    if ($tm) {
        $t = $tm
        if ($null -ne $sn.Trc -and $null -ne $sn.Trfc) { $t += ('   tRC {0}  tRFC {1}' -f [int]$sn.Trc, [int]$sn.Trfc) }
        if ($sn.Cr) { $t += '   ' + [string]$sn.Cr }
        $lines += , (Info-Line 'Timings' $t)
    } else { $lines += , (Info-Line 'Timings' 'needs HWiNFO running' 'Dim') }
    $lines += , (Info-CtrlLine $sn $r $lv)
    $lines += , (Info-VoltLine $sn $lv)
    $shown = 0
    foreach ($m in $mods) {
        if ($shown -ge 4) { break }
        $txt = (Fmt-N $m.GB 0) + ' GB'
        $who = (([string]$m.Maker + ' ' + [string]$m.Part).Trim())
        if ($who) { $txt += '   ' + $who }
        $slot = [string]$m.Slot; if (-not $slot) { $slot = 'Module' }
        $lines += , (Info-Line $slot $txt 'Sub')
        $shown++
    }
    $chip = ''; $ck = 'Sub'
    if ($tm) { $chip = 'Timings: HWiNFO'; $ck = 'Good' }
    return (Info-Card 'info:ram' 'Memory' $sub $lines '' $chip $ck)
}

# a drive size the way the makers write it (decimal): 2000398934016 -> "2.0 TB", 512110190592 -> "512 GB"
function Fmt-Drive {
    param($Bytes)
    if ($null -eq $Bytes -or [double]$Bytes -le 0) { return '' }
    $b = [double]$Bytes
    if ($b -ge 1e12) { return ((Fmt-N ($b / 1e12) 1) + ' TB') }
    return ((Fmt-N ($b / 1e9) 0) + ' GB')
}
# "NVMe SSD", "SATA HDD": the connection and the kind of drive, as far as Windows says
function Fmt-DriveKind {
    param([string]$Bus, [string]$Media)
    $k = @()
    if ($Bus -and $Bus -notmatch '^(Unknown|RAID|Virtual|Spaces|File Backed Virtual)$') { $k += $Bus }
    if ($Media -and $Media -notmatch '^(Unspecified|Unknown)$') { $k += $Media }
    return ($k -join ' ')
}
# "Gen 4 x4": the PCIe link of an NVMe drive as Windows reports it now. A link narrower than the drive supports is flagged; a lower
# generation than the drive supports is only shown (the slot or the CPU may allow no more); a link at the top is green.
function Info-DrivePcieLine {
    param($nums, $lk)
    if (-not $nums) { return (Info-Line 'PCIe link' 'Reading...' 'Dim') }
    if (-not $lk -or $null -eq $lk.Gen -or $null -eq $lk.Width) { return (Info-Line 'PCIe link' 'not reported for this drive' 'Dim') }
    $g = [int]$lk.Gen; $w = [int]$lk.Width
    $gm = $g; if ($null -ne $lk.GenMax) { $gm = [Math]::Max($g, [int]$lk.GenMax) }
    $wm = $w; if ($null -ne $lk.WidthMax) { $wm = [Math]::Max($w, [int]$lk.WidthMax) }
    $t = ('Gen {0} x{1}' -f $g, $w)
    if ($w -lt $wm) { return (Info-Line 'PCIe link' ($t + ('   (the drive supports Gen {0} x{1})' -f $gm, $wm)) 'Warn') }
    if ($g -lt $gm) { return (Info-Line 'PCIe link' ($t + ('   (the drive supports Gen {0}; the slot may allow less)' -f $gm)) 'Text') }
    return (Info-Line 'PCIe link' $t 'Good')
}
function Info-StorageCard {
    param($d)
    $st = $null; if ($d.Static) { $st = $d.Static.Storage }
    if (-not $d.Static) { return (Info-Card 'info:storage' 'Storage' '' @((Info-Reading)) '' '' 'Sub' 1) }
    $drives = @($st)
    if ($null -eq $st -or $drives.Count -eq 0) {
        return (Info-Card 'info:storage' 'Storage' '' @((Info-Line 'Drives' 'Windows did not list any here' 'Dim')) '' '' 'Sub' 1)
    }
    $lv = $d.Live
    $nums = $null; if ($lv) { $nums = $lv.Storage }
    $lines = @()
    $n = 0
    $worst = ''
    foreach ($x in $drives) {
        $n++
        if ($n -gt 4) { break }
        $t = ([string]$x.Name); if (-not $t) { $t = 'Drive ' + $n }
        $kind = Fmt-DriveKind ([string]$x.Bus) ([string]$x.Media)
        $sz = Fmt-Drive $x.Bytes
        $v = $t
        if ($sz) { $v += '   ' + $sz }
        if ($kind) { $v += '   ' + $kind }
        $lines += , (Info-Line ('Drive ' + $n) $v)
        $m = $null; if ($nums -and $nums.ContainsKey([string]$x.Id)) { $m = $nums[[string]$x.Id] }
        if ([string]$x.Bus -eq 'NVMe') { $lk = $null; if ($m) { $lk = $m.Link }; $lines += , (Info-DrivePcieLine $nums $lk) }
        $temp = $null; if ($m) { $temp = $m.Temp }
        if ($null -ne $temp -or $nums) { $lines += , (Info-TempLine 'Temperature' $temp 'not reported by this drive') }
        else { $lines += , (Info-Line 'Temperature' 'Reading...' 'Dim') }
        if ($m -and ($null -ne $m.Wear -or $null -ne $m.Hours)) {
            $w = @()
            $wk = 'Text'
            if ($null -ne $m.Wear) { $w += ((Fmt-N $m.Wear 0) + ' % of its life used'); if ([double]$m.Wear -ge 90) { $wk = 'Bad' } elseif ([double]$m.Wear -ge 70) { $wk = 'Warn' } }
            if ($null -ne $m.Hours) { $w += ((Fmt-N $m.Hours 0) + ' h powered on') }
            $lines += , (Info-Line 'Wear' ($w -join '   ') $wk)
        }
        $h = [string]$x.Health
        if ($h -and $h -ne 'Healthy') {
            $hk = 'Warn'; if ($h -match 'Unhealthy') { $hk = 'Bad' }
            $lines += , (Info-Line 'Health' $h $hk)
            if ($hk -eq 'Bad') { $worst = 'Bad' } elseif (-not $worst) { $worst = 'Warn' }
        }
    }
    if ($drives.Count -gt 4) { $lines += , (Info-Line 'More' (('and {0} more drive' -f ($drives.Count - 4)) + $(if ($drives.Count - 4 -gt 1) { 's' } else { '' })) 'Dim') }
    $chip = ''; $ck = 'Sub'
    if ($worst -eq 'Bad') { $chip = 'A drive is unhealthy'; $ck = 'Bad' }
    elseif ($worst -eq 'Warn') { $chip = 'Check a drive'; $ck = 'Warn' }
    else { $chip = 'All drives healthy'; $ck = 'Good' }
    $sub = '{0} drive{1}' -f $drives.Count, $(if ($drives.Count -eq 1) { '' } else { 's' })
    return (Info-Card 'info:storage' 'Storage' $sub $lines '' $chip $ck 1)
}

function Info-BoardCard {
    param($d)
    $b = $null; if ($d.Static) { $b = $d.Static.Board }
    if (-not $b) { return (Info-Card 'info:board' 'Motherboard' '' @((Info-Reading))) }
    # the title line is the model alone (the maker's full name is long and has its own line below)
    $sub = ([string]$b.Product).Trim()
    if (-not $sub) { $sub = ([string]$b.Maker).Trim() }
    if (-not $sub) { $sub = 'Not reported by the firmware' }
    $lines = @()
    if ($b.Maker) { $lines += , (Info-Line 'Maker' ([string]$b.Maker)) }
    if ($b.Version -and $b.Version -notmatch '^(Default string|To be filled|None|Not Applicable|x\.x)') { $lines += , (Info-Line 'Revision' ([string]$b.Version)) }
    $v = [string]$b.BiosVersion; if (-not $v) { $v = '-' }
    $lines += , (Info-Line 'BIOS version' $v)
    $day = Fmt-Day $b.BiosDate
    if ($day) { $lines += , (Info-Line 'BIOS date' $day) }
    if ($b.BiosVendor) { $lines += , (Info-Line 'BIOS maker' ([string]$b.BiosVendor)) }
    return (Info-Card 'info:board' 'Motherboard' $sub $lines)
}

# One card per screen. $compact = the short version for the Home page.
function Info-DisplayCards {
    param($d, [bool]$compact)
    $lv = $d.Live
    $disp = $null; if ($lv) { $disp = $lv.Displays }
    if (-not $disp) {
        $msg = 'Reading your screens...'
        if ($lv) { $msg = 'Not read yet' }
        return @((Info-Card 'info:disp' 'Display' '' @((Info-Line 'Status' $msg 'Dim'))))
    }
    if ($disp.Why -and -not @($disp.List).Count) {
        return @((Info-Card 'info:disp' 'Display' '' @() ('The screens could not be read: ' + [string]$disp.Why)))
    }
    $cards = @()
    $n = 0
    foreach ($s in @($disp.List)) {
        $n++
        $sm = $s.Summary
        $title = 'Display ' + $n
        if ($s.Primary) { $title += ' (main)' }
        $name = [string]$s.Name; if (-not $name) { $name = 'Screen ' + $n }
        $lines = @()
        $lines += , (Info-Line 'Resolution' ('{0} x {1}' -f $sm.W, $sm.H))
        $hz = [string]$sm.Hz + ' Hz'
        $chip = ''; $ck = 'Sub'
        $rk = 'Text'
        $atMax = ($sm.MaxHzHere -gt 0 -and $sm.Hz -ge $sm.MaxHzHere)
        if ($sm.MaxHzHere -gt 0 -and $sm.Hz -lt $sm.MaxHzHere) {
            $rk = 'Warn'; $chip = 'Below its top rate'; $ck = 'Warn'
            $hz += ('   (up to {0} Hz)' -f $sm.MaxHzHere)
        } elseif ($atMax) { $rk = 'Good'; $chip = 'At its top rate'; $ck = 'Good' }
        $lines += , (Info-Line 'Refresh rate' $hz $rk)
        if ($s.HzExact -and [Math]::Abs([double]$s.HzExact - [double]$sm.Hz) -ge 0.01) { $lines += , (Info-Line 'Exact rate' ('{0} Hz' -f (Fmt-N $s.HzExact 3))) }
        $hdr = 'unknown'; $hk = 'Dim'
        switch ([string]$s.Hdr) { 'on' { $hdr = 'On'; $hk = 'Good' } 'off' { $hdr = 'Off'; $hk = 'Text' } 'none' { $hdr = 'Not supported'; $hk = 'Dim' } }
        $lines += , (Info-Line 'HDR' $hdr $hk)
        if (-not $compact) {
            if ($sm.MaxHzHere -gt 0) { $lines += , (Info-Line 'Highest at this size' ([string]$sm.MaxHzHere + ' Hz')) }
            if ($sm.TopHz -gt 0) { $lines += , (Info-Line 'Highest it lists' ('{0} Hz at {1} x {2}' -f $sm.TopHz, $sm.TopW, $sm.TopH)) }
            $rates = @($sm.RatesHere)
            if ($rates.Count -gt 0) {
                $shown = @($rates | Select-Object -Last 8)
                $t = ($shown -join ', ') + ' Hz'
                if ($rates.Count -gt $shown.Count) { $t = '... ' + $t }
                $lines += , (Info-Line 'Rates at this size' $t)
            }
            if ($sm.Biggest) { $lines += , (Info-Line 'Biggest picture' ('{0} x {1}' -f $sm.Biggest.W, $sm.Biggest.H)) }
            $lines += , (Info-Line 'Modes listed' ([string]$sm.ModeCount))
        }
        $cards += , (Info-Card ('info:disp' + $n) $title $name $lines '' $chip $ck)
    }
    if ($cards.Count -eq 0) { $cards += , (Info-Card 'info:disp' 'Display' '' @() 'No screen was found.') }
    return $cards
}

function Info-SensorCard {
    param($d)
    $lv = $d.Live
    if (-not $lv) { return (Info-Card 'info:sensors' 'Sensors' '' @((Info-Reading)) '' '' 'Sub' 2) }
    $sn = $lv.Sensors
    $lines = @()
    $g = $lv.Gpu
    if ($g -and $g.Source -eq 'nvidia-smi') { $lines += , (Info-Line 'nvidia-smi' ('found: ' + [string]$lv.Smi) 'Good') }
    else { $lines += , (Info-Line 'nvidia-smi' 'not found (GPU temperature, power and clock need it)' 'Dim') }
    $hv = [string]$lv.HwiVia
    if ($lv.Hwi -and $hv) { $lines += , (Info-Line 'HWiNFO' ('running, readings from its ' + $hv) 'Good') }
    elseif ($lv.Hwi -and [string]$lv.HwiWhy -eq 'stale') { $lines += , (Info-Line 'HWiNFO' 'running, but its readings are frozen (its Sensors window is closed or paused)' 'Warn') }
    elseif ($lv.Hwi) { $lines += , (Info-Line 'HWiNFO' 'running, but not sharing its readings' 'Warn') }
    else { $lines += , (Info-Line 'HWiNFO' 'not running' 'Dim') }
    # which HWiNFO / LibreHardwareMonitor rows the CPU numbers were taken from, so they can be compared with that program
    if ($sn -and [string]$sn.CpuTempFrom) { $lines += , (Info-Line 'CPU temperature' ('from the row "' + [string]$sn.CpuTempFrom + '"') 'Sub') }
    if ($sn -and [string]$sn.CpuPowerFrom) { $lines += , (Info-Line 'CPU power' ('from the row "' + [string]$sn.CpuPowerFrom + '"') 'Sub') }
    if ($sn -and [string]$sn.UclkFrom) { $lines += , (Info-Line 'Memory controller' ('from the row "' + [string]$sn.UclkFrom + '"') 'Sub') }
    elseif ($hv) { $lines += , (Info-Line 'Memory controller' 'no row named "Memory Controller Clock" in HWiNFO' 'Dim') }
    if ($sn -and [string]$sn.VdimmFrom) { $lines += , (Info-Line 'DRAM voltage' ('from the row "' + [string]$sn.VdimmFrom + '"') 'Sub') }
    elseif ($hv) { $lines += , (Info-Line 'DRAM voltage' 'no row named DRAM, DIMM, VDIMM or CPU VDDIO in HWiNFO' 'Dim') }
    if ($lv.Lhm) { $lines += , (Info-Line 'LibreHardwareMonitor' 'running' 'Good') } else { $lines += , (Info-Line 'LibreHardwareMonitor' 'not running' 'Dim') }
    $missing = ($null -eq $sn -or ($null -eq $sn.CpuTemp -or $null -eq $sn.CpuPower -or -not (Info-Timings $sn)))
    $note = ''
    if ($missing) {
        $note = 'Windows itself does not report the CPU temperature, the CPU power or the memory timings: they sit behind a driver that only a hardware monitor loads, and this app installs none. '
        if ($lv.Hwi -and -not $hv) {
            if ([string]$lv.HwiWhy -eq 'denied') {
                $note += 'HWiNFO is running but Windows refused this app access to the readings it shares: start both with the same rights (both as administrator).'
            } elseif ([string]$lv.HwiWhy -eq 'stale') {
                $note += 'HWiNFO is running but has stopped updating the readings it shares, so they are not shown (they would be old numbers). Press "Start HWiNFO" at the top to restart it with its Sensors window running, or open HWiNFO''s Sensors window yourself and let it run (it can be minimised); a paused Sensors window freezes them.'
            } else {
                $note += 'HWiNFO is running but is not sharing its readings. Press "Start HWiNFO" at the top: it restarts HWiNFO with "Shared Memory Support" turned on and its Sensors window running (the free HWiNFO switches it off again after 12 hours, so press it again then). By hand: in HWiNFO open Settings and turn on "Shared Memory Support", and keep its Sensors window running (it can be minimised). The other way is to tick "Report value in Gadget" on the CPU temperature, CPU package power and memory timing rows.'
            }
        } elseif (-not $lv.Hwi) {
            $note += 'Press "Start HWiNFO" at the top: it starts HWiNFO (free) with its sensors on and "Shared Memory Support" turned on in its settings file. The graphics card (through nvidia-smi), the processor usage and clock, the memory speed and the drives are read without it.'
        } else {
            $note += 'HWiNFO is sharing its readings, but it has no row this app recognises for the missing numbers. The CPU rows are matched by their usual HWiNFO names, such as "CPU (Tctl/Tdie)" and "CPU Package Power".'
        }
    }
    return (Info-Card 'info:sensors' 'Sensors' '' $lines $note '' 'Sub' 2)
}

# The note on the Display page: there is no switch that forces a refresh rate
function Info-RateNote {
    param([int]$Span)
    $t = 'There is no Windows setting or registry switch that forces a refresh rate, so this app has none to offer. What Windows uses is the rate chosen under Settings > System > Display > Advanced display; it is kept after a restart. Check the cards: "At its top rate" means the screen is running the highest rate it lists for that picture size. ' +
         'A game can still ask for a lower rate. With an NVIDIA card, NVIDIA Control Panel > Manage 3D settings > Preferred refresh rate > Highest available stops that; NVIDIA keeps that option in its own driver profiles, not in the Windows registry, so this app does not change it. ' +
         'A lower rate than expected is usually the cable or port (use DisplayPort or the HDMI port the monitor says supports its top rate) or the monitor menu.'
    return (Info-Card 'info:ratenote' 'Keeping the full refresh rate' '' @() $t '' 'Sub' $Span)
}

# The cards of an info page, or the live cards on top of a settings page (Display)
function Get-PageCards {
    param([string]$cat)
    $list = @()
    if ($cat -eq $script:PageHome) {
        $d = Info-Data
        # two to a line: Windows and the motherboard, the timer and the security cards, the processor and the graphics card side by side,
        # then the memory and the screen
        $list += , (Info-OsCard $d)
        $list += , (Info-BoardCard $d)
        $list += , (Info-TimerCard $d)
        $list += , (Info-SecCard $d)
        $list += , (Info-CpuCard $d)
        $list += , (Info-GpuCard $d)
        $list += , (Info-RamCard $d)
        # the screens; with an even number of them the last one takes the whole width, so storage and the mouse always share a line
        $disps = @(Info-DisplayCards $d $true)
        if ($disps.Count -ge 2 -and ($disps.Count % 2) -eq 0) { $disps[$disps.Count - 1].Span = 2 }
        foreach ($c in $disps) { $list += , $c }
        $list += , (Info-StorageCard $d)
        $list += , (Info-MouseCard $d)
        $list += , (Info-SensorCard $d)
    } elseif ($cat -eq $script:DisplayCat) {
        $d = Info-Data
        $cards = @(Info-DisplayCards $d $false)
        foreach ($c in $cards) { $list += , $c }
        $span = 1; if (($cards.Count % 2) -eq 0) { $span = 2 }
        $list += , (Info-RateNote $span)
    }
    foreach ($c in $list) { $c.Cat = $cat }
    return $list
}

# ----------------------------------------------------------- size and painting ----
# Break a text into lines no wider than $Width pixels
function Info-Wrap {
    param([string]$Text, $Font, [int]$Width)
    $out = @()
    foreach ($para in ([string]$Text -split "`n")) {
        $line = ''
        foreach ($word in ($para -split ' ')) {
            if (-not $word) { continue }
            $try = $word
            if ($line) { $try = $line + ' ' + $word }
            if ($line -and (Ui-TextWidth $try $Font) -gt $Width) { $out += $line; $line = $word } else { $line = $try }
        }
        if ($line) { $out += $line }
    }
    return $out
}

# Work out the height of a card that is $w wide (the gap below it included) and wrap its note
function Info-Prepare {
    param($e, [int]$w)
    $M = $script:M
    $iw = $w - 2 * $M.Pad
    $top = Px 66                                          # the icon tile and the name beside it, then the lines
    $h = $top
    $lines = @($e.Lines)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        $l.Top = $h                                       # where the line starts, from the top of the card (for a click on it)
        if ($null -ne $l.Bar) { $h += Px 32 } else { $h += Px 22 }
        $l.HelpH = 0
        $l.HelpLines = @()
        $l.DefLines = @()
        $l.Open = $false
        if (-not $l.Id) { continue }
        $l.Open = [bool]$script:InfoOpen.ContainsKey([string]$e.Key + '|' + [string]$l.Id)
        # an open explanation goes under the last line of its group
        $last = ($i -eq ($lines.Count - 1) -or [string]$lines[$i + 1].Id -ne [string]$l.Id)
        if ($l.Open -and $last) {
            $tw = $iw - 2 * (Px 14)
            $l.HelpLines = @(Info-Wrap ([string]$l.Help) (Ui-Font 'cardDesc') $tw)
            $l.DefLines = @(Info-Wrap ('Windows default: ' + [string]$l.Def) (Ui-Font 'cardDesc') $tw)
            $l.HelpH = (Px 12) + (@($l.HelpLines).Count + @($l.DefLines).Count) * (Px 18) + (Px 6) + (Px 12)
            $h += $l.HelpH + (Px 6)
        }
    }
    $e.NoteLines = @()
    if ($e.Note) {
        $e.NoteLines = @(Info-Wrap ([string]$e.Note) (Ui-Font 'cardDesc') $iw)
        $h += (Px 8) + (@($e.NoteLines).Count * (Px 18))
    }
    $h += Px 16
    $e.Top = $top
    $e.W = $w
    $e.H = $h + $M.Gap
}

# The icon on a Home card: by what the card shows
function Info-IconKey {
    param($e)
    $k = [string]$e.Key
    if ($k -eq 'info:os') { return 'Windows' }
    if ($k -eq 'info:cpu') { return 'Processor' }
    if ($k -eq 'info:timer') { return 'Timer and clock' }
    if ($k -eq 'info:sec') { return 'Security' }
    if ($k -eq 'info:gpu') { return 'Graphics card' }
    if ($k -eq 'info:ram') { return 'Memory' }
    if ($k -eq 'info:storage') { return 'Storage' }
    if ($k -eq 'info:mouse') { return 'Mouse' }
    if ($k -eq 'info:board') { return 'Motherboard' }
    if ($k -eq 'info:sensors') { return 'Sensors' }
    if ($k.StartsWith('info:disp') -or $k -eq 'info:ratenote') { return 'Display' }
    return '_'
}

function Ui-PaintInfo {
    param($g, $e, [int]$y)
    $Th = $script:Th
    $M = $script:M
    $TF = $script:TF
    $x = [int]$e.X
    $cw = [int]$e.W
    $ch = $e.H - $M.Gap
    Ui-FillRound $g $Th.Card $x $y $cw $ch $M.Radius            # a flat card: a fill, no outline
    $ix = $x + $M.Pad
    $iw = $cw - 2 * $M.Pad
    $chipW = 0
    if ($e.Chip) {
        $font = Ui-Font 'smallb'
        $chipW = (Ui-Measure $g ([string]$e.Chip) $font) + (Px 22)
        $cx = $ix + $iw - $chipW
        $key = [string]$e.ChipKey
        Ui-FillRound $g $Th[(Ui-SoftKey $key)] $cx ($y + (Px 10)) $chipW (Px 22) (Px 6)
        Ui-Text $g ([string]$e.Chip) $font $Th[$key] $cx ($y + (Px 10)) $chipW (Px 22) $TF.C
    }
    # the icon tile, and the name beside it
    $tx0 = $ix + $M.IconD + $M.IconGap
    $tw = $iw - $M.IconD - $M.IconGap
    if ($chipW -gt 0) { $tw = $tw - $chipW - (Px 8) }
    Ui-FillRound $g $Th.AccentSoft $ix ($y + (Px 12)) $M.IconD $M.IconD (Px 12)
    $isz = Px 22
    Ui-PaintIcon $g (Info-IconKey $e) ($ix + [int](($M.IconD - $isz) / 2)) ($y + (Px 12) + [int](($M.IconD - $isz) / 2)) $isz $Th.Accent
    if ($e.Sub) {
        Ui-Text $g ([string]$e.Title).ToUpperInvariant() (Ui-Font 'cap') $Th.Dim $tx0 ($y + (Px 15)) $tw (Px 14) $TF.L
        Ui-Text $g ([string]$e.Sub) (Ui-Font 'cardName') $Th.Text $tx0 ($y + (Px 31)) ($cw - 2 * $M.Pad - $M.IconD - $M.IconGap) (Px 26) $TF.L
    } else {
        Ui-Text $g (Get-TitleCase ([string]$e.Title)) (Ui-Font 'cardName') $Th.Text $tx0 ($y + (Px 12)) $tw $M.IconD $TF.L
    }
    $ly = $y + [int]$e.Top
    $lw = [Math]::Min((Px 150), [int]($iw * 0.42))
    foreach ($l in @($e.Lines)) {
        $ck = [string]$l.K
        if (-not $ck) { $ck = 'Text' }
        $vw = $iw - $lw
        $lcol = $Th.Mute
        if ($l.Id) {
            # a line with an explanation: lit under the pointer, a small arrow at its right end (down: closed, up: open)
            $hotL = ($script:HotEntry -and [string]$script:HotEntry.Key -eq [string]$e.Key -and [string]$script:HotLine -eq [string]$l.Id)
            if ($hotL) { Ui-FillRound $g $Th.CardHot ($ix - (Px 8)) ($ly - (Px 1)) ($iw + (Px 16)) (Px 22) (Px 6) }
            if ($l.Open) { $lcol = $Th.Sub }
            $vw = $vw - (Px 18)
            if ($l.L) {
                $acol = $Th.Dim; if ($hotL -or $l.Open) { $acol = $Th.Accent }
                $ax = $ix + $iw - (Px 6)
                $ay = $ly + (Px 10)
                $d4 = Px 4; $d2 = Px 2
                if ($l.Open) { Ui-Line $g $acol 1.6 ($ax - $d4) ($ay + $d2) $ax ($ay - $d2); Ui-Line $g $acol 1.6 $ax ($ay - $d2) ($ax + $d4) ($ay + $d2) }
                else { Ui-Line $g $acol 1.6 ($ax - $d4) ($ay - $d2) $ax ($ay + $d2); Ui-Line $g $acol 1.6 $ax ($ay + $d2) ($ax + $d4) ($ay - $d2) }
            }
        }
        Ui-Text $g (Get-TitleCase ([string]$l.L)) (Ui-Font 'small') $lcol $ix $ly $lw (Px 20) $TF.L
        Ui-Text $g ([string]$l.V) (Ui-Font 'uib') $Th[$ck] ($ix + $lw) $ly $vw (Px 20) $TF.L
        if ($null -ne $l.Bar) {
            $by = $ly + (Px 23)
            $bh = Px 5
            Ui-FillRound $g $Th.Raised $ix $by $iw $bh 2
            $pct = [Math]::Max(0.0, [Math]::Min(100.0, [double]$l.Bar))
            if ($pct -gt 0) {
                $fw = [Math]::Max($bh, [int]($iw * $pct / 100.0))
                $bc = $Th.Accent
                if ($pct -ge 95) { $bc = $Th.Bad } elseif ($pct -ge 85) { $bc = $Th.Warn }
                Ui-FillRound $g $bc $ix $by $fw $bh 2
            }
            $ly += Px 32
        } else {
            $ly += Px 22
        }
        if ([int]$l.HelpH -gt 0) {
            # the explanation: a panel in the page colour under the line, what it is, then what Windows has by default
            $py = $ly + (Px 2)
            Ui-FillRound $g $Th.Bg $ix $py $iw ([int]$l.HelpH) (Px 10)
            $ty = $py + (Px 12)
            foreach ($hl in @($l.HelpLines)) { Ui-Text $g ([string]$hl) (Ui-Font 'cardDesc') $Th.Mute ($ix + (Px 14)) $ty ($iw - 2 * (Px 14)) (Px 18) $TF.L; $ty += Px 18 }
            $ty += Px 6
            foreach ($dl in @($l.DefLines)) { Ui-Text $g ([string]$dl) (Ui-Font 'cardDesc') $Th.Sub ($ix + (Px 14)) $ty ($iw - 2 * (Px 14)) (Px 18) $TF.L; $ty += Px 18 }
            $ly += [int]$l.HelpH + (Px 6)
        }
    }
    $ny = $ly + (Px 6)
    foreach ($nl in @($e.NoteLines)) {
        Ui-Text $g ([string]$nl) (Ui-Font 'cardDesc') $Th.Mute $ix $ny $iw (Px 18) $TF.L
        $ny += Px 18
    }
}

# ----------------------------------------------------------- the background reader ----
# The one place that starts a worker for the system information. $Kind = 'loop' (the live numbers, until the window closes).
# Tests replace this function.
function Start-SysJob {
    param([string]$Kind)
    $sh = $script:SysShared
    if (-not $sh) { throw 'the system reader has no shared state' }
    $rs = Open-WorkerRunspace
    $rs.SessionStateProxy.SetVariable('SysShared', $sh)
    $call = 'Invoke-SysLoop'
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($sysEngine.ToString() + "`r`n" + $call)
    $async = $ps.BeginInvoke()
    return @{ PS = $ps; RS = $rs; Async = $async; Kind = $Kind }
}

function Start-SysWorker {
    if ($script:SysWorker) { return }
    $script:SysShared = [hashtable]::Synchronized(@{ Stop = $false; Active = $false; Force = $false; Ver = 0; Static = $null; Live = $null; Clock = $null; Sec = $null })
    $script:SysSeen = -1
    $script:SysWorker = Start-SysJob 'loop'
}

# end the background reader without waiting for the call it is in the middle of
function Stop-SysWorker {
    $sh = $script:SysShared
    if ($sh) { $sh.Stop = $true }
    $j = $script:SysWorker
    if ($j) {
        try { [void]$j.PS.BeginStop($null, $null) } catch { }
        try { $j.RS.CloseAsync() } catch { }
    }
    $script:SysWorker = $null
}

# The page that is showing needs the live numbers
function Ui-OnPageShown {
    $sh = $script:SysShared
    if (-not $sh) { return }
    $text = ''
    if ($script:UI.find) { $text = ([string]$script:UI.find.Text).Trim() }
    $page = [string]$script:NavCat
    if ($text) { $page = '' }
    $live = ($page -eq $script:PageHome -or $page -eq $script:DisplayCat)
    if ([bool]$sh.Active -ne $live) {
        $sh.Active = $live
        if ($live) { $sh.Force = $true }
    }
}

# Called by the timer: when the reader has something new, redraw the cards that show it
function Ui-SysTick {
    $sh = $script:SysShared
    if (-not $sh) { return }
    $redo = $false
    if ([int]$sh.Ver -ne $script:SysSeen) { $script:SysSeen = [int]$sh.Ver; $redo = $true }
    if ($redo) { Ui-RefreshInfo }
}

# The line of a Home card at (rx, ry) inside the card that has an explanation, or $null (the line itself and its open explanation count)
function Info-HitLine {
    param($e, [int]$rx, [int]$ry)
    $M = $script:M
    if (-not $e -or $rx -lt ($M.Pad - (Px 8)) -or $rx -ge ([int]$e.W - $M.Pad + (Px 8))) { return $null }
    foreach ($l in @($e.Lines)) {
        if (-not $l.Id -or $null -eq $l.Top) { continue }
        $t = [int]$l.Top
        $b = $t + (Px 22)
        if ($null -ne $l.Bar) { $b = $t + (Px 32) }
        if ([int]$l.HelpH -gt 0) { $b += [int]$l.HelpH + (Px 6) }
        if ($ry -ge ($t - (Px 1)) -and $ry -lt $b) { return $l }
    }
    return $null
}
# Open or close the explanation of a line, and keep it in view when it opens
function Ui-ToggleInfoLine {
    param($e, [string]$Id)
    if (-not $e -or -not $Id) { return }
    $k = [string]$e.Key + '|' + $Id
    $opening = -not $script:InfoOpen.ContainsKey($k)
    if ($opening) { $script:InfoOpen[$k] = $true } else { $script:InfoOpen.Remove($k) }
    Ui-Layout
    $script:DList = $true
    if (-not $opening) { return }
    $card = @($script:View | Where-Object { [string]$_.Key -eq [string]$e.Key })[0]
    if (-not $card) { return }
    $ln = @(@($card.Lines) | Where-Object { [string]$_.Id -eq $Id -and [int]$_.HelpH -gt 0 })[0]
    if (-not $ln) { return }
    $bottom = [int]$card.Y + [int]$ln.Top + (Px 22) + [int]$ln.HelpH + (Px 12)
    $topY = [int]$card.Y + [int]$ln.Top
    if ($bottom -gt ($script:ScrollY + $script:ListH)) { Ui-ScrollTo ([Math]::Min($topY, $bottom - $script:ListH)) }
}

# Make the cards of the page that is showing again from the newest data
function Ui-RefreshInfo {
    $text = ''
    if ($script:UI.find) { $text = ([string]$script:UI.find.Text).Trim() }
    if ($text) { return }
    $page = [string]$script:NavCat
    $has = (Test-InfoPage $page) -or ($page -eq $script:DisplayCat -and -not $script:Filtering)
    if (-not $has) { return }
    foreach ($g in $script:Groups) {
        if ([string]$g.Cat -eq $page) { $g.Info = @(Get-PageCards $page) }
    }
    Ui-Layout
    $script:DList = $true
}

# ----------------------------------------------------------- the page button ----
# One button in the header that belongs to the page: "Display settings" on Display, "Start HWiNFO" on Home
function Ui-PageButtonText {
    param([string]$page)
    if ($page -eq $script:DisplayCat) { return 'Display settings' }
    if ($page -eq $script:PageHome) { return 'Start HWiNFO' }
    if ($page -eq $script:PowerCat) { return 'Compare Power Plans' }
    return ''
}
function Ui-DoPageButton {
    $page = [string]$script:NavCat
    if ($page -eq $script:DisplayCat) {
        try { Start-Process -FilePath 'ms-settings:display-advanced' } catch { Ui-Status ('Could not open Settings: ' + $_.Exception.Message) }
        return
    }
    if ($page -eq $script:PageHome) { Ui-StartHwinfo; return }
    if ($page -eq $script:PowerCat) { Ui-ShowPlanCmp }      # (it only reads the power plans)
}

# ----------------------------------------------------------- start HWiNFO ----
# HWiNFO is what gives this app the CPU temperature, the CPU power and the memory timings (Windows has no readings for them). It shares them
# only while "Shared Memory Support" is on AND its Sensors window is running. HWiNFO keeps its general options in a settings file next to the
# program, HWiNFO64.INI (HWiNFO32.INI for the 32-bit one), in a [Settings] section; the keys used here are the ones that file is known to hold:
#   SensorsSM = 1           Shared Memory Support on
#   SensorsOnly = 1         start with only the Sensors window (so the readings run without anybody opening it)
#   MinimalizeSensors = 1   keep that window minimised (HWiNFO spells it this way)
#   OpenSensors = 1         open the Sensors window when HWiNFO starts ("Show Sensors on Startup")
#   ShowWelcomeAndProgress = 0   do not show the Welcome screen: without this HWiNFO waits at it for a click on "Run" every time it starts
# HWiNFO reads the file when it starts, so a copy that is running has to be closed first. Only those five lines are touched, every other line
# stays as it was, and the first time a copy of the file as it was is kept next to it. The file is only edited when there is one to edit or the
# program is found; nothing is written anywhere else.
$script:HwiKeys = [ordered]@{ SensorsSM = '1'; SensorsOnly = '1'; MinimalizeSensors = '1'; OpenSensors = '1'; ShowWelcomeAndProgress = '0' }
$script:HwiKeyInfo = [ordered]@{ SensorsSM = 'Shared Memory Support on'; SensorsOnly = 'start with only the Sensors window'; MinimalizeSensors = 'keep that window minimised'; OpenSensors = 'open the Sensors window at start'; ShowWelcomeAndProgress = 'no Welcome screen, so nothing has to be clicked' }
$script:HwiBackupSuffix = '.before-Headroom'
$script:HwiBackupSuffixOld = '.before-FasterWin'     # the copy made by the builds from before the app was called Headroom: when it is there it is the copy
# where the copy of the settings file is kept (next to it): the old name when that copy exists, so that a second copy of a file that was
# already changed is never made, otherwise the new name
function Hwi-BackupPath {
    param([string]$Ini)
    $old = $Ini + $script:HwiBackupSuffixOld
    if (Test-Path -LiteralPath $old) { return $old }
    return ($Ini + $script:HwiBackupSuffix)
}
$script:HwiDownload = 'https://www.hwinfo.com/download/'

# where a HWiNFO program could be, best guess first: the copy that is running, then the places the installer and the usual ways of
# installing it leave a trace (the uninstall list, App Paths, the usual folders, shortcuts in the Start menu and on the desktop)
function Hwi-Candidates {
    $c = New-Object System.Collections.ArrayList
    $names = @('HWiNFO64.exe', 'HWiNFO32.exe')
    if (-not [Environment]::Is64BitOperatingSystem) { $names = @('HWiNFO32.exe', 'HWiNFO64.exe') }
    foreach ($pn in 'HWiNFO64', 'HWiNFO32') {
        try {
            foreach ($p in @([System.Diagnostics.Process]::GetProcessesByName($pn))) {
                try { if ($p.MainModule.FileName) { [void]$c.Add([string]$p.MainModule.FileName) } } catch { } finally { try { $p.Dispose() } catch { } }
            }
        } catch { }
    }
    foreach ($root in 'HKLM', 'HKCU') {
        foreach ($sub in 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall') {
            try {
                if ($root -eq 'HKLM') { $r = [Microsoft.Win32.Registry]::LocalMachine } else { $r = [Microsoft.Win32.Registry]::CurrentUser }
                $k = $r.OpenSubKey($sub)
                if (-not $k) { continue }
                try {
                    foreach ($n in @($k.GetSubKeyNames())) {
                        $s = $k.OpenSubKey($n)
                        if (-not $s) { continue }
                        try {
                            if (([string]$s.GetValue('DisplayName', '')) -notlike 'HWiNFO*') { continue }
                            $loc = ([string]$s.GetValue('InstallLocation', '')).Trim().Trim('"')
                            if ($loc) { foreach ($nm in $names) { [void]$c.Add((Join-Path $loc $nm)) } }
                            $ico = ([string]$s.GetValue('DisplayIcon', '')).Trim().Trim('"')
                            $ico = ($ico -replace ',\s*-?\d+$', '').Trim().Trim('"')
                            if ($ico) { [void]$c.Add($ico) }
                        } finally { $s.Close() }
                    }
                } finally { $k.Close() }
            } catch { }
        }
        foreach ($nm in $names) {
            try {
                if ($root -eq 'HKLM') { $r = [Microsoft.Win32.Registry]::LocalMachine } else { $r = [Microsoft.Win32.Registry]::CurrentUser }
                $k = $r.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\' + $nm)
                if ($k) { try { $v = ([string]$k.GetValue('', '')).Trim().Trim('"'); if ($v) { [void]$c.Add($v) } } finally { $k.Close() } }
            } catch { }
        }
    }
    $dirs = @()
    foreach ($e in 'ProgramFiles', 'ProgramFiles(x86)') {
        $b = [Environment]::GetEnvironmentVariable($e)
        if ($b) { $dirs += (Join-Path $b 'HWiNFO64'); $dirs += (Join-Path $b 'HWiNFO32'); $dirs += (Join-Path $b 'HWiNFO') }
    }
    $la = [Environment]::GetFolderPath('LocalApplicationData')
    if ($la) {
        $dirs += (Join-Path $la 'Programs\HWiNFO64'); $dirs += (Join-Path $la 'Programs\HWiNFO32')
        $dirs += (Join-Path $la 'Microsoft\WinGet\Links')
        try { foreach ($d in @(Get-ChildItem -LiteralPath (Join-Path $la 'Microsoft\WinGet\Packages') -Directory -Filter 'REALiX.HWiNFO*' -ErrorAction Stop)) { $dirs += $d.FullName } } catch { }
    }
    $up = [Environment]::GetEnvironmentVariable('USERPROFILE')
    if ($up) { $dirs += (Join-Path $up 'scoop\apps\hwinfo\current') }
    foreach ($d in $dirs) { foreach ($nm in $names) { [void]$c.Add((Join-Path $d $nm)) } }
    # shortcuts (the Start menu folders two levels down, and the desktops), read with Windows' own shortcut reader
    $lnks = @()
    foreach ($f in 'CommonPrograms', 'Programs') {
        try { $d = [Environment]::GetFolderPath($f); if ($d) { $lnks += @(Get-ChildItem -LiteralPath $d -Recurse -Depth 2 -Filter 'HWiNFO*.lnk' -ErrorAction Stop) } } catch { }
    }
    foreach ($f in 'Desktop', 'CommonDesktopDirectory') {
        try { $d = [Environment]::GetFolderPath($f); if ($d) { $lnks += @(Get-ChildItem -LiteralPath $d -Filter 'HWiNFO*.lnk' -ErrorAction Stop) } } catch { }
    }
    if ($lnks.Count -gt 0) {
        $sh = $null
        try {
            $sh = New-Object -ComObject WScript.Shell
            foreach ($l in $lnks) { try { $t = [string]$sh.CreateShortcut($l.FullName).TargetPath; if ($t) { [void]$c.Add($t) } } catch { } }
        } catch { } finally { if ($sh) { try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($sh) } catch { } } }
    }
    return @($c)
}

# The first candidate that is the 64-bit HWiNFO program (HWiNFO64.exe), or ''. On a 32-bit Windows (which has no 64-bit program) it is the 32-bit one.
function Hwi-FindExe {
    $want = 'HWiNFO32.exe'
    if ([Environment]::Is64BitOperatingSystem) { $want = 'HWiNFO64.exe' }
    foreach ($p in @(Hwi-Candidates)) {
        $s = [string]$p
        if (-not $s) { continue }
        try {
            if ((Split-Path -Leaf $s) -ne $want) { continue }
            if (Test-Path -LiteralPath $s -PathType Leaf) { return $s }
        } catch { }
    }
    return ''
}

function Hwi-IsRunning {
    foreach ($pn in 'HWiNFO64', 'HWiNFO32') {
        try {
            $l = @([System.Diagnostics.Process]::GetProcessesByName($pn))
            $n = $l.Count
            foreach ($p in $l) { try { $p.Dispose() } catch { } }
            if ($n -gt 0) { return $true }
        } catch { }
    }
    return $false
}

# Closes a running HWiNFO: politely first, and by force after a few seconds. $true when none is left.
function Hwi-Close {
    foreach ($pn in 'HWiNFO64', 'HWiNFO32') {
        $list = @()
        try { $list = @([System.Diagnostics.Process]::GetProcessesByName($pn)) } catch { }
        foreach ($p in $list) {
            try {
                try { [void]$p.CloseMainWindow() } catch { }
                if (-not $p.WaitForExit(3000)) { $p.Kill(); [void]$p.WaitForExit(3000) }
            } catch { } finally { try { $p.Dispose() } catch { } }
        }
    }
    Start-Sleep -Milliseconds 400
    return (-not (Hwi-IsRunning))
}

function Hwi-Launch {
    param([string]$Exe)
    Start-Process -FilePath $Exe -WorkingDirectory (Split-Path -Parent $Exe)
}

# The settings file that belongs to a program: HWiNFO64.exe -> HWiNFO64.INI in the same folder
function Hwi-IniPath {
    param([string]$Exe)
    return (Join-Path (Split-Path -Parent $Exe) (([System.IO.Path]::GetFileNameWithoutExtension($Exe)) + '.INI'))
}

# $Text with the keys of $Keys set in its [Settings] section. Every other line, and the file's own line endings, stay as they are; a key
# that is already right is left alone. Returns @{ Text; Changes } where Changes says what was different ('SensorsSM: 0 -> 1').
function Hwi-IniMerge {
    param([string]$Text, $Keys)
    $nl = "`r`n"
    if ($Text.IndexOf("`r`n", [System.StringComparison]::Ordinal) -lt 0 -and $Text.IndexOf("`n", [System.StringComparison]::Ordinal) -ge 0) { $nl = "`n" }
    $lines = New-Object System.Collections.ArrayList
    if ($Text.Length -gt 0) {
        foreach ($l in ($Text -split "\r?\n")) { [void]$lines.Add([string]$l) }
        if ($Text.EndsWith("`n", [System.StringComparison]::Ordinal) -and $lines.Count -gt 0 -and [string]$lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }
    }
    $changes = @()
    $hdr = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ([string]$lines[$i] -match '^\s*\[Settings\]\s*$') { $hdr = $i; break } }
    if ($hdr -lt 0) {
        if ($lines.Count -gt 0 -and ([string]$lines[$lines.Count - 1]).Trim() -ne '') { [void]$lines.Add('') }
        [void]$lines.Add('[Settings]')
        foreach ($k in $Keys.Keys) { [void]$lines.Add($k + '=' + [string]$Keys[$k]); $changes += ($k + ': (not set) -> ' + [string]$Keys[$k]) }
    } else {
        foreach ($k in $Keys.Keys) {
            $want = [string]$Keys[$k]
            $end = $lines.Count
            for ($i = $hdr + 1; $i -lt $lines.Count; $i++) { if ([string]$lines[$i] -match '^\s*\[') { $end = $i; break } }
            $found = $false
            $re = '^\s*' + [regex]::Escape($k) + '\s*=\s*(.*?)\s*$'
            for ($i = $hdr + 1; $i -lt $end; $i++) {
                $m = [regex]::Match([string]$lines[$i], $re, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                if (-not $m.Success) { continue }
                $found = $true
                if ([string]$m.Groups[1].Value -ne $want) {
                    $changes += ($k + ': ' + [string]$m.Groups[1].Value + ' -> ' + $want)
                    $lines[$i] = $k + '=' + $want
                }
            }
            if (-not $found) {
                $pos = $end
                while ($pos -gt ($hdr + 1) -and ([string]$lines[$pos - 1]).Trim() -eq '') { $pos-- }
                $lines.Insert($pos, ($k + '=' + $want))
                $changes += ($k + ': (not set) -> ' + $want)
            }
        }
    }
    $out = (@($lines) -join $nl) + $nl
    if ($changes.Count -eq 0) { $out = $Text }
    return @{ Text = $out; Changes = @($changes) }
}

# The settings file as text with the encoding it had (plain text read as Latin-1, which turns every byte into one character and back, so
# lines this app does not touch keep their bytes whatever the PC's code page; or UTF-8 / UTF-16 when it starts with a byte-order mark), so it
# is written back the same way. $null when it cannot be read.
function Hwi-IniRead {
    param([string]$Path)
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $enc = [System.Text.Encoding]::GetEncoding(28591)
        $skip = 0
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $enc = New-Object System.Text.UTF8Encoding($true); $skip = 3 }
        elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { $enc = New-Object System.Text.UnicodeEncoding($false, $true); $skip = 2 }
        elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) { return $null }
        return @{ Text = $enc.GetString($bytes, $skip, $bytes.Length - $skip); Enc = $enc }
    } catch { return $null }
}

# What would be written for this program: @{ Ini; Existed; Text; Enc; Changes; Error }. Nothing is written here.
function Hwi-Plan {
    param([string]$Exe)
    $ini = Hwi-IniPath $Exe
    $plan = @{ Ini = $ini; Existed = $false; Text = ''; Enc = [System.Text.Encoding]::GetEncoding(28591); Changes = @(); Error = '' }
    $txt = ''
    if (Test-Path -LiteralPath $ini -PathType Leaf) {
        $plan.Existed = $true
        $r = Hwi-IniRead $ini
        if (-not $r) { $plan.Error = 'the settings file could not be read (or is in a form this app does not edit)'; return $plan }
        $txt = [string]$r.Text
        $plan.Enc = $r.Enc
    }
    $m = Hwi-IniMerge $txt $script:HwiKeys
    $plan.Text = [string]$m.Text
    $plan.Changes = @($m.Changes)
    return $plan
}

# Writes a plan: a copy of the file as it was (once), then the file. Returns '' or the reason it failed.
function Hwi-Write {
    param($Plan)
    if (@($Plan.Changes).Count -eq 0) { return '' }
    try {
        $bak = Hwi-BackupPath ([string]$Plan.Ini)
        if ($Plan.Existed -and -not (Test-Path -LiteralPath $bak)) { Copy-Item -LiteralPath $Plan.Ini -Destination $bak -ErrorAction Stop }
        $enc = $Plan.Enc
        $bytes = @($enc.GetPreamble()) + @($enc.GetBytes([string]$Plan.Text))
        [System.IO.File]::WriteAllBytes([string]$Plan.Ini, [byte[]]$bytes)
        return ''
    } catch { return [string]$_.Exception.Message }
}

function Hwi-PlanText {
    param($Plan)
    $t = "These options are kept in HWiNFO's settings file:`r`n  " + [string]$Plan.Ini + "`r`n"
    foreach ($c in @($Plan.Changes)) {
        $k = ([string]$c -split ':')[0]
        $note = ''
        if ($script:HwiKeyInfo.Contains($k)) { $note = '   (' + [string]$script:HwiKeyInfo[$k] + ')' }
        $t += '    ' + $c + $note + "`r`n"
    }
    if ($Plan.Existed) { $t += 'A copy of the file as it is now is kept next to it as ' + (Split-Path -Leaf (Hwi-BackupPath ([string]$Plan.Ini))) + ". No other line is touched.`r`n" }
    else { $t += "The file does not exist yet, so it is created with only these lines.`r`n" }
    return $t
}

# What "Start HWiNFO" would do, worked out without changing anything and without asking anything. Returns @{ Code; Text; Exe; Running; Plan; Edits }:
#   notfound   the 64-bit program was not found            busy      HWiNFO runs and this app has not read its first values yet
#   shared     HWiNFO already runs and shares its readings  planerror the settings file cannot be edited
#   ready      go ahead (Running = a copy has to be closed first, Edits = the settings file needs changes)
function Hwi-Prepare {
    $sh = $script:SysShared
    $lv = $null
    if ($sh) { $lv = $sh.Live }
    $r = @{ Code = ''; Text = ''; Exe = ''; Running = $false; Plan = $null; Edits = $false }
    $exe = Hwi-FindExe
    if (-not $exe) { $r.Code = 'notfound'; $r.Text = 'HWiNFO was not found on this PC.'; return $r }
    $r.Exe = $exe
    $running = Hwi-IsRunning
    $r.Running = $running
    if ($running -and -not $lv) { $r.Code = 'busy'; $r.Text = 'Still reading your PC: press the button again in a moment.'; return $r }
    if ($running -and [string]$lv.HwiVia) { $r.Code = 'shared'; $r.Text = 'HWiNFO is already running and sharing its readings with this app.'; return $r }
    $plan = Hwi-Plan $exe
    if ($plan.Error) { $r.Code = 'planerror'; $r.Text = ('HWiNFO was not started: ' + [string]$plan.Error + '.'); return $r }
    $r.Plan = $plan
    $r.Edits = (@($plan.Changes).Count -gt 0)
    $r.Code = 'ready'
    return $r
}

# Does what Hwi-Prepare found ('ready'): closes a running copy, writes the settings lines, starts HWiNFO. Returns @{ Code; Text } with Code
# closefail | launchfail | started | restarted | startednote (started, but the settings file could not be changed: Text says so).
function Hwi-Execute {
    param($Prep)
    $sh = $script:SysShared
    $exe = [string]$Prep.Exe
    $plan = $Prep.Plan
    $edits = [bool]$Prep.Edits
    $closed = $false
    $err = ''
    if ($Prep.Running) {
        if (-not (Hwi-Close)) { return @{ Code = 'closefail'; Text = 'HWiNFO did not close, so nothing was changed. Close it from its tray icon and press the button again.' } }
        $closed = $true
        # HWiNFO saves its settings file again when it closes (window positions, anything changed in this session), so the lines are
        # worked out again from the file as it is NOW. The plan made before the close would put the old text back and lose what it just saved.
        $plan = Hwi-Plan $exe
        if ($plan.Error) { $err = [string]$plan.Error; $edits = $false } else { $edits = (@($plan.Changes).Count -gt 0) }
    }
    if ($edits) { $err = Hwi-Write $plan }
    try {
        Hwi-Launch $exe
    } catch {
        return @{ Code = 'launchfail'; Text = ('HWiNFO could not be started: ' + $_.Exception.Message) }
    }
    if ($sh) { $sh.Force = $true }
    if ($err) { return @{ Code = 'startednote'; Text = ('HWiNFO started, but its settings file could not be changed (' + $err + '). Turn on "Shared Memory Support" in its Settings by hand.') } }
    if ($closed) { return @{ Code = 'restarted'; Text = 'HWiNFO restarted with Shared Memory Support on. Its readings should show here in a few seconds.' } }
    return @{ Code = 'started'; Text = 'HWiNFO started with Shared Memory Support on. Its readings should show here in a few seconds.' }
}

# The "Start HWiNFO" button on Home
function Ui-StartHwinfo {
    $prep = Hwi-Prepare
    if ($prep.Code -eq 'notfound') {
        Ui-Status ([string]$prep.Text)
        $q = "HWiNFO (the 64-bit program, HWiNFO64.exe) was not found on this PC.`r`n`r`nHWiNFO (free) is the program that gives this app the CPU temperature, the CPU power and the memory timings. Install it, then press this button again.`r`n`r`nOpen its download page (" + $script:HwiDownload + ') in your browser?'
        if (Ui-Ask $q 'HWiNFO not found') {
            try { Start-Process -FilePath $script:HwiDownload } catch { Ui-Status ('Could not open the browser: ' + $_.Exception.Message) }
        }
        return
    }
    if ($prep.Code -ne 'ready') { Ui-Status ([string]$prep.Text); return }
    $running = [bool]$prep.Running
    $edits = [bool]$prep.Edits
    if ($running -or $edits) {
        if ($running) {
            $q = "HWiNFO is running, but it is not sharing its readings with this app.`r`n`r`nHWiNFO reads its settings file when it starts, so it has to be closed and started again.`r`n`r`n"
        } else {
            $q = "Start HWiNFO so that this app can show the CPU temperature, the CPU power and the memory timings?`r`n`r`n"
        }
        if ($edits) { $q += (Hwi-PlanText $prep.Plan) + "`r`n" } else { $q += "Its options are already set the way this needs.`r`n`r`n" }
        $q += 'The free HWiNFO switches Shared Memory Support off again after about 12 hours: press this button again then.'
        if ($running) { $q += "`r`n`r`nClose HWiNFO now and start it again?" }
        $title = 'Start HWiNFO'
        if ($running) { $title = 'Restart HWiNFO' }
        if (-not (Ui-Ask $q $title $running)) { return }
    }
    if ($running) {
        Ui-Status 'Closing HWiNFO...'
        try { $script:UI.status.Refresh() } catch { }       # show it now: closing can keep the window busy for a few seconds
    }
    $res = Hwi-Execute $prep
    Ui-Status ([string]$res.Text)
}

# =============================================================================
# THE WELCOME SCREEN: shown every time the window opens, on top of everything else.
#   Page 1 ("begin"):  the name, one line, a Begin button.
#   Page 2 ("hwinfo"): Start HWiNFO (the 64-bit program) with its sensor sharing switched on, or Skip. Whatever happens is said right
#                      there, and Continue opens the app.
# The first check of the PC keeps running underneath, so the app is ready when the screen goes away.
# It is one plain control that paints itself (like the side menu) with three buttons on it; the move from page 1 to page 2 is a short
# slide and fade (a quick timer that only runs during the move).
# =============================================================================
# Page = begin | hwinfo.   Sub (page 2) = idle | working | notfound | needclose | ok | shared | warn | error.   Kind = '' | good | warn | bad
$script:Welcome = @{ Page = 'begin'; From = ''; Sub = 'idle'; Text = ''; Kind = ''; Prep = $null; Anim = 1.0; T0 = 0; Done = $false }
$script:WelcomeActs = @{ P = ''; S = ''; T = '' }
$script:WelcomeMoveMs = 380

# $a mixed with $b: $t = 0 is $a, 1 is $b
function Blend-Color {
    param($a, $b, [double]$t)
    if ($t -lt 0) { $t = 0 } elseif ($t -gt 1) { $t = 1 }
    $r = [int][Math]::Round($a.R + ($b.R - $a.R) * $t)
    $g = [int][Math]::Round($a.G + ($b.G - $a.G) * $t)
    $bl = [int][Math]::Round($a.B + ($b.B - $a.B) * $t)
    return (Rgb $r $g $bl)
}

# Where things go on a page of the given size: LogoX/Y/S, then the Y of each line, then the width of a text block
function Get-WelcomeLayout {
    param([string]$page, [int]$W, [int]$H)
    $L = @{}
    $L.BlockW = [Math]::Min((Px 580), ($W - (Px 80)))
    $L.BlockX = [int](($W - $L.BlockW) / 2)
    if ($page -eq 'begin') {
        $s = Px 92
        $block = $s + (Px 28) + (Px 52) + (Px 8) + (Px 30) + (Px 50) + (Px 56)
        $top = [int](($H - $block) / 2) - (Px 14)
        if ($top -lt (Px 16)) { $top = Px 16 }
        $L.LogoS = $s; $L.LogoY = $top
        $y = $top + $s + (Px 28)
        $L.TitleY = $y
        $L.SubY = $y + (Px 60)
        $L.BtnY = $y + (Px 60) + (Px 30) + (Px 50)
        $L.CapY = 0; $L.BodyY = 0; $L.StatusY = 0
    } else {
        $s = Px 52
        $block = $s + (Px 24) + (Px 18) + (Px 6) + (Px 52) + (Px 12) + (Px 96) + (Px 26) + (Px 56) + (Px 22) + (Px 60)
        $top = [int](($H - $block) / 2) - (Px 8)
        if ($top -lt (Px 16)) { $top = Px 16 }
        $L.LogoS = $s; $L.LogoY = $top
        $y = $top + $s + (Px 24)
        $L.CapY = $y
        $L.TitleY = $y + (Px 24)
        $L.BodyY = $L.TitleY + (Px 64)
        $L.BtnY = $L.BodyY + (Px 96) + (Px 26)
        $L.StatusY = $L.BtnY + (Px 56) + (Px 22)
        $L.SubY = 0
    }
    $L.LogoX = [int](($W - $L.LogoS) / 2)
    return $L
}

# ----------------------------------------------------------- the text and what the buttons do ----------
$script:WelcomeBody = 'Headroom reads your CPU temperature, power and memory timings from HWiNFO, because Windows does not provide them. ' +
    'Press Start HWiNFO and Headroom turns on sensor sharing in HWiNFO''s settings file, then starts the 64-bit HWiNFO for you.'
$script:WelcomeTagline = 'Give your games room to run.'

# The buttons for the page and state shown now: @{ P = @(text, action); S = ...; T = ... } (only the ones that are there)
function Get-WelcomeButtons {
    $w = $script:Welcome
    if ($w.Page -eq 'begin') { return @{ P = @('Begin', 'begin') } }
    switch ([string]$w.Sub) {
        'working'   { return @{} }
        'notfound'  { return @{ P = @('Download HWiNFO', 'download'); S = @('Try again', 'start'); T = @('Continue without it', 'finish') } }
        'needclose' { return @{ P = @('Restart HWiNFO', 'restart'); S = @('Skip for now', 'finish') } }
        'ok'        { return @{ P = @('Continue', 'finish') } }
        'shared'    { return @{ P = @('Continue', 'finish') } }
        'warn'      { return @{ P = @('Continue', 'finish') } }
        'error'     { return @{ P = @('Try again', 'start'); S = @('Skip for now', 'finish') } }
    }
    return @{ P = @('Start HWiNFO', 'start'); S = @('Skip for now', 'finish') }
}

# Put the buttons where the shown page wants them, centred in a row
function Ui-WelcomeLayout {
    $ui = $script:UI
    $ov = $ui.welcome
    if (-not $ov) { return }
    $st = $script:Welcome
    $W = [int]$ov.Width
    $H = [int]$ov.Height
    $L = Get-WelcomeLayout ([string]$st.Page) $W $H
    $moving = ([double]$st.Anim -lt 1.0)
    $set = Get-WelcomeButtons
    $btns = @()
    $acts = @{ P = ''; S = ''; T = '' }
    foreach ($k in 'P', 'S', 'T') {
        $b = $ui[('wb' + $k)]
        if (-not $b) { continue }
        if ($set.ContainsKey($k) -and -not $moving) {
            $b.Text = [string]$set[$k][0]
            $b.Width = [Math]::Max((Px 160), ((Ui-TextWidth ([string]$set[$k][0]) (Ui-Font 'bigbtn')) + (Px 64)))     # as wide as its text needs, so a plain button's words sit evenly in the row
            $acts[$k] = [string]$set[$k][1]
            $btns += $b
            if (-not [bool]$b.Visible) { $b.Visible = $true }
        } else {
            if ([bool]$b.Visible) { $b.Visible = $false }
        }
    }
    $script:WelcomeActs = $acts
    $gap = Px 14
    $total = 0
    foreach ($b in $btns) { $total += [int]$b.Width }
    if ($btns.Count -gt 1) { $total += $gap * ($btns.Count - 1) }
    $x = [int](($W - $total) / 2)
    foreach ($b in $btns) {
        $b.Top = [int]$L.BtnY
        $b.Left = $x
        $x += [int]$b.Width + $gap
    }
    $ov.Invalidate()
}

# ----------------------------------------------------------- painting ----------
# One page of text, faded towards the background by $alpha (1 = fully shown) and moved $dy pixels
function Ui-PaintWelcomePage {
    param($g, [string]$page, [double]$alpha, [int]$dy, [int]$W, [int]$H)
    if ($alpha -lt 0.03) { return }
    $Th = $script:Th
    $TF = $script:TF
    $bg = $Th.Side
    $L = Get-WelcomeLayout $page $W $H
    $x = $L.BlockX
    $bw = $L.BlockW
    if ($page -eq 'begin') {
        Ui-Text $g 'Headroom' (Ui-Font 'hero') (Blend-Color $bg $Th.Text $alpha) 0 ($L.TitleY + $dy) $W (Px 52) $TF.C
        Ui-Text $g $script:WelcomeTagline (Ui-Font 'heroSub') (Blend-Color $bg $Th.Sub $alpha) $x ($L.SubY + $dy) $bw (Px 30) $TF.C
        return
    }
    $st = $script:Welcome
    Ui-Text $g 'LIVE SENSORS' (Ui-Font 'stepcap') (Blend-Color $bg $Th.Accent $alpha) 0 ($L.CapY + $dy) $W (Px 18) $TF.C
    Ui-Text $g 'Start HWiNFO' (Ui-Font 'hero') (Blend-Color $bg $Th.Text $alpha) 0 ($L.TitleY + $dy) $W (Px 52) $TF.C
    Ui-Text $g $script:WelcomeBody (Ui-Font 'wbody') (Blend-Color $bg $Th.Sub $alpha) $x ($L.BodyY + $dy) $bw (Px 96) $TF.CW
    if ([string]$st.Text) {
        $col = $Th.Sub
        if ($st.Kind -eq 'good') { $col = $Th.Good } elseif ($st.Kind -eq 'warn') { $col = $Th.Warn } elseif ($st.Kind -eq 'bad') { $col = $Th.Bad }
        Ui-Text $g ([string]$st.Text) (Ui-Font 'wbody') (Blend-Color $bg $col $alpha) $x ($L.StatusY + $dy) $bw (Px 64) $TF.CW
    }
}

function Ui-PaintWelcome {
    param($g, [int]$W, [int]$H)
    $Th = $script:Th
    $TF = $script:TF
    $st = $script:Welcome
    $bg = $Th.Side
    Ui-Fill $g $bg 0 0 $W $H
    $to = Get-WelcomeLayout ([string]$st.Page) $W $H
    $from = $to
    $e = [double]$st.Anim
    if ($e -lt 1.0 -and [string]$st.From) { $from = Get-WelcomeLayout ([string]$st.From) $W $H }
    # the mark moves and shrinks from one page to the next; a soft glow sits behind it
    $s = [int][Math]::Round($from.LogoS + ($to.LogoS - $from.LogoS) * $e)
    $ly = [int][Math]::Round($from.LogoY + ($to.LogoY - $from.LogoY) * $e)
    $lx = [int](($W - $s) / 2)
    $cx = [int]($W / 2)
    $cy = $ly + [int]($s / 2)
    foreach ($ring in @(@(210, 0.020), @(170, 0.030), @(130, 0.045), @(96, 0.065))) {
        $r = Px $ring[0]
        Ui-FillOval $g (Blend-Color $bg $Th.Accent $ring[1]) ($cx - $r) ($cy - $r) (2 * $r) (2 * $r)
    }
    Ui-PaintLogo $g $lx $ly $s
    # the two pages: the old one slides up and fades out while the new one comes up from below
    $lift = Px 22
    if ($e -lt 1.0 -and [string]$st.From) {
        Ui-PaintWelcomePage $g ([string]$st.From) (1.0 - $e) (-[int]($lift * $e)) $W $H
        Ui-PaintWelcomePage $g ([string]$st.Page) $e ([int]($lift * (1.0 - $e))) $W $H
    } else {
        Ui-PaintWelcomePage $g ([string]$st.Page) 1.0 0 $W $H
    }
    # which page this is
    $d = Px 8
    $dg = Px 14
    $dx = [int](($W - (2 * $d + $dg)) / 2)
    $dyy = $H - (Px 40)
    $first = $Th.Raised
    $second = $Th.Raised
    if ($st.Page -eq 'begin') { $first = $Th.Accent } else { $second = $Th.Accent }
    Ui-FillOval $g $first $dx $dyy $d $d
    Ui-FillOval $g $second ($dx + $d + $dg) $dyy $d $d
}

# ----------------------------------------------------------- building ----------
function Ui-BuildWelcome {
    $ui = $script:UI
    $form = $ui.form
    $Th = $script:Th
    if (-not $form) { return }
    $ov = New-Object System.Windows.Forms.Control
    $ov.BackColor = $Th.Side
    $ov.TabStop = $false
    $ov.Location = New-Object System.Drawing.Point(0, 0)
    $ov.Size = $form.ClientSize
    Ui-DoubleBuffer $ov
    $bp = New-Btn 'Begin' 180 'bigprimary' '' 54
    $bs = New-Btn 'Skip for now' 180 'bigghost' '' 54
    $bt = New-Btn 'Continue without it' 260 'bigghost' '' 54
    foreach ($b in $bp, $bs, $bt) {
        $b.Add_PreviewKeyDown({ param($s, $e) try { if ([string]$e.KeyCode -eq 'Tab') { $e.IsInputKey = $true } } catch { } })
        $b.Add_KeyDown({ param($s, $e) try { if ([string]$e.KeyCode -eq 'Tab') { Ui-WelcomeTab ([bool]$e.Shift); $e.Handled = $true; $e.SuppressKeyPress = $true } } catch { Ui-Fail $_ } })
    }
    $bs.Visible = $false
    $bt.Visible = $false
    $ov.Controls.Add($bp)
    $ov.Controls.Add($bs)
    $ov.Controls.Add($bt)
    $ov.Add_Paint({ param($s, $e) try { $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias; Ui-PaintWelcome $e.Graphics ([int]$s.Width) ([int]$s.Height) } catch { Ui-Fail $_ } })
    $ov.Add_Resize({ try { Ui-WelcomeLayout } catch { Ui-Fail $_ } })
    $bp.Add_Click({ try { Ui-WelcomeClick 'P' } catch { Ui-Fail $_ } })
    $bs.Add_Click({ try { Ui-WelcomeClick 'S' } catch { Ui-Fail $_ } })
    $bt.Add_Click({ try { Ui-WelcomeClick 'T' } catch { Ui-Fail $_ } })
    $form.Controls.Add($ov)
    $ov.BringToFront()
    $tm = New-Object System.Windows.Forms.Timer
    $tm.Interval = 16
    $tm.Add_Tick({ try { Ui-WelcomeStep } catch { Ui-Fail $_ } })
    $ui.welcome = $ov
    $ui.wbP = $bp
    $ui.wbS = $bs
    $ui.wbT = $bt
    $ui.wtimer = $tm
    $script:Welcome = @{ Page = 'begin'; From = ''; Sub = 'idle'; Text = ''; Kind = ''; Prep = $null; Anim = 1.0; T0 = 0; Done = $false }
    Ui-WelcomeLayout
}

function Test-WelcomeShowing {
    $ov = $script:UI.welcome
    return [bool]($ov -and [bool]$ov.Visible -and -not $script:Welcome.Done)
}

# ----------------------------------------------------------- moving between pages ----------
function Ui-WelcomeGo {
    param([string]$page)
    $w = $script:Welcome
    if ($w.Page -eq $page) { return }
    $w.From = [string]$w.Page
    $w.Page = $page
    $w.Anim = 0.0
    $w.T0 = [Environment]::TickCount
    Ui-WelcomeLayout                       # hides the buttons during the move
    $tm = $script:UI.wtimer
    if ($tm) { $tm.Start() }
}

# One frame of the move. $Elapsed (milliseconds since it began) is only given by tests.
function Ui-WelcomeStep {
    param([int]$Elapsed = -1)
    $w = $script:Welcome
    if ([double]$w.Anim -ge 1.0) { $tm = $script:UI.wtimer; if ($tm) { $tm.Stop() }; return }
    if ($Elapsed -lt 0) { $Elapsed = [int]([Environment]::TickCount - [int]$w.T0) }
    $t = $Elapsed / [double]$script:WelcomeMoveMs
    if ($t -ge 1.0) {
        $w.Anim = 1.0
        $w.From = ''
        $tm = $script:UI.wtimer
        if ($tm) { $tm.Stop() }
        Ui-WelcomeLayout
        Ui-WelcomeFocus
        return
    }
    if ($t -lt 0) { $t = 0.0 }
    $w.Anim = 1.0 - [Math]::Pow((1.0 - $t), 3)        # eases out
    $ov = $script:UI.welcome
    if ($ov) { $ov.Invalidate() }
}

function Ui-WelcomeFocus {
    $b = $script:UI.wbP
    if ($b -and [bool]$b.Visible) { try { [void]$b.Focus() } catch { } }
}

# Tab / Shift+Tab stay on the screen's own buttons (the app underneath is hidden and must not take the focus)
function Ui-WelcomeTab {
    param([bool]$back)
    $list = @()
    foreach ($k in 'wbP', 'wbS', 'wbT') { $b = $script:UI[$k]; if ($b -and [bool]$b.Visible) { $list += $b } }
    if ($list.Count -eq 0) { return }
    $at = -1
    for ($i = 0; $i -lt $list.Count; $i++) { if ($list[$i].Focused -eq $true) { $at = $i } }
    if ($back) { $at = $at - 1; if ($at -lt 0) { $at = $list.Count - 1 } } else { $at = ($at + 1) % $list.Count }
    try { [void]$list[$at].Focus() } catch { }
}

# ----------------------------------------------------------- what the buttons do ----------
function Ui-WelcomeSet {
    param([string]$sub, [string]$text, [string]$kind)
    $w = $script:Welcome
    $w.Sub = $sub
    $w.Text = $text
    $w.Kind = $kind
    Ui-WelcomeLayout
    $ov = $script:UI.welcome
    if ($ov) { try { $ov.Update() } catch { } }          # draw it now: starting or closing HWiNFO can keep the window busy for a moment
    Ui-WelcomeFocus
}

function Ui-WelcomeClick {
    param([string]$which)
    $act = [string]$script:WelcomeActs[$which]
    switch ($act) {
        'begin'    { Ui-WelcomeBegin }
        'start'    { Ui-WelcomeStart }
        'restart'  { Ui-WelcomeRun }
        'download' { Ui-WelcomeDownload }
        'finish'   { Ui-WelcomeFinish }
    }
}

# Begin: on to the HWiNFO page. If HWiNFO is already running and sharing, the page says so at once.
function Ui-WelcomeBegin {
    $w = $script:Welcome
    $w.Sub = 'idle'; $w.Text = ''; $w.Kind = ''
    $sh = $script:SysShared
    $lv = $null
    if ($sh) { $lv = $sh.Live }
    $running = $false
    try { $running = [bool](Hwi-IsRunning) } catch { }
    if ($running -and $lv -and [string]$lv.HwiVia) {
        $w.Sub = 'shared'; $w.Kind = 'good'
        $w.Text = 'HWiNFO is already running and sharing its sensors with Headroom. You are all set.'
    }
    Ui-WelcomeGo 'hwinfo'
}

# Start HWiNFO (also "Try again")
function Ui-WelcomeStart {
    $prep = Hwi-Prepare
    $script:Welcome.Prep = $prep
    switch ([string]$prep.Code) {
        'notfound'  { Ui-WelcomeSet 'notfound' 'HWiNFO64.exe was not found on this PC. Install the free HWiNFO, then press Try again, or carry on without it (the Home page can start it later).' 'warn' }
        'busy'      { Ui-WelcomeSet 'error' 'Headroom is still reading your PC for the first time. Try again in a moment.' 'warn' }
        'shared'    { Ui-WelcomeSet 'shared' 'HWiNFO is already running and sharing its sensors with Headroom. You are all set.' 'good' }
        'planerror' { Ui-WelcomeSet 'error' ([string]$prep.Text) 'bad' }
        'ready' {
            if ($prep.Running) {
                Ui-WelcomeSet 'needclose' 'HWiNFO is already running, but it is not sharing its sensors. It has to be closed and started again for the setting to take effect. Restart it now?' 'warn'
            } else {
                Ui-WelcomeRun
            }
        }
        default     { Ui-WelcomeSet 'error' 'HWiNFO could not be started.' 'bad' }
    }
}

# Closes a running HWiNFO if need be, switches the sensor setting on, starts it
function Ui-WelcomeRun {
    $prep = $script:Welcome.Prep
    if (-not $prep -or [string]$prep.Code -ne 'ready') { Ui-WelcomeStart; return }
    if ($prep.Running) { Ui-WelcomeSet 'working' 'Closing HWiNFO...' '' } else { Ui-WelcomeSet 'working' 'Starting HWiNFO...' '' }
    $res = Hwi-Execute $prep
    switch ([string]$res.Code) {
        'started'     { Ui-WelcomeSet 'ok' 'HWiNFO is starting with sensor sharing on. Waiting for its first readings...' 'good' }
        'restarted'   { Ui-WelcomeSet 'ok' 'HWiNFO restarted with sensor sharing on. Waiting for its first readings...' 'good' }
        'startednote' { Ui-WelcomeSet 'warn' ([string]$res.Text) 'warn' }
        default       { Ui-WelcomeSet 'error' ([string]$res.Text) 'bad' }
    }
}

function Ui-WelcomeDownload {
    try { Start-Process -FilePath $script:HwiDownload } catch { Ui-WelcomeSet 'notfound' ('Could not open the browser: ' + $_.Exception.Message) 'bad' }
}

# Continue / Skip: the screen goes away and the app is there
function Ui-WelcomeFinish {
    $w = $script:Welcome
    $w.Done = $true
    $tm = $script:UI.wtimer
    if ($tm) { try { $tm.Stop() } catch { } }
    $ov = $script:UI.welcome
    if ($ov) { $ov.Visible = $false }
    try { $script:UI.form.ActiveControl = $script:UI.list } catch { }
    try { Ui-InvalidateAll; Ui-InvalidateNav } catch { }
}

# Called by the window's timer: notices when HWiNFO's readings arrive
function Ui-WelcomeTick {
    if (-not (Test-WelcomeShowing)) { return }
    $w = $script:Welcome
    $changed = $false
    if ($w.Sub -eq 'ok') {
        $sh = $script:SysShared
        $lv = $null
        if ($sh) { $lv = $sh.Live }
        if ($lv -and [string]$lv.HwiVia) {
            $w.Sub = 'shared'; $w.Kind = 'good'
            $w.Text = 'Connected: HWiNFO is sharing its sensors with Headroom.'
            $changed = $true
        }
    }
    if ($changed) { $ov = $script:UI.welcome; if ($ov) { $ov.Invalidate() } }
}

# =============================================================================
# THE WINDOW, part 8: "Select Optimization Preset" - a window of its own (like "View description") with three choices:
#   Recommended Debloat   what it is, what it changes, and a button to apply it
#   Advanced Debloat      the same, with its warning (it is only for PCs that are used mainly for gaming)
#   Custom Preset  what is applied on this PC and what is not, save that to a file, open a saved file, apply it again
# The window only shows things and saves / opens the configuration file. Applying a preset closes it and goes through the usual
# steps in the main window (Ui-DoPreset): the questions, the list of changes, the confirmation. Nothing is changed from in here.
# Names used for locals: $Th = colours, $pw = $script:PW (the open window's state).
# =============================================================================
$script:PW = $null                  # the open window: Form, Rich, Key, Result, Opt (the three choices), Act (the buttons below), Status, Changed

$script:PresetDesc = @{
    recommended = 'The recommended set for a gaming PC. It removes telemetry and tracking, turns off network sharing and power saving, tunes Windows for games, tidies how Windows looks and switches off AI and Edge extras. It does not uninstall any app. You see the full list of changes first, and each change can be undone from this app.'
    custom = 'Your own configuration. Below is what is applied on this PC right now and what is not. Save it to a file and keep the file somewhere safe (a USB drive or a cloud folder): after you wipe this PC and install Windows again, open Headroom, come back to this window, press Open configuration and then Confirm changes, and every one of those settings that is not on yet is applied. The window shows what is already enabled and what will be changed first.'
}

# What Recommended Debloat does, in plain words and grouped by area (the exact list of settings follows it in the window).
# Short lines on purpose: the text box has no hanging indent, so a long line would wrap under its dash.
$script:RecommendedSummary = @(
    @{ H = 'Privacy and telemetry'; L = @(
        'Telemetry and error reporting off, with its services and scheduled tasks',
        'Advertising ID, activity history, feedback pop-ups and app-launch tracking off',
        'Defender sample sending and Defender Core telemetry off',
        'Store apps cannot run in the background; clipboard history (Win+V) off',
        'Location services stay as they are') }
    @{ H = 'Network'; L = @(
        'File and printer sharing, network discovery and UPnP off',
        'Old name lookups (LLMNR, mDNS, NetBIOS), SMB1 and connection sharing off',
        'Power saving off on network adapters and on all USB devices') }
    @{ H = 'Performance for games'; L = @(
        'Game Mode, HAGS and Optimizations for windowed games on',
        'Game Bar and mouse acceleration off',
        'Windows Security scans only while the PC is idle',
        'Sticky, Filter, Toggle and Mouse Keys and High Contrast shortcuts off') }
    @{ H = 'Services'; L = @(
        'Rarely used services and the data usage meter off',
        'Windows Health and Optimized Experiences, troubleshooting and diagnostics off',
        'Program Compatibility Assistant off',
        'Service Host processes merged (about 50 fewer svchost.exe)') }
    @{ H = 'Look and feel'; L = @(
        'Dark mode, solid black desktop, no transparency or visual effects',
        'Taskbar icons on the left; End task in the taskbar menu',
        'Widgets, Chat, search and Task View taskbar buttons hidden',
        'Start menu Recommended section hidden; Dynamic Lighting off',
        'Notifications, ads and suggestions off; no web results in Start search',
        'Copilot and Microsoft account cards hidden in Settings',
        'File Explorer: classic right-click menu; Home and Gallery removed from the side pane') }
    @{ H = 'AI features'; L = @(
        'Copilot, Recall, Click to Do and AI in Notepad and Paint off',
        'Text and image generation for apps and voice activation off',
        'AI components page hidden in Settings') }
    @{ H = 'Microsoft Edge'; L = @(
        'Copilot sidebar, AI features, telemetry and sync off',
        'Startup boost, background running, first-run page, rewards and other nags off',
        'Update services on demand; background update tasks off') }
)
# What Advanced Debloat does on top of Recommended Debloat, in plain words and grouped by area (the exact list of settings follows it).
# Short lines on purpose, as for Recommended: the text box has no hanging indent.
$script:AdvancedSummary = @(
    @{ H = 'Cloud, sync and OneDrive'; L = @(
        'Settings sync, cloud clipboard, nearby sharing and Offline Files off',
        'Contacts, mail and calendar sync services and Windows Update sharing off',
        'OneDrive blocked and uninstalled') }
    @{ H = 'Remote access and VPN'; L = @(
        'Remote Desktop, Remote Assistance, PowerShell remoting, remote management off',
        'Windows built-in VPN services off; Quick Assist removed') }
    @{ H = 'Network adapters and startup'; L = @(
        'Windows powering down network adapters off',
        'Fast Startup and hibernation off') }
    @{ H = 'Gaming and performance'; L = @(
        'Windows Update does not replace drivers (WPBT stays on)') }
    @{ H = 'Security prompts (lowers protection)'; L = @(
        'UAC prompts and the UAC engine off (Settings and Calculator can stop opening)',
        'Memory Integrity and hypervisor off; asks first because of FACEIT and Vanguard',
        'BitLocker and automatic device encryption are left alone') }
    @{ H = 'Services and scheduled tasks'; L = @(
        'Search indexer on demand; smart card and Xbox services off',
        'Printing off (it asks first)',
        'SMS Router, Smart Card Removal Policy, Biometric and both Sensor services off',
        'Software Quality Metrics, Maps update, Family Safety, Power Diagnostics tasks off') }
    @{ H = 'File Explorer and AI'; L = @(
        'File Explorer opens to This PC',
        'Windows AI core package removed') }
    @{ H = 'Apps removed (cannot be put back from this app)'; L = @(
        'Copilot and Cortana, News, Weather, Maps, Bing Search',
        'Mail, Calendar, Outlook, People, Teams, Phone Link',
        'Media Player, Movies & TV, Sticky Notes, To Do, OneNote, Whiteboard',
        'Power Automate, Help, Tips, Feedback Hub, Clipchamp, Solitaire and other extras',
        'Widgets, promo apps (LinkedIn, Disney+, Spotify, TikTok...), Dolby Access',
        'Game Bar app, Clock, Start Experiences, Camera, Paint, Sound Recorder') }
    @{ H = 'Left as they are'; L = @(
        'Location services, WPBT, BitLocker and automatic device encryption',
        'Microsoft Store (app and policy), Snipping Tool, Xbox app and Xbox sign-in') }
)
function Add-AdvancedSummary {
    param($parts)
    $nl = "`r`n"
    $n = @($script:Catalog | Where-Object { $_.Preset }).Count
    [void]$parts.Add(@{ S = 'head'; C = ''; T = $nl + (Get-TitleCase ([string]('Everything in Recommended Debloat'))) + $nl })
    [void]$parts.Add(@{ S = 'line'; C = ''; T = ('  - All {0} of its changes, Game Mode, HAGS and windowed games included' -f $n) + $nl })
    [void]$parts.Add(@{ S = 'head'; C = ''; T = $nl + (Get-TitleCase ([string]('And on top of that'))) + $nl })
    foreach ($g in $script:AdvancedSummary) {
        [void]$parts.Add(@{ S = 'head'; C = ''; T = $nl + (Get-TitleCase ([string]([string]$g.H))) + $nl })
        foreach ($l in @($g.L)) { [void]$parts.Add(@{ S = 'line'; C = ''; T = '  - ' + [string]$l + $nl }) }
    }
}
function Add-RecommendedSummary {
    param($parts)
    $nl = "`r`n"
    foreach ($g in $script:RecommendedSummary) {
        [void]$parts.Add(@{ S = 'head'; C = ''; T = $nl + (Get-TitleCase ([string]([string]$g.H))) + $nl })
        foreach ($l in @($g.L)) { [void]$parts.Add(@{ S = 'line'; C = ''; T = '  - ' + [string]$l + $nl }) }
    }
}

# the settings of a preset, in catalog order (run-once clean-ups are never part of a preset)
function Get-PresetWinRows {
    param([string]$key)
    $out = @()
    foreach ($id in @($script:Rows.Keys)) {
        $row = $script:Rows[$id]
        if ($row.T.Once) { continue }
        if (Test-InPreset $row $key) { $out += $row }
    }
    return $out
}

# One line per setting, under its page's name. $mark = a script block that gives text to put after a row's name ('' for none).
# $style / $markStyle = the look of the name and of the text after it (the already-enabled list is quieter than the one to change).
function Add-PresetCatLines {
    param($parts, $rows, $mark, [string]$style = 'line', [string]$markStyle = 'last', $resetIds = $null)
    $nl = "`r`n"
    $rows = @($rows)
    foreach ($cat in @($script:Cats)) {
        $in = @($rows | Where-Object { [string]$_.T.Cat -eq [string]$cat })
        if ($in.Count -eq 0) { continue }
        [void]$parts.Add(@{ S = 'head'; C = ''; T = $nl + (Get-TitleCase ([string]((Split-CatName ([string]$cat)).Short))) + $nl })
        foreach ($r in $in) {
            [void]$parts.Add(@{ S = $style; C = ''; T = '  - ' + [string]$r.T.Name })
            $m = ''
            if ($resetIds -and $resetIds.ContainsKey([string]$r.T.Id)) {
                # a Use default answer: the setting goes back to the Windows default
                $m = 'back to the Windows default'
            } else {
                if ($mark) { $m = [string](& $mark $r) }
                # where the preset puts the switch: a setting that turns its feature off when applied is listed as "switch off"
                if (-not $r.T.Choices -and -not $r.T.Once) { $sw = 'switch off'; if (Get-SwitchOn $r.T $true) { $sw = 'switch on' }; if ($m) { $m = $sw + ', ' + $m } else { $m = $sw } }
            }
            if ($m) { [void]$parts.Add(@{ S = $markStyle; C = ''; T = '   (' + $m + ')' }) }
            [void]$parts.Add(@{ S = $style; C = ''; T = $nl })
        }
    }
}

# Which settings of a preset are already enabled on this PC and which will be changed. $key = recommended | advanced | personal.
# Rows = every setting of the preset, Avail = the ones this PC has, Na = how many it does not have, On = already enabled,
# Change = will be changed (a setting with options counts as enabled only when the saved option is the one in force).
function Get-PresetSplit {
    param([string]$key)
    $rows = @(Get-PresetWinRows $key)
    $avail = @($rows | Where-Object { $_.State -ne 'NA' })
    $saved = $script:Personal.Picks
    $on = @(); $chg = @()
    foreach ($r in $avail) {
        $isOn = ($r.State -eq 'On')
        if ($isOn -and $key -eq 'personal' -and $r.T.Choices) {
            $pick = [string]$saved[[string]$r.T.Id]
            if ($pick -and [string]$r.Choice -ne $pick) { $isOn = $false }
        }
        if ($isOn) { $on += $r } else { $chg += $r }
    }
    # the Question Preset's Use default answers: their settings that are not at the Windows default are changes too (put back), kept apart
    # in ResetIds so the lists can say so; they are not part of Rows / Avail / On
    $resetIds = @{}
    $resetChecking = 0
    if ($key -eq 'guided') {
        foreach ($id in @((Get-GuidedSets).ResetList)) {
            $rr = $script:Rows[[string]$id]
            if (-not $rr) { continue }
            if ([string]$rr.State -eq 'Checking') { $resetChecking++; continue }
            if ((Get-GuidedResetAction $rr) -ne '') { $resetIds[[string]$id] = $true }
        }
        if ($resetIds.Count -gt 0) {
            $have = @{}
            foreach ($r in $chg) { $have[[string]$r.T.Id] = $true }
            foreach ($id in $resetIds.Keys) { $have[[string]$id] = $true }
            $chg = @(foreach ($id in @($script:Rows.Keys)) { if ($have.ContainsKey([string]$id)) { $script:Rows[$id] } })
        }
    }
    return @{ Rows = $rows; Avail = $avail; Na = ($rows.Count - $avail.Count); On = $on; Change = $chg; ResetIds = $resetIds; Checking = (@($avail | Where-Object { $_.State -eq 'Checking' }).Count + $resetChecking) }
}

# What is written after a setting that will be changed: the things to know before confirming
function Get-PresetChangeMark {
    param($r)
    $m = @()
    if ($r.T.OneWay) { $m += 'cannot be put back' }
    if (Get-NotRecReason $r.T) { $m += 'not recommended' }
    if ($r.T.Ask) { $m += 'asks first' }
    if ($r.T.Choices -and $script:Personal.Picks.ContainsKey([string]$r.T.Id)) {
        $k = [string]$script:Personal.Picks[[string]$r.T.Id]
        $c = @($r.T.Choices | Where-Object { [string]$_.Key -eq $k } | Select-Object -First 1)
        if ($c.Count -and [string]$c[0].Short) { $m += ('option: ' + [string]$c[0].Short) }
    }
    return ($m -join ', ')
}

# The settings of the list of changes that are applied (not the ones a Use default answer puts back)
function Get-PresetApplyRows {
    param($sp)
    return @($sp.Change | Where-Object { -not $sp.ResetIds.ContainsKey([string]$_.T.Id) })
}

# The list of what will be changed (to look at before pressing Confirm changes), grouped under the pages' names
function Add-PresetChangeList {
    param($p, $sp)
    $nl = "`r`n"
    if ($sp.Change.Count -gt 0) {
        [void]$p.Add(@{ S = 'wait'; C = ''; T = $nl + ('Will be changed ({0})' -f $sp.Change.Count) + $nl })
        Add-PresetCatLines $p $sp.Change { param($r) Get-PresetChangeMark $r } 'line' 'last' $sp.ResetIds
    } elseif ($sp.Checking -eq 0 -and $sp.Avail.Count -gt 0) {
        [void]$p.Add(@{ S = 'good'; C = ''; T = $nl + 'Nothing to change: everything in this preset is already enabled on this PC.' + $nl })
    }
}

# The list of what is already enabled on this PC (in green), grouped under the pages' names
function Add-PresetOnList {
    param($p, $sp)
    $nl = "`r`n"
    if ($sp.On.Count -gt 0) {
        [void]$p.Add(@{ S = 'good'; C = ''; T = $nl + ('Already enabled ({0})' -f $sp.On.Count) + $nl })
        Add-PresetCatLines $p $sp.On $null 'goodl' 'note'
    } elseif ($sp.Checking -eq 0 -and $sp.Avail.Count -gt 0) {
        [void]$p.Add(@{ S = 'note'; C = ''; T = $nl + 'None of the settings in this preset is enabled on this PC yet.' + $nl })
    }
}

# The warning for FACEIT and Riot Vanguard players: the settings of the list that ask the anti-cheat question ('' when none)
function Get-PresetAntiCheatText {
    param($chg)
    $plan = @(@($chg) | ForEach-Object { @{ Id = [string]$_.T.Id; Action = 'Apply' } })
    $ac = @(Get-AntiCheatNames $plan)
    if ($ac.Count -eq 0) { return '' }
    return ('WARNING for FACEIT and Riot Vanguard (Valorant, League of Legends) players: this list includes {0}, which those anti-cheats can refuse to run without. You are asked about it before it is switched on.' -f ($ac -join ', '))
}

# The text of the two list views of a preset ($view = change | enabled): the settings that will be changed, or the ones already enabled
function Get-PresetViewParts {
    param([string]$key, [string]$view)
    $nl = "`r`n"
    $p = New-Object System.Collections.ArrayList
    $sp = Get-PresetSplit $key
    [void]$p.Add(@{ S = 'title'; C = ''; T = ([string]$script:PresetNames[$key]) + $nl })
    if ($sp.Checking -gt 0 -or $script:Scanning) {
        [void]$p.Add(@{ S = 'note'; C = ''; T = 'Still checking your PC...' + $nl })
        return $p
    }
    $avail = $sp.Avail.Count
    if ($view -eq 'change') {
        $back = $sp.ResetIds.Count
        if ($back -gt 0) {
            [void]$p.Add(@{ S = 'sub'; C = ''; T = ('{0} of {1} settings will be changed when you press Confirm changes, and {2} will be put back to the Windows default' -f ($sp.Change.Count - $back), $avail, $back) + $nl })
        } else {
            [void]$p.Add(@{ S = 'sub'; C = ''; T = ('{0} of {1} settings will be changed when you press Confirm changes' -f $sp.Change.Count, $avail) + $nl })
        }
        $ac = Get-PresetAntiCheatText (Get-PresetApplyRows $sp)
        if ($ac) { [void]$p.Add(@{ S = 'warn'; C = ''; T = $nl + $ac + $nl }) }
        Add-PresetChangeList $p $sp
        if ($sp.Change.Count -gt 0) {
            [void]$p.Add(@{ S = 'note'; C = ''; T = $nl + 'A restore point is created first. Switching a setting off later puts the Windows default back.' + $nl })
        }
    } else {
        [void]$p.Add(@{ S = 'sub'; C = ''; T = ('{0} of {1} settings are already enabled on this PC' -f $sp.On.Count, $avail) + $nl })
        if ($sp.On.Count -gt 0) {
            [void]$p.Add(@{ S = 'body'; C = ''; T = $nl + 'Confirm changes leaves these as they are.' + $nl })
        }
        Add-PresetOnList $p $sp
    }
    if ($sp.Na -gt 0) { [void]$p.Add(@{ S = 'note'; C = ''; T = $nl + ('Not available on this PC, so skipped: {0}.' -f $sp.Na) + $nl }) }
    return $p
}

# ------------------------------------------------ the Question Preset (DRAFT): its part of the window ----------
# The name of a setting, and the lines of a list of settings ("  - name", with a note for the ones that remove something for good)
function Get-GuidedSettingName {
    param([string]$id)
    $t = $script:ById[$id]
    if ($t) { return [string]$t.Name }
    return $id
}
function Add-GuidedNameLines {
    param($parts, $ids)
    $nl = "`r`n"
    $allow = ([string]$script:GuidedAnswers['uninstall'] -ceq 'Yes')
    foreach ($id in @($ids)) {
        $t = $script:ById[[string]$id]
        [void]$parts.Add(@{ S = 'line'; C = ''; T = '  - ' + (Get-GuidedSettingName ([string]$id)) })
        if ($t -and $t.OneWay) {
            $m = '   (removes it for good'
            if (-not $allow) { $m += '; skipped unless you allow uninstalling' }
            [void]$parts.Add(@{ S = 'note'; C = ''; T = $m + ')' })
        }
        [void]$parts.Add(@{ S = 'line'; C = ''; T = $nl })
    }
}
function Get-GuidedShort {
    param($q)
    $t = [string]$q.Q
    if ($t.Length -gt 66) { $t = $t.Substring(0, 63).TrimEnd() + '...' }
    return $t
}
function Get-GuidedAnswerText {
    param([string]$a)
    if ($a -ceq 'Yes') { return 'Yes' }
    if ($a -ceq 'No') { return 'No' }
    if ($a -ceq 'Unsure') { return 'Not sure' }
    if ($a -ceq 'Default') { return 'Use default' }
    return 'not answered'
}

# One question: what it is, what Yes / No / Not sure do, and the answer given so far
function Get-GuidedQuestionParts {
    param($q, [int]$pos, [int]$count)
    $nl = "`r`n"
    $p = New-Object System.Collections.ArrayList
    [void]$p.Add(@{ S = 'sub'; C = ''; T = ('Question {0} of {1}  -  {2}' -f ($pos + 1), $count, [string]$q.Group) + $nl })
    [void]$p.Add(@{ S = 'title'; C = ''; T = $nl + [string]$q.Q + $nl })
    [void]$p.Add(@{ S = 'body'; C = ''; T = $nl + [string]$q.Help + $nl })
    $yes = @($q.Yes); $no = @($q.No); $keep = @($q.Keep)
    if ($yes.Count) {
        [void]$p.Add(@{ S = 'head'; C = ''; T = $nl + (Get-TitleCase ([string]'If you answer Yes, Headroom applies'))  + $nl })
        Add-GuidedNameLines $p $yes
    }
    if ($no.Count) {
        [void]$p.Add(@{ S = 'head'; C = ''; T = $nl + (Get-TitleCase ([string]'If you answer No, Headroom applies')) + $nl })
        Add-GuidedNameLines $p $no
    }
    $sameAsNo = ($keep.Count -eq $no.Count -and @($keep | Where-Object { $no -contains $_ }).Count -eq $keep.Count)
    if ($keep.Count -and -not $sameAsNo) {
        [void]$p.Add(@{ S = 'head'; C = ''; T = $nl + (Get-TitleCase ([string]'Yes or Not sure keeps these as Windows has them')) + $nl })
        foreach ($id in $keep) { [void]$p.Add(@{ S = 'line'; C = ''; T = '  - ' + (Get-GuidedSettingName ([string]$id)) + $nl }) }
    } elseif ($keep.Count) {
        [void]$p.Add(@{ S = 'note'; C = ''; T = $nl + 'Yes or Not sure leaves all of these as Windows has them.' + $nl })
    } elseif ([string]$q.Id -ceq 'uninstall') {
        [void]$p.Add(@{ S = 'note'; C = ''; T = $nl + 'Yes allows the settings that remove something for good (they are marked in the lists). No or Not sure skips all of them.' + $nl })
    } elseif ([string]$q.Id -ceq 'advanced') {
        [void]$p.Add(@{ S = 'note'; C = ''; T = $nl + 'Yes adds the advanced questions at the end, and the anti-cheat questions in the gaming part. No or Not sure skips all of them, and nothing from them is applied.' + $nl })
    } else {
        [void]$p.Add(@{ S = 'note'; C = ''; T = $nl + 'No or Not sure changes nothing for this question.' + $nl })
    }
    $owned = @(@($q.Yes) + @($q.No))
    if ($owned.Count) {
        $dt = 'Use default leaves all of these as Windows has them: the ones that are changed on this PC are put back to the Windows default when you press Confirm changes.'
        if (@($owned | Where-Object { $script:ById[[string]$_] -and $script:ById[[string]$_].OneWay }).Count) { $dt += ' Settings that remove an app cannot be put back, so those stay as they are.' }
    } else {
        $dt = 'Use default does the same as Not sure for this question.'
    }
    [void]$p.Add(@{ S = 'note'; C = ''; T = $nl + $dt + $nl })
    $a = [string]$script:GuidedAnswers[[string]$q.Id]
    if ($a) {
        [void]$p.Add(@{ S = 'good'; C = ''; T = $nl + ('Your answer: ' + (Get-GuidedAnswerText $a)) + $nl })
    } else {
        [void]$p.Add(@{ S = 'note'; C = ''; T = $nl + 'Not answered yet.' + $nl })
    }
    return $p
}

# The last page: what the answers come to, what was left alone and why, and the answers themselves
function Get-GuidedReviewParts {
    $nl = "`r`n"
    $p = New-Object System.Collections.ArrayList
    $asked = @(Get-GuidedAsked)
    $c = Get-GuidedCounts
    $sets = Get-GuidedSets
    [void]$p.Add(@{ S = 'sub'; C = ''; T = ('{0} of {1} questions answered' -f $c.Done, $c.Asked) + $nl })
    [void]$p.Add(@{ S = 'title'; C = ''; T = $nl + 'Review your answers' + $nl })
    [void]$p.Add(@{ S = 'body'; C = ''; T = $nl + 'Confirm changes applies the settings on the "Will be changed" tab: the ones your answers come to that are not enabled yet. Questions you answered Not sure, or have not answered, change nothing. A question you answered Use default leaves its settings as Windows has them, and puts back the ones that are changed. Use Back to change an answer.' + $nl })
    $sp = Get-PresetSplit 'guided'
    [void]$p.Add(@{ S = 'head'; C = ''; T = $nl + (Get-TitleCase ([string]'On this PC right now')) + $nl })
    if ($sp.Checking -gt 0 -or $script:Scanning) {
        [void]$p.Add(@{ S = 'note'; C = ''; T = 'Still checking your PC...' + $nl })
    } else {
        $applyRows = @(Get-PresetApplyRows $sp)
        $t = ('{0} settings come out of your answers: {1} are already enabled, {2} will be changed.' -f $sp.Avail.Count, $sp.On.Count, $applyRows.Count)
        if ($sp.ResetIds.Count -gt 0) { $t += (' {0} more will be put back to the Windows default (Use default).' -f $sp.ResetIds.Count) }
        if ($sp.Na -gt 0) { $t += (' Not available on this PC, so skipped: {0}.' -f $sp.Na) }
        [void]$p.Add(@{ S = 'line'; C = ''; T = $t + $nl })
    }
    $ac = Get-PresetAntiCheatText (Get-PresetApplyRows $sp)
    if ($ac) { [void]$p.Add(@{ S = 'warn'; C = ''; T = $nl + $ac + $nl }) }
    # the settings that lower protection or that other programs may need: only the advanced questions apply these
    $nr = @(Get-PresetApplyRows $sp | Where-Object { (Get-NotRecReason $_.T) -or ([string]$_.T.Risk -ceq 'security') } | ForEach-Object { [string]$_.T.Name })
    if ($nr.Count) {
        [void]$p.Add(@{ S = 'head'; C = ''; T = $nl + (Get-TitleCase ([string]('Marked Not recommended or lowering protection ({0})' -f $nr.Count))) + $nl })
        [void]$p.Add(@{ S = 'warn'; C = ''; T = 'These come from the advanced questions. Each one''s description says why it carries a mark. Use Back to change the answer if you are not sure.' + $nl })
        foreach ($n in $nr) { [void]$p.Add(@{ S = 'line'; C = ''; T = '  - ' + $n + $nl }) }
    }
    if ($sp.ResetIds.Count -gt 0) {
        [void]$p.Add(@{ S = 'head'; C = ''; T = $nl + (Get-TitleCase ([string]('Put back to the Windows default ({0})' -f $sp.ResetIds.Count))) + $nl })
        [void]$p.Add(@{ S = 'note'; C = ''; T = 'You answered Use default to these questions. These settings are changed on this PC right now, so Confirm changes puts them back.' + $nl })
        foreach ($r in @($sp.Change | Where-Object { $sp.ResetIds.ContainsKey([string]$_.T.Id) })) { [void]$p.Add(@{ S = 'line'; C = ''; T = '  - ' + [string]$r.T.Name + $nl }) }
    }
    $bl = @($sets.Blocked.Keys)
    if ($bl.Count) {
        [void]$p.Add(@{ S = 'head'; C = ''; T = $nl + (Get-TitleCase ([string]('Left alone because of your answers ({0})' -f $bl.Count))) + $nl })
        foreach ($id in $bl) {
            $q = Get-GuidedQuestion ([string]$sets.Blocked[$id])
            $why = Get-GuidedAnswerText ([string]$script:GuidedAnswers[[string]$q.Id])
            [void]$p.Add(@{ S = 'line'; C = ''; T = '  - ' + (Get-GuidedSettingName ([string]$id)) })
            [void]$p.Add(@{ S = 'note'; C = ''; T = ('   ({0} to: {1})' -f $why, (Get-GuidedShort $q)) })
            [void]$p.Add(@{ S = 'line'; C = ''; T = $nl })
        }
    }
    $nu = @($sets.NoUninstall)
    if ($nu.Count) {
        [void]$p.Add(@{ S = 'head'; C = ''; T = $nl + (Get-TitleCase ([string]('Not removed, because uninstalling is not allowed ({0})' -f $nu.Count))) + $nl })
        foreach ($id in $nu) { [void]$p.Add(@{ S = 'line'; C = ''; T = '  - ' + (Get-GuidedSettingName ([string]$id)) + $nl }) }
    }
    $use = @(Get-GuidedInUseApplied)
    if ($use.Count) {
        [void]$p.Add(@{ S = 'head'; C = ''; T = $nl + (Get-TitleCase ([string]('Applied now, but you said you use them ({0})' -f $use.Count))) + $nl })
        [void]$p.Add(@{ S = 'note'; C = ''; T = 'A preset only applies settings, so these stay as they are. Switch them off on their page if you want Windows to have them back.' + $nl })
        foreach ($r in $use) { [void]$p.Add(@{ S = 'line'; C = ''; T = '  - ' + [string]$r.T.Name + $nl }) }
    }
    [void]$p.Add(@{ S = 'head'; C = ''; T = $nl + (Get-TitleCase ([string]'Your answers')) + $nl })
    foreach ($q in $asked) {
        $a = Get-GuidedAnswerText ([string]$script:GuidedAnswers[[string]$q.Id])
        [void]$p.Add(@{ S = 'line'; C = ''; T = ('  {0}  -  {1}' -f $a, (Get-GuidedShort $q)) + $nl })
    }
    return $p
}

# The text of the Question Preset part of the window: the question that is open (or the review page), or the two lists
function Get-GuidedWinParts {
    param([string]$view = 'overview')
    $nl = "`r`n"
    $c = Get-GuidedCounts
    if ($view -eq 'change' -or $view -eq 'enabled') {
        if ($c.Done -eq 0) {
            $p = New-Object System.Collections.ArrayList
            [void]$p.Add(@{ S = 'title'; C = ''; T = ([string]$script:PresetNames['guided']) + $nl })
            [void]$p.Add(@{ S = 'note'; C = ''; T = 'Answer some questions first (the Questions tab): the lists show what your answers come to.' + $nl })
            return $p
        }
        $p = Get-PresetViewParts 'guided' $view
        if ($view -eq 'change') {
            $use = @(Get-GuidedInUseApplied)
            if ($use.Count) {
                [void]$p.Add(@{ S = 'head'; C = ''; T = $nl + (Get-TitleCase ([string]('Applied now, but you said you use them ({0})' -f $use.Count))) + $nl })
                [void]$p.Add(@{ S = 'note'; C = ''; T = 'A preset only applies settings, so these stay as they are.' + $nl })
                foreach ($r in $use) { [void]$p.Add(@{ S = 'line'; C = ''; T = '  - ' + [string]$r.T.Name + $nl }) }
            }
        }
        return $p
    }
    $asked = @(Get-GuidedAsked)
    $pos = [int]$script:GuidedPos
    if ($pos -lt 0) { $pos = 0 }
    if ($pos -gt $asked.Count) { $pos = $asked.Count }
    $script:GuidedPos = $pos
    if ($pos -ge $asked.Count) { return (Get-GuidedReviewParts) }
    return (Get-GuidedQuestionParts $asked[$pos] $pos $asked.Count)
}

# The text of the window for one choice: recommended | advanced | personal. Pieces like the details panel's (see Ui-PartStyle).
function Get-PresetWinParts {
    param([string]$key, [string]$view = 'overview')
    if ($key -eq 'guided') { return (Get-GuidedWinParts $view) }
    if ($key -eq 'personal') { return (Get-CustomWinParts $view) }
    if ($view -eq 'change' -or $view -eq 'enabled') { return (Get-PresetViewParts $key $view) }
    $nl = "`r`n"
    $p = New-Object System.Collections.ArrayList
    $name = [string]$script:PresetNames[$key]
    $sp = Get-PresetSplit $key
    $avail = @($sp.Avail)
    $chg = @($sp.Change)
    [void]$p.Add(@{ S = 'title'; C = ''; T = $name + $nl })
    [void]$p.Add(@{ S = 'sub'; C = ''; T = ('{0} settings' -f $avail.Count) + $nl })
    $desc = [string]$script:PresetDesc.recommended
    if ($key -eq 'advanced') {
        if (@($script:AdvancedExtra).Count -eq 0) {
            $desc = 'A deeper clean-up for a PC that is used mainly for gaming. It starts from the Recommended list and is meant to go further, by also switching off services and features that other uses of a PC may need. Right now it makes exactly the same changes as Recommended Debloat; the extra settings are still to come.'
        } else {
            $desc = ('A deeper clean-up for a PC that is used mainly for gaming. It makes all the changes of Recommended Debloat and {0} more that go further, switching off services and features that other uses of a PC may need.' -f @($script:AdvancedExtra).Count)
        }
    }
    [void]$p.Add(@{ S = 'body'; C = ''; T = $nl + $desc + $nl })
    if ($key -eq 'recommended') { Add-RecommendedSummary $p }
    if ($key -eq 'advanced') {
        [void]$p.Add(@{ S = 'head'; C = ''; T = $nl + (Get-TitleCase ([string]('Warning'))) + $nl })
        [void]$p.Add(@{ S = 'warn'; C = ''; T = [string]$script:AdvancedWarningText + $nl })
        if (@($script:AdvancedExtra).Count -gt 0) { Add-AdvancedSummary $p }
    }
    # how far it is on this PC: what is already enabled and what will be changed
    [void]$p.Add(@{ S = 'head'; C = ''; T = $nl + (Get-TitleCase ([string]('On this PC right now'))) + $nl })
    if ($sp.Checking -gt 0 -or $script:Scanning) {
        [void]$p.Add(@{ S = 'note'; C = ''; T = 'Still checking your PC...' + $nl })
    } else {
        $t = ('{0} of {1} settings are already enabled; {2} will be changed.' -f $sp.On.Count, $avail.Count, $chg.Count)
        if ($sp.Na -gt 0) { $t += (' Not available on this PC, so skipped: {0}.' -f $sp.Na) }
        [void]$p.Add(@{ S = 'line'; C = ''; T = $t + $nl })
        if ($sp.Change.Count -gt 0 -or $sp.On.Count -gt 0) {
            [void]$p.Add(@{ S = 'note'; C = ''; T = 'Open "Will be changed" or "Already enabled" above to see which settings they are.' + $nl })
        }
    }
    # FACEIT and Riot: the settings that ask the anti-cheat question
    $acText = Get-PresetAntiCheatText $chg
    if ($acText) {
        [void]$p.Add(@{ S = 'warn'; C = ''; T = $nl + $acText + $nl })
    }
    $nr = @($chg | Where-Object { Get-NotRecReason $_.T } | ForEach-Object { [string]$_.T.Name })
    if ($nr.Count) {
        [void]$p.Add(@{ S = 'last'; C = ''; T = $nl + ('{0} of these carry a "{1}" mark; each one''s description says why:' -f $nr.Count, $script:NotRecText) + $nl + (Format-NameList $nr 12) })
    }
    # the ones that cannot be put back from this app (removing apps, OneDrive...): named before anything is applied
    $one = @($chg | Where-Object { $_.T.OneWay } | ForEach-Object { [string]$_.T.Name })
    if ($one.Count) {
        [void]$p.Add(@{ S = 'last'; C = ''; T = $nl + ('{0} of these cannot be put back from this app (removed apps can usually be installed again from the Microsoft Store):' -f $one.Count) + $nl + (Format-NameList $one 20) })
    }
    $rb = @($chg | Where-Object { $_.T.Reboot } | ForEach-Object { [string]$_.T.Name })
    if ($rb.Count) {
        $more = ''
        if ($rb.Count -gt 6) { $more = ', ...' }
        [void]$p.Add(@{ S = 'last'; C = ''; T = $nl + ('A restart is needed afterwards for {0} of these: {1}{2}' -f $rb.Count, (($rb | Select-Object -First 6) -join ', '), $more) + $nl })
    }
    if ($chg.Count -gt 0) {
        [void]$p.Add(@{ S = 'note'; C = ''; T = $nl + 'Confirm changes applies the settings on the "Will be changed" tab. A restore point is created first. Switching a setting off later puts the Windows default back.' + $nl })
    }
    return $p
}

# The text of the Custom Preset part: the saved configuration, what is applied now, what is not
function Get-CustomWinParts {
    param([string]$view = 'overview')
    if (($view -eq 'change' -or $view -eq 'enabled') -and @($script:Personal.Picks.Keys).Count -gt 0) { return (Get-PresetViewParts 'personal' $view) }
    $nl = "`r`n"
    $p = New-Object System.Collections.ArrayList
    [void]$p.Add(@{ S = 'title'; C = ''; T = ([string]$script:PresetNames['personal']) + $nl })
    [void]$p.Add(@{ S = 'sub'; C = ''; T = 'Your own set of settings, kept in a file you can take with you' + $nl })
    [void]$p.Add(@{ S = 'body'; C = ''; T = $nl + [string]$script:PresetDesc.custom + $nl })
    [void]$p.Add(@{ S = 'head'; C = ''; T = $nl + (Get-TitleCase ([string]('Saved configuration'))) + $nl })
    if (@($script:Personal.Picks.Keys).Count -eq 0) {
        [void]$p.Add(@{ S = 'note'; C = ''; T = 'None yet. Press "Save configuration..." to keep everything that is switched on in the app right now (settings that are applied, and ones you have lined up) in a file.' + $nl })
    } else {
        $info = Get-PersonalInfo
        $t = ('{0} settings, saved {1}.' -f $info.Names.Count, $info.Saved) + $nl
        if ($info.Source) { $t += ('File: {0}' -f $info.Source) + $nl }
        [void]$p.Add(@{ S = 'line'; C = ''; T = $t })
        if ($info.NotOn.Count -gt 0) {
            [void]$p.Add(@{ S = 'line'; C = ''; T = ('{0} of them are not on right now: Confirm changes applies them. They are marked "in your saved configuration" in the list of what is not applied below.' -f $info.NotOn.Count) + $nl })
        } else {
            [void]$p.Add(@{ S = 'line'; C = ''; T = 'All of them are on right now.' + $nl })
        }
        if ($info.Na -gt 0) { [void]$p.Add(@{ S = 'note'; C = ''; T = ('Not available on this PC, so skipped: {0}.' -f $info.Na) + $nl }) }
        $sp = Get-PresetSplit 'personal'
        if ($sp.Checking -eq 0 -and -not $script:Scanning) {
            [void]$p.Add(@{ S = 'line'; C = ''; T = $nl + ('Of the saved settings, {0} are already enabled on this PC; {1} will be changed.' -f $sp.On.Count, $sp.Change.Count) + $nl })
            [void]$p.Add(@{ S = 'note'; C = ''; T = 'Open "Will be changed" or "Already enabled" above to see which settings they are.' + $nl })
        }
        if ($sp.Change.Count -gt 0) {
            [void]$p.Add(@{ S = 'note'; C = ''; T = $nl + 'Confirm changes applies the settings on the "Will be changed" tab. A restore point is created first. Switching a setting off later puts the Windows default back.' + $nl })
        }
    }
    $rows = @()
    foreach ($id in @($script:Rows.Keys)) { if (-not $script:Rows[$id].T.Once) { $rows += $script:Rows[$id] } }
    $applied = @($rows | Where-Object { $_.State -eq 'On' })
    $not = @($rows | Where-Object { ($_.State -eq 'Off' -and -not (Test-NothingToApply $_)) -or $_.State -eq 'Partial' -or $_.State -eq 'Unknown' })
    $na = @($rows | Where-Object { $_.State -eq 'NA' }).Count
    $lined = @(Get-Pending).Count
    if ($script:Scanning) {
        [void]$p.Add(@{ S = 'note'; C = ''; T = $nl + 'Still checking your PC...' + $nl })
    }
    if ($lined -gt 0) {
        [void]$p.Add(@{ S = 'note'; C = ''; T = $nl + ('{0} change(s) are lined up in the app and not applied yet. A saved configuration includes the ones that switch something on.' -f $lined) + $nl })
    }
    $saved = $script:Personal.Picks
    $markOn = {
        param($r)
        $m = @()
        if ((Get-Action $r) -eq 'Undo') { $m += $(if (Get-SwitchGoesOn $r.T $true) { 'lined up to turn on' } else { 'lined up to turn off' }) }
        if ($r.T.Choices -and $saved.ContainsKey([string]$r.T.Id) -and [string]$r.Choice -ne [string]$saved[[string]$r.T.Id]) { $m += 'your saved configuration uses another option' }
        return ($m -join ', ')
    }
    $markOff = {
        param($r)
        $m = @()
        $a = Get-Action $r
        if ($a -eq 'Apply') { $m += $(if (Get-SwitchGoesOn $r.T $false) { 'lined up to turn on' } else { 'lined up to turn off' }) } elseif ($r.State -eq 'Partial') { $m += 'partly changed' }
        if ($saved.ContainsKey([string]$r.T.Id)) { $m += 'in your saved configuration' }
        return ($m -join ', ')
    }
    [void]$p.Add(@{ S = 'head'; C = ''; T = $nl + (Get-TitleCase ([string](('Applied on this PC now ({0})' -f $applied.Count)))) })
    Add-PresetCatLines $p $applied $markOn
    [void]$p.Add(@{ S = 'head'; C = ''; T = $nl + $nl + (Get-TitleCase ([string](('Not applied ({0})' -f $not.Count)))) })
    Add-PresetCatLines $p $not $markOff
    if ($na -gt 0) { [void]$p.Add(@{ S = 'note'; C = ''; T = $nl + ('{0} more settings are not available on this PC and are not listed.' -f $na) + $nl }) }
    return $p
}

# ----------------------------------------------------------- the file boxes ----------
# The boxes that ask where to save the configuration and which file to open. They return the chosen path, or '' when cancelled.
function Ui-PickSaveFile {
    $d = New-Object System.Windows.Forms.SaveFileDialog
    try {
        $d.Title = 'Save your configuration'
        $d.Filter = 'Headroom configuration (*.json)|*.json|All files (*.*)|*.*'
        $d.DefaultExt = 'json'
        $d.AddExtension = $true
        $d.OverwritePrompt = $true
        $d.FileName = 'Headroom-configuration.json'
        $docs = ''
        try { $docs = [Environment]::GetFolderPath('MyDocuments') } catch { }
        if ($docs) { $d.InitialDirectory = $docs }
        $owner = $null
        if ($script:PW) { $owner = $script:PW.Form }
        if ($owner) { $r = $d.ShowDialog($owner) } else { $r = $d.ShowDialog() }
        if ($r -eq [System.Windows.Forms.DialogResult]::OK) { return [string]$d.FileName }
        return ''
    } finally {
        try { $d.Dispose() } catch { }
    }
}

function Ui-PickOpenFile {
    $d = New-Object System.Windows.Forms.OpenFileDialog
    try {
        $d.Title = 'Open a saved configuration'
        $d.Filter = 'Headroom configuration (*.json)|*.json|All files (*.*)|*.*'
        $d.CheckFileExists = $true
        $d.Multiselect = $false
        $docs = ''
        try { $docs = [Environment]::GetFolderPath('MyDocuments') } catch { }
        if ($docs) { $d.InitialDirectory = $docs }
        $owner = $null
        if ($script:PW) { $owner = $script:PW.Form }
        if ($owner) { $r = $d.ShowDialog($owner) } else { $r = $d.ShowDialog() }
        if ($r -eq [System.Windows.Forms.DialogResult]::OK) { return [string]$d.FileName }
        return ''
    } finally {
        try { $d.Dispose() } catch { }
    }
}

# ----------------------------------------------------------- the window ----------
function Ui-PresetWinStatus {
    param([string]$text)
    $pw = $script:PW
    if ($pw -and $pw.Status) { $pw.Status.Text = $text }
}

# The three tabs above the text (Overview, Will be changed, Already enabled): the numbers on them, which one is open,
# and whether they show at all (not for a Custom Preset with nothing saved yet)
function Ui-PresetWinTabs {
    $pw = $script:PW
    if (-not $pw -or -not $pw.Tabs) { return }
    $key = [string]$pw.Key
    $show = $true
    if ($key -eq 'personal' -and @($script:Personal.Picks.Keys).Count -eq 0) { $show = $false }
    if ([bool]$pw.Tabs.Panel.Visible -ne $show) { $pw.Tabs.Panel.Visible = $show }
    $first = 'Overview'
    if ($key -eq 'guided') { $first = 'Questions' }
    if ([string]$pw.Tabs['pv-over'].Text -ne $first) { $pw.Tabs['pv-over'].Text = $first; $pw.Tabs['pv-over'].Invalidate() }
    if (-not $show) { return }
    $sp = Get-PresetSplit $key
    $nChg = '...'; $nOn = '...'
    if ($sp.Checking -eq 0 -and -not $script:Scanning) {
        $nChg = [string]$sp.Change.Count
        $nOn = [string]$sp.On.Count
    }
    $view = [string]$pw.View
    foreach ($t in @(@('pv-over', 'overview', ''), @('pv-chg', 'change', $nChg), @('pv-on', 'enabled', $nOn))) {
        $b = $pw.Tabs[[string]$t[0]]
        if ([string]$script:ChipCount[[string]$t[0]] -ne [string]$t[2]) {
            $script:ChipCount[[string]$t[0]] = [string]$t[2]
            $b.Invalidate()
        }
        $kind = 'tab'
        if ($view -eq [string]$t[1]) { $kind = 'tabon' }
        if ([string]$b.Tag -ne $kind) { $b.Tag = $kind; Ui-StyleBtn $b }
    }
}

# The line under the text that says what Confirm changes will do (shown when a choice is opened)
function Get-PresetConfirmHint {
    param([string]$key)
    $sp = Get-PresetSplit $key
    if ($key -eq 'personal' -and @($script:Personal.Picks.Keys).Count -eq 0) { return '' }
    if ($sp.Checking -gt 0 -or $script:Scanning) { return 'Still checking your PC...' }
    if ($key -eq 'guided') {
        $gc = Get-GuidedCounts
        if ($gc.Done -eq 0) { return 'Answer the questions: Yes, No, Not sure or Use default. Nothing is changed until you press Confirm changes.' }
        if ($sp.Change.Count -eq 0) { return ('{0} of {1} questions answered. Nothing to change yet: the settings your answers come to are already enabled, or there are none.' -f $gc.Done, $gc.Asked) }
        if ($sp.ResetIds.Count -gt 0) {
            return ('{0} of {1} questions answered. Confirm changes makes the {2} change(s) on the "Will be changed" tab ({3} of them put settings back to the Windows default); {4} already enabled stay as they are.' -f $gc.Done, $gc.Asked, $sp.Change.Count, $sp.ResetIds.Count, $sp.On.Count)
        }
        return ('{0} of {1} questions answered. Confirm changes applies the {2} settings on the "Will be changed" tab; {3} already enabled stay as they are.' -f $gc.Done, $gc.Asked, $sp.Change.Count, $sp.On.Count)
    }
    if ($sp.Change.Count -eq 0) { return 'Everything in this preset is already enabled on this PC, so there is nothing to confirm.' }
    return ('Confirm changes applies the {0} settings on the "Will be changed" tab. Settings that are already enabled ({1}) are left as they are.' -f $sp.Change.Count, $sp.On.Count)
}

# The text on the right for the choice that is open
function Ui-PresetWinFill {
    $pw = $script:PW
    if (-not $pw) { return }
    $view = [string]$pw.View
    if ($view -ne 'change' -and $view -ne 'enabled') { $view = 'overview' }
    if ([string]$pw.Key -eq 'personal' -and @($script:Personal.Picks.Keys).Count -eq 0) { $view = 'overview' }   # no tabs to switch with yet
    $pw.View = $view
    Ui-PresetWinTabs
    Ui-FillRich $pw.Rich (Get-PresetWinParts ([string]$pw.Key) $view)
}

# One of the tabs was pressed (by its name)
function Ui-PresetWinTabClick {
    param([string]$name)
    $view = 'overview'
    if ($name -eq 'pv-chg') { $view = 'change' } elseif ($name -eq 'pv-on') { $view = 'enabled' }
    Ui-PresetWinView $view
}

# Show that list (overview | change | enabled)
function Ui-PresetWinView {
    param([string]$view)
    $pw = $script:PW
    if (-not $pw) { return }
    if ($view -ne 'change' -and $view -ne 'enabled') { $view = 'overview' }
    $pw.View = $view
    Ui-PresetWinFill
    Ui-PresetWinButtons      # (the Question Preset shows other buttons on its lists than on its questions)
}

# Show / hide the buttons under the text for the choice that is open, and put the visible ones in a row
function Ui-PresetWinButtons {
    $pw = $script:PW
    if (-not $pw) { return }
    $show = @()
    switch ([string]$pw.Key) {
        'recommended' { $show = @('act-recommended') }
        'advanced'    { $show = @('act-advanced') }
        'personal'    { $show = @('act-save', 'act-open', 'act-apply') }
        'guided'      {
            if ([string]$pw.View -ne 'overview') { $show = @('act-guided') }
            elseif ([int]$script:GuidedPos -ge @(Get-GuidedAsked).Count) { $show = @('act-back', 'act-restart', 'act-guided') }
            else { $show = @('act-yes', 'act-no', 'act-unsure', 'act-default', 'act-back', 'act-guided') }
        }
    }
    $busy = [bool](Get-BusyReason)
    $x = Px 24
    # when the window is narrow the visible buttons are made narrower (down to 60 %) so that they all fit in the row
    $scale = 1.0
    $tot = 0; $nVis = 0; $bw = 0
    foreach ($k in @($pw.Act.Keys)) {
        if ($show -contains $k) { $tot += [int]$script:PresetActW[[string]$k]; $nVis++; if ($bw -eq 0) { try { $bw = [int]$pw.Bar.Width } catch { $bw = 0 } } }
    }
    $room = $bw - (Px 48) - (Px 10) * [Math]::Max(0, $nVis - 1)
    if ($bw -gt 0 -and $tot -gt 0 -and $room -gt 0 -and $tot -gt $room) { $scale = [Math]::Max(0.6, [double]$room / [double]$tot) }
    foreach ($k in @($pw.Act.Keys)) {
        $b = $pw.Act[$k]
        $v = ($show -contains $k)
        if ([bool]$b.Visible -ne $v) { $b.Visible = $v }
        if ($v) {
            $wd = [int][Math]::Round([double]$script:PresetActW[[string]$k] * $scale)
            if ($wd -gt 0 -and [int]$b.Width -ne $wd) { $b.Width = $wd }
            $b.Left = $x
            $x += $b.Width + (Px 10)
        }
        $en = (-not $busy)
        if ($k -eq 'act-back') { $en = ($en -and [int]$script:GuidedPos -gt 0) }
        if ($k -eq 'act-recommended' -or $k -eq 'act-advanced' -or $k -eq 'act-apply' -or $k -eq 'act-guided') {
            # Confirm changes: only when there is something to change on this PC
            $kk = [string]$pw.Key
            if ($k -eq 'act-apply') { $kk = 'personal' }
            if ($k -eq 'act-guided') { $kk = 'guided' }
            $spb = Get-PresetSplit $kk
            $en = ($en -and $spb.Change.Count -gt 0 -and $spb.Checking -eq 0)
            if ($k -eq 'act-apply') { $en = ($en -and @($script:Personal.Picks.Keys).Count -gt 0) }
        }
        Ui-SetEnabled $b $en
    }
}

# Open one of the three choices: highlight its button, show its text and its buttons
function Ui-PresetWinSelect {
    param([string]$key)
    $pw = $script:PW
    if (-not $pw) { return }
    $pw.Key = $key
    $pw.View = 'overview'
    foreach ($k in @($pw.Opt.Keys)) {
        $b = $pw.Opt[$k]
        $kind = 'choice'
        if ($k -eq $key) { $kind = 'choiceon' }
        if ([string]$b.Tag -ne $kind) { $b.Tag = $kind; Ui-StyleBtn $b }
    }
    Ui-PresetWinFill
    Ui-PresetWinButtons
    Ui-PresetWinStatus (Get-PresetConfirmHint $key)
}

# A button under the text was pressed
function Ui-PresetWinAct {
    param([string]$name)
    $pw = $script:PW
    if (-not $pw) { return }
    switch ($name) {
        'act-recommended' { Ui-PresetWinFinish 'recommended' }
        'act-advanced'    { Ui-PresetWinFinish 'advanced' }
        'act-apply'       { Ui-PresetWinFinish 'personal' }
        'act-guided'      { Ui-PresetWinFinish 'guided' }
        'act-yes'         { Ui-GuidedAnswer 'Yes' }
        'act-no'          { Ui-GuidedAnswer 'No' }
        'act-unsure'      { Ui-GuidedAnswer 'Unsure' }
        'act-default'     { Ui-GuidedAnswer 'Default' }
        'act-back'        { Ui-GuidedBack }
        'act-restart'     { Ui-GuidedRestart }
        'act-save'        { Ui-PresetWinSave }
        'act-open'        { Ui-PresetWinOpen }
    }
}

# Redraw the Question Preset part after an answer, Back or Start over
function Ui-GuidedRefresh {
    Ui-PresetWinFill
    Ui-PresetWinButtons
    Ui-PresetWinStatus (Get-PresetConfirmHint 'guided')
}
# Yes / No / Not sure: keep the answer and go on to the next question (the answers can change which questions are asked later)
function Ui-GuidedAnswer {
    param([string]$ans)
    $asked = @(Get-GuidedAsked)
    $pos = [int]$script:GuidedPos
    if ($pos -lt 0 -or $pos -ge $asked.Count) { return }
    Set-GuidedAnswer ([string]$asked[$pos].Id) $ans
    $script:GuidedPos = $pos + 1
    Ui-GuidedRefresh
}
function Ui-GuidedBack {
    if ([int]$script:GuidedPos -gt 0) { $script:GuidedPos = [int]$script:GuidedPos - 1 }
    if ($script:PW) { $script:PW.View = 'overview' }
    Ui-GuidedRefresh
}
function Ui-GuidedRestart {
    Reset-GuidedAnswers
    if ($script:PW) { $script:PW.View = 'overview' }
    Ui-GuidedRefresh
}

# Confirm changes: close the window and let the main window apply this preset (after the questions some settings ask)
function Ui-PresetWinFinish {
    param([string]$key)
    $pw = $script:PW
    if (-not $pw) { return }
    $b = Get-BusyReason
    if ($b) { Ui-PresetWinStatus $b; return }
    if ($key -eq 'personal' -and @($script:Personal.Picks.Keys).Count -eq 0) {
        Ui-PresetWinStatus 'There is no saved configuration yet. Save one, or open a saved file, first.'
        return
    }
    if ($key -eq 'guided' -and (Get-GuidedCounts).Done -eq 0) {
        Ui-PresetWinStatus 'Answer some of the questions first: the settings come from your answers.'
        return
    }
    if ((Get-PresetSplit $key).Change.Count -eq 0) {
        Ui-PresetWinStatus 'Everything in this preset is already enabled on this PC, so there is nothing to confirm.'
        return
    }
    $pw.Result = $key
    $pw.Form.DialogResult = [System.Windows.Forms.DialogResult]::OK
}

# Save configuration...: ask where, write the file, keep a copy inside the app too
function Ui-PresetWinSave {
    $pw = $script:PW
    if (-not $pw) { return }
    $cap = Get-PersonalCapture
    if (@($cap.Keys).Count -eq 0) {
        Ui-PresetWinStatus 'Nothing is switched on in the app yet, so there is nothing to save. Apply some settings first.'
        return
    }
    $path = Ui-PickSaveFile
    if (-not $path) { Ui-PresetWinStatus 'Nothing was saved.'; return }
    $r = Save-Configuration $path $cap
    if ($r.Error) {
        Ui-PresetWinStatus ('The file could not be written, so nothing was saved: ' + [string]$r.Error)
        return
    }
    $pw.Changed = $true
    Ui-PresetWinFill
    Ui-PresetWinButtons
    $t = ('Saved {0} settings to {1}. Keep that file somewhere safe (a USB drive or a cloud folder): after a clean install of Windows, open it here and press Confirm changes.' -f $r.Count, $path)
    if ($r.PersonalError) { $t += (' (The app could not keep a copy of its own: {0})' -f $r.PersonalError) }
    Ui-PresetWinStatus $t
}

# Open configuration...: ask which file, read it, make it the Custom Preset
function Ui-PresetWinOpen {
    $pw = $script:PW
    if (-not $pw) { return }
    $path = Ui-PickOpenFile
    if (-not $path) { Ui-PresetWinStatus 'Nothing was opened.'; return }
    $r = Open-Configuration $path
    if (-not $r.Ok) {
        Ui-PresetWinStatus ('That file could not be used: ' + [string]$r.Error)
        return
    }
    $pw.Changed = $true
    Ui-PresetWinFill
    Ui-PresetWinButtons
    $info = Get-PersonalInfo
    $t = ('Opened {0}: {1} settings, {2} of them not on yet. Press Confirm changes to apply them; the lists show what is already enabled and what will be changed first.' -f [IO.Path]::GetFileName($path), $r.Count, $info.NotOn.Count)
    if ($r.Skipped -gt 0) { $t += (' {0} in the file are not available on this PC (or not known to this version of Headroom) and were skipped.' -f $r.Skipped) }
    if ($r.PersonalError) { $t += (' (The app could not keep a copy of its own: {0})' -f $r.PersonalError) }
    Ui-PresetWinStatus $t
}

# Build the window (not shown yet). Returns the form; the state is in $script:PW.
function Ui-BuildPresetWindow {
    $Th = $script:Th
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Select Optimization Preset'
    $f.Font = (Ui-Font 'ui')
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
    $f.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $f.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $f.MaximizeBox = $true
    $f.MinimizeBox = $false
    $f.ShowInTaskbar = $false
    $f.BackColor = $Th.Panel
    $wa = Ui-WorkArea
    $w = [Math]::Min((Px 1000), ([int]$wa.Width - (Px 40)))
    $h = [Math]::Min((Px 740), ([int]$wa.Height - (Px 90)))   # (the title bar and borders are on top of the client size)
    $f.ClientSize = New-Object System.Drawing.Size($w, $h)
    $f.MinimumSize = New-Object System.Drawing.Size([Math]::Min((Px 820), $w), [Math]::Min((Px 520), $h))

    # left: the heading, the three choices, Close
    $left = New-Pnl 'Left' (Px 280) $Th.Side
    $head = New-Object System.Windows.Forms.Label
    $head.Text = 'Select Optimization Preset'
    $head.Font = (Ui-Font 'detTitle')
    $head.ForeColor = $Th.Text
    $head.BackColor = $Th.Side
    $head.AutoSize = $false
    $head.Location = New-Object System.Drawing.Point((Px 20), (Px 22))
    $head.Size = New-Object System.Drawing.Size((Px 244), (Px 62))
    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = 'Answer questions about how you use this PC. Nothing is changed until you press Confirm changes.'
    $hint.Font = (Ui-Font 'small')
    $hint.ForeColor = $Th.Mute
    $hint.BackColor = $Th.Side
    $hint.AutoSize = $false
    $hint.Location = New-Object System.Drawing.Point((Px 20), (Px 86))
    $hint.Size = New-Object System.Drawing.Size((Px 244), (Px 50))
    $left.Controls.Add($head)
    $left.Controls.Add($hint)
    $opts = [ordered]@{}
    $y = 150
    $optDefs = @(
        @('guided', 'Question Preset', 'Answer questions about how you use this PC. It works out which settings to change.'),
        @('personal', 'Custom Preset', 'What is applied here, and your own saved configuration to apply again after a wipe.')
    )
    foreach ($d in $optDefs) {
        $b = New-Btn ([string]$d[1]) 244 'choice' ([string]$d[2]) 44
        $b.Name = [string]$d[0]
        $b.Location = New-Object System.Drawing.Point((Px 18), (Px $y))
        $b.Add_Click({ param($s, $e) try { Ui-PresetWinSelect ([string]$s.Name) } catch { Ui-Fail $_ } })
        $left.Controls.Add($b)
        $opts[[string]$d[0]] = $b
        $y += 52
    }
    $lbar = New-Pnl 'Bottom' (Px 64) $Th.Side
    $close = New-Btn 'Close' 100 'secondary' 'Close this window. Nothing is changed.' 36
    $close.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $close.Location = New-Object System.Drawing.Point((Px 18), (Px 14))
    $lbar.Controls.Add($close)
    $left.Controls.Add($lbar)

    # right: the text, a line for what just happened, and the buttons of the open choice
    $bar = New-Pnl 'Bottom' (Px 64) $Th.Bg
    $acts = [ordered]@{}
    $actDefs = @(
        @('act-recommended', 'Confirm changes', 190, 'primary', 'Apply the Recommended Debloat settings that are not enabled yet. A restore point is created first.'),
        @('act-advanced', 'Confirm changes', 190, 'primary', 'Apply the Advanced Debloat settings that are not enabled yet. The warning is shown first, and a restore point is created first.'),
        @('act-save', 'Save configuration...', 190, 'secondary', 'Save everything that is switched on in the app right now to a file you keep.'),
        @('act-open', 'Open configuration...', 190, 'secondary', 'Open a configuration file you saved earlier (for example after installing Windows again).'),
        @('act-apply', 'Confirm changes', 190, 'primary', 'Apply the settings of the saved configuration that are not enabled yet. A restore point is created first.'),
        @('act-yes', 'Yes', 80, 'secondary', 'Answer Yes to this question.'),
        @('act-no', 'No', 80, 'secondary', 'Answer No to this question.'),
        @('act-unsure', 'Not sure', 100, 'secondary', 'Not sure: this question changes nothing, and the settings that depend on it are left as Windows has them.'),
        @('act-default', 'Use default', 124, 'secondary', 'Use default: this question''s settings stay as Windows has them. The ones that are changed on this PC are put back to the Windows default when you press Confirm changes.'),
        @('act-back', 'Back', 80, 'secondary', 'Go back to the question before.'),
        @('act-restart', 'Start over', 120, 'secondary', 'Clear every answer and begin again.'),
        @('act-guided', 'Confirm changes', 150, 'primary', 'Apply the settings your answers come to that are not enabled yet. A restore point is created first.')
    )
    $script:PresetActW = @{}
    foreach ($d in $actDefs) {
        $b = New-Btn ([string]$d[1]) ([int]$d[2]) ([string]$d[3]) ([string]$d[4]) 36
        $b.Name = [string]$d[0]
        $script:PresetActW[[string]$d[0]] = [int]$b.Width
        $b.Top = (Px 14)
        $b.Visible = $false
        $b.Add_Click({ param($s, $e) try { Ui-PresetWinAct ([string]$s.Name) } catch { Ui-Fail $_ } })
        $bar.Controls.Add($b)
        $acts[[string]$d[0]] = $b
    }
    $bar.Add_Resize({ try { Ui-PresetWinButtons } catch { } })        # (the buttons are made narrower when the window is)
    $status = New-Object System.Windows.Forms.Label
    $status.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $status.Height = (Px 56)
    $status.Font = (Ui-Font 'ui')
    $status.ForeColor = $Th.Sub
    $status.BackColor = $Th.Panel
    $status.AutoSize = $false
    $status.TextAlign = [System.Drawing.ContentAlignment]::TopLeft
    $status.Padding = New-Object System.Windows.Forms.Padding((Px 24), (Px 6), (Px 12), (Px 4))
    $status.Text = ''

    $body = New-Object System.Windows.Forms.Panel
    $body.Dock = [System.Windows.Forms.DockStyle]::Fill
    $body.BackColor = $Th.Panel
    $body.Padding = New-Object System.Windows.Forms.Padding((Px 24), (Px 18), (Px 12), (Px 8))
    $rb = New-Rich $Th.Panel $Th.Text 'body'
    $body.Controls.Add($rb)
    # three tabs above the text: Overview, Will be changed (purple) and Already enabled (green); a hairline under them
    $tabsP = New-Object System.Windows.Forms.Panel
    $tabsP.Dock = [System.Windows.Forms.DockStyle]::Top
    $tabsP.Height = (Px 46)
    $tabsP.BackColor = $Th.Panel
    $hair = New-Object System.Windows.Forms.Panel
    $hair.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $hair.Height = 1
    $hair.BackColor = $Th.Edge
    $tabsP.Controls.Add($hair)
    $script:TabAccent['pv-over'] = $Th.Sub
    $script:TabAccent['pv-chg'] = $Th.Accent
    $script:TabAccent['pv-on'] = $Th.Good
    $tabs = @{ Panel = $tabsP }
    $tabX = 0
    $tabDefs = @(
        @('pv-over', 'Overview', 104, 'overview', 'What this preset is for and how far it is on this PC.'),
        @('pv-chg', 'Will be changed', 176, 'change', 'The settings this preset will change on this PC when you press Confirm changes.'),
        @('pv-on', 'Already enabled', 176, 'enabled', 'The settings of this preset that are already enabled on this PC. They are left as they are.')
    )
    foreach ($d in $tabDefs) {
        $tb = New-Btn ([string]$d[1]) ([int]$d[2]) 'tab' ([string]$d[4]) 40
        $tb.Name = [string]$d[0]
        $tb.Location = New-Object System.Drawing.Point((Px $tabX), (Px 2))
        $tb.Add_Click({ param($s, $e) try { Ui-PresetWinTabClick ([string]$s.Name) } catch { Ui-Fail $_ } })
        $tabsP.Controls.Add($tb)
        $tabs[[string]$d[0]] = $tb
        $tabX += [int]$d[2] + 6
    }
    $spacer = New-Object System.Windows.Forms.Panel
    $spacer.Dock = [System.Windows.Forms.DockStyle]::Top
    $spacer.Height = (Px 10)
    $spacer.BackColor = $Th.Panel
    $body.Controls.Add($spacer)
    $body.Controls.Add($tabsP)

    # the one added first fills what is left; each one added later is laid out before it
    $f.Controls.Add($body)
    $f.Controls.Add($status)
    $f.Controls.Add($bar)
    $f.Controls.Add($left)
    $f.CancelButton = $close
    $f.ActiveControl = $opts['guided']
    $script:PW = @{ Form = $f; Rich = $rb; Key = 'guided'; Result = ''; Opt = $opts; Act = $acts; Status = $status; Bar = $bar; Close = $close; Changed = $false; View = 'overview'; Tabs = $tabs }
    $f.Add_HandleCreated({ param($s, $e) try { Ui-DarkTitle $s } catch { } })
    # the text goes in once the window exists (formatting a rich text box needs its handle), before it is shown
    $f.Add_Load({ param($s, $e) try { Ui-PresetWinSelect 'guided' } catch { Ui-Fail $_ } })
    return $f
}

# The "Select Optimization Preset" button: open the window; when a preset was chosen in it, go on with that preset
function Ui-ShowPresets {
    $b = Get-BusyReason
    if ($b) { Ui-Status $b; return }
    $f = Ui-BuildPresetWindow
    if (-not $f) { return }
    $res = ''
    $changed = $false
    try {
        $owner = $script:UI.form
        if ($owner) { [void]$f.ShowDialog($owner) } else { [void]$f.ShowDialog() }
        if ($script:PW) { $res = [string]$script:PW.Result; $changed = [bool]$script:PW.Changed }
    } finally {
        try { $f.Dispose() } catch { }
        $script:PW = $null
    }
    # the Custom tab of the list shows the saved configuration: it may have changed in the window
    if ($changed -and [string]$script:Mode -eq 'Personal') { Ui-OnFilterChanged }
    if ($res) { Ui-DoPreset $res }
}

# ----------------------------------------------------------- Compare Power Plans ----
# The window behind "Compare Power Plans" on the Power page: the six power plans side by side (Get-PlanCompare). It only reads: a plan
# that is installed is read from this PC with "powercfg /qh", the others show what they would bring. One painted table that scrolls, and
# Close. The colour of the dot before a value says what it does: purple = set for speed, orange = saves power, red = blocks something,
# a ring = Windows' own default, a dashed square = not set by the plan (Windows uses its default) or not listed by Windows.
$script:PC = $null
function Ui-PlanCmpGeom {
    $g = @{ Pad = (Px 24); SetW = (Px 232); ColW = (Px 178); TitleY = (Px 18); SubY = (Px 56); LegendY = (Px 104); Top = (Px 140)
            HeadH = (Px 118); GroupH = (Px 34); RowH = (Px 54); FootH = (Px 64) }
    $g.TableW = $g.SetW + @($script:PlanDefs.Keys).Count * $g.ColW
    $n = 0; $last = ''
    foreach ($r in $script:PlanCmpRows) { if ([string]$r.Group -ne $last) { $n++; $last = [string]$r.Group } }
    $g.TableH = $g.HeadH + $n * $g.GroupH + @($script:PlanCmpRows).Count * $g.RowH
    $g.W = $g.Pad * 2 + $g.TableW
    $g.H = $g.Top + $g.TableH + $g.FootH
    return $g
}
function Ui-PlanCmpSourceText {
    param($p)
    switch ([string]$p.Source) {
        'pc'     { return 'Read from this PC' }
        'file'   { return 'Not installed: from its plan file' }
        'ref'    { return 'Not installed: known values' }
        'defaults' { return 'Not installed: Windows'' defaults' }
        'unread' { return 'Installed: Windows listed nothing' }
    }
    return ''
}
# Balanced and High Performance read from this PC: do they match the defaults Windows keeps for them? @{ T; C } or $null
function Ui-PlanCmpCheckText {
    param($p)
    if (-not $p.Check) { return $null }
    $n = [int]$p.Check.Diff
    if ($n -eq 0) { return @{ T = 'Same as Windows'' defaults'; C = $script:Th.Good } }
    $w = 'settings differ'; if ($n -eq 1) { $w = 'setting differs' }
    return @{ T = ('{0} {1} from Windows'' defaults' -f $n, $w); C = $script:Th.Warn }
}
# the mark before a value: a dot, a ring (Windows default) or a small dashed square (not set)
function Ui-PlanCmpMark {
    param($g, [string]$kind, [int]$x, [int]$cy)
    $Th = $script:Th
    $d = Px 9
    $y = $cy - [int]($d / 2)
    switch ($kind) {
        'speed' { Ui-FillOval $g $Th.Accent $x $y $d $d }
        'save'  { Ui-FillOval $g $Th.Warn $x $y $d $d }
        'block' { Ui-FillOval $g $Th.Bad $x $y $d $d }
        'none'  { Ui-FillOval $g $Th.Sub $x $y $d $d }
        'def'   { Ui-StrokeOval $g $Th.Mute 1.5 $x $y $d $d }
        default { Ui-StrokeRound $g $Th.Dim 1.2 $x $y $d $d (Px 2) }
    }
}
function Ui-PlanCmpTextColor {
    param([string]$kind)
    if ($kind -eq 'def') { return $script:Th.Mute }
    if ($kind -eq 'unset') { return $script:Th.Dim }
    return $script:Th.Text
}
function Ui-PaintPlanCmp {
    param($g)
    $Th = $script:Th
    $TF = $script:TF
    $pc = $script:PC
    if (-not $pc) { return }
    $G = Ui-PlanCmpGeom
    $x0 = $G.Pad
    Ui-Fill $g $Th.Bg 0 0 $G.W $G.H
    Ui-Text $g 'Compare Power Plans' (Ui-Font 'detTitle') $Th.Text $x0 $G.TitleY $G.TableW (Px 32) $TF.L
    $sub = 'The six plans on the Power page side by side, with the values used when the PC is plugged in. A plan that is installed is read from this PC (powercfg /qh, which only reads); a plan that is not installed shows what it would bring. Nothing here changes anything.'
    Ui-Text $g $sub (Ui-Font 'body') $Th.Sub $x0 $G.SubY ([Math]::Min($G.TableW, (Px 900))) (Px 40) $TF.W
    # the legend
    $lx = $x0; $ly = $G.LegendY + (Px 10)
    foreach ($it in @(@('speed', 'Set for speed'), @('save', 'Saves power'), @('block', 'Blocks something'), @('def', 'Windows default'), @('unset', 'Not set by the plan'))) {
        Ui-PlanCmpMark $g ([string]$it[0]) $lx $ly
        $tw = Ui-TextWidth ([string]$it[1]) (Ui-Font 'small')
        Ui-Text $g ([string]$it[1]) (Ui-Font 'small') $Th.Sub ($lx + (Px 15)) ($ly - (Px 10)) ($tw + (Px 6)) (Px 20) $TF.L
        $lx += (Px 15) + $tw + (Px 22)
    }
    if ($pc.Error) {
        Ui-Text $g ('The power plans could not be read: ' + [string]$pc.Error) (Ui-Font 'body') $Th.Bad $x0 $G.Top $G.TableW (Px 40) $TF.W
        return
    }
    $plans = @($pc.Plans)
    $top = $G.Top
    Ui-FillRound $g $Th.Card $x0 $top $G.TableW $G.TableH $script:M.Radius
    # the column of the active plan is tinted from top to bottom
    for ($i = 0; $i -lt $plans.Count; $i++) {
        if ($plans[$i].Active) { Ui-Fill $g $Th.TintApply ($x0 + $G.SetW + $i * $G.ColW) ($top + (Px 1)) $G.ColW ($G.TableH - (Px 2)) }
    }
    # the head: the name, who made it, where the values come from, and "Active plan"
    Ui-Text $g 'SETTING' (Ui-Font 'cap') $Th.Mute ($x0 + (Px 16)) ($top + $G.HeadH - (Px 30)) ($G.SetW - (Px 24)) (Px 20) $TF.L
    for ($i = 0; $i -lt $plans.Count; $i++) {
        $p = $plans[$i]
        $cx = $x0 + $G.SetW + $i * $G.ColW + (Px 14)
        $cw = $G.ColW - (Px 24)
        Ui-Text $g ([string]$p.Name) (Ui-Font 'rowName') $Th.Text $cx ($top + (Px 12)) $cw (Px 22) $TF.L
        Ui-Text $g ([string]$p.By) (Ui-Font 'small') $Th.Mute $cx ($top + (Px 34)) $cw (Px 18) $TF.L
        $sc = $Th.Sub; if ($p.Source -ne 'pc') { $sc = $Th.Dim }
        Ui-Text $g (Ui-PlanCmpSourceText $p) (Ui-Font 'small') $sc $cx ($top + (Px 52)) $cw (Px 18) $TF.L
        $ck = Ui-PlanCmpCheckText $p
        if ($ck) { Ui-Text $g ([string]$ck.T) (Ui-Font 'small') $ck.C $cx ($top + (Px 70)) $cw (Px 18) $TF.L }
        if ($p.Active) {
            $pw = (Ui-TextWidth 'Active plan' (Ui-Font 'smallb')) + (Px 16)
            Ui-FillRound $g $Th.GoodSoft $cx ($top + (Px 92)) $pw (Px 20) (Px 10)
            Ui-Text $g 'Active plan' (Ui-Font 'smallb') $Th.Good $cx ($top + (Px 92)) $pw (Px 20) $TF.C
        }
    }
    $y = $top + $G.HeadH
    Ui-Line $g $Th.Edge 1 $x0 $y ($x0 + $G.TableW) $y
    $last = ''
    $fv = Ui-Font 'row'
    $vw = $G.ColW - (Px 44)
    foreach ($r in $script:PlanCmpRows) {
        if ([string]$r.Group -ne $last) {
            $last = [string]$r.Group
            Ui-Fill $g $Th.Hover ($x0 + (Px 1)) $y ($G.TableW - (Px 2)) $G.GroupH
            Ui-Text $g $last.ToUpper() (Ui-Font 'cap') $Th.Sub ($x0 + (Px 16)) $y ($G.TableW - (Px 32)) $G.GroupH $TF.L
            $y += $G.GroupH
        }
        Ui-Text $g ([string]$r.Name) (Ui-Font 'uib') $Th.Text ($x0 + (Px 16)) ($y + (Px 9)) ($G.SetW - (Px 28)) (Px 20) $TF.L
        if ($r.Hint) { Ui-Text $g ([string]$r.Hint) (Ui-Font 'small') $Th.Mute ($x0 + (Px 16)) ($y + (Px 29)) ($G.SetW - (Px 28)) (Px 18) $TF.L }
        for ($i = 0; $i -lt $plans.Count; $i++) {
            $c = $plans[$i].Cells[[string]$r.Id]
            if (-not $c) { continue }
            $cx = $x0 + $G.SetW + $i * $G.ColW + (Px 14)
            $t = [string]$c.T
            $col = Ui-PlanCmpTextColor ([string]$c.K)
            if ((Ui-TextWidth $t $fv) -le $vw) {
                Ui-PlanCmpMark $g ([string]$c.K) $cx ($y + [int]($G.RowH / 2))
                Ui-Text $g $t $fv $col ($cx + (Px 16)) $y $vw $G.RowH $TF.L
            } else {
                # two lines, from the top, the mark level with the first
                Ui-PlanCmpMark $g ([string]$c.K) $cx ($y + (Px 17))
                Ui-Text $g $t $fv $col ($cx + (Px 16)) ($y + (Px 8)) $vw ($G.RowH - (Px 10)) $TF.W
            }
        }
        $y += $G.RowH
        Ui-Line $g $Th.Edge 1 ($x0 + (Px 12)) $y ($x0 + $G.TableW - (Px 12)) $y
    }
    # the column lines
    for ($i = 0; $i -le $plans.Count - 1; $i++) {
        $lx2 = $x0 + $G.SetW + $i * $G.ColW
        Ui-Line $g $Th.Edge 1 $lx2 ($top + (Px 1)) $lx2 ($top + $G.TableH - (Px 1))
    }
    $foot = 'Windows default: the plan leaves it to Windows. Not set: the plan file does not include it, so Windows uses its own default. Balanced and High Performance are compared with the defaults Windows keeps for them (what Restore plan defaults sets). Exact numbers: powercfg /q <plan ID>.'
    Ui-Text $g $foot (Ui-Font 'small') $Th.Mute $x0 ($top + $G.TableH + (Px 14)) ([Math]::Min($G.TableW, (Px 900))) (Px 40) $TF.W
}
# reads the six plans (powercfg /list and /qh only) and sizes the table
function Ui-PlanCmpRead {
    $pc = $script:PC
    if (-not $pc) { return }
    $pc.Error = ''
    try { $pc.Plans = @(Get-PlanCompare) } catch { $pc.Plans = @(); $pc.Error = $_.Exception.Message }
    $pc.When = (Get-Date).ToString('HH:mm')
    $G = Ui-PlanCmpGeom
    $pc.Table.Size = New-Object System.Drawing.Size($G.W, $G.H)
    $n = @($pc.Plans | Where-Object { $_.Installed }).Count
    if ($pc.Error) { $pc.Status.Text = 'The power plans could not be read.' }
    else { $pc.Status.Text = ('Read at {0}: {1} of the {2} plans are installed on this PC. Nothing was changed.' -f $pc.When, $n, @($script:PlanDefs.Keys).Count) }
    $pc.Table.Invalidate()
}
function Ui-BuildPlanCmpWindow {
    $Th = $script:Th
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Compare Power Plans'
    $f.Font = (Ui-Font 'ui')
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
    $f.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $f.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $f.MaximizeBox = $true
    $f.MinimizeBox = $false
    $f.ShowInTaskbar = $false
    $f.BackColor = $Th.Bg
    $G = Ui-PlanCmpGeom
    $wa = Ui-WorkArea
    $w = [Math]::Min(($G.W + (Px 24)), ([int]$wa.Width - (Px 40)))
    $h = [Math]::Min(($G.H + (Px 64)), ([int]$wa.Height - (Px 90)))
    $f.ClientSize = New-Object System.Drawing.Size($w, $h)
    $f.MinimumSize = New-Object System.Drawing.Size([Math]::Min((Px 640), $w), [Math]::Min((Px 420), $h))
    $bar = New-Pnl 'Bottom' (Px 64) $Th.Bg
    $close = New-Btn 'Close' 100 'secondary' 'Close this window. Nothing was changed.' 36
    $close.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $close.Location = New-Object System.Drawing.Point((Px 24), (Px 14))
    $status = New-Object System.Windows.Forms.Label
    $status.AutoSize = $false
    $status.Font = (Ui-Font 'small')
    $status.ForeColor = $Th.Mute
    $status.BackColor = $Th.Bg
    $status.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $status.Location = New-Object System.Drawing.Point((Px 140), (Px 14))
    $status.Size = New-Object System.Drawing.Size([Math]::Max((Px 200), ($w - (Px 164))), (Px 36))
    $status.Text = 'Reading the power plans...'
    $bar.Controls.Add($close)
    $bar.Controls.Add($status)
    $scroll = New-Object System.Windows.Forms.Panel
    $scroll.Dock = [System.Windows.Forms.DockStyle]::Fill
    $scroll.AutoScroll = $true
    $scroll.BackColor = $Th.Bg
    $tbl = New-Object System.Windows.Forms.Control
    $tbl.BackColor = $Th.Bg
    $tbl.Location = New-Object System.Drawing.Point(0, 0)
    $tbl.Size = New-Object System.Drawing.Size($G.W, $G.H)
    Ui-DoubleBuffer $tbl
    $tbl.Add_Paint({ param($s, $e) try { $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias; Ui-PaintPlanCmp $e.Graphics } catch { Ui-Fail $_ } })
    $scroll.Controls.Add($tbl)
    $f.Controls.Add($scroll)
    $f.Controls.Add($bar)
    $f.CancelButton = $close
    $f.ActiveControl = $close
    $script:PC = @{ Form = $f; Table = $tbl; Scroll = $scroll; Status = $status; Close = $close; Plans = @(); When = ''; Error = '' }
    $f.Add_HandleCreated({ param($s, $e) try { Ui-DarkTitle $s } catch { } })
    $scroll.Add_HandleCreated({ param($s, $e) try { Ui-DarkScroll $s } catch { } })
    $f.Add_Load({ param($s, $e) try { Ui-PlanCmpRead } catch { Ui-Fail $_ } })
    return $f
}
# The "Compare Power Plans" button on the Power page
function Ui-ShowPlanCmp {
    $f = Ui-BuildPlanCmpWindow
    if (-not $f) { return }
    $old = $null
    try {
        try { $old = [System.Windows.Forms.Cursor]::Current; [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor } catch { }
        $owner = $script:UI.form
        if ($owner) { [void]$f.ShowDialog($owner) } else { [void]$f.ShowDialog() }
    } finally {
        try { if ($old) { [System.Windows.Forms.Cursor]::Current = $old } } catch { }
        try { $f.Dispose() } catch { }
        $script:PC = $null
    }
}

# =============================================================================
# START
# =============================================================================
# A 32-bit PowerShell on 64-bit Windows would write HKLM\SOFTWARE settings to the wrong (WOW6432Node) place
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    Write-Host 'This is a 32-bit PowerShell. Start the 64-bit one ("Windows PowerShell", not "(x86)") as administrator, or double-click Start-Headroom.bat.' -ForegroundColor Red
    exit 1
}

. $engine      # the catalog and the engine, in this process too

$useConsole = ($NoGui -or $List -or $Preset -or (@(Split-Ids $Apply).Count -gt 0) -or (@(Split-Ids $Undo).Count -gt 0))
$code = 0
if ($useConsole) {
    $code = @(Start-ConsoleMode -ShowList ([bool]$List) -UsePreset ([bool]$Preset) -ApplyIds $Apply -UndoIds $Undo)[-1]
    if ($code -isnot [int]) { $code = 0 }
} else {
    try {
        Show-Window
    } catch {
        $code = 1
        $msg = $_.Exception.Message
        Write-Host ('The window could not be opened: ' + $msg) -ForegroundColor Red
        Write-Host 'You can still use everything from this console: run the script again with -NoGui (for example  -NoGui -List).' -ForegroundColor Yellow
        try {
            Add-Type -AssemblyName System.Windows.Forms
            [void][System.Windows.Forms.MessageBox]::Show(("The window could not be opened:`r`n{0}`r`n`r`nRun the script with -NoGui to use it from the console." -f $msg), 'Headroom')
        } catch { }
    }
}
exit $code
