# Protocol reference and research map

Scope: standard monitor plus offline inspection of identified BMU 3.27 / BMS
3.32 images. This is not an official or universally complete BYD specification.
All addresses are zero-based wire registers. Payload word indices are a
separate numbering system. No service/reset recipe is included.

## Requests actually sent by v1.5

| Function | Start | Count | Purpose |
|---|---|---:|---|
| FC03 | 0x0000 | 102 | Identity/model/topology; repeated after reconnect |
| FC03 | 0x0500 | 25 | System telemetry |
| FC16 (0x10) | 0x0550 | 2 | Select [tower, 0x8100], the only allowed write |
| FC03 | 0x0551 | 1 | Wait for ready 0x8801; 0x8100 still pending |
| FC03 | 0x0558 | 65 | Four chunks at the same address, not incrementing addresses |

Transport: unit ID 1, CRC16-checked RTU frames in a TCP stream, normally port
8080. Responses can be fragmented across TCP reads. This is not standard
MBAP-framed Modbus TCP. Every diagnostic chunk has a length word (128) followed
by 128 data bytes. Concatenating without those words gives 512 bytes.

The inspected ordinary object is 70 six-byte records = 420 meaningful bytes;
last-chunk padding is 92 bytes. The history object is 600 bytes and requires
five chunks. A fifth standard diagnostic read can exhaust transfer state.

## System summary

0x0500 is reported SOC in percent; 0x0501/02 maximum/minimum cell voltage in
0.01 V; 0x0503 reported SOH percent; 0x0504 signed current in 0.1 A; 0x0505 pack
voltage in 0.01 V; 0x0506/07 temperature extrema; 0x050D raw error/status.

Charge energy is uint32 from 0x0511 low word and 0x0512 high word, multiplied by
0.1 kWh. Discharge energy similarly uses 0x0513/14. These are NOT cycle counts.
Other summary words are preserved raw rather than assigned guessed meanings.

## Standard tower payload

Let W[n] be the zero-based uint16 array after dropping all transport length
words. Bytes in each word are big-endian; multiword counters use low-word-first.

| Field | Interpretation |
|---|---|
| W0 / W1 | Maximum / minimum cell mV |
| W3 / W4 | Maximum / minimum temperature |
| W6..W13 | 128 balance flags; logical cell i uses bit i%16 of W[6+i//16] |
| W14 + 65536*W15 | Reported cumulative charge Wh |
| W16 + 65536*W17 | Reported cumulative discharge Wh |
| High byte of W18 | Cal raw state, not a universal activity Boolean |
| W20 / W23 | Reported pack / output voltage, 0.1 V |
| W22 | Raw switch/control word, not a decoded contactor state |
| W24 | Reported SOC, 0.1 percentage point |
| W25 | Reported SOH, whole percent after BMU repacking |
| W26 | Signed current, 0.1 A; negative charging in validated captures |
| W27..W29 | Raw warning/status words |
| W30..W32 | Raw firmware/bank words; no active-bank inference |
| Bytes 66..89 | 24-byte BMS/controller serial field; first 19 displayed for compatibility |
| W47 | Legacy raw value; zero in the inspected small-image builder, not all-clear |
| W48 onward | Only the actual configured cells; 16 per HVM module |
| Bytes 354..417 | Temperature slots, 56 used for seven HVM modules |
| Bytes 418..419 | Inner checksum bytes created before BMU repacking |
| Bytes 420..511 | Transport padding |

Unsigned counters are widened before arithmetic so bit31 does not turn them
negative. The first 112 balance bits are used for seven modules. Unused cell and
balance slots are not interpreted as additional physical cells.

Low W27 bits traced in the smaller BMS image: 0x0001 upper string voltage,
0x0002 lower string voltage, 0x0004 upper cell voltage, 0x0008 lower cell voltage.
These are condition descriptions with delayed/hysteretic logic, not fixed
thresholds, severity labels or a complete official fault table. Higher bits,
W28 and W29 remain raw. No software alarm threshold controls the battery.

## Address-window inventory: static findings, NOT a probing list

Inspected small BMU callback: 0x080343B8; large-image counterpart: 0x0004872C.
Read bounds were cross-checked, not every write path or hardware generation.

| Region | Classification | In monitor? |
|---|---|---|
| 0x0000..0x0065 | Configuration/identity snapshot | Yes |
| 0x0100..0x01FF | Context-dependent shared buffer, not identified sensors | No |
| 0x0400..0x0408; stream 0x0409 | Storage/service transfer | No |
| 0x0500..0x0518 | System summary | Yes |
| 0x0550..0x0557; stream 0x0558 | Standard selected tower diagnostics | Yes, exact requests above |
| 0x05A0..0x05A7; stream 0x05A8 | History: 600 meaningful bytes | No |
| 0x05F0..0x0639 / 0x0640..0x0689 | Firmware/service windows | No |
| 0x0690..0x0697; stream 0x0698 | Extended BMS statistics: 66 bytes | No, static only |
| 0x0740..0x0747; stream 0x0748 | SOC/SOH service family | No |

Stream addresses denote exact starts for stateful 65-register reads, not proof
that each intervening address is independently readable. Some reads advance
transfer state; some service header reads also change cached state. A readable
address is therefore not automatically a harmless sensor register.

The 66-byte statistics object is little-endian, with energy, integrated-current
candidates and unresolved duration/capacity fields; see [Phase 1](research/PHASE1.md).
No hardware response has been acquired for it. Existing service paths can assign
model parameters or clear history; existence is documented but activation and
reset commands are deliberately absent.

No verified module-production-serial vector, persistent module energy array or
independent series-module current measurements have been identified. Power per
module is a calculation, not discovery of a new sensor.

## Sources and confidence

Public baseline: [sarnau](https://github.com/sarnau/BYD-Battery-Box-Infos) and
[ioBroker mapping](https://github.com/christianh17/ioBroker.bydhvs/blob/master/docs/byd-hexstructure.md).
Firmware identities and scoped code addresses are in [research](research/PHASE1.md).
Observed counters and masks are backed by supplied captures; exact physical
accuracy, full balancing execution, module order and remaining service semantics
are not thereby established.
