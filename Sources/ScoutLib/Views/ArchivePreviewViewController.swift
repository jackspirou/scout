import AppKit

// MARK: - ArchiveEntry

/// Represents a node in the archive file tree.
private class ArchiveEntry {
    let name: String
    let fullPath: String
    let isDirectory: Bool
    var size: Int64 = 0
    var children: [ArchiveEntry] = []

    init(name: String, fullPath: String, isDirectory: Bool) {
        self.name = name
        self.fullPath = fullPath
        self.isDirectory = isDirectory
    }
}

// MARK: - ArchivePreviewViewController

/// Displays archive file metadata and a file listing tree for archive files.
/// Supports ZIP, TAR, DMG, PKG, DEB, and other common archive formats.
final class ArchivePreviewViewController: NSViewController, PreviewChild {
    // MARK: - Properties

    private let headerView = PreviewHeaderView()
    private let mediaInfoView = MediaInfoView()
    private var outlineView: NSOutlineView!
    private var scrollView: NSScrollView!
    private var loadingSpinner: NSProgressIndicator!
    private var errorLabel: NSTextField!

    private var rootEntries: [ArchiveEntry] = []
    private var currentItem: FileItem?
    private var loadGeneration: Int = 0
    private var appearanceObservation: NSKeyValueObservation?

    // MARK: - Column Identifiers

    private static let nameColumnID = NSUserInterfaceItemIdentifier("name")
    private static let sizeColumnID = NSUserInterfaceItemIdentifier("size")

    // MARK: - Constants

    private static let zipFamilyExtensions: Set<String> = [
        "zip", "cbz", "ipa", "apk", "jar", "war", "ear",
    ]

    private static let tarFamilyExtensions: Set<String> = [
        "tar", "tgz", "tbz", "tbz2", "txz", "tlz",
    ]

    private static let singleCompressionExtensions: Set<String> = [
        "gz", "bz2", "xz", "lz", "lzma", "zst", "lz4", "br",
    ]

    private static let metadataOnlyExtensions: Set<String> = [
        "dmg", "iso", "rpm", "cab", "cpgz",
    ]

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter
    }()

    private static let backgroundQueue = DispatchQueue(
        label: "com.scout.archivePreview",
        qos: .userInitiated
    )

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()

        configureOutlineView()
        configureLoadingSpinner()
        configureErrorLabel()

        mediaInfoView.isHidden = true

        view.addSubview(headerView)
        view.addSubview(mediaInfoView)

        layoutSubviews()

        appearanceObservation = view.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            self?.headerView.updateAppearance()
            self?.mediaInfoView.updateAppearance()
        }
    }

    // MARK: - Configuration

    private func configureOutlineView() {
        outlineView = NSOutlineView()
        outlineView.headerView = nil
        outlineView.rowHeight = 22
        outlineView.indentationPerLevel = 16
        outlineView.autoresizesOutlineColumn = true
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.style = .plain
        outlineView.floatsGroupRows = false
        outlineView.dataSource = self
        outlineView.delegate = self

        let nameColumn = NSTableColumn(identifier: Self.nameColumnID)
        nameColumn.title = "Name"
        nameColumn.minWidth = 120
        nameColumn.resizingMask = .autoresizingMask
        outlineView.addTableColumn(nameColumn)
        outlineView.outlineTableColumn = nameColumn

        let sizeColumn = NSTableColumn(identifier: Self.sizeColumnID)
        sizeColumn.title = "Size"
        sizeColumn.width = 70
        sizeColumn.minWidth = 50
        sizeColumn.maxWidth = 90
        sizeColumn.resizingMask = []
        outlineView.addTableColumn(sizeColumn)

        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.documentView = outlineView

        view.addSubview(scrollView)
    }

    private func configureLoadingSpinner() {
        loadingSpinner = NSProgressIndicator()
        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false
        loadingSpinner.style = .spinning
        loadingSpinner.controlSize = .regular
        loadingSpinner.isIndeterminate = true
        loadingSpinner.isDisplayedWhenStopped = false
        view.addSubview(loadingSpinner)
    }

    private func configureErrorLabel() {
        errorLabel = NSTextField(labelWithString: "")
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.font = NSFont.systemFont(ofSize: 13)
        errorLabel.textColor = .secondaryLabelColor
        errorLabel.alignment = .center
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.maximumNumberOfLines = 0
        errorLabel.isHidden = true
        view.addSubview(errorLabel)
    }

    private func layoutSubviews() {
        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: view.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            mediaInfoView.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 1),
            mediaInfoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mediaInfoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: mediaInfoView.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            loadingSpinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingSpinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            errorLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            errorLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            errorLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
        ])
    }

    // MARK: - Public API (PreviewChild)

    func displayItem(_ item: FileItem) {
        currentItem = item
        loadGeneration += 1
        let generation = loadGeneration

        headerView.update(with: item)
        mediaInfoView.isHidden = true
        errorLabel.isHidden = true
        rootEntries = []
        outlineView.reloadData()

        loadingSpinner.startAnimation(nil)

        let url = item.url
        let ext = url.pathExtension.lowercased()
        let fileSize = item.size ?? 0
        let kind = item.kind

        Self.backgroundQueue.async { [weak self] in
            guard let self else { return }

            // Determine if this is a .tar.gz style double extension
            let isTarGz = Self.isTarCompressed(url: url)

            if isTarGz || Self.tarFamilyExtensions.contains(ext) {
                self.loadTarArchive(url: url, generation: generation, fileSize: fileSize, kind: kind)
            } else if Self.zipFamilyExtensions.contains(ext) {
                self.loadZipArchive(url: url, ext: ext, generation: generation, fileSize: fileSize, kind: kind)
            } else if ext == "pkg" {
                self.loadPkgArchive(url: url, generation: generation, fileSize: fileSize, kind: kind)
            } else if ext == "xip" {
                self.loadXipArchive(url: url, generation: generation, fileSize: fileSize, kind: kind)
            } else if ext == "deb" {
                self.loadDebArchive(url: url, generation: generation, fileSize: fileSize, kind: kind)
            } else if ext == "7z" {
                self.load7zArchive(url: url, generation: generation, fileSize: fileSize, kind: kind)
            } else if ext == "rar" {
                self.loadRarArchive(url: url, generation: generation, fileSize: fileSize, kind: kind)
            } else if ext == "dmg" {
                self.loadDmgInfo(url: url, generation: generation, fileSize: fileSize, kind: kind)
            } else if Self.singleCompressionExtensions.contains(ext) {
                self.loadSingleCompression(url: url, ext: ext, generation: generation, fileSize: fileSize, kind: kind)
            } else {
                // Metadata only (iso, rpm, cab, cpio, cpgz, ar)
                self.showMetadataOnly(generation: generation, fileSize: fileSize, kind: kind)
            }
        }
    }

    func clear() {
        loadGeneration += 1
        currentItem = nil
        rootEntries = []
        outlineView.reloadData()
        mediaInfoView.isHidden = true
        errorLabel.isHidden = true
        loadingSpinner.stopAnimation(nil)
    }

    // MARK: - Archive Loaders

    private func loadZipArchive(url: URL, ext: String, generation: Int, fileSize: Int64, kind: String) {
        let output = runProcess(
            executablePath: "/usr/bin/unzip",
            arguments: ["-l", url.path]
        )

        guard generation == loadGeneration else { return }

        if let output {
            let parsed = Self.parseUnzipListing(output)
            let entries = Self.buildTree(from: parsed.entries)
            Self.computeDirectorySizes(entries)

            let compressedSize: Int64 = fileSize
            let fileCount = Self.countFiles(in: entries)
            let dirCount = Self.countDirectories(in: entries)

            var rows: [MediaInfoRow] = []
            rows.append(MediaInfoRow(label: "Format", value: Self.formatName(for: ext)))
            rows.append(MediaInfoRow(label: "Entries", value: Self.entrySummary(files: fileCount, folders: dirCount)))
            rows.append(MediaInfoRow(label: "Compressed", value: Self.byteFormatter.string(fromByteCount: compressedSize)))
            if let uncompressedSize = parsed.totalSize {
                rows.append(MediaInfoRow(label: "Uncompressed", value: Self.byteFormatter.string(fromByteCount: uncompressedSize)))
                if uncompressedSize > 0 {
                    let ratio = Int(round(Double(compressedSize) / Double(uncompressedSize) * 100))
                    rows.append(MediaInfoRow(label: "Ratio", value: "\(ratio)%"))
                }
            }

            if ext == "ipa" {
                let ipaRows = self.extractIPAInfo(url: url)
                rows.append(contentsOf: ipaRows)
            }

            let summary = Self.makeCompactSummary(files: fileCount, folders: dirCount, compressedSize: compressedSize)

            DispatchQueue.main.async { [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                self.rootEntries = entries
                self.finishLoading(rows: rows, summary: summary, kind: kind, showTree: true)
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                self.showError("Could not read archive contents")
            }
        }
    }

    private func loadTarArchive(url: URL, generation: Int, fileSize: Int64, kind: String) {
        let output = runProcess(
            executablePath: "/usr/bin/tar",
            arguments: ["-tvf", url.path]
        )

        guard generation == loadGeneration else { return }

        if let output {
            let parsed = Self.parseTarListing(output)
            let entries = Self.buildTree(from: parsed)
            Self.computeDirectorySizes(entries)
            let fileCount = Self.countFiles(in: entries)
            let dirCount = Self.countDirectories(in: entries)

            var rows: [MediaInfoRow] = []
            rows.append(MediaInfoRow(label: "Format", value: Self.tarFormatName(for: url)))
            rows.append(MediaInfoRow(label: "Entries", value: Self.entrySummary(files: fileCount, folders: dirCount)))
            rows.append(MediaInfoRow(label: "Size", value: Self.byteFormatter.string(fromByteCount: fileSize)))

            let summary = Self.makeCompactSummary(files: fileCount, folders: dirCount, compressedSize: fileSize)

            DispatchQueue.main.async { [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                self.rootEntries = entries
                self.finishLoading(rows: rows, summary: summary, kind: kind, showTree: true)
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                self.showError("Could not read archive contents")
            }
        }
    }

    private func loadPkgArchive(url: URL, generation: Int, fileSize: Int64, kind: String) {
        let output = runProcess(
            executablePath: "/usr/sbin/pkgutil",
            arguments: ["--payload-files", url.path]
        )

        guard generation == loadGeneration else { return }

        if let output {
            let paths = output.components(separatedBy: "\n").filter { !$0.isEmpty }
            let items = paths.map { (path: $0, size: Int64(0)) }
            let entries = Self.buildTree(from: items)
            let fileCount = Self.countFiles(in: entries)
            let dirCount = Self.countDirectories(in: entries)

            var rows: [MediaInfoRow] = []
            rows.append(MediaInfoRow(label: "Format", value: "Installer Package"))
            rows.append(MediaInfoRow(label: "Entries", value: Self.entrySummary(files: fileCount, folders: dirCount)))
            rows.append(MediaInfoRow(label: "Size", value: Self.byteFormatter.string(fromByteCount: fileSize)))

            let summary = Self.makeCompactSummary(files: fileCount, folders: dirCount, compressedSize: fileSize)

            DispatchQueue.main.async { [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                self.rootEntries = entries
                self.finishLoading(rows: rows, summary: summary, kind: kind, showTree: true)
            }
        } else {
            // pkgutil may fail for some pkg files
            showMetadataOnly(generation: generation, fileSize: fileSize, kind: kind)
        }
    }

    private func loadXipArchive(url: URL, generation: Int, fileSize: Int64, kind: String) {
        // xip --list can be slow, so just show metadata
        var rows: [MediaInfoRow] = []
        rows.append(MediaInfoRow(label: "Format", value: "Xcode Archive"))
        rows.append(MediaInfoRow(label: "Size", value: Self.byteFormatter.string(fromByteCount: fileSize)))

        let summary = Self.byteFormatter.string(fromByteCount: fileSize)

        DispatchQueue.main.async { [weak self] in
            guard let self, self.loadGeneration == generation else { return }
            self.finishLoading(rows: rows, summary: summary, kind: kind, showTree: false)
        }
    }

    private func loadDebArchive(url: URL, generation: Int, fileSize: Int64, kind: String) {
        let arPath = "/usr/bin/ar"
        let hasAr = FileManager.default.fileExists(atPath: arPath)

        let output: String? = hasAr
            ? runProcess(executablePath: arPath, arguments: ["tv", url.path])
            : nil

        guard generation == loadGeneration else { return }

        if let output {
            let parsed = Self.parseArListing(output)
            let entries = Self.buildTree(from: parsed)
            let fileCount = Self.countFiles(in: entries)
            let dirCount = Self.countDirectories(in: entries)

            var rows: [MediaInfoRow] = []
            rows.append(MediaInfoRow(label: "Format", value: "Debian Package"))
            rows.append(MediaInfoRow(label: "Entries", value: Self.entrySummary(files: fileCount, folders: dirCount)))
            rows.append(MediaInfoRow(label: "Size", value: Self.byteFormatter.string(fromByteCount: fileSize)))

            let summary = Self.makeCompactSummary(files: fileCount, folders: dirCount, compressedSize: fileSize)

            DispatchQueue.main.async { [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                self.rootEntries = entries
                self.finishLoading(rows: rows, summary: summary, kind: kind, showTree: true)
            }
        } else {
            var rows: [MediaInfoRow] = []
            rows.append(MediaInfoRow(label: "Format", value: "Debian Package"))
            rows.append(MediaInfoRow(label: "Size", value: Self.byteFormatter.string(fromByteCount: fileSize)))
            let summary = Self.byteFormatter.string(fromByteCount: fileSize)
            let needsTools = !hasAr

            DispatchQueue.main.async { [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                self.finishLoading(rows: rows, summary: summary, kind: kind, showTree: false)
                if needsTools {
                    self.errorLabel.stringValue = "Install Xcode Command Line Tools to preview contents"
                    self.errorLabel.isHidden = false
                }
            }
        }
    }

    private func load7zArchive(url: URL, generation: Int, fileSize: Int64, kind: String) {
        // Check if 7z is available
        let sevenZipPath = Self.findExecutable(name: "7z", searchPaths: [
            "/usr/local/bin/7z",
            "/opt/homebrew/bin/7z",
        ])

        guard generation == loadGeneration else { return }

        guard let sevenZipPath else {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                var rows: [MediaInfoRow] = []
                rows.append(MediaInfoRow(label: "Format", value: "7-Zip Archive"))
                rows.append(MediaInfoRow(label: "Size", value: Self.byteFormatter.string(fromByteCount: fileSize)))
                self.finishLoading(rows: rows, summary: Self.byteFormatter.string(fromByteCount: fileSize), kind: kind, showTree: false)
                self.errorLabel.stringValue = "Install 7-Zip to preview contents"
                self.errorLabel.isHidden = false
            }
            return
        }

        let output = runProcess(
            executablePath: sevenZipPath,
            arguments: ["l", url.path]
        )

        guard generation == loadGeneration else { return }

        if let output {
            let parsed = Self.parse7zListing(output)
            let entries = Self.buildTree(from: parsed)
            Self.computeDirectorySizes(entries)
            let fileCount = Self.countFiles(in: entries)
            let dirCount = Self.countDirectories(in: entries)

            var rows: [MediaInfoRow] = []
            rows.append(MediaInfoRow(label: "Format", value: "7-Zip Archive"))
            rows.append(MediaInfoRow(label: "Entries", value: Self.entrySummary(files: fileCount, folders: dirCount)))
            rows.append(MediaInfoRow(label: "Size", value: Self.byteFormatter.string(fromByteCount: fileSize)))

            let summary = Self.makeCompactSummary(files: fileCount, folders: dirCount, compressedSize: fileSize)

            DispatchQueue.main.async { [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                self.rootEntries = entries
                self.finishLoading(rows: rows, summary: summary, kind: kind, showTree: true)
            }
        } else {
            showMetadataOnly(generation: generation, fileSize: fileSize, kind: kind)
        }
    }

    private func loadRarArchive(url: URL, generation: Int, fileSize: Int64, kind: String) {
        let unrarPath = Self.findExecutable(name: "unrar", searchPaths: [
            "/usr/local/bin/unrar",
            "/opt/homebrew/bin/unrar",
        ])

        guard generation == loadGeneration else { return }

        guard let unrarPath else {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                var rows: [MediaInfoRow] = []
                rows.append(MediaInfoRow(label: "Format", value: "RAR Archive"))
                rows.append(MediaInfoRow(label: "Size", value: Self.byteFormatter.string(fromByteCount: fileSize)))
                self.finishLoading(rows: rows, summary: Self.byteFormatter.string(fromByteCount: fileSize), kind: kind, showTree: false)
                self.errorLabel.stringValue = "Install unrar to preview contents"
                self.errorLabel.isHidden = false
            }
            return
        }

        let output = runProcess(
            executablePath: unrarPath,
            arguments: ["l", url.path]
        )

        guard generation == loadGeneration else { return }

        if let output {
            let parsed = Self.parseRarListing(output)
            let entries = Self.buildTree(from: parsed)
            Self.computeDirectorySizes(entries)
            let fileCount = Self.countFiles(in: entries)
            let dirCount = Self.countDirectories(in: entries)

            var rows: [MediaInfoRow] = []
            rows.append(MediaInfoRow(label: "Format", value: "RAR Archive"))
            rows.append(MediaInfoRow(label: "Entries", value: Self.entrySummary(files: fileCount, folders: dirCount)))
            rows.append(MediaInfoRow(label: "Size", value: Self.byteFormatter.string(fromByteCount: fileSize)))

            let summary = Self.makeCompactSummary(files: fileCount, folders: dirCount, compressedSize: fileSize)

            DispatchQueue.main.async { [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                self.rootEntries = entries
                self.finishLoading(rows: rows, summary: summary, kind: kind, showTree: true)
            }
        } else {
            showMetadataOnly(generation: generation, fileSize: fileSize, kind: kind)
        }
    }

    private func loadDmgInfo(url: URL, generation: Int, fileSize: Int64, kind: String) {
        // Get DMG metadata
        let infoOutput = runProcess(
            executablePath: "/usr/bin/hdiutil",
            arguments: ["imageinfo", url.path]
        )

        guard generation == loadGeneration else { return }

        var rows: [MediaInfoRow] = []
        rows.append(MediaInfoRow(label: "Format", value: "Disk Image"))
        rows.append(MediaInfoRow(label: "Size", value: Self.byteFormatter.string(fromByteCount: fileSize)))

        if let infoOutput {
            let dmgRows = Self.parseDmgInfo(infoOutput)
            rows.append(contentsOf: dmgRows)
        }

        // Try to mount read-only to list contents
        let mountPoint = Self.attachDmgReadOnly(url: url)
        guard generation == loadGeneration else {
            if let mountPoint { Self.detachDmg(mountPoint: mountPoint) }
            return
        }

        var entries: [ArchiveEntry] = []
        if let mountPoint {
            let contents = Self.listDirectoryRecursive(at: mountPoint)
            entries = Self.buildTree(from: contents)
            Self.computeDirectorySizes(entries)
            Self.detachDmg(mountPoint: mountPoint)
        }

        let fileCount = Self.countFiles(in: entries)
        let dirCount = Self.countDirectories(in: entries)
        let showTree = !entries.isEmpty

        if showTree {
            rows.append(MediaInfoRow(label: "Contents", value: Self.entrySummary(files: fileCount, folders: dirCount)))
        }

        let summary: String
        if showTree {
            summary = Self.makeCompactSummary(files: fileCount, folders: dirCount, compressedSize: fileSize)
        } else {
            summary = Self.byteFormatter.string(fromByteCount: fileSize)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.loadGeneration == generation else { return }
            self.rootEntries = entries
            self.finishLoading(rows: rows, summary: summary, kind: kind, showTree: showTree)
        }
    }

    /// Attaches a DMG read-only without browsing, returns the mount point path or nil.
    private static func attachDmgReadOnly(url: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", url.path, "-readonly", "-nobrowse", "-noverify", "-noautoopen", "-plist"]

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return nil }

            // Parse plist output to find mount point
            guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let entities = plist["system-entities"] as? [[String: Any]]
            else { return nil }

            for entity in entities {
                if let mountPoint = entity["mount-point"] as? String {
                    return mountPoint
                }
            }
            return nil
        } catch {
            return nil
        }
    }

    /// Detaches a mounted DMG volume.
    private static func detachDmg(mountPoint: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mountPoint, "-quiet"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    /// Lists directory contents recursively, returning relative paths with sizes.
    private static func listDirectoryRecursive(at root: String) -> [(path: String, size: Int64)] {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: root)
        var results: [(path: String, size: Int64)] = []

        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return results }

        for case let fileURL as URL in enumerator {
            let relativePath = fileURL.path.replacingOccurrences(of: root + "/", with: "")
            guard !relativePath.isEmpty, relativePath != root else { continue }

            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            let isDir = values?.isDirectory ?? false
            let size = Int64(values?.fileSize ?? 0)
            let path = isDir ? relativePath + "/" : relativePath
            results.append((path: path, size: size))
        }

        return results
    }

    private func loadSingleCompression(url: URL, ext: String, generation: Int, fileSize: Int64, kind: String) {
        // For single-file compression, check if it's actually a .tar.gz
        // (already handled by isTarCompressed check in displayItem)

        // Show just metadata - original filename, size
        let originalName = Self.strippedFilename(url: url, ext: ext)

        var rows: [MediaInfoRow] = []
        rows.append(MediaInfoRow(label: "Format", value: Self.compressionFormatName(for: ext)))
        rows.append(MediaInfoRow(label: "Compressed", value: Self.byteFormatter.string(fromByteCount: fileSize)))
        if let originalName {
            rows.append(MediaInfoRow(label: "Contents", value: originalName))
        }

        let summary = Self.byteFormatter.string(fromByteCount: fileSize)

        DispatchQueue.main.async { [weak self] in
            guard let self, self.loadGeneration == generation else { return }
            self.finishLoading(rows: rows, summary: summary, kind: kind, showTree: false)
        }
    }

    private func showMetadataOnly(generation: Int, fileSize: Int64, kind: String) {
        var rows: [MediaInfoRow] = []
        rows.append(MediaInfoRow(label: "Format", value: kind))
        rows.append(MediaInfoRow(label: "Size", value: Self.byteFormatter.string(fromByteCount: fileSize)))

        let summary = Self.byteFormatter.string(fromByteCount: fileSize)

        DispatchQueue.main.async { [weak self] in
            guard let self, self.loadGeneration == generation else { return }
            self.finishLoading(rows: rows, summary: summary, kind: kind, showTree: false)
        }
    }

    // MARK: - Completion Helpers

    private func finishLoading(rows: [MediaInfoRow], summary: String, kind: String, showTree: Bool) {
        loadingSpinner.stopAnimation(nil)

        mediaInfoView.update(title: "Archive Info", compactSummary: summary, rows: rows)
        mediaInfoView.isHidden = false

        if showTree {
            scrollView.isHidden = false
            outlineView.reloadData()
            // Auto-expand first level
            for entry in rootEntries {
                outlineView.expandItem(entry)
            }
        } else {
            scrollView.isHidden = true
        }

        headerView.setCompactDetail(summary)
    }

    private func showError(_ message: String) {
        loadingSpinner.stopAnimation(nil)
        scrollView.isHidden = true
        errorLabel.stringValue = message
        errorLabel.isHidden = false
    }

    // MARK: - Process Execution

    private func runProcess(executablePath: String, arguments: [String]) -> String? {
        guard FileManager.default.fileExists(atPath: executablePath) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    // MARK: - Tree Building

    private static func buildTree(from items: [(path: String, size: Int64)]) -> [ArchiveEntry] {
        var rootEntries: [ArchiveEntry] = []
        var lookup: [String: ArchiveEntry] = [:]

        for item in items {
            let isDir = item.path.hasSuffix("/")
            let cleanPath = isDir ? String(item.path.dropLast()) : item.path
            let components = cleanPath.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }

            // Strip leading "./" prefix if present
            let effectiveComponents: [String]
            if components.first == "." {
                effectiveComponents = Array(components.dropFirst())
                guard !effectiveComponents.isEmpty else { continue }
            } else {
                effectiveComponents = components
            }

            var currentPath = ""
            var parent: ArchiveEntry?

            for (i, component) in effectiveComponents.enumerated() {
                currentPath += (currentPath.isEmpty ? "" : "/") + component
                let isLastComponent = (i == effectiveComponents.count - 1)
                let entryIsDir = isLastComponent ? isDir : true

                if let existing = lookup[currentPath] {
                    parent = existing
                } else {
                    let entry = ArchiveEntry(
                        name: component,
                        fullPath: currentPath,
                        isDirectory: entryIsDir
                    )
                    if isLastComponent {
                        entry.size = item.size
                    }
                    lookup[currentPath] = entry
                    if let parent {
                        parent.children.append(entry)
                    } else {
                        rootEntries.append(entry)
                    }
                    parent = entry
                }
            }
        }

        sortEntries(&rootEntries)
        return rootEntries
    }

    /// Computes cumulative sizes for directory entries by summing children.
    private static func computeDirectorySizes(_ entries: [ArchiveEntry]) {
        for entry in entries {
            if entry.isDirectory {
                computeDirectorySizes(entry.children)
                entry.size = entry.children.reduce(Int64(0)) { $0 + $1.size }
            }
        }
    }

    private static func sortEntries(_ entries: inout [ArchiveEntry]) {
        entries.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        for entry in entries {
            sortEntries(&entry.children)
        }
    }

    // MARK: - Counting Helpers

    private static func countFiles(in entries: [ArchiveEntry]) -> Int {
        var count = 0
        for entry in entries {
            if entry.isDirectory {
                count += countFiles(in: entry.children)
            } else {
                count += 1
            }
        }
        return count
    }

    private static func countDirectories(in entries: [ArchiveEntry]) -> Int {
        var count = 0
        for entry in entries {
            if entry.isDirectory {
                count += 1
                count += countDirectories(in: entry.children)
            }
        }
        return count
    }

    // MARK: - Parsing Helpers

    /// Parses `unzip -l` output to extract per-file paths and sizes, plus the total uncompressed size.
    /// Format:
    /// ```
    ///   Length      Date    Time    Name
    /// ---------  ---------- -----   ----
    ///      1234  2024-01-01 12:00   path/to/file.txt
    /// ---------                     -------
    ///      1234                     1 file
    /// ```
    private static func parseUnzipListing(_ output: String) -> (entries: [(path: String, size: Int64)], totalSize: Int64?) {
        var entries: [(path: String, size: Int64)] = []
        var totalSize: Int64?
        var inTable = false
        let lines = output.components(separatedBy: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("--------") {
                if inTable {
                    // Footer separator — next non-empty line has the total
                    break
                }
                inTable = true
                continue
            }
            if inTable {
                guard !trimmed.isEmpty else { continue }
                // Format: "  <size>  <date> <time>   <path>"
                let parts = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
                guard parts.count >= 4 else { continue }
                let size = Int64(parts[0]) ?? 0
                let path = String(parts[3])
                entries.append((path: path, size: size))
            }
        }

        // Parse total from footer
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("--------") { continue }
            let parts = trimmed.split(separator: " ")
            if let first = parts.first, let size = Int64(first) {
                totalSize = size
            }
            break
        }

        return (entries, totalSize)
    }

    /// Parses `tar -tvf` output to extract per-file paths and sizes.
    /// macOS format: `drwxr-xr-x  0 user   staff       0 Mar 14 12:00 dir/`
    /// GNU format:   `drwxr-xr-x user/group       0 2024-03-14 12:00 dir/`
    private static func parseTarListing(_ output: String) -> [(path: String, size: Int64)] {
        var entries: [(path: String, size: Int64)] = []
        let lines = output.components(separatedBy: "\n")

        for line in lines {
            guard !line.isEmpty else { continue }
            // Split into at most 9 parts: perms, links/user, user/group, group/size, size/date, ...
            // The size is always followed by a date and the path is the last field.
            // Strategy: find the size by scanning numeric fields after permissions.
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 6 else { continue }

            // Find the size: it's the first purely numeric field after the permissions field (index 0).
            // On macOS tar: [perms, linkCount, user, group, size, month, day, time, path...]
            // On GNU tar:   [perms, user/group, size, date, time, path...]
            var sizeValue: Int64 = 0
            var pathStartIndex = parts.count - 1

            if parts.count >= 9, let size = Int64(parts[4]) {
                // macOS format: perms(0) links(1) user(2) group(3) size(4) month(5) day(6) time(7) path(8+)
                sizeValue = size
                pathStartIndex = 8
            } else if parts.count >= 6, let size = Int64(parts[2]) {
                // GNU format: perms(0) user/group(1) size(2) date(3) time(4) path(5+)
                sizeValue = size
                pathStartIndex = 5
            } else {
                // Fallback: last field is the path, no size
                pathStartIndex = parts.count - 1
            }

            // Reconstruct path (may contain spaces)
            let path = parts[pathStartIndex...].joined(separator: " ")
            guard !path.isEmpty else { continue }
            entries.append((path: path, size: sizeValue))
        }

        return entries
    }

    /// Parses `7z l` output to extract per-file paths and sizes.
    /// Format:
    /// ```
    ///    Date      Time    Attr         Size   Compressed  Name
    /// ------------------- ----- ------------ ------------  ----
    /// 2024-01-01 12:00:00 ....A         1234          567  path/to/file.txt
    /// ```
    private static func parse7zListing(_ output: String) -> [(path: String, size: Int64)] {
        var entries: [(path: String, size: Int64)] = []
        var inTable = false
        let lines = output.components(separatedBy: "\n")

        for line in lines {
            if line.hasPrefix("---") {
                if inTable {
                    break // End of table
                }
                inTable = true
                continue
            }
            if inTable {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                // Fields: Date(0) Time(1) Attr(2) Size(3) Compressed(4) Name(5+)
                let parts = trimmed.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
                if parts.count >= 6 {
                    let size = Int64(parts[3]) ?? 0
                    let name = String(parts[5])
                    entries.append((path: name, size: size))
                }
            }
        }

        return entries
    }

    /// Parses `unrar l` output to extract per-file paths and sizes.
    /// Format:
    /// ```
    ///  Attributes      Size     Date    Time   Name
    /// ----------- ---------  ---------- -----  ----
    ///     ..A....      1234  2024-01-01 12:00  path/to/file.txt
    /// -----------  ---------  ---------- -----  ----
    /// ```
    private static func parseRarListing(_ output: String) -> [(path: String, size: Int64)] {
        var entries: [(path: String, size: Int64)] = []
        var inTable = false
        let lines = output.components(separatedBy: "\n")

        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("----------") {
                if inTable {
                    break // End of table
                }
                inTable = true
                continue
            }
            if inTable {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                // Fields: Attr(0) Size(1) Date(2) Time(3) Name(4+)
                let parts = trimmed.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
                if parts.count >= 5 {
                    let size = Int64(parts[1]) ?? 0
                    let name = String(parts[4])
                    entries.append((path: name, size: size))
                }
            }
        }

        return entries
    }

    /// Parses `ar tv` output to extract per-file paths and sizes.
    /// Format: `rw-r--r--  0/0   1234 Jan  1 12:00 2024 filename`
    private static func parseArListing(_ output: String) -> [(path: String, size: Int64)] {
        var entries: [(path: String, size: Int64)] = []
        let lines = output.components(separatedBy: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // Fields: perms(0) uid/gid(1) size(2) month(3) day(4) time(5) year(6) name(7+)
            let parts = trimmed.split(separator: " ", maxSplits: 7, omittingEmptySubsequences: true)
            if parts.count >= 8 {
                let size = Int64(parts[2]) ?? 0
                let name = String(parts[7])
                entries.append((path: name, size: size))
            } else if parts.count >= 3 {
                // Fallback: at least try to get name
                let name = String(parts.last ?? "")
                let size = Int64(parts[2]) ?? 0
                entries.append((path: name, size: size))
            }
        }

        return entries
    }

    private static func parseDmgInfo(_ output: String) -> [MediaInfoRow] {
        var rows: [MediaInfoRow] = []
        let lines = output.components(separatedBy: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("Format Description:") {
                let value = trimmed.replacingOccurrences(of: "Format Description:", with: "").trimmingCharacters(in: .whitespaces)
                if !value.isEmpty {
                    rows.append(MediaInfoRow(label: "DMG Format", value: value))
                }
            } else if trimmed.hasPrefix("Encrypted:") {
                let value = trimmed.replacingOccurrences(of: "Encrypted:", with: "").trimmingCharacters(in: .whitespaces)
                if !value.isEmpty {
                    rows.append(MediaInfoRow(label: "Encrypted", value: value))
                }
            } else if trimmed.hasPrefix("Partition Type:") {
                let value = trimmed.replacingOccurrences(of: "Partition Type:", with: "").trimmingCharacters(in: .whitespaces)
                if !value.isEmpty {
                    rows.append(MediaInfoRow(label: "Partitions", value: value))
                }
            }
        }

        return rows
    }

    private func extractIPAInfo(url: URL) -> [MediaInfoRow] {
        var rows: [MediaInfoRow] = []

        guard let output = runProcess(
            executablePath: "/usr/bin/unzip",
            arguments: ["-p", url.path, "Payload/*.app/Info.plist"]
        ) else { return rows }

        guard let data = output.data(using: .utf8), !data.isEmpty,
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { return rows }

        if let name = plist["CFBundleName"] as? String {
            rows.append(MediaInfoRow(label: "App Name", value: name))
        }
        if let bundleID = plist["CFBundleIdentifier"] as? String {
            rows.append(MediaInfoRow(label: "Bundle ID", value: bundleID))
        }
        if let version = plist["CFBundleShortVersionString"] as? String {
            rows.append(MediaInfoRow(label: "Version", value: version))
        }
        if let minOS = plist["MinimumOSVersion"] as? String {
            rows.append(MediaInfoRow(label: "Min iOS", value: minOS))
        }

        return rows
    }

    // MARK: - Format Name Helpers

    private static func formatName(for ext: String) -> String {
        switch ext {
        case "zip": return "ZIP Archive"
        case "cbz": return "Comic Book Archive"
        case "ipa": return "iOS App Archive"
        case "apk": return "Android App Archive"
        case "jar": return "Java Archive"
        case "war": return "Web Archive (WAR)"
        case "ear": return "Enterprise Archive (EAR)"
        default: return "ZIP Archive"
        }
    }

    private static func tarFormatName(for url: URL) -> String {
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()

        if name.hasSuffix(".tar.gz") || ext == "tgz" { return "TAR.GZ Archive" }
        if name.hasSuffix(".tar.bz2") || ext == "tbz" || ext == "tbz2" { return "TAR.BZ2 Archive" }
        if name.hasSuffix(".tar.xz") || ext == "txz" { return "TAR.XZ Archive" }
        if name.hasSuffix(".tar.lz") || ext == "tlz" { return "TAR.LZ Archive" }
        return "TAR Archive"
    }

    private static func compressionFormatName(for ext: String) -> String {
        switch ext {
        case "gz": return "GZip Compressed"
        case "bz2": return "BZip2 Compressed"
        case "xz": return "XZ Compressed"
        case "lz": return "LZ Compressed"
        case "lzma": return "LZMA Compressed"
        case "zst": return "Zstandard Compressed"
        case "lz4": return "LZ4 Compressed"
        case "br": return "Brotli Compressed"
        default: return "Compressed File"
        }
    }

    private static func isTarCompressed(url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".tar.gz")
            || name.hasSuffix(".tar.bz2")
            || name.hasSuffix(".tar.xz")
            || name.hasSuffix(".tar.lz")
            || name.hasSuffix(".tar.lzma")
            || name.hasSuffix(".tar.zst")
    }

    private static func strippedFilename(url: URL, ext: String) -> String? {
        let name = url.lastPathComponent
        guard name.count > ext.count + 1 else { return nil }
        return String(name.dropLast(ext.count + 1))
    }

    private static func entrySummary(files: Int, folders: Int) -> String {
        var parts: [String] = []
        if files > 0 { parts.append("\(files) file\(files == 1 ? "" : "s")") }
        if folders > 0 { parts.append("\(folders) folder\(folders == 1 ? "" : "s")") }
        return parts.isEmpty ? "Empty" : parts.joined(separator: ", ")
    }

    private static func makeCompactSummary(files: Int, folders: Int, compressedSize: Int64) -> String {
        var parts: [String] = []
        parts.append(entrySummary(files: files, folders: folders))
        parts.append(byteFormatter.string(fromByteCount: compressedSize))
        return parts.joined(separator: " \u{00B7} ")
    }

    private static func findExecutable(name: String, searchPaths: [String]) -> String? {
        for path in searchPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }
}

// MARK: - NSOutlineViewDataSource

extension ArchivePreviewViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return rootEntries.count
        }
        guard let entry = item as? ArchiveEntry else { return 0 }
        return entry.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let entry = item as? ArchiveEntry {
            return entry.children[index]
        }
        return rootEntries[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let entry = item as? ArchiveEntry else { return false }
        return entry.isDirectory && !entry.children.isEmpty
    }
}

// MARK: - NSOutlineViewDelegate

extension ArchivePreviewViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let entry = item as? ArchiveEntry else { return nil }

        if tableColumn?.identifier == Self.nameColumnID {
            let cellID = NSUserInterfaceItemIdentifier("ArchiveNameCell")
            let cell: NSTableCellView
            if let reused = outlineView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = cellID

                let icon = NSImageView()
                icon.translatesAutoresizingMaskIntoConstraints = false
                icon.imageScaling = .scaleProportionallyDown
                cell.addSubview(icon)
                cell.imageView = icon

                let text = NSTextField(labelWithString: "")
                text.translatesAutoresizingMaskIntoConstraints = false
                text.font = NSFont.systemFont(ofSize: 12)
                text.lineBreakMode = .byTruncatingTail
                cell.addSubview(text)
                cell.textField = text

                NSLayoutConstraint.activate([
                    icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    icon.widthAnchor.constraint(equalToConstant: 16),
                    icon.heightAnchor.constraint(equalToConstant: 16),
                    text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
                    text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                    text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }

            let symbolName = entry.isDirectory ? "folder" : "doc"
            cell.imageView?.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: entry.isDirectory ? "Folder" : "File")
            cell.textField?.stringValue = entry.name
            return cell
        }

        if tableColumn?.identifier == Self.sizeColumnID {
            let cellID = NSUserInterfaceItemIdentifier("ArchiveSizeCell")
            let cell: NSTableCellView
            if let reused = outlineView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = cellID

                let text = NSTextField(labelWithString: "")
                text.translatesAutoresizingMaskIntoConstraints = false
                text.font = NSFont.systemFont(ofSize: 11)
                text.textColor = .secondaryLabelColor
                text.alignment = .right
                text.lineBreakMode = .byTruncatingTail
                cell.addSubview(text)
                cell.textField = text

                NSLayoutConstraint.activate([
                    text.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                    text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }

            if entry.size > 0 {
                cell.textField?.stringValue = Self.byteFormatter.string(fromByteCount: entry.size)
            } else {
                cell.textField?.stringValue = ""
            }
            return cell
        }

        return nil
    }
}
