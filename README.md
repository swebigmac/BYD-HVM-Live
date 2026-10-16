# BYD HVM Live

An unofficial PowerShell diagnostics dashboard for BYD Battery-Box Premium HVM installations.

> **Status:** Experimental. The current development version is v1.4. This project is independent of BYD and is not an official BYD application.

## Features

- Live per-cell voltage display for three battery towers, in numeric and heatmap views.
- Per-tower SOC, current, approximate power, minimum and maximum cell voltage, and voltage spread.
- System-level voltage and current measurements.
- Raw SOC calibration diagnostic byte (`Cal 0xXX`) for each tower. **These values have not yet been decoded or validated.**
- Continuous CSV logging, raw diagnostic captures and an error log.
- Connection recovery attempts after diagnostic timeouts.
- Built-in help and self-test.

## Requirements

- Windows PowerShell.
- Network connectivity to a compatible, already configured BYD Modbus RTU-over-TCP gateway.
- A supported HVM tower configuration.

The initial build has been developed around one installation with **three HVM towers, seven modules per tower**. Other configurations have not been validated.

## Getting started

Once the English PowerShell script has been added to this repository, download it and run the following commands from its directory:

```powershell
.\BYD-HVM-Live-v1.4-EN.ps1 -SelfTest
.\BYD-HVM-Live-v1.4-EN.ps1 /?
.\BYD-HVM-Live-v1.4-EN.ps1 /YOUR_GATEWAY_IP
```

Substitute your gateway's actual IP address for `YOUR_GATEWAY_IP`.

The interface offers a three-column overview and single-tower views, with numeric and heatmap modes. See the built-in help for keyboard shortcuts and configuration options.

## Important protocol and safety notes

**This tool is not strictly read-only at the Modbus protocol level.** It uses FC16 to select a diagnostic data block and FC03 to retrieve it. It does not intentionally change operational battery settings, charging limits, or firmware.

Do not use this software for safety-critical monitoring. Never bypass the BMS or its protective limits. Avoid running multiple tools that may interfere with each other's diagnostic requests.

SOC and SOH are estimates produced by the BMS; cell voltage alone does not directly determine SOC. The raw `Cal 0xXX` byte is not currently interpreted as an active/inactive calibration indicator.

## Logs and privacy

Diagnostic logs can include device identifiers, timestamps and details of your battery installation. Review and anonymize them before sharing. Do not commit personal log files to a public repository.

## References and acknowledgements

The protocol implementation draws on publicly available reverse-engineering work, particularly [sarnau/BYD-Battery-Box-Infos](https://github.com/sarnau/BYD-Battery-Box-Infos). Check the original project for additional protocol background.

## License

A project license has not yet been selected. Please do not assume an open-source license applies until a `LICENSE` file is added.

## Roadmap

- Validate the English-language v1.4 build on Windows PowerShell.
- Document tested hardware and firmware combinations.
- Verify timeout recovery and calibration-field behavior over longer runs.
- Add example screenshots and sanitized sample output.
