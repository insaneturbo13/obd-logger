# Architecture

## Data flow

```
Bluetooth LE adapter ──bytes──▶ ELMSession ──replies──▶ Poller ──samples──▶ LoggerEngine
   (BLEAdapterTransport)         (one command          (Scheduler,          ├─ DerivedSignals
                                  at a time, guard)      CapabilityMap)      ├─ TripRecorder ─▶ Documents/Trips/<id>/
                                                                             ├─ LiveData ─▶ dashboard (10 Hz)
                     iPad GPS (LocationRecorder) ──samples──────────────────▶ ├─ coolant alert, Live Activity
                                                                             └─ on trip end: CSV export, InfluxDB upload
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
SSM values) the simulation gives ~2 Hz engine speed, ~1 Hz coolant and transmission values
every 2–2.5 s.

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

`samples.csv` is append-only, flushed every second and synced every 5 s. A crash loses at
most a few seconds; a torn last line is skipped on reading.

Stored units: °C, km/h, kPa, %, V, g/s, rpm, λ. Conversion to °F/mph/AFR happens only for
display and exports.

## Exports

- **Raw CSV**: one row per reading (`time,elapsed_s,signal,name,value,unit`).
- **Table CSV**: one row per 0.5 s, a column per signal in display units. A value is
  repeated only while fresh: up to 2.5× that signal's typical interval in the trip (at
  least 1.5 s). Older cells stay empty, so a stall is visible. Optional age columns.
- **InfluxDB 2.x**: line protocol, measurement `trip`, tags `vehicle`, `trip_id`,
  `source=obdlogger`, one field per signal (stored units), millisecond timestamps.

## Background operation

- `bluetooth-central`: the app gets Bluetooth notifications in the background. The
  adapter always ends a reply with a prompt, so the polling loop is driven by Bluetooth
  events. The remembered adapter has a standing connection request; iOS completes it when
  the adapter powers up and relaunches the app if needed (state restoration).
- `location`: while a trip records, GPS runs with background updates allowed. This keeps
  the app running in front of Maps and adds position/speed to the trip.
- The Live Activity can only be started while the app is in the foreground; a trip that
  starts in the background gets it the next time the app is opened.
