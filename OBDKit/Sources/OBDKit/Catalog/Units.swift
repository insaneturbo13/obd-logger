import Foundation

/// Units samples are stored in. Display conversion happens once, at the edge (UI, exports).
public enum BaseUnit: String, Codable, Sendable, CaseIterable {
    case celsius, kmh, kpa, pascal, percent, volts, milliamps, gramsPerSecond, rpm
    case seconds, minutes, km, degrees, lambda, ratio, count, raw, state
    case newtonMeters, litersPerHour, liters, kmPerLiter, kilowatts, metersPerSecond2, meters
    case coordinate, rpmPerKmh

    public var symbol: String {
        switch self {
        case .celsius: return "°C"
        case .kmh: return "km/h"
        case .kpa: return "kPa"
        case .pascal: return "Pa"
        case .percent: return "%"
        case .volts: return "V"
        case .milliamps: return "mA"
        case .gramsPerSecond: return "g/s"
        case .rpm: return "rpm"
        case .seconds: return "s"
        case .minutes: return "min"
        case .km: return "km"
        case .degrees: return "°"
        case .lambda: return "λ"
        case .ratio: return ""
        case .count: return ""
        case .raw: return "raw"
        case .state: return ""
        case .newtonMeters: return "N·m"
        case .litersPerHour: return "L/h"
        case .liters: return "L"
        case .kmPerLiter: return "km/L"
        case .kilowatts: return "kW"
        case .metersPerSecond2: return "m/s²"
        case .meters: return "m"
        case .coordinate: return ""
        case .rpmPerKmh: return "rpm per km/h"
        }
    }
}

public struct DisplayPreferences: Codable, Sendable, Equatable {
    public enum Temperature: String, Codable, Sendable, CaseIterable { case fahrenheit, celsius }
    public enum Speed: String, Codable, Sendable, CaseIterable { case mph, kmh }
    public enum Pressure: String, Codable, Sendable, CaseIterable { case kpa, psi }
    public enum FuelEconomy: String, Codable, Sendable, CaseIterable { case mpgUS, litersPer100km }

    public var temperature: Temperature
    public var speed: Speed
    public var pressure: Pressure
    public var fuelEconomy: FuelEconomy
    /// Show equivalence ratio as gasoline air-fuel ratio (λ × 14.7).
    public var lambdaAsAFR: Bool

    public init(temperature: Temperature = .fahrenheit, speed: Speed = .mph, pressure: Pressure = .kpa,
                fuelEconomy: FuelEconomy = .mpgUS, lambdaAsAFR: Bool = true) {
        self.temperature = temperature
        self.speed = speed
        self.pressure = pressure
        self.fuelEconomy = fuelEconomy
        self.lambdaAsAFR = lambdaAsAFR
    }

    public static let us = DisplayPreferences()
    public static let metric = DisplayPreferences(temperature: .celsius, speed: .kmh, pressure: .kpa,
                                                  fuelEconomy: .litersPer100km, lambdaAsAFR: false)
}

public struct DisplayValue: Sendable, Equatable {
    public var value: Double
    public var unit: String
    public var decimals: Int

    public init(value: Double, unit: String, decimals: Int) {
        self.value = value
        self.unit = unit
        self.decimals = decimals
    }

    public var text: String { DisplayValue.format(value, decimals: decimals) }
    public var textWithUnit: String { unit.isEmpty ? text : "\(text) \(unit)" }

    public static func format(_ v: Double, decimals: Int) -> String {
        guard v.isFinite else { return "–" }
        return String(format: "%.\(max(0, decimals))f", v)
    }
}

public enum UnitConverter {
    public static let stoichiometricAFR = 14.7
    public static let milesPerKm = 0.621371192237334
    public static let gallonsPerLiter = 0.264172052358148

    /// Converts a stored value into the user's display units.
    public static func display(_ value: Double, unit: BaseUnit, prefs: DisplayPreferences, decimals: Int? = nil) -> DisplayValue {
        func dv(_ v: Double, _ u: String, _ d: Int) -> DisplayValue { DisplayValue(value: v, unit: u, decimals: decimals ?? d) }
        switch unit {
        case .celsius:
            return prefs.temperature == .fahrenheit ? dv(value * 9 / 5 + 32, "°F", 0) : dv(value, "°C", 0)
        case .kmh:
            return prefs.speed == .mph ? dv(value * milesPerKm, "mph", 0) : dv(value, "km/h", 0)
        case .km:
            return prefs.speed == .mph ? dv(value * milesPerKm, "mi", 1) : dv(value, "km", 1)
        case .kpa:
            return prefs.pressure == .psi ? dv(value * 0.145037738, "psi", 1) : dv(value, "kPa", 0)
        case .lambda:
            return prefs.lambdaAsAFR ? dv(value * stoichiometricAFR, "AFR", 2) : dv(value, "λ", 3)
        case .liters:
            return prefs.speed == .mph ? dv(value * gallonsPerLiter, "gal", 2) : dv(value, "L", 2)
        case .litersPerHour:
            return prefs.speed == .mph ? dv(value * gallonsPerLiter, "gal/h", 2) : dv(value, "L/h", 2)
        case .kmPerLiter:
            switch prefs.fuelEconomy {
            case .mpgUS: return dv(value * milesPerKm / gallonsPerLiter, "mpg", 1)
            case .litersPer100km: return dv(value > 0 ? 100 / value : .infinity, "L/100 km", 1)
            }
        case .kilowatts:
            return prefs.speed == .mph ? dv(value * 1.34102209, "hp", 0) : dv(value, "kW", 0)
        case .meters:
            return prefs.speed == .mph ? dv(value * 3.2808399, "ft", 0) : dv(value, "m", 0)
        case .rpmPerKmh:
            return prefs.speed == .mph ? dv(value / milesPerKm, "rpm/mph", 1) : dv(value, "rpm/(km/h)", 1)
        case .volts: return dv(value, "V", 1)
        case .percent: return dv(value, "%", 1)
        case .rpm: return dv(value, "rpm", 0)
        case .gramsPerSecond: return dv(value, "g/s", 1)
        case .degrees: return dv(value, "°", 1)
        case .milliamps: return dv(value, "mA", 2)
        case .pascal: return dv(value, "Pa", 0)
        case .seconds, .minutes, .count, .state, .raw, .newtonMeters:
            return dv(value, unit.symbol, 0)
        case .ratio: return dv(value, "", 3)
        case .metersPerSecond2: return dv(value, "m/s²", 2)
        case .coordinate: return dv(value, "", 6)
        }
    }

    /// Inverse of `display` for the value part, used to turn display-unit thresholds into stored units.
    public static func toBase(_ displayValue: Double, unit: BaseUnit, prefs: DisplayPreferences) -> Double {
        switch unit {
        case .celsius: return prefs.temperature == .fahrenheit ? (displayValue - 32) * 5 / 9 : displayValue
        case .kmh, .km: return prefs.speed == .mph ? displayValue / milesPerKm : displayValue
        case .kpa: return prefs.pressure == .psi ? displayValue / 0.145037738 : displayValue
        case .lambda: return prefs.lambdaAsAFR ? displayValue / stoichiometricAFR : displayValue
        default: return displayValue
        }
    }
}
