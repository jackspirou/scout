import AppKit
import UniformTypeIdentifiers

// MARK: - FileTypeDescriptor

/// Describes a file type's display properties without resolving an actual icon image.
struct FileTypeDescriptor {
    let kind: String
    let symbolName: String
    let isText: Bool
    let highlightrLanguage: String?
}

// MARK: - ResolvedFileType

/// A fully resolved file type with a concrete icon image.
struct ResolvedFileType {
    let kind: String
    let icon: NSImage
    let isText: Bool
    let highlightrLanguage: String?
    let iconDescriptor: FileTypeDescriptor
}

// MARK: - FileTypeResolver

/// Unified file type resolution system that consolidates icon, kind, and text-detection
/// logic formerly spread across `FileIconProvider` and `TextFilePreviewViewController`.
enum FileTypeResolver {
    // MARK: - Public API

    /// Resolves the file type for the given URL, returning a kind string, icon, and text flag.
    static func resolve(
        url: URL,
        isDirectory: Bool,
        systemKind: String?,
        iconStyle: IconStyle = .system
    ) -> ResolvedFileType {
        if isDirectory {
            let descriptor = FileTypeDescriptor(kind: systemKind ?? "Folder", symbolName: "folder.fill", isText: false, highlightrLanguage: nil)
            let icon = makeIcon(from: descriptor, url: url, isDirectory: true, iconStyle: iconStyle)
            return ResolvedFileType(
                kind: descriptor.kind,
                icon: icon,
                isText: false,
                highlightrLanguage: nil,
                iconDescriptor: descriptor
            )
        }

        let ext = url.pathExtension.lowercased()
        let filename = url.lastPathComponent.lowercased()

        // Check ambiguous extensions first — requires content sniffing.
        if ambiguousExtensions.contains(ext) {
            if let sniffed = sniffContent(at: url, ext: ext) {
                return makeResolved(from: sniffed, url: url, iconStyle: iconStyle)
            }
        }

        // Fast path: extension lookup, then filename lookup.
        if let descriptor = extensionRegistry[ext] ?? filenameRegistry[filename] {
            return makeResolved(from: descriptor, url: url, iconStyle: iconStyle)
        }

        // Fallback: sniff for text content. If the first 512 bytes contain no
        // null bytes and are valid UTF-8, treat as a text file. This catches
        // dotfiles and extensionless files like .zshrc, .bashrc, etc.
        let isText = isLikelyTextFile(at: url)
        let fallbackDescriptor = FileTypeDescriptor(kind: systemKind ?? (isText ? "Plain Text" : "Document"), symbolName: isText ? "doc.text" : "doc", isText: isText, highlightrLanguage: nil)
        return ResolvedFileType(
            kind: fallbackDescriptor.kind,
            icon: NSWorkspace.shared.icon(forFile: url.path),
            isText: isText,
            highlightrLanguage: nil,
            iconDescriptor: fallbackDescriptor
        )
    }

    /// Creates an NSImage from a descriptor, resolving it on demand based on the icon style.
    static func makeIcon(from descriptor: FileTypeDescriptor, url: URL, isDirectory: Bool, iconStyle: IconStyle) -> NSImage {
        switch iconStyle {
        case .system:
            return NSWorkspace.shared.icon(forFile: url.path)
        case .flat:
            if isDirectory {
                return NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Folder")
                    ?? NSWorkspace.shared.icon(forFile: url.path)
            }
            return NSImage(systemSymbolName: descriptor.symbolName, accessibilityDescription: descriptor.kind)
                ?? NSWorkspace.shared.icon(forFile: url.path)
        }
    }

    // MARK: - Private Helpers

    private static func makeResolved(from descriptor: FileTypeDescriptor, url: URL, iconStyle: IconStyle = .system) -> ResolvedFileType {
        let icon = makeIcon(from: descriptor, url: url, isDirectory: false, iconStyle: iconStyle)
        return ResolvedFileType(kind: descriptor.kind, icon: icon, isText: descriptor.isText, highlightrLanguage: descriptor.highlightrLanguage, iconDescriptor: descriptor)
    }

    // MARK: - Text Sniffing

    /// Reads the first 512 bytes and returns true if the content looks like text
    /// (valid UTF-8 with no null bytes). Returns false for empty or unreadable files.
    private static func isLikelyTextFile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        let data = handle.readData(ofLength: 512)
        try? handle.close()

        guard !data.isEmpty else { return false }
        if data.contains(0x00) { return false }
        return String(data: data, encoding: .utf8) != nil
    }

    // MARK: - Ambiguous Extensions

    /// Extensions that require content sniffing to resolve correctly.
    /// Keep this set small — each entry triggers synchronous 512-byte file reads
    /// during directory listing. Only add extensions where the system UTType is
    /// commonly wrong (e.g., .key = Keynote vs SSH key).
    private static let ambiguousExtensions: Set<String> = ["key"]

    private static func sniffContent(at url: URL, ext: String) -> FileTypeDescriptor? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        let data = handle.readData(ofLength: 512)
        try? handle.close()

        switch ext {
        case "key":
            // Keynote files are ZIP archives (PK magic bytes).
            if data.starts(with: [0x50, 0x4B]) {
                return FileTypeDescriptor(kind: "Keynote Presentation", symbolName: "doc.richtext", isText: false, highlightrLanguage: nil)
            }
            // PEM-style text key.
            if let text = String(data: data, encoding: .utf8), text.hasPrefix("-----BEGIN") {
                return FileTypeDescriptor(kind: "PEM Private Key", symbolName: "key", isText: true, highlightrLanguage: nil)
            }
            // No null bytes = likely text.
            if !data.contains(0x00) {
                return FileTypeDescriptor(kind: "Private Key", symbolName: "key", isText: true, highlightrLanguage: nil)
            }
            return FileTypeDescriptor(kind: "Keynote Presentation", symbolName: "doc.richtext", isText: false, highlightrLanguage: nil)
        default:
            return nil
        }
    }

    // MARK: - Extension Registry

    /// Maps lowercase file extensions to their type descriptors.
    private static let extensionRegistry: [String: FileTypeDescriptor] = {
        var map: [String: FileTypeDescriptor] = [:]

        // Swift
        map["swift"] = FileTypeDescriptor(kind: "Swift Source File", symbolName: "swift", isText: true, highlightrLanguage: "swift")

        // Web markup
        for ext in ["html", "htm"] {
            map[ext] = FileTypeDescriptor(kind: "HTML Document", symbolName: "chevron.left.forwardslash.chevron.right", isText: true, highlightrLanguage: "xml")
        }
        map["xml"] = FileTypeDescriptor(kind: "XML Document", symbolName: "chevron.left.forwardslash.chevron.right", isText: true, highlightrLanguage: "xml")

        // Styles
        map["css"] = FileTypeDescriptor(kind: "CSS Stylesheet", symbolName: "paintbrush", isText: true, highlightrLanguage: "css")
        map["scss"] = FileTypeDescriptor(kind: "Stylesheet", symbolName: "paintbrush", isText: true, highlightrLanguage: "scss")
        map["sass"] = FileTypeDescriptor(kind: "Stylesheet", symbolName: "paintbrush", isText: true, highlightrLanguage: "scss")
        map["less"] = FileTypeDescriptor(kind: "Stylesheet", symbolName: "paintbrush", isText: true, highlightrLanguage: "less")

        // JavaScript / TypeScript
        map["js"] = FileTypeDescriptor(kind: "JavaScript Source File", symbolName: "curlybraces", isText: true, highlightrLanguage: "javascript")
        map["jsx"] = FileTypeDescriptor(kind: "JSX Source File", symbolName: "curlybraces", isText: true, highlightrLanguage: "javascript")
        map["ts"] = FileTypeDescriptor(kind: "TypeScript Source File", symbolName: "curlybraces", isText: true, highlightrLanguage: "typescript")
        map["tsx"] = FileTypeDescriptor(kind: "TSX Source File", symbolName: "curlybraces", isText: true, highlightrLanguage: "typescript")

        // Data / Config
        map["json"] = FileTypeDescriptor(kind: "JSON Document", symbolName: "curlybraces", isText: true, highlightrLanguage: "json")
        for ext in ["yaml", "yml"] {
            map[ext] = FileTypeDescriptor(kind: "YAML Document", symbolName: "doc.text", isText: true, highlightrLanguage: "yaml")
        }
        map["toml"] = FileTypeDescriptor(kind: "TOML Document", symbolName: "doc.text", isText: true, highlightrLanguage: "ini")
        map["plist"] = FileTypeDescriptor(kind: "Property List", symbolName: "doc.text", isText: true, highlightrLanguage: "xml")
        map["csv"] = FileTypeDescriptor(kind: "CSV Document", symbolName: "tablecells", isText: true, highlightrLanguage: nil)
        map["tsv"] = FileTypeDescriptor(kind: "TSV Document", symbolName: "tablecells", isText: true, highlightrLanguage: nil)
        for ext in ["ini", "cfg", "conf", "properties"] {
            map[ext] = FileTypeDescriptor(kind: "Configuration File", symbolName: "doc.text", isText: true, highlightrLanguage: "ini")
        }
        map["editorconfig"] = FileTypeDescriptor(kind: "EditorConfig File", symbolName: "doc.text", isText: true, highlightrLanguage: "ini")

        // Programming languages
        map["py"] = FileTypeDescriptor(kind: "Python Source File", symbolName: "chevron.left.forwardslash.chevron.right", isText: true, highlightrLanguage: "python")
        map["rb"] = FileTypeDescriptor(kind: "Ruby Source File", symbolName: "chevron.left.forwardslash.chevron.right", isText: true, highlightrLanguage: "ruby")
        map["go"] = FileTypeDescriptor(kind: "Go Source File", symbolName: "chevron.left.forwardslash.chevron.right", isText: true, highlightrLanguage: "go")
        map["rs"] = FileTypeDescriptor(kind: "Rust Source File", symbolName: "chevron.left.forwardslash.chevron.right", isText: true, highlightrLanguage: "rust")
        map["java"] = FileTypeDescriptor(kind: "Java Source File", symbolName: "cup.and.saucer", isText: true, highlightrLanguage: "java")
        map["kt"] = FileTypeDescriptor(kind: "Kotlin Source File", symbolName: "chevron.left.forwardslash.chevron.right", isText: true, highlightrLanguage: "kotlin")
        map["scala"] = FileTypeDescriptor(kind: "Scala Source File", symbolName: "chevron.left.forwardslash.chevron.right", isText: true, highlightrLanguage: "scala")
        map["c"] = FileTypeDescriptor(kind: "C Source File", symbolName: "chevron.left.forwardslash.chevron.right", isText: true, highlightrLanguage: "c")
        map["h"] = FileTypeDescriptor(kind: "C Header File", symbolName: "chevron.left.forwardslash.chevron.right", isText: true, highlightrLanguage: "c")
        map["cpp"] = FileTypeDescriptor(kind: "C++ Source File", symbolName: "chevron.left.forwardslash.chevron.right", isText: true, highlightrLanguage: "cpp")
        map["hpp"] = FileTypeDescriptor(kind: "C++ Header File", symbolName: "chevron.left.forwardslash.chevron.right", isText: true, highlightrLanguage: "cpp")
        map["m"] = FileTypeDescriptor(kind: "Objective-C Source File", symbolName: "chevron.left.forwardslash.chevron.right", isText: true, highlightrLanguage: "objectivec")
        map["cs"] = FileTypeDescriptor(kind: "C# Source File", symbolName: "chevron.left.forwardslash.chevron.right", isText: true, highlightrLanguage: "csharp")
        map["php"] = FileTypeDescriptor(kind: "PHP Source File", symbolName: "chevron.left.forwardslash.chevron.right", isText: true, highlightrLanguage: "php")
        map["lua"] = FileTypeDescriptor(kind: "Lua Source File", symbolName: "chevron.left.forwardslash.chevron.right", isText: true, highlightrLanguage: "lua")
        map["r"] = FileTypeDescriptor(kind: "R Source File", symbolName: "chevron.left.forwardslash.chevron.right", isText: true, highlightrLanguage: "r")
        map["jl"] = FileTypeDescriptor(kind: "Julia Source File", symbolName: "chevron.left.forwardslash.chevron.right", isText: true, highlightrLanguage: "julia")
        for ext in ["pl", "pm"] {
            map[ext] = FileTypeDescriptor(kind: "Perl Source File", symbolName: "chevron.left.forwardslash.chevron.right", isText: true, highlightrLanguage: "perl")
        }
        for ext in ["ex", "exs"] {
            map[ext] = FileTypeDescriptor(kind: "Elixir Source File", symbolName: "chevron.left.forwardslash.chevron.right", isText: true, highlightrLanguage: nil)
        }
        for ext in ["erl", "hrl"] {
            map[ext] = FileTypeDescriptor(kind: "Erlang Source File", symbolName: "chevron.left.forwardslash.chevron.right", isText: true, highlightrLanguage: "erlang")
        }
        map["zig"] = FileTypeDescriptor(kind: "Zig Source File", symbolName: "chevron.left.forwardslash.chevron.right", isText: true, highlightrLanguage: nil)
        map["v"] = FileTypeDescriptor(kind: "V Source File", symbolName: "chevron.left.forwardslash.chevron.right", isText: true, highlightrLanguage: nil)
        map["nim"] = FileTypeDescriptor(kind: "Nim Source File", symbolName: "chevron.left.forwardslash.chevron.right", isText: true, highlightrLanguage: "nim")
        map["dart"] = FileTypeDescriptor(kind: "Dart Source File", symbolName: "chevron.left.forwardslash.chevron.right", isText: true, highlightrLanguage: "dart")
        map["vue"] = FileTypeDescriptor(kind: "Vue Component", symbolName: "chevron.left.forwardslash.chevron.right", isText: true, highlightrLanguage: "xml")
        map["svelte"] = FileTypeDescriptor(kind: "Svelte Component", symbolName: "chevron.left.forwardslash.chevron.right", isText: true, highlightrLanguage: "xml")

        // Shell scripts
        map["sh"] = FileTypeDescriptor(kind: "Shell Script", symbolName: "terminal", isText: true, highlightrLanguage: "bash")
        map["bash"] = FileTypeDescriptor(kind: "Bash Script", symbolName: "terminal", isText: true, highlightrLanguage: "bash")
        map["zsh"] = FileTypeDescriptor(kind: "Zsh Script", symbolName: "terminal", isText: true, highlightrLanguage: "bash")
        map["fish"] = FileTypeDescriptor(kind: "Fish Script", symbolName: "terminal", isText: true, highlightrLanguage: "bash")
        for ext in ["bat", "cmd"] {
            map[ext] = FileTypeDescriptor(kind: "Batch File", symbolName: "terminal", isText: true, highlightrLanguage: "dos")
        }
        map["ps1"] = FileTypeDescriptor(kind: "PowerShell Script", symbolName: "terminal", isText: true, highlightrLanguage: "powershell")

        // Build tools
        map["cmake"] = FileTypeDescriptor(kind: "CMake File", symbolName: "hammer", isText: true, highlightrLanguage: "cmake")

        // Containers (also in filenameRegistry for extensionless matches)
        map["dockerfile"] = FileTypeDescriptor(kind: "Dockerfile", symbolName: "shippingbox", isText: true, highlightrLanguage: "dockerfile")
        map["containerfile"] = FileTypeDescriptor(kind: "Containerfile", symbolName: "shippingbox", isText: true, highlightrLanguage: "dockerfile")

        // Markdown / Docs
        for ext in ["md", "markdown"] {
            map[ext] = FileTypeDescriptor(kind: "Markdown Document", symbolName: "doc.richtext", isText: true, highlightrLanguage: "markdown")
        }
        for ext in ["mermaid", "mmd"] {
            map[ext] = FileTypeDescriptor(kind: "Mermaid Diagram", symbolName: "diagram", isText: true, highlightrLanguage: nil)
        }
        map["rst"] = FileTypeDescriptor(kind: "reStructuredText Document", symbolName: "doc.richtext", isText: true, highlightrLanguage: nil)
        map["rtf"] = FileTypeDescriptor(kind: "Rich Text Document", symbolName: "doc.richtext", isText: true, highlightrLanguage: nil)
        map["tex"] = FileTypeDescriptor(kind: "LaTeX Document", symbolName: "doc.richtext", isText: true, highlightrLanguage: "latex")
        map["txt"] = FileTypeDescriptor(kind: "Plain Text Document", symbolName: "doc.plaintext", isText: true, highlightrLanguage: nil)
        map["log"] = FileTypeDescriptor(kind: "Log File", symbolName: "doc.text", isText: true, highlightrLanguage: nil)

        // Images
        map["png"] = FileTypeDescriptor(kind: "PNG Image", symbolName: "photo", isText: false, highlightrLanguage: nil)
        map["jpg"] = FileTypeDescriptor(kind: "JPEG Image", symbolName: "photo", isText: false, highlightrLanguage: nil)
        map["jpeg"] = FileTypeDescriptor(kind: "JPEG Image", symbolName: "photo", isText: false, highlightrLanguage: nil)
        map["gif"] = FileTypeDescriptor(kind: "GIF Image", symbolName: "photo", isText: false, highlightrLanguage: nil)
        map["svg"] = FileTypeDescriptor(kind: "SVG Image", symbolName: "photo", isText: true, highlightrLanguage: nil)
        map["webp"] = FileTypeDescriptor(kind: "WebP Image", symbolName: "photo", isText: false, highlightrLanguage: nil)
        map["ico"] = FileTypeDescriptor(kind: "ICO Image", symbolName: "photo", isText: false, highlightrLanguage: nil)
        map["icns"] = FileTypeDescriptor(kind: "ICNS Image", symbolName: "photo", isText: false, highlightrLanguage: nil)
        map["tiff"] = FileTypeDescriptor(kind: "TIFF Image", symbolName: "photo", isText: false, highlightrLanguage: nil)
        map["bmp"] = FileTypeDescriptor(kind: "BMP Image", symbolName: "photo", isText: false, highlightrLanguage: nil)
        map["heic"] = FileTypeDescriptor(kind: "HEIC Image", symbolName: "photo", isText: false, highlightrLanguage: nil)

        // Video
        map["mp4"] = FileTypeDescriptor(kind: "MP4 Video", symbolName: "play.rectangle.fill", isText: false, highlightrLanguage: nil)
        map["mov"] = FileTypeDescriptor(kind: "QuickTime Movie", symbolName: "play.rectangle.fill", isText: false, highlightrLanguage: nil)
        map["m4v"] = FileTypeDescriptor(kind: "M4V Video", symbolName: "play.rectangle.fill", isText: false, highlightrLanguage: nil)
        map["avi"] = FileTypeDescriptor(kind: "AVI Video", symbolName: "play.rectangle.fill", isText: false, highlightrLanguage: nil)
        map["mkv"] = FileTypeDescriptor(kind: "Matroska Video", symbolName: "play.rectangle.fill", isText: false, highlightrLanguage: nil)
        map["webm"] = FileTypeDescriptor(kind: "WebM Video", symbolName: "play.rectangle.fill", isText: false, highlightrLanguage: nil)
        map["flv"] = FileTypeDescriptor(kind: "Flash Video", symbolName: "play.rectangle.fill", isText: false, highlightrLanguage: nil)
        map["wmv"] = FileTypeDescriptor(kind: "Windows Media Video", symbolName: "play.rectangle.fill", isText: false, highlightrLanguage: nil)
        map["mpg"] = FileTypeDescriptor(kind: "MPEG Video", symbolName: "play.rectangle.fill", isText: false, highlightrLanguage: nil)
        map["mpeg"] = FileTypeDescriptor(kind: "MPEG Video", symbolName: "play.rectangle.fill", isText: false, highlightrLanguage: nil)
        map["ts"] = FileTypeDescriptor(kind: "MPEG Transport Stream", symbolName: "play.rectangle.fill", isText: false, highlightrLanguage: nil)
        map["3gp"] = FileTypeDescriptor(kind: "3GPP Video", symbolName: "play.rectangle.fill", isText: false, highlightrLanguage: nil)

        // Audio
        map["mp3"] = FileTypeDescriptor(kind: "MP3 Audio", symbolName: "waveform", isText: false, highlightrLanguage: nil)
        map["m4a"] = FileTypeDescriptor(kind: "M4A Audio", symbolName: "waveform", isText: false, highlightrLanguage: nil)
        map["wav"] = FileTypeDescriptor(kind: "WAV Audio", symbolName: "waveform", isText: false, highlightrLanguage: nil)
        map["aac"] = FileTypeDescriptor(kind: "AAC Audio", symbolName: "waveform", isText: false, highlightrLanguage: nil)
        map["flac"] = FileTypeDescriptor(kind: "FLAC Audio", symbolName: "waveform", isText: false, highlightrLanguage: nil)
        map["ogg"] = FileTypeDescriptor(kind: "Ogg Audio", symbolName: "waveform", isText: false, highlightrLanguage: nil)
        map["wma"] = FileTypeDescriptor(kind: "Windows Media Audio", symbolName: "waveform", isText: false, highlightrLanguage: nil)
        map["aiff"] = FileTypeDescriptor(kind: "AIFF Audio", symbolName: "waveform", isText: false, highlightrLanguage: nil)
        map["aif"] = FileTypeDescriptor(kind: "AIFF Audio", symbolName: "waveform", isText: false, highlightrLanguage: nil)
        map["opus"] = FileTypeDescriptor(kind: "Opus Audio", symbolName: "waveform", isText: false, highlightrLanguage: nil)

        // Archives
        map["zip"] = FileTypeDescriptor(kind: "ZIP Archive", symbolName: "doc.zipper", isText: false, highlightrLanguage: nil)
        map["tar"] = FileTypeDescriptor(kind: "TAR Archive", symbolName: "doc.zipper", isText: false, highlightrLanguage: nil)
        map["gz"] = FileTypeDescriptor(kind: "GZip Archive", symbolName: "doc.zipper", isText: false, highlightrLanguage: nil)
        map["bz2"] = FileTypeDescriptor(kind: "BZip2 Archive", symbolName: "doc.zipper", isText: false, highlightrLanguage: nil)
        map["xz"] = FileTypeDescriptor(kind: "XZ Archive", symbolName: "doc.zipper", isText: false, highlightrLanguage: nil)
        map["rar"] = FileTypeDescriptor(kind: "RAR Archive", symbolName: "doc.zipper", isText: false, highlightrLanguage: nil)
        map["7z"] = FileTypeDescriptor(kind: "7-Zip Archive", symbolName: "doc.zipper", isText: false, highlightrLanguage: nil)

        // Disk images
        map["dmg"] = FileTypeDescriptor(kind: "Disk Image", symbolName: "externaldrive", isText: false, highlightrLanguage: nil)

        // Git
        map["gitignore"] = FileTypeDescriptor(kind: "Git Ignore", symbolName: "eye.slash", isText: true, highlightrLanguage: "bash")
        map["gitattributes"] = FileTypeDescriptor(kind: "Git Attributes", symbolName: "doc.text", isText: true, highlightrLanguage: "bash")
        map["gitmodules"] = FileTypeDescriptor(kind: "Git Modules", symbolName: "doc.text", isText: true, highlightrLanguage: "bash")

        // Environment
        map["env"] = FileTypeDescriptor(kind: "Environment File", symbolName: "lock", isText: true, highlightrLanguage: "bash")

        // Lock files
        map["lock"] = FileTypeDescriptor(kind: "Lock File", symbolName: "lock", isText: true, highlightrLanguage: nil)
        map["resolved"] = FileTypeDescriptor(kind: "Lock File", symbolName: "lock", isText: true, highlightrLanguage: nil)

        // PDF
        map["pdf"] = FileTypeDescriptor(kind: "PDF Document", symbolName: "doc.richtext", isText: false, highlightrLanguage: nil)

        // Databases
        map["sql"] = FileTypeDescriptor(kind: "SQL File", symbolName: "cylinder", isText: true, highlightrLanguage: "sql")
        for ext in ["graphql", "gql"] {
            map[ext] = FileTypeDescriptor(kind: "GraphQL File", symbolName: "cylinder", isText: true, highlightrLanguage: "graphql")
        }
        for ext in ["sqlite", "db"] {
            map[ext] = FileTypeDescriptor(kind: "Database", symbolName: "cylinder", isText: false, highlightrLanguage: nil)
        }

        // Fonts
        for ext in ["ttf", "otf", "woff", "woff2"] {
            map[ext] = FileTypeDescriptor(kind: "Font File", symbolName: "textformat", isText: false, highlightrLanguage: nil)
        }

        // Crypto / keys
        map["pem"] = FileTypeDescriptor(kind: "PEM Certificate", symbolName: "key", isText: true, highlightrLanguage: nil)
        map["pub"] = FileTypeDescriptor(kind: "Public Key", symbolName: "key", isText: true, highlightrLanguage: nil)
        for ext in ["crt", "cer"] {
            map[ext] = FileTypeDescriptor(kind: "Certificate", symbolName: "key", isText: true, highlightrLanguage: nil)
        }
        map["csr"] = FileTypeDescriptor(kind: "Certificate Request", symbolName: "key", isText: true, highlightrLanguage: nil)

        // Infrastructure
        for ext in ["tf", "hcl"] {
            map[ext] = FileTypeDescriptor(kind: "Terraform File", symbolName: "doc.text", isText: true, highlightrLanguage: nil)
        }
        map["nix"] = FileTypeDescriptor(kind: "Nix File", symbolName: "doc.text", isText: true, highlightrLanguage: "nix")
        map["dhall"] = FileTypeDescriptor(kind: "Dhall File", symbolName: "doc.text", isText: true, highlightrLanguage: nil)

        // Schema / Protocol
        map["proto"] = FileTypeDescriptor(kind: "Protocol Buffer", symbolName: "doc.text", isText: true, highlightrLanguage: "protobuf")
        map["thrift"] = FileTypeDescriptor(kind: "Thrift File", symbolName: "doc.text", isText: true, highlightrLanguage: "thrift")
        map["avsc"] = FileTypeDescriptor(kind: "Avro Schema", symbolName: "doc.text", isText: true, highlightrLanguage: "json")

        // Go modules
        map["mod"] = FileTypeDescriptor(kind: "Go Module", symbolName: "doc.text", isText: true, highlightrLanguage: nil)
        map["sum"] = FileTypeDescriptor(kind: "Go Checksum", symbolName: "doc.text", isText: true, highlightrLanguage: nil)

        // Gradle / Kotlin
        map["gradle"] = FileTypeDescriptor(kind: "Gradle Build File", symbolName: "hammer", isText: true, highlightrLanguage: "gradle")
        map["kts"] = FileTypeDescriptor(kind: "Kotlin Script", symbolName: "chevron.left.forwardslash.chevron.right", isText: true, highlightrLanguage: "kotlin")

        // Apple-specific
        map["entitlements"] = FileTypeDescriptor(kind: "Entitlements", symbolName: "lock.shield", isText: true, highlightrLanguage: "xml")
        map["xcconfig"] = FileTypeDescriptor(kind: "Xcode Configuration", symbolName: "gearshape", isText: true, highlightrLanguage: "xml")
        map["strings"] = FileTypeDescriptor(kind: "Strings File", symbolName: "character.bubble", isText: true, highlightrLanguage: "xml")
        map["stringsdict"] = FileTypeDescriptor(kind: "Strings Dictionary", symbolName: "character.bubble", isText: true, highlightrLanguage: "xml")
        map["storyboard"] = FileTypeDescriptor(kind: "Storyboard", symbolName: "rectangle.on.rectangle", isText: true, highlightrLanguage: "xml")
        map["xib"] = FileTypeDescriptor(kind: "Interface Builder", symbolName: "rectangle.on.rectangle", isText: true, highlightrLanguage: "xml")
        map["pbxproj"] = FileTypeDescriptor(kind: "Xcode Project", symbolName: "hammer", isText: true, highlightrLanguage: "xml")
        map["xcscheme"] = FileTypeDescriptor(kind: "Xcode Scheme", symbolName: "gearshape", isText: true, highlightrLanguage: "xml")
        map["swiftinterface"] = FileTypeDescriptor(kind: "Swift Interface", symbolName: "swift", isText: true, highlightrLanguage: "swift")

        // Office documents
        map["docx"] = FileTypeDescriptor(kind: "Word Document", symbolName: "doc.fill", isText: false, highlightrLanguage: nil)
        map["xlsx"] = FileTypeDescriptor(kind: "Excel Spreadsheet", symbolName: "tablecells.fill", isText: false, highlightrLanguage: nil)
        map["pptx"] = FileTypeDescriptor(kind: "PowerPoint Presentation", symbolName: "rectangle.fill.on.rectangle.fill", isText: false, highlightrLanguage: nil)
        map["doc"] = FileTypeDescriptor(kind: "Word Document", symbolName: "doc.fill", isText: false, highlightrLanguage: nil)
        map["xls"] = FileTypeDescriptor(kind: "Excel Spreadsheet", symbolName: "tablecells.fill", isText: false, highlightrLanguage: nil)
        map["ppt"] = FileTypeDescriptor(kind: "PowerPoint Presentation", symbolName: "rectangle.fill.on.rectangle.fill", isText: false, highlightrLanguage: nil)

        // Source maps
        map["map"] = FileTypeDescriptor(kind: "Source Map", symbolName: "doc.text", isText: true, highlightrLanguage: "json")

        // Web3 / Blockchain
        map["sol"] = FileTypeDescriptor(kind: "Solidity Source File", symbolName: "chevron.left.forwardslash.chevron.right", isText: true, highlightrLanguage: nil)
        map["prisma"] = FileTypeDescriptor(kind: "Prisma Schema", symbolName: "doc.text", isText: true, highlightrLanguage: nil)
        map["wasm"] = FileTypeDescriptor(kind: "WebAssembly Binary", symbolName: "cpu", isText: false, highlightrLanguage: nil)

        // Misc
        map["jsonc"] = FileTypeDescriptor(kind: "JSON with Comments", symbolName: "curlybraces", isText: true, highlightrLanguage: "json")
        map["cjs"] = FileTypeDescriptor(kind: "CommonJS Module", symbolName: "curlybraces", isText: true, highlightrLanguage: "javascript")
        map["mjs"] = FileTypeDescriptor(kind: "ES Module", symbolName: "curlybraces", isText: true, highlightrLanguage: "javascript")

        return map
    }()

    // MARK: - Filename Registry

    /// Maps lowercase filenames (extensionless files and dotfiles) to their type descriptors.
    private static let filenameRegistry: [String: FileTypeDescriptor] = [
        // Build / containers
        "makefile": FileTypeDescriptor(kind: "Makefile", symbolName: "hammer", isText: true, highlightrLanguage: "makefile"),
        "dockerfile": FileTypeDescriptor(kind: "Dockerfile", symbolName: "shippingbox", isText: true, highlightrLanguage: "dockerfile"),
        "containerfile": FileTypeDescriptor(kind: "Containerfile", symbolName: "shippingbox", isText: true, highlightrLanguage: "dockerfile"),

        // Project files
        "license": FileTypeDescriptor(kind: "License", symbolName: "doc.text", isText: true, highlightrLanguage: nil),
        "readme": FileTypeDescriptor(kind: "Readme", symbolName: "doc.richtext", isText: true, highlightrLanguage: nil),
        "changelog": FileTypeDescriptor(kind: "Changelog", symbolName: "doc.text", isText: true, highlightrLanguage: nil),
        "authors": FileTypeDescriptor(kind: "Authors", symbolName: "doc.text", isText: true, highlightrLanguage: nil),

        // Ruby
        "gemfile": FileTypeDescriptor(kind: "Gemfile", symbolName: "doc.text", isText: true, highlightrLanguage: "ruby"),
        "rakefile": FileTypeDescriptor(kind: "Rakefile", symbolName: "hammer", isText: true, highlightrLanguage: "ruby"),

        // Other build/task files
        "procfile": FileTypeDescriptor(kind: "Procfile", symbolName: "terminal", isText: true, highlightrLanguage: "bash"),
        "brewfile": FileTypeDescriptor(kind: "Brewfile", symbolName: "doc.text", isText: true, highlightrLanguage: "ruby"),
        "vagrantfile": FileTypeDescriptor(kind: "Vagrantfile", symbolName: "shippingbox", isText: true, highlightrLanguage: "ruby"),
        "justfile": FileTypeDescriptor(kind: "Justfile", symbolName: "hammer", isText: true, highlightrLanguage: "makefile"),
        "taskfile": FileTypeDescriptor(kind: "Taskfile", symbolName: "hammer", isText: true, highlightrLanguage: "yaml"),
        "jenkinsfile": FileTypeDescriptor(kind: "Jenkinsfile", symbolName: "hammer", isText: true, highlightrLanguage: "groovy"),
        "pipfile": FileTypeDescriptor(kind: "Pipfile", symbolName: "doc.text", isText: true, highlightrLanguage: "ini"),

        // Dotfiles (config)
        ".gitignore": FileTypeDescriptor(kind: "Git Ignore", symbolName: "eye.slash", isText: true, highlightrLanguage: "bash"),
        ".gitkeep": FileTypeDescriptor(kind: "Git Keep", symbolName: "doc.text", isText: true, highlightrLanguage: "bash"),
        ".gitattributes": FileTypeDescriptor(kind: "Git Attributes", symbolName: "doc.text", isText: true, highlightrLanguage: "bash"),
        ".gitmodules": FileTypeDescriptor(kind: "Git Modules", symbolName: "doc.text", isText: true, highlightrLanguage: "bash"),
        ".dockerignore": FileTypeDescriptor(kind: "Docker Ignore", symbolName: "eye.slash", isText: true, highlightrLanguage: "bash"),
        ".editorconfig": FileTypeDescriptor(kind: "EditorConfig", symbolName: "doc.text", isText: true, highlightrLanguage: "ini"),
        ".env": FileTypeDescriptor(kind: "Environment File", symbolName: "lock", isText: true, highlightrLanguage: "bash"),
        ".env.local": FileTypeDescriptor(kind: "Environment File", symbolName: "lock", isText: true, highlightrLanguage: "bash"),
        ".env.development": FileTypeDescriptor(kind: "Environment File", symbolName: "lock", isText: true, highlightrLanguage: "bash"),
        ".env.production": FileTypeDescriptor(kind: "Environment File", symbolName: "lock", isText: true, highlightrLanguage: "bash"),

        // JS/Node dotfiles
        ".prettierrc": FileTypeDescriptor(kind: "Prettier Config", symbolName: "doc.text", isText: true, highlightrLanguage: "json"),
        ".eslintrc": FileTypeDescriptor(kind: "ESLint Config", symbolName: "doc.text", isText: true, highlightrLanguage: "json"),
        ".babelrc": FileTypeDescriptor(kind: "Babel Config", symbolName: "doc.text", isText: true, highlightrLanguage: "json"),
        ".npmrc": FileTypeDescriptor(kind: "npm Config", symbolName: "doc.text", isText: true, highlightrLanguage: nil),
        ".nvmrc": FileTypeDescriptor(kind: "Node Version", symbolName: "doc.text", isText: true, highlightrLanguage: nil),
        ".node-version": FileTypeDescriptor(kind: "Node Version", symbolName: "doc.text", isText: true, highlightrLanguage: nil),
        ".browserslistrc": FileTypeDescriptor(kind: "Browserslist Config", symbolName: "doc.text", isText: true, highlightrLanguage: nil),

        // Language version dotfiles
        ".ruby-version": FileTypeDescriptor(kind: "Ruby Version", symbolName: "doc.text", isText: true, highlightrLanguage: nil),
        ".python-version": FileTypeDescriptor(kind: "Python Version", symbolName: "doc.text", isText: true, highlightrLanguage: nil),
        ".tool-versions": FileTypeDescriptor(kind: "Tool Versions", symbolName: "doc.text", isText: true, highlightrLanguage: nil),

        // Swift/Apple dotfiles
        ".swiftformat": FileTypeDescriptor(kind: "SwiftFormat Config", symbolName: "doc.text", isText: true, highlightrLanguage: nil),
    ]
}
