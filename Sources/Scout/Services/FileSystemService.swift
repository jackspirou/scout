import AppKit
import Foundation

// MARK: - FileSystemError

enum FileSystemError: LocalizedError {
    case directoryNotFound(URL)
    case fileNotFound(URL)
    case permissionDenied(URL)
    case itemAlreadyExists(URL)
    case invalidName(String)
    case renameFailed(URL, String)
    case batchRenameFailed(String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .directoryNotFound(url):
            return "Directory not found: \(url.path)"
        case let .fileNotFound(url):
            return "File not found: \(url.path)"
        case let .permissionDenied(url):
            return "Permission denied: \(url.path)"
        case let .itemAlreadyExists(url):
            return "Item already exists: \(url.path)"
        case let .invalidName(name):
            return "Invalid name: \(name)"
        case let .renameFailed(url, newName):
            return "Failed to rename \(url.lastPathComponent) to \(newName)"
        case let .batchRenameFailed(reason):
            return "Batch rename failed: \(reason)"
        case let .operationFailed(reason):
            return "Operation failed: \(reason)"
        }
    }
}

// MARK: - FileSystemService

/// Actor-based service for file system operations.
/// Uses FileManager and POSIX APIs for performance-sensitive paths.
actor FileSystemService: FileSystemServiceProtocol {
    private let fileManager: FileManager
    var iconStyle: IconStyle

    init(fileManager: FileManager = .default, iconStyle: IconStyle = .system) {
        self.fileManager = fileManager
        self.iconStyle = iconStyle
    }

    func setIconStyle(_ style: IconStyle) {
        self.iconStyle = style
    }

    // MARK: - Directory Contents

    /// Returns the contents of a directory, sorted according to the specified field and order.
    func contentsOfDirectory(
        at url: URL,
        sortedBy sortField: SortField = .name,
        order: SortOrder = .ascending,
        showHiddenFiles: Bool = false
    ) async throws -> [FileItem] {
        guard directoryExists(at: url) else {
            throw FileSystemError.directoryNotFound(url)
        }

        let resourceKeys: Set<URLResourceKey> = [
            .nameKey,
            .isDirectoryKey,
            .isHiddenKey,
            .isSymbolicLinkKey,
            .isPackageKey,
            .fileSizeKey,
            .totalFileSizeKey,
            .contentModificationDateKey,
            .creationDateKey,
            .contentTypeKey,
            .localizedTypeDescriptionKey,
            .tagNamesKey,
            .fileSecurityKey,
        ]

        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: Array(resourceKeys),
                options: []
            )
        } catch let error as NSError {
            if error.code == NSFileReadNoPermissionError {
                throw FileSystemError.permissionDenied(url)
            }
            throw FileSystemError.operationFailed(error.localizedDescription)
        }

        var items: [FileItem] = []
        items.reserveCapacity(contents.count)

        for fileURL in contents {
            let item = buildFileItem(from: fileURL, resourceKeys: resourceKeys)
            items.append(item)
        }

        if !showHiddenFiles {
            items.removeAll { $0.isHidden }
        }

        items.sort { lhs, rhs in
            let result = FileItem.compare(lhs, rhs, by: sortField)
            return order == .ascending ? result : !result
        }

        return items
    }

    // MARK: - File Info

    /// Returns detailed information about a single file or directory.
    func fileInfo(at url: URL) async throws -> FileItem {
        guard fileManager.fileExists(atPath: url.path) else {
            throw FileSystemError.fileNotFound(url)
        }

        guard let item = FileItem.create(from: url, iconStyle: iconStyle) else {
            throw FileSystemError.operationFailed(
                "Failed to read attributes for \(url.path)"
            )
        }

        return item
    }

    // MARK: - Create Directory

    /// Creates a new directory at the specified location.
    func createDirectory(at url: URL, named name: String) async throws -> URL {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\0") else {
            throw FileSystemError.invalidName(name)
        }

        guard directoryExists(at: url) else {
            throw FileSystemError.directoryNotFound(url)
        }

        let newDirectoryURL = url.appendingPathComponent(name, isDirectory: true)

        guard !fileManager.fileExists(atPath: newDirectoryURL.path) else {
            throw FileSystemError.itemAlreadyExists(newDirectoryURL)
        }

        do {
            try fileManager.createDirectory(
                at: newDirectoryURL,
                withIntermediateDirectories: false,
                attributes: nil
            )
        } catch {
            throw FileSystemError.operationFailed(
                "Failed to create directory '\(name)': \(error.localizedDescription)"
            )
        }

        return newDirectoryURL
    }

    // MARK: - Move Items

    /// Moves items from source URLs to the destination directory.
    func moveItems(from sources: [URL], to destination: URL) async throws {
        try await transferItems(
            from: sources,
            to: destination,
            using: fileManager.moveItem,
            verb: "move"
        )
    }

    // MARK: - Copy Items

    /// Copies items from source URLs to the destination directory.
    func copyItems(from sources: [URL], to destination: URL) async throws {
        try await transferItems(
            from: sources,
            to: destination,
            using: fileManager.copyItem,
            verb: "copy"
        )
    }

    // MARK: - Trash Items

    /// Moves items to the trash and returns their new URLs in the trash.
    func trashItems(urls: [URL]) async throws -> [URL] {
        var trashedURLs: [URL] = []
        trashedURLs.reserveCapacity(urls.count)

        for url in urls {
            guard fileManager.fileExists(atPath: url.path) else {
                throw FileSystemError.fileNotFound(url)
            }

            var resultingURL: NSURL?
            do {
                try fileManager.trashItem(at: url, resultingItemURL: &resultingURL)
                if let trashedURL = resultingURL as URL? {
                    trashedURLs.append(trashedURL)
                }
            } catch {
                throw FileSystemError.operationFailed(
                    "Failed to trash \(url.lastPathComponent): \(error.localizedDescription)"
                )
            }
        }

        return trashedURLs
    }

    // MARK: - Rename Item

    /// Renames a file or directory and returns the new URL.
    func renameItem(at url: URL, to newName: String) async throws -> URL {
        guard !newName.isEmpty, !newName.contains("/"), !newName.contains("\0") else {
            throw FileSystemError.invalidName(newName)
        }

        guard fileManager.fileExists(atPath: url.path) else {
            throw FileSystemError.fileNotFound(url)
        }

        let parentURL = url.deletingLastPathComponent()
        let newURL = parentURL.appendingPathComponent(newName)

        guard !fileManager.fileExists(atPath: newURL.path) else {
            throw FileSystemError.itemAlreadyExists(newURL)
        }

        do {
            try fileManager.moveItem(at: url, to: newURL)
        } catch {
            throw FileSystemError.renameFailed(url, newName)
        }

        return newURL
    }

    // MARK: - Exists

    /// Checks whether a file or directory exists at the given URL.
    nonisolated func exists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Batch Rename

    /// Renames multiple files according to a pattern.
    func batchRename(urls: [URL], pattern: BatchRenamePattern) async throws -> [URL] {
        var renamedURLs: [URL] = []
        renamedURLs.reserveCapacity(urls.count)

        switch pattern {
        case let .regex(regexPattern, replacement):
            guard let regex = try? NSRegularExpression(pattern: regexPattern) else {
                throw FileSystemError.batchRenameFailed("Invalid regex pattern: \(regexPattern)")
            }

            for url in urls {
                let originalName = url.deletingPathExtension().lastPathComponent
                let ext = url.pathExtension
                let range = NSRange(originalName.startIndex..., in: originalName)
                let newBaseName = regex.stringByReplacingMatches(
                    in: originalName,
                    range: range,
                    withTemplate: replacement
                )
                let newName = ext.isEmpty ? newBaseName : "\(newBaseName).\(ext)"
                let newURL = try await renameItem(at: url, to: newName)
                renamedURLs.append(newURL)
            }

        case let .sequential(prefix, startNumber, zeroPadding, suffix):
            for (index, url) in urls.enumerated() {
                let number = startNumber + index
                let paddedNumber = String(format: "%0\(zeroPadding)d", number)
                let ext = url.pathExtension
                let newBaseName = "\(prefix)\(paddedNumber)\(suffix)"
                let newName = ext.isEmpty ? newBaseName : "\(newBaseName).\(ext)"
                let newURL = try await renameItem(at: url, to: newName)
                renamedURLs.append(newURL)
            }

        case let .findReplace(find, replace, caseSensitive):
            for url in urls {
                let originalName = url.lastPathComponent
                let options: String.CompareOptions = caseSensitive ? [] : .caseInsensitive
                let newName = originalName.replacingOccurrences(
                    of: find,
                    with: replace,
                    options: options
                )
                if newName != originalName {
                    let newURL = try await renameItem(at: url, to: newName)
                    renamedURLs.append(newURL)
                } else {
                    renamedURLs.append(url)
                }
            }

        case let .datePrefix(format):
            let formatter = DateFormatter()
            formatter.dateFormat = format

            for url in urls {
                let originalName = url.lastPathComponent
                let resourceValues = try url.resourceValues(forKeys: [
                    .contentModificationDateKey,
                ])
                let date = resourceValues.contentModificationDate ?? Date()
                let dateString = formatter.string(from: date)
                let newName = "\(dateString)_\(originalName)"
                let newURL = try await renameItem(at: url, to: newName)
                renamedURLs.append(newURL)
            }
        }

        return renamedURLs
    }

    // MARK: - Private Helpers

    /// Shared helper for move and copy operations.
    private func transferItems(
        from sources: [URL],
        to destination: URL,
        using operation: (URL, URL) throws -> Void,
        verb: String
    ) async throws {
        guard directoryExists(at: destination) else {
            throw FileSystemError.directoryNotFound(destination)
        }

        for sourceURL in sources {
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                throw FileSystemError.fileNotFound(sourceURL)
            }

            let destinationURL = destination.appendingPathComponent(sourceURL.lastPathComponent)

            do {
                try operation(sourceURL, destinationURL)
            } catch let error as NSError {
                if error.code == NSFileWriteFileExistsError {
                    throw FileSystemError.itemAlreadyExists(destinationURL)
                }
                throw FileSystemError.operationFailed(
                    "Failed to \(verb) \(sourceURL.lastPathComponent): \(error.localizedDescription)"
                )
            }
        }
    }

    private func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    /// Builds a FileItem from a URL using pre-fetched resource values.
    private func buildFileItem(from url: URL, resourceKeys: Set<URLResourceKey>) -> FileItem {
        // Prefer the factory method on FileItem which handles all edge cases.
        if let item = FileItem.create(from: url, iconStyle: iconStyle) {
            return item
        }

        // Fallback: create a minimal FileItem if resource values cannot be read.
        let name = url.lastPathComponent
        var isDir: ObjCBool = false
        fileManager.fileExists(atPath: url.path, isDirectory: &isDir)

        let resolved = FileTypeResolver.resolve(url: url, isDirectory: isDir.boolValue, systemKind: nil, iconStyle: iconStyle)
        return FileItem(
            url: url,
            name: name,
            isDirectory: isDir.boolValue,
            isHidden: name.hasPrefix("."),
            kind: resolved.kind,
            isText: resolved.isText,
            highlightrLanguage: resolved.highlightrLanguage,
            iconDescriptor: resolved.iconDescriptor,
            iconStyle: iconStyle
        )
    }
}
