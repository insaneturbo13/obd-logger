# Architecture

## Data flow

```
Bluetooth LE adapter ──bytes──▶ ELMSession ──replies──▶ Poller ──samples──▶ LoggerEngine
   (BLEAdapterTransport)         (one command          (Scheduler,          ├─ DerivedSignals
                                  at a time, guard)      CapabilityMap)      ├─ TripRecorder ─▶ Documents/Trips/<id>/
                                                                             ├─ LiveData ─▶ dashboard (10 Hz)
                     iPad GPS (LocationRecorder) ──samples──────────────────▶ ├─ coolant alert, Live Activity
       motion + barometer (MotionRecorder, MotionAverager) ──samples, bumps──▶ │
                                                                             └─ on trip end: MountCalibration, CSV export,
                                                                                InfluxDB upload
```

Everything left of `LoggerEngine` lives in `OBDKit` and is tested without a device:
against a simulated adapter (`SimulatedAdapter`) and against a real recorded session
(`Tests/OBDKitTests/Fixtures/veepeak-idle-2026-10-01.trace`).

## Read-only guard

`ReadOnlyGuard.check` runs inside `ELMSession.send` for every command. It accepts a short
list of adapter setup commands (`ATZ`, `ATE0`, `ATH1`, `ATSH…`, `ATCRA…`, …) and the read
services 01, 03, 07, 0A, 22 and A8 (SSM read, single address). Everything else is refused
before it reaches the transport, including clear codes (04), any write, routine, session
or reset service, SSM writes, and identifiers F180–F19F (module identity, VIN).

## Adapter session

- Setup: `ATZ`, echo/linefeeds/spaces off, **headers on** (replies are parsed per CAN ID),
  adaptive timing, automatic protocol, then `0100…` support bitmaps from every module.
- Module addressing: `ATSH` + `ATCRA` per module (proven on the Veepeak). At setup the
  session also checks whether the adapter's automatic receive filter follows `ATSH` alone
  (asks the transmission computer and the engine computer for `0100`); if so, a module
  change costs one command instead of two.
- Replies are reassembled as ISO-TP (single, first and consecutive frames) and classified:
  answers, not supported, conditional, negative, pending, silent, adapter error, no reply.

## Polling (measured on the Veepeak OBDCheck BLE+, 2026-10-01)

| Measurement | Value |
|---|---|
| One request, one standard PID | ~112 ms |
| One request, six standard PIDs | ~112 ms (packing is free) |
| Count hint (`…1`) | no gain; breaks packed requests on this adapter |
| AT command | ~75 ms |
| Request nobody answers (ATST32, ATAT1) | ~300 ms |
| Sustained, packed | ~8.8 requests/s, ~35 values/s (Windows; iOS may differ) |

The scheduler gives every poll item a target period. The next request serves the item
that is most overdue *relative to its own period*; standard requests are filled up to six
PIDs with the next-most-due. Under overload every item slows by the same factor instead
of some starving. A module change is only made when the other module's work is clearly
more overdue (stickiness), and once there, that module's nearly-due items are served as a
batch so they stay in phase. With everything on for the Outback (44 standard PIDs + 10
SSM values) and generic periods, the simulation gives ~2 Hz engine speed, ~1 Hz coolant and
transmission values every 2–2.5 s; a real drive's raw export (2026-10-02) came within ~5 %
of that.

A vehicle profile can set its own periods (`standardPeriods`, and `period` per sensor) and
**modes**: periods that apply only while a condition holds. Conditions are "stationary"
(road speed has read 0 for N seconds; ends the moment it reads above 0) and "coolant at
least N °C" (ends 2 °C lower). The Outback profile polls engine speed, road speed, airflow,
throttle and pedal every 0.33 s and coolant, timing and module voltage every 0.5 s; when
stopped it slows the wheel-speed, AWD, torque-converter and EGR reads, and when hot it
polls coolant and module voltage every 0.33 s. On a hot idle that halves module changes and
brings coolant and voltage to ~0.27 s. A period changed by mode is rescheduled from the
item's last read, so items that speed up are read at once. Mode changes go to the trip's
events (`poll_modes`) so slower polling isn't mistaken for a stall; the user's own period
for an item always wins.

The capability map (per car, keyed by the modules' support bitmaps, not the VIN) records
each item as active, silent or unsupported. Unsupported items are never asked again unless
the user retries; silent ones are retried once per connection; a working sensor that
misses three times in a row backs off (15 s doubling to 10 min). Silence only counts
against a sensor while the engine computer is answering, so turning the ignition off
doesn't write sensors off.

## Trips

A trip starts when the car answers and ends 30 s after it stops answering (ignition off)
or when the adapter disconnects. A new connection within the merge window (default
3 min) appends to the same trip as a new segment.

Each trip is a folder in `Documents/Trips/` (visible in the Files app):

| File | Content |
|---|---|
| `meta.json` | id, start/end, segments, adapter, protocol, profile, signal catalog, summary, export/upload state |
| `samples.csv` | `t_ms,signal,value`: every reading with its real time (Unix ms), stored units |
| `events.csv` | `t_ms,kind,detail`: connected, car offline/online, notes, coolant alerts, codes read |
| `trace.log` | optional: every adapter command and reply with timings |
| `vehicle-motion.csv` | pitch, roll, car-frame acceleration, yaw rate and road grade worked out at trip end; same format as `samples.csv`, rewritten whole each time the trip ends |

`samples.csv` is append-only, flushed every second and synced every 5 s. A crash loses at
most a few seconds; a torn last line is skipped on reading.

Stored units: °C, km/h, kPa, %, V, g/s, rpm, λ. Conversion to °F/mph/AFR happens only for
display and exports.

## Device motion and barometer

While a trip records, the device's own sensors record alongside the car's (Settings ›
Recording, on by default). Core Motion's device motion is read at 50 Hz and reduced by
`MotionAverager` to one set of values per half second, in the device's frame:

| Signal | What |
|---|---|
| `phone_gravity_x/y/z` | mean gravity direction (m/s²); the tilt comes from this |
| `phone_accel_x/y/z` | mean acceleration with gravity removed (m/s²) |
| `phone_rotation_x/y/z` | mean rotation rate (°/s) |
| `phone_jolt_peak` | largest acceleration along gravity in the half second (m/s²): bumps and potholes |
| `phone_vibration_rms` | RMS of the acceleration along gravity (m/s²): how rough the road is |
| `phone_pressure`, `phone_rel_altitude`, `phone_altitude` | barometer: pressure (kPa), altitude change since recording started and, where the device supports it, absolute altitude (m) |

A mean alone would smooth a bump away, so the peak is kept; a jolt of 4 m/s² (0.4 g) or
more is also written to the trip's events as `bump` with its peak and the road speed, at
most one every 2 s. A mount that bounces a little only shakes the acceleration: Core
Motion's gravity comes from sensor fusion with the gyroscope, not from the raw accelerometer.

At trip end `MountCalibration` turns these into the car's frame and writes
`vehicle-motion.csv`:

- **Down** is the average gravity direction while the device stayed put. A change of more
  than 15° (the device moved in its mount, or was picked up) starts a new stretch, each
  calibrated on its own; stretches under a minute are left out.
- **Forward** is the direction in which the device's acceleration follows the change of
  road speed (OBD speed, or GPS speed without it). It needs about 20 s of clear speeding
  up or slowing down; without that (a steady cruise) only yaw rate is given.
- **Pitch zero** comes from the barometer: the stretch's pitch is offset so its average
  matches the average road grade. Without a barometer, pitch is relative to the stretch's
  average. Roll is always relative (a road's crown leans the car a little all the time).

| Signal | Sign |
|---|---|
| `vehicle_pitch` (°) | nose up + |
| `vehicle_roll` (°) | leaning right + |
| `vehicle_accel_long` (m/s²) | speeding up + |
| `vehicle_accel_lat` (m/s²) | toward the right (turning right) + |
| `vehicle_yaw_rate` (°/s) | turning right + |
| `road_grade` (%) | uphill in the direction of travel +; barometric altitude change over 80 m of travel, above 15 km/h |

The summary of how the mount was found goes to `meta.json` (`motionCalibration`). A trip
resumed within the merge window is recalibrated from all its readings when it ends again.

Liquid in the cooling system feels speeding up and braking the way it feels tilt, so for
questions like an air pocket moving, compare temperatures with both pitch and longitudinal
acceleration.

## Exports

- **Raw CSV**: one row per reading (`time,elapsed_s,signal,name,value,unit`).
- **Table CSV**: one row per 0.5 s, a column per signal in display units. A value is
  repeated only while fresh: up to 2.5× that signal's typical interval in the trip (at
  least 1.5 s). Older cells stay empty, so a stall is visible. Optional age columns.
- **InfluxDB 2.x**: line protocol, measurement `trip`, tags `vehicle`, `trip_id`,
  `source=obdlogger`, one field per signal (stored units), millisecond timestamps.

## Import

Trips recorded on another device reach this one through CSV files (`TripImport` in OBDKit,
`TripImporter` in the app). Each file becomes an ordinary trip folder, marked with
`importedFrom` in `meta.json`; an imported trip is never resumed, exported or uploaded
again, since its source already has it.

| File | Read as |
|---|---|
| `<trip>-raw.csv` (this app) | every reading, exact; preferred when both exports of a trip are there |
| `<trip>.csv` (this app, table) | display units converted back; a repeated value kept once a second |
| `YYYY-MM-DD HH-MM-SS.csv` (Car Scanner) | time of day from each row, date from the name, clock in the device's time zone; columns mapped to signal IDs by name and unit, Car Scanner's running totals, averages and prices left out, anything else kept under `cs_<name>` |

Table-style files repeat each value until a new one arrives (Car Scanner without any
limit, so a frozen adapter looks like steady data). The import keeps every change plus one
repeat per second while a value holds, which keeps charts and trip totals right without
pretending the repeats are readings; the trip's notes say so.

Sources: files picked in the Files app, a CSV sent with Share › Open in, or a linked folder
checked when the app opens (subfolders included, so exports another tool has filed away in
a subfolder are still found). Trip IDs come from file names, so a trip already on the device is skipped
without downloading it; anything else is read through a file coordinator, which makes
iCloud Drive fetch files that are only placeholders.

A device that only views trips can turn off **Use the adapter on this device**. The adapter
takes one connection at a time and the app keeps a standing connection to a paired
adapter, so two devices with the app would race for it at every start. A device that has
never paired doesn't scan until **Find adapter** is tapped.

## Background operation

- `bluetooth-central`: the app gets Bluetooth notifications in the background. The
  adapter always ends a reply with a prompt, so the polling loop is driven by Bluetooth
  events. The remembered adapter has a standing connection request; iOS completes it when
  the adapter powers up and relaunches the app if needed (state restoration).
- Device motion and the barometer need no background mode of their own: they deliver
  updates for as long as the app runs, which GPS ensures during a trip. The barometer asks
  for Motion & Fitness permission the first time; without it, motion still records.
- `location`: while a trip records, GPS runs with background updates allowed. This keeps
  the app running in front of Maps and adds position/speed to the trip.
- The Live Activity can only be started while the app is in the foreground; a trip that
  starts in the background gets it the next time the app is opened. It only exists on the
  device that is recording: a device with the adapter switched off never shows one.
- In the Dynamic Island the reading is shown without its unit ("203°"). When another app
  also has a Live Activity (music, a timer), each gets a spot about 25 pt across, where the
  full "203 °F" was cut to "20…"; the island's text is a fixed size that shrinks to fit.
