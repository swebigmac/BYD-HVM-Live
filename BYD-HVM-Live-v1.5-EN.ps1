#Requires -Version 5.1
<#
BYD-HVM-Live -- experimental HVM diagnostics; see AppVersion below.
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
The model/layout guard uses R0011 HIGH byte = battery type, LOW = application.
Adds balance selection flags, reported SOH and cumulative energy from the standard
reply. No extended-statistics, history, configuration, reset or firmware requests.
-Demo: explicitly simulated values, no network. Uses separate DEMO log directory.
-Plain: plain-text per-tower output, useful for redirected output / test harnesses.

Decoder basis: BYD-HVM-Analys-4paket.ps1 and BYD-ID-Offline.ps1 in this chat;
Firmware research: 420 meaningful bytes + 92 transport padding; serial bytes 66..89;
SOC word 24; warnings 27..29; legacy raw word 47 is NOT a universal fault flag.
Balance words 6..13; energy 14..17 low-word-first; reported SOH word 25.
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
    [ValidateRange(0,3)][int]$WatchTower = 1,
    [ValidateRange(0,3)][int]$MasterTower = 1,
    [ValidateRange(1,8)][int]$WatchModule = 7,
    [ValidateRange(1,16)][int]$WatchCell = 14,
    [switch]$Numbers,
    [switch]$Plain,
    [switch]$Demo,
    [switch]$SelfTest,
    [switch]$CheckOnly,
    [ValidateRange(0,100000)][int]$MaxScans = 0
)


$AppVersion = '1.5'
$SchemaVersion = 2
$AppScriptName = Split-Path -Leaf $PSCommandPath
# Slash syntax /? and /a.b.c.d is supported as a positional argument in addition
# to PowerShell's standard -Ip, -SelfTest, -Demo etc. No built-in target IP.
function Show-BYDHelp {
    $helpText = @'
BYD HVM LIVE v{VERSION} - HELP AND PROTOCOL REFERENCE
===================================================
EXPERIMENTAL. Independent software; not a BYD safety/control system.
Windows PowerShell 5.1+, normal console (not ISE); administrator rights not needed.

START
  .\{SCRIPT} /?                          Help only; no network or logs
  .\{SCRIPT} /192.0.2.10                 Use YOUR battery IPv4 address
  .\{SCRIPT}                            Prompt for IPv4; no saved/default IP
  .\{SCRIPT} -Ip 192.0.2.10 -Port 8080   Standard PowerShell parameters
  .\{SCRIPT} -SelfTest                   Synthetic offline tests only
  .\{SCRIPT} -Demo -Plain -MaxScans 2    Simulated data, separate DEMO logs
  .\{SCRIPT} -Ip 192.0.2.10 -CheckOnly   Read config and exit; NO FC16
192.0.2.10 is a documentation example, NOT a battery address.
-ExpectedTowers 3 -ModulesPerTower 7 are layout guards, not configuration writes.
Other HVM layouts are experimental; HVS and HVB are not supported by this decoder.
-ScanSeconds 10 is a target sweep interval; -RefreshSeconds 1 redraws the screen.
Slow or failed responses delay sampling. Received times are PC times, not ADC times.
-OutputDirectory selects the PARENT directory for a NEW session directory.
-MasterTower 1 labels a configured/verified master; use 0 if unknown.
-WatchTower 1 -WatchModule 7 -WatchCell 14 watches a logical cell by tower number.
-WatchSerial '<your BMS serial>' selects the watch by identity instead.
-WatchTower 0 disables watching when no WatchSerial is supplied.

KEYS / DISPLAY
  H compact heatmap | N numeric mV | B balance overlay on/off
  A automatic/all towers | 1,2,3 selected tower | Q or Ctrl+C quit
  v / ^ = first minimum / maximum if tied; X = both.
  * = reported balance selection flag. V / A = selected minimum / maximum.
  In numeric view a prefix * marks the flag, independently of min/max highlighting.
  Flags are NOT a measured shunt current, balanced Ah or proof balancing is complete.
  Distance from tower median: <20 white, 20-49 cyan, 50-99 yellow, >=100 red (mV).
  These colours are visualization thresholds, NOT manufacturer alarm limits.
  Prefer at least 116 columns x 35 rows for the three-tower overview.
  Smaller windows show one tower; all configured towers are still read and logged.

WIRE PROTOCOL: MODBUS RTU FRAMES OVER TCP, DEFAULT PORT 8080, UNIT ID 1
This is NOT MBAP-framed Modbus TCP. All addresses below are zero-based wire
register addresses, NOT 4xxxx notation. CRC16 is checked on every response.
  FC03 0x0000, count 102: controller identity/configuration/versions
    0x0000..0x000B: 24-byte controller serial field
    0x0010: LOW byte high nibble=towers; LOW byte low nibble=modules/tower
    0x0011: HIGH byte model (1=HVM, 2=HVS); LOW byte application mode
  FC03 0x0500, count 25: system summary
    0x0500 SOC %, 0x0501 max / 0x0502 min cell: value *10 mV
    0x0503 reported SOH %, 0x0504 signed current *0.1 A
    0x0505 battery voltage *0.01 V
    0x0506 max / 0x0507 min / 0x0508 controller temperature, signed C
    0x050D raw error/status word; 0x0510 output voltage *0.01 V
    0x0511..0x0512 cumulative charge energy, uint32 LOW WORD FIRST *0.1 kWh
    0x0513..0x0514 cumulative discharge energy, same encoding; NOT cycle counts
    Other accepted words preserved raw; not labeled as known measurements.
  FC16 (decimal 16 / hex 0x10) 0x0550, count 2: [tower, 0x8100]
    Select diagnostic data. THIS IS A WRITE. The tool is NOT strictly read-only.
    This selector is the ONLY permitted write. No generic write CLI exists.
  FC03 0x0551, count 1: wait for 0x8801; 0x8100 means still waiting
  FC03 0x0558, count 65: FOUR reads at the SAME address for each tower
    First word=128, followed by 128 bytes. Drop that length word each time.
    The result is 256 words / 512 bytes: 420 meaningful bytes +92 padding in
    the inspected firmware. Do not confuse this with the five-chunk history page.

STANDARD BMS PAYLOAD - W[n] IS A PAYLOAD INDEX, NOT A MODBUS ADDRESS
Each W is big-endian on the wire; composite values can use LOW-WORD-FIRST order.
  W0/W1       max/min cell mV
  W3/W4       max/min temperature, signed C
  W6..W13     128 balance bits: cell i (zero-based) uses bit i%16 in W[6+i/16]
              For HVM 7 modules use only the first112 bits; ignore unused slots.
  W14/W15     charge energy Wh = W14 +65536*W15
  W16/W17     discharge energy Wh = W16 +65536*W17
  W18 HIGH    Cal raw byte; NOT a universal calibration-active boolean
  W20/W23     reported pack/output voltage *0.1 V, NOT cell voltage
  W22         raw switch/control word (not a decoded contactor indicator)
  W24         reported SOC *0.1 percentage point
  W25         reported SOH whole percent; NOT an independent capacity test
  W26         signed current *0.1 A; negative=charging in the verified captures
  W27..W29    warning/status words; preserve all bits
    W27 bit0: upper-string-voltage condition; bit1: lower-string-voltage condition
    W27 bit2: upper-cell-voltage condition; bit3: lower-cell-voltage condition
    Names are firmware-derived descriptions, not official alarm severity levels.
    Higher bits and W28/W29 remain raw. A cleared word is NOT a health guarantee.
  W30..W32    firmware/bank metadata preserved raw; no active-bank guess
  bytes66..89 controller/BMS serial field; NOT individual module serial numbers
  W47         legacy 'Fault_raw' value retained in CSV; UI calls it R47
              The inspected small BMS builder writes zero here. R47=0 is NOT
              proof of no battery faults; consult official BMS/Fronius events.
  W48 onward  actual configured cell count,16 cells per HVM module, integer mV
  bytes354..417 temperature slots; bytes418..419 inner checksum bytes
  bytes420..511 transport padding; inner checksum precedes BMU repacking
Tower power is signed current * sum(cell voltages). Module power uses the same
series current times that module's16-cell sum. Both are calculated approximations,
not separate energy meters or module current sensors. No lifetime module totals.
Cumulative energy is reported BMS history, may be reset, and does not establish
which physical modules were installed throughout that history. Do not 'correct'
the counters or infer exact capacity from differences against sampled power.

RECOVERY / SAFETY
Close other BYD diagnostic readers and Be Connect before connecting. Do not run
during firmware installation. No adapter/DHCP/firewall/charging settings changed.
One request is in flight at a time. On recoverable communication errors discard
the connection and partial sweep, retain STALE last values, wait at least20 s
(with bounded backoff), reconnect and REVALIDATE identity/model/topology.
No immediate blind repeat of FC16. User cancellation and decoder/identity errors
are not swallowed as communication errors. A timeout does not itself prove a
battery defect. The software cannot stop charging or replace battery protection.
Extended0x0698, history0x05A8 and service/reset0x0748 are NOT queried here.

LOGS (CSV schema2; decimal point, semicolon separator)
A fresh LIVE-date-time-id folder is created for every run; old logs stay intact.
  cells.csv      old columns retained; appends SOH, energy, balance masks/bits,
                 reported voltages/status and firmware words. Flags are0 or1.
  modules.csv    module voltage/power estimates, spread and balance-flag count
  system.csv     system measurements plus reported cumulative energy
  raw.ndjson     original diagnostic words, frames and observed state changes
  errors.log     communication/program errors
  snapshot-start/latest.json  complete sequential sweeps, with version metadata
  session.txt    version, parameters and interpretation limitations
AutoFlush writes each completed line; power loss can still lose buffered OS data.
Logs contain serial numbers, local addresses and usage times. Do not publish raw
logs without reviewing/anonymizing them. Gitignore does not redact file contents.

SOURCES / RESEARCH
  https://github.com/sarnau/BYD-Battery-Box-Infos
  https://github.com/christianh17/ioBroker.bydhvs/blob/master/docs/byd-hexstructure.md
Firmware-derived extensions and limits are documented under docs/research.
Per-cell balance flags, energy and tower current were already publicly described;
our work includes implementation and firmware/log validation, not a novelty claim.
'@
    Write-Host ($helpText.Replace('{VERSION}',$AppVersion).Replace('{SCRIPT}',$AppScriptName))
}
# Handle slash arguments before tests, logs or battery access.
if ($Ip -eq '/?' -or $Ip -eq '/help' -or $Ip -eq '--help') { Show-BYDHelp; return }
if ($Ip.StartsWith('/')) { $Ip = $Ip.Substring(1) }
if ([string]::IsNullOrWhiteSpace($Ip) -and -not ($SelfTest -or $Demo)) {
    Write-Host ('BYD HVM Live v{0} - Enter your battery IPv4 address.' -f $AppVersion)
    $Ip = Read-Host 'IPv4 address'
    if (-not [string]::IsNullOrWhiteSpace($Ip)) {
        Write-Host ('TIP: Next time: .\{0} /{1}' -f $AppScriptName,$Ip)
        Write-Host ('Shortcut target: powershell.exe -NoProfile -File "{0}" /{1}' -f $PSCommandPath,$Ip)
        [void](Read-Host 'Press Enter to continue')
    }
}
if ([string]::IsNullOrWhiteSpace($Ip) -and $Demo) { $Ip = '127.0.0.1' }

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
    ShowBalance = $true; ConsecutiveFailures = 0; ControllerIdentity = $null
    Trace = [Collections.Generic.List[object]]::new(); WatchFirst = $null
    WatchHistory = [Collections.Generic.List[object]]::new()
    CellCount = 16*$ModulesPerTower; CsvWriter = $null; StatusWriter = $null
    RawWriter = $null; ErrorWriter = $null; ModuleWriter = $null; LogPath = ''; WatchIdentity = ''
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

function Test-RecoverableError($Record) {
    $e=$Record.Exception
    while($null -ne $e) {
        if($e -is [OperationCanceledException]) { return $false }
        if($e -is [IO.IOException] -or $e -is [Net.Sockets.SocketException] -or $e -is [TimeoutException]) { return $true }
        $e=$e.InnerException
    }
    return $false
}
function Assert-WireRequest([byte[]]$Body,[int]$Function) {
    if($Body.Length -lt 6 -or $Body[0] -ne 1 -or $Body[1] -ne $Function){throw 'Request rejected by local wire whitelist.'}
    $address=([int]$Body[2] -shl 8) -bor [int]$Body[3]
    $count=([int]$Body[4] -shl 8) -bor [int]$Body[5]
    if($Function -eq 3 -and $Body.Length -eq 6) {
        if(($address -eq 0 -and $count -eq 102) -or ($address -eq 0x0500 -and $count -eq 25) -or ($address -eq 0x0551 -and $count -eq 1) -or ($address -eq 0x0558 -and $count -eq 65)){return}
    }
    if($Function -eq 16 -and $Body.Length -eq 11 -and $address -eq 0x0550 -and $count -eq 2 -and $Body[6] -eq 4 -and $Body[7] -eq 0 -and $Body[8] -ge 1 -and $Body[8] -le $ExpectedTowers -and $Body[9] -eq 129 -and $Body[10] -eq 0){return}
    throw 'Request rejected by local wire whitelist.'
}
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
    if ($Frame.Length -lt 5) { throw [IO.IOException]::new('Short Modbus frame.') }
    $got = [int]$Frame[$Frame.Length-2] -bor ([int]$Frame[$Frame.Length-1] -shl 8)
    if ((Get-Crc16 $Frame[0..($Frame.Length-3)]) -ne $got) { throw [IO.IOException]::new('Modbus CRC mismatch.') }
}
function Convert-Signed16([int]$Value) {
    if ($Value -ge 32768) { return ($Value-65536) }
    return $Value
}
function Get-U32LowFirst([int[]]$Words,[int]$At) {
    # Widen BEFORE arithmetic; PowerShell signed bit shifts overflow at bit31.
    return ([uint64]$Words[$At] + [uint64]$Words[$At+1]*[uint64]65536)
}
function Get-VoltageConditions([int]$Word) {
    $names=[Collections.Generic.List[string]]::new()
    if($Word -band 1){$names.Add('String high')}
    if($Word -band 2){$names.Add('String low')}
    if($Word -band 4){$names.Add('Cell high')}
    if($Word -band 8){$names.Add('Cell low')}
    if($Word -band 65520){$names.Add(('Other 0x{0:X4}' -f ($Word -band 65520)))}
    if($names.Count -eq 0){return 'No decoded voltage conditions'}
    return ($names -join '; ')
}
function Test-WatchedTower($TowerData) {
    if(-not [string]::IsNullOrWhiteSpace($WatchSerial)){return $TowerData.Serial -eq $WatchSerial}
    return ($WatchTower -gt 0 -and $TowerData.Tower -eq $WatchTower)
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
    $serialBytes = [byte[]]$bytes[66..89]
    $end = $serialBytes.Length
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
    if ($Words[25] -gt 100) { throw "Tower ${Tower}: invalid SOH representation; refusing to guess its scale." }
    [bool[]]$balance = New-Object bool[] $State.CellCount
    for ($i=0; $i -lt $State.CellCount; $i++) {
        $balance[$i] = ($Words[6+[int][Math]::Floor($i/16.0)] -band (1 -shl ($i%16))) -ne 0
    }
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
            Voltage=([double](($mc | Measure-Object -Sum).Sum)/1000.0)
            BalanceCount=@($balance[($m*16)..($m*16+15)] | Where-Object {$_}).Count
        })
    }
    return [pscustomobject]@{
        Tower=$Tower; Serial=$serial; SerialHex=[BitConverter]::ToString($serialBytes)
        RequestedAt=$RequestedAt; ReceivedAt=$ReceivedAt
        CaptureSeconds=($ReceivedAt-$RequestedAt).TotalSeconds; Scan=$State.Scan
        SocCalibrationRaw=(($Words[18] -shr 8) -band 0xFF)
        SocCalibrationWord=$Words[18]
        Soc=$Words[24]/10.0; Soh=$Words[25]
        ChargeEnergyWh=(Get-U32LowFirst $Words 14); DischargeEnergyWh=(Get-U32LowFirst $Words 16)
        BalanceFlags=$balance; BalanceWords=[int[]]$Words[6..13]
        BalanceCount=@($balance | Where-Object {$_}).Count
        PackVoltage=$Words[20]*0.1; OutputVoltage=$Words[23]*0.1; SwitchWord=$Words[22]
        FirmwareWords=[int[]]$Words[30..32]
        VoltageConditions=(Get-VoltageConditions $Words[27])
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
        ChargeEnergyKWh=(Get-U32LowFirst $Words 17)*0.1
        DischargeEnergyKWh=(Get-U32LowFirst $Words 19)*0.1
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
    if($null -eq $d) {
        $p.Add((Paint "TOWER $Tower | awaiting first capture" 96))
        for($i=1;$i -lt (11+$ModulesPerTower);$i++){$p.Add('')}
        return ,$p.ToArray()
    }
    $age=Get-Age $d.ReceivedAt
    $stale=($age -gt $Settings.StaleSeconds -or $State.ConnectionBroken -or $State.FailedTowers.ContainsKey($Tower))
    $ageColour=if($stale){91}else{37}
    $tag=if($stale){' STALE'}else{''}
    $masterTag=if($Tower -eq $MasterTower){'*'}else{''}
    $p.Add((Paint ('T{0}{1} SOC {2}% SOH {3}% {4}s{5}' -f $Tower,$masterTag,(Format-Num $d.Soc),$d.Soh,(Format-Num $age '0'),$tag) $ageColour))
    $sn=if([string]::IsNullOrWhiteSpace($d.Serial)){'[not decoded]'}else{$d.Serial}
    $p.Add('SN '+$sn)
    $p.Add(('Min {0} Max {1} d{2} mV' -f $d.Min,$d.Max,$d.Delta))
    $p.Add(('v M{0}/C{1:00} ^ M{2}/C{3:00} med{4}' -f $d.MinModule,$d.MinCell,$d.MaxModule,$d.MaxCell,(Format-Num $d.Median '0')))
    $p.Add(('I {0}A P {1}W Cal {2:X2}' -f (Format-Num $d.Current),(Format-Num ($d.Current*$d.Voltage) '0'),$d.SocCalibrationRaw))
    $p.Add(('E in  {0} kWh (reported)' -f (Format-Num ($d.ChargeEnergyWh/1000.0) '0.000')))
    $p.Add(('E out {0} kWh (reported)' -f (Format-Num ($d.DischargeEnergyWh/1000.0) '0.000')))
    $p.Add(('Balance flags: {0}/{1}' -f $d.BalanceCount,$State.CellCount))
    $wc=if(($d.Warning1 -bor $d.Warning2 -bor $d.Warning3 -bor $d.Fault) -ne 0){93}else{37}
    $p.Add((Paint ('W {0:X4}/{1:X4}/{2:X4} R47 {3:X4}' -f $d.Warning1,$d.Warning2,$d.Warning3,$d.Fault) $wc))
    $p.Add((Paint $d.VoltageConditions $wc))
    if($Numeric){$p.Add('    '+((1..16 | ForEach-Object {' {0,4}' -f $_}) -join '')+'  d mV bal')}
    else{$p.Add('    1234567890123456   d   mean bal')}
    foreach($m in $d.Modules) {
        $row='M{0}  ' -f $m.Number
        for($c=0;$c -lt 16;$c++) {
            $index=($m.Number-1)*16+$c
            $isMin=($index -eq $d.MinIndex);$isMax=($index -eq $d.MaxIndex)
            $bal=$State.ShowBalance -and $d.BalanceFlags[$index]
            $colour=if($isMin -and $isMax){95}elseif($isMin){96}elseif($isMax){92}else{Get-CellColour $m.Cells[$c] $d.Median}
            if($Numeric) {
                $mark=if($bal){'*'}else{' '}
                $text='{0}{1,4}' -f $mark,$m.Cells[$c]
            } else {
                $text=if($isMin -and $isMax){'X'}elseif($isMin){if($bal){'V'}else{'v'}}elseif($isMax){if($bal){'A'}else{'^'}}elseif($bal){'*'}else{'#'}
            }
            $row+=Paint $text $colour -Reverse:($isMin -or $isMax)
        }
        if($Numeric){$row+=('  {0,4} {1,3}' -f $m.Delta,$m.BalanceCount)}
        else{$row+=(' {0,4} {1,5} {2,3}' -f $m.Delta,(Format-Num $m.Average '0'),$m.BalanceCount)}
        $p.Add($row)
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
        $rows.Add(('System age {0}s | raw error 0x{1:X4} | negative current = charging' -f (Format-Num (Get-Age $b.Time) '0'),$b.Error))
    } else { $rows.Add('System status: awaiting first response'); $rows.Add('') }
    $rows.Add(('Sweep {0} | {1} | previous sweep {2}s | target interval {3}s' -f $State.Scan,$State.Stage,(Format-Num $State.LastSweepSeconds),$ScanSeconds))
    $summary=''; $currents=''; $allPresent=$true; $sum=0.0
    for($t=1;$t -le $ExpectedTowers;$t++) {
        $d=$State.Towers[$t]
        if($null -eq $d){$summary+="T${t}: ---   ";$allPresent=$false;continue}
        if($State.ConnectionBroken -or (Get-Age $d.ReceivedAt) -gt $Settings.StaleSeconds){$allPresent=$false}
        $label=if($t -eq $MasterTower){'T'+$t+'*'}else{'T'+$t}
        $summary+=('{0}: {1}% / d{2}mV / {3}s   ' -f $label,(Format-Num $d.Soc),$d.Delta,(Format-Num (Get-Age $d.ReceivedAt) '0'))
        $currents+=('{0} {1}A {2}W   ' -f $label,(Format-Num $d.Current),(Format-Num ($d.Current*$d.Voltage) '0'))
        $sum+=$d.Current
    }
    $rows.Add($summary)
    $rows.Add(('Communication: OK {0} | errors {1} | {2}' -f (($State.SuccessfulTowers.Values | Measure-Object -Sum).Sum),$State.CommunicationErrors,$State.Stage))
    if($currents -ne ''){$rows.Add('Tower current/power: '+$currents)}
    if($null -ne $b -and $allPresent -and (Get-Age $b.Time) -le $Settings.StaleSeconds -and $State.FailedTowers.Count -eq 0){
        # BMU and tower readings are sequential, not exactly simultaneous.
        $rows.Add(('Sum {0} A | BMU {1} A | difference {2} A (sequential samples)' -f (Format-Num $sum),(Format-Num $b.Current),(Format-Num ($sum-$b.Current))))
    }
    $watch=$null
    foreach($entry in @($State.Towers.Values)) { if(Test-WatchedTower $entry){$watch=$entry;break} }
    if($null -ne $watch) {
        $wi=16*($WatchModule-1)+$WatchCell-1
        $wv=$watch.Cells[$wi]
        $change=if($null -ne $State.WatchFirst){$wv-[int]$State.WatchFirst}else{0}
        $rows.Add((Paint ('WATCH SN ...{0} M{1}/C{2}: {3} mV | since start {4:+0;-0;0} mV | age {5}s' -f
            $watch.Serial.Substring([Math]::Max(0,$watch.Serial.Length-4)),$WatchModule,$WatchCell,$wv,$change,(Format-Num (Get-Age $watch.ReceivedAt) '0')) 95))
    } elseif($WatchTower -gt 0 -or $WatchSerial -ne '') { $rows.Add(('Watch: T{0} M{1}/C{2} - awaiting matching sample' -f $WatchTower,$WatchModule,$WatchCell)) }
    $rows.Add('')
    $numeric=[bool]$State.Numbers
    if($numeric -and $width -lt 94) {$numeric=$false}
    $panelHeight=11+$ModulesPerTower
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
    $footer.Add('* balance flag; V/A selected min/max; v/^ extrema. Flags NOT measured bleed current. Cal is RAW. R47 is legacy RAW.')
    $footer.Add('Timeout: skipped capture; stale tower data is NOT live. Diagnostic selection uses FC16.')
    $footer.Add('Q/Ctrl+C quit | H heatmap | N mV | B balance overlay | A auto | 1/2/3 tower | no charging commands')
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
            elseif($keyText -eq 'B') {$State.ShowBalance=-not $State.ShowBalance}
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
                if($Deadline.ElapsedMilliseconds -gt $Settings.FrameTimeoutMs) { throw [IO.IOException]::new('TCP frame timeout; partial capture discarded.') }
            }
            $n=$script:Stream.EndRead($async)
            if($n -le 0){throw [IO.IOException]::new('BYD closed the TCP connection.')}
            $offset+=$n
        } finally { $async.AsyncWaitHandle.Close() }
    }
    return ,$buffer
}
function Send-Request([byte[]]$Body,[int]$Function) {
    Assert-WireRequest $Body $Function
    [byte[]]$sent=Add-Crc $Body
    $reg=([int]$Body[2] -shl 8) -bor [int]$Body[3]
    $label='FC{0:X2} @0x{1:X4}' -f $Function,$reg
    $trace=[pscustomobject]@{Time=[DateTime]::UtcNow.ToString('o');Operation=$label;Sent=[BitConverter]::ToString($sent);Received=$null}
    $State.Trace.Add($trace)
    $script:Stream.Write($sent,0,$sent.Length)
    $timer=[Diagnostics.Stopwatch]::StartNew()
    [byte[]]$head=Read-Exact 3 $timer
    if($head[0] -ne 1){throw [IO.IOException]::new("$label returned an unexpected unit ID.")}
    [byte[]]$frame=$null
    if($head[1] -eq ($Function -bor 128)) {
        [byte[]]$tail=Read-Exact 2 $timer
        [byte[]]$frame=@($head)+@($tail)
        $trace.Received=[BitConverter]::ToString($frame)
        Assert-FrameCrc $frame
        if($head[2] -in @(4,6)){throw [IO.IOException]::new(('{0}: Modbus exception {1}; delayed retry permitted.' -f $label,$head[2]))}
        throw ('{0}: Modbus exception {1}; not retried automatically.' -f $label,$head[2])
    }
    if($head[1] -ne $Function){throw [IO.IOException]::new("$label returned an unexpected function.")}
    if($Function -eq 3) {
        $expectedCount=([int]$Body[4] -shl 8) -bor [int]$Body[5]
        if($head[2] -ne 2*$expectedCount){throw [IO.IOException]::new("$label returned an unexpected byte count.")}
        [byte[]]$tail=Read-Exact ($head[2]+2) $timer
        [byte[]]$frame=@($head)+@($tail)
    } elseif($Function -eq 16) {
        [byte[]]$tail=Read-Exact 5 $timer
        [byte[]]$frame=@($head)+@($tail)
    } else {throw 'Unsupported function.'}
    $trace.Received=[BitConverter]::ToString($frame)
    Assert-FrameCrc $frame
    if($Function -eq 16) {
        for($i=2;$i -le 5;$i++){if($frame[$i] -ne $Body[$i]){throw [IO.IOException]::new('FC16 acknowledgement mismatch.')}}
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
            if($timer.ElapsedMilliseconds -gt $Settings.ConnectTimeoutMs){throw [IO.IOException]::new('BYD TCP connect timeout.')}
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
        if($status[0] -ne 0x8100){throw [IO.IOException]::new(('Unexpected diagnostic status 0x{0:X4} on T{1}; discard transfer and cool down.' -f $status[0],$Tower))}
    }
    if(-not $ready){throw [IO.IOException]::new("Tower $Tower diagnostic-ready timeout.")}
    $words=[Collections.Generic.List[int]]::new()
    for($chunk=1;$chunk -le 4;$chunk++) {
        $State.Stage="T$Tower reading packet $chunk/4"
        Invoke-Tick
        [int[]]$block=Read-Registers 0x0558 65
        if($block.Length -ne 65 -or $block[0] -ne 128){throw [IO.IOException]::new("Invalid T$Tower chunk $chunk length.")}
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
    $delay=[Math]::Min(120,$Settings.ReconnectCooldownSeconds*[Math]::Pow(2,[Math]::Max(0,[Math]::Min(3,$State.ConsecutiveFailures-1))))
    $State.ReconnectAfter=[DateTime]::UtcNow.AddSeconds($delay)
}
function Register-CommunicationFailure([string]$Component,[string]$Message,[int]$Tower=0) {
    $State.CommunicationErrors++
    $State.ConsecutiveFailures++
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
    try {
        Open-Connection
        Read-ValidateConfiguration
        $State.ConnectionBroken=$false
        return $true
    }
    catch{
        if(-not (Test-RecoverableError $_)){throw}
        $State.ConsecutiveFailures++
        $State.CommunicationErrors++
        if($null -ne $State.ErrorWriter){$State.ErrorWriter.WriteLine(('{0} RECONNECT: {1}' -f [DateTime]::UtcNow.ToString('o'),$_.Exception.Message))}
        Reset-Transport
        return $false
    }
}
function Read-ValidateConfiguration {
    $State.Trace.Clear()
    [int[]]$configuration=Read-Registers 0 102
    $decoded=Convert-Configuration $configuration
    Write-Raw ([ordered]@{Type='Config';ReceivedAt=[DateTime]::UtcNow.ToString('o');Words=$configuration;Decoded=$decoded;Frames=$State.Trace.ToArray()})
    Assert-HvmConfiguration $decoded
    $identity=$configuration[0..11] -join ','
    if($null -ne $State.ControllerIdentity -and $identity -ne $State.ControllerIdentity){throw 'Controller identity changed on reconnect. Monitoring stopped.'}
    $State.ControllerIdentity=$identity
    $State.Config=$configuration;$State.DeviceConfig=$decoded;$State.ConfigSummary=$decoded.Summary
    if(-not $State.UiReady){Write-Host $State.ConfigSummary}
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
    if($null -eq $State.RawWriter){return}
    $Object['AppVersion']=$AppVersion
    $Object['SchemaVersion']=$SchemaVersion
    $State.RawWriter.WriteLine(($Object|ConvertTo-Json -Depth 10 -Compress))
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
    $row+=@($b.ChargeEnergyKWh,$b.DischargeEnergyKWh)
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
    if($null -ne $previous -and (($previous.BalanceWords -join ',') -ne ($TowerData.BalanceWords -join ',') -or $previous.Warning1 -ne $TowerData.Warning1 -or $previous.Soh -ne $TowerData.Soh)) {
        Write-Raw ([ordered]@{Type='ObservedStateChange';At=$TowerData.ReceivedAt.ToString('o');Tower=$TowerData.Tower;PreviousAt=$previous.ReceivedAt.ToString('o');BalanceWords=$TowerData.BalanceWords;Warning1=$TowerData.Warning1;SOH=$TowerData.Soh;Note='Observation times, not exact BMS transition times.'})
    }
    $State.Towers[$TowerData.Tower]=$TowerData
    if($State.FailedTowers.ContainsKey($TowerData.Tower)) { [void]$State.FailedTowers.Remove($TowerData.Tower) }
    if(-not $State.SuccessfulTowers.ContainsKey($TowerData.Tower)){$State.SuccessfulTowers[$TowerData.Tower]=0}
    $State.SuccessfulTowers[$TowerData.Tower]++
    $State.Samples++
    if(Test-WatchedTower $TowerData) {
        $value=$TowerData.Cells[16*($WatchModule-1)+$WatchCell-1]
        if($null -eq $State.WatchFirst){$State.WatchFirst=$value}
        $State.WatchHistory.Add([pscustomobject]@{Time=$TowerData.ReceivedAt;Value=$value})
        if($State.WatchHistory.Count -gt 120){$State.WatchHistory.RemoveAt(0)}
    }
    $r=$TowerData
    $row=@($r.ReceivedAt,$r.RequestedAt,$r.CaptureSeconds,$r.Scan,$r.Tower,$r.Serial,$r.Soc,$r.SocCalibrationRaw,$r.Current,($r.Current*$r.Voltage),$r.Voltage,$r.Min,$r.Max,$r.Delta,$r.MinModule,$r.MinCell,
        ('0x{0:X4}' -f $r.Warning1),('0x{0:X4}' -f $r.Warning2),('0x{0:X4}' -f $r.Warning3),('0x{0:X4}' -f $r.Fault),$r.TempMin,$r.TempMax)+@($r.Cells)
    $row+=@($r.Soh,$r.ChargeEnergyWh,$r.DischargeEnergyWh,$r.BalanceCount,$r.PackVoltage,$r.OutputVoltage,$r.SwitchWord,$r.VoltageConditions)+@($r.FirmwareWords)+@($r.BalanceWords)+@($r.BalanceFlags|ForEach-Object{[int]$_})
    if($null -ne $State.ModuleWriter) {
        foreach($m in $r.Modules) {
            $mr=@($r.ReceivedAt,$r.Scan,$r.Tower,$r.Serial,$m.Number,$m.Voltage,($m.Voltage*$r.Current),$m.Min,$m.Max,$m.Delta,$m.BalanceCount)
            $State.ModuleWriter.WriteLine((@($mr|ForEach-Object{Csv-Value $_}) -join ';'))
        }
    }
    if($null -ne $State.CsvWriter){$State.CsvWriter.WriteLine((@($row|ForEach-Object{Csv-Value $_}) -join ';'))}
    if(-not $State.UiReady){
        Write-Host ('{0} T{1} SN {2} SOC {3}% min/max {4}/{5}mV d{6} M{7}/C{8} ({9}s)' -f
            (Get-Date -Format 'HH:mm:ss'),$r.Tower,$r.Serial,(Format-Num $r.Soc),$r.Min,$r.Max,$r.Delta,$r.MinModule,$r.MinCell,(Format-Num $r.CaptureSeconds))
        Write-Host ('  SOH {0}% | balance flags {1} | E in/out {2}/{3} kWh | {4}' -f $r.Soh,$r.BalanceCount,(Format-Num ($r.ChargeEnergyWh/1000.0) '0.000'),(Format-Num ($r.DischargeEnergyWh/1000.0) '0.000'),$r.VoltageConditions)
    }
    Invoke-Tick -Force
}
function Save-FullSnapshot {
    if($null -eq $State.Status){return}
    $towers=[ordered]@{}; $times=[ordered]@{}
    for($t=1;$t -le $ExpectedTowers;$t++) {
        $d=$State.Towers[$t]
        if($null -eq $d -or $d.Scan -ne $State.Scan){return}
        $towers[[string]$t]=$d.Words
        $times[[string]$t]=[ordered]@{RequestedAt=$d.RequestedAt.ToString('o');ReceivedAt=$d.ReceivedAt.ToString('o');Serial=$d.Serial}
    }
    $obj=[ordered]@{
        AppVersion=$AppVersion;SchemaVersion=$SchemaVersion;Time=[DateTime]::UtcNow.ToString('o');Host=$Ip;Port=$Port;Mode='Deep';Demo=[bool]$Demo;Scan=$State.Scan
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
    foreach($name in @('Csv','Status','Raw','Error','Module')) {
        $fileName=switch($name){'Csv'{'cells.csv'} 'Status'{'system.csv'} 'Raw'{'raw.ndjson'} 'Error'{'errors.log'} 'Module'{'modules.csv'}}
        $writer=[IO.StreamWriter]::new((Join-Path $State.LogPath $fileName),$false,$encoding)
        $writer.AutoFlush=$true
        $State[$name+'Writer']=$writer
    }
    $headers=@('ReceivedAtUTC','RequestedAtUTC','CaptureSeconds','Scan','LogicalTower','BmsSerialField','SOC_pct','SOC_Calibration_Raw_HighByte_Word18','TowerCurrent_A','TowerPower_W','TowerCellSumVoltage_V','Min_mV','Max_mV','Spread_mV','LowestLogicalModule','LowestCell',
        'Warning1_raw','Warning2_raw','Warning3_raw','Fault_raw','TempMin_C','TempMax_C')
    for($m=1;$m -le $ModulesPerTower;$m++){for($c=1;$c -le 16;$c++){$headers+=('M{0:00}_C{1:00}_mV' -f $m,$c)}}
    $headers+=@('SOH_reported_pct','ChargeEnergyCounter_Wh','DischargeEnergyCounter_Wh','BalanceFlagCount','TowerPackVoltage_V','TowerOutputVoltage_V','SwitchWord_raw','VoltageConditions','FirmwareWord30_raw','FirmwareWord31_raw','FirmwareWord32_raw')
    for($i=0;$i -lt 8;$i++){$headers+=('BalanceWord{0}_raw' -f $i)}
    for($m=1;$m -le $ModulesPerTower;$m++){for($c=1;$c -le 16;$c++){$headers+=('M{0:00}_C{1:00}_BalanceFlag' -f $m,$c)}}
    $State.CsvWriter.WriteLine(($headers -join ';'))
    $State.ModuleWriter.WriteLine('ReceivedAtUTC;Scan;LogicalTower;BmsSerialField;LogicalModule;CalculatedVoltage_V;CalculatedPower_W;Min_mV;Max_mV;Spread_mV;BalanceFlagCount')
    $State.StatusWriter.WriteLine('ReceivedAtUTC;Scan;SOC_pct;SOH_pct;Voltage_V;Current_A;EstimatedPower_W;Min_mV;Max_mV;TempMin_C;TempMax_C;Error_raw;ChargeEnergyCounter_kWh;DischargeEnergyCounter_kWh')
    $info=@"
BYD-HVM-Live $AppVersion
CSV schema: $SchemaVersion
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
BMS serial is not the individual module serial. Master label is selected by -MasterTower (currently $MasterTower), not inferred. Module/cell indices are logical.
Display colours show distance from tower median; lowest/highest cell blocks use cyan/green reverse video. NOT BYD alarm criteria.
The Min/Diff sparkline rows are deliberately removed; raw data remains logged.
Balancing bits are reported selections/states, not independently measured bypass currents.
SOH and cumulative energy are BMS-reported values, not calibrated capacity/energy tests.
W47/Fault_raw is legacy metadata, NOT a comprehensive fault-free indicator.
All service/reset/extended-statistics areas are excluded from this monitor.
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
    $words[25]=96+2*($Tower-1)
    $words[14]=12345;$words[15]=1;$words[16]=12000;$words[17]=1
    $words[6]=1;$words[6+[int][Math]::Floor(($State.CellCount-1)/16.0)]=0x8000
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

    # Exercise actual framing with fragmented memory reads, never a battery.
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
    [int[]]$u=@(65535,65535)
    if((Get-U32LowFirst $u 0) -ne [uint64]4294967295){throw 'Unsigned32 overflow regression failed.'};$tests++
    [int[]]$balWords=New-DemoWords 1 0
    for($i=6;$i -le 13;$i++){$balWords[$i]=0}
    $balWords[6]=0x8001;$balWords[7]=1
    $balWords[6+$ModulesPerTower-1]=$balWords[6+$ModulesPerTower-1] -bor 0x8000
    if($ModulesPerTower -lt 8){$balWords[13]=65535}
    $bt=Convert-Tower $balWords 1 ([DateTime]::UtcNow) ([DateTime]::UtcNow)
    if($bt.BalanceCount -ne 4 -or -not $bt.BalanceFlags[0] -or -not $bt.BalanceFlags[15] -or -not $bt.BalanceFlags[16] -or -not $bt.BalanceFlags[$State.CellCount-1]){throw 'Balance bit order/unused slots test failed.'};$tests++
    if($bt.Soh -ne 96 -or $bt.ChargeEnergyWh -ne 77881){throw 'SOH/energy regression failed.'};$tests++
    if((Get-VoltageConditions 5) -ne 'String high; Cell high'){throw 'Voltage condition decode failed.'};$tests++
    foreach($address in @(0x0690,0x0698,0x0740,0x0748,0x05A8)) {
        $rejected=$false
        try{Read-Registers $address 65|Out-Null}catch{if($_.Exception.Message -match 'whitelist'){$rejected=$true}}
        if(-not $rejected){throw 'Experimental register escaped monitoring whitelist.'};$tests++
    }
    $cancelError=$null
    try {throw [OperationCanceledException]::new('test stop')}catch{$cancelError=$_}
    if(Test-RecoverableError $cancelError){throw 'Cancellation was incorrectly retryable.'};$tests++
    $ioError=$null
    try {throw [IO.IOException]::new('test timeout')}catch{$ioError=$_}
    if(-not (Test-RecoverableError $ioError)){throw 'IO error was not classified as retryable.'};$tests++
    $rejected=$false
    try {Assert-WireRequest ([byte[]](1,16,6,144,0,2,4,0,1,129,0)) 16}catch{$rejected=$true}
    if(-not $rejected){throw 'Service write escaped wire whitelist.'};$tests++
    Write-Host "SELFTEST OK: $tests checks. No battery connection; no log files."
}

try {
    if(($WatchTower -gt 0 -or $WatchSerial -ne '') -and $WatchModule -gt $ModulesPerTower){throw 'WatchModule exceeds ModulesPerTower.'}
    if($WatchTower -gt $ExpectedTowers -or $MasterTower -gt $ExpectedTowers){throw 'WatchTower/MasterTower exceeds ExpectedTowers.'}
    if($SelfTest){Run-SelfTest;return}
    # Fail before opening a socket if built-in offline regression checks fail.
    Run-SelfTest
    $State.Trace.Clear()
    if($CheckOnly -and $Demo){throw 'Use CheckOnly for live configuration or Demo for simulation, not both.'}
    if($CheckOnly){$Plain=$true}
    [Net.IPAddress]$parsed=$null
    if($Ip -notmatch '^(?:[0-9]{1,3}\.){3}[0-9]{1,3}$' -or -not [Net.IPAddress]::TryParse($Ip,[ref]$parsed) -or $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){throw 'Ip must be an IPv4 address.'}
    if(-not $Demo) {
        $mutexName='BYD_HVM_LIVE_'+$Ip.Replace('.','_')+'_'+$Port
        if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){$mutexName='Local\'+$mutexName}
        $script:Mutex=[Threading.Mutex]::new($false,$mutexName)
        try{$script:OwnsMutex=$script:Mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$script:OwnsMutex=$true}
        if(-not $script:OwnsMutex){throw 'Another copy of this live monitor already owns this target.'}
    }
    Open-Logs
    Write-Host ('BYD HVM Live v{0} -- direct diagnostic capture. No network or charge-setting changes.' -f $AppVersion)
    Write-Host 'Close Be Connect Plus, the old relay and other BYD readers. Q stops the monitor.'
    Write-Host 'Every tower request uses FC16 diagnostic selection; not a write-free protocol.'
    Write-Host ('Logs: '+$State.LogPath)
    Start-Display
    if($Demo) {
        [int[]]$config=New-Object int[] 102;$config[16]=($ExpectedTowers -shl 4) -bor $ModulesPerTower;$config[17]=0x0102
        $State.Config=$config
    } else {
        try {Open-Connection;Read-ValidateConfiguration}
        catch {
            if($CheckOnly -or -not (Test-RecoverableError $_)){throw}
            Register-CommunicationFailure 'Initial connection' $_.Exception.Message
        }
        if($CheckOnly){
            Write-Host 'CONFIG OK: HVM layout verified. No tower requests or diagnostic writes sent.'
            return
        }
    }
    while($true) {
        $State.Scan++
        $sweep=[Diagnostics.Stopwatch]::StartNew()
        if($Demo) {
            [int[]]$status=New-Object int[] 25
            $status[0]=[Math]::Min(100,14+$State.Scan);$status[3]=98
            $status[1]=315;$status[2]=281;$status[4]=65522;$status[5]=34300;$status[6]=26;$status[7]=20
            $State.Status=Convert-Status $status ([DateTime]::UtcNow);Save-Status
        } else {
            if(Wait-For-Reconnect){
                try {Capture-Status} catch {if(-not (Test-RecoverableError $_)){throw};Register-CommunicationFailure 'System status' $_.Exception.Message}
            }
        }
        for($t=1;$t -le $ExpectedTowers;$t++) {
            if(-not $Demo) {
                if(-not (Wait-For-Reconnect)){continue}
                if($State.FailedTowers.ContainsKey($t)) {
                    if([DateTime]::UtcNow -lt $State.FailedTowers[$t]){continue}
                    [void]$State.FailedTowers.Remove($t)
                }
            }
            if($Demo) {
                $State.Stage="DEMO generating T$t"
                $at=[DateTime]::UtcNow
                [int[]]$words=New-DemoWords $t ($State.Scan-1)
                $towerData=Convert-Tower $words $t $at ([DateTime]::UtcNow)
                Write-Raw ([ordered]@{Type='DemoTower';ReceivedAt=$at.ToString('o');Tower=$t;Scan=$State.Scan;Words=$words})
            } else {
                try {$towerData=Capture-Tower $t}
                catch {if(-not (Test-RecoverableError $_)){throw};Register-CommunicationFailure ('T'+$t) $_.Exception.Message $t; break}
            }
            Publish-Tower $towerData
            Wait-Ui $Settings.BetweenTowersMs
        }
        $State.LastSweepSeconds=$sweep.Elapsed.TotalSeconds
        Save-FullSnapshot
        if(-not $State.ConnectionBroken -and $State.FailedTowers.Count -eq 0){$State.ConsecutiveFailures=0}
        if($MaxScans -gt 0 -and $State.Scan -ge $MaxScans){break}
        while($sweep.Elapsed.TotalSeconds -lt $ScanSeconds) {
            $State.Stage=('Waiting {0}s for next sweep' -f [Math]::Ceiling($ScanSeconds-$sweep.Elapsed.TotalSeconds))
            Wait-Ui 100
        }
    }
} catch [OperationCanceledException] {
    $State.Stage='Stopped by user'
} catch {
    $script:ExitCode=1
    $State.LastError=$_.Exception.Message
    $State.Stage='STOPPED - unexpected program error'
    if($null -ne $State.ErrorWriter){$State.ErrorWriter.WriteLine(([DateTime]::UtcNow.ToString('o')+' '+$_.ToString()))}
    try{Write-Raw ([ordered]@{Type='Error';At=[DateTime]::UtcNow.ToString('o');Message=$_.Exception.Message;Frames=$State.Trace.ToArray()})}catch{}
} finally {
    if($null -ne $script:Stream){try{$script:Stream.Dispose()}catch{}}
    if($null -ne $script:Tcp){try{$script:Tcp.Dispose()}catch{}}
    foreach($name in @('CsvWriter','StatusWriter','RawWriter','ErrorWriter','ModuleWriter')) {
        if($null -ne $State[$name]){try{$State[$name].Dispose()}catch{}}
    }
    Stop-Display
    if($script:OwnsMutex -and $null -ne $script:Mutex){try{$script:Mutex.ReleaseMutex()}catch{}}
    if($null -ne $script:Mutex){$script:Mutex.Dispose()}
}
if(-not $SelfTest) {
    Write-Host ('Monitor closed. {0} tower captures; {1} complete sweeps.' -f $State.Samples,$script:FullSnapshotCount)
    if($State.LogPath -ne ''){Write-Host ('Saved in: '+$State.LogPath)}
}
if($State.LastError -ne ''){Write-Host ('ERROR: '+$State.LastError) -ForegroundColor Red;Write-Host 'The monitor stopped due to a non-recoverable error. No charging controls were issued.'}
if($script:ExitCode -ne 0){exit $script:ExitCode}
