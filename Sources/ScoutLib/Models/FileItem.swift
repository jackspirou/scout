import AppKit
import CoreServices
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
    let isHidden: Bool
    let tags: [String]

    /// Additional properties used by FileSystemService and SearchService.
    let isSymlink: Bool
    let isPackage: Bool
    let contentType: String?
    let permissions: UInt16
    let isLocked: Bool
    let isText: Bool
    let highlightrLanguage: String?

    let addedDate: Date?

    /// Descriptor and style used to resolve the icon image on demand.
    let iconDescriptor: FileTypeDescriptor
    let iconStyle: IconStyle

    /// Lazily resolved icon image based on the descriptor and style.
    var icon: NSImage {
        FileTypeResolver.makeIcon(from: iconDescriptor, url: url, isDirectory: isDirectory, iconStyle: iconStyle)
    }

    // MARK: - Identifiable

    var id: URL {
        url
    }

    // MARK: - Computed Properties

    /// Whether this file is an image, determined by UTType conformance or known image extensions.
    var isImage: Bool {
        if let contentType, let utType = UTType(contentType) {
            return utType.conforms(to: .image)
        }
        return Self.imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// Whether this file is a video, determined by UTType conformance or known video extensions.
    var isVideo: Bool {
        if let contentType, let utType = UTType(contentType) {
            return utType.conforms(to: .movie)
        }
        return Self.videoExtensions.contains(url.pathExtension.lowercased())
    }

    /// Whether this file is an audio file, determined by UTType conformance or known audio extensions.
    var isAudio: Bool {
        if let contentType, let utType = UTType(contentType) {
            return utType.conforms(to: .audio)
        }
        return Self.audioExtensions.contains(url.pathExtension.lowercased())
    }

    /// Whether this file is a PDF document.
    var isPDF: Bool {
        if let contentType, let utType = UTType(contentType) {
            return utType.conforms(to: .pdf)
        }
        return url.pathExtension.lowercased() == "pdf"
    }

    /// Whether this file is a Markdown document.
    var isMarkdown: Bool {
        Self.markdownExtensions.contains(url.pathExtension.lowercased())
    }

    /// Whether this file is an HTML document.
    var isHTML: Bool {
        Self.htmlExtensions.contains(url.pathExtension.lowercased())
    }

    /// Whether this file is a rich document (.docx, .doc, .rtf, .rtfd, .odt).
    var isRichDocument: Bool {
        Self.richDocumentExtensions.contains(url.pathExtension.lowercased())
    }

    /// Whether this file is an SVG image.
    var isSVG: Bool {
        url.pathExtension.lowercased() == "svg"
    }

    /// Whether this file is a Mermaid diagram.
    var isMermaid: Bool {
        Self.mermaidExtensions.contains(url.pathExtension.lowercased())
    }

    /// Whether this file is a CSV document.
    var isCSV: Bool {
        url.pathExtension.lowercased() == "csv"
    }

    /// Whether this file is a TSV document.
    var isTSV: Bool {
        url.pathExtension.lowercased() == "tsv"
    }

    /// Whether this file is an archive.
    var isArchive: Bool {
        Self.archiveExtensions.contains(url.pathExtension.lowercased())
    }

    /// The file extension (without leading dot), or an empty string if none.
    var `extension`: String {
        url.pathExtension
    }

    /// Human-readable file size string.
    var formattedSize: String {
        guard let size = size else { return "--" }
        return FileItem.byteCountFormatter.string(fromByteCount: size)
    }

    var formattedPermissions: String {
        let typeChar: Character = isDirectory ? "d" : isSymlink ? "l" : "-"
        let rwx = permissions.unixPermissionString
        let octal = String(permissions, radix: 8)
        return "\(typeChar)\(rwx) (\(octal))"
    }

    var parentPath: String {
        url.deletingLastPathComponent().path
    }

    /// Queries Spotlight for the last-opened date on demand (avoids per-file cost in directory listings).
    var lastOpenedDate: Date? {
        guard let mdItem = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return MDItemCopyAttribute(mdItem, kMDItemLastUsedDate as CFString) as? Date
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

    /// Full initializer with all properties — pure assignment, no resolution logic.
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
        addedDate: Date? = nil,
        kind: String,
        isText: Bool,
        highlightrLanguage: String?,
        iconDescriptor: FileTypeDescriptor,
        iconStyle: IconStyle = .system,
        contentType: String? = nil,
        tags: [String] = [],
        permissions: UInt16 = 0o644,
        isLocked: Bool = false
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
        self.addedDate = addedDate
        self.kind = kind
        self.isText = isText
        self.highlightrLanguage = highlightrLanguage
        self.iconDescriptor = iconDescriptor
        self.iconStyle = iconStyle
        self.contentType = contentType
        self.tags = tags
        self.permissions = permissions
        self.isLocked = isLocked
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
    static func create(from url: URL, iconStyle: IconStyle = .system) -> FileItem? {
        let fileManager = FileManager.default

        let resourceKeys: Set<URLResourceKey> = [
            .nameKey,
            .isDirectoryKey,
            .fileSizeKey,
            .totalFileSizeKey,
            .contentModificationDateKey,
            .creationDateKey,
            .localizedTypeDescriptionKey,
            .isHiddenKey,
            .isSymbolicLinkKey,
            .isPackageKey,
            .contentTypeKey,
            .tagNamesKey,
            .isUserImmutableKey,
            .addedToDirectoryDateKey,
        ]

        guard let resourceValues = try? url.resourceValues(forKeys: resourceKeys) else {
            let name = url.lastPathComponent
            var isDir: ObjCBool = false
            let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDir)
            guard exists else { return nil }

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
                iconStyle: iconStyle,
                tags: [],
                isLocked: false
            )
        }

        let isDirectory = resourceValues.isDirectory ?? false
        let size: Int64? = isDirectory ? nil : Int64(resourceValues.totalFileSize ?? resourceValues.fileSize ?? 0)
        let isLocked = resourceValues.isUserImmutable ?? false

        let resolved = FileTypeResolver.resolve(url: url, isDirectory: isDirectory, systemKind: resourceValues.localizedTypeDescription, iconStyle: iconStyle)
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
            addedDate: resourceValues.addedToDirectoryDate,
            kind: resourceValues.localizedTypeDescription ?? resolved.kind,
            isText: resolved.isText,
            highlightrLanguage: resolved.highlightrLanguage,
            iconDescriptor: resolved.iconDescriptor,
            iconStyle: iconStyle,
            contentType: resourceValues.contentType?.identifier,
            tags: resourceValues.tagNames ?? [],
            isLocked: isLocked
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
        case .dateLastOpened:
            return (lhs.lastOpenedDate ?? .distantPast) < (rhs.lastOpenedDate ?? .distantPast)
        case .dateAdded:
            return (lhs.addedDate ?? .distantPast) < (rhs.addedDate ?? .distantPast)
        case .kind:
            return lhs.kind.localizedStandardCompare(rhs.kind) == .orderedAscending
        case .tags:
            let lhsTag = lhs.tags.first ?? ""
            let rhsTag = rhs.tags.first ?? ""
            return lhsTag.localizedStandardCompare(rhsTag) == .orderedAscending
        }
    }

    // MARK: - Private

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter
    }()

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "svg", "webp", "ico", "icns",
        "tiff", "tif", "bmp", "heic", "heif", "raw", "cr2", "nef", "arw",
    ]

    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "avi", "mkv", "webm", "flv", "wmv",
        "mpg", "mpeg", "ts", "3gp",
    ]

    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "wav", "aac", "flac", "ogg", "wma",
        "aiff", "aif", "opus",
    ]

    private static let markdownExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd",
    ]

    private static let htmlExtensions: Set<String> = [
        "html", "htm",
    ]

    private static let richDocumentExtensions: Set<String> = [
        "docx", "doc", "rtf", "rtfd", "odt",
    ]

    private static let mermaidExtensions: Set<String> = [
        "mermaid", "mmd",
    ]

    private static let archiveExtensions: Set<String> = [
        // ZIP family
        "zip", "cbz",
        // TAR family
        "tar", "tgz", "tbz", "tbz2", "txz", "tlz",
        // Compressed archives
        "gz", "bz2", "xz", "lz", "lzma", "zst", "lz4", "br",
        // Apple/macOS
        "dmg", "pkg", "xip",
        // App bundles as archives
        "ipa", "apk",
        // Java/web
        "jar", "war", "ear",
        // Other
        "7z", "rar", "cab", "iso", "cpio", "rpm", "deb", "ar",
        "cpgz",
    ]
}
