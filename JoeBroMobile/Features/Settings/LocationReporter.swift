import SwiftUI
import CoreLocation

/// Reports the latest fix to the paired backend (no history kept server-side).
/// Significant-change monitoring plus one report each time the app comes to the foreground.
@MainActor
final class LocationReporter: NSObject, CLLocationManagerDelegate {
    static let shared = LocationReporter()
    static let enabledKey = "locationReportingEnabled"

    private let manager = CLLocationManager()
    private var lastSent = Date.distantPast

    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    override private init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on { start() } else { manager.stopMonitoringSignificantLocationChanges() }
    }

    /// Call on launch and every time the app becomes active.
    func start() {
        guard enabled else { return }
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startMonitoringSignificantLocationChanges()
            manager.requestLocation()
        default: break
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.start() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last else { return }
        Task { @MainActor in await self.post(fix) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    private func post(_ fix: CLLocation) async {
        guard enabled, Date().timeIntervalSince(lastSent) > 60,
              let api = ServerConfig.api()
        else { return }
        lastSent = Date()
        let body: [String: Any] = ["lat": fix.coordinate.latitude, "lon": fix.coordinate.longitude,
                                   "accuracy": fix.horizontalAccuracy, "timestamp": fix.timestamp.timeIntervalSince1970]
        _ = try? await api.send(JoeBroAPI.OK.self, "api/personal/location", json: body)
    }
}

/// Settings row: share location with the personal agent.
struct LocationToggleRow: View {
    @State private var on = LocationReporter.shared.enabled

    var body: some View {
        Toggle(isOn: Binding(get: { on }, set: { on = $0; LocationReporter.shared.setEnabled($0) })) {
            Label("Share location", systemImage: "location")
        }
    }
}
