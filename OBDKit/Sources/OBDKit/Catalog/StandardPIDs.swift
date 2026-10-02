import Foundation

/// SAE J1979 service 01 parameters: data length and scaling as published in the standard.
/// Names are our own wording.
public struct StandardPID: Sendable {
    public struct Output: Sendable {
        public let info: SignalInfo
        /// Decodes the PID's data bytes (after service and PID). nil = no value (e.g. "not used").
        public let decode: @Sendable ([UInt8]) -> Double?
    }

    public let pid: UInt8
    public let length: Int
    public let outputs: [Output]
    /// Default poll period in seconds.
    public let period: Double

    public func decode(_ data: [UInt8]) -> [(SignalID, Double)] {
        guard data.count >= length else { return [] }
        return outputs.compactMap { o in o.decode(data).flatMap { $0.isFinite ? (o.info.id, $0) : nil } }
    }
}

public enum StandardPIDs {
    /// Data lengths for every service 01 PID up to 0x6F, needed to split packed replies,
    /// including PIDs we don't decode.
    public static let lengths: [UInt8: Int] = {
        var l: [UInt8: Int] = [:]
        let table: [(ClosedRange<UInt8>, Int)] = [
            (0x00...0x01, 4), (0x02...0x03, 2), (0x04...0x0B, 1), (0x0C...0x0C, 2), (0x0D...0x0F, 1),
            (0x10...0x10, 2), (0x11...0x13, 1), (0x14...0x1B, 2), (0x1C...0x1E, 1), (0x1F...0x1F, 2),
            (0x20...0x20, 4), (0x21...0x23, 2), (0x24...0x2B, 4), (0x2C...0x30, 1), (0x31...0x32, 2),
            (0x33...0x33, 1), (0x34...0x3B, 4), (0x3C...0x3F, 2), (0x40...0x41, 4), (0x42...0x44, 2),
            (0x45...0x4C, 1), (0x4D...0x4E, 2), (0x4F...0x50, 4), (0x51...0x52, 1), (0x53...0x59, 2),
            (0x5A...0x5C, 1), (0x5D...0x5E, 2), (0x5F...0x5F, 1), (0x60...0x60, 4), (0x61...0x62, 1),
            (0x63...0x63, 2), (0x64...0x64, 5), (0x65...0x65, 2), (0x66...0x66, 5), (0x67...0x67, 3),
            (0x68...0x69, 7), (0x6A...0x6C, 5), (0x6D...0x6D, 11), (0x6E...0x6E, 9), (0x6F...0x6F, 3),
        ]
        for (range, n) in table { for p in range { l[p] = n } }
        return l
    }()

    public static func isSupportBitmap(_ pid: UInt8) -> Bool { pid % 0x20 == 0 }

    // MARK: decoders

    static func u8(_ d: [UInt8]) -> Double { Double(d[0]) }
    static func u16(_ d: [UInt8], _ i: Int = 0) -> Double { Double(Int(d[i]) << 8 | Int(d[i + 1])) }
    static func s16(_ d: [UInt8], _ i: Int = 0) -> Double { Double(Int16(bitPattern: UInt16(d[i]) << 8 | UInt16(d[i + 1]))) }
    static func pct(_ d: [UInt8]) -> Double { Double(d[0]) * 100 / 255 }
    static func temp(_ d: [UInt8]) -> Double { Double(d[0]) - 40 }
    static func trim(_ d: [UInt8]) -> Double { (Double(d[0]) - 128) * 100 / 128 }

    private static func out(_ id: SignalID, _ name: String, _ unit: BaseUnit, _ cat: SignalCategory,
                            _ range: ClosedRange<Double>? = nil, _ decode: @escaping @Sendable ([UInt8]) -> Double?) -> StandardPID.Output {
        .init(info: SignalInfo(id: id, name: name, unit: unit, category: cat, source: .standard, range: range), decode: decode)
    }

    private static func one(_ pid: UInt8, _ period: Double, _ id: SignalID, _ name: String, _ unit: BaseUnit,
                            _ cat: SignalCategory, _ range: ClosedRange<Double>? = nil,
                            _ decode: @escaping @Sendable ([UInt8]) -> Double?) -> StandardPID {
        StandardPID(pid: pid, length: lengths[pid]!, outputs: [out(id, name, unit, cat, range, decode)], period: period)
    }

    static let o2Positions = ["b1s1", "b1s2", "b1s3", "b1s4", "b2s1", "b2s2", "b2s3", "b2s4"]
    static func o2Name(_ i: Int) -> String {
        let p = o2Positions[i]
        return "bank \(p.dropFirst().prefix(1)) sensor \(p.suffix(1))"
    }

    public static let all: [UInt8: StandardPID] = {
        var list: [StandardPID] = [
            StandardPID(pid: 0x01, length: 4, outputs: [
                out("mil_on", "Check-engine light", .state, .status, 0...1) { Double($0[0] >> 7) },
                out("dtc_count", "Stored trouble codes", .count, .status) { Double($0[0] & 0x7F) },
            ], period: 30),
            one(0x03, 10, "fuel_system_status", "Fuel system status", .state, .airFuel) { u8($0) },
            one(0x04, 0.5, "engine_load", "Calculated load", .percent, .engine, 0...100) { pct($0) },
            one(0x05, 1, "coolant_temp", "Coolant temperature", .celsius, .temperatures, 40...120) { temp($0) },
            one(0x06, 1, "stft_b1", "Short-term fuel trim", .percent, .airFuel, -25...25) { trim($0) },
            one(0x07, 2, "ltft_b1", "Long-term fuel trim", .percent, .airFuel, -25...25) { trim($0) },
            one(0x08, 1, "stft_b2", "Short-term fuel trim, bank 2", .percent, .airFuel, -25...25) { trim($0) },
            one(0x09, 2, "ltft_b2", "Long-term fuel trim, bank 2", .percent, .airFuel, -25...25) { trim($0) },
            one(0x0A, 2, "fuel_pressure", "Fuel pressure", .kpa, .airFuel) { u8($0) * 3 },
            one(0x0B, 0.5, "map", "Manifold absolute pressure", .kpa, .engine, 0...105) { u8($0) },
            one(0x0C, 0.33, "rpm", "Engine speed", .rpm, .engine, 0...7000) { u16($0) / 4 },
            one(0x0D, 0.33, "speed", "Vehicle speed", .kmh, .drivetrain, 0...200) { u8($0) },
            one(0x0E, 1, "timing_advance", "Ignition timing advance", .degrees, .engine, -10...50) { u8($0) / 2 - 64 },
            one(0x0F, 2, "intake_air_temp", "Intake air temperature", .celsius, .temperatures, -20...80) { temp($0) },
            one(0x10, 0.33, "maf", "Mass air flow", .gramsPerSecond, .engine, 0...150) { u16($0) / 100 },
            one(0x11, 0.33, "throttle", "Throttle position", .percent, .throttle, 0...100) { pct($0) },
            one(0x13, 60, "o2_sensors_present", "Oxygen sensors present", .state, .status) { u8($0) },
            one(0x1C, 60, "obd_standard", "OBD standard", .state, .status) { u8($0) },
            one(0x1F, 10, "run_time", "Time since engine start", .seconds, .status) { u16($0) },
            one(0x21, 60, "distance_mil_on", "Distance with check-engine light on", .km, .status) { u16($0) },
            one(0x22, 2, "fuel_rail_pressure_rel", "Fuel rail pressure (relative)", .kpa, .airFuel) { u16($0) * 0.079 },
            one(0x23, 2, "fuel_rail_pressure", "Fuel rail pressure", .kpa, .airFuel) { u16($0) * 10 },
            one(0x2C, 2, "egr_commanded", "Commanded EGR", .percent, .emissions, 0...100) { pct($0) },
            one(0x2D, 2, "egr_error", "EGR error", .percent, .emissions, -100...100) { trim($0) },
            one(0x2E, 2, "evap_purge", "Commanded evaporative purge", .percent, .emissions, 0...100) { pct($0) },
            one(0x2F, 10, "fuel_level", "Fuel level", .percent, .fuel, 0...100) { pct($0) },
            one(0x30, 60, "warmups_since_clear", "Warm-ups since codes cleared", .count, .status) { u8($0) },
            one(0x31, 60, "distance_since_clear", "Distance since codes cleared", .km, .status) { u16($0) },
            one(0x32, 2, "evap_pressure", "Evaporative system vapor pressure", .pascal, .emissions) { s16($0) / 4 },
            one(0x33, 10, "baro", "Barometric pressure", .kpa, .engine, 60...105) { u8($0) },
            one(0x41, 60, "monitor_status_drive", "Monitor status this drive", .state, .status) { u16($0, 0) * 65536 + u16($0, 2) },
            one(0x42, 2, "module_voltage", "Control module voltage", .volts, .electrical, 10...16) { u16($0) / 1000 },
            one(0x43, 2, "absolute_load", "Absolute load", .percent, .engine, 0...100) { u16($0) * 100 / 255 },
            one(0x44, 2, "commanded_eq_ratio", "Commanded equivalence ratio", .lambda, .airFuel, 0.7...1.3) { u16($0) * 2 / 65536 },
            one(0x45, 2, "relative_throttle", "Relative throttle position", .percent, .throttle, 0...100) { pct($0) },
            one(0x46, 10, "ambient_air_temp", "Ambient air temperature", .celsius, .temperatures, -30...50) { temp($0) },
            one(0x47, 2, "throttle_b", "Absolute throttle position B", .percent, .throttle, 0...100) { pct($0) },
            one(0x48, 2, "throttle_c", "Absolute throttle position C", .percent, .throttle, 0...100) { pct($0) },
            one(0x49, 0.33, "pedal_d", "Accelerator pedal position D", .percent, .throttle, 0...100) { pct($0) },
            one(0x4A, 2, "pedal_e", "Accelerator pedal position E", .percent, .throttle, 0...100) { pct($0) },
            one(0x4B, 2, "pedal_f", "Accelerator pedal position F", .percent, .throttle, 0...100) { pct($0) },
            one(0x4C, 2, "commanded_throttle", "Commanded throttle actuator", .percent, .throttle, 0...100) { pct($0) },
            one(0x4D, 60, "time_mil_on", "Time with check-engine light on", .minutes, .status) { u16($0) },
            one(0x4E, 60, "time_since_clear", "Time since codes cleared", .minutes, .status) { u16($0) },
            one(0x51, 60, "fuel_type", "Fuel type", .state, .status) { u8($0) },
            one(0x52, 60, "ethanol_pct", "Ethanol content", .percent, .fuel, 0...100) { pct($0) },
            one(0x53, 2, "evap_abs_pressure", "Evaporative system absolute pressure", .kpa, .emissions) { u16($0) / 200 },
            one(0x54, 2, "evap_pressure_wide", "Evaporative system vapor pressure (wide)", .pascal, .emissions) { u16($0) - 32767 },
            one(0x59, 2, "fuel_rail_abs_pressure", "Fuel rail absolute pressure", .kpa, .airFuel) { u16($0) * 10 },
            one(0x5A, 2, "relative_pedal", "Relative accelerator pedal position", .percent, .throttle, 0...100) { pct($0) },
            one(0x5C, 2, "oil_temp_std", "Engine oil temperature (standard)", .celsius, .temperatures, 40...130) { temp($0) },
            one(0x5D, 2, "injection_timing", "Fuel injection timing", .degrees, .airFuel) { u16($0) / 128 - 210 },
            one(0x5E, 1, "engine_fuel_rate", "Engine fuel rate (reported)", .litersPerHour, .fuel, 0...30) { u16($0) / 20 },
            one(0x61, 1, "demand_torque", "Driver demand torque", .percent, .engine) { u8($0) - 125 },
            one(0x62, 1, "actual_torque", "Actual engine torque", .percent, .engine) { u8($0) - 125 },
            one(0x63, 60, "reference_torque", "Engine reference torque", .newtonMeters, .engine) { u16($0) },
            one(0x65, 60, "aux_io_status", "Auxiliary input/output status", .state, .status) { u16($0) },
            one(0x67, 1, "coolant_temp_2", "Coolant temperature (sensor 1, wide)", .celsius, .temperatures, 40...120) {
                $0[0] & 1 == 1 ? Double($0[1]) - 40 : nil
            },
        ]
        // Narrow-band oxygen sensors: voltage plus the trim they feed (0xFF = not used for trim).
        for i in 0..<8 {
            let pid = UInt8(0x14 + i), pos = o2Positions[i]
            list.append(StandardPID(pid: pid, length: 2, outputs: [
                out(SignalID("o2_\(pos)_voltage"), "Oxygen sensor \(o2Name(i)) voltage", .volts, .airFuel, 0...1.275) { Double($0[0]) / 200 },
                out(SignalID("o2_\(pos)_trim"), "Oxygen sensor \(o2Name(i)) trim", .percent, .airFuel, -25...25) {
                    $0[1] == 0xFF ? nil : (Double($0[1]) - 128) * 100 / 128
                },
            ], period: 2))
        }
        // Wide-range sensors reported as equivalence ratio + voltage, or equivalence ratio + current.
        for i in 0..<8 {
            let pid = UInt8(0x24 + i), pos = o2Positions[i]
            list.append(StandardPID(pid: pid, length: 4, outputs: [
                out(SignalID("o2_\(pos)_eq_ratio_v"), "Oxygen sensor \(o2Name(i)) equivalence ratio (voltage type)", .lambda, .airFuel, 0.7...1.3) { u16($0) * 2 / 65536 },
                out(SignalID("o2_\(pos)_wr_voltage"), "Oxygen sensor \(o2Name(i)) wide-range voltage", .volts, .airFuel, 0...8) { u16($0, 2) * 8 / 65536 },
            ], period: 2))
            let pid2 = UInt8(0x34 + i)
            list.append(StandardPID(pid: pid2, length: 4, outputs: [
                out(SignalID("o2_\(pos)_eq_ratio"), "Oxygen sensor \(o2Name(i)) equivalence ratio", .lambda, .airFuel, 0.7...1.3) { u16($0) * 2 / 65536 },
                out(SignalID("o2_\(pos)_wr_current"), "Oxygen sensor \(o2Name(i)) current", .milliamps, .airFuel, -2...2) { u16($0, 2) / 256 - 128 },
            ], period: 2))
        }
        // Catalyst temperatures (ECU-calculated on many cars).
        for (i, pos) in ["b1s1", "b2s1", "b1s2", "b2s2"].enumerated() {
            list.append(one(UInt8(0x3C + i), 5, SignalID("cat_temp_\(pos)"), "Catalyst temperature \(pos.uppercased())",
                            .celsius, .emissions, 0...900) { u16($0) / 10 - 40 })
        }
        return Dictionary(uniqueKeysWithValues: list.map { ($0.pid, $0) })
    }()

    /// Every signal any standard PID can produce.
    public static var signalInfos: [SignalInfo] { all.values.flatMap { $0.outputs.map(\.info) } }

    /// Splits a (possibly packed) positive service 01 payload (starting with 0x41) into PID -> data.
    /// Stops at the first PID whose length isn't known, since nothing after it can be located.
    public static func split(_ payload: [UInt8]) -> [UInt8: [UInt8]] {
        guard payload.first == 0x41 else { return [:] }
        var out: [UInt8: [UInt8]] = [:]
        var i = 1
        while i < payload.count, let n = lengths[payload[i]], i + 1 + n <= payload.count {
            out[payload[i]] = Array(payload[(i + 1)..<(i + 1 + n)])
            i += 1 + n
        }
        return out
    }

    /// Decodes a "PIDs supported" bitmap reply (PID 0x00, 0x20, ...) into the PIDs it lists.
    public static func supported(base: UInt8, bitmap: [UInt8]) -> Set<UInt8> {
        var s = Set<UInt8>()
        for (byteIndex, byte) in bitmap.prefix(4).enumerated() {
            for bit in 0..<8 where byte & (0x80 >> bit) != 0 {
                s.insert(base &+ UInt8(byteIndex * 8 + bit + 1))
            }
        }
        return s
    }
}
