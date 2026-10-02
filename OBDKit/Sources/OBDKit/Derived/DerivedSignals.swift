import Foundation

/// Values computed from measured ones, with no extra requests to the car. Each is emitted
/// when its triggering input arrives, using the latest *fresh* value of the other inputs.
public struct DerivedSignals: Sendable {
    public static let fuelRate: SignalID = "fuel_rate"
    public static let fuelEconomy: SignalID = "fuel_economy"
    public static let fuelUsed: SignalID = "fuel_used"
    public static let boost: SignalID = "boost"
    public static let rpmPerSpeed: SignalID = "rpm_per_speed"
    public static let converterSlip: SignalID = "converter_slip"
    public static let axleSlip: SignalID = "front_rear_slip"
    public static let distance: SignalID = "distance"
    public static let acceleration: SignalID = "acceleration"
    public static let powerEstimate: SignalID = "power_estimate"

    public static let infos: [SignalInfo] = [
        SignalInfo(id: fuelRate, name: "Fuel rate (from airflow)", unit: .litersPerHour, category: .derived, source: .derived, range: 0...20),
        SignalInfo(id: fuelEconomy, name: "Instant fuel economy", unit: .kmPerLiter, category: .derived, source: .derived, range: 0...25),
        SignalInfo(id: fuelUsed, name: "Fuel used this trip", unit: .liters, category: .derived, source: .derived),
        SignalInfo(id: boost, name: "Manifold vacuum/boost", unit: .kpa, category: .derived, source: .derived, range: -100...20),
        SignalInfo(id: rpmPerSpeed, name: "Engine speed per road speed", unit: .rpmPerKmh, category: .derived, source: .derived, range: 0...100),
        SignalInfo(id: converterSlip, name: "Torque converter slip", unit: .rpm, category: .derived, source: .derived, range: -500...1500),
        SignalInfo(id: axleSlip, name: "Front vs rear axle speed difference", unit: .percent, category: .derived, source: .derived, range: -10...10),
        SignalInfo(id: distance, name: "Distance this trip", unit: .km, category: .derived, source: .derived),
        SignalInfo(id: acceleration, name: "Acceleration", unit: .metersPerSecond2, category: .derived, source: .derived, range: -6...6),
        SignalInfo(id: powerEstimate, name: "Engine power (rough estimate from airflow)", unit: .kilowatts, category: .derived, source: .derived, range: 0...130),
    ]

    /// Gasoline density, g/L.
    public var fuelDensity = 745.0
    /// Inputs older than this (seconds) are not combined.
    public var freshness = 3.0

    private var latest: [SignalID: Sample] = [:]
    private var lastSpeed: Sample?
    private var lastMAF: Sample?
    private var accelRef: Sample?
    public private(set) var distanceKm = 0.0
    public private(set) var fuelLiters = 0.0

    public init() {}

    /// Seeds the trip totals when a recording is resumed.
    public mutating func resume(distanceKm: Double, fuelLiters: Double) {
        self.distanceKm = distanceKm
        self.fuelLiters = fuelLiters
    }

    private func fresh(_ id: SignalID, at t: Date) -> Double? {
        guard let s = latest[id], abs(t.timeIntervalSince(s.time)) <= freshness else { return nil }
        return s.value
    }

    public mutating func ingest(_ s: Sample) -> [Sample] {
        latest[s.signal] = s
        var out: [Sample] = []
        func emit(_ id: SignalID, _ v: Double) { if v.isFinite { out.append(Sample(id, v, s.time)) } }

        switch s.signal {
        case "maf":
            // Fuel mass = air mass / (stoichiometric AFR × commanded λ). Approximate: ignores fuel trims.
            let lambda = fresh("commanded_eq_ratio", at: s.time).flatMap { $0 > 0.5 ? $0 : nil } ?? 1.0
            let litersPerHour = s.value / (UnitConverter.stoichiometricAFR * lambda) / fuelDensity * 3600
            emit(Self.fuelRate, litersPerHour)
            emit(Self.powerEstimate, s.value * 0.80)
            if let prev = lastMAF {
                let dt = s.time.timeIntervalSince(prev.time)
                if dt > 0 && dt <= 5 {
                    let prevRate = prev.value / (UnitConverter.stoichiometricAFR * lambda) / fuelDensity * 3600
                    fuelLiters += (litersPerHour + prevRate) / 2 * dt / 3600
                    emit(Self.fuelUsed, fuelLiters)
                }
            }
            lastMAF = s
            if let speed = fresh("speed", at: s.time), speed > 3, litersPerHour > 0.05 {
                emit(Self.fuelEconomy, speed / litersPerHour)
            }
        case "speed":
            if let prev = lastSpeed {
                let dt = s.time.timeIntervalSince(prev.time)
                if dt > 0 && dt <= 5 {
                    distanceKm += (s.value + prev.value) / 2 * dt / 3600
                    emit(Self.distance, distanceKm)
                }
            }
            lastSpeed = s
            // Speed comes in whole km/h, so differentiate over at least half a second.
            if let ref = accelRef {
                let dt = s.time.timeIntervalSince(ref.time)
                if dt >= 0.5 {
                    if dt <= 3 { emit(Self.acceleration, (s.value - ref.value) / 3.6 / dt) }
                    accelRef = s
                }
            } else {
                accelRef = s
            }
        case "rpm":
            if let speed = fresh("speed", at: s.time), speed >= 5 { emit(Self.rpmPerSpeed, s.value / speed) }
        case "map":
            // Barometric pressure barely moves and is polled slowly, so a few minutes old is fine.
            if let baro = latest["baro"], abs(s.time.timeIntervalSince(baro.time)) < 300 { emit(Self.boost, s.value - baro.value) }
        case "turbine_speed":
            if let rpm = fresh("rpm", at: s.time) { emit(Self.converterSlip, rpm - s.value) }
        case "rear_axle_speed_vdc":
            if let front = fresh("front_axle_speed_vdc", at: s.time), s.value >= 10 {
                emit(Self.axleSlip, (front - s.value) / s.value * 100)
            }
        default:
            break
        }
        return out
    }
}
