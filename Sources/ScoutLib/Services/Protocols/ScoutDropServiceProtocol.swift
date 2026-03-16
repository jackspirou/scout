import Foundation
import Network

/// Protocol for ScoutDrop peer-to-peer file transfer, enabling mock implementations for testing.
protocol ScoutDropServiceProtocol: Actor {
    /// Start advertising this Mac on the local network.
    func startAdvertising(nickname: String, deviceID: String)

    /// Stop advertising.
    func stopAdvertising()

    /// Start browsing for nearby Scout instances.
    func startBrowsing()

    /// Stop browsing.
    func stopBrowsing()

    /// Stream of current nearby peers, emitted whenever the list changes.
    var peers: AsyncStream<[ScoutDropPeer]> { get }

    /// Send files to a peer. Throws on connection or transfer failure.
    func sendFiles(_ urls: [URL], to peer: ScoutDropPeer) async throws

    /// Cancel an active transfer.
    func cancelTransfer(_ transferID: UUID)

    /// Stream of incoming transfer offers from other peers.
    var incomingOffers: AsyncStream<ScoutDropOffer> { get }

    /// Stream of outgoing verification codes shown to the sender.
    var outgoingVerifications: AsyncStream<(peerName: String, code: String)> { get }

    /// Accept an incoming offer.
    func acceptOffer(_ transferID: UUID)

    /// Decline an incoming offer.
    func declineOffer(_ transferID: UUID)
}
