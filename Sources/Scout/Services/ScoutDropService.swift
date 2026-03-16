import CryptoKit
import Foundation
import Network
import Security

// MARK: - ScoutDropError

enum ScoutDropError: LocalizedError {
    case connectionFailed(String)
    case transferDeclined
    case transferTimeout
    case invalidMessage
    case connectionClosed
    case writeFailed(String)
    case checksumMismatch(String)
    case identityKeyMismatch(String)

    var errorDescription: String? {
        switch self {
        case let .connectionFailed(msg): return "Connection failed: \(msg)"
        case .transferDeclined: return "Transfer was declined"
        case .transferTimeout: return "Transfer timed out"
        case .invalidMessage: return "Received invalid message"
        case .connectionClosed: return "Connection closed unexpectedly"
        case let .writeFailed(msg): return "Failed to write file: \(msg)"
        case let .checksumMismatch(path): return "Checksum mismatch for \(path)"
        case let .identityKeyMismatch(name): return "Identity changed for \(name). The peer's cryptographic identity does not match the previously trusted key."
        }
    }
}

// MARK: - ScoutDropService

/// Actor-based service for peer-to-peer file transfer using Network.framework.
///
/// Manages Bonjour advertisement and discovery of nearby Scout instances,
/// and handles the send/receive flow for file transfers using a binary-framed
/// wire protocol (NWProtocolFramer) over QUIC with per-file stream multiplexing.
actor ScoutDropService: ScoutDropServiceProtocol {

    // MARK: - Constants

    private static let chunkSize = 524_288          // 512KB — QUIC handles segmentation
    private static let maxConcurrentStreams = 4      // max file streams in flight
    private static let receiveTimeout: TimeInterval = 30
    private static let serviceType = "_scoutdrop._udp"
    private static let alpn = ["scoutdrop/1"]
    private static let contentID = "ScoutDrop"
    private static let downloadDirName = "ScoutDrop"
    private static let txtKeyNickname = "nickname"
    private static let txtKeyDeviceID = "deviceID"

    // MARK: - AsyncStream Properties

    nonisolated let peers: AsyncStream<[ScoutDropPeer]>
    private let peersContinuation: AsyncStream<[ScoutDropPeer]>.Continuation

    nonisolated let incomingOffers: AsyncStream<ScoutDropOffer>
    private let offersContinuation: AsyncStream<ScoutDropOffer>.Continuation

    nonisolated let outgoingVerifications: AsyncStream<(peerName: String, code: String)>
    private let outgoingVerificationContinuation: AsyncStream<(peerName: String, code: String)>.Continuation

    // MARK: - Types

    /// Result from receiving a single file on a QUIC stream.
    private struct ReceivedFile: Sendable {
        let fileIndex: Int
        let incompletePath: URL
    }

    // MARK: - State

    private var localIdentity: SecIdentity?
    private var advertisedDeviceID: String = ""
    private var currentPeers: [NWEndpoint: ScoutDropPeer] = [:]
    private var pendingOffers: [UUID: (connection: NWConnection, offer: ScoutDropOffer, group: NWConnectionGroup)] = [:]
    private var activeTransfers: [UUID: Task<Void, Never>] = [:]

    private var browser: NWBrowser?
    private var listener: NWListener?
    private var activeGroups: [NWConnectionGroup] = []

    /// Routes incoming file streams to the correct transfer's continuation.
    private var fileStreamContinuations: [ObjectIdentifier: AsyncStream<NWConnection>.Continuation] = [:]

    // MARK: - Init

    init() {
        let (peerStream, peerCont) = AsyncStream.makeStream(of: [ScoutDropPeer].self)
        peers = peerStream
        peersContinuation = peerCont

        let (offerStream, offerCont) = AsyncStream.makeStream(of: ScoutDropOffer.self)
        incomingOffers = offerStream
        offersContinuation = offerCont

        let (verStream, verCont) = AsyncStream.makeStream(of: (peerName: String, code: String).self)
        outgoingVerifications = verStream
        outgoingVerificationContinuation = verCont
    }

    // MARK: - Advertising

    func startAdvertising(nickname: String, deviceID: String) {
        stopAdvertising()
        advertisedDeviceID = deviceID

        // Load or generate the persistent TLS identity for TOFU certificate pinning.
        if localIdentity == nil {
            do {
                localIdentity = try ScoutDropIdentity.getOrCreateIdentity()
            } catch {
                NSLog("[ScoutDropService] Failed to create TLS identity: %@", error.localizedDescription)
            }
        }

        do {
            let quicOptions = NWProtocolQUIC.Options(alpn: Self.alpn)
            if let identity = localIdentity {
                Self.configureTLSForListener(quicOptions, identity: identity)
            } else {
                Self.configureTLSAcceptAll(quicOptions)
            }

            let listenerParams = NWParameters(quic: quicOptions)
            listenerParams.includePeerToPeer = true

            // Add the binary framer to the listener's protocol stack.
            let framerOptions = NWProtocolFramer.Options(definition: ScoutDropFramer.definition)
            listenerParams.defaultProtocolStack.applicationProtocols.insert(framerOptions, at: 0)

            let newListener = try NWListener(using: listenerParams)
            let txtRecord = NWTXTRecord([Self.txtKeyNickname: nickname, Self.txtKeyDeviceID: deviceID])
            newListener.service = NWListener.Service(
                name: nickname,
                type: Self.serviceType,
                txtRecord: txtRecord
            )

            newListener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    NSLog("[ScoutDropService] Listener ready on port %d", newListener.port?.rawValue ?? 0)
                case let .failed(error):
                    NSLog("[ScoutDropService] Listener failed: %@", error.localizedDescription)
                    Task { await self.stopAdvertising() }
                default:
                    break
                }
            }

            newListener.newConnectionGroupHandler = { [weak self] group in
                guard let self else { return }
                Task { await self.handleIncomingGroup(group) }
            }

            newListener.start(queue: .main)
            listener = newListener
        } catch {
            NSLog("[ScoutDropService] Failed to create listener: %@", error.localizedDescription)
        }
    }

    func stopAdvertising() {
        listener?.cancel()
        listener = nil
        for group in activeGroups { group.cancel() }
        activeGroups.removeAll()
    }

    // MARK: - Browsing

    func startBrowsing() {
        stopBrowsing()

        let params = NWParameters()
        params.includePeerToPeer = true

        let newBrowser = NWBrowser(
            for: .bonjour(type: Self.serviceType, domain: nil),
            using: params
        )

        newBrowser.stateUpdateHandler = { state in
            switch state {
            case .ready:
                NSLog("[ScoutDropService] Browser ready")
            case let .failed(error):
                NSLog("[ScoutDropService] Browser failed: %@", error.localizedDescription)
            default:
                break
            }
        }

        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            Task { await self.handleBrowseResults(results) }
        }

        newBrowser.start(queue: .main)
        browser = newBrowser
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        currentPeers.removeAll()
    }

    // MARK: - Send Flow

    func sendFiles(_ urls: [URL], to peer: ScoutDropPeer) async throws {
        let transferID = UUID()

        // Build file entries.
        let (entries, basePaths) = buildFileEntries(urls: urls)
        let totalSize = entries.reduce(Int64(0)) { $0 + $1.size }

        // Connect to peer.
        peer.state = .connecting
        emitPeers()

        let (group, controlStream, peerKeyHash) = try await connect(
            to: peer.endpoint, peerDeviceID: peer.deviceID
        )

        peer.state = .connected
        emitPeers()

        // Store the peer's public key hash for TOFU (first use or update).
        if let deviceID = peer.deviceID, let peerKeyHash {
            PersistenceService.shared.saveScoutDropPeerKeyHash(
                deviceID: deviceID, keyHash: peerKeyHash
            )
        }

        // Generate verification code for PIN verification.
        let verificationCode = String(format: "%06d", Int.random(in: 0...999_999))

        // Emit the code to the sender's UI.
        outgoingVerificationContinuation.yield((peer.name, verificationCode))

        // Send offer.
        let offerMeta = ScoutDropOfferMetadata(
            senderName: Host.current().localizedName ?? "Unknown Mac",
            transferID: transferID,
            files: entries,
            totalSize: totalSize,
            verificationCode: verificationCode,
            senderDeviceID: advertisedDeviceID
        )
        try await sendControl(
            type: ScoutDropFrameHeader.typeOffer,
            metadata: offerMeta,
            on: controlStream
        )

        // Wait for accept/decline.
        let (responseHeader, responseMetadata, _) = try await receiveMessage(on: controlStream)

        guard responseHeader.messageType == ScoutDropFrameHeader.typeAccept else {
            controlStream.cancel()
            peer.state = .connected
            emitPeers()
            throw ScoutDropError.transferDeclined
        }

        // Parse resume offsets from the accept message.
        let acceptMeta = try JSONDecoder().decode(ScoutDropAcceptMetadata.self, from: responseMetadata)

        // Send files on per-file QUIC streams.
        try await sendFilesStreamed(
            basePaths: basePaths,
            transferID: transferID,
            totalSize: totalSize,
            resumeOffsets: acceptMeta.resumeOffsets,
            peer: peer,
            group: group,
            controlStream: controlStream
        )
    }

    // MARK: - Transfer Control

    func cancelTransfer(_ transferID: UUID) {
        if let task = activeTransfers.removeValue(forKey: transferID) {
            task.cancel()
        }
        if let pending = pendingOffers.removeValue(forKey: transferID) {
            let controlMeta = ScoutDropControlMetadata(
                transferID: transferID,
                errorMessage: "Transfer cancelled"
            )
            sendControlFireAndForget(
                type: ScoutDropFrameHeader.typeError, metadata: controlMeta, on: pending.connection
            )
            pending.connection.cancel()
        }
    }

    func acceptOffer(_ transferID: UUID) {
        guard let pending = pendingOffers.removeValue(forKey: transferID) else { return }

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.receiveFilesStreamed(
                    controlConnection: pending.connection,
                    offer: pending.offer,
                    transferID: transferID,
                    group: pending.group
                )
            } catch {
                NSLog("[ScoutDropService] Receive failed: %@", error.localizedDescription)
            }
            await self.removeActiveTransfer(transferID)
        }
        activeTransfers[transferID] = task
    }

    func declineOffer(_ transferID: UUID) {
        guard let pending = pendingOffers.removeValue(forKey: transferID) else { return }

        let controlMeta = ScoutDropControlMetadata(transferID: transferID)
        sendControlFireAndForget(
            type: ScoutDropFrameHeader.typeDecline, metadata: controlMeta, on: pending.connection
        )
        pending.connection.cancel()
    }

    // MARK: - Private: Connection Handling

    private func handleIncomingGroup(_ group: NWConnectionGroup) {
        // Claim the peer's public key hash extracted during TLS handshake.
        // The verify block writes to `lastExtractedPeerHash` on `.main` before
        // this handler is called (also on `.main`), so the ordering is guaranteed.
        if let peerHash = Self.lastExtractedPeerHash {
            incomingPeerKeyHashes[ObjectIdentifier(group)] = peerHash
            Self.lastExtractedPeerHash = nil
        }

        activeGroups.append(group)

        group.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                NSLog("[ScoutDropService] Incoming QUIC tunnel ready")
            case let .failed(error):
                NSLog("[ScoutDropService] Incoming QUIC tunnel failed: %@", error.localizedDescription)
                group.cancel()
                Task { await self.removeGroup(group) }
            case .cancelled:
                Task { await self.removeGroup(group) }
            default:
                break
            }
        }

        // Route incoming streams: first = control, subsequent = file streams.
        group.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.routeIncomingStream(connection, group: group) }
        }

        group.start(queue: .main)
    }

    private func removeGroup(_ group: NWConnectionGroup) {
        activeGroups.removeAll { $0 === group }
        incomingPeerKeyHashes.removeValue(forKey: ObjectIdentifier(group))
        if let cont = fileStreamContinuations.removeValue(forKey: ObjectIdentifier(group)) {
            cont.finish()
        }
    }

    // MARK: - Private: Path Traversal Validation

    /// Returns the resolved path if it stays within `destDir`, or `nil` if
    /// the relative path would escape (zip-slip / path traversal attack).
    private func validatedPath(
        relativePath: String, within destDir: URL
    ) -> URL? {
        let resolved = destDir.appendingPathComponent(relativePath).standardizedFileURL
        let destPrefix = destDir.standardizedFileURL.path + "/"
        guard resolved.standardizedFileURL.path.hasPrefix(destPrefix) else {
            NSLog("[ScoutDropService] Rejected path traversal: %@", relativePath)
            return nil
        }
        return resolved
    }

    private func routeIncomingStream(_ connection: NWConnection, group: NWConnectionGroup) {
        let key = ObjectIdentifier(group)
        if let cont = fileStreamContinuations[key] {
            // File stream — route to the ongoing transfer.
            cont.yield(connection)
        } else {
            // First stream on this group — control stream.
            handleControlStream(connection, group: group)
        }
    }

    private func handleControlStream(_ connection: NWConnection, group: NWConnectionGroup) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Task { await self.readInitialOffer(on: connection, group: group) }
            case let .failed(error):
                NSLog("[ScoutDropService] Control stream failed: %@", error.localizedDescription)
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    private func readInitialOffer(on connection: NWConnection, group: NWConnectionGroup) async {
        do {
            let (header, metaData, _) = try await receiveMessage(on: connection)

            guard header.messageType == ScoutDropFrameHeader.typeOffer else {
                NSLog("[ScoutDropService] First message was not a valid offer")
                connection.cancel()
                return
            }

            let offerMeta = try JSONDecoder().decode(ScoutDropOfferMetadata.self, from: metaData)

            // Retrieve the peer's public key hash extracted during TLS handshake.
            let peerKeyHash = incomingPeerKeyHashes.removeValue(forKey: ObjectIdentifier(group))

            let offer = ScoutDropOffer(
                id: offerMeta.transferID,
                senderName: offerMeta.senderName,
                files: offerMeta.files,
                totalSize: offerMeta.totalSize,
                verificationCode: offerMeta.verificationCode,
                senderDeviceID: offerMeta.senderDeviceID,
                peerPublicKeyHash: peerKeyHash
            )

            pendingOffers[offerMeta.transferID] = (connection: connection, offer: offer, group: group)
            offersContinuation.yield(offer)
        } catch {
            NSLog("[ScoutDropService] Failed to read offer: %@", error.localizedDescription)
            connection.cancel()
        }
    }

    // MARK: - Private: Send Files (Per-File QUIC Streams)

    private func sendFilesStreamed(
        basePaths: [(URL, String)],
        transferID: UUID,
        totalSize: Int64,
        resumeOffsets: [Int: Int64],
        peer: ScoutDropPeer,
        group: NWConnectionGroup,
        controlStream: NWConnection
    ) async throws {
        guard basePaths.count <= Int(UInt16.max) else {
            throw ScoutDropError.connectionFailed(
                "Transfer contains more than 65535 files, which exceeds the protocol limit"
            )
        }

        let initialBytes = resumeOffsets.values.reduce(Int64(0), +)

        // Progress tracking via AsyncStream — file tasks yield byte deltas.
        let (progressPipe, progressCont) = AsyncStream.makeStream(of: Int64.self)

        let progressTask = Task {
            var totalSent = initialBytes
            var lastEmit = ContinuousClock.now
            for await delta in progressPipe {
                totalSent += delta
                let now = ContinuousClock.now
                if now - lastEmit >= .milliseconds(100) {
                    let progress = totalSize > 0 ? Double(totalSent) / Double(totalSize) : 1.0
                    peer.state = .transferring(progress: min(progress, 1.0))
                    self.emitPeers()
                    lastEmit = now
                }
            }
            // Final emit to ensure 100% is reported.
            let progress = totalSize > 0 ? Double(totalSent) / Double(totalSize) : 1.0
            peer.state = .transferring(progress: min(progress, 1.0))
            self.emitPeers()
        }

        // Heartbeat task — sends keepalive every 30s on the control stream.
        let heartbeatTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { break }
                try? await sendRawFrame(
                    type: ScoutDropFrameHeader.typeHeartbeat, payload: Data(), on: controlStream
                )
            }
        }

        // Monitor task — reads control stream for per-file errors from receiver.
        var failedFileIndices: Set<Int> = []
        let monitorTask = Task {
            while !Task.isCancelled {
                guard let (header, metaData, _) = try? await self.receiveMessage(
                    on: controlStream, timeout: 3600
                ) else { break }
                if header.messageType == ScoutDropFrameHeader.typeFileError {
                    if let errorMeta = try? JSONDecoder().decode(
                        ScoutDropFileErrorMetadata.self, from: metaData
                    ) {
                        NSLog("[ScoutDropService] Receiver reported file %d error: %@",
                              errorMeta.fileIndex, errorMeta.errorMessage)
                        failedFileIndices.insert(errorMeta.fileIndex)
                    }
                }
            }
        }

        // Send files with bounded concurrency (up to maxConcurrentStreams).
        do {
            try await withThrowingTaskGroup(of: Void.self) { taskGroup in
                var nextIndex = 0
                var inFlight = 0

                while nextIndex < basePaths.count || inFlight > 0 {
                    while nextIndex < basePaths.count, inFlight < Self.maxConcurrentStreams {
                        let index = nextIndex
                        let (fileURL, _) = basePaths[index]
                        let resumeOffset = resumeOffsets[index] ?? 0

                        taskGroup.addTask {
                            try await self.sendFileOnStream(
                                fileURL: fileURL,
                                fileIndex: index,
                                resumeOffset: resumeOffset,
                                group: group,
                                progressCont: progressCont
                            )
                        }
                        nextIndex += 1
                        inFlight += 1
                    }

                    try await taskGroup.next()
                    inFlight -= 1
                }
            }
            heartbeatTask.cancel()
            monitorTask.cancel()
            progressCont.finish()
            await progressTask.value
        } catch {
            heartbeatTask.cancel()
            monitorTask.cancel()
            progressCont.finish()
            await progressTask.value
            throw error
        }

        if !failedFileIndices.isEmpty {
            NSLog("[ScoutDropService] Transfer completed with %d file error(s)", failedFileIndices.count)
        }

        // All files sent — send complete on control stream.
        let completeMeta = ScoutDropControlMetadata(transferID: transferID)
        try await sendControl(
            type: ScoutDropFrameHeader.typeComplete,
            metadata: completeMeta,
            on: controlStream
        )

        controlStream.cancel()
        removeGroup(group)
        peer.state = .connected
        emitPeers()
    }

    private func sendFileOnStream(
        fileURL: URL,
        fileIndex: Int,
        resumeOffset: Int64,
        group: NWConnectionGroup,
        progressCont: AsyncStream<Int64>.Continuation
    ) async throws {
        guard let stream = NWConnection(from: group) else {
            throw ScoutDropError.connectionFailed("Failed to open file stream")
        }

        try await startAndWaitForReady(stream)

        guard let fileHandle = FileHandle(forReadingAtPath: fileURL.path) else {
            stream.cancel()
            throw ScoutDropError.writeFailed("Cannot read \(fileURL.path)")
        }

        // Advisory shared lock — prevents writers, allows other readers.
        let lockResult = flock(fileHandle.fileDescriptor, LOCK_SH | LOCK_NB)
        if lockResult != 0 {
            NSLog("[ScoutDropService] Cannot lock file, proceeding without lock: %@", fileURL.path)
        }

        defer {
            if lockResult == 0 { flock(fileHandle.fileDescriptor, LOCK_UN) }
            try? fileHandle.close()
            stream.cancel()
        }

        // Incremental SHA-256 hash computed over the ENTIRE file (including resumed bytes).
        var hasher = SHA256()

        if resumeOffset > 0 {
            // Hash bytes from 0 to resumeOffset (the bytes we're skipping over the wire).
            fileHandle.seek(toFileOffset: 0)
            var remaining = resumeOffset
            while remaining > 0 {
                let readSize = min(remaining, Int64(Self.chunkSize))
                guard let data = try fileHandle.read(upToCount: Int(readSize)), !data.isEmpty else { break }
                hasher.update(data: data)
                remaining -= Int64(data.count)
            }
            // Now fileHandle is at resumeOffset, ready to send.
        }

        // First message: typeFileStart with 2-byte fileIndex + first chunk as payload.
        let firstChunk = try fileHandle.read(upToCount: Self.chunkSize) ?? Data()
        try await sendFileStart(fileIndex: fileIndex, payload: firstChunk, on: stream)
        hasher.update(data: firstChunk)
        progressCont.yield(Int64(firstChunk.count))

        // If first chunk was the only/last, send end marker with checksum.
        if firstChunk.isEmpty || firstChunk.count < Self.chunkSize {
            let checksum = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            try await sendFileEnd(checksum: checksum, on: stream)
            return
        }

        // Stream remaining chunks as raw binary (no JSON, no per-chunk metadata).
        while true {
            guard !Task.isCancelled else { throw CancellationError() }

            let chunkData = try fileHandle.read(upToCount: Self.chunkSize) ?? Data()
            hasher.update(data: chunkData)

            if chunkData.isEmpty || chunkData.count < Self.chunkSize {
                // Last chunk (or EOF) — send as typeFileEnd with checksum.
                let checksum = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                try await sendFileEnd(checksum: checksum, payload: chunkData, on: stream)
                progressCont.yield(Int64(chunkData.count))
                break
            }

            try await sendRawFrame(
                type: ScoutDropFrameHeader.typeFileData, payload: chunkData, on: stream
            )
            progressCont.yield(Int64(chunkData.count))
        }
    }

    // MARK: - Private: Receive Files (Per-File QUIC Streams)

    private func receiveFilesStreamed(
        controlConnection: NWConnection,
        offer: ScoutDropOffer,
        transferID: UUID,
        group: NWConnectionGroup
    ) async throws {
        // Prepare download directory.
        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let destDir = downloadsURL.appendingPathComponent(Self.downloadDirName, isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Create directories from the offer.
        for entry in offer.files where entry.isDirectory {
            guard let dirURL = validatedPath(relativePath: entry.relativePath, within: destDir) else {
                continue
            }
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        }

        // Create symlinks directly (no file stream needed).
        for entry in offer.files where entry.isSymlink {
            if let target = entry.symlinkTarget {
                guard let linkPath = validatedPath(relativePath: entry.relativePath, within: destDir) else {
                    continue
                }
                // Validate symlink target doesn't escape the dest dir.
                let resolvedTarget = linkPath.deletingLastPathComponent()
                    .appendingPathComponent(target).standardizedFileURL
                guard resolvedTarget.path.hasPrefix(destDir.standardizedFileURL.path + "/") else {
                    NSLog("[ScoutDropService] Rejected symlink escaping dest dir: %@ -> %@",
                          entry.relativePath, target)
                    continue
                }
                try? FileManager.default.removeItem(at: linkPath)
                try FileManager.default.createSymbolicLink(
                    atPath: linkPath.path, withDestinationPath: target
                )
            }
        }

        let fileEntries = offer.files.filter { !$0.isDirectory && !$0.isSymlink }

        // Check for existing partial files (resume support).
        var resumeOffsets: [Int: Int64] = [:]
        for (index, entry) in fileEntries.enumerated() {
            let incompletePath = destDir.appendingPathComponent(entry.relativePath + ".incomplete")
            if let attrs = try? FileManager.default.attributesOfItem(atPath: incompletePath.path),
               let existingSize = attrs[.size] as? Int64, existingSize > 0 {
                if existingSize > entry.size {
                    // File is larger than expected — delete and start fresh.
                    try? FileManager.default.removeItem(at: incompletePath)
                } else {
                    resumeOffsets[index] = existingSize
                }
            }
        }

        // Send accept with resume offsets.
        let acceptMeta = ScoutDropAcceptMetadata(transferID: transferID, resumeOffsets: resumeOffsets)
        try await sendControl(type: ScoutDropFrameHeader.typeAccept, metadata: acceptMeta, on: controlConnection)

        // Set up file stream routing for this group.
        let (fileStreamPipe, fileStreamCont) = AsyncStream.makeStream(of: NWConnection.self)
        let groupKey = ObjectIdentifier(group)
        fileStreamContinuations[groupKey] = fileStreamCont

        var transferComplete = false
        let expectedFiles = fileEntries.count

        defer {
            fileStreamContinuations.removeValue(forKey: groupKey)
            fileStreamCont.finish()
            if !transferComplete {
                NSLog("[ScoutDropService] Transfer incomplete, partial files preserved for resume")
            }
        }

        // No files to transfer — just wait for complete.
        if expectedFiles == 0 {
            let (header, _, _) = try await receiveMessage(on: controlConnection, timeout: 3600)
            guard header.messageType == ScoutDropFrameHeader.typeComplete else {
                throw ScoutDropError.invalidMessage
            }
            transferComplete = true
            controlConnection.cancel()
            return
        }

        // Receive files on per-file streams + wait for complete on control stream concurrently.
        let receivedFiles: [ReceivedFile] = try await withThrowingTaskGroup(
            of: [ReceivedFile].self
        ) { masterGroup in

            // Task 1: receive all file streams.
            masterGroup.addTask { [fileStreamPipe] in
                var results: [ReceivedFile] = []
                try await withThrowingTaskGroup(of: ReceivedFile?.self) { fileGroup in
                    var receivedStreams = 0
                    for await fileStream in fileStreamPipe {
                        let streamIndex = receivedStreams
                        receivedStreams += 1
                        fileGroup.addTask {
                            do {
                                return try await self.receiveFileOnStream(
                                    fileStream,
                                    fileEntries: fileEntries,
                                    destDir: destDir
                                )
                            } catch {
                                // Report per-file error to sender on the control stream.
                                NSLog("[ScoutDropService] File stream %d failed: %@",
                                      streamIndex, error.localizedDescription)
                                let errorMeta = ScoutDropFileErrorMetadata(
                                    transferID: transferID,
                                    fileIndex: streamIndex,
                                    errorMessage: error.localizedDescription
                                )
                                try? await self.sendControl(
                                    type: ScoutDropFrameHeader.typeFileError,
                                    metadata: errorMeta,
                                    on: controlConnection
                                )
                                return nil
                            }
                        }
                        if receivedStreams >= expectedFiles { break }
                    }
                    for try await result in fileGroup {
                        if let result { results.append(result) }
                    }
                }
                return results
            }

            // Task 2: wait for complete/error/heartbeat on control stream.
            masterGroup.addTask {
                while !Task.isCancelled {
                    let (header, metaData, _) = try await self.receiveMessage(
                        on: controlConnection, timeout: 3600
                    )
                    if header.messageType == ScoutDropFrameHeader.typeComplete {
                        return []
                    }
                    if header.messageType == ScoutDropFrameHeader.typeHeartbeat {
                        continue  // Keepalive — resets the receive timeout.
                    }
                    if header.messageType == ScoutDropFrameHeader.typeError {
                        let ctrl = try? JSONDecoder().decode(
                            ScoutDropControlMetadata.self, from: metaData
                        )
                        throw ScoutDropError.connectionFailed(ctrl?.errorMessage ?? "Unknown error")
                    }
                    // Skip unrecognized message types for forward compatibility.
                }
                throw CancellationError()
            }

            var allResults: [ReceivedFile] = []
            for try await partial in masterGroup {
                allResults.append(contentsOf: partial)
            }
            return allResults
        }

        // Rename .incomplete files to final names, validate checksums, restore permissions.
        for received in receivedFiles {
            let entry = fileEntries[received.fileIndex]
            let finalPath = destDir.appendingPathComponent(entry.relativePath)
            try? FileManager.default.removeItem(at: finalPath)
            try FileManager.default.moveItem(at: received.incompletePath, to: finalPath)

            // Restore POSIX permissions if available.
            if let perms = entry.posixPermissions {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: perms], ofItemAtPath: finalPath.path
                )
            }
        }

        transferComplete = true
        NSLog("[ScoutDropService] Transfer %@ complete", transferID.uuidString)
        controlConnection.cancel()
    }

    private func receiveFileOnStream(
        _ stream: NWConnection,
        fileEntries: [ScoutDropFileEntry],
        destDir: URL
    ) async throws -> ReceivedFile {
        try await startAndWaitForReady(stream)

        defer { stream.cancel() }

        // First message: typeFileStart with 2-byte fileIndex metadata + first chunk payload.
        let (header, metaData, payload) = try await receiveMessage(on: stream)
        guard header.messageType == ScoutDropFrameHeader.typeFileStart,
              metaData.count >= 2 else {
            throw ScoutDropError.invalidMessage
        }

        let fileIndex = Int(metaData.withUnsafeBytes { $0.load(as: UInt16.self) }.bigEndian)
        guard fileIndex >= 0, fileIndex < fileEntries.count else {
            throw ScoutDropError.invalidMessage
        }

        let entry = fileEntries[fileIndex]
        guard let validPath = validatedPath(relativePath: entry.relativePath, within: destDir) else {
            throw ScoutDropError.writeFailed("Path traversal rejected: \(entry.relativePath)")
        }
        let incompletePath = validPath.appendingPathExtension("incomplete")
        let parentDir = incompletePath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        // Open or create the .incomplete file (preserving existing content for resume).
        if !FileManager.default.fileExists(atPath: incompletePath.path) {
            FileManager.default.createFile(atPath: incompletePath.path, contents: nil)
        }

        guard let fileHandle = FileHandle(forUpdatingAtPath: incompletePath.path) else {
            throw ScoutDropError.writeFailed("Cannot open \(incompletePath.path)")
        }
        defer { try? fileHandle.close() }

        // Incremental SHA-256 hash covering the ENTIRE file including pre-existing bytes.
        var hasher = SHA256()

        // Hash existing bytes in the .incomplete file (for resume integrity).
        fileHandle.seek(toFileOffset: 0)
        while true {
            guard let existingData = try fileHandle.read(upToCount: Self.chunkSize),
                  !existingData.isEmpty else { break }
            hasher.update(data: existingData)
        }
        // Now at end of file, ready to append new data.

        // Write initial chunk payload.
        if !payload.isEmpty {
            try fileHandle.write(contentsOf: payload)
            hasher.update(data: payload)
        }

        // Receive remaining data until typeFileEnd.
        var senderChecksum: String?
        while true {
            let (h, md, pl) = try await receiveMessage(on: stream)
            if !pl.isEmpty {
                try fileHandle.write(contentsOf: pl)
                hasher.update(data: pl)
            }
            if h.messageType == ScoutDropFrameHeader.typeFileEnd {
                // Extract sender's checksum from metadata (UTF-8 hex string).
                if !md.isEmpty { senderChecksum = String(data: md, encoding: .utf8) }
                break
            }
            guard h.messageType == ScoutDropFrameHeader.typeFileData else {
                throw ScoutDropError.invalidMessage
            }
        }

        let receiverChecksum = hasher.finalize().map { String(format: "%02x", $0) }.joined()

        // Validate checksum against sender's hash of the same bytes.
        if let expected = senderChecksum, expected != receiverChecksum {
            throw ScoutDropError.checksumMismatch(entry.relativePath)
        }

        return ReceivedFile(fileIndex: fileIndex, incompletePath: incompletePath)
    }

    // MARK: - Private: Browse Results

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        var newPeers: [NWEndpoint: ScoutDropPeer] = [:]

        for result in results {
            let name = Self.extractServiceName(from: result)
            let deviceID = Self.extractDeviceID(from: result)

            // Skip our own advertised service — no point transferring to ourselves.
            if let deviceID, !advertisedDeviceID.isEmpty, deviceID == advertisedDeviceID {
                continue
            }

            let peer = currentPeers[result.endpoint]
                ?? ScoutDropPeer(name: name, endpoint: result.endpoint, deviceID: deviceID)
            peer.name = name
            peer.deviceID = deviceID
            newPeers[result.endpoint] = peer
        }

        currentPeers = newPeers
        emitPeers()
    }

    private static func extractServiceName(from result: NWBrowser.Result) -> String {
        // Primary: Bonjour service instance name (set from nickname).
        if case let .service(name, _, _, _) = result.endpoint {
            return name
        }
        // Fallback: TXT record.
        if case let .bonjour(txtRecord) = result.metadata,
           let nickname = txtRecord[txtKeyNickname] {
            return nickname
        }
        return "Unknown Mac"
    }

    private static func extractDeviceID(from result: NWBrowser.Result) -> String? {
        if case let .bonjour(txtRecord) = result.metadata {
            return txtRecord[txtKeyDeviceID]
        }
        return nil
    }

    private func emitPeers() {
        peersContinuation.yield(Array(currentPeers.values))
    }

    // MARK: - Private: Networking Helpers

    private func connect(
        to endpoint: NWEndpoint,
        peerDeviceID: String?
    ) async throws -> (group: NWConnectionGroup, control: NWConnection, peerKeyHash: String?) {
        let quicOptions = NWProtocolQUIC.Options(alpn: Self.alpn)

        // Storage for the peer's public key hash captured by the TLS verify block.
        // Safe because the verify block runs on .main and completes before the
        // continuation resumes, so there is no concurrent access.
        let capturedHash = UnsafeMutablePointer<String?>.allocate(capacity: 1)
        capturedHash.initialize(to: nil)
        defer {
            capturedHash.deinitialize(count: 1)
            capturedHash.deallocate()
        }

        if let identity = localIdentity {
            let expectedHash = peerDeviceID.flatMap {
                PersistenceService.shared.loadScoutDropPeerKeyHash(deviceID: $0)
            }
            Self.configureTLSForSender(
                quicOptions, identity: identity,
                expectedPeerKeyHash: expectedHash, capturedPeerHash: capturedHash
            )
        } else {
            Self.configureTLSAcceptAll(quicOptions)
        }

        let params = NWParameters(quic: quicOptions)
        params.includePeerToPeer = true

        // Add the binary framer to the outbound connection's protocol stack.
        let framerOptions = NWProtocolFramer.Options(definition: ScoutDropFramer.definition)
        params.defaultProtocolStack.applicationProtocols.insert(framerOptions, at: 0)

        let descriptor = NWMultiplexGroup(to: endpoint)
        let group = NWConnectionGroup(with: descriptor, using: params)

        // Wait for the QUIC tunnel to be ready.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            group.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    group.stateUpdateHandler = nil
                    cont.resume()
                case let .failed(error):
                    group.stateUpdateHandler = nil
                    cont.resume(throwing: ScoutDropError.connectionFailed(error.localizedDescription))
                case .cancelled:
                    group.stateUpdateHandler = nil
                    cont.resume(throwing: ScoutDropError.connectionClosed)
                default:
                    break
                }
            }
            group.start(queue: .main)
        }

        // Retain the group so the QUIC tunnel stays alive.
        activeGroups.append(group)

        // Open the first QUIC stream as the control stream.
        guard let controlStream = NWConnection(from: group) else {
            throw ScoutDropError.connectionFailed("Failed to open QUIC control stream from group")
        }

        try await startAndWaitForReady(controlStream)

        return (group, controlStream, capturedHash.pointee)
    }

    private func startAndWaitForReady(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    cont.resume()
                case let .failed(error):
                    connection.stateUpdateHandler = nil
                    cont.resume(throwing: ScoutDropError.connectionFailed(error.localizedDescription))
                case .cancelled:
                    connection.stateUpdateHandler = nil
                    cont.resume(throwing: ScoutDropError.connectionClosed)
                default:
                    break
                }
            }
            connection.start(queue: .main)
        }
    }

    // MARK: - Private: Frame Sending

    /// Core frame sender — all other send methods delegate here.
    private func sendFrame(
        type: UInt8,
        metadataLength: UInt32,
        payloadLength: UInt32,
        body: Data?,
        on connection: NWConnection
    ) async throws {
        let message = NWProtocolFramer.Message(definition: ScoutDropFramer.definition)
        var header = ScoutDropFrameHeader()
        header.messageType = type
        header.metadataLength = metadataLength
        header.payloadLength = payloadLength
        message.scoutDropHeader = header

        let context = NWConnection.ContentContext(
            identifier: Self.contentID,
            metadata: [message]
        )

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(
                content: body,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error { cont.resume(throwing: error) }
                    else { cont.resume() }
                }
            )
        }
    }

    /// Send a JSON-encoded control message (offer, accept, decline, complete, error).
    private func sendControl(
        type: UInt8,
        metadata: some Encodable,
        on connection: NWConnection
    ) async throws {
        let json = try JSONEncoder().encode(metadata)
        try await sendFrame(
            type: type, metadataLength: UInt32(json.count), payloadLength: 0,
            body: json, on: connection
        )
    }

    /// Fire-and-forget control message for non-async contexts (cancel, decline).
    private nonisolated func sendControlFireAndForget(
        type: UInt8,
        metadata: some Encodable & Sendable,
        on connection: NWConnection
    ) {
        guard let json = try? JSONEncoder().encode(metadata) else { return }
        Task { try? await self.sendFrame(
            type: type, metadataLength: UInt32(json.count), payloadLength: 0,
            body: json, on: connection
        ) }
    }

    /// Send typeFileStart: 2-byte fileIndex (UInt16 BE) as metadata + chunk payload.
    private func sendFileStart(
        fileIndex: Int,
        payload: Data,
        on connection: NWConnection
    ) async throws {
        var body = Data(count: 2)
        var indexBE = UInt16(fileIndex).bigEndian
        withUnsafeBytes(of: &indexBE) { body.replaceSubrange(0..<2, with: $0) }
        body.append(payload)

        try await sendFrame(
            type: ScoutDropFrameHeader.typeFileStart,
            metadataLength: 2, payloadLength: UInt32(payload.count),
            body: body, on: connection
        )
    }

    /// Send typeFileEnd: SHA-256 checksum as metadata + optional final payload.
    private func sendFileEnd(
        checksum: String,
        payload: Data = Data(),
        on connection: NWConnection
    ) async throws {
        let checksumData = Data(checksum.utf8)
        var body = checksumData
        body.append(payload)

        try await sendFrame(
            type: ScoutDropFrameHeader.typeFileEnd,
            metadataLength: UInt32(checksumData.count),
            payloadLength: UInt32(payload.count),
            body: body, on: connection
        )
    }

    /// Send a raw frame with no metadata — just the 9-byte header + payload.
    private func sendRawFrame(
        type: UInt8,
        payload: Data,
        on connection: NWConnection
    ) async throws {
        try await sendFrame(
            type: type, metadataLength: 0, payloadLength: UInt32(payload.count),
            body: payload.isEmpty ? nil : payload, on: connection
        )
    }

    private func receiveMessage(
        on connection: NWConnection,
        timeout: TimeInterval = receiveTimeout
    ) async throws -> (header: ScoutDropFrameHeader, metadata: Data, payload: Data) {
        try await withThrowingTaskGroup(
            of: (ScoutDropFrameHeader, Data, Data).self
        ) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { cont in
                    connection.receiveMessage { content, context, _, error in
                        if let error {
                            cont.resume(throwing: error)
                            return
                        }
                        guard let content,
                              let message = context?.protocolMetadata(
                                  definition: ScoutDropFramer.definition
                              ) as? NWProtocolFramer.Message,
                              let header = message.scoutDropHeader
                        else {
                            cont.resume(throwing: ScoutDropError.invalidMessage)
                            return
                        }

                        let metaLen = Int(header.metadataLength)
                        // Slice without copying — callers that need owned Data (e.g. JSON decode)
                        // will copy on access, but large payloads avoid a redundant allocation.
                        let metadata = content[content.startIndex..<content.index(content.startIndex, offsetBy: metaLen)]
                        let payload = content[content.index(content.startIndex, offsetBy: metaLen)...]
                        cont.resume(returning: (header, metadata, Data(payload)))
                    }
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw ScoutDropError.transferTimeout
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - Private: File Entries

    private func buildFileEntries(urls: [URL]) -> (entries: [ScoutDropFileEntry], basePaths: [(URL, String)]) {
        var entries: [ScoutDropFileEntry] = []
        var basePaths: [(URL, String)] = []

        for url in urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)

            if isDir.boolValue {
                let dirName = url.lastPathComponent
                entries.append(ScoutDropFileEntry(relativePath: dirName, size: 0, isDirectory: true))

                if let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
                ) {
                    for case let childURL as URL in enumerator {
                        let relativePath = dirName + "/" + String(childURL.path.dropFirst(url.path.count + 1))
                        let entry = buildSingleEntry(url: childURL, relativePath: relativePath)
                        entries.append(entry)
                        if !entry.isDirectory && !entry.isSymlink {
                            basePaths.append((childURL, relativePath))
                        }
                    }
                }
            } else {
                let entry = buildSingleEntry(url: url, relativePath: url.lastPathComponent)
                entries.append(entry)
                if !entry.isSymlink {
                    basePaths.append((url, url.lastPathComponent))
                }
            }
        }

        return (entries, basePaths)
    }

    private func buildSingleEntry(url: URL, relativePath: String) -> ScoutDropFileEntry {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileType = attrs?[.type] as? FileAttributeType
        let posixPerms = attrs?[.posixPermissions] as? Int

        // Detect symlinks.
        if fileType == .typeSymbolicLink {
            let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            return ScoutDropFileEntry(
                relativePath: relativePath, size: 0, isDirectory: false,
                posixPermissions: posixPerms, isSymlink: true, symlinkTarget: target
            )
        }

        let isDir = fileType == .typeDirectory
        let size = Int64((attrs?[.size] as? UInt64) ?? 0)

        return ScoutDropFileEntry(
            relativePath: relativePath, size: size, isDirectory: isDir,
            posixPermissions: posixPerms
        )
    }

    // MARK: - Private: TLS Configuration (TOFU Certificate Pinning)

    /// Holds the most recently extracted peer public key hash from the listener's
    /// TLS verify block. Both the verify block (dispatched to `.main`) and the
    /// listener's `newConnectionGroupHandler` (also on `.main`) execute serially,
    /// so this single-slot handoff is safe. `handleIncomingGroup` claims the hash
    /// and stores it in the actor-isolated `incomingPeerKeyHashes` dictionary,
    /// keyed by `ObjectIdentifier(group)`.
    private nonisolated(unsafe) static var lastExtractedPeerHash: String?

    /// Maps `ObjectIdentifier(NWConnectionGroup)` to the peer's public key hash
    /// extracted during TLS handshake. Populated in `handleIncomingGroup`, consumed
    /// and removed in `readInitialOffer`.
    private var incomingPeerKeyHashes: [ObjectIdentifier: String] = [:]

    /// Configure TLS for the listener (receiver). Accepts all peers at the TLS level
    /// and caches the peer's public key hash for application-level TOFU verification
    /// after the offer message arrives with the sender's deviceID.
    private static func configureTLSForListener(
        _ quicOptions: NWProtocolQUIC.Options,
        identity: SecIdentity
    ) {
        if let secIdentity = sec_identity_create(identity) {
            sec_protocol_options_set_local_identity(
                quicOptions.securityProtocolOptions, secIdentity
            )
        } else {
            NSLog("[ScoutDropService] sec_identity_create returned nil; proceeding without local identity")
        }

        sec_protocol_options_set_verify_block(
            quicOptions.securityProtocolOptions,
            { _, trust, completion in
                ScoutDropService.lastExtractedPeerHash = ScoutDropIdentity.publicKeyHash(from: trust)
                completion(true)
            },
            .main
        )
    }

    /// Configure TLS for the sender. Verifies the receiver's public key hash against
    /// the stored TOFU hash for the target deviceID. On first use (no stored hash),
    /// accepts and captures the hash for later storage.
    private static func configureTLSForSender(
        _ quicOptions: NWProtocolQUIC.Options,
        identity: SecIdentity,
        expectedPeerKeyHash: String?,
        capturedPeerHash: UnsafeMutablePointer<String?>
    ) {
        guard let secIdentity = sec_identity_create(identity) else {
            NSLog("[ScoutDropService] sec_identity_create returned nil; proceeding without local identity")
            return
        }
        sec_protocol_options_set_local_identity(
            quicOptions.securityProtocolOptions, secIdentity
        )

        sec_protocol_options_set_verify_block(
            quicOptions.securityProtocolOptions,
            { _, trust, completion in
                let peerHash = ScoutDropIdentity.publicKeyHash(from: trust)
                capturedPeerHash.pointee = peerHash

                guard let expectedPeerKeyHash else {
                    // First use — accept (TOFU).
                    completion(true)
                    return
                }
                completion(peerHash == expectedPeerKeyHash)
            },
            .main
        )
    }

    /// Fallback TLS configuration when no local identity is available.
    /// Accepts all peers without certificate pinning.
    private static func configureTLSAcceptAll(_ quicOptions: NWProtocolQUIC.Options) {
        sec_protocol_options_set_verify_block(
            quicOptions.securityProtocolOptions,
            { _, _, completion in completion(true) },
            .main
        )
    }

    // MARK: - Private: Cleanup

    private func removeActiveTransfer(_ transferID: UUID) {
        activeTransfers.removeValue(forKey: transferID)
    }
}
