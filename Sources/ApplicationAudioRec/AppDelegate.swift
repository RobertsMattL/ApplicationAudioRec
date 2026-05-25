import AppKit
import ScreenCaptureKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let recorder = AudioRecorder()
    private var apps: [AppInfo] = []
    private var elapsedTimer: Timer?
    private var startDate: Date?
    private var currentOutputURL: URL?
    private var playerController: PlayerWindowController?

    // MARK: - Persisted settings

    private var selectedBundleID: String {
        get { UserDefaults.standard.string(forKey: "selectedBundleID") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "selectedBundleID") }
    }
    private var selectedAppName: String {
        get { UserDefaults.standard.string(forKey: "selectedAppName") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "selectedAppName") }
    }
    private var bitrate: Int {
        get { let b = UserDefaults.standard.integer(forKey: "bitrate"); return b == 0 ? 320 : b }
        set { UserDefaults.standard.set(newValue, forKey: "bitrate") }
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🎙"

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        recorder.onError = { [weak self] message in
            Task { @MainActor in self?.handleStreamError(message) }
        }

        Task { await refreshApps() }
    }

    private func refreshApps() async {
        if let list = try? await recorder.fetchApps() {
            apps = list
        }
    }

    // MARK: - Menu construction

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu(menu)
        Task { await refreshApps() } // keep the source list fresh for next open
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        if recorder.isRecording {
            addItem(to: menu, title: "⏹  Stop Recording", action: #selector(toggleRecording))
            let info = NSMenuItem(title: "Recording \(selectedAppName)…", action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        } else {
            addItem(to: menu, title: "⏺  Start Recording", action: #selector(toggleRecording))
        }

        menu.addItem(.separator())
        menu.addItem(makeSourceMenu())
        menu.addItem(makeQualityMenu())

        menu.addItem(.separator())
        addItem(to: menu, title: "Open Player…", action: #selector(openPlayer))
        addItem(to: menu, title: "Open Recordings Folder", action: #selector(openFolder))

        menu.addItem(.separator())
        let quit = addItem(to: menu, title: "Quit", action: #selector(quit))
        quit.keyEquivalent = "q"
    }

    @discardableResult
    private func addItem(to menu: NSMenu, title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    private func makeSourceMenu() -> NSMenuItem {
        let title = selectedAppName.isEmpty ? "Source: (none selected)" : "Source: \(selectedAppName)"
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        // Keep the current selection visible even if that app isn't running now.
        var listed = apps
        if !selectedBundleID.isEmpty,
           !listed.contains(where: { $0.bundleID == selectedBundleID }) {
            listed.insert(AppInfo(bundleID: selectedBundleID,
                                  name: "\(selectedAppName) (not running)"), at: 0)
        }
        if apps.isEmpty {
            let scanning = NSMenuItem(title: "Scanning apps…", action: nil, keyEquivalent: "")
            scanning.isEnabled = false
            submenu.addItem(scanning)
        }
        for app in listed {
            let item = NSMenuItem(title: app.name, action: #selector(selectSource(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app
            item.state = (app.bundleID == selectedBundleID) ? .on : .off
            item.isEnabled = !recorder.isRecording
            submenu.addItem(item)
        }

        parent.submenu = submenu
        parent.isEnabled = !recorder.isRecording
        return parent
    }

    private func makeQualityMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Quality", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for kbps in [128, 192, 256, 320] {
            let item = NSMenuItem(title: "\(kbps) kbps", action: #selector(selectBitrate(_:)), keyEquivalent: "")
            item.target = self
            item.tag = kbps
            item.state = (kbps == bitrate) ? .on : .off
            item.isEnabled = !recorder.isRecording
            submenu.addItem(item)
        }
        parent.submenu = submenu
        parent.isEnabled = !recorder.isRecording
        return parent
    }

    // MARK: - Actions

    @objc private func selectSource(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? AppInfo else { return }
        selectedBundleID = app.bundleID
        selectedAppName = app.name.replacingOccurrences(of: " (not running)", with: "")
    }

    @objc private func selectBitrate(_ sender: NSMenuItem) {
        bitrate = sender.tag
    }

    @objc private func toggleRecording() {
        Task {
            if recorder.isRecording {
                await stopRecording()
            } else {
                await startRecording()
            }
        }
    }

    @objc private func openFolder() {
        NSWorkspace.shared.open(recordingsFolder())
    }

    @objc private func openPlayer() {
        if playerController == nil {
            let controller = PlayerWindowController(folder: recordingsFolder())
            controller.onClose = { [weak self] in self?.playerController = nil }
            playerController = controller
        }
        NSApp.activate(ignoringOtherApps: true)
        playerController?.showWindow(nil)
        playerController?.window?.makeKeyAndOrderFront(nil)
        playerController?.refresh()
    }

    @objc private func quit() {
        Task {
            if recorder.isRecording { await recorder.stop() }
            NSApp.terminate(nil)
        }
    }

    // MARK: - Recording

    private func recordingsFolder() -> URL {
        let base = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("ApplicationAudioRec", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func startRecording() async {
        guard !selectedBundleID.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No source selected"
            alert.informativeText = "Pick an application to record from the Source menu first."
            alert.runModal()
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let safeName = selectedAppName.replacingOccurrences(of: "/", with: "-")
        let url = recordingsFolder()
            .appendingPathComponent("\(safeName) \(formatter.string(from: Date())).mp3")

        do {
            try await recorder.start(bundleID: selectedBundleID, bitrateKbps: bitrate, outputURL: url)
            currentOutputURL = url
            startDate = Date()
            startElapsedTimer()
            updateTitle()
        } catch {
            presentStartError(error)
        }
    }

    private func stopRecording() async {
        await recorder.stop()
        stopElapsedTimer()
        if let url = currentOutputURL { flashSaved(url) }
    }

    private func handleStreamError(_ message: String) {
        if recorder.isRecording { Task { await stopRecording() } }
        let alert = NSAlert()
        alert.messageText = "Recording stopped"
        alert.informativeText = message
        alert.runModal()
    }

    // MARK: - Status-item title

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateTitle() }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        startDate = nil
    }

    private func updateTitle() {
        guard let start = startDate else { return }
        let total = Int(Date().timeIntervalSince(start))
        statusItem.button?.title = String(format: "🔴 %d:%02d", total / 60, total % 60)
    }

    private func flashSaved(_ url: URL) {
        statusItem.button?.title = "✅"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.recorder.isRecording else { return }
            self.statusItem.button?.title = "🎙"
        }
    }

    // MARK: - Error presentation

    private func presentStartError(_ error: Error) {
        let ns = error as NSError
        let denied = (ns.domain.contains("SCStream") && ns.code == -3801)
            || ns.localizedDescription.lowercased().contains("declined")

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't start recording"

        if denied {
            alert.informativeText = """
            Screen Recording permission is required to capture audio.

            Enable “ApplicationAudioRec” under System Settings → Privacy & Security \
            → Screen Recording, then quit and reopen the app.
            """
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        } else {
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
