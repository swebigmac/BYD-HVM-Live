# HVM module BIC board: physical observations and qualified interpretation

Status: independent visual inspection of a user-supplied photograph and component markings (October 2026). **Not** a validated BYD schematic, bill of materials, board reverse-engineering netlist or safety-approved service procedure. No private board photograph is redistributed here.

## Visible / user-observed details

- Board silkscreen: `NLPP_P3_BIC_V0`, dated `2019_9-20`.
- Each 16-cell HVM module is reported to contain one BIC board.
- Two devices were identified by their markings as LTC6811G-1 battery-stack monitor ICs. Each LTC6811 family device supports measurement of up to 12 series cells; a symmetric eight-cell allocation per IC is plausible but is not electrically traced.
- Top connection marked `To BMS`; bottom connection marked `From BIC`. The board has three apparent pulse-transformer components in the communications path; a chain through the two monitoring ICs is a strong **hypothesis**, not a continuity-tested schematic.
- Signal labels near a connector include `B_IPA` and `B_IMA`. Together with the LTC6811-1 and transformers, these strongly suggest transformer-coupled isoSPI. Physical signal waveforms were not captured.
- Eight visible large SMD parts marked `33R0` with accompanying small transistor-like packages were observed in one half of the symmetric board. Passive per-cell shunting is a likely purpose; the full 16-channel allocation, resistor topology and second half of the circuit were not independently traced.
- Two other larger transistor packages may be associated with local supplies or switching. Their functions and exact types are **unverified**.

## What follows, and what does not

If 33 ohms is directly placed across a 3.3 V cell, the **ideal instantaneous** shunt estimate is approximately 0.10 A and 0.33 W. These are conditional Ohm's-law estimates, **not measured balancing current or proven maximum**. Series components, switching duty cycle, heating and firmware conditions can change effective current.

LTC6811 is a cell-measurement and balancing-control IC, not a general-purpose independently flashable BMS controller. A central tower BMS selecting balance channels via an isoSPI daisy chain is therefore consistent with this hardware; no module firmware update or unique serial-number addressing is established by the photograph. Logical order in the communication chain is not verified as the physical module order.

Live v1.5 balance flags are decoded from the BMS diagnostic payload as documented in [PROTOCOL.md](../PROTOCOL.md). They report **software selection/state**, not the external BIC's physical transistor gate state, resistance, current, or accumulated Ah. The repeated appearance of eight selected flags per logical module in one capture could reflect firmware policy, but a hardware channel limit or precise scheduler is **not demonstrated**.

The marked board should not be accessed or rewired in an energized battery system. High-voltage module disassembly, cell tapping, external balancer attachment and service transactions require an approved procedure and qualified personnel.

## What would be needed to raise confidence

A properly isolated board-level schematic/continuity survey and component identification, plus manufacturer documentation or independently instrumented off-battery validation, would distinguish the proposed topology from observation. This research does not authorize probing isoSPI or operating module electronics without their normal safety system.
