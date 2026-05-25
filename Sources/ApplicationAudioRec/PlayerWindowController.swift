import AppKit
import AVFoundation

/// A small window that lists the MP3s in the recordings folder and plays them
/// back with transport controls, a seek slider, and a volume slider.
@MainActor
final class PlayerWindowController: NSWindowController, NSWindowDelegate,
                                    NSTableViewDataSource, NSTableViewDelegate,
                                    AVAudioPlayerDelegate {

    private struct Track {
        let url: URL
        var duration: TimeInterval?   // nil until computed lazily
    }

    private let folder: URL
    /// Called when the window closes so the owner can release this controller.
    var onClose: (() -> Void)?

    private var tracks: [Track] = []
    private var currentIndex: Int?
    private var player: AVAudioPlayer?
    private var timer: Timer?

    // UI
    private let tableView = NSTableView()
    private let nowPlayingLabel = NSTextField(labelWithString: "Nothing playing")
    private let elapsedLabel = NSTextField(labelWithString: "0:00")
    private let totalLabel = NSTextField(labelWithString: "0:00")
    private let positionSlider = NSSlider()
    private let volumeSlider = NSSlider()
    private let prevButton = NSButton()
    private let playPauseButton = NSButton()
    private let nextButton = NSButton()

    // MARK: - Init

    init(folder: URL) {
        self.folder = folder
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Recordings"
        window.minSize = NSSize(width: 420, height: 300)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - UI construction

    private func buildUI() {
        guard let content = window?.contentView else { return }

        // --- Track table ---
        let nameCol = NSTableColumn(identifier: .init("name"))
        nameCol.title = "Recording"
        nameCol.width = 380
        let durCol = NSTableColumn(identifier: .init("duration"))
        durCol.title = "Length"
        durCol.width = 70
        tableView.addTableColumn(nameCol)
        tableView.addTableColumn(durCol)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(doubleClickRow)
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 22

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)

        // --- Now playing ---
        nowPlayingLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nowPlayingLabel.lineBreakMode = .byTruncatingTail

        // --- Seek row ---
        positionSlider.minValue = 0
        positionSlider.maxValue = 1
        positionSlider.doubleValue = 0
        positionSlider.isContinuous = true
        positionSlider.controlSize = .small
        positionSlider.target = self
        positionSlider.action = #selector(seek)

        for label in [elapsedLabel, totalLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
        }
        totalLabel.alignment = .right
        let seekRow = NSStackView(views: [elapsedLabel, positionSlider, totalLabel])
        seekRow.spacing = 8

        // --- Transport + volume row ---
        configureTransport(prevButton, symbol: "backward.fill", action: #selector(playPrevious))
        configureTransport(playPauseButton, symbol: "play.fill", action: #selector(togglePlayPause))
        configureTransport(nextButton, symbol: "forward.fill", action: #selector(playNext))
        let transport = NSStackView(views: [prevButton, playPauseButton, nextButton])
        transport.spacing = 14

        let volIcon = NSImageView()
        volIcon.image = NSImage(systemSymbolName: "speaker.wave.2.fill",
                                accessibilityDescription: "Volume")
        volIcon.contentTintColor = .secondaryLabelColor
        volumeSlider.minValue = 0
        volumeSlider.maxValue = 1
        volumeSlider.doubleValue = 1
        volumeSlider.controlSize = .small
        volumeSlider.target = self
        volumeSlider.action = #selector(changeVolume)
        volumeSlider.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let volume = NSStackView(views: [volIcon, volumeSlider])
        volume.spacing = 4

        let controlsRow = NSStackView(views: [transport, flexibleSpace(), volume])

        // --- Footer ---
        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refresh))
        let revealButton = NSButton(title: "Show in Finder", target: self, action: #selector(revealInFinder))
        refreshButton.bezelStyle = .rounded
        revealButton.bezelStyle = .rounded
        let footerRow = NSStackView(views: [refreshButton, flexibleSpace(), revealButton])

        // --- Bottom container ---
        let bottom = NSStackView(views: [nowPlayingLabel, seekRow, controlsRow, footerRow])
        bottom.orientation = .vertical
        bottom.alignment = .leading
        bottom.spacing = 10
        bottom.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 14, right: 16)
        bottom.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bottom)

        for row in [nowPlayingLabel, seekRow, controlsRow, footerRow] as [NSView] {
            row.widthAnchor.constraint(equalTo: bottom.widthAnchor, constant: -32).isActive = true
        }

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottom.topAnchor),

            bottom.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        updateTransportEnabled()
    }

    private func configureTransport(_ button: NSButton, symbol: String, action: Selector) {
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.contentTintColor = .controlAccentColor
        button.target = self
        button.action = action
        button.widthAnchor.constraint(equalToConstant: 36).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
    }

    private func flexibleSpace() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.init(1), for: .horizontal)
        v.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return v
    }

    // MARK: - Folder scanning

    @objc func refresh() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []

        let mp3s = urls
            .filter { $0.pathExtension.lowercased() == "mp3" }
            .sorted { modDate($0) > modDate($1) }   // newest first

        // Preserve already-computed durations across refreshes.
        tracks = mp3s.map { url in
            Track(url: url, duration: tracks.first { $0.url == url }?.duration)
        }
        tableView.reloadData()
        computeMissingDurations()
        updateTransportEnabled()
    }

    private func modDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    /// Reads durations off the main thread so a large folder doesn't stall the UI.
    private func computeMissingDurations() {
        let pending = tracks.filter { $0.duration == nil }.map(\.url)
        guard !pending.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            for url in pending {
                let duration = (try? AVAudioPlayer(contentsOf: url))?.duration ?? 0
                DispatchQueue.main.async {
                    guard let self,
                          let idx = self.tracks.firstIndex(where: { $0.url == url }) else { return }
                    self.tracks[idx].duration = duration
                    self.tableView.reloadData(forRowIndexes: IndexSet(integer: idx),
                                              columnIndexes: IndexSet(integer: 1))
                }
            }
        }
    }

    // MARK: - Playback

    private func play(at index: Int) {
        guard tracks.indices.contains(index) else { return }
        let url = tracks[index].url
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.volume = Float(volumeSlider.doubleValue)
            p.prepareToPlay()
            p.play()
            player = p
            currentIndex = index

            positionSlider.maxValue = max(p.duration, 0.01)
            positionSlider.doubleValue = 0
            elapsedLabel.stringValue = Self.formatTime(0)
            totalLabel.stringValue = Self.formatTime(p.duration)
            nowPlayingLabel.stringValue = url.deletingPathExtension().lastPathComponent

            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            if tracks[index].duration == nil {
                tracks[index].duration = p.duration
                tableView.reloadData(forRowIndexes: IndexSet(integer: index),
                                     columnIndexes: IndexSet(integer: 1))
            }
            startTimer()
            updatePlayPauseIcon()
            updateTransportEnabled()
        } catch {
            nowPlayingLabel.stringValue = "Couldn't play \(url.lastPathComponent)"
        }
    }

    @objc private func doubleClickRow() {
        let row = tableView.clickedRow
        guard row >= 0 else { return }
        play(at: row)
    }

    @objc private func togglePlayPause() {
        if let p = player {
            if p.isPlaying { p.pause(); stopTimer() } else { p.play(); startTimer() }
            updatePlayPauseIcon()
        } else {
            let row = tableView.selectedRow >= 0 ? tableView.selectedRow
                : (tracks.isEmpty ? -1 : 0)
            if row >= 0 { play(at: row) }
        }
    }

    @objc private func playNext() {
        guard let i = currentIndex, i + 1 < tracks.count else { return }
        play(at: i + 1)
    }

    @objc private func playPrevious() {
        // Restart the current track if we're more than 3s in; otherwise go back.
        if let p = player, p.currentTime > 3 {
            p.currentTime = 0
            positionSlider.doubleValue = 0
            elapsedLabel.stringValue = Self.formatTime(0)
            return
        }
        guard let i = currentIndex, i - 1 >= 0 else { return }
        play(at: i - 1)
    }

    @objc private func seek() {
        guard let p = player else { return }
        p.currentTime = positionSlider.doubleValue
        elapsedLabel.stringValue = Self.formatTime(p.currentTime)
    }

    @objc private func changeVolume() {
        player?.volume = Float(volumeSlider.doubleValue)
    }

    @objc private func revealInFinder() {
        if let i = currentIndex {
            NSWorkspace.shared.activateFileViewerSelecting([tracks[i].url])
        } else {
            NSWorkspace.shared.open(folder)
        }
    }

    // MARK: - Timer

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let p = player else { return }
        positionSlider.doubleValue = p.currentTime
        elapsedLabel.stringValue = Self.formatTime(p.currentTime)
    }

    // MARK: - UI state

    private func updatePlayPauseIcon() {
        let playing = player?.isPlaying ?? false
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        playPauseButton.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill",
                                        accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
    }

    private func updateTransportEnabled() {
        let hasTracks = !tracks.isEmpty
        [prevButton, playPauseButton, nextButton].forEach { $0.isEnabled = hasTracks }
    }

    static func formatTime(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { tracks.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, tracks.indices.contains(row) else { return nil }
        let track = tracks[row]
        let isDuration = column.identifier.rawValue == "duration"
        let cellID = NSUserInterfaceItemIdentifier("cell.\(column.identifier.rawValue)")

        let cell = (tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView)
            ?? makeCell(id: cellID, rightAligned: isDuration)

        if isDuration {
            cell.textField?.stringValue = track.duration.map(Self.formatTime) ?? "—"
        } else {
            cell.textField?.stringValue = track.url.deletingPathExtension().lastPathComponent
        }
        return cell
    }

    private func makeCell(id: NSUserInterfaceItemIdentifier, rightAligned: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.lineBreakMode = .byTruncatingTail
        if rightAligned {
            tf.alignment = .right
            tf.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            tf.textColor = .secondaryLabelColor
        }
        cell.addSubview(tf)
        cell.textField = tf
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.handleFinished() }
    }

    private func handleFinished() {
        if let i = currentIndex, i + 1 < tracks.count {
            play(at: i + 1)   // auto-advance
        } else {
            stopTimer()
            positionSlider.doubleValue = positionSlider.maxValue
            updatePlayPauseIcon()
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        player?.stop()
        player = nil
        stopTimer()
        onClose?()
    }
}
