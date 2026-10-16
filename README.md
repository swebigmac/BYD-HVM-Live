# BYD HVM Live

Independent PowerShell diagnostics for BYD Battery-Box Premium HVM.

**v1.5 is an experimental review build, not an official BYD application or a
battery safety system.** Standard telemetry and recovery have automated tests
on Windows PowerShell 5.1 and PowerShell 7. New live operation on physical
hardware still needs verification; see [validation](docs/VALIDATION.md).

## Start

Download `BYD-HVM-Live-v1.5-EN.ps1`. Run in a normal PowerShell console, not ISE.
No administrator rights or additional Python installation are needed to use it.

```powershell
.\BYD-HVM-Live-v1.5-EN.ps1 -SelfTest
.\BYD-HVM-Live-v1.5-EN.ps1 /?
.\BYD-HVM-Live-v1.5-EN.ps1
```

The last command prompts for the battery's IPv4 address and prints a shortcut
example. For direct connection, use `/YOUR_BATTERY_IP` or `-Ip YOUR_BATTERY_IP`,
substituting the actual numeric address. No address is hardcoded or saved.
Port 8080 is the default. Follow your organization's script-execution policy.

The default layout guard is three towers with seven HVM modules each. It does
not change the installed configuration. `-ExpectedTowers` and `-ModulesPerTower`
allow other HVM layouts, but those have only synthetic tests; also set
`-WatchModule` within that module count. HVS/HVB are not supported. The
`-MasterTower 1` label is a configured assumption, not automatic discovery;
use `-MasterTower 0` when unknown.

Close other BYD diagnostic readers and Be Connect before starting. Do not run
this monitor during firmware installation. It leaves normal inverter control
alone and never commands battery charging or discharging.

## Display and controls

| Key | Action |
|---|---|
| H / N | Compact heatmap / exact cell millivolts |
| B | Toggle balance-flag overlay; acquisition and logging continue |
| A / 1 / 2 / 3 | Automatic overview / fixed tower |
| Q or Ctrl+C | Stop the monitor, not battery operation |

Per-tower panels show reported SOC, SOH, current, calculated power, cumulative
energy, cell spread, raw Cal, warning words and balance-flag counts.
`v` and `^` mark the first minimum and maximum when values tie. `*` marks a
balance flag; `V` / `A` combine it with a minimum / maximum. Numeric view adds
`*` before a selected cell value. `X` means the same cell is both extrema.

Use roughly 116 columns and 35 rows for the three-column view. Smaller consoles
show one tower while all configured towers continue to be captured. Screen
refresh (default 1 s) is separate from sequential acquisition (target 10 s).
Sample age is explicit; disconnected or stale values are not live readings.

`-WatchTower 1 -WatchModule 7 -WatchCell 14` is the default logical cell watch.
`-WatchSerial '<your BMS serial>'` uses identity instead; an empty serial is not
a hardcoded private identifier. `-WatchTower 0` disables an identity-free watch.

## Interpretation matters

- Balance flags are software-reported selection/state, NOT measured bypass
  current, balanced Ah, or proof that balancing has completed.
- SOH is a reported model value, not an independent capacity test. Cumulative
  energy belongs to controller history and can be reset; it is not an immutable
  per-module lifetime record or a calibrated meter.
- Cal is raw, not a universal calibration-active Boolean. The legacy CSV
  `Fault_raw` field is shown as `R47`: zero there is NOT a fault-free guarantee.
- Low warning-word bits have firmware-derived voltage-condition names; other
  bits remain raw. Names do not establish severity or a safe operating limit.
- Module power is calculated from common tower current and that module's cell
  voltage sum. Individual module serials and independent module currents have
  not been identified. Physical top/bottom order is not established by the UI.

## Protocol boundary

The wire protocol is Modbus RTU over TCP, not MBAP-framed Modbus TCP.
**It is not strictly read-only:** FC16 selects tower diagnostics at 0x0550.
That selector is the only permitted write; FC03 reads are locally whitelisted.
No history, extended-statistics, SOC/SOH-reset, firmware or configuration request
has been added. [Protocol reference](docs/PROTOCOL.md) and `/?` list every request.

On supported transport errors the connection and unfinished transfer are
abandoned, a 20-120 s backoff is applied, and configuration plus identity are
revalidated before a new diagnostic selection. A shared-buffer failure aborts
the current sweep. Stale values remain visibly stale. Unexpected data/model
errors still stop the program rather than silently continuing.

## Files and privacy

Each run creates a new session folder under Desktop/BYD-Diagnostik, or under
`-OutputDirectory`. Old runs are not overwritten. CSV uses semicolons and a
decimal point, with schema version 2. Existing cell columns remain and new
columns are appended.

| File | Contents |
|---|---|
| cells.csv | Cells, tower telemetry, SOH, energy, raw balance masks and cell flags |
| modules.csv | Calculated module voltage/power, spread and flag count |
| system.csv | System telemetry and reported cumulative energy |
| raw.ndjson | Complete standard payloads, frames, metadata and observed changes |
| snapshot-*.json / session.txt | Complete sequential sweeps and session metadata |
| errors.log | Communication and program failures |

Logs contain device identifiers, network addresses and usage times. Review and
anonymize before sharing. `.gitignore` prevents some accidental additions; it
does not redact data already committed or explicitly force-added. Research
summaries here contain aggregates, not raw personal captures or firmware images.

## Development and research

See [Phase 1 findings](docs/research/PHASE1.md), including the period-dependent
energy discrepancy and why the experimental 66-byte statistics path stays out
of live polling. Confirmed, observed and static-only findings are kept distinct.

Offline tests require Python 3 plus a PowerShell runtime:

```text
python tests/test_monitor.py --shell powershell
python tests/test_monitor.py --shell pwsh
python tools/inspect_captures.py captures.zip --split-utc 2026-10-15T21:30:00Z
```

Tests use synthetic values and a simulator bound only to 127.0.0.1. They do not
access a battery. The inspector only reads a local ZIP and emits aggregates.
The scripts are not fuzzers or service/reset tools.

## Acknowledgements and license

Protocol background includes [sarnau/BYD-Battery-Box-Infos](https://github.com/sarnau/BYD-Battery-Box-Infos)
and [christianh17/ioBroker.bydhvs](https://github.com/christianh17/ioBroker.bydhvs).
Balance flags, ordinary energy counters and tower current were already public;
we do not claim their discovery. See [CHANGELOG.md](CHANGELOG.md) and [MIT LICENSE](LICENSE).
