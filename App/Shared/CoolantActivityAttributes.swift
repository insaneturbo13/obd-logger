import ActivityKit
import Foundation

/// Lock-screen Live Activity while a trip records: coolant first, since that's what the
/// car is being watched for. Display strings are formatted by the app in the user's units.
struct CoolantActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var coolant: String
        /// Needle position across the gauge span, 0...1.
        var coolantPosition: Double
        /// Guide band across the gauge span, 0...1.
        var guideLow: Double
        var guideHigh: Double
        var oil: String
        var status: String
        var hot: Bool
        var stale: Bool
    }

    var tripStart: Date
}

extension CoolantActivityAttributes.ContentState {
    /// The reading without its unit, "203 °F" → "203°", for the Dynamic Island's small spots.
    /// Derived here rather than sent, so the saved state keeps its shape across versions.
    var coolantShort: String {
        let number = coolant.prefix { $0.isNumber || $0 == "-" || $0 == "." || $0 == "," }
        return number.isEmpty ? coolant : String(number) + "°"
    }
}
