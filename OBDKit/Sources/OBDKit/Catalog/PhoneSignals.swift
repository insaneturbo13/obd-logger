import Foundation

/// The recording device's own sensors: motion (gravity, acceleration, rotation) and the
/// barometer. The raw values are in the device's frame, so they depend on how it's mounted;
/// the vehicle-frame values (pitch, roll, longitudinal and lateral acceleration, yaw rate)
/// and the road grade are worked out from them at the end of each trip (`MountCalibration`).
public enum PhoneSignals {
    // Recorded live, one value per half second.
    public static let gravityX: SignalID = "phone_gravity_x"
    public static let gravityY: SignalID = "phone_gravity_y"
    public static let gravityZ: SignalID = "phone_gravity_z"
    public static let accelX: SignalID = "phone_accel_x"
    public static let accelY: SignalID = "phone_accel_y"
    public static let accelZ: SignalID = "phone_accel_z"
    public static let rotationX: SignalID = "phone_rotation_x"
    public static let rotationY: SignalID = "phone_rotation_y"
    public static let rotationZ: SignalID = "phone_rotation_z"
    /// Largest acceleration along gravity within the half second: bumps and potholes.
    public static let joltPeak: SignalID = "phone_jolt_peak"
    /// RMS of the acceleration along gravity within the half second: how rough the road is.
    public static let vibration: SignalID = "phone_vibration_rms"
    public static let pressure: SignalID = "phone_pressure"
    /// Barometric altitude change since recording started.
    public static let relativeAltitude: SignalID = "phone_rel_altitude"
    /// Absolute altitude from the barometer (devices that support it).
    public static let altitude: SignalID = "phone_altitude"

    // Worked out at the end of the trip.
    public static let pitch: SignalID = "vehicle_pitch"
    public static let roll: SignalID = "vehicle_roll"
    public static let longitudinal: SignalID = "vehicle_accel_long"
    public static let lateral: SignalID = "vehicle_accel_lat"
    public static let yawRate: SignalID = "vehicle_yaw_rate"
    public static let grade: SignalID = "road_grade"

    public static let gravity = [gravityX, gravityY, gravityZ]
    public static let acceleration = [accelX, accelY, accelZ]
    public static let rotation = [rotationX, rotationY, rotationZ]

    private static func info(_ id: SignalID, _ name: String, _ unit: BaseUnit, _ range: ClosedRange<Double>? = nil) -> SignalInfo {
        SignalInfo(id: id, name: name, unit: unit, category: .motion, source: .phone, range: range)
    }

    public static let recorded: [SignalInfo] = [
        info(gravityX, "Phone gravity X", .metersPerSecond2, -10...10),
        info(gravityY, "Phone gravity Y", .metersPerSecond2, -10...10),
        info(gravityZ, "Phone gravity Z", .metersPerSecond2, -10...10),
        info(accelX, "Phone acceleration X", .metersPerSecond2, -6...6),
        info(accelY, "Phone acceleration Y", .metersPerSecond2, -6...6),
        info(accelZ, "Phone acceleration Z", .metersPerSecond2, -6...6),
        info(rotationX, "Phone rotation rate X", .degreesPerSecond, -60...60),
        info(rotationY, "Phone rotation rate Y", .degreesPerSecond, -60...60),
        info(rotationZ, "Phone rotation rate Z", .degreesPerSecond, -60...60),
        info(joltPeak, "Vertical jolt peak", .metersPerSecond2, 0...15),
        info(vibration, "Vertical vibration RMS", .metersPerSecond2, 0...5),
        info(pressure, "Barometric pressure (phone)", .kpa, 70...105),
        info(relativeAltitude, "Altitude change (barometer)", .meters),
        info(altitude, "Altitude (barometer)", .meters),
    ]

    public static let calibrated: [SignalInfo] = [
        info(pitch, "Vehicle pitch", .degrees, -10...10),
        info(roll, "Vehicle roll", .degrees, -10...10),
        info(longitudinal, "Longitudinal acceleration", .metersPerSecond2, -6...6),
        info(lateral, "Lateral acceleration", .metersPerSecond2, -6...6),
        info(yawRate, "Yaw rate", .degreesPerSecond, -40...40),
        info(grade, "Road grade", .percent, -10...10),
    ]

    public static let infos = recorded + calibrated
}
