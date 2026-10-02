import CoreLocation
import Foundation
import OBDKit

/// GPS while a trip records. Also what keeps the app running with the screen off or with
/// Maps in front: an app receiving location updates in the background isn't suspended.
@MainActor
final class LocationRecorder: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onSamples: (([Sample]) -> Void)?
    private(set) var running = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.distanceFilter = kCLDistanceFilterNone
    }

    var authorization: CLAuthorizationStatus { manager.authorizationStatus }

    func requestAuthorization() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    func start() {
        requestAuthorization()
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        running = true
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        running = false
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        var samples: [Sample] = []
        for l in locations where l.horizontalAccuracy >= 0 {
            let t = l.timestamp
            samples.append(Sample(GPSSignals.latitude, l.coordinate.latitude, t))
            samples.append(Sample(GPSSignals.longitude, l.coordinate.longitude, t))
            samples.append(Sample(GPSSignals.accuracy, l.horizontalAccuracy, t))
            if l.speed >= 0 { samples.append(Sample(GPSSignals.speed, l.speed * 3.6, t)) }
            if l.verticalAccuracy >= 0 { samples.append(Sample(GPSSignals.altitude, l.altitude, t)) }
            if l.course >= 0 { samples.append(Sample(GPSSignals.course, l.course, t)) }
        }
        Task { @MainActor in self.onSamples?(samples) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
