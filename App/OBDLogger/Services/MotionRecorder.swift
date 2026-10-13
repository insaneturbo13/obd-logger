import CoreMotion
import Foundation
import OBDKit

/// The device's motion sensors and barometer while a trip records. Motion is read 50 times
/// a second and kept as one set of values per half second (`MotionAverager`): mean gravity,
/// acceleration and rotation, plus the peak vertical jolt so bumps survive the averaging.
/// The barometer adds air pressure and altitude. Pitch, roll and the car-frame accelerations
/// are worked out from these at the end of the trip (`MountCalibration`), which needs the
/// device to sit in a fixed mount; a little bounce is fine.
///
/// Runs in the background for as long as the app does (GPS keeps it running during a trip).
@MainActor
final class MotionRecorder {
    private let motion = CMMotionManager()
    private let altimeter = CMAltimeter()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "motion"
        q.maxConcurrentOperationCount = 1
        return q
    }()
    /// Touched only on `queue`.
    private final class Box: @unchecked Sendable { var averager = MotionAverager() }
    private var box = Box()

    var onSamples: (([Sample]) -> Void)?
    var onBump: ((MotionAverager.Bump) -> Void)?
    private(set) var running = false

    /// Core Motion stamps readings with seconds since boot; this turns one into a Date.
    nonisolated private static func date(uptime: TimeInterval) -> Date {
        Date(timeIntervalSinceNow: uptime - ProcessInfo.processInfo.systemUptime)
    }

    func start() {
        guard !running else { return }
        running = true
        let box = Box()
        self.box = box
        // The handlers are @Sendable so they don't inherit this class's main-actor isolation:
        // Core Motion calls them on `queue`.
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 1.0 / 50
            motion.startDeviceMotionUpdates(to: queue) { @Sendable [weak self] m, _ in
                guard let m else { return }
                // Core Motion reports gravity minus the device's acceleration (a device lying face up
                // reads -1 g on z), so userAcceleration points opposite to the way the device actually
                // speeds up. Negated here so + means accelerating along that axis.
                let a = m.userAcceleration
                let reading = MotionAverager.Reading(
                    time: Self.date(uptime: m.timestamp),
                    gravity: Vec3(m.gravity.x, m.gravity.y, m.gravity.z),
                    acceleration: Vec3(-a.x, -a.y, -a.z),
                    rotation: Vec3(m.rotationRate.x, m.rotationRate.y, m.rotationRate.z))
                let out = box.averager.add(reading)
                guard !out.samples.isEmpty || out.bump != nil else { return }
                Task { @MainActor in
                    if !out.samples.isEmpty { self?.onSamples?(out.samples) }
                    if let bump = out.bump { self?.onBump?(bump) }
                }
            }
        }
        // The barometer needs Motion & Fitness permission; asking happens on first use.
        let status = CMAltimeter.authorizationStatus()
        guard status != .denied && status != .restricted else { return }
        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: queue) { @Sendable [weak self] data, _ in
                guard let data else { return }
                let t = Self.date(uptime: data.timestamp)
                let samples = [Sample(PhoneSignals.relativeAltitude, data.relativeAltitude.doubleValue, t),
                               Sample(PhoneSignals.pressure, data.pressure.doubleValue, t)]
                Task { @MainActor in self?.onSamples?(samples) }
            }
        }
        if CMAltimeter.isAbsoluteAltitudeAvailable() {
            altimeter.startAbsoluteAltitudeUpdates(to: queue) { @Sendable [weak self] data, _ in
                guard let data, data.accuracy >= 0 else { return }
                let sample = Sample(PhoneSignals.altitude, data.altitude, Self.date(uptime: data.timestamp))
                Task { @MainActor in self?.onSamples?([sample]) }
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        motion.stopDeviceMotionUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        altimeter.stopAbsoluteAltitudeUpdates()
    }
}
