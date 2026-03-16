import AppKit
import PDFKit

// MARK: - PDFPreviewViewController

/// Displays a PDF file with a collapsible metadata header and a native PDFView.
/// Supports zoom, scrolling, text selection, and search via PDFKit.
final class PDFPreviewViewController: NSViewController, PreviewChild {
    // MARK: - Properties

    private let headerView = PreviewHeaderView()
    private let mediaInfoView = MediaInfoView()
    private var pdfView: PDFView!
    private var currentItem: FileItem?
    private var currentLoadTask: Task<Void, Never>?
    private var appearanceObservation: NSKeyValueObservation?

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()

        configurePDFView()

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

    private func configurePDFView() {
        pdfView = PDFView()
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = .textBackgroundColor

        view.addSubview(pdfView)
    }

    private func layoutSubviews() {
        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: view.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            mediaInfoView.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 1),
            mediaInfoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mediaInfoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            pdfView.topAnchor.constraint(equalTo: mediaInfoView.bottomAnchor),
            pdfView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            pdfView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    // MARK: - Public API

    func displayItem(_ item: FileItem) {
        currentLoadTask?.cancel()
        currentItem = item
        mediaInfoView.isHidden = true

        headerView.update(with: item)

        currentLoadTask = Task { [weak self] in
            await self?.loadPDF(item: item)
        }
    }

    func clear() {
        currentLoadTask?.cancel()
        currentItem = nil
        pdfView.document = nil
        mediaInfoView.isHidden = true
    }

    // MARK: - Private

    private func loadPDF(item: FileItem) async {
        let document = await Task.detached {
            PDFDocument(url: item.url)
        }.value

        guard !Task.isCancelled, currentItem?.url == item.url else { return }

        guard let document else {
            pdfView.document = nil
            return
        }

        pdfView.document = document

        let pageCount = document.pageCount
        let detail = "\(pageCount) page\(pageCount == 1 ? "" : "s") — \(item.formattedSize)"
        headerView.setCompactDetail(detail)

        let rows = makeInfoRows(from: document)
        guard !rows.isEmpty else { return }

        let summary = makeCompactSummary(from: document)
        mediaInfoView.update(title: "PDF Info", compactSummary: summary, rows: rows)
        mediaInfoView.isHidden = false
    }

    // MARK: - Metadata

    private func makeCompactSummary(from document: PDFDocument) -> String {
        var parts: [String] = []

        parts.append("\(document.pageCount) page\(document.pageCount == 1 ? "" : "s")")

        if let page = document.page(at: 0) {
            let bounds = page.bounds(for: .mediaBox)
            let w = Int(round(bounds.width * 72.0 / 72.0))
            let h = Int(round(bounds.height * 72.0 / 72.0))
            parts.append("\(w) \u{00D7} \(h) pt")
        }

        if let attrs = document.documentAttributes,
           let author = attrs[PDFDocumentAttribute.authorAttribute] as? String,
           !author.isEmpty {
            parts.append(author)
        }

        return parts.joined(separator: " \u{00B7} ")
    }

    private func makeInfoRows(from document: PDFDocument) -> [MediaInfoRow] {
        var rows: [MediaInfoRow] = []
        let attrs = document.documentAttributes ?? [:]

        rows.append(MediaInfoRow(label: "Pages", value: "\(document.pageCount)"))

        if let page = document.page(at: 0) {
            let bounds = page.bounds(for: .mediaBox)
            let wPt = bounds.width
            let hPt = bounds.height
            // Convert points to inches and mm for display
            let wIn = wPt / 72.0
            let hIn = hPt / 72.0
            let wMm = wIn * 25.4
            let hMm = hIn * 25.4
            let sizeStr = String(format: "%.0f \u{00D7} %.0f pt (%.1f \u{00D7} %.1f in / %.0f \u{00D7} %.0f mm)",
                                 wPt, hPt, wIn, hIn, wMm, hMm)
            rows.append(MediaInfoRow(label: "Page Size", value: sizeStr))

            let pageName = standardPageName(widthPt: wPt, heightPt: hPt)
            if let pageName {
                rows.append(MediaInfoRow(label: "Format", value: pageName))
            }
        }

        if let title = attrs[PDFDocumentAttribute.titleAttribute] as? String, !title.isEmpty {
            rows.append(MediaInfoRow(label: "Title", value: title))
        }

        if let author = attrs[PDFDocumentAttribute.authorAttribute] as? String, !author.isEmpty {
            rows.append(MediaInfoRow(label: "Author", value: author))
        }

        if let subject = attrs[PDFDocumentAttribute.subjectAttribute] as? String, !subject.isEmpty {
            rows.append(MediaInfoRow(label: "Subject", value: subject))
        }

        if let creator = attrs[PDFDocumentAttribute.creatorAttribute] as? String, !creator.isEmpty {
            rows.append(MediaInfoRow(label: "Creator", value: creator))
        }

        if let producer = attrs[PDFDocumentAttribute.producerAttribute] as? String, !producer.isEmpty {
            rows.append(MediaInfoRow(label: "Producer", value: producer))
        }

        if let keywords = attrs[PDFDocumentAttribute.keywordsAttribute] as? [String], !keywords.isEmpty {
            rows.append(MediaInfoRow(label: "Keywords", value: keywords.joined(separator: ", ")))
        }

        if let creationDate = attrs[PDFDocumentAttribute.creationDateAttribute] as? Date {
            rows.append(MediaInfoRow(label: "Created", value: creationDate.fullFormatted))
        }

        if let modDate = attrs[PDFDocumentAttribute.modificationDateAttribute] as? Date {
            rows.append(MediaInfoRow(label: "Modified", value: modDate.fullFormatted))
        }

        if document.isEncrypted {
            rows.append(MediaInfoRow(label: "Encrypted", value: "Yes"))
        }

        // PDF version from the document's major/minor version
        let major = document.majorVersion
        let minor = document.minorVersion
        if major > 0 {
            rows.append(MediaInfoRow(label: "PDF Version", value: "\(major).\(minor)"))
        }

        return rows
    }

    /// Matches common page dimensions (within 2pt tolerance) to standard names.
    private func standardPageName(widthPt: CGFloat, heightPt: CGFloat) -> String? {
        // Normalize to portrait orientation for matching.
        let w = min(widthPt, heightPt)
        let h = max(widthPt, heightPt)
        let tolerance: CGFloat = 2.0

        let standards: [(String, CGFloat, CGFloat)] = [
            ("Letter", 612, 792),
            ("Legal", 612, 1008),
            ("Tabloid", 792, 1224),
            ("A3", 841.89, 1190.55),
            ("A4", 595.28, 841.89),
            ("A5", 419.53, 595.28),
            ("B5", 498.90, 708.66),
        ]

        for (name, sw, sh) in standards {
            if abs(w - sw) < tolerance, abs(h - sh) < tolerance {
                let orientation = widthPt > heightPt ? "Landscape" : "Portrait"
                return "\(name) (\(orientation))"
            }
        }

        return nil
    }
}
