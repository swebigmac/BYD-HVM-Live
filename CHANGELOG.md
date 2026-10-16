# Changelog

## v1.4 (2026-10-16)

- English-language terminal interface, help text, and diagnostic messages.
- Display raw SOC calibration diagnostic byte per tower (`Cal 0xXX`); the meaning of its values remains unverified.
- Add version information to the dashboard and logging metadata.
- Improve three-column display spacing.
- Attempt delayed recovery after diagnostic timeouts instead of stopping immediately.
- Preserve per-cell voltage, tower current, power and system readouts, raw captures, and CSV logging.
- Remove installation-specific serial numbers and local network addresses from the repository copy.

**Validation:** The previous Swedish-language build has been observed operating on one installation. The English variant and timeout recovery require additional validation on Windows PowerShell. This version should be treated as experimental.

## Credits

Protocol background: [sarnau/BYD-Battery-Box-Infos](https://github.com/sarnau/BYD-Battery-Box-Infos).
