import AppKit
import UniformTypeIdentifiers

/// Represents a single file system item with its metadata.
struct FileItem: Identifiable, Hashable {
    // MARK: - Properties

    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64?
    let modificationDate: Date?
    let creationDate: Date?
    let kind: String
    let icon: NSImage
    let isHidden: Bool
    let tags: [String]

    /// Additional properties used by FileSystemService and SearchService.
    let isSymlink: Bool
    let isPackage: Bool
    let contentType: String?
    let permissions: UInt16

    // MARK: - Identifiable

    var id: URL {
        url
    }

    // MARK: - Computed Properties

    /// The file extension (without leading dot), or an empty string if none.
    var `extension`: String {
        url.pathExtension
    }

    /// Human-readable file size string.
    var formattedSize: String {
        guard let size = size else { return "--" }
        return FileItem.byteCountFormatter.string(fromByteCount: size)
    }

    /// Alias for backward compatibility with code that uses `fileSize`.
    var fileSize: Int64 {
        size ?? 0
    }

    /// Alias for backward compatibility with code that uses `dateModified`.
    var dateModified: Date {
        modificationDate ?? Date.distantPast
    }

    // MARK: - Initializers

    /// Full initializer with all properties.
    init(
        url: URL,
        name: String,
        isDirectory: Bool,
        isHidden: Bool = false,
        isSymlink: Bool = false,
        isPackage: Bool = false,
        size: Int64? = nil,
        modificationDate: Date? = nil,
        creationDate: Date? = nil,
        kind: String? = nil,
        icon: NSImage? = nil,
        contentType: String? = nil,
        tags: [String] = [],
        permissions: UInt16 = 0o644
    ) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.isHidden = isHidden
        self.isSymlink = isSymlink
        self.isPackage = isPackage
        self.size = size
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.kind = kind ?? (isDirectory ? "Folder" : "Document")
        self.icon = icon ?? NSWorkspace.shared.icon(forFile: url.path)
        self.contentType = contentType
        self.tags = tags
        self.permissions = permissions
    }

    // MARK: - Hashable

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }

    static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.url == rhs.url
    }

    // MARK: - Factory

    /// Creates a `FileItem` by reading metadata from the file system at the given URL.
    /// Returns `nil` if the URL cannot be accessed.
    static func create(from url: URL) -> FileItem? {
        let fileManager = FileManager.default

        let resourceKeys: Set<URLResourceKey> = [
            .nameKey,
            .isDirectoryKey,
            .fileSizeKey,
            .totalFileSizeKey,
            .contentModificationDateKey,
            .creationDateKey,
            .localizedTypeDescriptionKey,
            .effectiveIconKey,
            .isHiddenKey,
            .isSymbolicLinkKey,
            .isPackageKey,
            .contentTypeKey,
            .tagNamesKey,
        ]

        guard let resourceValues = try? url.resourceValues(forKeys: resourceKeys) else {
            let name = url.lastPathComponent
            var isDir: ObjCBool = false
            let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDir)
            guard exists else { return nil }

            return FileItem(
                url: url,
                name: name,
                isDirectory: isDir.boolValue,
                isHidden: name.hasPrefix("."),
                size: nil,
                modificationDate: nil,
                creationDate: nil,
                kind: isDir.boolValue ? "Folder" : "Document",
                icon: NSWorkspace.shared.icon(forFile: url.path),
                tags: []
            )
        }

        let isDirectory = resourceValues.isDirectory ?? false
        let size: Int64? = isDirectory ? nil : Int64(resourceValues.totalFileSize ?? resourceValues.fileSize ?? 0)
        let icon = (resourceValues.effectiveIcon as? NSImage) ?? NSWorkspace.shared.icon(forFile: url.path)

        return FileItem(
            url: url,
            name: resourceValues.name ?? url.lastPathComponent,
            isDirectory: isDirectory,
            isHidden: resourceValues.isHidden ?? url.lastPathComponent.hasPrefix("."),
            isSymlink: resourceValues.isSymbolicLink ?? false,
            isPackage: resourceValues.isPackage ?? false,
            size: size,
            modificationDate: resourceValues.contentModificationDate,
            creationDate: resourceValues.creationDate,
            kind: resourceValues.localizedTypeDescription ?? (isDirectory ? "Folder" : "Document"),
            icon: icon,
            contentType: resourceValues.contentType?.identifier,
            tags: resourceValues.tagNames ?? []
        )
    }

    // MARK: - Sorting

    /// Compares two FileItems by the given sort field. Directories always sort before files.
    /// Returns true if `lhs` should appear before `rhs` in ascending order.
    static func compare(_ lhs: FileItem, _ rhs: FileItem, by field: SortField) -> Bool {
        if lhs.isDirectory != rhs.isDirectory {
            return lhs.isDirectory
        }

        switch field {
        case .name:
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        case .size:
            return (lhs.size ?? 0) < (rhs.size ?? 0)
        case .dateModified:
            return lhs.dateModified < rhs.dateModified
        case .dateCreated:
            return (lhs.creationDate ?? .distantPast) < (rhs.creationDate ?? .distantPast)
        case .kind:
            return lhs.kind.localizedStandardCompare(rhs.kind) == .orderedAscending
        }
    }

    // MARK: - Private

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter
    }()
}
