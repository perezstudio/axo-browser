import CoreLocation
import Testing
@testable import AxoIntegration

/// A location manager that records requests instead of showing macOS's prompt.
@MainActor
final class FakeLocationManager: LocationManaging {
    var authorizationStatus: CLAuthorizationStatus = .notDetermined
    var requests = 0

    func requestWhenInUseAuthorization() {
        requests += 1
    }
}

@MainActor
struct LocationAuthorizationTests {
    @Test func asksMacOSOnlyBeforeItHasAnswered() {
        let manager = FakeLocationManager()
        let authorization = LocationAuthorization(manager: manager)
        #expect(manager.requests == 0, "Creating it doesn't prompt")

        authorization.requestIfNeeded()
        #expect(manager.requests == 1)

        for status in [CLAuthorizationStatus.authorizedAlways, .denied, .restricted] {
            manager.authorizationStatus = status
            #expect(!authorization.isUndetermined)
            authorization.requestIfNeeded()
        }
        #expect(manager.requests == 1, "Once macOS has an answer, Axo doesn't ask again")
    }
}
