import AppKit
import Foundation
import Observation
import UserNotifications

// MARK: - TransferError

enum TransferError: LocalizedError {
    case operationNotFound(UUID)
    case operationAlreadyRunning(UUID)
    case operationCancelled(UUID)
    case transferFailed(String)
    case destinationNotFound(URL)

    var errorDescription: String? {
        switch self {
        case let .operationNotFound(id):
            return "Transfer operation not found: \(id)"
        case let .operationAlreadyRunning(id):
            return "Transfer operation already running: \(id)"
        case let .operationCancelled(id):
            return "Transfer operation was cancelled: \(id)"
        case let .transferFailed(reason):
            return "Transfer failed: \(reason)"
        case let .destinationNotFound(url):
            return "Destination not found: \(url.path)"
        }
    }
}

// MARK: - TransferQueueController

/// Manages file transfer queue, running transfers sequentially with progress tracking.
@Observable
@MainActor
final class TransferQueueController {
    // MARK: - Properties

    private(set) var operations: [TransferOperation] = []
    private(set) var activeTransfer: TransferOperation?

    /// Callback for resolving filename conflicts during transfers.
    var conflictResolver: ((URL, URL) async -> ConflictResolution)?

    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    /// These flags are safe from data races because the entire class is `@MainActor`-isolated.
    /// All async methods (`executeTransfer`, `transferFiles`, `resolveConflict`) inherit main-actor
    /// isolation, so reads and writes to these flags always occur on the main thread.
    private var skipAllConflicts = false
    private var replaceAllConflicts = false

    // MARK: - Enqueue

    /// Enqueues a new transfer operation and starts processing the queue.
    @discardableResult
    func enqueue(
        sources: [URL],
        destination: URL,
        type: TransferType
    ) -> TransferOperation {
        let operation = TransferOperation(
            sources: sources,
            destination: destination,
            type: type
        )

        operations.append(operation)
        processQueue()

        return operation
    }

    // MARK: - Pause / Resume / Cancel

    /// Pauses an active transfer operation.
    func pause(operation: TransferOperation) {
        guard operation.status == .inProgress else { return }
        operation.status = .paused
        activeTasks[operation.id]?.cancel()
        activeTasks[operation.id] = nil
    }

    /// Resumes a paused transfer operation.
    func resume(operation: TransferOperation) {
        guard operation.status == .paused else { return }
        operation.status = .pending
        processQueue()
    }

    /// Cancels a transfer operation.
    func cancel(operation: TransferOperation) {
        activeTasks[operation.id]?.cancel()
        activeTasks[operation.id] = nil
        operation.status = .cancelled

        if activeTransfer?.id == operation.id {
            activeTransfer = nil
            processQueue()
        }
    }

    /// Cancels all pending and active transfer operations.
    func cancelAll() {
        for (id, task) in activeTasks {
            task.cancel()
            activeTasks[id] = nil
        }

        for operation in operations
            where operation.status != .completed && operation.status != .failed
        {
            operation.status = .cancelled
        }

        activeTransfer = nil
    }

    /// Removes completed, failed, and cancelled operations from the list.
    func clearCompleted() {
        operations.removeAll { op in
            op.status == .completed || op.status == .failed || op.status == .cancelled
        }
    }

    // MARK: - Private Queue Processing

    private func processQueue() {
        // Only run one transfer at a time.
        guard activeTransfer == nil else { return }

        guard let next = operations.first(where: { $0.status == .pending }) else {
            return
        }

        activeTransfer = next
        next.status = .inProgress

        let task = Task { [weak self] in
            guard let self else { return }
            await self.executeTransfer(next)
        }
        activeTasks[next.id] = task
    }

    private func executeTransfer(_ operation: TransferOperation) async {
        let fileManager = FileManager.default

        // Reset conflict resolution flags for each operation.
        skipAllConflicts = false
        replaceAllConflicts = false

        // Calculate total bytes.
        var totalBytes: Int64 = 0
        for source in operation.sources {
            totalBytes += Self.calculateSize(at: source, fileManager: fileManager)
        }
        operation.totalBytes = totalBytes
        operation.progress.totalUnitCount = totalBytes

        do {
            switch operation.type {
            case .copy:
                try await transferFiles(
                    from: operation.sources,
                    to: operation.destination,
                    operation: operation,
                    move: false,
                    fileManager: fileManager
                )

            case .move:
                try await transferFiles(
                    from: operation.sources,
                    to: operation.destination,
                    operation: operation,
                    move: true,
                    fileManager: fileManager
                )

            case .trash:
                for source in operation.sources {
                    guard !Task.isCancelled else {
                        operation.status = .cancelled
                        break
                    }
                    operation.currentFile = source.lastPathComponent
                    let size = Self.calculateSize(at: source, fileManager: fileManager)
                    try fileManager.trashItem(at: source, resultingItemURL: nil)
                    operation.bytesTransferred += size
                    operation.progress.completedUnitCount = operation.bytesTransferred
                }
            }

            if !Task.isCancelled, operation.status == .inProgress {
                operation.status = .completed
                sendCompletionNotification(for: operation)
            }
        } catch {
            if Task.isCancelled {
                operation.status = .cancelled
            } else {
                operation.status = .failed
                operation.error = error.localizedDescription
            }
        }

        activeTasks[operation.id] = nil
        activeTransfer = nil
        processQueue()
    }

    private func transferFiles(
        from sources: [URL],
        to destination: URL,
        operation: TransferOperation,
        move: Bool,
        fileManager: FileManager
    ) async throws {
        for source in sources {
            guard !Task.isCancelled else { return }

            let destURL = destination.appendingPathComponent(source.lastPathComponent)
            operation.currentFile = source.lastPathComponent

            // Handle conflicts.
            if fileManager.fileExists(atPath: destURL.path) {
                let resolution = try await resolveConflict(source: source, destination: destURL)

                switch resolution {
                case .skip:
                    continue
                case .skipAll:
                    skipAllConflicts = true
                    continue
                case .replace, .replaceAll:
                    if resolution == .replaceAll {
                        replaceAllConflicts = true
                    }
                    try fileManager.removeItem(at: destURL)
                case .keepBoth:
                    let uniqueURL = Self.uniqueDestination(for: destURL, fileManager: fileManager)
                    if move {
                        try fileManager.moveItem(at: source, to: uniqueURL)
                    } else {
                        try fileManager.copyItem(at: source, to: uniqueURL)
                    }
                    let size = Self.calculateSize(at: source, fileManager: fileManager)
                    operation.bytesTransferred += size
                    operation.progress.completedUnitCount = operation.bytesTransferred
                    continue
                case .rename:
                    let uniqueURL = Self.uniqueDestination(for: destURL, fileManager: fileManager)
                    if move {
                        try fileManager.moveItem(at: source, to: uniqueURL)
                    } else {
                        try fileManager.copyItem(at: source, to: uniqueURL)
                    }
                    let size = Self.calculateSize(at: source, fileManager: fileManager)
                    operation.bytesTransferred += size
                    operation.progress.completedUnitCount = operation.bytesTransferred
                    continue
                case .cancel:
                    operation.status = .cancelled
                    return
                }
            }

            if move {
                try fileManager.moveItem(at: source, to: destURL)
            } else {
                try fileManager.copyItem(at: source, to: destURL)
            }

            let size = Self.calculateSize(at: source, fileManager: fileManager)
            operation.bytesTransferred += size
            operation.progress.completedUnitCount = operation.bytesTransferred
        }
    }

    private func resolveConflict(source: URL, destination: URL) async throws -> ConflictResolution {
        if skipAllConflicts {
            return .skip
        }
        if replaceAllConflicts {
            return .replace
        }

        if let resolver = conflictResolver {
            return await resolver(source, destination)
        }

        // Default: keep both.
        return .keepBoth
    }

    /// Generates a unique destination URL by appending a number suffix.
    private static func uniqueDestination(for url: URL, fileManager: FileManager) -> URL {
        let directory = url.deletingLastPathComponent()
        let baseName = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension

        var counter = 2
        var candidate: URL

        repeat {
            let newName = ext.isEmpty ? "\(baseName) \(counter)" : "\(baseName) \(counter).\(ext)"
            candidate = directory.appendingPathComponent(newName)
            counter += 1
        } while fileManager.fileExists(atPath: candidate.path)

        return candidate
    }

    /// Calculates the total size of a file or directory tree.
    private static func calculateSize(at url: URL, fileManager: FileManager) -> Int64 {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return 0
        }

        if !isDirectory.boolValue {
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            return (attributes?[.size] as? Int64) ?? 0
        }

        // For directories, enumerate and sum.
        var totalSize: Int64 = 0
        if let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .totalFileSizeKey],
            options: []
        ) {
            for case let fileURL as URL in enumerator {
                let values = try? fileURL.resourceValues(forKeys: [.totalFileSizeKey, .fileSizeKey])
                totalSize += Int64(values?.totalFileSize ?? values?.fileSize ?? 0)
            }
        }

        return totalSize
    }

    /// Sends a user notification when a transfer completes.
    private func sendCompletionNotification(for operation: TransferOperation) {
        let content = UNMutableNotificationContent()
        content.title = "Transfer Complete"

        let count = operation.sources.count
        let typeLabel: String
        switch operation.type {
        case .copy:
            typeLabel = "copied"
        case .move:
            typeLabel = "moved"
        case .trash:
            typeLabel = "trashed"
        }

        content.body = "\(count) item\(count == 1 ? "" : "s") \(typeLabel) successfully"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: operation.id.uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("[TransferQueueController] Notification error: %@", error.localizedDescription)
            }
        }
    }
}
