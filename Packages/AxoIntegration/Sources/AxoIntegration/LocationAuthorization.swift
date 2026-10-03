import CoreLocation
import Foundation

/// The parts of `CLLocationManager` that ``LocationAuthorization`` uses, so tests can use a fake
/// that never shows macOS's location prompt.
@MainActor
public protocol LocationManaging: AnyObject {
    var authorizationStatus: CLAuthorizationStatus { get }
    func requestWhenInUseAuthorization()
}

extension CLLocationManager: LocationManaging {}

/// Axo's standing with macOS location services.
///
/// WebKit doesn't ask Axo about a page's location request (`navigator.geolocation`) until Axo
/// has its own `CLLocationManager`, so the app keeps one for its lifetime. Creating it doesn't
/// prompt. macOS asks the person only when ``requestIfNeeded()`` runs, which Axo does after the
/// person allows a site's location request, so the macOS prompt follows from something they
/// chose. See `docs/webkit-gaps.md`.
@MainActor
public final class LocationAuthorization {
    private let manager: any LocationManaging

    /// Creates the location manager. Pass a fake in tests.
    public init(manager: any LocationManaging = CLLocationManager()) {
        self.manager = manager
    }

    /// Whether macOS hasn't asked the person about Axo and location yet.
    public var isUndetermined: Bool {
        manager.authorizationStatus == .notDetermined
    }

    /// Asks macOS for location access if it hasn't asked before. macOS shows its prompt once;
    /// after the person answers, this does nothing.
    public func requestIfNeeded() {
        guard isUndetermined else { return }
        manager.requestWhenInUseAuthorization()
    }
}
