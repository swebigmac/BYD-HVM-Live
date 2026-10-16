# Phase 1 review: standard telemetry and experimental boundaries

2026-10-16. Offline work on supplied BMU 3.27 / BMS 3.32 images and an existing
three-tower, seven-module HVM capture. This is independent research, not a BYD
specification. No commands were sent to a physical battery during this review.

## Evidence categories

**Observed** means data occurred in saved captures; **static** means code was
followed in identified firmware; **public** means prior community documentation
exists. None of these alone certifies physical measurement accuracy or operation
on every hardware/firmware variant. The app's MCU identifiers are not proven CPU
part numbers. Logical module numbers are not verified physical sticker positions.

The existing evidence package was rechecked against all eight original binary
identities and 4,171 instruction-byte lines. All byte comparisons passed. This
checks transcription/identity, not every semantic control-flow interpretation.
The capture decoder reconstructed 13,922 tower payloads from 17 sessions; the
previous transport validation checked 277,658 frames without a CRC mismatch.
Original firmware, private raw logs and controller serials are not included here.

## 1. Balancing: selection/state is visible; physical bleed current is not

In the ordinary repacked diagnostic payload, W6..W13 hold 128 bits. Logical cell
`i` (zero-based) uses `(W[6 + i//16] >> (i%16)) & 1`. Only configured cell slots are
counted: 112 for seven HVM modules. This field was already publicly documented.

Additional small-image trace: the diagnostic record builder at 0x08009424,
particularly 0x080094F0..0x0800954A, reads the mask buffer at 0x20000A9C. The
serializer around 0x0800F17C, including 0x0800F222..0x0800F28C, sets/clears bits
using OR/BIC and STRB. A caller around 0x0800F2E0..0x0800F340 populates this state;
the clear path at 0x0800EE66 clears a 32-byte mask area. Another reader near
0x08007DDA uses this state in a communication/state structure.

This is software-maintained selection/state. We have not traced the entire path
through the analog front end, measured shunt current, or established hardware
readback semantics. The UI therefore says **Balance flags**, not measured
balancing current, completed balancing, or guaranteed energized resistors.

Saved-capture observations (sampling counts, NOT independent events):

| Logical tower | Samples with nonzero mask | Of those, reported current exactly zero | Largest number selected |
|---|---:|---:|---:|
| 1 | 665 | 36 | 8 |
| 2 | 36 | 30 | 41 |
| 3 | 530 | 91 | 45 |

Nonzero masks coexist with Cal=0 and zero reported terminal current. This does
not attribute all voltage relaxation to balancing. A six-hour capture gap also
means a first observed mask must not be called the exact balancing start time.
The historical event export ends before the last charging/rest sequence, so it
cannot independently timestamp the later mask transitions.

## 2. Energy discrepancy: split the record before drawing a conclusion

Tower counters W14/15 and W16/17 are unsigned low-word-first Wh. System counters
0x0511/12 and 0x0513/14 use the same word order but 0.1 kWh per count. These fields
are **not cycle counts**. Their interpretation is supported by public code,
firmware tracing and matching system/tower aggregates. Those matching aggregates
are not independent meters.

A previous combined comparison hid a period-dependent discrepancy. We now split
at 2026-10-15T21:30:00Z, in the firmware-update-related capture gap. Within each
session we reject gaps over 20 seconds and segments of at most 60 seconds, then
compare counter increments against trapezoidal integration of positive charging
power `max(0, -I * sum(cell_mV)/1000)`. No gap interpolation or offset correction.

| Period | Tower | Counter increase kWh | Integrated sampled power kWh | Integral relative to counter |
|---|---:|---:|---:|---:|
| Before gap | 1 | 7.656 | 7.502 | -2.01% |
| Before gap | 2 | 7.218 | 9.010 | +24.83% |
| Before gap | 3 | 8.600 | 8.471 | -1.50% |
| After gap | 1 | 3.625 | 3.581 | -1.21% |
| After gap | 2 | 4.516 | 4.479 | -0.81% |
| After gap | 3 | 3.451 | 3.430 | -0.62% |

Approximately 10.2 hours before and 2.71 hours after are included per tower.
The disproportionate tower-2 discrepancy is concentrated **before** the gap.
This is a useful observation, NOT proof that the firmware update fixed a known
energy-meter bug: reboot, calibration state, operating point and sampling differ.
There is no old BMS binary comparison here and no independent calibrated meter.
The monitor must not silently rescale or offset these counters.

The standalone `tools/inspect_captures.py` reproduces the aggregation from an
existing monitor ZIP using Python's standard library. It opens no sockets and
emits no controller serials, target IPs or session names. Example:

```sh
python tools/inspect_captures.py captures.zip --split-utc 2026-10-15T21:30:00Z --output summary.json
```

The actual aggregate-only output is `aggregate-validation.json`. The input data
is private and intentionally not committed, so a third party can inspect the
method but cannot reproduce this installation's numbers without its raw capture.

## 3. Extended statistics at 0x0698: static only, excluded from v1.5

The correctly bounded header is **0x0690..0x0697**, with the exact stream endpoint
**0x0698**. An earlier informal mention of 0x0690..0x069F was too broad.

Small BMU internal request sender: 0x08021E60. Small BMS scheduler: 0x0800BA32;
record builder: 0x0800A34C. The BMU assembler at 0x0802197E expects eleven six-byte
records, verifies their checksum and exposes the 66-byte object. The stream
transports it with zero padding to 128 data bytes. Fields are little-endian,
unlike ordinary repacked diagnostic words.

| Byte offset | Meaning / confidence |
|---|---|
| 0, 4 | Structured date/status-like fields, unresolved |
| 8, 12 | u32 charge/discharge energy source, Wh |
| 16, 20 | u32 integrated-current counters; cumulative Ah candidates, external scaling not live-validated |
| 24 | Low16 status-transition count |
| 26, 30, 34, 38 | u32 conditional duration counters; exact units/conditions unresolved |
| 42 | u16 throughput-normalized/cycle-like quantity; not a proven full-cycle count |
| 44 | u32 capacity-related quantity, external unit not established |
| 48, 52, 54, 58 | Other reference/counter fields, incompletely interpreted |
| 56..57, 60..63 | Builder zeros |
| 64..65 | Inner CRC16 over the preceding 64 bytes |

The examined response builder is a statistics serializer, not a seven-module
identifier table. Acquisition is a stateful selection/transfer, not a free sensor
array. Neighboring write branches can clear history. Static separation is not a
hardware test of all asynchronous side effects. Therefore **no request to this
region is added**, and its Ah/duration fields are not presented as live facts.
A future supervised capture needs a separately reviewed transaction plan.

## 4. What is and is not ready for the monitor

Ready for standard-block decoding: balance masks, whole-percent per-tower SOH,
unsigned energy counters, pack/output voltage and raw switch/firmware words.
Tower SOH is distinct from system SOH; neither is an independent capacity test.

The small-image voltage warning path maps low W27 bits 0/1 to upper/lower string
voltage conditions and 2/3 to upper/lower cell conditions. Names describe code
conditions, NOT severity levels or fixed thresholds. Higher bits and W28/29 remain
raw. `0x0005` is a combination of low bits, not a separate fifth code.

**Important correction:** W47 is retained as `Fault_raw` for CSV compatibility but
called **R47** on screen. The inspected small BMS builder writes zero there;
R47=0 is not proof that the system has no faults. Cal high-W18 remains raw and is
not a general calibration-active boolean.

The serial field occupies 24 bytes; the current BMU repacker exposes the known
19-character identifiers followed by five `x` characters in these captures.
The monitor preserves full raw bytes but keeps the legacy 19-character display
and identity-matching behavior. These are BMS/controller IDs, not module IDs.

No verified per-module production-serial retrieval, independent series-module
current sensor, per-module lifetime-energy array or measured bleed-current array
has been found in these reply paths. This is a bounded negative result, not a
proof of absence from every internal bus or service image. Calculated module
power uses common tower current times that module's cell-voltage sum; it is not
an additional physical sensor and cannot reconstruct historic module moves.

## 5. Reset / assignment paths: existence only

External SOC/SOH assignment and cumulative-counter-clear code paths are present
in the inspected firmware (including the 0x0740/0x0748 service family). Their
existence does not demonstrate an approved relearning/repair procedure. No unlock
values, executable reset transactions, patches or flashing tools are provided.
They are excluded from the monitor and simulator request whitelists.

## 6. Attribution and release decision

Per-cell balancing flags, ordinary energy counters, current, basic RTU and Cal
fields were already described by community projects. Do not advertise them as
new discoveries. Added value is firmware tracing, interpretation limits,
reproducible validation and a usable diagnostic UI. The 66-byte extended path and
420-byte diagnostic vs 600-byte history distinction are candidate contributions;
coverage of all existing third-party research is not exhaustive.

References:
- https://github.com/sarnau/BYD-Battery-Box-Infos
- https://github.com/christianh17/ioBroker.bydhvs/blob/master/docs/byd-hexstructure.md
- Principal small BMS: BMS-P3-3.32-A-21C9.bin, base0x08005000,
  SHA256884a2aadc7e5509fcdde5eb2b8b26e6b89e58d51001cc2b3c23f795ec8220a83.
- Principal small BMU: BMU-P3-3.27-A-8956.bin, base0x08020000,
  SHA256eff6dcf6242310b0a71ee8e1dc9e7c1411a6b0d66e1200a891b773eb73999c3f.

Decision: ship the ordinary-block additions as an experimental v1.5 for review,
without expanding the wire request whitelist. Keep experimental service/statistics
research separate. Private repository, no raw logs/firmware, no public release or
upstream claim of a universally complete Modbus map.
