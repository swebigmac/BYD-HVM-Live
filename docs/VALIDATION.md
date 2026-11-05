# v1.5 validation record

Date: 2026-10-16. This is software/protocol validation, not a battery certification.

## Windows execution

[GitHub Actions run 38898624203](https://github.com/swebigmac/BYD-HVM-Live/actions/runs/38898624203)
completed successfully for both Windows PowerShell 5.1 (`powershell`) and
PowerShell 7 (`pwsh`). Tested commit: `3dad3dc1a78f236b5eb9c83b5067734c850e1d3c`.
The monitor blob is `54225774e552c0d034027878294ab09e22e8de66`.
Its SHA256 is `6acc609ce32ace966326fc0388a3daaad404e8dd5b3b7b7d77d6f241f4e4aca4`.
Later documentation-only commits do not change that tested code.

The suite runs 38 built-in checks for each of three synthetic module layouts
(3, 7 and 8, with a valid watch module), help without connecting, demo output,
CSV schemas, balancing bit ordering and unused slots, unsigned32 energy values,
and a synthetic RTU-over-TCP simulator bound exclusively to `127.0.0.1`.

Transport scenarios: normal operation, T2 diagnostic-ready timeout, and invalid
CRC in a T2 response. Tests verify recovery after at least19 seconds of observed
cooldown, a new TCP connection and configuration validation before selecting
diagnostics again. Completed captures, logged errors and complete snapshots
are checked after recovery. No physical battery address or credentials are used.

An initial PowerShell7 run exposed a reusable-APM wait-handle bug. The corrected
monitor polls `IsCompleted` and does not close a reused `AsyncWaitHandle`.
Both Windows runtimes pass after this fix. This test does not establish that
all possible driver/firmware delays and network failures are covered.

## Local offline execution

The complete simulator suite also passed under PowerShell7.6.6 in the analysis
container. Separately, the actual PowerShell decoder was checked against102
saved real payloads (first/last per tower in17 sessions) and an independent
Python calculation: serial-prefix compatibility, SOH, balance flags, cumulative
energy and cell-voltage sums agreed. Those payloads remain private.

Heatmap panel generation was checked to fit37 columns, and numeric balance
markers were exercised. This is a formatting test, NOT manual validation of
every Windows terminal, resize behavior, colour theme or keyboard interaction.

## Research reproducibility

`tools/inspect_captures.py` reproduces the aggregate-only results in
`docs/research/aggregate-validation.json` when given the original private ZIP
and the explicit split time in PHASE1.md. Raw logs and firmware are not shipped.
Firmware identity/instruction-byte checks support transcription integrity;
they do not mechanically prove all manually inferred semantics.

## Physical installation observations, October 2026

The v1.5 dashboard was observed operating on a real installation with three
seven-module HVM towers during multiple day-long Windows PowerShell sessions.
Screenshots show continuously updated tower SOC/current, per-cell voltage
heatmaps and numeric tables, balance selection masks, warning words and energy
counters across low SOC (~4% system reported) and full charge (100%). Some
sessions were interrupted by Windows restarts; this is not an uninterrupted
endurance certification. Captures and identifying controller serials are held
privately and are not part of this repository.

At full charge, reported balance flags changed over time (including an observed
56/112 in one tower), sometimes while external tower current was 0 A. Such flags
are **not** direct measurements of shunt current. Reported upper-cell voltage
conditions persisted in some periods after individual cell voltages relaxed.
At a different full-charge event, one cell reportedly reached ~3608 mV; this
must not be represented as evidence of benign calibration or an approved test.
No claim is made that the application can infer whether the inverter requested
zero charge or the BMS enforced a limit.

## Still required before a stable release

Independent review of interpretation labels, independent transport/security
review, controlled fault-recovery observation on actual hardware, verification
of every supported topology, and independent electrical validation remain open.
The code is distributed as an **experimental** v1.5 release candidate, not
battery safety instrumentation. Extended statistics, service/reset transactions
and per-module serial retrieval are not live-validated or implemented.
