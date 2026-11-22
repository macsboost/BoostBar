import CoreLocation
import CoreWLAN

/// The current Wi‑Fi network name, for the network hover chart. Since macOS 14 the SSID is only
/// given to apps allowed to use Location Services, so the first time it's needed BoostBar asks once.
/// BoostBar never starts location updates — the permission just unlocks the network name.
final class WiFiInfo: NSObject, CLLocationManagerDelegate {
    static let shared = WiFiInfo()
    private let manager = CLLocationManager()
    private var asked = false

    override init() {
        super.init()
        manager.delegate = self
    }

    enum Name { case name(String), needsPermission, denied, none }

    /// SSID of the Wi‑Fi interface `bsd` (or the default Wi‑Fi interface).
    func networkName(for bsd: String? = nil) -> Name {
        let client = CWWiFiClient.shared()
        let iface = bsd.flatMap { client.interface(withName: $0) } ?? client.interface()
        if let ssid = iface?.ssid(), !ssid.isEmpty { return .name(ssid) }
        switch manager.authorizationStatus {
        case .notDetermined:
            if !asked {
                asked = true
                manager.requestWhenInUseAuthorization()
            }
            return .needsPermission
        case .denied, .restricted:
            return .denied
        default:
            return .none
        }
    }

    /// One line for the hover chart, or nil when there's nothing useful to say.
    func line(for bsd: String? = nil) -> String? {
        switch networkName(for: bsd) {
        case .name(let n): return "Network: \(n)"
        case .needsPermission: return "Network name: allow BoostBar in the Location Services prompt to show it"
        case .denied: return "Network name hidden — allow BoostBar in System Settings ▸ Privacy & Security ▸ Location Services"
        case .none: return nil
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        NotificationCenter.default.post(name: .boostBarStateChanged, object: nil)
    }
}
