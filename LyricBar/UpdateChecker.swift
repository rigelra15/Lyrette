import AppKit
import ServiceManagement

/// Checks GitHub Releases for a newer version, shows the changelog, and installs the update.
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/rigelra15/LyricBar/releases/latest")!
    private static let skippedVersionKey = "skippedUpdateVersion"

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let body: String?
        let htmlURL: URL
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case body
            case htmlURL = "html_url"
            case assets
        }

        var version: String { tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName }
        var dmgURL: URL? { assets.first { $0.name.hasSuffix(".dmg") }?.browserDownloadURL }
    }

    private var isChecking = false
    private var isInstalling = false

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Silent check, used at launch (which also covers "launch at login"). Only speaks up when
    /// there is a new version the user has not skipped.
    func checkOnLaunch() {
        Task { await check(userInitiated: false) }
    }

    /// Check requested from the UI: always reports the outcome.
    func checkNow() {
        Task { await check(userInitiated: true) }
    }

    private func check(userInitiated: Bool) async {
        guard !isChecking, !isInstalling else { return }
        isChecking = true
        defer { isChecking = false }

        do {
            var request = URLRequest(url: Self.latestReleaseURL, timeoutInterval: 15)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let release = try JSONDecoder().decode(Release.self, from: data)

            guard Self.isNewer(release.version, than: currentVersion) else {
                if userInitiated { showUpToDate() }
                return
            }
            if !userInitiated, UserDefaults.standard.string(forKey: Self.skippedVersionKey) == release.version {
                return
            }
            present(release)
        } catch {
            if userInitiated { showCheckFailed() }
        }
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - UI

    private func present(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = "LyricBar \(release.version) is available"
        alert.informativeText = "You have version \(currentVersion). Here's what's new:"
        alert.icon = NSApp.applicationIconImage
        alert.accessoryView = Self.changelogView(release.body)
        alert.addButton(withTitle: release.dmgURL == nil ? "View Release" : "Update Now")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let dmg = release.dmgURL {
                Task { await install(from: dmg, fallback: release.htmlURL) }
            } else {
                NSWorkspace.shared.open(release.htmlURL)
            }
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(release.version, forKey: Self.skippedVersionKey)
        default:
            break
        }
    }

    private static func changelogView(_ body: String?) -> NSView {
        let text = (body ?? "No changelog provided.").trimmingCharacters(in: .whitespacesAndNewlines)
        let attributed = (try? NSMutableAttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? NSMutableAttributedString(string: text)
        let range = NSRange(location: 0, length: attributed.length)
        attributed.addAttributes([
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor
        ], range: range)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 170))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.autoresizingMask = [.width]
        textView.textStorage?.setAttributedString(attributed)
        scroll.documentView = textView
        return scroll
    }

    private func showUpToDate() {
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "LyricBar \(currentVersion) is the latest version."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showCheckFailed() {
        let alert = NSAlert()
        alert.messageText = "Couldn't check for updates"
        alert.informativeText = "Please check your internet connection and try again."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showInstallFailed(_ reason: String, releasePage: URL) {
        let alert = NSAlert()
        alert.messageText = "Couldn't install the update"
        alert.informativeText = "\(reason)\n\nYou can download it manually from the release page."
        alert.addButton(withTitle: "Open Release Page")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(releasePage)
        }
    }

    // MARK: - Install

    private struct InstallError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private func install(from dmgURL: URL, fallback: URL) async {
        guard !isInstalling else { return }
        isInstalling = true

        let bundleURL = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path) else {
            isInstalling = false
            showInstallFailed("LyricBar can't replace itself in its current folder.", releasePage: fallback)
            return
        }

        let window = Self.makeProgressWindow()
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)

        let work = Task.detached { () throws -> URL in
            try await Self.downloadAndStage(dmgURL)
        }

        do {
            let stagedApp = try await work.value
            window.close()
            // A release may ship under a new app name; install it next to this one and retire this one.
            let destination = bundleURL.deletingLastPathComponent().appendingPathComponent(stagedApp.lastPathComponent)
            if destination.standardizedFileURL != bundleURL.standardizedFileURL {
                handOffLoginItem()
            }
            try launchReplacer(stagedApp: stagedApp, destination: destination, current: bundleURL)
            NSApp.terminate(nil)
        } catch {
            window.close()
            isInstalling = false
            showInstallFailed(error.localizedDescription, releasePage: fallback)
        }
    }

    private static func makeProgressWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 90),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "LyricBar Update"
        window.isReleasedWhenClosed = false

        let label = NSTextField(labelWithString: "Downloading update…\nLyricBar will restart when it's done.")
        label.alignment = .center
        label.frame = NSRect(x: 20, y: 40, width: 260, height: 36)
        let spinner = NSProgressIndicator(frame: NSRect(x: 20, y: 16, width: 260, height: 12))
        spinner.style = .bar
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)

        window.contentView?.addSubview(label)
        window.contentView?.addSubview(spinner)
        return window
    }

    /// Remembers whether this app launched at login, for the renamed app to pick up, and removes
    /// this app's login item since the bundle is about to be deleted.
    private func handOffLoginItem() {
        let enabled = SMAppService.mainApp.status == .enabled
        UserDefaults.standard.set(enabled, forKey: "migratedLaunchAtLogin")
        UserDefaults.standard.synchronize()
        if enabled { try? SMAppService.mainApp.unregister() }
    }

    /// Downloads the DMG, copies the app out of it, and unmounts. Returns the staged app.
    private nonisolated static func downloadAndStage(_ dmgURL: URL) async throws -> URL {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("LyricBarUpdate-\(UUID().uuidString)")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)

        let (tmpFile, response) = try await URLSession.shared.download(from: dmgURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw InstallError("The download failed.")
        }
        let dmg = workDir.appendingPathComponent("update.dmg")
        try fm.moveItem(at: tmpFile, to: dmg)

        let mount = workDir.appendingPathComponent("mount")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }

        let apps = (try? fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "app" } ?? []
        guard let source = apps.first else {
            throw InstallError("The update package doesn't contain an app.")
        }
        let staged = workDir.appendingPathComponent(source.lastPathComponent)
        try run("/usr/bin/ditto", [source.path, staged.path])
        return staged
    }

    @discardableResult
    private nonisolated static func run(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw InstallError("\(URL(fileURLWithPath: path).lastPathComponent) failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return output
    }

    /// Starts a detached shell that waits for this process to exit, installs the staged bundle at
    /// `destination`, removes `current` if the app was renamed, and launches the new one.
    private func launchReplacer(stagedApp: URL, destination: URL, current: URL) throws {
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        rm -rf "$2" && /usr/bin/ditto "$1" "$2" && /usr/bin/xattr -dr com.apple.quarantine "$2" || exit 1
        [ "$3" != "$2" ] && rm -rf "$3"
        /usr/bin/open "$2"
        rm -rf "$(dirname "$1")"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", stagedApp.path, destination.path, current.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}
