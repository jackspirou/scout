import AppKit
import AVFoundation

// MARK: - AudioPreviewViewController

/// Displays audio files with album art, waveform visualization, and custom
/// transport controls. Shows rich metadata from ID3/iTunes tags.
/// The player content (art, waveform, controls) is vertically centered
/// in the available space below the header and metadata sections.
final class AudioPreviewViewController: NSViewController, PreviewChild {
    // MARK: - Properties

    private let headerView = PreviewHeaderView()
    private let mediaInfoView = MediaInfoView()

    /// Container for the player UI (album art + waveform + transport),
    /// vertically centered in the space below the header/metadata.
    private var playerContentView: NSView!
    private var albumArtView: NSImageView!

    // Waveform views — user can toggle between static and realtime
    private var waveformContainerView: NSView!
    private var waveformView: WaveformView!
    private var realtimeWaveView: RealtimeWaveView!
    private var showingRealtimeWave = true
    private let audioLevelTap = AudioLevelTap()

    private var transportView: NSView!

    private var playPauseButton: NSButton!
    private var waveformToggleButton: NSButton!
    private var timeSlider: NSSlider!
    private var currentTimeLabel: NSTextField!
    private var totalTimeLabel: NSTextField!

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var currentItem: FileItem?
    private var metadataTask: Task<Void, Never>?
    private var waveformTask: Task<Void, Never>?
    private var appearanceObservation: NSKeyValueObservation?

    private var duration: TimeInterval = 0
    private var isSeeking = false

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()

        configurePlayerContent()

        mediaInfoView.isHidden = true

        view.addSubview(headerView)
        view.addSubview(mediaInfoView)
        view.addSubview(playerContentView)

        layoutSubviews()

        appearanceObservation = view.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            self?.headerView.updateAppearance()
            self?.mediaInfoView.updateAppearance()
        }
    }

    deinit {
        stopPlayback()
    }

    // MARK: - Configuration

    private func configurePlayerContent() {
        playerContentView = NSView()
        playerContentView.translatesAutoresizingMaskIntoConstraints = false

        configureAlbumArt()
        configureWaveform()
        configureTransport()

        NSLayoutConstraint.activate([
            albumArtView.topAnchor.constraint(equalTo: playerContentView.topAnchor),
            albumArtView.centerXAnchor.constraint(equalTo: playerContentView.centerXAnchor),
            albumArtView.leadingAnchor.constraint(greaterThanOrEqualTo: playerContentView.leadingAnchor, constant: 20),
            albumArtView.trailingAnchor.constraint(lessThanOrEqualTo: playerContentView.trailingAnchor, constant: -20),

            waveformContainerView.topAnchor.constraint(equalTo: albumArtView.bottomAnchor, constant: 16),
            waveformContainerView.leadingAnchor.constraint(equalTo: playerContentView.leadingAnchor, constant: 12),
            waveformContainerView.trailingAnchor.constraint(equalTo: playerContentView.trailingAnchor, constant: -12),
            waveformContainerView.heightAnchor.constraint(equalToConstant: 120),

            transportView.topAnchor.constraint(equalTo: waveformContainerView.bottomAnchor, constant: 8),
            transportView.leadingAnchor.constraint(equalTo: playerContentView.leadingAnchor),
            transportView.trailingAnchor.constraint(equalTo: playerContentView.trailingAnchor),
            transportView.heightAnchor.constraint(equalToConstant: 32),
            transportView.bottomAnchor.constraint(equalTo: playerContentView.bottomAnchor),
        ])
    }

    private func configureAlbumArt() {
        albumArtView = NSImageView()
        albumArtView.translatesAutoresizingMaskIntoConstraints = false
        albumArtView.imageScaling = .scaleProportionallyUpOrDown
        albumArtView.wantsLayer = true
        albumArtView.layer?.cornerRadius = 8
        albumArtView.layer?.masksToBounds = true
        albumArtView.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor

        // Square aspect ratio with preferred 200x200 that can shrink
        let preferredWidth = albumArtView.widthAnchor.constraint(equalToConstant: 200)
        preferredWidth.priority = .defaultHigh
        let preferredHeight = albumArtView.heightAnchor.constraint(equalToConstant: 200)
        preferredHeight.priority = .defaultHigh

        NSLayoutConstraint.activate([
            albumArtView.widthAnchor.constraint(equalTo: albumArtView.heightAnchor),
            albumArtView.widthAnchor.constraint(lessThanOrEqualToConstant: 200),
            albumArtView.heightAnchor.constraint(lessThanOrEqualToConstant: 200),
            preferredWidth,
            preferredHeight,
        ])

        playerContentView.addSubview(albumArtView)
    }

    private func configureWaveform() {
        waveformContainerView = NSView()
        waveformContainerView.translatesAutoresizingMaskIntoConstraints = false

        waveformView = WaveformView()
        waveformView.translatesAutoresizingMaskIntoConstraints = false
        waveformView.onSeek = { [weak self] position in
            self?.seekTo(position: position)
        }

        realtimeWaveView = RealtimeWaveView()
        realtimeWaveView.translatesAutoresizingMaskIntoConstraints = false
        realtimeWaveView.isHidden = false
        realtimeWaveView.onTap = { [weak self] in
            self?.toggleWaveformMode()
        }

        waveformContainerView.addSubview(waveformView)
        waveformContainerView.addSubview(realtimeWaveView)

        // Both waveform views fill the container
        for wv in [waveformView!, realtimeWaveView!] {
            NSLayoutConstraint.activate([
                wv.topAnchor.constraint(equalTo: waveformContainerView.topAnchor),
                wv.bottomAnchor.constraint(equalTo: waveformContainerView.bottomAnchor),
                wv.leadingAnchor.constraint(equalTo: waveformContainerView.leadingAnchor),
                wv.trailingAnchor.constraint(equalTo: waveformContainerView.trailingAnchor),
            ])
        }

        playerContentView.addSubview(waveformContainerView)
    }

    private func configureTransport() {
        transportView = NSView()
        transportView.translatesAutoresizingMaskIntoConstraints = false

        // Play/Pause button
        playPauseButton = NSButton(
            image: NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")!,
            target: self, action: #selector(togglePlayPause)
        )
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false
        playPauseButton.bezelStyle = .inline
        playPauseButton.isBordered = false
        playPauseButton.imagePosition = .imageOnly
        playPauseButton.symbolConfiguration = .init(pointSize: 16, weight: .medium)

        // Time slider (scrubber)
        timeSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: self, action: #selector(sliderChanged(_:)))
        timeSlider.translatesAutoresizingMaskIntoConstraints = false
        timeSlider.isContinuous = true

        // Current time label
        currentTimeLabel = NSTextField(labelWithString: "0:00")
        currentTimeLabel.translatesAutoresizingMaskIntoConstraints = false
        currentTimeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        currentTimeLabel.textColor = .secondaryLabelColor
        currentTimeLabel.alignment = .right

        // Total time label
        totalTimeLabel = NSTextField(labelWithString: "0:00")
        totalTimeLabel.translatesAutoresizingMaskIntoConstraints = false
        totalTimeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        totalTimeLabel.textColor = .secondaryLabelColor

        // Waveform mode toggle button
        waveformToggleButton = NSButton(
            image: NSImage(systemSymbolName: "waveform.path", accessibilityDescription: "Toggle waveform")!,
            target: self, action: #selector(toggleWaveformMode)
        )
        waveformToggleButton.translatesAutoresizingMaskIntoConstraints = false
        waveformToggleButton.bezelStyle = .inline
        waveformToggleButton.isBordered = false
        waveformToggleButton.imagePosition = .imageOnly
        waveformToggleButton.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        waveformToggleButton.toolTip = "Toggle spectrum visualizer"

        transportView.addSubview(playPauseButton)
        transportView.addSubview(currentTimeLabel)
        transportView.addSubview(timeSlider)
        transportView.addSubview(totalTimeLabel)
        transportView.addSubview(waveformToggleButton)

        NSLayoutConstraint.activate([
            playPauseButton.leadingAnchor.constraint(equalTo: transportView.leadingAnchor, constant: 8),
            playPauseButton.centerYAnchor.constraint(equalTo: transportView.centerYAnchor),
            playPauseButton.widthAnchor.constraint(equalToConstant: 24),
            playPauseButton.heightAnchor.constraint(equalToConstant: 24),

            currentTimeLabel.leadingAnchor.constraint(equalTo: playPauseButton.trailingAnchor, constant: 6),
            currentTimeLabel.centerYAnchor.constraint(equalTo: transportView.centerYAnchor),
            currentTimeLabel.widthAnchor.constraint(equalToConstant: 40),

            timeSlider.leadingAnchor.constraint(equalTo: currentTimeLabel.trailingAnchor, constant: 4),
            timeSlider.centerYAnchor.constraint(equalTo: transportView.centerYAnchor),

            totalTimeLabel.leadingAnchor.constraint(equalTo: timeSlider.trailingAnchor, constant: 4),
            totalTimeLabel.centerYAnchor.constraint(equalTo: transportView.centerYAnchor),
            totalTimeLabel.widthAnchor.constraint(equalToConstant: 40),

            waveformToggleButton.leadingAnchor.constraint(equalTo: totalTimeLabel.trailingAnchor, constant: 2),
            waveformToggleButton.centerYAnchor.constraint(equalTo: transportView.centerYAnchor),
            waveformToggleButton.trailingAnchor.constraint(equalTo: transportView.trailingAnchor, constant: -8),
            waveformToggleButton.widthAnchor.constraint(equalToConstant: 20),
            waveformToggleButton.heightAnchor.constraint(equalToConstant: 20),
        ])

        playerContentView.addSubview(transportView)
    }

    private func layoutSubviews() {
        // Vertically center the player content in the space below the metadata,
        // but don't let it overlap the metadata section.
        let centerY = playerContentView.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        centerY.priority = .defaultHigh

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: view.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            mediaInfoView.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 1),
            mediaInfoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mediaInfoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            // Player content: centered vertically, but stays below metadata
            playerContentView.topAnchor.constraint(greaterThanOrEqualTo: mediaInfoView.bottomAnchor, constant: 12),
            playerContentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerContentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            playerContentView.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -8),
            centerY,
        ])
    }

    // MARK: - Public API

    func displayItem(_ item: FileItem) {
        metadataTask?.cancel()
        waveformTask?.cancel()
        stopPlayback()

        currentItem = item
        duration = 0
        mediaInfoView.isHidden = true
        albumArtView.image = nil
        waveformView.waveformData = nil
        waveformView.progress = 0
        realtimeWaveView.reset()

        timeSlider.doubleValue = 0
        currentTimeLabel.stringValue = "0:00"
        totalTimeLabel.stringValue = "0:00"
        updatePlayPauseIcon(playing: false)

        // Default to realtime waveform view
        showingRealtimeWave = true
        waveformView.isHidden = true
        realtimeWaveView.isHidden = false

        headerView.update(with: item)

        // Create player (don't autoplay)
        let newPlayer = AVPlayer(url: item.url)
        newPlayer.automaticallyWaitsToMinimizeStalling = false
        player = newPlayer
        setupTimeObserver()
        observePlayerStatus()

        // Install realtime audio spectrum tap
        audioLevelTap.onSpectrum = { [weak self] bands in
            self?.realtimeWaveView.pushSpectrum(bands)
        }
        if let playerItem = newPlayer.currentItem {
            let tap = audioLevelTap
            Task {
                await tap.install(on: playerItem)
            }
        }

        // Observe end of playback to reset
        NotificationCenter.default.addObserver(
            self, selector: #selector(playerDidFinish(_:)),
            name: .AVPlayerItemDidPlayToEndTime, object: newPlayer.currentItem
        )

        metadataTask = Task { @MainActor [weak self] in
            await self?.loadMetadata(for: item)
        }

        waveformTask = Task { @MainActor [weak self] in
            await self?.loadWaveform(for: item)
        }
    }

    func clear() {
        metadataTask?.cancel()
        waveformTask?.cancel()
        stopPlayback()
        currentItem = nil
        duration = 0
        albumArtView.image = nil
        waveformView.waveformData = nil
        waveformView.progress = 0
        realtimeWaveView.reset()

        mediaInfoView.isHidden = true
    }

    // MARK: - Playback

    private func stopPlayback() {
        player?.pause()
        realtimeWaveView.stopAnimating()
        audioLevelTap.remove()
        removeTimeObserver()
        statusObservation?.invalidate()
        statusObservation = nil
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: player?.currentItem)
        player = nil
    }

    private func setupTimeObserver() {
        guard let player else { return }
        let interval = CMTime(value: 1, timescale: 20) // 20fps updates
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.updatePlaybackPosition(time)
        }
    }

    private func removeTimeObserver() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
    }

    private func observePlayerStatus() {
        statusObservation = player?.currentItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .readyToPlay else { return }
            let dur = CMTimeGetSeconds(item.duration)
            guard dur.isFinite, dur > 0 else { return }
            DispatchQueue.main.async { [weak self] in
                self?.duration = dur
                self?.totalTimeLabel.stringValue = dur.formattedDuration
            }
        }
    }

    private func updatePlaybackPosition(_ time: CMTime) {
        guard !isSeeking, duration > 0 else { return }
        let currentTime = CMTimeGetSeconds(time)
        guard currentTime.isFinite else { return }

        let progress = currentTime / duration
        timeSlider.doubleValue = progress
        waveformView.progress = CGFloat(progress)
        currentTimeLabel.stringValue = currentTime.formattedDuration
    }

    private func seekTo(position: Double) {
        guard duration > 0 else { return }
        let targetTime = CMTime(seconds: position * duration, preferredTimescale: 600)
        isSeeking = true
        player?.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                self?.isSeeking = false
            }
        }
        // Update UI immediately for responsive feedback
        timeSlider.doubleValue = position
        waveformView.progress = CGFloat(position)
        currentTimeLabel.stringValue = (position * duration).formattedDuration
    }

    // MARK: - Actions

    @objc func togglePlayPause() {
        guard let player else { return }
        if player.rate > 0 {
            player.pause()
            realtimeWaveView.stopAnimating()
            updatePlayPauseIcon(playing: false)
        } else {
            realtimeWaveView.startAnimating()
            player.play()
            updatePlayPauseIcon(playing: true)
        }
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        seekTo(position: sender.doubleValue)
    }

    @objc private func toggleWaveformMode() {
        showingRealtimeWave.toggle()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            waveformView.animator().isHidden = showingRealtimeWave
            realtimeWaveView.animator().isHidden = !showingRealtimeWave
        }
        updateWaveformToggleIcon()
    }

    private func updateWaveformToggleIcon() {
        let symbolName = showingRealtimeWave ? "waveform.path" : "waveform"
        waveformToggleButton.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "Toggle waveform"
        )
    }

    @objc private func playerDidFinish(_ notification: Notification) {
        guard let finishedItem = notification.object as? AVPlayerItem,
              finishedItem === player?.currentItem else { return }
        player?.seek(to: .zero)
        realtimeWaveView.stopAnimating()
        updatePlayPauseIcon(playing: false)
        waveformView.progress = 0
        timeSlider.doubleValue = 0
        currentTimeLabel.stringValue = "0:00"
    }

    private func updatePlayPauseIcon(playing: Bool) {
        let symbolName = playing ? "pause.fill" : "play.fill"
        let description = playing ? "Pause" : "Play"
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.allowsImplicitAnimation = true
            playPauseButton.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)
        }
    }

    // MARK: - Metadata

    private func loadMetadata(for item: FileItem) async {
        guard let metadata = await MediaMetadataExtractor.extractAudioMetadata(from: item.url) else {
            return
        }

        guard !Task.isCancelled, currentItem?.url == item.url else { return }

        // Set album art
        if let artData = metadata.albumArt, let image = NSImage(data: artData) {
            albumArtView.image = image
        } else {
            albumArtView.image = item.icon
        }

        // Build compact detail
        let summary = makeCompactSummary(from: metadata, item: item)
        headerView.setCompactDetail(summary)

        // Build info rows
        let rows = makeInfoRows(from: metadata)
        guard !rows.isEmpty else { return }

        let infoSummary = makeInfoSummary(from: metadata)
        mediaInfoView.update(title: "Audio Info", compactSummary: infoSummary, rows: rows)
        mediaInfoView.isHidden = false
    }

    private func loadWaveform(for item: FileItem) async {
        guard let data = await WaveformView.generateWaveform(from: item.url) else { return }
        guard !Task.isCancelled, currentItem?.url == item.url else { return }
        waveformView.waveformData = data
    }

    // MARK: - Metadata Builders

    private func makeCompactSummary(from meta: AudioMetadata, item: FileItem) -> String {
        var parts: [String] = []
        if let artist = meta.artist { parts.append(artist) }
        if let album = meta.albumName { parts.append(album) }
        parts.append(meta.formattedDuration)
        parts.append(item.formattedSize)
        return parts.joined(separator: " \u{2014} ")
    }

    private func makeInfoSummary(from meta: AudioMetadata) -> String {
        var parts: [String] = []
        if let codec = meta.audioCodec { parts.append(codec) }
        if let rate = meta.formattedSampleRate { parts.append(rate) }
        if let channels = meta.formattedChannels { parts.append(channels) }
        return parts.joined(separator: " \u{00B7} ")
    }

    private func makeInfoRows(from meta: AudioMetadata) -> [MediaInfoRow] {
        var rows: [MediaInfoRow] = []

        rows.append(MediaInfoRow(label: "Duration", value: meta.formattedDuration))

        if let artist = meta.artist {
            rows.append(MediaInfoRow(label: "Artist", value: artist))
        }

        if let album = meta.albumName {
            rows.append(MediaInfoRow(label: "Album", value: album))
        }

        if let title = meta.trackTitle {
            rows.append(MediaInfoRow(label: "Title", value: title))
        }

        if let trackNum = meta.trackNumber {
            rows.append(MediaInfoRow(label: "Track", value: "\(trackNum)"))
        }

        if let genre = meta.genre {
            rows.append(MediaInfoRow(label: "Genre", value: genre))
        }

        if let year = meta.releaseYear {
            rows.append(MediaInfoRow(label: "Year", value: year))
        }

        if let composer = meta.composer {
            rows.append(MediaInfoRow(label: "Composer", value: composer))
        }

        if let codec = meta.audioCodec {
            var detail = codec
            if let bitrate = meta.formattedBitrate { detail += " \u{00B7} \(bitrate)" }
            rows.append(MediaInfoRow(label: "Codec", value: detail))
        }

        if let rate = meta.formattedSampleRate {
            rows.append(MediaInfoRow(label: "Sample Rate", value: rate))
        }

        if let channels = meta.formattedChannels {
            rows.append(MediaInfoRow(label: "Channels", value: channels))
        }

        if let bpm = meta.bpm {
            rows.append(MediaInfoRow(label: "BPM", value: "\(bpm)"))
        }

        if let copyright = meta.copyright {
            rows.append(MediaInfoRow(label: "Copyright", value: copyright))
        }

        return rows
    }
}
