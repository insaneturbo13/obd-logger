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
