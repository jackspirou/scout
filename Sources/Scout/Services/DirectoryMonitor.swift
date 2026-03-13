import Foundation

// MARK: - DirectoryChangeEvent

/// Events emitted when file system changes are detected in the monitored directory.
enum DirectoryChangeEvent {
    case itemsAdded([URL])
    case itemsRemoved([URL])
    case itemsModified([URL])
    case rootChanged
}

// MARK: - DirectoryMonitorDelegate

protocol DirectoryMonitorDelegate: AnyObject {
    func directoryMonitor(_ monitor: DirectoryMonitor, didObserveChanges events: [DirectoryChangeEvent])
}

// MARK: - FSEvents Callback

/// Top-level C-convention callback for FSEvents. Bridges back to the DirectoryMonitor instance
/// via the `clientCallBackInfo` context pointer.
private func fsEventsCallback(
    _ streamRef: ConstFSEventStreamRef,
    _ clientCallBackInfo: UnsafeMutableRawPointer?,
    _ numEvents: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = clientCallBackInfo else { return }
    let monitor = Unmanaged<DirectoryMonitor>.fromOpaque(info).takeUnretainedValue()

    guard let pathsArray = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }

    monitor.handleEvents(paths: pathsArray, flags: eventFlags, count: numEvents)
}

// MARK: - DirectoryMonitor

final class DirectoryMonitor {
    // MARK: - Properties

    weak var delegate: DirectoryMonitorDelegate?

    private var streamRef: FSEventStreamRef?
    private var watchedURL: URL?
    private var knownPaths: Set<String> = []

    /// Lock protecting mutable state (`knownPaths`, `watchedURL`) that may be
    /// accessed from the FSEvents dispatch queue callback.
    private let lock = NSLock()

    // MARK: - Public API

    /// Starts monitoring the given directory for file system changes.
    ///
    /// - Parameters:
    ///   - url: The directory URL to monitor.
    ///   - knownPaths: The set of absolute path strings for currently known items in the directory.
    func startMonitoring(url: URL, knownPaths: Set<String>) {
        stopMonitoring()

        lock.lock()
        watchedURL = url
        self.knownPaths = knownPaths
        lock.unlock()

        let pathToWatch = url.path as CFString
        let pathsToWatch = [pathToWatch] as CFArray

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags: FSEventStreamCreateFlags =
            UInt32(kFSEventStreamCreateFlagFileEvents) |
            UInt32(kFSEventStreamCreateFlagUseCFTypes) |
            UInt32(kFSEventStreamCreateFlagNoDefer)

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            fsEventsCallback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            flags
        ) else { return }

        streamRef = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    /// Stops monitoring the current directory and releases the FSEvents stream.
    func stopMonitoring() {
        guard let stream = streamRef else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        streamRef = nil

        lock.lock()
        watchedURL = nil
        lock.unlock()
    }

    deinit {
        stopMonitoring()
    }

    // MARK: - Event Processing

    /// Called from the C callback to process a batch of FSEvents.
    fileprivate func handleEvents(paths: [String], flags: UnsafePointer<FSEventStreamEventFlags>, count: Int) {
        lock.lock()
        guard let watchedURL else {
            lock.unlock()
            return
        }
        let watchedPath = watchedURL.path
        // Snapshot knownPaths under the lock for use during event processing.
        var currentKnownPaths = knownPaths
        lock.unlock()

        var addedURLs: [URL] = []
        var removedURLs: [URL] = []
        var modifiedURLs: [URL] = []
        var rootDidChange = false

        for i in 0 ..< count {
            let flag = flags[i]
            let path = paths[i]

            // Check for root-level changes (watched directory itself).
            if flag & UInt32(kFSEventStreamEventFlagRootChanged) != 0 ||
                flag & UInt32(kFSEventStreamEventFlagUnmount) != 0
            {
                rootDidChange = true
                continue
            }

            // Filter out .DS_Store files.
            let filename = (path as NSString).lastPathComponent
            if filename == ".DS_Store" { continue }

            // Only process direct children of the watched directory.
            let parentPath = (path as NSString).deletingLastPathComponent
            guard parentPath == watchedPath else { continue }

            let isCreated = flag & UInt32(kFSEventStreamEventFlagItemCreated) != 0
            let isRemoved = flag & UInt32(kFSEventStreamEventFlagItemRemoved) != 0
            let isRenamed = flag & UInt32(kFSEventStreamEventFlagItemRenamed) != 0
            let isModified = flag & UInt32(kFSEventStreamEventFlagItemModified) != 0
            let isMetaMod = flag & UInt32(kFSEventStreamEventFlagItemInodeMetaMod) != 0

            let fileExists = FileManager.default.fileExists(atPath: path)
            let wasKnown = currentKnownPaths.contains(path)

            if isRenamed {
                // Renames produce a pair: one event for the old path (gone) and one for the new path (exists).
                if fileExists, !wasKnown {
                    addedURLs.append(URL(fileURLWithPath: path))
                } else if !fileExists, wasKnown {
                    removedURLs.append(URL(fileURLWithPath: path))
                }
            } else if isCreated, fileExists, !wasKnown {
                addedURLs.append(URL(fileURLWithPath: path))
            } else if isRemoved, !fileExists, wasKnown {
                removedURLs.append(URL(fileURLWithPath: path))
            } else if isModified || isMetaMod, fileExists, wasKnown {
                modifiedURLs.append(URL(fileURLWithPath: path))
            }
        }

        // Update known paths to reflect the new state.
        for url in addedURLs {
            currentKnownPaths.insert(url.path)
        }
        for url in removedURLs {
            currentKnownPaths.remove(url.path)
        }

        lock.lock()
        knownPaths = currentKnownPaths
        lock.unlock()

        // Build the list of change events.
        var events: [DirectoryChangeEvent] = []
        if rootDidChange { events.append(.rootChanged) }
        if !removedURLs.isEmpty { events.append(.itemsRemoved(removedURLs)) }
        if !addedURLs.isEmpty { events.append(.itemsAdded(addedURLs)) }
        if !modifiedURLs.isEmpty { events.append(.itemsModified(modifiedURLs)) }

        guard !events.isEmpty else { return }
        delegate?.directoryMonitor(self, didObserveChanges: events)
    }
}
