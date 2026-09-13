# KMBox Mac

A native macOS workbench for KMBox network input control, device diagnostics, and MicroPython development. Includes a SwiftUI/AppKit app, the `kmctl` CLI, and a reusable `KMBoxCore` library.

[中文](README.md) · [Usage](docs/USAGE.md) · [Compatibility](docs/COMPATIBILITY.md) · [Protocol](docs/PROTOCOL.md) · [Sources](SOURCES.md)

Version **1.3.1**. The UI and detailed guides are currently in Chinese. This is an independent project, not an official KMBox, DFRobot, or MicroPython product. uPyCraft was a workflow reference; its Windows executable is not bundled.

## Features

- Net UDP: relative, timed automatic, and Bézier movement; mouse buttons/wheel; HID keyboard combinations and held-key release.
- Device configuration: peripheral information and parsing-mode readback; legacy Net configuration commands.
- Diagnostics: matching-ACK RTT statistics, ICMP, chip ID, device reports and timestamped raw JSONL export.
- Serial workbench: Python editing, raw REPL, board files, verified upload with backups, run/stop, and startup-script entry generation.
- AVFoundation video preview and screenshots; NB firmware validation and HTTP hosting for device-initiated updates.

**A USB network interface is not a Python REPL.** Network input control uses Net UDP. Board scripting and file management use the B serial interface with compatible firmware. The two connections are separate and can coexist.

## Build

Requires macOS 13+, an Xcode toolchain supporting Swift 5.9+, and Python 3's standard library for tests. There are no third-party Swift packages, Windows DLLs, Qt components, or Python GUI dependencies.

```bash
swift test
bash scripts/build-app.sh
open "dist/KMBox Mac.app"
./dist/kmctl --help
```

Both outputs are universal arm64/x86_64 binaries. The app is ad-hoc signed, not Developer ID signed or notarized. Build products are excluded from Git. Tested locally on Apple Silicon/macOS 26.6.2/Swift 6.3.3; minimum-OS and physical Intel-Mac acceptance remain unverified.

```bash
./dist/kmctl --host DEVICE_IP --port DEVICE_PORT --uuid DEVICE_UUID auto-move 100 0 500 --stats
./dist/kmctl --host DEVICE_IP --port DEVICE_PORT --uuid DEVICE_UUID monitor 10 6688 --monitor-output ./monitor.jsonl
./dist/kmctl --serial /dev/cu.DEVICE ls
```

Use actual device values and `--local MAC_IPV4` when selecting a specific interface. Startup does not automatically connect, run scripts, or flash a device. Serial connection interrupts the current board script to enter raw REPL.

## Status and limitations

A protocol ACK does not prove actual HID output. Tests use real loopback UDP sockets and PTYs; they do not emulate the device firmware. Basic NB keyboard output has a manual hardware observation, while newer commands, persistence, serial workflows, flashing, and other models still require hardware validation.

NB AI algorithm discovery/current settings/threshold readback and the three distinct human/program/corrected trajectory streams are **not implemented**: confirmed network interfaces are missing. Legacy Net curve indices are not an NB algorithm catalog. Firmware hosting only serves a selected image; the device performs the flash. See [validation](docs/VALIDATION.md) and [compatibility](docs/COMPATIBILITY.md).

Settings and drafts are local. Exported reports may contain input events. Optional vendor adaptation buttons contact the original host tool's plain-TCP service at `47.75.195.35:5002`; normal connection does not contact it. Camera access requires macOS permission. Vendor firmware, Windows tools, downloaded repositories and local logs are excluded from the public source tree.

## Contributing and license

See [CONTRIBUTING.md](CONTRIBUTING.md), [CHANGELOG.md](CHANGELOG.md), and [release instructions](docs/RELEASING.md). Original project code and documentation are licensed under [MIT](LICENSE). [SOURCES.md](SOURCES.md) records upstream references, pinned revisions and license observations; third-party material is not relicensed by this project.
