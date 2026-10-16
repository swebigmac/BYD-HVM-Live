#Requires -Version 5.1
<#
BYD-HVM-Live v1.4 -- direct LAN cell dashboard for a three-tower HVM installation.
Run in a normal PowerShell console, not ISE. No admin rights are required.
No adapter, route, firewall, service, charging or firmware changes are made.

IMPORTANT: This is NOT write-free. Each tower capture selects diagnostics using
FC16 at 0x0550 with [tower, 0x8100], as in the previously working 4-packet script.
Only that write is allowed. Other traffic is whitelisted FC03 reads.
Stop Be Connect Plus, the old TCP relay and other BYD diagnostic readers first.
This is an unofficial diagnostic tool, NOT a battery safety/control system.

Run /? for full register descriptions; /IPv4 connects directly; no argument prompts for IP. All settings are at the top. Screen refresh and acquisition interval are separate.
Every tower is read sequentially. A slow BMS is never forced into a 1-second scan.
Q or Ctrl+C exits. A = automatic/all towers, 1/2/3 = selected tower,
N = numeric cells, H = compact heatmap. Narrow/short windows show one tower
at a time while all configured towers continue to be captured and logged.

-SelfTest: offline tests only, no network or log files.
These same tests also run automatically before a live connection.
-CheckOnly: read and validate configuration, save its raw fields, then exit.
Version 1.2 retains the v1.1 0x0011 byte selection fix: HIGH byte = battery type,
LOW byte = application mode. The model/layout guard remains active.
v1.2 adds signed per-tower current (word 26), calculated tower power, and highest-cell highlight. No new Modbus requests, writes or register ranges.
-Demo: explicitly simulated values, no network. Uses separate DEMO log directory.
-Plain: plain-text per-tower output, useful for redirected output / test harnesses.

Decoder basis: BYD-HVM-Analys-4paket.ps1 and BYD-ID-Offline.ps1 in this chat;
BeConnectPlus-Analys.md: 4 x 128 payload bytes; serial bytes 66..84;
SOC word 24; warning words 27..29; fault word 47; cells start at word 48.
https://github.com/sarnau/BYD-Battery-Box-Infos/blob/main/Read_Modbus.py
Model byte mapping cross-check (decodePacket2 and decodePacket0):
https://github.com/christianh17/ioBroker.bydhvs/blob/master/main.js
https://github.com/christianh17/ioBroker.bydhvs/blob/master/docs/byd-hexstructure.md
https://learn.microsoft.com/en-us/windows/console/console-virtual-terminal-sequences
#>
[CmdletBinding()]
param(
    [string]$Ip = '',
    [ValidateRange(1,65535)][int]$Port = 8080,
    [ValidateRange(5,300)][double]$ScanSeconds = 10,
    [ValidateRange(0.5,10)][double]$RefreshSeconds = 1,
    [ValidateRange(1,3)][int]$ExpectedTowers = 3,
    [ValidateRange(3,8)][int]$ModulesPerTower = 7,
    [string]$OutputDirectory = '',
    [string]$WatchSerial = '',
    [ValidateRange(1,8)][int]$WatchModule = 7,
    [ValidateRange(1,16)][int]$WatchCell = 14,
    [switch]$Numbers,
    [switch]$Plain,
    [switch]$Demo,
    [switch]$SelfTest,
    [switch]$CheckOnly,
    [ValidateRange(0,100000)][int]$MaxScans = 0
)


# Slash syntax /? and /a.b.c.d is supported as a positional argument in addition
# to PowerShell's standard -Ip, -SelfTest, -Demo etc. No built-in target IP.
function Show-BYDHelp {
    @'
BYD HVM LIVE v1.4 - HELP AND PROTOCOL REFERENCE
=================================================

GETTING STARTED (Windows PowerShell 5.1+, regular console, not PowerShell ISE)
  .\BYD-HVM-Live-v1.4-EN.ps1 /?                  Show this help; no connection
  .\BYD-HVM-Live-v1.4-EN.ps1 /192.168.1.100         Connect directly
  .\BYD-HVM-Live-v1.4-EN.ps1                    Prompt for the IPv4 address
  .\BYD-HVM-Live-v1.4-EN.ps1 -Ip 192.168.1.100     Standard PowerShell syntax
  .\BYD-HVM-Live-v1.4-EN.ps1 -SelfTest         Offline self-tests; no IP required
  .\BYD-HVM-Live-v1.4-EN.ps1 -Demo -MaxScans 2   Simulated data; no connection
  .\BYD-HVM-Live-v1.4-EN.ps1 -Ip 192.168.1.100 -CheckOnly

KEYBOARD CONTROLS
  N = numerical cell readings; H = compact cell heatmap
  A = automatic / all towers; 1,2,3 = focus on a tower; Q = quit
  v = lowest cell; ^ = highest cell; cyan / green highlighting
  Tower 1 = MASTER (verified for the original test installation only)

DATA ACQUISITION - MODBUS RTU OVER TCP, PORT 8080, SLAVE ID 1
  FC03 0x0000, 102 registers: system configuration
    0x0010: high nibble = tower count; low nibble = modules per tower
    0x0011: high byte = model (1=HVM, 2=HVS); low byte = application mode
  FC03 0x0500, 25 registers: aggregate system status
    0x0500 SOC %, 0x0501 maximum cell (*10 mV), 0x0502 minimum cell (*10 mV)
    0x0503 SOH %, 0x0504 signed system current /10 A
    0x0505 system voltage /100 V
    0x0506, 0x0507 maximum/minimum temperature C; 0x050D raw fault field
  FC16 0x0550, 2 registers: [tower 1..3, 0x8100]
    Selects BMS diagnostic data for one tower. THIS IS A WRITE COMMAND,
    so acquisition is NOT strictly read-only at the Modbus protocol level.
  FC03 0x0551, 1 register: wait for diagnostic-ready status 0x8801
  FC03 0x0558, 65 registers, four reads per tower:
    Each response contains one length word (128) and 64 data words.
    Four responses combine into 256 data words / 512 bytes per BMS.

DECODING - 256 WORDS IN THE COMBINED BMS BLOCK (ZERO-BASED)
    words 3,4      temperature range (signed C, maximum/minimum)
    word 18 high byte  raw SOC CALIBRATION; status meanings unverified
    word 24        SOC /10 %
    word 26        signed TOWER CURRENT /10 A; NEGATIVE = charging
    words 27..29   three raw warning masks
    word 47        raw fault mask
    words 48..159  112 cell voltage readings, mV (7 modules x 16 cells)
    bytes 66..84   BMS serial number (19 ASCII bytes)
  Tower voltage = sum of 112 cell voltage readings /1000, approximate.
  Tower power = tower current * tower voltage; negative = charging.
  Individual module serial numbers are NOT decoded by this version.
  Towers are captured SEQUENTIALLY; brief discrepancies between the sum
  of tower currents and BMU current are normal during power changes.

SAFETY AND VALIDATION
  Configuration must match the selected HVM tower/module layout.
  No network, charging, operating or firmware settings are changed.
  FC16 diagnostic selection is nevertheless a Modbus write, as above.
  Do not run with Be Connect or during a firmware update.
  This is an unofficial diagnostic tool, NOT a battery safety system.

LOG FILES
  A new LIVE-YYYYMMDD-HHMMSS-id directory is created per run.
  Previous runs are never overwritten.
  cells.csv       cell voltages, SOC, individual tower current/power, alarms
                  SOC_Calibration_Raw_HighByte_Word18 (0..255, not decoded)
  system.csv      BMU SOC, SOH, aggregate current, voltage and power
  raw.ndjson      full diagnostic words and raw messages
  errors.log      transport and program errors
  snapshot-*.json diagnostic snapshots
  A timed-out tower is paused for at least 20 seconds without immediate
  diagnostic retry; other towers continue. Connection is recreated safely
  after a transport failure.
  -OutputDirectory chooses the log directory.

SOURCES AND PROTOCOL NOTES
  https://github.com/sarnau/BYD-Battery-Box-Infos
  https://github.com/christianh17/ioBroker.bydhvs
  Byte layouts, units and tower current (word 26) have been compared with
  real BYD HVM 3x7 telemetry. All protocol descriptions are unofficial.
'@ | Write-Host
}
# Slash-argumentet binds till $Ip som forsta positionella parametern.
# Detta ska ske innan sjalvtest, konfiguration eller loggstart.
if ($Ip -eq '/?' -or $Ip -eq '/help' -or $Ip -eq '--help') { Show-BYDHelp; return }
if ($Ip.StartsWith('/')) { $Ip = $Ip.Substring(1) }
if ([string]::IsNullOrWhiteSpace($Ip) -and -not ($SelfTest -or $Demo)) {
    Write-Host 'BYD HVM Live v1.4 - Enter your battery IPv4 address.'
    $Ip = Read-Host 'IPv4 address'
    if (-not [string]::IsNullOrWhiteSpace($Ip)) {
        Write-Host ('TIP: Next time you can connect directly with: .\BYD-HVM-Live-v1.4-EN.ps1 /{0}' -f $Ip)
        Write-Host ('Create a Windows shortcut to PowerShell with arguments: -NoProfile -File "<full path>\BYD-HVM-Live-v1.4-EN.ps1" /{0}' -f $Ip)
    }
}
if ([string]::IsNullOrWhiteSpace($Ip) -and $Demo) { $Ip = '127.0.0.1' }

$AppVersion = '1.4'
# Communication and presentation settings. These are not battery limits.
$Settings = @{
    ConnectTimeoutMs = 4000
    FrameTimeoutMs = 4000
    DiagnosticTimeoutMs = 10000
    PollDelayMs = 250
    BetweenTowersMs = 250
    Highlight1_mV = 20
    Highlight2_mV = 50
    Highlight3_mV = 100
    StaleSeconds = [Math]::Max(30, 3*$ScanSeconds)
    RetryCooldownSeconds = 20
    ReconnectCooldownSeconds = 20
}

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$inv = [Globalization.CultureInfo]::InvariantCulture
$esc = [string][char]27
$script:State = @{
    Towers = @{}; Status = $null; Config = $null; Scan = 0; Samples = 0
    DeviceConfig = $null; ConfigSummary = ''
    Stage = 'Starting'; LastError = ''; Started = [DateTime]::UtcNow
    LastSweepSeconds = 0.0; LastPaint = [DateTime]::MinValue
    LastKeyCheck = [DateTime]::MinValue; Focus = 0; Numbers = [bool]$Numbers
    StopRequested = $false; UiReady = $false; Ansi = $false
    Trace = [Collections.Generic.List[object]]::new(); WatchFirst = $null
    WatchHistory = [Collections.Generic.List[object]]::new()
    CellCount = 16*$ModulesPerTower; CsvWriter = $null; StatusWriter = $null
    RawWriter = $null; ErrorWriter = $null; LogPath = ''; WatchIdentity = ''
    FailedTowers = @{}; TowerFailures = @{}; SuccessfulTowers = @{}; CommunicationErrors = 0
    ReconnectAfter = [DateTime]::MinValue; ConnectionBroken = $false
}
$script:Tcp = $null
$script:Stream = $null
$script:Mutex = $null
$script:OwnsMutex = $false
$script:OriginalCtrlC = $null
$script:VtSaved = $false
$script:CursorSaved = $null
$script:ForegroundSaved = $null
$script:BackgroundSaved = $null
$script:FullSnapshotCount = 0
$script:ExitCode = 0

function Get-Crc16([byte[]]$Data) {
    [int]$crc = 65535
    foreach ($b in $Data) {
        $crc = $crc -bxor [int]$b
        for ($bit=0; $bit -lt 8; $bit++) {
            if (($crc -band 1) -ne 0) { $crc = ($crc -shr 1) -bxor 40961 }
            else { $crc = $crc -shr 1 }
        }
    }
    return ($crc -band 65535)
}
function Add-Crc([byte[]]$Payload) {
    $crc = Get-Crc16 $Payload
    [byte[]]$frame = @($Payload) + @([byte]($crc -band 255),[byte](($crc -shr 8) -band 255))
    return ,$frame
}
function Assert-FrameCrc([byte[]]$Frame) {
    if ($Frame.Length -lt 5) { throw 'Short Modbus frame.' }
    $got = [int]$Frame[$Frame.Length-2] -bor ([int]$Frame[$Frame.Length-1] -shl 8)
    if ((Get-Crc16 $Frame[0..($Frame.Length-3)]) -ne $got) { throw 'Modbus CRC mismatch.' }
}
function Convert-Signed16([int]$Value) {
    if ($Value -ge 32768) { return ($Value-65536) }
    return $Value
}
function Get-Age($Time) {
    if ($null -eq $Time) { return 0.0 }
    return [Math]::Max(0,([DateTime]::UtcNow-[DateTime]$Time).TotalSeconds)
}
function Format-Num([double]$Value,[string]$Pattern='0.0') {
    return $Value.ToString($Pattern,$inv)
}
function Convert-Tower([int[]]$Words,[int]$Tower,[DateTime]$RequestedAt,[DateTime]$ReceivedAt) {
    if ($Words.Length -ne 256) { throw "Tower ${Tower}: expected exactly 256 payload words." }
    [byte[]]$bytes = New-Object byte[] 512
    for ($i=0; $i -lt 256; $i++) {
        if ($Words[$i] -lt 0 -or $Words[$i] -gt 65535) { throw 'Non-UInt16 payload word.' }
        $bytes[2*$i] = [byte](($Words[$i] -shr 8) -band 255)
        $bytes[2*$i+1] = [byte]($Words[$i] -band 255)
    }
    $serialBytes = [byte[]]$bytes[66..84]
    $end = 19
    while ($end -gt 0 -and $serialBytes[$end-1] -in @(0,32,255)) { $end-- }
    $serial = ''
    if ($end -gt 0) {
        $printable = $true
        for ($i=0; $i -lt $end; $i++) {
            if ($serialBytes[$i] -lt 32 -or $serialBytes[$i] -gt 126) { $printable=$false }
        }
        if ($printable) { $serial=[Text.Encoding]::ASCII.GetString($serialBytes,0,$end).Trim() }
    }
    if ($Words[24] -gt 1000) { throw "Tower ${Tower}: implausible SOC field; raw payload preserved." }
    [int[]]$cells = $Words[48..(47+$State.CellCount)]
    foreach ($v in $cells) {
        # Wide FORMAT check, not a manufacturer operating/safety threshold.
        if ($v -lt 1000 -or $v -gt 4500) { throw "Tower ${Tower}: suspect cell field $v mV; raw payload preserved." }
    }
    [int[]]$sorted = $cells | Sort-Object
    $median = ($sorted[$sorted.Length/2-1]+$sorted[$sorted.Length/2])/2.0
    $min = $sorted[0]; $max = $sorted[-1]
    $minimumIndex = [Array]::IndexOf($cells,$min)
    $maximumIndex = [Array]::IndexOf($cells,$max)
    $modules = [Collections.Generic.List[object]]::new()
    for ($m=0; $m -lt $ModulesPerTower; $m++) {
        [int[]]$mc = $cells[($m*16)..($m*16+15)]
        $stats = $mc | Measure-Object -Minimum -Maximum -Average
        $modules.Add([pscustomobject]@{
            Number=$m+1; Cells=$mc; Min=[int]$stats.Minimum; Max=[int]$stats.Maximum
            Delta=[int]($stats.Maximum-$stats.Minimum); Average=[double]$stats.Average
        })
    }
    return [pscustomobject]@{
        Tower=$Tower; Serial=$serial; SerialHex=[BitConverter]::ToString($serialBytes)
        RequestedAt=$RequestedAt; ReceivedAt=$ReceivedAt
        CaptureSeconds=($ReceivedAt-$RequestedAt).TotalSeconds; Scan=$State.Scan
        SocCalibrationRaw=(($Words[18] -shr 8) -band 0xFF)
        SocCalibrationWord=$Words[18]
        Soc=$Words[24]/10.0
        # Signed diagnostic word 26, validated against BMU current and Be Connect 2.0.
        Current=(Convert-Signed16 $Words[26])*0.1
        # Each HVM module has 16 series LFP cells. Use sum of decoded cell readings
        # for this tower's approximate battery voltage (not a measured DC bus voltage).
        Voltage=([double](($cells | Measure-Object -Sum).Sum)/1000.0)
        Cells=$cells; Min=$min; Max=$max; Delta=$max-$min
        Median=$median; MinIndex=$minimumIndex; MaxIndex=$maximumIndex
        MinModule=1+[int][Math]::Floor($minimumIndex/16.0); MinCell=1+($minimumIndex%16)
        MaxModule=1+[int][Math]::Floor($maximumIndex/16.0); MaxCell=1+($maximumIndex%16)
        Warning1=$Words[27]; Warning2=$Words[28]; Warning3=$Words[29]; Fault=$Words[47]
        TempMin=(Convert-Signed16 $Words[4]); TempMax=(Convert-Signed16 $Words[3])
        Modules=$modules.ToArray(); Words=$Words
    }
}
function Convert-Configuration([int[]]$Words) {
    if ($Words.Length -ne 102) { throw 'Configuration length is not 102 registers.' }
    foreach ($word in $Words) {
        if ($word -lt 0 -or $word -gt 65535) { throw 'Configuration contains a non-UInt16 word.' }
    }
    # Register 0x0011 consists of two DIFFERENT 8-bit fields.
    # A short FC03 read of 0x0010 (3 registers) has its model at frame byte 5:
    # frame[3:5] = R0010, frame[5:7] = R0011. Thus model is R0011 HIGH byte.
    # ioBroker decodePacket2 reads byteArray[5] (1=HVM, 2=HVS).
    # decodePacket0 reads full-config frame byte 38 for application mode,
    # i.e. the LOW byte of R0011. v1.0 mistakenly tested application as model.
    $modelCode = ($Words[0x0011] -shr 8) -band 255
    $applicationCode = $Words[0x0011] -band 255
    $model = switch ($modelCode) { 0 {'HVL'} 1 {'HVM'} 2 {'HVS'} default {'UNKNOWN'} }
    $application = switch ($applicationCode) { 0 {'OffGrid'} 1 {'OnGrid'} 2 {'Backup'} default {'UNKNOWN'} }
    return [pscustomobject]@{
        Towers = ($Words[0x0010] -shr 4) -band 15
        ModulesPerTower = $Words[0x0010] -band 15
        ModelCode = $modelCode; Model = $model
        ApplicationCode = $applicationCode; Application = $application
        Register0010 = $Words[0x0010]; Register0011 = $Words[0x0011]; Register0012 = $Words[0x0012]
        Summary = ('Config: R0010=0x{0:X4} R0011=0x{1:X4} R0012=0x{2:X4} | model={3} ({4}) | application={5} ({6}) | {7}x{8}' -f
            $Words[0x0010],$Words[0x0011],$Words[0x0012],$model,$modelCode,$application,$applicationCode,
            (($Words[0x0010] -shr 4) -band 15),($Words[0x0010] -band 15))
    }
}
function Assert-HvmConfiguration($Configuration) {
    if ($Configuration.Towers -ne $ExpectedTowers -or $Configuration.ModulesPerTower -ne $ModulesPerTower) {
        throw ('Configuration mismatch: device says {0} towers x {1} modules, expected {2} x {3}. No diagnostic write sent. {4}' -f
            $Configuration.Towers,$Configuration.ModulesPerTower,$ExpectedTowers,$ModulesPerTower,$Configuration.Summary)
    }
    if ($Configuration.ModelCode -ne 1) {
        throw ('Expected HVM model code 1 in HIGH byte of R0011; received {0} ({1}). No diagnostic write sent. {2}' -f
            $Configuration.ModelCode,$Configuration.Model,$Configuration.Summary)
    }
}

function Convert-Status([int[]]$Words,[DateTime]$Time) {
    if ($Words.Length -ne 25) { throw 'Status length is not 25 registers.' }
    if ($Words[0] -gt 100 -or $Words[3] -gt 100) { throw 'Unexpected status SOC/SOH.' }
    $current=(Convert-Signed16 $Words[4])*0.1
    $voltage=$Words[5]*0.01
    return [pscustomobject]@{
        Time=$Time; Soc=$Words[0]; Soh=$Words[3]; Current=$current; Voltage=$voltage
        Power=$current*$voltage; Max=$Words[1]*10; Min=$Words[2]*10
        TempMin=(Convert-Signed16 $Words[7]); TempMax=(Convert-Signed16 $Words[6])
        Error=$Words[13]; Words=$Words
    }
}

# UI uses Console methods and (where supported) ANSI; network settings are never touched.
function Start-Display {
    if ($Plain -or [Console]::IsOutputRedirected) { return }
    if ($Host.Name -ne 'ConsoleHost') { throw 'Use a normal PowerShell console, not ISE or an editor host.' }
    $State.UiReady=$true
    try { $script:OriginalCtrlC=[Console]::TreatControlCAsInput; [Console]::TreatControlCAsInput=$true } catch {}
    try { $script:CursorSaved=[Console]::CursorVisible; [Console]::CursorVisible=$false } catch {}
    try { $script:ForegroundSaved=[Console]::ForegroundColor; $script:BackgroundSaved=[Console]::BackgroundColor } catch {}
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        try {
            if ($null -eq ('BydLiveV11.ConsoleVt' -as [type])) {
                Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace BydLiveV11 {
    public static class ConsoleVt {
        [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr GetStdHandle(int n);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetConsoleMode(IntPtr h,out uint mode);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetConsoleMode(IntPtr h,uint mode);
        static IntPtr handle; static uint original; static bool changed;
        public static bool Enable() {
            handle=GetStdHandle(-11);
            if (!GetConsoleMode(handle,out original)) return false;
            changed=SetConsoleMode(handle,original | 4u);
            return changed;
        }
        public static void Restore() { if(changed) SetConsoleMode(handle,original); changed=false; }
    }
}
'@ | Out-Null
            }
            $State.Ansi=[BydLiveV11.ConsoleVt]::Enable()
            $script:VtSaved=$State.Ansi
        } catch { $State.Ansi=$false }
    } else { $State.Ansi=$true }
    if ($State.Ansi) { [Console]::Write($esc+'[?1049h'+$esc+'[?25l'+$esc+'[2J'+$esc+'[H') }
    else { try { [Console]::Clear() } catch {} }
}
function Stop-Display {
    if ($State.UiReady) {
        if ($State.Ansi) { [Console]::Write($esc+'[0m'+$esc+'[?25h'+$esc+'[?1049l') }
        if ($script:VtSaved) { try { [BydLiveV11.ConsoleVt]::Restore() } catch {} }
        if ($null -ne $script:CursorSaved) { try { [Console]::CursorVisible=$script:CursorSaved } catch {} }
        if ($null -ne $script:OriginalCtrlC) { try { [Console]::TreatControlCAsInput=$script:OriginalCtrlC } catch {} }
        if ($null -ne $script:ForegroundSaved) { try { [Console]::ForegroundColor=$script:ForegroundSaved; [Console]::BackgroundColor=$script:BackgroundSaved } catch {} }
    }
}
function Paint([string]$Text,[int]$Colour=37,[switch]$Reverse) {
    if (-not $State.Ansi) { return $Text }
    $mode = if ($Reverse) { '7;' } else { '' }
    return ($esc+'['+$mode+$Colour+'m'+$Text+$esc+'[0m')
}
function Strip-Ansi([string]$Text) { return [regex]::Replace($Text,'\x1B\[[0-?]*[ -/]*[@-~]','') }
function Fit-Line([string]$Text,[int]$Width) {
    if ($Width -lt 1) { return '' }
    $plainText=Strip-Ansi $Text
    if ($plainText.Length -gt $Width) { return $plainText.Substring(0,$Width) }
    return $Text+(' '*($Width-$plainText.Length))
}
function Get-CellColour([int]$Value,[double]$Median) {
    $d=[Math]::Abs($Value-$Median)
    if ($d -ge $Settings.Highlight3_mV) { return 91 }
    if ($d -ge $Settings.Highlight2_mV) { return 93 }
    if ($d -ge $Settings.Highlight1_mV) { return 96 }
    return 37
}
function New-TowerPanel([int]$Tower,[bool]$Numeric,[int]$PanelWidth) {
    $p=[Collections.Generic.List[string]]::new()
    $d=$State.Towers[$Tower]
    if ($null -eq $d) {
        $p.Add((Paint "TOWER $Tower | awaiting first capture" 96))
        for($i=0;$i -lt 14;$i++) { $p.Add('') }
        return ,$p.ToArray()
    }
    $age=Get-Age $d.ReceivedAt
    $ageColour=if ($age -gt $Settings.StaleSeconds) {91} else {37}
    $tag=if($age -gt $Settings.StaleSeconds){' STALE DATA'}else{''}
    if($State.FailedTowers.ContainsKey($Tower)) { $tag=' TIMEOUT (stale)' ; $ageColour=91 }
    $masterTag=if($Tower -eq 1){' MASTER'}else{''}
    $p.Add((Paint ('TOWER {0}{1} | SOC {2}% | {3}s{4}' -f $Tower,$masterTag,(Format-Num $d.Soc),(Format-Num $age '0'),$tag) $ageColour))
    $sn=if([string]::IsNullOrWhiteSpace($d.Serial)){'SN NOT DECODED'}else{$d.Serial}
    $p.Add(('SN '+$sn))
    $p.Add(('Min {0}  Max {1}  d {2} mV' -f $d.Min,$d.Max,$d.Delta))
    $p.Add(('v M{0}/C{1:00} ^ M{2}/C{3:00} median {4}' -f $d.MinModule,$d.MinCell,$d.MaxModule,$d.MaxCell,(Format-Num $d.Median '0')))
    $p.Add(('I {0}A P {1}W Cal 0x{2:X2}' -f (Format-Num $d.Current),(Format-Num ($d.Current*$d.Voltage) '0'),$d.SocCalibrationRaw))
    $wc=if(($d.Warning1 -bor $d.Warning2 -bor $d.Warning3 -bor $d.Fault) -ne 0){93}else{37}
    $p.Add((Paint ('W {0:X4}/{1:X4}/{2:X4} F {3:X4}' -f $d.Warning1,$d.Warning2,$d.Warning3,$d.Fault) $wc))
    if ($Numeric) {
        $heading='    '+((1..16 | ForEach-Object {' {0,4}' -f $_}) -join '')+'  d mV'
        $p.Add($heading)
        foreach($m in $d.Modules) {
            $row='M{0}  ' -f $m.Number
            for($c=0;$c -lt 16;$c++) {
                $index=($m.Number-1)*16+$c
                $text='{0,5}' -f $m.Cells[$c]
                $isMin=($index -eq $d.MinIndex); $isMax=($index -eq $d.MaxIndex)
                $colour=if($isMin -and $isMax){95}elseif($isMin){96}elseif($isMax){92}else{Get-CellColour $m.Cells[$c] $d.Median}
                $row+=Paint $text $colour -Reverse:($isMin -or $isMax)
            }
            $row+=('  {0,4}' -f $m.Delta)
            $p.Add($row)
        }
    } else {
        $p.Add('    1234567890123456  d mV    mean')
        foreach($m in $d.Modules) {
            $row='M{0}  ' -f $m.Number
            for($c=0;$c -lt 16;$c++) {
                $index=($m.Number-1)*16+$c
                $isMin=($index -eq $d.MinIndex); $isMax=($index -eq $d.MaxIndex)
                $glyph=if($isMin -and $isMax){'X'}elseif($isMin){'v'}elseif($isMax){'^'}else{'#'}
                $colour=if($isMin -and $isMax){95}elseif($isMin){96}elseif($isMax){92}else{Get-CellColour $m.Cells[$c] $d.Median}
                $row+=Paint $glyph $colour -Reverse:($isMin -or $isMax)
            }
            $row+=(' {0,5} {1,7}' -f $m.Delta,(Format-Num $m.Average '0'))
            $p.Add($row)
        }
    }
    return ,$p.ToArray()
}
function Show-Dashboard {
    if (-not $State.UiReady) { return }
    $width=[Math]::Max(1,[Console]::WindowWidth-1)
    $height=[Math]::Max(4,[Console]::WindowHeight-1)
    $rows=[Collections.Generic.List[string]]::new()
    $mode=if($Demo){'DEMO / SIMULATED DATA'}else{'LIVE / DIRECT LAN'}
    $colour=if($Demo){93}else{96}
    $rows.Add((Paint ('BYD HVM LIVE v{0} | {1} | {2} | {3}:{4}' -f $AppVersion,$mode,(Get-Date -Format 'HH:mm:ss'),$Ip,$Port) $colour))
    $b=$State.Status
    if($null -ne $b) {
        $rows.Add(('System SOC {0}% | SOH {1}% | {2} V | {3} A | ~{4} W | {5}..{6} C' -f
            $b.Soc,$b.Soh,(Format-Num $b.Voltage '0.00'),(Format-Num $b.Current),(Format-Num $b.Power '0'),$b.TempMin,$b.TempMax))
        $rows.Add(('System age {0}s | fault 0x{1:X4} | negative current = charging' -f (Format-Num (Get-Age $b.Time) '0'),$b.Error))
    } else { $rows.Add('System status: awaiting first response'); $rows.Add('') }
    $rows.Add(('Sweep {0} | {1} | previous sweep {2}s | target interval {3}s' -f $State.Scan,$State.Stage,(Format-Num $State.LastSweepSeconds),$ScanSeconds))
    $summary=''; $currents=''; $allPresent=$true; $sum=0.0
    for($t=1;$t -le $ExpectedTowers;$t++) {
        $d=$State.Towers[$t]
        if($null -eq $d){$summary+="T${t}: ---   ";$allPresent=$false;continue}
        $label=if($t -eq 1){'T1*'}else{'T'+$t}
        $summary+=('{0}: {1}% / d{2}mV / {3}s   ' -f $label,(Format-Num $d.Soc),$d.Delta,(Format-Num (Get-Age $d.ReceivedAt) '0'))
        $currents+=('{0} {1}A {2}W   ' -f $label,(Format-Num $d.Current),(Format-Num ($d.Current*$d.Voltage) '0'))
        $sum+=$d.Current
    }
    $rows.Add($summary)
    $rows.Add(('Communication: OK {0} | errors {1} | {2}' -f (($State.SuccessfulTowers.Values | Measure-Object -Sum).Sum),$State.CommunicationErrors,$State.Stage))
    if($currents -ne ''){$rows.Add('Tower current/power: '+$currents)}
    if($null -ne $b -and $allPresent -and $State.FailedTowers.Count -eq 0){
        # BMU and tower readings are sequential, not exactly simultaneous.
        $rows.Add(('Sum {0} A | BMU {1} A | difference {2} A (sequential samples)' -f (Format-Num $sum),(Format-Num $b.Current),(Format-Num ($sum-$b.Current))))
    }
    $watch=$null
    foreach($entry in @($State.Towers.Values)) { if($entry.Serial -eq $WatchSerial){$watch=$entry;break} }
    if($null -ne $watch) {
        $wi=16*($WatchModule-1)+$WatchCell-1
        $wv=$watch.Cells[$wi]
        $change=if($null -ne $State.WatchFirst){$wv-[int]$State.WatchFirst}else{0}
        $rows.Add((Paint ('WATCH SN ...{0} M{1}/C{2}: {3} mV | since start {4:+0;-0;0} mV | age {5}s' -f
            $WatchSerial.Substring([Math]::Max(0,$WatchSerial.Length-4)),$WatchModule,$WatchCell,$wv,$change,(Format-Num (Get-Age $watch.ReceivedAt) '0')) 95))
    } else { $rows.Add(('Watch: {0} M{1}/C{2} - waiting for matching SN' -f $WatchSerial,$WatchModule,$WatchCell)) }
    $rows.Add('')
    $numeric=[bool]$State.Numbers
    if($numeric -and $width -lt 94) {$numeric=$false}
    $panelHeight=7+$ModulesPerTower
    $availableHeight=$height-$rows.Count-4
    $focus=[int]$State.Focus
    $across=($width -ge (37*$ExpectedTowers+2*($ExpectedTowers-1)) -and -not $numeric -and $focus -eq 0)
    $stackAll=($focus -eq 0 -and -not $across -and $availableHeight -ge (($panelHeight+1)*$ExpectedTowers))
    if($across) {
        $pw=[int][Math]::Floor(($width-2*($ExpectedTowers-1))/$ExpectedTowers)
        $panels=@{}
        for($t=1;$t -le $ExpectedTowers;$t++){ $panels[$t]=New-TowerPanel $t $false $pw }
        for($line=0;$line -lt $panelHeight;$line++) {
            $parts=@()
            for($t=1;$t -le $ExpectedTowers;$t++) {
                $text=if($line -lt $panels[$t].Length){$panels[$t][$line]}else{''}
                $parts+=Fit-Line $text $pw
            }
            $rows.Add(($parts -join '  '))
        }
    } elseif($stackAll) {
        for($t=1;$t -le $ExpectedTowers;$t++) {
            foreach($line in (New-TowerPanel $t $numeric $width)){$rows.Add($line)}
            if($t -lt $ExpectedTowers){$rows.Add('')}
        }
    } else {
        if($focus -eq 0) {$focus=1+([int][Math]::Floor(([DateTime]::UtcNow-$State.Started).TotalSeconds/8)%$ExpectedTowers)}
        $label=if($State.Focus -eq 0){'rotating view; widen console to show all towers'}else{'fixed tower view'}
        $rows.Add(('Showing T{0}: {1}. All towers are still captured and logged.' -f $focus,$label))
        foreach($line in (New-TowerPanel $focus $numeric $width)){$rows.Add($line)}
    }
    $footer=[Collections.Generic.List[string]]::new()
    $footer.Add((Paint 'Color = |cell - tower median|: ' 37)+(Paint '<20 ' 37)+(Paint '20-49 ' 96)+(Paint '50-99 ' 93)+(Paint '>=100 mV' 91))
    $footer.Add('Cal = raw SOC calibration (high byte of word 18; meaning unknown). v = lowest, ^ = highest. T1* master.')
    $footer.Add('Timeout: skipped capture; stale tower data is NOT live. Diagnostic selection uses FC16.')
    $footer.Add('Q/Ctrl+C quit | H heatmap | N cell mV | A auto | 1/2/3 tower | no charging commands')
    $footer.Add(('Logs: '+$State.LogPath))
    if($rows.Count+$footer.Count -gt $height) {
        $keep=[Math]::Max(1,$height-$footer.Count-1)
        while($rows.Count -gt $keep){$rows.RemoveAt($rows.Count-1)}
        $rows.Add('WINDOW TOO SHORT: increase height to see all cells; all cells are logged.')
    }
    foreach($f in $footer){$rows.Add($f)}
    $textLines=@($rows | ForEach-Object {Fit-Line $_ $width})
    while($textLines.Count -lt $height){$textLines+=(' '*$width)}
    if($State.Ansi) {
        [Console]::Write($esc+'[H'+($textLines -join "`r`n")+$esc+'[0m')
    } else {
        try {
            [Console]::SetCursorPosition(0,0)
            [Console]::Write(($textLines -join [Environment]::NewLine))
        } catch { # A resize can invalidate cursor coordinates; try again next refresh.
        }
    }
}
function Invoke-Tick([switch]$Force) {
    if($State.UiReady -and ([DateTime]::UtcNow-$State.LastKeyCheck).TotalMilliseconds -ge 75) {
        $State.LastKeyCheck=[DateTime]::UtcNow
        while([Console]::KeyAvailable) {
            $key=[Console]::ReadKey($true)
            $keyText=$key.Key.ToString()
            if($keyText -eq 'Q' -or ($keyText -eq 'C' -and (($key.Modifiers -band [ConsoleModifiers]::Control) -ne 0))) {
                $State.StopRequested=$true
            } elseif($keyText -eq 'N') {$State.Numbers=$true}
            elseif($keyText -eq 'H') {$State.Numbers=$false}
            elseif($keyText -eq 'A') {$State.Focus=0}
            elseif([string]$key.KeyChar -match '^[1-3]$') {
                $v=[int]::Parse([string]$key.KeyChar)
                if($v -le $ExpectedTowers){$State.Focus=$v}
            }
        }
    }
    if($State.StopRequested) { throw [OperationCanceledException]::new('Stopped by user.') }
    if($Force -or ([DateTime]::UtcNow-$State.LastPaint).TotalSeconds -ge $RefreshSeconds) {
        $State.LastPaint=[DateTime]::UtcNow
        Show-Dashboard
    }
}
function Wait-Ui([int]$Milliseconds) {
    $timer=[Diagnostics.Stopwatch]::StartNew()
    while($timer.ElapsedMilliseconds -lt $Milliseconds) {
        Invoke-Tick
        Start-Sleep -Milliseconds ([Math]::Min(50,[Math]::Max(1,$Milliseconds-[int]$timer.ElapsedMilliseconds)))
    }
}

# Single in-flight request. BeginRead allows the screen and Q key to keep working.
function Read-Exact([int]$Count,[Diagnostics.Stopwatch]$Deadline) {
    [byte[]]$buffer=New-Object byte[] $Count
    $offset=0
    while($offset -lt $Count) {
        $async=$script:Stream.BeginRead($buffer,$offset,$Count-$offset,$null,$null)
        try {
            while(-not $async.AsyncWaitHandle.WaitOne(50)) {
                Invoke-Tick
                if($Deadline.ElapsedMilliseconds -gt $Settings.FrameTimeoutMs) { throw 'TCP frame timeout; capture stopped.' }
            }
            $n=$script:Stream.EndRead($async)
            if($n -le 0){throw 'BYD closed the TCP connection.'}
            $offset+=$n
        } finally { $async.AsyncWaitHandle.Close() }
    }
    return ,$buffer
}
function Send-Request([byte[]]$Body,[int]$Function) {
    [byte[]]$sent=Add-Crc $Body
    $reg=([int]$Body[2] -shl 8) -bor [int]$Body[3]
    $label='FC{0:X2} @0x{1:X4}' -f $Function,$reg
    $trace=[pscustomobject]@{Time=[DateTime]::UtcNow.ToString('o');Operation=$label;Sent=[BitConverter]::ToString($sent);Received=$null}
    $State.Trace.Add($trace)
    $script:Stream.Write($sent,0,$sent.Length)
    $timer=[Diagnostics.Stopwatch]::StartNew()
    [byte[]]$head=Read-Exact 3 $timer
    if($head[0] -ne 1){throw "$label returned an unexpected unit ID."}
    [byte[]]$frame=$null
    if($head[1] -eq ($Function -bor 128)) {
        [byte[]]$tail=Read-Exact 2 $timer
        [byte[]]$frame=@($head)+@($tail)
        $trace.Received=[BitConverter]::ToString($frame)
        Assert-FrameCrc $frame
        throw ('{0}: Modbus exception {1}. No automatic retry.' -f $label,$head[2])
    }
    if($head[1] -ne $Function){throw "$label returned an unexpected function."}
    if($Function -eq 3) {
        $expectedCount=([int]$Body[4] -shl 8) -bor [int]$Body[5]
        if($head[2] -ne 2*$expectedCount){throw "$label returned an unexpected byte count."}
        [byte[]]$tail=Read-Exact ($head[2]+2) $timer
        [byte[]]$frame=@($head)+@($tail)
    } elseif($Function -eq 16) {
        [byte[]]$tail=Read-Exact 5 $timer
        [byte[]]$frame=@($head)+@($tail)
    } else {throw 'Unsupported function.'}
    $trace.Received=[BitConverter]::ToString($frame)
    Assert-FrameCrc $frame
    if($Function -eq 16) {
        for($i=2;$i -le 5;$i++){if($frame[$i] -ne $Body[$i]){throw 'FC16 acknowledgement mismatch.'}}
        return
    }
    [int[]]$words=New-Object int[] $expectedCount
    for($i=0;$i -lt $expectedCount;$i++){$words[$i]=([int]$frame[3+2*$i] -shl 8) -bor [int]$frame[4+2*$i]}
    return ,$words
}
function Read-Registers([int]$Address,[int]$Count) {
    # Prevent accidental probes of undocumented register ranges.
    $allowed=(($Address -eq 0 -and $Count -eq 102) -or
        ($Address -eq 0x0500 -and $Count -eq 25) -or
        ($Address -eq 0x0551 -and $Count -eq 1) -or
        ($Address -eq 0x0558 -and $Count -eq 65))
    if(-not $allowed){throw 'Read request rejected by the local whitelist.'}
    [byte[]]$body=1,3,[byte](($Address -shr 8) -band 255),[byte]($Address -band 255),[byte](($Count -shr 8) -band 255),[byte]($Count -band 255)
    return ,(Send-Request $body 3)
}
function Select-TowerDiagnostics([int]$Tower) {
    if($Tower -lt 1 -or $Tower -gt $ExpectedTowers){throw 'Tower request out of range.'}
    # The ONLY FC16 write in this program. No generic write function is exposed.
    [byte[]]$body=1,16,5,80,0,2,4,0,[byte]$Tower,129,0
    Send-Request $body 16
}
function Open-Connection {
    $State.Stage='Connecting directly to BYD'
    Invoke-Tick -Force
    $script:Tcp=[Net.Sockets.TcpClient]::new()
    $script:Tcp.NoDelay=$true
    $async=$script:Tcp.BeginConnect($Ip,$Port,$null,$null)
    $timer=[Diagnostics.Stopwatch]::StartNew()
    try {
        while(-not $async.AsyncWaitHandle.WaitOne(50)) {
            Invoke-Tick
            if($timer.ElapsedMilliseconds -gt $Settings.ConnectTimeoutMs){throw 'BYD TCP connect timeout.'}
        }
        $script:Tcp.EndConnect($async)
    } finally {$async.AsyncWaitHandle.Close()}
    $script:Stream=$script:Tcp.GetStream()
    $script:Stream.ReadTimeout=$Settings.FrameTimeoutMs
    $script:Stream.WriteTimeout=$Settings.FrameTimeoutMs
}
function Capture-Tower([int]$Tower) {
    $State.Trace.Clear()
    $requested=[DateTime]::UtcNow
    $State.Stage="T$Tower requesting diagnostics"
    Invoke-Tick
    Select-TowerDiagnostics $Tower
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $ready=$false
    while($timer.ElapsedMilliseconds -lt $Settings.DiagnosticTimeoutMs) {
        Wait-Ui $Settings.PollDelayMs
        [int[]]$status=Read-Registers 0x0551 1
        $State.Stage=('T{0} waiting, status 0x{1:X4}' -f $Tower,$status[0])
        if($status[0] -eq 0x8801){$ready=$true;break}
        if($status[0] -ne 0x8100){throw ('Unexpected diagnostic status 0x{0:X4} on T{1}; stopped.' -f $status[0],$Tower)}
    }
    if(-not $ready){throw "Tower $Tower diagnostic-ready timeout."}
    $words=[Collections.Generic.List[int]]::new()
    for($chunk=1;$chunk -le 4;$chunk++) {
        $State.Stage="T$Tower reading packet $chunk/4"
        Invoke-Tick
        [int[]]$block=Read-Registers 0x0558 65
        if($block.Length -ne 65 -or $block[0] -ne 128){throw "Invalid T$Tower chunk $chunk length."}
        for($i=1;$i -lt 65;$i++){$words.Add($block[$i])}
    }
    $received=[DateTime]::UtcNow
    Write-Raw ([ordered]@{Type='Tower';Scan=$State.Scan;Tower=$Tower;RequestedAt=$requested.ToString('o');ReceivedAt=$received.ToString('o');Words=$words.ToArray();Frames=$State.Trace.ToArray()})
    return (Convert-Tower $words.ToArray() $Tower $requested $received)
}
function Reset-Transport {
    if($null -ne $script:Stream){try{$script:Stream.Dispose()}catch{}}
    if($null -ne $script:Tcp){try{$script:Tcp.Dispose()}catch{}}
    $script:Stream=$null; $script:Tcp=$null
    $State.ConnectionBroken=$true
    $State.ReconnectAfter=[DateTime]::UtcNow.AddSeconds($Settings.ReconnectCooldownSeconds)
}
function Register-CommunicationFailure([string]$Component,[string]$Message,[int]$Tower=0) {
    $State.CommunicationErrors++
    $now=[DateTime]::UtcNow
    if($Tower -gt 0) {
        if(-not $State.TowerFailures.ContainsKey($Tower)){$State.TowerFailures[$Tower]=0}
        $State.TowerFailures[$Tower]++
        $State.FailedTowers[$Tower]=$now.AddSeconds($Settings.RetryCooldownSeconds)
    }
    $line=('{0} {1}: {2}' -f $now.ToString('o'),$Component,$Message)
    $State.Stage=('Communication failure {0}; waiting before retry' -f $Component)
    if($null -ne $State.ErrorWriter){$State.ErrorWriter.WriteLine($line)}
    try{Write-Raw ([ordered]@{Type='CommunicationError';At=$now.ToString('o');Component=$Component;Message=$Message;Frames=$State.Trace.ToArray()})}catch{}
    # A timeout may leave an unfinished RTU-over-TCP frame. Discard the stream
    # before any subsequent request, rather than immediately repeating FC16.
    Reset-Transport
}
function Wait-For-Reconnect {
    if(-not $State.ConnectionBroken){return $true}
    if([DateTime]::UtcNow -lt $State.ReconnectAfter){return $false}
    try{Open-Connection; $State.ConnectionBroken=$false; return $true}
    catch{
        $State.CommunicationErrors++
        if($null -ne $State.ErrorWriter){$State.ErrorWriter.WriteLine(('{0} RECONNECT: {1}' -f [DateTime]::UtcNow.ToString('o'),$_.Exception.Message))}
        Reset-Transport
        return $false
    }
}
function Capture-Status {
    $State.Stage='Reading system status'
    $State.Trace.Clear()
    [int[]]$words=Read-Registers 0x0500 25
    $time=[DateTime]::UtcNow
    Write-Raw ([ordered]@{Type='Status';ReceivedAt=$time.ToString('o');Words=$words;Frames=$State.Trace.ToArray()})
    $State.Status=Convert-Status $words $time
    Save-Status
}

function Write-Raw($Object) {
    if($null -ne $State.RawWriter){$State.RawWriter.WriteLine(($Object|ConvertTo-Json -Depth 10 -Compress))}
}
function Csv-Value($Value) {
    if($null -eq $Value){return ''}
    if($Value -is [DateTime]){$s=$Value.ToString('o')}
    elseif($Value -is [IFormattable]){$s=$Value.ToString($null,$inv)}
    else{$s=[string]$Value}
    return '"'+$s.Replace('"','""')+'"'
}
function Save-Status {
    if($null -eq $State.StatusWriter){return}
    $b=$State.Status
    $row=@($b.Time,$State.Scan,$b.Soc,$b.Soh,$b.Voltage,$b.Current,$b.Power,$b.Min,$b.Max,$b.TempMin,$b.TempMax,('0x{0:X4}' -f $b.Error))
    $State.StatusWriter.WriteLine((@($row|ForEach-Object{Csv-Value $_}) -join ';'))
}
function Publish-Tower($TowerData) {
    $previous=$State.Towers[$TowerData.Tower]
    if($null -ne $previous) {
        if($previous.Serial -ne $TowerData.Serial){throw 'BMS serial changed during this session. Capture stopped.'}
    }
    foreach($other in @($State.Towers.Values)) {
        if($other.Tower -ne $TowerData.Tower -and $TowerData.Serial -ne '' -and $other.Serial -eq $TowerData.Serial){throw 'Duplicate BMS serial across tower responses. Capture stopped.'}
    }
    $State.Towers[$TowerData.Tower]=$TowerData
    if($State.FailedTowers.ContainsKey($TowerData.Tower)) { [void]$State.FailedTowers.Remove($TowerData.Tower) }
    if(-not $State.SuccessfulTowers.ContainsKey($TowerData.Tower)){$State.SuccessfulTowers[$TowerData.Tower]=0}
    $State.SuccessfulTowers[$TowerData.Tower]++
    $State.Samples++
    if($TowerData.Serial -eq $WatchSerial) {
        $value=$TowerData.Cells[16*($WatchModule-1)+$WatchCell-1]
        if($null -eq $State.WatchFirst){$State.WatchFirst=$value}
        $State.WatchHistory.Add([pscustomobject]@{Time=$TowerData.ReceivedAt;Value=$value})
        if($State.WatchHistory.Count -gt 120){$State.WatchHistory.RemoveAt(0)}
    }
    $r=$TowerData
    $row=@($r.ReceivedAt,$r.RequestedAt,$r.CaptureSeconds,$r.Scan,$r.Tower,$r.Serial,$r.Soc,$r.SocCalibrationRaw,$r.Current,($r.Current*$r.Voltage),$r.Voltage,$r.Min,$r.Max,$r.Delta,$r.MinModule,$r.MinCell,
        ('0x{0:X4}' -f $r.Warning1),('0x{0:X4}' -f $r.Warning2),('0x{0:X4}' -f $r.Warning3),('0x{0:X4}' -f $r.Fault),$r.TempMin,$r.TempMax)+@($r.Cells)
    if($null -ne $State.CsvWriter){$State.CsvWriter.WriteLine((@($row|ForEach-Object{Csv-Value $_}) -join ';'))}
    if(-not $State.UiReady){
        Write-Host ('{0} T{1} SN {2} SOC {3}% min/max {4}/{5}mV d{6} M{7}/C{8} ({9}s)' -f
            (Get-Date -Format 'HH:mm:ss'),$r.Tower,$r.Serial,(Format-Num $r.Soc),$r.Min,$r.Max,$r.Delta,$r.MinModule,$r.MinCell,(Format-Num $r.CaptureSeconds))
    }
    Invoke-Tick -Force
}
function Save-FullSnapshot {
    $towers=[ordered]@{}; $times=[ordered]@{}
    for($t=1;$t -le $ExpectedTowers;$t++) {
        $d=$State.Towers[$t]
        if($null -eq $d -or $d.Scan -ne $State.Scan){return}
        $towers[[string]$t]=$d.Words
        $times[[string]$t]=[ordered]@{RequestedAt=$d.RequestedAt.ToString('o');ReceivedAt=$d.ReceivedAt.ToString('o');Serial=$d.Serial}
    }
    $obj=[ordered]@{
        Time=[DateTime]::UtcNow.ToString('o');Host=$Ip;Port=$Port;Mode='Deep';Demo=[bool]$Demo;Scan=$State.Scan
        Note='Towers sampled sequentially; use TowerTimes. Logical positions only; not verified module serials.'
        Blocks=[ordered]@{Config=$State.Config;Status=$State.Status.Words};Towers=$towers;TowerTimes=$times;Errors=@()
    }
    $json=$obj|ConvertTo-Json -Depth 10
    $latest=Join-Path $State.LogPath 'snapshot-latest.json'
    $temp=Join-Path $State.LogPath 'snapshot-latest.tmp'
    [IO.File]::WriteAllText($temp,$json,[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $latest -Force
    if($script:FullSnapshotCount -eq 0){[IO.File]::WriteAllText((Join-Path $State.LogPath 'snapshot-start.json'),$json,[Text.UTF8Encoding]::new($false))}
    $script:FullSnapshotCount++
}
function Open-Logs {
    if([string]::IsNullOrWhiteSpace($OutputDirectory)) {
        $desktop=[Environment]::GetFolderPath('Desktop')
        if([string]::IsNullOrWhiteSpace($desktop)){$desktop=Join-Path $HOME 'Desktop'}
        $root=Join-Path $desktop 'BYD-Diagnostik'
    } else {$root=$OutputDirectory}
    $prefix=if($Demo){'DEMO-'}else{'LIVE-'}
    $State.LogPath=Join-Path $root ($prefix+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+([guid]::NewGuid().ToString('N').Substring(0,6)))
    [void][IO.Directory]::CreateDirectory($State.LogPath)
    $encoding=[Text.UTF8Encoding]::new($true)
    foreach($name in @('Csv','Status','Raw','Error')) {
        $fileName=switch($name){'Csv'{'cells.csv'} 'Status'{'system.csv'} 'Raw'{'raw.ndjson'} 'Error'{'errors.log'}}
        $writer=[IO.StreamWriter]::new((Join-Path $State.LogPath $fileName),$false,$encoding)
        $writer.AutoFlush=$true
        $State[$name+'Writer']=$writer
    }
    $headers=@('ReceivedAtUTC','RequestedAtUTC','CaptureSeconds','Scan','LogicalTower','BmsSerialField','SOC_pct','SOC_Calibration_Raw_HighByte_Word18','TowerCurrent_A','TowerPower_W','TowerCellSumVoltage_V','Min_mV','Max_mV','Spread_mV','LowestLogicalModule','LowestCell',
        'Warning1_raw','Warning2_raw','Warning3_raw','Fault_raw','TempMin_C','TempMax_C')
    for($m=1;$m -le $ModulesPerTower;$m++){for($c=1;$c -le 16;$c++){$headers+=('M{0:00}_C{1:00}_mV' -f $m,$c)}}
    $State.CsvWriter.WriteLine(($headers -join ';'))
    $State.StatusWriter.WriteLine('ReceivedAtUTC;Scan;SOC_pct;SOH_pct;Voltage_V;Current_A;EstimatedPower_W;Min_mV;Max_mV;TempMin_C;TempMax_C;Error_raw')
    $info=@"
BYD-HVM-Live $AppVersion
Mode: $(if($Demo){'SIMULATED DEMO - NOT BATTERY DATA'}else{'LIVE'})
Target: ${Ip}:$Port
Started UTC: $($State.Started.ToString('o'))
Expected towers: $ExpectedTowers; modules/tower: $ModulesPerTower; cells/module: 16
Full scan target interval: $ScanSeconds seconds; display refresh: $RefreshSeconds seconds.
All three towers are sampled sequentially, not simultaneously.
ReceivedAtUTC is when the PC completed the read, NOT a verified BMS sample timestamp.
Diagnostics might internally reuse/cached measurements; repeating a request does not prove 1 Hz ADC updates.
Only FC03 reads plus the FC16 diagnostic selector at 0x0550 are used.
No BMS configuration, firmware, charge settings or Windows network settings are changed.
CSV: semicolon-delimited, invariant decimal point, cell voltages as integer mV.
raw.ndjson stores payloads and CRC-checked frames. Each line is independent JSON.
snapshot-start.json and snapshot-latest.json are complete sequential sweeps.
BMS serial is not the individual module serial. Tower 1 is verified as master by user. Module/cell indices are logical.
Display colours show distance from tower median; lowest/highest cell blocks use cyan/green reverse video. NOT BYD alarm criteria.
The Min/Diff sparkline rows are deliberately removed; raw data remains logged.
Do not infer cell health from this monitor alone. It does not stop or control battery charging.
"@
    [IO.File]::WriteAllText((Join-Path $State.LogPath 'session.txt'),$info,[Text.UTF8Encoding]::new($true))
}

function New-DemoWords([int]$Tower,[int]$Step) {
    [int[]]$words=New-Object int[] 256
    $serials=@('DEMO000000000000001','DEMO000000000000002','DEMO000000000000003')
    $serial=$serials[$Tower-1]
    [byte[]]$bytes=New-Object byte[] 512
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes($serial),0,$bytes,66,19)
    for($i=0;$i -lt 256;$i++){$words[$i]=([int]$bytes[2*$i] -shl 8) -bor [int]$bytes[2*$i+1]}
    $base=3050+[Math]::Min(230,$Step*4)
    for($i=0;$i -lt $State.CellCount;$i++){$words[48+$i]=[int]$base+(($i*7+$Tower*3)%31)-15}
    if($Tower -eq 1) {
        for($i=0;$i -lt 16;$i++){$words[48+$i]=3150+[Math]::Min(140,$Step*2)+($i%5)}
        $words[48+16*($WatchModule-1)+$WatchCell-1]=2813+[Math]::Min(500,$Step*7)
    }
    $words[24]=[Math]::Min(1000,($Tower-1)*100+$Step*7)
    $words[26]=65536-(10+$Tower)
    $words[3]=26; $words[4]=20; $words[27]=8
    return ,$words
}
function Run-SelfTest {
    $tests=0
    $frame=Add-Crc ([byte[]](1,3,5,88,0,65))
    if([BitConverter]::ToString($frame) -ne '01-03-05-58-00-41-04-E5'){throw 'CRC request self-test failed.'};$tests++
    Assert-FrameCrc ([byte[]](1,3,2,0,2,57,133));$tests++
    $bad=[byte[]](1,3,2,0,2,57,132);$rejected=$false
    try{Assert-FrameCrc $bad}catch{$rejected=$true}
    if(-not $rejected){throw 'CRC rejection self-test failed.'};$tests++
    [int[]]$w=New-DemoWords 1 0
    $t=Convert-Tower $w 1 ([DateTime]::UtcNow) ([DateTime]::UtcNow)
    if($t.Serial -ne 'DEMO000000000000001'){throw 'Serial field self-test failed.'};$tests++
    if([Math]::Abs($t.Current+1.1) -gt 0.001){throw 'Tower signed current regression failed.'};$tests++
    $w[18]=0xAB34
    $tCal=Convert-Tower $w 1 ([DateTime]::UtcNow) ([DateTime]::UtcNow)
    if($tCal.SocCalibrationRaw -ne 0xAB -or $tCal.SocCalibrationWord -ne 0xAB34){throw 'SOC calibration raw high-byte test failed.'};$tests++
    if($t.Min -ne 2813 -or $t.MinModule -ne $WatchModule -or $t.MinCell -ne $WatchCell){throw 'Cell index self-test failed.'};$tests++
    if($t.Cells.Length -ne 16*$ModulesPerTower -or $t.Modules.Length -ne $ModulesPerTower){throw 'Layout self-test failed.'};$tests++
    [int[]]$s=New-Object int[] 25;$s[0]=14;$s[3]=98;$s[4]=65522;$s[5]=34300
    $st=Convert-Status $s ([DateTime]::UtcNow)
    if([Math]::Abs($st.Current+1.4) -gt 0.00001 -or $st.Voltage -ne 343){throw 'Signed current self-test failed.'};$tests++
    if((Strip-Ansi ($esc+'[91m2813'+$esc+'[0m')) -ne '2813'){throw 'ANSI self-test failed.'};$tests++
    if((Strip-Ansi (Paint 'MAX' 92 -Reverse)) -ne 'MAX'){throw 'Max-cell highlight self-test failed.'};$tests++
    if((Fit-Line 'abcdef' 3) -ne 'abc'){throw 'Screen clipping self-test failed.'};$tests++
    $w[48]=0;$rejected=$false
    try{Convert-Tower $w 1 ([DateTime]::UtcNow) ([DateTime]::UtcNow)|Out-Null}catch{$rejected=$true}
    if(-not $rejected){throw 'Invalid cell rejection self-test failed.'};$tests++

    # Regression tests for the exact v1.0 defect. Use different low bytes,
    # and also prove that an HVS with application=1 must NOT pass the guard.
    [int[]]$cfg=New-Object int[] 102
    $cfg[16]=($ExpectedTowers -shl 4) -bor $ModulesPerTower
    foreach($app in @(0,1,2)) {
        $cfg[17]=(1 -shl 8) -bor $app
        $decodedConfig=Convert-Configuration $cfg
        Assert-HvmConfiguration $decodedConfig
        if($decodedConfig.ModelCode -ne 1 -or $decodedConfig.ApplicationCode -ne $app){throw 'Config byte-order regression failed.'}
        $tests++
    }
    foreach($notHvm in @(0x0201,0x0001,0xFF01)) {
        $cfg[17]=$notHvm
        $rejected=$false
        try{Assert-HvmConfiguration (Convert-Configuration $cfg)}catch{$rejected=$true}
        if(-not $rejected){throw 'Non-HVM model guard regression failed.'}
        $tests++
    }
    $cfg[17]=0x0102
    $cfg[16]=($ExpectedTowers -shl 4) -bor 0
    $rejected=$false
    try{Assert-HvmConfiguration (Convert-Configuration $cfg)}catch{$rejected=$true}
    if(-not $rejected){throw 'Configuration layout guard regression failed.'};$tests++
    $rejected=$false
    try{Convert-Configuration ([int[]](0,0))|Out-Null}catch{$rejected=$true}
    if(-not $rejected){throw 'Configuration length guard regression failed.'};$tests++

    # Exercise the actual framing code with a memory stream, including fragmented
    # reads. The fake Write method records requests rather than contacting a BMS.
    $savedStream=$script:Stream
    try {
        $fake=[pscustomobject]@{Response=$null;Sent=[byte[]]@();ChunkSize=2}
        $fake | Add-Member -MemberType ScriptMethod -Name Write -Value {
            param([byte[]]$Buffer,[int]$Offset,[int]$Count)
            $this.Sent=New-Object byte[] $Count
            [Array]::Copy($Buffer,$Offset,$this.Sent,0,$Count)
        }
        $fake | Add-Member -MemberType ScriptMethod -Name BeginRead -Value {
            param([byte[]]$Buffer,[int]$Offset,[int]$Count,$Callback,$AsyncState)
            return $this.Response.BeginRead($Buffer,$Offset,[Math]::Min($Count,$this.ChunkSize),$Callback,$AsyncState)
        }
        $fake | Add-Member -MemberType ScriptMethod -Name EndRead -Value {
            param($AsyncResult)
            return $this.Response.EndRead($AsyncResult)
        }
        $script:Stream=$fake
        [byte[]]$payload=New-Object byte[] 53
        $payload[0]=1;$payload[1]=3;$payload[2]=50;$payload[4]=2
        [byte[]]$response=Add-Crc $payload
        $fake.Response=[IO.MemoryStream]::new($response,$false)
        [int[]]$decoded=Read-Registers 0x0500 25
        if($decoded.Length -ne 25 -or $decoded[0] -ne 2){throw 'Fragmented FC03 transport self-test failed.'};$tests++
        if([BitConverter]::ToString($fake.Sent) -ne '01-03-05-00-00-19-84-CC'){throw 'FC03 request frame self-test failed.'};$tests++
        $fake.Response.Dispose()
        $fake.Response=[IO.MemoryStream]::new((Add-Crc ([byte[]](1,16,5,80,0,2))),$false)
        Select-TowerDiagnostics 1
        if([BitConverter]::ToString($fake.Sent) -ne '01-10-05-50-00-02-04-00-01-81-00-F8-53'){throw 'FC16 request/ack self-test failed.'};$tests++
        $fake.Response.Dispose()
        $fake.Response=[IO.MemoryStream]::new((Add-Crc ([byte[]](1,131,4))),$false)
        $rejected=$false
        try{Read-Registers 0x0558 65|Out-Null}catch{if($_.Exception.Message -match 'exception 4'){$rejected=$true}}
        if(-not $rejected){throw 'Modbus exception frame self-test failed.'};$tests++
        $rejected=$false
        try{Read-Registers 0x1000 1|Out-Null}catch{if($_.Exception.Message -match 'whitelist'){$rejected=$true}}
        if(-not $rejected){throw 'Read whitelist self-test failed.'};$tests++
        $fake.Response.Dispose()
    } finally { $script:Stream=$savedStream }
    Write-Host "SELFTEST OK: $tests checks. No battery connection; no log files."
}

try {
    if($WatchModule -gt $ModulesPerTower){throw 'WatchModule exceeds ModulesPerTower.'}
    if($SelfTest){Run-SelfTest;return}
    # Fail before opening a socket if built-in offline regression checks fail.
    Run-SelfTest
    $State.Trace.Clear()
    if($CheckOnly -and $Demo){throw 'Use CheckOnly for live configuration or Demo for simulation, not both.'}
    if($CheckOnly){$Plain=$true}
    [Net.IPAddress]$parsed=$null
    if(-not [Net.IPAddress]::TryParse($Ip,[ref]$parsed) -or $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){throw 'Ip must be an IPv4 address.'}
    if(-not $Demo) {
        $mutexName='BYD_HVM_LIVE_'+$Ip.Replace('.','_')+'_'+$Port
        if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){$mutexName='Local\'+$mutexName}
        $script:Mutex=[Threading.Mutex]::new($false,$mutexName)
        try{$script:OwnsMutex=$script:Mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$script:OwnsMutex=$true}
        if(-not $script:OwnsMutex){throw 'Another copy of this live monitor already owns this target.'}
    }
    Open-Logs
    Write-Host 'BYD HVM Live v1.4 -- direct diagnostic capture. No network or charge-setting changes.'
    Write-Host 'Close Be Connect Plus, the old relay and other BYD readers. Q stops the monitor.'
    Write-Host 'Every tower request uses FC16 diagnostic selection; not a write-free protocol.'
    Write-Host ('Logs: '+$State.LogPath)
    Start-Display
    if($Demo) {
        [int[]]$config=New-Object int[] 102;$config[16]=($ExpectedTowers -shl 4) -bor $ModulesPerTower;$config[17]=0x0102
        $State.Config=$config
    } else {