import AppKit
import AVKit

// MARK: - VideoPreviewViewController

/// Displays video and audio files with native playback controls and a collapsible
/// metadata header. Uses AVPlayerView which provides transport controls, scrubbing,
/// volume, fullscreen, and PiP for video, and album art display for audio.
final class VideoPreviewViewController: NSViewController {
    // MARK: - Properties

    private let headerView = PreviewHeaderView()
    private let mediaInfoView = MediaInfoView()
    private var playerView: AVPlayerView!
    private var currentItem: FileItem?
    private var currentLoadTask: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?
    private var appearanceObservation: NSKeyValueObservation?

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()

        configurePlayerView()

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

    private func configurePlayerView() {
        playerView = AVPlayerView()
        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = true

        view.addSubview(playerView)
    }

    private func layoutSubviews() {
        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: view.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            mediaInfoView.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 1),
            mediaInfoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mediaInfoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            playerView.topAnchor.constraint(equalTo: mediaInfoView.bottomAnchor),
            playerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            playerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    // MARK: - Public API

    func displayItem(_ item: FileItem) {
        currentLoadTask?.cancel()
        metadataTask?.cancel()
        playerView.player?.pause()
        currentItem = item
        mediaInfoView.isHidden = true

        headerView.update(with: item)

        let player = AVPlayer(url: item.url)
        playerView.player = player

        metadataTask = Task { [weak self] in
            await self?.loadMetadata(for: item)
        }
    }

    func clear() {
        currentLoadTask?.cancel()
        metadataTask?.cancel()
        playerView.player?.pause()
        playerView.player = nil
        currentItem = nil
        mediaInfoView.isHidden = true
    }

    // MARK: - Metadata

    private func loadMetadata(for item: FileItem) async {
        guard let metadata = await MediaMetadataExtractor.extractVideoMetadata(from: item.url) else {
            return
        }

        guard !Task.isCancelled, currentItem?.url == item.url else { return }

        let infoTitle = metadata.hasVideo ? "Video Info" : "Audio Info"
        let rows = makeInfoRows(from: metadata)
        guard !rows.isEmpty else { return }

        let summary = makeCompactSummary(from: metadata, item: item)
        headerView.setCompactDetail(summary)
        mediaInfoView.update(title: infoTitle, compactSummary: summary, rows: rows)
        mediaInfoView.isHidden = false
    }

    private func makeCompactSummary(from meta: VideoMetadata, item: FileItem) -> String {
        var parts: [String] = []

        if let res = meta.formattedResolution {
            parts.append(res)
        }

        parts.append(meta.formattedDuration)
        parts.append(item.formattedSize)

        return parts.joined(separator: " \u{2014} ")
    }

    private func makeInfoRows(from meta: VideoMetadata) -> [MediaInfoRow] {
        var rows: [MediaInfoRow] = []

        rows.append(MediaInfoRow(label: "Duration", value: meta.formattedDuration))

        if let res = meta.formattedResolution {
            rows.append(MediaInfoRow(label: "Resolution", value: res))
        }

        if let ratio = meta.aspectRatio {
            rows.append(MediaInfoRow(label: "Aspect Ratio", value: ratio))
        }

        if let fps = meta.frameRate, fps > 0 {
            let fpsStr: String
            if fps == fps.rounded() {
                fpsStr = String(format: "%.0f fps", fps)
            } else {
                fpsStr = String(format: "%.3f fps", fps)
            }
            rows.append(MediaInfoRow(label: "Frame Rate", value: fpsStr))
        }

        if let codec = meta.videoCodec {
            var detail = codec
            if let bitrate = meta.videoBitrate, bitrate > 0 {
                detail += " \u{00B7} \(formatBitrate(bitrate))"
            }
            rows.append(MediaInfoRow(label: "Video Codec", value: detail))
        }

        if let codec = meta.audioCodec {
            var detail = codec
            if let bitrate = meta.audioBitrate, bitrate > 0 {
                detail += " \u{00B7} \(formatBitrate(bitrate))"
            }
            rows.append(MediaInfoRow(label: "Audio Codec", value: detail))
        }

        if let rate = meta.sampleRate, rate > 0 {
            let rateStr = rate >= 1000
                ? String(format: "%.1f kHz", rate / 1000.0)
                : String(format: "%.0f Hz", rate)
            rows.append(MediaInfoRow(label: "Sample Rate", value: rateStr))
        }

        if let channels = meta.formattedChannels {
            rows.append(MediaInfoRow(label: "Channels", value: channels))
        }

        if let totalBitrate = meta.totalBitrate, totalBitrate > 0 {
            rows.append(MediaInfoRow(label: "Total Bitrate", value: formatBitrate(totalBitrate)))
        }

        return rows
    }

    private func formatBitrate(_ bps: Double) -> String {
        if bps >= 1_000_000 {
            return String(format: "%.1f Mbps", bps / 1_000_000)
        }
        return String(format: "%.0f kbps", bps / 1_000)
    }
}
