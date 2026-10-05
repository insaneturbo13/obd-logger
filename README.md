# OBD Logger

An iPad-first (universal) iOS app that records a car's sensors through a Bluetooth LE
ELM327-style adapter, built to be a dependable everyday logger:

- **Keeps recording** with the screen off or another app in front (Bluetooth + location
  background modes), starts and stops trips by itself, and never loses more than a few
  seconds if the app is killed.
- **Polling that doesn't collapse.** A rate-based scheduler packs six standard values into
  each request (free on these adapters: one value or six take the same ~112 ms), batches
  requests per module, and remembers which sensors this car actually answers so dead ones
  aren't asked every drive.
- **Honest data.** Raw readings with their real timestamps. Exports never paper over a
  stall: a value is only repeated while it's fresh, so a frozen adapter shows up as a gap.
  Stale values dim on the dashboard instead of sitting still.
- **Read-only.** Every command passes one guard that allows adapter setup and read requests
  only. The app can't clear codes or write anything to the car.
- Manufacturer-specific sensors through vehicle profiles. First profile: 2010 Subaru
  Outback 2.5i CVT (engine oil and CVT fluid temperature, turbine speed, lock-up and AWD
  transfer duty, wheel and axle speeds), each entry carrying its verification status and
  evidence.
- Dark dashboard with warm text and the Wong color-vision-safe palette; coolant Live
  Activity on the lock screen with a configurable alert point.
- CSV export into any Files-app folder (iCloud Drive, Google Drive, OneDrive), optional
  InfluxDB upload, trouble-code reading.
- Import of trips recorded elsewhere: this app's CSV exports from another device (link the
  shared export folder and the iPhone shows what the iPad recorded) and Car Scanner's CSV
  exports, picked in Files, sent with Share › Open in, or picked up from the linked folder.

Status: early. The protocol core is tested against recordings from a real adapter; the app
has not yet been driven.

## Layout

| Path | What |
|---|---|
| `OBDKit/` | Swift package with the protocol core: read-only guard, ELM327 session, ISO-TP reassembly, standard PID decoding, vehicle profiles, scheduler, capability map, trip recorder, exports, simulator. No iOS dependencies; builds and tests on Linux and Windows. |
| `App/` | The iOS app (SwiftUI) and the Live Activity widget. `project.yml` is an [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec; the Xcode project is generated. |
| `profiles/` | Vehicle profiles (JSON). Embedded into OBDKit by `tools/embed_profiles.py`. |
| `docs/` | Architecture notes and the TestFlight setup. |

## Building

Protocol core, anywhere with Swift 5.10+:

```
swift test --package-path OBDKit
```

App, on a Mac with Xcode 16+ and XcodeGen:

```
cd App && xcodegen generate && open OBDLogger.xcodeproj
```

Without a Mac: GitHub Actions builds the app on every push (`.github/workflows/ci.yml`)
and uploads to TestFlight on demand (`testflight.yml`, setup in
[docs/TESTFLIGHT.md](docs/TESTFLIGHT.md)).

## Vehicle profiles

A profile lists manufacturer-specific values: module, request, scaling, unit, and a
status:

| Status | Meaning |
|---|---|
| `verified` | Confirmed against an independent signal while driving |
| `candidate` | Answers; scaling consistent with idle readings and earlier recordings |
| `assumed-scale` | Answers; scaling not yet seen move |
| `raw` | Scaling unknown; logged as the raw value |
| `no-information` | Answers but never changes; off by default |

Entries are only added after the car has been seen answering them, named and described in
our own words, with the evidence alongside.

## License

To be decided before the repository is made public.
