# Changelog

## v1.5 (2026-10-16, experimental review build)

- Decode per-cell balance selection flags from standard diagnostic words 6..13; ignore unused module slots. Add B overlay toggle and per-module/tower flag counts.
- Display per-tower reported SOH and cumulative charge/discharge energy; log unsigned low-word-first counters correctly, including values above signed32 range.
- Append CSV schema2 fields and add modules.csv with calculated module voltage/power, not independent current measurements or lifetime module energy.
- Preserve system cumulative energy in system.csv; explicitly distinguish these counters from cycle counts.
- Add firmware-derived low voltage-condition labels while retaining raw warning words and unverified Cal status.
- Rename misleading UI Fault label to R47; retain Fault_raw CSV compatibility with a documented limitation.
- Preserve all24 serial-field bytes raw while keeping19-character display/WatchSerial compatibility; make the master/watch tower labels configurable.
- Strengthen exact request whitelisting, delayed connection recovery and identity/model/topology revalidation. No new address families or service/reset requests.
- Fix PowerShell7 reusable async-result handling exposed by a real Windows CI test.
- Retain English UI/help, version banner, /? and /IPv4, interactive address entry and shortcut hint without a hardcoded address.
- Add offline synthetic RTU simulator, Windows PowerShell5.1/7 CI and scoped research/aggregate validation documentation. No private raw captures or firmware images included.

Validation: both Windows CI variants pass, including ready-timeout and CRC-error recovery. The real decoder also agrees with102 saved payloads in offline regression. Physical v1.5 operation and long-duration gateway recovery remain to be verified. See docs/VALIDATION.md.

## v1.4 (2026-10-16)

- English-language terminal interface, help text, and diagnostic messages.
- Display raw SOC calibration diagnostic byte per tower (Cal 0xXX).
- Add version information to the dashboard and logging metadata.
- Improve three-column display spacing.
- Attempt delayed recovery after diagnostic timeouts instead of stopping immediately.
- Preserve per-cell voltage, tower current, power and system readouts, raw captures, and CSV logging.
- Remove installation-specific serial numbers and local network addresses from the repository copy.

The Swedish-language v1.4 build was observed operating on one installation. Later v1.5 tests do not retroactively certify every v1.4 code path.

## Credits

Protocol background: [sarnau/BYD-Battery-Box-Infos](https://github.com/sarnau/BYD-Battery-Box-Infos) and [christianh17/ioBroker.bydhvs](https://github.com/christianh17/ioBroker.bydhvs).
