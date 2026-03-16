import Foundation
import Network

// MARK: - ScoutDropPeerState

enum ScoutDropPeerState {
    case discovered
    case connecting
    case connected
    case transferring(progress: Double)  // 0.0 to 1.0
    case disconnected
}

// MARK: - ScoutDropPeer

/// A discovered peer on the local network. Uses class (reference) semantics
/// because NSOutlineView relies on object identity for item tracking.
final class ScoutDropPeer: Identifiable {
    let id: UUID
    var name: String
    let endpoint: NWEndpoint
    var state: ScoutDropPeerState
    var deviceID: String?

    init(
        id: UUID = UUID(),
        name: String,
        endpoint: NWEndpoint,
        state: ScoutDropPeerState = .discovered,
        deviceID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.state = state
        self.deviceID = deviceID
    }
}
